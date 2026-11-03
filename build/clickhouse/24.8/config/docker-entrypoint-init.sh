#!/bin/bash
# ==========================================
# ClickHouse 启动前初始化脚本
# ==========================================
# 职责：根据 CLICKHOUSE_PASSWORD 环境变量重写 users.d/hg_dnmpr.xml 中的密码哈希，
#       然后 exec 官方镜像的 /entrypoint.sh（保持官方启动流程不变）。
# 触发方式：compose command 覆盖为 ["/entrypoint-init.sh"]
# 依赖：sha256sum（官方镜像自带 coreutils）、python3 或 clickhouse 本地工具计算 SHA256。
#       为避免额外依赖，采用 openssl 或 sha256sum 计算 SHA256(password) 的 hex。

set -euo pipefail

USERS_FILE="/etc/clickhouse-server/users.d/hg_dnmpr.xml"

# 计算 CLICKHOUSE_PASSWORD 的 SHA256 hex
compute_sha256_hex() {
    local password="$1"
    # printf 避免尾随换行；sha256sum 输出格式：<hex>  <filename>，仅取首字段
    printf '%s' "${password}" | sha256sum | awk '{print $1}'
}

if [[ -n "${CLICKHOUSE_PASSWORD:-}" ]]; then
    password_hex="$(compute_sha256_hex "${CLICKHOUSE_PASSWORD}")"
    echo "[entrypoint-init] 写入 clickhouse 用户密码哈希到 ${USERS_FILE}"
    # 用 sed 替换 <password_sha256_hex>...</password_sha256_hex> 之间的内容
    sed -i -E "s|<password_sha256_hex>[^<]*</password_sha256_hex>|<password_sha256_hex>${password_hex}</password_sha256_hex>|" "${USERS_FILE}"
else
    echo "[entrypoint-init] 警告：CLICKHOUSE_PASSWORD 未设置，clickhouse 用户使用占位哈希（无法登录），请在 .env 中配置 CLICKHOUSE_PASSWORD"
fi

# 移交控制权给官方 entrypoint
exec /entrypoint.sh "$@"
