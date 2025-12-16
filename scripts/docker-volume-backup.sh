#!/bin/bash

# ==========================================
# Docker Volume 备份脚本
# ==========================================
# 功能：备份 Docker named volume 数据，防止容器或镜像损坏导致数据丢失
# 使用方法：./scripts/docker-volume-backup.sh [volume_name] [backup_path]
#
# 示例：
#   ./scripts/docker-volume-backup.sh mysql_data /backup
#   ./scripts/docker-volume-backup.sh mongo_data /backup
#   ./scripts/docker-volume-backup.sh postgres_data /backup

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# 显示使用帮助
show_help() {
    cat << EOF
${GREEN}Docker Volume 备份脚本${NC}

${YELLOW}功能：${NC}
  备份 Docker named volume 数据，确保容器或镜像损坏时数据不丢失

${YELLOW}使用方法：${NC}
  $0 [volume_name] [backup_path]

${YELLOW}参数：${NC}
  volume_name   - Docker volume 名称（必需）
  backup_path   - 备份文件存储路径（可选，默认：/backup/volumes）

${YELLOW}示例：${NC}
  $0 mysql_data                    # 备份到默认路径
  $0 mysql_data /data/backup       # 备份到指定路径
  $0 mongo_data /backup
  $0 postgres_data /backup

${YELLOW}支持的 volume：${NC}
  - mysql_data      MySQL 数据卷
  - mongo_data      MongoDB 数据卷
  - postgres_data   PostgreSQL 数据卷

${YELLOW}备份文件格式：${NC}
  {volume_name}_backup_YYYYMMDD_HHMMSS.tar.gz

EOF
}

# 检查 volume 是否存在
check_volume_exists() {
    local volume_name="$1"
    if docker volume inspect "$volume_name" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 获取 volume 信息
get_volume_info() {
    local volume_name="$1"
    local mountpoint=$(docker volume inspect "$volume_name" --format '{{ .Mountpoint }}' 2>/dev/null)
    local driver=$(docker volume inspect "$volume_name" --format '{{ .Driver }}' 2>/dev/null)
    echo "$mountpoint|$driver"
}

# 备份 volume
backup_volume() {
    local volume_name="$1"
    local backup_path="${2:-/backup/volumes}"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="${backup_path}/${volume_name}_backup_${timestamp}.tar.gz"
    local temp_container="backup-${volume_name}-${timestamp}"

    # 创建备份目录
    mkdir -p "$backup_path"

    log_info "开始备份 volume: $volume_name"
    log_info "备份路径: $backup_path"

    # 检查 volume 是否存在
    if ! check_volume_exists "$volume_name"; then
        log_error "Volume '$volume_name' 不存在！"
        log_info "可用的 volumes："
        docker volume ls --format "{{ .Name }}" | grep -E "(mysql|mongo|postgres)" || true
        return 1
    fi

    # 获取 volume 信息
    local volume_info=$(get_volume_info "$volume_name")
    local mountpoint=$(echo "$volume_info" | cut -d'|' -f1)
    local driver=$(echo "$volume_info" | cut -d'|' -f2)

    log_info "Volume 挂载点: $mountpoint"
    log_info "Volume 驱动: $driver"

    # 检查是否有容器正在使用该 volume
    local using_containers=$(docker ps -a --filter "volume=$volume_name" --format "{{.Names}}" 2>/dev/null || echo "")
    if [[ -n "$using_containers" ]]; then
        log_warn "以下容器正在使用该 volume："
        echo "$using_containers" | while read -r container; do
            log_warn "  - $container"
        done
        log_info "建议：在备份前停止相关容器以确保数据一致性"
        read -p "是否继续备份？[y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "备份已取消"
            return 1
        fi
    fi

    # 创建临时容器来访问 volume 数据
    log_info "创建临时容器进行备份..."
    if docker run --rm \
        --name "$temp_container" \
        -v "$volume_name:/data:ro" \
        -v "$backup_path:/backup" \
        alpine:latest \
        tar czf "/backup/$(basename "$backup_file")" -C /data . 2>/dev/null; then
        
        # 验证备份文件
        if [[ -f "$backup_file" ]]; then
            local file_size=$(du -h "$backup_file" | cut -f1)
            log_success "备份完成！"
            log_info "备份文件: $backup_file"
            log_info "文件大小: $file_size"
            
            # 计算校验和
            local checksum=$(sha256sum "$backup_file" | cut -d' ' -f1)
            echo "$checksum" > "${backup_file}.sha256"
            log_info "校验和: $checksum (已保存到 ${backup_file}.sha256)"
            
            return 0
        else
            log_error "备份文件未生成！"
            return 1
        fi
    else
        log_error "备份失败！"
        return 1
    fi
}

# 主函数
main() {
    # 检查参数
    if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_help
        exit 0
    fi

    local volume_name="$1"
    local backup_path="${2:-/backup/volumes}"

    # 检查 Docker 是否运行
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker 未运行，请先启动 Docker"
        exit 1
    fi

    # 执行备份
    if backup_volume "$volume_name" "$backup_path"; then
        log_success "Volume 备份任务完成！"
        exit 0
    else
        log_error "Volume 备份任务失败！"
        exit 1
    fi
}

# 执行主函数
main "$@"

