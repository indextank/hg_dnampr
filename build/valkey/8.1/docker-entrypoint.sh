#!/bin/sh
set -e

# 防止宿主/编排注入残缺 PATH：相对 ENTRYPOINT 名与 valkey-server 都会找不到
# （报错：executable file not found in $PATH）
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# first arg is `-f` or `--some-option`
# or first arg is `something.conf`
if [ "${1#-}" != "$1" ] || [ "${1%.conf}" != "$1" ]; then
	set -- valkey-server "$@"
fi

# allow the container to be started with `--user`
# 降权后必须用绝对路径重入：相对 $0（docker-entrypoint.sh）在 PATH 异常时会找不到
if [ "$1" = 'valkey-server' -a "$(id -u)" = '0' ]; then
	find . \! -user valkey -exec chown valkey '{}' +
	exec setpriv --reuid=valkey --regid=valkey --clear-groups -- /usr/local/bin/docker-entrypoint.sh "$@"
fi

# set an appropriate umask (if one isn't set already)
um="$(umask)"
if [ "$um" = '0022' ]; then
	umask 0077
fi

exec "$@" $VALKEY_EXTRA_FLAGS
