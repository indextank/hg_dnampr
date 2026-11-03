#!/usr/bin/env bash
# ==========================================
# 代理管理函数库
# ==========================================
# 用途：构建阶段的代理配置、检测与应用
# 依赖：common_functions.sh（info/warn/error/success/_get_env_file_value）
#
# 规则：
# 1. BUILD_PROXY_ENABLED 决定是否启用代理（.env / 环境变量 / 脚本常量）。
# 2. 开关/类型以根目录 .env 为准（env/base.env 不维护代理项）。
# 3. 仅当 ENABLED=true 时，才从系统 PROXY_* 拼装 BUILD_PROXY_URL；.env 禁止写 BUILD_PROXY_URL。
# 4. 系统凭据：PROXY_SCHEME / PROXY_HOST / PROXY_PORT / [PROXY_USER] / [PROXY_PASS]
# 5. 可选临时覆盖：当前 shell 已 export 的 BUILD_PROXY_URL（或 DM_BUILD_PROXY_URL）优先于 PROXY_*。
# 6. 分层 env/ 不得写入代理账号、密码、完整代理地址或 BUILD_PROXY_* 开关。
# ==========================================

# true/1/yes/on → 启用
is_build_proxy_enabled() {
    case "${1:-}" in
        [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]|1) return 0 ;;
        *) return 1 ;;
    esac
}

# 从 PROXY_* 拼装 URL；缺 scheme/host/port 时输出空字符串
# 可选 $1：优先使用的 scheme（来自 BUILD_PROXY_TYPE）；为空则用 PROXY_SCHEME
compose_build_proxy_url_from_proxy_env() {
    local preferred_type="${1:-}"
    local scheme host port user pass

    scheme="${preferred_type:-}"
    case "${scheme,,}" in
        http|https|socks5|socks5h) ;;
        none|"")
            scheme="${PROXY_SCHEME:-}"
            ;;
        *)
            scheme="${PROXY_SCHEME:-}"
            ;;
    esac

    host="${PROXY_HOST:-}"
    port="${PROXY_PORT:-}"
    user="${PROXY_USER:-}"
    pass="${PROXY_PASS:-}"

    if [[ -z "$scheme" || -z "$host" || -z "$port" ]]; then
        echo ""
        return 1
    fi

    case "${scheme,,}" in
        http|https|socks5|socks5h) ;;
        *)
            echo ""
            return 1
            ;;
    esac

    if [[ -n "$user" ]]; then
        echo "${scheme}://${user}:${pass}@${host}:${port}"
    else
        echo "${scheme}://${host}:${port}"
    fi
    return 0
}

# 在 ENABLED 已为真的前提下，解析 type + url（不修改全局，stdout: type<TAB>url）
# $1 preferred_type  $2 explicit_url（可空）
_resolve_enabled_build_proxy_type_url() {
    local preferred_type="${1:-}"
    local explicit_url="${2:-}"
    local proxy_type proxy_url scheme

    if [[ -n "$explicit_url" ]]; then
        proxy_url="$explicit_url"
        proxy_type="$(_normalize_build_proxy_type "$preferred_type" "$proxy_url")"
        printf '%s\t%s\n' "$proxy_type" "$proxy_url"
        return 0
    fi

    proxy_url="$(compose_build_proxy_url_from_proxy_env "$preferred_type" 2>/dev/null || true)"
    if [[ -z "$proxy_url" ]]; then
        printf '%s\t%s\n' "none" ""
        return 1
    fi

    scheme="${proxy_url%%://*}"
    proxy_type="$(_normalize_build_proxy_type "${preferred_type:-$scheme}" "$proxy_url")"
    printf '%s\t%s\n' "$proxy_type" "$proxy_url"
    return 0
}

load_proxy_config() {
    local config_dir="${ENV_DIR:-$PROJECT_DIR/env}"
    local env_source value
    local resolved_type resolved_url

    DEFAULT_BUILD_PROXY_ENABLED="${DEFAULT_BUILD_PROXY_ENABLED:-false}"
    DEFAULT_BUILD_PROXY_TYPE="${DEFAULT_BUILD_PROXY_TYPE:-}"
    DEFAULT_NO_PROXY="${DEFAULT_NO_PROXY:-localhost,127.0.0.1,::1}"

    for env_source in "$PROJECT_DIR/.env" "$PROJECT_DIR/.env.local"; do
        [[ -f "$env_source" ]] || continue

        value="$(_get_env_file_value "$env_source" "BUILD_PROXY_ENABLED" || true)"
        [[ -n "$value" ]] && DEFAULT_BUILD_PROXY_ENABLED="$value"

        value="$(_get_env_file_value "$env_source" "BUILD_PROXY_TYPE" || true)"
        [[ -n "$value" ]] && DEFAULT_BUILD_PROXY_TYPE="$value"

        value="$(_get_env_file_value "$env_source" "NO_PROXY" || true)"
        [[ -n "$value" ]] && DEFAULT_NO_PROXY="$value"
    done

    export BUILD_PROXY_ENABLED="${BUILD_PROXY_ENABLED:-$DEFAULT_BUILD_PROXY_ENABLED}"
    export BUILD_PROXY_TYPE="${BUILD_PROXY_TYPE:-$DEFAULT_BUILD_PROXY_TYPE}"
    # URL 仅保留调用方已 export 的临时覆盖；否则留空，后面按 ENABLED 从 PROXY_* 生成
    export BUILD_PROXY_URL="${BUILD_PROXY_URL:-}"
    export NO_PROXY="${NO_PROXY:-$DEFAULT_NO_PROXY}"

    if ! is_build_proxy_enabled "$BUILD_PROXY_ENABLED"; then
        export BUILD_PROXY_ENABLED="false"
        export BUILD_PROXY_TYPE="none"
        export BUILD_PROXY_URL=""
        return 0
    fi

    export BUILD_PROXY_ENABLED="true"

    resolved_type=""
    resolved_url=""
    IFS=$'\t' read -r resolved_type resolved_url < <(_resolve_enabled_build_proxy_type_url "$BUILD_PROXY_TYPE" "$BUILD_PROXY_URL" || true)
    if [[ -n "$resolved_url" && "$resolved_type" != "none" ]]; then
        export BUILD_PROXY_TYPE="$resolved_type"
        export BUILD_PROXY_URL="$resolved_url"
    else
        warn "BUILD_PROXY_ENABLED=true，但未设置 BUILD_PROXY_URL，且系统 PROXY_SCHEME/HOST/PORT 不完整；已回退为直连"
        export BUILD_PROXY_ENABLED="false"
        export BUILD_PROXY_TYPE="none"
        export BUILD_PROXY_URL=""
    fi
}

_normalize_build_proxy_type() {
    local proxy_type="${1:-}"
    local proxy_url="${2:-}"
    proxy_type="${proxy_type,,}"

    case "$proxy_type" in
        none|http|https|socks5|socks5h)
            echo "$proxy_type"
            return 0
            ;;
        "")
            ;;
        *)
            echo "$proxy_type"
            return 0
            ;;
    esac

    case "${proxy_url%%://*}" in
        http|https|socks5|socks5h)
            echo "${proxy_url%%://*}"
            ;;
        *)
            if [[ -n "$proxy_url" ]]; then
                echo "http"
            else
                echo "none"
            fi
            ;;
    esac
}

_extract_proxy_host_port() {
    local proxy_url="$1"
    local hostport

    hostport="${proxy_url#*://}"
    hostport="${hostport%%/*}"
    hostport="${hostport##*@}"
    echo "${hostport%%:*} ${hostport##*:}"
}

_mask_proxy_url() {
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

disable_build_proxy_environment() {
    # 显式设为空字符串而非 unset，避免 docker compose 因变量未定义而输出 WARN。
    export HTTP_PROXY=""
    export HTTPS_PROXY=""
    export ALL_PROXY=""
    export http_proxy=""
    export https_proxy=""
    export all_proxy=""
    export NO_PROXY="${NO_PROXY:-$DEFAULT_NO_PROXY}"
    export no_proxy="${NO_PROXY:-$DEFAULT_NO_PROXY}"
    export BUILD_PROXY_ENABLED="false"
    export BUILD_PROXY_TYPE="none"
    export BUILD_PROXY_URL=""
}

validate_build_proxy_environment() {
    local proxy_type proxy_url check_host check_port proxy_label

    proxy_url="${BUILD_PROXY_URL:-}"
    proxy_type="$(_normalize_build_proxy_type "${BUILD_PROXY_TYPE:-}" "$proxy_url")"

    if ! is_build_proxy_enabled "${BUILD_PROXY_ENABLED:-false}" \
        || [[ "$proxy_type" == "none" || -z "$proxy_type" || -z "$proxy_url" ]]; then
        return 0
    fi

    read -r check_host check_port <<< "$(_extract_proxy_host_port "$proxy_url")"
    [[ "$check_host" == "$check_port" ]] && check_port="80"
    [[ -n "$check_host" ]] || return 0

    case "$proxy_type" in
        socks5|socks5h) proxy_label="SOCKS5" ;;
        http|https) proxy_label="HTTP/HTTPS" ;;
        *) return 0 ;;
    esac

    info "正在检测${proxy_label}构建代理可用性（TCP ${check_host}:${check_port}）"
    local _probe_ok=false
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 5 "$check_host" "$check_port" 2>/dev/null && _probe_ok=true
    else
        timeout 5 bash -c "echo >/dev/tcp/${check_host}/${check_port}" 2>/dev/null && _probe_ok=true
    fi

    if [[ "$_probe_ok" == "true" ]]; then
        info "${proxy_label}构建代理检测通过（${check_host}:${check_port} 可达）"
        return 0
    fi

    echo -e "${RED}❌ 构建代理检测失败（无法连接 ${check_host}:${check_port}），已切换为直连模式继续构建。${NC}" >&2
    disable_build_proxy_environment
    return 1
}

check_proxy() {
    load_proxy_config

    local proxy_url proxy_type check_host check_port
    proxy_url="${BUILD_PROXY_URL:-}"
    proxy_type="$(_normalize_build_proxy_type "${BUILD_PROXY_TYPE:-}" "$proxy_url")"

    echo ""
    echo -e "${CYAN}${BOLD}============================================${NC}"
    echo -e "${CYAN}${BOLD}  构建代理配置检测${NC}"
    echo -e "${CYAN}${BOLD}============================================${NC}"
    echo ""

    if ! is_build_proxy_enabled "${BUILD_PROXY_ENABLED:-false}"; then
        echo -e "${YELLOW}${BOLD}BUILD_PROXY_ENABLED=false（已禁用）${NC}"
        echo -e "${GREEN}无需检测，退出。${NC}"
        exit 0
    fi

    if [[ "$proxy_type" == "none" || -z "$proxy_type" ]]; then
        echo -e "${YELLOW}${BOLD}代理类型: none（已禁用）${NC}"
        echo -e "${GREEN}无需检测，退出。${NC}"
        exit 0
    fi

    if [[ -z "$proxy_url" ]]; then
        echo -e "${RED}❌ BUILD_PROXY_ENABLED=true 但未能从 PROXY_* / BUILD_PROXY_URL 得到有效地址${NC}" >&2
        exit 1
    fi

    read -r check_host check_port <<< "$(_extract_proxy_host_port "$proxy_url")"
    [[ "$check_host" == "$check_port" ]] && check_port="80"

    echo -e "代理开关: ${GREEN}BUILD_PROXY_ENABLED=true${NC}"
    echo -e "代理类型: ${GREEN}${proxy_type}${NC}"
    echo -e "代理地址: ${GREEN}$(_mask_proxy_url "$proxy_url")${NC}"
    echo ""

    echo -e "${CYAN}[1/2] TCP 连通性检测 (${check_host}:${check_port})...${NC}"
    local tcp_ok=false
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 5 "$check_host" "$check_port" 2>/dev/null && tcp_ok=true
    else
        timeout 5 bash -c "echo >/dev/tcp/${check_host}/${check_port}" 2>/dev/null && tcp_ok=true
    fi

    if [[ "$tcp_ok" != "true" ]]; then
        echo -e "  ${RED}❌ TCP 连通性检测失败${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✅ TCP 连通性检测通过${NC}"

    echo -e "${CYAN}[2/2] 代理访问外网检测...${NC}"
    local status
    status=$(curl --proxy "$proxy_url" -s --connect-timeout 15 --max-time 30 -o /dev/null -w "%{http_code}" "https://httpbin.org/ip" 2>/dev/null || echo "000")
    status="${status: -3}"
    if [[ "$status" == "200" ]]; then
        echo -e "  ${GREEN}✅ 外网代理检测通过 (HTTP ${status})${NC}"
        exit 0
    fi

    echo -e "  ${RED}❌ 外网代理检测失败 (HTTP ${status})${NC}"
    exit 1
}

apply_build_proxy_environment() {
    local proxy_url proxy_type effective_no_proxy

    # 确保已按 ENABLED + PROXY_* 解析
    if [[ -z "${BUILD_PROXY_ENABLED:-}" ]] || { is_build_proxy_enabled "${BUILD_PROXY_ENABLED:-false}" && [[ -z "${BUILD_PROXY_URL:-}" ]]; }; then
        load_proxy_config
    fi

    proxy_url="${BUILD_PROXY_URL:-}"
    proxy_type="$(_normalize_build_proxy_type "${BUILD_PROXY_TYPE:-}" "$proxy_url")"
    effective_no_proxy="${NO_PROXY:-$DEFAULT_NO_PROXY}"

    if ! is_build_proxy_enabled "${BUILD_PROXY_ENABLED:-false}"; then
        disable_build_proxy_environment
        info "构建代理已禁用（BUILD_PROXY_ENABLED=false）"
        return 0
    fi

    case "$proxy_type" in
        none|"")
            disable_build_proxy_environment
            info "构建代理已禁用（BUILD_PROXY_TYPE=none）"
            ;;
        http|https|socks5|socks5h)
            if [[ -z "$proxy_url" ]]; then
                echo -e "${RED}❌ BUILD_PROXY_ENABLED=true 但代理 URL 为空，已切换为直连模式。${NC}" >&2
                disable_build_proxy_environment
                return 1
            fi
            export HTTP_PROXY="$proxy_url"
            export HTTPS_PROXY="$proxy_url"
            export http_proxy="$proxy_url"
            export https_proxy="$proxy_url"
            export NO_PROXY="$effective_no_proxy"
            export no_proxy="$effective_no_proxy"
            if [[ "$proxy_type" == socks5* ]]; then
                export ALL_PROXY="$proxy_url"
                export all_proxy="$proxy_url"
            else
                export ALL_PROXY=""
                export all_proxy=""
            fi
            export BUILD_PROXY_ENABLED="true"
            export BUILD_PROXY_TYPE="$proxy_type"
            export BUILD_PROXY_URL="$proxy_url"
            info "使用 ${proxy_type} 构建代理: $(_mask_proxy_url "$proxy_url")"
            ;;
        *)
            echo -e "${RED}❌ 无效 BUILD_PROXY_TYPE: $proxy_type（支持: http | https | socks5 | socks5h | none），已切换为直连模式。${NC}" >&2
            disable_build_proxy_environment
            return 1
            ;;
    esac
}
