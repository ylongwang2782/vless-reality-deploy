#!/bin/bash

# ==========================================
# VLESS + Reality 一键部署脚本
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "配置文件不存在: $CONFIG_FILE"
    exit 1
fi

# 加载配置
source "$CONFIG_FILE"

# 验证必要配置
if [ -z "$VPS_IP" ] || [ -z "$VPS_PASSWORD" ]; then
    log_error "VPS_IP 和 VPS_PASSWORD 必须配置"
    exit 1
fi

log_info "=========================================="
log_info "VLESS + Reality 自动部署"
log_info "=========================================="
log_info "VPS: $VPS_IP"
log_info "域名: ${CF_SUBDOMAIN:-无}.${CF_DOMAIN:-无}"
log_info "=========================================="

# ==========================================
# Step 1: 部署 VPS
# ==========================================
log_info "Step 1: 部署 Xray 到 VPS..."

# 生成临时 expect 脚本
cat > /tmp/deploy_vps.exp << EOF
#!/usr/bin/expect

set timeout 180
set ip "$VPS_IP"
set password "$VPS_PASSWORD"
set user "$VPS_USER"
set script_dir "$SCRIPT_DIR"

# SCP install script
spawn scp -o StrictHostKeyChecking=no \$script_dir/install_vless.sh \$user@\$ip:/root/
expect {
    "password:" { send "\$password\r" }
    timeout { puts "SCP timed out"; exit 1 }
}
expect eof

# SSH to run the script
spawn ssh -o StrictHostKeyChecking=no \$user@\$ip
expect {
    "password:" { send "\$password\r" }
    timeout { puts "SSH timed out"; exit 1 }
}

expect "#"
send "chmod +x /root/install_vless.sh && /root/install_vless.sh '$SUB_PORT' '$NODE_NAME'\r"

expect {
    "Deployment Successful" { }
    timeout { puts "Installation timed out"; exit 1 }
}

expect "#"
send "rm /root/install_vless.sh\r"

expect "#"
send "exit\r"
expect eof
EOF

expect /tmp/deploy_vps.exp
log_info "VPS 部署完成"

# ==========================================
# Step 2: 下载生成的文件
# ==========================================
log_info "Step 2: 下载生成的文件..."

for file in vless_link.txt clash_vless.yaml clash_sub_url.txt vless_qr.png; do
    expect << EOF
set timeout 30
spawn scp -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP:/root/$file $SCRIPT_DIR/
expect {
    "password:" { send "$VPS_PASSWORD\r" }
    timeout { exit 1 }
}
expect eof
EOF
done

log_info "文件下载完成"

# ==========================================
# Step 3: 配置 Cloudflare（可选）
# ==========================================
if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_DOMAIN" ] && [ -n "$CF_SUBDOMAIN" ]; then
    log_info "Step 3: 配置 Cloudflare DNS..."

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
    # Step 4: 配置 SSL 并启用 Cloudflare 代理
    # ==========================================
    log_info "Step 4: 配置 SSL..."

    # 生成 SSL 配置脚本
    cat > /tmp/setup_ssl.sh << 'SSLEOF'
#!/bin/bash
SUB_PORT=$1
CF_SUBDOMAIN=$2
CF_DOMAIN=$3

mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/origin.key \
    -out /etc/nginx/ssl/origin.crt \
    -subj "/CN=$CF_SUBDOMAIN.$CF_DOMAIN" 2>/dev/null

SUB_TOKEN=$(cat /root/clash_sub_url.txt | grep -oE '[a-f0-9]{32}')

cat > /etc/nginx/sites-available/clash-sub << EOF
server {
    listen $SUB_PORT ssl;
    server_name $CF_SUBDOMAIN.$CF_DOMAIN;

    ssl_certificate /etc/nginx/ssl/origin.crt;
    ssl_certificate_key /etc/nginx/ssl/origin.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location /$SUB_TOKEN {
        alias /var/www/sub/clash.yaml;
        default_type 'text/yaml; charset=utf-8';
        add_header Content-Disposition 'attachment; filename="clash.yaml"';
    }

    location / {
        return 404;
    }
}
EOF

nginx -t && systemctl reload nginx
echo "SSL configured"
SSLEOF

    # 上传并执行 SSL 配置脚本
    expect << EOF
set timeout 60
spawn scp -o StrictHostKeyChecking=no /tmp/setup_ssl.sh $VPS_USER@$VPS_IP:/root/
expect {
    "password:" { send "$VPS_PASSWORD\r" }
    timeout { exit 1 }
}
expect eof

spawn ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP
expect {
    "password:" { send "$VPS_PASSWORD\r" }
    timeout { exit 1 }
}
expect "#"
send "chmod +x /root/setup_ssl.sh && /root/setup_ssl.sh '$SUB_PORT' '$CF_SUBDOMAIN' '$CF_DOMAIN'\r"
expect "#"
send "rm /root/setup_ssl.sh\r"
expect "#"
send "exit\r"
expect eof
EOF

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

    # 更新本地订阅链接
    SUB_TOKEN=$(cat "$SCRIPT_DIR/clash_sub_url.txt" | grep -oE '[a-f0-9]{32}')
    echo "https://$CF_SUBDOMAIN.$CF_DOMAIN:$SUB_PORT/$SUB_TOKEN" > "$SCRIPT_DIR/clash_sub_url.txt"

else
    log_warn "未配置 Cloudflare，跳过域名和 SSL 配置"
fi

# ==========================================
# 完成
# ==========================================
echo ""
log_info "=========================================="
log_info "部署完成！"
log_info "=========================================="
echo ""
echo "VLESS 链接:"
cat "$SCRIPT_DIR/vless_link.txt"
echo ""
echo "Clash 订阅链接:"
cat "$SCRIPT_DIR/clash_sub_url.txt"
echo ""
log_info "=========================================="
log_info "本地文件:"
log_info "  - vless_link.txt"
log_info "  - clash_vless.yaml"
log_info "  - clash_sub_url.txt"
log_info "  - vless_qr.png"
log_info "=========================================="
