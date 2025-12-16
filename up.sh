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

# 加载公共函数库
source "$SCRIPT_DIR/scripts/common_functions.sh"

# 显示使用帮助
show_help() {
    cat << EOF
${CYAN}Docker 项目管理脚本 v2.0${NC}

${YELLOW}使用方法:${NC}
    $0 [服务名...] [操作] [选项]

${YELLOW}服务名:${NC}
    php85, php84, php83, php82, php81, php80, php74, php72  - PHP服务
    nginx, tengine                                    - Web服务器 ⚠️ 二选一
    mysql                                            - MySQL数据库
    redis, valkey                                     - 缓存服务
    mongo, postgresql                                 - 其他数据库
    elk                                              - ELK栈 (自动检测SSL配置并生成证书)
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
    clear       - 清理Docker系统（未使用的资源）
    delete      - 强制删除所有容器
    prune       - 清理未使用的资源（镜像、容器、网络、卷）
    clean-all   - 彻底清理所有容器、镜像、网络和卷（危险操作）
    purge       - 同 clean-all，彻底清理所有资源

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
    $0 down                                         # 停止并删除所有容器和网络
    $0 restart                                      # 重启所有服务
    $0 clear                                        # 清理Docker系统（未使用的资源）
    $0 delete                                       # 强制删除所有容器
    $0 prune                                        # 清理未使用的资源（镜像、容器、网络、卷）
    $0 clean-all                                    # 彻底清理所有容器、镜像、网络和卷（危险操作）
    $0 elk --env prod                               # 启动ELK栈生产环境 (自动检测并生成SSL证书)
    $0 elk dev                                      # 启动ELK栈开发环境 (根据配置决定是否生成证书)

${YELLOW}特殊操作:${NC}
    up          - 对所有已安装/启动的容器执行操作
    down        - 停止并删除所有容器、自定义网络，清理未使用镜像
    clear       - 清理未使用的资源（相当于 docker system prune）
    delete      - 强制删除所有容器（相当于 docker container rm --force \$(docker container ls -a -q)）
    prune       - 清理未使用的镜像、容器、网络、卷（相当于 docker system prune -a -f --volumes）
    clean-all   - ${RED}危险操作${NC}：彻底清理所有容器、镜像、网络和卷
                  • 停止并删除所有容器
                  • 删除所有镜像（包括正在使用的）
                  • 删除所有网络（除了默认网络）
                  • 删除所有卷（包括未使用的）
                  • 清理构建缓存
    purge       - 同 clean-all，彻底清理所有资源

${YELLOW}ELK SSL证书自动生成:${NC}
    当启动ELK服务时，脚本会自动检查以下内容：
    1. 读取 config/env/elk.[ENV].env 中的 ELK_HTTP_SSL_ENABLED 配置
    2. 如果 ELK_HTTP_SSL_ENABLED=true，则检查SSL证书是否存在
    3. 如果证书缺失或不完整，自动运行 scripts/generate-elk-certs.sh 生成证书
    4. 如果 ELK_HTTP_SSL_ENABLED=false，跳过证书生成

    ${GREEN}优势：${NC}避免因忘记生成证书导致ELK服务启动失败

${RED}${BOLD}⚠️  警告：clean-all 和 purge 操作会删除所有容器和镜像，请谨慎使用！${NC}

EOF
}

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
        php72) echo "php72_apache" ;;
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

# 检测是否为WSL环境
is_wsl_environment() {
    # 方法1: 检查环境变量
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        return 0  # 是WSL环境
    fi

    # 方法2: 检查内核版本信息
    if [[ -f "/proc/version" ]] && grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; then
        return 0  # 是WSL环境
    fi

    # 方法3: 检查内核release信息
    if [[ -f "/proc/sys/kernel/osrelease" ]] && grep -qi "microsoft\|wsl" /proc/sys/kernel/osrelease 2>/dev/null; then
        return 0  # 是WSL环境
    fi

    return 1  # 不是WSL环境
}

# 同步 hosts 别名映射（调用 scripts/update-hosts-aliases.sh）
sync_hosts_aliases() {
    local operation="$1"
    local services_list="${2:-}"  # 可选：指定服务列表，用空格分隔
    local mode="update"

    case "$operation" in
        stop|down|delete|purge|clean-all|clear|prune)
            mode="delete"
            ;;
        *)
            mode="update"
            ;;
    esac

    local script="$SCRIPT_DIR/scripts/update-hosts-aliases.sh"

    if [[ ! -f "$script" ]]; then
        warn "未找到 hosts 同步脚本: $script"
        return 0
    fi

    # 如果是update模式，等待容器完全启动
    if [[ "$mode" == "update" ]]; then
        info "等待容器启动完成..."
        sleep 3

        # 检查容器是否已经获得IP（最多等待30秒）
        local max_wait=30
        local waited=0
        while [[ $waited -lt $max_wait ]]; do
            local running_containers=$(docker ps -q 2>/dev/null | wc -l)
            if [[ $running_containers -gt 0 ]]; then
                # 检查是否所有运行中的容器都有IP
                local containers_with_ip=$(docker ps -q 2>/dev/null | xargs -I {} docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' {} 2>/dev/null | grep -v '^$' | wc -l)
                if [[ $containers_with_ip -eq $running_containers ]] || [[ $waited -ge 10 ]]; then
                    break
                fi
            fi
            sleep 2
            waited=$((waited + 2))
        done

        info "同步 hosts 别名到 /etc/hosts 和 Windows hosts (mode=$mode)..."
    else
        info "清理 hosts 别名 (mode=$mode)..."
    fi

    if ! bash "$script" --mode "$mode"; then
        warn "同步 hosts 失败，请检查权限或脚本输出"
    fi
}

# 在容器停止/删除前，预先缓存容器信息用于清理hosts
cache_containers_for_cleanup() {
    local script="$SCRIPT_DIR/scripts/update-hosts-aliases.sh"
    if [[ ! -f "$script" ]]; then
        return 0
    fi

    # 强制更新缓存（即使不修改hosts文件）
    local cache_file="/tmp/hg_dnmpr-hosts-entries"
    local entries=()
    local cids
    cids=$(docker ps -q 2>/dev/null || true)

    if [[ -n "$cids" ]]; then
        while read -r cid; do
            [[ -z "$cid" ]] && continue
            local ip name aliases alias_list
            ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null | xargs)
            if [[ -n "$ip" ]]; then
                name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')
                aliases=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{range $i,$a := .Aliases}}{{$a}} {{end}}{{end}}' "$cid" 2>/dev/null | xargs)
                alias_list="$name $aliases"
                alias_list=$(echo "$alias_list" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | xargs)
                [[ -z "$alias_list" ]] && alias_list="$name"
                entries+=("$ip $alias_list")
            fi
        done <<< "$cids"
    fi

    if [[ ${#entries[@]} -gt 0 ]]; then
        printf "%s\n" "${entries[@]}" > "$cache_file"
        info "已缓存 ${#entries[@]} 个容器信息用于清理 hosts"
    fi
}

# 获取compose文件
# 参数: environment [services...] [--silent]
# --silent: 静默模式，不输出WSL检测信息
get_compose_files() {
    local environment="$1"
    local services=()
    local silent=false
    local base_files=""
    local wsl_file=""

    # 解析参数，检查是否有 --silent 标志
    shift
    for arg in "$@"; do
        if [[ "$arg" == "--silent" ]]; then
            silent=true
        else
            services+=("$arg")
        fi
    done

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

    # 检查是否包含MySQL服务
    local has_mysql=false
    for service in "${services[@]}"; do
        case "$service" in
            mysql|mysql_backup)
                has_mysql=true
                break
                ;;
        esac
    done

    # 如果是MySQL服务且是WSL环境，添加WSL配置文件
    if [[ "$has_mysql" == "true" ]] && is_wsl_environment; then
        if [[ -f "docker-compose.wsl.yaml" ]]; then
            wsl_file="-f docker-compose.wsl.yaml"
            # 非静默模式才输出日志
            if [[ "$silent" == "false" ]]; then
                # 将日志输出到stderr，避免污染函数返回值
                info "检测到WSL环境，将使用WSL优化的MySQL配置" >&2
            fi
        fi
    fi

    # 标准组合
    case "$environment" in
        dev|development)
            base_files="-f docker-compose.yaml -f docker-compose.dev.yaml"
            ;;
        prod|production)
            base_files="-f docker-compose.yaml -f docker-compose.prod.yaml"
            ;;
        *)
            base_files="-f docker-compose.yaml -f docker-compose.dev.yaml"
            ;;
    esac

    # 组合输出：基础文件 + WSL文件（如果存在）
    if [[ -n "$wsl_file" ]]; then
        echo "$base_files $wsl_file"
    else
        echo "$base_files"
    fi
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

# 自动添加MySQL备份服务
auto_add_mysql_backup() {
    local -n services_ref=$1
    local operation=${2:-"操作"}

    # 检查是否包含mysql服务
    local has_mysql=false
    for service in "${services_ref[@]}"; do
        if [[ "$service" == "mysql" ]]; then
            has_mysql=true
            break
        fi
    done

    # 如果包含MySQL服务且未包含mysql_backup，则自动添加
    if [[ "$has_mysql" == "true" ]]; then
        local has_mysql_backup=false
        for service in "${services_ref[@]}"; do
            if [[ "$service" == "mysql_backup" ]]; then
                has_mysql_backup=true
                break
            fi
        done

        if [[ "$has_mysql_backup" == "false" ]]; then
            # 根据检测到的MySQL版本设置正确的镜像
            local mysql_backup_image="hg_dnmpr-mysql:latest"
            local mysql_version=""
            for service in "${services_ref[@]}"; do
                if [[ "$service" == "mysql" ]]; then
                    mysql_backup_image="hg_dnmpr-mysql:latest"
                    mysql_version="MySQL"
                    break
                fi
            done

            # 对于某些操作，需要检查mysql镜像是否存在
            if [[ "$operation" == "up" || "$operation" == "start" || "$operation" == "restart" ]]; then
                if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "$mysql_backup_image" 2>/dev/null; then
                    export MYSQL_BACKUP_IMAGE="$mysql_backup_image"
                    services_ref+=("mysql_backup")
                    info "检测到${mysql_version}服务，自动添加mysql_backup服务进行${operation}操作，使用镜像: $mysql_backup_image"
                fi
            else
                export MYSQL_BACKUP_IMAGE="$mysql_backup_image"
                services_ref+=("mysql_backup")
                info "检测到${mysql_version}服务，自动添加mysql_backup服务进行${operation}操作，使用镜像: $mysql_backup_image"
            fi
        fi
    fi
}

# 检查并生成ELK SSL证书（如果需要）
check_and_generate_elk_certs() {
    local environment="$1"
    local services=("${@:2}")

    # 只在包含ELK服务时检查证书
    local has_elk=false
    for service in "${services[@]}"; do
        if [[ "$service" == "elk" ]]; then
            has_elk=true
            break
        fi
    done

    if [[ "$has_elk" == "false" ]]; then
        return 0
    fi

    # 标准化环境名称
    local env_name="$environment"
    case "$env_name" in
        production|prod) env_name="prod" ;;
        development|dev) env_name="dev" ;;
        *) env_name="dev" ;;
    esac

    # 读取环境配置文件中的 ELK_HTTP_SSL_ENABLED 配置
    local elk_env_file="config/env/elk.${env_name}.env"
    local ssl_enabled="false"

    if [[ -f "$elk_env_file" ]]; then
        # 读取配置文件中的 ELK_HTTP_SSL_ENABLED 值
        if grep -q "^ELK_HTTP_SSL_ENABLED=true" "$elk_env_file" 2>/dev/null; then
            ssl_enabled="true"
        elif grep -q "^ELK_HTTP_SSL_ENABLED=false" "$elk_env_file" 2>/dev/null; then
            ssl_enabled="false"
        fi
    fi

    # 如果 SSL 未启用，跳过证书生成
    if [[ "$ssl_enabled" == "false" ]]; then
        info "ℹ️  SSL未启用 (ELK_HTTP_SSL_ENABLED=false)，跳过证书生成"
        return 0
    fi

    info "🔐 检测到SSL已启用 (ELK_HTTP_SSL_ENABLED=true)，检查证书状态..."

    # 检查证书是否存在
    local certs_dir="conf/elasticsearch/certs"
    local cert_files=(
        "$certs_dir/ca/ca.crt"
        "$certs_dir/ca/ca.key"
        "$certs_dir/elasticsearch/elasticsearch.crt"
        "$certs_dir/elasticsearch/elasticsearch.key"
        "$certs_dir/kibana/kibana.crt"
        "$certs_dir/kibana/kibana.key"
        "$certs_dir/logstash/logstash.crt"
        "$certs_dir/logstash/logstash.key"
    )

    local missing_certs=false
    local missing_cert_list=""
    for cert_file in "${cert_files[@]}"; do
        if [[ ! -f "$cert_file" ]]; then
            missing_certs=true
            missing_cert_list+="  ❌ $cert_file\n"
        fi
    done

    if [[ "$missing_certs" == "true" ]]; then
        warning "⚠️  检测到SSL证书文件不完整或缺失："
        echo -e "$missing_cert_list"
        info "正在自动生成SSL证书..."
        echo ""

        local cert_script="scripts/generate-elk-certs.sh"
        if [[ ! -f "$cert_script" ]]; then
            error "证书生成脚本不存在: $cert_script"
            error "请确保脚本位于: $cert_script"
            return 1
        fi

        # 执行证书生成脚本
        info "执行证书生成脚本: $cert_script"
        if bash "$cert_script"; then
            echo ""
            success "✅ SSL证书生成完成"
            info "证书已保存至: $certs_dir"
        else
            echo ""
            error "❌ SSL证书生成失败，请检查脚本输出"
            error "提示: 您可以手动运行 ./$cert_script 来生成证书"
            return 1
        fi
    else
        success "✅ SSL证书文件完整，验证通过"

        # 检查证书是否过期（可选）
        local ca_cert="$certs_dir/ca/ca.crt"
        if command -v openssl &> /dev/null && [[ -f "$ca_cert" ]]; then
            local expiry_date=$(openssl x509 -in "$ca_cert" -noout -enddate 2>/dev/null | cut -d= -f2)
            if [[ -n "$expiry_date" ]]; then
                info "证书有效期至: $expiry_date"
            fi
        fi
    fi

    return 0
}

# 执行Docker Compose命令
execute_compose_command() {
    local environment="$1"
    local operation="$2"
    local options="$3"
    shift 3
    local services=("$@")
    local trap_set=false

    # 在启动操作时，检查ELK证书（仅生产环境）
    if [[ "$operation" == "up" || "$operation" == "start" ]]; then
        if ! check_and_generate_elk_certs "$environment" "${services[@]}"; then
            error "ELK证书检查失败，操作终止"
            return 1
        fi
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

    # redis冲突检测
    local has_redis=false
    local has_valkey=false
    for service in "${services[@]}"; do
        if [[ "$service" == "redis" ]]; then
            has_redis=true
        elif [[ "$service" == "valkey" ]]; then
            has_valkey=true
        fi
    done

    if [[ "$has_redis" == "true" && "$has_valkey" == "true" ]]; then
        echo -e "${RED}❌ 检测到同时指定了 redis 和 valkey 服务！${NC}" >&2
        echo "" >&2
        echo -e "${YELLOW}${BOLD}⚠️  重要提示：${NC}" >&2
        echo -e "  • valkey 服务衍生于redis，属于同类型产品，相互兼容，不可同时启动。" >&2
        echo "" >&2
        echo -e "${CYAN}请选择其中一种缓存服务器：${NC}" >&2
        echo -e "  ./up.sh redis $operation     # 使用redis" >&2
        echo -e "  ./up.sh valkey $operation   # 使用valkey" >&2
        echo "" >&2
        exit 1
    fi

    # 获取compose文件
    local compose_files=$(get_compose_files "$environment" "${services[@]}")

    # 处理特殊组合
    local final_services=()
    local web_services=()  # 用于存储Web服务器

    for service in "${services[@]}"; do
        local special_services=$(get_special_services "$service")
        if [[ -n "$special_services" ]]; then
            final_services+=($special_services)
        elif [[ "$service" != "all" ]]; then
            local mapped_service=$(map_service_name "$service")
            # 对于restart操作，将Web服务器单独分类
            if [[ "$operation" == "restart" && ("$mapped_service" == "nginx" || "$mapped_service" == "tengine") ]]; then
                web_services+=("$mapped_service")
            else
                final_services+=("$mapped_service")
            fi
        fi
    done

    # 如果不是restart操作，将Web服务器重新加回到final_services
    if [[ "$operation" != "restart" && ${#web_services[@]} -gt 0 ]]; then
        final_services+=("${web_services[@]}")
        web_services=()  # 清空web_services数组
    fi

    # 自动添加MySQL备份服务
    auto_add_mysql_backup final_services "$operation"

    # 提示信息
    if [[ "$operation" == "restart" && ${#web_services[@]} -gt 0 ]]; then
        info "检测到Web服务器 (${web_services[*]})，将在其他服务重启完成后最后重启"
    fi

    # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
    local compose_cmd=$(get_docker_compose_cmd)

    # hosts 同步将在 up/start 完成后执行，避免容器 IP 未就绪

    # 构建Docker命令
    local docker_cmd="$compose_cmd $compose_files"

    case "$operation" in
        up|start)
            # 检查镜像是否存在
            if [[ ${#final_services[@]} -gt 0 ]]; then
                missing_images=()
                for service in "${final_services[@]}"; do
                    local image_name="hg_dnmpr-${service}:latest"
                    if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${image_name}$" 2>/dev/null; then
                        missing_images+=("$service")
                    fi
                done

                if [[ ${#missing_images[@]} -gt 0 ]]; then
                    echo -e "${YELLOW}⚠️  检测到以下服务的镜像未构建：${missing_images[*]}${NC}"
                    echo ""
                    echo -e "${CYAN}是否要构建这些镜像？${NC}"
                    echo -e "  ${GREEN}y/Y${NC} - 是，构建镜像并启动服务"
                    echo -e "  ${RED}n/N${NC} - 否，跳过未构建的服务"
                    echo -e "  ${YELLOW}q/Q${NC} - 退出操作"
                    echo ""
                    read -p "请选择 [y/n/q]: " choice

                    case "$choice" in
                        [Yy]*)
                            info "开始构建镜像: ${missing_images[*]}"

                            # 处理ELK服务的特殊映射
                            local build_services=()
                            for service in "${missing_images[@]}"; do
                                case "$service" in
                                    elasticsearch|kibana|logstash)
                                        # ELK组件统一映射为elk服务
                                        if [[ ! " ${build_services[*]} " =~ " elk " ]]; then
                                            build_services+=("elk")
                                        fi
                                        ;;
                                    *)
                                        build_services+=("$service")
                                        ;;
                                esac
                            done

                            if ./build.sh "${build_services[@]}"; then
                                success "镜像构建完成，继续启动服务"
                            else
                                error "镜像构建失败，操作终止"
                                return 1
                            fi
                            ;;
                        [Nn]*)
                            # 从服务列表中移除未构建的服务
                            local available_services=()
                            for service in "${final_services[@]}"; do
                                local found=false
                                for missing in "${missing_images[@]}"; do
                                    if [[ "$service" == "$missing" ]]; then
                                        found=true
                                        break
                                    fi
                                done
                                if [[ "$found" == "false" ]]; then
                                    available_services+=("$service")
                                fi
                            done

                            if [[ ${#available_services[@]} -eq 0 ]]; then
                                warn "没有可启动的服务，操作终止"
                                return 1
                            fi

                            final_services=("${available_services[@]}")
                            info "将启动已构建的服务: ${final_services[*]}"
                            ;;
                        [Qq]*)
                            info "操作已取消"
                            return 1
                            ;;
                        *)
                            warn "无效选择，操作已取消"
                            return 1
                            ;;
                    esac
                fi
            fi

            docker_cmd="$docker_cmd up --no-build"
            if [[ "$options" =~ -d|--detach ]]; then
                docker_cmd="$docker_cmd -d"
            fi
            ;;
        stop)
            docker_cmd="$docker_cmd stop"
            ;;
        restart)
            # 对于restart操作，如果包含Web服务器，需要分步执行
            if [[ ${#web_services[@]} -gt 0 && ${#final_services[@]} -gt 0 ]]; then
                # 先重启非Web服务器
                info "步骤1: 重启其他服务 (${final_services[*]})"
                docker_cmd="$docker_cmd restart ${final_services[*]}"
                eval "$docker_cmd"

                # 等待一下，确保其他服务启动完成
                info "等待其他服务启动完成..."
                sleep 3

                # 再重启Web服务器
                info "步骤2: 重启Web服务器 (${web_services[*]})"
                docker_cmd="$compose_cmd $compose_files restart ${web_services[*]}"
                eval "$docker_cmd"
                return  # 提前返回，避免后面重复执行
            elif [[ ${#web_services[@]} -gt 0 && ${#final_services[@]} -eq 0 ]]; then
                # 如果只有Web服务器，直接重启
                info "重启Web服务器 (${web_services[*]})"
                docker_cmd="$docker_cmd restart ${web_services[*]}"
            else
                docker_cmd="$docker_cmd restart"
            fi
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

    # 为前台启动设置Ctrl+C清理trap
    if [[ "$operation" == "up" || "$operation" == "start" ]]; then
        if [[ ! "$options" =~ (-d|--detach) ]]; then
            trap 'echo ""; info "检测到中断信号，正在清理 hosts..."; cache_containers_for_cleanup; sync_hosts_aliases "down"; trap - INT TERM; exit 130' INT TERM
            trap_set=true
        fi
    fi

    eval "$docker_cmd"
    local cmd_status=$?

    if [[ "$trap_set" == "true" ]]; then
        trap - INT TERM
    fi

    # 启动完成后同步hosts（等待容器获得IP）
    if [[ "$operation" == "up" || "$operation" == "start" ]]; then
        if [[ ${#final_services[@]} -gt 0 ]]; then
            sync_hosts_aliases "$operation" "${final_services[*]}"
        else
            sync_hosts_aliases "$operation"
        fi
    fi

    return $cmd_status
}

# 系统清理操作
system_operations() {
    local operation="$1"

    case "$operation" in
        clear)
            log "执行Docker系统清理（未使用的资源）..."
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
        clean-all|purge)
            warn "⚠️  警告：此操作将彻底清理所有容器、镜像、网络和卷！"
            echo ""
            echo -e "${YELLOW}此操作将执行以下清理：${NC}"
            echo -e "  • 停止并删除所有容器"
            echo -e "  • 删除所有镜像（包括正在使用的）"
            echo -e "  • 删除所有网络（除了默认网络）"
            echo -e "  • 删除所有卷（包括未使用的）"
            echo -e "  • 清理构建缓存"
            echo ""
            read -p "确认执行彻底清理？(yes/no): " confirm

            if [[ "$confirm" != "yes" && "$confirm" != "y" && "$confirm" != "Y" ]]; then
                info "操作已取消"
                exit 0
            fi

            log "开始彻底清理所有Docker资源..."

            # 1. 停止并删除所有容器
            info "步骤1: 停止并删除所有容器..."
            local containers=$(docker container ls -a -q 2>/dev/null || echo "")
            if [[ -n "$containers" ]]; then
                docker container stop $containers 2>/dev/null || true
                docker container rm --force $containers 2>/dev/null || true
                info "已删除 $(echo $containers | wc -w) 个容器"
            else
                info "没有找到容器"
            fi

            # 2. 删除所有镜像
            info "步骤2: 删除所有镜像..."
            local images=$(docker images -q 2>/dev/null || echo "")
            if [[ -n "$images" ]]; then
                docker rmi --force $images 2>/dev/null || true
                info "已删除所有镜像"
            else
                info "没有找到镜像"
            fi

            # 3. 删除所有网络（除了默认网络）
            info "步骤3: 删除所有自定义网络..."
            local networks=$(docker network ls --filter "type=custom" -q 2>/dev/null || echo "")
            if [[ -n "$networks" ]]; then
                docker network rm $networks 2>/dev/null || true
                info "已删除 $(echo $networks | wc -w) 个自定义网络"
            else
                info "没有找到自定义网络"
            fi

            # 4. 删除所有卷
            info "步骤4: 删除所有卷..."
            local volumes=$(docker volume ls -q 2>/dev/null || echo "")
            if [[ -n "$volumes" ]]; then
                docker volume rm $volumes 2>/dev/null || true
                info "已删除所有卷"
            else
                info "没有找到卷"
            fi

            # 5. 清理构建缓存
            info "步骤5: 清理构建缓存..."
            docker builder prune -a -f 2>/dev/null || true
            info "构建缓存清理完成"

            # 6. 最终清理
            info "步骤6: 执行最终系统清理..."
            docker system prune -a -f --volumes 2>/dev/null || true

            success "彻底清理完成！所有容器、镜像、网络和卷已删除"
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

    # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
    local compose_cmd=$(get_docker_compose_cmd)

    echo -e "\n${CYAN}=== 主要服务状态 ===${NC}"
    $compose_cmd $compose_files ps 2>/dev/null || warn "无法获取主要服务状态"

    # 检查ELK服务是否真的存在和运行
    echo -e "\n${CYAN}=== ELK服务状态 ===${NC}"
    if [[ -f "docker-compose-ELK.yaml" ]]; then
        # 检查ELK compose文件中定义的服务是否有在运行
        local elk_containers=$(docker ps --filter "label=com.docker.compose.project=hg_dnmpr" --filter "label=com.docker.compose.config-hash" --format "{{.Names}}" | grep -E "elasticsearch|kibana|logstash" 2>/dev/null || echo "")
        if [[ -n "$elk_containers" ]]; then
            $compose_cmd -f docker-compose-ELK.yaml ps 2>/dev/null
        else
            info "ELK服务未运行"
        fi
    else
        info "ELK配置文件不存在"
    fi

    # 检查SGR服务是否真的存在和运行
    echo -e "\n${CYAN}=== SGR服务状态 ===${NC}"
    if [[ -f "docker-compose-spug+gitea+rap2.yaml" ]]; then
        # 检查SGR compose文件中定义的服务是否有在运行
        local sgr_containers=$(docker ps --filter "label=com.docker.compose.project=hg_dnmpr" --filter "label=com.docker.compose.config-hash" --format "{{.Names}}" | grep -E "spug|gitea|rap2" 2>/dev/null || echo "")
        if [[ -n "$sgr_containers" ]]; then
            $compose_cmd -f docker-compose-spug+gitea+rap2.yaml ps 2>/dev/null
        else
            info "SGR服务未运行"
        fi
    else
        info "SGR配置文件不存在"
    fi

    echo -e "\n${CYAN}=== 系统资源使用情况 ===${NC}"
    # 获取容器统计信息，同时显示容器ID和名称
    if docker stats --no-stream --format "table {{.Container}}\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" 2>/dev/null | head -1 | grep -q "CONTAINER"; then
        # 如果docker stats支持{{.Name}}格式
        docker stats --no-stream --format "table {{.Container}}\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" 2>/dev/null || warn "无法获取资源使用情况"
    else
        # 如果不支持，使用替代方案：先获取容器信息，然后合并显示
        echo -e "CONTAINER\t\tNAME\t\t\tCPU %\t\tMEM USAGE / LIMIT\tNET I/O\t\t\tBLOCK I/O"
        docker stats --no-stream --format "{{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" 2>/dev/null | while IFS=$'\t' read -r container cpu mem net block; do
            # 获取容器名称
            container_name=$(docker inspect --format '{{.Name}}' "$container" 2>/dev/null | sed 's/^\/*//')
            printf "%-12s\t%-15s\t%-8s\t%-20s\t%-15s\t%s\n" "$container" "$container_name" "$cpu" "$mem" "$net" "$block"
        done || warn "无法获取资源使用情况"
    fi
}

# 检查是否无参数，如果是则显示帮助信息
if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

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
        php84|php83|php82|php81|php80|php74|php72|nginx|tengine|mysql|mysql_backup|redis|valkey|mongo|postgres|elk|sgr|all)
            SERVICES+=("$1")
            shift
            ;;
        # 环境名（当作为第二个参数时，如：./up.sh elk dev|prod）
        dev|prod|production|development|test|staging)
            ENVIRONMENT="$1"
            shift
            ;;
        # 操作
        up|start|stop|restart|down|logs|ps|exec|clear|delete|prune|clean-all|purge)
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

# 检查分层配置文件
check_layered_config() {
    local config_dir="config/env"
    local required_configs=("base.env" "web.env" "php.env" "database.env" "redis.env")

    if [[ ! -d "$config_dir" ]]; then
        error "配置目录 $config_dir 不存在，请确保项目使用分层配置"
    fi

    for config in "${required_configs[@]}"; do
        if [[ ! -f "$config_dir/$config" ]]; then
            warn "配置文件 $config_dir/$config 不存在"
        fi
    done

    info "检测到分层配置，已验证配置文件结构"
}

# 检查配置文件
if [[ -f ".env" ]]; then
    warn "检测到 .env 文件，项目已迁移到分层配置，建议删除 .env 文件"
    warn "当前使用 config/env/ 目录下的分层配置文件"
fi

check_layered_config

# 加载环境变量函数定义
load_environment_variables() {
    local config_dir="config/env"
    local env_files=("base.env" "web.env" "php.env" "database.env" "redis.env" "elk.env" "apps.env")

    # 保存当前的ENVIRONMENT值（由命令行参数设置）
    local saved_environment="$ENVIRONMENT"

    # 设置导出模式
    set -a

    # 加载基础配置文件
    for env_file in "${env_files[@]}"; do
        local file_path="$config_dir/$env_file"
        if [[ -f "$file_path" ]]; then
            # 过滤掉注释行和空行，排除ENVIRONMENT变量（避免被覆盖）
            source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$file_path" 2>/dev/null | grep -v '^ENVIRONMENT=' || true)
        fi
    done

    # 恢复ENVIRONMENT值
    ENVIRONMENT="$saved_environment"

    # 根据指定环境加载特定的环境配置（会覆盖基础配置）
    local env_specific_files=()

    # 检查是否有ELK服务，如果有，加载对应的环境配置
    if [[ " ${SERVICES[@]} " =~ " elk " ]] || [[ ${#SERVICES[@]} -eq 0 ]]; then
        # 标准化环境名称（将所有变体统一为简短形式）
        local env_name="$ENVIRONMENT"
        case "$env_name" in
            production|prod) env_name="prod" ;;
            development|dev) env_name="dev" ;;
            test|testing) env_name="test" ;;
            staging|stage) env_name="staging" ;;
            *) env_name="dev" ;;  # 默认为dev
        esac

        # 检查ELK环境配置文件
        local elk_env_file="$config_dir/elk.${env_name}.env"
        if [[ -f "$elk_env_file" ]]; then
            info "🔧 加载ELK【${env_name}】环境配置: $elk_env_file"
            source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$elk_env_file" 2>/dev/null || true)
        else
            warn "未找到ELK环境配置文件: $elk_env_file，使用默认配置"
        fi
    fi

    # 关闭导出模式
    set +a
}

# 注意：不在这里调用load_environment_variables，而是在参数解析后调用

# 开始操作
log "开始 Docker 项目管理"

# 现在加载环境变量（在参数解析后，这样可以根据指定的环境加载对应配置）
load_environment_variables

# 设置配置目录权限
setup_conf_permissions

# 配置Docker容器别名（传递脚本名称用于日志标识）
setup_docker_aliases "up"

# 清理日志文件
cleanup_logs

# 处理系统级操作
case "$OPERATION" in
    clear|delete|prune|clean-all|purge)
        cache_containers_for_cleanup
        system_operations "$OPERATION"
        sync_hosts_aliases "$OPERATION"
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
            log "启动所有已构建的服务..."

            # 获取所有已构建的镜像对应的服务
            available_services=()

            # 检查主要服务的镜像是否存在
            for service in php85_apache php84_apache php83_apache php82_apache php81_apache php80_apache php74_apache php72_apache nginx tengine mysql mysql_backup redis valkey mongo postgres; do
                if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "hg_dnmpr-$service:latest" 2>/dev/null; then
                    available_services+=("$service")
                fi
            done

            # 自动添加MySQL备份服务
            auto_add_mysql_backup available_services "$OPERATION"

            if [[ ${#available_services[@]} -eq 0 ]]; then
                warn "没有找到已构建的镜像，请先使用 ./build.sh 构建所需的服务"
                info "例如: ./build.sh php84 nginx mysql"
                exit 1
            fi

            info "找到 ${#available_services[@]} 个已构建的服务: ${available_services[*]}"

            # 将服务名映射为原始服务名（用于WSL检测）
            mapped_services=()
            for service in "${available_services[@]}"; do
                case "$service" in
                    mysql|mysql_backup)
                        mapped_services+=("mysql")
                        ;;
                esac
            done

            # 获取compose文件（传递服务列表以检测是否需要WSL配置）
            compose_files=$(get_compose_files "$ENVIRONMENT" "${mapped_services[@]}")

            # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
            compose_cmd=$(get_docker_compose_cmd)

            # 只启动已构建的服务
            docker_cmd="$compose_cmd $compose_files up --no-build"
            if [[ "$DETACH" == "true" ]]; then
                docker_cmd="$docker_cmd -d"
            fi

            # 添加已构建的服务名
            docker_cmd="$docker_cmd ${available_services[*]}"

            # 为前台启动设置Ctrl+C清理trap
            if [[ "$DETACH" != "true" ]]; then
                trap 'echo ""; info "检测到中断信号，正在清理 hosts..."; cache_containers_for_cleanup; sync_hosts_aliases "down"; trap - INT TERM; exit 130' INT TERM
            fi

            eval "$docker_cmd"
            trap - INT TERM

            # 启动完成后同步hosts
            sync_hosts_aliases "$OPERATION"

            success "已构建的服务启动完成"
            ;;
        stop)
            log "停止所有正在运行的服务..."
            # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
            compose_cmd=$(get_docker_compose_cmd)

            # 检查是否有MySQL服务在运行，以确定是否需要WSL配置
            has_mysql_running=false
            if docker ps --format "{{.Names}}" | grep -q "^mysql$" 2>/dev/null; then
                has_mysql_running=true
            fi

            # 停止主要服务（如果MySQL在运行，会自动添加WSL配置）
            if [[ "$has_mysql_running" == "true" ]]; then
                compose_files=$(get_compose_files "$ENVIRONMENT" "mysql" --silent)
            else
                compose_files=$(get_compose_files "$ENVIRONMENT" --silent)
            fi
            $compose_cmd $compose_files stop

            # 停止ELK服务（如果存在且正在运行）
            if [[ -f "docker-compose-ELK.yaml" ]]; then
                elk_containers=$(docker ps --filter "label=com.docker.compose.project=hg_dnmpr" --format "{{.Names}}" | grep -E "elasticsearch|kibana|logstash" 2>/dev/null || echo "")
                if [[ -n "$elk_containers" ]]; then
                    info "停止ELK服务..."
                    $compose_cmd -f docker-compose-ELK.yaml stop
                fi
            fi

            if [[ -f "docker-compose-spug+gitea+rap2.yaml" ]]; then
                sgr_containers=$(docker ps --filter "label=com.docker.compose.project=hg_dnmpr" --format "{{.Names}}" | grep -E "spug|gitea|rap2" 2>/dev/null || echo "")

                if [[ -n "$sgr_containers" ]]; then
                    info "停止SGR服务..."
                    $compose_cmd -f docker-compose-spug+gitea+rap2.yaml stop
                fi
            fi

            cache_containers_for_cleanup
            sync_hosts_aliases "$OPERATION"
            success "所有服务已停止"
            ;;

        down)
            log "停止并卸载所有服务..."
            # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
            compose_cmd=$(get_docker_compose_cmd)

            # 检查是否有MySQL服务在运行，以确定是否需要WSL配置
            has_mysql_running=false
            if docker ps -a --format "{{.Names}}" | grep -q "^mysql$" 2>/dev/null; then
                has_mysql_running=true
            fi

            if [[ "$has_mysql_running" == "true" ]]; then
                compose_files=$(get_compose_files "$ENVIRONMENT" "mysql" --silent)
            else
                compose_files=$(get_compose_files "$ENVIRONMENT" --silent)
            fi

            cache_containers_for_cleanup
            sync_hosts_aliases "$OPERATION"
            $compose_cmd $compose_files down

            # 停止并删除ELK服务（如果存在）
            if [[ -f "docker-compose-ELK.yaml" ]]; then
                info "停止并卸载ELK服务..."
                $compose_cmd -f docker-compose-ELK.yaml down 2>/dev/null || true
            fi

            # 停止并删除SGR服务（如果存在）
            if [[ -f "docker-compose-spug+gitea+rap2.yaml" ]]; then
                info "停止并卸载SGR服务..."
                $compose_cmd -f docker-compose-spug+gitea+rap2.yaml down 2>/dev/null || true
            fi

            # 清理所有容器（包括不在当前项目中定义的）
            info "清理所有容器..."
            all_containers=$(docker ps -a -q 2>/dev/null || echo "")
            if [[ -n "$all_containers" ]]; then
                info "发现 $(echo $all_containers | wc -w) 个容器，正在删除..."
                docker rm -f $all_containers 2>/dev/null || true
            else
                info "没有发现任何容器"
            fi

            # 清理所有网络（除了默认网络）
            info "清理自定义网络..."
            custom_networks=$(docker network ls --filter "type=custom" -q 2>/dev/null || echo "")
            if [[ -n "$custom_networks" ]]; then
                info "发现 $(echo $custom_networks | wc -w) 个自定义网络，正在删除..."
                docker network rm $custom_networks 2>/dev/null || true
            else
                info "没有发现自定义网络"
            fi

            # 清理未使用的镜像（可选）
            info "清理未使用的镜像..."
            docker image prune -f 2>/dev/null || true

            success "所有容器和网络已清理完成"
            ;;
        restart)
            log "重启所有服务..."
            # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
            compose_cmd=$(get_docker_compose_cmd)

            # 检查是否有MySQL服务在运行，以确定是否需要WSL配置
            has_mysql_running=false
            if docker ps --format "{{.Names}}" | grep -q "^mysql$" 2>/dev/null; then
                has_mysql_running=true
            fi

            # 获取compose文件（如果MySQL在运行，会自动添加WSL配置）
            if [[ "$has_mysql_running" == "true" ]]; then
                compose_files=$(get_compose_files "$ENVIRONMENT" "mysql")
            else
            compose_files=$(get_compose_files "$ENVIRONMENT")
            fi

            # 获取所有运行中的容器名称（包括主服务和ELK服务）
            running_containers=$($compose_cmd $compose_files ps --format "{{.Name}}" 2>/dev/null || echo "")

            # 如果存在ELK compose文件，也获取ELK服务的容器
            if [[ -f "docker-compose-ELK.yaml" ]]; then
                elk_running_containers=$($compose_cmd -f docker-compose-ELK.yaml ps --format "{{.Name}}" 2>/dev/null || echo "")
                if [[ -n "$elk_running_containers" ]]; then
                    # 合并ELK容器到主容器列表
                    running_containers=$(echo -e "$running_containers\n$elk_running_containers")
                fi
            fi

            # 检查是否需要自动添加 mysql_backup 服务
            restart_services=()
            elk_services=()
            if [[ -n "$running_containers" ]]; then
                # 将运行中的容器转换为数组，并分离ELK服务
                while IFS= read -r container_name; do
                    if [[ -n "$container_name" ]]; then
                        # 检查是否是ELK服务
                        if [[ "$container_name" == "elasticsearch" || "$container_name" == "kibana" || "$container_name" == "logstash" ]]; then
                            elk_services+=("$container_name")
                        else
                        restart_services+=("$container_name")
                        fi
                    fi
                done <<< "$running_containers"

                # 自动添加MySQL备份服务
                auto_add_mysql_backup restart_services "restart"
            fi

            # 检查是否有运行中的Web服务器（nginx或tengine）
            running_web_services=()
            running_other_services=()

            if [[ ${#restart_services[@]} -gt 0 ]]; then
                # 分类运行中的服务
                for container_name in "${restart_services[@]}"; do
                    if [[ "$container_name" == "nginx" || "$container_name" == "tengine" ]]; then
                        running_web_services+=("$container_name")
                    else
                        running_other_services+=("$container_name")
                    fi
                done

                # 如果有Web服务器和其他服务同时运行，分步重启
                if [[ ${#running_web_services[@]} -gt 0 && ${#running_other_services[@]} -gt 0 ]]; then
                    info "检测到Web服务器 (${running_web_services[*]})，将分步重启以确保服务稳定性"

                    # 步骤1：重启其他服务
                    info "步骤1: 重启后端服务 (${running_other_services[*]})"
                    $compose_cmd $compose_files restart ${running_other_services[*]}

                    # 等待后端服务启动完成
                    info "等待后端服务启动完成..."
                    sleep 3

                    # 步骤2：重启Web服务器
                    info "步骤2: 重启Web服务器 (${running_web_services[*]})"
                    $compose_cmd $compose_files restart ${running_web_services[*]}

                    # 步骤3：重启ELK服务（如果存在）
                    if [[ ${#elk_services[@]} -gt 0 ]]; then
                        info "步骤3: 重启ELK服务 (${elk_services[*]})"
                        if [[ -f "docker-compose-ELK.yaml" ]]; then
                            $compose_cmd -f docker-compose-ELK.yaml restart ${elk_services[*]}
                        else
                            warn "未找到 docker-compose-ELK.yaml 文件，跳过ELK服务重启"
                        fi
                    fi

                    sync_hosts_aliases "$OPERATION"
                    success "所有服务重启完成"
                else
                    # 如果只有Web服务器或只有其他服务，重启指定的服务
                    if [[ ${#restart_services[@]} -gt 0 ]]; then
                        $compose_cmd $compose_files restart ${restart_services[*]}
                    else
                        $compose_cmd $compose_files restart
                    fi

                    # 重启ELK服务（如果存在）
                    if [[ ${#elk_services[@]} -gt 0 ]]; then
                        info "重启ELK服务 (${elk_services[*]})"
                        if [[ -f "docker-compose-ELK.yaml" ]]; then
                            $compose_cmd -f docker-compose-ELK.yaml restart ${elk_services[*]}
                        else
                            warn "未找到 docker-compose-ELK.yaml 文件，跳过ELK服务重启"
                        fi
                    fi

                    success "所有服务重启完成"
                fi
            else
                # 没有运行中的主服务，检查是否有ELK服务需要重启
                if [[ ${#elk_services[@]} -gt 0 ]]; then
                    info "重启ELK服务 (${elk_services[*]})"
                    if [[ -f "docker-compose-ELK.yaml" ]]; then
                        $compose_cmd -f "docker-compose-ELK.yaml" restart ${elk_services[*]}
                        sync_hosts_aliases "$OPERATION"
                        success "ELK服务重启完成"
                    else
                        warn "未找到 docker-compose-ELK.yaml 文件，跳过ELK服务重启"
                    fi
                else
                    # 正常重启
                $compose_cmd $compose_files restart
                sync_hosts_aliases "$OPERATION"
                success "所有服务重启完成"
                fi
            fi
            ;;
        *)
            error "操作 '$OPERATION' 需要指定服务名"
            ;;
    esac
else
    # 处理指定服务的操作
    case "$OPERATION" in
        stop|down|delete|purge|clean-all|clear|prune)
            cache_containers_for_cleanup
            sync_hosts_aliases "$OPERATION"
            ;;
    esac
    execute_compose_command "$ENVIRONMENT" "$OPERATION" "$OPTIONS" "${SERVICES[@]}"
    success "操作完成"
fi

log "所有操作完成！"
