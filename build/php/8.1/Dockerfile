FROM debian:bookworm-slim

# 代理设置参数
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

ARG PHP_VERSION
ARG PHP_SUFFIX=tar.xz
ARG PHP_EXTENSIONS

ARG CURL_VERSION
ARG LIBSODIUM_VERSION
ARG LIBICONV_VERSION
ARG REDIS_EXT_VERSION
ARG OPENSSL_VERSION
ARG FREETYPE_VERSION
ARG LIBWEBP_VERSION
ARG IMAGICK_VERSION
ARG IMAGICK_EXT_VERSION
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
ARG CHANGE_SOURCE=false
# 可选：构建阶段安装 nvm + Node（默认关闭）；版本与镜像见 env/php.env
ARG PHP_IMAGE_INSTALL_NVM=false
ARG PHP_IMAGE_NODE_VERSION=18.20.8
ARG PHP_IMAGE_NVM_NODE_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/

# prevent Debian's PHP packages from being installed
# https://github.com/docker-library/php/pull/542
RUN set -eux; \
	{ \
		echo 'Package: php*'; \
		echo 'Pin: release *'; \
		echo 'Pin-Priority: -1'; \
	} > /etc/apt/preferences.d/no-debian-php

ENV MC="-j$(nproc)"
ENV TMP_DIR=/tmp/extensions
ENV APACHE_CONFDIR=/etc/apache2
ENV APACHE_LOG_DIR=$APACHE_CONFDIR/logs
ENV APACHE_ENVVARS=$APACHE_CONFDIR/envvars
ENV APACHE_RUN_DIR=/var/run/apache2
ENV APACHE_PID_FILE=$APACHE_RUN_DIR/apache2.pid
ENV APACHE_RUN_USER=www-data
ENV APACHE_RUN_GROUP=www-data
ENV PHP_INI_DIR=/usr/local/etc/php

# dependencies required for running "phpize"
# persistent / runtime deps
RUN set -eux; \
	# apt 不支持 socks5 代理，统一禁用 apt 的代理（镜像源直连）
	echo 'Acquire::http::Proxy "false";' > /etc/apt/apt.conf.d/99noproxy; \
	echo 'Acquire::https::Proxy "false";' >> /etc/apt/apt.conf.d/99noproxy; \
	# 换源提前到第一个 apt-get update 之前
	if [ "${CHANGE_SOURCE}" = "true" ]; then \
		# bookworm 使用 deb822 源文件（与 PHP 8.2+ 一致）
		sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
	fi; \
	# Disable expired Valid-Until check for archived Debian release
	echo 'Acquire::Check-Valid-Until "false";' >> /etc/apt/apt.conf.d/99noproxy; \
	apt-get update; \
	apt-get upgrade -y; \
	apt-get install -y --assume-yes --no-install-recommends apt-transport-https ca-certificates; \
	cp -r /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/debian.sources.bak; \
	rm -rf /var/lib/apt/lists/*; \
	mkdir -p ${TMP_DIR}

RUN set -eux; \
	if [ "${CHANGE_SOURCE}" = "true" ]; then \
		sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
	fi; \
	mkdir -p "$PHP_INI_DIR/conf.d"; \
	\
	[ ! -d /var/www/html ]; \
		mkdir -p /var/www/html; \
		chmod 777 /var/www/html; \
	\
	# apt-get update; \
	# apt-get install -y --assume-yes --no-install-recommends apt-transport-https ca-certificates; \
	# mkdir -p ${TMP_DIR}; \
	apt-get update; \
	apt-get upgrade -y; \
	apt-get install -y --no-install-recommends apache2 git gnupg dirmngr curl xz-utils apt-utils libldap-common autoconf dpkg-dev file g++ gcc libc-dev make pkg-config re2c wget cmake automake libtool build-essential libssl-dev libpq-dev; \
	rm -rf /var/lib/apt/lists/*; \
	\
	sed -ri 's/^export ([^=]+)=(.*)$/: ${\1:=\2}\nexport \1/' "$APACHE_ENVVARS"; \
	\
	. "$APACHE_ENVVARS"; \
	for dir in \
		"$APACHE_LOCK_DIR" \
		"$APACHE_RUN_DIR" \
		"$APACHE_LOG_DIR" \
	; do \
		rm -rf "$dir"; \
		mkdir -p "$dir"; \
		chown "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$dir"; \
		chmod 777 "$dir"; \
	done; \
	\
	chown -R --no-dereference "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$APACHE_LOG_DIR"; \
	chown $APACHE_RUN_USER:$APACHE_RUN_GROUP /var/www/html; \
	\
	# Apache + PHP requires preforking Apache for best results
	a2dismod mpm_event && a2enmod headers rewrite mpm_prefork;

# PHP files should be handled by PHP, and should be preferred over any other file type
RUN { \
		echo '<FilesMatch \.php$>'; \
		echo '\tSetHandler application/x-httpd-php'; \
		echo '</FilesMatch>'; \
		echo; \
		echo 'DirectoryIndex disabled'; \
		echo 'DirectoryIndex index.php index.html index.htm'; \
		echo; \
		echo '<Directory /var/www/html/default>'; \
		echo '\tOptions Indexes FollowSymLinks'; \
		echo '\tAllowOverride None'; \
		echo '\tRequire all granted'; \
		echo '</Directory>'; \
	} | tee "$APACHE_CONFDIR/conf-available/docker-php.conf" \
	&& a2enconf docker-php

# Apply stack smash protection to functions using local buffers and alloca()
# Make PHP's main executable position-independent (improves ASLR security mechanism, and has no performance impact on x86_64)
# Enable optimization (-O2)
# Enable linker optimization (this sorts the hash buckets to improve cache locality, and is non-default)
# https://github.com/docker-library/php/issues/272
# -D_LARGEFILE_SOURCE and -D_FILE_OFFSET_BITS=64 (https://www.php.net/manual/en/intro.filesystem.php)
ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
# ENV PHP_LDFLAGS="-Wl,-O1 -pie"

# 解决错误： /lib/x86_64-linux-gnu/libpthread.so.0: error adding symbols: DSO missing from command line
ENV PHP_LDFLAGS="-Wl,--copy-dt-needed-entries"

ENV PHP_URL="https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz"

COPY ./build/php/common/ext-debian.sh ${TMP_DIR}
COPY ./src/php/ ${TMP_DIR}
COPY ./src/openssl/openssl-${OPENSSL_VERSION}.tar.gz ${TMP_DIR}/
COPY ./build/php/common/docker-php-* /usr/local/bin/
COPY ./include/shell/download-helper.sh /tmp/download-helper.sh
# 复制 Composer 安装脚本（curl 直装 phar + sha256 校验；兼容 socks5h 构建代理）
COPY ./include/shell/install-composer.sh /tmp/install-composer.sh
# PECL 频道注册表修复脚本（规避 PEAR 1.10.13 解析 channel.xml 时的 ETag 前缀污染）
COPY ./include/shell/fix-pecl-channel.php /tmp/fix-pecl-channel.php
# CVE-2026-109618 / CVE-2026-109619 官方修复补丁（GHSA-w8hw-w9fx-j79w / GHSA-6wmf-4rv5-p3rp）
# 来源：https://github.com/php/php-src/tree/PHP-8.1-CVE-2026-109618-109619
COPY ./build/php/patches/php8.1-CVE-2026-109618-109619.patch ${TMP_DIR}/
WORKDIR ${TMP_DIR}

RUN set -eux; \
	\
	chmod +x /usr/local/bin/docker-php-source; \
	savedAptMark="$(apt-mark showmanual)"; \
	# apt-get update; \
	# apt-get install -y --no-install-recommends gnupg dirmngr; \
	# rm -rf /var/lib/apt/lists/*; \
	\
	cd "${TMP_DIR}"; \
	bash -c '. /tmp/download-helper.sh && \
	parallel_download \
		"openssl-${OPENSSL_VERSION}.tar.gz:https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz|https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz|https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VERSION//./_}/openssl-${OPENSSL_VERSION}.tar.gz|https://ghproxy.net/https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz|https://ghproxy.net/https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VERSION//./_}/openssl-${OPENSSL_VERSION}.tar.gz" \
		"curl-${CURL_VERSION}.tar.xz:https://curl.se/download/curl-${CURL_VERSION}.tar.xz" \
		"libwebp-${LIBWEBP_VERSION}.tar.gz:https://github.com/webmproject/libwebp/archive/v${LIBWEBP_VERSION}.tar.gz|https://codeload.github.com/webmproject/libwebp/tar.gz/refs/tags/v${LIBWEBP_VERSION}|https://ghproxy.com/https://github.com/webmproject/libwebp/archive/v${LIBWEBP_VERSION}.tar.gz" \
		"php-${PHP_VERSION}.tar.xz:${PHP_URL}"'; \
	\
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark > /dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false

RUN set -eux; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		apache2-dev \
		libargon2-dev \
		libcurl4-openssl-dev \
		libonig-dev \
		libsodium-dev \
		libsqlite3-dev \
		libssl-dev \
		libreadline-dev \
		libxml2-dev \
		zlib1g-dev \
		libfreetype6-dev \
		libjpeg62-turbo-dev \
		libpng-dev \
		libzip-dev \
		libvpx-dev \
		libwebp-dev \
		libmagickwand-dev \
		libxpm-dev \
		libicu-dev \
		webp \
		libavif-dev \
		libxslt1-dev \
		libpsl-dev \
		patch \
	; \
	export MC="-j$(nproc)"; \
	\
	# ---------- Install openssl ----------
	if [ ! -e "/usr/local/openssl/lib/libssl.a" ]; then \
		cd "${TMP_DIR}"; \
		tar xzf openssl-${OPENSSL_VERSION}.tar.gz; \
		cd openssl-${OPENSSL_VERSION}; \
		./config -Wl,-rpath=/usr/local/openssl/lib -fPIC --prefix=/usr/local/openssl --openssldir=/usr/local/openssl; \
		make depend; \
		make ${MC}; \
		make install; \
		\
		if [ -e "/usr/bin/openssl" ]; then \
			mv /usr/bin/openssl /usr/bin/openssl.old; \
			ln -s /usr/local/openssl/bin/openssl /usr/bin/openssl; \
		fi; \
		\
		# if [ ! -e "/usr/lib/x86_64-linux-gnu/libssl.so.1.1" ]; then \
		# 	ln -sf /usr/local/openssl/lib/libssl.so.1.1 /usr/lib/x86_64-linux-gnu/libssl.so.1.1; \
		# fi; \
		# if [ ! -e "/usr/lib/x86_64-linux-gnu/libcrypto.so.1.1" ]; then \
		# 	ln -sf /usr/local/openssl/lib/libcrypto.so.1.1 /usr/lib/x86_64-linux-gnu/libcrypto.so.1.1; \
		# fi; \
		\
		if [ ! -e "/usr/lib/x86_64-linux-gnu/libssl.so.3" ]; then \
			ln -sf /usr/local/openssl/lib64/libssl.so.3 /usr/lib/x86_64-linux-gnu/libssl.so.3; \
		fi; \
		\
		if [ ! -e "/usr/lib/x86_64-linux-gnu/libcrypto.so.3" ]; then \
			ln -sf /usr/local/openssl/lib64/libcrypto.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3; \
		fi; \
		\
		if [ ! -e "/usr/lib/libssl.so" ]; then \
			ln -sf /usr/lib/x86_64-linux-gnu/libssl.so /usr/lib/; \
		fi; \
		\
		if [ -f "/usr/local/openssl/lib/libcrypto.a" ]; then \
		\
			if [ ! -f "/usr/local/openssl/cert.pem" ]; then \
				# echo "151.101.78.49 curl.haxx.se" >> /etc/hosts; \
				wget --limit-rate=100M --tries=6 -c --no-check-certificate https://curl.haxx.se/ca/cacert.pem; \
				cp -r cacert.pem /usr/local/openssl/cert.pem; \
			fi; \
		\
		fi; \
		\
		echo "/usr/local/openssl/lib" >> /etc/ld.so.conf; \
		ldconfig; \
		# find / -name libssl.so; \
		cd "${TMP_DIR}"; \
		rm -fr openssl-${OPENSSL_VERSION}; \
	fi; \
	\
	# ---------- Install freetype ----------
	if [ ! -e "/usr/local/freetype/lib/libfreetype.la" ]; then \
		cd "${TMP_DIR}"; \
		tar xJf freetype-${FREETYPE_VERSION}.tar.xz; \
		cd freetype-${FREETYPE_VERSION} > /dev/null; \
		./configure --prefix=/usr/local/freetype --enable-freetype-config; \
		make ${MC}; \
		make install; \
		ln -sf /usr/local/freetype/include/freetype2/* /usr/include/; \
		[ -d /usr/lib/pkgconfig ] && /bin/cp /usr/local/freetype/lib/pkgconfig/freetype2.pc /usr/lib/pkgconfig/; \
		cd "${TMP_DIR}"; \
		rm -rf freetype-${FREETYPE_VERSION}; \
	fi; \
	\
# ---------- Install curl ----------
	if [ ! -e "/usr/local/curl/lib/libcurl.la" ]; then \
		cd "${TMP_DIR}"; \
		tar xJf curl-${CURL_VERSION}.tar.xz; \
		cd curl-${CURL_VERSION}; \
		# cURL 8.x 要求 OpenSSL >= 3；且本地 OpenSSL 3.5.8 的默认 CA 路径与系统不一致，
		# 改用系统 OpenSSL 3（bookworm libssl-dev）以复用系统 CA；PHP 仍链接 /usr/local/openssl。
		./configure --prefix=/usr/local/curl --with-openssl; \
		make ${MC}; \
		make install; \
		cd "${TMP_DIR}"; \
		rm -fr curl-${CURL_VERSION}; \
		\
		if [ -e "/usr/local/curl/bin/curl" ]; then \
			mv /usr/bin/curl /usr/bin/curl.bak; \
			ln -sf /usr/local/curl/bin/curl /usr/bin/curl; \
		fi; \
	fi; \
	\
# ---------- Install libiconv ----------
	if [ ! -e "/usr/local/lib/libiconv.la" ]; then \
		cd "${TMP_DIR}"; \
		tar xzf libiconv-${LIBICONV_VERSION}.tar.gz; \
		cd libiconv-${LIBICONV_VERSION}; \
		./configure --prefix=/usr/local/libiconv; \
		make ${MC}; \
		make install; \
		cd "${TMP_DIR}"; \
		rm -fr libiconv-${LIBICONV_VERSION}; \
	fi; \
	\
# ---------- Install libsodium ----------
	if [ ! -e "/usr/local/lib/libsodium.la" ]; then \
		cd "${TMP_DIR}"; \
		tar xzf libsodium-${LIBSODIUM_VERSION}.tar.gz; \
		cd libsodium-${LIBSODIUM_VERSION}; \
		./configure --disable-dependency-tracking --enable-minimal; \
		make ${MC}; \
		make install; \
		cd "${TMP_DIR}"; \
		rm -fr libsodium-${LIBSODIUM_VERSION}; \
	fi; \
	\
# ---------- Install Webp plugin ----------
	cd "${TMP_DIR}"; \
	tar xzf libwebp-"${LIBWEBP_VERSION}".tar.gz; \
	cd libwebp-"${LIBWEBP_VERSION}"; \
	# 方法一：
	./autogen.sh; \
	./configure --enable-libwebpdecoder --enable-libwebpextras; \
	make ${MC}; \
	make install; \
	ldconfig /usr/local/lib/; \
	\
	# 方法二：
	# mkdir build; \
	# cd build; \
	# cmake ../; \
	# make ${MC}; \
	# make install; \
	# cmake -DWEBP_BUILD_CWEBP=ON -DWEBP_BUILD_DWEBP=ON ../; \
	cd "${TMP_DIR}"; \
	rm -rf libwebp-"${LIBWEBP_VERSION}"; \
	\
	# 让 PHP 编译使用本地 OpenSSL 3.5.8（3.x 库在 lib64），避免 bookworm 系统 OpenSSL 3.0 抢先
	export \
		CFLAGS="$PHP_CFLAGS" \
		CPPFLAGS="-I/usr/local/openssl/include $PHP_CPPFLAGS" \
		LDFLAGS="-L/usr/local/openssl/lib64 $PHP_LDFLAGS" \
		PKG_CONFIG_PATH="/usr/local/openssl/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
	; \
	mkdir php; \
	tar -Jxf php-${PHP_VERSION}.tar.xz -C php --strip-components=1; \
	touch "${TMP_DIR}/.docker-extracted"; \
	echo "Applying CVE-2026-109618 / CVE-2026-109619 security patch (PHP 8.1)..."; \
	patch -p1 --forward --directory="php" --input="${TMP_DIR}/php8.1-CVE-2026-109618-109619.patch"; \
	cd php; \
	gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
	debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
	if [ ! -d /usr/include/curl ]; then \
		ln -sT "/usr/include/$debMultiarch/curl" /usr/local/include/curl; \
	fi; \
	./configure \
		--build="$gnuArch" \
		--with-config-file-path="$PHP_INI_DIR" \
		--with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
		\
		--with-apxs2 \
		--with-pic \
		--with-xsl \
		--with-mhash \
		--with-gettext \
		--with-readline \
		--with-sqlite3=/usr \
		--with-pdo-sqlite=/usr \
		--with-curl=/usr/local/curl \
		--with-libdir="lib/$debMultiarch" \
		\
		# add postgresql support
		--with-pgsql --with-pdo-pgsql \
		\
		# bundled pcre does not support JIT on s390x
		$(test "$gnuArch" = 's390x-linux-gnu' && echo '--without-pcre-jit') \
		\
		# PHP 8.1 编译选项（本 Dockerfile 专用于 8.1）
		--with-openssl=/usr/local/openssl --with-sodium=/usr/local --with-zip --enable-gd --with-webp --with-freetype --with-xpm --with-jpeg --with-pear --with-iconv --with-password-argon2 --with-avif \
		\
		--enable-option-checking=fatal \
		--enable-mbstring \
		--enable-ftp \
		--with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
		# --enable-gd --with-freetype --with-jpeg --with-zlib \
		--with-zlib \
		--enable-xml \
		--enable-bcmath \
		--enable-shmop \
		--enable-exif \
		--enable-pcntl \
		--enable-sockets \
		--enable-soap \
		--enable-sysvsem \
		--enable-mbregex \
		\
		--disable-rpath \
		--disable-cgi \
		--disable-debug \
		# --disable-fileinfo \
		--disable-phpdbg \
	; \
	make ${MC}; \
	make install; \
	find -type f -name '*.a' -delete; \
	find \
		/usr/local \
		-type f \
		-perm '/0111' \
		-exec sh -euxc ' \
			strip --strip-all "$@" || : \
		' -- '{}' + \
	; \
	make clean; \
	\
	# pecl channel-update pecl.php.net; \
	# pecl update-channels; \
# https://github.com/docker-library/php/issues/692 (copy default example "php.ini" files somewhere easily discoverable)
	cp -v php.ini-* "$PHP_INI_DIR/"; \
	\
	cd "${TMP_DIR}"; \
	rm -fr php; \
	\
	# \
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
	apt-mark auto '.*' > /dev/null; \
	[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
	# bookworm merged-usr：ldd 输出 /lib/...，dpkg 记录 /usr/lib/...，归一化后再查所属包
	find /usr/local -type f -executable -exec ldd '{}' ';' \
		| awk '/=>/ { print $(NF-1) }' \
		| sort -u \
		| sed -e 's#^/lib/#/usr/lib/#' -e 's#^/lib64/#/usr/lib64/#' -e 's#^/lib32/#/usr/lib32/#' \
		| xargs -r dpkg-query --search \
		| cut -d: -f1 \
		| sort -u \
		| xargs -r apt-mark manual \
	; \
	\
	# apt-get install -y vim; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	rm -rf /var/lib/apt/lists/*

ADD ./build/php/common/apache2-foreground /usr/local/bin/
# 暂存到 /tmp：中间层 apt purge 会卸载 supervisor，最终 RUN 再安装并移入 conf.d
COPY ./build/php/common/supervisor/supervisord.conf /tmp/supervisord.docker.conf
COPY ./build/php/common/supervisor/conf.d/00-apache2.conf /tmp/supervisor-apache.conf
COPY ./build/php/common/docker-install-nvm.sh /tmp/docker-install-nvm.sh
ENV EXTENSIONS=",${PHP_EXTENSIONS},"

RUN set -eux; \
		\
		apt-get update; \
		apt-get install -y --no-install-recommends supervisor iputils-ping; \
		apt-mark manual supervisor iputils-ping; \
		if [ -f /etc/gai.conf ]; then \
			sed -ri 's/^#(precedence ::ffff:0:0\/96[[:space:]]+100)/\1/' /etc/gai.conf || true; \
			sed -ri 's/^#(label ::ffff:0:0\/96[[:space:]]+4)/\1/' /etc/gai.conf || true; \
		else \
			{ echo 'precedence ::ffff:0:0/96  100'; echo 'label ::ffff:0:0/96  4'; } > /etc/gai.conf; \
		fi; \
		rm -rf /var/lib/apt/lists/*; \
		install -d -m 755 /etc/supervisor/conf.d /var/log/supervisor; \
		cp /tmp/supervisord.docker.conf /etc/supervisor/supervisord.conf; \
		rm -f /tmp/supervisord.docker.conf; \
		mv /tmp/supervisor-apache.conf /etc/supervisor/conf.d/00-apache2.conf; \
		command -v supervisord; \
		command -v supervisorctl; \
		chmod +x /usr/local/bin/apache2-foreground; \
		\
		# 创建健康检查脚本
		{ \
			echo '#!/bin/bash'; \
			echo 'set -e'; \
			echo '# 检查Apache进程'; \
			echo 'pgrep apache2 > /dev/null || exit 1'; \
			echo '# 检查HTTP响应'; \
			echo 'curl -f http://localhost:88/php-status >/dev/null 2>&1 || exit 1'; \
			echo 'exit 0'; \
		} > /usr/local/bin/healthcheck.sh; \
		chmod +x /usr/local/bin/healthcheck.sh; \
		chmod +x /usr/local/bin/docker-php-*; \
		sed -i "s#<Directory /var/www/>#<Directory /var/www/html/>#g" /etc/apache2/apache2.conf; \
		echo "ServerName 127.0.0.1:88" >>  /etc/apache2/apache2.conf; \
		sed -i "s#ServerTokens OS#ServerTokens Prod#g" /etc/apache2/conf-available/security.conf; \
		sed -i "s#ServerSignature On#ServerSignature Off#g" /etc/apache2/conf-available/security.conf; \
		echo "ProtocolsHonorOrder On" >> /etc/apache2/conf-available/security.conf; \
		sed -i "s/#AddDefaultCharset UTF-8/AddDefaultCharset UTF-8/g" /etc/apache2/conf-available/charset.conf; \
		sed -i "s/Listen 80/Listen 88/g" /etc/apache2/ports.conf; \
		sed -i "s/CustomLog/#CustomLog/g" /etc/apache2/conf-enabled/other-vhosts-access-log.conf; \
		# 添加PHP状态页面支持
        echo "<Location /php-status>" > /etc/apache2/conf-available/status.conf && \
		echo "    SetHandler server-status" >> /etc/apache2/conf-available/status.conf && \
		echo "    Require local" >> /etc/apache2/conf-available/status.conf && \
		echo "</Location>" >> /etc/apache2/conf-available/status.conf && \
		# 启用status模块（如果未启用）和配置
		a2enmod status || true && \
		a2enconf status; \
		\
		echo "alias ll='ls -latrh --color=auto'" >> ~/.bashrc; \
		# source ~/.bashrc; \
		\
		if [ -f "/usr/bin/git" ]; then \
			git config --global alias.co checkout; \
			git config --global alias.br branch; \
			git config --global alias.ci commit; \
			git config --global alias.st status; \
			git config --global alias.last 'log -1 HEAD'; \
			git config --global alias.logg "log --graph --decorate --all"; \
			git config --global core.autocrlf "input"; \
			git config --global http.postBuffer 524288000; \
			git config --global core.editor /usr/bin/vi; \
			git config --global http.sslverify false; \
			git config --global pull.rebase false; \
			git config --global credential.helper cache; \
			git config --global http.version HTTP/2; \
			git config --global --add safe.directory "*"; \
		fi; \
		\
		# 安装 Composer（curl 直装 phar + sha256；脚本内已离线验证 --version） \
		sh /tmp/install-composer.sh; \
		\
		if [ -f "/usr/local/bin/pecl" ]; then \
			# 先修复频道注册表：PEAR 自带的 raw-socket HTTP 客户端会把 CDN 响应 ETag 的
			# 数字前缀混入 channel.xml 响应体，导致解析报
			#   XML Error: 'Not well-formed (invalid token)' on line '1'
			# 修复脚本用 PHP 原生 HTTP 客户端重新拉取并写回 ETag，使后续条件请求命中 304。
			php /tmp/fix-pecl-channel.php || echo "警告: PECL 频道修复失败，跳过（不影响扩展安装主路径）"; \
			\
			# 频道更新为可选步骤：即使失败也不中断构建（扩展有直接下载 tgz 的主路径）。
			pecl channel-update pecl.php.net || echo "警告: pecl channel-update 失败，继续构建"; \
			pecl update-channels || echo "警告: pecl update-channels 失败，继续构建"; \
		fi; \
		\
		rm -rf /tmp/pear ~/.pearrc; \
		\
    chmod +x ext-debian.sh; \
    # pipefail：让 ext-debian.sh 的退出码穿透 | tee，否则扩展安装失败也会被当作构建成功（/bin/sh 为 dash，不支持 pipefail，改用 bash） \
    bash -o pipefail -c 'bash ext-debian.sh | tee -a /tmp/ext-debian.log'; \
		rm -fr ${TMP_DIR}

RUN set -eux; \
	chmod +x /tmp/docker-install-nvm.sh; \
	export CHANGE_SOURCE="${CHANGE_SOURCE}"; \
	export PHP_IMAGE_INSTALL_NVM="${PHP_IMAGE_INSTALL_NVM}"; \
	export PHP_IMAGE_NODE_VERSION="${PHP_IMAGE_NODE_VERSION}"; \
	export PHP_IMAGE_NVM_NODE_MIRROR="${PHP_IMAGE_NVM_NODE_MIRROR}"; \
	bash /tmp/docker-install-nvm.sh

ENTRYPOINT ["docker-php-entrypoint"]
# supervisord 作为 PID 1 管理 apache2-foreground
STOPSIGNAL SIGTERM

WORKDIR /var/www/html

# 健康检查配置
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
	CMD /usr/local/bin/healthcheck.sh

EXPOSE 88
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
