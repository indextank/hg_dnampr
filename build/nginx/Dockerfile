# 使用debian:bookworm-slim作为基础镜像
FROM debian:bookworm-slim

ARG NGINX_VERSION
ARG HMNM_VERSION
ARG CHANGE_SOURCE=false
ARG OPENSSL_VERSION
ARG PCRE_VERSION

ENV TMP_DIR /tmp/extensions

# 安装必要的工具和依赖
RUN apt-get update && \
    apt-get install -y \
    build-essential \
    wget \
    libpcre3 \
    libpcre3-dev \
    zlib1g \
    zlib1g-dev \
    libssl-dev

COPY ./src/nginx/ ${TMP_DIR}
WORKDIR ${TMP_DIR}

ENV RUN_USER nginx

RUN set -eux; \
	\
	if [ ${CHANGE_SOURCE} = true ]; then \
		sed -i 's@deb.debian.org@mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/debian.sources; \
	fi; \
	\
    groupadd --system --gid 101 ${RUN_USER}; \
    useradd --system --gid ${RUN_USER} --no-create-home --home /nonexistent --comment "nginx user" --shell /bin/false --uid 101 ${RUN_USER}; \
    apt-get update; \
    apt-get install --no-install-recommends --no-install-suggests -y gnupg1 ca-certificates vim; \
    \
    export MC="-j$(nproc)"; \
    \
    cd ${TMP_DIR}; \
    \
    if [ ! -f "nginx-${NGINX_VERSION}.tar.gz" ]; then \
        curl -L "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -o nginx-${NGINX_VERSION}.tar.gz; \
    fi; \
    \
    if [ ! -f "openssl-${OPENSSL_VERSION}.tar.gz" ]; then \
        curl -L "https://openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" -o openssl-${OPENSSL_VERSION}.tar.gz; \
    fi; \
    \
    if [ ! -f "pcre-${PCRE_VERSION}.tar.gz" ]; then \
        curl -L "https://ftp.exim.org/pub/pcre/pcre-${PCRE_VERSION}.tar.gz" -o pcre-${PCRE_VERSION}.tar.gz; \
    fi; \
    \
    if [ ! -f "headers-more-nginx-module-${HMNM_VERSION}.tar.gz" ]; then \
        curl -L "https://github.com/openresty/headers-more-nginx-module/archive/v${HMNM_VERSION}.tar.gz" -o headers-more-nginx-module-${HMNM_VERSION}.tar.gz; \
    fi; \
    \
    tar xzf openssl-${OPENSSL_VERSION}.tar.gz; \
    tar xzf pcre-${PCRE_VERSION}.tar.gz; \
    tar xzvf nginx-${NGINX_VERSION}.tar.gz; \
    tar xzf headers-more-nginx-module-${HMNM_VERSION}.tar.gz; \
    mkdir -p nginx-${NGINX_VERSION}/module > /dev/null; \
    mv headers-more-nginx-module-${HMNM_VERSION} nginx-${NGINX_VERSION}/module/headers-more-nginx-module; \
    cd nginx-${NGINX_VERSION}; \
    \
# Modify Nginx version
    sed -i 's@#define NGINX_VERSION.*$@#define NGINX_VERSION      "1.1.2"@' src/core/nginx.h; \
    sed -i 's@#define NGINX_VER.*NGINX_VERSION$@#define NGINX_VER          "hg_web/" NGINX_VERSION@' src/core/nginx.h; \
    sed -i 's@Server: nginx@Server: hg_web@' src/http/ngx_http_header_filter_module.c; \
    \
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
                --add-module=module/headers-more-nginx-module; \
    make ${MC}; \
    make install; \
    \
    [ -z "`grep ^'export PATH=' /etc/profile`" ] && echo "export PATH=/etc/nginx/sbin:\$PATH" >> /etc/profile; \
    [ -n "`grep ^'export PATH=' /etc/profile`" -a -z "`grep /etc/nginx /etc/profile`" ] && sed -i "s@^export PATH=\(.*\)@export PATH=/etc/nginx/sbin:\1@" /etc/profile; \
    . /etc/profile; \
    \
    mkdir -p /etc/nginx/conf/vhost; \
    ln -sf /etc/nginx/conf/vhost /etc/nginx/conf.d; \
# forward request and error logs to docker log collector
    # ln -sf /dev/stdout /var/log/nginx/access.log; \
    # ln -sf /dev/stderr /var/log/nginx/error.log; \
# create a docker-entrypoint.d directory
    mkdir /docker-entrypoint.d; \
    \
    apt-mark auto '.*' > /dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    \
    rm -rf ${TMP_DIR}/*

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

COPY ./conf/nginx/nginx.conf /etc/nginx/conf/
COPY ./vhost/nginx_vhost/certs/* /etc/nginx/conf/ssl/

COPY ./build/nginx/docker-entrypoint.sh /
# COPY ./build/nginx/10-listen-on-ipv6-by-default.sh /docker-entrypoint.d
COPY ./build/nginx/15-local-resolvers.envsh /docker-entrypoint.d
COPY ./build/nginx/20-envsubst-on-templates.sh /docker-entrypoint.d
COPY ./build/nginx/30-tune-worker-processes.sh /docker-entrypoint.d
ENTRYPOINT ["/docker-entrypoint.sh"]

WORKDIR /var/www/html

EXPOSE 80

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]