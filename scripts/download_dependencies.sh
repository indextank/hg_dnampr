#!/bin/bash

# ==========================================
# 依赖软件包下载脚本
# ==========================================
# 功能：检查并下载构建所需的软件包到src目录
# 作者：自动化构建系统
# 使用方法：./scripts/download_dependencies.sh [服务名...]

set -euo pipefail

# 脚本配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$PROJECT_DIR/src"

# 引入公共函数库
source "$SCRIPT_DIR/common_functions.sh"

# 加载环境变量
load_env_files() {
    local config_dir="$PROJECT_DIR/config/env"
    
    # 加载所有环境配置文件
    for env_file in "$config_dir"/*.env; do
        if [[ -f "$env_file" ]]; then
            log "加载配置文件: $(basename "$env_file")"
            # 使用while循环逐行读取，跳过注释和空行
            while IFS= read -r line; do
                # 去掉行首尾空格
                line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                
                # 跳过注释行和空行
                [[ "$line" =~ ^# ]] && continue
                [[ -z "$line" ]] && continue
                
                # 检查是否包含等号且不是注释行
                if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                    # 提取键和值
                    key=$(echo "$line" | cut -d'=' -f1)
                    value=$(echo "$line" | cut -d'=' -f2- | sed 's/[[:space:]]*#.*$//')
                    
                    # 导出变量
                    if [[ -n "$key" && -n "$value" ]]; then
                        export "$key"="$value"
                    fi
                fi
            done < "$env_file"
        fi
    done
}

# 创建目录函数
ensure_directory() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        log "创建目录: $dir"
        mkdir -p "$dir"
    fi
}

# 下载文件函数
download_file() {
    local url="$1"
    local output_file="$2"
    local description="${3:-文件}"
    
    if [[ -f "$output_file" ]]; then
        info "$description 已存在，跳过下载: $(basename "$output_file")"
        return 0
    fi
    
    log "下载 $description: $(basename "$output_file")"
    
    # 创建输出目录
    ensure_directory "$(dirname "$output_file")"
    
    # 下载文件，支持重试
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        if curl -fsSL --retry 3 --retry-delay 5 -o "$output_file" "$url"; then
            success "下载完成: $(basename "$output_file")"
            return 0
        else
            retry_count=$((retry_count + 1))
            warn "下载失败，重试 $retry_count/$max_retries: $(basename "$output_file")"
            sleep 2
        fi
    done
    
    error "下载失败: $description"
    return 1
}

# PHP相关下载
download_php_dependencies() {
    local php_version="$1"
    local php_src_dir="$SRC_DIR/php"
    
    ensure_directory "$php_src_dir"
    
    info "下载PHP $php_version 相关依赖..."
    
    # PHP源码
    download_file \
        "https://www.php.net/distributions/php-${php_version}.tar.xz" \
        "$php_src_dir/php-${php_version}.tar.xz" \
        "PHP ${php_version} 源码"
    
    # OpenSSL
    if [[ -n "${OPENSSL_VERSION:-}" ]]; then
        download_file \
            "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" \
            "$php_src_dir/openssl-${OPENSSL_VERSION}.tar.gz" \
            "OpenSSL ${OPENSSL_VERSION}"
    fi
    
    # cURL
    if [[ -n "${CURL_VERSION:-}" ]]; then
        download_file \
            "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" \
            "$php_src_dir/curl-${CURL_VERSION}.tar.xz" \
            "cURL ${CURL_VERSION}"
    fi
    
    # FreeType
    if [[ -n "${FREETYPE_VERSION:-}" ]]; then
        download_file \
            "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz" \
            "$php_src_dir/freetype-${FREETYPE_VERSION}.tar.xz" \
            "FreeType ${FREETYPE_VERSION}"
    fi
    
    # LibWebP
    if [[ -n "${LIBWEBP_VERSION:-}" ]]; then
        download_file \
            "https://github.com/webmproject/libwebp/archive/v${LIBWEBP_VERSION}.tar.gz" \
            "$php_src_dir/libwebp-${LIBWEBP_VERSION}.tar.gz" \
            "LibWebP ${LIBWEBP_VERSION}"
    fi
    
    # ImageMagick
    if [[ -n "${IMAGICK_VERSION:-}" ]]; then
        download_file \
            "https://github.com/ImageMagick/ImageMagick/archive/${IMAGICK_VERSION}.tar.gz" \
            "$php_src_dir/ImageMagick-${IMAGICK_VERSION}.tar.gz" \
            "ImageMagick ${IMAGICK_VERSION}"
    fi
}

# Nginx相关下载
download_nginx_dependencies() {
    local nginx_src_dir="$SRC_DIR/nginx"
    
    ensure_directory "$nginx_src_dir"
    
    info "下载Nginx相关依赖..."
    
    # Nginx源码
    if [[ -n "${NGINX_VERSION:-}" ]]; then
        download_file \
            "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
            "$nginx_src_dir/nginx-${NGINX_VERSION}.tar.gz" \
            "Nginx ${NGINX_VERSION}"
    fi
    
    # Tengine源码
    if [[ -n "${TENGINE_VERSION:-}" ]]; then
        download_file \
            "https://github.com/alibaba/tengine/archive/${TENGINE_VERSION}.tar.gz" \
            "$nginx_src_dir/tengine-${TENGINE_VERSION}.tar.gz" \
            "Tengine ${TENGINE_VERSION}"
    fi
    
    # OpenSSL (for Nginx)
    if [[ -n "${OPENSSL_VERSION:-}" ]]; then
        download_file \
            "https://openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" \
            "$nginx_src_dir/openssl-${OPENSSL_VERSION}.tar.gz" \
            "OpenSSL ${OPENSSL_VERSION} (for Nginx)"
    fi
    
    # PCRE
    if [[ -n "${PCRE_VERSION:-}" ]]; then
        download_file \
            "https://ftp.exim.org/pub/pcre/pcre-${PCRE_VERSION}.tar.gz" \
            "$nginx_src_dir/pcre-${PCRE_VERSION}.tar.gz" \
            "PCRE ${PCRE_VERSION}"
    fi
    
    # Headers More Nginx Module
    if [[ -n "${HEADERS_MORE_NGINX_MODULE_VERSION:-}" ]]; then
        download_file \
            "https://github.com/openresty/headers-more-nginx-module/archive/v${HEADERS_MORE_NGINX_MODULE_VERSION}.tar.gz" \
            "$nginx_src_dir/headers-more-nginx-module-${HEADERS_MORE_NGINX_MODULE_VERSION}.tar.gz" \
            "Headers More Nginx Module ${HEADERS_MORE_NGINX_MODULE_VERSION}"
    fi
}

# Redis相关下载
download_redis_dependencies() {
    local redis_src_dir="$SRC_DIR/redis"
    
    ensure_directory "$redis_src_dir"
    
    info "下载Redis相关依赖..."
    
    # Redis源码
    if [[ -n "${REDIS_VERSION:-}" ]]; then
        download_file \
            "https://github.com/redis/redis/archive/${REDIS_VERSION}.tar.gz" \
            "$redis_src_dir/redis-${REDIS_VERSION}.tar.gz" \
            "Redis ${REDIS_VERSION}"
    fi
    
    # Valkey源码
    if [[ -n "${VALKEY_VERSION:-}" ]]; then
        download_file \
            "https://github.com/valkey-io/valkey/archive/${VALKEY_VERSION}.tar.gz" \
            "$redis_src_dir/valkey-${VALKEY_VERSION}.tar.gz" \
            "Valkey ${VALKEY_VERSION}"
    fi
}

# MySQL相关下载
download_mysql_dependencies() {
    local mysql_src_dir="$SRC_DIR/mysql"
    
    ensure_directory "$mysql_src_dir"
    
    info "下载MySQL相关依赖..."
    
    # MySQL源码
    if [[ -n "${MYSQL_VERSION:-}" ]]; then
        download_file \
            "https://dev.mysql.com/get/Downloads/MySQL-8.0/mysql-${MYSQL_VERSION}.tar.gz" \
            "$mysql_src_dir/mysql-${MYSQL_VERSION}.tar.gz" \
            "MySQL ${MYSQL_VERSION}"
    fi
    
    # Gosu
    if [[ -n "${GOSU_VERSION:-}" ]]; then
        download_file \
            "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-amd64" \
            "$mysql_src_dir/gosu-amd64" \
            "Gosu ${GOSU_VERSION}"
    fi
}

# MongoDB相关下载
download_mongo_dependencies() {
    local mongo_src_dir="$SRC_DIR/mongo"
    
    ensure_directory "$mongo_src_dir"
    
    info "下载MongoDB相关依赖..."
    
    # MongoDB源码
    if [[ -n "${MONGO_VERSION:-}" ]]; then
        download_file \
            "https://github.com/mongodb/mongo/archive/r${MONGO_VERSION}.tar.gz" \
            "$mongo_src_dir/mongo-${MONGO_VERSION}.tar.gz" \
            "MongoDB ${MONGO_VERSION}"
    fi
}

# PostgreSQL相关下载
download_postgres_dependencies() {
    local postgres_src_dir="$SRC_DIR/postgres"
    
    ensure_directory "$postgres_src_dir"
    
    info "下载PostgreSQL相关依赖..."
    
    # PostgreSQL源码 (使用PG_VERSION变量)
    if [[ -n "${PG_VERSION:-}" ]]; then
        # 提取主版本号 (例如从17.5-1.pgdg120+1提取17.5)
        local pg_main_version=$(echo "${PG_VERSION}" | sed 's/-.*$//')
        download_file \
            "https://ftp.postgresql.org/pub/source/v${pg_main_version}/postgresql-${pg_main_version}.tar.gz" \
            "$postgres_src_dir/postgresql-${pg_main_version}.tar.gz" \
            "PostgreSQL ${pg_main_version}"
    fi
}

# ELK相关下载
download_elk_dependencies() {
    local elk_src_dir="$SRC_DIR/elk"
    
    ensure_directory "$elk_src_dir"
    
    info "下载ELK相关依赖..."
    
    # Elasticsearch
    if [[ -n "${ELK_VERSION:-}" ]]; then
        local es_dir="$elk_src_dir/elasticsearch"
        ensure_directory "$es_dir"
        
        download_file \
            "https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-${ELK_VERSION}-linux-x86_64.tar.gz" \
            "$es_dir/elasticsearch-${ELK_VERSION}-linux-x86_64.tar.gz" \
            "Elasticsearch ${ELK_VERSION}"
        
        # Kibana
        local kibana_dir="$elk_src_dir/kibana"
        ensure_directory "$kibana_dir"
        
        download_file \
            "https://artifacts.elastic.co/downloads/kibana/kibana-${ELK_VERSION}-linux-x86_64.tar.gz" \
            "$kibana_dir/kibana-${ELK_VERSION}-linux-x86_64.tar.gz" \
            "Kibana ${ELK_VERSION}"
        
        # Logstash
        local logstash_dir="$elk_src_dir/logstash"
        ensure_directory "$logstash_dir"
        
        download_file \
            "https://artifacts.elastic.co/downloads/logstash/logstash-${ELK_VERSION}-linux-x86_64.tar.gz" \
            "$logstash_dir/logstash-${ELK_VERSION}-linux-x86_64.tar.gz" \
            "Logstash ${ELK_VERSION}"
    fi
    
    # Tini
    if [[ -n "${TINI_VERSION:-}" ]]; then
        download_file \
            "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini" \
            "$elk_src_dir/tini" \
            "Tini ${TINI_VERSION}"
    fi
}

# 根据服务下载依赖
download_service_dependencies() {
    local service="$1"
    
    case "$service" in
        php84|php83|php82|php81|php80|php74|php72)
            local version_var="PHP${service#php}_VERSION"
            local php_version="${!version_var:-}"
            if [[ -n "$php_version" ]]; then
                download_php_dependencies "$php_version"
            else
                warn "未找到 $service 的版本配置"
            fi
            ;;
        nginx)
            download_nginx_dependencies
            ;;
        tengine)
            download_nginx_dependencies
            ;;
        redis)
            download_redis_dependencies
            ;;
        valkey)
            download_redis_dependencies
            ;;
        mysql|mysql_backup)
            download_mysql_dependencies
            ;;
        mongo)
            download_mongo_dependencies
            ;;
        postgres)
            download_postgres_dependencies
            ;;
        elk)
            download_elk_dependencies
            ;;
        all)
            # 下载所有依赖
            download_php_dependencies "${PHP84_VERSION:-}"
            download_php_dependencies "${PHP83_VERSION:-}"
            download_php_dependencies "${PHP82_VERSION:-}"
            download_php_dependencies "${PHP81_VERSION:-}"
            download_php_dependencies "${PHP80_VERSION:-}"
            download_php_dependencies "${PHP74_VERSION:-}"
            download_php_dependencies "${PHP72_VERSION:-}"
            download_nginx_dependencies
            download_redis_dependencies
            download_mysql_dependencies
            download_mongo_dependencies
            download_postgres_dependencies
            download_elk_dependencies
            ;;
        *)
            warn "未知服务: $service"
            ;;
    esac
}

# 主函数
main() {
    log "开始下载依赖软件包..."
    
    # 加载环境变量
    load_env_files
    
    # 确保src目录存在
    ensure_directory "$SRC_DIR"
    
    # 如果没有指定服务，显示帮助信息
    if [[ $# -eq 0 ]]; then
        echo "使用方法: $0 [服务名...]"
        echo "支持的服务: php84, php83, php82, php81, php80, php74, php72, nginx, tengine, redis, valkey, mysql, mongo, postgres, elk, all"
        exit 1
    fi
    
    # 下载指定服务的依赖
    for service in "$@"; do
        download_service_dependencies "$service"
    done
    
    success "依赖下载完成！"
}

# 执行主函数
main "$@"