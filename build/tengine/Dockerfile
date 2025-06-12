FROM alpine:3.20

# 代理设置参数
ARG http_proxy
ARG https_proxy
ARG no_proxy

ARG TENGINE_VERSION
ARG HMNM_VERSION
ARG ALPINE_REPOSITORIES
ARG CHANGE_SOURCE=false

# nginx: https://git.io/vSIyj

RUN rm -rf /var/cache/apk/* && \
    rm -rf /tmp/*

ENV TMP_DIR=/tmp/extensions

# If you're in China, or you need to change sources, will be set CHANGE_SOURCE to true in .env.
RUN set -eux; \
    mkdir -p ${TMP_DIR}; \
    \
    if [ ${CHANGE_SOURCE} = true ]; then \
        sed -i "s/dl-cdn.alpinelinux.org/${ALPINE_REPOSITORIES}/g" /etc/apk/repositories; \
        apk update; \
        apk add --no-cache tzdata; \
        cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime; \
        echo "Asia/Shanghai" > /etc/timezone; \
    fi;

COPY ./src/nginx/ ${TMP_DIR}
WORKDIR ${TMP_DIR}

ENV CONFIG="\
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=nginx \
        --group=nginx \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_xslt_module=dynamic \
        --with-http_image_filter_module=dynamic \
        --with-http_geoip_module=dynamic \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_auth_request_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_stub_status_module \
        --with-threads \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_realip_module \
        --with-stream_geoip_module=dynamic \
        --with-stream_ssl_preread_module \
        --with-http_slice_module \
        --with-mail \
        --with-mail_ssl_module \
        --with-compat \
        --with-file-aio \
        --with-http_v2_module \
        --add-module=modules/ngx_http_upstream_check_module \
        --add-module=modules/headers-more-nginx-module-${HMNM_VERSION} \
	    --add-module=modules/ngx_http_upstream_session_sticky_module \
        "
RUN set -eux; \
    # 创建用户和组
    addgroup -S nginx; \
    adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx; \
    adduser -u 82 -D -S -G www-data www-data; \
    # 安装构建依赖
    apk add --no-cache --virtual .build-deps \
            gcc \
            libc-dev \
            make \
            openssl-dev \
            pcre-dev \
            zlib-dev \
            linux-headers \
            curl \
            libxslt-dev \
            gd-dev \
            geoip-dev; \
    cd ${TMP_DIR}; \
    \
    # 下载源码
    if [ ! -f "tengine-$TENGINE_VERSION.tar.gz" ]; then \
        curl -L "https://github.com/alibaba/tengine/archive/$TENGINE_VERSION.tar.gz" -o tengine-$TENGINE_VERSION.tar.gz; \
    fi; \
    \
    if [ ! -f "headers-more-nginx-module-${HMNM_VERSION}.tar.gz" ]; then \
        curl -L "https://github.com/openresty/headers-more-nginx-module/archive/v${HMNM_VERSION}.tar.gz" -o headers-more-nginx-module-${HMNM_VERSION}.tar.gz; \
    fi; \
    \
    # curl -L "https://github.com/alibaba/tengine/archive/$TENGINE_VERSION.tar.gz" -o tengine-$TENGINE_VERSION.tar.gz; \
    # mkdir -p /tmp/extensions; \
    tar -zxC /tmp/extensions -f tengine-$TENGINE_VERSION.tar.gz; \
    rm -fr ${TMP_DIR}/tengine-$TENGINE_VERSION.tar.gz; \
    cd ${TMP_DIR}/tengine-$TENGINE_VERSION; \
    mv ${TMP_DIR}/headers-more-nginx-module-${HMNM_VERSION}.tar.gz .; \
    tar -zxC ${TMP_DIR}/tengine-$TENGINE_VERSION/modules -f headers-more-nginx-module-${HMNM_VERSION}.tar.gz; \
    rm -fr ${TMP_DIR}/headers-more-nginx-module-${HMNM_VERSION}.tar.gz; \
    ls -l ${TMP_DIR}/tengine-$TENGINE_VERSION/modules; \
    ./configure $CONFIG --with-debug; \
    make -j$(getconf _NPROCESSORS_ONLN); \
    mv objs/nginx objs/nginx-debug; \
    mv objs/ngx_http_xslt_filter_module.so objs/ngx_http_xslt_filter_module-debug.so; \
    mv objs/ngx_http_image_filter_module.so objs/ngx_http_image_filter_module-debug.so; \
    mv objs/ngx_http_geoip_module.so objs/ngx_http_geoip_module-debug.so; \
    mv objs/ngx_stream_geoip_module.so objs/ngx_stream_geoip_module-debug.so; \
    ./configure $CONFIG; \
    make -j$(getconf _NPROCESSORS_ONLN); \
    make install; \
    # rm -rf /etc/nginx/html/; \
    mkdir /etc/nginx/conf.d/; \
    # mkdir -p /etc/nginx/html/; \
    install -m644 html/index.html /etc/nginx/html/; \
    install -m644 html/50x.html /etc/nginx/html/; \
    install -m755 objs/nginx-debug /usr/sbin/nginx-debug; \
    install -m755 objs/ngx_http_xslt_filter_module-debug.so /usr/lib/nginx/modules/ngx_http_xslt_filter_module-debug.so; \
    install -m755 objs/ngx_http_image_filter_module-debug.so /usr/lib/nginx/modules/ngx_http_image_filter_module-debug.so; \
    install -m755 objs/ngx_http_geoip_module-debug.so /usr/lib/nginx/modules/ngx_http_geoip_module-debug.so; \
    install -m755 objs/ngx_stream_geoip_module-debug.so /usr/lib/nginx/modules/ngx_stream_geoip_module-debug.so; \
    ln -s ../../usr/lib/nginx/modules /etc/nginx/modules; \
    strip /usr/sbin/nginx*; \
    strip /usr/lib/nginx/modules/*.so; \
    \
    # Bring in gettext so we can get `envsubst`, then throw
    # the rest away. To do this, we need to install `gettext`
    # then move `envsubst` out of the way so `gettext` can
    # be deleted completely, then move `envsubst` back.
    apk add --no-cache --virtual .gettext gettext; \
    mv /usr/bin/envsubst /tmp/; \
    \
    runDeps="$( \
            scanelf --needed --nobanner --format '%n#p' /usr/sbin/nginx /usr/lib/nginx/modules/*.so /tmp/envsubst \
                    | tr ',' '\n' \
                    | sort -u \
                    | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .nginx-rundeps $runDeps; \
    apk del .build-deps; \
    apk del .gettext; \
    mv /tmp/envsubst /usr/local/bin/; \
    \
    # Bring in tzdata so users could set the timezones through the environment
    # variables
    apk add --no-cache tzdata curl ca-certificates; \
    \
    # 清理构建依赖和临时文件，减小镜像体积
    cd /; \
    rm -rf ${TMP_DIR}/*; \
    \
    # forward request and error logs to docker log collector
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log

# 创建proxy.conf配置文件
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
} | tee "/etc/nginx/proxy.conf"

COPY ./conf/nginx/tengine/nginx.conf /etc/nginx/
COPY ./vhost/nginx_vhost/certs/* /etc/nginx/conf/ssl/

EXPOSE 80 443

STOPSIGNAL SIGTERM

CMD ["nginx", "-g", "daemon off;"]