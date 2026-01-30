#!/bin/bash

# ==========================================
# VLESS + Reality 安装脚本
# 用法: ./install_vless.sh [SUB_PORT] [NODE_NAME]
# ==========================================

SUB_PORT=${1:-8443}
NODE_NAME=${2:-My_Reality}

# ==========================================
# 1. System Optimization (Enable TCP BBR)
# ==========================================
echo "--- Step 1: Enabling TCP BBR Congestion Control ---"
if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo "BBR enabled successfully."
else
    echo "BBR is already enabled."
fi

# ==========================================
# 2. Install Xray Core
# ==========================================
echo "--- Step 2: Installing Xray Core ---"
if ! command -v curl &> /dev/null; then
    apt-get update && apt-get install -y curl
fi

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

XRAY_BIN="/usr/local/bin/xray"
systemctl stop xray

# ==========================================
# 3. Generate Identity & Keys
# ==========================================
echo "--- Step 3: Generating Reality Keys ---"
KEYS=$($XRAY_BIN x25519)

PK=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
PUB=$(echo "$KEYS" | grep "Public" | awk '{print $2}')

if [ -z "$PUB" ]; then
    PUB=$(echo "$KEYS" | grep "Password" | awk '{print $2}')
fi

echo "Private Key: $PK"
echo "Public Key:  $PUB"

if [ -z "$PK" ] || [ -z "$PUB" ]; then
    echo "CRITICAL ERROR: Failed to parse keys. Aborting."
    exit 1
fi

UUID=$($XRAY_BIN uuid)
SID=$(openssl rand -hex 4)

# ==========================================
# 4. Write Configuration (VLESS + Reality)
# ==========================================
echo "--- Step 4: Writing Configuration ---"
mkdir -p /usr/local/etc/xray

cat > /usr/local/etc/xray/config.json <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "flow": "xtls-rprx-vision",
                        "email": "user@vps"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "www.apple.com:443",
                    "xver": 0,
                    "serverNames": [
                        "www.apple.com"
                    ],
                    "privateKey": "$PK",
                    "shortIds": [
                        "$SID"
                    ]
                }
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom"
        }
    ]
}
EOF

# ==========================================
# 5. Service User Hardening
# ==========================================
echo "--- Step 5: Configuring Xray Service User ---"
if ! id -u xray >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin xray
fi

mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
User=xray
Group=xray
EOF

mkdir -p /var/log/xray
chown -R xray:xray /var/log/xray
chmod 644 /usr/local/etc/xray/config.json

systemctl daemon-reload

# ==========================================
# 6. Service & Firewall Management
# ==========================================
echo "--- Step 6: Restarting Service & Firewall ---"
systemctl restart xray
systemctl enable xray

sleep 2

STATUS=$(systemctl is-active xray)
if [ "$STATUS" != "active" ]; then
    echo "Error: Xray failed to start. Check logs with 'journalctl -u xray -n 20'"
    exit 1
fi

if command -v ufw &> /dev/null; then
    ufw allow 443/tcp > /dev/null 2>&1
    ufw allow $SUB_PORT/tcp > /dev/null 2>&1
    echo "Firewall rules added for port 443 and $SUB_PORT."
fi

# ==========================================
# 6.5. Setup Subscription Server (nginx)
# ==========================================
echo "--- Step 6.5: Setting up Subscription Server ---"

if ! command -v nginx &> /dev/null; then
    apt-get update && apt-get install -y nginx
fi

SUB_TOKEN=$(openssl rand -hex 16)
SUB_DIR="/var/www/sub"
mkdir -p "$SUB_DIR"

cat > /etc/nginx/sites-available/clash-sub <<EOF
server {
    listen $SUB_PORT;
    server_name _;

    location /$SUB_TOKEN {
        alias $SUB_DIR/clash.yaml;
        default_type 'text/yaml; charset=utf-8';
        add_header Content-Disposition 'attachment; filename="clash.yaml"';
    }

    location / {
        return 404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/clash-sub /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default 2>/dev/null

nginx -t && systemctl reload nginx
systemctl enable nginx

# ==========================================
# 7. Output Subscription Link + QR + Clash YAML
# ==========================================
IP=$(curl -s ifconfig.me)

# URL encode the node name
NODE_NAME_ENCODED=$(echo -n "$NODE_NAME" | sed 's/ /%20/g')

LINK="vless://$UUID@$IP:443?security=reality&encryption=none&pbk=$PUB&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.apple.com&sid=$SID#$NODE_NAME_ENCODED"

SUB_URL="http://$IP:$SUB_PORT/$SUB_TOKEN"

cat > /root/clash_vless.yaml <<EOF
# Clash Meta (mihomo) Configuration for VLESS + Reality

proxies:
  - name: "$NODE_NAME"
    type: vless
    server: $IP
    port: 443
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.apple.com
    reality-opts:
      public-key: $PUB
      short-id: $SID
    client-fingerprint: chrome

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - $NODE_NAME
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
EOF

cp /root/clash_vless.yaml "$SUB_DIR/clash.yaml"

echo "$LINK" > /root/vless_link.txt
echo "$SUB_URL" > /root/clash_sub_url.txt

echo ""
echo "================================================================"
echo "   VLESS + Reality Deployment Successful!"
echo "================================================================"
echo ""
echo "VLESS Link:"
echo "$LINK"
echo ""
echo "Clash Subscription URL:"
echo "$SUB_URL"
echo ""
echo "================================================================"
echo "Output files:"
echo "  - VLESS Link:      /root/vless_link.txt"
echo "  - Clash YAML:      /root/clash_vless.yaml"
echo "  - Subscription:    /root/clash_sub_url.txt"
echo "  - QR Code:         /root/vless_qr.png"
echo "================================================================"

if ! command -v qrencode &> /dev/null; then
    apt-get update && apt-get install -y qrencode
fi
qrencode -o /root/vless_qr.png "$LINK"
qrencode -t ASCII "$LINK"
