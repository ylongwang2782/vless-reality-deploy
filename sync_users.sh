#!/bin/bash

# ==========================================
# 用户同步脚本
# 读取 users.yaml 配置，同步用户到 VPS
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
USERS_FILE="$SCRIPT_DIR/users.yaml"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

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

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "config.yaml 不存在，请先复制 config.yaml.example 并编辑"
    exit 1
fi

if [ ! -f "$USERS_FILE" ]; then
    log_error "users.yaml 不存在，请先复制 users.yaml.example 并编辑"
    exit 1
fi

source "$SCRIPT_DIR/config.sh"
if ! load_config "$NODE_ID"; then
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no"

log_info "=========================================="
log_info "同步用户配置到 VPS"
log_info "=========================================="
log_info "VPS: $VPS_IP"
log_info "SSH Host: $SSH_HOST"

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

# 获取服务器信息（优先 IPv4）
IP=$(curl -4 -s ifconfig.me 2>/dev/null || true)
if [ -z "$IP" ]; then
    IP=$(curl -6 -s ifconfig.me 2>/dev/null || true)
fi

# 从配置获取密钥
KEYS=$(python3 << 'PY'
import json
with open('/usr/local/etc/xray/config.json') as f:
    c = json.load(f)
# 找到 VLESS inbound（带有 streamSettings 的）
for inb in c['inbounds']:
    if 'streamSettings' in inb:
        rs = inb['streamSettings']['realitySettings']
        print(rs['privateKey'])
        print(rs['shortIds'][0])
        break
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

# 确保 stats 配置存在
if 'stats' not in xray_config:
    xray_config['stats'] = {}

if 'api' not in xray_config:
    xray_config['api'] = {
        "tag": "api",
        "services": ["StatsService"]
    }

if 'policy' not in xray_config:
    xray_config['policy'] = {
        "levels": {
            "0": {
                "statsUserUplink": True,
                "statsUserDownlink": True
            }
        },
        "system": {
            "statsInboundUplink": True,
            "statsInboundDownlink": True,
            "statsOutboundUplink": True,
            "statsOutboundDownlink": True
        }
    }

# 确保 API inbound 存在
api_inbound_exists = False
vless_inbound_idx = 0
for i, inb in enumerate(xray_config['inbounds']):
    if inb.get('tag') == 'api':
        api_inbound_exists = True
    if inb.get('protocol') == 'vless':
        vless_inbound_idx = i
        if 'tag' not in inb:
            inb['tag'] = 'vless-in'

if not api_inbound_exists:
    xray_config['inbounds'].insert(0, {
        "tag": "api",
        "port": 10085,
        "listen": "127.0.0.1",
        "protocol": "dokodemo-door",
        "settings": {
            "address": "127.0.0.1"
        }
    })
    vless_inbound_idx += 1

# 确保路由规则存在
if 'routing' not in xray_config:
    xray_config['routing'] = {"rules": []}

api_rule_exists = any(r.get('outboundTag') == 'api' for r in xray_config['routing'].get('rules', []))
if not api_rule_exists:
    xray_config['routing']['rules'].insert(0, {
        "inboundTag": ["api"],
        "outboundTag": "api",
        "type": "field"
    })

# 获取现有用户 (使用正确的 inbound 索引)
existing_emails = {c['email'] for c in xray_config['inbounds'][vless_inbound_idx]['settings']['clients']}

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
        for client in xray_config['inbounds'][vless_inbound_idx]['settings']['clients']:
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

    # 使用用户名作为订阅路径（简洁）
    sub_token = name

    node_name = node_prefix if node_prefix else "Reality"

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

  - name: "Streaming"
    type: select
    proxies:
      - {node_name}
      - Proxy
      - DIRECT

  - name: "AI"
    type: select
    proxies:
      - {node_name}
      - Proxy
      - DIRECT

  - name: "AdBlock"
    type: select
    proxies:
      - REJECT
      - DIRECT

rule-providers:
  reject:
    type: http
    behavior: domain
    url: "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/reject.txt"
    path: ./ruleset/reject.yaml
    interval: 86400

  direct:
    type: http
    behavior: domain
    url: "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/direct.txt"
    path: ./ruleset/direct.yaml
    interval: 86400

  proxy:
    type: http
    behavior: domain
    url: "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/proxy.txt"
    path: ./ruleset/proxy.yaml
    interval: 86400

  private:
    type: http
    behavior: domain
    url: "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/private.txt"
    path: ./ruleset/private.yaml
    interval: 86400

  gfw:
    type: http
    behavior: domain
    url: "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/gfw.txt"
    path: ./ruleset/gfw.yaml
    interval: 86400

  tld-not-cn:
    type: http
    behavior: domain
    url: "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/tld-not-cn.txt"
    path: ./ruleset/tld-not-cn.yaml
    interval: 86400

  telegramcidr:
    type: http
    behavior: ipcidr
    url: "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/telegramcidr.txt"
    path: ./ruleset/telegramcidr.yaml
    interval: 86400

  cncidr:
    type: http
    behavior: ipcidr
    url: "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/cncidr.txt"
    path: ./ruleset/cncidr.yaml
    interval: 86400

  lancidr:
    type: http
    behavior: ipcidr
    url: "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/lancidr.txt"
    path: ./ruleset/lancidr.yaml
    interval: 86400

rules:
  # Ad blocking
  - RULE-SET,reject,AdBlock

  # Private network
  - RULE-SET,private,DIRECT
  - RULE-SET,lancidr,DIRECT,no-resolve

  # AI services (OpenAI, Claude, etc.)
  - DOMAIN-SUFFIX,openai.com,AI
  - DOMAIN-SUFFIX,ai.com,AI
  - DOMAIN-SUFFIX,anthropic.com,AI
  - DOMAIN-SUFFIX,claude.ai,AI
  - DOMAIN-SUFFIX,gemini.google.com,AI
  - DOMAIN-SUFFIX,bard.google.com,AI
  - DOMAIN-SUFFIX,perplexity.ai,AI

  # Streaming services
  - DOMAIN-SUFFIX,netflix.com,Streaming
  - DOMAIN-SUFFIX,nflxvideo.net,Streaming
  - DOMAIN-SUFFIX,youtube.com,Streaming
  - DOMAIN-SUFFIX,googlevideo.com,Streaming
  - DOMAIN-SUFFIX,ytimg.com,Streaming
  - DOMAIN-SUFFIX,disneyplus.com,Streaming
  - DOMAIN-SUFFIX,hulu.com,Streaming
  - DOMAIN-SUFFIX,hbo.com,Streaming
  - DOMAIN-SUFFIX,hbomax.com,Streaming
  - DOMAIN-SUFFIX,spotify.com,Streaming
  - DOMAIN-SUFFIX,twitch.tv,Streaming

  # Telegram
  - RULE-SET,telegramcidr,Proxy,no-resolve

  # GFW blocked sites
  - RULE-SET,gfw,Proxy
  - RULE-SET,tld-not-cn,Proxy

  # Proxy domains
  - RULE-SET,proxy,Proxy

  # Direct domains (China)
  - RULE-SET,direct,DIRECT

  # China IP
  - RULE-SET,cncidr,DIRECT,no-resolve
  - GEOIP,CN,DIRECT,no-resolve

  # Final rule
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

    results.append({
        "name": name,
        "sub_url": f"http://{ip}:{sub_port}/{sub_token}",
        "sub_token": sub_token
    })

if new_clients:
    xray_config['inbounds'][vless_inbound_idx]['settings']['clients'].extend(new_clients)
    with open('/usr/local/etc/xray/config.json', 'w') as f:
        json.dump(xray_config, f, indent=4)
    print(f"[INFO] Added {len(new_clients)} new user(s)")

# 生成订阅服务的路由配置
sub_routes = {}
for r in results:
    user_config_path = f"/var/lib/xray/traffic/{r['name']}.json"
    sub_routes[r['sub_token']] = {
        'name': r['name'],
        'yaml_path': f"/var/www/sub/{r['name']}.yaml",
        'config_path': user_config_path
    }

with open('/var/www/sub/routes.json', 'w') as f:
    json.dump(sub_routes, f, indent=2)

# 创建 Python 订阅服务
sub_service = '''#!/usr/bin/env python3
import http.server
import ssl
import json
import os
import mimetypes
from datetime import datetime
from urllib.parse import urlparse, unquote

SUB_DIR = "/var/www/sub"
DOWNLOAD_DIR = "/var/www/downloads"
ROUTES_FILE = os.path.join(SUB_DIR, "routes.json")
USE_SSL = False

class SubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # 静默日志

    def do_HEAD(self):
        self._handle_request(head_only=True)

    def do_GET(self):
        self._handle_request(head_only=False)

    def _handle_request(self, head_only=False):
        path = unquote(urlparse(self.path).path).strip('/')

        if path.startswith('download'):
            self._handle_download(path, head_only)
            return

        # 加载路由配置
        try:
            with open(ROUTES_FILE, 'r') as f:
                routes = json.load(f)
        except:
            self.send_error(500, "Internal Server Error")
            return

        if path not in routes:
            self.send_error(404, "Not Found")
            return

        route = routes[path]

        if isinstance(route, dict) and route.get('type') == 'downloads':
            self.send_error(404, "Not Found")
            return
        yaml_path = route['yaml_path']
        config_path = route['config_path']

        # 读取 YAML 文件
        try:
            with open(yaml_path, 'r') as f:
                yaml_content = f.read()
        except:
            self.send_error(404, "Not Found")
            return

        # 读取用户配置获取流量限制
        upload = 0
        download = 0
        total = 0
        expire = 0

        try:
            with open(config_path, 'r') as f:
                user_config = json.load(f)

            traffic_limit_gb = user_config.get('traffic_limit_gb', 0)
            if traffic_limit_gb > 0:
                total = traffic_limit_gb * 1024 * 1024 * 1024  # 转换为字节

            # 读取已使用流量（如果存在）
            upload = user_config.get('upload_bytes', 0)
            download = user_config.get('download_bytes', 0)

            # 计算过期时间（下个重置日）
            reset_day = user_config.get('reset_day', 1)
            now = datetime.now()
            year = now.year
            month = now.month
            if now.day >= reset_day:
                month += 1
                if month > 12:
                    month = 1
                    year += 1
            try:
                expire_date = datetime(year, month, reset_day)
                expire = int(expire_date.timestamp())
            except:
                pass
        except:
            pass

        # 发送响应
        self.send_response(200)
        self.send_header('Content-Type', 'text/yaml; charset=utf-8')

        # 添加 subscription-userinfo 响应头（Shadowrocket 用这个显示流量信息）
        if total > 0:
            userinfo = f"upload={upload}; download={download}; total={total}"
            if expire > 0:
                userinfo += f"; expire={expire}"
            self.send_header('subscription-userinfo', userinfo)

        self.end_headers()
        if not head_only:
            self.wfile.write(yaml_content.encode('utf-8'))

    def _handle_download(self, path, head_only):
        if path == 'download/links' or path == 'download/links.json':
            links = []
            try:
                with open(ROUTES_FILE, 'r') as f:
                    routes = json.load(f)
                for token, route in routes.items():
                    if isinstance(route, dict) and route.get('type') == 'downloads':
                        continue
                    name = route.get('name') if isinstance(route, dict) else token
                    host = self.headers.get('Host', '')
                    scheme = 'https' if USE_SSL else 'http'
                    base = f"{scheme}://{host}" if host else ''
                    url = f"{base}/{token}" if base else f"/{token}"
                    links.append({
                        "name": name or token,
                        "token": token,
                        "url": url
                    })
                links.sort(key=lambda x: x.get("name", ""))
            except:
                pass

            body = json.dumps({
                "count": len(links),
                "links": links,
                "updated_at": datetime.utcnow().isoformat() + "Z"
            }, ensure_ascii=False)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            if not head_only:
                self.wfile.write(body.encode('utf-8'))
            return

        if path == 'download' or path == 'download/':
            index_path = os.path.join(DOWNLOAD_DIR, 'index.html')
            if os.path.exists(index_path):
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.end_headers()
                if not head_only:
                    with open(index_path, 'rb') as f:
                        self.wfile.write(f.read())
            else:
                self.send_error(404, "Not Found")
            return

        filename = path[len('download/'):]
        filepath = os.path.join(DOWNLOAD_DIR, filename)

        if '..' in filename or not os.path.abspath(filepath).startswith(DOWNLOAD_DIR):
            self.send_error(403, "Forbidden")
            return

        if not os.path.isfile(filepath):
            self.send_error(404, "Not Found")
            return

        file_size = os.path.getsize(filepath)
        content_type, _ = mimetypes.guess_type(filepath)
        if content_type is None:
            content_type = 'application/octet-stream'

        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(file_size))
        self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
        self.end_headers()

        if not head_only:
            with open(filepath, 'rb') as f:
                while True:
                    chunk = f.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)

def run_server(port, use_ssl=False):
    global USE_SSL
    USE_SSL = use_ssl
    server = http.server.HTTPServer(('0.0.0.0', port), SubHandler)
    if use_ssl and os.path.exists('/etc/nginx/ssl/origin.crt'):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain('/etc/nginx/ssl/origin.crt', '/etc/nginx/ssl/origin.key')
        server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"Subscription server running on port {port} (SSL: {use_ssl})")
    server.serve_forever()

if __name__ == '__main__':
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8443
    use_ssl = os.path.exists('/etc/nginx/ssl/origin.crt')
    run_server(port, use_ssl)
'''

with open('/var/www/sub/sub_server.py', 'w') as f:
    f.write(sub_service)
os.chmod('/var/www/sub/sub_server.py', 0o755)

# 创建 systemd 服务
systemd_service = f'''[Unit]
Description=Subscription Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /var/www/sub/sub_server.py {sub_port}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
'''

with open('/etc/systemd/system/sub-server.service', 'w') as f:
    f.write(systemd_service)

# 创建流量采集脚本
traffic_collector = '''#!/usr/bin/env python3
"""
流量采集脚本 - 从 Xray API 获取用户流量并更新配置文件
"""
import json
import socket
import os
from datetime import datetime

XRAY_API_HOST = "127.0.0.1"
XRAY_API_PORT = 10085
TRAFFIC_DIR = "/var/lib/xray/traffic"

def query_stats(reset=False):
    """通过 Xray API statsquery 查询流量统计"""
    try:
        import subprocess
        cmd = ["/usr/local/bin/xray", "api", "statsquery", "-s", f"{XRAY_API_HOST}:{XRAY_API_PORT}"]
        if reset:
            cmd.append("-reset")

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            print(f"[ERROR] statsquery failed: {result.stderr.strip()}")
            return {}

        data = json.loads(result.stdout)
        stats = {}
        for item in data.get("stat", []):
            name = item.get("name", "")
            value = item.get("value", 0)
            if name:
                stats[name] = value
        return stats
    except Exception as e:
        print(f"[ERROR] Query stats failed: {e}")
        return {}

def update_user_traffic():
    """更新用户流量数据"""
    if not os.path.exists(TRAFFIC_DIR):
        return

    # 获取所有用户流量统计
    stats = query_stats()

    for filename in os.listdir(TRAFFIC_DIR):
        if not filename.endswith('.json'):
            continue

        filepath = os.path.join(TRAFFIC_DIR, filename)
        try:
            with open(filepath, 'r') as f:
                user_config = json.load(f)

            email = user_config.get('email', '')
            if not email:
                continue

            # 查找对应的流量数据
            uplink_key = f"user>>>{email}>>>traffic>>>uplink"
            downlink_key = f"user>>>{email}>>>traffic>>>downlink"

            upload = stats.get(uplink_key, 0)
            download = stats.get(downlink_key, 0)

            # 累加流量（Xray stats 是累计值）
            # 检查是否需要重置（每月重置日）
            reset_day = user_config.get('reset_day', 1)
            last_reset = user_config.get('last_reset_date', '')
            today = datetime.now().strftime('%Y-%m-%d')
            current_day = datetime.now().day
            current_month = datetime.now().strftime('%Y-%m')
            last_reset_month = last_reset[:7] if last_reset else ''

            # 如果是新的月份且已过重置日，重置流量
            if current_month != last_reset_month and current_day >= reset_day:
                user_config['upload_bytes'] = upload
                user_config['download_bytes'] = download
                user_config['last_reset_date'] = today
                print(f"[INFO] Reset traffic for {email}")
            else:
                # 更新流量数据
                user_config['upload_bytes'] = upload
                user_config['download_bytes'] = download

            user_config['last_update'] = datetime.now().isoformat()

            with open(filepath, 'w') as f:
                json.dump(user_config, f, indent=2)

            total_gb = (upload + download) / (1024**3)
            print(f"[INFO] {email}: upload={upload}, download={download}, total={total_gb:.2f}GB")

        except Exception as e:
            print(f"[ERROR] Failed to update {filename}: {e}")

if __name__ == '__main__':
    print(f"[INFO] Traffic collector started at {datetime.now()}")
    update_user_traffic()
    print("[INFO] Done")
'''

with open('/var/lib/xray/traffic_collector.py', 'w') as f:
    f.write(traffic_collector)
os.chmod('/var/lib/xray/traffic_collector.py', 0o755)

# 添加 cron 任务（每5分钟执行一次）
import subprocess
cron_job = "*/5 * * * * /usr/bin/python3 /var/lib/xray/traffic_collector.py >> /var/log/xray/traffic.log 2>&1"
# 检查是否已存在
result = subprocess.run(['crontab', '-l'], capture_output=True, text=True)
existing_cron = result.stdout if result.returncode == 0 else ''
if 'traffic_collector.py' not in existing_cron:
    new_cron = existing_cron.rstrip() + chr(10) + cron_job + chr(10)
    subprocess.run(['crontab', '-'], input=new_cron, text=True)
    print("[INFO] Cron job added for traffic collection")

# 生成合并的订阅链接文件
with open('/root/subscriptions.txt', 'w') as f:
    for r in results:
        f.write(f"{r['name']}: {r['sub_url']}" + chr(10))

print("")
print("=" * 60)
print("USER_LINKS_START")
for r in results:
    print(f"USER:{r['name']}")
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

# 停止旧的 nginx 订阅配置（如果存在）
rm -f /etc/nginx/sites-enabled/clash-sub /etc/nginx/sites-enabled/sub-proxy 2>/dev/null
nginx -t && systemctl reload nginx 2>/dev/null || true

# 启动 Python 订阅服务（监听 8443，带 SSL）
echo "[INFO] Starting subscription server..."
systemctl daemon-reload
systemctl enable sub-server
systemctl restart sub-server
sleep 2

if [ "$(systemctl is-active sub-server)" = "active" ]; then
    echo "[INFO] Subscription server OK"
else
    echo "[ERROR] Subscription server failed"
    systemctl status sub-server
    exit 1
fi

echo "[INFO] Sync completed"
REMOTE_SCRIPT

log_info "上传配置到 VPS..."

scp $SSH_OPTS /tmp/sync_users_remote.sh "$USERS_FILE" "$SSH_HOST:/tmp/"
ssh $SSH_OPTS "$SSH_HOST" "chmod +x /tmp/sync_users_remote.sh && /tmp/sync_users_remote.sh /tmp/users.yaml $(printf %q "$SUB_PORT") $(printf %q "$NODE_NAME")"
ssh $SSH_OPTS "$SSH_HOST" "rm -f /tmp/sync_users_remote.sh /tmp/users.yaml"

log_info "下载订阅链接..."

# 下载合并的订阅链接文件
scp $SSH_OPTS "$SSH_HOST:/root/subscriptions.txt" "$SCRIPT_DIR/"

# 如果配置了 Cloudflare，更新订阅链接为 HTTPS
if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_DOMAIN" ] && [ -n "$CF_SUBDOMAIN" ]; then
    log_info "更新订阅链接为 HTTPS..."

    # 尝试配置 Origin Rules（可选，需要额外权限）
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" 2>/dev/null | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    ORIGIN_RULES_OK=false
    if [ -n "$ZONE_ID" ]; then
        # 尝试配置 Origin Rules
        RESULT=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/phases/http_request_origin/entrypoint" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{
                \"rules\": [{
                    \"expression\": \"(http.host eq \\\"$CF_SUBDOMAIN.$CF_DOMAIN\\\")\",
                    \"description\": \"sub-port-rule\",
                    \"action\": \"route\",
                    \"action_parameters\": {
                        \"origin\": {
                            \"port\": $SUB_PORT
                        }
                    }
                }]
            }" 2>/dev/null)

        if echo "$RESULT" | grep -q '"success":true'; then
            log_info "Origin Rules 配置成功（443 -> $SUB_PORT）"
            ORIGIN_RULES_OK=true
        fi
    fi

    # 更新订阅链接文件
    if [ -f "$SCRIPT_DIR/subscriptions.txt" ]; then
        > "$SCRIPT_DIR/subscriptions.txt.tmp"
        while IFS=': ' read -r username url; do
            if [ "$ORIGIN_RULES_OK" = true ]; then
                echo "$username: https://$CF_SUBDOMAIN.$CF_DOMAIN/$username" >> "$SCRIPT_DIR/subscriptions.txt.tmp"
            else
                echo "$username: https://$CF_SUBDOMAIN.$CF_DOMAIN:$SUB_PORT/$username" >> "$SCRIPT_DIR/subscriptions.txt.tmp"
            fi
        done < "$SCRIPT_DIR/subscriptions.txt"
        mv "$SCRIPT_DIR/subscriptions.txt.tmp" "$SCRIPT_DIR/subscriptions.txt"
    fi

    if [ "$ORIGIN_RULES_OK" = false ]; then
        log_warn "Origin Rules 配置失败（需要额外 API 权限），使用带端口的链接"
    fi
fi

# 输出结果
echo ""
log_info "=========================================="
log_info "用户同步完成！"
log_info "=========================================="
echo ""

if [ -f "$SCRIPT_DIR/subscriptions.txt" ]; then
    cat "$SCRIPT_DIR/subscriptions.txt"
    echo ""
fi

log_info "订阅链接保存在: $SCRIPT_DIR/subscriptions.txt"
log_info "=========================================="
