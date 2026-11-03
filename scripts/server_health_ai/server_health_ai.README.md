# server_health_ai 使用说明（独立项目）

`server_health_ai.py` 是一个完全独立的 Linux 服务器巡检脚本，功能覆盖：系统资源、网络、应用日志、MySQL、AI 诊断与报告输出。

- 项目目录：`scripts/server_health_ai`
- 入口脚本：`scripts/server_health_ai/server_health_ai.py`
- 运行依赖：Python 标准库（无必须第三方包）

---

## 1. 功能总览

- **系统采样**：基于 `/proc` 采集 CPU、内存、iowait、loadavg、网卡吞吐。
- **并行执行**：核心采集任务并行运行，采样窗口一致。
- **应用日志分析**：支持多日志文件、glob、自定义 log format、Top URL/IP/UA、状态码分桶。
- **MySQL 采集**：支持 DSN、socket、`--defaults-file`，并可自动探测 docker 容器。
- **AI 诊断**：OpenAI 兼容接口，自动 prompt 裁剪，不支持 `response_format` 时自动降级。
- **报告输出**：Markdown 报告 + sidecar JSON + 可选聚合 JSON + 历史 diff。
- **安全执行**：命令白名单、固定 PATH、最小环境变量、审计日志、PID 锁。

---

## 2. 默认阈值（当前版本）

当前默认阈值（黄/红）：

- CPU：`70 / 90`
- 内存：`75 / 90`
- 磁盘使用率：`80 / 90`
- iowait：`10 / 25`
- HTTP 错误率：`1.0 / 5.0`
- MySQL 连接线程：`200 / 500`

配置位置：

- 代码默认：`DEFAULT_CONFIG["thresholds"]`
- 示例配置：`server_health_ai.example.toml`

### 2.1 生产建议阈值模板（保守/标准/激进）

以下模板用于生产环境按业务特征快速选型：

- **保守模板（低误报、偏稳定）**
  - CPU：`75 / 92`
  - 内存：`80 / 92`
  - 磁盘：`85 / 93`
  - iowait：`12 / 30`
  - HTTP 错误率：`1.5 / 6.0`
  - MySQL 线程：`260 / 650`

- **标准模板（推荐默认）**
  - CPU：`70 / 90`
  - 内存：`75 / 90`
  - 磁盘：`80 / 90`
  - iowait：`10 / 25`
  - HTTP 错误率：`1.0 / 5.0`
  - MySQL 线程：`200 / 500`

- **激进模板（早预警、偏敏感）**
  - CPU：`65 / 85`
  - 内存：`70 / 85`
  - 磁盘：`75 / 88`
  - iowait：`5 / 15`
  - HTTP 错误率：`0.5 / 2.0`
  - MySQL 线程：`120 / 300`

可将模板值写入 `server_health_ai.example.toml` 的 `[thresholds.*]` 段后，通过 `--config` 生效。

---

## 3. 环境要求与权限

### 3.1 运行环境

- OS：Linux（脚本启动会校验 `/proc`）
- Python：3.10+
- TOML 配置解析：Python 3.11+（3.10 可用 JSON/INI）

### 3.2 可选系统命令

脚本会在存在时调用：`iftop`、`nethogs`、`iostat`、`ifconfig`、`ss`、`netstat`、`lsof`、`mysqladmin`、`mysql`、`docker`。

缺失时会降级，不影响主流程。

### 3.3 权限建议

- 非 root 也可运行，但 `iftop/nethogs` 通常需要 root。
- `docker` 采集要求当前用户可访问 Docker daemon。

---

## 4. 快速开始

在项目目录执行：

```bash
cd /data/hg_dnmpr/scripts/server_health_ai
```

### 4.1 最小离线只读运行

```bash
python3 server_health_ai.py -t 60 -f - --no-net --no-history --readonly
```

### 4.2 常规运行（生成报告）

```bash
python3 server_health_ai.py \
  -t 120 \
  -f '/var/log/nginx/*.log' \
  -r /tmp/server_health_report.md \
  --json-out /tmp/server_health_report.json
```

### 4.3 使用配置文件运行

```bash
python3 server_health_ai.py --config ./server_health_ai.example.toml -t 90
```

---

## 5. CLI 参数说明（重点）

### 5.1 采集控制

- `-t, --time`：采样时长（1~3600）
- `-f, --file`：日志文件（可重复，支持 glob；传 `-` 表示跳过日志分析）
- `--log-format`：`auto` / `combined` / `combined_with_time` / 自定义命名正则

### 5.2 MySQL

- `-d, --database`：MySQL DSN（禁止带明文密码）
- `--mysql-defaults-file`：如 `~/.my.cnf`
- `--mysql-socket`：如 `/var/run/mysqld/mysqld.sock`
- `--mysql-container`：显式指定 docker 容器名

### 5.3 AI

- `-m, --model`
- `--temperature`
- `--max-tokens`
- `--ai-timeout`
- `--ai-system-prompt-file`
- `--no-ai`（快捷关闭 AI）

### 5.4 输出与历史

- `-r, --report`：Markdown 报告输出路径
- `--json-out`：输出聚合 JSON
- `--history-dir`：历史归档目录
- `--no-history`：禁用历史功能

### 5.5 运行模式

- `--dry-run`：只打印命令，不执行
- `--no-install`：缺工具时不自动安装
- `--no-net`：禁用外部网络（含 AI）
- `--readonly`：只读模式，不写文件
- `--no-audit`：禁用审计日志

---

## 6. 配置文件说明

支持 `.toml`、`.json`、`.ini`。

推荐从模板复制：

```bash
cp server_health_ai.example.toml /etc/server_health_ai.toml
```

加载优先级：

1. 代码默认值
2. `--config` 文件
3. CLI 参数（最高优先级）

---

## 7. 输出文件说明

默认（非 readonly）会生成：

- `report_YYYYMMDD_HHMMSS.md`
- `report_YYYYMMDD_HHMMSS.collected.json`
- `report_YYYYMMDD_HHMMSS.ai.json`

若传 `--json-out`，还会多一份聚合 JSON：

- `{"collected": ..., "ai": ..., "report_md": "..."}`

---

## 8. 退出码

- `0`：成功
- `1`：未捕获运行错误
- `2`：参数或配置错误
- `3`：PID 锁冲突（已有实例运行）
- `4`：平台不支持（非 Linux 或 `/proc` 不可用）

---

## 9. 安全策略

- 命令必须命中白名单；`argv[0]` 禁止带 `/`。
- 子进程固定 `PATH=/usr/sbin:/usr/bin:/sbin:/bin`。
- 子进程仅透传最小环境变量（`LANG/LC_ALL/LC_CTYPE/TERM/TZ`）。
- 禁止自动安装 `mysqladmin/mysql/docker`。
- DSN 中带密码会被拒绝。

---

## 10. systemd 定时运行

项目已提供模板：

- `server-health-ai.service`
- `server-health-ai.timer`

示例部署：

```bash
cd /data/hg_dnmpr/scripts/server_health_ai
sudo install -d /opt/server_health_ai /var/lib/server-health-ai
sudo install -m 0755 server_health_ai.py /opt/server_health_ai/
sudo install -m 0644 server_health_ai.example.toml /etc/server_health_ai.toml
sudo install -m 0644 server-health-ai.service /etc/systemd/system/
sudo install -m 0644 server-health-ai.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now server-health-ai.timer
systemctl status server-health-ai.timer
```

---

## 11. 测试、Lint、类型检查

在项目目录执行：

```bash
cd /data/hg_dnmpr/scripts/server_health_ai
python3 -m unittest -v test_server_health_ai.py
```

如果本机安装了 `ruff` / `mypy`：

```bash
ruff check server_health_ai.py test_server_health_ai.py
mypy server_health_ai.py
```

---

## 12. 常见问题

### Q1：非 root 运行会失败吗？
不会。仅 `iftop`/`nethogs` 可能权限不足，脚本会降级并继续。

### Q2：没有 MySQL / Docker 会失败吗？
不会。数据库部分会标记为 `missing_tool` 或 `not_allowed`，其它模块照常运行。

### Q3：如何完全离线运行？
使用 `--no-net` 或 `--no-ai`，并避免依赖需要联网安装的路径。

### Q4：如何调低告警敏感度？
修改 `server_health_ai.example.toml` 的 `[thresholds.*]` 并通过 `--config` 加载。
