#!/bin/bash

export MC="-j$(nproc)"

echo
echo "============================================"
echo "Install extensions from   : ext-debian.sh"
echo "PHP version               : ${PHP_VERSION}"
echo "Extra Extensions          : ${PHP_EXTENSIONS}"
echo "Multicore Compilation     : ${MC}"
echo "Work directory            : ${PWD}"
echo "============================================"
echo

php_detail_version=$(/usr/local/bin/php-config --version)
php_main_version=${php_detail_version%.*}

if [ "${PHP_EXTENSIONS}" != "" ]; then
    echo "---------- Install general dependencies ----------"
    # mv /etc/apt/sources.list /etc/apt/sources.list.new
    # cp -rf /etc/apt/sources.list.bak /etc/apt/sources.list
    apt-get update
    apt-get install -y --assume-yes --no-install-recommends apt-transport-https ca-certificates

    sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list
    # mv /etc/apt/sources.list /etc/apt/sources.list.bak
    # cp -rf /etc/apt/sources.list.new /etc/apt/sources.list
    apt-get update
    apt-get install -y --assume-yes lsof pkg-config apt-utils wget gcc g++ make cmake unzip autoconf automake libtool libssl-dev libpq-dev libedit-dev libzip-dev libicu-dev libxslt-dev binutils libyaml-dev iputils-ping nano libc-ares-dev libcurl4-openssl-dev libbrotli-dev
    rm -rf /var/lib/apt/lists/*
fi

if [ -z "${EXTENSIONS##*,opcache,*}" ]; then
    echo "---------- Install opcache ----------"
    docker-php-ext-install opcache
fi

if [ -z "${EXTENSIONS##*,yaf,*}" ]; then
    echo "---------- Install yaf ----------"
    printf "\n" | pecl install yaf
    docker-php-ext-enable yaf
fi

if [ -z "${EXTENSIONS##*,memcached,*}" ]; then
    echo "---------- Install memcached extension ----------"
	apt-get install -y libmemcached-dev zlib1g-dev \
    printf "\n" | pecl install memcached-3.2.0
    docker-php-ext-enable memcached
fi

if [ -z "${EXTENSIONS##*,swoole,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install swoole extension ----------"

    if [[ "${php_main_version}" =~ ^5.[3-6]$ ]]; then
        if [ ! -f swoole-2.0.11.tgz ]; then
            wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/swoole-2.0.11.tgz
        fi
        if [ -f swoole-2.0.11.tgz ]; then
            mkdir swoole \
                && tar -xf swoole-2.0.11.tgz -C swoole --strip-components=1 \
                && cd swoole \
                && phpize \
                && ./configure --enable-openssl --with-openssl-dir=/usr/local/openssl \
                && make ${MC} \
                && make install \
                && cd .. \
                && rm -fr swoole \
                && docker-php-ext-enable swoole
        fi
    elif [[ "${php_main_version}" =~ ^7.[0-4]$ ]]; then
        if [ ! -f swoole-4.8.13.tgz ]; then
            wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/swoole-4.8.13.tgz
        fi
        if [ -f swoole-4.8.13.tgz ]; then
            mkdir swoole \
                && tar -xf swoole-4.8.13.tgz -C swoole --strip-components=1 \
                && cd swoole \
                && phpize \
                && ./configure --enable-openssl --with-openssl-dir=/usr/local/openssl \
                && make ${MC} \
                && make install \
                && cd .. \
                && rm -fr swoole \
                && docker-php-ext-enable swoole
        fi
    else
        # -n 判断SWOOLE_EXT_VERSION不为空
        if [ -n "${SWOOLE_EXT_VERSION}" ]; then
            if [ ! -f swoole-${SWOOLE_EXT_VERSION}.tgz ]; then
                wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/swoole-${SWOOLE_EXT_VERSION}.tgz
            fi

            if [ -f swoole-${SWOOLE_EXT_VERSION}.tgz ]; then
                mkdir swoole \
                    && tar -xf swoole-${SWOOLE_EXT_VERSION}.tgz -C swoole --strip-components=1 \
                    && cd swoole \
                    && phpize \
                    && ./configure --enable-openssl --enable-sockets --enable-brotli --enable-cares --enable-swoole-coro-time --enable-swoole-curl --enable-swoole --with-openssl-dir=/usr/local/openssl \
                    && make ${MC} \
                    && make install \
                    && cd .. \
                    && rm -fr swoole \
                    && docker-php-ext-enable swoole
            else
                printf "\n" | pecl install swoole
                docker-php-ext-enable swoole
            fi
        else
            printf "\n" | pecl install swoole
            docker-php-ext-enable swoole
        fi
    fi

    if [ -f "/usr/local/etc/php/conf.d/docker-php-ext-swoole.ini" ]; then
        echo "swoole.use_shortname='Off'" >> /usr/local/etc/php/conf.d/docker-php-ext-swoole.ini
    fi
    # if [ $(grep "vernum=" /usr/local/bin/php-config | awk -F ' ' '{print $1}' | cut -b 9-13) -gt 80000 ]; then
    # fi
fi

if [ -z "${EXTENSIONS##*,yaml,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install yaml extension ----------"

    # 7.0+
    if [[ "${php_main_version}" =~ ^7.[0-4]$|8.[0-4]$ ]]; then
        if [ -n "${YAML_EXT_VERSION}" ]; then
            if [ ! -f yaml-${YAML_EXT_VERSION}.tgz ]; then
                wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/yaml-${YAML_EXT_VERSION}.tgz
            fi
            if [ -f yaml-${YAML_EXT_VERSION}.tgz ]; then
                mkdir yaml \
                    && tar -xf yaml-${YAML_EXT_VERSION}.tgz -C yaml --strip-components=1 \
                    && ( cd yaml && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr yaml ) \
                    && docker-php-ext-enable yaml
            else
                printf "\n" | pecl install yaml
                docker-php-ext-enable yaml
            fi
        else
            printf "\n" | pecl install yaml
            docker-php-ext-enable yaml
        fi
    fi
fi


if [ -z "${EXTENSIONS##*,redis,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install redis extension ----------"

    if [ -n "${REDIS_EXT_VERSION}" ]; then
        if [ ! -f redis-${REDIS_EXT_VERSION}.tgz ]; then
            wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/redis-${REDIS_EXT_VERSION}.tgz
        fi
        if [ -f redis-${REDIS_EXT_VERSION}.tgz ]; then
            mkdir redis \
                && tar -xf redis-${REDIS_EXT_VERSION}.tgz -C redis --strip-components=1 \
                && ( cd redis && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr redis ) \
                && docker-php-ext-enable redis
        else
            printf "\n" | pecl install redis
            docker-php-ext-enable redis
        fi
    else
        printf "\n" | pecl install redis
        docker-php-ext-enable redis
    fi
fi


if [ -z "${EXTENSIONS##*,xdebug,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install xdebug extension ----------"

    if [[ "${php_main_version}" =~ ^5.[0-6]$ ]]; then
        echo "Your php ${php_main_version} does not support xdebug! ";
    elif [[ "${php_main_version}" =~ ^7.[0-1]$ ]]; then
        if [ ! -f xdebug-2.9.8.tgz ]; then
            wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/xdebug-2.9.8.tgz
        fi
        if [ -f xdebug-2.9.8.tgz ]; then
            mkdir xdebug \
                && tar -xf xdebug-2.9.8.tgz -C xdebug --strip-components=1 \
                && ( cd xdebug && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr xdebug) \
                && docker-php-ext-enable xdebug
        fi
    elif [[ "${php_main_version}" =~ ^7.[2-4]$ ]]; then
        if [ ! -f xdebug-3.1.6.tgz ]; then
            wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/xdebug-3.1.6.tgz
        fi
        if [ -f xdebug-3.1.6.tgz ]; then
            mkdir xdebug \
                && tar -xf xdebug-3.1.6.tgz -C xdebug --strip-components=1 \
                && ( cd xdebug && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr xdebug) \
                && docker-php-ext-enable xdebug
        fi
    else
        if [ -n "${XDEBUG_EXT_VERSION}" ]; then
            if [ ! -f xdebug-${XDEBUG_EXT_VERSION}.tgz ]; then
                wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/xdebug-${XDEBUG_EXT_VERSION}.tgz
            fi

            if [ -f xdebug-${XDEBUG_EXT_VERSION}.tgz ]; then
                mkdir xdebug \
                    && tar -xf xdebug-${XDEBUG_EXT_VERSION}.tgz -C xdebug --strip-components=1 \
                    && ( cd xdebug && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr xdebug) \
                    && docker-php-ext-enable xdebug
            else
                printf "\n" | pecl install xdebug
                docker-php-ext-enable xdebug
            fi
        else
            printf "\n" | pecl install xdebug
            docker-php-ext-enable xdebug
        fi
    fi

#     if [ -f "/usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini" ]; then
#         cat >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini << EOF
# [xdebug]
# zend_extension=xdebug.so
# xdebug.trace_output_dir=/tmp/xdebug
# xdebug.profiler_output_dir = /tmp/xdebug
# xdebug.profiler_enable = On
# xdebug.profiler_enable_trigger = 1
# EOF
#     fi
fi


if [ -z "${EXTENSIONS##*,imagick,*}" ]; then

    cd "${TMP_DIR}"

    if [ ! -f "/usr/local/imagemagick" ]; then
        echo "---------- Install ImageMagick ----------"

        if [ ! -f ImageMagick-${IMAGICK_VERSION}.tar.gz ]; then
            curl -L https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${IMAGICK_VERSION}.tar.gz -o ImageMagick-${IMAGICK_VERSION}.tar.gz
        fi
        tar xzf ImageMagick-${IMAGICK_VERSION}.tar.gz
        cd ImageMagick-${IMAGICK_VERSION} > /dev/null
        ./configure --prefix=/usr/local/imagemagick --enable-shared --enable-static
        make ${MC} && make install
        ldconfig /usr/local/lib
        cd "${TMP_DIR}"
        rm -rf ImageMagick-${IMAGICK_VERSION}
    fi

    cd "${TMP_DIR}"
    echo "---------- Install imagick extension ----------"

    if [ -n "${IMAGICK_VERSION}" ]; then
        if [ ! -f imagick-${IMAGICK_EXT_VERSION}.tgz ]; then
            wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/imagick-${IMAGICK_EXT_VERSION}.tgz
        fi
        if [ -f imagick-${IMAGICK_EXT_VERSION}.tgz ]; then
            mkdir imagick \
                && tar -xf imagick-${IMAGICK_EXT_VERSION}.tgz -C imagick --strip-components=1 \
                && ( cd imagick && phpize && ./configure --with-imagick=/usr/local/imagemagick/ && make ${MC} && make install && cd .. && rm -fr imagick ) \
                && docker-php-ext-enable imagick
        else
            printf "\n" | pecl install imagick-${IMAGICK_EXT_VERSION}
            docker-php-ext-enable imagick
        fi
    else
        printf "\n" | pecl install imagick-${IMAGICK_EXT_VERSION}
        docker-php-ext-enable imagick
    fi
fi


if [ -z "${EXTENSIONS##*,mongodb,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install mongodb extension ----------"
    echo "PHP main version: ${php_main_version}"
    echo "MongoDB extension version: ${MONGODB_EXT_VERSION:-auto-detect}"
    
    apt-get update
    apt-get install -y unixodbc-dev libssl-dev pkg-config

    # 根据 PHP 版本自动选择合适的 MongoDB 扩展版本
    SELECTED_MONGODB_VERSION=""
    
    if [[ "${php_main_version}" =~ ^5.[3-6]$ ]]; then
        # PHP 5.3-5.6: 使用旧的 mongo 扩展 (不是 mongodb)
        echo "PHP 5.x detected, using legacy mongo extension"
        if [ ! -f mongo-1.6.16.tgz ]; then
            wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/mongo-1.6.16.tgz
        fi
        if [ -f mongo-1.6.16.tgz ]; then
            mkdir mongo \
                && tar -xf mongo-1.6.16.tgz -C mongo --strip-components=1 \
                && ( cd mongo && phpize && ./configure --with-php-config=/usr/local/bin/php-config && make ${MC} && make install && cd .. && rm -fr mongo ) \
                && docker-php-ext-enable mongo \
                && echo "Legacy mongo extension installed successfully"
        else
            printf "\n" | pecl install mongo
            docker-php-ext-enable mongo
        fi
        
    elif [[ "${php_main_version}" =~ ^7.[0]$ ]]; then
        # PHP 7.0: MongoDB 1.9.2
        echo "PHP 7.0 detected, using MongoDB extension 1.9.2"
        SELECTED_MONGODB_VERSION="1.9.2"
        
    elif [[ "${php_main_version}" =~ ^7.[1-3]$ ]]; then
        # PHP 7.1-7.3: MongoDB 1.16.2
        echo "PHP 7.1-7.3 detected, using MongoDB extension 1.16.2"
        SELECTED_MONGODB_VERSION="1.16.2"
        
    elif [[ "${php_main_version}" =~ ^7.[4]$|^8.[0]$ ]]; then
        # PHP 7.4 和 8.0: MongoDB 1.20.0
        echo "PHP 7.4/8.0 detected, using MongoDB extension 1.20.0"
        SELECTED_MONGODB_VERSION="1.20.0"
        
    elif [[ "${php_main_version}" =~ ^8.[1-9]$ ]]; then
        # PHP 8.1+: MongoDB 2.0.0+
        echo "PHP 8.1+ detected, using latest MongoDB extension"
        if [ -n "${MONGODB_EXT_VERSION}" ]; then
            # 验证指定版本是否兼容
            if [[ "${MONGODB_EXT_VERSION}" =~ ^2\. ]]; then
                echo "Using specified MongoDB extension version: ${MONGODB_EXT_VERSION}"
                SELECTED_MONGODB_VERSION="${MONGODB_EXT_VERSION}"
            else
                echo "Warning: MongoDB extension ${MONGODB_EXT_VERSION} may not be compatible with PHP ${php_main_version}"
                echo "Using MongoDB extension 2.0.0 for PHP 8.1+ compatibility"
                SELECTED_MONGODB_VERSION="2.0.0"
            fi
        else
            SELECTED_MONGODB_VERSION="2.0.0"
        fi
        
    else
        # 未知版本，尝试使用默认版本
        echo "Unknown PHP version ${php_main_version}, attempting to use default MongoDB extension"
        if [ -n "${MONGODB_EXT_VERSION}" ]; then
            SELECTED_MONGODB_VERSION="${MONGODB_EXT_VERSION}"
        else
            printf "\n" | pecl install mongodb
            docker-php-ext-enable mongodb
        fi
    fi

    # 下载并安装选定版本的 MongoDB 扩展
    if [ -n "${SELECTED_MONGODB_VERSION}" ]; then
        echo "Installing MongoDB extension version: ${SELECTED_MONGODB_VERSION}"
        
        if [ ! -f mongodb-${SELECTED_MONGODB_VERSION}.tgz ]; then
            echo "Downloading MongoDB extension ${SELECTED_MONGODB_VERSION}..."
            wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/mongodb-${SELECTED_MONGODB_VERSION}.tgz
        fi
        
        if [ -f mongodb-${SELECTED_MONGODB_VERSION}.tgz ]; then
            mv mongodb-${SELECTED_MONGODB_VERSION}.tgz mongodb.tgz
        else
            echo "Failed to download MongoDB extension ${SELECTED_MONGODB_VERSION}, trying PECL install"
            printf "\n" | pecl install mongodb-${SELECTED_MONGODB_VERSION}
            docker-php-ext-enable mongodb
        fi
    fi

    # 编译和安装从源码下载的扩展
    if [ -f mongodb.tgz ]; then
        echo "---------- Compiling MongoDB extension from source ----------"
        
        if mkdir mongodb && tar -xf mongodb.tgz -C mongodb --strip-components=1; then
            echo "MongoDB extension extracted successfully"
            cd mongodb
            
            if phpize; then
                echo "phpize completed successfully"
                
                echo "Running configure..."
                if ./configure --with-php-config=/usr/local/bin/php-config; then
                    echo "Configure completed successfully"
                    
                    if make ${MC}; then
                        echo "Make completed successfully"
                        
                        if make install; then
                            echo "Make install completed successfully"
                            cd ..
                            rm -fr mongodb
                            
                            echo "Enabling MongoDB extension..."
                            if docker-php-ext-enable mongodb; then
                                echo "MongoDB extension installed and enabled successfully"
                                
                                # 验证安装
                                if php -m | grep -q mongodb; then
                                    echo "✅ MongoDB extension verification: SUCCESS"
                                else
                                    echo "❌ MongoDB extension verification: FAILED"
                                fi
                            else
                                echo "ERROR: Failed to enable MongoDB extension"
                            fi
                        else
                            echo "ERROR: Make install failed"
                            cd ..
                        fi
                    else
                        echo "ERROR: Make compilation failed"
                        cd ..
                    fi
                else
                    echo "ERROR: Configure failed"
                    cd ..
                fi
            else
                echo "ERROR: phpize failed"
                cd ..
            fi
        else
            echo "ERROR: Failed to extract MongoDB extension"
        fi
    fi
fi


if [ -z "${EXTENSIONS##*,grpc,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install grpc extension ----------"
    apt-get update && apt-get install -y zlib1g-dev

    if [ -n "${GRPC_EXT_VERSION}" ]; then
        if [ ! -f grpc-${GRPC_EXT_VERSION}.tgz ]; then
            wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/grpc-${GRPC_EXT_VERSION}.tgz
        fi
        if [ -f grpc-${GRPC_EXT_VERSION}.tgz ]; then
            mkdir grpc \
                && tar -xf grpc-${GRPC_EXT_VERSION}.tgz -C grpc --strip-components=1 \
                && ( cd grpc && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr grpc ) \
                && docker-php-ext-enable grpc
        else
            printf "\n" | pecl install grpc
            docker-php-ext-enable grpc
        fi
    else
        printf "\n" | pecl install grpc
        docker-php-ext-enable grpc
    fi

    if [ -f "/usr/local/etc/php/conf.d/docker-php-ext-grpc.ini" ]; then
        echo "grpc.enable_fork_support = 1" >> /usr/local/etc/php/conf.d/docker-php-ext-grpc.ini
    fi
fi


if [ -z "${EXTENSIONS##*,protobuf,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install protobuf ----------"

    if [ ! -f protoc-${PROTOBUF_VERSION}-linux-x86_64.zip ]; then
        wget --limit-rate=100M --tries=6 -c --no-check-certificate https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/protoc-${PROTOBUF_VERSION}-linux-x86_64.zip
    fi

    if [ -f protoc-${PROTOBUF_VERSION}-linux-x86_64.zip ]; then
        unzip protoc-${PROTOBUF_VERSION}-linux-x86_64.zip
        cp bin/protoc /usr/local/bin/
        rm -fr bin include readme.txt
    fi

    cd "${TMP_DIR}"
    if [ -f "/usr/local/bin/protoc" ];then
        echo "---------- Install protobuf extension ----------"

        if [ -n "${PROTOBUF_EXT_VERSION}" ]; then
            if [ ! -f protobuf-${PROTOBUF_EXT_VERSION}.tgz ]; then
                wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/protobuf-${PROTOBUF_EXT_VERSION}.tgz
            fi
            if [ -f protobuf-${PROTOBUF_EXT_VERSION}.tgz ]; then
                mkdir protobuf \
                    && tar -xf protobuf-${PROTOBUF_EXT_VERSION}.tgz -C protobuf --strip-components=1 \
                    && ( cd protobuf && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr protobuf ) \
                    && docker-php-ext-enable protobuf
            else
                printf "\n" | pecl install protobuf-${PROTOBUF_EXT_VERSION}
                docker-php-ext-enable protobuf
            fi
        else
            printf "\n" | pecl install protobuf-${PROTOBUF_EXT_VERSION}
            docker-php-ext-enable protobuf
        fi
    fi
fi

if [ -z "${EXTENSIONS##*,rdkafka,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install librdkafka ----------"

    if [ ! -f librdkafka-${LIBRDKAFKA_VERSION}.tar.gz ]; then
        wget --limit-rate=100M --tries=6 -c --no-check-certificate https://codeload.github.com/edenhill/librdkafka/tar.gz/v${LIBRDKAFKA_VERSION} -O librdkafka-${LIBRDKAFKA_VERSION}.tar.gz
    fi

    if [ -f librdkafka-${LIBRDKAFKA_VERSION}.tar.gz ]; then
        mkdir librdkafka \
            && tar -xf librdkafka-${LIBRDKAFKA_VERSION}.tar.gz -C librdkafka --strip-components=1 \
            && ( cd librdkafka && ./configure && make ${MC} && make install && cd .. && rm -fr librdkafka )

        cd "${TMP_DIR}"
        echo "---------- Install rdkafka extension ----------"

        if [ -n "${RDKAFKA_EXT_VERSION}" ]; then
            if [ ! -f rdkafka-${RDKAFKA_EXT_VERSION}.tgz ]; then
                wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/rdkafka-${RDKAFKA_EXT_VERSION}.tgz
            fi
            if [ -f rdkafka-${RDKAFKA_EXT_VERSION}.tgz ]; then
                mkdir rdkafka \
                    && tar -xf rdkafka-${RDKAFKA_EXT_VERSION}.tgz -C rdkafka --strip-components=1 \
                    && ( cd rdkafka && phpize && ./configure && make ${MC} && make install && cd .. && rm -fr rdkafka ) \
                    && docker-php-ext-enable rdkafka
            else
                printf "\n" | pecl install rdkafka
                docker-php-ext-enable rdkafka
            fi
        else
            printf "\n" | pecl install rdkafka
            docker-php-ext-enable rdkafka
        fi
    fi
fi

if [ -z "${EXTENSIONS##*,zookeeper,*}" ]; then

    cd "${TMP_DIR}"
    echo "---------- Install apache-zookeeper ----------"
    apt-get update && apt-get install -y libcppunit-dev file ant libcppunit-dev git

    if [ ! -f apache-zookeeper-${ZOOKEEPER_VERSION}.tar.gz ]; then
        wget --limit-rate=100M --tries=6 -c --no-check-certificate https://mirrors.tuna.tsinghua.edu.cn/apache/zookeeper/zookeeper-${ZOOKEEPER_VERSION}/apache-zookeeper-${ZOOKEEPER_VERSION}.tar.gz
    fi

    if [ -f apache-zookeeper-${ZOOKEEPER_VERSION}.tar.gz ]; then
        mkdir zookeeper \
            && tar -xf apache-zookeeper-${ZOOKEEPER_VERSION}.tar.gz -C zookeeper --strip-components=1 \
            && cd zookeeper \
            && ant clean jar \
            && ant compile_jute \
            && cd zookeeper-client/zookeeper-client-c \
            && autoreconf -if && ACLOCAL="aclocal -I /usr/share/aclocal" autoreconf -if \
            && ./configure --prefix=/usr/local/zookeeper && make CFLAGS="-Wno-error" ${MC} \
            && make install

        cd "${TMP_DIR}"
        rm -fr zookeeper
        echo "---------- Install zookeeper extension ----------"

        if [ -n "${ZOOKEEPER_EXT_VERSION}" ]; then
            if [ ! -f zookeeper-${ZOOKEEPER_EXT_VERSION}.tgz ];then
                wget --limit-rate=100M --tries=6 -c --no-check-certificate https://pecl.php.net/get/zookeeper-${ZOOKEEPER_EXT_VERSION}.tgz
            fi
            if [ -f zookeeper-${ZOOKEEPER_EXT_VERSION}.tgz ]; then
                mkdir zookeeper-ext \
                    && tar -xf zookeeper-${ZOOKEEPER_EXT_VERSION}.tgz -C zookeeper-ext --strip-components=1 \
                    && ( cd zookeeper-ext && phpize && ./configure --with-libzookeeper-dir=/usr/local/zookeeper && make ${MC} && make install && cd .. && rm -fr zookeeper-ext ) \
                    && docker-php-ext-enable zookeeper
            else
                printf "\n" | pecl install zookeeper
                docker-php-ext-enable zookeeper
            fi
        else
            printf "\n" | pecl install zookeeper
            docker-php-ext-enable zookeeper
        fi
    fi
fi