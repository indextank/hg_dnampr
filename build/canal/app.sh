#!/bin/bash
# 基于 Canal 官方 image/app.sh。
# Docker Desktop / WSL 下「su/runuser 降权再 exec sh」会稳定报 Resource temporarily unavailable(EAGAIN)，
# 与 bash/sh 无关。此处由 root 直接 /bin/sh -c 启动（容器内单租户可接受；生产请评估隔离）。
# 上游: https://github.com/alibaba/canal/blob/master/docker/image/app.sh

set +e

source /etc/profile
export JAVA_HOME=/usr/java/latest
export PATH=$JAVA_HOME/bin:$PATH
touch /tmp/start.log
host=`hostname -i`

run_as_admin() {
	# 不再调用 su/runuser，避免降权 fork 在部分运行时失败
	/bin/sh -c "$1"
}

# waitterm
# wait TERM/INT signal.
# see: http://veithen.github.io/2014/11/16/sigterm-propagation.html
waitterm() {
 local PID
 # any process to block
 tail -f /dev/null &
 PID="$!"
 # setup trap, could do nothing, or just kill the blocker
 trap "kill -TERM ${PID}" TERM INT
 # wait for signal, ignore wait exit code
 wait "${PID}" || true
 # clear trap
 trap - TERM INT
 # wait blocker, ignore blocker exit code
 wait "${PID}" 2>/dev/null || true
}

# waittermpid "${PIDFILE}".
# monitor process by pidfile && wait TERM/INT signal.
# if the process disappeared, return 1, means exit with ERROR.
# if TERM or INT signal received, return 0, means OK to exit.
waittermpid() {
 local PIDFILE PID do_run error
 PIDFILE="${1?}"
 do_run=true
 error=0
 trap "do_run=false" TERM INT
 while "${do_run}" ; do
 PID="$(cat "${PIDFILE}")"
 if ! ps -p "${PID}" >/dev/null 2>&1; then
 do_run=false
 error=1
 else
 sleep 1
 fi
 done
 trap - TERM INT
 return "${error}"
}


function checkStart() {
 local name=$1
 local cmd=$2
 local timeout=$3
 cost=5
 while [ $timeout -gt 0 ]; do
 ST=`eval $cmd`
 if [ "$ST" == "0" ]; then
 sleep 1
 let timeout=timeout-1
 let cost=cost+1
 elif [ "$ST" == "" ]; then
 sleep 1
 let timeout=timeout-1
 let cost=cost+1
 else
 break
 fi
 done
 echo "start $name successful"
}


function start_canal() {
 echo "start canal ..."
 managerAddress=`perl -le 'print $ENV{"canal.admin.manager"}'`
 if [ ! -z "$managerAddress" ] ; then
 # canal_local.properties mode
 adminPort=`perl -le 'print $ENV{"canal.admin.port"}'`
 if [ -z "$adminPort" ] ; then
 adminPort=11110
 fi

 run_as_admin 'cd /home/admin/canal-server/bin/ && sh restart.sh local 1>>/tmp/start.log 2>&1'
 sleep 5
 #check start
 checkStart "canal" "nc 127.0.0.1 $adminPort -w 1 -zv 2> /tmp/nc.out && cat /tmp/nc.out | grep -c Connected" 30
 else
 metricsPort=`perl -le 'print $ENV{"canal.metrics.pull.port"}'`
 if [ -z "$metricsPort" ] ; then
 metricsPort=11112
 fi

 destination=`perl -le 'print $ENV{"canal.destinations"}'`
 destinationExpr=`perl -le 'print $ENV{"canal.destinations.expr"}'`
 multistream=`perl -le 'print $ENV{"canal.instance.multi.stream.on"}'`

 if [[ "$destination" =~ ',' ]] || [[ -n "$destinationExpr" ]]; then
 if [[ "$multistream" = 'true' ]] ; then
 if [[ -n "$destinationExpr" ]] ; then
 splitDestinations '1' $destinationExpr
 else
 splitDestinations '2' $destination
 fi
 else
 echo "multi destination is not support, destinationExpr:$destinationExpr, destinations:$destination"
 exit 1;
 fi
 else
 if [ "$destination" != "" ] && [ "$destination" != "example" ] ; then
 if [ -d /home/admin/canal-server/conf/example ]; then
 mv /home/admin/canal-server/conf/example /home/admin/canal-server/conf/$destination
 fi
 fi 
 fi

 run_as_admin 'cd /home/admin/canal-server/bin/ && sh restart.sh 1>>/tmp/start.log 2>&1'
 sleep 5
 #check start
 checkStart "canal" "nc 127.0.0.1 $metricsPort -w 1 -zv 2> /tmp/nc.out && cat /tmp/nc.out | grep -c Connected" 30
 fi 
}

function splitDestinations() {
 holdExample="false"
 prefix=''
 array=()

 if [[ "$1" == '1' ]] ; then
 echo "split destinations expr "$2
 prefix=$(echo $2 | sed 's/{.*//')
 num=$(echo $2 | sed 's/.*{//;s/}//;s/-/ /')
 array=($(seq $num))
 else
 echo "split destinations "$2
 array=(${2//,/ })
 fi

 for var in ${array[@]}
 do
 cp -r /home/admin/canal-server/conf/example /home/admin/canal-server/conf/$prefix$var
 chown root:root -R /home/admin/canal-server/conf/$prefix$var
 if [[ "$prefix$var" = 'example' ]] ; then
 holdExample="true"
 fi
 done
 if [[ "$holdExample" != 'true' ]] ; then
 rm -rf /home/admin/canal-server/conf/example
 fi
}

function stop_canal() {
 echo "stop canal"
 run_as_admin 'cd /home/admin/canal-server/bin/ && sh stop.sh 1>>/tmp/start.log 2>&1'
 echo "stop canal successful ..."
}

function start_exporter() {
 run_as_admin 'cd /home/admin/node_exporter && ./node_exporter 1>>/tmp/start.log 2>&1 &'
}

function stop_exporter() {
 run_as_admin 'killall node_exporter'
}

# wait_for_rabbitmq: 等待 RabbitMQ 的 AMQP 端口（5672）可连接后再启动 Canal。
# Canal 启动时若 RabbitMQ 尚未就绪，会抛出 Connection refused 并直接退出，
# 且不会自动重试，必须在外部等待就绪后再启动。
function wait_for_rabbitmq() {
  local host="${1:-rabbitmq}"
  local port="${2:-5672}"
  local max_wait="${3:-60}"
  local waited=0
  echo "==> Waiting for RabbitMQ at ${host}:${port} ..."
  while ! nc -z "${host}" "${port}" >/dev/null 2>&1; do
    if [ "${waited}" -ge "${max_wait}" ]; then
      echo "==> ERROR: RabbitMQ not available after ${max_wait}s, giving up."
      exit 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  # 额外等待 3 秒让 RabbitMQ AMQP 服务完全初始化
  sleep 3
  echo "==> RabbitMQ is ready (waited ${waited}s)."
}

# canal_watchdog: 监控 Canal Java 进程，崩溃后自动重启。
# Canal 不具备自恢复能力——RabbitMQ 重启/网络抖动会导致 Canal 直接退出。
# 此 watchdog 循环检测进程存活，崩溃后等待 RabbitMQ 重新就绪再重启。
function canal_watchdog() {
  local pidfile="/home/admin/canal-server/bin/canal.pid"
  local rabbitmq_host="${RABBITMQ_HOST:-rabbitmq}"
  local rabbitmq_port="${RABBITMQ_PORT:-5672}"

  echo "==> Canal watchdog started."
  while true; do
    # 检查 Canal 进程是否存活
    if [ -f "${pidfile}" ]; then
      local pid
      pid=$(cat "${pidfile}" 2>/dev/null)
      if [ -n "${pid}" ] && ps -p "${pid}" >/dev/null 2>&1; then
        sleep 5
        continue
      fi
    fi

    echo "==> Canal process not found, preparing to restart ..."
    wait_for_rabbitmq "${rabbitmq_host}" "${rabbitmq_port}" 120
    echo "==> Restarting Canal ..."
    run_as_admin 'cd /home/admin/canal-server/bin/ && sh stop.sh 1>>/tmp/start.log 2>&1; sleep 2; sh startup.sh 1>>/tmp/start.log 2>&1'
    echo "==> Canal restarted."
    sleep 10
  done
}

echo "==> START ..."

start_exporter
wait_for_rabbitmq
start_canal

echo "==> START SUCCESSFUL ..."

# 后台启动 watchdog，持续监控 Canal 进程并在崩溃后自动重启
canal_watchdog &
WATCHDOG_PID=$!

# wait TERM signal
waitterm

echo "==> STOP"

# 停止 watchdog
kill "${WATCHDOG_PID}" 2>/dev/null || true

stop_canal
stop_exporter

echo "==> STOP SUCCESSFUL ..."
