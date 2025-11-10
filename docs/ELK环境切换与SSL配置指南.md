# ELK环境切换与SSL配置指南

## 📖 概述

本项目的ELK Stack支持**开发环境（dev）**和**生产环境（prod）**两种模式，通过环境配置实现自动切换HTTP和HTTPS协议。

## 🚀 快速开始

### 开发环境（默认）
```bash
# 启动开发环境（HTTP，无SSL）
./up.sh elk
# 或明确指定
./up.sh elk dev
```

### 生产环境
```bash
# 启动生产环境（HTTPS，启用SSL）
./up.sh elk prod
```

## 🔧 环境差异对比

| 特性 | 开发环境（dev） | 生产环境（prod） |
|------|----------------|-----------------|
| **协议** | HTTP | HTTPS |
| **端口** | 9333 (HTTP) | 9333 (HTTPS) |
| **SSL/TLS** | 禁用 | 启用 |
| **安全认证** | 启用（Basic Auth） | 启用（Basic Auth + SSL） |
| **证书要求** | 需要（但不使用）* | 需要且使用 |
| **Kibana登录** | http://127.0.0.1:56001 | http://127.0.0.1:56001 |
| **默认账号** | elastic / GwGh_HxORLonWw3jSFk8 | elastic / GwGh_HxORLonWw3jSFk8 |

> *注意：由于Elasticsearch 8.x的严格安全检查，即使开发环境不使用SSL，也需要有效的证书文件存在。

## 📁 配置文件说明

### 环境配置文件

```
config/env/
├── elk.env          # ELK基础配置
├── elk.dev.env      # 开发环境配置（HTTP）
└── elk.prod.env     # 生产环境配置（HTTPS）
```

### 开发环境配置 (elk.dev.env)
```env
ELK_SECURITY_ENABLED=true          # 启用安全功能
ELK_TRANSPORT_SSL_ENABLED=false    # 禁用节点间SSL
ELK_HTTP_SSL_ENABLED=false         # 禁用HTTP SSL
ELASTICSEARCH_PROTOCOL=http        # 使用HTTP协议
```

### 生产环境配置 (elk.prod.env)
```env
ELK_SECURITY_ENABLED=true          # 启用安全功能
ELK_TRANSPORT_SSL_ENABLED=true     # 启用节点间SSL
ELK_HTTP_SSL_ENABLED=true          # 启用HTTP SSL
ELASTICSEARCH_PROTOCOL=https       # 使用HTTPS协议
```

## 🔐 SSL证书管理

### 自动证书生成

`up.sh`脚本会在以下情况自动生成SSL证书：

1. **生产环境首次启动**：如果检测到证书文件不完整
2. **开发环境首次启动**：如果检测到证书文件不存在

### 手动生成证书

```bash
# 手动生成SSL证书
bash scripts/generate-elk-certs.sh
```

生成的证书位于：
```
conf/elasticsearch/certs/
├── ca/
│   ├── ca.crt           # CA证书
│   └── ca.key           # CA私钥
├── elasticsearch/
│   ├── elasticsearch.crt
│   └── elasticsearch.key
├── kibana/
│   ├── kibana.crt
│   └── kibana.key
└── logstash/
    ├── logstash.crt
    └── logstash.key
```

### 证书有效期

- **默认有效期**：10年（3650天）
- **证书类型**：自签名证书（适用于开发/测试环境）
- **生产环境建议**：使用正式CA签发的证书

## 🌐 访问地址

### Elasticsearch

**开发环境**:
```bash
# HTTP访问
curl -u elastic:GwGh_HxORLonWw3jSFk8 http://127.0.0.1:9333
```

**生产环境**:
```bash
# HTTPS访问（忽略自签名证书警告）
curl -k -u elastic:GwGh_HxORLonWw3jSFk8 https://127.0.0.1:9333
```

### Kibana

**所有环境**（Kibana本身不启用HTTPS）:
```
http://127.0.0.1:56001
```

### Logstash

**API端口**:
```
http://127.0.0.1:9600
```

**数据接收端口**:
- Beats: 5044
- TCP: 5000
- HTTP: 8090

## 🔄 环境切换

### 从开发切换到生产

```bash
# 1. 停止开发环境
docker compose -f docker-compose-ELK.yaml down

# 2. 启动生产环境（自动生成证书）
./up.sh elk prod
```

### 从生产切换到开发

```bash
# 1. 停止生产环境
docker compose -f docker-compose-ELK.yaml down

# 2. 启动开发环境
./up.sh elk dev
```

## 🛠️ 技术实现细节

### 1. 配置动态加载

`up.sh`脚本根据环境参数自动加载对应的配置文件：

```bash
./up.sh elk dev   # 加载 elk.dev.env
./up.sh elk prod  # 加载 elk.prod.env
```

### 2. 协议自动切换

- **Elasticsearch**: 通过环境变量`ELK_HTTP_SSL_ENABLED`控制
- **Kibana**: 通过`ELASTICSEARCH_PROTOCOL`环境变量连接到正确的协议
- **Logstash**: 通过`ELASTICSEARCH_PROTOCOL`环境变量设置output URL

### 3. 证书自动检测

`up.sh`中的`check_and_generate_elk_certs`函数会：
- 检测当前环境（dev/prod）
- 验证证书文件完整性
- 必要时自动调用证书生成脚本

### 4. 关键配置文件

**elasticsearch.yml**:
```yaml
xpack.security.enabled: ${ELK_SECURITY_ENABLED}
xpack.security.transport.ssl.enabled: ${ELK_TRANSPORT_SSL_ENABLED}
xpack.security.http.ssl.enabled: ${ELK_HTTP_SSL_ENABLED}
```

**docker-compose-ELK.yaml**:
```yaml
environment:
  ELASTICSEARCH_PROTOCOL: ${ELASTICSEARCH_PROTOCOL:-http}
```

**logstash/conf.d/default.conf**:
```ruby
output {
  elasticsearch {
    hosts => ["${ELASTICSEARCH_PROTOCOL:http}://elasticsearch:9200"]
    user => "${ELASTICSEARCH_USERNAME:elastic}"
    password => "${ELASTICSEARCH_PASSWORD}"
    cacert => "${ELASTICSEARCH_SSL_CERTIFICATE_AUTHORITY}"
  }
}
```

## 📝 常见问题

### Q1: 为什么开发环境也需要证书？

**A**: Elasticsearch 8.x在加载SSL配置时，即使`ssl.enabled=false`，也会验证证书文件的有效性。因此即使不使用SSL，也需要有效的证书文件存在。

### Q2: 如何更换证书？

**A**: 
```bash
# 1. 删除旧证书
rm -rf conf/elasticsearch/certs/{ca,elasticsearch,kibana,logstash}/*.{crt,key}

# 2. 重新生成
bash scripts/generate-elk-certs.sh

# 3. 重启服务
./up.sh elk prod restart
```

### Q3: 证书过期怎么办？

**A**: 重新生成证书并重启服务即可（见Q2）。

### Q4: 如何验证当前使用的协议？

**A**:
```bash
# 查看Elasticsearch环境变量
docker exec elasticsearch env | grep ELK_

# 测试HTTP
curl -I -u elastic:password http://127.0.0.1:9333

# 测试HTTPS
curl -I -k -u elastic:password https://127.0.0.1:9333
```

### Q5: Logstash连接失败怎么办？

**A**: 检查环境变量配置：
```bash
# 进入Logstash容器
docker exec -it logstash bash

# 查看环境变量
env | grep ELASTICSEARCH

# 查看Pipeline配置
cat /usr/share/logstash/pipeline/default.conf
```

## ⚠️ 重要注意事项

1. **证书文件必须存在**：无论开发还是生产环境，证书文件都必须存在且有效
2. **首次启动**：首次启动时`up.sh`会自动生成证书，请耐心等待
3. **端口占用**：确保9333、56001、9600等端口未被占用
4. **密码安全**：生产环境请修改默认密码
5. **防火墙**：如需外部访问，请正确配置防火墙规则

## 🔗 相关文档

- [Elasticsearch Security配置](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/security-settings.html)
- [Kibana Configuration](https://www.elastic.co/guide/en/kibana/8.19/settings.html)
- [Logstash Output Elasticsearch](https://www.elastic.co/guide/en/logstash/8.19/plugins-outputs-elasticsearch.html)

## 📞 技术支持

如遇到问题，请检查：
1. Docker日志：`docker logs elasticsearch|kibana|logstash`
2. 配置文件：`config/env/elk.*.env`
3. 证书文件：`conf/elasticsearch/certs/`

---

**更新日期**：2025-10-24  
**版本**：1.0.0

