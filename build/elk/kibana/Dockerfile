################################################################################
# Build stage 0 `builder`:
# Extract Kibana artifact
################################################################################

FROM debian:bullseye-slim AS builder

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
  # 使用重试机制更新软件源
  apt-get update --fix-missing || (sleep 5 && apt-get update --fix-missing) || apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y wget

COPY ./src/elk/kibana ${TMP_DIR}

WORKDIR ${TMP_DIR}

RUN set -eux; \
	\
	cd "${TMP_DIR}"; \
	\
	if [ ! -f "kibana-${ELK_VERSION}-linux-$(arch).tar.gz" ]; then \
        wget --limit-rate=100M --tries=6 -c --no-check-certificate "https://artifacts.elastic.co/downloads/kibana/kibana-${ELK_VERSION}-linux-$(arch).tar.gz"; \
	fi; \
  \
  mkdir -p /usr/share/kibana


WORKDIR /usr/share/kibana

RUN tar --strip-components=1 -zxf ${TMP_DIR}/kibana-${ELK_VERSION}-linux-$(arch).tar.gz && \
    chmod -R g=u /usr/share/kibana && \
    rm -fr ${TMP_DIR}/*




################################################################################
# Build stage 1 (the actual Kibana image):
#
# Copy kibana from stage 0
# Add entrypoint
################################################################################

FROM debian:bullseye-slim

ARG CHANGE_SOURCE=false
ARG ELK_VERSION
ARG TINI_VERSION

ENV TMP_DIR=/tmp/extensions

EXPOSE 5601

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
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends fontconfig fonts-liberation libnss3 libfontconfig1 ca-certificates curl; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

COPY ./src/elk/kibana ${TMP_DIR}

# Add an init process, check the checksum to make sure it's a match
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
  mkdir /usr/share/fonts/local; \
  \
	if [ ! -f "NotoSansCJK-Regular.ttc" ]; then \
        curl --retry 8 -S -L -o /usr/share/fonts/local/NotoSansCJK-Regular.ttc https://github.com/googlefonts/noto-cjk/raw/NotoSansV2.001/NotoSansCJK-Regular.ttc; \
        echo "5dcd1c336cc9344cb77c03a0cd8982ca8a7dc97d620fd6c9c434e02dcb1ceeb3  /usr/share/fonts/local/NotoSansCJK-Regular.ttc" | sha256sum -c -; \
	fi; \
  \
  cp -r NotoSansCJK-Regular.ttc /usr/share/fonts/local/; \
  fc-cache -v; \
  rm -fr ${TMP_DIR}/*

# Bring in Kibana from the initial stage.
COPY --from=builder --chown=1000:0 /usr/share/kibana /usr/share/kibana

WORKDIR /usr/share/kibana
# RUN ln -s /usr/share/kibana /opt/kibana

ENV ELASTIC_CONTAINER=true
ENV PATH=/usr/share/kibana/bin:$PATH

# Set some Kibana configuration defaults.
COPY --chown=1000:0 ./conf/kibana/kibana.yml /usr/share/kibana/config/kibana.yml

# Add the launcher/wrapper script. It knows how to interpret environment
# variables and translate them to Kibana CLI options.
COPY ./build/elk/kibana/kibana-docker /usr/local/bin/

# Set execute permissions for the kibana-docker script
RUN chmod 0755 /usr/local/bin/kibana-docker

# Ensure gid 0 write permissions for OpenShift.
RUN chmod g+ws /usr/share/kibana && \
    find /usr/share/kibana -gid 0 -and -not -perm /g+w -exec chmod g+w {} \; && \
# Remove the suid bit everywhere to mitigate "Stack Clash"
    find / -xdev -perm -4000 -exec chmod u-s {} + && \
# Provide a non-root user to run the process.
    groupadd --gid 1000 kibana && \
    useradd --uid 1000 --gid 1000 -G 0 \
      --home-dir /usr/share/kibana --no-create-home \
      kibana

# LABEL org.label-schema.build-date="2023-10-11T20:06:54.391Z" \
#   org.label-schema.license="Elastic License" \
#   org.label-schema.name="Kibana" \
#   org.label-schema.schema-version="1.0" \
#   org.label-schema.url="https://www.elastic.co/products/kibana" \
#   org.label-schema.usage="https://www.elastic.co/guide/en/kibana/reference/index.html" \
#   org.label-schema.vcs-ref="976088dd04c6fd3b907fd2bb92af306e7d77ce4c" \
#   org.label-schema.vcs-url="https://github.com/elastic/kibana" \
#   org.label-schema.vendor="Elastic" \
#   org.label-schema.version="${ELK_VERSION}" \
#   org.opencontainers.image.created="2023-10-11T20:06:54.391Z" \
#   org.opencontainers.image.documentation="https://www.elastic.co/guide/en/kibana/reference/index.html" \
#   org.opencontainers.image.licenses="Elastic License" \
#   org.opencontainers.image.revision="976088dd04c6fd3b907fd2bb92af306e7d77ce4c" \
#   org.opencontainers.image.source="https://github.com/elastic/kibana" \
#   org.opencontainers.image.title="Kibana" \
#   org.opencontainers.image.url="https://www.elastic.co/products/kibana" \
#   org.opencontainers.image.vendor="Elastic" \
#   org.opencontainers.image.version="${ELK_VERSION}"


ENTRYPOINT ["/bin/tini", "--"]


CMD ["/usr/local/bin/kibana-docker"]


USER kibana
