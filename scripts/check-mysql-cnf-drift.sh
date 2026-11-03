#!/bin/bash
# ============================================================================
# check-mysql-cnf-drift.sh — MySQL 多版本配置漂移校验
# ----------------------------------------------------------------------------
# 目的：确保 build/mysql/<版本>/config/conf.d/*.cnf 在多个大版本之间
#       只有"版本相关项"允许不同，其余环境/性能项必须完全一致，避免
#       修改一个版本后忘记同步另一个版本（配置漂移）。
#
# 校验规则：
#   1. 归一化（去注释/空行/行尾空白）后，各版本同一 cnf 的其余内容必须一致。
#   2. 版本相关项按白名单断言（见 ALLOW_* 变量）：
#        default_authentication_plugin  → 仅 8.0 允许（8.4 起移除）
#        mysql-native-password          → 仅 8.4 允许（9.x 移除，8.0 不支持）
#        skip-host-cache / skip_host_cache → 任何版本都不允许（8.4 起移除）
#   3. --validate 追加：对各版本镜像跑 mysqld --validate-config，
#      捕获 unknown / removed / 废弃告警。
#
# 用法：
#   bash scripts/check-mysql-cnf-drift.sh              # 静态漂移校验
#   bash scripts/check-mysql-cnf-drift.sh --validate    # 追加镜像级校验（需先构建镜像）
#   bash scripts/check-mysql-cnf-drift.sh -v            # 同上
#
# 退出码：0=通过；1=存在漂移或校验失败
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CNF_ROOT="$ROOT/build/mysql"
FILES=(mysql-dev.cnf mysql-prod.cnf mysql-wsl.cnf docker.cnf)

# 版本相关行白名单：<版本>:<正则>
ALLOW_LINES=(
    '8.0:^default_authentication_plugin[[:space:]]*='
    '8.4:^mysql-native-password[[:space:]]*='
)

# 严禁出现的已移除选项
BANNED_PATTERNS=(
    '^skip-host-cache(.*)$'
    '^skip_host_cache(.*)$'
)

DO_VALIDATE=false
for arg in "$@"; do
    case "$arg" in
        --validate|-v) DO_VALIDATE=true ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "未知参数: $arg（可用: --validate）" >&2; exit 2 ;;
    esac
done

fail=0
ok()  { printf '  [PASS] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; fail=1; }

mapfile -t VERSIONS < <(find "$CNF_ROOT" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V)
if ((${#VERSIONS[@]} < 2)); then
    echo "未发现至少两个 MySQL 版本目录（$CNF_ROOT），跳过漂移校验"
    exit 0
fi
echo "== 版本目录: ${VERSIONS[*]} =="

# 输出归一化内容；按版本剔除白名单行
normalized() {
    local ver="$1" file="$2" line pat skip
    grep -vE '^[[:space:]]*(#|$)' "$file" | sed 's/[[:space:]]*$//' | while IFS= read -r line; do
        skip=false
        for spec in "${ALLOW_LINES[@]}"; do
            if [[ "$ver" == "${spec%%:*}" && "$line" =~ ${spec#*:} ]]; then
                skip=true
                break
            fi
        done
        $skip || printf '%s\n' "$line"
    done
}

echo ""
echo "== 1. 归一化内容一致性（仅版本相关项允许不同） =="
for f in "${FILES[@]}"; do
    base_ver="${VERSIONS[0]}"
    base_file="$CNF_ROOT/$base_ver/config/conf.d/$f"
    [[ -f "$base_file" ]] || { bad "$f: 基准版本 $base_ver 缺失该文件"; continue; }
    file_fail=0
    for ver in "${VERSIONS[@]:1}"; do
        cur="$CNF_ROOT/$ver/config/conf.d/$f"
        [[ -f "$cur" ]] || { bad "$f: $ver 缺失该文件"; file_fail=1; continue; }
        if ! diff -q <(normalized "$base_ver" "$base_file") <(normalized "$ver" "$cur") >/dev/null; then
            bad "$f: $base_ver 与 $ver 存在非白名单差异"
            diff <(normalized "$base_ver" "$base_file") <(normalized "$ver" "$cur") | sed 's/^/       /'
            file_fail=1
        fi
    done
    [[ $file_fail -eq 0 ]] && ok "$f: ${VERSIONS[*]} 归一化一致"
done

echo ""
echo "== 2. 版本相关项断言 =="
# 2a. default_authentication_plugin 只在 8.0
for ver in "${VERSIONS[@]}"; do
    for f in mysql-dev.cnf mysql-prod.cnf; do
        p="$CNF_ROOT/$ver/config/conf.d/$f"
        [[ -f "$p" ]] || continue
        if grep -qE '^[[:space:]]*default_authentication_plugin[[:space:]]*=' "$p"; then
            [[ "$ver" == "8.0" ]] || bad "$f: $ver 出现 default_authentication_plugin（8.4 起已移除）"
        fi
    done
done
grep -qE '^[[:space:]]*default_authentication_plugin' "$CNF_ROOT/8.0/config/conf.d/mysql-dev.cnf" 2>/dev/null \
    && ok "8.0 保留 default_authentication_plugin（可显式声明认证插件）" || true

# 2b. mysql-native-password 只在 8.4
for ver in "${VERSIONS[@]}"; do
    p="$CNF_ROOT/$ver/config/conf.d/docker.cnf"
    [[ -f "$p" ]] || continue
    if grep -qE '^[[:space:]]*mysql-native-password[[:space:]]*=' "$p"; then
        [[ "$ver" == "8.4" ]] || bad "docker.cnf: $ver 出现 mysql-native-password（仅 8.4 支持）"
    fi
done
grep -qE '^[[:space:]]*mysql-native-password[[:space:]]*=' "$CNF_ROOT/8.4/config/conf.d/docker.cnf" 2>/dev/null \
    && ok "8.4 通过 mysql-native-password=ON 保留存量客户端兼容" || true

# 2c. 已移除的 skip-host-cache 系列
for ver in "${VERSIONS[@]}"; do
    for f in "${FILES[@]}"; do
        p="$CNF_ROOT/$ver/config/conf.d/$f"
        [[ -f "$p" ]] || continue
        for pat in "${BANNED_PATTERNS[@]}"; do
            if grep -qE "$pat" "$p"; then
                bad "$f: $ver 使用了已移除选项（匹配 $pat）"
            fi
        done
    done
done
ok "未使用 skip-host-cache / skip_host_cache（8.4 起已移除）"

echo ""
echo "== 3. 环境档三份互斥存在性 =="
for ver in "${VERSIONS[@]}"; do
    for f in mysql-dev.cnf mysql-prod.cnf mysql-wsl.cnf; do
        [[ -f "$CNF_ROOT/$ver/config/conf.d/$f" ]] \
            && ok "$ver/$f 存在" || bad "$ver/$f 缺失"
    done
done

if $DO_VALIDATE; then
    echo ""
    echo "== 4. 镜像级 --validate-config =="
    if ! command -v docker >/dev/null 2>&1; then
        bad "docker 不可用，无法执行 --validate"
    else
        for ver in "${VERSIONS[@]}"; do
            img="hg_dnmpr_mysql:$ver"
            if ! docker image inspect "$img" >/dev/null 2>&1; then
                echo "  [SKIP] $img 不存在（先执行 ./build.sh mysql）"
                continue
            fi
            for f in mysql-dev.cnf mysql-prod.cnf mysql-wsl.cnf; do
                src="$CNF_ROOT/$ver/config/conf.d/$f"
                dsrc="$CNF_ROOT/$ver/config/conf.d/docker.cnf"
                out=$(docker run --rm -v "$src:/src/env.cnf:ro" -v "$dsrc:/src/docker.cnf:ro" \
                    --entrypoint bash "$img" -c '
                        cp /src/env.cnf /etc/mysql/conf.d/mysql-env.cnf
                        cp /src/docker.cnf /etc/mysql/conf.d/docker.cnf
                        chmod 644 /etc/mysql/conf.d/*.cnf
                        mysqld --validate-config --log-error-verbosity=3 2>&1
                    ' 2>&1)
                hits=$(printf '%s\n' "$out" | grep -E 'MY-011068|MY-000067|MY-000068|unknown (variable|option)|removed' || true)
                if [[ -n "$hits" ]]; then
                    bad "$ver/$f --validate-config 出现未知/已移除/废弃项"
                    printf '%s\n' "$hits" | sed 's/^/       /'
                else
                    ok "$ver/$f --validate-config 通过"
                fi
            done
        done
    fi
fi

echo ""
if [[ $fail -eq 0 ]]; then
    echo "RESULT: PASS（无配置漂移）"
    exit 0
fi
echo "RESULT: FAIL（存在配置漂移，请对齐上表差异）"
exit 1
