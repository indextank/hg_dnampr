#!/bin/bash
# 扫描本机 hg_dnmpr_* / 主栈相关镜像的 CVE（只读，不修改镜像）。
# 优先 Trivy，其次 Grype；两者皆无则提示安装并退出 2。
#
# 用法:
#   bash scripts/scan-images.sh              # 扫描本地 hg_dnmpr_* 与 compose 中常见第三方镜像
#   bash scripts/scan-images.sh nginx valkey # 仅扫描指定仓库名片段
#   SCAN_SEVERITY=HIGH,CRITICAL bash scripts/scan-images.sh
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}" || exit 1

SEVERITY="${SCAN_SEVERITY:-HIGH,CRITICAL}"

_have() { command -v "$1" >/dev/null 2>&1; }

_list_images() {
    local filter=()
    if [[ "$#" -gt 0 ]]; then
        filter=("$@")
    fi
    local line repo
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        repo="${line%%:*}"
        if [[ "${#filter[@]}" -eq 0 ]]; then
            printf '%s\n' "${line}"
            continue
        fi
        local f
        for f in "${filter[@]}"; do
            if [[ "${line}" == *"${f}"* ]]; then
                printf '%s\n' "${line}"
                break
            fi
        done
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^(hg_dnmpr_|syncer:|prom/|grafana/|oliver006/|nginx/nginx-prometheus|dpage/|timescale/|gcr.io/cadvisor|openspug/|gitea/|wangqiru/|containrrr/|diygod/|browserless/|rapteam/|alpine:)' | grep -v '<none>' | sort -u)
}

_scan_trivy() {
    local img="$1"
    trivy image --severity "${SEVERITY}" --exit-code 0 --no-progress "${img}"
}

_scan_grype() {
    local img="$1"
    grype "${img}" --fail-on "${SEVERITY%%,*}" 2>/dev/null || grype "${img}"
}

main() {
    if ! _have docker; then
        echo "ERROR: docker 不可用" >&2
        exit 1
    fi

    local scanner=""
    if _have trivy; then
        scanner=trivy
    elif _have grype; then
        scanner=grype
    else
        echo "ERROR: 未安装 trivy 或 grype。" >&2
        echo "  安装 Trivy: https://aquasecurity.github.io/trivy/latest/getting-started/installation/" >&2
        echo "  安装 Grype: https://github.com/anchore/grype#installation" >&2
        exit 2
    fi

    echo "scanner=${scanner} severity=${SEVERITY}"
    local imgs=()
    mapfile -t imgs < <(_list_images "$@")
    if [[ "${#imgs[@]}" -eq 0 ]]; then
        echo "无匹配本地镜像"
        exit 0
    fi

    local img rc=0
    for img in "${imgs[@]}"; do
        echo "======== ${img} ========"
        if [[ "${scanner}" == "trivy" ]]; then
            _scan_trivy "${img}" || rc=1
        else
            _scan_grype "${img}" || rc=1
        fi
    done

    echo "======== digests (local) ========"
    docker images --digests --format '{{.Repository}}:{{.Tag}}  {{.Digest}}  {{.ID}}' \
        | grep -E '^hg_dnmpr_' | head -n 50 || true
    echo "提示: 自建镜像可用「版本 tag + 构建后记录 digest」追溯；compose 中 image: name@sha256:... 可固定第三方。"
    exit "${rc}"
}

main "$@"
