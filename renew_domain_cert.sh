#!/bin/bash
# ============================================================================
# Author: indextank
# Date: 2026-11-12
# Version: 1.0.0
# Description: This script is used to renew the domain certificate.
# ============================================================================
# 非交互子命令:
#     --check-certs                      巡检已部署证书有效期
#     --check-dns <域名>                 只读自检：NS / 解析商 / 凭据来源与脱敏值
#     --verify-cert <域名>               校验已部署证书与私钥匹配、SAN、有效期
#     --list-dns-creds                   列出按域名加密保存的解析商凭据
#     --remove-dns-creds <域名>          删除指定域名的已保存凭据（不影响其他域名）
#     --renew-all                        续期全部证书（cron 入口）：按域名注入已保存凭据，
#                                        未到期自动跳过，续期后由 reloadcmd 重载 Nginx
# ============================================================================
export LC_ALL=C
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

# fonts color - 必须在脚本开头定义，因为后续代码会使用
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

# ==========================================
# 代理配置
# ==========================================
# 开关：true 才启用；false/空则不走代理。
# 账密来自系统环境变量 PROXY_*（勿写入本脚本）：
#   PROXY_SCHEME  PROXY_HOST  PROXY_PORT  [PROXY_USER]  [PROXY_PASS]
# 启用后由下方逻辑拼装 PROXY_URL；临时覆盖可：export PROXY_URL=... 或 BUILD_PROXY_URL=...
BUILD_PROXY_ENABLED="${BUILD_PROXY_ENABLED:-false}"
BUILD_PROXY_TYPE="${BUILD_PROXY_TYPE:-socks5h}"

acme_is_proxy_enabled() {
    case "${1:-}" in
        [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]|1) return 0 ;;
        *) return 1 ;;
    esac
}

acme_compose_proxy_url_from_env() {
    local preferred_type="${1:-}"
    local scheme host port user pass
    scheme="${preferred_type:-}"
    case "${scheme,,}" in
        http|https|socks5|socks5h) ;;
        *) scheme="${PROXY_SCHEME:-}" ;;
    esac
    host="${PROXY_HOST:-}"
    port="${PROXY_PORT:-}"
    user="${PROXY_USER:-}"
    pass="${PROXY_PASS:-}"
    [[ -n "$scheme" && -n "$host" && -n "$port" ]] || { echo ""; return 1; }
    case "${scheme,,}" in
        http|https|socks5|socks5h) ;;
        *) echo ""; return 1 ;;
    esac
    if [[ -n "$user" ]]; then
        echo "${scheme}://${user}:${pass}@${host}:${port}"
    else
        echo "${scheme}://${host}:${port}"
    fi
}

acme_mask_proxy_url() {
    local proxy_url="$1"
    local scheme rest hostport
    [[ -n "$proxy_url" ]] || { echo ""; return 0; }
    scheme="${proxy_url%%://*}"
    rest="${proxy_url#*://}"
    hostport="${rest%%/*}"
    hostport="${hostport##*@}"
    if [[ "$scheme" == "$proxy_url" ]]; then
        echo "$hostport"
    else
        echo "${scheme}://${hostport}"
    fi
}

# 仅当 BUILD_PROXY_ENABLED=true 时生成/保留 PROXY_URL
acme_resolve_proxy_url() {
    local explicit="${PROXY_URL:-${BUILD_PROXY_URL:-}}"
    PROXY_URL=""
    if ! acme_is_proxy_enabled "${BUILD_PROXY_ENABLED:-false}"; then
        return 0
    fi
    if [[ -n "$explicit" ]]; then
        PROXY_URL="$explicit"
        return 0
    fi
    PROXY_URL="$(acme_compose_proxy_url_from_env "${BUILD_PROXY_TYPE:-}" 2>/dev/null || true)"
    if [[ -z "$PROXY_URL" ]]; then
        yellow "BUILD_PROXY_ENABLED=true，但系统 PROXY_SCHEME/HOST/PORT 不完整且未设置 PROXY_URL，按直连处理"
    fi
}

acme_resolve_proxy_url

# ==========================================
# DNS 解析商凭据
# ==========================================
# 凭据来源优先级（高 → 低）：
#   1) 按域名加密保存的凭据库（手动配置解析商后写入，续签时自动复用）
#   2) 系统环境变量（export Ali_Key=... 后再执行本脚本）
#   3) 私有环境文件 acme_renew_domain_cert.local.env（已 gitignore，参考同名 .example）
#
# 本脚本不内置任何默认密钥。默认解析商（阿里云 DNS / Cloudflare DNS）的凭据
# 必须由系统环境变量或私有 env 文件提供；缺失/失效/权限不足时，按交互流程
# 改为 HTTP 验证，或为当前域名单独配置解析商凭据（按域名隔离、加密保存）。

ACME_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACME_LOCAL_ENV_FILE="${ACME_LOCAL_ENV_FILE:-${ACME_SCRIPT_DIR}/acme_renew_domain_cert.local.env}"

# ---- 按域名隔离的加密凭据库 ----
ACME_CRED_STORE_DIR="${ACME_CRED_STORE_DIR:-${HOME}/.hg_acme_dns}"
ACME_CRED_STORE_KEY="${ACME_CRED_STORE_KEY:-${ACME_CRED_STORE_DIR}/master.key}"
ACME_CRED_STORE_DOMAINS="${ACME_CRED_STORE_DOMAINS:-${ACME_CRED_STORE_DIR}/domains}"
ACME_CRED_CIPHER="aes-256-cbc"
ACME_CRED_KDF_ITER=200000

# ---- 解析商目录：插件名|显示名|变量:标签:必填|... ----
ACME_PROVIDER_CATALOG=(
    'dns_ali|阿里云 DNS|Ali_Key:AccessKey ID:1|Ali_Secret:AccessKey Secret:1'
    'dns_cf|Cloudflare|CF_Token:API Token:1|CF_Account_ID:Account ID:0'
    'dns_dp|腾讯云 DNSPod|DP_Id:Token ID:1|DP_Key:Token:1'
    'dns_jd|京东云 DNS|JD_ACCESS_KEY_ID:AccessKey ID:1|JD_ACCESS_KEY_SECRET:AccessKey Secret:1'
    'dns_gd|GoDaddy|GD_Key:API Key:1|GD_Secret:API Secret:1'
    'dns_namecheap|Namecheap|NAMECHEAP_API_KEY:API Key:1|NAMECHEAP_USERNAME:登录用户名:1|NAMECHEAP_SOURCEIP:授权 IP:1'
    'dns_namesilo|NameSilo|Namesilo_Key:API Key:1'
    'dns_porkbun|Porkbun|PORKBUN_API_KEY:API Key:1|PORKBUN_SECRET_API_KEY:Secret API Key:1'
    'dns_dgon|DigitalOcean|DO_API_KEY:API Token:1'
    'dns_vultr|Vultr|VULTR_API_KEY:API Key:1'
    'dns_linode|Linode|LINODE_API_KEY:API Key:1'
    'dns_gcore|Gcore|GCORE_Key:API Key:1'
    'dns_duckdns|DuckDNS|DuckDNS_Token:Token:1'
    'dns_dynv6|dynv6|DYNV6_TOKEN:Token:1'
    'dns_aws|AWS Route 53|AWS_ACCESS_KEY_ID:Access Key ID:1|AWS_SECRET_ACCESS_KEY:Secret Access Key:1'
)

# 有内置在线校验逻辑的默认解析商
ACME_DEFAULT_PROVIDERS=(dns_ali dns_cf)

# HTTP 验证的站点根目录（其 /.well-known/acme-challenge/ 必须能被公网访问）
ACME_HTTP_WEBROOT="${ACME_HTTP_WEBROOT:-}"
ACME_HTTP_MODE=""
ACME_HTTP_WEBROOT_DIR=""

# 本次签发上下文
ACME_VERIFY_MODE="dns"
ACME_LAST_ISSUE_LOG=""
ACME_LAST_AUTH_ERROR=""
ACME_CRED_FAIL_REASON=""
ACME_LOADED_PROVIDER=""
ACME_LOADED_VARS=()
declare -A ACME_CRED_SHADOW=()
ACME_PROMPT_VALUE=""

# acme_catalog_all_vars
# 用途：输出解析商目录中出现的全部凭据变量名（供私有 env 白名单使用）
# 返回：始终 0
acme_catalog_all_vars() {
    local entry spec var
    local -a parts=()
    for entry in "${ACME_PROVIDER_CATALOG[@]}"; do
        IFS='|' read -r -a parts <<< "$entry"
        for spec in "${parts[@]:2}"; do
            var="${spec%%:*}"
            [ -n "$var" ] && printf '%s\n' "$var"
        done
    done
    return 0
}

# 允许从私有 env 文件注入的变量白名单（防止误写覆盖 PATH 等系统变量）
ACME_ENV_ALLOWED_KEYS=()
while IFS= read -r _acme_var; do
    ACME_ENV_ALLOWED_KEYS+=("$_acme_var")
done < <(acme_catalog_all_vars | sort -u)
ACME_ENV_ALLOWED_KEYS+=(ACME_HTTP_WEBROOT ACME_CRED_STORE_DIR ACME_CA ACME_EAB_KID ACME_EAB_HMAC_KEY)
unset _acme_var

# 记录加载前的环境变量快照，用于 --check-dns 报告凭据来源
declare -A ACME_ENV_SNAPSHOT=()
for _k in "${ACME_ENV_ALLOWED_KEYS[@]}"; do
    ACME_ENV_SNAPSHOT["$_k"]="${!_k:-}"
done
unset _k

# acme_load_local_env <file>
# 用途：读取 KEY=VALUE 形式的私有环境文件，只填充"当前为空"的变量，绝不覆盖系统环境变量。
# 参数：$1 文件路径
# 返回：0 = 已读取；1 = 文件不存在或不可读
acme_load_local_env() {
    local file="$1" line lineno=0 key val _allowed _ok
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            yellow "忽略 ${file} 第 ${lineno} 行：不是 KEY=VALUE 格式（值含空格时请加引号）"
            continue
        fi
        key="${BASH_REMATCH[2]}"
        val="${BASH_REMATCH[3]}"
        _ok=false
        for _allowed in "${ACME_ENV_ALLOWED_KEYS[@]}"; do
            if [[ "$key" == "$_allowed" ]]; then _ok=true; break; fi
        done
        if [[ "$_ok" != "true" ]]; then
            yellow "忽略 ${file} 第 ${lineno} 行：${key} 不在允许注入的白名单内"
            continue
        fi
        # 去掉首尾空白
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        else
            # 未加引号时把 " #..." 视为行尾注释
            val="${val%%[[:space:]]#*}"
            val="${val%"${val##*[![:space:]]}"}"
        fi
        # 系统环境变量优先：已设置且非空则跳过
        if [[ -n "${!key:-}" ]]; then
            continue
        fi
        printf -v "$key" '%s' "$val"
        export "$key"
    done < "$file"
    return 0
}

# 私有 env 文件（不存在则跳过，不报错）
acme_load_local_env "$ACME_LOCAL_ENV_FILE" || true

# 目录内的凭据变量统一导出，确保 acme.sh 的 DNS 插件能读取
for _acme_var in "${ACME_ENV_ALLOWED_KEYS[@]}"; do
    if [ -n "${!_acme_var:-}" ]; then
        export "$_acme_var"
    fi
done
unset _acme_var

# ==========================================
# 解析商自动识别
# ==========================================

# 二级公共后缀（推导可注册根域时需要，如 com.cn / co.uk）
ACME_TWO_LEVEL_SUFFIXES=(com.cn net.cn org.cn gov.cn edu.cn com.hk com.tw com.mo co.uk org.uk ac.uk com.au net.au co.nz com.sg co.jp co.kr com.br)

# acme_root_domain <域名>
# 用途：从任意域名（含通配符）推导可注册根域名
# 返回：始终 0，结果打印到 stdout
acme_root_domain() {
    local raw="${1,,}" suffix last2
    local -a parts=()
    raw="${raw#\*.}"
    raw="${raw%.}"
    IFS='.' read -r -a parts <<< "$raw"
    if (( ${#parts[@]} < 2 )); then
        printf '%s' "$raw"
        return 0
    fi
    last2="${parts[${#parts[@]}-2]}.${parts[${#parts[@]}-1]}"
    for suffix in "${ACME_TWO_LEVEL_SUFFIXES[@]}"; do
        if [[ "$last2" == "$suffix" ]] && (( ${#parts[@]} >= 3 )); then
            printf '%s.%s' "${parts[${#parts[@]}-3]}" "$last2"
            return 0
        fi
    done
    printf '%s' "$last2"
}

# acme_query_ns_doh <根域名>
# 用途：无 dig/host/nslookup 时，通过 DoH(JSON) 查询 NS 记录
# 返回：0 = 查到（每行一个，打印到 stdout）；1 = 失败
acme_query_ns_doh() {
    local d="$1" resp="" out="" url
    command -v curl >/dev/null 2>&1 || return 1
    # 优先直连 AliDNS；失败再用 Cloudflare（启用代理时带上代理）
    for url in "https://dns.alidns.com/resolve?name=${d}&type=NS" "https://cloudflare-dns.com/dns-query?name=${d}&type=NS"; do
        resp=""
        if [[ "$url" == *alidns* || -z "${PROXY_URL:-}" ]]; then
            resp="$(curl -s -m 8 -H 'Accept: application/dns-json' "$url" 2>/dev/null)" || resp=""
        else
            resp="$(curl -s -m 8 --proxy "$PROXY_URL" -H 'Accept: application/dns-json' "$url" 2>/dev/null)" || resp=""
        fi
        # 只取 Answer 中 type=NS 的记录，避免把 Authority 段的 SOA 误当 NS
        if command -v python3 >/dev/null 2>&1; then
            out="$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for ans in data.get("Answer") or []:
    if ans.get("type") in (2, "NS"):
        name = str(ans.get("data", "")).rstrip(".")
        if name:
            print(name)
' 2>/dev/null)"
        else
            out="$(printf '%s' "$resp" | grep -o '"data"[[:space:]]*:[[:space:]]*"[^" ]*"' | sed 's/.*"\([^"]*\)"$/\1/')"
        fi
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out" | tr '[:upper:]' '[:lower:]' | sed -e 's/\.$//' -e '/^$/d'
            return 0
        fi
    done
    return 1
}

# acme_query_ns <根域名>
# 用途：查询域名的权威 NS 记录（dig → host → nslookup → DoH 逐级回退）
# 返回：0 = 查到（结果每行一个，打印到 stdout）；1 = 未查到或工具缺失
acme_query_ns() {
    local d="$1" out=""
    if command -v dig >/dev/null 2>&1; then
        out="$(dig +short +time=3 +tries=1 NS "$d" 2>/dev/null)"
    elif command -v host >/dev/null 2>&1; then
        out="$(host -t NS "$d" 2>/dev/null | awk '{print $NF}')"
    elif command -v nslookup >/dev/null 2>&1; then
        out="$(nslookup -type=NS "$d" 2>/dev/null | awk '/[Nn]ameserver/{print $NF}')"
    fi
    out="$(printf '%s\n' "$out" | tr '[:upper:]' '[:lower:]' | sed -e 's/\.$//' -e '/^$/d')"
    if [[ -z "$out" ]]; then
        acme_query_ns_doh "$d" && return 0
        return 1
    fi
    printf '%s\n' "$out"
}

# acme_provider_from_ns
# 用途：从 stdin 的 NS 主机名中识别本脚本已内置凭据支持的解析商插件名
# 返回：0 = 识别成功（插件名打印到 stdout）；1 = 无法识别
acme_provider_from_ns() {
    local ns
    while IFS= read -r ns; do
        case "$ns" in
            *aliyun.com|*hichina.com|*alidns.com) printf 'dns_ali'; return 0 ;;
            *cloudflare.com) printf 'dns_cf'; return 0 ;;
        esac
    done
    return 1
}

# acme_ns_family_hint
# 用途：识别未内置凭据的解析商族，仅用于给出提示文案
# 返回：0 = 识别成功（厂商名打印到 stdout）；1 = 无法识别
acme_ns_family_hint() {
    local ns
    while IFS= read -r ns; do
        case "$ns" in
            *dnspod.net|*dnspod.com|*dnsv2.com|*dnsv3.com) printf '腾讯云 DNSPod'; return 0 ;;
            *huaweicloud-dns.*|*hwcdn.net) printf '华为云 DNS'; return 0 ;;
            *awsdns-*) printf 'AWS Route 53'; return 0 ;;
            *azure-dns.*) printf 'Azure DNS'; return 0 ;;
            *domaincontrol.com) printf 'GoDaddy'; return 0 ;;
            *registrar-servers.com) printf 'Namecheap'; return 0 ;;
        esac
    done
    return 1
}

# acme_provider_find <插件名>
# 用途：从解析商目录取出完整条目
# 返回：0 = 命中（条目打印到 stdout）；1 = 未收录
acme_provider_find() {
    local plugin="$1" entry
    for entry in "${ACME_PROVIDER_CATALOG[@]}"; do
        if [ "${entry%%|*}" == "$plugin" ]; then
            printf '%s' "$entry"
            return 0
        fi
    done
    return 1
}

# acme_provider_label <插件名>
# 用途：取解析商显示名（未收录时回落为插件名）
# 返回：始终 0，结果打印到 stdout
acme_provider_label() {
    local entry rest
    if entry="$(acme_provider_find "$1")"; then
        rest="${entry#*|}"
        printf '%s' "${rest%%|*}"
    else
        printf '%s' "$1"
    fi
}

# acme_provider_specs <插件名>
# 用途：输出该解析商的字段定义（每行 "变量:标签:必填"）
# 返回：始终 0
acme_provider_specs() {
    local entry
    local -a parts=()
    if entry="$(acme_provider_find "$1")"; then
        IFS='|' read -r -a parts <<< "$entry"
        printf '%s\n' "${parts[@]:2}"
    fi
    return 0
}

# acme_provider_is_default <插件名>
# 用途：判断是否属于默认解析商（有内置凭据校验逻辑）
# 返回：0 = 是；1 = 否
acme_provider_is_default() {
    local p
    for p in "${ACME_DEFAULT_PROVIDERS[@]}"; do
        [ "$p" == "$1" ] && return 0
    done
    return 1
}

# acme_provider_installed <插件名>
# 用途：判断 acme.sh 是否已安装该 DNS 插件
# 返回：0 = 已安装；1 = 未安装
acme_provider_installed() {
    [ -f "${ACME_HOME}/dnsapi/$1.sh" ]
}

# acme_provider_usable_list
# 用途：列出当前环境可用（acme.sh 已安装）且本脚本能自动填字段的解析商
# 输出：每行 "序号|插件名|显示名"
# 返回：始终 0
acme_provider_usable_list() {
    local entry plugin i=0
    for entry in "${ACME_PROVIDER_CATALOG[@]}"; do
        plugin="${entry%%|*}"
        acme_provider_installed "$plugin" || continue
        i=$((i + 1))
        printf '%s|%s|%s\n' "$i" "$plugin" "$(acme_provider_label "$plugin")"
    done
    return 0
}

# acme_provider_credentials_ready <插件名>
# 用途：判断该解析商的必填凭据是否齐全（只检查存在性，不联网）
# 返回：0 = 齐全；1 = 缺失
acme_provider_credentials_ready() {
    local spec var rest req
    while IFS= read -r spec; do
        [ -z "$spec" ] && continue
        var="${spec%%:*}"
        rest="${spec#*:}"
        req="${rest##*:}"
        [ "$req" == "1" ] || continue
        [ -n "${!var:-}" ] || return 1
    done < <(acme_provider_specs "$1")
    return 0
}

# acme_provider_missing_vars <插件名>
# 用途：输出缺失的必填变量名（空格分隔）
# 返回：始终 0
acme_provider_missing_vars() {
    local spec var rest req missing=()
    while IFS= read -r spec; do
        [ -z "$spec" ] && continue
        var="${spec%%:*}"
        rest="${spec#*:}"
        req="${rest##*:}"
        [ "$req" == "1" ] || continue
        [ -n "${!var:-}" ] || missing+=("$var")
    done < <(acme_provider_specs "$1")
    printf '%s' "${missing[*]}"
    return 0
}

# ==========================================
# 按域名加密凭据库
# ==========================================

# acme_cred_store_init
# 用途：初始化凭据库目录与 AES 主密钥（首次使用时生成，权限 600）
# 返回：0 = 就绪；1 = 失败（缺少 openssl 或目录不可写）
acme_cred_store_init() {
    if ! command -v openssl >/dev/null 2>&1; then
        red "缺少 openssl，无法加密保存 DNS 凭据"
        return 1
    fi
    mkdir -p "$ACME_CRED_STORE_DIR" "$ACME_CRED_STORE_DOMAINS" 2>/dev/null || {
        red "无法创建凭据库目录: $ACME_CRED_STORE_DIR"
        return 1
    }
    chmod 700 "$ACME_CRED_STORE_DIR" "$ACME_CRED_STORE_DOMAINS" 2>/dev/null || true
    if [ ! -s "$ACME_CRED_STORE_KEY" ]; then
        if ! ( umask 077; openssl rand -hex 32 > "$ACME_CRED_STORE_KEY" ); then
            red "生成凭据库主密钥失败: $ACME_CRED_STORE_KEY"
            return 1
        fi
        chmod 600 "$ACME_CRED_STORE_KEY" 2>/dev/null || true
        yellow "已生成凭据库主密钥: $ACME_CRED_STORE_KEY（权限 600；丢失将无法解密已保存凭据）"
    fi
    return 0
}

# acme_cred_store_file <根域名>
# 用途：计算该域名的凭据文件名（域名维度隔离）
# 返回：始终 0，路径打印到 stdout
acme_cred_store_file() {
    local root="${1,,}"
    printf '%s/%s.cred' "$ACME_CRED_STORE_DOMAINS" "${root//[!a-zA-Z0-9._-]/_}"
}

# acme_cred_store_exists <根域名>
# 返回：0 = 已保存；1 = 未保存
acme_cred_store_exists() {
    [ -s "$(acme_cred_store_file "$1")" ]
}

# acme_cred_store_save <根域名> <插件名> <变量=值>...
# 用途：加密保存该域名的解析商凭据（覆盖同域名旧记录，不影响其他域名）
# 返回：0 = 成功；1 = 失败
acme_cred_store_save() {
    local root="$1" plugin="$2" file tmp kv var val
    shift 2
    acme_cred_store_init || return 1
    file="$(acme_cred_store_file "$root")"
    tmp="$(umask 077; mktemp "${ACME_CRED_STORE_DOMAINS}/.tmp.XXXXXX")" || {
        red "创建临时凭据文件失败"
        return 1
    }
    if ! {
        printf 'FORMAT=1\n'
        printf 'DOMAIN=%s\n' "$root"
        printf 'PROVIDER=%s\n' "$plugin"
        printf 'UPDATED=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for kv in "$@"; do
            var="${kv%%=*}"
            val="${kv#*=}"
            [ -n "$var" ] || continue
            printf 'F\t%s\t%s\n' "$var" "$val"
        done
    } | openssl enc "-${ACME_CRED_CIPHER}" -salt -pbkdf2 -iter "$ACME_CRED_KDF_ITER" \
            -pass "file:${ACME_CRED_STORE_KEY}" -out "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        red "加密保存凭据失败: $file"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        red "写入凭据文件失败: $file"
        return 1
    fi
    green "已加密保存 ${root} 的解析商凭据（${plugin}）：${file}"
    return 0
}

# acme_cred_store_load <根域名>
# 用途：解密并导出该域名保存的凭据，设置 ACME_LOADED_PROVIDER / ACME_LOADED_VARS
# 返回：0 = 成功；1 = 未保存或解密失败
acme_cred_store_load() {
    local root="$1" file line plain rest var val
    file="$(acme_cred_store_file "$root")"
    ACME_LOADED_PROVIDER=""
    ACME_LOADED_VARS=()
    [ -s "$file" ] || return 1
    if [ ! -r "$ACME_CRED_STORE_KEY" ]; then
        yellow "凭据库主密钥不可读，无法解密已保存凭据: $ACME_CRED_STORE_KEY"
        return 1
    fi
    if ! plain="$(openssl enc -d "-${ACME_CRED_CIPHER}" -pbkdf2 -iter "$ACME_CRED_KDF_ITER" \
            -pass "file:${ACME_CRED_STORE_KEY}" -in "$file" 2>/dev/null)"; then
        yellow "已保存凭据解密失败（主密钥可能已变更）: $file"
        return 1
    fi
    while IFS= read -r line; do
        if [[ "$line" == PROVIDER=* ]]; then
            ACME_LOADED_PROVIDER="${line#PROVIDER=}"
        elif [[ "$line" == F$'\t'* ]]; then
            rest="${line#F$'\t'}"
            var="${rest%%$'\t'*}"
            val="${rest#*$'\t'}"
            [ "$var" == "$rest" ] && continue
            if [ -z "${ACME_CRED_SHADOW[$var]+x}" ]; then
                if [ -n "${!var+x}" ]; then
                    ACME_CRED_SHADOW[$var]="=${!var}"
                else
                    ACME_CRED_SHADOW[$var]="-"
                fi
            fi
            printf -v "$var" '%s' "$val"
            export "$var"
            ACME_LOADED_VARS+=("$var")
        fi
    done <<< "$plain"
    [ -n "$ACME_LOADED_PROVIDER" ] || return 1
    return 0
}

# acme_cred_store_unset
# 用途：撤销上一次从凭据库加载的变量，恢复加载前的值（系统环境 / 私有 env 的默认凭据），
#       避免按域名凭据影响后续域名
# 返回：始终 0
acme_cred_store_unset() {
    local v saved
    for v in "${!ACME_CRED_SHADOW[@]}"; do
        saved="${ACME_CRED_SHADOW[$v]}"
        if [ "$saved" == "-" ]; then
            unset "$v"
        else
            printf -v "$v" '%s' "${saved#=}"
            export "$v"
        fi
    done
    ACME_CRED_SHADOW=()
    ACME_LOADED_VARS=()
    ACME_LOADED_PROVIDER=""
    return 0
}

# acme_cred_store_delete <根域名>
# 用途：删除该域名的已保存凭据（其他域名不受影响）
# 返回：0 = 成功或本就不存在；1 = 删除失败
acme_cred_store_delete() {
    local root="$1" file
    file="$(acme_cred_store_file "$root")"
    if [ ! -s "$file" ]; then
        yellow "未找到 ${root} 的已保存凭据"
        return 0
    fi
    if rm -f "$file"; then
        green "已删除 ${root} 的已保存凭据: $file"
        return 0
    fi
    red "删除失败: $file"
    return 1
}

# acme_cred_store_list [--domains-only]
# 用途：列出凭据库中已保存的域名与解析商
# 返回：始终 0
acme_cred_store_list() {
    local mode="${1:-}" file line provider domain updated found=0
    if [ ! -d "$ACME_CRED_STORE_DOMAINS" ]; then
        [ "$mode" == "--domains-only" ] || yellow "凭据库为空: $ACME_CRED_STORE_DOMAINS"
        return 0
    fi
    for file in "$ACME_CRED_STORE_DOMAINS"/*.cred; do
        [ -s "$file" ] || continue
        found=1
        provider=""
        domain=""
        updated=""
        while IFS= read -r line; do
            case "$line" in
                PROVIDER=*) provider="${line#PROVIDER=}" ;;
                DOMAIN=*)   domain="${line#DOMAIN=}" ;;
                UPDATED=*)  updated="${line#UPDATED=}" ;;
            esac
        done < <(openssl enc -d "-${ACME_CRED_CIPHER}" -pbkdf2 -iter "$ACME_CRED_KDF_ITER" \
                    -pass "file:${ACME_CRED_STORE_KEY}" -in "$file" 2>/dev/null)
        [ -n "$domain" ] || continue
        if [ "$mode" == "--domains-only" ]; then
            printf '%s\n' "$domain"
        else
            printf '  %-28s %-14s %s\n' "$domain" "${provider:-?}" "${updated:-?}"
        fi
    done
    if [ "$mode" != "--domains-only" ] && [ "$found" -eq 0 ]; then
        yellow "凭据库为空: $ACME_CRED_STORE_DOMAINS"
    fi
    return 0
}

# acme_mask_secret <值>
# 用途：输出脱敏后的凭据（仅保留前 4 位与后 2 位），绝不打印完整密钥
acme_mask_secret() {
    local v="${1:-}"
    if [[ -z "$v" ]]; then
        printf '未设置'
        return 0
    fi
    if (( ${#v} <= 8 )); then
        printf '****（长度 %d）' "${#v}"
        return 0
    fi
    printf '%s****%s（长度 %d）' "${v:0:4}" "${v: -2}" "${#v}"
}

# acme_credential_origin <变量名>
# 用途：判定凭据实际来源（按域名保存 / 系统环境变量 / 私有 env 文件）
# 返回：始终 0，来源文案打印到 stdout
acme_credential_origin() {
    local name="$1" v
    for v in "${ACME_LOADED_VARS[@]}"; do
        if [ "$v" == "$name" ]; then
            printf '按域名保存的凭据'
            return 0
        fi
    done
    if [ -n "${ACME_ENV_SNAPSHOT[$name]:-}" ]; then
        printf '系统环境变量'
    elif [ -n "${!name:-}" ]; then
        printf '私有 env 文件'
    else
        printf '未设置'
    fi
    return 0
}

# acme_detect_ns_provider <根域名>
# 用途：按 NS 记录识别解析商（只识别默认解析商，非默认仅给出提示）
# 返回：0 = 识别成功（插件名打印到 stdout）；1 = 未能识别
acme_detect_ns_provider() {
    local root="$1" ns_list="" provider="" hint=""
    if ns_list="$(acme_query_ns "$root")"; then
        yellow "域名 ${root} 的 NS 记录：$(printf '%s' "$ns_list" | tr '\n' ' ')" >&2
        if provider="$(printf '%s\n' "$ns_list" | acme_provider_from_ns)"; then
            printf '%s' "$provider"
            return 0
        fi
        hint="$(printf '%s\n' "$ns_list" | acme_ns_family_hint)" || hint=""
        if [ -n "$hint" ]; then
            yellow "检测到解析商：${hint}（不属于默认配置，可手动配置其 API 凭据）" >&2
        else
            yellow "未能从 NS 识别出解析商" >&2
        fi
    else
        yellow "无法查询 ${root} 的 NS 记录（DNS 不可用或被拦截）" >&2
    fi
    return 1
}

# acme_prompt_credential_value <变量名> <标签> <必填 1|0>
# 用途：提示输入单项凭据，做非空与格式校验，不通过则重新输入
# 结果：读取到的值写入全局 ACME_PROMPT_VALUE（可留空）
# 返回：0 = 成功；1 = 取消或输入流结束
acme_prompt_credential_value() {
    local var="$1" label="$2" required="$3" val="" pattern prompt
    ACME_PROMPT_VALUE=""
    pattern='^[^[:space:]]{6,}$'
    case "$var" in
        *SOURCEIP*)   pattern='^[0-9]{1,3}(\.[0-9]{1,3}){3}$' ;;
        *ACCOUNT_ID*) pattern='^[A-Za-z0-9._-]{4,}$' ;;
    esac
    while :; do
        prompt="  ${label}（${var}"
        [ "$required" == "0" ] && prompt+="，可留空跳过"
        prompt+="）: "
        if ! read -r -p "$(yellow "$prompt")" val; then
            return 1
        fi
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        if [ -z "$val" ]; then
            if [ "$required" == "0" ]; then
                ACME_PROMPT_VALUE=""
                return 0
            fi
            red "  ${var} 不能为空，请重新输入"
            continue
        fi
        if [[ ! "$val" =~ $pattern ]]; then
            red "  格式不正确（不允许空格或制表符，长度至少 6 位），请重新输入"
            continue
        fi
        ACME_PROMPT_VALUE="$val"
        return 0
    done
}

# acme_configure_dns_credentials <根域名>
# 用途：列出可用解析商 → 逐项输入并校验 key/secret → 按域名加密保存并立即生效
# 返回：0 = 配置完成；1 = 取消或失败
acme_configure_dns_credentials() {
    local root="$1"
    local line idx rest plugin label sel chosen="" spec var lbl req val prompt
    local -a list_lines=() declared=() specs=()
    local attempt=0

    acme_cred_store_init || return 1

    while IFS= read -r line; do
        [ -n "$line" ] && list_lines+=("$line")
    done < <(acme_provider_usable_list)

    if [ ${#list_lines[@]} -eq 0 ]; then
        red "未在 ${ACME_HOME}/dnsapi/ 找到可用的 DNS 插件，无法手动配置"
        yellow "请先在菜单 2 安装/升级 acme.sh，或确认 dnsapi 目录存在"
        return 1
    fi

    echo
    blue "========== 当前支持的 DNS 解析商 =========="
    for line in "${list_lines[@]}"; do
        idx="${line%%|*}"
        rest="${line#*|}"
        plugin="${rest%%|*}"
        label="${rest#*|}"
        printf '  %2s) %-24s %s\n' "$idx" "$label" "$plugin"
    done
    echo "   0) 取消"
    blue "==========================================="
    yellow "说明：仅列出 acme.sh 已安装且脚本内置字段定义的插件；未列出的插件请改用 HTTP 验证。"

    while :; do
        if ! read -r -p "$(yellow '请选择解析商序号: ')" sel; then
            return 1
        fi
        [ -z "$sel" ] && { red "请输入序号"; continue; }
        [ "$sel" == "0" ] && { yellow "已取消解析商配置"; return 1; }
        for line in "${list_lines[@]}"; do
            if [ "${line%%|*}" == "$sel" ]; then
                rest="${line#*|}"
                chosen="${rest%%|*}"
                break
            fi
        done
        [ -n "$chosen" ] && break
        red "无效序号，请重新输入"
    done

    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        declared=()
        # 先把字段定义读入数组：避免 < <(...) 重定向 stdin 导致凭据输入读到字段行
        specs=()
        while IFS= read -r spec; do
            [ -n "$spec" ] && specs+=("$spec")
        done < <(acme_provider_specs "$chosen")

        echo
        yellow "请输入 $(acme_provider_label "$chosen")（${chosen}）的凭据："
        for spec in "${specs[@]}"; do
            var="${spec%%:*}"
            rest="${spec#*:}"
            lbl="${rest%%:*}"
            req="${rest##*:}"
            acme_prompt_credential_value "$var" "$lbl" "$req" || return 1
            val="$ACME_PROMPT_VALUE"
            if [ -n "$val" ]; then
                declared+=("${var}=${val}")
                printf -v "$var" '%s' "$val"
                export "$var"
            fi
        done

        if [ ${#declared[@]} -eq 0 ]; then
            red "未输入任何凭据，无法保存"
            return 1
        fi

        if acme_validate_provider_credentials "$root" "$chosen"; then
            break
        fi

        red "凭据校验未通过：${ACME_CRED_FAIL_REASON}"
        if [ "$attempt" -ge 3 ]; then
            red "已连续 3 次校验未通过，放弃本次配置"
            return 1
        fi
        prompt="  r) 重新输入    c) 仍保存并继续（跳过在线校验）    0) 取消: "
        if ! read -r -p "$(yellow "$prompt")" sel; then
            return 1
        fi
        case "$sel" in
            r|R) continue ;;
            c|C) break ;;
            *) return 1 ;;
        esac
    done

    acme_cred_store_save "$root" "$chosen" "${declared[@]}" || return 1
    printf -v DNS_NAME '%s' "$chosen"
    return 0
}

# acme_validate_provider_credentials <根域名> <插件名>
# 用途：校验凭据可用性（必填齐全 + Cloudflare 令牌在线校验）
#   阿里云等插件不做本地签名预校验，以避免误判；其失效/权限不足由 acme.sh
#   实际调用返回的错误码识别（见 acme_issue_auth_failed）
# 结果：失败原因写入 ACME_CRED_FAIL_REASON
# 返回：0 = 可用/无法在线校验；2 = 缺项；3 = 无效或无权限
acme_validate_provider_credentials() {
    local root="$1" plugin="$2" out=""
    ACME_CRED_FAIL_REASON=""

    if ! acme_provider_credentials_ready "$plugin"; then
        ACME_CRED_FAIL_REASON="缺少必填凭据：$(acme_provider_missing_vars "$plugin")"
        return 2
    fi

    # 仅 Cloudflare 有稳定可用的令牌校验接口
    if [ "$plugin" != "dns_cf" ]; then
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        yellow "未安装 python3，跳过 ${plugin} 凭据在线校验"
        return 0
    fi

    out="$(PROXY_URL="${PROXY_URL:-}" python3 - "$root" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

root = sys.argv[1]
token = os.environ.get("CF_Token", "").strip()
proxy = os.environ.get("PROXY_URL", "").strip()


def opener():
    if proxy:
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy})
        )
    return urllib.request.build_opener()


def finish(kind, msg, code):
    print("%s:%s" % (kind, msg))
    sys.exit(code)


if not token:
    finish("MISSING", "CF_Token", 3)

url = "https://api.cloudflare.com/client/v4/zones?name=" + urllib.parse.quote(root)
try:
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token,
                                              "Accept": "application/json"})
    with opener().open(req, timeout=12) as resp:
        data = json.loads(resp.read().decode("utf-8", "replace"))
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", "replace")[:200]
    finish("INVALID", "HTTP %s %s" % (exc.code, body), 4)
except Exception as exc:
    finish("UNKNOWN", str(exc)[:200], 5)

if not data.get("success"):
    finish("INVALID", json.dumps(data.get("errors", []), ensure_ascii=False)[:200], 4)
result = data.get("result") or []
if not result:
    finish("INVALID", "token 有效但无权读取 %s 的 DNS 区域" % root, 4)
finish("OK", result[0].get("name", root), 0)
PY
)" || true

    case "$out" in
        OK:*)
            green "凭据在线校验通过（${out#OK:}）"
            return 0
            ;;
        MISSING:*)
            ACME_CRED_FAIL_REASON="缺少必填凭据：${out#MISSING:}"
            return 2
            ;;
        INVALID:*)
            ACME_CRED_FAIL_REASON="凭据无效或权限不足：${out#INVALID:}"
            return 3
            ;;
        *)
            yellow "凭据在线校验跳过（网络不可达或接口异常）"
            return 0
            ;;
    esac
}

# acme_handle_credential_failure <根域名> <插件名> <原因>
# 用途：凭据不可用时中止 DNS 流程，给出"HTTP 验证 / 手动配置解析商"两个选项
# 结果：选择 HTTP 时设置 ACME_VERIFY_MODE=http；选择手动配置时写入凭据库并保持 dns
# 返回：0 = 已选择后续方案；1 = 中止
acme_handle_credential_failure() {
    local root="$1" plugin="$2" reason="$3" sel=""
    ACME_VERIFY_MODE="dns"

    echo
    red "❌ DNS 解析商凭据不可用，已停止当前 DNS 验证流程"
    white "  域名：  ${root}"
    if [ -n "$plugin" ]; then
        white "  解析商：${plugin}（$(acme_provider_label "$plugin")）"
    else
        white "  解析商：未识别"
    fi
    white "  原因：  ${reason}"

    if [ ! -t 0 ]; then
        red "当前为非交互环境，无法选择后续处理方式；请修复凭据后重试"
        return 1
    fi

    echo
    yellow "请选择后续处理方式："
    echo "  1) 改用 HTTP 方式继续验证（不需要任何 DNS 凭据）"
    echo "  2) 手动配置其他 DNS 解析商（凭据按域名加密保存，后续自动复用）"
    echo "  0) 中止本次签发"
    while :; do
        if ! read -r -p "$(yellow '请输入序号: ')" sel; then
            return 1
        fi
        case "$sel" in
            1)
                ACME_VERIFY_MODE="http"
                green "已切换为 HTTP 验证方式"
                return 0
                ;;
            2)
                if acme_configure_dns_credentials "$root"; then
                    ACME_VERIFY_MODE="dns"
                    return 0
                fi
                yellow "未完成解析商配置，请重新选择处理方式"
                ;;
            0|"")
                red "已中止本次签发"
                return 1
                ;;
            *)
                red "无效序号，请重新输入"
                ;;
        esac
    done
}

# acme_prepare_issue_proxy
# 用途：判断服务器 IP 归属，决定签发时是否走代理（保持原有行为）
# 结果：设置全局 USE_PROXY
# 返回：始终 0
acme_prepare_issue_proxy() {
    USE_PROXY=false
    [ -f "${HOME}/.acme.sh/acme.sh" ] || return 0

    if [ ! -f "${ACME_SCRIPT_DIR}/get_ipaddr_state.py" ]; then
        cat > "${ACME_SCRIPT_DIR}/get_ipaddr_state.py" << 'EOF'
#!/usr/bin/env python
#coding:utf-8
import sys,socket,json

if sys.version_info[0] == 2:
  import urllib2 as request
else:
  import urllib.request as request

try:
  socket.setdefaulttimeout(5)
  if len(sys.argv) == 1:
    apiurl = "http://ip-api.com/json"
  elif len(sys.argv) == 2:
    apiurl = "http://ip-api.com/json/%s" % sys.argv[1]
  content = request.urlopen(apiurl).read().decode('utf-8')
  content = json.JSONDecoder().decode(content)
  if content['status'] == 'success':
    print(content['countryCode'])
  else:
    print("CN")
except:
  print("Usage:%s IP" % sys.argv[0])
EOF
        chmod +x "${ACME_SCRIPT_DIR}/get_ipaddr_state.py" 2>/dev/null || true
    fi
    local country_code=""
    country_code="$(python3 "${ACME_SCRIPT_DIR}/get_ipaddr_state.py" 2>/dev/null || true)"
    yellow "当前服务器IP所在国家/地区代码: ${country_code:-未知}"
    if [ "$country_code" == "CN" ]; then
        yellow "服务器IP在中国，即将使用代理执行acme.sh"
        USE_PROXY=true
    fi
    return 0
}

# ==========================================
# 免费证书颁发机构（CA）目录与自动选择
# ==========================================
# 目录依据 acme.sh 源码中的 CA 定义与其对 EAB 的处理方式确定：
#   - letsencrypt / letsencrypt_test：无需 EAB
#   - zerossl：acme.sh 可用注册邮箱自动换取 EAB（无需人工申请）
#   - actalis / sslcom / google：需在 CA 控制台申请 EAB（--eab-kid / --eab-hmac-key）
# 格式：键|acme.sh --server 短名|显示名|目录 URL|EAB 类型(no/auto/manual)|优先级
ACME_CA_CATALOG=(
    'letsencrypt|letsencrypt|Let'"'"'s Encrypt|https://acme-v02.api.letsencrypt.org/directory|no|10'
    'zerossl|zerossl|ZeroSSL|https://acme.zerossl.com/v2/DV90|auto|20'
    'actalis|actalis|Actalis|https://acme-api.actalis.com/acme/directory|manual|30'
    'sslcom|sslcom|SSL.com|https://acme.ssl.com/sslcom-dv-rsa|manual|40'
    'google|google|Google Trust Services|https://dv.acme-v02.api.pki.goog/directory|manual|50'
    'letsencrypt_test|letsencrypt_test|Let'"'"'s Encrypt (测试环境)|https://acme-staging-v02.api.letsencrypt.org/directory|no|90'
)

# 默认候选顺序：只需按优先级取可达且无需人工 EAB 的 CA
ACME_CA_AUTO_ORDER=(letsencrypt zerossl actalis sslcom google)

# acme_ca_entry <短名>
# 用途：从 CA 目录取完整条目
# 返回：0 = 命中（条目打印到 stdout）；1 = 未收录
acme_ca_entry() {
    local want="$1" entry rest
    for entry in "${ACME_CA_CATALOG[@]}"; do
        rest="${entry#*|}"
        if [ "${rest%%|*}" == "$want" ]; then
            printf '%s' "$entry"
            return 0
        fi
    done
    return 1
}

# acme_ca_field <短名> <字段序号>
# 用途：取该 CA 的某个字段
#   1=键 2=acme.sh 短名 3=显示名 4=目录 URL 5=EAB 类型 6=优先级
# 返回：0 = 成功；1 = 未收录或字段不存在
acme_ca_field() {
    local entry="" idx="${2}" i=1 rest=""
    entry="$(acme_ca_entry "$1")" || return 1
    [ -n "$entry" ] || return 1
    rest="$entry"
    while [ "$i" -lt "$idx" ]; do
        rest="${rest#*|}"
        i=$((i + 1))
    done
    printf '%s' "${rest%%|*}"
    return 0
}

# acme_ca_label <短名>
# 用途：CA 显示名（未收录时回落为短名）
acme_ca_label() {
    acme_ca_field "$1" 3 2>/dev/null || printf '%s' "$1"
}

# acme_ca_eab_type <短名>
# 用途：判断 EAB 需求（no/auto/manual）
acme_ca_eab_type() {
    acme_ca_field "$1" 5 2>/dev/null || printf 'manual'
}

# acme_ca_directory <短名>
# 用途：取 CA 目录 URL
acme_ca_directory() {
    acme_ca_field "$1" 4 2>/dev/null
}

# acme_ca_supported <短名>
# 用途：确认本机 acme.sh 认识该 --server 短名（读 acme.sh 源码的 CA_NAMES 定义）
# 返回：0 = 支持；1 = 不支持或 acme.sh 未安装
acme_ca_supported() {
    local short="$1"
    [ -f "$ACME_SH_BIN" ] || return 1
    grep -qE "(^|,|\")${short}(,|\"|$)" "$ACME_SH_BIN" 2>/dev/null
}

# acme_ca_reachable <短名>
# 用途：探测 CA 目录接口是否可达（不发起任何注册或签发）
# 返回：0 = 可达；1 = 不可达
acme_ca_reachable() {
    local url code=""
    url="$(acme_ca_directory "$1")"
    [ -n "$url" ] || return 1
    command -v curl >/dev/null 2>&1 || return 0
    local -a cargs=(-s -o /dev/null -w '%{http_code}' -m 8 -L)
    if [ "${USE_PROXY:-false}" == "true" ] && [ -n "${PROXY_URL:-}" ]; then
        cargs+=(--proxy "$PROXY_URL")
    fi
    code="$(curl "${cargs[@]}" "$url" 2>/dev/null)" || code=""
    [[ "$code" =~ ^[23] ]]
}

# acme_ca_from_existing <域名>
# 用途：读取 acme.sh 已保存证书配置中的 CA（用于续签保持一致）
# 返回：0 = 命中（短名打印到 stdout）；1 = 未找到
acme_ca_from_existing() {
    local domain="$1" conf url key
    local -a cands=("${ACME_HOME}/${domain}_ecc/${domain}.conf" "${ACME_HOME}/${domain}/${domain}.conf")
    for conf in "${cands[@]}"; do
        [ -s "$conf" ] || continue
        url="$(grep -m1 "^Le_API=" "$conf" 2>/dev/null | sed -e "s/^Le_API=//" -e "s/[\"']//g")"
        [ -n "$url" ] || continue
        for key in "${ACME_CA_AUTO_ORDER[@]}" letsencrypt_test; do
            if [ "$(acme_ca_directory "$key")" == "$url" ]; then
                printf '%s' "$key"
                return 0
            fi
        done
    done
    return 1
}

# acme_ca_recent_issue <域名> <天数>
# 用途：判断该域名在 N 天内是否已由本机签发过证书（用于规避 CA 重复签发限额）
# 返回：0 = 近期已签发；1 = 否
acme_ca_recent_issue() {
    local domain="$1" days="${2:-7}" file
    for file in "${ACME_HOME}/${domain}_ecc/${domain}.cer" "${ACME_HOME}/${domain}/${domain}.cer"; do
        [ -e "$file" ] || continue
        if [ -n "$(find "$file" -mtime "-${days}" 2>/dev/null)" ]; then
            return 0
        fi
    done
    return 1
}

# acme_ca_has_eab <短名>
# 用途：判断该 CA 是否已具备 EAB 凭据（环境变量 ACME_EAB_* 或 acme.sh 已保存的 CA 配置）
#   acme.sh 把 CA 配置存于 $ACME_HOME/ca/<目录主机>/<目录路径>/ca.conf
# 返回：0 = 具备；1 = 不具备
acme_ca_has_eab() {
    local short="$1" url host path conf
    [ -n "${ACME_EAB_KID:-}" ] && [ -n "${ACME_EAB_HMAC_KEY:-}" ] && return 0
    url="$(acme_ca_directory "$short")" || return 1
    [ -n "$url" ] || return 1
    host="${url#https://}"
    host="${host%%/*}"
    path="${url#https://${host}}"
    path="${path#/}"
    path="${path%%\?*}"
    conf="${ACME_HOME}/ca/${host}/${path}/ca.conf"
    [ -s "$conf" ] && grep -q "^CA_EAB_KEY_ID=" "$conf" 2>/dev/null
}

# acme_select_ca <域名>
# 用途：自动评估并选择最合适的免费 CA
#   顺序：1) 已签发过 → 沿用原 CA（续签一致）
#         2) 近期已签发过 → 优先备用 CA（规避重复签发限额）
#         3) 按优先级取"本机支持 + 接口可达 + 无需人工 EAB"的首个
# 结果：设置 CERT_SERVER / ACME_CA_KEY / ACME_CA_REASON
# 返回：0 = 选定；1 = 无可用 CA
acme_select_ca() {
    local domain="$1"
    local key="" reason="" existing="" candidate=""
    local -a pool=()

    CERT_SERVER=""
    ACME_CA_KEY=""
    ACME_CA_REASON=""

    # 显式覆盖：环境变量 ACME_CA 优先（值是 acme.sh 的 --server 短名）
    if [ -n "${ACME_CA:-}" ]; then
        if acme_ca_supported "${ACME_CA}"; then
            ACME_CA_KEY="${ACME_CA}"
            CERT_SERVER="${ACME_CA}"
            ACME_CA_REASON="由环境变量 ACME_CA 指定"
            return 0
        fi
        red "环境变量 ACME_CA=${ACME_CA} 不受本机 acme.sh 支持"
        return 1
    fi

    # 1) 沿用已有证书的 CA
    if existing="$(acme_ca_from_existing "$domain")" && acme_ca_supported "$existing"; then
        ACME_CA_KEY="$existing"
        CERT_SERVER="$existing"
        ACME_CA_REASON="检测到该域名已由 $(acme_ca_label "$existing") 签发，续签沿用同一 CA"
        return 0
    fi

    # 2) 组装候选池：支持 + 无需人工 EAB（或已具备 EAB）
    for candidate in "${ACME_CA_AUTO_ORDER[@]}"; do
        [[ "$candidate" == "letsencrypt_test" ]] && continue
        acme_ca_supported "$candidate" || continue
        case "$(acme_ca_eab_type "$candidate")" in
            no|auto) ;;
            manual) acme_ca_has_eab "$candidate" || continue ;;
        esac
        pool+=("$candidate")
    done

    if [ ${#pool[@]} -eq 0 ]; then
        red "本机 acme.sh 没有可用的免费 CA（请先安装/升级 acme.sh）"
        return 1
    fi

    # 3) 近期已签发过 → 把首选 CA 轮换到末尾，规避重复签发限额
    if acme_ca_recent_issue "$domain" 7 && [ ${#pool[@]} -gt 1 ]; then
        candidate="${pool[0]}"
        pool=("${pool[@]:1}" "$candidate")
        reason="该域名 7 天内已签发过证书，优先使用备用 CA 以规避重复签发限额；"
    fi

    # 4) 取首个可达者
    for candidate in "${pool[@]}"; do
        if acme_ca_reachable "$candidate"; then
            ACME_CA_KEY="$candidate"
            CERT_SERVER="$candidate"
            ACME_CA_REASON="${reason}选择 $(acme_ca_label "$candidate")（接口可达、本机 acme.sh 支持）"
            return 0
        fi
        yellow "$(acme_ca_label "$candidate") 接口不可达，跳过"
    done

    # 5) 全部不可达时退回首个候选，让 acme.sh 给出真实错误
    candidate="${pool[0]}"
    ACME_CA_KEY="$candidate"
    CERT_SERVER="$candidate"
    ACME_CA_REASON="${reason}所有候选 CA 接口探测均失败，回退到 $(acme_ca_label "$candidate") 由 acme.sh 实测"
    return 0
}

# acme_ca_next_candidates <当前短名>
# 用途：签发失败时给出可回退的备用 CA 列表（每行一个，已排除当前 CA）
# 返回：始终 0
acme_ca_next_candidates() {
    local current="$1" candidate
    for candidate in "${ACME_CA_AUTO_ORDER[@]}"; do
        [ "$candidate" == "$current" ] && continue
        acme_ca_supported "$candidate" || continue
        case "$(acme_ca_eab_type "$candidate")" in
            no|auto) ;;
            manual) acme_ca_has_eab "$candidate" || continue ;;
        esac
        printf '%s\n' "$candidate"
    done
    return 0
}

# acme_issue_rate_limited <日志文件>
# 用途：判断签发失败是否由 CA 限额/重复签发引起
# 返回：0 = 是；1 = 否
acme_issue_rate_limited() {
    local log="${1:-}"
    [ -s "$log" ] || return 1
    grep -qiE 'too many certificates|rateLimited|rate limit|too many failed|duplicate certificate' "$log"
}

# acme_run_acme_to_log <日志文件> <acme.sh 参数...>
# 用途：按代理策略执行 acme.sh，并把输出同时写日志与终端
# 返回：acme.sh 的退出码
acme_run_acme_to_log() {
    local log="$1" rc=0
    shift
    if [ "${USE_PROXY:-false}" == "true" ] && [ -n "${CURL_PROXY_ARG:-}" ]; then
        ALL_PROXY="$CURL_PROXY_ARG" "$ACME_SH_BIN" "$@" 2>&1 | tee "$log"
        rc=${PIPESTATUS[0]}
    elif [ "${USE_PROXY:-false}" == "true" ] && command -v proxychains >/dev/null 2>&1; then
        yellow "使用 proxychains 执行 acme.sh"
        proxychains -q "$ACME_SH_BIN" "$@" 2>&1 | tee "$log"
        rc=${PIPESTATUS[0]}
    else
        "$ACME_SH_BIN" "$@" 2>&1 | tee "$log"
        rc=${PIPESTATUS[0]}
    fi
    return "$rc"
}

# acme_issue_dns <域名> <插件名>
# 用途：以 DNS API 方式签发（结果日志路径写入 ACME_LAST_ISSUE_LOG）
#   统一带上注册邮箱：ZeroSSL 需用邮箱自动换取 EAB，Other CA 也用于账号找回
# 返回：acme.sh 的退出码
acme_issue_dns() {
    local domain="$1" plugin="$2" log rc=0
    log="$(mktemp -t acme-dns-XXXXXX)" || return 1
    yellow "签发方式：DNS API（${plugin}），CA：$(acme_ca_label "${ACME_CA_KEY:-$CERT_SERVER}")"
    acme_run_acme_to_log "$log" --server "$CERT_SERVER" --issue --keylength ec-256 \
        --dns "$plugin" -m "$EMAIL" --force -d "$domain"
    rc=$?
    ACME_LAST_ISSUE_LOG="$log"
    return "$rc"
}

# acme_issue_auth_failed <日志文件>
# 用途：判断签发失败是否由凭据无效/权限不足引起，并把错误行写入 ACME_LAST_AUTH_ERROR
# 返回：0 = 是凭据类失败；1 = 其他原因
acme_issue_auth_failed() {
    local log="${1:-}" line="" pattern
    ACME_LAST_AUTH_ERROR=""
    [ -s "$log" ] || return 1
    pattern='InvalidAccessKeyId|SignatureDoesNotMatch|InvalidAccessKeySecret|InvalidAccessKey|Forbidden|Unauthorized|AccessDenied|InvalidToken|Invalid API Token|Invalid request headers|Authentication error|DomainNotExist|InvalidDomainName|NoSuchDomain|not authorized|permission denied'
    grep -qiE "$pattern" "$log" || return 1
    line="$(grep -iE "$pattern" "$log" | tail -n 1)"
    line="$(printf '%s' "$line" | sed -e $'s/\033\\[[0-9;]*m//g')"
    ACME_LAST_AUTH_ERROR="${line:0:240}"
    return 0
}

# acme_http_choose_mode
# 用途：选择 HTTP 验证方式（webroot 或 standalone）并校验目录可用性
# 结果：设置 ACME_HTTP_MODE / ACME_HTTP_WEBROOT_DIR
# 返回：0 = 选定；1 = 取消或不可用
acme_http_choose_mode() {
    local cand="" c path="" sel=""
    ACME_HTTP_MODE=""
    ACME_HTTP_WEBROOT_DIR=""

    if [ -n "${ACME_HTTP_WEBROOT:-}" ]; then
        if [ -d "$ACME_HTTP_WEBROOT" ] && [ -w "$ACME_HTTP_WEBROOT" ]; then
            ACME_HTTP_MODE="webroot"
            ACME_HTTP_WEBROOT_DIR="$ACME_HTTP_WEBROOT"
            return 0
        fi
        red "ACME_HTTP_WEBROOT 不可用或不可写: $ACME_HTTP_WEBROOT"
    fi

    for c in /data/wwwroot /var/www/html /usr/share/nginx/html "${ACME_SCRIPT_DIR}/www"; do
        if [ -d "$c" ] && [ -w "$c" ]; then
            cand="$c"
            break
        fi
    done

    if [ ! -t 0 ]; then
        if [ -n "$cand" ]; then
            ACME_HTTP_MODE="webroot"
            ACME_HTTP_WEBROOT_DIR="$cand"
            return 0
        fi
        red "非交互环境下未找到可用站点根目录，无法执行 HTTP 验证"
        return 1
    fi

    echo
    yellow "HTTP 验证要求站点根目录下的 /.well-known/acme-challenge/ 可被公网访问"
    [ -n "$cand" ] && white "  已自动检测到候选目录: $cand"
    if [ -n "$cand" ]; then
        echo "  1) 使用站点根目录 $cand"
    else
        echo "  1) 自动检测（当前无候选目录）"
    fi
    echo "  2) 手动输入站点根目录"
    echo "  3) acme.sh standalone（自行监听 80 端口，需先释放 80 端口）"
    echo "  0) 取消"
    while :; do
        if ! read -r -p "$(yellow '请输入序号: ')" sel; then
            return 1
        fi
        case "$sel" in
            1)
                path="$cand"
                [ -z "$path" ] && read -r -p "$(yellow '请输入站点根目录（如 /data/wwwroot）: ')" path
                path="${path%/}"
                if [ -n "$path" ] && [ -d "$path" ] && [ -w "$path" ]; then
                    ACME_HTTP_MODE="webroot"
                    ACME_HTTP_WEBROOT_DIR="$path"
                    return 0
                fi
                red "目录不存在或不可写: ${path:-（空）}"
                ;;
            2)
                read -r -p "$(yellow '请输入站点根目录（如 /data/wwwroot）: ')" path
                path="${path%/}"
                if [ -n "$path" ] && [ -d "$path" ] && [ -w "$path" ]; then
                    ACME_HTTP_MODE="webroot"
                    ACME_HTTP_WEBROOT_DIR="$path"
                    return 0
                fi
                red "目录不存在或不可写: ${path:-（空）}"
                ;;
            3)
                ACME_HTTP_MODE="standalone"
                return 0
                ;;
            0|"")
                yellow "已取消 HTTP 验证"
                return 1
                ;;
            *)
                red "无效序号，请重新输入"
                ;;
        esac
    done
}

# acme_issue_http <域名>
# 用途：以 HTTP 方式签发（webroot 或 standalone），不读取任何 DNS 凭据
# 返回：acme.sh 的退出码
acme_issue_http() {
    local domain="$1" log rc=0
    acme_http_choose_mode || return 1
    log="$(mktemp -t acme-http-XXXXXX)" || return 1
    if [ "$ACME_HTTP_MODE" == "webroot" ]; then
        if ! mkdir -p "${ACME_HTTP_WEBROOT_DIR}/.well-known/acme-challenge" 2>/dev/null; then
            red "无法创建验证目录: ${ACME_HTTP_WEBROOT_DIR}/.well-known/acme-challenge"
            rm -f "$log"
            return 1
        fi
        yellow "签发方式：HTTP webroot（${ACME_HTTP_WEBROOT_DIR}），CA：$(acme_ca_label "${ACME_CA_KEY:-$CERT_SERVER}")"
        acme_run_acme_to_log "$log" --server "$CERT_SERVER" --issue --keylength ec-256 \
            --webroot "$ACME_HTTP_WEBROOT_DIR" -m "$EMAIL" --force -d "$domain"
        rc=$?
    else
        yellow "签发方式：HTTP standalone（监听 80 端口），CA：$(acme_ca_label "${ACME_CA_KEY:-$CERT_SERVER}")"
        acme_run_acme_to_log "$log" --server "$CERT_SERVER" --issue --keylength ec-256 \
            --standalone -m "$EMAIL" --force -d "$domain"
        rc=$?
    fi
    ACME_LAST_ISSUE_LOG="$log"
    return "$rc"
}

# 默认域名证书安装路径（可用同名环境变量覆盖，便于测试或自定义部署）
# 仓库内 nginx 容器把 ${仓库}/vhost/nginx_vhost 挂载为 /etc/nginx/conf.d，
# 因此证书实际写入 ${仓库}/vhost/nginx_vhost/certs（不再假设 /srv 软链存在）。
CERT_INSTALL_DOCKER_DIR="${CERT_INSTALL_DOCKER_DIR:-${ACME_SCRIPT_DIR}/vhost/nginx_vhost/certs}"
CERT_INSTALL_DIR="${CERT_INSTALL_DIR:-}"

# acme_require_cert_dir
# 用途：真正需要写入/读取证书文件前，确认证书目录可用（只读子命令不强制）
# 返回：0 = 可用；1 = 不可用（已输出原因与解决办法）
acme_require_cert_dir() {
    if [ -n "$CERT_INSTALL_DIR" ] && [ -d "$CERT_INSTALL_DIR" ]; then
        return 0
    fi
    red "❌ 未找到可用的证书安装目录"
    white "  已检测宿主机路径：/usr/local/nginx/conf/{ssl,certs}、/usr/local/tengine/conf/{ssl,certs}"
    white "  已检测 Docker 路径：${CERT_INSTALL_DOCKER_DIR}"
    yellow "  解决办法（任选其一）："
    yellow "    a) 确认在仓库根目录执行，且 vhost/nginx_vhost/certs 存在（本机即为该路径）"
    yellow "    b) 显式指定：CERT_INSTALL_DIR=/实际路径 ./acme_renew_domain_cert.sh"
    return 1
}

# 优先从宿主机候选路径中查找已存在的目录
candidate_dirs=("/usr/local/nginx/conf/ssl" "/usr/local/nginx/conf/certs" "/usr/local/tengine/conf/ssl" "/usr/local/tengine/conf/certs")
for dir in "${candidate_dirs[@]}"; do
  if [ -d "$dir" ]; then
    CERT_INSTALL_DIR="$dir"
    break
  fi
done

# 宿主机路径未找到时，回落到仓库内的 Docker 证书目录
if [ -z "$CERT_INSTALL_DIR" ]; then
  if [ -d "$CERT_INSTALL_DOCKER_DIR" ]; then
    CERT_INSTALL_DIR="$CERT_INSTALL_DOCKER_DIR"
    green "\n检测到 Docker 环境，证书安装目录: $CERT_INSTALL_DIR\n"
  fi
fi

# 只读子命令（--check-dns / --list-dns-creds / --remove-dns-creds）不在此处退出，
# 留到实际部署/续期时再由 acme_require_cert_dir 报错。
if [ -z "$CERT_INSTALL_DIR" ]; then
  yellow "\n⚠️  暂未找到证书安装目录（已检测宿主机路径及 Docker 路径 $CERT_INSTALL_DOCKER_DIR）"
  yellow "    只读查询可继续使用；签发/部署/续期前需先修正该路径（否则会中止）。\n"
fi

EMAIL=baibaiguanjia@163.com

# [[ $EUID -ne 0 ]] && yellow "请以root模式运行脚本" && exit 1

SUDO=sudo
[ $(id -u) == "0" ] && {
    SUDO=''
}

command_exists() {
	command -v "$1" 2>&1
}

function sys(){
    [ -f /etc/os-release ] && grep -i pretty_name /etc/os-release | cut -d \" -f2 && return
    [ -f /etc/lsb-release ] && grep -i description /etc/lsb-release | cut -d \" -f2 && return
    [ -f /etc/redhat-release ] && awk '{print $0}' /etc/redhat-release && return;
}

case $(uname -m) in
    i386)   osArchitecture="386" ;;
    i686)   osArchitecture="386" ;;
    x86_64) osArchitecture="amd64" ;;
    arm)    dpkg --print-architecture | grep -q "arm64" && osArchitecture="arm64" || osArchitecture="arm" ;;
    aarch64)    dpkg --print-architecture | grep -q "arm64" && osArchitecture="arm64" || osArchitecture="arm" ;;
    * )     osArchitecture="arm" ;;
esac

osCPUText=$(cat /proc/cpuinfo | grep vendor_id | uniq)
if [[ $osCPUText =~ "GenuineIntel" ]]; then
    osCPU="intel"
elif [[ $osCPUText =~ "AMD" ]]; then
    osCPU="amd"
else
    osCPU="unknown"
fi

CPU=$osCPU'-'$osArchitecture

if [ "$(getconf WORD_BIT)" == "32" ] && [ "$(getconf LONG_BIT)" == "64" ]; then
  if [ "${TARGET_ARCH}" == 'aarch64' ]; then
    SYS_ARCH=arm64
    SYS_ARCH_i=aarch64
    SYS_ARCH_n=arm64
  else
    SYS_ARCH=amd64 #openjdk
    SYS_ARCH_i=x86-64 #ioncube
    SYS_ARCH_n=x64 #nodejs
  fi
else
  red "32-bit OS are not supported!"
  kill -9 $$; exit 1;
fi

OS_DETAIL=`sys`         # 输出格式：XeroLinux、Debian GNU/Linux 12 (bookworm)、AlmaLinux 8.8 (Sapphire Caracal)
CURRENT_OS=`grep -w ID /etc/os-release | cut -d \= -f2 | cut -d \" -f2`         # 输出格式：XeroLinux、garuda、debian、centos、rocky、almalinux
CURRENT_OS_VER=`grep -w VERSION_ID /etc/os-release | cut -d \= -f2 | cut -d \" -f2`     # 输出格式：11、12。  比如debian 12,会输出12
# KERNEL_VER=`uname -r | awk -F "-" '{print $1}'`                               # 输出格式： 6.4.12
KERNEL_VER=`uname -r`                                                           # 输出格式： 6.4.12
KERNEL_MAIN=`uname  -r | awk -F . '{print $1}'`                                 # 输出格式： 6
VIRT_TYPE=`systemd-detect-virt`
THREAD=$(grep 'processor' /proc/cpuinfo | sort -u | wc -l)  # CPU盒数

ACME_HOME="${HOME}/.acme.sh"
ACME_SH_BIN="${ACME_HOME}/acme.sh"

# 续期/巡检日志路径（不要再把输出丢进 /dev/null，静默失败无法排查）
if [ -d /var/log ] && { [ -w /var/log ] || [ "$(id -u)" = "0" ]; }; then
    ACME_CRON_LOG="/var/log/acme_cron.log"
    ACME_CHECK_LOG="/var/log/acme_cert_check.log"
else
    ACME_CRON_LOG="${HOME}/acme_cron.log"
    ACME_CHECK_LOG="${HOME}/acme_cert_check.log"
fi
ACME_VER=""
if [ -x "${ACME_SH_BIN}" ]; then
  ACME_VER=$( "${ACME_SH_BIN}" --version | grep -oP 'v\d+\.\d+\.\d+' )
fi

if [[ "${CURRENT_OS}" =~ ^centos$|^redhat$|^red\ hat$|^rocky$|^fedora$|^amazon$|^alibaba$|^aliyun$|^almalinux$ ]]; then
    OS=rhel
    RHEL_VER=`grep -w VERSION_ID /etc/os-release | cut -d \" -f2`
elif [[ "${CURRENT_OS}" =~ ^debian$|^deepin$|^uos$|^raspbian$|^kali$ ]]; then
    OS=debian
    DEBIAN_VER=`grep -w VERSION_ID /etc/os-release | cut -d \" -f2`
elif [[ "${CURRENT_OS}" =~ ^ubuntu$|^linuxmint$|^elementary$ ]]; then
    OS=ubuntu
    UBUNTU_VER=`grep -w VERSION_ID /etc/os-release | cut -d \" -f2`
elif [[ "${CURRENT_OS}" =~ ^XeroLinux$|^Archlinux$|^GarudaLinux$|^endeavouros$|^garuda$ ]]; then
    OS=arch
    ARCH_VER=`grep -w IMAGE_VERSION /etc/os-release | cut -d \= -f2`      # 2023.09
fi

# Check OS Version
if [ ${RHEL_VER} -lt 7 ] >/dev/null 2>&1 || [ ${DEBIAN_VER} -lt 8 ] >/dev/null 2>&1 || [ ${UBUNTU_VER} -lt 16 ] >/dev/null 2>&1; then
    red "Does not support this OS, Please install CentOS 7+,Debian 8+,Ubuntu 16+"
    kill -9 $$
fi

PR=""

if [ ! -z `command_exists proxychains` ]; then
	PR=/usr/bin/proxychains
fi

# ==========================================
# 解析 PROXY_URL，派生各分量及 curl/proxychains 所需变量
# （须在 acme_resolve_proxy_url 之后；从 URL 回填的 USER/PASS 仅供本脚本下游使用）
# ==========================================
PROXY_PROTO=""   # http 或 socks5 / socks5h
PROXY_IP=""
# 注意：下面会覆盖同名 PROXY_PORT/USER/PASS 为「从 URL 解析出的值」；拼装已在 resolve 阶段完成
_ACME_PROXY_PORT=""
_ACME_PROXY_USER=""
_ACME_PROXY_PASS=""
CURL_PROXY_ARG=""          # curl --proxy 参数值
PC_PROXY_TYPE=""           # proxychains 配置中的类型行

if [[ -n "${PROXY_URL:-}" ]]; then
    # 提取协议
    PROXY_PROTO=$(echo "$PROXY_URL" | grep -oP '^[a-z0-9+]+')
    # 去掉协议头
    _proxy_rest=$(echo "$PROXY_URL" | sed 's|^[a-z0-9+]*://||')
    # 提取 user:pass（@前）和 host:port（@后）
    if echo "$_proxy_rest" | grep -q '@'; then
        _proxy_auth=$(echo "$_proxy_rest" | cut -d'@' -f1)
        _proxy_host=$(echo "$_proxy_rest" | cut -d'@' -f2)
        _ACME_PROXY_USER=$(echo "$_proxy_auth" | cut -d':' -f1)
        _ACME_PROXY_PASS=$(echo "$_proxy_auth" | cut -d':' -f2)
    else
        _proxy_host="$_proxy_rest"
    fi
    PROXY_IP=$(echo "$_proxy_host" | cut -d':' -f1)
    _ACME_PROXY_PORT=$(echo "$_proxy_host" | cut -d':' -f2)
    # 下游（proxychains 配置等）仍使用历史变量名
    PROXY_PORT="$_ACME_PROXY_PORT"
    PROXY_USER="$_ACME_PROXY_USER"
    PROXY_PASS="$_ACME_PROXY_PASS"

    # curl 直接支持 http/socks5/socks5h，原样传入即可
    CURL_PROXY_ARG="$PROXY_URL"

    # proxychains 配置行类型：http->http  socks5->socks5
    case "$PROXY_PROTO" in
        http|https)  PC_PROXY_TYPE="http" ;;
        socks5*)     PC_PROXY_TYPE="socks5" ;;
        socks4*)     PC_PROXY_TYPE="socks4" ;;
        *)           PC_PROXY_TYPE="socks5" ;;
    esac
fi


# ==========================================
# 服务器区域检测函数
# ==========================================
detect_server_location() {
    local location=""
    local timeout=8

    # 方法1: 使用ipinfo.io检测
    location=$(timeout $timeout curl -s --connect-timeout 3 "https://ipinfo.io/country" 2>/dev/null | tr -d '\n' || echo "")
    if [[ -n "$location" && "$location" != "Unknown" ]]; then
        echo "$location"
        return 0
    fi

    # 方法2: 使用ip-api.com
    location=$(timeout $timeout curl -s --connect-timeout 3 "http://ip-api.com/line?fields=countryCode" 2>/dev/null | tr -d '\n' || echo "")
    if [[ -n "$location" && "$location" != "Unknown" ]]; then
        echo "$location"
        return 0
    fi

    # 方法3: 检查特定网站的可访问性判断
    if ! timeout 5 curl -s --connect-timeout 3 "https://www.google.com" >/dev/null 2>&1; then
        if timeout 5 curl -s --connect-timeout 3 "https://www.baidu.com" >/dev/null 2>&1; then
            echo "CN"
            return 0
        fi
    fi

    echo "Unknown"
    return 1
}

# ==========================================
# 检测是否在中国大陆
# ==========================================
is_in_china() {
    local location=$(detect_server_location)
    [[ "$location" =~ ^(CN|China|中国)$ ]] && return 0
    return 1
}

# ==========================================
# 直接验证 PROXY_URL 连通性
# 返回 0=可用, 1=不可用, 2=未配置
# ==========================================
check_proxy_config_connectivity() {
    if [[ -z "$CURL_PROXY_ARG" ]]; then
        return 2
    fi

    # 通过代理访问 Google 来验证连通性
    if timeout 10 curl -s --connect-timeout 6 \
        --proxy "$CURL_PROXY_ARG" \
        "https://www.google.com" >/dev/null 2>&1; then
        return 0
    fi

    # 备用：尝试访问 GitHub
    if timeout 10 curl -s --connect-timeout 6 \
        --proxy "$CURL_PROXY_ARG" \
        "https://github.com" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# ==========================================
# 检测 proxychains4 安装状态
# ==========================================
check_proxychains4_installed() {
    if command -v proxychains4 >/dev/null 2>&1; then
        echo "installed"
        return 0
    elif command -v proxychains >/dev/null 2>&1; then
        echo "installed-old"
        return 0
    else
        echo "not-installed"
        return 1
    fi
}

# ==========================================
# 检测 proxychains4 代理连通性
# ==========================================
check_proxychains4_connectivity() {
    local proxy_cmd=""

    # 确定使用哪个命令
    if command -v proxychains4 >/dev/null 2>&1; then
        proxy_cmd="proxychains4"
    elif command -v proxychains >/dev/null 2>&1; then
        proxy_cmd="proxychains"
    else
        echo "not-installed"
        return 1
    fi

    # 测试连接 (尝试连接 Google，静默输出)
    if timeout 8 $proxy_cmd -q curl -s --connect-timeout 3 "https://www.google.com" >/dev/null 2>&1; then
        echo "connected"
        return 0
    else
        echo "failed"
        return 1
    fi
}

# ==========================================
# 获取 proxychains4 配置文件路径
# ==========================================
get_proxychains_config() {
    local config_paths=(
        "/etc/proxychains4.conf"
        "/etc/proxychains.conf"
        "$HOME/.proxychains/proxychains.conf"
    )

    for config in "${config_paths[@]}"; do
        if [[ -f "$config" ]]; then
            echo "$config"
            return 0
        fi
    done

    echo "not-found"
    return 1
}

# ==========================================
# 显示网络环境信息
# ==========================================
show_network_environment_info() {
    local location=$(detect_server_location)
    local in_china=false

    echo ""
    blue "================== 网络环境检测 =================="

    # 显示服务器位置
    if [[ "$location" =~ ^(CN|China|中国)$ ]]; then
        in_china=true
        yellow "📍 服务器位置: 中国大陆 (${location})"
        yellow "⚠️  注意: 在中国大陆访问 Let's Encrypt 等国外服务可能需要使用代理"
    elif [[ "$location" == "Unknown" ]]; then
        white "📍 服务器位置: 未知 (无法检测)"
    else
        green "📍 服务器位置: 海外 (${location})"
        green "✅ 网络访问正常，无需配置代理"
    fi

    # 如果在中国大陆，先验证代理配置，再检测 proxychains4
    if [[ "$in_china" == "true" ]]; then
        echo ""

        # --- 直接验证脚本内配置的代理 ---
        if [[ -n "$CURL_PROXY_ARG" ]]; then
            yellow "🔍 正在验证代理配置可用性 (${PROXY_PROTO}://${PROXY_IP}:${PROXY_PORT})..."
            check_proxy_config_connectivity
            local proxy_check_result=$?
            if [[ $proxy_check_result -eq 0 ]]; then
                green "✅ 代理配置验证成功: ${PROXY_PROTO}://${PROXY_IP}:${PROXY_PORT} 可正常访问外网"
            elif [[ $proxy_check_result -eq 1 ]]; then
                red "❌ 代理配置验证失败: 无法通过 ${PROXY_PROTO}://${PROXY_IP}:${PROXY_PORT} 访问外网"
                yellow "   请检查代理服务器是否正常运行，或检查 BUILD_PROXY_ENABLED / 系统 PROXY_* 后重试。"
            fi
        else
            yellow "⚠️  未启用代理（BUILD_PROXY_ENABLED=false 或 PROXY_* 不完整），国内环境可能无法正常签署证书"
        fi
        echo ""

        local install_status=$(check_proxychains4_installed)

        if [[ "$install_status" == "installed" ]]; then
            green "✅ proxychains4: 已安装"

            # 检测连通性
            local connectivity=$(check_proxychains4_connectivity)
            if [[ "$connectivity" == "connected" ]]; then
                green "✅ 代理连通性: 正常"
            else
                red "❌ 代理连通性: 失败"
                echo ""
                yellow "💡 修复建议:"
                local config_file=$(get_proxychains_config)
                if [[ "$config_file" != "not-found" ]]; then
                    yellow "   1. 检查配置文件: $config_file"
                    yellow "   2. 确认代理服务器配置正确（格式: socks5 IP PORT USER PASSWORD）"
                    yellow "   3. 测试代理连接: proxychains4 curl -I https://www.google.com"
                    yellow "   4. 查看详细日志: proxychains4 -f $config_file curl -v https://www.google.com"
                else
                    yellow "   1. 配置文件未找到，请创建 /etc/proxychains4.conf"
                    yellow "   2. 参考格式:"
                    yellow "      [ProxyList]"
                    yellow "      socks5  PROXY_IP  PROXY_PORT  USER  PASSWORD"
                fi
                echo ""
                yellow "   当前脚本代理配置:"
                yellow "   BUILD_PROXY_ENABLED=${BUILD_PROXY_ENABLED}  PROXY=$(acme_mask_proxy_url "${PROXY_URL:-}")"
            fi
        elif [[ "$install_status" == "installed-old" ]]; then
            yellow "⚠️  proxychains: 已安装旧版本 (建议升级到 proxychains4)"
            yellow "   升级方法: 选择菜单选项 1"
        else
            red "❌ proxychains4: 未安装"
            yellow "💡 安装建议:"
            yellow "   - 选择菜单选项 1 进行安装"
            yellow "   - 或手动安装: "
            case "$OS" in
                debian|ubuntu)
                    yellow "     apt install proxychains4"
                    ;;
                rhel)
                    yellow "     yum install proxychains-ng 或从源码编译"
                    ;;
                arch)
                    yellow "     pacman -S proxychains-ng"
                    ;;
            esac
        fi
    fi

    blue "=================================================="
    echo ""
}

# 域名合法性检查（RFC 1123），失败原因写入 DOMAIN_ERR
# 说明：公共 CA（Let's Encrypt / ZeroSSL / Google Trust / SSL.com 等）拒绝签发含
#       下划线、空格、协议头、路径的域名；本函数在提交签发前拦截，避免浪费 API 调用。
DOMAIN_ERR=""
domain_check() {
  local d="$1"
  DOMAIN_ERR=""
  if [ -z "$d" ]; then DOMAIN_ERR="域名为空"; return 1; fi
  if [[ $d == *"_"* ]]; then
    DOMAIN_ERR="域名包含下划线“_”，公共 CA 一律拒绝签发。
  处理建议：改用连字符或点，例如 ${d//_/-} 或 ${d//_/.}，并同步修改 DNS 解析与站点配置。"
    return 1
  fi
  if [[ $d == *"://"* || $d == */* ]]; then DOMAIN_ERR="不要包含协议头或路径（如 https:// 或 /xxx）"; return 1; fi
  if [[ $d =~ [[:space:]] ]]; then DOMAIN_ERR="域名不能包含空格"; return 1; fi
  if [ ${#d} -gt 253 ]; then DOMAIN_ERR="域名总长度超过 253 字符"; return 1; fi
  local re='^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{0,61}[A-Za-z0-9]$'
  if [[ ! $d =~ $re ]]; then
    DOMAIN_ERR="域名格式不合法：每级标签只能包含字母、数字、连字符，且不能以连字符开头或结尾（不要包含协议头或路径）"
    return 1
  fi
  return 0
}

validate_domain() {
  local input="${1:-}"
  if [ -n "$input" ]; then
    input="${input%.}"; input="${input,,}"
    if domain_check "$input"; then domain="$input"; return 0; fi
    red "域名格式不合法：${input}"
    red "$DOMAIN_ERR"
    return 1
  fi
  while :; do
    domain=""
    read -r -p "请输入一个有效的域名（例如：www.baidu.com, *.baidu.com；输入 0 取消）: " domain || return 1
    [ "$domain" == "0" ] && return 1
    domain="${domain%.}"; domain="${domain,,}"
    if domain_check "$domain"; then return 0; fi
    red "$DOMAIN_ERR"
    echo "请重新输入。"
  done
}

# ==========================================
# 将当前 PROXY_URL 写入 proxychains 配置文件
# 每次调用都会强制覆盖 [ProxyList] 段，确保与脚本配置同步
# ==========================================
update_proxychains_config() {
    if [[ -z "${PROXY_URL:-}" ]]; then
        red "\n未启用或未解析到代理（需 BUILD_PROXY_ENABLED=true 且系统 PROXY_* 齐全），无法写入 proxychains 配置。\n"
        return 1
    fi

    # 确定配置文件路径（proxychains4 优先）
    local conf=""
    if   [ -f "/etc/proxychains4.conf" ]; then conf="/etc/proxychains4.conf"
    elif [ -f "/etc/proxychains.conf" ];  then conf="/etc/proxychains.conf"
    else
        red "\n未找到 proxychains 配置文件 (/etc/proxychains4.conf 或 /etc/proxychains.conf)\n"
        return 1
    fi

    yellow "\n========== 更新 proxychains 代理配置 =========="
    yellow "配置文件: $conf"
    yellow "代理地址: $(acme_mask_proxy_url "$PROXY_URL")"

    # 备份（仅首次，后续不覆盖备份）
    if [ ! -f "${conf}.bak" ]; then
        $SUDO cp "$conf" "${conf}.bak"
        green "已备份原始配置到 ${conf}.bak"
    fi

    # --- 修复基础配置项 ---
    # 1. 注释掉默认 socks4 行（避免冲突）
    $SUDO sed -i 's/^socks4/#socks4/g' "$conf"

    # 2. proxy_dns 处理：
    #    - http 代理：不支持 proxy_dns，必须注释
    #    - socks5/socks4（无论本地还是远程）：必须启用 proxy_dns
    #      原因：socks5h 是“代理服务器解析 DNS”，proxychains 的 socks5 补法是启用 proxy_dns
    #      本地代理同样需要，否则本地被污染的 DNS 会导致代理连接错误 IP
    #    - proxy_dns_daemon：单独注释，它会尝试启动内置 DNS 守护进程，未配置时会导致挂起
    if [[ "$PC_PROXY_TYPE" == "http" ]]; then
        $SUDO sed -i 's/^proxy_dns\b/#proxy_dns/g' "$conf"
        $SUDO sed -i 's/^proxy_dns_old\b/#proxy_dns_old/g' "$conf"
        $SUDO sed -i 's/^proxy_dns_daemon\b/#proxy_dns_daemon/g' "$conf"
    else
        # socks5/socks4：启用 proxy_dns（取消注释），让 DNS 交给代理服务器解析
        $SUDO sed -i 's/^#\s*proxy_dns\b/proxy_dns/g' "$conf"
        # proxy_dns_old 和 proxy_dns_daemon 一律注释，避免内置守护进程未运行导致挂起
        $SUDO sed -i 's/^proxy_dns_old\b/#proxy_dns_old/g' "$conf"
        $SUDO sed -i 's/^proxy_dns_daemon\b/#proxy_dns_daemon/g' "$conf"
    fi

    # 3. 删除 [ProxyList] 之后所有已有的代理行，重写为当前配置
    #    策略：删除 [ProxyList] 段内的 http/socks 开头的行，再追加新行
    $SUDO sed -i '/^\s*\(http\|socks[45]\)\s/d' "$conf"

    # 4. 追加新的代理行到 [ProxyList] 段
    #    先确保 [ProxyList] 标记存在
    if ! grep -q '\[ProxyList\]' "$conf"; then
        echo -e "\n[ProxyList]" | $SUDO tee --append "$conf" >/dev/null
    fi
    echo "$PC_PROXY_TYPE $PROXY_IP $PROXY_PORT $PROXY_USER $PROXY_PASS" | $SUDO tee --append "$conf" >/dev/null

    green "\n✅ proxychains 配置已更新:"
    green "   $PC_PROXY_TYPE $PROXY_IP $PROXY_PORT $PROXY_USER $PROXY_PASS"
    echo ""

    # 5. 验证配置是否生效
    yellow "正在通过 proxychains 验证代理连通性..."
    local pc_cmd=""
    command -v proxychains4 >/dev/null 2>&1 && pc_cmd="proxychains4" || pc_cmd="proxychains"
    if timeout 15 $pc_cmd -q curl -s --connect-timeout 8 "https://www.google.com" >/dev/null 2>&1; then
        green "✅ proxychains 代理验证成功！"
    else
        red "❌ proxychains 代理验证失败，请检查:"
        yellow "   1. 代理服务 ${PROXY_IP}:${PROXY_PORT} 是否正常运行"
        yellow "   2. 当前配置文件内容:"
        grep -v '^\s*#' "$conf" | grep -v '^\s*$' | while read line; do
            yellow "      $line"
        done
    fi
    echo ""
}

install_proxychains4() {
    yellow "\n========== 安装 proxychains4 ==========\n" && sleep 2

    if [ -z `command_exists proxychains4` ]; then
        if [[ "${OS}" == "ubuntu" || "${OS}" == "debian" ]]; then
            $SUDO apt-get remove proxychains -y
            $SUDO rm -f /etc/proxychains.conf
            $SUDO apt-get install proxychains-ng -y

        elif [[ "${OS}" == "rhel" ]]; then
            $SUDO yum remove proxychains -y
            $SUDO yum autoremove -y
            $SUDO yum install proxychains-ng -y

        else
            red "\n~~当前${CURRENT_OS}系统暂不支持proxychains4的安装...\n" && exit 1
        fi
    fi

    # 安装完成后直接更新代理配置
    update_proxychains_config

    if [ -z `command_exists proxychains4` ]; then
        red "proxychains4 安装失败，请手动安装。" && start_menu
    fi
    green "proxychains4 安装完成。"
    start_menu
}

function install_acme_sh() {
    if [ -f "${HOME}/.acme.sh/acme.sh" ]; then
        if [ -f "${HOME}/.zshrc" ]; then
            grep "alias acme.sh=" ${HOME}/.zshrc >> /dev/null
            if [ $? -ne 0 ]; then
                echo "alias acme.sh=${HOME}/.acme.sh/acme.sh" >> ~/.zshrc
            fi
        fi

        if [ -f "${HOME}/.bashrc" ]; then
            grep "alias acme.sh=" ${HOME}/.bashrc >> /dev/null
            if [ $? -ne 0 ]; then
                echo "alias acme.sh=${HOME}/.acme.sh/acme.sh" >> ${HOME}/.bashrc
            fi
        fi

        if [[ "$SHELL" == "/bin/bash" || "$SHELL" == "/usr/bin/bash" ]]; then
            bash -c 'source ~/.bashrc'
            if [ $? -eq 0 ]; then
                echo "加载或执行用户主目录下的.bashrc文件成功"
            fi
        elif [[ "$SHELL" == "/bin/zsh" || "$SHELL" == "/usr/bin/zsh" ]]; then
            zsh -c 'source ~/.zshrc'
            if [ $? -eq 0 ]; then
                echo "加载或执行用户主目录下的.zshrc文件成功"
            fi
        fi

        red "开始升级 .acme.sh" && sleep 1
        # $SUDO $PR ${HOME}/.acme.sh/acme.sh --upgrade
        $SUDO $PR ${HOME}/.acme.sh/acme.sh --upgrade --auto-upgrade

        red ".acme.sh升级完成." && sleep 1
        ${ACME_SH_BIN} --version

        ensure_acme_renew_cron
        return 0
    fi

    $SUDO $PR curl --retry 8 -S -L https://get.acme.sh | sh -s email=$EMAIL
    red ".acme.sh 已安装."
    ${ACME_SH_BIN} --version
    ensure_acme_renew_cron
    return 0
}

function uninstall_acme_sh() {
    [[ $EUID -ne 0 ]] && $SUDO rm -fr /root/.acme.sh
    $SUDO rm -fr ${HOME}/.acme.sh
    [ -f "${HOME}/.bashrc" ] && sed -i '/.acme.sh/d' ${HOME}/.bashrc
    [ -f "${HOME}/.zshrc" ] && sed -i '/.acme.sh/d' ${HOME}/.zshrc
    remove_acme_cron_entries

    red ".acme.sh 已卸载（${ACME_HOME}）"
    return 0
}

# ==========================================
# acme.sh 脚本管理（安装/升级 + 卸载 + 状态）
# ==========================================

# acme_sh_manage_status
# 用途：只读展示 acme.sh 安装状态、版本、已装 DNS 插件数、续期 cron 概况
# 返回：0 = 已安装；1 = 未安装
acme_sh_manage_status() {
    blue "\n========== acme.sh 安装状态 =========="
    if [ ! -f "$ACME_SH_BIN" ]; then
        yellow "未安装：${ACME_SH_BIN}"
        return 1
    fi
    green "安装路径：${ACME_SH_BIN}"
    green "版本：    $( "$ACME_SH_BIN" --version 2>/dev/null | head -1 )"
    if [ -d "${ACME_HOME}/dnsapi" ]; then
        green "DNS 插件：$(ls "${ACME_HOME}/dnsapi"/*.sh 2>/dev/null | wc -l) 个"
    fi
    green "已签发证书：$(acme_list_managed_certs | wc -l) 个"
    if [ -n "$(find_acme_cron_lines)" ]; then
        yellow "续期 cron：存在 acme.sh 自带 --cron 条目（不读按域名凭据，请执行菜单 6 替换）"
    elif [ -n "$(find_renew_all_cron_lines)" ]; then
        green "续期 cron：已配置（--renew-all）"
    else
        yellow "续期 cron：未配置（签发成功后会自动写入，或执行菜单 6）"
    fi
    return 0
}

# acme_list_managed_certs
# 用途：列出 acme.sh 已签发的证书，每行 "<域名>\t<ecc|rsa>"（目录内须有同名 .conf）
# 返回：始终 0
acme_list_managed_certs() {
    local d name base
    [ -d "$ACME_HOME" ] || return 0
    for d in "$ACME_HOME"/*/; do
        d="${d%/}"
        name="$(basename "$d")"
        base="${name%_ecc}"
        # ECC 目录内的配置文件名为 <域名>.conf（不含 _ecc 后缀），此处必须去掉后缀再匹配
        [ -f "$d/$base.conf" ] || continue
        if [[ "$name" == *_ecc ]]; then
            printf '%s\tecc\n' "$base"
        else
            printf '%s\trsa\n' "$name"
        fi
    done
    return 0
}

# acme_sh_manage
# 用途：acme.sh 脚本管理子菜单（合并原"安装/升级"与"卸载"两个入口）
# 返回：始终 0（返回主菜单）
acme_sh_manage() {
    local choice="" confirm=""
    while :; do
        blue "\n========== acme.sh 脚本管理 =========="
        if [ -f "$ACME_SH_BIN" ]; then
            green "当前状态：已安装（$("$ACME_SH_BIN" --version 2>/dev/null | head -1)）"
        else
            yellow "当前状态：未安装"
        fi
        echo ""
        echo "  1) 安装 / 升级 acme.sh（--upgrade --auto-upgrade）"
        echo "  2) 卸载 acme.sh（保留已部署的证书文件）"
        echo "  3) 查看安装状态（版本 / DNS 插件 / 续期 cron）"
        echo "  0) 返回主菜单"
        blue "======================================="
        if ! read -r -p "$(yellow '请输入序号: ')" choice; then
            return 0
        fi
        case "$choice" in
            1)
                install_acme_sh
                ;;
            2)
                if [ ! -d "$ACME_HOME" ]; then
                    yellow "未检测到 ${ACME_HOME}，无需卸载"
                    continue
                fi
                red "⚠️  卸载将删除 ${ACME_HOME}（含账号密钥、证书与续期配置）"
                white "   已部署到 Nginx 目录的证书文件不会被删除"
                read -r -p "$(yellow '确认卸载？[y/N]: ')" confirm
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    uninstall_acme_sh
                else
                    yellow "已取消卸载"
                fi
                ;;
            3)
                acme_sh_manage_status || true
                ;;
            0|"")
                return 0
                ;;
            *)
                red "无效序号，请重新输入"
                ;;
        esac
    done
}

function add_domain_cert() {
    validate_and_issue_cert
}

# acme_issue_with_ca_fallback <域名> <验证函数名> [插件名]
# 用途：按当前 CA 签发；若因 CA 限额/重复签发失败，自动切换到备用 CA 重试
#   验证函数签名：<函数名> <域名> [插件名]
# 返回：0 = 成功；1 = 失败（失败原因已输出）
acme_issue_with_ca_fallback() {
    local domain="$1" issue_fn="$2" plugin="${3:-}" candidate="" tries=0 max=2

    while [ "$tries" -lt "$max" ]; do
        tries=$((tries + 1))
        if [ -n "$plugin" ]; then
            "$issue_fn" "$domain" "$plugin"
        else
            "$issue_fn" "$domain"
        fi && return 0

        if acme_issue_rate_limited "${ACME_LAST_ISSUE_LOG:-}"; then
            yellow "检测到 $(acme_ca_label "${ACME_CA_KEY:-$CERT_SERVER}") 签发限额/重复签发"
            candidate="$(acme_ca_next_candidates "${ACME_CA_KEY:-$CERT_SERVER}" | head -n 1)"
            if [ -n "$candidate" ] && [ "$tries" -lt "$max" ]; then
                yellow "自动切换到备用 CA：$(acme_ca_label "$candidate")"
                ACME_CA_KEY="$candidate"
                CERT_SERVER="$candidate"
                ACME_CA_REASON="原 CA 触发签发限额，已自动切换到 $(acme_ca_label "$candidate")"
                continue
            fi
            red "没有可切换的备用 CA"
        fi
        return 1
    done
    return 1
}

function validate_and_issue_cert() {
    local ca_confirm_rc=0

    # 调用函数并获取域名名称（支持非交互传参：validate_and_issue_cert <域名>）
    if [ -n "${1:-}" ]; then
        if ! validate_domain "$1"; then
            red "已中止：域名格式不合法"
            return 1
        fi
    elif ! validate_domain; then
        yellow "已取消添加域名证书"
        return 1
    fi

    # 提取可注册根域名（内置处理 com.cn / co.uk 等二级公共后缀）
    root_domain="$(acme_root_domain "$domain")"
    acme_prepare_issue_proxy

    # 自动评估并选择免费 CA
    if ! acme_select_ca "$domain"; then
        red "\n❌ 未找到可用的免费证书颁发机构，已中止（未产生任何 DNS 记录变更）"
        return 1
    fi

    red "验证成功，您当前输入的域名是： $domain"
    yellow "根域名：  ${root_domain}"
    yellow "证书颁发机构：$(acme_ca_label "$ACME_CA_KEY")（--server ${CERT_SERVER}）"
    yellow "选择依据：${ACME_CA_REASON}"

    # 交互环境下允许改选 CA
    if [ -t 0 ]; then
        ca_confirm_rc=0
        acme_ca_confirm_choice || ca_confirm_rc=$?
        if [ "$ca_confirm_rc" -eq 2 ]; then
            return 1
        fi
    else
        echo ""
    fi

    ACME_VERIFY_MODE="dns"
    local attempt=0 provider="" cred_source="" rc=0 issued=false reason=""

    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))

        # ---- HTTP 验证分支：不读取任何 DNS 凭据 ----
        if [ "$ACME_VERIFY_MODE" == "http" ]; then
            if acme_issue_with_ca_fallback "$domain" acme_issue_http; then
                issued=true
                break
            fi
            red "❌ HTTP 方式签发失败"
            if [ -s "${ACME_LAST_ISSUE_LOG:-}" ]; then
                yellow "日志尾部："
                tail -n 15 "$ACME_LAST_ISSUE_LOG"
            fi
            rm -f "${ACME_LAST_ISSUE_LOG:-}" 2>/dev/null || true
            return 1
        fi

        # ---- 确定解析商与凭据来源：按域名保存的凭据优先 ----
        acme_cred_store_unset
        if acme_cred_store_load "$root_domain"; then
            provider="$ACME_LOADED_PROVIDER"
            cred_source="按域名保存的凭据（${ACME_CRED_STORE_DIR}）"
        else
            provider="$(acme_detect_ns_provider "$root_domain")" || provider=""
            cred_source="默认配置"
            if [ -z "$provider" ]; then
                if ! acme_handle_credential_failure "$root_domain" "" \
                        "无法从 NS 记录识别解析商，且该域名没有已保存的凭据"; then
                    return 1
                fi
                continue
            fi
            if ! acme_provider_is_default "$provider"; then
                if ! acme_handle_credential_failure "$root_domain" "$provider" \
                        "解析商 $(acme_provider_label "$provider") 不属于默认配置，没有可用的默认凭据"; then
                    return 1
                fi
                continue
            fi
        fi

        yellow "当前使用的 DNS 解析商：${provider}（$(acme_provider_label "$provider")）"
        yellow "凭据来源：${cred_source}"

        # ---- 凭据可用性校验（缺失 / 失效 / 权限不足 / 校验失败）----
        rc=0
        acme_validate_provider_credentials "$root_domain" "$provider" || rc=$?
        if [ "$rc" -ne 0 ]; then
            if ! acme_handle_credential_failure "$root_domain" "$provider" "$ACME_CRED_FAIL_REASON"; then
                return 1
            fi
            continue
        fi

        # ---- DNS 方式签发 ----
        DNS_NAME="$provider"
        if acme_issue_with_ca_fallback "$domain" acme_issue_dns "$provider"; then
            issued=true
            break
        fi

        if acme_issue_auth_failed "${ACME_LAST_ISSUE_LOG:-}"; then
            reason="DNS API 调用被拒绝（凭据无效、已失效或权限不足）"
            [ -n "${ACME_LAST_AUTH_ERROR:-}" ] && reason="${reason}：${ACME_LAST_AUTH_ERROR}"
            if ! acme_handle_credential_failure "$root_domain" "$provider" "$reason"; then
                return 1
            fi
            continue
        fi

        red "❌ 证书签发失败（非凭据原因）"
        if [ -s "${ACME_LAST_ISSUE_LOG:-}" ]; then
            yellow "日志尾部："
            tail -n 20 "$ACME_LAST_ISSUE_LOG"
        fi
        rm -f "${ACME_LAST_ISSUE_LOG:-}" 2>/dev/null || true
        return 1
    done

    rm -f "${ACME_LAST_ISSUE_LOG:-}" 2>/dev/null || true

    if [ "$issued" != true ]; then
        red "\n❌ 证书签发未完成（已尝试 ${attempt} 次），已中止部署（不会用旧证书覆盖 Nginx 现有证书）"
        return 1
    fi

    green "\n✅ 证书已由 $(acme_ca_label "$ACME_CA_KEY") 签发（续期沿用同一 CA，无需重复选择）"

    if ! install_nginx_cert "$domain"; then
        red "❌ 证书已签发但部署失败，可修复后执行: $0 --verify-cert ${domain}"
        return 1
    fi

    # 证书安装成功后，检测并修复自动续期 cron 任务
    ensure_acme_renew_cron
    return 0
}

# acme_ca_confirm_choice
# 用途：展示自动选择的 CA 并允许改选（交互环境）
# 返回：0 = 保持自动选择；1 = 用户已改选
acme_ca_confirm_choice() {
    local sel="" candidate i=1
    local -a pool=()
    while IFS= read -r candidate; do
        [ -n "$candidate" ] && pool+=("$candidate")
    done < <(acme_ca_next_candidates "${ACME_CA_KEY:-}")

    echo ""
    yellow "是否保持该证书颁发机构？"
    echo "  回车) 保持 $(acme_ca_label "$ACME_CA_KEY")"
    for candidate in "${pool[@]}"; do
        acme_ca_supported "$candidate" || continue
        printf '  %2d) 改选 %s（%s）\n' "$i" "$(acme_ca_label "$candidate")" "$candidate"
        i=$((i + 1))
    done
    echo "   0) 中止本次签发"
    read -r -p "$(yellow '请输入序号: ')" sel || return 0
    [ -z "$sel" ] && return 0
    [ "$sel" == "0" ] && { red "已中止本次签发"; return 2; }
    i=1
    for candidate in "${pool[@]}"; do
        acme_ca_supported "$candidate" || continue
        if [ "$sel" == "$i" ]; then
            ACME_CA_KEY="$candidate"
            CERT_SERVER="$candidate"
            ACME_CA_REASON="用户手动改选"
            yellow "已改选：$(acme_ca_label "$candidate")"
            return 1
        fi
        i=$((i + 1))
    done
    red "无效序号，保持自动选择"
    return 0
}

# ==========================================
# 卸载域名 SSL 证书
# 自动列出本脚本安装的所有域名证书，支持按序号单个/批量卸载
# ==========================================

# acme_is_deployed_cert <目录> <文件名主干>
# 用途：判断 <目录>/<主干>.pem 是否为本脚本部署的证书（域名样式 + 同名 .key 存在），
#       排除同目录下 mkcert 等其他工具生成的 rootCA.pem、*-key.pem、xxx+N.pem
# 返回：0 = 是；1 = 否
acme_is_deployed_cert() {
    local dir="$1" base="$2"
    [[ "$base" =~ ^(\*\.)?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] || return 1
    [ -f "$dir/$base.key" ] || return 1
    return 0
}

# 收集已通过本脚本安装证书的域名
# 结果写入全局数组: REMOVE_SSL_DOMAINS (域名), REMOVE_SSL_PATHS (证书安装路径描述)
collect_installed_ssl_domains() {
    REMOVE_SSL_DOMAINS=()
    REMOVE_SSL_PATHS=()

    local domain_dir domain cert_path pem base
    local -A seen=()

    # 来源1: acme.sh 证书目录 (本脚本签署的证书，兼容 ECC 证书 _ecc 后缀目录)
    if [ -d "${ACME_HOME}" ]; then
        for domain_dir in "${ACME_HOME}"/*; do
            [ -d "$domain_dir" ] || continue
            domain=$(basename "$domain_dir")
            # 仅保留形如域名的目录，跳过 account、ca 等 acme.sh 内部目录
            [[ "$domain" =~ ^[a-zA-Z0-9.*-]+\.[a-zA-Z0-9-]{2,}(_ecc)?$ ]] || continue
            # 目录内必须存在 acme.sh 配置文件，确认是证书目录
            ls "$domain_dir"/*.conf >/dev/null 2>&1 || continue
            domain="${domain%_ecc}"
            [ -n "${seen[$domain]}" ] && continue
            seen[$domain]=1
            REMOVE_SSL_DOMAINS+=("$domain")
        done
    fi

    # 来源2: 证书安装目录中的 .pem 文件 (本脚本执行 install-cert 后生成)
    local dir
    for dir in "$CERT_INSTALL_DIR" "$CERT_INSTALL_DOCKER_DIR"; do
        [ -n "$dir" ] && [ -d "$dir" ] || continue
        for pem in "$dir"/*.pem; do
            [ -e "$pem" ] || continue
            base=$(basename "$pem" .pem)
            acme_is_deployed_cert "$dir" "$base" || continue
            [ -n "${seen[$base]}" ] && continue
            seen[$base]=1
            REMOVE_SSL_DOMAINS+=("$base")
        done
    done

    # 按域名排序，保证序号列表稳定有序
    if [ ${#REMOVE_SSL_DOMAINS[@]} -gt 0 ]; then
        IFS=$'\n' REMOVE_SSL_DOMAINS=($(sort <<<"${REMOVE_SSL_DOMAINS[*]}")); unset IFS
    fi

    # 为每个域名探测证书安装路径
    local d
    for d in "${REMOVE_SSL_DOMAINS[@]}"; do
        cert_path=""
        if [ -n "$CERT_INSTALL_DIR" ] && [ -f "$CERT_INSTALL_DIR/$d.pem" ]; then
            cert_path="$CERT_INSTALL_DIR/$d.pem"
        elif [ -f "$CERT_INSTALL_DOCKER_DIR/$d.pem" ]; then
            cert_path="$CERT_INSTALL_DOCKER_DIR/$d.pem"
        fi
        REMOVE_SSL_PATHS+=("$cert_path")
    done
}

# 查找并清理引用指定域名证书的 Nginx 站点配置文件
cleanup_domain_nginx_conf() {
    local domain="$1"
    local d f del_conf
    local search_dirs=()

    # 宿主机 Nginx/Tengine 配置目录
    for d in "/usr/local/nginx/conf" "/usr/local/tengine/conf" "/etc/nginx"; do
        [ -d "$d" ] && search_dirs+=("$d")
    done
    # Docker Nginx vhost 配置目录 (certs 的上级目录)
    local docker_vhost_dir
    docker_vhost_dir=$(dirname "$CERT_INSTALL_DOCKER_DIR")
    [ -d "$docker_vhost_dir" ] && search_dirs+=("$docker_vhost_dir")

    [ ${#search_dirs[@]} -eq 0 ] && return 0

    # 查找引用该域名证书文件的 conf 配置 (排除证书安装目录本身)
    local conf_files=()
    while IFS= read -r f; do
        [ -n "$f" ] && conf_files+=("$f")
    done < <(grep -rlF --include='*.conf' "${domain}.pem" "${search_dirs[@]}" 2>/dev/null \
             | grep -v "^${CERT_INSTALL_DIR}/" | grep -v "^${CERT_INSTALL_DOCKER_DIR}/" | sort -u)

    [ ${#conf_files[@]} -eq 0 ] && return 0

    yellow "检测到以下 Nginx 配置文件引用了域名 $domain 的证书:"
    for f in "${conf_files[@]}"; do
        yellow "  - $f"
    done
    read -p "$(yellow '是否一并删除上述站点配置文件？[y/N]: ')" -e del_conf
    if [[ "$del_conf" =~ ^[yY]$ ]]; then
        for f in "${conf_files[@]}"; do
            if rm -f "$f" 2>/dev/null || $SUDO rm -f "$f" 2>/dev/null; then
                green "✅ 已删除站点配置: $f"
            else
                red "❌ 权限不足，删除站点配置失败: $f，请使用 root 权限手动删除"
                return 1
            fi
        done
    else
        yellow "已保留站点配置文件，请手动检查其中的 ssl_certificate 配置，避免 Nginx 重载失败"
    fi
    return 0
}

# 卸载证书后重载 Nginx 使配置生效
reload_nginx_after_cert_change() {
    yellow "\n正在重载 Nginx 使配置生效..."
    if [ ! -z `command_exists nginx` ]; then
        if $SUDO systemctl force-reload nginx 2>/dev/null; then
            green "✅ 已重载宿主机 Nginx 服务"
        else
            red "❌ 宿主机 Nginx 重载失败，请手动执行: systemctl force-reload nginx"
            yellow "   提示: 若仍有站点配置引用已删除的证书文件，需先清理对应配置"
        fi
    elif docker ps 2>/dev/null | grep -q nginx; then
        if docker exec nginx nginx -t >/dev/null 2>&1; then
            if docker restart nginx >/dev/null 2>&1; then
                green "✅ 已重启 Docker Nginx 容器"
            else
                red "❌ Docker Nginx 容器重启失败，请手动执行: docker restart nginx"
            fi
        else
            red "❌ Docker Nginx 配置检测失败 (nginx -t)，可能存在引用已删除证书的站点配置"
            yellow "   请检查 $CERT_INSTALL_DOCKER_DIR 上级目录中的站点配置后手动执行: docker restart nginx"
        fi
    else
        yellow "⚠️  未检测到运行中的 Nginx 服务，跳过重载"
    fi
}

# 卸载单个域名的SSL证书: 清理 acme.sh 配置、证书文件、关联的 Nginx 站点配置
remove_single_domain_ssl() {
    local domain="$1"
    local result=0

    blue "\n---------- 开始卸载域名: $domain ----------"

    # 1. 移除 acme.sh 中的证书与续期配置 (兼容 RSA 与 ECC 目录)
    if [ -x "${ACME_SH_BIN}" ]; then
        if [ -d "${ACME_HOME}/${domain}" ]; then
            if "${ACME_SH_BIN}" --remove -d "${domain}"; then
                green "✅ 已移除 acme.sh 证书配置 (RSA): $domain"
            else
                red "❌ acme.sh 移除证书配置失败 (RSA): $domain"
                result=1
            fi
        fi
        if [ -d "${ACME_HOME}/${domain}_ecc" ]; then
            if "${ACME_SH_BIN}" --remove -d "${domain}" --ecc; then
                green "✅ 已移除 acme.sh 证书配置 (ECC): $domain"
            else
                red "❌ acme.sh 移除证书配置失败 (ECC): $domain"
                result=1
            fi
        fi
    else
        yellow "⚠️  未找到 acme.sh (${ACME_SH_BIN})，跳过 acme.sh 配置清理"
    fi

    # 兜底清理残留的 acme.sh 域名目录
    local d
    for d in "${ACME_HOME}/${domain}" "${ACME_HOME}/${domain}_ecc"; do
        if [ -d "$d" ]; then
            if rm -rf "$d" 2>/dev/null || $SUDO rm -rf "$d" 2>/dev/null; then
                green "✅ 已清理残留目录: $d"
            else
                red "❌ 权限不足，无法清理目录: $d，请使用 root 权限手动删除"
                result=1
            fi
        fi
    done

    # 2. 删除已安装的证书文件 (.pem/.key)
    local dir file found=false
    for dir in "$CERT_INSTALL_DIR" "$CERT_INSTALL_DOCKER_DIR"; do
        [ -n "$dir" ] && [ -d "$dir" ] || continue
        for file in "$dir/${domain}.pem" "$dir/${domain}.key"; do
            [ -e "$file" ] || continue
            found=true
            if [ -w "$dir" ]; then
                rm -f "$file" 2>/dev/null
            else
                $SUDO rm -f "$file" 2>/dev/null
            fi
            if [ -e "$file" ]; then
                red "❌ 权限不足，删除证书文件失败: $file，请使用 root 权限手动删除"
                result=1
            else
                green "✅ 已删除证书文件: $file"
            fi
        done
    done
    if [ "$found" = false ]; then
        yellow "⚠️  未找到域名 $domain 的本地证书文件 (.pem/.key)，可能已被删除或未执行安装"
    fi

    # 3. 清理关联的 Nginx 站点配置 (引用该域名证书的 conf 文件)
    cleanup_domain_nginx_conf "$domain" || result=1

    if [ "$result" -eq 0 ]; then
        green "✅ 域名 $domain SSL证书卸载完成"
    else
        red "⚠️  域名 $domain 卸载过程中存在失败项，请根据上方提示手动处理"
    fi
    return $result
}

function remove_domain_ssl() {
    collect_installed_ssl_domains

    if [ ${#REMOVE_SSL_DOMAINS[@]} -eq 0 ]; then
        yellow "\n未检测到任何通过本脚本安装SSL证书的域名，无需卸载。\n"
        start_menu
        return
    fi

    blue "\n========== 已安装SSL证书的域名列表 =========="
    local i path_desc
    for i in "${!REMOVE_SSL_DOMAINS[@]}"; do
        if [ -n "${REMOVE_SSL_PATHS[$i]}" ]; then
            path_desc="${REMOVE_SSL_PATHS[$i]}"
        else
            path_desc="未找到本地证书文件（仅存在 acme.sh 配置）"
        fi
        green "  $((i+1)). 域名: ${REMOVE_SSL_DOMAINS[$i]}"
        white "      证书路径: ${path_desc}"
    done
    blue "============================================="

    local total=${#REMOVE_SSL_DOMAINS[@]}
    local input idx valid confirm
    local -a selected=()

    while :; do
        read -p "$(yellow '请输入要卸载的证书序号（多个序号以半角空格分隔，如: 1 2；输入 0 取消）: ')" -e input

        # 输入 0 取消操作
        if [[ "$input" =~ ^[[:space:]]*0[[:space:]]*$ ]]; then
            yellow "已取消卸载操作。"
            start_menu
            return
        fi

        selected=()
        valid=true
        local -A picked=()
        for idx in $input; do
            if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
                red "错误: 输入内容 '$idx' 不是有效序号，请仅输入列表中的数字序号（多个以半角空格分隔）。"
                valid=false
                break
            fi
            if [ "$idx" -lt 1 ] || [ "$idx" -gt "$total" ]; then
                red "错误: 序号 '$idx' 不存在，有效范围为 1-$total。"
                valid=false
                break
            fi
            # 去重，避免重复卸载
            if [ -z "${picked[$idx]}" ]; then
                picked[$idx]=1
                selected+=("$idx")
            fi
        done

        if [ "$valid" = true ]; then
            if [ ${#selected[@]} -eq 0 ]; then
                red "错误: 输入不能为空，请输入至少一个序号。"
                continue
            fi
            break
        fi
    done

    yellow "\n即将卸载以下域名的SSL证书:"
    for idx in "${selected[@]}"; do
        red "  - ${REMOVE_SSL_DOMAINS[$((idx-1))]}"
    done
    read -p "$(yellow '确认卸载？该操作将删除证书文件及关联配置 [y/N]: ')" -e confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        yellow "已取消卸载操作。"
        start_menu
        return
    fi

    local success_count=0 fail_count=0
    for idx in "${selected[@]}"; do
        if remove_single_domain_ssl "${REMOVE_SSL_DOMAINS[$((idx-1))]}"; then
            success_count=$((success_count+1))
        else
            fail_count=$((fail_count+1))
        fi
    done

    # 重载 Nginx 使配置生效
    if [ "$success_count" -gt 0 ]; then
        reload_nginx_after_cert_change
    fi

    blue "\n========== 卸载结果汇总 =========="
    green "成功: $success_count 个"
    [ "$fail_count" -gt 0 ] && red "失败: $fail_count 个"
    echo ""

    # 证书删除完成后重新显示菜单
    start_menu
}

# ==========================================
# acme.sh 自动续期 cron 检测与修复
# ==========================================
get_user_crontab() {
    crontab -l 2>/dev/null || true
}

# 从 crontab 中提取 acme.sh 自带的 --cron 续期行（忽略注释）
find_acme_cron_lines() {
    get_user_crontab | grep -v '^[[:space:]]*#' | grep -E 'acme\.sh.*--cron|--cron.*acme\.sh' 2>/dev/null || true
}

# 检测 acme.sh 是否可用（存在且可执行）
check_acme_sh_ready() {
    local _issue=""

    blue "\n========== acme.sh 安装状态检测 =========="

    if [ ! -e "${ACME_SH_BIN}" ]; then
        red "❌ acme.sh 未找到: ${ACME_SH_BIN}"
        yellow "   请先通过菜单 2（acme.sh 脚本管理）→ 1 安装/升级"
        return 1
    fi

    if [ ! -x "${ACME_SH_BIN}" ]; then
        yellow "⚠️  acme.sh 存在但无执行权限，尝试修复: ${ACME_SH_BIN}"
        if chmod +x "${ACME_SH_BIN}" 2>/dev/null; then
            green "✅ 已添加执行权限"
        else
            red "❌ 无法为 acme.sh 添加执行权限，请手动执行: chmod +x ${ACME_SH_BIN}"
            return 1
        fi
    fi

    if [ ! -d "${ACME_HOME}" ]; then
        red "❌ acme.sh 主目录不存在: ${ACME_HOME}"
        return 1
    fi

    green "✅ acme.sh 已安装: ${ACME_SH_BIN}"
    green "   版本: $( "${ACME_SH_BIN}" --version 2>/dev/null | head -1 )"
    return 0
}

# acme_self_path
# 用途：输出本脚本的绝对路径（写入 cron 用）
acme_self_path() {
    readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}"
}

# 从 crontab 中提取本脚本的 --renew-all 续期行（忽略注释）
find_renew_all_cron_lines() {
    local self_name
    self_name="$(basename "$(acme_self_path)")"
    get_user_crontab | grep -v '^[[:space:]]*#' | grep -F -- "$self_name" | grep -F -- '--renew-all' || true
}

# 检测续期 cron 是否符合预期
# 预期：存在且仅存在指向本脚本的 "--renew-all" 行；不存在 acme.sh 自带的 "--cron" 行
# （acme.sh --cron 只读全局 account.conf，无法按域名注入已保存凭据，会让多账号域名续期串号）
# 返回：0 = 正常；1 = 未配置；2 = 需修复（路径不符 / 存在 acme.sh --cron 旧条目）
check_acme_cron_status() {
    local renew_lines legacy_lines self line valid_count=0 invalid_count=0

    blue "\n========== 自动续期 cron 任务检测 =========="

    self="$(acme_self_path)"
    renew_lines="$(find_renew_all_cron_lines)"
    legacy_lines="$(find_acme_cron_lines)"

    if [ -z "$renew_lines" ] && [ -z "$legacy_lines" ]; then
        yellow "⚠️  未找到自动续期 cron 任务"
        yellow "   期望包含: \"${self}\" --renew-all"
        return 1
    fi

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" == *"$self"* ]]; then
            green "   ✅ 有效: $line"
            valid_count=$((valid_count + 1))
        else
            red "   ❌ 脚本路径不匹配: $line"
            invalid_count=$((invalid_count + 1))
        fi
    done <<< "$renew_lines"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        red "   ❌ acme.sh 自带续期（不读按域名凭据，需替换）: $line"
        invalid_count=$((invalid_count + 1))
    done <<< "$legacy_lines"

    if [ "$valid_count" -eq 1 ] && [ "$invalid_count" -eq 0 ]; then
        green "✅ 自动续期 cron 任务配置正常"
        return 0
    fi
    yellow "⚠️  续期 cron 需要修复（有效 ${valid_count} 条，待清理 ${invalid_count} 条）"
    return 2
}

# 清理 crontab 中的续期条目：acme.sh 自带 --cron 行 + 本脚本的 --renew-all 行
remove_acme_cron_entries() {
    local current filtered self_name

    current=$(get_user_crontab)
    if [ -z "$current" ]; then
        return 0
    fi

    self_name="$(basename "$(acme_self_path)")"
    filtered=$(printf '%s\n' "$current" \
        | grep -Ev 'acme\.sh.*--cron|--cron.*acme\.sh|/\.acme\.sh/.*acme\.sh' \
        | awk -v n="$self_name" 'index($0, n) && index($0, "--renew-all") {next} {print}' || true)
    if [ -n "$filtered" ]; then
        printf '%s\n' "$filtered" | crontab - 2>/dev/null
    else
        crontab -r 2>/dev/null || true
    fi
    yellow "已清理 crontab 中的旧续期条目"
}

# 写入本脚本的 --renew-all 续期 cron（每天 0 点随机分钟执行，未到期的证书由 acme.sh 自动跳过）
install_acme_cron_manual() {
    local cron_minute cron_line current

    cron_minute=$(shuf -i 3-58 -n 1 2>/dev/null || echo "43")
    cron_line="${cron_minute} 0 * * * \"$(acme_self_path)\" --renew-all >> ${ACME_CRON_LOG} 2>&1"

    yellow "写入续期 cron 任务:"
    yellow "   ${cron_line}"

    current=$(get_user_crontab)
    if [ -n "$current" ]; then
        { printf '%s\n' "$current"; echo "$cron_line"; } | crontab - 2>/dev/null
    else
        echo "$cron_line" | crontab - 2>/dev/null
    fi
}

# 检测并修复自动续期 cron（证书添加成功后 / 菜单 6 调用）
ensure_acme_renew_cron() {
    local cron_status

    # 无论续期 cron 是否正常，都确保存在独立的证书到期巡检任务
    install_cert_check_cron

    blue "\n=================================================="
    blue "  开始检测自动续期 cron 任务"
    blue "=================================================="

    if ! check_acme_sh_ready; then
        red "\n❌ acme.sh 不可用，跳过 cron 检测与修复"
        red "   证书已签发，但自动续期可能无法执行，请手动安装 acme.sh 后修复 cron"
        return 1
    fi

    cron_status=0
    check_acme_cron_status || cron_status=$?

    if [ "$cron_status" -eq 0 ]; then
        green "\n✅ 自动续期 cron 无需修复"
        return 0
    fi

    blue "\n========== 开始修复续期 cron 任务 =========="
    [ "$cron_status" -eq 2 ] && remove_acme_cron_entries
    install_acme_cron_manual

    blue "\n========== 修复结果验证 =========="
    if check_acme_cron_status; then
        green "\n✅ 自动续期 cron 任务已修复完成"
        yellow "   可手动测试: \"$(acme_self_path)\" --renew-all"
        return 0
    fi
    red "\n❌ 续期 cron 写入后验证未通过，请手动检查: crontab -l"
    return 1
}

# 部署后自检：证书与私钥匹配、SAN 含域名、剩余有效期 > 7 天
verify_deployed_cert() {
    local domain="$1" crt="$2" key="$3" ok=0 cert_md5 key_md5

    if [ ! -s "$crt" ]; then
        red "❌ 部署校验失败：证书文件不存在或为空: $crt"
        return 1
    fi
    if [ ! -s "$key" ]; then
        red "❌ 部署校验失败：私钥文件不存在或为空: $key"
        return 1
    fi

    cert_md5=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null)
    key_md5=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl md5 2>/dev/null)
    if [ -z "$cert_md5" ] || [ "$cert_md5" != "$key_md5" ]; then
        red "❌ 部署校验失败：证书与私钥不匹配 ($crt)"
        ok=1
    fi

    if ! openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -q "$domain"; then
        red "❌ 部署校验失败：证书 SAN 不包含 $domain"
        ok=1
    fi

    if ! openssl x509 -in "$crt" -noout -checkend 604800 >/dev/null 2>&1; then
        red "❌ 部署校验失败：证书已过期或将在 7 天内过期 ($crt)"
        ok=1
    fi

    if [ "$ok" -eq 0 ]; then
        green "✅ 部署校验通过：证书与私钥匹配、SAN 正确、有效期充足"
        return 0
    fi
    return 1
}

# 巡检证书安装目录下所有已部署证书（供 cron / 手工调用）
check_all_deployed_certs() {
    local dir="$CERT_INSTALL_DIR" f domain cnt=0 bad=0 rc=0 enddate

    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        red "❌ 证书安装目录不存在: $dir"
        return 1
    fi

    blue "\n===== 已部署证书巡检: $dir ====="
    for f in "$dir"/*.pem; do
        [ -e "$f" ] || continue
        domain=$(basename "$f" .pem)
        acme_is_deployed_cert "$dir" "$domain" || continue
        cnt=$((cnt + 1))
        enddate=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)
        if verify_deployed_cert "$domain" "$f" "$dir/$domain.key" >/dev/null 2>&1; then
            green "✅ $domain    到期: $enddate"
        else
            bad=$((bad + 1))
            rc=1
            red "❌ $domain    校验失败:"
            verify_deployed_cert "$domain" "$f" "$dir/$domain.key"
        fi
    done

    if [ "$cnt" -eq 0 ]; then
        yellow "⚠️  未找到本脚本部署的证书（<域名>.pem + <域名>.key）"
        return 1
    fi
    if [ "$bad" -eq 0 ]; then
        green "✅ 共巡检 $cnt 个证书，全部通过"
    else
        red "❌ 共巡检 $cnt 个证书，其中 $bad 个异常，请立即处理"
    fi
    return $rc
}

# 写入"已部署证书到期巡检"cron（独立于 acme.sh，兜底发现静默失败）
install_cert_check_cron() {
    local script_path check_line current

    script_path="$(acme_self_path)"
    check_line="30 8 * * * \"${script_path}\" --check-certs >> ${ACME_CHECK_LOG} 2>&1"

    current=$(get_user_crontab)
    if echo "$current" | grep -q -- '--check-certs'; then
        green "✅ 已存在证书到期巡检 cron 任务"
        return 0
    fi

    if [ -n "$current" ]; then
        { echo "$current"; echo "$check_line"; } | crontab - 2>/dev/null
    else
        echo "$check_line" | crontab - 2>/dev/null
    fi

    if get_user_crontab | grep -q -- '--check-certs'; then
        green "✅ 已写入证书到期巡检 cron 任务"
        yellow "   ${check_line}"
        return 0
    fi
    red "❌ 证书巡检 cron 写入失败，请手动添加:"
    red "   ${check_line}"
    return 1
}

function install_nginx_cert() {
    local domain="$1"
    local ecc_flag=""
    local install_dir="" install_target="" install_key="" reload_cmd=""

    if [ -z "$domain" ]; then
        red "❌ install_nginx_cert: 域名为空"
        return 1
    fi

    # 部署前确认证书目录可用（只读子命令不受影响）
    acme_require_cert_dir || return 1

    # acme.sh v3 默认 ec-256，证书存放在 <domain>_ecc 目录；
    # 不带 --ecc 会读到历史 RSA 目录，从而部署已过期的旧证书（2026-10-15 故障根因）
    if [ -d "${ACME_HOME}/${domain}_ecc" ]; then
        ecc_flag="--ecc"
    fi

    # 一致性护栏：同名域名同时存在 RSA 与 ECC 目录时告警，避免再次部署到错误目录
    if [ -d "${ACME_HOME}/${domain}" ] && [ -n "$ecc_flag" ]; then
        red "⚠️  检测到 ${domain} 同时存在 RSA 与 ECC 证书目录，本次按 ECC 部署"
        yellow "   建议清理历史 RSA 证书: ${ACME_SH_BIN} --remove -d ${domain}"
    fi

    if command -v nginx >/dev/null 2>&1 || [ -x /usr/local/nginx/sbin/nginx ]; then
        red "当前Nginx运行在宿主机服务中"
        install_dir="$CERT_INSTALL_DIR"
        if [ -x /usr/local/nginx/sbin/nginx ]; then
            reload_cmd="/usr/local/nginx/sbin/nginx -t && /usr/local/nginx/sbin/nginx -s reload"
        else
            reload_cmd="systemctl force-reload nginx"
        fi
        ${ACME_SH_BIN} --install-cert -d "$domain" $ecc_flag \
            --key-file       "$install_dir/$domain.key" \
            --fullchain-file "$install_dir/$domain.pem" \
            --reloadcmd     "$reload_cmd"
        install_target="$install_dir/$domain.pem"
        install_key="$install_dir/$domain.key"
    elif command -v docker >/dev/null 2>&1 && docker ps 2>/dev/null | grep -q nginx; then
        red "当前Nginx运行在Docker服务中,当前申请证书的域名为：$domain"
        install_dir="$CERT_INSTALL_DOCKER_DIR"
        ${ACME_SH_BIN} --install-cert -d "$domain" $ecc_flag \
            --key-file       "$install_dir/$domain.key" \
            --fullchain-file "$install_dir/$domain.pem" \
            --reloadcmd     "docker restart nginx"
        install_target="$install_dir/$domain.pem"
        install_key="$install_dir/$domain.key"
    else
        red "❌ 未检测到宿主机或 Docker 环境中的 Nginx，跳过证书部署"
        return 1
    fi

    # 部署后自检：避免"部署成功"却实际是旧证书 / 证书与私钥不匹配
    if [ -n "$install_target" ]; then
        verify_deployed_cert "$domain" "$install_target" "$install_key" || {
            red "❌ 证书部署校验未通过，请检查上方错误"
            return 1
        }
    fi
    return 0
}


function start_menu() {
    tput setaf 3
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    red "                域名添加ssl证书 (更新日期：2026-10-28)"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    tput sgr0
    white "Linux系统信息如下："
    white "操作系统：  $(blue "$OS_DETAIL")" && white "内核版本：  $(blue "$KERNEL_VER")" && white "CPU架构：   $(blue "$CPU")" && white "虚拟化类型：$(blue "$VIRT_TYPE")"

    # 显示网络环境信息
    show_network_environment_info

    echo ""
    blue "1. 安装proxychains4"
    echo ""
    blue "2. acme.sh 脚本管理（安装/升级/卸载/状态）"
    echo ""
    green "3. 添加域名证书（自动选择免费 CA）"
    echo ""
    red "4. 卸载域名SSL证书 (按序号选择，支持批量)"
    echo ""
    yellow "5. 更新 proxychains 代理配置（改了 BUILD_PROXY_ENABLED / 系统 PROXY_* 后执行）"
    yellow "6. 检测/修复 acme.sh 自动续期 cron 任务"
    echo ""
    green "7. 巡检已部署证书 (证书/私钥匹配、SAN、有效期)"

    echo ""
    yellow "0. 退出脚本"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    white "当前.acme.sh版本：$(red "$ACME_VER")"
    echo
    while :; do

    read -p "$(yellow '请输入对应的数字，按回车: ')" -e CHOICE

case $CHOICE in
            1 )
                install_proxychains4;;
            2 )
                acme_sh_manage; start_menu;;
            3 )
                add_domain_cert; start_menu;;
            4 )
                remove_domain_ssl;;
            5 )
                update_proxychains_config; start_menu;;
            6 )
                ensure_acme_renew_cron; start_menu;;
            7 )
                check_all_deployed_certs; start_menu;;
            0 )
                exit;;
            * )
                echo "#################################"
                echo "    Choose the correct number    "
                echo "#################################"
                ;;
    esac
    done
}

# 非交互子命令（供 cron / 手工巡检调用，避免误入交互菜单）
case "$1" in
    --check-certs)
        check_all_deployed_certs
        exit $?
        ;;
    --check-dns)
        # 只读自检：解析商识别结果 + 凭据来源与脱敏值（不发起签发、不改 DNS）
        if [ -z "${2:-}" ]; then
            red "用法: $0 --check-dns <domain>"
            exit 2
        fi
        _chk_root="$(acme_root_domain "$2")"
        white "输入域名：$2"
        white "根域名：  $_chk_root"

        # CA 评估（不发起签发）：已有证书则沿用，否则按可达性择优
        if acme_select_ca "$2" >/dev/null 2>&1; then
            white "证书颁发机构：$(acme_ca_label "$ACME_CA_KEY")（--server ${CERT_SERVER}）"
            white "评估依据：$(printf '%s' "$ACME_CA_REASON")"
        else
            yellow "证书颁发机构：无法评估（acme.sh 未安装或不支持任何候选 CA）"
        fi

        if _chk_ns="$(acme_query_ns "$_chk_root")"; then
            white "NS 记录： $(printf '%s' "$_chk_ns" | tr '\n' ' ')"
        else
            yellow "NS 记录： 查询失败（dig/host/nslookup/DoH 均不可用）"
        fi

        _chk_rc=0
        _chk_provider=""
        _chk_source=""
        acme_cred_store_unset
        if acme_cred_store_load "$_chk_root"; then
            _chk_provider="$ACME_LOADED_PROVIDER"
            _chk_source="按域名保存的凭据"
        elif _chk_provider="$(acme_detect_ns_provider "$_chk_root")"; then
            _chk_source="NS 自动识别"
        else
            _chk_provider=""
            _chk_source="未识别"
        fi

        if [ -n "$_chk_provider" ]; then
            green "解析商：  ${_chk_provider}（$(acme_provider_label "$_chk_provider")，来源：${_chk_source}）"
        else
            red "解析商：  未能识别（可选择手动配置解析商，或改用 HTTP 验证）"
            _chk_rc=1
        fi

        echo
        white "凭据状态（脱敏）："
        if [ -n "$_chk_provider" ]; then
            while IFS= read -r _chk_spec; do
                [ -z "$_chk_spec" ] && continue
                _chk_var="${_chk_spec%%:*}"
                _chk_rest="${_chk_spec#*:}"
                _chk_lbl="${_chk_rest%%:*}"
                _chk_req="${_chk_rest##*:}"
                _chk_flag=""
                [ "$_chk_req" == "1" ] && _chk_flag="（必填）"
                printf '  %-20s = %s  来源: %s%s\n' \
                    "$_chk_var" "$(acme_mask_secret "${!_chk_var:-}")" \
                    "$(acme_credential_origin "$_chk_var")" "$_chk_flag"
            done < <(acme_provider_specs "$_chk_provider")
            acme_provider_credentials_ready "$_chk_provider" || _chk_rc=1
        fi
        white "凭据库文件：$(acme_cred_store_file "$_chk_root")"
        if [ -f "$(acme_cred_store_file "$_chk_root")" ]; then
            white "  状态：已保存"
        else
            yellow "  状态：未保存（首次手动配置解析商后自动生成）"
        fi
        if [ -f "$ACME_LOCAL_ENV_FILE" ]; then
            white "私有 env 文件：$ACME_LOCAL_ENV_FILE（已读取）"
        else
            yellow "私有 env 文件：$ACME_LOCAL_ENV_FILE（不存在，已跳过）"
        fi
        exit "$_chk_rc"
        ;;
    --list-dns-creds)
        blue "已保存的按域名凭据（加密存储于 ${ACME_CRED_STORE_DIR}）："
        printf '  %-28s %-14s %s\n' "DOMAIN" "PROVIDER" "UPDATED"
        acme_cred_store_list
        exit 0
        ;;
    --remove-dns-creds)
        if [ -z "${2:-}" ]; then
            red "用法: $0 --remove-dns-creds <domain>"
            exit 2
        fi
        acme_cred_store_delete "$(acme_root_domain "$2")" || exit 1
        exit 0
        ;;
    --renew-all)
        # 续期（cron 入口）：遍历 acme.sh 已签发的全部证书，按根域名注入已保存凭据后逐个续期。
        # 不加 --force：未到期由 acme.sh 跳过（返回 2）；续期成功后由 install-cert 记录的 reloadcmd 重载 Nginx。
        echo "===== $(date '+%F %T') 续期开始 ====="
        if ! check_acme_sh_ready; then
            exit 1
        fi
        acme_prepare_issue_proxy
        _renew_fail=0
        _renew_ok=0
        _renew_skip=0
        _renew_total=0
        while IFS=$'\t' read -r _renew_d _renew_type; do
            [ -n "$_renew_d" ] || continue
            _renew_total=$((_renew_total + 1))
            acme_cred_store_unset
            _renew_src="默认凭据（系统环境 / 私有 env）"
            if acme_cred_store_load "$(acme_root_domain "$_renew_d")"; then
                _renew_src="按域名保存的凭据（${ACME_LOADED_PROVIDER}）"
            fi
            _renew_args=(--renew -d "$_renew_d")
            [ "$_renew_type" == "ecc" ] && _renew_args+=(--ecc)
            yellow "续期 ${_renew_d}（${_renew_type}，${_renew_src}）"
            if _renew_ca="$(acme_ca_from_existing "$_renew_d")"; then
                white "  CA：$(acme_ca_label "$_renew_ca")（沿用 acme.sh 中记录的 CA）"
            fi
            _renew_log="$(mktemp -t acme-renew-XXXXXX)"
            _renew_rc=0
            acme_run_acme_to_log "$_renew_log" "${_renew_args[@]}" >/dev/null || _renew_rc=$?
            case "$_renew_rc" in
                0) green "  ✅ 已续期"; _renew_ok=$((_renew_ok + 1)) ;;
                2) white "  ⏭  未到续期时间，跳过"; _renew_skip=$((_renew_skip + 1)) ;;
                *) red "  ❌ 续期失败（rc=${_renew_rc}）"
                   tail -n 15 "$_renew_log"
                   _renew_fail=$((_renew_fail + 1)) ;;
            esac
            rm -f "$_renew_log"
        done < <(acme_list_managed_certs)
        acme_cred_store_unset
        blue "续期汇总：共 ${_renew_total}，续期 ${_renew_ok}，跳过 ${_renew_skip}，失败 ${_renew_fail}"
        [ "$_renew_fail" -eq 0 ] || exit 1
        exit 0
        ;;
    --verify-cert)
        if [ -z "$2" ]; then
            red "用法: $0 --verify-cert <domain>"
            exit 2
        fi
        verify_deployed_cert "$2" "$CERT_INSTALL_DIR/$2.pem" "$CERT_INSTALL_DIR/$2.key"
        exit $?
        ;;
esac

if [ $# == 0 ]; then
    start_menu
    # 出现错误立即终止脚本
    set -e
fi

