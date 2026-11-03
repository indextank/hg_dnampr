#!/bin/sh
# Composer 官方安装脚本（供所有 PHP 版本镜像构建使用）
#
# 流程（与 Composer 官方文档推荐流程一致）：
#   1. 下载官方安装器签名（installer.sig，sha384，随安装器版本动态变化，必须实时获取）
#   2. 下载官方安装器 composer-setup.php（等效于 php -r "copy('https://getcomposer.org/installer', ...)")
#   3. sha384 完整性校验（等效于 php -r "if (hash_file('sha384', ...) === ...) ..."）
#   4. 执行安装：php composer-setup.php --install-dir=/usr/local/bin --filename=composer
#   5. 清理安装器，并对安装结果做最终验证（phar 签名损坏时直接失败，中断构建）
#
# 网络抖动防护：所有下载最多重试 5 次，每次重试间隔 3 秒。
set -eu

RETRY_MAX=5
RETRY_DELAY=3

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

INSTALLER_SIG_PATH="/tmp/composer-installer.sig"
INSTALLER_PATH="/tmp/composer-setup.php"

rm -f "${INSTALLER_SIG_PATH}" "${INSTALLER_PATH}"

# 1. 下载官方安装器签名（sha384 校验依据）
if ! download_with_retry "https://composer.github.io/installer.sig" "${INSTALLER_SIG_PATH}"; then
    log_msg "ERROR: 无法下载 Composer 安装器签名文件。"
    exit 1
fi

# 2. 下载官方安装器（优先官方源；失败时回退腾讯云镜像，但仍使用官方签名校验完整性）
if download_with_retry "https://getcomposer.org/installer" "${INSTALLER_PATH}"; then
    log_msg "Official Composer installer downloaded."
elif download_with_retry "https://mirrors.tencent.com/composer/composer-setup.php" "${INSTALLER_PATH}"; then
    log_msg "WARN: 官方源不可用，已回退至腾讯云镜像（仍执行官方 sha384 签名校验）。"
else
    log_msg "ERROR: 无法下载 Composer 安装器。"
    exit 1
fi

# 3. sha384 完整性校验
EXPECTED_CHECKSUM="$(tr -d '\r\n' < "${INSTALLER_SIG_PATH}")"
ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', '${INSTALLER_PATH}');")"
rm -f "${INSTALLER_SIG_PATH}"
if [ -z "${EXPECTED_CHECKSUM}" ] || [ "${#EXPECTED_CHECKSUM}" -ne 96 ] || [ "${EXPECTED_CHECKSUM}" != "${ACTUAL_CHECKSUM}" ]; then
    log_msg "ERROR: Installer corrupt (sha384 校验失败)。"
    rm -f "${INSTALLER_PATH}"
    exit 1
fi
log_msg "Installer verified."

# 4. 执行官方安装器，安装到系统路径
php "${INSTALLER_PATH}" --install-dir=/usr/local/bin --filename=composer
RESULT=$?
rm -f "${INSTALLER_PATH}"
if [ "${RESULT}" -ne 0 ] || [ ! -f /usr/local/bin/composer ]; then
    log_msg "ERROR: Composer 安装失败。"
    exit 1
fi
chmod +x /usr/local/bin/composer

# 5. 最终验证：phar 文件不完整/签名损坏时该命令会抛 PharException 失败，直接中断构建，
#    避免带有 broken signature 的 composer 进入镜像
if ! php /usr/local/bin/composer --version; then
    log_msg "ERROR: Composer 安装后验证失败（可能存在签名损坏）。"
    rm -f /usr/local/bin/composer
    exit 1
fi
log_msg "Composer installed successfully."
