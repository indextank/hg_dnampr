FROM debian:bookworm-slim

# 添加代理设置
ARG http_proxy
ARG https_proxy
ARG no_proxy

ARG CHANGE_SOURCE=false
ARG MYSQL_VER
ARG BOOST_VER
ARG GOSU_VERSION

ENV TMP_DIR=/tmp/extensions
ENV MYSQL_INSTALL_DIR=/usr/local/mysql

RUN set -eux; \
	\
	if [ "${CHANGE_SOURCE:-false}" = "true" ]; then \
		sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
	fi; \
	\
	apt-get update; \
	apt-get install -y --assume-yes --no-install-recommends apt-transport-https ca-certificates; \
	apt-get install -y --no-install-recommends gnupg dirmngr gcc g++ make cmake libtinfo5 libssl-dev libreadline-dev pkg-config xz-utils libaio1 libaio-dev libnuma-dev; \
  	rm -rf /var/lib/apt/lists/*; \
	groupadd -r mysql; \
	useradd -r -g mysql mysql; \
	mkdir -p ${TMP_DIR}; \
	mkdir -p ${MYSQL_INSTALL_DIR}

COPY ./src/mysql/ ${TMP_DIR}
WORKDIR ${TMP_DIR}

# add gosu for easy step-down from root
# https://github.com/tianon/gosu/releases
RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends wget; \
	rm -rf /var/lib/apt/lists/*; \
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

RUN set -eux; \
	mkdir /docker-entrypoint-initdb.d; \
	\
	cd ${TMP_DIR}; \
	\
	apt-get update; \
	apt-get install -y --no-install-recommends wget; \
	\
	if [ ! -f mysql-${MYSQL_VER}-linux-glibc2.28-x86_64.tar.xz ]; then \
		wget --limit-rate=100M --tries=6 -c --no-check-certificate https://cdn.mysql.com//Downloads/MySQL-8.0/mysql-${MYSQL_VER}-linux-glibc2.28-x86_64.tar.xz; \
	fi; \
	\
	chmod +x mysql-${MYSQL_VER}-linux-glibc2.28-x86_64.tar.xz; \
	tar xJf mysql-${MYSQL_VER}-linux-glibc2.28-x86_64.tar.xz; \
    mv mysql-${MYSQL_VER}-linux-glibc2.28-x86_64/* ${MYSQL_INSTALL_DIR}; \
	rm -fr ${MYSQL_INSTALL_DIR}/bin/mysqld-debug; \
	\
	if [ -d "${MYSQL_INSTALL_DIR}/support-files" ]; then \
		sed -i 's@executing mysqld_safe@executing mysqld_safe\nexport LD_PRELOAD=/usr/local/lib/libjemalloc.so@' ${MYSQL_INSTALL_DIR}/bin/mysqld_safe; \
	fi; \
	\
	ln -sf /usr/local/mysql/bin/mysqld /usr/sbin/mysqld; \
	/bin/cp ${MYSQL_INSTALL_DIR}/support-files/mysql.server /etc/init.d/mysqld; \
	sed -i "s@^basedir=.*@basedir=${MYSQL_INSTALL_DIR}@" /etc/init.d/mysqld; \
  	sed -i "s@^datadir=.*@datadir=/var/lib/mysql/@" /etc/init.d/mysqld; \
  	chmod +x /etc/init.d/mysqld; \
	ln -sf /usr/local/mysql/bin/* /usr/bin/; \
	[ ! -d "/etc/mysql" ] && mkdir -p /etc/mysql/conf.d; \
	rm -rf /var/lib/apt/lists/*; \
	rm -fr ${TMP_DIR}/*

# Config files
COPY ./conf/mysql/ /etc/mysql/
RUN chmod 644 /etc/mysql/conf.d/*.cnf \
    && chown root:root /etc/mysql/conf.d/*.cnf
COPY ./build/mysql/docker-entrypoint.sh /usr/local/bin/

RUN chmod 777 /usr/local/bin/docker-entrypoint.sh \
    && ln -s /usr/local/bin/docker-entrypoint.sh /

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

EXPOSE 3306
CMD ["mysqld"]