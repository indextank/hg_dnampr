#!/bin/bash
set -e

# 只在数据库初始化时执行
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
  echo "MYSQL_ROOT_PASSWORD not set, skipping user creation."
  exit 0
fi

mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<-EOSQL
CREATE USER IF NOT EXISTS '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';
GRANT Alter, Alter Routine, Create, Create View, Delete, Drop, Event, Execute, File, Index, Insert, Lock Tables, Reload, Select, Show Databases, Show View, Super, Trigger, Update ON *.* TO '$MYSQL_USER'@'%';
FLUSH PRIVILEGES;
EOSQL