# ==========================================
# pgvector 镜像（PostgreSQL 18 + pgvector 向量扩展）
# ==========================================
# 策略：基于已构建的 hg_dnmpr_postgres:latest 镜像扩展，apt 安装 postgresql-18-pgvector。
# 优势：完全复用主 PG 镜像的 gosu/entrypoint/locale/PGDG 源 等基础设施，零重复维护。
# 依赖：必须先构建 postgres 镜像（build.sh postgres），再构建 pgvector。
# build.sh 已在服务目录中登记 pgvector 依赖 postgres（见 service_catalog.sh）。
#
# context 仍为项目根（与 postgres-server 一致，由 compose/stacks/databases.yaml 指定）。

FROM hg_dnmpr_postgres:latest

# 代理仅作为构建参数参与 RUN 指令，不写入最终镜像。
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG CHANGE_SOURCE=false

# PGDG 源已在基础镜像中配置（bookworm-pgdg main 18），直接安装 pgvector 扩展包。
# postgresql-18-pgvector 由 PGDG 官方仓库提供，无需额外添加源。
RUN set -eux; \
    # 受限网络下禁用 apt 代理（与主 PG 镜像一致）
    echo 'Acquire::http::Proxy "false";' > /etc/apt/apt.conf.d/99noproxy; \
    echo 'Acquire::https::Proxy "false";' >> /etc/apt/apt.conf.d/99noproxy; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-18-pgvector; \
    rm -rf /var/lib/apt/lists/*; \
    # 验证扩展控制文件已就位（CREATE EXTENSION vector 时由 PG 自动发现）
    ls -l /usr/share/postgresql/18/extension/vector* >/dev/null 2>&1 || { \
        echo "ERROR: pgvector 扩展文件未找到，请检查 PGDG 源是否包含 postgresql-18-pgvector"; \
        exit 1; \
    }

# entrypoint / CMD / EXPOSE / STOPSIGNAL 全部继承自基础镜像，无需重复声明。
# 使用时在目标库执行：CREATE EXTENSION IF NOT EXISTS vector;
