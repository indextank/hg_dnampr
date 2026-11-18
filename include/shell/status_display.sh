#!/bin/bash
# ==========================================
# status_display.sh — 环境检测 + MySQL备份 + 状态展示
# ==========================================
# 依赖：common_functions.sh, service_catalog.sh

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

is_elk_only_services() {
    local services=("$@")
    [[ ${#services[@]} -eq 0 ]] && return 1   # 空列表表示全部服务，不跳过
    for svc in "${services[@]}"; do
        case "$svc" in
            elk|elasticsearch|kibana|logstash) ;;
            monitoring|syncer-prometheus|syncer-grafana) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

_cr_has_image() {
    local img="$1"
    cr_cmd images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null \
        | grep -qE "^(localhost/)?${img}$"
}

# 是否存在 mysql_backup 相关容器（含 podman-compose 命名的 project_mysql_backup_1）
_cr_has_mysql_backup_container() {
    local _proj="${COMPOSE_PROJECT_NAME:-hg_dnmpr}"
    cr_cmd ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -qE "^(${_proj}_)?mysql_backup(_[0-9]+)?$|^mysql_backup$" \
        || return 1
    return 0
}

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
            # mysql_backup 复用 hg_dnmpr_mysql 镜像，fallback 也应指向同一镜像
            # 优先使用已配置的 MYSQL_BACKUP_IMAGE（来自 db_backup.env 或 build.sh 导出）
            local mysql_backup_image="${MYSQL_BACKUP_IMAGE:-hg_dnmpr_mysql:latest}"
            local mysql_version=""
            for service in "${services_ref[@]}"; do
                if [[ "$service" == "mysql" ]]; then
                    mysql_version="MySQL"
                    break
                fi
            done

            # 对于某些操作，需要检查mysql镜像是否存在
            if [[ "$operation" == "up" || "$operation" == "start" || "$operation" == "restart" ]]; then
                if _cr_has_image "$mysql_backup_image"; then
                    export MYSQL_BACKUP_IMAGE="$mysql_backup_image"
                    services_ref+=("mysql_backup")
                    info "检测到${mysql_version}服务，自动添加mysql_backup服务进行${operation}操作，使用镜像: $mysql_backup_image"
                fi
            else
                # down/stop/rm 等：仅当备份容器实际存在时才加入，避免 podman-compose 对不存在的容器报错
                if _cr_has_mysql_backup_container; then
                    export MYSQL_BACKUP_IMAGE="$mysql_backup_image"
                    services_ref+=("mysql_backup")
                    info "检测到${mysql_version}服务，自动添加mysql_backup服务进行${operation}操作，使用镜像: $mysql_backup_image"
                fi
            fi
        fi
    fi
}

# 列出当前项目容器的名称、IP 及状态
# 用法: show_container_status [服务名...]（不指定服务名时列出所有 hg_dnmpr* 项目容器）
show_container_status() {
    local filters=("$@")

    log "列出容器状态（名称 / IP / 状态）..."

    local ids
    ids=$(cr_cmd ps -a -q 2>/dev/null || true)
    if [[ -z "$ids" ]]; then
        warn "未发现任何容器"
        return 0
    fi

    # 一次性 inspect 所有容器；Health 不存在时兜底输出 none，避免模板空指针报错
    local _fmt='{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}'
    local rows
    # shellcheck disable=SC2086  # ids 需按空白拆分为多个参数
    rows=$(cr_cmd inspect --format "$_fmt" $ids 2>/dev/null || true)
    if [[ -z "$rows" ]]; then
        warn "无法获取容器详细信息"
        return 1
    fi

    # 服务别名展开：与容器名/compose 服务名对齐
    local _expanded_filters=()
    local _f
    for _f in "${filters[@]}"; do
        case "$_f" in
            all)      ;;  # 不过滤
            elk)      _expanded_filters+=(elasticsearch kibana logstash) ;;
            monitoring) _expanded_filters+=(prometheus grafana) ;;
            postgresql) _expanded_filters+=(postgres) ;;
            mongodb)  _expanded_filters+=(mongo) ;;
            *)        _expanded_filters+=("$_f") ;;
        esac
    done

    local -a out_rows=()
    local name state health ips project svc status_text
    while IFS='|' read -r name state health ips project svc; do
        [[ -z "$name" ]] && continue
        # 仅展示本项目容器（compose 项目名以 hg_dnmpr 开头）
        [[ "$project" == hg_dnmpr* ]] || continue
        name="${name#/}"

        # 服务名过滤（匹配容器名或 compose 服务名）
        if [[ ${#_expanded_filters[@]} -gt 0 ]]; then
            local _matched=false
            for _f in "${_expanded_filters[@]}"; do
                if [[ "$name" == *"$_f"* || "$svc" == *"$_f"* ]]; then
                    _matched=true
                    break
                fi
            done
            [[ "$_matched" == "true" ]] || continue
        fi

        # 状态文本：running 时附加健康检查状态
        status_text="$state"
        if [[ "$state" == "running" ]]; then
            case "$health" in
                healthy)   status_text="running (healthy)" ;;
                unhealthy) status_text="running (unhealthy)" ;;
                starting)  status_text="running (starting)" ;;
            esac
        fi

        ips="${ips% }"
        [[ -z "$ips" ]] && ips="-"
        out_rows+=("$name|$ips|$status_text")
    done <<< "$rows"

    if [[ ${#out_rows[@]} -eq 0 ]]; then
        warn "未发现匹配的容器"
        return 0
    fi

    # 按名称排序后计算列宽输出
    local sorted_rows
    sorted_rows=$(printf '%s\n' "${out_rows[@]}" | sort -t'|' -k1,1)

    local w_name=4 w_ip=2 w_status=4
    local _row _n _i _s
    while IFS='|' read -r _n _i _s; do
        (( ${#_n} > w_name )) && w_name=${#_n}
        (( ${#_i} > w_ip )) && w_ip=${#_i}
        (( ${#_s} > w_status )) && w_status=${#_s}
    done <<< "$sorted_rows"

    echo -e "\n${CYAN}=== 容器状态 ===${NC}"
    # 中文表头占 2 列但按字节计算，宽度 +2 补偿以保证与数据行对齐
    printf "%-12s  %-$((w_name + 2))s  %-${w_ip}s  %s\n" "序号" "名称" "IP" "状态"
    local idx=0
    while IFS='|' read -r _n _i _s; do
        idx=$((idx + 1))
        printf "%-10s  %-${w_name}s  %-${w_ip}s  %s\n" "$idx" "$_n" "$_i" "$_s"
    done <<< "$sorted_rows"
    echo ""
    info "共 ${#out_rows[@]} 个容器"
}

show_status() {
    local environment="$1"

    log "显示服务状态..."

    # 规范化环境名：development→dev，production→prod
    local env_short
    case "$environment" in
        dev|development)  env_short="dev" ;;
        prod|production)  env_short="prod" ;;
        *)                env_short="${environment}" ;;
    esac

    # 显示所有compose文件的状态
    local compose_files="-f compose/main.yaml -f docker-compose.${env_short}.yaml"

    # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
    # 注意：up.sh 通过 firewall-check.sh 将 IFS 设为 $'\n\t'（去掉了空格），
    # 导致 ${compose_cmd} 展开时无法把 “docker compose” 按空格拆分为两个词。
    # 解决方案：将命令转为数组，数组元素展开不受 IFS 影响。
    local compose_cmd_str
    compose_cmd_str=$(get_docker_compose_cmd) || compose_cmd_str="docker compose"
    # 将命令字符串按空格拆分为数组（临时恢复 IFS 使空格生效）
    local _ifs_save="$IFS"
    IFS=' ' read -ra _compose_cmd_arr <<< "$compose_cmd_str"
    IFS="$_ifs_save"

    echo -e "\n${CYAN}=== 主要服务状态 ===${NC}"
    bash -c "${compose_cmd_str} $compose_files ps" 2>/dev/null || warn "无法获取主要服务状态"

    # 检查ELK服务是否真的存在和运行
    echo -e "\n${CYAN}=== ELK服务状态 ===${NC}"
    if [[ -f "compose/stacks/elk.yaml" ]]; then
        # 检查ELK compose文件中定义的服务是否有在运行
        local elk_containers=$(cr_cmd ps --filter "label=com.docker.compose.project=hg_dnmpr_elk" --format "{{.Names}}" | grep -E "elasticsearch|kibana|logstash" 2>/dev/null || echo "")
        if [[ -n "$elk_containers" ]]; then
            "${_compose_cmd_arr[@]}" -f compose/stacks/elk.yaml ps 2>/dev/null || true
        else
            info "ELK服务未运行"
        fi
    else
        info "ELK配置文件不存在"
    fi

    # 检查SGR服务是否真的存在和运行
    echo -e "\n${CYAN}=== SGR服务状态 ===${NC}"
    if [[ -f "compose/stacks/sgr.yaml" ]]; then
        # 检查SGR compose文件中定义的服务是否有在运行
        local sgr_containers=$(cr_cmd ps --filter "label=com.docker.compose.project=hg_dnmpr_sgr" --format "{{.Names}}" | grep -E "spug|gitea|rap2" 2>/dev/null || echo "")
        if [[ -n "$sgr_containers" ]]; then
            "${_compose_cmd_arr[@]}" -f compose/stacks/sgr.yaml ps 2>/dev/null || true
        else
            info "SGR服务未运行"
        fi
    else
        info "SGR配置文件不存在"
    fi

    # 检查RabbitMQ服务是否真的存在和运行
    echo -e "\n${CYAN}=== RabbitMQ服务状态 ===${NC}"
    if [[ -f "compose/stacks/rabbitmq.yaml" ]]; then
        local rabbitmq_containers=$(cr_cmd ps --filter "label=com.docker.compose.project=hg_dnmpr_rabbitmq" --format "{{.Names}}" | grep -E "rabbitmq|canal-server" 2>/dev/null || echo "")
        if [[ -n "$rabbitmq_containers" ]]; then
            "${_compose_cmd_arr[@]}" -f compose/stacks/rabbitmq.yaml ps 2>/dev/null || true
        else
            info "RabbitMQ服务未运行"
        fi
    else
        info "RabbitMQ配置文件不存在"
    fi

    # 检查Syncer服务是否真的存在和运行
    echo -e "\n${CYAN}=== Syncer服务状态 ===${NC}"
    if [[ -f "compose/stacks/syncer.yaml" ]]; then
        local syncer_containers=$(cr_cmd ps --filter "label=com.docker.compose.project=hg_dnmpr_syncer" --format "{{.Names}}" | grep -E "^syncer$" 2>/dev/null || echo "")
        if [[ -n "$syncer_containers" ]]; then
            "${_compose_cmd_arr[@]}" -f compose/stacks/syncer.yaml ps 2>/dev/null || true
        else
            info "Syncer服务未运行"
        fi
    else
        info "Syncer配置文件不存在"
    fi

    echo -e "\n${CYAN}=== 系统资源使用情况 ===${NC}"
    # 获取容器统计信息，同时显示容器ID和名称
    # podman stats 使用 {{.ID}} 而非 docker 的 {{.Container}}
    local _stats_fmt
    if cr_is_podman; then
        _stats_fmt="table {{.ID}}\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
    else
        _stats_fmt="table {{.Container}}\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
    fi
    cr_cmd stats --no-stream --format "$_stats_fmt" 2>/dev/null || warn "无法获取资源使用情况"
}
