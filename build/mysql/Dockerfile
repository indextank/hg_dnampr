FROM debian:bookworm-slim

ARG CHANGE_SOURCE=false
ARG MYSQL_VER
ARG GOSU_VERSION
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

ENV TMP_DIR=/tmp/extensions
ENV HTTP_PROXY=${HTTP_PROXY:-}
ENV HTTPS_PROXY=${HTTPS_PROXY:-}
ENV NO_PROXY=${NO_PROXY:-}

RUN set -eux; \
	mkdir -p ${TMP_DIR}; \
	\
	if [ ${CHANGE_SOURCE} = true ]; then \
		sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
	fi; \
    \
	# 关闭 HTTP Pipelining 特性，在 apt 2.1.9 及以后的版本中，apt 的 HTTP Pipelining 特性与 Nginx 服务器疑似存在一定的不兼容问题
	echo "Acquire::http::Pipeline-Depth \"0\";" > /etc/apt/apt.conf.d/99nopipelining; \
	\
	apt-get update; \
	apt-get install -y --assume-yes --no-install-recommends apt-transport-https ca-certificates; \
	apt-get update; \
	apt-get install -y --no-install-recommends gnupg dirmngr wget; \
  	rm -rf /var/lib/apt/lists/*; \
	groupadd -r mysql; \
	useradd -r -g mysql mysql

COPY ./src/mysql/ ${TMP_DIR}
WORKDIR ${TMP_DIR}

# add gosu for easy step-down from root
# https://github.com/tianon/gosu/releases
RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
	\
	cd "${TMP_DIR}"; \
	\
	if [ -f "gosu-amd64-${GOSU_VERSION}" ]; then \
    	cp -r gosu-amd64-${GOSU_VERSION} /usr/local/bin/gosu; \
	fi; \
	\
	if [ ! -f "/usr/local/bin/gosu" ]; then \
		dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
		wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
		wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
		export GNUPGHOME="$(mktemp -d)"; \
		gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
		gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
		gpgconf --kill all; \
		rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
	fi; \
	\
	apt-mark auto '.*' > /dev/null; \
	[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark > /dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	chmod +x /usr/local/bin/gosu; \
	gosu --version; \
	gosu nobody true

RUN mkdir /docker-entrypoint-initdb.d

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		bzip2 \
		openssl \
# FATAL ERROR: please install the following Perl modules before executing /usr/local/mysql/scripts/mysql_install_db:
# File::Basename
# File::Copy
# Sys::Hostname
# Data::Dumper
		perl \
		xz-utils \
		zstd \
	; \
	rm -rf /var/lib/apt/lists/*

RUN set -eux; \
# pub   rsa4096 2023-10-23 [SC] [expires: 2025-10-22]
#       BCA4 3417 C3B4 85DD 128E  C6D4 B7B3 B788 A8D3 785C
# uid           [ unknown] MySQL Release Engineering <mysql-build@oss.oracle.com>
# sub   rsa4096 2023-10-23 [E] [expires: 2025-10-22]
	mkdir -p /etc/apt/keyrings; \
	export GNUPGHOME="$(mktemp -d)"; \
	key_id='B7B3B788A8D3785C'; \
	key_full='BCA4 3417 C3B4 85DD 128E C6D4 B7B3 B788 A8D3 785C'; \
	key_imported=false; \
	# 方法1: 尝试从密钥服务器获取最新密钥（可能已更新） \
	for keyserver in hkps://keys.openpgp.org keyserver.ubuntu.com pgp.mit.edu keyserver.pgp.com; do \
		if gpg --batch --keyserver "$keyserver" --recv-keys "$key_id" 2>&1; then \
			# 导出密钥到文件 \
			if gpg --batch --export "$key_id" > /etc/apt/keyrings/mysql.gpg 2>&1; then \
				key_imported=true; \
				echo "MySQL GPG key imported from keyserver: $keyserver"; \
				break; \
			fi; \
		fi; \
	done; \
	# 方法2: 如果密钥服务器失败，尝试从 MySQL 官网下载 \
	if [ "$key_imported" = false ]; then \
		echo "Trying to download MySQL GPG key from official website"; \
		if wget -q -O /tmp/mysql_pubkey.asc https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 2>&1; then \
			# 检查是否为 ASCII 格式的 PGP 密钥 \
			if head -1 /tmp/mysql_pubkey.asc | grep -q "BEGIN PGP PUBLIC KEY BLOCK"; then \
				# 先导入到 GPG keyring，然后导出为二进制格式 \
				if gpg --batch --import /tmp/mysql_pubkey.asc 2>&1; then \
					if gpg --batch --export "$key_id" > /etc/apt/keyrings/mysql.gpg 2>&1; then \
						key_imported=true; \
						echo "MySQL GPG key imported from website and exported"; \
					fi; \
				fi; \
				# 如果导入失败，直接转换格式 \
				if [ "$key_imported" = false ]; then \
					gpg --dearmor < /tmp/mysql_pubkey.asc > /etc/apt/keyrings/mysql.gpg 2>&1 && \
					key_imported=true && \
					echo "MySQL GPG key converted from ASCII to binary format"; \
				fi; \
			else \
				# 如果已经是二进制格式，直接复制 \
				cp /tmp/mysql_pubkey.asc /etc/apt/keyrings/mysql.gpg && \
				key_imported=true && \
				echo "MySQL GPG key downloaded (already in binary format)"; \
			fi; \
			rm -f /tmp/mysql_pubkey.asc; \
		fi; \
	fi; \
	# 验证密钥文件是否存在且不为空 \
	if [ "$key_imported" = false ] || [ ! -s /etc/apt/keyrings/mysql.gpg ]; then \
		echo "Error: Failed to import or download MySQL GPG key"; \
		ls -la /etc/apt/keyrings/ || true; \
		exit 1; \
	fi; \
	# 设置正确的权限 \
	chmod 644 /etc/apt/keyrings/mysql.gpg; \
	gpgconf --kill all 2>/dev/null || true; \
	rm -rf "$GNUPGHOME"; \
	echo "MySQL GPG key file created successfully: $(ls -lh /etc/apt/keyrings/mysql.gpg)"

ENV MYSQL_MAJOR=8.0
ENV MYSQL_VERSION=${MYSQL_VER}-1debian12

RUN echo 'deb [ signed-by=/etc/apt/keyrings/mysql.gpg ] http://repo.mysql.com/apt/debian/ bookworm mysql-8.0' > /etc/apt/sources.list.d/mysql.list

# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
RUN { \
		echo mysql-community-server mysql-community-server/data-dir select ''; \
		echo mysql-community-server mysql-community-server/root-pass password ''; \
		echo mysql-community-server mysql-community-server/re-root-pass password ''; \
		echo mysql-community-server mysql-community-server/remove-test-db select false; \
	} | debconf-set-selections \
	&& apt-get update --allow-insecure-repositories \
	&& apt-get install -y --allow-unauthenticated \
		mysql-community-client="${MYSQL_VERSION}" \
		mysql-community-server-core="${MYSQL_VERSION}" \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm -rf /var/lib/mysql && mkdir -p /var/lib/mysql /var/run/mysqld \
	&& mkdir -p /var/lib/mysql-files /tmp \
	&& chown -R mysql:mysql /var/lib/mysql /var/run/mysqld /var/lib/mysql-files \
	&& chmod 750 /var/lib/mysql-files \
# ensure that /var/run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
	&& chmod 1777 /var/run/mysqld /var/lib/mysql \
	&& rm -fr ${TMP_DIR}

VOLUME /var/lib/mysql

# Config files
COPY ./conf/mysql/ /etc/mysql/
RUN chmod 644 /etc/mysql/conf.d/*.cnf \
    && chown root:root /etc/mysql/conf.d/*.cnf
COPY ./build/mysql/docker-entrypoint.sh /usr/local/bin/

RUN chmod 777 /usr/local/bin/docker-entrypoint.sh \
    && ln -s usr/local/bin/docker-entrypoint.sh /entrypoint.sh # backwards compat
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 3306 33060
CMD ["mysqld"]