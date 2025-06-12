@echo off
chcp 65001 >nul
echo =============================================================================
echo 🐳 Docker 构建问题修复工具
echo =============================================================================
echo.

echo 🔧 步骤 1: 清理 Docker 缓存和损坏镜像...
docker system prune -a -f
docker builder prune -a -f

echo.
echo 🔧 步骤 2: 移除损坏的镜像...
docker image rm alpine:3.21 2>nul
docker image rm debian:bookworm-slim 2>nul

echo.
echo 🔧 步骤 3: 配置 Docker 镜像源...
set DOCKER_CONFIG_DIR=%USERPROFILE%\.docker
if not exist "%DOCKER_CONFIG_DIR%" mkdir "%DOCKER_CONFIG_DIR%"

echo {> "%DOCKER_CONFIG_DIR%\daemon.json"
echo   "registry-mirrors": [>> "%DOCKER_CONFIG_DIR%\daemon.json"
echo     "https://docker.m.daocloud.io",>> "%DOCKER_CONFIG_DIR%\daemon.json"
echo     "https://dockerproxy.com",>> "%DOCKER_CONFIG_DIR%\daemon.json"
echo     "https://mirror.baidubce.com">> "%DOCKER_CONFIG_DIR%\daemon.json"
echo   ],>> "%DOCKER_CONFIG_DIR%\daemon.json"
echo   "features": {>> "%DOCKER_CONFIG_DIR%\daemon.json"
echo     "buildkit": true>> "%DOCKER_CONFIG_DIR%\daemon.json"
echo   },>> "%DOCKER_CONFIG_DIR%\daemon.json"
echo   "max-concurrent-downloads": 10>> "%DOCKER_CONFIG_DIR%\daemon.json"
echo }>> "%DOCKER_CONFIG_DIR%\daemon.json"

echo ✅ Docker 配置已更新: %DOCKER_CONFIG_DIR%\daemon.json

echo.
echo 🔧 步骤 4: 测试镜像拉取...
echo 正在测试 alpine:3.20...
docker pull alpine:3.20
if %errorlevel% equ 0 (
    echo ✅ alpine:3.20 拉取成功
) else (
    echo ❌ alpine:3.20 拉取失败
)

echo 正在测试 debian:bookworm-slim...
docker pull debian:bookworm-slim
if %errorlevel% equ 0 (
    echo ✅ debian:bookworm-slim 拉取成功
) else (
    echo ❌ debian:bookworm-slim 拉取失败
)

echo.
echo =============================================================================
echo 🎉 修复完成！
echo =============================================================================
echo.
echo ⚠️  重要提示：
echo 1. 请重启 Docker Desktop 以使配置生效
echo 2. 重启后可以尝试运行: bash ./build.sh nginx dev --no-cache
echo 3. 如果仍有问题，请检查网络连接和防火墙设置
echo.
echo 配置文件位置: %DOCKER_CONFIG_DIR%\daemon.json
echo =============================================================================

pause 