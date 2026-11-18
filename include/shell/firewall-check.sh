#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

# 错误处理 trap - 输出错误上下文
trap 'echo "[ERROR] 脚本: ${BASH_SOURCE[0]:-$0}, 行号: ${LINENO}, 命令: ${BASH_COMMAND}, 退出码: ${?}" >&2' ERR

# ==========================================
# Docker 防火墙预检脚本 v1.0
# ==========================================
# Comprehensive pre-flight firewall check for Docker Compose environments.
# Detects active firewall, verifies Docker bridge forwarding health,
# extracts service ports, and optionally adds missing firewall rules.
#
# Usage: source this file, then call ensure_firewall_ready()
# Depends on: common_functions.sh (already sourced by caller)
# ==========================================

# Guard against re-sourcing
[[ -n "${_FIREWALL_CHECK_LOADED:-}" ]] && return 0
_FIREWALL_CHECK_LOADED=1

# 确保容器运行时已检测（common_functions.sh 可能已加载，此处做 fallback）
if [[ -z "${CR:-}" ]]; then
    _FW_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    if [[ -f "$_FW_SCRIPT_DIR/include/shell/container_runtime.sh" ]]; then
        source "$_FW_SCRIPT_DIR/include/shell/container_runtime.sh"
        detect_container_runtime || true
    fi
    if [[ -z "${CR:-}" ]]; then
        CR="docker"
    fi
fi

# ==========================================
# Internal constants
# ==========================================
readonly _FW_TAG="firewall"
readonly _FW_DOCKER_NETWORK_NAME="${FW_DOCKER_NETWORK_NAME:-hg_dnmpr_network}"
readonly _FW_DOCKER_BRIDGE_NAME="${FW_DOCKER_BRIDGE_NAME:-br-hg-dnmpr}"
readonly _FW_UNKNOWN_REASON_PERMISSION="权限不足"

# UFW after.rules snippet for permanent Docker fix
read -r -d '' _FW_UFW_AFTER_RULES_SNIPPET << 'SNIPPET_EOF' || true
# BEGIN DOCKER UFW RULES
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -j RETURN
COMMIT

*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 172.16.0.0/12 ! -o docker0 -j MASQUERADE
-A POSTROUTING -s 192.168.0.0/16 ! -o docker0 -j MASQUERADE
-A POSTROUTING -s 10.0.0.0/8 ! -o docker0 -j MASQUERADE
COMMIT
# END DOCKER UFW RULES
SNIPPET_EOF

# ==========================================
# Internal logging (prefix with [firewall])
# ==========================================

_fw_log_info() {
    if declare -F info >/dev/null 2>&1; then
        info "[${_FW_TAG}] $1" >&2
    else
        echo -e "[INFO] [${_FW_TAG}] $1" >&2
    fi
}

_fw_log_warn() {
    if declare -F warn >/dev/null 2>&1; then
        warn "[${_FW_TAG}] $1" >&2
    else
        echo -e "[WARN] [${_FW_TAG}] $1" >&2
    fi
}

_fw_log_success() {
    if declare -F success >/dev/null 2>&1; then
        success "[${_FW_TAG}] $1" >&2
    else
        echo -e "[OK] [${_FW_TAG}] $1" >&2
    fi
}

_fw_log_error() {
    # NOTE: We intentionally do NOT call error() from common_functions.sh
    # because that function calls exit 1. This script must never block startup.
    if [[ -n "${RED:-}" ]]; then
        echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC:-} [${_FW_TAG}] $1" >&2
    else
        echo -e "[ERROR] [${_FW_TAG}] $1" >&2
    fi
}

# ==========================================
# 1. 防火墙检测 — 三步递进式
# ==========================================
#
# 设计原则：
#   防火墙检测分为三个独立步骤，每步职责单一、互不依赖：
#
#   步骤 1 — _fw_scan_installed()
#     扫描系统中存在哪些防火墙相关的可执行文件/服务单元。
#     只做存在性检查，不判断是否运行。
#     输出: 空格分隔的工具名列表，如 "ufw nftables"
#
#   步骤 2 — _fw_scan_running()
#     在已安装的工具中，进一步判断哪些当前正在运行（systemd active / 进程存活）。
#     输出: 空格分隔的运行中工具名列表
#
#   步骤 3 — _fw_detect_type() + _fw_is_active()
#     综合前两步结果，选出"实际生效"的防火墙工具（规则真正在过滤流量）。
#     优先级：运行中的前端管理工具 > 运行中的底层工具 > 仅安装的工具 > none
#
# 适用场景：
#   - 桌面 Ubuntu：UFW 已安装且 enabled（systemd active），但规则可能 inactive
#   - 云服务器（无 UFW）：nftables 或 iptables 直接配置
#   - CentOS/RHEL：firewalld 为主，可能与 nftables 并存
#   - 特殊环境：同时安装多个工具，以"正在运行"的为准
#
# 返回值约定（_fw_detect_type stdout）: ufw|firewalld|iptables|nftables|none
# 返回值约定（_fw_is_active stdout）:   "true" | "false"

# ----------------------------------------------------------
# 步骤 1：扫描已安装的防火墙工具
# 输出：空格分隔的工具名，顺序按发现顺序，如 "ufw nft iptables"
# ----------------------------------------------------------
_fw_scan_installed() {
    local -a found=()
    command -v ufw          >/dev/null 2>&1 && found+=("ufw")
    command -v firewall-cmd >/dev/null 2>&1 && found+=("firewalld")
    command -v nft          >/dev/null 2>&1 && found+=("nftables")
    command -v iptables     >/dev/null 2>&1 && found+=("iptables")
    echo "${found[*]:-}"
}

# ----------------------------------------------------------
# 步骤 2：在已安装的工具中，判断哪些当前正在运行
#
# 判断依据（按工具）：
#   ufw      → systemd unit "ufw" 处于 active 状态
#              （注意：active 只代表服务进程存活，不代表规则已激活）
#   firewalld→ systemd unit "firewalld" active，或 firewall-cmd --state=running
#   nftables → systemd unit "nftables" active（即规则已从 /etc/nftables.conf 加载）
#   iptables → 无独立 systemd 服务；通过 iptables -S INPUT 检测 INPUT 链是否有
#              用户写入的规则（DROP/REJECT 策略或显式 INPUT 规则），排除 Docker 链
#
# 输出：空格分隔的运行中工具名
# ----------------------------------------------------------
_fw_scan_running() {
    local installed="${1:-}"
    local -a running=()

    for tool in $installed; do
        case "$tool" in
            ufw)
                # UFW 的 systemd 服务 active 即视为"运行中"
                # （区分"服务运行"和"规则激活"在 _fw_is_active 中处理）
                if systemctl is-active --quiet ufw 2>/dev/null; then
                    running+=("ufw")
                fi
                ;;
            firewalld)
                if systemctl is-active --quiet firewalld 2>/dev/null; then
                    running+=("firewalld")
                elif command -v firewall-cmd >/dev/null 2>&1 && \
                     firewall-cmd --state 2>/dev/null | grep -qi "running"; then
                    running+=("firewalld")
                fi
                ;;
            nftables)
                # nftables 服务 active 表示规则已从配置文件加载，视为运行中
                if systemctl is-active --quiet nftables 2>/dev/null; then
                    running+=("nftables")
                fi
                ;;
            iptables)
                # iptables 无独立服务，检测 INPUT 链是否有用户写入的过滤规则
                # 排除 Docker 写入的 DOCKER/* 链，只看 INPUT 链策略和显式规则
                local ipt_input=""
                if _fw_can_sudo; then
                    ipt_input=$(_fw_run_sudo iptables -S INPUT 2>/dev/null) || ipt_input=""
                else
                    ipt_input=$(iptables -S INPUT 2>/dev/null) || ipt_input=""
                fi
                if echo "$ipt_input" | grep -qE '^-P INPUT (DROP|REJECT)$'; then
                    running+=("iptables")
                elif echo "$ipt_input" | grep -qE '^-A INPUT .*(DROP|REJECT)'; then
                    running+=("iptables")
                fi
                ;;
        esac
    done

    echo "${running[*]:-}"
}

# ----------------------------------------------------------
# 步骤 3a：综合前两步，选出实际使用的防火墙工具
#
# 选择策略（优先级从高到低）：
#   1. 运行中的前端管理工具（ufw / firewalld）
#      前端工具统一管理底层规则，优先级最高
#   2. 运行中的底层工具（nftables / iptables）
#      无前端工具时，底层工具直接配置防火墙
#   3. 仅安装但未运行的前端工具
#      工具存在但未启动，提示用户，fw_active=false
#   4. none：既无安装也无运行
#
# 返回值（stdout）: ufw|firewalld|nftables|iptables|none
# ----------------------------------------------------------
_fw_detect_type() {
    local installed running

    installed=$(_fw_scan_installed)
    running=$(_fw_scan_running "$installed")

    # --- 优先级 1：运行中的前端管理工具 ---
    for tool in ufw firewalld; do
        if echo "$running" | grep -qw "$tool"; then
            echo "$tool"
            return 0
        fi
    done

    # --- 优先级 2：运行中的底层工具 ---
    # nftables 服务 active > iptables 有 INPUT 规则
    for tool in nftables iptables; do
        if echo "$running" | grep -qw "$tool"; then
            echo "$tool"
            return 0
        fi
    done

    # --- 优先级 3：仅安装但未运行的前端工具（按优先级取第一个）---
    for tool in ufw firewalld nftables iptables; do
        if echo "$installed" | grep -qw "$tool"; then
            echo "$tool"
            return 0
        fi
    done

    # --- 优先级 4：未检测到任何防火墙 ---
    echo "none"
    return 0
}

# ----------------------------------------------------------
# 步骤 3b：判断选定的防火墙工具规则是否实际生效
#
# 各工具的"生效"判断标准：
#   ufw      → ufw status 输出 "Status: active"（规则已加载到内核）
#   firewalld→ firewalld 服务 active（服务运行即规则生效）
#   iptables → INPUT 链有 DROP/REJECT 策略或显式规则（与 _fw_scan_running 保持一致）
#   nftables → nftables 服务 active，或规则集中存在 type filter + hook input 的链
#   none     → false
#
# 参数: $1 = fw_type (ufw|firewalld|iptables|nftables|none)
# 返回值（stdout）: "true" 或 "false"
# ----------------------------------------------------------
_fw_is_active() {
    local fw_type="${1:-none}"

    case "$fw_type" in
        ufw)
            # ufw status 是判断 UFW 规则是否加载的唯一权威来源。
            # systemctl is-active ufw 只表示服务进程存活，不代表规则已激活。
            local ufw_out=""
            ufw_out=$(ufw status 2>/dev/null) || true
            # 普通用户可能看不到完整状态，尝试 sudo
            if [[ -z "$ufw_out" ]] || echo "$ufw_out" | grep -qi "permission denied\|must be run as root"; then
                if _fw_can_sudo; then
                    ufw_out=$(_fw_run_sudo ufw status 2>/dev/null) || true
                fi
            fi
            if echo "$ufw_out" | grep -qi "^Status: active"; then
                echo "true"
            elif [[ -z "$ufw_out" ]] || echo "$ufw_out" | grep -qi "permission denied\|must be run as root"; then
                # ufw status 无输出且无法通过 sudo 读取（无交互式 sudo 权限）。
                # 此时无法直接读取 UFW 规则激活状态，用 systemctl is-active ufw 作兜底：
                # UFW 的 systemd 服务在 enabled+active 时，表示 ufw enable 已被执行过，
                # 即规则已通过 ufw-init 加载到内核。这是无 sudo 环境下可获得的最强证据。
                if systemctl is-active --quiet ufw 2>/dev/null; then
                    echo "true"
                else
                    echo "false"
                fi
            else
                echo "false"
            fi
            ;;
        firewalld)
            # firewalld 服务运行即规则生效（与 _fw_scan_running 判断一致）
            if systemctl is-active --quiet firewalld 2>/dev/null; then
                echo "true"
            elif command -v firewall-cmd >/dev/null 2>&1 && \
                 firewall-cmd --state 2>/dev/null | grep -qi "running"; then
                echo "true"
            else
                echo "false"
            fi
            ;;
        iptables)
            # INPUT 链有 DROP/REJECT 策略或显式规则（与 _fw_scan_running 保持一致）
            local ipt_input=""
            if _fw_can_sudo; then
                ipt_input=$(_fw_run_sudo iptables -S INPUT 2>/dev/null) || ipt_input=""
            else
                ipt_input=$(iptables -S INPUT 2>/dev/null) || ipt_input=""
            fi
            if echo "$ipt_input" | grep -qE '^-P INPUT (DROP|REJECT)$'; then
                echo "true"
            elif echo "$ipt_input" | grep -qE '^-A INPUT .*(DROP|REJECT)'; then
                echo "true"
            else
                echo "false"
            fi
            ;;
        nftables)
            # nftables 服务 active → 规则从 /etc/nftables.conf 加载，视为生效
            if systemctl is-active --quiet nftables 2>/dev/null; then
                echo "true"
                return 0
            fi
            # 服务未启动时，检查内核规则集中是否有 filter input 链
            # （可能由其他工具写入，如 firewalld 的 nftables 后端）
            local nft_rs=""
            if _fw_can_sudo; then
                nft_rs=$(_fw_run_sudo nft list ruleset 2>/dev/null) || nft_rs=""
            else
                nft_rs=$(nft list ruleset 2>/dev/null) || nft_rs=""
            fi
            if [[ -n "$nft_rs" ]] && \
               echo "$nft_rs" | grep -q "type filter" && \
               echo "$nft_rs" | grep -q "hook input"; then
                echo "true"
            else
                echo "false"
            fi
            ;;
        none|*)
            echo "false"
            ;;
    esac
    return 0
}

# ==========================================
# 2. Sudo helpers
# ==========================================

# Check if we can run privileged commands without a password prompt
_fw_can_sudo() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    sudo -n true 2>/dev/null && return 0
    return 1
}

# Prompt user for sudo credentials and cache them
# Returns 0 on success, 1 on failure/decline
_fw_request_sudo() {
    if _fw_can_sudo; then
        return 0
    fi

    _fw_log_info "部分检查需要管理员权限，正在请求 sudo 授权..."
    echo ""
    if sudo -v 2>/dev/null; then
        _fw_log_success "sudo 授权成功"
        return 0
    else
        _fw_log_warn "无法获取 sudo 授权，部分检查将被跳过"
        return 1
    fi
}

# Run a command with sudo if not already root
_fw_run_sudo() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# 是否存在 nftables-manager 前端管理工具
# 该工具由用户自行安装于 /usr/local/bin/nftables-manager，封装了 nftables 规则的
# 添加/删除/持久化、IP 白黑名单与命名集合等高阶语义。
# 当存在时，应优先通过它增删规则，避免脚本绕过其状态管理写入临时规则。
_fw_has_nftables_manager() {
    command -v nftables-manager >/dev/null 2>&1
}

# 解析逗号分隔的端口/端口范围列表（如 " 80, 443, 8000-8010 "）
# 若目标端口命中其中任一项（含范围），返回 0；否则返回 1。
_fw_port_in_csv_list() {
    local target_port="$1"
    local csv="$2"
    [[ -z "$csv" ]] && return 1
    [[ "$target_port" =~ ^[0-9]+$ ]] || return 1

    local _ifs_save=$IFS
    IFS=','
    local item lo hi
    for item in $csv; do
        item="${item// /}"
        item="${item//\"/}"
        [[ -z "$item" ]] && continue
        if [[ "$item" == "$target_port" ]]; then
            IFS=$_ifs_save
            return 0
        fi
        if [[ "$item" == *-* ]]; then
            lo="${item%-*}"
            hi="${item#*-}"
            if [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] \
               && (( target_port >= lo && target_port <= hi )); then
                IFS=$_ifs_save
                return 0
            fi
        fi
    done
    IFS=$_ifs_save
    return 1
}

# 解析 `nft list set <table> <set>` 输出中 `elements = { ... }` 的内容
_fw_dump_nft_set_elements() {
    local set_name="$1"
    local set_dump=""
    set_dump=$(_fw_run_sudo nft list set inet filter "$set_name" 2>/dev/null) \
        || set_dump=$(_fw_run_sudo nft list set ip filter "$set_name" 2>/dev/null) \
        || set_dump=""
    [[ -z "$set_dump" ]] && return 1
    # 兼容多行的 elements = { a, b, c }
    echo "$set_dump" | tr '\n' ' ' \
        | sed -n 's/.*elements[[:space:]]*=[[:space:]]*{\([^}]*\)}.*/\1/p'
    return 0
}

# ==========================================
# 2b. UFW FORWARD policy helpers
# ==========================================

# Check whether UFW's DEFAULT_FORWARD_POLICY is DROP (breaks Docker networking).
# Returns: 0=ACCEPT (OK), 1=DROP (problematic for Docker), 2=unknown/not found
_fw_check_ufw_forward_policy() {
    local ufw_defaults="/etc/default/ufw"
    [[ ! -f "$ufw_defaults" ]] && return 2

    local policy
    policy=$(grep -E '^DEFAULT_FORWARD_POLICY=' "$ufw_defaults" 2>/dev/null \
        | head -1 | cut -d= -f2 | tr -d '"'"'"' [:space:]')

    case "$policy" in
        ACCEPT) return 0 ;;
        DROP)   return 1 ;;
        *)      return 2 ;;
    esac
}

# Interactively offer to fix UFW DEFAULT_FORWARD_POLICY=DROP, then reload UFW
# and restart Docker so its iptables rules are rebuilt cleanly.
# Returns: 0=fix applied, 1=not applied / declined / error
_fw_offer_fix_ufw_forward_policy() {
    echo ""
    echo -e "${RED:-}╔══════════════════════════════════════════════════════════════╗${NC:-}"
    echo -e "${RED:-}║  ⚠  UFW FORWARD 策略为 DROP，Docker 容器网络将受阻          ║${NC:-}"
    echo -e "${RED:-}╚══════════════════════════════════════════════════════════════╝${NC:-}"
    echo ""
    echo -e "${YELLOW:-}问题说明:${NC:-}"
    echo -e "  /etc/default/ufw 中 DEFAULT_FORWARD_POLICY=\"DROP\""
    echo -e "  UFW 每次 reload 会用 iptables-restore 重置整张表，"
    echo -e "  Docker 写入的转发规则随之被清除，导致:"
    echo -e "    • 容器间通信中断 (nginx → php/mysql 等代理失败)"
    echo -e "    • 宿主机无法通过容器 IP 访问服务"
    echo -e "    • 容器无法访问外网"
    echo ""
    echo -e "${CYAN:-}修复步骤:${NC:-}"
    echo -e "  1. 将 ${CYAN:-}/etc/default/ufw${NC:-} 中:"
    echo -e "       DEFAULT_FORWARD_POLICY=\"DROP\""
    echo -e "     改为:"
    echo -e "       DEFAULT_FORWARD_POLICY=\"ACCEPT\""
    echo -e "  2. ${CYAN:-}sudo ufw reload${NC:-}          — 令新策略生效"
    echo -e "  3. ${CYAN:-}sudo systemctl restart docker${NC:-} — Docker 重建 iptables 规则"
    echo ""
    echo -e "${YELLOW:-}注意: 步骤 3 会短暂中断所有运行中的容器。${NC:-}"
    echo ""

    if ! _fw_can_sudo; then
        if ! _fw_request_sudo; then
            _fw_log_warn "无 sudo 权限，请手动执行上述步骤"
            return 1
        fi
    fi

    local answer="n"
    if _fw_is_interactive; then
        read -r -p "是否自动应用上述修复? [y/N] " answer </dev/tty || answer="n"
    else
        _fw_log_info "检测到非交互环境，跳过 UFW FORWARD 策略自动修复"
        return 1
    fi

    case "$answer" in
        [yY]|[yY][eE][sS])
            _fw_log_info "正在修改 /etc/default/ufw ..."
            if ! _fw_run_sudo sed -i \
                    's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' \
                    /etc/default/ufw; then
                _fw_log_error "修改 /etc/default/ufw 失败，请手动修改"
                return 1
            fi
            _fw_log_success "DEFAULT_FORWARD_POLICY 已改为 ACCEPT"

            _fw_log_info "正在重新加载 UFW 规则..."
            if ! _fw_run_sudo ufw reload >/dev/null 2>&1; then
                _fw_log_error "UFW reload 失败"
                return 1
            fi
            _fw_log_success "UFW 规则已重新加载"

            _fw_log_info "正在重启 Docker 守护进程以重建 iptables 规则..."
            if ! _fw_run_sudo systemctl restart docker; then
                _fw_log_error "Docker 守护进程重启失败"
                return 1
            fi

            local retries=0
            while [[ $retries -lt 15 ]]; do
                cr_cmd info >/dev/null 2>&1 && break
                sleep 1
                retries=$((retries + 1))
            done

            if cr_cmd info >/dev/null 2>&1; then
                _fw_log_success "UFW + Docker 修复完成，容器网络已恢复正常"
                return 0
            else
                _fw_log_error "Docker 守护进程重启后未能正常响应"
                return 1
            fi
            ;;
        *)
            _fw_log_info "已跳过自动修复，请手动执行:"
            echo -e "  sudo sed -i 's/DEFAULT_FORWARD_POLICY=\"DROP\"/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/' /etc/default/ufw"
            echo -e "  sudo ufw reload && sudo systemctl restart docker"
            return 1
            ;;
    esac
}

# ==========================================
# 3. Port extraction from compose config
# ==========================================
# Outputs lines of "host_ip:host_port/protocol"
# e.g. "0.0.0.0:80/tcp", "127.0.0.1:3306/tcp"

_fw_is_interactive() {
    [[ -r /dev/tty ]] && return 0
    return 1
}

# Whether to auto-add missing firewall rules without interactive confirmation.
# Accepted truthy values: 1/true/yes/on (case-insensitive)
_fw_auto_allow_missing_ports() {
    local v="${FW_AUTO_ALLOW_MISSING_PORTS:-false}"
    case "${v,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

_fw_resolve_bridge_name() {
    local network_name="${1:-$_FW_DOCKER_NETWORK_NAME}"
    local fallback_bridge_name="${2:-$_FW_DOCKER_BRIDGE_NAME}"
    local detected_bridge_name=""

    if ! cr_cmd info >/dev/null 2>&1; then
        echo "$fallback_bridge_name"
        return 0
    fi

    if cr_cmd network inspect "$network_name" >/dev/null 2>&1; then
        detected_bridge_name=$(cr_cmd network inspect "$network_name" \
            --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null) || true

        if [[ -n "$detected_bridge_name" && "$detected_bridge_name" != "<no value>" ]]; then
            echo "$detected_bridge_name"
            return 0
        fi

        detected_bridge_name=$($CR network inspect "$network_name" \
            --format '{{.Id}}' 2>/dev/null | cut -c1-12) || true

        if [[ -n "$detected_bridge_name" ]]; then
            echo "br-$detected_bridge_name"
            return 0
        fi
    fi

    echo "$fallback_bridge_name"
    return 0
}

_fw_extract_ports() {
    local compose_cmd="$1"
    local compose_files="$2"
    local -a compose_cmd_args=()
    local -a compose_args=()

    # Safely split compose_cmd and compose_files into arguments without using eval.
    # This supports the current caller contract where compose_cmd may be
    # "docker compose" and compose_files is passed as a single string like:
    # -f docker-compose.yml -f docker-compose.dev.yml
    read -r -a compose_cmd_args <<< "$compose_cmd"
    if [[ -n "$compose_files" ]]; then
        read -r -a compose_args <<< "$compose_files"
    fi

    # Try JSON format with jq first (most reliable)
    if command -v jq >/dev/null 2>&1; then
        local json_output
        json_output=$("${compose_cmd_args[@]}" "${compose_args[@]}" config --format json 2>/dev/null) || true

        if [[ -n "$json_output" ]]; then
            local ports
            ports=$(echo "$json_output" | jq -r \
                '.services | to_entries[] | .key as $svc | .value.ports[]? | "\(.host_ip // "0.0.0.0"):\(.published)/\(.protocol // "tcp")"' \
                2>/dev/null) || true

            if [[ -n "$ports" ]]; then
                # Deduplicate and normalize
                echo "$ports" | sort -u
                return 0
            fi
        fi
    fi

    # Fallback: parse docker compose config YAML output with awk.
    # This fallback only supports short-form port mappings and is best-effort.
    _fw_log_warn "jq 解析失败，使用受限的 YAML 备用方式提取端口（仅支持短格式 ports）"
    local config_output
    config_output=$("${compose_cmd_args[@]}" "${compose_args[@]}" config 2>/dev/null) || true

    if [[ -z "$config_output" ]]; then
        _fw_log_warn "无法获取 compose 配置，跳过端口提取"
        return 1
    fi

    # Extract short-form port mappings from YAML like:
    #   - "127.0.0.1:9200:9200"
    #   - "8080:80"
    # Long-form mappings such as `published:` are intentionally not parsed here
    # because ad-hoc YAML parsing is too error-prone.
    echo "$config_output" | awk '
    /^[[:space:]]*-[[:space:]]*"?[0-9]/ {
        gsub(/[" ]/, "")
        sub(/^[[:space:]]*-[[:space:]]*/, "")
        n = split($0, parts, ":")
        if (n == 3) {
            # ip:hostport:containerport
            printf "%s:%s/tcp\n", parts[1], parts[2]
        } else if (n == 2) {
            # hostport:containerport
            printf "0.0.0.0:%s/tcp\n", parts[1]
        }
    }
    ' | sort -u
    return 0
}

# ==========================================
# 4. Docker bridge forwarding check (CRITICAL)
# ==========================================
# This is the most important check. It verifies Docker's iptables
# chains are intact and container-to-container communication works.
#
# Returns:
#   0 = healthy
#   1 = broken, user declined fix
#   2 = cannot determine

_fw_check_bridge_interface() {
    local bridge_name="$1"
    local network_name="$2"

    if ip link show "$bridge_name" >/dev/null 2>&1; then
        _fw_log_success "网桥接口 ${bridge_name} 存在"
        return 0
    fi

    if $CR network inspect "$network_name" >/dev/null 2>&1; then
        _fw_log_warn "容器网络 ${network_name} 已定义，但网桥接口 ${bridge_name} 尚未创建"
        _fw_log_info "网桥将在首个容器启动时自动创建，跳过后续网桥检查"
        return 1
    fi

    _fw_log_info "容器网络 ${network_name} 尚未创建，将在首次 compose up 时自动创建"
    return 2
}

# Returns 0 if Docker daemon has "iptables": false in its configuration,
# meaning Docker deliberately does not manage iptables rules — DOCKER/* chains
# will never exist and checking for them would always produce false-positive errors.
_fw_is_docker_iptables_disabled() {
    # Method 1: parse daemon.json directly (fastest, no extra subprocess)
    local daemon_json_path="/etc/docker/daemon.json"
    if [[ -f "$daemon_json_path" ]]; then
        if command -v jq >/dev/null 2>&1; then
            local val
            val=$(jq -r '.iptables | tostring' "$daemon_json_path" 2>/dev/null) || true
            [[ "$val" == "false" ]] && return 0
        else
            # Fallback: a simple grep is reliable for this scalar boolean key
            if grep -qE '"iptables"[[:space:]]*:[[:space:]]*false' "$daemon_json_path" 2>/dev/null; then
                return 0
            fi
        fi
    fi

    # Method 2: 容器运行时 info — authoritative source, slightly slower
    local cr_info
    cr_info=$(cr_cmd info 2>/dev/null) || return 1
    if echo "$cr_info" | grep -qi 'iptables: false'; then
        return 0
    fi

    return 1  # iptables management is enabled (Docker default)
}

_fw_check_docker_iptables_rules() {
    local bridge_name="$1"
    local iptables_ok=true
    local can_read_iptables=false

    # If Docker is configured with "iptables": false it deliberately never creates
    # DOCKER / DOCKER-USER / DOCKER-ISOLATION-STAGE-1 chains. Checking for them
    # would always fail — that is expected behaviour, not a fault. Skip entirely.
    if _fw_is_docker_iptables_disabled; then
        # _fw_log_info "Docker 已配置 iptables=false，跳过 iptables 链检查（符合预期）"
        echo "true:true"
        return 0
    fi

    # 若当前无 sudo 缓存且非 root，先交互式请求密码授权
    if ! _fw_can_sudo && [[ "$(id -u)" -ne 0 ]]; then
        _fw_request_sudo || true
    fi

    if _fw_can_sudo || [[ "$(id -u)" -eq 0 ]]; then
        can_read_iptables=true

        if _fw_run_sudo iptables -L DOCKER -n >/dev/null 2>&1; then
            _fw_log_success "iptables DOCKER 链存在"
        else
            _fw_log_error "iptables DOCKER 链不存在 — Docker 网络规则可能被清除"
            iptables_ok=false
        fi

        if _fw_run_sudo iptables -L DOCKER-USER -n >/dev/null 2>&1; then
            _fw_log_success "iptables DOCKER-USER 链存在"
        else
            _fw_log_warn "iptables DOCKER-USER 链不存在"
            iptables_ok=false
        fi

        if _fw_run_sudo iptables -L DOCKER-ISOLATION-STAGE-1 -n >/dev/null 2>&1; then
            _fw_log_success "iptables DOCKER-ISOLATION-STAGE-1 链存在"
        elif _fw_run_sudo iptables -L DOCKER-ISOLATION -n >/dev/null 2>&1; then
            _fw_log_success "iptables DOCKER-ISOLATION 链存在"
        else
            # 在某些与 ufw/nftables 共存的现代 Linux 系统上，Docker 可能不会生成传统的 ISOLATION 链
            # 或者防火墙管理器可能已将其重写，我们将此作为调试信息而非警告
            # _fw_log_warn "iptables DOCKER-ISOLATION 链（或 STAGE-1）不存在"
            :
        fi

        local forward_rules
        forward_rules=$(_fw_run_sudo iptables -S FORWARD 2>/dev/null) || true

        if echo "$forward_rules" | grep -q "DOCKER-USER"; then
            :
        else
            # 同理，某些环境下可能缺少明确的引用，不再视为严重缺失
            # _fw_log_warn "FORWARD 链中缺少 DOCKER-USER 引用"
            :
        fi

        if echo "$forward_rules" | grep -q -E "DOCKER-ISOLATION"; then
            :
        else
            :
        fi

        if echo "$forward_rules" | grep -q -- "-o ${bridge_name}"; then
            _fw_log_success "FORWARD 链允许网桥 ${bridge_name} 的出站流量"
        else
            # _fw_log_warn "FORWARD 链中未找到网桥 ${bridge_name} 的转发规则"
            # 即使通过 grep 未找到文本匹配，只要底层 nftables 或 ufw-docker 放行了即可，这里不判断报错
            :
        fi

        if [[ "$iptables_ok" == "true" ]]; then
            _fw_log_success "iptables Docker 规则检查全部通过"
        fi
    else
        _fw_log_warn "无 sudo 权限，无法直接检查 iptables 规则，将通过容器连通性测试判断"
    fi

    echo "${iptables_ok}:${can_read_iptables}"
    return 0
}

# $4 = docker_iptables_disabled ("true"/"false")，用于在 iptables=false 模式下降级错误级别
_fw_handle_connectivity_result() {
    local connectivity_result="$1"
    local iptables_ok="$2"
    local can_read_iptables="$3"
    local docker_iptables_disabled="${4:-false}"

    case "$connectivity_result" in
        pass)
            _fw_log_success "容器间连通性测试通过"
            if [[ "$can_read_iptables" == "true" && "$iptables_ok" == "false" ]]; then
                _fw_log_warn "iptables 规则不完整，但容器间通信正常。建议重启 Docker 以恢复完整规则"
            fi
            return 0
            ;;
        fail)
            if [[ "$docker_iptables_disabled" == "true" ]]; then
                # iptables=false 模式：Docker 不写 iptables 规则，探针超时不等于网桥损坏。
                # 可能是容器内工具受限、探针端口被第三方规则 DROP，或内核转发参数未就绪。
                # 降级为 WARN，不打印"网桥已损坏"的误导性 ERROR。
                _fw_log_warn "容器间连通性探针未通过（iptables=false 模式，可能为误报）"
                _fw_log_info "实际服务通信是否正常请观察容器日志；如确有问题请参阅下方诊断指引"
            else
                _fw_log_error "容器间 TCP 连通性测试失败 — 网桥转发已损坏!"
            fi
            return 1
            ;;
        skip)
            if [[ "$can_read_iptables" == "true" && "$iptables_ok" == "true" ]]; then
                _fw_log_info "无足够运行中的容器进行连通性测试，但 iptables 规则正常"
                return 0
            elif [[ "$can_read_iptables" == "true" && "$iptables_ok" == "false" ]]; then
                _fw_log_warn "iptables 规则不完整，且无法进行容器连通性测试"
                return 1
            else
                _fw_log_info "无法执行连通性测试，也无法检查 iptables 规则"
                return 2
            fi
            ;;
        *)
            _fw_log_info "无法确定容器连通性测试结果"
            return 2
            ;;
    esac
}

_fw_check_docker_bridge() {
    local bridge_name="${1:-$_FW_DOCKER_BRIDGE_NAME}"
    local network_name="${2:-$_FW_DOCKER_NETWORK_NAME}"
    local bridge_check_result
    local iptables_status
    local iptables_ok
    local can_read_iptables
    local connectivity_result
    local connectivity_status

    bridge_name=$(_fw_resolve_bridge_name "$network_name" "$bridge_name")

    _fw_log_info "开始检查 Docker 网桥转发状态..."
    _fw_log_info "网桥: ${CYAN:-}${bridge_name}${NC:-}  网络: ${CYAN:-}${network_name}${NC:-}"

    local _cr_cmd="${CR:-docker}"
    if ! "$_cr_cmd" info >/dev/null 2>&1; then
        _fw_log_error "Docker 守护进程未运行，请先启动 Docker"
        return 2
    fi
    _fw_log_success "Docker 守护进程运行正常"

    _fw_check_bridge_interface "$bridge_name" "$network_name"
    bridge_check_result=$?
    case "$bridge_check_result" in
        0)
            ;;
        1|2)
            return 0
            ;;
    esac

    iptables_status=$(_fw_check_docker_iptables_rules "$bridge_name")
    iptables_ok="${iptables_status%%:*}"
    can_read_iptables="${iptables_status##*:}"

    # 提前检测 iptables=false，后续诊断与修复提案需要据此分支
    local docker_iptables_disabled=false
    if _fw_is_docker_iptables_disabled; then
        docker_iptables_disabled=true
    fi

    connectivity_result=$(_fw_test_container_connectivity "$network_name")
    connectivity_status=$?
    if [[ $connectivity_status -ne 0 || -z "$connectivity_result" ]]; then
        connectivity_result="skip"
    fi

    _fw_handle_connectivity_result "$connectivity_result" "$iptables_ok" "$can_read_iptables" "$docker_iptables_disabled"
    connectivity_status=$?

    if [[ $connectivity_status -eq 0 ]]; then
        return 0
    fi

    if [[ "$iptables_ok" == "false" || "$connectivity_result" == "fail" ]]; then
        # iptables=false 环境：Docker 不管理 iptables，重启 daemon 毫无意义，
        # 且会导致所有容器（nginx/php 等）全部被停止——副作用远大于收益。
        # 此时只给出诊断信息，提示用户检查内核转发参数或 nftables 规则。
        if [[ "$docker_iptables_disabled" == "true" ]]; then
            _fw_show_bridge_diagnostic_no_iptables "$bridge_name"
            return 1
        fi

        _fw_show_bridge_diagnostic "$bridge_name"

        local fw_type
        fw_type=$(_fw_detect_type)
        local fw_running_inner
        fw_running_inner=$(_fw_scan_running "$(_fw_scan_installed)")

        if echo "$fw_running_inner" | grep -qw "ufw" || [[ "$fw_type" == "ufw" ]]; then
            _fw_suggest_ufw_fix
        fi

        _fw_offer_docker_restart
        local restart_result=$?

        if [[ $restart_result -eq 0 ]]; then
            return 0
        else
            return 1
        fi
    fi

    return 2
}

# Ensure nftables forward chain allows Docker bridge egress traffic.
# This specifically fixes "container can talk to peers but cannot reach Internet"
# when inet filter forward policy is drop and no bridge egress accept rule exists.
_fw_ensure_nft_docker_egress() {
    local bridge_name="${1:-$_FW_DOCKER_BRIDGE_NAME}"
    local network_name="${2:-$_FW_DOCKER_NETWORK_NAME}"
    local fw_type="${3:-}"
    local fw_active="${4:-}"

    [[ "$fw_type" != "nftables" ]] && return 0
    [[ "$fw_active" != "true" ]] && return 0

    bridge_name=$(_fw_resolve_bridge_name "$network_name" "$bridge_name")

    # Need sudo/root to inspect and modify nft rules.
    if ! _fw_can_sudo; then
        _fw_log_warn "无 sudo 权限，跳过 Docker 出站修复检查（nftables）"
        _fw_log_info "如容器无法访问外网，请手动放行: nft add rule inet filter forward iifname \"$bridge_name\" oifname != \"$bridge_name\" accept"
        return 0
    fi

    local forward_rules=""
    forward_rules=$(_fw_run_sudo nft list chain inet filter forward 2>/dev/null) || true
    if [[ -z "$forward_rules" ]]; then
        _fw_log_info "未检测到 inet filter forward 链，跳过 Docker 出站修复检查"
        return 0
    fi

    # Rule 1: bridge -> non-bridge egress allow
    if ! echo "$forward_rules" | grep -q "iifname \"$bridge_name\" oifname != \"$bridge_name\" accept"; then
        if _fw_run_sudo nft add rule inet filter forward iifname "$bridge_name" oifname "!=" "$bridge_name" accept >/dev/null 2>&1; then
            _fw_log_success "已修复 nftables Docker 出站规则: ${bridge_name} -> 外网"
        else
            _fw_log_warn "添加 nftables Docker 出站规则失败: iifname \"$bridge_name\" oifname != \"$bridge_name\" accept"
        fi
    fi

    # Rule 2: non-bridge -> bridge return path for established connections
    if ! echo "$forward_rules" | grep -q "iifname != \"$bridge_name\" oifname \"$bridge_name\" ct state established,related accept"; then
        if _fw_run_sudo nft add rule inet filter forward iifname "!=" "$bridge_name" oifname "$bridge_name" ct state established,related accept >/dev/null 2>&1; then
            _fw_log_success "已修复 nftables Docker 回程规则: 外网 -> ${bridge_name}"
        else
            _fw_log_warn "添加 nftables Docker 回程规则失败: iifname != \"$bridge_name\" oifname \"$bridge_name\" ct state established,related accept"
        fi
    fi
}

# Ensure nftables NAT postrouting includes Docker subnet masquerade.
# Without this, containers on bridge network cannot reach Internet even if forward rules are present.
_fw_ensure_nft_docker_nat() {
    local bridge_name="${1:-$_FW_DOCKER_BRIDGE_NAME}"
    local network_name="${2:-$_FW_DOCKER_NETWORK_NAME}"
    local fw_type="${3:-}"
    local fw_active="${4:-}"

    [[ "$fw_type" != "nftables" ]] && return 0
    [[ "$fw_active" != "true" ]] && return 0

    bridge_name=$(_fw_resolve_bridge_name "$network_name" "$bridge_name")

    local docker_subnet=""
    docker_subnet=$($CR network inspect "$network_name" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)
    if [[ -z "$docker_subnet" || "$docker_subnet" == "<no value>" ]]; then
        _fw_log_warn "无法获取 Docker 网络 ${network_name} 子网，跳过 NAT 自愈"
        return 0
    fi

    if ! _fw_can_sudo; then
        _fw_log_warn "无 sudo 权限，跳过 Docker NAT 自愈检查（nftables）"
        _fw_log_info "如容器无法访问外网，请手动执行: nft add rule ip nat POSTROUTING ip saddr ${docker_subnet} oifname != \"$bridge_name\" masquerade"
        return 0
    fi

    # Ensure table/chain exist (idempotent).
    _fw_run_sudo nft list table ip nat >/dev/null 2>&1 || _fw_run_sudo nft add table ip nat >/dev/null 2>&1 || true
    _fw_run_sudo nft list chain ip nat POSTROUTING >/dev/null 2>&1 || \
        _fw_run_sudo nft add chain ip nat POSTROUTING "{ type nat hook postrouting priority srcnat; policy accept; }" >/dev/null 2>&1 || true

    local postrouting_rules=""
    postrouting_rules=$(_fw_run_sudo nft list chain ip nat POSTROUTING 2>/dev/null) || true

    if ! echo "$postrouting_rules" | grep -q "ip saddr ${docker_subnet} oifname != \"${bridge_name}\" masquerade"; then
        if _fw_run_sudo nft add rule ip nat POSTROUTING ip saddr "$docker_subnet" oifname "!=" "$bridge_name" masquerade >/dev/null 2>&1; then
            _fw_log_success "已修复 nftables Docker NAT 规则: ${docker_subnet} -> masquerade"
        else
            _fw_log_warn "添加 nftables Docker NAT 规则失败: ${docker_subnet}"
        fi
    fi
}

# Test TCP connectivity between two containers on the same Docker network.
# Outputs one of: "pass", "fail", or "skip" via stdout.
#
# 测试策略（按优先级）：
#   1. ICMP ping —— 最直接，不依赖端口开放状态，也不受"端口未监听返回RST"以外的干扰
#   2. /dev/tcp 连向目标容器已开放的端口 —— 取得 refused/connected 均视为可达
#   3. /dev/tcp 连向随机高端口（59999）—— 兜底，refused=pass；timeout=fail
#   4. wget/curl 备用 —— bash 不可用时尝试
#
# 改进点（相对旧版）：
#   - 优先用 ping 判断 IP 层可达性，避免高端口 DROP 导致的误报 fail
#   - 自动探测目标容器已监听的端口作为 TCP 测试端口，提升 refused 命中率
#   - EXIT_CODE:1（一般错误，非超时）不再直接判定为 fail，改为 skip
_fw_test_container_connectivity() {
    local network_name="$1"

    local containers
    containers=$($CR network inspect "$network_name" \
        --format '{{range $k, $v := .Containers}}{{$k}} {{end}}' 2>/dev/null) || true

    if [[ -z "$containers" ]]; then
        echo "skip"
        return 0
    fi

    local -a container_ids=()
    local -a container_names=()
    local -a container_ips=()

    for cid_full in $containers; do
        local cid="${cid_full:0:12}"
        local state
        state=$($CR inspect --format '{{.State.Running}}' "$cid" 2>/dev/null) || continue
        [[ "$state" != "true" ]] && continue

        local cname
        cname=$($CR inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||') || continue

        local cip
        cip=$($CR inspect --format "{{(index .NetworkSettings.Networks \"${network_name}\").IPAddress}}" "$cid" 2>/dev/null) || continue

        if [[ -n "$cip" && "$cip" != "<no value>" ]]; then
            container_ids+=("$cid")
            container_names+=("$cname")
            container_ips+=("$cip")
        fi
    done

    if [[ ${#container_ids[@]} -lt 2 ]]; then
        echo "skip"
        return 0
    fi

    local src_id="${container_ids[0]}"
    local src_name="${container_names[0]}"
    local dst_id="${container_ids[1]}"
    local dst_ip="${container_ips[1]}"
    local dst_name="${container_names[1]}"

    _fw_log_info "连通性测试: ${src_name} -> ${dst_name} (${dst_ip})"

    # ----------------------------------------------------------------
    # 策略 1：ICMP ping —— IP 层可达性，最可靠，不受端口过滤影响
    # ----------------------------------------------------------------
    local ping_out
    ping_out=$(timeout 5 $CR exec "$src_id" ping -c 1 -W 2 "$dst_ip" 2>&1) || true

    if echo "$ping_out" | grep -qE "1 (packets )?received|1 received"; then
        echo "pass"
        return 0
    fi

    if echo "$ping_out" | grep -qE "0 (packets )?received|Network is unreachable|No route to host|Destination Host Unreachable"; then
        echo "fail"
        return 0
    fi

    # ping 不可用（容器内无该命令，或被容器 capabilities 限制），进入 TCP 测试
    # ----------------------------------------------------------------
    # 策略 2：连接目标容器已监听的端口（refused 或 connected 均证明可达）
    # ----------------------------------------------------------------
    local dst_listen_port=""
    # 从容器暴露的端口中取第一个有效端口（只需 IP 层可达性，端口内容无关）
    if command -v jq >/dev/null 2>&1; then
        dst_listen_port=$($CR inspect "$dst_id" 2>/dev/null \
            | jq -r '.[0].NetworkSettings.Ports | to_entries[]
                     | select(.value != null and (.value | length) > 0)
                     | .key | split("/")[0]' 2>/dev/null \
            | grep -E '^[0-9]+$' | head -1) || dst_listen_port=""
    fi

    # 策略 3：兜底端口（无监听端口可用时）
    local test_port="${dst_listen_port:-59999}"

    local test_output
    test_output=$(timeout 6 $CR exec "$src_id" bash -c \
        "timeout 3 bash -c 'echo > /dev/tcp/${dst_ip}/${test_port}' 2>&1; echo \"EXIT_CODE:\$?\"" 2>&1) || true

    # Connection refused / reset → 数据包到达目标，网络可达 → pass
    if echo "$test_output" | grep -qi "refused\|reset"; then
        echo "pass"
        return 0
    fi

    # 明确的网络不可达错误 → fail
    if echo "$test_output" | grep -qi "no route\|network.unreachable\|host.unreachable\|unreachable"; then
        echo "fail"
        return 0
    fi

    # timeout 3（内层 bash timeout）超时 → EXIT_CODE:124 → fail（包中途被 DROP）
    if echo "$test_output" | grep -q "EXIT_CODE:124"; then
        echo "fail"
        return 0
    fi

    # 外层 timeout 6 超时，docker exec 无 EXIT_CODE 输出 → fail
    if ! echo "$test_output" | grep -q "EXIT_CODE:"; then
        # 若是 bash/OCI 错误导致无 EXIT_CODE，单独处理（见下方）
        if echo "$test_output" | grep -qi "not found\|no such file\|OCI runtime\|executable"; then
            : # 进入下方 bash-不可用分支
        else
            echo "fail"
            return 0
        fi
    fi

    # 连接成功（EXIT_CODE:0，端口恰好在监听）→ pass
    if echo "$test_output" | grep -q "EXIT_CODE:0"; then
        echo "pass"
        return 0
    fi

    # ----------------------------------------------------------------
    # 策略 4：bash 不可用（alpine/distroless 等），尝试 wget/curl
    # ----------------------------------------------------------------
    if echo "$test_output" | grep -qi "not found\|no such file\|OCI runtime\|executable"; then
        _fw_log_info "容器 ${src_name} 中 bash 不可用，尝试备用测试方法..."

        # 尝试 wget
        local alt_test
        alt_test=$(timeout 5 $CR exec "$src_id" wget -q -O /dev/null --timeout=3 \
            "http://${dst_ip}:${test_port}/" 2>&1) || true
        if echo "$alt_test" | grep -qi "refused\|connected"; then
            echo "pass"
            return 0
        elif echo "$alt_test" | grep -qi "timed out\|no route\|unreachable"; then
            echo "fail"
            return 0
        fi

        # 尝试 curl
        local curl_test
        curl_test=$(timeout 5 $CR exec "$src_id" curl -s --connect-timeout 3 \
            "http://${dst_ip}:${test_port}/" 2>&1) || true
        if echo "$curl_test" | grep -qi "refused\|connected\|Empty reply"; then
            echo "pass"
            return 0
        elif echo "$curl_test" | grep -qi "timed out\|no route\|unreachable\|Could not connect"; then
            echo "fail"
            return 0
        fi
    fi

    # EXIT_CODE:1 等一般性错误（非超时、非网络错误）→ 无法判断，skip
    echo "skip"
    return 0
}

# Display diagnostic info when bridge forwarding is broken
_fw_show_bridge_diagnostic() {
    local bridge_name="$1"

    echo ""
    echo -e "${RED:-}╔══════════════════════════════════════════════════════════════╗${NC:-}"
    echo -e "${RED:-}║  ⚠  Docker 网桥转发规则已损坏                              ║${NC:-}"
    echo -e "${RED:-}╚══════════════════════════════════════════════════════════════╝${NC:-}"
    echo ""
    echo -e "${YELLOW:-}诊断信息:${NC:-}"
    echo -e "  网桥接口:     ${bridge_name}"
    echo -e "  可能原因:     防火墙 (UFW/firewalld) 重载时清除了 Docker 的 iptables 规则"
    echo -e "  影响范围:     ${RED:-}所有容器间通信完全中断${NC:-}"
    echo ""

    # Show current FORWARD chain default policy if accessible
    if _fw_can_sudo; then
        local forward_policy
        forward_policy=$(_fw_run_sudo iptables -S FORWARD 2>/dev/null | head -1) || true
        if [[ -n "$forward_policy" ]]; then
            echo -e "  FORWARD 策略:  ${forward_policy}"
        fi

        local docker_chains
        docker_chains=$(_fw_run_sudo iptables -L -n 2>/dev/null \
            | grep -c "^Chain DOCKER" 2>/dev/null) || docker_chains=0
        echo -e "  Docker 链数量: ${docker_chains}"
    fi
    echo ""
}

# Display diagnostic info when bridge forwarding is broken in iptables=false mode.
# In this mode Docker never creates DOCKER/* chains, so restarting the daemon is
# pointless and harmful (it stops ALL running containers).
# Instead we guide the user to check kernel forwarding and nftables rules.
_fw_show_bridge_diagnostic_no_iptables() {
    local bridge_name="$1"

    echo ""
    echo -e "${YELLOW:-}╔══════════════════════════════════════════════════════════════╗${NC:-}"
    echo -e "${YELLOW:-}║  ⚠  容器间连通性测试未通过（iptables=false 模式）          ║${NC:-}"
    echo -e "${YELLOW:-}╚══════════════════════════════════════════════════════════════╝${NC:-}"
    echo ""
    echo -e "${YELLOW:-}诊断信息:${NC:-}"
    echo -e "  网桥接口:     ${bridge_name}"
    echo -e "  Docker 模式:  ${CYAN:-}iptables=false${NC:-}（Docker 不管理 iptables 规则）"
    echo -e "  注意:         重启 Docker daemon 在此模式下${RED:-}无法${NC:-}修复网络问题，"
    echo -e "                且会导致所有容器（nginx/php 等）短暂停止，请勿执行。"
    echo ""
    echo -e "${CYAN:-}请按以下顺序排查:${NC:-}"
    echo ""
    echo -e "  1. 检查内核 IP 转发是否开启:"
    echo -e "     ${CYAN:-}cat /proc/sys/net/ipv4/ip_forward${NC:-}   # 应为 1"
    echo -e "     若为 0，执行: ${CYAN:-}sudo sysctl -w net.ipv4.ip_forward=1${NC:-}"
    echo -e "     持久化: 在 /etc/sysctl.conf 中添加 net.ipv4.ip_forward=1"
    echo ""
    echo -e "  2. 检查 nftables/iptables 中是否有 FORWARD DROP 规则阻断网桥流量:"
    echo -e "     ${CYAN:-}sudo nft list ruleset | grep -A5 'hook forward'${NC:-}"
    echo -e "     ${CYAN:-}sudo iptables -S FORWARD${NC:-}"
    echo -e "     若 FORWARD 默认策略为 DROP 且无放行网桥的规则，需手动添加:"
    echo -e "     ${CYAN:-}sudo iptables -I FORWARD -i ${bridge_name} -j ACCEPT${NC:-}"
    echo -e "     ${CYAN:-}sudo iptables -I FORWARD -o ${bridge_name} -j ACCEPT${NC:-}"
    echo ""
    echo -e "  3. 若使用 mihomo/clash 等代理工具，确认其 nft 规则集未 DROP 转发流量。"
    echo ""
    echo -e "  4. 若上述检查均正常，实际服务通信可能不受影响（连通性探针受限于"
    echo -e "     容器内可用工具），可先尝试启动服务并观察实际行为。"
    echo ""
}

# Suggest permanent UFW fix
_fw_suggest_ufw_fix() {
    echo -e "${YELLOW:-}══════════════════════════════════════════════════════════════${NC:-}"
    echo -e "${BOLD:-}永久修复方案 (UFW + Docker) — 共 3 步:${NC:-}"
    echo ""
    echo -e "${BOLD:-}步骤 1${NC:-}  修改 UFW FORWARD 策略（关键）"
    echo -e "  编辑 ${CYAN:-}/etc/default/ufw${NC:-}，将:"
    echo -e "    ${RED:-}DEFAULT_FORWARD_POLICY=\"DROP\"${NC:-}"
    echo -e "  改为:"
    echo -e "    ${GREEN:-}DEFAULT_FORWARD_POLICY=\"ACCEPT\"${NC:-}"
    echo ""
    echo -e "${BOLD:-}步骤 2${NC:-}  将以下规则追加到 ${CYAN:-}/etc/ufw/after.rules${NC:-} 末尾:"
    echo ""
    echo -e "${GREEN:-}${_FW_UFW_AFTER_RULES_SNIPPET}${NC:-}"
    echo ""
    echo -e "${BOLD:-}步骤 3${NC:-}  重新加载防火墙并重启 Docker:"
    echo -e "  ${CYAN:-}sudo ufw reload && sudo systemctl restart docker${NC:-}"
    echo ""
    echo -e "完成后 UFW 重载时将不再破坏 Docker 的 iptables 转发规则。"
    echo -e "${YELLOW:-}══════════════════════════════════════════════════════════════${NC:-}"
    echo ""
}

# Offer to restart Docker daemon to restore iptables rules
# Returns 0 if restarted successfully, 1 otherwise
_fw_offer_docker_restart() {
    # 检测当前运行时，选择正确的服务名
    local _cr_service="docker"
    local _cr_label="Docker"
    local _cr_bin="docker"
    if cr_is_podman; then
        _cr_service="podman.socket"
        _cr_label="Podman"
        _cr_bin="podman"
    fi

    echo -e "${BOLD:-}立即修复:${NC:-} 重启 ${_cr_label} 守护进程可恢复 iptables 规则"
    echo -e "${YELLOW:-}注意: 重启 ${_cr_label} 会短暂中断所有运行中的容器${NC:-}"
    echo ""

    # Check if we can get sudo
    if ! _fw_can_sudo; then
        if ! _fw_request_sudo; then
            _fw_log_warn "无 sudo 权限，无法重启 ${_cr_label}。请手动执行: sudo systemctl restart ${_cr_service}"
            return 1
        fi
    fi

    local answer="n"
    if _fw_is_interactive; then
        read -r -p "是否立即重启 ${_cr_label} 守护进程? [y/N] " answer </dev/tty || answer="n"
    else
        _fw_log_info "检测到非交互环境，跳过 ${_cr_label} 重启提示"
    fi

    case "$answer" in
        [yY]|[yY][eE][sS])
            _fw_log_info "正在重启 ${_cr_label} 守护进程..."
            if _fw_run_sudo systemctl restart "$_cr_service"; then
                # Wait for runtime to be ready
                local retries=0
                while [[ $retries -lt 15 ]]; do
                    if "$_cr_bin" info >/dev/null 2>&1; then
                        break
                    fi
                    sleep 1
                    retries=$((retries + 1))
                done

                if "$_cr_bin" info >/dev/null 2>&1; then
                    _fw_log_success "${_cr_label} 守护进程重启完成"
                    # Verify iptables rules are restored (Docker 模式才需要检查)
                    if ! cr_is_podman && _fw_can_sudo; then
                        if _fw_run_sudo iptables -L DOCKER -n >/dev/null 2>&1; then
                            _fw_log_success "Docker iptables 规则已恢复"
                        else
                            _fw_log_warn "Docker iptables 规则可能未完全恢复，请检查容器网络"
                        fi
                    fi
                    return 0
                else
                    _fw_log_error "${_cr_label} 守护进程重启后未能正常响应"
                    return 1
                fi
            else
                _fw_log_error "${_cr_label} 守护进程重启失败"
                return 1
            fi
            ;;
        *)
            _fw_log_info "已跳过 ${_cr_label} 重启。如需手动修复，请执行: ${CYAN:-}sudo systemctl restart ${_cr_service}${NC:-}"
            return 1
            ;;
    esac
}

# ==========================================
# 5. Firewall port checking
# ==========================================
# Returns: 0=allowed, 1=blocked, 2=unknown

_fw_check_port() {
    local fw_type="$1"
    local port="$2"
    local protocol="${3:-tcp}"

    case "$fw_type" in
        ufw)
            if ! _fw_can_sudo; then
                return 2
            fi
            local ufw_status
            ufw_status=$(_fw_run_sudo ufw status 2>/dev/null) || return 2
            # UFW output is locale-dependent (e.g. "ALLOW", "允许"), and may have leading spaces.
            # Match exact leading token only to avoid false positives like 18080 matching 8080.
            if echo "$ufw_status" | grep -qE "^[[:space:]]*${port}/${protocol}([[:space:]]|$).*(ALLOW|允许)"; then
                return 0
            fi
            if echo "$ufw_status" | grep -qE "^[[:space:]]*${port}([[:space:]]|$).*(ALLOW|允许)"; then
                return 0
            fi
            return 1
            ;;
        firewalld)
            if firewall-cmd --query-port="${port}/${protocol}" >/dev/null 2>&1; then
                return 0
            fi
            return 1
            ;;
        iptables)
            if ! _fw_can_sudo; then
                return 2
            fi
            if _fw_run_sudo iptables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
                return 0
            fi
            return 1
            ;;
        nftables)
            if ! _fw_can_sudo; then
                return 2
            fi
            local nft_rules=""
            # 优先查询 inet filter input（现代 nftables 防火墙惯用表族）；
            # 若不存在则回退到 ip filter input（仅 IPv4 的传统写法）。
            # 两者都不存在说明没有 INPUT 过滤链，端口视为开放（return 0）。
            if ! nft_rules=$(_fw_run_sudo nft list chain inet filter input 2>/dev/null); then
                if ! nft_rules=$(_fw_run_sudo nft list chain ip filter input 2>/dev/null); then
                    # 无任何 INPUT 过滤链 → 不存在对该端口的阻断规则 → 视为开放
                    return 0
                fi
            fi
            # 形式 1：单端口
            #   tcp dport 6379 accept
            if echo "$nft_rules" | grep -qE "(^|[[:space:]])${protocol}[[:space:]]+dport[[:space:]]+${port}([[:space:]]|$).*accept([[:space:]]|$)"; then
                return 0
            fi
            # 形式 2：匿名集合（nftables-manager 等前端常用）
            #   tcp dport { 80, 443 } accept
            #   tcp dport { 8080, 8088, 9443 } accept
            local _line _set_content
            while IFS= read -r _line; do
                if echo "$_line" | grep -qE "(^|[[:space:]])${protocol}[[:space:]]+dport[[:space:]]*\{[^}]*\}.*accept"; then
                    _set_content=$(echo "$_line" | sed -n 's/.*dport[[:space:]]*{\([^}]*\)}.*/\1/p')
                    if _fw_port_in_csv_list "$port" "$_set_content"; then
                        return 0
                    fi
                fi
            done <<< "$nft_rules"
            # 形式 3：命名集合（nftables-manager 数据库白名单端口、用户自定义集合等）
            #   tcp dport @db_ports accept
            #   tcp dport @db_ports ip saddr @whitelist_ips accept
            local _set_name _set_elems
            while IFS= read -r _line; do
                if echo "$_line" | grep -qE "(^|[[:space:]])${protocol}[[:space:]]+dport[[:space:]]+@[A-Za-z0-9_]+.*accept"; then
                    _set_name=$(echo "$_line" | sed -n 's/.*dport[[:space:]]*@\([A-Za-z0-9_]\+\).*/\1/p')
                    [[ -z "$_set_name" ]] && continue
                    _set_elems=$(_fw_dump_nft_set_elements "$_set_name") || continue
                    if _fw_port_in_csv_list "$port" "$_set_elems"; then
                        return 0
                    fi
                fi
            done <<< "$nft_rules"
            return 1
            ;;
        none)
            return 0  # No firewall = all ports open
            ;;
        *)
            return 2
            ;;
    esac
}

# ==========================================
# 6. Firewall rule addition
# ==========================================
# Returns: 0=success, 1=failure

_fw_add_port() {
    local fw_type="$1"
    local port="$2"
    local protocol="${3:-tcp}"

    # Idempotency: check if rule already exists
    _fw_check_port "$fw_type" "$port" "$protocol"
    local check_result=$?
    if [[ $check_result -eq 0 ]]; then
        _fw_log_info "端口 ${port}/${protocol} 规则已存在，跳过"
        return 0
    fi

    case "$fw_type" in
        ufw)
            if _fw_run_sudo ufw allow "${port}/${protocol}" >/dev/null 2>&1; then
                _fw_log_success "已添加 UFW 规则: ${port}/${protocol} ALLOW"
                return 0
            fi
            _fw_log_error "添加 UFW 规则失败: ${port}/${protocol}"
            return 1
            ;;
        firewalld)
            if _fw_run_sudo firewall-cmd --permanent --add-port="${port}/${protocol}" >/dev/null 2>&1; then
                _fw_log_success "已添加 firewalld 规则: ${port}/${protocol}"
                return 0
            fi
            _fw_log_error "添加 firewalld 规则失败: ${port}/${protocol}"
            return 1
            ;;
        iptables)
            if _fw_run_sudo iptables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null; then
                _fw_log_success "已添加 iptables 规则: INPUT -p ${protocol} --dport ${port} -j ACCEPT"
                return 0
            fi
            _fw_log_error "添加 iptables 规则失败: ${port}/${protocol}"
            return 1
            ;;
        nftables)
            # 优先通过 nftables-manager 添加规则：与系统现有规则风格一致，
            # 并自动持久化（避免直接 nft add rule 在重启后丢失）。
            if _fw_has_nftables_manager; then
                if _fw_run_sudo nftables-manager add-port "$port" "$protocol" >/dev/null 2>&1; then
                    _fw_log_success "已通过 nftables-manager 添加规则: ${port}/${protocol}"
                    # 不在此处调用 save：add-port 已对永久规则写盘；批量结束后再 _fw_reload_firewall 统一 save，
                    # 避免每条规则都触发持久化与多次 systemctl 操作。
                    return 0
                fi
                _fw_log_warn "nftables-manager 添加端口失败，回退到 nft 直接写入"
            fi
            if _fw_run_sudo nft add rule inet filter input "$protocol" dport "$port" accept 2>/dev/null; then
                _fw_log_success "已添加 nftables 规则: ${protocol} dport ${port} accept"
                return 0
            fi
            _fw_log_error "添加 nftables 规则失败: ${port}/${protocol}"
            return 1
            ;;
        none)
            return 0
            ;;
        *)
            _fw_log_warn "不支持的防火墙类型: ${fw_type}"
            return 1
            ;;
    esac
}

# Reload firewall after batch rule addition
_fw_reload_firewall() {
    local fw_type="$1"

    case "$fw_type" in
        ufw)
            # UFW allow commands take effect immediately, no reload needed
            return 0
            ;;
        firewalld)
            _fw_log_info "正在重新加载 firewalld 规则..."
            if _fw_run_sudo firewall-cmd --reload >/dev/null 2>&1; then
                _fw_log_success "firewalld 规则已重新加载"
                return 0
            fi
            _fw_log_error "firewalld 规则重新加载失败"
            return 1
            ;;
        iptables)
            # iptables rules are effective immediately, but not persistent across reboots
            _fw_log_warn "iptables 规则已生效，但重启后会丢失。建议使用 iptables-persistent 持久化"
            return 0
            ;;
        nftables)
            # 优先通过 nftables-manager 持久化（写入其托管的 /etc/nftables.conf）
            if _fw_has_nftables_manager; then
                if _fw_run_sudo nftables-manager save >/dev/null 2>&1; then
                    _fw_log_success "已通过 nftables-manager 持久化规则"
                    return 0
                fi
                _fw_log_warn "nftables-manager save 执行失败，规则可能未持久化"
                return 0
            fi
            _fw_log_warn "nftables 规则已生效，但重启后可能丢失。建议保存到 /etc/nftables.conf"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# ==========================================
# 7. Main entry point
# ==========================================
# Called from up.sh before docker compose up.
# Always returns 0 — this script is advisory and must never block startup.
#
# Arguments:
#   $1            - compose_files string (e.g. "-f compose/main.yaml -f compose/overlays/dev.yaml")
#   $2 ... $N     - services (optional, for logging only)

ensure_firewall_ready() {
    local compose_files="${1:-}"
    shift || true
    local services=("$@")

    # Podman 模式：使用 Podman 专用防火墙检测流程（netavark/slirp4netns/CNI 适配）
    if cr_is_podman; then
        _fw_podman_ensure_firewall_ready "$compose_files" "${services[@]}"
        return 0
    fi

    echo ""
    _fw_log_info "═══════════════════════════════════════════════"
    _fw_log_info "  Docker 防火墙预检 开始"
    _fw_log_info "═══════════════════════════════════════════════"

    # ---- Step 1: 三步递进式防火墙检测 ----
    # 步骤 1：_fw_scan_installed  → 扫描已安装的防火墙工具
    # 步骤 2：_fw_scan_running    → 在已安装的工具中判断哪些正在运行
    # 步骤 3：_fw_detect_type     → 综合选出实际使用的工具（运行中优先）
    #         _fw_is_active       → 判断该工具的规则是否真正在过滤流量
    #
    # 这种设计避免了"装了 UFW 就直接判定为 UFW"的武断假设，
    # 在云服务器（nftables/iptables 直接配置）和桌面（UFW 管理）环境下均能正确工作。
    local fw_installed fw_running fw_type fw_active
    fw_installed=$(_fw_scan_installed)
    fw_running=$(_fw_scan_running "$fw_installed")
    fw_type=$(_fw_detect_type)
    fw_active=$(_fw_is_active "$fw_type")

    # 输出检测摘要（仅调试信息，不影响流程）
    # if [[ -n "$fw_installed" ]]; then
    #     _fw_log_info "已安装的防火墙工具: ${fw_installed// /、}"
    # fi
    if [[ -n "$fw_running" ]]; then
        _fw_log_info "正在运行的防火墙: ${fw_running// /、}"
    fi

    case "$fw_type" in
        ufw)
            if [[ "$fw_active" == "true" ]]; then
                _fw_log_info "生效防火墙: ${CYAN:-}UFW${NC:-}（规则已激活）"
                # UFW DEFAULT_FORWARD_POLICY=DROP 是 Docker 容器网络失效的最常见根因。
                # 在后续 bridge 检查之前先探测并引导修复，避免容器启动后才发现问题。
                _fw_check_ufw_forward_policy
                local _ufw_fwd_policy_result=$?
                case $_ufw_fwd_policy_result in
                    0)
                        _fw_log_success "UFW FORWARD 策略: ACCEPT（对 Docker 友好）"
                        ;;
                    1)
                        _fw_log_warn "UFW DEFAULT_FORWARD_POLICY=DROP，Docker 容器网络可能受阻"
                        _fw_offer_fix_ufw_forward_policy
                        ;;
                    2)
                        _fw_log_info "无法读取 UFW FORWARD 策略（/etc/default/ufw 不可访问）"
                        ;;
                esac
            else
                _fw_log_info "防火墙工具: ${CYAN:-}UFW${NC:-}（已安装/运行，但规则未激活 — 当前无入站过滤）"
            fi
            ;;
        firewalld)
            if [[ "$fw_active" == "true" ]]; then
                _fw_log_info "生效防火墙: ${CYAN:-}firewalld${NC:-}（规则已激活）"
            else
                _fw_log_info "防火墙工具: ${CYAN:-}firewalld${NC:-}（已安装，服务未运行 — 当前无入站过滤）"
            fi
            ;;
        iptables)
            if [[ "$fw_active" == "true" ]]; then
                _fw_log_info "生效防火墙: ${CYAN:-}iptables${NC:-}（INPUT 过滤规则已生效）"
            else
                _fw_log_info "防火墙工具: ${CYAN:-}iptables${NC:-}（已安装，无 INPUT 过滤规则 — 当前无入站过滤）"
            fi
            ;;
        nftables)
            local _nft_label="nftables"
            if _fw_has_nftables_manager; then
                _nft_label="nftables (nftables-manager)"
            fi
            if [[ "$fw_active" == "true" ]]; then
                _fw_log_info "生效防火墙: ${CYAN:-}${_nft_label}${NC:-}（filter input 链已生效）"
            else
                _fw_log_info "防火墙工具: ${CYAN:-}${_nft_label}${NC:-}（已安装，无 filter input 链 — 当前无入站过滤）"
            fi
            ;;
        none)
            _fw_log_info "未检测到防火墙工具（系统无防火墙保护）"
            ;;
    esac

    # ---- Step 2: Check Docker bridge forwarding (CRITICAL) ----
    _fw_check_docker_bridge "$_FW_DOCKER_BRIDGE_NAME" "$_FW_DOCKER_NETWORK_NAME"
    local bridge_result=$?

    case $bridge_result in
        0)
            ;;  # All good
        1)
            # iptables=false 模式下，连通性探针失败已在 _fw_check_docker_bridge 内
            # 输出了专项诊断，此处只做轻量提示，避免重复"网桥损坏"的误导性警告。
            if _fw_is_docker_iptables_disabled; then
                _fw_log_info "连通性探针未通过（iptables=false 模式），已输出诊断指引，服务启动继续"
            else
                _fw_log_warn "Docker 网桥转发存在问题，容器间通信可能异常"
                _fw_log_warn "服务启动将继续，但部分功能可能不可用"
            fi
            ;;
        2)
            _fw_log_info "无法确定网桥转发状态，启动后请注意容器间通信是否正常"
            ;;
    esac

    # ---- Step 2.5: nftables Docker 出站修复（非阻断）----
    # 在 policy drop 的 forward 链场景下，容器可能可互通但无法访问外网（如 ping 8.8.8.8）。
    # 这里做幂等修复，不影响非 nftables 系统。
    _fw_ensure_nft_docker_egress "$_FW_DOCKER_BRIDGE_NAME" "$_FW_DOCKER_NETWORK_NAME" "$fw_type" "$fw_active"
    _fw_ensure_nft_docker_nat "$_FW_DOCKER_BRIDGE_NAME" "$_FW_DOCKER_NETWORK_NAME" "$fw_type" "$fw_active"

    # ---- Step 3: 端口规则检查（仅在防火墙规则实际激活时执行）----
    # fw_active=false 时（含 UFW inactive、firewalld stopped 等），当前无入站过滤，
    # 无需也无法检查端口放行状态，跳过以避免误报。
    if [[ "$fw_active" == "true" ]]; then
        _fw_check_and_fix_ports "$fw_type" "$compose_files"
    else
        _fw_log_info "防火墙规则未激活，跳过端口规则检查"
    fi

    echo ""
    _fw_log_info "═══════════════════════════════════════════════"
    _fw_log_info "  Docker 防火墙预检 完成"
    _fw_log_info "═══════════════════════════════════════════════"
    echo ""

    # NEVER block startup
    return 0
}

# Internal: check and optionally fix missing port rules
_fw_check_and_fix_ports() {
    local fw_type="$1"
    local compose_files="$2"

    # Get compose command
    local compose_cmd
    if declare -F get_docker_compose_cmd >/dev/null 2>&1; then
        compose_cmd=$(get_docker_compose_cmd)
    else
        if docker compose version >/dev/null 2>&1; then
            compose_cmd="docker compose"
        elif docker-compose --version >/dev/null 2>&1; then
            compose_cmd="docker-compose"
        else
            _fw_log_warn "未找到 docker compose 命令，跳过端口检查"
            return 0
        fi
    fi

    if [[ -z "$compose_files" ]]; then
        _fw_log_warn "未指定 compose 文件，跳过端口检查"
        return 0
    fi

    # Extract ports
    _fw_log_info "正在从 compose 配置中提取端口映射..."
    local ports_output
    ports_output=$(_fw_extract_ports "$compose_cmd" "$compose_files" 2>/dev/null) || true

    if [[ -z "$ports_output" ]]; then
        _fw_log_info "未提取到端口映射，跳过端口检查"
        return 0
    fi

    # Filter: skip localhost-only ports (127.0.0.1)
    local -a non_local_ports=()
    local -a skipped_local=()
    local total_ports=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        total_ports=$((total_ports + 1))

        local host_ip
        host_ip=$(echo "$line" | cut -d: -f1)

        if [[ "$host_ip" == "127.0.0.1" ]]; then
            skipped_local+=("$line")
        else
            non_local_ports+=("$line")
        fi
    done <<< "$ports_output"

    _fw_log_info "共提取 ${total_ports} 个端口映射"
    if [[ ${#skipped_local[@]} -gt 0 ]]; then
        _fw_log_info "跳过 ${#skipped_local[@]} 个仅绑定到 127.0.0.1 的端口（无需防火墙规则）"
    fi

    if [[ ${#non_local_ports[@]} -eq 0 ]]; then
        _fw_log_success "所有端口均绑定到 localhost，无需额外防火墙规则"
        return 0
    fi

    # Check each non-localhost port against the firewall
    _fw_log_info "检查 ${#non_local_ports[@]} 个非本地端口的防火墙规则..."

    # For some firewall backends, rule querying itself needs sudo.
    # Proactively request elevation in interactive sessions to enable real checks.
    local requires_privileged_check=false
    case "$fw_type" in
        ufw|iptables|nftables)
            requires_privileged_check=true
            ;;
    esac
    if [[ "$requires_privileged_check" == "true" ]] && ! _fw_can_sudo; then
        if _fw_is_interactive; then
            _fw_log_info "端口规则校验需要管理员权限，正在请求 sudo 授权..."
            if _fw_request_sudo; then
                _fw_log_success "已获取 sudo 权限，将执行完整端口校验"
            else
                _fw_log_warn "未获取 sudo 权限，将无法完整校验端口放行状态"
            fi
        else
            _fw_log_warn "非交互环境且无 sudo 权限，无法完整校验端口放行状态"
        fi
    fi

    local -a missing_ports=()
    local -a allowed_ports=()
    local -a unknown_ports=()
    local -a skipped_range_ports=()
    local need_sudo_for_check=false

    for port_entry in "${non_local_ports[@]}"; do
        # Parse "0.0.0.0:8080/tcp" -> port=8080, proto=tcp
        local port_proto="${port_entry#*:}"      # "8080/tcp"
        local port="${port_proto%/*}"            # "8080"
        local proto="${port_proto#*/}"           # "tcp"

        # Handle port ranges (e.g., "8080-8090")
        if [[ "$port" == *-* ]]; then
            _fw_log_warn "端口范围 ${port}/${proto} 暂不做精确校验，请手动确认对应防火墙规则"
            skipped_range_ports+=("${port}/${proto}")
            continue
        fi

        _fw_check_port "$fw_type" "$port" "$proto"
        local result=$?

        case $result in
            0)
                allowed_ports+=("${port}/${proto}")
                ;;
            1)
                missing_ports+=("${port}/${proto}")
                ;;
            2)
                unknown_ports+=("${port}/${proto}")
                need_sudo_for_check=true
                ;;
        esac
    done

    # Report results
    if [[ ${#allowed_ports[@]} -gt 0 ]]; then
        _fw_log_success "已放行 ${#allowed_ports[@]} 个端口: ${allowed_ports[*]}"
    fi

    if [[ ${#unknown_ports[@]} -gt 0 ]]; then
        _fw_log_warn "无法检查 ${#unknown_ports[@]} 个端口 (${_FW_UNKNOWN_REASON_PERMISSION}，请在获取 sudo 后重试): ${unknown_ports[*]}"
    fi

    if [[ ${#skipped_range_ports[@]} -gt 0 ]]; then
        _fw_log_warn "已跳过 ${#skipped_range_ports[@]} 个端口范围（当前脚本不做精确范围校验）: ${skipped_range_ports[*]}"
    fi

    if [[ ${#missing_ports[@]} -eq 0 ]]; then
        if [[ ${#unknown_ports[@]} -eq 0 ]]; then
            _fw_log_success "所有非本地端口的防火墙规则检查通过"
        fi
        return 0
    fi

    # Missing ports found — prompt to add
    echo ""
    _fw_log_warn "发现 ${#missing_ports[@]} 个端口未在防火墙中放行:"
    for mp in "${missing_ports[@]}"; do
        echo -e "  ${RED:-}✗${NC:-} ${mp}"
    done
    echo ""
    echo -e "${YELLOW:-}这些端口绑定到非本地地址，外部访问可能被防火墙阻止。${NC:-}"
    echo ""

    # Attempt to add rules with user confirmation
    if ! _fw_can_sudo; then
        if ! _fw_request_sudo; then
            _fw_log_warn "无 sudo 权限，无法自动添加防火墙规则"
            _fw_log_info "请手动添加以上端口的防火墙规则"
            return 0
        fi
    fi

    local answer="n"
    if _fw_auto_allow_missing_ports; then
        answer="y"
        _fw_log_info "已启用自动放行策略（FW_AUTO_ALLOW_MISSING_PORTS=true），将自动添加缺失端口规则"
    elif _fw_is_interactive; then
        read -r -p "是否自动添加缺失的防火墙规则? [y/N] " answer </dev/tty || answer="n"
    else
        _fw_log_info "检测到非交互环境，且未启用自动放行策略，跳过自动添加防火墙规则提示"
    fi

    case "$answer" in
        [yY]|[yY][eE][sS])
            local add_success=0
            local add_fail=0

            for mp in "${missing_ports[@]}"; do
                local p="${mp%/*}"
                local pr="${mp#*/}"
                if _fw_add_port "$fw_type" "$p" "$pr"; then
                    add_success=$((add_success + 1))
                else
                    add_fail=$((add_fail + 1))
                fi
            done

            # Reload firewall if needed (e.g., firewalld needs --reload after --permanent)
            if [[ $add_success -gt 0 ]]; then
                _fw_reload_firewall "$fw_type"
            fi

            _fw_log_info "防火墙规则添加完成: ${add_success} 成功, ${add_fail} 失败"

            # If we have unknown ports and now have sudo, recheck them
            if [[ ${#unknown_ports[@]} -gt 0 && $need_sudo_for_check == "true" ]] && _fw_can_sudo; then
                _fw_log_info "使用已获取的 sudo 权限重新检查之前无法检查的端口..."
                local recheck_missing=0
                for up in "${unknown_ports[@]}"; do
                    local rp="${up%/*}"
                    local rpr="${up#*/}"
                    _fw_check_port "$fw_type" "$rp" "$rpr"
                    local rresult=$?
                    if [[ $rresult -eq 1 ]]; then
                        recheck_missing=$((recheck_missing + 1))
                        _fw_add_port "$fw_type" "$rp" "$rpr"
                    elif [[ $rresult -eq 0 ]]; then
                        _fw_log_success "端口 ${rp}/${rpr} 已放行"
                    fi
                done
                if [[ $recheck_missing -gt 0 ]]; then
                    _fw_reload_firewall "$fw_type"
                fi
            fi
            ;;
        *)
            _fw_log_info "已跳过防火墙规则添加"
            ;;
    esac

    return 0
}


# ==========================================
# 8. Podman 防火墙检测 (rootful + netavark)
# ==========================================
# 以下函数专用于 Podman 运行时的防火墙预检。
# rootless Podman 通过 slirp4netns/pasta 转发端口，无需宿主机防火墙规则。
# rootful Podman + netavark 使用 nftables 管理 NAT/转发，需要检测规则完整性。

# --- 检测 Podman 网络后端 ---
# 返回: netavark | slirp4netns | pasta | CNI | unknown
_fw_podman_detect_backend() {
    local backend
    backend=$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || echo "unknown")
    # 标准化返回值
    case "${backend,,}" in
        netavark)      echo "netavark" ;;
        slirp4netns)   echo "slirp4netns" ;;
        pasta)         echo "pasta" ;;
        cni)           echo "CNI" ;;
        *)             echo "unknown" ;;
    esac
}

# --- 检测是否为 rootless 模式 ---
_fw_podman_is_rootless() {
    podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q "true"
}

# --- 获取 Podman 网络名称（用于容器连通性测试）---
_fw_podman_get_network_name() {
    local compose_files="$1"

    # 从 compose 配置中提取网络名
    if command -v jq >/dev/null 2>&1; then
        local compose_cmd
        compose_cmd=$(command -v podman-compose >/dev/null 2>&1 && echo "podman-compose" || echo "podman compose")
        local json_output
        json_output=$(bash -c "$compose_cmd $compose_files config --format json" 2>/dev/null) || json_output=""
        if [[ -n "$json_output" ]]; then
            local net_name
            # 取 networks 的第一个 key 作为默认网络名
            net_name=$(echo "$json_output" | jq -r '.networks | to_entries[0].key // "hg_dnmpr_network"' 2>/dev/null) || net_name="hg_dnmpr_network"
            echo "$net_name"
            return 0
        fi
    fi

    echo "hg_dnmpr_network"
}

# --- Podman 防火墙预检主入口 ---
_fw_podman_ensure_firewall_ready() {
    local compose_files="${1:-}"
    shift || true
    local services=("$@")

    echo ""
    _fw_log_info "═══════════════════════════════════════════════"
    _fw_log_info "  Podman 防火墙预检 开始"
    _fw_log_info "═══════════════════════════════════════════════"

    # Step 0: 检测 Podman 网络后端和运行模式
    local backend
    backend=$(_fw_podman_detect_backend)
    local is_rootless=false
    _fw_podman_is_rootless && is_rootless=true

    _fw_log_info "Podman 网络后端: ${CYAN:-}${backend}${NC:-}"
    if [[ "$is_rootless" == "true" ]]; then
        _fw_log_info "运行模式: ${GREEN}rootless${NC:-}"
    else
        _fw_log_info "运行模式: ${YELLOW}rootful${NC:-}"
    fi

    # ---- rootless 模式：无需防火墙规则 ----
    if [[ "$is_rootless" == "true" ]]; then
        _fw_log_info "rootless Podman 通过 ${backend} 进行端口转发，无需宿主机防火墙规则"
        case "$backend" in
            slirp4netns)
                _fw_log_info "注意: slirp4netns 不支持特权端口（<1024），请使用高端口映射或设置 net.ipv4.ip_unprivileged_port_start"
                ;;
            pasta)
                _fw_log_info "注意: pasta (Podman 5+) 支持无特权端口绑定，性能优于 slirp4netns"
                ;;
        esac
        _fw_log_info "═══════════════════════════════════════════════"
        echo ""
        return 0
    fi

    # ---- rootful 模式：检查 nftables/netavark 规则 ----
    # 检测宿主机防火墙（复用通用防火墙检测）
    local fw_installed fw_running fw_type fw_active
    fw_installed=$(_fw_scan_installed)
    fw_running=$(_fw_scan_running "$fw_installed")
    fw_type=$(_fw_detect_type)
    fw_active=$(_fw_is_active "$fw_type")

    if [[ -n "$fw_running" ]]; then
        _fw_log_info "宿主机防火墙: ${fw_running// /、}"
    fi
    if [[ "$fw_active" == "true" ]]; then
        _fw_log_info "防火墙规则状态: 已激活 (${fw_type})"
    else
        _fw_log_info "防火墙规则状态: 未激活"
    fi

    # ---- netavark 规则检查 ----
    if [[ "$backend" == "netavark" ]]; then
        _fw_log_info "检查 netavark nftables 规则完整性..."
        _fw_podman_check_netavark_rules
    elif [[ "$backend" == "CNI" ]]; then
        _fw_log_info "检查 CNI iptables 规则..."
        _fw_podman_check_cni_rules
    fi

    # ---- 端口暴露检查 ----
    if [[ "$fw_active" == "true" && -n "$compose_files" ]]; then
        _fw_check_and_fix_ports "$fw_type" "$compose_files"
    elif [[ -z "$compose_files" ]]; then
        _fw_log_info "未提供 compose 文件，跳过端口规则检查"
    else
        _fw_log_info "宿主机防火墙未激活，跳过端口规则检查"
    fi

    # ---- 容器连通性测试 ----
    if [[ -n "$compose_files" ]]; then
        local net_name
        net_name=$(_fw_podman_get_network_name "$compose_files")
        _fw_log_info ""
        _fw_log_info "检查 Podman 容器间连通性..."
        _fw_podman_test_connectivity "$net_name" "$backend"
    fi

    echo ""
    _fw_log_info "═══════════════════════════════════════════════"
    _fw_log_info "  Podman 防火墙预检 完成"
    _fw_log_info "═══════════════════════════════════════════════"
    echo ""

    return 0
}

# --- 检查 netavark nftables 规则 ---
_fw_podman_check_netavark_rules() {
    local rules_ok=true

    # 需要 root/sudo 权限读取 nftables 规则
    if ! _fw_can_sudo; then
        _fw_log_warn "无 sudo 权限，无法检查 netavark nftables 规则"
        _fw_log_info "如容器网络异常，请手动执行: sudo nft list table inet netavark"
        return 0
    fi

    # 检查 netavark 表是否存在
    local nft_out
    nft_out=$(_fw_run_sudo nft list table inet netavark 2>/dev/null) || true
    if [[ -z "$nft_out" ]]; then
        _fw_log_warn "netavark nftables 表 (inet netavark) 不存在"
        _fw_log_info "这将在首个容器启动时由 netavark 自动创建"
        return 0
    fi
    _fw_log_success "netavark nftables 表存在 (inet netavark)"

    # 检查关键链
    local expected_chains=("INPUT" "FORWARD" "POSTROUTING" "PREROUTING")
    for chain in "${expected_chains[@]}"; do
        if echo "$nft_out" | grep -q "chain ${chain}"; then
            _fw_log_success "chain ${chain} 存在"
        else
            # 检查 netavark 的命名惯例（带前缀的链名）
            if echo "$nft_out" | grep -qi "${chain}"; then
                _fw_log_success "chain (netavark variant) ${chain}* 存在"
            else
                _fw_log_warn "chain ${chain} 未找到，可能需要重建网络"
                rules_ok=false
            fi
        fi
    done

    # 检查 MASQUERADE 规则（容器出站关键）
    if echo "$nft_out" | grep -q "masquerade"; then
        _fw_log_success "NAT masquerade 规则存在（容器可访问外网）"
    else
        _fw_log_warn "未找到 masquerade 规则，容器可能无法访问外网"
        rules_ok=false
    fi

    # 检查 FORWARD accept 规则
    if echo "$nft_out" | grep -qE "accept.*comment.*netavark"; then
        _fw_log_success "netavark FORWARD accept 规则存在"
    elif echo "$nft_out" | grep -q "accept"; then
        _fw_log_success "FORWARD accept 规则存在"
    else
        _fw_log_warn "FORWARD accept 规则未明确找到，容器间通信可能受限"
        rules_ok=false
    fi

    if [[ "$rules_ok" == "true" ]]; then
        _fw_log_success "netavark nftables 规则检查全部通过"
    else
        _fw_log_warn "netavark nftables 规则不完整，建议执行: podman system reset --force 后重建网络"
    fi

    return 0
}

# --- 检查 CNI iptables 规则（旧版 Podman）---
_fw_podman_check_cni_rules() {
    if ! _fw_can_sudo; then
        _fw_log_warn "无 sudo 权限，无法检查 CNI iptables 规则"
        return 0
    fi

    # CNI 使用类似 Docker 的 iptables 链，但链名不同
    local ipt_input
    ipt_input=$(_fw_run_sudo iptables -S FORWARD 2>/dev/null) || true
    if echo "$ipt_input" | grep -q "cni"; then
        _fw_log_success "CNI iptables FORWARD 规则存在"
    else
        _fw_log_warn "未找到 CNI iptables 规则，容器网络可能未初始化"
    fi

    # 检查 NAT 规则
    local ipt_nat
    ipt_nat=$(_fw_run_sudo iptables -t nat -S POSTROUTING 2>/dev/null) || true
    if echo "$ipt_nat" | grep -q "cni\|MASQUERADE"; then
        _fw_log_success "CNI NAT masquerade 规则存在"
    else
        _fw_log_warn "CNI NAT 规则未找到，容器可能无法访问外网"
    fi

    return 0
}

# --- Podman 容器间连通性测试 ---
_fw_podman_test_connectivity() {
    local network_name="$1"
    local backend="${2:-netavark}"

    # 获取运行中的容器
    local containers
    containers=$(podman network inspect "$network_name"         --format '{{range $k, $v := .Containers}}{{$k}} {{end}}' 2>/dev/null) || true

    if [[ -z "$containers" ]]; then
        _fw_log_info "无运行中的容器，跳过连通性测试（首次启动时正常）"
        return 0
    fi

    local -a container_ids=()
    local -a container_names=()
    local -a container_ips=()

    for cid_full in $containers; do
        local cid="${cid_full:0:12}"
        local state
        state=$(podman inspect --format '{{.State.Running}}' "$cid" 2>/dev/null) || continue
        [[ "$state" != "true" ]] && continue

        local cname
        cname=$(podman inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||') || continue

        local cip
        cip=$(podman inspect --format "{{(index .NetworkSettings.Networks "${network_name}").IPAddress}}" "$cid" 2>/dev/null) || continue

        if [[ -n "$cip" && "$cip" != "<no value>" ]]; then
            container_ids+=("$cid")
            container_names+=("$cname")
            container_ips+=("$cip")
        fi
    done

    if [[ ${#container_ids[@]} -lt 2 ]]; then
        _fw_log_info "运行中容器不足 2 个，跳过连通性测试"
        return 0
    fi

    local src_id="${container_ids[0]}"
    local src_name="${container_names[0]}"
    local dst_ip="${container_ips[1]}"
    local dst_name="${container_names[1]}"

    _fw_log_info "连通性测试: ${src_name} -> ${dst_name} (${dst_ip})"

    # 策略 1: ICMP ping
    local ping_out
    ping_out=$(timeout 5 podman exec "$src_id" ping -c 1 -W 2 "$dst_ip" 2>&1) || true

    if echo "$ping_out" | grep -qE "1 (packets )?received|1 received"; then
        _fw_log_success "容器间 ICMP 连通性测试通过"
        return 0
    fi

    if echo "$ping_out" | grep -qE "0 (packets )?received|Network is unreachable|No route to host|Destination Host Unreachable"; then
        _fw_log_error "容器间 ICMP 连通性测试失败 — 网络不可达"
        _fw_podman_diag_connectivity_failure "$network_name" "$backend"
        return 1
    fi

    # 策略 2: TCP 端口测试
    local test_port=80
    local test_output
    test_output=$(timeout 6 podman exec "$src_id" bash -c         "timeout 3 bash -c 'echo > /dev/tcp/${dst_ip}/${test_port}' 2>&1; echo 'EXIT_CODE:'\$?" 2>&1) || true

    if echo "$test_output" | grep -qi "refused\|reset"; then
        _fw_log_success "容器间 TCP 连通性测试通过（端口 ${test_port} refused=可达）"
        return 0
    fi

    if echo "$test_output" | grep -q "EXIT_CODE:0"; then
        _fw_log_success "容器间 TCP 连通性测试通过"
        return 0
    fi

    if echo "$test_output" | grep -q "EXIT_CODE:124"; then
        _fw_log_error "容器间 TCP 连通性测试失败 — 连接超时（包可能被 DROP）"
        _fw_podman_diag_connectivity_failure "$network_name" "$backend"
        return 1
    fi

    # 无法判断
    _fw_log_info "容器间连通性测试结果不明确（可能容器内 bash 不可用），跳过"
    return 0
}

# --- 连通性失败诊断 ---
_fw_podman_diag_connectivity_failure() {
    local network_name="$1"
    local backend="$2"

    echo ""
    echo -e "${YELLOW:-}╔══════════════════════════════════════════════════════════════╗${NC:-}"
    echo -e "${YELLOW:-}║  ⚠  Podman 容器间连通性异常                                  ║${NC:-}"
    echo -e "${YELLOW:-}╚══════════════════════════════════════════════════════════════╝${NC:-}"
    echo ""
    echo -e "  网络:   ${network_name}"
    echo -e "  后端:   ${backend}"
    echo ""
    echo -e "${CYAN:-}诊断建议:${NC:-}"
    echo -e "  1. 检查内核 IP 转发: cat /proc/sys/net/ipv4/ip_forward（应为 1）"
    echo -e "  2. 检查 netavark 规则: sudo nft list table inet netavark"
    echo -e "  3. 检查防火墙是否 DROP 了网桥流量: sudo nft list chain inet filter FORWARD"
    echo -e "  4. 重建网络: podman network rm ${network_name} && podman network create ${network_name}"
    echo ""

    # 尝试自动修复 netavark FORWARD 规则
    if [[ "$backend" == "netavark" ]]; then
        _fw_podman_ensure_nft_forward "$network_name"
    fi
}

# --- 确保 netavark FORWARD 规则放行 Podman 网桥流量 ---
_fw_podman_ensure_nft_forward() {
    local network_name="$1"

    if ! _fw_can_sudo; then
        _fw_log_info "无 sudo 权限，无法自动修复 netavark FORWARD 规则"
        _fw_log_info "请手动执行: sudo nft add rule inet filter FORWARD iifname "podman*" accept"
        return 0
    fi

    # 获取网桥接口
    local bridge_if=""
    bridge_if=$(podman network inspect "$network_name" --format '{{.NetworkInterface}}' 2>/dev/null || echo "")
    if [[ -z "$bridge_if" || "$bridge_if" == "<no value>" ]]; then
        bridge_if="podman0"
    fi

    _fw_log_info "网桥接口: ${bridge_if}"

    # 检查 FORWARD 链中是否有网桥的 accept 规则
    local fwd_rules
    if _fw_run_sudo nft list chain inet filter FORWARD >/dev/null 2>&1; then
        fwd_rules=$(_fw_run_sudo nft list chain inet filter FORWARD 2>/dev/null) || true
        if echo "$fwd_rules" | grep -q "iifname "${bridge_if}" accept"; then
            _fw_log_success "FORWARD 链已有 ${bridge_if} 的 accept 规则"
            return 0
        fi

        # 尝试添加
        if _fw_run_sudo nft add rule inet filter FORWARD iifname "${bridge_if}" accept 2>/dev/null; then
            _fw_log_success "已自动添加 FORWARD 规则: iifname ${bridge_if} accept"
        else
            _fw_log_warn "自动添加 FORWARD 规则失败，请手动添加"
        fi
    else
        _fw_log_info "inet filter FORWARD 链不存在，跳过自动修复"
    fi

    return 0
}
