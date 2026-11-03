# AGENTS MySQL — 版本与配置核验规则

面向「新增 / 升级 MySQL 大版本」与「修改 mysql-*.cnf」场景的强制核验规则。
本文件由 `AGENTS.md` 的 Trigger 表按需加载，不参与常规上下文。

## Trigger Index

| 触发场景 | 加载段落 |
| --- | --- |
| 新增 `build/mysql/<新版本>/` 目录、升级 `MYSQL_BUILD_VERSION` | `## MYSQL-ADD-VERSION` |
| 修改 `build/mysql/*/config/conf.d/*.cnf` | `## MYSQL-CNF-CHANGE` |
| 增删 `scripts/check-mysql-cnf-drift.sh` 的白名单 | `## MYSQL-DRIFT-WHITELIST` |
| 判定「某参数属于哪个版本」 | `## MYSQL-PARAM-PROBE` |
| 需要输出结论 | `## MYSQL-OUTPUT` + `## MYSQL-FORBIDDEN` |

# Detection Rules

- 判定「是否为新增版本」：`ls build/mysql/` 出现此前不存在的版本目录，或 `env/mysql.env` 的 `MYSQL_BUILD_VERSION` 指向新目录。
- 判定「是否为配置变更」：diff 命中 `build/mysql/*/config/conf.d/*.cnf` 或 `build/mysql/*/config/my.cnf`。
- 上述任一命中即**必须先读本文件的对应段落**，再动代码。

# Rule Index

## MYSQL-PARAM-PROBE

《禁止凭记忆判定参数归属版本，必须实测》

单参数归属探测（**必须显式区分 `mysqld_rc` 与 grep 结果，切勿用 `| grep` 后的 `$?` 当 mysqld 退出码**）：

```bash
docker run --rm --entrypoint bash hg_dnmpr_mysql:<ver> -c '
  out=$(mysqld --validate-config --log-error-verbosity=3 --<param>=<value> 2>&1); rc=$?
  printf "%s\n" "$out" | grep -E "MY-0000(67|68)|MY-011068"
  echo "mysqld_rc=$rc"'
```

判据：

| 观测 | 含义 |
| --- | --- |
| `mysqld_rc=0` 且无输出 | 支持，无副作用 |
| `mysqld_rc=0` 且出现 `MY-011068` | 支持但已废弃 → 不得使用，改用替代项 |
| `mysqld_rc=1` 且出现 `MY-000067` / `MY-000068` | 不支持（未知变量/未知选项），写入将导致 mysqld 拒绝启动 |

默认值探测（用于判断「不显式配置时三版本是否等价」）：

```bash
docker run --rm --entrypoint bash hg_dnmpr_mysql:<ver> -c \
  "mysqld --verbose --help 2>/dev/null | grep -E '^<param> '"
```

已实证的版本差异（MySQL 8.0.46 / 8.4.13 / 9.7.4，勿凭印象改动，改动须附新实证）：

| 参数 | 8.0 | 8.4 | 9.7 | 归属 |
| --- | --- | --- | --- | --- |
| `skip-host-cache` | 支持但报 `MY-011068` 废弃 | 已移除（硬失败） | 已移除（硬失败） | 禁用于所有版本，统一用 `host_cache_size=0` |
| `default-authentication-plugin` | 支持 | 已移除 | 已移除 | 仅 `8.0/mysql-{dev,prod}.cnf` |
| `mysql-native-password` | 不支持 | 支持 | 已移除 | 仅 `8.4/docker.cnf` |

其余环境级参数（`innodb_*`、`max_connections`、`sql_mode`、`tls_version`、`local_infile`、
`secure_file_priv`、`character_set_server` 等）**在上述三版本间默认值一致**，
故 `mysql-dev.cnf` / `mysql-prod.cnf` / `mysql-wsl.cnf` 允许跨版本同源——
但「允许同源」不等于「可以不再验证」，见 `## MYSQL-ADD-VERSION` 步骤 4。

## MYSQL-ADD-VERSION

《新增版本必须按序完成，缺一步即不得声称完成》

1. **复制基线（仅环境档）**
   - `mysql-{dev,prod,wsl}.cnf`：从**版本号最接近**的已有目录复制（如新增 9.8 → 复制 9.7）。
   - `docker.cnf` 与 `Dockerfile` / `docker-entrypoint.sh`：**逐个文件判定**，不得整目录复制后不检查。
     认证相关三选项（见上表）必须按新版本实测结果决定保留/删除。
2. **目录与构建变量**
   - 目录名必须与 `MYSQL_BUILD_VERSION` 取值一致（`8.0` / `8.4` / `9.7` 风格）。
   - 检查 `build/mysql/<ver>/Dockerfile`：`ENV MYSQL_MAJOR`、apt 仓库通道（`mysql-8.0` / `mysql-8.4` / `mysql-9.x`）必须与新版本匹配。
3. **构建镜像**（`hg_dnmpr_mysql:<ver>`，验证后才允许清理）
   ```bash
   docker buildx build --allow=network.host --network=host \
     --build-arg MYSQL_VER= --build-arg MYSQL_PIN_POLICY=latest \
     -f build/mysql/<ver>/Dockerfile -t hg_dnmpr_mysql:<ver> --load .
   ```
4. **三档 × 新版本逐一 `--validate-config`**（必须全绿，仅 dev 档允许保留 `MY-010101`）
   ```bash
   ver=<新版本>
   for f in dev prod wsl; do
     docker run --rm -v "$PWD/build/mysql/$ver/config/conf.d/mysql-$f.cnf:/src/env.cnf:ro" \
       -v "$PWD/build/mysql/$ver/config/conf.d/docker.cnf:/src/docker.cnf:ro" \
       --entrypoint bash hg_dnmpr_mysql:$ver -c '
         cp /src/env.cnf /etc/mysql/conf.d/mysql-env.cnf
         cp /src/docker.cnf /etc/mysql/conf.d/docker.cnf
         chmod 644 /etc/mysql/conf.d/*.cnf
         out=$(mysqld --validate-config --log-error-verbosity=3 2>&1); rc=$?
         printf "%s\n" "$out" | grep -E "unknown (variable|option)|removed|MY-011068|MY-010915"
         echo "mysqld_rc=$rc"'
   done
   ```
   判据：`mysqld_rc=0` 且 grep 无输出 = 通过。
   出现 `unknown variable` / `unknown option` / `removed` / `MY-011068` / `MY-010915` 一律视为失败。
5. **真实启动三档**（不能只靠 `--validate-config`）
   ```bash
   bash scripts/check-mysql-cnf-drift.sh --validate   # 静态等值 + 版本专属 + 镜像级
   bash scripts/check-mysql-runtime-cnf.sh           # 真实容器：挂载源 / 权限 / 标志参数
   ```
   至少验证：`SHOW VARIABLES` 中标志参数与档位预期一致、启动日志无 warning、容器 `healthy`。
6. **同步外围清单**
   - `scripts/check-mysql-cnf-drift.sh` 的 `ALLOW_LINES`：**只在步骤 4 实证出差异后**才加条目，禁止预设。
   - `env/mysql.env`：`MYSQL_BUILD_VERSION` 注释与资源上限（`MYSQL_PROD_*_MEMORY` 必须
     ≥ `mysql-prod.cnf` 的 `innodb_buffer_pool_size` + 非池内存 ≈5G）。
   - `README.md`：MySQL 版本与选择规则表。
7. **收尾**：删除验证用临时镜像 tag（保留 `:latest` 对应版本），并在交付说明中列出实测输出。

## MYSQL-CNF-CHANGE

- 改动必须落到**所有已支持版本**的同名文件，除非该行属 `## MYSQL-PARAM-PROBE` 表格中的版本专属项。
- 改完必须执行：

```bash
bash scripts/check-mysql-cnf-drift.sh            # 静态等值 + 版本专属断言
bash scripts/check-mysql-cnf-drift.sh --validate # 追加镜像级校验
```

- `sql_mode`：启用 `STRICT_TRANS_TABLES` 时必须同时声明 `NO_ZERO_DATE,NO_ZERO_IN_DATE,ERROR_FOR_DIVISION_BY_ZERO`，
  否则触发 `MY-010915`。

## MYSQL-DRIFT-WHITELIST

- 脚本按 `build/mysql/*/` 目录**自动发现版本**，新增版本无需改脚本主体，只需按需维护白名单。
- 白名单（`ALLOW_LINES`）只接受**实测驱动的差异**：先在 `## MYSQL-PARAM-PROBE` 拿到 `mysqld_rc` 证据，再登记。
- 新增条目必须写成 `<版本>:<锚定正则>`，并同步本文件 `## MYSQL-PARAM-PROBE` 表格。
- 禁止为「让脚本变绿」而扩大白名单、放宽正则或注释掉断言。

## MYSQL-OUTPUT

新增/升级版本、修改 cnf 后，回复必须包含：

1. 基线来源（复制自哪个版本）与 `docker.cnf` 逐项判定结论。
2. 三档 × 新版本 `--validate-config` 的 rc 与告警原文（或明确「无告警」）。
3. `scripts/check-mysql-cnf-drift.sh --validate` 的 RESULT 行。
4. 真实启动后的标志参数值（`SHOW VARIABLES` 摘录）与容器健康状态。
5. 外围清单（白名单 / env / README）是否需要变动的结论。

## MYSQL-FORBIDDEN

- 禁止凭记忆或训练知识断言「某参数在某版本可用」，必须实测。
- 禁止整目录复制新版本后不做逐项 `--validate-config` 就交付。
- 禁止把 8.4 独有的 `mysql-native-password`、8.0 独有的 `default-authentication-plugin`
  抄到不支持的版本（会导致 mysqld 拒绝启动）。
- 禁止用注释掉的方式「保留」已移除参数（如 `#skip_host_cache`），应直接删除并替换为等价配置。
- 禁止跳过 `scripts/check-mysql-cnf-drift.sh` 就声称配置一致。
- 禁止留下验证用临时镜像 tag 或未清理的 cnf 副本。
