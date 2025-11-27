#!/bin/bash

# ==========================================
# Docker & Docker Compose 管理脚本
# ==========================================
# 版本: 2.0
# 更新日期: 2025-11-18
# 支持系统: Debian 10-12+, Ubuntu 20.04+, Arch Linux, WSL, AlmaLinux 8-10
# 功能: 安装/卸载 Docker、自动检测系统、根据地域优化配置
# 使用: sudo ./docker_manager.sh [install|uninstall|help]
# ==========================================

set -e

export LC_ALL=C
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8
export DEBIAN_FRONTEND=noninteractive

# ==========================================
# 颜色函数定义
# ==========================================
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}

# 颜色变量（用于日志函数）
GREEN="\033[32m\033[01m"
YELLOW="\033[33m\033[01m"
RED="\033[31m\033[01m"
BLUE="\033[36m\033[01m"
NC="\033[0m"

# ==========================================
# 全局变量
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/docker_manager.log"
DOCKER_VERSION=""
COMPOSE_VERSION=""
COUNTRY_CODE=""
IN_CHINA=false
OPERATION=""

# 中国镜像源配置
DOCKER_MIRROR_CN="https://docker.m.daocloud.io"
DOCKER_REGISTRY_MIRRORS=(
    "https://docker.m.daocloud.io"
    "https://dockerhub.icu"
    "https://docker.1panel.live"
)

# ==========================================
# 日志函数
# ==========================================
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1" | tee -a "$LOG_FILE"
}

# ==========================================
# 显示帮助信息
# ==========================================
show_help() {
    clear
    blue "======================================================"
    blue "    Docker & Docker Compose 管理脚本 v2.0"
    blue "======================================================"
    echo ""
    
    yellow "使用方法:"
    echo "  sudo ./docker_manager.sh [命令]"
    echo ""
    
    yellow "命令:"
    echo "  install      安装 Docker 和 Docker Compose"
    echo "  uninstall    卸载 Docker 和 Docker Compose（删除所有数据）"
    echo "  help         显示此帮助信息"
    echo ""
    
    yellow "示例:"
    echo "  sudo ./docker_manager.sh install      # 安装 Docker"
    echo "  sudo ./docker_manager.sh uninstall    # 卸载 Docker"
    echo ""
    
    yellow "支持的系统:"
    echo "  - Debian 10, 11, 12+"
    echo "  - Ubuntu 20.04, 22.04, 24.04+"
    echo "  - Arch Linux / Manjaro / Garuda"
    echo "  - AlmaLinux 8, 9, 10"
    echo "  - CentOS Stream / Rocky Linux"
    echo "  - WSL2 (Windows Subsystem for Linux)"
    echo ""
    
    yellow "功能特性:"
    echo "  ✅ 自动检测系统类型和版本"
    echo "  ✅ 智能地理位置检测"
    echo "  ✅ 中国大陆自动配置镜像加速"
    echo "  ✅ Docker 性能优化配置"
    echo "  ✅ 用户权限自动配置"
    echo "  ✅ 完整的日志记录"
    echo ""
    
    blue "======================================================"
}

# ==========================================
# 检查是否为 root 用户
# ==========================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限运行，请使用 sudo ./docker_manager.sh $OPERATION"
    fi
}

# ==========================================
# 系统检测函数
# ==========================================
detect_system() {
    info "正在检测系统信息..."
    
    # 检测操作系统
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        OS_PRETTY_NAME=$PRETTY_NAME
    else
        error "无法检测操作系统类型"
    fi
    
    # 检测架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  ARCH_TYPE="amd64" ;;
        aarch64) ARCH_TYPE="arm64" ;;
        armv7l)  ARCH_TYPE="armhf" ;;
        *)       error "不支持的架构: $ARCH" ;;
    esac
    
    # 检测是否为 WSL
    IS_WSL=false
    if [[ -f /proc/version ]] && grep -qi "microsoft\|wsl" /proc/version; then
        IS_WSL=true
        warn "检测到 WSL 环境"
    fi
    
    # 检测内核版本
    KERNEL_VERSION=$(uname -r)
    
    info "操作系统: $OS_PRETTY_NAME"
    info "系统版本: $OS_VERSION"
    info "系统架构: $ARCH ($ARCH_TYPE)"
    info "内核版本: $KERNEL_VERSION"
    info "WSL 环境: $IS_WSL"
}

# ==========================================
# 检测服务器地理位置
# ==========================================
detect_server_location() {
    info "正在检测服务器地理位置..."
    
    local location=""
    local timeout=8
    
    # 方法1: 使用 ipinfo.io
    location=$(timeout $timeout curl -s --connect-timeout 3 "https://ipinfo.io/country" 2>/dev/null | tr -d '\n' || echo "")
    if [[ -n "$location" && "$location" != "Unknown" ]]; then
        COUNTRY_CODE="$location"
        info "服务器位置: $COUNTRY_CODE (来源: ipinfo.io)"
        return 0
    fi
    
    # 方法2: 使用 ip-api.com
    location=$(timeout $timeout curl -s --connect-timeout 3 "http://ip-api.com/line?fields=countryCode" 2>/dev/null | tr -d '\n' || echo "")
    if [[ -n "$location" && "$location" != "Unknown" ]]; then
        COUNTRY_CODE="$location"
        info "服务器位置: $COUNTRY_CODE (来源: ip-api.com)"
        return 0
    fi
    
    # 方法3: 通过网站可访问性判断
    if ! timeout 5 curl -s --connect-timeout 3 "https://www.google.com" >/dev/null 2>&1; then
        if timeout 5 curl -s --connect-timeout 3 "https://www.baidu.com" >/dev/null 2>&1; then
            COUNTRY_CODE="CN"
            info "服务器位置: CN (通过网站可访问性判断)"
            return 0
        fi
    fi
    
    COUNTRY_CODE="Unknown"
    warn "无法检测服务器地理位置，将使用默认配置"
    return 0
}

# ==========================================
# 判断是否在中国大陆
# ==========================================
check_china_location() {
    if [[ "$COUNTRY_CODE" =~ ^(CN|China|中国)$ ]]; then
        IN_CHINA=true
        yellow "📍 检测到服务器位于中国大陆，将使用国内镜像源加速"
    else
        IN_CHINA=false
        green "📍 服务器位于海外，使用官方源"
    fi
    return 0
}

# ==========================================
# 卸载旧版本 Docker
# ==========================================
remove_old_docker() {
    info "检查并卸载旧版本 Docker..."
    
    case $OS in
        debian|ubuntu)
            apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true
            ;;
        arch|archlinux)
            pacman -Rns --noconfirm docker docker-compose 2>/dev/null || true
            ;;
        almalinux|centos|rhel|rocky)
            yum remove -y docker docker-client docker-client-latest docker-common \
                docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
            ;;
    esac
    
    success "旧版本清理完成"
}

# ==========================================
# 安装 Docker - Debian/Ubuntu
# ==========================================
install_docker_debian_ubuntu() {
    info "开始安装 Docker (Debian/Ubuntu)..."
    
    # 更新包索引
    apt-get update
    
    # 安装依赖
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common
    
    # 添加 Docker 官方 GPG 密钥
    mkdir -p /etc/apt/keyrings
    
    # 删除已存在的密钥和源列表，避免交互式提示
    rm -f /etc/apt/keyrings/docker.gpg
    rm -f /etc/apt/sources.list.d/docker.list
    
    if [[ "$IN_CHINA" == "true" ]]; then
        # 使用阿里云镜像
        curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/$OS/gpg | gpg --batch --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
            "deb [arch=$ARCH_TYPE signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/$OS \
            $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    else
        # 使用官方源
        curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --batch --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
            "deb [arch=$ARCH_TYPE signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
            $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    fi
    
    # 更新包索引
    apt-get update
    
    # 安装 Docker Engine
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    success "Docker 安装完成"
}

# ==========================================
# 安装 Docker - Arch Linux
# ==========================================
install_docker_arch() {
    info "开始安装 Docker (Arch Linux)..."
    
    # 更新系统
    pacman -Sy --noconfirm
    
    # 安装 Docker
    pacman -S --noconfirm docker docker-compose docker-buildx
    
    success "Docker 安装完成"
}

# ==========================================
# 安装 Docker - AlmaLinux/CentOS/RHEL
# ==========================================
install_docker_almalinux() {
    info "开始安装 Docker (AlmaLinux/CentOS/RHEL)..."
    
    # 安装依赖
    yum install -y yum-utils device-mapper-persistent-data lvm2
    
    # 添加 Docker 仓库
    if [[ "$IN_CHINA" == "true" ]]; then
        # 使用阿里云镜像
        yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
        sed -i 's+download.docker.com+mirrors.aliyun.com/docker-ce+' /etc/yum.repos.d/docker-ce.repo
    else
        # 使用官方源
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi
    
    # 安装 Docker Engine
    yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    success "Docker 安装完成"
}

# ==========================================
# 配置 Docker 镜像加速和优化
# ==========================================
configure_docker() {
    info "正在配置 Docker..."
    
    # 创建配置目录
    mkdir -p /etc/docker
    
    # 生成 daemon.json 配置
    local config_file="/etc/docker/daemon.json"
    
    if [[ "$IN_CHINA" == "true" ]]; then
        # 中国大陆配置
        cat > "$config_file" <<EOF
{
  "registry-mirrors": [
    "${DOCKER_REGISTRY_MIRRORS[0]}",
    "${DOCKER_REGISTRY_MIRRORS[1]}",
    "${DOCKER_REGISTRY_MIRRORS[2]}"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "data-root": "/var/lib/docker",
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "live-restore": true,
  "userland-proxy": false,
  "experimental": false,
  "metrics-addr": "127.0.0.1:9323",
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5,
  "default-shm-size": "64M",
  "debug": false
}
EOF
        success "已配置国内镜像加速"
    else
        # 海外配置
        cat > "$config_file" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "data-root": "/var/lib/docker",
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "live-restore": true,
  "userland-proxy": false,
  "experimental": false,
  "metrics-addr": "127.0.0.1:9323",
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5,
  "default-shm-size": "64M",
  "debug": false
}
EOF
        success "已配置 Docker 优化参数"
    fi
    
    info "Docker 配置文件: $config_file"
}

# ==========================================
# WSL 特殊配置
# ==========================================
configure_wsl() {
    if [[ "$IS_WSL" == "true" ]]; then
        warn "WSL 环境特殊配置..."
        
        # WSL2 通常使用 Docker Desktop，给出提示
        yellow "检测到 WSL 环境，建议："
        yellow "  1. 如果使用 WSL2，建议安装 Docker Desktop for Windows"
        yellow "  2. 如果在 WSL2 内直接使用 Docker，需要手动启动 Docker 服务"
        yellow "  3. WSL1 不支持 Docker，请升级到 WSL2"
        
        # 创建 WSL 配置文件
        if [[ ! -f /etc/wsl.conf ]]; then
            cat > /etc/wsl.conf <<EOF
[boot]
systemd=true

[network]
generateResolvConf = true
EOF
            info "已创建 WSL 配置文件"
        fi
    fi
}

# ==========================================
# 启动 Docker 服务
# ==========================================
start_docker() {
    info "正在启动 Docker 服务..."
    
    if [[ "$IS_WSL" == "true" ]]; then
        # WSL 环境
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload
            systemctl enable docker
            systemctl start docker
        else
            warn "WSL 环境未启用 systemd，请手动启动 Docker: sudo dockerd"
            return 0
        fi
    else
        # 非 WSL 环境
        systemctl daemon-reload
        systemctl enable docker
        systemctl restart docker
    fi
    
    # 等待 Docker 启动
    sleep 3
    
    # 验证 Docker 是否运行
    if docker info >/dev/null 2>&1; then
        success "Docker 服务已启动"
        return 0
    else
        warn "Docker 服务启动可能失败，请检查: systemctl status docker"
        return 1
    fi
}

# ==========================================
# 配置用户权限
# ==========================================
configure_user_permissions() {
    info "配置 Docker 用户权限..."
    
    # 获取当前用户（如果是通过 sudo 运行）
    local real_user="${SUDO_USER:-$USER}"
    
    if [[ "$real_user" != "root" && -n "$real_user" ]]; then
        # 添加用户到 docker 组
        usermod -aG docker "$real_user" 2>/dev/null || groupadd docker && usermod -aG docker "$real_user"
        success "用户 $real_user 已添加到 docker 组"
        yellow "注意: 需要重新登录才能生效，或执行: newgrp docker"
    fi
}

# ==========================================
# 验证安装
# ==========================================
verify_installation() {
    info "验证 Docker 安装..."
    
    echo ""
    blue "================== 安装信息 =================="
    
    # Docker 版本
    if command -v docker >/dev/null 2>&1; then
        DOCKER_VERSION=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        green "✅ Docker 版本: $DOCKER_VERSION"
    else
        red "❌ Docker 未安装"
        return 1
    fi
    
    # Docker Compose 版本
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_VERSION=$(docker compose version --short)
        green "✅ Docker Compose 版本: $COMPOSE_VERSION"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_VERSION=$(docker-compose --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        green "✅ Docker Compose 版本: $COMPOSE_VERSION (独立版本)"
    else
        yellow "⚠️  Docker Compose 未安装"
    fi
    
    # Docker 服务状态
    if docker info >/dev/null 2>&1; then
        green "✅ Docker 服务: 运行中"
    else
        yellow "⚠️  Docker 服务: 未运行"
    fi
    
    # 镜像加速状态
    if [[ "$IN_CHINA" == "true" ]]; then
        green "✅ 镜像加速: 已配置国内镜像源"
    else
        green "✅ 镜像加速: 使用官方源"
    fi
    
    blue "=============================================="
    echo ""
    
    # 运行测试
    info "运行 Hello World 测试..."
    if docker run --rm hello-world >/dev/null 2>&1; then
        success "Docker 测试成功！"
        return 0
    else
        warn "Docker 测试失败，但基本功能可能正常"
        return 1
    fi
}

# ==========================================
# 显示使用提示
# ==========================================
show_usage_tips() {
    echo ""
    blue "================== 使用提示 =================="
    
    yellow "📚 基本命令:"
    echo "  docker --version              # 查看 Docker 版本"
    echo "  docker compose version        # 查看 Compose 版本"
    echo "  docker info                   # 查看 Docker 信息"
    echo "  docker ps                     # 查看运行中的容器"
    echo "  systemctl status docker       # 查看 Docker 服务状态"
    
    echo ""
    yellow "🔧 常用操作:"
    echo "  systemctl start docker        # 启动 Docker"
    echo "  systemctl stop docker         # 停止 Docker"
    echo "  systemctl restart docker      # 重启 Docker"
    echo "  systemctl enable docker       # 开机自启"
    
    echo ""
    yellow "📖 配置文件位置:"
    echo "  /etc/docker/daemon.json       # Docker 配置文件"
    echo "  /var/lib/docker               # Docker 数据目录"
    echo "  $LOG_FILE        # 管理日志"
    
    if [[ "$IN_CHINA" == "true" ]]; then
        echo ""
        yellow "🌏 国内用户提示:"
        echo "  - 已配置镜像加速，拉取镜像速度更快"
        echo "  - 如需修改镜像源，编辑: /etc/docker/daemon.json"
        echo "  - 修改后重启: systemctl restart docker"
    fi
    
    echo ""
    yellow "⚠️  重要提示:"
    if [[ -n "${SUDO_USER}" && "${SUDO_USER}" != "root" ]]; then
        echo "  - 用户 ${SUDO_USER} 需要重新登录才能使用 docker 命令"
        echo "  - 或临时生效: newgrp docker"
    fi
    
    if [[ "$IS_WSL" == "true" ]]; then
        echo "  - WSL 环境建议使用 Docker Desktop for Windows"
        echo "  - 或手动启动: sudo dockerd &"
    fi
    
    blue "=============================================="
    echo ""
}

# ==========================================
# 卸载 Docker
# ==========================================
uninstall_docker() {
    clear
    blue "======================================================"
    blue "    Docker & Docker Compose 卸载脚本"
    blue "======================================================"
    echo ""
    
    red "⚠️  警告: 此操作将完全卸载 Docker 及删除所有数据！"
    echo ""
    yellow "将要执行以下操作:"
    echo "  1. 停止所有运行中的容器"
    echo "  2. 删除所有容器、镜像、卷和网络"
    echo "  3. 卸载 Docker 和 Docker Compose"
    echo "  4. 删除 Docker 配置文件和数据目录"
    echo ""
    
    read -p "确认要继续吗？[y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        yellow "操作已取消"
        exit 0
    fi
    
    echo ""
    blue "开始卸载..."
    echo "卸载开始时间: $(date)" >> "$LOG_FILE"
    
    # 停止 Docker 服务
    info "停止 Docker 服务..."
    systemctl stop docker 2>/dev/null || true
    systemctl disable docker 2>/dev/null || true
    
    # 停止所有容器
    info "停止所有容器..."
    docker stop $(docker ps -aq) 2>/dev/null || true
    
    # 删除所有容器
    info "删除所有容器..."
    docker rm $(docker ps -aq) 2>/dev/null || true
    
    # 删除所有镜像
    info "删除所有镜像..."
    docker rmi $(docker images -q) -f 2>/dev/null || true
    
    # 删除所有卷
    info "删除所有卷..."
    docker volume rm $(docker volume ls -q) 2>/dev/null || true
    
    # 删除所有网络
    info "删除自定义网络..."
    docker network rm $(docker network ls -q) 2>/dev/null || true
    
    # 根据系统卸载
    case $OS in
        debian|ubuntu)
            info "卸载 Docker (Debian/Ubuntu)..."
            apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
            apt-get autoremove -y
            apt-get autoclean
            rm -f /etc/apt/sources.list.d/docker.list
            rm -f /etc/apt/keyrings/docker.gpg
            ;;
        arch|archlinux)
            info "卸载 Docker (Arch Linux)..."
            pacman -Rns --noconfirm docker docker-compose docker-buildx 2>/dev/null || true
            ;;
        almalinux|centos|rhel|rocky)
            info "卸载 Docker (AlmaLinux/CentOS/RHEL)..."
            yum remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
            yum autoremove -y
            rm -f /etc/yum.repos.d/docker-ce.repo
            ;;
        *)
            red "不支持的操作系统: $OS"
            exit 1
            ;;
    esac
    
    # 删除 Docker 数据目录
    info "删除 Docker 数据目录..."
    rm -rf /var/lib/docker
    rm -rf /var/lib/containerd
    rm -rf /etc/docker
    rm -rf /var/run/docker.sock
    rm -rf /var/run/docker
    
    # 删除 Docker 组
    info "删除 Docker 用户组..."
    groupdel docker 2>/dev/null || true
    
    echo ""
    green "======================================================"
    green "    ✅ Docker 卸载完成！"
    green "======================================================"
    echo ""
    
    yellow "提示:"
    echo "  - 所有 Docker 数据已删除"
    echo "  - 用户需要重新登录才能完全生效"
    echo "  - 如需重新安装，运行: sudo ./docker_manager.sh install"
    echo ""
    
    success "卸载完成，日志已保存到: $LOG_FILE"
}

# ==========================================
# 安装 Docker 主函数
# ==========================================
install_docker() {
    clear
    
    blue "======================================================"
    blue "    Docker & Docker Compose 一键安装脚本 v2.0"
    blue "======================================================"
    echo ""
    
    # 初始化日志
    echo "安装开始时间: $(date)" > "$LOG_FILE"
    
    # 系统检测
    detect_system
    
    # 地理位置检测
    detect_server_location
    check_china_location
    
    echo ""
    yellow "即将开始安装 Docker..."
    yellow "按 Ctrl+C 取消，或等待 5 秒自动继续..."
    sleep 5
    
    # 卸载旧版本
    remove_old_docker
    
    # 根据系统类型安装
    case $OS in
        debian|ubuntu)
            install_docker_debian_ubuntu
            ;;
        arch|archlinux)
            install_docker_arch
            ;;
        almalinux|centos|rhel|rocky)
            install_docker_almalinux
            ;;
        *)
            error "不支持的操作系统: $OS"
            ;;
    esac
    
    # 配置 Docker
    configure_docker
    
    # WSL 特殊配置
    configure_wsl
    
    # 启动 Docker 服务
    start_docker
    
    # 配置用户权限
    configure_user_permissions
    
    # 验证安装
    verify_installation
    
    # 显示使用提示
    show_usage_tips
    
    # 完成
    echo ""
    green "======================================================"
    green "    ✅ Docker 安装完成！"
    green "======================================================"
    echo ""
    
    success "安装日志已保存到: $LOG_FILE"
}

# ==========================================
# 主函数
# ==========================================
main() {
    # 解析命令行参数
    OPERATION="${1:-help}"
    
    case "$OPERATION" in
        install)
            check_root
            install_docker
            ;;
        uninstall)
            check_root
            detect_system
            uninstall_docker
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            show_help
            ;;
    esac
}

# 执行主函数
main "$@"

