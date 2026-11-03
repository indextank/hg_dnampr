#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/common_functions.sh"

cd "$PROJECT_DIR"
load_project_environment_from_base_env "$PROJECT_DIR"
export_monitoring_publish_host_from_base_env "$PROJECT_DIR"

compose_cmd="$(get_docker_compose_cmd)"
base_url="http://127.0.0.1"
prom_url="${base_url}:9090"
grafana_url="${base_url}:3000"
loki_url="http://syncer-loki:3100"

log "检查 monitoring compose 配置..."
$compose_cmd -f compose/stacks/monitoring.yaml config >/dev/null
success "Compose 配置校验通过"

log "根据当前运行容器刷新 monitoring targets 配置..."
bash "$PROJECT_DIR/include/shell/generate-monitoring-config.sh" >/dev/null

log "检查 monitoring 容器状态..."
$compose_cmd -f compose/stacks/monitoring.yaml ps

is_container_running() {
    local container_name="$1"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container_name"
}

check_job_target_state() {
    local prom_url="$1"
    local job_name="$2"
    local expected_present="$3"
    local targets_payload
    targets_payload="$(curl -fsS "${prom_url}/api/v1/targets?state=active")"
    local target_stats
    target_stats="$(
        python3 - "$job_name" "$targets_payload" <<'PY'
import json
import sys

job = sys.argv[1]
payload = json.loads(sys.argv[2])
targets = payload.get("data", {}).get("activeTargets", [])
matched = [t for t in targets if t.get("labels", {}).get("job") == job]
down = [t for t in matched if t.get("health") != "up"]
print(f"{len(matched)} {len(down)}")
PY
    )"
    local total_count down_count
    total_count="$(echo "$target_stats" | awk '{print $1}')"
    down_count="$(echo "$target_stats" | awk '{print $2}')"

    if [[ "$expected_present" == "true" ]]; then
        if [[ "${total_count:-0}" -eq 0 ]]; then
            error "预期 job=${job_name} 存在，但 Prometheus 未查询到该 target"
        fi
        if [[ "${down_count:-0}" -gt 0 ]]; then
            warn "job=${job_name} 存在 down target，请检查 ${prom_url}/targets"
        else
            success "job=${job_name} target 正常"
        fi
    else
        if [[ "${total_count:-0}" -eq 0 ]]; then
            success "job=${job_name} 未启用（符合当前运行容器状态）"
        elif [[ "${down_count:-0}" -eq "${total_count:-0}" ]]; then
            success "job=${job_name} 未运行且仅存在 down 目标（视为可接受）"
        else
            warn "job=${job_name} 当前有 target，建议确认是否需要运行该 exporter"
        fi
    fi
}

syncer_running="false"
mysql_running="false"
mongo_running="false"
postgres_running="false"
redis_running="false"
valkey_running="false"
nginx_running="false"
tengine_running="false"
rabbitmq_running="false"

if is_container_running "syncer"; then syncer_running="true"; fi
if is_container_running "mysql"; then mysql_running="true"; fi
if is_container_running "mongo"; then mongo_running="true"; fi
if is_container_running "postgres"; then postgres_running="true"; fi
if is_container_running "redis"; then redis_running="true"; fi
if is_container_running "valkey"; then valkey_running="true"; fi
if is_container_running "nginx"; then nginx_running="true"; fi
if is_container_running "tengine"; then tengine_running="true"; fi
if is_container_running "rabbitmq"; then rabbitmq_running="true"; fi

log "检查 Prometheus ready 状态..."
if curl -fsS "${prom_url}/-/ready" >/dev/null; then
    success "Prometheus ready"
else
    error "Prometheus 未就绪，请检查 ./up.sh monitoring logs"
fi

log "触发 Prometheus 热重载..."
curl -fsS -X POST "${prom_url}/-/reload" >/dev/null || warn "Prometheus reload 失败，继续使用自动刷新机制检查"
sleep 2

log "检查 Prometheus targets..."
targets_json="$(curl -fsS "${prom_url}/api/v1/targets?state=active")"
if echo "$targets_json" | grep -q '"health":"down"'; then
    info "检测到 down target（可能包含已禁用 exporter 的历史目标），将结合运行容器做细分校验"
else
    success "当前 active targets 未发现 down 状态"
fi

log "检查业务 exporter targets 与运行容器是否一致..."
check_job_target_state "$prom_url" "syncer" "$syncer_running"
check_job_target_state "$prom_url" "mysql-exporter" "$mysql_running"
check_job_target_state "$prom_url" "mongo-exporter" "$mongo_running"
check_job_target_state "$prom_url" "postgres-exporter" "$postgres_running"
check_job_target_state "$prom_url" "redis-exporter" "$redis_running"
check_job_target_state "$prom_url" "valkey-exporter" "$valkey_running"
check_job_target_state "$prom_url" "nginx-exporter" "$nginx_running"
check_job_target_state "$prom_url" "tengine-exporter" "$tengine_running"
check_job_target_state "$prom_url" "rabbitmq" "$rabbitmq_running"

log "检查 Prometheus 规则加载..."
rules_json="$(curl -fsS "${prom_url}/api/v1/rules")"
if echo "$rules_json" | grep -q 'RabbitMQQueueBacklogHigh'; then
    success "Prometheus 告警规则已加载"
else
    error "未检测到 RabbitMQ 告警规则"
fi

log "检查 Grafana 数据源 API..."
if curl -fsS "${grafana_url}/api/health" >/dev/null; then
    success "Grafana API 可访问"
else
    error "Grafana API 不可访问"
fi

log "检查 Loki 容器内 ready 状态..."
if docker exec syncer-loki wget -q --spider http://localhost:3100/ready; then
    success "Loki ready"
else
    warn "Loki ready 检查失败，请查看 ./up.sh monitoring logs"
fi

log "检查 Promtail 指标是否可被 Prometheus 抓取..."
if curl -fsS "${prom_url}/api/v1/query?query=up%7Bjob%3D%22promtail%22%7D" | grep -q '"value"'; then
    success "Promtail target 已被 Prometheus 查询到"
else
    warn "Promtail target 暂未返回查询结果"
fi

cat <<EOF

监控访问入口:
  Prometheus: ${prom_url}
  Grafana:    ${grafana_url}

Loki 查询示例（Grafana Explore）:
  {container="rabbitmq"} |~ "(?i)(ack.{0,80}(timeout|timed out)|timeout.{0,80}ack|consumer.{0,80}ack)"

EOF

success "Monitoring 验证流程完成"
