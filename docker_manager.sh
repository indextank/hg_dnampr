#!/bin/bash

# Docker管理脚本 - 独立版本
# 版本：1.0.0
# 维护日期：2026-07-16
# 功能：Docker和Docker Compose的安装、卸载、配置和管理
# 支持系统：Arch Linux, Debian, Ubuntu, CentOS, RHEL, Fedora, AlmaLinux, Rocky, openSUSE, WSL
#
# 数据目录（可通过环境变量覆盖）：
#   CONTAINERD_DATA_PATH  默认 /data/containerd（install_docker 会自动迁移至此；菜单 8 可再指定路径）
#   DOCKER_DATA_PATH      默认 /data/docker（菜单 10 迁移 Docker data-root 时用作默认目标）

set -e

# 颜色输出函数
blue() { echo -e "\033[36m\033[01m$1\033[0m"; }
red() { echo -e "\033[31m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
white() { echo -e "\033[37m\033[01m$1\033[0m"; }
readp() { read -p "$(yellow "$1")" $2; }

# 默认数据路径（可被环境变量覆盖）
CONTAINERD_DATA_PATH="${CONTAINERD_DATA_PATH:-/data/containerd}"

# 构建/安装代理：脚本内开关决定是否启用；账密来自系统 PROXY_*，勿写入本脚本。
#   PROXY_SCHEME  PROXY_HOST  PROXY_PORT  [PROXY_USER]  [PROXY_PASS]
# 临时覆盖（可选）：export DM_BUILD_PROXY_ENABLED=true DM_BUILD_PROXY_URL='...'
# 测试：curl --proxy "${PROXY_SCHEME}://${PROXY_HOST}:${PROXY_PORT}" --proxy-user "${PROXY_USER}:${PROXY_PASS}" -I https://www.youtube.com
BUILD_PROXY_ENABLED=false
BUILD_PROXY_TYPE=socks5h
BUILD_PROXY_URL=
BUILD_NO_PROXY="${BUILD_NO_PROXY:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"

# 运行期代理状态（由 dm_probe_build_proxy 设置；与 BUILD_PROXY_ENABLED 开关不同）
DM_PROXY_ENABLED=false
DM_EFFECTIVE_PROXY_URL=""
DM_EFFECTIVE_PROXY_TYPE=""
DM_EFFECTIVE_NO_PROXY=""

dm_is_build_proxy_enabled() {
    case "${1:-}" in
        [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]|1) return 0 ;;
        *) return 1 ;;
    esac
}

# 仅在开关开启时从 PROXY_* 拼装 URL（输出 URL 或空）
dm_compose_proxy_url_from_env() {
    local preferred_type="${1:-}"
    local scheme host port user pass
    scheme="${preferred_type:-}"
    case "${scheme,,}" in
        http|https|socks5|socks5h) ;;
        *) scheme="${PROXY_SCHEME:-}" ;;
    esac
    host="${PROXY_HOST:-}"
    port="${PROXY_PORT:-}"
    user="${PROXY_USER:-}"
    pass="${PROXY_PASS:-}"
    [[ -n "$scheme" && -n "$host" && -n "$port" ]] || { echo ""; return 1; }
    case "${scheme,,}" in
        http|https|socks5|socks5h) ;;
        *) echo ""; return 1 ;;
    esac
    if [[ -n "$user" ]]; then
        echo "${scheme}://${user}:${pass}@${host}:${port}"
    else
        echo "${scheme}://${host}:${port}"
    fi
}

# 解析：开关关闭→直连；开启后 显式 URL > PROXY_* 拼装（输出: type<TAB>url<TAB>no_proxy）
dm_resolve_build_proxy_vars() {
    local enabled="${BUILD_PROXY_ENABLED:-false}"
    local proxy_type="${BUILD_PROXY_TYPE:-}"
    local proxy_url="${BUILD_PROXY_URL:-}"
    local no_proxy="${BUILD_NO_PROXY:-localhost,127.0.0.1,::1}"
    [[ -n "${DM_BUILD_PROXY_ENABLED:-}" ]] && enabled="$DM_BUILD_PROXY_ENABLED"
    [[ -n "${DM_BUILD_PROXY_TYPE:-}" ]] && proxy_type="$DM_BUILD_PROXY_TYPE"
    [[ -n "${DM_BUILD_PROXY_URL:-}" ]] && proxy_url="$DM_BUILD_PROXY_URL"
    [[ -n "${DM_BUILD_NO_PROXY:-}" ]] && no_proxy="$DM_BUILD_NO_PROXY"

    if ! dm_is_build_proxy_enabled "$enabled"; then
        printf '%s\t%s\t%s' "none" "" "$no_proxy"
        return 0
    fi

    if [[ -z "$proxy_url" ]]; then
        proxy_url="$(dm_compose_proxy_url_from_env "$proxy_type" 2>/dev/null || true)"
    fi
    if [[ -z "$proxy_url" ]]; then
        printf '%s\t%s\t%s' "none" "" "$no_proxy"
        return 0
    fi
    if [[ -z "$proxy_type" || "$proxy_type" == "none" ]]; then
        proxy_type="${proxy_url%%://*}"
    fi
    printf '%s\t%s\t%s' "${proxy_type,,}" "$proxy_url" "$no_proxy"
}

# 从代理 URL 解析 host、port（支持 user:pass@host:port）
dm_parse_proxy_host_port() {
    local url="$1"
    DM_PROXY_HOST=""
    DM_PROXY_PORT=""
    DM_PROXY_HOST="$(printf '%s' "$url" | sed -E 's|^[a-zA-Z0-9+.-]+://([^@]*@)?([^/:]+)(:([0-9]+))?.*|\2|')"
    DM_PROXY_PORT="$(printf '%s' "$url" | sed -E 's|^[a-zA-Z0-9+.-]+://([^@]*@)?([^/:]+):([0-9]+).*|\3|')"
    if [[ -z "$DM_PROXY_PORT" ]]; then
        case "$url" in
            socks5://*|socks5h://*) DM_PROXY_PORT=1080 ;;
            *) DM_PROXY_PORT=8080 ;;
        esac
    fi
}

# 测试代理：TCP 连通 + curl 访问 Docker Hub API（401/200 均视为可达）
dm_test_proxy_url() {
    local proxy_url="$1"
    local proxy_type="${2:-http}"

    [[ -z "$proxy_url" ]] && return 1
    case "${proxy_type,,}" in
        none|"") return 1 ;;
        http|https|socks5|socks5h) ;;
        *) return 1 ;;
    esac

    if ! command_exists curl; then
        yellow "⚠️  未安装 curl，跳过代理 HTTP 探测"
        return 1
    fi

    dm_parse_proxy_host_port "$proxy_url"
    if [[ -n "$DM_PROXY_HOST" && "$DM_PROXY_PORT" =~ ^[0-9]+$ ]]; then
        if ! (timeout 3 bash -c ">/dev/tcp/${DM_PROXY_HOST}/${DM_PROXY_PORT}") 2>/dev/null; then
            return 1
        fi
    else
        return 1
    fi

    local http_code
    http_code=$(curl -fsS -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 20 \
        --proxy "$proxy_url" \
        "https://registry-1.docker.io/v2/" 2>/dev/null || echo "000")
    case "$http_code" in
        200|301|302|401) return 0 ;;
    esac
    # 备用探测（部分网络对 registry 有限制）
    http_code=$(curl -fsS -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 15 \
        --proxy "$proxy_url" \
        "https://www.google.com/generate_204" 2>/dev/null || echo "000")
    [[ "$http_code" == "204" || "$http_code" == "200" ]]
}

dm_apply_build_proxy_to_session() {
    [[ "$DM_PROXY_ENABLED" != true ]] || [[ -z "$DM_EFFECTIVE_PROXY_URL" ]] && return 0
    export HTTP_PROXY="$DM_EFFECTIVE_PROXY_URL"
    export HTTPS_PROXY="$DM_EFFECTIVE_PROXY_URL"
    export ALL_PROXY="$DM_EFFECTIVE_PROXY_URL"
    export NO_PROXY="$DM_EFFECTIVE_NO_PROXY"
    export http_proxy="$HTTP_PROXY"
    export https_proxy="$HTTPS_PROXY"
    export all_proxy="$ALL_PROXY"
    export no_proxy="$NO_PROXY"
}

dm_clear_session_proxy() {
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy 2>/dev/null || true
}

# 启动时探测：开关开启且 PROXY_*/显式 URL 可用则启用；否则直连
dm_probe_build_proxy() {
    DM_PROXY_ENABLED=false
    DM_EFFECTIVE_PROXY_URL=""
    DM_EFFECTIVE_PROXY_TYPE=""
    DM_EFFECTIVE_NO_PROXY="${BUILD_NO_PROXY:-localhost,127.0.0.1,::1}"

    local proxy_type proxy_url no_proxy
    IFS=$'\t' read -r proxy_type proxy_url no_proxy <<< "$(dm_resolve_build_proxy_vars)"

    [[ -z "$proxy_url" ]] && return 0
    case "${proxy_type,,}" in
        none|"") return 0 ;;
    esac

    yellow "🔍 检测构建代理 (${proxy_type}) …"
    if dm_test_proxy_url "$proxy_url" "$proxy_type"; then
        DM_PROXY_ENABLED=true
        DM_EFFECTIVE_PROXY_URL="$proxy_url"
        DM_EFFECTIVE_PROXY_TYPE="$proxy_type"
        DM_EFFECTIVE_NO_PROXY="$no_proxy"
        dm_apply_build_proxy_to_session
        green "✅ 代理可用，已为本会话启用: $(_dm_mask_proxy_url "$proxy_url")"
        return 0
    fi

    yellow "⚠️  代理不可达或探测失败，已自动禁用（安装与拉取将尝试直连）"
    dm_clear_session_proxy
    DM_PROXY_ENABLED=false
    return 0
}

_dm_mask_proxy_url() {
    local proxy_url="$1"
    local scheme rest hostport
    scheme="${proxy_url%%://*}"
    rest="${proxy_url#*://}"
    hostport="${rest%%/*}"
    hostport="${hostport##*@}"
    if [[ "$scheme" == "$proxy_url" ]]; then
        echo "$hostport"
    else
        echo "${scheme}://${hostport}"
    fi
}

# 写入 apt/dnf 代理（安装 Docker 组件时使用）
dm_configure_package_manager_proxy() {
    [[ "$DM_PROXY_ENABLED" != true ]] || [[ -z "$DM_EFFECTIVE_PROXY_URL" ]] && return 0
    get_sudo 2>/dev/null || true
    [[ -z "${SUDO:-}" && "$(id -u)" -ne 0 ]] && return 0

    if command_exists apt-get; then
        $SUDO tee /etc/apt/apt.conf.d/95docker-manager-proxy >/dev/null <<EOF
// 由 docker_manager.sh 生成 — 构建/安装代理
Acquire::http::Proxy "${DM_EFFECTIVE_PROXY_URL}";
Acquire::https::Proxy "${DM_EFFECTIVE_PROXY_URL}";
EOF
        green "✅ 已配置 apt 代理"
    fi

    if [[ -f /etc/dnf/dnf.conf ]]; then
        $SUDO sed -i '/^# docker_manager proxy$/d;/^proxy=/d;/^proxy_username=/d;/^proxy_password=/d' /etc/dnf/dnf.conf 2>/dev/null || true
        $SUDO tee -a /etc/dnf/dnf.conf >/dev/null <<EOF

# docker_manager proxy
proxy=${DM_EFFECTIVE_PROXY_URL}
EOF
        green "✅ 已配置 dnf 代理"
    elif [[ -f /etc/yum.conf ]]; then
        $SUDO sed -i '/^# docker_manager proxy$/d;/^proxy=/d' /etc/yum.conf 2>/dev/null || true
        $SUDO tee -a /etc/yum.conf >/dev/null <<EOF

# docker_manager proxy
proxy=${DM_EFFECTIVE_PROXY_URL}
EOF
        green "✅ 已配置 yum 代理"
    fi
}

dm_clear_package_manager_proxy() {
    get_sudo 2>/dev/null || true
    [[ -z "${SUDO:-}" && "$(id -u)" -ne 0 ]] && return 0
    $SUDO rm -f /etc/apt/apt.conf.d/95docker-manager-proxy 2>/dev/null || true
    if [[ -f /etc/dnf/dnf.conf ]]; then
        $SUDO sed -i '/^# docker_manager proxy$/d;/^proxy=/d' /etc/dnf/dnf.conf 2>/dev/null || true
    fi
    if [[ -f /etc/yum.conf ]]; then
        $SUDO sed -i '/^# docker_manager proxy$/d;/^proxy=/d' /etc/yum.conf 2>/dev/null || true
    fi
}

# Docker 守护进程默认代理（systemd drop-in，影响 docker pull / build 等）
dm_configure_docker_systemd_proxy() {
    [[ "$DM_PROXY_ENABLED" != true ]] || [[ -z "$DM_EFFECTIVE_PROXY_URL" ]] && return 0
    if ! command -v systemctl >/dev/null 2>&1; then
        yellow "⚠️  无 systemctl，跳过 Docker 服务代理配置"
        return 0
    fi
    get_sudo

    $SUDO mkdir -p /etc/systemd/system/docker.service.d
    $SUDO tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null <<EOF
# 由 docker_manager.sh 生成 — Docker 守护进程拉取镜像默认代理
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
[Service]
Environment="HTTP_PROXY=${DM_EFFECTIVE_PROXY_URL}"
Environment="HTTPS_PROXY=${DM_EFFECTIVE_PROXY_URL}"
Environment="ALL_PROXY=${DM_EFFECTIVE_PROXY_URL}"
Environment="NO_PROXY=${DM_EFFECTIVE_NO_PROXY}"
EOF

    # containerd 部分环境也会拉取镜像
    if $SUDO systemctl list-unit-files 2>/dev/null | grep -q '^containerd.service'; then
        $SUDO mkdir -p /etc/systemd/system/containerd.service.d
        $SUDO tee /etc/systemd/system/containerd.service.d/http-proxy.conf >/dev/null <<EOF
[Service]
Environment="HTTP_PROXY=${DM_EFFECTIVE_PROXY_URL}"
Environment="HTTPS_PROXY=${DM_EFFECTIVE_PROXY_URL}"
Environment="ALL_PROXY=${DM_EFFECTIVE_PROXY_URL}"
Environment="NO_PROXY=${DM_EFFECTIVE_NO_PROXY}"
EOF
    fi

    $SUDO systemctl daemon-reload
    if $SUDO systemctl is-active docker >/dev/null 2>&1; then
        $SUDO systemctl restart docker 2>/dev/null || true
    fi
    green "✅ Docker/containerd 服务默认代理已写入 systemd"
}

dm_clear_docker_systemd_proxy() {
    get_sudo 2>/dev/null || true
    [[ -z "${SUDO:-}" && "$(id -u)" -ne 0 ]] && return 0
    $SUDO rm -f /etc/systemd/system/docker.service.d/http-proxy.conf 2>/dev/null || true
    $SUDO rm -f /etc/systemd/system/containerd.service.d/http-proxy.conf 2>/dev/null || true
    command -v systemctl >/dev/null 2>&1 && $SUDO systemctl daemon-reload 2>/dev/null || true
}

# Docker CLI 默认代理 (~/.docker/config.json)
dm_write_docker_client_proxy_file() {
    local cfg="$1"
    local proxy_url="$2"
    local no_proxy="$3"
    local dir
    dir="$(dirname "$cfg")"
    mkdir -p "$dir" 2>/dev/null || $SUDO mkdir -p "$dir"

    if command_exists python3; then
        DM_PROXY_CFG_PATH="$cfg" DM_PROXY_CFG_URL="$proxy_url" DM_PROXY_CFG_NOPROXY="$no_proxy" python3 <<'PY'
import json, os
path = os.environ["DM_PROXY_CFG_PATH"]
url = os.environ["DM_PROXY_CFG_URL"]
nop = os.environ["DM_PROXY_CFG_NOPROXY"]
cfg = {}
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
cfg.setdefault("proxies", {})["default"] = {
    "httpProxy": url,
    "httpsProxy": url,
    "noProxy": nop,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
    else
        cat >"$cfg" <<EOF
{
  "proxies": {
    "default": {
      "httpProxy": "${proxy_url}",
      "httpsProxy": "${proxy_url}",
      "noProxy": "${no_proxy}"
    }
  }
}
EOF
    fi
}

dm_configure_docker_client_proxy() {
    [[ "$DM_PROXY_ENABLED" != true ]] || [[ -z "$DM_EFFECTIVE_PROXY_URL" ]] && return 0
    get_sudo 2>/dev/null || true

    local cfg_paths=()
    if [ "$(id -u)" -eq 0 ]; then
        cfg_paths+=("/root/.docker/config.json")
    fi
    cfg_paths+=("${HOME}/.docker/config.json")

    if [ -n "${NORMAL_USER:-}" ] && [ "$NORMAL_USER" != "root" ]; then
        local uhome
        uhome="$(getent passwd "$NORMAL_USER" 2>/dev/null | cut -d: -f6)"
        [[ -n "$uhome" ]] && cfg_paths+=("$uhome/.docker/config.json")
    fi

    local cfg seen="" uhome_dir
    for cfg in "${cfg_paths[@]}"; do
        [[ -z "$cfg" ]] && continue
        case " $seen " in
            *" $cfg "*) continue ;;
        esac
        seen="$seen $cfg"
        uhome_dir="$(dirname "$cfg")"
        if [ ! -d "$uhome_dir" ] 2>/dev/null; then
            $SUDO mkdir -p "$uhome_dir" 2>/dev/null || mkdir -p "$uhome_dir"
        fi
        if [ -w "$uhome_dir" ] 2>/dev/null; then
            dm_write_docker_client_proxy_file "$cfg" "$DM_EFFECTIVE_PROXY_URL" "$DM_EFFECTIVE_NO_PROXY"
        else
            local tmpf
            tmpf="$(mktemp)"
            dm_write_docker_client_proxy_file "$tmpf" "$DM_EFFECTIVE_PROXY_URL" "$DM_EFFECTIVE_NO_PROXY"
            $SUDO install -m 0644 -D "$tmpf" "$cfg"
            rm -f "$tmpf"
        fi
        if [ -n "${NORMAL_USER:-}" ] && [[ "$cfg" == *"/${NORMAL_USER}/"* ]]; then
            # 目录可能由 root 创建，需整目录归还给业务用户，否则 buildx 无法写入 ~/.docker/buildx
            $SUDO chown -R "$NORMAL_USER:$NORMAL_USER" "$uhome_dir" 2>/dev/null || true
            $SUDO mkdir -p "$uhome_dir/buildx" 2>/dev/null || true
            $SUDO chown -R "$NORMAL_USER:$NORMAL_USER" "$uhome_dir" 2>/dev/null || true
        fi
    done
    green "✅ Docker CLI 默认代理已写入 ~/.docker/config.json"
}

dm_configure_docker_proxy_stack() {
    if [[ "$DM_PROXY_ENABLED" != true ]]; then
        dm_clear_docker_systemd_proxy
        dm_clear_package_manager_proxy
        return 0
    fi
    dm_configure_package_manager_proxy
    dm_configure_docker_systemd_proxy
    dm_configure_docker_client_proxy
}

dm_show_proxy_status() {
    echo "-------------------------------------------"
    if [[ "$DM_PROXY_ENABLED" == true ]]; then
        green "构建/拉取代理: 已启用 (${DM_EFFECTIVE_PROXY_TYPE})"
        echo "  URL: ${DM_EFFECTIVE_PROXY_URL%%@*}@***"
        echo "  NO_PROXY: $DM_EFFECTIVE_NO_PROXY"
    else
        yellow "构建/拉取代理: 未启用（探测失败或未配置）"
    fi
    echo "-------------------------------------------"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 获取sudo命令
get_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    elif command_exists sudo; then
        SUDO="sudo"
    elif command_exists doas; then
        SUDO="doas"
    else
        red "❌ 需要root权限，但未找到sudo或doas命令"
        exit 1
    fi
    export SUDO
}

# 获取真实的 os-release 文件路径（兼容系统伪装）
get_real_os_release() {
    if [ -f /etc/os-release.real ]; then
        echo "/etc/os-release.real"
    elif [ -f /etc/os-release ]; then
        echo "/etc/os-release"
    else
        echo ""
    fi
}

# 获取真实的 /proc/version 内容（兼容系统伪装）
get_real_proc_version() {
    # 如果 /proc/version 被挂载伪装，使用备份文件
    if [ "$(uname -s)" = "Linux" ] && mountpoint -q /proc/version 2>/dev/null; then
        if [ -f /tmp/proc-version.real ]; then
            cat /tmp/proc-version.real
            return
        fi
    fi
    # 如果备份文件存在，使用备份文件
    if [ -f /tmp/proc-version.real ]; then
        cat /tmp/proc-version.real
    elif [ -f /proc/version ]; then
        cat /proc/version
    else
        echo ""
    fi
}

# 检测系统类型
detect_system() {
    # 首先检测 FreeBSD
    if [ "$(uname -s)" = "FreeBSD" ]; then
        OS_ID="freebsd"
        OS_VERSION=$(freebsd-version | cut -d'-' -f1)
        OS="freebsd"
        IS_WSL=false

        # FreeBSD 版本检查 (最低 13.5)
        FREEBSD_MAJOR=$(echo "$OS_VERSION" | cut -d'.' -f1)
        FREEBSD_MINOR=$(echo "$OS_VERSION" | cut -d'.' -f2)
        if [ "$FREEBSD_MAJOR" -lt 13 ] || { [ "$FREEBSD_MAJOR" -eq 13 ] && [ "$FREEBSD_MINOR" -lt 5 ]; }; then
            red "FreeBSD 版本需要 13.5 或更高，当前版本: $OS_VERSION"
            exit 1
        fi

        # 检测是否在中国
        IS_CHINA_IP=false
        CHINA_IP=0
        if command_exists curl; then
            if curl -s --connect-timeout 3 "https://ipapi.co/country_code/" 2>/dev/null | grep -qi "CN\|China"; then
                IS_CHINA_IP=true
                CHINA_IP=1
            fi
        fi

        export OS OS_ID OS_VERSION IS_WSL IS_CHINA_IP CHINA_IP
        return
    fi

    # 优先使用真实系统信息（兼容系统伪装）
    # fake-os-release.sh 会将真实系统信息备份到 /etc/os-release.real
    local os_release_file=$(get_real_os_release)
    if [ -f /etc/os-release.real ]; then
        yellow "ℹ️  检测到系统伪装，使用真实系统信息进行检测"
    fi

    if [ -f "$os_release_file" ]; then
        . "$os_release_file"
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="rhel"
        # 从 /etc/redhat-release 提取版本信息
        if grep -q "release" /etc/redhat-release; then
            OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        fi
    elif [ -f /etc/debian_version ]; then
        OS_ID="debian"
        OS_VERSION=$(cat /etc/debian_version | cut -d'/' -f1)
    else
        OS_ID="unknown"
    fi

    # 检测WSL环境（使用真实系统信息）
    IS_WSL=false
    local proc_version_content=$(get_real_proc_version)
    if echo "$proc_version_content" | grep -qi microsoft 2>/dev/null || \
       echo "$proc_version_content" | grep -qi wsl 2>/dev/null || \
       [ -n "${WSL_DISTRO_NAME:-}" ]; then
        IS_WSL=true
    fi

    # 检测是否在中国
    IS_CHINA_IP=false
    CHINA_IP=0
    if command_exists curl; then
        if curl -s --connect-timeout 3 "https://ipapi.co/country_code/" 2>/dev/null | grep -qi "CN\|China"; then
            IS_CHINA_IP=true
            CHINA_IP=1
        fi
    fi

    # 统一系统标识
    case "$OS_ID" in
        ubuntu|linuxmint|pop|elementary|zorin)
            OS="ubuntu"
            ;;
        debian|raspbian|kali)
            OS="debian"
            ;;
        centos|rhel|fedora|rocky|almalinux|ol)
            OS="rhel"
            ;;
        arch|manjaro|endeavouros|garuda|cachyos)
            OS="arch"
            ;;
        deepin|uos)
            OS="deepin"
            ;;
        opensuse-leap|opensuse-tumbleweed|opensuse|sles|sled)
            OS="opensuse"
            if [ -f "$os_release_file" ]; then
                OPENSUSE_VER=$(grep -w VERSION_ID "$os_release_file" | cut -d \" -f2)
            fi
            ;;
        *)
            OS="unknown"
            ;;
    esac

    export OS IS_WSL IS_CHINA_IP CHINA_IP OPENSUSE_VER
}

# 获取普通用户名
get_normal_user() {
    if [ "$(id -u)" -eq 0 ]; then
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            NORMAL_USER="$SUDO_USER"
        elif [ -n "$username" ] && [ "$username" != "root" ]; then
            NORMAL_USER="$username"
        elif [ -n "$USER" ] && [ "$USER" != "root" ]; then
            NORMAL_USER="$USER"
        else
            NORMAL_USER=$(awk -F: '($3==1000){print $1; exit}' /etc/passwd)
            [ -z "$NORMAL_USER" ] && NORMAL_USER="root"
        fi
    else
        NORMAL_USER=$(whoami)
    fi
    export NORMAL_USER
}

# 修复 Docker CE 仓库在大陆网络下的更新失败问题
fix_docker_ce_repo_connectivity() {
    local docker_repo="/etc/yum.repos.d/docker-ce.repo"
    [ -f "${docker_repo}" ] || return 0

    # 避免 docker 源偶发网络问题阻塞系统 update
    $SUDO sed -i '/^\[docker-ce-stable\]/,/^\[/{/^[[:space:]]*skip_if_unavailable=/d}' "${docker_repo}" 2>/dev/null || true
    $SUDO sed -i '/^\[docker-ce-stable\]/a skip_if_unavailable=1' "${docker_repo}" 2>/dev/null || true

    # 大陆网络优先切到阿里云镜像
    if [ "${IS_CHINA_IP:-false}" = true ]; then
        $SUDO sed -i 's|^baseurl=https://download.docker.com/linux/centos/\$releasever/\$basearch/stable|baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/\$releasever/\$basearch/stable|g' "${docker_repo}" 2>/dev/null || true
    fi
}

# ==================== Docker安装相关函数 ====================

# Docker镜像源管理
setup_docker_mirrors() {
    local is_china="${CHINA_IP:-0}"

    # 定义镜像源
    local china_mirrors=(
        "https://mirrors.ustc.edu.cn/docker-ce/linux"
        "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux"
        "https://mirrors.aliyun.com/docker-ce/linux"
        "https://mirrors.163.com/docker-ce/linux"
    )

    local global_mirrors=(
        "https://download.docker.com/linux"
        "https://mirror.sjtu.edu.cn/docker-ce/linux"
    )

    # 根据地理位置选择镜像源
    if [ "$is_china" = "1" ]; then
        DOCKER_MIRRORS=("${china_mirrors[@]}" "${global_mirrors[@]}")
        yellow "🇨🇳 检测到中国IP，优先使用国内镜像源"
    else
        DOCKER_MIRRORS=("${global_mirrors[@]}" "${china_mirrors[@]}")
        yellow "🌍 使用国际镜像源"
    fi

    export DOCKER_MIRRORS
}

# 智能网络连接管理
smart_download() {
    local url="$1"
    local output="$2"
    local timeout="${3:-30}"
    local retries="${4:-3}"

    yellow "🌐 正在下载: $(basename "$url")"

    # ── 策略1: 代理可用时，优先使用代理加速（适用于 GitHub 等受限站点）──
    if [ "$DM_PROXY_ENABLED" = true ] && [ -n "$DM_EFFECTIVE_PROXY_URL" ]; then
        yellow "🔄 使用代理加速下载..."
        if curl -fsSL --connect-timeout "$timeout" --max-time $((timeout*2)) \
            -L --proxy "$DM_EFFECTIVE_PROXY_URL" \
            -o "$output" "$url" 2>/dev/null; then
            green "✅ 代理下载成功"
            return 0
        fi
        # 代理 -k（跳过证书校验）再试一次
        if curl -fsSL --connect-timeout "$timeout" --max-time $((timeout*2)) \
            -L --proxy "$DM_EFFECTIVE_PROXY_URL" --insecure \
            -o "$output" "$url" 2>/dev/null; then
            green "✅ 代理下载成功"
            return 0
        fi
        yellow "⚠️  代理下载失败，降级为直连..."
    fi

    # ── 策略2: 直连降级 ──
    local direct_methods=(
        "curl -fsSL --connect-timeout $timeout --max-time $((timeout*2)) -L -o '$output' '$url'"
        "wget --timeout=$timeout --tries=1 -O '$output' '$url'"
        "curl -fsSL --connect-timeout $timeout --max-time $((timeout*2)) -L --insecure -o '$output' '$url'"
    )

    # 临时禁用代理环境变量，确保直连不被干扰
    local old_http_proxy="${http_proxy:-}"
    local old_https_proxy="${https_proxy:-}"
    local old_HTTP_PROXY="${HTTP_PROXY:-}"
    local old_HTTPS_PROXY="${HTTPS_PROXY:-}"
    local old_ALL_PROXY="${ALL_PROXY:-}"
    local old_all_proxy="${all_proxy:-}"
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true

    for method in "${direct_methods[@]}"; do
        if eval "$method" 2>/dev/null; then
            green "✅ 直连下载成功"
            # 恢复代理设置
            [ -n "$old_http_proxy" ]  && export http_proxy="$old_http_proxy"
            [ -n "$old_https_proxy" ] && export https_proxy="$old_https_proxy"
            [ -n "$old_HTTP_PROXY" ]  && export HTTP_PROXY="$old_HTTP_PROXY"
            [ -n "$old_HTTPS_PROXY" ] && export HTTPS_PROXY="$old_HTTPS_PROXY"
            [ -n "$old_ALL_PROXY" ]   && export ALL_PROXY="$old_ALL_PROXY"
            [ -n "$old_all_proxy" ]   && export all_proxy="$old_all_proxy"
            return 0
        fi
    done

    # 恢复代理设置
    [ -n "$old_http_proxy" ]  && export http_proxy="$old_http_proxy"
    [ -n "$old_https_proxy" ] && export https_proxy="$old_https_proxy"
    [ -n "$old_HTTP_PROXY" ]  && export HTTP_PROXY="$old_HTTP_PROXY"
    [ -n "$old_HTTPS_PROXY" ] && export HTTPS_PROXY="$old_HTTPS_PROXY"
    [ -n "$old_ALL_PROXY" ]   && export ALL_PROXY="$old_ALL_PROXY"
    [ -n "$old_all_proxy" ]   && export all_proxy="$old_all_proxy"

    red "❌ 下载失败: $url"
    return 1
}

# 测试镜像源连通性
test_docker_mirror() {
    local mirror_url="$1"
    local os_name="$2"

    yellow "🔍 测试镜像源: $mirror_url"

    # 测试GPG密钥下载
    if smart_download "${mirror_url}/${os_name}/gpg" "/tmp/docker_test_gpg" 10 1; then
        rm -f "/tmp/docker_test_gpg"
        green "✅ 镜像源连接正常: $mirror_url"
        return 0
    else
        red "❌ 镜像源连接失败: $mirror_url"
        return 1
    fi
}

# 等待APT锁定释放
wait_for_apt_lock() {
    local max_wait=600  # 最大等待10分钟
    local wait_time=0
    local lock_files=(
        "/var/lib/dpkg/lock"
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/apt/lists/lock"
        "/var/cache/apt/archives/lock"
    )

    yellow "🔒 检查APT锁定状态..."

    while [ $wait_time -lt $max_wait ]; do
        local locked=false

        # 检查锁定文件
        for lock_file in "${lock_files[@]}"; do
            if $SUDO lsof "$lock_file" >/dev/null 2>&1; then
                locked=true
                local process_info=$($SUDO lsof "$lock_file" 2>/dev/null | grep -v COMMAND | head -1)
                if [ -n "$process_info" ]; then
                    local pid=$(echo "$process_info" | awk '{print $2}')
                    local cmd=$(echo "$process_info" | awk '{print $1}')
                    yellow "⏳ APT被进程锁定: $cmd (PID: $pid), 等待解锁... (${wait_time}s/${max_wait}s)"
                fi
                break
            fi
        done

        # 如果没有锁定，退出循环
        if [ "$locked" = false ]; then
            green "✅ APT锁定已释放"
            return 0
        fi

        sleep 3
        wait_time=$((wait_time + 3))
    done

    # 超时处理
    red "⚠️  等待APT锁定释放超时 (${max_wait}s)"
    yellow "正在尝试强制解锁..."

    # 强制解锁
    for lock_file in "${lock_files[@]}"; do
        if [ -f "$lock_file" ]; then
            $SUDO rm -f "$lock_file" 2>/dev/null || true
        fi
    done

    # 终止相关进程
    $SUDO pkill -f "apt-get|apt|dpkg" 2>/dev/null || true
    sleep 2

    # 修复dpkg
    $SUDO dpkg --configure -a 2>/dev/null || true

    green "🔧 强制解锁完成"
    return 0
}

# 安全的APT操作包装器
safe_apt_update() {
    wait_for_apt_lock
    yellow "📦 更新软件包列表..."
    if ! $SUDO apt-get update; then
        red "❌ 软件包列表更新失败"
        return 1
    fi
    green "✅ 软件包列表更新成功"
}

safe_apt_install() {
    wait_for_apt_lock
    yellow "📦 安装软件包: $*"
    if ! $SUDO apt-get install -y "$@"; then
        red "❌ 软件包安装失败: $*"
        return 1
    fi
    green "✅ 软件包安装成功: $*"
}

# 在Arch Linux上安装Docker
install_docker_arch() {
    yellow "🐳 开始在 Arch Linux 系统上安装 Docker..."
    $SUDO pacman -S --noconfirm docker docker-compose
    green "✅ Arch Linux Docker安装完成"
}

# 在FreeBSD上安装Docker（使用Podman作为替代）
install_docker_freebsd() {
    yellow "🐳 FreeBSD Docker 兼容方案"
    echo ""
    yellow "⚠️  FreeBSD 不原生支持 Docker，但提供以下替代方案："
    echo ""
    echo "  1. Podman - Docker 兼容的容器运行时（推荐）"
    echo "  2. 使用 bhyve 虚拟化运行 Linux + Docker"
    echo "  3. 使用 jail 容器（FreeBSD 原生）"
    echo ""

    readp "是否安装 Podman 作为 Docker 替代方案？(Y/n): " install_podman
    if [[ ! "$install_podman" =~ ^[Nn]$ ]]; then
        yellow "📦 正在安装 Podman..."
        $SUDO pkg install -y podman buildah skopeo

        # 配置 Podman
        $SUDO mkdir -p /usr/local/etc/containers

        # 创建 registries.conf
        if [ ! -f /usr/local/etc/containers/registries.conf ]; then
            cat > /tmp/registries.conf << 'EOF'
[registries.search]
registries = ['docker.io', 'quay.io']

[registries.insecure]
registries = []

[registries.block]
registries = []
EOF
            $SUDO mv /tmp/registries.conf /usr/local/etc/containers/registries.conf
        fi

        # 创建 docker 别名
        if ! grep -q "alias docker=" ~/.bashrc 2>/dev/null; then
            echo 'alias docker="podman"' >> ~/.bashrc
            echo 'alias docker-compose="podman-compose"' >> ~/.bashrc
        fi

        # 安装 podman-compose
        if command_exists pip3; then
            pip3 install podman-compose
        else
            $SUDO pkg install -y py39-pip
            pip3 install podman-compose
        fi

        green "✅ Podman 安装完成！"
        echo ""
        yellow "💡 使用提示："
        echo "   - Podman 命令与 Docker 基本兼容"
        echo "   - 已创建 'docker' 别名指向 'podman'"
        echo "   - 使用 'podman-compose' 替代 'docker-compose'"
        echo "   - 重新登录或运行 'source ~/.bashrc' 使别名生效"
    else
        yellow "跳过 Podman 安装"
        echo ""
        yellow "💡 其他方案："
        echo "   - bhyve: pkg install vm-bhyve"
        echo "   - jail: 使用 FreeBSD 原生 jail 容器"
    fi
}

# 自动安装Docker（使用官方脚本）
auto_install_docker() {
    yellow "🚀 使用Docker官方安装脚本..."

    # 确保docker组存在
    if ! getent group docker >/dev/null 2>&1; then
        yellow "👥 创建docker组..."
        $SUDO groupadd docker 2>/dev/null || true
    fi

    # 下载并执行安装脚本
    local script_urls=(
        "https://get.docker.com"
        "https://test.docker.com"
        "https://mirror.azure.cn/docker-ce/linux/static/get-docker.sh"
    )

    local script_downloaded=false
    for script_url in "${script_urls[@]}"; do
        yellow "🔽 尝试下载安装脚本: $script_url"
        if smart_download "$script_url" "/tmp/get-docker.sh" 30; then
            script_downloaded=true
            break
        fi
    done

    if [ "$script_downloaded" = false ]; then
        red "❌ 无法下载Docker安装脚本"
        return 1
    fi

    # 执行安装脚本
    yellow "⚙️  执行Docker安装脚本..."
    if $SUDO sh /tmp/get-docker.sh --mirror Aliyun; then
        green "✅ Docker安装脚本执行成功"
        rm -f /tmp/get-docker.sh

        # WSL特殊处理
        if [ "$IS_WSL" = true ]; then
            yellow "🐧 检测到WSL环境，安装uidmap..."
            $SUDO apt-get install -y uidmap 2>/dev/null || true
        fi
    else
        red "❌ Docker安装脚本执行失败"
        rm -f /tmp/get-docker.sh
        return 1
    fi

    # 确保docker组存在
    if ! getent group docker >/dev/null 2>&1; then
        yellow "👥 创建docker组..."
        $SUDO groupadd docker 2>/dev/null || true
    fi

    return 0
}

# 在Debian/Ubuntu上安装Docker
install_docker_debian() {
    yellow "🐳 开始在 ${OS} 系统上安装 Docker..."

    # 设置镜像源
    setup_docker_mirrors

    # 卸载旧版本
    yellow "🗑️  清理旧版本Docker..."
    safe_apt_update
    $SUDO apt-get remove docker docker-engine docker.io containerd runc -y 2>/dev/null || true

    # 安装依赖包
    yellow "📦 安装依赖包..."
    if ! safe_apt_install ca-certificates curl gnupg lsb-release; then
        red "❌ 依赖包安装失败"
        return 1
    fi

    # 清理旧的Docker配置
    yellow "🧹 清理旧的Docker配置..."
    $SUDO rm -f /etc/apt/keyrings/docker*.asc /etc/apt/keyrings/docker*.gpg 2>/dev/null || true
    $SUDO rm -f /etc/apt/sources.list.d/docker*.list 2>/dev/null || true

    # 创建密钥目录
    $SUDO install -m 0755 -d /etc/apt/keyrings

    # 尝试添加Docker仓库
    local gpg_added=false
    local repo_added=false

    yellow "🔑 正在配置Docker仓库..."

    # 遍历镜像源，找到可用的
    for mirror_url in "${DOCKER_MIRRORS[@]}"; do
        yellow "🔍 尝试镜像源: $mirror_url"

        # 测试连通性
        if ! test_docker_mirror "$mirror_url" "$OS"; then
            continue
        fi

        # 下载GPG密钥
        local gpg_file="/etc/apt/keyrings/docker-$(basename "$mirror_url" | tr '.' '-').gpg"
        if smart_download "${mirror_url}/${OS}/gpg" "/tmp/docker.gpg" 15; then
            if $SUDO gpg --dearmor -o "$gpg_file" "/tmp/docker.gpg" 2>/dev/null; then
                $SUDO chmod a+r "$gpg_file"
                rm -f "/tmp/docker.gpg"

                # 添加仓库源
                local codename
                local os_release_file=$(get_real_os_release)
                if [[ "${OS}" == "debian" ]]; then
                    codename=$(. "$os_release_file" && echo "$VERSION_CODENAME")
                else
                    codename=$(. "$os_release_file" && echo "$UBUNTU_CODENAME")
                    # 如果没有UBUNTU_CODENAME，使用VERSION_CODENAME
                    [ -z "$codename" ] && codename=$(. "$os_release_file" && echo "$VERSION_CODENAME")
                fi

                if [ -n "$codename" ]; then
                    echo "deb [arch=$(dpkg --print-architecture) signed-by=${gpg_file}] ${mirror_url}/${OS} ${codename} stable" | \
                    $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null

                    green "✅ 成功配置Docker仓库: $mirror_url"
                    gpg_added=true
                    repo_added=true
                    break
                else
                    red "❌ 无法获取系统代码名称"
                fi
            else
                red "❌ GPG密钥处理失败"
                rm -f "/tmp/docker.gpg"
            fi
        fi
    done

    # 如果仓库配置失败，尝试使用官方安装脚本
    if [ "$repo_added" = false ]; then
        yellow "⚠️  仓库配置失败，尝试使用Docker官方安装脚本..."
        return install_docker_with_script
    fi

    # 更新包索引
    if ! safe_apt_update; then
        yellow "⚠️  包索引更新失败，尝试使用官方安装脚本..."
        return install_docker_with_script
    fi

    # 检查Docker包是否可用
    if ! apt-cache search docker-ce | grep -q "^docker-ce "; then
        yellow "⚠️  Docker包不可用，尝试使用官方安装脚本..."
        return install_docker_with_script
    fi

    # 安装Docker包
    yellow "📦 安装Docker包..."
    if ! safe_apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        yellow "⚠️  Docker包安装失败，尝试使用官方安装脚本..."
        return install_docker_with_script
    fi

    green "✅ Docker安装成功"
    return 0
}

# 使用Docker官方安装脚本
install_docker_with_script() {
    auto_install_docker
}

# 在RHEL/CentOS上安装Docker
install_docker_rhel() {
    yellow "🐳 开始在 RHEL/CentOS 系统上安装 Docker..."

    # 检测包管理器：AlmaLinux/Rocky 8+ 和 Fedora 使用 dnf，旧版 CentOS 7 使用 yum
    local PKG_MGR="yum"
    if command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    fi

    # 卸载旧版本
    $SUDO $PKG_MGR remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine -y 2>/dev/null || true

    # 安装依赖
    $SUDO $PKG_MGR install -y yum-utils device-mapper-persistent-data lvm2

    # 定义镜像源列表
    local repo_urls=(
        "https://mirrors.ustc.edu.cn/docker-ce/linux/centos/docker-ce.repo"
        "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/centos/docker-ce.repo"
        "https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo"
        "https://download.docker.com/linux/centos/docker-ce.repo"
    )

    # 如果不是中国IP，优先使用官方源
    if [ "$IS_CHINA_IP" != true ]; then
        repo_urls=(
            "https://download.docker.com/linux/centos/docker-ce.repo"
            "https://mirrors.ustc.edu.cn/docker-ce/linux/centos/docker-ce.repo"
            "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/centos/docker-ce.repo"
            "https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo"
        )
    fi

    # 尝试下载并添加Docker仓库
    local repo_added=false
    for repo_url in "${repo_urls[@]}"; do
        yellow "🔍 尝试镜像源: $(echo "$repo_url" | sed 's|/docker-ce.repo||')"

        # 清理旧的repo文件
        $SUDO rm -f /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true

        # 下载repo文件
        if smart_download "$repo_url" "/tmp/docker-ce.repo" 30; then
            # 替换镜像源URL
            if [ "$IS_CHINA_IP" = true ]; then
                # 使用下载的镜像源本身，并替换 gpgkey 为镜像源地址
                local mirror_base_url=$(echo "$repo_url" | sed 's|/docker-ce.repo||')
                $SUDO sed -i "s|https://download.docker.com/linux/centos/gpg|${mirror_base_url}/gpg|g" /tmp/docker-ce.repo
                $SUDO cp /tmp/docker-ce.repo /etc/yum.repos.d/docker-ce.repo
            else
                # 非中国IP，使用官方源但保留下载的文件
                $SUDO cp /tmp/docker-ce.repo /etc/yum.repos.d/docker-ce.repo
            fi

            # 清理缓存
            $SUDO $PKG_MGR clean all 2>/dev/null || true

            # 测试仓库是否可用
            if [ "$PKG_MGR" = "dnf" ]; then
                if $SUDO dnf makecache --refresh 2>/dev/null; then
                    repo_added=true
                    green "✅ 成功配置Docker仓库: $repo_url"
                    break
                else
                    yellow "⚠️  仓库缓存更新失败，尝试下一个镜像源..."
                fi
            else
                if $SUDO yum makecache fast 2>/dev/null; then
                    repo_added=true
                    green "✅ 成功配置Docker仓库: $repo_url"
                    break
                else
                    yellow "⚠️  仓库缓存更新失败，尝试下一个镜像源..."
                fi
            fi
        fi
    done

    # 清理临时文件
    rm -f /tmp/docker-ce.repo 2>/dev/null || true

    if [ "$repo_added" = false ]; then
        red "❌ 所有镜像源均无法连接，尝试手动创建仓库配置..."

        # 手动创建repo文件（使用中科大镜像）
        $SUDO tee /etc/yum.repos.d/docker-ce.repo > /dev/null << 'EOF'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://mirrors.ustc.edu.cn/docker-ce/linux/centos/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://mirrors.ustc.edu.cn/docker-ce/linux/centos/gpg

[docker-ce-stable-debuginfo]
name=Docker CE Stable - Debuginfo $basearch
baseurl=https://mirrors.ustc.edu.cn/docker-ce/linux/centos/$releasever/debug-$basearch/stable
enabled=0
gpgcheck=1
gpgkey=https://mirrors.ustc.edu.cn/docker-ce/linux/centos/gpg

[docker-ce-stable-source]
name=Docker CE Stable - Sources
baseurl=https://mirrors.ustc.edu.cn/docker-ce/linux/centos/$releasever/source/stable
enabled=0
gpgcheck=1
gpgkey=https://mirrors.ustc.edu.cn/docker-ce/linux/centos/gpg
EOF

        # 再次尝试
        if [ "$PKG_MGR" = "dnf" ]; then
            if $SUDO dnf makecache --refresh 2>/dev/null; then
                green "✅ 手动配置仓库成功"
                repo_added=true
            fi
        else
            if $SUDO yum makecache fast 2>/dev/null; then
                green "✅ 手动配置仓库成功"
                repo_added=true
            fi
        fi

        if [ "$repo_added" = false ]; then
            red "❌ 无法配置Docker仓库，请检查网络连接"
            return 1
        fi
    fi

    # 安装流程自动修复仓库连通性配置（菜单 1 默认生效）
    fix_docker_ce_repo_connectivity

    # 安装Docker
    yellow "📦 正在安装Docker..."
    $SUDO $PKG_MGR install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    green "✅ RHEL/CentOS Docker安装完成"
}

# 在openSUSE上安装Docker
install_docker_opensuse() {
    yellow "🐳 开始在 openSUSE 系统上安装 Docker..."

    # 卸载旧版本
    yellow "🗑️  清理旧版本Docker..."
    $SUDO zypper --non-interactive remove docker docker-client docker-compose containerd runc 2>/dev/null || true

    # 安装依赖
    yellow "📦 安装依赖包..."
    $SUDO zypper --non-interactive install -y \
        ca-certificates \
        curl \
        lsb-release \
        wget || {
        yellow "⚠️  部分依赖安装失败，继续尝试..."
    }

    # 检测openSUSE版本
    local opensuse_version="${OPENSUSE_VER:-15.5}"
    yellow "📋 检测到 openSUSE 版本: ${opensuse_version}"

    # 首先尝试从系统默认仓库安装（openSUSE 可能已经包含 Docker）
    yellow "🔍 尝试从系统默认仓库安装Docker..."
    if $SUDO zypper --non-interactive install -y docker docker-compose 2>/dev/null; then
        green "✅ Docker从系统默认仓库安装成功"
        return 0
    fi

    # 如果系统仓库没有，尝试添加 Docker 官方仓库
    yellow "🔍 尝试添加Docker官方仓库..."

    local docker_repo_url=""
    local os_release_file=$(get_real_os_release)

    if grep -qi "tumbleweed" "$os_release_file" 2>/dev/null; then
        docker_repo_url="https://download.docker.com/linux/opensuse-tumbleweed"
    else
        # 对于 Leap，使用通用路径（Docker 官方可能不直接支持，但尝试一下）
        docker_repo_url="https://download.docker.com/linux/opensuse"
    fi

    # 配置Docker仓库（中国镜像源）
    if [[ "$IS_CHINA_IP" == true ]]; then
        yellow "🇨🇳 检测到中国IP，使用国内镜像源..."
        docker_repo_url="https://mirrors.ustc.edu.cn/docker-ce/linux/opensuse"
    fi

    # 移除可能存在的旧Docker仓库
    $SUDO rm -f /etc/zypp/repos.d/docker*.repo 2>/dev/null || true
    $SUDO zypper removerepo docker 2>/dev/null || true

    # 尝试添加Docker仓库（openSUSE 的 Docker 仓库支持有限，可能失败）
    local repo_added=false

    # 方法1: 尝试使用 rpm-md 类型
    if $SUDO zypper addrepo -f -t rpm-md "${docker_repo_url}" docker 2>/dev/null; then
        if $SUDO zypper --non-interactive refresh docker 2>/dev/null; then
            repo_added=true
            yellow "✅ Docker仓库添加并刷新成功"
        fi
    fi

    # 如果仓库添加成功，尝试安装
    if [[ "$repo_added" == true ]]; then
        yellow "📦 从Docker仓库安装Docker包..."
        if $SUDO zypper --non-interactive install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null; then
            green "✅ Docker CE从仓库安装成功"
            return 0
        fi
    fi

    # 如果以上方法都失败，使用 Docker 官方安装脚本（最可靠的方法）
    yellow "📦 Docker仓库方法不可用，使用Docker官方安装脚本（推荐）..."
    yellow "ℹ️  这是 openSUSE 上安装 Docker 最可靠的方法"
    install_docker_with_script
    return $?
}

# 安装docker-compose
install_docker_compose() {
    if [ -e "/usr/local/bin/docker-compose" ] || [ -e "/usr/bin/docker-compose" ]; then
        green "✅ docker-compose已存在"
        return 0
    fi

    yellow "📦 安装docker-compose..."

    # 获取最新版本号（优先使用代理访问 GitHub API）
    local compose_version
    local version_urls=(
        "https://api.github.com/repos/docker/compose/releases/latest"
        "https://mirror.ghproxy.com/https://api.github.com/repos/docker/compose/releases/latest"
    )

    for version_url in "${version_urls[@]}"; do
        local _curl_proxy=""
        if [ "$DM_PROXY_ENABLED" = true ] && [ -n "$DM_EFFECTIVE_PROXY_URL" ]; then
            _curl_proxy="--proxy $DM_EFFECTIVE_PROXY_URL"
        fi
        if compose_version=$(curl -s $_curl_proxy --connect-timeout 10 "$version_url" 2>/dev/null | grep 'tag_name' | cut -d\" -f4); then
            if [ -n "$compose_version" ]; then
                break
            fi
        fi
        # 代理失败时不传代理再试一次
        if compose_version=$(curl -s --connect-timeout 10 "$version_url" 2>/dev/null | grep 'tag_name' | cut -d\" -f4); then
            if [ -n "$compose_version" ]; then
                break
            fi
        fi
    done

    # 如果获取版本失败，使用默认版本
    if [ -z "$compose_version" ]; then
        compose_version="v2.24.0"
        yellow "⚠️  无法获取最新版本，使用默认版本: $compose_version"
    else
        green "📋 获取到最新版本: $compose_version"
    fi

    # 下载docker-compose
    local arch=$(uname -m)
    local os_name=$(uname -s)
    # GitHub 新版本(v5.x)使用小写 linux，旧版本使用大写 Linux
    local os_name_lower=$(echo "$os_name" | tr '[:upper:]' '[:lower:]')
    local download_urls=(
        "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-${os_name_lower}-${arch}"
        "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-${os_name}-${arch}"
        "https://mirror.ghproxy.com/https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-${os_name_lower}-${arch}"
        "https://mirror.ghproxy.com/https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-${os_name}-${arch}"
        "https://mirrors.aliyun.com/docker-toolbox/linux/compose/docker-compose-${os_name_lower}-${arch}"
        "https://mirrors.aliyun.com/docker-toolbox/linux/compose/docker-compose-${os_name}-${arch}"
    )

    local compose_downloaded=false
    for download_url in "${download_urls[@]}"; do
        yellow "🔽 尝试下载: $download_url"
        if smart_download "$download_url" "/tmp/docker-compose" 60; then
            compose_downloaded=true
            break
        fi
    done

    if [ "$compose_downloaded" = false ]; then
        red "❌ docker-compose下载失败"
        return 1
    fi

    # 安装docker-compose
    $SUDO mv /tmp/docker-compose /usr/local/bin/docker-compose
    $SUDO chmod +x /usr/local/bin/docker-compose

    # 创建符号链接
    if [ ! -e "/usr/bin/docker-compose" ]; then
        $SUDO ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true
    fi

    green "✅ docker-compose安装成功"
    return 0
}

# 更新 Docker 和 Docker Compose
upgrade_docker_and_compose() {
    yellow "🔄 开始更新 Docker 和 Docker Compose..."

    # 先做系统检测，确保 OS 变量可用
    detect_system

    case "$OS" in
        debian|ubuntu)
            # 修复仓库连通性（含国内镜像自动适配）
            fix_docker_ce_repo_connectivity

            if ! safe_apt_update; then
                red "❌ apt 包索引更新失败"
                return 1
            fi

            if ! safe_apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
                red "❌ Docker 组件更新失败"
                return 1
            fi
            ;;
        arch|manjaro|garuda|cachyos)
            $SUDO pacman -Syu --noconfirm docker docker-compose docker-buildx || {
                red "❌ Arch 系统更新 Docker 失败"
                return 1
            }
            ;;
        rhel|almalinux|centos|rocky|fedora)
            # 修复仓库连通性，避免 docker-ce 包不可用
            fix_docker_ce_repo_connectivity
            if command_exists dnf; then
                $SUDO dnf makecache --refresh -y >/dev/null 2>&1 || true
                $SUDO dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
                    red "❌ dnf 更新 Docker 失败"
                    return 1
                }
            else
                $SUDO yum makecache fast >/dev/null 2>&1 || true
                $SUDO yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
                    red "❌ yum 更新 Docker 失败"
                    return 1
                }
            fi
            ;;
        opensuse)
            # openSUSE 优先使用系统仓库包
            $SUDO zypper --non-interactive refresh >/dev/null 2>&1 || true
            $SUDO zypper --non-interactive install -y docker docker-compose || {
                red "❌ openSUSE 更新 Docker 失败"
                return 1
            }
            ;;
        *)
            red "❌ 当前系统暂不支持自动更新 Docker: $OS"
            return 1
            ;;
    esac

    # 重启并检查服务状态
    if command_exists systemctl; then
        $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
        $SUDO systemctl enable docker >/dev/null 2>&1 || true
        $SUDO systemctl restart docker || {
            red "❌ Docker 服务重启失败"
            return 1
        }
        sleep 2
        if ! $SUDO systemctl is-active docker >/dev/null 2>&1; then
            red "❌ Docker 服务未正常运行"
            return 1
        fi
    fi

    green "✅ Docker 和 Docker Compose 更新完成"
    show_docker_status
    return 0
}

# 检测并修复Docker服务的systemd limits问题
fix_docker_systemd_limits() {
    yellow "🔧 检查Docker服务的systemd limits配置..."

    # 检查是否存在limits问题的系统
    local need_limits_fix=false

    # CachyOS和其他Arch系衍生版经常遇到limits问题
    local os_release_file=$(get_real_os_release)
    if [[ -n "$os_release_file" && -f "$os_release_file" ]]; then
        local os_id=$(grep "^ID=" "$os_release_file" | cut -d= -f2 | tr -d '"')
        local os_id_like=$(grep "^ID_LIKE=" "$os_release_file" | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "")

        if [[ "$os_id" =~ ^(cachyos|manjaro|endeavouros|garuda)$ ]] || [[ "$os_id_like" =~ arch ]]; then
            yellow "🎯 检测到 $os_id 系统，可能需要调整Docker服务limits"
            need_limits_fix=true
        fi
    fi

    # 检查Docker服务状态，看是否有limits错误
    if command -v systemctl >/dev/null 2>&1; then
        local docker_status=$($SUDO systemctl status docker --no-pager 2>/dev/null || echo "")
        if echo "$docker_status" | grep -q "status=205/LIMITS\|Main process exited.*code=205"; then
            yellow "🚨 检测到Docker服务因LIMITS问题启动失败"
            need_limits_fix=true
        fi
    fi

    # 如果需要修复limits问题
    if [ "$need_limits_fix" = true ]; then
        yellow "🔧 正在修复Docker服务的systemd limits配置..."

        # 停止Docker服务
        yellow "⏹️  停止Docker服务..."
        $SUDO systemctl stop docker 2>/dev/null || true

        # 创建systemd服务覆盖目录
        $SUDO mkdir -p /etc/systemd/system/docker.service.d

        # 创建limits配置文件
        $SUDO tee /etc/systemd/system/docker.service.d/limits.conf > /dev/null << 'EOF'
[Service]
# 允许更多线程/进程
TasksMax=infinity
# 允许打开更多文件
LimitNOFILE=infinity
LimitNPROC=infinity
# 允许更多内存映射
LimitMEMLOCK=infinity
# 调整其他资源限制
LimitCORE=infinity
# 设置合理的超时时间
TimeoutStartSec=0
KillMode=process
Restart=on-failure
RestartSec=2
EOF

        green "✅ 已创建Docker服务limits配置文件"

        # 重新加载systemd配置
        yellow "🔄 重新加载systemd配置..."
        $SUDO systemctl daemon-reload
        $SUDO systemctl daemon-reexec

        green "✅ systemd limits配置修复完成"
        return 0
    else
        green "✅ 系统无需调整Docker服务limits"
        return 0
    fi
}

# 修复Docker服务limits问题（独立功能）
repair_docker_limits() {
    blue "🐳 Docker systemd limits 修复工具"
    echo "=================================="

    # 检查systemctl是否可用
    if ! command -v systemctl >/dev/null 2>&1; then
        red "❌ systemctl命令不可用，无法管理Docker服务"
        return 1
    fi

    # 检查Docker服务状态
    yellow "🔍 检查Docker服务状态..."

    local docker_status=$($SUDO systemctl status docker --no-pager 2>/dev/null || echo "")

    if echo "$docker_status" | grep -q "status=205/LIMITS\|Main process exited.*code=205"; then
        yellow "🚨 确认检测到Docker服务因LIMITS问题启动失败"
    elif $SUDO systemctl is-active docker >/dev/null 2>&1; then
        green "✅ Docker服务运行正常，但仍将执行预防性修复..."
    else
        yellow "⚠️  Docker服务未运行，将尝试修复并启动..."
    fi

    # 执行修复
    fix_docker_systemd_limits

    # 启动Docker服务
    yellow "🚀 启动Docker服务..."

    if $SUDO systemctl start docker; then
        green "✅ Docker服务启动成功"
    else
        red "❌ Docker服务启动失败"
        yellow "📋 查看详细错误信息:"
        $SUDO systemctl status docker --no-pager || true
        return 1
    fi

    # 等待服务完全启动
    yellow "⏳ 等待Docker服务完全启动..."
    local wait_count=0
    while [ $wait_count -lt 10 ]; do
        if $SUDO systemctl is-active docker >/dev/null 2>&1; then
            green "✅ Docker服务运行正常"
            break
        fi
        sleep 2
        wait_count=$((wait_count + 1))
    done

    if [ $wait_count -ge 10 ]; then
        red "❌ Docker服务启动超时"
        return 1
    fi

    # 启用Docker服务自启动
    if $SUDO systemctl enable docker 2>/dev/null; then
        green "✅ Docker服务已设置为开机自启"
    fi

    # 验证Docker功能
    yellow "🔍 验证Docker功能..."

    # 检查Docker版本
    if docker version >/dev/null 2>&1; then
        green "✅ Docker命令行工具正常"
        docker version --format "Docker版本: {{.Server.Version}}" 2>/dev/null || docker --version
    else
        yellow "⚠️  Docker命令行工具需要重新登录生效"
    fi

    # 检查Docker信息
    if docker info >/dev/null 2>&1; then
        green "✅ Docker守护进程连接正常"
    else
        yellow "⚠️  Docker守护进程连接需要权限调整，请重新登录或运行: newgrp docker"
    fi

    echo ""
    green "🎉 Docker服务修复完成！"
    yellow "💡 如果仍有权限问题，请重新登录或运行: newgrp docker"

    return 0
}

# 启动Docker服务
start_docker_service() {
    yellow "\n🚀 启动Docker服务..."

    # 检查systemd是否可用
    if ! command -v systemctl >/dev/null 2>&1; then
        yellow "⚠️  systemctl不可用，跳过服务启动"
        return 0
    fi

    # 重新加载systemd配置
    $SUDO systemctl daemon-reload 2>/dev/null || true

    # 检查docker.service是否存在
    if ! $SUDO systemctl list-unit-files | grep -q "docker.service"; then
        red "❌ docker.service文件不存在"
        yellow "🔍 尝试查找Docker服务文件..."

        # 尝试查找服务文件
        local service_paths=(
            "/lib/systemd/system/docker.service"
            "/usr/lib/systemd/system/docker.service"
            "/etc/systemd/system/docker.service"
        )

        local found_service=false
        for service_path in "${service_paths[@]}"; do
            if [ -f "$service_path" ]; then
                green "✅ 找到服务文件: $service_path"
                found_service=true
                break
            fi
        done

        if [ "$found_service" = false ]; then
            yellow "⚠️  Docker服务文件缺失，尝试重新安装..."
            return 1
        fi

        # 重新加载服务
        $SUDO systemctl daemon-reload
    fi

    # 启用Docker服务
    if $SUDO systemctl enable docker 2>/dev/null; then
        green "✅ Docker服务启用成功"
    else
        yellow "⚠️  Docker服务启用失败"
    fi

    # 启动Docker服务
    yellow "▶️  启动Docker服务..."
    if $SUDO systemctl start docker 2>/dev/null; then
        green "✅ Docker服务启动成功"
    else
        red "❌ Docker服务启动失败"
        yellow "🔍 检查服务状态..."
        $SUDO systemctl status docker --no-pager || true

        # 检查是否是limits问题并尝试修复
        local docker_status=$($SUDO systemctl status docker --no-pager 2>/dev/null || echo "")
        if echo "$docker_status" | grep -q "status=205/LIMITS\|Main process exited.*code=205"; then
            yellow "🔧 检测到LIMITS问题，尝试自动修复..."
            if fix_docker_systemd_limits; then
                yellow "🔄 重新启动Docker服务..."
                if $SUDO systemctl start docker 2>/dev/null; then
                    green "✅ Docker服务修复后启动成功"
                else
                    red "❌ Docker服务修复后仍然启动失败"
                    $SUDO systemctl status docker --no-pager || true
                    return 1
                fi
            else
                red "❌ 无法修复Docker服务limits问题"
                return 1
            fi
        else
            return 1
        fi
    fi

    # 等待服务完全启动
    yellow "⏳ 等待Docker服务完全启动..."
    local wait_count=0
    while [ $wait_count -lt 10 ]; do
        if $SUDO systemctl is-active docker >/dev/null 2>&1; then
            green "✅ Docker服务运行正常"
            break
        fi
        sleep 2
        wait_count=$((wait_count + 1))
    done

    if [ $wait_count -ge 10 ]; then
        red "❌ Docker服务启动超时"
        return 1
    fi

    return 0
}

# 从 /etc/containerd/config.toml 读取当前生效的 root（无有效行则返回空）
get_containerd_root_from_config() {
    if [ ! -f /etc/containerd/config.toml ]; then
        echo ""
        return 0
    fi
    local line
    line=$($SUDO grep -E '^[[:space:]]*root[[:space:]]*=' /etc/containerd/config.toml 2>/dev/null | head -1)
    if [ -z "$line" ]; then
        echo ""
        return 0
    fi
    echo "$line" | sed -n 's/^[[:space:]]*root[[:space:]]*=[[:space:]]*["'\'']\([^"'\'']*\)["'\''].*/\1/p'
}

# 写入或更新 containerd 的 root 到 config.toml（不含数据迁移）
_apply_containerd_root_config() {
    local containerd_root="$1"
    $SUDO mkdir -p /etc/containerd

    if [ ! -f /etc/containerd/config.toml ]; then
        if containerd config default >/dev/null 2>&1; then
            containerd config default | $SUDO tee /etc/containerd/config.toml >/dev/null
        else
            $SUDO tee /etc/containerd/config.toml >/dev/null << EOF
version = 2
root = "$containerd_root"
state = "/run/containerd"
EOF
        fi
    fi

    if $SUDO grep -qE '^[[:space:]]*#?[[:space:]]*root[[:space:]]*=' /etc/containerd/config.toml 2>/dev/null; then
        $SUDO sed -i 's|^[[:space:]]*#\?[[:space:]]*root[[:space:]]*=.*|root = "'"$containerd_root"'"|' /etc/containerd/config.toml
    else
        if $SUDO grep -qE '^[[:space:]]*version[[:space:]]*=' /etc/containerd/config.toml; then
            $SUDO sed -i '/^[[:space:]]*version[[:space:]]*=/a root = "'"$containerd_root"'"' /etc/containerd/config.toml
        else
            $SUDO sed -i '1i root = "'"$containerd_root"'"' /etc/containerd/config.toml
        fi
    fi
}

# 配置 containerd 数据目录（默认 /data/containerd；install_docker 无参调用即自动迁移至此）
# 参数 $1：可选目标目录绝对路径；菜单项 8 可传入用户输入以再次迁移到其他盘
setup_containerd_data_path() {
    # FreeBSD 使用不同架构，跳过
    [ "${OS:-}" = "freebsd" ] && return 0

    # 检查 containerd 是否已安装
    if ! command_exists containerd && [ ! -x /usr/bin/containerd ]; then
        return 0
    fi

    local containerd_root="${1:-${CONTAINERD_DATA_PATH:-/data/containerd}}"
    containerd_root="${containerd_root%/}"

    if [ -z "$containerd_root" ] || [ "${containerd_root#/}" = "$containerd_root" ]; then
        red "❌ containerd 数据目录必须是绝对路径（以 / 开头）"
        return 1
    fi

    # 当前数据位置：无配置时与 containerd 默认一致
    local current_root
    current_root=$(get_containerd_root_from_config)
    [ -z "$current_root" ] && current_root="/var/lib/containerd"
    current_root="${current_root%/}"

    # 目标不能位于当前数据目录之下（避免 rsync 递归问题）
    if [ -n "$current_root" ] && [ "$current_root" != "/" ] && [[ "$containerd_root" == "$current_root"/* ]]; then
        red "❌ 目标目录不能位于当前数据目录之下: $current_root"
        return 1
    fi

    yellow "🔧 配置 containerd 数据目录: $containerd_root"
    yellow "ℹ️  当前数据目录: $current_root"

    local did_migrate=false
    local rsync_ok=0

    # 路径相同：仅确保配置与权限
    if [ "$current_root" = "$containerd_root" ]; then
        _apply_containerd_root_config "$containerd_root"
        $SUDO mkdir -p "$containerd_root"
        $SUDO chown -R root:root "$containerd_root" 2>/dev/null || true
    else
        # 路径不同：若当前目录有数据则迁移（支持 /var → /home 或 /home → 其他盘）
        local src_size=0
        if [ -d "$current_root" ]; then
            src_size=$($SUDO du -sm "$current_root" 2>/dev/null | cut -f1)
        fi
        local has_files=false
        if [ -d "$current_root" ] && [ -n "$($SUDO ls -A "$current_root" 2>/dev/null)" ]; then
            has_files=true
        fi
        local do_migrate=false
        if [ "${src_size:-0}" -gt 0 ] 2>/dev/null || [ "$has_files" = true ]; then
            do_migrate=true
        fi

        if [ "$do_migrate" = true ]; then
            yellow "📦 正在从 $current_root 迁移数据到 $containerd_root ..."
            stop_docker_stack
            sleep 1

            $SUDO mkdir -p "$containerd_root"
            yellow "🔄 正在复制数据（rsync）..."
            if $SUDO rsync -aHAX "$current_root/" "$containerd_root/"; then
                rsync_ok=1
            else
                red "❌ 数据复制失败，请检查磁盘空间与权限"
                start_docker_stack || true
                return 1
            fi

            _apply_containerd_root_config "$containerd_root"
            did_migrate=true

            if [ "$rsync_ok" = 1 ] && [ -n "$current_root" ] && [ -d "$current_root" ]; then
                case "$current_root" in
                    /|/bin|/boot|/dev|/etc|/home|/usr|/root|/var|/mnt|/opt|/data/)
                        yellow "⚠️  未自动删除系统级路径，请手动清理: $current_root"
                        ;;
                    *)
                        yellow "🗑️  正在删除旧数据目录: $current_root"
                        $SUDO rm -rf "$current_root"
                        ;;
                esac
            fi
            green "✅ containerd 数据迁移完成"
        else
            _apply_containerd_root_config "$containerd_root"
            $SUDO mkdir -p "$containerd_root"
        fi
    fi

    $SUDO chown -R root:root "$containerd_root" 2>/dev/null || true

    if command_exists restorecon 2>/dev/null; then
        $SUDO restorecon -RFv "$containerd_root" 2>/dev/null || true
    fi

    if command_exists systemctl; then
        if [ "$did_migrate" = true ]; then
            if ! $SUDO systemctl is-active docker >/dev/null 2>&1; then
                yellow "🔄 正在启动 containerd 与 Docker..."
                if start_docker_stack; then
                    green "✅ containerd 与 Docker 服务已启动"
                else
                    red "❌ Docker 启动失败或 API 不可用"
                fi
            fi
        else
            if $SUDO systemctl is-active docker >/dev/null 2>&1 || $SUDO systemctl is-active containerd >/dev/null 2>&1; then
                yellow "🔄 正在重启 Docker 以应用 containerd 数据目录配置..."
                stop_docker_stack
                start_docker_stack || true
            fi
        fi
    fi

    green "✅ containerd 数据目录已配置为: $containerd_root"
}

# 菜单：交互式输入 containerd 迁移目标目录
menu_migrate_containerd_data_path() {
    [ "${OS:-}" = "freebsd" ] && { yellow "当前系统不支持此操作"; return 0; }
    if ! command_exists containerd && [ ! -x /usr/bin/containerd ]; then
        red "❌ 未检测到 containerd，请先安装 Docker"
        return 0
    fi

    local default_path="${CONTAINERD_DATA_PATH:-/data/containerd}"
    local cur
    cur=$(get_containerd_root_from_config)
    [ -z "$cur" ] && cur="/var/lib/containerd"
    echo ""
    yellow "当前 containerd 数据目录: $cur"
    yellow "默认迁移目标: $default_path"
    echo ""
    readp "请输入新的绝对路径（直接回车使用上述默认；例如 /mnt/ssd/containerd）: " user_in
    user_in="${user_in%/}"
    user_in="${user_in#"${user_in%%[![:space:]]*}"}"
    user_in="${user_in%"${user_in##*[![:space:]]}"}"

    if [ -z "$user_in" ]; then
        if ! setup_containerd_data_path "$default_path"; then
            return 0
        fi
    else
        if [ "${user_in#/}" = "$user_in" ]; then
            red "❌ 必须是绝对路径（以 / 开头）"
            return 0
        fi
        if ! setup_containerd_data_path "$user_in"; then
            return 0
        fi
    fi
}

# 从 daemon.json 读取 data-root（Docker 未就绪时的兜底）
get_docker_data_root_from_daemon_json() {
    local p="/etc/docker/daemon.json"
    if [ ! -f "$p" ]; then
        echo ""
        return 0
    fi
    if command_exists python3; then
        python3 - <<'PY' 2>/dev/null || true
import json
try:
    with open("/etc/docker/daemon.json", "r", encoding="utf-8") as f:
        data = json.load(f)
    print((data.get("data-root") or "").rstrip("/"))
except Exception:
    pass
PY
        return 0
    fi
    # 极简兜底：不依赖 python
    sed -n 's/.*"data-root"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$p" 2>/dev/null | head -1
}

# 读取当前生效的 Docker data-root（优先 API，其次 daemon.json）
get_docker_data_root() {
    local root=""
    if command_exists docker || [ -x /usr/bin/docker ]; then
        root="$($SUDO docker info --format '{{.DockerRootDir}}' 2>/dev/null | tr -d '\r' | head -1)"
        root="${root%/}"
    fi
    if [ -z "$root" ]; then
        root="$(get_docker_data_root_from_daemon_json)"
        root="${root%/}"
    fi
    if [ -z "$root" ]; then
        root="/var/lib/docker"
    fi
    printf '%s\n' "$root"
}

# 等待 Docker API 可用（避免 socket 假死后误判）
wait_for_docker_api() {
    local retries="${1:-30}"
    local i
    for i in $(seq 1 "$retries"); do
        if $SUDO docker info >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# 完整停止 Docker（必须同时停 docker.socket，否则 /run/docker.sock 会假死：LISTEN 但 Connection refused）
stop_docker_stack() {
    if ! command_exists systemctl; then
        return 0
    fi
    $SUDO systemctl stop docker 2>/dev/null || true
    $SUDO systemctl stop docker.socket 2>/dev/null || true
    $SUDO systemctl stop containerd 2>/dev/null || true
    # 清理可能残留的失效 socket 节点
    if [ -S /run/docker.sock ] || [ -e /run/docker.sock ]; then
        # 仅在确认无进程占用时删除；有占用则留给 systemd 重建
        if ! $SUDO fuser /run/docker.sock >/dev/null 2>&1; then
            $SUDO rm -f /run/docker.sock 2>/dev/null || true
        fi
    fi
}

# 完整启动 Docker，并等待 API 就绪
start_docker_stack() {
    if ! command_exists systemctl; then
        return 1
    fi
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    $SUDO systemctl start containerd 2>/dev/null || true
    $SUDO systemctl start docker.socket 2>/dev/null || true
    if ! $SUDO systemctl start docker; then
        return 1
    fi
    if ! wait_for_docker_api 30; then
        # 常见修复：socket 单元状态异常时重启一次
        yellow "⚠️  Docker 已启动但 API 未就绪，尝试重启 docker.socket ..."
        $SUDO systemctl restart docker.socket 2>/dev/null || true
        $SUDO systemctl restart docker 2>/dev/null || true
        wait_for_docker_api 30 || return 1
    fi
    return 0
}

# 写入 containerd systemd limits（与 scripts/docker_containerd_repair_restart.sh 对齐）
_dm_apply_containerd_systemd_limits() {
    local override_dir="/etc/systemd/system/containerd.service.d"
    $SUDO mkdir -p "$override_dir"
    $SUDO tee "$override_dir/override.conf" >/dev/null <<'EOF'
[Service]
LimitNPROC=infinity
LimitNOFILE=infinity
LimitCORE=infinity
EOF
}

# 安全清空数据目录内容（拒绝根路径与非绝对路径）
_dm_wipe_dir_contents() {
    local d="${1%/}"
    if [[ -z "$d" || "$d" == "/" || "$d" != /* ]]; then
        red "❌ 拒绝清空非法路径: ${1:-<empty>}"
        return 1
    fi
    if [[ ! -d "$d" ]]; then
        yellow "ℹ️  目录不存在，跳过: $d"
        return 0
    fi
    yellow "🗑️  清空目录内容: $d"
    $SUDO rm -rf "$d"/* "$d"/.[!.]* "$d"/..?* 2>/dev/null || true
}

# 修复 / 重置 Docker 与 containerd 运行时
# 对应 scripts/docker_containerd_repair_restart.sh；彻底重置清空当前生效 data-root（非写死 /var/lib）
# 参数: safe（默认）| reset；无参则交互选择
repair_docker_containerd_runtime() {
    local mode="${1:-}"
    local docker_root containerd_root confirm confirm2

    if ! command_exists systemctl; then
        red "❌ systemctl 不可用，无法执行修复"
        return 1
    fi

    docker_root="$(get_docker_data_root 2>/dev/null || echo /var/lib/docker)"
    containerd_root="$(get_containerd_root_from_config 2>/dev/null || true)"
    containerd_root="${containerd_root:-/var/lib/containerd}"
    docker_root="${docker_root%/}"
    containerd_root="${containerd_root%/}"

    if [[ -z "$mode" ]]; then
        echo ""
        blue "🔧 Docker / containerd 运行时修复"
        echo "==========================================="
        echo "当前 Docker data-root : $docker_root"
        echo "当前 containerd root  : $containerd_root"
        echo ""
        echo "  1. 安全修复（清理 runtime 残留，保留镜像/容器/卷）"
        echo "  2. 彻底重置（额外清空上述数据目录，不可恢复）"
        echo "  0. 取消"
        echo "==========================================="
        readp "请选择 [0-2]: " mode
        case "$mode" in
            1) mode="safe" ;;
            2) mode="reset" ;;
            0|"") yellow "已取消"; return 0 ;;
            safe|reset) ;;
            *) red "无效选择"; return 1 ;;
        esac
    fi

    case "$mode" in
        safe|reset) ;;
        *) red "❌ 未知模式: $mode（仅支持 safe|reset）"; return 1 ;;
    esac

    echo ""
    echo "============================================================"
    yellow "  ⚠️  Docker / containerd 修复"
    echo "============================================================"
    echo "  将执行："
    echo "    1. 停止 docker / docker.socket / containerd"
    echo "    2. 清理 /run 下 runtime 残留与 containerd 任务元数据"
    echo "    3. 修复 systemd limits 并 daemon-reload"
    echo "    4. 加载 overlay / br_netfilter"
    echo "    5. 重启 containerd 与 docker"
    if [[ "$mode" == "safe" ]]; then
        echo "    6. 安全清理无效容器（不删镜像/卷）"
    else
        echo ""
        red "  🔴 彻底重置模式："
        red "    将清空: $docker_root"
        red "    将清空: $containerd_root"
        red "    镜像、容器、卷、构建缓存等将被永久删除且无法恢复！"
    fi
    echo "============================================================"
    echo ""

    if [[ "$mode" == "reset" ]]; then
        readp "请输入 yes 确认彻底重置: " confirm
        if [[ "$confirm" != "yes" ]]; then
            yellow "已取消操作。"
            return 0
        fi
        readp "再次确认：请输入要清空的 Docker data-root 完整路径: " confirm2
        if [[ "${confirm2%/}" != "$docker_root" ]]; then
            red "路径不匹配（期望: $docker_root），已取消。"
            return 0
        fi
    else
        readp "确认继续安全修复？(yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            yellow "已取消操作。"
            return 0
        fi
    fi

    echo ""
    yellow ">>> [1/10] 停止 docker & containerd..."
    stop_docker_stack
    $SUDO pkill -9 dockerd 2>/dev/null || true
    $SUDO pkill -9 containerd 2>/dev/null || true

    yellow ">>> [2/10] 清理 runtime 残留目录..."
    $SUDO rm -rf /run/docker/* /run/containerd/* 2>/dev/null || true
    $SUDO rm -rf "${containerd_root}/io.containerd.runtime.v2.task/moby/"* 2>/dev/null || true
    $SUDO rm -f "${containerd_root}/io.containerd.metadata.v1.bolt/meta.db" 2>/dev/null || true

    if [[ "$mode" == "reset" ]]; then
        yellow ">>> [3/10] 清空 Docker & containerd 数据目录..."
        _dm_wipe_dir_contents "$docker_root" || return 1
        _dm_wipe_dir_contents "$containerd_root" || return 1
    else
        yellow ">>> [3/10] 跳过数据目录清空（安全模式）"
    fi

    yellow ">>> [4/10] 修复 systemd 限制项..."
    _dm_apply_containerd_systemd_limits
    # 顺带确保 docker.service limits 覆盖存在（不依赖是否检测到 205）
    $SUDO mkdir -p /etc/systemd/system/docker.service.d
    if [[ ! -f /etc/systemd/system/docker.service.d/limits.conf ]]; then
        $SUDO tee /etc/systemd/system/docker.service.d/limits.conf >/dev/null <<'EOF'
[Service]
TasksMax=infinity
LimitNOFILE=infinity
LimitNPROC=infinity
LimitMEMLOCK=infinity
LimitCORE=infinity
TimeoutStartSec=0
KillMode=process
Restart=on-failure
RestartSec=2
EOF
    fi

    yellow ">>> [5/10] 重新加载 systemd..."
    $SUDO systemctl daemon-reexec 2>/dev/null || true
    $SUDO systemctl daemon-reload 2>/dev/null || true
    $SUDO systemctl reset-failed docker docker.socket containerd 2>/dev/null || true

    yellow ">>> [6/10] 加载内核模块..."
    $SUDO modprobe overlay 2>/dev/null || true
    $SUDO modprobe br_netfilter 2>/dev/null || true

    yellow ">>> [7/10] 启动 containerd..."
    $SUDO systemctl unmask containerd docker 2>/dev/null || true
    $SUDO systemctl start containerd 2>/dev/null || true

    yellow ">>> [8/10] 启动 docker..."
    if ! start_docker_stack; then
        red "❌ Docker 启动失败，请执行: sudo journalctl -xeu docker.service"
        return 1
    fi

    if [[ "$mode" == "safe" ]]; then
        yellow ">>> [9/10] 清理无效容器（安全模式，不删除镜像/卷）..."
        $SUDO docker container prune -f 2>/dev/null || true
    else
        yellow ">>> [9/10] 彻底重置模式：跳过 container prune"
    fi

    yellow ">>> [10/10] 验证 Docker 状态..."
    if $SUDO systemctl is-active --quiet docker; then
        green "🎉 Docker 服务已恢复正常"
        $SUDO docker ps -a 2>/dev/null || true
        echo ""
        green "当前 Docker data-root: $(get_docker_data_root)"
        return 0
    fi

    red "❌ Docker 启动失败，请执行: sudo journalctl -xeu docker.service"
    return 1
}

# 清理已废弃的旧 Docker data-root（迁移后残留）
# 参数: $1=当前生效 data-root, $2=待清理旧路径
cleanup_stale_docker_data_dir() {
    local active_root="${1%/}"
    local old_dir="${2%/}"
    local size_h=""

    [ -z "$old_dir" ] && return 0
    [ "$old_dir" = "$active_root" ] && return 0
    [ ! -e "$old_dir" ] && return 0

    case "$old_dir" in
        /|/bin|/boot|/dev|/etc|/home|/usr|/root|/var|/mnt|/opt|/data|/data/)
            yellow "⚠️  拒绝清理系统级路径: $old_dir"
            return 1
            ;;
    esac

    # 仍挂载则先尝试懒卸载
    if mount | grep -q " ${old_dir}/\| ${old_dir} "; then
        yellow "⚠️  检测到旧目录仍有挂载，尝试卸载: $old_dir"
        mount | awk -v p="$old_dir" '$3 == p || index($3, p "/") == 1 {print length($3), $3}' \
            | sort -rn | awk '{print $2}' | while read -r m; do
            $SUDO umount -l "$m" 2>/dev/null || $SUDO umount "$m" 2>/dev/null || true
        done
    fi
    if mount | grep -q " ${old_dir}/\| ${old_dir} "; then
        red "❌ 旧目录仍有挂载，跳过删除: $old_dir"
        mount | grep " ${old_dir}"
        return 1
    fi

    # dockerd 不得再引用该路径
    local pid
    pid="$(pgrep -x dockerd | head -1 || true)"
    if [ -n "$pid" ]; then
        local fd t
        for fd in /proc/$pid/fd/*; do
            t="$(readlink -f "$fd" 2>/dev/null || true)"
            case "$t" in
                "$old_dir"|"$old_dir"/*)
                    red "❌ dockerd 仍在使用 $t，跳过删除"
                    return 1
                    ;;
            esac
        done
    fi

    size_h="$($SUDO du -sh "$old_dir" 2>/dev/null | awk '{print $1}')"
    yellow "🗑️  删除废弃 Docker 数据目录: $old_dir（约 ${size_h:-?}）"
    if $SUDO rm -rf "$old_dir"; then
        green "✅ 已释放旧目录: $old_dir"
        return 0
    fi
    red "❌ 删除失败: $old_dir"
    return 1
}

# 菜单：交互式输入 Docker data-root 迁移目标目录
menu_migrate_docker_data_root_path() {
    echo ""
    if ! command_exists docker && [ ! -x /usr/bin/docker ]; then
        red "❌ 未检测到 docker，请先安装 Docker"
        return 0
    fi

    local default_base="${DOCKER_DATA_PATH:-/data/docker}"
    local default_path="${default_base%/}"
    local cur
    cur="$(get_docker_data_root)"
    local cfg_root
    cfg_root="$(get_docker_data_root_from_daemon_json)"
    local stale_default="/var/lib/docker"

    yellow "当前 Docker data-root: $cur"
    if [ -n "$cfg_root" ] && [ "$cfg_root" != "$cur" ]; then
        yellow "daemon.json 中的 data-root: $cfg_root（与运行值不一致）"
    fi
    if [ -e "$stale_default" ] && [ "$cur" != "$stale_default" ]; then
        local stale_sz
        stale_sz="$($SUDO du -sh "$stale_default" 2>/dev/null | awk '{print $1}')"
        yellow "发现残留旧目录: $stale_default（约 ${stale_sz:-?}），迁移完成后可清理释放空间"
    fi
    yellow "默认迁移目标: $default_path"
    echo ""
    readp "请输入新的绝对路径（直接回车使用上述默认；例如 /data/docker）: " user_in
    user_in="${user_in%/}"
    user_in="${user_in#"${user_in%%[![:space:]]*}"}"
    user_in="${user_in%"${user_in##*[![:space:]]}"}"

    if [ -z "$user_in" ]; then
        user_in="$default_path"
    fi
    if [ "${user_in#/}" = "$user_in" ]; then
        red "❌ 必须是绝对路径（以 / 开头）"
        return 0
    fi
    if [[ "$user_in" == "$cur"/* ]] && [ "$user_in" != "$cur" ]; then
        red "❌ 目标路径不能位于当前数据目录内部：$cur"
        return 0
    fi

    # 已在目标路径：检查 API，并提示清理残留旧目录
    if [ "$user_in" = "$cur" ] && [ "${cfg_root:-}" = "$user_in" ]; then
        yellow "ℹ️  data-root 已是目标路径，检查 Docker API ..."
        if start_docker_stack; then
            green "✅ 无需迁移，当前 data-root: $(get_docker_data_root)"
            if [ -e "$stale_default" ] && [ "$user_in" != "$stale_default" ]; then
                local ans=""
                readp "检测到残留 $stale_default，是否删除以释放空间？[y/N]: " ans
                if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
                    # 重启一次，避免旧 overlay 仍挂在 /var/lib/docker
                    stop_docker_stack
                    if mount | grep -q " /var/lib/docker"; then
                        mount | awk '$3 == "/var/lib/docker" || index($3, "/var/lib/docker/") == 1 {print length($3), $3}' \
                            | sort -rn | awk '{print $2}' | while read -r m; do
                            $SUDO umount -l "$m" 2>/dev/null || $SUDO umount "$m" 2>/dev/null || true
                        done
                    fi
                    start_docker_stack || true
                    cleanup_stale_docker_data_dir "$(get_docker_data_root)" "$stale_default" || true
                else
                    yellow "已跳过清理 $stale_default"
                fi
            fi
        else
            red "❌ Docker API 不可用，请检查 docker / docker.socket 状态"
        fi
        return 0
    fi

    yellow "🔧 开始迁移 Docker data-root 到: $user_in"

    # 停止 Docker 服务，避免迁移过程中文件变化（必须停 docker.socket）
    stop_docker_stack

    $SUDO mkdir -p "$user_in"

    # 有数据时进行迁移；无数据时仅改配置
    if [ -d "$cur" ] && [ -n "$($SUDO ls -A "$cur" 2>/dev/null)" ]; then
        yellow "📦 正在从 $cur 复制数据到 $user_in ..."
        if command_exists rsync; then
            if ! $SUDO rsync -aHAX "$cur/" "$user_in/"; then
                red "❌ 数据迁移失败（rsync）"
                start_docker_stack || true
                return 1
            fi
        else
            if ! $SUDO cp -a "$cur/." "$user_in/"; then
                red "❌ 数据迁移失败（cp）"
                start_docker_stack || true
                return 1
            fi
        fi
    fi

    $SUDO mkdir -p /etc/docker
    [ ! -f /etc/docker/daemon.json ] && echo "{}" | $SUDO tee /etc/docker/daemon.json >/dev/null

    # 尽量保留原配置，仅更新 data-root
    if command_exists python3; then
        if ! $SUDO python3 - "$user_in" <<'PY'
import json,sys
p="/etc/docker/daemon.json"
new_root=sys.argv[1]
try:
    with open(p,"r",encoding="utf-8") as f:
        data=json.load(f)
    if not isinstance(data,dict):
        data={}
except Exception:
    data={}
data["data-root"]=new_root
with open(p,"w",encoding="utf-8") as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
    f.write("\n")
PY
        then
            red "❌ 更新 /etc/docker/daemon.json 失败"
            start_docker_stack || true
            return 1
        fi
    else
        # 兜底：覆盖最小配置
        echo "{\"data-root\":\"$user_in\"}" | $SUDO tee /etc/docker/daemon.json >/dev/null
    fi

    if ! start_docker_stack; then
        red "❌ Docker 启动失败或 API 不可用，请检查 /etc/docker/daemon.json 与 docker.socket"
        return 1
    fi

    local new_root
    new_root="$(get_docker_data_root)"
    if [ "$new_root" = "$user_in" ]; then
        green "✅ Docker data-root 迁移完成: $new_root"
        # 清理本次迁移源目录
        if [ -d "$cur" ] && [ "$cur" != "$user_in" ]; then
            cleanup_stale_docker_data_dir "$new_root" "$cur" || \
                yellow "⚠️  请手动确认后清理旧目录: $cur"
        fi
        # 若源不是默认路径，再检查 /var/lib/docker 残留
        if [ -e "$stale_default" ] && [ "$stale_default" != "$user_in" ] && [ "$stale_default" != "$cur" ]; then
            local ans2=""
            readp "另外检测到残留 $stale_default，是否一并删除？[y/N]: " ans2
            if [[ "${ans2,,}" == "y" || "${ans2,,}" == "yes" ]]; then
                cleanup_stale_docker_data_dir "$new_root" "$stale_default" || true
            fi
        fi
    else
        yellow "⚠️  Docker API 已恢复，但 data-root 未匹配目标值"
        yellow "当前值: ${new_root:-未知}，目标值: $user_in"
        yellow "daemon.json: $(get_docker_data_root_from_daemon_json)"
    fi
}

# 配置Docker数据目录
configure_docker_data_path() {
    yellow "\n🔧 配置Docker数据目录..."

    # 默认数据路径
    local docker_data_path="${DOCKER_DATA_PATH:-/data/docker}"

    if [ -e "/usr/bin/docker" ]; then
        [ -f "/var/run/docker.sock" ] && $SUDO chmod a+rw /var/run/docker.sock

        if [ ! -d "${docker_data_path}/docker" ]; then
            $SUDO mkdir -p ${docker_data_path}/docker
            [ -d "/var/lib/docker" ] && $SUDO rsync -avz /var/lib/docker ${docker_data_path}/ && $SUDO rm -fr /var/lib/docker
        fi

        [ ! -d "/etc/docker/" ] && $SUDO mkdir -p /etc/docker
        [ ! -f "/etc/docker/daemon.json" ] && $SUDO touch /etc/docker/daemon.json

        # 配置daemon.json
        # 镜像源说明（2026-08 实测）：
        # - docker.1ms.run 可用且速度快，作为首选
        # - docker.m.daocloud.io 已将 blob 重定向到 Docker Hub 官方 CDN，仅作兜底
        # - dockerproxy.com / mirror.baidubce.com / docker.nju.edu.cn 均已停服，移除
        echo "{
    \"registry-mirrors\": [
        \"https://docker.1ms.run\",
        \"https://docker.m.daocloud.io\"
    ],
    \"dns\": [
        \"8.8.4.4\",
        \"114.114.114.114\"
     ],
    \"iptables\": false,
    \"insecure-registries\":[],
    \"log-driver\":\"json-file\",
    \"log-opts\": {\"max-size\":\"500m\", \"max-file\":\"3\"},
    \"data-root\": \"${docker_data_path}/docker/lib\"
}" | $SUDO tee /etc/docker/daemon.json > /dev/null

        $SUDO systemctl daemon-reload

        # 将用户添加到docker组
        if [ -n "$NORMAL_USER" ] && [ "$NORMAL_USER" != "root" ]; then
            $SUDO usermod -aG docker $NORMAL_USER 2>/dev/null || true
            green "已将用户 $NORMAL_USER 添加到docker组，请注销并重新登录以应用更改"
        fi
    fi
}

# 验证Docker安装
verify_docker_installation() {
    yellow "\n🔍 验证Docker安装..."

    # 检查docker命令是否可用
    if ! command_exists docker; then
        red "❌ docker命令不可用"
        return 1
    fi

    # 检查Docker版本
    if docker --version >/dev/null 2>&1; then
        local docker_version=$(docker --version)
        green "✅ Docker版本: $docker_version"
    else
        red "❌ 无法获取Docker版本"
        return 1
    fi

    # 检查Docker服务状态
    if command -v systemctl >/dev/null 2>&1; then
        if $SUDO systemctl is-active docker >/dev/null 2>&1; then
            green "✅ Docker服务运行正常"
        else
            red "❌ Docker服务未运行"
            $SUDO systemctl status docker --no-pager || true
            return 1
        fi
    fi

    # 检查docker-compose
    yellow "🔍 检查docker-compose..."
    if command_exists docker-compose; then
        local compose_version=$(docker-compose --version 2>/dev/null || echo "未知版本")
        green "✅ docker-compose版本: $compose_version"
    else
        yellow "⚠️  docker-compose未安装或不在PATH中"
        install_docker_compose
    fi

    # 检查用户权限
    if [ -n "$NORMAL_USER" ] && [ "$NORMAL_USER" != "root" ]; then
        yellow "🔍 检查用户 $NORMAL_USER 的Docker权限..."

        # 检查用户是否在docker组中
        if groups $NORMAL_USER | grep -q "\bdocker\b"; then
            green "✅ 用户 $NORMAL_USER 已在docker组中"

            # 尝试不使用sudo测试（检查当前会话的组权限）
            if [ "$(id -u)" -ne 0 ]; then
                if groups | grep -q "\bdocker\b"; then
                    yellow "🧪 测试Docker功能（无需sudo）..."
                    if docker run --rm hello-world >/dev/null 2>&1; then
                        green "✅ Docker功能测试通过（无需sudo）"
                    else
                        yellow "⚠️  当前会话的组权限未生效"
                        yellow "💡 请运行以下命令之一来应用组权限："
                        echo "   1. newgrp docker  （立即生效，但会创建新shell）"
                        echo "   2. 注销并重新登录  （推荐）"
                        echo "   3. 使用 sudo docker 命令（临时方案）"
                    fi
                else
                    yellow "⚠️  当前会话的组权限未生效"
                    yellow "💡 请运行以下命令之一来应用组权限："
                    echo "   1. newgrp docker  （立即生效，但会创建新shell）"
                    echo "   2. 注销并重新登录  （推荐）"
                    echo "   3. 使用 sudo docker 命令（临时方案）"
                fi
            fi
        else
            yellow "⚠️  用户 $NORMAL_USER 未在docker组中"
            yellow "💡 正在尝试添加用户到docker组..."
            if $SUDO usermod -aG docker $NORMAL_USER 2>/dev/null; then
                green "✅ 已将用户添加到docker组"
                yellow "💡 请注销并重新登录，或运行: newgrp docker"
            else
                yellow "⚠️  无法添加用户到docker组，请手动执行："
                echo "   sudo usermod -aG docker $NORMAL_USER"
            fi
        fi
    fi

    return 0
}

# 安装Docker主函数
install_docker() {
    green "开始安装Docker..."

    # 安装前写入 apt/dnf 代理（若启动时已探测可用）
    if [ "$DM_PROXY_ENABLED" = true ]; then
        dm_configure_package_manager_proxy
    fi

    # 检查是否已安装Docker
    if command_exists docker && (command_exists docker-compose || [ -e "/usr/bin/docker-compose" ]); then
        green "Docker已安装，当前版本："
        docker --version
        if command_exists docker-compose; then
            docker-compose --version
        fi
        readp "是否重新安装？(y/N): " reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    case "$OS" in
        arch)
            install_docker_arch
            ;;
        debian|ubuntu)
            # WSL 下的 Debian/Ubuntu 使用官方安装脚本（get.docker.com 支持）
            if [ "$IS_WSL" = true ]; then
                auto_install_docker
            else
                install_docker_debian
            fi
            ;;
        deepin)
            auto_install_docker
            ;;
        rhel)
            # RHEL 系（CentOS/AlmaLinux/Rocky/Fedora）在 WSL 和原生环境均使用 yum/dnf 原生安装
            install_docker_rhel
            ;;
        opensuse)
            install_docker_opensuse
            ;;
        freebsd)
            install_docker_freebsd
            ;;
        *)
            red "不支持在当前系统上安装Docker"
            return 1
            ;;
    esac

    # 确保docker组存在
    if ! getent group docker >/dev/null 2>&1; then
        yellow "👥 创建docker组..."
        $SUDO groupadd docker 2>/dev/null || true
    fi

    # 将当前用户添加到docker组
    if [ -n "$NORMAL_USER" ] && [ "$NORMAL_USER" != "root" ]; then
        yellow "👤 将用户 $NORMAL_USER 添加到docker组..."
        if $SUDO usermod -aG docker $NORMAL_USER 2>/dev/null; then
            green "✅ 已将用户 $NORMAL_USER 添加到docker组"

            # 检查用户当前是否已经在docker组中（需要重新登录才能生效）
            if groups $NORMAL_USER | grep -q "\bdocker\b"; then
                yellow "ℹ️  组权限已应用，但当前会话可能需要重新加载"
            else
                yellow "ℹ️  组权限将在重新登录后生效"
            fi

            # 尝试立即应用组权限（使用 newgrp，但只在交互式shell中）
            if [ -t 0 ] && [ -t 1 ]; then
                yellow "💡 提示：要立即使用Docker（无需重新登录），可以运行："
                echo "   newgrp docker"
                echo "   或者注销并重新登录"
            fi
        else
            yellow "⚠️  添加用户到docker组失败，但这不影响使用"
        fi
    fi

    # 预防性修复systemd limits问题
    fix_docker_systemd_limits

    # 自动将 containerd 数据目录配置为 /data/containerd（若已有数据则从当前目录迁移，需在首次启动 Docker 前完成）
    setup_containerd_data_path

    # 安装docker-compose
    install_docker_compose

    # 启动Docker服务
    start_docker_service

    # 配置Docker数据目录
    configure_docker_data_path

    # 验证安装
    verify_docker_installation

    # 将可用代理写入 systemd / CLI / 包管理器，供后续 docker pull 与组件安装使用
    dm_configure_docker_proxy_stack

    green "🎉 Docker安装完成！"
    dm_show_proxy_status
}

# ==================== Docker卸载相关函数 ====================

# 停止Docker服务
stop_docker_services() {
    yellow "🛑 停止Docker相关服务..."

    # 停止所有运行的容器
    if command_exists docker; then
        yellow "📦 停止所有运行的容器..."
        $SUDO docker stop $(docker ps -aq) 2>/dev/null || true
        $SUDO docker rm $(docker ps -aq) 2>/dev/null || true
        green "✅ 已停止所有容器"
    fi

    # 停止systemd服务
    if command_exists systemctl; then
        local services=("docker" "docker.socket" "containerd")
        for service in "${services[@]}"; do
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                yellow "🔄 停止服务: $service"
                $SUDO systemctl stop "$service" 2>/dev/null || true
                $SUDO systemctl disable "$service" 2>/dev/null || true
            fi
        done
        green "✅ 已停止Docker服务"
    fi

    # 杀死相关进程
    yellow "🔪 终止Docker相关进程..."
    $SUDO pkill -f "^dockerd" 2>/dev/null || true
    $SUDO pkill -f "docker-proxy" 2>/dev/null || true
    $SUDO pkill -f "containerd-shim" 2>/dev/null || true
    $SUDO pkill -f "/usr/bin/dockerd" 2>/dev/null || true
    $SUDO pkill -f "/usr/bin/containerd" 2>/dev/null || true
    sleep 3
}

# 卸载Docker包 - Arch Linux
uninstall_docker_arch() {
    yellow "🗑️  卸载Arch Linux Docker包..."

    local packages=(
        "docker"
        "docker-compose"
        "docker-buildx"
        "containerd"
        "runc"
    )

    for package in "${packages[@]}"; do
        if pacman -Qi "$package" >/dev/null 2>&1; then
            yellow "📦 卸载包: $package"
            $SUDO pacman -Rns --noconfirm "$package" 2>/dev/null || true
        fi
    done

    green "✅ Arch Linux Docker包卸载完成"
}

# 卸载Docker包 - Debian/Ubuntu
uninstall_docker_debian() {
    yellow "🗑️  卸载Debian/Ubuntu Docker包..."

    # 更新包列表
    $SUDO apt-get update 2>/dev/null || true

    local packages=(
        "docker-ce"
        "docker-ce-cli"
        "docker-ce-rootless-extras"
        "docker-buildx-plugin"
        "docker-compose-plugin"
        "containerd.io"
        "docker.io"
        "docker-engine"
        "docker"
        "docker-compose"
        "runc"
    )

    # 卸载包
    for package in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii.*$package"; then
            yellow "📦 卸载包: $package"
            $SUDO apt-get remove --purge -y "$package" 2>/dev/null || true
        fi
    done

    # 自动清理
    $SUDO apt-get autoremove -y 2>/dev/null || true
    $SUDO apt-get autoclean 2>/dev/null || true

    green "✅ Debian/Ubuntu Docker包卸载完成"
}

# 卸载Docker包 - RHEL/CentOS/Fedora
uninstall_docker_rhel() {
    yellow "🗑️  卸载RHEL/CentOS/Fedora Docker包..."

    local packages=(
        "docker-ce"
        "docker-ce-cli"
        "docker-ce-rootless-extras"
        "docker-buildx-plugin"
        "docker-compose-plugin"
        "containerd.io"
        "docker"
        "docker-client"
        "docker-client-latest"
        "docker-common"
        "docker-latest"
        "docker-latest-logrotate"
        "docker-logrotate"
        "docker-engine"
        "docker-compose"
        "runc"
    )

    # 检测包管理器
    if command_exists dnf; then
        PKG_MGR="dnf"
    elif command_exists yum; then
        PKG_MGR="yum"
    else
        red "❌ 未找到包管理器 (dnf/yum)"
        return 1
    fi

    # 卸载包
    for package in "${packages[@]}"; do
        if $PKG_MGR list installed "$package" >/dev/null 2>&1; then
            yellow "📦 卸载包: $package"
            $SUDO $PKG_MGR remove -y "$package" 2>/dev/null || true
        fi
    done

    green "✅ RHEL/CentOS/Fedora Docker包卸载完成"
}

# 卸载Docker包 - openSUSE
uninstall_docker_opensuse() {
    yellow "🗑️  卸载openSUSE Docker包..."

    local packages=(
        "docker"
        "docker-ce"
        "docker-ce-cli"
        "docker-compose"
        "docker-buildx"
        "containerd"
        "containerd.io"
        "runc"
    )

    # 卸载包
    for package in "${packages[@]}"; do
        if zypper se -i "$package" >/dev/null 2>&1; then
            yellow "📦 卸载包: $package"
            $SUDO zypper --non-interactive remove -y "$package" 2>/dev/null || true
        fi
    done

    green "✅ openSUSE Docker包卸载完成"
}

# 清理Docker仓库配置
clean_docker_repos() {
    yellow "🧹 清理Docker仓库配置..."

    # 清理APT仓库 (Debian/Ubuntu)
    if [ "$OS" = "debian" ] || [ "$OS" = "ubuntu" ]; then
        $SUDO rm -f /etc/apt/sources.list.d/docker*.list 2>/dev/null || true
        $SUDO rm -f /etc/apt/keyrings/docker*.gpg 2>/dev/null || true
        $SUDO rm -f /etc/apt/keyrings/docker*.asc 2>/dev/null || true
        $SUDO rm -f /usr/share/keyrings/docker*.gpg 2>/dev/null || true
    fi

    # 清理YUM仓库 (RHEL/CentOS/Fedora)
    if [ "$OS" = "rhel" ]; then
        $SUDO rm -f /etc/yum.repos.d/docker*.repo 2>/dev/null || true
    fi

    # 清理zypper仓库 (openSUSE)
    if [ "$OS" = "opensuse" ]; then
        $SUDO rm -f /etc/zypp/repos.d/docker*.repo 2>/dev/null || true
        $SUDO zypper removerepo docker 2>/dev/null || true
    fi

    green "✅ Docker仓库配置清理完成"
}

# 清理Docker数据和配置
clean_docker_data() {
    yellow "🗂️  清理Docker数据和配置..."

    # 停止服务确保文件未被占用
    stop_docker_services

    # 清理Docker数据目录（包含 containerd 默认路径 /data/containerd）
    local docker_dirs=(
        "/var/lib/docker"
        "/var/lib/containerd"
        "/data/containerd"
        "/var/run/docker"
        "/var/run/containerd"
        "/etc/docker"
        "/etc/containerd"
        "/data/docker"
        "/opt/docker"
    )

    for dir in "${docker_dirs[@]}"; do
        if [ -d "$dir" ]; then
            yellow "🗑️  删除目录: $dir"
            $SUDO rm -rf "$dir" 2>/dev/null || true
        fi
    done

    # 清理用户配置
    local user_dirs=(
        "$HOME/.docker"
        "/root/.docker"
    )

    for dir in "${user_dirs[@]}"; do
        if [ -d "$dir" ]; then
            yellow "🗑️  删除用户配置: $dir"
            $SUDO rm -rf "$dir" 2>/dev/null || true
        fi
    done

    # 清理systemd服务文件
    local service_files=(
        "/etc/systemd/system/docker.service"
        "/etc/systemd/system/docker.socket"
        "/etc/systemd/system/containerd.service"
        "/etc/systemd/system/docker.service.d"
        "/lib/systemd/system/docker.service"
        "/lib/systemd/system/docker.socket"
        "/lib/systemd/system/containerd.service"
        "/usr/lib/systemd/system/docker.service"
        "/usr/lib/systemd/system/docker.socket"
        "/usr/lib/systemd/system/containerd.service"
    )

    for file in "${service_files[@]}"; do
        if [ -e "$file" ]; then
            yellow "🗑️  删除服务文件: $file"
            $SUDO rm -rf "$file" 2>/dev/null || true
        fi
    done

    # 重新加载systemd
    if command_exists systemctl; then
        $SUDO systemctl daemon-reload 2>/dev/null || true
    fi

    green "✅ Docker数据和配置清理完成"
}

# 清理Docker二进制文件
clean_docker_binaries() {
    yellow "🔧 清理Docker二进制文件..."

    local binaries=(
        "/usr/bin/docker"
        "/usr/bin/docker-compose"
        "/usr/bin/dockerd"
        "/usr/bin/containerd"
        "/usr/bin/containerd-shim"
        "/usr/bin/containerd-shim-runc-v1"
        "/usr/bin/containerd-shim-runc-v2"
        "/usr/bin/runc"
        "/usr/bin/docker-init"
        "/usr/bin/docker-proxy"
        "/usr/local/bin/docker"
        "/usr/local/bin/docker-compose"
        "/usr/local/bin/dockerd"
        "/usr/local/bin/containerd"
        "/usr/local/bin/runc"
        "/opt/docker/bin/docker"
        "/opt/docker/bin/dockerd"
    )

    for binary in "${binaries[@]}"; do
        if [ -f "$binary" ]; then
            yellow "🗑️  删除二进制文件: $binary"
            $SUDO rm -f "$binary" 2>/dev/null || true
        fi
    done

    green "✅ Docker二进制文件清理完成"
}

# 清理Docker用户组
clean_docker_group() {
    yellow "👥 清理Docker用户组..."

    if getent group docker >/dev/null 2>&1; then
        yellow "🗑️  删除docker用户组"
        $SUDO groupdel docker 2>/dev/null || true
        green "✅ docker用户组已删除"
    else
        green "✅ docker用户组不存在"
    fi
}

# 清理网络配置
clean_docker_network() {
    yellow "🌐 清理Docker网络配置..."

    # 清理iptables规则
    if command_exists iptables; then
        yellow "🔥 清理iptables规则..."
        $SUDO iptables -t nat -F DOCKER 2>/dev/null || true
        $SUDO iptables -t nat -X DOCKER 2>/dev/null || true
        $SUDO iptables -t filter -F DOCKER 2>/dev/null || true
        $SUDO iptables -t filter -X DOCKER 2>/dev/null || true
        $SUDO iptables -t filter -F DOCKER-ISOLATION-STAGE-1 2>/dev/null || true
        $SUDO iptables -t filter -X DOCKER-ISOLATION-STAGE-1 2>/dev/null || true
        $SUDO iptables -t filter -F DOCKER-ISOLATION-STAGE-2 2>/dev/null || true
        $SUDO iptables -t filter -X DOCKER-ISOLATION-STAGE-2 2>/dev/null || true
        $SUDO iptables -t filter -F DOCKER-USER 2>/dev/null || true
        $SUDO iptables -t filter -X DOCKER-USER 2>/dev/null || true
    fi

    # 清理网络接口
    if command_exists ip; then
        yellow "🔌 清理Docker网络接口..."
        for interface in $(ip link show | grep docker | awk -F: '{print $2}' | tr -d ' '); do
            yellow "🗑️  删除网络接口: $interface"
            $SUDO ip link delete "$interface" 2>/dev/null || true
        done
    fi

    green "✅ Docker网络配置清理完成"
}

# 清理残留文件
clean_residual_files() {
    yellow "🧽 清理残留文件..."

    # 清理日志文件
    local log_files=(
        "/var/log/docker.log"
        "/var/log/docker/*"
        "/var/log/containers/*"
    )

    for log_pattern in "${log_files[@]}"; do
        $SUDO rm -rf $log_pattern 2>/dev/null || true
    done

    # 清理临时文件
    $SUDO rm -rf /tmp/docker* 2>/dev/null || true
    $SUDO rm -rf /tmp/*docker* 2>/dev/null || true

    # 清理缓存
    $SUDO rm -rf /var/cache/docker* 2>/dev/null || true

    green "✅ 残留文件清理完成"
}

# WSL特殊处理
handle_wsl_cleanup() {
    if [ "$IS_WSL" = true ]; then
        yellow "🐧 检测到WSL环境，执行特殊清理..."

        # WSL中可能需要额外清理
        $SUDO rm -rf /mnt/wsl/docker-desktop* 2>/dev/null || true
        $SUDO rm -rf /mnt/c/Users/*/AppData/Local/Docker* 2>/dev/null || true

        green "✅ WSL特殊清理完成"
    fi
}

# 验证卸载结果
verify_uninstall() {
    yellow "🔍 验证卸载结果..."

    local issues_found=false

    # 检查命令是否还存在
    local commands=("docker" "docker-compose" "dockerd" "containerd")
    for cmd in "${commands[@]}"; do
        if command_exists "$cmd"; then
            red "⚠️  命令仍然存在: $cmd ($(which $cmd))"
            issues_found=true
        fi
    done

    # 检查服务是否还在运行
    if command_exists systemctl; then
        local services=("docker" "docker.socket" "containerd")
        for service in "${services[@]}"; do
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                red "⚠️  服务仍在运行: $service"
                issues_found=true
            fi
        done
    fi

    # 检查关键目录是否还存在
    local dirs=("/var/lib/docker" "/etc/docker")
    for dir in "${dirs[@]}"; do
        if [ -d "$dir" ]; then
            red "⚠️  目录仍然存在: $dir"
            issues_found=true
        fi
    done

    if [ "$issues_found" = false ]; then
        green "✅ Docker已完全卸载"
        return 0
    else
        yellow "⚠️  发现一些残留，但主要组件已卸载"
        return 1
    fi
}

# 卸载Docker主函数
uninstall_docker() {
    blue "🐳 Docker彻底卸载脚本"
    blue "支持系统: Arch Linux, Debian, Ubuntu, CentOS, RHEL, Fedora, openSUSE, WSL"
    echo

    # 确认卸载
    read -p "⚠️  确定要彻底卸载Docker吗？这将删除所有容器、镜像和数据！(y/N): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        yellow "❌ 用户取消卸载"
        return 0
    fi
    echo

    # 执行卸载步骤
    yellow "🚀 开始卸载Docker..."
    echo

    # 1. 停止服务
    stop_docker_services
    echo

    # 2. 卸载包
    case "$OS" in
        arch)
            uninstall_docker_arch
            ;;
        debian|ubuntu)
            uninstall_docker_debian
            ;;
        rhel)
            uninstall_docker_rhel
            ;;
        deepin)
            uninstall_docker_debian
            ;;
        opensuse)
            uninstall_docker_opensuse
            ;;
        *)
            yellow "⚠️  未知系统类型，跳过包卸载"
            ;;
    esac
    echo

    # 3. 清理仓库配置
    clean_docker_repos
    echo

    # 4. 清理数据和配置
    clean_docker_data
    echo

    # 5. 清理二进制文件
    clean_docker_binaries
    echo

    # 6. 清理用户组
    clean_docker_group
    echo

    # 7. 清理网络配置
    clean_docker_network
    echo

    # 8. 清理残留文件
    clean_residual_files
    echo

    # 9. WSL特殊处理
    handle_wsl_cleanup
    echo

    # 10. 验证卸载
    verify_uninstall
    echo

    green "🎉 Docker卸载完成！"
    yellow "💡 建议重启系统以确保所有更改生效"

    # 提示重新登录
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        yellow "💡 建议用户 $SUDO_USER 注销并重新登录以清除组权限缓存"
    fi
}

# 修复Docker用户权限
fix_docker_user_permissions() {
    blue "🐳 Docker用户权限修复工具"
    echo "=================================="

    get_normal_user

    if [ -z "$NORMAL_USER" ] || [ "$NORMAL_USER" = "root" ]; then
        yellow "⚠️  当前以root用户运行，无需修复权限"
        return 0
    fi

    yellow "👤 当前用户: $NORMAL_USER"

    # 确保docker组存在
    if ! getent group docker >/dev/null 2>&1; then
        yellow "👥 创建docker组..."
        $SUDO groupadd docker 2>/dev/null || true
    fi

    # 检查用户是否在docker组中
    if groups $NORMAL_USER | grep -q "\bdocker\b"; then
        green "✅ 用户 $NORMAL_USER 已在docker组中"
    else
        yellow "👤 将用户 $NORMAL_USER 添加到docker组..."
        if $SUDO usermod -aG docker $NORMAL_USER 2>/dev/null; then
            green "✅ 已将用户 $NORMAL_USER 添加到docker组"
        else
            red "❌ 添加用户到docker组失败"
            return 1
        fi
    fi

    # 检查当前会话的组权限
    if [ "$(id -u)" -ne 0 ]; then
        if groups | grep -q "\bdocker\b"; then
            green "✅ 当前会话已具有docker组权限"

            # 测试Docker权限
            yellow "🧪 测试Docker权限..."
            if docker run --rm hello-world >/dev/null 2>&1; then
                green "✅ Docker权限测试通过！可以正常使用docker命令（无需sudo）"
            else
                yellow "⚠️  Docker权限测试失败，可能需要重新加载组权限"
                yellow "💡 请运行以下命令之一："
                echo "   1. newgrp docker  （立即生效，但会创建新shell）"
                echo "   2. 注销并重新登录  （推荐）"
            fi
        else
            yellow "⚠️  当前会话的组权限未生效"
            yellow "💡 请运行以下命令之一来应用组权限："
            echo ""
            echo "   方法1: newgrp docker"
            echo "   说明: 立即生效，但会创建新的shell会话"
            echo ""
            echo "   方法2: 注销并重新登录"
            echo "   说明: 推荐方法，所有新会话都会生效"
            echo ""
            echo "   方法3: 使用 sudo docker 命令"
            echo "   说明: 临时方案，每次都需要sudo"
            echo ""

            # 提供交互式选项
            if [ -t 0 ] && [ -t 1 ]; then
                readp "是否现在运行 'newgrp docker' 来立即应用权限？(Y/n): " apply_now
                if [[ ! "$apply_now" =~ ^[Nn]$ ]]; then
                    yellow "💡 正在运行 newgrp docker..."
                    yellow "⚠️  注意：这将创建一个新的shell会话"
                    yellow "   在新会话中，您可以直接使用 docker 命令（无需sudo）"
                    yellow "   输入 'exit' 可以返回原会话"
                    echo ""
                    readp "按回车键继续..." temp
                    exec newgrp docker
                fi
            fi
        fi
    fi

    return 0
}

# ==================== 主菜单 ====================

# 显示Docker状态
show_docker_status() {
    clear
    echo "==========================================="
    echo "          Docker状态信息"
    echo "==========================================="

    if command_exists docker; then
        green "Docker已安装"
        echo ""
        echo "Docker版本:"
        docker --version
        echo ""

        if command_exists docker-compose; then
            echo "Docker Compose版本:"
            docker-compose --version
            echo ""
        fi

        if command_exists systemctl; then
            echo "Docker服务状态:"
            $SUDO systemctl status docker --no-pager -l | head -n 10
            echo ""
        fi

        echo "Docker信息:"
        $SUDO docker info 2>/dev/null | head -n 20 || echo "无法获取Docker信息"
    else
        red "Docker未安装"
    fi

    echo "==========================================="
}

# 主菜单
main_menu() {
    clear
    echo "==========================================="
    echo "       Docker管理工具"
    echo "==========================================="
    echo "当前系统: $OS"
    [ "$IS_WSL" = true ] && echo "WSL环境: 是"
    [ "$IS_CHINA_IP" = true ] && echo "地理位置: 中国"
    echo ""
    echo "  1. 安装 Docker（含 Compose）"
    echo "  2. 卸载Docker"
    echo "  3. 查看Docker状态"
    echo "  4. 重启Docker服务"
    echo "  5. 更新Docker和Docker Compose"
    echo "  6. 修复Docker服务limits问题"
    echo "  7. 修复Docker用户权限（无需sudo使用docker）"
    echo "  8. 配置/迁移 containerd 数据目录（不包含 Docker data-root）"
    echo "  9. 修复 Docker 仓库连通性"
    echo " 10. 配置/迁移 Docker data-root（默认 /data/docker）"
    echo " 11. 检测并配置 Docker 拉取代理（http/socks5）"
    echo " 12. 修复 / 重置 Docker 与 containerd（可选彻底清空数据）"
    echo "  0. 退出"
    echo "==========================================="
    dm_show_proxy_status
    readp "请选择 [0-12]: " choice

    case "$choice" in
        1)
            install_docker
            readp "按回车键返回主菜单..." temp
            main_menu
            ;;
        2)
            uninstall_docker
            readp "按回车键返回主菜单..." temp
            main_menu
            ;;
        3)
            show_docker_status
            readp "按回车键返回主菜单..." temp
            main_menu
            ;;
        4)
            if command_exists systemctl; then
                yellow "重启Docker服务..."
                $SUDO systemctl restart docker
                if $SUDO systemctl is-active docker >/dev/null 2>&1; then
                    green "✅ Docker服务重启成功"
                else
                    red "❌ Docker服务重启失败"
                fi
            else
                red "systemctl不可用"
            fi
            readp "按回车键返回主菜单..." temp
            main_menu
            ;;
        5)
            upgrade_docker_and_compose
            readp "按回车键返回主菜单..." temp
            main_menu
            ;;
        6)
            repair_docker_limits
            readp "按回车键返回主菜单..." temp
            main_menu
            ;;
        7)
            fix_docker_user_permissions
            readp "按回车键返回主菜单..." temp
            main_menu
            ;;
        8)
            menu_migrate_containerd_data_path
            readp "按回车键返回主菜单..." temp
            main_menu
            ;;
        9)
            yellow "🔧 开始修复 Docker 仓库连通性..."
            fix_docker_ce_repo_connectivity
            if command_exists dnf; then
                $SUDO dnf clean all >/dev/null 2>&1 || true
                if $SUDO dnf makecache --refresh >/dev/null 2>&1; then
                    green "✅ Docker 仓库连通性修复完成（dnf 缓存刷新成功）"
                else
                    yellow "⚠️  Docker 仓库连通性已应用，但缓存刷新失败，请检查网络"
                fi
            elif command_exists yum; then
                $SUDO yum clean all >/dev/null 2>&1 || true
                if $SUDO yum makecache fast >/dev/null 2>&1; then
                    green "✅ Docker 仓库连通性修复完成（yum 缓存刷新成功）"
                else
                    yellow "⚠️  Docker 仓库连通性已应用，但缓存刷新失败，请检查网络"
                fi
            else
                yellow "⚠️  未检测到 dnf/yum，已仅应用 repo 文件修复"
            fi
            readp "按回车键返回主菜单..." temp
            main_menu
            ;;
        10)
            menu_migrate_docker_data_root_path
            readp "按回车键返回主菜单..." temp
            main_menu
            ;;
        11)
            dm_probe_build_proxy
            dm_configure_docker_proxy_stack
            dm_show_proxy_status
            readp "按回车键返回主菜单..." temp
            main_menu
            ;;
        12)
            repair_docker_containerd_runtime
            readp "按回车键返回主菜单..." temp
            main_menu
            ;;
        0)
            green "感谢使用！"
            exit 0
            ;;
        *)
            red "无效的选择，请重新输入（0-12）"
            sleep 2
            main_menu
            ;;
    esac
}

# 主函数
main() {
    # 检测系统
    detect_system
    get_sudo
    get_normal_user

    green "📋 检测到系统: $OS"
    [ "$IS_WSL" = true ] && yellow "🐧 WSL环境: 是"
    [ "$IS_CHINA_IP" = true ] && yellow "🇨🇳 地理位置: 中国"
    echo ""

    # 自动探测构建代理；不通则禁用，可用则导出到当前会话（安装/下载过程生效）
    dm_probe_build_proxy

    # 显示主菜单
    main_menu
}

# 执行主函数
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
