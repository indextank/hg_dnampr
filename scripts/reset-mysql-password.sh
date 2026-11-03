#!/bin/bash
# ==========================================
# MySQL密码重置脚本
# ==========================================
# 功能：重置 Docker/Podman 容器中 MySQL 的 root/dev 密码
# 默认从 env/mysql.env / env/postgres.env / env/mongodb.env 读取；未知旧密码时自动走 skip-grant-tables 恢复
#
# 使用方法：
#   ./reset-mysql-password.sh
#   ./reset-mysql-password.sh -r 'new_root_pass' -u 'new_dev_pass'
#   ./reset-mysql-password.sh --force-skip-grant
# ==========================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql}"
FORCE_SKIP_GRANT=false
RANDOM_PASSWORDS=false

# shellcheck source=/dev/null
source "$PROJECT_ROOT/include/shell/container_runtime.sh"
detect_container_runtime

_load_env_kv() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    while IFS= read -r _line; do
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$_line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
        _key="${_line%%=*}"
        _val="${_line#*=}"
        if [[ "$_val" == \"*\" ]]; then
            _val="${_val:1:${#_val}-2}"
        elif [[ "$_val" == \'*\' ]]; then
            _val="${_val:1:${#_val}-2}"
        fi
        export "${_key}=${_val}"
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$file" 2>/dev/null || true)
}

_sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

_cr_exec() {
    ${CR_SUDO:+$CR_SUDO }$CR exec "$MYSQL_CONTAINER" "$@"
}

# 使用临时 cnf 文件测试 MySQL 连接
_mysql_try_connect() {
    local pass="$1"
    local cnf
    cnf="$(mktemp)"
    chmod 600 "$cnf"
    # 单引号确保 $cnf 在 RETURN 时才展开
    # shellcheck disable=SC2064
    trap "rm -f '$cnf'" RETURN
    printf '[client]\nuser=root\npassword=%s\n' "$pass" >"$cnf"
    ${CR_SUDO:+$CR_SUDO }$CR cp "$cnf" "${MYSQL_CONTAINER}:/tmp/.reset-mysql.cnf" >/dev/null 2>&1 || true
    if _cr_exec mysql --defaults-extra-file=/tmp/.reset-mysql.cnf -hlocalhost -e "SELECT 1" >/dev/null 2>&1; then
        _cr_exec rm -f /tmp/.reset-mysql.cnf >/dev/null 2>&1 || true
        return 0
    fi
    _cr_exec rm -f /tmp/.reset-mysql.cnf >/dev/null 2>&1 || true
    return 1
}

# 使用临时 cnf 文件执行 SQL（以 root 身份）
_mysql_run_sql_with_pass() {
    local pass="$1"
    local sql="$2"
    local cnf
    cnf="$(mktemp)"
    chmod 600 "$cnf"
    # shellcheck disable=SC2064
    trap "rm -f '$cnf'" RETURN
    printf '[client]\nuser=root\npassword=%s\n' "$pass" >"$cnf"
    ${CR_SUDO:+$CR_SUDO }$CR cp "$cnf" "${MYSQL_CONTAINER}:/tmp/.reset-mysql.cnf" >/dev/null 2>&1 || true
    _cr_exec mysql --defaults-extra-file=/tmp/.reset-mysql.cnf -hlocalhost -e "$sql"
    _cr_exec rm -f /tmp/.reset-mysql.cnf >/dev/null 2>&1 || true
}

_reset_root_with_known_pass() {
    local known_pass="$1"
    local new_pass="$2"
    local esc
    esc="$(_sql_escape "$new_pass")"
    _mysql_run_sql_with_pass "$known_pass" "
        ALTER USER 'root'@'localhost' IDENTIFIED BY '${esc}';
        CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${esc}';
        ALTER USER 'root'@'%' IDENTIFIED BY '${esc}';
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
        FLUSH PRIVILEGES;
    "
}

_reset_via_skip_grant() {
    local new_pass="$1"
    local data_path image recovery_name esc
    esc="$(_sql_escape "$new_pass")"

    data_path="${MYSQL_DATA_PATH:-}"
    if [[ -z "$data_path" ]]; then
        data_path="$(${CR_SUDO:+$CR_SUDO }$CR inspect "$MYSQL_CONTAINER" \
            --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Source}}{{end}}{{end}}' \
            2>/dev/null || true)"
    fi
    image="$(${CR_SUDO:+$CR_SUDO }$CR inspect "$MYSQL_CONTAINER" \
        --format '{{.Config.Image}}' 2>/dev/null || true)"
    image="${image:-hg_dnmpr_mysql:latest}"

    if [[ -z "$data_path" || ! -d "$data_path" ]]; then
        echo -e "${RED}错误: 无法确定 MySQL 数据目录 (MYSQL_DATA_PATH)${NC}" >&2
        return 1
    fi

    echo -e "${YELLOW}使用 skip-grant-tables 恢复（数据目录: ${data_path}）...${NC}"

    ${CR_SUDO:+$CR_SUDO }$CR stop "$MYSQL_CONTAINER" >/dev/null 2>&1 || true

    recovery_name="mysql-reset-recovery-$$"
    ${CR_SUDO:+$CR_SUDO }$CR rm -f "$recovery_name" >/dev/null 2>&1 || true

    # 通过镜像默认 entrypoint(docker-entrypoint.sh) 启动临时恢复容器：
    # entrypoint 会以 root 身份创建 /var/log/mysql 等日志目录(否则 mysqld 因
    # 无法打开 log_error 文件而启动失败)，并修正数据目录/日志目录所有权，
    # 随后通过 gosu 降权为 mysql 用户运行 mysqld，避免产生 root 所有权文件。
    if ! ${CR_SUDO:+$CR_SUDO }$CR run -d --name "$recovery_name" \
        -v "${data_path}:/var/lib/mysql:rw" \
        "$image" \
        mysqld --skip-grant-tables --skip-networking \
        --datadir=/var/lib/mysql; then
        echo -e "${RED}错误: 无法启动临时恢复容器${NC}" >&2
        ${CR_SUDO:+$CR_SUDO }$CR start "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
        return 1
    fi

    local ready=false
    local i
    for i in $(seq 1 30); do
        if ${CR_SUDO:+$CR_SUDO }$CR exec "$recovery_name" mysql -uroot -e "SELECT 1" >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 2
    done
    if [[ "$ready" != true ]]; then
        echo -e "${RED}错误: 恢复实例未在预期时间内就绪${NC}" >&2
        ${CR_SUDO:+$CR_SUDO }$CR logs "$recovery_name" 2>&1 | tail -20 >&2 || true
        ${CR_SUDO:+$CR_SUDO }$CR rm -f "$recovery_name" >/dev/null 2>&1 || true
        ${CR_SUDO:+$CR_SUDO }$CR start "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
        return 1
    fi

    local sql_file
    sql_file="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$sql_file'" RETURN
    cat >"$sql_file" <<EOSQL
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${esc}';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${esc}';
ALTER USER 'root'@'%' IDENTIFIED BY '${esc}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOSQL

    if ! ${CR_SUDO:+$CR_SUDO }$CR exec -i "$recovery_name" mysql -uroot <"$sql_file"; then
        echo -e "${RED}错误: skip-grant 模式下执行 ALTER USER 失败${NC}" >&2
        ${CR_SUDO:+$CR_SUDO }$CR rm -f "$recovery_name" >/dev/null 2>&1 || true
        ${CR_SUDO:+$CR_SUDO }$CR start "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
        return 1
    fi

    ${CR_SUDO:+$CR_SUDO }$CR stop "$recovery_name" >/dev/null 2>&1 || true
    ${CR_SUDO:+$CR_SUDO }$CR rm -f "$recovery_name" >/dev/null 2>&1 || true
    ${CR_SUDO:+$CR_SUDO }$CR start "$MYSQL_CONTAINER" >/dev/null 2>&1 || true

    local _mysql_ready=false
    local _wait_attempt
    for _wait_attempt in $(seq 1 25); do
        sleep 2
        # 检查容器是否仍在运行（崩溃时提前退出并打印日志）
        if ! ${CR_SUDO:+$CR_SUDO }$CR ps --format '{{.Names}}' 2>/dev/null | grep -qx "$MYSQL_CONTAINER"; then
            echo -e "${RED}错误: MySQL 容器已停止（可能启动失败），容器日志如下:${NC}" >&2
            ${CR_SUDO:+$CR_SUDO }$CR logs "$MYSQL_CONTAINER" --tail 40 2>&1 >&2 || true
            return 1
        fi
        if _mysql_try_connect "$new_pass"; then
            _mysql_ready=true
            break
        fi
        echo -e "${YELLOW}等待 MySQL 重启就绪（${_wait_attempt}/25）...${NC}"
    done
    if [[ "$_mysql_ready" == "true" ]]; then
        echo -e "${GREEN}✓ skip-grant-tables 恢复成功，root 密码已更新${NC}"
        return 0
    fi
    echo -e "${RED}错误: MySQL 重启后 50 秒内连接测试仍失败，容器日志如下:${NC}" >&2
    ${CR_SUDO:+$CR_SUDO }$CR logs "$MYSQL_CONTAINER" --tail 40 2>&1 >&2 || true
    return 1
}

_reset_dev_user() {
    local root_pass="$1"
    local user_pass="$2"
    local user_name="${MYSQL_USER_NAME:-dev}"
    local esc_user esc_pass
    esc_user="$(_sql_escape "$user_name")"
    esc_pass="$(_sql_escape "$user_pass")"

    [[ -n "$user_name" && -n "$user_pass" ]] || return 0

    echo -e "${YELLOW}正在重置 dev 用户 (${user_name})...${NC}"
    if _mysql_run_sql_with_pass "$root_pass" "
        ALTER USER '${esc_user}'@'%' IDENTIFIED BY '${esc_pass}';
        ALTER USER '${esc_user}'@'localhost' IDENTIFIED BY '${esc_pass}';
        FLUSH PRIVILEGES;
    " 2>/dev/null; then
        echo -e "${GREEN}✓ dev 用户密码重置成功${NC}"
        return 0
    fi

    if _mysql_run_sql_with_pass "$root_pass" "
        CREATE USER IF NOT EXISTS '${esc_user}'@'%' IDENTIFIED BY '${esc_pass}';
        CREATE USER IF NOT EXISTS '${esc_user}'@'localhost' IDENTIFIED BY '${esc_pass}';
        GRANT ALL PRIVILEGES ON *.* TO '${esc_user}'@'%' WITH GRANT OPTION;
        GRANT ALL PRIVILEGES ON *.* TO '${esc_user}'@'localhost' WITH GRANT OPTION;
        FLUSH PRIVILEGES;
    " 2>/dev/null; then
        echo -e "${GREEN}✓ dev 用户已创建并设置密码${NC}"
        return 0
    fi
    echo -e "${YELLOW}⚠ dev 用户重置跳过（可能为生产环境未配置 MYSQL_USER）${NC}"
}

# --- 参数 ---
CUSTOM_ROOT_PASSWORD=""
CUSTOM_USER_PASSWORD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r) CUSTOM_ROOT_PASSWORD="$2"; shift 2 ;;
        -u) CUSTOM_USER_PASSWORD="$2"; shift 2 ;;
        --force-skip-grant) FORCE_SKIP_GRANT=true; shift ;;
        -h|--help)
            echo "用法: $0 [-r root密码] [-u dev密码] [--force-skip-grant]"
            exit 0
            ;;
        *) echo -e "${RED}未知参数: $1${NC}"; exit 1 ;;
    esac
done

_gen_password() {
    # 生成16位随机密码（字母+数字，避免特殊字符导致 shell/SQL 转义问题）
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
}

if _load_env_kv "$ENV_FILE"; then
    DEFAULT_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
    DEFAULT_USER_PASSWORD="${MYSQL_PASSWORD:-}"
else
    echo -e "${YELLOW}提示: 未找到 $ENV_FILE，将使用随机密码${NC}"
    DEFAULT_ROOT_PASSWORD="$(_gen_password)"
    DEFAULT_USER_PASSWORD="$(_gen_password)"
    RANDOM_PASSWORDS=true
fi

MYSQL_USER_NAME="${MYSQL_USER:-dev}"
ROOT_PASSWORD="${CUSTOM_ROOT_PASSWORD:-$DEFAULT_ROOT_PASSWORD}"
USER_PASSWORD="${CUSTOM_USER_PASSWORD:-$DEFAULT_USER_PASSWORD}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}MySQL 密码重置${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "容器: ${YELLOW}${MYSQL_CONTAINER}${NC} (${CR})"
echo -e "新 root 密码: ${YELLOW}${ROOT_PASSWORD}${NC}"
echo -e "新 dev 密码: ${YELLOW}${USER_PASSWORD}${NC} (用户: ${MYSQL_USER_NAME})"
echo -e "${GREEN}========================================${NC}"
echo ""

read -r -p "确认要重置 MySQL 密码吗? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}已取消${NC}"
    exit 0
fi

if ! ${CR_SUDO:+$CR_SUDO }$CR ps --format '{{.Names}}' 2>/dev/null | grep -qx "$MYSQL_CONTAINER"; then
    echo -e "${RED}错误: 容器 '${MYSQL_CONTAINER}' 未运行${NC}"
    echo -e "${YELLOW}请先执行: cd ${PROJECT_ROOT} && ./up.sh mysql${NC}"
    exit 1
fi

echo -e "${GREEN}开始重置...${NC}"
echo ""

known_pass=""
known_pass_found=false
if [[ "$FORCE_SKIP_GRANT" != true ]]; then
    candidates=()
    [[ -n "$DEFAULT_ROOT_PASSWORD" ]] && candidates+=("$DEFAULT_ROOT_PASSWORD")
    # 历史上未加引号的 database.env 会把 < 之后截断
    if [[ "$DEFAULT_ROOT_PASSWORD" == *'<'* ]]; then
        candidates+=("${DEFAULT_ROOT_PASSWORD%%<*}")
    fi
    candidates+=("" "root" "root123")

    echo -e "${YELLOW}尝试使用已知旧密码连接...${NC}"
    for cand in "${candidates[@]}"; do
        if _mysql_try_connect "$cand"; then
            known_pass="$cand"
            known_pass_found=true
            if [[ -n "$cand" ]]; then
                echo -e "${GREEN}✓ 已用旧密码连接成功${NC}"
            else
                echo -e "${GREEN}✓ 已用空密码连接成功${NC}"
            fi
            break
        fi
    done
fi

if [[ "$known_pass_found" == true ]]; then
    echo -e "${YELLOW}正在更新 root 密码...${NC}"
    if _reset_root_with_known_pass "$known_pass" "$ROOT_PASSWORD"; then
        echo -e "${GREEN}✓ root 密码重置成功${NC}"
    else
        echo -e "${RED}✗ ALTER USER 失败，将尝试 skip-grant-tables${NC}"
        known_pass_found=false
    fi
fi

if [[ "$known_pass_found" != true ]]; then
    if ! _reset_via_skip_grant "$ROOT_PASSWORD"; then
        exit 1
    fi
fi

_reset_dev_user "$ROOT_PASSWORD" "$USER_PASSWORD"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}完成。请使用以下命令验证:${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "  ${CR} exec -it ${MYSQL_CONTAINER} mysql -uroot -p'${ROOT_PASSWORD}' -e \"SELECT 1\""
echo ""

if [[ "$RANDOM_PASSWORDS" == true ]]; then
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}随机密码（请妥善保存）：${NC}"
    echo -e "  root 密码: ${GREEN}${ROOT_PASSWORD}${NC}"
    echo -e "  dev  密码: ${GREEN}${USER_PASSWORD}${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
fi
