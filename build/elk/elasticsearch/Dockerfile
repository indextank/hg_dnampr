################################################################################
# Build stage 1 `builder`:
# Extract Elasticsearch artifact
################################################################################

FROM debian:bullseye-slim AS builder

ARG CHANGE_SOURCE=false

ARG ELK_VERSION
ARG TINI_VERSION

ENV TMP_DIR=/tmp/extensions

RUN set -eux; \
	\
    mkdir -p ${TMP_DIR}; \
    mkdir -p /usr/share/elasticsearch; \
	\
	if [ ${CHANGE_SOURCE} = true ]; then \
		sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list; \
	fi; \
	\
    # 使用重试机制和多个失败恢复策略更新软件源
    apt-get update --fix-missing || (sleep 5 && apt-get update --fix-missing) || apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget

COPY ./src/elk/elasticsearch ${TMP_DIR}
WORKDIR ${TMP_DIR}

# `tini` is a tiny but valid init for containers. This is used to cleanly
# control how ES and any child processes are shut down.
#
# The tini GitHub page gives instructions for verifying the binary using
# gpg, but the keyservers are slow to return the key and this can fail the
# build. Instead, we check the binary against the published checksum.
RUN set -eux; \
    \
	cd "${TMP_DIR}"; \
	\
    case "$(arch)" in \
      aarch64) \
          TINI_BIN='tini-arm64'; \
          ;; \
      x86_64) \
          TINI_BIN='tini-amd64'; \
          ;; \
      *) echo >&2 "Unsupported architecture $(arch)" ; exit 1 ;; \
    esac ; \
    \
    if [ ! -f "${TINI_BIN}_${TINI_VERSION}" ]; then \
        wget --limit-rate=100M --tries=6 -c --no-check-certificate "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/${TINI_BIN}"; \
        wget --limit-rate=100M --tries=6 -c --no-check-certificate "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/${TINI_BIN}.sha256sum"; \
        sha256sum -c "${TINI_BIN}.sha256sum"; \
        rm "${TINI_BIN}.sha256sum"; \
        mv "${TINI_BIN}" /bin/tini; \
	else \
        mv ${TINI_BIN}_${TINI_VERSION} /bin/tini; \
    fi; \
    \
    chmod +x /bin/tini; \
    \
	if [ ! -f "elasticsearch-${ELK_VERSION}-linux-$(arch).tar.gz" ]; then \
        wget --limit-rate=100M --tries=6 -c --no-check-certificate "https://artifacts-no-kpi.elastic.co/downloads/elasticsearch/elasticsearch-${ELK_VERSION}-linux-$(arch).tar.gz"; \
	fi

WORKDIR /usr/share/elasticsearch

RUN tar -zxf ${TMP_DIR}/elasticsearch-${ELK_VERSION}-linux-$(arch).tar.gz --strip-components=1 && \
    rm -fr ${TMP_DIR}/*

# The distribution includes a `config` directory, no need to create it
COPY ./conf/elasticsearch/elasticsearch.yml config/
COPY ./conf/elasticsearch/log4j2.properties config/log4j2.docker.properties

#  1. Configure the distribution for Docker
#  2. Create required directory
#  3. Move the distribution's default logging config aside
#  4. Move the generated docker logging config so that it is the default
#  5. Reset permissions on all directories
#  6. Reset permissions on all files
#  7. Make CLI tools executable
#  8. Make some directories writable. `bin` must be writable because
#     plugins can install their own CLI utilities.
#  9. Make some files writable
RUN set -eux ; \
    sed -i -e 's/ES_DISTRIBUTION_TYPE=tar/ES_DISTRIBUTION_TYPE=docker/' bin/elasticsearch-env; \
    mkdir data; \
    mv config/log4j2.properties config/log4j2.file.properties; \
    mv config/log4j2.docker.properties config/log4j2.properties; \
    find . -type d -exec chmod 0755 {} +; \
    find . -type f -exec chmod 0644 {} +; \
    chmod 0755 bin/* jdk/bin/* jdk/lib/jspawnhelper modules/x-pack-ml/platform/linux-*/bin/*; \
    chmod 0775 bin config config/jvm.options.d data logs plugins; \
    find config -type f -exec chmod 0664 {} +




################################################################################
# Build stage 2 (the actual Elasticsearch image):
#
# Copy elasticsearch from stage 1
# Add entrypoint
################################################################################

FROM debian:bullseye-slim

ARG CHANGE_SOURCE=false
ARG ELASTICSEARCH_PLUGINS
ARG ELK_VERSION

ENV PLUGINS=",${ELASTICSEARCH_PLUGINS},"

# Change default shell to bash, then install required packages with retries.
RUN set -eux; \
	\
	if [ ${CHANGE_SOURCE} = true ]; then \
		sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list; \
	fi; \
	\
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update --fix-missing || (sleep 5 && apt-get update --fix-missing) || apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends ca-certificates curl netcat p11-kit unzip zip; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    \
    groupadd -g 1000 elasticsearch; \
    adduser --uid 1000 --gid 1000 --home /usr/share/elasticsearch elasticsearch; \
    adduser elasticsearch root; \
    chown -R 0:0 /usr/share/elasticsearch

ENV ELASTIC_CONTAINER=true

WORKDIR /usr/share/elasticsearch

COPY --from=builder --chown=0:0 /usr/share/elasticsearch /usr/share/elasticsearch
COPY --from=builder --chown=0:0 /bin/tini /bin/tini

ENV PATH=/usr/share/elasticsearch/bin:$PATH

COPY ./build/elk/elasticsearch/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY ./build/elk/elasticsearch/setup-kibana-password.sh /usr/local/bin/setup-kibana-password.sh

# 1. Sync the user and group permissions of /etc/passwd
# 2. Set correct permissions of the entrypoint
# 3. Ensure that there are no files with setuid or setgid, in order to mitigate "stackclash" attacks.
#    We've already run this in previous layers so it ought to be a no-op.
# 4. Replace OpenJDK's built-in CA certificate keystore with the one from the OS
#    vendor. The latter is superior in several ways.
#    REF: https://github.com/elastic/elasticsearch-docker/issues/171
# 5. Tighten up permissions on the ES home dir (the permissions of the contents are handled earlier)
# 6. You can't install plugins that include configuration when running as `elasticsearch` and the `config`
#    dir is owned by `root`, because the installed tries to manipulate the permissions on the plugin's
#    config directory.
RUN chmod g=u /etc/passwd && \
    chmod 0555 /usr/local/bin/docker-entrypoint.sh && \
    chmod 0755 /usr/local/bin/setup-kibana-password.sh && \
    chown root:root /usr/local/bin/setup-kibana-password.sh && \
    find / -xdev -perm -4000 -exec chmod ug-s {} + && \
    chmod 0775 /usr/share/elasticsearch && \
    chown elasticsearch bin config config/jvm.options.d data logs plugins

# Update "cacerts" bundle to use Ubuntu's CA certificates (and make sure it
# stays up-to-date with changes to Ubuntu's store)
COPY ./build/elk/elasticsearch/docker-openjdk /etc/ca-certificates/update.d/docker-openjdk
RUN chmod +x /etc/ca-certificates/update.d/docker-openjdk && \
    /etc/ca-certificates/update.d/docker-openjdk

RUN if [[ "${PLUGINS}" == *",amazon-ec2,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install amazon-ec2; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",analysis-icu,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install analysis-icu; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",analysis-kuromoji,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install analysis-kuromoji; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",analysis-nori,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install analysis-nori; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",analysis-phonetic,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install analysis-phonetic; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",analysis-smartcn,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install analysis-smartcn; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",analysis-stempel,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install analysis-stempel; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",analysis-ukrainian,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install analysis-ukrainian; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",discovery-azure-classic,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install discovery-azure-classic; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",discovery-ec2,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install discovery-ec2; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",discovery-file,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install discovery-file; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",discovery-gce,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install discovery-gce; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",google-cloud-storage,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install google-cloud-storage; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",ingest-attachment,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install ingest-attachment; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",ingest-geoip,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install ingest-geoip; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",ingest-user-agent,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install ingest-user-agent; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",mapper-murmur3,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install mapper-murmur3; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",mapper-size,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install mapper-size; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",microsoft-azure-storage,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install microsoft-azure-storage; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",qa,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install qa; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",repository-azure,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install repository-azure; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",repository-gcs,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install repository-gcs; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",repository-hdfs,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install repository-hdfs; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",repository-s3,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install repository-s3; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",store-smb,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install store-smb; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",analysis-ik,"* ]]; then \
        printf "y\n" | elasticsearch-plugin install https://github.com/medcl/elasticsearch-analysis-ik/releases/download/v${ELK_VERSION}/elasticsearch-analysis-ik-${ELK_VERSION}.zip; \
    fi \
    && \
    if [[ "${PLUGINS}" == *",analysis-pinyin,"* ]]; then \
      printf "y\n" | elasticsearch-plugin install https://github.com/medcl/elasticsearch-analysis-pinyin/releases/download/v${ELK_VERSION}/elasticsearch-analysis-pinyin-${ELK_VERSION}.zip; \
    fi

EXPOSE 9200 9300

# LABEL org.label-schema.build-date="2023-10-11T22:04:35.506990650Z" \
#   org.label-schema.license="Elastic-License-2.0" \
#   org.label-schema.name="Elasticsearch" \
#   org.label-schema.schema-version="1.0" \
#   org.label-schema.url="https://www.elastic.co/products/elasticsearch" \
#   org.label-schema.usage="https://www.elastic.co/guide/en/elasticsearch/reference/index.html" \
#   org.label-schema.vcs-ref="b4a62ac808e886ff032700c391f45f1408b2538c" \
#   org.label-schema.vcs-url="https://github.com/elastic/elasticsearch" \
#   org.label-schema.vendor="Elastic" \
#   org.label-schema.version="${ELK_VERSION}" \
#   org.opencontainers.image.created="2023-10-11T22:04:35.506990650Z" \
#   org.opencontainers.image.documentation="https://www.elastic.co/guide/en/elasticsearch/reference/index.html" \
#   org.opencontainers.image.licenses="Elastic-License-2.0" \
#   org.opencontainers.image.revision="b4a62ac808e886ff032700c391f45f1408b2538c" \
#   org.opencontainers.image.source="https://github.com/elastic/elasticsearch" \
#   org.opencontainers.image.title="Elasticsearch" \
#   org.opencontainers.image.url="https://www.elastic.co/products/elasticsearch" \
#   org.opencontainers.image.vendor="Elastic" \
#   org.opencontainers.image.version="${ELK_VERSION}"

# Our actual entrypoint is `tini`, a minimal but functional init program. It
# calls the entrypoint we provide, while correctly forwarding signals.
ENTRYPOINT ["/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
# Dummy overridable parameter parsed by entrypoint
CMD ["eswrapper"]

# 在最终阶段添加更完整的权限设置
RUN set -eux; \
    mkdir -p /usr/share/elasticsearch/logs; \
    chmod 0777 /usr/share/elasticsearch/logs; \
    chown -R elasticsearch:root /usr/share/elasticsearch/logs; \
    chmod -R 0777 /usr/share/elasticsearch/logs; \
    chown -R elasticsearch:root /usr/share/elasticsearch/data; \
    chmod -R 0777 /usr/share/elasticsearch/data; \
    chown -R elasticsearch:root /usr/share/elasticsearch/config; \
    chmod -R 0777 /usr/share/elasticsearch/config; \
    mkdir -p /usr/share/elasticsearch/config/certs; \
    chmod -R 0777 /usr/share/elasticsearch/config/certs; \
    chown -R elasticsearch:root /usr/share/elasticsearch/config/certs

USER 1000:0

################################################################################
# End of multi-stage Dockerfile
################################################################################
