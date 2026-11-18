#!/usr/bin/env bash
# ==========================================
# Dockerignore 切换管理函数库
# ==========================================
# 用途：构建时临时切换 .dockerignore 文件（PHP 构建上下文优化）
# 依赖：common_functions.sh（info/error 函数）
# 全局变量（由 build.sh 主体初始化）：
#   ACTIVE_DOCKERIGNORE_SOURCE — 当前激活的 ignore 文件
#   PROJECT_DIR               — 项目根目录
# ==========================================

# 动态生成的混合 ignorefile 路径（本文件内部自动维护，无需外部初始化）
GENERATED_MIXED_IGNOREFILE=""

restore_temp_dockerignore() {
    local stable_backup="$PROJECT_DIR/.dockerignore.stable"
    if [[ -f "$stable_backup" ]]; then
        mv -f "$stable_backup" "$PROJECT_DIR/.dockerignore"
    fi
    # 清理动态生成的混合 ignorefile。
    # 注意：不能依赖 GENERATED_MIXED_IGNOREFILE 判断 —— 该变量是在
    # $( ) 命令替换子 shell 中赋值的，不会传播回父 shell，按变量清理必然遗漏；
    # mixed_auto 是纯生成物（_auto 后缀，无人工维护场景），无条件清理安全。
    rm -f "$PROJECT_DIR/.dockerignore.mixed_auto"
    GENERATED_MIXED_IGNOREFILE=""
}

is_php_build_target() {
    local service="$1"
    case "$service" in
        php85_apache|php84_apache|php83_apache|php82_apache|php81_apache|php80_apache|php74_apache)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_nginx_build_target() {
    local service="$1"
    case "$service" in
        nginx|nginx_server|tengine|tengine_server)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# 为混合构建场景动态生成 .dockerignore。
# 以标准 .dockerignore 为基础，按需移除 src/php/ src/nginx/ src/openssl/ 的排除行，
# 使同批次的 PHP/nginx/mysql/mongo/valkey 都能拿到各自所需的构建上下文。
# 返回：生成文件的路径；若无需修改则返回空（调用方应继续使用标准 .dockerignore）。
generate_mixed_dockerignore() {
    local has_php="$1"
    local has_nginx="$2"
    local tmp_file="$PROJECT_DIR/.dockerignore.mixed_auto"

    # 收集需从排除列表中移除的路径
    local unexclude=()
    [[ "$has_php" == "true" ]] && unexclude+=("src/php/")
    [[ "$has_nginx" == "true" || "$has_php" == "true" ]] && unexclude+=("src/openssl/")
    [[ "$has_nginx" == "true" ]] && unexclude+=("src/nginx/")

    if [[ ${#unexclude[@]} -eq 0 ]]; then
        # 无需修改，直接用标准 .dockerignore
        echo ""
        return 0
    fi

    # 精确匹配整行后剔除，避免误删注释
    local grep_args=()
    for pattern in "${unexclude[@]}"; do
        grep_args+=(-e "^${pattern}$")
    done

    grep -v "${grep_args[@]}" "$PROJECT_DIR/.dockerignore" > "$tmp_file" 2>/dev/null || true
    GENERATED_MIXED_IGNOREFILE="$tmp_file"
    echo "$tmp_file"
}

resolve_ignorefile_for_build() {
    local final_services=("$@")

    # 显式指定优先级最高
    if [[ -n "${IGNOREFILE_PATH:-}" ]]; then
        local explicit_path="$IGNOREFILE_PATH"
        if [[ "$explicit_path" != /* ]]; then
            explicit_path="$PROJECT_DIR/$explicit_path"
        fi
        if [[ ! -f "$explicit_path" ]]; then
            error "--ignorefile 指定的文件不存在: $explicit_path"
        fi
        echo "$explicit_path"
        return 0
    fi

    # 自动策略：扫描服务列表，确定是否需要修改构建上下文
    local has_php_target=false
    local has_nginx_target=false
    for service in "${final_services[@]}"; do
        if is_php_build_target "$service"; then
            has_php_target=true
        elif is_nginx_build_target "$service"; then
            has_nginx_target=true
        fi
    done

    # 只要包含 PHP 或 nginx 服务，就需要从标准 .dockerignore 中
    # 移除对应的 src/ 排除行（STANDARD 默认排除 src/php/ src/nginx/ src/openssl/）。
    # 纯 mysql/mongo/valkey 等构建不需要这些目录，STANDARD 直接可用，返回空即可。
    if [[ "$has_php_target" == "true" || "$has_nginx_target" == "true" ]]; then
        local mixed_file
        mixed_file="$(generate_mixed_dockerignore "$has_php_target" "$has_nginx_target")"
        echo "$mixed_file"
        return 0
    fi
}

switch_to_dockerignore_if_needed() {
    local final_services=("$@")
    local active_ignore_file="$PROJECT_DIR/.dockerignore"
    local stable_backup="$PROJECT_DIR/.dockerignore.stable"
    local selected_ignore_file

    # ---- 启动时自动恢复：检测上次崩溃后遗留的稳定备份 ----
    if [[ -f "$stable_backup" ]]; then
        # 若当前 .dockerignore 与某个专用 ignorefile 内容相同，说明上次未还原
        if diff -q "$active_ignore_file" "$stable_backup" > /dev/null 2>&1; then
            : # 已一致，无需还原
        else
            cp "$stable_backup" "$active_ignore_file"
            info "已自动还原上次崩溃遗留的 .dockerignore（来自 .dockerignore.stable）"
        fi
    fi

    selected_ignore_file="$(resolve_ignorefile_for_build "${final_services[@]}")"
    if [[ -z "$selected_ignore_file" ]]; then
        return 0
    fi

    if [[ ! -f "$active_ignore_file" ]]; then
        error "当前项目缺少 .dockerignore，无法应用 --ignorefile 机制"
    fi

    # 选择结果与当前规则一致时，无需切换。
    if [[ "$selected_ignore_file" == "$active_ignore_file" ]]; then
        ACTIVE_DOCKERIGNORE_SOURCE="$selected_ignore_file"
        return 0
    fi

    # 保存稳定备份（固定路径，用于崩溃恢复和 trap 还原，不再生成 PID 级备份文件）
    cp "$active_ignore_file" "$stable_backup"
    cp "$selected_ignore_file" "$active_ignore_file"
    ACTIVE_DOCKERIGNORE_SOURCE="$selected_ignore_file"
    info "已应用 --ignorefile 规则（临时切换 .dockerignore）：$selected_ignore_file"
}
