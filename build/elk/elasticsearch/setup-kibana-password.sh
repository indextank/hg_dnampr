#!/bin/bash
# ==========================================
# Elasticsearch Kibana 用户密码设置脚本
# ==========================================
# 功能：在 Elasticsearch 启动后，设置 kibana_system 用户的密码
# 使用方法：在 docker-entrypoint.sh 中调用此脚本

set -e

# 等待 Elasticsearch 启动
wait_for_elasticsearch() {
    local max_attempts=120
    local attempt=0
    
    echo "[setup-kibana-password] 等待 Elasticsearch 启动..."
    while [ $attempt -lt $max_attempts ]; do
        # 检查是否启用了安全功能
        if [ "${ELK_SECURITY_ENABLED:-false}" = "true" ]; then
            # 使用认证
            if curl -s -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9200/_cluster/health" > /dev/null 2>&1; then
                echo "[setup-kibana-password] Elasticsearch 已启动（安全模式）"
                return 0
            fi
        else
            # 不使用认证
            if curl -s "http://localhost:9200/_cluster/health" > /dev/null 2>&1; then
                echo "[setup-kibana-password] Elasticsearch 已启动（非安全模式）"
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    
    echo "[setup-kibana-password] 警告: Elasticsearch 未能在预期时间内启动"
    return 1
}

# 设置 kibana_system 用户密码
set_kibana_password() {
    local kibana_password="${KIBANA_ELASTICSEARCH_PASSWORD:-${ELASTIC_PASSWORD}}"
    
    if [ -z "$kibana_password" ]; then
        echo "[setup-kibana-password] 警告: KIBANA_ELASTICSEARCH_PASSWORD 未设置，跳过 kibana_system 用户密码设置"
        return 0
    fi
    
    if [ -z "$ELASTIC_PASSWORD" ]; then
        echo "[setup-kibana-password] 警告: ELASTIC_PASSWORD 未设置，无法设置 kibana_system 用户密码"
        return 0
    fi
    
    echo "[setup-kibana-password] 设置 kibana_system 用户密码..."
    
    # 使用 Elasticsearch 的 API 设置密码
    local response=$(curl -s -X POST \
        -u "elastic:${ELASTIC_PASSWORD}" \
        "http://localhost:9200/_security/user/kibana_system/_password" \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"${kibana_password}\"}" 2>&1)
    
    if echo "$response" | grep -q '"error"'; then
        echo "[setup-kibana-password] 警告: 设置 kibana_system 用户密码失败: $response"
        # 如果是因为用户已存在，尝试更新密码
        if echo "$response" | grep -q "already exists"; then
            echo "[setup-kibana-password] 尝试更新现有用户的密码..."
            response=$(curl -s -X POST \
                -u "elastic:${ELASTIC_PASSWORD}" \
                "http://localhost:9200/_security/user/kibana_system/_password" \
                -H "Content-Type: application/json" \
                -d "{\"password\":\"${kibana_password}\"}" 2>&1)
            if ! echo "$response" | grep -q '"error"'; then
                echo "[setup-kibana-password] 成功: kibana_system 用户密码已更新"
                return 0
            fi
        fi
        return 1
    else
        echo "[setup-kibana-password] 成功: kibana_system 用户密码已设置"
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
    
    # 等待一段时间，确保 Elasticsearch 完全启动
    sleep 5
    
    # 设置 kibana_system 用户密码
    set_kibana_password
}

# 在后台运行（不阻塞 Elasticsearch 启动）
main &

