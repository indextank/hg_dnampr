#!/bin/bash
# ==========================================
# ClickHouse 定时备份脚本
# ==========================================
# 运行方式：由 docker-compose 中的 clickhouse-backup 容器调用
# 备份策略：ALTER TABLE ... FREEZE 生成只读快照到 /var/lib/clickhouse/shadow/，再 tar.zst 打包
# 保留策略：自动清理超过 BACKUP_RETENTION_DAYS 天的旧备份（默认 7 天）
# 调度方式：容器内 while true + sleep 自调度，不依赖宿主 cron（与 backup-pg.sh 一致）
#
# 说明：
#   - FREEZE 不复制数据到磁盘，而是在 metadata 层创建硬链接快照，速度快、空间省。
#   - 打包后立即 ALTER TABLE ... CLEAR SHADOW 清理 shadow 目录，避免残留占用。
#   - 该方案无需引入 clickhouse-backup 等第三方二进制，依赖 ClickHouse 内置能力。
#   - 备份粒度：按库逐一 FREEZE 所有表；系统库（system/INFORMATION_SCHEMA/INFORMATION_SCHEMA）跳过。

set -euo pipefail

# ==========================================
# 配置（通过容器环境变量传入）
# ==========================================
BACKUP_DIR="${BACKUP_DIR:-/backup}"
CH_HOST="${CLICKHOUSE_HOST:-clickhouse}"
CH_PORT="${CLICKHOUSE_HTTP_PORT:-8123}"
CH_USER="${CLICKHOUSE_USER:-clickhouse}"
CH_PASSWORD="${CLICKHOUSE_PASSWORD:-}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_AT="${BACKUP_AT:-05:20}"  # HH:MM，每日备份时间
LOG_FILE="${BACKUP_DIR}/backup.log"

# ClickHouse 数据目录（shadow 快照落盘位置，由 clickhouse-server 配置决定）
CH_DATA_DIR="${CLICKHOUSE_DATA_DIR:-/var/lib/clickhouse}"

# 系统库白名单（FREEZE 这些库无意义）
CH_SYSTEM_DATABASES=("system" "INFORMATION_SCHEMA" "information_schema" "default")

# ==========================================
# 工具函数
# ==========================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

is_system_db() {
    local db="$1"
    for s in "${CH_SYSTEM_DATABASES[@]}"; do
        if [[ "$db" == "$s" ]]; then
            return 0
        fi
    done
    return 1
}

# clickhouse-client 调用封装（HTTP 接口，避免依赖 native TCP 端口）
ch_query() {
    local query="$1"
    if [[ -n "${CH_PASSWORD}" ]]; then
        curl -s -u "${CH_USER}:${CH_PASSWORD}" "http://${CH_HOST}:${CH_PORT}/?query=${query// /+}" 2>/dev/null
    else
        curl -s -u "${CH_USER}:" "http://${CH_HOST}:${CH_PORT}/?query=${query// /+}" 2>/dev/null
    fi
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

wait_for_ch() {
    local max_wait=60
    local waited=0
    log "等待 ClickHouse 服务就绪 (${CH_HOST}:${CH_PORT})..."
    until curl -s -u "${CH_USER}:${CH_PASSWORD}" "http://${CH_HOST}:${CH_PORT}/?query=SELECT%201" >/dev/null 2>&1; do
        waited=$((waited + 5))
        if (( waited >= max_wait )); then
            log "错误：等待 ClickHouse 超时（${max_wait}s），跳过本次备份"
            return 1
        fi
        log "ClickHouse 未就绪，5s 后重试..."
        sleep 5
    done
    log "ClickHouse 连接正常"
    return 0
}

run_backup_once() {
    mkdir -p "${BACKUP_DIR}"
    local date_str
    date_str=$(date +"%Y%m%d_%H%M%S")

    log "=== ClickHouse 备份任务开始 (${date_str}) ==="
    log "目标主机：${CH_HOST}:${CH_PORT}"
    log "备份目录：${BACKUP_DIR}"

    if ! wait_for_ch; then
        return 1
    fi

    # 获取非系统库列表（SQL 需 URL 编码空格为 %20，curl 内已用 // 替换）
    local dbs db
    dbs=$(ch_query "SELECT name FROM system.databases WHERE name NOT IN ('system','INFORMATION_SCHEMA','information_schema') ORDER BY name" | tr -d '\r' || true)

    if [[ -z "$dbs" ]]; then
        log "警告：未获取到任何用户数据库，跳过本次备份"
        return 0
    fi

    local backup_file="${BACKUP_DIR}/clickhouse_${date_str}.tar.zst"
    log "开始打包全部用户库快照 → ${backup_file}"

    # 对每个库执行 FREEZE（WITH NAME 标记本次快照分区），便于清理
    local partition_name="backup_${date_str}"
    for db in $dbs; do
        if is_system_db "$db"; then
            continue
        fi
        log "FREEZE 数据库：${db}"
        # FREEZE 整个库的所有表（ClickHouse 23+ 支持库级 FREEZE；旧版本需逐表）
        ch_query "ALTER DATABASE \`${db}\` FREEZE WITH NAME '${partition_name}'" >/dev/null 2>&1 \
            || log "警告：FREEZE 库 ${db} 失败（可能为空库或不支持库级 FREEZE），跳过"
    done

    # 打包 shadow 目录（FREEZE 快照落盘位置）为 tar.zst
    local shadow_dir="${CH_DATA_DIR}/shadow"
    if [[ -d "${shadow_dir}" ]] && [[ -n "$(ls -A "${shadow_dir}" 2>/dev/null)" ]]; then
        if ! tar -I zstd -cf "${backup_file}" -C "${CH_DATA_DIR}" shadow 2>/dev/null \
            || tar --zstd -cf "${backup_file}" -C "${CH_DATA_DIR}" shadow 2>/dev/null; then
            :
        fi

        if [[ -f "${backup_file}" ]]; then
            local size
            size=$(du -sh "${backup_file}" | cut -f1)
            log "打包完成：${backup_file}（大小：${size}）"
        else
            log "错误：打包失败，删除不完整文件"
            rm -f "${backup_file}"
        fi

        # 清理 shadow 快照（无论打包是否成功，都需清理 FREEZE 残留）
        log "清理 ClickHouse shadow 快照..."
        for db in $dbs; do
            if is_system_db "$db"; then
                continue
            fi
            ch_query "ALTER DATABASE \`${db}\` CLEAR SHADOW WITH NAME '${partition_name}'" >/dev/null 2>&1 || true
        done
        # 兜底：直接删除 shadow 目录残留（容器的 clickhouse 用户可写）
        rm -rf "${shadow_dir}"/* 2>/dev/null || true
    else
        log "警告：shadow 目录为空或不存在，本次无可备份数据（可能所有库都是空库）"
    fi

    # 清理过期备份
    log "清理 ${RETENTION_DAYS} 天前的旧备份..."
    local deleted
    deleted=$(find "${BACKUP_DIR}" -name "clickhouse_*.tar.zst" -mtime "+${RETENTION_DAYS}" -print | wc -l || echo 0)
    find "${BACKUP_DIR}" -name "clickhouse_*.tar.zst" -mtime "+${RETENTION_DAYS}" -delete || true
    find "${BACKUP_DIR}" -name "backup.log" -size +100M -exec truncate -s 10M {} \; || true
    log "已清理 ${deleted} 个过期备份文件"
    log "=== ClickHouse 备份任务完成 (${date_str}) ==="
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
        run_backup_once || log "本次 ClickHouse 备份执行失败，请查看日志"
    done
}

main_loop
