# 🚀 快速开始指南

## 📑 目录

- [项目简介](#-项目简介)
- [一键启动](#-一键启动)
  - [环境准备](#1-环境准备)
  - [快速启动](#2-快速启动推荐)
  - [开发环境快速启动](#3-开发环境快速启动)
- [默认访问地址](#-默认访问地址)
- [常用命令](#️-常用命令)
  - [构建命令](#构建命令)
  - [服务管理](#服务管理)
  - [特殊组合](#特殊组合)
- [数据备份快速参考](#-数据备份快速参考)
  - [备份单个 Volume](#备份单个-volume)
  - [批量备份所有 Volumes](#批量备份所有-volumes)
  - [恢复 Volume](#恢复-volume)
  - [关键要点](#关键要点)
- [WSL优化配置](#-wsl优化配置)
  - [WSL 2 性能优化](#wsl-2-性能优化)
  - [常见 WSL 问题解决](#常见-wsl-问题解决)
- [基本配置说明](#️-基本配置说明)
  - [分层配置文件](#分层配置文件)
  - [PHP 版本配置](#php-版本配置)
  - [端口配置](#端口配置)
- [故障排除](#-故障排除)
  - [权限问题](#权限问题)
  - [端口冲突](#端口冲突)
  - [构建失败](#构建失败)
  - [WSL Docker 问题](#wsl-docker-问题)
  - [清理Docker垃圾](#清理docker垃圾)
- [项目结构](#-项目结构)
- [最佳实践](#-最佳实践)
  - [开发环境推荐配置](#开发环境推荐配置)
  - [生产环境推荐配置](#生产环境推荐配置)
- [更多信息](#-更多信息)

---

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
# 最常用的开发环境组合（使用PHP 8.4稳定版）
./build.sh nginx php84 mysql redis --auto-up

# 或使用PHP 8.5最新版本
./build.sh nginx php85 mysql redis --auto-up
```

## 🌐 默认访问地址

| 服务    | 地址                      | 端口 | 说明           |
| ------- | ------------------------- | ---- | -------------- |
| PHP 8.5 | https://php85.default.com | 8085 | 最新PHP版本    |
| PHP 8.4 | https://php84.default.com | 8084 | PHP 8.4 稳定版 |
| PHP 8.3 | https://php83.default.com | 8083 | PHP 8.3        |
| PHP 8.2 | https://php82.default.com | 8082 | PHP 8.2        |
| PHP 8.1 | https://php81.default.com | 8081 | PHP 8.1        |
| PHP 8.0 | https://php80.default.com | 8080 | PHP 8.0        |
| PHP 7.4 | https://php74.default.com | 8074 | PHP 7.4        |
| PHP 7.2 | https://php72.default.com | 8072 | PHP 7.2        |

**本地开发**：修改 hosts 文件添加域名解析

```bash
# Windows: C:\Windows\System32\drivers\etc\hosts
# Linux/Mac: /etc/hosts
127.0.0.1 php85.default.com php84.default.com php83.default.com php82.default.com php81.default.com php80.default.com php74.default.com php72.default.com
```

## 🛠️ 常用命令

### 构建命令

```bash
# 构建特定服务（推荐使用 PHP 8.4）
./build.sh nginx php84 mysql redis

# 构建多个PHP版本
./build.sh nginx php84 php82 mysql redis

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
./up.sh ps

# 进入容器
docker exec -it php84_apache /bin/bash
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

## 💾 数据备份快速参考

> ⚠️ **重要提示**：使用 Docker named volume 时，容器或镜像损坏不会导致数据丢失，但 volume 损坏或主机故障会导致数据丢失。**定期备份至关重要！**

### 备份单个 Volume

```bash
# MySQL 数据卷备份
./scripts/docker-volume-backup.sh mysql_data

# MongoDB 数据卷备份
./scripts/docker-volume-backup.sh mongo_data

# PostgreSQL 数据卷备份
./scripts/docker-volume-backup.sh postgres_data

# 指定备份路径
./scripts/docker-volume-backup.sh mysql_data /data/backup/volumes
```

### 批量备份所有 Volumes

```bash
# 备份所有数据库 volumes（默认路径：/backup/volumes）
./scripts/backup-all-volumes.sh

# 指定备份路径
./scripts/backup-all-volumes.sh /data/backup/volumes
```

### 恢复 Volume

```bash
# 恢复 MySQL 数据卷
./scripts/docker-volume-restore.sh mysql_data /backup/volumes/mysql_data_backup_20231214_120000.tar.gz

# 恢复 MongoDB 数据卷
./scripts/docker-volume-restore.sh mongo_data /backup/volumes/mongo_data_backup_20231214_120000.tar.gz

# 恢复 PostgreSQL 数据卷
./scripts/docker-volume-restore.sh postgres_data /backup/volumes/postgres_data_backup_20231214_120000.tar.gz
```

### 关键要点

1. **容器/镜像损坏 ≠ 数据丢失**
   - Volume 数据独立于容器和镜像
   - 重新创建容器时挂载相同 volume 即可恢复

2. **Volume 损坏 = 数据丢失风险**
   - 需要从备份恢复
   - 定期备份至关重要

3. **双重保护策略**
   - Volume 级别备份（完整数据）
   - 应用级别备份（数据库导出）

4. **建议备份频率**
   - 生产环境：每天备份，保留 30 天
   - 开发环境：每周备份，保留 7 天
   - 重要数据：每小时备份

> 📖 **详细数据保护指南**：查看 [README.md](README.md#-数据保护指南)

## 🪟 WSL优化配置

### WSL 2 性能优化

在 WSL2 环境下使用 Docker Desktop 需要特别优化，以获得最佳性能。

#### 1. 配置 .wslconfig 文件

在 Windows 用户目录下创建或编辑 `C:\Users\<用户名>\.wslconfig`：

```ini
[wsl2]
# ==========================================
# 基础资源配置（根据实际硬件调整）
# ==========================================
# 限制WSL2内存使用（建议设置为物理内存的50-75%）
# 示例：16GB物理内存 -> 8GB，32GB物理内存 -> 16GB
memory=8GB

# 限制CPU核心数（建议设置为物理核心数的75%）
# 示例：8核CPU -> 6核，16核CPU -> 12核
processors=4

# ==========================================
# 网络配置
# ==========================================
# 启用本地主机转发（重要！用于Docker端口映射）
localhostForwarding=true

# ==========================================
# 交换空间配置
# ==========================================
# 交换空间大小（建议为内存的50%，最大不超过8GB）
swap=4GB

# 交换文件路径（建议放在非系统盘，如D盘）
# 注意：路径使用双反斜杠转义
swapFile=D:\\wsl-swap.vhdx

# ==========================================
# 内核参数优化
# ==========================================
# 解决部分情况下 WSL 发行版内的 ping 命令可能会需要 root 权限才能使用的问题
# vm.overcommit_memory=1: 允许内存过度分配（Docker需要）
# ping_group_range: 允许非root用户使用ping
kernelCommandLine=sysctl.vm.overcommit_memory=1 sysctl.net.ipv4.ping_group_range=\"0 2147483647\"

# ==========================================
# 虚拟化配置
# ==========================================
# 启用嵌套虚拟化支持（Docker Desktop需要）
nestedVirtualization=true

# ==========================================
# 内存优化配置
# ==========================================
# 启用页面报告（优化内存使用，WSL 2.0.9+）
pageReporting=true

# 空闲内存回收时间（毫秒，5秒=5000ms）
# 较小值：更积极回收内存，但可能影响性能
# 较大值：更保守回收，性能更好但内存占用更高
vmIdleTimeout=5000

# ==========================================
# 存储优化配置
# ==========================================
# 虚拟硬盘压缩（gradual模式：渐进式压缩，性能影响小）
# 可选值：true（gradual模式）| false（禁用压缩）
sparseVhd=true

# ==========================================
# 实验性功能（WSL 2.0.9+，WSL 2.5.10已稳定）
# ==========================================
[experimental]

# 网络模式：nat（NAT模式，推荐）| mirrored（镜像模式，性能更好但可能有兼容性问题）
# nat模式：更稳定，兼容性好，适合大多数场景
# mirrored模式：性能更好，但某些应用可能不兼容
networkingMode=nat

# 自动代理配置（自动检测Windows代理设置）
autoProxy=true

# DNS隧道（通过Windows DNS解析，解决DNS问题）
dnsTunneling=true

# 防火墙（false=禁用WSL防火墙，使用Windows防火墙）
# 如果遇到网络问题，可以尝试设置为true
firewall=false

# 内存自动回收（使用Docker时必须设置为disabled或dropcache）
# disabled: 禁用自动回收（推荐，Docker需要）
# dropcache: 立即释放缓存（可能影响性能）
# gradual: 缓慢释放（Docker可能无法启动）
# ⚠️ 重要：如果使用Docker，必须设置为disabled或dropcache
autoMemoryReclaim=disabled

# 主机地址回环（允许从Windows访问WSL服务）
hostAddressLoopback=true

# ==========================================
# 性能优化建议（可选，根据需求启用）
# ==========================================
# 如果遇到性能问题，可以尝试以下配置：

# 1. 禁用GUI支持（如果不需要WSLg，可以提升性能）
# guiApplications=false

# 2. 启用自动内存回收（如果不用Docker，可以启用gradual模式）
# autoMemoryReclaim=gradual

# 3. 使用镜像网络模式（性能更好，但可能有兼容性问题）
# networkingMode=mirrored
```

**配置验证和优化建议：**

```bash
# 在WSL中验证配置是否生效
# 1. 检查内存限制
free -h

# 2. 检查CPU核心数
nproc

# 3. 检查交换空间
swapon --show

# 4. 检查内核参数
sysctl vm.overcommit_memory
sysctl net.ipv4.ping_group_range
```

**配置生效验证：**

修改 `.wslconfig` 后，需要重启 WSL 使配置生效：

```powershell
# 在 PowerShell 中执行
wsl --shutdown

# 等待几秒后重新启动 WSL
wsl
```

然后在 WSL 中验证配置：

```bash
# 验证内存限制
free -h
# 应该显示约 8GB 总内存

# 验证CPU核心数
nproc
# 应该显示 4 个核心

# 验证交换空间
swapon --show
# 应该显示 4GB 交换空间

# 验证内核参数
sysctl vm.overcommit_memory
# 应该显示 vm.overcommit_memory = 1

# 测试ping权限（非root用户）
ping -c 1 8.8.8.8
# 应该可以正常ping，无需root权限
```

#### 2. WSL 内核参数优化

在 WSL2 终端中编辑 `/etc/sysctl.conf`：

```bash
# 编辑配置文件
sudo vim /etc/sysctl.conf

# 添加以下内容
# 文件系统优化
fs.inotify.max_user_watches=524288
fs.file-max=2097152

# 网络优化
net.core.somaxconn=100000
net.ipv4.tcp_max_syn_backlog=819200
net.ipv4.ip_local_port_range=1024 65535

# 应用配置
sudo sysctl -p
```

#### 3. Docker Desktop WSL 配置

在 Docker Desktop 设置中：

1. **General（常规）**
   - ✅ 启用 "Use the WSL 2 based engine"
   - ✅ 启用 "Use Docker Compose V2"

2. **Resources（资源）**
   - WSL Integration: 启用你的 WSL 发行版

3. **Docker Engine（引擎配置）**

```json
{
    "builder": {
        "gc": {
            "enabled": true,
            "defaultKeepStorage": "20GB"
        }
    },
    "experimental": false,
    "features": {
        "buildkit": true
    },
    "max-concurrent-downloads": 10,
    "max-concurrent-uploads": 10,
    "registry-mirrors": [
        "https://docker.mirrors.ustc.edu.cn",
        "https://hub-mirror.c.163.com"
    ]
}
```

#### 4. WSL 文件系统性能

```bash
# 在 WSL 中查看挂载点
mount | grep drvfs

# 推荐的项目存储位置
# ✅ 推荐：/home/用户名/projects  （WSL原生文件系统，性能最佳）
# ❌ 避免：/mnt/c/projects        （Windows文件系统，性能较差）

# 迁移项目到WSL原生文件系统
cd ~
git clone <repository-url>
cd hg_dnmpr
```

### 常见 WSL 问题解决

```bash
# 重启 WSL 服务
wsl --shutdown
wsl

# 查看 WSL 版本
wsl -l -v

# 设置默认 WSL 版本为 2
wsl --set-default-version 2

# 将发行版转换为 WSL 2
wsl --set-version Ubuntu 2

# 查看 WSL IP 地址
ip addr show eth0 | grep inet

# 从 Windows 访问 WSL 服务
# 使用 localhost:端口 或 WSL的IP:端口
```

> 💡 **提示**：WSL 环境下启动 MySQL 时，脚本会自动检测并使用 WSL 优化的配置。

## ⚙️ 基本配置说明

### 分层配置文件

项目采用分层配置管理，配置文件位于 `config/env/` 目录：

- `base.env` - 基础配置（代理、时区、路径等）
- `web.env` - Web服务器配置（Nginx、Tengine）
- `php.env` - PHP服务配置（版本、扩展、端口等）
- `database.env` - 数据库配置（MySQL、MongoDB、PostgreSQL）
- `redis.env` - 缓存服务配置（Redis、Valkey）
- `elk.env` - ELK日志栈配置
- `apps.env` - 应用服务配置

### PHP 版本配置

支持的 PHP 版本及推荐场景：

| 版本    | 状态   | 推荐场景         | 扩展支持 |
| ------- | ------ | ---------------- | -------- |
| PHP 8.5 | 最新版 | 尝鲜、新特性开发 | 完整支持 |
| PHP 8.4 | 稳定版 | **生产环境推荐** | 完整支持 |
| PHP 8.3 | 稳定版 | 生产环境         | 完整支持 |
| PHP 8.2 | 稳定版 | 生产环境         | 完整支持 |
| PHP 8.1 | 维护版 | 老项目维护       | 完整支持 |
| PHP 8.0 | EOL    | 不推荐           | 部分支持 |
| PHP 7.4 | EOL    | 遗留项目         | 有限支持 |
| PHP 7.2 | EOL    | 遗留项目         | 有限支持 |

### 端口配置

默认端口配置（可在 `php.env` 中修改）：

- PHP 8.5: 8085
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

# WSL 文件权限问题
# 在 /etc/wsl.conf 中添加
[automount]
options = "metadata,umask=22,fmask=11"
```

### 端口冲突

```bash
# 查看端口占用
# Linux/WSL
netstat -tulpn | grep :8084

# Windows
netstat -ano | findstr :8084

# 修改端口配置
vim config/env/php.env
# 修改 PHP84_PORT=8084 为其他端口
```

### 构建失败

```bash
# 检查网络连接
ping www.php.net

# 使用国内镜像源
# 编辑 config/env/base.env
CHANGE_SOURCE=true
MIRRORS_SOURCE=aliyun

# 清理缓存重新构建
./build.sh nginx php84 --no-cache --auto-prune
```

### WSL Docker 问题

```bash
# Docker Desktop 未启动
# 1. 确保 Docker Desktop 正在运行
# 2. 检查 WSL 集成是否启用

# Docker 守护进程连接失败
wsl --shutdown
# 重启 Docker Desktop

# 内存不足
# 编辑 .wslconfig 增加内存限制
# 或清理 Docker 镜像
docker system prune -a -f --volumes
```

### 清理Docker垃圾

```bash
# 标准清理（保留镜像）
docker system prune -f

# 强制清理（包括未使用的镜像）
docker system prune -a -f

# 清理所有数据（包括卷，谨慎使用！）
docker system prune -a -f --volumes

# 查看磁盘使用情况
docker system df
```

## 📁 项目结构

```
hg_dnmpr/
├── build/              # Docker构建文件
│   ├── php/           # PHP Dockerfile
│   ├── nginx/         # Nginx配置
│   └── mysql/          # MySQL配置
├── config/env/         # 分层配置文件
│   ├── base.env       # 基础配置
│   ├── php.env        # PHP配置
│   ├── web.env        # Web服务器配置
│   └── ...
├── conf/               # 服务配置文件
│   ├── php/           # PHP配置目录
│   │   ├── php84/     # PHP 8.4配置
│   │   ├── php83/     # PHP 8.3配置
│   │   └── ...
│   ├── nginx/         # Nginx配置
│   └── mysql/         # MySQL配置
├── vhost/              # 虚拟主机配置
├── logs/               # 日志文件
│   ├── php84/         # PHP 8.4日志
│   ├── nginx/         # Nginx日志
│   └── ...
├── scripts/            # 辅助脚本
│   ├── docker-volume-backup.sh    # Volume备份脚本
│   ├── docker-volume-restore.sh    # Volume恢复脚本
│   └── backup-all-volumes.sh       # 批量备份脚本
├── docs/               # 文档目录
├── src/                # 源代码目录
├── build.sh            # 构建脚本
├── up.sh               # 启动脚本
├── compose_*.yaml      # Docker编排文件
├── README.md           # 详细文档
└── QUICK_START.md      # 本文档
```

## 🎯 最佳实践

### 开发环境推荐配置

```bash
# 使用稳定的 PHP 8.4 进行开发
./build.sh nginx php84 mysql redis --auto-up

# 如果需要多版本测试
./build.sh nginx php84 php82 mysql redis --auto-up

# 重启服务
./up.sh nginx php84 mysql redis restart

# 查看日志
docker logs -f php84_apache
```

### 生产环境推荐配置

```bash
# 使用稳定的 PHP 8.4 生产环境
./build.sh nginx php84 mysql redis prod --no-cache --auto-prune --auto-up

# 或完整部署
./build.sh all prod --no-cache --auto-prune --auto-up

# 仅启动核心服务
./up.sh nginx php84 mysql redis prod

# 监控服务状态
watch -n 5 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
```

## 📚 更多信息

- **详细配置说明**：查看 [README.md](README.md)
- **数据保护详细指南**：查看 [README.md - 数据保护指南](README.md#-数据保护指南)
- **配置文件说明**：查看 `config/env/` 目录下的配置文件
- **问题反馈**：提交 Issue 或 Pull Request

---

**快速开始完成！** 🎉

现在你可以：

- ✅ 快速启动开发环境
- ✅ 在 WSL2 环境下获得最佳性能
- ✅ 使用数据备份工具保护数据安全
- ✅ 根据需求灵活配置和优化

如有问题，请查看详细文档或提交Issue。Happy Coding! 💻
