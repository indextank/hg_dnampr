#!/bin/bash

# ==========================================
# Docker 项目构建脚本 v2.0
# ==========================================
# 功能：自动检测代理、支持并行构建、多架构构建
# 作者：重构版本
# 使用方法：./build.sh [服务名...] [环境] [选项]

set -euo pipefail

# ==========================================
# 自动检测 Docker Desktop 和 buildx
# ==========================================
detect_docker_environment() {
    local has_docker_desktop=false
    local has_buildx=false
    
    # 检测 Docker Desktop
    # 方法1: 检查 Docker Desktop 特有的 context
    if docker context ls 2>/dev/null | grep -q "desktop-linux\|desktop-windows"; then
        has_docker_desktop=true
    fi
    
    # 方法2: 检查 Docker Desktop 进程 (Windows/Mac)
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]] || [[ "$OSTYPE" == "darwin"* ]]; then
        if pgrep -f "Docker Desktop" >/dev/null 2>&1 || pgrep -f "com.docker.backend" >/dev/null 2>&1; then
            has_docker_desktop=true
        fi
    fi
    
    # 方法3: 检查 Docker 信息中的 Operating System 字段
    if docker info 2>/dev/null | grep -q "Docker Desktop\|Docker for"; then
        has_docker_desktop=true
    fi
    
    # 检测 buildx 插件
    if docker buildx version >/dev/null 2>&1; then
        has_buildx=true
    fi
    
    # 输出检测结果
    if [[ "$has_docker_desktop" == "true" && "$has_buildx" == "true" ]]; then
        echo "INFO: 检测到 Docker Desktop 和 buildx 插件，启用 BuildKit 功能"
        export DOCKER_BUILDKIT=1
        export COMPOSE_DOCKER_CLI_BUILD=1
    else
        echo "INFO: 未检测到完整的 Docker Desktop 环境，禁用 buildx/bake 功能"
        # 禁用 Docker Compose 的 buildx/bake 警告
        export DOCKER_BUILDKIT=0
        export COMPOSE_DOCKER_CLI_BUILD=0
    fi
}

# 执行 Docker 环境检测
detect_docker_environment

# 脚本配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# 引入公共函数库
source "$SCRIPT_DIR/scripts/common_functions.sh"

# 从分层配置文件中获取代理配置
DEFAULT_HTTP_PROXY=""
DEFAULT_HTTPS_PROXY=""
DEFAULT_NO_PROXY="localhost,127.0.0.1"

# 加载分层配置文件中的代理设置
load_proxy_config() {
    local config_dir="$SCRIPT_DIR/config/env"

    # 检查并加载base.env中的代理配置
    if [[ -f "$config_dir/base.env" ]]; then
        while IFS='=' read -r key value; do
            # 跳过注释和空行
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue

            # 去掉值中的注释部分和空格
            value=$(echo "$value" | sed 's/[[:space:]]*#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            case "$key" in
                HTTP_PROXY)
                    if [[ -n "$value" ]]; then
                        DEFAULT_HTTP_PROXY="$value"
                    fi
                    ;;
                HTTPS_PROXY)
                    if [[ -n "$value" ]]; then
                        DEFAULT_HTTPS_PROXY="$value"
                    fi
                    ;;
                NO_PROXY)
                    if [[ -n "$value" ]]; then
                        DEFAULT_NO_PROXY="$value"
                    fi
                    ;;
            esac
        done < "$config_dir/base.env"
    fi
}

# 加载代理配置
load_proxy_config

# 如果环境变量已设置，优先使用环境变量
if [ -n "${HTTP_PROXY:-}" ]; then
    DEFAULT_HTTP_PROXY="$HTTP_PROXY"
fi

if [ -n "${HTTPS_PROXY:-}" ]; then
    DEFAULT_HTTPS_PROXY="$HTTPS_PROXY"
fi

if [ -n "${NO_PROXY:-}" ]; then
    DEFAULT_NO_PROXY="$NO_PROXY"
fi

# 检测是否为WSL环境
is_wsl_environment() {
    if [[ -f "/proc/version" ]] && grep -qi "microsoft\|wsl" /proc/version; then
        return 0  # 是WSL环境
    fi
    return 1  # 不是WSL环境
}

# 智能代理检测函数
# detect_and_set_proxy() {
#     log "执行智能代理检测..."

#     # 检查是否强制禁用代理检测
#     if [[ "${DISABLE_PROXY_DETECTION:-false}" == "true" ]]; then
#         log "代理检测已被禁用 (DISABLE_PROXY_DETECTION=true)"
#         return 0
#     fi

#     # 检测地理位置
#     local location=""
#     local timeout=10

#     info "正在检测地理位置..."

#     # 方法1: 使用ipinfo.io检测
#     location=$(timeout $timeout curl -s --connect-timeout 5 "https://ipinfo.io/country" 2>/dev/null || echo "")
#     if [[ -n "$location" ]]; then
#         info "通过 ipinfo.io 检测到位置: $location"
#     fi

#     # 方法2: 如果第一种方法失败，使用ip-api.com
#     if [[ -z "$location" ]]; then
#         location=$(timeout $timeout curl -s --connect-timeout 5 "http://ip-api.com/line?fields=countryCode" 2>/dev/null || echo "")
#         if [[ -n "$location" ]]; then
#             info "通过 ip-api.com 检测到位置: $location"
#         fi
#     fi

#     # 方法3: 检查特定网站的可访问性
#     if [[ -z "$location" ]]; then
#         info "尝试通过网站可访问性判断位置..."
#         if ! timeout 5 curl -s --connect-timeout 3 "https://www.google.com" >/dev/null 2>&1; then
#             if timeout 5 curl -s --connect-timeout 3 "https://www.baidu.com" >/dev/null 2>&1; then
#                 location="CN"
#                 info "通过网站可访问性判断可能在中国大陆"
#             fi
#         fi
#     fi

#     # 根据位置设置代理和镜像源
#     if [[ "$location" =~ ^(CN|China|中国)$ ]]; then
#         log "检测到位置在中国大陆..."

#         # 从分层配置文件中读取代理配置
#         local env_http_proxy="${HTTP_PROXY:-}"
#         local env_https_proxy="${HTTPS_PROXY:-}"

#         # 检查代理配置是否为空
#         if [[ -z "$env_http_proxy" || -z "$env_https_proxy" ]]; then
#             if is_wsl_environment; then
#                 log "检测到WSL环境，自动设置代理配置..."
#                 export http_proxy="$DEFAULT_HTTP_PROXY"
#                 export https_proxy="$DEFAULT_HTTPS_PROXY"
#                 export HTTP_PROXY="$DEFAULT_HTTP_PROXY"
#                 export HTTPS_PROXY="$DEFAULT_HTTPS_PROXY"
#                 export no_proxy="$DEFAULT_NO_PROXY"
#                 export NO_PROXY="$DEFAULT_NO_PROXY"
#                 info "已设置代理: $DEFAULT_HTTP_PROXY"
#             else
#                 # 显示黄色加粗警告信息
#                 echo -e "\n${YELLOW}${BOLD}⚠️  当前处于国内运行环境，未设置http_proxy代理。${NC}"
#                 echo -e "${YELLOW}${BOLD}   建议在config/env/base.env文件中配置代理以提高构建速度：${NC}"
#                 echo -e "${YELLOW}${BOLD}   http_proxy=$DEFAULT_HTTP_PROXY${NC}"
#                 echo -e "${YELLOW}${BOLD}   https_proxy=$DEFAULT_HTTPS_PROXY${NC}"
#                 echo -e "${YELLOW}${BOLD}   10秒后继续执行...${NC}\n"

#                 # 倒计时显示
#                 for i in {10..1}; do
#                     echo -ne "${YELLOW}${BOLD}倒计时: $i 秒\r${NC}"
#                     sleep 1
#                 done
#                 echo -e "\n${GREEN}继续执行构建...${NC}\n"

#                 # 设置默认的代理配置
#                 export no_proxy="$DEFAULT_NO_PROXY"
#                 export NO_PROXY="$DEFAULT_NO_PROXY"
#             fi
#         else
#             log "使用分层配置文件中的代理配置..."
#             export http_proxy="$env_http_proxy"
#             export https_proxy="$env_https_proxy"
#             export HTTP_PROXY="$env_http_proxy"
#             export HTTPS_PROXY="$env_https_proxy"
#             export no_proxy="$DEFAULT_NO_PROXY"
#             export NO_PROXY="$DEFAULT_NO_PROXY"
#             info "代理配置: $env_http_proxy"
#         fi

#         # 中国大陆启用镜像源
#         export CHANGE_SOURCE="true"

#     else
#         log "检测到位置在海外，禁用代理配置，禁用镜像源..."
#         unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
#         export no_proxy="$DEFAULT_NO_PROXY"
#         export NO_PROXY="$DEFAULT_NO_PROXY"
#         export CHANGE_SOURCE="false"   # 海外使用镜像源加速
#     fi
# }

# 服务名映射函数
map_service_name() {
    local service="$1"
    case "$service" in
        php85) echo "php85_apache" ;;
        php84) echo "php84_apache" ;;
        php83) echo "php83_apache" ;;
        php82) echo "php82_apache" ;;
        php81) echo "php81_apache" ;;
        php80) echo "php80_apache" ;;
        php74) echo "php74_apache" ;;
        php72) echo "php72" ;;
        nginx) echo "nginx" ;;
        tengine) echo "tengine" ;;
        mysql) echo "mysql" ;;
        mysql_backup) echo "mysql_backup" ;;
        redis) echo "redis" ;;
        valkey) echo "valkey" ;;
        mongo) echo "mongo" ;;
        postgresql) echo "postgres" ;;
        pgadmin) echo "pgadmin" ;;
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
            echo "nginx php85_apache php84_apache php82_apache php74_apache mysql mysql_backup redis valkey"
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

    # 下载依赖软件包
    log "检查并下载构建依赖..."
    if [[ -f "$SCRIPT_DIR/scripts/download_dependencies.sh" ]]; then
        # 调用下载脚本
        if ! "$SCRIPT_DIR/scripts/download_dependencies.sh" "${services[@]}"; then
            warn "依赖下载失败，但继续构建过程"
        else
            success "依赖下载完成"
        fi
    else
        warn "下载脚本不存在: $SCRIPT_DIR/scripts/download_dependencies.sh"
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
    local auto_add_mysql_backup=false

    # 检查是否包含 mysql 服务，如果是则自动添加 mysql_backup
    for service in "${services[@]}"; do
        if [[ "$service" == "mysql" ]]; then
            auto_add_mysql_backup=true
            break
        fi
    done

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

    # 如果检测到 mysql 服务，自动添加 mysql_backup
    if [[ "$auto_add_mysql_backup" == "true" ]]; then
        # 检查是否已经包含 mysql_backup，避免重复添加
        local has_mysql_backup=false
        for service in "${final_services[@]}"; do
            if [[ "$service" == "mysql_backup" ]]; then
                has_mysql_backup=true
                break
            fi
        done

        if [[ "$has_mysql_backup" == "false" ]]; then
            final_services+=("mysql_backup")
            info "检测到 MySQL 服务，自动添加 mysql_backup 服务"
        fi

        # 根据构建的MySQL版本设置mysql_backup使用的镜像
        local mysql_backup_image="hg_dnmpr-mysql:latest"
        for service in "${services[@]}"; do
            if [[ "$service" == "mysql" ]]; then
                mysql_backup_image="hg_dnmpr-mysql:latest"
                info "设置 mysql_backup 使用 MySQL 镜像: $mysql_backup_image"
                break
            fi
        done

        # 导出环境变量供docker-compose使用
        export MYSQL_BACKUP_IMAGE="$mysql_backup_image"
    fi

    # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
    local compose_cmd=$(get_docker_compose_cmd)

    # 构建Docker命令
    local docker_cmd="$compose_cmd $compose_files build"

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
        docker_cmd="$compose_cmd $compose_files up --force-recreate"
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

    # 检测网络连接，如果无法访问 Docker Hub，自动启用国内镜像源
    if [[ "${CHANGE_SOURCE:-false}" != "true" ]]; then
        info "检测网络连接..."
        if ! timeout 5 curl -s -o /dev/null https://registry-1.docker.io 2>/dev/null; then
            warn "无法访问 Docker Hub，尝试启用国内镜像源加速"
            # 检测国内镜像源是否可访问
            if timeout 5 curl -s -o /dev/null https://mirrors.ustc.edu.cn 2>/dev/null; then
                export CHANGE_SOURCE=true
                info "已启用国内镜像源加速（CHANGE_SOURCE=true）"
            else
                warn "国内镜像源也无法访问，使用默认镜像源（可能需要配置代理）"
                export CHANGE_SOURCE=false
            fi
        else
            info "网络连接正常，使用默认镜像源"
        fi
    else
        # 如果已配置使用国内镜像源，检测是否可访问
        info "已配置使用国内镜像源加速（CHANGE_SOURCE=true）"
        if ! timeout 5 curl -s -o /dev/null https://mirrors.ustc.edu.cn 2>/dev/null; then
            warn "国内镜像源无法访问，回退到官方镜像源"
            export CHANGE_SOURCE=false
        fi
    fi

    # 确保代理环境变量被正确导出到Docker构建过程
    if [[ -n "${HTTP_PROXY:-}" ]]; then
        export HTTP_PROXY="$HTTP_PROXY"
        info "设置HTTP_PROXY: $HTTP_PROXY"
    else
        export HTTP_PROXY=""
        info "HTTP_PROXY未设置，使用空值"
    fi

    if [[ -n "${HTTPS_PROXY:-}" ]]; then
        export HTTPS_PROXY="$HTTPS_PROXY"
        info "设置HTTPS_PROXY: $HTTPS_PROXY"
    else
        export HTTPS_PROXY=""
        info "HTTPS_PROXY未设置，使用空值"
    fi

    if [[ -n "${NO_PROXY:-}" ]]; then
        export NO_PROXY="$NO_PROXY"
        info "设置NO_PROXY: $NO_PROXY"
    else
        export NO_PROXY="localhost,127.0.0.1"
        info "NO_PROXY未设置，使用默认值: localhost,127.0.0.1"
    fi

    # 执行命令
    eval "$docker_cmd"

    # 推送镜像（如果需要）
    if [[ "$PUSH_IMAGE" == "true" ]]; then
        log "推送镜像到仓库..."
        local compose_cmd=$(get_docker_compose_cmd)
        for service in "${final_services[@]}"; do
            $compose_cmd $compose_files push "$service" || warn "推送 $service 失败"
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

# 检查是否没有参数，如果没有参数则显示帮助信息
if [[ $# -eq 0 ]]; then
    show_build_help
    exit 0
fi

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        # 服务名
        php85|php84|php83|php82|php81|php80|php74|php72|nginx|tengine|mysql|mysql_backup|redis|valkey|mongo|postgres|elk|sgr|all)
            SERVICES+=("$1")
            shift
            ;;
        # 环境类型
        dev|development|prod|production)
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
        --help|-h|help)
            show_build_help
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

# 加载分层配置文件
load_config_files

# 加载ELK环境特定配置（如果构建ELK服务）
if [[ " ${SERVICES[@]} " =~ " elk " ]] || [[ " ${SERVICES[@]} " =~ " elasticsearch " ]] || [[ " ${SERVICES[@]} " =~ " kibana " ]] || [[ " ${SERVICES[@]} " =~ " logstash " ]]; then
    # 标准化环境名称
    env_name="$ENVIRONMENT"
    case "$env_name" in
        production|prod) env_name="prod" ;;
        development|dev) env_name="dev" ;;
        test|testing) env_name="test" ;;
        staging|stage) env_name="staging" ;;
        *) env_name="dev" ;;  # 默认为dev
    esac

    # 检查ELK环境配置文件
    config_dir="$PROJECT_DIR/config/env"
    elk_env_file="$config_dir/elk.${env_name}.env"
    if [[ -f "$elk_env_file" ]]; then
        info "🔧 加载ELK【${env_name}】环境配置: $elk_env_file"
        set -a
        source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$elk_env_file" 2>/dev/null || true)
        set +a
    else
        warn "未找到ELK环境配置文件: $elk_env_file，使用默认配置"
    fi
fi

# 执行代理检测
# detect_and_set_proxy

for i in {5..1}; do
    echo -ne "${YELLOW}${BOLD}倒计时: $i 秒\r${NC}"
    sleep 1
done

# 开始构建
log "开始 Docker 项目构建"

# 设置配置目录权限
setup_conf_permissions

# 配置Docker容器别名（传递脚本名称用于日志标识）
setup_docker_aliases "build"

# 清理日志文件
cleanup_logs

# 检查是否包含 all 参数，如果是则展示服务列表并倒计时
for service in "${SERVICES[@]}"; do
    if [[ "$service" == "all" ]]; then
        # 获取 all 对应的服务列表
        all_services=$(get_special_services "all")

        echo -e "\n${CYAN}${BOLD}=== 即将构建以下服务 ===${NC}"
        echo -e "${YELLOW}环境类型: ${ENVIRONMENT}${NC}"
        echo -e "${YELLOW}构建服务列表:${NC}"

        # 逐行显示服务
        for svc in $all_services; do
            case "$svc" in
                nginx)
                    echo -e "  • ${GREEN}nginx${NC}          - 标准的Nginx Web服务器"
                    ;;
                php85)
                    echo -e "  • ${GREEN}php85_apache${NC}   - PHP 8.5 + Apache 服务器"
                    ;;
                php84)
                    echo -e "  • ${GREEN}php84_apache${NC}   - PHP 8.4 + Apache 服务器"
                    ;;
                php82)
                    echo -e "  • ${GREEN}php82_apache${NC}   - PHP 8.2 + Apache 服务器"
                    ;;
                php74)
                    echo -e "  • ${GREEN}php74_apache${NC}   - PHP 7.4 + Apache 服务器"
                    ;;
                mysql)
                    echo -e "  • ${GREEN}mysql${NC}         - MySQL 8.0 数据库服务器"
                    ;;
                redis)
                    echo -e "  • ${GREEN}redis${NC}          - Redis 缓存服务器"
                    ;;
                valkey)
                    echo -e "  • ${GREEN}valkey${NC}         - Valkey 缓存服务器"
                    ;;
                *)
                    echo -e "  • ${GREEN}$svc${NC}"
                    ;;
            esac
        done

        echo -e "\n${YELLOW}${BOLD}⚠️  注意: 构建过程可能需要较长时间，请确保网络连接稳定${NC}"
        echo -e "${RED}${BOLD}如需取消构建，请按 Ctrl+C${NC}\n"

        # 倒计时15秒
        for i in {15..1}; do
            echo -ne "${YELLOW}${BOLD}构建将在 $i 秒后开始...\r${NC}"
            sleep 1
        done
        echo -e "${GREEN}${BOLD}开始构建！${NC}\n"

        break  # 找到 all 参数后退出循环
    fi
done

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
        up_cmd="$PROJECT_DIR/up.sh"

        # 添加服务名称
        for service in "${SERVICES[@]}"; do
            up_cmd+=" $service"
        done

        # 添加环境参数
        up_cmd+=" --env $ENVIRONMENT"

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
