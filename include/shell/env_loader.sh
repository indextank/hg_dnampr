#!/usr/bin/env bash
# ==========================================
# 环境变量加载与审计函数库
# ==========================================
# 用途：加载项目分层环境配置、审计日志记录
# 依赖：
#   common_functions.sh（info/warn/error/success 函数）
# 全局变量（由调用方提供）：
#   PROJECT_DIR     — 项目根目录
#   SCRIPT_DIR      — 脚本目录
#   AUDIT_LOG_FILE  — 审计日志文件路径
#   ORIGINAL_CMDLINE — 原始命令行
# ==========================================

audit_log() {
    local status="$1"
    local detail="$2"
    local ts user host cwd
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    user="${USER:-$(id -un 2>/dev/null || echo unknown)}"
    host="$(hostname 2>/dev/null || echo unknown-host)"
    cwd="$(pwd)"
    mkdir -p "$(dirname "$AUDIT_LOG_FILE")" 2>/dev/null || true
    printf '%s | user=%s host=%s status=%s op=%s env=%s services="%s" cwd=%s cmd="%s" detail="%s"\n' \
        "$ts" "$user" "$host" "$status" "${OPERATION:-unknown}" "${ENVIRONMENT:-unknown}" \
        "${SERVICES[*]:-all}" "$cwd" "$ORIGINAL_CMDLINE" "$detail" >>"$AUDIT_LOG_FILE" 2>/dev/null || true
}

_audit_on_exit() {
    local code="$1"
    if [[ "$code" -eq 0 ]]; then
        audit_log "OK" "脚本执行成功"
    else
        audit_log "FAIL:$code" "脚本异常退出"
    fi
}

# 检查分层配置文件
check_layered_config() {
    local config_dir="${ENV_DIR:-env}"
    local required_configs=("base.env" "web.env" "php.env" "mysql.env" "postgres.env" "db_backup.env" "mongodb.env" "redis.env" "timescaledb.env" "pgvector.env" "clickhouse.env")

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

# 加载环境变量函数定义
load_environment_variables() {
    local config_dir="${ENV_DIR:-env}"
    local env_files=("base.env" "web.env" "php.env" "mysql.env" "postgres.env" "db_backup.env" "mongodb.env" "redis.env" "timescaledb.env" "pgvector.env" "clickhouse.env" "elk.env" "apps.env" "rabbitmq.env" "canal.env" "syncer.env")

    # 保存当前的ENVIRONMENT值（已由 env/base.env 设置）
    local saved_environment="$ENVIRONMENT"

    # 设置导出模式
    set -a

    # 加载基础配置文件
    for env_file in "${env_files[@]}"; do
        local file_path="$config_dir/$env_file"
        if [[ -f "$file_path" ]]; then
            # 过滤掉注释行和空行，排除ENVIRONMENT变量（统一由 base.env 入口函数控制）
            while IFS= read -r _up_line; do
                _up_key="${_up_line%%=*}"
                _up_val="${_up_line#*=}"
                if [[ "${_up_val}" == '"'*'"' ]]; then
                    _up_val="${_up_val:1:${#_up_val}-2}"
                elif [[ "${_up_val}" == "'"*"'" ]]; then
                    _up_val="${_up_val:1:${#_up_val}-2}"
                fi
                export "${_up_key}=${_up_val}"
            done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$file_path" 2>/dev/null | grep -v '^ENVIRONMENT=' || true)
            unset _up_key _up_val _up_line
        fi
    done

    # 恢复ENVIRONMENT值，避免其它分层配置覆盖 base.env 的项目环境标识
    ENVIRONMENT="$saved_environment"

    # 根据指定环境加载特定的环境配置（会覆盖基础配置）
    local env_specific_files=()

    # 检查是否有ELK或Syncer服务，如果有，加载对应的ELK环境配置。
    # Syncer 依赖 ELK 的 ELASTICSEARCH_PROTOCOL 变量（决定 http/https），
    # 因此启动 syncer 时也需要加载正确的 elk.{env}.env，保证协议与 ELK 栈一致。
    # 含 ELK 任一组件时也加载 elk.{env}.env，否则仅写 elasticsearch 时 ELASTICSEARCH_DATA_PATH 不生效，
    # 与「先 down 再 start」相比 restart 若走 force-recreate 会误绑到默认命名卷。
    if [[ " ${SERVICES[@]} " =~ " elk " ]] || [[ " ${SERVICES[@]} " =~ " elasticsearch " ]] || [[ " ${SERVICES[@]} " =~ " kibana " ]] || [[ " ${SERVICES[@]} " =~ " logstash " ]] || [[ " ${SERVICES[@]} " =~ " syncer " ]] || [[ ${#SERVICES[@]} -eq 0 ]]; then
        # ELK 环境配置统一按 base.env 的 ENVIRONMENT 选择。
        local env_name="${PROJECT_ENVIRONMENT_SHORT:-dev}"

        # 检查 ELK 环境配置文件；该配置随 ELK 版本走，位于 build/elk/<version>/ 下。
        local elk_major_minor="${ELK_BUILD_VERSION:-9.5}"
        if [[ "$elk_major_minor" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            elk_major_minor="${elk_major_minor%.*}"
        fi
        local elk_env_file="${BUILD_ROOT:-$PROJECT_DIR/build}/elk/${elk_major_minor}/elk.${env_name}.env"
        if [[ -f "$elk_env_file" ]]; then
            info "🔧 加载ELK【${env_name}】环境配置: $elk_env_file"
            while IFS= read -r _up_line; do
                _up_key="${_up_line%%=*}"
                _up_val="${_up_line#*=}"
                if [[ "${_up_val}" == '"'*'"' ]]; then
                    _up_val="${_up_val:1:${#_up_val}-2}"
                elif [[ "${_up_val}" == "'"*"'" ]]; then
                    _up_val="${_up_val:1:${#_up_val}-2}"
                fi
                export "${_up_key}=${_up_val}"
            done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$elk_env_file" 2>/dev/null || true)
            unset _up_key _up_val _up_line
        else
            warn "未找到ELK环境配置文件: $elk_env_file，使用默认配置"
        fi
    fi

    # 根目录 .env/.env.local 最后加载，覆盖 env/ 下所有分层配置。
    # container-strip-host-proxy.env 仍会在 Compose env_file 运行时兜底清理代理变量，避免构建代理进入容器。
    load_env_file_exports "$PROJECT_DIR/.env"
    load_env_file_exports "$PROJECT_DIR/.env.local"
    load_project_environment_from_base_env "$PROJECT_DIR"

    # 将项目内相对路径规范化为绝对路径，供 shell 脚本内部检查/生成文件使用。
    # Compose 文件仍通过 env_file 使用 ../../build 等相对路径，按 compose/stacks 目录正确解析。
    _normalize_project_relative_env_paths

    # 从 DATA_PATH_HOST + *_DATA_SUBDIR 派生传统的 *_DATA_PATH 变量并 export，
    # 供仍以 ${MYSQL_DATA_PATH} 等旧名读取宿主机路径的 shell 脚本使用
    # （如 scripts/reset-mysql-password.sh）。Compose YAML 端已直接使用嵌套插值，
    # 此处仅为运行时 shell 兼容层；如未配置 DATA_PATH_HOST 则保留空值，由调用方自行处理。
    _derive_legacy_data_paths

    # MySQL：按 MYSQL_BUILD_VERSION 解析通道最新版 → MYSQL_VER
    if declare -F derive_mysql_build_ver >/dev/null 2>&1; then
        derive_mysql_build_ver
    fi

    # MySQL：按 MYSQL_BUILD_VERSION 派生 MYSQL_CONF_FILE / MYSQL_ENV_CONFIG_FILE
    if declare -F derive_mysql_conf_paths >/dev/null 2>&1; then
        derive_mysql_conf_paths
    fi

    # PostgreSQL：按 PG_MAJOR 解析 PGDG 通道最新版 → PG_VERSION / PG_SOURCE_VERSION
    if declare -F derive_pg_build_ver >/dev/null 2>&1; then
        derive_pg_build_ver
    fi

    # Mongo / Redis / Valkey：按 *_BUILD_VERSION 解析通道最新版
    if declare -F derive_mongo_build_ver >/dev/null 2>&1; then
        derive_mongo_build_ver
    fi
    if declare -F derive_redis_build_ver >/dev/null 2>&1; then
        derive_redis_build_ver
    fi
    if declare -F derive_valkey_build_ver >/dev/null 2>&1; then
        derive_valkey_build_ver
    fi
    if declare -F derive_redis_conf_paths >/dev/null 2>&1; then
        derive_redis_conf_paths
    fi

    # PHP：hardening.ini（版本优先 / common 兜底）+ 统一 opcache.ini
    if declare -F derive_php_ini_overlay_paths >/dev/null 2>&1; then
        derive_php_ini_overlay_paths
    fi

    # ELK：按 ELK_BUILD_VERSION 解析通道最新版 → ELK_VERSION，并派生配置路径
    if declare -F derive_elk_build_ver >/dev/null 2>&1; then
        derive_elk_build_ver
    fi
    if declare -F derive_elk_conf_paths >/dev/null 2>&1; then
        derive_elk_conf_paths
    fi

    # 关闭导出模式
    set +a
}

# 从 DATA_PATH_HOST + *_DATA_SUBDIR 派生并 export 传统 *_DATA_PATH 变量。
# 仅当目标变量当前为空时填充，避免覆盖用户在 .env 中显式覆盖的值。
_derive_legacy_data_paths() {
    local _root="${DATA_PATH_HOST:-}"
    local _sub _var
    local -a _pairs=(
        "MYSQL_DATA_SUBDIR:MYSQL_DATA_PATH:mysql"
        "MONGO_DATA_SUBDIR:MONGO_DATA_PATH:mongo"
        "POSTGRES_DATA_SUBDIR:POSTGRES_DATA_PATH:postgres"
        "PGADMIN_DATA_SUBDIR:PGADMIN_DATA_PATH:pgadmin"
        "SPUG_DATA_SUBDIR:SPUG_DATA_DIR:spug"
        "GITEA_DATA_SUBDIR:GITEA_DATA_DIR:gitea"
        "ELASTICSEARCH_DATA_SUBDIR:ELASTICSEARCH_DATA_PATH:elasticsearch"
    )
    local _pair _sub_var _path_var _default_subdir
    for _pair in "${_pairs[@]}"; do
        IFS=':' read -r _sub_var _path_var _default_subdir <<<"$_pair"
        # 若用户已在 .env 显式覆盖 *_DATA_PATH（含空值），尊重其选择
        if [[ -n "${!_path_var+x}" ]]; then
            continue
        fi
        _sub="${!_sub_var:-$_default_subdir}"
        if [[ -n "$_root" && -n "$_sub" ]]; then
            export "${_path_var}=${_root}/${_sub}"
        fi
    done
    # Canal 特殊处理：两个路径共享同一父目录（CANAL_DATA_SUBDIR），子目录分别为 conf 和 logs
    local _canal_sub="${CANAL_DATA_SUBDIR:-canal-server}"
    if [[ -n "$_root" && -n "$_canal_sub" ]]; then
        if [[ -z "${CANAL_CONFIG_PATH+x}" ]]; then
            export CANAL_CONFIG_PATH="${_root}/${_canal_sub}/conf"
        fi
        if [[ -z "${CANAL_LOG_PATH+x}" ]]; then
            # 复用 CANAL_CONFIG_PATH 的父目录，避免与自定义 CANAL_CONFIG_PATH 分叉
            export CANAL_LOG_PATH="${CANAL_CONFIG_PATH%/*}/logs"
        fi
    fi
}

_normalize_project_relative_env_paths() {
    # 路径变量清单来自 project_paths.sh 的单一数据源；未加载时回退到内置默认。
    local _path_vars=()
    if [[ -n "${HG_PROJECT_PATH_VARS+x}" ]]; then
        _path_vars=("${HG_PROJECT_PATH_VARS[@]}")
    else
        _path_vars=(
            MYSQL_CONF_FILE MYSQL_ENV_CONFIG_FILE MYSQL_LOG_DIR
            NGINX_CONF_FILE NGINX_VHOST_DIR NGINX_LOG_DIR NGINX_MIME_TYPES_FILE
            TENGINE_CONF_FILE
            APACHE_LOG_DIR APACHE_VHOST_DIR
            PHP74_PHP_CONF_FILE PHP80_PHP_CONF_FILE PHP81_PHP_CONF_FILE
            PHP82_PHP_CONF_FILE PHP83_PHP_CONF_FILE PHP84_PHP_CONF_FILE PHP85_PHP_CONF_FILE
            PHP74_HARDENING_INI_FILE PHP80_HARDENING_INI_FILE PHP81_HARDENING_INI_FILE
            PHP82_HARDENING_INI_FILE PHP83_HARDENING_INI_FILE PHP84_HARDENING_INI_FILE PHP85_HARDENING_INI_FILE
            PHP_OPCACHE_INI_FILE
            REDIS_CONF_FILE REDIS_LOG_DIR VALKEY_DATA_DIR REDIS_DATA_DIR
            ELASTICSEARCH_YML_FILE ELASTICSEARCH_CONF_DIR KIBANA_CONF_DIR
            LOGSTASH_CONF_DIR LOGSTASH_PIPELINE_CONF_DIR RABBITMQ_LOG_DIR
            ELASTICSEARCH_DATA_PATH ELASTICSEARCH_LOG_DIR
        )
    fi
    local _pv _val _normalized
    for _pv in "${_path_vars[@]}"; do
        _val="${!_pv:-}"
        [[ -n "$_val" ]] || continue
        case "$_val" in
            ../../*) _normalized="${PROJECT_DIR}/${_val#../../}" ;;
            ./*) _normalized="${PROJECT_DIR}/${_val#./}" ;;
            *) continue ;;
        esac
        export "${_pv}=${_normalized}"
    done
}
