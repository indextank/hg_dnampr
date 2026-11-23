#!/bin/bash

# ==========================================
# 依赖软件包下载脚本
# ==========================================
# 功能：检查并下载构建所需的软件包到src目录
# 作者：自动化构建系统
# 使用方法：./include/shell/download_dependencies.sh [服务名...]

set -euo pipefail

# 脚本配置（本文件位于 include/shell/，仓库根为其上两级）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/src"

# 引入公共函数库
source "$SCRIPT_DIR/common_functions.sh"

# 去重提示：同一批次内 RabbitMQ/Canal 类服务只提示一次
RABBITMQ_CANAL_HINT_SHOWN=false

# 加载环境变量
# 用途：由 build.sh 调起时（HG_ENV_LOADED=1）直接继承父进程已合并 .env 覆盖的环境；
#       独立运行时只加载目标服务需要的 env/*.env，再以根目录 .env/.env.local 覆盖。
# 参数：目标服务名...
load_env_files() {
    local config_dir="${ENV_DIR:-$PROJECT_DIR/env}"
    local env_file joined
    local -a scoped=()

    if [[ "${HG_ENV_LOADED:-}" == "1" ]]; then
        return 0
    fi

    mapfile -t scoped < <(env_scope_env_files "$@")
    for env_file in "${scoped[@]}"; do
        load_env_file_exports "$config_dir/$env_file"
    done
    load_env_file_exports "$PROJECT_DIR/.env"
    load_env_file_exports "$PROJECT_DIR/.env.local"
    printf -v joined '%s ' "${scoped[@]}"
    log "按目标服务加载配置文件: ${joined}+ .env/.env.local"
}

# 创建目录函数
ensure_directory() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        log "创建目录: $dir"
        mkdir -p "$dir"
    fi
}

# 判断下载产物是否完整。
# 背景：部分 CDN（如 GitHub release-assets / Azure Blob）在 HTTP/2 下会在传输完成后
# 未干净关闭流，curl 因此返回 18(CURLE_PARTIAL_FILE)，但文件实际上已完整。
# 这里对压缩包做完整性校验，完整就接受，避免误判失败而重复下载。
# 若对应的校验工具不存在，则降级为“非空即接受”，不引入回归。
download_file_is_complete() {
    local f="$1"
    [[ -f "$f" ]] && [[ -s "$f" ]] || return 1
    case "$f" in
        *.tar.gz|*.tgz)
            command -v gzip >/dev/null 2>&1 || return 0
            gzip -t "$f" >/dev/null 2>&1 ;;
        *.tar.xz)
            command -v xz >/dev/null 2>&1 || return 0
            xz -t "$f" >/dev/null 2>&1 ;;
        *.tar.bz2)
            command -v bzip2 >/dev/null 2>&1 || return 0
            bzip2 -t "$f" >/dev/null 2>&1 ;;
        *.zip)
            command -v unzip >/dev/null 2>&1 || return 0
            unzip -tqq "$f" >/dev/null 2>&1 ;;
        *)
            return 0 ;;
    esac
}

# 下载文件函数
# 参数：
#   $1: 单个 URL，或多个备用 URL（以 | 分隔，按顺序回退）
#   $2: 输出文件路径
#   $3: 描述（可选，用于日志）
download_file() {
    local urls="$1"
    local output_file="$2"
    local description="${3:-文件}"

    # 检查文件是否存在且大小大于0
    if [[ -f "$output_file" ]] && [[ -s "$output_file" ]]; then
        info "$description 已存在，跳过下载: $(basename "$output_file")"
        return 0
    fi

    # 如果文件存在但大小为0，删除它
    if [[ -f "$output_file" ]] && [[ ! -s "$output_file" ]]; then
        warn "发现空文件，删除后重新下载: $(basename "$output_file")"
        rm -f "$output_file"
    fi

    log "下载 $description: $(basename "$output_file")"

    # 创建输出目录
    ensure_directory "$(dirname "$output_file")"

    # 拆分多源下载地址（主源 + 备用镜像）
    local -a url_list=()
    local old_ifs="$IFS"
    IFS='|' read -r -a url_list <<< "$urls"
    IFS="$old_ifs"

    local max_retries=3
    local url
    local tried=0

    for url in "${url_list[@]}"; do
        [[ -z "$url" ]] && continue
        tried=$((tried + 1))
        if [[ $tried -gt 1 ]]; then
            warn "主下载源不可用，尝试备用镜像 ${tried}: $url"
        fi

        local retry_count=0
        while [[ $retry_count -lt $max_retries ]]; do
            # --http1.1：强制使用 HTTP/1.1，规避部分 CDN 在 HTTP/2 下出现的
            #   "HTTP/2 stream 1 was not closed cleanly ..."(curl exit 18) 问题。
            # 使用断点续传，超时设置为 1 小时。
            if curl -fL --http1.1 --retry 3 --retry-delay 5 --max-time 3600 --connect-timeout 30 --progress-bar -C - -o "$output_file" "$url"; then
                # curl 成功也要校验：部分镜像会对不存在的路径返回 200 + 错误页
                if download_file_is_complete "$output_file"; then
                    success "下载完成: $(basename "$output_file")"
                    return 0
                fi
                warn "文件校验失败（来源可能返回了错误页），换下一个下载源"
                rm -f "$output_file"
                break
            fi

            # curl 返回非 0 时，文件仍可能已完整（exit 18 仅表示流未干净关闭）。
            # 完整性校验通过则直接接受，避免误删完整文件反复重下。
            if download_file_is_complete "$output_file"; then
                warn "curl 返回非 0，但文件已完整，视为下载成功: $(basename "$output_file")"
                success "下载完成: $(basename "$output_file")"
                return 0
            fi

            retry_count=$((retry_count + 1))
            warn "下载失败，重试 $retry_count/$max_retries: $(basename "$output_file")"
            # 删除不完整文件，避免下次 -C - 从错误偏移续传
            rm -f "$output_file"
            sleep 5
        done
    done

    error "下载失败: $description（已尝试 ${tried} 个下载源）"
    return 1
}

# 生成 OpenSSL 源码的多源下载地址（以 | 分隔，交给 download_file 逐个回退）
#   主源：www.openssl.org/source（会 301 到 GitHub Releases，偶发 HTTP/2 流异常）
#   备源：GitHub Releases 直连（与主源同一份文件，仅 CDN 不同）
#        旧版本归档目录 old/<系列>/（1.1.1 系列官方只在 old 下长期保留）
#        国内反代 ghproxy.net（GitHub 不可达时使用）
# 注意：GitHub Release 的 tag 命名不统一：3.x = openssl-3.5.8；1.1.1w = OpenSSL_1_1_1w
openssl_source_urls() {
    local version="$1"
    local file="openssl-${version}.tar.gz"
    local tag="openssl-${version}"

    case "$version" in
        1.1.1*) tag="OpenSSL_${version//./_}" ;;
    esac

    local urls="https://www.openssl.org/source/${file}"
    urls="${urls}|https://github.com/openssl/openssl/releases/download/${tag}/${file}"

    case "$version" in
        1.1.1*) urls="${urls}|https://www.openssl.org/source/old/1.1.1/${file}" ;;
    esac

    urls="${urls}|https://ghproxy.net/https://github.com/openssl/openssl/releases/download/${tag}/${file}"

    printf '%s' "$urls"
}

# OpenSSL相关下载（统一管理）
download_openssl_dependencies() {
    local openssl_src_dir="$SRC_DIR/openssl"

    ensure_directory "$openssl_src_dir"

    # 检查是否有需要下载的文件
    local need_download=false

    # OpenSSL (主版本)
    if [[ -n "${OPENSSL_VERSION:-}" ]] && [[ ! -f "$openssl_src_dir/openssl-${OPENSSL_VERSION}.tar.gz" ]]; then
        need_download=true
    fi

    # OpenSSL 1.1版本（兼容旧版本）
    if [[ -n "${OPENSSL_VERSION_11:-}" ]] && [[ ! -f "$openssl_src_dir/openssl-${OPENSSL_VERSION_11}.tar.gz" ]]; then
        need_download=true
    fi

    # 只有在需要下载时才显示提示信息
    if [[ "$need_download" == "true" ]]; then
        info "下载OpenSSL相关依赖..."
    else
        info "检查OpenSSL相关依赖..."
    fi

    # OpenSSL (主版本)
    if [[ -n "${OPENSSL_VERSION:-}" ]]; then
        download_file \
            "$(openssl_source_urls "$OPENSSL_VERSION")" \
            "$openssl_src_dir/openssl-${OPENSSL_VERSION}.tar.gz" \
            "OpenSSL ${OPENSSL_VERSION}"
    fi

    # OpenSSL 1.1版本（兼容旧版本）
    if [[ -n "${OPENSSL_VERSION_11:-}" ]]; then
        download_file \
            "$(openssl_source_urls "$OPENSSL_VERSION_11")" \
            "$openssl_src_dir/openssl-${OPENSSL_VERSION_11}.tar.gz" \
            "OpenSSL ${OPENSSL_VERSION_11}"
    fi
}

# PHP相关下载
download_php_dependencies() {
    local php_version="$1"
    local php_src_dir="$SRC_DIR/php"

    ensure_directory "$php_src_dir"

    # 先下载 OpenSSL（统一管理）
    download_openssl_dependencies

    # 检查是否有需要下载的文件
    local need_download=false

    # PHP源码
    if [[ ! -f "$php_src_dir/php-${php_version}.tar.xz" ]]; then
        need_download=true
    fi

    # cURL
    if [[ -n "${CURL_VERSION:-}" ]] && [[ ! -f "$php_src_dir/curl-${CURL_VERSION}.tar.xz" ]]; then
        need_download=true
    fi

    # FreeType
    if [[ -n "${FREETYPE_VERSION:-}" ]] && [[ ! -f "$php_src_dir/freetype-${FREETYPE_VERSION}.tar.xz" ]]; then
        need_download=true
    fi

    # LibWebP
    if [[ -n "${LIBWEBP_VERSION:-}" ]] && [[ ! -f "$php_src_dir/libwebp-${LIBWEBP_VERSION}.tar.gz" ]]; then
        need_download=true
    fi

    # LibIconv
    if [[ -n "${LIBICONV_VERSION:-}" ]] && [[ ! -f "$php_src_dir/libiconv-${LIBICONV_VERSION}.tar.gz" ]]; then
        need_download=true
    fi

    # LibSodium
    if [[ -n "${LIBSODIUM_VERSION:-}" ]] && [[ ! -f "$php_src_dir/libsodium-${LIBSODIUM_VERSION}.tar.gz" ]]; then
        need_download=true
    fi

    # ImageMagick
    if [[ -n "${IMAGICK_VERSION:-}" ]] && [[ ! -f "$php_src_dir/ImageMagick-${IMAGICK_VERSION}.tar.gz" ]]; then
        need_download=true
    fi

    # 只有在需要下载时才显示提示信息
    if [[ "$need_download" == "true" ]]; then
        info "下载PHP $php_version 相关依赖..."
    else
        info "检查PHP $php_version 相关依赖..."
    fi

    # PHP源码
    download_file \
        "https://www.php.net/distributions/php-${php_version}.tar.xz" \
        "$php_src_dir/php-${php_version}.tar.xz" \
        "PHP ${php_version} 源码"

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

    # LibIconv
    if [[ -n "${LIBICONV_VERSION:-}" ]]; then
        download_file \
            "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-${LIBICONV_VERSION}.tar.gz" \
            "$php_src_dir/libiconv-${LIBICONV_VERSION}.tar.gz" \
            "LibIconv ${LIBICONV_VERSION}"
    fi

    # LibSodium
    if [[ -n "${LIBSODIUM_VERSION:-}" ]]; then
        download_file \
            "https://download.libsodium.org/libsodium/releases/libsodium-${LIBSODIUM_VERSION}.tar.gz" \
            "$php_src_dir/libsodium-${LIBSODIUM_VERSION}.tar.gz" \
            "LibSodium ${LIBSODIUM_VERSION}"
    fi

    # ImageMagick
    if [[ -n "${IMAGICK_VERSION:-}" ]]; then
        download_file \
            "https://imagemagick.org/archive/ImageMagick-${IMAGICK_VERSION}.tar.gz" \
            "$php_src_dir/ImageMagick-${IMAGICK_VERSION}.tar.gz" \
            "ImageMagick ${IMAGICK_VERSION}"
    fi
}

# Nginx相关下载
download_nginx_dependencies() {
    local nginx_src_dir="$SRC_DIR/nginx"

    ensure_directory "$nginx_src_dir"

    # 先下载 OpenSSL（统一管理）
    download_openssl_dependencies

    # 检查是否有需要下载的文件
    local need_download=false

    # Nginx源码
    if [[ -n "${NGINX_VERSION:-}" ]] && [[ ! -f "$nginx_src_dir/nginx-${NGINX_VERSION}.tar.gz" ]]; then
        need_download=true
    fi

    # Tengine源码
    if [[ -n "${TENGINE_VERSION:-}" ]] && [[ ! -f "$nginx_src_dir/tengine-${TENGINE_VERSION}.tar.gz" ]]; then
        need_download=true
    fi

    # PCRE
    if [[ -n "${PCRE_VERSION:-}" ]] && [[ ! -f "$nginx_src_dir/pcre-${PCRE_VERSION}.tar.gz" ]]; then
        need_download=true
    fi

    # Headers More Nginx Module
    if [[ -n "${HEADERS_MORE_NGINX_MODULE_VERSION:-}" ]] && [[ ! -f "$nginx_src_dir/headers-more-nginx-module-${HEADERS_MORE_NGINX_MODULE_VERSION}.tar.gz" ]]; then
        need_download=true
    fi

    # ngx_brotli 模块
    if [[ -n "${NGX_BROTLI_VERSION:-}" ]] && [[ ! -f "$nginx_src_dir/ngx_brotli-${NGX_BROTLI_VERSION}.tar.gz" ]]; then
        need_download=true
    fi

    # zstd-nginx-module 模块
    if [[ -n "${NGX_ZSTD_VERSION:-}" ]] && [[ ! -f "$nginx_src_dir/zstd-nginx-module-${NGX_ZSTD_VERSION}.tar.gz" ]]; then
        need_download=true
    fi

    # 只有在需要下载时才显示提示信息
    if [[ "$need_download" == "true" ]]; then
        info "下载Nginx相关依赖..."
    else
        info "检查Nginx相关依赖..."
    fi

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

    # ngx_brotli 模块
    if [[ -n "${NGX_BROTLI_VERSION:-}" ]]; then
        download_file \
            "https://github.com/google/ngx_brotli/archive/v${NGX_BROTLI_VERSION}.tar.gz" \
            "$nginx_src_dir/ngx_brotli-${NGX_BROTLI_VERSION}.tar.gz" \
            "ngx_brotli ${NGX_BROTLI_VERSION}"
    fi

    # zstd-nginx-module 模块
    if [[ -n "${NGX_ZSTD_VERSION:-}" ]]; then
        download_file \
            "https://github.com/tokers/zstd-nginx-module/archive/${NGX_ZSTD_VERSION}.tar.gz" \
            "$nginx_src_dir/zstd-nginx-module-${NGX_ZSTD_VERSION}.tar.gz" \
            "zstd-nginx-module ${NGX_ZSTD_VERSION}"
    fi
}

# Redis相关下载（按 REDIS_BUILD_VERSION 取通道最新，同系列只保留一份；缓存于 src/redis）
download_redis_dependencies() {
    local redis_src_dir="$SRC_DIR/redis"
    local series="${REDIS_BUILD_VERSION:-8.10}"

    ensure_directory "$redis_src_dir"

    if declare -F derive_redis_build_ver >/dev/null 2>&1; then
        derive_redis_build_ver
    fi
    local redis_ver="${REDIS_VERSION:-}"
    if [[ -z "$redis_ver" ]]; then
        warn "无法解析 Redis ${series} 最新版本，跳过源码包下载"
        return 0
    fi

    if [[ ! -f "$redis_src_dir/redis-${redis_ver}.tar.gz" ]]; then
        info "下载Redis相关依赖..."
    else
        info "检查Redis相关依赖..."
    fi

    download_file \
        "https://download.redis.io/releases/redis-${redis_ver}.tar.gz|https://github.com/redis/redis/archive/refs/tags/${redis_ver}.tar.gz" \
        "$redis_src_dir/redis-${redis_ver}.tar.gz" \
        "Redis ${redis_ver}"
    # 强制：仅 src/redis 放 redis 包；同系列（如 8.2.x）只留当前一份；清掉错位的 valkey-*
    if declare -F normalize_kv_src_archives >/dev/null 2>&1; then
        normalize_kv_src_archives "$redis_src_dir" "redis" "$series" "$redis_ver"
    fi
}

# Valkey相关下载（按 VALKEY_BUILD_VERSION 取通道最新；缓存于 src/valkey，供 Dockerfile COPY）
download_valkey_dependencies() {
    local valkey_src_dir="$SRC_DIR/valkey"
    local series="${VALKEY_BUILD_VERSION:-8.1}"

    ensure_directory "$valkey_src_dir"

    if declare -F derive_valkey_build_ver >/dev/null 2>&1; then
        derive_valkey_build_ver
    fi
    local valkey_ver="${VALKEY_VERSION:-}"
    if [[ -z "$valkey_ver" ]]; then
        warn "无法解析 Valkey ${series} 最新版本，跳过源码包下载"
        return 0
    fi

    if [[ ! -f "$valkey_src_dir/valkey-${valkey_ver}.tar.gz" ]]; then
        info "下载Valkey相关依赖..."
    else
        info "检查Valkey相关依赖..."
    fi

    download_file \
        "https://github.com/valkey-io/valkey/archive/refs/tags/${valkey_ver}.tar.gz|https://download.valkey.io/releases/valkey-${valkey_ver}.tar.gz" \
        "$valkey_src_dir/valkey-${valkey_ver}.tar.gz" \
        "Valkey ${valkey_ver}"
    # 强制：仅 src/valkey 放 valkey 包；同系列（如 8.1.x）只留当前一份；清掉错位的 redis-*
    if declare -F normalize_kv_src_archives >/dev/null 2>&1; then
        normalize_kv_src_archives "$valkey_src_dir" "valkey" "$series" "$valkey_ver"
    fi
    # 历史误放：旧逻辑曾把 valkey tar 下到 src/redis，一并清掉
    if declare -F purge_foreign_product_archives >/dev/null 2>&1; then
        purge_foreign_product_archives "$SRC_DIR/redis" "valkey"
    fi
}

# MySQL相关下载（按 MYSQL_BUILD_VERSION 自动取通道最新版，同系列只保留一份 tar.gz）
download_mysql_dependencies() {
    local mysql_src_dir="$SRC_DIR/mysql"
    local series="${MYSQL_BUILD_VERSION:-8.4}"

    ensure_directory "$mysql_src_dir"

    # 解析通道最新版（与 derive_mysql_build_ver 同逻辑）
    if declare -F derive_mysql_build_ver >/dev/null 2>&1; then
        derive_mysql_build_ver
    fi
    local mysql_ver="${MYSQL_VER:-}"
    if [[ -z "$mysql_ver" ]]; then
        warn "无法解析 MySQL ${series} 最新版本，跳过源码包下载（镜像构建仍可走 apt Candidate）"
    fi

    local need_download=false
    local mysql_file=""
    local gosu_file=""

    if [[ -n "$mysql_ver" ]]; then
        mysql_file="$mysql_src_dir/mysql-${mysql_ver}.tar.gz"
        if [[ ! -f "$mysql_file" ]]; then
            need_download=true
        fi
    fi

    if [[ -n "${GOSU_VERSION:-}" ]]; then
        gosu_file="$mysql_src_dir/gosu-amd64-${GOSU_VERSION}"
        if [[ ! -f "$gosu_file" ]] && [[ ! -f "$mysql_src_dir/gosu-amd64" ]]; then
            need_download=true
        fi
    fi

    if [[ "$need_download" == "true" ]]; then
        info "下载MySQL相关依赖..."
    else
        info "检查MySQL相关依赖..."
    fi

    if [[ -n "$mysql_ver" ]]; then
        # 主源 cdn.mysql.com + 官方 get 跳转
        local _series_path="MySQL-${mysql_ver%.*}"
        download_file \
            "https://cdn.mysql.com/Downloads/${_series_path}/mysql-${mysql_ver}.tar.gz|https://dev.mysql.com/get/Downloads/${_series_path}/mysql-${mysql_ver}.tar.gz" \
            "$mysql_src_dir/mysql-${mysql_ver}.tar.gz" \
            "MySQL ${mysql_ver}"
        # 同系列只保留当前一份（如清理 mysql-8.4.11.tar.gz）
        if declare -F prune_versioned_archives >/dev/null 2>&1; then
            prune_versioned_archives "$mysql_src_dir" "mysql-${series}." ".tar.gz" "mysql-${mysql_ver}.tar.gz"
        fi
    fi

    if [[ -n "${GOSU_VERSION:-}" ]]; then
        local _gosu_dest="$mysql_src_dir/gosu-amd64-${GOSU_VERSION}"
        if [[ -f "$_gosu_dest" ]]; then
            info "Gosu ${GOSU_VERSION} 已存在，跳过下载: gosu-amd64-${GOSU_VERSION}"
        elif [[ -f "$mysql_src_dir/gosu-amd64" ]]; then
            cp "$mysql_src_dir/gosu-amd64" "$_gosu_dest"
            chmod +x "$_gosu_dest"
            info "Gosu ${GOSU_VERSION} 已存在（gosu-amd64），已复制为 gosu-amd64-${GOSU_VERSION}"
        else
            download_file \
                "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-amd64" \
                "$_gosu_dest" \
                "Gosu ${GOSU_VERSION}"
            [[ -f "$_gosu_dest" ]] && chmod +x "$_gosu_dest" || true
        fi
    fi
}

# MongoDB相关下载（按 MONGO_BUILD_VERSION 取 apt 通道最新；同系列只保留一份 src/mongo tar.gz）
download_mongo_dependencies() {
    local mongo_src_dir="$SRC_DIR/mongo"
    local series="${MONGO_BUILD_VERSION:-8.2}"

    ensure_directory "$mongo_src_dir"

    if declare -F derive_mongo_build_ver >/dev/null 2>&1; then
        derive_mongo_build_ver
    fi
    local mongo_ver="${MONGO_VERSION:-}"
    if [[ -z "$mongo_ver" ]]; then
        warn "无法解析 MongoDB ${series} 最新版本，跳过源码包下载（镜像构建仍可走 apt Candidate）"
        return 0
    fi

    if [[ ! -f "$mongo_src_dir/mongo-${mongo_ver}.tar.gz" ]]; then
        info "下载MongoDB相关依赖..."
    else
        info "检查MongoDB相关依赖..."
    fi

    download_file \
        "https://github.com/mongodb/mongo/archive/r${mongo_ver}.tar.gz" \
        "$mongo_src_dir/mongo-${mongo_ver}.tar.gz" \
        "MongoDB ${mongo_ver}"
    if declare -F prune_versioned_archives >/dev/null 2>&1; then
        prune_versioned_archives "$mongo_src_dir" "mongo-${series}." ".tar.gz" "mongo-${mongo_ver}.tar.gz"
    fi
}

# PostgreSQL相关下载（按 PG_MAJOR 自动取 PGDG 通道最新版，同主版本只保留一份 tar.gz）
download_postgres_dependencies() {
    local postgres_src_dir="$SRC_DIR/postgres"
    local major="${PG_MAJOR:-19}"

    ensure_directory "$postgres_src_dir"

    if declare -F derive_pg_build_ver >/dev/null 2>&1; then
        derive_pg_build_ver
    fi

    local pg_main_version="${PG_SOURCE_VERSION:-}"
    if [[ -z "$pg_main_version" && -n "${PG_VERSION:-}" ]]; then
        pg_main_version="$(postgres_upstream_ver "${PG_VERSION}")"
    fi

    local need_download=false
    if [[ -n "$pg_main_version" ]]; then
        if [[ ! -f "$postgres_src_dir/postgresql-${pg_main_version}.tar.gz" ]]; then
            need_download=true
        fi
    else
        warn "无法解析 PostgreSQL ${major} 最新版本，跳过源码包下载（镜像构建仍可走 apt Candidate）"
    fi

    if [[ "$need_download" == "true" ]]; then
        info "下载PostgreSQL相关依赖..."
    else
        info "检查PostgreSQL相关依赖..."
    fi

    if [[ -n "$pg_main_version" ]]; then
        download_file \
            "https://ftp.postgresql.org/pub/source/v${pg_main_version}/postgresql-${pg_main_version}.tar.gz|https://mirrors.aliyun.com/postgresql/source/v${pg_main_version}/postgresql-${pg_main_version}.tar.gz" \
            "$postgres_src_dir/postgresql-${pg_main_version}.tar.gz" \
            "PostgreSQL ${pg_main_version}"
        if declare -F prune_versioned_archives >/dev/null 2>&1; then
            prune_versioned_archives "$postgres_src_dir" "postgresql-${major}." ".tar.gz" "postgresql-${pg_main_version}.tar.gz"
        fi
    fi
}

# ELK相关下载（按 ELK_BUILD_VERSION 取通道最新，同系列只保留一份；缓存于 src/elk）
# 按官方发布的 <url>.sha512 校验已下载文件
# 不匹配：删除文件并返回 1（set -e 下中止，避免使用被篡改/损坏的包）
# 校验和不可获取或缺少 sha512sum：告警后放行，保持离线构建可用
verify_sha512_remote() {
    local file="$1"
    local sum_url="$2"
    local description="${3:-文件}"

    [[ -f "$file" ]] || return 0
    if ! command -v sha512sum >/dev/null 2>&1; then
        warn "未找到 sha512sum，跳过 $description 校验"
        return 0
    fi

    local expected
    expected="$(curl -fsSL --http1.1 --connect-timeout 15 --max-time 60 "$sum_url" 2>/dev/null | awk '{print $1; exit}' || true)"
    if [[ ! "$expected" =~ ^[0-9a-fA-F]{128}$ ]]; then
        warn "无法获取 $description 的 SHA-512 校验和，跳过校验: $sum_url"
        return 0
    fi

    local actual
    actual="$(sha512sum "$file" | awk '{print $1}')"
    if [[ "${actual,,}" != "${expected,,}" ]]; then
        error "$description SHA-512 校验失败，已删除: $(basename "$file")"
        rm -f "$file"
        return 1
    fi
    success "$description SHA-512 校验通过"
}

download_elk_dependencies() {
    local elk_src_dir="$SRC_DIR/elk"
    local series="${ELK_BUILD_VERSION:-9.5}"
    local ver=""
    local tini_ver="${TINI_VERSION:-v0.19.0}"

    ensure_directory "$elk_src_dir"

    if [[ -n "${ELK_VERSION_OVERRIDE:-}" ]]; then
        ver="${ELK_VERSION_OVERRIDE}"
    elif [[ -n "${ELK_VERSION:-}" ]]; then
        ver="${ELK_VERSION}"
    elif declare -F resolve_elk_latest_ver >/dev/null 2>&1; then
        ver="$(resolve_elk_latest_ver "$series" || true)"
    fi
    if [[ -z "$ver" ]] && declare -F resolve_elk_ver_from_local >/dev/null 2>&1; then
        ver="$(resolve_elk_ver_from_local "$series" "$elk_src_dir" || true)"
    fi
    if [[ -z "$ver" ]]; then
        warn "未能解析 ELK ${series} 最新版本，跳过 ELK 依赖下载"
        return 0
    fi
    export ELK_VERSION="$ver"
    export TINI_VERSION="$tini_ver"

    local need_download=false
    if [[ ! -f "$elk_src_dir/elasticsearch-${ver}-linux-x86_64.tar.gz" ]] \
        || [[ ! -f "$elk_src_dir/kibana-${ver}-linux-x86_64.tar.gz" ]] \
        || [[ ! -f "$elk_src_dir/logstash-${ver}-linux-x86_64.tar.gz" ]] \
        || { [[ ! -f "$elk_src_dir/tini-amd64_${tini_ver}" ]] && [[ ! -f "$elk_src_dir/tini" ]]; }; then
        need_download=true
    fi

    if [[ "$need_download" == "true" ]]; then
        info "下载ELK相关依赖（${series} → ${ver}）..."
    else
        info "检查ELK相关依赖（${series} → ${ver}）..."
    fi

    local _comp _pkg _url
    for _comp in elasticsearch kibana logstash; do
        _pkg="${_comp}-${ver}-linux-x86_64.tar.gz"
        _url="https://artifacts.elastic.co/downloads/${_comp}/${_pkg}"
        download_file "$_url" "$elk_src_dir/$_pkg" "${_comp} ${ver}"
        verify_sha512_remote "$elk_src_dir/$_pkg" "${_url}.sha512" "${_comp} ${ver}"
    done

    # 可选插件：与 ELASTICSEARCH_PLUGINS 对齐，预拉到 src/elk 供 Dockerfile 离线安装
    local plugins="${ELASTICSEARCH_PLUGINS:-}"
    if [[ ",${plugins}," == *",analysis-ik,"* ]]; then
        download_file \
            "https://release.infinilabs.com/analysis-ik/stable/elasticsearch-analysis-ik-${ver}.zip" \
            "$elk_src_dir/elasticsearch-analysis-ik-${ver}.zip" \
            "analysis-ik ${ver}"
    fi
    if [[ ",${plugins}," == *",analysis-pinyin,"* ]]; then
        download_file \
            "https://release.infinilabs.com/analysis-pinyin/stable/elasticsearch-analysis-pinyin-${ver}.zip" \
            "$elk_src_dir/elasticsearch-analysis-pinyin-${ver}.zip" \
            "analysis-pinyin ${ver}"
    fi

    # Tini：Dockerfile 引用 tini-amd64_${TINI_VERSION}
    local _tini_found=""
    local _tini_dest="$elk_src_dir/tini-amd64_${tini_ver}"
    if [[ -f "$elk_src_dir/tini-amd64_${tini_ver}" ]]; then
        _tini_found="$elk_src_dir/tini-amd64_${tini_ver}"
    elif [[ -f "$elk_src_dir/tini" ]]; then
        _tini_found="$elk_src_dir/tini"
    fi
    if [[ -n "$_tini_found" ]]; then
        if [[ "$_tini_found" != "$_tini_dest" ]]; then
            cp "$_tini_found" "$_tini_dest"
            chmod +x "$_tini_dest"
        fi
        info "Tini ${tini_ver} 已存在，跳过下载: $(basename "$_tini_found")"
    else
        download_file \
            "https://github.com/krallin/tini/releases/download/${tini_ver}/tini-amd64" \
            "$_tini_dest" \
            "Tini ${tini_ver}"
        [[ -f "$_tini_dest" ]] && chmod +x "$_tini_dest" || true
    fi

    if declare -F prune_elk_src_archives >/dev/null 2>&1; then
        prune_elk_src_archives "$elk_src_dir" "$series" "$ver"
    fi
}

# 根据服务下载依赖
download_service_dependencies() {
    local service="$1"

    case "$service" in
        php85|php84|php83|php82|php81|php80|php74)
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
            download_valkey_dependencies
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
        rabbitmq|canal|canal-server|syncer|monitoring|prometheus|grafana|syncer-prometheus|syncer-grafana|sgr|spug|gitea|rap2-dolores|rap2-delos)
            # RabbitMQ 直接基于官方镜像构建，无需预下载源码依赖。
            if [[ "$RABBITMQ_CANAL_HINT_SHOWN" == "false" ]]; then
                info "Monitoring/RabbitMQ/Canal/SGR 使用官方基础镜像或现有构建链，无需下载额外构建依赖"
                RABBITMQ_CANAL_HINT_SHOWN=true
            fi
            ;;
        openssl)
            download_openssl_dependencies
            ;;
        all)
            # 下载所有依赖
            info "开始下载所有服务的依赖..."
            download_openssl_dependencies
            # 下载所有 PHP 版本的依赖（只下载一次共享依赖）
            if [[ -n "${PHP85_VERSION:-}" ]]; then
                download_php_dependencies "${PHP85_VERSION}"
            fi
            if [[ -n "${PHP84_VERSION:-}" ]]; then
                download_php_dependencies "${PHP84_VERSION}"
            fi
            if [[ -n "${PHP83_VERSION:-}" ]]; then
                download_php_dependencies "${PHP83_VERSION}"
            fi
            if [[ -n "${PHP82_VERSION:-}" ]]; then
                download_php_dependencies "${PHP82_VERSION}"
            fi
            if [[ -n "${PHP81_VERSION:-}" ]]; then
                download_php_dependencies "${PHP81_VERSION}"
            fi
            if [[ -n "${PHP80_VERSION:-}" ]]; then
                download_php_dependencies "${PHP80_VERSION}"
            fi
            if [[ -n "${PHP74_VERSION:-}" ]]; then
                download_php_dependencies "${PHP74_VERSION}"
            fi
            download_nginx_dependencies
            download_redis_dependencies
            download_valkey_dependencies
            download_mysql_dependencies
            download_mongo_dependencies
            download_postgres_dependencies
            download_elk_dependencies
            success "所有依赖下载完成！"
            ;;
        *)
            warn "未知服务: $service"
            ;;
    esac
}

# 主函数
main() {
    # 如果没有指定服务，显示帮助信息
    if [[ $# -eq 0 ]]; then
        echo "使用方法: $0 [服务名...]"
        echo "支持的服务: php85, php84, php83, php82, php81, php80, php74, nginx, tengine, redis, valkey, mysql, mongo, postgres, rabbitmq, canal, syncer, elk, sgr, spug, gitea, rap2-dolores, rap2-delos, openssl, all"
        exit 1
    fi

    log "开始下载依赖软件包..."

    # 加载环境变量；上游版本由各 download_*_dependencies 按需解析（复用 build.sh 已解析结果）
    load_env_files "$@"

    # 确保src目录存在
    ensure_directory "$SRC_DIR"

    # 下载指定服务的依赖
    for service in "$@"; do
        download_service_dependencies "$service"
    done

    success "依赖下载完成！"
}

# 执行主函数
main "$@"
