#!/bin/bash

# ==========================================
# 批量备份所有数据库 Volume 脚本
# ==========================================
# 功能：一次性备份所有数据库 volume（MySQL、MongoDB、PostgreSQL）
# 使用方法：./scripts/backup-all-volumes.sh [backup_path]

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# 显示使用帮助
show_help() {
    cat << EOF
${GREEN}批量备份所有数据库 Volume 脚本${NC}

${YELLOW}功能：${NC}
  一次性备份所有数据库 volume（MySQL、MongoDB、PostgreSQL）

${YELLOW}使用方法：${NC}
  $0 [backup_path]

${YELLOW}参数：${NC}
  backup_path   - 备份文件存储路径（可选，默认：/backup/volumes）

${YELLOW}示例：${NC}
  $0                    # 备份到默认路径
  $0 /data/backup       # 备份到指定路径

${YELLOW}备份的 volumes：${NC}
  - mysql_data      MySQL 数据卷
  - mongo_data      MongoDB 数据卷
  - postgres_data   PostgreSQL 数据卷

EOF
}

# 主函数
main() {
    # 检查参数
    if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_help
        exit 0
    fi

    local backup_path="${1:-/backup/volumes}"
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local backup_script="${script_dir}/docker-volume-backup.sh"
    local volumes=("mysql_data" "mongo_data" "postgres_data")
    local success_count=0
    local fail_count=0

    log_info "开始批量备份所有数据库 volumes..."
    log_info "备份路径: $backup_path"
    echo

    # 检查备份脚本是否存在
    if [[ ! -f "$backup_script" ]]; then
        log_error "备份脚本不存在: $backup_script"
        exit 1
    fi

    # 检查 Docker 是否运行
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker 未运行，请先启动 Docker"
        exit 1
    fi

    # 遍历所有 volumes 进行备份
    for volume in "${volumes[@]}"; do
        echo "----------------------------------------"
        log_info "备份 volume: $volume"
        
        if bash "$backup_script" "$volume" "$backup_path" >/dev/null 2>&1; then
            log_success "$volume 备份成功"
            ((success_count++))
        else
            # 检查 volume 是否存在
            if docker volume inspect "$volume" >/dev/null 2>&1; then
                log_error "$volume 备份失败"
                ((fail_count++))
            else
                log_info "$volume 不存在，跳过备份"
            fi
        fi
        echo
    done

    # 输出总结
    echo "========================================"
    log_info "备份任务完成"
    log_success "成功: $success_count"
    if [[ $fail_count -gt 0 ]]; then
        log_error "失败: $fail_count"
    fi
    log_info "备份路径: $backup_path"
    echo "========================================"
}

# 执行主函数
main "$@"

