#!/bin/bash

# ==========================================
# Docker Daemon 代理配置脚本
# ==========================================
# 功能：配置 Docker daemon 使用系统代理
# 使用方法：sudo ./scripts/configure-docker-proxy.sh

set -euo pipefail

DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
DOCKER_SERVICE_DIR="/etc/systemd/system/docker.service.d"
PROXY_CONF_FILE="$DOCKER_SERVICE_DIR/http-proxy.conf"

# 检测 WSL 环境并获取代理地址
detect_proxy() {
    local proxy_host=""
    local proxy_port=""
    
    # 检测 WSL 环境
    if [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ "$(uname -r)" =~ microsoft|WSL ]]; then
        # WSL 环境，使用 Windows 主机的代理
        # 通常 WSL 中可以通过 172.21.128.1 访问 Windows 主机
        proxy_host="172.21.128.1"
        
        # 尝试检测代理端口（常见端口：7890, 10809, 10808, 60066）
        for port in 56608 7890 10809 10808 60066 1080 8080; do
            if timeout 2 curl -s -o /dev/null "http://${proxy_host}:${port}" 2>/dev/null; then
                proxy_port="$port"
                break
            fi
        done
        
        if [[ -z "$proxy_port" ]]; then
            echo "⚠️  无法自动检测代理端口，请手动指定"
            read -p "请输入代理端口（默认 7890）: " proxy_port
            proxy_port="${proxy_port:-7890}"
        fi
        
        echo "http://${proxy_host}:${proxy_port}"
    else
        # 普通 Linux 环境，尝试从环境变量获取
        if [[ -n "${HTTP_PROXY:-}" ]]; then
            echo "$HTTP_PROXY"
        elif [[ -n "${http_proxy:-}" ]]; then
            echo "$http_proxy"
        else
            echo ""
        fi
    fi
}

# 配置 Docker daemon 代理（通过 systemd）
configure_docker_daemon_proxy() {
    local proxy_url="$1"
    
    if [[ -z "$proxy_url" ]]; then
        echo "❌ 未提供代理地址"
        return 1
    fi
    
    echo "📝 配置 Docker daemon 使用代理: $proxy_url"
    
    # 创建 systemd 服务目录
    sudo mkdir -p "$DOCKER_SERVICE_DIR"
    
    # 创建代理配置文件
    sudo tee "$PROXY_CONF_FILE" > /dev/null <<EOF
[Service]
Environment="HTTP_PROXY=$proxy_url"
Environment="HTTPS_PROXY=$proxy_url"
Environment="NO_PROXY=localhost,127.0.0.1,172.17.0.0/16,host.docker.internal"
EOF
    
    echo "✅ 代理配置文件已创建: $PROXY_CONF_FILE"
    
    # 重新加载 systemd 配置
    sudo systemctl daemon-reload
    
    # 重启 Docker 服务
    echo "🔄 重启 Docker 服务..."
    sudo systemctl restart docker
    
    echo "✅ Docker daemon 代理配置完成"
    echo ""
    echo "📋 配置信息："
    echo "   HTTP_PROXY=$proxy_url"
    echo "   HTTPS_PROXY=$proxy_url"
    echo "   NO_PROXY=localhost,127.0.0.1,172.17.0.0/16,host.docker.internal"
    echo ""
    echo "💡 提示：如果代理地址变更，请重新运行此脚本"
}

# 主函数
main() {
    echo "=========================================="
    echo "Docker Daemon 代理配置脚本"
    echo "=========================================="
    echo ""
    
    # 检查是否为 root 用户
    if [[ $EUID -ne 0 ]]; then
        echo "❌ 此脚本需要 root 权限"
        echo "请使用: sudo $0"
        exit 1
    fi
    
    # 检测代理
    echo "🔍 检测代理配置..."
    local proxy_url=$(detect_proxy)
    
    if [[ -z "$proxy_url" ]]; then
        echo "⚠️  无法自动检测代理，请手动输入"
        read -p "请输入代理地址（例如: http://172.21.128.1:7890）: " proxy_url
        if [[ -z "$proxy_url" ]]; then
            echo "❌ 未提供代理地址，退出"
            exit 1
        fi
    fi
    
    echo "✅ 检测到代理: $proxy_url"
    echo ""
    
    # 配置代理
    configure_docker_daemon_proxy "$proxy_url"
    
    echo ""
    echo "✅ 配置完成！现在 Docker daemon 将使用代理拉取镜像"
}

main "$@"

