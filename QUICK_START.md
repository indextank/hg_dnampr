# 🚀 快速开始指南

## 一键启动

```bash
# 1. 复制配置文件
cp .env.example .env

# 2. 构建并启动所有服务（推荐）
./build.sh all --auto-prune --auto-up

# 3. 或者分步执行
./build.sh nginx php84 mysql8 redis    # 构建
./up.sh nginx php84 mysql8 redis       # 启动
```

## 常用命令

```bash
# 开发环境快速启动
./build.sh nginx php84 mysql8 --auto-up

# 生产环境完整部署  
./build.sh all prod --no-cache --auto-prune --auto-up

# 重启服务
./up.sh nginx php84 mysql8 restart

# 停止服务
./up.sh nginx php84 mysql8 stop
```

## 默认访问地址

- PHP 7.4：https://74.default.com
- PHP 8.2：https://82.default.com  
- PHP 8.4：https://84.default.com

**本地开发**：修改 hosts 文件添加域名解析
```
127.0.0.1 74.default.com 82.default.com 84.default.com
```

## 故障排除

```bash
# 权限问题
chmod +x build.sh up.sh

# 清理Docker垃圾
sudo docker system prune -f

# 查看日志
docker logs [容器名] --follow
```

详细文档请查看 [README.md](README.md) 