#!/bin/bash

# ==========================================
# Podman 管理脚本 v1.0
# ==========================================
# 功能：Podman 的安装、卸载、配置和管理
# 适用：AlmaLinux / RHEL / CentOS / Fedora
# 使用：./podman_manager.sh

set -Eeuo pipefail
IFS=$'\n\t'

# 错误处理 trap - 输出错误上下文
trap 'echo "[ERROR] 脚本: ${BASH_SOURCE[0]:-$0}, 行号: ${LINENO}, 命令: ${BASH_COMMAND}, 退出码: ${?}" >&2' ERR

# ==========================================
# 颜色定义
# ==========================================
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    PURPLE='\033[0;35m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' PURPLE='' BOLD='' NC=''
fi

# ==========================================
# 日志函数
# ==========================================
log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
info()    { echo -e "${BLUE}[$(date '+%H:%M:%S')] INFO:${NC} $*"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅${NC} $*"; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ❌ ERROR:${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ==========================================
# 常量定义
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 国内镜像源列表（用于 registries.conf）
MIRROR_ALIYUN="docker.io=https://registry.cn-hangzhou.aliyuncs.com"
MIRROR_TENCENT="docker.io=https://mirror.ccs.tencentyun.com"
MIRROR_USTC="docker.io=https://docker.mirrors.ustc.edu.cn"
MIRROR_HUAWEI="docker.io=https://swr.cn-south-1.myhuaweicloud.com"

# ── 构建/拉镜像代理（脚本内默认；可被 .env / env/base.env 覆盖）──
# 会话内自动 export（若环境已有 HTTP_PROXY 则不改）。菜单「同步代理」亦用此合并结果。
#
# 构建/安装代理：开关决定是否启用；账密来自系统 PROXY_*（PROXY_SCHEME/HOST/PORT/[USER]/[PASS]），勿写入本脚本。
# 不需要代理时设 BUILD_PROXY_ENABLED=false。若本地代理未监听，pull 可能 proxyconnect refused（诊断会无代理重试一次）。
BUILD_PROXY_ENABLED=false
BUILD_PROXY_TYPE="socks5h"
BUILD_PROXY_URL=""
BUILD_NO_PROXY="${BUILD_NO_PROXY:-localhost,127.0.0.1,::1,127.0.0.0/8}"

# 可安装软件包列表
PKG_PODMAN="podman"
PKG_COMPOSE="podman-compose"
PKG_DOCKER_COMPAT="podman-docker"
PKG_BUILDAH="buildah"
PKG_SKOPEO="skopeo"

# ==========================================
# Podman 默认路径（可在安装/迁移时交互修改）
# ==========================================
# Podman 根运行目录（runRoot）：临时运行时数据（rootful / 写入 /etc 时使用）
# 推荐：/var/run/containers 或 /run/containers。rootless 首次安装不能复用此路径（对非 root 通常不可写），脚本对 rootless 自动使用 XDG：${XDG_RUNTIME_DIR:-/run/user/<uid>/containers}
DEFAULT_PODMAN_RUN_ROOT="/var/run/containers"
# Podman 镜像/容器存储目录（graphRoot）：rootful 与 rootless 共用此脚本预设（rootless 写入 ~/.config/containers/storage.conf，并尽量 sudo mkdir+chown 本目录）
# 推荐与业务数据分区分离；勿与无关服务共用目录。
# 菜单 1 首次安装：root 写 /etc/containers/storage.conf；非 root（rootless）写用户 storage.conf 并应用本 GraphRoot + XDG RunRoot。
DEFAULT_PODMAN_GRAPH_ROOT="/data/containers"

# ==========================================
# 工具函数
# ==========================================

# 检测是否具有 sudo/root 权限
require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
            SUDO="sudo"
        elif command -v sudo &>/dev/null; then
            warn "当前操作需要 root 权限，请输入 sudo 密码"
            SUDO="sudo"
        else
            die "当前操作需要 root 权限，请以 root 用户运行或安装 sudo"
        fi
    else
        SUDO=""
    fi
}

# 带提示的 sudo 执行
run_as_root() {
    if [[ -n "${SUDO:-}" ]]; then
        $SUDO "$@"
    else
        "$@"
    fi
}

# Podman 安全执行（展示用）— stderr 丢弃；在子 shell 内关闭 errtrace / ERR，避免 set -E 下 podman 125 仍触发父脚本的 ERR 陷阱
# 注意: 仅用于只读展示命令，写操作（pull/rmi/stop等）请直接用 podman 并检查退出码
_podman_safe() {
    (
        set +o errtrace 2>/dev/null || true
        set +e +o pipefail
        trap '' ERR 2>/dev/null || true
        podman "$@" 2>/dev/null
        exit 0
    )
}

# 全局 pipefail 时，「$(podman … | 其它命令)」常以 podman 的 125 作为管道退出码并触发 ERR；此类赋值须「|| true」或 set +e / 置于 if 条件中。
# 统计换行分隔的非空行数（恒为纯数字）。勿使用 `wc -l || echo 0`：部分 wc 在空输入或非零退出时与 echo 0 拼接成「0\n0」，会破坏后续 [[ 算术比较。
_pm_count_nonempty_lines_from_var() {
    printf '%s\n' "${1:-}" | sed '/^[[:space:]]*$/d' | wc -l | awk '{ print ($1 + 0) }'
}

# 检测包管理器
detect_pkg_manager() {
    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
    elif command -v apt-get &>/dev/null; then
        PKG_MGR="apt-get"
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman"
    elif command -v zypper &>/dev/null; then
        PKG_MGR="zypper"
    else
        die "未能检测到支持的包管理器（dnf/yum/apt-get/pacman/zypper）"
    fi
}

# 检测 podman 是否已安装
is_podman_installed() {
    command -v podman &>/dev/null
}

# 获取 podman 版本
get_podman_version() {
    podman --version 2>/dev/null | awk '{print $3}' || echo "未知"
}

# 检测软件包是否已安装
is_pkg_installed() {
    local pkg="$1"
    case "$PKG_MGR" in
        dnf|yum|zypper)
            rpm -q "$pkg" &>/dev/null
            ;;
        apt-get)
            dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"
            ;;
        pacman)
            pacman -Q "$pkg" &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# 按当前包管理器安装软件包
install_pkg_if_missing() {
    local pkg="$1"
    local desc="${2:-$pkg}"
    if is_pkg_installed "$pkg"; then
        info "$desc 已安装，跳过"
        return 0
    fi

    log "安装 $desc ($pkg)..."
    case "$PKG_MGR" in
        dnf|yum)
            run_as_root $PKG_MGR install -y "$pkg"
            ;;
        apt-get)
            run_as_root apt-get update -q 2>/dev/null || true
            run_as_root apt-get install -y "$pkg"
            ;;
        pacman)
            run_as_root pacman -Sy --noconfirm "$pkg"
            ;;
        zypper)
            run_as_root zypper --non-interactive install "$pkg"
            ;;
        *)
            warn "未知包管理器 $PKG_MGR，无法安装 $pkg"
            return 1
            ;;
    esac
}

# 安装 fuse-overlayfs，避免 storage.conf 指向不存在的 mount_program
ensure_fuse_overlayfs_installed() {
    if command -v fuse-overlayfs >/dev/null 2>&1; then
        success "fuse-overlayfs 已安装: $(command -v fuse-overlayfs)"
        return 0
    fi

    if install_pkg_if_missing "fuse-overlayfs" "fuse-overlayfs（rootless overlay 兼容层）"; then
        if command -v fuse-overlayfs >/dev/null 2>&1; then
            success "fuse-overlayfs 安装成功: $(command -v fuse-overlayfs)"
            return 0
        fi
    fi

    warn "fuse-overlayfs 安装失败或不可用；Podman 5 + 新内核可继续使用 native overlay"
    return 0
}

# 按任意键继续（-e：readline，避免方向键变成 ^[[C 等转义字符）
press_any_key() {
    echo ""
    read -rep "$(echo -e "${YELLOW}按 Enter 键返回菜单...${NC}")" _
}

# 分隔线
separator() {
    echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
}

# 主界面状态栏：Podman 运行模式（rootless + native overlay / fuse-overlayfs）及实际生效的配置路径
# 注意：全局 set -E（errtrace）下，函数内 podman info 失败仍会触发 ERR；此处用子 shell + 关闭 errtrace/ERR，避免刷屏并保证 draw_header 不中断
_pm_print_podman_runtime_banner() {
    (
        set +o errtrace 2>/dev/null || true
        set +e +o pipefail
        trap '' ERR 2>/dev/null || true

        local rootless ov_driver native_diff cfg graph run graph_opts
        rootless=$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)
        ov_driver=$(podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null)
        native_diff=$(podman info --format '{{index .Store.GraphStatus "Native Overlay Diff"}}' 2>/dev/null)
        cfg=$(podman info --format '{{.Store.ConfigFile}}' 2>/dev/null)
        graph=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)
        run=$(podman info --format '{{.Store.RunRoot}}' 2>/dev/null)
        graph_opts=$(podman info --format '{{range $k,$v := .Store.GraphOptions}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null)

        if [[ -z "$graph" && -z "$run" && "$rootless" != "true" && "$rootless" != "false" ]]; then
            echo -e "  ${YELLOW}○ 无法获取 Podman 运行详情（podman info 不可用）${NC}"
            exit 0
        fi

        local overlay_kind="—"
        if [[ "$ov_driver" == "overlay" ]]; then
            if [[ "$native_diff" == "true" ]]; then
                overlay_kind="native overlay"
            elif echo "$graph_opts" | grep -qiF 'fuse-overlayfs'; then
                overlay_kind="fuse-overlayfs"
            else
                overlay_kind="overlay（非 native）"
            fi
        elif [[ -n "$ov_driver" ]]; then
            overlay_kind="驱动: ${ov_driver}"
        fi

        local mode_tag=""
        if [[ "$rootless" == "true" ]]; then
            mode_tag="rootless"
        elif [[ "$rootless" == "false" ]]; then
            mode_tag="rootful"
        else
            mode_tag="未知(root?)"
        fi

        echo -e "  ${CYAN}● 运行模式:${NC} ${BOLD}${mode_tag}${NC}  +  ${BOLD}${overlay_kind}${NC}"
        echo -e "  ${CYAN}● storage 配置文件:${NC} ${cfg:-（未知）}"
        if [[ -n "${CONTAINERS_STORAGE_CONF:-}" ]]; then
            echo -e "  ${CYAN}● CONTAINERS_STORAGE_CONF:${NC} ${CONTAINERS_STORAGE_CONF}"
        fi
        if [[ -n "${CONTAINERS_CONF:-}" ]]; then
            echo -e "  ${CYAN}● CONTAINERS_CONF:${NC} ${CONTAINERS_CONF}"
        fi
        echo -e "  ${CYAN}● GraphRoot:${NC} ${graph:-（未知）}"
        echo -e "  ${CYAN}● RunRoot:${NC}   ${run:-（未知）}"
        exit 0
    )
}

# ==========================================
# 菜单绘制
# ==========================================

draw_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║           Podman 管理脚本 v1.0                   ║"
    echo "  ║     AlmaLinux / RHEL / CentOS / Fedora           ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # 状态栏
    if is_podman_installed; then
        local ver
        ver=$(get_podman_version)
        echo -e "  ${GREEN}● Podman 已安装  版本: ${BOLD}${ver}${NC}"
        _pm_print_podman_runtime_banner
    else
        echo -e "  ${RED}○ Podman 未安装${NC}"
    fi

    # 附加组件状态
    detect_pkg_manager 2>/dev/null || true
    local extras=()
    is_pkg_installed "$PKG_COMPOSE"       && extras+=("podman-compose")
    is_pkg_installed "$PKG_DOCKER_COMPAT" && extras+=("podman-docker")
    is_pkg_installed "$PKG_BUILDAH"       && extras+=("buildah")
    is_pkg_installed "$PKG_SKOPEO"        && extras+=("skopeo")
    if [[ ${#extras[@]} -gt 0 ]]; then
        # 将数组元素用顿号连接为一行显示
        local _joined
        _joined=$(IFS='、'; echo "${extras[*]}")
        echo -e "  ${BLUE}● 附加组件: ${_joined}${NC}"
    fi

    echo ""
    separator
}

draw_main_menu() {
    draw_header
    echo -e "${BOLD}  主菜单${NC}"
    separator
    echo -e "  ${GREEN}${BOLD}【安装与卸载】${NC}"
    echo -e "   1) 安装 Podman"
    echo -e "   2) 安装附加组件（Compose / Docker兼容 / Buildah / Skopeo）"
    echo -e "   3) 卸载 Podman 及所有组件"
    echo ""
    echo -e "  ${CYAN}${BOLD}【配置】${NC}"
    echo -e "   4) 配置镜像加速源"
    echo -e "   5) 配置 Rootless 模式"
    echo -e "   6) 配置存储路径"
    echo -e "   7) 同步 Docker 代理配置（从 base.env 读取）"
    echo ""
    echo -e "  ${PURPLE}${BOLD}【管理】${NC}"
    echo -e "   8) 查看系统状态"
    echo -e "   9) 容器管理"
    echo -e "  10) 镜像管理"
    echo -e "  11) Pod 管理"
    echo -e "  12) 网络管理"
    echo -e "  13) 卷管理"
    echo -e "  14) 系统清理"
    echo ""
    echo -e "  ${YELLOW}${BOLD}【其他】${NC}"
    echo -e "  15) 运行诊断检查"
    echo ""
    echo -e "  ${RED}${BOLD}【迁移】${NC}"
    echo -e "  16) 🚀 从 Docker 一键迁移到 Podman"
    echo -e "  17) 🧹 Rootful → Rootless 统一管理（清理 root 残留，统一为普通用户）"
    echo -e "   0) 退出"
    separator
    echo -ne "  ${BOLD}请选择 [0-17]: ${NC}"
}

# ==========================================
# 1. 安装 Podman
# ==========================================
install_podman() {
    draw_header
    echo -e "${BOLD}  安装 Podman${NC}"
    separator

    if is_podman_installed; then
        warn "Podman 已安装（版本 $(get_podman_version)），无需重复安装"
        echo -e "  如需重新安装，请先执行卸载操作"
        press_any_key; return
    fi

    require_root
    detect_pkg_manager

    info "包管理器: $PKG_MGR"
    info "即将安装: $PKG_PODMAN"
    echo ""
    read -rep "$(echo -e "${YELLOW}确认安装 Podman？[Y/n]: ${NC}")" confirm
    [[ "${confirm,,}" == "n" ]] && { info "已取消"; press_any_key; return; }

    log "更新软件包索引..."
    run_as_root $PKG_MGR makecache -q 2>/dev/null || run_as_root $PKG_MGR update -q -y 2>/dev/null || true

    log "安装 Podman..."
    if install_pkg_if_missing "$PKG_PODMAN" "Podman"; then
        success "Podman 安装成功（版本 $(get_podman_version)）"
        ensure_fuse_overlayfs_installed

        # 安装后初始化配置目录
        mkdir -p "$HOME/.config/containers"
        log "已创建用户配置目录: $HOME/.config/containers"

        # 仅当以 root 身份运行脚本时写入 /etc（rootful）；非 root + sudo 装包时 EUID 仍非 0，不写 /etc，避免 RunRoot/GraphRoot 指向仅 root 可写的系统路径导致 rootless 失败
        if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
            _apply_default_podman_storage_after_install || true
        else
            info "当前非 root 会话：跳过 /etc/containers/storage.conf；将按脚本预设写入 rootless 用户配置（GraphRoot=${DEFAULT_PODMAN_GRAPH_ROOT}，RunRoot=XDG 运行目录）。"
            if _pm_apply_rootless_script_storage_defaults; then
                success "已写入 rootless 存储配置（graphRoot 优先为 ${DEFAULT_PODMAN_GRAPH_ROOT}）"
            else
                warn "未能自动写入 ~/.config/containers/storage.conf，请使用菜单「6) 配置存储路径」或检查 sudo 权限"
            fi
        fi

        # 安装后自动配置多镜像源（提升国内拉取成功率）
        echo ""
        log "自动配置多镜像加速源..."
        _apply_multi_mirrors_silent

        echo ""
        read -rep "$(echo -e "${YELLOW}是否同时安装推荐附加组件（podman-compose / buildah / skopeo）？[Y/n]: ${NC}")" install_extras
        [[ "${install_extras,,}" != "n" ]] && install_extras_menu
    else
        die "Podman 安装失败，请检查网络连接或软件源配置"
    fi

    press_any_key
}

# ==========================================
# 2. 安装附加组件
# ==========================================
install_extras_menu() {
    draw_header
    echo -e "${BOLD}  安装附加组件${NC}"
    separator

    require_root
    detect_pkg_manager

    local items=(
        "$PKG_COMPOSE:podman-compose（Docker Compose 兼容层）"
        "$PKG_DOCKER_COMPAT:podman-docker（docker 命令别名兼容）"
        "$PKG_BUILDAH:buildah（OCI 镜像构建工具）"
        "$PKG_SKOPEO:skopeo（镜像搬运/检查工具）"
    )

    echo -e "  ${CYAN}当前安装状态：${NC}"
    for item in "${items[@]}"; do
        local pkg="${item%%:*}"
        local desc="${item#*:}"
        if is_pkg_installed "$pkg"; then
            echo -e "   ${GREEN}✅ [已安装]${NC} $desc"
        else
            echo -e "   ${YELLOW}○  [未安装]${NC} $desc"
        fi
    done

    echo ""
    separator
    echo -e "   1) 安装 podman-compose（Docker Compose 兼容）"
    echo -e "   2) 安装 podman-docker（docker 命令别名）"
    echo -e "   3) 安装 buildah（镜像构建工具）"
    echo -e "   4) 安装 skopeo（镜像搬运工具）"
    echo -e "   5) 安装全部"
    echo -e "   0) 返回"
    separator
    echo -ne "  ${BOLD}请选择 [0-5]: ${NC}"
    read -re choice

    local to_install=()
    case "$choice" in
        1) to_install=("$PKG_COMPOSE") ;;
        2) to_install=("$PKG_DOCKER_COMPAT") ;;
        3) to_install=("$PKG_BUILDAH") ;;
        4) to_install=("$PKG_SKOPEO") ;;
        5) to_install=("$PKG_COMPOSE" "$PKG_DOCKER_COMPAT" "$PKG_BUILDAH" "$PKG_SKOPEO") ;;
        0) return ;;
        *) warn "无效选项"; return ;;
    esac

    local need_install=()
    for pkg in "${to_install[@]}"; do
        if is_pkg_installed "$pkg"; then
            warn "$pkg 已安装，跳过"
        else
            need_install+=("$pkg")
        fi
    done

    if [[ ${#need_install[@]} -eq 0 ]]; then
        info "所选组件均已安装"
        return
    fi

    log "安装: ${need_install[*]}"
    if run_as_root $PKG_MGR install -y "${need_install[@]}"; then
        success "安装完成: ${need_install[*]}"
    else
        error "部分组件安装失败，请检查错误信息"
    fi
}

# 卸载流程：仅在白名单路径下删除存储目录，防止误删
_pm_rm_podman_storage_path_if_safe() {
    local d="${1:-}"
    [[ -z "$d" || "$d" == "/" ]] && return 0
    case "$d" in
        /var/lib/containers|/var/lib/containers/*|/data/containers|/data/containers/*|/run/containers|/run/containers/*|/var/run/containers|/var/run/containers/*|/root/.local/share/containers|/root/.local/share/containers/*|/home/*/.local/share/containers|/home/*/.local/share/containers/*)
            if [[ -e "$d" ]]; then
                run_as_root rm -rf "$d" 2>/dev/null || true
                success "已删除存储路径: $d"
            fi
            ;;
        *)
            warn "跳过删除非白名单路径（请手动处理）: $d"
            ;;
    esac
}

# ==========================================
# 3. 卸载 Podman
# ==========================================
uninstall_podman() {
    draw_header
    echo -e "${BOLD}  卸载 Podman 及所有组件${NC}"
    separator

    require_root
    detect_pkg_manager

    if ! is_podman_installed; then
        warn "Podman 未安装，无需卸载"
        press_any_key; return
    fi

    echo -e "${RED}${BOLD}  ⚠️  警告：此操作将卸载以下软件包：${NC}"
    local all_pkgs=("$PKG_PODMAN" "$PKG_COMPOSE" "$PKG_DOCKER_COMPAT" "$PKG_BUILDAH" "$PKG_SKOPEO")
    for pkg in "${all_pkgs[@]}"; do
        is_pkg_installed "$pkg" && echo -e "   • $pkg"
    done

    echo ""
    echo -e "${CYAN}  以下为与「卸载软件包」无关的数据处理，请逐项选择（默认均为保留）：${NC}"
    echo ""
    echo -e "  ${YELLOW}(1) 本地容器数据${NC}（镜像、容器层、命名卷存储等）"
    echo -e "      ${BOLD}保留${NC} — 直接回车或输入 N"
    echo -e "      ${BOLD}卸载前尽量清理${NC} — 输入 y（将执行 root 语境下的 podman stop/rm/prune，并在卸包后删除检测到的 GraphRoot/RunRoot 目录，仅限常见路径）"
    local purge_data=""
    read -rep "$(echo -e "      ${BOLD}是否清理本地数据？[y/N]: ${NC}")" purge_data
    echo ""
    echo -e "  ${YELLOW}(2) 用户配置文件目录${NC}（registries、storage 等）"
    echo -e "      实际路径: ${CYAN}${HOME}/.config/containers/${NC}"
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "$(id -un 2>/dev/null || true)" ]]; then
        local _su_home=""
        _su_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6) || true
        [[ -n "$_su_home" ]] && echo -e "      （当前为 sudo：发起用户 ${SUDO_USER} 的配置在 ${CYAN}${_su_home}/.config/containers/${NC}，若需一并删除请对其单独选择或事后手动处理）"
    fi
    echo -e "      ${BOLD}保留${NC} — 直接回车或输入 N"
    echo -e "      ${BOLD}删除${NC} — 输入 y（仅在软件包卸载成功后执行 rm）"
    local purge_cfg=""
    read -rep "$(echo -e "      ${BOLD}是否删除上述配置目录？[y/N]: ${NC}")" purge_cfg
    echo ""
    read -rep "$(echo -e "${RED}确认卸载以上软件包？请输入 yes 确认: ${NC}")" confirm
    [[ "$confirm" != "yes" ]] && { info "已取消"; press_any_key; return; }

    local installed_pkgs=()
    for pkg in "${all_pkgs[@]}"; do
        is_pkg_installed "$pkg" && installed_pkgs+=("$pkg")
    done

    local _graph="" _run=""
    if [[ "${purge_data,,}" == "y" ]]; then
        info "正在清理本地 Podman 数据（root 语境）…"
        _graph=$(run_as_root podman info --format '{{.Store.GraphRoot}}' 2>/dev/null) || true
        _run=$(run_as_root podman info --format '{{.Store.RunRoot}}' 2>/dev/null) || true
        run_as_root podman stop -a -t 0 2>/dev/null || true
        run_as_root podman rm -af 2>/dev/null || true
        run_as_root podman volume prune -f 2>/dev/null || true
        run_as_root podman rmi -af 2>/dev/null || true
        run_as_root podman system prune -af --volumes --build --external 2>/dev/null || run_as_root podman system prune -af --volumes --build 2>/dev/null || true
        if [[ -n "${SUDO_USER:-}" ]]; then
            local _rh="" _lc=""
            _rh=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6) || true
            _lc="${_rh}/.local/share/containers"
            if [[ -n "$_lc" && -d "$_lc" ]]; then
                info "尝试清理 ${SUDO_USER} 的 rootless 存储: $_lc"
                run_as_root rm -rf "$_lc" 2>/dev/null || true
            fi
        fi
        success "本地数据清理步骤已执行（若仍有残留目录，请按 podman info 中的路径手动核对）"
    fi

    log "卸载: ${installed_pkgs[*]}"
    if run_as_root $PKG_MGR remove -y "${installed_pkgs[@]}"; then
        success "卸载完成"
        if [[ "${purge_data,,}" == "y" ]]; then
            _pm_rm_podman_storage_path_if_safe "$_graph"
            _pm_rm_podman_storage_path_if_safe "$_run"
        fi
        if [[ "${purge_cfg,,}" == "y" ]]; then
            if [[ -d "$HOME/.config/containers" ]]; then
                rm -rf "$HOME/.config/containers"
                success "已删除配置目录: $HOME/.config/containers/"
            else
                info "配置目录不存在，跳过: $HOME/.config/containers/"
            fi
            if [[ -n "${SUDO_USER:-}" ]]; then
                local _suh="" purge_cfg_su=""
                _suh=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6) || true
                if [[ -n "$_suh" && "$_suh" != "$HOME" && -d "${_suh}/.config/containers" ]]; then
                    read -rep "$(echo -e "${YELLOW}是否同时删除 sudo 发起用户 ${SUDO_USER} 的配置目录 ${_suh}/.config/containers/ ？[y/N]: ${NC}")" purge_cfg_su
                    if [[ "${purge_cfg_su,,}" == "y" ]]; then
                        run_as_root rm -rf "${_suh}/.config/containers"
                        success "已删除: ${_suh}/.config/containers/"
                    fi
                fi
            fi
        fi
    else
        error "卸载过程中出现错误"
    fi

    press_any_key
}

# ==========================================
# 4. 配置镜像加速源
# ==========================================
configure_mirrors() {
    draw_header
    echo -e "${BOLD}  配置镜像加速源${NC}"
    separator

    local user_cfg="$HOME/.config/containers/registries.conf"
    local sys_cfg="/etc/containers/registries.conf"

    # 显示当前配置
    echo -e "  ${CYAN}当前镜像配置文件：${NC}"
    if [[ -f "$user_cfg" ]]; then
        echo -e "   用户级: ${GREEN}$user_cfg${NC}"
        grep -E "prefix|location" "$user_cfg" 2>/dev/null | head -10 || true
    else
        echo -e "   用户级: ${YELLOW}未配置${NC}"
    fi
    if [[ -f "$sys_cfg" ]]; then
        echo -e "   系统级: ${GREEN}$sys_cfg${NC}（需 root 修改）"
    fi

    echo ""
    separator
    echo -e "   1) 配置阿里云镜像加速"
    echo -e "   2) 配置腾讯云镜像加速"
    echo -e "   3) 配置中科大镜像加速"
    echo -e "   4) 配置华为云镜像加速"
    echo -e "   5) 同时配置多个镜像源（推荐）"
    echo -e "   6) 自定义镜像源"
    echo -e "   7) 查看当前配置"
    echo -e "   8) 清除镜像源配置"
    echo -e "   0) 返回"
    separator
    echo -ne "  ${BOLD}请选择 [0-8]: ${NC}"
    read -re choice

    case "$choice" in
        1) _apply_mirror "阿里云" "registry.cn-hangzhou.aliyuncs.com" ;;
        2) _apply_mirror "腾讯云" "mirror.ccs.tencentyun.com" ;;
        3) _apply_mirror "中科大" "docker.mirrors.ustc.edu.cn" ;;
        4) _apply_mirror "华为云" "swr.cn-south-1.myhuaweicloud.com" ;;
        5) _apply_multi_mirrors ;;
        6)
            echo -ne "  输入镜像源地址（如 mirror.example.com）: "
            read -re custom_mirror
            [[ -z "$custom_mirror" ]] && { warn "地址为空，已取消"; press_any_key; return; }
            _apply_mirror "自定义" "$custom_mirror"
            ;;
        7)
            echo ""
            echo -e "${CYAN}=== 用户级配置 ($user_cfg) ===${NC}"
            [[ -f "$user_cfg" ]] && cat "$user_cfg" || echo "  （未配置）"
            ;;
        8)
            read -rep "$(echo -e "${YELLOW}确认清除用户级镜像源配置？[y/N]: ${NC}")" c
            if [[ "${c,,}" == "y" ]]; then
                rm -f "$user_cfg"
                success "已清除 $user_cfg"
            fi
            ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac

    press_any_key
}

_apply_mirror() {
    local name="$1"
    local mirror_host="$2"
    local user_cfg="$HOME/.config/containers/registries.conf"
    mkdir -p "$(dirname "$user_cfg")"

    cat > "$user_cfg" <<EOF
# Podman 镜像加速配置 - 由 podman_manager.sh 生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "docker.io"
location = "docker.io"

  [[registry.mirror]]
  location = "${mirror_host}"

EOF
    success "已配置 ${name} 镜像加速（${mirror_host}）"
    info "配置文件: $user_cfg"
    _test_mirror "$mirror_host"
}

# 内部镜像源列表（有序，podman 按顺序尝试）
_PM_MIRROR_HOSTS=(
    "registry.cn-hangzhou.aliyuncs.com"   # 阿里云
    "mirror.ccs.tencentyun.com"           # 腾讯云
    "swr.cn-south-1.myhuaweicloud.com"    # 华为云
    "docker.mirrors.ustc.edu.cn"          # 中科大
    "mirror.baidubce.com"                 # 百度云
)

# _write_multi_mirrors_conf：把 _PM_MIRROR_HOSTS 写入 registries.conf
_write_multi_mirrors_conf() {
    local user_cfg="$HOME/.config/containers/registries.conf"
    mkdir -p "$(dirname "$user_cfg")"

    # 构建 [[registry.mirror]] 块（每个占两行）
    local mirror_blocks=""
    for mhost in "${_PM_MIRROR_HOSTS[@]}"; do
        mirror_blocks+=$'\n  [[registry.mirror]]\n'
        mirror_blocks+=$"  location = \"${mhost}\""
    done
    mirror_blocks+=$'\n'

    {
        echo "# Podman 多镜像加速配置 - 由 podman_manager.sh 生成"
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# 镜像源数量: ${#_PM_MIRROR_HOSTS[@]}"
        echo ""
        echo 'unqualified-search-registries = ["docker.io"]'
        echo ""
        echo '[[registry]]'
        echo 'prefix = "docker.io"'
        echo 'location = "docker.io"'
        printf '%s' "$mirror_blocks"
    } > "$user_cfg"

    echo "$user_cfg"
}

# _apply_multi_mirrors：交互式入口（显示进度、测试连通性）
_apply_multi_mirrors() {
    local user_cfg
    user_cfg=$(_write_multi_mirrors_conf)

    success "已配置 ${#_PM_MIRROR_HOSTS[@]} 个镜像源（按序尝试）:"
    local idx=1
    for mhost in "${_PM_MIRROR_HOSTS[@]}"; do
        echo -e "   ${idx}) ${mhost}"
        (( idx++ )) || true
    done
    info "配置文件: $user_cfg"

    # 测试各镜像源连通性
    echo ""
    info "测试镜像源连通性..."
    for mhost in "${_PM_MIRROR_HOSTS[@]}"; do
        _test_mirror "$mhost"
    done
}

# _apply_multi_mirrors_silent：安装后自动调用（静默写配置，不测连通性）
_apply_multi_mirrors_silent() {
    local user_cfg
    user_cfg=$(_write_multi_mirrors_conf)
    success "已自动写入 ${#_PM_MIRROR_HOSTS[@]} 个镜像加速源:"
    local idx=1
    for mhost in "${_PM_MIRROR_HOSTS[@]}"; do
        echo -e "   ${idx}) ${mhost}"
        (( idx++ )) || true
    done
    info "配置文件: $user_cfg"
    info "提示：可通过菜单「4) 配置镜像加速源」随时调整"
}

_test_mirror() {
    local host="$1"
    local code
    code=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" "https://${host}/v2/" 2>/dev/null) || code="000"
    if echo "$code" | grep -qE "^(200|401|403)"; then
        echo -e "   ${GREEN}✓${NC} ${host}（HTTP ${code}）"
    else
        echo -e "   ${YELLOW}?${NC} ${host}（HTTP ${code}，直连不可达，将由代理处理）"
    fi
}

# ==========================================
# 5. 配置 Rootless 模式
# ==========================================

# 验证 Rootless 状态并运行最小测试容器（stderr 在失败时展示，便于排查拉镜像/存储等问题）
_verify_rootless_configuration() {
    _fix_rootless_storage_if_unwritable 2>/dev/null || true
    echo ""
    log "验证 Rootless / 容器运行时..."
    local rootless_flag seccomp_en
    rootless_flag=$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo "unknown")
    seccomp_en=$(podman info --format '{{.Host.Security.Seccomp.Enabled}}' 2>/dev/null || echo "unknown")

    echo -e "  ${CYAN}当前 EUID:${NC} ${EUID}  ${CYAN}（0 通常表示 root / sudo 提权，Podman 多为 rootful）${NC}"
    echo -e "  ${CYAN}Podman Rootless:${NC} ${BOLD}${rootless_flag}${NC}"
    echo -e "  ${CYAN}Seccomp 已启用:${NC} ${seccomp_en}"

    if [[ "${rootless_flag}" != "true" ]]; then
        warn "当前 Podman 未处于 Rootless（Rootless=${rootless_flag}）。若以 sudo 运行本脚本，会固定为 rootful。"
        info "要验证真实 Rootless：请直接以普通用户执行本脚本，或终端运行: podman info -f '{{.Host.Security.Rootless}}'"
    fi

    echo ""
    log "尝试运行测试容器（需能拉取镜像；先 alpine，失败再试 quay.io/podman/hello）..."
    local errf outf ok=0 last_img=""
    errf=$(mktemp 2>/dev/null || echo "/tmp/podman_mgr_rootless_err.$$")
    outf="${errf}.stdout"
    last_img='docker.io/library/alpine:latest'
    if _pm_podman_registry_proxy_try_then_bypass --capture "$outf" "$errf" podman run --rm --pull=missing "$last_img" echo "Podman 测试容器运行成功"; then
        ok=1
    else
        last_img='quay.io/podman/hello:latest'
        # hello 镜像使用内置入口，不可再传 shell/echo 子命令
        if _pm_podman_registry_proxy_try_then_bypass --capture "$outf" "$errf" podman run --rm --pull=missing "$last_img"; then
            ok=1
        fi
    fi
    rm -f "$outf" 2>/dev/null || true

    if [[ "$ok" -eq 1 ]]; then
        if [[ "${rootless_flag}" == "true" ]]; then
            success "Rootless 下容器运行正常"
        else
            success "容器运行正常（当前为 rootful；若要 Rootless 请以普通用户运行 Podman）"
        fi
        rm -f "$errf" 2>/dev/null || true
    else
        warn "测试容器运行失败（最后尝试镜像: ${last_img}）"
        if [[ -s "$errf" ]]; then
            info "Podman 错误输出（节选）:"
            sed 's/^/  /' "$errf" | head -35
        else
            info "（无错误输出；可手动执行: podman run --rm -it ${last_img} sh）"
        fi
        rm -f "$errf" 2>/dev/null || true
        info "常见原因: 代理需认证时请确认系统 PROXY_USER/PASS（或临时 BUILD_PROXY_URL）；不需要代理时设 BUILD_PROXY_ENABLED=false；另可配置「镜像加速」、检查 slirp4netns/passt、存储驱动、subuid（重新登录或 newgrp）"
    fi
}

configure_rootless() {
    if ! is_podman_installed; then
        draw_header
        echo -e "${BOLD}  配置 Rootless 模式${NC}"
        separator
        warn "请先安装 Podman"
        press_any_key
        return
    fi

    local user="${USER:-$(id -un)}"
    while true; do
        draw_header
        echo -e "${BOLD}  配置 Rootless 模式${NC}"
        separator

        echo -e "  ${CYAN}Rootless 模式说明：${NC}"
        echo -e "  • 无需 root 权限即可运行容器，提升安全性"
        echo -e "  • 需要 newuidmap / newgidmap 及 /etc/subuid、/etc/subgid 配置"
        echo ""

        echo -e "  ${CYAN}当前用户: ${BOLD}${user}${NC}"

        if grep -q "^${user}:" /etc/subuid 2>/dev/null; then
            echo -e "  ${GREEN}✅ /etc/subuid 已配置${NC}"
        else
            echo -e "  ${RED}○  /etc/subuid 未配置${NC}"
        fi

        if grep -q "^${user}:" /etc/subgid 2>/dev/null; then
            echo -e "  ${GREEN}✅ /etc/subgid 已配置${NC}"
        else
            echo -e "  ${RED}○  /etc/subgid 未配置${NC}"
        fi

        if command -v newuidmap &>/dev/null; then
            echo -e "  ${GREEN}✅ newuidmap 已安装${NC}"
        else
            echo -e "  ${RED}○  newuidmap 未安装（需安装 shadow-utils）${NC}"
        fi

        echo ""
        separator
        echo -e "   1) 自动配置 Rootless（为当前用户添加 subuid/subgid）"
        echo -e "   2) 安装 shadow-utils（提供 newuidmap/newgidmap）"
        echo -e "   3) 验证 Rootless 配置"
        echo -e "   4) 迁移现有容器到 Rootless 模式"
        echo -e "   0) 返回主菜单"
        separator
        echo -ne "  ${BOLD}请选择 [0-4]: ${NC}"
        read -re choice

        case "$choice" in
            1) _setup_rootless "$user" ;;
            2)
                require_root
                detect_pkg_manager
                if run_as_root $PKG_MGR install -y shadow-utils; then
                    success "shadow-utils 安装完成"
                else
                    warn "shadow-utils 安装失败"
                fi
                ;;
            3) _verify_rootless_configuration ;;
            4)
                info "执行 podman system migrate..."
                if podman system migrate; then
                    success "迁移完成"
                else
                    warn "podman system migrate 失败（可查看上方输出）"
                fi
                ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac

        press_any_key
    done
}

_setup_rootless() {
    local user="$1"
    require_root

    # P2 优化：从现有 subuid/subgid 最大值递增，避免 UID 不连续时的范围碎片化
    # 算法：读取已有所有用户的起始值，取最大值 + 65536 作为新起始值
    local start_uid
    start_uid=$(awk -F: '/^[^#]/ && $2 > 0 { if ($2 > max) max=$2 } END { print (max > 0 ? max + 65536 : 100000) }' /etc/subuid 2>/dev/null || echo 100000)
    local start_gid
    start_gid=$(awk -F: '/^[^#]/ && $2 > 0 { if ($2 > max) max=$2 } END { print (max > 0 ? max + 65536 : 100000) }' /etc/subgid 2>/dev/null || echo 100000)

    if ! grep -q "^${user}:" /etc/subuid 2>/dev/null; then
        echo "${user}:${start_uid}:65536" | run_as_root tee -a /etc/subuid > /dev/null
        success "已写入 /etc/subuid: ${user}:${start_uid}:65536"
    else
        warn "/etc/subuid 中 ${user} 已存在，跳过"
    fi

    if ! grep -q "^${user}:" /etc/subgid 2>/dev/null; then
        echo "${user}:${start_gid}:65536" | run_as_root tee -a /etc/subgid > /dev/null
        success "已写入 /etc/subgid: ${user}:${start_gid}:65536"
    else
        warn "/etc/subgid 中 ${user} 已存在，跳过"
    fi

    log "配置用户命名空间..."
    run_as_root sysctl -w kernel.unprivileged_userns_clone=1 2>/dev/null || true
    run_as_root podman system migrate 2>/dev/null || true

    success "Rootless 配置完成，请重新登录或执行：newgrp ${user}"
}

# ==========================================
# 6. 配置存储路径
# ==========================================
configure_storage() {
    draw_header
    echo -e "${BOLD}  配置存储路径${NC}"
    separator

    if ! is_podman_installed; then
        warn "请先安装 Podman"; press_any_key; return
    fi

    local sys_storage_cfg="/etc/containers/storage.conf"
    local user_storage_cfg="$HOME/.config/containers/storage.conf"
    local rl_def_run="${XDG_RUNTIME_DIR:-/run/user/$(id -u)/containers}"

    _fix_rootless_storage_if_unwritable 2>/dev/null || true

    # P6: 检测 rootless 模式，确定正确的配置文件路径
    # rootless Podman 只读取 ~/.config/containers/storage.conf，
    # 不读取 /etc/containers/storage.conf
    local is_rootless="false"
    local effective_storage_cfg="$sys_storage_cfg"
    if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q "true"; then
        is_rootless="true"
        effective_storage_cfg="$user_storage_cfg"
    elif [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        # podman info 可能因 graphRoot 不可写失败；非 root 按 rootless 用户配置处理
        is_rootless="true"
        effective_storage_cfg="$user_storage_cfg"
    fi

    # 优先读取 podman info 中的实际路径
    local current_graph
    current_graph=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo "未知")
    local current_run
    current_run=$(podman info --format '{{.Store.RunRoot}}' 2>/dev/null || echo "未知")

    echo -e "  ${CYAN}当前存储配置（实际生效）：${NC}"
    echo -e "   运行模式   : $( [[ "$is_rootless" == "true" ]] && echo 'rootless (非特权)' || echo 'root (特权)' )"
    echo -e "   配置文件   : ${YELLOW}${effective_storage_cfg}${NC}"
    echo -e "   GraphRoot（镜像/容器） : ${GREEN}${current_graph}${NC}"
    echo -e "   RunRoot（运行时数据）  : ${GREEN}${current_run}${NC}"
    echo ""
    echo -e "  ${CYAN}预设默认路径：${NC}"
    if [[ "$is_rootless" == "true" ]]; then
        echo -e "   GraphRoot 默认（脚本常量，与菜单 1 非 root 安装一致）: ${YELLOW}${DEFAULT_PODMAN_GRAPH_ROOT}${NC}"
        echo -e "   RunRoot 默认（rootless 可写，XDG）                    : ${YELLOW}${rl_def_run}${NC}"
        echo -e "   （rootful 写入 /etc 时 RunRoot 字面量为 ${YELLOW}${DEFAULT_PODMAN_RUN_ROOT}${NC}，rootless 不能直接使用该路径）"
    else
        echo -e "   GraphRoot 默认   : ${YELLOW}${DEFAULT_PODMAN_GRAPH_ROOT}${NC}"
        echo -e "   RunRoot 默认     : ${YELLOW}${DEFAULT_PODMAN_RUN_ROOT}${NC}"
    fi
    if [[ "$is_rootless" == "true" ]]; then
        echo -e "  ${YELLOW}警告: rootless 模式下存储配置写入 ~/.config/containers/storage.conf${NC}"
        echo -e "  ${YELLOW}而非 /etc/containers/storage.conf（rootless Podman 不读取系统配置）${NC}"
    fi
    # 安全检查：如果是通过 sudo 以 root 身份运行，生效路径是 $HOME/.config/...
    # 此时 $HOME 可能解析为 /root，而非普通用户 home。
    # 需明确提示用户应在普通用户终端（非 sudo）运行 configure_storage。
    if [[ "$EUID" -eq 0 && "$effective_storage_cfg" == "$user_storage_cfg" ]]; then
        echo -e "  ${RED}⚠ 检测到以 root 身份配置 rootless 存储：${NC}"
        echo -e "  ${RED}$HOME/.config/containers/storage.conf 将指向 /root，而非普通用户 home${NC}"
        echo -e "  ${YELLOW}建议: 退出 sudo，以普通用户身份执行菜单 6 配置存储路径${NC}"
    fi
    echo ""

    # 展示当前配置文件内容
    for cfg in "$sys_storage_cfg" "$user_storage_cfg"; do
        if [[ -f "$cfg" ]]; then
            echo -e "  ${CYAN}配置文件：${NC} $cfg"
            grep -v '^ *#\|^ *$' "$cfg" 2>/dev/null | head -20 || true
            echo ""
        fi
    done

    separator
    echo -e "   1) 修改 GraphRoot（镜像和容器存储路径）"
    echo -e "   2) 修改 RunRoot（运行时数据路径）"
    if [[ "$is_rootless" == "true" ]]; then
        echo -e "   3) 一键应用脚本默认路径（GraphRoot=${DEFAULT_PODMAN_GRAPH_ROOT}，RunRoot=XDG）"
    else
        echo -e "   3) 一键应用默认路径（GraphRoot=${DEFAULT_PODMAN_GRAPH_ROOT}  RunRoot=${DEFAULT_PODMAN_RUN_ROOT}）"
    fi
    echo -e "   4) 查看存储使用情况"
    echo -e "   5) 重置存储配置为系统默认值"
    echo -e "   0) 返回"
    separator
    echo -ne "  ${BOLD}请选择 [0-5]: ${NC}"
    read -re choice

    case "$choice" in
        1)
            local def_g="$DEFAULT_PODMAN_GRAPH_ROOT"
            echo -e "  当前 GraphRoot: ${GREEN}${current_graph}${NC}"
            echo -ne "  输入新路径 [直接回车使用默认 ${def_g}]: "
            read -re new_graph
            [[ -z "$new_graph" ]] && new_graph="$def_g"
            local use_run="$current_run"
            [[ "$use_run" == "未知" ]] && use_run="$rl_def_run"
            if [[ "$is_rootless" == "true" ]]; then
                if [[ "$new_graph" == "$DEFAULT_PODMAN_GRAPH_ROOT" || "$new_graph" == "${DEFAULT_PODMAN_GRAPH_ROOT}/"* ]]; then
                    run_as_root mkdir -p "$new_graph" 2>/dev/null || { warn "无法创建目录（需 sudo）: $new_graph"; press_any_key; return; }
                    _sudo_chown_default_podman_graph_root_for_current_user 2>/dev/null || true
                fi
                mkdir -p "$new_graph" || { warn "无法创建目录: $new_graph"; press_any_key; return; }
                _write_storage_conf_for_current_user "$effective_storage_cfg" "$new_graph" "$use_run"
            else
                require_root
                run_as_root mkdir -p "$new_graph" || { warn "无法创建目录: $new_graph"; press_any_key; return; }
                _write_storage_conf "$effective_storage_cfg" "$new_graph" "$use_run"
            fi
            success "已更新 GraphRoot → $new_graph"
            warn "已有数据不会自动迁移，需手动复制或重新拉取镜像"
            ;;
        2)
            local def_r="$DEFAULT_PODMAN_RUN_ROOT"
            [[ "$is_rootless" == "true" ]] && def_r="$rl_def_run"
            echo -e "  当前 RunRoot: ${GREEN}${current_run}${NC}"
            echo -ne "  输入新路径 [直接回车使用默认 ${def_r}]: "
            read -re new_run
            [[ -z "$new_run" ]] && new_run="$def_r"
            local use_graph="$current_graph"
            [[ "$use_graph" == "未知" ]] && use_graph="$DEFAULT_PODMAN_GRAPH_ROOT"
            if [[ "$is_rootless" == "true" ]]; then
                if [[ "$use_graph" == "$DEFAULT_PODMAN_GRAPH_ROOT" || "$use_graph" == "${DEFAULT_PODMAN_GRAPH_ROOT}/"* ]]; then
                    run_as_root mkdir -p "$use_graph" 2>/dev/null || true
                    _sudo_chown_default_podman_graph_root_for_current_user 2>/dev/null || true
                fi
                mkdir -p "$new_run" || { warn "无法创建目录: $new_run"; press_any_key; return; }
                _write_storage_conf_for_current_user "$effective_storage_cfg" "$use_graph" "$new_run"
            else
                require_root
                run_as_root mkdir -p "$new_run" || { warn "无法创建目录: $new_run"; press_any_key; return; }
                _write_storage_conf "$effective_storage_cfg" "$use_graph" "$new_run"
            fi
            success "已更新 RunRoot → $new_run"
            ;;
        3)
            echo ""
            if [[ "$is_rootless" == "true" ]]; then
                echo -e "  将应用以下路径（与菜单 1 非 root 安装一致）："
                echo -e "   GraphRoot : ${YELLOW}${DEFAULT_PODMAN_GRAPH_ROOT}${NC}（sudo 建目录并修正属主）"
                echo -e "   RunRoot   : ${YELLOW}${rl_def_run}${NC}（XDG 运行目录）"
            else
                echo -e "  将应用以下默认路径："
                echo -e "   GraphRoot : ${YELLOW}${DEFAULT_PODMAN_GRAPH_ROOT}${NC}"
                echo -e "   RunRoot   : ${YELLOW}${DEFAULT_PODMAN_RUN_ROOT}${NC}"
            fi
            echo ""
            read -rep "$(echo -e "${YELLOW}确认应用默认路径？[Y/n]: ${NC}")" confirm
            [[ "${confirm,,}" == "n" ]] && { info "已取消"; press_any_key; return; }
            if [[ "$is_rootless" == "true" ]]; then
                if _pm_apply_rootless_script_storage_defaults; then
                    success "已应用 rootless 脚本默认存储配置"
                else
                    warn "应用失败，请检查 sudo 与目录权限"
                fi
            else
                require_root
                run_as_root mkdir -p "$DEFAULT_PODMAN_GRAPH_ROOT" "$DEFAULT_PODMAN_RUN_ROOT"
                _write_storage_conf "$effective_storage_cfg" "$DEFAULT_PODMAN_GRAPH_ROOT" "$DEFAULT_PODMAN_RUN_ROOT"
                success "已应用默认路径配置"
            fi
            ;;
        4)
            echo ""
            log "存储使用情况："
            _podman_safe system df || warn "无法获取存储信息"
            ;;
        5)
            read -rep "$(echo -e "${YELLOW}确认删除所有存储配置文件，恢复系统默认？[y/N]: ${NC}")" c
            if [[ "${c,,}" == "y" ]]; then
                require_root
                run_as_root rm -f "$sys_storage_cfg"
                rm -f "$user_storage_cfg" 2>/dev/null || true
                success "已删除存储配置 ($sys_storage_cfg 和 $user_storage_cfg)，重启 podman 后生效"
            fi
            ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac

    press_any_key
}

# 新安装 Podman（菜单 1）成功后：root → /etc/containers/storage.conf（rootful）；非 root → _pm_apply_rootless_script_storage_defaults（用户 storage.conf）
_apply_default_podman_storage_after_install() {
    # 防御：仅真实 root 应写 /etc；非 root 即使用 sudo dnf 也不应改系统 storage（避免 rootless 继承不可写路径）
    [[ "${EUID:-$(id -u)}" -ne 0 ]] && return 0
    require_root
    log "自动应用预设存储路径（GraphRoot=${DEFAULT_PODMAN_GRAPH_ROOT}, RunRoot=${DEFAULT_PODMAN_RUN_ROOT}）..."
    if ! run_as_root mkdir -p "$DEFAULT_PODMAN_GRAPH_ROOT" "$DEFAULT_PODMAN_RUN_ROOT"; then
        warn "创建存储目录失败，跳过自动写入 storage.conf（可稍后使用菜单 6 配置）"
        return 0
    fi
    _write_storage_conf "/etc/containers/storage.conf" "$DEFAULT_PODMAN_GRAPH_ROOT" "$DEFAULT_PODMAN_RUN_ROOT"
    success "已自动配置 rootful 存储: graphRoot=${DEFAULT_PODMAN_GRAPH_ROOT}, runRoot=${DEFAULT_PODMAN_RUN_ROOT}"
}

# rootless：GraphRoot 使用脚本常量 DEFAULT_PODMAN_GRAPH_ROOT（sudo 建目录并 chown）；RunRoot 使用 XDG 运行目录（与 DEFAULT_PODMAN_RUN_ROOT 字面路径不同，否则无写权限）
_pm_apply_rootless_script_storage_defaults() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 1
    local user_sc="${HOME%/}/.config/containers/storage.conf"
    local rl_run="${XDG_RUNTIME_DIR:-/run/user/$(id -u)/containers}"
    local rl_graph_home="${XDG_DATA_HOME:-$HOME/.local/share}/containers/storage"
    local graph_use="$DEFAULT_PODMAN_GRAPH_ROOT"

    mkdir -p "$HOME/.config/containers" "$rl_run" 2>/dev/null || true

    if ! run_as_root mkdir -p "$DEFAULT_PODMAN_GRAPH_ROOT" 2>/dev/null; then
        warn "无法创建 GraphRoot（需 sudo）：${DEFAULT_PODMAN_GRAPH_ROOT}；暂用 ${rl_graph_home}"
        graph_use="$rl_graph_home"
    else
        _sudo_chown_default_podman_graph_root_for_current_user 2>/dev/null || true
        if ! _podman_storage_path_usable_non_root "$DEFAULT_PODMAN_GRAPH_ROOT" 2>/dev/null; then
            warn "${DEFAULT_PODMAN_GRAPH_ROOT} 对当前用户不可写；暂用 ${rl_graph_home}"
            graph_use="$rl_graph_home"
        fi
    fi
    mkdir -p "$graph_use" 2>/dev/null || true
    if _write_storage_conf_for_current_user "$user_sc" "$graph_use" "$rl_run"; then
        log "已写入 ${user_sc}（graphRoot=${graph_use}, runRoot=${rl_run}）"
        return 0
    fi
    return 1
}

# 内部：写入 storage.conf（mode=root 需已 require_root；mode=user 写入当前用户 HOME，无需 root）
_write_storage_conf_impl() {
    local conf_path="$1"
    local graph_root="$2"
    local run_root="$3"
    local mode="${4:-root}"

    local tmpf
    tmpf=$(mktemp)
    local overlay_section=""
    local kernel_major kernel_minor
    kernel_major=$(uname -r | cut -d. -f1)
    kernel_minor=$(uname -r | cut -d. -f2)
    if [[ "${kernel_major}" -ge 6 ]] || [[ "${kernel_major}" -eq 5 && "${kernel_minor}" -ge 13 ]]; then
        overlay_section=$'\n# 内核 '$(uname -r)$' 支持 rootless native overlay，无需 fuse-overlayfs\n# native overlay 比 fuse-overlayfs 性能提升 40-60%'
    elif command -v fuse-overlayfs >/dev/null 2>&1; then
        overlay_section=$'\n[storage.options.overlay]\nmount_program = "'"$(command -v fuse-overlayfs)"'"\n# 内核 '$(uname -r)$' < 5.13，需要 fuse-overlayfs 提供 rootless overlay 支持'
    else
        overlay_section=$'\n# ⚠️  内核 '$(uname -r)$' < 5.13 且 fuse-overlayfs 未安装\n# rootless 模式可能无法使用 overlay 驱动，将回退到 vfs（性能显著下降）\n# 建议: 升级内核至 5.13+ 或安装 fuse-overlayfs'
    fi

    cat > "$tmpf" <<STOREOF
# Podman 存储配置 - 由 podman_manager.sh 生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

[storage]
driver = "overlay"
runRoot = "${run_root}"
graphRoot = "${graph_root}"

[storage.options]
additionalimagestores = []
${overlay_section}
STOREOF

    if [[ "$mode" == "root" ]]; then
        run_as_root mkdir -p "$(dirname "$conf_path")"
        run_as_root cp "$tmpf" "$conf_path"
        run_as_root chmod 644 "$conf_path"
    else
        mkdir -p "$(dirname "$conf_path")" || { rm -f "$tmpf"; return 1; }
        mkdir -p "$graph_root" "$run_root" 2>/dev/null || true
        cp "$tmpf" "$conf_path" || { rm -f "$tmpf"; return 1; }
        chmod 644 "$conf_path"
    fi
    rm -f "$tmpf"
}

# 内部：写入 /etc/containers/storage.conf（rootful）
_write_storage_conf() {
    local conf_path="$1"
    local graph_root="$2"
    local run_root="$3"
    require_root
    _write_storage_conf_impl "$conf_path" "$graph_root" "$run_root" "root"
}

# 写入当前用户 ~/.config/containers/storage.conf（rootless，路径须当前用户可写）
_write_storage_conf_for_current_user() {
    _write_storage_conf_impl "$1" "$2" "$3" "user"
}

# 判断当前非 root 用户是否可将该路径作为 Podman GraphRoot/RunRoot 使用（可写且在允许的位置）
_podman_storage_path_usable_non_root() {
    local p="$1" uid me
    [[ -z "$p" || "$p" != /* ]] && return 1
    uid=$(id -u)
    me="/run/user/${uid}"
    if [[ "$p" == "${me}"/* ]] || [[ "$p" == "$me" ]]; then
        [[ -w "$p" ]] && return 0
        mkdir -p "$p" 2>/dev/null && [[ -w "$p" ]] && return 0
        return 1
    fi
    if [[ "$p" == "${HOME}/"* ]]; then
        [[ -w "$p" ]] && return 0
        mkdir -p "$p" 2>/dev/null && [[ -w "$p" ]] && return 0
        return 1
    fi
    case "$p" in
        /run/containers|/run/containers/*|/var/run/containers|/var/run/containers/*)
            [[ -w "$p" ]] && return 0
            return 1 ;;
        /data/containers|/data/containers/*|/var/lib/containers|/var/lib/containers/*)
            [[ -w "$p" ]] && return 0
            mkdir -p "$p" 2>/dev/null && [[ -w "$p" ]] && return 0
            return 1 ;;
    esac
    [[ -w "$p" ]] && return 0
    return 1
}

# /etc 中 rootful 路径可能导致 rootless 继承不可写路径。优先尝试 sudo 将 DEFAULT_PODMAN_GRAPH_ROOT 归属当前用户；仍失败再写入 ~/.config/containers/storage.conf。
_sudo_chown_default_podman_graph_root_for_current_user() {
    local d="${DEFAULT_PODMAN_GRAPH_ROOT}"
    local u="${USER:-$(id -un)}"
    local g
    g="$(id -gn)"
    if ! command -v sudo &>/dev/null; then
        return 1
    fi
    if ! sudo -n true 2>/dev/null; then
        info "将尝试使用 sudo 修正 ${d} 属主为 ${u}:${g}（若提示请输入密码）"
    fi
    if sudo mkdir -p "$d" 2>/dev/null && sudo chown -R "${u}:${g}" "$d" 2>/dev/null; then
        log "已通过 sudo 将 ${d} 归属为 ${u}:${g}"
        return 0
    fi
    warn "sudo 未能修正 ${d} 权限（可能无权限或已取消）；将回退为写入用户级 storage.conf"
    return 1
}

# 返回 0 表示仍存在不可写等问题（需继续写入 ~/.config）；返回 1 表示已恢复可用
_podman_storage_still_needs_user_conf() {
    if podman info 2>&1 | head -50 | grep -qiE 'runroot.*not writable|graphroot.*not writable|not writable.*(/run/containers|/var/run/containers|/data/containers|/var/lib/containers|libpod)'; then
        return 0
    fi
    local gr rr
    gr=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)
    rr=$(podman info --format '{{.Store.RunRoot}}' 2>/dev/null || true)
    gr=$(printf '%s' "$gr" | tr -d '\r')
    rr=$(printf '%s' "$rr" | tr -d '\r')
    if [[ -n "$gr" && "$gr" == /* ]] && ! _podman_storage_path_usable_non_root "$gr"; then
        return 0
    fi
    if [[ -n "$rr" && "$rr" == /* ]] && ! _podman_storage_path_usable_non_root "$rr"; then
        return 0
    fi
    return 1
}

# 检测 rootless 存储不可写时：优先 sudo 修正 DEFAULT_PODMAN_GRAPH_ROOT 属主；仍失败则写入 ~/.config/containers/storage.conf。
_fix_rootless_storage_if_unwritable() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
    command -v podman &>/dev/null || return 0

    local needs_fix=0
    if podman info 2>&1 | head -50 | grep -qiE 'runroot.*not writable|graphroot.*not writable|not writable.*(/run/containers|/var/run/containers|/data/containers|/var/lib/containers|libpod)'; then
        needs_fix=1
    fi

    local gr rr
    gr=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)
    rr=$(podman info --format '{{.Store.RunRoot}}' 2>/dev/null || true)
    gr=$(printf '%s' "$gr" | tr -d '\r')
    rr=$(printf '%s' "$rr" | tr -d '\r')

    if [[ -n "$gr" && "$gr" == /* ]]; then
        _podman_storage_path_usable_non_root "$gr" || needs_fix=1
    fi
    if [[ -n "$rr" && "$rr" == /* ]]; then
        _podman_storage_path_usable_non_root "$rr" || needs_fix=1
    fi

    [[ "$needs_fix" -eq 0 ]] && return 0

    # 与脚本预设 GraphRoot（DEFAULT_PODMAN_GRAPH_ROOT）相关时，优先 sudo 将目录归属当前用户及主组
    local try_chown=0
    if [[ -n "$gr" && "$gr" == "${DEFAULT_PODMAN_GRAPH_ROOT}"* ]]; then try_chown=1; fi
    if [[ "$gr" == *'/data/containers'* ]]; then try_chown=1; fi
    if [[ -f /etc/containers/storage.conf ]] && grep -qF "${DEFAULT_PODMAN_GRAPH_ROOT}" /etc/containers/storage.conf 2>/dev/null; then try_chown=1; fi

    if [[ "$try_chown" -eq 1 ]]; then
        _sudo_chown_default_podman_graph_root_for_current_user || true
        if ! _podman_storage_still_needs_user_conf; then
            log "存储路径已可写，无需再写入用户级 storage.conf 覆盖"
            return 0
        fi
    fi

    local g_graph="${XDG_DATA_HOME:-$HOME/.local/share}/containers/storage"
    local g_run="${XDG_RUNTIME_DIR:-/run/user/$(id -u)/containers}"

    mkdir -p "${HOME}/.config/containers" "$g_graph" "$g_run" 2>/dev/null || return 1

    if [[ -f "$user_sc" ]]; then
        cp -a "$user_sc" "${user_sc}.bak.$(date +%s)" 2>/dev/null || true
    fi

    if _write_storage_conf_for_current_user "$user_sc" "$g_graph" "$g_run"; then
        log "已为 rootless 写入 ${user_sc}（graphRoot=${g_graph}, runRoot=${g_run}），避免不可写的系统级存储路径"
    fi
}

# ==========================================
# 6.x 构建代理：开关 + .env / PROXY_* / 脚本常量
# ==========================================
_pm_is_build_proxy_enabled() {
    case "${1:-}" in
        [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]|1) return 0 ;;
        *) return 1 ;;
    esac
}

_pm_compose_proxy_url_from_env() {
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

# 输出三列（tab）：proxy_type  proxy_url  no_proxy
# 仅当 BUILD_PROXY_ENABLED=true 时才拼装/使用 URL
_pm_resolve_build_proxy_vars() {
    local _log="${1:-0}"
    local enabled="" proxy_type="" proxy_url="" no_proxy=""
    local _env_files=()
    [[ -f "$SCRIPT_DIR/.env" ]] && _env_files+=("$SCRIPT_DIR/.env")
    [[ -f "$SCRIPT_DIR/env/base.env" ]] && _env_files+=("$SCRIPT_DIR/env/base.env")

    for _env_f in "${_env_files[@]}"; do
        [[ "$_log" == 1 ]] && info "读取代理配置: $_env_f"
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            value="${value%%#*}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            case "$key" in
                BUILD_PROXY_ENABLED) [[ -z "$enabled" ]] && enabled="$value" ;;
                BUILD_PROXY_TYPE) [[ -z "$proxy_type" ]] && proxy_type="$value" ;;
                BUILD_PROXY_URL)  [[ -z "$proxy_url" ]] && proxy_url="$value" ;;
                NO_PROXY)         [[ -z "$no_proxy" ]] && no_proxy="$value" ;;
            esac
        done < "$_env_f"
    done

    [[ -z "$enabled" && -n "${BUILD_PROXY_ENABLED:-}" ]] && enabled="$BUILD_PROXY_ENABLED"
    [[ -z "$proxy_type" && -n "${BUILD_PROXY_TYPE:-}" ]] && proxy_type="$BUILD_PROXY_TYPE"
    [[ -z "$proxy_url" && -n "${BUILD_PROXY_URL:-}" ]] && proxy_url="$BUILD_PROXY_URL"
    [[ -z "$no_proxy" && -n "${BUILD_NO_PROXY:-}" ]] && no_proxy="$BUILD_NO_PROXY"
    enabled="${enabled:-false}"

    if ! _pm_is_build_proxy_enabled "$enabled"; then
        printf '%s\t%s\t%s' "none" "" "$no_proxy"
        return 0
    fi

    if [[ -z "$proxy_url" ]]; then
        proxy_url="$(_pm_compose_proxy_url_from_env "$proxy_type" 2>/dev/null || true)"
    fi
    if [[ -z "$proxy_url" ]]; then
        [[ "$_log" == 1 ]] && warn "BUILD_PROXY_ENABLED=true 但 PROXY_* / BUILD_PROXY_URL 无效，按直连处理"
        printf '%s\t%s\t%s' "none" "" "$no_proxy"
        return 0
    fi
    if [[ -z "$proxy_type" || "$proxy_type" == "none" ]]; then
        proxy_type="${proxy_url%%://*}"
    fi
    printf '%s\t%s\t%s' "${proxy_type,,}" "$proxy_url" "$no_proxy"
}

# 本会话：为 dnf/curl/podman pull 等导出代理（不覆盖已存在的 HTTP_PROXY）
# 同时自动写入 ~/.config/containers/containers.conf，确保 podman 拉镜像时代理生效
_pm_apply_session_proxy_from_build() {
    local proxy_type proxy_url no_proxy
    IFS=$'\t' read -r proxy_type proxy_url no_proxy <<< "$(_pm_resolve_build_proxy_vars 0)"
    [[ -z "$proxy_url" ]] && return 0
    case "${proxy_type,,}" in
        none|"") return 0 ;;
    esac
    case "${proxy_type,,}" in
        http|https|socks5|socks5h) ;;
        *) return 0 ;;
    esac
    # 无论如何都写入 containers.conf（即使不覆盖已有环境变量）
    _write_containers_conf_proxy "$proxy_url" "$no_proxy" 2>/dev/null || true
    # 已有代理变量时不覆盖
    [[ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}${http_proxy:-}${https_proxy:-}" ]] && return 0
    export HTTP_PROXY="$proxy_url" HTTPS_PROXY="$proxy_url" ALL_PROXY="$proxy_url"
    export NO_PROXY="${no_proxy:-localhost,127.0.0.1,::1}" \
           no_proxy="${no_proxy:-localhost,127.0.0.1,::1}"
    export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY" all_proxy="$ALL_PROXY"
}

# podman 拉取时通过 env 显式注入代理变量：
#   1. 优先使用脚本配置的 BUILD_PROXY_URL（最可靠，sudo 下也有效）
#   2. fallback 到会话环境变量（HTTP_PROXY 等）
# 失败且代理可达时不重试；代理不可达时无代理重试
_pm_podman_registry_proxy_try_then_bypass() {
    local use_capture=0 outf="" errf=""
    if [[ "${1:-}" == "--capture" ]]; then
        use_capture=1
        outf="$2"
        errf="$3"
        shift 3
    fi

    # 优先从脚本配置读取代理（不依赖会话环境变量，应对 sudo 环境）
    local _proxy_url _no_proxy
    local _build_proxy_type _build_proxy_url _build_no_proxy
    IFS=$'\t' read -r _build_proxy_type _build_proxy_url _build_no_proxy <<< "$(_pm_resolve_build_proxy_vars 0)"
    if [[ -n "$_build_proxy_url" && "${_build_proxy_type,,}" != "none" ]]; then
        _proxy_url="$_build_proxy_url"
        _no_proxy="${_build_no_proxy:-localhost,127.0.0.1,::1}"
    else
        # fallback 到会话环境变量
        _proxy_url="${HTTPS_PROXY:-${HTTP_PROXY:-${https_proxy:-${http_proxy:-${ALL_PROXY:-${all_proxy:-}}}}}}}"
        _no_proxy="${NO_PROXY:-${no_proxy:-localhost,127.0.0.1,::1}}"
    fi

    # 有代理：显式注入并执行（env 注入优先级高于 containers.conf）
    if [[ -n "$_proxy_url" ]]; then
        local _env_inject=(env
            HTTP_PROXY="$_proxy_url"  HTTPS_PROXY="$_proxy_url"  ALL_PROXY="$_proxy_url"
            http_proxy="$_proxy_url"  https_proxy="$_proxy_url"  all_proxy="$_proxy_url"
            NO_PROXY="$_no_proxy"     no_proxy="$_no_proxy"
        )
        if [[ "$use_capture" -eq 1 ]]; then
            "${_env_inject[@]}" "$@" >"$outf" 2>"$errf" && return 0
        else
            "${_env_inject[@]}" "$@" &>/dev/null && return 0
        fi
    else
        if [[ "$use_capture" -eq 1 ]]; then
            "$@" >"$outf" 2>"$errf" && return 0
        else
            "$@" &>/dev/null && return 0
        fi
    fi

    # 执行失败，判断是否应该尝试无代理绕过
    if [[ -z "$_proxy_url" ]]; then
        return 1
    fi
    # 从代理 URL 中解析 host:port，探测 TCP 连通性（超时 3 秒）
    local _proxy_host _proxy_port _proxy_reachable=0
    _proxy_host="$(printf '%s' "$_proxy_url" | sed -E 's|^[a-zA-Z0-9+.-]+://([^@]*@)?([^/:]+)(:[0-9]+)?.*|\2|')"
    _proxy_port="$(printf '%s' "$_proxy_url" | sed -E 's|^[a-zA-Z0-9+.-]+://([^@]*@)?([^/:]+):([0-9]+).*|\3|')"
    if [[ -n "$_proxy_host" && -n "$_proxy_port" && "$_proxy_port" =~ ^[0-9]+$ ]]; then
        if (timeout 3 bash -c ">/dev/tcp/${_proxy_host}/${_proxy_port}") 2>/dev/null; then
            _proxy_reachable=1
        fi
    fi
    if [[ "$_proxy_reachable" -eq 1 ]]; then
        # 代理可达但命令失败：不是网络问题，不绕过
        return 1
    fi
    log "（重试）检测到代理 ${_proxy_host}:${_proxy_port} 不可达，已在无代理环境下重试…"
    if [[ "$use_capture" -eq 1 ]]; then
        (
            unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy NO_PROXY no_proxy 2>/dev/null || true
            "$@" >"$outf" 2>"$errf"
        ) && return 0
    else
        (
            unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy NO_PROXY no_proxy 2>/dev/null || true
            "$@" &>/dev/null
        ) && return 0
    fi
    return 1
}

# ==========================================
# 7. 同步代理配置（优先读取 .env，fallback 到 base.env，再 fallback 脚本默认）
# ==========================================
configure_proxy() {
    draw_header
    echo -e "${BOLD}  同步代理配置（.env → base.env → 脚本内 BUILD_PROXY_*）${NC}"
    separator

    local proxy_type="" proxy_url="" no_proxy=""
    IFS=$'\t' read -r proxy_type proxy_url no_proxy <<< "$(_pm_resolve_build_proxy_vars 1)"

    # 构建最终代理 URL
    local effective_proxy=""
    case "${proxy_type,,}" in
        http|https|socks5|socks5h)
            effective_proxy="$proxy_url"
            ;;
        none|"")
            info "BUILD_PROXY_TYPE=none 或未设置有效 URL，代理配置将按「清除/空」处理"
            ;;
    esac

    echo -e "  ${CYAN}检测到代理配置：${NC}"
    echo -e "   类型:      ${GREEN}${proxy_type:-未设置}${NC}"
    echo -e "   代理地址:  ${GREEN}${effective_proxy:-（无）}${NC}"
    echo -e "   NO_PROXY:  ${GREEN}${no_proxy:-（无）}${NC}"
    echo ""

    separator
    echo -e "   1) 写入用户级容器代理配置（~/.config/containers/containers.conf）"
    echo -e "   2) 写入 systemd 服务代理（影响 podman pull 等系统服务）"
    echo -e "   3) 手动输入代理地址"
    echo -e "   4) 清除代理配置"
    echo -e "   0) 返回"
    separator
    echo -ne "  ${BOLD}请选择 [0-4]: ${NC}"
    read -re choice

    case "$choice" in
        1) _write_containers_conf_proxy "$effective_proxy" "$no_proxy" ;;
        2) _write_systemd_proxy "$effective_proxy" "$no_proxy" ;;
        3)
            echo -ne "  输入代理地址（如 socks5://127.0.0.1:1080）: "
            read -re manual_proxy
            echo -ne "  输入 NO_PROXY（如 localhost,127.0.0.1，留空跳过）: "
            read -re manual_no_proxy
            _write_containers_conf_proxy "$manual_proxy" "$manual_no_proxy"
            ;;
        4) _clear_proxy_config ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac

    press_any_key
}

_write_containers_conf_proxy() {
    local proxy="$1"
    local noproxy="${2:-localhost,127.0.0.1}"
    local cfg="$HOME/.config/containers/containers.conf"
    mkdir -p "$(dirname "$cfg")"

    cat > "$cfg" <<EOF
# Podman 容器代理配置 - 由 podman_manager.sh 生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

[engine]
env = [
  "HTTP_PROXY=${proxy}",
  "HTTPS_PROXY=${proxy}",
  "ALL_PROXY=${proxy}",
  "NO_PROXY=${noproxy}",
  "http_proxy=${proxy}",
  "https_proxy=${proxy}",
  "all_proxy=${proxy}",
  "no_proxy=${noproxy}"
]
EOF
    success "已写入容器代理配置: $cfg"
    info "此配置会将代理环境变量注入到所有新启动的容器中"
}

_write_systemd_proxy() {
    local proxy="$1"
    local noproxy="${2:-localhost,127.0.0.1}"
    require_root

    local drop_in_dir="/etc/systemd/system/podman.service.d"
    run_as_root mkdir -p "$drop_in_dir"
    local drop_in_file="$drop_in_dir/proxy.conf"

    run_as_root tee "$drop_in_file" > /dev/null <<EOF
# Podman systemd 代理配置 - 由 podman_manager.sh 生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

[Service]
Environment="HTTP_PROXY=${proxy}"
Environment="HTTPS_PROXY=${proxy}"
Environment="ALL_PROXY=${proxy}"
Environment="NO_PROXY=${noproxy}"
EOF
    run_as_root systemctl daemon-reload
    success "已写入 systemd 代理配置: $drop_in_file"
    info "已执行 systemctl daemon-reload"
}

_clear_proxy_config() {
    local cfg="$HOME/.config/containers/containers.conf"
    if [[ -f "$cfg" ]]; then
        rm -f "$cfg"
        success "已删除 $cfg"
    else
        info "容器代理配置文件不存在，无需清除"
    fi
}

# ==========================================
# 8. 查看系统状态
# ==========================================
show_status() {
    draw_header
    echo -e "${BOLD}  系统状态总览${NC}"
    separator

    if ! is_podman_installed; then
        warn "Podman 未安装"; press_any_key; return
    fi

    echo -e "${CYAN}${BOLD}── Podman 版本信息 ────────────────────────────${NC}"
    _podman_safe version || true

    echo ""
    echo -e "${CYAN}${BOLD}── 系统信息摘要 ───────────────────────────────${NC}"
    # 优先用 --format 输出关键字段；失败时回退到 podman info 截取前 30 行
    # 注意：用 sed 替代 head 避免管道 SIGPIPE（head 提前退出导致上游 125 退出码触发 set -e）
    podman info --format '
OS:         {{.Host.OS}}
Arch:       {{.Host.Arch}}
Kernel:     {{.Host.Kernel}}
GraphRoot:  {{.Store.GraphRoot}}
RunRoot:    {{.Store.RunRoot}}
Driver:     {{.Store.GraphDriverName}}
Rootless:   {{.Host.Security.Rootless}}
' 2>/dev/null || { _podman_safe info 2>/dev/null | sed -n '1,30p' || true; }

    echo ""
    echo -e "${CYAN}${BOLD}── 资源使用 ───────────────────────────────────${NC}"
    _podman_safe system df

    echo ""
    echo -e "${CYAN}${BOLD}── 运行中的容器 ───────────────────────────────${NC}"
    _podman_safe ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}" || true

    press_any_key
}

# ==========================================
# 9. 容器管理
# ==========================================
manage_containers() {
    while true; do
        draw_header
        echo -e "${BOLD}  容器管理${NC}"
        separator

        if ! is_podman_installed; then
            warn "Podman 未安装"; press_any_key; return
        fi

        # 显示当前容器数量
        local running
        running=$(podman ps -q 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | awk '{ print ($1 + 0) }') || true
        local total
        total=$(podman ps -aq 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | awk '{ print ($1 + 0) }') || true
        echo -e "  ${CYAN}运行中: ${GREEN}${running}${NC}  ${CYAN}总计: ${YELLOW}${total}${NC}"
        echo ""

        echo -e "   1) 列出所有容器"
        echo -e "   2) 列出运行中的容器"
        echo -e "   3) 启动容器"
        echo -e "   4) 停止容器"
        echo -e "   5) 重启容器"
        echo -e "   6) 删除容器"
        echo -e "   7) 进入容器（exec）"
        echo -e "   8) 查看容器日志"
        echo -e "   9) 查看容器详情（inspect）"
        echo -e "  10) 停止并删除所有容器"
        echo -e "   0) 返回"
        separator
        echo -ne "  ${BOLD}请选择 [0-10]: ${NC}"
        read -re choice

        case "$choice" in
            1)  echo ""; _podman_safe ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Created}}"; press_any_key ;;
            2)  echo ""; _podman_safe ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"; press_any_key ;;
            3)  _container_action "启动" "start" ;;
            4)  _container_action "停止" "stop" ;;
            5)  _container_action "重启" "restart" ;;
            6)  _container_action "删除" "rm" ;;
            7)
                echo -ne "  输入容器名或 ID: "
                read -re cname
                [[ -z "$cname" ]] && continue
                echo -ne "  输入执行命令（默认 bash）: "
                read -re cmd
                podman exec -it "$cname" "${cmd:-bash}" || true
                press_any_key
                ;;
            8)
                echo -ne "  输入容器名或 ID: "
                read -re cname
                [[ -z "$cname" ]] && continue
                echo -ne "  显示最后 N 行（默认 50）: "
                read -re nlines
                podman logs --tail "${nlines:-50}" -f "$cname" 2>/dev/null || true
                press_any_key
                ;;
            9)
                echo -ne "  输入容器名或 ID: "
                read -re cname
                [[ -z "$cname" ]] && continue
                echo ""
                _podman_safe inspect "$cname" | sed -n '1,80p' || true
                press_any_key
                ;;
            10)
                read -rep "$(echo -e "${RED}确认停止并删除所有容器？[y/N]: ${NC}")" c
                if [[ "${c,,}" == "y" ]]; then
                    podman stop -a 2>/dev/null || true
                    podman rm -a 2>/dev/null || true
                    success "已清理所有容器"
                fi
                press_any_key
                ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

_container_action() {
    local action_name="$1"
    local action_cmd="$2"
    echo ""
    _podman_safe ps -a --format "table {{.Names}}\t{{.Status}}"
    echo ""
    echo -ne "  输入容器名或 ID（多个用空格分隔）: "
    read -re -a targets
    if [[ ${#targets[@]} -eq 0 ]]; then
        warn "未输入容器名，已取消"
    else
        for t in "${targets[@]}"; do
            if podman "$action_cmd" "$t" 2>/dev/null; then
                success "${action_name}成功: $t"
            else
                error "${action_name}失败: $t"
            fi
        done
    fi
    press_any_key
}

# ==========================================
# 10. 镜像管理
# ==========================================
manage_images() {
    while true; do
        draw_header
        echo -e "${BOLD}  镜像管理${NC}"
        separator

        if ! is_podman_installed; then
            warn "Podman 未安装"; press_any_key; return
        fi

        local img_count
        img_count=$(podman images -q 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | awk '{ print ($1 + 0) }') || true
        echo -e "  ${CYAN}本地镜像总数: ${GREEN}${img_count}${NC}"
        echo ""

        echo -e "   1) 列出所有镜像"
        echo -e "   2) 拉取镜像"
        echo -e "   3) 删除镜像"
        echo -e "   4) 搜索镜像"
        echo -e "   5) 查看镜像详情"
        echo -e "   6) 导出镜像（save）"
        echo -e "   7) 导入镜像（load）"
        echo -e "   8) 给镜像打标签（tag）"
        echo -e "   9) 删除所有未使用镜像（prune）"
        echo -e "   0) 返回"
        separator
        echo -ne "  ${BOLD}请选择 [0-9]: ${NC}"
        read -re choice

        case "$choice" in
            1)
                echo ""
                _podman_safe images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.Created}}"
                press_any_key
                ;;
            2)
                echo -ne "  输入镜像名（如 nginx:latest）: "
                read -re img
                [[ -z "$img" ]] && continue
                log "拉取镜像: $img"
                podman pull "$img" && success "拉取成功" || error "拉取失败"
                press_any_key
                ;;
            3)
                echo ""
                _podman_safe images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}"
                echo ""
                echo -ne "  输入镜像名或 ID（多个用空格分隔）: "
                read -re -a imgs
                for img in "${imgs[@]}"; do
                    podman rmi "$img" 2>/dev/null && success "已删除: $img" || error "删除失败: $img"
                done
                press_any_key
                ;;
            4)
                echo -ne "  输入搜索关键词: "
                read -re keyword
                [[ -z "$keyword" ]] && continue
                _podman_safe search "$keyword" --limit 20
                press_any_key
                ;;
            5)
                echo -ne "  输入镜像名或 ID: "
                read -re img
                [[ -z "$img" ]] && continue
                _podman_safe inspect "$img" | sed -n '1,60p' || true
                press_any_key
                ;;
            6)
                echo -ne "  输入镜像名: "
                read -re img
                [[ -z "$img" ]] && continue
                local safe_name="${img//[:\/]/_}"
                local out_file="${safe_name}.tar"
                log "导出 $img 到 $out_file"
                podman save -o "$out_file" "$img" && success "已导出: $out_file" || error "导出失败"
                press_any_key
                ;;
            7)
                echo -ne "  输入 tar 文件路径: "
                read -re tar_file
                [[ -z "$tar_file" || ! -f "$tar_file" ]] && { warn "文件不存在"; press_any_key; continue; }
                podman load -i "$tar_file" && success "导入成功" || error "导入失败"
                press_any_key
                ;;
            8)
                echo -ne "  源镜像名: "
                read -re src
                echo -ne "  新标签: "
                read -re dst
                [[ -z "$src" || -z "$dst" ]] && continue
                podman tag "$src" "$dst" && success "已打标签: $src → $dst" || error "打标签失败"
                press_any_key
                ;;
            9)
                read -rep "$(echo -e "${YELLOW}删除所有未使用镜像（dangling）？[y/N]: ${NC}")" c
                if [[ "${c,,}" == "y" ]]; then
                    podman image prune -f 2>/dev/null && success "清理完成" || warn "清理失败或无可清理镜像"
                fi
                press_any_key
                ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

# ==========================================
# 11. Pod 管理
# ==========================================
manage_pods() {
    while true; do
        draw_header
        echo -e "${BOLD}  Pod 管理${NC}"
        separator

        if ! is_podman_installed; then
            warn "Podman 未安装"; press_any_key; return
        fi

        local pod_count
        pod_count=$(podman pod ls -q 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | awk '{ print ($1 + 0) }') || true
        echo -e "  ${CYAN}Pod 总数: ${GREEN}${pod_count}${NC}"
        echo ""

        echo -e "   1) 列出所有 Pod"
        echo -e "   2) 创建 Pod"
        echo -e "   3) 启动 Pod"
        echo -e "   4) 停止 Pod"
        echo -e "   5) 删除 Pod"
        echo -e "   6) 查看 Pod 详情"
        echo -e "   7) 查看 Pod 统计信息"
        echo -e "   0) 返回"
        separator
        echo -ne "  ${BOLD}请选择 [0-7]: ${NC}"
        read -re choice

        case "$choice" in
            1)
                echo ""
                _podman_safe pod ls --format "table {{.Name}}\t{{.Status}}\t{{.Containers}}\t{{.Created}}" || true
                press_any_key
                ;;
            2)
                echo -ne "  Pod 名称: "
                read -re pod_name
                [[ -z "$pod_name" ]] && continue
                echo -ne "  发布端口（如 8080:80，留空跳过）: "
                read -re pod_port
                local pod_args=(--name "$pod_name")
                [[ -n "$pod_port" ]] && pod_args+=(-p "$pod_port")
                podman pod create "${pod_args[@]}" && success "Pod 已创建: $pod_name" || error "创建失败"
                press_any_key
                ;;
            3|4|5)
                local act_map=([3]="start" [4]="stop" [5]="rm")
                local act_name_map=([3]="启动" [4]="停止" [5]="删除")
                echo ""
                _podman_safe pod ls --format "table {{.Name}}\t{{.Status}}"
                echo ""
                echo -ne "  输入 Pod 名称: "
                read -re pod_name
                [[ -z "$pod_name" ]] && continue
                podman pod "${act_map[$choice]}" "$pod_name" && success "${act_name_map[$choice]}成功: $pod_name" || error "${act_name_map[$choice]}失败"
                press_any_key
                ;;
            6)
                echo -ne "  输入 Pod 名称: "
                read -re pod_name
                [[ -z "$pod_name" ]] && continue
                _podman_safe pod inspect "$pod_name" | sed -n '1,50p' || true
                press_any_key
                ;;
            7)
                _podman_safe pod stats --no-stream || warn "无运行中的 Pod"
                press_any_key
                ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

# ==========================================
# 12. 网络管理
# ==========================================
manage_networks() {
    while true; do
        draw_header
        echo -e "${BOLD}  网络管理${NC}"
        separator

        if ! is_podman_installed; then
            warn "Podman 未安装"; press_any_key; return
        fi

        echo -e "   1) 列出所有网络"
        echo -e "   2) 创建网络"
        echo -e "   3) 删除网络"
        echo -e "   4) 查看网络详情"
        echo -e "   5) 清理未使用网络"
        echo -e "   0) 返回"
        separator
        echo -ne "  ${BOLD}请选择 [0-5]: ${NC}"
        read -re choice

        case "$choice" in
            1)
                echo ""
                _podman_safe network ls --format "table {{.Name}}\t{{.Driver}}\t{{.Options}}" || true
                press_any_key
                ;;
            2)
                echo -ne "  网络名称: "
                read -re net_name
                [[ -z "$net_name" ]] && continue
                echo -ne "  子网（如 192.168.100.0/24，留空跳过）: "
                read -re subnet
                local net_args=(--name "$net_name")
                [[ -n "$subnet" ]] && net_args+=(--subnet "$subnet")
                podman network create "${net_args[@]}" && success "网络已创建: $net_name" || error "创建失败"
                press_any_key
                ;;
            3)
                echo ""
                _podman_safe network ls
                echo ""
                echo -ne "  输入网络名称: "
                read -re net_name
                [[ -z "$net_name" ]] && continue
                podman network rm "$net_name" && success "已删除: $net_name" || error "删除失败"
                press_any_key
                ;;
            4)
                echo -ne "  输入网络名称: "
                read -re net_name
                [[ -z "$net_name" ]] && continue
                _podman_safe network inspect "$net_name" || true
                press_any_key
                ;;
            5)
                read -rep "$(echo -e "${YELLOW}清理所有未使用网络？[y/N]: ${NC}")" c
                if [[ "${c,,}" == "y" ]]; then
                    podman network prune -f 2>/dev/null && success "清理完成" || warn "网络 prune 未完成或无需清理"
                fi
                press_any_key
                ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

# ==========================================
# 13. 卷管理
# ==========================================
manage_volumes() {
    while true; do
        draw_header
        echo -e "${BOLD}  卷管理${NC}"
        separator

        if ! is_podman_installed; then
            warn "Podman 未安装"; press_any_key; return
        fi

        local vol_count
        vol_count=$(podman volume ls -q 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | awk '{ print ($1 + 0) }') || true
        echo -e "  ${CYAN}卷总数: ${GREEN}${vol_count}${NC}"
        echo ""

        echo -e "   1) 列出所有卷"
        echo -e "   2) 创建卷"
        echo -e "   3) 删除卷"
        echo -e "   4) 查看卷详情"
        echo -e "   5) 清理未使用卷"
        echo -e "   0) 返回"
        separator
        echo -ne "  ${BOLD}请选择 [0-5]: ${NC}"
        read -re choice

        case "$choice" in
            1)
                echo ""
                _podman_safe volume ls --format "table {{.Name}}\t{{.Driver}}\t{{.Mountpoint}}" || true
                press_any_key
                ;;
            2)
                echo -ne "  卷名称: "
                read -re vol_name
                [[ -z "$vol_name" ]] && continue
                podman volume create "$vol_name" && success "卷已创建: $vol_name" || error "创建失败"
                press_any_key
                ;;
            3)
                echo ""
                _podman_safe volume ls 2>/dev/null
                echo ""
                echo -ne "  输入卷名称（多个用空格分隔）: "
                read -re -a vols
                for vol in "${vols[@]}"; do
                    podman volume rm "$vol" 2>/dev/null && success "已删除: $vol" || error "删除失败: $vol"
                done
                press_any_key
                ;;
            4)
                echo -ne "  输入卷名称: "
                read -re vol_name
                [[ -z "$vol_name" ]] && continue
                _podman_safe volume inspect "$vol_name" || true
                press_any_key
                ;;
            5)
                read -rep "$(echo -e "${YELLOW}清理所有未挂载的卷？[y/N]: ${NC}")" c
                if [[ "${c,,}" == "y" ]]; then
                    podman volume prune -f 2>/dev/null && success "清理完成" || warn "卷 prune 未完成或无需清理"
                fi
                press_any_key
                ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
    done
}

# ==========================================
# 14. 系统清理
# ==========================================
system_cleanup() {
    draw_header
    echo -e "${BOLD}  系统清理${NC}"
    separator

    if ! is_podman_installed; then
        warn "Podman 未安装"; press_any_key; return
    fi

    echo -e "${CYAN}${BOLD}── 当前资源占用 ──────────────────────────────${NC}"
    _podman_safe system df

    echo ""
    separator
    echo -e "   1) 清理停止的容器"
    echo -e "   2) 清理未使用的镜像（dangling + 构建缓存）"
    echo -e "   3) 清理未使用的卷"
    echo -e "   4) 清理未使用的网络"
    echo -e "   5) ${RED}${BOLD}全量清理${NC}（容器 + 镜像 + 卷 + 网络 + 构建缓存，谨慎操作）"
    echo -e "   6) 清理构建缓存（buildah/build 临时数据）"
    echo -e "   0) 返回"
    separator
    echo -ne "  ${BOLD}请选择 [0-6]: ${NC}"
    read -re choice

    case "$choice" in
        1)
            podman container prune -f && success "已清理停止的容器"
            ;;
        2)
            # --build-cache 清理 buildah/multi-stage 构建残留
            # --external 清理被外部构建容器引用的镜像
            # -a 清理所有未使用镜像（不仅仅是 dangling）
            log "清理未使用镜像（含构建缓存和外部引用）..."
            podman image prune -af --build-cache --external 2>/dev/null                 && success "已彻底清理未使用镜像"                 || warn "部分镜像清理失败，可尝试全量清理（选项 5）"
            ;;
        3)
            podman volume prune -f && success "已清理未使用卷"
            ;;
        4)
            podman network prune -f && success "已清理未使用网络"
            ;;
        5)
            echo ""
            echo -e "${RED}${BOLD}  ⚠️  警告：此操作将清理所有未运行容器、未使用镜像（含构建缓存和外部引用）、卷和网络！${NC}"
            echo -e "  ${YELLOW}包括: buildah 构建容器、multi-stage 中间层、external store 引用${NC}"
            read -rep "$(echo -e "${RED}请输入 'clean all' 确认: ${NC}")" confirm
            if [[ "$confirm" == "clean all" ]]; then
                log "执行全量清理（含构建缓存和外部数据）..."
                # --all: 所有未使用数据
                # --force: 不提示确认
                # --volumes: 包含未使用的卷
                # --build: 清理构建容器（buildah/multi-stage 残留）
                # --external: 清理外部引用数据
                # 须放在 if 内：set -E 下单独 podman 返回 125 会触发 ERR，且 set -e 时不会执行到下一行的 _prune_rc=$?
                local _prune_rc=0
                if ! podman system prune -af --volumes --build --external 2>/dev/null; then
                    _prune_rc=$?
                fi
                if [[ $_prune_rc -eq 0 ]]; then
                    success "全量清理完成"
                else
                    # 部分 failure 常见原因是某些 image 被 podman-compose 的临时 pod 引用
                    # 再次尝试不带 --external（部分版本对 --external 支持有限）
                    warn "完整清理未完全成功，尝试降级清理（跳过 external）..."
                    if podman system prune -af --volumes --build 2>/dev/null; then
                        success "降级清理完成"
                    else
                        warn "清理未完全成功，请手动检查"
                    fi
                fi
                echo ""
                echo -e "${CYAN}清理后资源占用：${NC}"
                _podman_safe system df
                # 额外清理：显式删除所有 <none>:<none> 标签的镜像
                local _dangling
                _dangling=$(podman images -f "dangling=true" -q 2>/dev/null) || true
                if [[ -n "$_dangling" ]]; then
                    log "发现残余 dangling 镜像，强制删除..."
                    echo "$_dangling" | xargs -r podman rmi -f 2>/dev/null || true
                    success "已强制删除残余 dangling 镜像"
                fi
            else
                info "已取消"
            fi
            ;;
        6)
            # 专门清理构建缓存
            log "清理构建缓存（buildah containers + build cache）..."
            # 删除 buildah 构建容器
            if command -v buildah >/dev/null 2>&1; then
                buildah containers --all -q 2>/dev/null | xargs -r buildah rm 2>/dev/null || true
            fi
            # 使用 podman image prune --build-cache 清理持久化构建缓存
            podman image prune -f --build-cache 2>/dev/null                 && success "构建缓存清理完成"                 || info "无构建缓存可清理"
            ;;
        0) press_any_key; return ;;
        *) warn "无效选项" ;;
    esac

    press_any_key
}

# ==========================================
# 15-a. SHM Lock 自动检测与修复
# ==========================================
# 背景：Podman 使用 /dev/shm/libpod_rootless_lock_<UID> 管理锁槽。
# 当 Podman 大版本升级后，lock 文件格式（每个 slot 字节数）可能发生变化，
# 旧文件中的槽位仍被标记为占用，导致每次执行 podman 命令都输出大量
# "Refreshing volume xxx: acquiring lock N for volume xxx: file exists" 错误。
# 修复方案：podman system renumber 重建 SHM lock 文件，对数据无任何影响。
# ------------------------------------------------------------------
# fix_shm_lock [--quiet]
#   --quiet : 静默模式，无 ERRO 时不打印任何内容，仅在修复时输出提示
# ------------------------------------------------------------------
fix_shm_lock() {
    local quiet=false
    [[ "${1:-}" == "--quiet" ]] && quiet=true

    # Podman 未安装则跳过
    if ! is_podman_installed; then
        $quiet || warn "Podman 未安装，跳过 SHM lock 检查"
        return 0
    fi

    # 仅 Rootless 模式下才有 /dev/shm/libpod_rootless_lock_<UID>
    local uid
    uid=$(id -u)
    local lock_file="/dev/shm/libpod_rootless_lock_${uid}"

    if [[ ! -f "$lock_file" ]]; then
        $quiet || info "SHM lock 文件不存在，无需修复: $lock_file"
        return 0
    fi

    # ---- 检测是否存在 ERRO 输出 ----
    # 用 podman volume ls（最轻量的命令）捕获 stderr，判断是否含有 lock 报错
    local err_output
    err_output=$(podman volume ls 2>&1 >/dev/null || true)

    if echo "$err_output" | grep -q "acquiring lock.*file exists"; then
        warn "🔒 检测到 SHM lock 槽位冲突（Podman 版本升级后遗留），正在自动修复..."
        if podman system renumber 2>/dev/null; then
            success "✅ SHM lock 修复完成（podman system renumber 已执行）"
            # 验证修复结果
            local verify_err
            verify_err=$(podman volume ls 2>&1 >/dev/null || true)
            if echo "$verify_err" | grep -q "acquiring lock.*file exists"; then
                error "❌ 修复后仍存在 lock 冲突，请手动执行: podman system renumber"
                return 1
            fi
        else
            error "❌ podman system renumber 执行失败，请手动运行: podman system renumber"
            return 1
        fi
    else
        $quiet || info "🔒 SHM lock 状态正常，无需修复"
    fi

    return 0
}

# ==========================================
# 15. 运行诊断检查
# ==========================================
run_diagnostics() {
    draw_header
    echo -e "${BOLD}  诊断检查${NC}"
    separator

    local pass=0 fail=0 warn_count=0

    _check() {
        local label="$1"
        local result="$2"   # ok / warn / fail
        local detail="${3:-}"
        case "$result" in
            ok)
                echo -e "  ${GREEN}✅ ${label}${NC}${detail:+  $detail}"
                # set -e：(( x++ )) 在 x=0 时结果为 0 → 退出码 1；改用 ++x
                (( ++pass ))
                ;;
            warn)
                echo -e "  ${YELLOW}⚠️  ${label}${NC}${detail:+  $detail}"
                (( ++warn_count ))
                ;;
            fail)
                echo -e "  ${RED}❌ ${label}${NC}${detail:+  $detail}"
                (( ++fail ))
                ;;
        esac
    }

    echo -e "${CYAN}${BOLD}── 基础检查 ────────────────────────────────────${NC}"

    # Podman 安装
    if is_podman_installed; then
        _check "Podman 已安装" ok "（$(get_podman_version)）"
    else
        _check "Podman 未安装" fail
    fi

    # 附加组件
    is_pkg_installed "$PKG_COMPOSE" && _check "podman-compose 已安装" ok || _check "podman-compose 未安装" warn "可选组件"
    is_pkg_installed "$PKG_BUILDAH" && _check "buildah 已安装" ok       || _check "buildah 未安装" warn "可选组件"
    is_pkg_installed "$PKG_SKOPEO"  && _check "skopeo 已安装" ok        || _check "skopeo 未安装" warn "可选组件"

    echo ""
    echo -e "${CYAN}${BOLD}── 运行时检查 ──────────────────────────────────${NC}"

    if is_podman_installed; then
        # Rootless 检查
        if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q "true"; then
            _check "Rootless 模式" ok
        else
            _check "以 root 身份运行" warn "建议使用 Rootless 模式"
        fi

        # subuid/subgid
        local user="${USER:-$(id -un)}"
        grep -q "^${user}:" /etc/subuid 2>/dev/null \
            && _check "/etc/subuid 已配置" ok \
            || _check "/etc/subuid 未配置" warn "Rootless 模式需要此配置"

        # 存储驱动
        local driver
        driver=$(podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || echo "unknown")
        case "$driver" in
            overlay) _check "存储驱动: overlay" ok ;;
            vfs)     _check "存储驱动: vfs" warn "vfs 性能较差，建议切换到 overlay" ;;
            *)       _check "存储驱动: $driver" warn ;;
        esac

        # 测试运行
        if _pm_podman_registry_proxy_try_then_bypass podman run --rm --quiet alpine:latest echo "ok"; then
            _check "测试容器运行" ok
        else
            _check "测试容器运行失败" fail "podman run --rm alpine echo ok 失败（若代理不可达，脚本已自动在无代理环境下重试；若代理可达则拉取失败另有原因，请检查镜像源或代理可用性）"
        fi
    fi

    echo ""
    echo -e "${CYAN}${BOLD}── 网络检查 ────────────────────────────────────${NC}"

    # 解析当前代理（优先 BUILD_PROXY_URL，其次会话环境变量）
    local _diag_proxy=""
    if [[ -n "${BUILD_PROXY_URL:-}" ]]; then
        _diag_proxy="$BUILD_PROXY_URL"
    elif [[ -n "${HTTPS_PROXY:-}" ]]; then
        _diag_proxy="$HTTPS_PROXY"
    elif [[ -n "${HTTP_PROXY:-}" ]]; then
        _diag_proxy="$HTTP_PROXY"
    fi

    for host in "docker.io" "registry.cn-hangzhou.aliyuncs.com" "mirrors.tuna.tsinghua.edu.cn"; do
        # 先尝试直连
        if curl -s --connect-timeout 5 --max-time 8 -o /dev/null "https://${host}" 2>/dev/null; then
            _check "可达: $host" ok "直连"
        elif [[ -n "$_diag_proxy" ]] && curl -s --connect-timeout 8 --max-time 12 \
                --proxy "$_diag_proxy" -o /dev/null "https://${host}" 2>/dev/null; then
            # 直连不通但代理可达 —— 对 podman 拉镜像没有影响（脚本会通过代理拉取）
            _check "可达: $host" ok "经代理 $(echo "$_diag_proxy" | sed 's|.*@||')"
        else
            if [[ -n "$_diag_proxy" ]]; then
                _check "不可达: $host" warn "直连与代理均不可达，请检查代理配置或网络"
            else
                _check "不可达: $host" warn "直连不可达且未配置代理"
            fi
        fi
    done

    echo ""
    echo -e "${CYAN}${BOLD}── 配置文件检查 ────────────────────────────────${NC}"

    local cfg_files=(
        "$HOME/.config/containers/registries.conf:镜像加速配置"
        "$HOME/.config/containers/containers.conf:容器代理配置"
        "$HOME/.config/containers/storage.conf:存储路径配置"
    )
    for entry in "${cfg_files[@]}"; do
        local f="${entry%%:*}"
        local desc="${entry#*:}"
        [[ -f "$f" ]] \
            && _check "$desc 已配置" ok "($f)" \
            || _check "$desc 未配置" warn "（可选）"
    done

    echo ""
    echo -e "${CYAN}${BOLD}── SHM Lock 检查 ───────────────────────────────${NC}"

    local uid
    uid=$(id -u)
    local lock_file="/dev/shm/libpod_rootless_lock_${uid}"
    if [[ ! -f "$lock_file" ]]; then
        _check "SHM lock 文件" warn "不存在: $lock_file（首次运行 podman 后自动创建）"
    else
        local lock_err
        lock_err=$(podman volume ls 2>&1 >/dev/null || true)
        if echo "$lock_err" | grep -q "acquiring lock.*file exists"; then
            _check "SHM lock 槽位" fail "存在冲突（Podman 版本升级后遗留），建议执行: podman system renumber"
            echo ""
            read -rep "$(echo -e "  ${YELLOW}是否立即自动修复？[y/N]: ${NC}")" _fix_choice
            if [[ "${_fix_choice,,}" == "y" ]]; then
                fix_shm_lock
            fi
        else
            _check "SHM lock 槽位" ok "($lock_file)"
        fi
    fi

    echo ""
    separator
    echo -e "  ${BOLD}诊断结果: ${GREEN}通过 ${pass}${NC}  ${YELLOW}警告 ${warn_count}${NC}  ${RED}失败 ${fail}${NC}"
    separator

    press_any_key
}

# ==========================================
# 16. Docker → Podman 一键迁移
# ==========================================

# ---- 迁移：内部工具函数 ----

# 格式化文件大小
_fmt_size() {
    local bytes="$1"
    if   (( bytes >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; $bytes/1073741824" | bc)"
    elif (( bytes >= 1048576   )); then printf "%.1f MB" "$(echo "scale=1; $bytes/1048576"   | bc)"
    elif (( bytes >= 1024      )); then printf "%.1f KB" "$(echo "scale=1; $bytes/1024"      | bc)"
    else echo "${bytes} B"; fi
}

# 检测 docker 是否已安装且 daemon 可用
_docker_available() {
    command -v docker &>/dev/null && docker info &>/dev/null 2>&1
}

# 获取 docker root dir（默认 /var/lib/docker）
_docker_root() {
    docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker"
}

# 获取 docker 镜像列表  格式: repo:tag
_docker_image_list() {
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' || true
}

# 报告文件路径
_migration_report_file() {
    echo "/tmp/docker2podman_migration_$(date '+%Y%m%d_%H%M%S').log"
}

# 迁移状态文件路径（固定，方便重复执行时读取）
MIGRATION_STATE_FILE="/tmp/.docker2podman_state"

# 标记某个步骤已完成
_migrate_mark_done() {
    local step="$1"
    echo "${step}=done" >> "$MIGRATION_STATE_FILE"
}

# 判断某个步骤是否已完成
_migrate_is_done() {
    local step="$1"
    [[ -f "$MIGRATION_STATE_FILE" ]] && grep -q "^${step}=done" "$MIGRATION_STATE_FILE" 2>/dev/null
}

# 保存一个键値到状态文件
_migrate_save_val() {
    local key="$1" val="$2"
    # 先删除旧行再写入
    [[ -f "$MIGRATION_STATE_FILE" ]] && sed -i "/^${key}=/d" "$MIGRATION_STATE_FILE" 2>/dev/null || true
    echo "${key}=${val}" >> "$MIGRATION_STATE_FILE"
}

# 从状态文件读取一个键値
_migrate_load_val() {
    local key="$1" default="${2:-}"
    if [[ -f "$MIGRATION_STATE_FILE" ]]; then
        local v
        v=$(grep "^${key}=" "$MIGRATION_STATE_FILE" 2>/dev/null | tail -1 | cut -d'=' -f2-)
        echo "${v:-$default}"
    else
        echo "$default"
    fi
}

# ---- 迁移步骤函数 ----

# 步骤 1：探测 Docker 环境
_migrate_step1_detect() {
    info "[1/6] 探测 Docker 环境..."

    if ! command -v docker &>/dev/null; then
        error "未找到 docker 命令，无法迁移"
        return 1
    fi

    DOCKER_VERSION=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    DOCKER_ROOT=$(_docker_root)
    DOCKER_RUNNING=false

    if docker info &>/dev/null 2>&1; then
        DOCKER_RUNNING=true
        DOCKER_IMAGES=$(docker images -q 2>/dev/null | wc -l)
        DOCKER_CONTAINERS=$(docker ps -aq 2>/dev/null | wc -l)
        DOCKER_VOLUMES=$(docker volume ls -q 2>/dev/null | wc -l)
        DOCKER_NETWORKS=$(docker network ls -q 2>/dev/null | wc -l)
    else
        warn "Docker daemon 未运行，将跳过镜像/容器迁移"
        DOCKER_IMAGES=0
        DOCKER_CONTAINERS=0
        DOCKER_VOLUMES=0
        DOCKER_NETWORKS=0
    fi

    echo ""
    echo -e "  ${BOLD}Docker 环境概览${NC}"
    echo -e "  版本        : $DOCKER_VERSION"
    echo -e "  根目录      : $DOCKER_ROOT"
    echo -e "  Daemon 状态 : $( $DOCKER_RUNNING && echo '运行中' || echo '未运行' )"
    echo -e "  镜像数量    : $DOCKER_IMAGES"
    echo -e "  容器数量    : $DOCKER_CONTAINERS"
    echo -e "  数据卷数量  : $DOCKER_VOLUMES"
    echo -e "  网络数量    : $DOCKER_NETWORKS"
    echo ""

    return 0
}

# 步骤 2：备份 Docker 镜像（使用 docker save → tar）
_migrate_step2_backup_images() {
    info "[2/6] 备份 Docker 镜像..."

    if ! $DOCKER_RUNNING || [[ "$DOCKER_IMAGES" -eq 0 ]]; then
        warn "无可备份的镜像，跳过"
        BACKUP_DIR=""
        IMAGE_LIST=()
        _migrate_mark_done "step2"
        return 0
    fi

    BACKUP_DIR="/data/docker_migration_backup_$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "$BACKUP_DIR"
    info "备份目录: $BACKUP_DIR"
    # 持久化备份目录，以便重跑时读取
    _migrate_save_val "BACKUP_DIR" "$BACKUP_DIR"

    # 获取镜像列表
    mapfile -t IMAGE_LIST < <(_docker_image_list)
    # 持久化镜像列表（换行符 → 空格分隔）
    _migrate_save_val "IMAGE_LIST" "$(IFS=' '; echo "${IMAGE_LIST[*]}")"

    local total=${#IMAGE_LIST[@]}
    local idx=0
    local ok=0
    local fail=0

    MIGRATION_SUMMARY_IMAGES=()

    for img in "${IMAGE_LIST[@]}"; do
        (( idx++ )) || true
        local safe_name
        safe_name=$(echo "$img" | tr '/:' '__')
        local tar_path="$BACKUP_DIR/${safe_name}.tar"

        echo -ne "  [${idx}/${total}] 保存 ${CYAN}${img}${NC} ... "
        if docker save -o "$tar_path" "$img" 2>/dev/null; then
            local sz
            sz=$(_fmt_size "$(stat -c%s "$tar_path" 2>/dev/null || echo 0)")
            echo -e "${GREEN}OK${NC} (${sz})"
            MIGRATION_SUMMARY_IMAGES+=("OK|$img|$tar_path")
            (( ok++ )) || true
        else
            echo -e "${RED}FAIL${NC}"
            MIGRATION_SUMMARY_IMAGES+=("FAIL|$img|")
            (( fail++ )) || true
        fi
    done

    echo ""
    success "镜像备份完成：成功 ${ok}，失败 ${fail}"
    BACKUP_IMAGES_OK=$ok
    BACKUP_IMAGES_FAIL=$fail
    _migrate_save_val "BACKUP_IMAGES_OK" "$ok"
    _migrate_save_val "BACKUP_IMAGES_FAIL" "$fail"
    _migrate_mark_done "step2"
    return 0
}

# 步骤 3：将备份镜像导入 Podman
_migrate_step3_import_to_podman() {
    info "[3/6] 将备份镜像导入 Podman..."

    # 如果内存中无备份目录，尝试从状态文件恢复
    if [[ -z "${BACKUP_DIR:-}" ]]; then
        BACKUP_DIR=$(_migrate_load_val "BACKUP_DIR" "")
    fi
    if [[ ${#IMAGE_LIST[@]} -eq 0 ]]; then
        local saved_list
        saved_list=$(_migrate_load_val "IMAGE_LIST" "")
        if [[ -n "$saved_list" ]]; then
            read -ra IMAGE_LIST <<< "$saved_list"
        fi
    fi

    if [[ -z "${BACKUP_DIR:-}" ]] || [[ ${#IMAGE_LIST[@]} -eq 0 ]]; then
        warn "无备份镜像信息，跳过导入"
        IMPORT_IMAGES_OK=0
        IMPORT_IMAGES_FAIL=0
        _migrate_mark_done "step3"
        return 0
    fi

    if [[ ! -d "$BACKUP_DIR" ]]; then
        error "备份目录不存在: $BACKUP_DIR"
        IMPORT_IMAGES_OK=0
        IMPORT_IMAGES_FAIL=0
        return 1
    fi

    if ! command -v podman &>/dev/null; then
        warn "Podman 尚未安装，稍后安装完毕后将自动导入"
        NEED_DEFERRED_IMPORT=true
        IMPORT_IMAGES_OK=0
        IMPORT_IMAGES_FAIL=0
        return 0
    fi

    # 检查 storage.conf 可读性
    if [[ -f /etc/containers/storage.conf ]] && ! [[ -r /etc/containers/storage.conf ]]; then
        warn "storage.conf 权限不足，尝试修复..."
        chmod 644 /etc/containers/storage.conf 2>/dev/null || \
            run_as_root chmod 644 /etc/containers/storage.conf 2>/dev/null || true
    fi

    NEED_DEFERRED_IMPORT=false
    local ok=0
    local fail=0
    local idx=0
    local total=${#IMAGE_LIST[@]}

    for img in "${IMAGE_LIST[@]}"; do
        (( idx++ )) || true
        local safe_name
        safe_name=$(echo "$img" | tr '/:' '__')
        local tar_path="$BACKUP_DIR/${safe_name}.tar"

        echo -ne "  [${idx}/${total}] 导入 ${CYAN}${img}${NC} ... "
        if [[ ! -f "$tar_path" ]]; then
            echo -e "${RED}FAIL${NC} (备份文件不存在: $tar_path)"
            (( fail++ )) || true
            continue
        fi
        local err_out _load_rc
        set +e
        err_out=$(podman load -i "$tar_path" 2>&1)
        _load_rc=$?
        set -e
        if [[ $_load_rc -eq 0 ]]; then
            echo -e "${GREEN}OK${NC}"
            (( ok++ )) || true
        else
            echo -e "${RED}FAIL${NC}"
            echo -e "    ${YELLOW}${err_out}${NC}"
            (( fail++ )) || true
        fi
    done

    echo ""
    success "镜像导入完成：成功 ${ok}，失败 ${fail}"
    IMPORT_IMAGES_OK=$ok
    IMPORT_IMAGES_FAIL=$fail
    _migrate_save_val "IMPORT_IMAGES_OK" "$ok"
    _migrate_save_val "IMPORT_IMAGES_FAIL" "$fail"
    _migrate_mark_done "step3"
    return 0
}

# 步骤 4：卸载 Docker
_migrate_step4_uninstall_docker() {
    info "[4/6] 卸载 Docker..."
    require_root
    detect_pkg_manager

    # 停止并禁用 docker 服务
    for svc in docker docker.socket containerd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "停止服务: $svc"
            run_as_root systemctl stop "$svc" 2>/dev/null || true
        fi
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            run_as_root systemctl disable "$svc" 2>/dev/null || true
        fi
    done

    # 构建卸载包列表（兼容各发行版命名）
    local docker_pkgs=()
    local candidate_pkgs=(
        docker docker-ce docker-ce-cli containerd containerd.io
        docker-engine docker.io docker-compose docker-compose-plugin
        docker-buildx-plugin docker-scan-plugin
        docker-ce-rootless-extras
    )

    for pkg in "${candidate_pkgs[@]}"; do
        if [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
            rpm -q "$pkg" &>/dev/null && docker_pkgs+=("$pkg")
        else
            dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" && docker_pkgs+=("$pkg")
        fi
    done

    if [[ ${#docker_pkgs[@]} -eq 0 ]]; then
        warn "未检测到已安装的 Docker 软件包，跳过卸载"
    else
        log "卸载软件包: ${docker_pkgs[*]}"
        if [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
            run_as_root $PKG_MGR remove -y "${docker_pkgs[@]}" 2>/dev/null || true
        else
            run_as_root apt-get remove -y --purge "${docker_pkgs[@]}" 2>/dev/null || true
            run_as_root apt-get autoremove -y 2>/dev/null || true
        fi
        success "Docker 软件包已卸载"
    fi

    # 清理 Docker 配置与数据目录
    info "清理 Docker 配置文件与运行时目录..."

    # 先处理 netns 挂载点：/var/run/docker/netns/* 和 /run/docker/netns/*
    # 这些是被内核持有的 network namespace，必须先 umount 才能删除
    for netns_dir in /var/run/docker/netns /run/docker/netns; do
        if [[ -d "$netns_dir" ]]; then
            log "卡载网络命名空间挂载点: $netns_dir"
            # 逐一 umount 该目录下所有挂载点
            while IFS= read -r mnt; do
                run_as_root umount "$mnt" 2>/dev/null && log "  umount: $mnt" || warn "  umount 失败（已跳过）: $mnt"
            done < <(run_as_root findmnt -rn -o TARGET "$netns_dir" 2>/dev/null | sort -r || true)
            # 备用：直接读 /proc/mounts 中匹配项
            if [[ -n "$(ls -A "$netns_dir" 2>/dev/null)" ]]; then
                while IFS= read -r mnt; do
                    run_as_root umount "$mnt" 2>/dev/null || true
                done < <(grep " ${netns_dir}" /proc/mounts 2>/dev/null | awk '{print $2}' | sort -r || true)
            fi
        fi
    done

    local docker_dirs=(
        /etc/docker
        /var/run/docker.sock
        /var/run/docker
        /run/docker.sock
        /run/docker
        "$HOME/.docker"
    )
    for d in "${docker_dirs[@]}"; do
        if [[ -e "$d" ]]; then
            run_as_root rm -rf "$d" 2>/dev/null \
                && log "已删除: $d" \
                || warn "删除失败（可能仍有挂载）: $d"
        fi
    done

    # 询问是否删除 docker 数据目录（/var/lib/docker）
    echo ""
    warn "Docker 数据目录 ${DOCKER_ROOT} 包含所有镜像/容器数据（已备份）"
    read -rep "$(echo -e "${YELLOW}是否删除该目录以彻底清理？[Y/n]: ${NC}")" del_data
    if [[ "${del_data,,}" != "n" ]]; then
        run_as_root rm -rf "$DOCKER_ROOT" 2>/dev/null || true
        success "Docker 数据目录已删除: $DOCKER_ROOT"
        DOCKER_DATA_DELETED=true
    else
        info "保留 Docker 数据目录（手动清理时可删除 $DOCKER_ROOT）"
        DOCKER_DATA_DELETED=false
    fi

    # 清理 Docker 相关 yum/apt repo 文件
    local repo_files=(
        /etc/yum.repos.d/docker-ce.repo
        /etc/yum.repos.d/docker*.repo
        /etc/apt/sources.list.d/docker*.list
        /etc/apt/keyrings/docker*.gpg
        /etc/apt/trusted.gpg.d/docker*.gpg
    )
    for rf in "${repo_files[@]}"; do
        # 展开 glob
        for f in $rf; do
            [[ -e "$f" ]] && run_as_root rm -f "$f" && log "已删除仓库文件: $f"
        done
    done

    # 清理 /usr/local/bin 中可能残留的 docker 二进制
    for bin in docker docker-compose docker-containerd docker-runc; do
        local bp="/usr/local/bin/$bin"
        [[ -e "$bp" ]] && run_as_root rm -f "$bp" && log "已删除: $bp"
    done

    success "Docker 卸载清理完成"
    _migrate_save_val "DOCKER_DATA_DELETED" "$DOCKER_DATA_DELETED"
    _migrate_mark_done "step4"
    return 0
}

# 步骤 5：安装并配置 Podman（含路径对齐）
_migrate_step5_install_podman() {
    info "[5/6] 安装并配置 Podman..."

    require_root
    detect_pkg_manager

    if ! is_podman_installed; then
        log "安装 Podman..."

        # 国内环境：尝试配置国内源（仅 RHEL/CentOS/AlmaLinux 系列）
        if [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
            # Podman 在 RHEL 系默认随 AppStream 提供，无需额外 repo
            run_as_root $PKG_MGR makecache -q 2>/dev/null || true
        else
            run_as_root apt-get update -q 2>/dev/null || true
        fi

        if install_pkg_if_missing "podman" "Podman"; then
            success "Podman 已安装（版本 $(get_podman_version)）"
            ensure_fuse_overlayfs_installed
        else
            error "Podman 安装失败，请检查网络或软件源"
            return 1
        fi
    else
        info "Podman 已安装（版本 $(get_podman_version)），跳过安装"
    fi

    # 确保 Podman overlay 兼容组件已安装（Podman 已存在时也检查一次）
    ensure_fuse_overlayfs_installed

    # 安装 skopeo（辅助镜像操作）
    if ! command -v skopeo &>/dev/null; then
        log "安装 skopeo..."
        run_as_root $PKG_MGR install -y skopeo 2>/dev/null || warn "skopeo 安装失败（非必须）"
    fi

    # ---- 配置镜像加速（国内源）----
    info "配置国内镜像加速源..."
    local reg_conf="/etc/containers/registries.conf"
    run_as_root mkdir -p /etc/containers

    # 检测是否已有配置
    if [[ ! -f "$reg_conf" ]] || ! grep -q 'mirrors' "$reg_conf" 2>/dev/null; then
        run_as_root tee "$reg_conf" > /dev/null <<'REGEOF'
unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "docker.io"
location = "docker.io"

  [[registry.mirror]]
  location = "registry.cn-hangzhou.aliyuncs.com"

  [[registry.mirror]]
  location = "mirror.ccs.tencentyun.com"

  [[registry.mirror]]
  location = "docker.mirrors.ustc.edu.cn"
REGEOF
        success "已配置国内镜像加速源 → $reg_conf"
    else
        info "registries.conf 已存在，跳过覆盖"
    fi

    # ---- 存储路径对齐（与 Docker 保持一致 / 使用项目默认路径）----
    # 迁移时应用项目默认路径：GraphRoot=${DEFAULT_PODMAN_GRAPH_ROOT}  RunRoot=${DEFAULT_PODMAN_RUN_ROOT}
    local target_graph_root="$DEFAULT_PODMAN_GRAPH_ROOT"
    local target_run_root="$DEFAULT_PODMAN_RUN_ROOT"

    echo ""
    echo -e "  ${CYAN}存储路径配置（可直接回车使用默认値）：${NC}"
    echo -ne "  GraphRoot（镜像/容器存储） [默认: ${target_graph_root}]: "
    read -re user_graph
    [[ -n "$user_graph" ]] && target_graph_root="$user_graph"

    echo -ne "  RunRoot（运行时数据）       [默认: ${target_run_root}]: "
    read -re user_run
    [[ -n "$user_run" ]] && target_run_root="$user_run"

    info "存储路径确认： GraphRoot=$target_graph_root  RunRoot=$target_run_root"

    local storage_conf="/etc/containers/storage.conf"
    if [[ ! -f "$storage_conf" ]] || ! grep -q 'graphRoot' "$storage_conf" 2>/dev/null; then
        run_as_root mkdir -p "$target_graph_root" "$target_run_root"
        _write_storage_conf "$storage_conf" "$target_graph_root" "$target_run_root"
        success "已配置 Podman 存储路径 → GraphRoot=$target_graph_root"
    else
        info "storage.conf 已存在，跳过覆盖（需要修改可进入菜单 6）"
    fi

    # ---- 如有延迟导入任务，现在执行 ----
    if [[ "${NEED_DEFERRED_IMPORT:-false}" == "true" ]] && [[ -n "${BACKUP_DIR:-}" ]]; then
        info "Podman 已就绪，开始导入已备份的镜像..."
        _migrate_step3_import_to_podman
    fi

    _migrate_mark_done "step5"
    return 0
}

# 步骤 6：生成迁移报告
_migrate_step6_report() {
    local report_file="$1"
    info "[6/6] 生成迁移报告..."

    local podman_ver
    podman_ver=$(get_podman_version 2>/dev/null || echo "未知")
    local podman_image_count=0
    podman_image_count=$(podman images -q 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | awk '{ print ($1 + 0) }') || true

    {
        echo "========================================"
        echo "  Docker → Podman 迁移报告"
        echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  主机: $(hostname)"
        echo "========================================"
        echo ""
        echo "【迁移前 Docker 环境】"
        echo "  Docker 版本   : ${DOCKER_VERSION:-未知}"
        echo "  Docker 根目录 : ${DOCKER_ROOT:-未知}"
        echo "  原有镜像数量  : ${DOCKER_IMAGES:-0}"
        echo "  原有容器数量  : ${DOCKER_CONTAINERS:-0}"
        echo "  原有数据卷数  : ${DOCKER_VOLUMES:-0}"
        echo ""
        echo "【镜像备份情况】"
        echo "  备份目录      : ${BACKUP_DIR:-无}"
        echo "  备份成功      : ${BACKUP_IMAGES_OK:-0}"
        echo "  备份失败      : ${BACKUP_IMAGES_FAIL:-0}"
        echo ""
        echo "【镜像导入 Podman】"
        echo "  导入成功      : ${IMPORT_IMAGES_OK:-0}"
        echo "  导入失败      : ${IMPORT_IMAGES_FAIL:-0}"
        echo ""
        echo "【Docker 卸载】"
        echo "  软件包已卸载  : 是"
        echo "  配置已清理    : 是"
        echo "  数据目录已删  : ${DOCKER_DATA_DELETED:-false}"
        echo ""
        echo "【Podman 环境】"
        echo "  Podman 版本   : $podman_ver"
        echo "  当前镜像数量  : $podman_image_count"
        if [[ -f /etc/containers/storage.conf ]]; then
            local gRoot rRoot
            gRoot=$(grep 'graphRoot' /etc/containers/storage.conf 2>/dev/null | awk -F'"' '{print $2}' || echo "未知")
            rRoot=$(grep 'runRoot' /etc/containers/storage.conf 2>/dev/null | awk -F'"' '{print $2}' || echo "未知")
            echo "  镜像存储路径  : $gRoot"
            echo "  运行时路径    : $rRoot"
        fi
        echo "  镜像加速      : 已配置（阿里云/腾讯云/中科大）"
        echo ""
        if [[ "${BACKUP_IMAGES_FAIL:-0}" -gt 0 ]] || [[ "${IMPORT_IMAGES_FAIL:-0}" -gt 0 ]]; then
            echo "【注意事项】"
            [[ "${BACKUP_IMAGES_FAIL:-0}" -gt 0 ]] && echo "  ⚠ 有 ${BACKUP_IMAGES_FAIL} 个镜像备份失败，请手动处理"
            [[ "${IMPORT_IMAGES_FAIL:-0}" -gt 0 ]] && echo "  ⚠ 有 ${IMPORT_IMAGES_FAIL} 个镜像导入失败，可从备份目录手动加载:"
            [[ -n "${BACKUP_DIR:-}" ]] && echo "    podman load -i <备份目录中对应的 .tar 文件>"
            echo ""
        fi
        echo "【常用 Podman 命令对照】"
        echo "  docker ps         →  podman ps"
        echo "  docker images     →  podman images"
        echo "  docker run        →  podman run"
        echo "  docker-compose    →  podman-compose（需单独安装）"
        echo "  docker build      →  podman build"
        echo ""
        echo "  如需 docker 命令兼容：安装 podman-docker 包"
        echo "  $( [[ $PKG_MGR == 'apt-get' ]] && echo 'apt-get install -y podman-docker' || echo 'dnf install -y podman-docker' )"
        echo ""
        echo "========================================"
        echo "  报告文件: $report_file"
        echo "========================================"
    } | tee "$report_file"

    success "报告已保存至: $report_file"
}

# ---- 迁移主流程 ----
migrate_docker_to_podman() {
    draw_header
    echo -e "${BOLD}  🚀 从 Docker 一键迁移到 Podman${NC}"
    separator

    # 初始化运行时状态变量
    DOCKER_VERSION=""
    DOCKER_ROOT="/var/lib/docker"
    DOCKER_RUNNING=false
    DOCKER_IMAGES=0
    DOCKER_CONTAINERS=0
    DOCKER_VOLUMES=0
    DOCKER_NETWORKS=0
    BACKUP_DIR=""
    IMAGE_LIST=()
    MIGRATION_SUMMARY_IMAGES=()
    BACKUP_IMAGES_OK=0
    BACKUP_IMAGES_FAIL=0
    IMPORT_IMAGES_OK=0
    IMPORT_IMAGES_FAIL=0
    NEED_DEFERRED_IMPORT=false
    DOCKER_DATA_DELETED=false

    # ---- 断点续跑检测 ----
    if [[ -f "$MIGRATION_STATE_FILE" ]]; then
        echo -e "  ${YELLOW}检测到上次未完成的迁移记录：${NC}"
        echo ""
        # 展示已完成的步骤
        for s in step2 step3 step4 step5; do
            if _migrate_is_done "$s"; then
                echo -e "   ${GREEN}✅ ${s} 已完成${NC}"
            else
                echo -e "   ${YELLOW}○ ${s} 未完成${NC}"
            fi
        done
        echo ""
        echo -e "   a) 从上次中断点继续"
        echo -e "   b) 忽略旧记录，重新开始迁移"
        echo -e "   0) 返回菜单"
        echo ""
        read -rep "$(echo -e "${YELLOW}请选择 [a/b/0]: ${NC}")" resume_choice
        case "${resume_choice,,}" in
            a)
                # 从状态文件恢复历史数据
                BACKUP_DIR=$(_migrate_load_val "BACKUP_DIR" "")
                local saved_list
                saved_list=$(_migrate_load_val "IMAGE_LIST" "")
                [[ -n "$saved_list" ]] && read -ra IMAGE_LIST <<< "$saved_list"
                BACKUP_IMAGES_OK=$(_migrate_load_val "BACKUP_IMAGES_OK" "0")
                BACKUP_IMAGES_FAIL=$(_migrate_load_val "BACKUP_IMAGES_FAIL" "0")
                IMPORT_IMAGES_OK=$(_migrate_load_val "IMPORT_IMAGES_OK" "0")
                IMPORT_IMAGES_FAIL=$(_migrate_load_val "IMPORT_IMAGES_FAIL" "0")
                local saved_del
                saved_del=$(_migrate_load_val "DOCKER_DATA_DELETED" "false")
                DOCKER_DATA_DELETED=$([ "$saved_del" = "true" ] && echo true || echo false)
                info "已恢复上次状态，BACKUP_DIR=$BACKUP_DIR"
                ;;
            b)
                rm -f "$MIGRATION_STATE_FILE"
                info "已清除旧状态，重新开始"
                ;;
            0|*)
                press_any_key; return
                ;;
        esac
        echo ""
    fi

    # ---- 迁移前确认（如果不是断点续跑）----
    if ! [[ -f "$MIGRATION_STATE_FILE" ]]; then
        # 只有此时才探测并要求确认
        if ! _migrate_step1_detect; then
            warn "未检测到 Docker 环境，迁移中止"
            press_any_key; return
        fi
        echo -e "${RED}${BOLD}⚠  警告：此操作将卸载 Docker 并安装 Podman${NC}"
        echo -e "  建议先确认重要容器/数据已有其他备份方式"
        echo ""
        read -rep "$(echo -e "${YELLOW}确认开始迁移？输入 yes 继续: ${NC}")" confirm
        if [[ "${confirm,,}" != "yes" ]]; then
            info "已取消迁移"
            press_any_key; return
        fi
        # 创建状态文件标记已开始
        echo "migration_started=$(date '+%Y-%m-%d %H:%M:%S')" > "$MIGRATION_STATE_FILE"
        _migrate_save_val "DOCKER_VERSION" "$DOCKER_VERSION"
        _migrate_save_val "DOCKER_ROOT" "$DOCKER_ROOT"
        _migrate_save_val "DOCKER_IMAGES" "$DOCKER_IMAGES"
        _migrate_save_val "DOCKER_CONTAINERS" "$DOCKER_CONTAINERS"
        _migrate_save_val "DOCKER_VOLUMES" "$DOCKER_VOLUMES"
        _migrate_mark_done "step1"
    else
        # 断点续跑：从状态文件恢复源牴 Docker 信息
        DOCKER_VERSION=$(_migrate_load_val "DOCKER_VERSION" "未知")
        DOCKER_ROOT=$(_migrate_load_val "DOCKER_ROOT" "/var/lib/docker")
        DOCKER_IMAGES=$(_migrate_load_val "DOCKER_IMAGES" "0")
        DOCKER_CONTAINERS=$(_migrate_load_val "DOCKER_CONTAINERS" "0")
        DOCKER_VOLUMES=$(_migrate_load_val "DOCKER_VOLUMES" "0")
    fi

    echo ""
    local report_file
    report_file=$(_migration_report_file)

    # 步骤 2：备份镜像
    if _migrate_is_done "step2"; then
        info "[2/6] 镜像备份已完成，跳过 (备份目录: ${BACKUP_DIR:-无})"
    else
        _migrate_step2_backup_images || true
    fi

    # 步骤 3：导入镜像到 Podman
    if _migrate_is_done "step3"; then
        info "[3/6] 镜像导入已完成，跳过 (成功: ${IMPORT_IMAGES_OK}，失败: ${IMPORT_IMAGES_FAIL})"
    else
        _migrate_step3_import_to_podman || true
    fi

    # 步骤 4：卸载 Docker
    if _migrate_is_done "step4"; then
        info "[4/6] Docker 卸载已完成，跳过"
    else
        _migrate_step4_uninstall_docker || true
    fi

    # 步骤 5：安装并配置 Podman
    if _migrate_is_done "step5"; then
        info "[5/6] Podman 安装配置已完成，跳过"
    else
        _migrate_step5_install_podman || {
            error "Podman 安装失败，请检查错误后重新运行菜单 16"
            press_any_key; return
        }
    fi

    # 步骤 6：生成报告
    echo ""
    separator
    _migrate_step6_report "$report_file"

    # 迁移全部完成，删除状态文件
    rm -f "$MIGRATION_STATE_FILE"
    success "迁移全部完成，将状态文件已清理"

    press_any_key
}


# ==========================================
# 17. Rootful → Rootless 统一管理
# ==========================================
# 功能：清理 root 用户遗留的 Podman 配置和数据，
#       将 Podman 管理统一到普通用户（rootless 模式）。
#       适用于 root 和普通用户分别运行过 podman，导致配置混乱的场景。
#
# 清理内容：
#   1. /etc/containers/storage.conf     — root 存储配置（若由本脚本生成则删除）
#   2. /var/lib/containers/             — root Podman 运行时数据
#   3. /data/containerd、/data/volume_data 中的 root 遗留 overlay 数据
#   4. root 的 podman systemd 服务残留
#   5. root 的构建缓存（buildah containers）
#
# 保留内容：
#   - ecs-user ~/.config/containers/ — 用户配置
#   - ecs-user ~/.local/share/containers/ — 用户数据
#   - /etc/subuid, /etc/subgid — 用户 rootless 所需
#   - /data/volume_data/mysql 等 — 数据库持久化数据
cleanup_root_podman_unify_to_rootless() {
    draw_header
    echo -e "${BOLD}  🧹 Rootful → Rootless 统一管理${NC}"
    separator

    require_root
    detect_pkg_manager

    echo -e "${CYAN}${BOLD}此操作将：${NC}"
    echo ""
    echo -e "  ${YELLOW}1) 扫描并清理 root 所有 Podman 污染源${NC}"
    echo -e "  ${YELLOW}2) 删除 root 属主的普通用户 storage.conf（导致 permission denied 元凶）${NC}"
    echo -e "  ${YELLOW}3) 删除 root 的 Podman 系统配置${NC}"
    echo -e "  ${YELLOW}4) 清理 root 遗留的 Podman 运行时数据${NC}"
    echo -e "  ${YELLOW}5) 统一由普通用户（rootless）管理 Podman${NC}"
    echo ""

    # ======================================================
    # 探测阶段：扫描所有 root 污染源
    # ======================================================
    echo -e "${CYAN}${BOLD}── 全面探测 root 污染源 ──────────────────────${NC}"
    echo ""

    local root_has_podman=false
    command -v podman >/dev/null 2>&1 && root_has_podman=true

    # --- 1. root 残留容器 ---
    local root_containers=""
    if $root_has_podman; then
        root_containers=$(podman ps -aq 2>/dev/null) || true
    fi
    local root_ct_count=0
    [[ -n "$root_containers" ]] && root_ct_count=$(_pm_count_nonempty_lines_from_var "$root_containers")
    if [[ "$root_ct_count" -gt 0 ]]; then
        echo -e "  ${RED}⚠  root 下有 ${root_ct_count} 个残留容器${NC}"
    else
        echo -e "  ${GREEN}✅ root 下无残留容器${NC}"
    fi

    # --- 2. root 残留镜像 ---
    local root_img_count=0
    if $root_has_podman; then
        root_img_count=$(podman images -q 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | awk '{ print ($1 + 0) }') || true
    fi
    echo -e "  root 镜像数量: ${root_img_count}"

    # --- 3. 全局配置文件 ---
    echo ""
    echo -e "${CYAN}── 系统级配置 (/etc/containers) ───────────────${NC}"
    local clean_cfgs=()
    [[ -f /etc/containers/storage.conf ]] && clean_cfgs+=("/etc/containers/storage.conf")
    if [[ ${#clean_cfgs[@]} -gt 0 ]]; then
        echo -e "  ${RED}将被删除：${NC}"
        for f in "${clean_cfgs[@]}"; do
            echo -e "    • ${f}"
        done
    else
        echo -e "  ${GREEN}✅ 无残留${NC}"
    fi

    # --- 4. root 属主的普通用户 storage.conf（关键！）---
    echo ""
    echo -e "${CYAN}── 用户级配置 (~/.config/containers) ───────────${NC}"
    # 探测所有可能被 root 污染的用户 home 下的 storage.conf
    local _polluted_user_cfgs=()
    local _real_user="ecs-user"
    # 如果脚本是通过 sudo 运行的，SUDO_USER 是真实用户
    [[ -n "${SUDO_USER:-}" ]] && _real_user="$SUDO_USER"

    local _user_home
    _user_home=$(eval echo ~"$_real_user" 2>/dev/null) || _user_home="/home/$_real_user"
    local _user_sc="$_user_home/.config/containers/storage.conf"

    if [[ -f "$_user_sc" ]]; then
        local _sc_owner _sc_runroot _sc_graphroot
        _sc_owner=$(stat -c '%U' "$_user_sc" 2>/dev/null || echo "")
        _sc_runroot=$(grep 'runRoot' "$_user_sc" 2>/dev/null | head -1 || echo "")
        _sc_graphroot=$(grep 'graphRoot' "$_user_sc" 2>/dev/null | head -1 || echo "")

        local _polluted=false
        # 判断是否被污染：属主是 root，或路径指向 root 专有目录
        [[ "$_sc_owner" == "root" ]] && _polluted=true
        echo "$_sc_graphroot" | grep -qE '"(/data/|/var/lib/)"' && _polluted=true
        echo "$_sc_runroot" | grep -qE '"(/var/run/containers|/data/containerd)"' && _polluted=true

        if [[ "$_polluted" == "true" ]]; then
            echo -e "  ${RED}⚠  发现 root 污染的 storage.conf（普通用户 podman 无法启动的元凶！）${NC}"
            echo -e "    文件: ${_user_sc}  (属主: ${_sc_owner:-?})"
            echo -e "    内容: ${_sc_graphroot}  ${_sc_runroot}"
            echo -e "    影响: 普通用户执行 podman 会报 permission denied"
            _polluted_user_cfgs+=("$_user_sc")
        else
            echo -e "  ${GREEN}✅ $_user_sc 正常${NC}"
        fi
    else
        echo -e "  ${GREEN}✅ 无用户 storage.conf（podman 使用默认路径）${NC}"
    fi

    # --- 5. root 数据目录 ---
    echo ""
    echo -e "${CYAN}── 数据目录检查 ───────────────────────────────${NC}"
    local clean_dirs=()
    [[ -d /var/lib/containers ]] && clean_dirs+=("/var/lib/containers")
    [[ -d /data/containerd ]] && clean_dirs+=("/data/containerd")
    # 空目录 /data/containers（root 创建的，无内容）
    if [[ -d /data/containers ]]; then
        local _srv_ct_content
        _srv_ct_content=$(ls -A /data/containers 2>/dev/null || echo "")
        if [[ -z "$_srv_ct_content" ]]; then
            clean_dirs+=("/data/containers")
        else
            # 只清理 podman 内部子目录
            for _sub in overlay overlay-containers overlay-images overlay-layers libpod volumes; do
                [[ -d "/data/containers/$_sub" ]] && clean_dirs+=("/data/containers/$_sub")
            done
        fi
    fi

    # /data/volume_data 中的 root podman 内部文件
    if [[ -d /data/volume_data ]]; then
        for _sub in overlay overlay-containers overlay-images overlay-layers libpod volumes storage.lock userns.lock db.sql defaultNetworkBackend; do
            [[ -e "/data/volume_data/$_sub" ]] && clean_dirs+=("/data/volume_data/$_sub")
        done
    fi

    if [[ ${#clean_dirs[@]} -gt 0 ]]; then
        echo -e "  ${RED}将被清理：${NC}"
        for d in "${clean_dirs[@]}"; do
            local _sz
            _sz=$(du -sh "$d" 2>/dev/null | awk 'NR==1 { print $1; exit }') || true
            echo -e "    • ${d}  ${_sz:+(${_sz})}"
        done
    else
        echo -e "  ${GREEN}✅ 无残留数据目录${NC}"
    fi

    # --- 汇总 ---
    local _total_issues=0
    [[ "$root_ct_count" -gt 0 ]] && _total_issues=$((_total_issues + 1))
    [[ "$root_img_count" -gt 0 ]] && _total_issues=$((_total_issues + 1))
    [[ ${#clean_cfgs[@]} -gt 0 ]] && _total_issues=$((_total_issues + 1))
    [[ ${#_polluted_user_cfgs[@]} -gt 0 ]] && _total_issues=$((_total_issues + 1))
    [[ ${#clean_dirs[@]} -gt 0 ]] && _total_issues=$((_total_issues + 1))

    echo ""
    separator
    if [[ "$_total_issues" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}✅ 未发现任何 root 污染，Podman 已处于正常的 rootless 管理状态${NC}"
        echo ""
        # 快速检查：确认普通用户 podman 可用
        echo -e "${CYAN}快速验证：${NC}"
        podman info --format '  Rootless: {{.Host.Security.Rootless}}' 2>/dev/null || echo "  （无法检测，请以普通用户运行 podman info）"
        echo -e "  GraphRoot 默认路径: ~/.local/share/containers/storage"
        press_any_key
        return
    fi

    echo -e "  ${CYAN}共发现 ${_total_issues} 类问题需要修复${NC}"
    echo ""

    # ======================================================
    # 确认
    # ======================================================
    read -rep "$(echo -e "${RED}确认清理以上所有 root 污染源？[y/N]: ${NC}")" confirm

    if [[ "${confirm,,}" != "y" ]]; then
        info "已取消"
        press_any_key
        return
    fi

    log "开始全面清理 root Podman 污染源..."

    # ======================================================
    # 执行阶段
    # ======================================================

    # Step A: 删除 root 属主的用户 storage.conf（最先处理，解除普通用户 podman 阻塞）
    for _f in "${_polluted_user_cfgs[@]}"; do
        if [[ -f "$_f" ]]; then
            run_as_root rm -f "$_f"
            success "已删除 root 污染的用户 storage.conf: $_f"
        fi
    done
    # 确保用户配置目录属主正确
    local _cfg_dir="$_user_home/.config/containers"
    if [[ -d "$_cfg_dir" ]]; then
        run_as_root chown -R "${_real_user}:${_real_user}" "$_cfg_dir" 2>/dev/null || true
    fi

    # Step B: 停止并删除 root 下所有容器
    if [[ -n "$root_containers" ]]; then
        info "停止 root 容器..."
        echo "$root_containers" | xargs -r run_as_root podman stop -t 10 2>/dev/null || true
        echo "$root_containers" | xargs -r run_as_root podman rm -f 2>/dev/null || true
        success "已停止并删除 root 残留容器"
    fi

    # Step C: 删除 root 镜像
    if $root_has_podman && [[ "$root_img_count" -gt 0 ]]; then
        info "删除 root 镜像..."
        run_as_root podman image prune -af --build-cache --external 2>/dev/null || true
        run_as_root podman rmi -a -f 2>/dev/null || true
        success "已删除 root 镜像"
    fi

    # Step D: 备份并删除 root 系统配置文件
    local backup_dir="/tmp/podman_root_backup_$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "$backup_dir"
    for f in "${clean_cfgs[@]}"; do
        if [[ -f "$f" ]]; then
            run_as_root cp -a "$f" "$backup_dir/" 2>/dev/null || true
            run_as_root rm -f "$f"
            success "已删除 root 配置: $f"
        fi
    done
    if ls "$backup_dir"/* >/dev/null 2>&1; then
        info "配置文件备份至: $backup_dir"
    else
        rmdir "$backup_dir" 2>/dev/null || true
    fi

    # Step E: 清理 root 数据目录
    for d in "${clean_dirs[@]}"; do
        if [[ -e "$d" ]]; then
            run_as_root rm -rf "$d" 2>/dev/null && success "已清理: $d" || warn "清理失败: $d"
        fi
    done

    # Step F: 清理 buildah 构建容器
    if command -v buildah >/dev/null 2>&1; then
        run_as_root buildah containers --all -q 2>/dev/null | xargs -r run_as_root buildah rm 2>/dev/null || true
    fi

    # Step G: 清理 lingering
    local _root_linger="/var/lib/systemd/linger/root"
    [[ -f "$_root_linger" ]] && run_as_root rm -f "$_root_linger"

    # Step H: 确保普通用户 rootless 配置正确
    if id "$_real_user" >/dev/null 2>&1; then
        if ! grep -q "^${_real_user}:" /etc/subuid 2>/dev/null; then
            local _max_uid
            _max_uid=$(awk -F: '/^[^#]/ && $2 > 0 { if ($2 > max) max=$2 } END { print (max > 0 ? max + 65536 : 100000) }' /etc/subuid 2>/dev/null || echo 100000)
            echo "${_real_user}:${_max_uid}:65536" | run_as_root tee -a /etc/subuid > /dev/null
            echo "${_real_user}:${_max_uid}:65536" | run_as_root tee -a /etc/subgid > /dev/null
            success "已为 ${_real_user} 配置 /etc/subuid 和 /etc/subgid"
        else
            success "/etc/subuid 中 ${_real_user} 配置正常"
        fi
    fi

    echo ""
    separator
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  ✅ Root Podman 污染清理完成！${NC}"
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}后续管理方式：${NC}"
    echo -e "   • 统一使用普通用户（${_real_user}）执行 podman 管理"
    echo -e "   • 运行: ${CYAN}podman ps${NC}、${CYAN}podman images${NC}"
    echo -e "   • 项目管理: ${CYAN}./up.sh <服务名> up -d${NC}"
    echo -e "   • 构建镜像: ${CYAN}./build.sh <服务名>${NC}"
    echo ""
    echo -e "  ${CYAN}快速验证：${NC}"
    echo -e "    podman info --format 'Rootless: {{.Host.Security.Rootless}}'"
    echo -e "    （应输出 'true'）"
    echo ""

    press_any_key
}


main() {
    detect_pkg_manager 2>/dev/null || true
    local _had_proxy="${HTTP_PROXY-}"
    _pm_apply_session_proxy_from_build 2>/dev/null || true
    if [[ -z "$_had_proxy" && -n "${HTTP_PROXY:-}" ]]; then
        info "已为当前 shell 会话启用构建代理（dnf / curl / podman pull 等；来自 .env/base.env 或脚本内 BUILD_PROXY_*）"
    fi

    # 启动时静默检测并自动修复 SHM lock 槽位冲突
    # （Podman 大版本升级后常见问题，修复无数据风险）
    fix_shm_lock --quiet 2>/dev/null || true
    _fix_rootless_storage_if_unwritable 2>/dev/null || true

    while true; do
        draw_main_menu
        read -re choice

        case "$choice" in
            1)  install_podman ;;
            2)  install_extras_menu; press_any_key ;;
            3)  uninstall_podman ;;
            4)  configure_mirrors ;;
            5)  configure_rootless ;;
            6)  configure_storage ;;
            7)  configure_proxy ;;
            8)  show_status ;;
            9)  manage_containers ;;
            10) manage_images ;;
            11) manage_pods ;;
            12) manage_networks ;;
            13) manage_volumes ;;
            14) system_cleanup ;;
            15) run_diagnostics ;;
            16) migrate_docker_to_podman ;;
            17) cleanup_root_podman_unify_to_rootless ;;
            0)
                echo -e "\n${GREEN}再见！${NC}\n"
                exit 0
                ;;
            *)
                warn "无效选项，请输入 0-17"
                sleep 1
                ;;
        esac
    done
}

main "$@"
