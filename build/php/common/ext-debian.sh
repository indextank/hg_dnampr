#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

export MC="-j$(nproc)"

DOWNLOAD_HELPER="${DOWNLOAD_HELPER:-/tmp/download-helper.sh}"
if [ ! -r "${DOWNLOAD_HELPER}" ]; then
    echo "ERROR: 下载校验助手不存在: ${DOWNLOAD_HELPER}"
    exit 1
fi
# shellcheck source=/dev/null
. "${DOWNLOAD_HELPER}"

echo
echo "============================================"
echo "Install extensions from   : ext-debian.sh"
echo "PHP version               : ${PHP_VERSION}"
echo "Extra Extensions          : ${PHP_EXTENSIONS}"
echo "Multicore Compilation     : ${MC}"
echo "Work directory            : ${PWD}"
echo "============================================"
echo

php_detail_version=$(/usr/local/bin/php-config --version)
php_main_version=${php_detail_version%.*}

if [[ "${php_main_version}" == "8.6" ]]; then
    for unsupported_extension in swoole xdebug yaml imagick; do
        if [ -z "${EXTENSIONS##*,${unsupported_extension},*}" ]; then
            echo "ERROR: PHP 8.6 暂不允许安装 ${unsupported_extension}；请从 PHP86_EXTENSIONS 中排除该扩展"
            exit 1
        fi
    done
fi

if [ "${PHP_EXTENSIONS}" != "" ]; then
    echo "---------- Install general dependencies ----------"
    apt-get update
    apt-get install -y --assume-yes --no-install-recommends apt-transport-https ca-certificates

    # 软件源由 Dockerfile 的 CHANGE_SOURCE/FALLBACK_MIRROR 统一决定。
    # 此处禁止无条件改写，避免绕过用户选择或破坏 debian.sources。
    apt-get update
    apt-get install -y --assume-yes lsof pkg-config apt-utils wget gcc g++ make cmake unzip autoconf automake libtool libssl-dev libpq-dev libedit-dev libzip-dev libicu-dev libxslt-dev binutils libyaml-dev libc-ares-dev libcurl4-openssl-dev libbrotli-dev
    rm -rf /var/lib/apt/lists/*
fi

if [ -z "${EXTENSIONS##*,opcache,*}" ]; then
    echo "---------- Install opcache ----------"
    docker-php-ext-install opcache
fi

if [ -z "${EXTENSIONS##*,yaf,*}" ]; then
    echo "---------- Install yaf ----------"
    if [ -z "${YAF_EXT_VERSION:-}" ]; then
        echo "ERROR: YAF_EXT_VERSION 为空，无法可信校验 PECL 包"
        exit 1
    fi
    download_pecl_package_verified "yaf" "${YAF_EXT_VERSION}" "yaf-${YAF_EXT_VERSION}.tgz" || exit 1
    printf "\n" | pecl install "./yaf-${YAF_EXT_VERSION}.tgz"
    docker-php-ext-enable yaf
fi

if [ -z "${EXTENSIONS##*,memcached,*}" ]; then
    echo "---------- Install memcached extension ----------"
    apt-get update && apt-get install -y libmemcached-dev zlib1g-dev && \
    download_pecl_package_verified "memcached" "3.2.0" "memcached-3.2.0.tgz" && \
    printf "\n" | pecl install "./memcached-3.2.0.tgz" && \
    docker-php-ext-enable memcached
fi

if [ -z "${EXTENSIONS##*,swoole,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install swoole extension ----------"

    if [[ "${php_main_version}" =~ ^7\.4$ ]]; then
        download_pecl_package_verified "swoole" "4.8.13" "swoole-4.8.13.tgz" || exit 1
        if [ -f swoole-4.8.13.tgz ]; then
            mkdir swoole \
                && tar -xf swoole-4.8.13.tgz -C swoole --strip-components=1 \
                && cd swoole \
                && phpize \
                && ./configure --enable-openssl --with-openssl-dir=/usr/local/openssl \
                && make ${MC} \
                && make install \
                && cd .. \
                && rm -fr swoole \
                && docker-php-ext-enable swoole
        fi
    else
        # PHP 8.x：按次要版本钳制 Swoole，避免 compose 传错版本时编译直接炸掉。
        _swoole_ver="${SWOOLE_EXT_VERSION:-}"
        case "${php_main_version}" in
            8.0) _swoole_ver="${SWOOLE7_EXT_VERSION:-5.1.3}" ;;
            8.1) _swoole_ver="${SWOOLE60_EXT_VERSION:-6.0.2}" ;;
        esac
        # -n 判断SWOOLE_EXT_VERSION不为空
        if [ -n "${_swoole_ver}" ]; then
            _SWOOLE_INSTALLED=false
            download_pecl_package_verified "swoole" "${_swoole_ver}" "swoole-${_swoole_ver}.tgz" || exit 1

            # 验证下载的文件是否为有效的 tar 归档（PECL 对不存在的版本返回 HTML 错误页）
            if [ -f "swoole-${_swoole_ver}.tgz" ] && tar -tf "swoole-${_swoole_ver}.tgz" >/dev/null 2>&1; then
                mkdir swoole \
                    && tar -xf "swoole-${_swoole_ver}.tgz" -C swoole --strip-components=1 \
                    && cd swoole \
                    && phpize \
                    && ./configure --enable-sockets --enable-brotli --enable-cares --enable-swoole-curl --with-openssl-dir=/usr/local/openssl \
                    && make ${MC} \
                    && make install \
                    && cd .. \
                    && rm -fr swoole \
                    && docker-php-ext-enable swoole \
                    && _SWOOLE_INSTALLED=true
            else
                echo "ERROR: swoole-${_swoole_ver}.tgz 无效或不存在，拒绝未验证的回退下载"
                rm -f "swoole-${_swoole_ver}.tgz"
                exit 1
            fi

            if [ "$_SWOOLE_INSTALLED" = false ]; then
                echo "ERROR: swoole-${_swoole_ver} 未安装，拒绝未验证的回退下载"
                exit 1
            fi
        else
            echo "ERROR: SWOOLE_EXT_VERSION 为空，无法可信校验 PECL 包"
            exit 1
        fi
    fi

    if [ -f "/usr/local/etc/php/conf.d/docker-php-ext-swoole.ini" ]; then
        echo "swoole.use_shortname='Off'" >> /usr/local/etc/php/conf.d/docker-php-ext-swoole.ini
    fi
    # if [ $(grep "vernum=" /usr/local/bin/php-config | awk -F ' ' '{print $1}' | cut -b 9-13) -gt 80000 ]; then
    # fi
fi

if [ -z "${EXTENSIONS##*,yaml,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install yaml extension ----------"

    # 7.0+
    # 8.[0-9]：覆盖 8.5 及后续 8.x；原写法只到 8.4，导致 8.5 静默跳过 yaml
    if [[ "${php_main_version}" =~ ^7.[4]$|8.[0-9]$ ]]; then
        if [ -n "${YAML_EXT_VERSION}" ]; then
            download_pecl_package_verified "yaml" "${YAML_EXT_VERSION}" "yaml-${YAML_EXT_VERSION}.tgz" || exit 1
            if [ -f yaml-${YAML_EXT_VERSION}.tgz ]; then
                mkdir yaml \
                    && tar -xf yaml-${YAML_EXT_VERSION}.tgz -C yaml --strip-components=1 \
                    && ( cd yaml && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr yaml ) \
                    && docker-php-ext-enable yaml
            else
                echo "ERROR: yaml-${YAML_EXT_VERSION}.tgz 缺失，拒绝未验证的回退下载"
                exit 1
            fi
        else
            echo "ERROR: YAML_EXT_VERSION 为空，无法可信校验 PECL 包"
            exit 1
        fi
    fi
fi


if [ -z "${EXTENSIONS##*,redis,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install redis extension ----------"

    _redis_ver="${REDIS_EXT_VERSION:-}"
    # phpredis 6.1+ 要求 PHP >= 8.1；7.4/8.0 固定到仍兼容的 6.0.2。
    case "${php_main_version}" in
        7.4|8.0) _redis_ver="6.0.2" ;;
    esac
    if [ -n "${_redis_ver}" ]; then
        download_pecl_package_verified "redis" "${_redis_ver}" "redis-${_redis_ver}.tgz" || exit 1
        if [ -f "redis-${_redis_ver}.tgz" ]; then
            mkdir redis \
                && tar -xf "redis-${_redis_ver}.tgz" -C redis --strip-components=1 \
                && ( cd redis && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr redis ) \
                && docker-php-ext-enable redis
        else
            echo "ERROR: redis-${_redis_ver}.tgz 缺失，拒绝未验证的回退下载"
            exit 1
        fi
    else
        echo "ERROR: REDIS_EXT_VERSION 为空，无法可信校验 PECL 包"
        exit 1
    fi
fi


if [ -z "${EXTENSIONS##*,xdebug,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install xdebug extension ----------"

    if [[ "${php_main_version}" =~ ^7.[4]$ ]]; then
        download_pecl_package_verified "xdebug" "3.1.6" "xdebug-3.1.6.tgz" || exit 1
        if [ -f xdebug-3.1.6.tgz ]; then
            mkdir xdebug \
                && tar -xf xdebug-3.1.6.tgz -C xdebug --strip-components=1 \
                && ( cd xdebug && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr xdebug) \
                && docker-php-ext-enable xdebug
        fi
    else
        if [ -n "${XDEBUG_EXT_VERSION}" ]; then
            download_pecl_package_verified "xdebug" "${XDEBUG_EXT_VERSION}" "xdebug-${XDEBUG_EXT_VERSION}.tgz" || exit 1

            if [ -f xdebug-${XDEBUG_EXT_VERSION}.tgz ]; then
                mkdir xdebug \
                    && tar -xf xdebug-${XDEBUG_EXT_VERSION}.tgz -C xdebug --strip-components=1 \
                    && ( cd xdebug && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr xdebug) \
                    && docker-php-ext-enable xdebug
            else
                echo "ERROR: xdebug-${XDEBUG_EXT_VERSION}.tgz 缺失，拒绝未验证的回退下载"
                exit 1
            fi
        else
            echo "ERROR: XDEBUG_EXT_VERSION 为空，无法可信校验 PECL 包"
            exit 1
        fi
    fi

#     if [ -f "/usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini" ]; then
#         cat >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini << EOF
# [xdebug]
# zend_extension=xdebug.so
# xdebug.trace_output_dir=/tmp/xdebug
# xdebug.profiler_output_dir = /tmp/xdebug
# xdebug.profiler_enable = On
# xdebug.profiler_enable_trigger = 1
# EOF
#     fi
fi


if [ -z "${EXTENSIONS##*,imagick,*}" ]; then

    cd "${TMP_DIR}"

    if [ ! -d "/usr/local/imagemagick" ]; then
        echo "---------- Install ImageMagick ----------"

        download_and_verify_sha256 \
            "https://codeload.github.com/ImageMagick/ImageMagick/tar.gz/refs/tags/${IMAGICK_VERSION}" \
            "ImageMagick-${IMAGICK_VERSION}.tar.gz" "${IMAGICK_SOURCE_SHA256:-}" || exit 1
        tar xzf ImageMagick-${IMAGICK_VERSION}.tar.gz
        cd ImageMagick-${IMAGICK_VERSION} > /dev/null
        ./configure --prefix=/usr/local/imagemagick --enable-shared --enable-static
        make ${MC} && make install
        ldconfig /usr/local/lib
        cd "${TMP_DIR}"
        rm -rf ImageMagick-${IMAGICK_VERSION}
    fi

    cd "${TMP_DIR}"
    echo "---------- Install imagick extension ----------"

    if [ -n "${IMAGICK_EXT_VERSION}" ]; then
        download_pecl_package_verified "imagick" "${IMAGICK_EXT_VERSION}" "imagick-${IMAGICK_EXT_VERSION}.tgz" || exit 1
        if [ -f imagick-${IMAGICK_EXT_VERSION}.tgz ]; then
            mkdir imagick \
                && tar -xf imagick-${IMAGICK_EXT_VERSION}.tgz -C imagick --strip-components=1 \
                && ( cd imagick && phpize && ./configure --with-imagick=/usr/local/imagemagick/ && make ${MC} && make install && cd .. && rm -fr imagick ) \
                && docker-php-ext-enable imagick
        else
            echo "ERROR: imagick-${IMAGICK_EXT_VERSION}.tgz 缺失，拒绝未验证的回退下载"
            exit 1
        fi
    else
        echo "ERROR: IMAGICK_EXT_VERSION 为空，无法可信校验 PECL 包"
        exit 1
    fi
fi


if [ -z "${EXTENSIONS##*,mongodb,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install mongodb extension ----------"
    echo "PHP main version: ${php_main_version}"
    echo "MongoDB extension version: ${MONGODB_EXT_VERSION:-auto-detect}"

    apt-get update
    apt-get install -y unixodbc-dev libssl-dev pkg-config

    # 根据 PHP 版本自动选择合适的 MongoDB 扩展版本
    SELECTED_MONGODB_VERSION=""

    if [[ "${php_main_version}" =~ ^7.[4]$|^8.[0]$ ]]; then
        # PHP 7.4 和 8.0: MongoDB 1.20.0
        echo "PHP 7.4/8.0 detected, using MongoDB extension 1.20.0"
        SELECTED_MONGODB_VERSION="1.20.0"

    elif [[ "${php_main_version}" =~ ^8.[1-9]$ ]]; then
        # PHP 8.1+: MongoDB 2.0.0+
        echo "PHP 8.1+ detected, using latest MongoDB extension"
        if [ -n "${MONGODB_EXT_VERSION}" ]; then
            # 验证指定版本是否兼容
            if [[ "${MONGODB_EXT_VERSION}" =~ ^2\. ]]; then
                echo "Using specified MongoDB extension version: ${MONGODB_EXT_VERSION}"
                SELECTED_MONGODB_VERSION="${MONGODB_EXT_VERSION}"
            else
                echo "Warning: MongoDB extension ${MONGODB_EXT_VERSION} may not be compatible with PHP ${php_main_version}"
                echo "Using MongoDB extension 2.0.0 for PHP 8.1+ compatibility"
                SELECTED_MONGODB_VERSION="2.0.0"
            fi
        else
            SELECTED_MONGODB_VERSION="2.0.0"
        fi

    else
        # 未知版本，尝试使用默认版本
        echo "Unknown PHP version ${php_main_version}, attempting to use default MongoDB extension"
        if [ -n "${MONGODB_EXT_VERSION}" ]; then
            SELECTED_MONGODB_VERSION="${MONGODB_EXT_VERSION}"
        else
            echo "ERROR: MONGODB_EXT_VERSION 为空，无法可信校验 PECL 包"
            exit 1
        fi
    fi

    # 下载并安装选定版本的 MongoDB 扩展
    if [ -n "${SELECTED_MONGODB_VERSION}" ]; then
        echo "Installing MongoDB extension version: ${SELECTED_MONGODB_VERSION}"

        echo "Downloading MongoDB extension ${SELECTED_MONGODB_VERSION}..."
        download_pecl_package_verified "mongodb" "${SELECTED_MONGODB_VERSION}" \
            "mongodb-${SELECTED_MONGODB_VERSION}.tgz" || exit 1

        if [ -f mongodb-${SELECTED_MONGODB_VERSION}.tgz ]; then
            mv mongodb-${SELECTED_MONGODB_VERSION}.tgz mongodb.tgz
        else
            echo "ERROR: mongodb-${SELECTED_MONGODB_VERSION}.tgz 缺失，拒绝未验证的回退下载"
            exit 1
        fi
    fi

    # 编译和安装从源码下载的扩展
    if [ -f mongodb.tgz ]; then
        echo "---------- Compiling MongoDB extension from source ----------"

        if mkdir mongodb && tar -xf mongodb.tgz -C mongodb --strip-components=1; then
            echo "MongoDB extension extracted successfully"
            cd mongodb

            if phpize; then
                echo "phpize completed successfully"

                echo "Running configure..."
                if ./configure --with-php-config=/usr/local/bin/php-config; then
                    echo "Configure completed successfully"

                    if make ${MC}; then
                        echo "Make completed successfully"

                        if make install; then
                            echo "Make install completed successfully"
                            cd ..
                            rm -fr mongodb

                            echo "Enabling MongoDB extension..."
                            if docker-php-ext-enable mongodb; then
                                echo "MongoDB extension installed and enabled successfully"

                                # 验证安装
                                if php -m | grep -q mongodb; then
                                    echo "✅ MongoDB extension verification: SUCCESS"
                                else
                                    echo "❌ MongoDB extension verification: FAILED"
                                fi
                            else
                                echo "ERROR: Failed to enable MongoDB extension"
                            fi
                        else
                            echo "ERROR: Make install failed"
                            cd ..
                        fi
                    else
                        echo "ERROR: Make compilation failed"
                        cd ..
                    fi
                else
                    echo "ERROR: Configure failed"
                    cd ..
                fi
            else
                echo "ERROR: phpize failed"
                cd ..
            fi
        else
            echo "ERROR: Failed to extract MongoDB extension"
        fi
    fi
fi


if [ -z "${EXTENSIONS##*,grpc,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install grpc extension ----------"
    apt-get update && apt-get install -y zlib1g-dev

    if [ -n "${GRPC_EXT_VERSION}" ]; then
        download_pecl_package_verified "grpc" "${GRPC_EXT_VERSION}" "grpc-${GRPC_EXT_VERSION}.tgz" || exit 1
        if [ -f grpc-${GRPC_EXT_VERSION}.tgz ]; then
            mkdir grpc \
                && tar -xf grpc-${GRPC_EXT_VERSION}.tgz -C grpc --strip-components=1 \
                && ( cd grpc && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr grpc ) \
                && docker-php-ext-enable grpc
        else
            echo "ERROR: grpc-${GRPC_EXT_VERSION}.tgz 缺失，拒绝未验证的回退下载"
            exit 1
        fi
    else
        echo "ERROR: GRPC_EXT_VERSION 为空，无法可信校验 PECL 包"
        exit 1
    fi

    if [ -f "/usr/local/etc/php/conf.d/docker-php-ext-grpc.ini" ]; then
        echo "grpc.enable_fork_support = 1" >> /usr/local/etc/php/conf.d/docker-php-ext-grpc.ini
    fi
fi


if [ -z "${EXTENSIONS##*,protobuf,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install protobuf ----------"

    case "$(uname -m)" in
        x86_64|amd64) PROTOC_ARCH="x86_64" ;;
        aarch64|arm64) PROTOC_ARCH="aarch_64" ;;
        *)
            echo "ERROR: protoc 不支持当前架构: $(uname -m)"
            exit 1
            ;;
    esac
    PROTOC_ARCHIVE="protoc-${PROTOBUF_VERSION}-linux-${PROTOC_ARCH}.zip"
    download_and_verify_sha256 \
        "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/${PROTOC_ARCHIVE}" \
        "${PROTOC_ARCHIVE}" "${PROTOC_SHA256:-}" || exit 1

    if [ -f "${PROTOC_ARCHIVE}" ]; then
        unzip "${PROTOC_ARCHIVE}"
        cp bin/protoc /usr/local/bin/
        rm -fr bin include readme.txt
    fi

    cd "${TMP_DIR}"
    if [ -f "/usr/local/bin/protoc" ];then
        echo "---------- Install protobuf extension ----------"

        if [ -n "${PROTOBUF_EXT_VERSION}" ]; then
            download_pecl_package_verified "protobuf" "${PROTOBUF_EXT_VERSION}" "protobuf-${PROTOBUF_EXT_VERSION}.tgz" || exit 1
            if [ -f protobuf-${PROTOBUF_EXT_VERSION}.tgz ]; then
                mkdir protobuf \
                    && tar -xf protobuf-${PROTOBUF_EXT_VERSION}.tgz -C protobuf --strip-components=1 \
                    && ( cd protobuf && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr protobuf ) \
                    && docker-php-ext-enable protobuf
            else
                echo "ERROR: protobuf-${PROTOBUF_EXT_VERSION}.tgz 缺失，拒绝未验证的回退下载"
                exit 1
            fi
        else
            echo "ERROR: PROTOBUF_EXT_VERSION 为空，无法可信校验 PECL 包"
            exit 1
        fi
    fi
fi

if [ -z "${EXTENSIONS##*,rdkafka,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install librdkafka ----------"

    download_and_verify_sha256 \
        "https://codeload.github.com/confluentinc/librdkafka/tar.gz/refs/tags/v${LIBRDKAFKA_VERSION}" \
        "librdkafka-${LIBRDKAFKA_VERSION}.tar.gz" "${LIBRDKAFKA_SHA256:-}" || exit 1

    if [ -f librdkafka-${LIBRDKAFKA_VERSION}.tar.gz ]; then
        mkdir librdkafka \
            && tar -xf librdkafka-${LIBRDKAFKA_VERSION}.tar.gz -C librdkafka --strip-components=1 \
            && ( cd librdkafka && ./configure && make ${MC} && make install && cd .. && rm -fr librdkafka )

        cd "${TMP_DIR}"
        echo "---------- Install rdkafka extension ----------"

        if [ -n "${RDKAFKA_EXT_VERSION}" ]; then
            download_pecl_package_verified "rdkafka" "${RDKAFKA_EXT_VERSION}" "rdkafka-${RDKAFKA_EXT_VERSION}.tgz" || exit 1
            if [ -f rdkafka-${RDKAFKA_EXT_VERSION}.tgz ]; then
                mkdir rdkafka \
                    && tar -xf rdkafka-${RDKAFKA_EXT_VERSION}.tgz -C rdkafka --strip-components=1 \
                    && ( cd rdkafka && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr rdkafka ) \
                    && docker-php-ext-enable rdkafka
            else
                echo "ERROR: rdkafka-${RDKAFKA_EXT_VERSION}.tgz 缺失，拒绝未验证的回退下载"
                exit 1
            fi
        else
            echo "ERROR: RDKAFKA_EXT_VERSION 为空，无法可信校验 PECL 包"
            exit 1
        fi
    fi
fi

if [ -z "${EXTENSIONS##*,zookeeper,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install apache-zookeeper ----------"
    apt-get update && apt-get install -y libcppunit-dev file ant libcppunit-dev git

    download_and_verify_sha256 \
        "https://archive.apache.org/dist/zookeeper/zookeeper-${ZOOKEEPER_VERSION}/apache-zookeeper-${ZOOKEEPER_VERSION}.tar.gz" \
        "apache-zookeeper-${ZOOKEEPER_VERSION}.tar.gz" "${ZOOKEEPER_SHA256:-}" || exit 1

    if [ -f apache-zookeeper-${ZOOKEEPER_VERSION}.tar.gz ]; then
        mkdir zookeeper \
            && tar -xf apache-zookeeper-${ZOOKEEPER_VERSION}.tar.gz -C zookeeper --strip-components=1 \
            && cd zookeeper \
            && ant clean jar \
            && ant compile_jute \
            && cd zookeeper-client/zookeeper-client-c \
            && autoreconf -if && ACLOCAL="aclocal -I /usr/share/aclocal" autoreconf -if \
            && ./configure --prefix=/usr/local/zookeeper && make CFLAGS="-Wno-error" ${MC} \
            && make install

        cd "${TMP_DIR}"
        rm -fr zookeeper
        echo "---------- Install zookeeper extension ----------"

        if [ -n "${ZOOKEEPER_EXT_VERSION}" ]; then
            download_pecl_package_verified "zookeeper" "${ZOOKEEPER_EXT_VERSION}" "zookeeper-${ZOOKEEPER_EXT_VERSION}.tgz" || exit 1
            if [ -f zookeeper-${ZOOKEEPER_EXT_VERSION}.tgz ]; then
                mkdir zookeeper-ext \
                    && tar -xf zookeeper-${ZOOKEEPER_EXT_VERSION}.tgz -C zookeeper-ext --strip-components=1 \
                    && ( cd zookeeper-ext && phpize && ./configure --with-libzookeeper-dir=/usr/local/zookeeper && make ${MC} && make install && cd .. && rm -fr zookeeper-ext ) \
                    && docker-php-ext-enable zookeeper
            else
                echo "ERROR: zookeeper-${ZOOKEEPER_EXT_VERSION}.tgz 缺失，拒绝未验证的回退下载"
                exit 1
            fi
        else
            echo "ERROR: ZOOKEEPER_EXT_VERSION 为空，无法可信校验 PECL 包"
            exit 1
        fi
    fi
fi

# ==========================================
# 最终校验：声明的扩展必须全部成功加载
# ==========================================
# 背景：上面各扩展块普遍采用“下载失败 -> 回退 pecl”的容错写法，任何一步失败都不会
# 中断脚本；再叠加 Dockerfile 中的 `ext-debian.sh | tee` 管道，退出码会被 tee 吞掉，
# 最终可能出现“镜像构建成功但扩展缺失”的假成功。这里统一兜底：只要 EXTENSIONS 中
# 有扩展没有出现在 `php -m` 输出里，就以非 0 退出，让 pipefail 把失败传递给构建。
# 注意：7.4/8.0/8.1 的 Dockerfile 用 ENV EXTENSIONS 传入扩展列表；
# 8.2+ 的 ENV 只设在最终运行阶段，构建阶段仅有 ARG PHP_EXTENSIONS，故做兜底，
# 否则该校验会因 EXTENSIONS 为空而空转。
_declared_exts="${EXTENSIONS:-${PHP_EXTENSIONS:-,}}"
_php_bin="${PHP_BIN:-/usr/local/bin/php}"
_missing_exts=""
while IFS= read -r _ext; do
    [ -n "${_ext}" ] || continue
    case "$_ext" in
        # opcache 在 php -m 中的模块名为 Zend OPcache
        opcache) _module="Zend OPcache" ;;
        *)       _module="${_ext}" ;;
    esac
    if ! "${_php_bin}" -m 2>/dev/null | grep -qix "${_module}"; then
        _missing_exts="${_missing_exts} ${_ext}"
    fi
done < <(printf '%s' "${_declared_exts}" | tr ',' '\n')

if [ -n "${_missing_exts}" ]; then
    echo "============================================"
    echo "ERROR: 以下扩展未成功加载:${_missing_exts}"
    echo "============================================"
    exit 1
fi

echo "所有声明的扩展均已成功加载: ${_declared_exts:-<none>}"
