#!/bin/bash

# ==========================================
# 用户同步脚本
# 读取 users.yaml 配置，同步用户到 VPS
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
USERS_FILE="$SCRIPT_DIR/users.yaml"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "config.env 不存在，请先复制 config.env.example 并编辑"
    exit 1
fi

if [ ! -f "$USERS_FILE" ]; then
    log_error "users.yaml 不存在，请先复制 users.yaml.example 并编辑"
    exit 1
fi

source "$CONFIG_FILE"

# 验证必要配置
if [ -z "$VPS_IP" ] || [ -z "$VPS_PASSWORD" ]; then
    log_error "VPS_IP 和 VPS_PASSWORD 必须在 config.env 中配置"
    exit 1
fi

log_info "=========================================="
log_info "同步用户配置到 VPS"
log_info "=========================================="

# 生成远程执行脚本（从文件读取 YAML）
cat > /tmp/sync_users_remote.sh << 'REMOTE_SCRIPT'
#!/bin/bash

USERS_YAML_FILE="$1"
SUB_PORT="$2"
NODE_PREFIX="$3"

XRAY_BIN="/usr/local/bin/xray"
CONFIG_FILE="/usr/local/etc/xray/config.json"
TRAFFIC_DIR="/var/lib/xray/traffic"
SUB_DIR="/var/www/sub"
OUTPUT_DIR="/root/user_links"

mkdir -p "$TRAFFIC_DIR" "$SUB_DIR" "$OUTPUT_DIR"

# 检查 Python3 和 PyYAML
if ! command -v python3 &> /dev/null; then
    echo "[ERROR] Python3 not found"
    exit 1
fi

# 安装 PyYAML 如果不存在
python3 -c "import yaml" 2>/dev/null || pip3 install pyyaml -q

# 获取服务器信息
IP=$(curl -s ifconfig.me)

# 从配置获取密钥
KEYS=$(python3 << 'PY'
import json
with open('/usr/local/etc/xray/config.json') as f:
    c = json.load(f)
rs = c['inbounds'][0]['streamSettings']['realitySettings']
print(rs['privateKey'])
print(rs['shortIds'][0])
PY
)

PK=$(echo "$KEYS" | head -1)
SID=$(echo "$KEYS" | tail -1)
PUB=$($XRAY_BIN x25519 -i "$PK" 2>&1 | grep "Password" | awk '{print $2}')

echo "[INFO] Server IP: $IP"
echo "[INFO] Public Key: $PUB"
echo "[INFO] Short ID: $SID"

# 解析 YAML 并处理用户
python3 << PYTHON_SCRIPT
import yaml
import json
import subprocess
import os

# 从文件读取 YAML
with open('$USERS_YAML_FILE', 'r') as f:
    users_config = yaml.safe_load(f)

sub_port = "$SUB_PORT"
node_prefix = "$NODE_PREFIX"
ip = "$IP"
pub = "$PUB"
sid = "$SID"

users = users_config.get('users', [])

if not users:
    print("[WARN] No users defined in users.yaml")
    exit(0)

# 读取现有 Xray 配置
with open('/usr/local/etc/xray/config.json', 'r') as f:
    xray_config = json.load(f)

# 获取现有用户
existing_emails = {c['email'] for c in xray_config['inbounds'][0]['settings']['clients']}

# 处理每个用户
results = []
new_clients = []

for user in users:
    name = user['name']
    traffic_limit = user.get('traffic_limit_gb', 0)
    reset_day = user.get('reset_day', 1)
    email = f"{name}@vps"

    # 检查用户是否已存在
    if email in existing_emails:
        for client in xray_config['inbounds'][0]['settings']['clients']:
            if client['email'] == email:
                uuid = client['id']
                break
        print(f"[INFO] User {name} already exists, UUID: {uuid}")
    else:
        result = subprocess.run(['/usr/local/bin/xray', 'uuid'], capture_output=True, text=True)
        uuid = result.stdout.strip()
        print(f"[INFO] Creating user {name}, UUID: {uuid}")
        new_clients.append({
            "id": uuid,
            "flow": "xtls-rprx-vision",
            "email": email
        })

    # 生成订阅 token
    import hashlib
    sub_token = f"{name}_{hashlib.md5(uuid.encode()).hexdigest()[:16]}"

    node_name = f"{node_prefix}_{name}" if node_prefix else f"Reality_{name}"

    vless_link = f"vless://{uuid}@{ip}:443?security=reality&encryption=none&pbk={pub}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.apple.com&sid={sid}#{node_name}"

    clash_yaml = f'''# Clash Meta Configuration for {name}

proxies:
  - name: "{node_name}"
    type: vless
    server: {ip}
    port: 443
    uuid: {uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.apple.com
    reality-opts:
      public-key: {pub}
      short-id: {sid}
    client-fingerprint: chrome

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - {node_name}
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
'''

    with open(f'/var/www/sub/{name}.yaml', 'w') as f:
        f.write(clash_yaml)

    user_info = {
        "username": name,
        "uuid": uuid,
        "email": email,
        "sub_token": sub_token,
        "traffic_limit_gb": traffic_limit,
        "reset_day": reset_day
    }
    with open(f'/var/lib/xray/traffic/{name}.json', 'w') as f:
        json.dump(user_info, f, indent=2)

    with open(f'/root/user_links/{name}_vless.txt', 'w') as f:
        f.write(vless_link)
    with open(f'/root/user_links/{name}_sub.txt', 'w') as f:
        f.write(f"http://{ip}:{sub_port}/{sub_token}")

    results.append({
        "name": name,
        "vless": vless_link,
        "sub_url": f"http://{ip}:{sub_port}/{sub_token}",
        "sub_token": sub_token
    })

if new_clients:
    xray_config['inbounds'][0]['settings']['clients'].extend(new_clients)
    with open('/usr/local/etc/xray/config.json', 'w') as f:
        json.dump(xray_config, f, indent=4)
    print(f"[INFO] Added {len(new_clients)} new user(s)")

# 更新 nginx 配置
nginx_locations = ""
for r in results:
    nginx_locations += f'''
    location /{r['sub_token']} {{
        alias /var/www/sub/{r['name']}.yaml;
        default_type 'text/yaml; charset=utf-8';
    }}
'''

if os.path.exists('/etc/nginx/ssl/origin.crt'):
    nginx_conf = f'''server {{
    listen {sub_port} ssl;
    server_name _;
    ssl_certificate /etc/nginx/ssl/origin.crt;
    ssl_certificate_key /etc/nginx/ssl/origin.key;
    ssl_protocols TLSv1.2 TLSv1.3;
{nginx_locations}
    location / {{ return 404; }}
}}
'''
else:
    nginx_conf = f'''server {{
    listen {sub_port};
    server_name _;
{nginx_locations}
    location / {{ return 404; }}
}}
'''

with open('/etc/nginx/sites-available/clash-sub', 'w') as f:
    f.write(nginx_conf)

print("")
print("=" * 60)
print("USER_LINKS_START")
for r in results:
    print(f"USER:{r['name']}")
    print(f"VLESS:{r['vless']}")
    print(f"SUB:{r['sub_url']}")
    print("---")
print("USER_LINKS_END")
print("=" * 60)
PYTHON_SCRIPT

# 验证并重启服务
echo "[INFO] Validating Xray config..."
if $XRAY_BIN run -test -config $CONFIG_FILE > /dev/null 2>&1; then
    echo "[INFO] Restarting Xray..."
    systemctl restart xray
    sleep 2
    if [ "$(systemctl is-active xray)" = "active" ]; then
        echo "[INFO] Xray OK"
    else
        echo "[ERROR] Xray failed"
        exit 1
    fi
else
    echo "[ERROR] Invalid config"
    exit 1
fi

nginx -t && systemctl reload nginx
echo "[INFO] Sync completed"
REMOTE_SCRIPT

log_info "上传配置到 VPS..."

# 创建 expect 脚本
cat > /tmp/sync_expect.exp << EXPEOF
#!/usr/bin/expect
set timeout 300

# 上传脚本和配置
spawn scp -o StrictHostKeyChecking=no /tmp/sync_users_remote.sh $USERS_FILE $VPS_USER@$VPS_IP:/tmp/
expect {
    "password:" { send "$VPS_PASSWORD\r" }
    timeout { puts "SCP timed out"; exit 1 }
}
expect eof

# 执行脚本
spawn ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP
expect {
    "password:" { send "$VPS_PASSWORD\r" }
    timeout { puts "SSH timed out"; exit 1 }
}
expect "#"
send "chmod +x /tmp/sync_users_remote.sh && /tmp/sync_users_remote.sh /tmp/users.yaml '$SUB_PORT' '$NODE_NAME'\r"
expect {
    "USER_LINKS_END" { }
    "ERROR" { puts "Sync failed"; exit 1 }
    timeout { puts "Timeout"; exit 1 }
}
expect "#"
send "rm -f /tmp/sync_users_remote.sh /tmp/users.yaml\r"
expect "#"
send "exit\r"
expect eof
EXPEOF

expect /tmp/sync_expect.exp

log_info "下载用户链接..."

# 创建本地输出目录
mkdir -p "$SCRIPT_DIR/user_links"

# 下载所有用户链接
expect << EOF
set timeout 60
spawn scp -o StrictHostKeyChecking=no -r $VPS_USER@$VPS_IP:/root/user_links/* $SCRIPT_DIR/user_links/
expect {
    "password:" { send "$VPS_PASSWORD\r" }
    timeout { puts "Download timed out"; exit 1 }
}
expect eof
EOF

# 如果配置了 Cloudflare，更新订阅链接为 HTTPS
if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_DOMAIN" ] && [ -n "$CF_SUBDOMAIN" ]; then
    log_info "更新订阅链接为 HTTPS..."
    for sub_file in "$SCRIPT_DIR/user_links/"*_sub.txt; do
        if [ -f "$sub_file" ]; then
            SUB_TOKEN=$(cat "$sub_file" | grep -oE '[a-z]+_[a-f0-9]+')
            echo "https://$CF_SUBDOMAIN.$CF_DOMAIN:$SUB_PORT/$SUB_TOKEN" > "$sub_file"
        fi
    done
fi

# 输出结果
echo ""
log_info "=========================================="
log_info "用户同步完成！"
log_info "=========================================="
echo ""

for vless_file in "$SCRIPT_DIR/user_links/"*_vless.txt; do
    if [ -f "$vless_file" ]; then
        username=$(basename "$vless_file" _vless.txt)
        sub_file="$SCRIPT_DIR/user_links/${username}_sub.txt"

        echo "用户: $username"
        echo "VLESS: $(cat "$vless_file")"
        if [ -f "$sub_file" ]; then
            echo "订阅:  $(cat "$sub_file")"
        fi
        echo ""
    fi
done

log_info "链接文件保存在: $SCRIPT_DIR/user_links/"
log_info "=========================================="
