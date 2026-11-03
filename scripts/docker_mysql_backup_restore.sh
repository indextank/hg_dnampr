#!/bin/bash

# 设置错误处理
set -e
# 启用管道失败检测（管道中任何命令失败都会导致整个管道失败）
set -o pipefail

# 设置 MySQL 容器名称、用户名和密码
MYSQL_CONTAINER_NAME='mysql'

MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"
MYSQL_CHARSET="utf8mb4"
MYSQL_USER='root'
MYSQL_PASSWORD='15Vcw9CBPhOA6N'

# 设置备份存放路径
BACKUP_PATH='/data/db_backup/'

# 检查并安装 pv 命令（用于显示进度）
HAS_PV=false
install_pv_if_needed() {
    if command -v pv >/dev/null 2>&1; then
        HAS_PV=true
        return 0
    fi

    echo "检测到系统未安装 pv 命令，正在尝试安装..."
    echo "提示: pv 命令可以提供更好的进度显示（百分比、速度、剩余时间）"

    # 检测系统类型并安装 pv
    if command -v apt-get >/dev/null 2>&1; then
        # Debian/Ubuntu 系统
        if [ "$(id -u)" = "0" ]; then
            apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq pv >/dev/null 2>&1
        else
            echo "需要 root 权限来安装 pv，尝试使用 sudo..."
            if command -v sudo >/dev/null 2>&1; then
                sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq pv >/dev/null 2>&1
            else
                echo "⚠️  无法安装 pv（需要 root 权限），将使用简单进度显示"
                return 1
            fi
        fi
    elif command -v yum >/dev/null 2>&1; then
        # CentOS/RHEL 系统
        if [ "$(id -u)" = "0" ]; then
            yum install -y -q pv >/dev/null 2>&1
        else
            echo "需要 root 权限来安装 pv，尝试使用 sudo..."
            if command -v sudo >/dev/null 2>&1; then
                sudo yum install -y -q pv >/dev/null 2>&1
            else
                echo "⚠️  无法安装 pv（需要 root 权限），将使用简单进度显示"
                return 1
            fi
        fi
    elif command -v dnf >/dev/null 2>&1; then
        # Fedora 系统
        if [ "$(id -u)" = "0" ]; then
            dnf install -y -q pv >/dev/null 2>&1
        else
            echo "需要 root 权限来安装 pv，尝试使用 sudo..."
            if command -v sudo >/dev/null 2>&1; then
                sudo dnf install -y -q pv >/dev/null 2>&1
            else
                echo "⚠️  无法安装 pv（需要 root 权限），将使用简单进度显示"
                return 1
            fi
        fi
    elif command -v apk >/dev/null 2>&1; then
        # Alpine 系统
        if [ "$(id -u)" = "0" ]; then
            apk add -q pv >/dev/null 2>&1
        else
            echo "需要 root 权限来安装 pv，尝试使用 sudo..."
            if command -v sudo >/dev/null 2>&1; then
                sudo apk add -q pv >/dev/null 2>&1
            else
                echo "⚠️  无法安装 pv（需要 root 权限），将使用简单进度显示"
                return 1
            fi
        fi
    elif command -v pacman >/dev/null 2>&1; then
        # Arch Linux 系统
        if [ "$(id -u)" = "0" ]; then
            pacman -Sy --noconfirm pv >/dev/null 2>&1
        else
            echo "需要 root 权限来安装 pv，尝试使用 sudo..."
            if command -v sudo >/dev/null 2>&1; then
                sudo pacman -Sy --noconfirm pv >/dev/null 2>&1
            else
                echo "⚠️  无法安装 pv（需要 root 权限），将使用简单进度显示"
                return 1
            fi
        fi
    else
        echo "⚠️  无法识别系统类型，无法自动安装 pv，将使用简单进度显示"
        return 1
    fi

    # 验证安装是否成功
    if command -v pv >/dev/null 2>&1; then
        HAS_PV=true
        echo "✅ pv 命令安装成功"
        return 0
    else
        echo "⚠️  pv 安装失败，将使用简单进度显示"
        return 1
    fi
}

# 尝试安装 pv（如果需要）
if ! command -v pv >/dev/null 2>&1; then
    install_pv_if_needed
fi

# 最终检查
if command -v pv >/dev/null 2>&1; then
    HAS_PV=true
fi

# 恢复数据库文件并显示进度
# ── SQL 流过滤器：剥离 GTID / SQL_LOG_BIN / DROP DATABASE / CREATE DATABASE / USE，并可选地将 SQL 中的库名引用从 rename_from 替换为 rename_to ──
# 注意：必须剥离 DROP DATABASE。恢复时 mysql 以目标库为默认库连接，若执行备份中的
#       DROP DATABASE（库名映射后即目标库），会话会失去默认库，后续语句报 ERROR 1046。
# 用法：gunzip ... | _apply_sql_filters [rename_from] [rename_to] | mysql target_db
_apply_sql_filters() {
    local rename_from="${1:-}"
    local rename_to="${2:-}"
    local _init
    _init="SET SESSION innodb_strict_mode=0;"$'\n'"SET SESSION sql_mode='NO_ENGINE_SUBSTITUTION';"$'\n'

    if [ -n "$rename_from" ] && [ -n "$rename_to" ] && [ "$rename_from" != "$rename_to" ]; then
        { printf '%s' "$_init"; cat; } | \
        sed -e '/^SET @@GLOBAL.GTID_PURGED=/d' \
            -e '/^SET @@SESSION.SQL_LOG_BIN=/d' \
            -e '/^\/\*!40000 DROP DATABASE /d' \
            -e '/^DROP DATABASE /d' \
            -e '/^CREATE DATABASE /d' \
            -e '/^USE /d' \
            -e "s/\`${rename_from}\`/\`${rename_to}\`/g"
    else
        { printf '%s' "$_init"; cat; } | \
        sed -e '/^SET @@GLOBAL.GTID_PURGED=/d' \
            -e '/^SET @@SESSION.SQL_LOG_BIN=/d' \
            -e '/^\/\*!40000 DROP DATABASE /d' \
            -e '/^DROP DATABASE /d' \
            -e '/^CREATE DATABASE /d' \
            -e '/^USE /d'
    fi
}

# ── MySQL 容器数据目录可用磁盘空间（GB，保留1位小数）；无法检测时输出 "?" ───
_mysql_disk_free_gb() {
    local avail_bytes
    avail_bytes=$(docker exec "$MYSQL_CONTAINER_NAME" \
        df /var/lib/mysql --output=avail -B1 2>/dev/null | tail -1 | tr -d ' \n' || true)
    avail_bytes=$(printf '%s' "${avail_bytes:-0}" | tr -cd '0-9')
    if [ -z "$avail_bytes" ] || ! [ "$avail_bytes" -gt 0 ] 2>/dev/null; then
        echo "?"
        return 1
    fi
    awk "BEGIN {printf \"%.1f\", ${avail_bytes} / 1024 / 1024 / 1024}"
}

# ── InnoDB 写入自检：用于辅助诊断 Error 168 / 1030 / 权限问题 ─────────────
_mysql_innodb_write_check() {
    local diag_db="_diag168_$$"
    local diag_sql
    diag_sql="CREATE DATABASE IF NOT EXISTS \`${diag_db}\`; USE \`${diag_db}\`; CREATE TABLE IF NOT EXISTS t1(id INT PRIMARY KEY) ENGINE=InnoDB; DROP DATABASE IF EXISTS \`${diag_db}\`;"
    docker exec "$MYSQL_CONTAINER_NAME" \
        mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
        -e "$diag_sql" 2>&1
}

# ── 自动修复 MySQL 数据目录权限（errno: 13 / Permission denied）──────────
# 根因：宿主机 bind-mount 目录（/srv/volume_data/mysql）属主不是容器内
#       mysql 用户（UID 999），导致 MySQL 无法创建新 schema 目录。
# 方案：以 root 身份在容器内执行 chown，无需宿主机 sudo 权限。
# 返回：0 = 修复成功且写入自检通过；1 = 修复失败
_mysql_fix_datadir_permissions() {
    echo "  🔧 检测到数据目录权限异常（errno: 13），尝试在容器内自动修复..."
    local fix_output
    fix_output=$(docker exec -u root "$MYSQL_CONTAINER_NAME" \
        bash -c "chown -R mysql:mysql /var/lib/mysql && chmod 750 /var/lib/mysql" 2>&1 || true)
    if [ -n "$fix_output" ]; then
        echo "  ⚠️  chown 输出: $fix_output"
    fi

    # 修复后重新做写入自检
    local recheck
    recheck=$(_mysql_innodb_write_check || true)
    recheck=$(printf '%s\n' "$recheck" | grep -v "\[Warning\]" | grep -v "Using a password" | sed '/^$/d')
    if [ -z "$recheck" ]; then
        echo "  ✅ 权限修复成功，InnoDB 写入自检通过，即将开始恢复..."
        return 0
    fi

    echo "  ❌ 权限修复后写入自检仍失败:"
    printf '%s\n' "$recheck" | head -3 | sed 's/^/     /'
    echo "  💡 请手动检查宿主机挂载目录并修复："
    echo "     sudo ls -ld /srv/volume_data/mysql"
    echo "     sudo chown -R 999:999 /srv/volume_data/mysql"
    echo "     然后重启容器：./up.sh mysql restart"
    return 1
}

# ── 打印恢复失败后的诊断信息 ───────────────────────────────────────────────
_print_restore_diagnostics() {
    local backup_file="$1"
    local target_db="$2"
    local error_file="$3"

    echo "  🔍 开始恢复诊断..."

    local free_gb
    free_gb=$(_mysql_disk_free_gb || true)
    if [ -n "$free_gb" ] && [ "$free_gb" != "?" ]; then
        echo "  🔍 MySQL 数据目录当前可用空间: ${free_gb} GB"
    else
        echo "  ⚠️  无法检测 MySQL 数据目录可用空间"
    fi

    local innodb_check_output
    innodb_check_output=$(_mysql_innodb_write_check || true)
    innodb_check_output=$(printf '%s\n' "$innodb_check_output" | grep -v "\[Warning\]" | grep -v "Using a password" | sed '/^$/d')

    if [ -n "$innodb_check_output" ]; then
        echo "  ❌ InnoDB 写入自检失败 → MySQL 容器 InnoDB 异常，建议重启容器后重试"
        printf '%s\n' "$innodb_check_output" | head -5 | sed 's/^/     /'
        return 0
    fi

    echo "  ✅ InnoDB 写入自检通过"

    if [ -f "$backup_file" ]; then
        echo "  🔎 备份文件头部（前 40 行）:"
        zcat "$backup_file" 2>/dev/null | head -40 | sed 's/^/     /'
    fi

    if [ -f "$error_file" ]; then
        local filtered_errors
        filtered_errors=$(cat "$error_file" | grep -v "^$" | grep -v "\[Warning\]" | grep -v "Using a password" || true)
        if [ -n "$filtered_errors" ]; then
            echo "  🔎 恢复错误摘要:"
            printf '%s\n' "$filtered_errors" | head -10 | sed 's/^/     /'
        fi
    fi
}

restore_file_with_progress() {
    local backup_file="$1"
    local db_name="${2:-}"
    local rename_from="${3:-}"

    # 获取文件大小
    local file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")

    if [ "$file_size" = "0" ]; then
        echo "⚠️  无法获取文件大小，使用普通模式恢复"
        # 创建临时文件用于捕获错误
        local error_file="/tmp/mysql_restore_error_$$.txt"
        local restore_status=0

        local free_gb
        free_gb=$(_mysql_disk_free_gb || true)
        if [ -n "$free_gb" ] && [ "$free_gb" != "?" ]; then
            echo "  🔍 MySQL 数据目录当前可用空间: ${free_gb} GB"
        fi

        if [ -n "$db_name" ]; then
            gunzip < "$backup_file" 2>&1 | \
            _apply_sql_filters "$rename_from" "$db_name" | \
            docker exec -i $MYSQL_CONTAINER_NAME \
            mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD $db_name 2>"$error_file" || restore_status=$?
        else
            gunzip < "$backup_file" 2>&1 | \
            _apply_sql_filters "$rename_from" "$db_name" | \
            docker exec -i $MYSQL_CONTAINER_NAME \
            mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD 2>"$error_file" || restore_status=$?
        fi

        # 检查是否有真正的错误（排除警告信息）
        if [ $restore_status -ne 0 ]; then
            # 恢复失败，显示错误信息
            if [ -s "$error_file" ]; then
                echo ""
                echo "❌ MySQL 错误信息："
                # 过滤掉警告信息，只显示真正的错误
                cat "$error_file" | grep -v "^$" | grep -v "\[Warning\]" | grep -v "Using a password" | head -10
                # 如果过滤后还有内容，说明有真正的错误
                local real_errors=$(cat "$error_file" | grep -v "^$" | grep -v "\[Warning\]" | grep -v "Using a password" | wc -l)
                if [ "$real_errors" -eq 0 ]; then
                    # 只有警告，没有真正的错误，恢复可能成功
                    echo "⚠️  仅检测到警告信息，恢复可能已成功"
                fi
            fi
            _print_restore_diagnostics "$backup_file" "$db_name" "$error_file"
            rm -f "$error_file" 2>/dev/null || true
            return $restore_status
        elif [ -s "$error_file" ]; then
            # 恢复状态为0，但错误文件有内容，可能是警告
            local warnings=$(cat "$error_file" | grep -v "^$" | grep -c "\[Warning\]" || echo "0")
            local real_errors=$(cat "$error_file" | grep -v "^$" | grep -v "\[Warning\]" | grep -v "Using a password" | wc -l)

            if [ "$real_errors" -gt 0 ]; then
                # 有真正的错误
                echo ""
                echo "⚠️  MySQL 警告/错误信息："
                cat "$error_file" | grep -v "^$" | head -10
            elif [ "$warnings" -gt 0 ]; then
                # 只有警告，不影响恢复
                echo ""
                echo "ℹ️  MySQL 警告信息（不影响恢复）："
                cat "$error_file" | grep -v "^$" | head -5
            fi
        fi

        rm -f "$error_file" 2>/dev/null || true
        return 0
    fi

    # 格式化文件大小显示
    local file_size_mb=$(awk "BEGIN {printf \"%.2f\", $file_size / 1024 / 1024}")
    local file_size_gb=$(awk "BEGIN {printf \"%.2f\", $file_size / 1024 / 1024 / 1024}")

    if [ $(echo "$file_size_gb >= 1" | bc 2>/dev/null || awk "BEGIN {print ($file_size_gb >= 1) ? 1 : 0}") = "1" ]; then
        echo "文件大小: ${file_size_gb} GB (${file_size_mb} MB)"
    else
        echo "文件大小: ${file_size_mb} MB"
    fi

    # 如果系统有 pv 命令，使用它显示进度（显示百分比、速度、剩余时间）
    if [ "$HAS_PV" = true ]; then
        echo "正在恢复..."
        # 创建临时文件用于捕获错误
        local error_file="/tmp/mysql_restore_error_$$.txt"
        local restore_status=0

        local free_gb
        free_gb=$(_mysql_disk_free_gb || true)
        if [ -n "$free_gb" ] && [ "$free_gb" != "?" ]; then
            echo "  🔍 MySQL 数据目录当前可用空间: ${free_gb} GB"
        fi

        if [ -n "$db_name" ]; then
            # pv 的进度输出到 stderr（终端），数据输出到 stdout
            pv -p -t -e -r -b -s "$file_size" "$backup_file" 2>&2 | gunzip 2>/dev/null | \
            _apply_sql_filters "$rename_from" "$db_name" | \
            docker exec -i $MYSQL_CONTAINER_NAME \
            mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD $db_name 2>"$error_file" || restore_status=$?
        else
            # pv 的进度输出到 stderr（终端），数据输出到 stdout
            pv -p -t -e -r -b -s "$file_size" "$backup_file" 2>&2 | gunzip 2>/dev/null | \
            _apply_sql_filters "$rename_from" "$db_name" | \
            docker exec -i $MYSQL_CONTAINER_NAME \
            mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD 2>"$error_file" || restore_status=$?
        fi

        # 检查是否有真正的错误（排除警告信息）
        if [ $restore_status -ne 0 ]; then
            # 恢复失败，显示错误信息
            if [ -s "$error_file" ]; then
                echo ""
                echo "❌ MySQL 错误信息："
                # 过滤掉警告信息，只显示真正的错误
                cat "$error_file" | grep -v "^$" | grep -v "\[Warning\]" | grep -v "Using a password" | head -10
                # 如果过滤后还有内容，说明有真正的错误
                local real_errors=$(cat "$error_file" | grep -v "^$" | grep -v "\[Warning\]" | grep -v "Using a password" | wc -l)
                if [ "$real_errors" -eq 0 ]; then
                    # 只有警告，没有真正的错误，恢复可能成功
                    echo "⚠️  仅检测到警告信息，恢复可能已成功"
                fi
            fi
            _print_restore_diagnostics "$backup_file" "$db_name" "$error_file"
            rm -f "$error_file" 2>/dev/null || true
            return $restore_status
        elif [ -s "$error_file" ]; then
            # 恢复状态为0，但错误文件有内容，可能是警告
            local warnings=$(cat "$error_file" | grep -v "^$" | grep -c "\[Warning\]" || echo "0")
            local real_errors=$(cat "$error_file" | grep -v "^$" | grep -v "\[Warning\]" | grep -v "Using a password" | wc -l)

            if [ "$real_errors" -gt 0 ]; then
                # 有真正的错误
                echo ""
                echo "⚠️  MySQL 警告/错误信息："
                cat "$error_file" | grep -v "^$" | head -10
            elif [ "$warnings" -gt 0 ]; then
                # 只有警告，不影响恢复
                echo ""
                echo "ℹ️  MySQL 警告信息（不影响恢复）："
                cat "$error_file" | grep -v "^$" | head -5
            fi
        fi

        rm -f "$error_file" 2>/dev/null || true
        return 0
    else
        # 没有 pv 命令，使用简单的进度显示（显示已用时间和估算进度）
        echo "正在恢复（显示时间进度）..."
        local start_time=$(date +%s)
        local bytes_read=0
        local progress_file="/tmp/restore_progress_$$.txt"

        # 创建临时文件用于捕获错误
        local error_file="/tmp/mysql_restore_error_$$.txt"

        local free_gb
        free_gb=$(_mysql_disk_free_gb || true)
        if [ -n "$free_gb" ] && [ "$free_gb" != "?" ]; then
            echo "  🔍 MySQL 数据目录当前可用空间: ${free_gb} GB"
        fi

        # 启动恢复进程，使用 dd 的 status=progress 选项来监控进度
        if [ -n "$db_name" ]; then
            (
                # 使用 dd 读取文件，每 1MB 输出一次进度
                dd if="$backup_file" bs=1M status=progress 2>"$progress_file" | gunzip 2>/dev/null | \
                _apply_sql_filters "$rename_from" "$db_name" | \
                docker exec -i $MYSQL_CONTAINER_NAME \
                mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD $db_name 2>"$error_file"
            ) &
            local restore_pid=$!
        else
            (
                dd if="$backup_file" bs=1M status=progress 2>"$progress_file" | gunzip 2>/dev/null | \
                _apply_sql_filters "$rename_from" "$db_name" | \
                docker exec -i $MYSQL_CONTAINER_NAME \
                mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD 2>"$error_file"
            ) &
            local restore_pid=$!
        fi

        # 监控进程并显示进度
        while kill -0 $restore_pid 2>/dev/null; do
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            local minutes=$((elapsed / 60))
            local seconds=$((elapsed % 60))

            # 从 dd 的进度文件中读取已读取的字节数
            if [ -f "$progress_file" ]; then
                # dd status=progress 输出格式：可能是 "12345678 bytes (12 MB, 11 MiB) copied, 1.23456 s, 10 MB/s"
                # 或者 "12345678+0 records in"
                local dd_line=$(tail -1 "$progress_file" 2>/dev/null || echo "")

                # 尝试提取字节数（多种格式）
                if echo "$dd_line" | grep -qE '[0-9]+ bytes'; then
                    # 格式：12345678 bytes
                    bytes_read=$(echo "$dd_line" | grep -oE '[0-9]+ bytes' | head -1 | awk '{print $1}' || echo "")
                elif echo "$dd_line" | grep -qE '[0-9]+\+[0-9]+ records'; then
                    # 格式：1234+1 records in
                    local records=$(echo "$dd_line" | awk '{print $1}' | tr -d '+' || echo "")
                    if [[ "$records" =~ ^[0-9]+$ ]]; then
                        # 假设每个记录是 1MB
                        bytes_read=$((records * 1024 * 1024))
                    fi
                fi

                # 验证提取的字节数是否有效
                if [ -n "$bytes_read" ] && [[ "$bytes_read" =~ ^[0-9]+$ ]] && [ "$bytes_read" -le "$file_size" ]; then
                    # bytes_read 已设置
                    :
                else
                    bytes_read=0
                fi
            fi

            # 计算百分比（基于已读取的字节数）
            local percent=0
            if [ "$bytes_read" != "0" ] && [ "$file_size" != "0" ]; then
                percent=$(awk "BEGIN {printf \"%.1f\", ($bytes_read / $file_size) * 100}")
            fi

            # 计算速度（MB/s）
            local speed_mb=0
            if [ $elapsed -gt 0 ] && [ "$bytes_read" != "0" ]; then
                speed_mb=$(awk "BEGIN {printf \"%.2f\", ($bytes_read / 1024 / 1024) / $elapsed}")
            fi

            # 估算剩余时间
            local remaining_seconds=0
            if [ "$speed_mb" != "0" ] && [ "$percent" != "0" ] && [ "$percent" != "100.0" ]; then
                local remaining_bytes=$((file_size - bytes_read))
                local remaining_mb=$(awk "BEGIN {printf \"%.2f\", $remaining_bytes / 1024 / 1024}")
                remaining_seconds=$(awk "BEGIN {printf \"%.0f\", $remaining_mb / $speed_mb}" 2>/dev/null || echo "0")
            fi

            local remaining_min=$((remaining_seconds / 60))
            local remaining_sec=$((remaining_seconds % 60))

            # 显示进度信息
            if [ "$percent" != "0" ] && [ "$speed_mb" != "0" ]; then
                printf "\r⏳ 恢复中... 进度: %5.1f%% | 已用时: %02d:%02d | 速度: %.2f MB/s | 剩余: %02d:%02d" \
                    "$percent" "$minutes" "$seconds" "$speed_mb" "$remaining_min" "$remaining_sec"
            else
                printf "\r⏳ 恢复中... 已用时: %02d:%02d" "$minutes" "$seconds"
            fi

            sleep 1
        done

        # 等待进程完成
        wait $restore_pid
        local restore_status=$?

        # 检查是否有错误
        if [ $restore_status -ne 0 ] || [ -s "$error_file" ]; then
            if [ -s "$error_file" ]; then
                echo ""
                echo "❌ MySQL 错误信息："
                cat "$error_file" | grep -v "^$" | head -10
            fi
            if [ $restore_status -ne 0 ]; then
                _print_restore_diagnostics "$backup_file" "$db_name" "$error_file"
            fi
        fi

        # 清理临时文件
        rm -f "$progress_file" "$error_file" 2>/dev/null || true

        # 显示完成信息
        local total_elapsed=$(($(date +%s) - start_time))
        local total_min=$((total_elapsed / 60))
        local total_sec=$((total_elapsed % 60))

        if [ $restore_status -eq 0 ]; then
            printf "\r✅ 恢复完成！总用时: %02d:%02d\n" "$total_min" "$total_sec"
        else
            printf "\r❌ 恢复失败！总用时: %02d:%02d\n" "$total_min" "$total_sec"
        fi

        return $restore_status
    fi
}

# 检查MySQL容器是否运行
if ! docker ps | grep -q "$MYSQL_CONTAINER_NAME"; then
    echo "错误：MySQL容器 '$MYSQL_CONTAINER_NAME' 未运行！"
    echo "请先启动MySQL容器："
    echo "  ./up.sh mysql"
    exit 1
fi

# 命令行参数：仅当单独传入 "1"/"2"/"7" 时跳过菜单直接执行对应操作；
# 无参数、非法参数、多参数组合一律忽略并走原交互菜单。
OPERATION=""
if [ "$#" -eq 1 ]; then
    case "$1" in
        1|2|7)
            OPERATION="$1"
            ;;
    esac
fi

if [ -z "$OPERATION" ]; then
    # 显示选择菜单
    echo "请选择操作："
    echo "1. 备份单个数据库"
    echo "2. 备份所有数据库(排除mysql自带库)"
    echo ""
    echo "3. 恢复单个数据库"
    echo "4. 恢复全部数据库"
    echo ""
    echo "5. 数据库更名"
    echo ""
    echo "6. 删除所有非系统数据库"
    echo "7. 完整清理流程(备份→删除→恢复)"
    read -p "输入选择 [1-7]: " OPERATION
fi

# 功能实现的函数
backup_single_db() {
   read -p "输入要备份的数据库名: " DB_NAME
   BACKUP_FILE="${BACKUP_PATH}${DB_NAME}_backup_$(date '+%Y%m%d_%H%M%S').sql.gz"

   # 确保备份目录存在
   mkdir -p "$BACKUP_PATH"

   echo "正在备份数据库: $DB_NAME ..."
   docker exec $MYSQL_CONTAINER_NAME \
   mysqldump -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD \
   --default-character-set=$MYSQL_CHARSET \
   --single-transaction \
   --set-gtid-purged=OFF \
   --flush-logs \
   --hex-blob \
   --triggers \
   --routines \
   --events \
   --databases $DB_NAME 2>/dev/null | gzip > "$BACKUP_FILE"

   if [ $? -eq 0 ]; then
       echo "✅ 数据库 $DB_NAME 备份完成，文件路径：$BACKUP_FILE"
   else
       echo "❌ 数据库 $DB_NAME 备份失败！"
       exit 1
   fi
}

backup_all_dbs() {
    # 确保备份目录存在
    mkdir -p "$BACKUP_PATH"

    echo "正在获取数据库列表..."
    # 获取所有非系统数据库列表
    DBS_RAW=$(docker exec $MYSQL_CONTAINER_NAME \
    mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "(Database|sys|information_schema|performance_schema|mysql)")

    if [ -z "$DBS_RAW" ]; then
        echo "❌ 未找到任何数据库！"
        return 1
    fi

    # 将数据库列表转换为数组
    DBS_ARRAY=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            DBS_ARRAY+=("$line")
        fi
    done <<< "$DBS_RAW"

    echo "找到以下数据库："
    for db in "${DBS_ARRAY[@]}"; do
        echo "  - $db"
    done
    echo "开始备份..."

    # 为每个数据库创建备份
    for db in "${DBS_ARRAY[@]}"; do
        BACKUP_FILE="${BACKUP_PATH}${db}_backup_$(date '+%Y%m%d_%H%M%S').sql.gz"

        echo "正在备份数据库: $db ..."
        docker exec $MYSQL_CONTAINER_NAME \
        mysqldump -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD \
        --default-character-set=utf8mb4 \
        --single-transaction \
        --set-gtid-purged=OFF \
        --flush-logs \
        --hex-blob \
        --triggers \
        --routines \
        --events \
        --databases ${db} 2>/dev/null | gzip > "$BACKUP_FILE"

        if [ $? -eq 0 ]; then
            echo "✅ 数据库 $db 已备份到 $BACKUP_FILE"
        else
            echo "❌ 数据库 $db 备份失败！"
        fi
    done

    echo "🎉 所有数据库备份完成！"
}


# 从备份文件头部自动提取数据库名
# 优先查找 USE `db`; 语句（--databases 备份），其次读注释行 -- Host: ...  Database: xxx
extract_db_name_from_file() {
    local backup_file="$1"
    local detected_db=""

    # 方法1：含 USE `db`; 的备份（mysqldump --databases）
    detected_db=$(zcat "$backup_file" 2>/dev/null | head -50 \
        | grep -m1 "^USE " | sed 's/^USE //;s/;//' | tr -d '`' | tr -d ' \r\n')

    # 方法2：从 mysqldump 头部注释 "-- Host: x.x.x.x    Database: db_name" 提取
    if [ -z "$detected_db" ]; then
        detected_db=$(zcat "$backup_file" 2>/dev/null | head -5 \
            | grep "^-- Host:" | sed 's/.*Database:[[:space:]]*//' | tr -d ' \r\n')
    fi

    echo "$detected_db"
}

# 自动检测库名并恢复：
#   - 若备份文件缺少 CREATE DATABASE / USE 语句，先自动建库再指定库名恢复
#   - 若文件已含上述语句，则直接走无库名的全量恢复（兼容原有行为）
restore_with_auto_db() {
    local backup_file="$1"
    local target_db="${2:-}"
    local rename_from="${3:-}"

    if [ -z "$target_db" ]; then
        target_db=$(extract_db_name_from_file "$backup_file")
    fi

    if [ -z "$target_db" ]; then
        echo "⚠️  无法从文件头部检测到数据库名，尝试直接恢复（可能失败）..."
        restore_file_with_progress "$backup_file"
        return $?
    fi

    # ── 恢复前预检：检测 /var/lib/mysql 是否可写，errno:13 则自动修复 ──────
    local _pre_check
    _pre_check=$(_mysql_innodb_write_check 2>&1 || true)
    _pre_check=$(printf '%s\n' "$_pre_check" | grep -v "\[Warning\]" | grep -v "Using a password" | sed '/^$/d')
    if printf '%s\n' "$_pre_check" | grep -q "errno: 13\|Permission denied\|3680"; then
        if ! _mysql_fix_datadir_permissions; then
            echo "  ❌ 数据目录权限修复失败，无法继续恢复，请按上方提示手动处理"
            return 1
        fi
    fi

    echo "ℹ️  确保目标数据库: \`$target_db\`（默认字符集 utf8mb4，排序规则 utf8mb4_unicode_ci）"
    docker exec "$MYSQL_CONTAINER_NAME" \
        mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
        -e "CREATE DATABASE IF NOT EXISTS \`${target_db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        2>/dev/null || true

    restore_file_with_progress "$backup_file" "$target_db" "$rename_from"
}

# 恢复单个数据库：
#   1. 用户指定备份文件
#   2. 自动从文件头部检测目标库名，用户可确认或修改
#   3. 若文件无 CREATE DATABASE 语句则自动建库
#   4. 调用 restore_file_with_progress 执行恢复
restore_single_db() {
    # ── 1. 获取备份文件路径 ──────────────────────────────────────────────
    echo ""
    local RESTORE_FILE=""

    # 若默认路径存在，列出可选文件供快速选择
    if [ -d "$BACKUP_PATH" ] && ls "$BACKUP_PATH"/*.sql.gz >/dev/null 2>&1; then
        local AVAILABLE_FILES
        AVAILABLE_FILES=($(ls -t "$BACKUP_PATH"/*.sql.gz 2>/dev/null))
        echo "默认备份路径下的文件（共 ${#AVAILABLE_FILES[@]} 个）："
        echo "----------------------------------------"
        for i in "${!AVAILABLE_FILES[@]}"; do
            local fname fsize ftime
            fname=$(basename "${AVAILABLE_FILES[$i]}")
            fsize=$(ls -lh "${AVAILABLE_FILES[$i]}" | awk '{print $5}')
            ftime=$(stat -c "%y" "${AVAILABLE_FILES[$i]}" 2>/dev/null | cut -d'.' -f1 || echo "未知")
            echo "  $((i+1)). $fname"
            echo "      大小: $fsize | 修改时间: $ftime"
        done
        echo "----------------------------------------"
        echo ""
        while true; do
            read -p "请输入序号选择文件，或直接输入完整路径: " FILE_INPUT
            if [[ "$FILE_INPUT" =~ ^[0-9]+$ ]] && \
               [ "$FILE_INPUT" -ge 1 ] && [ "$FILE_INPUT" -le ${#AVAILABLE_FILES[@]} ]; then
                RESTORE_FILE="${AVAILABLE_FILES[$((FILE_INPUT-1))]}"
                break
            elif [ -f "$FILE_INPUT" ]; then
                RESTORE_FILE="$FILE_INPUT"
                break
            elif [ -n "$FILE_INPUT" ]; then
                echo "❌ 无效输入，请重新输入"
            else
                echo "❌ 未输入任何内容，请重新输入"
            fi
        done
    else
        while true; do
            read -p "请输入备份文件完整路径 (.sql.gz): " RESTORE_FILE
            RESTORE_FILE="${RESTORE_FILE// /}"
            if [ -f "$RESTORE_FILE" ]; then
                break
            else
                echo "❌ 文件不存在: $RESTORE_FILE，请重新输入"
            fi
        done
    fi

    echo "✅ 已选择文件: $(basename "$RESTORE_FILE")"

    # ── 2. 检测 / 确认目标数据库名 ──────────────────────────────────────
    local detected_db TARGET_DB RENAME_FROM
    detected_db=$(extract_db_name_from_file "$RESTORE_FILE")
    RENAME_FROM=""

    echo ""
    if [ -n "$detected_db" ]; then
        echo "ℹ️  从文件头部检测到目标数据库: \`$detected_db\`"
        read -e -i "$detected_db" -p "目标数据库名: " TARGET_DB
        if [ -z "$TARGET_DB" ]; then
            TARGET_DB="$detected_db"
        fi
    else
        echo "⚠️  未能从文件头部检测到数据库名"
        while true; do
            read -p "请手动输入目标数据库名: " TARGET_DB
            TARGET_DB="${TARGET_DB// /}"
            if [ -n "$TARGET_DB" ]; then
                break
            else
                echo "❌ 数据库名不能为空，请重新输入"
            fi
        done
    fi

    echo "✅ 目标数据库: \`$TARGET_DB\`"

    if [ -n "$detected_db" ] && [ "$TARGET_DB" != "$detected_db" ]; then
        RENAME_FROM="$detected_db"
        echo "ℹ️  库名映射: \`$RENAME_FROM\` → \`$TARGET_DB\`"
    fi

    # ── 3. 选择恢复模式（覆盖导入 / 清空重建导入）───────────────────────
    echo ""
    echo "请选择恢复模式："
    echo "  1) 覆盖导入（当前）"
    echo "     - 不先删库；同名表按备份 SQL 覆盖，备份中不存在的旧表会保留"
    echo "  2) 清空重建导入"
    echo "     - 若目标库已存在：直接 DROP DATABASE，再按备份恢复（不另做保护性备份）"
    local RESTORE_MODE=""
    while true; do
        read -p "输入选择 [1-2，默认1]: " RESTORE_MODE
        RESTORE_MODE="${RESTORE_MODE// /}"
        if [ -z "$RESTORE_MODE" ]; then
            RESTORE_MODE="1"
        fi
        case "$RESTORE_MODE" in
            1|2) break ;;
            *) echo "❌ 无效选择，请输入 1 或 2" ;;
        esac
    done

    # 若选择清空重建，且目标库已存在，则直接删除后重建恢复
    if [ "$RESTORE_MODE" = "2" ]; then
        local db_exists
        db_exists=$(_rdb_exec -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${TARGET_DB}';")
        db_exists=${db_exists:-0}
        if [ "$db_exists" -gt 0 ] 2>/dev/null; then
            echo "🗑️  正在清空目标数据库: \`$TARGET_DB\`"
            if ! _rdb_exec -e "DROP DATABASE IF EXISTS \`${TARGET_DB}\`;"; then
                echo "❌ 删除目标数据库失败，已中止恢复"
                return 1
            fi
            echo "✅ 目标数据库已清空，将执行重建导入"
        else
            echo "ℹ️  目标数据库当前不存在，按重建导入流程继续"
        fi
    fi

    # ── 4. 确保目标库存在并执行恢复 ─────────────────────────────────────
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "正在恢复数据库: \`$TARGET_DB\`"
    echo "文件: $(basename "$RESTORE_FILE")"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if restore_with_auto_db "$RESTORE_FILE" "$TARGET_DB" "$RENAME_FROM"; then
        echo "✅ 数据库 \`$TARGET_DB\` 恢复完成"
    else
        echo "❌ 数据库 \`$TARGET_DB\` 恢复失败"
        return 1
    fi
}

# ── 辅助函数：在容器内静默执行 SQL 并返回结果（自动屏蔽密码警告）──────────
_rdb_exec() {
    docker exec "$MYSQL_CONTAINER_NAME" \
        mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
        -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
        --silent --skip-column-names \
        "$@" 2>/dev/null
}

# ── 数据库更名 ─────────────────────────────────────────────────────────────
# 策略：
#   1. 预先导出视图/存储过程/函数/事件的 DDL（表迁移前，保证引用完整）
#   2. 逐表执行 RENAME TABLE（InnoDB 为纯元数据操作，无需复制数据，GB 级秒级完成）
#      触发器随表自动迁移，跨库外键失败的表单独报告
#   3. 将预导出 DDL（已 sed 替换库名引用）导入新库
#   4. 验证对象数量，让用户决定是否删除原库
rename_database() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔄  数据库更名"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "说明: MySQL 无原生 RENAME DATABASE 命令。"
    echo "  本工具采用「逐表元数据迁移」策略："
    echo "  InnoDB 的 RENAME TABLE 仅修改元数据，无需复制数据，"
    echo "  GB 级大表通常在秒级完成；视图/存储过程/函数/事件单独处理。"
    echo ""

    # ── 1. 获取原/新数据库名 ─────────────────────────────────────────────
    local OLD_DB NEW_DB
    while true; do
        read -p "请输入原数据库名称: " OLD_DB
        OLD_DB="${OLD_DB// /}"
        [ -n "$OLD_DB" ] && break
        echo "❌ 数据库名不能为空"
    done

    while true; do
        read -p "请输入新数据库名称: " NEW_DB
        NEW_DB="${NEW_DB// /}"
        [ -n "$NEW_DB" ] && break
        echo "❌ 数据库名不能为空"
    done

    if [ "$OLD_DB" = "$NEW_DB" ]; then
        echo "❌ 新旧名称相同，无需操作"
        return 1
    fi

    # ── 2. 验证原库存在 / 新库不存在 ────────────────────────────────────
    local _cnt
    _cnt=$(_rdb_exec -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${OLD_DB}';")
    if [ "${_cnt:-0}" -eq 0 ]; then
        echo "❌ 数据库 \`$OLD_DB\` 不存在"
        return 1
    fi
    local new_db_exists=false
    local new_db_tbl_cnt=0
    _cnt=$(_rdb_exec -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${NEW_DB}';")
    if [ "${_cnt:-0}" -gt 0 ]; then
        new_db_exists=true
        new_db_tbl_cnt=$(_rdb_exec -e \
            "SELECT COUNT(*) FROM information_schema.TABLES \
             WHERE TABLE_SCHEMA='${NEW_DB}' AND TABLE_TYPE='BASE TABLE';")
    fi

    # ── 3. 收集库信息 ────────────────────────────────────────────────────
    echo "📊 正在分析数据库..."
    local tbl_cnt view_cnt proc_cnt func_cnt evt_cnt db_size non_innodb active_conn
    tbl_cnt=$(_rdb_exec   -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${OLD_DB}' AND TABLE_TYPE='BASE TABLE';")
    view_cnt=$(_rdb_exec  -e "SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='${OLD_DB}';")
    proc_cnt=$(_rdb_exec  -e "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='${OLD_DB}' AND ROUTINE_TYPE='PROCEDURE';")
    func_cnt=$(_rdb_exec  -e "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='${OLD_DB}' AND ROUTINE_TYPE='FUNCTION';")
    evt_cnt=$(_rdb_exec   -e "SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA='${OLD_DB}';")
    db_size=$(_rdb_exec   -e "SELECT CONCAT(IFNULL(ROUND(SUM(data_length+index_length)/1024/1024/1024,2),0),' GB') FROM information_schema.TABLES WHERE TABLE_SCHEMA='${OLD_DB}';")
    non_innodb=$(_rdb_exec -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${OLD_DB}' AND TABLE_TYPE='BASE TABLE' AND ENGINE!='InnoDB';")
    active_conn=$(_rdb_exec -e "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE DB='${OLD_DB}' AND ID!=CONNECTION_ID();")

    echo ""
    echo "┌─────────────────────────────────────────────"
    if [ "$new_db_exists" = true ]; then
        printf "│  %-14s \`%s\`  →  \`%s\` ⚠️  (已存在，覆盖模式)\n" "更名:" "$OLD_DB" "$NEW_DB"
    else
        printf "│  %-14s \`%s\`  →  \`%s\`\n" "更名:" "$OLD_DB" "$NEW_DB"
    fi
    echo "├─────────────────────────────────────────────"
    printf "│  %-14s %s 张%s\n" "基础表:" "${tbl_cnt:-0}" \
        "$([ "${non_innodb:-0}" -gt 0 ] && echo "  (含 ${non_innodb} 张非InnoDB，迁移可能较慢)" || echo "")"
    printf "│  %-14s %s 个\n" "视图:"     "${view_cnt:-0}"
    printf "│  %-14s %s 个\n" "存储过程:" "${proc_cnt:-0}"
    printf "│  %-14s %s 个\n" "函数:"     "${func_cnt:-0}"
    printf "│  %-14s %s 个\n" "事件:"     "${evt_cnt:-0}"
    printf "│  %-14s %s\n"   "磁盘占用:" "${db_size:-0 GB}"
    printf "│  %-14s %s 个\n" "活跃连接:" "${active_conn:-0}"
    if [ "$new_db_exists" = true ]; then
        echo "├─────────────────────────────────────────────"
        printf "│  ⚠️  %-12s \`%s\` 已存在 %s 张表，同名表将被覆盖\n" "覆盖目标:" "$NEW_DB" "${new_db_tbl_cnt:-0}"
    fi
    echo "└─────────────────────────────────────────────"

    # ── 4. 活跃连接警告 ──────────────────────────────────────────────────
    if [ "${active_conn:-0}" -gt 0 ]; then
        echo ""
        echo "⚠️  当前有 ${active_conn} 个连接正在使用 \`$OLD_DB\`"
        echo "   RENAME TABLE 每次对单张表加 DDL 元数据锁（通常毫秒级释放），"
        echo "   锁期间该表的读写请求会短暂排队，锁释放后自动继续，影响极小。"
        echo "   更名完成后请及时将应用的数据库连接配置改为 \`$NEW_DB\`。"
        echo ""
        read -p "了解上述影响，是否继续？(y/N): " _ans
        [[ "$_ans" =~ ^[Yy]$ ]] || { echo "操作已取消"; return 0; }
    fi

    # ── 5. 最终确认 ──────────────────────────────────────────────────────
    echo ""
    if [ "$new_db_exists" = true ]; then
        read -p "确认将 \`$OLD_DB\` 迁移至 \`$NEW_DB\`（同名表将被覆盖）？(y/N): " _ans
    else
        read -p "确认将 \`$OLD_DB\` 更名为 \`$NEW_DB\`？(y/N): " _ans
    fi
    [[ "$_ans" =~ ^[Yy]$ ]] || { echo "操作已取消"; return 0; }

    # ── 6. 执行更名 ──────────────────────────────────────────────────────
    local _t0; _t0=$(date +%s)
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 6.1 预导出视图/存储过程/函数/事件 DDL
    #     必须在 RENAME TABLE 之前执行，此时表仍在 OLD_DB，视图引用完整
    local TEMP_DDL="" has_ddl=false
    if [ "${view_cnt:-0}" -gt 0 ] || [ "${proc_cnt:-0}" -gt 0 ] || \
       [ "${func_cnt:-0}" -gt 0 ] || [ "${evt_cnt:-0}" -gt 0 ]; then
        has_ddl=true
    fi

    if [ "$has_ddl" = true ]; then
        echo "▶  [1/4] 预导出 DDL 对象（视图/存储过程/函数/事件）..."
        TEMP_DDL=$(mktemp /tmp/rename_ddl_XXXXXX.sql)
        # --no-data        : 不导出行数据
        # --no-create-info : 跳过基础表的 CREATE TABLE（表将由 RENAME TABLE 迁移）
        # --routines       : 包含存储过程和函数
        # --events         : 包含事件
        # sed 替换库名显式引用，确保导入新库后引用正确
        docker exec "$MYSQL_CONTAINER_NAME" \
            mysqldump \
            -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
            -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
            --no-data \
            --no-create-info \
            --routines \
            --events \
            --set-gtid-purged=OFF \
            "${OLD_DB}" 2>/dev/null \
        | sed "s/\`${OLD_DB}\`/\`${NEW_DB}\`/g" \
        > "$TEMP_DDL"
        echo "   ✅ DDL 对象已预导出"
    else
        echo "▶  [1/4] 无 DDL 对象（视图/存储过程/函数/事件），跳过预导出"
    fi

    # 6.2 获取原库字符集，创建新库
    local _cs _cl
    _cs=$(_rdb_exec -e "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${OLD_DB}';")
    _cl=$(_rdb_exec -e "SELECT DEFAULT_COLLATION_NAME    FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${OLD_DB}';")
    _cs="${_cs:-utf8mb4}"; _cl="${_cl:-utf8mb4_unicode_ci}"

    if [ "$new_db_exists" = false ]; then
        echo "▶  [2/4] 创建新数据库 \`$NEW_DB\`（字符集: ${_cs} / ${_cl}）..."
        if ! _rdb_exec -e "CREATE DATABASE \`${NEW_DB}\` CHARACTER SET ${_cs} COLLATE ${_cl};"; then
            echo "❌ 创建新数据库失败，操作中止"
            rm -f "$TEMP_DDL"
            return 1
        fi
        echo "   ✅ 新数据库已创建"
    else
        echo "▶  [2/4] 目标数据库 \`$NEW_DB\` 已存在，跳过创建（覆盖模式）"
    fi

    # 6.3 逐表 RENAME（InnoDB：纯元数据操作；触发器随表自动迁移）
    echo "▶  [3/4] 逐表迁移 (${tbl_cnt:-0} 张)..."
    local _ok=0 _fail=0
    local _failed_tbls=()
    if [ "${tbl_cnt:-0}" -gt 0 ]; then
        local _tbl_list
        _tbl_list=$(_rdb_exec -e \
            "SELECT TABLE_NAME FROM information_schema.TABLES \
             WHERE TABLE_SCHEMA='${OLD_DB}' AND TABLE_TYPE='BASE TABLE' \
             ORDER BY TABLE_NAME;")
        while IFS= read -r _tbl; do
            [ -z "$_tbl" ] && continue
            # 覆盖模式：新库中存在同名表时先删除，再 RENAME
            if [ "$new_db_exists" = true ]; then
                _rdb_exec -e "DROP TABLE IF EXISTS \`${NEW_DB}\`.\`${_tbl}\`;" 2>/dev/null || true
            fi
            if _rdb_exec -e \
               "RENAME TABLE \`${OLD_DB}\`.\`${_tbl}\` TO \`${NEW_DB}\`.\`${_tbl}\`;"; then
                _ok=$(( _ok + 1 ))
                printf "\r   进度: %d/%d 张" "$_ok" "${tbl_cnt}"
            else
                _fail=$(( _fail + 1 ))
                _failed_tbls+=("$_tbl")
                printf "\r   ⚠️  \`%s\` 迁移失败（可能含跨库外键），继续...\n" "$_tbl"
            fi
        done <<< "$_tbl_list"
        echo ""
    fi

    if [ "$_fail" -gt 0 ]; then
        echo "   ⚠️  ${_fail} 张表迁移失败（跨库外键约束，需手动处理）："
        for _t in "${_failed_tbls[@]}"; do printf "      - \`%s\`\n" "$_t"; done
    else
        echo "   ✅ ${_ok} 张表全部迁移完成（触发器随表自动迁移）"
    fi

    # 6.4 导入 DDL 对象至新库
    if [ "$has_ddl" = true ] && [ -s "$TEMP_DDL" ]; then
        echo "▶  [4/4] 导入 DDL 对象至 \`$NEW_DB\`..."
        local _ddl_status=0
        docker exec -i "$MYSQL_CONTAINER_NAME" \
            mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
            -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
            "${NEW_DB}" < "$TEMP_DDL" 2>/dev/null || _ddl_status=$?
        rm -f "$TEMP_DDL"
        if [ "$_ddl_status" -eq 0 ]; then
            echo "   ✅ DDL 对象导入完成"
        else
            echo "   ⚠️  DDL 导入时遇到警告，部分对象可能需手动核查"
        fi
    else
        [ "$has_ddl" = true ] && rm -f "$TEMP_DDL"
        echo "▶  [4/4] 无 DDL 对象需导入，跳过"
    fi

    # ── 7. 验证对比 ──────────────────────────────────────────────────────
    local n_tbl n_view n_proc n_func n_evt
    n_tbl=$(_rdb_exec  -e "SELECT COUNT(*) FROM information_schema.TABLES   WHERE TABLE_SCHEMA='${NEW_DB}' AND TABLE_TYPE='BASE TABLE';")
    n_view=$(_rdb_exec -e "SELECT COUNT(*) FROM information_schema.VIEWS    WHERE TABLE_SCHEMA='${NEW_DB}';")
    n_proc=$(_rdb_exec -e "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='${NEW_DB}' AND ROUTINE_TYPE='PROCEDURE';")
    n_func=$(_rdb_exec -e "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='${NEW_DB}' AND ROUTINE_TYPE='FUNCTION';")
    n_evt=$(_rdb_exec  -e "SELECT COUNT(*) FROM information_schema.EVENTS   WHERE EVENT_SCHEMA='${NEW_DB}';")

    local _verify_ok=true
    { [ "${n_tbl:-0}"  -lt "${tbl_cnt:-0}"  ] || \
      [ "${n_view:-0}" -lt "${view_cnt:-0}" ] || \
      [ "${n_proc:-0}" -lt "${proc_cnt:-0}" ] || \
      [ "${n_func:-0}" -lt "${func_cnt:-0}" ] || \
      [ "${n_evt:-0}"  -lt "${evt_cnt:-0}"  ]; } && _verify_ok=false

    # 查询原库中存在但新库中缺失的具体表名
    local _missing_tbls=""
    if [ "${n_tbl:-0}" -lt "${tbl_cnt:-0}" ]; then
        _missing_tbls=$(_rdb_exec -e \
            "SELECT TABLE_NAME FROM information_schema.TABLES \
             WHERE TABLE_SCHEMA='${OLD_DB}' AND TABLE_TYPE='BASE TABLE' \
             AND TABLE_NAME NOT IN ( \
                 SELECT TABLE_NAME FROM information_schema.TABLES \
                 WHERE TABLE_SCHEMA='${NEW_DB}' AND TABLE_TYPE='BASE TABLE' \
             ) ORDER BY TABLE_NAME;" 2>/dev/null) || true
    fi

    local _elapsed=$(( $(date +%s) - _t0 ))
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "验证对比（原库 → 新库）："
    printf "  %-10s 原:%-4s → 新:%-4s %s\n" "基础表"  "${tbl_cnt:-0}"  "${n_tbl:-0}"  "$( [ "${n_tbl:-0}"  -ge "${tbl_cnt:-0}"  ] && echo ✅ || echo ⚠️  )"
    printf "  %-10s 原:%-4s → 新:%-4s %s\n" "视图"    "${view_cnt:-0}" "${n_view:-0}" "$( [ "${n_view:-0}" -ge "${view_cnt:-0}" ] && echo ✅ || echo ⚠️  )"
    printf "  %-10s 原:%-4s → 新:%-4s %s\n" "存储过程" "${proc_cnt:-0}" "${n_proc:-0}" "$( [ "${n_proc:-0}" -ge "${proc_cnt:-0}" ] && echo ✅ || echo ⚠️  )"
    printf "  %-10s 原:%-4s → 新:%-4s %s\n" "函数"    "${func_cnt:-0}" "${n_func:-0}" "$( [ "${n_func:-0}" -ge "${func_cnt:-0}" ] && echo ✅ || echo ⚠️  )"
    printf "  %-10s 原:%-4s → 新:%-4s %s\n" "事件"    "${evt_cnt:-0}"  "${n_evt:-0}"  "$( [ "${n_evt:-0}"  -ge "${evt_cnt:-0}"  ] && echo ✅ || echo ⚠️  )"
    if [ -n "$_missing_tbls" ]; then
        echo ""
        echo "  ⚠️  以下表在新库中缺失（共 $(( tbl_cnt - n_tbl )) 张）："
        while IFS= read -r _mt; do
            [ -n "$_mt" ] && printf "      - \`%s\`\n" "$_mt"
        done <<< "$_missing_tbls"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$_verify_ok" = true ]; then
        echo "✅ 验证通过！新库 \`${NEW_DB}\` 对象数量与原库 \`${OLD_DB}\` 完全一致，耗时: ${_elapsed} 秒"
    else
        echo "⚠️  部分对象数量不匹配（见上方 ⚠️），请手动核查后再决定是否删除原库"
    fi

    # ── 8. 确认是否删除原库 ──────────────────────────────────────────────
    echo ""
    local _remaining
    _remaining=$(_rdb_exec -e \
        "SELECT COUNT(*) FROM information_schema.TABLES \
         WHERE TABLE_SCHEMA='${OLD_DB}' AND TABLE_TYPE='BASE TABLE';")
    if [ "${_remaining:-0}" -gt 0 ]; then
        echo "⚠️  原库 \`$OLD_DB\` 仍有 ${_remaining} 张表未迁移，建议先手动处理再删除"
    fi

    if [ "$_verify_ok" = true ]; then
        echo "验证通过，可安全删除原数据库。"
    else
        echo "存在未完全迁移的对象，建议确认无误后再删除。"
    fi

    read -p "是否删除原数据库 \`$OLD_DB\`？(y/N): " _ans
    if [[ "$_ans" =~ ^[Yy]$ ]]; then
        if _rdb_exec -e "DROP DATABASE \`${OLD_DB}\`;"; then
            echo "✅ 原数据库 \`$OLD_DB\` 已删除"
        else
            echo "❌ 删除失败，请手动执行: DROP DATABASE \`${OLD_DB}\`;"
        fi
    else
        echo "ℹ️  原数据库 \`$OLD_DB\` 已保留"
        echo "   确认无误后可手动执行: DROP DATABASE \`${OLD_DB}\`;"
    fi
}

restore_all_dbs() {
   # 默认使用 BACKUP_PATH，如果路径不存在或为空，则允许用户手动指定
   if [ -z "$BACKUP_PATH" ] || [ ! -d "$BACKUP_PATH" ]; then
       echo "⚠️  默认备份路径不存在或为空: $BACKUP_PATH"
       read -p "请输入备份文件路径或目录: " BACKUP_FILE_PATH
   else
       # 检查默认路径下是否有备份文件
       BACKUP_FILES_COUNT=$(ls -1 "$BACKUP_PATH"/*.sql.gz 2>/dev/null | wc -l)
       if [ "$BACKUP_FILES_COUNT" -eq 0 ]; then
           echo "⚠️  默认备份路径下没有找到备份文件: $BACKUP_PATH"
           read -p "请输入备份文件路径或目录（直接回车使用默认路径）: " BACKUP_FILE_PATH
           # 如果用户没有输入，使用默认路径
           if [ -z "$BACKUP_FILE_PATH" ]; then
               BACKUP_FILE_PATH="$BACKUP_PATH"
           fi
       else
           # 默认路径存在且有备份文件，直接使用
           echo "✅ 使用默认备份路径: $BACKUP_PATH"
           BACKUP_FILE_PATH="$BACKUP_PATH"
       fi
   fi

   # 如果输入的是目录路径，列出可用的备份文件
   if [ -d "$BACKUP_FILE_PATH" ]; then
       # 查找所有 .sql.gz 备份文件，按修改时间倒序排列（最新的在前）
       BACKUP_FILES=($(ls -t "$BACKUP_FILE_PATH"/*.sql.gz 2>/dev/null))

       if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
           echo "❌ 目录中没有找到 .sql.gz 备份文件：$BACKUP_FILE_PATH"
           exit 1
       fi

       echo ""
       echo "找到以下备份文件（共 ${#BACKUP_FILES[@]} 个）："
       echo "----------------------------------------"
       for i in "${!BACKUP_FILES[@]}"; do
           filename=$(basename "${BACKUP_FILES[$i]}")
           filesize=$(ls -lh "${BACKUP_FILES[$i]}" | awk '{print $5}')
           filetime=$(stat -c "%y" "${BACKUP_FILES[$i]}" 2>/dev/null | cut -d'.' -f1 || stat -f "%Sm" "${BACKUP_FILES[$i]}" 2>/dev/null || echo "未知")
           echo "  $((i+1)). $filename"
           echo "      大小: $filesize | 修改时间: $filetime"
       done
       echo "----------------------------------------"
       echo ""
       echo "  all. 恢复所有备份文件（按顺序恢复）【直接回车默认选择 all】"
       echo "  提示: 可以输入多个编号，用逗号分隔，如: 1,3,5 或 1，3，5"
       echo "  提示: 输入 q 或 quit 退出"
       echo ""

       while true; do
           read -p "请选择要恢复的备份文件 [1-${#BACKUP_FILES[@]}/all/多选如1,3,5/q退出，回车默认all]: " FILE_CHOICE

           if [ -z "$FILE_CHOICE" ]; then
               FILE_CHOICE="all"
           fi

           if [[ "$FILE_CHOICE" =~ ^[Qq]([Uu][Ii][Tt])?$ ]]; then
               echo "操作已取消"
               exit 0
           fi

           if [[ "$FILE_CHOICE" =~ ^[Aa][Ll][Ll]$ ]]; then
               echo ""
               echo "✅ 已选择：恢复所有备份文件（共 ${#BACKUP_FILES[@]} 个）"
               FILES_TO_PROCESS=("${BACKUP_FILES[@]}")
               break
           elif [[ "$FILE_CHOICE" =~ , ]] || [[ "$FILE_CHOICE" =~ ， ]]; then
               FILE_CHOICE_CLEANED=$(echo "$FILE_CHOICE" | tr '，' ',' | tr -d ' ' | sed 's/,,*/,/g' | sed 's/^,//' | sed 's/,$//')

               if [ -z "$FILE_CHOICE_CLEANED" ]; then
                   echo "❌ 输入格式错误：未找到有效的文件编号！"
                   echo "   请重新输入，或输入 q 退出"
                   continue
               fi

               IFS=',' read -ra SELECTED_INDICES <<< "$FILE_CHOICE_CLEANED"

               SELECTED_FILES=()
               INVALID_INDICES=()

               for index in "${SELECTED_INDICES[@]}"; do
                   index=$(echo "$index" | xargs)
                   if [ -z "$index" ]; then
                       continue
                   fi
                   if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#BACKUP_FILES[@]} ]; then
                       SELECTED_FILES+=("${BACKUP_FILES[$((index-1))]}")
                   else
                       INVALID_INDICES+=("$index")
                   fi
               done

               if [ ${#INVALID_INDICES[@]} -gt 0 ]; then
                   echo "❌ 无效的文件编号: ${INVALID_INDICES[*]}"
                   echo "   有效范围: 1-${#BACKUP_FILES[@]}"
                   echo "   请重新输入，或输入 q 退出"
                   continue
               fi

               if [ ${#SELECTED_FILES[@]} -eq 0 ]; then
                   echo "❌ 未选择任何有效的文件！"
                   echo "   请重新输入，或输入 q 退出"
                   continue
               fi

               echo ""
               echo "✅ 已选择以下文件（共 ${#SELECTED_FILES[@]} 个）："
               for i in "${!SELECTED_FILES[@]}"; do
                   echo "  $((i+1)). $(basename "${SELECTED_FILES[$i]}")"
               done

               FILES_TO_PROCESS=("${SELECTED_FILES[@]}")
               break
           elif [[ "$FILE_CHOICE" =~ ^[0-9]+$ ]] && [ "$FILE_CHOICE" -ge 1 ] && [ "$FILE_CHOICE" -le ${#BACKUP_FILES[@]} ]; then
               BACKUP_FILE_PATH="${BACKUP_FILES[$((FILE_CHOICE-1))]}"
               echo ""
               echo "✅ 已选择：$BACKUP_FILE_PATH"
               break
           else
               echo "❌ 无效选择！"
               echo "   有效选项: 1-${#BACKUP_FILES[@]}, all, 多选如1,3,5, 或 q 退出"
               echo "   请重新输入"
               continue
           fi
       done
   fi

   if [ ${#FILES_TO_PROCESS[@]} -gt 0 ]; then
       local total=${#FILES_TO_PROCESS[@]}
       local plan_target_dbs=()
       local plan_rename_froms=()

       echo ""
       echo "请逐个确认目标数据库名："
       for backup_file in "${FILES_TO_PROCESS[@]}"; do
           local detected_db TARGET_DB
           detected_db=$(extract_db_name_from_file "$backup_file")

           echo ""
           echo "文件: $(basename "$backup_file")"
           if [ -n "$detected_db" ]; then
               read -e -i "$detected_db" -p "  目标数据库名: " TARGET_DB
               [ -z "$TARGET_DB" ] && TARGET_DB="$detected_db"
           else
               echo "  ⚠️  未能从文件头部检测到数据库名"
               while true; do
                   read -p "  请手动输入目标数据库名: " TARGET_DB
                   TARGET_DB="${TARGET_DB// /}"
                   [ -n "$TARGET_DB" ] && break
                   echo "  ❌ 数据库名不能为空"
               done
           fi

           local RENAME_FROM=""
           if [ -n "$detected_db" ] && [ "$TARGET_DB" != "$detected_db" ]; then
               RENAME_FROM="$detected_db"
           fi

           plan_target_dbs+=("$TARGET_DB")
           plan_rename_froms+=("$RENAME_FROM")
       done

       echo ""
       echo "════════════════════════════════════════════════════════"
       echo "  恢复计划汇总（共 $total 个文件）"
       echo "════════════════════════════════════════════════════════"
       for i in "${!FILES_TO_PROCESS[@]}"; do
           if [ -n "${plan_rename_froms[$i]}" ]; then
               printf "  %2d. %-45s →    \`%s\` 重命名为 \`%s\`\n" \
                   "$((i+1))" \
                   "$(basename "${FILES_TO_PROCESS[$i]}")" \
                   "${plan_rename_froms[$i]}" \
                   "${plan_target_dbs[$i]}"
           else
               printf "  %2d. %-45s → \`%s\`\n" \
                   "$((i+1))" \
                   "$(basename "${FILES_TO_PROCESS[$i]}")" \
                   "${plan_target_dbs[$i]}"
           fi
       done
       echo "════════════════════════════════════════════════════════"
       echo ""

       read -p "确认开始恢复以上所有数据库？[y/N]: " FINAL_CONFIRM
       if [[ ! "$FINAL_CONFIRM" =~ ^[Yy]$ ]]; then
           echo "已取消恢复操作"
           return 0
       fi

       echo ""
       echo "开始批量恢复..."
       local success_count=0
       local failed_count=0

       set +e

       for i in "${!FILES_TO_PROCESS[@]}"; do
           local backup_file="${FILES_TO_PROCESS[$i]}"
           local target_db="${plan_target_dbs[$i]}"
           local rename_from="${plan_rename_froms[$i]}"

           echo ""
           echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
           printf "  [%d/%d] 恢复 \`%s\`\n" "$((i+1))" "$total" "$target_db"
           if [ -n "$rename_from" ]; then
               echo "  库名映射: \`$rename_from\` → \`$target_db\`"
           fi
           echo "  文件: $(basename "$backup_file")"
           echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

           if restore_with_auto_db "$backup_file" "$target_db" "$rename_from"; then
               echo "✅ \`$target_db\` 恢复成功（文件: $(basename "$backup_file")）"
               ((success_count++))
           else
               echo "❌ \`$target_db\` 恢复失败（文件: $(basename "$backup_file")）"
               ((failed_count++))
           fi
       done

       set -e

       echo ""
       echo "════════════════════════════════════════════════════════"
       echo "🎉 批量恢复完成！成功: $success_count 个 | 失败: $failed_count 个"
       echo "════════════════════════════════════════════════════════"
       return 0
   fi

   if [ ! -f "$BACKUP_FILE_PATH" ]; then
       echo "❌ 备份文件不存在：$BACKUP_FILE_PATH"
       exit 1
   fi

   echo ""
   echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
   echo "正在恢复数据库"
   echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
   if restore_with_auto_db "$BACKUP_FILE_PATH"; then
       echo "✅ 所有数据库从文件 $BACKUP_FILE_PATH 恢复完成。"
   else
       echo "❌ 数据库恢复失败！"
       exit 1
   fi
}

delete_all_dbs() {
    echo "⚠️  警告：此操作将删除所有非系统数据库！"
    echo "系统数据库（mysql, information_schema, performance_schema, sys）将被保留。"
    echo ""

    # 获取所有非系统数据库列表
    echo "正在获取数据库列表..."
    DBS_RAW=$(docker exec $MYSQL_CONTAINER_NAME \
    mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "(Database|sys|information_schema|performance_schema|mysql)")

    if [ -z "$DBS_RAW" ]; then
        echo "ℹ️  未找到任何非系统数据库，无需删除。"
        return 0
    fi

    # 将数据库列表转换为数组
    DBS_ARRAY=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            DBS_ARRAY+=("$line")
        fi
    done <<< "$DBS_RAW"

    echo "找到以下非系统数据库："
    for db in "${DBS_ARRAY[@]}"; do
        echo "  - $db"
    done
    echo ""

    # 确认删除
    read -p "确认要删除这些数据库吗？(输入 YES/yes/y/Y 确认): " CONFIRM

    # 支持多种确认方式
    case "$CONFIRM" in
        YES|yes|y|Y)
            echo "✅ 确认删除操作"
            ;;
        *)
            echo "❌ 操作已取消。"
            return 0
            ;;
    esac

    echo "开始删除数据库..."
    local deleted_count=0
    local failed_count=0

    # 临时禁用 set -e 来防止脚本在删除过程中退出
    set +e

    # 删除每个数据库
    for db in "${DBS_ARRAY[@]}"; do
        echo "正在删除数据库: $db ..."
        docker exec $MYSQL_CONTAINER_NAME \
        mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD -e "DROP DATABASE IF EXISTS \`$db\`;" 2>/dev/null

        if [ $? -eq 0 ]; then
            echo "✅ 数据库 $db 删除成功"
            ((deleted_count++))
        else
            echo "❌ 数据库 $db 删除失败"
            ((failed_count++))
        fi
    done

    # 重新启用 set -e
    set -e

    echo ""
    echo "🎉 删除操作完成！"
    echo "成功删除: $deleted_count 个数据库"
    if [ $failed_count -gt 0 ]; then
        echo "删除失败: $failed_count 个数据库"
    fi

    # 显示剩余数据库
    echo ""
    echo "当前剩余数据库："
    docker exec $MYSQL_CONTAINER_NAME \
    mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD -e "SHOW DATABASES;" 2>/dev/null | grep -v "Database"

    # 优化MySQL表空间
    echo ""
    echo "正在优化MySQL表空间..."
    docker exec $MYSQL_CONTAINER_NAME \
    mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD -e "FLUSH TABLES;" 2>/dev/null

    echo "✅ 数据库空间清理完成！"
}

complete_cleanup_restore() {
    echo "🔄 完整数据库清理和恢复流程"
    echo "================================"
    echo ""

    # 步骤1：备份所有数据库
    echo "📦 步骤1：备份所有数据库"
    echo "------------------------"
    if ! backup_all_dbs; then
        echo "❌ 备份失败，停止流程"
        return 1
    fi
    echo ""

    # 步骤2：删除所有非系统数据库
    echo "🗑️  步骤2：删除所有非系统数据库"
    echo "--------------------------------"
    delete_all_dbs
    echo ""

    # 步骤3：显示恢复选项
    echo "🔄 步骤3：恢复数据库"
    echo "--------------------"
    echo "请选择恢复方式："
    echo "1. 恢复所有数据库（从最新的备份文件）"
    echo "2. 手动选择恢复文件"
    echo "3. 跳过恢复"
    read -p "输入选择 [1-3]: " RESTORE_CHOICE

    case $RESTORE_CHOICE in
        1)
            # 自动找到最新的备份文件
            LATEST_BACKUP=$(ls -t "$BACKUP_PATH"*_backup_*.sql.gz 2>/dev/null | head -1)
            if [ -n "$LATEST_BACKUP" ]; then
                echo "找到最新备份文件: $LATEST_BACKUP"
                echo "正在恢复所有数据库..."
                gunzip < "$LATEST_BACKUP" | docker exec -i $MYSQL_CONTAINER_NAME \
                mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD 2>/dev/null

                if [ $? -eq 0 ]; then
                    echo "✅ 所有数据库恢复完成！"
                else
                    echo "❌ 数据库恢复失败！"
                fi
            else
                echo "❌ 未找到备份文件！"
            fi
            ;;
        2)
            read -p "输入备份文件路径: " BACKUP_FILE_PATH
            if [ -f "$BACKUP_FILE_PATH" ]; then
                echo "正在恢复所有数据库..."
                gunzip < "$BACKUP_FILE_PATH" | \
                sed -e '/^SET @@GLOBAL.GTID_PURGED=/d' -e '/^SET @@SESSION.SQL_LOG_BIN=/d' | \
                docker exec -i $MYSQL_CONTAINER_NAME \
                mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD 2>/dev/null

                if [ $? -eq 0 ]; then
                    echo "✅ 所有数据库恢复完成！"
                else
                    echo "❌ 数据库恢复失败！"
                fi
            else
                echo "❌ 备份文件不存在：$BACKUP_FILE_PATH"
            fi
            ;;
        3)
            echo "ℹ️  跳过恢复步骤"
            ;;
        *)
            echo "❌ 无效选择，跳过恢复步骤"
            ;;
    esac

    echo ""
    echo "🎯 完整流程结束！"
    echo "================================"
    echo "✅ 已备份所有数据库到: $BACKUP_PATH"
    echo "✅ 已删除所有非系统数据库"
    echo "✅ 已优化数据库空间"
    if [ "$RESTORE_CHOICE" = "1" ] || [ "$RESTORE_CHOICE" = "2" ]; then
        echo "✅ 已恢复数据库"
    fi
}

# 根据用户选择执行相应操作
case $OPERATION in
   1) backup_single_db ;;
   2) backup_all_dbs ;;
   3) restore_single_db ;;
   4) restore_all_dbs ;;
   5) rename_database ;;
   6) delete_all_dbs ;;
   7) complete_cleanup_restore ;;
   *) echo "无效的选择！请输入1-7之间的数字"; exit 1 ;;
esac
