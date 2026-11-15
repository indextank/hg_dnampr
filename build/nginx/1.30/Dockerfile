# 使用debian:bookworm-slim作为基础镜像
FROM debian:bookworm-slim


ARG NGINX_VERSION
ARG HMNM_VERSION
ARG CHANGE_SOURCE=false
ARG OPENSSL_VERSION
ARG PCRE_VERSION
ARG NGX_BROTLI_VERSION
ARG NGX_ZSTD_VERSION
ARG NGINX_ENABLE_BROTLI=true
ARG NGINX_ENABLE_ZSTD=true

ENV TMP_DIR=/tmp/extensions

# 安装必要的工具和依赖
RUN set -eux; \
    if [ "${CHANGE_SOURCE:-false}" = "true" ]; then \
        sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
    fi; \
    apt-get update && \
    apt-get install -y \
    build-essential \
    wget \
    curl \
    libpcre3 \
    libpcre3-dev \
    zlib1g \
    zlib1g-dev \
    libssl-dev \
    gnupg1 \
    ca-certificates \
    iputils-ping \
    vim \
    gettext-base; \
    # 根据压缩模块开关安装对应的开发库
    if [ "${NGINX_ENABLE_BROTLI:-true}" = "true" ]; then \
        apt-get install -y libbrotli-dev; \
    fi; \
    if [ "${NGINX_ENABLE_ZSTD:-true}" = "true" ]; then \
        apt-get install -y libzstd-dev; \
    fi

# 复制下载辅助脚本
COPY ./include/shell/download-helper.sh /tmp/download-helper.sh

# 预先将宏机已备好的源码包拷贝进来（避免在容器内从网络下载，提升构建速度）
# 若宏机对应文件不存在，COPY 会失败导致构建中断；请通过 ./build.sh nginx 构建（会自动切换 .dockerignore）
COPY ./src/nginx/nginx-${NGINX_VERSION}.tar.gz ${TMP_DIR}/nginx-${NGINX_VERSION}.tar.gz
COPY ./src/openssl/openssl-${OPENSSL_VERSION}.tar.gz ${TMP_DIR}/openssl-${OPENSSL_VERSION}.tar.gz
COPY ./src/nginx/pcre-${PCRE_VERSION}.tar.gz ${TMP_DIR}/pcre-${PCRE_VERSION}.tar.gz
COPY ./src/nginx/headers-more-nginx-module-${HMNM_VERSION}.tar.gz ${TMP_DIR}/headers-more-nginx-module-${HMNM_VERSION}.tar.gz
COPY ./src/nginx/ngx_brotli-${NGX_BROTLI_VERSION}.tar.gz ${TMP_DIR}/ngx_brotli-${NGX_BROTLI_VERSION}.tar.gz
COPY ./src/nginx/zstd-nginx-module-${NGX_ZSTD_VERSION}.tar.gz ${TMP_DIR}/zstd-nginx-module-${NGX_ZSTD_VERSION}.tar.gz
WORKDIR ${TMP_DIR}

ENV RUN_USER=nginx

# 将构建时压缩模块开关传递到运行时，供入口脚本生成压缩配置
ENV NGINX_ENABLE_BROTLI=${NGINX_ENABLE_BROTLI}
ENV NGINX_ENABLE_ZSTD=${NGINX_ENABLE_ZSTD}

RUN set -eux; \
    # 创建nginx用户和组
    groupadd --system --gid 101 ${RUN_USER}; \
    useradd --system --gid ${RUN_USER} --no-create-home --home /nonexistent --comment "nginx user" --shell /bin/false --uid 101 ${RUN_USER}; \
    \
    export MC="-j$(nproc)"; \
    \
    cd ${TMP_DIR}; \
    \
    # 使用 bash 加载下载辅助脚本并执行下载
    bash -c '. /tmp/download-helper.sh && \
    parallel_download \
        "nginx-${NGINX_VERSION}.tar.gz:https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
        "openssl-${OPENSSL_VERSION}.tar.gz:https://openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" \
        "pcre-${PCRE_VERSION}.tar.gz:https://ftp.exim.org/pub/pcre/pcre-${PCRE_VERSION}.tar.gz" \
        "headers-more-nginx-module-${HMNM_VERSION}.tar.gz:https://github.com/openresty/headers-more-nginx-module/archive/v${HMNM_VERSION}.tar.gz" \
        "ngx_brotli-${NGX_BROTLI_VERSION}.tar.gz:https://github.com/google/ngx_brotli/archive/v${NGX_BROTLI_VERSION}.tar.gz" \
        "zstd-nginx-module-${NGX_ZSTD_VERSION}.tar.gz:https://github.com/tokers/zstd-nginx-module/archive/${NGX_ZSTD_VERSION}.tar.gz" || { \
        echo "下载失败"; \
        exit 1; \
    }'; \
    \
    # 解压源码包
    tar xzf openssl-${OPENSSL_VERSION}.tar.gz; \
    tar xzf pcre-${PCRE_VERSION}.tar.gz; \
    tar xzvf nginx-${NGINX_VERSION}.tar.gz; \
    tar xzf headers-more-nginx-module-${HMNM_VERSION}.tar.gz; \
    tar xzf ngx_brotli-${NGX_BROTLI_VERSION}.tar.gz; \
    tar xzf zstd-nginx-module-${NGX_ZSTD_VERSION}.tar.gz; \
    mkdir -p nginx-${NGINX_VERSION}/module > /dev/null; \
    mv headers-more-nginx-module-${HMNM_VERSION} nginx-${NGINX_VERSION}/module/headers-more-nginx-module; \
    mv ngx_brotli-${NGX_BROTLI_VERSION} nginx-${NGINX_VERSION}/module/ngx_brotli; \
    mv zstd-nginx-module-${NGX_ZSTD_VERSION} nginx-${NGINX_VERSION}/module/zstd-nginx-module; \
    cd nginx-${NGINX_VERSION}; \
    \
    # 根据压缩模块开关构建 configure 参数（写入临时文件，避免 $$ 转义问题）
    printf '%s' "--add-module=module/headers-more-nginx-module" > /tmp/mod_args; \
    if [ "${NGINX_ENABLE_BROTLI:-true}" = "true" ]; then \
        printf ' %s' "--add-module=module/ngx_brotli" >> /tmp/mod_args; \
        echo ">>> Brotli 压缩模块: 已启用"; \
    else \
        echo ">>> Brotli 压缩模块: 已禁用"; \
    fi; \
    if [ "${NGINX_ENABLE_ZSTD:-true}" = "true" ]; then \
        printf ' %s' "--add-module=module/zstd-nginx-module" >> /tmp/mod_args; \
        echo ">>> Zstd 压缩模块: 已启用"; \
    else \
        echo ">>> Zstd 压缩模块: 已禁用"; \
    fi; \
    echo ">>> EXTRA_MODULES=$(cat /tmp/mod_args)"; \
    \
    # 修改Nginx版本信息
    sed -i 's@#define NGINX_VERSION.*$@#define NGINX_VERSION      "1.1.2"@' src/core/nginx.h; \
    sed -i 's@#define NGINX_VER.*NGINX_VERSION$@#define NGINX_VER          "hg_web/" NGINX_VERSION@' src/core/nginx.h; \
    sed -i 's@Server: nginx@Server: hg_web@' src/http/ngx_http_header_filter_module.c; \
    \
    # 配置、编译和安装Nginx
    ./configure --prefix=/etc/nginx \
                --user=${RUN_USER} \
                --group=${RUN_USER} \
                --with-http_stub_status_module \
                --with-http_sub_module \
                --with-http_v2_module \
                --with-http_ssl_module \
                --with-stream \
                --with-stream_ssl_preread_module \
                --with-stream_ssl_module \
                --with-http_gzip_static_module \
                --with-http_realip_module \
                --with-http_flv_module \
                --with-http_mp4_module \
                --with-openssl=../openssl-${OPENSSL_VERSION} \
                --with-pcre=../pcre-${PCRE_VERSION} \
                --with-pcre-jit \
                $(cat /tmp/mod_args); \
    make ${MC}; \
    make install; \
    \
    # 配置环境变量
    [ -z "`grep ^'export PATH=' /etc/profile`" ] && echo "export PATH=/etc/nginx/sbin:\$PATH" >> /etc/profile; \
    [ -n "`grep ^'export PATH=' /etc/profile`" -a -z "`grep /etc/nginx /etc/profile`" ] && sed -i "s@^export PATH=\(.*\)@export PATH=/etc/nginx/sbin:\1@" /etc/profile; \
    . /etc/profile; \
    \
    # 创建配置目录
    mkdir -p /etc/nginx/conf/vhost; \
    ln -sf /etc/nginx/conf/vhost /etc/nginx/conf.d; \
    \
    # 清理构建依赖和临时文件，减小镜像体积（保留curl）
    cd /; \
    rm -rf ${TMP_DIR}/*; \
    # 保留运行时库（标记为手动安装，避免被 --auto-remove 清除）
    printf '' > /tmp/runtime_pkgs; \
    if [ "${NGINX_ENABLE_BROTLI:-true}" = "true" ]; then \
        printf ' %s' "libbrotli1" >> /tmp/runtime_pkgs; \
    fi; \
    if [ "${NGINX_ENABLE_ZSTD:-true}" = "true" ]; then \
        printf ' %s' "libzstd1" >> /tmp/runtime_pkgs; \
    fi; \
    _PKGS="$(cat /tmp/runtime_pkgs)"; \
    if [ -n "$_PKGS" ]; then \
        apt-get install -y $_PKGS; \
    fi; \
    apt-get purge -y --auto-remove build-essential wget libpcre3-dev zlib1g-dev libssl-dev libbrotli-dev libzstd-dev; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    \
    # 创建docker-entrypoint.d目录
    mkdir /docker-entrypoint.d

RUN { \
    echo 'proxy_connect_timeout 300s;'; \
    echo 'proxy_send_timeout 900;'; \
    echo 'proxy_read_timeout 900;'; \
    echo 'proxy_buffer_size 32k;'; \
    echo 'proxy_buffers 4 64k;'; \
    echo 'proxy_busy_buffers_size 128k;'; \
    echo 'proxy_redirect off;'; \
    echo 'proxy_hide_header Vary;'; \
    echo "proxy_set_header Accept-Encoding '';"; \
    echo 'proxy_set_header Referer $http_referer;'; \
    echo 'proxy_set_header Cookie $http_cookie;'; \
    echo 'proxy_set_header Host $host;'; \
    echo 'proxy_set_header X-Real-IP $remote_addr;'; \
    echo 'proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'; \
    echo 'proxy_set_header X-Forwarded-Proto $scheme;'; \
} | tee "/etc/nginx/conf/proxy.conf"

RUN { \
    echo '/var/log/nginx/*nginx.log {'; \
    echo '  daily'; \
    echo '  rotate 5'; \
    echo '  missingok'; \
    echo '  dateext'; \
    echo '  compress'; \
    echo '  notifempty'; \
    echo '  sharedscripts'; \
    echo '  postrotate'; \
    echo '  [ -e /var/run/nginx.pid ] && kill -USR1 \`cat /var/run/nginx.pid\`'; \
    echo '  endscript'; \
} | tee "/etc/logrotate.d/nginx" \
&& ldconfig

ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/etc/nginx/sbin/"

COPY ./build/nginx/1.30/config/nginx.conf /etc/nginx/conf/
COPY ./build/nginx/1.30/config/mime.types /etc/nginx/conf/mime.types
COPY ./build/nginx/1.30/config/snippets/ /etc/nginx/conf/snippets/
COPY ./vhost/nginx_vhost/certs/* /etc/nginx/conf/ssl/

COPY ./build/nginx/1.30/docker-entrypoint.sh /
COPY ./build/nginx/1.30/config/compression.conf.template /etc/nginx/conf/compression.conf.template
RUN chmod +x /docker-entrypoint.sh
# COPY ./build/nginx/1.30/10-listen-on-ipv6-by-default.sh /docker-entrypoint.d
COPY ./build/nginx/1.30/15-local-resolvers.envsh /docker-entrypoint.d
COPY ./build/nginx/1.30/20-envsubst-on-templates.sh /docker-entrypoint.d
COPY ./build/nginx/1.30/30-tune-worker-processes.sh /docker-entrypoint.d
COPY ./build/nginx/1.30/40-compression-conf.sh /docker-entrypoint.d
RUN chmod +x /docker-entrypoint.d/*.sh /docker-entrypoint.d/*.envsh
ENTRYPOINT ["/docker-entrypoint.sh"]

WORKDIR /var/www/html

EXPOSE 80

# 清理构建代理变量，避免代理配置进入运行容器。
ENV HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= http_proxy= https_proxy= all_proxy= NO_PROXY= no_proxy=

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
