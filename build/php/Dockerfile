# 第一阶段：构建基础依赖
FROM debian:bookworm-slim AS base-builder

# 代理设置参数
ARG http_proxy
ARG https_proxy
ARG no_proxy

# 构建参数定义
ARG SOURCE_LIST
ARG CHANGE_SOURCE=false
ARG DEBIAN_FRONTEND=noninteractive

# 防止Debian的PHP包被安装
# https://github.com/docker-library/php/pull/542
RUN set -eux; \
	{ \
		echo 'Package: php*'; \
		echo 'Pin: release *'; \
		echo 'Pin-Priority: -1'; \
	} > /etc/apt/preferences.d/no-debian-php

# 设置基础环境变量
ENV TMP_DIR=/tmp/extensions
ENV MC="-j$(nproc)"

# 安装基础依赖
RUN set -eux; \
	if [ ${CHANGE_SOURCE} = true ]; then \
		sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
	fi; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		apache2 \
		apache2-dev \
		apt-transport-https \
		apt-utils \
		build-essential \
		ca-certificates \
		cmake \
		curl \
		dirmngr \
		dpkg-dev \
		file \
		git \
		g++ \
		gcc \
		gnupg \
		libargon2-dev \
		libavif-dev \
		libcurl4-openssl-dev \
		libfreetype6-dev \
		libicu-dev \
		libjpeg62-turbo-dev \
		libldap-common \
		libmagickwand-dev \
		libonig-dev \
		libpng-dev \
		libpng16-16 \
		libpq-dev \
		libpsl-dev \
		libreadline-dev \
		libsodium-dev \
		libsqlite3-dev \
		libssl-dev \
		libvpx-dev \
		libwebp-dev \
		libxpm-dev \
		libxml2-dev \
		libxslt1-dev \
		libzip-dev \
		libc-dev \
		libtool \
		lrzsz \
		make \
		perl-modules \
		pkg-config \
		re2c \
		webp \
		wget \
		xz-utils; \
	rm -rf /var/lib/apt/lists/*; \
	mkdir -p ${TMP_DIR}

# 创建工作目录
WORKDIR ${TMP_DIR}

# 第二阶段：构建基础库
FROM base-builder AS libs-builder

# 构建参数
ARG OPENSSL_VERSION
ARG CURL_VERSION
ARG FREETYPE_VERSION
ARG LIBWEBP_VERSION
ARG LIBICONV_VERSION
ARG LIBSODIUM_VERSION

# 复制源码包
COPY ./src/php/ ${TMP_DIR}/

# 下载所需的源码包（如果不存在）
# RUN set -eux; \
# 	cd "${TMP_DIR}"; \
# 	if [ ! -f "openssl-${OPENSSL_VERSION}.tar.gz" ]; then \
# 		curl -L "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" -o openssl-${OPENSSL_VERSION}.tar.gz; \
# 	fi; \
# 	if [ ! -f "curl-${CURL_VERSION}.tar.xz" ]; then \
# 		curl -L "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" -o curl-${CURL_VERSION}.tar.xz; \
# 	fi; \
# 	if [ ! -f "libwebp-${LIBWEBP_VERSION}.tar.gz" ]; then \
# 		curl -L "https://github.com/webmproject/libwebp/archive/v${LIBWEBP_VERSION}.tar.gz" -o libwebp-${LIBWEBP_VERSION}.tar.gz; \
# 	fi
RUN set -eux; \
	cd "${TMP_DIR}"; \
	# 并行下载优化
	download_if_missing() { \
		local url="$1" filename="$2"; \
		if [ ! -f "${filename}" ]; then \
			echo "下载 ${filename}..."; \
			curl -fsSL --retry 3 --retry-delay 5 -o "${filename}" "${url}" || { \
				echo "下载 ${filename} 失败"; \
				return 1; \
			}; \
		else \
			echo "${filename} 已存在，跳过下载"; \
		fi; \
	}; \
	\
	# 并行下载 (网络优化)
	{ \
		download_if_missing "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" "openssl-${OPENSSL_VERSION}.tar.gz" & \
		download_if_missing "https://curl.se/download/curl-${CURL_VERSION}.tar.xz" "curl-${CURL_VERSION}.tar.xz" & \
		download_if_missing "https://github.com/webmproject/libwebp/archive/v${LIBWEBP_VERSION}.tar.gz" "libwebp-${LIBWEBP_VERSION}.tar.gz" & \
		wait; \
	} || { echo "下载失败"; exit 1; }


# 编译基础库
RUN set -eux; \
	export MC="-j$(nproc)"; \
	\
	if [ -e "/usr/lib/x86_64-linux-gnu/libpng16.so.16" ]; then \
		echo "/usr/lib/x86_64-linux-gnu" >> /etc/ld.so.conf.d/libpng.conf; \
		ldconfig; \
	fi; \
	\
	# ---------- 编译 OpenSSL (优化版) ----------
	build_openssl() { \
		if [ ! -e "/usr/local/openssl/lib/libssl.a" ]; then \
			echo "编译 OpenSSL ${OPENSSL_VERSION}..."; \
			cd "${TMP_DIR}"; \
			tar xzf "openssl-${OPENSSL_VERSION}.tar.gz"; \
			cd "openssl-${OPENSSL_VERSION}"; \
			\
			# 多架构优化配置
			case "${TARGETARCH:-$(uname -m)}" in \
				"amd64"|"x86_64") CONFIG_ARCH="linux-x86_64" ;; \
				"arm64"|"aarch64") CONFIG_ARCH="linux-aarch64" ;; \
				*) CONFIG_ARCH="linux-generic64" ;; \
			esac; \
			\
			./Configure "${CONFIG_ARCH}" \
				--prefix=/usr/local/openssl \
				--openssldir=/usr/local/openssl \
				shared zlib \
				enable-ec_nistp_64_gcc_128 \
				no-ssl3 no-weak-ssl-ciphers \
				-Wl,-rpath=/usr/local/openssl/lib; \
			make depend; \
			make ${MC}; \
			make install_sw; \
			\
			# 更新系统链接
			if [ -e "/usr/bin/openssl" ]; then \
				mv /usr/bin/c_rehash /usr/bin/c_rehash.old || true; \
				mv /usr/bin/openssl /usr/bin/openssl.old || true; \
				ln -sf /usr/local/openssl/bin/openssl /usr/bin/openssl; \
			fi; \
			\
			# 配置动态链接库
			if [[ ${OPENSSL_VERSION} =~ ^1\.1 ]]; then \
				ln -sf /usr/local/openssl/lib/libssl.so.1.1 /usr/lib/x86_64-linux-gnu/libssl.so.1.1; \
				ln -sf /usr/local/openssl/lib/libcrypto.so.1.1 /usr/lib/x86_64-linux-gnu/libcrypto.so.1.1; \
				echo "/usr/local/openssl/lib" > /etc/ld.so.conf.d/openssl-1.1.conf; \
			else \
				rm -f /usr/bin/openssl /usr/include/openssl /usr/lib/libssl.so /usr/lib/libcrypto.so; \
				ln -sf /usr/local/openssl/bin/openssl /usr/bin/openssl; \
				ln -sf /usr/local/openssl/include/openssl /usr/include/openssl; \
				ln -sf /usr/local/openssl/lib/libssl.so /usr/lib/libssl.so; \
				ln -sf /usr/local/openssl/lib/libcrypto.so /usr/lib/libcrypto.so; \
				echo "/usr/local/openssl/lib" > /etc/ld.so.conf.d/openssl-3.conf; \
			fi; \
			ldconfig; \
			cd "${TMP_DIR}"; \
			rm -rf "openssl-${OPENSSL_VERSION}"; \
		fi; \
	}; \
	\
	# ---------- 编译 FreeType (优化版) ----------
	build_freetype() { \
		if [ ! -e "/usr/local/freetype/lib/libfreetype.la" ]; then \
			echo "编译 FreeType ${FREETYPE_VERSION}..."; \
			cd "${TMP_DIR}"; \
			tar xJf "freetype-${FREETYPE_VERSION}.tar.xz"; \
			cd "freetype-${FREETYPE_VERSION}"; \
			./configure \
				--prefix=/usr/local/freetype \
				--enable-freetype-config \
				--with-harfbuzz=no \
				--with-brotli=no; \
			make ${MC}; \
			make install; \
			ln -sf /usr/local/freetype/include/freetype2/* /usr/include/ || true; \
			[ -d /usr/lib/pkgconfig ] && cp /usr/local/freetype/lib/pkgconfig/freetype2.pc /usr/lib/pkgconfig/ || true; \
			cd "${TMP_DIR}"; \
			rm -rf "freetype-${FREETYPE_VERSION}"; \
		fi; \
	}; \
	\
	# ---------- 编译 cURL (优化版) ----------
	build_curl() { \
		if [ ! -e "/usr/local/curl/lib/libcurl.la" ]; then \
			echo "编译 cURL ${CURL_VERSION}..."; \
			cd "${TMP_DIR}"; \
			tar xJf "curl-${CURL_VERSION}.tar.xz"; \
			cd "curl-${CURL_VERSION}"; \
			./configure \
				--prefix=/usr/local/curl \
				--with-openssl=/usr/local/openssl \
				--enable-optimize \
				--enable-http \
				--enable-ftp \
				--enable-file \
				--enable-ldap \
				--enable-ldaps \
				--enable-proxy \
				--enable-dict \
				--enable-telnet \
				--enable-tftp \
				--enable-pop3 \
				--enable-imap \
				--enable-smb \
				--enable-smtp \
				--enable-gopher \
				--disable-manual; \
			make ${MC}; \
			make install; \
			cd "${TMP_DIR}"; \
			rm -rf "curl-${CURL_VERSION}"; \
			\
			# 更新系统curl
			if [ -e "/usr/local/curl/bin/curl" ]; then \
				mv /usr/bin/curl /usr/bin/curl.bak || true; \
				ln -sf /usr/local/curl/bin/curl /usr/bin/curl; \
			fi; \
		fi; \
	}; \
	\
	# ---------- 编译 libiconv ----------
	build_libiconv() { \
		if [ ! -e "/usr/local/lib/libiconv.la" ]; then \
			echo "编译 libiconv ${LIBICONV_VERSION}..."; \
			cd "${TMP_DIR}"; \
			tar xzf "libiconv-${LIBICONV_VERSION}.tar.gz"; \
			cd "libiconv-${LIBICONV_VERSION}"; \
			./configure --prefix=/usr/local/libiconv; \
			make ${MC}; \
			make install; \
			cd "${TMP_DIR}"; \
			rm -rf "libiconv-${LIBICONV_VERSION}"; \
		fi; \
	}; \
	\
	# ---------- 编译 libsodium ----------
	build_libsodium() { \
		if [ ! -e "/usr/local/lib/libsodium.la" ]; then \
			echo "编译 libsodium ${LIBSODIUM_VERSION}..."; \
			cd "${TMP_DIR}"; \
			tar xzf "libsodium-${LIBSODIUM_VERSION}.tar.gz"; \
			cd "libsodium-${LIBSODIUM_VERSION}"; \
			./configure \
				--disable-dependency-tracking \
				--enable-minimal \
				--enable-opt; \
			make ${MC}; \
			make install; \
			cd "${TMP_DIR}"; \
			rm -rf "libsodium-${LIBSODIUM_VERSION}"; \
		fi; \
	}; \
	\
	# ---------- 编译 WebP ----------
	build_webp() { \
		echo "编译 WebP ${LIBWEBP_VERSION}..."; \
		cd "${TMP_DIR}"; \
		tar xzf "libwebp-${LIBWEBP_VERSION}.tar.gz"; \
		cd "libwebp-${LIBWEBP_VERSION}"; \
		./autogen.sh; \
		./configure \
			--enable-libwebpdecoder \
			--enable-libwebpextras \
			--enable-everything; \
		make ${MC}; \
		make install; \
		ldconfig /usr/local/lib/; \
		cd "${TMP_DIR}"; \
		rm -rf "libwebp-${LIBWEBP_VERSION}"; \
	}; \
	\
	# 并行构建基础库
	{ \
		build_openssl & \
		build_freetype & \
		build_curl & \
		build_libiconv & \
		build_libsodium & \
		wait; \
		build_webp; \
	}

# 第三阶段：构建PHP
FROM libs-builder AS php-builder

# PHP相关参数
ARG PHP_VERSION
ARG PHP_SUFFIX
ARG PHP_EXTENSIONS
ARG REDIS_EXT_VERSION
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

# 设置PHP编译参数和环境变量
ENV PHP_INI_DIR=/usr/local/etc/php
ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
ENV PHP_CPPFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
ENV PHP_LDFLAGS="-Wl,--copy-dt-needed-entries"
ENV PHP_URL="https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz"
ENV APACHE_CONFDIR=/etc/apache2
ENV APACHE_LOG_DIR=$APACHE_CONFDIR/logs
ENV APACHE_ENVVARS=$APACHE_CONFDIR/envvars
ENV APACHE_RUN_DIR=/var/run/apache2
ENV APACHE_PID_FILE=$APACHE_RUN_DIR/apache2.pid
ENV APACHE_RUN_USER=www-data
ENV APACHE_RUN_GROUP=www-data
ENV APACHE_LOCK_DIR=/var/lock/apache2

# 复制PHP构建脚本和配置工具
COPY ./build/php/ext-debian.sh ${TMP_DIR}/
COPY ./build/php/docker-php-* /usr/local/bin/

# 设置Apache目录和PHP INI目录
RUN set -eux; \
	mkdir -p "$PHP_INI_DIR/conf.d"; \
	chmod +x /usr/local/bin/docker-php-*; \
	mkdir -p /var/www/html; \
	chmod 777 /var/www/html; \
	\
	# Apache配置
	sed -ri 's/^export ([^=]+)=(.*)$/: ${\1:=\2}\nexport \1/' "$APACHE_ENVVARS"; \
	. "$APACHE_ENVVARS"; \
	for dir in \
		"$APACHE_LOCK_DIR" \
		"$APACHE_RUN_DIR" \
		"$APACHE_LOG_DIR" \
		"$APACHE_RUN_DIR/socks" \
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
	# Apache mod_php配置
	a2dismod mpm_event && a2enmod headers rewrite mpm_prefork; \
	{ \
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

# 下载PHP源码
RUN set -eux; \
	cd "${TMP_DIR}"; \
	if [ ! -f "php-${PHP_VERSION}.tar.xz" ]; then \
		echo "正在下载PHP源码：${PHP_URL}"; \
		curl -fsSL -o php-${PHP_VERSION}.tar.xz "$PHP_URL" || { echo "下载PHP源码失败"; exit 1; }; \
	else \
		echo "PHP源码已存在，跳过下载"; \
	fi; \
	echo "检查PHP源码包"; \
	ls -la php-${PHP_VERSION}.tar.xz || { echo "PHP源码不存在"; exit 1; }

# 编译安装PHP
RUN set -eux; \
	echo "构建环境变量: PHP_CFLAGS=${PHP_CFLAGS}, PHP_CPPFLAGS=${PHP_CPPFLAGS}, PHP_LDFLAGS=${PHP_LDFLAGS}"; \
	cd "${TMP_DIR}"; \
	export CFLAGS="${PHP_CFLAGS}"; \
	export CPPFLAGS="${PHP_CPPFLAGS}"; \
	export LDFLAGS="${PHP_LDFLAGS}"; \
	mkdir -p php; \
	echo "解压PHP源码包"; \
	tar -Jxf php-${PHP_VERSION}.tar.xz -C php --strip-components=1 || { echo "解压PHP源码失败"; exit 1; }; \
	touch "${TMP_DIR}/.docker-extracted"; \
	cd php; \
	\
	# 获取PHP版本信息
	echo "读取PHP版本信息"; \
	[ -f "main/php_version.h" ] || { echo "PHP版本文件不存在"; ls -la main/; exit 1; }; \
	phpMajor="$(grep "#define PHP_MAJOR_VERSION " main/php_version.h | awk -F " " '{print $3}')"; \
	phpMinor="$(grep "#define PHP_MINOR_VERSION " main/php_version.h | awk -F " " '{print $3}')"; \
	phpVersionId=${phpMajor}.${phpMinor}; \
	echo "检测到PHP版本: ${phpVersionId}"; \
	\
	# 设置构建参数
	gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
	debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
	if [ ! -d /usr/include/curl ]; then \
		echo "创建curl符号链接"; \
		mkdir -p /usr/local/include; \
		if [ -d "/usr/include/$debMultiarch/curl" ]; then \
			ln -sT "/usr/include/$debMultiarch/curl" /usr/local/include/curl; \
		else \
			echo "警告: /usr/include/$debMultiarch/curl 不存在"; \
			ls -la /usr/include/$debMultiarch/; \
		fi; \
	fi; \
	\
	# 配置并编译PHP
	echo "配置PHP构建参数"; \
	./configure \
		--build="$gnuArch" \
		--with-config-file-path="$PHP_INI_DIR" \
		--with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
		--with-apxs2 \
		--with-pic \
		--with-xsl \
		--with-gettext \
		--with-readline \
		--with-sqlite3=/usr \
		--with-pdo-sqlite=/usr \
		--with-curl=/usr/local/curl \
		--with-libdir="lib/$debMultiarch" \
		--with-pgsql --with-pdo-pgsql \
		$(test "$gnuArch" = 's390x-linux-gnu' && echo '--without-pcre-jit') \
		# PHP版本特定配置
		$(test "$phpVersionId" = "5.6" && echo '--with-openssl --with-mcrypt --enable-zip --with-gd --enable-gd-native-ttf --with-libxml-dir=/usr --with-freetype-dir=/usr/local/freetype --with-jpeg-dir --with-png-dir --with-iconv-dir --enable-inline-optimization') \
		$(test "$phpVersionId" = "7.0" && echo '--with-openssl --with-mcrypt --enable-zip --with-gd --enable-gd-native-ttf --with-libxml-dir=/usr --with-webp-dir=/usr/local --with-freetype-dir=/usr/local/freetype --with-jpeg-dir --with-png-dir --with-iconv-dir --enable-inline-optimization') \
		$(test "$phpVersionId" = "7.1" && echo '--with-openssl --with-mcrypt --enable-zip --with-gd --enable-gd-native-ttf --with-libxml-dir=/usr --with-webp-dir=/usr/local --with-freetype-dir=/usr/local/freetype --with-jpeg-dir --with-png-dir --with-iconv-dir --enable-inline-optimization') \
		$(test "$phpVersionId" = "7.2" && echo '--enable-maintainer-zts --with-openssl --with-sodium=/usr/local --enable-zip --with-gd --with-libxml-dir=/usr --with-webp-dir=/usr/local --with-freetype-dir=/usr/local/freetype --with-jpeg-dir --with-png-dir --with-iconv-dir --enable-inline-optimization --with-password-argon2') \
		$(test "$phpVersionId" = "7.3" && echo '--enable-maintainer-zts --with-openssl=/usr/local/openssl --with-sodium=/usr/local --enable-zip --with-gd --with-libxml-dir=/usr --with-webp-dir=/usr/local --with-freetype-dir=/usr/local/freetype --with-jpeg-dir --with-png-dir --with-iconv-dir --enable-inline-optimization --with-password-argon2') \
		$(test "$phpVersionId" = "7.4" && echo '--enable-maintainer-zts --with-mhash --with-openssl=/usr/local/openssl --with-sodium=/usr/local --with-zip --enable-gd --with-webp --with-freetype --with-xpm --with-jpeg --with-iconv-dir --enable-inline-optimization --with-password-argon2') \
		$(test "$phpVersionId" = "8.0" && echo '--enable-zts --with-openssl --with-mhash --with-sodium=/usr/local --with-zip --enable-gd --with-webp --with-freetype --with-xpm --with-jpeg --with-iconv --with-password-argon2') \
		$(test "$phpVersionId" = "8.1" && echo '--enable-zts --with-openssl --with-sodium=/usr/local --with-zip --enable-gd --with-webp --with-freetype --with-xpm --with-jpeg --with-iconv --with-password-argon2 --with-avif') \
		$(test "$phpVersionId" = "8.2" && echo '--enable-zts --with-openssl --with-sodium=/usr/local --with-zip --enable-gd --with-webp --with-freetype --with-xpm --with-jpeg --with-iconv --with-password-argon2 --with-avif') \
		$(test "$phpVersionId" = "8.3" && echo '--enable-zts --with-openssl --with-sodium=/usr/local --with-zip --enable-gd --with-webp --with-freetype --with-xpm --with-jpeg --with-iconv --with-password-argon2 --with-avif') \
		$(test "$phpVersionId" = "8.4" && echo '--enable-zts --with-openssl=/usr/local/openssl --with-sodium=/usr/local --with-zip --enable-gd --with-webp --with-freetype --with-xpm --with-jpeg --with-iconv --with-password-argon2 --with-avif') \
		--enable-option-checking=fatal \
		--enable-mbstring \
		--enable-ftp \
		--with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
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
		--disable-rpath \
		--disable-cgi \
		--disable-debug \
		--disable-phpdbg || { echo "PHP配置失败"; cat config.log; exit 1; }; \
	\
	echo "编译PHP"; \
	make -j "$(nproc)" || { echo "PHP编译失败"; exit 1; }; \
	echo "安装PHP"; \
	make install || { echo "PHP安装失败"; exit 1; }; \
	\
	# 删除不必要的文件和优化
	find -type f -name '*.a' -delete; \
	find /usr/local -type f -perm '/0111' -exec sh -euxc 'strip --strip-all "$@" || :' -- '{}' +; \
	make clean; \
	\
	# 复制PHP.ini文件示例
	cp -v php.ini-* "$PHP_INI_DIR/"

# 安装扩展和Composer
RUN set -eux; \
	cd "${TMP_DIR}"; \
	echo "安装PHP扩展"; \
	chmod +x ext-debian.sh; \
	bash ext-debian.sh | tee -a /tmp/ext-debian.log || echo "扩展安装可能有部分失败"; \
	\
	echo "安装Composer"; \
	php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" || { echo "下载Composer失败"; }; \
	php -r "if (hash_file('sha384', 'composer-setup.php') === 'dac665fdc30fdd8ec78b38b9800061b4150413ff2e3b6f88543c636f7cd84f6db9189d43a81e5503cda447da73c7e5b6') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); } echo PHP_EOL;" || echo "验证Composer失败"; \
	php composer-setup.php || echo "安装Composer失败"; \
	php -r "unlink('composer-setup.php');" || echo "删除Composer安装程序失败"; \
	if [ -f "composer.phar" ]; then \
		mv composer.phar /usr/local/bin/composer; \
		chmod +x /usr/local/bin/composer; \
	else \
		echo "Composer安装失败，未生成composer.phar文件"; \
	fi; \
	\
	# 更新PECL通道
	if [ -f "/usr/local/bin/pecl" ]; then \
		pecl channel-update pecl.php.net || echo "PECL通道更新失败"; \
		pecl update-channels || echo "PECL通道刷新失败"; \
	fi; \
	\
	# 清理缓存
	rm -rf /tmp/pear ~/.pearrc; \
	apt-get autoremove -y; \
	apt-get autoclean

# ==========================================
# 最终阶段：运行时镜像 (安全优化)
# ==========================================
FROM debian:bookworm-slim

# 运行时参数
ARG PHP_EXTENSIONS
ARG PHP_VERSION
ARG CHANGE_SOURCE=false

# 防止Debian的PHP包被安装
RUN set -eux; \
	{ \
		echo 'Package: php*'; \
		echo 'Pin: release *'; \
		echo 'Pin-Priority: -1'; \
	} > /etc/apt/preferences.d/no-debian-php

# 设置环境变量
ENV APACHE_CONFDIR=/etc/apache2
ENV APACHE_LOG_DIR=$APACHE_CONFDIR/logs
ENV APACHE_ENVVARS=$APACHE_CONFDIR/envvars
ENV APACHE_RUN_DIR=/var/run/apache2
ENV APACHE_PID_FILE=$APACHE_RUN_DIR/apache2.pid
ENV APACHE_RUN_USER=www-data
ENV APACHE_RUN_GROUP=www-data
ENV APACHE_LOCK_DIR=/var/lock/apache2
ENV PHP_INI_DIR=/usr/local/etc/php
ENV EXTENSIONS=",${PHP_EXTENSIONS},"

# 安装运行时依赖
RUN set -eux; \
	if [ ${CHANGE_SOURCE} = true ]; then \
		sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
	fi; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		apache2 \
		curl \
		git \
		build-essential \
        autoconf \
		g++ \
		gcc \
		libbrotli-dev libc-ares-dev libargon2-1 libcurl4-openssl-dev libjbig-dev libtiff-dev libfontconfig-dev \
		libavif15 \
		libcurl4 \
		libicu72 \
		libjpeg62-turbo \
		libonig5 \
		libpng16-16 \
		libpq5 \
		libsqlite3-0 \
		libssl3 \
		libwebp7 \
		libxml2 \
		libxpm4 \
		libzip4 \
		lrzsz \
		ca-certificates \
		libreadline8 \
		libsodium23 \
		zlib1g \
		zlib1g-dev \
		libxslt1.1 \
		libssl-dev \
		libfreetype6 \
		libvpx7 \
		libyaml-dev liblcms2-2 liblqr-1-0-dev libdjvulibre21 libxext6 libxext-dev libopenexr-dev libopenjp2-7-dev \
		pkg-config; \
		rm -rf /var/lib/apt/lists/*; \
		\
	# 创建必要的目录
	mkdir -p /var/www/html; \
	chmod 777 /var/www/html; \
	mkdir -p "$PHP_INI_DIR/conf.d"; \
	\
	# 创建Apache目录
	mkdir -p "$APACHE_LOG_DIR" "$APACHE_RUN_DIR" "$APACHE_LOCK_DIR" "$APACHE_RUN_DIR/socks"; \
	chown -R "$APACHE_RUN_USER:$APACHE_RUN_GROUP" /var/www/html "$APACHE_LOG_DIR" "$APACHE_RUN_DIR"; \
	chmod 777 "$APACHE_LOG_DIR" "$APACHE_RUN_DIR" "$APACHE_LOCK_DIR" "$APACHE_RUN_DIR/socks"

# 从构建阶段复制文件
COPY --from=php-builder /usr/local/ /usr/local/
COPY --from=php-builder /etc/apache2/ /etc/apache2/
COPY --from=php-builder /usr/lib/apache2/ /usr/lib/apache2/
COPY --from=php-builder /etc/ld.so.conf.d/ /etc/ld.so.conf.d/
COPY ./build/php/apache2-foreground /usr/local/bin/

# 配置Apache和系统环境
RUN set -eux; \
	ldconfig; \
	chmod +x /usr/local/bin/apache2-foreground; \
	chmod +x /usr/local/bin/docker-php-*; \
	\
	# 配置Apache
	sed -i "s#<Directory /var/www/>#<Directory /var/www/html/>#g" /etc/apache2/apache2.conf; \
	echo "ServerName 127.0.0.1:88" >> /etc/apache2/apache2.conf; \
	sed -i "s#ServerTokens OS#ServerTokens Prod#g" /etc/apache2/conf-available/security.conf; \
	sed -i "s#ServerSignature On#ServerSignature Off#g" /etc/apache2/conf-available/security.conf; \
	echo "ProtocolsHonorOrder On" >> /etc/apache2/conf-available/security.conf; \
	sed -i "s/#AddDefaultCharset UTF-8/AddDefaultCharset UTF-8/g" /etc/apache2/conf-available/charset.conf; \
	sed -i "s/Listen 80/Listen 88/g" /etc/apache2/ports.conf; \
	sed -i "s/CustomLog/#CustomLog/g" /etc/apache2/conf-enabled/other-vhosts-access-log.conf; \
	\
	# 添加监控端点
	{ \
	echo '<Location /php-status>'; \
	echo '    SetHandler server-status'; \
	echo '    Require local'; \
	echo '</Location>'; \
	echo '<Location /php-info>'; \
	echo '    SetHandler application/x-httpd-php'; \
	echo '    Require local'; \
	echo '</Location>'; \
	} >> /etc/apache2/conf-available/status.conf; \
	# 启用status模块（如果未启用）和配置
	a2enmod status || true; \
	a2enconf status; \
	\
	# 启用Apache模块，采用了prefork MPM配合mod_php模式，这是为了避免潜在的线程安全问题。
	a2dismod mpm_event && a2enmod headers rewrite mpm_prefork; \
	a2enconf docker-php; \
	\
	# 安全配置增强
	{ \
		echo 'Header always set X-Content-Type-Options nosniff'; \
		echo 'Header always set X-Frame-Options DENY'; \
		echo 'Header always set X-XSS-Protection "1; mode=block"'; \
		echo 'Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"'; \
		echo 'Header always set Referrer-Policy "strict-origin-when-cross-origin"'; \
	} >> /etc/apache2/conf-available/security-headers.conf; \
	a2enconf security-headers; \
	\
	# 配置终端环境
	echo "alias ll='ls -latrh --color=auto'" >> ~/.bashrc; \
	\
	# 配置Git全局设置
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
	# 创建健康检查脚本
	{ \
		echo '#!/bin/bash'; \
		echo 'set -e'; \
		echo '# 检查Apache进程'; \
		echo 'pgrep apache2 > /dev/null || exit 1'; \
		# echo '# 检查PHP-FPM (如果启用)'; \
		# echo '# pgrep php-fpm > /dev/null || exit 1'; \
		echo '# 检查HTTP响应'; \
		echo 'curl -f http://localhost:88/php-status >/dev/null 2>&1 || exit 1'; \
		echo 'exit 0'; \
	} > /usr/local/bin/healthcheck.sh; \
	chmod +x /usr/local/bin/healthcheck.sh

# 创建PHP信息页面用于监控
RUN echo '<?php phpinfo(); ?>' > /var/www/html/php-info.php

# 设置工作目录
WORKDIR /var/www/html

# 健康检查配置 (优化版)
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
	CMD /usr/local/bin/healthcheck.sh

# 暴露端口
EXPOSE 88

# 设置入口点和命令
ENTRYPOINT ["docker-php-entrypoint"]
STOPSIGNAL SIGWINCH

CMD ["apache2-foreground"]

# 添加标签和元数据
LABEL maintainer="PHP Docker Team" \
      version="1.0" \
      description="Optimized PHP with Apache2 runtime" \
      php.version="${PHP_VERSION}" \
      org.opencontainers.image.title="PHP-Apache Optimized" \
      org.opencontainers.image.description="Multi-stage optimized PHP with Apache2" \
      org.opencontainers.image.vendor="Your Organization" \
      org.opencontainers.image.licenses="MIT" 