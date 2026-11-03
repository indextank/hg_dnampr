#!/bin/bash
# ==========================================
# ELK Let's Encrypt 证书续签脚本
# ==========================================
# 用途：由宿主机 crontab 每日调用，自动续签 Kibana 的 Let's Encrypt 证书
# 设置：crontab -e 添加 → 30 2 * * * /data/hg_dnmpr/scripts/renew-elk-certs.sh >> /data/hg_dnmpr/logs/elk-cert-renewal.log 2>&1
# ==========================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

_ts() { date '+%F %T'; }
_log() { echo "[$(  _ts)] $*"; }

# 加载容器运行时
if [[ -f "$PROJECT_DIR/include/shell/container_runtime.sh" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/include/shell/container_runtime.sh"
    detect_container_runtime 2>/dev/null || true
else
    # 降级：直接使用 docker
    cr_cmd() { docker "$@"; }
fi

# 读取配置值
_get_val() {
    grep -E "^${1}=" "$PROJECT_DIR/env/elk.prod.env" 2>/dev/null \
        | tail -1 | cut -d= -f2- | tr -d '\r' | sed "s/^['\"]//;s/['\"]$//"
}

KIBANA_DOMAIN="$(_get_val KIBANA_DOMAIN)"

if [[ -z "$KIBANA_DOMAIN" ]]; then
    _log "KIBANA_DOMAIN 未配置，跳过续签"
    exit 0
fi

# 检查 nginx 容器是否运行
if ! cr_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "nginx"; then
    _log "nginx 容器未运行，跳过续签（请先启动 nginx）"
    exit 0
fi

# 检查 acme.sh 是否已安装
if ! cr_cmd exec nginx sh -c 'command -v /root/.acme.sh/acme.sh > /dev/null 2>&1'; then
    _log "acme.sh 未在 nginx 容器内安装，跳过续签"
    _log "提示：请先运行 ./up.sh elk 完成初次证书申请"
    exit 0
fi

_log "开始检查/续签证书: $KIBANA_DOMAIN"

# 执行续签（acme.sh 内置幂等，证书未到期会自动跳过）
if cr_cmd exec nginx /root/.acme.sh/acme.sh \
    --renew -d "$KIBANA_DOMAIN" \
    --server letsencrypt 2>&1 | while IFS= read -r line; do _log "  $line"; done; then
    _log "续签检查完成"
    # reload nginx（证书有更新时 acme.sh 会自动调用 reloadcmd，此处兜底）
    cr_cmd exec nginx nginx -s reload 2>/dev/null && _log "nginx 已 reload"
else
    _log "续签失败或证书未到期（正常），退出码: $?"
fi

_log "完成"
