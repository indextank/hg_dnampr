#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/common_functions.sh"

cd "$PROJECT_DIR"
load_project_environment_from_base_env "$PROJECT_DIR"

load_monitoring_env_file() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 0

    while IFS= read -r _line; do
        _line="${_line#$'\ufeff'}"
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$_line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$_line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]] || continue

        local _key _val
        _key="${_line%%=*}"
        _key="$(echo "$_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        _val="${_line#*=}"
        _val="$(echo "$_val" | sed 's/[[:space:]]*#.*$//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [[ "$_val" == '"'*'"' ]]; then
            _val="${_val:1:${#_val}-2}"
        elif [[ "$_val" == "'"*"'" ]]; then
            _val="${_val:1:${#_val}-2}"
        fi
        export "${_key}=${_val}"
    done < "$env_file"
}

for env_file in \
    env/base.env \
    env/mysql.env / env/postgres.env / env/mongodb.env \
    env/redis.env \
    env/rabbitmq.env \
    env/syncer.env; do
    load_monitoring_env_file "$env_file"
done

rules_dir="$PROJECT_DIR/build/monitoring/prometheus/rules"
targets_dir="$PROJECT_DIR/build/monitoring/prometheus/targets"
mkdir -p "$rules_dir" "$targets_dir"

rabbitmq_ready_threshold="${MONITORING_RABBITMQ_READY_THRESHOLD:-1000}"
rabbitmq_unacked_threshold="${MONITORING_RABBITMQ_UNACKED_THRESHOLD:-500}"
sync_lag_threshold="${MONITORING_SYNC_LAG_THRESHOLD:-1000}"
ack_window="${MONITORING_ACK_TIMEOUT_WINDOW:-5m}"

cat > "$rules_dir/project-alerts.yml" <<EOF_RULES
groups:
  - name: project-service-health
    interval: 30s
    rules:
      - alert: MonitoringTargetDown
        expr: up == 0
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Prometheus target is down: {{ \$labels.job }} / {{ \$labels.instance }}"
          description: "Prometheus has not been able to scrape {{ \$labels.job }} at {{ \$labels.instance }} for more than 2 minutes."

      - alert: ContainerMetricsStale
        expr: time() - container_last_seen{name!=""} > 300
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Container metrics disappeared: {{ \$labels.name }}"
          description: "cAdvisor has not seen container {{ \$labels.name }} recently. Check whether it exited or was recreated."

  - name: rabbitmq-core-alerts
    interval: 30s
    rules:
      - alert: RabbitMQAckTimeoutLogDetected
        expr: increase(promtail_custom_rabbitmq_ack_timeout_log_total[${ack_window}]) > 0
        for: 1m
        labels:
          severity: critical
          component: rabbitmq
        annotations:
          summary: "RabbitMQ ACK timeout log detected"
          description: "Promtail matched RabbitMQ ACK timeout related logs in the last ${ack_window}. Open Grafana Loki logs filtered by container=rabbitmq for details."

      - alert: RabbitMQQueueBacklogHigh
        expr: max(rabbitmq_queue_messages_ready) by (queue, vhost) > ${rabbitmq_ready_threshold}
        for: 5m
        labels:
          severity: warning
          component: rabbitmq
        annotations:
          summary: "RabbitMQ queue backlog is high: {{ \$labels.queue }}"
          description: "Queue {{ \$labels.vhost }}/{{ \$labels.queue }} has more than ${rabbitmq_ready_threshold} ready messages for 5 minutes."

      - alert: RabbitMQUnackedMessagesHigh
        expr: max(rabbitmq_queue_messages_unacked) by (queue, vhost) > ${rabbitmq_unacked_threshold}
        for: 5m
        labels:
          severity: warning
          component: rabbitmq
        annotations:
          summary: "RabbitMQ unacked messages are high: {{ \$labels.queue }}"
          description: "Queue {{ \$labels.vhost }}/{{ \$labels.queue }} has more than ${rabbitmq_unacked_threshold} unacknowledged messages for 5 minutes."

      - alert: MessageSyncLagHigh
        expr: max(syncer_sync_consumer_lag) by (queue) > ${sync_lag_threshold}
        for: 5m
        labels:
          severity: critical
          component: syncer
        annotations:
          summary: "Message sync lag is high: {{ \$labels.queue }}"
          description: "Syncer consumer lag for queue {{ \$labels.queue }} has been above ${sync_lag_threshold} for 5 minutes."
EOF_RULES

write_target_file() {
    local file_name="$1"
    local target="$2"
    local service_label="$3"
    local enabled="$4"

    if [[ "$enabled" == "true" ]]; then
        cat > "$targets_dir/$file_name" <<EOF_TARGET
- targets:
    - $target
  labels:
    service: $service_label
    stack: hg_dnmpr
EOF_TARGET
    else
        cat > "$targets_dir/$file_name" <<EOF_EMPTY_TARGET
- targets: []
  labels:
    service: $service_label
    stack: hg_dnmpr
EOF_EMPTY_TARGET
    fi
}

is_container_running() {
    local container_name="$1"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container_name"
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

write_target_file "syncer.yml" "syncer:8080" "go-mysql-sync-es" "$syncer_running"
write_target_file "mysql-exporter.yml" "syncer-mysql-exporter:9104" "mysql" "$mysql_running"
write_target_file "mongo-exporter.yml" "syncer-mongo-exporter:9216" "mongo" "$mongo_running"
write_target_file "postgres-exporter.yml" "syncer-postgres-exporter:9187" "postgres" "$postgres_running"
write_target_file "redis-exporter.yml" "syncer-redis-exporter:9121" "redis" "$redis_running"
write_target_file "valkey-exporter.yml" "syncer-valkey-exporter:9121" "valkey" "$valkey_running"
write_target_file "nginx-exporter.yml" "syncer-nginx-exporter:9113" "nginx" "$nginx_running"
write_target_file "tengine-exporter.yml" "syncer-tengine-exporter:9113" "tengine" "$tengine_running"
write_target_file "rabbitmq.yml" "rabbitmq:15692" "rabbitmq" "$rabbitmq_running"

blackbox_targets=()
if [[ "$syncer_running" == "true" ]]; then blackbox_targets+=("http://syncer:8080/health"); fi
if [[ "$nginx_running" == "true" ]]; then blackbox_targets+=("http://nginx/nginx_status"); fi
if [[ "$tengine_running" == "true" ]]; then blackbox_targets+=("http://tengine/nginx_status"); fi
blackbox_targets+=("http://syncer-prometheus:9090/-/ready")
blackbox_targets+=("http://syncer-grafana:3000/api/health")

{
    echo "- targets:"
    for target in "${blackbox_targets[@]}"; do
        echo "    - ${target}"
    done
    cat <<'EOF_TARGETS_LABELS'
  labels:
    probe: http_2xx
    stack: hg_dnmpr
EOF_TARGETS_LABELS
} > "$targets_dir/blackbox-http.yml"

success "监控配置已生成：Prometheus rules 与 blackbox targets"
