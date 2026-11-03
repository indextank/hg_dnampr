#!/bin/bash
# ============================================================================
# check-mysql-runtime-cnf.sh — MySQL 运行时配置自检（只读，不改任何状态）
# ----------------------------------------------------------------------------
# 校验「当前实际运行的 mysql 容器」是否加载了与本机环境匹配的那份 cnf，
# 且三份 cnf 互斥唯一生效、权限合规、关键参数取值正确。
#
# 校验项：
#   1. 入口一致性：build.sh 与 up.sh 都注入了 is_wsl_environment（防 wsl overlay 静默丢失）
#   2. 环境归一化：由 env/base.env / .env / .env.local 推导期望档位
#   3. 挂载源：/etc/mysql/mount-src/mysql-env.cnf 必须指向期望的 cnf
#   4. 权限：容器内 my.cnf 与 conf.d.live/*.cnf 必须 644、my.cnf 非软链、无 world-writable 告警
#   5. 标志参数：按档位断言 SHOW VARIABLES 取值
#
# 用法: bash scripts/check-mysql-runtime-cnf.sh [容器名]
# 退出码: 0=全部通过；1=存在不一致；2=前置条件不满足
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER="${1:-mysql}"
cd "$ROOT" || exit 2

fail=0
skip=0
ok()   { printf '  [PASS] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=1; }
warn() { printf '  [WARN] %s\n' "$*"; skip=1; }

# ---- 1. 入口一致性（防回归：build.sh 曾缺 status_display.sh） ----
echo "== 1. 入口脚本一致性 =="
for entry in build.sh up.sh; do
    [[ -f "$ROOT/$entry" ]] || { warn "$entry 不存在，跳过"; continue; }
    if grep -qE '^[[:space:]]*source[[:space:]].*status_display\.sh' "$ROOT/$entry"; then
        ok "$entry 已注入 status_display.sh（is_wsl_environment 可用）"
    else
        bad "$entry 未注入 status_display.sh → WSL overlay 会被静默跳过"
    fi
done

# ---- 2. 环境归一化（与 common_functions.sh 同源逻辑） ----
raw=$(grep -hE '^[[:space:]]*ENVIRONMENT=' env/base.env .env .env.local 2>/dev/null \
      | tail -1 | cut -d= -f2- | tr -d '"\047' | sed 's/[[:space:]]*#.*$//' | xargs -r)
raw="${raw,,}"
case "$raw" in
    production|prod) short=prod ;;
    *)               short=dev ;;
esac

is_wsl() {
    [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
    grep -qi 'microsoft\|wsl' /proc/version 2>/dev/null && return 0
    grep -qi 'microsoft\|wsl' /proc/sys/kernel/osrelease 2>/dev/null && return 0
    return 1
}

if is_wsl; then expect="mysql-wsl.cnf"; combo="WSL"
else expect="mysql-${short}.cnf"; combo="非WSL/${short}"; fi

echo ""
echo "== 2. 环境判定 =="
ok "组合=${combo}（ENVIRONMENT='${raw:-<unset>}'）→ 期望 ${expect}"

# ---- 3. 容器与挂载源 ----
echo ""
echo "== 3. 容器与挂载源 =="
if ! command -v docker >/dev/null 2>&1; then
    warn "docker 不可用"; echo ""; echo "RESULT: SKIP"; exit 2
fi
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    warn "容器 $CONTAINER 不存在（先 ./up.sh mysql up -d）"; echo ""; echo "RESULT: SKIP"; exit 2
fi

src=$(docker inspect "$CONTAINER" --format \
    '{{range .Mounts}}{{if eq .Destination "/etc/mysql/mount-src/mysql-env.cnf"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
[[ "$src" == *"/${expect}" ]] && ok "挂载源 = ${src}" || bad "挂载源 = ${src:-<空>}（期望 *${expect}）"

others=$(printf '%s\n' "$src" | grep -oE 'mysql-(dev|prod|wsl)\.cnf' | sort -u | wc -l)
[[ "$others" -le 1 ]] && ok "仅加载 1 份环境 cnf（互斥）" || bad "同时匹配到多份环境 cnf"

live=$(docker exec "$CONTAINER" sh -c 'ls /etc/mysql/conf.d.live/*.cnf 2>/dev/null' | wc -l)
[[ "$live" -eq 2 ]] && ok "conf.d.live 仅 2 份（docker.cnf + mysql-env.cnf）" || bad "conf.d.live 文件数=${live}（期望 2）"

# ---- 4. 权限 ----
echo ""
echo "== 4. 配置权限 =="
docker exec "$CONTAINER" sh -c 'test ! -L /etc/mysql/my.cnf' >/dev/null 2>&1 \
    && ok "my.cnf 非 alternatives 软链" || bad "my.cnf 仍为软链"
mode=$(docker exec "$CONTAINER" stat -c '%a' /etc/mysql/my.cnf 2>/dev/null)
[[ "$mode" == "644" ]] && ok "my.cnf 权限 644" || bad "my.cnf 权限 ${mode:-?}（期望 644）"
for f in $(docker exec "$CONTAINER" sh -c 'ls /etc/mysql/conf.d.live/*.cnf 2>/dev/null'); do
    m=$(docker exec "$CONTAINER" stat -c '%a' "$f" 2>/dev/null)
    [[ "$m" == "644" ]] && ok "$(basename "$f") 权限 644" || bad "$(basename "$f") 权限 ${m:-?}"
done
docker logs "$CONTAINER" 2>&1 | grep -qi 'World-writable config file' \
    && bad "启动日志存在 World-writable config file 警告" || ok "无 world-writable 警告"

# ---- 5. 标志参数 ----
echo ""
echo "== 5. 标志参数（SHOW VARIABLES） =="
pass=$(sed '1s/^\xEF\xBB\xBF//' .env 2>/dev/null | grep -E '^MYSQL_ROOT_PASSWORD=' | tail -1 | cut -d= -f2- | tr -d '"\047')
q() { docker exec -e MYSQL_PWD="$pass" "$CONTAINER" mysql -uroot -N -B -e "SELECT @@$1" 2>/dev/null; }
# 布尔型变量的取值在不同版本/不同变量上可能显示 0/1 或 OFF/ON，统一归一化后比较
norm_bool() {
    case "${1,,}" in
        0|off|false|no) echo "OFF" ;;
        1|on|true|yes)  echo "ON"  ;;
        *)              printf '%s' "$1" ;;
    esac
}
chk() {
    local v want; v=$(q "$1")
    [[ -z "$v" ]] && { warn "$1 取值失败（认证/连接问题），跳过"; return; }
    want=$(norm_bool "$2")
    if [[ "$(norm_bool "$v")" == "$want" ]]; then
        ok "$1=$v"
    else
        bad "$1=$v（期望 $2）"
    fi
}

case "$expect" in
    mysql-wsl.cnf)
        chk innodb_flush_method fsync
        chk innodb_doublewrite 0
        chk performance_schema 0
        chk max_connect_errors 1000000
        ;;
    mysql-dev.cnf)
        chk innodb_flush_method O_DIRECT
        chk max_connections 100
        chk local_infile 1
        chk sql_mode NO_ENGINE_SUBSTITUTION
        ;;
    mysql-prod.cnf)
        chk max_connections 300
        chk local_infile 0
        chk gtid_mode ON
        chk require_secure_transport 0
        ;;
esac

# prod：buffer_pool 必须能被容器内存上限容纳（含非池开销）
if [[ "$expect" == "mysql-prod.cnf" ]]; then
    pool=$(q innodb_buffer_pool_size)
    limit=$(docker inspect "$CONTAINER" --format '{{.HostConfig.Memory}}' 2>/dev/null)
    if [[ -n "$pool" && -n "$limit" && "$limit" -gt 0 ]]; then
        # 需要 pool + 非池内存(≈5G) ≤ limit
        need=$(( pool + 5*1024*1024*1024 ))
        [[ "$need" -le "$limit" ]] && ok "buffer_pool 可被内存上限容纳（pool+5G ≤ limit）" \
            || bad "buffer_pool(${pool}) + 非池(5G) > 内存上限(${limit})，存在 OOM 风险"
    fi
fi

echo ""
[[ $fail -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"
exit 1
