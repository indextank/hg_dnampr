FROM debian:bookworm-slim

# 添加代理设置
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

# 代理仅作为构建参数参与 RUN 指令，不写入最终镜像。
# wget 不支持 socks5 代理，写入 wgetrc 禁用代理
RUN echo "use_proxy=off" > /etc/wgetrc

ARG PG_VERSION
ARG PG_PIN_POLICY=latest
ARG CHANGE_SOURCE=false

ENV TMP_DIR=/tmp/extensions

# explicitly set user/group IDs
RUN set -eux; \
	\
	mkdir -p ${TMP_DIR}; \
	\
	if [ ${CHANGE_SOURCE} = true ]; then \
		sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
	fi; \
	\
	# apt 不支持 socks5 代理，统一禁用 apt 的代理（镜像源直连）
	echo 'Acquire::http::Proxy "false";' > /etc/apt/apt.conf.d/99noproxy; \
	echo 'Acquire::https::Proxy "false";' >> /etc/apt/apt.conf.d/99noproxy; \
	\
	groupadd -r postgres --gid=999; \
	# https://salsa.debian.org/postgresql/postgresql-common/blob/997d842ee744687d99a2b2d95c1083a2615c79e8/debian/postgresql-common.postinst#L32-35
	useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
	# also create the postgres user's home directory with appropriate permissions
	# see https://github.com/docker-library/postgres/issues/274
	install --verbose --directory --owner postgres --group postgres --mode 1777 /var/lib/postgresql

RUN set -ex; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		gnupg \
# https://www.postgresql.org/docs/16/app-psql.html#APP-PSQL-META-COMMAND-PSET-PAGER
# https://github.com/postgres/postgres/blob/REL_16_1/src/include/fe_utils/print.h#L25
# (if "less" is available, it gets used as the default pager for psql, and it only adds ~1.5MiB to our image size)
		less \
	; \
	rm -rf /var/lib/apt/lists/*

# grab gosu for easy step-down from root
# https://github.com/tianon/gosu/releases
ENV GOSU_VERSION=1.19

# 路径说明：本地缓存的 gosu 二进制放在 src/gosu/ 子目录（与 mongo/mysql 服务保持一致）
# 拷贝到 ${TMP_DIR} 后由下方 RUN 步骤优先使用本地文件，缺失时回退到 GitHub 下载。
COPY ./src/gosu/gosu-amd64-${GOSU_VERSION} ${TMP_DIR}/
WORKDIR ${TMP_DIR}
RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
	# 此前 RUN echo "use_proxy=off" > /etc/wgetrc 已在 /etc/wgetrc 预置了自定义配置，
	# apt-get install wget 会触发 conffile 冲突提示；非交互式构建中 debconf 读不到 stdin 就会报错。
	# DEBIAN_FRONTEND=noninteractive 让 debconf 走默认动作，--force-confold 保留现有 wgetrc。
	DEBIAN_FRONTEND=noninteractive apt-get update; \
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		-o Dpkg::Options::="--force-confdef" \
		-o Dpkg::Options::="--force-confold" \
		ca-certificates wget iputils-ping; \
	rm -rf /var/lib/apt/lists/*; \
	\
	cd "${TMP_DIR}"; \
	\
	if [ -f "gosu-amd64-${GOSU_VERSION}" ]; then \
    	cp -r gosu-amd64-${GOSU_VERSION} /usr/local/bin/gosu; \
		rm -fr ${TMP_DIR}; \
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

# make the "en_US.UTF-8" locale so postgres will be utf-8 enabled by default
RUN set -eux; \
	if [ -f /etc/dpkg/dpkg.cfg.d/docker ]; then \
# if this file exists, we're likely in "debian:xxx-slim", and locales are thus being excluded so we need to remove that exclusion (since we need locales)
		grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \
		sed -ri '/\/usr\/share\/locale/d' /etc/dpkg/dpkg.cfg.d/docker; \
		! grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \
	fi; \
	apt-get update; apt-get install -y --no-install-recommends locales; rm -rf /var/lib/apt/lists/*; \
	echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen; \
	locale-gen; \
	locale -a | grep 'en_US.utf8'
ENV LANG=en_US.utf8

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		libnss-wrapper \
		xz-utils \
		zstd \
	; \
	rm -rf /var/lib/apt/lists/*

RUN mkdir /docker-entrypoint-initdb.d

# 路径说明：PGDG 公钥预置在 src/postgres/pgdg-key.asc（与 src/gosu/ 本地兜底策略一致）。
# 受限网络下 keyserver.ubuntu.com 不可达，改用本地 COPY 导入，避开 keyserver 拉取。
COPY ./src/postgres/pgdg-key.asc /usr/local/share/keyrings/postgres.gpg.asc

ENV PG_MAJOR=18
ENV PATH=$PATH:/usr/lib/postgresql/$PG_MAJOR/bin
ENV PG_PIN_POLICY=${PG_PIN_POLICY}

# PGDG 版本由宿主机 derive_pg_build_ver 解析后传入；缺失时 apt-install-pgdg.sh 装 Candidate
COPY ./build/postgres/apt-install-pgdg.sh /tmp/apt-install-pgdg.sh
ARG PG_VERSION
ARG PG_PIN_POLICY=latest

RUN set -ex; \
	\
# see note below about "*.pyc" files
	export PYTHONDONTWRITEBYTECODE=1; \
	\
	dpkgArch="$(dpkg --print-architecture)"; \
	# 受限网络下 apt.postgresql.org 不可达，CHANGE_SOURCE=true 时使用阿里云 PGDG 镜像
	# 注意：阿里云 PGDG HTTP 镜像必须使用 [trusted=yes]，否则 apt-get update 会因无法校验 InRelease 签名而失败。
	# 参考：https://mirrors.aliyun.com/postgresql/repos/apt/
	# 官方源仍使用 signed-by 进行 GPG 签名校验。
	if [ "${CHANGE_SOURCE}" = true ]; then \
		aptRepo="[trusted=yes] http://mirrors.aliyun.com/postgresql/repos/apt/ bookworm-pgdg main ${PG_MAJOR}"; \
	else \
		aptRepo="[ signed-by=/usr/local/share/keyrings/postgres.gpg.asc ] http://apt.postgresql.org/pub/repos/apt/ bookworm-pgdg main ${PG_MAJOR}"; \
	fi; \
	case "$dpkgArch" in \
		amd64 | arm64 | ppc64el) \
# arches officialy built by upstream
			echo "deb $aptRepo" > /etc/apt/sources.list.d/pgdg.list; \
			apt-get update; \
			;; \
		*) \
# we're on an architecture upstream doesn't officially build for
# let's build binaries from their published source packages
			echo "deb-src $aptRepo" > /etc/apt/sources.list.d/pgdg.list; \
			\
			savedAptMark="$(apt-mark showmanual)"; \
			\
			tempDir="$(mktemp -d)"; \
			cd "$tempDir"; \
			\
# create a temporary local APT repo to install from (so that dependency resolution can be handled by APT, as it should be)
			apt-get update; \
			apt-get install -y --no-install-recommends dpkg-dev; \
			echo "deb [ trusted=yes ] file://$tempDir ./" > /etc/apt/sources.list.d/temp.list; \
			_update_repo() { \
				dpkg-scanpackages . > Packages; \
# work around the following APT issue by using "Acquire::GzipIndexes=false" (overriding "/etc/apt/apt.conf.d/docker-gzip-indexes")
#   Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
#   ...
#   E: Failed to fetch store:/var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages  Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
				apt-get -o Acquire::GzipIndexes=false update; \
			}; \
			_update_repo; \
			\
# build .deb files from upstream's source packages (which are verified by apt-get)
			nproc="$(nproc)"; \
			export DEB_BUILD_OPTIONS="nocheck parallel=$nproc"; \
# we have to build postgresql-common first because postgresql-$PG_MAJOR shares "debian/rules" logic with it: https://salsa.debian.org/postgresql/postgresql/-/commit/99f44476e258cae6bf9e919219fa2c5414fa2876
# (and it "Depends: pgdg-keyring")
			apt-get build-dep -y postgresql-common pgdg-keyring; \
			apt-get source --compile postgresql-common pgdg-keyring; \
			_update_repo; \
			_pg_ver="${PG_VERSION}"; \
			if [ -z "$_pg_ver" ] || [ "$_pg_ver" = "latest" ]; then \
				_pg_ver="$(apt-cache policy postgresql-$PG_MAJOR | awk '/Candidate:/ { print $2; exit }')"; \
			fi; \
			apt-get build-dep -y "postgresql-$PG_MAJOR=$_pg_ver"; \
			apt-get source --compile "postgresql-$PG_MAJOR=$_pg_ver"; \
			\
# we don't remove APT lists here because they get re-downloaded and removed later
			\
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
# (which is done after we install the built packages so we don't have to redownload any overlapping dependencies)
			apt-mark showmanual | xargs apt-mark auto > /dev/null; \
			apt-mark manual $savedAptMark; \
			\
			ls -lAFh; \
			_update_repo; \
			grep '^Package: ' Packages; \
			cd /; \
			;; \
	esac; \
	\
	apt-get install -y --no-install-recommends postgresql-common; \
	sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf; \
	PG_MAJOR="${PG_MAJOR}" PG_VERSION="${PG_VERSION}" PG_PIN_POLICY="${PG_PIN_POLICY}" \
		sh /tmp/apt-install-pgdg.sh; \
	rm -f /tmp/apt-install-pgdg.sh; \
	\
	rm -rf /var/lib/apt/lists/*; \
	\
	if [ -n "$tempDir" ]; then \
# if we have leftovers from building, let's purge them (including extra, unnecessary build deps)
		apt-get purge -y --auto-remove; \
		rm -rf "$tempDir" /etc/apt/sources.list.d/temp.list; \
	fi; \
	\
# some of the steps above generate a lot of "*.pyc" files (and setting "PYTHONDONTWRITEBYTECODE" beforehand doesn't propagate properly for some reason), so we clean them up manually (as long as they aren't owned by a package)
	find /usr -name '*.pyc' -type f -exec bash -c 'for pyc; do dpkg -S "$pyc" &> /dev/null || rm -vf "$pyc"; done' -- '{}' +; \
	\
	postgres --version

# make the sample config easier to munge (and "correct by default")
RUN set -eux; \
	dpkg-divert --add --rename --divert "/usr/share/postgresql/postgresql.conf.sample.dpkg" "/usr/share/postgresql/$PG_MAJOR/postgresql.conf.sample"; \
	cp -v /usr/share/postgresql/postgresql.conf.sample.dpkg /usr/share/postgresql/postgresql.conf.sample; \
	ln -sv ../postgresql.conf.sample "/usr/share/postgresql/$PG_MAJOR/"; \
	sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" /usr/share/postgresql/postgresql.conf.sample; \
	grep -F "listen_addresses = '*'" /usr/share/postgresql/postgresql.conf.sample

RUN install --verbose --directory --owner postgres --group postgres --mode 3777 /var/run/postgresql

ENV PGDATA=/var/lib/postgresql/data
# this 1777 will be replaced by 0700 at runtime (allows semi-arbitrary "--user" values)
RUN install --verbose --directory --owner postgres --group postgres --mode 1777 "$PGDATA"
VOLUME /var/lib/postgresql/data

COPY ./build/postgres/18/bookworm/docker-entrypoint.sh /usr/local/bin/
COPY ./build/postgres/18/bookworm/docker-ensure-initdb.sh /usr/local/bin/
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

# 清理构建代理变量，避免代理配置进入运行容器。
ENV HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= http_proxy= https_proxy= all_proxy= NO_PROXY= no_proxy=

EXPOSE 5432
CMD ["postgres"]
