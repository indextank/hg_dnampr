#!/usr/bin/env python3
"""
server_health_ai.py — 独立的服务器性能巡检与 AI 辅助诊断工具。

特性概览
========
- 系统采样：基于 ``/proc`` 的零依赖 CPU/内存/iowait/loadavg/网卡吞吐采集，避免每秒 fork ``top``/``free``。
- 并行采集：CPU/内存/网络/磁盘/iftop/nethogs/iostat/进程 Top 在同一时间窗口内并行执行。
- 应用日志：支持多文件（含 glob）、自定义 ``log_format``、按时间窗口反向扫描、Top URL/IP/UA、状态码按分钟分桶。
- MySQL：支持 unix socket / ``--defaults-file`` / ``my.cnf``，扩展指标（max_connections 占比、慢查询、复制状态、innodb 关键变量）；本机缺失时按 ``--mysql-container`` > ``label=mysql`` > ``image~=^mysql`` > ``port=3306`` 顺序挑选 docker 容器执行。
- AI：OpenAI 兼容 ``chat/completions``，自动 prompt 体积裁剪、不支持 ``response_format`` 时降级、旁路文件输出 prompt 与原始响应。
- 报告：Markdown + 可选 ``--json-out`` 结构化输出 + 历史目录对比 + Mermaid xychart 时序图 + sidecar 原始数据。
- 安全：白名单 + ``argv[0]`` 不允许含 ``/``、固定 ``PATH``、最小化 env、所有 subprocess 走 SafeRunner；支持 ``--dry-run``/``--no-install``/``--no-net``/``--readonly``。
- systemd：随脚本附 ``server-health-ai.service`` 与 ``server-health-ai.timer`` 模板。

退出码
======
- 0：成功
- 1：未捕获的运行期错误
- 2：用法/参数错误
- 3：PID 锁冲突
- 4：平台不支持（非 Linux 或 ``/proc`` 不可用）

详细文档参见同目录 ``server_health_ai.README.md``。
"""

from __future__ import annotations

import argparse
import configparser
import dataclasses
import datetime as dt
import fcntl
import fnmatch
import glob as globmod
import json
import locale
import logging
import os
import random
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

try:
    import tomllib  # type: ignore[import-not-found]  # Python 3.11+
except Exception:  # pragma: no cover - fallback path for <3.11
    tomllib = None  # type: ignore[assignment]


# ============================================================
# 常量、退出码与默认值
# ============================================================

EXIT_OK = 0
EXIT_RUNTIME_ERR = 1
EXIT_USAGE = 2
EXIT_LOCK = 3
EXIT_PLATFORM = 4

# 安全沙箱基于"命令白名单"控制可执行程序。
DEFAULT_ALLOWED_COMMANDS: Tuple[str, ...] = (
    "ifconfig",
    "iftop",
    "top",
    "nethogs",
    "free",
    "df",
    "netstat",
    "lsof",
    "ss",
    "tail",
    "ls",
    "wc",
    "sort",
    "uniq",
    "awk",
    "grep",
    "echo",
    "head",
    "iostat",
    "mysqladmin",
    "mysql",
    "docker",
)

# 禁止通过包管理器自动安装的工具（仅允许"本机已存在"或"容器内执行"）。
NO_AUTO_INSTALL_TOOLS: Tuple[str, ...] = ("mysqladmin", "mysql", "docker")

# 受限 PATH，避免命令查找被 PATH 注入污染。
SAFE_PATH = "/usr/sbin:/usr/bin:/sbin:/bin"

# 仅允许从父进程透传到子进程的 env 键（其余统一清理）。
SAFE_ENV_PASSTHROUGH: Tuple[str, ...] = ("LANG", "LC_ALL", "LC_CTYPE", "TERM", "TZ")

EXTRA_COMMAND_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")
UNSAFE_TOKEN_CHARS_RE = re.compile(r"[;&|`$<>\r\n]")
DOCKER_CONTAINER_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")

# 已知 nginx log_format 模板的命名正则。
KNOWN_LOG_FORMATS: Dict[str, str] = {
    "combined": (
        r"^(?P<remote_addr>\S+)\s+-\s+(?P<remote_user>\S+)\s+"
        r"\[(?P<time_local>[^\]]+)\]\s+"
        r'"(?P<request>[^"]*)"\s+'
        r"(?P<status>\d{3})\s+(?P<body_bytes_sent>\S+)\s+"
        r'"(?P<http_referer>[^"]*)"\s+'
        r'"(?P<http_user_agent>[^"]*)"\s*$'
    ),
    "combined_with_time": (
        r"^(?P<remote_addr>\S+)\s+-\s+(?P<remote_user>\S+)\s+"
        r"\[(?P<time_local>[^\]]+)\]\s+"
        r'"(?P<request>[^"]*)"\s+'
        r"(?P<status>\d{3})\s+(?P<body_bytes_sent>\S+)\s+"
        r'"(?P<http_referer>[^"]*)"\s+'
        r'"(?P<http_user_agent>[^"]*)"\s+'
        r"(?P<request_time>\d+(?:\.\d+)?)\s*$"
    ),
}

# 默认配置（CLI/配置文件可覆盖）。
DEFAULT_CONFIG: Dict[str, Any] = {
    "ai": {
        "openai": {
            "base_url": os.environ.get("OPENAI_BASE_URL", "https://api.openai.com"),
            "api_key": os.environ.get("OPENAI_API_KEY", ""),
            "model": "gpt-3.5-turbo",
            "timeout_s": 30,
            "temperature": 0.2,
            "max_tokens": 900,
            "system_prompt_file": "",
        },
        "budget": {
            "max_prompt_chars": 60000,
        },
    },
    "mysql": {
        "dsn": "mysql://root@localhost",
        "defaults_file": "",
        "socket": "",
        "container": "",
        "container_label": "mysql",
        "container_image_regex": r"^mysql(?::|$)",
    },
    "logging": {
        "level": "INFO",
        "audit_path": "",  # 空字符串则使用 ``_default_audit_path()``
        "no_audit": False,
    },
    "runtime": {
        "pid_file": "/tmp/server_health_ai.pid",
        "command_timeout_s": 30,
        "parallel": True,
        "modes": {
            "dry_run": False,
            "no_install": False,
            "no_net": False,
            "readonly": False,
        },
    },
    "application": {
        "log_files": [],  # 空则使用 CLI 指定 / 跳过
        "log_format": "auto",
    },
    "thresholds": {
        "cpu": {"yellow": 70, "red": 90},
        "memory": {"yellow": 75, "red": 90},
        "disk": {"yellow": 80, "red": 90},
        "iowait": {"yellow": 10, "red": 25},
        "http_error_rate": {"yellow": 1.0, "red": 5.0},
        "mysql_threads": {"yellow": 200, "red": 500},
    },
    "history": {
        "dir": "",  # 空则使用 ``_default_history_dir()``
        "max_keep": 30,
    },
    "hgdnmpr": {
        "enabled": True,
        "containers": [
            "nginx",
            "tengine",
            "mysql",
            "postgres",
            "mongo",
            "redis",
            "valkey",
            "rabbitmq",
        ],
    },
}


# ============================================================
# 基础辅助
# ============================================================


def _now_ts() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def _human_ts_for_filename() -> str:
    return dt.datetime.now().strftime("%Y%m%d_%H%M%S")


def _best_effort_decode(raw: bytes) -> str:
    if not raw:
        return ""
    candidates: List[str] = []
    pref = locale.getpreferredencoding(False)
    if pref:
        candidates.append(pref)
    candidates.extend(["utf-8", "utf-8-sig", "gb18030", "gbk", "latin-1"])
    for enc in candidates:
        try:
            return raw.decode(enc)
        except Exception:
            continue
    return raw.decode(errors="replace")


def _parse_int(s: str) -> Optional[int]:
    try:
        return int(s)
    except Exception:
        return None


def _parse_float(s: str) -> Optional[float]:
    try:
        return float(s)
    except Exception:
        return None


def _clamp(n: int, low: int, high: int) -> int:
    return max(low, min(high, n))


def _percentile(values: Sequence[float], p: float) -> Optional[float]:
    if not values:
        return None
    if p <= 0:
        return min(values)
    if p >= 100:
        return max(values)
    xs = sorted(values)
    k = (len(xs) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    if f == c:
        return xs[f]
    d0 = xs[f] * (c - k)
    d1 = xs[c] * (k - f)
    return d0 + d1


def _severity_to_light(sev: int) -> str:
    if sev >= 4:
        return "🔴"
    if sev >= 2:
        return "🟡"
    return "🟢"


def _color(s: str, code: str, enable: bool) -> str:
    if not enable:
        return s
    return f"\033[{code}m{s}\033[0m"


def _expand_path(p: str) -> str:
    if not p:
        return p
    return os.path.expanduser(os.path.expandvars(p))


def _deep_get(d: Dict[str, Any], path: str, default: Any = None) -> Any:
    cur: Any = d
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def _deep_merge(base: Dict[str, Any], overlay: Dict[str, Any]) -> Dict[str, Any]:
    """递归合并：``overlay`` 优先，原地不修改 ``base``。"""

    out: Dict[str, Any] = dict(base)
    for k, v in overlay.items():
        if k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def _is_root() -> bool:
    return hasattr(os, "geteuid") and os.geteuid() == 0


def _default_audit_path() -> str:
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "server_health_ai", "audit.log")


def _default_history_dir() -> str:
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "server_health_ai", "history")


def _safe_hostname() -> str:
    try:
        return os.uname().nodename
    except Exception:
        return ""


# ============================================================
# CLI
# ============================================================


def _build_arg_parser() -> argparse.ArgumentParser:
    class ColorHelpFormatter(argparse.RawTextHelpFormatter):
        def _format_action_invocation(self, action: argparse.Action) -> str:
            txt = super()._format_action_invocation(action)
            return _color(txt, "1;36", sys.stdout.isatty())

    epilog = (
        "退出码: 0 成功 / 1 运行错误 / 2 用法错误 / 3 PID 锁冲突 / 4 平台不支持\n"
        "权限说明: iftop/nethogs/部分 lsof 字段需要 root 才能完整工作；非 root 时会标记降级。\n"
        "安装策略: mysqladmin/mysql/docker 禁止由本脚本通过包管理器自动安装。\n"
        "示例:\n"
        "  ./server_health_ai.py -t 60 -f /var/log/nginx/access.log\n"
        "  ./server_health_ai.py -t 30 --no-net --json-out report.json\n"
        "  ./server_health_ai.py --config /etc/server_health_ai.toml -t 120\n"
    )

    p = argparse.ArgumentParser(
        prog="server_health_ai.py",
        formatter_class=ColorHelpFormatter,
        description="服务器带宽与性能智能检测（AI辅助诊断），独立运行的纯 Python 脚本。",
        epilog=epilog,
    )

    p.add_argument("-m", "--model", default="", help="AI 模型名（默认从配置/环境读取，最终回退 gpt-3.5-turbo）")
    p.add_argument(
        "-c",
        "--commands",
        default="",
        help="逗号分隔的额外命令白名单（例如：mysqladmin,iostat,docker）",
    )
    p.add_argument(
        "-t",
        "--time",
        type=int,
        default=60,
        help="检测时长，1-3600 秒（默认 60）",
    )
    p.add_argument(
        "-f",
        "--file",
        action="append",
        default=None,
        help=(
            "应用日志路径，可重复指定或使用 glob，例如 -f '/var/log/nginx/*.log'。"
            "传入 '-' 表示跳过应用日志分析。默认 /var/log/nginx/access.log"
        ),
    )
    p.add_argument(
        "--log-format",
        default="auto",
        help="日志格式：combined / combined_with_time / auto / 完整命名正则字符串（必须包含 (?P<time_local>...) 与 (?P<status>...) 等命名组）",
    )
    p.add_argument(
        "-d",
        "--database",
        default="",
        help="MySQL DSN（不建议在 DSN 中携带密码），格式 mysql://user@host:port",
    )
    p.add_argument("--mysql-defaults-file", default="", help="mysqladmin/mysql --defaults-file 路径（如 ~/.my.cnf）")
    p.add_argument("--mysql-socket", default="", help="MySQL unix socket 路径（如 /var/run/mysqld/mysqld.sock）")
    p.add_argument("--mysql-container", default="", help="显式指定执行 mysqladmin/mysql 的 docker 容器名")
    p.add_argument(
        "-r",
        "--report",
        default="",
        help="输出 Markdown 报告路径（默认 ./report_YYYYMMDD_HHMMSS.md）",
    )
    p.add_argument("--json-out", default="", help="额外输出结构化结果到指定 JSON 文件")
    p.add_argument("--config", default="", help="配置文件路径（支持 .toml/.json/.ini）")

    # AI 控制
    p.add_argument("--temperature", type=float, default=None, help="AI temperature 覆盖")
    p.add_argument("--max-tokens", type=int, default=None, help="AI max_tokens 覆盖")
    p.add_argument("--ai-timeout", type=int, default=None, help="AI 调用超时秒数覆盖")
    p.add_argument("--ai-system-prompt-file", default="", help="自定义 system prompt 文件路径")
    p.add_argument("--no-ai", action="store_true", help="跳过 AI 调用，仅产出基于阈值的报告")

    # 历史
    p.add_argument("--history-dir", default="", help="历史报告目录（用于本次与上次对比）")
    p.add_argument("--no-history", action="store_true", help="禁用历史归档与对比")

    # 运行模式开关
    p.add_argument("--dry-run", action="store_true", help="仅打印将执行的命令，不实际执行")
    p.add_argument("--no-install", action="store_true", help="检测到缺失工具时不调用包管理器安装")
    p.add_argument("--no-net", action="store_true", help="禁用所有外部网络调用（含 AI、docker pull 等）")
    p.add_argument("--readonly", action="store_true", help="只读模式：不写入审计日志/PID/报告，仅打印到 stdout")
    p.add_argument("--no-audit", action="store_true", help="禁用审计日志写入")

    p.add_argument("-q", "--quiet", action="store_true", help="降低输出（仅 WARNING 及以上）")
    p.add_argument("-v", "--verbose", action="store_true", help="提升输出（DEBUG）")

    return p


# ============================================================
# 配置加载
# ============================================================


def load_config_file(path: str) -> Dict[str, Any]:
    """支持 .toml/.json/.ini，未识别后缀按 toml→json→ini 顺序探测。"""

    if not path:
        return {}
    rp = _expand_path(path)
    if not os.path.exists(rp):
        raise FileNotFoundError(f"config file not found: {rp}")
    with open(rp, "rb") as f:
        raw = f.read()

    suffix = os.path.splitext(rp)[1].lower()

    def _try_toml() -> Optional[Dict[str, Any]]:
        if tomllib is None:
            return None
        try:
            return tomllib.loads(_best_effort_decode(raw))
        except Exception:
            return None

    def _try_json() -> Optional[Dict[str, Any]]:
        try:
            return json.loads(_best_effort_decode(raw))
        except Exception:
            return None

    def _try_ini() -> Optional[Dict[str, Any]]:
        cp = configparser.ConfigParser()
        try:
            cp.read_string(_best_effort_decode(raw))
        except Exception:
            return None
        out: Dict[str, Any] = {}
        for section in cp.sections():
            cur = out
            parts = section.split(".")
            for part in parts[:-1]:
                cur = cur.setdefault(part, {})
            cur[parts[-1]] = {k: _coerce_scalar(v) for k, v in cp.items(section)}
        return out

    if suffix == ".toml":
        d = _try_toml()
    elif suffix == ".json":
        d = _try_json()
    elif suffix in (".ini", ".cfg", ".conf"):
        d = _try_ini()
    else:
        d = _try_toml() or _try_json() or _try_ini()

    if d is None:
        raise ValueError(f"failed to parse config file: {rp}")
    if not isinstance(d, dict):
        raise ValueError(f"config root must be a mapping: {rp}")
    return d


def _coerce_scalar(v: str) -> Any:
    if v is None:
        return v
    s = v.strip()
    if s.lower() in ("true", "yes", "on"):
        return True
    if s.lower() in ("false", "no", "off"):
        return False
    iv = _parse_int(s)
    if iv is not None and re.fullmatch(r"-?\d+", s):
        return iv
    fv = _parse_float(s)
    if fv is not None and re.fullmatch(r"-?\d+\.\d+", s):
        return fv
    return s


# ============================================================
# 审计日志
# ============================================================


class AuditLogger:
    def __init__(self, path: str, enabled: bool = True):
        self._path = path
        self._enabled = enabled
        self._lock = threading.Lock()
        self._fh: Optional[Any] = None
        if not enabled:
            return
        try:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        except Exception:
            pass
        try:
            self._fh = open(path, "a", encoding="utf-8", errors="replace")
            try:
                os.chmod(path, 0o600)
            except Exception:
                pass
        except Exception:
            self._enabled = False
            self._fh = None

    @property
    def enabled(self) -> bool:
        return self._enabled and self._fh is not None

    def log(self, event: str, **fields: Any) -> None:
        if not self.enabled:
            return
        payload: Dict[str, Any] = {"ts": _now_ts(), "event": event}
        payload.update(fields)
        with self._lock:
            try:
                assert self._fh is not None
                self._fh.write(json.dumps(payload, ensure_ascii=False, default=str) + "\n")
                self._fh.flush()
            except Exception:
                pass

    def close(self) -> None:
        if self._fh is None:
            return
        with self._lock:
            try:
                self._fh.close()
            except Exception:
                pass
            self._fh = None


# ============================================================
# 安全 Runner
# ============================================================


@dataclasses.dataclass(frozen=True)
class CommandResult:
    argv: List[str]
    exit_code: int
    duration_ms: int
    stdout: str
    stderr: str
    timed_out: bool


class SafeRunner:
    """命令白名单 + ``argv[0]`` 不允许包含路径分隔符 + 受限 PATH/env/cwd。"""

    def __init__(
        self,
        allowed_commands: Iterable[str],
        timeout_s: int,
        audit: AuditLogger,
        logger: logging.Logger,
        dry_run: bool = False,
        cwd: Optional[str] = None,
    ):
        self._allowed = set(allowed_commands)
        self._timeout_s = timeout_s
        self._audit = audit
        self._logger = logger
        self._dry_run = dry_run
        self._cwd = cwd or "/"

    @property
    def timeout_s(self) -> int:
        return self._timeout_s

    @property
    def audit(self) -> AuditLogger:
        return self._audit

    def extend_allowed(self, extra: Iterable[str]) -> None:
        for cmd in extra:
            self._allowed.add(cmd)

    def allowed_commands(self) -> List[str]:
        return sorted(self._allowed)

    def is_allowed(self, cmd: str) -> bool:
        return cmd in self._allowed

    def _safe_env(self, extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        env: Dict[str, str] = {"PATH": SAFE_PATH}
        for k in SAFE_ENV_PASSTHROUGH:
            if k in os.environ:
                env[k] = os.environ[k]
        if extra:
            for k, v in extra.items():
                if not k or UNSAFE_TOKEN_CHARS_RE.search(str(v) or ""):
                    continue
                env[k] = str(v)
        return env

    def _validate_argv(self, argv: Sequence[str]) -> None:
        if not argv:
            raise ValueError("empty command")
        head = argv[0]
        if "/" in head:
            raise PermissionError(f"argv[0] must be basename, got: {head}")
        if head not in self._allowed:
            raise PermissionError(f"command not allowed: {head}")
        for tok in argv:
            if UNSAFE_TOKEN_CHARS_RE.search(tok):
                raise PermissionError("unsafe token detected")

    def run(self, cmdline: str, env_extra: Optional[Dict[str, str]] = None) -> CommandResult:
        argv = shlex.split(cmdline)
        return self.run_argv(argv, env_extra=env_extra)

    def run_argv(
        self,
        argv: Sequence[str],
        env_extra: Optional[Dict[str, str]] = None,
        timeout_s: Optional[int] = None,
    ) -> CommandResult:
        argv_list = list(argv)
        self._validate_argv(argv_list)
        env = self._safe_env(env_extra)
        timeout = int(timeout_s if timeout_s is not None else self._timeout_s)

        if self._dry_run:
            self._audit.log("command_dry_run", argv=argv_list, env_extra_keys=sorted(list((env_extra or {}).keys())))
            self._logger.info("[dry-run] %s", " ".join(shlex.quote(x) for x in argv_list))
            return CommandResult(argv=argv_list, exit_code=0, duration_ms=0, stdout="", stderr="", timed_out=False)

        start = time.time()
        timed_out = False
        try:
            self._audit.log("command_exec", argv=argv_list)
            cp = subprocess.run(
                argv_list,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout,
                check=False,
                cwd=self._cwd,
                env=env,
            )
            dur_ms = int((time.time() - start) * 1000)
            return CommandResult(
                argv=argv_list,
                exit_code=int(cp.returncode),
                duration_ms=dur_ms,
                stdout=_best_effort_decode(cp.stdout),
                stderr=_best_effort_decode(cp.stderr),
                timed_out=False,
            )
        except subprocess.TimeoutExpired as e:
            timed_out = True
            dur_ms = int((time.time() - start) * 1000)
            self._logger.warning("命令超时: %s", argv_list[0])
            return CommandResult(
                argv=argv_list,
                exit_code=124,
                duration_ms=dur_ms,
                stdout=_best_effort_decode(e.stdout or b""),
                stderr=_best_effort_decode(e.stderr or b""),
                timed_out=True,
            )
        except FileNotFoundError as e:
            return CommandResult(
                argv=argv_list,
                exit_code=127,
                duration_ms=0,
                stdout="",
                stderr=str(e),
                timed_out=False,
            )
        finally:
            if timed_out:
                self._audit.log("command_timeout", argv=argv_list, timeout_s=timeout)


def _parse_extra_commands(raw: str) -> List[str]:
    if not raw:
        return []
    out: List[str] = []
    for part in raw.split(","):
        cmd = part.strip()
        if not cmd:
            continue
        if not EXTRA_COMMAND_NAME_RE.fullmatch(cmd):
            raise ValueError(f"invalid extra command name: {cmd}")
        out.append(cmd)
    return out


# ============================================================
# 平台与依赖检测
# ============================================================


def parse_os_release(path: str = "/etc/os-release") -> Dict[str, str]:
    data: Dict[str, str] = {}
    if not os.path.exists(path):
        return data
    try:
        with open(path, "rb") as f:
            txt = _best_effort_decode(f.read())
    except Exception:
        return data
    for line in txt.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip()
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            v = v[1:-1]
        data[k.strip()] = v
    return data


def detect_package_manager() -> Optional[str]:
    for pm in ("apt-get", "dnf", "yum"):
        if shutil.which(pm):
            return pm
    return None


def ensure_tools(
    tools: Sequence[str],
    pm: Optional[str],
    audit: AuditLogger,
    logger: logging.Logger,
    no_install: bool = False,
) -> Dict[str, Any]:
    availability: Dict[str, Any] = {"tools": {}, "package_manager": pm, "attempted_install": False}
    missing: List[str] = []
    for t in tools:
        ok = bool(shutil.which(t))
        availability["tools"][t] = {"available": ok}
        if not ok:
            missing.append(t)

    if not missing:
        availability["status"] = "ok"
        return availability

    availability["status"] = "missing"
    availability["missing"] = missing

    if no_install:
        availability["install_suggestion"] = (
            f"缺失工具: {', '.join(missing)}；当前为 --no-install 模式，已跳过自动安装"
        )
        return availability

    if not pm:
        availability["install_suggestion"] = f"缺失工具: {', '.join(missing)}；未检测到包管理器"
        return availability

    if not _is_root():
        availability["install_suggestion"] = (
            f"缺失工具: {', '.join(missing)}；建议以 root 或 sudo 执行自动安装: {pm} install ..."
        )
        return availability

    pkg_map = {
        "iftop": {"apt-get": "iftop", "yum": "iftop", "dnf": "iftop"},
        "nethogs": {"apt-get": "nethogs", "yum": "nethogs", "dnf": "nethogs"},
        "iostat": {"apt-get": "sysstat", "yum": "sysstat", "dnf": "sysstat"},
        "ifconfig": {"apt-get": "net-tools", "yum": "net-tools", "dnf": "net-tools"},
        "netstat": {"apt-get": "net-tools", "yum": "net-tools", "dnf": "net-tools"},
        "lsof": {"apt-get": "lsof", "yum": "lsof", "dnf": "lsof"},
        "ss": {"apt-get": "iproute2", "yum": "iproute", "dnf": "iproute"},
    }
    no_auto_install = set(NO_AUTO_INSTALL_TOOLS)
    install_missing: List[str] = [t for t in missing if t not in no_auto_install]
    skipped_missing: List[str] = [t for t in missing if t in no_auto_install]
    if skipped_missing:
        availability.setdefault("tools_policy", {})
        for t in skipped_missing:
            availability["tools_policy"][t] = {
                "auto_install": False,
                "reason": "禁止通过包管理器自动安装；优先本机已存在或容器内执行",
            }

    pkgs: List[str] = []
    for t in install_missing:
        m = pkg_map.get(t, {})
        pkgs.append(m.get(pm, t))

    if not pkgs:
        availability["install_suggestion"] = (
            f"缺失工具: {', '.join(missing)}；其中 {', '.join(skipped_missing) or '-'} 禁止自动安装"
        )
        return availability

    cmd: List[str]
    if pm == "apt-get":
        cmd = ["apt-get", "update"]
        audit.log("dep_install", argv=cmd, missing=install_missing)
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        cmd = ["apt-get", "install", "-y"] + pkgs
    elif pm in ("yum", "dnf"):
        cmd = [pm, "install", "-y"] + pkgs
    else:
        availability["install_suggestion"] = f"缺失工具: {', '.join(missing)}；未知包管理器: {pm}"
        return availability

    availability["attempted_install"] = True
    audit.log("dep_install", argv=cmd, missing=install_missing)
    logger.info("尝试安装缺失工具: %s", ", ".join(install_missing))
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    for t in install_missing:
        availability["tools"][t]["available_after_install"] = bool(shutil.which(t))
    return availability


# ============================================================
# 平台检测（H1）
# ============================================================


def check_platform() -> Tuple[bool, str]:
    if sys.platform != "linux":
        return False, f"仅支持 Linux，当前 platform={sys.platform}"
    if not os.path.isdir("/proc"):
        return False, "/proc 不可用，无法采集"
    return True, ""


# ============================================================
# /proc 解析（B1, B3）
# ============================================================


def _read_proc_text(path: str) -> Optional[str]:
    try:
        with open(path, "rb") as f:
            return _best_effort_decode(f.read())
    except Exception:
        return None


def read_cpu_jiffies() -> Optional[Tuple[int, int, int]]:
    """返回 ``(total, idle_plus_iowait, iowait)`` jiffies。"""

    txt = _read_proc_text("/proc/stat")
    if not txt:
        return None
    for line in txt.splitlines():
        if not line.startswith("cpu "):
            continue
        parts = line.split()
        try:
            nums = [int(x) for x in parts[1:]]
        except Exception:
            return None
        # user nice system idle iowait irq softirq steal guest guest_nice
        idle = nums[3] if len(nums) > 3 else 0
        iowait = nums[4] if len(nums) > 4 else 0
        total = sum(nums)
        return total, idle + iowait, iowait
    return None


def cpu_pct_from_jiffies(prev: Tuple[int, int, int], cur: Tuple[int, int, int]) -> Tuple[Optional[float], Optional[float]]:
    pt, pi, pio = prev
    ct, ci, cio = cur
    dt_ = ct - pt
    if dt_ <= 0:
        return None, None
    di = ci - pi
    dio = cio - pio
    cpu_used = max(0.0, min(100.0, (1.0 - di / dt_) * 100.0))
    iowait = max(0.0, min(100.0, (dio / dt_) * 100.0))
    return cpu_used, iowait


def read_meminfo() -> Dict[str, int]:
    info: Dict[str, int] = {}
    txt = _read_proc_text("/proc/meminfo")
    if not txt:
        return info
    for line in txt.splitlines():
        k, _, rest = line.partition(":")
        parts = rest.strip().split()
        if not parts:
            continue
        v = _parse_int(parts[0])
        if v is None:
            continue
        info[k.strip()] = v  # kB
    return info


def mem_used_pct(info: Dict[str, int]) -> Optional[float]:
    total = info.get("MemTotal")
    avail = info.get("MemAvailable")
    if total and avail is not None and total > 0:
        return max(0.0, min(100.0, (1.0 - avail / total) * 100.0))
    return None


def read_loadavg() -> Optional[Tuple[float, float, float]]:
    txt = _read_proc_text("/proc/loadavg")
    if not txt:
        return None
    parts = txt.split()
    if len(parts) < 3:
        return None
    try:
        return float(parts[0]), float(parts[1]), float(parts[2])
    except Exception:
        return None


def read_net_dev() -> Dict[str, Tuple[int, int]]:
    """返回 ``{iface: (rx_bytes, tx_bytes)}``。"""

    out: Dict[str, Tuple[int, int]] = {}
    txt = _read_proc_text("/proc/net/dev")
    if not txt:
        return out
    lines = txt.splitlines()
    for line in lines[2:]:
        if ":" not in line:
            continue
        iface, _, rest = line.partition(":")
        parts = rest.split()
        if len(parts) < 16:
            continue
        rx = _parse_int(parts[0])
        tx = _parse_int(parts[8])
        if rx is None or tx is None:
            continue
        out[iface.strip()] = (rx, tx)
    return out


# ============================================================
# 旧 top/free/iostat 文本解析（保留以兼容 fallback / 单测）
# ============================================================


def _parse_top_cpu_usage_percent(text: str) -> Optional[float]:
    for line in text.splitlines():
        if "Cpu(s)" in line or "%Cpu(s)" in line:
            m = re.search(r"(\d+[\.,]\d+)\s*id", line)
            if not m:
                m = re.search(r"(\d+[\.,]\d+)\s*%?id", line)
            if m:
                v = m.group(1).replace(",", ".")
                idle = _parse_float(v)
                if idle is None:
                    return None
                return max(0.0, min(100.0, 100.0 - idle))
    return None


def _parse_free_mem(text: str) -> Dict[str, Any]:
    for line in text.splitlines():
        if line.startswith("Mem:") or line.startswith("Mem "):
            parts = line.split()
            if len(parts) >= 3:
                total = _parse_int(parts[1])
                used = _parse_int(parts[2])
                available = _parse_int(parts[6]) if len(parts) >= 7 else None
                used_pct = None
                if total and used is not None:
                    used_pct = (used / total) * 100.0
                return {"total_mb": total, "used_mb": used, "available_mb": available, "used_pct": used_pct}
    return {}


def _parse_iostat_iowait(text: str) -> Optional[float]:
    """解析 ``iostat -c`` 输出中最近一次 ``%iowait``。

    iostat 的列标题与 ``avg-cpu:`` 同行，例如::

        avg-cpu:  %user   %nice %system %iowait  %steal   %idle
                   3.42    0.00    1.10    1.74    0.00   93.74
    """

    in_cpu = False
    headers: List[str] = []
    last_value: Optional[float] = None
    for line in text.splitlines():
        s = line.strip()
        if s.lower().startswith("avg-cpu"):
            in_cpu = True
            after = s.split(":", 1)[1].strip() if ":" in s else ""
            headers = after.split() if after else []
            continue
        if in_cpu and not headers and s:
            headers = s.split()
            continue
        if in_cpu and headers and s:
            vals = s.split()
            if len(vals) != len(headers):
                in_cpu = False
                headers = []
                continue
            d = dict(zip(headers, vals))
            for k in ("%iowait", "iowait"):
                if k in d:
                    v = _parse_float(d[k].replace(",", "."))
                    if v is not None:
                        last_value = v
            in_cpu = False
            headers = []
    return last_value


# ============================================================
# 进程 Top N（B4 + H3 hidepid 降级）
# ============================================================


def _safe_listdir_proc() -> List[str]:
    try:
        return [n for n in os.listdir("/proc") if n.isdigit()]
    except PermissionError:
        return []
    except Exception:
        return []


@dataclasses.dataclass
class ProcSnapshot:
    pid: int
    comm: str
    state: str
    utime: int
    stime: int
    rss_kb: int
    cmdline: str


def _read_proc_pid_snapshot(pid_str: str) -> Optional[ProcSnapshot]:
    try:
        with open(f"/proc/{pid_str}/stat", "rb") as f:
            stat_raw = f.read().decode(errors="replace")
        # comm 内可能含空格，被括号包裹
        l_idx = stat_raw.find("(")
        r_idx = stat_raw.rfind(")")
        if l_idx < 0 or r_idx < 0 or r_idx <= l_idx:
            return None
        comm = stat_raw[l_idx + 1 : r_idx]
        rest = stat_raw[r_idx + 2 :].split()
        # rest[0]=state, rest[11]=utime, rest[12]=stime, rest[21]=rss(pages)
        if len(rest) < 22:
            return None
        state = rest[0]
        utime = int(rest[11])
        stime = int(rest[12])
        rss_pages = int(rest[21])
        rss_kb = rss_pages * (os.sysconf("SC_PAGESIZE") // 1024 or 4)

        cmdline = ""
        try:
            with open(f"/proc/{pid_str}/cmdline", "rb") as f:
                cmd_raw = f.read()
            cmdline = cmd_raw.replace(b"\x00", b" ").decode(errors="replace").strip()
        except Exception:
            cmdline = ""

        return ProcSnapshot(
            pid=int(pid_str),
            comm=comm,
            state=state,
            utime=utime,
            stime=stime,
            rss_kb=rss_kb,
            cmdline=cmdline[:200],
        )
    except FileNotFoundError:
        return None
    except PermissionError:
        return None
    except Exception:
        return None


def _snapshot_all_pids() -> Dict[int, ProcSnapshot]:
    out: Dict[int, ProcSnapshot] = {}
    pids = _safe_listdir_proc()
    for p in pids:
        snap = _read_proc_pid_snapshot(p)
        if snap is not None:
            out[snap.pid] = snap
    return out


def collect_top_processes(elapsed_s: float, prev: Dict[int, ProcSnapshot], cur: Dict[int, ProcSnapshot], top_n: int = 10) -> Dict[str, Any]:
    if elapsed_s <= 0:
        return {"status": "skipped", "reason": "elapsed<=0"}
    if not cur:
        return {"status": "degraded", "reason": "无法读取 /proc/[pid]/stat（可能 hidepid=2 或权限不足）"}

    sc_clk_tck = os.sysconf("SC_CLK_TCK") or 100
    cores = os.cpu_count() or 1

    cpu_rows: List[Dict[str, Any]] = []
    mem_rows: List[Dict[str, Any]] = []
    for pid, snap in cur.items():
        prev_snap = prev.get(pid)
        if prev_snap is not None:
            d_jiffies = (snap.utime + snap.stime) - (prev_snap.utime + prev_snap.stime)
            cpu_pct = max(0.0, (d_jiffies / sc_clk_tck) / elapsed_s * 100.0 / cores)
        else:
            cpu_pct = 0.0
        row = {
            "pid": pid,
            "comm": snap.comm,
            "state": snap.state,
            "cpu_pct": round(cpu_pct, 2),
            "rss_mb": round(snap.rss_kb / 1024.0, 1),
            "cmdline": snap.cmdline,
        }
        cpu_rows.append(row)
        mem_rows.append(row)

    cpu_rows.sort(key=lambda r: r["cpu_pct"], reverse=True)
    mem_rows.sort(key=lambda r: r["rss_mb"], reverse=True)
    return {
        "status": "ok",
        "elapsed_s": elapsed_s,
        "cores": cores,
        "by_cpu": cpu_rows[:top_n],
        "by_rss": mem_rows[:top_n],
    }


# ============================================================
# Reservoir 采样
# ============================================================


@dataclasses.dataclass
class Reservoir:
    limit: int
    items: List[float] = dataclasses.field(default_factory=list)
    seen: int = 0
    rng: random.Random = dataclasses.field(default_factory=lambda: random.Random(1337))

    def add(self, v: float) -> None:
        self.seen += 1
        if len(self.items) < self.limit:
            self.items.append(v)
            return
        j = self.rng.randint(1, self.seen)
        if j <= self.limit:
            self.items[j - 1] = v


# ============================================================
# 应用日志解析（C1, C2, C3, C4）
# ============================================================


def _parse_nginx_time(ts: str) -> Optional[dt.datetime]:
    try:
        return dt.datetime.strptime(ts, "%d/%b/%Y:%H:%M:%S %z")
    except Exception:
        return None


def _resolve_log_format(fmt: str) -> Optional[re.Pattern[str]]:
    if not fmt:
        return None
    if fmt in KNOWN_LOG_FORMATS:
        return re.compile(KNOWN_LOG_FORMATS[fmt])
    if fmt == "auto":
        return None  # 由调用方双格式探测
    try:
        return re.compile(fmt)
    except re.error:
        return None


def _expand_log_paths(patterns: Sequence[str]) -> List[str]:
    out: List[str] = []
    seen: set[str] = set()
    for p in patterns:
        if not p or p == "-":
            continue
        rp = _expand_path(p)
        for m in sorted(globmod.glob(rp)) or [rp]:
            if not os.path.isfile(m):
                continue
            if m in seen:
                continue
            seen.add(m)
            out.append(m)
    return out


def _read_log_window_reverse(path: str, window_start: dt.datetime, max_bytes: int = 64 * 1024 * 1024) -> Tuple[List[str], int]:
    """从文件尾向前按块读取，直到读到的块包含早于 ``window_start`` 的时间戳为止。

    返回 ``(lines, bytes_read)``。"""

    size = os.path.getsize(path)
    chunk = 256 * 1024
    read_total = 0
    buffer = b""
    pos = size
    t_re = re.compile(rb"\[(\d{2}/[A-Za-z]{3}/\d{4}:\d{2}:\d{2}:\d{2} [+\-]\d{4})\]")

    with open(path, "rb") as f:
        while pos > 0 and read_total < max_bytes:
            read_size = min(chunk, pos)
            pos -= read_size
            f.seek(pos)
            data = f.read(read_size)
            buffer = data + buffer
            read_total += read_size

            # 试探块内最早时间戳
            earliest: Optional[dt.datetime] = None
            for m in t_re.finditer(data):
                ts = _parse_nginx_time(m.group(1).decode(errors="replace"))
                if ts is not None:
                    earliest = ts
                    break
            if earliest is not None and earliest < window_start:
                break

    text = _best_effort_decode(buffer)
    lines = text.splitlines()
    if pos > 0 and lines:
        # 第一行可能不完整，丢弃
        lines = lines[1:]
    return lines, read_total


def analyze_access_log(
    paths: Sequence[str],
    window_s: int,
    log_format: str = "auto",
    max_bytes_per_file: int = 64 * 1024 * 1024,
    top_n: int = 10,
) -> Dict[str, Any]:
    if not paths:
        return {"status": "skipped", "reason": "no log files configured"}

    files = _expand_log_paths(paths)
    if not files:
        return {"status": "missing", "patterns": list(paths)}

    candidates: List[re.Pattern[str]] = []
    if log_format == "auto":
        candidates = [
            re.compile(KNOWN_LOG_FORMATS["combined_with_time"]),
            re.compile(KNOWN_LOG_FORMATS["combined"]),
        ]
    else:
        p = _resolve_log_format(log_format)
        if p is None:
            return {"status": "invalid_log_format", "log_format": log_format}
        candidates = [p]

    t_re = re.compile(r"\[(\d{2}/[A-Za-z]{3}/\d{4}:\d{2}:\d{2}:\d{2} [+\-]\d{4})\]")

    # 第一次：找全局最大 ts，作为窗口锚点
    last_ts_global: Optional[dt.datetime] = None
    for path in files:
        if not os.path.isfile(path) or os.path.getsize(path) == 0:
            continue
        try:
            with open(path, "rb") as f:
                size = os.path.getsize(path)
                f.seek(max(0, size - 65536))
                tail = _best_effort_decode(f.read())
        except Exception:
            continue
        for line in reversed(tail.splitlines()):
            m = t_re.search(line)
            if not m:
                continue
            ts = _parse_nginx_time(m.group(1))
            if ts is None:
                continue
            if last_ts_global is None or ts > last_ts_global:
                last_ts_global = ts
            break

    if last_ts_global is None:
        return {"status": "unparsable", "files": files}

    window_start = last_ts_global - dt.timedelta(seconds=window_s)

    total = 0
    errors = 0
    bytes_scanned = 0
    status_counts: Dict[str, int] = {}
    minute_buckets: Dict[str, Dict[str, int]] = {}
    url_counts: Dict[str, int] = {}
    ip_counts: Dict[str, int] = {}
    ua_counts: Dict[str, int] = {}
    rt = Reservoir(limit=20000)
    first_ts: Optional[dt.datetime] = None
    last_in_window: Optional[dt.datetime] = None

    for path in files:
        try:
            lines, br = _read_log_window_reverse(path, window_start, max_bytes=max_bytes_per_file)
        except Exception:
            continue
        bytes_scanned += br

        for line in lines:
            m = t_re.search(line)
            if not m:
                continue
            ts = _parse_nginx_time(m.group(1))
            if not ts or ts < window_start:
                continue
            total += 1
            if first_ts is None or ts < first_ts:
                first_ts = ts
            if last_in_window is None or ts > last_in_window:
                last_in_window = ts

            parsed: Optional[re.Match[str]] = None
            for c in candidates:
                pm = c.match(line)
                if pm is not None:
                    parsed = pm
                    break

            status_code = "000"
            request = ""
            remote_addr = ""
            ua = ""
            request_time: Optional[float] = None
            if parsed is not None:
                gd = parsed.groupdict()
                status_code = gd.get("status") or "000"
                request = gd.get("request") or ""
                remote_addr = gd.get("remote_addr") or ""
                ua = gd.get("http_user_agent") or ""
                rt_s = gd.get("request_time")
                if rt_s:
                    request_time = _parse_float(rt_s)
            else:
                ms = re.search(r'"\s*(\d{3})\s+', line)
                if ms:
                    status_code = ms.group(1)

            status_counts[status_code] = status_counts.get(status_code, 0) + 1
            ci = _parse_int(status_code) or 0
            if ci >= 400:
                errors += 1
            mkey = ts.strftime("%Y-%m-%d %H:%M")
            mb = minute_buckets.setdefault(mkey, {"total": 0, "errors": 0})
            mb["total"] += 1
            if ci >= 400:
                mb["errors"] += 1

            if request:
                method_path = request.split()
                if len(method_path) >= 2:
                    url = method_path[0] + " " + method_path[1].split("?", 1)[0]
                else:
                    url = request[:120]
                url_counts[url] = url_counts.get(url, 0) + 1
            if remote_addr:
                ip_counts[remote_addr] = ip_counts.get(remote_addr, 0) + 1
            if ua:
                ua_counts[ua[:160]] = ua_counts.get(ua[:160], 0) + 1
            if request_time is not None and 0 <= request_time < 600:
                rt.add(request_time)

    duration_s: Optional[float] = None
    if first_ts and last_in_window:
        duration_s = max(1.0, (last_in_window - first_ts).total_seconds())
    qps = (total / duration_s) if duration_s else None
    error_rate = (errors / total * 100.0) if total else None

    rts = rt.items
    return {
        "status": "ok",
        "files": files,
        "log_format": log_format,
        "window_s": window_s,
        "bytes_scanned": bytes_scanned,
        "total_requests": total,
        "qps": qps,
        "errors": errors,
        "error_rate_pct": error_rate,
        "status_counts": status_counts,
        "minute_buckets": [
            {"minute": k, "total": v["total"], "errors": v["errors"]}
            for k, v in sorted(minute_buckets.items())
        ],
        "top_urls": _top_n_dict(url_counts, top_n),
        "top_ips": _top_n_dict(ip_counts, top_n),
        "top_user_agents": _top_n_dict(ua_counts, top_n),
        "request_time": {
            "sampled": len(rts),
            "p50": _percentile(rts, 50),
            "p95": _percentile(rts, 95),
            "p99": _percentile(rts, 99),
            "max": max(rts) if rts else None,
        },
        "time_range": {
            "start": first_ts.isoformat() if first_ts else None,
            "end": last_in_window.isoformat() if last_in_window else None,
        },
    }


def _top_n_dict(d: Dict[str, int], n: int) -> List[Dict[str, Any]]:
    return [
        {"key": k, "count": v}
        for k, v in sorted(d.items(), key=lambda x: x[1], reverse=True)[:n]
    ]


# ============================================================
# MySQL 采集
# ============================================================


class MysqladminUnavailable(RuntimeError):
    pass


def _parse_mysql_dsn(dsn: str) -> Dict[str, Any]:
    if not dsn:
        return {"user": "root", "password": "", "host": "localhost", "port": 3306}
    u = urllib.parse.urlparse(dsn)
    if u.scheme and u.scheme != "mysql":
        raise ValueError("only mysql:// DSN is supported")
    user = urllib.parse.unquote(u.username or "root")
    password = urllib.parse.unquote(u.password or "")
    host = u.hostname or "localhost"
    port = u.port or 3306
    return {"user": user, "password": password, "host": host, "port": port}


def _parse_rfc3339(ts: str) -> Optional[dt.datetime]:
    s = ts.strip()
    if not s:
        return None
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    if "." in s:
        head, tail = s.split(".", 1)
        if "+" in tail:
            frac, tz = tail.split("+", 1)
            s = f"{head}.{frac[:6]}+{tz}"
        elif "-" in tail:
            frac, tz = tail.split("-", 1)
            s = f"{head}.{frac[:6]}-{tz}"
        else:
            s = f"{head}.{tail[:6]}"
    try:
        return dt.datetime.fromisoformat(s)
    except Exception:
        return None


def _docker_select_mysql_container(
    runner: SafeRunner,
    explicit: str,
    label: str,
    image_regex: str,
) -> Optional[str]:
    if not runner.is_allowed("docker") or not shutil.which("docker"):
        return None

    if explicit and DOCKER_CONTAINER_NAME_RE.fullmatch(explicit):
        return explicit

    candidates: List[Tuple[Optional[dt.datetime], str]] = []

    def _list_by(filter_args: List[str]) -> List[str]:
        argv = ["docker", "ps", "--format", "{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.CreatedAt}}"]
        for fa in filter_args:
            argv.extend(["--filter", fa])
        try:
            r = runner.run_argv(argv)
        except Exception:
            return []
        if r.exit_code != 0:
            return []
        out: List[str] = []
        rx = re.compile(image_regex) if image_regex else None
        for ln in r.stdout.splitlines():
            parts = ln.split("\t")
            if len(parts) < 1:
                continue
            name = parts[0].strip()
            if not DOCKER_CONTAINER_NAME_RE.fullmatch(name):
                continue
            image = parts[1].strip() if len(parts) > 1 else ""
            ports = parts[2].strip() if len(parts) > 2 else ""
            if rx is not None and image and not rx.search(image):
                if "3306" not in ports and not filter_args:
                    continue
            out.append(name)
        return out

    pools: List[List[str]] = []
    if label:
        pools.append(_list_by([f"label={label}"]))
    pools.append(_list_by(["expose=3306"]))
    pools.append(_list_by(["publish=3306"]))
    pools.append(_list_by([]))  # 全部，再用 image_regex 过滤

    seen: set[str] = set()
    flat: List[str] = []
    for pool in pools:
        for n in pool:
            if n in seen:
                continue
            seen.add(n)
            flat.append(n)

    for name in flat:
        try:
            r = runner.run_argv(["docker", "inspect", "-f", "{{.State.StartedAt}}", name])
        except Exception:
            continue
        if r.exit_code != 0:
            continue
        first = r.stdout.strip().splitlines()[0] if r.stdout.strip() else ""
        candidates.append((_parse_rfc3339(first), name))

    if not candidates:
        return None
    candidates.sort(key=lambda x: x[0] or dt.datetime.min.replace(tzinfo=dt.timezone.utc), reverse=True)
    return candidates[0][1]


def _exec_mysqladmin(
    runner: SafeRunner,
    mysqladmin_args: List[str],
    env_extra: Dict[str, str],
    container: Optional[str],
) -> CommandResult:
    if shutil.which("mysqladmin") and runner.is_allowed("mysqladmin"):
        return runner.run_argv(["mysqladmin", *mysqladmin_args], env_extra=env_extra)

    if container is None:
        raise MysqladminUnavailable(
            "未找到本机 mysqladmin，且未发现合适的 MySQL 容器；禁止自动安装 mysql-client。"
        )

    docker_argv = ["docker", "exec", "-i"]
    if env_extra.get("MYSQL_PWD"):
        docker_argv += ["-e", "MYSQL_PWD"]
    docker_argv += [container, "mysqladmin", *mysqladmin_args]
    return runner.run_argv(docker_argv, env_extra=env_extra)


def collect_mysql_metrics(
    runner: SafeRunner,
    cfg: Dict[str, Any],
    cli_dsn: str,
) -> Dict[str, Any]:
    if not runner.is_allowed("mysqladmin"):
        return {
            "status": "not_allowed",
            "tool": "mysqladmin",
            "hint": "通过 -c mysqladmin 扩展命令白名单",
        }

    mysql_cfg = dict(cfg.get("mysql", {}))
    dsn = (cli_dsn or mysql_cfg.get("dsn", "")).strip()

    try:
        info = _parse_mysql_dsn(dsn) if dsn else {"user": "root", "password": "", "host": "localhost", "port": 3306}
    except Exception as e:
        return {"status": "invalid_dsn", "error": str(e)}

    if info.get("password"):
        return {
            "status": "unsafe_dsn",
            "error": "DSN 中检测到明文密码，已拒绝；请改用 --mysql-defaults-file 或 MYSQL_PWD 环境变量",
        }

    env_extra: Dict[str, str] = {}
    if os.environ.get("MYSQL_PWD"):
        env_extra["MYSQL_PWD"] = os.environ["MYSQL_PWD"]

    base_args: List[str] = []
    defaults_file = _expand_path(str(mysql_cfg.get("defaults_file") or ""))
    if defaults_file:
        if not os.path.isfile(defaults_file):
            return {"status": "missing_defaults_file", "path": defaults_file}
        base_args.extend([f"--defaults-file={defaults_file}"])
    socket = _expand_path(str(mysql_cfg.get("socket") or ""))
    if socket:
        base_args.extend(["-S", socket])
    else:
        base_args.extend(["-u", info["user"], "-h", info["host"], "-P", str(info["port"])])

    container = _docker_select_mysql_container(
        runner=runner,
        explicit=str(mysql_cfg.get("container") or ""),
        label=str(mysql_cfg.get("container_label") or ""),
        image_regex=str(mysql_cfg.get("container_image_regex") or ""),
    )

    def _run(name: str, *extras: str) -> CommandResult:
        return _exec_mysqladmin(runner, [*base_args, name, *extras], env_extra, container)

    try:
        r_status = _run("status")
    except MysqladminUnavailable as e:
        return {"status": "missing_tool", "tool": "mysqladmin", "error": str(e)}

    if r_status.exit_code != 0:
        return {
            "status": "error",
            "command": "mysqladmin status",
            "stderr": r_status.stderr.strip()[:2000],
            "stdout": r_status.stdout.strip()[:2000],
            "container": container,
        }

    threads_connected = None
    m = re.search(r"Threads:\s*(\d+)", r_status.stdout)
    if m:
        threads_connected = _parse_int(m.group(1))
    questions = None
    m = re.search(r"Questions:\s*(\d+)", r_status.stdout)
    if m:
        questions = _parse_int(m.group(1))
    slow = None
    m = re.search(r"Slow queries:\s*(\d+)", r_status.stdout)
    if m:
        slow = _parse_int(m.group(1))

    ext_kv: Dict[str, str] = {}
    try:
        r_ext = _run("extended-status")
    except MysqladminUnavailable:
        r_ext = CommandResult(argv=[], exit_code=127, duration_ms=0, stdout="", stderr="", timed_out=False)
    if r_ext.exit_code == 0:
        for line in r_ext.stdout.splitlines():
            if "\t" not in line:
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            ext_kv[parts[1].strip()] = parts[3].strip()

    var_kv: Dict[str, str] = {}
    try:
        r_var = _run("variables")
    except MysqladminUnavailable:
        r_var = CommandResult(argv=[], exit_code=127, duration_ms=0, stdout="", stderr="", timed_out=False)
    if r_var.exit_code == 0:
        for line in r_var.stdout.splitlines():
            if "\t" not in line:
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            var_kv[parts[1].strip()] = parts[3].strip()

    innodb_reads = _parse_int(ext_kv.get("Innodb_buffer_pool_reads", "")) if ext_kv else None
    innodb_read_requests = _parse_int(ext_kv.get("Innodb_buffer_pool_read_requests", "")) if ext_kv else None
    threads_running = _parse_int(ext_kv.get("Threads_running", "")) if ext_kv else None
    aborted_clients = _parse_int(ext_kv.get("Aborted_clients", "")) if ext_kv else None
    aborted_connects = _parse_int(ext_kv.get("Aborted_connects", "")) if ext_kv else None
    max_used_conn = _parse_int(ext_kv.get("Max_used_connections", "")) if ext_kv else None
    slow_queries_total = _parse_int(ext_kv.get("Slow_queries", "")) if ext_kv else slow

    max_conn_var = _parse_int(var_kv.get("max_connections", "")) if var_kv else None
    innodb_buffer_pool_size = _parse_int(var_kv.get("innodb_buffer_pool_size", "")) if var_kv else None

    hit_rate = None
    if innodb_reads is not None and innodb_read_requests and innodb_read_requests > 0:
        hit_rate = max(0.0, min(1.0, 1.0 - (innodb_reads / innodb_read_requests)))

    conn_usage_pct = None
    if max_conn_var and threads_connected is not None and max_conn_var > 0:
        conn_usage_pct = round(threads_connected / max_conn_var * 100.0, 2)

    return {
        "status": "ok",
        "via_docker_container": container,
        "threads_connected": threads_connected,
        "threads_running": threads_running,
        "questions": questions,
        "slow_queries": slow_queries_total,
        "aborted_clients": aborted_clients,
        "aborted_connects": aborted_connects,
        "max_used_connections": max_used_conn,
        "max_connections": max_conn_var,
        "connection_usage_pct": conn_usage_pct,
        "innodb_buffer_pool": {
            "reads": innodb_reads,
            "read_requests": innodb_read_requests,
            "hit_rate": hit_rate,
            "size_bytes": innodb_buffer_pool_size,
        },
        "raw": {
            "status_text": r_status.stdout.strip()[:4000],
            "extended_status_rc": r_ext.exit_code,
            "variables_rc": r_var.exit_code,
        },
    }


# ============================================================
# Docker 容器统计（B5）
# ============================================================


def collect_docker_stats(runner: SafeRunner) -> Dict[str, Any]:
    if not runner.is_allowed("docker"):
        return {"status": "not_allowed", "hint": "通过 -c docker 扩展命令白名单"}
    if not shutil.which("docker"):
        return {"status": "missing_tool", "tool": "docker"}
    argv = [
        "docker",
        "stats",
        "--no-stream",
        "--format",
        "{{.Name}}\t{{.CPUPerc}}\t{{.MemPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}",
    ]
    try:
        r = runner.run_argv(argv)
    except Exception as e:
        return {"status": "error", "error": str(e)}
    if r.exit_code != 0:
        return {"status": "error", "rc": r.exit_code, "stderr": r.stderr.strip()[:1000]}
    rows: List[Dict[str, Any]] = []
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 6:
            continue
        rows.append(
            {
                "name": parts[0].strip(),
                "cpu_pct": parts[1].strip(),
                "mem_pct": parts[2].strip(),
                "mem_usage": parts[3].strip(),
                "net_io": parts[4].strip(),
                "block_io": parts[5].strip(),
            }
        )
    return {"status": "ok", "containers": rows}


def _docker_list_running_containers(runner: SafeRunner) -> Dict[str, Dict[str, str]]:
    """列出当前运行中的容器元信息。"""

    if not runner.is_allowed("docker"):
        return {}
    argv = ["docker", "ps", "--format", "{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"]
    try:
        r = runner.run_argv(argv)
    except Exception:
        return {}
    if r.exit_code != 0:
        return {}
    out: Dict[str, Dict[str, str]] = {}
    for ln in r.stdout.splitlines():
        parts = ln.split("\t")
        if len(parts) < 1:
            continue
        name = parts[0].strip()
        if not name:
            continue
        out[name] = {
            "image": parts[1].strip() if len(parts) > 1 else "",
            "status": parts[2].strip() if len(parts) > 2 else "",
            "ports": parts[3].strip() if len(parts) > 3 else "",
        }
    return out


def _docker_inspect_health(runner: SafeRunner, container: str) -> Dict[str, Any]:
    """读取容器 health/status。"""

    if not DOCKER_CONTAINER_NAME_RE.fullmatch(container):
        return {"status": "invalid_container_name"}
    argv = [
        "docker",
        "inspect",
        "-f",
        "{{.State.Status}}\t{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}",
        container,
    ]
    try:
        r = runner.run_argv(argv)
    except Exception as e:
        return {"status": "error", "error": str(e)}
    if r.exit_code != 0:
        return {"status": "error", "rc": r.exit_code, "stderr": r.stderr.strip()[:500]}
    line = r.stdout.strip().splitlines()[0] if r.stdout.strip() else ""
    parts = line.split("\t")
    return {
        "status": "ok",
        "container_state": parts[0].strip() if len(parts) > 0 else "",
        "health_state": parts[1].strip() if len(parts) > 1 else "none",
    }


def _docker_exec_probe(
    runner: SafeRunner,
    container: str,
    argv_inside: Sequence[str],
    timeout_s: int = 8,
) -> Dict[str, Any]:
    """执行容器内探针命令。"""

    if not DOCKER_CONTAINER_NAME_RE.fullmatch(container):
        return {"status": "invalid_container_name"}
    argv = ["docker", "exec", "-i", container, *list(argv_inside)]
    try:
        r = runner.run_argv(argv, timeout_s=timeout_s)
    except Exception as e:
        return {"status": "error", "error": str(e)}
    return {
        "status": "ok" if r.exit_code == 0 else "failed",
        "rc": r.exit_code,
        "stdout": r.stdout.strip()[:500],
        "stderr": r.stderr.strip()[:500],
    }


def collect_hgdnmpr_services(runner: SafeRunner, cfg: Dict[str, Any]) -> Dict[str, Any]:
    """针对 hg_dnmpr 典型容器做兼容性健康检查。"""

    project_cfg = dict(cfg.get("hgdnmpr", {}))
    if not bool(project_cfg.get("enabled", True)):
        return {"status": "disabled"}
    expected = list(project_cfg.get("containers") or [])
    if not expected:
        return {"status": "skipped", "reason": "no expected containers configured"}

    running = _docker_list_running_containers(runner)
    if not running:
        return {"status": "no_docker_or_no_containers"}

    checks: Dict[str, Any] = {}
    missing: List[str] = []
    unhealthy: List[str] = []
    probe_failed: List[str] = []

    for c in expected:
        info = running.get(c)
        if not info:
            checks[c] = {"present": False}
            missing.append(c)
            continue
        item: Dict[str, Any] = {"present": True, "ps": info}
        hi = _docker_inspect_health(runner, c)
        item["inspect"] = hi
        if hi.get("status") == "ok":
            st = str(hi.get("container_state") or "")
            hs = str(hi.get("health_state") or "")
            if st != "running" or (hs not in ("none", "healthy")):
                unhealthy.append(c)
        else:
            unhealthy.append(c)

        probe: Dict[str, Any] = {"status": "skipped"}
        if c == "mysql":
            probe = _docker_exec_probe(runner, c, ["mysqladmin", "ping", "-h", "127.0.0.1"])
        elif c == "postgres":
            probe = _docker_exec_probe(runner, c, ["pg_isready", "-h", "127.0.0.1", "-p", "5432"])
        elif c == "mongo":
            probe = _docker_exec_probe(runner, c, ["mongosh", "--quiet", "--eval", "db.adminCommand({ping:1}).ok"])
            if probe.get("status") != "ok":
                probe = _docker_exec_probe(runner, c, ["mongo", "--quiet", "--eval", "db.adminCommand({ping:1}).ok"])
        elif c in ("redis", "valkey"):
            probe = _docker_exec_probe(runner, c, ["redis-cli", "ping"])
        elif c == "rabbitmq":
            probe = _docker_exec_probe(runner, c, ["rabbitmq-diagnostics", "-q", "ping"])
        elif c in ("nginx", "tengine"):
            probe = _docker_exec_probe(runner, c, ["curl", "--fail", "--max-time", "3", "http://127.0.0.1/nginx_status"])
            if probe.get("status") != "ok":
                probe = _docker_exec_probe(runner, c, ["curl", "--fail", "--max-time", "3", "http://127.0.0.1/"])
        item["probe"] = probe
        if probe.get("status") not in ("ok", "skipped"):
            probe_failed.append(c)
        checks[c] = item

    present_cnt = sum(1 for x in checks.values() if isinstance(x, dict) and x.get("present"))
    compatible = (len(missing) == 0 and len(unhealthy) == 0 and len(probe_failed) == 0)
    return {
        "status": "ok",
        "expected_containers": expected,
        "present_count": present_cnt,
        "missing_containers": missing,
        "unhealthy_containers": sorted(set(unhealthy)),
        "probe_failed_containers": sorted(set(probe_failed)),
        "compatibility": {
            "perfect_support": compatible,
            "score_pct": round(present_cnt / max(1, len(expected)) * 100.0, 2),
        },
        "checks": checks,
    }


# ============================================================
# 系统并行采集
# ============================================================


def _sample_cpu_mem_loop(duration_s: int, stop: Dict[str, bool]) -> Dict[str, Any]:
    cpu_samples: List[float] = []
    iowait_samples: List[float] = []
    mem_samples: List[float] = []
    load_samples: List[Tuple[float, float, float]] = []
    series_ts: List[str] = []

    prev = read_cpu_jiffies()
    start_mono = time.monotonic()
    for i in range(duration_s):
        if stop.get("flag"):
            break
        time.sleep(max(0.0, (start_mono + (i + 1)) - time.monotonic()))
        cur = read_cpu_jiffies()
        if prev is not None and cur is not None:
            cpu, iow = cpu_pct_from_jiffies(prev, cur)
            if cpu is not None:
                cpu_samples.append(cpu)
            if iow is not None:
                iowait_samples.append(iow)
            prev = cur

        info = read_meminfo()
        used_pct = mem_used_pct(info)
        if used_pct is not None:
            mem_samples.append(used_pct)
        la = read_loadavg()
        if la is not None:
            load_samples.append(la)
        series_ts.append(dt.datetime.now().strftime("%H:%M:%S"))

    return {
        "cpu": {
            "samples": len(cpu_samples),
            "avg_pct": (sum(cpu_samples) / len(cpu_samples)) if cpu_samples else None,
            "peak_pct": max(cpu_samples) if cpu_samples else None,
            "series": cpu_samples,
        },
        "memory": {
            "samples": len(mem_samples),
            "avg_used_pct": (sum(mem_samples) / len(mem_samples)) if mem_samples else None,
            "peak_used_pct": max(mem_samples) if mem_samples else None,
            "series": mem_samples,
        },
        "iowait": {
            "samples": len(iowait_samples),
            "avg_pct": (sum(iowait_samples) / len(iowait_samples)) if iowait_samples else None,
            "peak_pct": max(iowait_samples) if iowait_samples else None,
            "series": iowait_samples,
        },
        "loadavg": {
            "samples": len(load_samples),
            "last": load_samples[-1] if load_samples else None,
            "peak_1m": max((x[0] for x in load_samples), default=None),
        },
        "series_ts": series_ts,
    }


def _sample_net_dev(duration_s: int, stop: Dict[str, bool]) -> Dict[str, Any]:
    first = read_net_dev()
    elapsed = 0
    target = max(1, duration_s)
    while elapsed < target:
        if stop.get("flag"):
            break
        time.sleep(1.0)
        elapsed += 1
    last = read_net_dev()
    rates: List[Dict[str, Any]] = []
    for iface, lv in last.items():
        fv = first.get(iface)
        if fv is None:
            continue
        rx_kbs = (lv[0] - fv[0]) / max(1, elapsed) / 1024.0
        tx_kbs = (lv[1] - fv[1]) / max(1, elapsed) / 1024.0
        rates.append({"iface": iface, "rx_kb_s": round(rx_kbs, 1), "tx_kb_s": round(tx_kbs, 1)})
    rates.sort(key=lambda r: r["rx_kb_s"] + r["tx_kb_s"], reverse=True)
    return {"status": "ok", "elapsed_s": elapsed, "rates": rates}


def _collect_iostat(runner: SafeRunner, duration_s: int) -> Dict[str, Any]:
    if not (shutil.which("iostat") and runner.is_allowed("iostat")):
        return {"status": "missing_tool", "tool": "iostat"}
    interval = 1
    count = max(2, min(duration_s, 300))
    try:
        r = runner.run_argv(["iostat", "-c", str(interval), str(count)], timeout_s=interval * count + 10)
    except Exception as e:
        return {"status": "error", "error": str(e)}
    iw = _parse_iostat_iowait(r.stdout)
    return {"status": "ok", "iowait_pct_last": iw, "raw": r.stdout[:8000]}


def _collect_iftop(runner: SafeRunner, duration_s: int) -> Dict[str, Any]:
    if not shutil.which("iftop") or not runner.is_allowed("iftop"):
        return {"status": "missing_tool", "tool": "iftop"}
    if not _is_root():
        return {"status": "permission_denied", "hint": "iftop 通常需要 root 权限"}
    secs = max(5, min(duration_s, 300))
    try:
        r = runner.run_argv(
            ["iftop", "-t", "-s", str(secs), "-L", "10", "-n", "-P"],
            timeout_s=secs + 10,
        )
    except Exception as e:
        return {"status": "error", "error": str(e)}
    lines = [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
    interesting: List[str] = []
    for ln in lines:
        if "=>" in ln or "<=" in ln:
            interesting.append(ln)
        if len(interesting) >= 60:
            break
    return {"status": "ok", "top": interesting[:60], "raw_tail": lines[-30:]}


def _collect_nethogs(runner: SafeRunner, duration_s: int) -> Dict[str, Any]:
    if not shutil.which("nethogs") or not runner.is_allowed("nethogs"):
        return {"status": "missing_tool", "tool": "nethogs"}
    if not _is_root():
        return {"status": "permission_denied", "hint": "nethogs 通常需要 root 权限"}
    count = max(5, min(duration_s, 60))
    try:
        r = runner.run_argv(["nethogs", "-t", "-c", str(count), "-d", "1"], timeout_s=count + 10)
    except Exception as e:
        return {"status": "error", "error": str(e)}
    procs: Dict[str, Dict[str, Any]] = {}
    for ln in r.stdout.splitlines():
        if not ln or "/" not in ln:
            continue
        parts = ln.split("\t")
        if len(parts) < 3:
            parts = re.split(r"\s+", ln.strip())
        if len(parts) < 3:
            continue
        name = parts[0]
        sent = _parse_float(parts[1])
        recv = _parse_float(parts[2])
        if sent is None or recv is None:
            continue
        cur = procs.get(name, {"sent_kb_s": 0.0, "recv_kb_s": 0.0, "samples": 0})
        cur["sent_kb_s"] += float(sent)
        cur["recv_kb_s"] += float(recv)
        cur["samples"] += 1
        procs[name] = cur
    top = sorted(
        (
            {
                "process": k,
                "sent_kb_s": v["sent_kb_s"] / max(1, v["samples"]),
                "recv_kb_s": v["recv_kb_s"] / max(1, v["samples"]),
            }
            for k, v in procs.items()
        ),
        key=lambda x: x["sent_kb_s"] + x["recv_kb_s"],
        reverse=True,
    )[:10]
    return {
        "status": "ok",
        "top10": top,
        "raw_head": r.stdout.splitlines()[:30],
        "rc": r.exit_code,
        "stderr": r.stderr[:2000],
    }


def _collect_ifconfig(runner: SafeRunner) -> Dict[str, Any]:
    if not shutil.which("ifconfig") or not runner.is_allowed("ifconfig"):
        return {"status": "missing_tool", "tool": "ifconfig"}
    try:
        r = runner.run_argv(["ifconfig", "-a"])
    except Exception as e:
        return {"status": "error", "error": str(e)}
    return {"status": "ok", "raw": r.stdout.strip()[:16000]}


def _collect_disk_df(runner: SafeRunner) -> Dict[str, Any]:
    try:
        r = runner.run_argv(["df", "-h"])
    except Exception as e:
        return {"status": "error", "error": str(e)}
    used_pcts: List[float] = []
    rows: List[Dict[str, Any]] = []
    lines = r.stdout.splitlines()
    for line in lines[1:]:
        parts = line.split()
        if len(parts) < 6:
            continue
        use = parts[4]
        if use.endswith("%"):
            v = _parse_float(use[:-1])
            if v is not None:
                used_pcts.append(v)
                rows.append(
                    {"filesystem": parts[0], "size": parts[1], "used": parts[2], "avail": parts[3], "use_pct": v, "mount": parts[5]}
                )
    return {
        "status": "ok",
        "max_used_pct": max(used_pcts) if used_pcts else None,
        "rows": sorted(rows, key=lambda r: r["use_pct"], reverse=True)[:20],
    }


def _collect_net_connections(runner: SafeRunner) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    for tool, argv in (
        ("ss", ["ss", "-s"]),
        ("netstat", ["netstat", "-an"]),
        ("lsof", ["lsof", "-nP", "-i"]),
    ):
        if not shutil.which(tool) or not runner.is_allowed(tool):
            out[tool] = {"status": "missing_tool"}
            continue
        try:
            r = runner.run_argv(argv)
            out[tool] = {"rc": r.exit_code, "stdout": r.stdout[:8000], "stderr": r.stderr[:2000]}
        except Exception as e:
            out[tool] = {"error": str(e)}
    return out


# ============================================================
# 总编排
# ============================================================


def collect_all(
    runner: SafeRunner,
    duration_s: int,
    stop: Dict[str, bool],
    parallel: bool,
    log_paths: List[str],
    log_format: str,
    cfg: Dict[str, Any],
    cli_dsn: str,
    logger: logging.Logger,
) -> Dict[str, Any]:
    collected: Dict[str, Any] = {}

    # 进程 Top N 快照
    proc_prev = _snapshot_all_pids()
    start_mono = time.monotonic()

    tasks: Dict[str, Callable[[], Any]] = {
        "system_samples": lambda: _sample_cpu_mem_loop(duration_s, stop),
        "net_throughput": lambda: _sample_net_dev(duration_s, stop),
        "iostat": lambda: _collect_iostat(runner, duration_s),
        "iftop": lambda: _collect_iftop(runner, duration_s),
        "nethogs": lambda: _collect_nethogs(runner, duration_s),
        "ifconfig": lambda: _collect_ifconfig(runner),
        "disk": lambda: _collect_disk_df(runner),
        "connections": lambda: _collect_net_connections(runner),
        "docker_stats": lambda: collect_docker_stats(runner),
        "hgdnmpr_services": lambda: collect_hgdnmpr_services(runner, cfg),
        "app_log": lambda: analyze_access_log(paths=log_paths, window_s=duration_s, log_format=log_format),
        "mysql": lambda: collect_mysql_metrics(runner=runner, cfg=cfg, cli_dsn=cli_dsn),
    }

    results: Dict[str, Any] = {}
    if parallel:
        with ThreadPoolExecutor(max_workers=min(8, len(tasks))) as ex:
            futures = {ex.submit(fn): name for name, fn in tasks.items()}
            for fut in as_completed(futures):
                name = futures[fut]
                try:
                    results[name] = fut.result()
                except Exception as e:
                    logger.warning("collector %s failed: %s", name, e)
                    results[name] = {"status": "error", "error": str(e)}
    else:
        for name, fn in tasks.items():
            try:
                results[name] = fn()
            except Exception as e:
                logger.warning("collector %s failed: %s", name, e)
                results[name] = {"status": "error", "error": str(e)}

    elapsed = max(1.0, time.monotonic() - start_mono)
    proc_cur = _snapshot_all_pids()
    results["top_processes"] = collect_top_processes(elapsed_s=elapsed, prev=proc_prev, cur=proc_cur, top_n=10)

    # 构造 collected 结构（与历史报告兼容）
    sys_block = results.get("system_samples", {})
    collected["system"] = {
        "cpu": sys_block.get("cpu", {}),
        "memory": sys_block.get("memory", {}),
        "iowait": sys_block.get("iowait", {}),
        "loadavg": sys_block.get("loadavg", {}),
        "series_ts": sys_block.get("series_ts", []),
        "iostat": results.get("iostat", {}),
        "disk": results.get("disk", {}),
    }
    collected["network"] = {
        "ifconfig": results.get("ifconfig", {}),
        "iftop": results.get("iftop", {}),
        "nethogs": results.get("nethogs", {}),
        "throughput": results.get("net_throughput", {}),
        "connections": results.get("connections", {}),
    }
    collected["application"] = results.get("app_log", {})
    collected["database"] = results.get("mysql", {})
    collected["docker"] = results.get("docker_stats", {})
    collected["project_support"] = results.get("hgdnmpr_services", {})
    collected["processes"] = results.get("top_processes", {})
    return collected


# ============================================================
# 阈值红绿灯
# ============================================================


def _light_by_threshold(v: Optional[float], yellow: float, red: float) -> str:
    if v is None:
        return "⚪"
    if v >= red:
        return "🔴"
    if v >= yellow:
        return "🟡"
    return "🟢"


def _derive_lights(collected: Dict[str, Any], thresholds: Dict[str, Any]) -> Dict[str, Any]:
    cpu_peak = _deep_get(collected, "system.cpu.peak_pct")
    mem_peak = _deep_get(collected, "system.memory.peak_used_pct")
    disk_full = _deep_get(collected, "system.disk.max_used_pct")
    iowait_peak = _deep_get(collected, "system.iowait.peak_pct")
    err_rate = _deep_get(collected, "application.error_rate_pct")
    threads = _deep_get(collected, "database.threads_connected")
    conn_pct = _deep_get(collected, "database.connection_usage_pct")
    hit_rate = _deep_get(collected, "database.innodb_buffer_pool.hit_rate")
    support_ok = _deep_get(collected, "project_support.compatibility.perfect_support")

    t = thresholds
    lights = {
        "cpu": {"light": _light_by_threshold(cpu_peak, t["cpu"]["yellow"], t["cpu"]["red"]), "peak_pct": cpu_peak},
        "memory": {"light": _light_by_threshold(mem_peak, t["memory"]["yellow"], t["memory"]["red"]), "peak_used_pct": mem_peak},
        "disk": {"light": _light_by_threshold(disk_full, t["disk"]["yellow"], t["disk"]["red"]), "max_used_pct": disk_full},
        "iowait": {"light": _light_by_threshold(iowait_peak, t["iowait"]["yellow"], t["iowait"]["red"]), "peak_pct": iowait_peak},
        "http_error_rate": {
            "light": _light_by_threshold(err_rate, t["http_error_rate"]["yellow"], t["http_error_rate"]["red"]),
            "error_rate_pct": err_rate,
        },
    }
    if threads is None:
        lights["mysql_threads_connected"] = {"light": "⚪", "threads_connected": None}
    else:
        ty = t["mysql_threads"]["yellow"]
        tr = t["mysql_threads"]["red"]
        sev = "🟢"
        if threads >= tr:
            sev = "🔴"
        elif threads >= ty:
            sev = "🟡"
        lights["mysql_threads_connected"] = {
            "light": sev,
            "threads_connected": threads,
            "connection_usage_pct": conn_pct,
        }
    if hit_rate is not None:
        sev = "🟢" if hit_rate >= 0.99 else ("🟡" if hit_rate >= 0.95 else "🔴")
        lights["mysql_buffer_pool_hit"] = {"light": sev, "hit_rate": hit_rate}
    if support_ok is None:
        lights["hgdnmpr_container_support"] = {"light": "⚪", "perfect_support": None}
    else:
        lights["hgdnmpr_container_support"] = {
            "light": "🟢" if bool(support_ok) else "🔴",
            "perfect_support": bool(support_ok),
            "score_pct": _deep_get(collected, "project_support.compatibility.score_pct"),
        }
    return lights


# ============================================================
# AI 调用（D1, D2, D3, D4）
# ============================================================


class OpenAIChatClient:
    def __init__(
        self,
        base_url: str,
        api_key: str,
        timeout_s: int,
        audit: AuditLogger,
        logger: logging.Logger,
    ):
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._timeout_s = timeout_s
        self._audit = audit
        self._logger = logger

    def chat_completions(self, payload: Dict[str, Any]) -> Tuple[int, Dict[str, Any]]:
        url = f"{self._base_url}/v1/chat/completions"
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(url, data=data, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", f"Bearer {self._api_key}")
        self._audit.log("ai_call", url=url, model=str(payload.get("model", "")))
        try:
            with urllib.request.urlopen(req, timeout=self._timeout_s) as resp:
                raw = resp.read()
                return resp.status, json.loads(_best_effort_decode(raw))
        except urllib.error.HTTPError as e:
            try:
                body = json.loads(_best_effort_decode(e.read() or b""))
            except Exception:
                body = {"error": str(e)}
            return int(e.code), body


def _trim_collected_for_prompt(collected: Dict[str, Any], max_chars: int) -> Tuple[Dict[str, Any], List[str]]:
    """超限时按优先级丢弃大字段。"""

    out = json.loads(json.dumps(collected, ensure_ascii=False, default=str))
    dropped: List[str] = []

    def _size() -> int:
        return len(json.dumps(out, ensure_ascii=False, default=str))

    def _drop(path: str) -> None:
        parts = path.split(".")
        cur: Any = out
        for p in parts[:-1]:
            if not isinstance(cur, dict) or p not in cur:
                return
            cur = cur[p]
        if isinstance(cur, dict) and parts[-1] in cur:
            del cur[parts[-1]]
            dropped.append(path)

    drop_order = [
        "network.ifconfig.raw",
        "network.connections.lsof.stdout",
        "network.connections.netstat.stdout",
        "network.iftop.raw_tail",
        "system.iostat.raw",
        "database.raw",
        "system.cpu.series",
        "system.memory.series",
        "system.iowait.series",
        "system.series_ts",
        "application.minute_buckets",
        "processes.by_rss",
        "processes.by_cpu",
    ]
    for p in drop_order:
        if _size() <= max_chars:
            break
        _drop(p)

    return out, dropped


def build_prompt(
    collected: Dict[str, Any],
    max_chars: int,
    system_prompt: str,
) -> Tuple[Dict[str, Any], List[str]]:
    trimmed, dropped = _trim_collected_for_prompt(collected, max_chars)
    user_text = (
        "请基于以下巡检数据，模拟资深运维工程师的诊断过程，输出严格 JSON 对象：\n"
        "{\n"
        '  "executive_summary": "一段专业摘要",\n'
        '  "risk_points": [{"title":"风险点","severity":1-5,"evidence":"证据","impact":"影响","recommendation":"建议"}],\n'
        '  "actions": [{"priority":"P0/P1/P2","action":"可执行建议","command_examples":["..."],"risk":"潜在风险"}]\n'
        "}\n\n"
        "巡检原始数据（JSON）：\n"
        + json.dumps(trimmed, ensure_ascii=False, default=str)
    )
    payload = {
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_text},
        ],
        "_dropped_fields": dropped,
    }
    return payload, dropped


def _extract_json_from_text(text: str) -> Optional[Dict[str, Any]]:
    if not text:
        return None
    try:
        return json.loads(text)
    except Exception:
        pass
    m = re.search(r"\{[\s\S]*\}", text.strip())
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except Exception:
        return None


DEFAULT_SYSTEM_PROMPT = (
    "你是一名资深 SRE/运维工程师，擅长从网络、CPU、内存、磁盘、应用日志、数据库指标综合定位瓶颈，"
    "并输出可执行、分优先级的优化建议。输出必须是严格 JSON 对象。"
)


def ai_analyze(
    client: OpenAIChatClient,
    model: str,
    collected: Dict[str, Any],
    temperature: float,
    max_tokens: int,
    audit: AuditLogger,
    logger: logging.Logger,
    max_prompt_chars: int,
    system_prompt: str,
) -> Dict[str, Any]:
    prompt_payload, dropped = build_prompt(collected, max_prompt_chars, system_prompt)
    base_payload = {
        "model": model,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "messages": prompt_payload["messages"],
        "response_format": {"type": "json_object"},
    }

    delay = 1.0
    last_err: Optional[str] = None
    used_response_format = True

    for attempt in range(1, 4):
        try:
            status, resp = client.chat_completions(base_payload)
        except urllib.error.URLError as e:
            last_err = str(e)
            audit.log("ai_error", attempt=attempt, error=last_err)
            if attempt < 3:
                time.sleep(delay)
                delay *= 2
            continue
        except Exception as e:
            last_err = str(e)
            audit.log("ai_error", attempt=attempt, error=last_err)
            if attempt < 3:
                time.sleep(delay)
                delay *= 2
            continue

        if status == 400 and used_response_format:
            err_msg = json.dumps(resp, ensure_ascii=False, default=str)
            if "response_format" in err_msg or "json_object" in err_msg:
                logger.info("AI 供应商不支持 response_format=json_object，已自动降级")
                base_payload.pop("response_format", None)
                used_response_format = False
                continue

        if status >= 400:
            last_err = json.dumps(resp, ensure_ascii=False, default=str)
            audit.log("ai_error", attempt=attempt, status=status, error=last_err[:1000])
            if attempt < 3:
                time.sleep(delay)
                delay *= 2
            continue

        content = (
            resp.get("choices", [{}])[0]
            .get("message", {})
            .get("content", "")
        )
        if not content:
            return {"status": "empty", "raw": resp, "dropped_fields": dropped}
        audit.log("ai_response", bytes=len(content))

        parsed = _extract_json_from_text(content)
        if parsed is None:
            return {"status": "unparsed_text", "raw": resp, "text": content, "dropped_fields": dropped}
        return {
            "status": "ok",
            "json": parsed,
            "raw": resp,
            "dropped_fields": dropped,
            "used_response_format": used_response_format,
        }

    logger.warning("AI 调用失败: %s", last_err or "unknown")
    return {"status": "error", "error": last_err, "dropped_fields": dropped}


# ============================================================
# 报告渲染（E2 mermaid + E3 history + E4 sidecar）
# ============================================================


def _mermaid_xychart(title: str, y_label: str, ts: List[str], values: List[float], y_max: float = 100.0) -> str:
    if not values:
        return ""
    # 最多 60 个点
    if len(values) > 60:
        step = max(1, len(values) // 60)
        ts = ts[::step][:60]
        values = values[::step][:60]
    xaxis = "[" + ",".join(json.dumps(t, ensure_ascii=False) for t in ts) + "]"
    line = "[" + ",".join(f"{v:.2f}" for v in values) + "]"
    y_top = max(y_max, max(values) * 1.1)
    return (
        "```mermaid\n"
        "xychart-beta\n"
        f"    title \"{title}\"\n"
        f"    x-axis {xaxis}\n"
        f"    y-axis \"{y_label}\" 0 --> {y_top:.1f}\n"
        f"    line {line}\n"
        "```"
    )


def _history_load_last(history_dir: str) -> Optional[Dict[str, Any]]:
    if not history_dir or not os.path.isdir(history_dir):
        return None
    files = sorted(globmod.glob(os.path.join(history_dir, "report_*.collected.json")))
    if not files:
        return None
    try:
        with open(files[-1], "rb") as f:
            return json.loads(_best_effort_decode(f.read()))
    except Exception:
        return None


def _history_archive(history_dir: str, max_keep: int, current_collected: Dict[str, Any], current_md: str) -> str:
    os.makedirs(history_dir, exist_ok=True)
    ts = _human_ts_for_filename()
    base = os.path.join(history_dir, f"report_{ts}")
    with open(base + ".collected.json", "w", encoding="utf-8") as f:
        json.dump(current_collected, f, ensure_ascii=False, indent=2, default=str)
    with open(base + ".md", "w", encoding="utf-8") as f:
        f.write(current_md)

    files = sorted(globmod.glob(os.path.join(history_dir, "report_*.collected.json")))
    if max_keep > 0 and len(files) > max_keep:
        for old in files[:-max_keep]:
            try:
                os.remove(old)
                md = old.replace(".collected.json", ".md")
                if os.path.exists(md):
                    os.remove(md)
            except Exception:
                pass
    return base


def _format_diff(prev: Optional[float], curr: Optional[float], unit: str = "") -> str:
    if prev is None and curr is None:
        return "-"
    if prev is None:
        return f"new={curr}{unit}"
    if curr is None:
        return f"prev={prev}{unit}, now=N/A"
    delta = curr - prev
    sign = "+" if delta >= 0 else ""
    return f"{prev:.2f}{unit} -> {curr:.2f}{unit} ({sign}{delta:.2f})"


def _render_history_diff(prev: Optional[Dict[str, Any]], curr: Dict[str, Any]) -> List[str]:
    if not prev:
        return ["- 无可对比的历史报告"]

    fields: List[Tuple[str, str, str]] = [
        ("CPU peak", "system.cpu.peak_pct", "%"),
        ("Mem peak", "system.memory.peak_used_pct", "%"),
        ("Disk max used", "system.disk.max_used_pct", "%"),
        ("Iowait peak", "system.iowait.peak_pct", "%"),
        ("HTTP error rate", "application.error_rate_pct", "%"),
        ("MySQL threads", "database.threads_connected", ""),
        ("Buffer pool hit rate", "database.innodb_buffer_pool.hit_rate", ""),
    ]
    out: List[str] = []
    for label, path, unit in fields:
        pv = _deep_get(prev, path)
        cv = _deep_get(curr, path)
        out.append(f"- {label}: {_format_diff(pv if isinstance(pv, (int, float)) else None, cv if isinstance(cv, (int, float)) else None, unit)}")
    return out


def render_report(
    collected: Dict[str, Any],
    ai: Dict[str, Any],
    thresholds: Dict[str, Any],
    history_prev: Optional[Dict[str, Any]],
    sidecar_links: Dict[str, str],
) -> str:
    lights = _derive_lights(collected, thresholds)
    now = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    ai_obj = ai.get("json") if isinstance(ai, dict) else None

    lines: List[str] = []
    meta = collected.get("meta", {})
    lines.append("# 服务器带宽与性能智能巡检报告\n")
    lines.append(f"- 生成时间: {now}")
    lines.append(f"- 检测时长: {meta.get('duration_s')} 秒")
    lines.append(f"- 主机: {meta.get('hostname')}")
    lines.append(f"- 是否 root: {meta.get('is_root')}")
    if meta.get("os_release", {}):
        lines.append(f"- OS: {meta['os_release'].get('PRETTY_NAME', '')}")
    lines.append("")

    lines.append("## 执行摘要（红绿灯）")
    for k in (
        "cpu",
        "memory",
        "disk",
        "iowait",
        "http_error_rate",
        "mysql_threads_connected",
        "mysql_buffer_pool_hit",
        "hgdnmpr_container_support",
    ):
        item = lights.get(k)
        if not item:
            continue
        light = item.get("light", "⚪")
        metric = {kk: vv for kk, vv in item.items() if kk != "light"}
        lines.append(f"- {light} {k}: {json.dumps(metric, ensure_ascii=False, default=str)}")
    lines.append("")

    sys_block = collected.get("system", {})
    cpu_series = _deep_get(sys_block, "cpu.series") or []
    mem_series = _deep_get(sys_block, "memory.series") or []
    iow_series = _deep_get(sys_block, "iowait.series") or []
    ts_series = sys_block.get("series_ts") or [str(i) for i in range(max(len(cpu_series), len(mem_series), len(iow_series)))]
    if cpu_series or mem_series or iow_series:
        lines.append("## 系统资源时序（采样窗口内）")
        if cpu_series:
            lines.append(_mermaid_xychart("CPU usage (%)", "percent", ts_series[: len(cpu_series)], cpu_series))
            lines.append("")
        if mem_series:
            lines.append(_mermaid_xychart("Memory usage (%)", "percent", ts_series[: len(mem_series)], mem_series))
            lines.append("")
        if iow_series:
            lines.append(_mermaid_xychart("IOWait (%)", "percent", ts_series[: len(iow_series)], iow_series))
            lines.append("")

    lines.append("## 性能瓶颈热力图（Top5风险点）")
    if ai.get("status") == "ok" and isinstance(ai_obj, dict):
        risks = ai_obj.get("risk_points") or []
        if isinstance(risks, list) and risks:
            for r in risks[:5]:
                if not isinstance(r, dict):
                    continue
                title = str(r.get("title", ""))
                sev = int(r.get("severity", 0) or 0)
                evidence = str(r.get("evidence", ""))
                impact = str(r.get("impact", ""))
                rec = str(r.get("recommendation", ""))
                lines.append(f"- {_severity_to_light(sev)} {title}（S{sev}）")
                if evidence:
                    lines.append(f"  - 证据: {evidence}")
                if impact:
                    lines.append(f"  - 影响: {impact}")
                if rec:
                    lines.append(f"  - 建议: {rec}")
        else:
            lines.append("- ⚪ 未返回风险点列表")
    elif ai.get("status") == "skipped":
        lines.append(f"- ⚪ AI 被跳过（{ai.get('reason')}），仅基于阈值告警")
    else:
        lines.append("- ⚪ AI 分析不可用，已输出基于阈值的基础摘要")
    lines.append("")

    lines.append("## 优化建议（按优先级）")
    if ai.get("status") == "ok" and isinstance(ai_obj, dict):
        actions = ai_obj.get("actions") or []
        if isinstance(actions, list) and actions:
            for a in actions:
                if not isinstance(a, dict):
                    continue
                pr = str(a.get("priority", "P1"))
                act = str(a.get("action", ""))
                risk = str(a.get("risk", ""))
                lines.append(f"- {pr}: {act}")
                ex = a.get("command_examples")
                if isinstance(ex, list) and ex:
                    lines.append(f"  - 示例命令: {', '.join(str(x) for x in ex[:3])}")
                if risk:
                    lines.append(f"  - 风险: {risk}")
        else:
            lines.append("- ⚪ 未返回行动列表")
    else:
        lines.append("- P1: 建议补充 AI 配置（OpenAI 兼容 API Key/Endpoint）以生成更贴近业务的诊断建议")
    lines.append("")

    if ai.get("status") == "ok" and isinstance(ai_obj, dict):
        summary = ai_obj.get("executive_summary")
        if summary:
            lines.append("## AI 自然语言诊断")
            lines.append(str(summary).strip())
            lines.append("")

    # Top URL/IP/UA
    app = collected.get("application", {})
    if isinstance(app, dict) and app.get("status") == "ok":
        if app.get("top_urls"):
            lines.append("## 应用日志 Top URL")
            for row in app["top_urls"]:
                lines.append(f"- {row['key']}: {row['count']}")
            lines.append("")
        if app.get("top_ips"):
            lines.append("## 应用日志 Top IP")
            for row in app["top_ips"]:
                lines.append(f"- {row['key']}: {row['count']}")
            lines.append("")
        if app.get("top_user_agents"):
            lines.append("## 应用日志 Top UA")
            for row in app["top_user_agents"][:5]:
                lines.append(f"- {row['key']}: {row['count']}")
            lines.append("")

    procs = collected.get("processes") or {}
    if isinstance(procs, dict) and procs.get("status") == "ok":
        lines.append("## 进程 Top10（按 CPU）")
        for r in procs.get("by_cpu", [])[:10]:
            lines.append(
                f"- pid={r['pid']} cpu={r['cpu_pct']}% rss={r['rss_mb']}MB state={r['state']} comm={r['comm']}"
            )
        lines.append("")

    # hg_dnmpr 容器兼容性检查
    psup = collected.get("project_support") or {}
    if isinstance(psup, dict):
        lines.append("## hg_dnmpr 容器兼容性")
        if psup.get("status") == "ok":
            comp = psup.get("compatibility", {})
            lines.append(f"- 完美支持: {bool(comp.get('perfect_support'))}")
            lines.append(f"- 覆盖率: {comp.get('score_pct')}%")
            if psup.get("missing_containers"):
                lines.append(f"- 缺失容器: {', '.join(psup.get('missing_containers', []))}")
            if psup.get("unhealthy_containers"):
                lines.append(f"- 非健康容器: {', '.join(psup.get('unhealthy_containers', []))}")
            if psup.get("probe_failed_containers"):
                lines.append(f"- 探针失败容器: {', '.join(psup.get('probe_failed_containers', []))}")
            checks = psup.get("checks", {})
            if isinstance(checks, dict):
                for name, item in sorted(checks.items()):
                    if not isinstance(item, dict):
                        continue
                    present = item.get("present")
                    if not present:
                        lines.append(f"- {name}: ❌ missing")
                        continue
                    st = _deep_get(item, "inspect.container_state") or "unknown"
                    hs = _deep_get(item, "inspect.health_state") or "unknown"
                    pr = _deep_get(item, "probe.status") or "unknown"
                    lines.append(f"- {name}: state={st}, health={hs}, probe={pr}")
        else:
            lines.append(f"- 状态: {psup.get('status')}")
            if psup.get("reason"):
                lines.append(f"- 原因: {psup.get('reason')}")
        lines.append("")

    # 历史对比
    if history_prev is not None:
        lines.append("## 与上一次报告对比")
        lines.extend(_render_history_diff(history_prev, collected))
        lines.append("")

    # sidecar 链接
    if sidecar_links:
        lines.append("## 附属文件")
        for k, v in sidecar_links.items():
            lines.append(f"- {k}: `{v}`")
        lines.append("")

    return "\n".join(lines) + "\n"


# ============================================================
# PID 锁
# ============================================================


class PidLock:
    def __init__(self, path: str):
        self._path = path
        self._fh: Optional[Any] = None

    def acquire(self) -> None:
        os.makedirs(os.path.dirname(self._path) or ".", exist_ok=True)
        fh = open(self._path, "w")
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except Exception:
            fh.close()
            raise RuntimeError(f"已在运行（PID 锁文件被占用）：{self._path}")
        fh.seek(0)
        fh.truncate()
        fh.write(str(os.getpid()))
        fh.flush()
        self._fh = fh

    def release(self) -> None:
        if not self._fh:
            return
        try:
            fcntl.flock(self._fh.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
        try:
            self._fh.close()
        except Exception:
            pass
        self._fh = None


# ============================================================
# main
# ============================================================


def _build_runtime_config(args: argparse.Namespace) -> Dict[str, Any]:
    cfg: Dict[str, Any] = json.loads(json.dumps(DEFAULT_CONFIG))
    if args.config:
        loaded = load_config_file(args.config)
        cfg = _deep_merge(cfg, loaded)

    # CLI 覆盖
    if args.temperature is not None:
        cfg["ai"]["openai"]["temperature"] = float(args.temperature)
    if args.max_tokens is not None:
        cfg["ai"]["openai"]["max_tokens"] = int(args.max_tokens)
    if args.ai_timeout is not None:
        cfg["ai"]["openai"]["timeout_s"] = int(args.ai_timeout)
    if args.model:
        cfg["ai"]["openai"]["model"] = args.model
    if args.ai_system_prompt_file:
        cfg["ai"]["openai"]["system_prompt_file"] = args.ai_system_prompt_file
    if args.no_ai:
        cfg["runtime"]["modes"]["no_net"] = True

    if args.mysql_defaults_file:
        cfg["mysql"]["defaults_file"] = args.mysql_defaults_file
    if args.mysql_socket:
        cfg["mysql"]["socket"] = args.mysql_socket
    if args.mysql_container:
        cfg["mysql"]["container"] = args.mysql_container
    if args.database:
        cfg["mysql"]["dsn"] = args.database

    if args.history_dir:
        cfg["history"]["dir"] = args.history_dir
    if args.no_history:
        cfg["history"]["dir"] = ""

    if args.dry_run:
        cfg["runtime"]["modes"]["dry_run"] = True
    if args.no_install:
        cfg["runtime"]["modes"]["no_install"] = True
    if args.no_net:
        cfg["runtime"]["modes"]["no_net"] = True
    if args.readonly:
        cfg["runtime"]["modes"]["readonly"] = True
    if args.no_audit:
        cfg["logging"]["no_audit"] = True

    if args.quiet:
        cfg["logging"]["level"] = "WARNING"
    if args.verbose:
        cfg["logging"]["level"] = "DEBUG"

    return cfg


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _build_arg_parser().parse_args(argv)
    duration_s = _clamp(args.time, 1, 3600)
    if args.time != duration_s:
        print(f"检测时长已自动修正为 {duration_s} 秒（合法范围 1-3600）", file=sys.stderr)

    ok, reason = check_platform()
    if not ok:
        print(f"平台不支持: {reason}", file=sys.stderr)
        return EXIT_PLATFORM

    try:
        cfg = _build_runtime_config(args)
    except Exception as e:
        print(f"配置加载失败: {e}", file=sys.stderr)
        return EXIT_USAGE

    modes = cfg["runtime"]["modes"]
    readonly = bool(modes["readonly"])
    no_audit = bool(cfg["logging"]["no_audit"]) or readonly

    log_level = str(cfg["logging"].get("level", "INFO")).upper()
    logging.basicConfig(
        level=getattr(logging, log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    logger = logging.getLogger("server_health_ai")

    audit_path = _expand_path(str(cfg["logging"].get("audit_path") or "") or _default_audit_path())
    audit = AuditLogger(audit_path, enabled=not no_audit)

    pid_path = _expand_path(str(cfg["runtime"].get("pid_file") or "/tmp/server_health_ai.pid"))
    lock = PidLock(pid_path)

    stop: Dict[str, bool] = {"flag": False}

    def _on_sig(_sig: int, _frame: Any) -> None:
        stop["flag"] = True
        logger.warning("收到信号，准备终止采样...")

    signal.signal(signal.SIGINT, _on_sig)
    signal.signal(signal.SIGTERM, _on_sig)

    if not _is_root():
        logger.warning("当前非 root 用户：iftop/nethogs/部分 lsof 字段可能不可用，结果将被标记为降级")

    if not readonly:
        try:
            lock.acquire()
        except Exception as e:
            logger.error("%s", str(e))
            return EXIT_LOCK

    try:
        try:
            extra = _parse_extra_commands(args.commands)
        except Exception as e:
            logger.error("额外白名单解析失败: %s", str(e))
            return EXIT_USAGE

        allowed = set(DEFAULT_ALLOWED_COMMANDS)
        for c in extra:
            allowed.add(c)

        runner = SafeRunner(
            allowed_commands=allowed,
            timeout_s=int(cfg["runtime"].get("command_timeout_s", 30) or 30),
            audit=audit,
            logger=logger,
            dry_run=bool(modes["dry_run"]),
        )

        osr = parse_os_release()
        pm = detect_package_manager()
        desired_tools = ["ifconfig", "iftop", "nethogs", "free", "df", "ss", "netstat", "lsof", "iostat", "mysqladmin", "mysql", "docker"]
        env_matrix = ensure_tools(desired_tools, pm, audit, logger, no_install=bool(modes["no_install"]))

        # 应用日志路径解析
        log_paths_cfg: List[str] = list(cfg.get("application", {}).get("log_files") or [])
        if args.file is not None:
            log_paths_cfg = [p for p in args.file if p != "-"]
            if any(p == "-" for p in args.file):
                log_paths_cfg = []
        if not log_paths_cfg:
            default_path = "/var/log/nginx/access.log"
            if os.path.exists(default_path):
                log_paths_cfg = [default_path]
        if log_paths_cfg:
            existing = _expand_log_paths(log_paths_cfg)
            if not existing:
                logger.warning("应用日志未匹配任何文件: %s", log_paths_cfg)
        log_format = args.log_format if args.log_format else cfg["application"].get("log_format", "auto")

        meta = {
            "ts": _now_ts(),
            "duration_s": duration_s,
            "hostname": _safe_hostname(),
            "os_release": osr,
            "is_root": _is_root(),
            "config_source": args.config or "embedded_defaults",
            "allowed_commands": runner.allowed_commands(),
            "modes": modes,
        }

        collected: Dict[str, Any] = {"meta": meta, "environment": env_matrix}
        more = collect_all(
            runner=runner,
            duration_s=duration_s,
            stop=stop,
            parallel=bool(cfg["runtime"].get("parallel", True)),
            log_paths=log_paths_cfg,
            log_format=log_format,
            cfg=cfg,
            cli_dsn=args.database,
            logger=logger,
        )
        collected.update(more)

        # AI
        no_net = bool(modes["no_net"])
        openai_cfg = cfg["ai"]["openai"]
        ai_result: Dict[str, Any]
        if no_net:
            ai_result = {"status": "skipped", "reason": "no_net or no_ai mode"}
        elif not str(openai_cfg.get("api_key", "")).strip():
            ai_result = {"status": "skipped", "reason": "missing api_key"}
        else:
            sys_prompt = DEFAULT_SYSTEM_PROMPT
            spf = _expand_path(str(openai_cfg.get("system_prompt_file") or ""))
            if spf and os.path.isfile(spf):
                try:
                    with open(spf, "rb") as f:
                        sys_prompt = _best_effort_decode(f.read()) or DEFAULT_SYSTEM_PROMPT
                except Exception:
                    pass
            client = OpenAIChatClient(
                base_url=str(openai_cfg.get("base_url")),
                api_key=str(openai_cfg.get("api_key")),
                timeout_s=int(openai_cfg.get("timeout_s", 30) or 30),
                audit=audit,
                logger=logger,
            )
            ai_result = ai_analyze(
                client=client,
                model=str(openai_cfg.get("model") or "gpt-3.5-turbo"),
                collected=collected,
                temperature=float(openai_cfg.get("temperature", 0.2) or 0.2),
                max_tokens=int(openai_cfg.get("max_tokens", 900) or 900),
                audit=audit,
                logger=logger,
                max_prompt_chars=int(cfg["ai"]["budget"].get("max_prompt_chars", 60000) or 60000),
                system_prompt=sys_prompt,
            )

        # 报告 + 旁路文件 + 历史
        report_path = args.report.strip() or os.path.join(os.getcwd(), f"report_{_human_ts_for_filename()}.md")
        sidecar = {}
        if not readonly:
            base, _ = os.path.splitext(report_path)
            collected_path = base + ".collected.json"
            ai_path = base + ".ai.json"
            sidecar = {
                "collected_json": os.path.basename(collected_path),
                "ai_json": os.path.basename(ai_path),
            }

        history_dir = _expand_path(str(cfg["history"].get("dir") or "")) or (_default_history_dir() if not args.no_history else "")
        history_prev = _history_load_last(history_dir) if history_dir else None

        thresholds = cfg["thresholds"]
        md = render_report(
            collected=collected,
            ai=ai_result,
            thresholds=thresholds,
            history_prev=history_prev,
            sidecar_links=sidecar,
        )

        if readonly:
            sys.stdout.write(md)
            return EXIT_OK

        os.makedirs(os.path.dirname(os.path.abspath(report_path)) or ".", exist_ok=True)
        with open(report_path, "w", encoding="utf-8", errors="replace") as f:
            f.write(md)

        base, _ = os.path.splitext(report_path)
        with open(base + ".collected.json", "w", encoding="utf-8") as f:
            json.dump(collected, f, ensure_ascii=False, indent=2, default=str)
        with open(base + ".ai.json", "w", encoding="utf-8") as f:
            json.dump(ai_result, f, ensure_ascii=False, indent=2, default=str)

        if args.json_out:
            jp = _expand_path(args.json_out)
            os.makedirs(os.path.dirname(os.path.abspath(jp)) or ".", exist_ok=True)
            with open(jp, "w", encoding="utf-8") as f:
                json.dump(
                    {"collected": collected, "ai": ai_result, "report_md": report_path},
                    f,
                    ensure_ascii=False,
                    indent=2,
                    default=str,
                )

        if history_dir:
            try:
                _history_archive(history_dir, int(cfg["history"].get("max_keep", 30) or 30), collected, md)
            except Exception as e:
                logger.warning("历史归档失败: %s", e)

        audit.log("report_generate", path=report_path)
        print(report_path)
        return EXIT_OK
    finally:
        audit.close()
        if not readonly:
            lock.release()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc()
        raise SystemExit(EXIT_RUNTIME_ERR)
