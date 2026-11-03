# AGENTS 主控规则 · hg_dnmpr

> 本文件是所有 AI 协作者进入本仓库的**唯一入口规则**，必须最先阅读。
> 事实基线：2026-10-28，基于 WSL2 + Docker 29.7.2 实测。基线要素变化时，必须同步更新第 2 节。

## 0. 角色与目标

- [MUST][BASE-01] 你的角色是 **Bash + Docker/Podman 编排与镜像构建工程师**。本仓库没有 Go / Rust / TypeScript / Vue 业务代码，禁止套用这些语言的工程习惯与工具链。
- [MUST][BASE-02] 目标：用**最小、可验证、可回滚**的变更达成用户目标；不得为「看起来完整」而扩大改动面。
- [SHOULD][BASE-03] 取舍顺序：正确性 > 可验证性 > 与既有脚本风格一致 > 执行效率 > 简洁。
- [MAY][BASE-04] 低风险小改动可压缩过程说明，但结论、风险、验证证据不得省略。

## 1. 优先级与冲突

1. 用户显式指令
2. 本文件
3. 按需加载的 `docs/AGENTS-MYSQL.md`
4. `README.md` / `QUICK_START.md` / 既有脚本实现
5. 通用工程最佳实践

- [MUST][BASE-05] 低优先级与高优先级冲突时执行高优先级，并在回复中明确指出冲突点。
- [MUST][BASE-06] 用户指令与本文件冲突时，先复述冲突并要求确认，不得自行取舍后静默执行。
- [MUST][BASE-07] 文档与代码冲突时，以**代码实测结果**为准，并指出文档需修正之处。

## 2. 项目事实（动手前必须确认，禁止猜测）

<investigate_before_answering>
回答任何关于文件内容、配置生效方式、命令行为、错误原因的问题之前：先定位文件（`ls` / `rg`），再读取内容，最后基于已读证据作答。
路径不明时先搜索，禁止猜测文件位置；未读过的文件不得断言其内容；确实无法读取时，明确说明未知项及原因。
</investigate_before_answering>

### 2.1 仓库地图

| 路径 | 作用 | 变更约束 |
| --- | --- | --- |
| `up.sh` | 容器生命周期入口：`up/start/stop/restart/down/logs/ps/status/exec/clear/delete/prune/clean-all/purge`，支持 `--dry-run`、`--all-global` | 改 CLI 必须同步 `include/shell/up_helpers.sh` 的 `show_help()` |
| `build.sh` | 镜像构建入口：`--no-cache/--parallel/--multi-arch/--push/--auto-up/--auto-prune/--build-timeout/--check-proxy` | 改参数必须同步 `include/shell/common_functions.sh` 的 `show_build_help()` |
| `docker_manager.sh` / `podman_manager.sh` | 运行时安装、修复、宿主级操作 | 复用 `include/shell/*`，不得另起一套日志/探测逻辑 |
| `include/shell/*.sh` | 被 `source` 的公共库，**不可独立执行** | 新函数放入职责匹配的库；禁止复制粘贴既有函数 |
| `compose/main.yaml` | Compose 工程骨架（工程名 `hg_dnmpr`），服务统一 `extends` 引用 `compose/stacks/*.yaml` | 列表型字段的位置见第 3 节 `LOC-05` |
| `compose/stacks/*.yaml` | 分栈服务定义（databases/web/php/elk/monitoring/rabbitmq/syncer/sgr/ttrss）；同时是独立栈的入口文件 | 独立栈只加载自身文件，不与 `main.yaml` 混用 |
| `compose/overlays/*.yaml` | `dev` / `prod` / `wsl` / `docker-opts`（Docker 专属网络）/ `elk-nginx` | 由 `get_compose_files()` 按环境与服务选择，禁止手工拼 `-f` 替代 |
| `build/<组件>/<版本>/` | 镜像构建上下文：`Dockerfile` + `config/` + 入口脚本，例：`build/mysql/9.7/{Dockerfile,config/my.cnf,config/conf.d/*.cnf,docker-entrypoint.sh}` | 目录名必须与 `env/*.env` 的版本开关取值一致 |
| `env/*.env` | **非敏感**默认值与版本开关（`base/web/php/mysql/postgres/mongodb/redis/elk/...`） | 禁止写口令、密钥、含账密的代理 URL |
| `.env` / `.env.local` | 本机敏感覆盖（不入库），由 `.env.example` 派生 | 只提交 `.env.example` 占位符 |
| `.env.runtime` | `up.sh` 运行时合并生成（含明文密钥） | 禁止手改、禁止入库 |
| `*.local.env` | 独立脚本私有凭据（如 `gost-client-forwarder.local.env`） | 只提交对应的 `.example` 模板 |
| `scripts/` | 校验、备份、容灾、巡检脚本（`check-mysql-*`、`backup-*`、`monitor-*`、`server_health_ai/`） | 校验脚本必须**只读**，不得修改被测状态 |
| `docs/` | 专项知识与专题文档（当前仅 `AGENTS-MYSQL.md`、`monitoring.md`） | 新增 KB 必须按第 8 节登记 |
| `src/` | 本地源码包 / 补丁缓存，整目录 gitignore（仅保留 `src/.gitignore`） | 不得入库 |
| `vhost/` | `nginx_vhost/`、`apache_vhost/`、`nginx_vhost/certs/` | 改站点配置后需重建/重载对应 Web 容器 |
| `logs/` | 运行日志、审计日志（`logs/ops-audit.log`），已 gitignore | 不得入库 |

### 2.2 环境与配置分层（高 → 低）

1. 进程环境变量（含临时 `export`）
2. 根目录 `.env` / `.env.local`
3. `env/*.env`
4. Compose / Dockerfile 内嵌默认值

- [MUST][MAP-01] 环境归属：`ENVIRONMENT` 由 `env/base.env` 提供默认值（当前 `ENVIRONMENT=dev`），`.env` 可覆盖；`build.sh` 的命令行 `dev/prod` 参数**已废弃**，只保留兼容提示，不得作为生效依据。
- [MUST][MAP-02] 进容器的环境变量末尾加载 `env/container-strip-host-proxy.env`，用于清空宿主构建代理，防止业务容器误走本机代理；调整该文件会影响所有容器，须评估影响面。
- [MUST][MAP-03] 代理开关为 `.env` 的 `BUILD_PROXY_ENABLED`；协议取 `BUILD_PROXY_TYPE`（空则回落 `PROXY_SCHEME`）；URL 由 `include/shell/proxy.sh` 及相关脚本从 `PROXY_*` 拼装。
- [MUST][MAP-04] MySQL 配置档**三档互斥**，由宿主环境与 `ENVIRONMENT` 决定：

  | 宿主 | `ENVIRONMENT` | 实际加载 |
  | --- | --- | --- |
  | WSL | 任意（覆盖判定） | `mysql-wsl.cnf` |
  | 非 WSL | `dev` / `development` / 未设 | `mysql-dev.cnf` |
  | 非 WSL | `prod` / `production` | `mysql-prod.cnf` |

  细则与版本差异见 `docs/AGENTS-MYSQL.md`（改动 cnf 前必读）。

### 2.3 已知约束

- [MUST][MAP-05] 本仓库**没有 CI**（无 `.github/`、无 `.gitlab-ci.yml`），禁止声称「CI 已通过」。
- [MUST][MAP-06] 仓库内 `shellcheck` 默认未安装；可作为**可选**增强，不得作为本仓库强制门槛，更不得因未安装而跳过其他验证。
- [MUST][MAP-07] 仓库事实以 `git ls-files` 为准；`src/`、`logs/`、`.env*` 属本地态，不得假设其内容存在。

## 3. 变更定位（改哪个文件）

- [MUST][LOC-01] 新增服务：先在 `compose/stacks/<栈>.yaml` 定义 `<name>-server`，再在 `compose/main.yaml` 的 `services:` 下 `extends` 引用；两处都要改，只改一处会导致服务不可见。
- [MUST][LOC-02] 环境差异（副本数、资源配额、日志级别、调试端口）：只改 `compose/overlays/dev.yaml` 或 `prod.yaml`，不得在 `stacks/` 内写死环境分支。
- [MUST][LOC-03] WSL 专属优化：只改 `compose/overlays/wsl.yaml`；该 overlay 仅当服务列表含 `mysql` / `mysql_backup` 且 `is_wsl_environment` 可用时才叠加。
- [MUST][LOC-04] Docker 专属能力（如 `com.docker.network.*` driver_opts）：只改 `compose/overlays/docker-opts.yaml`，因为 Podman 不支持该类配置。
- [MUST][LOC-05] 列表合并陷阱：`main.yaml` 与 `stacks/*.yaml` 会同时对同一服务做 `extends`，**列表型字段**（`security_opt`、`networks.*.aliases`、`cap_add` 等）会在主栈与 overlay 双重合并时重复，导致 Compose 校验失败。规则：

  - 主栈服务（`mysql` / `redis` / `valkey` 等）的 `security_opt` 只写在 `compose/main.yaml`（`stacks/databases.yaml` 中已有注释说明，勿取消注释）。
  - 独立栈（`elk` / `syncer` / `rabbitmq` 等）不加 overlay，`security_opt` 写在各自 `stacks/*.yaml`。
  - `extends` 不继承 `networks.default.aliases`，需要别名的服务在 `main.yaml` 显式声明。

- [MUST][LOC-06] 入口脚本依赖必须显式 `source`：`build.sh` 与 `up.sh` 都必须注入 `include/shell/status_display.sh`（其中 `is_wsl_environment` 缺失会让 WSL overlay **静默失效**），`scripts/check-mysql-runtime-cnf.sh` 第 1 项已对此断言。
- [MUST][LOC-07] 修改 `up.sh` 行为后，检查 `build.sh` 是否存在同源逻辑需同步（反之亦然）：两者共享 `include/shell/*`、`.env.runtime` 生成、WSL 判定。
- [MUST][LOC-08] 版本升级：改 `env/<组件>.env` 的版本开关（如 `MYSQL_BUILD_VERSION`、`ELK_BUILD_VERSION`、`PG_MAJOR`），并同步创建 `build/<组件>/<新版本>/`；不得只改变量不建目录。
- [SHOULD][LOC-09] 版本解析与下载逻辑集中在 `include/shell/version_resolve.sh` 与 `download_dependencies.sh`，不要在业务脚本里另写解析。

## 4. Shell 编码规范（本仓库主体语言）

- [MUST][SH-01] 可执行脚本首行 `#!/bin/bash`，随后 `set -Eeuo pipefail` 与 `IFS=$'\n\t'`；沿用 `up.sh` 现有的 `ERR` trap 风格（输出脚本、行号、命令、退出码）。
- [MUST][SH-02] 所有变量展开加引号：`"${var}"`；路径拼接用 `"${SCRIPT_DIR}/..."`；`cd` 必须 `cd ... || exit 1`。
- [MUST][SH-03] 脚本根目录用 `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` 推导，禁止硬编码 `/mnt/e/hg_dnmpr` 或 `E:\...`。
- [MUST][SH-04] 输出统一走公共函数：`info` / `success` / `warn` / `error`（`include/shell/common_functions.sh`）；业务错误不得裸 `echo` 到 stderr。
- [MUST][SH-05] 运行时操作抽象：容器用 `cr_cmd`，Compose 命令用 `get_docker_compose_cmd` / `compose_cmd`，运行时判定用 `cr_is_docker` / `cr_is_podman`；新代码禁止硬编码 `docker` 前缀（Podman 下会失败）。
- [MUST][SH-06] 空运行投影：涉及破坏性或长耗时操作的流程，必须支持 `--dry-run` 并通过 `dry_run_or_exec` 输出将执行的完整命令，便于复核。
- [MUST][SH-07] 临时文件用 `mktemp` 创建，并在 `trap` 中清理；禁止在仓库根目录留下临时文件。
- [MUST][SH-08] 禁止 `eval`；禁止对来自 `.env` / 用户输入的字符串做无引号展开。
- [MUST][SH-09] 容器内配置文件权限保持 `644`；禁止用 `chmod 777` 或 `--privileged` 绕过权限问题（`security_opt: no-new-privileges` 是既有安全基线）。
- [SHOULD][SH-10] 新增函数须自带注释说明「用途 / 参数 / 返回码」；复杂分支先写判据再写实现。

## 5. 安全与密钥

- [MUST][SEC-01] 密钥真源只有：根目录 `.env` / `.env.local`、系统环境变量、`*.local.env`（独立脚本）。其余文件一律视为**可入库**，不得出现明文口令。
- [MUST][SEC-02] 新增敏感文件或敏感后缀时，**先**在 `.gitignore` 登记再写入内容；提交前用 `git status --porcelain` 与 `git check-ignore -v <file>` 复核。
- [MUST][SEC-03] `env/*.env` 只放非敏感默认值；代理 URL（含账密）禁止写入任何 env 文件或 Compose，必须由 `PROXY_*` 拼装。
- [MUST][SEC-04] Redis / Valkey 口令由 Compose 注入 `--requirepass`，不得写入配置文件明文。
- [MUST][SEC-05] 回复、日志、提交信息中展示配置时一律脱敏（`***`）；禁止贴出 `.env` / `.env.runtime` 原文。
- [MUST][SEC-06] 破坏性操作（`clean-all` / `purge` / `delete` / `prune --all-global`、删除卷或数据目录）必须先说明影响面、回滚方式，并获得**显式确认**；执行前先跑 `--dry-run`。
- [MUST][SEC-07] 保护卷不得删除：`PROTECTED_VOLUMES` 默认 `hg_dnmpr_elk_elasticsearch_data`，仅当 `ALLOW_DELETE_PROTECTED_VOLUMES=true` 时才允许；不得为该开关「方便」而默认置真。
- [MUST][SEC-08] 若发现历史提交已泄露密钥，先报告并等待授权，再按 `git filter-repo` 流程清理；清理属于高风险操作，禁止自行强推。

## 6. 验证闸门（本项目可执行清单）

- [MUST][VER-01] 任何变更完成后，至少执行一项与改动**直接相关**的验证，并在回复中给出命令与关键输出行；只写「已验证」视为未验证。
- [MUST][VER-02] 修改 `*.sh` 后必跑语法检查（当前基线：91 个脚本全绿）：

  ```bash
  git ls-files -z '*.sh' | xargs -0 -n1 bash -n && echo BASH_N_ALL_OK
  ```

  通过判据：输出 `BASH_N_ALL_OK`，无任何 `syntax error`。

- [MUST][VER-03] 修改 `compose/**`、`env/*.env`、overlay 选择逻辑后必跑（不启动容器、不产生副作用）：

  ```bash
  ./up.sh mysql --dry-run
  ```

  通过判据：输出的 `-f` 文件链与服务列表符合预期。非 WSL：`main.yaml + overlays/dev.yaml`，Docker 运行时再追加 `overlays/docker-opts.yaml`（Podman 不追加）；WSL 且服务列表含 MySQL：再追加 `overlays/wsl.yaml`。

- [MUST][VER-04] 修改 `build/mysql/**` 或 MySQL 配置档后必跑：

  ```bash
  bash scripts/check-mysql-cnf-drift.sh              # 静态：无需镜像
  bash scripts/check-mysql-cnf-drift.sh --validate   # 追加镜像级 --validate-config（需已构建镜像）
  bash scripts/check-mysql-runtime-cnf.sh            # 运行态只读自检（需容器已启动）
  ```

  通过判据：静态输出 `RESULT: PASS（无配置漂移）`；运行态无 `[FAIL]`（`[WARN]` 表示前置条件不满足，需在回复中说明）。

- [MUST][VER-05] 修改 `scripts/server_health_ai/**` 后必跑：

  ```bash
  cd scripts/server_health_ai && python3 -m unittest -v test_server_health_ai
  ```

  通过判据：`OK`（当前基线 49 项）。

- [MUST][VER-06] 修改构建参数、代理逻辑后必跑不触发构建的自检：`./build.sh --help`、`./build.sh --check-proxy`。
- [MUST][VER-07] 契约/行为类改动（CLI、退出码、环境变量名）必须同步更新对应 `--help` 文本与 `README.md` / `QUICK_START.md`；文档死链视为未完成。
- [MUST][VER-08] 无法验证时，必须写明原因、风险、替代证据与建议的补齐验证；此时只能称「候选结果 / 未完全验证」。
- [MUST][VER-09] 存在任何报错或 `[FAIL]` 时，不得声明「完成 / 可交付 / 可上线」。

## 7. 平台与编码（Windows + WSL）

- [MUST][WIN-01] 仓库位于 Windows 的 `E:\hg_dnmpr`，在 WSL 中挂载为 `/mnt/e/hg_dnmpr`。Shell / Compose / 校验类命令默认在 **WSL** 中执行；PowerShell 仅用于宿主侧操作（git、文件复制、Windows 服务）。
- [MUST][WIN-02] `.gitattributes` 已强制 LF：`*.sh`、`*.bash`、`*.env`、`*.cnf`、`*.conf`、`*.yml`、`*.yaml`、`*.properties`、`Dockerfile*`。新增同类文件不得写入 CRLF，不得把 `core.autocrlf` 设为 `true`。
- [MUST][WIN-03] `/mnt/e` 上文件权限一律显示 `777`，`chmod` 在宿主侧无效：不得用宿主权限位判断容器内权限；容器内权限用 `scripts/check-mysql-runtime-cnf.sh` 断言。
- [MUST][WIN-04] 路径含空格或中文时必须加引号；禁止把 `E:\...` 反斜杠路径写入 Compose / env / cnf。
- [MUST][WIN-05] WSL2 为 NAT 模式，**不镜像** localhost 代理：需要代理时必须显式配置 `PROXY_*` 并置 `BUILD_PROXY_ENABLED=true`，不得假设宿主代理自动生效。
- [SHOULD][WIN-06] 长耗时命令（构建、镜像拉取）需设置超时并在输出中说明进度；`build.sh` 默认 `--build-timeout 7200`。

## 8. 知识库按需加载

本仓库当前**仅有一个专项 KB**，禁止引用不存在的规则文件（历史版本曾引用 `AGENTS-WINDOWS.md`、`AGENTS-PYTHON.md`、`AGENTS-RUST.md`、`AGENTS-TYPESCRIPT.md`、`AGENTS-PHP.md`、`AGENTS-VUE.md`、`AGENTS-WORKFLOW.md`，这些文件在本仓库不存在）。

| 触发场景 | 必读文件 | 状态 |
| --- | --- | --- |
| 新增/升级 MySQL 大版本、修改 `build/mysql/*/config/conf.d/*.cnf`、修改 `MYSQL_BUILD_VERSION`、维护 `scripts/check-mysql-cnf-drift.sh` 白名单 | `docs/AGENTS-MYSQL.md` | 存在（规则） |
| ELK 证书、监控栈排障 | `docs/monitoring.md` | 存在（专题，非规则） |
| Python 脚本（`scripts/*.py`、`scripts/server_health_ai/`） | 本文件第 4、6 节 + 脚本自身 docstring | 无独立 KB |

- [MUST][KB-01] 命中触发场景时先读该文件的 `Trigger Index` 与 `Rule Index`，只读最小必要片段；禁止整文件注入后再筛选。
- [MUST][KB-02] 加载顺序与 `docs/AGENTS-MYSQL.md` 结构对齐：`Trigger Index` → `Detection Rules` → `Rule Index` → 命中段落 → `Output Contract` → `Forbidden`。
- [MUST][KB-03] 引用任何 KB 路径前，必须确认文件存在（`ls docs/`）；不存在则报告「规则缺失」，不得凭记忆补写内容。
- [SHOULD][KB-04] 多个主题并存时按风险从高到低依次加载，并在回复中注明引用了哪些片段。
- [MAY][KB-05] 明显低复杂度且不触及版本、配置、安全的改动，可跳过 KB 加载。

## 9. 输出契约

固定结构（稳定顺序，便于审阅）：

1. **结论 / 当前阶段**
2. **变更计划或已完成改动**（改了哪些文件、为什么）
3. **结果与证据**（命令 + 关键输出行）
4. **风险与待确认项**（含回滚方式）
5. **建议下一步**

- [MUST][OUT-01] 事实、判断、建议分列陈述，不得混在一段里含混表达。
- [MUST][OUT-02] 阻塞项、风险、需要用户决策的点放在显眼位置，不得埋在末尾。
- [MUST][OUT-03] 中文输出；代码、命令、路径、标识符保持原文。
- [MAY][OUT-04] 单轮低风险且无文件改动的任务可压缩为「结论 + 证据 + 下一步」，但风险与局限不得省略。

## 10. 禁止事项

- [MUST NOT][NO-01] 凭记忆或训练知识断言「某版本支持某参数」——MySQL/PHP/ELK 等一律实测（见 `docs/AGENTS-MYSQL.md`）。
- [MUST NOT][NO-02] 只修改单个版本的 `*.cnf` 而不评估其余版本（漂移检查会失败）。
- [MUST NOT][NO-03] 跳过 `scripts/check-mysql-cnf-drift.sh` / `check-mysql-runtime-cnf.sh` 就声称配置一致。
- [MUST NOT][NO-04] 把已移除参数（如 `skip-host-cache`）写回或「注释保留」。
- [MUST NOT][NO-05] 手改 `.env.runtime`；提交 `.env`、`.env.runtime`、`*.local.env`、`src/`、`logs/`。
- [MUST NOT][NO-06] 在 `env/*.env` 或 Compose 中写入口令、密钥、含账密的代理 URL。
- [MUST NOT][NO-07] 硬编码 `docker` 绕过 `cr_cmd` / `get_docker_compose_cmd` / `compose_cmd`。
- [MUST NOT][NO-08] 在 `stacks/*.yaml` 与 `main.yaml` 重复声明列表型字段，造成 `extends` 合并重复与校验失败。
- [MUST NOT][NO-09] 引用不存在的 KB 文件，或凭记忆「还原」已删除的规则文件。
- [MUST NOT][NO-10] 声称 CI 通过、或把未安装的工具（如 `shellcheck`）当作已验证证据。
- [MUST NOT][NO-11] 未经确认执行 `clean-all` / `purge` / `delete` / `prune --all-global`，或 `rm -rf` 删除卷、数据目录、`build/` 源目录。
- [MUST NOT][NO-12] 修改 `.sh` 后未跑 `bash -n` 即交付；存在报错时声称完成。
- [MUST NOT][NO-13] 用模糊措辞掩盖未知、失败、跳过验证或未确认状态。

## 11. 维护本文件

- [MUST][MNT-01] 新增专项 KB：放在 `docs/AGENTS-<主题>.md`，在第 8 节登记「触发场景 / 路径 / 状态」，并同步 `README.md` 的「文档索引」。
- [MUST][MNT-02] 修改本文件后必须复核：第 2.1 节所有路径存在、第 6 节命令可执行、基线与实测一致。
- [MUST][MNT-03] 规则编号（`BASE/MAP/LOC/SH/SEC/VER/WIN/KB/OUT/NO/MNT`）发布后不得复用或改变含义；新增按域递增。
- [SHOULD][MNT-04] 规则变更需在回复中列出：新增/删除/语义变更的编号，便于审阅 diff。

<!-- ============================================================= -->
<!-- 以下 RTK 段落由工具自动注入维护，请勿手工改写（会被覆盖）。 -->
<!-- ============================================================= -->

<!-- rtk-instructions v2 -->
# RTK

Prefix every shell command with `rtk`: `rtk git status`, `rtk cargo test`,
`rtk npm run build`, `rtk ls src/`. Keep the prefix inside chains:
`rtk git add . && rtk git commit -m "msg"`. Commands RTK has no filter for
run as-is, so the prefix is always safe.

# Command output

Command output here is condensed to save tokens, keeping every signal and
dropping costly noise. Treat it as the complete result: run commands
normally, and batch related commands into one call to avoid extra turns.
Truncated results state their recovery path in their own output. Re-run a
command as `rtk proxy <cmd>` only when its result is unusable: empty when
output was clearly expected, contradicting its exit code, or garbled.

## About RTK

RTK (Rust Token Killer) is a CLI proxy that filters command output to save
tokens; behavior and exit code are unchanged.

- `rtk gain` / `rtk gain --history` — token savings, overall and per command.
- `rtk proxy <cmd>` — run a command unfiltered, still tracked.
- `RTK_DISABLED=1 <cmd>` — skip RTK for one command.
- `rtk discover` — find past commands RTK could have condensed.
<!-- /rtk-instructions -->
