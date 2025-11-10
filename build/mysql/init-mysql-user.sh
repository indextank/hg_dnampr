#!/bin/bash
set -e

echo "=== MySQL Dev User Initialization Script Started ==="
echo "Current time: $(date)"
echo "MYSQL_USER: ${MYSQL_USER:-<not set>}"
echo "MYSQL_DATABASE: ${MYSQL_DATABASE:-<not set>}"
echo "MySQL Version: $(mysql --version 2>/dev/null || echo 'Version check failed')"

# 检查必要的环境变量
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
  echo "❌ ERROR: MYSQL_ROOT_PASSWORD not set, skipping user creation."
  exit 1
fi

if [ -z "$MYSQL_USER" ]; then
  echo "❌ ERROR: MYSQL_USER not set, skipping user creation."
  exit 1
fi

if [ -z "$MYSQL_PASSWORD" ]; then
  echo "❌ ERROR: MYSQL_PASSWORD not set, skipping user creation."
  exit 1
fi

echo "Creating user: $MYSQL_USER"

# 等待 MySQL 服务完全启动
echo "Waiting for MySQL to be ready..."
for i in {1..60}; do
    if mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
        echo "MySQL is ready!"
        break
    fi
    echo "Waiting... ($i/60)"
    sleep 2
done

# 验证连接
if ! mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
    echo "❌ ERROR: Cannot connect to MySQL with root password"
    exit 1
fi

echo "✅ Connected to MySQL successfully"

# 创建开发用户
echo "Creating dev user and setting permissions..."

# 使用printf安全地处理包含特殊字符的密码
# 创建临时SQL文件以避免shell变量替换问题
TEMP_SQL=$(mktemp)

# 写入SQL命令到临时文件，使用printf确保特殊字符正确处理
printf '%s\n' \
    "-- 确保禁用SSL传输要求 (开发环境)" \
    "SET GLOBAL require_secure_transport = OFF;" \
    "SET PERSIST require_secure_transport = OFF;" \
    "" \
    "-- 创建开发用户 (mysql_native_password 兼容)" > "$TEMP_SQL"

# 使用printf安全地添加包含密码的CREATE USER语句
# 先删除可能存在的用户，然后重新创建以确保密码正确
printf "DROP USER IF EXISTS '%s'@'%%';\n" "$MYSQL_USER" >> "$TEMP_SQL"
printf "DROP USER IF EXISTS '%s'@'localhost';\n" "$MYSQL_USER" >> "$TEMP_SQL"
printf "CREATE USER '%s'@'%%' IDENTIFIED WITH mysql_native_password BY '%s';\n" "$MYSQL_USER" "$MYSQL_PASSWORD" >> "$TEMP_SQL"
printf "CREATE USER '%s'@'localhost' IDENTIFIED WITH mysql_native_password BY '%s';\n" "$MYSQL_USER" "$MYSQL_PASSWORD" >> "$TEMP_SQL"

# 执行SQL文件
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "$TEMP_SQL"

# 继续执行权限设置 - 使用临时SQL文件避免变量替换问题
TEMP_GRANT_SQL=$(mktemp)
# 设置清理trap，确保临时文件被删除
trap "rm -f $TEMP_SQL $TEMP_GRANT_SQL" EXIT

# 写入权限设置SQL到临时文件
printf '%s\n' \
    "-- 授权开发用户（限制敏感权限）" \
    "-- 授予基本数据库操作权限，但排除敏感的系统权限" > "$TEMP_GRANT_SQL"

# 使用printf安全地添加包含用户名的GRANT语句
printf "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, EVENT, TRIGGER ON *.* TO '%s'@'%%';\n" "$MYSQL_USER" >> "$TEMP_GRANT_SQL"
printf "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, EVENT, TRIGGER ON *.* TO '%s'@'localhost';\n" "$MYSQL_USER" >> "$TEMP_GRANT_SQL"
printf "FLUSH PRIVILEGES;\n" >> "$TEMP_GRANT_SQL"

# 执行权限设置SQL文件
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "$TEMP_GRANT_SQL"

# Check if SQL execution was successful
if [ $? -eq 0 ]; then
    echo "✅ MySQL dev user initialization completed successfully"
    
    # 验证dev用户连接
    echo "Testing dev user connection..."
    if mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1 as test_connection;" >/dev/null 2>&1; then
        echo "✅ Dev user connection test successful"
    else
        echo "❌ Dev user connection test failed"
        echo "Debugging: Checking user existence..."
        mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT User, Host, plugin, authentication_string FROM mysql.user WHERE User='$MYSQL_USER';"
        exit 1
    fi
else
    echo "❌ MySQL dev user initialization failed"
    exit 1
fi

echo "=== MySQL Dev User Initialization Script Completed ==="