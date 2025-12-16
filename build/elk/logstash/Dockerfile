# This Dockerfile was generated from templates/Dockerfile.j2

FROM debian:bullseye-slim

ARG CHANGE_SOURCE=false
ARG ELK_VERSION

ENV TMP_DIR=/tmp/extensions

RUN set -eux; \
	\
    mkdir -p ${TMP_DIR}; \
	\
	if [ ${CHANGE_SOURCE} = true ]; then \
		sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list; \
	fi; \
	\
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update --fix-missing || (sleep 5 && apt-get update --fix-missing) || apt-get update; \
    apt-get install -y procps findutils locales tar gzip curl wget; \
    apt-get clean all; \
    locale-gen 'en_US.UTF-8' || true; \
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 || true; \
    apt-get clean metadata; \
    apt-get clean all

COPY ./src/elk/logstash ${TMP_DIR}
# 复制下载辅助脚本
COPY ./scripts/download-helper.sh /tmp/download-helper.sh

WORKDIR ${TMP_DIR}

RUN set -eux; \
    \
	cd "${TMP_DIR}"; \
	\
	# 使用 bash 加载下载辅助脚本并执行下载
	bash -c '. /tmp/download-helper.sh && \
	download_if_missing "https://artifacts.elastic.co/downloads/logstash/logstash-${ELK_VERSION}-linux-$(arch).tar.gz" "logstash-${ELK_VERSION}-linux-$(arch).tar.gz" || { \
		echo "下载失败"; \
		exit 1; \
	}'; \
	\
    mkdir -p /usr/share; \
    tar zxf ${TMP_DIR}/logstash-${ELK_VERSION}-linux-$(arch).tar.gz -C /usr/share/; \
    rm -fr ${TMP_DIR}/*.tar.gz; \
    mv /usr/share/logstash-${ELK_VERSION} /usr/share/logstash; \
    \
    # Provide a non-root user to run the process.
    groupadd --gid 1000 logstash; \
    adduser --uid 1000 --gid 1000 --home /usr/share/logstash --no-create-home logstash; \
    \
    chown --recursive logstash:logstash /usr/share/logstash/; \
    chown -R logstash:root /usr/share/logstash; \
    chmod -R g=u /usr/share/logstash; \
    mkdir /licenses/; \
    mv /usr/share/logstash/NOTICE.TXT /licenses/NOTICE.TXT; \
    mv /usr/share/logstash/LICENSE.txt /licenses/LICENSE.txt; \
    find /usr/share/logstash -type d -exec chmod g+s {} \;

WORKDIR /usr/share/logstash

ENV ELASTIC_CONTAINER=true
ENV PATH=/usr/share/logstash/bin:$PATH

# Provide a minimal configuration, so that simple invocations will provide
# a good experience.
COPY ./conf/logstash/pipelines.yml config/pipelines.yml
COPY ./conf/logstash/logstash.yml config/logstash.yml
COPY ./conf/logstash/log4j2.properties config/
COPY ./conf/logstash/log4j2.file.properties config/
COPY ./conf/logstash/conf.d/default.conf pipeline/logstash.conf

RUN chown --recursive logstash:root config/ pipeline/ && \
    chmod -R 664 config/*.yml config/*.properties config/*.conf && \
    chmod -R 664 pipeline/*.conf && \
    chmod -R 775 config/ pipeline/

# Ensure Logstash gets the correct locale by default.
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

COPY ./build/elk/logstash/env2yaml /usr/local/bin/

# Place the startup wrapper script.
COPY ./build/elk/logstash/docker-entrypoint /usr/local/bin/

RUN chmod 0755 /usr/local/bin/docker-entrypoint && \
    chmod 0755 /usr/local/bin/env2yaml

# Ensure config directory and files are writable
RUN chmod -R 775 /usr/share/logstash/config && \
    chmod 664 /usr/share/logstash/config/*.yml && \
    chmod 664 /usr/share/logstash/config/*.properties && \
    chown -R logstash:logstash /usr/share/logstash/config

USER 1000

EXPOSE 9600 5044

# LABEL  org.label-schema.schema-version="1.0" \
#   org.label-schema.vendor="Elastic" \
#   org.opencontainers.image.vendor="Elastic" \
#   org.label-schema.name="logstash" \
#   org.opencontainers.image.title="logstash" \
#   org.label-schema.version="${ELK_VERSION}" \
#   org.opencontainers.image.version="${ELK_VERSION}" \
#   org.label-schema.url="https://www.elastic.co/products/logstash" \
#   org.label-schema.vcs-url="https://github.com/elastic/logstash" \
#   org.label-schema.license="Elastic License" \
#   org.opencontainers.image.licenses="Elastic License" \
#   org.opencontainers.image.description="Logstash is a free and open server-side data processing pipeline that ingests data from a multitude of sources, transforms it, and then sends it to your favorite 'stash.'" \
#   org.label-schema.build-date=2023-10-10T17:45:22+00:00 \
# org.opencontainers.image.created=2023-10-10T17:45:22+00:00

ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
