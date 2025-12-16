#!/bin/bash
# ==========================================
# 并行下载辅助脚本
# ==========================================
# 功能：提供统一的并行下载函数，减少 Dockerfile 代码重复
# 使用方法：在 Dockerfile 中 source 此脚本，然后调用 download_if_missing 函数

# 下载函数（单个文件）
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
            curl -fsSL --retry 3 --retry-delay 5 -o "${filename}" "${url}" || {
                echo "下载 ${filename} 失败"
                return 1
            }
        elif command -v wget >/dev/null 2>&1; then
            wget --tries=3 --timeout=30 -O "${filename}" "${url}" || {
                echo "下载 ${filename} 失败"
                return 1
            }
        else
            echo "错误：未找到 curl 或 wget 命令"
            return 1
        fi
        echo "${filename} 下载完成"
    else
        echo "${filename} 已存在，跳过下载"
    fi
    return 0
}

# 并行下载函数（多个文件）
# 参数：
#   $@: 文件列表（格式：filename1:url1 filename2:url2 ...）
# 示例：
#   parallel_download "nginx-1.20.1.tar.gz:https://nginx.org/download/nginx-1.20.1.tar.gz" "pcre-8.44.tar.gz:https://ftp.exim.org/pub/pcre/pcre-8.44.tar.gz"
parallel_download() {
    local download_tasks=()
    
    # 检查哪些文件需要下载
    for item in "$@"; do
        IFS=':' read -r filename url <<< "$item"
        if [ ! -f "$filename" ]; then
            download_tasks+=("$filename:$url")
        fi
    done
    
    # 如果没有需要下载的文件，直接返回
    if [ ${#download_tasks[@]} -eq 0 ]; then
        echo "所有文件已存在，无需下载"
        return 0
    fi
    
    echo "开始下载 ${#download_tasks[@]} 个缺失的文件..."
    
    # 并行下载
    local pids=()
    for item in "${download_tasks[@]}"; do
        IFS=':' read -r filename url <<< "$item"
        download_if_missing "$url" "$filename" &
        pids+=($!)
    done
    
    # 等待所有下载完成
    local failed=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failed=1
        fi
    done
    
    if [ $failed -eq 1 ]; then
        echo "部分文件下载失败"
        return 1
    fi
    
    echo "所有文件下载完成"
    return 0
}

