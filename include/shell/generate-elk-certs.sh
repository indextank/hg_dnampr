#!/bin/bash
# ELK SSL证书生成脚本
# 用于生产环境的SSL/TLS配置

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 本文件位于 include/shell/，仓库根为其上两级
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_DIR/build}"
CERTS_DIR="$BUILD_ROOT/elk/${ELK_BUILD_VERSION:-9.5}/elasticsearch/config/certs"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           ELK SSL证书生成工具                                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# 创建证书目录
echo "📁 创建证书目录..."
mkdir -p "$CERTS_DIR"/{ca,elasticsearch,kibana,logstash}

# 生成CA证书
echo "🔐 生成CA根证书..."
cd "$CERTS_DIR/ca"

# 生成CA私钥
openssl genrsa -out ca.key 4096 2>/dev/null

# 生成CA证书
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
  -subj "/C=CN/ST=Beijing/L=Beijing/O=ELK/OU=DevOps/CN=ELK-CA" 2>/dev/null

echo "✅ CA证书生成完成: $CERTS_DIR/ca/ca.crt"

# 生成Elasticsearch证书
echo "🔐 生成Elasticsearch证书..."
cd "$CERTS_DIR/elasticsearch"

# 生成私钥
openssl genrsa -out elasticsearch.key 2048 2>/dev/null

# 创建证书签名请求配置
cat > elasticsearch.cnf << 'EOFCNF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = CN
ST = Beijing
L = Beijing
O = ELK
OU = Elasticsearch
CN = elasticsearch

[v3_req]
keyUsage = digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = elasticsearch
DNS.2 = localhost
IP.1 = 127.0.0.1
EOFCNF

# 生成证书签名请求
openssl req -new -key elasticsearch.key -out elasticsearch.csr -config elasticsearch.cnf 2>/dev/null

# 使用CA签名证书
openssl x509 -req -in elasticsearch.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key \
  -CAcreateserial -out elasticsearch.crt -days 3650 \
  -extensions v3_req -extfile elasticsearch.cnf 2>/dev/null

# 清理临时文件
rm elasticsearch.csr elasticsearch.cnf

echo "✅ Elasticsearch证书生成完成"

# 生成Kibana证书
echo "🔐 生成Kibana证书..."
cd "$CERTS_DIR/kibana"

# 生成私钥
openssl genrsa -out kibana.key 2048 2>/dev/null

# 创建证书签名请求配置
cat > kibana.cnf << 'EOFCNF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = CN
ST = Beijing
L = Beijing
O = ELK
OU = Kibana
CN = kibana

[v3_req]
keyUsage = digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = kibana
DNS.2 = localhost
IP.1 = 127.0.0.1
EOFCNF

# 生成证书签名请求
openssl req -new -key kibana.key -out kibana.csr -config kibana.cnf 2>/dev/null

# 使用CA签名证书
openssl x509 -req -in kibana.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key \
  -CAcreateserial -out kibana.crt -days 3650 \
  -extensions v3_req -extfile kibana.cnf 2>/dev/null

# 清理临时文件
rm kibana.csr kibana.cnf

echo "✅ Kibana证书生成完成"

# 生成Logstash证书
echo "🔐 生成Logstash证书..."
cd "$CERTS_DIR/logstash"

# 生成私钥
openssl genrsa -out logstash.key 2048 2>/dev/null

# 创建证书签名请求配置
cat > logstash.cnf << 'EOFCNF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = CN
ST = Beijing
L = Beijing
O = ELK
OU = Logstash
CN = logstash

[v3_req]
keyUsage = digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = logstash
DNS.2 = localhost
IP.1 = 127.0.0.1
EOFCNF

# 生成证书签名请求
openssl req -new -key logstash.key -out logstash.csr -config logstash.cnf 2>/dev/null

# 使用CA签名证书
openssl x509 -req -in logstash.csr -CA ../ca/ca.crt -CAkey ../ca/ca.key \
  -CAcreateserial -out logstash.crt -days 3650 \
  -extensions v3_req -extfile logstash.cnf 2>/dev/null

# 清理临时文件
rm logstash.csr logstash.cnf

echo "✅ Logstash证书生成完成"

# 设置权限
echo "🔧 设置证书文件权限..."
chmod 644 "$CERTS_DIR"/{ca,elasticsearch,kibana,logstash}/*.crt
chmod 600 "$CERTS_DIR"/{ca,elasticsearch,kibana,logstash}/*.key

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           ✅ SSL证书生成完成！                                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "📁 证书位置："
echo "   CA证书: $CERTS_DIR/ca/"
echo "   Elasticsearch: $CERTS_DIR/elasticsearch/"
echo "   Kibana: $CERTS_DIR/kibana/"
echo "   Logstash: $CERTS_DIR/logstash/"
echo ""
echo "🚀 现在可以启动 ELK（环境由 env/base.env 的 ENVIRONMENT 决定）："
echo "   ./up.sh elk"
echo ""

