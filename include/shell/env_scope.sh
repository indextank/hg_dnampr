#!/bin/bash
# ==========================================
# 服务作用域：按目标服务裁剪 env 加载与上游版本联网解析
# ==========================================
# 单一来源：
#   HG_ENV_LAYER_FILES          env/ 分层文件的标准加载顺序（根目录 .env/.env.local 由调用方最后加载）
#   env_scope_has               服务列表是否涉及某组件
#   env_scope_env_files         服务列表 → 需加载的 env/*.env 文件名
#   env_scope_resolve_versions  服务列表 → 只联网解析涉及组件的上游版本
#   env_scope_skip_versions     不构建的入口（up.sh）跳过版本解析
#   env_scope_version_cached / env_scope_mark_version
#                               版本解析结果缓存（导出给子进程，避免 build.sh → download_dependencies.sh 重复联网）
#
# 约束：被 source 的库，不修改调用方 shell 选项 / IFS / trap；
#       依赖 common_functions.sh 提供的 info 与 derive_*_build_ver。
# ==========================================

HG_ENV_LAYER_FILES=(
    base.env web.env php.env mysql.env postgres.env mongodb.env redis.env
    timescaledb.env pgvector.env clickhouse.env elk.env apps.env rabbitmq.env canal.env syncer.env
)

# 需要联网解析上游版本的组件（与 derive_*_build_ver 一一对应）
HG_VERSIONED_COMPONENTS=(mysql postgres mongo redis valkey elk)

# 用途：判断服务列表是否涉及某组件
# 参数：$1 组件名（mysql/postgres/mongo/redis/valkey/elk/php/web）；其余为 build.sh / up.sh 服务短名
# 返回：0 涉及（服务列表为空或含 all 时恒为 0）；1 不涉及
env_scope_has() {
    local want="$1"
    local svc comp
    shift
    (($# == 0)) && return 0
    for svc in "$@"; do
        case "$svc" in
            all) return 0 ;;
            mysql|mysql_backup) comp="mysql" ;;
            postgres|postgresql) comp="postgres" ;;
            mongo|mongodb) comp="mongo" ;;
            redis) comp="redis" ;;
            valkey) comp="valkey" ;;
            elk|elasticsearch|kibana|logstash) comp="elk" ;;
            php[0-9][0-9]|php[0-9][0-9]_apache|openssl) comp="php" ;;
            nginx|tengine) comp="web" ;;
            *) comp="" ;;
        esac
        [[ "$comp" == "$want" ]] && return 0
    done
    return 1
}

# 用途：输出服务列表需要加载的 env/*.env 文件名（每行一个，按 HG_ENV_LAYER_FILES 顺序）
# 参数：服务短名...；为空或含 all 时输出全部分层文件
# 返回：0
env_scope_env_files() {
    local f
    local -A need=([base.env]=1)

    if env_scope_has all "$@"; then
        printf '%s\n' "${HG_ENV_LAYER_FILES[@]}"
        return 0
    fi
    if env_scope_has mysql "$@"; then need[mysql.env]=1; fi
    if env_scope_has postgres "$@"; then need[postgres.env]=1; fi
    if env_scope_has mongo "$@"; then need[mongodb.env]=1; fi
    if env_scope_has redis "$@" || env_scope_has valkey "$@"; then need[redis.env]=1; fi
    if env_scope_has elk "$@"; then need[elk.env]=1; fi
    if env_scope_has php "$@"; then need[php.env]=1; fi
    if env_scope_has web "$@"; then need[web.env]=1; fi

    for f in "${HG_ENV_LAYER_FILES[@]}"; do
        if [[ -n "${need[$f]:-}" ]]; then
            printf '%s\n' "$f"
        fi
    done
}

# 用途：判断组件版本是否已按当前系列解析过（本进程或父进程导出），可直接复用
# 参数：$1 组件标记（MYSQL/PG/MONGO/REDIS/VALKEY/ELK）；$2 当前系列；$3 解析结果变量名
# 返回：0 可复用；1 需重新解析
env_scope_version_cached() {
    local marker="_HG_RESOLVED_${1}"
    [[ "${!marker:-}" == "$2" && -n "${!3:-}" ]]
}

# 用途：记录组件版本已按某系列解析完成，并导出给子进程
# 参数：$1 组件标记；$2 系列
env_scope_mark_version() {
    local marker="_HG_RESOLVED_${1}"
    printf -v "$marker" '%s' "$2"
    export "${marker?}"
}

# 内部：为未解析的组件导出空占位。Compose 侧这些变量仅作构建参数（${VAR:-} 插值），
# 显式置空可避免 .env.runtime 缺项与 "variable is not set" 告警。
_env_scope_export_version_placeholders() {
    export MYSQL_VER="${MYSQL_VER:-}"
    export MYSQL_PIN_POLICY="${MYSQL_PIN_POLICY:-latest}"
    export PG_VERSION="${PG_VERSION:-}"
    export PG_SOURCE_VERSION="${PG_SOURCE_VERSION:-}"
    export PG_PIN_POLICY="${PG_PIN_POLICY:-latest}"
    export MONGO_VERSION="${MONGO_VERSION:-}"
    export REDIS_VERSION="${REDIS_VERSION:-}"
    export VALKEY_VERSION="${VALKEY_VERSION:-}"
    export ELK_VERSION="${ELK_VERSION:-}"
    export TINI_VERSION="${TINI_VERSION:-v0.19.0}"
}

# 用途：只为目标服务涉及的组件联网解析上游版本，其余组件导出空占位
# 参数：服务短名...；为空或含 all 时全量解析
# 返回：0
env_scope_resolve_versions() {
    local comp joined
    local -a wanted=()

    for comp in "${HG_VERSIONED_COMPONENTS[@]}"; do
        if env_scope_has "$comp" "$@"; then
            wanted+=("$comp")
        fi
    done

    _env_scope_export_version_placeholders
    if ((${#wanted[@]} == 0)); then
        info "目标服务不涉及 MySQL/PostgreSQL/MongoDB/Redis/Valkey/ELK，跳过上游版本解析"
        return 0
    fi
    printf -v joined '%s ' "${wanted[@]}"
    info "按目标服务解析上游版本: ${joined% }"

    for comp in "${wanted[@]}"; do
        case "$comp" in
            mysql) derive_mysql_build_ver ;;
            postgres) derive_pg_build_ver ;;
            mongo) derive_mongo_build_ver ;;
            redis) derive_redis_build_ver ;;
            valkey) derive_valkey_build_ver ;;
            elk) derive_elk_build_ver ;;
        esac
    done
}

# 用途：不执行构建的入口跳过版本联网解析（up.sh 全部走 --no-build；缺镜像时调用的 build.sh 会自行解析）
# 参数：$1 可选说明文字
# 返回：0
env_scope_skip_versions() {
    _env_scope_export_version_placeholders
    info "${1:-当前操作不构建镜像}，跳过上游版本解析"
}
