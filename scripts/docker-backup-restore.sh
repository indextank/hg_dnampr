#!/usr/bin/env bash

# ==========================================
# Docker Volume / Image 备份恢复工具
# ==========================================
# 功能：
#   1. 备份 / 恢复 Docker named volume
#   2. 备份 / 恢复单个 Docker image
#   3. 备份 / 恢复全部 Docker image
#   4. 直接运行脚本时以菜单形式交互

set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

DEFAULT_VOLUME_BACKUP_DIR="/backup/volumes"
DEFAULT_IMAGE_BACKUP_DIR="/backup/images"

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

show_help() {
    cat << EOF
${GREEN}Docker Volume / Image 备份恢复工具${NC}

${YELLOW}用法：${NC}
  $0                         # 打开交互菜单
  $0 volume-backup [volume] [backup_dir]
  $0 volume-restore [volume] [backup_file]
  $0 image-backup [image] [backup_dir]
  $0 image-backup-all [backup_dir]
  $0 image-restore [backup_file]
  $0 image-restore-all [backup_dir]

${YELLOW}默认目录：${NC}
  Volume 备份：${DEFAULT_VOLUME_BACKUP_DIR}
  Image  备份：${DEFAULT_IMAGE_BACKUP_DIR}

${YELLOW}说明：${NC}
  - Volume 备份文件格式：{volume}_backup_YYYYMMDD_HHMMSS.tar.gz
  - Image  备份文件格式：{image}_image_backup_YYYYMMDD_HHMMSS.tar.gz
  - 恢复操作会覆盖 volume 数据或导入镜像，请谨慎操作

EOF
}

require_docker() {
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker 未运行，请先启动 Docker"
        exit 1
    fi
}

confirm() {
    local prompt="${1:-确认继续？}"
    read -r -p "${prompt} [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

prompt_with_default() {
    local prompt="$1"
    local default_value="$2"
    local value

    read -r -p "${prompt} [默认: ${default_value}]: " value
    echo "${value:-$default_value}"
}

sanitize_name() {
    local name="$1"
    name="${name//\//_}"
    name="${name//:/_}"
    name="${name//@/_}"
    echo "$name" | tr -cs '[:alnum:]_.-' '_'
}

write_checksum() {
    local file_path="$1"
    local checksum

    checksum="$(sha256sum "$file_path" | cut -d' ' -f1)"
    echo "$checksum" > "${file_path}.sha256"
    log_info "校验和: $checksum (已保存到 ${file_path}.sha256)"
}

check_backup_file() {
    local backup_file="$1"
    local allowed_pattern="${2:-.*}"

    if [[ ! -f "$backup_file" ]]; then
        log_error "备份文件不存在: $backup_file"
        return 1
    fi

    if [[ ! "$backup_file" =~ $allowed_pattern ]]; then
        log_error "备份文件格式不正确: $backup_file"
        return 1
    fi

    local checksum_file="${backup_file}.sha256"
    if [[ -f "$checksum_file" ]]; then
        log_info "验证备份文件校验和..."
        local expected_checksum
        local actual_checksum
        expected_checksum="$(tr -d '[:space:]' < "$checksum_file")"
        actual_checksum="$(sha256sum "$backup_file" | cut -d' ' -f1)"

        if [[ "$expected_checksum" == "$actual_checksum" ]]; then
            log_success "校验和验证通过"
        else
            log_error "校验和验证失败，文件可能已损坏"
            log_error "期望: $expected_checksum"
            log_error "实际: $actual_checksum"
            return 1
        fi
    else
        log_warn "未找到校验和文件，跳过验证"
    fi
}

check_volume_exists() {
    local volume_name="$1"
    docker volume inspect "$volume_name" >/dev/null 2>&1
}

select_volume() {
    local volumes=()
    local PS3="请选择编号: "
    mapfile -t volumes < <(docker volume ls --format "{{ .Name }}" | sort)

    if [[ ${#volumes[@]} -eq 0 ]]; then
        log_error "当前没有可用的 Docker volume"
        return 1
    fi

    echo >&2
    log_info "可用 Volume：" >&2
    select volume_name in "${volumes[@]}" "手动输入" "取消"; do
        case "$volume_name" in
            "手动输入")
                read -r -p "请输入 Volume 名称: " volume_name
                [[ -n "$volume_name" ]] && echo "$volume_name" && return 0
                log_warn "Volume 名称不能为空" >&2
                ;;
            "取消")
                return 1
                ;;
            "")
                log_warn "无效选择，请重试" >&2
                ;;
            *)
                echo "$volume_name"
                return 0
                ;;
        esac
    done
}

select_image() {
    local images=()
    local PS3="请选择编号: "
    mapfile -t images < <(docker image ls --format "{{.Repository}}:{{.Tag}}" | awk '$0 !~ /^<none>:/ && $0 !~ /:<none>$/' | sort -u)

    if [[ ${#images[@]} -eq 0 ]]; then
        log_error "当前没有可用的已命名 Docker image"
        return 1
    fi

    echo >&2
    log_info "可用 Image：" >&2
    select image_ref in "${images[@]}" "手动输入" "取消"; do
        case "$image_ref" in
            "手动输入")
                read -r -p "请输入 Image 名称（如 nginx:1.25）: " image_ref
                [[ -n "$image_ref" ]] && echo "$image_ref" && return 0
                log_warn "Image 名称不能为空" >&2
                ;;
            "取消")
                return 1
                ;;
            "")
                log_warn "无效选择，请重试" >&2
                ;;
            *)
                echo "$image_ref"
                return 0
                ;;
        esac
    done
}

backup_volume() {
    local volume_name="$1"
    local backup_dir="${2:-$DEFAULT_VOLUME_BACKUP_DIR}"
    local timestamp
    local backup_file
    local temp_container

    timestamp="$(date +"%Y%m%d_%H%M%S")"
    backup_file="${backup_dir}/${volume_name}_backup_${timestamp}.tar.gz"
    temp_container="backup-${volume_name}-${timestamp}"

    mkdir -p "$backup_dir"

    log_info "开始备份 Volume: $volume_name"
    log_info "备份目录: $backup_dir"

    if ! check_volume_exists "$volume_name"; then
        log_error "Volume '$volume_name' 不存在"
        return 1
    fi

    local mountpoint
    local driver
    mountpoint="$(docker volume inspect "$volume_name" --format '{{ .Mountpoint }}' 2>/dev/null)"
    driver="$(docker volume inspect "$volume_name" --format '{{ .Driver }}' 2>/dev/null)"
    log_info "Volume 挂载点: $mountpoint"
    log_info "Volume 驱动: $driver"

    local using_containers
    using_containers="$(docker ps -a --filter "volume=$volume_name" --format "{{.Names}}" 2>/dev/null || true)"
    if [[ -n "$using_containers" ]]; then
        log_warn "以下容器正在使用该 Volume："
        while read -r container; do
            [[ -n "$container" ]] && log_warn "  - $container"
        done <<< "$using_containers"
        log_warn "建议先停止相关容器，以确保数据一致性"
        confirm "是否继续备份？" || {
            log_info "备份已取消"
            return 1
        }
    fi

    if docker run --rm \
        --name "$temp_container" \
        -v "$volume_name:/data:ro" \
        -v "$backup_dir:/backup" \
        alpine:latest \
        tar czf "/backup/$(basename "$backup_file")" -C /data . 2>/dev/null; then
        if [[ -f "$backup_file" ]]; then
            log_success "Volume 备份完成"
            log_info "备份文件: $backup_file"
            log_info "文件大小: $(du -h "$backup_file" | cut -f1)"
            write_checksum "$backup_file"
        else
            log_error "备份文件未生成"
            return 1
        fi
    else
        log_error "Volume 备份失败"
        return 1
    fi
}

restore_volume() {
    local volume_name="$1"
    local backup_file="$2"
    local temp_container

    temp_container="restore-${volume_name}-$(date +%s)"

    log_info "开始恢复 Volume: $volume_name"
    log_info "备份文件: $backup_file"

    check_backup_file "$backup_file" '\.(tar\.gz|tgz)$' || return 1

    local using_containers
    using_containers="$(docker ps --filter "volume=$volume_name" --format "{{.Names}}" 2>/dev/null || true)"
    if [[ -n "$using_containers" ]]; then
        log_error "以下容器正在使用该 Volume，请先停止："
        while read -r container; do
            [[ -n "$container" ]] && log_error "  - $container"
        done <<< "$using_containers"
        return 1
    fi

    if ! check_volume_exists "$volume_name"; then
        log_info "Volume '$volume_name' 不存在，正在创建..."
        docker volume create "$volume_name" >/dev/null
        log_success "Volume 创建成功"
    else
        log_warn "Volume '$volume_name' 已存在，恢复操作将覆盖现有数据"
        confirm "确认继续恢复？" || {
            log_info "恢复已取消"
            return 1
        }
    fi

    local backup_file_abs
    local backup_dir
    local backup_filename
    backup_file_abs="$(readlink -f "$backup_file" 2>/dev/null || echo "$backup_file")"
    backup_dir="$(dirname "$backup_file_abs")"
    backup_filename="$(basename "$backup_file_abs")"

    log_info "清空 Volume 数据..."
    docker run --rm \
        -v "$volume_name:/data" \
        alpine:latest \
        sh -c "rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null || true" >/dev/null 2>&1

    log_info "从备份文件恢复数据..."
    if docker run --rm \
        --name "$temp_container" \
        -v "$volume_name:/data" \
        -v "$backup_dir:/backup:ro" \
        alpine:latest \
        sh -c "cd /data && tar xzf /backup/$backup_filename" 2>/dev/null; then
        local data_size
        data_size="$(docker run --rm -v "$volume_name:/data:ro" alpine:latest sh -c "du -sh /data 2>/dev/null | cut -f1" 2>/dev/null || echo "未知")"
        log_success "Volume 恢复完成"
        log_info "恢复的数据大小: $data_size"
    else
        log_error "Volume 恢复失败"
        return 1
    fi
}

check_image_exists() {
    local image_ref="$1"
    docker image inspect "$image_ref" >/dev/null 2>&1
}

backup_image() {
    local image_ref="$1"
    local backup_dir="${2:-$DEFAULT_IMAGE_BACKUP_DIR}"
    local timestamp
    local safe_name
    local backup_file

    if ! check_image_exists "$image_ref"; then
        log_error "Image '$image_ref' 不存在"
        return 1
    fi

    mkdir -p "$backup_dir"
    timestamp="$(date +"%Y%m%d_%H%M%S")"
    safe_name="$(sanitize_name "$image_ref")"
    backup_file="${backup_dir}/${safe_name}_image_backup_${timestamp}.tar.gz"

    log_info "开始备份 Image: $image_ref"
    log_info "备份文件: $backup_file"

    if docker save "$image_ref" | gzip > "$backup_file"; then
        log_success "Image 备份完成"
        log_info "文件大小: $(du -h "$backup_file" | cut -f1)"
        write_checksum "$backup_file"
    else
        rm -f "$backup_file"
        log_error "Image 备份失败: $image_ref"
        return 1
    fi
}

list_named_images() {
    docker image ls --format "{{.Repository}}:{{.Tag}}" \
        | awk '$0 !~ /^<none>:/ && $0 !~ /:<none>$/' \
        | sort -u
}

backup_all_images() {
    local backup_dir="${1:-$DEFAULT_IMAGE_BACKUP_DIR}"
    local images=()
    local failed=0

    mapfile -t images < <(list_named_images)

    if [[ ${#images[@]} -eq 0 ]]; then
        log_error "当前没有可备份的已命名 Docker image"
        return 1
    fi

    log_warn "将备份全部已命名镜像，共 ${#images[@]} 个"
    confirm "确认继续？" || {
        log_info "备份已取消"
        return 1
    }

    mkdir -p "$backup_dir"
    for image_ref in "${images[@]}"; do
        if ! backup_image "$image_ref" "$backup_dir"; then
            failed=$((failed + 1))
        fi
    done

    if [[ "$failed" -eq 0 ]]; then
        log_success "全部 Image 备份完成"
    else
        log_warn "全部 Image 备份结束，失败数量: $failed"
        return 1
    fi
}

load_image_file() {
    local backup_file="$1"

    check_backup_file "$backup_file" '\.(tar|tar\.gz|tgz)$' || return 1

    log_info "开始恢复 Image 文件: $backup_file"
    case "$backup_file" in
        *.tar.gz|*.tgz)
            gzip -dc "$backup_file" | docker load
            ;;
        *.tar)
            docker load -i "$backup_file"
            ;;
        *)
            log_error "不支持的镜像备份文件格式: $backup_file"
            return 1
            ;;
    esac
    log_success "Image 恢复完成: $backup_file"
}

restore_image() {
    local backup_file="$1"

    log_warn "恢复镜像会向本地 Docker 导入备份文件中的镜像标签"
    confirm "确认继续恢复？" || {
        log_info "恢复已取消"
        return 1
    }

    load_image_file "$backup_file"
}

restore_all_images() {
    local backup_dir="${1:-$DEFAULT_IMAGE_BACKUP_DIR}"
    local files=()
    local failed=0

    if [[ ! -d "$backup_dir" ]]; then
        log_error "备份目录不存在: $backup_dir"
        return 1
    fi

    mapfile -t files < <(find "$backup_dir" -maxdepth 1 -type f \( -name "*.tar" -o -name "*.tar.gz" -o -name "*.tgz" \) | sort)

    if [[ ${#files[@]} -eq 0 ]]; then
        log_error "目录中没有可恢复的镜像备份文件: $backup_dir"
        return 1
    fi

    log_warn "将恢复目录中的全部镜像备份文件，共 ${#files[@]} 个"
    confirm "确认继续？" || {
        log_info "恢复已取消"
        return 1
    }

    for backup_file in "${files[@]}"; do
        if ! load_image_file "$backup_file"; then
            failed=$((failed + 1))
        fi
    done

    if [[ "$failed" -eq 0 ]]; then
        log_success "全部 Image 恢复完成"
    else
        log_warn "全部 Image 恢复结束，失败数量: $failed"
        return 1
    fi
}

menu_volume_backup() {
    local volume_name
    local backup_dir

    volume_name="$(select_volume)" || return 1
    backup_dir="$(prompt_with_default "请输入 Volume 备份目录" "$DEFAULT_VOLUME_BACKUP_DIR")"
    backup_volume "$volume_name" "$backup_dir"
}

menu_volume_restore() {
    local volume_name
    local backup_file

    read -r -p "请输入要恢复到的 Volume 名称: " volume_name
    if [[ -z "$volume_name" ]]; then
        log_error "Volume 名称不能为空"
        return 1
    fi

    read -r -p "请输入 Volume 备份文件路径: " backup_file
    restore_volume "$volume_name" "$backup_file"
}

menu_image_backup() {
    local image_ref
    local backup_dir

    image_ref="$(select_image)" || return 1
    backup_dir="$(prompt_with_default "请输入 Image 备份目录" "$DEFAULT_IMAGE_BACKUP_DIR")"
    backup_image "$image_ref" "$backup_dir"
}

menu_image_backup_all() {
    local backup_dir

    backup_dir="$(prompt_with_default "请输入 Image 备份目录" "$DEFAULT_IMAGE_BACKUP_DIR")"
    backup_all_images "$backup_dir"
}

menu_image_restore() {
    local backup_file

    read -r -p "请输入 Image 备份文件路径: " backup_file
    restore_image "$backup_file"
}

menu_image_restore_all() {
    local backup_dir

    backup_dir="$(prompt_with_default "请输入 Image 备份目录" "$DEFAULT_IMAGE_BACKUP_DIR")"
    restore_all_images "$backup_dir"
}

main_menu() {
    while true; do
        echo
        echo -e "${GREEN}Docker Volume / Image 备份恢复工具${NC}"
        echo "1) 备份单个 Volume"
        echo "2) 恢复单个 Volume"
        echo "3) 备份单个 Image"
        echo "4) 备份全部 Image"
        echo "5) 恢复单个 Image"
        echo "6) 恢复全部 Image"
        echo "0) 退出"
        echo
        read -r -p "请选择操作: " choice

        case "$choice" in
            1) menu_volume_backup ;;
            2) menu_volume_restore ;;
            3) menu_image_backup ;;
            4) menu_image_backup_all ;;
            5) menu_image_restore ;;
            6) menu_image_restore_all ;;
            0)
                log_info "已退出"
                exit 0
                ;;
            *)
                log_warn "无效选择，请重试"
                ;;
        esac
    done
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        show_help
        exit 0
    fi

    require_docker

    case "${1:-menu}" in
        menu)
            main_menu
            ;;
        volume-backup)
            backup_volume "${2:?缺少 volume 名称}" "${3:-$DEFAULT_VOLUME_BACKUP_DIR}"
            ;;
        volume-restore)
            restore_volume "${2:?缺少 volume 名称}" "${3:?缺少备份文件路径}"
            ;;
        image-backup)
            backup_image "${2:?缺少 image 名称}" "${3:-$DEFAULT_IMAGE_BACKUP_DIR}"
            ;;
        image-backup-all)
            backup_all_images "${2:-$DEFAULT_IMAGE_BACKUP_DIR}"
            ;;
        image-restore)
            restore_image "${2:?缺少备份文件路径}"
            ;;
        image-restore-all)
            restore_all_images "${2:-$DEFAULT_IMAGE_BACKUP_DIR}"
            ;;
        *)
            log_error "未知命令: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
