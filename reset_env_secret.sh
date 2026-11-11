#!/usr/bin/env bash
# ==========================================
# reset_env_secret.sh — 随机重置根目录 .env 中的敏感口令
# ==========================================
# 用法:
#   ./reset_env_secret.sh              # 就地更新 .env（先备份）
#   ./reset_env_secret.sh --dry-run    # 只打印将生成的值，不写文件
#   ENV_FILE=/path/to/.env ./reset_env_secret.sh
#
# 依赖: bash 4+、/dev/urandom
# ==========================================

set -euo pipefail

# ---------- 可在脚本头部自定义（也可用环境变量覆盖）----------
# 密码长度（位）
PASSWORD_LENGTH="${PASSWORD_LENGTH:-18}"
# 允许出现的特殊符号。
# 禁止纳入以下字符（否则会破坏 .env / Compose / bash 加载）：
#   $  → Compose / dotenv 会把 $or、$HOME 等当成变量插值（WARNING: The "or" variable is not set）
#   !  → 交互 bash 历史展开
#   #  → load_env_file_exports / 部分 dotenv 会把 # 后当作注释截断
#   ' " ` \ 空白 以及 < > & | ; ( ) { } [ ] → shell / YAML 元字符
# 勿加入单引号 '（若日后改为单引号包裹写入会冲突）。
SPECIAL_CHARS="${SPECIAL_CHARS:-~%^*,.-_}"
# 目标文件（相对仓库根或绝对路径）
ENV_FILE="${ENV_FILE:-}"
# ----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$ENV_FILE" ]]; then
    ENV_FILE="${SCRIPT_DIR}/.env"
fi

# 需要轮换的变量（与当前 .env 敏感口令项对齐）
SECRET_KEYS=(
    MYSQL_PASSWORD
    MYSQL_ROOT_PASSWORD
    MONGO_INITDB_ROOT_PASSWORD
    ME_CONFIG_BASICAUTH_PASSWORD
    ME_CONFIG_MONGODB_ADMINPASSWORD
    PG_PASSWORD
    PGADMIN_DEFAULT_PASSWORD
    TIMESCALE_PASSWORD
    PGVECTOR_PASSWORD
    CLICKHOUSE_PASSWORD
    KIBANA_ELASTICSEARCH_PASSWORD
    KIBANA_ENCRYPTION_KEY
    RABBITMQ_DEFAULT_PASS
    CANAL_ADMIN_PASSWORD
    CANAL_INSTANCE_DB_PASSWORD
    SPUG_DB_PASSWORD
    GITEA_DB_PASSWORD
    RAP2_MYSQL_PASSWORD
    REDIS_PASSWORD
)

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=true ;;
        --help|-h)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)
            echo "未知参数: $arg（支持 --dry-run / --help）" >&2
            exit 1
            ;;
    esac
done

# 构造 tr 字符集：字母数字 + 特殊符号；'-' 必须放在集合末尾以免被当成范围
_build_tr_charset() {
    local special="$1"
    local no_hyphen="${special//-/}"
    if [[ "$special" == *"-"* ]]; then
        printf 'A-Za-z0-9%s-' "$no_hyphen"
    else
        printf 'A-Za-z0-9%s' "$special"
    fi
}

# 从 /dev/urandom 取恰好 n 个符合 charset 的字符
_rand_chars() {
    local n="$1"
    local charset="$2"
    local out=""
    local chunk
    while (( ${#out} < n )); do
        chunk="$(LC_ALL=C tr -dc "$charset" </dev/urandom | head -c "$((n - ${#out} + 8))" || true)"
        out+="$chunk"
    done
    printf '%s' "${out:0:n}"
}

# 口令不得含 Compose/dotenv 可插值的 $VAR 形态，也不得含裸 $
_is_compose_safe_secret() {
    local secret="$1"
    # 任意 $ 均拒绝（含 $or、${or}、$1、$$ 等）
    [[ "$secret" != *'$'* ]]
}

# 生成密码：首位仅为字母/数字，其余为字母数字+特殊符号；失败则重试
generate_password() {
    local len="${1:-$PASSWORD_LENGTH}"
    if (( len < 2 )); then
        echo "PASSWORD_LENGTH 至少为 2" >&2
        return 1
    fi
    if [[ "$SPECIAL_CHARS" == *'$'* ]]; then
        echo "SPECIAL_CHARS 禁止包含 \$（会导致 Compose 将 \$or 等当作变量）" >&2
        return 1
    fi
    local first rest_charset candidate
    local attempt=0
    local max_attempts=20
    rest_charset="$(_build_tr_charset "$SPECIAL_CHARS")"
    while (( attempt < max_attempts )); do
        attempt=$((attempt + 1))
        first="$(_rand_chars 1 'A-Za-z0-9')"
        candidate="${first}$(_rand_chars $((len - 1)) "$rest_charset")"
        if _is_compose_safe_secret "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    echo "无法在 ${max_attempts} 次内生成不含 \$ 的安全口令，请检查 SPECIAL_CHARS" >&2
    return 1
}

if [[ ! -f "$ENV_FILE" ]]; then
    echo "找不到环境文件: $ENV_FILE" >&2
    echo "请先: cp .env.example .env" >&2
    exit 1
fi

if (( PASSWORD_LENGTH < 2 )); then
    echo "PASSWORD_LENGTH=$PASSWORD_LENGTH 非法（至少 2）" >&2
    exit 1
fi

# 启动时拦截危险 SPECIAL_CHARS，避免误改脚本头部后又生成 $or 类口令
if [[ "$SPECIAL_CHARS" == *'$'* ]]; then
    echo "SPECIAL_CHARS 含有 \$，拒绝执行（Compose 会把密码中的 \$or 当成变量）" >&2
    exit 1
fi
if [[ "$SPECIAL_CHARS" == *'#'* ]]; then
    echo "SPECIAL_CHARS 含有 #，拒绝执行（env 加载可能把 # 后截断为注释）" >&2
    exit 1
fi

declare -A NEW_SECRETS=()
local_key=""
for local_key in "${SECRET_KEYS[@]}"; do
    NEW_SECRETS["$local_key"]="$(generate_password "$PASSWORD_LENGTH")"
done

echo "目标文件: $ENV_FILE"
echo "密码长度: $PASSWORD_LENGTH"
echo "特殊符号: $SPECIAL_CHARS"
echo "模式:     $([[ "$DRY_RUN" == true ]] && echo dry-run || echo write)"
echo "----------------------------------------"
for local_key in "${SECRET_KEYS[@]}"; do
    printf '%s=%s\n' "$local_key" "${NEW_SECRETS[$local_key]}"
    if ! _is_compose_safe_secret "${NEW_SECRETS[$local_key]}"; then
        echo "内部错误: ${local_key} 仍含 \$，已中止（未写文件）" >&2
        exit 1
    fi
done
echo "----------------------------------------"

if [[ "$DRY_RUN" == true ]]; then
    echo "dry-run：未修改文件。"
    exit 0
fi

backup="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$ENV_FILE" "$backup"
echo "已备份: $backup"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

updated=0
missing=0
while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        if [[ -n "${NEW_SECRETS[$key]+x}" ]]; then
            printf '%s=%s\n' "$key" "${NEW_SECRETS[$key]}"
            updated=$((updated + 1))
            unset "NEW_SECRETS[$key]"
            continue
        fi
    fi
    printf '%s\n' "$line"
done < "$ENV_FILE" > "$tmp"

# 原文件中缺失的键：追加到文件末尾
for local_key in "${SECRET_KEYS[@]}"; do
    if [[ -n "${NEW_SECRETS[$local_key]+x}" ]]; then
        echo "警告: .env 中未找到 ${local_key}，已追加到文件末尾" >&2
        printf '%s=%s\n' "$local_key" "${NEW_SECRETS[$local_key]}" >> "$tmp"
        missing=$((missing + 1))
        unset "NEW_SECRETS[$local_key]"
    fi
done

mv "$tmp" "$ENV_FILE"
trap - EXIT

echo "完成: 就地更新 ${updated} 项，追加 ${missing} 项。"
echo "请妥善保存上方明文口令；轮换后需按服务要求重建/改密（Redis/Mongo 等可能不会自动改已有实例口令）。"
