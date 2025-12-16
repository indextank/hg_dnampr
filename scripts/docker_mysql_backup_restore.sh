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
MYSQL_PASSWORD='bxiI2b8ZLYbaAdQBRT'

# 设置备份存放路径
BACKUP_PATH='/srv/backup/'

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
restore_file_with_progress() {
    local backup_file="$1"
    local db_name="${2:-}"
    
    # 获取文件大小
    local file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
    
    if [ "$file_size" = "0" ]; then
        echo "⚠️  无法获取文件大小，使用普通模式恢复"
        # 创建临时文件用于捕获错误
        local error_file="/tmp/mysql_restore_error_$$.txt"
        local restore_status=0
        
        if [ -n "$db_name" ]; then
            gunzip < "$backup_file" 2>&1 | \
            sed -e '/^SET @@GLOBAL.GTID_PURGED=/d' -e '/^SET @@SESSION.SQL_LOG_BIN=/d' | \
            docker exec -i $MYSQL_CONTAINER_NAME \
            mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD $db_name 2>"$error_file" || restore_status=$?
        else
            gunzip < "$backup_file" 2>&1 | \
            sed -e '/^SET @@GLOBAL.GTID_PURGED=/d' -e '/^SET @@SESSION.SQL_LOG_BIN=/d' | \
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
        echo "正在恢复（显示详细进度）..."
        # 创建临时文件用于捕获错误
        local error_file="/tmp/mysql_restore_error_$$.txt"
        local restore_status=0
        
        if [ -n "$db_name" ]; then
            # pv 的进度输出到 stderr（终端），数据输出到 stdout
            pv -p -t -e -r -b -s "$file_size" "$backup_file" 2>&2 | gunzip 2>/dev/null | \
            sed -e '/^SET @@GLOBAL.GTID_PURGED=/d' -e '/^SET @@SESSION.SQL_LOG_BIN=/d' | \
            docker exec -i $MYSQL_CONTAINER_NAME \
            mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD $db_name 2>"$error_file" || restore_status=$?
        else
            # pv 的进度输出到 stderr（终端），数据输出到 stdout
            pv -p -t -e -r -b -s "$file_size" "$backup_file" 2>&2 | gunzip 2>/dev/null | \
            sed -e '/^SET @@GLOBAL.GTID_PURGED=/d' -e '/^SET @@SESSION.SQL_LOG_BIN=/d' | \
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
        
        # 启动恢复进程，使用 dd 的 status=progress 选项来监控进度
        if [ -n "$db_name" ]; then
            (
                # 使用 dd 读取文件，每 1MB 输出一次进度
                dd if="$backup_file" bs=1M status=progress 2>"$progress_file" | gunzip 2>&1 | docker exec -i $MYSQL_CONTAINER_NAME \
                mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD $db_name 2>"$error_file"
            ) &
            local restore_pid=$!
        else
            (
                dd if="$backup_file" bs=1M status=progress 2>"$progress_file" | gunzip 2>&1 | docker exec -i $MYSQL_CONTAINER_NAME \
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

# 显示选择菜单
echo "请选择操作："
echo "1. 备份单个数据库"
echo "2. 备份所有数据库(排除mysql自带库)"
echo "3. 恢复全部数据库"
echo "4. 删除所有非系统数据库"
echo "5. 完整清理流程(备份→删除→恢复)"
read -p "输入选择 [1-5]: " OPERATION

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
           # 获取文件名（不含路径）
           filename=$(basename "${BACKUP_FILES[$i]}")
           # 获取文件大小
           filesize=$(ls -lh "${BACKUP_FILES[$i]}" | awk '{print $5}')
           # 获取文件修改时间
           filetime=$(stat -c "%y" "${BACKUP_FILES[$i]}" 2>/dev/null | cut -d'.' -f1 || stat -f "%Sm" "${BACKUP_FILES[$i]}" 2>/dev/null || echo "未知")
           echo "  $((i+1)). $filename"
           echo "      大小: $filesize | 修改时间: $filetime"
       done
       echo "----------------------------------------"
       echo ""
       echo "  all. 恢复所有备份文件（按顺序恢复）"
       echo "  提示: 可以输入多个编号，用逗号分隔，如: 1,3,5 或 1，3，5"
       echo "  提示: 输入 q 或 quit 退出"
       echo ""
       
       # 循环输入，直到用户输入有效选择或退出
       while true; do
           read -p "请选择要恢复的备份文件 [1-${#BACKUP_FILES[@]}/all/多选如1,3,5/q退出]: " FILE_CHOICE
           
           # 处理退出选项
           if [[ "$FILE_CHOICE" =~ ^[Qq]([Uu][Ii][Tt])?$ ]]; then
               echo "操作已取消"
               exit 0
           fi
           
           # 处理 "all" 选项
           if [[ "$FILE_CHOICE" =~ ^[Aa][Ll][Ll]$ ]]; then
               echo ""
               echo "✅ 已选择：恢复所有备份文件（共 ${#BACKUP_FILES[@]} 个）"
               # 设置特殊标记，表示恢复所有文件
               BACKUP_FILE_PATH="ALL_FILES"
               break
           # 处理多个文件选择（支持英文逗号和中文逗号）
           elif [[ "$FILE_CHOICE" =~ , ]] || [[ "$FILE_CHOICE" =~ ， ]]; then
               # 将中文逗号替换为英文逗号，去除所有空格，处理连续逗号
               FILE_CHOICE_CLEANED=$(echo "$FILE_CHOICE" | tr '，' ',' | tr -d ' ' | sed 's/,,*/,/g' | sed 's/^,//' | sed 's/,$//')
               
               # 如果处理后为空，提示错误并重新输入
               if [ -z "$FILE_CHOICE_CLEANED" ]; then
                   echo "❌ 输入格式错误：未找到有效的文件编号！"
                   echo "   请重新输入，或输入 q 退出"
                   continue
               fi
               
               # 分割字符串为数组
               IFS=',' read -ra SELECTED_INDICES <<< "$FILE_CHOICE_CLEANED"
               
               # 验证每个编号是否有效
               SELECTED_FILES=()
               INVALID_INDICES=()
               
               for index in "${SELECTED_INDICES[@]}"; do
                   # 去除前后空格（虽然已经去除了，但为了安全再处理一次）
                   index=$(echo "$index" | xargs)
                   # 跳过空字符串
                   if [ -z "$index" ]; then
                       continue
                   fi
                   # 验证是否为有效数字且在范围内
                   if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#BACKUP_FILES[@]} ]; then
                       SELECTED_FILES+=("${BACKUP_FILES[$((index-1))]}")
                   else
                       INVALID_INDICES+=("$index")
                   fi
               done
               
               # 如果有无效编号，提示错误并重新输入
               if [ ${#INVALID_INDICES[@]} -gt 0 ]; then
                   echo "❌ 无效的文件编号: ${INVALID_INDICES[*]}"
                   echo "   有效范围: 1-${#BACKUP_FILES[@]}"
                   echo "   请重新输入，或输入 q 退出"
                   continue
               fi
               
               # 如果未选择任何有效文件，提示错误并重新输入
               if [ ${#SELECTED_FILES[@]} -eq 0 ]; then
                   echo "❌ 未选择任何有效的文件！"
                   echo "   请重新输入，或输入 q 退出"
                   continue
               fi
               
               echo ""
               echo "✅ 已选择以下文件（共 ${#SELECTED_FILES[@]} 个）："
               for i in "${!SELECTED_FILES[@]}"; do
                   echo "  $((i+1)). ${SELECTED_FILES[$i]}"
               done
               
               # 设置特殊标记，表示恢复多个选中的文件
               BACKUP_FILE_PATH="MULTIPLE_FILES"
               # 将选中的文件数组保存到全局变量
               MULTIPLE_BACKUP_FILES=("${SELECTED_FILES[@]}")
               break
           # 处理单个文件选择
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
   
   # 处理恢复所有文件的情况
   if [ "$BACKUP_FILE_PATH" = "ALL_FILES" ]; then
       echo "正在恢复所有备份文件..."
       local success_count=0
       local failed_count=0
       
       # 临时禁用 set -e 来防止脚本在恢复过程中退出
       set +e
       
       for backup_file in "${BACKUP_FILES[@]}"; do
           echo ""
           echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
           echo "正在恢复文件: $(basename "$backup_file")"
           echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
           if restore_file_with_progress "$backup_file"; then
               echo "✅ 文件 $backup_file 恢复成功"
               ((success_count++))
           else
               echo "❌ 文件 $backup_file 恢复失败"
               ((failed_count++))
           fi
       done
       
       # 重新启用 set -e
       set -e
       
       echo ""
       echo "🎉 批量恢复完成！"
       echo "成功恢复: $success_count 个文件"
       if [ $failed_count -gt 0 ]; then
           echo "恢复失败: $failed_count 个文件"
       fi
       return 0
   fi
   
   # 处理恢复多个选中文件的情况
   if [ "$BACKUP_FILE_PATH" = "MULTIPLE_FILES" ]; then
       echo ""
       echo "正在恢复选中的备份文件..."
       local success_count=0
       local failed_count=0
       
       # 临时禁用 set -e 来防止脚本在恢复过程中退出
       set +e
       
       for backup_file in "${MULTIPLE_BACKUP_FILES[@]}"; do
           echo ""
           echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
           echo "正在恢复文件: $(basename "$backup_file")"
           echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
           if restore_file_with_progress "$backup_file"; then
               echo "✅ 文件 $backup_file 恢复成功"
               ((success_count++))
           else
               echo "❌ 文件 $backup_file 恢复失败"
               ((failed_count++))
           fi
       done
       
       # 重新启用 set -e
       set -e
       
       echo ""
       echo "🎉 批量恢复完成！"
       echo "成功恢复: $success_count 个文件"
       if [ $failed_count -gt 0 ]; then
           echo "恢复失败: $failed_count 个文件"
       fi
       return 0
   fi
   
   # 检查备份文件是否存在
   if [ ! -f "$BACKUP_FILE_PATH" ]; then
       echo "❌ 备份文件不存在：$BACKUP_FILE_PATH"
       exit 1
   fi

   echo ""
   echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
   echo "正在恢复数据库"
   echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
   # 恢复所有数据库（带进度显示）
   if restore_file_with_progress "$BACKUP_FILE_PATH"; then
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
   3) restore_all_dbs ;;
   4) delete_all_dbs ;;
   5) complete_cleanup_restore ;;
   *) echo "无效的选择！请输入1-5之间的数字"; exit 1 ;;
esac