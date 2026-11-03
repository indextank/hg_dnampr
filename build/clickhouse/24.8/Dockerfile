# ==========================================
# ClickHouse 自建镜像（基于官方 clickhouse/clickhouse-server）
# ==========================================
# 策略：FROM 官方镜像，预置时区、自定义 config.xml/users.xml 覆盖层、Prometheus metrics 端点。
# 官方镜像内置 entrypoint 会自动加载 /etc/clickhouse-server/config.d/ 与 users.d/ 下的覆盖文件，
# 因此采用"增量覆盖"而非"整体替换"，避免与官方默认配置脱节。
#
# context 为项目根（与其它服务一致，由 compose/stacks/databases.yaml 指定 context: ../..）。

ARG CLICKHOUSE_IMAGE=clickhouse/clickhouse-server:24.8
FROM ${CLICKHOUSE_IMAGE}

# 代理仅作为构建参数，不写入最终镜像。
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG CHANGE_SOURCE=false

# 时区设置（与项目其它服务对齐，由 env TZ 注入运行时；此处仅设置镜像默认值）
ARG TZ=Asia/Shanghai
ENV TZ=${TZ}

# 增量覆盖配置文件：
# - config.d/hg_dnmpr.xml：监听地址、内存上限、时区、Prometheus metrics 端点（9362）
# - users.d/hg_dnmpr.xml：默认管理员用户（密码由运行时 env CLICKHOUSE_PASSWORD 注入，见 entrypoint 脚本）
# 官方镜像 entrypoint 会以 root 启动、读取这些 .d 目录、降权到 clickhouse 用户后启动 server。
COPY ./build/clickhouse/24.8/config/config.d/hg_dnmpr.xml /etc/clickhouse-server/config.d/hg_dnmpr.xml
COPY ./build/clickhouse/24.8/config/users.d/hg_dnmpr.xml /etc/clickhouse-server/users.d/hg_dnmpr.xml

# 入口脚本：运行时根据 CLICKHOUSE_USER/CLICKHOUSE_PASSWORD 环境变量重写 users.d 配置中的密码哈希。
# 官方镜像默认 entrypoint 为 /entrypoint.sh，我们通过 compose command 覆盖调用本脚本后再 exec 官方 entrypoint。
COPY ./build/clickhouse/24.8/config/docker-entrypoint-init.sh /entrypoint-init.sh
RUN chmod +x /entrypoint-init.sh

# 端口说明：
# 8123 = HTTP 接口（JDBC/HTTP 客户端、ClickHouse 内部管理）
# 9000 = 原生 TCP 接口（clickhouse-client 默认）
# 9009 = 集群间副本/分布式通信
# 9362 = Prometheus metrics 端点（由 config.d/hg_dnmpr.xml 开启）
EXPOSE 8123 9000 9009 9362
