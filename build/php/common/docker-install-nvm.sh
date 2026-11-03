#!/usr/bin/env bash
# PHP 镜像构建阶段可选安装 nvm + Node.js（由 Dockerfile 传入环境变量控制）
# 参考：https://mirrors.tuna.tsinghua.edu.cn/help/nodejs-release/

set -eu

if [ "${PHP_IMAGE_INSTALL_NVM:-false}" != "true" ]; then
	echo "[docker-install-nvm] 跳过：PHP_IMAGE_INSTALL_NVM 未设为 true（当前=${PHP_IMAGE_INSTALL_NVM:-})"
	rm -f /tmp/docker-install-nvm.sh
	exit 0
fi

version="${PHP_IMAGE_NODE_VERSION:?PHP_IMAGE_NODE_VERSION is required}"
change_source="${CHANGE_SOURCE:-false}"
mirror="${PHP_IMAGE_NVM_NODE_MIRROR:-}"
if [ -z "$mirror" ]; then
	if [ "$change_source" = "true" ]; then
		mirror="https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/"
	else
		mirror="https://nodejs.org/dist/"
	fi
fi
# nvm 要求 NVM_NODEJS_ORG_MIRROR 以 / 结尾，与 nodejs.org/dist 布局一致
case "$mirror" in
*/) ;;
*) mirror="${mirror}/" ;;
esac

export NVM_DIR="${NVM_DIR:-/root/.nvm}"
export NVM_NODEJS_ORG_MIRROR="$mirror"
NVM_GIT_REF="${NVM_GIT_REF:-v0.40.1}"

echo "[docker-install-nvm] 安装 nvm，Node 版本=${version}，镜像=${NVM_NODEJS_ORG_MIRROR}，CHANGE_SOURCE=${change_source}"

rm -rf "$NVM_DIR"
if [ "$change_source" = "true" ]; then
	echo "[docker-install-nvm] CHANGE_SOURCE=true，优先使用国内 Gitee 克隆 nvm..."
	if ! git clone --branch "$NVM_GIT_REF" --depth 1 https://gitee.com/mirrors/nvm.git "$NVM_DIR"; then
		echo "[docker-install-nvm] Gitee 克隆失败，回退 GitHub..."
		git clone --branch "$NVM_GIT_REF" --depth 1 https://github.com/nvm-sh/nvm.git "$NVM_DIR"
	fi
else
	echo "[docker-install-nvm] 使用 GitHub 克隆 nvm（失败回退 Gitee）..."
	if ! git clone --branch "$NVM_GIT_REF" --depth 1 https://github.com/nvm-sh/nvm.git "$NVM_DIR"; then
		echo "[docker-install-nvm] GitHub 克隆失败，回退 Gitee..."
		git clone --branch "$NVM_GIT_REF" --depth 1 https://gitee.com/mirrors/nvm.git "$NVM_DIR"
	fi
fi

# shellcheck disable=SC1090
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

nvm install "$version"
nvm alias default "$version"
nvm use default

bindir="$NVM_DIR/versions/node/v${version}/bin"
if [ ! -d "$bindir" ]; then
	echo "[docker-install-nvm] 错误：未找到 $bindir" >&2
	exit 1
fi

for f in node npm npx corepack; do
	if [ -e "$bindir/$f" ]; then
		ln -sf "$bindir/$f" "/usr/local/bin/$f"
	fi
done

/usr/local/bin/node -v
/usr/local/bin/npm -v

/usr/local/bin/npm config set registry https://registry.npmmirror.com

rm -f /tmp/docker-install-nvm.sh
echo "[docker-install-nvm] 完成"
