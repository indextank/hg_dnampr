#!/bin/bash

# 容器名称  容器ID，容器名称都行，建议使用id，不会被更改
container_name="mysql"
# 数据库账户
mysql_name="root"
# 数据库密码
mysql_pwd="EgWlTOXrqBxw6H1"
# 数据库备份根目录
backup_dir="/srv/backup_sql/"
bakup_log="/srv/backup_sql"
# 备份数据库
DATABASES=$(/usr/bin/docker exec -i ${container_name} mysql -u${mysql_name} -p${mysql_pwd} -e "show databases" | grep -Ev "Database|sys|information_schema|performance_schema|mysql")
# 备份数据保留天数
backup_clean_day=5

# 如果文件夹不存在则创建
if [ ! -d $backup_dir ]; then
        sudo mkdir -p $backup_dir
        sudo chown -R $(whoami):$(whoami) $backup_dir
fi

# 循环数据库进行备份
for db in  $DATABASES
do
        echo
        echo ----------$BACKUP_FILEDIR/${db}_`date "+%Y%m%d_%H%M%S"`.sql.gz BEGIN----------

        /usr/bin/docker exec -i ${container_name}  mysqldump -u${mysql_name} -p${mysql_pwd} --default-character-set=utf8mb4 --single-transaction --source-data=2 --flush-logs --hex-blob --triggers --routines --events --databases ${db} |  gzip > ${backup_dir}/${db}_`date "+%Y%m%d_%H%M%S"`.sql.gz

        #写创建备份日志
        echo "create $bakup_log/${db}-`date "+%Y%m%d_%H%M%S"`.dupm" >> $bakup_log/log.txt
        echo ----------$BACKUP_FILEDIR/${db}_`date "+%Y%m%d_%H%M%S"`.sql.gz COMPLETE----------
        echo
done
echo "done"

#删除5天之前的备份
find ${backup_dir} -type f -mtime +${backup_clean_day} -delete
