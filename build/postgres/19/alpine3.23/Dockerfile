#
# NOTE: 基于本仓库 postgres/18/alpine3.23 适配逻辑，对齐 docker-library/postgres 19/alpine3.23
# （LLVM21、--with-libcurl/--with-liburing、world-bin、gosu）。
#

FROM alpine:3.23

ARG PG_VERSION
ARG ALPINE_REPOSITORIES
ARG CHANGE_SOURCE=false

ENV TMP_DIR=/tmp/extensions

# If you're in China, or you need to change sources, will be set CHANGE_SOURCE to true in .env.
RUN set -eux; \
    mkdir -p ${TMP_DIR}; \
    \
    if [ "${CHANGE_SOURCE}" = "true" ]; then \
        sed -i "s/dl-cdn.alpinelinux.org/${ALPINE_REPOSITORIES}/g" /etc/apk/repositories; \
        if ! apk update; then \
            echo "Mirror ${ALPINE_REPOSITORIES} unavailable, reverting to dl-cdn.alpinelinux.org"; \
            sed -i "s/${ALPINE_REPOSITORIES}/dl-cdn.alpinelinux.org/g" /etc/apk/repositories; \
            apk update; \
        fi; \
        apk add --no-cache tzdata; \
        cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime; \
        echo "Asia/Shanghai" > /etc/timezone; \
    fi;

# 70 is the standard uid/gid for "postgres" in Alpine
# https://git.alpinelinux.org/aports/tree/main/postgresql-common/postgresql-common.pre-install?h=3.22-stable
RUN set -eux; \
	addgroup -g 70 -S postgres; \
	adduser -u 70 -S -D -G postgres -H -h /var/lib/postgresql -s /bin/sh postgres; \
	# also create the postgres user's home directory with appropriate permissions
	# see https://github.com/docker-library/postgres/issues/274
	install --verbose --directory --owner postgres --group postgres --mode 1777 /var/lib/postgresql; \
	install --verbose --directory --owner postgres --group postgres --mode 3777 /run/postgresql

# grab gosu for easy step-down from root（官方 alpine 19 entrypoint 使用 gosu，不再用 su-exec）
# https://github.com/tianon/gosu/releases
ENV GOSU_VERSION=1.19

# 路径说明：本地缓存的 gosu 二进制放在 src/gosu/（与 bookworm 变体一致）
COPY ./src/gosu/gosu-amd64-${GOSU_VERSION} ${TMP_DIR}/
WORKDIR ${TMP_DIR}
RUN set -eux; \
	apk add --no-cache --virtual .gosu-deps \
		ca-certificates \
		dpkg \
		gnupg \
	; \
	\
	if [ -f "gosu-amd64-${GOSU_VERSION}" ]; then \
		cp -r "gosu-amd64-${GOSU_VERSION}" /usr/local/bin/gosu; \
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
	apk del --no-network .gosu-deps; \
	chmod +x /usr/local/bin/gosu; \
	gosu --version; \
	gosu nobody true

# make the "en_US.UTF-8" locale so postgres will be utf-8 enabled by default
# alpine doesn't require explicit locale-file generation
ENV LANG=en_US.utf8

# 安装 ping 工具，便于容器内执行网络连通性验证。
RUN apk add --no-cache iputils

RUN mkdir /docker-entrypoint-initdb.d

ENV PG_MAJOR=19

ENV DOCKER_PG_LLVM_DEPS=\
		llvm21-dev \
		clang21

COPY ./src/postgres/ ${TMP_DIR}
WORKDIR ${TMP_DIR}

RUN set -eux; \
	\
	cd ${TMP_DIR}; \
	\
	if [ ! -f postgresql-$PG_VERSION.tar.bz2 ]; then \
		wget --limit-rate=100M --tries=6 -c --no-check-certificate https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2; \
	fi; \
	\
	mv postgresql-$PG_VERSION.tar.bz2 postgresql.tar.bz2; \
	mkdir -p /usr/src/postgresql; \
	tar \
		--extract \
		--file postgresql.tar.bz2 \
		--directory /usr/src/postgresql \
		--strip-components 1 \
	; \
	rm postgresql.tar.bz2; \
	\
	apk add --no-cache --virtual .build-deps \
		$DOCKER_PG_LLVM_DEPS \
		bison \
		coreutils \
		dpkg-dev dpkg \
		flex \
		g++ \
		gcc \
		krb5-dev \
		libc-dev \
		libedit-dev \
		libxml2-dev \
		libxslt-dev \
		linux-headers \
		make \
		openldap-dev \
		openssl-dev \
		perl-dev \
		perl-ipc-run \
		perl-utils \
		python3-dev \
		tcl-dev \
		util-linux-dev \
		zlib-dev \
# https://www.postgresql.org/docs/15/install-procedure.html#CONFIGURE-OPTIONS-FEATURES
		icu-dev \
# https://www.postgresql.org/docs/18/install-make.html#CONFIGURE-OPTION-WITH-LZ4
		lz4-dev \
# https://www.postgresql.org/docs/18/install-make.html#CONFIGURE-OPTION-WITH-ZSTD
		zstd-dev \
# https://www.postgresql.org/docs/18/install-make.html#CONFIGURE-OPTION-WITH-LIBCURL
		curl-dev \
# https://www.postgresql.org/docs/18/install-make.html#CONFIGURE-OPTION-WITH-LIBURING
		liburing-dev \
	; \
	\
	cd /usr/src/postgresql; \
# update "DEFAULT_PGSOCKET_DIR" to "/run/postgresql" (matching Debian / official alpine 19)
	awk '$1 == "#define" && $2 == "DEFAULT_PGSOCKET_DIR" && $3 == "\"/tmp\"" { $3 = "\"/run/postgresql\""; print; next } { print }' src/include/pg_config_manual.h > src/include/pg_config_manual.h.new; \
	grep '/run/postgresql' src/include/pg_config_manual.h.new; \
	mv src/include/pg_config_manual.h.new src/include/pg_config_manual.h; \
	gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
# explicitly update autoconf config.guess and config.sub so they support more arches/libcs
	wget -O config/config.guess 'https://git.savannah.gnu.org/cgit/config.git/plain/config.guess?id=7d3d27baf8107b630586c962c057e22149653deb'; \
	wget -O config/config.sub 'https://git.savannah.gnu.org/cgit/config.git/plain/config.sub?id=7d3d27baf8107b630586c962c057e22149653deb'; \
	\
	export LLVM_CONFIG="/usr/lib/llvm21/bin/llvm-config"; \
	export CLANG=clang-21; \
	\
# configure options mostly copying Debian / docker-library postgres 19:
	./configure \
		--enable-option-checking=fatal \
		--build="$gnuArch" \
# "/usr/src/postgresql/src/backend/access/common/tupconvert.c:105: undefined reference to `libintl_gettext'"
#		--enable-nls \
		--enable-integer-datetimes \
		--enable-tap-tests \
# skip debugging info -- we want tiny size instead
#		--enable-debug \
		--disable-rpath \
		--with-uuid=e2fs \
		--with-pgport=5432 \
		--with-system-tzdata=/usr/share/zoneinfo \
		--prefix=/usr/local \
		--with-includes=/usr/local/include \
		--with-libraries=/usr/local/lib \
		--with-gssapi \
		--with-icu \
		--with-ldap \
		--with-libcurl \
		--with-liburing \
		--with-libxml \
		--with-libxslt \
		--with-llvm \
		--with-lz4 \
		--with-openssl \
#		--with-pam \
		--with-perl \
		--with-python \
		--with-tcl \
		--with-zstd \
	; \
	make -j "$(nproc)" world-bin; \
	make install-world-bin; \
	make -C contrib install; \
	\
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive /usr/local \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
# Remove plperl, plpython and pltcl dependencies by default to save image size
			| grep -v -e perl -e python -e tcl \
	)"; \
	apk add --no-cache --virtual .postgresql-rundeps \
		$runDeps \
		bash \
		tzdata \
		zstd \
# https://wiki.alpinelinux.org/wiki/Release_Notes_for_Alpine_3.16.0#ICU_data_split
		icu-data-full \
# nss_wrapper is not availble on ppc64le: "test case segfaults in ppc64le"
		$([ "$(apk --print-arch)" != 'ppc64le' ] && echo 'nss_wrapper') \
	; \
	apk del --no-network .build-deps; \
	cd /; \
	rm -rf \
		/usr/src/postgresql \
		/usr/local/share/doc \
		/usr/local/share/man \
		${TMP_DIR} \
	; \
	\
	postgres --version

# make the sample config easier to munge (and "correct by default")
RUN set -eux; \
	cp -v /usr/local/share/postgresql/postgresql.conf.sample /usr/local/share/postgresql/postgresql.conf.sample.orig; \
	sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" /usr/local/share/postgresql/postgresql.conf.sample; \
	grep -F "listen_addresses = '*'" /usr/local/share/postgresql/postgresql.conf.sample

# 官方 18+ 将 PGDATA 改为 /var/lib/postgresql/$PG_MAJOR/docker、VOLUME 改为 /var/lib/postgresql。
# 本仓库 Compose 仍挂载 ...:/var/lib/postgresql/data，故保留旧路径以兼容既有数据卷。
ENV PGDATA=/var/lib/postgresql/data
# this 1777 will be replaced by 0700 at runtime (allows semi-arbitrary "--user" values)
RUN mkdir -p "$PGDATA" && chown -R postgres:postgres "$PGDATA" && chmod 1777 "$PGDATA"
VOLUME /var/lib/postgresql/data

COPY ./build/postgres/19/alpine3.23/docker-entrypoint.sh /usr/local/bin/
COPY ./build/postgres/19/alpine3.23/docker-ensure-initdb.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-* \
    && ln -sT /usr/local/bin/docker-ensure-initdb.sh /usr/local/bin/docker-enforce-initdb.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# We set the default STOPSIGNAL to SIGINT, which corresponds to what PostgreSQL
# calls "Fast Shutdown mode" wherein new connections are disallowed and any
# in-progress transactions are aborted, allowing PostgreSQL to stop cleanly and
# flush tables to disk.
#
# See https://www.postgresql.org/docs/current/server-shutdown.html for more details
# about available PostgreSQL server shutdown signals.
#
# See also https://www.postgresql.org/docs/current/server-start.html for further
# justification of this as the default value, namely that the example (and
# shipped) systemd service files use the "Fast Shutdown mode" for service
# termination.
#
STOPSIGNAL SIGINT
#
# An additional setting that is recommended for all users regardless of this
# value is the runtime "--stop-timeout" (or your orchestrator/runtime's
# equivalent) for controlling how long to wait between sending the defined
# STOPSIGNAL and sending SIGKILL.
#
# The default in most runtimes (such as Docker) is 10 seconds, and the
# documentation at https://www.postgresql.org/docs/current/server-start.html notes
# that even 90 seconds may not be long enough in many instances.

EXPOSE 5432
CMD ["postgres"]
