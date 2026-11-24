# syntax=docker/dockerfile:1.7

FROM debian:bookworm-slim AS builder

ARG PHP_VERSION
ARG PHP_EXTENSIONS
ARG OPENSSL_VERSION
ARG TARGETARCH
ARG LIBAVIF_VERSION
ARG LIBAVIF_SHA256
ARG CHANGE_SOURCE=false
ARG FALLBACK_MIRROR
ARG BUILD_PROXY_TYPE=none
ARG REDIS_EXT_VERSION
ARG IMAGICK_VERSION
ARG IMAGICK_EXT_VERSION
ARG IMAGICK_SOURCE_SHA256
ARG MEMCACHED_VERSION
ARG MONGODB_EXT_VERSION
ARG SWOOLE_EXT_VERSION
ARG GRPC_EXT_VERSION
ARG LIBRDKAFKA_VERSION
ARG RDKAFKA_EXT_VERSION
ARG PROTOBUF_VERSION
ARG PROTOBUF_EXT_VERSION
ARG XDEBUG_EXT_VERSION
ARG ZOOKEEPER_VERSION
ARG ZOOKEEPER_EXT_VERSION
ARG YAML_EXT_VERSION
ARG PHP_IMAGE_INSTALL_NVM=false
ARG PHP_IMAGE_NODE_VERSION=26.1.0
ARG PHP_IMAGE_NVM_NODE_MIRROR=https://nodejs.org/dist/

ENV DEBIAN_FRONTEND=noninteractive \
    TMP_DIR=/tmp/extensions \
    PHP_INI_DIR=/usr/local/etc/php \
    APACHE_CONFDIR=/etc/apache2 \
    APACHE_ENVVARS=/etc/apache2/envvars \
    APACHE_RUN_DIR=/tmp/apache2/run \
    APACHE_PID_FILE=/tmp/apache2/run/apache2.pid \
    APACHE_RUN_USER=www-data \
    APACHE_RUN_GROUP=www-data \
    APACHE_LOCK_DIR=/tmp/apache2/lock \
    APACHE_LOG_DIR=/tmp/apache2/logs

RUN set -eux; \
    if [ "${CHANGE_SOURCE}" = "true" ]; then \
        sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
    elif [ -n "${FALLBACK_MIRROR:-}" ]; then \
        sed -i "s@deb.debian.org@${FALLBACK_MIRROR}@g" /etc/apt/sources.list.d/debian.sources; \
    fi; \
    if [ "${BUILD_PROXY_TYPE}" = "socks5" ] || [ "${BUILD_PROXY_TYPE}" = "socks5h" ]; then \
        printf '%s\n' 'Acquire::http::Proxy "false";' 'Acquire::https::Proxy "false";' > /etc/apt/apt.conf.d/99noproxy; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        apache2 apache2-dev autoconf automake bison build-essential ca-certificates cmake curl \
        dpkg-dev file g++ gcc git libargon2-dev libavif-dev libbrotli-dev libc-ares-dev \
        libaom-dev \
        libcurl4-openssl-dev libedit-dev libffi-dev libfreetype6-dev libicu-dev \
        libjpeg62-turbo-dev libmagickwand-dev libmemcached-dev libonig-dev libpng-dev \
        libpq-dev libreadline-dev libsodium-dev libsqlite3-dev libssl-dev libtool \
        libvpx-dev libwebp-dev libxpm-dev libxml2-dev libxslt1-dev libyaml-dev libzip-dev \
        make patch pkg-config re2c unzip wget xz-utils zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p "${TMP_DIR}" "${PHP_INI_DIR}/conf.d"

WORKDIR ${TMP_DIR}

# The repository download step owns source acquisition and checksum verification.
# Image builds are deliberately offline/fail-closed for PHP and OpenSSL sources.
COPY ./src/php/ ${TMP_DIR}/
COPY ./src/openssl/openssl-${OPENSSL_VERSION}.tar.gz ${TMP_DIR}/
COPY ./build/php/checksums.sha256 ${TMP_DIR}/checksums.sha256
COPY ./build/php/patches/ /tmp/php-patches/
COPY ./build/php/common/docker-php-* /usr/local/bin/

RUN set -eux; \
    test -s "php-${PHP_VERSION}.tar.xz"; \
    test -s "openssl-${OPENSSL_VERSION}.tar.gz"; \
    grep "  php-${PHP_VERSION}.tar.xz\$" checksums.sha256 | sha256sum -c -; \
    grep "  openssl-${OPENSSL_VERSION}.tar.gz\$" checksums.sha256 | sha256sum -c -; \
    tar -xzf "openssl-${OPENSSL_VERSION}.tar.gz"; \
    cd "openssl-${OPENSSL_VERSION}"; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
        amd64) _openssl_target=linux-x86_64 ;; \
        arm64) _openssl_target=linux-aarch64 ;; \
        *) _openssl_target=linux-generic64 ;; \
    esac; \
    ./Configure "${_openssl_target}" --prefix=/usr/local/openssl --openssldir=/usr/local/openssl \
        shared zlib no-ssl3 no-weak-ssl-ciphers; \
    make -j"$(nproc)"; \
    make install_sw; \
    printf '%s\n' /usr/local/openssl/lib /usr/local/openssl/lib64 > /etc/ld.so.conf.d/openssl-local.conf; \
    ldconfig

RUN set -eux; \
    _libavif_archive="libavif-${LIBAVIF_VERSION}.tar.gz"; \
    curl -fsSL --proto '=https' --tlsv1.2 \
        "https://codeload.github.com/AOMediaCodec/libavif/tar.gz/refs/tags/v${LIBAVIF_VERSION}" \
        -o "${_libavif_archive}"; \
    echo "${LIBAVIF_SHA256}  ${_libavif_archive}" | sha256sum -c -; \
    tar -xzf "${_libavif_archive}"; \
    cmake -S "libavif-${LIBAVIF_VERSION}" -B "libavif-${LIBAVIF_VERSION}/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=ON \
        -DAVIF_CODEC_AOM=SYSTEM \
        -DAVIF_LIBYUV=OFF \
        -DAVIF_BUILD_APPS=OFF \
        -DAVIF_BUILD_TESTS=OFF; \
    cmake --build "libavif-${LIBAVIF_VERSION}/build" --parallel "$(nproc)"; \
    cmake --install "libavif-${LIBAVIF_VERSION}/build"; \
    rm -rf "${_libavif_archive}" "libavif-${LIBAVIF_VERSION}"; \
    ldconfig

RUN set -eux; \
    chmod +x /usr/local/bin/docker-php-*; \
    tar -xJf "php-${PHP_VERSION}.tar.xz"; \
    cd "php-${PHP_VERSION}"; \
    case "${PHP_VERSION}" in \
        7.4.*) patch -p1 < /tmp/php-patches/php7.4-CVE-2026-109618-109619.patch ;; \
        8.0.*) patch -p1 < /tmp/php-patches/php8.0-CVE-2026-109618-109619.patch ;; \
        8.1.*) patch -p1 < /tmp/php-patches/php8.1-CVE-2026-109618-109619.patch ;; \
    esac; \
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
    debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
    _version_minor="${PHP_VERSION%.*}"; \
    _version_major="${_version_minor%.*}"; \
    _extra_args=''; \
    # PHP 7.4 仍使用旧开关；8.0+ 才是 --enable-zts。
    _zts_arg='--enable-zts'; \
    case "${_version_minor}" in \
        7.4) _extra_args='--with-iconv'; _zts_arg='--enable-maintainer-zts' ;; \
        8.0) _extra_args='--with-iconv' ;; \
        8.1|8.2|8.3|8.4) _extra_args='--with-iconv --with-avif' ;; \
        *) _extra_args='--with-iconv --with-avif --with-ffi' ;; \
    esac; \
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:/usr/local/openssl/lib/pkgconfig:/usr/local/openssl/lib64/pkgconfig"; \
    export CPPFLAGS="-I/usr/local/openssl/include -fstack-protector-strong -O2"; \
    export LDFLAGS="-L/usr/local/openssl/lib -L/usr/local/openssl/lib64 -Wl,-rpath,/usr/local/openssl/lib -Wl,-rpath,/usr/local/openssl/lib64"; \
    ./configure \
        --build="${gnuArch}" \
        --with-config-file-path="${PHP_INI_DIR}" \
        --with-config-file-scan-dir="${PHP_INI_DIR}/conf.d" \
        --with-apxs2 \
        --with-openssl=/usr/local/openssl \
        --with-curl \
        --with-xsl \
        --with-gettext \
        --with-readline \
        --with-sqlite3 \
        --with-pdo-sqlite \
        --with-libdir="lib/${debMultiarch}" \
        --with-pgsql --with-pdo-pgsql \
        --with-sodium --with-zip \
        --enable-gd --with-webp --with-freetype --with-xpm --with-jpeg \
        --with-password-argon2 --enable-intl \
        ${_zts_arg} --enable-mbstring --enable-ftp \
        --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
        --with-zlib --enable-bcmath --enable-shmop --enable-exif --enable-pcntl \
        --enable-sockets --enable-soap --enable-sysvsem --enable-mbregex \
        --disable-rpath --disable-cgi --disable-debug --disable-phpdbg \
        --enable-option-checking=fatal \
        ${_extra_args}; \
    make -j"$(nproc)"; \
    make install; \
    cp php.ini-production "${PHP_INI_DIR}/php.ini-production"; \
    find /usr/local -type f -name '*.a' -delete; \
    find /usr/local -type f -perm /0111 -exec sh -c 'strip --strip-all "$@" 2>/dev/null || true' sh {} +

COPY ./build/php/common/ext-debian.sh ${TMP_DIR}/ext-debian.sh
COPY ./include/shell/download-helper.sh /tmp/download-helper.sh
COPY ./include/shell/install-composer.sh /tmp/install-composer.sh

ENV EXTENSIONS=",${PHP_EXTENSIONS},"

RUN set -eux; \
    cd "${TMP_DIR}"; \
    chmod +x ext-debian.sh; \
    bash -o pipefail ext-debian.sh; \
    COMPOSER_INSTALL_LOG=/dev/null sh /tmp/install-composer.sh; \
    php -v; \
    php -m

# Optional Node runtime: install the signed release tarball into /opt instead
# of keeping nvm, Git and a root-owned /root/.nvm tree in the final image.
RUN set -eux; \
    mkdir -p /opt/node; \
    if [ "${PHP_IMAGE_INSTALL_NVM}" = "true" ]; then \
        case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
            amd64) _node_arch=x64 ;; \
            arm64) _node_arch=arm64 ;; \
            *) echo "Unsupported Node architecture: ${TARGETARCH:-unknown}" >&2; exit 1 ;; \
        esac; \
        _node_base="${PHP_IMAGE_NVM_NODE_MIRROR%/}/v${PHP_IMAGE_NODE_VERSION}"; \
        _node_file="node-v${PHP_IMAGE_NODE_VERSION}-linux-${_node_arch}.tar.xz"; \
        curl -fsSLO "${_node_base}/${_node_file}"; \
        curl -fsSLo SHASUMS256.txt "${_node_base}/SHASUMS256.txt"; \
        grep "  ${_node_file}\$" SHASUMS256.txt | sha256sum -c -; \
        tar -xJf "${_node_file}" -C /opt/node --strip-components=1; \
        rm -f "${_node_file}" SHASUMS256.txt; \
    fi

FROM debian:bookworm-slim AS runtime

ARG PHP_VERSION
ARG CHANGE_SOURCE=false
ARG PHP_IMAGE_INSTALL_NVM=false
ARG PHP_IMAGE_NODE_VERSION=26.1.0
ARG PHP_IMAGE_NVM_NODE_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/

ENV APACHE_CONFDIR=/etc/apache2 \
    APACHE_ENVVARS=/etc/apache2/envvars \
    APACHE_RUN_DIR=/tmp/apache2/run \
    APACHE_PID_FILE=/tmp/apache2/run/apache2.pid \
    APACHE_RUN_USER=www-data \
    APACHE_RUN_GROUP=www-data \
    APACHE_LOCK_DIR=/tmp/apache2/lock \
    APACHE_LOG_DIR=/tmp/apache2/logs \
    PHP_INI_DIR=/usr/local/etc/php \
    PATH=/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN set -eux; \
    if [ "${CHANGE_SOURCE}" = "true" ]; then \
        sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        apache2 ca-certificates curl libaom3 libargon2-1 libbrotli1 libc-ares2 \
        libcurl4 libdjvulibre21 libffi8 libfontconfig1 libfreetype6 libicu72 libjbig0 \
        libjpeg62-turbo liblcms2-2 liblqr-1-0 libmagickcore-6.q16-6 \
        libmagickwand-6.q16-6 libmemcached11 libonig5 libopenexr-3-1-30 libopenjp2-7 \
        libpng16-16 libpq5 libreadline8 \
        libsodium23 libsqlite3-0 libssl3 libvpx7 libwebp7 libxpm4 libxml2 libxslt1.1 \
        libtiff6 libxext6 libyaml-0-2 libzip4 zlib1g; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /var/www/html /var/www/php-health /tmp/apache2/run /tmp/apache2/lock /tmp/apache2/logs \
        /tmp/php_sessions /tmp/php_upload "${PHP_INI_DIR}/conf.d"; \
    chown -R www-data:www-data /var/www/html /var/www/php-health /tmp/apache2 /tmp/php_sessions /tmp/php_upload; \
    chmod 0750 /tmp/apache2 /tmp/apache2/run /tmp/apache2/lock /tmp/apache2/logs; \
    chmod 0700 /tmp/php_sessions /tmp/php_upload; \
    chmod 0555 /var/www/php-health

COPY --from=builder /usr/local/ /usr/local/
COPY --from=builder /opt/node/ /opt/node/
COPY --from=builder /etc/apache2/ /etc/apache2/
COPY --from=builder /usr/lib/apache2/ /usr/lib/apache2/
COPY --from=builder /etc/ld.so.conf.d/openssl-local.conf /etc/ld.so.conf.d/openssl-local.conf
COPY ./build/php/common/apache2-foreground /usr/local/bin/apache2-foreground
COPY ./build/php/common/docker-php-entrypoint /usr/local/bin/docker-php-entrypoint
COPY ./build/php/common/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY ./build/php/common/runtime.ini /usr/local/etc/php/conf.d/00-runtime.ini

RUN set -eux; \
    printf '%s\n' /usr/local/lib /usr/local/openssl/lib /usr/local/openssl/lib64 /usr/local/imagemagick/lib \
        > /etc/ld.so.conf.d/php-local.conf; \
    ldconfig; \
    sed -ri 's/^export ([^=]+)=(.*)$/: ${\1:=\2}\nexport \1/' "${APACHE_ENVVARS}"; \
    sed -ri 's!^Listen 80$!Listen 88!' /etc/apache2/ports.conf; \
    sed -ri 's!^([[:space:]]*)ErrorLog .*$!\1ErrorLog /proc/self/fd/2!' /etc/apache2/apache2.conf; \
    printf '%s\n' \
        'ServerName 127.0.0.1:88' \
        'ServerTokens Prod' \
        'ServerSignature Off' \
        'PidFile /tmp/apache2/run/apache2.pid' \
        'Mutex file:/tmp/apache2/lock default' \
        'CustomLog /proc/self/fd/1 combined' \
        >> /etc/apache2/apache2.conf; \
    printf '%s\n' \
        '<Location /php-status>' \
        '    SetHandler server-status' \
        '    Require local' \
        '    RewriteEngine Off' \
        '</Location>' \
        > /etc/apache2/conf-available/php-status.conf; \
    # conf-enabled 先于 sites-enabled 加载：作为未匹配 Host 的默认 vhost，避免健康检查打到业务站。
    printf '%s\n' \
        '<VirtualHost *:88>' \
        '    ServerName php-health.local' \
        '    DocumentRoot /var/www/php-health' \
        '    ErrorLog /proc/self/fd/2' \
        '    CustomLog /proc/self/fd/1 combined' \
        '    <Directory /var/www/php-health>' \
        '        Options None' \
        '        AllowOverride None' \
        '        Require local' \
        '        DirectoryIndex disabled' \
        '    </Directory>' \
        '</VirtualHost>' \
        > /etc/apache2/conf-available/000-php-health.conf; \
    printf '%s\n' \
        '<FilesMatch \.php$>' \
        '    SetHandler application/x-httpd-php' \
        '</FilesMatch>' \
        '' \
        'DirectoryIndex disabled' \
        'DirectoryIndex index.php index.html' \
        '' \
        '<Directory /var/www/>' \
        '    Options -Indexes' \
        '    AllowOverride All' \
        '</Directory>' \
        > /etc/apache2/conf-available/docker-php.conf; \
    # 兼容历史 vhost 的 ErrorLog "/etc/apache2/logs/..."；必须在 COPY /etc/apache2 之后创建。
    ln -sfn /tmp/apache2/logs /etc/apache2/logs; \
    a2dismod mpm_event || true; \
    a2enmod headers rewrite status mpm_prefork; \
    a2enconf 000-php-health docker-php php-status; \
    rm -f /etc/apache2/conf-enabled/other-vhosts-access-log.conf; \
    chmod 0755 /usr/local/bin/apache2-foreground /usr/local/bin/docker-php-entrypoint /usr/local/bin/healthcheck.sh; \
    apache2 -t; \
    php -v; \
    test ! -e /usr/bin/git; \
    test ! -e /usr/bin/gcc

WORKDIR /var/www/html
USER www-data:www-data
EXPOSE 88
STOPSIGNAL SIGWINCH
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD ["/usr/local/bin/healthcheck.sh"]
ENTRYPOINT ["docker-php-entrypoint"]
CMD ["apache2-foreground"]

LABEL org.opencontainers.image.title="hg_dnmpr PHP-Apache" \
      org.opencontainers.image.description="Non-root, multi-stage PHP with Apache" \
      org.opencontainers.image.version="${PHP_VERSION}"
