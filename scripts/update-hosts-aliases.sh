#!/usr/bin/env bash
#
# update-hosts-aliases.sh
#
# 功能升级：
#   1) 自动检测 WSL：WSL 环境下同时更新 Linux /etc/hosts 与 Windows hosts。
#   2) 支持 add/update/delete 模式：根据 up.sh 的操作添加或删除映射。
#   3) 自动扫描已启动容器，为所有容器写入（或删除）别名映射，幂等处理。
#   4) 仅删除或追加/替换目标别名所在行，不影响其他 hosts 条目。
#   5) 支持 host 网络模式容器（映射到 127.0.0.1）。
#
# 典型用法（由 up.sh 调用）：
#   add/update： ./scripts/update-hosts-aliases.sh --mode update
#   delete：     ./scripts/update-hosts-aliases.sh --mode delete
#
set -euo pipefail

LINUX_HOSTS="/etc/hosts"
WINDOWS_HOSTS="/mnt/c/Windows/System32/drivers/etc/hosts"
DEFAULT_WINDOWS_IP="127.0.0.1"

MODE="update"              # add|update|delete
WINDOWS_IP="$DEFAULT_WINDOWS_IP"
MANUAL_ENTRIES=""          # 格式: "ip alias1 alias2;ip2 alias3"
SKIP_DOCKER="false"
CACHE_FILE="/tmp/hg_dnmpr-hosts-entries"
VERBOSE="true"             # 显示详细日志

usage() {
  cat <<'EOF'
更新 hosts 别名映射（支持自动检测 WSL、批量容器、add/update/delete 模式）

参数：
  --mode <add|update|delete>   默认 update
  --windows-ip <ip>            WSL 场景下写入 Windows hosts 的 IP，默认 127.0.0.1
  --entries "<list>"           手工指定映射，形如: "172.20.0.3 mysql db;10.1.1.2 cache"
  --skip-docker                不从 docker 容器自动收集映射
  -h, --help                   显示帮助
EOF
}

is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
  [[ -f /proc/version ]] && grep -qi "microsoft\|wsl" /proc/version && return 0
  [[ -f /proc/sys/kernel/osrelease ]] && grep -qi "microsoft\|wsl" /proc/sys/kernel/osrelease && return 0
  return 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        MODE="${2:-update}"
        shift 2
        ;;
      --windows-ip)
        WINDOWS_IP="${2:-$DEFAULT_WINDOWS_IP}"
        shift 2
        ;;
      --entries)
        MANUAL_ENTRIES="${2:-}"
        shift 2
        ;;
      --skip-docker)
        SKIP_DOCKER="true"
        shift 1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "未知参数: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  case "$MODE" in
    add|update|delete) ;;
    *)
      echo "无效的 --mode 值: $MODE (允许: add|update|delete)" >&2
      exit 1
      ;;
  esac
}

# 收集 docker 容器映射：输出形如 "ip alias1 alias2"
collect_docker_entries() {
  local entries=()
  local cids
  cids=$(docker ps -q 2>/dev/null || true)
  if [[ -z "$cids" ]]; then
    [[ "$VERBOSE" == "true" ]] && echo "未发现运行中的容器" >&2
    echo "${entries[@]}"
    return
  fi

  local total_containers=0
  local collected_containers=0
  local skipped_containers=0

  while read -r cid; do
    [[ -z "$cid" ]] && continue
    total_containers=$((total_containers + 1))

    local ip name aliases alias_list network_mode
    name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')
    network_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cid" 2>/dev/null || echo "")

    # 获取容器IP
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null | xargs)

    # 如果容器使用host网络模式或者没有容器IP，映射到127.0.0.1
    if [[ -z "$ip" ]]; then
      if [[ "$network_mode" == "host" ]]; then
        ip="127.0.0.1"
        [[ "$VERBOSE" == "true" ]] && echo "  ✓ 容器 $name 使用 host 网络模式，映射到 127.0.0.1" >&2
      else
        [[ "$VERBOSE" == "true" ]] && echo "  ✗ 跳过容器 $name：无法获取IP (network_mode=$network_mode)" >&2
        skipped_containers=$((skipped_containers + 1))
        continue
      fi
    else
      [[ "$VERBOSE" == "true" ]] && echo "  ✓ 容器 $name IP: $ip" >&2
    fi

    # 获取别名
    aliases=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{range $i,$a := .Aliases}}{{$a}} {{end}}{{end}}' "$cid" 2>/dev/null | xargs)
    alias_list="$name $aliases"
    alias_list=$(echo "$alias_list" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | xargs)
    [[ -z "$alias_list" ]] && alias_list="$name"

    entries+=("$ip $alias_list")
    collected_containers=$((collected_containers + 1))
    [[ "$VERBOSE" == "true" ]] && echo "    别名: $alias_list" >&2
  done <<< "$cids"

  if [[ "$VERBOSE" == "true" ]]; then
    echo "容器统计: 总计 $total_containers 个，已采集 $collected_containers 个，跳过 $skipped_containers 个" >&2
  fi

  printf "%s\n" "${entries[@]}"
}

# 将 entries 字符串解析为数组
parse_manual_entries() {
  local list="$1"
  local arr=()
  IFS=';' read -ra parts <<< "$list"
  for part in "${parts[@]}"; do
    local trimmed
    trimmed=$(echo "$part" | xargs)
    [[ -z "$trimmed" ]] && continue
    arr+=("$trimmed")
  done
  printf "%s\n" "${arr[@]}"
}

write_cache() {
  local file="$1"
  shift || true
  printf "%s\n" "$@" > "$file"
}

read_cache() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  cat "$file"
}

# 批量更新/删除 hosts 文件（一次性处理所有条目）
apply_entries_batch() {
  local file="$1"
  local action="$2"   # add|update|delete
  shift 2
  local entries=("$@")

  # 检查文件是否存在
  if [[ ! -f "$file" ]]; then
    return 1
  fi

  # 检查写权限
  if [[ ! -w "$file" ]]; then
    return 1
  fi

  # 收集所有需要处理的别名
  local all_aliases=""
  for entry in "${entries[@]}"; do
    local aliases_part=$(echo "$entry" | cut -d' ' -f2-)
    all_aliases="$all_aliases $aliases_part"
  done
  all_aliases=$(echo "$all_aliases" | xargs)

  [[ -z "$all_aliases" ]] && return 0

  local tmp
  tmp="$(mktemp)"

  # 读取并过滤hosts文件（删除包含任何目标别名的行）
  if ! awk -v aliases="$all_aliases" '
    BEGIN {
      n = split(aliases, a, /[ \t]+/)
      for (i=1; i<=n; i++) alias[a[i]]=1
    }
    {
      if ($0 ~ /^[ \t]*#/) { print; next }
      keep=1
      for (i=2; i<=NF; i++) { if ($i in alias) { keep=0; break } }
      if (keep) print
    }
  ' "$file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  # 如果是添加/更新操作，添加所有新条目
  if [[ "$action" != "delete" ]]; then
    for entry in "${entries[@]}"; do
      echo "$entry" >> "$tmp"
    done
  fi

  # 写入文件，使用多种方法尝试（WSL 环境下增强可靠性）
  local write_success=false

  # 方法1: cp 命令
  if cp -f "$tmp" "$file" 2>/dev/null; then
    write_success=true
  # 方法2: cat 通过管道
  elif cat "$tmp" | tee "$file" >/dev/null 2>&1; then
    write_success=true
  # 方法3: dd 命令
  elif dd if="$tmp" of="$file" conv=notrunc 2>/dev/null; then
    write_success=true
  fi

  rm -f "$tmp"

  if $write_success; then
    return 0
  else
    return 1
  fi
}

main() {
  parse_args "$@"

  local entries=()
  if [[ -n "$MANUAL_ENTRIES" ]]; then
    while read -r e; do entries+=("$e"); done < <(parse_manual_entries "$MANUAL_ENTRIES")
  fi

  if [[ "$SKIP_DOCKER" != "true" ]]; then
    while read -r e; do
      [[ -z "$e" ]] && continue
      entries+=("$e")
    done < <(collect_docker_entries)
  fi

  if [[ ${#entries[@]} -eq 0 && "$MODE" == "delete" && -f "$CACHE_FILE" ]]; then
    while read -r e; do
      [[ -z "$e" ]] && continue
      entries+=("$e")
    done < "$CACHE_FILE"
  fi

  if [[ ${#entries[@]} -eq 0 ]]; then
    echo "未发现任何需要处理的映射，退出。" >&2
    exit 0
  fi

  if [[ "$VERBOSE" == "true" ]]; then
    echo "准备处理 ${#entries[@]} 条映射：" >&2
    for entry in "${entries[@]}"; do
      echo "  - $entry" >&2
    done
  fi

  if [[ "$MODE" != "delete" ]]; then
    write_cache "$CACHE_FILE" "${entries[@]}"
  fi

  local wsl_env=false
  if is_wsl; then
    wsl_env=true
  fi

  # 准备 Linux hosts 的条目（使用容器IP）
  local linux_entries=("${entries[@]}")

  # 准备 Windows hosts 的条目（转换为 127.0.0.1）
  local windows_entries=()
  if $wsl_env && [[ -f "$WINDOWS_HOSTS" ]]; then
    for entry in "${entries[@]}"; do
      local ip=$(echo "$entry" | awk '{print $1}')
      local aliases=$(echo "$entry" | cut -d' ' -f2-)
      local win_ip="$WINDOWS_IP"
      # 如果容器本身就是 127.0.0.1（host网络模式），保持不变
      if [[ "$ip" == "127.0.0.1" ]]; then
        win_ip="127.0.0.1"
      fi
      windows_entries+=("$win_ip $aliases")
    done
  fi

  # 一次性更新 Linux hosts
  local linux_success=0
  local linux_failed=0
  if apply_entries_batch "$LINUX_HOSTS" "$MODE" "${linux_entries[@]}"; then
    linux_success=${#linux_entries[@]}
  else
    linux_failed=${#linux_entries[@]}
  fi

  # 一次性更新 Windows hosts
  local windows_success=0
  local windows_failed=0
  local windows_permission_error=false
  if $wsl_env && [[ -f "$WINDOWS_HOSTS" ]] && [[ ${#windows_entries[@]} -gt 0 ]]; then
    if apply_entries_batch "$WINDOWS_HOSTS" "$MODE" "${windows_entries[@]}" 2>/dev/null; then
      windows_success=${#windows_entries[@]}
    else
      windows_failed=${#windows_entries[@]}
      windows_permission_error=true
    fi
  fi

  # 如果Windows hosts有权限错误，显示一次警告
  if $windows_permission_error && [[ $windows_failed -gt 0 ]]; then
    echo "" >&2
    echo "⚠️  警告：无法写入 Windows hosts 文件（${windows_failed} 条失败）" >&2
    echo "   文件：$WINDOWS_HOSTS" >&2
    echo "   原因：可能是文件被占用或权限不足" >&2
    echo "   解决方案：" >&2
    echo "   1. 关闭可能占用 hosts 的程序（如杀毒软件、防火墙）" >&2
    echo "   2. 在 Windows 中以管理员身份编辑 hosts 文件" >&2
    echo "   3. 配置 WSL /etc/wsl.conf（参考 WSL_PERMISSIONS_GUIDE.md）" >&2
    echo "   注意：Linux hosts 已成功同步，仅 Windows 访问受影响" >&2
    echo "" >&2
  fi

  if [[ "$MODE" == "delete" ]]; then
    rm -f "$CACHE_FILE"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "完成 hosts $MODE 操作，共处理 ${#entries[@]} 条映射。"
  echo "  Linux /etc/hosts: 成功 $linux_success 条，失败 $linux_failed 条"
  if is_wsl; then
    echo "  Windows hosts: 成功 $windows_success 条，失败 $windows_failed 条 (IP=${WINDOWS_IP})"
    echo "WSL 环境：已同步更新 /etc/hosts 和 Windows hosts。"
  else
    echo "非 WSL 环境：仅更新 /etc/hosts。"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main "$@"
