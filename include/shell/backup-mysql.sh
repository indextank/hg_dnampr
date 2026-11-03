#!/bin/bash
# ==========================================
# MySQL 定时备份脚本
# ==========================================
# 运行方式：由 docker-compose 中的 mysql-backup 容器调用
# 备份策略：mysqldump 全量备份（含所有库、触发器、存储过程），压缩存储
# 保留策略：自动清理超过 BACKUP_RETENTION_DAYS 天的旧备份（默认 7 天）

set -euo pipefail

# ==========================================
# 配置（通过容器环境变量传入）
# ==========================================
BACKUP_DIR="${BACKUP_DIR:-/backup}"
MYSQL_HOST="${MYSQL_HOST:-mysql}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_AT="${BACKUP_AT:-02:00}"  # HH:MM，每日备份时间
LOG_FILE="${BACKUP_DIR}/backup.log"

# 排除的系统库
MYSQL_SYSTEM_DATABASES=("information_schema" "performance_schema" "mysql" "sys")

# ==========================================
# 工具函数
# ==========================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

is_system_db() {
    local db="$1"
    for sysdb in "${MYSQL_SYSTEM_DATABASES[@]}"; do
        if [[ "$db" == "$sysdb" ]]; then
            return 0
        fi
    done
    return 1
}

next_run_epoch() {
    local now target today tomorrow
    now=$(date +%s)
    local hour="${BACKUP_AT%:*}"
    local minute="${BACKUP_AT#*:}"
    today=$(date +%F)
    target=$(date -d "${today} ${hour}:${minute}:00" +%s)
    if (( target <= now )); then
        tomorrow=$(date -d "+1 day" +%F)
        target=$(date -d "${tomorrow} ${hour}:${minute}:00" +%s)
    fi
    echo "$target"
}

wait_for_mysql() {
    local max_wait=60
    local waited=0
    log "等待 MySQL 服务就绪 (${MYSQL_HOST}:${MYSQL_PORT})..."
    until mysqladmin ping \
        -h "${MYSQL_HOST}" \
        -P "${MYSQL_PORT}" \
        -u "${MYSQL_USER}" \
        -p"${MYSQL_PASSWORD}" \
        --silent > /dev/null 2>&1; do
        waited=$((waited + 5))
        if (( waited >= max_wait )); then
            log "错误：等待 MySQL 超时（${max_wait}s），跳过本次备份"
            return 1
        fi
        log "MySQL 未就绪，5s 后重试..."
        sleep 5
    done
    log "MySQL 连接正常"
    return 0
}

run_backup_once() {
    mkdir -p "${BACKUP_DIR}"
    local date_str
    date_str=$(date +"%Y%m%d_%H%M%S")

    log "=== MySQL 备份任务开始 (${date_str}) ==="
    log "目标主机：${MYSQL_HOST}:${MYSQL_PORT}"
    log "备份目录：${BACKUP_DIR}"

    if ! wait_for_mysql; then
        return 1
    fi

    # 获取非系统库列表
    local dbs db
    dbs=$(mysql \
        -h "${MYSQL_HOST}" \
        -P "${MYSQL_PORT}" \
        -u "${MYSQL_USER}" \
        -p"${MYSQL_PASSWORD}" \
        -N -e "SHOW DATABASES;" 2>/dev/null | tr -d '\r' || true)

    if [[ -z "$dbs" ]]; then
        log "警告：未获取到任何数据库，跳过本次备份"
        return 0
    fi

    for db in $dbs; do
        if is_system_db "$db"; then
            log "跳过系统库：${db}"
            continue
        fi

        local backup_file="${BACKUP_DIR}/mysql_${db}_${date_str}.sql.gz"
        log "开始备份库 ${db} → ${backup_file}"

        if ! mysqldump \
            -h "${MYSQL_HOST}" \
            -P "${MYSQL_PORT}" \
            -u "${MYSQL_USER}" \
            -p"${MYSQL_PASSWORD}" \
            --single-transaction \
            --routines \
            --triggers \
            --databases "${db}" \
            --add-drop-database \
            --add-drop-table \
            --create-options \
            --extended-insert \
            --quick \
            --lock-tables=false \
            | gzip > "${backup_file}"; then
            log "错误：备份库 ${db} 失败，删除不完整文件"
            rm -f "${backup_file}"
        else
            local size
            size=$(du -sh "${backup_file}" | cut -f1)
            log "备份完成：${backup_file}（大小：${size}）"
        fi
    done

    # 清理过期备份
    log "清理 ${RETENTION_DAYS} 天前的旧备份..."
    local deleted
    deleted=$(find "${BACKUP_DIR}" -name "mysql_*.sql.gz" -mtime "+${RETENTION_DAYS}" -print | wc -l || echo 0)
    find "${BACKUP_DIR}" -name "mysql_*.sql.gz" -mtime "+${RETENTION_DAYS}" -delete || true
    find "${BACKUP_DIR}" -name "backup.log" -size +100M -exec truncate -s 10M {} \; || true
    log "已清理 ${deleted} 个过期备份文件"
    log "=== MySQL 备份任务完成 (${date_str}) ==="
}

main_loop() {
    mkdir -p "${BACKUP_DIR}"
    while true; do
        local next now sleep_sec
        next=$(next_run_epoch)
        now=$(date +%s)
        sleep_sec=$(( next - now ))
        if (( sleep_sec > 0 )); then
            log "下次备份时间：$(date -d "@$next" '+%Y-%m-%d %H:%M:%S')，等待 ${sleep_sec}s"
            sleep "${sleep_sec}" || true
        fi
        run_backup_once || log "本次 MySQL 备份执行失败，请查看日志"
    done
}

main_loop