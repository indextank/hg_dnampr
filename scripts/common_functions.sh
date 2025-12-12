#!/bin/bash

# ==========================================
# Docker 项目公共函数库 v1.0
# ==========================================
# 功能：提供build.sh和up.sh脚本的公共函数
# 作者：重构版本
# 使用方法：source scripts/common_functions.sh

# 颜色定义
# 检测运行环境并决定是否启用颜色
if [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ "$(uname -r)" =~ microsoft|WSL ]] || [[ "${TERM_PROGRAM:-}" == "vscode" ]] || [[ "${TERM:-}" == "cygwin" ]] || [[ "${MSYSTEM:-}" =~ MINGW|MSYS ]]; then
    # Windows环境或WSL环境，禁用颜色
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    PURPLE=''
    CYAN=''
    BOLD=''
    NC=''
else
    # 非Windows环境，启用颜色
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
fi

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
    exit 1
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1"
}

# 配置Docker容器别名
setup_docker_aliases() {
    local script_name="${1:-common}"

    # 定义所有别名
    local aliases=(
        "alias dphp74='docker exec -it php74_apache /bin/bash'"
        "alias dphp82='docker exec -it php82_apache /bin/bash'"
        "alias dphp84='docker exec -it php84_apache /bin/bash'"
        "alias dphp85='docker exec -it php85_apache /bin/bash'"
        "alias dnginx='docker exec -it nginx /bin/bash'"
        "alias dmysql='docker exec -it mysql /bin/bash'"
        "alias dmongo='docker exec -it mongo /bin/bash'"
        "alias dvalkey='docker exec -it valkey /bin/bash'"
        "alias dredis='docker exec -it redis /bin/bash'"
        "alias dpostgres='docker exec -it postgres /bin/bash'"
    )

    # 检测当前shell类型
    local current_shell=""
    local config_file=""

    # 检测WSL环境并设置正确的HOME路径
    local user_home=""
    local current_user=$(whoami)

    if [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ "$(uname -r)" =~ microsoft|WSL ]]; then
        # WSL环境，检查是否是root用户
        if [[ "$current_user" == "root" ]]; then
            # root用户的主目录是/root
            user_home="/root"
        else
            # 普通用户使用/home/用户名
            user_home="/home/$current_user"
        fi
        if [[ "$script_name" == "build" ]]; then
            info "检测到WSL环境，使用Linux用户目录: $user_home"
        fi
    else
        # 普通Linux环境，使用$HOME环境变量（更可靠）
        if [[ -n "${HOME:-}" ]]; then
            user_home="$HOME"
        elif [[ "$current_user" == "root" ]]; then
            user_home="/root"
        else
            user_home="/home/$current_user"
        fi
    fi

    if [[ -n "${BASH_VERSION:-}" ]]; then
        current_shell="bash"
        config_file="$user_home/.bashrc"
    elif [[ -n "${ZSH_VERSION:-}" ]]; then
        current_shell="zsh"
        config_file="$user_home/.zshrc"
    elif [[ "$0" == *"zsh"* ]]; then
        current_shell="zsh"
        config_file="$user_home/.zshrc"
    elif [[ "$0" == *"bash"* ]]; then
        current_shell="bash"
        config_file="$user_home/.bashrc"
    else
        # 尝试从环境变量检测
        if [[ "${SHELL:-}" == *"zsh"* ]]; then
            current_shell="zsh"
            config_file="$user_home/.zshrc"
        elif [[ "${SHELL:-}" == *"bash"* ]]; then
            current_shell="bash"
            config_file="$user_home/.bashrc"
        else
            current_shell="bash"
            config_file="$user_home/.bashrc"
        fi
    fi

    if [[ "$script_name" == "build" ]]; then
        info "检测到shell类型: $current_shell"
        info "配置文件路径: $config_file"
    fi

    # 确保配置文件目录存在
    local config_dir=$(dirname "$config_file")
    if [[ ! -d "$config_dir" ]]; then
        info "配置文件目录不存在，创建: $config_dir"
        mkdir -p "$config_dir" 2>/dev/null || {
            warn "无法创建配置文件目录: $config_dir，尝试使用默认HOME目录"
            if [[ -n "${HOME:-}" ]]; then
                user_home="$HOME"
            else
                user_home="/root"
            fi
            config_file="$user_home/.${current_shell}rc"
            config_dir=$(dirname "$config_file")
            mkdir -p "$config_dir" 2>/dev/null || error "无法创建配置文件目录: $config_dir"
        }
    fi

    # 确保配置文件存在
    if [[ ! -f "$config_file" ]]; then
        info "配置文件不存在，创建: $config_file"
        touch "$config_file" 2>/dev/null || error "无法创建配置文件: $config_file"
    fi

    # 检查每个别名是否已存在，不存在则添加
    local aliases_to_add=()
    local aliases_found=0

    for alias_line in "${aliases[@]}"; do
        # 提取别名名称（例如从 "alias dphp74='...'" 中提取 "dphp74"）
        local alias_name=$(echo "$alias_line" | sed -n "s/alias \([^=]*\)=.*/\1/p")

        # 检查配置文件中是否已存在该别名
        if grep -q "^alias $alias_name=" "$config_file" 2>/dev/null; then
            aliases_found=$((aliases_found + 1))
        else
            aliases_to_add+=("$alias_line")
        fi
    done

    # 如果有需要添加的别名
    if [[ ${#aliases_to_add[@]} -gt 0 ]]; then
        info "添加 ${#aliases_to_add[@]} 个新别名到 $config_file"

        # 准备要插入的内容
        local content_to_insert=""
        content_to_insert+=$'\n'
        content_to_insert+="# Docker容器快捷别名 - 由 $script_name.sh 脚本自动添加 $(date)"$'\n'
        for alias_line in "${aliases_to_add[@]}"; do
            content_to_insert+="$alias_line"$'\n'
        done

        # 创建临时文件
        local temp_file="${config_file}.tmp.$$"

        # 决定插入位置的策略：
        # 1. 如果存在 alias 行，在最后一个 alias 行之后插入
        # 2. 如果不存在 alias 但存在 export 行，在第一个 export 行之前插入
        # 3. 如果都不存在，在文件末尾追加

        local last_alias_line=0
        local first_export_line=0
        local line_num=0

        # 分析文件找到插入位置
        while IFS= read -r line; do
            line_num=$((line_num + 1))
            # 查找 alias 行（忽略注释）
            if [[ "$line" =~ ^[[:space:]]*alias[[:space:]] ]]; then
                last_alias_line=$line_num
            fi
            # 查找第一个 export 行（忽略注释）
            if [[ "$line" =~ ^[[:space:]]*export[[:space:]] ]] && [[ $first_export_line -eq 0 ]]; then
                first_export_line=$line_num
            fi
        done < "$config_file"

        # 确定插入策略
        local insert_mode=""
        local insert_line=0

        if [[ $last_alias_line -gt 0 ]]; then
            # 策略1: 在最后一个 alias 之后插入
            insert_mode="after_alias"
            insert_line=$last_alias_line
            if [[ "$script_name" == "build" ]]; then
                info "检测到现有 alias 配置，将在第 $insert_line 行之后插入"
            fi
        elif [[ $first_export_line -gt 0 ]]; then
            # 策略2: 在第一个 export 之前插入
            insert_mode="before_export"
            insert_line=$first_export_line
            if [[ "$script_name" == "build" ]]; then
                info "检测到 export 配置，将在第 $insert_line 行之前插入"
            fi
        else
            # 策略3: 在文件末尾追加
            insert_mode="append"
            if [[ "$script_name" == "build" ]]; then
                info "将在文件末尾追加别名配置"
            fi
        fi

        # 根据策略插入内容
        if [[ "$insert_mode" == "append" ]]; then
            # 直接追加到文件末尾
            echo "$content_to_insert" >> "$config_file"
        else
            # 需要在特定位置插入
            line_num=0
            local inserted=false

            while IFS= read -r line || [[ -n "$line" ]]; do
                line_num=$((line_num + 1))

                if [[ "$insert_mode" == "after_alias" ]] && [[ $line_num -eq $insert_line ]] && [[ "$inserted" == false ]]; then
                    # 在最后一个 alias 之后插入
                    echo "$line" >> "$temp_file"
                    echo "$content_to_insert" >> "$temp_file"
                    inserted=true
                elif [[ "$insert_mode" == "before_export" ]] && [[ $line_num -eq $insert_line ]] && [[ "$inserted" == false ]]; then
                    # 在第一个 export 之前插入
                    echo "$content_to_insert" >> "$temp_file"
                    echo "$line" >> "$temp_file"
                    inserted=true
                else
                    echo "$line" >> "$temp_file"
                fi
            done < "$config_file"

            # 替换原文件
            if [[ -f "$temp_file" ]]; then
                mv "$temp_file" "$config_file" || {
                    error "无法更新配置文件: $config_file"
                    rm -f "$temp_file"
                    return 1
                }
            fi
        fi

        success "成功添加 ${#aliases_to_add[@]} 个Docker别名"

        # 尝试重新加载配置文件（仅在build脚本中）
        if [[ "$script_name" == "build" ]]; then
            if [[ "$current_shell" == "bash" ]]; then
                if source "$config_file" 2>/dev/null; then
                    success "已自动加载bash配置文件"
                else
                    warn "无法自动加载配置文件，请手动执行: source $config_file"
                fi
            elif [[ "$current_shell" == "zsh" ]]; then
                if source "$config_file" 2>/dev/null; then
                    success "已自动加载zsh配置文件"
                else
                    warn "无法自动加载配置文件，请手动执行: source $config_file"
                fi
            fi
        else
            # up脚本中的提示
            info "别名已添加到 $config_file"
            info "请在新的终端会话中使用这些别名，或手动执行: source $config_file"
        fi

        # 显示使用提示
        echo ""
        echo -e "${CYAN}=== Docker容器快捷命令 ===${NC}"
        echo -e "${YELLOW}现在您可以使用以下命令快速进入容器：${NC}"
        for alias_line in "${aliases_to_add[@]}"; do
            local alias_name=$(echo "$alias_line" | sed -n "s/alias \([^=]*\)=.*/\1/p")
            echo -e "  ${GREEN}$alias_name${NC} - 进入对应容器"
        done
        echo ""

    else
        success "所有Docker别名已存在 (共 $aliases_found 个)"
    fi
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

    # 设置日志目录权限（ELK服务需要）
    info "设置日志目录权限..."
    local logs_dir="./logs"

    # 创建日志目录（如果不存在）
    if [ ! -d "$logs_dir" ]; then
        mkdir -p "$logs_dir" 2>/dev/null || true
    fi

    # 设置日志目录权限为777，确保容器内用户可以写入
    if [ -d "$logs_dir" ]; then
        # 创建ELK相关的日志子目录
        mkdir -p "$logs_dir/elasticsearch" 2>/dev/null || true
        mkdir -p "$logs_dir/kibana" 2>/dev/null || true
        mkdir -p "$logs_dir/logstash" 2>/dev/null || true

        # 设置所有日志目录权限为777（容器内用户UID 1000需要写入权限）
        find "$logs_dir" -type d -exec chmod 777 {} \; 2>/dev/null || true
        find "$logs_dir" -type f -exec chmod 666 {} \; 2>/dev/null || true

        info "日志目录权限设置完成"
    else
        warn "日志目录 $logs_dir 无法创建"
    fi
}

# 清理日志文件函数
cleanup_logs() {
    info "清理日志文件..."

    local logs_dir="$PROJECT_DIR/logs"

    if [ -d "$logs_dir" ]; then
        # 查找并删除所有 .log 文件，但保留目录
        find "$logs_dir" -name "*.log" -type f -delete 2>/dev/null || true

        # 统计清理的文件数量
        local cleaned_count=$(find "$logs_dir" -name "*.log" -type f 2>/dev/null | wc -l)

        if [ "$cleaned_count" -eq 0 ]; then
            success "日志文件清理完成，共清理 $cleaned_count 个文件"
        else
            warn "日志文件清理完成，但仍有 $cleaned_count 个文件无法删除"
        fi
    else
        warn "日志目录 $logs_dir 不存在，跳过清理"
    fi
}

# 分层配置文件读取函数
load_config_files() {
    local config_dir="$PROJECT_DIR/config/env"
    local config_files=(
        "$config_dir/base.env"        # 基础配置
        "$config_dir/database.env"    # 数据库配置
        "$config_dir/php.env"         # PHP配置
        "$config_dir/web.env"         # Web服务配置
        "$config_dir/redis.env"       # Redis配置
        "$config_dir/elk.env"         # ELK配置
        "$config_dir/apps.env"        # 应用配置
        ".env"                        # 主配置文件（向后兼容）
        ".env.local"                  # 本地配置（优先级最高）
    )

    log "开始加载分层配置文件..."

    # 检查config目录是否存在
    if [[ ! -d "$config_dir" ]]; then
        warn "config/env目录不存在，回退到.env文件模式"

        if [[ ! -f ".env" ]]; then
            if [[ -f ".env.example" ]]; then
                warn ".env文件不存在，从.env.example复制..."
                cp .env.example .env
            else
                error ".env文件不存在，请先创建.env文件"
            fi
        fi
        config_files=(".env" ".env.local")
    fi

    # 按优先级顺序加载配置文件
    for config_file in "${config_files[@]}"; do
        if [[ -f "$config_file" ]]; then
            # info "加载配置文件: $config_file"

            set +u
            while IFS='=' read -r key value; do
                # 跳过注释和空行
                [[ "$key" =~ ^[[:space:]]*# ]] && continue
                [[ -z "$key" ]] && continue

                # 确保 key 是有效的变量名
                [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && continue

                # 去掉值中的注释部分
                value=$(echo "$value" | sed 's/[[:space:]]*#.*$//')

                # 去掉值前后的空格
                value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

                # 设置环境变量
                if [[ -n "$value" ]]; then
                    export "$key"="$value"
                fi
            done < <(grep '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*=' "$config_file")
            set -u
        # else
        #     info "配置文件不存在，跳过: $config_file"
        fi
    done

    success "分层配置文件加载完成"
}

# 帮助信息检查函数
check_help_params() {
    for arg in "$@"; do
        case "$arg" in
            help|--help|-help|-h)
                return 0
                ;;
        esac
    done
    return 1
}

# 无参数时显示帮助的检查函数
check_no_params() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi
    return 1
}

# 检测并返回正确的 Docker Compose 命令
# 优先使用 docker compose（Docker Compose V2 插件）
# 如果不存在，则使用 docker-compose（独立工具）
get_docker_compose_cmd() {
    # 检查 docker compose 是否可用
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
        return 0
    fi

    # 检查 docker-compose 是否可用
    if docker-compose --version >/dev/null 2>&1; then
        echo "docker-compose"
        return 0
    fi

    # 如果都不可用，返回错误
    error "未找到 Docker Compose 命令，请安装 docker-compose 或 Docker Compose V2 插件"
    return 1
}

# 显示build.sh帮助信息
show_build_help() {
    cat << EOF
${CYAN}Docker 项目构建脚本 v2.0${NC}

${YELLOW}使用方法:${NC}
    $0 [服务名...] [环境] [选项]

${YELLOW}服务名:${NC}
    php84, php83, php82, php81, php80, php74, php72  - PHP服务
    nginx, tengine                                    - Web服务器 ⚠️ 二选一
    mysql, mysql                                   - MySQL数据库 ⚠️ 二选一
    redis, valkey                                     - 缓存服务
    mongo, postgresql                                 - 其他数据库
    elk                                              - ELK栈 (elasticsearch, kibana, logstash)
    sgr                                              - Spug+Gitea+Rap2栈
    all                                              - 所有服务

${YELLOW}环境类型:${NC}
    dev, development    - 开发环境 ${RED}(默认)${NC}
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
    --help, -h, help   显示此帮助信息

${YELLOW}示例:${NC}
    $0                                              # 显示帮助信息
    $0 help                                         # 显示帮助信息
    $0 php84                                        # 构建PHP84开发环境 (默认dev)
    $0 php84 dev                                    # 构建PHP84开发环境
    $0 php84 dev --no-cache                         # 无缓存构建PHP84
    $0 php84 php82 mysql valkey                    # 构建多个服务开发环境 (默认dev)
    $0 php84 php82 mysql valkey prod               # 构建多个服务生产环境
    $0 php84 php82 mysql valkey prod --force-recreate  # 强制重新创建
    $0 elk prod                                     # 构建ELK栈生产环境
    $0 sgr prod                                     # 构建SGR栈生产环境
    $0 php84 dev --multi-arch                       # 多架构构建

${YELLOW}特殊组合:${NC}
    elk     -> elasticsearch, kibana, logstash
    sgr     -> spug, gitea, rap2
    all     -> 所有可用服务

${RED}${BOLD}⚠️  重要提示: 如果不指定环境类型，默认使用 dev 开发环境进行构建！${NC}

EOF
}

# 显示up.sh帮助信息
show_up_help() {
    cat << EOF
${CYAN}Docker 项目管理脚本 v2.0${NC}

${YELLOW}使用方法:${NC}
    $0 [命令] [服务名...] [环境] [选项]

${YELLOW}命令:${NC}
    up, start           启动服务
    down, stop          停止服务
    restart             重启服务
    ps, status          查看服务状态
    logs                查看服务日志
    exec                进入容器
    build               构建服务
    pull                拉取镜像
    clean               清理资源
    help                显示此帮助信息
    --help, -h          显示此帮助信息

${YELLOW}服务名:${NC}
    php84, php83, php82, php81, php80, php74, php72  - PHP服务
    nginx, tengine                                    - Web服务器 ⚠️ 二选一
    mysql, mysql                                   - MySQL数据库 ⚠️ 二选一
    redis, valkey                                     - 缓存服务
    mongo, postgresql                                 - 其他数据库
    elk                                              - ELK栈 (elasticsearch, kibana, logstash)
    sgr                                              - Spug+Gitea+Rap2栈
    all                                              - 所有服务

${YELLOW}环境类型:${NC}
    dev, development    - 开发环境 ${RED}(默认)${NC}
    prod, production    - 生产环境
    test, testing       - 测试环境

${YELLOW}选项:${NC}
    --detach, -d       后台运行
    --force-recreate   强制重新创建容器
    --no-deps          不启动依赖服务
    --remove-orphans   移除孤立容器
    --follow, -f       跟踪日志输出
    --tail <n>         显示最后n行日志
    --since <time>     显示指定时间后的日志
    --help, -h, help   显示此帮助信息

${YELLOW}示例:${NC}
    $0                                              # 显示帮助信息
    $0 help                                         # 显示帮助信息
    $0 up                                           # 启动所有服务 (默认dev环境)
    $0 up php84 mysql                             # 启动指定服务
    $0 up php84 mysql prod                        # 启动指定服务(生产环境)
    $0 down                                         # 停止所有服务
    $0 restart nginx                                # 重启nginx服务
    $0 ps                                           # 查看所有服务状态
    $0 status                                       # 查看所有服务状态
    $0 logs php84                                   # 查看php84日志
    $0 logs php84 --follow                         # 跟踪php84日志
    $0 exec php84                                   # 进入php84容器
    $0 clean                                        # 清理未使用的资源

${YELLOW}特殊组合:${NC}
    elk     -> elasticsearch, kibana, logstash
    sgr     -> spug, gitea, rap2
    all     -> 所有可用服务

${RED}${BOLD}⚠️  重要提示: 如果不指定环境类型，默认使用 dev 开发环境！${NC}

EOF
}
