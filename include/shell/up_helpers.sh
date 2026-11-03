#!/bin/bash
# ==========================================
# up_helpers.sh — up.sh 辅助工具函数
# ==========================================

# Dry-run 辅助函数：如果是 dry-run 模式则只打印命令，否则执行
# 用法: dry_run_or_exec <命令> [参数...]
dry_run_or_exec() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        local _cmd_preview
        _cmd_preview=$(format_services_inline "$@")
        echo -e "${CYAN}[DRY-RUN]${NC} ${_cmd_preview}"
        return 0
    else
        "$@"
    fi
}

# 执行 compose up 并过滤掉 podman-compose 在 detach 模式下输出的容器 ID 行
# 用法: compose_up_quiet <完整 compose up 命令字符串> [detach_flag]
# 只有在 detach("-d") 模式下才过滤，前台模式不过滤（保留实时日志输出）
compose_up_quiet() {
    local cmd_str="$1"
    local _container_echo_noise='^(php[0-9]{2}_apache|nginx|tengine|mysql|mongo|redis|valkey|postgres|pgadmin|mysql_backup|mongo_backup|postgres_backup|elasticsearch|kibana|logstash|rabbitmq|canal-server|syncer|spug|gitea|rap2-dolores|rap2-delos)$'
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo -e "${CYAN}[DRY-RUN]${NC} bash -c '$cmd_str'"
        return 0
    fi
    if [[ "$cmd_str" == *" -d"* || "$cmd_str" == *"--detach"* ]]; then
        # detach 模式：合并 stderr+stdout 一起过滤已知噪声
        # 1. 纯 64 位十六进制容器 ID（podman-compose detach 正常输出）
        # 2. pod cgroup 未设置（podman 已知 bug，不影响容器启动）
        # 3. 容器依赖检查"容器不存在"（首次启动时容器尚未创建，属正常）
        # 4. Podman detach 模式下的容器名单行回显（仅信息噪声）
        # 注意：必须保留 bash -c 的真实退出码（不可用 pipeline||true 吞掉失败）。
        local _cu_out _cu_st
        set +eE
        _cu_out=$(bash -c "$cmd_str" 2>&1)
        _cu_st=$?
        # 容器名冲突自愈：旧容器缺少 compose config-hash 标签（如由旧版 compose 创建）时，
        # compose --force-recreate 不认识它、直接新建同名容器，daemon 报
        # "The container name ... is already in use by container <id>"。
        # 此时强制删除冲突容器并重试一次。
        if [[ $_cu_st -ne 0 ]] && printf '%s\n' "$_cu_out" | grep -q 'is already in use by container'; then
            local _conflict_ids
            _conflict_ids=$(printf '%s\n' "$_cu_out" | grep -oE 'is already in use by container "[0-9a-f]+"' | grep -oE '[0-9a-f]{12,64}' | sort -u)
            if [[ -n "$_conflict_ids" ]]; then
                local _cid
                while IFS= read -r _cid; do
                    [[ -n "$_cid" ]] && cr_cmd rm -f "$_cid" >/dev/null 2>&1 || true
                done <<< "$_conflict_ids"
                _cu_out=$(bash -c "$cmd_str" 2>&1)
                _cu_st=$?
            fi
        fi
        set -Ee
        if [[ -n "$_cu_out" ]]; then
            printf "%s\n" "$_cu_out" | grep -vE -e '^[0-9a-f]{64}$' -e 'cgroup is not set' -e 'is not a valid container, cannot be used as a dependency' -e 'no container with .* found: no such container' -e "$_container_echo_noise" || true
        fi
        return "$_cu_st"
    else
        bash -c "$cmd_str"
    fi
}

# 执行 compose 命令并过滤 Podman 常见噪音（适用于 restart 等非 detach 命令）
compose_cmd_quiet() {
    local cmd_str="$1"
    local _noise='(^[0-9a-f]{64}$|cgroup is not set|is not a valid container, cannot be used as a dependency|no container with .* found: no such container|^(php[0-9]{2}_apache|nginx|tengine|mysql|mongo|redis|valkey|postgres|pgadmin|mysql_backup|mongo_backup|postgres_backup|elasticsearch|kibana|logstash|rabbitmq|canal-server|syncer|spug|gitea|rap2-dolores|rap2-delos)$)'
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo -e "${CYAN}[DRY-RUN]${NC} bash -c '$cmd_str'"
        return 0
    fi
    local _out
    set +eE
    _out=$(bash -c "$cmd_str" 2>&1)
    local _status=$?
    set -Ee
    if [[ -n "$_out" ]]; then
        printf "%s\n" "$_out" | grep -vE "$_noise" || true
    fi
    return $_status
}

# 将服务数组格式化为单行字符串（不受全局 IFS=$'\n\t' 影响）
format_services_inline() {
    local items=("$@")
    local out=""
    local item
    for item in "${items[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ -n "$out" ]]; then
            out="$out $item"
        else
            out="$item"
        fi
    done
    echo "$out"
}

# 显示使用帮助
show_help() {
    cat << 'ENDOFHELP'
=========================================
 hg_dnmpr 容器项目管理脚本 up.sh
=========================================

使用方法:
    ./up.sh [服务名...] [操作] [选项]

服务名:
    php85, php84, php83, php82, php81, php80, php74  - PHP 服务
    nginx, tengine                                    - Web 服务器（二选一）
    mysql                                            - MySQL 数据库
    redis, valkey                                     - 缓存服务
    mongo, postgres                                   - 其他数据库
    rabbitmq                                         - RabbitMQ 消息队列
    canal, canal-server                              - Canal 服务
    syncer                                           - MySQL -> Elasticsearch 同步服务
    monitoring                                       - Prometheus + Grafana 监控栈
    elk                                              - ELK 栈（自动检测 SSL 配置并生成证书）
    sgr                                              - Spug + Gitea + Rap2 栈
    all                                              - 所有服务

操作:
    up          - 启动服务（默认）
    start       - 启动服务（同 up）
    stop        - 停止服务
    restart     - 重启服务
    down        - 停止并删除服务
    logs        - 查看服务日志
    ps          - 查看服务状态
    status      - 列出容器的名称、IP 及状态（可附加服务名过滤）
    exec        - 进入服务容器
    clear       - 清理容器系统（未使用的资源）
    delete      - 强制删除所有容器
    prune       - 清理未使用的资源（镜像、容器、网络、卷）
    clean-all   - 彻底清理所有容器、镜像、网络和卷 [危险操作]
    purge       - 同 clean-all，彻底清理所有资源 [危险操作]

选项:
    -d, --detach       后台运行
    -f, --follow       跟踪日志输出
    --tail N           显示最后 N 行日志
    --dry-run          空运行模式，输出操作计划而不实际执行
                       包括：操作类型、环境、服务列表（含依赖解析）、
                       Compose 文件路径和将要执行的命令清单
    --all-global       清理操作作用于全局（所有项目），而非仅当前项目
    --help, -h         显示此帮助信息

示例:
    ./up.sh php84                                    # 启动 PHP 8.4 服务
    ./up.sh php84 nginx -d                           # 后台启动 PHP 8.4 和 Nginx
    ./up.sh php84 restart                            # 重启 PHP 8.4 服务
    ./up.sh php84 mongo stop                         # 停止 PHP 8.4 和 Mongo 服务
    ./up.sh php84 mongo down                         # 停止并删除 PHP 8.4 和 Mongo 服务
    ./up.sh php84 logs -f                            # 跟踪 PHP 8.4 日志
    ./up.sh php84 logs --tail 100                    # 显示 PHP 8.4 最后 100 行日志
    ./up.sh php84 exec                               # 进入 PHP 8.4 容器
    ./up.sh up -d                                    # 后台启动：主栈（已构建镜像）+ 有镜像的 ELK/RabbitMQ/Syncer 等
    ./up.sh status                                   # 列出所有项目容器的名称、IP 及状态
    ./up.sh mysql status                             # 仅列出 MySQL 相关容器的名称、IP 及状态
    ./up.sh down                                     # 停止并删除所有容器和网络
    ./up.sh restart                                  # 重启所有服务
    ./up.sh clear                                    # 清理容器系统（未使用的资源）
    ./up.sh delete                                   # 强制删除所有容器
    ./up.sh prune                                    # 清理未使用的资源（镜像、容器、网络、卷）
    ./up.sh clean-all                                # 彻底清理所有容器、镜像、网络和卷 [危险操作]
    ./up.sh elk                                      # 按 env/base.env 的 ENVIRONMENT 启动 ELK 栈
    ./up.sh syncer                                   # 按同一 ENVIRONMENT 加载 ELK/Syncer 相关配置

特殊操作:
    up          - 无服务名时：主栈按已构建镜像启动；ELK/RabbitMQ/Syncer 有本地构建镜像也会启动
    down        - 停止并删除所有容器、自定义网络，清理未使用镜像
    clear       - 清理未使用的资源（相当于 docker/podman system prune）
    delete      - 强制删除所有容器（相当于 docker/podman container rm --force $(docker/podman container ls -a -q)）
    prune       - 清理未使用的镜像、容器、网络、卷（相当于 docker/podman system prune -a -f --volumes）
    clean-all   - [危险操作] 彻底清理所有容器、镜像、网络和卷
                  * 停止并删除所有容器
                  * 删除所有镜像（包括正在使用的）
                  * 删除所有网络（除了默认网络）
                  * 删除所有卷（包括未使用的）
                  * 清理构建缓存
                  配合 --all-global 可清理全局所有项目（非仅当前项目）
    purge       - [危险操作] 同 clean-all，彻底清理所有资源
                  配合 --all-global 可清理全局所有项目（非仅当前项目）

ELK SSL 证书自动生成:
    当启动 ELK 服务时，脚本会自动检查以下内容：
    1. 读取 env/elk.[ENV].env 中的 ELK_HTTP_SSL_ENABLED 配置
    2. 如果 ELK_HTTP_SSL_ENABLED=true，则检查 SSL 证书是否存在
    3. 如果证书缺失或不完整，自动运行 include/shell/generate-elk-certs.sh 生成证书
    4. 如果 ELK_HTTP_SSL_ENABLED=false，跳过证书生成
    优势：避免因忘记生成证书导致 ELK 服务启动失败

⚠️  警告：clean-all 和 purge 操作会删除所有容器和镜像，请谨慎使用！
默认启用受保护卷：hg_dnmpr_elk_elasticsearch_data（不会被 prune/clean-all/purge 删除）
如需强制删除受保护卷：设置 ALLOW_DELETE_PROTECTED_VOLUMES=true

ENDOFHELP
}
