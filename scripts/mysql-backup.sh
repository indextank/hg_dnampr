#!/bin/bash

# MySQL备份脚本
# 用于自动备份MySQL数据库

set -e

# 配置变量
BACKUP_DIR="/backup"
DATE=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$BACKUP_DIR/backup.log"

# 创建备份目录
mkdir -p "$BACKUP_DIR"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 检查MySQL连接
check_mysql_connection() {
    local host=$1
    local user=$2
    local password=$3
    
    if mysqladmin ping -h "$host" -u "$user" -p"$password" --silent; then
        return 0
    else
        return 1
    fi
}

# 执行备份
perform_backup() {
    local host=$1
    local user=$2
    local password=$3
    local backup_file=$4
    
    log "开始备份MySQL数据库 - 主机: $host"
    
    if check_mysql_connection "$host" "$user" "$password"; then
        mysqldump -h "$host" -u "$user" -p"$password" \
            --single-transaction \
            --routines \
            --triggers \
            --all-databases \
            --add-drop-database \
            --add-drop-table \
            --create-options \
            --disable-keys \
            --extended-insert \
            --quick \
            --lock-tables=false > "$backup_file"
        
        if [ $? -eq 0 ]; then
            log "备份成功完成: $backup_file"
            # 压缩备份文件
            gzip "$backup_file"
            log "备份文件已压缩: $backup_file.gz"
        else
            log "备份失败: $backup_file"
            return 1
        fi
    else
        log "无法连接到MySQL服务器: $host"
        return 1
    fi
}

# 清理旧备份
cleanup_old_backups() {
    log "开始清理7天前的备份文件"
    find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete
    find "$BACKUP_DIR" -name "*.sql" -mtime +7 -delete
    log "旧备份文件清理完成"
}

# 检查容器是否运行
check_container_running() {
    local container_name=$1
    if docker ps --format "table {{.Names}}" | grep -q "^${container_name}$"; then
        return 0
    else
        return 1
    fi
}

# 检测可用的MySQL服务
detect_mysql_services() {
    local available_services=()
    
    # 检查mysql-server容器
    if check_container_running "mysql_server" || check_container_running "mysql-server"; then
        if check_mysql_connection "mysql-server" "root" "$MYSQL_ROOT_PASSWORD"; then
            available_services+=("mysql")
            log "检测到可用的MySQL服务"
        fi
    fi
    
    echo "${available_services[@]}"
}

# 主函数
main() {
    log "=== MySQL备份任务开始 ==="
    
    # 检测可用的MySQL服务
    available_services=($(detect_mysql_services))
    
    if [ ${#available_services[@]} -eq 0 ]; then
        log "警告: 未检测到任何可用的MySQL服务"
        log "=== MySQL备份任务结束 ==="
        return 1
    fi
    
    # 备份检测到的MySQL服务
    for service in "${available_services[@]}"; do
        case $service in
            "mysql")
                if [ "$MYSQL_ENABLED" = "true" ] || [ -z "$MYSQL_ENABLED" ]; then
                    MYSQL_BACKUP_FILE="$BACKUP_DIR/mysql_backup_$DATE.sql"
                    perform_backup "mysql-server" "root" "$MYSQL_ROOT_PASSWORD" "$MYSQL_BACKUP_FILE"
                fi
                ;;
        esac
    done
    
    # 清理旧备份
    cleanup_old_backups
    
    log "=== MySQL备份任务完成 ==="
}

# 执行主函数
main "$@"