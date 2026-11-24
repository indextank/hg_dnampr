#!/usr/bin/env bash
set -e

# 脚本信息
SCRIPT_NAME="WSL 环境 Docker Web 项目 mkcert SSL证书管理工具"
SCRIPT_VERSION="4.0"

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Windows mkcert 可执行文件（项目内置）
WINDOWS_MKCERT_EXE="$SCRIPT_DIR/mkcert-v1.4.4-windows-amd64.exe"
# Windows 用户 mkcert CA 目录（宿主机）
WINDOWS_CAROOT_DEFAULT="C:\\Users\\$USER\\AppData\\Local\\mkcert"

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
    "php85.default.com"
    "php86.default.com"
    "baiyou-dev.default.com"
    "baiyou-dev.api.default.com"
    "beacon-dev.default.com"
    "beacon-dev.api.default.com"
    "clue-dev.default.com"
    "aems.default.com"
    "aems.api.default.com"
)

# 证书输出目录 - 指向项目的 nginx 证书目录
CERT_OUTPUT_DIR="$SCRIPT_DIR/vhost/nginx_vhost/certs"

# Windows hosts 文件（WSL 挂载路径）
WINDOWS_HOSTS_WIN_PATH="C:\\Windows\\System32\\drivers\\etc\\hosts"
WINDOWS_HOSTS_WSL_PATH="/mnt/c/Windows/System32/drivers/etc/hosts"

# Windows hosts 文件（WSL 挂载路径）
WINDOWS_HOSTS_WIN_PATH="C:\\Windows\\System32\\drivers\\etc\\hosts"
WINDOWS_HOSTS_WSL_PATH="/mnt/c/Windows/System32/drivers/etc/hosts"

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

# ─── WSL 检测与 Windows 互操作 ───────────────────────────────

# 检测是否在 WSL 环境中运行
is_wsl() {
    if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
        return 0
    fi
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        return 0
    fi
    return 1
}

# 获取 Windows 用户名（兼容 WSL 与宿主机用户名不一致的情况）
get_windows_username() {
    local win_user=""
    # 优先通过 cmd.exe 获取
    if command_exists cmd.exe; then
        win_user=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n')
    fi
    # 回退：使用当前 Linux 用户名
    if [[ -z "$win_user" ]]; then
        win_user="$USER"
    fi
    echo "$win_user"
}

# 获取 Windows 侧 mkcert CAROOT 路径（WSL 格式）
get_windows_caroot_wsl_path() {
    local win_user
    win_user=$(get_windows_username)
    local win_path="/mnt/c/Users/${win_user}/AppData/Local/mkcert"

    # 尝试通过 cmd.exe 执行 mkcert -CAROOT 获取精确路径
    if [[ -f "$WINDOWS_MKCERT_EXE" ]]; then
        # 将 WSL 路径转换为 Windows 路径供 cmd.exe 使用
        local win_exe_path
        win_exe_path=$(wslpath -w "$WINDOWS_MKCERT_EXE" 2>/dev/null || echo "$WINDOWS_MKCERT_EXE")
        local raw_path
        raw_path=$(cmd.exe /c "\"$win_exe_path\" -CAROOT" 2>/dev/null | tr -d '\r\n')
        if [[ -n "$raw_path" ]]; then
            # 将 C:\Users\xxx\... 转换为 /mnt/c/Users/xxx/...
            win_path=$(wslpath -u "$raw_path" 2>/dev/null || echo "$win_path")
        fi
    fi
    echo "$win_path"
}

# ─── Windows 文件互操作辅助（绕开 /mnt/c 权限限制） ─────────────

# 通过 PowerShell 读取 Windows 侧文件内容（转 LF）
win_read_file_content() {
    local win_path="$1"
    powershell.exe -NoProfile -Command "if (Test-Path -LiteralPath '${win_path}') { Get-Content -LiteralPath '${win_path}' -Raw }" 2>/dev/null | tr -d '\r' || true
}

# 判断 Windows 侧文件是否存在
win_file_exists() {
    local win_path="$1"
    local result
    result=$(powershell.exe -NoProfile -Command "if (Test-Path -LiteralPath '${win_path}') { 'YES' }" 2>/dev/null | tr -d '\r\n')
    [[ "$result" == "YES" ]]
}

# 获取 Windows CA rootCA.pem 内容（优先直接读 /mnt 路径，失败回退 PowerShell）
get_windows_ca_content() {
    local win_caroot_wsl="$1"
    local content=""
    if [[ -r "${win_caroot_wsl}/rootCA.pem" ]]; then
        content=$(cat "${win_caroot_wsl}/rootCA.pem" 2>/dev/null | tr -d '\r' || true)
    fi
    if [[ -z "$content" ]] && command_exists powershell.exe; then
        local win_caroot_win
        win_caroot_win=$(wslpath -w "$win_caroot_wsl" 2>/dev/null || true)
        if [[ -n "$win_caroot_win" ]]; then
            content=$(win_read_file_content "${win_caroot_win}\\rootCA.pem")
        fi
    fi
    [[ -z "$content" ]] && return 1
    printf '%s\n' "$content"
}

# 在 Windows 宿主机上安装 mkcert 并初始化 CA
install_mkcert_on_windows() {
    yellow "🪟 正在处理 Windows 宿主机 mkcert..."

    if ! is_wsl; then
        yellow "⚠️ 非 WSL 环境，跳过 Windows mkcert 安装"
        return 0
    fi

    # 检查 exe 是否存在
    if [[ ! -f "$WINDOWS_MKCERT_EXE" ]]; then
        red "❌ 未找到 Windows mkcert 可执行文件: $WINDOWS_MKCERT_EXE"
        yellow "💡 请从 https://github.com/FiloSottile/mkcert/releases/latest 下载并放到项目根目录"
        return 1
    fi

    # 检查 Windows 上是否已安装 mkcert（CA 文件是否存在；目录元数据可直读）
    local win_caroot
    win_caroot=$(get_windows_caroot_wsl_path)

    if [[ -f "${win_caroot}/rootCA.pem" ]] || win_file_exists "$(wslpath -w "$win_caroot" 2>/dev/null || echo '')\\rootCA.pem"; then
        green "✅ Windows mkcert CA 已存在: ${win_caroot}/rootCA.pem"
    else
        yellow "📦 在 Windows 上安装 mkcert CA..."
        # 将 WSL 路径转换为 Windows 路径供 cmd.exe 使用
        local win_exe_path
        win_exe_path=$(wslpath -w "$WINDOWS_MKCERT_EXE" 2>/dev/null || echo "$WINDOWS_MKCERT_EXE")
        # 通过 cmd.exe 执行 Windows mkcert --install（写入根证书存储需要管理员，失败则 UAC 提权重试）
        local install_ok=false
        if cmd.exe /c "\"$win_exe_path\" -install" 2>/dev/null; then
            install_ok=true
        else
            yellow "🔐 普通权限安装失败，发起 UAC 提权安装（请在弹出的 Windows 对话框中点击“是”）..."
            local ps_elev_install="Start-Process -FilePath 'cmd.exe' -ArgumentList '/c \"\"${win_exe_path}\"\" -install' -Verb RunAs -WindowStyle Hidden -Wait"
            powershell.exe -NoProfile -Command "$ps_elev_install" >/dev/null 2>&1 || true
            if [[ -f "${win_caroot}/rootCA.pem" ]] || win_file_exists "$(wslpath -w "$win_caroot" 2>/dev/null || echo '')\\rootCA.pem"; then
                install_ok=true
            fi
        fi
        if [[ "$install_ok" == "true" ]]; then
            green "✅ Windows mkcert CA 安装成功"
        else
            red "❌ Windows mkcert CA 安装失败"
            yellow "💡 请在 Windows 以管理员身份打开 CMD 手动执行:"
            yellow "   .\\mkcert-v1.4.4-windows-amd64.exe -install"
            return 1
        fi
    fi

    # 验证 CA 文件
    if [[ -f "${win_caroot}/rootCA.pem" ]] && [[ -f "${win_caroot}/rootCA-key.pem" ]]; then
        green "✅ Windows CA 文件完整:"
        echo "  - ${win_caroot}/rootCA.pem"
        echo "  - ${win_caroot}/rootCA-key.pem"
    else
        red "❌ Windows CA 文件不完整，请手动检查: $win_caroot"
        return 1
    fi
}

# 将 Windows CA 证书同步到 WSL mkcert
# 注意：WSL sandbox 模式下 /mnt/c 下的 CA 私钥（root:root 0600）无法直接读取，
# 必须通过 powershell.exe 管道取回内容后写入 WSL CAROOT。
sync_windows_ca_to_wsl() {
    yellow "🔄 正在同步 Windows CA 证书到 WSL..."

    if ! is_wsl; then
        yellow "⚠️ 非 WSL 环境，跳过 CA 同步"
        return 0
    fi

    local win_caroot
    win_caroot=$(get_windows_caroot_wsl_path)

    # 通过 Windows 侧命令获取 CA 内容（兼容 /mnt 直读无权限）
    local ca_content=""
    ca_content=$(get_windows_ca_content "$win_caroot") || true
    if [[ -z "$ca_content" ]]; then
        red "❌ 无法读取 Windows CA 证书内容: ${win_caroot}/rootCA.pem"
        yellow "💡 请先在 Windows 上执行: mkcert-v1.4.4-windows-amd64.exe -install"
        return 1
    fi

    # 获取 WSL 侧 mkcert CAROOT
    local wsl_caroot
    wsl_caroot=$(mkcert -CAROOT 2>/dev/null || true)
    if [[ -z "$wsl_caroot" ]]; then
        red "❌ 无法获取 WSL mkcert CAROOT 路径"
        return 1
    fi

    # WSL 与 Windows CAROOT 指向同一目录时无需复制（避免自我覆盖）
    if [[ "$(realpath -m "$wsl_caroot" 2>/dev/null || echo "$wsl_caroot")" == "$(realpath -m "$win_caroot" 2>/dev/null || echo "$win_caroot")" ]]; then
        green "✅ WSL 与 Windows CAROOT 相同，无需同步"
        mkcert -install 2>/dev/null || true
        return 0
    fi

    # 备份 WSL 旧 CA 并检查是否已一致
    if [[ -f "${wsl_caroot}/rootCA.pem" ]]; then
        local wsl_content
        wsl_content=$(tr -d '\r' < "${wsl_caroot}/rootCA.pem" 2>/dev/null || true)
        if [[ -n "$wsl_content" ]] && printf '%s' "$wsl_content" | cmp -s - <(printf '%s' "$ca_content"); then
            green "✅ WSL 与 Windows CA 证书已一致，无需同步"
            return 0
        fi

        local backup_dir="${wsl_caroot}/backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        cp -f "${wsl_caroot}/rootCA.pem" "$backup_dir/" 2>/dev/null || true
        cp -f "${wsl_caroot}/rootCA-key.pem" "$backup_dir/" 2>/dev/null || true
        yellow "📄 已备份 WSL 旧 CA 到: $backup_dir"
    fi

    # 将 Windows CA 内容写入 WSL CAROOT（私钥尽量从 Windows 侧取回）
    mkdir -p "$wsl_caroot"
    printf '%s\n' "$ca_content" > "${wsl_caroot}/rootCA.pem"
    chmod 644 "${wsl_caroot}/rootCA.pem"

    local key_content=""
    if [[ -r "${win_caroot}/rootCA-key.pem" ]]; then
        key_content=$(cat "${win_caroot}/rootCA-key.pem" 2>/dev/null | tr -d '\r' || true)
    fi
    if [[ -z "$key_content" ]] && command_exists powershell.exe; then
        local win_caroot_win
        win_caroot_win=$(wslpath -w "$win_caroot" 2>/dev/null || true)
        if [[ -n "$win_caroot_win" ]]; then
            key_content=$(win_read_file_content "${win_caroot_win}\\rootCA-key.pem")
        fi
    fi
    if [[ -n "$key_content" ]]; then
        printf '%s\n' "$key_content" > "${wsl_caroot}/rootCA-key.pem"
        chmod 600 "${wsl_caroot}/rootCA-key.pem"
        green "✅ Windows CA 证书已同步到 WSL: $wsl_caroot"
    else
        yellow "⚠️ 无法读取 Windows CA 私钥，仅同步了 rootCA.pem（生成新证书需在 Windows 侧执行）"
    fi

    # 重新安装 CA 到 WSL 系统信任库（复用已同步的 CA，不会重新生成）
    yellow "🔧 重新安装 CA 到 WSL 系统信任库..."
    if ! mkcert -install 2>/dev/null; then
        # 回退：手工写入系统信任锚点（openssl.cnf 不可写等场景）
        yellow "⚠️ mkcert -install 失败，回退到直接安装系统信任锚点..."
        CAFILE="${wsl_caroot}/rootCA.pem"
        install_to_system_ca || true
    fi

    green "✅ CA 证书同步完成"
}

# 配置 Windows 系统代理绕过列表（WSL 环境下自动执行）
configure_windows_proxy_bypass() {
    yellow "🔧 正在配置 Windows 系统代理绕过列表..."

    if ! is_wsl; then
        return 0
    fi

    if ! command_exists powershell.exe; then
        yellow "⚠️ 未找到 powershell.exe，跳过 Windows 代理绕过配置"
        return 0
    fi

    # 需要绕过的域名通配符
    local bypass_domains=("*.default.com" "*.api.default.com" "*.test.com" "*.api.test.com")

    # 构建 PowerShell 脚本：读取当前 ProxyOverride，追加缺失条目
    local ps_script='$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"; $current = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).ProxyOverride; if ($null -eq $current) { $current = "" }; $items = $current -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }; $changed = $false;'

    for domain in "${bypass_domains[@]}"; do
        ps_script+=" if (\$items -notcontains '${domain}') { \$items += '${domain}'; \$changed = \$true };"
    done

    ps_script+=' if ($changed) { $newOverride = ($items -join ";") + ";<local>"; Set-ItemProperty $regPath -Name ProxyOverride -Value $newOverride; Write-Output "UPDATED" } else { Write-Output "NOCHANGE" }'

    local result
    result=$(powershell.exe -NoProfile -Command "$ps_script" 2>/dev/null | tr -d '\r\n')

    case "$result" in
        *UPDATED*)
            green "✅ Windows 代理绕过列表已更新（添加了 ${bypass_domains[*]}）"
            ;;
        *NOCHANGE*)
            green "✅ Windows 代理绕过列表已是最新"
            ;;
        *)
            yellow "⚠️ Windows 代理绕过配置未成功，请手动在 Clash/代理工具中添加绕过域名:"
            for domain in "${bypass_domains[@]}"; do
                echo "  - $domain"
            done
            ;;
    esac
}

# 检测操作系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VER=$VERSION_ID
        OS_CODENAME=${VERSION_CODENAME:-}
        OS_LIKE=${ID_LIKE:-}
        OS_FAMILY="unknown"
    else
        red "❌ 无法检测操作系统类型"
        exit 1
    fi

    case "$OS" in
        ubuntu|debian|kali|raspbian|linuxmint|elementary|pop|anduinos|zorin)
            OS_FAMILY="debian"
            PKG_MANAGER="apt"
            PKG_UPDATE="apt update"
            PKG_INSTALL="apt install -y"
            NSS_TOOLS_PKG="libnss3-tools"
            MKCERT_PKG="mkcert"
            ;;
        arch|manjaro|garuda|endeavouros|artix|cachyos)
            OS_FAMILY="arch"
            PKG_MANAGER="pacman"
            PKG_UPDATE="pacman -Sy"
            PKG_INSTALL="pacman -S --noconfirm"
            NSS_TOOLS_PKG="nss"
            MKCERT_PKG="mkcert"
            ;;
        fedora|centos|rhel|rocky|almalinux)
            OS_FAMILY="rhel"
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
            OS_FAMILY="suse"
            PKG_MANAGER="zypper"
            PKG_UPDATE="zypper refresh"
            PKG_INSTALL="zypper install -y"
            NSS_TOOLS_PKG="mozilla-nss-tools"
            MKCERT_PKG="mkcert"
            ;;
        *)
            if [[ " $OS_LIKE " == *" arch "* ]]; then
                OS_FAMILY="arch"
                PKG_MANAGER="pacman"
                PKG_UPDATE="pacman -Sy"
                PKG_INSTALL="pacman -S --noconfirm"
                NSS_TOOLS_PKG="nss"
                MKCERT_PKG="mkcert"
            elif [[ " $OS_LIKE " == *" debian "* ]] || [[ " $OS_LIKE " == *" ubuntu "* ]]; then
                OS_FAMILY="debian"
                PKG_MANAGER="apt"
                PKG_UPDATE="apt update"
                PKG_INSTALL="apt install -y"
                NSS_TOOLS_PKG="libnss3-tools"
                MKCERT_PKG="mkcert"
            elif [[ " $OS_LIKE " == *" rhel "* ]] || [[ " $OS_LIKE " == *" fedora "* ]] || [[ " $OS_LIKE " == *" centos "* ]]; then
                OS_FAMILY="rhel"
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
            elif [[ " $OS_LIKE " == *" suse "* ]]; then
                OS_FAMILY="suse"
                PKG_MANAGER="zypper"
                PKG_UPDATE="zypper refresh"
                PKG_INSTALL="zypper install -y"
                NSS_TOOLS_PKG="mozilla-nss-tools"
                MKCERT_PKG="mkcert"
            else
                yellow "⚠️ 未识别的操作系统: $OS，将尝试使用通用方法"
                PKG_MANAGER="unknown"
            fi
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

    if [ "${OS_FAMILY:-unknown}" = "arch" ] && ! command_exists trust && ! command_exists update-ca-trust; then
        yellow "📦 正在安装 p11-kit (trust)..."
        case "$PKG_MANAGER" in
            pacman)
                sudo $PKG_INSTALL p11-kit
                ;;
            *)
                yellow "⚠️ 无法自动安装 p11-kit，请手动安装以支持系统证书库更新"
                ;;
        esac
    fi

    green "✅ 依赖检查完成"
}

# 检查 mkcert CA
check_mkcert_ca() {
    yellow "🔍 检查 mkcert CA 状态..."

    # 获取 CAROOT 路径（mkcert -CAROOT 始终返回 0，不能用于判断是否已安装）
    CAROOT=$(mkcert -CAROOT 2>/dev/null || true)
    if [ -z "$CAROOT" ]; then
        red "❌ 无法获取 mkcert CAROOT 路径，请确认 mkcert 已正确安装"
        exit 1
    fi

    CAFILE="$CAROOT/rootCA.pem"
    CAKEYFILE="$CAROOT/rootCA-key.pem"

    # 以 CA 文件是否存在作为唯一判断依据
    if [ ! -f "$CAFILE" ]; then
        yellow "⚠️ mkcert CA 尚未初始化（$CAFILE 不存在），正在运行 mkcert -install ..."
        mkcert -install

        # 安装后再次确认文件已生成
        if [ ! -f "$CAFILE" ]; then
            red "❌ mkcert -install 执行后仍找不到 CA 文件: $CAFILE"
            red "   请手动运行: mkcert -install"
            exit 1
        fi
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
    CAROOT=$(mkcert -CAROOT 2>/dev/null || true)
    CAFILE="$CAROOT/rootCA.pem"
    if [ -z "$CAROOT" ] || [ ! -f "$CAFILE" ]; then
        red "❌ 无法定位 CA 文件用于系统证书库安装"
        echo "CA 文件位置: $CAFILE"
    else
        case "${OS_FAMILY:-unknown}" in
            debian)
                sudo rm -f /usr/local/share/ca-certificates/mkcert*.crt
                ;;
            arch)
                sudo rm -f /etc/ca-certificates/trust-source/anchors/mkcert-rootCA.crt
                ;;
            rhel)
                sudo rm -f /etc/pki/ca-trust/source/anchors/mkcert-rootCA.crt
                ;;
            suse)
                sudo rm -f /etc/pki/trust/anchors/mkcert-rootCA.crt
                ;;
        esac
        install_to_system_ca || true
    fi

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

        if [[ -f "$cert_file" && -f "$key_file" ]]; then
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

# 管理 Windows 宿主机 hosts 文件（WSL 环境，只追加不覆盖：已存在则跳过）
# 用法: manage_windows_hosts_file <ip>
manage_windows_hosts_file() {
    local hosts_ip="${1:-127.0.0.1}"

    yellow "🌐 正在管理 Windows 宿主机 hosts 文件..."

    if ! is_wsl; then
        yellow "⚠️ 非 WSL 环境，跳过 Windows hosts 配置"
        return 0
    fi

    if ! command_exists powershell.exe; then
        yellow "⚠️ 未找到 powershell.exe，跳过 Windows hosts 配置"
        return 0
    fi

    # 优先通过 PowerShell 读取（绕开 /mnt 权限），失败回退直读挂载路径
    local hosts_content
    hosts_content=$(win_read_file_content "$WINDOWS_HOSTS_WIN_PATH")
    if [[ -z "$hosts_content" && -r "$WINDOWS_HOSTS_WSL_PATH" ]]; then
        hosts_content=$(cat "$WINDOWS_HOSTS_WSL_PATH" 2>/dev/null || true)
    fi

    if [[ -z "$hosts_content" ]]; then
        yellow "⚠️ 无法读取 Windows hosts 文件，跳过（请手动确认 $WINDOWS_HOSTS_WIN_PATH）"
        return 0
    fi

    # 收集需要追加的域名（任意 IPs 已解析或注释中存在则跳过）
    local to_append=()
    local domain
    for domain in "${PROJECT_DOMAINS_FOR_HOSTS[@]}"; do
        if ! printf '%s\n' "$hosts_content" | grep -qiE "^[[:space:]]*[0-9a-fA-F.:]+[[:space:]]+.*${domain//./\.}([[:space:]]|$|#)"; then
            to_append+=("$domain")
        else
            cyan "  - 跳过已存在的域名: $domain"
        fi
    done

    if [[ ${#to_append[@]} -eq 0 ]]; then
        green "✅ Windows hosts 已包含全部本地域名，无需修改"
        return 0
    fi

    # 生成待追加内容（CRLF 行尾，写入项目内共享目录以便提权进程访问）
    local tmp_win="${CERT_OUTPUT_DIR}/.windows-hosts-append.tmp"
    mkdir -p "$CERT_OUTPUT_DIR"
    local run_marker="# mkcert auto-generated entries - $(date '+%Y-%m-%d %H:%M:%S')"
    {
        echo ""
        echo "$run_marker"
        for domain in "${to_append[@]}"; do
            printf '%s    %s\r\n' "$hosts_ip" "$domain"
        done
        echo "# End mkcert auto-generated entries"
    } > "$tmp_win"

    # 方法1：普通权限直接追加（cmd.exe >> 需要管理员，多数情况下会失败）
    local win_tmp
    win_tmp=$(wslpath -w "$tmp_win" 2>/dev/null || echo "$tmp_win")
    if cmd.exe /c "attrib -R \"$WINDOWS_HOSTS_WIN_PATH\" & type \"$win_tmp\" >> \"$WINDOWS_HOSTS_WIN_PATH\"" >/dev/null 2>&1; then
        if win_read_file_content "$WINDOWS_HOSTS_WIN_PATH" | grep -qF "$run_marker"; then
            rm -f "$tmp_win"
            green "✅ Windows hosts 已追加 ${#to_append[@]} 个域名"
            return 0
        fi
    fi

    # 方法2：通过 UAC 提权追加（会弹出“用户账户控制”确认框）
    yellow "🔐 需要管理员权限，正在发起 UAC 提权写入 Windows hosts..."
    yellow "   （请在弹出的 Windows 对话框中点击“是”）"
    local ps_elev="Start-Process -FilePath 'cmd.exe' -ArgumentList '/c type \"${win_tmp}\" >> \"${WINDOWS_HOSTS_WIN_PATH}\"' -Verb RunAs -WindowStyle Hidden -Wait"
    powershell.exe -NoProfile -Command "$ps_elev" >/dev/null 2>&1 || true

    # 校验写入结果（用本次运行唯一的时间戳标记行，避免误判）
    local verify
    verify=$(win_read_file_content "$WINDOWS_HOSTS_WIN_PATH")
    if [[ -n "$verify" ]] && printf '%s\n' "$verify" | grep -qF "$run_marker"; then
        rm -f "$tmp_win"
        green "✅ Windows hosts 已追加 ${#to_append[@]} 个域名（$hosts_ip）"
    else
        rm -f "$tmp_win"
        red "❌ Windows hosts 写入失败（可能被 UAC 取消或文件被占用）"
        yellow "💡 请手动将以下内容追加到 $WINDOWS_HOSTS_WIN_PATH ："
        for domain in "${to_append[@]}"; do
            echo "   $hosts_ip    $domain"
        done
    fi
}

# 安装到系统证书库
install_to_system_ca() {
    yellow "📥 正在安装到系统证书库..."

    case "${OS_FAMILY:-unknown}" in
        debian)
            sudo mkdir -p /usr/local/share/ca-certificates
            sudo cp "$CAFILE" /usr/local/share/ca-certificates/mkcert-rootCA.crt
            sudo update-ca-certificates
            ;;
        arch)
            sudo mkdir -p /etc/ca-certificates/trust-source/anchors
            sudo cp "$CAFILE" /etc/ca-certificates/trust-source/anchors/mkcert-rootCA.crt
            if command_exists trust; then
                sudo trust extract-compat
            elif command_exists update-ca-trust; then
                sudo update-ca-trust
            else
                yellow "⚠️ 未找到 trust/update-ca-trust 命令，请安装 p11-kit 并执行: sudo trust extract-compat"
                echo "CA 文件位置: $CAFILE"
                return 1
            fi
            ;;
        rhel)
            sudo mkdir -p /etc/pki/ca-trust/source/anchors
            sudo cp "$CAFILE" /etc/pki/ca-trust/source/anchors/mkcert-rootCA.crt
            sudo update-ca-trust
            ;;
        suse)
            sudo mkdir -p /etc/pki/trust/anchors
            sudo cp "$CAFILE" /etc/pki/trust/anchors/mkcert-rootCA.crt
            sudo update-ca-certificates
            ;;
        *)
            if [ -d "/usr/local/share/ca-certificates" ]; then
                sudo mkdir -p /usr/local/share/ca-certificates
                sudo cp "$CAFILE" /usr/local/share/ca-certificates/mkcert-rootCA.crt
                sudo update-ca-certificates
            elif [ -d "/etc/ca-certificates/trust-source/anchors" ] || [[ " ${OS_LIKE:-} " == *" arch "* ]]; then
                OS_FAMILY="arch"
                install_to_system_ca
                return $?
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

    # 询问用户是否要重启容器（WSL/非交互环境自动重建，避免卡在菜单）
    if is_wsl || [ ! -t 0 ]; then
        yellow "🔄 自动重建 nginx 容器以加载新证书（nginx 证书为镜像内置，必须重建）..."
        rebuild_nginx_container
        return 0
    fi

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
        if "$SCRIPT_DIR/up.sh" nginx php74 php80 php81 php82 php83 php84 php85 php86 restart; then
            green "✅ web服务重启成功"
        else
            red "❌ web服务重启失败，请手动执行: ./up.sh nginx php74 php80 php81 php82 php83 php84 php85 php86 restart"
        fi
    fi
}

# 重建nginx容器以更新证书
rebuild_nginx_container() {
    yellow "🔨 正在重建nginx容器以更新证书..."

    # 证书更新只影响 Dockerfile 末尾的 COPY 层，无需 --no-cache 重跑 apt-get。
    # 使用缓存构建（复用 apt 安装层）+ --force-recreate 确保容器使用新镜像。
    if "$SCRIPT_DIR/build.sh" nginx --force-recreate; then
        green "✅ nginx容器重建成功，证书已更新"

        # 验证证书是否正确
        yellow "🔍 验证证书更新..."
        # 等待容器进入 running 状态（最多 30 秒）
        local _wait=0
        until [[ "$(docker inspect -f '{{.State.Status}}' nginx 2>/dev/null)" == "running" ]]; do
            sleep 1
            (( _wait++ ))
            if [[ $_wait -ge 30 ]]; then
                yellow "⚠️ 等待 nginx 容器超时（30s），跳过证书验证"
                return 0
            fi
        done

        if docker exec nginx openssl x509 -in /etc/nginx/conf/ssl/rootCA.pem -text -noout | grep -q "*.api.default.com"; then
            green "✅ 证书验证成功，包含 *.api.default.com"
        else
            yellow "⚠️ 证书验证失败，可能需要手动检查"
        fi
    else
        red "❌ nginx容器重建失败，请手动执行: ./build.sh nginx --force-recreate"
        yellow "💡 若构建时 apt-get 失败（exit 100），说明网络无法访问 deb.debian.org，可尝试:"
        yellow "   export CHANGE_SOURCE=true && ./build.sh nginx --force-recreate"
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
    if is_wsl; then
        echo "- Windows CA 路径: $(get_windows_caroot_wsl_path)"
        echo "- Windows hosts: $WINDOWS_HOSTS_WIN_PATH"
        echo "- 跳过 CA 同步: $0 --no-windows-sync"
        echo "- 跳过 Windows hosts: $0 --no-windows-hosts"
    fi
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
    echo "  --no-windows-sync  跳过 Windows CA 同步（WSL 环境）"
    echo "  --no-windows-hosts 跳过 Windows 宿主机 hosts 配置（WSL 环境）"
    echo "  --hosts-ip <ip>    Windows hosts 写入的 IP，默认 127.0.0.1"
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
    echo "  - 自动更新 /etc/hosts 和 Windows 宿主机 hosts 文件（已存在则跳过）"
    echo "  - 导入证书到浏览器"
    echo "  - WSL 环境下自动同步 Windows 宿主机 CA 证书"
    echo ""
    echo "支持的系统:"
    echo "  - WSL (Ubuntu/Debian/Arch/AlmaLinux)"
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
    local no_windows_sync=false
    local no_windows_hosts=false
    local hosts_ip="127.0.0.1"
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
            --no-windows-sync)
                no_windows_sync=true
                shift
                ;;
            --no-windows-hosts)
                no_windows_hosts=true
                shift
                ;;
            --hosts-ip)
                hosts_ip="${2:-127.0.0.1}"
                shift 2
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

    # WSL 环境：检测并提示
    if is_wsl; then
        green "✅ 检测到 WSL 环境 (${WSL_DISTRO_NAME:-unknown})"
    fi

    # 安装依赖
    install_dependencies

    # WSL 环境：安装 Windows mkcert 并同步 CA
    if is_wsl && [ "$no_windows_sync" = false ]; then
        yellow "🔗 WSL CA 同步流程..."
        install_mkcert_on_windows
        sync_windows_ca_to_wsl
        configure_windows_proxy_bypass
    fi

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
        if is_wsl && [ "$no_windows_hosts" = false ]; then
            manage_windows_hosts_file "$hosts_ip"
        fi
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

# 执行主函数（被 source 时不自动执行，便于测试和复用）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

