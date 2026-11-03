#!/bin/sh
# vim:sw=4:ts=4:et

# 根据构建时压缩模块开关，从模板生成压缩配置文件。
# 生成的文件写入 /etc/nginx/conf.d/compression.conf（可写挂载点），
# 主配置 nginx.conf 通过 include 引用。

set -e

ME=$(basename "$0")
TEMPLATE="/etc/nginx/conf/compression.conf.template"
OUTPUT="/etc/nginx/conf.d/compression.conf"

entrypoint_log() {
    if [ -z "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ]; then
        echo "$ME: $*"
    fi
}

if [ ! -f "$TEMPLATE" ]; then
    entrypoint_log "compression template not found ($TEMPLATE), skipping"
    exit 0
fi

# ---------- Brotli 配置块 ----------
if [ "${NGINX_ENABLE_BROTLI:-false}" = "true" ]; then
    BROTLI_BLOCK="##Brotli Compression
brotli on;
brotli_comp_level 6;
brotli_types text/plain text/css application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript application/javascript image/svg+xml;"
    entrypoint_log "Brotli compression: ENABLED"
else
    BROTLI_BLOCK="##Brotli Compression: DISABLED (module not compiled)"
    entrypoint_log "Brotli compression: DISABLED"
fi

# ---------- Zstd 配置块 ----------
if [ "${NGINX_ENABLE_ZSTD:-false}" = "true" ]; then
    ZSTD_BLOCK="##Zstd Compression
zstd on;
zstd_comp_level 3;
zstd_min_length 256;
zstd_types text/plain text/css application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript application/javascript image/svg+xml;"
    entrypoint_log "Zstd compression: ENABLED"
else
    ZSTD_BLOCK="##Zstd Compression: DISABLED (module not compiled)"
    entrypoint_log "Zstd compression: DISABLED"
fi

# ---------- 生成配置 ----------
export NGINX_BROTLI_BLOCK="$BROTLI_BLOCK"
export NGINX_ZSTD_BLOCK="$ZSTD_BLOCK"

envsubst '${NGINX_BROTLI_BLOCK} ${NGINX_ZSTD_BLOCK}' < "$TEMPLATE" > "$OUTPUT"
entrypoint_log "compression config generated -> $OUTPUT"
