#!/bin/bash
#
# 宿主机 MySQL 备份脚本（与 Docker / 本仓库编排无关）
# 面向本机安装的 MySQL（如 /usr/local/mysql + systemd mysqld.service）
#
# 常用环境变量：
#   MYSQL_BACKUP_DIR     备份目录，默认 /data/backup
#   MYSQL_HOST           主机，默认 127.0.0.1；留空则优先走 socket
#   MYSQL_PORT           端口，默认 3306
#   MYSQL_SOCKET         socket，默认 /tmp/mysql.sock
#   MYSQL_USER           用户，默认 root
#   MYSQL_ROOT_PASSWORD  密码（也可用 MYSQL_PASSWORD）
#   MYSQL_BIN_DIR        客户端目录，默认自动探测 /usr/local/mysql/bin
#   MYSQL_RETENTION_DAYS 保留天数，默认 7
#   MYSQL_EXTRA_EXCLUDE  额外排除库名，空格分隔
#
# 输出文件（按库单独备份）:
#   <MYSQL_BACKUP_DIR>/<库名>_YYYYMMDD_HHMMSS.sql.gz
#

set -euo pipefail

BACKUP_DIR="${MYSQL_BACKUP_DIR:-/data/backup}"
DATE="$(date +"%Y%m%d_%H%M%S")"
LOG_FILE="${MYSQL_BACKUP_LOG:-$BACKUP_DIR/backup.log}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_ROOT_PASSWORD:-${MYSQL_PASSWORD:-}}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_SOCKET="${MYSQL_SOCKET:-/tmp/mysql.sock}"
MYSQL_BIN_DIR="${MYSQL_BIN_DIR:-}"
RETENTION_DAYS="${MYSQL_RETENTION_DAYS:-7}"
# MySQL 自带库 + 可扩展排除列表
SYSTEM_DB_REGEX='^(mysql|information_schema|performance_schema|sys)$'
EXTRA_EXCLUDE="${MYSQL_EXTRA_EXCLUDE:-}"

if [[ -z "$MYSQL_PASSWORD" ]]; then
    echo "ERROR: MYSQL_ROOT_PASSWORD / MYSQL_PASSWORD 未设置" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

resolve_mysql_bin_dir() {
    if [[ -n "$MYSQL_BIN_DIR" && -x "$MYSQL_BIN_DIR/mysql" ]]; then
        return 0
    fi
    local candidates=(
        /usr/local/mysql/bin
        /usr/bin
        /bin
    )
    local d
    for d in "${candidates[@]}"; do
        if [[ -x "$d/mysql" && -x "$d/mysqldump" ]]; then
            MYSQL_BIN_DIR="$d"
            return 0
        fi
    done
    # PATH 兜底
    local mysql_path
    mysql_path="$(command -v mysql 2>/dev/null || true)"
    if [[ -n "$mysql_path" ]]; then
        MYSQL_BIN_DIR="$(dirname "$mysql_path")"
        return 0
    fi
    return 1
}

# 通过临时 defaults-extra-file 传凭据，避免 -p 出现在 process list
DEFAULTS_FILE=""
cleanup() {
    if [[ -n "${DEFAULTS_FILE:-}" && -f "$DEFAULTS_FILE" ]]; then
        rm -f "$DEFAULTS_FILE"
    fi
}
trap cleanup EXIT

create_defaults_file() {
    DEFAULTS_FILE="$(mktemp /tmp/mysql-backup.XXXXXX.cnf)"
    chmod 600 "$DEFAULTS_FILE"
    {
        echo "[client]"
        echo "user=${MYSQL_USER}"
        echo "password=${MYSQL_PASSWORD}"
        if [[ -n "${USE_SOCKET:-}" ]]; then
            echo "socket=${MYSQL_SOCKET}"
        else
            echo "host=${MYSQL_HOST}"
            echo "port=${MYSQL_PORT}"
        fi
    } >"$DEFAULTS_FILE"
}

mysql_cmd() {
    "${MYSQL_BIN_DIR}/mysql" --defaults-extra-file="$DEFAULTS_FILE" "$@"
}

mysqldump_cmd() {
    "${MYSQL_BIN_DIR}/mysqldump" --defaults-extra-file="$DEFAULTS_FILE" "$@"
}

mysqladmin_cmd() {
    if [[ -x "${MYSQL_BIN_DIR}/mysqladmin" ]]; then
        "${MYSQL_BIN_DIR}/mysqladmin" --defaults-extra-file="$DEFAULTS_FILE" "$@"
    else
        return 127
    fi
}

detect_mysql_service() {
    # systemd 单元：本机常见为 mysqld.service（LSB）或 mysql.service
    local unit
    for unit in mysqld.service mysql.service mariadb.service; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            echo "$unit"
            return 0
        fi
    done
    # init.d 兜底
    if [[ -x /etc/init.d/mysqld ]] && /etc/init.d/mysqld status >/dev/null 2>&1; then
        echo "init.d/mysqld"
        return 0
    fi
    if [[ -x /etc/init.d/mysql ]] && /etc/init.d/mysql status >/dev/null 2>&1; then
        echo "init.d/mysql"
        return 0
    fi
    # 进程 / socket / 端口兜底
    if [[ -S "$MYSQL_SOCKET" ]]; then
        echo "socket:${MYSQL_SOCKET}"
        return 0
    fi
    if command -v ss >/dev/null 2>&1 && ss -lnt "( sport = :${MYSQL_PORT} )" 2>/dev/null | grep -q LISTEN; then
        echo "port:${MYSQL_PORT}"
        return 0
    fi
    if pgrep -x mysqld >/dev/null 2>&1; then
        echo "process:mysqld"
        return 0
    fi
    return 1
}

choose_connection() {
    # 优先本机 socket（与 /etc/my.cnf 一致），失败再走 TCP
    USE_SOCKET=""
    if [[ -S "$MYSQL_SOCKET" ]]; then
        USE_SOCKET=1
        create_defaults_file
        if mysqladmin_cmd ping --silent >/dev/null 2>&1 \
            || mysql_cmd -N -e "SELECT 1" >/dev/null 2>&1; then
            log "使用 socket 连接: ${MYSQL_SOCKET}"
            return 0
        fi
        cleanup
        USE_SOCKET=""
        log "socket 连接失败，回退 TCP ${MYSQL_HOST}:${MYSQL_PORT}"
    fi
    create_defaults_file
    if mysqladmin_cmd ping --silent >/dev/null 2>&1 \
        || mysql_cmd -N -e "SELECT 1" >/dev/null 2>&1; then
        log "使用 TCP 连接: ${MYSQL_HOST}:${MYSQL_PORT}"
        return 0
    fi
    return 1
}

is_excluded_db() {
    local name="$1"
    local extra
    if [[ "$name" =~ $SYSTEM_DB_REGEX ]]; then
        return 0
    fi
    for extra in $EXTRA_EXCLUDE; do
        if [[ "$name" == "$extra" ]]; then
            return 0
        fi
    done
    return 1
}

list_user_databases() {
    local db
    while IFS= read -r db; do
        [[ -z "$db" ]] && continue
        if is_excluded_db "$db"; then
            continue
        fi
        printf '%s\n' "$db"
    done < <(mysql_cmd -N -e "SHOW DATABASES")
}

# 库名转安全文件名（保留字母数字、._-）
safe_db_filename() {
    local name="$1"
    name="${name//[^A-Za-z0-9._-]/_}"
    [[ -n "$name" ]] || name="unknown_db"
    printf '%s' "$name"
}

backup_one_database() {
    local db="$1"
    local safe_name
    local backup_file
    local size

    safe_name="$(safe_db_filename "$db")"
    backup_file="${BACKUP_DIR}/${safe_name}_${DATE}.sql"

    log "开始备份数据库: ${db} -> $(basename "$backup_file").gz"

    if mysqldump_cmd \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        --add-drop-database \
        --add-drop-table \
        --create-options \
        --disable-keys \
        --extended-insert \
        --quick \
        --set-gtid-purged=OFF \
        --databases "$db" >"$backup_file"; then
        size="$(du -h "$backup_file" | awk '{print $1}')"
        log "备份成功: $backup_file (${size})"
        gzip -f "$backup_file"
        size="$(du -h "${backup_file}.gz" | awk '{print $1}')"
        log "已压缩: ${backup_file}.gz (${size})"
        return 0
    fi

    rm -f "$backup_file"
    log "ERROR: 备份失败: ${db}"
    return 1
}

perform_backup() {
    local databases=("$@")
    local db
    local failed=0
    local ok=0

    if [[ ${#databases[@]} -eq 0 ]]; then
        die "没有可备份的用户数据库（均被排除或实例为空）"
    fi

    log "开始按库单独备份（共 ${#databases[@]} 个）"

    for db in "${databases[@]}"; do
        if backup_one_database "$db"; then
            ok=$((ok + 1))
        else
            failed=$((failed + 1))
        fi
    done

    log "备份汇总: 成功 ${ok}，失败 ${failed}"
    if [[ "$failed" -gt 0 ]]; then
        die "有 ${failed} 个数据库备份失败"
    fi
}

cleanup_old_backups() {
    log "清理 ${RETENTION_DAYS} 天前的备份文件"
    # 新格式: <dbname>_YYYYMMDD_HHMMSS.sql[.gz]；兼容旧格式 mysql_backup_*.sql[.gz]
    find "$BACKUP_DIR" -maxdepth 1 -type f \( \
            -name '*_????????_??????.sql.gz' -o \
            -name '*_????????_??????.sql' -o \
            -name 'mysql_backup_*.sql.gz' -o \
            -name 'mysql_backup_*.sql' \
        \) -mtime "+${RETENTION_DAYS}" -print -delete \
        | while IFS= read -r f; do
            [[ -n "$f" ]] && log "已删除过期备份: $f"
        done || true
    log "旧备份清理完成"
}

main() {
    log "=== MySQL备份任务开始 ==="

    if ! resolve_mysql_bin_dir; then
        die "未找到 mysql / mysqldump（可设置 MYSQL_BIN_DIR=/usr/local/mysql/bin）"
    fi
    log "MySQL 客户端目录: $MYSQL_BIN_DIR"

    local service_hint
    if service_hint="$(detect_mysql_service)"; then
        log "检测到 MySQL 服务: ${service_hint}"
    else
        die "未检测到宿主机 MySQL 服务（systemd mysqld/mysql、socket、端口或 mysqld 进程）"
    fi

    if ! choose_connection; then
        die "无法连接 MySQL（请检查 MYSQL_ROOT_PASSWORD / socket / host/port）"
    fi

    local databases=()
    mapfile -t databases < <(list_user_databases)
    if [[ ${#databases[@]} -eq 0 ]]; then
        die "未找到需要备份的用户数据库（已排除 mysql/information_schema/performance_schema/sys）"
    fi
    log "待备份库数量: ${#databases[@]}"

    perform_backup "${databases[@]}"
    cleanup_old_backups

    log "=== MySQL备份任务完成 ==="
}

main "$@"
