# ==========================================
# RabbitMQ 生产级 Dockerfile (Alpine)
# ==========================================
# 基于官方 RabbitMQ Alpine 镜像构建
# 参考: https://github.com/docker-library/rabbitmq/blob/master/4.2/alpine/
# 默认启用 Management 插件（Web 管理面板）
# 支持国内镜像源加速、代理配置

ARG RABBITMQ_VERSION=4.2.5
ARG CHANGE_SOURCE=true

FROM rabbitmq:${RABBITMQ_VERSION}-management-alpine

ARG CHANGE_SOURCE
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG RABBITMQ_VERSION

LABEL maintainer="hg_dnmpr" \
      description="RabbitMQ with Management Plugin (Alpine)" \
      version="${RABBITMQ_VERSION}"

# 设置代理（如果需要）
# 代理仅作为构建参数参与 RUN 指令，不写入最终镜像。

# 配置 Alpine 镜像源（中国大陆加速）
RUN if [ "${CHANGE_SOURCE}" = "true" ]; then \
        sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories 2>/dev/null || true; \
    fi

# 安装常用工具
RUN apk add --no-cache \
    curl \
    ca-certificates \
    tzdata \
    iputils

# 启用常用插件
RUN rabbitmq-plugins enable --offline \
    rabbitmq_shovel \
    rabbitmq_shovel_management \
    rabbitmq_prometheus \
    && true

# 清除代理环境变量
ENV http_proxy="" \
    https_proxy="" \
    HTTP_PROXY="" \
    HTTPS_PROXY="" \
    no_proxy="" \
    NO_PROXY=""

EXPOSE 4369 5671 5672 15671 15672 15691 15692 25672

CMD ["rabbitmq-server"]
