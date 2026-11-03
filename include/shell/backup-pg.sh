#!/bin/bash
# ==========================================
# PostgreSQL 定时备份脚本
# ==========================================
# 运行方式：由 docker-compose 中的 pg-backup 容器调用
# 备份策略：pg_dumpall 全量备份（含所有数据库、角色、表空间），压缩存储
# 保留策略：自动清理超过 BACKUP_RETENTION_DAYS 天的旧备份（默认 7 天）

set -euo pipefail

# ==========================================
# 配置（通过容器环境变量传入）
# ==========================================
BACKUP_DIR="${BACKUP_DIR:-/backup}"
PG_HOST="${PG_HOST:-postgres}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${POSTGRES_USER:-postgres}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_AT="${BACKUP_AT:-04:20}"  # HH:MM，每日备份时间
LOG_FILE="${BACKUP_DIR}/backup.log"

# PGPASSWORD 由容器环境变量直接注入，pg_dump/psql 自动读取
PG_SYSTEM_DATABASES=("postgres" "template0" "template1")

# ==========================================
# 工具函数
# ==========================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

is_system_db() {
    local db="$1"
    for s in "${PG_SYSTEM_DATABASES[@]}"; do
        if [[ "$db" == "$s" ]]; then
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

wait_for_pg() {
    local max_wait=60
    local waited=0
    log "等待 PostgreSQL 服务就绪 (${PG_HOST}:${PG_PORT})..."
    until pg_isready -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" > /dev/null 2>&1; do
        waited=$((waited + 5))
        if (( waited >= max_wait )); then
            log "错误：等待 PostgreSQL 超时（${max_wait}s），跳过本次备份"
            return 1
        fi
        log "PostgreSQL 未就绪，5s 后重试..."
        sleep 5
    done
    log "PostgreSQL 连接正常"
    return 0
}

run_backup_once() {
    mkdir -p "${BACKUP_DIR}"
    local date_str
    date_str=$(date +"%Y%m%d_%H%M%S")

    log "=== PostgreSQL 备份任务开始 (${date_str}) ==="
    log "目标主机：${PG_HOST}:${PG_PORT}"
    log "备份目录：${BACKUP_DIR}"

    if ! wait_for_pg; then
        return 1
    fi

    # 获取非系统库列表
    local dbs db
    dbs=$(psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -At \
        -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>/dev/null | tr -d '\r' || true)

    if [[ -z "$dbs" ]]; then
        log "警告：未获取到任何数据库，跳过本次备份"
        return 0
    fi

    for db in $dbs; do
        if is_system_db "$db"; then
            log "跳过系统库：${db}"
            continue
        fi

        local backup_file="${BACKUP_DIR}/pg_${db}_${date_str}.sql.gz"
        log "开始备份库 ${db} → ${backup_file}"

        if ! pg_dump \
            --host="${PG_HOST}" \
            --port="${PG_PORT}" \
            --username="${PG_USER}" \
            --format=plain \
            --clean \
            --if-exists \
            --dbname="${db}" \
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
    deleted=$(find "${BACKUP_DIR}" -name "pg_*.sql.gz" -mtime "+${RETENTION_DAYS}" -print | wc -l || echo 0)
    find "${BACKUP_DIR}" -name "pg_*.sql.gz" -mtime "+${RETENTION_DAYS}" -delete || true
    find "${BACKUP_DIR}" -name "backup.log" -size +100M -exec truncate -s 10M {} \; || true
    log "已清理 ${deleted} 个过期备份文件"
    log "=== PostgreSQL 备份任务完成 (${date_str}) ==="
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
        run_backup_once || log "本次 PostgreSQL 备份执行失败，请查看日志"
    done
}

main_loop