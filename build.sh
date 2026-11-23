#!/bin/bash

# ==========================================
# Docker 项目构建脚本 v2.0
# ==========================================
# 功能：自动检测代理、支持并行构建、多架构构建
# 作者：euper
# 日期：2026-05-10
# 使用方法：./build.sh [服务名...] [选项]

set -euo pipefail

# ==========================================
# 自动检测 Docker Desktop 和 buildx
# ==========================================

# 脚本配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# 临时 .dockerignore 切换状态（用于纯 PHP 构建上下文优化）
ACTIVE_DOCKERIGNORE_SOURCE=""

# 构建日志临时文件（构建期间写入，结束或中断时清理）
BUILD_LOG_FILE=""


# 引入公共函数库（必须在 detect_docker_environment 调用之前，因为函数体内使用了 info()）
source "$SCRIPT_DIR/include/shell/common_functions.sh"
source "$SCRIPT_DIR/include/shell/build_compose_utils.sh"
source "$SCRIPT_DIR/include/shell/proxy.sh"
source "$SCRIPT_DIR/include/shell/dockerignore.sh"
# 提供 is_wsl_environment：get_compose_files 依赖它在 WSL 主机叠加 compose/overlays/wsl.yaml，
# 与 up.sh 保持同一判定来源（缺失时 WSL overlay 会被静默跳过）。
source "$SCRIPT_DIR/include/shell/status_display.sh"

# 退出清理：还原临时 .dockerignore 并删除构建日志（构建被中断时也能执行）
cleanup_on_exit() {
    restore_temp_dockerignore
    if [[ -n "${BUILD_LOG_FILE:-}" && -f "${BUILD_LOG_FILE}" ]]; then
        rm -f "${BUILD_LOG_FILE}"
        BUILD_LOG_FILE=""
    fi
}

trap cleanup_on_exit EXIT

# 帮助信息不依赖 Docker/Podman、代理或 env 加载，必须优先返回。
if [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]; then
    show_build_help
    exit 0
fi

# 执行 Docker 环境检测（source 之后调用，info() 已可用）
detect_docker_environment

# 单实例保护：.dockerignore 的临时切换是「全局文件 + trap 还原」机制，
# 并发运行时另一实例退出会将其还原，导致 buildkit 懒计算的 COPY cache key
# 读到被还原的排除规则，报 "COPY ./src/php": not found 等瞬时假错。
# flock 锁随进程退出（含 SIGKILL）自动释放，无需手工清理。
BUILD_INSTANCE_LOCK="$PROJECT_DIR/build/.build.lock"
mkdir -p "$PROJECT_DIR/build"
exec 9>"$BUILD_INSTANCE_LOCK"
if ! flock -n 9; then
    error "检测到另一个 build.sh 实例正在运行（锁: $BUILD_INSTANCE_LOCK）\n并发构建会互相破坏 .dockerignore 临时切换机制，请等待当前构建完成，\n或先确认旧实例已停止（ps aux | grep build.sh）后重试"
fi

# 构建代理默认配置。
# 代理只允许通过 BUILD_PROXY_TYPE 与 BUILD_PROXY_URL 配置；HTTP_PROXY/HTTPS_PROXY 由脚本在构建阶段派生。
DEFAULT_NO_PROXY="localhost,127.0.0.1,::1"
DEFAULT_BUILD_PROXY_TYPE="none"
DEFAULT_BUILD_PROXY_URL=""

# 加载构建阶段需要的环境变量（与 up.sh 保持一致）。
# 目的：让 docker compose 在解析 compose 文件中的变量时，优先读取根目录 .env 覆盖后的配置。
load_build_environment_variables
load_proxy_config


# 独立代理检测函数（--check-proxy 参数触发）
# 加载配置、检测代理连通性、输出结果后退出


# 服务名映射函数

# 前置条件检查（自动检测 Docker/Podman 和 Compose 工具）

# 获取compose文件

# 获取特殊组合的服务列表


# 构建函数
build_services() {
    local environment="$1"
    shift
    local services=("$@")

    # 混合服务拆分：不同独立栈（elk/sgr/rabbitmq/syncer）不能共用同一套 compose 文件。
    # 若一次命令混合多个栈，按栈分步构建，避免出现 "no such service"。
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
        info "检测到多栈服务混合构建，分步执行..."

        if ((${#_regular_services[@]} > 0)); then
            info "步骤 ${_step}/${_group_count}：构建主栈服务 (${_regular_services[*]})"
            build_services "$environment" "${_regular_services[@]}" || _ret=$?
            _step=$((_step + 1))
        fi
        if ((${#_elk_services[@]} > 0)); then
            info "步骤 ${_step}/${_group_count}：构建 ELK 栈服务 (${_elk_services[*]})"
            build_services "$environment" "elk" || _ret=$?
            _step=$((_step + 1))
        fi
        if ((${#_rabbitmq_services[@]} > 0)); then
            info "步骤 ${_step}/${_group_count}：构建 RabbitMQ 栈服务 (${_rabbitmq_services[*]})"
            build_services "$environment" "${_rabbitmq_services[@]}" || _ret=$?
            _step=$((_step + 1))
        fi
        if ((${#_syncer_services[@]} > 0)); then
            info "步骤 ${_step}/${_group_count}：构建 Syncer 栈服务 (${_syncer_services[*]})"
            build_services "$environment" "syncer" || _ret=$?
            _step=$((_step + 1))
        fi
        if ((${#_sgr_services[@]} > 0)); then
            info "步骤 ${_step}/${_group_count}：构建 SGR 栈服务 (${_sgr_services[*]})"
            build_services "$environment" "sgr" || _ret=$?
            _step=$((_step + 1))
        fi
        if ((${#_monitoring_services[@]} > 0)); then
            info "步骤 ${_step}/${_group_count}：构建 Monitoring 栈服务 (${_monitoring_services[*]})"
            build_services "$environment" "monitoring" || _ret=$?
        fi

        return "$_ret"
    fi

    # 下载依赖软件包
    log "检查并下载构建依赖..."
    local dep_script="$SCRIPT_DIR/include/shell/download_dependencies.sh"
    if [[ -f "$dep_script" ]]; then
        # 确保下载脚本有可执行权限
        if [[ ! -x "$dep_script" ]]; then
            chmod +x "$dep_script"
        fi
        # 调用下载脚本
        if ! "$dep_script" "${services[@]}"; then
            warn "依赖下载失败，但继续构建过程"
        else
            success "依赖下载完成"
        fi
    else
        warn "下载脚本不存在: $dep_script"
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
        echo -e "  ./build.sh nginx $environment     # 使用标准Nginx" >&2
        echo -e "  ./build.sh tengine $environment   # 使用Tengine增强版" >&2
        echo "" >&2
        exit 1
    fi

    # 获取compose文件
    local compose_files
    compose_files=$(get_compose_files "$environment" "${services[@]}")

    # 处理特殊组合
    local final_services=()

    # image-only backup 短名：compose 中无 build 段，绝不可作为 bake/compose build 目标。
    # 复用主服务镜像；构建时只导出 *_BACKUP_IMAGE，运行时由 up.sh 再拉起 backup 容器。
    local -A _image_only_backups=(
        [mysql_backup]=1
        [pgvector_backup]=1
        [clickhouse_backup]=1
        [timescaledb_backup]=1
        [mongo_backup]=1
        [postgres_backup]=1
    )

    for service in "${services[@]}"; do
        # 跳过 image-only backup（后续统一：转主服务 / 导出镜像变量）
        [[ -n "${_image_only_backups[$service]:-}" ]] && continue
        local special_services
        special_services=$(get_special_services "$service" build)
        if [[ -n "$special_services" ]]; then
            final_services+=($special_services)
        else
            final_services+=($(map_service_name "$service"))
        fi
    done

    # ===========================================================
    # image-only *_backup 复用主服务镜像处理
    # ----------------------------------------------------------
    # 这些 backup 服务在 compose 中无独立 build 配置，复用主服务（或官方）镜像。
    # - 显式构建 *_backup 且不含主服务 → 转为构建主服务（timescaledb 除外：官方镜像，无需构建）
    # - 构建列表含主服务 → 仅导出对应 *_BACKUP_IMAGE，绝不把 backup 加入构建目标
    #   （否则 bake 后端会报：failed to find target <backup>）
    # ===========================================================
    # 映射：backup_short main_short image_env image_default [skip_build_main]
    local -a _backup_pairs=(
        "mysql_backup mysql MYSQL_BACKUP_IMAGE hg_dnmpr_mysql:latest"
        "pgvector_backup pgvector PGVECTOR_BACKUP_IMAGE hg_dnmpr_pgvector:latest"
        "clickhouse_backup clickhouse CLICKHOUSE_BACKUP_IMAGE hg_dnmpr_clickhouse:latest"
        "timescaledb_backup timescaledb TIMESCALE_BACKUP_IMAGE timescale/timescaledb:pg18 skip_build_main"
    )
    local _pair
    for _pair in "${_backup_pairs[@]}"; do
        local _backup_name _main_name _image_env _image_default _skip_build_main=""
        read -r _backup_name _main_name _image_env _image_default _skip_build_main <<< "$_pair"

        local _has_main=false _has_backup_arg=false
        local _svc
        for _svc in "${services[@]}"; do
            [[ "$_svc" == "$_main_name" ]] && _has_main=true
            [[ "$_svc" == "$_backup_name" ]] && _has_backup_arg=true
        done

        # 兜底：从 final_services 剔除残留的 image-only backup（含 all 展开误带入）
        local _filtered=()
        for _svc in "${final_services[@]}"; do
            [[ "$_svc" != "$_backup_name" ]] && _filtered+=("$_svc")
        done
        final_services=("${_filtered[@]}")

        # 仅传 *_backup、不含主服务：转为构建主服务（官方镜像类跳过）
        if [[ "$_has_backup_arg" == "true" ]] && [[ "$_has_main" == "false" ]]; then
            if [[ "$_skip_build_main" == "skip_build_main" ]]; then
                info "${_backup_name} 使用官方/现成镜像 ${_image_default}，无需构建（请用 up/pull）"
            else
                local _main_already=false
                for _svc in "${final_services[@]}"; do
                    [[ "$_svc" == "$_main_name" ]] && _main_already=true && break
                done
                if [[ "$_main_already" == "false" ]]; then
                    final_services+=("$_main_name")
                fi
                info "${_backup_name} 复用 ${_main_name} 镜像，转换为构建 ${_main_name} 服务"
            fi
        fi

        # 构建列表已含主服务，或显式请求了 backup：导出 backup 镜像变量
        local _main_in_final=false
        for _svc in "${final_services[@]}"; do
            [[ "$_svc" == "$_main_name" ]] && _main_in_final=true && break
        done
        if [[ "$_main_in_final" == "true" ]] || [[ "$_has_backup_arg" == "true" ]]; then
            export "${_image_env}=${_image_default}"
            info "设置 ${_backup_name} 使用镜像: ${_image_default}"
        fi
    done
    unset _pair _backup_name _main_name _image_env _image_default _skip_build_main \
        _has_main _has_backup_arg _svc _filtered _main_in_final _main_already _image_only_backups

    # 获取 Docker Compose 命令（兼容 docker compose 和 docker-compose）
    local compose_cmd
    compose_cmd=$(get_docker_compose_cmd)

    # 构建Docker命令
    local docker_cmd="$compose_cmd $compose_files build"
    local pull_cmd="$compose_cmd $compose_files pull"

    # 添加选项
    if [[ "$NO_CACHE" == "true" ]]; then
        docker_cmd="$docker_cmd --no-cache"
    fi

    # 在生成构建命令前先统一代理环境，Podman 直构模式也能读取到派生出的 HTTP_PROXY/HTTPS_PROXY。
    apply_build_proxy_environment || true
    validate_build_proxy_environment || true

    # ===========================================================
    # Podman 模式：podman-compose 1.x 不支持 build.network 字段，
    # 导致构建容器使用 slirp4netns 而非 host 网络，apt/curl 极慢甚至卡死。
    # 解决方案：直接调用 podman build --network host，完全绕过此缺陷。
    # ===========================================================
    if cr_is_podman; then
            local _podman_build_script
            # 将 compose 文件和目标服务导出给 python3 脚本
            export _PODMAN_COMPOSE_FILES="${compose_files//"-f "/}"
            export _PODMAN_TARGET_SERVICES="${final_services[*]}"
            export _PODMAN_NO_CACHE="${NO_CACHE:-false}"
            _podman_build_script=$(python3 - << 'PYEOF'
import os, yaml, re, shlex

def expand(val):
    """展开 ${VAR}、${VAR:-default}、${VAR-default} 形式的变量引用。
    若变量不存在且无默认值，返回空字符串（与 compose/bash 行为一致）。"""
    if not isinstance(val, str): return val
    def repl(m):
        brace_expr = m.group(1)  # 花括号内容，如 VAR、VAR:-default
        bare_key   = m.group(2)  # 无花括号形式，如 $VAR
        if bare_key:
            return os.environ.get(bare_key, '')
        # 解析 ${VAR:-default} / ${VAR-default}
        if ':-' in brace_expr:
            key, default = brace_expr.split(':-', 1)
            return os.environ.get(key, default)
        if '-' in brace_expr and not brace_expr.startswith('-'):
            key, default = brace_expr.split('-', 1)
            val_env = os.environ.get(key)
            return val_env if val_env is not None else default
        return os.environ.get(brace_expr, '')
    return re.sub(r'\$\{([^}]+)\}|\$([A-Za-z_][A-Za-z0-9_]*)', repl, val)

def rec_merge(base, override):
    if not isinstance(base, dict) or not isinstance(override, dict):
        return override if override is not None else base
    result = dict(base)
    for k, v in override.items():
        if k in result and isinstance(result[k], dict) and isinstance(v, dict):
            result[k] = rec_merge(result[k], v)
        elif v is not None:
            result[k] = v
    return result

def _norm_file(path, base_dir=None):
    if not path: return path
    path = expand(str(path))
    if os.path.isabs(path): return os.path.normpath(path)
    return os.path.normpath(os.path.join(base_dir or os.getcwd(), path))

def resolve_extends(svc, files_by_path):
    ext = (svc or {}).get('extends')
    if not ext or not isinstance(ext, dict): return svc or {}
    ext_file, ext_svc_name = ext.get('file'), ext.get('service')
    origin = (svc or {}).get('__compose_file')
    ext_file = _norm_file(ext_file, os.path.dirname(origin) if origin else os.getcwd())
    if ext_file and ext_file in files_by_path:
        base_svc = ((files_by_path[ext_file].get('services') or {}).get(ext_svc_name) or {})
        base_svc = resolve_extends(base_svc, files_by_path)
        return rec_merge(base_svc, {k: v for k, v in (svc or {}).items() if k != 'extends'})
    return svc or {}

files_raw = os.environ.get('_PODMAN_COMPOSE_FILES', '')
targets = os.environ.get('_PODMAN_TARGET_SERVICES', '').split()
no_cache = os.environ.get('_PODMAN_NO_CACHE', 'false') == 'true'

files = re.findall(r'-f\s+(\S+)', files_raw)
if not files:
    files = [f for f in files_raw.split() if os.path.exists(f)]
files = [_norm_file(f) for f in files]

# 预加载所有 compose 文件（包括 extends 引用的）
files_by_path = {}
to_load = list(files)
while to_load:
    f = _norm_file(to_load.pop(0))
    if f in files_by_path or not os.path.exists(f): continue
    cfg = yaml.safe_load(open(f)) or {}
    for svc in (cfg.get('services') or {}).values():
        if isinstance(svc, dict):
            svc['__compose_file'] = f
            if isinstance(svc.get('build'), dict):
                svc['build']['__compose_file'] = f
    files_by_path[f] = cfg
    for svc in (cfg.get('services') or {}).values():
        ef = ((svc or {}).get('extends') or {}).get('file')
        if ef:
            ef = _norm_file(ef, os.path.dirname(f))
        if ef and ef not in files_by_path: to_load.append(ef)

# 合并服务（解析 extends）
services = {}
for f in files:
    cfg = files_by_path.get(f, {})
    for svc_name, val in (cfg.get('services') or {}).items():
        resolved = resolve_extends(val, files_by_path)
        services[svc_name] = rec_merge(services.get(svc_name, {}), resolved)

for svc_name in (targets if targets else list(services.keys())):
    svc = services.get(svc_name)
    if not svc: continue
    build = svc.get('build')
    if not build: continue
    if not isinstance(build, dict): build = {'context': str(build)}
    build_origin = build.get('__compose_file') or svc.get('__compose_file')
    ctx = expand(build.get('context', '.'))
    ctx = _norm_file(ctx, os.path.dirname(build_origin) if build_origin else os.getcwd())
    dockerfile = expand(build.get('dockerfile', ''))
    image = expand(svc.get('image', f'localhost/{svc_name}:latest'))
    network = build.get('network', 'host')
    shm_size = str(build.get('shm_size', '') or '')
    args_dict = build.get('args', {})
    if isinstance(args_dict, list):
        args_dict = {(a.split('=',1)[0] if '=' in a else a): (a.split('=',1)[1] if '=' in a else '') for a in args_dict}
    cmd_parts = ['podman', 'build', '--network', network]
    if no_cache: cmd_parts.append('--no-cache')
    if dockerfile: cmd_parts += ['-f', os.path.join(ctx, dockerfile)]
    if shm_size: cmd_parts += ['--shm-size', shm_size]
    cmd_parts += ['-t', image]
    for k, v in (args_dict or {}).items():
        if v is None:
            # YAML 中值为 null：透传给 podman，由宿主机环境决定
            cmd_parts += ['--build-arg', k]
        else:
            ev = expand(str(v))
            if ev:
                cmd_parts += ['--build-arg', f'{k}={ev}']
            else:
                # 展开后为空（变量在 .env 中未定义）：透传，让 podman 从宿主机继承
                cmd_parts += ['--build-arg', k]
    cmd_parts.append(ctx)
    print(shlex.join(cmd_parts))
PYEOF
        )

        if [[ -z "$_podman_build_script" ]]; then
            error "Podman 构建命令生成失败，无法解析 compose 文件中的 build 配置"
            return 1
        fi

        info "Podman 直接构建模式（--network host），共 ${#final_services[@]} 个服务"
        docker_cmd="bash -c $(printf '%q' "$(echo "$_podman_build_script" | tr '\n' ';')")"
        # 逐条执行 podman build 命令（支持串行，保证日志清晰）
        docker_cmd=""
        local _build_failed=false
        local build_start_time_pod=$(date +%s)
        while IFS= read -r _pcmd; do
            [[ -z "$_pcmd" ]] && continue
            log "执行: $_pcmd"
            if ! eval "$_pcmd"; then
                _build_failed=true
                error "构建失败: $_pcmd"
            fi
        done <<< "$_podman_build_script"
        local build_end_time_pod=$(date +%s)
        if [[ "$_build_failed" == "true" ]]; then
            error "构建失败（耗时: $(( build_end_time_pod - build_start_time_pod )) 秒）"
            restore_temp_dockerignore
            return 1
        fi
        success "构建成功（耗时: $(( build_end_time_pod - build_start_time_pod )) 秒）"
        restore_temp_dockerignore
        return 0
    fi

    if [[ "$PARALLEL_BUILD" == "true" ]] && [[ ${#final_services[@]} -gt 1 ]]; then
        # docker compose build --parallel
        docker_cmd="$docker_cmd --parallel"
    fi

    if [[ "$MULTI_ARCH" == "true" ]]; then
        docker_cmd="$docker_cmd --platform linux/amd64,linux/arm64"
    fi

    # 添加服务名
    if [[ ${#final_services[@]} -gt 0 ]]; then
        docker_cmd="$docker_cmd ${final_services[*]}"
        pull_cmd="$pull_cmd ${final_services[*]}"
    fi

    # force-recreate 的正确语义应是：先 build，再按需使用新镜像重建容器。
    # 不能把 build 直接替换成 up，否则会出现“看起来在构建，实际在启动容器”的错误行为。
    local recreate_cmd=""
    if [[ "$FORCE_RECREATE" == "true" ]]; then
        if [[ ${#final_services[@]} -gt 0 ]]; then
            # 分两步重建：先用 compose rm -sf 仅移除目标容器（不碰共享网络），
            # 再用 compose up --no-build 重新创建并连接网络。
            # compose rm -sf 会正确清理 compose 内部容器状态，避免两种互斥错误：
            #   - 无 --no-deps：compose up --force-recreate 试图删网络 → network has active endpoints
            #   - 有 --no-deps：compose 不管理网络 → container is not connected to network
            local _svc_list="${final_services[*]}"
            recreate_cmd="${compose_cmd} ${compose_files} rm -sf ${_svc_list}"
            # --no-deps：容器已被 rm -sf 删除，up 时只需创建新容器并连接已有网络，
            # 不触碰 depends_on 的 php 容器，避免 compose 停止依赖容器后触发网络错误。
            recreate_cmd+="; ${compose_cmd} ${compose_files} up -d --no-build --no-deps ${_svc_list}"
        else
            # 无指定服务（全量重建）：走原有 --force-recreate 路径
            recreate_cmd="$compose_cmd $compose_files up -d --no-build --force-recreate"
        fi
    fi

    # 纯镜像服务（无 build 上下文）不应走 build，
    # 否则会出现 "No services to build" 的误导性告警。
    local image_only_stack=false
    if [[ " ${services[*]} " =~ " monitoring " ]] || [[ " ${services[*]} " =~ " prometheus " ]] || [[ " ${services[*]} " =~ " grafana " ]] || [[ " ${services[*]} " =~ " syncer-prometheus " ]] || [[ " ${services[*]} " =~ " syncer-grafana " ]] || [[ " ${services[*]} " =~ " sgr " ]] || [[ " ${services[*]} " =~ " spug " ]] || [[ " ${services[*]} " =~ " gitea " ]] || [[ " ${services[*]} " =~ " rap2-dolores " ]] || [[ " ${services[*]} " =~ " rap2-delos " ]] || [[ " ${services[*]} " =~ " timescaledb " ]]; then
        image_only_stack=true
    fi

    if [[ "$image_only_stack" == "true" ]]; then
        log "检测到纯镜像服务，跳过 build，改为拉取镜像"
        info "执行拉取命令: $pull_cmd"
        if timeout "${BUILD_TIMEOUT:-7200}" bash -c "$pull_cmd"; then
            success "镜像拉取成功"
            if [[ -n "$recreate_cmd" ]]; then
                log "开始按新镜像重建容器..."
                info "执行重建命令: $recreate_cmd"
                bash -c "$recreate_cmd"
                success "容器重建完成"
            fi
            log "构建完成！"
            return 0
        else
            local pull_exit_code=$?
            error "镜像拉取失败（退出码: $pull_exit_code）"
            return "$pull_exit_code"
        fi
    fi

    # 执行构建
    log "执行构建命令: $docker_cmd"
    info "构建环境: $environment"
    info "构建服务: ${final_services[*]:-所有服务}"

    # 根据服务自动选择 ignore 规则；支持显式 --ignorefile FILE 覆盖。
    switch_to_dockerignore_if_needed "${final_services[@]}"

    # Docker构建环境变量已在脚本开头通过 detect_docker_environment() 检测并设置
    # 不再强制覆盖，保持自动检测的结果

    # 检测网络连接，如果无法访问 Docker Hub，自动启用国内镜像源。
    # 国内镜像源检测必须走直连（--noproxy），因为代理通常只能访问外网，
    # 经代理访问国内镜像站反而会失败。
    if [[ "${CHANGE_SOURCE:-false}" != "true" ]]; then
        info "检测网络连接..."
        export FALLBACK_MIRROR=""
        if ! timeout 5 curl -s -o /dev/null https://registry-1.docker.io 2>/dev/null; then
            warn "无法访问 Docker Hub，尝试启用国内镜像源加速"
            if timeout 5 curl --noproxy '*' -s -o /dev/null https://mirrors.ustc.edu.cn 2>/dev/null; then
                export CHANGE_SOURCE=true
                info "已启用国内镜像源加速（CHANGE_SOURCE=true）"
            else
                warn "国内镜像源也无法访问，使用默认镜像源（可能需要配置代理）"
                export CHANGE_SOURCE=false
            fi
        else
            info "网络连接正常，使用默认镜像源"
        fi
    else
        info "已配置使用国内镜像源加速（CHANGE_SOURCE=true）"
        # 已显式启用，仅做可达性确认；带重试避免瞬时网络抖动导致假回退
        _ustc_ok=false
        for _ustc_attempt in 1 2 3; do
            if timeout 10 curl --noproxy '*' -s -o /dev/null https://mirrors.ustc.edu.cn 2>/dev/null; then
                _ustc_ok=true
                break
            fi
            info "中科大镜像源检测第 ${_ustc_attempt} 次失败，1s 后重试..."
            sleep 1
        done
        if ! $_ustc_ok; then
            # USTC 不可达，尝试阿里云镜像源作为备用
            warn "中科大镜像源无法访问（3次重试均失败），尝试阿里云镜像源..."
            _aliyun_ok=false
            for _aliyun_attempt in 1 2; do
                if timeout 10 curl --noproxy '*' -s -o /dev/null https://mirrors.aliyun.com 2>/dev/null; then
                    _aliyun_ok=true
                    break
                fi
                info "阿里云镜像源检测第 ${_aliyun_attempt} 次失败，1s 后重试..."
                sleep 1
            done
            if $_aliyun_ok; then
                info "阿里云镜像源连通性确认 OK，使用阿里云备用镜像源"
                export FALLBACK_MIRROR=mirrors.aliyun.com
            else
                warn "阿里云镜像源也无法访问，回退到官方镜像源"
                export CHANGE_SOURCE=false
                export FALLBACK_MIRROR=""
                # 使用官方源时需要可用的 HTTP 代理（apt 不支持 SOCKS5）
                _proxy_type="${BUILD_PROXY_TYPE:-none}"
                if [[ "$_proxy_type" == socks5* ]]; then
                    warn "当前代理类型为 SOCKS5，apt 不支持 SOCKS5 代理，构建可能失败"
                    warn "建议配置 HTTP 代理或确保 deb.debian.org 可直连"
                fi
            fi
        else
            info "中科大镜像源连通性确认 OK"
            export FALLBACK_MIRROR=""
        fi
        unset _ustc_ok _ustc_attempt _aliyun_ok _aliyun_attempt _proxy_type
    fi

    # 执行命令
    # 使用 bash -c 而非 eval：eval 在脚本文件内联执行长时间子进程时，
    # bash 的预读缓冲可能导致文件偏移量偏移，使 LINENO 计数错位，
    # 产生"xxx: 未找到命令"等假报错。bash -c 在独立子进程执行，
    # 父进程脚本文件读取不受阻塞影响。

    # 添加构建超时控制：默认 2 小时（7200 秒），可通过 --build-timeout 选项调整
    # 防止因网络缓慢或镜像拉取问题导致无限等待
    local build_timeout="${BUILD_TIMEOUT:-7200}"
    local build_start_time=$(date +%s)

    log "开始构建，超时时间设置为: ${build_timeout} 秒 ($(( build_timeout / 60 )) 分钟)"

    # 使用 timeout 命令包装 docker compose build，防止无限卡死
    # 捕获超时信号（124 表示超时，其他值表示其他错误）
    # resolve_compose_build_command：自动处理 bake 后端下 network:host 的 network.host entitlement 报错
    local build_cmd
    build_cmd=$(resolve_compose_build_command "$docker_cmd" "$compose_cmd" "$compose_files" "$MULTI_ARCH" "${final_services[@]}")
    # 构建日志落盘，便于失败时精准诊断（如 network.host entitlement 未授权）
    local build_log
    build_log=$(mktemp -t hg_dnmpr_build.XXXXXX 2>/dev/null) || build_log="/tmp/hg_dnmpr_build.$$.log"
    BUILD_LOG_FILE="$build_log"
    if timeout "$build_timeout" bash -c "$build_cmd" 2>&1 | tee "$build_log"; then
        local build_end_time=$(date +%s)
        local build_duration=$(( build_end_time - build_start_time ))
        success "构建成功，耗时: ${build_duration} 秒"

        if [[ -n "$recreate_cmd" ]]; then
            log "开始按新镜像重建容器..."
            info "执行重建命令: $recreate_cmd"
            bash -c "$recreate_cmd"
            success "容器重建完成"
        fi

        restore_temp_dockerignore
        rm -f "$build_log"
    else
        local exit_code=$?
        local build_end_time=$(date +%s)
        local build_duration=$(( build_end_time - build_start_time ))

        if [[ $exit_code -eq 124 ]]; then
            # 先完成清理与详情输出，最后一行 error 负责输出摘要并退出
            # （error() 会直接 exit 1，故不能在其后继续调用）
            restore_temp_dockerignore
            rm -f "$build_log"
            warn "可能原因："
            warn "  1. Docker 镜像拉取速度慢（特别是大型镜像如 canal、elasticsearch）"
            warn "  2. 网络连接不稳定"
            warn "  3. Docker Hub 访问缓慢"
            warn "解决方案："
            warn "  • 增加超时时间：./build.sh ${SERVICES[*]} --build-timeout 14400（4小时）"
            warn "  • 配置国内镜像源：export CHANGE_SOURCE=true && ./build.sh ..."
            warn "  • 配置构建代理：在根目录 .env 设置 BUILD_PROXY_TYPE 与 BUILD_PROXY_URL 后执行 ./build.sh ..."
            warn "  • 检查网络连接：ping 8.8.8.8 或 curl -I https://hub.docker.com/"
            warn "  • 在已有镜像基础上继续构建（使用缓存）：./build.sh ${SERVICES[*]} --parallel"
            error "构建超时（${build_duration} 秒 > ${build_timeout} 秒），已中止"
            return 1
        elif [[ $exit_code -eq 125 ]] && [[ ${#final_services[@]} -gt 0 ]]; then
            # podman-compose 并行构建时，即使部分服务成功也可能返回 125。
            # 检查所有目标服务的镜像是否实际存在来判断构建结果。
            local _cr_cmd
            _cr_cmd="${CR:-docker}"
            local _all_built=true
            local _missing_services=()
            local _image_name
            for _svc in "${final_services[@]}"; do
                _image_name="$(${_cr_cmd} images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i "${_svc}" | head -1)"
                if [[ -z "$_image_name" ]]; then
                    _all_built=false
                    _missing_services+=("$_svc")
                fi
            done
            if [[ "$_all_built" == "true" ]]; then
                warn "检测到 podman-compose 返回退出码 125，但所有服务镜像均已构建成功，视为构建成功"
                local build_end_time_125=$(date +%s)
                success "构建成功，耗时: $(( build_end_time_125 - build_start_time )) 秒"
                restore_temp_dockerignore
                rm -f "$build_log"
                return 0
            else
                # 先清理再输出错误（error() 会直接 exit 1）
                restore_temp_dockerignore
                rm -f "$build_log"
                error "构建失败（退出码: $exit_code），以下服务镜像未生成：${_missing_services[*]}"
                return $exit_code
            fi
        else
            # 精准诊断：bake 后端下 network: host 需显式授权 network.host entitlement
            # 注意：error() 会直接 exit 1，故先完成诊断与日志清理，再输出详情，最后一行 error 收尾。
            local _entitlement_issue=false
            if [[ -f "$build_log" ]] && grep -qE "additional privileges requested|--allow=network\.host" "$build_log" 2>/dev/null; then
                _entitlement_issue=true
            fi
            rm -f "$build_log"
            if [[ "$_entitlement_issue" == "true" ]]; then
                warn "检测到 BuildKit network.host 权限（entitlement）未授权"
                warn "原因：compose 构建段配置了 network: host，新版 Compose 默认走 bake 后端，需显式授权"
                warn "自动处理未生效的可能原因："
                warn "  1. 处于多架构构建（--multi-arch），该模式未自动改用 bake 路径"
                warn "  2. buildx 不可用或能力探测失败"
                warn "手动解决方案："
                warn "  • 生成 bake 定义并显式授权：docker compose build --print <服务> | docker buildx bake --allow=network.host -f - <服务>"
                warn "  • 或移除 compose 构建段的 network: host 配置（compose/stacks/php.yaml）"
            else
                warn "请检查上面的构建日志找出具体错误"
            fi
            error "构建失败（退出码: $exit_code），耗时: ${build_duration} 秒"
            return $exit_code
        fi
    fi

    # 推送镜像（如果需要）
    if [[ "$PUSH_IMAGE" == "true" ]]; then
        log "推送镜像到仓库..."
        local compose_cmd
        compose_cmd=$(get_docker_compose_cmd)
        for service in "${final_services[@]}"; do
            $compose_cmd $compose_files push "$service" || warn "推送 $service 失败"
        done
    fi

    log "构建完成！"
}

# ============================================================
# PHP CLI 包装脚本生成
# ============================================================
# phpXX 镜像构建成功后，将 build/php/common/php（模板）中的版本占位符
# 替换为实际版本号，安装为宿主机 /usr/local/bin/phpXX，供编辑器/
# 终端直接调用容器内的 PHP。
install_php_cli_wrappers() {
    local services=("$@")
    local template="$SCRIPT_DIR/build/php/common/php"

    if [[ ! -f "$template" ]]; then
        warn "PHP 包装脚本模板不存在: $template，跳过生成"
        return 0
    fi

    # 展开 all 等特殊分组，得到实际构建的服务列表
    local expanded=()
    local svc special
    for svc in "${services[@]}"; do
        special=$(get_special_services "$svc" build)
        if [[ -n "$special" ]]; then
            expanded+=($special)
        else
            expanded+=("$svc")
        fi
    done

    local ver dotted target tmp
    for svc in "${expanded[@]}"; do
        # 仅处理 phpXX 形式的服务（如 php84 → 容器 php84_apache）
        [[ "$svc" =~ ^php([0-9]{2})$ ]] || continue
        ver="${BASH_REMATCH[1]}"
        dotted="${ver:0:1}.${ver:1}"
        target="/usr/local/bin/php${ver}"

        tmp="$(mktemp)"
        sed -e "s/{{PHP_VERSION}}/${ver}/g" \
            -e "s/{{PHP_DOTTED_VERSION}}/${dotted}/g" \
            "$template" > "$tmp"

        if [[ -w /usr/local/bin ]]; then
            if install -m 755 "$tmp" "$target"; then
                success "PHP CLI 包装脚本已安装: $target（容器 php${ver}_apache）"
            else
                warn "安装 $target 失败"
            fi
        elif command -v sudo >/dev/null 2>&1; then
            if sudo install -m 755 "$tmp" "$target"; then
                success "PHP CLI 包装脚本已安装: $target（容器 php${ver}_apache）"
            else
                warn "安装 $target 失败（权限不足），可在构建后手工执行: sudo install -m 755 <渲染后脚本> $target"
            fi
        else
            warn "无 sudo 可用，无法安装 $target"
        fi
        rm -f "$tmp"
    done

    return 0
}

# 参数解析
SERVICES=()
ENVIRONMENT="development"
NO_CACHE="false"
PARALLEL_BUILD="true"  # 默认启用并行构建
MULTI_ARCH="false"
PUSH_IMAGE="false"
FORCE_RECREATE="false"
AUTO_PRUNE="false"  # 新增：构建后自动清理
AUTO_UP="false"  # 新增：构建后自动启动服务
BUILD_TIMEOUT="7200"  # 新增：构建超时时间（秒），默认2小时
IGNOREFILE_PATH=""    # 新增：可显式指定 ignore 规则文件（相对项目根目录或绝对路径）

# 检查是否没有参数，如果没有参数则显示帮助信息
if [[ $# -eq 0 ]]; then
    show_build_help
    exit 0
fi

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        # 服务名
        php85|php84|php83|php82|php81|php80|php74|nginx|tengine|mysql|mysql_backup|redis|valkey|mongo|mongodb|postgres|postgresql|pgadmin|timescaledb|timescaledb_backup|pgvector|pgvector_backup|clickhouse|clickhouse_backup|elk|elasticsearch|kibana|logstash|sgr|spug|gitea|rap2-dolores|rap2-delos|rabbitmq|syncer|canal|canal-server|monitoring|prometheus|grafana|syncer-prometheus|syncer-grafana|all)
            SERVICES+=("$1")
            shift
            ;;
        # 环境参数已统一由 env/base.env 控制；保留旧参数兼容但不再覆盖。
        dev|development|prod|production)
            warn "环境参数 '$1' 已废弃并被忽略；当前环境统一读取 env/base.env 的 ENVIRONMENT"
            shift
            ;;
        # 选项
        --no-cache)
            NO_CACHE="true"
            shift
            ;;
        --parallel)
            PARALLEL_BUILD="true"
            shift
            ;;
        --no-parallel)
            PARALLEL_BUILD="false"
            shift
            ;;
        --multi-arch)
            MULTI_ARCH="true"
            shift
            ;;
        --push)
            PUSH_IMAGE="true"
            shift
            ;;
        --force-recreate)
            FORCE_RECREATE="true"
            shift
            ;;
        --auto-prune)
            AUTO_PRUNE="true"
            shift
            ;;
        --auto-up)
            AUTO_UP="true"
            shift
            ;;
        --build-timeout)
            if [[ $# -lt 2 ]]; then
                error "--build-timeout 需要指定超时秒数\n使用: ./build.sh ... --build-timeout 14400"
            fi
            BUILD_TIMEOUT="$2"
            # 验证是否为正整数
            if ! [[ "$BUILD_TIMEOUT" =~ ^[0-9]+$ ]]; then
                error "--build-timeout 必须是正整数（秒数），例如: 7200（2小时）、14400（4小时）"
            fi
            shift 2
            ;;
        --ignorefile)
            if [[ $# -lt 2 ]]; then
                error "--ignorefile 需要指定文件路径\n使用: ./build.sh ... --ignorefile .dockerignore.php"
            fi
            IGNOREFILE_PATH="$2"
            shift 2
            ;;
        --check-proxy)
            load_proxy_config
            check_proxy
            exit 0
            ;;
        --help|-h|help)
            show_build_help
            exit 0
            ;;
        *)
            error "未知参数: $1\n使用 --help 查看帮助信息"
            ;;
    esac
done

# 验证参数
if [[ ${#SERVICES[@]} -eq 0 ]]; then
    error "请指定至少一个服务名\n使用 --help 查看帮助信息"
fi

# 切换到项目目录
cd "$PROJECT_DIR"

# 加载分层配置文件；上游版本只解析目标服务涉及的组件
load_config_files "${SERVICES[@]}"

# 统一项目环境：构建、ELK环境配置、monitoring端口绑定均读取 env/base.env。
export_monitoring_publish_host_from_base_env "$PROJECT_DIR"

# 加载ELK环境特定配置（如果构建ELK服务）
if [[ " ${SERVICES[@]} " =~ " elk " ]] || [[ " ${SERVICES[@]} " =~ " elasticsearch " ]] || [[ " ${SERVICES[@]} " =~ " kibana " ]] || [[ " ${SERVICES[@]} " =~ " logstash " ]]; then
    env_name="${PROJECT_ENVIRONMENT_SHORT:-dev}"

    # 检查 ELK 环境配置文件；该配置随 ELK 版本走，位于 build/elk/<version>/ 下。
    elk_major_minor="${ELK_BUILD_VERSION:-9.5}"
    if [[ "$elk_major_minor" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        elk_major_minor="${elk_major_minor%.*}"
    fi
    elk_env_file="${BUILD_ROOT:-$PROJECT_DIR/build}/elk/${elk_major_minor}/elk.${env_name}.env"
    if [[ -f "$elk_env_file" ]]; then
        info "🔧 加载ELK【${env_name}】环境配置: $elk_env_file"
        # 使用 while read + export 替代 source <(...)：
        # source 会逐行"执行"内容使 LINENO 偏移，导致假报错。
        # 此处手动拆 key/value 并剥除外层引号后再 export，
        # 等价于 bash 对 KEY="VALUE" 求值的结果，但不改变 LINENO。
        while IFS= read -r _elk_line; do
            _elk_key="${_elk_line%%=*}"
            _elk_val="${_elk_line#*=}"
            # 剥除外层双引号或单引号（与 bash source 求值行为一致）
            if [[ "${_elk_val}" == '"'*'"' ]]; then
                _elk_val="${_elk_val:1:${#_elk_val}-2}"
            elif [[ "${_elk_val}" == "'"*"'" ]]; then
                _elk_val="${_elk_val:1:${#_elk_val}-2}"
            fi
            export "${_elk_key}=${_elk_val}"
        done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$elk_env_file" 2>/dev/null || true)
        unset _elk_key _elk_val _elk_line
    else
        warn "未找到ELK环境配置文件: $elk_env_file，使用默认配置"
    fi
fi

# 开始构建
log "开始 Docker 项目构建"

# 检查前置条件（Docker / Docker Compose 必须在依赖下载之前验证）
check_prerequisites

# 设置配置目录权限
setup_conf_permissions

# 配置Docker容器别名（传递脚本名称用于日志标识）
setup_docker_aliases "build"
# 恢复 shell 严格模式（防止 setup_docker_aliases 内部的 source 操作改变了选项）
set -euo pipefail

# 清理日志文件
cleanup_logs

# 检查是否包含 all 参数，如果是则展示服务列表并倒计时
for service in "${SERVICES[@]}"; do
    if [[ "$service" == "all" ]]; then
        # 获取 all 对应的服务列表
        all_services=$(get_special_services "all" build)

        echo -e "\n${CYAN}${BOLD}=== 即将构建以下服务 ===${NC}"
        echo -e "${YELLOW}项目环境(base.env): ${ENVIRONMENT}${NC}"
        echo -e "${YELLOW}构建服务列表:${NC}"

        # 逐行显示服务
        for svc in $all_services; do
            case "$svc" in
                nginx)
                    echo -e "  • ${GREEN}nginx${NC}          - 标准的Nginx Web服务器"
                    ;;
                php85)
                    echo -e "  • ${GREEN}php85_apache${NC}   - PHP 8.5 + Apache 服务器"
                    ;;
                php84)
                    echo -e "  • ${GREEN}php84_apache${NC}   - PHP 8.4 + Apache 服务器"
                    ;;
                php82)
                    echo -e "  • ${GREEN}php82_apache${NC}   - PHP 8.2 + Apache 服务器"
                    ;;
                php74)
                    echo -e "  • ${GREEN}php74_apache${NC}   - PHP 7.4 + Apache 服务器"
                    ;;
                mysql)
                    echo -e "  • ${GREEN}mysql${NC}         - MySQL 8.0 数据库服务器"
                    ;;
                redis)
                    echo -e "  • ${GREEN}redis${NC}          - Redis 缓存服务器"
                    ;;
                valkey)
                    echo -e "  • ${GREEN}valkey${NC}         - Valkey 缓存服务器"
                    ;;
                *)
                    echo -e "  • ${GREEN}$svc${NC}"
                    ;;
            esac
        done

        echo -e "\n${YELLOW}${BOLD}⚠️  注意: 构建过程可能需要较长时间，请确保网络连接稳定${NC}"
        echo -e "${RED}${BOLD}如需取消构建，请按 Ctrl+C${NC}\n"

        # 倒计时15秒
        for i in {15..1}; do
            echo -ne "${YELLOW}${BOLD}构建将在 $i 秒后开始...\r${NC}"
            sleep 1
        done
        echo -e "${GREEN}${BOLD}开始构建！${NC}\n"

        break  # 找到 all 参数后退出循环
    fi
done

build_services "$ENVIRONMENT" "${SERVICES[@]}"

# PHP 镜像构建成功后，自动生成宿主机 /usr/local/bin/phpXX 包装脚本
install_php_cli_wrappers "${SERVICES[@]}"

# 构建后自动清理
if [[ "$AUTO_PRUNE" == "true" ]]; then
    log "开始构建后自动清理..."

    # 显示清理前的磁盘使用情况
    info "清理前的容器存储使用情况:"
    cr_cmd system df

    # 执行清理
    log "执行容器系统清理..."
    if cr_cmd system prune -f; then
        success "容器系统清理完成"
    else
        warn "容器系统清理失败，但不影响构建结果"
    fi

    # 显示清理后的磁盘使用情况
    info "清理后的容器存储使用情况:"
    cr_cmd system df
fi

# 构建后自动启动服务
if [[ "$AUTO_UP" == "true" ]]; then
    log "开始构建后自动启动服务..."

    # 调用up.sh脚本来启动服务
    if [[ -f "$PROJECT_DIR/up.sh" ]]; then
        up_cmd="$PROJECT_DIR/up.sh"

        # 添加服务名称
        for service in "${SERVICES[@]}"; do
            up_cmd+=" $service"
        done

        log "执行启动命令: $up_cmd"

        if ! $up_cmd; then
            warn "服务启动失败，但不影响构建结果"
        else
            success "服务启动完成"
        fi
    else
        warn "up.sh脚本不存在，跳过自动启动"
    fi
fi

log "所有构建任务完成！"
