#!/bin/bash
# 设置mysql的登录用户名和密码(根据实际情况填写)
mysql_user="root"
mysql_password="bxiI2b8ZLYbaAdQBRT"
mysql_host="mysql"
mysql_port="3306"
mysql_charset="utf8mb4"
mysql_database="wklan"
mysql_docker_name="mysql"

# export MYSQL_PWD=${mysql_password}

# 备份文件存放地址(根据实际情况填写)
backup_location=/srv/backup

#如果文件夹不存在，创建文件夹
if [ ! -d $backup_location ]; then
  mkdir $backup_location
fi


# 是否删除过期数据
expire_backup_delete="ON"
expire_days=5
backup_time=`date +%Y%m%d%H%M%S`
backup_dir=$backup_location
backup_file_name=$mysql_database"_"$backup_time".sql"
backup_file_name_zip=$mysql_database"_"$backup_time".sql.gz"
welcome_msg="Welcome to use MySQL backup tools!"

# 备份单个指定数据库
docker exec -i $mysql_docker_name mysqldump -h$mysql_host -P$mysql_port -u$mysql_user -p$mysql_password --default-character-set $mysql_charset --single-transaction --source-data=2 --flush-logs --hex-blob --triggers --routines --events --databases $mysql_database  | gzip> $backup_dir/$backup_file_name_zip

# 备份整个数据库
DATABASES=$(/usr/bin/docker exec -i $mysql_docker_name mysql -h$mysql_host -u$mysql_user -p$mysql_password -e "show databases" | grep -Ev "Database|sys|information_schema|performance_schema|mysql")
echo '-----------------'
echo $DATABASES

for db in  $DATABASES
do
        echo
        echo ----------$BACKUP_FILEDIR/${db}_`date "+%Y%m%d_%H%M%S"`.sql.gz BEGIN----------

        /usr/bin/docker exec -i $mysql_docker_name  mysqldump -h$mysql_host -u$mysql_user -p$mysql_password --default-character-set=utf8mb4 --single-transaction --source-data=2 --flush-logs --hex-blob --triggers --routines --events --databases ${db} |  gzip > ${backup_dir}/${db}_`date "+%Y%m%d_%H%M%S"`.sql.gz

        #写创建备份日志
        echo "create $bakup_log/${db}-`date "+%Y%m%d_%H%M%S"`.dupm" >> $bakup_log/log.txt
        echo ----------$BACKUP_FILEDIR/${db}_`date "+%Y%m%d_%H%M%S"`.sql.gz COMPLETE----------
        echo
done

# 删除过期数据
if [ "$expire_backup_delete" == "ON" -a  "$backup_location" != "" ];then
        `find $backup_location/ -type f -mtime +$expire_days | xargs rm -rf`
        echo "Expired backup data delete complete!"
fi
