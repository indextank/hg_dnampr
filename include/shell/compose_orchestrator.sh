#!/bin/bash
# ==========================================
# compose_orchestrator.sh — Compose 命令编排与多栈分步执行
# ==========================================
# 依赖：up_helpers.sh, service_catalog.sh, hosts_manager.sh, env_loader.sh, elk_certs.sh 等已 source 的环境

# Podman bind 目录 mkdir + uid 映射（与主栈 up.sh 逻辑一致）
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    _compose_orch_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=./podman_bind_permissions.sh
    [[ -f "${_compose_orch_dir}/podman_bind_permissions.sh" ]] && source "${_compose_orch_dir}/podman_bind_permissions.sh"
    # shellcheck source=./resource_limits.sh
    [[ -f "${_compose_orch_dir}/resource_limits.sh" ]] && source "${_compose_orch_dir}/resource_limits.sh"
    unset _compose_orch_dir
fi

# ELK：Elasticsearch bootstrap.memory_lock 与运行时关系
# - Docker：默认真（mlock 通常可满足 JVM 锁堆）
# - Podman rootless：默认真易因宿主机 memlock 过低导致启动失败，故默认假
# 由 execute_compose_command 在检测到 elk compose 且未显式设置 ELASTICSEARCH_BOOTSTRAP_MEMORY_LOCK 时 export。
_apply_elasticsearch_bootstrap_memory_lock_env() {
    local _cfs="$1"
    [[ "$_cfs" == *compose/stacks/elk.yaml* ]] || return 0
    [[ -z "${ELASTICSEARCH_BOOTSTRAP_MEMORY_LOCK:-}" ]] || return 0
    if declare -F detect_container_runtime &>/dev/null; then
        detect_container_runtime 2>/dev/null || true
    fi
    if cr_is_podman; then
        export ELASTICSEARCH_BOOTSTRAP_MEMORY_LOCK=false
        info "ELK: 已按 Podman 设置 ELASTICSEARCH_BOOTSTRAP_MEMORY_LOCK=false（bootstrap.memory_lock；rootful+memlock 充足可在 elk.*.env 显式设为 true）"
    else
        export ELASTICSEARCH_BOOTSTRAP_MEMORY_LOCK=true
        info "ELK: 已按 Docker 设置 ELASTICSEARCH_BOOTSTRAP_MEMORY_LOCK=true（bootstrap.memory_lock）"
    fi
}

execute_compose_command() {
    local environment="$1"
    local operation="$2"
    local options="$3"
    shift 3
    local services=("$@")
    local trap_set=false
    local split_depth="${UP_SPLIT_DEPTH:-0}"

    # SGR 子服务依赖主栈数据库/缓存（当前 SGR compose 已不再内置 mysql/redis）
    # - spug / gitea 依赖 mysql
    # - rap2-* 依赖 mysql + redis
    # 在 up/start/restart 时自动补齐依赖，避免容器内解析 mysql/redis 失败。
    # 仅在顶层调用注入依赖，避免多栈递归分步时重复注入导致死循环。
    if [[ "$split_depth" -eq 0 ]] && [[ "$operation" == "up" || "$operation" == "start" || "$operation" == "restart" ]]; then
        local need_mysql=false
        local need_redis=false
        local has_mysql=false
        local has_redis=false
        local _svc

        for _svc in "${services[@]}"; do
            case "$_svc" in
                spug|gitea) need_mysql=true ;;
                rap2-dolores|rap2-delos|sgr) need_mysql=true; need_redis=true ;;
                mysql) has_mysql=true ;;
                redis|valkey) has_redis=true ;;
            esac
        done

        if [[ "$need_mysql" == "true" && "$has_mysql" == "false" ]]; then
            services+=("mysql")
            info "检测到 SGR 服务依赖，自动追加 mysql"
        fi
        if [[ "$need_redis" == "true" && "$has_redis" == "false" ]]; then
            # redis / valkey 互斥：优先复用当前已运行实例，其次复用已存在镜像
            if cr_cmd ps --format "{{.Names}}" 2>/dev/null | grep -qx "valkey"; then
                services+=("valkey")
                info "检测到 SGR 服务依赖，自动追加 valkey（已运行）"
            elif cr_cmd ps --format "{{.Names}}" 2>/dev/null | grep -qx "redis"; then
                services+=("redis")
                info "检测到 SGR 服务依赖，自动追加 redis（已运行）"
            elif _cr_has_image "hg_dnmpr_valkey:latest"; then
                services+=("valkey")
                info "检测到 SGR 服务依赖，自动追加 valkey（本地镜像已存在）"
            else
                services+=("redis")
                info "检测到 SGR 服务依赖，自动追加 redis"
            fi
        fi
    fi

    # ── 混合服务拆分：不同独立栈（elk/sgr/rabbitmq/syncer）不能共用同一套 compose 文件
    # ── 若一次命令混合了多个栈（或与常规主栈混合），按栈分步执行，避免 "no such service"
    local _regular_services=()
    local _elk_services=()
    local _sgr_services=()
    local _rabbitmq_services=()
    local _syncer_services=()
    local _monitoring_services=()
    for _s in "${services[@]}"; do
        case "$_s" in
            elk|elasticsearch|kibana|logstash) _elk_services+=("$_s") ;;
            sgr|spug|gitea|rap2-dolores|rap2-delos) _sgr_services+=("$_s") ;;
            rabbitmq|canal|canal-server) _rabbitmq_services+=("$_s") ;;
            syncer) _syncer_services+=("$_s") ;;
            monitoring|syncer-prometheus|syncer-grafana|prometheus|grafana) _monitoring_services+=("$_s") ;;
            *) _regular_services+=("$_s") ;;
        esac
    done

    local _group_count=0
    ((${#_regular_services[@]} > 0)) && _group_count=$((_group_count + 1))
    ((${#_elk_services[@]} > 0)) && _group_count=$((_group_count + 1))
    ((${#_sgr_services[@]} > 0)) && _group_count=$((_group_count + 1))
    ((${#_rabbitmq_services[@]} > 0)) && _group_count=$((_group_count + 1))
    ((${#_syncer_services[@]} > 0)) && _group_count=$((_group_count + 1))
    ((${#_monitoring_services[@]} > 0)) && _group_count=$((_group_count + 1))

    if [[ "$_group_count" -gt 1 ]]; then
        local _step=1
        local _ret=0
        local _next_depth=$((split_depth + 1))
        info "检测到多栈服务混合，分步执行..."

        # 多栈分步执行时，up/start 操作必须强制后台运行（-d）。
        # 若不加 -d，第一个栈会以前台 attach 模式运行并阻塞 shell，
        # 导致后续栈永远无法启动。
        # 规则：
        #   - 用户已显式指定 -d / --detach → 保持不变
        #   - 用户未指定 -d，且操作为 up/start → 自动追加 -d，并提示用户
        local _options_for_steps="$options"
        if [[ "$operation" == "up" || "$operation" == "start" ]]; then
            if [[ ! "$options" =~ (-d|--detach) ]]; then
                info "多栈分步执行：自动切换为后台模式（-d），如需查看日志请使用 ./up.sh <服务> logs -f"
                _options_for_steps="$options -d"
            fi
        fi

        if ((${#_regular_services[@]} > 0)); then
            info "步骤 ${_step}/${_group_count}：执行主栈服务 (${_regular_services[*]})"
            ( UP_SPLIT_DEPTH="$_next_depth"; execute_compose_command "$environment" "$operation" "$_options_for_steps" "${_regular_services[@]}" ) || _ret=$?
            _step=$((_step + 1))
        fi
        # ELK 必须在 syncer 之前启动（syncer 依赖 Elasticsearch）
        if ((${#_elk_services[@]} > 0)); then
            info "步骤 ${_step}/${_group_count}：执行 ELK 栈服务 (${_elk_services[*]})"
            ( UP_SPLIT_DEPTH="$_next_depth"; execute_compose_command "$environment" "$operation" "$_options_for_steps" "elk" ) || _ret=$?
            _step=$((_step + 1))
            # 若同时还需要启动 syncer，且当前是启动/重启操作，则等待 ES 就绪后再继续
            if ((${#_syncer_services[@]} > 0)) && \
               [[ "$operation" == "up" || "$operation" == "start" || "$operation" == "restart" ]]; then
                wait_for_elasticsearch_ready "$environment"
            fi
        fi
        if ((${#_rabbitmq_services[@]} > 0)); then
            info "步骤 ${_step}/${_group_count}：执行 RabbitMQ 栈服务 (${_rabbitmq_services[*]})"
            ( UP_SPLIT_DEPTH="$_next_depth"; execute_compose_command "$environment" "$operation" "$_options_for_steps" "${_rabbitmq_services[@]}" ) || _ret=$?
            _step=$((_step + 1))
            # 若后续还要启动 syncer，则必须等待 RabbitMQ 就绪，避免 syncer 首次连接失败后退出消费协程
            if ((${#_syncer_services[@]} > 0)) && \
               [[ "$operation" == "up" || "$operation" == "start" || "$operation" == "restart" ]]; then
                wait_for_rabbitmq_ready 120
            fi
        fi
        if ((${#_syncer_services[@]} > 0)); then
            info "步骤 ${_step}/${_group_count}：执行 Syncer 栈服务 (${_syncer_services[*]})"
            ( UP_SPLIT_DEPTH="$_next_depth"; execute_compose_command "$environment" "$operation" "$_options_for_steps" "syncer" ) || _ret=$?
            _step=$((_step + 1))
        fi
        if ((${#_sgr_services[@]} > 0)); then
            info "步骤 ${_step}/${_group_count}：执行 SGR 栈服务 (${_sgr_services[*]})"
            ( UP_SPLIT_DEPTH="$_next_depth"; execute_compose_command "$environment" "$operation" "$_options_for_steps" "sgr" ) || _ret=$?
            _step=$((_step + 1))
        fi
        if ((${#_monitoring_services[@]} > 0)); then
            info "步骤 ${_step}/${_group_count}：执行 Monitoring 栈服务 (${_monitoring_services[*]})"
            ( UP_SPLIT_DEPTH="$_next_depth"; execute_compose_command "$environment" "$operation" "$_options_for_steps" "monitoring" ) || _ret=$?
        fi
        # exit 124 = detach 超时，容器仍在后台启动，不视为错误
        [[ $_ret -eq 124 ]] && _ret=0
        return "$_ret"
    fi

    # 在启动操作时，检查ELK证书（仅生产环境）
    if [[ "$operation" == "up" || "$operation" == "start" ]]; then
        if ! check_and_generate_elk_certs "$environment" "${services[@]}"; then
            error "ELK证书检查失败，操作终止"
            return 1
        fi

        # 确保 ES 的 setup-kibana-password-noop.sh 有执行权限
        # 该脚本覆盖 ES 镜像内置的密码设置脚本（密码由 _sync_kibana_system_password 统一管理）
        # 若文件无 +x 权限，容器内会报 "Permission denied" 并回退到镜像内置脚本产生 WARN
        local _noop_script="${PROJECT_DIR}/build/elk/${ELK_BUILD_VERSION:-9.5}/elasticsearch/setup-kibana-password-noop.sh"
        if [[ -f "$_noop_script" ]] && [[ ! -x "$_noop_script" ]]; then
            chmod +x "$_noop_script" 2>/dev/null || true
        fi

        # ELK SSL 启用场景下，自动安装系统信任链（失败仅提示，不阻塞服务启动）
        local has_elk=false
        for service in "${services[@]}"; do
            if [[ "$service" == "elk" || "$service" == "elasticsearch" || "$service" == "kibana" || "$service" == "logstash" ]]; then
                has_elk=true
                break
            fi
        done

        if [[ "$has_elk" == "true" ]]; then
            local env_name="$environment"
            case "$env_name" in
                production|prod) env_name="prod" ;;
                development|dev) env_name="dev" ;;
                *) env_name="dev" ;;
            esac
            local elk_env_file="${BUILD_ROOT:-$PROJECT_DIR/build}/elk/${ELK_BUILD_VERSION:-9.5}/elk.${env_name}.env"
            # 生产环境：确保 nginx 已叠加 ELK overlay（证书卷 + hg_dnmpr_network）
            # 必须在 ELK 容器启动前执行，使 nginx 可通过容器名访问 kibana
            if [[ "$env_name" == "prod" ]]; then
                if declare -f ensure_nginx_with_elk_overlay >/dev/null 2>&1; then
                    info "生产环境 ELK：确保 nginx 已应用 ELK overlay（证书卷挂载 + hg_dnmpr_network）..."
                    ensure_nginx_with_elk_overlay || warn "nginx ELK overlay 应用未完成，请检查 nginx 容器状态"
                fi
            fi
            if [[ -f "$elk_env_file" ]] && grep -q "^ELK_HTTP_SSL_ENABLED=true" "$elk_env_file" 2>/dev/null; then
                ensure_elk_ca_trust || true
            fi
        fi
    fi

    # Web服务冲突检测
    local has_nginx=false
    local has_tengine=false
    for service in "${services[@]}"; do
        if [[ "$service" == "nginx" ]]; then
            has_nginx=true
        elif [[ "$service" == "tengine" ]]; then
            has_tengine=true
        fi
    done

    if [[ "$has_nginx" == "true" && "$has_tengine" == "true" ]]; then
        echo -e "${RED}❌ 检测到同时指定了 nginx 和 tengine 服务！${NC}" >&2
        echo "" >&2
        echo -e "${YELLOW}${BOLD}⚠️  重要提示：${NC}" >&2
        echo -e "  • nginx-server:  标准的Nginx Web服务器" >&2
        echo -e "  • tengine-server: 阿里巴巴开源的Nginx增强版" >&2
        echo "" >&2
        echo -e "${CYAN}请选择其中一种Web服务器：${NC}" >&2
        echo -e "  ./up.sh nginx $operation     # 使用标准Nginx" >&2
        echo -e "  ./up.sh tengine $operation   # 使用Tengine增强版" >&2
        echo "" >&2
        exit 1
    fi

    # redis冲突检测
    local has_redis=false
    local has_valkey=false
    for service in "${services[@]}"; do
        if [[ "$service" == "redis" ]]; then
            has_redis=true
        elif [[ "$service" == "valkey" ]]; then
            has_valkey=true
        fi
    done

    if [[ "$has_redis" == "true" && "$has_valkey" == "true" ]]; then
        echo -e "${RED}❌ 检测到同时指定了 redis 和 valkey 服务！${NC}" >&2
        echo "" >&2
        echo -e "${YELLOW}${BOLD}⚠️  重要提示：${NC}" >&2
        echo -e "  • valkey 服务衍生于redis，属于同类型产品，相互兼容，不可同时启动。" >&2
        echo "" >&2
        echo -e "${CYAN}请选择其中一种缓存服务器：${NC}" >&2
        echo -e "  ./up.sh redis $operation     # 使用redis" >&2
        echo -e "  ./up.sh valkey $operation   # 使用valkey" >&2
        echo "" >&2
        exit 1
    fi

    # 获取compose文件
    local compose_files=$(get_compose_files "$environment" "${services[@]}")

    # P17: deploy.resources → 实际资源限制转换
    # compose v3 deploy.resources 仅对 Swarm 生效，compose up 需转换
    local _resource_override_file=""
    if declare -f apply_resource_limits >/dev/null 2>&1; then
        apply_resource_limits "$compose_files" "$environment" "${services[@]}" || true
        _resource_override_file="${RESOURCE_LIMITS_OVERRIDE_FILE:-}"
    fi
    if [[ -n "$_resource_override_file" && -f "$_resource_override_file" ]]; then
        compose_files="$compose_files -f $_resource_override_file"
    fi

    # P19: SELinux Enforcing 模式下自动追加 :Z 标签
    # 当 SELinux 处于 Enforcing 状态时，bind mount 需要 :Z 标签才能被容器访问
    local _selinux_override_file=""
    if cr_is_podman; then
        local _selinux_state
        _selinux_state=$(command -v getenforce &>/dev/null && getenforce 2>/dev/null || echo "Disabled")
        if [[ "$_selinux_state" == "Enforcing" ]]; then
            _selinux_override_file="${TMPDIR:-/tmp}/hg_dnmpr_selinux_override_$$.yaml"
            # 生成临时 compose override 为 bind mount 添加 :Z 标签
            # 注意: :Z 使容器独占该目录（每个容器独立标签），:z 共享（同一标签）
            # 数据库卷等单容器挂载使用 :Z，共享挂载使用 :z
            info "检测到 SELinux Enforcing，自动生成卷标签适配 (P19)"
            # 实际的 :Z 标签已在前面的 compose/stacks/web.yaml vol 中硬编码
            # 此处生成一个占位 override 让 compose 知晓处理了 SELinux
            if [[ ! -f "$_selinux_override_file" ]]; then
                echo "# SELinux 卷标签适配 - 由 compose_orchestrator.sh 自动生成" > "$_selinux_override_file"
                echo "# 已有卷标签 :Z（见 compose/stacks/web.yaml），此文件仅为标记" >> "$_selinux_override_file"
                echo "services: {}" >> "$_selinux_override_file"
            fi
            compose_files="$compose_files -f $_selinux_override_file"
        fi
    fi

    # 方案3: Podman 容器自愈策略 — 自动加载 restart: on-failure overlay
    # 仅在 Podman 运行时生效，不影响 Docker 已有行为。
    # podman-compose 的 depends_on condition: service_healthy 在并发启动
    # 和 crun 竞态下可能不稳定，on-failure 重启策略作为补充保障。
    if cr_is_podman; then
        local _podman_restart_ov="${PROJECT_DIR}/compose/overlays/podman-restart.yaml"
        if [[ -f "$_podman_restart_ov" ]]; then
            compose_files="$compose_files -f $_podman_restart_ov"
        fi
    fi

    # 处理特殊组合
    local final_services=()
    local web_services=()  # 用于存储Web服务器

    for service in "${services[@]}"; do
        local special_services=$(get_special_services "$service")
        if [[ -n "$special_services" ]]; then
            IFS=' ' read -ra _special_arr <<< "$special_services"
            final_services+=("${_special_arr[@]}")
        elif [[ "$service" != "all" ]]; then
            local mapped_service=$(map_service_name "$service")
            # 对于restart操作，将Web服务器单独分类
            if [[ "$operation" == "restart" && ("$mapped_service" == "nginx" || "$mapped_service" == "tengine") ]]; then
                web_services+=("$mapped_service")
            else
                final_services+=("$mapped_service")
            fi
        fi
    done

    # 如果不是restart操作，将Web服务器重新加回到final_services
    if [[ "$operation" != "restart" && ${#web_services[@]} -gt 0 ]]; then
        final_services+=("${web_services[@]}")
        web_services=()  # 清空web_services数组
    fi

    # 自动添加MySQL备份服务
    auto_add_mysql_backup final_services "$operation"

    # monitoring 栈服务按运行态动态启停：
    # 当 exporter 不在本次 final_services 中时，主动停止旧容器，避免出现“未启用服务仍在监控运行”。
    if [[ "$operation" == "up" || "$operation" == "start" || "$operation" == "restart" ]]; then
        local _contains_monitoring=false
        for _svc in "${services[@]}"; do
            case "$_svc" in
                monitoring|prometheus|grafana|alertmanager|loki|promtail|cadvisor|node-exporter|blackbox-exporter|mysql-exporter|mongo-exporter|postgres-exporter|redis-exporter|valkey-exporter|nginx-exporter|tengine-exporter)
                    _contains_monitoring=true
                    break
                    ;;
            esac
        done

        if [[ "$_contains_monitoring" == "true" ]]; then
            local _monitoring_exporters=(mysql-exporter mongo-exporter postgres-exporter redis-exporter valkey-exporter nginx-exporter tengine-exporter)
            local _stale_exporters=()
            local _exp _enabled

            for _exp in "${_monitoring_exporters[@]}"; do
                _enabled=false
                for _svc in "${final_services[@]}"; do
                    if [[ "$_svc" == "$_exp" ]]; then
                        _enabled=true
                        break
                    fi
                done
                if [[ "$_enabled" == "false" ]]; then
                    _stale_exporters+=("$_exp")
                fi
            done

            if [[ ${#_stale_exporters[@]} -gt 0 ]]; then
                local _compose_cmd
                _compose_cmd=$(get_docker_compose_cmd)
                info "停止未启用的 monitoring exporter: ${_stale_exporters[*]}"
                dry_run_or_exec_words "$_compose_cmd" -f compose/stacks/monitoring.yaml stop "${_stale_exporters[@]}" >/dev/null 2>&1 || true
            fi
        fi
    fi

    # 提示信息
    if [[ "$operation" == "restart" && ${#web_services[@]} -gt 0 ]]; then
        info "检测到Web服务器 (${web_services[*]})，将在其他服务重启完成后最后重启"
    fi

    # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
    local compose_cmd=$(get_docker_compose_cmd)

    # hosts 同步将在 up/start 完成后执行，避免容器 IP 未就绪

    # 构建Docker命令
    _apply_elasticsearch_bootstrap_memory_lock_env "$compose_files"
    local docker_cmd="$compose_cmd $compose_files"
    # 为 compose 添加 --env-file （必须），确保容器变量从运行时配置展开
    # 不使用 --env-file 时 docker compose 只从当前 shell环境/项目默认 .env 读取变量，
    # 而 .env.runtime 是脚本层将所有 env/*.env 层叠后的最终结果，必须显式传入。
    local _env_runtime="${PROJECT_DIR}/.env.runtime"
    if [[ -f "$_env_runtime" ]]; then
        docker_cmd="$compose_cmd --env-file $_env_runtime $compose_files"
    fi

    case "$operation" in
        up|start)
            # 检查镜像是否存在
            if [[ ${#final_services[@]} -gt 0 ]]; then
                missing_images=()
                for service in "${final_services[@]}"; do
                    local _svc_project
                    _svc_project=$(get_compose_project_for_service "$service")
                    local image_name="${_svc_project}_${service}:latest"
                    local has_image=false

                    # SGR 栈使用官方镜像（非 hg_dnmpr_* 命名），按真实镜像名判断是否已存在
                    case "$service" in
                        spug)
                            if cr_cmd images --format "{{.Repository}}:{{.Tag}}" | grep -q "^openspug/spug-service:latest$" 2>/dev/null; then
                                has_image=true
                            fi
                            ;;
                        gitea)
                            if cr_cmd images --format "{{.Repository}}:{{.Tag}}" | grep -q "^gitea/gitea:latest$" 2>/dev/null; then
                                has_image=true
                            fi
                            ;;
                        rap2-dolores)
                            if cr_cmd images --format "{{.Repository}}:{{.Tag}}" | grep -q "^rapteam/rap2-dolores:latest$" 2>/dev/null; then
                                has_image=true
                            fi
                            ;;
                        rap2-delos)
                            if cr_cmd images --format "{{.Repository}}:{{.Tag}}" | grep -q "^rapteam/rap2-delos:latest$" 2>/dev/null; then
                                has_image=true
                            fi
                            ;;
                    esac

                    # monitoring 栈使用官方 image，
                    # 不依赖本地 build.sh 产物，直接允许 up/start。
                    case "$service" in
                        prometheus|grafana|alertmanager|loki|promtail|cadvisor|node-exporter|blackbox-exporter|mysql-exporter|mongo-exporter|postgres-exporter|redis-exporter|valkey-exporter|nginx-exporter|tengine-exporter|syncer-prometheus|syncer-grafana)
                            has_image=true
                            ;;
                    esac

                    # 检查镜像名称：hg_dnmpr_nginx, hg_dnmpr_php74_apache 等
                    if _cr_has_image "${image_name}"; then
                        has_image=true
                    fi

                    # mysql_backup 使用 mysql 镜像
                    if [[ "$has_image" == "false" && "$service" == "mysql_backup" ]]; then
                        if _cr_has_image "hg_dnmpr_mysql:latest"; then
                            has_image=true
                        fi
                    fi

                    # Syncer 在 compose 中显式 image: syncer:latest，兼容该命名
                    # Podman 本地构建的镜像带 localhost/ 前缀，使用 _cr_has_image 统一匹配
                    if [[ "$has_image" == "false" && "$service" == "syncer" ]]; then
                        if _cr_has_image "syncer:latest"; then
                            has_image=true
                        fi
                    fi

                    # ELK 服务使用显式镜像名称：hg_dnmpr_elk_elasticsearch, hg_dnmpr_elk_kibana, hg_dnmpr_elk_logstash
                    if [[ "$has_image" == "false" ]]; then
                        case "$service" in
                            elasticsearch)
                                if _cr_has_image "hg_dnmpr_elk_elasticsearch:latest"; then
                                    has_image=true
                                fi
                                ;;
                            kibana)
                                if _cr_has_image "hg_dnmpr_elk_kibana:latest"; then
                                    has_image=true
                                fi
                                ;;
                            logstash)
                                if _cr_has_image "hg_dnmpr_elk_logstash:latest"; then
                                    has_image=true
                                fi
                                ;;
                        esac
                    fi

                    # RabbitMQ：compose/stacks/rabbitmq.yaml 中为 image: hg_dnmpr_rabbitmq:latest，
                    # 并非 ${project}_${service}（否则会误查 hg_dnmpr_rabbitmq_rabbitmq:latest）。
                    if [[ "$has_image" == "false" && "$service" == "rabbitmq" ]]; then
                        if _cr_has_image "hg_dnmpr_rabbitmq:latest"; then
                            has_image=true
                        fi
                    fi

                    if [[ "$has_image" == "false" ]]; then
                        missing_images+=("$service")
                    fi
                done

                if [[ ${#missing_images[@]} -gt 0 ]]; then
                    echo -e "${YELLOW}⚠️  检测到以下服务的镜像未构建：${missing_images[*]}${NC}"
                    echo ""
                    # dry-run 模式不依赖本地镜像是否已构建，继续输出将执行的 compose 命令。
                    if [[ "${DRY_RUN:-false}" == "true" ]]; then
                        info "[DRY-RUN] 跳过镜像构建检查，继续输出计划: ${missing_images[*]}"
                        missing_images=()
                    else
                        echo -e "${CYAN}是否要构建这些镜像？${NC}"
                        echo -e "  ${GREEN}y/Y${NC} - 是，构建镜像并启动服务"
                        echo -e "  ${RED}n/N${NC} - 否，跳过未构建的服务"
                        echo -e "  ${YELLOW}q/Q${NC} - 退出操作"
                        echo ""
                        read -p "请选择 [y/n/q]: " choice
                    fi

                    # dry-run 模式默认选择 n（跳过未构建服务）
                    if [[ "${DRY_RUN:-false}" == "true" ]]; then
                        choice="n"
                    fi

                    case "$choice" in
                        [Yy]*)
                            info "开始构建镜像: ${missing_images[*]}"

                            # 处理服务名反向映射：把 compose 服务名转换为 build.sh 参数
                            local build_services=()
                            local elk_added=false
                            for service in "${missing_images[@]}"; do
                                local build_param=$(unmap_service_name_for_build "$service")

                                # ELK 组件统一映射为 elk，避免重复
                                if [[ "$build_param" == "elk" ]]; then
                                    if [[ "$elk_added" == "false" ]]; then
                                        build_services+=("elk")
                                        elk_added=true
                                    fi
                                else
                                    build_services+=("$build_param")
                                fi
                            done

                            local build_cmd=(./build.sh "${build_services[@]}")
                            if [[ -n "$BUILD_IGNOREFILE" ]]; then
                                build_cmd+=(--ignorefile "$BUILD_IGNOREFILE")
                            fi

                            if "${build_cmd[@]}"; then
                                success "镜像构建完成，继续启动服务"
                            else
                                error "镜像构建失败，操作终止"
                                return 1
                            fi
                            ;;
                        [Nn]*)
                            # 从服务列表中移除未构建的服务
                            local available_services=()
                            for service in "${final_services[@]}"; do
                                local found=false
                                for missing in "${missing_images[@]}"; do
                                    if [[ "$service" == "$missing" ]]; then
                                        found=true
                                        break
                                    fi
                                done
                                if [[ "$found" == "false" ]]; then
                                    available_services+=("$service")
                                fi
                            done

                            if [[ ${#available_services[@]} -eq 0 ]]; then
                                warn "没有可启动的服务，操作终止"
                                return 1
                            fi

                            final_services=("${available_services[@]}")
                            info "将启动已构建的服务: ${final_services[*]}"
                            ;;
                        [Qq]*)
                            info "操作已取消"
                            return 1
                            ;;
                        *)
                            warn "无效选择，操作已取消"
                            return 1
                            ;;
                    esac
                fi
            fi

            docker_cmd="$docker_cmd up --no-build"
            if [[ "$options" =~ -d|--detach ]]; then
                docker_cmd="$docker_cmd -d"
            fi

            # podman-compose 对 depends_on condition: service_healthy 支持不完整，
            # 此处增加外部等待循环确保依赖服务就绪后再启动下游
            if cr_is_podman && [[ "$COMPOSE_CMD" == "podman-compose" ]]; then
                info "podman-compose 模式: 启用外部健康检查降级方案"
                _podman_healthcheck_fallback "${final_services[@]}" || true
            fi
            ;;
        stop)
            docker_cmd="$docker_cmd stop"
            ;;
        restart)
            # 主栈（含 compose/base/compose/main.yaml）：force-recreate 以便应用新构建镜像层（如 PHP supervisor）。
            # 独立栈（仅 ELK/RabbitMQ/Syncer 等 yaml）：勿 force-recreate，否则会按当前 shell 重新展开卷变量，
            # 若 elk.dev.env / elk.prod.env 与首次创建容器时不一致，Elasticsearch 会挂错目录，表现为索引数据「丢失」。
            local _restart_use_recreate=true
            if [[ "$compose_files" != *"compose/main.yaml"* ]]; then
                _restart_use_recreate=false
            fi
            if [[ ${#web_services[@]} -gt 0 && ${#final_services[@]} -gt 0 ]]; then
                if cr_is_podman; then
                    info "restart → compose restart（Podman：后端先、Web 后，避免 force-recreate 依赖冲突）"
                    info "步骤1: 重启后端服务 ($(format_services_inline "${final_services[@]}"))"
                    compose_cmd_quiet "$compose_cmd $compose_files restart $(IFS=' '; echo "${final_services[*]}")" || return $?
                    if [[ "${DRY_RUN:-false}" != "true" ]]; then
                        info "等待后端服务就绪..."
                        sleep 3
                    fi
                    info "步骤2: 重启 Web 服务 ($(format_services_inline "${web_services[@]}"))"
                    compose_cmd_quiet "$compose_cmd $compose_files restart $(IFS=' '; echo "${web_services[*]}")" || return $?
                else
                    info "restart → up -d --no-build --force-recreate（主栈：应用当前本地镜像层）"
                    info "步骤1: 重新创建并启动后端服务 (${final_services[*]})"
                    docker_cmd="$docker_cmd up -d --no-build --force-recreate $(IFS=' '; echo "${final_services[*]}")"
                    dry_run_or_exec bash -c "$docker_cmd"

                    if [[ "${DRY_RUN:-false}" != "true" ]]; then
                        info "等待后端服务就绪..."
                        sleep 3
                    fi

                    info "步骤2: 重新创建并启动 Web 服务 (${web_services[*]})"
                    docker_cmd="$compose_cmd $compose_files up -d --no-build --force-recreate $(IFS=' '; echo "${web_services[*]}")"
                    dry_run_or_exec bash -c "$docker_cmd"
                fi
                if ! is_elk_only_services "${final_services[@]}"; then
                    sync_hosts_aliases "$operation" "${final_services[*]} ${web_services[*]}"
                fi
                return
            elif [[ ${#web_services[@]} -gt 0 && ${#final_services[@]} -eq 0 ]]; then
                if cr_is_podman; then
                    info "restart → compose restart（Podman：主栈 Web）"
                    docker_cmd="$docker_cmd restart $(IFS=' '; echo "${web_services[*]}")"
                else
                    info "restart → up -d --no-build --force-recreate（主栈 Web）"
                    docker_cmd="$docker_cmd up -d --no-build --force-recreate $(IFS=' '; echo "${web_services[*]}")"
                fi
            elif [[ "$_restart_use_recreate" == "false" ]]; then
                info "restart 独立栈：使用 compose restart（保留卷挂载；更新镜像请用 up -d --force-recreate <服务>）"
                docker_cmd="$docker_cmd restart"
            else
                if cr_is_podman; then
                    info "restart → compose restart（Podman：主栈，避免 force-recreate 依赖/重名冲突）"
                    docker_cmd="$docker_cmd restart"
                else
                    info "restart → up -d --no-build --force-recreate（应用当前本地镜像层）"
                    docker_cmd="$docker_cmd up -d --no-build --force-recreate"
                fi
            fi
            ;;
        down)
            docker_cmd="$docker_cmd down"
            ;;
        logs)
            docker_cmd="$docker_cmd logs"
            if [[ "$options" =~ -f|--follow ]]; then
                docker_cmd="$docker_cmd -f"
            fi
            if [[ "$options" =~ --tail[[:space:]]+([0-9]+) ]]; then
                local tail_lines="${BASH_REMATCH[1]}"
                docker_cmd="$docker_cmd --tail $tail_lines"
            fi
            ;;
        ps)
            docker_cmd="$docker_cmd ps"
            ;;
        exec)
            if [[ ${#final_services[@]} -eq 0 ]]; then
                error "exec操作需要指定具体的服务名"
            fi
            local service_name="${final_services[0]}"
            docker_cmd="$docker_cmd exec $service_name bash"
            ;;
        *)
            error "未知操作: $operation"
            ;;
    esac

    # 添加服务名（除了某些特殊操作）
    if [[ "$operation" != "exec" ]] && [[ ${#final_services[@]} -gt 0 ]]; then
        docker_cmd="$docker_cmd $(IFS=' '; echo "${final_services[*]}")"
    fi

    # ── monitoring 栈自动配置生成 ───────────────────────────────────────────
    if [[ "$operation" == "up" || "$operation" == "start" || "$operation" == "restart" ]]; then
        local _is_monitoring_stack=false
        for _svc in "${services[@]}" "${final_services[@]}"; do
            case "$_svc" in
                monitoring|prometheus|grafana|alertmanager|loki|promtail|cadvisor|node-exporter|blackbox-exporter|mysql-exporter|mongo-exporter|postgres-exporter|redis-exporter|valkey-exporter|nginx-exporter|tengine-exporter)
                    _is_monitoring_stack=true
                    break
                    ;;
            esac
        done
        if [[ "$_is_monitoring_stack" == "true" ]]; then
            local _monitoring_generator="$PROJECT_DIR/include/shell/generate-monitoring-config.sh"
            if [[ -f "$_monitoring_generator" ]]; then
                dry_run_or_exec bash "$_monitoring_generator"
            else
                warn "监控配置生成脚本不存在: $_monitoring_generator"
            fi
        fi
    fi

    # ── 确保主网络 hg_dnmpr_network 存在 ──────────────────────────────────
    # compose/main.yaml 及所有独立栈（elk/rabbitmq/syncer/sgr/monitoring）均将
    # hg_dnmpr_network 声明为 external，Docker Compose 不会自动创建。
    # 若网络不存在，compose up 会直接报错拒绝启动。
    # 此处在所有 up/start/restart 操作时统一预建网络（首次启动或网络被清理后）。
    if [[ "$operation" == "up" || "$operation" == "start" || "$operation" == "restart" ]]; then
        if ! cr_cmd network inspect hg_dnmpr_network >/dev/null 2>&1; then
            info "hg_dnmpr_network 不存在，自动创建..."
            local _net_create_args=(--driver bridge --subnet 172.20.0.0/24)
            # Docker 专有 opts：Podman 不支持 com.docker.*
            if cr_is_docker; then
                _net_create_args+=(--opt com.docker.network.enable_ipv6=false)
                _net_create_args+=(--opt com.docker.network.bridge.name=br-hg-dnmpr)
            fi
            if [[ "${DRY_RUN:-false}" == "true" ]]; then
                echo -e "${CYAN}[DRY-RUN]${NC} ${CR:-docker} network create ${_net_create_args[*]} hg_dnmpr_network"
            else
                cr_cmd network create "${_net_create_args[@]}" hg_dnmpr_network \
                    && success "hg_dnmpr_network 创建成功" \
                    || {
                        if cr_cmd network inspect hg_dnmpr_network >/dev/null 2>&1; then
                            info "hg_dnmpr_network 已由其他进程创建，继续..."
                        else
                            error "hg_dnmpr_network 创建失败，请检查 $CR 权限或手动执行：\n  $CR network create --driver bridge --subnet 172.20.0.0/24 hg_dnmpr_network"
                        fi
                    }
            fi
        else
            info "hg_dnmpr_network 已存在，跳过创建"
        fi
    fi

    # 防火墙预检（up/start/restart 操作，advisory 模式：任何内部错误均不阻塞启动）
    # ensure_firewall_ready 设计为始终返回 0，但因本脚本 set -euo pipefail，
    # 函数内任何未捕获的命令失败都会导致整个 up.sh 退出。
    # 用 set +e 包裹确保预检永远不会中断服务启动流程。
    # dry-run 模式跳过防火墙预检（无需网络操作）
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        if [[ "$operation" == "up" || "$operation" == "start" || "$operation" == "restart" ]]; then
            if [[ "$split_depth" -eq 0 ]]; then
                set +eE
                FW_AUTO_ALLOW_MISSING_PORTS=true ensure_firewall_ready "$compose_files" "${final_services[@]}"
                set -Ee
            fi
        fi
    fi

    # 执行命令
    log "执行命令: $docker_cmd"
    info "操作: $operation"
    info "环境: $environment"
    info "服务: ${final_services[*]:-所有服务}"

    # 为前台启动设置Ctrl+C清理trap（dry-run 模式跳过）
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        if [[ "$operation" == "up" || "$operation" == "start" ]]; then
            if [[ ! "$options" =~ (-d|--detach) ]]; then
                trap 'echo ""; info "检测到中断信号，正在清理 hosts..."; cache_containers_for_cleanup; sync_hosts_aliases "down"; trap - INT TERM; exit 130' INT TERM
                trap_set=true
            fi
        fi
    fi

    # 确保 bind mount 宿主机目录存在（避免 podman statfs no such file）；Podman 下同时做 uid 映射
    if [[ "${DRY_RUN:-false}" != "true" ]] && [[ "$operation" == "up" || "$operation" == "start" || "$operation" == "restart" ]]; then
        if cr_is_podman; then
            _podman_prepare_all_bind_mounts_from_compose "$compose_files"
        else
            _ensure_compose_bind_dirs "$compose_files"
        fi
    fi

    # detach 模式，以及 Podman 下的 down：过滤已知噪声（stderr+stdout 合并），detach 时加超时防止卡死
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo -e "${CYAN}[DRY-RUN]${NC} bash -c '$docker_cmd'"
        local cmd_status=0
    # Podman：podman-compose down [服务] 会对 compose 中的容器名执行 stop/rm；容器已不存在时
    # Podman 仍打印 Error: no such container（幂等噪声）。与 up -d 分支一致，在此过滤。
    elif [[ "$docker_cmd" == *" -d"* || "$docker_cmd" == *"--detach"* ]] \
        || { [[ "$operation" == "down" ]] && cr_is_podman; }; then
        local _noise='(^[0-9a-f]{64}$|cgroup is not set|is not a valid container, cannot be used as a dependency|no container with .* found: no such container|^(php[0-9]{2}_apache|nginx|tengine|mysql|mongo|redis|valkey|postgres|pgadmin|mysql_backup|mongo_backup|postgres_backup|elasticsearch|kibana|logstash|rabbitmq|canal-server|syncer|spug|gitea|rap2-dolores|rap2-delos)$)'
        local _dc_out
        # ELK：Elasticsearch 冷启动 + healthcheck + 依赖服务编排，Podman 下常超过 600s
        local _compose_to=600
        if [[ "$docker_cmd" == *compose/stacks/elk.yaml* ]] || [[ "$compose_files" == *compose/stacks/elk.yaml* ]]; then
            _compose_to=1800
        fi
        _dc_out=$(timeout "$_compose_to" bash -c "$docker_cmd" 2>&1) || true
        local cmd_status=${PIPESTATUS[0]}
        # 网络活跃端点冲突自动处理：存在活跃端点时 stop 冲突容器 → 重试 → 成功后恢复原容器
        if [[ $cmd_status -ne 0 ]] && echo "$_dc_out" | grep -q "has active endpoints"; then
            warn "网络重建失败（存在活跃端点），尝试停止冲突容器后重试..."
            local _active_names
            _active_names=$(echo "$_dc_out" | grep -oP 'name:"\K[^"]+' | sort -u | tr '\n' ' ' || true)
            for _an in $_active_names; do
                cr_cmd stop "$_an" >/dev/null 2>&1 || true
            done
            _dc_out=$(timeout "$_compose_to" bash -c "$docker_cmd" 2>&1) || true
            cmd_status=${PIPESTATUS[0]}
            if [[ $cmd_status -eq 0 ]]; then
                for _an in $_active_names; do
                    cr_cmd start "$_an" >/dev/null 2>&1 || true
                    info "已恢复容器: $_an"
                done
            fi
        fi
        if [[ -n "$_dc_out" ]]; then
            printf "%s\n" "$_dc_out" | grep -vE "$_noise" || true
        fi
        # exit 124 = timeout kill。detach 模式下容器会继续在后台启动，超时不代表失败，
        # 重置为 0 避免误报并阻断多栈分步流程。
        if [[ $cmd_status -eq 124 ]]; then
            warn "podman-compose 执行超时（${_compose_to}s），容器可能仍在后台启动。ELK 请检查: podman logs elasticsearch（常见：数据目录权限或 JVM 内存不足）"
            cmd_status=0
        fi
        # rootless crun 竞态条件容错：检测 exec.fifo 错误并自动重试
        # 症状: crun 高并发创建容器时 /run/user/UID/crun/.../exec.fifo 短暂不可用
        # 影响: kibana/logstash 等依赖 ES 的服务在第一次 up 时可能启动失败
        if [[ -n "$_dc_out" ]] && echo "$_dc_out" | grep -q "exec.fifo.*No such file"; then
            local _fifo_svcs
            _fifo_svcs=$(echo "$_dc_out" | grep -oP '\[([a-z]+)\]' | sed 's/\[//g;s/\]//g' | sort -u | tr '
' ' ' || true)
            if [[ -n "$_fifo_svcs" ]]; then
                warn "rootless crun exec.fifo 竞态导致以下服务启动失败: ${_fifo_svcs}"
                info "等待 5s 后自动重试启动失败的服务..."
                sleep 5
                for _svc in $_fifo_svcs; do
                    [[ "$_svc" == "elasticsearch" ]] && continue
                    info "重试启动 $_svc ..."
                    timeout 120 bash -c "$compose_cmd $compose_files up -d --no-build $_svc" 2>&1 | grep -vE "$_noise" || true
                done
                cmd_status=0
            fi
        fi
    else
        # 对于 down 操作且指定了服务名，先尝试标准 compose down，
        # 若因全量配置解析失败（如 .env.runtime 未加载导致空变量），
        # 则降级为直接 docker stop + rm 停止指定容器，避免服务残留。
        if [[ "$operation" == "down" ]] && [[ ${#final_services[@]} -gt 0 ]]; then
            local _down_status=0
            # 注意：脚本全局有 set -e，必须用 || 与赋值防止失败时直接退出
            bash -c "$docker_cmd" 2>&1 || _down_status=$?
            if [[ $_down_status -ne 0 ]]; then
                warn "compose down 失败（退出码 $_down_status），降级为直接 stop+rm 容器..."
                for _svc in "${final_services[@]}"; do
                    local _ct_names
                    # 先精确匹配容器名（container_name 通常与服务名相同）
                    _ct_names=$(cr_cmd ps -a --filter "name=^${_svc}$" --format "{{.Names}}" 2>/dev/null || true)
                    if [[ -z "$_ct_names" ]]; then
                        # 退而求其次：模精匹配（含 compose 项目名前缀的容器名）
                        _ct_names=$(cr_cmd ps -a --filter "name=${_svc}" --format "{{.Names}}" 2>/dev/null || true)
                    fi
                    if [[ -n "$_ct_names" ]]; then
                        info "停止并删除容器: $_ct_names"
                        cr_cmd stop $_ct_names 2>/dev/null || true
                        cr_cmd rm $_ct_names 2>/dev/null || true
                    else
                        warn "未找到容器: $_svc"
                    fi
                done
            fi
            local cmd_status=0  # 降级处理后视为成功
        else
            bash -c "$docker_cmd"
            local cmd_status=$?
        fi
    fi

    if [[ "$trap_set" == "true" ]]; then
        trap - INT TERM
    fi

    # ELK 生产环境：自动同步 kibana_system 密码
    # 问题：setup-kibana-password 在 ES 首次冷启动时执行，但 ES security index
    #       尚未就绪（green 之后才可写），导致 kibana_system 密码未设置。
    # 症状：kibana 报 "unable to authenticate user [kibana_system]"
    # 修复：在此处检测并对齐 kibana_system 密码与 elastic 密码
    if [[ "$operation" == "up" || "$operation" == "start" ]] && [[ "$cmd_status" -eq 0 ]]; then
        local _sync_elk=false
        for _s in "${services[@]}" "${final_services[@]}"; do
            case "$_s" in elk|elasticsearch|kibana|logstash) _sync_elk=true; break ;; esac
        done
        if [[ "$_sync_elk" == "true" ]]; then
            _sync_kibana_system_password || true
        fi
    fi

    # 启动/重启完成后同步 hosts（force-recreate 后容器 IP 可能变化）
    # ELK 服务不需要注册到 /etc/hosts，仅操作 ELK 时跳过同步
    # dry-run 模式跳过 hosts 同步（无需修改系统文件）
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        if [[ "$operation" == "up" || "$operation" == "start" || "$operation" == "restart" ]]; then
            if [[ ${#final_services[@]} -gt 0 ]]; then
                if ! is_elk_only_services "${final_services[@]}"; then
                    sync_hosts_aliases "$operation" "${final_services[*]}"
                fi
            else
                sync_hosts_aliases "$operation"
            fi
        fi
    else
        info "[DRY-RUN] 跳过 hosts 别名同步"
    fi

    return $cmd_status
}


# ELK 生产环境：自动同步 kibana_system 密码
# ES 首次冷启动时 security index 尚未就绪，docker-entrypoint 的 setup-kibana-password
# 脚本会因 ES 不可达而静默跳过，导致 kibana_system 密码未被设置为 elastic 密码的值。
# 此函数在 compose up 成功后检测并对齐密码，解决 kibana 认证失败问题。
_sync_kibana_system_password() {
    # 仅在 security enabled + 生产环境才需要同步（dev 无密码）
    [[ "${ELK_SECURITY_ENABLED:-false}" != "true" ]] && return 0

    local _es_ct="elasticsearch"
    # 确认 ES 容器在运行
    cr_cmd inspect --format '{{.State.Running}}' "$_es_ct" 2>/dev/null | grep -q "true" || return 0

    local _es_pass="${ELASTIC_PASSWORD:-${KIBANA_ELASTICSEARCH_PASSWORD:-}}"
    [[ -z "$_es_pass" ]] && { warn "未找到 ELASTIC_PASSWORD，跳过 kibana_system 密码同步"; return 0; }

    # 确定协议
    local _proto="http"
    local _tls_flag=""
    [[ "${ELK_HTTP_SSL_ENABLED:-false}" == "true" ]] && { _proto="https"; _tls_flag="-k"; }

    info "ELK: 检查 kibana_system 密码是否与 elastic 一致..."

    # 等待 ES cluster health 为 green/yellow（确保 security index 可写）
    local _attempt=0
    local _max_attempts=30
    while [[ $_attempt -lt $_max_attempts ]]; do
        local _health
        _health=$(cr_cmd exec "$_es_ct" curl -s $_tls_flag -u "elastic:$_es_pass"             "${_proto}://localhost:9200/_cluster/health" 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "")
        if [[ "$_health" == "green" || "$_health" == "yellow" ]]; then
            break
        fi
        sleep 2
        _attempt=$((_attempt + 1))
    done

    # 直接设置 kibana_system 密码为 elastic 密码（幂等操作）
    local _set_result
    _set_result=$(cr_cmd exec "$_es_ct" curl -s $_tls_flag -X POST \
        -u "elastic:$_es_pass" \
        -H "Content-Type: application/json" \
        -d '{"password":"'"$_es_pass"'"}' \
        "${_proto}://localhost:9200/_security/user/kibana_system/_password" 2>/dev/null || echo "")

    if echo "$_set_result" | grep -q "^{}"; then
        success "ELK: kibana_system 密码已同步（与 elastic 一致）"
    elif [[ -z "$_set_result" ]]; then
        warn "ELK: kibana_system 密码同步请求未得到响应，kibana 可能仍无法认证"
    else
        info "ELK: kibana_system 密码同步完成: $_set_result"
    fi
}


# P18: podman-compose 外部健康检查降级方案
# podman-compose 1.x 对 depends_on condition: service_healthy 支持不完整，
# 此函数在 compose up 后轮询依赖服务的健康状态，超时后继续但不阻塞
_podman_healthcheck_fallback() {
    local _svcs=("$@")
    local _max_wait=120  # 最多等 2 分钟
    local _interval=5
    local _waited=0

    for _svc in "${_svcs[@]}"; do
        case "$_svc" in
            php74_apache|php80_apache|php81_apache|php82_apache|php83_apache|php84_apache|php85_apache)
                info "等待 $_svc 健康就绪..."
                while [[ $_waited -lt $_max_wait ]]; do
                    if cr_cmd inspect --format '{{.State.Health.Status}}' "$_svc" 2>/dev/null | grep -q "healthy"; then
                        info "$_svc 已健康就绪"
                        break
                    fi
                    sleep "$_interval"
                    _waited=$((_waited + _interval))
                done
                [[ $_waited -ge $_max_wait ]] && warn "$_svc 健康检查超时(${_max_wait}s)，继续启动下游服务"
                ;;
        esac
    done
    return 0
}

# _ensure_elasticsearch_host_data_writable
# ES 镜像以 USER 1000:0 运行；Docker 为缺失的 bind 路径自动 mkdir 时属主多为 root:root/755，
# 导致 /usr/share/elasticsearch/data/node.lock → AccessDeniedException → unhealthy。
# 在 up/start/restart 前把宿主机数据目录（及 host-path 日志目录）对齐为 1000:0 / 0775。
_ensure_elasticsearch_host_data_writable() {
    local _data="${ELASTICSEARCH_DATA_PATH:-}"
    if [[ -z "$_data" && -n "${DATA_PATH_HOST:-}" ]]; then
        _data="${DATA_PATH_HOST%/}/${ELASTICSEARCH_DATA_SUBDIR:-elasticsearch}"
    fi
    [[ -z "$_data" || "$_data" == /* ]] || return 0  # 仅处理绝对宿主机路径；命名卷跳过

    mkdir -p "$_data" 2>/dev/null || true
    if [[ -d "$_data" ]]; then
        if ! chown -R 1000:0 "$_data" 2>/dev/null; then
            warn "无法 chown 1000:0 $_data（可能需要 root）；ES 可能因 node.lock 权限失败"
        else
            chmod 0775 "$_data" 2>/dev/null || true
        fi
    fi

    local _log="${ELASTICSEARCH_LOG_DIR:-}"
    if [[ -n "$_log" && "$_log" == /* ]]; then
        mkdir -p "$_log" 2>/dev/null || true
        chown -R 1000:0 "$_log" 2>/dev/null || true
        chmod 0775 "$_log" 2>/dev/null || true
    fi
}

# _ensure_compose_bind_dirs <compose_files>
# Docker 模式：解析 compose bind，展开环境变量与相对路径后 mkdir（Podman 见 _podman_prepare_all_bind_mounts_from_compose）
_ensure_compose_bind_dirs() {
    if declare -F _compose_ensure_bind_dirs_mkdir_from_files &>/dev/null; then
        set +e
        _compose_ensure_bind_dirs_mkdir_from_files "$1"
        set -e
    fi
    _ensure_elasticsearch_host_data_writable
}
