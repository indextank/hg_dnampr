"""server_health_ai.py 的测试（单元 + 轻量集成，均使用 stdlib unittest）。

用法
====
- ``python3 -m unittest -v test_server_health_ai.py``
- ``python3 test_server_health_ai.py``
- 若安装了 ``pytest``，``pytest test_server_health_ai.py`` 同样能运行。
"""

from __future__ import annotations

import datetime as dt
import contextlib
import io
import json
import os
import sys
import tempfile
import textwrap
import time
import unittest
from typing import Any, Dict

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import server_health_ai as sha  # noqa: E402


# ---------------------------------------------------------------------------
# 数学/通用辅助
# ---------------------------------------------------------------------------


class TestUtilities(unittest.TestCase):
    def test_clamp(self) -> None:
        self.assertEqual(sha._clamp(5, 1, 10), 5)
        self.assertEqual(sha._clamp(-1, 1, 10), 1)
        self.assertEqual(sha._clamp(99, 1, 10), 10)

    def test_percentile_basic(self) -> None:
        xs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        self.assertAlmostEqual(sha._percentile(xs, 50), 5.5, places=3)
        self.assertEqual(sha._percentile(xs, 0), 1)
        self.assertEqual(sha._percentile(xs, 100), 10)

    def test_percentile_empty(self) -> None:
        self.assertIsNone(sha._percentile([], 95))

    def test_severity_to_light(self) -> None:
        self.assertEqual(sha._severity_to_light(5), "🔴")
        self.assertEqual(sha._severity_to_light(2), "🟡")
        self.assertEqual(sha._severity_to_light(0), "🟢")

    def test_deep_get_and_merge(self) -> None:
        d = {"a": {"b": {"c": 1}}}
        self.assertEqual(sha._deep_get(d, "a.b.c"), 1)
        self.assertIsNone(sha._deep_get(d, "a.x.y"))
        merged = sha._deep_merge({"a": {"b": 1, "c": 2}}, {"a": {"b": 9}, "d": 3})
        self.assertEqual(merged, {"a": {"b": 9, "c": 2}, "d": 3})

    def test_best_effort_decode(self) -> None:
        self.assertEqual(sha._best_effort_decode(b"hello"), "hello")
        # gbk
        self.assertIn("中文", sha._best_effort_decode("中文".encode("gbk")))


# ---------------------------------------------------------------------------
# 旧 top/free/iostat 文本解析
# ---------------------------------------------------------------------------


class TestTopFreeIostat(unittest.TestCase):
    def test_parse_top_cpu_idle_line(self) -> None:
        text = "%Cpu(s):  3.5 us,  1.2 sy,  0.0 ni, 94.0 id,  0.5 wa\n"
        self.assertAlmostEqual(sha._parse_top_cpu_usage_percent(text) or -1, 6.0, places=2)

    def test_parse_free_mem_line(self) -> None:
        text = textwrap.dedent(
            """\
                          total        used        free      shared  buff/cache   available
            Mem:           7984        2010         300         210        5670        5560
            Swap:          2047           0        2047
            """
        )
        out = sha._parse_free_mem(text)
        self.assertEqual(out["total_mb"], 7984)
        self.assertEqual(out["used_mb"], 2010)
        self.assertEqual(out["available_mb"], 5560)
        self.assertAlmostEqual(out["used_pct"] or -1, 2010 / 7984 * 100.0, places=4)

    def test_parse_iostat_iowait(self) -> None:
        text = textwrap.dedent(
            """\
            Linux 5.15.0 (host)     04/28/2026

            avg-cpu:  %user   %nice %system %iowait  %steal   %idle
                       3.42    0.00    1.10    1.74    0.00   93.74

            """
        )
        v = sha._parse_iostat_iowait(text)
        self.assertIsNotNone(v)
        assert v is not None
        self.assertAlmostEqual(v, 1.74, places=3)


# ---------------------------------------------------------------------------
# nginx / RFC3339 时间解析
# ---------------------------------------------------------------------------


class TestTimeParsing(unittest.TestCase):
    def test_parse_nginx_time(self) -> None:
        ts = sha._parse_nginx_time("28/Apr/2026:09:30:01 +0800")
        self.assertIsNotNone(ts)
        assert ts is not None
        self.assertEqual(ts.year, 2026)
        self.assertEqual(ts.month, 4)
        self.assertEqual(ts.day, 28)

    def test_parse_rfc3339_with_z(self) -> None:
        ts = sha._parse_rfc3339("2026-04-28T03:30:01Z")
        self.assertIsNotNone(ts)
        assert ts is not None
        self.assertEqual(ts.tzinfo, dt.timezone.utc)

    def test_parse_rfc3339_with_micros(self) -> None:
        ts = sha._parse_rfc3339("2026-04-28T03:30:01.123456789+08:00")
        self.assertIsNotNone(ts)


# ---------------------------------------------------------------------------
# MySQL DSN
# ---------------------------------------------------------------------------


class TestMysqlDsn(unittest.TestCase):
    def test_minimal(self) -> None:
        d = sha._parse_mysql_dsn("mysql://root@localhost")
        self.assertEqual(d, {"user": "root", "password": "", "host": "localhost", "port": 3306})

    def test_with_credentials(self) -> None:
        d = sha._parse_mysql_dsn("mysql://u%40b:p%40ss@db:3307")
        self.assertEqual(d["user"], "u@b")
        self.assertEqual(d["password"], "p@ss")
        self.assertEqual(d["host"], "db")
        self.assertEqual(d["port"], 3307)

    def test_invalid_scheme(self) -> None:
        with self.assertRaises(ValueError):
            sha._parse_mysql_dsn("postgres://root@localhost")


# ---------------------------------------------------------------------------
# Reservoir
# ---------------------------------------------------------------------------


class TestReservoir(unittest.TestCase):
    def test_within_limit(self) -> None:
        r = sha.Reservoir(limit=5)
        for v in (1.0, 2.0, 3.0):
            r.add(v)
        self.assertEqual(r.items, [1.0, 2.0, 3.0])
        self.assertEqual(r.seen, 3)

    def test_overflow_keeps_size(self) -> None:
        r = sha.Reservoir(limit=10)
        for v in range(1000):
            r.add(float(v))
        self.assertEqual(len(r.items), 10)
        self.assertEqual(r.seen, 1000)


# ---------------------------------------------------------------------------
# 应用日志解析（C2 反向扫描 + C3 Top URL/IP）
# ---------------------------------------------------------------------------


def _make_log_line(t: dt.datetime, ip: str, method: str, url: str, status: int, ua: str = "ua/1.0", rt: float = 0.123) -> str:
    ts = t.strftime("%d/%b/%Y:%H:%M:%S %z")
    return (
        f'{ip} - - [{ts}] "{method} {url} HTTP/1.1" {status} 1024 '
        f'"https://ref.example/" "{ua}" {rt:.3f}'
    )


class TestAccessLog(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.NamedTemporaryFile(prefix="access_", suffix=".log", delete=False, mode="w")
        self.path = self.tmp.name

    def tearDown(self) -> None:
        try:
            os.remove(self.path)
        except FileNotFoundError:
            pass

    def test_combined_with_time(self) -> None:
        now = dt.datetime.now(dt.timezone.utc).astimezone()
        lines = []
        for i in range(60):
            t = now - dt.timedelta(seconds=60 - i)
            ip = "1.2.3.4" if i % 2 else "5.6.7.8"
            url = "/api/v1/foo" if i < 50 else "/api/v1/bar"
            lines.append(_make_log_line(t, ip, "GET", url, 200, rt=0.1 + i * 0.001))
        # 注入 5 条 5xx
        for i in range(5):
            t = now - dt.timedelta(seconds=10 - i)
            lines.append(_make_log_line(t, "9.9.9.9", "POST", "/api/v1/error", 500, rt=2.0))
        with open(self.path, "w") as f:
            f.write("\n".join(lines))

        out = sha.analyze_access_log([self.path], window_s=120, log_format="combined_with_time")
        self.assertEqual(out["status"], "ok")
        self.assertGreater(out["total_requests"], 0)
        self.assertIn("top_urls", out)
        self.assertIn("top_ips", out)
        self.assertGreater(len(out["top_urls"]), 0)
        self.assertGreater(out["request_time"]["sampled"], 0)
        self.assertIsNotNone(out["error_rate_pct"])

    def test_skipped_when_paths_empty(self) -> None:
        out = sha.analyze_access_log([], window_s=60)
        self.assertEqual(out["status"], "skipped")

    def test_missing_file(self) -> None:
        out = sha.analyze_access_log(["/nonexistent/path/__nope.log"], window_s=60)
        self.assertEqual(out["status"], "missing")


# ---------------------------------------------------------------------------
# /proc 解析（B1）
# ---------------------------------------------------------------------------


class TestProcParsers(unittest.TestCase):
    def test_cpu_pct_from_jiffies(self) -> None:
        prev = (1000, 800, 50)  # idle+iowait=800
        cur = (2000, 1500, 80)  # delta total=1000, delta idle=700 → used 30%
        cpu, iow = sha.cpu_pct_from_jiffies(prev, cur)
        self.assertIsNotNone(cpu)
        self.assertIsNotNone(iow)
        assert cpu is not None and iow is not None
        self.assertAlmostEqual(cpu, 30.0, places=4)
        self.assertAlmostEqual(iow, 3.0, places=4)

    def test_mem_used_pct(self) -> None:
        info = {"MemTotal": 8 * 1024 * 1024, "MemAvailable": 2 * 1024 * 1024}
        v = sha.mem_used_pct(info)
        self.assertIsNotNone(v)
        assert v is not None
        self.assertAlmostEqual(v, 75.0, places=4)


# ---------------------------------------------------------------------------
# Prompt 体积裁剪（D1）
# ---------------------------------------------------------------------------


class TestPromptTrim(unittest.TestCase):
    def test_drops_in_priority_order(self) -> None:
        big = "x" * 50000
        collected = {
            "system": {
                "cpu": {"peak_pct": 90, "series": [1] * 1000},
                "iostat": {"raw": big},
            },
            "network": {
                "ifconfig": {"raw": big},
                "connections": {"lsof": {"stdout": big}},
                "iftop": {"raw_tail": [big]},
            },
        }
        trimmed, dropped = sha._trim_collected_for_prompt(collected, max_chars=2000)
        self.assertGreater(len(dropped), 0)
        size = len(json.dumps(trimmed, ensure_ascii=False, default=str))
        self.assertLess(size, 60000)


# ---------------------------------------------------------------------------
# JSON/正则的 fallback 提取（D3）
# ---------------------------------------------------------------------------


class TestJsonFallback(unittest.TestCase):
    def test_pure_json(self) -> None:
        d = sha._extract_json_from_text('{"a":1}')
        self.assertEqual(d, {"a": 1})

    def test_with_prose_around(self) -> None:
        d = sha._extract_json_from_text("分析结果如下：\n{\"a\":1, \"b\":[1,2,3]}\n谢谢。")
        self.assertEqual(d, {"a": 1, "b": [1, 2, 3]})

    def test_garbage(self) -> None:
        self.assertIsNone(sha._extract_json_from_text("no braces here"))


# ---------------------------------------------------------------------------
# SafeRunner 安全检查（F1）
# ---------------------------------------------------------------------------


class TestSafeRunner(unittest.TestCase):
    def setUp(self) -> None:
        self.audit = sha.AuditLogger("/tmp/__sha_test_audit.log", enabled=False)
        import logging
        self.logger = logging.getLogger("test")
        self.runner = sha.SafeRunner(
            allowed_commands=["echo", "ls"],
            timeout_s=5,
            audit=self.audit,
            logger=self.logger,
            dry_run=True,
        )

    def test_rejects_path_in_argv0(self) -> None:
        with self.assertRaises(PermissionError):
            self.runner.run_argv(["/bin/echo", "hi"])

    def test_rejects_unsafe_token(self) -> None:
        with self.assertRaises(PermissionError):
            self.runner.run_argv(["echo", "hi; rm -rf /"])

    def test_rejects_not_in_whitelist(self) -> None:
        with self.assertRaises(PermissionError):
            self.runner.run_argv(["nc", "-l"])

    def test_dry_run_returns_zero(self) -> None:
        r = self.runner.run_argv(["echo", "hello"])
        self.assertEqual(r.exit_code, 0)
        self.assertEqual(r.stdout, "")


# ---------------------------------------------------------------------------
# 配置加载（A1）
# ---------------------------------------------------------------------------


class TestConfigLoading(unittest.TestCase):
    def test_load_json(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write(json.dumps({"ai": {"openai": {"model": "gpt-4o"}}}))
            path = f.name
        try:
            cfg = sha.load_config_file(path)
            self.assertEqual(cfg["ai"]["openai"]["model"], "gpt-4o")
        finally:
            os.remove(path)

    def test_load_ini(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".ini", delete=False) as f:
            f.write("[ai.openai]\nmodel = gpt-4o-mini\ntimeout_s = 45\n")
            path = f.name
        try:
            cfg = sha.load_config_file(path)
            self.assertEqual(cfg["ai"]["openai"]["model"], "gpt-4o-mini")
            self.assertEqual(cfg["ai"]["openai"]["timeout_s"], 45)
        finally:
            os.remove(path)

    def test_load_toml(self) -> None:
        if sha.tomllib is None:
            self.skipTest("tomllib not available")
        with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as f:
            f.write('[ai.openai]\nmodel = "gpt-4o"\ntimeout_s = 99\n')
            path = f.name
        try:
            cfg = sha.load_config_file(path)
            self.assertEqual(cfg["ai"]["openai"]["model"], "gpt-4o")
            self.assertEqual(cfg["ai"]["openai"]["timeout_s"], 99)
        finally:
            os.remove(path)


# ---------------------------------------------------------------------------
# 阈值红绿灯
# ---------------------------------------------------------------------------


class TestLights(unittest.TestCase):
    def test_lights_levels(self) -> None:
        thresholds = sha.DEFAULT_CONFIG["thresholds"]
        collected: Dict[str, Any] = {
            "system": {
                "cpu": {"peak_pct": 95},
                "memory": {"peak_used_pct": 50},
                "disk": {"max_used_pct": 85},
                "iowait": {"peak_pct": 5},
            },
            "application": {"error_rate_pct": 0.5},
            "database": {"threads_connected": 600, "innodb_buffer_pool": {"hit_rate": 0.97}},
        }
        lights = sha._derive_lights(collected, thresholds)
        self.assertEqual(lights["cpu"]["light"], "🔴")
        self.assertEqual(lights["memory"]["light"], "🟢")
        self.assertEqual(lights["disk"]["light"], "🟡")
        self.assertEqual(lights["iowait"]["light"], "🟢")
        self.assertEqual(lights["http_error_rate"]["light"], "🟢")
        self.assertEqual(lights["mysql_threads_connected"]["light"], "🔴")
        self.assertEqual(lights["mysql_buffer_pool_hit"]["light"], "🟡")


# ---------------------------------------------------------------------------
# 历史 diff 渲染（E3）
# ---------------------------------------------------------------------------


class TestHistoryDiff(unittest.TestCase):
    def test_diff_render(self) -> None:
        prev = {"system": {"cpu": {"peak_pct": 50}, "memory": {"peak_used_pct": 60}}}
        curr = {"system": {"cpu": {"peak_pct": 70}, "memory": {"peak_used_pct": 60}}}
        out = "\n".join(sha._render_history_diff(prev, curr))
        self.assertIn("CPU peak", out)
        self.assertIn("50.00", out)
        self.assertIn("70.00", out)


class TestLogFormatAndPaths(unittest.TestCase):
    def test_resolve_known_log_format(self) -> None:
        p = sha._resolve_log_format("combined")
        self.assertIsNotNone(p)
        assert p is not None
        self.assertTrue(hasattr(p, "match"))

    def test_resolve_invalid_log_format(self) -> None:
        p = sha._resolve_log_format("(?P<broken>")
        self.assertIsNone(p)

    def test_expand_log_paths_with_glob(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sha_logs_") as d:
            p1 = os.path.join(d, "a.log")
            p2 = os.path.join(d, "b.log")
            p3 = os.path.join(d, "c.txt")
            with open(p1, "w") as f:
                f.write("x")
            with open(p2, "w") as f:
                f.write("y")
            with open(p3, "w") as f:
                f.write("z")
            out = sha._expand_log_paths([os.path.join(d, "*.log"), p1, "-"])
            self.assertEqual(sorted(out), sorted([p1, p2]))


class TestOutputRendering(unittest.TestCase):
    def test_mermaid_xychart_empty(self) -> None:
        self.assertEqual(sha._mermaid_xychart("x", "y", [], []), "")

    def test_mermaid_xychart_nonempty(self) -> None:
        txt = sha._mermaid_xychart("CPU", "percent", ["00:00:01", "00:00:02"], [10.0, 20.5])
        self.assertIn("xychart-beta", txt)
        self.assertIn("CPU", txt)
        self.assertIn("line [10.00,20.50]", txt)

    def test_render_report_contains_history_section(self) -> None:
        collected: Dict[str, Any] = {
            "meta": {"duration_s": 5, "hostname": "h1", "is_root": False, "os_release": {"PRETTY_NAME": "TestOS"}},
            "system": {
                "cpu": {"peak_pct": 10, "series": [10.0]},
                "memory": {"peak_used_pct": 20, "series": [20.0]},
                "iowait": {"peak_pct": 1, "series": [1.0]},
                "series_ts": ["00:00:01"],
                "disk": {"max_used_pct": 30},
            },
            "application": {"status": "ok", "top_urls": [], "top_ips": [], "top_user_agents": []},
            "database": {"threads_connected": 5, "innodb_buffer_pool": {"hit_rate": 0.999}},
            "processes": {"status": "ok", "by_cpu": []},
        }
        prev = {"system": {"cpu": {"peak_pct": 8}}}
        md = sha.render_report(
            collected=collected,
            ai={"status": "skipped", "reason": "no_net"},
            thresholds=sha.DEFAULT_CONFIG["thresholds"],
            history_prev=prev,
            sidecar_links={"collected_json": "a.collected.json"},
        )
        self.assertIn("与上一次报告对比", md)
        self.assertIn("附属文件", md)
        self.assertIn("AI 被跳过", md)


class TestHistoryArchive(unittest.TestCase):
    def test_history_archive_and_load(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sha_hist_") as d:
            collected = {"system": {"cpu": {"peak_pct": 1}}}
            base1 = sha._history_archive(d, 10, collected, "# report 1\n")
            self.assertTrue(os.path.exists(base1 + ".collected.json"))
            self.assertTrue(os.path.exists(base1 + ".md"))
            loaded = sha._history_load_last(d)
            self.assertIsNotNone(loaded)
            assert loaded is not None
            self.assertEqual(loaded["system"]["cpu"]["peak_pct"], 1)

    def test_history_archive_respects_max_keep(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sha_hist_keep_") as d:
            for i in range(5):
                sha._history_archive(d, 2, {"i": i}, f"# report {i}\n")
                time.sleep(0.01)
            files = [x for x in os.listdir(d) if x.endswith(".collected.json")]
            self.assertLessEqual(len(files), 2)


class TestConfigHelpers(unittest.TestCase):
    def test_coerce_scalar(self) -> None:
        self.assertEqual(sha._coerce_scalar("true"), True)
        self.assertEqual(sha._coerce_scalar("false"), False)
        self.assertEqual(sha._coerce_scalar("42"), 42)
        self.assertEqual(sha._coerce_scalar("3.14"), 3.14)
        self.assertEqual(sha._coerce_scalar("abc"), "abc")

    def test_trim_collected_for_prompt_drops_fields(self) -> None:
        big = {"network": {"ifconfig": {"raw": "x" * 100000}}}
        trimmed, dropped = sha._trim_collected_for_prompt(big, 3000)
        self.assertTrue(len(dropped) >= 1)
        self.assertNotIn("raw", trimmed.get("network", {}).get("ifconfig", {}))


class TestMainIntegration(unittest.TestCase):
    def test_main_readonly_no_net(self) -> None:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = sha.main(["-t", "1", "-f", "-", "--no-net", "--no-history", "--readonly", "--no-audit", "--no-install"])
        self.assertEqual(rc, sha.EXIT_OK)
        out = buf.getvalue()
        self.assertIn("服务器带宽与性能智能巡检报告", out)
        self.assertIn("AI 被跳过", out)

    def test_main_writes_report_and_json_out(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sha_main_") as d:
            report = os.path.join(d, "report.md")
            json_out = os.path.join(d, "report.json")
            rc = sha.main(
                [
                    "-t",
                    "1",
                    "-f",
                    "-",
                    "--no-net",
                    "--no-history",
                    "--no-audit",
                    "--no-install",
                    "-r",
                    report,
                    "--json-out",
                    json_out,
                ]
            )
            self.assertEqual(rc, sha.EXIT_OK)
            self.assertTrue(os.path.exists(report))
            self.assertTrue(os.path.exists(json_out))
            self.assertTrue(os.path.exists(os.path.join(d, "report.collected.json")))
            self.assertTrue(os.path.exists(os.path.join(d, "report.ai.json")))

            with open(json_out, "r", encoding="utf-8") as f:
                payload = json.load(f)
            self.assertIn("collected", payload)
            self.assertIn("ai", payload)
            self.assertIn("report_md", payload)
            self.assertEqual(payload["report_md"], report)
            self.assertIn("meta", payload["collected"])
            self.assertIn("system", payload["collected"])


class _FakeRunner:
    def __init__(self, table: Dict[str, tuple[int, str, str]]):
        self.table = table

    def is_allowed(self, cmd: str) -> bool:
        return cmd == "docker"

    def run_argv(self, argv: list[str], timeout_s: int | None = None):  # noqa: ARG002
        key = " ".join(argv)
        rc, out, err = self.table.get(key, (1, "", "not mocked"))
        return sha.CommandResult(argv=argv, exit_code=rc, duration_ms=0, stdout=out, stderr=err, timed_out=False)


class TestHgDnmprCompatibility(unittest.TestCase):
    def test_collect_hgdnmpr_services_perfect(self) -> None:
        table = {
            "docker ps --format {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}": (
                0,
                "nginx\thg_dnmpr_nginx:latest\tUp 1 hour\t0.0.0.0:80->80/tcp\n"
                "mysql\thg_dnmpr_mysql:latest\tUp 1 hour\t0.0.0.0:3306->3306/tcp\n",
                "",
            ),
            "docker inspect -f {{.State.Status}}\t{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} nginx": (0, "running\thealthy\n", ""),
            "docker inspect -f {{.State.Status}}\t{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} mysql": (0, "running\thealthy\n", ""),
            "docker exec -i nginx curl --fail --max-time 3 http://127.0.0.1/nginx_status": (0, "ok", ""),
            "docker exec -i mysql mysqladmin ping -h 127.0.0.1": (0, "mysqld is alive", ""),
        }
        cfg = {"hgdnmpr": {"enabled": True, "containers": ["nginx", "mysql"]}}
        out = sha.collect_hgdnmpr_services(_FakeRunner(table), cfg)
        self.assertEqual(out["status"], "ok")
        self.assertEqual(out["missing_containers"], [])
        self.assertEqual(out["unhealthy_containers"], [])
        self.assertEqual(out["probe_failed_containers"], [])
        self.assertTrue(out["compatibility"]["perfect_support"])
        self.assertEqual(out["compatibility"]["score_pct"], 100.0)

    def test_collect_hgdnmpr_services_missing_and_failed(self) -> None:
        table = {
            "docker ps --format {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}": (
                0,
                "nginx\thg_dnmpr_nginx:latest\tUp 1 hour\t0.0.0.0:80->80/tcp\n",
                "",
            ),
            "docker inspect -f {{.State.Status}}\t{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} nginx": (0, "running\tunhealthy\n", ""),
            "docker exec -i nginx curl --fail --max-time 3 http://127.0.0.1/nginx_status": (1, "", "500"),
            "docker exec -i nginx curl --fail --max-time 3 http://127.0.0.1/": (1, "", "500"),
        }
        cfg = {"hgdnmpr": {"enabled": True, "containers": ["nginx", "mysql"]}}
        out = sha.collect_hgdnmpr_services(_FakeRunner(table), cfg)
        self.assertEqual(out["status"], "ok")
        self.assertIn("mysql", out["missing_containers"])
        self.assertIn("nginx", out["unhealthy_containers"])
        self.assertIn("nginx", out["probe_failed_containers"])
        self.assertFalse(out["compatibility"]["perfect_support"])


if __name__ == "__main__":
    unittest.main()
