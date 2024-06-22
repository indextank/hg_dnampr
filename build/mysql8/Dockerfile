FROM debian:bullseye-slim

ARG CHANGE_SOURCE=false
ARG MYSQL_VER
ARG BOOST_VER
ARG GOSU_VERSION
ARG MYSQL_DATA_DIR

ENV TMP_DIR /tmp/extensions
ENV MYSQL_INSTALL_DIR=/usr/local/mysql

RUN set -eux; \
	mkdir -p ${TMP_DIR}; \
	\
	if [ ${CHANGE_SOURCE} = true ]; then \
		sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list; \
	fi; \
	\
	apt-get update; \
	apt-get install -y --assume-yes --no-install-recommends apt-transport-https ca-certificates; \
	cp -r /etc/apt/sources.list /etc/apt/sources.list.bak; \
	apt-get install -y --no-install-recommends gnupg dirmngr gcc g++ make cmake libssl-dev libreadline-dev pkg-config xz-utils libaio1 libaio-dev libnuma-dev; \
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
	dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
	\
	cd "${TMP_DIR}"; \
	\
	if [ -f "gosu-amd64-${GOSU_VERSION}" ]; then \
    	cp -r gosu-amd64-${GOSU_VERSION} /usr/local/bin/gosu; \
	fi; \
	\
	if [ ! -f "/usr/local/bin/gosu" ]; then \
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
	cd ${TMP_DIR}; \
	\
	if [ ! -f mysql-${MYSQL_VER}-linux-glibc2.12-x86_64.tar.xz ]; then \
		wget --limit-rate=100M --tries=6 -c --no-check-certificate https://cdn.mysql.com//Downloads/MySQL-8.0/mysql-${MYSQL_VER}-linux-glibc2.12-x86_64.tar.xz; \
	fi; \
	\
	chmod +x mysql-${MYSQL_VER}-linux-glibc2.12-x86_64.tar.xz; \
	tar xJf mysql-${MYSQL_VER}-linux-glibc2.12-x86_64.tar.xz; \
    mv mysql-${MYSQL_VER}-linux-glibc2.12-x86_64/* ${MYSQL_INSTALL_DIR}; \
	rm -fr ${MYSQL_INSTALL_DIR}/bin/mysqld-debug; \
	# tar xzf mysql-boost-${MYSQL_VER}.tar.gz; \
	# cd mysql-${MYSQL_VER}; \
	# [ -e "/usr/bin/cmake3" ] && CMAKE=cmake3 || CMAKE=cmake; \
	# $CMAKE . -DCMAKE_INSTALL_PREFIX=${MYSQL_INSTALL_DIR} -DMYSQL_DATADIR=${MYSQL_DATA_DIR} -DWITH_BOOST=../boost/boost_${BOOST_VER} -DDOWNLOAD_BOOST=1 -DFORCE_INSOURCE_BUILD=1 -DSYSCONFDIR=/etc -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DWITH_BLACKHOLE_STORAGE_ENGINE=1 -DWITH_MYISAM_STORAGE_ENGINE=1 -DENABLED_LOCAL_INFILE=1 -DFORCE_INSOURCE_BUILD=1 -DCMAKE_C_COMPILER=/usr/bin/gcc -DCMAKE_CXX_COMPILER=/usr/bin/g++ -DDEFAULT_CHARSET=utf8mb4; \
    # make -j 4; \
    # make install; \
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
COPY ./conf/mysql/my.cnf /etc/mysql/
COPY ./conf/mysql/conf.d/* /etc/mysql/conf.d/
COPY ./build/mysql/docker-entrypoint.sh /usr/local/bin/

RUN chmod 777 /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

EXPOSE 3306 3306
CMD ["mysqld"]