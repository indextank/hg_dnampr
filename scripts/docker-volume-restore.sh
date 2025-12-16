#!/bin/bash

# ==========================================
# Docker Volume 恢复脚本
# ==========================================
# 功能：从备份文件恢复 Docker named volume 数据
# 使用方法：./scripts/docker-volume-restore.sh [volume_name] [backup_file]
#
# 示例：
#   ./scripts/docker-volume-restore.sh mysql_data /backup/volumes/mysql_data_backup_20231214_120000.tar.gz

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
${GREEN}Docker Volume 恢复脚本${NC}

${YELLOW}功能：${NC}
  从备份文件恢复 Docker named volume 数据

${YELLOW}使用方法：${NC}
  $0 [volume_name] [backup_file]

${YELLOW}参数：${NC}
  volume_name   - Docker volume 名称（必需）
  backup_file   - 备份文件路径（必需，支持 .tar.gz 格式）

${YELLOW}示例：${NC}
  $0 mysql_data /backup/volumes/mysql_data_backup_20231214_120000.tar.gz
  $0 mongo_data /backup/volumes/mongo_data_backup_20231214_120000.tar.gz
  $0 postgres_data /backup/volumes/postgres_data_backup_20231214_120000.tar.gz

${YELLOW}⚠️  警告：${NC}
  恢复操作会覆盖 volume 中的现有数据！
  请确保相关容器已停止，并在恢复前做好数据备份。

EOF
}

# 检查备份文件
check_backup_file() {
    local backup_file="$1"
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "备份文件不存在: $backup_file"
        return 1
    fi

    # 检查文件格式
    if [[ ! "$backup_file" =~ \.(tar\.gz|tgz)$ ]]; then
        log_error "备份文件格式不正确，应为 .tar.gz 或 .tgz 格式"
        return 1
    fi

    # 验证校验和（如果存在）
    local checksum_file="${backup_file}.sha256"
    if [[ -f "$checksum_file" ]]; then
        log_info "验证备份文件校验和..."
        local expected_checksum=$(cat "$checksum_file")
        local actual_checksum=$(sha256sum "$backup_file" | cut -d' ' -f1)
        
        if [[ "$expected_checksum" == "$actual_checksum" ]]; then
            log_success "校验和验证通过"
        else
            log_error "校验和验证失败！文件可能已损坏"
            log_error "期望: $expected_checksum"
            log_error "实际: $actual_checksum"
            return 1
        fi
    else
        log_warn "未找到校验和文件，跳过验证"
    fi

    return 0
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

# 恢复 volume
restore_volume() {
    local volume_name="$1"
    local backup_file="$2"
    local temp_container="restore-${volume_name}-$(date +%s)"

    log_info "开始恢复 volume: $volume_name"
    log_info "备份文件: $backup_file"

    # 检查备份文件
    if ! check_backup_file "$backup_file"; then
        return 1
    fi

    # 检查是否有容器正在使用该 volume
    local using_containers=$(docker ps --filter "volume=$volume_name" --format "{{.Names}}" 2>/dev/null || echo "")
    if [[ -n "$using_containers" ]]; then
        log_error "以下容器正在使用该 volume，请先停止："
        echo "$using_containers" | while read -r container; do
            log_error "  - $container"
        done
        log_error "请先停止相关容器："
        echo "$using_containers" | while read -r container; do
            log_info "  docker stop $container"
        done
        return 1
    fi

    # 检查 volume 是否存在，不存在则创建
    if ! check_volume_exists "$volume_name"; then
        log_info "Volume '$volume_name' 不存在，正在创建..."
        if docker volume create "$volume_name" >/dev/null 2>&1; then
            log_success "Volume 创建成功"
        else
            log_error "Volume 创建失败"
            return 1
        fi
    else
        log_warn "⚠️  Volume '$volume_name' 已存在，恢复操作将覆盖现有数据！"
        read -p "确认继续恢复？[y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "恢复已取消"
            return 1
        fi
    fi

    # 获取备份文件绝对路径
    local backup_file_abs=$(readlink -f "$backup_file" 2>/dev/null || echo "$backup_file")
    local backup_dir=$(dirname "$backup_file_abs")
    local backup_filename=$(basename "$backup_file_abs")

    log_info "清空 volume 数据..."
    # 创建临时容器清空 volume
    docker run --rm \
        -v "$volume_name:/data" \
        alpine:latest \
        sh -c "rm -rf /data/* /data/.* 2>/dev/null || true" >/dev/null 2>&1

    log_info "从备份文件恢复数据..."
    # 创建临时容器恢复数据
    if docker run --rm \
        --name "$temp_container" \
        -v "$volume_name:/data" \
        -v "$backup_dir:/backup:ro" \
        alpine:latest \
        sh -c "cd /data && tar xzf /backup/$backup_filename" 2>/dev/null; then
        
        log_success "恢复完成！"
        log_info "Volume: $volume_name"
        log_info "备份文件: $backup_file"
        
        # 验证恢复结果
        local data_size=$(docker run --rm \
            -v "$volume_name:/data:ro" \
            alpine:latest \
            sh -c "du -sh /data 2>/dev/null | cut -f1" 2>/dev/null || echo "未知")
        log_info "恢复的数据大小: $data_size"
        
        return 0
    else
        log_error "恢复失败！"
        return 1
    fi
}

# 主函数
main() {
    # 检查参数
    if [[ $# -lt 2 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_help
        exit 0
    fi

    local volume_name="$1"
    local backup_file="$2"

    # 检查 Docker 是否运行
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker 未运行，请先启动 Docker"
        exit 1
    fi

    # 执行恢复
    if restore_volume "$volume_name" "$backup_file"; then
        log_success "Volume 恢复任务完成！"
        log_info "提示：恢复完成后，可以启动相关容器验证数据"
        exit 0
    else
        log_error "Volume 恢复任务失败！"
        exit 1
    fi
}

# 执行主函数
main "$@"

