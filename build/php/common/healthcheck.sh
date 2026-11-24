#!/bin/sh
set -eu

php -r 'exit(PHP_VERSION_ID > 0 ? 0 : 1);'
# 显式打到镜像内默认健康 vhost，避免 sites-enabled 业务站 .htaccess 劫持 /php-status。
curl --fail --silent --show-error --max-time 5 \
	-H 'Host: php-health.local' \
	'http://127.0.0.1:88/php-status' >/dev/null
