# HG_DNMPR - Docker 一键部署套件

[![Docker](https://img.shields.io/badge/Docker-Required-blue.svg)](https://www.docker.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![PHP](https://img.shields.io/badge/PHP-7.2--8.5-purple.svg)](https://www.php.net/)
[![MySQL](https://img.shields.io/badge/MySQL-8.0-orange.svg)](https://www.mysql.com/)

一款全功能的Docker一键部署套件，支持Nginx + Apache + PHP + MySQL + MongoDB + Redis + ELK等，满足日常开发及生产环境使用。

## 📑 目录

- [项目特点](#-项目特点)
- [支持的服务](#-支持的服务)
- [架构设计](#️-架构设计)
- [详细配置](#️-详细配置)
- [高级配置](#-高级配置)
- [数据保护指南](#-数据保护指南)
- [监控和日志](#-监控和日志)
- [部署指南](#-部署指南)
- [故障排除](#-故障排除)
- [开发指南](#-开发指南)
- [贡献指南](#-贡献指南)
- [许可证](#-许可证)

---

## 🌟 项目特点

- **🚀 一键部署** - 支持一键构建和启动所有服务
- **🔧 多版本支持** - PHP 7.2-8.5、MySQL 8.0、Redis 7.0等
- **📦 分层配置** - 采用分层配置文件管理，便于维护
- **🌍 环境自适应** - 智能代理检测，国内外环境自适应
- **🔒 生产就绪** - 包含安全配置、性能优化、监控等
- **📊 完整生态** - 支持ELK日志分析、开发工具栈等
- **💾 数据安全** - 使用 Docker named volume，支持自动备份和恢复

## 📋 支持的服务

### Web服务器

| 服务      | 版本  | 说明                |
| --------- | ----- | ------------------- |
| `nginx`   | 1.25+ | 标准Nginx服务器     |
| `tengine` | 3.0+  | 阿里巴巴增强版Nginx |

### PHP版本

| 版本    | 服务名  | 端口 | 说明               |
| ------- | ------- | ---- | ------------------ |
| PHP 8.5 | `php85` | 8085 | 最新版本           |
| PHP 8.4 | `php84` | 8084 | 稳定版本，推荐使用 |
| PHP 8.3 | `php83` | 8083 | 稳定版本           |
| PHP 8.2 | `php82` | 8082 | 稳定版本           |
| PHP 8.1 | `php81` | 8081 | 稳定版本           |
| PHP 8.0 | `php80` | 8080 | 稳定版本           |
| PHP 7.4 | `php74` | 8074 | 兼容版本           |
| PHP 7.2 | `php72` | 8072 | 兼容版本           |

### 数据库服务

| 服务       | 版本 | 端口  | 说明                        |
| ---------- | ---- | ----- | --------------------------- |
| `mysql`    | 8.0+ | 3306  | MySQL 8.0（基于docker安装） |
| `mongo`    | 7.0+ | 27017 | MongoDB                     |
| `postgres` | 16+  | 5432  | PostgreSQL                  |

### 缓存服务

| 服务     | 版本 | 端口 | 说明          |
| -------- | ---- | ---- | ------------- |
| `redis`  | 7.0+ | 6379 | Redis缓存     |
| `valkey` | 7.0+ | 6380 | Redis兼容缓存 |

### 特殊组合

| 组合  | 服务                              | 说明       |
| ----- | --------------------------------- | ---------- |
| `elk` | Elasticsearch + Kibana + Logstash | 日志分析栈 |
| `sgr` | Spug + Gitea + Rap2               | 开发工具栈 |
| `all` | 所有基础服务                      | 完整环境   |

## 🏗️ 架构设计

### 分层配置架构

```
config/env/
├── base.env          # 基础配置（代理、时区、路径）
├── web.env           # Web服务器配置
├── php.env           # PHP服务配置
├── database.env      # 数据库配置
├── redis.env         # 缓存服务配置
├── elk.env           # ELK日志栈配置
└── apps.env          # 应用服务配置
```

### 服务编排架构

```
Docker Compose Files:
├── docker-compose.yaml           # 基础服务编排
├── compose_web.yaml              # Web服务器编排
├── compose_php.yaml              # PHP服务编排
├── compose_databases.yaml        # 数据库服务编排
├── docker-compose-ELK.yaml       # ELK日志栈编排
├── docker-compose-spug+gitea+rap2.yaml  # 开发工具栈编排
├── docker-compose.dev.yaml       # 开发环境配置
├── docker-compose.prod.yaml      # 生产环境配置
└── docker-compose.wsl.yaml       # WSL环境优化配置
```

### 数据持久化架构

所有数据库使用 **Docker named volume** 进行数据持久化：

- **MySQL**: `mysql_data` volume
- **MongoDB**: `mongo_data` volume
- **PostgreSQL**: `postgres_data` volume

优势：
- ✅ 数据独立于容器和镜像，容器删除不影响数据
- ✅ 存储在 Linux 文件系统，I/O 性能优异
- ✅ Docker 统一管理，无需手动创建目录
- ✅ 支持自动备份和恢复

## ⚙️ 详细配置

### 环境变量配置

#### 基础配置 (`base.env`)

```bash
# 环境标识
ENVIRONMENT=development                    # development/production
VERSION=1.1.0                             # 项目版本号
DOMAIN=default.com                        # 域名配置

# 时区配置
TZ=Asia/Shanghai                         # 系统时区设置

# 代理配置
HTTP_PROXY=                               # HTTP代理
HTTPS_PROXY=                              # HTTPS代理
NO_PROXY=localhost,127.0.0.1,172.17.0.0/16

# 路径配置
GLOBAL_WEB_PATH=/data/wwwroot             # 项目根目录
# 注意：数据库数据存储默认使用 Docker named volume
# MySQL: mysql_data, MongoDB: mongo_data, PostgreSQL: postgres_data
```

#### PHP配置 (`php.env`)

```bash
# PHP版本配置
PHP85_VERSION=8.5.0                       # PHP 8.5版本
PHP84_VERSION=8.4.0                       # PHP 8.4版本
PHP83_VERSION=8.3.0                       # PHP 8.3版本
# ... 其他版本

# 端口配置
PHP85_PORT=8085                           # PHP 8.5端口
PHP84_PORT=8084                           # PHP 8.4端口
PHP83_PORT=8083                           # PHP 8.3端口
# ... 其他端口

# 服务器名称配置
PHP85_SERVER_NAME=php85.default.com       # PHP 8.5服务器名称
PHP84_SERVER_NAME=php84.default.com       # PHP 8.4服务器名称
PHP83_SERVER_NAME=php83.default.com       # PHP 8.3服务器名称
# ... 其他服务器名称

# 性能配置
PHP_MEMORY_LIMIT=1024M                    # PHP内存限制
PHP_MAX_EXECUTION_TIME=300                # 最大执行时间
PHP_UPLOAD_MAX_FILESIZE=128M              # 最大上传文件大小
```

#### 数据库配置 (`database.env`)

```bash
# MySQL配置
MYSQL_ROOT_PASSWORD=root123               # MySQL root密码
MYSQL_DATABASE=test                       # 默认数据库
MYSQL_USER=test                           # 默认用户
MYSQL_PASSWORD=test123                    # 默认密码

# MongoDB配置
MONGO_INITDB_ROOT_USERNAME=admin          # MongoDB管理员用户名
MONGO_INITDB_ROOT_PASSWORD=admin123       # MongoDB管理员密码

# PostgreSQL配置
POSTGRES_DB=test                          # PostgreSQL默认数据库
POSTGRES_USER=postgres                    # PostgreSQL用户名
POSTGRES_PASSWORD=postgres123             # PostgreSQL密码
```

### 构建选项详解

#### build.sh 选项

```bash
./build.sh [服务名...] [环境] [选项]
```

**环境类型：**

- `dev` (默认) - 开发环境，优化构建速度
- `prod` - 生产环境，优化性能和安全性
- `test` - 测试环境，用于CI/CD

**构建选项：**

- `--no-cache` - 不使用构建缓存，强制重新构建
- `--parallel` - 并行构建多个服务（默认）
- `--no-parallel` - 禁用并行构建，串行构建
- `--auto-prune` - 构建后自动清理Docker垃圾
- `--auto-up` - 构建后自动启动服务
- `--force-recreate` - 强制重新创建容器
- `--multi-arch` - 多架构构建（ARM64/AMD64）
- `--push` - 推送到镜像仓库

#### up.sh 选项

```bash
./up.sh [服务名...] [操作] [选项]
```

**操作类型：**

- 无参数 - 启动服务
- `stop` - 停止服务
- `restart` - 重启服务
- `down` - 停止并删除容器
- `ps` - 查看服务状态
- `logs` - 查看服务日志
- `exec` - 进入服务容器

**特殊功能：**

- WSL 环境自动检测：在 WSL 环境下启动 MySQL 时，自动使用 WSL 优化配置
- 自动添加 MySQL 备份服务：启动 MySQL 时自动添加备份服务

## 🔧 高级配置

### 自定义虚拟主机

```bash
# 编辑虚拟主机配置
vim vhost/nginx_vhost/default.conf

# 示例配置
server {
    listen 80;
    server_name your-domain.com;
    root /var/www/html;
    index index.php index.html;

    location ~ \.php$ {
        fastcgi_pass php84_apache:88;
        fastcgi_index index.php;
        include fastcgi_params;
    }
}
```

### 性能优化配置

```bash
# PHP性能优化
PHP_MEMORY_LIMIT=2048M                    # 增加内存限制
PHP_MAX_EXECUTION_TIME=600                # 增加执行时间
PHP_OPCACHE_ENABLE=1                      # 启用OPcache
PHP_OPCACHE_MEMORY_CONSUMPTION=256        # OPcache内存

# MySQL性能优化
MYSQL_INNODB_BUFFER_POOL_SIZE=1G          # InnoDB缓冲池
MYSQL_MAX_CONNECTIONS=1000                # 最大连接数
MYSQL_QUERY_CACHE_SIZE=128M               # 查询缓存
```

### 安全配置

```bash
# 容器安全
security_opt:
  - no-new-privileges:true                # 禁止特权提升
cap_drop:
  - ALL                                   # 删除所有权限

# 网络安全
networks:
  - internal                              # 内部网络
  - external                              # 外部网络
```

## 💾 数据保护指南

### 📋 概述

使用 Docker named volume 进行数据持久化时，虽然数据存储在 Docker 管理的卷中，但仍需要采取适当的备份策略来防止数据丢失。

### ⚠️ 数据丢失风险场景

#### 1. 容器损坏
- **场景**：容器崩溃、配置错误导致无法启动
- **影响**：容器无法使用，但 **volume 数据仍然安全**
- **解决方案**：重新创建容器，挂载相同的 volume

```bash
# 重新创建容器，数据自动恢复
docker stop mysql
docker rm mysql
./up.sh mysql up -d
```

#### 2. 镜像损坏
- **场景**：镜像文件损坏、被误删除
- **影响**：无法创建新容器，但 **volume 数据仍然安全**
- **解决方案**：重新构建或拉取镜像，挂载相同的 volume

```bash
# 重新构建镜像，挂载相同 volume
./build.sh mysql --no-cache
./up.sh mysql up -d
```

#### 3. Volume 损坏（最严重）
- **场景**：Docker 存储驱动故障、磁盘损坏、误删除 volume
- **影响**：**数据可能丢失**
- **解决方案**：从备份恢复

#### 4. 主机系统故障
- **场景**：系统崩溃、磁盘故障
- **影响**：**数据可能丢失**
- **解决方案**：从备份恢复

### 🛡️ 数据保护策略

#### 策略 1：定期备份 Volume（推荐）

**备份单个 Volume**

```bash
# 备份 MySQL 数据卷
./scripts/docker-volume-backup.sh mysql_data /backup/volumes

# 备份 MongoDB 数据卷
./scripts/docker-volume-backup.sh mongo_data /backup/volumes

# 备份 PostgreSQL 数据卷
./scripts/docker-volume-backup.sh postgres_data /backup/volumes
```

**批量备份所有 Volumes**

```bash
# 备份所有数据库 volumes
./scripts/backup-all-volumes.sh /backup/volumes
```

**从备份恢复**

```bash
# 恢复 MySQL 数据卷
./scripts/docker-volume-restore.sh mysql_data /backup/volumes/mysql_data_backup_20231214_120000.tar.gz

# 恢复 MongoDB 数据卷
./scripts/docker-volume-restore.sh mongo_data /backup/volumes/mongo_data_backup_20231214_120000.tar.gz

# 恢复 PostgreSQL 数据卷
./scripts/docker-volume-restore.sh postgres_data /backup/volumes/postgres_data_backup_20231214_120000.tar.gz
```

#### 策略 2：应用级备份（数据库导出）

**MySQL 备份**

```bash
# 使用项目自带的备份脚本
./scripts/docker_mysql_backup_restore.sh

# 或使用 mysqldump
docker exec mysql mysqldump -u root -p --all-databases > backup.sql
```

**MongoDB 备份**

```bash
# 使用 mongodump
docker exec mongo mongodump --out /backup/mongo
docker cp mongo:/backup/mongo ./backup/mongo
```

**PostgreSQL 备份**

```bash
# 使用 pg_dump
docker exec postgres pg_dumpall -U postgres > backup.sql
```

#### 策略 3：自动化定期备份

**使用 Cron 定时任务**

```bash
# 编辑 crontab
crontab -e

# 每天凌晨 2 点备份所有 volumes
0 2 * * * /data/hg_dnmpr/scripts/backup-all-volumes.sh /backup/volumes

# 每周日凌晨 3 点备份并清理 30 天前的备份
0 3 * * 0 /data/hg_dnmpr/scripts/backup-all-volumes.sh /backup/volumes && find /backup/volumes -name "*.tar.gz" -mtime +30 -delete
```

### 📦 备份文件管理

**备份文件命名规则**

```
{volume_name}_backup_YYYYMMDD_HHMMSS.tar.gz
{volume_name}_backup_YYYYMMDD_HHMMSS.tar.gz.sha256  # 校验和文件
```

**备份文件存储建议**

1. **本地存储**：`/backup/volumes/` 或 `/data/backup/volumes/`
2. **远程存储**：NFS、S3、云存储等
3. **异地备份**：定期同步到其他服务器或云存储

**备份保留策略**

- **每日备份**：保留 7 天
- **每周备份**：保留 4 周
- **每月备份**：保留 12 个月

### 🔄 恢复流程

#### 场景 1：容器损坏，Volume 完好

```bash
# 1. 停止并删除损坏的容器
docker stop mysql
docker rm mysql

# 2. 重新创建容器，挂载相同的 volume
./up.sh mysql up -d

# 数据自动恢复，无需额外操作
```

#### 场景 2：Volume 损坏或丢失

```bash
# 1. 停止相关容器
docker stop mysql

# 2. 删除损坏的 volume（如果存在）
docker volume rm mysql_data

# 3. 从备份恢复
./scripts/docker-volume-restore.sh mysql_data /backup/volumes/mysql_data_backup_20231214_120000.tar.gz

# 4. 重新启动容器
./up.sh mysql up -d
```

#### 场景 3：主机系统故障

```bash
# 1. 在新主机上安装 Docker 和项目

# 2. 恢复备份文件到新主机

# 3. 创建 volume 并恢复数据
./scripts/docker-volume-restore.sh mysql_data /backup/volumes/mysql_data_backup_20231214_120000.tar.gz

# 4. 启动服务
./up.sh mysql up -d
```

### ✅ 最佳实践

#### 1. 多重备份策略

- **Volume 级别备份**：完整备份整个 volume（推荐用于灾难恢复）
- **应用级别备份**：数据库导出备份（推荐用于数据迁移和版本控制）
- **定期备份**：自动化定期备份，避免手动遗漏

#### 2. 备份验证

```bash
# 验证备份文件完整性
sha256sum -c mysql_data_backup_20231214_120000.tar.gz.sha256

# 测试恢复流程（在测试环境）
./scripts/docker-volume-restore.sh mysql_data_test /backup/volumes/mysql_data_backup_20231214_120000.tar.gz
```

#### 3. 监控和告警

- 监控备份任务执行状态
- 监控备份文件大小变化
- 设置备份失败告警

#### 4. 文档记录

- 记录备份策略和恢复流程
- 记录备份文件位置和访问权限
- 定期测试恢复流程

### 🔍 检查 Volume 状态

```bash
# 列出所有 volumes
docker volume ls

# 查看 volume 详细信息
docker volume inspect mysql_data

# 查看 volume 使用情况
docker system df -v
```

### 📝 总结

使用 Docker named volume 的优势：

✅ **数据持久化**：容器删除不会影响数据  
✅ **性能优化**：存储在 Linux 文件系统，I/O 性能好  
✅ **易于管理**：Docker 统一管理，无需手动创建目录  

但仍需要：

⚠️ **定期备份**：防止 volume 损坏或主机故障  
⚠️ **多重备份**：Volume 备份 + 应用级备份  
⚠️ **定期测试**：验证备份和恢复流程  

### 🆘 紧急恢复

如果遇到数据丢失紧急情况：

1. **立即停止相关容器**，防止进一步数据损坏
2. **检查 volume 状态**：`docker volume inspect {volume_name}`
3. **查找最新备份**：`ls -lt /backup/volumes/ | head -10`
4. **执行恢复**：使用恢复脚本从备份恢复
5. **验证数据**：启动容器后验证数据完整性

---

**重要提示**：定期备份是数据安全的关键！建议至少每天备份一次，重要数据建议每小时备份。

## 📊 监控和日志

### 日志配置

```bash
# 日志轮转配置
LOG_MAX_SIZE=100m                         # 单个日志文件最大大小
LOG_MAX_FILE=10                           # 保留的日志文件数量

# 日志目录
APACHE_LOG_DIR=./logs/apache              # Apache日志目录
NGINX_LOG_DIR=./logs/nginx                # Nginx日志目录
```

### ELK日志分析

```bash
# 启动ELK栈
./build.sh elk --auto-up

# 访问Kibana
http://localhost:5601

# 配置Logstash管道
vim conf/logstash/pipeline/default.conf
```

### 健康检查

```bash
# 服务健康检查
docker-compose ps                         # 查看服务状态
docker-compose logs [服务名]              # 查看服务日志

# 自定义健康检查
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost/health"]
  interval: 30s
  timeout: 10s
  retries: 3
```

## 🚀 部署指南

### 开发环境部署

```bash
# 1. 克隆项目
git clone <repository-url>
cd hg_dnmpr

# 2. 快速启动开发环境
./build.sh nginx php84 mysql redis --auto-up

# 3. 验证服务
curl http://localhost:8084
```

### 生产环境部署

```bash
# 1. 生产环境完整部署
./build.sh all prod --no-cache --auto-prune --auto-up

# 2. 配置反向代理
# 使用Nginx或Traefik作为反向代理

# 3. 配置SSL证书
# 使用Let's Encrypt或其他SSL证书

# 4. 配置监控
# 使用Prometheus + Grafana监控

# 5. 配置自动备份
# 设置 cron 定时任务备份 volumes
```

### CI/CD集成

```yaml
# .github/workflows/deploy.yml
name: Deploy to Production
on:
    push:
        branches: [main]
jobs:
    deploy:
        runs-on: ubuntu-latest
        steps:
            - uses: actions/checkout@v3
            - name: Deploy with Docker
              run: |
                  ./build.sh all prod --no-cache --auto-prune --auto-up
```

## 🔍 故障排除

### 常见问题

#### 1. 端口冲突

```bash
# 检查端口占用
netstat -tulpn | grep :8084

# 修改端口配置
vim config/env/php.env
# 修改 PHP84_PORT=8085
```

#### 2. 权限问题

```bash
# 修复脚本权限
chmod +x build.sh up.sh

# 修复entrypoint权限
find build/ -name "*entrypoint*" -type f -exec chmod +x {} \;
```

#### 3. 磁盘空间不足

```bash
# 清理Docker垃圾
docker system prune -a -f --volumes

# 清理构建缓存
./build.sh --auto-prune
```

#### 4. 网络问题

```bash
# 检查网络连接
docker network ls
docker network inspect hg_dnmpr_default

# 重建网络
docker-compose down
docker network prune
docker-compose up -d
```

### 调试技巧

```bash
# 查看详细构建日志
./build.sh nginx php84 2>&1 | tee build.log

# 进入容器调试
docker exec -it php84_apache bash

# 查看服务依赖
docker-compose config
```

## 🤝 贡献指南

### 提交Issue

1. 使用Issue模板
2. 提供详细的错误信息
3. 包含系统环境信息
4. 提供复现步骤

### 提交Pull Request

1. Fork项目
2. 创建功能分支
3. 提交代码变更
4. 创建Pull Request

### 代码规范

- 遵循Shell脚本最佳实践
- 使用有意义的变量名
- 添加适当的注释
- 确保向后兼容

## 📄 许可证

本项目采用 [MIT License](LICENSE) 开源许可证。

## 🙏 致谢

感谢所有贡献者的支持和帮助！

---

**如有问题，请查看 [QUICK_START.md](QUICK_START.md) 或提交Issue。**
