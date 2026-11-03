#!/bin/bash
# ============================================================================
# db_backup_restore.sh — MySQL / PostgreSQL 备份与恢复
#
# 引擎：--engine mysql|pgsql
# 兼容：MySQL 客户端 ≥ 8.0（覆盖 8.0 / 8.4 / 9.x）；PostgreSQL 客户端 ≥ 17（覆盖 17 / 18+）
# 退出码：0 成功 | 2 参数错误 | 3 依赖或版本不满足 | 4 连接失败 | 5 备份/恢复执行失败
#
# 连接默认值优先级（高→低，CLI 显式传入最高）：
#   1) 命令行 --host/--port/--user/--password/--socket
#   2) 进程环境 MYSQL_PWD / PGPASSWORD（仅密码）
#   3) 项目根 .env / .env.local + env/mysql.env / env/postgres.env（非敏感端口等）
#   4) 内置默认（host=127.0.0.1，端口 3306/5432）
#
# 运行环境：本仓库 MySQL/PostgreSQL 默认在 WSL 的 Docker 中运行。
#   - Windows 宿主启动时自动检测 WSL，并默认转入 WSL 内执行（可用 --no-wsl-reexec 禁止）
#   - 宿主缺少 mysql/psql 客户端但容器可用时，自动经 docker exec 调用容器内客户端
# 无参数时进入交互菜单；日志与 --dry-run 永不打印明文密码。
# ============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---- 退出码 ----
readonly EC_OK=0
readonly EC_USAGE=2
readonly EC_DEP=3
readonly EC_CONN=4
readonly EC_EXEC=5

# ---- 默认连接参数 ----
ENGINE=""
ACTION="" # backup | restore
HOST=""
PORT=""
USER_NAME=""
PASSWORD=""
SOCKET=""
OUTPUT_DIR="."
BACKUP_ALL=false
INCLUDE_SYSTEM=false
DRY_RUN=false
YES=false
MYSQL_CHARSET="utf8mb4"
MYSQL_COLLATE="utf8mb4_unicode_ci"

# CLI 是否显式设置（避免被 .env 覆盖）
CLI_HOST=false
CLI_PORT=false
CLI_USER=false
CLI_PASSWORD=false
CLI_SOCKET=false

# 库名列表（备份目标 / 恢复过滤）
DB_LIST=()
RESTORE_FILE=""
RESTORE_DIR=""
ONLY_DB="" # --only 别名，与恢复时 --db 等价（单库过滤）

# PostgreSQL 恢复增强（仅对纯 SQL 明文 dump 生效）
#   PG_SKIP_EXT_OBJECTS : 跳过目标库已装扩展自有的函数/类型结构块
#   PG_FIX_BROKEN_CHECK : 修复 "CHECK (CHECK (...))" 畸形约束
#   PG_RESUME_FROM_LINE : 从第 N 行续跑（N=0 表示从头）
PG_SKIP_EXT_OBJECTS=true
PG_FIX_BROKEN_CHECK=true
PG_RESUME_FROM_LINE=0
PG_IMPORT_PROGRESS_FILE=""
PG_IMPORT_TOTAL_LINES=0

# 运行时 / 环境
CLIENT_VERSION=""
TMP_ROOT=""
MYSQL_DEFAULTS_FILE=""
INTERACTIVE_MENU=false
NO_WSL_REEXEC=false
FORCE_DOCKER_EXEC=false
VIA_DOCKER=false # 实际是否走 docker exec
RUNTIME_KIND=""  # windows | wsl | linux
HAS_WSL=false
HAS_DOCKER=false
DOCKER_BIN=""
MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql}"
PG_CONTAINER="${PG_CONTAINER:-postgres}"
ENV_LOADED_FROM=""
declare -a SUCCESS_ITEMS=()
declare -a FAIL_ITEMS=()
# 失败项 → 具体原因（键与 FAIL_ITEMS 元素一致），供摘要逐条说明
declare -A FAIL_REASON=()
declare -a BACKUP_TARGETS=()
declare -a RESTORE_FILES=()

# ============================================================================
# 日志（错误一律 stderr）
# ============================================================================
# 诊断一律 stderr，保证函数 stdout 仅承载可解析数据（库名/文件列表）
info()  { printf '[INFO] %s\n' "$*" >&2; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
die() {
    local code="${1:-$EC_EXEC}"
    shift || true
    error "$*"
    exit "${code}"
}

mask_secret() {
    local s="${1:-}"
    if [[ -z "${s}" ]]; then
        printf '%s' "<empty>"
    else
        printf '%s' "***"
    fi
}

# 登记失败项并立即给出可读原因（同时进入摘要）
# 参数：$1 失败项标识（如 restore:db）；$2 具体原因
fail_with_reason() {
    local item="$1" reason="$2"
    FAIL_ITEMS+=("${item}")
    FAIL_REASON["${item}"]="${reason}"
    error "${item} → ${reason}"
}

# 将命令数组打印为可复核字符串，把紧跟 --password/-p 的值替换为 ***
cmd_preview() {
    local -a out=()
    local prev="" a
    for a in "$@"; do
        if [[ "${prev}" == "--password" || "${prev}" == "-p" || "${prev}" == "-P" ]]; then
            out+=("***")
        elif [[ "${a}" == --password=* || "${a}" == -p=* ]]; then
            out+=("${a%%=*}=***")
        else
            out+=("${a}")
        fi
        prev="${a}"
    done
    printf '%q ' "${out[@]}"
    printf '\n'
}

# dry-run 或实际执行；返回子进程退出码
run_cmd() {
    if [[ "${DRY_RUN}" == true ]]; then
        printf '[DRY-RUN] '
        cmd_preview "$@"
        return 0
    fi
    "$@"
}

cleanup() {
    local rc=$?
    if [[ -n "${MYSQL_DEFAULTS_FILE:-}" && -f "${MYSQL_DEFAULTS_FILE}" ]]; then
        rm -f "${MYSQL_DEFAULTS_FILE}"
    fi
    if [[ -n "${TMP_ROOT:-}" && -d "${TMP_ROOT}" ]]; then
        rm -rf "${TMP_ROOT}"
    fi
    return "${rc}"
}
trap cleanup EXIT

# ============================================================================
# 项目 .env 读取（仅白名单键；不 source 整文件，避免副作用）
# ============================================================================
# 去除首尾空白与成对引号
env_strip_value() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    if [[ "${v}" == \"*\" && "${v}" == *\" ]]; then
        v="${v:1:${#v}-2}"
    elif [[ "${v}" == \'*\' && "${v}" == *\' ]]; then
        v="${v:1:${#v}-2}"
    fi
    printf '%s' "${v}"
}

# env_file_get <file> <KEY> → stdout 值；找不到返回 1
env_file_get() {
    local file="$1" key="$2" line k v
    [[ -f "${file}" ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        [[ "${line}" == export[[:space:]]* ]] && line="${line#export }"
        line="${line#"${line%%[![:space:]]*}"}"
        k="${line%%=*}"
        k="${k%"${k##*[![:space:]]}"}"
        [[ "${k}" == "${key}" ]] || continue
        v="${line#*=}"
        env_strip_value "${v}"
        return 0
    done <"${file}"
    return 1
}

# 按优先级从多个文件取首个非空值
env_lookup() {
    local key="$1" f v
    shift
    for f in "$@"; do
        v="$(env_file_get "${f}" "${key}" 2>/dev/null || true)"
        if [[ -n "${v}" ]]; then
            printf '%s' "${v}"
            return 0
        fi
    done
    return 1
}

# 加载项目连接默认值到全局（不覆盖 CLI 已设字段）
load_project_env_defaults() {
    local -a files=()
    local f v
    for f in \
        "${PROJECT_ROOT}/.env.local" \
        "${PROJECT_ROOT}/.env" \
        "${PROJECT_ROOT}/env/mysql.env" \
        "${PROJECT_ROOT}/env/postgres.env"
    do
        [[ -f "${f}" ]] && files+=("${f}")
    done
    if [[ ${#files[@]} -eq 0 ]]; then
        warn "未找到项目 .env / env/*.env，使用内置默认连接参数"
        return 0
    fi
    ENV_LOADED_FROM="${files[*]}"

    if [[ "${ENGINE}" == "mysql" ]]; then
        if [[ "${CLI_HOST}" != true ]]; then
            v="$(env_lookup MYSQL_BIND_HOST "${files[@]}" || true)"
            HOST="${v:-127.0.0.1}"
        fi
        if [[ "${CLI_PORT}" != true ]]; then
            v="$(env_lookup MYSQL_HOST_PORT "${files[@]}" || true)"
            PORT="${v:-3306}"
        fi
        if [[ "${CLI_USER}" != true ]]; then
            v="$(env_lookup MYSQL_ADMIN_USER "${files[@]}" || true)"
            [[ -z "${v}" ]] && v="root"
            USER_NAME="${v}"
        fi
        if [[ "${CLI_PASSWORD}" != true && -z "${PASSWORD}" ]]; then
            # 进程环境优先于文件
            if [[ -n "${MYSQL_PWD:-}" ]]; then
                PASSWORD="${MYSQL_PWD}"
            else
                v="$(env_lookup MYSQL_ROOT_PASSWORD "${files[@]}" || true)"
                [[ -z "${v}" ]] && v="$(env_lookup MYSQL_PASSWORD "${files[@]}" || true)"
                PASSWORD="${v:-}"
            fi
        fi
    elif [[ "${ENGINE}" == "pgsql" ]]; then
        if [[ "${CLI_HOST}" != true ]]; then
            HOST="127.0.0.1"
        fi
        if [[ "${CLI_PORT}" != true ]]; then
            v="$(env_lookup PG_PORT "${files[@]}" || true)"
            PORT="${v:-5432}"
        fi
        if [[ "${CLI_USER}" != true ]]; then
            v="$(env_lookup PG_USER "${files[@]}" || true)"
            USER_NAME="${v:-postgres}"
        fi
        if [[ "${CLI_PASSWORD}" != true && -z "${PASSWORD}" ]]; then
            if [[ -n "${PGPASSWORD:-}" ]]; then
                PASSWORD="${PGPASSWORD}"
            else
                v="$(env_lookup PG_PASSWORD "${files[@]}" || true)"
                PASSWORD="${v:-}"
            fi
        fi
    fi
}

# ============================================================================
# Windows / WSL / Docker 探测
# ============================================================================
is_wsl_runtime() {
    [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
    [[ -f /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && return 0
    [[ -f /proc/sys/kernel/osrelease ]] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null && return 0
    return 1
}

is_windows_native() {
    # 已在 WSL 内则不算 Windows 原生
    is_wsl_runtime && return 1
    case "$(uname -s 2>/dev/null || true)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
    esac
    case "${OSTYPE:-}" in
        msys*|cygwin*) return 0 ;;
    esac
    case "$(uname -o 2>/dev/null || true)" in
        Msys|Cygwin|Windows*) return 0 ;;
    esac
    return 1
}

find_wsl_exe() {
    if command -v wsl.exe >/dev/null 2>&1; then
        command -v wsl.exe
        return 0
    fi
    if command -v wsl >/dev/null 2>&1; then
        command -v wsl
        return 0
    fi
    for p in /mnt/c/Windows/System32/wsl.exe /c/Windows/System32/wsl.exe \
             "/mnt/c/Program Files/WSL/wsl.exe"; do
        if [[ -x "${p}" ]]; then
            printf '%s' "${p}"
            return 0
        fi
    done
    return 1
}

# Windows 路径 → WSL /mnt 路径（尽力转换）
windows_path_to_wsl() {
    local p="$1"
    # 已是 POSIX
    if [[ "${p}" == /* ]]; then
        printf '%s' "${p}"
        return 0
    fi
    # D:\foo → /mnt/d/foo ； D:/foo → /mnt/d/foo
    if [[ "${p}" =~ ^([A-Za-z]):[\\/](.*)$ ]]; then
        local drive="${BASH_REMATCH[1],,}"
        local rest="${BASH_REMATCH[2]//\\//}"
        printf '/mnt/%s/%s' "${drive}" "${rest}"
        return 0
    fi
    printf '%s' "${p}"
}

docker_available() {
    local bin="${1:-docker}"
    command -v "${bin}" >/dev/null 2>&1 || return 1
    "${bin}" info >/dev/null 2>&1
}

docker_container_running() {
    local name="$1"
    [[ -n "${DOCKER_BIN}" ]] || return 1
    # DOCKER_BIN 可能为 "wsl.exe -e docker"
    # shellcheck disable=SC2086
    ${DOCKER_BIN} ps --format '{{.Names}}' 2>/dev/null | grep -qx "${name}"
}

# 探测并填充 RUNTIME_KIND / HAS_WSL / HAS_DOCKER / DOCKER_BIN
detect_runtime() {
    RUNTIME_KIND="linux"
    HAS_WSL=false
    HAS_DOCKER=false
    DOCKER_BIN=""

    if is_wsl_runtime; then
        RUNTIME_KIND="wsl"
        HAS_WSL=true
    elif is_windows_native; then
        RUNTIME_KIND="windows"
        if find_wsl_exe >/dev/null 2>&1; then
            HAS_WSL=true
        fi
    fi

    if docker_available docker; then
        HAS_DOCKER=true
        DOCKER_BIN="$(command -v docker)"
    elif [[ "${RUNTIME_KIND}" == "windows" && "${HAS_WSL}" == true ]]; then
        local wsl
        wsl="$(find_wsl_exe || true)"
        if [[ -n "${wsl}" ]] && "${wsl}" -e docker info >/dev/null 2>&1; then
            HAS_DOCKER=true
            DOCKER_BIN="${wsl} -e docker"
        fi
    fi
}

print_runtime_status() {
    detect_runtime
    info "======== 运行环境 ========"
    info "脚本路径: ${SCRIPT_DIR}/${SCRIPT_NAME}"
    info "项目根目录: ${PROJECT_ROOT}"
    info "运行时: ${RUNTIME_KIND}  WSL=${HAS_WSL}  Docker=${HAS_DOCKER}"
    if [[ -n "${DOCKER_BIN}" ]]; then
        info "Docker 命令: ${DOCKER_BIN}"
        if [[ "${HAS_DOCKER}" == true ]]; then
            if docker_container_running "${MYSQL_CONTAINER}"; then
                info "MySQL 容器: ${MYSQL_CONTAINER}（运行中）"
            else
                warn "MySQL 容器: ${MYSQL_CONTAINER}（未运行或不存在）"
            fi
            if docker_container_running "${PG_CONTAINER}"; then
                info "PostgreSQL 容器: ${PG_CONTAINER}（运行中）"
            else
                warn "PostgreSQL 容器: ${PG_CONTAINER}（未运行或不存在）"
            fi
        fi
    else
        warn "未检测到可用 Docker（Windows 上将尝试检测 WSL 内 docker）"
    fi
    if [[ -n "${ENV_LOADED_FROM}" ]]; then
        info "已加载配置文件: ${ENV_LOADED_FROM}"
    else
        # 预览加载源（不解析密钥）
        local f
        for f in "${PROJECT_ROOT}/.env.local" "${PROJECT_ROOT}/.env" \
                 "${PROJECT_ROOT}/env/mysql.env" "${PROJECT_ROOT}/env/postgres.env"; do
            [[ -f "${f}" ]] && info "可用配置: ${f}"
        done
    fi
}

# Windows 原生环境下转入 WSL 执行本脚本（保留参数）
maybe_reexec_in_wsl() {
    [[ "${NO_WSL_REEXEC}" == true ]] && return 0
    [[ "${DBBR_SKIP_WSL_REEXEC:-}" == "1" ]] && return 0
    detect_runtime
    [[ "${RUNTIME_KIND}" == "windows" ]] || return 0
    [[ "${HAS_WSL}" == true ]] || {
        warn "当前为 Windows 宿主但未检测到 WSL；将尝试本机执行（数据库若只在 WSL Docker 中，可能连接失败）"
        return 0
    }
    local wsl script_wsl root_wsl
    wsl="$(find_wsl_exe)" || return 0
    script_wsl="$(windows_path_to_wsl "${SCRIPT_DIR}/${SCRIPT_NAME}")"
    root_wsl="$(windows_path_to_wsl "${PROJECT_ROOT}")"
    info "检测到 Windows + WSL：转入 WSL 执行"
    info "  wsl: ${wsl}"
    info "  script: ${script_wsl}"
    # 向 WSL 传递跳过标记，避免循环
    exec "${wsl}" -e bash -lc "export DBBR_SKIP_WSL_REEXEC=1; cd $(printf '%q' "${root_wsl}") && exec bash $(printf '%q' "${script_wsl}") $(printf '%q ' "$@")"
}

# ============================================================================
# 用法
# ============================================================================
show_help() {
    cat <<EOF
用法:
  ${SCRIPT_NAME}                         # 交互菜单
  ${SCRIPT_NAME} --menu                  # 同上
  ${SCRIPT_NAME} --engine mysql|pgsql (--backup|--restore) [选项]

连接默认值来自项目 .env（可被 CLI / MYSQL_PWD|PGPASSWORD 覆盖）：
  MySQL: MYSQL_BIND_HOST, MYSQL_HOST_PORT, MYSQL_ADMIN_USER, MYSQL_ROOT_PASSWORD
  PG:    PG_PORT, PG_USER, PG_PASSWORD

必选（非菜单模式）：
  --engine mysql|pgsql          数据库引擎
  --backup | --restore          操作模式（互斥）

连接：
  --host <addr>                 默认取 .env 的 MYSQL_BIND_HOST 或 127.0.0.1
  --port <n>                    默认 MYSQL_HOST_PORT / PG_PORT
  --user <name>                 默认 MYSQL_ADMIN_USER|root / PG_USER|postgres
  --password <pass>             优先 MYSQL_PWD / PGPASSWORD，再读 .env
  --socket <path>               Unix socket（优先于 host/port）

备份：
  --all                         备份全部用户库（排除系统库）
  --db <name>                   备份指定库（可重复）
  --include-system              不过滤系统库
  --output-dir <dir>            产物目录，默认当前目录

恢复：
  --file <path>                 单个 .sql / .sql.gz(.bz2/.xz/.zst) / .tar.gz
  --dir <path>                  递归收集目录内全部上述格式
                                （压缩 SQL 流式解压，不落地临时文件）
  --db <name> / --only <name>   仅恢复指定库
  --yes                         跳过覆盖确认
  --mysql-charset / --mysql-collate   自动建库字符集（默认 utf8mb4）

PostgreSQL 明文 dump 兼容（仅 --engine pgsql）：
  （默认开启）跳过扩展自有对象   Navicat 等工具会 DROP/CREATE 扩展内置函数，
                                目标库已装 pg_trgm/pgcrypto 等时会报
                                "cannot drop function ... extension ... requires it"
  --pg-keep-extension-objects   关闭上述跳过，按 dump 原样执行
  --pg-no-fix-broken-check      不修复 "CHECK (CHECK (expr) NOT VALID)" 畸形约束
  --pg-resume-from-line <N>     从 dump 第 N 行续跑（用于中断后接着灌，
                                已提交事务不回滚；失败时会提示建议行号）

环境：
  --via-docker                  强制经 docker exec 使用容器内客户端
  --no-wsl-reexec               Windows 下禁止自动转入 WSL
  --dry-run                     只打印命令（密码脱敏）
  --help, -h                    显示本帮助

退出码：0 成功 | 2 参数错误 | 3 依赖/版本 | 4 连接失败 | 5 备份/恢复失败
EOF
}

# ============================================================================
# 参数解析
# ============================================================================
parse_args() {
    if [[ $# -eq 0 ]]; then
        INTERACTIVE_MENU=true
        return 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit "${EC_OK}"
                ;;
            --menu)
                INTERACTIVE_MENU=true
                shift
                ;;
            --engine)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--engine 需要参数"
                ENGINE="$2"
                shift 2
                ;;
            --backup)
                [[ -z "${ACTION}" ]] || die "${EC_USAGE}" "--backup 与 --restore 互斥"
                ACTION="backup"
                shift
                ;;
            --restore)
                [[ -z "${ACTION}" ]] || die "${EC_USAGE}" "--backup 与 --restore 互斥"
                ACTION="restore"
                shift
                ;;
            --host)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--host 需要参数"
                HOST="$2"
                CLI_HOST=true
                shift 2
                ;;
            --port)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--port 需要参数"
                PORT="$2"
                CLI_PORT=true
                shift 2
                ;;
            --user)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--user 需要参数"
                USER_NAME="$2"
                CLI_USER=true
                shift 2
                ;;
            --password)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--password 需要参数"
                PASSWORD="$2"
                CLI_PASSWORD=true
                shift 2
                ;;
            --socket)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--socket 需要参数"
                SOCKET="$2"
                CLI_SOCKET=true
                shift 2
                ;;
            --output-dir)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--output-dir 需要参数"
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --all)
                BACKUP_ALL=true
                shift
                ;;
            --db)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--db 需要参数"
                DB_LIST+=("$2")
                shift 2
                ;;
            --only)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--only 需要参数"
                ONLY_DB="$2"
                DB_LIST+=("$2")
                shift 2
                ;;
            --include-system)
                INCLUDE_SYSTEM=true
                shift
                ;;
            --file)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--file 需要参数"
                RESTORE_FILE="$2"
                shift 2
                ;;
            --dir)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--dir 需要参数"
                RESTORE_DIR="$2"
                shift 2
                ;;
            --yes|-y)
                YES=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --via-docker)
                FORCE_DOCKER_EXEC=true
                shift
                ;;
            --no-wsl-reexec)
                NO_WSL_REEXEC=true
                shift
                ;;
            --mysql-charset)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--mysql-charset 需要参数"
                MYSQL_CHARSET="$2"
                shift 2
                ;;
            --mysql-collate)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--mysql-collate 需要参数"
                MYSQL_COLLATE="$2"
                shift 2
                ;;
            --pg-keep-extension-objects)
                PG_SKIP_EXT_OBJECTS=false
                shift
                ;;
            --pg-no-fix-broken-check)
                PG_FIX_BROKEN_CHECK=false
                shift
                ;;
            --pg-resume-from-line)
                [[ $# -ge 2 ]] || die "${EC_USAGE}" "--pg-resume-from-line 需要参数"
                [[ "$2" =~ ^[0-9]+$ ]] || die "${EC_USAGE}" "--pg-resume-from-line 需为非负整数: $2"
                PG_RESUME_FROM_LINE="$2"
                shift 2
                ;;
            *)
                die "${EC_USAGE}" "未知参数: $1（见 --help）"
                ;;
        esac
    done

    if [[ "${INTERACTIVE_MENU}" == true ]]; then
        return 0
    fi
    validate_args
}

validate_args() {
    case "${ENGINE}" in
        mysql|pgsql) ;;
        "")
            die "${EC_USAGE}" "必须指定 --engine mysql|pgsql"
            ;;
        *)
            die "${EC_USAGE}" "非法 --engine=${ENGINE}，仅支持 mysql|pgsql"
            ;;
    esac

    [[ -n "${ACTION}" ]] || die "${EC_USAGE}" "必须指定 --backup 或 --restore"

    # CLI 未给密码时，先吃进程环境，再让 load_project_env_defaults 补 .env
    if [[ "${CLI_PASSWORD}" != true && -z "${PASSWORD}" ]]; then
        if [[ "${ENGINE}" == "mysql" && -n "${MYSQL_PWD:-}" ]]; then
            PASSWORD="${MYSQL_PWD}"
        elif [[ "${ENGINE}" == "pgsql" && -n "${PGPASSWORD:-}" ]]; then
            PASSWORD="${PGPASSWORD}"
        fi
    fi

    load_project_env_defaults

    if [[ -z "${HOST}" ]]; then
        HOST="127.0.0.1"
    fi
    if [[ -z "${PORT}" ]]; then
        if [[ "${ENGINE}" == "mysql" ]]; then
            PORT="3306"
        else
            PORT="5432"
        fi
    fi
    if [[ -z "${USER_NAME}" ]]; then
        if [[ "${ENGINE}" == "mysql" ]]; then
            USER_NAME="root"
        else
            USER_NAME="${USER:-postgres}"
        fi
    fi

    info "连接参数: engine=${ENGINE} host=${HOST} port=${PORT} user=${USER_NAME} socket=${SOCKET:-<none>} password=$(mask_secret "${PASSWORD}") force_docker=${FORCE_DOCKER_EXEC}"

    if [[ "${ACTION}" == "backup" ]]; then
        if [[ "${BACKUP_ALL}" != true && ${#DB_LIST[@]} -eq 0 ]]; then
            die "${EC_USAGE}" "备份需指定 --all 或至少一个 --db <name>"
        fi
        if [[ "${BACKUP_ALL}" == true && ${#DB_LIST[@]} -gt 0 ]]; then
            die "${EC_USAGE}" "--all 与 --db 互斥"
        fi
        if [[ -n "${RESTORE_FILE}" || -n "${RESTORE_DIR}" ]]; then
            die "${EC_USAGE}" "备份模式不要使用 --file / --dir"
        fi
    fi

    if [[ "${ACTION}" == "restore" ]]; then
        if [[ -z "${RESTORE_FILE}" && -z "${RESTORE_DIR}" ]]; then
            die "${EC_USAGE}" "恢复需指定 --file 或 --dir"
        fi
        if [[ -n "${RESTORE_FILE}" && -n "${RESTORE_DIR}" ]]; then
            die "${EC_USAGE}" "--file 与 --dir 互斥"
        fi
        if [[ "${BACKUP_ALL}" == true ]]; then
            die "${EC_USAGE}" "恢复模式不要使用 --all"
        fi
        # 恢复时多个 --db 仅允许一个过滤目标（或用 --only）
        if [[ ${#DB_LIST[@]} -gt 1 ]]; then
            die "${EC_USAGE}" "恢复时 --db/--only 最多指定一个库名"
        fi
        if [[ ${#DB_LIST[@]} -eq 1 ]]; then
            ONLY_DB="${DB_LIST[0]}"
        fi
    fi
}

# ============================================================================
# 依赖与版本
# ============================================================================
# 比较 semver 主.次：返回 0 表示 a >= b（只比 major.minor）
version_ge_mm() {
    local a="$1" b="$2"
    local a_maj a_min b_maj b_min
    a_maj="${a%%.*}"
    a_min="${a#*.}"
    a_min="${a_min%%.*}"
    b_maj="${b%%.*}"
    b_min="${b#*.}"
    b_min="${b_min%%.*}"
    a_maj="${a_maj:-0}"
    a_min="${a_min:-0}"
    b_maj="${b_maj:-0}"
    b_min="${b_min:-0}"
    if (( a_maj > b_maj )); then
        return 0
    fi
    if (( a_maj < b_maj )); then
        return 1
    fi
    (( a_min >= b_min ))
}

# 从工具 --version 输出抽取 X.Y 或 X.Y.Z
extract_version() {
    local text="$1"
    if [[ "${text}" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

require_cmd() {
    local c
    for c in "$@"; do
        if ! command -v "${c}" >/dev/null 2>&1; then
            die "${EC_DEP}" "缺少依赖命令: ${c}"
        fi
    done
}

# 决定是否经 docker exec 调用客户端
resolve_client_transport() {
    VIA_DOCKER=false
    detect_runtime
    local need_docker=false
    if [[ "${FORCE_DOCKER_EXEC}" == true ]]; then
        need_docker=true
    elif [[ "${ENGINE}" == "mysql" ]]; then
        if ! command -v mysql >/dev/null 2>&1 || ! command -v mysqldump >/dev/null 2>&1; then
            need_docker=true
        fi
    else
        if ! command -v psql >/dev/null 2>&1 || ! command -v pg_dump >/dev/null 2>&1 || ! command -v createdb >/dev/null 2>&1; then
            need_docker=true
        fi
    fi

    if [[ "${need_docker}" != true ]]; then
        return 0
    fi

    [[ "${HAS_DOCKER}" == true && -n "${DOCKER_BIN}" ]] \
        || die "${EC_DEP}" "宿主缺少数据库客户端，且未检测到 Docker（可在 WSL 中安装客户端，或先启动容器）"

    local cname
    if [[ "${ENGINE}" == "mysql" ]]; then
        cname="${MYSQL_CONTAINER}"
    else
        cname="${PG_CONTAINER}"
    fi
    if [[ "${DRY_RUN}" != true ]]; then
        docker_container_running "${cname}" \
            || die "${EC_DEP}" "将经 docker exec 访问，但容器未运行: ${cname}"
    fi
    VIA_DOCKER=true
    info "客户端传输: docker exec → ${cname}"
}

# 在容器内执行命令（DOCKER_BIN 可能含空格，如 "wsl -e docker"）
docker_exec_cmd() {
    local cname="$1"
    shift
    # shellcheck disable=SC2086
    ${DOCKER_BIN} exec -i "${cname}" "$@"
}

check_dependencies() {
    require_cmd tar gzip mktemp
    resolve_client_transport

    local ver_raw=""
    if [[ "${ENGINE}" == "mysql" ]]; then
        if [[ "${VIA_DOCKER}" == true ]]; then
            ver_raw="$(docker_exec_cmd "${MYSQL_CONTAINER}" mysqldump --version 2>&1 || true)"
        else
            require_cmd mysql mysqldump
            ver_raw="$(mysqldump --version 2>&1 || true)"
        fi
        CLIENT_VERSION="$(extract_version "${ver_raw}" || true)"
        if [[ -z "${CLIENT_VERSION}" ]]; then
            die "${EC_DEP}" "无法解析 mysqldump 版本: ${ver_raw}"
        fi
        if ! version_ge_mm "${CLIENT_VERSION}" "8.0"; then
            die "${EC_DEP}" "MySQL 客户端版本 ${CLIENT_VERSION} 低于最低支持 8.0（需 8.0 / 8.4 / 9.x）"
        fi
        info "MySQL 客户端版本: ${CLIENT_VERSION}（兼容范围 ≥ 8.0，via_docker=${VIA_DOCKER}）"
    else
        if [[ "${VIA_DOCKER}" == true ]]; then
            ver_raw="$(docker_exec_cmd "${PG_CONTAINER}" psql --version 2>&1 || true)"
        else
            require_cmd psql pg_dump createdb
            ver_raw="$(psql --version 2>&1 || true)"
        fi
        CLIENT_VERSION="$(extract_version "${ver_raw}" || true)"
        if [[ -z "${CLIENT_VERSION}" ]]; then
            die "${EC_DEP}" "无法解析 psql 版本: ${ver_raw}"
        fi
        if ! version_ge_mm "${CLIENT_VERSION}" "17.0"; then
            die "${EC_DEP}" "PostgreSQL 客户端版本 ${CLIENT_VERSION} 低于最低支持 17（需 17 / 18+）"
        fi
        info "PostgreSQL 客户端版本: ${CLIENT_VERSION}（兼容范围 ≥ 17，via_docker=${VIA_DOCKER}）"
    fi
}

# ============================================================================
# 连接封装（密码不出现在 argv）
# ============================================================================
mysql_write_defaults() {
    MYSQL_DEFAULTS_FILE="$(mktemp "${TMPDIR:-/tmp}/dbbr-mysql.XXXXXX.cnf")"
    chmod 600 "${MYSQL_DEFAULTS_FILE}"
    {
        echo "[client]"
        echo "user=${USER_NAME}"
        if [[ -n "${PASSWORD}" ]]; then
            printf 'password=%s\n' "${PASSWORD}"
        fi
        if [[ "${VIA_DOCKER}" == true ]]; then
            # 容器内连本机 mysqld
            echo "host=127.0.0.1"
            echo "port=3306"
        elif [[ -n "${SOCKET}" ]]; then
            echo "socket=${SOCKET}"
        else
            echo "host=${HOST}"
            echo "port=${PORT}"
        fi
    } >"${MYSQL_DEFAULTS_FILE}"
}

# docker exec 场景：把 cnf 打进容器临时文件（密码不出现在 docker 命令行）
mysql_docker_with_cnf() {
    local tool="$1"
    shift
    local remote_cnf="/tmp/dbbr-$$.cnf"
    local rc=0
    # shellcheck disable=SC2086
    ${DOCKER_BIN} exec -i "${MYSQL_CONTAINER}" sh -c "cat >'${remote_cnf}' && chmod 600 '${remote_cnf}'" <"${MYSQL_DEFAULTS_FILE}"
    # shellcheck disable=SC2086
    ${DOCKER_BIN} exec -i "${MYSQL_CONTAINER}" "${tool}" --defaults-extra-file="${remote_cnf}" "$@" || rc=$?
    # shellcheck disable=SC2086
    ${DOCKER_BIN} exec -i "${MYSQL_CONTAINER}" rm -f "${remote_cnf}" >/dev/null 2>&1 || true
    return "${rc}"
}

mysql_cli() {
    if [[ "${VIA_DOCKER}" == true ]]; then
        mysql_docker_with_cnf mysql --batch --raw --skip-column-names "$@"
    else
        mysql --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" --batch --raw --skip-column-names "$@"
    fi
}

mysqldump_cli() {
    if [[ "${VIA_DOCKER}" == true ]]; then
        mysql_docker_with_cnf mysqldump "$@"
    else
        mysqldump --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" "$@"
    fi
}

pg_env_export() {
    if [[ "${VIA_DOCKER}" == true ]]; then
        export PGHOST="127.0.0.1"
        export PGPORT="5432"
    else
        export PGHOST="${HOST}"
        export PGPORT="${PORT}"
        if [[ -n "${SOCKET}" ]]; then
            export PGHOST="${SOCKET}"
        fi
    fi
    export PGUSER="${USER_NAME}"
    if [[ -n "${PASSWORD}" ]]; then
        export PGPASSWORD="${PASSWORD}"
    fi
}

psql_cli() {
    if [[ "${VIA_DOCKER}" == true ]]; then
        # shellcheck disable=SC2086
        ${DOCKER_BIN} exec -i \
            -e "PGPASSWORD=${PASSWORD}" \
            -e "PGUSER=${USER_NAME}" \
            -e "PGHOST=127.0.0.1" \
            -e "PGPORT=5432" \
            "${PG_CONTAINER}" psql -v ON_ERROR_STOP=1 -At "$@"
    else
        psql -v ON_ERROR_STOP=1 -At "$@"
    fi
}

createdb_cli() {
    local db="$1"
    if [[ "${VIA_DOCKER}" == true ]]; then
        # shellcheck disable=SC2086
        ${DOCKER_BIN} exec -i \
            -e "PGPASSWORD=${PASSWORD}" \
            -e "PGUSER=${USER_NAME}" \
            -e "PGHOST=127.0.0.1" \
            -e "PGPORT=5432" \
            "${PG_CONTAINER}" createdb "${db}"
    else
        createdb "${db}"
    fi
}

pg_dump_cli() {
    local db="$1"
    if [[ "${VIA_DOCKER}" == true ]]; then
        # shellcheck disable=SC2086
        ${DOCKER_BIN} exec -i \
            -e "PGPASSWORD=${PASSWORD}" \
            -e "PGUSER=${USER_NAME}" \
            -e "PGHOST=127.0.0.1" \
            -e "PGPORT=5432" \
            "${PG_CONTAINER}" pg_dump --format=plain --no-owner --no-acl -d "${db}"
    else
        pg_dump --format=plain --no-owner --no-acl -d "${db}"
    fi
}

test_connection() {
    info "测试连接: engine=${ENGINE} host=${HOST} port=${PORT} user=${USER_NAME} socket=${SOCKET:-<none>} password=$(mask_secret "${PASSWORD}") via_docker=${VIA_DOCKER}"
    if [[ "${DRY_RUN}" == true ]]; then
        info "[DRY-RUN] 跳过真实连接测试"
        return 0
    fi
    if [[ "${ENGINE}" == "mysql" ]]; then
        mysql_write_defaults
        if ! mysql_cli -e "SELECT 1" >/dev/null 2>&1; then
            die "${EC_CONN}" "MySQL 连接失败（检查 .env 账密、端口映射、容器状态）"
        fi
    else
        pg_env_export
        if ! psql_cli -d postgres -c "SELECT 1" >/dev/null 2>&1; then
            die "${EC_CONN}" "PostgreSQL 连接失败（检查 .env 账密、端口映射、容器状态）"
        fi
    fi
    info "连接成功"
}

# ============================================================================
# 系统库过滤与枚举
# ============================================================================
is_system_db() {
    local name="$1"
    if [[ "${INCLUDE_SYSTEM}" == true ]]; then
        return 1
    fi
    if [[ "${ENGINE}" == "mysql" ]]; then
        case "${name}" in
            information_schema|mysql|performance_schema|sys) return 0 ;;
            *) return 1 ;;
        esac
    else
        case "${name}" in
            template0|template1|postgres) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

# 列出实例上的用户库到 stdout（一行一个）
list_user_databases() {
    local -a raw=()
    local line
    if [[ "${DRY_RUN}" == true ]]; then
        # dry-run 无法枚举时：若指定了 --db 则回显；--all 则提示占位
        if [[ ${#DB_LIST[@]} -gt 0 ]]; then
            printf '%s\n' "${DB_LIST[@]}"
            return 0
        fi
        info "[DRY-RUN] 将执行数据库枚举（系统库已按规则排除）"
        return 0
    fi

    if [[ "${ENGINE}" == "mysql" ]]; then
        mapfile -t raw < <(mysql_cli -e "SHOW DATABASES")
    else
        mapfile -t raw < <(psql_cli -d postgres -c "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY 1")
    fi

    for line in "${raw[@]}"; do
        [[ -n "${line}" ]] || continue
        if is_system_db "${line}"; then
            continue
        fi
        printf '%s\n' "${line}"
    done
}

# 结果写入全局 BACKUP_TARGETS；返回 0 成功，非 0 失败（勿在进程替换中调用 die）
resolve_backup_targets() {
    BACKUP_TARGETS=()
    local -a available=()
    local d

    if [[ "${BACKUP_ALL}" == true ]]; then
        mapfile -t available < <(list_user_databases)
        if [[ ${#available[@]} -eq 0 || -z "${available[0]:-}" ]]; then
            if [[ "${DRY_RUN}" == true ]]; then
                warn "[DRY-RUN] --all：实际运行时将枚举用户库；当前无实例数据可枚举"
                return 0
            fi
            error "过滤系统库后无用户数据库可备份（可用 --include-system 覆盖排除规则）"
            return 1
        fi
        BACKUP_TARGETS=("${available[@]}")
    else
        mapfile -t available < <(list_user_databases || true)
        for d in "${DB_LIST[@]}"; do
            if [[ "${DRY_RUN}" != true ]]; then
                local found=false
                local a
                for a in "${available[@]:-}"; do
                    if [[ "${a}" == "${d}" ]]; then
                        found=true
                        break
                    fi
                done
                if [[ "${found}" != true ]]; then
                    if is_system_db "${d}"; then
                        error "数据库 ${d} 属于系统默认库，默认排除；如需备份请加 --include-system"
                        return 1
                    fi
                    error "数据库不存在或不在可备份清单中: ${d}"
                    return 1
                fi
            fi
            BACKUP_TARGETS+=("${d}")
        done
    fi

    info "待备份数据库 (${#BACKUP_TARGETS[@]}): ${BACKUP_TARGETS[*]:-<none>}"
    return 0
}

# ============================================================================
# 备份
# ============================================================================
write_metadata() {
    local meta_file="$1"
    local db_name="$2"
    local stamp="$3"
    local extra_args="$4"
    cat >"${meta_file}" <<EOF
engine=${ENGINE}
database=${db_name}
client_version=${CLIENT_VERSION}
backup_time=${stamp}
host=${HOST}
port=${PORT}
user=${USER_NAME}
socket=${SOCKET}
include_system=${INCLUDE_SYSTEM}
backup_args=${extra_args}
tool=${SCRIPT_NAME}
EOF
}

backup_one_mysql() {
    local db="$1"
    local stamp out_base work data_file meta_file archive
    stamp="$(date +"%Y%m%d_%H%M%S")"
    out_base="${ENGINE}_${db}_${stamp}"
    archive="${OUTPUT_DIR}/${out_base}.tar.gz"

    if [[ "${DRY_RUN}" == true ]]; then
        info "[DRY-RUN] 将备份 MySQL 库 ${db} → ${archive}"
        run_cmd mysqldump --defaults-extra-file="<cnf>" \
            --single-transaction --routines --triggers --events \
            --default-character-set=utf8mb4 \
            --databases "${db}"
        return 0
    fi

    work="$(mktemp -d "${TMP_ROOT}/bak.${db}.XXXXXX")"
    data_file="${work}/data.sql"
    meta_file="${work}/metadata.env"

    local dump_args=(
        --single-transaction
        --routines
        --triggers
        --events
        --default-character-set=utf8mb4
        --databases "${db}"
    )

    if ! mysqldump_cli "${dump_args[@]}" >"${data_file}"; then
        rm -rf "${work}"
        rm -f "${archive}"
        return 1
    fi

    write_metadata "${meta_file}" "${db}" "$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')" \
        "--single-transaction --routines --triggers --events --default-character-set=utf8mb4 --databases"

    if ! tar -C "${work}" -czf "${archive}" data.sql metadata.env; then
        rm -rf "${work}"
        rm -f "${archive}"
        return 1
    fi
    rm -rf "${work}"
    info "备份完成: ${archive}"
    return 0
}

backup_one_pgsql() {
    local db="$1"
    local stamp out_base work data_file meta_file archive
    stamp="$(date +"%Y%m%d_%H%M%S")"
    out_base="${ENGINE}_${db}_${stamp}"
    archive="${OUTPUT_DIR}/${out_base}.tar.gz"

    if [[ "${DRY_RUN}" == true ]]; then
        info "[DRY-RUN] 将备份 PostgreSQL 库 ${db} → ${archive}"
        run_cmd pg_dump_cli "${db}"
        return 0
    fi

    work="$(mktemp -d "${TMP_ROOT}/bak.${db}.XXXXXX")"
    data_file="${work}/data.sql"
    meta_file="${work}/metadata.env"

    if ! pg_dump_cli "${db}" >"${data_file}"; then
        rm -rf "${work}"
        rm -f "${archive}"
        return 1
    fi

    write_metadata "${meta_file}" "${db}" "$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')" \
        "--format=plain --no-owner --no-acl"

    if ! tar -C "${work}" -czf "${archive}" data.sql metadata.env; then
        rm -rf "${work}"
        rm -f "${archive}"
        return 1
    fi
    rm -rf "${work}"
    info "备份完成: ${archive}"
    return 0
}

do_backup() {
    local db rc=0

    if [[ "${DRY_RUN}" != true ]]; then
        mkdir -p "${OUTPUT_DIR}"
    else
        info "[DRY-RUN] 将创建输出目录: ${OUTPUT_DIR}"
    fi

    if ! resolve_backup_targets; then
        FAIL_ITEMS+=("backup:resolve_targets")
        return "${EC_EXEC}"
    fi
    if [[ ${#BACKUP_TARGETS[@]} -eq 0 || -z "${BACKUP_TARGETS[0]:-}" ]]; then
        if [[ "${DRY_RUN}" == true && "${BACKUP_ALL}" == true ]]; then
            info "[DRY-RUN] --all 备份流程已演练（无具体库名）"
            return 0
        fi
        error "没有可备份的数据库"
        FAIL_ITEMS+=("backup:empty")
        return "${EC_EXEC}"
    fi

    for db in "${BACKUP_TARGETS[@]}"; do
        info "开始备份: ${db}"
        if [[ "${ENGINE}" == "mysql" ]]; then
            if backup_one_mysql "${db}"; then
                SUCCESS_ITEMS+=("backup:${db}")
            else
                FAIL_ITEMS+=("backup:${db}")
                rc=1
            fi
        else
            if backup_one_pgsql "${db}"; then
                SUCCESS_ITEMS+=("backup:${db}")
            else
                FAIL_ITEMS+=("backup:${db}")
                rc=1
            fi
        fi
    done

    [[ "${rc}" -eq 0 ]] || return "${EC_EXEC}"
    return 0
}

# ============================================================================
# 恢复：收集文件、解析库名、建库、导入
# ============================================================================
# 路径类型自动纠正：--dir 误给文件 / --file 误给目录时自动切换，避免"路径存在却报不存在"
normalize_restore_path() {
    if [[ -n "${RESTORE_FILE}" && -z "${RESTORE_DIR}" && -d "${RESTORE_FILE}" ]]; then
        RESTORE_DIR="${RESTORE_FILE}"
        RESTORE_FILE=""
        info "检测到该路径是目录，已切换为目录恢复模式: ${RESTORE_DIR}"
        return 0
    fi
    if [[ -n "${RESTORE_DIR}" && -z "${RESTORE_FILE}" && -f "${RESTORE_DIR}" ]]; then
        RESTORE_FILE="${RESTORE_DIR}"
        RESTORE_DIR=""
        info "检测到该路径是文件，已切换为单文件恢复模式: ${RESTORE_FILE}"
        return 0
    fi
    return 0
}

# 是否为受支持的 SQL 负载文件（归档 .tar.gz/.tgz 走 unpack_archive，不在此列）
# 参数：$1 路径；返回：0 是，1 否
is_supported_sql_payload() {
    case "$1" in
        *.sql) return 0 ;;
        *.sql.gz|*.sql.bz2|*.sql.xz|*.sql.zst) return 0 ;;
        *) return 1 ;;
    esac
}

# 压缩后缀 → 解压命令；无压缩返回 1
# 参数：$1 路径
sql_decompress_cmd() {
    case "$1" in
        *.gz)  printf 'gzip' ;;
        *.bz2) printf 'bzip2' ;;
        *.xz)  printf 'xz' ;;
        *.zst) printf 'zstd' ;;
        *) return 1 ;;
    esac
}

# 输出明文 SQL 到 stdout；压缩文件流式解压，不落临时文件
# 参数：$1 路径；返回：0 成功，非 0 为读取/解压失败
sql_stream() {
    local path="$1" cmd
    if [[ ! -f "${path}" ]]; then
        error "文件不存在: ${path}"
        return 1
    fi
    if cmd="$(sql_decompress_cmd "${path}")"; then
        require_cmd "${cmd}"
        "${cmd}" -dc "${path}"
    else
        cat "${path}"
    fi
}

# 结果写入全局 RESTORE_FILES；返回 0 成功，非 0 失败
# 注意：不可在 $( ) / <( ) 中调用，否则 die 只会退出子 shell
collect_restore_files() {
    RESTORE_FILES=()
    local f
    normalize_restore_path
    if [[ -n "${RESTORE_FILE}" ]]; then
        if [[ ! -e "${RESTORE_FILE}" ]]; then
            error "恢复文件不存在: ${RESTORE_FILE}"
            return 1
        fi
        if [[ ! -f "${RESTORE_FILE}" ]]; then
            error "不是普通文件: ${RESTORE_FILE}"
            return 1
        fi
        case "${RESTORE_FILE}" in
            *.sql|*.sql.gz|*.sql.bz2|*.sql.xz|*.sql.zst|*.tar.gz|*.tgz) ;;
            *)
                error "不支持的文件类型（支持 .sql / .sql.gz / .sql.bz2 / .sql.xz / .sql.zst / .tar.gz）: ${RESTORE_FILE}"
                return 1
                ;;
        esac
        RESTORE_FILES+=("${RESTORE_FILE}")
        return 0
    fi

    if [[ ! -e "${RESTORE_DIR}" ]]; then
        error "恢复目录不存在: ${RESTORE_DIR}"
        return 1
    fi
    if [[ ! -d "${RESTORE_DIR}" ]]; then
        error "不是目录: ${RESTORE_DIR}（单文件请用 --file）"
        return 1
    fi
    while IFS= read -r -d '' f; do
        RESTORE_FILES+=("${f}")
    done < <(find "${RESTORE_DIR}" -type f \
        \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.sql.bz2' \
           -o -name '*.sql.xz' -o -name '*.sql.zst' \
           -o -name '*.tar.gz' -o -name '*.tgz' \) -print0 | sort -z)
    if [[ ${#RESTORE_FILES[@]} -eq 0 ]]; then
        error "目录中未找到 .sql / .sql.gz / .tar.gz 备份文件: ${RESTORE_DIR}"
        warn "已列出该目录实际文件类型（供核对），若为其他压缩格式请先转换或解压"
        local _ext
        while IFS= read -r _ext; do
            [[ -n "${_ext}" ]] && warn "  发现后缀: .${_ext}"
        done < <(find "${RESTORE_DIR}" -type f -printf '%f\n' 2>/dev/null \
            | sed -nE 's/.*\.([A-Za-z0-9]+)$/\1/p' | sort -u | head -n 10)
        return 1
    fi
    return 0
}

# 从 metadata.env 读键
meta_get() {
    local file="$1" key="$2"
    [[ -f "${file}" ]] || return 1
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" == "${key}="* ]] || continue
        printf '%s' "${line#${key}=}"
        return 0
    done <"${file}"
    return 1
}

# 从 SQL 内容猜测库名
guess_db_from_sql() {
    local sql_file="$1"
    local line name
    # MySQL: CREATE DATABASE [IF NOT EXISTS] `name` / USE `name`
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ [Cc][Rr][Ee][Aa][Tt][Ee][[:space:]]+[Dd][Aa][Tt][Aa][Bb][Aa][Ss][Ee][[:space:]]+([Ii][Ff][[:space:]]+[Nn][Oo][Tt][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+)?[\`\"\']?([A-Za-z0-9_$-]+) ]]; then
            name="${BASH_REMATCH[2]}"
            if [[ -n "${name}" ]]; then
                printf '%s' "${name}"
                return 0
            fi
        fi
        if [[ "${line}" =~ ^[Uu][Ss][Ee][[:space:]]+[\`\"\']?([A-Za-z0-9_$-]+) ]]; then
            name="${BASH_REMATCH[1]}"
            name="${name%;}"
            printf '%s' "${name}"
            return 0
        fi
        # PostgreSQL: \connect name / \c name
        if [[ "${line}" =~ ^\\c(onnect)?[[:space:]]+([^[:space:]]+) ]]; then
            name="${BASH_REMATCH[2]}"
            name="${name%\"}"
            name="${name#\"}"
            printf '%s' "${name}"
            return 0
        fi
        # pg_dump 头部: -- Name: xxx; Type: DATABASE
        if [[ "${line}" =~ ^--[[:space:]]*Name:[[:space:]]*([^;]+)\;[[:space:]]*Type:[[:space:]]*DATABASE ]]; then
            name="${BASH_REMATCH[1]}"
            name="${name#"${name%%[![:space:]]*}"}"
            name="${name%"${name##*[![:space:]]}"}"
            printf '%s' "${name}"
            return 0
        fi
        # Navicat / DBeaver 头部注释: "Source Catalog : beacon_v3" / "Database : xxx"
        if [[ "${line}" =~ ^[[:space:]]*(Source[[:space:]]+Catalog|Source[[:space:]]+Database|Database|Catalog)[[:space:]]*:[[:space:]]*(.+)$ ]]; then
            name="${BASH_REMATCH[2]}"
            name="${name#"${name%%[![:space:]]*}"}"
            name="${name%"${name##*[![:space:]]}"}"
            name="${name%\"}"
            name="${name#\"}"
            if [[ -n "${name}" ]]; then
                printf '%s' "${name}"
                return 0
            fi
        fi
    done < <(sql_stream "${sql_file}" 2>/dev/null | head -n 200 || true)
    return 1
}

# 从文件名解析：{engine}_{db}_{YYYYmmdd_HHMMSS}.tar.gz / *.sql / *.sql.gz
guess_db_from_filename() {
    local path="$1"
    local base
    base="$(basename "${path}")"
    base="${base%.tar.gz}"
    base="${base%.tgz}"
    base="${base%.sql}"
    base="${base%.gz}"
    base="${base%.bz2}"
    base="${base%.xz}"
    base="${base%.zst}"
    # engine_dbname_YYYYMMDD_HHMMSS
    if [[ "${base}" =~ ^(mysql|pgsql)_(.+)_([0-9]{8}_[0-9]{6})$ ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
        return 0
    fi
    # 退化：去掉末尾时间戳
    if [[ "${base}" =~ ^(.+)_([0-9]{8}_[0-9]{6})$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

resolve_target_db() {
    local sql_file="$1"
    local meta_file="${2:-}"
    local src_path="${3:-}"
    local name=""

    # 1) 显式 --db/--only（单文件场景可作为强制目标）
    if [[ -n "${ONLY_DB}" && -n "${RESTORE_FILE}" ]]; then
        printf '%s' "${ONLY_DB}"
        return 0
    fi

    # 2) 元数据
    if [[ -n "${meta_file}" && -f "${meta_file}" ]]; then
        name="$(meta_get "${meta_file}" "database" || true)"
        if [[ -n "${name}" ]]; then
            printf '%s' "${name}"
            return 0
        fi
    fi

    # 3) SQL 内容
    name="$(guess_db_from_sql "${sql_file}" || true)"
    if [[ -n "${name}" ]]; then
        # 内容库名与文件名库名不一致时显式告警：内容优先，但差异必须可见
        local fname
        fname="$(guess_db_from_filename "${src_path}" || true)"
        if [[ -n "${fname}" && "${fname}" != "${name}" ]]; then
            warn "库名冲突: dump 内容指向 [${name}]，文件名暗示 [${fname}]，已按内容为准"
            warn "  如需强制目标库，请显式传入 --db <name>"
        fi
        printf '%s' "${name}"
        return 0
    fi

    # 4) 文件名
    name="$(guess_db_from_filename "${src_path}" || true)"
    if [[ -n "${name}" ]]; then
        printf '%s' "${name}"
        return 0
    fi

    return 1
}

# SQL 标识符单引号转义（仅用于字面量比较，不做标识符拼接以外用途）
sql_quote_literal() {
    local s="$1"
    s="${s//\'/\'\'}"
    printf '%s' "${s}"
}

db_exists() {
    local db="$1"
    local hit lit
    if [[ "${DRY_RUN}" == true ]]; then
        info "[DRY-RUN] 将检测数据库是否存在: ${db}"
        return 1
    fi
    lit="$(sql_quote_literal "${db}")"
    if [[ "${ENGINE}" == "mysql" ]]; then
        hit="$(mysql_cli -e "SELECT SCHEMA_NAME FROM information_schema.schemata WHERE SCHEMA_NAME='${lit}'" || true)"
        [[ -n "${hit}" ]]
    else
        hit="$(psql_cli -d postgres -c "SELECT 1 FROM pg_database WHERE datname='${lit}'" || true)"
        [[ -n "${hit}" ]]
    fi
}

create_database() {
    local db="$1"
    info "目标库不存在，自动创建: ${db}"
    if [[ "${ENGINE}" == "mysql" ]]; then
        local sql="CREATE DATABASE IF NOT EXISTS \`${db}\` DEFAULT CHARACTER SET ${MYSQL_CHARSET} COLLATE ${MYSQL_COLLATE}"
        if [[ "${DRY_RUN}" == true ]]; then
            run_cmd mysql --defaults-extra-file="<cnf>" -e "${sql}"
            return 0
        fi
        mysql_cli -e "${sql}"
    else
        if [[ "${DRY_RUN}" == true ]]; then
            run_cmd createdb_cli "${db}"
            return 0
        fi
        if ! createdb_cli "${db}" 2>/dev/null; then
            db_exists "${db}" || die "${EC_EXEC}" "创建 PostgreSQL 数据库失败: ${db}"
        fi
    fi
}

confirm_restore() {
    local db="$1" src="$2"
    if [[ "${YES}" == true || "${DRY_RUN}" == true ]]; then
        return 0
    fi
    local reply
    read -r -p "即将向库 [${db}] 导入 ${src}（已存在则覆盖数据）。确认继续？[y/N]: " reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

# ----------------------------------------------------------------------------
# PostgreSQL 明文 dump 的兼容预处理
#
# 背景（实测于 beacon_v3 Navicat dump，29.8 GB）：
#   1) Navicat 等工具把扩展（pg_trgm / pgcrypto / pg_stat_statements）自带的
#      函数、类型当成普通对象逐个 DROP/CREATE。目标库若已安装该扩展，DROP 会报
#        cannot drop function ... because extension pg_trgm requires it
#      导致 psql -v ON_ERROR_STOP=1 中止。
#   2) 部分 dump 会导出畸形约束 CHECK (CHECK (expr) NOT VALID)，语法直接报错。
#   3) 中止后已提交的数据不会回滚，需要能从中断处续跑。
#
# 三条对策分别由 --pg-keep-extension-objects / --pg-no-fix-broken-check /
# --pg-resume-from-line 控制，默认全开且日志可见。
# ----------------------------------------------------------------------------

# 列出目标库中「由扩展拥有」的函数与类型，输出 "function|名字" / "type|名字"
# 用途：生成结构块跳过清单；返回 0 且输出可为空
# 注意：本函数可能在管道中间被调用，必须显式 </dev/null，
#       否则 docker exec -i / psql 会抢占并丢弃上游的 SQL 流。
pg_extension_owned_objects() {
    local db="$1"
    psql_cli -d "${db}" -c "
        SELECT 'function|' || p.proname
          FROM pg_depend d
          JOIN pg_proc p ON p.oid = d.objid
          JOIN pg_extension e ON e.oid = d.refobjid
         WHERE d.classid = 'pg_proc'::regclass
           AND d.refclassid = 'pg_extension'::regclass
           AND d.deptype = 'e'
           AND e.extname <> 'plpgsql'
        UNION
        SELECT 'type|' || t.typname
          FROM pg_depend d
          JOIN pg_type t ON t.oid = d.objid
          JOIN pg_extension e ON e.oid = d.refobjid
         WHERE d.classid = 'pg_type'::regclass
           AND d.refclassid = 'pg_extension'::regclass
           AND d.deptype = 'e'
           AND e.extname <> 'plpgsql'
    " </dev/null 2>/dev/null || true
}

# 把 dump 过滤后写到 stdout
# 参数：$1 目标库；$2 进度文件路径（由父进程计算，因本函数在管道左侧子 shell 内运行）
# 输入：stdin 明文 SQL（压缩解锁由 sql_stream 在上游完成）
# 返回：0 正常；awk 侧错误由调用方 pipefail 捕获
pg_stream_filtered() {
    local db="$1" progfile="$2"
    local objfile owned_n

    [[ -n "${TMP_ROOT}" && -d "${TMP_ROOT}" ]] || TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/db_backup_restore.XXXXXX")"
    objfile="${TMP_ROOT}/pg_ext_objects.txt"
    : >"${objfile}"
    : >"${progfile}" 2>/dev/null || true

    if [[ "${PG_SKIP_EXT_OBJECTS}" == true ]]; then
        pg_extension_owned_objects "${db}" >"${objfile}" || true
        owned_n="$(wc -l <"${objfile}" 2>/dev/null || printf '0')"
        owned_n="${owned_n//[[:space:]]/}"
        info "扩展对象保护清单: ${owned_n:-0} 项（跳过目标库已有扩展的自有对象）"
    else
        info "扩展对象保护: 已关闭（--pg-keep-extension-objects）"
    fi

    if [[ "${PG_RESUME_FROM_LINE}" -gt 0 ]]; then
        info "断点续跑: 从第 ${PG_RESUME_FROM_LINE} 行开始（前面已提交的事务不会回滚）"
    fi

    awk -v objfile="${objfile}" \
        -v progfile="${progfile}" \
        -v skip_ext="${PG_SKIP_EXT_OBJECTS}" \
        -v fixchk="${PG_FIX_BROKEN_CHECK}" \
        -v resume="${PG_RESUME_FROM_LINE}" '
    BEGIN {
        if (skip_ext == "true") {
            while ((getline l < objfile) > 0) {
                if (l != "") owned[l] = 1
            }
            close(objfile)
        }
        skipblk = 0
        nskip = 0
        nfix = 0
    }
    {
        if (resume + 0 > 0 && NR < resume + 0) { next }

        # 正在跳过某个结构块，直到块尾的 ALTER ... OWNER TO 行
        if (skipblk == 1) {
            if ($0 ~ /^ALTER (FUNCTION|TYPE) /) { skipblk = 0 }
            next
        }

        # 命中扩展自有对象：整块跳过
        if (skip_ext == "true" && $0 ~ /^-- (Function|Type) structure for /) {
            nm = $0
            sub(/^-- (Function|Type) structure for /, "", nm)
            sub(/[[:space:]]+$/, "", nm)
            kind = ($0 ~ /^-- Function structure for /) ? "function" : "type"
            if ((kind "|" nm) in owned) {
                skipblk = 1
                nskip++
                printf "[INFO] 跳过扩展自有对象: %s %s (dump 第 %d 行)\n", kind, nm, NR > "/dev/stderr"
                next
            }
        }

        line = $0
        # 畸形约束 CHECK (CHECK (expr) NOT VALID) → CHECK (expr) NOT VALID
        if (fixchk == "true" && line ~ /CHECK[[:space:]]*\([[:space:]]*CHECK[[:space:]]*\(/) {
            gsub(/CHECK[[:space:]]*\([[:space:]]*CHECK[[:space:]]*\(/, "CHECK (", line)
            sub(/\)[[:space:]]*;[[:space:]]*$/, ";", line)
            nfix++
            printf "[WARN] 修复畸形 CHECK 约束（dump 第 %d 行）\n", NR > "/dev/stderr"
        }

        print line

        if (NR % 500 == 0 || $0 ~ /^COMMIT;$/) {
            printf "%d\n", NR > progfile
            fflush(progfile)
        }
    }
    END {
        printf "%d\n", NR > progfile
        fflush(progfile)
        close(progfile)
        printf "[INFO] 过滤统计: 跳过对象块 %d 个, 修复畸形约束 %d 处\n", nskip, nfix > "/dev/stderr"
    }
    ' -
}

# 导入失败后给出续跑建议（进度不可用时退化为通用提示）
# 参数：$1 进度文件路径
pg_report_resume_hint() {
    local progfile="${1:-}" last=""
    if [[ "${PG_IMPORT_TOTAL_LINES:-0}" -gt 0 ]]; then
        warn "导入中断（dump 总行数 ${PG_IMPORT_TOTAL_LINES}）；已提交的事务不会回滚。"
    else
        warn "导入中断（压缩流，总行数未知）；已提交的事务不会回滚。"
    fi
    if [[ -n "${progfile}" && -f "${progfile}" ]]; then
        last="$(tail -n 1 "${progfile}" 2>/dev/null || true)"
        last="${last//[[:space:]]/}"
    fi
    if [[ "${last}" =~ ^[0-9]+$ ]]; then
        warn "写入侧进度: 已向 psql 写入至第 ${last} 行（psql 实际执行位置不晚于此行，可能更早）。"
        warn "续跑起点建议: --pg-resume-from-line $((last + 1))"
        warn "若上次中断点在 DDL 段，dump 多用 DROP ... IF EXISTS，回放通常安全；"
        warn "若在数据段，回放可能导致重复插入，请先核对再决定起点。"
    else
        warn "未能记录写入侧进度；请按上方 ERROR 定位语句行号，再用 --pg-resume-from-line <N> 续跑。"
    fi
    warn "常见原因: 报 operator class / function ... does not exist 时，多为目标库缺少对应扩展，"
    warn "  先在目标库执行 CREATE EXTENSION IF NOT EXISTS <扩展名>（如 pg_trgm / pgcrypto）再重试。"
}

# ----------------------------------------------------------------------------
# 导入执行器：区分「数据流（解压/读取）」与「导入端」的失败
#
# 背景（实测于 mysql_baiyou_hospital_data_dev，304 MB / 解压 3.6 GB）：
#   宿主内存被其他进程占满时，gzip 中途 "Cannot allocate memory" 退出，
#   管道下游 mysql 读到被截断的半条 INSERT，抛出
#     ERROR 1064 (42000) at line 4746: ... near '' at line 1
#   若只看导入端退出码，用户会误以为 SQL 文件有语法问题，实际根因在前端。
#
# 因此必须用 PIPESTATUS 分别取各段退出码，并优先以流侧失败定性。
# ----------------------------------------------------------------------------
# 全局输出（供调用方读取）
IMPORT_STREAM_RC=0
IMPORT_FILTER_RC=0
IMPORT_IMPORT_RC=0
IMPORT_FAIL_STAGE=""
IMPORT_FAIL_REASON=""

# 可用内存（MB），读取失败返回 0
mem_available_mb() {
    awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || printf '0'
}

# 流侧失败时的定性说明（区分内存压力与文件/IO 问题）
# 参数：$1 退出码
describe_stream_failure() {
    local rc="$1" avail
    avail="$(mem_available_mb)"
    printf '解压/读取数据流失败（退出码 %s）' "${rc}"
    if [[ "${avail}" =~ ^[0-9]+$ ]] && [[ "${avail}" -lt 1024 ]]; then
        printf '；当前可用内存仅 %s MB，高度疑似内存不足导致解压中断' "${avail}"
    fi
}

# 执行导入管道
# 参数：$1 engine(mysql|pgsql)；$2 库名；$3 SQL 文件；$4 PG 进度文件（仅 pgsql）
# 返回：0 成功；非 0 失败。失败时 IMPORT_FAIL_STAGE / IMPORT_FAIL_REASON 说明原因
run_import_pipeline() {
    local engine="$1" db="$2" sql_file="$3" progfile="${4:-}"
    local -a ps=()
    local had_e=0

    IMPORT_STREAM_RC=0
    IMPORT_FILTER_RC=0
    IMPORT_IMPORT_RC=0
    IMPORT_FAIL_STAGE=""
    IMPORT_FAIL_REASON=""

    # 管道在 set -e + pipefail 下失败会直接终止脚本，需临时关闭以取 PIPESTATUS
    case "$-" in *e*) had_e=1 ;; esac
    set +e
    if [[ "${engine}" == "pgsql" ]]; then
        sql_stream "${sql_file}" \
            | pg_stream_filtered "${db}" "${progfile}" \
            | psql_cli -d "${db}" >/dev/null
        ps=("${PIPESTATUS[@]}")
    else
        sql_stream "${sql_file}" | mysql_cli --database="${db}"
        ps=("${PIPESTATUS[@]}")
    fi
    [[ "${had_e}" -eq 1 ]] && set -e

    IMPORT_STREAM_RC="${ps[0]:-0}"
    if [[ "${engine}" == "pgsql" ]]; then
        IMPORT_FILTER_RC="${ps[1]:-0}"
        IMPORT_IMPORT_RC="${ps[2]:-0}"
    else
        IMPORT_IMPORT_RC="${ps[1]:-0}"
    fi

    # 全部成功
    if [[ "${IMPORT_STREAM_RC}" -eq 0 && "${IMPORT_FILTER_RC}" -eq 0 && "${IMPORT_IMPORT_RC}" -eq 0 ]]; then
        return 0
    fi

    # 流侧失败优先定性：下游的 SQL 报错多为截断后的次生现象
    if [[ "${IMPORT_STREAM_RC}" -ne 0 ]]; then
        IMPORT_FAIL_STAGE="stream"
        IMPORT_FAIL_REASON="$(describe_stream_failure "${IMPORT_STREAM_RC}")"
        return "${IMPORT_STREAM_RC}"
    fi
    if [[ "${IMPORT_FILTER_RC}" -ne 0 ]]; then
        IMPORT_FAIL_STAGE="filter"
        IMPORT_FAIL_REASON="SQL 过滤/预处理阶段失败（退出码 ${IMPORT_FILTER_RC}）"
        return "${IMPORT_FILTER_RC}"
    fi
    IMPORT_FAIL_STAGE="import"
    IMPORT_FAIL_REASON="数据库执行 SQL 失败（导入端退出码 ${IMPORT_IMPORT_RC}）"
    return "${IMPORT_IMPORT_RC}"
}

# 导入失败后输出成因链与处置建议
# 参数：$1 库名；$2 SQL 文件；$3 PG 进度文件（可空）
report_import_failure() {
    local db="$1" sql_file="$2" progfile="${3:-}"
    local size_h
    size_h="$(du -h "${sql_file}" 2>/dev/null | awk '{print $1}')"

    error "恢复失败详情: 库=${db} 文件=$(basename "${sql_file}") 大小=${size_h:-?}"
    case "${IMPORT_FAIL_STAGE}" in
        stream)
            error "失败阶段: 解压/读取数据流"
            error "原因: ${IMPORT_FAIL_REASON}"
            error "影响: SQL 流在途中被截断，导入端随后的语法错误（如 1064 near ''）是次生现象，"
            error "      并非 dump 文件本身有语法问题；目标库可能只导入了一部分表。"
            error "核对: 该文件可先用 gzip -t 验完整性，通过则说明文件无损、问题在运行环境"
            error "处置: 1) 释放内存（关闭占用大的进程）后重试本库"
            error "      2) 或改用落盘解压再导入，规避管道内存压力："
            error "         gzip -dc '${sql_file}' > /path/free_space/dump.sql"
            error "         然后 --restore --file /path/free_space/dump.sql --db ${db}"
            ;;
        filter)
            error "失败阶段: SQL 过滤/预处理"
            error "原因: ${IMPORT_FAIL_REASON}"
            error "处置: 可先用 --pg-keep-extension-objects / --pg-no-fix-broken-check 关闭过滤定位问题"
            ;;
        import)
            error "失败阶段: 数据库执行 SQL"
            error "原因: ${IMPORT_FAIL_REASON}"
            error "提示: 上方 ERROR 行给出了具体语句位置与数据库原始报错"
            if [[ "${ENGINE}" == "pgsql" ]]; then
                pg_report_resume_hint "${progfile}"
            fi
            ;;
        *)
            error "失败阶段: 未知（${IMPORT_FAIL_REASON:-无详细信息}）"
            ;;
    esac
}

import_mysql_sql() {
    local db="$1" sql_file="$2"
    if [[ "${DRY_RUN}" == true ]]; then
        local _dec=""
        _dec="$(sql_decompress_cmd "${sql_file}" || true)"
        if [[ -n "${_dec}" ]]; then
            info "[DRY-RUN] ${_dec} -dc ${sql_file} | mysql --database=${db}"
        else
            run_cmd mysql --defaults-extra-file="<cnf>" --database="${db}" -e "SOURCE ${sql_file}"
        fi
        return 0
    fi
    run_import_pipeline mysql "${db}" "${sql_file}" ""
}

import_pgsql_sql() {
    local db="$1" sql_file="$2" rc=0 progfile dec=""
    dec="$(sql_decompress_cmd "${sql_file}" || true)"
    if [[ "${DRY_RUN}" == true ]]; then
        if [[ -n "${dec}" ]]; then
            info "[DRY-RUN] ${dec} -dc ${sql_file} | psql -d ${db}"
        else
            run_cmd psql -d "${db}" -f "${sql_file}"
        fi
        info "[DRY-RUN] 过滤开关: skip_ext=${PG_SKIP_EXT_OBJECTS} fix_check=${PG_FIX_BROKEN_CHECK} resume_from=${PG_RESUME_FROM_LINE}"
        return 0
    fi

    # 进度文件路径必须在父进程确定：pg_stream_filtered 位于管道左侧子 shell，
    # 其内部赋值的全局变量不会回传到父进程。
    [[ -n "${TMP_ROOT}" && -d "${TMP_ROOT}" ]] || TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/db_backup_restore.XXXXXX")"
    progfile="${TMP_ROOT}/pg_import_progress.txt"
    PG_IMPORT_PROGRESS_FILE="${progfile}"
    if [[ -n "${dec}" ]]; then
        # 压缩流无法廉价预知行数，保持 0 表示未知
        PG_IMPORT_TOTAL_LINES=0
    else
        PG_IMPORT_TOTAL_LINES="$(wc -l <"${sql_file}" 2>/dev/null || printf '0')"
        PG_IMPORT_TOTAL_LINES="${PG_IMPORT_TOTAL_LINES//[[:space:]]/}"
    fi

    # 经 docker exec 时容器内看不到宿主路径，统一走 stdin
    run_import_pipeline pgsql "${db}" "${sql_file}" "${progfile}"
}

# 解包 tar.gz，设置全局 RESTORE_SQL / RESTORE_META
unpack_archive() {
    local archive="$1"
    local work
    work="$(mktemp -d "${TMP_ROOT}/restore.XXXXXX")"
    if [[ "${DRY_RUN}" == true ]]; then
        info "[DRY-RUN] 将解包 ${archive} → 临时目录"
        RESTORE_SQL=""
        RESTORE_META=""
        RESTORE_WORK="${work}"
        return 0
    fi
    tar -xzf "${archive}" -C "${work}" || {
        error "解包失败（文件可能损坏或不是 tar.gz）: ${archive}"
        rm -rf "${work}"
        return 1
    }
    if [[ -f "${work}/data.sql" ]]; then
        RESTORE_SQL="${work}/data.sql"
    else
        # 取第一个 .sql
        RESTORE_SQL="$(find "${work}" -type f -name '*.sql' | head -n 1 || true)"
    fi
    if [[ -f "${work}/metadata.env" ]]; then
        RESTORE_META="${work}/metadata.env"
    else
        RESTORE_META="$(find "${work}" -type f -name 'metadata*' | head -n 1 || true)"
    fi
    RESTORE_WORK="${work}"
    if [[ -z "${RESTORE_SQL}" ]]; then
        error "压缩包内未找到 SQL 数据文件: ${archive}"
        return 1
    fi
    return 0
}

restore_one_file() {
    local path="$1"
    local db sql_file meta_file=""

    RESTORE_SQL=""
    RESTORE_META=""
    RESTORE_WORK=""

    case "${path}" in
        *.tar.gz|*.tgz)
            if [[ "${DRY_RUN}" == true ]]; then
                info "[DRY-RUN] 处理归档: ${path}"
                db="$(guess_db_from_filename "${path}" || true)"
                if [[ -z "${db}" && -n "${ONLY_DB}" ]]; then
                    db="${ONLY_DB}"
                fi
                if [[ -z "${db}" ]]; then
                    error "无法从文件名确定库名，实际运行需包内元数据或 --db: ${path}"
                    FAIL_ITEMS+=("restore:${path}")
                    return 1
                fi
                if [[ -n "${ONLY_DB}" && "${db}" != "${ONLY_DB}" ]]; then
                    info "跳过（--only=${ONLY_DB}）: ${path} → ${db}"
                    return 0
                fi
                info "[DRY-RUN] 目标库=${db}"
                if ! db_exists "${db}"; then
                    create_database "${db}"
                fi
                run_cmd echo "import ${path} into ${db}"
                SUCCESS_ITEMS+=("restore:${db}")
                return 0
            fi
            if ! unpack_archive "${path}"; then
                FAIL_ITEMS+=("unpack:${path}")
                return 1
            fi
            sql_file="${RESTORE_SQL}"
            meta_file="${RESTORE_META}"
            ;;
        *.sql|*.sql.gz|*.sql.bz2|*.sql.xz|*.sql.zst)
            sql_file="${path}"
            ;;
        *)
            error "跳过不支持的文件: ${path}"
            FAIL_ITEMS+=("restore:${path}")
            return 1
            ;;
    esac

    # 引擎一致性校验：避免把 MySQL 备份灌进 PostgreSQL（或反之）
    if [[ -n "${meta_file}" && -f "${meta_file}" ]]; then
        local meta_engine
        meta_engine="$(meta_get "${meta_file}" "engine" || true)"
        if [[ -n "${meta_engine}" && "${meta_engine}" != "${ENGINE}" ]]; then
            error "备份引擎为 ${meta_engine}，与 --engine ${ENGINE} 不一致，已跳过: ${path}"
            FAIL_ITEMS+=("engine-mismatch:${path}")
            return 1
        fi
    fi

    # 无元数据时，用文件名前缀兜底判定引擎（如 mysql_xxx.sql.gz / pgsql_xxx.tar.gz）
    case "$(basename "${path}")" in
        mysql_*)
            if [[ "${ENGINE}" != "mysql" ]]; then
                error "文件名指示 MySQL 备份，与 --engine ${ENGINE} 不一致，已跳过: ${path}"
                FAIL_ITEMS+=("engine-mismatch:${path}")
                return 1
            fi
            ;;
        pgsql_*|pg_*)
            if [[ "${ENGINE}" != "pgsql" ]]; then
                error "文件名指示 PostgreSQL 备份，与 --engine ${ENGINE} 不一致，已跳过: ${path}"
                FAIL_ITEMS+=("engine-mismatch:${path}")
                return 1
            fi
            ;;
    esac

    if ! db="$(resolve_target_db "${sql_file}" "${meta_file:-}" "${path}")"; then
        error "无法确定目标库名，请显式传入 --db: ${path}"
        warn "提示：可解析的文件名形如 {engine}_{db}_{YYYYmmdd_HHMMSS}.sql[.gz]；当前文件名: $(basename "${path}")"
        FAIL_ITEMS+=("restore:${path}")
        return 1
    fi

    # 目录恢复过滤
    if [[ -n "${ONLY_DB}" && -n "${RESTORE_DIR}" && "${db}" != "${ONLY_DB}" ]]; then
        info "跳过（--only/--db=${ONLY_DB}）: ${path} → ${db}"
        return 0
    fi

    info "恢复文件 ${path} → 库 ${db}"

    if ! confirm_restore "${db}" "${path}"; then
        warn "用户取消: ${path}"
        FAIL_ITEMS+=("cancel:${db}")
        return 1
    fi

    if ! db_exists "${db}"; then
        create_database "${db}" || {
            FAIL_ITEMS+=("create:${db}")
            return 1
        }
    else
        info "目标库已存在，将直接导入覆盖: ${db}"
    fi

    if [[ "${ENGINE}" == "mysql" ]]; then
        if import_mysql_sql "${db}" "${sql_file}"; then
            SUCCESS_ITEMS+=("restore:${db}")
        else
            report_import_failure "${db}" "${sql_file}" "${PG_IMPORT_PROGRESS_FILE:-}"
            fail_with_reason "restore:${db}" "${IMPORT_FAIL_REASON:-SQL 导入失败}"
            return 1
        fi
    else
        if import_pgsql_sql "${db}" "${sql_file}"; then
            SUCCESS_ITEMS+=("restore:${db}")
        else
            report_import_failure "${db}" "${sql_file}" "${PG_IMPORT_PROGRESS_FILE:-}"
            fail_with_reason "restore:${db}" "${IMPORT_FAIL_REASON:-SQL 导入失败}"
            return 1
        fi
    fi
    return 0
}

do_restore() {
    local f rc=0

    if ! collect_restore_files; then
        fail_with_reason "restore:resolve_files" "未能收集到可恢复的备份文件（见上方错误与后缀提示）"
        return "${EC_EXEC}"
    fi
    info "待恢复文件 (${#RESTORE_FILES[@]}):"
    for f in "${RESTORE_FILES[@]}"; do
        info "  - ${f}"
    done

    for f in "${RESTORE_FILES[@]}"; do
        if ! restore_one_file "${f}"; then
            rc=1
        fi
    done

    [[ "${rc}" -eq 0 ]] || return "${EC_EXEC}"
    return 0
}

# ============================================================================
# 汇总
# ============================================================================
print_summary() {
    info "======== 结果摘要 ========"
    info "成功 (${#SUCCESS_ITEMS[@]}): ${SUCCESS_ITEMS[*]:-<none>}"
    if [[ ${#FAIL_ITEMS[@]} -gt 0 ]]; then
        error "失败 (${#FAIL_ITEMS[@]}):"
        local it
        for it in "${FAIL_ITEMS[@]}"; do
            if [[ -n "${FAIL_REASON[${it}]:-}" ]]; then
                error "  - ${it}"
                error "    原因: ${FAIL_REASON[${it}]}"
            else
                error "  - ${it}"
            fi
        done
    else
        info "失败 (0): <none>"
    fi
}

# ============================================================================
# 交互菜单
# ============================================================================
reset_operation_state() {
    ACTION=""
    ENGINE=""
    BACKUP_ALL=false
    INCLUDE_SYSTEM=false
    DB_LIST=()
    RESTORE_FILE=""
    RESTORE_DIR=""
    ONLY_DB=""
    SUCCESS_ITEMS=()
    FAIL_ITEMS=()
    FAIL_REASON=()
    BACKUP_TARGETS=()
    VIA_DOCKER=false
    CLIENT_VERSION=""
}

prompt_line() {
    local tip="$1"
    local val=""
    read -r -p "${tip}: " val || return 1
    printf '%s' "${val}"
}

menu_prompt_output_dir() {
    local d
    d="$(prompt_line "输出目录（默认 ${OUTPUT_DIR}）")" || return 1
    [[ -n "${d}" ]] && OUTPUT_DIR="${d}"
    return 0
}

menu_run_action() {
    TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/db_backup_restore.XXXXXX")"
    validate_args
    check_dependencies
    test_connection
    local rc=0
    case "${ACTION}" in
        backup) do_backup || rc=$? ;;
        restore) do_restore || rc=$? ;;
        *) error "未知操作"; rc="${EC_USAGE}" ;;
    esac
    print_summary
    # 清理本次临时目录，供菜单下一轮复用 trap 全局清理
    if [[ -n "${TMP_ROOT:-}" && -d "${TMP_ROOT}" ]]; then
        rm -rf "${TMP_ROOT}"
        TMP_ROOT=""
    fi
    if [[ -n "${MYSQL_DEFAULTS_FILE:-}" && -f "${MYSQL_DEFAULTS_FILE}" ]]; then
        rm -f "${MYSQL_DEFAULTS_FILE}"
        MYSQL_DEFAULTS_FILE=""
    fi
    return "${rc}"
}

menu_backup() {
    local eng="$1" mode db
    reset_operation_state
    ENGINE="${eng}"
    ACTION="backup"
    echo ""
    echo "备份范围: 1) 全部用户库(--all)  2) 指定库(--db)  0) 返回"
    read -r -p "请选择: " mode || return 0
    case "${mode}" in
        1) BACKUP_ALL=true ;;
        2)
            db="$(prompt_line "数据库名（多个用空格分隔）")" || return 0
            [[ -n "${db}" ]] || { warn "未输入库名"; return 0; }
            # shellcheck disable=SC2206
            DB_LIST=(${db})
            ;;
        0|"") return 0 ;;
        *) warn "无效选项"; return 0 ;;
    esac
    menu_prompt_output_dir || return 0
    read -r -p "是否 dry-run？[y/N]: " mode
    [[ "${mode}" =~ ^[Yy]$ ]] && DRY_RUN=true || DRY_RUN=false
    menu_run_action || true
    DRY_RUN=false
}

menu_restore() {
    local eng="$1" mode path only
    reset_operation_state
    ENGINE="${eng}"
    ACTION="restore"
    echo ""
    echo "恢复来源: 1) 单个文件(--file)  2) 目录(--dir)  0) 返回"
    read -r -p "请选择: " mode || return 0
    case "${mode}" in
        1)
            path="$(prompt_line "备份文件路径 (.sql/.tar.gz)")" || return 0
            RESTORE_FILE="${path}"
            ;;
        2)
            path="$(prompt_line "备份目录路径")" || return 0
            RESTORE_DIR="${path}"
            only="$(prompt_line "仅恢复指定库（可空=全部）")" || true
            if [[ -n "${only}" ]]; then
                ONLY_DB="${only}"
                DB_LIST=("${only}")
            fi
            ;;
        0|"") return 0 ;;
        *) warn "无效选项"; return 0 ;;
    esac
    # PostgreSQL 明文 dump 增强选项（仅 pgsql 生效）
    if [[ "${eng}" == "pgsql" ]]; then
        menu_pg_options || return 0
        info "PG 增强: skip_ext=${PG_SKIP_EXT_OBJECTS} fix_check=${PG_FIX_BROKEN_CHECK} resume_from=${PG_RESUME_FROM_LINE}"
    fi
    read -r -p "跳过覆盖确认？[--yes] [y/N]: " mode
    [[ "${mode}" =~ ^[Yy]$ ]] && YES=true || YES=false
    read -r -p "是否 dry-run？[y/N]: " mode
    [[ "${mode}" =~ ^[Yy]$ ]] && DRY_RUN=true || DRY_RUN=false
    menu_run_action || true
    DRY_RUN=false
    YES=false
}

# PostgreSQL 恢复增强子菜单（仅作用于明文 SQL dump）
# 返回：0 继续；非 0 表示用户取消
menu_pg_options() {
    local opt line skip_txt fix_txt
    while :; do
        if [[ "${PG_SKIP_EXT_OBJECTS}" == true ]]; then skip_txt="开"; else skip_txt="关"; fi
        if [[ "${PG_FIX_BROKEN_CHECK}" == true ]]; then fix_txt="开"; else fix_txt="关"; fi
        echo ""
        echo "PostgreSQL 恢复增强（默认全开，直接回车即用当前配置）:"
        echo "  1) 跳过扩展自有对象       当前: ${skip_txt}"
        echo "  2) 修复畸形 CHECK 约束    当前: ${fix_txt}"
        echo "  3) 续跑起点行             当前: ${PG_RESUME_FROM_LINE}（0=从头）"
        echo "  0) 完成并继续恢复"
        read -r -p "请选择: " opt || return 0
        case "${opt}" in
            1) if [[ "${PG_SKIP_EXT_OBJECTS}" == true ]]; then PG_SKIP_EXT_OBJECTS=false; else PG_SKIP_EXT_OBJECTS=true; fi ;;
            2) if [[ "${PG_FIX_BROKEN_CHECK}" == true ]]; then PG_FIX_BROKEN_CHECK=false; else PG_FIX_BROKEN_CHECK=true; fi ;;
            3)
                line="$(prompt_line "起始行号（0=从头）")" || continue
                if [[ "${line}" =~ ^[0-9]+$ ]]; then
                    PG_RESUME_FROM_LINE="${line}"
                else
                    warn "需为非负整数: ${line}"
                fi
                ;;
            0|"") return 0 ;;
            *) warn "无效选项" ;;
        esac
    done
}

menu_show_conn_preview() {
    local eng
    echo ""
    echo "预览引擎: 1) MySQL  2) PostgreSQL  0) 返回"
    read -r -p "请选择: " eng || return 0
    case "${eng}" in
        1) ENGINE=mysql ;;
        2) ENGINE=pgsql ;;
        0|"") return 0 ;;
        *) warn "无效选项"; return 0 ;;
    esac
    # 仅加载默认值，不要求 ACTION
    local saved_action="${ACTION}"
    ACTION="backup"
    BACKUP_ALL=true
    load_project_env_defaults
    [[ -n "${HOST}" ]] || HOST="127.0.0.1"
    [[ -n "${PORT}" ]] || { [[ "${ENGINE}" == mysql ]] && PORT=3306 || PORT=5432; }
    [[ -n "${USER_NAME}" ]] || { [[ "${ENGINE}" == mysql ]] && USER_NAME=root || USER_NAME=postgres; }
    info "engine=${ENGINE} host=${HOST} port=${PORT} user=${USER_NAME} password=$(mask_secret "${PASSWORD}")"
    info "配置来源: ${ENV_LOADED_FROM:-<builtin>}"
    ACTION="${saved_action}"
}

start_menu() {
    local choice
    detect_runtime
    print_runtime_status
    while :; do
        echo ""
        echo "=============================================="
        echo "  db_backup_restore  （项目: ${PROJECT_ROOT}）"
        echo "=============================================="
        echo "  1) 刷新环境检测（WSL / Docker / 容器）"
        echo "  2) MySQL 备份"
        echo "  3) MySQL 恢复"
        echo "  4) PostgreSQL 备份"
        echo "  5) PostgreSQL 恢复"
        echo "  6) 查看连接默认值（脱敏，来自 .env）"
        echo "  7) 帮助"
        echo "  0) 退出"
        echo "=============================================="
        read -r -p "请输入序号: " choice || exit "${EC_OK}"
        case "${choice}" in
            1) print_runtime_status ;;
            2) menu_backup mysql ;;
            3) menu_restore mysql ;;
            4) menu_backup pgsql ;;
            5) menu_restore pgsql ;;
            6) menu_show_conn_preview ;;
            7) show_help ;;
            0|"") exit "${EC_OK}" ;;
            *) warn "无效选项: ${choice}" ;;
        esac
    done
}

# ============================================================================
# main
# ============================================================================
run_once() {
    TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/db_backup_restore.XXXXXX")"
    check_dependencies
    test_connection
    local rc=0
    case "${ACTION}" in
        backup) do_backup || rc=$? ;;
        restore) do_restore || rc=$? ;;
        *) die "${EC_USAGE}" "内部错误：未知 ACTION=${ACTION}" ;;
    esac
    print_summary
    if [[ "${rc}" -ne 0 ]]; then
        exit "${EC_EXEC}"
    fi
    exit "${EC_OK}"
}

main() {
    # 预扫：re-exec 发生在 parse_args 之前，需提前识别开关
    local _a
    for _a in "$@"; do
        case "${_a}" in
            --no-wsl-reexec) NO_WSL_REEXEC=true ;;
            --help|-h)
                show_help
                exit "${EC_OK}"
                ;;
        esac
    done

    # Windows 宿主：优先转入 WSL（菜单与子命令均适用）
    maybe_reexec_in_wsl "$@"

    parse_args "$@"

    if [[ "${INTERACTIVE_MENU}" == true ]]; then
        start_menu
        exit "${EC_OK}"
    fi

    run_once
}

# 被 source 时不自动执行，便于函数级单测
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
