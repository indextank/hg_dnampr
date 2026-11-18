#!/usr/bin/env bash
# ==========================================
# Build.sh 专用 Compose 工具函数库
# ==========================================
# 用途：Docker/Podman 环境检测、服务名映射、compose 文件解析
# 依赖：
#   common_functions.sh（info/warn/error/success/load_project_environment_from_base_env）
#   container_runtime.sh（cr_cmd、CR_IS_PODMAN、COMPOSE_CMD）
# 全局变量（由调用方提供）：
#   SCRIPT_DIR, PROJECT_DIR
# ==========================================

# 服务清单单一数据源：map_service_name / get_special_services / get_compose_files /
# unmap_service_name_for_build / get_compose_project_for_service 全部来自 service_catalog.sh，
# 避免与 up.sh 路径出现定义漂移。
if ! declare -F map_service_name >/dev/null 2>&1; then
    _bcu_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -f "${_bcu_dir}/service_catalog.sh" ]] && source "${_bcu_dir}/service_catalog.sh"
    unset _bcu_dir
fi

# 确保 ~/.docker（含 buildx 状态目录）对当前用户可写；避免 root 安装 Docker 后构建报 permission denied。
ensure_docker_cli_config_writable() {
    local docker_config="${DOCKER_CONFIG:-$HOME/.docker}"
    local stat_owner

    if [[ -z "$docker_config" || "$docker_config" == "/" ]]; then
        return 0
    fi

    if [[ ! -d "$docker_config" ]]; then
        mkdir -p "$docker_config/buildx" 2>/dev/null && return 0
        if command -v sudo >/dev/null 2>&1; then
            sudo mkdir -p "$docker_config/buildx" \
                && sudo chown -R "$(id -u):$(id -g)" "$docker_config"
        fi
        return 0
    fi

    if [[ -w "$docker_config" ]]; then
        mkdir -p "$docker_config/buildx" 2>/dev/null || true
        return 0
    fi

    stat_owner="$(stat -c '%U:%G' "$docker_config" 2>/dev/null || echo 'unknown')"
    if command -v warn >/dev/null 2>&1 && [[ "$(type -t warn)" == "function" ]]; then
        warn "Docker 配置目录不可写: ${docker_config}（当前属主 ${stat_owner}），尝试修复..."
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        if command -v error >/dev/null 2>&1 && [[ "$(type -t error)" == "function" ]]; then
            error "无法写入 ${docker_config}，请手动执行: chown -R $(id -un):$(id -gn) ${docker_config}"
        fi
        return 1
    fi

    if sudo chown -R "$(id -u):$(id -g)" "$docker_config"; then
        mkdir -p "$docker_config/buildx" 2>/dev/null || true
        if command -v info >/dev/null 2>&1 && [[ "$(type -t info)" == "function" ]]; then
            info "已修复 Docker 配置目录权限: ${docker_config}"
        fi
        return 0
    fi

    if command -v error >/dev/null 2>&1 && [[ "$(type -t error)" == "function" ]]; then
        error "修复 ${docker_config} 权限失败，构建可能无法使用 buildx"
    fi
    return 1
}

detect_docker_environment() {
    local has_docker_desktop=false
    local has_buildx=false

    # 确保容器运行时已检测；无运行时时不在帮助/参数解析阶段失败，真正构建前由 check_prerequisites 报错。
    if [[ -z "$CR" ]]; then
        detect_container_runtime || true
    fi

    [[ -n "${CR:-}" ]] || return 0

    # Podman 环境：跳过 Docker Desktop / buildx 检测
    if cr_is_podman; then
        if command -v info >/dev/null 2>&1 && [[ "$(type -t info)" == "function" ]]; then
            info "检测到 Podman 容器运行时，跳过 Docker Desktop 检测"
        fi
        # Podman 使用 Buildah 作为构建后端，不设置 DOCKER_BUILDKIT
        export DOCKER_BUILDKIT=0
        export COMPOSE_DOCKER_CLI_BUILD=0
        export COMPOSE_EXPERIMENTAL_BAKE=0
        export BUILDKIT_PROGRESS=plain
        return 0
    fi

    ensure_docker_cli_config_writable || true

    # 检测 Docker Desktop
    # 方法1: 检查 Docker Desktop 特有的 context
    if docker context ls 2>/dev/null | grep -q "desktop-linux\|desktop-windows"; then
        has_docker_desktop=true
    fi

    # 方法2: 检查 Docker Desktop 进程 (Windows/Mac)
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]] || [[ "$OSTYPE" == "darwin"* ]]; then
        if pgrep -f "Docker Desktop" >/dev/null 2>&1 || pgrep -f "com.docker.backend" >/dev/null 2>&1; then
            has_docker_desktop=true
        fi
    fi

    # 方法3: 检查 Docker 信息中的 Operating System 字段
    if docker info 2>/dev/null | grep -q "Docker Desktop\|Docker for"; then
        has_docker_desktop=true
    fi

    # 检测 buildx 插件（Docker ≥ 23.0 自带，Linux 原生引擎无需 Docker Desktop）
    if docker buildx version >/dev/null 2>&1; then
        has_buildx=true
    fi

    # BuildKit 可用性以 buildx 为准，不硬绑定 Docker Desktop。
    # 现代 Linux 上 docker build 已是 docker buildx build 的别名，BuildKit 即默认后端。
    if [[ "$has_buildx" == "true" ]]; then
        local _msg="检测到 buildx 插件"
        [[ "$has_docker_desktop" == "true" ]] && _msg="$_msg（Docker Desktop）"
        if command -v info >/dev/null 2>&1 && [[ "$(type -t info)" == "function" ]]; then
            info "$_msg，启用 BuildKit 构建后端"
        fi
        export DOCKER_BUILDKIT=1
        export COMPOSE_DOCKER_CLI_BUILD=1
    else
        if command -v info >/dev/null 2>&1 && [[ "$(type -t info)" == "function" ]]; then
            info "未检测到 buildx 插件，使用传统构建后端"
        fi
        export DOCKER_BUILDKIT=0
        export COMPOSE_DOCKER_CLI_BUILD=0
        export COMPOSE_EXPERIMENTAL_BAKE=0
        export BUILDKIT_PROGRESS=plain
    fi
}

load_build_environment_variables() {
    local config_dir="${ENV_DIR:-$SCRIPT_DIR/env}"
    # web.env：提供 GLOBAL_WEB_PATH/APACHE_LOG_DIR 等 compose 插值变量
    # （此前缺失导致 ${GLOBAL_WEB_PATH}:/var/www/html:rw,Z → "invalid spec"）；
    # 根目录 .env 最后加载，确保本地敏感配置覆盖所有分层配置。
    local env_files=("base.env" "web.env" "php.env" "syncer.env" "mysql.env" "postgres.env" "mongodb.env" "redis.env" "timescaledb.env" "pgvector.env" "clickhouse.env")

    set -a
    for env_file in "${env_files[@]}"; do
        local file_path="$config_dir/$env_file"
        load_env_file_exports "$file_path"
    done
    load_env_file_exports "$PROJECT_DIR/.env"
    load_env_file_exports "$PROJECT_DIR/.env.local"
    load_project_environment_from_base_env "$PROJECT_DIR"
    set +a
    # 生成合并 env 文件，供 compose 在 sudo 环境下通过 --env-file 插值（见 write_compose_env_file）
    write_compose_env_file || true
}

check_prerequisites() {
    # 确保运行时已检测
    if [[ -z "$CR" ]] || [[ -z "$COMPOSE_CMD" ]]; then
        detect_container_runtime
    fi

    # 检查容器运行时命令是否存在
    if [[ -z "$CR" ]]; then
        error "未找到容器运行时命令，请先安装 Docker 或 Podman\n  Podman: dnf install -y podman\n  Docker: https://docs.docker.com/engine/install/"
    fi

    if ! command -v "$CR" &>/dev/null; then
        error "未找到 $CR 命令，请先安装\n  Podman: dnf install -y podman\n  Docker: sudo apt-get install docker-ce"
    fi

    # 检查运行时守护进程（经 cr_cmd，非 docker 组成员时会自动加 CR_SUDO）
    if ! cr_cmd info &>/dev/null 2>&1; then
        if cr_is_podman; then
            error "Podman 服务未就绪，请执行: podman system migrate && podman system service start"
        else
            error "Docker 守护进程未运行或当前用户无权限访问\n  启动服务: sudo systemctl start docker\n  免 sudo 构建: sudo usermod -aG docker ${USER:-ecs-user} 后重新登录\n  或确保 sudo docker info 可用（脚本会自动加 sudo）"
        fi
    fi

    # 检查 Compose 工具
    if [[ -z "$COMPOSE_CMD" ]]; then
        error "未找到 Compose 工具，请安装\n  Podman: dnf install -y podman-compose 或 pip install podman-compose\n  Docker: sudo apt-get install docker-compose-plugin"
    fi

    # 验证 Compose 可用（与 get_docker_compose_cmd 一致，需要时带 CR_SUDO）
    local -a _cc_chk=()
    local _cc_head="${COMPOSE_CMD}"
    [[ -n "${CR_SUDO:-}" ]] && _cc_head="${CR_SUDO} ${COMPOSE_CMD}"
    IFS=' ' read -r -a _cc_chk <<< "${_cc_head}"
    if ! "${_cc_chk[@]}" version &>/dev/null 2>&1; then
        error "Compose 命令 (${_cc_head}) 不可用"
    fi

    local _cr_ver
    _cr_ver="$(cr_cmd --version 2>/dev/null | head -1 || echo '')"
    success "容器运行时检测通过 (${CR}${_cr_ver}, ${COMPOSE_CMD}${CR_NEEDS_SUDO:+, 自动 sudo})"
}

# 解决 docker compose build 在 bake 后端下 network:host 触发 BuildKit entitlement 报错的问题。
#
# 背景：新版 Docker Compose 默认以 bake 后端执行 `compose build`（内部等价于
#       `docker buildx bake`，从 stdin 读取 bake 定义）。compose 中 PHP 构建段配置了
#       `network: host`，bake 会将其视为需要 network.host entitlement，若不显式授权则中止：
#         "additional privileges requested: pass \"--allow=network.host\" to grant requested privileges"
#       注意：`COMPOSE_EXPERIMENTAL_BAKE=0` 在新版 Compose 已无法回退经典构建路径。
#
# 策略：先用 `compose build --print` 检测本次构建是否声明了 network: host；若声明且具备
#       buildx，则改用 `compose build --print | docker buildx bake --allow=network.host` 执行，
#       显式授予该 entitlement；否则原样返回普通构建命令，行为不变。
#
# 参数：<plain_build_cmd> <compose_cmd> <compose_files> <multi_arch> <services...>
# 输出：回显最终要执行的构建命令字符串（供调用方以 `timeout ... bash -c` 执行）。
resolve_compose_build_command() {
    local plain_cmd="$1"
    local compose_cmd="$2"
    local compose_files="$3"
    local multi_arch="$4"
    shift 4
    local services=("$@")

    # buildx 命令的 sudo 前缀与 compose 命令保持一致
    local bx_sudo="${CR_SUDO:-}"
    local bx_cmd="docker"
    [[ -n "$bx_sudo" ]] && bx_cmd="${bx_sudo} docker"

    # 能力探测：优先直接调用；需 sudo 时用非交互模式（-n）避免无凭据缓存时阻塞等待密码输入
    local probe_ok=false
    if command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
        probe_ok=true
    elif [[ -n "$bx_sudo" ]] && $bx_sudo -n docker buildx version >/dev/null 2>&1; then
        probe_ok=true
    fi

    # 仅在 Docker + buildx + 单架构场景自动处理；多架构的 --platform 无法经 bake CLI 透传，保持原路径
    if ! cr_is_docker \
        || [[ "$probe_ok" != "true" ]] \
        || [[ "${multi_arch:-false}" == "true" ]]; then
        printf '%s\n' "$plain_cmd"
        return 0
    fi

    # 一次 --print：同时检测 network.host，并筛掉无 build 段的服务（如 mysql_backup）
    local svc_list="${services[*]}"
    local bake_json=""
    bake_json=$($compose_cmd $compose_files build --print $svc_list 2>/dev/null) || bake_json=""

    local needs_host=false
    if printf '%s' "$bake_json" | grep -q '"network"[[:space:]]*:[[:space:]]*"host"'; then
        needs_host=true
    fi

    if [[ "$needs_host" != "true" ]]; then
        printf '%s\n' "$plain_cmd"
        return 0
    fi

    # 仅把 bake 定义里真实存在的 target 传给 bake，避免 failed to find target
    if [[ -n "$bake_json" ]]; then
        local bake_targets=""
        bake_targets=$(printf '%s' "$bake_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(" ".join(sorted((data.get("target") or {}).keys())))
except Exception:
    pass
' 2>/dev/null) || bake_targets=""
        if [[ -n "$bake_targets" ]]; then
            local filtered=() missing=() s
            for s in $svc_list; do
                if printf ' %s ' " $bake_targets " | grep -Fq " $s "; then
                    filtered+=("$s")
                else
                    missing+=("$s")
                fi
            done
            if [[ ${#missing[@]} -gt 0 ]] && declare -F info >/dev/null 2>&1; then
                info "bake 跳过无 build 目标的服务: ${missing[*]}" >&2
            fi
            if [[ ${#filtered[@]} -gt 0 ]]; then
                svc_list="${filtered[*]}"
            fi
        fi
    fi

    local nc_flag=""
    [[ "${NO_CACHE:-false}" == "true" ]] && nc_flag="--no-cache"
    if declare -F info >/dev/null 2>&1; then
        info "检测到构建需要 network.host 权限，自动改用 buildx bake --allow=network.host 执行" >&2
    fi
    printf '%s\n' "$compose_cmd $compose_files build --print $svc_list 2>/dev/null | $bx_cmd buildx bake --allow=network.host $nc_flag -f - $svc_list"
}
# get_compose_files / get_special_services / map_service_name 现由 service_catalog.sh 提供（单一数据源）。
# build.sh 在调用 get_special_services 时应显式传 build 模式：get_special_services "$svc" build。
