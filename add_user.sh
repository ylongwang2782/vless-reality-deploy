#!/bin/bash

# ==========================================
# VLESS 用户管理脚本
# 用法: ./add_user.sh <用户名> [流量限制GB] [重置日期]
# 示例: ./add_user.sh wyl 200 27
# ==========================================

USERNAME=$1
TRAFFIC_LIMIT_GB=${2:-0}
RESET_DAY=${3:-1}

if [ -z "$USERNAME" ]; then
    echo "用法: $0 <用户名> [流量限制GB] [重置日期]"
    echo "示例: $0 wyl 200 27"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

source "$CONFIG_FILE"

echo "[INFO] 添加用户: $USERNAME"
[ "$TRAFFIC_LIMIT_GB" -gt 0 ] && echo "[INFO] 流量限制: ${TRAFFIC_LIMIT_GB}GB/月，每月${RESET_DAY}号重置"

# 生成远程执行脚本
cat > /tmp/add_user_remote.sh << 'REMOTE_SCRIPT'
#!/bin/bash

USERNAME=$1
TRAFFIC_LIMIT_GB=$2
RESET_DAY=$3
SUB_PORT=$4

XRAY_BIN="/usr/local/bin/xray"
CONFIG_FILE="/usr/local/etc/xray/config.json"
TRAFFIC_DIR="/var/lib/xray/traffic"
SUB_DIR="/var/www/sub"

# 生成新用户 UUID
NEW_UUID=$($XRAY_BIN uuid)
echo "[INFO] 生成 UUID: $NEW_UUID"

# 获取配置信息（使用 python 更可靠）
eval $(python3 << 'PY'
import json
with open('/usr/local/etc/xray/config.json') as f:
    c = json.load(f)
rs = c['inbounds'][0]['streamSettings']['realitySettings']
print(f"PK={rs['privateKey']}")
print(f"SID={rs['shortIds'][0]}")
PY
)
# Xray 把公钥叫做 "Password"
PUB=$($XRAY_BIN x25519 -i "$PK" 2>&1 | grep "Password" | awk '{print $2}')
IP=$(curl -s ifconfig.me)

echo "[INFO] Public Key: $PUB"

# 备份配置
cp $CONFIG_FILE ${CONFIG_FILE}.bak

# 添加新用户到配置
python3 << PYTHON_SCRIPT
import json

with open('$CONFIG_FILE', 'r') as f:
    config = json.load(f)

# 添加新用户
new_user = {
    "id": "$NEW_UUID",
    "flow": "xtls-rprx-vision",
    "email": "${USERNAME}@vps"
}

config['inbounds'][0]['settings']['clients'].append(new_user)

with open('$CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=4)

print("[INFO] 用户已添加到配置")
PYTHON_SCRIPT

# 验证配置
if ! $XRAY_BIN run -test -config $CONFIG_FILE > /dev/null 2>&1; then
    echo "[ERROR] 配置验证失败，恢复备份"
    cp ${CONFIG_FILE}.bak $CONFIG_FILE
    exit 1
fi

# 重启 Xray
systemctl restart xray
sleep 2

if [ "$(systemctl is-active xray)" != "active" ]; then
    echo "[ERROR] Xray 重启失败，恢复备份"
    cp ${CONFIG_FILE}.bak $CONFIG_FILE
    systemctl restart xray
    exit 1
fi

echo "[INFO] Xray 重启成功"

# 创建目录
mkdir -p "$TRAFFIC_DIR" "$SUB_DIR"

# 生成用户专属订阅文件
cat > "$SUB_DIR/${USERNAME}.yaml" << EOF
# Clash Meta Configuration for $USERNAME

proxies:
  - name: "Reality_${USERNAME}"
    type: vless
    server: $IP
    port: 443
    uuid: $NEW_UUID
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
      - Reality_${USERNAME}
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
EOF

# 生成订阅 token
SUB_TOKEN="${USERNAME}_$(openssl rand -hex 8)"

# 读取现有 nginx 配置并添加新路径
NGINX_CONF="/etc/nginx/sites-available/clash-sub"

# 检查是否已存在该用户的配置
if ! grep -q "/${USERNAME}_" "$NGINX_CONF" 2>/dev/null; then
    # 在最后一个 location 块之后、server 块结束之前添加
    sed -i "/location \/ {/i\\
    location /${SUB_TOKEN} {\\
        alias ${SUB_DIR}/${USERNAME}.yaml;\\
        default_type 'text/yaml; charset=utf-8';\\
        add_header Content-Disposition 'attachment; filename=\"${USERNAME}.yaml\"';\\
    }\\
" "$NGINX_CONF"
fi

nginx -t && systemctl reload nginx

# 生成 VLESS 链接
VLESS_LINK="vless://${NEW_UUID}@${IP}:443?security=reality&encryption=none&pbk=${PUB}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.apple.com&sid=${SID}#Reality_${USERNAME}"

# 保存用户信息
echo "$VLESS_LINK" > /root/${USERNAME}_vless_link.txt
echo "http://${IP}:${SUB_PORT}/${SUB_TOKEN}" > /root/${USERNAME}_sub_url.txt

# 保存用户配置（用于流量管理）
cat > "$TRAFFIC_DIR/${USERNAME}.json" << EOF
{
    "username": "$USERNAME",
    "uuid": "$NEW_UUID",
    "email": "${USERNAME}@vps",
    "sub_token": "$SUB_TOKEN",
    "traffic_limit_gb": $TRAFFIC_LIMIT_GB,
    "reset_day": $RESET_DAY,
    "created_at": "$(date -Iseconds)"
}
EOF

echo ""
echo "================================================================"
echo "   用户添加成功: $USERNAME"
echo "================================================================"
echo ""
echo "VLESS 链接:"
echo "$VLESS_LINK"
echo ""
echo "订阅链接:"
echo "http://${IP}:${SUB_PORT}/${SUB_TOKEN}"
echo ""
echo "================================================================"
REMOTE_SCRIPT

# 上传并执行远程脚本
expect << EOF
set timeout 120
spawn scp -o StrictHostKeyChecking=no /tmp/add_user_remote.sh $VPS_USER@$VPS_IP:/root/
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
send "chmod +x /root/add_user_remote.sh && /root/add_user_remote.sh '$USERNAME' '$TRAFFIC_LIMIT_GB' '$RESET_DAY' '$SUB_PORT'\r"
expect {
    "用户添加成功" { }
    "ERROR" { exit 1 }
    timeout { exit 1 }
}
expect "#"
send "rm /root/add_user_remote.sh\r"
expect "#"
send "exit\r"
expect eof
EOF

if [ $? -ne 0 ]; then
    echo "[ERROR] 用户添加失败"
    exit 1
fi

# 下载用户文件
for file in ${USERNAME}_vless_link.txt ${USERNAME}_sub_url.txt; do
    expect << EOF
set timeout 30
spawn scp -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP:/root/$file $SCRIPT_DIR/
expect {
    "password:" { send "$VPS_PASSWORD\r" }
    timeout { continue }
}
expect eof
EOF
done

# 如果配置了 Cloudflare，更新订阅链接为 HTTPS
if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_DOMAIN" ] && [ -n "$CF_SUBDOMAIN" ]; then
    if [ -f "$SCRIPT_DIR/${USERNAME}_sub_url.txt" ]; then
        SUB_TOKEN=$(cat "$SCRIPT_DIR/${USERNAME}_sub_url.txt" | grep -oE '[a-z]+_[a-f0-9]+')
        echo "https://$CF_SUBDOMAIN.$CF_DOMAIN:$SUB_PORT/$SUB_TOKEN" > "$SCRIPT_DIR/${USERNAME}_sub_url.txt"
    fi
fi

echo ""
echo "[INFO] =========================================="
echo "[INFO] 用户 $USERNAME 添加完成!"
echo "[INFO] =========================================="
echo ""
if [ -f "$SCRIPT_DIR/${USERNAME}_vless_link.txt" ]; then
    echo "VLESS 链接:"
    cat "$SCRIPT_DIR/${USERNAME}_vless_link.txt"
    echo ""
fi
if [ -f "$SCRIPT_DIR/${USERNAME}_sub_url.txt" ]; then
    echo "订阅链接:"
    cat "$SCRIPT_DIR/${USERNAME}_sub_url.txt"
    echo ""
fi
if [ "$TRAFFIC_LIMIT_GB" -gt 0 ]; then
    echo "[INFO] 流量限制: ${TRAFFIC_LIMIT_GB}GB/月"
    echo "[INFO] 重置日期: 每月${RESET_DAY}号"
fi
echo "[INFO] =========================================="
