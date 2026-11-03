FROM debian:bookworm-slim

ARG CHANGE_SOURCE=false
ARG MYSQL_VER
# latest：始终装通道 Candidate；prefer：优先 MYSQL_VER；exact：必须命中
ARG MYSQL_PIN_POLICY=latest
# GPG 公钥全部导入失败时是否允许降级为 trusted=yes（不校验签名，存在供应链风险，默认禁止）
ARG MYSQL_ALLOW_INSECURE_APT=false
ARG GOSU_VERSION
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

ENV TMP_DIR=/tmp/extensions
# 代理仅作为构建参数参与 RUN 指令，不写入最终镜像。
# wget 不支持 socks5 代理，写入 wgetrc 禁用代理（wget 走直连，curl/gpg 仍可用 socks5）
RUN echo "use_proxy=off" > /etc/wgetrc

RUN set -eux; \
	mkdir -p ${TMP_DIR}; \
	\
	if [ ${CHANGE_SOURCE} = true ]; then \
		sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
	fi; \
    \
	# 关闭 HTTP Pipelining 特性，在 apt 2.1.9 及以后的版本中，apt 的 HTTP Pipelining 特性与 Nginx 服务器疑似存在一定的不兼容问题
	echo "Acquire::http::Pipeline-Depth \"0\";" > /etc/apt/apt.conf.d/99nopipelining; \
	# apt 不支持 socks5 代理，统一禁用 apt 的代理（镜像源直连）
	echo 'Acquire::http::Proxy "false";' > /etc/apt/apt.conf.d/99noproxy; \
	echo 'Acquire::https::Proxy "false";' >> /etc/apt/apt.conf.d/99noproxy; \
	\
	apt-get update; \
	apt-get install -y --assume-yes --no-install-recommends apt-transport-https ca-certificates; \
	apt-get update; \
	apt-get install -y --no-install-recommends gnupg dirmngr curl; \
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
		curl -fsSL -o /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
		curl -fsSL -o /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
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
		iputils-ping \
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

# 禁用 IPv6 优先解析，减少 ping 外网域名时因 AAAA 路径异常导致的长时间等待
RUN set -eux; \
	if [ -f /etc/gai.conf ]; then \
		sed -ri 's/^#(precedence ::ffff:0:0\/96[[:space:]]+100)/\1/' /etc/gai.conf || true; \
		sed -ri 's/^#(label ::ffff:0:0\/96[[:space:]]+4)/\1/' /etc/gai.conf || true; \
	else \
		{ \
			echo 'precedence ::ffff:0:0/96  100'; \
			echo 'label ::ffff:0:0/96  4'; \
		} > /etc/gai.conf; \
	fi

RUN set -eux; \
# pub   rsa4096 2023-10-23 [SC] [expires: 2027-10-23]
#       BCA4 3417 C3B4 85DD 128E  C6D4 B7B3 B788 A8D3 785C
# uid           [ unknown] MySQL Release Engineering <mysql-build@oss.oracle.com>
# sub   rsa4096 2023-10-23 [E] [expires: 2027-10-23]
	mkdir -p /etc/apt/keyrings; \
	export GNUPGHOME="$(mktemp -d)"; \
	key_id='B7B3B788A8D3785C'; \
	key_imported=false; \
	# 方法0: 优先使用构建上下文中预置的本地密钥文件（src/mysql/mysql.gpg 或 mysql_pubkey.asc） \
	if [ -f "${TMP_DIR}/mysql.gpg" ]; then \
		cp "${TMP_DIR}/mysql.gpg" /etc/apt/keyrings/mysql.gpg; \
		key_imported=true; \
		echo "MySQL GPG key copied from local bundled binary file"; \
	elif [ -f "${TMP_DIR}/mysql_pubkey.asc" ]; then \
		if gpg --batch --import "${TMP_DIR}/mysql_pubkey.asc" 2>&1; then \
			if gpg --batch --export "$key_id" > /etc/apt/keyrings/mysql.gpg 2>&1; then \
				key_imported=true; \
				echo "MySQL GPG key imported from local bundled ASC file"; \
			fi; \
		fi; \
		if [ "$key_imported" = false ]; then \
			gpg --dearmor < "${TMP_DIR}/mysql_pubkey.asc" > /etc/apt/keyrings/mysql.gpg 2>&1 && \
			key_imported=true && \
			echo "MySQL GPG key converted from local bundled ASC file"; \
		fi; \
	fi; \
	# 方法1: 尝试从密钥服务器获取最新密钥 \
	if [ "$key_imported" = false ]; then \
		for keyserver in hkps://keys.openpgp.org keyserver.ubuntu.com pgp.mit.edu keyserver.pgp.com; do \
			if gpg --batch --keyserver "$keyserver" --recv-keys "$key_id" 2>&1; then \
				if gpg --batch --export "$key_id" > /etc/apt/keyrings/mysql.gpg 2>&1; then \
					key_imported=true; \
					echo "MySQL GPG key imported from keyserver: $keyserver"; \
					break; \
				fi; \
			fi; \
		done; \
	fi; \
	# 方法2: 如果密钥服务器失败，尝试从 MySQL 官网下载 \
	if [ "$key_imported" = false ]; then \
		echo "Trying to download MySQL GPG key from official website"; \
		if curl -fsSL -o /tmp/mysql_pubkey.asc https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 2>&1; then \
			if head -1 /tmp/mysql_pubkey.asc | grep -q "BEGIN PGP PUBLIC KEY BLOCK"; then \
				if gpg --batch --import /tmp/mysql_pubkey.asc 2>&1; then \
					if gpg --batch --export "$key_id" > /etc/apt/keyrings/mysql.gpg 2>&1; then \
						key_imported=true; \
						echo "MySQL GPG key imported from website and exported"; \
					fi; \
				fi; \
				if [ "$key_imported" = false ]; then \
					gpg --dearmor < /tmp/mysql_pubkey.asc > /etc/apt/keyrings/mysql.gpg 2>&1 && \
					key_imported=true && \
					echo "MySQL GPG key converted from ASCII to binary format"; \
				fi; \
			else \
				cp /tmp/mysql_pubkey.asc /etc/apt/keyrings/mysql.gpg && \
				key_imported=true && \
				echo "MySQL GPG key downloaded (already in binary format)"; \
			fi; \
			rm -f /tmp/mysql_pubkey.asc; \
		fi; \
	fi; \
	gpgconf --kill all 2>/dev/null || true; \
	rm -rf "$GNUPGHOME"; \
	# 所有方法失败时降级为 trusted=yes 模式（写入标记文件，下一步据此调整 sources.list） \
	if [ "$key_imported" = false ] || [ ! -s /etc/apt/keyrings/mysql.gpg ]; then \
		rm -f /etc/apt/keyrings/mysql.gpg; \
		if [ "${MYSQL_ALLOW_INSECURE_APT}" != "true" ]; then \
			echo "ERROR: Failed to import MySQL GPG key via all methods. 可将公钥放到 src/mysql/mysql_pubkey.asc 离线导入，或显式设置 MYSQL_ALLOW_INSECURE_APT=true（不推荐）" >&2; \
			exit 1; \
		fi; \
		echo "WARNING: MYSQL_ALLOW_INSECURE_APT=true, falling back to trusted=yes mode (package signatures NOT verified)"; \
		rm -f /etc/apt/keyrings/mysql.gpg; \
		touch /tmp/mysql-skip-gpg; \
	else \
		chmod 644 /etc/apt/keyrings/mysql.gpg; \
		echo "MySQL GPG key file created successfully: $(ls -lh /etc/apt/keyrings/mysql.gpg)"; \
	fi

ENV MYSQL_MAJOR=8.4
# 请求版本（可能因 apt 索引滚动而回退）；实际安装版本见 /etc/mysql/mysql_pkg_version
ENV MYSQL_VERSION=${MYSQL_VER}-1debian12
ENV MYSQL_PIN_POLICY=${MYSQL_PIN_POLICY}

RUN if [ -f /tmp/mysql-skip-gpg ]; then \
		echo "WARNING: Using trusted=yes mode (GPG key import failed at build time)"; \
		# 注意：官方仓库中 8.4 的组件名为 mysql-8.4-lts（非 mysql-8.4）
		echo 'deb [ trusted=yes ] http://repo.mysql.com/apt/debian/ bookworm mysql-8.4-lts' > /etc/apt/sources.list.d/mysql.list; \
	else \
		echo 'deb [ signed-by=/etc/apt/keyrings/mysql.gpg ] http://repo.mysql.com/apt/debian/ bookworm mysql-8.4-lts' > /etc/apt/sources.list.d/mysql.list; \
	fi

# Oracle apt 索引常只保留通道当前版本；由 apt-install-community.sh 按 MYSQL_PIN_POLICY 解析
COPY ./build/mysql/apt-install-community.sh /tmp/apt-install-community.sh
# 在安装层前重新声明 ARG，避免 BuildKit 作用域导致空值
ARG MYSQL_VER
ARG MYSQL_PIN_POLICY=latest
# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
RUN { \
		echo mysql-community-server mysql-community-server/data-dir select ''; \
		echo mysql-community-server mysql-community-server/root-pass password ''; \
		echo mysql-community-server mysql-community-server/re-root-pass password ''; \
		echo mysql-community-server mysql-community-server/remove-test-db select false; \
	} | debconf-set-selections \
	&& apt-get update $( [ -f /tmp/mysql-skip-gpg ] && echo --allow-insecure-repositories ) \
	&& MYSQL_VER="${MYSQL_VER}" MYSQL_PIN_POLICY="${MYSQL_PIN_POLICY}" \
		sh /tmp/apt-install-community.sh \
	&& rm -f /tmp/apt-install-community.sh \
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
# 只复制基础配置文件（my.cnf + docker.cnf），不复制整个 build/mysql/8.4/config/ 目录。
# 环境差异化配置由 compose 挂到 /etc/mysql/mount-src/，entrypoint 再复制为 mode 644
# 的正式文件——避免 WSL/Windows 9p 把 777 文件直接挂到 MySQL 读取路径导致
# “World-writable config file ... is ignored”。
#
# 必须先拆除 Debian alternatives 软链（my.cnf → alternatives → my.cnf.fallback），
# 否则 COPY/bind-mount 到 /etc/mysql/my.cnf 会落到 fallback，客户端仍报 world-writable。
RUN rm -f /etc/mysql/my.cnf \
    && mkdir -p /etc/mysql/conf.d /etc/mysql/mount-src \
    && chmod 755 /etc/mysql/mount-src
COPY ./build/mysql/8.4/config/my.cnf /etc/mysql/my.cnf
COPY ./build/mysql/8.4/config/conf.d/docker.cnf /etc/mysql/conf.d/docker.cnf
# 清理包自带 conf.d；预创建日志文件（MySQL 8.0+ 不会自动创建缺失日志文件）
RUN rm -f /etc/mysql/conf.d/mysql.cnf \
    && test -f /etc/mysql/my.cnf && test ! -L /etc/mysql/my.cnf \
    && chmod 644 /etc/mysql/my.cnf /etc/mysql/conf.d/docker.cnf \
    && chown root:root /etc/mysql/my.cnf /etc/mysql/conf.d/docker.cnf \
    && mkdir -p /var/log/mysql \
    && touch /var/log/mysql/error.log /var/log/mysql/slow.log \
    && chown -R mysql:mysql /var/log/mysql \
    && chmod 640 /var/log/mysql/error.log /var/log/mysql/slow.log
COPY ./build/mysql/8.4/docker-entrypoint.sh /usr/local/bin/

RUN chmod 777 /usr/local/bin/docker-entrypoint.sh \
    && ln -s usr/local/bin/docker-entrypoint.sh /entrypoint.sh # backwards compat

# 构建阶段可能通过 --build-arg 注入代理；勿写入最终镜像，否则容器内 curl 会误连 127.0.0.1
ENV HTTP_PROXY=
ENV HTTPS_PROXY=
ENV ALL_PROXY=
ENV http_proxy=
ENV https_proxy=
ENV all_proxy=
ENV FTP_PROXY=
ENV ftp_proxy=

ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 3306 33060
CMD ["mysqld"]
