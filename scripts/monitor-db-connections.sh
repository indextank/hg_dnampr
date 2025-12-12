#!/bin/bash

# 数据库连接监控脚本
# 实时监控 MySQL 连接状态和中断连接数

set -e

# 配置
MYSQL_CONTAINER="mysql"
MYSQL_ROOT_PASSWORD="bxiI2b8ZLYbaAdQBRT"
LOG_FILE="./logs/db-connection-monitor.log"
INTERVAL=60  # 检查间隔（秒）
ALERT_THRESHOLD=10  # 告警阈值：每分钟新增中断连接数

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 创建日志目录
mkdir -p "$(dirname "$LOG_FILE")"

# 日志函数
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${GREEN}[$1]${NC} $2" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[$1]${NC} $2" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$1]${NC} $2" | tee -a "$LOG_FILE"
}

# 检查 MySQL 容器是否运行
check_mysql_running() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${MYSQL_CONTAINER}$"; then
        log_error "ERROR" "MySQL 容器 ($MYSQL_CONTAINER) 未运行"
        return 1
    fi
    return 0
}

# 获取 MySQL 状态
get_mysql_stats() {
    docker exec "$MYSQL_CONTAINER" mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "
        SELECT
            VARIABLE_NAME,
            VARIABLE_VALUE
        FROM performance_schema.global_status
        WHERE VARIABLE_NAME IN (
            'Connections',
            'Aborted_connects',
            'Aborted_clients',
            'Threads_connected',
            'Max_used_connections',
            'Connection_errors_max_connections',
            'Connection_errors_internal'
        )
        ORDER BY VARIABLE_NAME;
    " 2>&1 | grep -v "Using a password"
}

# 获取特定指标值
get_metric_value() {
    local stats="$1"
    local metric="$2"
    echo "$stats" | grep "^${metric}" | awk '{print $2}'
}

# 显示启动信息
echo ""
echo "=========================================="
echo "MySQL 连接监控系统"
echo "=========================================="
echo "容器: $MYSQL_CONTAINER"
echo "监控间隔: ${INTERVAL}秒"
echo "日志文件: $LOG_FILE"
echo "告警阈值: 每分钟新增 ${ALERT_THRESHOLD} 个中断连接"
echo "=========================================="
echo ""

log "INFO" "监控系统启动"
log "INFO" "PID: $$"

# 检查 MySQL 是否运行
if ! check_mysql_running; then
    log "ERROR" "无法启动监控：MySQL 容器未运行"
    exit 1
fi

# 初始化计数器
PREVIOUS_CONNECTIONS=0
PREVIOUS_ABORTED=0
PREVIOUS_ABORTED_CLIENTS=0
ITERATION=0

# 主监控循环
while true; do
    ITERATION=$((ITERATION + 1))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # 检查 MySQL 是否还在运行
    if ! check_mysql_running; then
        log_error "ERROR" "MySQL 容器已停止运行"
        sleep $INTERVAL
        continue
    fi

    # 获取当前统计信息
    STATS=$(get_mysql_stats)

    if [ -z "$STATS" ]; then
        log_error "ERROR" "无法获取 MySQL 统计信息"
        sleep $INTERVAL
        continue
    fi

    # 提取各项指标
    TOTAL_CONNECTIONS=$(get_metric_value "$STATS" "Connections")
    ABORTED_CONNECTS=$(get_metric_value "$STATS" "Aborted_connects")
    ABORTED_CLIENTS=$(get_metric_value "$STATS" "Aborted_clients")
    THREADS_CONNECTED=$(get_metric_value "$STATS" "Threads_connected")
    MAX_USED_CONNECTIONS=$(get_metric_value "$STATS" "Max_used_connections")
    CONNECTION_ERRORS_MAX=$(get_metric_value "$STATS" "Connection_errors_max_connections")
    CONNECTION_ERRORS_INTERNAL=$(get_metric_value "$STATS" "Connection_errors_internal")

    # 计算增量
    NEW_CONNECTIONS=0
    NEW_ABORTED=0
    NEW_ABORTED_CLIENTS=0

    if [ $ITERATION -gt 1 ]; then
        NEW_CONNECTIONS=$((TOTAL_CONNECTIONS - PREVIOUS_CONNECTIONS))
        NEW_ABORTED=$((ABORTED_CONNECTS - PREVIOUS_ABORTED))
        NEW_ABORTED_CLIENTS=$((ABORTED_CLIENTS - PREVIOUS_ABORTED_CLIENTS))
    fi

    # 判断状态
    STATUS="OK"
    if [ "$NEW_ABORTED" -ge "$ALERT_THRESHOLD" ]; then
        STATUS="ALERT"
        log_warn "ALERT" "检测到 $NEW_ABORTED 个新的中断连接！"
    elif [ "$NEW_ABORTED" -gt 0 ]; then
        STATUS="WARN"
        log_warn "WARN" "检测到 $NEW_ABORTED 个新的中断连接"
    else
        log_info "INFO" "连接正常"
    fi

    # 详细日志
    if [ "$STATUS" != "OK" ] || [ $((ITERATION % 10)) -eq 0 ]; then
        # 每10次迭代或有问题时记录详细信息
        echo "" | tee -a "$LOG_FILE"
        echo "========================================" | tee -a "$LOG_FILE"
        echo "[$TIMESTAMP] 监控报告 #$ITERATION" | tee -a "$LOG_FILE"
        echo "========================================" | tee -a "$LOG_FILE"
        echo "总连接数:           $TOTAL_CONNECTIONS (+$NEW_CONNECTIONS)" | tee -a "$LOG_FILE"
        echo "中断连接:           $ABORTED_CONNECTS (+$NEW_ABORTED)" | tee -a "$LOG_FILE"
        echo "中断客户端:         $ABORTED_CLIENTS (+$NEW_ABORTED_CLIENTS)" | tee -a "$LOG_FILE"
        echo "当前活动连接:       $THREADS_CONNECTED" | tee -a "$LOG_FILE"
        echo "最大使用连接:       $MAX_USED_CONNECTIONS" | tee -a "$LOG_FILE"
        echo "连接数超限错误:     $CONNECTION_ERRORS_MAX" | tee -a "$LOG_FILE"
        echo "内部连接错误:       $CONNECTION_ERRORS_INTERNAL" | tee -a "$LOG_FILE"
        echo "状态:               $STATUS" | tee -a "$LOG_FILE"
        echo "========================================" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"

        # 如果有严重问题，获取更多诊断信息
        if [ "$STATUS" = "ALERT" ]; then
            echo "诊断信息:" | tee -a "$LOG_FILE"
            echo "----------------------------------------" | tee -a "$LOG_FILE"

            # 获取当前连接列表
            docker exec "$MYSQL_CONTAINER" mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "
                SELECT
                    SUBSTRING_INDEX(HOST, ':', 1) as client_host,
                    COUNT(*) as connection_count,
                    STATE
                FROM information_schema.PROCESSLIST
                WHERE USER != 'system user'
                GROUP BY client_host, STATE
                ORDER BY connection_count DESC
                LIMIT 10;
            " 2>&1 | grep -v "Using a password" | tee -a "$LOG_FILE"

            echo "" | tee -a "$LOG_FILE"

            # 检查错误日志（最后10行）
            echo "MySQL 错误日志 (最后10行):" | tee -a "$LOG_FILE"
            docker exec "$MYSQL_CONTAINER" tail -n 10 /var/log/mysql/error.log 2>/dev/null | tee -a "$LOG_FILE" || echo "无法读取错误日志" | tee -a "$LOG_FILE"

            echo "========================================" | tee -a "$LOG_FILE"
            echo "" | tee -a "$LOG_FILE"
        fi
    fi

    # 更新上一次的值
    PREVIOUS_CONNECTIONS=$TOTAL_CONNECTIONS
    PREVIOUS_ABORTED=$ABORTED_CONNECTS
    PREVIOUS_ABORTED_CLIENTS=$ABORTED_CLIENTS

    # 等待下一次检查
    sleep $INTERVAL
done
