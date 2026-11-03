#!/bin/bash
# ==========================================
# hosts_manager.sh — /etc/hosts 别名管理
# ==========================================

# 同步 hosts 别名映射（调用 scripts/update-hosts-aliases.sh）
sync_hosts_aliases() {
    local operation="$1"
    local services_list="${2:-}"  # 可选：指定服务列表，用空格分隔
    local mode="update"

    case "$operation" in
        stop|down|delete|purge|clean-all|clear|prune)
            mode="delete"
            ;;
        *)
            mode="update"
            ;;
    esac

    local script="$SCRIPT_DIR/scripts/update-hosts-aliases.sh"

    if [[ ! -f "$script" ]]; then
        warn "未找到 hosts 同步脚本: $script"
        return 0
    fi

    # 如果是update模式，等待容器完全启动
    if [[ "$mode" == "update" ]]; then
        info "等待容器启动完成..."
        sleep 3

        # 检查容器是否已经获得IP（最多等待30秒）
        local max_wait=30
        local waited=0
        while [[ $waited -lt $max_wait ]]; do
            local running_containers
            running_containers=$(cr_cmd ps -q 2>/dev/null | wc -l | tr -d ' ' || true)
            [[ -z "$running_containers" ]] && running_containers=0
            if [[ $running_containers -gt 0 ]]; then
                # 检查是否所有运行中的容器都有IP
                local containers_with_ip
                containers_with_ip=$(cr_cmd ps -q 2>/dev/null | xargs -r -I {} cr_cmd inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' {} 2>/dev/null | grep -cv '^$' || true)
                [[ -z "$containers_with_ip" ]] && containers_with_ip=0
                if [[ $containers_with_ip -eq $running_containers ]] || [[ $waited -ge 10 ]]; then
                    break
                fi
            fi
            sleep 2
            waited=$((waited + 2))
        done

        if [[ -n "${WSL_DISTRO_NAME:-}" ]] || (grep -qi "microsoft\|wsl" /proc/version 2>/dev/null); then
            info "同步 hosts 别名到 /etc/hosts 和 Windows hosts (mode=$mode)..."
        else
            info "同步 hosts 别名到 /etc/hosts (mode=$mode)..."
        fi
    else
        info "清理 hosts 别名 (mode=$mode)..."
    fi

    if ! bash "$script" --mode "$mode"; then
        warn "同步 hosts 失败，请检查权限或脚本输出"
    fi
}

# 在容器停止/删除前，预先缓存容器信息用于清理hosts
cache_containers_for_cleanup() {
    local script="$SCRIPT_DIR/scripts/update-hosts-aliases.sh"
    if [[ ! -f "$script" ]]; then
        return 0
    fi

    # 强制更新缓存（即使不修改hosts文件）
    local cache_file="$HOSTS_CACHE_FILE"
    local entries=()
    local cids
    cids=$(cr_cmd ps -q 2>/dev/null || true)

    if [[ -n "$cids" ]]; then
        while read -r cid; do
            [[ -z "$cid" ]] && continue
            local ip name aliases alias_list
            ip=$(cr_cmd inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null | xargs)
            if [[ -n "$ip" ]]; then
                name=$(cr_cmd inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')
                aliases=$(cr_cmd inspect -f '{{range .NetworkSettings.Networks}}{{range $i,$a := .Aliases}}{{$a}} {{end}}{{end}}' "$cid" 2>/dev/null | xargs)
                alias_list="$name $aliases"
                alias_list=$(echo "$alias_list" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | xargs)
                [[ -z "$alias_list" ]] && alias_list="$name"
                entries+=("$ip $alias_list")
            fi
        done <<< "$cids"
    fi

    if [[ ${#entries[@]} -gt 0 ]]; then
        mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true
        if printf "%s\n" "${entries[@]}" > "$cache_file" 2>/dev/null; then
            info "已缓存 ${#entries[@]} 个容器信息用于清理 hosts"
        else
            warn "缓存容器信息失败（路径: $cache_file），将继续执行而不使用缓存文件"
        fi
    fi
}
