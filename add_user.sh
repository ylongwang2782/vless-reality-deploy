#!/bin/bash

# ==========================================
# VLESS 用户管理脚本
# 用法: ./add_user.sh <用户名> [流量限制GB] [重置日期]
# 示例: ./add_user.sh alice 200 27
# ==========================================

usage() {
    echo "用法: $0 <用户名> [流量限制GB] [重置日期] [--node <node_id>]"
    echo "示例: $0 alice 200 27 --node usa"
}

NODE_ID=""
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--node)
            NODE_ID="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

set -- "${POSITIONAL[@]}"
USERNAME=$1
TRAFFIC_LIMIT_GB=${2:-0}
RESET_DAY=${3:-1}

if [ -z "$USERNAME" ]; then
    usage
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"

source "$SCRIPT_DIR/config.sh"
if ! load_config "$NODE_ID"; then
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no"

echo "[INFO] 添加用户: $USERNAME"
[ "$TRAFFIC_LIMIT_GB" -gt 0 ] && echo "[INFO] 流量限制: ${TRAFFIC_LIMIT_GB}GB/月，每月${RESET_DAY}号重置"
echo "[INFO] VPS: $VPS_IP"
echo "[INFO] SSH Host: $SSH_HOST"

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
IP=$(curl -4 -s ifconfig.me 2>/dev/null || true)
if [ -z "$IP" ]; then
    IP=$(curl -6 -s ifconfig.me 2>/dev/null || true)
fi

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

# 更新订阅服务的路由配置
ROUTES_FILE="$SUB_DIR/routes.json"
python3 << PYROUTES
import json
import os

routes_file = '$ROUTES_FILE'
routes = {}
if os.path.exists(routes_file):
    with open(routes_file, 'r') as f:
        routes = json.load(f)

routes['$SUB_TOKEN'] = {
    'name': '$USERNAME',
    'yaml_path': '$SUB_DIR/${USERNAME}.yaml',
    'config_path': '$TRAFFIC_DIR/${USERNAME}.json'
}

with open(routes_file, 'w') as f:
    json.dump(routes, f, indent=2)
print("[INFO] Routes updated")
PYROUTES

# 如果订阅服务存在则重启
if systemctl is-active sub-server >/dev/null 2>&1; then
    systemctl restart sub-server
    echo "[INFO] Subscription server restarted"
else
    echo "[WARN] Subscription server not running, run sync_users.sh to start it"
fi

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
if ! scp $SSH_OPTS /tmp/add_user_remote.sh "$SSH_HOST:/root/"; then
    echo "[ERROR] 上传脚本失败"
    exit 1
fi

if ! ssh $SSH_OPTS "$SSH_HOST" "chmod +x /root/add_user_remote.sh && /root/add_user_remote.sh $(printf %q "$USERNAME") $(printf %q "$TRAFFIC_LIMIT_GB") $(printf %q "$RESET_DAY") $(printf %q "$SUB_PORT") && rm /root/add_user_remote.sh"; then
    echo "[ERROR] 用户添加失败"
    exit 1
fi

# 下载用户文件
for file in ${USERNAME}_vless_link.txt ${USERNAME}_sub_url.txt; do
    scp $SSH_OPTS "$SSH_HOST:/root/$file" "$SCRIPT_DIR/" || true
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
