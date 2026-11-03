#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
GOST_BIN="/usr/bin/gost"
GOST_BIN_ALT="/usr/local/bin/gost"
GOST_DIR="/etc/gost-client"
CONFIG_FILE="${GOST_DIR}/config.yaml"
ENV_FILE="${GOST_DIR}/proxy.env"
STATE_FILE="${GOST_DIR}/state.env"
SERVICE_FILE="/etc/systemd/system/gost-client-forwarder.service"
RESTART_SERVICE_FILE="/etc/systemd/system/gost-client-forwarder-restart.service"
TIMER_FILE="/etc/systemd/system/gost-client-forwarder-restart.timer"

DEFAULT_LOCAL_HTTP_PORT=
DEFAULT_LOCAL_SOCKS_PORT=
# 本地代理认证用户名/密码默认值（留空时优先复用已安装的 state.env，否则随机生成）
# 凭据不写入本脚本：在脚本同目录的 gost-client-forwarder.local.env 中设置（已被 .gitignore 忽略）
DEFAULT_LOCAL_USER=""
DEFAULT_LOCAL_PASS=""

# 本机转发监听地址：127.0.0.1 仅本机；0.0.0.0 对所有网卡开放（需防火墙配合）
DEFAULT_LOCAL_BIND="127.0.0.1"
DEFAULT_AUTO_CONFIGURE_DOCKER=1

# ====== 可直接修改的默认变量（另一台机器拷贝后优先改这里）======
DEFAULT_HTTP_UPSTREAM_HOST=""
DEFAULT_HTTP_UPSTREAM_PORT=""
DEFAULT_HTTP_UPSTREAM_USER=""
DEFAULT_HTTP_UPSTREAM_PASS=""
DEFAULT_HTTP_UPSTREAM_PROXY_TYPE="http"

DEFAULT_SOCKS_UPSTREAM_HOST=""
DEFAULT_SOCKS_UPSTREAM_PORT=""
DEFAULT_SOCKS_UPSTREAM_USER=""
DEFAULT_SOCKS_UPSTREAM_PASS=""
DEFAULT_SOCKS_UPSTREAM_PROXY_TYPE="socks5"

DEFAULT_UPSTREAM_TRANSPORT="grpc"
DEFAULT_GRPC_PATH="/GostTunel/Tunnel"
DEFAULT_H3_AUTHORIZE_PATH="/authorize"
DEFAULT_H3_PUSH_PATH="/push"
DEFAULT_H3_PULL_PATH="/pull"

# 每日定时重启时间（systemd OnCalendar 语法），可在 local.env 中覆盖
DEFAULT_RESTART_ON_CALENDAR="*-*-* 03:10:00"

# 可通过 gost-client-forwarder.local.env 覆盖的全部参数（用于溯源与自检）
UPSTREAM_TRACKED_PARAMS=(
  DEFAULT_LOCAL_HTTP_PORT DEFAULT_LOCAL_SOCKS_PORT
  DEFAULT_LOCAL_USER DEFAULT_LOCAL_PASS
  DEFAULT_LOCAL_BIND DEFAULT_AUTO_CONFIGURE_DOCKER
  DEFAULT_HTTP_UPSTREAM_HOST DEFAULT_HTTP_UPSTREAM_PORT
  DEFAULT_HTTP_UPSTREAM_USER DEFAULT_HTTP_UPSTREAM_PASS
  DEFAULT_HTTP_UPSTREAM_PROXY_TYPE
  DEFAULT_SOCKS_UPSTREAM_HOST DEFAULT_SOCKS_UPSTREAM_PORT
  DEFAULT_SOCKS_UPSTREAM_USER DEFAULT_SOCKS_UPSTREAM_PASS
  DEFAULT_SOCKS_UPSTREAM_PROXY_TYPE
  DEFAULT_UPSTREAM_TRANSPORT DEFAULT_GRPC_PATH
  DEFAULT_H3_AUTHORIZE_PATH DEFAULT_H3_PUSH_PATH DEFAULT_H3_PULL_PATH
  DEFAULT_RESTART_ON_CALENDAR
  UPSTREAM_PRECHECK_MODE UPSTREAM_AUTH_REQUIRED
)

# 本机私有覆盖（上游/本地账号口令等敏感默认值），不入库；可用 GOST_LOCAL_ENV_FILE 指定其他路径
GOST_LOCAL_ENV_FILE="${GOST_LOCAL_ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gost-client-forwarder.local.env}"

# source 之前先快照，用于判定每个参数究竟是「脚本默认」还是「local.env 覆盖」
declare -A LOCAL_ENV_SNAPSHOT=()
LOCAL_ENV_FILE_LOADED=0
LOCAL_ENV_DECLARED_KEYS=()   # 文件里显式出现的键
LOCAL_ENV_SET_KEYS=()        # 最终判定为「由 local.env 提供」的键

# 校验 local.env 的书写合法性。
# bash -n 只能发现真正的语法错误；而 `KEY=a b` 这种「值含空格未加引号」是合法语法，
# 却会在 source 时把 b 当命令执行（报 command not found）。故额外做行级 lint。
_validate_local_env_file() {
  local f="$1" line lineno=0 head tail rest
  local -a bad=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=(.*)$ ]]; then
      rest="${BASH_REMATCH[2]}"
      case "$rest" in
        \"*|\'*) continue ;;            # 已加引号
        '')      continue ;;            # 空值
      esac
      if [[ "$rest" == *[[:space:]]* ]]; then
        head="${rest%%[[:space:]]*}"
        tail="${rest#"$head"}"
        tail="${tail#"${tail%%[![:space:]]*}"}"   # 去掉前导空白
        if [[ -n "$tail" && "$tail" != \#* ]]; then
          bad+=("第 ${lineno} 行: ${line}")
        fi
      fi
    fi
  done <"$f"

  if ((${#bad[@]} > 0)); then
    printf '\033[31m[ERROR]\033[0m %s 存在「值含空格但未加引号」的配置，source 时会把它当成命令执行。\n' "$f" >&2
    local b
    for b in "${bad[@]}"; do printf '  %s\n' "$b" >&2; done
    printf '  修复方式：给值加引号，例如 DEFAULT_RESTART_ON_CALENDAR="*-*-* 03:10:00"\n' >&2
    exit 1
  fi
}

if [[ -f "$GOST_LOCAL_ENV_FILE" ]]; then
  LOCAL_ENV_FILE_LOADED=1
  if ! LOCAL_ENV_SYNTAX_ERR="$(bash -n "$GOST_LOCAL_ENV_FILE" 2>&1)"; then
    printf '\033[31m[ERROR]\033[0m %s 存在语法错误，已中止。\n' "$GOST_LOCAL_ENV_FILE" >&2
    [[ -n "$LOCAL_ENV_SYNTAX_ERR" ]] && printf '  %s\n' "$LOCAL_ENV_SYNTAX_ERR" >&2
    exit 1
  fi
  _validate_local_env_file "$GOST_LOCAL_ENV_FILE"
  # 先静态解析文件里显式声明的键：即使值与脚本默认相同，也算「来自 local.env」
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    if [[ "$_line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
      LOCAL_ENV_DECLARED_KEYS+=("${BASH_REMATCH[2]}")
    fi
  done <"$GOST_LOCAL_ENV_FILE"

  for _k in "${UPSTREAM_TRACKED_PARAMS[@]}"; do
    LOCAL_ENV_SNAPSHOT["$_k"]="${!_k-}"
  done
  # shellcheck disable=SC1090
  source "$GOST_LOCAL_ENV_FILE"

  for _k in "${UPSTREAM_TRACKED_PARAMS[@]}"; do
    # 命中任一条件即认为来自 local.env：文件中显式声明，或值确实发生了变化
    _declared=0
    if ((${#LOCAL_ENV_DECLARED_KEYS[@]} > 0)); then
      for _d in "${LOCAL_ENV_DECLARED_KEYS[@]}"; do
        [[ "$_d" == "$_k" ]] && { _declared=1; break; }
      done
    fi
    if ((_declared == 1)) || [[ "${!_k-}" != "${LOCAL_ENV_SNAPSHOT[$_k]-}" ]]; then
      LOCAL_ENV_SET_KEYS+=("$_k")
    fi
  done
  unset _k _d _declared _line
fi

# 上游预检策略（放在 source 之后，因此可在 local.env 中覆盖）
#   UPSTREAM_PRECHECK_MODE=lenient  两组至少完整配置一组（默认）
#   UPSTREAM_PRECHECK_MODE=strict   8 项全部必填
#   UPSTREAM_AUTH_REQUIRED=1        上游账号口令必填（默认）
#   UPSTREAM_AUTH_REQUIRED=0        允许免认证上游，账号口令缺失仅告警
UPSTREAM_PRECHECK_MODE="${UPSTREAM_PRECHECK_MODE:-lenient}"
UPSTREAM_AUTH_REQUIRED="${UPSTREAM_AUTH_REQUIRED:-1}"

# ============================================================

RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
CYAN="$(printf '\033[36m')"
BOLD="$(printf '\033[1m')"
BOLD_GREEN="$(printf '\033[1;32m')"
BOLD_YELLOW="$(printf '\033[1;33m')"
BOLD_CYAN="$(printf '\033[1;36m')"
RESET="$(printf '\033[0m')"

log() { printf "%s[%s]%s %s\n" "$GREEN" "INFO" "$RESET" "$*"; }
warn() { printf "%s[%s]%s %s\n" "$YELLOW" "WARN" "$RESET" "$*"; }
err() { printf "%s[%s]%s %s\n" "$RED" "ERROR" "$RESET" "$*" >&2; }

on_error() {
  local code=$?
  trap - ERR
  err "执行失败（exit=${code}）。"
  exit "$code"
}
trap on_error ERR

usage() {
  cat <<EOF
${SCRIPT_NAME} - gost 本地转发客户端（跨发行版）

用法:
  ${SCRIPT_NAME} --setup [参数...]
  ${SCRIPT_NAME} --status
  ${SCRIPT_NAME} --check-config
  ${SCRIPT_NAME} --stop
  ${SCRIPT_NAME} --start
  ${SCRIPT_NAME} --restart
  ${SCRIPT_NAME} --uninstall
  ${SCRIPT_NAME} -h|--help

核心参数（--setup 时可省略，省略则交互输入）:
  --upstream-transport TYPE    上游传输：tcp、grpc、h3，默认 ${DEFAULT_UPSTREAM_TRANSPORT}
  --http-upstream-host HOST    HTTP 本地入口专用上游地址
  --http-upstream-port PORT    HTTP 本地入口专用上游端口
  --http-upstream-user USER    HTTP 本地入口专用上游用户名
  --http-upstream-pass PASS    HTTP 本地入口专用上游密码
  --http-upstream-proxy-type TYPE  HTTP 本地入口专用上游类型：http、socks5
  --socks-upstream-host HOST   SOCKS5 本地入口专用上游地址
  --socks-upstream-port PORT   SOCKS5 本地入口专用上游端口
  --socks-upstream-user USER   SOCKS5 本地入口专用上游用户名
  --socks-upstream-pass PASS   SOCKS5 本地入口专用上游密码
  --socks-upstream-proxy-type TYPE SOCKS5 本地入口专用上游类型：http、socks5
  --grpc-path PATH             gRPC 请求路径，默认 ${DEFAULT_GRPC_PATH}
  --h3-authorize-path PATH     HTTP3/PHT 授权路径，默认 ${DEFAULT_H3_AUTHORIZE_PATH}
  --h3-push-path PATH          HTTP3/PHT 上行路径，默认 ${DEFAULT_H3_PUSH_PATH}
  --h3-pull-path PATH          HTTP3/PHT 下行路径，默认 ${DEFAULT_H3_PULL_PATH}
  --local-http-port PORT       本地 HTTP 转发端口，默认 ${DEFAULT_LOCAL_HTTP_PORT}
  --local-socks-port PORT      本地 SOCKS5 转发端口，默认 ${DEFAULT_LOCAL_SOCKS_PORT}
  --local-bind ADDR            监听地址：127.0.0.1（默认）或 0.0.0.0（全网卡）或本机某网卡 IPv4
  --local-user USER            对最终用户暴露的本地 HTTP/SOCKS 用户名，默认随机
  --local-pass PASS            对最终用户暴露的本地 HTTP/SOCKS 密码，默认随机
  --configure-docker           自动写入 docker systemd 代理配置并重启 docker
  --upstream-precheck-mode M   上游预检模式：lenient（默认，至少一组完整）| strict（8 项全填）
  --upstream-auth-optional     允许上游免认证：USER/PASS 缺失只告警，不中止
  --upstream-auth-required     要求上游 USER/PASS 必填（默认）
  --restart-on-calendar SPEC   每日重启时间（systemd OnCalendar），默认 ${DEFAULT_RESTART_ON_CALENDAR}
  --check-config               打印全部参数的生效值与来源（local.env / 脚本默认），敏感值脱敏

配置来源与优先级（高 → 低）:
  1) 命令行参数（仅本次执行生效）
  2) ${GOST_LOCAL_ENV_FILE##*/}
     脚本同目录、已被 .gitignore 忽略；全部 DEFAULT_* 及预检开关均可在此覆盖，
     相当于把本节所有参数集中到该文件维护，无需改脚本。
  3) 脚本顶部第 16-47 行的 DEFAULT_* 默认值

说明:
  1) 直接执行 ${SCRIPT_NAME} 或 ${SCRIPT_NAME} --setup 会自动配置、开机自启并启用每日定时重启。
  2) 推荐把 DEFAULT_HTTP_UPSTREAM_* 与 DEFAULT_SOCKS_UPSTREAM_* 统一写在
     ${GOST_LOCAL_ENV_FILE##*/} 中；改脚本顶部的同名变量仅作为兜底方式。
  3) --setup 会先做上游默认值预检；DEFAULT_HTTP_UPSTREAM_* / DEFAULT_SOCKS_UPSTREAM_*
     存在未赋值项时中止，不会写入任何配置或启动服务。预检策略见 --upstream-precheck-mode。
  4) --check-config 可列出每个参数的生效值与来源，用于确认 local.env 是否真的生效。

示例:
  ${SCRIPT_NAME} --setup --upstream-transport grpc --http-upstream-host 1.2.3.4 --http-upstream-port 28909 --http-upstream-user u1 --http-upstream-pass p1 --http-upstream-proxy-type http --socks-upstream-host 1.2.3.4 --socks-upstream-port 28910 --socks-upstream-user u2 --socks-upstream-pass p2 --socks-upstream-proxy-type socks5 --grpc-path /GostTunel/Tunnel
  ${SCRIPT_NAME} --setup --upstream-transport h3 --local-bind 0.0.0.0 --local-http-port 18080 --local-socks-port 18081 ...
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 运行。"
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
  elif command_exists pacman; then
    echo "pacman"
  else
    err "未检测到支持的包管理器（apt/dnf/yum/pacman）。"
    exit 1
  fi
}

install_dependencies() {
  local pm
  pm="$(detect_pkg_manager)"
  local need_install=0
  for c in curl tar sed grep systemctl ss; do
    if ! command_exists "$c"; then
      need_install=1
      break
    fi
  done
  [[ "$need_install" -eq 0 ]] && return

  warn "正在安装基础依赖..."
  case "$pm" in
    apt)
      apt-get update -y
      apt-get install -y curl tar sed grep iproute2 systemd
      ;;
    dnf)
      dnf install -y curl tar sed grep iproute systemd
      ;;
    yum)
      yum install -y curl tar sed grep iproute systemd
      ;;
    pacman)
      pacman -Sy --noconfirm curl tar sed grep iproute2 systemd
      ;;
  esac
}

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$os" in
    linux) PLATFORM_OS="linux" ;;
    *)
      err "暂仅支持 Linux，当前: ${os}"
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
    riscv64) PLATFORM_ARCH="riscv64" ;;
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
  local version="${tag#v}"
  echo "https://github.com/go-gost/gost/releases/download/${tag}/gost_${version}_${os}_${arch}.tar.gz"
}

random_16() {
  local out
  out="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  while [[ "${#out}" -lt 16 ]]; do
    out="${out}$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c $((16 - ${#out})) || true)"
  done
  printf '%s' "${out:0:16}"
}

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
    *) return 1 ;;
  esac
}

normalize_proxy_type() {
  local t="${1:-socks5}"
  case "$t" in
    http) echo "http" ;;
    socks|socks5) echo "socks5" ;;
    *) return 1 ;;
  esac
}

install_gost_if_needed() {
  if [[ -x "$GOST_BIN" ]]; then
    log "检测到 gost 已安装: $("$GOST_BIN" -V 2>/dev/null || echo unknown)"
    return
  fi

  local json tag url tmpd archive name
  json="$(latest_release_json)"
  tag="$(printf '%s\n' "$json" | extract_tag_name)"
  [[ -n "$tag" ]] || { err "无法获取最新版本号"; exit 1; }
  url="$(printf '%s\n' "$json" | extract_asset_url "$PLATFORM_OS" "$PLATFORM_ARCH")"
  [[ -n "$url" ]] || url="$(fallback_asset_url "$tag" "$PLATFORM_OS" "$PLATFORM_ARCH")"

  log "安装 gost ${tag}..."
  tmpd="$(mktemp -d)"
  archive="${tmpd}/gost.tar.gz"
  curl -fL --retry 3 --connect-timeout 15 -o "$archive" "$url"
  tar -xzf "$archive" -C "$tmpd"
  name="$(find "$tmpd" -type f -name gost -print -quit)"
  [[ -f "$name" ]] || { err "未找到 gost 二进制"; rm -rf "$tmpd"; exit 1; }
  install -m 0755 "$name" "$GOST_BIN"
  ln -sfn "$GOST_BIN" "$GOST_BIN_ALT"
  rm -rf "$tmpd"
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && ((p >= 1 && p <= 65535))
}

validate_bind_addr() {
  local a="$1"
  [[ -n "$a" ]] || return 1
  case "$a" in
    127.0.0.1|0.0.0.0) return 0 ;;
  esac
  if [[ "$a" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    return 0
  fi
  err "LOCAL_BIND_ADDR 非法（请使用 127.0.0.1、0.0.0.0 或本机 IPv4，如 10.0.0.5）"
  return 1
}

ensure_inputs() {
  LOCAL_HTTP_PORT="${LOCAL_HTTP_PORT:-$DEFAULT_LOCAL_HTTP_PORT}"
  LOCAL_SOCKS_PORT="${LOCAL_SOCKS_PORT:-$DEFAULT_LOCAL_SOCKS_PORT}"
  LOCAL_BIND_ADDR="${LOCAL_BIND_ADDR:-${DEFAULT_LOCAL_BIND:-127.0.0.1}}"
  UPSTREAM_TRANSPORT="$(normalize_transport "${UPSTREAM_TRANSPORT:-$DEFAULT_UPSTREAM_TRANSPORT}")" || { err "UPSTREAM_TRANSPORT 非法，仅支持 tcp/grpc/h3"; exit 1; }
  GRPC_PATH="${GRPC_PATH:-$DEFAULT_GRPC_PATH}"
  H3_AUTHORIZE_PATH="${H3_AUTHORIZE_PATH:-$DEFAULT_H3_AUTHORIZE_PATH}"
  H3_PUSH_PATH="${H3_PUSH_PATH:-$DEFAULT_H3_PUSH_PATH}"
  H3_PULL_PATH="${H3_PULL_PATH:-$DEFAULT_H3_PULL_PATH}"
  LOCAL_USER="${LOCAL_USER:-${DEFAULT_LOCAL_USER:-}}"
  LOCAL_PASS="${LOCAL_PASS:-${DEFAULT_LOCAL_PASS:-}}"
  # 重复执行 setup 时复用已安装的本地认证，避免依赖它的 BUILD_PROXY_URL 等配置失效
  if [[ ( -z "$LOCAL_USER" || -z "$LOCAL_PASS" ) && -r "$STATE_FILE" ]]; then
    [[ -n "$LOCAL_USER" ]] || LOCAL_USER="$(grep '^LOCAL_USER=' "$STATE_FILE" | cut -d= -f2- || true)"
    [[ -n "$LOCAL_PASS" ]] || LOCAL_PASS="$(grep '^LOCAL_PASS=' "$STATE_FILE" | cut -d= -f2- || true)"
  fi
  [[ -n "$LOCAL_USER" ]] || LOCAL_USER="$(random_proxy_username)"
  [[ -n "$LOCAL_PASS" ]] || LOCAL_PASS="$(random_16)"

  HTTP_UPSTREAM_HOST="${HTTP_UPSTREAM_HOST:-${DEFAULT_HTTP_UPSTREAM_HOST:-}}"
  HTTP_UPSTREAM_PORT="${HTTP_UPSTREAM_PORT:-${DEFAULT_HTTP_UPSTREAM_PORT:-}}"
  HTTP_UPSTREAM_USER="${HTTP_UPSTREAM_USER:-${DEFAULT_HTTP_UPSTREAM_USER:-}}"
  HTTP_UPSTREAM_PASS="${HTTP_UPSTREAM_PASS:-${DEFAULT_HTTP_UPSTREAM_PASS:-}}"
  HTTP_UPSTREAM_PROXY_TYPE="${HTTP_UPSTREAM_PROXY_TYPE:-${DEFAULT_HTTP_UPSTREAM_PROXY_TYPE:-http}}"

  SOCKS_UPSTREAM_HOST="${SOCKS_UPSTREAM_HOST:-${DEFAULT_SOCKS_UPSTREAM_HOST:-}}"
  SOCKS_UPSTREAM_PORT="${SOCKS_UPSTREAM_PORT:-${DEFAULT_SOCKS_UPSTREAM_PORT:-}}"
  SOCKS_UPSTREAM_USER="${SOCKS_UPSTREAM_USER:-${DEFAULT_SOCKS_UPSTREAM_USER:-}}"
  SOCKS_UPSTREAM_PASS="${SOCKS_UPSTREAM_PASS:-${DEFAULT_SOCKS_UPSTREAM_PASS:-}}"
  SOCKS_UPSTREAM_PROXY_TYPE="${SOCKS_UPSTREAM_PROXY_TYPE:-${DEFAULT_SOCKS_UPSTREAM_PROXY_TYPE:-socks5}}"

  if [[ -z "$HTTP_UPSTREAM_HOST" && -z "$SOCKS_UPSTREAM_HOST" ]]; then
    err "DEFAULT_HTTP_UPSTREAM_HOST 与 DEFAULT_SOCKS_UPSTREAM_HOST 至少需要配置一个。"
    exit 1
  fi

  if [[ -n "$HTTP_UPSTREAM_HOST" ]]; then
    HTTP_UPSTREAM_PROXY_TYPE="$(normalize_proxy_type "$HTTP_UPSTREAM_PROXY_TYPE")" || { err "HTTP_UPSTREAM_PROXY_TYPE 非法，仅支持 http/socks5"; exit 1; }
    validate_port "$HTTP_UPSTREAM_PORT" || { err "HTTP_UPSTREAM_PORT 非法"; exit 1; }
    [[ -n "$HTTP_UPSTREAM_USER" && -n "$HTTP_UPSTREAM_PASS" ]] || \
      warn "HTTP 上游未配置账号/口令（若上游需要认证，请在 ${GOST_LOCAL_ENV_FILE} 中设置 DEFAULT_HTTP_UPSTREAM_USER/PASS）"
  fi
  if [[ -n "$SOCKS_UPSTREAM_HOST" ]]; then
    SOCKS_UPSTREAM_PROXY_TYPE="$(normalize_proxy_type "$SOCKS_UPSTREAM_PROXY_TYPE")" || { err "SOCKS_UPSTREAM_PROXY_TYPE 非法，仅支持 http/socks5"; exit 1; }
    validate_port "$SOCKS_UPSTREAM_PORT" || { err "SOCKS_UPSTREAM_PORT 非法"; exit 1; }
    [[ -n "$SOCKS_UPSTREAM_USER" && -n "$SOCKS_UPSTREAM_PASS" ]] || \
      warn "SOCKS 上游未配置账号/口令（若上游需要认证，请在 ${GOST_LOCAL_ENV_FILE} 中设置 DEFAULT_SOCKS_UPSTREAM_USER/PASS）"
  fi
  validate_port "$LOCAL_HTTP_PORT" || { err "LOCAL_HTTP_PORT 非法"; exit 1; }
  validate_port "$LOCAL_SOCKS_PORT" || { err "LOCAL_SOCKS_PORT 非法"; exit 1; }
  validate_bind_addr "$LOCAL_BIND_ADDR" || exit 1

  if [[ "$LOCAL_BIND_ADDR" != "127.0.0.1" ]]; then
    warn "监听地址为 ${LOCAL_BIND_ADDR}：局域网/公网可达时，请务必配合防火墙/安全组仅放行可信来源；本地 HTTP/SOCKS 已启用用户名密码认证。"
  fi
}

append_upstream_chain() {
  local chain_name="$1" host="$2" port="$3" user="$4" pass="$5" proxy_type="$6"
  cat >>"$CONFIG_FILE" <<EOF
  - name: ${chain_name}
    hops:
      - name: hop-0
        nodes:
          - name: node-upstream
            addr: "${host}:${port}"
            connector:
              type: ${proxy_type}
              auth:
                username: "${user}"
                password: "${pass}"
EOF
  if [[ "$proxy_type" == "socks5" ]]; then
    cat >>"$CONFIG_FILE" <<EOF
              metadata:
                notls: true
EOF
  fi
  cat >>"$CONFIG_FILE" <<EOF
            dialer:
              type: ${UPSTREAM_TRANSPORT}
EOF
  if [[ "$UPSTREAM_TRANSPORT" == "grpc" ]]; then
    cat >>"$CONFIG_FILE" <<EOF
              metadata:
                path: ${GRPC_PATH}
EOF
  elif [[ "$UPSTREAM_TRANSPORT" == "h3" ]]; then
    cat >>"$CONFIG_FILE" <<EOF
              metadata:
                authorizePath: ${H3_AUTHORIZE_PATH}
                pushPath: ${H3_PUSH_PATH}
                pullPath: ${H3_PULL_PATH}
EOF
  fi
}

write_config() {
  mkdir -p "$GOST_DIR"
  # 目录需要允许普通用户读取 proxy.env（用于 source）
  chmod 755 "$GOST_DIR"

  local log_level="${GOST_CLIENT_LOG_LEVEL:-info}"

  cat >"$CONFIG_FILE" <<EOF
services:
EOF
  if [[ -n "$HTTP_UPSTREAM_HOST" ]]; then
    cat >>"$CONFIG_FILE" <<EOF
  - name: local-http
    addr: "${LOCAL_BIND_ADDR}:${LOCAL_HTTP_PORT}"
    handler:
      type: http
      auth:
        username: "${LOCAL_USER}"
        password: "${LOCAL_PASS}"
      chain: chain-upstream-http
    listener:
      type: tcp
      chain: chain-upstream-http

EOF
  fi
  if [[ -n "$SOCKS_UPSTREAM_HOST" ]]; then
    cat >>"$CONFIG_FILE" <<EOF
  - name: local-socks5
    addr: "${LOCAL_BIND_ADDR}:${LOCAL_SOCKS_PORT}"
    handler:
      type: socks5
      auth:
        username: "${LOCAL_USER}"
        password: "${LOCAL_PASS}"
      chain: chain-upstream-socks
    listener:
      type: tcp
      chain: chain-upstream-socks

EOF
  fi
  cat >>"$CONFIG_FILE" <<EOF
chains:
EOF
  if [[ -n "$HTTP_UPSTREAM_HOST" ]]; then
    append_upstream_chain "chain-upstream-http" "$HTTP_UPSTREAM_HOST" "$HTTP_UPSTREAM_PORT" "$HTTP_UPSTREAM_USER" "$HTTP_UPSTREAM_PASS" "$HTTP_UPSTREAM_PROXY_TYPE"
  fi
  if [[ -n "$SOCKS_UPSTREAM_HOST" ]]; then
    append_upstream_chain "chain-upstream-socks" "$SOCKS_UPSTREAM_HOST" "$SOCKS_UPSTREAM_PORT" "$SOCKS_UPSTREAM_USER" "$SOCKS_UPSTREAM_PASS" "$SOCKS_UPSTREAM_PROXY_TYPE"
  fi
  cat >>"$CONFIG_FILE" <<EOF

log:
  output: stderr
  level: ${log_level}
EOF
  chmod 640 "$CONFIG_FILE"
}

write_service() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Gost Local Forwarder Client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${GOST_BIN} -C ${CONFIG_FILE}
Restart=always
RestartSec=3s
# 不设 LimitNOFILE：部分环境禁止将 RLIMIT_NOFILE 提到百万级，会导致 status=205/LIMITS

[Install]
WantedBy=multi-user.target
EOF
}

write_restart_units() {
  cat >"$RESTART_SERVICE_FILE" <<EOF
[Unit]
Description=Restart gost client forwarder daily

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart gost-client-forwarder.service
EOF

  cat >"$TIMER_FILE" <<EOF
[Unit]
Description=Daily restart timer for gost client forwarder at ${RESTART_ON_CALENDAR}

[Timer]
OnCalendar=${RESTART_ON_CALENDAR}
Persistent=true
Unit=gost-client-forwarder-restart.service

[Install]
WantedBy=timers.target
EOF
}

write_env_file() {
  cat >"$ENV_FILE" <<EOF
# shell environment exports
EOF
  if [[ -n "$HTTP_UPSTREAM_HOST" ]]; then
    cat >>"$ENV_FILE" <<EOF
export http_proxy="http://${LOCAL_USER}:${LOCAL_PASS}@127.0.0.1:${LOCAL_HTTP_PORT}"
export https_proxy="http://${LOCAL_USER}:${LOCAL_PASS}@127.0.0.1:${LOCAL_HTTP_PORT}"
export HTTP_PROXY="http://${LOCAL_USER}:${LOCAL_PASS}@127.0.0.1:${LOCAL_HTTP_PORT}"
export HTTPS_PROXY="http://${LOCAL_USER}:${LOCAL_PASS}@127.0.0.1:${LOCAL_HTTP_PORT}"
EOF
  fi
  if [[ -n "$SOCKS_UPSTREAM_HOST" ]]; then
    cat >>"$ENV_FILE" <<EOF
export all_proxy="socks5h://${LOCAL_USER}:${LOCAL_PASS}@127.0.0.1:${LOCAL_SOCKS_PORT}"
export ALL_PROXY="socks5h://${LOCAL_USER}:${LOCAL_PASS}@127.0.0.1:${LOCAL_SOCKS_PORT}"
EOF
  fi
  cat >>"$ENV_FILE" <<EOF

# no proxy local addresses
export no_proxy="127.0.0.1,localhost"
export NO_PROXY="127.0.0.1,localhost"
EOF
  # proxy.env 不含上游账号密码，仅本地代理变量，允许普通用户读取
  chmod 644 "$ENV_FILE"

  cat >"$STATE_FILE" <<EOF
UPSTREAM_TRANSPORT=${UPSTREAM_TRANSPORT}
HTTP_UPSTREAM_HOST=${HTTP_UPSTREAM_HOST}
HTTP_UPSTREAM_PORT=${HTTP_UPSTREAM_PORT}
HTTP_UPSTREAM_USER=${HTTP_UPSTREAM_USER}
HTTP_UPSTREAM_PROXY_TYPE=${HTTP_UPSTREAM_PROXY_TYPE}
SOCKS_UPSTREAM_HOST=${SOCKS_UPSTREAM_HOST}
SOCKS_UPSTREAM_PORT=${SOCKS_UPSTREAM_PORT}
SOCKS_UPSTREAM_USER=${SOCKS_UPSTREAM_USER}
SOCKS_UPSTREAM_PROXY_TYPE=${SOCKS_UPSTREAM_PROXY_TYPE}
LOCAL_BIND_ADDR=${LOCAL_BIND_ADDR}
LOCAL_HTTP_PORT=${LOCAL_HTTP_PORT}
LOCAL_SOCKS_PORT=${LOCAL_SOCKS_PORT}
LOCAL_USER=${LOCAL_USER}
LOCAL_PASS=${LOCAL_PASS}
INSTALL_TIME=$(date '+%F %T %z')
EOF
  chmod 600 "$STATE_FILE"
}

configure_docker_proxy() {
  if [[ -z "$HTTP_UPSTREAM_HOST" ]]; then
    warn "未配置 HTTP 上游，未创建本地 HTTP 入口，跳过 Docker HTTP_PROXY 配置。"
    return 0
  fi
  local dir="/etc/systemd/system/docker.service.d"
  mkdir -p "$dir"
  cat >"${dir}/http-proxy.conf" <<EOF
[Service]
Environment="HTTP_PROXY=http://${LOCAL_USER}:${LOCAL_PASS}@127.0.0.1:${LOCAL_HTTP_PORT}"
Environment="HTTPS_PROXY=http://${LOCAL_USER}:${LOCAL_PASS}@127.0.0.1:${LOCAL_HTTP_PORT}"
Environment="NO_PROXY=127.0.0.1,localhost"
EOF

  systemctl daemon-reload
  if systemctl list-unit-files docker.service >/dev/null 2>&1; then
    systemctl restart docker || warn "docker 重启失败，请手动检查。"
  else
    warn "未检测到 docker.service，已写入配置，后续安装 docker 后可直接生效。"
  fi
}

start_service() {
  systemctl daemon-reload
  systemctl enable gost-client-forwarder.service
  systemctl restart gost-client-forwarder.service
  systemctl enable gost-client-forwarder-restart.timer >/dev/null 2>&1 || true
  systemctl restart gost-client-forwarder-restart.timer >/dev/null 2>&1 || true
}

stop_service() {
  systemctl stop gost-client-forwarder.service >/dev/null 2>&1 || true
}

status_service() {
  systemctl --no-pager --full status gost-client-forwarder.service || true
  echo
  systemctl --no-pager --full status gost-client-forwarder-restart.timer || true
  echo
  if [[ -f "$STATE_FILE" ]]; then
    log "当前配置:"
    sed -n '1,80p' "$STATE_FILE"
  fi
  echo
  ss -lntup | grep -E "(gost|:${DEFAULT_LOCAL_HTTP_PORT}\b|:${DEFAULT_LOCAL_SOCKS_PORT}\b|:18[0-9]{3}\b)" || true
}

print_usage_snippets() {
  printf '\n%b\n' "${BOLD_GREEN}================ 最终代理使用信息 ================${RESET}"
  printf '%b\n' "${BOLD_CYAN}▶ 本机使用（本机连本机转发，与监听地址无关，推荐）${RESET}"
  if [[ -n "$HTTP_UPSTREAM_HOST" ]]; then
    printf '  %bHTTP%b   : %bhttp://%s:%s@127.0.0.1:%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$LOCAL_USER" "$LOCAL_PASS" "$LOCAL_HTTP_PORT" "$RESET"
  fi
  if [[ -n "$SOCKS_UPSTREAM_HOST" ]]; then
    printf '  %bSOCKS5%b : %bsocks5://%s:%s@127.0.0.1:%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$LOCAL_USER" "$LOCAL_PASS" "$LOCAL_SOCKS_PORT" "$RESET"
  fi
  printf '\n%b\n' "${BOLD_CYAN}▶ 对外使用（仅当 --local-bind 为 0.0.0.0 或本机某网卡 IP 时）${RESET}"
  printf '  %b说明%b   : %b将 SERVER_IP 替换为本机公网/内网 IP，并放行防火墙/安全组对应端口。%b\n' "$BOLD" "$RESET" "$YELLOW" "$RESET"
  if [[ -n "$HTTP_UPSTREAM_HOST" ]]; then
    printf '  %bHTTP%b   : %bhttp://%s:%s@SERVER_IP:%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$LOCAL_USER" "$LOCAL_PASS" "$LOCAL_HTTP_PORT" "$RESET"
  fi
  if [[ -n "$SOCKS_UPSTREAM_HOST" ]]; then
    printf '  %bSOCKS5%b : %bsocks5://%s:%s@SERVER_IP:%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$LOCAL_USER" "$LOCAL_PASS" "$LOCAL_SOCKS_PORT" "$RESET"
  fi
  printf '\n%b\n' "${BOLD_CYAN}▶ 命令行示例${RESET}"
  printf '  %b加载环境%b : %bsource %s%b\n' "$BOLD" "$RESET" "$GREEN" "$ENV_FILE" "$RESET"
  if [[ -n "$HTTP_UPSTREAM_HOST" ]]; then
    printf '  %bHTTP 测试%b: %bcurl -I https://www.google.com%b\n' "$BOLD" "$RESET" "$GREEN" "$RESET"
  fi
  if [[ -n "$SOCKS_UPSTREAM_HOST" ]]; then
    printf '  %bSOCKS 测试%b: %bcurl --proxy socks5h://127.0.0.1:%s --proxy-user %s:%s -I https://www.youtube.com%b\n' "$BOLD" "$RESET" "$GREEN" "$LOCAL_SOCKS_PORT" "$LOCAL_USER" "$LOCAL_PASS" "$RESET"
  fi
  printf '\n%b\n' "${BOLD_YELLOW}▶ 排障提示${RESET}"
  if [[ -n "$SOCKS_UPSTREAM_HOST" ]]; then
    printf '  %bSOCKS 链路%b: %bcurl -v --proxy socks5h://127.0.0.1:%s --proxy-user %s:%s -I https://www.google.com%b\n' "$BOLD" "$RESET" "$GREEN" "$LOCAL_SOCKS_PORT" "$LOCAL_USER" "$LOCAL_PASS" "$RESET"
  fi
  printf '  %b查看日志%b : %bsudo journalctl -u gost-client-forwarder -n 80 --no-pager%b\n' "$BOLD" "$RESET" "$GREEN" "$RESET"
  printf '  %b调试模式%b : %bGOST_CLIENT_LOG_LEVEL=debug sudo -E ./gost-client-forwarder.sh --setup%b\n' "$BOLD" "$RESET" "$GREEN" "$RESET"
  printf '%b\n' "${BOLD_GREEN}====================================================${RESET}"
}

show_plan_and_confirm() {
  echo
  printf '%b\n' "${BOLD_GREEN}=============== 配置概要 ===============${RESET}"
  printf '%b\n' "${BOLD_CYAN}▶ 远端 GOST 服务端${RESET}"
  printf '  %b公共传输方案%b : %b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$UPSTREAM_TRANSPORT" "$RESET"
  if [[ -n "$HTTP_UPSTREAM_HOST" ]]; then
    printf '  %bHTTP 上游%b    : %b%s:%s%b  用户=%b%s%b  类型=%b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$HTTP_UPSTREAM_HOST" "$HTTP_UPSTREAM_PORT" "$RESET" "$YELLOW" "$HTTP_UPSTREAM_USER" "$RESET" "$BOLD_GREEN" "$HTTP_UPSTREAM_PROXY_TYPE" "$RESET"
  fi
  if [[ -n "$SOCKS_UPSTREAM_HOST" ]]; then
    printf '  %bSOCKS 上游%b   : %b%s:%s%b  用户=%b%s%b  类型=%b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$SOCKS_UPSTREAM_HOST" "$SOCKS_UPSTREAM_PORT" "$RESET" "$YELLOW" "$SOCKS_UPSTREAM_USER" "$RESET" "$BOLD_GREEN" "$SOCKS_UPSTREAM_PROXY_TYPE" "$RESET"
  fi
  printf '  %b上游密码%b     : %b已隐藏%b\n' "$BOLD" "$RESET" "$YELLOW" "$RESET"
  printf '%b\n' "${BOLD_CYAN}▶ 本地对外暴露${RESET}"
  printf '  %b监听地址%b : %b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$LOCAL_BIND_ADDR" "$RESET"
  if [[ -n "$HTTP_UPSTREAM_HOST" ]]; then
    printf '  %bHTTP 端口%b : %b%s%b\n' "$BOLD" "$RESET" "$YELLOW" "$LOCAL_HTTP_PORT" "$RESET"
  fi
  if [[ -n "$SOCKS_UPSTREAM_HOST" ]]; then
    printf '  %bSOCKS 端口%b: %b%s%b\n' "$BOLD" "$RESET" "$YELLOW" "$LOCAL_SOCKS_PORT" "$RESET"
  fi
  printf '  %b认证用户%b : %b%s%b\n' "$BOLD" "$RESET" "$YELLOW" "$LOCAL_USER" "$RESET"
  printf '  %b认证密码%b : %b********%b\n' "$BOLD" "$RESET" "$YELLOW" "$RESET"
  printf '  %bDocker 代理%b: %b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "$([[ "${CONFIGURE_DOCKER:-0}" -eq 1 ]] && echo 启用 || echo 不启用)" "$RESET"
  printf '%b\n' "${BOLD_GREEN}========================================${RESET}"
  log "已启用自动配置模式，将直接写入配置、设置开机自启和每日定时重启。"
  return 0
}

print_proxychains_snippet() {
  [[ -n "$SOCKS_UPSTREAM_HOST" ]] || return 0
  cat <<EOF

proxychains 配置建议:
1) 安装（按系统）:
   Debian/Ubuntu: apt-get install -y proxychains4
   RHEL/CentOS  : dnf install -y proxychains-ng  (或 yum)
   Arch         : pacman -Sy --noconfirm proxychains-ng

2) 修改配置文件（常见路径: /etc/proxychains4.conf 或 /etc/proxychains.conf）:
   删除或注释原有末尾代理行，追加:
     socks5 127.0.0.1 ${LOCAL_SOCKS_PORT} ${LOCAL_USER} ${LOCAL_PASS}

3) 用法:
   proxychains4 curl -I https://www.youtube.com
   proxychains4 wget -O- https://www.google.com
EOF
}

setup_flow() {
  require_root
  install_dependencies
  detect_platform
  install_gost_if_needed
  ensure_inputs
  write_config
  write_service
  write_restart_units
  write_env_file
  start_service
  if [[ "${CONFIGURE_DOCKER:-0}" -eq 1 ]]; then
    configure_docker_proxy
  fi
  log "gost 本地转发已就绪。"
  status_service
  print_usage_snippets
  print_proxychains_snippet
}

uninstall_flow() {
  require_root
  stop_service
  systemctl stop gost-client-forwarder-restart.timer >/dev/null 2>&1 || true
  systemctl disable gost-client-forwarder.service >/dev/null 2>&1 || true
  systemctl disable gost-client-forwarder-restart.timer >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$RESTART_SERVICE_FILE" "$TIMER_FILE"
  rm -rf "$GOST_DIR"
  systemctl daemon-reload
  log "gost-client-forwarder 已卸载（未删除 ${GOST_BIN}）。"
}

# ============================================================
# 上游默认值预检
# ------------------------------------------------------------
# 校验脚本顶部的 DEFAULT_HTTP_UPSTREAM_*（第 28-31 行）与
# DEFAULT_SOCKS_UPSTREAM_*（第 34-37 行）是否已完成赋值。
# 存在空值时中止，避免带着空上游进入安装流程、生成无效 gost 配置。
#
# 两个可调开关（均可在 gost-client-forwarder.local.env 覆盖，或用命令行参数）：
#   UPSTREAM_PRECHECK_MODE    lenient（默认）| strict
#       lenient —— HTTP 组与 SOCKS 组至少完整配置一组；另一组整体留空则告警跳过。
#       strict  —— 8 项必须全部非空（即使只用一条隧道，也要把另一组填满）。
#   UPSTREAM_AUTH_REQUIRED    1（默认）| 0
#       1 —— 上游账号/口令缺失视为配置不完整，直接中止。
#       0 —— 允许上游免认证（匿名代理），账号/口令缺失仅告警。
#
# lenient 模式判定：
#   1) 两组全空                     -> 失败退出，输出完整填写指引
#   2) 某组只填了一部分              -> 失败退出，列出缺失的具体变量
#   3) 某组整体留空 + 另一组已配齐    -> 告警并跳过该组（单上游部署）
# ============================================================
UPSTREAM_PRECHECK_ENV_HINT() {
  printf '  %b方式一（推荐）：编辑 %s%b\n' "$YELLOW" "$GOST_LOCAL_ENV_FILE" "$RESET"
  printf '      该文件已被 .gitignore 忽略，不会入库；内容示例：\n'
  printf '        %bDEFAULT_HTTP_UPSTREAM_HOST=1.2.3.4%b\n' "$CYAN" "$RESET"
  printf '        %bDEFAULT_HTTP_UPSTREAM_PORT=28909%b\n' "$CYAN" "$RESET"
  printf '        %bDEFAULT_HTTP_UPSTREAM_USER=your_user%b\n' "$CYAN" "$RESET"
  printf '        %bDEFAULT_HTTP_UPSTREAM_PASS=your_pass%b\n' "$CYAN" "$RESET"
  printf '        %bDEFAULT_SOCKS_UPSTREAM_HOST=1.2.3.4%b\n' "$CYAN" "$RESET"
  printf '        %bDEFAULT_SOCKS_UPSTREAM_PORT=28910%b\n' "$CYAN" "$RESET"
  printf '        %bDEFAULT_SOCKS_UPSTREAM_USER=your_user%b\n' "$CYAN" "$RESET"
  printf '        %bDEFAULT_SOCKS_UPSTREAM_PASS=your_pass%b\n' "$CYAN" "$RESET"
  printf '      也可在同一文件里固化预检策略：\n'
  printf '        %bUPSTREAM_PRECHECK_MODE=lenient%b   # lenient 或 strict\n' "$CYAN" "$RESET"
  printf '        %bUPSTREAM_AUTH_REQUIRED=1%b         # 1 要求账号口令；0 允许免认证上游\n' "$CYAN" "$RESET"
  printf '  %b方式二%b：直接修改本脚本第 28-31 / 34-37 行的同名变量\n' "$YELLOW" "$RESET"
  printf '  %b方式三%b：命令行传入（仅本次生效）\n' "$YELLOW" "$RESET"
  printf '      %s --setup --http-upstream-host H --http-upstream-port P ...\n' "$SCRIPT_NAME"
  printf '      %s --setup --upstream-precheck-mode strict --upstream-auth-optional\n' "$SCRIPT_NAME"
  printf '  说明（当前模式：%s，认证要求：%s）：\n' \
    "${UPSTREAM_PRECHECK_MODE}" "$([[ "$UPSTREAM_AUTH_REQUIRED" -eq 1 ]] && echo '必需' || echo '可选')"
  if [[ "$UPSTREAM_PRECHECK_MODE" == "strict" ]]; then
    printf '    strict 模式下 8 项变量必须全部非空。\n'
  else
    printf '    lenient 模式下 HTTP 组与 SOCKS 组至少需完整配置一组；只部署单条隧道时，另一组可整体留空。\n'
  fi
  if [[ "$UPSTREAM_AUTH_REQUIRED" -ne 1 ]]; then
    printf '    已允许免认证上游：USER/PASS 缺失只会告警，不会中止。\n'
  fi
  if [[ -f "$STATE_FILE" ]]; then
    printf '  提示：检测到既有安装配置 %s，若只想查看或重启服务，\n' "$STATE_FILE"
    printf '        可直接执行 %s --status / --restart，无需重新执行 --setup。\n' "$SCRIPT_NAME"
  fi
}

normalize_precheck_mode() {
  case "${1,,}" in
    strict)         echo "strict" ;;
    lenient|loose)  echo "lenient" ;;
    *) return 1 ;;
  esac
}

# 统计某组中「按当前策略属于必填但为空」的变量，结果写入全局 PRE_GROUP_MISSING
_pre_group_missing() {
  local label="$1"; shift
  local -a keys=("$@")
  local k out=()
  for k in "${keys[@]}"; do
    if [[ -z "${!k:-}" ]]; then
      case "$k" in
        *_USER|*_PASS)
          (( UPSTREAM_AUTH_REQUIRED == 1 )) && out+=("$k")
          ;;
        *) out+=("$k") ;;
      esac
    fi
  done
  PRE_GROUP_MISSING=("${out[@]}")
}

# 某组「是否被启用」= HOST 或 PORT 至少有一个非空
_pre_group_started() {
  local h="${!1:-}" p="${!2:-}"
  [[ -n "$h" || -n "$p" ]]
}

precheck_upstream_defaults() {
  UPSTREAM_PRECHECK_MODE="$(normalize_precheck_mode "${UPSTREAM_PRECHECK_MODE:-lenient}")" \
    || { err "UPSTREAM_PRECHECK_MODE 非法，仅支持 lenient/strict"; exit 1; }
  [[ "${UPSTREAM_AUTH_REQUIRED:-1}" =~ ^[01]$ ]] \
    || { err "UPSTREAM_AUTH_REQUIRED 非法，仅支持 0/1"; exit 1; }

  local -a http_keys=(DEFAULT_HTTP_UPSTREAM_HOST DEFAULT_HTTP_UPSTREAM_PORT \
                      DEFAULT_HTTP_UPSTREAM_USER DEFAULT_HTTP_UPSTREAM_PASS)
  local -a socks_keys=(DEFAULT_SOCKS_UPSTREAM_HOST DEFAULT_SOCKS_UPSTREAM_PORT \
                       DEFAULT_SOCKS_UPSTREAM_USER DEFAULT_SOCKS_UPSTREAM_PASS)
  local -a http_missing=() socks_missing=()
  local k

  _pre_group_missing HTTP "${http_keys[@]}";  http_missing=("${PRE_GROUP_MISSING[@]}")
  _pre_group_missing SOCKS "${socks_keys[@]}"; socks_missing=("${PRE_GROUP_MISSING[@]}")

  local http_started=0 socks_started=0
  if _pre_group_started DEFAULT_HTTP_UPSTREAM_HOST DEFAULT_HTTP_UPSTREAM_PORT;  then http_started=1;  fi
  if _pre_group_started DEFAULT_SOCKS_UPSTREAM_HOST DEFAULT_SOCKS_UPSTREAM_PORT; then socks_started=1; fi

  # ---- 状态表 ----
  printf '\n%b================ 上游默认值预检 ================%b\n' "$BOLD_CYAN" "$RESET"
  printf '  模式：%b%s%b   认证要求：%b%s%b\n' "$BOLD" "$UPSTREAM_PRECHECK_MODE" "$RESET" \
    "$BOLD" "$([[ "$UPSTREAM_AUTH_REQUIRED" -eq 1 ]] && echo '必需' || echo '可选')" "$RESET"
  printf '  %-32s %-8s %-8s %s\n' "变量" "分组" "必填" "状态"
  local -a all_keys=("${http_keys[@]}" "${socks_keys[@]}")
  local grp need st
  for k in "${all_keys[@]}"; do
    case "$k" in *_HTTP_UPSTREAM_*) grp="HTTP"  ;; *) grp="SOCKS" ;; esac
    need="是"
    case "$k" in
      *_USER|*_PASS) (( UPSTREAM_AUTH_REQUIRED == 1 )) || need="否" ;;
    esac
    if [[ -z "${!k:-}" ]]; then
      if [[ "$need" == "否" ]]; then
        printf '  %-32s %-8s %-8s %b%s%b\n' "$k" "$grp" "$need" "$YELLOW" "空（按策略允许）" "$RESET"
      else
        printf '  %-32s %-8s %-8s %b%s%b\n' "$k" "$grp" "$need" "$RED" "空" "$RESET"
      fi
    else
      printf '  %-32s %-8s %-8s %b%s%b\n' "$k" "$grp" "$need" "$GREEN" "已赋值" "$RESET"
    fi
  done
  printf '  覆盖文件：%s（%s）\n' "$GOST_LOCAL_ENV_FILE" \
    "$([[ -f "$GOST_LOCAL_ENV_FILE" ]] && echo '已加载' || echo '不存在')"
  printf '%b================================================%b\n\n' "$BOLD_CYAN" "$RESET"

  # ---- strict：8 项一律必填 ----
  if [[ "$UPSTREAM_PRECHECK_MODE" == "strict" ]]; then
    local -a all_missing=("${http_missing[@]}" "${socks_missing[@]}")
    if (( ${#all_missing[@]} > 0 )); then
      err "strict 模式下要求 8 项全部非空，当前缺失 ${#all_missing[@]} 项："
      local m
      for m in "${all_missing[@]}"; do err "  - $m"; done
      err "已中止后续执行（未做任何配置或安装动作）。"
      printf '\n%b补齐方式：%b\n' "$BOLD" "$RESET"
      UPSTREAM_PRECHECK_ENV_HINT
      exit 1
    fi
    log "上游默认值预检通过（strict：8 项齐备）。"
    return 0
  fi

  # ---- lenient：至少一组完整 ----
  local http_ok=1 socks_ok=1
  (( ${#http_missing[@]}  == 0 )) || http_ok=0
  (( ${#socks_missing[@]} == 0 )) || socks_ok=0

  # 规则 1：两组都不可用
  if (( http_ok == 0 && socks_ok == 0 )); then
    if (( http_started == 0 && socks_started == 0 )); then
      err "上游默认值全部为空：DEFAULT_HTTP_UPSTREAM_* 与 DEFAULT_SOCKS_UPSTREAM_* 均未完成赋值。"
    elif (( http_started == 1 && socks_started == 0 )); then
      err "DEFAULT_HTTP_UPSTREAM_* 配置不完整，缺少：${http_missing[*]}"
      err "（SOCKS 组未启用；如需启用请补齐 DEFAULT_SOCKS_UPSTREAM_*）"
    elif (( http_started == 0 && socks_started == 1 )); then
      err "DEFAULT_SOCKS_UPSTREAM_* 配置不完整，缺少：${socks_missing[*]}"
      err "（HTTP 组未启用；如需启用请补齐 DEFAULT_HTTP_UPSTREAM_*）"
    else
      err "HTTP 组与 SOCKS 组均未配置完整，至多只能启用其中一组。"
      if (( ${#http_missing[@]}  > 0 )); then err "  DEFAULT_HTTP_UPSTREAM_*  缺少：${http_missing[*]}";  fi
      if (( ${#socks_missing[@]} > 0 )); then err "  DEFAULT_SOCKS_UPSTREAM_* 缺少：${socks_missing[*]}"; fi
    fi
    err "已中止后续执行（未做任何配置或安装动作）。"
    printf '\n%b补齐方式：%b\n' "$BOLD" "$RESET"
    UPSTREAM_PRECHECK_ENV_HINT
    exit 1
  fi

  # 规则 2：两组都启用了，但都不完整 -> 属于半个配置，中止
  if (( http_started == 1 && socks_started == 1 )); then
    local fail=0
    if (( http_ok == 0 ));  then err "DEFAULT_HTTP_UPSTREAM_* 配置不完整，缺少：${http_missing[*]}";  fail=1; fi
    if (( socks_ok == 0 )); then err "DEFAULT_SOCKS_UPSTREAM_* 配置不完整，缺少：${socks_missing[*]}"; fail=1; fi
    if (( fail == 1 )); then
      err "已中止后续执行（未做任何配置或安装动作）。"
      printf '\n%b补齐方式：%b\n' "$BOLD" "$RESET"
      UPSTREAM_PRECHECK_ENV_HINT
      exit 1
    fi
  fi

  # 规则 3：单组启用 —— 另一组整体留空则告警跳过
  if (( http_started == 0 && socks_ok == 1 )); then
    warn "DEFAULT_HTTP_UPSTREAM_* 全空：本次不创建 HTTP 本地入口的专用上游链。"
  fi
  if (( socks_started == 0 && http_ok == 1 )); then
    warn "DEFAULT_SOCKS_UPSTREAM_* 全空：本次不创建 SOCKS5 本地入口的专用上游链。"
  fi
  if (( UPSTREAM_AUTH_REQUIRED != 1 && http_ok == 1 && http_started == 1 )); then
    if [[ -z "${DEFAULT_HTTP_UPSTREAM_USER:-}" ]]; then warn "HTTP 上游未设账号（已允许免认证）。"; fi
  fi
  if (( UPSTREAM_AUTH_REQUIRED != 1 && socks_ok == 1 && socks_started == 1 )); then
    if [[ -z "${DEFAULT_SOCKS_UPSTREAM_USER:-}" ]]; then warn "SOCKS 上游未设账号（已允许免认证）。"; fi
  fi

  log "上游默认值预检通过。"
}

# ============================================================
# 配置溯源自检（--check-config）
# ------------------------------------------------------------
# 逐项列出参数「生效值 + 来源」，用于确认所有参数均可由
# gost-client-forwarder.local.env 提供。敏感值一律脱敏。
# 来源判定优先级：local.env 覆盖 > 脚本默认 > 已安装 state.env（仅运行时复用项）
# ============================================================
_is_local_env_key() {
  local want="$1" k
  for k in "${LOCAL_ENV_SET_KEYS[@]}"; do
    [[ "$k" == "$want" ]] && return 0
  done
  return 1
}

_mask() {
  local v="${1-}"
  if [[ -z "$v" ]]; then printf '(空)'; return; fi
  if (( ${#v} <= 4 )); then printf '****'; else printf '%s****(%d字符)' "${v:0:2}" "${#v}"; fi
}

check_config() {
  printf '\n%b=========== 配置溯源（全部参数均可在 local.env 覆盖）===========%b\n' "$BOLD_CYAN" "$RESET"
  if (( LOCAL_ENV_FILE_LOADED == 1 )); then
    printf '  覆盖文件：%b%s%b\n' "$GREEN" "$GOST_LOCAL_ENV_FILE" "$RESET"
  else
    printf '  覆盖文件：%b(不存在，全部使用脚本默认)%b\n' "$YELLOW" "$RESET"
  fi
  printf '  已由 local.env 覆盖：%b%d%b / %d 项\n\n' \
    "$BOLD" "${#LOCAL_ENV_SET_KEYS[@]}" "$RESET" "${#UPSTREAM_TRACKED_PARAMS[@]}"
  printf '  %-34s %-22s %s\n' "参数" "生效值" "来源"
  printf '  %-34s %-22s %s\n' "----------------------------------" "----------------------" "----------"

  local k val src secret=0
  for k in "${UPSTREAM_TRACKED_PARAMS[@]}"; do
    val="${!k-}"
    case "$k" in
      *PASS|*USER) secret=1; val="$(_mask "$val")" ;;
      *) secret=0 ;;
    esac
    if _is_local_env_key "$k"; then
      src="local.env"
    else
      src="脚本默认"
    fi
    printf '  %-34s %-22s %s\n' "$k" "${val:-(空)}" "$src"
  done

  # 运行时复用：本地账号口令可能来自已安装 state.env
  printf '\n  %b运行时补充（仅 --setup 时复用）%b\n' "$BOLD" "$RESET"
  if [[ -r "$STATE_FILE" ]]; then
    local su sp
    su="$(grep '^LOCAL_USER=' "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true)"
    sp="$(grep '^LOCAL_PASS=' "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true)"
    printf '  %-34s %-22s %s\n' "LOCAL_USER(state)" "$(_mask "$su")" "已安装配置"
    printf '  %-34s %-22s %s\n' "LOCAL_PASS(state)" "$(_mask "$sp")" "已安装配置"
  else
    printf '  %s\n' "未检测到 $STATE_FILE"
  fi

  printf '\n  提示：命令行参数（--http-upstream-host 等）优先级高于 local.env。\n'
  printf '%b=============================================================%b\n\n' "$BOLD_CYAN" "$RESET"
}

main() {
  local action=""
  CONFIGURE_DOCKER="${DEFAULT_AUTO_CONFIGURE_DOCKER}"
  UPSTREAM_TRANSPORT="${DEFAULT_UPSTREAM_TRANSPORT}"
  HTTP_UPSTREAM_HOST="${DEFAULT_HTTP_UPSTREAM_HOST}"
  HTTP_UPSTREAM_PORT="${DEFAULT_HTTP_UPSTREAM_PORT}"
  HTTP_UPSTREAM_USER="${DEFAULT_HTTP_UPSTREAM_USER}"
  HTTP_UPSTREAM_PASS="${DEFAULT_HTTP_UPSTREAM_PASS}"
  HTTP_UPSTREAM_PROXY_TYPE="${DEFAULT_HTTP_UPSTREAM_PROXY_TYPE}"
  SOCKS_UPSTREAM_HOST="${DEFAULT_SOCKS_UPSTREAM_HOST}"
  SOCKS_UPSTREAM_PORT="${DEFAULT_SOCKS_UPSTREAM_PORT}"
  SOCKS_UPSTREAM_USER="${DEFAULT_SOCKS_UPSTREAM_USER}"
  SOCKS_UPSTREAM_PASS="${DEFAULT_SOCKS_UPSTREAM_PASS}"
  SOCKS_UPSTREAM_PROXY_TYPE="${DEFAULT_SOCKS_UPSTREAM_PROXY_TYPE}"
  GRPC_PATH="${DEFAULT_GRPC_PATH}"
  H3_AUTHORIZE_PATH="${DEFAULT_H3_AUTHORIZE_PATH}"
  H3_PUSH_PATH="${DEFAULT_H3_PUSH_PATH}"
  H3_PULL_PATH="${DEFAULT_H3_PULL_PATH}"
  LOCAL_HTTP_PORT="${DEFAULT_LOCAL_HTTP_PORT}"
  LOCAL_SOCKS_PORT="${DEFAULT_LOCAL_SOCKS_PORT}"
  LOCAL_BIND_ADDR="${DEFAULT_LOCAL_BIND}"
  LOCAL_USER="${DEFAULT_LOCAL_USER}"
  LOCAL_PASS="${DEFAULT_LOCAL_PASS}"
  RESTART_ON_CALENDAR="${DEFAULT_RESTART_ON_CALENDAR}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --setup) action="setup"; shift ;;
      --status) action="status"; shift ;;
      --start) action="start"; shift ;;
      --stop) action="stop"; shift ;;
      --restart) action="restart"; shift ;;
      --uninstall) action="uninstall"; shift ;;
      --upstream-transport) UPSTREAM_TRANSPORT="$2"; shift 2 ;;
      --http-upstream-host) HTTP_UPSTREAM_HOST="$2"; shift 2 ;;
      --http-upstream-port) HTTP_UPSTREAM_PORT="$2"; shift 2 ;;
      --http-upstream-user) HTTP_UPSTREAM_USER="$2"; shift 2 ;;
      --http-upstream-pass) HTTP_UPSTREAM_PASS="$2"; shift 2 ;;
      --http-upstream-proxy-type) HTTP_UPSTREAM_PROXY_TYPE="$2"; shift 2 ;;
      --socks-upstream-host) SOCKS_UPSTREAM_HOST="$2"; shift 2 ;;
      --socks-upstream-port) SOCKS_UPSTREAM_PORT="$2"; shift 2 ;;
      --socks-upstream-user) SOCKS_UPSTREAM_USER="$2"; shift 2 ;;
      --socks-upstream-pass) SOCKS_UPSTREAM_PASS="$2"; shift 2 ;;
      --socks-upstream-proxy-type) SOCKS_UPSTREAM_PROXY_TYPE="$2"; shift 2 ;;
      --grpc-path) GRPC_PATH="$2"; shift 2 ;;
      --h3-authorize-path) H3_AUTHORIZE_PATH="$2"; shift 2 ;;
      --h3-push-path) H3_PUSH_PATH="$2"; shift 2 ;;
      --h3-pull-path) H3_PULL_PATH="$2"; shift 2 ;;
      --local-http-port) LOCAL_HTTP_PORT="$2"; shift 2 ;;
      --local-socks-port) LOCAL_SOCKS_PORT="$2"; shift 2 ;;
      --local-bind) LOCAL_BIND_ADDR="$2"; shift 2 ;;
      --local-user) LOCAL_USER="$2"; shift 2 ;;
      --local-pass) LOCAL_PASS="$2"; shift 2 ;;
      --configure-docker) CONFIGURE_DOCKER=1; shift ;;
      --upstream-precheck-mode) UPSTREAM_PRECHECK_MODE="$2"; shift 2 ;;
      --upstream-auth-required) UPSTREAM_AUTH_REQUIRED=1; shift ;;
      --upstream-auth-optional) UPSTREAM_AUTH_REQUIRED=0; shift ;;
      --restart-on-calendar) RESTART_ON_CALENDAR="$2"; shift 2 ;;
      --check-config) action="check-config"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) err "未知参数: $1"; usage; exit 1 ;;
    esac
  done

  case "${action:-setup}" in
    setup)
      # 预检：上游默认值未赋值时直接中止，避免生成无效配置
      precheck_upstream_defaults
      # 如果 STATE_FILE 已存在，说明之前执行过安装，展示当前配置并询问用户
      if [[ -f "$STATE_FILE" ]]; then
        echo
        printf '%b\n' "${BOLD_GREEN}================ 当前本地代理配置 ================${RESET}"
        # 读出各字段并格式化展示（简化：直接读取 state.env）
        local _st_transport _st_http_host _st_http_port _st_http_user _st_socks_host _st_socks_port _st_socks_user
        local _st_bind _st_http_lport _st_socks_lport _st_local_user _st_local_pass _st_install_time
        _st_transport="$(  grep '^UPSTREAM_TRANSPORT='  "$STATE_FILE" | cut -d= -f2- || true)"
        _st_http_host="$(   grep '^HTTP_UPSTREAM_HOST='  "$STATE_FILE" | cut -d= -f2- || true)"
        _st_http_port="$(   grep '^HTTP_UPSTREAM_PORT='  "$STATE_FILE" | cut -d= -f2- || true)"
        _st_http_user="$(   grep '^HTTP_UPSTREAM_USER='  "$STATE_FILE" | cut -d= -f2- || true)"
        _st_socks_host="$(  grep '^SOCKS_UPSTREAM_HOST=' "$STATE_FILE" | cut -d= -f2- || true)"
        _st_socks_port="$(  grep '^SOCKS_UPSTREAM_PORT=' "$STATE_FILE" | cut -d= -f2- || true)"
        _st_socks_user="$(  grep '^SOCKS_UPSTREAM_USER=' "$STATE_FILE" | cut -d= -f2- || true)"
        _st_bind="$(        grep '^LOCAL_BIND_ADDR='     "$STATE_FILE" | cut -d= -f2- || true)"
        _st_http_lport="$(  grep '^LOCAL_HTTP_PORT='     "$STATE_FILE" | cut -d= -f2- || true)"
        _st_socks_lport="$( grep '^LOCAL_SOCKS_PORT='    "$STATE_FILE" | cut -d= -f2- || true)"
        _st_local_user="$(  grep '^LOCAL_USER='          "$STATE_FILE" | cut -d= -f2- || true)"
        _st_local_pass="$(  grep '^LOCAL_PASS='          "$STATE_FILE" | cut -d= -f2- || true)"
        _st_install_time="$(grep '^INSTALL_TIME='        "$STATE_FILE" | cut -d= -f2- || true)"
        printf '%b\n' "${BOLD_CYAN}▶ 上游连接${RESET}"
        printf '  %b传输方案%b : %b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "${_st_transport:-未记录}" "$RESET"
        [[ -n "$_st_http_host" ]] && \
          printf '  %bHTTP 上游%b   : %b%s:%s%b  用户=%b%s%b\n' \
            "$BOLD" "$RESET" "$BOLD_GREEN" "$_st_http_host" "$_st_http_port" "$RESET" "$YELLOW" "$_st_http_user" "$RESET"
        [[ -n "$_st_socks_host" ]] && \
          printf '  %bSOCKS 上游%b  : %b%s:%s%b  用户=%b%s%b\n' \
            "$BOLD" "$RESET" "$BOLD_GREEN" "$_st_socks_host" "$_st_socks_port" "$RESET" "$YELLOW" "$_st_socks_user" "$RESET"
        printf '%b\n' "${BOLD_CYAN}▶ 本地监听${RESET}"
        printf '  %b监听地址%b : %b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "${_st_bind:-未记录}" "$RESET"
        printf '  %b认证用户%b : %b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "${_st_local_user:-未记录}" "$RESET"
        printf '  %b认证密码%b : %b%s%b\n' "$BOLD" "$RESET" "$BOLD_GREEN" "${_st_local_pass:-未记录}" "$RESET"
        [[ -n "$_st_http_lport" ]] && \
          printf '  %bHTTP  端口%b : %b%s%b  →  %bhttp://%s:%s@127.0.0.1:%s%b\n' \
            "$BOLD" "$RESET" "$YELLOW" "$_st_http_lport" "$RESET" "$BOLD_GREEN" "${_st_local_user}" "${_st_local_pass}" "$_st_http_lport" "$RESET"
        [[ -n "$_st_socks_lport" ]] && \
          printf '  %bSOCKS 端口%b : %b%s%b  →  %bsocks5://%s:%s@127.0.0.1:%s%b\n' \
            "$BOLD" "$RESET" "$YELLOW" "$_st_socks_lport" "$RESET" "$BOLD_GREEN" "${_st_local_user}" "${_st_local_pass}" "$_st_socks_lport" "$RESET"
        [[ -n "$_st_install_time" ]] && \
          printf '  %b安装时间%b : %b%s%b\n' "$BOLD" "$RESET" "$YELLOW" "$_st_install_time" "$RESET"
        printf '%b\n' "${BOLD_GREEN}================================================${RESET}"
        echo
        # 展示运行状态（压缩为一行绿色摘要）
        local _svc_state _svc_since _svc_pid _svc_mem _status_line
        _svc_state="$(systemctl show gost-client-forwarder.service --property=ActiveState --value 2>/dev/null || echo unknown)"
        _svc_since="$(systemctl show gost-client-forwarder.service --property=ActiveEnterTimestamp --value 2>/dev/null | sed 's/ [A-Z]*$//' || echo)"
        _svc_pid="$(  systemctl show gost-client-forwarder.service --property=MainPID           --value 2>/dev/null || echo)"
        _svc_mem="$(  systemctl show gost-client-forwarder.service --property=MemoryCurrent      --value 2>/dev/null || echo)"
        # 内存单位转换（字节 → MB）
        if [[ "$_svc_mem" =~ ^[0-9]+$ ]] && (( _svc_mem > 0 )); then
          _svc_mem="$(( _svc_mem / 1024 / 1024 )) MB"
        else
          _svc_mem=""
        fi
        _status_line="状态: ${_svc_state}"
        [[ -n "$_svc_since" ]] && _status_line+="  起始: ${_svc_since}"
        [[ -n "$_svc_pid"   ]] && _status_line+="  PID: ${_svc_pid}"
        [[ -n "$_svc_mem"   ]] && _status_line+="  内存: ${_svc_mem}"
        if [[ "$_svc_state" == "active" ]]; then
          printf '%b%s%b\n' "${GREEN}" "$_status_line" "${RESET}"
        else
          printf '%b%s%b\n' "${RED}" "$_status_line" "${RESET}"
        fi
        echo
        printf '%b检测到 gost 客户端已安装并配置。%b\n' "$YELLOW" "$RESET"
        printf '如需重新安装覆盖当前配置，请输入 %by%b；输入其他任意键退出: ' "$BOLD" "$RESET"
        local _ans
        read -r _ans
        if [[ ! "${_ans,,}" =~ ^y ]]; then
          log "已取消重新安装。"
          exit 0
        fi
        echo
      fi
      ensure_inputs
      if show_plan_and_confirm; then
        setup_flow
      fi
      ;;
    status) status_service ;;
    check-config) check_config ;;
    start) require_root; systemctl start gost-client-forwarder.service ;;
    stop) require_root; stop_service ;;
    restart) require_root; systemctl restart gost-client-forwarder.service ;;
    uninstall) uninstall_flow ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
