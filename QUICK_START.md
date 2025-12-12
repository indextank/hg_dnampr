# 🚀 快速开始指南

## 📋 项目简介

**HG_DNMPR** 是一款全功能的Docker一键部署套件，支持Nginx + Apache + PHP + MySQL + MongoDB + Redis + ELK等，满足日常开发及生产环境使用。

## ⚡ 一键启动

### 1. 环境准备

```bash
# 确保Docker和Docker Compose已安装
docker --version
docker-compose --version

# 克隆项目
git clone <repository-url>
cd hg_dnmpr
```

### 2. 快速启动（推荐）

```bash
# 一键构建并启动所有服务
./build.sh all --auto-prune --auto-up

# 或者分步执行
./build.sh nginx php84 mysql redis    # 构建
./up.sh nginx php84 mysql redis       # 启动
```

### 3. 开发环境快速启动

```bash
# 最常用的开发环境组合
./build.sh nginx php84 mysql redis --auto-up
```

## 🌐 默认访问地址

| 服务    | 地址                      | 说明        |
| ------- | ------------------------- | ----------- |
| PHP 8.4 | https://php84.default.com | 最新PHP版本 |
| PHP 8.3 | https://php83.default.com | PHP 8.3     |
| PHP 8.2 | https://php82.default.com | PHP 8.2     |
| PHP 8.1 | https://php81.default.com | PHP 8.1     |
| PHP 8.0 | https://php80.default.com | PHP 8.0     |
| PHP 7.4 | https://php74.default.com | PHP 7.4     |
| PHP 7.2 | https://php72.default.com | PHP 7.2     |

**本地开发**：修改 hosts 文件添加域名解析

```bash
# Windows: C:\Windows\System32\drivers\etc\hosts
# Linux/Mac: /etc/hosts
127.0.0.1 php84.default.com php83.default.com php82.default.com php81.default.com php80.default.com php74.default.com php72.default.com
```

## 🛠️ 常用命令

### 构建命令

```bash
# 构建特定服务
./build.sh nginx php84 mysql redis

# 生产环境构建
./build.sh all prod --no-cache --auto-prune --auto-up

# 仅构建不启动
./build.sh nginx php84 --no-cache
```

### 服务管理

```bash
# 启动服务
./up.sh nginx php84 mysql redis

# 重启服务
./up.sh nginx php84 mysql redis restart

# 停止服务
./up.sh nginx php84 mysql redis stop

# 查看服务状态
./up.sh status
```

### 特殊组合

```bash
# ELK日志分析栈
./build.sh elk --auto-up

# 开发工具栈（Spug + Gitea + Rap2）
./build.sh sgr --auto-up

# 所有基础服务
./build.sh all --auto-up
```

## ⚙️ 配置说明

### 分层配置文件

项目采用分层配置管理，配置文件位于 `config/env/` 目录：

- `base.env` - 基础配置（代理、时区、路径等）
- `web.env` - Web服务器配置（Nginx、Tengine）
- `php.env` - PHP服务配置（版本、扩展、端口等）
- `database.env` - 数据库配置（MySQL、MongoDB、PostgreSQL）
- `redis.env` - 缓存服务配置（Redis、Valkey）
- `elk.env` - ELK日志栈配置
- `apps.env` - 应用服务配置

### 端口配置

默认端口配置（可在 `php.env` 中修改）：

- PHP 8.4: 8084
- PHP 8.3: 8083
- PHP 8.2: 8082
- PHP 8.1: 8081
- PHP 8.0: 8080
- PHP 7.4: 8074
- PHP 7.2: 8072

## 🔧 故障排除

### 权限问题

```bash
# 给脚本添加执行权限
chmod +x build.sh up.sh

# 修复entrypoint权限
find build/ -name "*entrypoint*" -type f -exec chmod +x {} \;
```

### 端口冲突

检查并修改配置文件中的端口：

```bash
# 查看端口占用
netstat -tulpn | grep :8084

# 修改端口配置
vim config/env/php.env
```

### 清理Docker垃圾

```bash
# 标准清理
docker system prune -f

# 强制清理（包括未使用的镜像和卷）
docker system prune -a -f --volumes
```

### 查看日志

```bash
# 查看容器日志
docker logs [容器名] --follow

# 查看构建日志
./build.sh nginx php84 2>&1 | tee build.log
```

## 📁 项目结构

```
hg_dnmpr/
├── build/              # Docker构建文件
├── config/env/         # 分层配置文件
├── conf/               # 服务配置文件
├── vhost/              # 虚拟主机配置
├── logs/               # 日志文件
├── src/                # 源代码目录
├── scripts/            # 辅助脚本
├── build.sh            # 构建脚本
├── up.sh               # 启动脚本
├── compose_*.yaml      # Docker编排文件
└── README.md           # 详细文档
```

## 🎯 最佳实践

### 开发环境

```bash
# 快速启动开发环境
./build.sh nginx php84 mysql redis --auto-up

# 重启服务
./up.sh nginx php84 mysql redis restart
```

### 生产环境

```bash
# 生产环境完整部署
./build.sh all prod --no-cache --auto-prune --auto-up

# 仅启动核心服务
./up.sh nginx php84 mysql redis prod
```

### 性能优化

```bash
# 并行构建
./build.sh nginx php84 --parallel

# 清理构建缓存
./build.sh nginx php84 --auto-prune
```

## 📚 更多信息

- 详细配置说明：查看 [README.md](README.md)
- 配置文件说明：查看 `config/env/` 目录下的配置文件
- 问题反馈：提交 Issue 或 Pull Request

---

**快速开始完成！** 🎉 如有问题，请查看详细文档或提交Issue。
