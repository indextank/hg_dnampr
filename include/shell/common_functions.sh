#!/bin/bash

# ==========================================
# Docker 项目公共函数库 v2.0
# ==========================================
# 功能：提供build.sh和up.sh脚本的公共函数
# 作者：重构版本
# 使用方法：source include/shell/common_functions.sh

# 注意：此处不使用外部传入的 SCRIPT_DIR（其语义因调用方而异），
# 而是始终通过 BASH_SOURCE 定位本文件所在目录展开两层得到项目根，
# 避免 download_dependencies.sh 等子脚本设置的 SCRIPT_DIR 导致路径错误
_COMMON_FUNCTIONS_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---- 加载项目路径注册表 ----
if [[ -f "$_COMMON_FUNCTIONS_PROJECT_DIR/include/shell/project_paths.sh" ]]; then
    source "$_COMMON_FUNCTIONS_PROJECT_DIR/include/shell/project_paths.sh"
fi

# ---- 加载上游版本自动解析 ----
if [[ -f "$_COMMON_FUNCTIONS_PROJECT_DIR/include/shell/version_resolve.sh" ]]; then
    source "$_COMMON_FUNCTIONS_PROJECT_DIR/include/shell/version_resolve.sh"
fi

# ---- 加载服务作用域（env 文件清单、按服务解析版本、版本缓存） ----
source "$_COMMON_FUNCTIONS_PROJECT_DIR/include/shell/env_scope.sh"

# ---- 加载容器运行时抽象层 ----
if [[ -f "$_COMMON_FUNCTIONS_PROJECT_DIR/include/shell/container_runtime.sh" ]]; then
    source "$_COMMON_FUNCTIONS_PROJECT_DIR/include/shell/container_runtime.sh"
    detect_container_runtime || true
else
    echo "警告: 未找到 container_runtime.sh，将仅支持 Docker" >&2
fi
# 将修正后的项目根覆盖 SCRIPT_DIR（供后续函数库使用）
SCRIPT_DIR="${SCRIPT_DIR:-$_COMMON_FUNCTIONS_PROJECT_DIR}"

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
    # 使用 ANSI-C 引用（$'...'）使变量直接包含 ESC 字节，
    # 这样 echo -e 与 cat << EOF（如 show_build_help/show_up_help）均可正确着色。
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    PURPLE=$'\033[0;35m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
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

# 读取 env 文件中的单个变量值。
# 仅解析 KEY=VALUE 形式，不执行文件内容，避免敏感配置中包含特殊字符时触发 shell 求值。
_get_env_file_value() {
    local file_path="$1"
    local target_key="$2"
    local raw=""

    [[ -f "$file_path" ]] || return 1
    raw="$({ grep -E "^[[:space:]]*${target_key}=" "$file_path" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*#.*$//;s/[[:space:]]*$//')"
    raw="${raw%\"}"
    raw="${raw#\"}"
    raw="${raw%\'}"
    raw="${raw#\'}"
    echo "$raw"
}

# 安全加载 env 文件。
# - 支持空值覆盖：根目录 .env 可以将分层配置中的同名变量置空。
# - 不 source 文件：避免密码、代理 URL 中的特殊字符被 shell 执行或截断。
# - 纯 Bash 参数展开解析，不为每行 fork sed（WSL /mnt 下全量加载可节省数秒）。
load_env_file_exports() {
    local file_path="$1"
    local _env_line _env_key _env_val

    [[ -f "$file_path" ]] || return 0
    while IFS= read -r _env_line; do
        _env_key="${_env_line%%=*}"
        _env_val="${_env_line#*=}"
        _env_key="${_env_key#"${_env_key%%[![:space:]]*}"}"
        _env_key="${_env_key%"${_env_key##*[![:space:]]}"}"
        [[ "$_env_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

        _env_val="${_env_val%%#*}"
        _env_val="${_env_val#"${_env_val%%[![:space:]]*}"}"
        _env_val="${_env_val%"${_env_val##*[![:space:]]}"}"
        if [[ "${_env_val}" == '"'*'"' ]]; then
            _env_val="${_env_val:1:${#_env_val}-2}"
        elif [[ "${_env_val}" == "'"*"'" ]]; then
            _env_val="${_env_val:1:${#_env_val}-2}"
        fi
        export "${_env_key}=${_env_val}"
    done < <(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$file_path" 2>/dev/null || true)
}

# 生成合并的 compose env 文件（默认 build/.env.compose）。
# compose 需要 env/*.env 与根目录 .env/.env.local 中的变量做插值；
# 当 compose 以 sudo 调用（用户不在 docker 组）时，进程环境被 env_reset 剥离，
# 插值拿空值会导致 "invalid spec: empty section between colons" 等错误，
# 因此按相同优先级落盘为文件，由 get_docker_compose_cmd 追加 --env-file 传入。
# 同名变量后写覆盖先写，与 load_env_file_exports 的加载语义一致。
write_compose_env_file() {
    local _project_dir="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    local _env_dir="${ENV_DIR:-$_project_dir/env}"
    local _merged_file="$_project_dir/build/.env.compose"
    local _name
    local -a _order=()
    for _name in "${HG_ENV_LAYER_FILES[@]}"; do
        _order+=("$_env_dir/$_name")
    done
    _order+=("$_project_dir/.env" "$_project_dir/.env.local")
    mkdir -p "$(dirname "$_merged_file")" 2>/dev/null || true
    {
        echo "# 自动生成（write_compose_env_file），请勿手工编辑；每次加载配置时重新生成"
        local _f _line
        for _f in "${_order[@]}"; do
            [[ -f "$_f" ]] || continue
            while IFS= read -r _line; do
                printf '%s\n' "$_line"
            done < <(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$_f" 2>/dev/null || true)
        done
    } > "$_merged_file" 2>/dev/null || return 1
    export COMPOSE_ENV_FILE="$_merged_file"
    return 0
}

# 从 env/base.env 读取默认项目环境，再由根目录 .env/.env.local 覆盖。
# 对外导出：
#   ENVIRONMENT                 development|production
#   PROJECT_ENVIRONMENT         development|production
#   PROJECT_ENVIRONMENT_SHORT   dev|prod（用于 elk.dev.env / elk.prod.env）
load_project_environment_from_base_env() {
    local project_root="${1:-}"
    if [[ -z "$project_root" ]]; then
        project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    fi
    local raw=""
    local env_source

    for env_source in "$project_root/env/base.env" "$project_root/.env" "$project_root/.env.local"; do
        if [[ -f "$env_source" ]]; then
            local _raw_candidate
            _raw_candidate="$(_get_env_file_value "$env_source" "ENVIRONMENT" || true)"
            [[ -n "$_raw_candidate" ]] && raw="$_raw_candidate"
        fi
    done
    raw="${raw,,}"

    case "$raw" in
        production|prod)
            export ENVIRONMENT="production"
            export PROJECT_ENVIRONMENT="production"
            export PROJECT_ENVIRONMENT_SHORT="prod"
            ;;
        development|dev|"")
            export ENVIRONMENT="development"
            export PROJECT_ENVIRONMENT="development"
            export PROJECT_ENVIRONMENT_SHORT="dev"
            ;;
        *)
            if declare -F warn >/dev/null 2>&1; then
                warn "环境配置中 ENVIRONMENT='$raw' 无效，已回退为 development"
            fi
            export ENVIRONMENT="development"
            export PROJECT_ENVIRONMENT="development"
            export PROJECT_ENVIRONMENT_SHORT="dev"
            ;;
    esac
}

# 根据统一项目环境导出 monitoring 宿主机端口绑定。
# production → 0.0.0.0（可经公网 IP:端口访问，需自行配置安全组/防火墙）
# development → 127.0.0.1（仅本机）
# 若调用方已设置 MONITORING_PUBLISH_HOST，则不再覆盖。
export_monitoring_publish_host_from_base_env() {
    load_project_environment_from_base_env "${1:-}"
    [[ -n "${MONITORING_PUBLISH_HOST:-}" ]] && return 0

    case "${PROJECT_ENVIRONMENT_SHORT:-dev}" in
        prod)
            export MONITORING_PUBLISH_HOST="0.0.0.0"
            ;;
        *)
            export MONITORING_PUBLISH_HOST="127.0.0.1"
            ;;
    esac
}

# 配置容器运行时别名（自动适配 Docker/Podman）
setup_docker_aliases() {
    local script_name="${1:-common}"

    if [[ -z "$CR" ]]; then
        detect_container_runtime
    fi

    # 定义所有别名（使用 $CR 变量替代硬编码 docker）
    local aliases=(
        "alias dphp74='$CR exec -it php74_apache /bin/bash'"
        "alias dphp82='$CR exec -it php82_apache /bin/bash'"
        "alias dphp84='$CR exec -it php84_apache /bin/bash'"
        "alias dphp85='$CR exec -it php85_apache /bin/bash'"
        "alias dnginx='$CR exec -it nginx /bin/bash'"
        "alias dmysql='$CR exec -it mysql /bin/bash'"
        "alias dmongo='$CR exec -it mongo /bin/bash'"
        "alias dvalkey='$CR exec -it valkey /bin/sh'"
        "alias dredis='$CR exec -it redis /bin/sh'"
        "alias dpostgres='$CR exec -it postgres /bin/bash'"
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
            # 已存在：检查内容是否一致
            local existing_line
            existing_line=$(grep "^alias $alias_name=" "$config_file" 2>/dev/null)
            if [[ "$existing_line" != "$alias_line" ]]; then
                # 内容不同，原地替换（适配 docker→podman 迁移等场景）
                sed -i "s|^alias $alias_name=.*|$alias_line|" "$config_file"
                aliases_found=$((aliases_found + 1))
            else
                aliases_found=$((aliases_found + 1))
            fi
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

        # 注意：在构建脚本中禁止 source ~/.bashrc
        # 原因：~/.bashrc 通常包含 pyenv init、nvm 等大型 source/eval 块（数千行），
        # 在非交互式脚本中执行这些会：
        #   1. 污染当前 shell 的 set -e / set -u / set -o pipefail 选项
        #   2. 导致 bash 内部行号计数（LINENO）偏移，使错误信息指向错误位置
        #   3. 引入不可预期的 PATH / 函数 / 变量覆盖
        # 别名已写入配置文件，用户在新终端或手动 source 后即可使用。
        if [[ "$script_name" == "build" ]]; then
            info "别名已写入 $config_file"
            info "请开启新终端或手动执行以下命令使别名生效: source $config_file"
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
    fi
}

# 设置配置目录权限，避免容器内权限问题
setup_conf_permissions() {
    # info "设置配置目录权限..."

    local config_roots=(
        "${BUILD_ROOT:-./build}/nginx/1.30/config"
        "${BUILD_ROOT:-./build}/tengine/3.1/config"
        "${BUILD_ROOT:-./build}/mysql/8.0/config"
        "${BUILD_ROOT:-./build}/mysql/8.4/config"
        "${BUILD_ROOT:-./build}/mysql/9.7/config"
        "${BUILD_ROOT:-./build}/redis/7.2"
        "${BUILD_ROOT:-./build}/redis/8.2"
        "${BUILD_ROOT:-./build}/redis/8.4"
        "${BUILD_ROOT:-./build}/redis/8.6"
        "${BUILD_ROOT:-./build}/redis/8.8"
        "${BUILD_ROOT:-./build}/redis/8.10"
        "${BUILD_ROOT:-./build}/rabbitmq/4.2/config"
        "${BUILD_ROOT:-./build}/canal/config"
        "${BUILD_ROOT:-./build}/elk/8.19/elasticsearch/config"
        "${BUILD_ROOT:-./build}/elk/8.19/kibana/config"
        "${BUILD_ROOT:-./build}/elk/${ELK_BUILD_VERSION:-9.5}/logstash/config"
        "${BUILD_ROOT:-./build}/elk/9.4/elasticsearch/config"
        "${BUILD_ROOT:-./build}/elk/9.4/kibana/config"
        "${BUILD_ROOT:-./build}/elk/9.4/logstash/config"
        "${BUILD_ROOT:-./build}/elk/9.5/elasticsearch/config"
        "${BUILD_ROOT:-./build}/elk/9.5/kibana/config"
        "${BUILD_ROOT:-./build}/elk/9.5/logstash/config"
        "${BUILD_ROOT:-./build}/monitoring"
    )

    local config_root
    for config_root in "${config_roots[@]}"; do
        [[ -d "$config_root" ]] || continue
        find "$config_root" -type d -exec chmod 755 {} \; 2>/dev/null || true
        find "$config_root" -type f -exec chmod 644 {} \; 2>/dev/null || true
    done

    # Logstash 配置需要写权限
    if [ -d "${BUILD_ROOT:-./build}/elk/${ELK_BUILD_VERSION:-9.5}/logstash/config" ]; then
        chmod -R 777 "${BUILD_ROOT:-./build}/elk/${ELK_BUILD_VERSION:-9.5}/logstash/config" 2>/dev/null || true
    fi

    info "服务配置目录权限设置完成"

    # 设置日志目录权限（ELK服务需要）
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

    else
        warn "日志目录 $logs_dir 无法创建"
    fi
}

# 清理日志文件函数
cleanup_logs() {
    # info "清理日志文件..."

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
# 用途：加载 env/ 分层配置与根目录 .env/.env.local，派生配置路径，并只为目标服务联网解析上游版本
# 参数：目标服务短名...（为空或含 all 时全量解析版本）
# 说明：env 文件仍全量加载——compose 会对整个工程文件插值，缺变量会导致 invalid spec；
#       耗时大头是版本联网解析，按服务裁剪的是这一步。
load_config_files() {
    local config_dir="${ENV_DIR:-$PROJECT_DIR/env}"
    local _name
    local -a config_files=()
    for _name in "${HG_ENV_LAYER_FILES[@]}"; do
        config_files+=("$config_dir/$_name")
    done
    # 根目录敏感配置与本地临时覆盖，最后加载以覆盖所有分层配置
    config_files+=("$PROJECT_DIR/.env" "$PROJECT_DIR/.env.local")

    log "开始加载分层配置文件..."

    # 检查 env 目录是否存在
    if [[ ! -d "$config_dir" ]]; then
        warn "env 目录不存在，回退到 .env 文件模式"

        if [[ ! -f ".env" ]]; then
            if [[ -f ".env.example" ]]; then
                warn ".env 文件不存在，从 .env.example 复制..."
                cp .env.example .env
            else
                error ".env 文件不存在，请先创建 .env 文件"
            fi
        fi
        config_files=(".env" ".env.local")
    fi

    # 按优先级顺序加载配置文件
    for config_file in "${config_files[@]}"; do
        if [[ -f "$config_file" ]]; then
            # info "加载配置文件: $config_file"

            set +u
            load_env_file_exports "$config_file"
            set -u
        # else
        #     info "配置文件不存在，跳过: $config_file"
        fi
    done

    success "分层配置文件加载完成"
    # 子脚本（download_dependencies.sh）据此直接继承本进程环境，不再重读 env/*.env：
    # 重读会把根目录 .env 的覆盖值改回分层默认值。
    export HG_ENV_LOADED=1

    # 同步生成 compose 插值用合并 env 文件（供 sudo 场景下 --env-file 读取）
    write_compose_env_file || true

    # 配置路径派生均为本地计算（仅空值填充，不覆盖显式设置），始终执行
    derive_mysql_conf_paths
    derive_redis_conf_paths
    # PHP：hardening.ini（版本优先 / common 兜底）+ 统一 opcache.ini
    derive_php_ini_overlay_paths
    derive_elk_conf_paths

    # 上游版本需联网解析：只解析目标服务涉及的组件
    env_scope_resolve_versions "$@"
}

# 按 MYSQL_BUILD_VERSION（如 8.0 / 8.4 / 9.7）自动解析该系列 apt 通道最新上游版本并 export MYSQL_VER。
# 每次运行解析一次（保证拿到通道最新），同一运行内及子进程复用结果；仅 MYSQL_VER_OVERRIDE 可强制钉选。
# 回退：repo.mysql.com Packages → 本地 src/mysql tar.gz。
derive_mysql_build_ver() {
    local series="${MYSQL_BUILD_VERSION:-8.4}"
    local resolved=""

    if env_scope_version_cached MYSQL "$series" MYSQL_VER; then
        return 0
    fi

    if [[ -n "${MYSQL_VER_OVERRIDE:-}" ]]; then
        resolved="${MYSQL_VER_OVERRIDE}"
        info "MySQL ${series}：使用 MYSQL_VER_OVERRIDE=${resolved}"
    else
        if declare -F resolve_mysql_latest_ver >/dev/null 2>&1; then
            resolved="$(resolve_mysql_latest_ver "$series" || true)"
        fi
        if [[ -z "$resolved" ]] && declare -F resolve_mysql_ver_from_local >/dev/null 2>&1; then
            resolved="$(resolve_mysql_ver_from_local "$series" "${_COMMON_FUNCTIONS_PROJECT_DIR}/src/mysql" || true)"
            [[ -n "$resolved" ]] && info "MySQL ${series}：离线回退本地源码包版本 ${resolved}"
        fi
    fi

    export MYSQL_VER="${resolved:-}"
    export MYSQL_PIN_POLICY="${MYSQL_PIN_POLICY:-latest}"
    if [[ -n "${MYSQL_VER}" ]]; then
        env_scope_mark_version MYSQL "$series"
        info "MySQL ${series} → MYSQL_VER=${MYSQL_VER} (PIN=${MYSQL_PIN_POLICY})"
    else
        warn "MySQL ${series}：未能解析具体版本，构建将安装 apt Candidate（PIN=latest）"
    fi
}

# 按 PG_MAJOR 自动解析 PGDG 通道最新 apt 版本并 export：
#   PG_VERSION        — 完整 apt 版本（如 18.6-1.pgdg12+2），供 bookworm Dockerfile
#   PG_SOURCE_VERSION — 上游源码版本（如 18.6），供 src/postgres 缓存与 alpine 构建
# 每次运行解析一次，同一运行内及子进程复用结果；仅 PG_VERSION_OVERRIDE 可强制钉选。
derive_pg_build_ver() {
    local major="${PG_MAJOR:-19}"
    local apt_ver=""
    local src_ver=""

    if env_scope_version_cached PG "$major" PG_SOURCE_VERSION; then
        return 0
    fi

    if [[ -n "${PG_VERSION_OVERRIDE:-}" ]]; then
        apt_ver="${PG_VERSION_OVERRIDE}"
        info "PostgreSQL ${major}：使用 PG_VERSION_OVERRIDE=${apt_ver}"
    else
        if declare -F resolve_postgres_latest_apt_ver >/dev/null 2>&1; then
            apt_ver="$(resolve_postgres_latest_apt_ver "$major" || true)"
        fi
    fi

    if [[ -n "$apt_ver" ]] && declare -F postgres_upstream_ver >/dev/null 2>&1; then
        src_ver="$(postgres_upstream_ver "$apt_ver")"
    elif declare -F resolve_postgres_ver_from_local >/dev/null 2>&1; then
        src_ver="$(resolve_postgres_ver_from_local "$major" "${_COMMON_FUNCTIONS_PROJECT_DIR}/src/postgres" || true)"
        [[ -n "$src_ver" ]] && info "PostgreSQL ${major}：离线回退本地源码包版本 ${src_ver}"
    fi

    export PG_VERSION="${apt_ver:-}"
    export PG_SOURCE_VERSION="${src_ver:-}"
    export PG_PIN_POLICY="${PG_PIN_POLICY:-latest}"
    if [[ -n "${PG_SOURCE_VERSION}" ]]; then
        env_scope_mark_version PG "$major"
    fi
    if [[ -n "${PG_VERSION}" ]]; then
        info "PostgreSQL ${major} → PG_VERSION=${PG_VERSION} PG_SOURCE_VERSION=${PG_SOURCE_VERSION:-?} (PIN=${PG_PIN_POLICY})"
    else
        warn "PostgreSQL ${major}：未能解析 apt 版本，构建将安装 apt Candidate（PIN=latest）"
    fi
}

# 按 MONGO_BUILD_VERSION 解析 apt 通道最新版 → MONGO_VERSION
# 每次运行解析一次，同一运行内及子进程复用结果；仅 MONGO_VERSION_OVERRIDE 可强制钉选。
derive_mongo_build_ver() {
    local series="${MONGO_BUILD_VERSION:-8.2}"
    local resolved=""

    if env_scope_version_cached MONGO "$series" MONGO_VERSION; then
        return 0
    fi

    if [[ -n "${MONGO_VERSION_OVERRIDE:-}" ]]; then
        resolved="${MONGO_VERSION_OVERRIDE}"
        info "MongoDB ${series}：使用 MONGO_VERSION_OVERRIDE=${resolved}"
    else
        if declare -F resolve_mongo_latest_ver >/dev/null 2>&1; then
            resolved="$(resolve_mongo_latest_ver "$series" || true)"
        fi
        if [[ -z "$resolved" ]] && declare -F resolve_mongo_ver_from_local >/dev/null 2>&1; then
            resolved="$(resolve_mongo_ver_from_local "$series" "${_COMMON_FUNCTIONS_PROJECT_DIR}/src/mongo" || true)"
            [[ -n "$resolved" ]] && info "MongoDB ${series}：离线回退本地源码包版本 ${resolved}"
        fi
    fi

    export MONGO_VERSION="${resolved:-}"
    if [[ -n "${MONGO_VERSION}" ]]; then
        env_scope_mark_version MONGO "$series"
        info "MongoDB ${series} → MONGO_VERSION=${MONGO_VERSION}"
    else
        warn "MongoDB ${series}：未能解析具体版本，构建将安装 apt Candidate（空钉选）"
    fi
}

# 按 REDIS_BUILD_VERSION 解析最新版 → REDIS_VERSION
derive_redis_build_ver() {
    local series="${REDIS_BUILD_VERSION:-8.10}"
    local resolved=""

    if env_scope_version_cached REDIS "$series" REDIS_VERSION; then
        return 0
    fi

    if [[ -n "${REDIS_VERSION_OVERRIDE:-}" ]]; then
        resolved="${REDIS_VERSION_OVERRIDE}"
        info "Redis ${series}：使用 REDIS_VERSION_OVERRIDE=${resolved}"
    else
        if declare -F resolve_redis_latest_ver >/dev/null 2>&1; then
            resolved="$(resolve_redis_latest_ver "$series" || true)"
        fi
        if [[ -z "$resolved" ]] && declare -F resolve_redis_ver_from_local >/dev/null 2>&1; then
            resolved="$(resolve_redis_ver_from_local "$series" "${_COMMON_FUNCTIONS_PROJECT_DIR}/src/redis" || true)"
            [[ -n "$resolved" ]] && info "Redis ${series}：离线回退本地源码包版本 ${resolved}"
        fi
    fi

    export REDIS_VERSION="${resolved:-}"
    if [[ -n "${REDIS_VERSION}" ]]; then
        env_scope_mark_version REDIS "$series"
        info "Redis ${series} → REDIS_VERSION=${REDIS_VERSION}"
    else
        warn "Redis ${series}：未能解析具体版本，源码构建可能失败"
    fi
}

# 按 VALKEY_BUILD_VERSION 解析最新版 → VALKEY_VERSION
derive_valkey_build_ver() {
    local series="${VALKEY_BUILD_VERSION:-8.1}"
    local resolved=""

    if env_scope_version_cached VALKEY "$series" VALKEY_VERSION; then
        return 0
    fi

    if [[ -n "${VALKEY_VERSION_OVERRIDE:-}" ]]; then
        resolved="${VALKEY_VERSION_OVERRIDE}"
        info "Valkey ${series}：使用 VALKEY_VERSION_OVERRIDE=${resolved}"
    else
        if declare -F resolve_valkey_latest_ver >/dev/null 2>&1; then
            resolved="$(resolve_valkey_latest_ver "$series" || true)"
        fi
        if [[ -z "$resolved" ]] && declare -F resolve_valkey_ver_from_local >/dev/null 2>&1; then
            resolved="$(resolve_valkey_ver_from_local "$series" "${_COMMON_FUNCTIONS_PROJECT_DIR}/src/valkey" || true)"
            [[ -n "$resolved" ]] && info "Valkey ${series}：离线回退本地源码包版本 ${resolved}"
        fi
    fi

    export VALKEY_VERSION="${resolved:-}"
    if [[ -n "${VALKEY_VERSION}" ]]; then
        env_scope_mark_version VALKEY "$series"
        info "Valkey ${series} → VALKEY_VERSION=${VALKEY_VERSION}"
    else
        warn "Valkey ${series}：未能解析具体版本，源码构建可能失败"
    fi
}

# 按 MYSQL_BUILD_VERSION 派生 MYSQL_CONF_FILE / MYSQL_ENV_CONFIG_FILE（自动发现机制）。
# 仅当变量为空时填充默认值，尊重 .env/.env.local 中的显式覆盖；
# 切换版本只需修改 MYSQL_BUILD_VERSION，配置路径自动跟随 build/mysql/<版本>/。
derive_mysql_conf_paths() {
    local _base="${BUILD_ROOT:-${PROJECT_DIR:-}/build}/mysql/${MYSQL_BUILD_VERSION:-8.4}"
    if [[ -z "${MYSQL_CONF_FILE:-}" ]]; then
        export MYSQL_CONF_FILE="${_base}/config/my.cnf"
    fi
    if [[ -z "${MYSQL_ENV_CONFIG_FILE:-}" ]]; then
        export MYSQL_ENV_CONFIG_FILE="${_base}/config/conf.d/mysql-${PROJECT_ENVIRONMENT_SHORT:-dev}.cnf"
    fi
    unset _base
}

# Redis 配置路径随 REDIS_BUILD_VERSION 自动跟随（仅空值填充）
derive_redis_conf_paths() {
    local _base="${BUILD_ROOT:-${PROJECT_DIR:-}/build}/redis/${REDIS_BUILD_VERSION:-8.10}"
    if [[ -z "${REDIS_CONF_FILE:-}" ]]; then
        # compose 挂载使用相对项目根的路径（与历史 env 约定一致）
        export REDIS_CONF_FILE="../../build/redis/${REDIS_BUILD_VERSION:-8.10}/redis.conf"
    fi
    unset _base
}

# PHP conf.d 覆盖：版本目录 hardening.ini 优先，缺失则回落 common/hardening.ini；
# 全版本统一挂载 common/opcache.ini。路径相对 compose/stacks（../../build/...）。
# 用途：启动时以 conf.d/zz-*.ini 覆盖 php.ini 中对应项（disable_functions / expose_php / opcache 等）。
derive_php_ini_overlay_paths() {
    local _php_root="${BUILD_ROOT:-${PROJECT_DIR:-}/build}/php"
    local _common_hardening_abs="${_php_root}/common/hardening.ini"
    local _common_hardening_rel="../../build/php/common/hardening.ini"
    local _common_opcache_abs="${_php_root}/common/opcache.ini"
    local _common_opcache_rel="../../build/php/common/opcache.ini"
    local _ver _tag _var _ver_abs _ver_rel

    if [[ -z "${PHP_OPCACHE_INI_FILE:-}" ]]; then
        export PHP_OPCACHE_INI_FILE="${_common_opcache_rel}"
    fi
    if [[ ! -f "${_common_opcache_abs}" ]]; then
        error "缺少 ${_common_opcache_abs}（全版本 PHP 必须加载 opcache.ini）"
    fi

    for _ver in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
        _tag="${_ver//./}"
        _var="PHP${_tag}_HARDENING_INI_FILE"
        _ver_abs="${_php_root}/${_ver}/hardening.ini"
        _ver_rel="../../build/php/${_ver}/hardening.ini"

        if [[ -f "${_ver_abs}" ]]; then
            printf -v "${_var}" '%s' "${_ver_rel}"
            export "${_var?}"
        elif [[ -f "${_common_hardening_abs}" ]]; then
            printf -v "${_var}" '%s' "${_common_hardening_rel}"
            export "${_var?}"
            warn "PHP ${_ver}：未找到 build/php/${_ver}/hardening.ini，回落 common/hardening.ini"
        else
            error "PHP ${_ver}：hardening.ini 缺失（版本目录与 common 均无）"
        fi
    done
    unset _php_root _common_hardening_abs _common_hardening_rel
    unset _common_opcache_abs _common_opcache_rel
    unset _ver _tag _var _ver_abs _ver_rel
}

# 按 ELK_BUILD_VERSION 解析通道最新版 → ELK_VERSION；TINI 默认 v0.19.0（官方仍在用）
# 每次运行解析一次，同一运行内及子进程复用结果；仅 ELK_VERSION_OVERRIDE 可强制钉选。
derive_elk_build_ver() {
    local series="${ELK_BUILD_VERSION:-9.5}"
    local resolved=""

    if env_scope_version_cached ELK "$series" ELK_VERSION; then
        export TINI_VERSION="${TINI_VERSION:-v0.19.0}"
        return 0
    fi

    if [[ -n "${ELK_VERSION_OVERRIDE:-}" ]]; then
        resolved="${ELK_VERSION_OVERRIDE}"
        info "ELK ${series}：使用 ELK_VERSION_OVERRIDE=${resolved}"
    else
        if declare -F resolve_elk_latest_ver >/dev/null 2>&1; then
            resolved="$(resolve_elk_latest_ver "$series" || true)"
        fi
        if [[ -z "$resolved" ]] && declare -F resolve_elk_ver_from_local >/dev/null 2>&1; then
            resolved="$(resolve_elk_ver_from_local "$series" "${_COMMON_FUNCTIONS_PROJECT_DIR}/src/elk" || true)"
            [[ -n "$resolved" ]] && info "ELK ${series}：离线回退本地源码包版本 ${resolved}"
        fi
    fi

    export ELK_VERSION="${resolved:-}"
    # 不强制要求 env 配置 TINI_VERSION；与官方 dockerfiles 对齐默认 v0.19.0
    export TINI_VERSION="${TINI_VERSION:-v0.19.0}"
    if [[ -n "${ELK_VERSION}" ]]; then
        env_scope_mark_version ELK "$series"
        info "ELK ${series} → ELK_VERSION=${ELK_VERSION} (TINI=${TINI_VERSION})"
    else
        warn "ELK ${series}：未能解析具体版本，构建/下载可能失败"
    fi
}

# 按 ELK_BUILD_VERSION 派生 ES/Kibana/Logstash 配置路径（仅空值填充）。
# 切换版本只需修改 ELK_BUILD_VERSION；env/elk.env 与 elk.{dev,prod}.env 不必再写带版本号的路径。
derive_elk_conf_paths() {
    local series="${ELK_BUILD_VERSION:-9.5}"
    local rel="../../build/elk/${series}"
    local env_short="${PROJECT_ENVIRONMENT_SHORT:-dev}"
    case "${env_short}" in
        production|prod) env_short="prod" ;;
        *) env_short="dev" ;;
    esac

    if [[ -z "${ELASTICSEARCH_CONF_DIR:-}" ]]; then
        export ELASTICSEARCH_CONF_DIR="${rel}/elasticsearch/config"
    fi
    if [[ -z "${KIBANA_CONF_DIR:-}" ]]; then
        export KIBANA_CONF_DIR="${rel}/kibana/config"
    fi
    if [[ -z "${LOGSTASH_CONF_DIR:-}" ]]; then
        export LOGSTASH_CONF_DIR="${rel}/logstash/config"
    fi
    # pipeline 目录存放实际 default.conf；conf.d 仅占位
    if [[ -z "${LOGSTASH_PIPELINE_CONF_DIR:-}" ]]; then
        export LOGSTASH_PIPELINE_CONF_DIR="${rel}/logstash/config/pipeline"
    fi
    if [[ -z "${ELASTICSEARCH_YML_FILE:-}" ]]; then
        export ELASTICSEARCH_YML_FILE="${rel}/elasticsearch/config/elasticsearch.${env_short}.yml"
    fi
    unset series rel env_short
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

# 检测并返回正确的 Compose 命令
# 优先 podman-compose（若 Podman 可用），其次 docker compose V2，最后 docker-compose V1
# 该函数由 container_runtime.sh 的 detect_container_runtime() 统一设置 COMPOSE_CMD
get_docker_compose_cmd() {
    if [[ -z "$COMPOSE_CMD" ]]; then
        detect_container_runtime || true
    fi
    if [[ -z "$COMPOSE_CMD" ]]; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} 未找到可用的 Compose 命令，dry-run 使用占位命令: docker compose" >&2
            echo "docker compose"
            return 0
        fi
        error "未找到可用的 Compose 命令 (podman-compose / docker compose / docker-compose)"
        return 1
    fi
    # 若需要 sudo（当前用户不在 docker 组），在 COMPOSE_CMD 前加 sudo
    # sudo 默认 env_reset 会剥离导出的构建变量，compose 插值会拿到空值
    # （如 ${GLOBAL_WEB_PATH}:/var/www/html:rw,Z → "invalid spec: empty section between colons"）。
    # 故存在合并 env 文件时，始终追加 --env-file，让插值走文件而非进程环境。
    local _compose_env_args=""
    if [[ -n "${COMPOSE_ENV_FILE:-}" && -f "$COMPOSE_ENV_FILE" ]]; then
        _compose_env_args=" --env-file $COMPOSE_ENV_FILE"
    elif [[ -n "${PROJECT_DIR:-}" && -f "$PROJECT_DIR/build/.env.compose" ]]; then
        _compose_env_args=" --env-file $PROJECT_DIR/build/.env.compose"
    fi
    if [[ -n "${CR_SUDO:-}" ]]; then
        echo "${CR_SUDO} ${COMPOSE_CMD}${_compose_env_args}"
    else
        echo "${COMPOSE_CMD}${_compose_env_args}"
    fi
    return 0
}

# 显示build.sh帮助信息
show_build_help() {
    cat << EOF
${CYAN}Docker 项目构建脚本 v2.0${NC}

${YELLOW}使用方法:${NC}
    $0 [服务名...] [选项]

${YELLOW}服务名:${NC}
    php84, php83, php82, php81, php80, php74  - PHP服务
    nginx, tengine                                    - Web服务器 ⚠️ 二选一
    mysql, mysql                                   - MySQL数据库 ⚠️ 二选一
    redis, valkey                                     - 缓存服务
    mongo|mongodb, postgres|postgresql                - 其他数据库
    rabbitmq                                         - RabbitMQ消息队列
    canal, canal-server                              - Canal 服务
    syncer                                           - MySQL ➜ Elasticsearch 同步服务
    monitoring                                       - Prometheus + Grafana 监控栈（使用拉取镜像，无需构建）
    elk                                              - ELK栈 (elasticsearch, kibana, logstash)
    sgr                                              - Spug+Gitea+Rap2栈
    all                                              - 所有服务

${YELLOW}环境来源:${NC}
    统一读取 env/base.env 中的 ENVIRONMENT=development|dev|production|prod
    命令行 dev/prod 参数已废弃，仅保留兼容提示，不再覆盖项目环境。

${YELLOW}选项:${NC}
    --no-cache         不使用构建缓存
    --parallel         并行构建 (默认启用)
    --no-parallel      禁用并行构建
    --multi-arch       多架构构建 (linux/amd64,linux/arm64)
    --push             构建完成后推送到镜像仓库
    --force-recreate   构建完成后强制重新创建容器（不会替代 build）
    --auto-prune       构建后自动清理
    --auto-up          构建后自动启动服务
    --build-timeout    构建超时时间（秒），默认7200秒（2小时）
                       用于防止网络缓慢时无限等待。建议值：
                       • 7200   - 2小时（默认值，快速网络）
                       • 10800  - 3小时（中等网络）
                       • 14400  - 4小时（慢速网络或大型镜像）
                       • 21600  - 6小时（极慢网络或多个大型镜像）
    --ignorefile FILE  指定构建使用的 ignore 规则文件（相对项目根目录或绝对路径）
    --check-proxy      独立检测代理配置并输出结果（不执行构建）
    --help, -h, help   显示此帮助信息

${YELLOW}示例:${NC}
    $0                                              # 显示帮助信息
    $0 help                                         # 显示帮助信息
    $0 php84                                        # 按 base.env 当前环境构建PHP84
    $0 php84 --no-cache                             # 无缓存构建PHP84
    $0 php84 php82 mysql valkey                    # 按 base.env 当前环境构建多个服务
    $0 php84 php82 mysql valkey --force-recreate    # 先构建，再按新镜像重建容器
    $0 elk                                          # 按 base.env 当前环境构建ELK栈
    $0 sgr                                          # 按 base.env 当前环境构建SGR栈
    $0 rabbitmq                                     # 构建RabbitMQ服务
    $0 canal                                        # 构建Canal服务
    $0 syncer                                       # 构建Syncer服务
    $0 monitoring                                   # 启动监控栈（仅拉取镜像，不构建）
    $0 php84 --multi-arch                           # 多架构构建
    $0 elk canal rabbitmq syncer --build-timeout 14400  # 混合栈构建，增加超时到4小时
    $0 elk --no-cache --build-timeout 21600       # 无缓存构建ELK，超时6小时（处理极慢网络）
    $0 php74 --ignorefile .dockerignore.php         # 构建 PHP74 时显式指定 ignore 规则
    $0 --check-proxy                                # 检测当前代理配置是否可用

${YELLOW}特殊组合:${NC}
    elk     -> elasticsearch, kibana, logstash
    sgr     -> spug, gitea, rap2
    rabbitmq -> RabbitMQ 消息队列服务
    canal   -> canal-server
    syncer      -> syncer 同步服务
    monitoring  -> prometheus + grafana（配置位于 build/monitoring/）
    all         -> 所有可用服务

${RED}${BOLD}⚠️  重要提示: 构建环境只读取 env/base.env 的 ENVIRONMENT。${NC}

${YELLOW}网络问题排查:${NC}
    如果构建超时（特别是拉取 canal、elasticsearch 等大型镜像时）：

    1. 增加超时时间：
       $0 elk canal rabbitmq syncer --build-timeout 14400

    2. 配置国内镜像源加速（中国大陆用户推荐）：
       export CHANGE_SOURCE=true
       $0 elk canal rabbitmq syncer --build-timeout 10800

    3. 配置 HTTP/HTTPS 代理：
       export HTTP_PROXY=http://proxy.example.com:8080
       export HTTPS_PROXY=https://proxy.example.com:8080
       $0 elk canal rabbitmq syncer --build-timeout 10800

    4. 检查网络连接：
       ping 8.8.8.8
       curl -I https://hub.docker.com/

    5. 查看 Docker 镜像拉取日志：
       docker events --filter type=image

EOF
}

# 显示up.sh帮助信息
show_up_help() {
    cat << EOF
${CYAN}Docker 项目管理脚本 v2.0${NC}

${YELLOW}使用方法:${NC}
    $0 [命令] [服务名...] [选项]

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
    php84, php83, php82, php81, php80, php74  - PHP服务
    nginx, tengine                                    - Web服务器 ⚠️ 二选一
    mysql, mysql                                   - MySQL数据库 ⚠️ 二选一
    redis, valkey                                     - 缓存服务
    mongo|mongodb, postgres|postgresql                - 其他数据库
    rabbitmq                                         - RabbitMQ消息队列
    canal, canal-server                              - Canal 服务
    syncer                                           - MySQL ➜ Elasticsearch 同步服务
    elk                                              - ELK栈 (elasticsearch, kibana, logstash)
    sgr                                              - Spug+Gitea+Rap2栈
    all                                              - 所有服务

${YELLOW}环境来源:${NC}
    统一读取 env/base.env 中的 ENVIRONMENT=development|dev|production|prod
    命令行 dev/prod 参数已废弃，仅保留兼容提示，不再覆盖项目环境。

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
    $0 up                                           # 按 base.env 当前环境启动所有服务
    $0 up php84 mysql                             # 启动指定服务
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
    rabbitmq -> RabbitMQ 消息队列服务
    canal   -> canal-server
    syncer  -> syncer 同步服务
    all     -> 所有可用服务

${RED}${BOLD}⚠️  重要提示: 启动环境只读取 env/base.env 的 ENVIRONMENT。${NC}

EOF
}
