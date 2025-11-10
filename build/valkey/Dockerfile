FROM alpine:3.21

# 添加代理设置
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

# 设置代理环境变量
ENV http_proxy=${HTTP_PROXY}
ENV https_proxy=${HTTPS_PROXY}
ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTPS_PROXY}
ENV no_proxy=${NO_PROXY}
ENV NO_PROXY=${NO_PROXY}

ARG VALKEY_VERSION
ARG ALPINE_REPOSITORIES
ARG CHANGE_SOURCE=false

ENV TMP_DIR=/tmp/extensions

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN set -eux; \
# alpine already has a gid 999, so we'll use the next id
	addgroup -S -g 1000 valkey; \
	adduser -S -G valkey -u 999 valkey

# runtime dependencies
RUN set -eux; \
    mkdir -p ${TMP_DIR}; \
    \
    if [ ${CHANGE_SOURCE} = true ]; then \
        sed -i "s/dl-cdn.alpinelinux.org/${ALPINE_REPOSITORIES}/g" /etc/apk/repositories; \
        apk update; \
        # grab su-exec for easy step-down from root
        apk add --no-cache tzdata setpriv; \
        cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime; \
        echo "Asia/Shanghai" > /etc/timezone; \
    fi;

ENV TMP_DIR=/tmp/extensions

ENV VALKEY_DOWNLOAD_URL=https://github.com/valkey-io/valkey/archive/refs/tags/${VALKEY_VERSION}.tar.gz
# ENV VALKEY_DOWNLOAD_SHA=3355fbd5458d853ab201d2c046ffca9f078000587ccbe9a6c585110f146ad2c5

COPY ./src/valkey/ ${TMP_DIR}
WORKDIR ${TMP_DIR}

RUN set -eux; \
	\
	apk add --no-cache --virtual .build-deps \
		coreutils \
		dpkg-dev dpkg \
		gcc \
		g++ \
		linux-headers \
		make \
		musl-dev \
		openssl-dev \
# install real "wget" to avoid:
#   + wget -O valkey.tar.gz https://download.valkey.io/releases/valkey-6.0.6.tar.gz
#   Connecting to download.valkey.io (45.60.121.1:80)
#   wget: bad header line:     XxhODalH: btu; path=/; Max-Age=900
		wget \
	; \
	\
	# wget -O valkey.tar.gz "$VALKEY_DOWNLOAD_URL"; \
	# 		echo "$VALKEY_DOWNLOAD_SHA *valkey.tar.gz" | sha256sum -c -; \
	cd ${TMP_DIR}; \
    \
    if [ ! -f "valkey-${VALKEY_VERSION}.tar.gz" ]; then \
        curl -L "$REDIS_DOWNLOAD_URL" -o valkey-${VALKEY_VERSION}.tar.gz; \
    fi; \
    \
	mkdir -p /usr/src/valkey; \
	# tar -xzf valkey.tar.gz -C /usr/src/valkey --strip-components=1; \
	# rm valkey.tar.gz; \
	tar -xzf valkey-${VALKEY_VERSION}.tar.gz -C /usr/src/valkey --strip-components=1; \
	rm valkey-${VALKEY_VERSION}.tar.gz; \
	\
# disable Valkey protected mode [1] as it is unnecessary in context of Docker
# (ports are not automatically exposed when running inside Docker, but rather explicitly by specifying -p / -P)
	grep -E '^ *createBoolConfig[(]"protected-mode",.*, *1 *,.*[)],$' /usr/src/valkey/src/config.c; \
	sed -ri 's!^( *createBoolConfig[(]"protected-mode",.*, *)1( *,.*[)],)$!\10\2!' /usr/src/valkey/src/config.c; \
	grep -E '^ *createBoolConfig[(]"protected-mode",.*, *0 *,.*[)],$' /usr/src/valkey/src/config.c; \
# for future reference, we modify this directly in the source instead of just supplying a default configuration flag because apparently "if you specify any argument to valkey-server, [it assumes] you are going to specify everything"
# (more exactly, this makes sure the default behavior of "save on SIGTERM" stays functional by default)
	\
# https://github.com/jemalloc/jemalloc/issues/467 -- we need to patch the "./configure" for the bundled jemalloc to match how Debian compiles, for compatibility
# (also, we do cross-builds, so we need to embed the appropriate "--build=xxx" values to that "./configure" invocation)
	gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
	extraJemallocConfigureFlags="--build=$gnuArch"; \
# https://salsa.debian.org/debian/jemalloc/-/blob/c0a88c37a551be7d12e4863435365c9a6a51525f/debian/rules#L8-23
	dpkgArch="$(dpkg --print-architecture)"; \
	case "${dpkgArch##*-}" in \
		amd64 | i386 | x32) extraJemallocConfigureFlags="$extraJemallocConfigureFlags --with-lg-page=12" ;; \
		*) extraJemallocConfigureFlags="$extraJemallocConfigureFlags --with-lg-page=16" ;; \
	esac; \
	extraJemallocConfigureFlags="$extraJemallocConfigureFlags --with-lg-hugepage=21"; \
	grep -F 'cd jemalloc && ./configure ' /usr/src/valkey/deps/Makefile; \
	sed -ri 's!cd jemalloc && ./configure !&'"$extraJemallocConfigureFlags"' !' /usr/src/valkey/deps/Makefile; \
	grep -F "cd jemalloc && ./configure $extraJemallocConfigureFlags " /usr/src/valkey/deps/Makefile; \
	\
	echo "Version 8.1.1 is 8.1 or higher - enabling USE_FAST_FLOAT"; \
			export BUILD_TLS=yes USE_FAST_FLOAT=yes; \
	make -C /usr/src/valkey -j "$(nproc)" all; \
	make -C /usr/src/valkey install; \
	\
	serverMd5="$(md5sum /usr/local/bin/valkey-server | cut -d' ' -f1)"; export serverMd5; \
	find /usr/local/bin/valkey* -maxdepth 0 \
		-type f -not -name valkey-server \
		-exec sh -eux -c ' \
			md5="$(md5sum "$1" | cut -d" " -f1)"; \
			test "$md5" = "$serverMd5"; \
		' -- '{}' ';' \
		-exec ln -svfT 'valkey-server' '{}' ';' \
	; \
	\
	rm -r /usr/src/valkey; \
	\
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive /usr/local \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)"; \
	apk add --no-network --virtual .valkey-rundeps $runDeps; \
	apk del --no-network .build-deps; \
	\
	valkey-cli --version; \
	valkey-server --version; \
	\
	echo '{"spdxVersion":"SPDX-2.3","SPDXID":"SPDXRef-DOCUMENT","name":"valkey-server-sbom","packages":[{"name":"valkey-server","versionInfo":"8.1.1","SPDXID":"SPDXRef-Package--valkey-server","externalRefs":[{"referenceCategory":"PACKAGE-MANAGER","referenceType":"purl","referenceLocator":"pkg:generic/valkey-server@8.1.1?os_name=alpine&os_version=3.21"}],"licenseDeclared":"BSD-3-Clause"}]}' > /usr/local/valkey.spdx.json

RUN mkdir /data && chown valkey:valkey /data
VOLUME /data
WORKDIR /data

COPY ./build/valkey/docker-entrypoint.sh /usr/local/bin/
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 6379
CMD ["valkey-server"]