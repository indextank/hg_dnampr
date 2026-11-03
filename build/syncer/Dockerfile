# ==========================================
# Syncer — go_mysq_sync_es 项目的 Docker 镜像
# ==========================================
# 多阶段构建: Go 1.23 编译 → Alpine 3.19 运行时
# 构建产物: syncer (守护进程) + syncer-cli (管理工具)

# Build stage
FROM golang:1.23-alpine AS builder

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY
ARG CHANGE_SOURCE=false

# 将 build-arg 注入 RUN 环境（与 mysql/mongo 等镜像一致；否则 go mod download 不走代理）
# 代理仅作为构建参数参与 RUN 指令，不写入运行镜像。

RUN if [ "${CHANGE_SOURCE}" = "true" ]; then \
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories; \
    go env -w GOPROXY=https://goproxy.cn,direct; \
    go env -w GOSUMDB=sum.golang.google.cn; \
    fi

RUN apk add --no-cache git ca-certificates

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o /app/syncer ./cmd/syncer
RUN CGO_ENABLED=0 GOOS=linux go build -o /app/syncer-cli ./cmd/cli

# Runtime stage
FROM alpine:latest

ARG CHANGE_SOURCE=false

RUN if [ "${CHANGE_SOURCE}" = "true" ]; then \
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories; \
    fi

RUN apk add --no-cache ca-certificates tzdata iputils

WORKDIR /app

COPY --from=builder /app/syncer /app/syncer
COPY --from=builder /app/syncer-cli /app/syncer-cli
COPY configs/ /app/configs/

EXPOSE 8080

ENTRYPOINT ["/app/syncer"]
CMD ["--config", "/app/configs/config.yaml"]
