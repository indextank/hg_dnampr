#!/usr/bin/env bash
set -e

# 脚本信息
SCRIPT_NAME="Docker Web 项目 mkcert SSL证书管理工具"
SCRIPT_VERSION="3.0"

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 通配符域名配置（用于广泛支持所有子域名）
WILDCARD_DOMAINS=(
    "*.api.default.com"
    "*.default.com"
    "*.test.com"
    "*.local"
    "*.dev"
)

# 基础域名配置
BASE_DOMAINS=(
    "localhost"
    "127.0.0.1"
    "::1"
)

# 项目中发现的具体域名（用于hosts文件管理）
PROJECT_DOMAINS_FOR_HOSTS=(
    "php74.default.com"
    "php82.default.com"
    "php84.default.com"
    "baiyou-dev.default.com"
    "baiyou-dev.api.default.com"
    "beacon-dev.default.com"
    "beacon-dev.api.default.com"
    "clue-dev.default.com"
)

# 证书输出目录 - 指向项目的 nginx 证书目录
CERT_OUTPUT_DIR="$SCRIPT_DIR/vhost/nginx_vhost/certs"

# 颜色输出函数
blue() { echo -e "\033[36m\033[01m$1\033[0m"; }
red() { echo -e "\033[31m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
white() { echo -e "\033[37m\033[01m$1\033[0m"; }
cyan() { echo -e "\033[96m\033[01m$1\033[0m"; }

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检测操作系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VER=$VERSION_ID
        OS_CODENAME=${VERSION_CODENAME:-}
    else
        red "❌ 无法检测操作系统类型"
        exit 1
    fi

    case "$OS" in
        ubuntu|debian|kali|raspbian|linuxmint|elementary|pop|anduinos)
            PKG_MANAGER="apt"
            PKG_UPDATE="apt update"
            PKG_INSTALL="apt install -y"
            NSS_TOOLS_PKG="libnss3-tools"
            MKCERT_PKG="mkcert"
            ;;
        arch|manjaro|garuda|endeavouros|artix)
            PKG_MANAGER="pacman"
            PKG_UPDATE="pacman -Sy"
            PKG_INSTALL="pacman -S --noconfirm"
            NSS_TOOLS_PKG="nss"
            MKCERT_PKG="mkcert"
            ;;
        fedora|centos|rhel|rocky|almalinux)
            if command_exists dnf; then
                PKG_MANAGER="dnf"
                PKG_UPDATE="dnf check-update || true"
                PKG_INSTALL="dnf install -y"
            else
                PKG_MANAGER="yum"
                PKG_UPDATE="yum check-update || true"
                PKG_INSTALL="yum install -y"
            fi
            NSS_TOOLS_PKG="nss-tools"
            MKCERT_PKG="mkcert"
            ;;
        opensuse*|sles)
            PKG_MANAGER="zypper"
            PKG_UPDATE="zypper refresh"
            PKG_INSTALL="zypper install -y"
            NSS_TOOLS_PKG="mozilla-nss-tools"
            MKCERT_PKG="mkcert"
            ;;
        *)
            yellow "⚠️ 未识别的操作系统: $OS，将尝试使用通用方法"
            PKG_MANAGER="unknown"
            ;;
    esac
}

# 自动安装 mkcert
install_mkcert() {
    if command_exists mkcert; then
        green "✅ mkcert 已安装: $(mkcert -version 2>/dev/null || echo 'version unknown')"
        return 0
    fi

    yellow "📦 正在安装 mkcert..."

    case "$PKG_MANAGER" in
        apt)
            # 对于 Ubuntu/Debian，先尝试从官方仓库安装
            sudo $PKG_UPDATE
            if sudo $PKG_INSTALL $MKCERT_PKG 2>/dev/null; then
                green "✅ 从官方仓库安装 mkcert 成功"
                return 0
            fi

            # 如果失败，从 GitHub 下载
            yellow "📦 从 GitHub 下载 mkcert..."
            install_mkcert_from_github
            ;;
        pacman)
            sudo $PKG_INSTALL $MKCERT_PKG
            ;;
        dnf|yum)
            # Fedora/RHEL 通常需要 EPEL 或从 GitHub 安装
            if ! sudo $PKG_INSTALL $MKCERT_PKG 2>/dev/null; then
                yellow "📦 从 GitHub 下载 mkcert..."
                install_mkcert_from_github
            fi
            ;;
        zypper)
            sudo $PKG_INSTALL $MKCERT_PKG
            ;;
        *)
            yellow "📦 从 GitHub 下载 mkcert..."
            install_mkcert_from_github
            ;;
    esac

    if command_exists mkcert; then
        green "✅ mkcert 安装成功"
    else
        red "❌ mkcert 安装失败"
        exit 1
    fi
}

# 从 GitHub 下载并安装 mkcert
install_mkcert_from_github() {
    local arch
    local os_name

    # 检测架构
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l) arch="arm" ;;
        i386|i686) arch="386" ;;
        *)
            red "❌ 不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac

    # 检测操作系统
    case "$(uname -s)" in
        Linux) os_name="linux" ;;
        Darwin) os_name="darwin" ;;
        *)
            red "❌ 不支持的操作系统: $(uname -s)"
            exit 1
            ;;
    esac

    local download_url="https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v*-${os_name}-${arch}"
    local temp_dir=$(mktemp -d)
    local mkcert_file="$temp_dir/mkcert"

    yellow "📥 正在下载 mkcert..."
    if curl -L -o "$mkcert_file" "https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v1.4.4-${os_name}-${arch}" 2>/dev/null; then
        chmod +x "$mkcert_file"
        sudo mv "$mkcert_file" /usr/local/bin/mkcert
        green "✅ mkcert 下载安装成功"
    else
        red "❌ mkcert 下载失败，请检查网络连接"
        rm -rf "$temp_dir"
        exit 1
    fi

    rm -rf "$temp_dir"
}

# 安装必要的工具
install_dependencies() {
    yellow "🔧 检查并安装必要的依赖..."

    # 安装 mkcert
    install_mkcert

    # 检查 curl
    if ! command_exists curl; then
        yellow "📦 正在安装 curl..."
        case "$PKG_MANAGER" in
            apt)
                sudo $PKG_UPDATE
                sudo $PKG_INSTALL curl
                ;;
            pacman)
                sudo $PKG_INSTALL curl
                ;;
            dnf|yum)
                sudo $PKG_INSTALL curl
                ;;
            zypper)
                sudo $PKG_INSTALL curl
                ;;
            *)
                red "❌ 请手动安装 curl"
                exit 1
                ;;
        esac
    fi

    # 安装 NSS 工具 (用于 Firefox 证书导入)
    if ! command_exists certutil; then
        yellow "📦 正在安装 NSS 工具..."
        case "$PKG_MANAGER" in
            apt)
                sudo $PKG_UPDATE
                sudo $PKG_INSTALL $NSS_TOOLS_PKG
                ;;
            pacman)
                sudo $PKG_INSTALL $NSS_TOOLS_PKG
                ;;
            dnf|yum)
                sudo $PKG_INSTALL $NSS_TOOLS_PKG
                ;;
            zypper)
                sudo $PKG_INSTALL $NSS_TOOLS_PKG
                ;;
            *)
                yellow "⚠️ 无法自动安装 NSS 工具，将跳过 Firefox 证书导入"
                ;;
        esac
    fi

    green "✅ 依赖检查完成"
}

# 检查 mkcert CA
check_mkcert_ca() {
    yellow "🔍 检查 mkcert CA 状态..."

    # 检查是否已安装 CA
    if ! mkcert -CAROOT >/dev/null 2>&1; then
        yellow "⚠️ mkcert CA 未初始化，正在安装..."
        mkcert -install
    fi

    CAROOT=$(mkcert -CAROOT)
    CAFILE="$CAROOT/rootCA.pem"
    CAKEYFILE="$CAROOT/rootCA-key.pem"

    if [ ! -f "$CAFILE" ]; then
        red "❌ 找不到 mkcert CA 文件，请重新运行: mkcert -install"
        exit 1
    fi

    green "✅ 找到 mkcert CA: $CAFILE"
}

# 强制重新安装CA证书
force_reinstall_ca() {
    yellow "🔄 强制重新安装CA证书..."

    # 1. 完全重新安装CA
    yellow "1. 重新安装CA证书..."
    mkcert -uninstall || true
    mkcert -install

    # 2. 手动安装到Firefox
    yellow "2. 手动安装CA到Firefox..."
    local firefox_profiles=$(find ~/.mozilla/firefox/ -name "*.default*" -type d 2>/dev/null || true)
    for profile in $firefox_profiles; do
        if [ -d "$profile" ]; then
            local profile_name=$(basename "$profile")
            cyan "  处理 $profile_name..."

            # 删除所有可能的旧mkcert证书
            certutil -d "sql:$profile" -D -n "mkcert development CA" 2>/dev/null || true
            certutil -d "sql:$profile" -D -n "mkcert" 2>/dev/null || true
            certutil -d "sql:$profile" -D -n "mkcert development certificate" 2>/dev/null || true

            # 重新添加CA证书，使用更高的信任级别
            if certutil -d "sql:$profile" -A -t "C,C,C" -n "mkcert-dev-ca-$(date +%s)" -i "$(mkcert -CAROOT)/rootCA.pem"; then
                green "    ✅ CA证书已安装"
            else
                red "    ❌ CA证书安装失败"
            fi
        fi
    done

    # 3. 重新安装到系统
    yellow "3. 重新安装到系统证书库..."
    sudo rm -f /usr/local/share/ca-certificates/mkcert*.crt
    sudo cp "$(mkcert -CAROOT)/rootCA.pem" "/usr/local/share/ca-certificates/mkcert-$(date +%s).crt"
    sudo update-ca-certificates

    green "✅ CA证书强制重新安装完成"
}

# 生成域名证书
generate_domain_certificates() {
    yellow "🔐 正在生成域名证书..."

    # 创建证书输出目录
    mkdir -p "$CERT_OUTPUT_DIR"

    # 进入证书目录
    cd "$CERT_OUTPUT_DIR"

    # 合并所有域名 - 现在主要使用通配符域名
    local all_domains=("${WILDCARD_DOMAINS[@]}" "${BASE_DOMAINS[@]}")

    # 生成包含所有域名的证书
    green "📋 生成的域名列表:"
    for domain in "${all_domains[@]}"; do
        echo "  - $domain"
    done

    # 生成证书
    yellow "🔨 正在生成证书文件..."
    if mkcert "${all_domains[@]}"; then
        green "✅ 证书生成成功"

                # 查找最新生成的证书文件（根据时间戳和域名内容）
        local cert_file=""
        local key_file=""

        # 优先查找包含api.default.com的证书文件（最新的完整证书）
        if [[ -f "_wildcard.api.default.com+7.pem" ]]; then
            cert_file="_wildcard.api.default.com+7.pem"
            key_file="_wildcard.api.default.com+7-key.pem"
        else
            # 如果没有找到API证书，查找最新的证书文件
            cert_file=$(ls -t *.pem 2>/dev/null | grep -v "\-key\.pem" | head -1)
            if [[ -n "$cert_file" ]]; then
                key_file="${cert_file%.pem}-key.pem"
            fi
        fi

        if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
            green "📄 生成的证书文件："
            echo "  - 证书文件: $(basename "$cert_file")"
            echo "  - 私钥文件: $(basename "$key_file")"

            # 复制为项目标准名称，确保nginx使用最新证书
            cp "$cert_file" "rootCA.pem"
            cp "$key_file" "rootCA-key.pem"

            green "📄 项目标准文件："
            echo "  - 证书文件: $(pwd)/rootCA.pem"
            echo "  - 私钥文件: $(pwd)/rootCA-key.pem"

            # 验证证书包含的域名
            yellow "🔍 验证证书包含的域名："
            openssl x509 -in "rootCA.pem" -text -noout | grep -A 10 "Subject Alternative Name" | grep DNS | sed 's/DNS://g' | tr ',' '\n' | sed 's/^[[:space:]]*/  - /' | head -10

            # 设置适当的权限
            chmod 644 "rootCA.pem"
            chmod 600 "rootCA-key.pem"

        else
            yellow "⚠️ 未找到预期的证书文件，但生成过程完成"
            echo "证书目录内容:"
            ls -la .
        fi
    else
        red "❌ 证书生成失败"
        cd - >/dev/null
        exit 1
    fi

    cd - >/dev/null
}

# 管理 hosts 文件
manage_hosts_file() {
    yellow "🌐 正在管理 /etc/hosts 文件..."

    local hosts_file="/etc/hosts"
    local backup_file="/etc/hosts.mkcert.backup.$(date +%Y%m%d_%H%M%S)"
    local temp_file=$(mktemp)

    # 备份原始 hosts 文件
    if [ ! -f "$hosts_file.mkcert.backup" ]; then
        sudo cp "$hosts_file" "$backup_file"
        sudo ln -sf "$backup_file" "$hosts_file.mkcert.backup"
        yellow "📄 已备份 hosts 文件到: $backup_file"
    fi

    # 移除旧的 mkcert 条目
    sudo grep -v "# mkcert auto-generated" "$hosts_file" > "$temp_file" || true

    # 添加新的条目（检查重复）
    echo "" >> "$temp_file"
    echo "# mkcert auto-generated entries - $(date)" >> "$temp_file"
    for domain in "${PROJECT_DOMAINS_FOR_HOSTS[@]}"; do
        # 检查域名是否已存在（排除mkcert自动生成的条目）
        if ! grep -q "^[[:space:]]*127\.0\.0\.1[[:space:]]*$domain[[:space:]]*$" "$temp_file" && \
           ! sudo grep -q "^[[:space:]]*127\.0\.0\.1[[:space:]]*$domain[[:space:]]*[^#]*$" "$hosts_file"; then
            echo "127.0.0.1    $domain    # mkcert auto-generated" >> "$temp_file"
            cyan "  + 添加域名: $domain"
        else
            cyan "  - 跳过已存在的域名: $domain"
        fi
    done
    echo "# End mkcert auto-generated entries" >> "$temp_file"

    # 更新 hosts 文件
    sudo cp "$temp_file" "$hosts_file"
    rm "$temp_file"

    green "✅ 已更新 /etc/hosts 文件"
}

# 安装到系统证书库
install_to_system_ca() {
    yellow "📥 正在安装到系统证书库..."

    case "$OS" in
        ubuntu|debian|kali|raspbian|linuxmint|elementary|pop|anduinos)
            sudo cp "$CAFILE" /usr/local/share/ca-certificates/mkcert-rootCA.crt
            sudo update-ca-certificates
            ;;
        arch|manjaro|garuda|endeavouros|artix)
            sudo cp "$CAFILE" /etc/ca-certificates/trust-source/anchors/mkcert-rootCA.crt
            sudo trust extract-compat
            ;;
        fedora|centos|rhel|rocky|almalinux)
            sudo cp "$CAFILE" /etc/pki/ca-trust/source/anchors/mkcert-rootCA.crt
            sudo update-ca-trust
            ;;
        opensuse*|sles)
            sudo cp "$CAFILE" /etc/pki/trust/anchors/mkcert-rootCA.crt
            sudo update-ca-certificates
            ;;
        *)
            # 通用方法 - 尝试 Debian/Ubuntu 方式
            if [ -d "/usr/local/share/ca-certificates" ]; then
                sudo cp "$CAFILE" /usr/local/share/ca-certificates/mkcert-rootCA.crt
                sudo update-ca-certificates
            else
                yellow "⚠️ 无法确定系统证书库位置，请手动安装CA证书"
                echo "CA 文件位置: $CAFILE"
                return 1
            fi
            ;;
    esac

    green "✅ 已安装到系统证书库"
}

# 安装到 Firefox
install_to_firefox() {
    yellow "📥 正在安装到 Firefox..."

    if ! command_exists certutil; then
        yellow "⚠️ 未找到 certutil，跳过 Firefox 导入"
        return 1
    fi

    local firefox_dir="$HOME/.mozilla/firefox"

    if [ -d "$firefox_dir" ]; then
        local installed=false
        for profile in "$firefox_dir"/*.default* "$firefox_dir"/*.*default*; do
            if [ -d "$profile" ]; then
                blue "➡️ 处理 Firefox profile: $(basename "$profile")"
                if certutil -d "sql:$profile" -A -t "C,," -n "mkcert development CA" -i "$CAFILE" 2>/dev/null; then
                    green "  ✅ 已导入到 $(basename "$profile")"
                    installed=true
                else
                    yellow "  ⚠️ 导入失败: $(basename "$profile")"
                fi
            fi
        done

        if [ "$installed" = true ]; then
            green "✅ 已安装到 Firefox"
        else
            yellow "⚠️ 未找到有效的 Firefox profile"
        fi
    else
        yellow "⚠️ 未找到 Firefox 配置目录，跳过 Firefox 导入"
    fi
}

# 安装到 Chrome/Chromium
install_to_chrome() {
    yellow "📥 正在安装到 Chrome/Chromium..."

    # Chrome/Chromium 通常使用系统证书库，所以主要是提示信息
    if command_exists google-chrome || command_exists chromium || command_exists chromium-browser; then
        green "✅ Chrome/Chromium 将使用系统证书库中的 CA"
        echo "如果 Chrome 仍然提示不安全，请尝试："
        echo "1. 重启 Chrome"
        echo "2. 清除浏览器缓存"
        echo "3. 在地址栏输入 chrome://settings/certificates 手动导入"
    else
        yellow "⚠️ 未检测到 Chrome/Chromium"
    fi
}

# Docker容器重启功能
restart_docker_containers() {
    local restart_nginx=false
    local restart_web=false
    local rebuild_nginx=false

    # 询问用户是否要重启容器
    echo ""
    cyan "🐳 证书已生成完成，需要重启Docker容器以加载新证书"
    echo ""
    echo "可选的重启操作："
    echo "1. 重启nginx容器 (快速，但可能不会更新证书)"
    echo "2. 重建nginx容器 (推荐，确保证书更新)"
    echo "3. 重启所有web服务 (nginx + php)"
    echo "4. 跳过重启 (稍后手动重启)"
    echo ""

    while true; do
        read -p "请选择操作 (1/2/3/4): " -n 1 -r choice
        echo
        case $choice in
            1)
                restart_nginx=true
                break
                ;;
            2)
                rebuild_nginx=true
                break
                ;;
            3)
                restart_web=true
                break
                ;;
            4)
                yellow "⚠️ 跳过容器重启，请记得稍后手动重启以加载新证书"
                return 0
                ;;
            *)
                red "无效选择，请输入 1、2、3 或 4"
                ;;
        esac
    done

    # 执行重启操作
    if [ "$restart_nginx" = true ]; then
        yellow "🔄 正在重启nginx容器..."
        if "$SCRIPT_DIR/up.sh" nginx restart; then
            green "✅ nginx容器重启成功"
        else
            red "❌ nginx容器重启失败，请手动执行: ./up.sh nginx restart"
        fi
    elif [ "$rebuild_nginx" = true ]; then
        rebuild_nginx_container
    elif [ "$restart_web" = true ]; then
        yellow "🔄 正在重启web服务 (nginx + php)..."
        if "$SCRIPT_DIR/up.sh" nginx php74 php82 php84 restart; then
            green "✅ web服务重启成功"
        else
            red "❌ web服务重启失败，请手动执行: ./up.sh nginx php74 php82 php84 restart"
        fi
    fi
}

# 重建nginx容器以更新证书
rebuild_nginx_container() {
    yellow "🔨 正在重建nginx容器以更新证书..."

    # 使用项目的build.sh脚本重建nginx
    if "$SCRIPT_DIR/build.sh" nginx --no-cache --auto-up; then
        green "✅ nginx容器重建成功，证书已更新"

        # 验证证书是否正确
        yellow "🔍 验证证书更新..."
        sleep 2  # 等待容器完全启动

        if docker exec nginx openssl x509 -in /etc/nginx/conf/ssl/rootCA.pem -text -noout | grep -q "*.api.default.com"; then
            green "✅ 证书验证成功，包含 *.api.default.com"
        else
            yellow "⚠️ 证书验证失败，可能需要手动检查"
        fi
    else
        red "❌ nginx容器重建失败，请手动执行: ./build.sh nginx --no-cache --auto-up"
    fi
}

# 显示使用说明
show_usage_info() {
    green "🎉 SSL 证书配置完成！"
    echo ""
    blue "📋 项目信息："
    echo "- 项目路径: $SCRIPT_DIR"
    echo "- 证书路径: $CERT_OUTPUT_DIR/"
    echo "- 证书文件: rootCA.pem"
    echo "- 私钥文件: rootCA-key.pem"
    echo ""
    blue "🌐 支持的域名模式："
    for domain in "${WILDCARD_DOMAINS[@]}"; do
        echo "   - $domain (通配符支持所有子域名)"
    done
    echo ""
    blue "📋 项目中的具体域名："
    for domain in "${PROJECT_DOMAINS_FOR_HOSTS[@]}"; do
        echo "   - https://$domain"
    done
    echo ""
    blue "🐳 Docker Nginx 配置："
    echo "您的 nginx 配置已经正确指向："
    echo "  ssl_certificate /etc/nginx/conf/ssl/rootCA.pem;"
    echo "  ssl_certificate_key /etc/nginx/conf/ssl/rootCA-key.pem;"
    echo ""
    cyan "🔄 重要提示："
    echo "1. 证书现在使用通配符模式，支持 *.default.com 下的所有子域名"
    echo "2. 重启浏览器后访问 HTTPS 网站"
    echo ""
    echo "3. 如果证书仍然不被信任，请："
    echo "   - 检查浏览器是否已重启"
    echo "   - 清除浏览器缓存和 SSL 状态"
    echo "   - 确认系统时间正确"
    echo ""
    blue "🔧 故障排除："
    echo "- 查看 CA 证书: mkcert -CAROOT"
    echo "- 重新安装 CA: mkcert -install"
    echo "- 恢复 hosts 文件: sudo cp /etc/hosts.mkcert.backup /etc/hosts"
    echo "- 深度修复: $0 --deep-fix"
    echo "- 强制重建: $0 --rebuild-nginx"
}

# 显示帮助信息
show_help() {
    blue "╔════════════════════════════════════════════════════════════════╗"
    blue "║              $SCRIPT_NAME v$SCRIPT_VERSION               ║"
    blue "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help         显示此帮助信息"
    echo "  --no-hosts         不修改 /etc/hosts 文件"
    echo "  --no-browser       跳过浏览器证书安装"
    echo "  --no-docker        跳过Docker容器重启询问"
    echo "  --auto-restart     自动重启nginx容器"
    echo "  --rebuild-nginx    重建nginx容器以更新证书"
    echo "  --force-reinstall  强制重新安装CA证书"
    echo "  --deep-fix         深度修复浏览器证书问题"
    echo "  --clean            清理生成的证书文件"
    echo ""
    echo "功能:"
    echo "  - 自动检测操作系统并安装 mkcert"
    echo "  - 为项目域名生成 SSL 证书"
    echo "  - 自动配置系统证书库"
    echo "  - 自动更新 /etc/hosts 文件"
    echo "  - 导入证书到浏览器"
    echo ""
    echo "支持的系统:"
    echo "  - Ubuntu/Debian (包括 AnduinOS)"
    echo "  - Arch Linux 系列"
    echo "  - Fedora/RHEL 系列"
    echo "  - openSUSE"
}

# 深度修复浏览器证书问题
deep_fix_browser_certificates() {
    blue "🔧 开始深度修复浏览器证书问题..."
    echo ""

    # 首先强制重新安装CA
    force_reinstall_ca

    # 清理并重新生成项目证书
    yellow "4. 清理并重新生成项目证书..."
    rm -f "$CERT_OUTPUT_DIR"/*.pem 2>/dev/null || true

    # 重新生成证书
    generate_domain_certificates

    # 重建nginx容器
    yellow "5. 重建nginx容器..."
    rebuild_nginx_container

    echo ""
    green "🎉 深度修复完成！"
    echo ""
    cyan "📋 接下来请执行以下步骤："
    echo ""
    yellow "步骤1: 完全关闭所有浏览器"
    echo "- 关闭所有Firefox和Chrome窗口"
    echo "- 确保进程完全退出"
    echo ""
    yellow "步骤2: 清理浏览器数据"
    echo "Firefox:"
    echo "  1. 打开Firefox"
    echo "  2. 按 Ctrl+Shift+Delete"
    echo "  3. 选择'所有内容'和'所有时间'"
    echo "  4. 勾选'Cookie和站点数据'、'缓存的Web内容'、'证书'"
    echo "  5. 点击'立即清除'"
    echo ""
    echo "Chrome:"
    echo "  1. 打开Chrome"
    echo "  2. 按 Ctrl+Shift+Delete"
    echo "  3. 选择'所有时间'"
    echo "  4. 勾选所有选项"
    echo "  5. 点击'清除数据'"
    echo ""
    yellow "步骤3: Firefox证书设置"
    echo "  1. 在地址栏输入: about:preferences#privacy"
    echo "  2. 滚动到'证书'部分"
    echo "  3. 点击'查看证书'"
    echo "  4. 在'证书颁发机构'标签页中查找'mkcert'"
    echo "  5. 如果找到，双击编辑，勾选'信任此CA标识网站'"
    echo ""
    yellow "步骤4: 测试"
    echo "  访问: https://beacon-dev.api.default.com/"
    echo "  访问: https://baiyou-dev.api.default.com/"
    echo ""
    cyan "如果仍然有问题，请尝试："
    echo "- 使用无痕/隐私模式"
    echo "- 临时禁用防病毒软件的HTTPS扫描"
    echo "- 检查系统时间是否正确"
    echo "- 重启计算机"
}

# 清理证书文件
clean_certificates() {
    yellow "🧹 正在清理证书文件..."

    if [ -d "$CERT_OUTPUT_DIR" ]; then
        rm -rf "$CERT_OUTPUT_DIR"/*
        green "✅ 证书文件已清理"
    fi

    # 恢复 hosts 文件
    if [ -f "/etc/hosts.mkcert.backup" ]; then
        read -p "是否恢复 hosts 文件? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo cp "/etc/hosts.mkcert.backup" "/etc/hosts"
            green "✅ hosts 文件已恢复"
        fi
    fi
}

# 主函数
main() {
    local no_hosts=false
    local no_browser=false
    local no_docker=false
    local auto_restart=false
    local rebuild_nginx=false
    local force_reinstall=false
    local deep_fix=false
    local clean_mode=false

    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            --no-hosts)
                no_hosts=true
                shift
                ;;
            --no-browser)
                no_browser=true
                shift
                ;;
            --no-docker)
                no_docker=true
                shift
                ;;
            --auto-restart)
                auto_restart=true
                shift
                ;;
            --rebuild-nginx)
                rebuild_nginx=true
                shift
                ;;
            --force-reinstall)
                force_reinstall=true
                shift
                ;;
            --deep-fix)
                deep_fix=true
                shift
                ;;
            --clean)
                clean_mode=true
                shift
                ;;
            *)
                red "❌ 未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 特殊模式处理
    if [ "$clean_mode" = true ]; then
        clean_certificates
        exit 0
    fi

    if [ "$deep_fix" = true ]; then
        clear
        blue "╔════════════════════════════════════════════════════════════════╗"
        blue "║              $SCRIPT_NAME v$SCRIPT_VERSION - 深度修复模式               ║"
        blue "╚════════════════════════════════════════════════════════════════╝"
        echo ""

        # 检测操作系统
        detect_os
        green "✅ 检测到操作系统: $OS ${OS_VER:-unknown}"

        # 安装依赖
        install_dependencies

        # 执行深度修复
        deep_fix_browser_certificates
        exit 0
    fi

    if [ "$rebuild_nginx" = true ]; then
        yellow "🔨 仅重建nginx容器模式..."
        rebuild_nginx_container
        exit 0
    fi

    clear
    blue "╔════════════════════════════════════════════════════════════════╗"
    blue "║              $SCRIPT_NAME v$SCRIPT_VERSION               ║"
    blue "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    # 检测操作系统
    detect_os
    green "✅ 检测到操作系统: $OS ${OS_VER:-unknown}"

    # 安装依赖
    install_dependencies

    # 强制重新安装CA（如果指定）
    if [ "$force_reinstall" = true ]; then
        force_reinstall_ca
    else
        # 检查 mkcert CA
        check_mkcert_ca
    fi

    # 生成域名证书
    generate_domain_certificates

    # 管理 hosts 文件
    if [ "$no_hosts" = false ]; then
        manage_hosts_file
    fi

    # 安装到系统证书库
    install_to_system_ca

    # 安装到浏览器
    if [ "$no_browser" = false ]; then
        install_to_firefox
        install_to_chrome
    fi

    # Docker容器重启
    if [ "$auto_restart" = true ]; then
        yellow "🔄 自动重启nginx容器..."
        if "$SCRIPT_DIR/up.sh" nginx restart; then
            green "✅ nginx容器自动重启成功"
        else
            red "❌ nginx容器自动重启失败"
        fi
    elif [ "$rebuild_nginx" = true ]; then
        rebuild_nginx_container
    elif [ "$no_docker" = false ]; then
        restart_docker_containers
    fi

    # 显示使用说明
    show_usage_info
}

# 执行主函数
main "$@"