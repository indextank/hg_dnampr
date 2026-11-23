#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
GOST_BIN="/usr/bin/gost"
GOST_BIN_ALT="/usr/local/bin/gost"
GOST_DIR="/etc/gost"
GOST_CONFIG="${GOST_DIR}/config.yaml"
GOST_ENV="${GOST_DIR}/gost.env"
GOST_SERVICE="/etc/systemd/system/gost.service"
GOST_RESTART_SERVICE="/etc/systemd/system/gost-restart.service"
GOST_TIMER="/etc/systemd/system/gost-restart.timer"
GOST_LOG_DIR="/var/log/gost"
STATE_FILE="${GOST_DIR}/state.env"
PROXY_DB="${GOST_DIR}/proxies.db"
DEFAULT_PORT=8080
DEFAULT_GRPC_PATH="/GostTunel/Tunnel"
DEFAULT_H3_AUTHORIZE_PATH="/authorize"
DEFAULT_H3_PUSH_PATH="/push"
DEFAULT_H3_PULL_PATH="/pull"
# HTTP 代理响应头 Proxy-Agent：本机 proxies.db 中 HTTP 服务不设置（保持 gost/3.0 默认）。
# DEFAULT_HTTP_PROXY_AGENT="squid/4.15"

RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BOLD="$(printf '\033[1m')"
BOLD_GREEN="$(printf '\033[1;32m')"
BOLD_DEFAULT="$(printf '\033[1;39m')"
RESET="$(printf '\033[0m')"

log() { printf "%s[%s]%s %s\n" "$GREEN" "INFO" "$RESET" "$*"; }
warn() { printf "%s[%s]%s %s\n" "$YELLOW" "WARN" "$RESET" "$*"; }
err() { printf "%s[%s]%s %s\n" "$RED" "ERROR" "$RESET" "$*" >&2; }

on_error() {
  local exit_code=$?
  trap - ERR
  err "执行失败（exit=${exit_code}），请查看上方日志。"
  exit "$exit_code"
}
trap on_error ERR

usage() {
  cat <<'EOF'
gost-server-manager.sh - Gost 一键安装/升级与管理脚本（Bash 4+）

用法:
  ./gost-server-manager.sh                显示交互菜单（默认）
  ./gost-server-manager.sh --install      交互安装/升级
  ./gost-server-manager.sh --purge        完全卸载并清理 gost
  ./gost-server-manager.sh --reload-config  仅重写 /etc/gost/config.yaml 并重启 gost（需 root）
  ./gost-server-manager.sh --status       显示 gost 服务状态（交互主菜单选 5 亦同）
  ./gost-server-manager.sh -h|--help      显示帮助

功能:
  1) 自动检测系统与 CPU 架构，下载官方最新 release 二进制
  2) 安装前自动清理历史二进制、配置、日志、systemd 单元
  3) 交互选择 HTTP/SOCKS5，自动生成随机 16 位账号密码
  4) 注册 systemd 服务并设置开机自启
  5) 通过 systemd timer 每日 03:00 自动重启
  6) 菜单「一键配置」可选择传统 TCP、gRPC over HTTP/2 或 PHT-over-HTTP3 传输方案
  7) 幂等执行，可重复运行
  - 可选：通过环境变量 HTTP_PROXY_AGENT 或脚本内 DEFAULT_HTTP_PROXY_AGENT 自定义 HTTP 代理响应头 Proxy-Agent（见 https://gost.run/en/tutorials/protocols/http/ ）
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 运行，或通过 sudo 执行。"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_pkg_manager() {
  if command_exists apt-get; then
    echo "apt"
  elif command_exists dnf; then
    echo "dnf"
  elif command_exists yum; then
    echo "yum"
  else
    err "未检测到支持的包管理器（apt/dnf/yum）。"
    exit 1
  fi
}

install_dependencies() {
  local pm
  pm="$(detect_pkg_manager)"
  local missing=()
  local deps=(curl tar gzip sed awk ss systemctl)
  local dep
  for dep in "${deps[@]}"; do
    if ! command_exists "$dep"; then
      missing+=("$dep")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return
  fi

  warn "缺少依赖: ${missing[*]}，正在安装..."
  case "$pm" in
    apt)
      apt-get update -y
      apt-get install -y curl tar gzip sed gawk iproute2 systemd
      ;;
    dnf)
      dnf install -y curl tar gzip sed gawk iproute systemd
      ;;
    yum)
      yum install -y curl tar gzip sed gawk iproute systemd
      ;;
  esac
}

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$os" in
    linux) PLATFORM_OS="linux" ;;
    darwin) PLATFORM_OS="darwin" ;;
    *)
      err "不支持的操作系统: ${os}"
      exit 1
      ;;
  esac

  case "$arch" in
    x86_64|amd64) PLATFORM_ARCH="amd64" ;;
    aarch64|arm64) PLATFORM_ARCH="arm64" ;;
    armv7l|armv7) PLATFORM_ARCH="armv7" ;;
    armv6l|armv6) PLATFORM_ARCH="armv6" ;;
    armv5l|armv5) PLATFORM_ARCH="armv5" ;;
    i386|i686) PLATFORM_ARCH="386" ;;
    *)
      err "不支持的 CPU 架构: ${arch}"
      exit 1
      ;;
  esac
}

latest_release_json() {
  curl -fsSL "https://api.github.com/repos/go-gost/gost/releases/latest"
}

extract_tag_name() {
  sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -n1
}

extract_asset_url() {
  local os="$1" arch="$2"
  sed -nE 's/^[[:space:]]*"browser_download_url":[[:space:]]*"([^"]+)".*/\1/p' \
    | grep -E "gost(_[0-9][^/]*_${os}_${arch}\\.tar\\.gz|-${os}-${arch}[-._0-9A-Za-z]*\\.gz)$" \
    | grep -Ev 'checksums|sha256|\.sig' \
    | head -n1
}

fallback_asset_url() {
  local tag="$1" os="$2" arch="$3"
  local version
  version="${tag#v}"
  # gost v3 官方当前常见命名
  echo "https://github.com/go-gost/gost/releases/download/${tag}/gost_${version}_${os}_${arch}.tar.gz"
}

extract_version_from_tag() {
  local tag="$1"
  echo "${tag#v}"
}

random_16() {
  local out
  out="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  while [[ "${#out}" -lt 16 ]]; do
    out="${out}$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c $((16 - ${#out})) || true)"
  done
  printf '%s' "${out:0:16}"
}

# 代理账号默认用户名：user_ + 随机 6～8 位十进制数字
random_proxy_username() {
  local len=$((RANDOM % 3 + 6)) i d=""
  for ((i = 0; i < len; i++)); do
    d+=$((RANDOM % 10))
  done
  printf 'user_%s' "$d"
}

normalize_transport() {
  local t="${1:-tcp}"
  case "$t" in
    tcp|traditional|http|socks5) echo "tcp" ;;
    grpc|http2|h2) echo "grpc" ;;
    h3|http3|pht|pht-h3) echo "h3" ;;
    *) echo "tcp" ;;
  esac
}

transport_label() {
  case "$(normalize_transport "${1:-tcp}")" in
    grpc) echo "gRPC over HTTP/2" ;;
    h3) echo "PHT-over-HTTP3" ;;
    *) echo "传统 HTTP/SOCKS over TCP" ;;
  esac
}

choose_transport_interactive() {
  local input
  echo "请选择传输方案："
  echo "  1) 传统 HTTP/SOCKS over TCP（普通客户端可直接使用，默认）"
  echo "  2) gRPC over HTTP/2（需 gost-client-forwarder 暴露标准 HTTP/SOCKS）"
  echo "  3) PHT-over-HTTP3（需 gost-client-forwarder，且需放行 UDP 端口）"
  read -r -p "请选择 [1-3] (默认 1): " input
  case "${input:-1}" in
    1) REPLY_TRANSPORT="tcp" ;;
    2) REPLY_TRANSPORT="grpc" ;;
    3) REPLY_TRANSPORT="h3" ;;
    *) warn "无效选项，已使用传统 TCP。"; REPLY_TRANSPORT="tcp" ;;
  esac
}

# 状态页/示例 URL 优先使用公网 IPv4（失败则回退本机第一 IPv4）
fetch_display_public_ip() {
  local pub=""
  if command_exists curl; then
    pub="$(curl -4fsS --connect-timeout 3 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$pub" ]] || pub="$(curl -4fsS --connect-timeout 3 --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)"
  fi
  pub="$(printf '%s' "$pub" | tr -d '\r\n[:space:]')"
  if [[ -z "$pub" ]] || [[ ! "$pub" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    pub="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ -n "$pub" ]] || pub="127.0.0.1"
  printf '%s' "$pub"
}

# 交互：监听端口，回车使用建议值（须 1-65535 且未被占用）
# 参数: 建议端口 [排除的已选端口] [提示前缀，如 "HTTP 代理 "]
read_listen_port_with_default() {
  local suggest="$1" exclude="${2:-}" label="${3:-}" input pfx=""
  [[ -n "$label" ]] && pfx="${label}"
  while true; do
    read -r -p "${pfx}监听端口 (回车默认随机 ${suggest}, 范围 1-65535): " input
    if [[ -z "$input" ]]; then
      LISTEN_PORT="$suggest"
    else
      LISTEN_PORT="$input"
    fi
    if [[ -n "$exclude" ]] && [[ "$LISTEN_PORT" == "$exclude" ]]; then
      warn "不能与已选端口 ${exclude} 相同。"
      suggest="$(random_free_port_20000_30000)"
      while [[ -n "$exclude" ]] && [[ "$suggest" == "$exclude" ]]; do
        suggest="$(random_free_port_20000_30000)"
      done
      continue
    fi
    if [[ ! "$LISTEN_PORT" =~ ^[0-9]+$ ]] || ((LISTEN_PORT < 1 || LISTEN_PORT > 65535)); then
      warn "端口须为 1-65535 的整数。"
      suggest="$(random_free_port_20000_30000)"
      while [[ -n "$exclude" ]] && [[ "$suggest" == "$exclude" ]]; do
        suggest="$(random_free_port_20000_30000)"
      done
      continue
    fi
    if is_port_used "$LISTEN_PORT"; then
      warn "端口 ${LISTEN_PORT} 已被占用（含本机监听或已有配置），请更换。"
      suggest="$(random_free_port_20000_30000)"
      while [[ -n "$exclude" ]] && [[ "$suggest" == "$exclude" ]]; do
        suggest="$(random_free_port_20000_30000)"
      done
      continue
    fi
    return 0
  done
}

# 交互：代理用户名，回车使用 user_+随机数字
read_proxy_username_with_default() {
  local def="$1" label="${2:-}" input pfx=""
  [[ -n "$label" ]] && pfx="${label}"
  read -r -p "${pfx}用户名 (回车默认 ${def}): " input
  if [[ -z "$input" ]]; then
    REPLY_USER="$def"
    return 0
  fi
  if [[ ! "$input" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    err "用户名仅允许字母、数字及 _ . -"
    return 1
  fi
  REPLY_USER="$input"
  return 0
}



is_gost_binary_installed() {
  [[ -x "$GOST_BIN" ]]
}

is_default_install_layout() {
  [[ -x "$GOST_BIN" ]] || return 1
  [[ -f "$GOST_SERVICE" ]] || return 1
  [[ -f "$GOST_TIMER" ]] || return 1
  grep -q '^ExecStart=/usr/bin/gost -C /etc/gost/config.yaml$' "$GOST_SERVICE"
}

get_installed_version() {
  if [[ ! -x "$GOST_BIN" ]]; then
    return 1
  fi
  local raw line v
  raw="$("$GOST_BIN" -V 2>/dev/null)" || return 1
  line="$(printf '%s\n' "$raw" | head -n1 | tr -d '\r')"
  [[ -n "$line" ]] || return 1
  # gost v3 常见输出形如: gost version 3.2.6 (go1.25.4 linux/amd64)
  # 旧写法 .*([0-9]+\.[0-9]+\.[0-9]+) 会误抓到 go 工具链的 1.25.4，导致永远判定为「有新版」
  v="$(printf '%s\n' "$line" | sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*\(go.*/\1/p')"
  [[ -n "$v" ]] || v="$(printf '%s\n' "$line" | sed -nE 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

choose_port_interactive() {
  local p="$1"
  while true; do
    read -r -p "请输入监听端口 (默认 ${p}): " LISTEN_PORT
    LISTEN_PORT="${LISTEN_PORT:-$p}"
    if [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && ((LISTEN_PORT >= 1 && LISTEN_PORT <= 65535)); then
      return
    fi
    warn "端口必须是 1-65535 的整数。"
  done
}

random_port_20000_30000() {
  echo $((RANDOM % 10001 + 20000))
}

is_port_used() {
  local p="$1"
  if [[ -f "$PROXY_DB" ]] && grep -qE "^[^|]+\|${p}\|" "$PROXY_DB"; then
    return 0
  fi
  ss -lntup 2>/dev/null | grep -qE "[:.]${p}\b"
}

random_free_port_20000_30000() {
  local p tries=0
  while ((tries < 50)); do
    p="$(random_port_20000_30000)"
    if ! is_port_used "$p"; then
      echo "$p"
      return
    fi
    tries=$((tries + 1))
  done
  err "无法找到可用随机端口（20000-30000）。"
  exit 1
}

init_proxy_db() {
  mkdir -p "$GOST_DIR"
  chmod 750 "$GOST_DIR"
  touch "$PROXY_DB"
  chmod 600 "$PROXY_DB"
}

write_runtime_state() {
  cat >"$STATE_FILE" <<EOF
INSTALL_TIME=$(date '+%F %T %z')
VERSION=${GOST_VERSION}
EOF
  chmod 600 "$STATE_FILE"
}

write_env_summary() {
  local proxy_type="$1" port="$2" user="$3" pass="$4"
  cat >"$GOST_ENV" <<EOF
PROXY_TYPE=${proxy_type}
LISTEN_PORT=${port}
GOST_USER=${user}
GOST_PASS=${pass}
CONFIG_FILE=${GOST_CONFIG}
EOF
  chmod 600 "$GOST_ENV"
}



write_config_from_db() {
  init_proxy_db
  local n
  n="$(grep -cE '^(http|socks5)\|' "$PROXY_DB" 2>/dev/null || true)"
  n="${n//[^0-9]/}"
  [[ -z "$n" ]] && n=0
  if ((n == 0)); then
    warn "当前没有代理条目，已写入空服务。"
    cat >"$GOST_CONFIG" <<'EOF'
services: []

log:
  output: stderr
  level: info
EOF
    chmod 640 "$GOST_CONFIG"
    return 0
  fi

  local type port user pass transport _extra PA
  PA="${HTTP_PROXY_AGENT:-${DEFAULT_HTTP_PROXY_AGENT:-}}"
  PA="${PA//\"/}"
  {
    echo "services:"
    while IFS='|' read -r type port user pass transport _extra; do
      [[ -z "${type:-}" ]] && continue
      [[ "$type" == "http" || "$type" == "socks5" ]] || continue
      transport="$(normalize_transport "${transport:-tcp}")"
      cat <<EOF
  - name: proxy-${type}-${transport}-${port}
    addr: ":${port}"
    handler:
      type: ${type}
EOF
      if [[ "$type" == "socks5" && "$transport" == "tcp" ]]; then
        cat <<EOF
      metadata:
        notls: true
EOF
      fi
      cat <<EOF
      auth:
        username: "${user}"
        password: "${pass}"
EOF
      if [[ "$type" == "http" && -n "${PA}" ]]; then
        cat <<EOF
      header:
        Proxy-Agent: "${PA}"
EOF
      fi
      cat <<EOF
    listener:
      type: ${transport}
EOF
      if [[ "$transport" == "grpc" ]]; then
        cat <<EOF
      metadata:
        path: ${DEFAULT_GRPC_PATH}
EOF
      elif [[ "$transport" == "h3" ]]; then
        cat <<EOF
      metadata:
        authorizePath: ${DEFAULT_H3_AUTHORIZE_PATH}
        pushPath: ${DEFAULT_H3_PUSH_PATH}
        pullPath: ${DEFAULT_H3_PULL_PATH}
EOF
      fi
    done <"$PROXY_DB"

    echo ""
    cat <<'EOF'
log:
  output: stderr
  level: info
EOF
  } >"$GOST_CONFIG"
  chmod 640 "$GOST_CONFIG"

  return 0
}

print_client_forwarder_defaults_block() {
  local transport="$1" http_host="$2" http_port="$3" http_user="$4" http_pass="$5" http_type="$6" socks_host="$7" socks_port="$8" socks_user="$9" socks_pass="${10}" socks_type="${11}"
  [[ -n "$socks_host" ]] || socks_host="$http_host"
  [[ -n "$socks_port" ]] || socks_port="$http_port"
  [[ -n "$socks_user" ]] || socks_user="$http_user"
  [[ -n "$socks_pass" ]] || socks_pass="$http_pass"
  [[ -n "$socks_type" ]] || socks_type="$http_type"
  printf '%b\n' "${BOLD}${YELLOW}▶ 可复制到 gost-client-forwarder.sh 的默认变量块${RESET}"
  cat <<EOF
DEFAULT_HTTP_UPSTREAM_HOST="${http_host}"
DEFAULT_HTTP_UPSTREAM_PORT="${http_port}"
DEFAULT_HTTP_UPSTREAM_USER="${http_user}"
DEFAULT_HTTP_UPSTREAM_PASS="${http_pass}"
DEFAULT_HTTP_UPSTREAM_PROXY_TYPE="${http_type}"

DEFAULT_SOCKS_UPSTREAM_HOST="${socks_host}"
DEFAULT_SOCKS_UPSTREAM_PORT="${socks_port}"
DEFAULT_SOCKS_UPSTREAM_USER="${socks_user}"
DEFAULT_SOCKS_UPSTREAM_PASS="${socks_pass}"
DEFAULT_SOCKS_UPSTREAM_PROXY_TYPE="${socks_type}"

DEFAULT_UPSTREAM_TRANSPORT="${transport}"
DEFAULT_GRPC_PATH="${DEFAULT_GRPC_PATH}"
DEFAULT_H3_AUTHORIZE_PATH="${DEFAULT_H3_AUTHORIZE_PATH}"
DEFAULT_H3_PUSH_PATH="${DEFAULT_H3_PUSH_PATH}"
DEFAULT_H3_PULL_PATH="${DEFAULT_H3_PULL_PATH}"
EOF
}

print_client_forwarder_hint() {
  local type="$1" port="$2" user="$3" pass="$4" transport="$5"
  local ip cmd extra_args=""
  ip="$(fetch_display_public_ip)"
  [[ "$transport" == "grpc" ]] && extra_args=" --grpc-path ${DEFAULT_GRPC_PATH}"
  [[ "$transport" == "h3" ]] && extra_args=" --h3-authorize-path ${DEFAULT_H3_AUTHORIZE_PATH} --h3-push-path ${DEFAULT_H3_PUSH_PATH} --h3-pull-path ${DEFAULT_H3_PULL_PATH}"
  cmd="sudo ./gost-client-forwarder.sh --setup --upstream-transport ${transport} --upstream-proxy-type ${type} --upstream-host ${ip} --upstream-port ${port} --upstream-user ${user} --upstream-pass ${pass}${extra_args} --local-bind 0.0.0.0"
  printf '%b\n' "${BOLD}${YELLOW}▶ 客户端转发部署提示${RESET}"
  printf '  %b当前服务%b : %b%s%b / %b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$type" "$RESET" "$BOLD_GREEN" "$(transport_label "$transport")" "$RESET"
  printf '  %b说明%b     : 普通浏览器/curl 不能直接连接此端口，需要通过 gost-client-forwarder 暴露标准 HTTP/SOCKS5 地址。\n' "$BOLD" "$RESET"
  printf '  %b部署命令%b :\n' "$BOLD" "$RESET"
  printf '    %b%s%b\n' "$BOLD_GREEN" "$cmd" "$RESET"
  if [[ "$transport" == "h3" ]]; then
    printf '  %b注意%b     : %bPHT-over-HTTP3 需要服务端安全组/防火墙放行 UDP %s，并确认两端 GOST 版本支持 HTTP3。%b\n' "$BOLD" "$RESET" "$YELLOW" "$port" "$RESET"
  else
    printf '  %b注意%b     : %bgRPC over HTTP/2 需要服务端安全组/防火墙放行 TCP %s。%b\n' "$BOLD" "$RESET" "$YELLOW" "$port" "$RESET"
  fi
  echo
  print_client_forwarder_defaults_block "$transport" "$ip" "$port" "$user" "$pass" "$type" "" "" "" "" ""
}

print_proxy_example() {
  local type="$1" port="$2" user="$3" pass="$4" transport="$(normalize_transport "${5:-tcp}")"
  local ip
  ip="$(fetch_display_public_ip)"
  printf '%b\n' "${BOLD_GREEN}================ 代理配置信息 ================${RESET}"
  printf '  %b代理类型%b : %b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$type" "$RESET"
  printf '  %b传输方案%b : %b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$(transport_label "$transport")" "$RESET"
  printf '  %b监听端口%b : %b%s%b\n' "$BOLD" "$RESET" "$YELLOW" "$port" "$RESET"
  printf '  %b用户名%b   : %b%s%b\n' "$BOLD" "$RESET" "$YELLOW" "$user" "$RESET"
  printf '  %b密码%b     : %b%s%b\n' "$BOLD" "$RESET" "$YELLOW" "$pass" "$RESET"
  if [[ "$transport" != "tcp" ]]; then
    echo
    print_client_forwarder_hint "$type" "$port" "$user" "$pass" "$transport"
    printf '%b\n' "${BOLD_GREEN}================================================${RESET}"
    return 0
  fi
  printf '%b\n' "${BOLD}${GREEN}▶ 客户端示例${RESET}"
  if [[ "$type" == "http" ]]; then
    printf '  %bURL 方式%b : %bhttp://%s:%s@%s:%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$user" "$pass" "$ip" "$port" "$RESET"
    printf '  %bcurl 示例%b: %bcurl -x http://%s:%s@%s:%s https://api.ipify.org%b\n' "$BOLD" "$RESET" "$GREEN" "$user" "$pass" "$ip" "$port" "$RESET"
  else
    printf '  %bURL 方式%b : %bsocks5://%s:%s@%s:%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$user" "$pass" "$ip" "$port" "$RESET"
    printf '  %bcurl 示例%b: %bcurl --socks5 %s:%s --proxy-user %s:%s https://api.ipify.org%b\n' "$BOLD" "$RESET" "$GREEN" "$ip" "$port" "$user" "$pass" "$RESET"
    printf '  %b说明%b     : %bSOCKS 监听已禁用 GOST 专有 TLS 扩展，与普通 curl/浏览器兼容；HTTPS 走 socks5h 时 DNS 在代理侧解析%b\n' "$BOLD" "$RESET" "$YELLOW" "$RESET"
  fi
  printf '%b\n' "${BOLD_GREEN}================================================${RESET}"
}

upsert_proxy_record() {
  local type="$1" port="$2" user="$3" pass="$4" transport="$(normalize_transport "${5:-tcp}")"
  init_proxy_db
  if grep -qE "^[^|]+\|${port}\|" "$PROXY_DB"; then
    sed -i "/^[^|]\+|${port}|/d" "$PROXY_DB"
  fi
  echo "${type}|${port}|${user}|${pass}|${transport}" >>"$PROXY_DB"
}

# 系统级网络优化：针对 WARP(wgcf)/低 MTU 路径下的 PMTUD 黑洞，启用内核 MTU 探测 + MSS 钳位
apply_system_tweaks_for_gost() {
  local changed=0
  # 启用 TCP MTU 探测（0=关，1=基于 ICMP 黑洞探测，2=始终探测）
  if [[ "$(cat /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null)" != "1" ]]; then
    sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 && changed=1
  fi
  # 减小 base MSS 以适配 WARP(wgcf) 的 MTU 1280
  local cur_base
  cur_base="$(cat /proc/sys/net/ipv4/tcp_base_mss 2>/dev/null || echo 1024)"
  if (( cur_base > 1024 )); then
    sysctl -w net.ipv4.tcp_base_mss=1024 >/dev/null 2>&1 && changed=1
  fi
  if (( changed )); then
    # 写入 sysctl.d 以便重启后持久化
    local f=/etc/sysctl.d/99-gost-mtu.conf
    mkdir -p /etc/sysctl.d
    cat >"$f" <<'EOF'
# GOST: enable TCP MTU probing for WARP/wgcf path (MTU 1280)
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_base_mss=1024
EOF
    log "已应用内核 MTU 优化（tcp_mtu_probing=1, tcp_base_mss=1024），解决 WARP 低 MTU 路径下的 TLS 握手失败。"
  fi
}

apply_proxy_changes() {
  if write_config_from_db; then
    apply_system_tweaks_for_gost
    systemctl daemon-reload
    systemctl enable gost.service >/dev/null 2>&1 || true
    systemctl restart gost.service
    systemctl enable gost-restart.timer >/dev/null 2>&1 || true
    systemctl restart gost-restart.timer
  fi
}

# 根据 proxies.db 重写 /etc/gost/config.yaml 并重启 gost（与改代理后的逻辑一致）
regenerate_gost_config_and_restart() {
  require_root
  if ! is_default_install_layout; then
    err "未检测到脚本默认安装的 gost（/usr/bin/gost 与 gost.service）。请先使用菜单 1 安装。"
    return 1
  fi
  log "正在根据 ${PROXY_DB} 重新生成 ${GOST_CONFIG} 并重启服务..."
  apply_proxy_changes
  log "已完成：${GOST_CONFIG} 已刷新，gost.service 与 gost-restart.timer 已重启。"
}

list_proxy_db_pretty() {
  if [[ ! -s "$PROXY_DB" ]]; then
    echo "  （无条目）"
    return 0
  fi
  echo "[当前代理账户列表]"
  while IFS='|' read -r t po u p tr _rest; do
    [[ -z "${t:-}" ]] && continue
    tr="$(normalize_transport "${tr:-tcp}")"
    echo "  ${t}  端口=${po}  用户=${u}  密码=${p}  传输=$(transport_label "$tr")"
  done <"$PROXY_DB"
}

delete_proxy_by_port() {
  require_root
  init_proxy_db
  if [[ ! -w "$PROXY_DB" ]]; then
    err "无法写入 ${PROXY_DB}，请确认使用 root 执行。"
    return 1
  fi

  local p
  read -r -p "请输入要删除的监听端口号: " p
  if [[ ! "$p" =~ ^[0-9]+$ ]] || ((p < 1 || p > 65535)); then
    err "非法端口号。"
    return 1
  fi

  if ! grep -qE "^[^|]+\|${p}\|" "$PROXY_DB" 2>/dev/null; then
    err "未找到监听端口 ${p} 对应的代理账户。"
    return 1
  fi

  sed -i "/^[^|]*|${p}|/d" "$PROXY_DB"
  log "已删除端口 ${p} 对应的代理账户。"
  apply_proxy_changes
  list_proxy_db_pretty
}

add_http_proxy() {
  local port user pass transport
  choose_transport_interactive
  transport="$REPLY_TRANSPORT"
  port="$(random_free_port_20000_30000)"
  read_listen_port_with_default "$port" "" "HTTP 代理 " || return 1
  read_proxy_username_with_default "$(random_proxy_username)" "HTTP 代理 " || return 1
  user="$REPLY_USER"
  pass="$(random_16)"
  upsert_proxy_record "http" "$LISTEN_PORT" "$user" "$pass" "$transport"

  write_env_summary "http" "$LISTEN_PORT" "$user" "$pass"
  apply_proxy_changes
  print_proxy_example "http" "$LISTEN_PORT" "$user" "$pass" "$transport"
}

add_socks5_proxy() {
  local port user pass transport
  choose_transport_interactive
  transport="$REPLY_TRANSPORT"
  port="$(random_free_port_20000_30000)"
  read_listen_port_with_default "$port" "" "SOCKS5 代理 " || return 1
  read_proxy_username_with_default "$(random_proxy_username)" "SOCKS5 代理 " || return 1
  user="$REPLY_USER"
  pass="$(random_16)"

  upsert_proxy_record "socks5" "$LISTEN_PORT" "$user" "$pass" "$transport"
  write_env_summary "socks5" "$LISTEN_PORT" "$user" "$pass"
  apply_proxy_changes
  print_proxy_example "socks5" "$LISTEN_PORT" "$user" "$pass" "$transport"
}

one_click_configure_both() {
  local http_port socks_port http_user http_pass socks_user socks_pass transport
  if ! is_default_install_layout; then
    warn "检测到 gost 未就绪，先执行安装/升级。"
    install_or_upgrade_flow "skip_proxy_menu"
  fi
  choose_transport_interactive
  transport="$REPLY_TRANSPORT"
  http_port="$(random_free_port_20000_30000)"
  read_listen_port_with_default "$http_port" "" "HTTP 代理 " || return 1
  http_port="$LISTEN_PORT"

  socks_port="$(random_free_port_20000_30000)"
  while [[ "$socks_port" == "$http_port" ]]; do
    socks_port="$(random_free_port_20000_30000)"
  done
  read_listen_port_with_default "$socks_port" "$http_port" "SOCKS5 代理 " || return 1
  socks_port="$LISTEN_PORT"

  read_proxy_username_with_default "$(random_proxy_username)" "HTTP 代理 " || return 1
  http_user="$REPLY_USER"
  read_proxy_username_with_default "$(random_proxy_username)" "SOCKS5 代理 " || return 1
  socks_user="$REPLY_USER"

  http_pass="$(random_16)"
  socks_pass="$(random_16)"
  upsert_proxy_record "http" "$http_port" "$http_user" "$http_pass" "$transport"
  upsert_proxy_record "socks5" "$socks_port" "$socks_user" "$socks_pass" "$transport"

  write_env_summary "http+socks5" "${http_port},${socks_port}" "${http_user},${socks_user}" "${http_pass},${socks_pass}"
  apply_proxy_changes
  echo "--------------------------------------------------"
  print_proxy_example "http" "$http_port" "$http_user" "$http_pass" "$transport"
  echo
  print_proxy_example "socks5" "$socks_port" "$socks_user" "$socks_pass" "$transport"
  if [[ "$transport" != "tcp" ]]; then
    local ip
    ip="$(fetch_display_public_ip)"
    echo
    printf '%b\n' "${BOLD_GREEN}================ HTTP/SOCKS 双上游集中变量块 ================${RESET}"
    print_client_forwarder_defaults_block "$transport" "$ip" "$http_port" "$http_user" "$http_pass" "http" "$ip" "$socks_port" "$socks_user" "$socks_pass" "socks5"
    printf '%b\n' "${BOLD_GREEN}==============================================================${RESET}"
  fi
}

write_systemd_units() {
  mkdir -p "$GOST_LOG_DIR"
  chmod 755 "$GOST_LOG_DIR"

  cat >"$GOST_SERVICE" <<'EOF'
[Unit]
Description=Gost Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/gost -C /etc/gost/config.yaml
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=3s
StandardOutput=append:/var/log/gost/gost.log
StandardError=append:/var/log/gost/gost.err.log

[Install]
WantedBy=multi-user.target
EOF

  cat >"$GOST_RESTART_SERVICE" <<'EOF'
[Unit]
Description=Restart gost service daily

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart gost.service
EOF

  cat >"$GOST_TIMER" <<'EOF'
[Unit]
Description=Daily restart timer for gost at 03:00

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=gost-restart.service

[Install]
WantedBy=timers.target
EOF
}

stop_and_disable_service_if_exists() {
  if systemctl list-unit-files gost.service >/dev/null 2>&1; then
    systemctl stop gost.service >/dev/null 2>&1 || true
    systemctl disable gost.service >/dev/null 2>&1 || true
  fi
  if systemctl list-unit-files gost-restart.timer >/dev/null 2>&1; then
    systemctl stop gost-restart.timer >/dev/null 2>&1 || true
    systemctl disable gost-restart.timer >/dev/null 2>&1 || true
  fi
  if systemctl list-unit-files gost-restart.service >/dev/null 2>&1; then
    systemctl stop gost-restart.service >/dev/null 2>&1 || true
    systemctl disable gost-restart.service >/dev/null 2>&1 || true
  fi

  # 兜底清理：结束所有残留 gost 进程（含手动启动）
  if command_exists pkill; then
    pkill -x gost >/dev/null 2>&1 || true
    sleep 1
    pkill -9 -x gost >/dev/null 2>&1 || true
  else
    killall gost >/dev/null 2>&1 || true
    sleep 1
    killall -9 gost >/dev/null 2>&1 || true
  fi
}

remove_legacy_files() {
  rm -f "$GOST_BIN"
  rm -f "$GOST_BIN_ALT"
  rm -rf "$GOST_DIR"
  rm -rf "$GOST_LOG_DIR"
  rm -f "$GOST_SERVICE" "$GOST_RESTART_SERVICE" "$GOST_TIMER"

  # 常见遗留路径（兼容旧脚本）
  rm -f /usr/lib/systemd/system/gost.service
  rm -f /lib/systemd/system/gost.service

  # 尝试清理 crontab 中的历史重启任务（如果存在）
  if [[ -f /etc/crontab ]]; then
    sed -i '/gost.*systemctl restart gost/d' /etc/crontab || true
  fi
}

purge_all() {
  log "开始清理历史 gost 组件..."
  stop_and_disable_service_if_exists
  remove_legacy_files
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true
  log "清理完成。"
}

download_and_install_gost() {
  local release_json tag asset_url version tmpd archive_path extracted_path filename
  release_json="$(latest_release_json)"
  tag="$(printf "%s\n" "$release_json" | extract_tag_name)"
  [[ -n "$tag" ]] || { err "获取最新版本 tag 失败。"; exit 1; }
  version="$(extract_version_from_tag "$tag")"
  asset_url="$(printf "%s\n" "$release_json" | extract_asset_url "$PLATFORM_OS" "$PLATFORM_ARCH")"
  if [[ -z "$asset_url" ]]; then
    warn "API 资产解析失败，尝试使用标准命名兜底下载链接..."
    asset_url="$(fallback_asset_url "$tag" "$PLATFORM_OS" "$PLATFORM_ARCH")"
  fi

  log "检测到最新版本: ${tag}"
  log "下载资产: ${asset_url}"

  tmpd="$(mktemp -d)"

  filename="${asset_url##*/}"
  archive_path="${tmpd}/${filename}"
  if ! curl -fL --retry 3 --connect-timeout 15 -o "$archive_path" "$asset_url"; then
    err "下载失败: ${asset_url}"
    err "请检查网络连通性或 GitHub 访问限制。"
    exit 1
  fi

  if [[ "$filename" == *.tar.gz ]]; then
    tar -xzf "$archive_path" -C "$tmpd"
    extracted_path="$(find "$tmpd" -type f -name gost -print -quit)"
  elif [[ "$filename" == *.gz ]]; then
    gunzip -f "$archive_path"
    extracted_path="${archive_path%.gz}"
  else
    extracted_path="$archive_path"
  fi

  [[ -f "$extracted_path" ]] || { err "解压后未找到 gost 二进制。"; exit 1; }

  install -m 0755 "$extracted_path" "$GOST_BIN"
  ln -sfn "$GOST_BIN" "$GOST_BIN_ALT"
  GOST_VERSION="$version"
  log "gost 已安装到 ${GOST_BIN}"
  rm -rf "$tmpd"
}

enable_and_start_services() {
  systemctl daemon-reload
  systemctl enable gost.service >/dev/null 2>&1 || true
  if [[ -f "$GOST_CONFIG" ]]; then
    systemctl restart gost.service >/dev/null 2>&1 || true
  fi
  systemctl enable gost-restart.timer >/dev/null 2>&1 || true
  systemctl restart gost-restart.timer >/dev/null 2>&1 || true
}

print_examples() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  ip="${ip:-YOUR_SERVER_IP}"

  echo
  log "安装完成，结果如下："
  echo "--------------------------------------------------"
  echo "版本: $("$GOST_BIN" -V 2>/dev/null || echo "未知")"
  echo "服务状态:"
  systemctl --no-pager --full status gost.service | sed -n '1,10p' || true
  echo
  echo "定时器状态:"
  systemctl --no-pager --full status gost-restart.timer | sed -n '1,10p' || true
  echo
  echo "监听端口:"
  ss -lntup | grep -E "(:${LISTEN_PORT}\b|gost)" || warn "未检测到端口监听，请检查服务日志。"
  echo
  echo "账号信息:"
  echo "  代理类型 : ${PROXY_TYPE}"
  echo "  监听端口 : ${LISTEN_PORT}"
  echo "  用户名   : ${GOST_USER}"
  echo "  密码     : ${GOST_PASS}"
  echo
  echo "客户端示例:"
  if [[ "$PROXY_TYPE" == "http" ]]; then
    echo "  URL 方式 : http://${GOST_USER}:${GOST_PASS}@${ip}:${LISTEN_PORT}"
    echo "  curl 示例: curl -x http://${GOST_USER}:${GOST_PASS}@${ip}:${LISTEN_PORT} https://api.ipify.org"
  else
    echo "  URL 方式 : socks5://${GOST_USER}:${GOST_PASS}@${ip}:${LISTEN_PORT}"
    echo "  curl 示例: curl --socks5 ${ip}:${LISTEN_PORT} --proxy-user ${GOST_USER}:${GOST_PASS} https://api.ipify.org"
    echo "  说明     : SOCKS 已配置为与普通客户端兼容（禁用 GOST 专有 SOCKS TLS 扩展）；若客户端也使用 gost，仍可在客户端侧使用加密传输至本代理"
  fi
  echo "--------------------------------------------------"
}

pause_return_to_menu() {
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    return 0
  fi
  echo
  read -r -n1 -s -p "按任意键返回菜单..." _
  echo
  # 清屏，使下一屏菜单不叠在上一次输出之后（无 clear 时用 ANSI 兜底）
  if command -v clear >/dev/null 2>&1; then
    clear
  else
    printf '\033[2J\033[H'
  fi
}

show_status() {
  if ! command_exists systemctl; then
    err "当前系统不支持 systemd。"
    exit 1
  fi

  local active enabled pid version type port usr pwd transport _rest has_proxy=0
  active="$(systemctl is-active gost.service 2>/dev/null || echo "unknown")"
  enabled="$(systemctl is-enabled gost.service 2>/dev/null || echo "unknown")"
  pid="$(systemctl show gost.service -p MainPID --value 2>/dev/null || echo "-")"
  version="$([[ -x "$GOST_BIN" ]] && "$GOST_BIN" -V 2>/dev/null || echo "未知")"

  echo
  printf '%b\n' "${BOLD_GREEN}================ gost 当前状态 ================${RESET}"
  printf '  %b版本%b       : %b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$version" "$RESET"
  # printf '  %b服务状态%b   : ActiveState=%b%s%b; Enabled=%b%s%b; MainPID=%b%s%b\n' \
  #   "$BOLD" "$RESET" "$BOLD_GREEN" "$active" "$RESET" "$BOLD_GREEN" "$enabled" "$RESET" "$YELLOW" "$pid" "$RESET"
  printf '%b\n' "${BOLD_GREEN}================================================${RESET}"

  printf '%b\n' "${BOLD}${GREEN}▶ gost.service 状态${RESET}"
  systemctl --no-pager --full status gost.service | sed -n '1,10p' || true
  echo
  printf '%b\n' "${BOLD}${GREEN}▶ gost-restart.timer 状态${RESET}"
  systemctl --no-pager --full status gost-restart.timer | sed -n '1,10p' || true
  echo
  printf '%b\n' "${BOLD}${GREEN}▶ 当前监听端口${RESET}"
  ss -lntup | grep -E "(gost|:([0-9]+)\b)" | grep gost || warn "未检测到 gost 监听端口，请检查服务日志。"

  echo
  if [[ ! -r "$PROXY_DB" ]] || [[ ! -s "$PROXY_DB" ]]; then
    printf '%b\n' "${BOLD_GREEN}================ 代理配置列表 ================${RESET}"
    printf '  %b暂无代理条目%b：未配置或无法读取 %s，请确认使用 root 执行。\n' "$YELLOW" "$RESET" "$PROXY_DB"
    printf '%b\n' "${BOLD_GREEN}================================================${RESET}"
    return 0
  fi

  while IFS='|' read -r type port usr pwd transport _rest; do
    [[ -z "${type:-}" ]] && continue
    [[ "$type" == "http" || "$type" == "socks5" ]] || continue
    transport="$(normalize_transport "${transport:-tcp}")"
    has_proxy=1
    echo
    print_proxy_example "$type" "$port" "$usr" "$pwd" "$transport"
  done <"$PROXY_DB"

  if [[ "$has_proxy" -eq 0 ]]; then
    printf '  %b暂无有效代理条目%b：%s 中没有 http/socks5 记录。\n' "$YELLOW" "$RESET" "$PROXY_DB"
    printf '%b\n' "${BOLD_GREEN}================================================${RESET}"
  fi
}

install_or_upgrade_flow() {
  local mode="${1:-normal}"
  local latest_tag latest_version installed_version
  require_root
  install_dependencies
  detect_platform

  latest_tag="$(latest_release_json | extract_tag_name)"
  latest_version="$(extract_version_from_tag "$latest_tag")"

  if ! is_gost_binary_installed; then
    log "当前未安装 gost，开始安装。"
    purge_all
    download_and_install_gost
    write_systemd_units
    init_proxy_db
    write_runtime_state
    enable_and_start_services
  elif ! is_default_install_layout; then
    warn "检测到已有 gost 但不符合当前脚本默认路径，先清理再安装。"
    purge_all
    download_and_install_gost
    write_systemd_units
    init_proxy_db
    write_runtime_state
    enable_and_start_services
  else
    installed_version="$(get_installed_version || true)"
    if [[ "$installed_version" == "$latest_version" ]]; then
      log "当前已是最新版本 v${installed_version}，跳过升级。"
      GOST_VERSION="$installed_version"
    else
      log "检测到新版本 v${latest_version}（当前: v${installed_version:-unknown}），开始升级。"
      download_and_install_gost
      write_systemd_units
      write_runtime_state
      enable_and_start_services
    fi
  fi

  if [[ "$mode" != "skip_proxy_menu" ]]; then
    show_proxy_menu
  fi
}

# 主菜单「1) 安装/升级/卸载 gost」内展示的状态行
print_gost_release_status() {
  local latest_tag="$1" latest_version="$2"
  local installed_version="" layout_ok="未知"
  echo "------------- gost 安装状态 -------------"
  if is_gost_binary_installed; then
    installed_version="$(get_installed_version || echo unknown)"
    echo "  已安装: 是"
    echo "  当前版本: v${installed_version}"
    if is_default_install_layout; then
      layout_ok="是"
    else
      layout_ok="否（建议选子菜单 1 重新安装）"
    fi
    echo "  默认路径布局: ${layout_ok}"
  else
    echo "  已安装: 否"
  fi
  echo "  上游最新版本: v${latest_version}（${latest_tag}）"
  if [[ -n "${installed_version}" ]] && [[ "${installed_version}" != "unknown" ]]; then
    if [[ "${installed_version}" == "${latest_version}" ]]; then
      echo "  与上游对比: 已是最新"
    else
      echo "  与上游对比: 可升级至 v${latest_version}（请选子菜单 2）"
    fi
  fi
  echo "----------------------------------------"
}

gost_submenu_install() {
  if ! is_gost_binary_installed; then
    log "当前未安装 gost，开始安装。"
    purge_all
    download_and_install_gost
    write_systemd_units
    init_proxy_db
    write_runtime_state
    enable_and_start_services
    return 0
  fi
  if ! is_default_install_layout; then
    warn "检测到已有 gost 但不符合当前脚本默认路径，将清理后重新安装。"
    purge_all
    download_and_install_gost
    write_systemd_units
    init_proxy_db
    write_runtime_state
    enable_and_start_services
    return 0
  fi
  local iv
  iv="$(get_installed_version || echo unknown)"
  warn "已按默认路径安装 gost（当前 v${iv}），无需重复「安装」。请选「2) 升级 gost」或先「3) 完全卸载」后再安装。"
}

gost_submenu_upgrade() {
  if ! is_gost_binary_installed; then
    err "未安装 gost，请先执行「1) 安装 gost」。"
    return 1
  fi
  if ! is_default_install_layout; then
    err "当前安装不符合脚本默认路径，请先执行「1) 安装 gost」修复。"
    return 1
  fi
  local installed_version latest_tag latest_version
  latest_tag="$(latest_release_json | extract_tag_name)"
  latest_version="$(extract_version_from_tag "$latest_tag")"
  installed_version="$(get_installed_version || true)"
  if [[ "$installed_version" == "$latest_version" ]]; then
    log "当前已是最新版本 v${installed_version}，跳过升级。"
    GOST_VERSION="$installed_version"
    return 0
  fi
  log "检测到新版本 v${latest_version}（当前: v${installed_version:-unknown}），开始升级。"
  download_and_install_gost
  write_systemd_units
  write_runtime_state
  enable_and_start_services
}

gost_submenu_purge_full() {
  purge_all
  log "已完全卸载 gost（含代理配置与 systemd 单元）。"
}

show_gost_install_manage_submenu() {
  require_root
  install_dependencies
  detect_platform
  local latest_tag latest_version sub
  latest_tag="$(latest_release_json | extract_tag_name)"
  latest_version="$(extract_version_from_tag "$latest_tag")"
  while true; do
    print_gost_release_status "$latest_tag" "$latest_version"
    cat <<'EOF'
  1) 安装 gost
  2) 升级 gost
  3) 完全卸载 gost
  0) 返回主菜单
----------------------------------------
EOF
    read -r -p "请选择 [0-3]: " sub
    case "$sub" in
      1) gost_submenu_install || true ;;
      2) gost_submenu_upgrade || true ;;
      3) gost_submenu_purge_full ;;
      0|'') break ;;
      *) warn "无效选项，请重试。" ;;
    esac
    latest_tag="$(latest_release_json | extract_tag_name)"
    latest_version="$(extract_version_from_tag "$latest_tag")"
    pause_return_to_menu
  done
}

show_main_menu() {
  local choice
  while true; do
    cat <<'EOF'

================ gost-manager 菜单 ================
  1) 安装/升级/卸载 gost
  2) 一键配置 HTTP + SOCKS5（可选传统 TCP/gRPC/HTTP3）
  3) 添加 HTTP 代理（可选传统 TCP/gRPC/HTTP3）
  4) 添加 SOCKS5 代理（可选传统 TCP/gRPC/HTTP3）
  5) 查看服务状态
  6) 删除指定端口的代理账户
  7) 显示帮助
  8) 重新生成 config.yaml 并重启 gost
  0) 退出
===================================================
EOF
    read -r -p "请输入选项 [0-8] (默认 1): " choice
    choice="${choice:-1}"
    case "$choice" in
      1) show_gost_install_manage_submenu ;;
      2) require_root; one_click_configure_both || true ;;
      3) require_root; is_default_install_layout || install_or_upgrade_flow "skip_proxy_menu"; add_http_proxy || true ;;
      4) require_root; is_default_install_layout || install_or_upgrade_flow "skip_proxy_menu"; add_socks5_proxy || true ;;
      5) show_status ;;
      6) require_root; delete_proxy_by_port || true ;;
      7) usage ;;
      8) require_root; regenerate_gost_config_and_restart || true ;;
      0) log "已退出。"; break ;;
      *) err "无效选项: ${choice}" ;;
    esac
    pause_return_to_menu
  done
}

show_proxy_menu() {
  local c
  while true; do
    cat <<'EOF'
------------- 代理配置菜单 -------------
  1) 一键配置 HTTP + SOCKS5（可选传统 TCP/gRPC/HTTP3）
  2) 添加 HTTP 代理（可选传统 TCP/gRPC/HTTP3）
  3) 添加 SOCKS5 代理（可选传统 TCP/gRPC/HTTP3）
  4) 删除指定端口的代理账户
  5) 重新生成 config.yaml 并重启 gost
  0) 返回主菜单
----------------------------------------
EOF
    read -r -p "请选择 [0-5] (默认 1): " c
    c="${c:-1}"
    case "$c" in
      0) break ;;
      1) one_click_configure_both || true ;;
      2) add_http_proxy || true ;;
      3) add_socks5_proxy || true ;;
      4) delete_proxy_by_port || true ;;
      5) require_root; regenerate_gost_config_and_restart || true ;;
      *) warn "无效选项，请重试。" ;;
    esac
    pause_return_to_menu
  done
}

main() {
  local arg="${1:-}"
  case "$arg" in
    "")
      show_main_menu
      ;;
    --install)
      install_or_upgrade_flow "skip_proxy_menu"
      ;;
    --purge)
      require_root
      purge_all
      ;;
    --reload-config)
      regenerate_gost_config_and_restart
      ;;
    --status)
      show_status
      pause_return_to_menu
      ;;
    -h|--help)
      usage
      ;;
    *)
      err "未知参数: ${arg}"
      usage
      exit 1
      ;;
  esac
}

main "${1:-}"
