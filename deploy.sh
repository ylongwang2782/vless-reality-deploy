#!/bin/bash

# ==========================================
# VLESS + Reality 一键部署脚本
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 解析参数
NODE_ID=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--node)
            NODE_ID="$2"
            shift 2
            ;;
        -h|--help)
            echo "用法: $0 [--node <node_id>]"
            exit 0
            ;;
        *)
            log_error "未知参数: $1"
            echo "用法: $0 [--node <node_id>]"
            exit 1
            ;;
    esac
done

# 加载配置
source "$SCRIPT_DIR/config.sh"
if ! load_config "$NODE_ID"; then
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no"

log_info "=========================================="
log_info "VLESS + Reality 自动部署"
log_info "=========================================="
log_info "VPS: $VPS_IP"
log_info "SSH Host: $SSH_HOST"
log_info "域名: ${CF_SUBDOMAIN:-无}.${CF_DOMAIN:-无}"
log_info "=========================================="

# ==========================================
# Step 1: 部署 VPS
# ==========================================
log_info "Step 1: 部署 Xray 到 VPS..."

scp $SSH_OPTS "$SCRIPT_DIR/install_vless.sh" "$SSH_HOST:/root/"
ssh $SSH_OPTS "$SSH_HOST" "chmod +x /root/install_vless.sh && /root/install_vless.sh $(printf %q "$SUB_PORT") $(printf %q "$NODE_NAME") && rm /root/install_vless.sh"
log_info "VPS 部署完成"

# ==========================================
# Step 2: 配置 Cloudflare（可选）
# ==========================================
if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_DOMAIN" ] && [ -n "$CF_SUBDOMAIN" ]; then
    log_info "Step 2: 配置 Cloudflare DNS..."

    # 获取 Zone ID
    ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json")

    ZONE_ID=$(echo "$ZONE_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$ZONE_ID" ]; then
        log_error "无法获取 Cloudflare Zone ID"
        exit 1
    fi

    log_info "Zone ID: $ZONE_ID"

    # 检查 DNS 记录是否存在
    RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$CF_SUBDOMAIN.$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json")

    RECORD_ID=$(echo "$RECORD_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -n "$RECORD_ID" ]; then
        # 更新现有记录
        log_info "更新 DNS 记录..."
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$CF_SUBDOMAIN\",\"content\":\"$VPS_IP\",\"ttl\":1,\"proxied\":false}" > /dev/null
    else
        # 创建新记录
        log_info "创建 DNS 记录..."
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$CF_SUBDOMAIN\",\"content\":\"$VPS_IP\",\"ttl\":1,\"proxied\":false}" > /dev/null
    fi

    log_info "DNS 配置完成: $CF_SUBDOMAIN.$CF_DOMAIN -> $VPS_IP"

    # ==========================================
    # Step 3: 配置 SSL 并启用 Cloudflare 代理
    # ==========================================
    log_info "Step 3: 配置 SSL 证书..."

    # 生成 SSL 配置脚本（只生成证书，订阅服务由 sync_users.sh 配置）
    cat > /tmp/setup_ssl.sh << 'SSLEOF'
#!/bin/bash
CF_SUBDOMAIN=$1
CF_DOMAIN=$2

mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/origin.key \
    -out /etc/nginx/ssl/origin.crt \
    -subj "/CN=$CF_SUBDOMAIN.$CF_DOMAIN" 2>/dev/null

echo "SSL certificate generated"
SSLEOF

    # 上传并执行 SSL 配置脚本
    scp $SSH_OPTS /tmp/setup_ssl.sh "$SSH_HOST:/root/"
    ssh $SSH_OPTS "$SSH_HOST" "chmod +x /root/setup_ssl.sh && /root/setup_ssl.sh $(printf %q "$CF_SUBDOMAIN") $(printf %q "$CF_DOMAIN") && rm /root/setup_ssl.sh"

    log_info "SSL 配置完成"

    # 启用 Cloudflare 代理
    log_info "启用 Cloudflare 代理..."

    # 重新获取 Record ID
    RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$CF_SUBDOMAIN.$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json")
    RECORD_ID=$(echo "$RECORD_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data '{"proxied":true}' > /dev/null

    log_info "Cloudflare 代理已启用"

else
    log_warn "未配置 Cloudflare，跳过域名和 SSL 配置"
fi

# ==========================================
# Step 4: 同步用户配置（如果存在 users.yaml）
# ==========================================
USERS_FILE="$SCRIPT_DIR/users.yaml"

if [ -f "$USERS_FILE" ]; then
    log_info "Step 4: 同步用户配置..."
    if [ -n "$NODE_ID" ]; then
        "$SCRIPT_DIR/sync_users.sh" --node "$NODE_ID"
    else
        "$SCRIPT_DIR/sync_users.sh"
    fi
else
    log_warn "未找到 users.yaml，跳过多用户配置"
    log_info "如需添加用户，请复制 users.yaml.example 为 users.yaml 并编辑"
    echo ""
    log_info "=========================================="
    log_info "VPS 部署完成！"
    log_info "请配置 users.yaml 后运行 sync_users.sh 添加用户"
    log_info "=========================================="
fi
