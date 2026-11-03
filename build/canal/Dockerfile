# ==========================================
# Canal Server — 基于官方镜像注入项目配置
# ==========================================
# 上游: https://github.com/alibaba/canal/tree/master/docker
# 基础镜像: https://hub.docker.com/r/canal/canal-server
# 配置: 仓库 build/canal/config/（serverMode=rabbitMQ，对接本栈 rabbitmq 服务名）

ARG CANAL_VERSION=v1.1.8
FROM canal/canal-server:${CANAL_VERSION}

ARG CHANGE_SOURCE=false
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY

USER root

# 安装 ping（可选）：官方 osbase 为 CentOS 6，默认 yum 源常失效，需 CHANGE_SOURCE 切换 vault 镜像。
# 代理仅参与本 RUN，不写入最终镜像。
RUN set -ux; \
    export http_proxy="${HTTP_PROXY:-}" https_proxy="${HTTPS_PROXY:-${HTTP_PROXY:-}}"; \
    export HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-${HTTP_PROXY:-}}"; \
    export ALL_PROXY="${ALL_PROXY:-}" all_proxy="${ALL_PROXY:-}"; \
    export NO_PROXY="${NO_PROXY:-}" no_proxy="${NO_PROXY:-}"; \
    if [ "${CHANGE_SOURCE}" = "true" ]; then \
        if command -v apt-get >/dev/null 2>&1; then \
            sed -i 's@deb.debian.org@mirrors.aliyun.com@g' /etc/apt/sources.list 2>/dev/null || true; \
            sed -i 's@security.debian.org@mirrors.aliyun.com@g' /etc/apt/sources.list 2>/dev/null || true; \
        elif command -v apk >/dev/null 2>&1; then \
            sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories 2>/dev/null || true; \
        elif command -v yum >/dev/null 2>&1; then \
            for repo in /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-CR.repo; do \
                [ -f "$repo" ] || continue; \
                sed -i 's|^mirrorlist=|#mirrorlist=|g' "$repo" 2>/dev/null || true; \
                sed -i 's|^#baseurl=http://mirror.centos.org/centos/7/|baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/|g' "$repo" 2>/dev/null || true; \
            done; \
            yum clean all 2>/dev/null || true; \
        fi; \
    fi; \
    if command -v apt-get >/dev/null 2>&1; then \
        apt-get update && apt-get install -y --no-install-recommends iputils-ping \
        && rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null 2>&1; then \
        apk add --no-cache iputils; \
    elif command -v yum >/dev/null 2>&1; then \
        yum install -y iputils && yum clean all; \
    else \
        echo "未识别的基础系统，跳过 ping 工具安装"; \
    fi || echo "WARN: ping 工具安装失败，已跳过（不影响 Canal 运行）"

COPY ./build/canal/config/canal.properties /home/admin/canal-server/conf/canal.properties
COPY ./build/canal/config/example/instance.properties /home/admin/canal-server/conf/example/instance.properties

# app.sh 以 root 直接起进程（见 build/canal/app.sh）；需对数据与日志目录可写
RUN chown -R root:root /home/admin/canal-server \
    && sh -c 'for d in /home/admin/node_exporter /home/admin/node_exporter-*; do [ -e "$$d" ] && chown -R root:root "$$d"; done' || true

COPY ./build/canal/app.sh /home/admin/app.sh
RUN chmod 755 /home/admin/app.sh && chown root:root /home/admin/app.sh

# 清除构建阶段代理，避免写入运行镜像
ENV HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= http_proxy= https_proxy= all_proxy=

WORKDIR /home/admin
