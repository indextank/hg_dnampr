#!/usr/bin/env bash
# ==========================================
# ELK Let's Encrypt 证书管理函数库
# ==========================================
# 用途：生产环境 ELK 通过 Nginx 反代 + Let's Encrypt 实现可信 HTTPS
# 依赖：
#   common_functions.sh（info/warn/error/success）
#   container_runtime.sh（cr_cmd）
# 全局变量（由调用方提供）：
#   PROJECT_DIR  — 项目根目录（绝对路径）
#   ENVIRONMENT  — 运行环境（production/prod/development/dev）
# ==========================================

# ------------------------------------------
# 内部：加载 Let's Encrypt 相关配置变量
# ------------------------------------------
_elk_le_load_config() {
    local env_file="$PROJECT_DIR/build/elk/${ELK_BUILD_VERSION:-9.5}/elk.prod.env"
    if [[ ! -f "$env_file" ]]; then
        warn "未找到 $env_file，无法加载 Let's Encrypt 配置"
        return 1
    fi
    # 仅读取未设置的变量（避免覆盖已由 env_file 加载的値）
    local _key _val _line
    while IFS= read -r _line; do
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$_line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
        _key="${_line%%=*}"
        _val="${_line#*=}"
        # 去除引号
        if [[ "$_val" == \"*\" ]]; then _val="${_val:1:${#_val}-2}"
        elif [[ "$_val" == \'*\' ]]; then _val="${_val:1:${#_val}-2}"; fi
        case "$_key" in
            KIBANA_DOMAIN|ELK_LETSENCRYPT_EMAIL|ELK_LETSENCRYPT_CERT_DIR|KIBANA_PUBLIC_BASE_URL|\
            ELK_ACME_DNS_PROVIDER|ELK_ACME_ALI_KEY|ELK_ACME_ALI_SECRET|ELK_ACME_CF_TOKEN)
                [[ -z "${!_key:-}" ]] && export "${_key}=${_val}"
                ;;
        esac
    done < "$env_file"
    # 设置默认値
    KIBANA_DOMAIN="${KIBANA_DOMAIN:-}"
    ELK_LETSENCRYPT_EMAIL="${ELK_LETSENCRYPT_EMAIL:-}"
    ELK_LETSENCRYPT_CERT_DIR="${ELK_LETSENCRYPT_CERT_DIR:-./vhost/nginx_vhost/certs}"
    ELK_ACME_DNS_PROVIDER="${ELK_ACME_DNS_PROVIDER:-}"
    ELK_ACME_ALI_KEY="${ELK_ACME_ALI_KEY:-}"
    ELK_ACME_ALI_SECRET="${ELK_ACME_ALI_SECRET:-}"
    ELK_ACME_CF_TOKEN="${ELK_ACME_CF_TOKEN:-}"
}

# ------------------------------------------
# 内部：解析纯域名（去除 http:// 或 https:// 前缀及末尾 /）
# 用法：_elk_le_parse_domain "https://my-es.jgyljt.com"  输出: my-es.jgyljt.com
# ------------------------------------------
_elk_le_parse_domain() {
    local raw="$1"
    # 去除协议头
    raw="${raw#https://}"
    raw="${raw#http://}"
    # 去除末尾斜杠和路径
    raw="${raw%%/*}"
    # 去除末尾空格
    raw="${raw%% }"
    echo "$raw"
}

# ------------------------------------------
# 确保 nginx 容器已叠加 ELK overlay 运行
# 职责：
#   1. 若 nginx 镜像不存在 → 先 build
#   2. 若 nginx 容器未运行 → 自动启动（用 --no-deps 跳过 depends_on）
#   3. 若已运行但尚未加入 hg_dnmpr_network → docker network connect
# 调用场景：ELK up/start 流程（生产环境）
# ------------------------------------------
ensure_nginx_with_elk_overlay() {
    # docker/compose 命令数组（支持 sudo）
    # 用数组而不是字符串，避免含空格的命令名被当成单个词
    # 注意: up.sh 设置了 IFS=$'\n\t'，空格不在 IFS 里，所以 ${VAR} 不能被空格分割
    #         必须用 read -ra 或 ( )内显式用空格分割
    local _docker_bin
    _docker_bin=$(command -v docker 2>/dev/null || echo "/usr/bin/docker")
    local -a _docker_cmd=() _compose_cmd=()
    # 将 COMPOSE_CMD 按空格分割成数组元素（避免 IFS 非默认导致的分割失败）
    local -a _compose_parts=()
    IFS=' ' read -ra _compose_parts <<< "${COMPOSE_CMD:-docker compose}"
    if [[ -n "${CR_SUDO:-}" ]]; then
        _docker_cmd=("$CR_SUDO" "$_docker_bin")
        _compose_cmd=("$CR_SUDO" "${_compose_parts[@]}")
    else
        _docker_cmd=("$_docker_bin")
        _compose_cmd=("${_compose_parts[@]}")
    fi

    info "ELK 启动：确保 nginx 已应用 ELK overlay（证书卷挂载 + hg_dnmpr_network）..."

    # ── 步骤1：检查 nginx 镜像，不存在则先构建 ────────────────────
    local _env_short
    case "${ENVIRONMENT:-}" in
        prod|production) _env_short="prod" ;;
        *) _env_short="dev" ;;
    esac
    if ! cr_cmd images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^hg_dnmpr_nginx:latest$"; then
        info "未检测到 hg_dnmpr_nginx:latest 镜像，开始构建..."
        if ! (cd "$PROJECT_DIR" && "${_compose_cmd[@]}" --env-file "$PROJECT_DIR/.env.runtime" -f "$PROJECT_DIR/compose/main.yaml" -f "$PROJECT_DIR/compose/overlays/${_env_short}.yaml" build nginx 2>&1); then
            warn "nginx 镜像构建失败"
            return 1
        fi
        success "nginx 镜像构建完成"
    fi

    # ── 步骤2：检查容器是否运行，未运行则直接用 docker run 启动 ────────
    if ! cr_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "nginx"; then
        # 先检查容器是否已创建但处于 stopped 状态
        local _nginx_id
        _nginx_id=$(cr_cmd ps -a --filter "name=^nginx$" --format '{{.ID}}' 2>/dev/null | head -1)
        if [[ -n "$_nginx_id" ]]; then
            # 容器已存在但停止了，直接 start
            info "nginx 容器已存在（stopped），正在启动..."
            if ! "${_docker_cmd[@]}" start nginx 2>&1; then
                warn "nginx 容器 start 失败"
                return 1
            fi
        else
            # 容器不存在，需要创建并启动
            info "nginx 容器不存在，正在创建并启动（直接 docker run，跳过 compose 网络管理）..."
            # 通过 compose config 获取 nginx 的完整运行参数
            local _nginx_cfg
            _nginx_cfg=$("${_compose_cmd[@]}" --env-file "$PROJECT_DIR/.env.runtime" \
                -f "$PROJECT_DIR/compose/main.yaml" \
                -f "$PROJECT_DIR/compose/overlays/prod.yaml" \
                config --format json 2>/dev/null) || true
            # 提取卷挂载参数（数组形式，避免 IFS 非默认导致的 word-split 失败）
            local -a _vol_args=()
            while IFS= read -r _vol; do
                [[ -n "$_vol" ]] && _vol_args+=("-v" "$_vol")
            done < <(echo "$_nginx_cfg" | python3 -c "
import json,sys
c=json.load(sys.stdin)
for v in c['services']['nginx'].get('volumes',[]):
    print(v['source']+':'+v['target'])
" 2>/dev/null)
            # 提取证书卷（ELK overlay）
            # 证书统一存放于 vhost/nginx_vhost/certs/，已通过 NGINX_VHOST_DIR 挂载为 /etc/nginx/conf.d/
            # 无需额外卷挂载，注释原有 elk-certs overlay 路径
            # local _cert_dir_host="${ELK_LETSENCRYPT_CERT_DIR:-./vhost/nginx_vhost/certs}"
            # [[ "$_cert_dir_host" == ./* ]] && _cert_dir_host="$PROJECT_DIR/${_cert_dir_host#./}"
            # _vol_args+=("-v" "${_cert_dir_host}:/etc/nginx/elk-certs:rw")
            # 提取端口映射（数组）
            local -a _port_args=()
            while IFS= read -r _port; do
                [[ -n "$_port" ]] && _port_args+=("-p" "$_port")
            done < <(echo "$_nginx_cfg" | python3 -c "
import json,sys
c=json.load(sys.stdin)
for p in c['services']['nginx'].get('ports',[]):
    print(str(p.get('published',''))+':'+str(p['target']))
" 2>/dev/null)
            # 提取环境变量（数组）——减少不必要的大量 -e 参数，只传递 nginx 实际需要的变量
            local -a _env_args=()
            while IFS= read -r _e; do
                [[ -n "$_e" ]] && _env_args+=("-e" "$_e")
            done < <(echo "$_nginx_cfg" | python3 -c "
import json,sys
c=json.load(sys.stdin)
# 只传递 nginx 实际使用的关键变量
keep = {'SET_CONTAINER_TIMEZONE', 'CONTAINER_TIMEZONE', 'TZ'}
for k,v in c['services']['nginx'].get('environment',{}).items():
    if k in keep:
        print(k+'='+str(v))
" 2>/dev/null)
            # 执行 docker run
            if ! "${_docker_cmd[@]}" run -d \
                --name nginx \
                --restart unless-stopped \
                --network hg_dnmpr_network \
                "${_vol_args[@]}" \
                "${_port_args[@]}" \
                "${_env_args[@]}" \
                hg_dnmpr_nginx:latest 2>&1; then
                warn "docker run nginx 失败"
                return 1
            fi
        fi
        # 等待容器就绪（最多 30s）
        local _i
        for _i in $(seq 1 15); do
            cr_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "nginx" && break
            sleep 2
        done
        if ! cr_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "nginx"; then
            warn "nginx 容器启动超时"
            return 1
        fi
        success "nginx 容器已启动"
    fi

    # ── 步骤3：容器已运行 → 检查是否已加入 hg_dnmpr_network ──────
    local _nginx_nets
    _nginx_nets=$(cr_cmd inspect nginx --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || echo "")
    if echo "$_nginx_nets" | grep -qw "hg_dnmpr_network"; then
        info "nginx 已加入 hg_dnmpr_network，overlay 已生效，无需重新应用"
        return 0
    fi

    # ── 步骤4：尚未加入目标网络 → docker network connect ──────────
    info "nginx 尚未加入 hg_dnmpr_network，正在执行 network connect..."
    if ! "${_docker_cmd[@]}" network inspect hg_dnmpr_network >/dev/null 2>&1; then
        # 网络尚不存在：ELK 容器启动后会自动创建，不阻塞此步骤
        info "hg_dnmpr_network 尚不存在，ELK 启动后将自动创建并连接"
        return 0
    fi
    if "${_docker_cmd[@]}" network connect hg_dnmpr_network nginx 2>/dev/null; then
        success "nginx 已加入 hg_dnmpr_network"
    else
        warn "docker network connect 失败，请手动执行: ${_docker_cmd[*]} network connect hg_dnmpr_network nginx"
        return 1
    fi

    success "nginx ELK overlay 已应用（hg_dnmpr_network 网络已连接）"
    return 0
}


# ------------------------------------------
# 向后兼容别名（旧代码调用 ensure_nginx_running 不报错）
# ------------------------------------------
ensure_nginx_running() {
    ensure_nginx_with_elk_overlay "$@"
}

# ------------------------------------------
# 主函数：申请/续签 Let's Encrypt 证书
# 生产环境 + KIBANA_DOMAIN 非空时执行，其余情况静默跳过
# ------------------------------------------
ensure_letsencrypt_cert() {
    # 非生产环境跳过
    case "${ENVIRONMENT:-}" in
        production|prod) ;;
        *) return 0 ;;
    esac

    _elk_le_load_config

    # 域名未配置则提示并跳过（不报错，不中断启动）
    if [[ -z "${KIBANA_DOMAIN:-}" ]]; then
        warn "KIBANA_DOMAIN 未配置，跳过 Let's Encrypt 证书申请"
        info "如需启用可信 HTTPS，请在 build/elk/${ELK_BUILD_VERSION:-9.5}/elk.prod.env 中配置："
        echo "  KIBANA_DOMAIN=your.kibana.domain.com"
        echo "  ELK_LETSENCRYPT_EMAIL=admin@your.domain.com"
        return 0
    fi

    if [[ -z "${ELK_LETSENCRYPT_EMAIL:-}" ]]; then
        warn "ELK_LETSENCRYPT_EMAIL 未配置，跳过 Let's Encrypt 证书申请"
        return 0
    fi

    # 解析纯域名（支持 https://my-es.jgyljt.com 格式）
    local domain
    domain="$(_elk_le_parse_domain "$KIBANA_DOMAIN")"
    if [[ -z "$domain" ]]; then
        error "KIBANA_DOMAIN 解析失败: $KIBANA_DOMAIN"
        return 1
    fi

    # 确定验证方式
    local use_dns=false
    local dns_provider="${ELK_ACME_DNS_PROVIDER:-}"
    if [[ -n "$dns_provider" ]]; then
        # 检查对应 API Key 是否已配置
        case "$dns_provider" in
            dns_ali)
                if [[ -n "${ELK_ACME_ALI_KEY:-}" && -n "${ELK_ACME_ALI_SECRET:-}" ]]; then
                    use_dns=true
                else
                    warn "ELK_ACME_DNS_PROVIDER=dns_ali 但 Ali_Key/Ali_Secret 未配置，降级到 webroot 验证"
                fi
                ;;
            dns_cf)
                if [[ -n "${ELK_ACME_CF_TOKEN:-}" ]]; then
                    use_dns=true
                else
                    warn "ELK_ACME_DNS_PROVIDER=dns_cf 但 CF_Token 未配置，降级到 webroot 验证"
                fi
                ;;
            *)
                warn "未识别的 DNS 插件: $dns_provider，降级到 webroot 验证"
                ;;
        esac
    fi

    # webroot 验证需要 nginx 运行；DNS 验证在宿主机直接执行无需 nginx
    if [[ "$use_dns" == false ]]; then
        ensure_nginx_running || return 1
    fi

    local cert_dir
    if [[ "${ELK_LETSENCRYPT_CERT_DIR}" == ./* ]]; then
        cert_dir="$PROJECT_DIR/${ELK_LETSENCRYPT_CERT_DIR#./}"
    else
        cert_dir="$ELK_LETSENCRYPT_CERT_DIR"
    fi
    local fullchain="$cert_dir/fullchain.pem"

    # 证书有效期 > 30 天则跳过申请
    if [[ -f "$fullchain" ]] && openssl x509 -checkend 2592000 -noout -in "$fullchain" 2>/dev/null; then
        success "Let's Encrypt 证书有效（30天内不到期），跳过申请"
        generate_kibana_vhost "$domain"
        return 0
    fi

    info "开始申请 Let's Encrypt 证书: $domain"
    mkdir -p "$cert_dir"

    if [[ "$use_dns" == true ]]; then
        # ── DNS-01 验证：在宿主机上直接调用 acme.sh ──
        info "验证方式: DNS-01（$dns_provider）"
        _elk_le_issue_dns "$domain" "$dns_provider" "$cert_dir"
    else
        # ── webroot 验证：在 nginx 容器内调用 acme.sh ──
        info "验证方式: webroot（nginx 容器）"
        _elk_le_issue_webroot "$domain" "$cert_dir"
    fi

    success "✅ Let's Encrypt 证书申请成功！"
    info "Kibana 现在可通过以下地址访问: https://${domain}"

    # 更新 elk.prod.env 中的 KIBANA_PUBLIC_BASE_URL
    local env_file="$PROJECT_DIR/build/elk/${ELK_BUILD_VERSION:-9.5}/elk.prod.env"
    if grep -q "^KIBANA_PUBLIC_BASE_URL=" "$env_file" 2>/dev/null; then
        sed -i "s|^KIBANA_PUBLIC_BASE_URL=.*|KIBANA_PUBLIC_BASE_URL=https://${domain}|" "$env_file"
    fi

    # 确保 nginx 运行（DNS 验证模式下 nginx 尚未启动）
    ensure_nginx_running || true

    # 设置自动续签 crontab
    setup_cert_renewal_cron

    return 0
}

# ------------------------------------------
# 内部：DNS-01 验证申请证书（宿主机直接调用 acme.sh）
# ------------------------------------------
_elk_le_issue_dns() {
    local domain="$1" dns_provider="$2" cert_dir="$3"

    # 检查宿主机是否已安装 acme.sh
    local acme_bin="$HOME/.acme.sh/acme.sh"
    if [[ ! -f "$acme_bin" ]]; then
        info "宿主机尚未安装 acme.sh，开始安装..."
        local install_cmd="curl -sS https://get.acme.sh | sh -s email=${ELK_LETSENCRYPT_EMAIL}"
        if ! eval "$install_cmd"; then
            error "acme.sh 安装失败"
            return 1
        fi
        # 重新加载以确保命令可用
        [[ -f "$HOME/.acme.sh/acme.sh.env" ]] && source "$HOME/.acme.sh/acme.sh.env" || true
        success "acme.sh 安装完成"
    fi

    # 根据 DNS 提供商导出 API 凭证到环境变量
    case "$dns_provider" in
        dns_ali)
            export Ali_Key="${ELK_ACME_ALI_KEY}"
            export Ali_Secret="${ELK_ACME_ALI_SECRET}"
            info "使用阿里云 DNS API (Ali_Key: ${Ali_Key:0:8}...)"
            ;;
        dns_cf)
            export CF_Token="${ELK_ACME_CF_TOKEN}"
            info "使用 Cloudflare DNS API"
            ;;
    esac

    # 申请证书
    if ! "$acme_bin" --issue -d "$domain" \
        --dns "$dns_provider" \
        --server letsencrypt; then
        error "证书申请失败，请确认 DNS API Key 正确且域名已由该 DNS 提供商管理"
        return 1
    fi

    # 安装证书到目标目录
    "$acme_bin" --install-cert -d "$domain" \
        --cert-file   "$cert_dir/${domain}.cert.pem" \
        --key-file    "$cert_dir/${domain}.key.pem" \
        --fullchain-file "$cert_dir/${domain}.fullchain.pem" \
        --reloadcmd   "$(_elk_le_nginx_reload_cmd)"

    # 生成 vhost 并 reload nginx
    generate_kibana_vhost "$domain"
    _elk_le_nginx_reload
}

# ------------------------------------------
# 内部：webroot 验证申请证书（nginx 容器内调用 acme.sh）
# ------------------------------------------
_elk_le_issue_webroot() {
    local domain="$1" cert_dir="$2"

    # 在 nginx 容器内安装 acme.sh（幂等）
    info "检查/安装 acme.sh（nginx 容器内）..."
    if ! cr_cmd exec nginx sh -c 'command -v /root/.acme.sh/acme.sh > /dev/null 2>&1'; then
        local install_cmd="curl -sS https://get.acme.sh | sh -s email=${ELK_LETSENCRYPT_EMAIL}"
        if ! cr_cmd exec nginx sh -c "$install_cmd"; then
            error "acme.sh 安装失败，请检查 nginx 容器网络连通性"
            return 1
        fi
        success "acme.sh 安装完成"
    fi

    # 申请证书
    info "申请证书中（webroot 验证）..."
    if ! cr_cmd exec nginx /root/.acme.sh/acme.sh \
        --issue -d "$domain" \
        --webroot /var/www/html \
        --server letsencrypt; then
        error "证书申请失败，请确认："
        echo "  1. 域名 $domain 的 DNS A 记录已解析到本服务器"
        echo "  2. 服务器 80 端口已在安全组/防火墙开放"
        echo "  3. nginx 容器可正常访问互联网"
        return 1
    fi

    # 安装证书到实机目录（nginx 容器内路径）
    # 证书位于 /etc/nginx/conf.d/certs/（即实机 vhost/nginx_vhost/certs/）
    cr_cmd exec nginx /root/.acme.sh/acme.sh \
        --install-cert -d "$domain" \
        --cert-file /etc/nginx/conf.d/certs/${domain}.cert.pem \
        --key-file /etc/nginx/conf.d/certs/${domain}.key.pem \
        --fullchain-file /etc/nginx/conf.d/certs/${domain}.fullchain.pem \
        --reloadcmd "nginx -s reload"

    generate_kibana_vhost "$domain"
    cr_cmd exec nginx nginx -s reload 2>/dev/null || true
}

# ------------------------------------------
# 内部：获取 nginx reload 命令（DNS 模式下 acme.sh --install-cert reloadcmd 用）
# ------------------------------------------
_elk_le_nginx_reload_cmd() {
    # DNS 模式证书安装到宿主机，reload 需通过 docker exec 调用
    local cr="${CR:-docker}"
    local sudo_prefix="${CR_SUDO:+$CR_SUDO }"
    echo "${sudo_prefix}${cr} exec nginx nginx -s reload"
}

# ------------------------------------------
# 内部：nginx 容器执行 reload
# ------------------------------------------
_elk_le_nginx_reload() {
    if cr_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "nginx"; then
        cr_cmd exec nginx nginx -s reload 2>/dev/null || true
    fi
}

# ------------------------------------------
# 生成 Kibana 的 Nginx vhost 配置
# 参数: domain — 纯域名（如 my-es.jgyljt.com）
# ------------------------------------------
generate_kibana_vhost() {
    local domain="${1:-${KIBANA_DOMAIN:-}}"
    # 支持传入带前缀的域名
    domain="$(_elk_le_parse_domain "$domain")"
    if [[ -z "$domain" ]]; then
        warn "generate_kibana_vhost: 域名为空，跳过 vhost 生成"
        return 0
    fi

    # cert_dir 内容路径（容器内视角）
    # 证书存放于 /etc/nginx/conf.d/certs/（即实机 vhost/nginx_vhost/certs/）
    local container_cert_dir="/etc/nginx/conf.d/certs"

    # vhost 文件路径：与 NGINX_VHOST_DIR（./vhost/nginx_vhost）挂载路径保持一致
    # 容器内对应 /etc/nginx/conf.d/<domain>.conf
    local conf_file="$PROJECT_DIR/vhost/nginx_vhost/${domain}.conf"
    mkdir -p "$PROJECT_DIR/vhost/nginx_vhost"

    cat > "$conf_file" << NGINX_CONF
# ==========================================
# Kibana HTTPS 反代配置（Let's Encrypt）
# 由 elk_letsencrypt.sh 自动生成，请勿手动修改
# ==========================================
server {
    listen 80;
    server_name ${domain};

    # Let's Encrypt webroot 验证（证书续签需要）
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }

    # 其余请求强制跳转 HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${domain};

    ssl_certificate     ${container_cert_dir}/${domain}.fullchain.pem;
    ssl_certificate_key ${container_cert_dir}/${domain}.key.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE+AESGCM:ECDHE+CHACHA20:DHE+AESGCM:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    # 使用 Docker 内嵌 DNS，实现运行时动态解析（避免 reload 时 kibana 不存导致失败）
    resolver 127.0.0.11 valid=10s ipv6=off;
    resolver_timeout 5s;

    # Kibana WebSocket 支持（实时日志/Console 功能需要）
    proxy_http_version  1.1;
    proxy_set_header    Upgrade \$http_upgrade;
    proxy_set_header    Connection "upgrade";
    proxy_set_header    Host \$host;
    proxy_set_header    X-Real-IP \$remote_addr;
    proxy_set_header    X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header    X-Forwarded-Proto \$scheme;
    proxy_read_timeout  300s;
    proxy_send_timeout  300s;

    location / {
        # 将 upstream 存入变量，避免 nginx 在启动/reload 时验证 upstream
        set \$kibana_upstream http://kibana:5601;
        proxy_pass \$kibana_upstream;
    }
}
NGINX_CONF

    success "Kibana Nginx vhost 配置已生成: $conf_file"
}

# ------------------------------------------
# 设置宿主机 crontab 自动续签任务（幂等）
# ------------------------------------------
setup_cert_renewal_cron() {
    local renew_script="$PROJECT_DIR/scripts/renew-elk-certs.sh"
    local log_file="$PROJECT_DIR/logs/elk-cert-renewal.log"
    local cron_job="30 2 * * * ${renew_script} >> ${log_file} 2>&1"

    # 确保续签脚本存在且有执行权限
    if [[ ! -f "$renew_script" ]]; then
        warn "未找到续签脚本: $renew_script，跳过 crontab 设置"
        return 0
    fi
    chmod +x "$renew_script" 2>/dev/null || true

    # 幂等写入（先删除旧条目，再追加新条目）
    ( crontab -l 2>/dev/null | grep -v "renew-elk-certs"; echo "$cron_job" ) | crontab -
    success "crontab 每日 02:30 自动续签任务已设置"
    info "日志将写入: $log_file"
}
