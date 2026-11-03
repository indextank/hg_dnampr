#!/bin/bash
# ==========================================
# Elasticsearch Kibana 用户密码设置脚本
# ==========================================
# 功能：在 Elasticsearch 启动后，设置 kibana_system 用户的密码
# 使用方法：在 docker-entrypoint.sh 中调用此脚本

set -e

# 根据 ELK_HTTP_SSL_ENABLED 返回协议前缀和 curl TLS 参数
# 用法：read -r _proto _curl_tls <<< "$(es_connection_params)"
es_connection_params() {
    if [ "${ELK_HTTP_SSL_ENABLED:-false}" = "true" ]; then
        echo "https -k"
    else
        echo "http"
    fi
}

# 等待 Elasticsearch 启动
wait_for_elasticsearch() {
    local max_attempts=120
    local attempt=0
    local _proto _curl_tls
    read -r _proto _curl_tls <<< "$(es_connection_params)"

    echo "[setup-kibana-password] 等待 Elasticsearch 启动... (协议: ${_proto})"
    while [ $attempt -lt $max_attempts ]; do
        # 检查是否启用了安全功能
        if [ "${ELK_SECURITY_ENABLED:-false}" = "true" ]; then
            # 使用认证
            if curl -s ${_curl_tls} -u "elastic:${ELASTIC_PASSWORD}" "${_proto}://localhost:9200/_cluster/health" > /dev/null 2>&1; then
                echo "[setup-kibana-password] Elasticsearch 已启动（安全模式, ${_proto}）"
                return 0
            fi
        else
            # 不使用认证
            if curl -s ${_curl_tls} "${_proto}://localhost:9200/_cluster/health" > /dev/null 2>&1; then
                echo "[setup-kibana-password] Elasticsearch 已启动（非安全模式, ${_proto}）"
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    echo "[setup-kibana-password] 警告: Elasticsearch 未能在预期时间内启动"
    return 1
}

# 等待 .security-7 索引主分片就绪
# 背景：ES 启动后 _cluster/health 可达，但 .security-7 主分片可能仍在分配中。
# 若此时发起安全 API 请求，ES 会报 UnavailableShardsException 并输出 ERROR 日志。
# 此函数轮询 _cluster/health?wait_for_status=yellow&timeout=5s 直到集群至少 yellow，
# 再额外等待 .security-7 分片活跃，从而消除启动期间的误报 ERROR。
wait_for_security_index() {
    local max_attempts=60
    local attempt=0
    local _proto _curl_tls
    read -r _proto _curl_tls <<< "$(es_connection_params)"
    local _auth=""
    [ "${ELK_SECURITY_ENABLED:-false}" = "true" ] && _auth="-u elastic:${ELASTIC_PASSWORD}"

    echo "[setup-kibana-password] 等待 .security-7 分片就绪..."
    while [ $attempt -lt $max_attempts ]; do
        # 使用 wait_for_status=yellow 等待集群至少变黄（所有主分片已分配）
        local _status
        _status=$(curl -s ${_curl_tls} ${_auth} \
            "${_proto}://localhost:9200/_cluster/health/.security-7?wait_for_status=yellow&timeout=3s" \
            2>/dev/null | grep -o '"status":"[^"]*"' | head -1 || true)
        if echo "${_status}" | grep -qE '"status":"(green|yellow)"'; then
            echo "[setup-kibana-password] .security-7 分片已就绪 (${_status})"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 3
    done

    echo "[setup-kibana-password] 警告: .security-7 分片未能在预期时间内就绪，尝试继续执行"
    return 0
}

# 设置 kibana_system 用户密码
set_kibana_password() {
    local kibana_password="${KIBANA_ELASTICSEARCH_PASSWORD:-${ELASTIC_PASSWORD}}"
    local _proto _curl_tls
    read -r _proto _curl_tls <<< "$(es_connection_params)"

    if [ -z "$kibana_password" ]; then
        echo "[setup-kibana-password] 警告: KIBANA_ELASTICSEARCH_PASSWORD 未设置，跳过 kibana_system 用户密码设置"
        return 0
    fi

    if [ -z "$ELASTIC_PASSWORD" ]; then
        echo "[setup-kibana-password] 警告: ELASTIC_PASSWORD 未设置，无法设置 kibana_system 用户密码"
        return 0
    fi

    echo "[setup-kibana-password] 设置 kibana_system 用户密码 (${_proto})..."

    # 使用 Elasticsearch 的 API 设置密码
    local response=$(curl -s ${_curl_tls} -X POST \
        -u "elastic:${ELASTIC_PASSWORD}" \
        "${_proto}://localhost:9200/_security/user/kibana_system/_password" \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"${kibana_password}\"}" 2>&1)

    if echo "$response" | grep -q '"error"'; then
        echo "[setup-kibana-password] 警告: 设置 kibana_system 用户密码失败: $response"
        # 如果是因为用户已存在，尝试更新密码
        if echo "$response" | grep -q "already exists"; then
            echo "[setup-kibana-password] 尝试更新现有用户的密码..."
            response=$(curl -s ${_curl_tls} -X POST \
                -u "elastic:${ELASTIC_PASSWORD}" \
                "${_proto}://localhost:9200/_security/user/kibana_system/_password" \
                -H "Content-Type: application/json" \
                -d "{\"password\":\"${kibana_password}\"}" 2>&1)
            if ! echo "$response" | grep -q '"error"'; then
                echo "[setup-kibana-password] 成功: kibana_system 用户密码已更新"
                return 0
            fi
        fi
        return 1
    else
        echo "[setup-kibana-password] 成功: kibana_system 用户密码已设置 (${_proto})"
        return 0
    fi
}

# 主函数
main() {
    # 检查是否启用了安全功能
    if [ "${ELK_SECURITY_ENABLED:-false}" != "true" ]; then
        echo "[setup-kibana-password] 安全功能未启用，跳过 kibana_system 用户密码设置"
        return 0
    fi

    # 等待 Elasticsearch 启动
    if ! wait_for_elasticsearch; then
        echo "[setup-kibana-password] 警告: 无法连接到 Elasticsearch，跳过 kibana_system 用户密码设置"
        return 0
    fi

    # 等待 .security-7 索引主分片就绪，避免 UnavailableShardsException ERROR 日志
    wait_for_security_index

    # 设置 kibana_system 用户密码
    set_kibana_password
}

# 在后台运行（不阻塞 Elasticsearch 启动）
main &
