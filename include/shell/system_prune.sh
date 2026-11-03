#!/bin/bash
# ==========================================
# system_prune.sh — 系统清理与资源管理
# ==========================================

# 根据 compose 项目名生成容器/镜像/网络标签过滤参数
# Docker: --filter "label=com.docker.compose.project=hg_dnmpr"
# Podman: 标签过滤支持有限，降级为无过滤
get_project_label_filter() {
    if [[ "${CLEAN_ALL_GLOBAL:-false}" == "true" ]]; then
        echo ""
        return 0
    fi
    if cr_is_podman; then
        echo ""
        return 0
    fi
    local project_label="${COMPOSE_PROJECT_NAME:-hg_dnmpr}"
    # 某些容器运行时（如旧版 docker）不支持多个 --filter 组合，
    # 只使用 project label 作为主过滤条件。
    echo "--filter label=com.docker.compose.project=${project_label}"
}

get_project_network_filter() {
    if [[ "${CLEAN_ALL_GLOBAL:-false}" == "true" ]]; then
        echo ""
        return 0
    fi

    local project_name="${COMPOSE_PROJECT_NAME:-hg_dnmpr}"
    if cr_is_podman; then
        echo "--filter name=^${project_name}_"
        return 0
    fi

    echo "--filter label=com.docker.compose.project=${project_name}"
}

get_project_volume_filter() {
    if [[ "${CLEAN_ALL_GLOBAL:-false}" == "true" ]]; then
        echo ""
        return 0
    fi

    local project_name="${COMPOSE_PROJECT_NAME:-hg_dnmpr}"
    if cr_is_podman; then
        echo "--filter name=^${project_name}_"
        return 0
    fi

    echo "--filter label=com.docker.compose.project=${project_name}"
}

is_protected_volume() {
    local volume="$1"
    if [[ "${ALLOW_DELETE_PROTECTED_VOLUMES}" == "true" ]]; then
        return 1
    fi
    local item
    IFS=',' read -r -a _protect_list <<<"$PROTECTED_VOLUMES_RAW"
    for item in "${_protect_list[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -z "$item" ]] && continue
        if [[ "$volume" == "$item" ]]; then
            return 0
        fi
    done
    return 1
}

confirm_dangerous_operation() {
    local operation="$1"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        info "[DRY-RUN] 跳过危险操作确认: ${operation}"
        return 0
    fi
    if [[ "${FORCE_DANGEROUS_OPS:-false}" == "true" ]]; then
        warn "检测到 FORCE_DANGEROUS_OPS=true，跳过交互确认"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        error "危险操作 '$operation' 需要交互确认（或显式设置 FORCE_DANGEROUS_OPS=true）"
        audit_log "BLOCKED" "非交互终端阻止危险操作 ${operation}"
        return 1
    fi
    warn "危险操作确认：请输入 '${operation}' 才会继续执行"
    read -r -p "确认字符串: " confirm
    if [[ "$confirm" != "$operation" ]]; then
        info "操作已取消"
        audit_log "CANCELLED" "危险操作 ${operation} 被用户取消"
        return 1
    fi
    return 0
}

remove_volumes_with_protection() {
    local action="$1"
    shift
    local volumes=("$@")
    local deletable=()
    local protected=()
    local volume

    for volume in "${volumes[@]}"; do
        [[ -z "$volume" ]] && continue
        if is_protected_volume "$volume"; then
            protected+=("$volume")
        else
            deletable+=("$volume")
        fi
    done

    if [[ ${#protected[@]} -gt 0 ]]; then
        warn "检测到受保护卷，已跳过删除：${protected[*]}"
        audit_log "SAFEGUARD" "跳过受保护卷删除 action=${action} volumes=${protected[*]}"
    fi

    if [[ ${#deletable[@]} -eq 0 ]]; then
        info "没有可删除的卷（已全部保护或不存在）"
        return 0
    fi

    cr_cmd volume rm "${deletable[@]}" 2>/dev/null || true
    info "已删除卷数量: ${#deletable[@]}"
    audit_log "OK" "删除卷 action=${action} count=${#deletable[@]} volumes=${deletable[*]}"
}

# 清理 Podman 未使用匿名卷（64 位 hash 命名），避免 compose 变更后残留大量匿名卷
prune_unused_anonymous_volumes() {
    cr_is_podman || return 0

    local dangling_volumes
    dangling_volumes=$(cr_cmd volume ls -qf dangling=true 2>/dev/null || true)
    if [[ -z "$dangling_volumes" ]]; then
        info "未发现未使用匿名卷"
        return 0
    fi

    local anonymous_volumes=()
    local vol
    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        if [[ "$vol" =~ ^[0-9a-f]{64}$ ]]; then
            anonymous_volumes+=("$vol")
        fi
    done <<< "$dangling_volumes"

    if [[ ${#anonymous_volumes[@]} -eq 0 ]]; then
        info "未发现 64 位 hash 命名的未使用匿名卷"
        return 0
    fi

    info "清理未使用匿名卷: ${#anonymous_volumes[@]} 个"
    dry_run_or_exec remove_volumes_with_protection "prune-anonymous" "${anonymous_volumes[@]}"
}

# 清理 rootless Podman runtime 临时目录；仅在无运行容器时执行，避免影响现有容器
cleanup_podman_rootless_runtime() {
    cr_is_podman || return 0

    local running_count
    running_count=$(cr_cmd ps -q 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    if [[ "$running_count" -gt 0 ]]; then
        info "检测到 $running_count 个运行中容器，跳过 rootless runtime 清理"
        return 0
    fi

    local runtime_dir="/run/user/$(id -u)/containers"
    if [[ ! -d "$runtime_dir" ]]; then
        info "rootless runtime 目录不存在，跳过: $runtime_dir"
        return 0
    fi

    info "清理 rootless Podman runtime 临时目录: $runtime_dir"
    dry_run_or_exec rm -rf "$runtime_dir"
}

# 系统清理操作
system_operations() {
    local operation="$1"

    case "$operation" in
        clear)
            log "执行项目资源清理（未使用的资源）..."
            local proj_filter=$(get_project_label_filter)
            if [[ -z "$proj_filter" ]]; then
                dry_run_or_exec cr_cmd system prune -f
            else
                dry_run_or_exec cr_cmd container prune -f $proj_filter 2>/dev/null || true
                dry_run_or_exec cr_cmd image prune -f $proj_filter 2>/dev/null || true
                dry_run_or_exec cr_cmd network prune -f $proj_filter 2>/dev/null || true
            fi
            # 清理无标签的中间层镜像（<none>），这些镜像没有项目标签不会被上述命令清理
            dry_run_or_exec cr_cmd image prune -f 2>/dev/null || true
            # Podman 下某些悬挂镜像在 image prune 后仍可能残留，显式二次清理：
            # 1) dangling=true 的镜像
            # 2) repository=<none> 的镜像
            local dangling_ids=""
            local none_repo_ids=""
            local image_id=""
            local image_repo=""
            while IFS= read -r image_id; do
                [[ -z "$image_id" ]] && continue
                dangling_ids+="${image_id}"$'\n'
            done < <(cr_cmd images --filter dangling=true --format "{{.ID}}" 2>/dev/null || true)

            while IFS='|' read -r image_repo image_id; do
                [[ -z "$image_id" ]] && continue
                if [[ "$image_repo" == "<none>" ]]; then
                    none_repo_ids+="${image_id}"$'\n'
                fi
            done < <(cr_cmd images --format "{{.Repository}}|{{.ID}}" 2>/dev/null || true)

            local merged_ids
            merged_ids=$(printf "%s%s" "$dangling_ids" "$none_repo_ids" | sort -u | sed '/^$/d')
            if [[ -n "$merged_ids" ]]; then
                # shellcheck disable=SC2206
                local merged_arr=($merged_ids)
                info "清理悬挂镜像(<none>/dangling): ${#merged_arr[@]} 个"
                dry_run_or_exec cr_cmd rmi -f "${merged_arr[@]}" 2>/dev/null || true
            fi
            success "项目资源清理完成"
            ;;
        delete)
            log "强制删除项目容器..."
            local proj_filter=$(get_project_label_filter)
            local containers=$(cr_cmd container ls -a -q $proj_filter)
            if [[ -n "$containers" ]]; then
                dry_run_or_exec cr_cmd container rm --force $containers
                success "项目容器已删除"
            else
                info "没有找到项目容器"
            fi
            ;;
        prune)
            confirm_dangerous_operation "prune" || exit 1
            log "清理未使用的项目资源..."
            local proj_filter=$(get_project_label_filter)
            if [[ -z "$proj_filter" ]]; then
                dry_run_or_exec cr_cmd system prune -a -f
            else
                dry_run_or_exec cr_cmd container prune -f $proj_filter 2>/dev/null || true
                dry_run_or_exec cr_cmd image prune -a -f $proj_filter 2>/dev/null || true
                dry_run_or_exec cr_cmd network prune -f $proj_filter 2>/dev/null || true
            fi
            local dangling_volumes
            dangling_volumes=$(cr_cmd volume ls -qf dangling=true $proj_filter 2>/dev/null || true)
            if [[ -n "$dangling_volumes" ]]; then
                # shellcheck disable=SC2206
                local dangling_arr=($dangling_volumes)
                dry_run_or_exec remove_volumes_with_protection "prune-dangling" "${dangling_arr[@]}"
            else
                info "未发现 dangling 卷"
            fi
            prune_unused_anonymous_volumes
            cleanup_podman_rootless_runtime
            success "项目资源清理完成"
            audit_log "OK" "执行 prune 完成（保护卷机制已生效，已尝试清理匿名卷和 rootless runtime）"
            ;;
        clean-all|purge)
            confirm_dangerous_operation "$operation" || exit 1

            local proj_filter=$(get_project_label_filter)
            local scope_label="项目"
            if [[ -z "$proj_filter" ]]; then
                scope_label="所有"
            fi

            warn "⚠️  警告：此操作将彻底清理${scope_label}容器、镜像、网络和卷！"
            echo ""
            echo -e "${YELLOW}此操作将执行以下清理：${NC}"
            echo -e "  • 停止并删除${scope_label}容器"
            echo -e "  • 删除${scope_label}镜像（包括正在使用的）"
            echo -e "  • 删除${scope_label}网络（除了默认网络）"
            echo -e "  • 删除${scope_label}卷（包括未使用的）"
            echo -e "  • 清理构建缓存"
            echo ""
            # dry-run 模式跳过交互确认
            if [[ "${DRY_RUN:-false}" != "true" ]]; then
                read -p "确认执行彻底清理？(yes/no): " confirm

                if [[ "$confirm" != "yes" && "$confirm" != "y" && "$confirm" != "Y" ]]; then
                    info "操作已取消"
                    exit 0
                fi
            else
                info "[DRY-RUN] 跳过交互确认"
            fi

            log "开始彻底清理${scope_label}Docker资源..."

            # 1. 停止并删除所有容器
            info "步骤1: 停止并删除${scope_label}容器..."
            local containers=$(cr_cmd container ls -a -q $proj_filter 2>/dev/null || echo "")
            if [[ -n "$containers" ]]; then
                dry_run_or_exec cr_cmd container stop $containers 2>/dev/null || true
                dry_run_or_exec cr_cmd container rm --force $containers 2>/dev/null || true
                info "已删除 $(echo $containers | wc -w) 个容器"
            else
                info "没有找到${scope_label}容器"
            fi

            # 2. 删除所有镜像
            info "步骤2: 删除${scope_label}镜像..."
            local images=$(cr_cmd images -q $proj_filter 2>/dev/null || echo "")
            # 标签过滤对 build.sh 直接构建（非 compose build）的镜像无效；
            # 回退：按镜像名称前缀（hg_dnmpr- 和 hg_dnmpr_）补充查找
            if [[ -z "$images" ]] && [[ "${CLEAN_ALL_GLOBAL:-false}" != "true" ]]; then
                local _proj="${COMPOSE_PROJECT_NAME:-hg_dnmpr}"
                local _by_name
                _by_name="$(cr_cmd images --format "{{.ID}}" --filter "reference=${_proj}-*" 2>/dev/null || true)"$'\n'"$(cr_cmd images --format "{{.ID}}" --filter "reference=${_proj}_*" 2>/dev/null || true)"
                images="$(echo "$_by_name" | sort -u | sed '/^$/d')"
            fi
            if [[ -n "$images" ]]; then
                # shellcheck disable=SC2086
                dry_run_or_exec cr_cmd rmi --force $images 2>/dev/null || true
                info "已删除${scope_label}镜像"
            else
                info "没有找到${scope_label}镜像"
            fi

            # 3. 删除所有网络（除了默认网络）
            info "步骤3: 删除${scope_label}自定义网络..."
            local net_filter=$(get_project_network_filter)
            local networks=$(cr_cmd network ls --filter "type=custom" -q $net_filter 2>/dev/null || echo "")
            if [[ -n "$networks" ]]; then
                dry_run_or_exec cr_cmd network rm $networks 2>/dev/null || true
                info "已删除 $(echo $networks | wc -w) 个自定义网络"
            else
                info "没有找到${scope_label}自定义网络"
            fi

            # 4. 删除所有卷
            info "步骤4: 删除${scope_label}卷..."
            local vol_filter=$(get_project_volume_filter)
            local volumes=$(cr_cmd volume ls -q $vol_filter 2>/dev/null || echo "")
            if [[ -n "$volumes" ]]; then
                # shellcheck disable=SC2206
                local volume_arr=($volumes)
                dry_run_or_exec remove_volumes_with_protection "clean-all" "${volume_arr[@]}"
            else
                info "没有找到${scope_label}卷"
            fi

            # 5. 清理构建缓存
            info "步骤5: 清理构建缓存..."
            dry_run_or_exec cr_cmd builder prune -a -f 2>/dev/null || true
            info "构建缓存清理完成"

            # 6. 最终清理
            info "步骤6: 执行最终系统清理..."
            if [[ -z "$proj_filter" ]]; then
                dry_run_or_exec cr_cmd system prune -a -f 2>/dev/null || true
            else
                dry_run_or_exec cr_cmd container prune -f $proj_filter 2>/dev/null || true
                dry_run_or_exec cr_cmd image prune -a -f $proj_filter 2>/dev/null || true
                dry_run_or_exec cr_cmd network prune -f $proj_filter 2>/dev/null || true
            fi
            prune_unused_anonymous_volumes
            cleanup_podman_rootless_runtime

            success "彻底清理完成！${scope_label}容器、镜像、网络和卷已删除，并已尝试清理匿名卷和 rootless runtime"
            audit_log "OK" "执行 ${operation} 完成（保护卷机制已生效）"
            ;;
        *)
            error "未知系统操作: $operation"
            ;;
    esac
}
