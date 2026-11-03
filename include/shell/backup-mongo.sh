#!/bin/bash
# ==========================================
# MongoDB 定时备份脚本
# ==========================================
# 运行方式：由 docker-compose 中的 mongo-backup 容器调用
# 备份策略：每次执行全量 mongodump，压缩后存入 /backup
# 保留策略：自动清理超过 BACKUP_RETENTION_DAYS 天的旧备份（默认 7 天）

set -euo pipefail

# ==========================================
# 配置（通过容器环境变量传入）
# ==========================================
BACKUP_DIR="${BACKUP_DIR:-/backup}"
MONGO_HOST="${MONGO_HOST:-mongo}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_USERNAME="${MONGO_INITDB_ROOT_USERNAME:-mongoadmin}"
MONGO_PASSWORD="${MONGO_INITDB_ROOT_PASSWORD:-}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_AT="${BACKUP_AT:-02:45}"  # HH:MM，每日备份时间
LOG_FILE="${BACKUP_DIR}/backup.log"

MONGO_SYSTEM_DBS=("admin" "local" "config")

# ==========================================
# 工具函数
# ==========================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

is_system_db() {
    local db="$1"
    for s in "${MONGO_SYSTEM_DBS[@]}"; do
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

wait_for_mongo() {
    local max_wait=60
    local waited=0
    log "等待 MongoDB 服务就绪 (${MONGO_HOST}:${MONGO_PORT})..."
    until mongosh --host "${MONGO_HOST}" --port "${MONGO_PORT}" \
        --username "${MONGO_USERNAME}" --password "${MONGO_PASSWORD}" \
        --authenticationDatabase admin \
        --eval "db.adminCommand('ping')" --quiet > /dev/null 2>&1; do
        waited=$((waited + 5))
        if (( waited >= max_wait )); then
            log "错误：等待 MongoDB 超时（${max_wait}s），跳过本次备份"
            return 1
        fi
        log "MongoDB 未就绪，5s 后重试..."
        sleep 5
    done
    log "MongoDB 连接正常"
    return 0
}

run_backup_once() {
    mkdir -p "${BACKUP_DIR}"
    local date_str
    date_str=$(date +"%Y%m%d_%H%M%S")

    log "=== MongoDB 备份任务开始 (${date_str}) ==="
    log "目标主机：${MONGO_HOST}:${MONGO_PORT}"
    log "备份目录：${BACKUP_DIR}"

    if ! wait_for_mongo; then
        return 1
    fi

    # 获取非系统库列表
    local dbs db
    dbs=$(mongosh --host "${MONGO_HOST}" --port "${MONGO_PORT}" \
        --username "${MONGO_USERNAME}" --password "${MONGO_PASSWORD}" \
        --authenticationDatabase admin \
        --quiet --eval 'db.adminCommand({ listDatabases: 1 }).databases.map(d => d.name).join("\n")' 2>/dev/null | tr -d '\r' || true)

    if [[ -z "$dbs" ]]; then
        log "警告：未获取到任何数据库，跳过本次备份"
        return 0
    fi

    for db in $dbs; do
        if is_system_db "$db"; then
            log "跳过系统库：${db}"
            continue
        fi

        local archive="${BACKUP_DIR}/mongo_${db}_${date_str}.archive.gz"
        log "开始备份库 ${db} → ${archive}"

        if ! mongodump \
            --host "${MONGO_HOST}" \
            --port "${MONGO_PORT}" \
            --username "${MONGO_USERNAME}" \
            --password "${MONGO_PASSWORD}" \
            --authenticationDatabase admin \
            --db "${db}" \
            --gzip \
            --archive="${archive}"; then
            log "错误：备份库 ${db} 失败，删除不完整文件"
            rm -f "${archive}"
        else
            local size
            size=$(du -sh "${archive}" | cut -f1)
            log "备份完成：${archive}（大小：${size}）"
        fi
    done

    # 清理过期备份
    log "清理 ${RETENTION_DAYS} 天前的旧备份..."
    local deleted
    deleted=$(find "${BACKUP_DIR}" -name "mongo_*.archive.gz" -mtime "+${RETENTION_DAYS}" -print | wc -l || echo 0)
    find "${BACKUP_DIR}" -name "mongo_*.archive.gz" -mtime "+${RETENTION_DAYS}" -delete || true
    find "${BACKUP_DIR}" -name "backup.log" -size +100M -exec truncate -s 10M {} \; || true
    log "已清理 ${deleted} 个过期备份文件"
    log "=== MongoDB 备份任务完成 (${date_str}) ==="
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
        run_backup_once || log "本次 MongoDB 备份执行失败，请查看日志"
    done
}

main_loop