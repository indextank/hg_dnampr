# ==========================================
# Redis 8.0+ 生产级 Dockerfile
# ==========================================
# 解决方案：使用官方基础镜像 + 精简模块构建
# 优化策略：
# 1. 避免复杂的模块编译（RedisJSON/RedisSearch等）
# 2. 使用稳定的 Debian 基础镜像
# 3. 配置国内镜像源加速
# 4. 非root用户运行增强安全性

# ARG REDIS_VERSION=8.0.1
ARG CHANGE_SOURCE=true

# ==========================================
# 构建阶段：编译 Redis
# ==========================================
FROM debian:bookworm-slim AS builder

ARG REDIS_VERSION
ARG CHANGE_SOURCE
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

# 设置代理（如果需要）
ENV http_proxy=${HTTP_PROXY}
ENV https_proxy=${HTTPS_PROXY}
ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTPS_PROXY}
ENV no_proxy=${NO_PROXY}
ENV NO_PROXY=${NO_PROXY}

ENV TMP_DIR=/tmp/extensions

# 设置环境变量
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    REDIS_VERSION=${REDIS_VERSION}

# 配置镜像源（中国大陆加速）
RUN if [ "${CHANGE_SOURCE}" = "true" ]; then \
        sed -i 's/deb.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list.d/debian.sources && \
        sed -i 's/security.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list.d/debian.sources; \
    fi

COPY ./src/redis/ ${TMP_DIR}
# 复制下载辅助脚本
COPY ./scripts/download-helper.sh /tmp/download-helper.sh

# 安装构建依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    curl \
    build-essential \
    gcc \
    g++ \
    libc6-dev \
    libssl-dev \
    make \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# 下载并编译 Redis（不包含复杂模块）
WORKDIR ${TMP_DIR}
RUN set -eux; \
    \
    cd ${TMP_DIR}; \
    \
    # 使用 bash 加载下载辅助脚本并执行下载
    bash -c '. /tmp/download-helper.sh && \
    if [ ! -f "redis-${REDIS_VERSION}.tar.gz" ]; then \
        download_if_missing "https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz" "redis-${REDIS_VERSION}.tar.gz" || \
        download_if_missing "https://github.com/redis/redis/archive/refs/tags/${REDIS_VERSION}.tar.gz" "redis-${REDIS_VERSION}.tar.gz" || { \
            echo "下载失败"; \
            exit 1; \
        }; \
    fi'; \
    \
    # 解压源码
    tar -xzf redis-${REDIS_VERSION}.tar.gz --strip-components=1; \
    rm redis-${REDIS_VERSION}.tar.gz; \
    \
    # 禁用保护模式（容器环境安全）
    grep -E '^ *createBoolConfig\("protected-mode",.*, *1 *,.*\),$' src/config.c; \
    sed -ri 's!^( *createBoolConfig\("protected-mode",.*, *)1( *,.*\),)$!\10\2!' src/config.c; \
    grep -E '^ *createBoolConfig\("protected-mode",.*, *0 *,.*\),$' src/config.c; \
    \
    # 编译 Redis（仅核心功能，跳过模块）
    export BUILD_TLS=yes; \
    make -j "$(nproc)" \
        PREFIX=/usr/local \
        MALLOC=jemalloc \
        BUILD_WITH_MODULES=no; \
    \
    # 安装 Redis
    make install; \
    \
    # 验证安装
    redis-server --version; \
    redis-cli --version

# ==========================================
# 运行阶段：精简镜像
# ==========================================
FROM debian:bookworm-slim

ARG CHANGE_SOURCE

# 设置环境变量
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    REDIS_USER=redis \
    REDIS_UID=999 \
    REDIS_GID=999

# 配置镜像源
RUN if [ "${CHANGE_SOURCE}" = "true" ]; then \
        sed -i 's/deb.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list.d/debian.sources && \
        sed -i 's/security.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list.d/debian.sources; \
    fi

# 安装运行时依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    tzdata \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# 创建 Redis 用户和目录
RUN groupadd -r -g ${REDIS_GID} ${REDIS_USER} && \
    useradd -r -g ${REDIS_USER} -u ${REDIS_UID} -d /data -s /bin/bash ${REDIS_USER} && \
    mkdir -p /data /var/log/redis && \
    chown -R ${REDIS_USER}:${REDIS_USER} /data /var/log/redis

# 从构建阶段复制 Redis 二进制文件
COPY --from=builder /usr/local/bin/redis* /usr/local/bin/

# 创建符号链接（Redis 传统做法）
RUN cd /usr/local/bin && \
    for file in redis-*; do \
        if [ "$file" != "redis-server" ]; then \
            ln -sf redis-server "$file"; \
        fi; \
    done

# 设置工作目录和权限
WORKDIR /data

# 健康检查
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD redis-cli ping || exit 1

# 暴露端口
EXPOSE 6379

# 创建启动脚本
COPY <<'EOF' /usr/local/bin/docker-entrypoint.sh
#!/bin/bash
set -e

# 如果以 root 运行，切换到 redis 用户
if [ "$(id -u)" = '0' ]; then
    # 确保数据目录权限正确
    chown -R redis:redis /data /var/log/redis
    
    # 切换到 redis 用户执行
    exec gosu redis "$0" "$@"
fi

# 如果没有提供配置文件，使用默认配置
if [ "$1" = 'redis-server' ] && [ ! -f "$2" ]; then
    # 生成基本配置
    cat > /tmp/redis.conf <<-'REDIS_CONF'
# Redis 8.0+ 基础配置
bind 0.0.0.0
port 6379
protected-mode no
tcp-backlog 511
timeout 0
tcp-keepalive 300

# 持久化配置
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /data

# 日志配置
loglevel notice
logfile /var/log/redis/redis-server.log
syslog-enabled no

# 内存管理
maxmemory-policy allkeys-lru
maxmemory-samples 5

# 安全配置
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command DEBUG ""
rename-command CONFIG ""

# 网络配置
tcp-keepalive 60
timeout 0
REDIS_CONF
    
    shift 2
    set -- "$1" /tmp/redis.conf "$@"
fi

exec "$@"
EOF

COPY ./build/redis/docker-entrypoint.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 设置入口点
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

EXPOSE 6379
CMD ["redis-server"]