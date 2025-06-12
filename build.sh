#!/bin/bash

# ==========================================
# Docker 项目构建脚本 v2.0
# ==========================================
# 功能：自动检测代理、支持并行构建、多架构构建
# 作者：重构版本
# 使用方法：./build.sh [服务名...] [环境] [选项]

set -euo pipefail

# 脚本配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
LOG_DIR="$PROJECT_DIR/logs/build"
LOG_FILE="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"

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
${CYAN}Docker 项目构建脚本 v2.0${NC}

${YELLOW}使用方法:${NC}
    $0 [服务名...] [环境] [选项]

${YELLOW}服务名:${NC}
    php84, php83, php82, php81, php80, php74, php72  - PHP服务
    nginx, tengine                                    - Web服务器 ⚠️ 二选一
    mysql8, mysql                                   - MySQL数据库 ⚠️ 二选一
    redis, valkey                                     - 缓存服务
    mongo, postgresql                                 - 其他数据库
    elk                                              - ELK栈 (elasticsearch, kibana, logstash)
    sgr                                              - Spug+Gitea+Rap2栈
    all                                              - 所有服务

${YELLOW}环境类型:${NC}
    dev, development    - 开发环境 (默认)
    prod, production    - 生产环境
    test, testing       - 测试环境

${YELLOW}选项:${NC}
    --no-cache         不使用构建缓存
    --parallel         并行构建 (默认启用)
    --no-parallel      禁用并行构建
    --multi-arch       多架构构建 (linux/amd64,linux/arm64)
    --push             构建完成后推送到镜像仓库
    --force-recreate   强制重新创建容器
    --auto-prune       构建后自动清理
    --auto-up          构建后自动启动服务
    --help, -h         显示此帮助信息

${YELLOW}示例:${NC}
    $0 php84 dev                                    # 构建PHP84开发环境
    $0 php84 dev --no-cache                         # 无缓存构建PHP84
    $0 php84 php82 mysql8 valkey prod               # 构建多个服务生产环境
    $0 php84 php82 mysql8 valkey prod --force-recreate  # 强制重新创建
    $0 elk prod                                     # 构建ELK栈生产环境
    $0 sgr prod                                     # 构建SGR栈生产环境
    $0 php84 dev --multi-arch                       # 多架构构建

${YELLOW}特殊组合:${NC}
    elk     -> elasticsearch, kibana, logstash
    sgr     -> spug, gitea, rap2
    all     -> 所有可用服务

EOF
}

# 代理配置变量（方便维护修改）
DEFAULT_HTTP_PROXY="http://host.docker.internal:60010"
DEFAULT_HTTPS_PROXY="http://host.docker.internal:60010"
DEFAULT_NO_PROXY="localhost,127.0.0.1,172.17.0.0/16,host.docker.internal"

# 检测是否为WSL环境
is_wsl_environment() {
    if [[ -f "/proc/version" ]] && grep -qi "microsoft\|wsl" /proc/version; then
        return 0  # 是WSL环境
    fi
    return 1  # 不是WSL环境
}

# 智能代理检测函数
detect_and_set_proxy() {
    log "执行智能代理检测..."
    
    # 检查是否强制禁用代理检测
    if [[ "${DISABLE_PROXY_DETECTION:-false}" == "true" ]]; then
        log "代理检测已被禁用 (DISABLE_PROXY_DETECTION=true)"
        return 0
    fi
    
    # 检测地理位置
    local location=""
    local timeout=10
    
    info "正在检测地理位置..."
    
    # 方法1: 使用ipinfo.io检测
    location=$(timeout $timeout curl -s --connect-timeout 5 "https://ipinfo.io/country" 2>/dev/null || echo "")
    if [[ -n "$location" ]]; then
        info "通过 ipinfo.io 检测到位置: $location"
    fi
    
    # 方法2: 如果第一种方法失败，使用ip-api.com
    if [[ -z "$location" ]]; then
        location=$(timeout $timeout curl -s --connect-timeout 5 "http://ip-api.com/line?fields=countryCode" 2>/dev/null || echo "")
        if [[ -n "$location" ]]; then
            info "通过 ip-api.com 检测到位置: $location"
        fi
    fi
    
    # 方法3: 检查特定网站的可访问性
    if [[ -z "$location" ]]; then
        info "尝试通过网站可访问性判断位置..."
        if ! timeout 5 curl -s --connect-timeout 3 "https://www.google.com" >/dev/null 2>&1; then
            if timeout 5 curl -s --connect-timeout 3 "https://www.baidu.com" >/dev/null 2>&1; then
                location="CN"
                info "通过网站可访问性判断可能在中国大陆"
            fi
        fi
    fi
    
    # 根据位置设置代理和镜像源
    if [[ "$location" =~ ^(CN|China|中国)$ ]]; then
        log "检测到位置在中国大陆..."
        
        # 从.env文件读取代理配置
        local env_http_proxy=""
        local env_https_proxy=""
        
        if [[ -f ".env" ]]; then
            env_http_proxy=$(grep "^http_proxy=" .env 2>/dev/null | cut -d'=' -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            env_https_proxy=$(grep "^https_proxy=" .env 2>/dev/null | cut -d'=' -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        fi
        
        # 检查代理配置是否为空
        if [[ -z "$env_http_proxy" || -z "$env_https_proxy" ]]; then
            if is_wsl_environment; then
                log "检测到WSL环境，自动设置代理配置..."
                export http_proxy="$DEFAULT_HTTP_PROXY"
                export https_proxy="$DEFAULT_HTTPS_PROXY"
                export no_proxy="$DEFAULT_NO_PROXY"
                info "已设置代理: $DEFAULT_HTTP_PROXY"
            else
                # 显示黄色加粗警告信息
                echo -e "\n${YELLOW}${BOLD}⚠️  当前处于国内运行环境，未设置http_proxy代理。${NC}"
                echo -e "${YELLOW}${BOLD}   建议在.env文件中配置代理以提高构建速度：${NC}"
                echo -e "${YELLOW}${BOLD}   http_proxy=$DEFAULT_HTTP_PROXY${NC}"
                echo -e "${YELLOW}${BOLD}   https_proxy=$DEFAULT_HTTPS_PROXY${NC}"
                echo -e "${YELLOW}${BOLD}   10秒后继续执行...${NC}\n"
                
                # 倒计时显示
                for i in {10..1}; do
                    echo -ne "${YELLOW}${BOLD}倒计时: $i 秒\r${NC}"
                    sleep 1
                done
                echo -e "\n${GREEN}继续执行构建...${NC}\n"
                
                # 设置默认的no_proxy
                export no_proxy="$DEFAULT_NO_PROXY"
            fi
        else
            log "使用.env文件中的代理配置..."
            export http_proxy="$env_http_proxy"
            export https_proxy="$env_https_proxy"
            export no_proxy="$DEFAULT_NO_PROXY"
            info "代理配置: $env_http_proxy"
        fi
        
        # 中国大陆启用镜像源
        export CHANGE_SOURCE="true"
        
    else
        log "检测到位置在海外，禁用代理配置，禁用镜像源..."
        unset http_proxy https_proxy
        export no_proxy="$DEFAULT_NO_PROXY"
        export CHANGE_SOURCE="false"   # 海外使用镜像源加速
    fi
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
        mysql) echo "mysql" ;;
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
            echo ""  # SGR通常构建整个栈
            ;;
        all)
            echo "nginx php84_apache php82_apache php74_apache mysql8 redis valkey"
            ;;
        *)
            echo ""
            ;;
    esac
}

# 构建函数
build_services() {
    local environment="$1"
    shift
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
        echo -e "  • mysql-server:  使用 Dockerfile (标准安装方式)" >&2
        echo -e "  • mysql8-server: 使用 Dockerfile_gf (优化安装方式)" >&2
        echo "" >&2
        echo -e "${CYAN}请选择其中一种MySQL服务：${NC}" >&2
        echo -e "  ./build.sh mysql $environment    # 使用标准安装方式" >&2
        echo -e "  ./build.sh mysql8 $environment   # 使用优化安装方式" >&2
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
        echo -e "  ./build.sh nginx $environment     # 使用标准Nginx" >&2
        echo -e "  ./build.sh tengine $environment   # 使用Tengine增强版" >&2
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
            if [[ "$service" == "all" ]]; then
                final_services+=($special_services)
            else
                final_services+=($special_services)
            fi
        else
            final_services+=($(map_service_name "$service"))
        fi
    done
    
    # 构建Docker命令
    local docker_cmd="docker compose $compose_files build"
    
    # 添加选项
    if [[ "$NO_CACHE" == "true" ]]; then
        docker_cmd="$docker_cmd --no-cache"
    fi
    
    if [[ "$PARALLEL_BUILD" == "true" ]] && [[ ${#final_services[@]} -gt 1 ]]; then
        docker_cmd="$docker_cmd --parallel"
    fi
    
    if [[ "$MULTI_ARCH" == "true" ]]; then
        docker_cmd="$docker_cmd --platform linux/amd64,linux/arm64"
    fi
    
    if [[ "$FORCE_RECREATE" == "true" ]]; then
        # 如果是force-recreate，使用up命令而不是build
        docker_cmd="docker compose $compose_files up --force-recreate"
        if [[ ${#final_services[@]} -gt 0 ]]; then
            docker_cmd="$docker_cmd ${final_services[*]}"
        fi
    else
        # 添加服务名
        if [[ ${#final_services[@]} -gt 0 ]]; then
            docker_cmd="$docker_cmd ${final_services[*]}"
        fi
    fi
    
    # 执行构建
    log "执行构建命令: $docker_cmd"
    info "构建环境: $environment"
    info "构建服务: ${final_services[*]:-所有服务}"
    
    # 清屏并执行
    clear
    
    # 设置Docker构建环境变量
    export DOCKER_BUILDKIT=1
    export COMPOSE_DOCKER_CLI_BUILD=1
    
    # 执行命令
    eval "$docker_cmd"
    
    # 推送镜像（如果需要）
    if [[ "$PUSH_IMAGE" == "true" ]]; then
        log "推送镜像到仓库..."
        for service in "${final_services[@]}"; do
            docker compose $compose_files push "$service" || warn "推送 $service 失败"
        done
    fi
    
    log "构建完成！"
}

# 参数解析
SERVICES=()
ENVIRONMENT="dev"
NO_CACHE="false"
PARALLEL_BUILD="true"  # 默认启用并行构建
MULTI_ARCH="false"
PUSH_IMAGE="false"
FORCE_RECREATE="false"
AUTO_PRUNE="false"  # 新增：构建后自动清理
AUTO_UP="false"  # 新增：构建后自动启动服务

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        # 服务名
        php84|php83|php82|php81|php80|php74|php72|nginx|tengine|mysql8|mysql|redis|valkey|mongo|postgres|elk|sgr|all)
            SERVICES+=("$1")
            shift
            ;;
        # 环境类型
        dev|development|prod|production|test|testing)
            ENVIRONMENT="$1"
            shift
            ;;
        # 选项
        --no-cache)
            NO_CACHE="true"
            shift
            ;;
        --parallel)
            PARALLEL_BUILD="true"
            shift
            ;;
        --no-parallel)
            PARALLEL_BUILD="false"
            shift
            ;;
        --multi-arch)
            MULTI_ARCH="true"
            shift
            ;;
        --push)
            PUSH_IMAGE="true"
            shift
            ;;
        --force-recreate)
            FORCE_RECREATE="true"
            shift
            ;;
        --auto-prune)
            AUTO_PRUNE="true"
            shift
            ;;
        --auto-up)
            AUTO_UP="true"
            shift
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

# 验证参数
if [[ ${#SERVICES[@]} -eq 0 ]]; then
    error "请指定至少一个服务名\n使用 --help 查看帮助信息"
fi

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

# 加载环境变量
if [[ -f ".env" ]]; then
    set +u
    while IFS='=' read -r key value; do
        # 跳过注释和空行
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        
        # 去掉值中的注释部分
        value=$(echo "$value" | sed 's/[[:space:]]*#.*$//')
        
        # 设置环境变量
        if [[ -n "$value" ]]; then
            export "$key"="$value"
        fi
    done < <(grep -v '^[[:space:]]*#' .env | grep -v '^[[:space:]]*$')
    set -u
    
    log "环境变量加载完成"
else
    warn ".env 文件不存在，使用默认配置"
fi

# 执行代理检测
detect_and_set_proxy

# 开始构建
log "开始 Docker 项目构建"
log "构建日志: $LOG_FILE"

# 设置配置目录权限
setup_conf_permissions

build_services "$ENVIRONMENT" "${SERVICES[@]}"

# 构建后自动清理
if [[ "$AUTO_PRUNE" == "true" ]]; then
    log "开始构建后自动清理..."
    
    # 显示清理前的磁盘使用情况
    info "清理前的Docker磁盘使用情况:"
    sudo docker system df
    
    # 执行清理
    log "执行 Docker 系统清理..."
    if sudo docker system prune -f; then
        success "Docker 系统清理完成"
    else
        warn "Docker 系统清理失败，但不影响构建结果"
    fi
    
    # 显示清理后的磁盘使用情况
    info "清理后的Docker磁盘使用情况:"
    sudo docker system df
fi

# 构建后自动启动服务
if [[ "$AUTO_UP" == "true" ]]; then
    log "开始构建后自动启动服务..."
    
    # 调用up.sh脚本来启动服务
    if [[ -f "$PROJECT_DIR/up.sh" ]]; then
        local up_cmd="$PROJECT_DIR/up.sh"
        
        # 添加服务名称
        for service in "${SERVICES[@]}"; do
            up_cmd+=" $service"
        done
        
        # 添加环境参数
        up_cmd+=" $ENVIRONMENT"
        
        log "执行启动命令: $up_cmd"
        
        if ! $up_cmd; then
            warn "服务启动失败，但不影响构建结果"
        else
            success "服务启动完成"
        fi
    else
        warn "up.sh脚本不存在，跳过自动启动"
    fi
fi

log "所有构建任务完成！" 