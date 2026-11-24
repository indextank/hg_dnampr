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

# 仅允许经过 TLS 的上游地址。
_require_https_url() {
    case "$1" in
        https://*) return 0 ;;
        *)
            echo "错误：拒绝非 HTTPS 下载地址: $1"
            return 1
            ;;
    esac
}

# download_and_verify_sha256 — 下载并校验普通归档；无可信摘要时关闭失败。
# 参数：$1 URL，$2 目标文件，$3 预期 SHA256。
download_and_verify_sha256() {
    local url="$1"
    local filename="$2"
    local expected_sha256="$3"
    local actual_sha256=""
    local tmp_file="${filename}.part"

    _require_https_url "${url}" || return 1
    if ! printf '%s' "${expected_sha256}" | grep -Eq '^[0-9a-fA-F]{64}$'; then
        echo "错误：${filename} 缺少有效的显式 SHA256，拒绝下载"
        return 1
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        echo "错误：sha256sum 不可用，无法校验 ${filename}"
        return 1
    fi

    if [ -f "${filename}" ]; then
        actual_sha256=$(sha256sum "${filename}" | cut -d' ' -f1)
        if [ "${actual_sha256}" = "${expected_sha256}" ]; then
            echo "${filename} 已存在且 SHA256 校验通过"
            return 0
        fi
        echo "警告：${filename} 的 SHA256 不匹配，重新下载"
        rm -f "${filename}"
    fi

    rm -f "${tmp_file}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --tlsv1.2 --http1.1 \
            --retry 3 --retry-delay 5 -o "${tmp_file}" "${url}" || {
            rm -f "${tmp_file}"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --tries=3 --timeout=30 -O "${tmp_file}" "${url}" || {
            rm -f "${tmp_file}"
            return 1
        }
    else
        echo "错误：未找到 curl 或 wget 命令"
        return 1
    fi

    actual_sha256=$(sha256sum "${tmp_file}" | cut -d' ' -f1)
    if [ "${actual_sha256}" != "${expected_sha256}" ]; then
        echo "错误：${filename} 的 SHA256 校验失败"
        rm -f "${tmp_file}"
        return 1
    fi
    mv "${tmp_file}" "${filename}"
    echo "${filename} 下载完成且 SHA256 校验通过"
}

# download_github_release_asset_verified — 使用 GitHub 发布资产元数据中的 SHA256。
# 参数：$1 owner/repo，$2 tag，$3 资产名，$4 目标文件。
download_github_release_asset_verified() {
    local repository="$1"
    local tag="$2"
    local asset_name="$3"
    local filename="$4"
    local api_file="${filename}.github.json"
    local metadata=""
    local asset_url=""
    local expected_sha256=""

    if ! command -v php >/dev/null 2>&1; then
        echo "错误：php 不可用，无法解析 GitHub 发布资产元数据"
        return 1
    fi
    rm -f "${api_file}"
    asset_url="https://api.github.com/repos/${repository}/releases/tags/${tag}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 5 \
            -H 'Accept: application/vnd.github+json' -o "${api_file}" "${asset_url}" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --tries=3 --timeout=30 -O "${api_file}" "${asset_url}" || return 1
    else
        echo "错误：未找到 curl 或 wget 命令"
        return 1
    fi

    metadata=$(php -r '
        $data = json_decode(file_get_contents($argv[1]), true);
        if (!is_array($data) || ($data["tag_name"] ?? "") !== $argv[2]) exit(2);
        foreach (($data["assets"] ?? []) as $asset) {
            if (($asset["name"] ?? "") !== $argv[3]) continue;
            $digest = $asset["digest"] ?? "";
            $url = $asset["browser_download_url"] ?? "";
            if (!preg_match("/^sha256:([0-9a-f]{64})$/i", $digest, $m) ||
                strpos($url, "https://github.com/") !== 0) exit(3);
            echo $url, "\n", $m[1], "\n";
            exit(0);
        }
        exit(4);
    ' "${api_file}" "${tag}" "${asset_name}") || {
        echo "错误：GitHub 发布资产缺少可信 SHA256: ${repository} ${tag} ${asset_name}"
        rm -f "${api_file}"
        return 1
    }
    asset_url=$(printf '%s\n' "${metadata}" | sed -n '1p')
    expected_sha256=$(printf '%s\n' "${metadata}" | sed -n '2p')
    rm -f "${api_file}"
    download_and_verify_sha256 "${asset_url}" "${filename}" "${expected_sha256}"
}

# download_pecl_package_verified — 用 PECL REST 元数据和 package.xml 校验归档。
# PECL REST 不发布 SHA256；这里同时验证包名、版本、大小、HTTPS 下载地址和
# 归档内 package.xml 身份。任一信息无法验证时关闭失败。
# 参数：$1 包名，$2 版本，$3 目标文件。
download_pecl_package_verified() {
    local package="$1"
    local version="$2"
    local filename="$3"
    local rest_file="${filename}.rest.xml"
    local tmp_file="${filename}.part"
    local metadata=""
    local download_url=""
    local expected_size=""
    local actual_size=""

    if [ -z "${package}" ] || [ -z "${version}" ]; then
        echo "错误：PECL 包名和版本不能为空"
        return 1
    fi
    if ! command -v php >/dev/null 2>&1; then
        echo "错误：php 不可用，无法验证 PECL REST/package.xml"
        return 1
    fi

    rm -f "${rest_file}" "${tmp_file}"
    download_url="https://pecl.php.net/rest/r/${package}/${version}.xml"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 5 \
            -o "${rest_file}" "${download_url}" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --tries=3 --timeout=30 -O "${rest_file}" "${download_url}" || return 1
    else
        echo "错误：未找到 curl 或 wget 命令"
        return 1
    fi

    metadata=$(php -r '
        $xml = @simplexml_load_file($argv[1]);
        if ($xml === false) exit(2);
        $xml->registerXPathNamespace("p", "http://pear.php.net/dtd/rest.release");
        $get = static function ($xml, $name) {
            $nodes = $xml->xpath("//p:" . $name);
            return isset($nodes[0]) ? trim((string) $nodes[0]) : "";
        };
        $package = $get($xml, "p");
        $version = $get($xml, "v");
        $size = $get($xml, "f");
        $url = $get($xml, "g");
        if ($package !== $argv[2] || $version !== $argv[3] ||
            !ctype_digit($size) || strpos($url, "https://pecl.php.net/get/") !== 0) exit(3);
        echo $size, "\n", $url, "\n";
    ' "${rest_file}" "${package}" "${version}") || {
        echo "错误：PECL REST 元数据验证失败: ${package}-${version}"
        rm -f "${rest_file}"
        return 1
    }
    expected_size=$(printf '%s\n' "${metadata}" | sed -n '1p')
    download_url=$(printf '%s\n' "${metadata}" | sed -n '2p')
    case "${download_url}" in
        *.tgz) ;;
        *) download_url="${download_url}.tgz" ;;
    esac
    _require_https_url "${download_url}" || return 1

    if [ -f "${filename}" ]; then
        actual_size=$(wc -c < "${filename}" | tr -d ' ')
        if [ "${actual_size}" != "${expected_size}" ]; then
            echo "警告：${filename} 大小与 PECL REST 不符，重新下载"
            rm -f "${filename}"
        fi
    fi
    if [ ! -f "${filename}" ]; then
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --proto '=https' --tlsv1.2 --http1.1 \
                --retry 3 --retry-delay 5 -o "${tmp_file}" "${download_url}" || {
                rm -f "${rest_file}" "${tmp_file}"
                return 1
            }
        else
            wget --https-only --tries=3 --timeout=30 -O "${tmp_file}" "${download_url}" || {
                rm -f "${rest_file}" "${tmp_file}"
                return 1
            }
        fi
        actual_size=$(wc -c < "${tmp_file}" | tr -d ' ')
        if [ "${actual_size}" != "${expected_size}" ]; then
            echo "错误：${filename} 大小与 PECL REST 不符"
            rm -f "${rest_file}" "${tmp_file}"
            return 1
        fi
        mv "${tmp_file}" "${filename}"
    fi

    if ! tar -xOf "${filename}" package.xml 2>/dev/null | php -r '
        $xml = @simplexml_load_string(stream_get_contents(STDIN));
        if ($xml === false) exit(2);
        $ns = $xml->getNamespaces(true);
        $p = isset($ns[""]) ? $xml->children($ns[""]) : $xml;
        if (trim((string) $p->name) !== $argv[1] ||
            trim((string) $p->version->release) !== $argv[2]) exit(3);
    ' "${package}" "${version}"; then
        echo "错误：${filename} 的 package.xml 身份校验失败"
        rm -f "${filename}" "${rest_file}"
        return 1
    fi
    rm -f "${rest_file}"
    echo "${filename} 已通过 PECL REST/package.xml 校验"
}

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

    _require_https_url "${url}" || return 1
    if [ ! -f "${filename}" ]; then
        echo "下载 ${filename}..."
        if command -v curl >/dev/null 2>&1; then
            # --http1.1：规避 CDN 在 HTTP/2 下未干净关闭流导致的 curl exit 18
            if ! curl -fsSL --proto '=https' --tlsv1.2 --http1.1 --retry 3 --retry-delay 5 -o "${filename}" "${url}"; then
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
            wget --https-only --tries=3 --timeout=30 -O "${filename}" "${url}" || {
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
        if ! _require_https_url "${url}"; then
            continue
        fi
        echo "尝试下载 ${filename}: ${url}"
        if command -v curl >/dev/null 2>&1; then
            # --http1.1：规避 CDN 在 HTTP/2 下未干净关闭流导致的 curl exit 18
            if curl -fsSL --proto '=https' --tlsv1.2 --http1.1 --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 5 -o "${filename}" "${url}"; then
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
            if wget --https-only --tries=3 --timeout=30 -O "${filename}" "${url}"; then
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
