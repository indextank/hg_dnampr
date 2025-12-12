#!/usr/bin/env bash
# Docker / containerd 一键修复 + 可选彻底重置脚本

set -euo pipefail

RESET_MODE=false

if [[ "${1:-}" == "--force-reset" ]]; then
  RESET_MODE=true
  echo "⚠️  已启用彻底重置模式：将清空 Docker 全部数据!"
  read -rp "确认继续？(yes/no): " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "取消操作。"
    exit 0
  fi
fi

echo ">>> [1/10] 停止 docker & containerd..."
sudo systemctl stop docker.socket docker.service containerd.service 2>/dev/null || true
sudo pkill -9 dockerd containerd 2>/dev/null || true

echo ">>> [2/10] 清理 runtime 残留目录..."
sudo rm -rf /run/docker/* /run/containerd/* 2>/dev/null || true
sudo rm -rf /var/lib/containerd/io.containerd.runtime.v2.task/moby/* 2>/dev/null || true
sudo rm -f /var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db 2>/dev/null || true

if [[ "$RESET_MODE" == true ]]; then
  echo ">>> [3/10] ⚠️  清空 Docker & containerd 数据目录..."
  sudo rm -rf /var/lib/docker/*
  sudo rm -rf /var/lib/containerd/*
fi

echo ">>> [4/10] 修复 systemd 限制项..."
OVERRIDE_DIR="/etc/systemd/system/containerd.service.d"
sudo mkdir -p "$OVERRIDE_DIR"
sudo tee "$OVERRIDE_DIR/override.conf" >/dev/null <<'EOF'
[Service]
LimitNPROC=infinity
LimitNOFILE=infinity
LimitCORE=infinity
EOF

echo ">>> [5/10] 重新加载 systemd..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl reset-failed docker containerd || true

echo ">>> [6/10] 加载内核模块..."
sudo modprobe overlay || true
sudo modprobe br_netfilter || true

echo ">>> [7/10] 启动 containerd..."
sudo systemctl unmask containerd docker 2>/dev/null || true
sudo systemctl start containerd || true

echo ">>> [8/10] 启动 docker..."
sudo systemctl start docker || true

if [[ "$RESET_MODE" == false ]]; then
  echo ">>> [9/10] 清理无效容器(安全模式，不删除镜像/卷)..."
  sudo docker container prune -f 2>/dev/null || true
fi

echo ">>> [10/10] 验证 Docker 状态..."
if sudo systemctl is-active --quiet docker; then
    echo "===================================="
    echo "  🎉 Docker 服务已恢复正常"
    echo "===================================="
    sudo docker ps -a || true
else
    echo "❌ Docker 启动失败，请执行："
    echo "    sudo journalctl -xeu docker.service"
fi
