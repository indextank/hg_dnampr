#!/bin/bash

# ==========================================
# 容器运行时统一抽象层 v1.0
# ==========================================
# 功能：自动检测 Docker/Podman 并导出统一变量
# 优先级：Podman > Docker
# 使用方法：source include/shell/container_runtime.sh

# ==========================================
# 全局变量（由 detect_container_runtime 设置）
# ==========================================
# CR               容器运行时命令（"podman" 或 "docker"）
# COMPOSE_CMD       Compose 命令（"podman-compose" 或 "docker compose" 或 "docker-compose"）
# CR_IS_PODMAN     "true"/"false" — 是否为 Podman 运行时
# CR_IS_DOCKER     "true"/"false" — 是否为 Docker 运行时
# CR_NEEDS_SUDO    "true"/"false" — 是否需要 sudo 提权
# CR_SUDO          需要时的 sudo 前缀，否则为空

# 默认值（调用 detect_container_runtime 前）
CR=""
COMPOSE_CMD=""
CR_IS_PODMAN="false"
CR_IS_DOCKER="false"
CR_NEEDS_SUDO="false"
CR_SUDO=""

# 运行时判定谓词（单一入口）。
# 调用方用 `cr_is_podman` / `cr_is_docker` 表达意图，而非散落地比较全局字符串。
# 用单括号 [ = ] 书写，避免与代码库中 [[ == "true" ]] 的批量替换冲突。
cr_is_podman() { [ "${CR_IS_PODMAN:-false}" = "true" ]; }
cr_is_docker() { [ "${CR_IS_DOCKER:-false}" = "true" ]; }


_load_container_runtime_preference() {
    local project_root="${PROJECT_ROOT:-}"
    if [[ -z "$project_root" ]]; then
        project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    fi
    local file key val
    for file in "$project_root/.env" "$project_root/.env.local"; do
        [[ -f "$file" ]] || continue
        val="$(grep -E '^[[:space:]]*CONTAINER_RUNTIME=' "$file" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | tr -d '"\047' | xargs -r || true)"
        [[ -n "$val" ]] && CONTAINER_RUNTIME="$val"
    done
    CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-auto}"
}

# ==========================================
# 核心检测函数
# ==========================================
detect_container_runtime() {
    _load_container_runtime_preference

    # 避免重复检测
    if [[ -n "$CR" ]] && [[ -n "$COMPOSE_CMD" ]]; then
        return 0
    fi

    # ----- 预处理：清除无效的 DOCKER_HOST ———————————————————
    # 当 DOCKER_HOST 指向一个不可达的 socket 时（如残留的 podman socket 路径），
    # 自动清除它而不是让整个运行时检测失败
    if [[ -n "${DOCKER_HOST:-}" ]]; then
        local _dh_socket="${DOCKER_HOST#unix://}"
        if [[ "$DOCKER_HOST" == unix://* ]] && [[ ! -S "$_dh_socket" ]]; then
            unset DOCKER_HOST
        fi
    fi

    # ----- 检测 Docker（优先） ————————————————————————————
    if [[ "${CONTAINER_RUNTIME,,}" != "podman" ]] && command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        CR="docker"
        CR_IS_DOCKER="true"
        CR_IS_PODMAN="false"
        CR_NEEDS_SUDO="false"
        CR_SUDO=""

        # 检测 Docker Compose
        if docker compose version &>/dev/null 2>&1; then
            COMPOSE_CMD="docker compose"
        elif docker-compose --version &>/dev/null 2>&1; then
            COMPOSE_CMD="docker-compose"
        else
            COMPOSE_CMD=""
        fi

        return 0
    fi

    # ----- 回退：检测 Podman（需能成功运行 podman info） —————————————
    if [[ "${CONTAINER_RUNTIME,,}" != "docker" ]] && command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
        CR="podman"
        CR_IS_PODMAN="true"
        CR_IS_DOCKER="false"
        CR_NEEDS_SUDO="false"
        CR_SUDO=""

        # 检测 Podman Compose 方案
        if command -v podman-compose &>/dev/null; then
            COMPOSE_CMD="podman-compose"
        elif podman compose version &>/dev/null 2>&1; then
            COMPOSE_CMD="podman compose"
        elif docker compose version &>/dev/null 2>&1; then
            COMPOSE_CMD="docker compose"
        elif docker-compose --version &>/dev/null 2>&1; then
            COMPOSE_CMD="docker-compose"
        else
            COMPOSE_CMD=""
        fi

        return 0
    fi

    # ----- Docker 无常驻进程但命令存在（如需 sudo） ————————————
    if [[ "${CONTAINER_RUNTIME,,}" != "podman" ]] && command -v docker &>/dev/null; then
        CR="docker"
        CR_IS_DOCKER="true"
        CR_IS_PODMAN="false"
        if sudo docker info &>/dev/null 2>&1; then
            CR_NEEDS_SUDO="true"
            CR_SUDO="sudo"
        else
            CR_NEEDS_SUDO="false"
            CR_SUDO=""
        fi

        if docker compose version &>/dev/null 2>&1; then
            COMPOSE_CMD="docker compose"
        elif docker-compose --version &>/dev/null 2>&1; then
            COMPOSE_CMD="docker-compose"
        else
            COMPOSE_CMD=""
        fi

        return 0
    fi

    # ----- 无可用运行时 -----
    CR=""
    COMPOSE_CMD=""
    return 1
}

# ==========================================
# 统一命令执行函数
# ==========================================

# 执行容器运行时命令（自动处理 sudo）
# 用法: cr_cmd ps -a      等价于: docker ps -a 或 podman ps -a
cr_cmd() {
    if [[ -z "$CR" ]]; then
        detect_container_runtime
    fi
    if [[ -z "$CR" ]]; then
        echo "错误: 未找到可用的容器运行时 (docker/podman)" >&2
        return 1
    fi
    $CR_SUDO $CR "$@"
}

# 执行 Compose 命令
# 用法: compose_cmd up -d      等价于: docker compose up -d 或 podman-compose up -d
compose_cmd() {
    if [[ -z "$COMPOSE_CMD" ]]; then
        detect_container_runtime
    fi
    if [[ -z "$COMPOSE_CMD" ]]; then
        echo "错误: 未找到可用的 Compose 工具" >&2
        return 1
    fi
    # COMPOSE_CMD 可能包含空格（如 "docker compose"），所以不用引号包裹
    $COMPOSE_CMD "$@"
}

# 获取 compose 命令字符串（用于嵌套调用）
# 用法: local cc; cc=$(get_compose_cmd_str)
get_compose_cmd_str() {
    if [[ -z "$COMPOSE_CMD" ]]; then
        detect_container_runtime
    fi
    echo "$COMPOSE_CMD"
}

# 获取容器运行时命令字符串
get_cr_str() {
    if [[ -z "$CR" ]]; then
        detect_container_runtime
    fi
    if [[ -n "$CR_SUDO" ]]; then
        echo "$CR_SUDO $CR"
    else
        echo "$CR"
    fi
}

# ==========================================
# 运行时信息输出
# ==========================================
print_runtime_info() {
    if [[ -z "$CR" ]]; then
        detect_container_runtime
    fi

    if [[ -z "$CR" ]]; then
        echo "  容器运行时: ${RED}未检测到${NC}"
        return 1
    fi

    local cr_ver
    cr_ver=$(cr_cmd --version 2>/dev/null | head -1 || echo "未知")
    local compose_ver
    compose_ver=$($COMPOSE_CMD version 2>/dev/null | head -1 || echo "未知")

    echo "  容器运行时  : ${GREEN}${CR}${NC}    ${cr_ver}"
    echo "  Compose 工具 : ${GREEN}${COMPOSE_CMD}${NC}"
    echo "  需要 sudo    : ${CR_NEEDS_SUDO}"
    echo "  Rootless     : $( cr_is_podman && echo '是 (Podman)' || echo '否 (Docker)' )"
}
