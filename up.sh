#!/bin/bash

# ==========================================
# Docker 项目管理脚本 v2.0
# ==========================================
# 功能：服务启动、停止、重启、容器管理
# 作者：重构版本
# 使用方法：./up.sh [服务名...] [操作] [选项]

set -euo pipefail

# 脚本配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
LOG_DIR="$PROJECT_DIR/logs/up"
LOG_FILE="$LOG_DIR/up-$(date +%Y%m%d-%H%M%S).log"

# 创建日志目录
mkdir -p "$LOG_DIR"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE" >&2
    exit 1
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1" | tee -a "$LOG_FILE"
}

# 设置配置目录权限，避免容器内权限问题
setup_conf_permissions() {
    info "设置配置目录权限..."
    
    # 确保conf目录存在并设置权限
    if [ -d "./conf" ]; then
        # 设置目录权限为755，文件权限为644
        find ./conf -type d -exec chmod 755 {} \; 2>/dev/null || true
        find ./conf -type f -exec chmod 644 {} \; 2>/dev/null || true
        
        # 特别处理logstash配置文件，需要写权限
        if [ -d "./conf/logstash" ]; then
            chmod -R 777 ./conf/logstash 2>/dev/null || true
            # find ./conf/logstash -name "*.yml" -exec chmod 664 {} \; 2>/dev/null || true
            # find ./conf/logstash -name "*.properties" -exec chmod 664 {} \; 2>/dev/null || true
        fi

        # 设置elasticsearch配置权限
        if [ -d "./conf/elasticsearch" ]; then
            chmod -R 755 ./conf/elasticsearch 2>/dev/null || true
        fi
        
        # 设置kibana配置权限
        if [ -d "./conf/kibana" ]; then
            chmod -R 755 ./conf/kibana 2>/dev/null || true
        fi
        
        info "配置目录权限设置完成"
    else
        warn "配置目录 ./conf 不存在"
    fi
}

# 显示使用帮助
show_help() {
    cat << EOF
${CYAN}Docker 项目管理脚本 v2.0${NC}

${YELLOW}使用方法:${NC}
    $0 [服务名...] [操作] [选项]

${YELLOW}服务名:${NC}
    php84, php83, php82, php81, php80, php74, php72  - PHP服务
    nginx, tengine                                    - Web服务器 ⚠️ 二选一
    mysql8, mysql57                                   - MySQL数据库 ⚠️ 二选一
    redis, valkey                                     - 缓存服务
    mongo, postgresql                                 - 其他数据库
    elk                                              - ELK栈
    sgr                                              - Spug+Gitea+Rap2栈
    all                                              - 所有服务

${YELLOW}操作:${NC}
    up          - 启动服务 (默认)
    start       - 启动服务 (同up)
    stop        - 停止服务
    restart     - 重启服务
    down        - 停止并删除服务
    logs        - 查看服务日志
    ps          - 查看服务状态
    exec        - 进入服务容器
    clear       - 清理Docker系统
    delete      - 强制删除所有容器
    prune       - 清理未使用的资源

${YELLOW}选项:${NC}
    -d, --detach       后台运行
    -f, --follow       跟踪日志输出
    --tail N           显示最后N行日志
    --env ENV          指定环境 (dev/prod/test, 默认dev)
    --help, -h         显示此帮助信息

${YELLOW}示例:${NC}
    $0 php84                                        # 启动PHP84服务
    $0 php84 nginx -d                               # 后台启动PHP84和Nginx
    $0 php84 restart                                # 重启PHP84服务
    $0 php84 mongo stop                             # 停止PHP84和Mongo服务
    $0 php84 mongo down                             # 停止并删除PHP84和Mongo服务
    $0 php84 logs -f                                # 跟踪PHP84日志
    $0 php84 logs --tail 100                        # 显示PHP84最后100行日志
    $0 php84 exec                                   # 进入PHP84容器
    $0 up -d                                        # 后台启动所有服务
    $0 down                                         # 停止所有服务
    $0 restart                                      # 重启所有服务
    $0 clear                                        # 清理Docker系统
    $0 delete                                       # 强制删除所有容器
    $0 elk --env prod                               # 启动ELK栈生产环境

${YELLOW}特殊操作:${NC}
    up/down     - 对所有已安装/启动的容器执行操作
    clear       - 相当于 docker system prune
    delete      - 相当于 docker container rm --force \$(docker container ls -a -q)
    prune       - 清理未使用的镜像、容器、网络、卷

EOF
}

# 服务名映射函数
map_service_name() {
    local service="$1"
    case "$service" in
        php84) echo "php84_apache" ;;
        php83) echo "php83_apache" ;;
        php82) echo "php82_apache" ;;
        php81) echo "php81_apache" ;;
        php80) echo "php80_apache" ;;
        php74) echo "php74_apache" ;;
        php72) echo "php72_apache" ;;
        nginx) echo "nginx" ;;
        tengine) echo "tengine" ;;
        mysql8) echo "mysql8" ;;
        mysql57) echo "mysql57" ;;
        redis) echo "redis" ;;
        valkey) echo "valkey" ;;
        mongo) echo "mongo" ;;
        postgresql) echo "postgresql" ;;
        *) echo "$service" ;;
    esac
}

# 获取compose文件
get_compose_files() {
    local environment="$1"
    local services=("${@:2}")
    
    # 检查是否包含特殊组合
    for service in "${services[@]}"; do
        case "$service" in
            elk)
                echo "-f docker-compose-ELK.yaml"
                return
                ;;
            sgr)
                echo "-f docker-compose-spug+gitea+rap2.yaml"
                return
                ;;
        esac
    done
    
    # 标准组合
    case "$environment" in
        dev|development)
            echo "-f docker-compose.yaml -f docker-compose.dev.yaml"
            ;;
        prod|production)
            echo "-f docker-compose.yaml -f docker-compose.prod.yaml"
            ;;
        test|testing)
            echo "-f docker-compose.yaml -f docker-compose.test.yaml"
            ;;
        *)
            echo "-f docker-compose.yaml -f docker-compose.dev.yaml"
            ;;
    esac
}

# 获取特殊组合的服务列表
get_special_services() {
    local service="$1"
    case "$service" in
        elk)
            echo "elasticsearch kibana logstash"
            ;;
        sgr)
            echo ""  # SGR通常操作整个栈
            ;;
        all)
            # 获取所有运行中的服务
            echo ""  # 空表示所有服务
            ;;
        *)
            echo ""
            ;;
    esac
}

# 执行Docker Compose命令
execute_compose_command() {
    local environment="$1"
    local operation="$2"
    local options="$3"
    shift 3
    local services=("$@")
    
    # MySQL服务冲突检测
    local has_mysql=false
    local has_mysql8=false
    for service in "${services[@]}"; do
        if [[ "$service" == "mysql" ]]; then
            has_mysql=true
        elif [[ "$service" == "mysql8" ]]; then
            has_mysql8=true
        fi
    done
    
    if [[ "$has_mysql" == "true" && "$has_mysql8" == "true" ]]; then
        echo -e "${RED}❌ 检测到同时指定了 mysql 和 mysql8 服务！${NC}" >&2
        echo "" >&2
        echo -e "${YELLOW}${BOLD}⚠️  重要提示：${NC}" >&2
        echo -e "  • mysql-server:  使用 Dockerfile (标准安装方式，端口3306)" >&2
        echo -e "  • mysql8-server: 使用 Dockerfile_gf (优化安装方式，端口3307)" >&2
        echo "" >&2
        echo -e "${CYAN}请选择其中一种MySQL服务：${NC}" >&2
        echo -e "  ./up.sh mysql $operation    # 使用标准安装方式" >&2
        echo -e "  ./up.sh mysql8 $operation   # 使用优化安装方式" >&2
        echo "" >&2
        exit 1
    fi
    
    # Web服务冲突检测
    local has_nginx=false
    local has_tengine=false
    for service in "${services[@]}"; do
        if [[ "$service" == "nginx" ]]; then
            has_nginx=true
        elif [[ "$service" == "tengine" ]]; then
            has_tengine=true
        fi
    done
    
    if [[ "$has_nginx" == "true" && "$has_tengine" == "true" ]]; then
        echo -e "${RED}❌ 检测到同时指定了 nginx 和 tengine 服务！${NC}" >&2
        echo "" >&2
        echo -e "${YELLOW}${BOLD}⚠️  重要提示：${NC}" >&2
        echo -e "  • nginx-server:  标准的Nginx Web服务器" >&2
        echo -e "  • tengine-server: 阿里巴巴开源的Nginx增强版" >&2
        echo "" >&2
        echo -e "${CYAN}请选择其中一种Web服务器：${NC}" >&2
        echo -e "  ./up.sh nginx $operation     # 使用标准Nginx" >&2
        echo -e "  ./up.sh tengine $operation   # 使用Tengine增强版" >&2
        echo "" >&2
        exit 1
    fi
    
    # 获取compose文件
    local compose_files=$(get_compose_files "$environment" "${services[@]}")
    
    # 处理特殊组合
    local final_services=()
    for service in "${services[@]}"; do
        local special_services=$(get_special_services "$service")
        if [[ -n "$special_services" ]]; then
            final_services+=($special_services)
        elif [[ "$service" != "all" ]]; then
            final_services+=($(map_service_name "$service"))
        fi
    done
    
    # 构建Docker命令
    local docker_cmd="docker compose $compose_files"
    
    case "$operation" in
        up|start)
            docker_cmd="$docker_cmd up"
            if [[ "$options" =~ -d|--detach ]]; then
                docker_cmd="$docker_cmd -d"
            fi
            ;;
        stop)
            docker_cmd="$docker_cmd stop"
            ;;
        restart)
            docker_cmd="$docker_cmd restart"
            ;;
        down)
            docker_cmd="$docker_cmd down"
            ;;
        logs)
            docker_cmd="$docker_cmd logs"
            if [[ "$options" =~ -f|--follow ]]; then
                docker_cmd="$docker_cmd -f"
            fi
            if [[ "$options" =~ --tail[[:space:]]+([0-9]+) ]]; then
                local tail_lines="${BASH_REMATCH[1]}"
                docker_cmd="$docker_cmd --tail $tail_lines"
            fi
            ;;
        ps)
            docker_cmd="$docker_cmd ps"
            ;;
        exec)
            if [[ ${#final_services[@]} -eq 0 ]]; then
                error "exec操作需要指定具体的服务名"
            fi
            local service_name="${final_services[0]}"
            docker_cmd="$docker_cmd exec $service_name bash"
            ;;
        *)
            error "未知操作: $operation"
            ;;
    esac
    
    # 添加服务名（除了某些特殊操作）
    if [[ "$operation" != "exec" ]] && [[ ${#final_services[@]} -gt 0 ]]; then
        docker_cmd="$docker_cmd ${final_services[*]}"
    fi
    
    # 执行命令
    log "执行命令: $docker_cmd"
    info "操作: $operation"
    info "环境: $environment"
    info "服务: ${final_services[*]:-所有服务}"
    
    eval "$docker_cmd"
}

# 系统清理操作
system_operations() {
    local operation="$1"
    
    case "$operation" in
        clear)
            log "执行Docker系统清理..."
            docker system prune -f
            success "Docker系统清理完成"
            ;;
        delete)
            log "强制删除所有容器..."
            local containers=$(docker container ls -a -q)
            if [[ -n "$containers" ]]; then
                docker container rm --force $containers
                success "所有容器已删除"
            else
                info "没有找到容器"
            fi
            ;;
        prune)
            log "清理未使用的Docker资源..."
            docker system prune -a -f --volumes
            success "Docker资源清理完成"
            ;;
        *)
            error "未知系统操作: $operation"
            ;;
    esac
}

# 显示服务状态
show_status() {
    local environment="$1"
    
    log "显示服务状态..."
    
    # 显示所有compose文件的状态
    local compose_files="-f docker-compose.yaml -f docker-compose.${environment}.yaml"
    
    echo -e "\n${CYAN}=== 主要服务状态 ===${NC}"
    docker compose $compose_files ps 2>/dev/null || warn "无法获取主要服务状态"
    
    echo -e "\n${CYAN}=== ELK服务状态 ===${NC}"
    docker compose -f docker-compose-ELK.yaml ps 2>/dev/null || warn "无法获取ELK服务状态"
    
    echo -e "\n${CYAN}=== SGR服务状态 ===${NC}"
    docker compose -f docker-compose-spug+gitea+rap2.yaml ps 2>/dev/null || warn "无法获取SGR服务状态"
    
    echo -e "\n${CYAN}=== 系统资源使用情况 ===${NC}"
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" 2>/dev/null || warn "无法获取资源使用情况"
}

# 参数解析
SERVICES=()
OPERATION="up"
ENVIRONMENT="dev"
DETACH="false"
FOLLOW="false"
TAIL_LINES=""
OPTIONS=""

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        # 服务名
        php84|php83|php82|php81|php80|php74|php72|nginx|tengine|mysql8|mysql|redis|valkey|mongo|postgres|elk|sgr|all)
            SERVICES+=("$1")
            shift
            ;;
        # 操作
        up|start|stop|restart|down|logs|ps|exec|clear|delete|prune)
            OPERATION="$1"
            shift
            ;;
        # 选项
        -d|--detach)
            DETACH="true"
            OPTIONS="$OPTIONS -d"
            shift
            ;;
        -f|--follow)
            FOLLOW="true"
            OPTIONS="$OPTIONS -f"
            shift
            ;;
        --tail)
            if [[ $# -gt 1 ]]; then
                TAIL_LINES="$2"
                OPTIONS="$OPTIONS --tail $2"
                shift 2
            else
                error "--tail 需要指定行数"
            fi
            ;;
        --env)
            if [[ $# -gt 1 ]]; then
                ENVIRONMENT="$2"
                shift 2
            else
                error "--env 需要指定环境名"
            fi
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            error "未知参数: $1\n使用 --help 查看帮助信息"
            ;;
    esac
done

# 切换到项目目录
cd "$PROJECT_DIR"

# 检查.env文件
if [[ ! -f ".env" ]]; then
    if [[ -f ".env.example" ]]; then
        warn ".env文件不存在，从.env.example复制..."
        cp .env.example .env
    else
        error ".env文件不存在，请先创建.env文件"
    fi
fi

# 开始操作
log "开始 Docker 项目管理"
log "操作日志: $LOG_FILE"

# 设置配置目录权限
setup_conf_permissions

# 处理系统级操作
case "$OPERATION" in
    clear|delete|prune)
        system_operations "$OPERATION"
        exit 0
        ;;
    ps)
        if [[ ${#SERVICES[@]} -eq 0 ]]; then
            show_status "$ENVIRONMENT"
            exit 0
        fi
        ;;
esac

# 处理全局操作（无服务名指定）
if [[ ${#SERVICES[@]} -eq 0 ]]; then
    case "$OPERATION" in
        up|start)
            log "启动所有服务..."
            compose_files=$(get_compose_files "$ENVIRONMENT")
            docker_cmd="docker compose $compose_files up"
            if [[ "$DETACH" == "true" ]]; then
                docker_cmd="$docker_cmd -d"
            fi
            eval "$docker_cmd"
            success "所有服务启动完成"
            ;;
        down)
            log "停止所有服务..."
            compose_files=$(get_compose_files "$ENVIRONMENT")
            docker compose $compose_files down
            success "所有服务已停止"
            ;;
        restart)
            log "重启所有服务..."
            compose_files=$(get_compose_files "$ENVIRONMENT")
            docker compose $compose_files restart
            success "所有服务重启完成"
            ;;
        *)
            error "操作 '$OPERATION' 需要指定服务名"
            ;;
    esac
else
    # 处理指定服务的操作
    execute_compose_command "$ENVIRONMENT" "$OPERATION" "$OPTIONS" "${SERVICES[@]}"
    success "操作完成"
fi

log "所有操作完成！" 