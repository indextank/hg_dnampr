# 使用官方MongoDB镜像
# 参考：https://github.com/docker-library/mongo

# 设置构建参数
ARG MONGO_VERSION
ARG CHANGE_SOURCE=false

FROM debian:bookworm-slim

# 添加代理设置
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG CHANGE_SOURCE=false
# MONGO_VERSION 必须在 FROM 之后重新声明，否则 RUN 步骤无法获取该值
ARG MONGO_VERSION

# 代理仅作为构建参数参与 RUN 指令，不写入最终镜像。
# wget 不支持 socks5 代理，写入 wgetrc 禁用代理
RUN echo "use_proxy=off" > /etc/wgetrc

ENV TMP_DIR=/tmp/extensions

# 初始化用户、目录、apt 镜像源、apt 代理屏蔽
RUN set -eux; \
	\
	mkdir -p ${TMP_DIR}; \
	\
	if [ "${CHANGE_SOURCE:-false}" = "true" ]; then \
		sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
	fi; \
	# apt 不支持 socks5 代理，统一禁用 apt 的代理（镜像源直连）
	echo 'Acquire::http::Proxy "false";' > /etc/apt/apt.conf.d/99noproxy; \
	echo 'Acquire::https::Proxy "false";' >> /etc/apt/apt.conf.d/99noproxy; \
	\
	groupadd --gid 999 --system mongodb; \
	useradd --uid 999 --system --gid mongodb --home-dir /data/db mongodb; \
	mkdir -p /data/db /data/configdb; \
	chown -R mongodb:mongodb /data/db /data/configdb

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		ca-certificates \
		iputils-ping \
		jq \
		numactl \
		procps \
	; \
	rm -rf /var/lib/apt/lists/*

# 预置本地文件：gosu、js-yaml、MongoDB GPG key
# 构建容器内 HTTPS 外连不可靠，所有三方依赖均通过宏机预下载后 COPY 进入，避免构建时联网
COPY ./src/gosu/ ${TMP_DIR}/
COPY ./src/mongo/js-yaml-3.13.1.tgz ${TMP_DIR}/js-yaml-3.13.1.tgz
COPY ./src/mongo/server-8.0.asc ${TMP_DIR}/server-8.0.asc
WORKDIR ${TMP_DIR}

# grab gosu for easy step-down from root (https://github.com/tianon/gosu/releases)
ENV GOSU_VERSION=1.17
# grab "js-yaml" for parsing mongod's YAML config files (https://github.com/nodeca/js-yaml/releases)
ENV JSYAML_VERSION=3.13.1
ENV JSYAML_CHECKSUM=662e32319bdd378e91f67578e56a34954b0a2e33aca11d70ab9f4826af24b941

RUN set -eux; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	# 修复可能的 dpkg 损坏状态
	dpkg --configure -a 2>/dev/null || true; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		gnupg \
		curl \
	; \
	rm -rf /var/lib/apt/lists/*; \
	\
	cd "${TMP_DIR}"; \
	\
	# ── gosu ──────────────────────────────────────────────────────
	# 优先使用本地预置文件（CHANGE_SOURCE=true 或离线场景）
	if [ -f "gosu-amd64-${GOSU_VERSION}" ]; then \
		cp gosu-amd64-${GOSU_VERSION} /usr/local/bin/gosu; \
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
	# ── js-yaml ───────────────────────────────────────────────────
	# 使用本地预置文件（构建容器内无法访问 registry.npmjs.org）
	mkdir -p /opt/js-yaml/; \
	cp "${TMP_DIR}/js-yaml-${JSYAML_VERSION}.tgz" /opt/js-yaml/js-yaml.tgz; \
	echo "$JSYAML_CHECKSUM */opt/js-yaml/js-yaml.tgz" | sha256sum -c -; \
	tar -xz --strip-components=1 -f /opt/js-yaml/js-yaml.tgz -C /opt/js-yaml package/dist/js-yaml.js package/package.json; \
	rm /opt/js-yaml/js-yaml.tgz; \
	ln -s /opt/js-yaml/dist/js-yaml.js /js-yaml.js; \
	\
	# ── MongoDB PGP key ───────────────────────────────────────────
	# 使用本地预置文件（server-8.0.asc 由宏机预下载到 src/mongo/）
	# MongoDB 8.0 密钥指纹：4B0752C1BCA238C0B4EE14DC41DE058A4E7DCA05
	export GNUPGHOME="$(mktemp -d)"; \
	mkdir -p /etc/apt/keyrings; \
	cp "${TMP_DIR}/server-8.0.asc" KEYS; \
	gpg --batch --import KEYS; \
	# 从默认 keyring 导出到 apt trusted keyring
	gpg --batch --export 4B0752C1BCA238C0B4EE14DC41DE058A4E7DCA05 | \
		gpg --batch --no-default-keyring --keyring /etc/apt/keyrings/mongodb.gpg --import; \
	gpg --batch --no-default-keyring \
		--keyring /etc/apt/keyrings/mongodb.gpg \
		--export --armor 4B0752C1BCA238C0B4EE14DC41DE058A4E7DCA05 > /etc/apt/keyrings/mongodb.asc; \
	chmod 644 /etc/apt/keyrings/mongodb.asc; \
	rm -rf "$GNUPGHOME" KEYS; \
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark > /dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	\
	# smoke test
	chmod +x /usr/local/bin/gosu; \
	gosu --version; \
	gosu nobody true

RUN mkdir /docker-entrypoint-initdb.d

# Allow build-time overrides (eg. to build image with MongoDB Enterprise version)
# Options for MONGO_PACKAGE: mongodb-org OR mongodb-enterprise
# Options for MONGO_REPO: repo.mongodb.org OR repo.mongodb.com
ARG MONGO_PACKAGE=mongodb-org
ARG MONGO_REPO=repo.mongodb.org
ENV MONGO_PACKAGE=${MONGO_PACKAGE} MONGO_REPO=${MONGO_REPO}

ENV MONGO_MAJOR=8.0

# CHANGE_SOURCE=true 时使用清华镜像源加速（国内访问官方 repo.mongodb.org 慢）
# 清华：https://mirrors.tuna.tsinghua.edu.cn/mongodb/apt/debian
# 阿里云：https://mirrors.aliyun.com/mongodb/apt/debian
RUN if [ "${CHANGE_SOURCE:-false}" = "true" ]; then \
		echo "deb [ signed-by=/etc/apt/keyrings/mongodb.asc ] https://mirrors.tuna.tsinghua.edu.cn/mongodb/apt/debian bookworm/${MONGO_PACKAGE}/${MONGO_MAJOR} main" \
			| tee "/etc/apt/sources.list.d/${MONGO_PACKAGE}-${MONGO_MAJOR}.list"; \
	else \
		echo "deb [ signed-by=/etc/apt/keyrings/mongodb.asc ] http://${MONGO_REPO}/apt/debian bookworm/${MONGO_PACKAGE}/${MONGO_MAJOR} main" \
			| tee "/etc/apt/sources.list.d/${MONGO_PACKAGE}-${MONGO_MAJOR}.list"; \
	fi

RUN set -x \
	&& echo "MONGO_VERSION is: $MONGO_VERSION" \
	&& export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y \
		${MONGO_PACKAGE}${MONGO_VERSION:+=$MONGO_VERSION} \
		${MONGO_PACKAGE}-server${MONGO_VERSION:+=$MONGO_VERSION} \
		${MONGO_PACKAGE}-mongos${MONGO_VERSION:+=$MONGO_VERSION} \
		mongodb-mongosh${MONGO_VERSION:+=$MONGO_VERSION} \
		mongodb-database-tools${MONGO_VERSION:+=$MONGO_VERSION} \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm -rf /var/lib/mongodb \
	&& mv /etc/mongod.conf /etc/mongod.conf.orig

VOLUME /data/db /data/configdb

# ensure that if running as custom user that "mongosh" has a valid "HOME"
# https://github.com/docker-library/mongo/issues/524
ENV HOME=/data/db

# ensure that glibc isn't using rseq so that google-tcmalloc can
# https://www.mongodb.com/docs/manual/administration/tcmalloc-performance/#disable-glibc-rseq
ENV GLIBC_TUNABLES=glibc.pthread.rseq=0

COPY ./build/mongo/8.0/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# 清理构建代理变量，避免代理配置进入运行容器。
ENV HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= http_proxy= https_proxy= all_proxy= NO_PROXY= no_proxy=

EXPOSE 27017
CMD ["mongod"]
