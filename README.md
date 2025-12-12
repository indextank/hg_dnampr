# HG_DNMPR - Docker 一键部署套件

[![Docker](https://img.shields.io/badge/Docker-Required-blue.svg)](https://www.docker.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![PHP](https://img.shields.io/badge/PHP-7.2--8.4-purple.svg)](https://www.php.net/)
[![MySQL](https://img.shields.io/badge/MySQL-8.0-orange.svg)](https://www.mysql.com/)

一款全功能的Docker一键部署套件，支持Nginx + Apache + PHP + MySQL + MongoDB + Redis + ELK等，满足日常开发及生产环境使用。

## 🌟 项目特点

- **🚀 一键部署** - 支持一键构建和启动所有服务
- **🔧 多版本支持** - PHP 7.2-8.4、MySQL 8.0、Redis 7.0等
- **📦 分层配置** - 采用分层配置文件管理，便于维护
- **🌍 环境自适应** - 智能代理检测，国内外环境自适应
- **🔒 生产就绪** - 包含安全配置、性能优化、监控等
- **📊 完整生态** - 支持ELK日志分析、开发工具栈等

## 📋 支持的服务

### Web服务器

| 服务      | 版本  | 说明                |
| --------- | ----- | ------------------- |
| `nginx`   | 1.25+ | 标准Nginx服务器     |
| `tengine` | 3.0+  | 阿里巴巴增强版Nginx |

### PHP版本

| 版本    | 服务名  | 端口 | 说明               |
| ------- | ------- | ---- | ------------------ |
| PHP 8.4 | `php84` | 8084 | 最新版本，推荐使用 |
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
└── docker-compose.prod.yaml      # 生产环境配置
```

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
MYSQL_DATA_DIR=/data/myDockerData/mysql_data
```

#### PHP配置 (`php.env`)

```bash
# PHP版本配置
PHP84_VERSION=8.4.0                       # PHP 8.4版本
PHP83_VERSION=8.3.0                       # PHP 8.3版本
# ... 其他版本

# 端口配置
PHP84_PORT=8084                           # PHP 8.4端口
PHP83_PORT=8083                           # PHP 8.3端口
# ... 其他端口

# 服务器名称配置
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
- `status` - 查看服务状态
- `logs` - 查看服务日志

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

## 📚 开发指南

### 添加新服务

1. 在 `build/` 目录下创建Dockerfile
2. 在 `conf/` 目录下添加配置文件
3. 在 `compose_*.yaml` 中添加服务定义
4. 在 `config/env/` 中添加环境变量

### 自定义构建

```dockerfile
# build/custom/Dockerfile
FROM php:8.4-apache

# 安装扩展
RUN docker-php-ext-install mysqli pdo_mysql

# 配置Apache
COPY conf/apache/custom.conf /etc/apache2/sites-available/

# 启动服务
CMD ["apache2-foreground"]
```

### 扩展开发

```bash
# 创建自定义扩展
mkdir -p build/extensions/custom
cd build/extensions/custom

# 编写扩展代码
# 编译扩展
# 集成到PHP镜像
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
