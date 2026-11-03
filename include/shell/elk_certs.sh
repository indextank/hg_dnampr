#!/usr/bin/env bash
# ==========================================
# ELK 证书管理函数库
# ==========================================
# 用途：生成和信任 ELK Stack 所需的 TLS 证书
# 依赖：
#   common_functions.sh（info/warn/error/success 函数）
#   generate-elk-certs.sh（由函数内部 source 调用）
# 全局变量（由调用方提供）：
#   SCRIPT_DIR  — 脚本根目录
#   PROJECT_DIR — 项目根目录
# ==========================================

# 检查并生成ELK SSL证书（如果需要）
check_and_generate_elk_certs() {
    local environment="$1"
    local services=("${@:2}")

    # 只在包含ELK服务时检查证书
    local has_elk=false
    for service in "${services[@]}"; do
        if [[ "$service" == "elk" ]]; then
            has_elk=true
            break
        fi
    done

    if [[ "$has_elk" == "false" ]]; then
        return 0
    fi

    # 标准化环境名称
    local env_name="$environment"
    case "$env_name" in
        production|prod) env_name="prod" ;;
        development|dev) env_name="dev" ;;
        *) env_name="dev" ;;
    esac

    # 读取环境配置文件中的 ELK_HTTP_SSL_ENABLED 配置
    local elk_env_file="${BUILD_ROOT:-$PROJECT_DIR/build}/elk/${ELK_BUILD_VERSION:-9.5}/elk.${env_name}.env"
    local ssl_enabled="false"

    if [[ -f "$elk_env_file" ]]; then
        # 读取配置文件中的 ELK_HTTP_SSL_ENABLED 值
        if grep -q "^ELK_HTTP_SSL_ENABLED=true" "$elk_env_file" 2>/dev/null; then
            ssl_enabled="true"
        elif grep -q "^ELK_HTTP_SSL_ENABLED=false" "$elk_env_file" 2>/dev/null; then
            ssl_enabled="false"
        fi
    fi

    # 如果 SSL 未启用，跳过证书生成
    if [[ "$ssl_enabled" == "false" ]]; then
        info "ℹ️  SSL未启用 (ELK_HTTP_SSL_ENABLED=false)，跳过证书生成"
        return 0
    fi

    info "🔐 检测到SSL已启用 (ELK_HTTP_SSL_ENABLED=true)，检查证书状态..."

    # 检查证书是否存在
    local certs_dir="${BUILD_ROOT:-$PROJECT_DIR/build}/elk/${ELK_BUILD_VERSION:-9.5}/elasticsearch/config/certs"
    local cert_files=(
        "$certs_dir/ca/ca.crt"
        "$certs_dir/ca/ca.key"
        "$certs_dir/elasticsearch/elasticsearch.crt"
        "$certs_dir/elasticsearch/elasticsearch.key"
        "$certs_dir/kibana/kibana.crt"
        "$certs_dir/kibana/kibana.key"
        "$certs_dir/logstash/logstash.crt"
        "$certs_dir/logstash/logstash.key"
    )

    local missing_certs=false
    local missing_cert_list=""
    for cert_file in "${cert_files[@]}"; do
        if [[ ! -f "$cert_file" ]]; then
            missing_certs=true
            missing_cert_list+="  ❌ $cert_file\n"
        fi
    done

    if [[ "$missing_certs" == "true" ]]; then
        warn "⚠️  检测到SSL证书文件不完整或缺失："
        echo -e "$missing_cert_list"
        info "正在自动生成SSL证书..."
        echo ""

        local cert_script="include/shell/generate-elk-certs.sh"
        if [[ ! -f "$cert_script" ]]; then
            error "证书生成脚本不存在: $cert_script"
            error "请确保脚本位于: $cert_script"
            return 1
        fi

        # 执行证书生成脚本
        info "执行证书生成脚本: $cert_script"
        if bash "$cert_script"; then
            echo ""
            success "✅ SSL证书生成完成"
            info "证书已保存至: $certs_dir"
        else
            echo ""
            error "❌ SSL证书生成失败，请检查脚本输出"
            error "提示: 您可以手动运行 ./$cert_script 来生成证书"
            return 1
        fi
    else
        success "✅ SSL证书文件完整，验证通过"

        # 检查证书是否过期（可选）
        local ca_cert="$certs_dir/ca/ca.crt"
        if command -v openssl &> /dev/null && [[ -f "$ca_cert" ]]; then
            local expiry_date
            expiry_date=$(openssl x509 -in "$ca_cert" -noout -enddate 2>/dev/null | cut -d= -f2)
            if [[ -n "$expiry_date" ]]; then
                info "证书有效期至: $expiry_date"
            fi
        fi
    fi

    return 0
}

# 使用 sudo 或直接执行命令（自动降级）
_run_privileged() {
    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        "$@"
    fi
}

# 自动将 ELK CA 安装到系统信任库（Linux）
# 支持：
#   Debian/Ubuntu  — update-ca-certificates
#   RHEL/CentOS/Alibaba Cloud Linux — update-ca-trust
# 无法自动完成：Chrome/Edge 独立证书库（仅提示）
ensure_elk_ca_trust() {
    local certs_dir="${BUILD_ROOT:-$PROJECT_DIR/build}/elk/${ELK_BUILD_VERSION:-9.5}/elasticsearch/config/certs"
    local elk_ca_file="$certs_dir/ca/ca.crt"

    # ELK CA 不存在则跳过
    if [[ ! -f "$elk_ca_file" ]]; then
        warn "未找到 ELK CA 证书: $elk_ca_file，跳过系统信任安装"
        return 0
    fi

    # ── 检测发行版类型 ──────────────────────────────────────────────
    local distro_type="unknown"
    if command -v update-ca-certificates >/dev/null 2>&1; then
        distro_type="debian"   # Debian / Ubuntu
    elif command -v update-ca-trust >/dev/null 2>&1; then
        distro_type="rhel"     # RHEL / CentOS / Alibaba Cloud Linux / Rocky / AlmaLinux
    fi

    if [[ "$distro_type" == "unknown" ]]; then
        warn "系统缺少证书更新工具（update-ca-certificates / update-ca-trust），无法自动安装 ELK CA"
        info "请根据您的系统手动执行："
        echo "  # Debian/Ubuntu:"
        echo "    sudo cp $elk_ca_file /usr/local/share/ca-certificates/elk-ca.crt"
        echo "    sudo update-ca-certificates"
        echo "  # CentOS/RHEL/Alibaba Cloud Linux:"
        echo "    sudo cp $elk_ca_file /etc/pki/ca-trust/source/anchors/elk-ca.crt"
        echo "    sudo update-ca-trust extract"
        return 0
    fi

    # ── Debian/Ubuntu ───────────────────────────────────────────────
    if [[ "$distro_type" == "debian" ]]; then
        local sys_ca_dir="/usr/local/share/ca-certificates"
        local sys_ca_file="$sys_ca_dir/elk-ca.crt"

        # 已安装则跳过
        if [[ -f "$sys_ca_file" ]]; then
            return 0
        fi

        info "尝试自动安装 ELK CA 到系统信任库（Debian/Ubuntu）..."
        if _run_privileged cp "$elk_ca_file" "$sys_ca_file" 2>/dev/null \
            && _run_privileged update-ca-certificates >/dev/null 2>&1; then
            success "ELK CA 已安装到系统信任库: $sys_ca_file"
        else
            warn "未能自动完成系统证书安装（可能需要 sudo 权限）"
            info "请手动执行："
            echo "  sudo cp $elk_ca_file $sys_ca_file"
            echo "  sudo update-ca-certificates"
        fi

    # ── RHEL / CentOS / Alibaba Cloud Linux ────────────────────────
    elif [[ "$distro_type" == "rhel" ]]; then
        local sys_ca_dir="/etc/pki/ca-trust/source/anchors"
        local sys_ca_file="$sys_ca_dir/elk-ca.crt"

        # 已安装则跳过
        if [[ -f "$sys_ca_file" ]]; then
            return 0
        fi

        info "尝试自动安装 ELK CA 到系统信任库（RHEL/CentOS/Alibaba Linux）..."
        if _run_privileged cp "$elk_ca_file" "$sys_ca_file" 2>/dev/null \
            && _run_privileged update-ca-trust extract >/dev/null 2>&1; then
            success "ELK CA 已安装到系统信任库: $sys_ca_file"
        else
            warn "未能自动完成系统证书安装（可能需要 sudo 权限）"
            info "请手动执行："
            echo "  sudo cp $elk_ca_file $sys_ca_file"
            echo "  sudo update-ca-trust extract"
        fi
    fi

    # 浏览器侧提示（Chrome/Edge 使用独立证书库，无法自动化）
    info "若浏览器仍提示 Not Secure，请手动将以下 CA 证书导入浏览器「受信任的根证书颁发机构」："
    echo "  ${PROJECT_DIR:-$PWD}/$elk_ca_file"
}
