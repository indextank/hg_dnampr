#!/bin/bash
# ==========================================
# 上游版本自动解析（按大版本取通道最新）
# ==========================================
# 供 common_functions / download_dependencies 使用：
#   resolve_mysql_latest_ver / resolve_postgres_latest_apt_ver
#   resolve_mongo_latest_ver / resolve_redis_latest_ver / resolve_valkey_latest_ver
#   prune_versioned_archives <dir> <glob_prefix> <ext> <keep_basename>
# ==========================================

# 拉取 URL 文本（失败返回空）；优先 curl，回退 wget
_vr_fetch() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 60 "$url" 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O - --timeout=60 "$url" 2>/dev/null || true
    fi
}

# MySQL apt 组件名：9.7 → mysql-9.7-lts；8.4 → mysql-8.4-lts；8.0 → mysql-8.0
_mysql_apt_component() {
    local series="$1"
    case "$series" in
        9.7) echo "mysql-9.7-lts" ;;
        8.4) echo "mysql-8.4-lts" ;;
        8.0) echo "mysql-8.0" ;;
        *)
            # 启发式：含小数点的创新/LTS 通道优先试 mysql-<series>-lts
            echo "mysql-${series}-lts"
            ;;
    esac
}

# 从 repo.mysql.com Packages 解析 mysql-community-server-core 最新上游版本（去掉 -1debianN）
# 用法: resolve_mysql_latest_ver [8.0|8.4|9.7]
resolve_mysql_latest_ver() {
    local series="${1:-${MYSQL_BUILD_VERSION:-8.4}}"
    local component
    component="$(_mysql_apt_component "$series")"
    local url="https://repo.mysql.com/apt/debian/dists/bookworm/${component}/binary-amd64/Packages"
    local ver=""
    ver="$(_vr_fetch "$url" | awk '
        /^Package: mysql-community-server-core$/ { p=1; next }
        p && /^Version:/ {
            v=$2
            sub(/-1debian[0-9]+$/, "", v)
            print v
            exit
        }
    ')"
    # 8.4 等若 -lts 组件 404，回退 mysql-<series>
    if [[ -z "$ver" && "$component" == *"-lts" ]]; then
        url="https://repo.mysql.com/apt/debian/dists/bookworm/mysql-${series}/binary-amd64/Packages"
        ver="$(_vr_fetch "$url" | awk '
            /^Package: mysql-community-server-core$/ { p=1; next }
            p && /^Version:/ {
                v=$2
                sub(/-1debian[0-9]+$/, "", v)
                print v
                exit
            }
        ')"
    fi
    printf '%s' "$ver"
}

# 从本地 src/mysql 缓存推断系列下最新 tar.gz 版本
resolve_mysql_ver_from_local() {
    local series="${1:-${MYSQL_BUILD_VERSION:-8.4}}"
    local dir="${2:-${_COMMON_FUNCTIONS_PROJECT_DIR:-.}/src/mysql}"
    local f
    f="$(ls -1 "$dir"/mysql-"${series}".*.tar.gz 2>/dev/null | sed 's/.*\///' | sort -V | tail -1 || true)"
    [[ -z "$f" ]] && return 0
    f="${f#mysql-}"
    f="${f%.tar.gz}"
    printf '%s' "$f"
}

# PGDG Packages：postgresql-$major 的 Version（完整 apt 版本）
# 用法: resolve_postgres_latest_apt_ver [19]
resolve_postgres_latest_apt_ver() {
    local major="${1:-${PG_MAJOR:-19}}"
    local urls=(
        "https://apt.postgresql.org/pub/repos/apt/dists/bookworm-pgdg/main/binary-amd64/Packages"
        "https://mirrors.aliyun.com/postgresql/repos/apt/dists/bookworm-pgdg/main/binary-amd64/Packages"
    )
    local url body ver=""
    for url in "${urls[@]}"; do
        body="$(_vr_fetch "$url")"
        [[ -z "$body" ]] && continue
        ver="$(printf '%s\n' "$body" | awk -v maj="$major" '
            $0 == "Package: postgresql-" maj { p=1; next }
            p && /^Version:/ { print $2; exit }
            p && /^$/ { p=0 }
        ')"
        [[ -n "$ver" ]] && break
    done
    printf '%s' "$ver"
}

# apt 版本 → 上游源码版本：18.4-1.pgdg12+1 → 18.4
postgres_upstream_ver() {
    local apt_ver="${1:-}"
    printf '%s' "${apt_ver%%-*}"
}

# 从本地 src/postgres 缓存推断主版本下最新源码包上游版本
resolve_postgres_ver_from_local() {
    local major="${1:-${PG_MAJOR:-19}}"
    local dir="${2:-${_COMMON_FUNCTIONS_PROJECT_DIR:-.}/src/postgres}"
    local f
    f="$(ls -1 "$dir"/postgresql-"${major}".*.tar.gz 2>/dev/null | sed 's/.*\///' | sort -V | tail -1 || true)"
    [[ -z "$f" ]] && return 0
    f="${f#postgresql-}"
    f="${f%.tar.gz}"
    printf '%s' "$f"
}

# -----------------------------------------------------------------------------
# GitHub matching-refs：取 series 下纯数字补丁版本最新 tag（排除 rc/beta）
# 例: _github_latest_semver_tag redis/redis 8.2 → 8.2.11
# -----------------------------------------------------------------------------
_github_latest_semver_tag() {
    local repo="$1"   # owner/name
    local series="$2" # 8.2
    local url="https://api.github.com/repos/${repo}/git/matching-refs/tags/${series}."
    local body
    body="$(_vr_fetch "$url")"
    [[ -z "$body" ]] && return 0
    printf '%s' "$body" | grep -oE '"ref":[[:space:]]*"refs/tags/'"${series}"'\.[0-9]+"' \
        | sed -E 's/.*"refs\/tags\/([^"]+)".*/\1/' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1
}

# Redis：GitHub tags → download.redis.io 目录列表 → 本地缓存
# 用法: resolve_redis_latest_ver [8.2]
resolve_redis_latest_ver() {
    local series="${1:-${REDIS_BUILD_VERSION:-8.10}}"
    local ver=""
    ver="$(_github_latest_semver_tag "redis/redis" "$series")"
    if [[ -z "$ver" ]]; then
        ver="$(_vr_fetch "https://download.redis.io/releases/" \
            | grep -oE "redis-${series}\\.[0-9]+\\.tar\\.gz" \
            | sed "s/redis-//;s/\\.tar\\.gz//" \
            | sort -V | tail -1 || true)"
    fi
    printf '%s' "$ver"
}

resolve_redis_ver_from_local() {
    local series="${1:-${REDIS_BUILD_VERSION:-8.10}}"
    local dir="${2:-${_COMMON_FUNCTIONS_PROJECT_DIR:-.}/src/redis}"
    local f
    f="$(ls -1 "$dir"/redis-"${series}".*.tar.gz 2>/dev/null | sed 's/.*\///' | sort -V | tail -1 || true)"
    [[ -z "$f" ]] && return 0
    f="${f#redis-}"
    f="${f%.tar.gz}"
    printf '%s' "$f"
}

# Valkey：GitHub tags → download.valkey.io → 本地 src/valkey
# 用法: resolve_valkey_latest_ver [8.1]
resolve_valkey_latest_ver() {
    local series="${1:-${VALKEY_BUILD_VERSION:-8.1}}"
    local ver=""
    ver="$(_github_latest_semver_tag "valkey-io/valkey" "$series")"
    if [[ -z "$ver" ]]; then
        ver="$(_vr_fetch "https://download.valkey.io/releases/" \
            | grep -oE "valkey-${series}\\.[0-9]+\\.tar\\.gz" \
            | sed "s/valkey-//;s/\\.tar\\.gz//" \
            | sort -V | tail -1 || true)"
    fi
    printf '%s' "$ver"
}

resolve_valkey_ver_from_local() {
    local series="${1:-${VALKEY_BUILD_VERSION:-8.1}}"
    local dir="${2:-${_COMMON_FUNCTIONS_PROJECT_DIR:-.}/src/valkey}"
    local f
    f="$(ls -1 "$dir"/valkey-"${series}".*.tar.gz 2>/dev/null | sed 's/.*\///' | sort -V | tail -1 || true)"
    [[ -z "$f" ]] && return 0
    f="${f#valkey-}"
    f="${f%.tar.gz}"
    printf '%s' "$f"
}

# Docker Hub library/elasticsearch：取 series 下纯数字补丁版本最新 tag
_elk_dockerhub_latest_ver() {
    local series="$1"
    local body
    # name= 过滤含 series 的 tag；再本地筛 series.N
    body="$(_vr_fetch "https://hub.docker.com/v2/repositories/library/elasticsearch/tags?page_size=100&ordering=-last_updated&name=${series}")"
    [[ -z "$body" ]] && return 0
    printf '%s' "$body" | grep -oE '"name":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' \
        | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' \
        | grep -E "^${series}\\.[0-9]+$" \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1
}

# ELK：Docker Hub tags → GitHub v* tags → 本地 src/elk 缓存
# 用法: resolve_elk_latest_ver [8.19|9.4|9.5]
# 说明：elastic/elasticsearch 上游 tag 形如 v9.5.5；优先 Docker Hub official
resolve_elk_latest_ver() {
    local series="${1:-${ELK_BUILD_VERSION:-9.5}}"
    local ver="" body
    ver="$(_elk_dockerhub_latest_ver "$series")"
    if [[ -z "$ver" ]]; then
        body="$(_vr_fetch "https://api.github.com/repos/elastic/elasticsearch/git/matching-refs/tags/v${series}.")"
        if [[ -n "$body" ]]; then
            ver="$(printf '%s' "$body" | grep -oE '"ref":[[:space:]]*"refs/tags/v?'"${series}"'\.[0-9]+"' \
                | sed -E 's/.*"refs\/tags\/v?([^"]+)".*/\1/' \
                | sort -t. -k1,1n -k2,2n -k3,3n \
                | tail -1)"
        fi
    fi
    printf '%s' "$ver"
}

# 从本地 src/elk 缓存推断系列下最新 elasticsearch tar.gz 版本
resolve_elk_ver_from_local() {
    local series="${1:-${ELK_BUILD_VERSION:-9.5}}"
    local dir="${2:-${_COMMON_FUNCTIONS_PROJECT_DIR:-.}/src/elk}"
    local f
    f="$(ls -1 "$dir"/elasticsearch-"${series}".*-linux-x86_64.tar.gz 2>/dev/null | sed 's/.*\///' | sort -V | tail -1 || true)"
    [[ -z "$f" ]] && return 0
    f="${f#elasticsearch-}"
    f="${f%-linux-x86_64.tar.gz}"
    printf '%s' "$f"
}

# 同系列 ELK 安装包/插件只保留 keep_ver 对应的一份
# 用法: prune_elk_src_archives <dir> <series> <keep_ver>
prune_elk_src_archives() {
    local dir="$1"
    local series="$2"
    local keep_ver="$3"
    [[ -d "$dir" && -n "$series" && -n "$keep_ver" ]] || return 0
    prune_versioned_archives "$dir" "elasticsearch-${series}." "-linux-x86_64.tar.gz" \
        "elasticsearch-${keep_ver}-linux-x86_64.tar.gz"
    prune_versioned_archives "$dir" "kibana-${series}." "-linux-x86_64.tar.gz" \
        "kibana-${keep_ver}-linux-x86_64.tar.gz"
    prune_versioned_archives "$dir" "logstash-${series}." "-linux-x86_64.tar.gz" \
        "logstash-${keep_ver}-linux-x86_64.tar.gz"
    prune_versioned_archives "$dir" "elasticsearch-analysis-ik-${series}." ".zip" \
        "elasticsearch-analysis-ik-${keep_ver}.zip"
    prune_versioned_archives "$dir" "elasticsearch-analysis-pinyin-${series}." ".zip" \
        "elasticsearch-analysis-pinyin-${keep_ver}.zip"
}

# MongoDB：按 MONGO_BUILD_VERSION 从官方 apt Packages 取 mongodb-org-server 最新版
# 8.2 → Ubuntu noble multiverse；8.0 → Debian bookworm main
# 用法: resolve_mongo_latest_ver [8.2|8.0]
resolve_mongo_latest_ver() {
    local series="${1:-${MONGO_BUILD_VERSION:-8.2}}"
    local urls=()
    case "$series" in
        8.2|9.*|8.[3-9]*)
            urls=(
                "https://repo.mongodb.org/apt/ubuntu/dists/noble/mongodb-org/${series}/multiverse/binary-amd64/Packages"
            )
            ;;
        8.0|7.*|*)
            urls=(
                "https://repo.mongodb.org/apt/debian/dists/bookworm/mongodb-org/${series}/main/binary-amd64/Packages"
                "https://mirrors.tuna.tsinghua.edu.cn/mongodb/apt/debian/dists/bookworm/mongodb-org/${series}/main/binary-amd64/Packages"
            )
            ;;
    esac
    local url body ver=""
    for url in "${urls[@]}"; do
        body="$(_vr_fetch "$url")"
        [[ -z "$body" ]] && continue
        ver="$(printf '%s\n' "$body" | awk '
            /^Package: mongodb-org-server$/ { p=1; next }
            p && /^Version:/ { print $2; exit }
            p && /^$/ { p=0 }
        ')"
        [[ -n "$ver" ]] && break
    done
    printf '%s' "$ver"
}

resolve_mongo_ver_from_local() {
    local series="${1:-${MONGO_BUILD_VERSION:-8.2}}"
    local dir="${2:-${_COMMON_FUNCTIONS_PROJECT_DIR:-.}/src/mongo}"
    local f
    f="$(ls -1 "$dir"/mongo-"${series}".*.tar.gz 2>/dev/null | sed 's/.*\///' | sort -V | tail -1 || true)"
    [[ -z "$f" ]] && return 0
    f="${f#mongo-}"
    f="${f%.tar.gz}"
    printf '%s' "$f"
}

# 同系列只保留一份归档：删除 dir 下匹配 prefix*.ext 且不等于 keep_basename 的文件
# 例: prune_versioned_archives src/mysql 'mysql-8.4.' '.tar.gz' 'mysql-8.4.13.tar.gz'
# 使用 find 而非裸 glob，避免 Windows/WSL 下 pathname 展开与 nullglob 差异漏删。
prune_versioned_archives() {
    local dir="$1"
    local prefix="$2"   # 如 mysql-8.4. 或 redis-8.2.
    local ext="$3"      # 如 .tar.gz
    local keep="$4"     # 保留的完整文件名
    [[ -d "$dir" ]] || return 0
    local f base
    # -name 'redis-8.2.*.tar.gz'：同系列多补丁版本只留 keep
    while IFS= read -r -d '' f; do
        base="$(basename "$f")"
        if [[ "$base" != "$keep" ]]; then
            if declare -F info >/dev/null 2>&1; then
                info "清理旧源码包: $base（保留 $keep）"
            else
                echo "清理旧源码包: $base（保留 $keep）"
            fi
            rm -f "$f"
        fi
    done < <(find "$dir" -maxdepth 1 -type f -name "${prefix}*${ext}" -print0 2>/dev/null)
}

# 清理错放到错误目录的产品归档（如 src/redis 下的 valkey-*.tar.gz）
# 用法: purge_foreign_product_archives <dir> <foreign_product>
# 例: purge_foreign_product_archives src/redis valkey
purge_foreign_product_archives() {
    local dir="$1"
    local foreign="$2"  # redis | valkey | ...
    [[ -d "$dir" ]] || return 0
    local f base
    while IFS= read -r -d '' f; do
        base="$(basename "$f")"
        if declare -F info >/dev/null 2>&1; then
            info "移除错位源码包: ${dir%/}/$base（不属于 $(basename "$dir")）"
        else
            echo "移除错位源码包: ${dir%/}/$base"
        fi
        rm -f "$f"
    done < <(find "$dir" -maxdepth 1 -type f -name "${foreign}-*.tar.gz" -print0 2>/dev/null)
}

# Redis/Valkey 源码目录规范化：
#   1) 删除错位产品包（redis 目录不得有 valkey-*，反之亦然）
#   2) 同系列（如 8.2.x）只保留 keep_ver 对应的一份
# 用法: normalize_kv_src_archives <dir> <product> <series> <keep_ver>
# 例: normalize_kv_src_archives src/redis redis 8.2 8.2.11
normalize_kv_src_archives() {
    local dir="$1"
    local product="$2"    # redis | valkey
    local series="$3"     # 8.2
    local keep_ver="$4"   # 8.2.11
    local keep="${product}-${keep_ver}.tar.gz"
    local foreign=""

    case "$product" in
        redis) foreign=valkey ;;
        valkey) foreign=redis ;;
        *) foreign="" ;;
    esac

    [[ -d "$dir" ]] || return 0
    [[ -n "$foreign" ]] && purge_foreign_product_archives "$dir" "$foreign"
    if [[ -n "$series" && -n "$keep_ver" ]]; then
        prune_versioned_archives "$dir" "${product}-${series}." ".tar.gz" "$keep"
    fi
}
