#!/usr/bin/env python3
"""
docker_restart_analyzer.py — Docker 容器重启根因自动分析工具

功能概览
========
- 定期轮询 Docker 容器状态，自动检测 Restarting 状态并触发根因分析
- 采集容器日志、退出码、重启历史、宿主机资源、网络连通性等诊断数据
- 多维度根因匹配（资源耗尽 / 配置错误 / 应用异常 / 系统异常）
- 输出结构化解决方案（问题描述 + 根因说明 + 修复命令 + 预防建议）
- 支持本地日志、企业微信/钉钉 webhook 通知

依赖
====
- Python 3.7+
- docker 客户端（CLI）
- 可选：curl（webhook 通知）

退出码
======
- 0: 成功（未检测到重启或分析完成）
- 1: 运行期错误
- 2: 参数错误
- 3: 权限不足（无 Docker 操作权限）

配置说明
========
所有配置参数集中在脚本头部的"配置参数"区域，按分类整理。
CLI 参数优先级最高，会覆盖内置默认值。

使用示例
========
  # 单次扫描
  python3 docker_restart_analyzer.py --once

  # 守护模式，每 30 秒轮询，连续重启超过 3 次才触发
  python3 docker_restart_analyzer.py --interval 30 --restart-threshold 3

  # 指定日志文件和 webhook
  python3 docker_restart_analyzer.py --log-file /var/log/docker-restart.log \\
      --webhook https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

# ════════════════════════════════════════════════════════════════════════
# 配置参数（集中管理 — 修改此处即可调整所有默认行为）
# CLI 参数优先级更高，会覆盖此处的默认值。
# ════════════════════════════════════════════════════════════════════════

# ── 脚本元信息 ──────────────────────────────────────────────────────────
SCRIPT_NAME = "docker_restart_analyzer"
VERSION = "1.0.0"

# ── [analyzer] 分析器配置 ──────────────────────────────────────────────
# 轮询间隔（秒）：守护模式下每次扫描容器状态的间隔
DEFAULT_INTERVAL = 30
# 采集容器日志的行数：分析时截取容器最新日志的行数
DEFAULT_LOG_LINES = 20
# 触发分析的最小重启次数（连续重启超过此值才触发）
# 设为 1 表示只要检测到 Restarting 状态就立即分析
DEFAULT_RESTART_THRESHOLD = 1
# 采集容器 inspect 信息的条数（重启历史记录上限）
DEFAULT_INSPECT_COUNT = 5
# 报告文件保留天数（超过此天数的旧报告自动清理）
DEFAULT_LOG_RETENTION_DAYS = 7
# 分析报告输出目录（同时生成 .txt 人读 + .json 机读）
# 留空（None）则仅在 stdout 输出，不写报告文件
DEFAULT_REPORT_DIR: Optional[str] = None

# ── [logging] 日志配置 ─────────────────────────────────────────────────
# 日志文件路径（留空则仅输出到 stdout）
DEFAULT_LOG_FILE: Optional[str] = None

# ── [webhook] 通知配置 ─────────────────────────────────────────────────
# 企业微信 / 钉钉 webhook 地址（留空则不发送通知）
# 企业微信获取方式: 企业微信群 → 添加群机器人 → 复制 webhook 地址
# 钉钉获取方式: 钉钉群 → 群设置 → 智能群助手 → 添加自定义机器人
DEFAULT_WEBHOOK_URL: Optional[str] = None

# ════════════════════════════════════════════════════════════════════════
# 配置参数结束
# ════════════════════════════════════════════════════════════════════════

# 根因分类
CAT_RESOURCE = "资源耗尽"
CAT_CONFIG = "配置错误"
CAT_APP = "应用异常"
CAT_SYSTEM = "系统异常"

# ─── 工具函数 ────────────────────────────────────────────────────────────


def ts() -> str:
    """返回带毫秒的时间戳字符串"""
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def log(msg: str, level: str = "INFO", log_file: Optional[str] = None) -> None:
    """统一日志输出（stdout + 可选文件）"""
    line = f"[{ts()}] [{level}] {msg}"
    print(line, flush=True)
    if log_file:
        try:
            with open(log_file, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass


def run_cmd(
    cmd: List[str],
    timeout: int = 10,
    check: bool = False,
) -> Tuple[int, str, str]:
    """执行外部命令，返回 (returncode, stdout, stderr)"""
    try:
        r = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if check and r.returncode != 0:
            raise RuntimeError(
                f"命令执行失败: {' '.join(cmd)}\nstderr: {r.stderr[:500]}"
            )
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except FileNotFoundError:
        return 127, "", f"命令不存在: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", f"命令超时: {' '.join(cmd)}"
    except Exception as e:
        return 1, "", str(e)


# ─── Docker 客户端 ──────────────────────────────────────────────────────


class DockerClient:
    """轻量 Docker CLI 包装器"""

    def __init__(self, bin_path: Optional[str] = None):
        self.bin = bin_path or shutil.which("docker") or "docker"

    def available(self) -> bool:
        """检查 docker 客户端是否可用且当前用户有操作权限"""
        rc, _, _ = run_cmd([self.bin, "info", "--format", "{{.ServerVersion}}"], timeout=5)
        return rc == 0

    def list_restarting(self) -> List[Dict[str, Any]]:
        """列出所有处于 Restarting 状态的容器"""
        rc, out, _ = run_cmd(
            [self.bin, "ps", "--filter", "status=restarting", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"],
            timeout=10,
        )
        if rc != 0:
            return []
        containers = []
        for line in out.strip().splitlines():
            parts = line.split("\t")
            if len(parts) >= 4:
                containers.append({
                    "id": parts[0],
                    "name": parts[1],
                    "image": parts[2],
                    "status": parts[3],
                })
        return containers

    def list_all(self) -> List[Dict[str, Any]]:
        """列出所有容器（含已停止）"""
        rc, out, _ = run_cmd(
            [self.bin, "ps", "-a", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"],
            timeout=10,
        )
        if rc != 0:
            return []
        containers = []
        for line in out.strip().splitlines():
            parts = line.split("\t")
            if len(parts) >= 4:
                containers.append({
                    "id": parts[0],
                    "name": parts[1],
                    "image": parts[2],
                    "status": parts[3],
                    "ports": parts[4] if len(parts) > 4 else "",
                })
        return containers

    def inspect(self, container_id: str) -> Dict[str, Any]:
        """获取容器 inspect JSON"""
        rc, out, err = run_cmd(
            [self.bin, "inspect", "--type", "container", container_id],
            timeout=10,
        )
        if rc != 0:
            return {"_error": err}
        try:
            data = json.loads(out)
            return data[0] if isinstance(data, list) and data else {}
        except json.JSONDecodeError:
            return {"_error": "inspect JSON 解析失败"}

    def logs(self, container_id: str, lines: int = 20) -> Tuple[str, str]:
        """获取容器日志，返回 (stdout, stderr)"""
        rc1, out, _ = run_cmd(
            [self.bin, "logs", "--tail", str(lines), "--timestamps", container_id],
            timeout=10,
        )
        # docker logs 输出到 stdout+stderr 混合；分别再取
        rc2, stdout_only, _ = run_cmd(
            [self.bin, "logs", "--tail", str(lines), "--stdout", "--timestamps", container_id],
            timeout=10,
        )
        rc3, stderr_only, _ = run_cmd(
            [self.bin, "logs", "--tail", str(lines), "--stderr", "--timestamps", container_id],
            timeout=10,
        )
        return stdout_only, stderr_only

    def restart_count(self, container_id: str) -> int:
        """获取容器重启次数"""
        rc, out, _ = run_cmd(
            [self.bin, "inspect", "--format", "{{.RestartCount}}", container_id],
            timeout=5,
        )
        if rc == 0:
            try:
                return int(out.strip().strip('"'))
            except ValueError:
                pass
        return 0


# ─── 宿主机资源采集 ──────────────────────────────────────────────────────


def collect_host_resources() -> Dict[str, Any]:
    """采集宿主机 CPU/内存/磁盘资源"""
    info: Dict[str, Any] = {}

    # CPU
    try:
        with open("/proc/loadavg") as f:
            parts = f.read().split()
            info["load_avg"] = {
                "1min": float(parts[0]),
                "5min": float(parts[1]),
                "15min": float(parts[2]),
            }
    except (OSError, ValueError, IndexError):
        info["load_avg"] = None

    # CPU 核心数
    info["cpu_cores"] = os.cpu_count()

    # 内存
    try:
        with open("/proc/meminfo") as f:
            mem = {}
            for line in f:
                parts = line.split(":")
                if len(parts) == 2:
                    key = parts[0].strip()
                    val = int(parts[1].strip().split()[0])
                    mem[key] = val
            total = mem.get("MemTotal", 0)
            avail = mem.get("MemAvailable", mem.get("MemFree", 0))
            used = total - avail
            info["memory"] = {
                "total_mb": total // 1024,
                "used_mb": used // 1024,
                "available_mb": avail // 1024,
                "usage_percent": round(used / total * 100, 1) if total > 0 else 0,
            }
    except (OSError, ValueError):
        info["memory"] = None

    # 磁盘（根分区 + Docker 数据目录）
    rc, out, _ = run_cmd(["df", "-h", "--output=target,size,used,avail,pcent", "/"], timeout=5)
    info["disk_root"] = out if rc == 0 else None

    # Docker 数据目录
    rc, out, _ = run_cmd(["df", "-h", "--output=target,size,used,avail,pcent", "/var/lib/docker"], timeout=5)
    info["disk_docker"] = out if rc == 0 else "（/var/lib/docker 不存在或不可访问）"

    return info


def collect_network_info(docker: DockerClient, container_id: str, inspect_data: Dict) -> Dict[str, Any]:
    """采集容器网络配置与连通性"""
    net: Dict[str, Any] = {}
    net_settings = inspect_data.get("NetworkSettings", {})
    net["ip_address"] = net_settings.get("IPAddress", "")
    net["networks"] = list(net_settings.get("Networks", {}).keys())
    net["ports"] = net_settings.get("Ports", {})

    # 端口冲突检测
    rc, out, _ = run_cmd(
        [docker.bin, "port", container_id],
        timeout=5,
    )
    net["port_mapping"] = out if rc == 0 else ""

    # ping 测试（容器 IP，如果有）
    container_ip = net["ip_address"]
    if container_ip:
        rc, out, _ = run_cmd(["ping", "-c", "1", "-W", "2", container_ip], timeout=5)
        net["ping"] = "可达" if rc == 0 else "不可达"
    else:
        net["ping"] = "容器无 IP（可能未启动成功）"

    return net


# ─── 诊断数据采集 ────────────────────────────────────────────────────────


def collect_diagnostics(
    docker: DockerClient,
    container: Dict[str, Any],
    config: Dict[str, Any],
) -> Dict[str, Any]:
    """采集单个 Restarting 容器的完整诊断数据"""
    cid = container["id"]
    name = container["name"]

    diag: Dict[str, Any] = {
        "container": container,
        "collected_at": ts(),
    }

    # 1. inspect 数据（退出码、状态、挂载、环境变量、健康检查）
    inspect_data = docker.inspect(cid)
    diag["inspect"] = {
        "exit_code": _safe_get(inspect_data, "State", "ExitCode"),
        "error_message": _safe_get(inspect_data, "State", "Error"),
        "oom_killed": _safe_get(inspect_data, "State", "OOMKilled"),
        "health_status": _safe_get(inspect_data, "State", "Health", "Status"),
        "health_failing_streak": _safe_get(inspect_data, "State", "Health", "FailingStreak"),
        "restart_count": _safe_get(inspect_data, "RestartCount"),
        "started_at": _safe_get(inspect_data, "State", "StartedAt"),
        "finished_at": _safe_get(inspect_data, "State", "FinishedAt"),
        "restart_policy": _safe_get(inspect_data, "HostConfig", "RestartPolicy", "Name"),
        "memory_limit": _safe_get(inspect_data, "HostConfig", "Memory"),
        "memory_swap": _safe_get(inspect_data, "HostConfig", "MemorySwap"),
        "binds": _safe_get(inspect_data, "HostConfig", "Binds") or [],
        "env": _parse_env_list(_safe_get(inspect_data, "Config", "Env") or []),
        "entrypoint": _safe_get(inspect_data, "Config", "Entrypoint"),
        "cmd": _safe_get(inspect_data, "Config", "Cmd"),
        "healthcheck_test": _safe_get(inspect_data, "Config", "Healthcheck", "Test"),
    }

    # 1b. 健康检查日志（从 inspect 中提取，不依赖容器运行状态）
    health_log_raw = _safe_get(inspect_data, "State", "Health", "Log") or []
    diag["inspect"]["health_log"] = [
        {"start": e.get("Start", ""), "exit_code": e.get("ExitCode"), "output": e.get("Output", "")}
        for e in (health_log_raw[-5:] if isinstance(health_log_raw, list) else [])
    ]
    # 若全量 inspect 未拿到 health log，用 format 查询补充（容器重启间隙可能延迟写入）
    if not diag["inspect"]["health_log"]:
        _hc_rc, _hc_out, _ = run_cmd(
            [docker.bin, "inspect", "--format", "{{json .State.Health.Log}}", cid],
            timeout=5,
        )
        if _hc_rc == 0 and _hc_out and _hc_out not in ("null", "<nil>", ""):
            try:
                _hc_entries = json.loads(_hc_out)
                if isinstance(_hc_entries, list):
                    diag["inspect"]["health_log"] = [
                        {"start": e.get("Start", ""), "exit_code": e.get("ExitCode"), "output": e.get("Output", "")}
                        for e in _hc_entries[-5:]
                    ]
            except (json.JSONDecodeError, TypeError):
                pass

    # 1c. State.Error（容器退出时的错误信息 — 即使 docker logs 为空也可能存在）
    state_error = _safe_get(inspect_data, "State", "Error") or ""
    diag["inspect"]["state_error"] = state_error

    # 2. 日志
    stdout_log, stderr_log = docker.logs(cid, config["log_lines"])

    # 2a. 若 docker logs 为空且存在 State.Error，用 Error 信息补充
    if not stdout_log and not stderr_log and state_error:
        stderr_log = f"[State.Error]\n{state_error}"

    # 2b. 若仍为空，从 health check log 补充（容器重启间隙 docker logs 可能返回空）
    combined_health_output = "\n".join(
        e.get("output", "").strip() for e in diag["inspect"]["health_log"] if e.get("output")
    )
    if not stdout_log and not stderr_log and combined_health_output:
        stderr_log = f"[health-check output]\n{combined_health_output}"

    # 2c. 若仍为空，短暂等待后重试一次（容器可能正在重启中）
    if not stdout_log and not stderr_log:
        time.sleep(2)
        stdout_log, stderr_log = docker.logs(cid, config["log_lines"])
        if not stdout_log and not stderr_log and state_error:
            stderr_log = f"[State.Error]\n{state_error}"
        if not stdout_log and not stderr_log and combined_health_output:
            stderr_log = f"[health-check output]\n{combined_health_output}"

    diag["logs_stdout"] = stdout_log
    diag["logs_stderr"] = stderr_log

    # 3. 宿主机资源
    diag["host_resources"] = collect_host_resources()

    # 4. 网络信息
    diag["network"] = collect_network_info(docker, cid, inspect_data)

    # 5. 重启次数（从 inspect）
    diag["restart_count"] = diag["inspect"]["restart_count"] or 0

    return diag


def _safe_get(data: Dict, *keys) -> Any:
    """安全嵌套取值"""
    current = data
    for k in keys:
        if isinstance(current, dict):
            current = current.get(k)
        else:
            return None
    return current


def _parse_env_list(env_list: List[str]) -> Dict[str, str]:
    """将 ['KEY=val', ...] 列表转为字典"""
    result = {}
    for item in env_list:
        if "=" in item:
            k, v = item.split("=", 1)
            result[k] = v
    return result


# ─── 根因分析引擎 ────────────────────────────────────────────────────────


def analyze_root_causes(diag: Dict[str, Any]) -> List[Dict[str, Any]]:
    """对诊断数据进行多维度根因匹配，返回排序后的根因列表"""
    findings: List[Dict[str, Any]] = []

    _check_resource(diag, findings)
    _check_config(diag, findings)
    _check_application(diag, findings)
    _check_system(diag, findings)

    # 按置信度降序排列
    findings.sort(key=lambda x: x.get("confidence", 0), reverse=True)
    return findings


def _add(
    findings: List[Dict[str, Any]],
    category: str,
    confidence: int,
    description: str,
    root_cause: str,
    fix_commands: List[str],
    prevention: str,
) -> None:
    """添加一条根因发现"""
    findings.append({
        "category": category,
        "confidence": confidence,
        "description": description,
        "root_cause": root_cause,
        "fix_commands": fix_commands,
        "prevention": prevention,
    })


def _check_resource(diag: Dict, findings: List) -> None:
    """资源耗尽类检查"""
    inspect = diag.get("inspect", {})
    host = diag.get("host_resources", {})

    # OOM Killed
    if inspect.get("oom_killed"):
        mem_limit = inspect.get("memory_limit", 0)
        limit_str = f"（内存限制: {mem_limit // 1024 // 1024}MB）" if mem_limit and mem_limit > 0 else "（无内存限制）"
        _add(
            findings,
            CAT_RESOURCE,
            95,
            f"容器 {diag['container']['name']} 因内存超限被 OOM Kill{limit_str}",
            "容器内存使用量超过 memory limit，内核 OOM Killer 杀死了容器主进程。"
            "常见于 JVM/PHP 应用堆内存设置不当，或容器内存限制低于应用最低需求。",
            [
                "# 提高容器内存限制（编辑 compose 后重启）",
                "# docker compose 原生: mem_limit: 1g",
                "# 或动态调整:",
                "docker update --memory=1g --memory-swap=2g {diag['container']['name']}",
                "",
                "# 查看应用内存使用详情",
                "docker stats --no-stream {diag['container']['name']}",
            ],
            "根据应用基线内存 + 峰值余量设置 memory limit，建议 swap = memory × 2。"
            "对 JVM 应用设置 -Xmx 为 memory limit 的 60-70%。",
        )

    # 宿主机内存不足
    mem = host.get("memory")
    if mem and mem.get("usage_percent", 0) > 90:
        _add(
            findings,
            CAT_RESOURCE,
            85,
            f"宿主机内存使用率过高: {mem['usage_percent']}%（可用 {mem['available_mb']}MB / 总 {mem['total_mb']}MB）",
            "宿主机物理内存接近耗尽，导致容器无法分配足够内存，频繁触发 OOM 或 swap thrashing。",
            [
                "# 查找内存消耗 Top 5 进程",
                "ps aux --sort=-%mem | head -5",
                "",
                "# 查看各容器内存占用",
                "docker stats --no-stream",
                "",
                "# 清理缓存（谨慎操作）",
                "sync && echo 3 > /proc/sys/vm/drop_caches",
            ],
            "部署监控系统（如 Prometheus + node_exporter）设置内存告警阈值 85%。"
            "定期审查容器内存分配总量不超过宿主机物理内存的 80%。",
        )

    # 磁盘空间不足
    disk_docker = host.get("disk_docker", "")
    disk_root = host.get("disk_root", "")
    for disk_info in [disk_docker, disk_root]:
        if disk_info and isinstance(disk_info, str):
            # 提取使用率百分比
            pct_match = re.search(r"(\d+)%", disk_info)
            if pct_match and int(pct_match.group(1)) > 90:
                _add(
                    findings,
                    CAT_RESOURCE,
                    80,
                    f"磁盘空间不足: {disk_info.strip()}",
                    "磁盘空间接近耗尽，容器无法写入日志/数据文件，导致应用崩溃或启动失败。",
                    [
                        "# 查看磁盘占用",
                        "df -h",
                        "",
                        "# 清理 Docker 无用镜像和容器",
                        "docker system prune -a --volumes",
                        "",
                        "# 查看大文件",
                        "du -sh /var/lib/docker/* 2>/dev/null | sort -rh | head -10",
                        "",
                        "# 清理容器日志",
                        "truncate -s 0 $(find /var/lib/docker/containers -name '*-json.log')",
                    ],
                    "配置 Docker 日志轮转: /etc/docker/daemon.json 设置 log-opts.max-size=100m, max-file=3。"
                    "定期执行 docker system prune。",
                )
                break


def _check_config(diag: Dict, findings: List) -> None:
    """配置错误类检查"""
    inspect = diag.get("inspect", {})
    name = diag["container"]["name"]
    logs = (diag.get("logs_stderr", "") + "\n" + diag.get("logs_stdout", "")).lower()

    # State.Error 也纳入模式匹配（容器退出错误即使 docker logs 为空也可能存在）
    state_error = (inspect.get("state_error", "") or "").lower()
    if state_error:
        logs = logs + "\n" + state_error

    # 端口绑定冲突
    net = diag.get("network", {})
    port_map = net.get("port_mapping", "")
    if port_map:
        # 检查是否有端口绑定失败的日志特征
        port_conflict_patterns = [
            r"bind.*already.*in.*use",
            r"address.*already.*in.*use",
            r"port.*is.*allocat",
            r"failed.*to.*bind",
            r"listen.*tcp.*bind",
        ]
        for pattern in port_conflict_patterns:
            if re.search(pattern, logs):
                _add(
                    findings,
                    CAT_CONFIG,
                    90,
                    f"端口绑定冲突: 容器 {name} 无法绑定所需端口",
                    f"宿主机上已有其他进程占用了容器所需的端口。\n端口映射: {port_map}",
                    [
                        "# 查找占用端口的进程",
                        "ss -tlnp | grep <冲突端口号>",
                        "",
                        "# 方案 1: 停止占用端口的进程",
                        "kill <占用进程的PID>",
                        "",
                        "# 方案 2: 修改容器端口映射",
                        f"# 在 docker-compose.yml 中将端口改为其他空闲端口",
                        f"docker compose down {name} && docker compose up -d {name}",
                    ],
                    "使用 ./up.sh 启动前执行端口预检（firewall-check 已内置）。"
                    "避免多个容器映射到同一宿主机端口。",
                )
                break

    # 挂载卷权限错误
    binds = inspect.get("binds", [])
    if binds:
        perm_patterns = [
            r"permission\s*denied",
            r"operation\s*not\s*permitted",
            r"access\s*is\s*denied",
            r"cannot\s*open\s.*(no\s*such\s*file|permission)",
            r"mkdir.*permission",
            r"chown.*operation\s*not\s*permitted",
        ]
        for pattern in perm_patterns:
            if re.search(pattern, logs):
                _add(
                    findings,
                    CAT_CONFIG,
                    85,
                    f"挂载卷权限错误: 容器 {name} 无法访问挂载目录",
                    f"容器内进程对挂载的宿主机目录没有读/写权限。\n挂载列表:\n" + "\n".join(f"  - {b}" for b in binds[:10]),
                    [
                        "# 查看挂载目录权限",
                        "ls -la <宿主机路径>",
                        "",
                        "# 方案 1: 修改目录所有者匹配容器用户",
                        "chown -R <容器UID>:<容器GID> <宿主机路径>",
                        "",
                        "# 方案 2: 放宽目录权限（不推荐生产环境）",
                        "chmod -R 777 <宿主机路径>",
                        "",
                        "# 查看 Docker 数据卷权限",
                        f"docker run --rm -v <卷名>:/data alpine ls -la /data",
                    ],
                    "在 Dockerfile 中使用 USER 指令明确运行用户，"
                    "挂载目录的宿主机路径确保与容器用户 UID/GID 匹配。",
                )
                break

    # 环境变量缺失
    env = inspect.get("env", {})
    env_patterns = [
        (r"environment\s*variable.*not\s*(set|defined|found)", "环境变量未设置"),
        (r"required\s*env.*missing", "必需的环境变量缺失"),
        (r"(MYSQL_ROOT_PASSWORD|REDIS_PASSWORD|DATABASE_URL|JWT_SECRET).*empty|not\s*set", "关键密码/连接变量为空"),
        (r"please\s*(set|provide|configure).*environment", "应用要求配置环境变量"),
    ]
    for pattern, desc in env_patterns:
        if re.search(pattern, logs, re.IGNORECASE):
            _add(
                findings,
                CAT_CONFIG,
                82,
                f"环境变量配置错误: {desc}",
                "应用启动时检测到必需的环境变量未正确设置，拒绝继续启动。",
                [
                    "# 查看当前容器环境变量",
                    f"docker exec {name} env | sort",
                    "",
                    "# 在 .env 或 docker-compose.yml 中补充缺失的变量",
                    "# 然后重建容器:",
                    f"docker compose up -d --force-recreate {name}",
                ],
                "使用 .env 文件统一管理环境变量，启动前通过脚本验证关键变量非空。"
                f"当前容器环境变量列表: {list(env.keys())[:10]}",
            )
            break

    # nginx upstream 解析失败（高优先级 — 直接导致 nginx 崩溃退出）
    nginx_patterns = [
        (r"host\s+not\s+found\s+in\s+upstream\s+\"([^\"]+)\"", "upstream 主机名无法解析"),
        (r"\[emerg\].*no\s+resolver", "无 DNS resolver 配置"),
        (r"\[emerg\].*unknown\s+directive", "配置语法错误"),
    ]
    for pattern, desc in nginx_patterns:
        m = re.search(pattern, logs, re.IGNORECASE)
        if m:
            # 尝试提取 upstream 名称
            upstream_name = m.group(1) if m.lastindex and m.lastindex >= 1 else "<upstream>"
            _add(
                findings,
                CAT_CONFIG,
                92,
                f"Nginx 启动失败: {desc}（{upstream_name}）",
                f"Nginx 在加载配置时遇到致命错误（[emerg]），直接退出。\n"
                f"最常见原因: upstream 引用的容器（如 {upstream_name}）未启动或不在同一 Docker 网络中。",
                [
                    f"# 检查 {upstream_name} 容器是否在运行",
                    f"docker ps --filter name={upstream_name}",
                    "",
                    f"# 启动缺失的 upstream 容器",
                    f"docker compose up -d {upstream_name}",
                    "",
                    "# 检查容器是否在同一网络",
                    f"docker network inspect $(docker inspect {name} --format '{{{{range .NetworkSettings.Networks}}}}{{{{.NetworkID}}}}{{{{end}}}}')",
                    "",
                    "# 临时注释掉问题配置后启动 nginx",
                    f"docker exec {name} sed -i 's/^/# /' /etc/nginx/conf.d/<问题配置文件>",
                ],
                "确保 upstream 容器在 nginx 之前或同时启动。"
                "使用 depends_on + condition: service_healthy 确保启动顺序。",
            )
            break

    # 依赖服务未就绪
    dep_patterns = [
        (r"connection\s*refused", "目标服务拒绝连接（可能未启动或端口不对）"),
        (r"fail(?:ed)?\s+to\s+connect\s+to\s+localhost|couldn.t\s+connect\s+to\s+server", "容器主进程未监听端口（health check 无法连接）"),
        (r"can.?\s*t\s*resolve\s*host|name.*resolution.*failed", "无法解析依赖服务主机名（DNS 未就绪）"),
        (r"(timeout|timed?\s*out).*(connect|establish)", "连接依赖服务超时（可能服务未就绪）"),
        (r"ECONNREFUSED|ENOTFOUND|ECONNRESET|EHOSTUNREACH", "网络连接异常"),
        (r"waiting.*for.*(mysql|postgres|redis|mongo|database|db)", "正在等待依赖数据库就绪"),
    ]
    for pattern, desc in dep_patterns:
        if re.search(pattern, logs, re.IGNORECASE):
            _add(
                findings,
                CAT_CONFIG,
                75,
                f"依赖服务未就绪: {desc}",
                "容器依赖的下游服务（数据库/缓存/消息队列）尚未启动或不可达，"
                "导致应用在初始化阶段失败退出。",
                [
                    "# 检查依赖服务状态",
                    "docker ps --filter name=mysql --filter name=postgres --filter name=redis",
                    "",
                    "# 手动测试连通性",
                    f"docker exec {name} sh -c 'ping -c 1 <依赖服务名> || nslookup <依赖服务名>'",
                    "",
                    "# 确保依赖服务先启动",
                    "docker compose up -d mysql redis postgres",
                    f"docker compose restart {name}",
                ],
                "使用 docker-compose 的 depends_on + healthcheck 确保启动顺序。"
                "在应用代码中实现指数退避重试机制。",
            )
            break


def _check_application(diag: Dict, findings: List) -> None:
    """应用异常类检查"""
    inspect = diag.get("inspect", {})
    name = diag["container"]["name"]
    exit_code = inspect.get("exit_code")
    logs = (diag.get("logs_stderr", "") + "\n" + diag.get("logs_stdout", "")).lower()
    # State.Error 也纳入模式匹配
    state_error = (inspect.get("state_error", "") or "").lower()
    if state_error:
        logs = logs + "\n" + state_error

    # 应用进程主动退出（非 0 退出码）
    if exit_code is not None and exit_code != 0:
        _add(
            findings,
            CAT_APP,
            78,
            f"应用进程异常退出（退出码: {exit_code}）",
            _exit_code_hint(exit_code),
            [
                "# 查看完整应用日志",
                f"docker logs --tail 100 {name}",
                "",
                "# 检查应用配置文件",
                f"docker exec {name} cat /app/config.yml 2>/dev/null || true",
                "",
                "# 手动运行入口命令进行调试",
                f"docker run --rm -it {diag['container']['image']} <原始启动命令>",
            ],
            "对关键服务实现优雅退出信号处理（SIGTERM/SIGINT）。"
            "日志中记录退出原因和堆栈信息。",
        )

    # 健康检查连续失败
    health_status = inspect.get("health_status")
    failing_streak = inspect.get("health_failing_streak", 0)
    health_log = inspect.get("health_log", [])
    # 从 health log 中提取最后一次失败的输出
    last_health_output = ""
    for _hc_entry in reversed(health_log):
        if _hc_entry.get("exit_code", 0) != 0 and _hc_entry.get("output"):
            last_health_output = _hc_entry["output"].strip()
            break
    if not last_health_output and health_log:
        last_health_output = health_log[-1].get("output", "").strip()

    if health_status == "unhealthy" or (failing_streak and failing_streak >= 3) or last_health_output:
        _add(
            findings,
            CAT_APP,
            80,
            f"健康检查连续失败（状态: {health_status}, 连续失败: {failing_streak} 次"
            + (f", 最后输出: {last_health_output[:150].replace(chr(10), ' | ')}" if last_health_output else "")
            + "）",
            "容器的 healthcheck 指令连续返回非 0，Docker 标记为 unhealthy。"
            "Restart Policy 为 always/unless-stopped 时，unhealthy 状态可能导致容器被重启。",
            [
                "# 查看健康检查日志",
                f"docker inspect --format='{{{{json .State.Health.Log}}}}' {name} | python3 -m json.tool",
                "",
                "# 手动执行 healthcheck 命令",
                f"docker exec {name} {_format_healthcheck_cmd(inspect.get('healthcheck_test'))}",
                "",
                "# 临时禁用 healthcheck",
                f"docker update --health-cmd='none' {name} 2>/dev/null || true",
            ],
            "healthcheck 的 interval 不宜过短（建议 ≥30s），"
            "start-period 应覆盖应用冷启动时间（建议 30-60s）。",
        )

    # 启动命令执行失败
    entrypoint = inspect.get("entrypoint")
    cmd = inspect.get("cmd")
    cmd_fail_patterns = [
        r"exec.*format\s*error",
        r"no\s*such\s*file\s*or\s*directory.*entrypoint",
        r"command\s*not\s*found",
        r"exec.*failed",
        r"cannot\s*execute",
    ]
    for pattern in cmd_fail_patterns:
        if re.search(pattern, logs, re.IGNORECASE):
            _add(
                findings,
                CAT_APP,
                88,
                f"启动命令执行失败",
                f"容器的 Entrypoint/Cmd 无法正常执行。\nEntrypoint: {entrypoint}\nCmd: {cmd}",
                [
                    "# 检查镜像内入口脚本是否存在且有执行权限",
                    f"docker run --rm --entrypoint='' {diag['container']['image']} ls -la /entrypoint.sh",
                    "",
                    "# 手动执行入口命令调试",
                    f"docker run --rm -it --entrypoint='' {diag['container']['image']} sh",
                ],
                "Dockerfile 中 COPY 的脚本文件确保 chmod +x。"
                "使用 SHELL 指令确保脚本以正确解释器运行。",
            )
            break


def _format_healthcheck_cmd(test) -> str:
    """将 healthcheck Test 数组格式化为可执行命令字符串"""
    if not test or not isinstance(test, list) or len(test) < 1:
        return "<healthcheck 命令>"
    mode = test[0]
    if mode == "NONE":
        return "<healthcheck 已禁用>"
    if len(test) < 2:
        return "<healthcheck 命令>"
    if mode == "CMD-SHELL":
        # CMD-SHELL: ["CMD-SHELL", "curl -f http://localhost/"]
        return f"sh -c '{test[1]}'"
    elif mode == "CMD":
        # CMD: ["CMD", "curl", "-f", "http://localhost/"]
        return " ".join(test[1:])
    return " ".join(test[1:]) if len(test) > 1 else "<healthcheck 命令>"


def _exit_code_hint(code: int) -> str:
    """退出码含义速查"""
    hints = {
        0: "正常退出（但容器可能因前台进程结束而停止）",
        1: "通用应用错误（配置错误、代码异常等）",
        2: "Shell 内置错误（参数解析失败、命令不存在）",
        125: "Docker 守护进程自身错误",
        126: "命令存在但不可执行（缺少执行权限）",
        127: "命令不存在（PATH 找不到）",
        128: "无效的退出参数",
        137: "被 SIGKILL 杀死（通常是 OOM Killer 或手动 kill -9）",
        139: "段错误（Segmentation Fault，通常是内存非法访问）",
        143: "被 SIGTERM 正常终止（通常是 docker stop 触发）",
    }
    if code in hints:
        return hints[code]
    if 128 < code < 165:
        sig = code - 128
        return f"被信号 {sig} 终止（执行 kill -l {sig} 查看信号名）"
    return f"非标准退出码 {code}，请查看应用日志获取详细错误信息"


def _check_system(diag: Dict, findings: List) -> None:
    """系统异常类检查"""
    inspect = diag.get("inspect", {})
    name = diag["container"]["name"]
    logs = (diag.get("logs_stderr", "") + "\n" + diag.get("logs_stdout", "")).lower()
    # State.Error 也纳入模式匹配
    state_error = (inspect.get("state_error", "") or "").lower()
    if state_error:
        logs = logs + "\n" + state_error
    host = diag.get("host_resources", {})

    # Docker 守护进程波动
    daemon_patterns = [
        r"docker.*daemon.*not\s*running",
        r"cannot\s*connect\s*to\s*the\s*docker\s*daemon",
        r"connection\s*reset\s*by\s*peer.*docker",
    ]
    for pattern in daemon_patterns:
        if re.search(pattern, logs, re.IGNORECASE):
            _add(
                findings,
                CAT_SYSTEM,
                70,
                "Docker 守护进程异常",
                "Docker daemon 不可达或连接不稳定，容器因无法与 daemon 通信而被重启。",
                [
                    "# 检查 Docker daemon 状态",
                    "systemctl status docker",
                    "",
                    "# 重启 Docker 服务",
                    "systemctl restart docker",
                    "",
                    "# 查看 Docker daemon 日志",
                    "journalctl -u docker --since '10 min ago'",
                ],
                "监控 Docker daemon 的 uptime 指标。配置 systemd 自动恢复策略。",
            )
            break

    # 存储驱动异常
    storage_patterns = [
        r"storage\s*driver.*error",
        r"failed\s*to.*mount.*overlay",
        r"no\s*space\s*left\s*on\s*device",
        r"i/o\s*error",
        r"read.?\s*only\s*file\s*system",
    ]
    for pattern in storage_patterns:
        if re.search(pattern, logs, re.IGNORECASE):
            _add(
                findings,
                CAT_SYSTEM,
                72,
                "存储驱动异常",
                "Docker 存储驱动（overlay2/devicemapper）发生 I/O 错误或空间耗尽，"
                "导致容器层无法正常读写。",
                [
                    "# 检查存储驱动状态",
                    "docker info | grep -i storage",
                    "",
                    "# 检查磁盘 I/O 错误",
                    "dmesg | grep -i 'i/o error' | tail -10",
                    "",
                    "# 检查文件系统一致性",
                    "fsck -n /dev/sda1  # 只读检查，不加 -n 会修改",
                ],
                "定期检查磁盘健康（smartctl）。保持 Docker 数据分区使用率 <80%。",
            )
            break

    # 网络策略拦截
    net = diag.get("network", {})
    ping_status = net.get("ping", "")
    if "不可达" in ping_status or "无 IP" in ping_status:
        _add(
            findings,
            CAT_SYSTEM,
            65,
            f"容器网络异常（ping: {ping_status}）",
            "容器网络配置异常或网络策略拦截了容器间通信。"
            "可能原因：Docker 网络损坏、iptables/nftables 规则冲突、容器未正确获取 IP。",
            [
                "# 检查容器网络配置",
                f"docker network inspect $(docker inspect {name} --format '{{{{range .NetworkSettings.Networks}}}}{{{{.NetworkID}}}}{{{{end}}}}')",
                "",
                "# 重建容器网络",
                f"docker network disconnect <网络名> {name} 2>/dev/null; docker network connect <网络名> {name}",
                "",
                "# 检查防火墙规则是否拦截 Docker 网桥",
                "iptables -L FORWARD -n | head -20",
            ],
            "避免手动修改 Docker 生成的 iptables/nftables 规则。"
            "使用 ./up.sh 内置的 firewall-check 进行预检。",
        )


# ─── 报告输出 ────────────────────────────────────────────────────────────


def format_report(
    diag: Dict[str, Any],
    findings: List[Dict[str, Any]],
) -> str:
    """生成人类可读的结构化分析报告"""
    c = diag["container"]
    lines = []
    sep = "=" * 70

    lines.append(sep)
    lines.append(f"  Docker 容器重启根因分析报告")
    lines.append(f"  生成时间: {diag['collected_at']}")
    lines.append(sep)
    lines.append("")

    # 容器基本信息
    lines.append("── 容器基本信息 ──")
    lines.append(f"  名称:     {c['name']}")
    lines.append(f"  ID:       {c['id']}")
    lines.append(f"  镜像:     {c['image']}")
    lines.append(f"  状态:     {c['status']}")
    rc = diag.get("inspect", {}).get("restart_count", 0)
    lines.append(f"  重启次数: {rc}")
    lines.append("")

    # 宿主机资源概要
    host = diag.get("host_resources", {})
    mem = host.get("memory")
    if mem:
        lines.append("── 宿主机资源 ──")
        lines.append(f"  CPU 核心:  {host.get('cpu_cores', '?')}")
        load = host.get("load_avg")
        if load:
            lines.append(f"  负载:     {load['1min']} / {load['5min']} / {load['15min']}")
        lines.append(f"  内存:     {mem['used_mb']}MB / {mem['total_mb']}MB ({mem['usage_percent']}%)")
        lines.append("")

    # 根因分析结果
    if findings:
        lines.append(f"── 根因分析结果（共 {len(findings)} 项，按置信度排序）──")
        for i, f in enumerate(findings, 1):
            lines.append("")
            lines.append(f"  [{i}] {f['category']}（置信度: {f['confidence']}%）")
            lines.append(f"  问题描述:")
            for fl in f["description"].splitlines():
                lines.append(f"    {fl}")
            lines.append(f"  根因说明:")
            for fl in f["root_cause"].splitlines():
                lines.append(f"    {fl}")
            lines.append(f"  修复命令:")
            for cmd in f["fix_commands"]:
                lines.append(f"    {cmd}")
            lines.append(f"  预防建议:")
            lines.append(f"    {f['prevention']}")
    else:
        lines.append("── 根因分析结果 ──")
        lines.append("  未匹配到已知根因模式，建议手动检查以下日志：")
        lines.append(f"  docker logs --tail 100 {c['name']}")

    lines.append("")
    lines.append("── 最近日志（stderr 优先）──")
    stderr = diag.get("logs_stderr", "").strip()
    stdout = diag.get("logs_stdout", "").strip()
    if stderr:
        lines.append(stderr)
    elif stdout:
        lines.append(stdout)
    else:
        lines.append("  （无日志输出）")

    # 健康检查日志（从 inspect 中提取，不依赖容器运行状态）
    health_log = diag.get("inspect", {}).get("health_log", [])
    if health_log:
        lines.append("")
        lines.append("── 健康检查日志（最近 5 条）──")
        for entry in health_log:
            exit_code = entry.get("exit_code", "?")
            start = entry.get("start", "?")
            output = entry.get("output", "").strip()
            status_mark = "✓" if exit_code == 0 else "✗"
            lines.append(f"  [{status_mark}] {start} (exit={exit_code})")
            if output:
                for ol in output.splitlines()[:5]:
                    lines.append(f"      {ol}")

    lines.append("")
    lines.append(sep)
    return "\n".join(lines)


def format_webhook(
    diag: Dict[str, Any],
    findings: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """生成企业微信/钉钉 webhook 消息体（Markdown 格式）"""
    c = diag["container"]
    md_lines = [
        f"### Docker 容器重启告警",
        f"> **容器**: `{c['name']}` ({c['id'][:12]})",
        f"> **镜像**: {c['image']}",
        f"> **状态**: {c['status']}",
        f"> **重启次数**: {diag.get('inspect', {}).get('restart_count', 0)}",
        f"> **时间**: {diag['collected_at']}",
        "",
    ]
    if findings:
        md_lines.append(f"**根因分析（{len(findings)} 项）**:")
        for i, f in enumerate(findings[:3], 1):  # webhook 最多 3 条
            md_lines.append(f"\n**{i}. {f['category']}**（{f['confidence']}%）")
            md_lines.append(f"- {f['description'].splitlines()[0]}")
            md_lines.append(f"- 修复: `{f['fix_commands'][-1] if f['fix_commands'] else 'N/A'}`")
    else:
        md_lines.append("**未匹配到已知根因，请手动检查日志**")

    # 企业微信格式
    return {
        "msgtype": "markdown",
        "markdown": {
            "content": "\n".join(md_lines),
        },
    }


def send_webhook(url: str, payload: Dict[str, Any], timeout: int = 10) -> bool:
    """发送 webhook 通知"""
    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status < 300
    except (urllib.error.URLError, OSError) as e:
        log(f"webhook 发送失败: {e}", "ERROR")
        return False


# ─── 配置构建 ────────────────────────────────────────────────────────────


def build_config(args: argparse.Namespace) -> Dict[str, Any]:
    """构建运行配置：CLI 参数优先，未指定则使用内置默认值"""
    cfg = {
        "interval": args.interval or DEFAULT_INTERVAL,
        "log_lines": args.log_lines or DEFAULT_LOG_LINES,
        "restart_threshold": args.restart_threshold or DEFAULT_RESTART_THRESHOLD,
        "log_file": args.log_file or DEFAULT_LOG_FILE,
        "webhook_url": args.webhook or DEFAULT_WEBHOOK_URL,
        "once": args.once,
        "dry_run": args.dry_run,
        "report_dir": args.report_dir or DEFAULT_REPORT_DIR,
    }
    return cfg


# ─── 主逻辑 ──────────────────────────────────────────────────────────────

_running = True


def _signal_handler(signum, frame):
    global _running
    _running = False
    log(f"收到信号 {signum}，正在优雅退出...", "INFO")


def check_permissions(docker: DockerClient) -> bool:
    """检查当前用户是否有 Docker 操作权限"""
    if not shutil.which("docker"):
        log("docker 客户端未安装或不在 PATH 中", "ERROR")
        log("安装方式:", "ERROR")
        log("  Ubuntu/Debian: apt-get install -y docker.io", "ERROR")
        log("  CentOS/RHEL:   yum install -y docker", "ERROR")
        log("  Arch:          pacman -S docker", "ERROR")
        return False

    if not docker.available():
        log("当前用户无法访问 Docker 守护进程", "ERROR")
        log("解决方案:", "ERROR")
        log("  方案 1: sudo usermod -aG docker $USER && newgrp docker", "ERROR")
        log("  方案 2: sudo systemctl start docker", "ERROR")
        log("  方案 3: 使用 sudo 运行本脚本", "ERROR")
        return False

    return True


def analyze_container(
    docker: DockerClient,
    container: Dict[str, Any],
    config: Dict[str, Any],
    analyzed: set,
) -> Optional[str]:
    """分析单个 Restarting 容器，返回报告字符串（或 None）"""
    cid = container["id"]
    if cid in analyzed:
        return None
    analyzed.add(cid)

    name = container["name"]
    log(f"开始分析容器: {name} ({cid[:12]})")

    try:
        diag = collect_diagnostics(docker, container, config)
    except Exception as e:
        log(f"采集诊断数据失败: {name}: {e}", "ERROR")
        return None

    # 重启次数阈值过滤
    rc = diag.get("restart_count", 0)
    threshold = config["restart_threshold"]
    if rc < threshold:
        log(f"容器 {name} 重启次数 {rc} < 阈值 {threshold}，跳过分析")
        return None

    findings = analyze_root_causes(diag)
    report = format_report(diag, findings)
    print(report)

    # 写入报告文件
    report_dir = config.get("report_dir")
    if report_dir:
        os.makedirs(report_dir, exist_ok=True)
        report_path = os.path.join(report_dir, f"{name}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt")
        try:
            with open(report_path, "w", encoding="utf-8") as f:
                f.write(report)
            log(f"报告已保存: {report_path}")
        except OSError as e:
            log(f"报告保存失败: {e}", "ERROR")

    # 写入结构化 JSON（供日志系统接入）
    report_dir = config.get("report_dir")
    if report_dir:
        json_path = os.path.join(report_dir, f"{name}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json")
        try:
            structured = {
                "timestamp": diag["collected_at"],
                "container": container,
                "exit_code": diag["inspect"].get("exit_code"),
                "restart_count": rc,
                "oom_killed": diag["inspect"].get("oom_killed"),
                "findings": findings,
                "host_memory_usage": diag.get("host_resources", {}).get("memory", {}).get("usage_percent"),
            }
            with open(json_path, "w", encoding="utf-8") as f:
                json.dump(structured, f, ensure_ascii=False, indent=2)
        except OSError:
            pass

    # webhook 通知
    webhook_url = config.get("webhook_url")
    if webhook_url:
        payload = format_webhook(diag, findings)
        if send_webhook(webhook_url, payload):
            log(f"webhook 通知已发送")
        else:
            log(f"webhook 通知发送失败", "WARN")

    return report


def run_once(docker: DockerClient, config: Dict[str, Any], analyzed: set) -> int:
    """执行单次扫描"""
    restarting = docker.list_restarting()
    if not restarting:
        log("未检测到 Restarting 状态的容器")
        return 0

    log(f"检测到 {len(restarting)} 个 Restarting 容器: {[c['name'] for c in restarting]}")
    count = 0
    for container in restarting:
        if analyze_container(docker, container, config, analyzed) is not None:
            count += 1
    return count


def run_daemon(docker: DockerClient, config: Dict[str, Any]) -> None:
    """守护模式：持续轮询"""
    interval = config["interval"]
    analyzed: set = set()

    log(f"守护模式启动，轮询间隔 {interval}s，重启阈值 {config['restart_threshold']}")

    while _running:
        try:
            run_once(docker, config, analyzed)

            # 每隔一段时间清理已分析集合，允许后续重新分析
            # 当容器从 Restarting 恢复后再次进入 Restarting 时能再次触发
            time.sleep(interval)
            # 清理已分析集合中不再 restarting 的容器
            current_restarting = {c["id"] for c in docker.list_restarting()}
            analyzed &= current_restarting

        except KeyboardInterrupt:
            break
        except Exception as e:
            log(f"轮询周期异常: {e}", "ERROR")
            time.sleep(interval)

    log("守护模式已退出")


# ─── CLI ────────────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    """构建命令行参数解析器"""
    p = argparse.ArgumentParser(
        prog=SCRIPT_NAME,
        description="Docker 容器重启根因自动分析工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用示例:
  # 单次扫描
  %(prog)s --once

  # 守护模式
  %(prog)s --interval 30 --restart-threshold 3

  # 带日志和 webhook
  %(prog)s --log-file /var/log/docker-restart.log \\
      --webhook https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx
""",
    )
    p.add_argument("--version", action="version", version=f"{SCRIPT_NAME} v{VERSION}")

    mode = p.add_argument_group("运行模式")
    mode.add_argument("--once", action="store_true", help="仅执行一次扫描后退出")
    mode.add_argument("--dry-run", action="store_true", help="干跑模式（不发送 webhook、不写报告文件）")

    poll = p.add_argument_group("轮询配置")
    poll.add_argument("--interval", type=int, metavar="N", help=f"轮询间隔（秒，默认 {DEFAULT_INTERVAL}）")
    poll.add_argument("--log-lines", type=int, metavar="N", help=f"采集日志行数（默认 {DEFAULT_LOG_LINES}）")
    poll.add_argument("--restart-threshold", type=int, metavar="N", help=f"触发分析的最小重启次数（默认 {DEFAULT_RESTART_THRESHOLD}）")

    output = p.add_argument_group("输出配置")
    output.add_argument("--log-file", metavar="PATH", help="日志输出文件路径")
    output.add_argument("--report-dir", metavar="DIR", help="分析报告输出目录（同时生成 .txt 和 .json）")
    output.add_argument("--webhook", metavar="URL", help="企业微信/钉钉 webhook 地址")

    adv = p.add_argument_group("高级")
    adv.add_argument("--docker-bin", metavar="PATH", help="docker 客户端路径（默认自动检测）")

    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    # 构建配置
    config = build_config(args)

    log_file = config.get("log_file")
    log(f"{SCRIPT_NAME} v{VERSION} 启动", "INFO", log_file)

    # dry-run 模式
    if config["dry_run"]:
        log("干跑模式：将跳过 webhook 发送和报告文件写入", "WARN", log_file)

    # 权限校验
    docker = DockerClient(args.docker_bin)
    if not check_permissions(docker):
        return 3

    # 注册信号
    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    if config["once"]:
        count = run_once(docker, config, set())
        log(f"扫描完成，分析了 {count} 个容器", "INFO", log_file)
        return 0
    else:
        run_daemon(docker, config)
        return 0


if __name__ == "__main__":
    sys.exit(main())
