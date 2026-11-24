#!/bin/bash

# ==========================================
# Docker/Podman 项目管理脚本 v2.0
# ==========================================
# 功能：服务启动、停止、重启、容器管理
# 作者：euper
# 日期：2026-05-12
# 使用方法：./up.sh [服务名...] [操作] [选项]

set -Eeuo pipefail
IFS=$'\n\t'

# 错误处理 trap - 输出错误上下文（仅在非零退出码时输出）
trap '[[ ${?} -ne 0 ]] && echo "[ERROR] 脚本: ${BASH_SOURCE[0]:-$0}, 行号: ${LINENO}, 命令: ${BASH_COMMAND}, 退出码: ${?}" >&2' ERR

# 脚本配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
ORIGINAL_CMDLINE="$0 $*"
HOSTS_CACHE_FILE="${HOSTS_CACHE_FILE:-$PROJECT_DIR/logs/hg_dnmpr-hosts-entries}"

# 审计与保护配置
AUDIT_LOG_FILE="${AUDIT_LOG_FILE:-${PROJECT_DIR}/logs/ops-audit.log}"
PROTECTED_VOLUMES_RAW="${PROTECTED_VOLUMES:-hg_dnmpr_elk_elasticsearch_data}"
ALLOW_DELETE_PROTECTED_VOLUMES="${ALLOW_DELETE_PROTECTED_VOLUMES:-false}"

# 加载公共函数库
source "$SCRIPT_DIR/include/shell/common_functions.sh"
source "$SCRIPT_DIR/include/shell/health_check.sh"
source "$SCRIPT_DIR/include/shell/elk_certs.sh"
# shellcheck source=/dev/null
[[ -f "$SCRIPT_DIR/include/shell/elk_letsencrypt.sh" ]] && source "$SCRIPT_DIR/include/shell/elk_letsencrypt.sh"

# 加载防火墙预检脚本
source "$SCRIPT_DIR/include/shell/firewall-check.sh"
source "$SCRIPT_DIR/include/shell/env_loader.sh"
source "$SCRIPT_DIR/include/shell/up_helpers.sh"
source "$SCRIPT_DIR/include/shell/service_catalog.sh"
source "$SCRIPT_DIR/include/shell/hosts_manager.sh"
source "$SCRIPT_DIR/include/shell/system_prune.sh"
source "$SCRIPT_DIR/include/shell/status_display.sh"
source "$SCRIPT_DIR/include/shell/compose_orchestrator.sh"


# Dry-run 模式（默认关闭，由 --dry-run 参数开启）
DRY_RUN="${DRY_RUN:-false}"

# 检测是否为WSL环境

# 判断服务列表是否全部为 ELK 服务（ELK 容器不需要注册到 /etc/hosts）
# 返回 0 = 全部是 ELK；返回 1 = 含有非 ELK 服务，或列表为空（空=操作所有服务）

# _cr_has_image <image:tag>
# 封装镜像存在检测，同时匹配 Docker（无前缀）和 Podman（localhost/ 前缀）两种格式。
# 返回 0 = 存在，1 = 不存在

# 自动添加MySQL备份服务

# compose 服务名与 container_name 不一致时，将服务名映射为用于 docker ps 预检的容器名


# 等待 Elasticsearch 就绪（集群健康状态达到 yellow 或 green）

# 等待 RabbitMQ 就绪（优先检查容器 health=healthy；无 healthcheck 时退化为 running）

# 执行Docker Compose命令

# 显示服务状态

# 检查是否无参数，如果是则显示帮助信息
if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

# 参数解析
SERVICES=()
OPERATION="up"
ENVIRONMENT=""
DETACH="false"
FOLLOW="false"
TAIL_LINES=""
OPTIONS=""
BUILD_IGNOREFILE=""
MYSQL_BIND_HOST_CLI_SET="false"

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        # 服务名
        php86|php85|php84|php83|php82|php81|php80|php74|nginx|tengine|mysql|mysql_backup|redis|valkey|mongo|mongodb|postgres|postgresql|pgadmin|timescaledb|timescaledb_backup|pgvector|pgvector_backup|clickhouse|clickhouse_backup|elk|elasticsearch|kibana|logstash|sgr|spug|gitea|rap2-dolores|rap2-delos|rabbitmq|syncer|canal|canal-server|monitoring|prometheus|grafana|syncer-prometheus|syncer-grafana|all)
            SERVICES+=("$1")
            shift
            ;;
        # 环境名已统一由 env/base.env 控制；保留旧参数兼容但不再覆盖。
        dev|prod|production|development|test|staging)
            warn "环境参数 '$1' 已废弃并被忽略；当前环境统一读取 env/base.env 的 ENVIRONMENT"
            shift
            ;;
        # 操作
        up|start|stop|restart|down|logs|ps|status|exec|clear|delete|prune|purne|clean-all|purge)
            # 兼容常见拼写错误：purne -> prune
            if [[ "$1" == "purne" ]]; then
                OPERATION="prune"
            else
            OPERATION="$1"
            fi
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
        --mysql-bind-host)
            if [[ $# -gt 1 ]]; then
                case "$2" in
                    127.0.0.1|0.0.0.0)
                        export MYSQL_BIND_HOST="$2"
                        MYSQL_BIND_HOST_CLI_SET="true"
                        shift 2
                        ;;
                    *)
                        error "--mysql-bind-host 仅支持 127.0.0.1 或 0.0.0.0（收到: $2）"
                        ;;
                esac
            else
                error "--mysql-bind-host 需要指定地址（127.0.0.1 或 0.0.0.0）"
            fi
            ;;
        --env)
            if [[ $# -gt 1 ]]; then
                warn "--env $2 已废弃并被忽略；当前环境统一读取 env/base.env 的 ENVIRONMENT"
                shift 2
            else
                error "--env 需要指定环境名"
            fi
            ;;
        --ignorefile)
            if [[ $# -gt 1 ]]; then
                BUILD_IGNOREFILE="$2"
                shift 2
            else
                error "--ignorefile 需要指定文件路径"
            fi
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --all-global)
            CLEAN_ALL_GLOBAL="true"
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

# 切换到项目目录
cd "$PROJECT_DIR"

# status 为只读查询：提前短路返回，避免触发日志清理、hosts 同步等副作用
if [[ "$OPERATION" == "status" ]]; then
    show_container_status "${SERVICES[@]}"
    exit 0
fi

# ── Dry-run 模式：输出操作计划摘要 ──────────────────────────────────────
if [[ "${DRY_RUN:-false}" == "true" ]]; then
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║          操 作 计 划 摘 要 (DRY-RUN)                   ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}▶ 操作类型:${NC} ${OPERATION}"
    echo -e "${YELLOW}▶ 容器运行时:${NC} ${CR:-docker} ($( cr_is_podman && echo "Podman" || echo "Docker" ))"
    echo -e "${YELLOW}▶ 项目环境:${NC} ${ENVIRONMENT}"
    if [[ ${#SERVICES[@]} -gt 0 ]]; then
        echo -e "${YELLOW}▶ 目标服务:${NC} ${SERVICES[*]}"
    else
        echo -e "${YELLOW}▶ 目标服务:${NC} 所有已部署服务（全局模式）"
    fi
    echo -e "${YELLOW}▶ 选项:${NC} ${OPTIONS:-无}"
    echo ""
    echo -e "${CYAN}── 将执行的命令计划 ──${NC}"
    echo ""
fi

# 检查配置文件
check_layered_config

# 统一项目环境：所有构建/启动相关环境判断均以 env/base.env 为准。
# 若 .env 或 .env.local 中定义了 ENVIRONMENT，则优先使用（允许用户在 .env 中覆盖）。
for _pre_env_file in "$PROJECT_DIR/.env" "$PROJECT_DIR/.env.local"; do
    if [[ -f "$_pre_env_file" ]]; then
        _pre_env_val=$((grep -E '^[[:space:]]*ENVIRONMENT=' "$_pre_env_file" 2>/dev/null || true) | tail -1 | cut -d= -f2- | tr -d '"\047' | sed 's/[[:space:]]*#.*$//' | xargs -r)
        [[ -n "$_pre_env_val" ]] && ENVIRONMENT="$_pre_env_val"
    fi
done
unset _pre_env_file _pre_env_val
load_project_environment_from_base_env "$PROJECT_DIR"


# 注意：不在这里调用load_environment_variables，而是在参数解析后调用

# 开始操作
log "开始 Docker 项目管理"
audit_log "START" "开始执行 up.sh"
trap '_audit_on_exit $?' EXIT

# 现在加载环境变量；ELK/Syncer 环境由 env/base.env 自动决定，无需交互选择。
# load_environment_variables 内部已通过 _normalize_project_relative_env_paths
# 将所有项目内相对路径变量（清单见 project_paths.sh::HG_PROJECT_PATH_VARS）统一
# 规范化为绝对路径，Docker 与 Podman（podman-compose 以 YAML 目录为基准）行为一致，
# 因此此处不再单独处理 Podman 的 './' 前缀。
# 保存命令行指定的 MYSQL_BIND_HOST，避免被 env/*.env 覆盖
_mysql_bind_host_cli_value=""
if [[ "${MYSQL_BIND_HOST_CLI_SET:-false}" == "true" ]]; then
    _mysql_bind_host_cli_value="${MYSQL_BIND_HOST:-}"
fi

load_environment_variables

# 恢复 --mysql-bind-host（优先级高于 env/mysql.env / .env）
if [[ "${MYSQL_BIND_HOST_CLI_SET:-false}" == "true" && -n "${_mysql_bind_host_cli_value}" ]]; then
    export MYSQL_BIND_HOST="${_mysql_bind_host_cli_value}"
fi
unset _mysql_bind_host_cli_value

# 让 profile 中的 COMPOSE_PROFILE 同步到 Compose 标准变量 COMPOSE_PROFILES
if [[ -n "${COMPOSE_PROFILE:-}" && -z "${COMPOSE_PROFILES:-}" ]]; then
    export COMPOSE_PROFILES="$COMPOSE_PROFILE"
fi

# 根据环境自动选择 MySQL 环境配置文件（docker/podman 通用）
if [[ -n "${MYSQL_ENV_CONFIG_FILE:-}" ]]; then
    _env_short="${PROJECT_ENVIRONMENT_SHORT:-dev}"
    _mysql_env_file="${MYSQL_ENV_CONFIG_FILE//-dev/-${_env_short}}"
    _mysql_env_file="${_mysql_env_file//-prod/-${_env_short}}"
    if [[ "$_mysql_env_file" != "$MYSQL_ENV_CONFIG_FILE" ]]; then
        if [[ "$_mysql_env_file" = /* ]]; then
            _mysql_env_check_path="$_mysql_env_file"
        else
            _mysql_env_check_path="$PROJECT_DIR/${_mysql_env_file#./}"
        fi
        if [[ -f "$_mysql_env_check_path" ]]; then
            export MYSQL_ENV_CONFIG_FILE="$_mysql_env_file"
            info "MySQL 环境配置已切换: $_env_short → ${_mysql_env_file}"
        else
            warn "MySQL 环境配置文件不存在，保持当前配置: ${MYSQL_ENV_CONFIG_FILE}（期望: ${_mysql_env_file}）"
        fi
    fi
    unset _env_short _mysql_env_file _mysql_env_check_path
fi

# 根据 profile 生成 PHP 运行时 ini 覆盖文件，使 PHP 运行时项真正影响 PHP 运行时。
# 运行时项来源：env/php.env 的 PHP_DEV_* / PHP_PROD_*，按 PROJECT_ENVIRONMENT_SHORT 选择，
# 包括 memory_limit、max_execution_time、upload_max_filesize、post_max_size、max_input_vars、
# display_errors、error_reporting。
case "${PROJECT_ENVIRONMENT_SHORT:-dev}" in
    prod)
        _php_memory_limit="${PHP_PROD_MEMORY_LIMIT:-2048M}"
        _php_max_execution_time="${PHP_PROD_MAX_EXECUTION_TIME:-60}"
        _php_upload_max_filesize="${PHP_PROD_UPLOAD_MAX_FILESIZE:-128M}"
        _php_post_max_size="${PHP_PROD_POST_MAX_SIZE:-128M}"
        _php_max_input_vars="${PHP_PROD_MAX_INPUT_VARS:-5000}"
        _php_display_errors="${PHP_PROD_DISPLAY_ERRORS:-Off}"
        _php_error_reporting="${PHP_PROD_ERROR_REPORTING:-E_ALL & ~E_DEPRECATED}"
        ;;
    *)
        _php_memory_limit="${PHP_DEV_MEMORY_LIMIT:-1024M}"
        _php_max_execution_time="${PHP_DEV_MAX_EXECUTION_TIME:-300}"
        _php_upload_max_filesize="${PHP_DEV_UPLOAD_MAX_FILESIZE:-128M}"
        _php_post_max_size="${PHP_DEV_POST_MAX_SIZE:-128M}"
        _php_max_input_vars="${PHP_DEV_MAX_INPUT_VARS:-5000}"
        _php_display_errors="${PHP_DEV_DISPLAY_ERRORS:-On}"
        _php_error_reporting="${PHP_DEV_ERROR_REPORTING:-E_ALL}"
        ;;
esac
_php_profile_ini_file="${PROJECT_DIR}/build/php/common/zz-profile-overrides.ini"
mkdir -p "$(dirname "$_php_profile_ini_file")"
{
    printf '; 由 up.sh 根据 env/%s 配置与 .env 自动生成，请勿手动修改\n' "${PROJECT_ENVIRONMENT_SHORT:-dev}"
    printf 'display_errors = %s\n' "$_php_display_errors"
    printf 'error_reporting = %s\n' "$_php_error_reporting"
    printf 'memory_limit = %s\n' "$_php_memory_limit"
    printf 'max_execution_time = %s\n' "$_php_max_execution_time"
    printf 'upload_max_filesize = %s\n' "$_php_upload_max_filesize"
    printf 'post_max_size = %s\n' "$_php_post_max_size"
    printf 'max_input_vars = %s\n' "$_php_max_input_vars"
} > "$_php_profile_ini_file"
export PHP_PROFILE_INI_FILE="$_php_profile_ini_file"
info "PHP Profile 配置已生成: ${PHP_PROFILE_INI_FILE}（环境: ${PROJECT_ENVIRONMENT_SHORT:-dev}）"
unset _php_profile_ini_file _php_memory_limit _php_max_execution_time _php_upload_max_filesize _php_post_max_size _php_max_input_vars _php_display_errors _php_error_reporting

# MySQL 宿主机端口绑定：启动/重启涉及 MySQL 时交互选择（默认 127.0.0.1）
# 须在生成 .env.runtime 之前完成，以便 compose 插值生效。
if services_need_mysql_bind_prompt "$OPERATION" "${SERVICES[@]+"${SERVICES[@]}"}"; then
    prompt_mysql_bind_host
fi

# ── 生成运行时覆盖 env 文件 ───────────────────────────────────────────────
# compose 的 env_file 会原样加载 env/*.env；脚本层面的 .env/.env.local 覆盖不会自动进入容器。
# 因此在最后追加 .env.runtime，把当前 shell 中合并后的最终配置值写入，确保 .env 是最高优先级。
_script_env_file="${PROJECT_DIR}/.env.runtime"
_runtime_env_sources=(
    "env/base.env"
    "env/web.env"
    "env/php.env"
    "env/mysql.env"
    "env/postgres.env"
    "env/mongodb.env"
    "env/db_backup.env"
    "env/redis.env"
    "env/timescaledb.env"
    "env/pgvector.env"
    "env/clickhouse.env"
    "env/elk.env"
    "env/apps.env"
    "env/rabbitmq.env"
    "env/canal.env"
    "env/syncer.env"
    "build/elk/${ELK_BUILD_VERSION:-9.5}/elk.${PROJECT_ENVIRONMENT_SHORT:-dev}.env"
    ".env"
    ".env.local"
)
: > "$_script_env_file"
_runtime_existing_env_sources=()
for _runtime_src in "${_runtime_env_sources[@]}"; do
    [[ -f "$_runtime_src" ]] && _runtime_existing_env_sources+=("$_runtime_src")
done
if [[ ${#_runtime_existing_env_sources[@]} -gt 0 ]]; then
    while IFS= read -r _runtime_key; do
        [[ -z "$_runtime_key" ]] && continue
        if [[ -v $_runtime_key ]]; then
            _runtime_val="${!_runtime_key}"
            _runtime_val="${_runtime_val//\'/\'\\\'\'}"
            printf "%s='%s'\n" "$_runtime_key" "$_runtime_val" >> "$_script_env_file"
        fi
    done < <(grep -hE '^[A-Za-z_][A-Za-z0-9_]*=' "${_runtime_existing_env_sources[@]}" | cut -d= -f1 | sort -u)
    fi
    # 派生变量（源 env 中可能被注释，grep 扫不到）：必须显式写入，否则 compose 插值变空
    for _runtime_key in \
        COMPOSE_PROFILES PHP_PROFILE_INI_FILE \
        ELK_BUILD_VERSION ELK_VERSION TINI_VERSION \
        ELASTICSEARCH_CONF_DIR KIBANA_CONF_DIR LOGSTASH_CONF_DIR LOGSTASH_PIPELINE_CONF_DIR ELASTICSEARCH_YML_FILE \
        REDIS_CONF_FILE MYSQL_CONF_FILE MYSQL_ENV_CONFIG_FILE \
        MYSQL_VER PG_VERSION MONGO_VERSION REDIS_VERSION VALKEY_VERSION \
        PHP_OPCACHE_INI_FILE \
        PHP74_HARDENING_INI_FILE PHP80_HARDENING_INI_FILE PHP81_HARDENING_INI_FILE \
        PHP82_HARDENING_INI_FILE PHP83_HARDENING_INI_FILE PHP84_HARDENING_INI_FILE PHP85_HARDENING_INI_FILE PHP86_HARDENING_INI_FILE
    do
        if [[ -v $_runtime_key ]]; then
            _runtime_val="${!_runtime_key}"
            _runtime_val="${_runtime_val//\'/\'\\\'\'}"
            printf "%s='%s'\n" "$_runtime_key" "$_runtime_val" >> "$_script_env_file"
        fi
    done
    # compose --env-file 参与 YAML 展开；宿主机构建代理（含 127.0.0.1）不得进入容器上下文
    cat >> "$_script_env_file" <<'RUNENVSTRIP'
HTTP_PROXY=''
HTTPS_PROXY=''
ALL_PROXY=''
http_proxy=''
https_proxy=''
all_proxy=''
FTP_PROXY=''
ftp_proxy=''
BUILD_PROXY_URL=''
RUNENVSTRIP
    unset _runtime_env_sources _runtime_existing_env_sources _runtime_src _runtime_key _runtime_val
    info "运行时覆盖配置已生成: .env.runtime（.env/.env.local 优先级最高）"

# monitoring 端口绑定优先跟随 profile 的 PUBLISH_HOST；未设置时再按环境推导。
if [[ -n "${PUBLISH_HOST:-}" && -z "${MONITORING_PUBLISH_HOST:-}" ]]; then
    export MONITORING_PUBLISH_HOST="$PUBLISH_HOST"
fi
export_monitoring_publish_host_from_base_env "$PROJECT_DIR"

# 设置配置目录权限
setup_conf_permissions

# 配置Docker容器别名（传递脚本名称用于日志标识）；dry-run 不应修改用户 shell 配置。
if [[ "${DRY_RUN:-false}" != "true" ]]; then
    setup_docker_aliases "up"
fi

# 清理日志文件
cleanup_logs

# 处理系统级操作
case "$OPERATION" in
    clear|delete|prune|clean-all|purge)
        cache_containers_for_cleanup
        system_operations "$OPERATION"
        # dry-run 模式跳过 hosts 同步
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            sync_hosts_aliases "$OPERATION"
        fi
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
            log "启动所有已构建/已部署的服务（主栈按 hg_dnmpr_* 镜像检测；ELK/RabbitMQ/Syncer 若本地已有构建镜像也会一并拉起；自动跳过健康运行中的容器）..."

            # ── 主栈：检查已构建镜像的服务 ──────────────────────────────────
            available_services=()

            for service in php86_apache php85_apache php84_apache php83_apache php82_apache php81_apache php80_apache php74_apache nginx tengine mysql mysql_backup redis valkey mongo postgres; do
                if _cr_has_image "hg_dnmpr_${service}:latest"; then
                    available_services+=("$service")
                fi
            done

            # 自动添加MySQL备份服务
            auto_add_mysql_backup available_services "$OPERATION"

            # 与主循环镜像命名不同的服务：按需追加（compose up 使用服务键名）
            # 仅在备份镜像本地已存在时追加，避免 up --no-build 触发外网 pull 失败。
            if printf '%s\n' "${available_services[@]}" | grep -qx mongo && \
               _cr_has_image "hg_dnmpr_mongo:latest" && \
               _cr_has_image "hg_dnmpr_mongo_backup:latest" &&
               ! printf '%s\n' "${available_services[@]}" | grep -qx mongo-backup; then
                available_services+=("mongo-backup")
            fi
            if printf '%s\n' "${available_services[@]}" | grep -qx postgres && \
               _cr_has_image "hg_dnmpr_postgres:latest" && \
               _cr_has_image "hg_dnmpr_postgres_backup:latest" &&
               ! printf '%s\n' "${available_services[@]}" | grep -qx postgres-backup; then
                available_services+=("postgres-backup")
            fi
            if printf '%s\n' "${available_services[@]}" | grep -qx postgres && \
               [[ -n "$(cr_cmd images -q "dpage/pgadmin4" 2>/dev/null | head -1)" ]] && \
               ! printf '%s\n' "${available_services[@]}" | grep -qx pgadmin; then
                available_services+=("pgadmin")
            fi

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

            # 防火墙预检（advisory 模式：任何内部错误均不阻塞启动流程）
            set +eE
            FW_AUTO_ALLOW_MISSING_PORTS=true ensure_firewall_ready "$compose_files" "${available_services[@]}"
            set -Ee

            # Podman 模式：预先创建主栈网络（podman-compose 不支持 com.docker.* 网络 opt）
            if cr_is_podman; then
                # 检查特权端口限制（rootless Podman 默认不能绑定 < 1024 的端口）
                _unpriv_port=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024)
                if [[ "$_unpriv_port" -gt 80 ]]; then
                    warn "Podman rootless: ip_unprivileged_port_start=${_unpriv_port}，无法绑定端口 80/443"
                    info "正在设置 net.ipv4.ip_unprivileged_port_start=80 ..."
                    if sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80 >/dev/null 2>&1; then
                        success "ip_unprivileged_port_start 已设为 80（当前生效）"
                        # 写入 sysctl.conf 持久化（如果还没有该项）
                        if ! grep -q 'ip_unprivileged_port_start' /etc/sysctl.conf 2>/dev/null; then
                            echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee -a /etc/sysctl.conf >/dev/null
                            success "已写入 /etc/sysctl.conf 持久化"
                        fi
                    else
                        warn "自动设置失败，请手动执行:"
                        warn "  sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80"
                        warn "  echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee -a /etc/sysctl.conf"
                    fi
                fi
                if ! podman network exists hg_dnmpr_network 2>/dev/null; then
                    # 检测是否有 Docker 遗留的同子网网桥接口（如 br-hg-dnmpr），
                    # 它会导致 podman network create 报 "subnet already used" 错误。
                    _legacy_bridge="br-hg-dnmpr"
                    if ip link show "$_legacy_bridge" >/dev/null 2>&1; then
                        warn "Podman 模式: 检测到 Docker 遗留网桥 ${_legacy_bridge}（172.20.0.0/24），正在清理..."
                        if sudo ip link set "$_legacy_bridge" down 2>/dev/null && \
                           sudo ip link delete "$_legacy_bridge" 2>/dev/null; then
                            success "遗留网桥 ${_legacy_bridge} 已清理"
                        else
                            warn "无法自动清理 ${_legacy_bridge}，请手动执行: sudo ip link delete ${_legacy_bridge}"
                        fi
                    fi
                    info "Podman 模式: 预建 hg_dnmpr_network 网络..."
                    podman network create \
                        --driver bridge \
                        --subnet 172.20.0.0/24 \
                        --label io.podman.compose.project=hg_dnmpr \
                        --label com.docker.compose.project=hg_dnmpr \
                        hg_dnmpr_network \
                    && success "hg_dnmpr_network 创建成功" \
                    || warn "hg_dnmpr_network 创建失败，可能已存在或权限不足，将继续尝试启动"
                else
                    info "Podman 模式: hg_dnmpr_network 已存在，跳过创建"
                fi

                # 修正持久化数据目录的 uid 映射（Podman rootless：容器内 uid 与宿主机 subuid 对应）
                # 统一按当前 compose 文件扫描 bind 路径，展开 .env 变量后 mkdir + podman unshare chown（与 compose 编排一致）
                if declare -F _podman_prepare_all_bind_mounts_from_compose &>/dev/null; then
                    _podman_prepare_all_bind_mounts_from_compose "$compose_files"
                else
                    warn "Podman：未加载 podman_bind_permissions，跳过 bind 目录 uid 映射"
                fi
            fi

            # Docker 模式：预建主栈网络（network 已声明为 external，compose 不再自管理）
            # 若网络不存在（首次启动或被手动删除），docker compose up 会直接报错。
            if ! cr_is_podman; then
                if ! docker network inspect hg_dnmpr_network >/dev/null 2>&1; then
                    info "Docker 模式: 预建 hg_dnmpr_network 网络..."
                    docker network create \
                        --driver bridge \
                        --subnet 172.20.0.0/24 \
                        --opt com.docker.network.enable_ipv6=false \
                        --opt com.docker.network.bridge.name=br-hg-dnmpr \
                        hg_dnmpr_network \
                    && success "hg_dnmpr_network 创建成功" \
                    || { docker network inspect hg_dnmpr_network >/dev/null 2>&1 \
                         && info "hg_dnmpr_network 已由其他进程创建，继续..." \
                         || warn "hg_dnmpr_network 创建失败，请手动执行: docker network create --driver bridge --subnet 172.20.0.0/24 hg_dnmpr_network"; }
                else
                    info "Docker 模式: hg_dnmpr_network 已存在，跳过创建"
                fi
            fi

            # ── 检测各独立栈：曾创建过容器，或本地已有对应构建镜像（首次也能随全局 up 拉起）
            # docker compose up --no-build -d 对健康运行中的容器是幂等的，
            # 只会启动处于 stopped/exited/restarting 状态的容器。
            _global_detach_flag="-d"

            # ELK 栈
            _elk_deployed=false
            if [[ -f "compose/stacks/elk.yaml" ]]; then
                _elk_cids=$(cr_cmd ps -a \
                    --filter "label=com.docker.compose.project=hg_dnmpr_elk" \
                    -q 2>/dev/null || true)
                if [[ -n "$_elk_cids" ]]; then
                    _elk_deployed=true
                elif _cr_has_image "hg_dnmpr_elk_elasticsearch:latest"; then
                    _elk_deployed=true
                fi
            fi

            # RabbitMQ / Canal 栈
            _rabbitmq_deployed=false
            if [[ -f "compose/stacks/rabbitmq.yaml" ]]; then
                _rmq_cids=$(cr_cmd ps -a \
                    --filter "label=com.docker.compose.project=hg_dnmpr_rabbitmq" \
                    -q 2>/dev/null || true)
                if [[ -n "$_rmq_cids" ]]; then
                    _rabbitmq_deployed=true
                elif _cr_has_image "hg_dnmpr_rabbitmq_rabbitmq:latest" \
                    && _cr_has_image "hg_dnmpr_rabbitmq_canal-server:latest"; then
                    _rabbitmq_deployed=true
                fi
            fi

            # Syncer 栈
            _syncer_deployed=false
            if [[ -f "compose/stacks/syncer.yaml" ]]; then
                _syn_cids=$(cr_cmd ps -a \
                    --filter "label=com.docker.compose.project=hg_dnmpr_syncer" \
                    -q 2>/dev/null || true)
                if [[ -n "$_syn_cids" ]]; then
                    _syncer_deployed=true
                elif cr_cmd images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -qE "^(localhost/)?syncer:latest$"; then
                    _syncer_deployed=true
                fi
            fi

            # SGR 栈
            _sgr_deployed=false
            if [[ -f "compose/stacks/sgr.yaml" ]]; then
                _sgr_cids=$(cr_cmd ps -a \
                    --filter "label=com.docker.compose.project=hg_dnmpr_sgr" \
                    -q 2>/dev/null || true)
                [[ -n "$_sgr_cids" ]] && _sgr_deployed=true
            fi

            # Monitoring 栈
            _monitoring_deployed=false
            if [[ -f "compose/stacks/monitoring.yaml" ]]; then
                _mon_cids=$(cr_cmd ps -a \
                    --filter "label=com.docker.compose.project=hg_dnmpr_monitoring" \
                    -q 2>/dev/null || true)
                [[ -n "$_mon_cids" ]] && _monitoring_deployed=true
            fi

            # ── 步骤1：启动主栈（逐个检查，跳过已健康运行的容器）──────────────
            if [[ ${#available_services[@]} -gt 0 ]]; then
                _main_need_start=()
                _main_skip=()
                for _svc in "${available_services[@]}"; do
                    _hc="$(_health_target_for_compose_service "$_svc")"
                    if _is_container_healthy "$_hc"; then
                        _main_skip+=("$_svc")
                    else
                        _main_need_start+=("$_svc")
                    fi
                done

                if [[ ${#_main_skip[@]} -gt 0 ]]; then
                    info "⏭  跳过已健康运行的主栈容器: ${_main_skip[*]}"
                fi

                if [[ ${#_main_need_start[@]} -gt 0 ]]; then
                    info "▶  启动主栈服务: ${_main_need_start[*]}"
                    _main_svc_str="$(IFS=' '; echo "${_main_need_start[*]}")"
                    _main_cmd="$compose_cmd $compose_files up --no-build $_global_detach_flag $_main_svc_str"
                    # 为前台启动设置Ctrl+C清理trap（dry-run 模式跳过）
                    if [[ "${DRY_RUN:-false}" != "true" ]]; then
                        if [[ "$DETACH" != "true" ]]; then
                            trap 'echo ""; info "检测到中断信号，正在清理 hosts..."; cache_containers_for_cleanup; sync_hosts_aliases "down"; trap - INT TERM; exit 130' INT TERM
                        fi
                        compose_up_quiet "$_main_cmd"
                        trap - INT TERM 2>/dev/null || true
                    else
                        echo -e "${CYAN}[DRY-RUN]${NC} bash -c '$_main_cmd'"
                    fi
                else
                    info "⏭  主栈所有容器均已健康运行，跳过"
                fi
            else
                info "未找到主栈已构建镜像，跳过主栈启动"
            fi

            # ── 步骤2：按依赖顺序启动各独立栈（整栈全部健康则跳过）──────────
            # ELK 优先（syncer 依赖 ES）
            if [[ "$_elk_deployed" == "true" ]]; then
                if _is_stack_all_healthy "hg_dnmpr_elk"; then
                    info "⧭  跳过 ELK 栈（所有容器均已健康运行）"
                else
                    info "▶  启动 ELK 栈..."
                    if ! check_and_generate_elk_certs "$ENVIRONMENT" "elk"; then
                        warn "ELK证书检查失败，跳过ELK栈启动"
                    else
                        # 生产环境：在 ELK 启动前确保 nginx 已应用 ELK overlay
                        case "${ENVIRONMENT:-}" in
                            production|prod)
                                if declare -f ensure_nginx_with_elk_overlay >/dev/null 2>&1; then
                                    info "生产环境 ELK（all模式）：确保 nginx 已应用 ELK overlay..."
                                    ensure_nginx_with_elk_overlay || warn "nginx ELK overlay 应用未完成，请检查 nginx 容器状态"
                                fi
                                ;;
                        esac
                        compose_up_quiet "$compose_cmd -f compose/stacks/elk.yaml up --no-build $_global_detach_flag"
                        # 生产环境：ELK 启动后申请/续签 Let's Encrypt 证书
                        case "${ENVIRONMENT:-}" in
                            production|prod)
                                if declare -f ensure_letsencrypt_cert >/dev/null 2>&1; then
                                    ensure_letsencrypt_cert || warn "Let's Encrypt 证书处理未完成，请检查相关配置"
                                fi
                                ;;
                        esac
                        # 若还需启动 syncer，等待 ES 就绪（dry-run 跳过等待）
                        if [[ "$_syncer_deployed" == "true" && "${DRY_RUN:-false}" != "true" ]]; then
                            wait_for_elasticsearch_ready "$ENVIRONMENT"
                        fi
                    fi
                fi
            fi

            # RabbitMQ / Canal
            if [[ "$_rabbitmq_deployed" == "true" ]]; then
                if _is_stack_all_healthy "hg_dnmpr_rabbitmq"; then
                    info "⏭  跳过 RabbitMQ 栈（所有容器均已健康运行）"
                else
                    # 检查 rabbitmq 主容器是否正在 starting（自行启动中）
                    # 若是，则不需要触发 compose up（避免卡住等待 healthcheck）
                    # canal-server 依赖 rabbitmq healthy，待 rabbitmq 就绪后会自动被 depends_on 拉起
                    _rmq_status=$(cr_cmd ps --filter "name=^rabbitmq$" --format "{{.Status}}" 2>/dev/null | head -1)
                    if [[ "$_rmq_status" =~ \(starting\) ]]; then
                        info "⏭  RabbitMQ 正在启动中（starting），跳过重复 up，等待就绪后 canal-server 会自动启动"
                    else
                        info "▶  启动 RabbitMQ 栈..."
                        compose_up_quiet "$compose_cmd -f compose/stacks/rabbitmq.yaml up --no-build $_global_detach_flag"
                    fi
                fi
            fi

            # Syncer（必须在 ELK 之后）
            if [[ "$_syncer_deployed" == "true" ]]; then
                if _is_stack_all_healthy "hg_dnmpr_syncer"; then
                    info "⏭  跳过 Syncer 栈（所有容器均已健康运行）"
                else
                    info "▶  启动 Syncer 栈..."
                    compose_up_quiet "$compose_cmd -f compose/stacks/syncer.yaml up --no-build $_global_detach_flag"
                fi
            fi

            # SGR
            if [[ "$_sgr_deployed" == "true" ]]; then
                if _is_stack_all_healthy "hg_dnmpr_sgr"; then
                    info "⏭  跳过 SGR 栈（所有容器均已健康运行）"
                else
                    info "▶  启动 SGR 栈..."
                    compose_up_quiet "$compose_cmd -f compose/stacks/sgr.yaml up --no-build $_global_detach_flag"
                fi
            fi

            # Monitoring
            if [[ "$_monitoring_deployed" == "true" ]]; then
                if _is_stack_all_healthy "hg_dnmpr_monitoring"; then
                    info "⏭  跳过 Monitoring 栈（所有容器均已健康运行）"
                else
                    info "▶  启动 Monitoring 栈..."
                    if [[ -f "$PROJECT_DIR/include/shell/generate-monitoring-config.sh" ]]; then
                        dry_run_or_exec bash "$PROJECT_DIR/include/shell/generate-monitoring-config.sh"
                    fi
                    compose_up_quiet "$compose_cmd -f compose/stacks/monitoring.yaml up --no-build $_global_detach_flag"
                fi
            fi

            if [[ ${#available_services[@]} -eq 0 && \
                  "$_elk_deployed" == "false" && \
                  "$_rabbitmq_deployed" == "false" && \
                  "$_syncer_deployed" == "false" && \
                  "$_sgr_deployed" == "false" && \
                  "$_monitoring_deployed" == "false" ]]; then
                warn "未发现任何已构建/已部署的服务，请先使用 ./build.sh 构建所需的服务"
                info "例如: ./build.sh php84 nginx mysql"
                exit 1
            fi

            # 启动完成后同步hosts（dry-run 模式跳过）
            if [[ "${DRY_RUN:-false}" != "true" ]]; then
                sync_hosts_aliases "$OPERATION"
            fi

            success "所有服务已处理完毕（健康运行中的容器已自动跳过）"
            ;;
        stop)
            log "停止所有正在运行的服务..."
            # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
            compose_cmd=$(get_docker_compose_cmd)

            # 检查是否有MySQL服务在运行，以确定是否需要WSL配置
            has_mysql_running=false
            if cr_cmd ps --format "{{.Names}}" | grep -q "^mysql$" 2>/dev/null; then
                has_mysql_running=true
            fi

            # 停止主要服务（如果MySQL在运行，会自动添加WSL配置）
            if [[ "$has_mysql_running" == "true" ]]; then
                compose_files=$(get_compose_files "$ENVIRONMENT" "mysql" --silent)
            else
                compose_files=$(get_compose_files "$ENVIRONMENT" --silent)
            fi
            dry_run_or_exec bash -c "$compose_cmd $compose_files stop 2>&1 | grep -v 'no container with\|no pod with\|no such container\|no such pod' >&2 || true"

            # 停止ELK服务（如果存在且正在运行）
            if [[ -f "compose/stacks/elk.yaml" ]]; then
                elk_containers=$(cr_cmd ps --filter "label=com.docker.compose.project=hg_dnmpr_elk" --format "{{.Names}}" | grep -E "elasticsearch|kibana|logstash" 2>/dev/null || echo "")
                if [[ -n "$elk_containers" ]]; then
                    info "停止ELK服务..."
                    dry_run_or_exec_words "$compose_cmd" -f compose/stacks/elk.yaml stop
                fi
            fi

            if [[ -f "compose/stacks/sgr.yaml" ]]; then
                sgr_containers=$(cr_cmd ps --filter "label=com.docker.compose.project=hg_dnmpr_sgr" --format "{{.Names}}" | grep -E "spug|gitea|rap2" 2>/dev/null || echo "")

                if [[ -n "$sgr_containers" ]]; then
                    info "停止SGR服务..."
                    dry_run_or_exec_words "$compose_cmd" -f compose/stacks/sgr.yaml stop
                fi
            fi

            if [[ -f "compose/stacks/rabbitmq.yaml" ]]; then
                rabbitmq_containers=$(cr_cmd ps --filter "label=com.docker.compose.project=hg_dnmpr_rabbitmq" --format "{{.Names}}" | grep -E "rabbitmq|canal-server" 2>/dev/null || echo "")
                if [[ -n "$rabbitmq_containers" ]]; then
                    info "停止RabbitMQ服务..."
                    dry_run_or_exec_words "$compose_cmd" -f compose/stacks/rabbitmq.yaml stop
                fi
            fi

            if [[ -f "compose/stacks/syncer.yaml" ]]; then
                syncer_containers=$(cr_cmd ps --filter "label=com.docker.compose.project=hg_dnmpr_syncer" --format "{{.Names}}" | grep -E "^syncer$" 2>/dev/null || echo "")
                if [[ -n "$syncer_containers" ]]; then
                    info "停止Syncer服务..."
                    dry_run_or_exec_words "$compose_cmd" -f compose/stacks/syncer.yaml stop
                fi
            fi

            cache_containers_for_cleanup
            # dry-run 模式跳过 hosts 同步
            if [[ "${DRY_RUN:-false}" != "true" ]]; then
                sync_hosts_aliases "$OPERATION"
            fi
            success "所有服务已停止"
            ;;

        down)
            log "停止并卸载所有服务..."
            # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
            compose_cmd=$(get_docker_compose_cmd)

            # 检查是否有MySQL服务在运行，以确定是否需要WSL配置
            has_mysql_running=false
            if cr_cmd ps -a --format "{{.Names}}" | grep -q "^mysql$" 2>/dev/null; then
                has_mysql_running=true
            fi

            if [[ "$has_mysql_running" == "true" ]]; then
                compose_files=$(get_compose_files "$ENVIRONMENT" "mysql" --silent)
            else
                compose_files=$(get_compose_files "$ENVIRONMENT" --silent)
            fi

            cache_containers_for_cleanup
            # dry-run 模式跳过 hosts 同步
            if [[ "${DRY_RUN:-false}" != "true" ]]; then
                sync_hosts_aliases "$OPERATION"
            fi
            dry_run_or_exec bash -c "$compose_cmd $compose_files down 2>&1 | grep -v 'no container with\|no pod with\|no such container\|no such pod' >&2 || true"

            # 停止并删除ELK服务（如果存在）
            if [[ -f "compose/stacks/elk.yaml" ]]; then
                info "停止并卸载ELK服务..."
                dry_run_or_exec_words "$compose_cmd" -f compose/stacks/elk.yaml down 2>/dev/null || true
            fi

            # 停止并删除SGR服务（如果存在）
            if [[ -f "compose/stacks/sgr.yaml" ]]; then
                info "停止并卸载SGR服务..."
                dry_run_or_exec_words "$compose_cmd" -f compose/stacks/sgr.yaml down 2>/dev/null || true
            fi

            # 停止并删除RabbitMQ服务（如果存在）
            if [[ -f "compose/stacks/rabbitmq.yaml" ]]; then
                info "停止并卸载RabbitMQ服务..."
                dry_run_or_exec_words "$compose_cmd" -f compose/stacks/rabbitmq.yaml down 2>/dev/null || true
            fi

            # 停止并删除Syncer服务（如果存在）
            if [[ -f "compose/stacks/syncer.yaml" ]]; then
                info "停止并卸载Syncer服务..."
                dry_run_or_exec_words "$compose_cmd" -f compose/stacks/syncer.yaml down 2>/dev/null || true
            fi

            # 清理所有容器（包括不在当前项目中定义的）
            info "清理所有容器..."
            all_containers=$(cr_cmd ps -a -q 2>/dev/null || echo "")
            if [[ -n "$all_containers" ]]; then
                info "发现 $(echo $all_containers | wc -w) 个容器，正在删除..."
                dry_run_or_exec cr_cmd rm -f $all_containers 2>/dev/null || true
            else
                info "没有发现任何容器"
            fi

            # 清理所有网络（除了默认网络）
            info "清理自定义网络..."
            custom_networks=$(cr_cmd network ls --filter "type=custom" -q 2>/dev/null || echo "")
            if [[ -n "$custom_networks" ]]; then
                info "发现 $(echo $custom_networks | wc -w) 个自定义网络，正在删除..."
                dry_run_or_exec cr_cmd network rm $custom_networks 2>/dev/null || true
            else
                info "没有发现自定义网络"
            fi

            # 清理未使用的镜像（可选）
            info "清理未使用的镜像..."
            dry_run_or_exec cr_cmd image prune -f 2>/dev/null || true

            success "所有容器和网络已清理完成"
            ;;
        restart)
            log "重启所有服务..."
            # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
            compose_cmd=$(get_docker_compose_cmd)

            # 检查是否有MySQL服务在运行，以确定是否需要WSL配置
            has_mysql_running=false
            if cr_cmd ps --format "{{.Names}}" | grep -q "^mysql$" 2>/dev/null; then
                has_mysql_running=true
            fi

            # 获取compose文件（如果MySQL在运行，会自动添加WSL配置）
            if [[ "$has_mysql_running" == "true" ]]; then
                compose_files=$(get_compose_files "$ENVIRONMENT" "mysql")
            else
            compose_files=$(get_compose_files "$ENVIRONMENT")
            fi

            # 获取当前真实运行中的主栈容器（仅 hg_dnmpr 项目）
            # 避免 Podman 下 compose ps 输出与真实运行态不一致而误重启未运行服务。
            running_containers=$(cr_cmd ps \
                --filter "label=com.docker.compose.project=hg_dnmpr" \
                --format "{{.Names}}" 2>/dev/null | sort -u || echo "")

            # 如果存在ELK compose文件，也获取ELK服务的容器
            if [[ -f "compose/stacks/elk.yaml" ]]; then
                elk_running_containers=$(cr_cmd ps \
                    --filter "label=com.docker.compose.project=hg_dnmpr_elk" \
                    --format "{{.Names}}" 2>/dev/null || echo "")
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
                        # 容器名与 compose 服务键名一致，直接使用
                        service_name="$container_name"
                        # 检查是否是ELK服务
                        if [[ "$service_name" == "elasticsearch" || "$service_name" == "kibana" || "$service_name" == "logstash" ]]; then
                            elk_services+=("$service_name")
                        else
                        restart_services+=("$service_name")
                        fi
                    fi
                done <<< "$running_containers"

                # 自动添加MySQL备份服务
                auto_add_mysql_backup restart_services "restart"
            fi

            # 防火墙预检（advisory 模式：任何内部错误均不阻塞重启流程）
            # 必须在获取容器快照之后执行：预检可能触发 Docker daemon 重启，
            # 若在此之前执行，Docker 重启会使容器列表失真，导致重启后容器丢失。
            set +eE
            FW_AUTO_ALLOW_MISSING_PORTS=true ensure_firewall_ready "$compose_files"
            set -Ee

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
                    _web_services_text="$(format_services_inline "${running_web_services[@]}")"
                    _other_services_text="$(format_services_inline "${running_other_services[@]}")"
                    info "检测到Web服务器 (${_web_services_text})，将分步重启以确保服务稳定性"

                    if cr_is_podman; then
                        # Podman 下 force-recreate 容易触发依赖删除与名称占用冲突。
                        # 改用 restart，保持“后端先、Web 后”的重启顺序，同时规避重建冲突。
                        info "步骤1: 重启后端服务（Podman 安全模式）(${_other_services_text})"
                        _restart_back_cmd="$compose_cmd $compose_files restart $(IFS=' '; echo "${running_other_services[*]}")"
                        compose_cmd_quiet "$_restart_back_cmd"
                    else
                        # Docker 保持 force-recreate，确保应用本地最新镜像层。
                        info "步骤1: 重新创建并启动后端服务 (${_other_services_text})"
                        compose_up_quiet "$compose_cmd $compose_files up -d --no-build --force-recreate $(IFS=' '; echo "${running_other_services[*]}")"
                    fi

                    if [[ "${DRY_RUN:-false}" != "true" ]]; then
                        info "等待后端服务启动完成..."
                        sleep 3
                    fi

                    if cr_is_podman; then
                        info "步骤2: 重启 Web 服务（Podman 安全模式）(${_web_services_text})"
                        _restart_web_cmd="$compose_cmd $compose_files restart $(IFS=' '; echo "${running_web_services[*]}")"
                        compose_cmd_quiet "$_restart_web_cmd"
                    else
                        info "步骤2: 重新创建并启动 Web 服务 (${_web_services_text})"
                        compose_up_quiet "$compose_cmd $compose_files up -d --no-build --force-recreate $(IFS=' '; echo "${running_web_services[*]}")"
                    fi

                    # 步骤3：重启ELK服务（如果存在）
                    if [[ ${#elk_services[@]} -gt 0 ]]; then
                        info "步骤3: 重启ELK服务 ($(format_services_inline "${elk_services[@]}"))"
                        if [[ -f "compose/stacks/elk.yaml" ]]; then
                            dry_run_or_exec_words "$compose_cmd" -f compose/stacks/elk.yaml restart "${elk_services[@]}"
                        else
                            warn "未找到 compose/stacks/elk.yaml 文件，跳过ELK服务重启"
                        fi
                    fi

                    if [[ "${DRY_RUN:-false}" != "true" ]]; then
                        sync_hosts_aliases "$OPERATION"
                    fi
                    success "所有服务重启完成"
                else
                    # 如果只有 Web 或只有后端（例如 nginx 未打上 compose label），
                    # Podman 下必须使用 restart，避免 force-recreate 触发依赖/重名冲突。
                    if [[ ${#restart_services[@]} -gt 0 ]]; then
                        if cr_is_podman; then
                            info "Podman 全局重启（单组服务）: compose restart (${restart_services[*]})"
                            compose_cmd_quiet "$compose_cmd $compose_files restart $(IFS=' '; echo "${restart_services[*]}")"
                        else
                            compose_up_quiet "$compose_cmd $compose_files up -d --no-build --force-recreate $(IFS=' '; echo "${restart_services[*]}")"
                        fi
                    else
                        if cr_is_podman; then
                            info "Podman 全局重启: compose restart（全部运行中服务）"
                            compose_cmd_quiet "$compose_cmd $compose_files restart"
                        else
                            compose_up_quiet "$compose_cmd $compose_files up -d --no-build --force-recreate"
                        fi
                    fi

                    # 重启ELK服务（如果存在）
                    if [[ ${#elk_services[@]} -gt 0 ]]; then
                        info "重启ELK服务 ($(format_services_inline "${elk_services[@]}"))"
                        if [[ -f "compose/stacks/elk.yaml" ]]; then
                            dry_run_or_exec_words "$compose_cmd" -f compose/stacks/elk.yaml restart "${elk_services[@]}"
                        else
                            warn "未找到 compose/stacks/elk.yaml 文件，跳过ELK服务重启"
                        fi
                    fi

                    success "所有服务重启完成"
                fi
            else
                # 没有运行中的主服务，检查是否有ELK服务需要重启
                if [[ ${#elk_services[@]} -gt 0 ]]; then
                    info "重启ELK服务 ($(format_services_inline "${elk_services[@]}"))"
                    if [[ -f "compose/stacks/elk.yaml" ]]; then
                        dry_run_or_exec_words "$compose_cmd" -f "compose/stacks/elk.yaml" restart "${elk_services[@]}"
                        # ELK 服务不需要注册到 /etc/hosts，ELK-only 重启跳过 hosts 同步
                        success "ELK服务重启完成"
                    else
                        warn "未找到 compose/stacks/elk.yaml 文件，跳过ELK服务重启"
                    fi
                else
                    # 正常「重启」：Docker 强制重建；
                    # Podman 下若当前无运行快照，用 up -d --no-build 启动已定义服务（不 force-recreate，避免依赖冲突）。
                    if cr_is_podman; then
                        info "Podman: 无运行中主栈容器快照，执行 up -d --no-build（安全模式）"
                        compose_up_quiet "$compose_cmd $compose_files up -d --no-build"
                    else
                        compose_up_quiet "$compose_cmd $compose_files up -d --no-build --force-recreate"
                    fi
                    if [[ "${DRY_RUN:-false}" != "true" ]]; then
                        sync_hosts_aliases "$OPERATION"
                    fi
                    success "所有服务重启完成"
                fi
            fi
            ;;
        *)
            error "操作 '$OPERATION' 需要指定服务名"
            ;;
    esac
else
    # Non-global: run compose for named SERVICES (avoid nested case/esac here — some merges broke parsing)
    if [[ "$OPERATION" == "stop" || "$OPERATION" == "down" || "$OPERATION" == "delete" || "$OPERATION" == "purge" || "$OPERATION" == "clean-all" || "$OPERATION" == "clear" || "$OPERATION" == "prune" ]]; then
        # ELK-only: skip hosts sync (no sudo); other stacks: cache + sync before destructive ops
        # dry-run 模式跳过 hosts 同步
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            if ! is_elk_only_services "${SERVICES[@]}"; then
                cache_containers_for_cleanup
                sync_hosts_aliases "$OPERATION"
            fi
        fi
    fi
    execute_compose_command "$ENVIRONMENT" "$OPERATION" "$OPTIONS" "${SERVICES[@]}"
    success "操作完成"
fi

log "所有操作完成！"
