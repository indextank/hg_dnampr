# HG_DNMPR - Docker 一键部署套件

一款全功能的Docker一键部署套件，支持Nginx + Apache + PHP + MySQL 8 + MongoDB + Redis + ELK等，满足日常开发及生产环境使用。
为了加快部署速度，可以提前下载好相关源码安装包，放在src目录下里面，下载链接：https://pan.baidu.com/s/1HFyWPOqLmh6j7lE31eimYg?pwd=40ea

## 🚀 快速开始

### 1. 基础使用

```bash
# 构建并启动所有服务
./build.sh all --auto-prune --auto-up

# 构建特定服务
./build.sh nginx php84 mysql8 redis

# 启动服务
./up.sh nginx php84 mysql8 redis

# 停止服务
./up.sh nginx php84 mysql8 redis stop
```

### 2. 常用命令

```bash
# 开发环境 - 快速构建启动
./build.sh nginx php84 mysql8 --auto-up

# 生产环境 - 完整构建清理启动
./build.sh all prod --no-cache --auto-prune --auto-up

# 仅构建不启动
./build.sh nginx php84

# 构建后清理Docker垃圾
./build.sh nginx php84 --auto-prune
```

## 📋 支持的服务

### Web服务器（二选一）
- `nginx` - 标准Nginx
- `tengine` - 阿里巴巴增强版Nginx

### PHP版本（可多选）
- `php84`, `php83`, `php82`, `php81`, `php80`, `php74`, `php72`

### 数据库（可多选）
- `mysql8`, `mysql` - MySQL数据库
- `mongo` - MongoDB
- `postgres` - PostgreSQL

### 缓存服务
- `redis` - Redis缓存
- `valkey` - Redis兼容缓存

### 特殊组合
- `elk` - Elasticsearch + Kibana + Logstash
- `sgr` - Spug + Gitea + Rap2
- `all` - 所有基础服务

## ⚙️ 配置说明

### 环境配置
1. 复制环境配置文件：`cp .env.example .env`
2. 根据需要修改 `.env` 文件中的配置
3. 修改 `vhost/` 目录下的虚拟主机配置

### 默认访问地址
- PHP 7.2：https://72.default.com
- PHP 7.4：https://74.default.com  
- PHP 8.2：https://82.default.com
- PHP 8.4：https://84.default.com

**本地开发**：请修改 hosts 文件添加域名解析
**生产环境**：请修改相关配置文件中的域名

## 🛠️ 构建选项

### build.sh 选项

```bash
./build.sh [服务名...] [环境] [选项]
```

**环境类型：**
- `dev` (默认) - 开发环境
- `prod` - 生产环境  
- `test` - 测试环境

**构建选项：**
- `--no-cache` - 不使用构建缓存
- `--parallel` - 并行构建（默认）
- `--no-parallel` - 禁用并行构建
- `--auto-prune` - 构建后自动清理Docker垃圾
- `--auto-up` - 构建后自动启动服务
- `--force-recreate` - 强制重新创建容器
- `--multi-arch` - 多架构构建
- `--push` - 推送到镜像仓库

### up.sh 选项

```bash
./up.sh [服务名...] [操作] [选项]
```

**操作类型：**
- 无参数 - 启动服务
- `stop` - 停止服务
- `restart` - 重启服务
- `down` - 停止并删除容器

## 🔧 常见问题

### 权限错误
如果遇到 `permission denied` 错误：
```bash
# 给脚本添加执行权限
chmod +x build.sh up.sh

# 修复entrypoint权限
find build/ -name "*entrypoint*" -type f -exec chmod +x {} \;
```

### 端口冲突
检查并修改 `.env` 文件中的端口配置：
```bash
NGINX_HTTP_HOST_PORT=80
NGINX_HTTPS_HOST_PORT=443
MYSQL_HOST_PORT=3306
```

### 磁盘空间不足
定期清理Docker垃圾：
```bash
# 标准清理
sudo docker system prune -f

# 强制清理（包括未使用的镜像和卷）
sudo docker system prune -a -f --volumes
```

### 服务冲突
- 不能同时使用 `nginx` 和 `tengine`
- 不能同时使用 `mysql` 和 `mysql8`

## 📁 目录结构

```
hg_dnmpr/
├── build/          # Docker构建文件
├── conf/           # 服务配置文件
├── vhost/          # 虚拟主机配置
├── logs/           # 日志文件
├── src/            # 源代码目录
├── build.sh        # 构建脚本
├── up.sh           # 启动脚本
├── .env            # 环境配置
└── docker-compose.yaml  # Docker编排文件
```

## 🌟 项目特点

1. **100%开源**，遵循Docker标准
2. **多版本PHP共存**，可任意切换
3. **支持HTTPS和HTTP/2**
4. **支持绑定任意多个域名**
5. **路径可自定义**（源代码、数据、配置、日志）
6. **生产环境验证**，确保可用性
7. **智能代理检测**，国内外环境自适应

## 📝 使用示例

### 开发环境
```bash
# 快速启动开发环境
./build.sh nginx php84 mysql8 redis --auto-up

# 重启服务
./up.sh nginx php84 mysql8 redis restart
```

### 生产环境
```bash
# 生产环境完整部署
./build.sh all prod --no-cache --auto-prune --auto-up

# 仅启动核心服务
./up.sh nginx php84 mysql8 redis prod
```

### 特殊场景
```bash
# 构建ELK日志分析栈
./build.sh elk prod --auto-up

# 构建开发工具栈
./build.sh sgr dev --auto-up

# 无缓存重新构建
./build.sh nginx php84 --no-cache --force-recreate
```

## 🤝 贡献

欢迎提交Issue和Pull Request来改进这个项目。

## 📄 许可证

本项目采用开源许可证，详见LICENSE文件。