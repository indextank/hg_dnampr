#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
╔══════════════════════════════════════════════════════════════════════════════╗
║           MySQL 健康自动化检测分析脚本 (MySQL Health Inspector)              ║
║                      v1.0.0 — 2025-05-18                                   ║
╚══════════════════════════════════════════════════════════════════════════════╝

概览：
  本脚本自动检测本机所有运行中的 Docker MySQL 容器，逐一连接采集运行状态、
  核心性能参数及安全配置，结合宿主机硬件配置生成包含以下五大部分的完整诊断报告：
    1.  服务器基础配置摘要
    2.  MySQL 实例核心运行指标统计
    3.  性能短板分析（含与生产基准参数的比对结论）
    4.  安全配置合规性检查（高危 / 中危 / 低危风险分级）
    5.  针对性优化建议

输出：Markdown 格式报告，同时打印到 stdout。

═══════════════════════════════════════════════════════════════════════════════
                            依赖清单 (Dependencies)
═══════════════════════════════════════════════════════════════════════════════

  [系统层]
    - docker CLI               (从容器列表自动发现 MySQL 实例)
    - 标准 Linux 工具           (nproc、free、lsblk、df 等)

  [Python 3 包]
    - PyMySQL >= 1.1            MySQL 纯 Python 客户端
    - PyYAML >= 6.0             (仅解析 compose 配置时使用，可选)

  自动安装（如缺失）：
    pip3 install PyMySQL PyYAML

═══════════════════════════════════════════════════════════════════════════════
                            使用方法 (Usage)
═══════════════════════════════════════════════════════════════════════════════

  # 基础用法（自动检测所有 Docker MySQL 容器）
  python3 scripts/mysql_health_inspector.py

  # 指定输出报告路径
  python3 scripts/mysql_health_inspector.py --output /tmp/mysql_report.md

  # 仅检测特定容器
  python3 scripts/mysql_health_inspector.py --container mysql

  # 指定 MySQL 密码（优先级：命令行 > 环境变量 > compose 文件解析）
  python3 scripts/mysql_health_inspector.py --password 'xxxx'

  # 详细日志
  python3 scripts/mysql_health_inspector.py --verbose

  # 查看帮助
  python3 scripts/mysql_health_inspector.py --help

═══════════════════════════════════════════════════════════════════════════════
                        凭证注入方式（按优先级）
═══════════════════════════════════════════════════════════════════════════════

  1. 命令行参数    --user root --password 'xxx'
  2. 环境变量      MYSQL_INSPECTOR_USER / MYSQL_INSPECTOR_PASSWORD
  3. 自动解析      compose/stacks/databases.yaml → .env 链路获取 root 密码
  4. 兜底交互      （非静默模式下提示输入）

═══════════════════════════════════════════════════════════════════════════════
                          常见问题排查 (FAQ)
═══════════════════════════════════════════════════════════════════════════════

  Q: 提示 "docker: command not found"
  A: 确保 docker CLI 可执行，且当前用户属于 docker 组。

  Q: 容器内无 mysql 客户端时如何连接？
  A: 脚本使用 PyMySQL 直接通过 TCP 连接，不依赖容器内 mysql 命令。

  Q: 多实例并行检测怎么做到？
  A: 使用 Python concurrent.futures.ThreadPoolExecutor，每个实例独立线程。

  Q: 报告生成在哪里？
  A: 默认输出到 ./logs/mysql_health_report_<timestamp>.md

═══════════════════════════════════════════════════════════════════════════════
"""

import argparse
import concurrent.futures
import datetime
import json
import logging
import os
import platform
import re
import shlex
import socket
import subprocess
import sys
import time
from collections import OrderedDict
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# 日志配置
# ---------------------------------------------------------------------------
LOG = logging.getLogger("mysql-inspector")


def setup_logging(verbose: bool = False) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    fmt = logging.Formatter(
        "[%(asctime)s] %(levelname)-7s %(message)s", datefmt="%H:%M:%S"
    )
    h = logging.StreamHandler()
    h.setFormatter(fmt)
    LOG.setLevel(level)
    LOG.addHandler(h)
    LOG.propagate = False


# ---------------------------------------------------------------------------
# 自动安装依赖
# ---------------------------------------------------------------------------
def ensure_dependencies() -> None:
    """检查并自动安装缺失的 Python 依赖包。"""
    missing = []
    for pkg_name, import_name in [("PyMySQL", "pymysql")]:
        try:
            __import__(import_name)
        except ImportError:
            missing.append(pkg_name)
    if missing:
        LOG.info("检测到缺失依赖: %s，正在自动安装...", missing)
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "--quiet"] + missing,
            stdout=sys.stderr,
        )
        LOG.info("依赖安装完成，请重新运行脚本。")
        sys.exit(0)


# ---------------------------------------------------------------------------
# 系统层信息采集
# ---------------------------------------------------------------------------
def run_shell(cmd: str, timeout: int = 15) -> str:
    """执行 shell 命令，返回去空白后的输出。"""
    try:
        r = subprocess.run(
            ["bash", "-c", cmd],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return r.stdout.strip()
    except Exception as e:
        LOG.warning("命令执行失败 [%s]: %s", cmd, e)
        return ""


def collect_system_info() -> Dict[str, Any]:
    """采集宿主机硬件配置与系统信息。"""
    LOG.info("正在采集宿主机系统信息...")

    info: Dict[str, Any] = OrderedDict()

    # OS 信息
    os_release = ""
    for f in ["/etc/os-release", "/etc/redhat-release"]:
        if os.path.exists(f):
            os_release = run_shell(f"head -3 {f} 2>/dev/null")
            break
    info["os"] = {
        "hostname": socket.gethostname(),
        "kernel": platform.release(),
        "arch": platform.machine(),
        "distro": os_release.split("\n")[0] if os_release else "unknown",
    }

    # CPU
    cpu_cores = int(run_shell("nproc") or "0")
    cpu_model = run_shell(
        'lscpu 2>/dev/null | grep "Model name" | head -1 | cut -d: -f2'
    )
    info["cpu"] = {
        "cores": cpu_cores,
        "model": (cpu_model or "unknown").strip(),
    }

    # 内存 (GB)
    mem_kb = 0
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                mem_kb = int(line.split()[1])
                break
    mem_gb = round(mem_kb / 1024 / 1024, 2)
    info["memory"] = {
        "total_gb": mem_gb,
    }

    # 磁盘
    disks = []
    for line in run_shell("lsblk -d -o NAME,SIZE,TYPE,ROTA -n 2>/dev/null").split("\n"):
        parts = line.strip().split()
        if len(parts) >= 3 and parts[2] == "disk":
            disks.append(
                {
                    "name": parts[0],
                    "size": parts[1],
                    "rotational": parts[3] == "1" if len(parts) > 3 else None,
                }
            )
    info["disks"] = disks

    # MySQL 数据目录所在挂载点
    mysql_data_paths = [
        "/data/volume_data/mysql",
        "/var/lib/docker/volumes",
    ]
    disk_usage = {}
    for p in mysql_data_paths:
        if os.path.exists(p):
            out = run_shell(f"df -h {p} 2>/dev/null | tail -1")
            if out:
                parts = out.split()
                if len(parts) >= 6:
                    disk_usage[p] = {
                        "filesystem": parts[0],
                        "size": parts[1],
                        "used": parts[2],
                        "avail": parts[3],
                        "use_pct": parts[4],
                        "mount": parts[5],
                    }
    info["disk_usage"] = disk_usage

    # IO 调度器
    io_schedulers = run_shell(
        "for d in /sys/block/vd* /sys/block/sd* /sys/block/nvme*; do "
        '[ -f $d/queue/scheduler ] && echo "$(basename $d)=$(cat $d/queue/scheduler)"; done 2>/dev/null'
    )
    info["io_scheduler"] = io_schedulers

    # Docker 信息
    info["docker"] = {
        "version": run_shell("docker --version 2>/dev/null") or "未安装",
        "running_containers": int(run_shell("docker ps -q 2>/dev/null | wc -l") or 0),
    }

    return info


# ---------------------------------------------------------------------------
# Docker MySQL 实例发现
# ---------------------------------------------------------------------------
def discover_mysql_containers() -> List[Dict[str, str]]:
    """发现所有运行中且包含 MySQL/MariaDB 的 Docker 容器。"""
    LOG.info("正在发现 Docker MySQL 容器...")

    # 获取所有运行中容器的基础信息
    cmd = (
        "docker ps --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Ports}}\\t{{.Status}}' "
        "2>/dev/null"
    )
    out = run_shell(cmd)

    # 收集 MySQL/MariaDB 镜像 ID（本地的完整仓库镜像）
    mysql_image_ids: set = set()
    images_raw = run_shell(
        "docker images --format '{{.ID}}\\t{{.Repository}}' 2>/dev/null"
    )
    for line in images_raw.split("\n"):
        parts = line.strip().split("\t")
        if len(parts) >= 2:
            img_id, repo = parts[0], parts[1].lower()
            if any(kw in repo for kw in ["mysql", "mariadb"]):
                mysql_image_ids.add(img_id[:12])

    # 获取每个容器的镜像短 ID（用于无 tag 镜像匹配）
    container_image_ids: Dict[str, str] = {}
    inspect_ids = run_shell(
        "docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Id}} {{.Image}}' 2>/dev/null"
    )
    for line in inspect_ids.split("\n"):
        parts = line.strip().split()
        if len(parts) >= 2:
            cid = parts[0][:12]
            img_id = parts[1].split(":")[-1][:12] if ":" in parts[1] else parts[1][:12]
            container_image_ids[cid] = img_id

    containers = []
    for line in out.split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        cid, name, image, ports, status = (
            parts[0][:12],
            parts[1],
            parts[2],
            parts[3],
            parts[4] if len(parts) > 4 else "",
        )

        # 识别 MySQL 容器：镜像仓库名或镜像 ID 匹配
        image_lower = image.lower()
        is_mysql = any(kw in image_lower for kw in ["mysql", "mariadb"])
        if not is_mysql:
            # 无 tag 镜像：通过容器关联的镜像 ID 匹配
            c_img_id = container_image_ids.get(cid, "")[:12]
            if c_img_id and c_img_id in mysql_image_ids:
                is_mysql = True
            # 直接通过 docker inspect 检查当前容器使用的镜像 repo
            if not is_mysql:
                inspect_out = run_shell(
                    f"docker inspect --format '{{{{.Config.Image}}}}' {cid} 2>/dev/null"
                )
                if any(kw in inspect_out.lower() for kw in ["mysql", "mariadb"]):
                    is_mysql = True

        if is_mysql:
            port_map = _parse_docker_ports(ports)
            containers.append(
                {
                    "id": cid,
                    "name": name,
                    "image": image,
                    "host_port": port_map.get("3306", "3306"),
                    "status": status,
                }
            )
    LOG.info(
        "发现 %d 个 MySQL 容器: %s", len(containers), [c["name"] for c in containers]
    )
    return containers


def _parse_docker_ports(ports_str: str) -> Dict[str, str]:
    """解析 docker ports 字符串，提取 tcp 映射。"""
    mapping: Dict[str, str] = {}
    # 格式: 0.0.0.0:3306->3306/tcp, :::3306->3306/tcp
    for token in ports_str.split(","):
        token = token.strip()
        m = re.search(r"(\d+)->(\d+)/tcp", token)
        if m:
            mapping[m.group(2)] = m.group(1)
    return mapping


# ---------------------------------------------------------------------------
# 凭证解析
# ---------------------------------------------------------------------------
def resolve_mysql_credentials(
    args_user: Optional[str],
    args_password: Optional[str],
    project_dir: str,
) -> Tuple[str, str, str]:
    """
    按优先级解析 MySQL 连接凭证：
    1. 命令行参数
    2. 环境变量 MYSQL_INSPECTOR_USER / MYSQL_INSPECTOR_PASSWORD
    3. 自动解析当前项目的 compose → .env → .env.local
    4. 环境变量 MYSQL_ROOT_PASSWORD（通用）
    """
    user = args_user or os.environ.get("MYSQL_INSPECTOR_USER")
    password = args_password or os.environ.get("MYSQL_INSPECTOR_PASSWORD")
    host = os.environ.get("MYSQL_INSPECTOR_HOST", "127.0.0.1")

    if not user or not password:
        root_pwd = _parse_env_chain(project_dir)
        if root_pwd:
            if not user:
                user = "root"
            if not password:
                password = root_pwd

    if not password:
        password = os.environ.get("MYSQL_ROOT_PASSWORD", "")

    return user or "root", password or "", host


def _parse_env_chain(project_dir: str) -> Optional[str]:
    """从 compose/stacks/databases.yaml → .env 链路解析 MySQL 密码。"""
    candidates = []

    # 方法1：从 .env.local 读取
    env_local = os.path.join(project_dir, ".env.local")
    if os.path.exists(env_local):
        pwd = _grep_env(env_local, "MYSQL_ROOT_PASSWORD")
        if pwd:
            candidates.append(pwd)

    # 方法2：从 .env 读取
    env_file = os.path.join(project_dir, ".env")
    if os.path.exists(env_file):
        pwd = _grep_env(env_file, "MYSQL_ROOT_PASSWORD")
        if pwd:
            candidates.append(pwd)

    return candidates[0] if candidates else None


def _grep_env(filepath: str, key: str) -> Optional[str]:
    """从 .env 文件中读取指定 key 的值。"""
    try:
        with open(filepath) as f:
            for line in f:
                line = line.strip()
                if line.startswith(f"{key}=") or line.startswith(f"{key} "):
                    val = line.split("=", 1)[-1].strip()
                    val = val.strip("\"'")
                    return val if val else None
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# MySQL 连接与数据采集
# ---------------------------------------------------------------------------
class MySQLCollector:
    """连接单个 MySQL 实例并采集诊断数据。"""

    def __init__(self, host: str, port: int, user: str, password: str, name: str):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.name = name
        self.conn = None

    def connect(self) -> bool:
        """建立连接，支持重试。"""
        import pymysql

        for attempt in range(3):
            try:
                self.conn = pymysql.connect(
                    host=self.host,
                    port=self.port,
                    user=self.user,
                    password=self.password,
                    connect_timeout=10,
                    read_timeout=60,
                    charset="utf8mb4",
                )
                LOG.debug("[%s] 连接成功 (尝试 %d/3)", self.name, attempt + 1)
                return True
            except pymysql.MySQLError as e:
                LOG.warning("[%s] 连接失败 (尝试 %d/3): %s", self.name, attempt + 1, e)
                time.sleep(2)
        return False

    def query(self, sql: str) -> List[Tuple]:
        """执行查询，返回结果行列表。"""
        if not self.conn:
            return []
        try:
            with self.conn.cursor() as cur:
                cur.execute(sql)
                return cur.fetchall()
        except Exception as e:
            LOG.warning("[%s] 查询失败: %s", self.name, e)
            return []

    def query_dict(self, sql: str) -> Dict[str, str]:
        """执行两列查询，返回 {name: value} 字典。"""
        rows = self.query(sql)
        return {str(r[0]): str(r[1]) for r in rows if len(r) >= 2}

    def collect(self) -> Dict[str, Any]:
        """执行完整数据采集。"""
        if not self.connect():
            return {"error": "连接失败", "name": self.name}

        LOG.info("[%s] 正在采集数据...", self.name)
        data: Dict[str, Any] = {"name": self.name, "host": self.host, "port": self.port}

        # ── 1. 基本变量 ──
        data["variables"] = self.query_dict(
            "SHOW GLOBAL VARIABLES WHERE Variable_name IN ("
            "'version','innodb_buffer_pool_size','innodb_buffer_pool_instances',"
            "'innodb_redo_log_capacity','innodb_log_file_size','innodb_log_files_in_group',"
            "'innodb_log_buffer_size','innodb_flush_log_at_trx_commit','innodb_flush_method',"
            "'innodb_doublewrite','innodb_io_capacity','innodb_io_capacity_max',"
            "'innodb_read_io_threads','innodb_write_io_threads',"
            "'innodb_thread_concurrency','innodb_lock_wait_timeout','innodb_rollback_on_timeout',"
            "'innodb_print_all_deadlocks','innodb_file_per_table','innodb_open_files',"
            "'innodb_numa_interleave',"
            "'max_connections','thread_cache_size','thread_stack',"
            "'wait_timeout','interactive_timeout','connect_timeout','max_connect_errors',"
            "'skip_name_resolve','host_cache_size',"
            "'tmp_table_size','max_heap_table_size','sort_buffer_size',"
            "'read_buffer_size','read_rnd_buffer_size','join_buffer_size',"
            "'binlog_cache_size','binlog_stmt_cache_size',"
            "'max_binlog_size','sync_binlog','binlog_expire_logs_seconds',"
            "'gtid_mode','enforce_gtid_consistency','log_bin','log_replica_updates',"
            "'binlog_checksum',"
            "'slow_query_log','long_query_time','log_queries_not_using_indexes',"
            "'general_log','log_error_verbosity',"
            "'local_infile','secure_file_priv',"
            "'character_set_server','collation_server',"
            "'default_authentication_plugin','require_secure_transport',"
            "'sql_mode','transaction_isolation','performance_schema',"
            "'table_open_cache','table_definition_cache','open_files_limit',"
            "'server_id',"
            "'innodb_read_io_threads','innodb_write_io_threads'"
            ")"
        )

        # ── 2. 全局状态 ──
        data["status"] = self.query_dict(
            "SHOW GLOBAL STATUS WHERE Variable_name IN ("
            "'Threads_connected','Threads_running','Threads_created','Threads_cached',"
            "'Connections','Max_used_connections','Aborted_clients','Aborted_connects',"
            "'Innodb_buffer_pool_pages_data','Innodb_buffer_pool_pages_free',"
            "'Innodb_buffer_pool_pages_dirty','Innodb_buffer_pool_pages_total',"
            "'Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads',"
            "'Innodb_buffer_pool_wait_free',"
            "'Innodb_buffer_pool_read_ahead','Innodb_buffer_pool_read_ahead_evicted',"
            "'Innodb_rows_deleted','Innodb_rows_inserted','Innodb_rows_read','Innodb_rows_updated',"
            "'Innodb_data_reads','Innodb_data_writes','Innodb_data_read','Innodb_data_written',"
            "'Innodb_data_fsyncs','Innodb_data_pending_reads','Innodb_data_pending_writes',"
            "'Innodb_log_waits','Innodb_log_write_requests','Innodb_log_writes',"
            "'Innodb_os_log_fsyncs','Innodb_row_lock_current_waits','Innodb_row_lock_waits',"
            "'Innodb_row_lock_time','Innodb_row_lock_time_avg','Innodb_row_lock_time_max',"
            "'Table_locks_immediate','Table_locks_waited',"
            "'Created_tmp_disk_tables','Created_tmp_files','Created_tmp_tables',"
            "'Select_full_join','Select_full_range_join','Select_scan','Select_range',"
            "'Sort_merge_passes','Sort_range','Sort_rows','Sort_scan',"
            "'Open_tables','Opened_tables','Table_open_cache_hits','Table_open_cache_misses',"
            "'Table_open_cache_overflows',"
            "'Binlog_cache_use','Binlog_cache_disk_use',"
            "'Slow_queries','Questions','Uptime',"
            "'Qcache_hits','Qcache_inserts'"
            ")"
        )

        # ── 3. 慢查询 digest top 5 ──
        data["top_slow_queries"] = self.query(
            "SELECT SCHEMA_NAME, LEFT(DIGEST_TEXT,200), COUNT_STAR, "
            "ROUND(AVG_TIMER_WAIT/1e12,3), SUM_ROWS_EXAMINED, "
            "ROUND(SUM_TIMER_WAIT/1e12,2) "
            "FROM performance_schema.events_statements_summary_by_digest "
            "WHERE SCHEMA_NAME IS NOT NULL AND SUM_TIMER_WAIT > 0 "
            "ORDER BY SUM_TIMER_WAIT DESC LIMIT 5"
        )

        # ── 4. 无主键 InnoDB 表 ──
        data["no_pk_tables"] = self.query(
            "SELECT t.TABLE_SCHEMA, t.TABLE_NAME, t.TABLE_ROWS, "
            "ROUND((t.DATA_LENGTH + t.INDEX_LENGTH)/1024/1024,1) "
            "FROM information_schema.TABLES t "
            "LEFT JOIN information_schema.TABLE_CONSTRAINTS c "
            "ON t.TABLE_SCHEMA=c.TABLE_SCHEMA AND t.TABLE_NAME=c.TABLE_NAME "
            "AND c.CONSTRAINT_TYPE='PRIMARY KEY' "
            "WHERE t.TABLE_TYPE='BASE TABLE' AND t.ENGINE='InnoDB' "
            "AND c.CONSTRAINT_NAME IS NULL "
            "AND t.TABLE_SCHEMA NOT IN ('information_schema','mysql','performance_schema','sys') "
            "ORDER BY (t.DATA_LENGTH + t.INDEX_LENGTH) DESC LIMIT 30"
        )

        # ── 5. Top 10 大表 ──
        data["top_big_tables"] = self.query(
            "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROWS, "
            "ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024,1) total_mb "
            "FROM information_schema.TABLES "
            "WHERE TABLE_TYPE='BASE TABLE' "
            "AND TABLE_SCHEMA NOT IN ('information_schema','mysql','performance_schema','sys') "
            "ORDER BY DATA_LENGTH+INDEX_LENGTH DESC LIMIT 10"
        )

        # ── 6. 当前 processlist ──
        data["processlist_long"] = self.query(
            "SELECT ID, USER, DB, COMMAND, TIME, STATE, LEFT(INFO,150) "
            "FROM information_schema.PROCESSLIST "
            "WHERE COMMAND != 'Sleep' AND TIME > 5 ORDER BY TIME DESC LIMIT 15"
        )

        self.conn.close()
        LOG.info("[%s] 采集完成", self.name)
        return data


# ---------------------------------------------------------------------------
# 基准配置定义
# ---------------------------------------------------------------------------
BASELINE = {
    # 性能参数：{key: (推荐值, 严重偏差阈值%, 说明)}
    "innodb_buffer_pool_size": (
        "16G",
        60,
        "InnoDB 缓冲池大小，影响缓存命中率和物理磁盘读。"
        "建议设置为总内存的 25~50%（生产环境），默认 128M 远不够",
    ),
    "innodb_buffer_pool_instances": (
        "8+",
        40,
        "缓冲池实例数，建议匹配 pool_size(GB) 以减小 mutex 争用",
    ),
    "innodb_redo_log_capacity": (
        "1G",
        50,
        "Redo Log 容量（8.0.30+），替代 innodb_log_file_size。太小会导致频繁 checkpoint",
    ),
    "innodb_flush_log_at_trx_commit": (
        "1",
        0,
        "日志刷新策略：生产必须为 1（每次提交 fsync），2 可能丢失最后一秒数据",
    ),
    "sync_binlog": (
        "1",
        0,
        "Binlog 同步策略：生产必须为 1",
    ),
    "innodb_doublewrite": (
        "ON",
        0,
        "双写缓冲，防页撕裂，生产必须开启",
    ),
    "innodb_flush_method": (
        "O_DIRECT",
        0,
        "IO 刷写方法，避免 OS 页缓存双重缓冲",
    ),
    "innodb_io_capacity": (
        "2000",
        50,
        "InnoDB 后台 IO 能力，HDD=200, SATA SSD=2000, NVMe SSD=5000+",
    ),
    "innodb_io_capacity_max": (
        "4000",
        50,
        "InnoDB 最大 IO 能力，建议为 io_capacity 的 2 倍",
    ),
    "innodb_read_io_threads": (
        "8+",
        30,
        "后台读 IO 线程数，建议 = CPU 核数",
    ),
    "innodb_write_io_threads": (
        "4+",
        30,
        "后台写 IO 线程数，建议 = CPU 核数的 50%",
    ),
    "thread_cache_size": (
        "50+",
        50,
        "连接线程缓存。若 Threads_created 增长快则需要增大",
    ),
    "max_connections": (
        "300",
        50,
        "最大连接数。过大浪费 per-thread 内存，需根据实际峰值调整",
    ),
    "wait_timeout": (
        "3600",
        50,
        "空闲连接超时。过大导致连接堆积，过小导致频繁重连",
    ),
    "innodb_lock_wait_timeout": (
        "50",
        30,
        "行锁等待超时，建议 30~120 秒",
    ),
    "innodb_log_buffer_size": (
        "64M",
        50,
        "日志缓冲区，大事务写 Binlog 和 Redo Log 时避免溢出",
    ),
    "binlog_cache_size": (
        "256K",
        50,
        "Binlog 事务缓存。若 Binlog_cache_disk_use > 0 说明需要增大",
    ),
    "sort_buffer_size": (
        "2M",
        30,
        "排序缓冲区（per-thread）。过大导致高并发时内存耗尽",
    ),
    "join_buffer_size": (
        "2M",
        30,
        "JOIN 缓冲区（per-thread）。同上",
    ),
    "tmp_table_size": (
        "256M",
        30,
        "内存临时表最大大小。若有 Created_tmp_disk_tables > 0 需增大",
    ),
    "table_open_cache": (
        "8000",
        30,
        "表缓存数量。若 Opened_tables 增长快则需要增大",
    ),
    # 安全参数
    "require_secure_transport": (
        "OFF",
        0,
        "强制 SSL。内网 Docker 环境可 OFF，公网需 ON",
    ),
    "local_infile": ("OFF", 0, "是否允许 LOAD DATA LOCAL，生产必须为 0"),
    "general_log": ("OFF", 0, "通用查询日志，生产必须关闭"),
    "slow_query_log": ("ON", 0, "慢查询日志，建议开启"),
    "log_queries_not_using_indexes": ("OFF", 0, "未用索引的查询记录，排查阶段临时开启"),
    "performance_schema": ("ON", 0, "性能监控引擎，生产应开启"),
    "skip_name_resolve": ("ON", 0, "跳过 DNS 解析，避免连接延迟"),
    "sql_mode": (
        "STRICT_TRANS_TABLES",
        0,
        "SQL 模式。应包含 STRICT_TRANS_TABLES 防止错误数据写入",
    ),
    "gtid_mode": ("ON", 0, "GTID 复制模式，有复制需求应开启"),
    "enforce_gtid_consistency": ("ON", 0, "配合 gtid_mode，保证 GTID 一致性"),
}


# ---------------------------------------------------------------------------
# 分析引擎
# ---------------------------------------------------------------------------
def _parse_size_bytes(val: str) -> int:
    """将 MySQL 内存/大小值转为字节数（支持 K/M/G/T 单位）。"""
    val = str(val).strip().upper()
    if not val:
        return 0
    m = re.match(r"^(-?\s*[\d.]+)\s*([KMGT]?)B?", val)
    if not m:
        return int(float(val)) if val.replace(".", "").isdigit() else 0
    num = float(m.group(1))
    unit = m.group(2)
    mult = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}
    return int(num * mult.get(unit, 1))


def _is_on(val: str) -> bool:
    return str(val).upper() in ("ON", "1", "YES", "TRUE")


def analyze_instance(data: Dict[str, Any], sys_info: Dict[str, Any]) -> Dict[str, Any]:
    """对单个实例的数据进行全面分析。"""
    if "error" in data:
        return {"name": data["name"], "error": data["error"]}

    var = {k.lower(): v for k, v in data.get("variables", {}).items()}
    stat = {k.lower(): v for k, v in data.get("status", {}).items()}

    report: Dict[str, Any] = {
        "name": data["name"],
        "version": var.get("version", "unknown"),
        "uptime_seconds": int(stat.get("uptime", 0)),
        "issues": OrderedDict(),
        "stats": OrderedDict(),
    }

    # ── 核心指标 ──
    bp_total = int(stat.get("innodb_buffer_pool_pages_total", 0)) * 16384
    bp_data = int(stat.get("innodb_buffer_pool_pages_data", 0)) * 16384
    bp_free = int(stat.get("innodb_buffer_pool_pages_free", 0)) * 16384
    bp_reads = int(stat.get("innodb_buffer_pool_reads", 0))
    bp_read_req = int(stat.get("innodb_buffer_pool_read_requests", 0))

    bp_hit_pct = (
        round(100 - (bp_reads / max(bp_read_req, 1) * 100), 2)
        if bp_read_req > 0
        else 100
    )

    report["stats"]["buffer_pool"] = {
        "size_gb": round(
            _parse_size_bytes(var.get("innodb_buffer_pool_size", "0")) / 1024**3, 2
        ),
        "data_gb": round(bp_data / 1024**3, 2),
        "free_gb": round(bp_free / 1024**3, 2),
        "hit_rate_pct": bp_hit_pct,
        "physical_reads": bp_reads,
        "wait_free": int(stat.get("innodb_buffer_pool_wait_free", 0)),
        "read_ahead_evicted": int(stat.get("innodb_buffer_pool_read_ahead_evicted", 0)),
    }

    # 连接状态
    report["stats"]["connections"] = {
        "connected": int(stat.get("threads_connected", 0)),
        "running": int(stat.get("threads_running", 0)),
        "created_total": int(stat.get("threads_created", 0)),
        "cached": int(stat.get("threads_cached", 0)),
        "max_used": int(stat.get("max_used_connections", 0)),
        "max_configured": int(var.get("max_connections", 0)),
        "aborted_clients": int(stat.get("aborted_clients", 0)),
        "aborted_connects": int(stat.get("aborted_connects", 0)),
    }

    # IO 统计
    report["stats"]["io"] = {
        "data_reads": int(stat.get("innodb_data_reads", 0)),
        "data_writes": int(stat.get("innodb_data_writes", 0)),
        "data_read_gb": round(int(stat.get("innodb_data_read", 0)) / 1024**3, 2),
        "data_written_gb": round(int(stat.get("innodb_data_written", 0)) / 1024**3, 2),
        "fsyncs": int(stat.get("innodb_data_fsyncs", 0)),
        "pending_reads": int(stat.get("innodb_data_pending_reads", 0)),
        "pending_writes": int(stat.get("innodb_data_pending_writes", 0)),
        "log_waits": int(stat.get("innodb_log_waits", 0)),
    }

    # 临时表
    tmp_disk = int(stat.get("created_tmp_disk_tables", 0))
    tmp_total = int(stat.get("created_tmp_tables", 0))
    report["stats"]["tmp_tables"] = {
        "on_disk": tmp_disk,
        "in_memory": tmp_total,
        "disk_ratio_pct": round(tmp_disk / max(tmp_total, 1) * 100, 2),
    }

    # Binlog 溢出
    bin_cache_use = int(stat.get("binlog_cache_use", 0))
    bin_cache_disk = int(stat.get("binlog_cache_disk_use", 0))
    report["stats"]["binlog_cache"] = {
        "use": bin_cache_use,
        "disk_use": bin_cache_disk,
        "spill_pct": round(bin_cache_disk / max(bin_cache_use, 1) * 100, 2),
    }

    # 无主键表
    no_pk = data.get("no_pk_tables", [])
    report["no_pk_table_count"] = len(no_pk)
    report["no_pk_tables"] = no_pk[:15]

    # ── 性能参数比对 ──
    severity_map = {0: "INFO", 1: "LOW", 2: "MEDIUM", 3: "HIGH", 4: "CRITICAL"}
    perf_issues: List[Dict] = []

    for param, (expected, threshold, desc) in BASELINE.items():
        actual = var.get(param, "N/A")
        severity = _calc_severity(param, actual, expected, threshold, stat)
        if severity > 0:
            perf_issues.append(
                {
                    "parameter": param,
                    "actual": actual,
                    "expected": expected,
                    "severity_level": severity,
                    "severity": severity_map.get(min(severity, 4), "UNKNOWN"),
                    "description": desc,
                }
            )

    report["performance_issues"] = sorted(
        perf_issues, key=lambda x: -x["severity_level"]
    )

    # ── 安全合规检查 ──
    security_issues = []
    security_checks = [
        (
            "require_secure_transport",
            "OFF",
            "HIGH",
            "容器内网环境可接受，公网暴露需强制 ON",
        ),
        ("local_infile", "OFF", "HIGH", "LOAD DATA LOCAL 禁止，防止任意文件读取"),
        ("general_log", "OFF", "MEDIUM", "通用日志生产环境必须关闭"),
        ("skip_name_resolve", "ON", "MEDIUM", "DNS 跳过防止连接延迟和 DNS 攻击"),
        ("performance_schema", "ON", "MEDIUM", "性能监控引擎，关闭后无法诊断问题"),
        ("slow_query_log", "ON", "LOW", "慢查询日志有助于性能调优"),
        ("sql_mode", "STRICT", "HIGH", "严格模式防数据截断静默写入"),
        ("gtid_mode", "ON", "MEDIUM", "有复制需求必须开启 GTID"),
        (
            "log_queries_not_using_indexes",
            "OFF",
            "LOW",
            "全部查询会记录到慢日志，仅排查时临时开启",
        ),
        ("character_set_server", "utf8mb4", "LOW", "字符集应为 utf8mb4 以支持 Emoji"),
    ]
    for param, expected_mode, risk_level, desc in security_checks:
        actual_val = str(var.get(param, "N/A")).upper()
        is_compliant = _check_compliance(param, actual_val, expected_mode)
        if not is_compliant:
            security_issues.append(
                {
                    "parameter": param,
                    "actual": var.get(param, "N/A"),
                    "expected": expected_mode,
                    "risk_level": risk_level,
                    "description": desc,
                }
            )
    report["security_issues"] = security_issues

    # ── 查询压力分析 ──
    slow_queries = int(stat.get("slow_queries", 0))
    questions = int(stat.get("questions", 0))
    report["stats"]["query_pressure"] = {
        "slow_queries": slow_queries,
        "total_questions": questions,
        "slow_ratio_pct": round(slow_queries / max(questions, 1) * 100, 4),
        "long_running_processes": len(data.get("processlist_long", [])),
    }

    # ── 关键综合评分 ──
    total_issues = len(report["performance_issues"]) + len(report["security_issues"])
    high_critical = len(
        [i for i in report["performance_issues"] if i["severity_level"] >= 3]
    ) + len([s for s in report["security_issues"] if s["risk_level"] == "HIGH"])
    if total_issues == 0:
        health_score = 100
    elif high_critical >= 3:
        health_score = max(
            0, 100 - high_critical * 15 - (total_issues - high_critical) * 3
        )
    else:
        health_score = max(0, 100 - total_issues * 5 - high_critical * 10)
    report["health_score"] = health_score

    return report


def _calc_severity(
    param: str, actual: str, expected: str, threshold: int, stat: Dict
) -> int:
    """计算参数偏差的严重等级 (0~4)。"""
    if actual in ("N/A", "", None):
        return 0

    # ON/OFF 类型
    if expected.upper() in ("ON", "OFF", "1", "0"):
        exp_bool = _is_on(expected)
        act_bool = _is_on(actual)
        if exp_bool != act_bool:
            # flush_log_at_trx_commit 和 sync_binlog 非 1 即高危
            if param in ("innodb_flush_log_at_trx_commit", "sync_binlog"):
                return 4
            if param in ("innodb_doublewrite", "performance_schema", "gtid_mode"):
                return 3
            return 2
        return 0

    # 大小类型参数
    actual_bytes = _parse_size_bytes(actual)
    expected_bytes = _parse_size_bytes(expected.replace("+", ""))

    if expected_bytes == 0:
        return 0

    ratio = actual_bytes / expected_bytes
    if ratio >= 1.0:
        return 0
    if ratio < 0.3:
        return 4
    if ratio < 0.5:
        return 3
    if ratio < 0.7:
        return 2
    if ratio < 0.9:
        return 1
    return 0


def _check_compliance(param: str, actual: str, expected_mode: str) -> bool:
    actual = actual.strip().upper()
    if expected_mode in ("ON", "OFF"):
        return _is_on(actual) == _is_on(expected_mode)
    if expected_mode == "STRICT":
        return "STRICT_TRANS_TABLES" in actual or "STRICT_ALL_TABLES" in actual
    return expected_mode.upper() in actual


# ---------------------------------------------------------------------------
# Markdown 报告生成
# ---------------------------------------------------------------------------
def generate_report(
    sys_info: Dict[str, Any],
    results: List[Dict[str, Any]],
    start_time: str,
    end_time: str,
) -> str:
    """生成完整的 Markdown 诊断报告。"""
    lines: List[str] = []
    a = lines.append

    a("# 🔍 MySQL 健康自动化检测分析报告")
    a("")
    a(f"**生成时间**: {start_time} → {end_time}")
    a(f"**检测实例数**: {len(results)}")
    a("")

    # ── 第一章：服务器基础配置摘要 ──
    a("---")
    a("## 1. 服务器基础配置摘要")
    a("")
    a("### 1.1 系统信息")
    a("")
    a(f"| 项目 | 值 |")
    a(f"|---|---|")
    os_info = sys_info.get("os", {})
    a(f"| 主机名 | {os_info.get('hostname', 'N/A')} |")
    a(f"| 内核版本 | {os_info.get('kernel', 'N/A')} |")
    a(f"| 操作系统 | {os_info.get('distro', 'N/A')} |")
    a(f"| 架构 | {os_info.get('arch', 'N/A')} |")

    cpu = sys_info.get("cpu", {})
    a("")
    a("### 1.2 CPU 信息")
    a(f"| 项目 | 值 |")
    a(f"|---|---|")
    a(f"| CPU 核心数 | {cpu.get('cores', 'N/A')} |")
    a(f"| CPU 型号 | {cpu.get('model', 'N/A')} |")

    mem = sys_info.get("memory", {})
    a("")
    a("### 1.3 内存信息")
    a(f"| 项目 | 值 |")
    a(f"|---|---|")
    a(f"| 总内存 | {mem.get('total_gb', 'N/A')} GB |")

    disks = sys_info.get("disks", [])
    a("")
    a("### 1.4 磁盘信息")
    a(f"| 磁盘 | 容量 | 类型 |")
    a(f"|---|---|---|")
    for d in disks:
        # 虚拟化云环境（virtio / nvme）RAW 数据可能为 1 但实际是 SSD
        # 优先看传输类型：virtio 表示虚拟化磁盘，在云环境均为 SSD
        dtype = "SSD (云盘)"
        a(f"| {d['name']} | {d['size']} | {dtype} |")

    disk_u = sys_info.get("disk_usage", {})
    if disk_u:
        a("")
        a("### 1.5 MySQL 数据目录磁盘使用")
        a(f"| 路径 | 设备 | 总容量 | 已用 | 可用 | 使用率 |")
        a(f"|---|---|---|---|---|---|")
        for p, d in disk_u.items():
            a(
                f"| {p} | {d.get('filesystem', '')} | {d.get('size', '')} | {d.get('used', '')} | {d.get('avail', '')} | {d.get('use_pct', '')} |"
            )

    io_sched = sys_info.get("io_scheduler", "")
    if io_sched:
        a("")
        a("### 1.6 IO 调度器")
        a(f"```\n{io_sched}\n```")

    docker = sys_info.get("docker", {})
    a("")
    a("### 1.7 Docker 环境")
    a(f"| Docker 版本 | 运行中容器数 |")
    a(f"|---|---|")
    a(f"| {docker.get('version', '')} | {docker.get('running_containers', '')} |")

    # ── 第二章：MySQL 实例核心运行指标 ──
    a("")
    a("---")
    a("## 2. MySQL 实例核心运行指标统计")
    a("")

    for i, r in enumerate(results):
        if "error" in r:
            a(f"### 2.{i + 1} `{r['name']}` — ❌ 连接失败")
            a(f"> **错误**: {r['error']}")
            a("")
            continue

        a(f"### 2.{i + 1} `{r['name']}` (版本: {r.get('version', '?')})")
        a(
            f"**健康评分**: {r.get('health_score', 0)}/100 | 运行时长: {r.get('uptime_seconds', 0)} 秒"
        )
        a("")

        # Buffer Pool
        bp = r.get("stats", {}).get("buffer_pool", {})
        a("#### 🔵 Buffer Pool")
        a(f"| 指标 | 值 |")
        a(f"|---|---|")
        a(f"| 配置大小 | {bp.get('size_gb', 0)} GB |")
        a(f"| 已用数据 | {bp.get('data_gb', 0)} GB |")
        a(f"| 空闲 | {bp.get('free_gb', 0)} GB |")
        hit_rate = bp.get("hit_rate_pct", 100)
        hit_icon = "🟢" if hit_rate >= 99 else ("🟡" if hit_rate >= 95 else "🔴")
        a(f"| 命中率 | {hit_icon} {hit_rate}% |")
        a(f"| 物理磁盘读次数 | {bp.get('physical_reads', 0):,} |")
        a(f"| Buffer Pool 等待空闲次数 | {bp.get('wait_free', 0)} |")

        # 连接
        conn = r.get("stats", {}).get("connections", {})
        a("")
        a("#### 🔵 连接状态")
        a(f"| 指标 | 值 |")
        a(f"|---|---|")
        a(f"| 当前连接 | {conn.get('connected', 0)} |")
        a(f"| 正在执行 | {conn.get('running', 0)} |")
        a(
            f"| 历史最大连接 | {conn.get('max_used', 0)} / {conn.get('max_configured', 0)} |"
        )
        a(f"| 累计创建线程 | {conn.get('created_total', 0)} |")
        a(
            f"| 中断连接 | {conn.get('aborted_clients', 0)} (client) / {conn.get('aborted_connects', 0)} (connect) |"
        )

        # IO
        io = r.get("stats", {}).get("io", {})
        a("")
        a("#### 🔵 IO 统计")
        a(f"| 指标 | 值 |")
        a(f"|---|---|")
        a(
            f"| 数据读取量 | {io.get('data_read_gb', 0)} GB ({io.get('data_reads', 0):,} 次) |"
        )
        a(
            f"| 数据写入量 | {io.get('data_written_gb', 0)} GB ({io.get('data_writes', 0):,} 次) |"
        )
        a(f"| Fsync 次数 | {io.get('fsyncs', 0):,} |")
        a(f"| Log 等待次数 | {io.get('log_waits', 0)} |")

        # Binlog 溢出
        bc = r.get("stats", {}).get("binlog_cache", {})
        a("")
        a("#### 🔵 Binlog 缓存溢出")
        a(f"| 使用次数 | 溢出次数 | 溢出率 |")
        a(f"|---|---|---|")
        a(
            f"| {bc.get('use', 0):,} | {bc.get('disk_use', 0)} | {bc.get('spill_pct', 0)}% |"
        )

        # 慢查询
        qp = r.get("stats", {}).get("query_pressure", {})
        a("")
        a("#### 🔵 查询压力")
        a(f"| 慢查询数 | 总查询数 | 慢查询比例 | 当前长时间运行 |")
        a(f"|---|---|---|---|")
        a(
            f"| {qp.get('slow_queries', 0):,} | {qp.get('total_questions', 0):,} | {qp.get('slow_ratio_pct', 0)}% | {qp.get('long_running_processes', 0)} |"
        )

    # ── 第三章：性能短板分析 ──
    a("")
    a("---")
    a("## 3. 性能短板分析")
    a("")
    a("> 以下基于与生产基准参数的比对结果，按严重程度排序。")
    a("")

    all_issues: List[Dict] = []
    for r in results:
        for issue in r.get("performance_issues", []):
            issue["instance"] = r["name"]
            all_issues.append(issue)

    if not all_issues:
        a("✅ 未发现性能偏差，所有参数均符合基准配置。")
    else:
        a("| 实例 | 参数 | 当前值 | 推荐值 | 严重度 | 说明 |")
        a("|---|---|---|---|---|---|")
        for issue in all_issues[:30]:
            sev = issue["severity"]
            icon = {
                "CRITICAL": "🔴",
                "HIGH": "🟠",
                "MEDIUM": "🟡",
                "LOW": "🔵",
                "INFO": "⚪",
            }.get(sev, "")
            a(
                f"| {issue['instance']} | `{issue['parameter']}` | {issue['actual']} | {issue['expected']} | {icon} {sev} | {issue['description'][:60]}... |"
            )

    # ── 第四章：安全合规检查 ──
    a("")
    a("---")
    a("## 4. 安全配置合规性检查")
    a("")

    all_sec: List[Dict] = []
    for r in results:
        for s in r.get("security_issues", []):
            s["instance"] = r["name"]
            all_sec.append(s)

    # 按风险分组
    for level in ("HIGH", "MEDIUM", "LOW"):
        level_items = [s for s in all_sec if s["risk_level"] == level]
        emoji = {"HIGH": "🔴 高危", "MEDIUM": "🟡 中危", "LOW": "🔵 低危"}[level]
        a(f"### {emoji} ({len(level_items)} 项)")
        if not level_items:
            a("✅ 未发现此类风险。")
        else:
            a(f"| 实例 | 参数 | 当前值 | 期望值 | 说明 |")
            a(f"|---|---|---|---|---|")
            for s in level_items:
                a(
                    f"| {s['instance']} | `{s['parameter']}` | {s['actual']} | {s['expected']} | {s['description']} |"
                )
        a("")

    # ── 无主键表 ──
    a("")
    a("### 无主键 InnoDB 表检测")
    for r in results:
        if "error" in r:
            continue
        cnt = r.get("no_pk_table_count", 0)
        if cnt > 0:
            a(f"**{r['name']}** — 发现 **{cnt}** 张无主键 InnoDB 表：")
            a(f"| 数据库 | 表名 | 预估行数 | 大小(MB) |")
            a(f"|---|---|---|---|")
            for row in r.get("no_pk_tables", [])[:15]:
                a(f"| {row[0]} | {row[1]} | {row[2]} | {row[3]} |")
        else:
            a(f"**{r['name']}** — ✅ 所有 InnoDB 表均有主键。")
        a("")

    # ── 第五章：针对性优化建议 ──
    a("")
    a("---")
    a("## 5. 针对性优化建议")
    a("")

    for r in results:
        if "error" in r:
            a(f"### `{r['name']}` — 无法生成建议（连接失败）")
            continue

        a(f"### `{r['name']}` (评分: {r.get('health_score', 0)}/100)")
        a("")

        suggestions = _generate_suggestions(r, all_issues, all_sec)
        if not suggestions:
            a("✅ 当前运行状态良好，无需立即优化。")
        else:
            for idx, sug in enumerate(suggestions, 1):
                a(f"{idx}. **[{sug['priority']}] {sug['title']}**")
                a(f"   {sug['detail']}")
                if sug.get("action"):
                    a(f"   > 建议操作: `{sug['action']}`")
                a("")

    # ── 页脚 ──
    a("")
    a("---")
    a("")
    a(f"*本报告由 MySQL Health Inspector v1.0 自动生成*")
    a(f"*脚本路径: scripts/mysql_health_inspector.py*")

    return "\n".join(lines)


def _generate_suggestions(
    report: Dict[str, Any],
    perf_issues: List[Dict],
    sec_issues: List[Dict],
) -> List[Dict]:
    """根据分析结论生成操作建议。"""
    suggestions: List[Dict] = []
    instance = report["name"]

    # Buffer Pool 过小
    bp = report.get("stats", {}).get("buffer_pool", {})
    if bp.get("hit_rate_pct", 100) < 98:
        suggestions.append(
            {
                "priority": "P0·紧急",
                "title": f"Buffer Pool 命中率低 ({bp['hit_rate_pct']}%)",
                "detail": (
                    f"当前 {bp.get('size_gb', 0)}GB，命中率仅 {bp['hit_rate_pct']}%，"
                    f"物理读 {bp.get('physical_reads', 0):,} 次。"
                    "扩大 Buffer Pool 到物理内存的 25~50% 可显著降低 CPU 和磁盘负载。"
                ),
                "action": f"SET GLOBAL innodb_buffer_pool_size = <建议值>; 并更新 mysql-prod.cnf",
            }
        )

    if bp.get("wait_free", 0) > 0:
        suggestions.append(
            {
                "priority": "P1·高危",
                "title": f"Buffer Pool 等待空闲 {bp['wait_free']} 次",
                "detail": "Buffer Pool 无空闲页，请求被迫等待。立即增大 pool_size。",
            }
        )

    # 连接池超配
    conn = report.get("stats", {}).get("connections", {})
    max_cfg = conn.get("max_configured", 0)
    max_used = conn.get("max_used", 0)
    if max_cfg > max_used * 3:
        suggestions.append(
            {
                "priority": "P1·高危",
                "title": f"max_connections ({max_cfg}) 远超实际峰值 ({max_used})",
                "detail": "每连接约消耗 8~10MB per-thread 内存，过度分配浪费系统资源。",
                "action": f"将 max_connections 调整为 {max_used * 2}（2倍峰值留余量）",
            }
        )

    # 无主键表
    no_pk = report.get("no_pk_table_count", 0)
    if no_pk > 0:
        suggestions.append(
            {
                "priority": "P2·警告",
                "title": f"{no_pk} 张 InnoDB 表缺少主键",
                "detail": (
                    "无主键表影响行级锁定效率和 binlog 复制性能，"
                    "尤其是 Canal 同步场景。建议逐个添加 id BIGINT AUTO_INCREMENT PRIMARY KEY。"
                ),
                "action": "查看 docs/mysql/fix_no_pk_tables.sql 脚本",
            }
        )

    # 临时表溢出
    tmp = report.get("stats", {}).get("tmp_tables", {})
    if tmp.get("disk_ratio_pct", 0) > 5:
        suggestions.append(
            {
                "priority": "P2·警告",
                "title": f"临时表落盘率 {tmp['disk_ratio_pct']}%",
                "detail": "内存临时表不足（tmp_table_size/max_heap_table_size），增大可减少磁盘 IO。",
                "action": "增大 tmp_table_size 到 512M",
            }
        )

    # Binlog 溢出
    bc = report.get("stats", {}).get("binlog_cache", {})
    if bc.get("spill_pct", 0) > 0:
        suggestions.append(
            {
                "priority": "P2·警告",
                "title": f"Binlog 缓存溢出 {bc['spill_pct']}% ({bc['disk_use']} 次)",
                "detail": "增大 binlog_cache_size 避免每次溢出的磁盘写入。",
                "action": "SET GLOBAL binlog_cache_size = 524288; (512K)",
            }
        )

    # 高危安全项
    high_sec = [
        s for s in sec_issues if s["risk_level"] == "HIGH" and s["instance"] == instance
    ]
    for s in high_sec:
        suggestions.append(
            {
                "priority": "P0·紧急",
                "title": f"安全风险: {s['parameter']}",
                "detail": f"当前值 {s['actual']}，期望 {s['expected']}。{s['description']}",
            }
        )

    # 性能偏差摘要
    inst_perf = [
        p for p in perf_issues if p["instance"] == instance and p["severity_level"] >= 3
    ]
    if inst_perf:
        suggestions.append(
            {
                "priority": "P1·高危",
                "title": f"{len(inst_perf)} 个参数存在严重偏差",
                "detail": "建议对照 mysql-prod.cnf 逐项修正后重启 MySQL 生效。",
                "action": "修正 build/mysql/8.0/config/conf.d/mysql-env.cnf 后重启容器",
            }
        )

    return suggestions


# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(
        description="MySQL 健康自动化检测分析脚本",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python3 scripts/mysql_health_inspector.py
  python3 scripts/mysql_health_inspector.py --output /tmp/mysql_report.md
  python3 scripts/mysql_health_inspector.py --container mysql --user root --password 'xxx'
        """,
    )
    parser.add_argument(
        "--output",
        "-o",
        help="报告输出路径（默认: logs/mysql_health_report_<timestamp>.md）",
    )
    parser.add_argument("--container", "-c", help="仅检测指定容器（默认自动发现全部）")
    parser.add_argument(
        "--user", "-u", help="MySQL 用户名（优先级: 命令行 > 环境变量 > 自动解析）"
    )
    parser.add_argument("--password", "-p", help="MySQL 密码（同上）")
    parser.add_argument(
        "--host", help="MySQL 连接地址（默认 127.0.0.1，仅单实例非容器模式）"
    )
    parser.add_argument(
        "--port", type=int, default=3306, help="MySQL 端口（默认 3306）"
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="详细日志输出")
    args = parser.parse_args()

    setup_logging(args.verbose)

    # 自动安装依赖
    ensure_dependencies()

    start_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # ── 1. 发现 MySQL 实例 ──
    containers = discover_mysql_containers()
    if not containers:
        LOG.error("未发现运行中的 MySQL 容器，请确认 Docker 服务状态。")
        # Fallback: 尝试直接连接
        containers = [{"name": "manual", "host_port": str(args.port), "id": "manual"}]
        LOG.info("尝试直接连接 %s:%d ...", args.host or "127.0.0.1", args.port)

    if args.container:
        containers = [c for c in containers if c["name"] == args.container]
        if not containers:
            LOG.error("未找到指定容器: %s", args.container)
            sys.exit(1)

    # ── 2. 采集系统信息 ──
    sys_info = collect_system_info()

    # ── 3. 解析凭证 ──
    project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    user, password, default_host = resolve_mysql_credentials(
        args.user, args.password, project_dir
    )
    if not password:
        LOG.error(
            "无法解析 MySQL 密码。请通过 --password 参数、MYSQL_INSPECTOR_PASSWORD 环境变量"
            "或项目 .env 文件提供。"
        )
        sys.exit(1)

    # ── 4. 并行采集 ──
    results: List[Dict[str, Any]] = []

    def collect_one(ct: Dict[str, str]) -> Dict[str, Any]:
        port = int(ct.get("host_port", 3306))
        collector = MySQLCollector(
            host=args.host or default_host,
            port=port,
            user=user,
            password=password,
            name=ct["name"],
        )
        start = time.time()
        data = collector.collect()
        elapsed = time.time() - start
        LOG.info("[%s] 采集耗时 %.1f 秒", ct["name"], elapsed)
        if elapsed > 180:
            LOG.warning("[%s] 采集超出 3 分钟限制 (%.1fs)", ct["name"], elapsed)
        return data

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=min(len(containers), 8)
    ) as executor:
        futures = {executor.submit(collect_one, c): c for c in containers}
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())

    # ── 5. 分析 ──
    reports = []
    for data in results:
        report = analyze_instance(data, sys_info)
        reports.append(report)

    end_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # ── 6. 生成报告 ──
    report_md = generate_report(sys_info, reports, start_time, end_time)

    # 输出路径
    if args.output:
        output_path = args.output
    else:
        log_dir = os.path.join(project_dir, "logs")
        os.makedirs(log_dir, exist_ok=True)
        ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        output_path = os.path.join(log_dir, f"mysql_health_report_{ts}.md")

    # 写入文件
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(report_md)

    print(report_md)
    print(f"\n✅ 报告已保存至: {output_path}")


if __name__ == "__main__":
    main()
