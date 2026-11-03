# Prometheus + Grafana 监控方案

本文档说明当前项目的完整监控栈部署、自动发现、告警和验证流程。

## 组件

监控栈由 `compose/stacks/monitoring.yaml` 管理，运行在 `hg_dnmpr_network` 网络中。

- Prometheus：指标采集、告警规则计算。
- Alertmanager：接收 Prometheus 告警，默认本地空接收器，可后续接入 Webhook、邮件或企业 IM。
- Grafana：仪表板、Prometheus/Loki/Alertmanager 数据源展示。
- Loki + Promtail：Docker 容器日志采集与 RabbitMQ ACK 超时日志检索。
- cAdvisor：自动发现并采集所有 Docker 容器 CPU、内存、网络、文件系统指标。
- Node Exporter：采集宿主机基础指标。
- Blackbox Exporter：HTTP 健康探测。
- 服务 exporter：MySQL、MongoDB、PostgreSQL、Redis、Valkey、Nginx、Tengine；RabbitMQ 使用官方 `rabbitmq_prometheus` 插件。

## 环境与端口

端口绑定由 `env/base.env` 的 `ENVIRONMENT` 统一决定。

- `development` / `dev`：Prometheus 与 Grafana 仅绑定 `127.0.0.1`。
- `production` / `prod`：Prometheus 与 Grafana 绑定 `0.0.0.0`，可通过云服务器公网 IP 访问。

生产环境请同时在云安全组和服务器防火墙放行：

- `9090/tcp`：Prometheus
- `3000/tcp`：Grafana

建议生产环境使用 Nginx/Caddy 反向代理并启用 HTTPS 与访问控制，不要长期暴露默认端口到公网。

## 启动

```bash
./build.sh monitoring
./up.sh monitoring -d
```

`build.sh monitoring` 会拉取所有监控镜像，不执行本地构建。

`up.sh monitoring -d` 会在启动前自动执行：

```bash
bash include/shell/generate-monitoring-config.sh
```

该脚本会根据 `env/base.env` 及监控阈值生成：

- `build/monitoring/prometheus/rules/project-alerts.yml`
- `build/monitoring/prometheus/targets/blackbox-http.yml`

## 自动服务发现策略

当前方案分为两层：

1. cAdvisor 自动采集所有运行中的容器指标，因此新增容器会自动出现在容器 CPU、内存、网络等图表中。
2. 性能指标通过 exporter 暴露，Prometheus 统一抓取。新增服务时推荐新增对应 exporter 和 scrape job。

现有 exporter 目标：

- `syncer-mysql-exporter:9104`
- `syncer-mongo-exporter:9216`
- `syncer-postgres-exporter:9187`
- `syncer-redis-exporter:9121`
- `syncer-valkey-exporter:9121`
- `syncer-nginx-exporter:9113`
- `syncer-tengine-exporter:9113`
- `rabbitmq:15692`（RabbitMQ 官方 Prometheus 插件）

## RabbitMQ 告警

三类核心告警位于 `build/monitoring/prometheus/rules/project-alerts.yml`。

- `RabbitMQAckTimeoutLogDetected`：Promtail 匹配 RabbitMQ ACK 超时相关日志，并将计数指标暴露给 Prometheus。
- `RabbitMQQueueBacklogHigh`：队列 ready 消息堆积超过阈值。
- `RabbitMQUnackedMessagesHigh`：unacked 消息过高。
- `MessageSyncLagHigh`：Syncer 消费延迟过高。

阈值在 `env/base.env` 中配置：

```env
MONITORING_RABBITMQ_READY_THRESHOLD=1000
MONITORING_RABBITMQ_UNACKED_THRESHOLD=500
MONITORING_SYNC_LAG_THRESHOLD=1000
MONITORING_ACK_TIMEOUT_WINDOW=5m
```

修改阈值后重新执行：

```bash
./up.sh monitoring restart
```

## Grafana

访问地址：

- 开发环境：`http://127.0.0.1:3000`
- 生产环境：`http://<服务器IP>:3000`

默认账号由环境变量控制：

```env
GF_ADMIN_USER=admin
GF_ADMIN_PASSWORD=admin
```

当前自动配置的数据源：

- Prometheus
- Loki
- Alertmanager

当前自动配置的仪表板：

- `HG DNMP 运行总览`
- `MySQL 监控总览`
- `MongoDB 监控总览`
- `MySQL-ES 同步器监控`

## Loki 日志查询

RabbitMQ ACK 超时日志查询示例：

```logql
{container="rabbitmq"} |~ "(?i)(ack.{0,80}(timeout|timed out)|timeout.{0,80}ack|consumer.{0,80}ack)"
```

按项目查看日志：

```logql
{compose_project=~"hg_dnmpr.*"}
```

## 验证

启动后运行：

```bash
bash include/shell/check-monitoring.sh
```

验证内容包括：

- Compose 配置有效性。
- Prometheus ready 状态。
- Prometheus target 状态。
- Prometheus 告警规则加载。
- Grafana API 可访问。
- Loki ready 状态。
- Promtail 是否被 Prometheus 抓取。

手动验证建议：

1. 停止一个非关键服务，确认 Prometheus `up == 0` 或 cAdvisor 图表出现异常。
2. 在 RabbitMQ 中制造测试队列堆积，确认 `RabbitMQQueueBacklogHigh` 进入 pending/firing。
3. 写入一条包含 `ack timeout` 的 RabbitMQ 测试日志或复现消费确认超时，确认 Loki 能查到日志且 Promtail 指标递增。
4. 打开 Grafana `HG DNMP Runtime Overview`，检查容器、数据库、RabbitMQ、Syncer 与日志面板。

## 故障排查

- Prometheus target down：打开 `http://127.0.0.1:9090/targets` 查看具体 exporter。
- exporter 认证失败：检查 `env/mysql.env / env/postgres.env / env/mongodb.env`、`redis.env`、`rabbitmq.env` 中的账号密码是否和容器内实际一致。
- RabbitMQ target down：先执行 `./build.sh rabbitmq --auto-up` 或重建 RabbitMQ 镜像，确保自定义镜像已启用 `rabbitmq_prometheus` 插件。
- Loki 无日志：确认 Promtail 挂载了 `/var/run/docker.sock` 和 `/var/lib/docker/containers`，并检查 `syncer-promtail` 日志。
- Grafana 无仪表板：检查 `build/monitoring/grafana/provisioning/dashboards/provider.yaml` 和 dashboard JSON 是否有效。
