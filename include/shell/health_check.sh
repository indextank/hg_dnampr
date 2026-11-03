#!/usr/bin/env bash
# ==========================================
# 容器健康检查函数库
# ==========================================
# 用途：检测容器健康状态、等待服务就绪
# 依赖：
#   common_functions.sh（info/warn/error/success 函数）
#   container_runtime.sh（cr_cmd — 容器运行时命令）
# 全局变量（由调用方提供）：无特殊要求
# ==========================================

# 检查单个容器是否正常运行（Up 且不处于 Restarting / unhealthy 状态）
# 参数：容器名（精确匹配）
# 返回 0 = 正常运行可跳过；返回 1 = 未运行或异常需要启动
_is_container_healthy() {
    local name="$1"
    local status
    # docker ps --filter name 为子串匹配，用 ^name$ 精确锁定
    status=$(cr_cmd ps --filter "name=^${name}$" --format "{{.Status}}" 2>/dev/null | head -1)
    # 状态必须以 "Up" 开头，且不含 Restarting / (unhealthy)
    if [[ "$status" =~ ^Up ]] && \
       [[ ! "$status" =~ Restarting ]] && \
       [[ ! "$status" =~ \(unhealthy\) ]]; then
        return 0
    fi
    return 1
}


_health_target_for_compose_service() {
    case "$1" in
        mongo-backup) echo "mongo_backup" ;;
        postgres-backup)    echo "postgres_backup" ;;
        *)            echo "$1" ;;
    esac
}

# 检查某 compose project 下的所有容器是否全部正常运行
# 参数：compose project 名称（com.docker.compose.project label 值）
# 返回 0 = 全部正常可跳过；返回 1 = 有容器缺失/异常需要 up
_is_stack_all_healthy() {
    local project="$1"
    # 统计总容器数（含已退出）
    local total
    total=$(cr_cmd ps -a \
        --filter "label=com.docker.compose.project=${project}" \
        -q 2>/dev/null | wc -l | tr -d ' ')
    # 无容器记录 → 未部署，需要 up
    [[ "$total" -eq 0 ]] && return 1

    # 逐条检查每个容器状态
    local statuses
    statuses=$(cr_cmd ps -a \
        --filter "label=com.docker.compose.project=${project}" \
        --format "{{.Status}}" 2>/dev/null)
    while IFS= read -r _s; do
        [[ -z "$_s" ]] && continue
        # 任意一个容器不是 "Up..." 或含 Restarting / (unhealthy) → 需要 up
        if [[ ! "$_s" =~ ^Up ]] || \
           [[ "$_s" =~ Restarting ]] || \
           [[ "$_s" =~ \(unhealthy\) ]]; then
            return 1
        fi
    done <<< "$statuses"

    return 0
}

# 参数：environment（用于读取协议/端口/凭证配置）
# 行为：最多等待 ${ES_WAIT_TIMEOUT:-120} 秒，每 5 秒轮询一次；超时后给出警告但不阻断流程
wait_for_elasticsearch_ready() {
    local environment="${1:-dev}"

    # 标准化环境名
    local env_name="$environment"
    case "$env_name" in
        production|prod) env_name="prod" ;;
        development|dev) env_name="dev" ;;
        *) env_name="dev" ;;
    esac

    # 读取协议（ELASTICSEARCH_PROTOCOL 在 load_environment_variables 中已导出）
    # 宿主机探测端口：compose 将容器 9200 映射为 127.0.0.1:${ELASTICSEARCH_HOST_PORT:-9200}，
    # elk.env 中通常为 ELASTICSEARCH_HOST_PORT=9333。误用 9200 会导致本机无监听而一直超时。
    local protocol="${ELASTICSEARCH_PROTOCOL:-http}"
    local es_port="${ELASTICSEARCH_HOST_PORT:-${ELASTICSEARCH_PORT:-9200}}"
    local es_user="${ELASTIC_USERNAME:-elastic}"
    # compose 中 elastic 密码来自 KIBANA_ELASTICSEARCH_PASSWORD（写入容器 ELASTIC_PASSWORD），elk.env 通常不设 ELASTIC_PASSWORD
    local es_pass="${ELASTIC_PASSWORD:-${KIBANA_ELASTICSEARCH_PASSWORD:-}}"
    # 端口映射为 127.0.0.1:PORT；localhost 可能解析到 ::1 而无监听，导致 curl 一直失败
    local es_host="127.0.0.1"
    local health_url="${protocol}://${es_host}:${es_port}/_cluster/health"

    local max_wait="${ES_WAIT_TIMEOUT:-180}"
    local interval=5
    local waited=0

    info "⏳ 等待 Elasticsearch 就绪（最长 ${max_wait}s）: ${health_url}"

    # compose restart 返回后，ES 可能仍处恢复阶段：对 /_cluster/health 会短暂返回 HTTP 503。
    # curl -f 在 4xx/5xx 时丢弃 body 且退出非零，导致本函数拿不到 JSON、空转直到超时；up/start 则因 compose 等 Healthy 后再返回，不易触发。
    local es_cname="${ES_CONTAINER_NAME:-elasticsearch}"
    local hw=0
    local hs=""
    hs=$(cr_cmd inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$es_cname" 2>/dev/null || echo "missing")
    if [[ "$hs" != "missing" && "$hs" != "none" ]]; then
        info "⏳ 先等待容器 ${es_cname} 的 Docker health=healthy（最长 120s，restart 后尤其需要）..."
        while [[ $hw -lt 120 ]]; do
            hs=$(cr_cmd inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$es_cname" 2>/dev/null || echo "missing")
            if [[ "$hs" == "healthy" ]]; then
                success "✅ 容器 ${es_cname} health=healthy（${hw}s）"
                break
            fi
            sleep 2
            hw=$((hw + 2))
        done
        if [[ "$hs" != "healthy" ]]; then
            warn "容器 ${es_cname} 在 120s 内未达到 healthy（当前: ${hs}），继续用 HTTP(S) 探测 _cluster/health..."
        fi
    fi

    # 构建 curl 基础选项（勿用 -f：503 时仍可能有 JSON body，需解析 status）
    local curl_opts=(-sS --connect-timeout 3 --max-time 8)
    # HTTPS 场景：若存在 CA 证书则使用，否则跳过 TLS 校验（开发环境宽容）
    if [[ "$protocol" == "https" ]]; then
        # 使用绝对路径（PROJECT_DIR），避免工作目录不同导致相对路径失效
        # 证书路径跟随 ELK 版本（与 compose/stacks/elk.yaml 的 ELASTICSEARCH_CONF_DIR 同源）
        local ca_file="${PROJECT_DIR:-$(pwd)}/build/elk/${ELK_BUILD_VERSION:-9.5}/elasticsearch/config/certs/ca/ca.crt"
        if [[ -f "$ca_file" ]]; then
            curl_opts+=(--cacert "$ca_file")
        else
            # CA 不存在时跳过验证（开发环境 / 证书尚未生成时）
            curl_opts+=(-k)
        fi
    fi
    # 凭证
    if [[ -n "$es_pass" ]]; then
        curl_opts+=(-u "${es_user}:${es_pass}")
    fi

    while [[ $waited -lt $max_wait ]]; do
        local response
        response=$(curl "${curl_opts[@]}" "$health_url" 2>/dev/null || true)
        if [[ -n "$response" ]]; then
            local status
            status=$(echo "$response" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
            case "$status" in
                green|yellow)
                    success "✅ Elasticsearch 已就绪（status=${status}，耗时 ${waited}s）"
                    return 0
                    ;;
                red)
                    # 集群 red 状态：已可通信，但数据分片未完全分配；继续等待但打印警告
                    info "Elasticsearch 响应但状态为 red（耗时 ${waited}s），继续等待..."
                    ;;
                *)
                    # 响应但无法解析 status，可能是启动中
                    info "Elasticsearch 响应中（状态未知），继续等待... (${waited}s)"
                    ;;
            esac
        fi
        sleep "$interval"
        waited=$((waited + interval))
        info "  仍在等待 Elasticsearch... (${waited}s/${max_wait}s)"
    done

    warn "⚠️  等待 Elasticsearch 超时（${max_wait}s），将继续启动 syncer，但可能因 ES 未就绪而连接失败"
    warn "    如需延长等待时间，可设置环境变量: ES_WAIT_TIMEOUT=180"
    return 0  # 超时不阻断流程，让 syncer 自行重试
}

# 参数：可选超时时间秒，默认 120
wait_for_rabbitmq_ready() {
    local max_wait="${1:-120}"
    local interval=3
    local waited=0
    local cname="rabbitmq"

    info "⏳ 等待 RabbitMQ 就绪（最长 ${max_wait}s）..."
    while [[ $waited -lt $max_wait ]]; do
        local running
        running="$(cr_cmd inspect -f '{{.State.Running}}' "${cname}" 2>/dev/null || echo false)"
        if [[ "${running}" == "true" ]]; then
            local health
            health="$(cr_cmd inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cname}" 2>/dev/null || echo none)"
            if [[ "${health}" == "healthy" || "${health}" == "none" ]]; then
                success "✅ RabbitMQ 已就绪（耗时 ${waited}s，health=${health}）"
                return 0
            fi
        fi
        sleep "${interval}"
        waited=$((waited + interval))
        info "  仍在等待 RabbitMQ... (${waited}s/${max_wait}s)"
    done

    warn "⚠️  等待 RabbitMQ 超时（${max_wait}s），继续后续流程，syncer 可能启动失败"
    return 0
}
