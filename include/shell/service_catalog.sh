#!/usr/bin/env bash
# ==========================================
# hg_dnmpr 服务目录（单一数据源 Adapter）
# ==========================================
# 职责：集中维护“服务清单”这一事实，并派生出所有与服务名相关的查询：
#   - map_service_name              短名 → compose 服务键名
#   - unmap_service_name_for_build  compose 服务键名 → build.sh 参数
#   - get_special_services          组合短名 → 真实子服务列表（build/run 两种模式）
#   - get_compose_files             环境 + 服务 → compose -f 参数串
#   - get_compose_project_for_service  服务 → 所属 compose project 名
#
# 设计约束（最佳实践）：
#   - 本文件是被 source 的“库”，禁止修改调用方的 shell 选项 / IFS / trap。
#   - 单一 PHP 版本列表 HG_PHP_APACHE_VERSIONS 是新增/下线 PHP 版本的唯一改动点。
#
# 使用方式：
#   source include/shell/service_catalog.sh
#   map_service_name php84            # → php84_apache
#   get_special_services elk          # → elasticsearch kibana logstash
#   get_special_services all build    # → 主栈可构建服务列表
# ==========================================

# --- 单一事实：带 Apache 容器后缀的 PHP 版本（新增版本只改这里） ---
# 顺序用于 build 的 "all" 展开展示顺序。
HG_PHP_APACHE_VERSIONS=(85 84 83 82 81 80 74 72)

# 内部：判断短名是否为带 Apache 后缀的 PHP 服务
_is_php_apache_short() {
    local v
    for v in "${HG_PHP_APACHE_VERSIONS[@]}"; do
        [[ "$1" == "php${v}" ]] && return 0
    done
    return 1
}

# 短名 → compose 服务键名
map_service_name() {
    local service="$1"
    if _is_php_apache_short "$service"; then
        echo "${service}_apache"
        return 0
    fi
    case "$service" in
        # ELK 子服务名无需重映射，直接透传
        elasticsearch|kibana|logstash) echo "$service" ;;
        nginx) echo "nginx" ;;
        tengine) echo "tengine" ;;
        mysql) echo "mysql" ;;
        mysql_backup) echo "mysql_backup" ;;
        redis) echo "redis" ;;
        valkey) echo "valkey" ;;
        mongo|mongodb) echo "mongo" ;;
        postgres|postgresql) echo "postgres" ;;
        pgadmin) echo "pgadmin" ;;
        timescaledb) echo "timescaledb" ;;
        timescaledb_backup) echo "timescaledb_backup" ;;
        pgvector) echo "pgvector" ;;
        pgvector_backup) echo "pgvector_backup" ;;
        clickhouse) echo "clickhouse" ;;
        clickhouse_backup) echo "clickhouse_backup" ;;
        rabbitmq) echo "rabbitmq" ;;
        canal|canal-server) echo "canal-server" ;;
        syncer) echo "syncer" ;;
        monitoring) echo "monitoring" ;;
        *) echo "$service" ;;
    esac
}

# compose 服务键名 → build.sh 参数
unmap_service_name_for_build() {
    local service="$1"
    local v
    for v in "${HG_PHP_APACHE_VERSIONS[@]}"; do
        if [[ "$service" == "php${v}_apache" ]]; then
            echo "php${v}"
            return 0
        fi
    done
    case "$service" in
        canal-server) echo "canal" ;;
        elasticsearch|kibana|logstash) echo "elk" ;;
        *) echo "$service" ;;
    esac
}

# build 模式下 "all" 展开出的主栈可构建服务列表（单一来源）
list_buildable_all_services() {
    local out=()
    out+=(nginx)
    local v
    for v in "${HG_PHP_APACHE_VERSIONS[@]}"; do
        out+=("php${v}_apache")
    done
    # mysql_backup 无独立 build（复用 hg_dnmpr_mysql），不可列入可构建列表，
    # 否则 bake 后端会报 failed to find target mysql_backup
    out+=(mysql redis valkey)
    # 时序/向量/列存数据库（pgvector/clickhouse 自建镜像需构建；timescaledb 用官方镜像无需构建）
    out+=(pgvector clickhouse)
    echo "${out[*]}"
}

# 组合短名 → 真实子服务列表
# 用法: get_special_services <service> [mode]
#   mode=run（默认）：用于启动/编排，反映“当前应运行什么”
#   mode=build       ：用于构建，反映“应构建出哪些镜像”
get_special_services() {
    local service="$1"
    local mode="${2:-run}"
    case "$service" in
        elk)
            echo "elasticsearch kibana logstash"
            ;;
        elasticsearch|kibana|logstash)
            echo "$service"
            ;;
        sgr)
            # sgr 组合栈对应 compose/stacks/sgr.yaml 中的真实服务名
            echo "spug gitea rap2-dolores rap2-delos"
            ;;
        syncer)
            echo "syncer"
            ;;
        canal|canal-server)
            echo "canal-server"
            ;;
        monitoring)
            if [[ "$mode" == "build" ]]; then
                # 构建/拉取阶段：覆盖全部 exporter，无法依赖运行中容器判断
                echo "alertmanager loki promtail cadvisor node-exporter blackbox-exporter mysql-exporter mongo-exporter postgres-exporter redis-exporter valkey-exporter nginx-exporter tengine-exporter timescaledb-exporter pgvector-exporter clickhouse-exporter prometheus grafana"
            else
                # 运行阶段：仅为正在运行的业务容器启用对应 exporter，避免无效监控目标
                local monitoring_services=(
                    alertmanager loki promtail cadvisor node-exporter blackbox-exporter prometheus grafana
                )
                local _name
                for _name in mysql mongo postgres redis valkey nginx tengine; do
                    if cr_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "$_name"; then
                        monitoring_services+=("${_name}-exporter")
                    fi
                done
                # ClickHouse 内置 Prometheus 端点，对应 exporter 服务名为 clickhouse-exporter（占位容器）
                if cr_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "timescaledb"; then
                    monitoring_services+=("timescaledb-exporter")
                fi
                if cr_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "pgvector"; then
                    monitoring_services+=("pgvector-exporter")
                fi
                if cr_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "clickhouse"; then
                    monitoring_services+=("clickhouse-exporter")
                fi
                echo "${monitoring_services[*]}"
            fi
            ;;
        all)
            if [[ "$mode" == "build" ]]; then
                list_buildable_all_services
            else
                # 运行阶段：空表示“所有已部署服务”
                echo ""
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

# 服务 → 所属 Docker Compose 项目名（用于按 project 识别独立栈镜像）
# 项目名来源（各 compose 文件顶部 name 字段）：
#   hg_dnmpr        ← compose/main.yaml（主服务：nginx/php*/mysql/redis/...）
#   hg_dnmpr_elk    ← compose/stacks/elk.yaml
#   hg_dnmpr_sgr    ← compose/stacks/sgr.yaml
#   hg_dnmpr_syncer ← compose/stacks/syncer.yaml
#   hg_dnmpr_ttrss  ← compose/stacks/ttrss.yaml
#   hg_dnmpr_monitoring ← compose/stacks/monitoring.yaml
#   hg_dnmpr_rabbitmq   ← compose/stacks/rabbitmq.yaml
get_compose_project_for_service() {
    local service="$1"
    case "$service" in
        elasticsearch|kibana|logstash)
            echo "hg_dnmpr_elk" ;;
        spug|gitea|rap2-dolores|rap2-delos)
            echo "hg_dnmpr_sgr" ;;
        ttrss|mercury|opencc|watchtower|rsshub)
            echo "hg_dnmpr_ttrss" ;;
        rabbitmq|canal|canal-server)
            echo "hg_dnmpr_rabbitmq" ;;
        syncer)
            echo "hg_dnmpr_syncer" ;;
        syncer-prometheus|syncer-grafana|prometheus|grafana)
            echo "hg_dnmpr_monitoring" ;;
        *)
            echo "hg_dnmpr" ;;
    esac
}

# 环境 + 服务 → compose -f 参数串
# 用法: get_compose_files <environment> [services...] [--silent]
#   --silent: 静默模式，不输出 WSL 检测信息
get_compose_files() {
    local environment="$1"
    local services=()
    local silent=false
    local base_files=""
    local wsl_file=""

    shift || true
    for arg in "$@"; do
        if [[ "$arg" == "--silent" ]]; then
            silent=true
        else
            services+=("$arg")
        fi
    done

    # 独立栈（compose/stacks/*.yaml）只用各自的 compose 文件
    local service
    for service in "${services[@]}"; do
        case "$service" in
            elk)
                echo "-f compose/stacks/elk.yaml"; return ;;
            sgr|spug|gitea|rap2-dolores|rap2-delos)
                echo "-f compose/stacks/sgr.yaml"; return ;;
            rabbitmq|canal|canal-server)
                echo "-f compose/stacks/rabbitmq.yaml"; return ;;
            syncer)
                echo "-f compose/stacks/syncer.yaml"; return ;;
            monitoring)
                echo "-f compose/stacks/monitoring.yaml"; return ;;
        esac
    done

    # 主栈是否含 MySQL（用于决定是否叠加 WSL overlay）
    local has_mysql=false
    for service in "${services[@]}"; do
        case "$service" in
            mysql|mysql_backup) has_mysql=true; break ;;
        esac
    done

    # MySQL + WSL 环境：叠加 WSL 优化 overlay（is_wsl_environment 由 status_display.sh 提供，构建上下文可能未定义）
    if [[ "$has_mysql" == "true" ]] && declare -F is_wsl_environment >/dev/null 2>&1 && is_wsl_environment; then
        if [[ -f "compose/overlays/wsl.yaml" ]]; then
            wsl_file="-f compose/overlays/wsl.yaml"
            if [[ "$silent" == "false" ]] && declare -F info >/dev/null 2>&1; then
                info "检测到WSL环境，将使用WSL优化的MySQL配置" >&2
            fi
        fi
    fi

    # 主栈：compose/main.yaml + 环境 overlay
    case "$environment" in
        prod|production)
            base_files="-f compose/main.yaml -f compose/overlays/prod.yaml" ;;
        *)
            base_files="-f compose/main.yaml -f compose/overlays/dev.yaml" ;;
    esac

    # Docker 专属网络 opt（Podman 不支持 com.docker.network.*）
    local docker_opts_file=""
    if cr_is_docker && [[ -f "compose/overlays/docker-opts.yaml" ]]; then
        docker_opts_file="-f compose/overlays/docker-opts.yaml"
    fi

    local result="$base_files"
    [[ -n "$docker_opts_file" ]] && result="$result $docker_opts_file"
    [[ -n "$wsl_file" ]] && result="$result $wsl_file"
    echo "$result"
}
