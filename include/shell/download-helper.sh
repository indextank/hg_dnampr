#!/bin/sh
# ==========================================
# 并行下载辅助脚本（POSIX sh 兼容版）
# ==========================================
# 功能：提供统一的并行下载函数，减少 Dockerfile 代码重复
# 使用方法：在 Dockerfile 中 source 此脚本，然后调用对应函数
#
# 兼容性：POSIX sh / busybox ash / bash
#   - 已移除 bash 专有语法：数组 ()、here-string <<<
#   - 使用 cut -d: -f1 / cut -d: -f2- 替代 IFS=: read <<< 解析 "filename:url"
#   - 使用空格分隔字符串追踪后台 PID，替代 bash 数组
#
# 参数格式（parallel_download）：
#   "filename1:url1" "filename2:url2" ...
#   URL 中包含 : (如 https://) 不影响解析，因为 cut -f2- 取第 2 字段到末尾

# ==========================================
# _download_file_complete — 判断下载产物是否完整
# ==========================================
# 背景：部分 CDN（GitHub release-assets / Azure Blob）在 HTTP/2 下传输完成后
# 未干净关闭流，curl 返回 18(CURLE_PARTIAL_FILE)，但文件实际已完整。
# 对压缩包做完整性校验；校验工具缺失时降级为“非空即接受”。
_download_file_complete() {
    local f="$1"
    [ -f "$f" ] && [ -s "$f" ] || return 1
    case "$f" in
        *.tar.gz|*.tgz)
            command -v gzip >/dev/null 2>&1 || return 0
            gzip -t "$f" >/dev/null 2>&1 ;;
        *.tar.xz)
            command -v xz >/dev/null 2>&1 || return 0
            xz -t "$f" >/dev/null 2>&1 ;;
        *.tar.bz2)
            command -v bzip2 >/dev/null 2>&1 || return 0
            bzip2 -t "$f" >/dev/null 2>&1 ;;
        *.zip)
            command -v unzip >/dev/null 2>&1 || return 0
            unzip -tqq "$f" >/dev/null 2>&1 ;;
        *)
            return 0 ;;
    esac
}

# ==========================================
# download_if_missing — 下载单个文件
# ==========================================
# 参数：
#   $1: URL
#   $2: 文件名
# 示例：
#   download_if_missing "https://example.com/file.tar.gz" "file.tar.gz"
download_if_missing() {
    local url="$1"
    local filename="$2"

    if [ ! -f "${filename}" ]; then
        echo "下载 ${filename}..."
        if command -v curl >/dev/null 2>&1; then
            # --http1.1：规避 CDN 在 HTTP/2 下未干净关闭流导致的 curl exit 18
            if ! curl -fsSL --http1.1 --retry 3 --retry-delay 5 -o "${filename}" "${url}"; then
                # curl 报错但文件可能已完整（exit 18），校验后接受
                if _download_file_complete "${filename}"; then
                    echo "curl 返回非 0，但文件完整，视为下载成功: ${filename}"
                else
                    echo "下载 ${filename} 失败"
                    rm -f "${filename}" 2>/dev/null || true
                    return 1
                fi
            fi
        elif command -v wget >/dev/null 2>&1; then
            wget --tries=3 --timeout=30 -O "${filename}" "${url}" || {
                echo "下载 ${filename} 失败"
                return 1
            }
        else
            echo "错误：未找到 curl 或 wget 命令"
            return 1
        fi
        # 下载器返回成功也要校验：部分镜像会对不存在的路径返回 200 + 错误页
        if ! _download_file_complete "${filename}"; then
            echo "下载 ${filename} 失败（文件校验未通过）"
            rm -f "${filename}" 2>/dev/null || true
            return 1
        fi
        echo "${filename} 下载完成"
    else
        echo "${filename} 已存在，跳过下载"
    fi
    return 0
}

# download_if_missing_fallback — 支持多镜像回退下载（URL 以 | 分隔）
download_if_missing_fallback() {
    local urls="$1"
    local filename="$2"

    if [ -f "${filename}" ] && [ -s "${filename}" ]; then
        echo "${filename} 已存在，跳过下载"
        return 0
    fi
    if [ -f "${filename}" ] && [ ! -s "${filename}" ]; then
        rm -f "${filename}"
    fi

    local old_ifs="$IFS"
    IFS='|'
    set -- $urls
    IFS="$old_ifs"

    local url
    for url in "$@"; do
        [ -z "$url" ] && continue
        echo "尝试下载 ${filename}: ${url}"
        if command -v curl >/dev/null 2>&1; then
            # --http1.1：规避 CDN 在 HTTP/2 下未干净关闭流导致的 curl exit 18
            if curl -fsSL --http1.1 --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 5 -o "${filename}" "${url}"; then
                # curl 成功也要校验：部分镜像会对不存在的路径返回 200 + 错误页
                if _download_file_complete "${filename}"; then
                    echo "${filename} 下载完成"
                    return 0
                fi
                echo "文件校验失败（来源可能返回了错误页），换下一个镜像"
                rm -f "${filename}" 2>/dev/null || true
                continue
            fi
            # curl 报错但文件可能已完整（exit 18），校验后接受
            if _download_file_complete "${filename}"; then
                echo "curl 返回非 0，但文件完整，视为下载成功: ${filename}"
                return 0
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget --tries=3 --timeout=30 -O "${filename}" "${url}"; then
                echo "${filename} 下载完成"
                return 0
            fi
        else
            echo "错误：未找到 curl 或 wget 命令"
            return 1
        fi
        echo "当前镜像下载失败，尝试下一个..."
        rm -f "${filename}" 2>/dev/null || true
    done

    echo "下载 ${filename} 失败（所有镜像均不可用）"
    return 1
}

# ==========================================
# parallel_download — 并行下载多个文件
# ==========================================
# 参数：
#   $@: 文件列表，每项格式为 "filename:url"
#       filename 不含 :；url 可含多个 :（如 https://...）
# 示例：
#   parallel_download \
#     "nginx-1.24.0.tar.gz:https://nginx.org/download/nginx-1.24.0.tar.gz" \
#     "pcre-8.44.tar.gz:https://ftp.exim.org/pub/pcre/pcre-8.44.tar.gz"
parallel_download() {
    # ---- 第一遍：统计缺失文件数量 ----
    local missing=0
    for item in "$@"; do
        local fname
        fname=$(echo "$item" | cut -d: -f1)
        if [ ! -f "$fname" ]; then
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -eq 0 ]; then
        echo "所有文件已存在，无需下载"
        return 0
    fi

    echo "开始下载 ${missing} 个缺失的文件..."

    # ---- 第二遍：并行启动下载，用空格分隔字符串记录 PID ----
    local pids=""
    for item in "$@"; do
        local fname url
        fname=$(echo "$item" | cut -d: -f1)
        # cut -f2- 保留第 2 字段到末尾，含 URL 内的所有 : (https://)
        url=$(echo "$item" | cut -d: -f2-)
        if [ ! -f "$fname" ]; then
            download_if_missing_fallback "$url" "$fname" &
            pids="${pids} $!"
        fi
    done

    # ---- 等待全部后台任务，汇总失败状态 ----
    local failed=0
    for pid in $pids; do
        if ! wait "$pid"; then
            failed=1
        fi
    done

    if [ "$failed" -eq 1 ]; then
        echo "部分文件下载失败"
        return 1
    fi

    echo "所有文件下载完成"
    return 0
}
