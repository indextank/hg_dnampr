#!/bin/sh
# Composer 安装脚本（供所有 PHP 版本镜像构建使用）
#
# 全程用 curl 下载 composer.phar（curl 支持 socks5h/http 代理），
# 避免 php streams / composer-setup.php 在 SOCKS 代理下失败：
#   Failed to open stream: Unable to find the socket transport "socks5h"
#
# 流程：
#   1. curl 下载官方 latest-stable 的 sha256sum
#   2. curl 下载 composer.phar（官方优先；失败回退国内镜像，仍用官方 sha256 校验）
#   3. sha256 完整性校验（本地，不经 PHP 网络）
#   4. 安装到 /usr/local/bin/composer
#   5. 离线验证 --version（清空代理 + COMPOSER_DISABLE_NETWORK，防止 PHP 再走 socks）
#
# 网络抖动防护：所有下载最多重试 5 次，每次重试间隔 3 秒。
set -eu

RETRY_MAX=5
RETRY_DELAY=3
COMPOSER_BIN="/usr/local/bin/composer"
PHAR_PATH="/tmp/composer.phar"
SUM_PATH="/tmp/composer.phar.sha256sum"

log_msg() {
    if [ -n "${COMPOSER_INSTALL_LOG:-}" ]; then
        printf '%s\n' "$1" | tee -a "${COMPOSER_INSTALL_LOG}"
    else
        printf '%s\n' "$1"
    fi
}

# 带重试的下载：最多 RETRY_MAX 次，每次间隔 RETRY_DELAY 秒
download_with_retry() {
    url="$1"
    dest="$2"
    attempt=1
    while [ "${attempt}" -le "${RETRY_MAX}" ]; do
        if curl -fsSL --connect-timeout 10 --max-time 120 "${url}" -o "${dest}"; then
            return 0
        fi
        log_msg "WARN: 下载失败（第 ${attempt}/${RETRY_MAX} 次），${RETRY_DELAY} 秒后重试: ${url}"
        rm -f "${dest}"
        attempt=$((attempt + 1))
        if [ "${attempt}" -le "${RETRY_MAX}" ]; then
            sleep "${RETRY_DELAY}"
        fi
    done
    return 1
}

# PHP streams 不支持 socks5h；验证阶段禁止 Composer/PHP 走代理网络
run_composer_offline() {
    env \
        HTTP_PROXY= \
        HTTPS_PROXY= \
        ALL_PROXY= \
        http_proxy= \
        https_proxy= \
        all_proxy= \
        COMPOSER_DISABLE_NETWORK=1 \
        php "${COMPOSER_BIN}" "$@"
}

rm -f "${PHAR_PATH}" "${SUM_PATH}"

# 1. 下载官方 sha256 校验文件
if ! download_with_retry \
    "https://getcomposer.org/download/latest-stable/composer.phar.sha256sum" \
    "${SUM_PATH}"; then
    log_msg "ERROR: 无法下载 Composer sha256sum。"
    exit 1
fi

# 2. 下载 composer.phar（官方优先；镜像回退）
if download_with_retry \
    "https://getcomposer.org/download/latest-stable/composer.phar" \
    "${PHAR_PATH}"; then
    log_msg "Official Composer phar downloaded."
elif download_with_retry \
    "https://mirrors.tencent.com/composer/composer.phar" \
    "${PHAR_PATH}"; then
    log_msg "WARN: 官方源不可用，已回退至腾讯云镜像（仍执行官方 sha256 校验）。"
elif download_with_retry \
    "https://mirrors.aliyun.com/composer/composer.phar" \
    "${PHAR_PATH}"; then
    log_msg "WARN: 官方/腾讯云不可用，已回退至阿里云镜像（仍执行官方 sha256 校验）。"
else
    log_msg "ERROR: 无法下载 Composer phar。"
    rm -f "${SUM_PATH}"
    exit 1
fi

# 3. sha256 完整性校验（官方 sum 文件格式: "<hash>  composer.phar" 或 "<hash> *composer.phar"）
EXPECTED_CHECKSUM="$(awk 'NF>=1 { print $1; exit }' "${SUM_PATH}" | tr -d '\r\n')"
ACTUAL_CHECKSUM="$(sha256sum "${PHAR_PATH}" | awk '{ print $1 }')"
rm -f "${SUM_PATH}"
if [ -z "${EXPECTED_CHECKSUM}" ] || [ "${#EXPECTED_CHECKSUM}" -ne 64 ] \
    || [ -z "${ACTUAL_CHECKSUM}" ] || [ "${EXPECTED_CHECKSUM}" != "${ACTUAL_CHECKSUM}" ]; then
    log_msg "ERROR: Composer phar corrupt (sha256 校验失败)。"
    log_msg "ERROR: expected=${EXPECTED_CHECKSUM:-<empty>} actual=${ACTUAL_CHECKSUM:-<empty>}"
    rm -f "${PHAR_PATH}"
    exit 1
fi
log_msg "Composer phar verified (sha256)."

# 4. 安装到系统路径
install -m 755 "${PHAR_PATH}" "${COMPOSER_BIN}"
rm -f "${PHAR_PATH}"
if [ ! -f "${COMPOSER_BIN}" ]; then
    log_msg "ERROR: Composer 安装失败（目标文件不存在）。"
    exit 1
fi

# 5. 离线验证：phar 损坏时 php 会抛 PharException；禁用网络避免 socks5h 误触发
if ! run_composer_offline --version; then
    log_msg "ERROR: Composer 安装后验证失败（可能存在签名损坏）。"
    rm -f "${COMPOSER_BIN}"
    exit 1
fi
log_msg "Composer installed successfully."
