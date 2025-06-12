#!/bin/bash

# 设置 MySQL 容器名称、用户名和密码
MYSQL_CONTAINER_NAME='mysql'

MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"
MYSQL_CHARSET="utf8mb4"
MYSQL_USER='root'
MYSQL_PASSWORD='bxiI2b8ZLYbaAdQBRT'

# 设置备份存放路径
BACKUP_PATH='/srv/backup/'

# 显示选择菜单
echo "请选择操作："
echo "1. 备份单个数据库"
echo "2. 备份所有数据库(排除mysql自带库)"
echo "3. 恢复指定数据库"
echo "4. 恢复全部数据库"
read -p "输入选择 [1-5]: " OPERATION

# 功能实现的函数
backup_single_db() {
   read -p "输入要备份的数据库名: " DB_NAME
   docker exec $MYSQL_CONTAINER_NAME \
   mysqldump -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD --default-character-set $MYSQL_CHARSET --single-transaction --source-data=2 --flush-logs --hex-blob --triggers --routines --events --databases $DB_NAME | gzip> $BACKUP_PATH${DB_NAME}_backup_`date "+%Y%m%d_%H%M%S"`.sql.gz

   echo "数据库 $DB_NAME 备份完成，文件路径：$BACKUP_PATH${DB_NAME}_backup.sql.gz"
}

backup_all_dbs() {
    # 获取所有非系统数据库列表
    DBS=$(docker exec $MYSQL_CONTAINER_NAME \
    mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD -e "SHOW DATABASES;" | grep -Ev "(Database|sys|information_schema|performance_schema|mysql)")

    # 为每个数据库创建备份
    for db in $DBS; do
        docker exec $MYSQL_CONTAINER_NAME \
        mysqldump -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD --default-character-set=utf8mb4 --single-transaction --source-data=2 --flush-logs --hex-blob --triggers --routines --events --databases ${db} |  gzip > $BACKUP_PATH${db}_backup_`date "+%Y%m%d_%H%M%S"`.sql.gz

        echo "数据库 $db 已备份到 $BACKUP_PATH${db}_backup.sql.gz"
    done
}


restore_single_db() {
   read -p "输入要恢复的数据库名: " DB_NAME
   read -p "输入备份文件路径: " BACKUP_FILE_PATH

   # 检查数据库是否存在，如果不存在则创建
   DB_EXISTS=$(docker exec $MYSQL_CONTAINER_NAME \
   mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD -e "SHOW DATABASES LIKE '$DB_NAME';" | grep "$DB_NAME")

   if [ -z "$DB_EXISTS" ]; then
       echo "数据库 $DB_NAME 不存在，正在创建..."
       docker exec $MYSQL_CONTAINER_NAME \
       mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD -e "CREATE DATABASE $DB_NAME;"
       echo "数据库 $DB_NAME 已创建。"
   fi

   # 恢复数据库
   gunzip < $BACKUP_FILE_PATH | docker exec -i $MYSQL_CONTAINER_NAME \
   mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD $DB_NAME
   echo "数据库 $DB_NAME 从文件 $BACKUP_FILE_PATH 恢复完成。"
}

restore_all_dbs() {
   read -p "输入备份文件路径: " BACKUP_FILE_PATH
   gunzip < $BACKUP_FILE_PATH | docker exec -i $MYSQL_CONTAINER_NAME \
   mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD
   echo "所有数据库从文件 $BACKUP_FILE_PATH 恢复完成。"
}

# 根据用户选择执行相应操作
case $OPERATION in
   1) backup_single_db ;;
   2) backup_all_dbs ;;
   3) restore_single_db ;;
   4) restore_all_dbs ;;
   *) echo "无效的选择！"; exit 1 ;;
esac