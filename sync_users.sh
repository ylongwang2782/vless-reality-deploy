#!/bin/bash

# ==========================================
# 用户同步脚本 (多节点版本)
# 读取 config.yaml 和 users.yaml，同步用户到所有 VPS
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

# 检查依赖
check_dependencies() {
    if ! command -v python3 &> /dev/null; then
        log_error "需要安装 python3"
        exit 1
    fi

    python3 -c "import yaml" 2>/dev/null || {
        log_info "安装 PyYAML..."
        pip3 install pyyaml -q
    }
}

# 检查配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    # 兼容旧版 config.env
    if [ -f "$SCRIPT_DIR/config.env" ]; then
        log_warn "检测到旧版 config.env，请迁移到 config.yaml"
        log_info "参考 config.yaml.example 创建新配置文件"
    fi
    log_error "config.yaml 不存在"
    exit 1
fi

if [ ! -f "$USERS_FILE" ]; then
    log_error "users.yaml 不存在"
    exit 1
fi

check_dependencies

log_info "=========================================="
log_info "同步用户配置 (多节点模式)"
log_info "=========================================="

# 使用 Python 解析配置并执行同步
python3 << 'PYTHON_SCRIPT'
import yaml
import json
import subprocess
import os
import sys
import tempfile

SCRIPT_DIR = os.environ.get('SCRIPT_DIR', os.path.dirname(os.path.abspath(__file__)))
if not SCRIPT_DIR:
    SCRIPT_DIR = os.getcwd()

# 读取配置
with open(f'{SCRIPT_DIR}/config.yaml', 'r') as f:
    config = yaml.safe_load(f)

with open(f'{SCRIPT_DIR}/users.yaml', 'r') as f:
    users_config = yaml.safe_load(f)

main_vps = config['main_vps']
cloudflare = config.get('cloudflare', {})
sub_port = config.get('sub_port', 8443)
nodes = config.get('nodes', [])
users = users_config.get('users', [])

print(f"[INFO] 主 VPS: {main_vps['ip']}")
print(f"[INFO] 节点数量: {len(nodes)}")
print(f"[INFO] 用户数量: {len(users)}")

# 生成远程同步脚本
def generate_remote_script(node_config, is_main=True):
    """生成在 VPS 上执行的脚本"""
    return '''#!/bin/bash
USERS_YAML_FILE="$1"
SUB_PORT="$2"
IS_MAIN="$3"

XRAY_BIN="/usr/local/bin/xray"
CONFIG_FILE="/usr/local/etc/xray/config.json"
TRAFFIC_DIR="/var/lib/xray/traffic"
SUB_DIR="/var/www/sub"

mkdir -p "$TRAFFIC_DIR" "$SUB_DIR"

# 安装 PyYAML
python3 -c "import yaml" 2>/dev/null || pip3 install pyyaml -q

# 获取服务器信息
IP=$(curl -s ifconfig.me)

# 从配置获取密钥
KEYS=$(python3 << 'PY'
import json
with open('/usr/local/etc/xray/config.json') as f:
    c = json.load(f)
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

echo "NODE_INFO:$IP:$PUB:$SID"

# 解析用户并更新 Xray 配置
python3 << PYEOF
import yaml
import json
import subprocess
import os

with open('$USERS_YAML_FILE', 'r') as f:
    users_config = yaml.safe_load(f)

users = users_config.get('users', [])

# 读取 Xray 配置
with open('/usr/local/etc/xray/config.json', 'r') as f:
    xray_config = json.load(f)

# 找到 VLESS inbound
vless_idx = 0
for i, inb in enumerate(xray_config['inbounds']):
    if inb.get('protocol') == 'vless':
        vless_idx = i
        break

existing_emails = {c['email'] for c in xray_config['inbounds'][vless_idx]['settings']['clients']}

new_clients = []
for user in users:
    name = user['name']
    email = f"{name}@vps"

    if email not in existing_emails:
        result = subprocess.run(['/usr/local/bin/xray', 'uuid'], capture_output=True, text=True)
        uuid = result.stdout.strip()
        new_clients.append({
            "id": uuid,
            "flow": "xtls-rprx-vision",
            "email": email
        })
        print(f"[INFO] Created user {name}: {uuid}")
    else:
        for client in xray_config['inbounds'][vless_idx]['settings']['clients']:
            if client['email'] == email:
                print(f"[INFO] User {name} exists: {client['id']}")
                break

if new_clients:
    xray_config['inbounds'][vless_idx]['settings']['clients'].extend(new_clients)
    with open('/usr/local/etc/xray/config.json', 'w') as f:
        json.dump(xray_config, f, indent=4)

# 输出所有用户的 UUID
print("USER_UUIDS_START")
for client in xray_config['inbounds'][vless_idx]['settings']['clients']:
    if '@vps' in client['email']:
        name = client['email'].replace('@vps', '')
        print(f"{name}:{client['id']}")
print("USER_UUIDS_END")
PYEOF

# 重启 Xray
if $XRAY_BIN run -test -config $CONFIG_FILE > /dev/null 2>&1; then
    systemctl restart xray
    sleep 2
    if [ "$(systemctl is-active xray)" = "active" ]; then
        echo "[INFO] Xray restarted successfully"
    fi
fi

echo "SYNC_DONE"
'''

def run_ssh_command(host, port, user, password, command, timeout=120):
    """通过 SSH 执行命令"""
    expect_script = f'''
set timeout {timeout}
spawn ssh -p {port} -o StrictHostKeyChecking=no {user}@{host}
expect {{
    "password:" {{ send "{password}\\r" }}
    timeout {{ puts "SSH timeout"; exit 1 }}
}}
expect "#"
send "{command}\\r"
expect {{
    "SYNC_DONE" {{ }}
    timeout {{ puts "Command timeout"; exit 1 }}
}}
expect "#"
send "exit\\r"
expect eof
'''
    result = subprocess.run(['expect', '-c', expect_script], capture_output=True, text=True, timeout=timeout+30)
    return result.stdout

def upload_and_run(host, port, user, password, local_files, remote_script, timeout=180):
    """上传文件并执行脚本"""
    # 生成 expect 脚本
    scp_files = ' '.join(local_files)
    expect_script = f'''
set timeout {timeout}

# 上传文件
spawn scp -P {port} -o StrictHostKeyChecking=no {scp_files} {user}@{host}:/tmp/
expect {{
    "password:" {{ send "{password}\\r" }}
    timeout {{ puts "SCP timeout"; exit 1 }}
}}
expect eof

# 执行脚本
spawn ssh -p {port} -o StrictHostKeyChecking=no {user}@{host}
expect {{
    "password:" {{ send "{password}\\r" }}
    timeout {{ puts "SSH timeout"; exit 1 }}
}}
expect "#"
send "chmod +x /tmp/sync_remote.sh && /tmp/sync_remote.sh /tmp/users.yaml '{sub_port}' 'true'\\r"
expect {{
    "SYNC_DONE" {{ }}
    timeout {{ puts "Script timeout"; exit 1 }}
}}
expect "#"
send "rm -f /tmp/sync_remote.sh /tmp/users.yaml\\r"
expect "#"
send "exit\\r"
expect eof
'''
    result = subprocess.run(['expect', '-c', expect_script], capture_output=True, text=True, timeout=timeout+30)
    return result.stdout

# 同步主 VPS
print("\n[INFO] 同步主 VPS...")

# 保存远程脚本
with open('/tmp/sync_remote.sh', 'w') as f:
    f.write(generate_remote_script(main_vps, is_main=True))

# 复制 users.yaml
subprocess.run(['cp', f'{SCRIPT_DIR}/users.yaml', '/tmp/users.yaml'])

# 执行同步
output = upload_and_run(
    main_vps['ip'],
    main_vps.get('ssh_port', 22),
    main_vps.get('user', 'root'),
    main_vps['password'],
    ['/tmp/sync_remote.sh', '/tmp/users.yaml'],
    '/tmp/sync_remote.sh'
)

# 解析主节点信息
main_node_info = None
main_user_uuids = {}

for line in output.split('\n'):
    if line.startswith('NODE_INFO:'):
        parts = line.replace('NODE_INFO:', '').split(':')
        if len(parts) >= 3:
            main_node_info = {
                'ip': parts[0],
                'public_key': parts[1],
                'short_id': parts[2]
            }
            print(f"[INFO] 主节点: {main_node_info['ip']}")

    if 'USER_UUIDS_START' in output:
        in_uuids = False
        for l in output.split('\n'):
            if 'USER_UUIDS_START' in l:
                in_uuids = True
                continue
            if 'USER_UUIDS_END' in l:
                break
            if in_uuids and ':' in l:
                parts = l.strip().split(':')
                if len(parts) >= 2:
                    name = parts[0].strip()
                    uuid = parts[1].strip()
                    if name and uuid and len(uuid) == 36:
                        main_user_uuids[name] = uuid

print(f"[INFO] 获取到 {len(main_user_uuids)} 个用户 UUID")

# 同步远程节点
remote_nodes_info = []
for node in nodes:
    if node['type'] == 'remote' and 'ssh' in node:
        print(f"\n[INFO] 同步远程节点: {node['name']}...")

        ssh_config = node['ssh']
        output = upload_and_run(
            node['server'],
            ssh_config.get('port', 22),
            ssh_config.get('user', 'root'),
            ssh_config['password'],
            ['/tmp/sync_remote.sh', '/tmp/users.yaml'],
            '/tmp/sync_remote.sh'
        )

        # 远程节点信息已经在 config.yaml 中配置
        remote_nodes_info.append({
            'name': node['name'],
            'server': node['server'],
            'port': node.get('port', 443),
            'public_key': node['public_key'],
            'short_id': node['short_id']
        })
        print(f"[INFO] {node['name']} 同步完成")

# 生成订阅配置（包含所有节点）
print("\n[INFO] 生成多节点订阅配置...")

# 构建节点列表
all_nodes = []

# 主节点
if main_node_info:
    for node in nodes:
        if node['type'] == 'local':
            all_nodes.append({
                'name': node['name'],
                'server': main_node_info['ip'],
                'port': 443,
                'public_key': main_node_info['public_key'],
                'short_id': main_node_info['short_id']
            })
            break

# 远程节点
for node in nodes:
    if node['type'] == 'remote':
        all_nodes.append({
            'name': node['name'],
            'server': node['server'],
            'port': node.get('port', 443),
            'public_key': node['public_key'],
            'short_id': node['short_id']
        })

print(f"[INFO] 总节点数: {len(all_nodes)}")
for n in all_nodes:
    print(f"  - {n['name']}: {n['server']}")

# 生成订阅服务配置并上传到主 VPS
sub_config = {
    'nodes': all_nodes,
    'users': {u['name']: main_user_uuids.get(u['name'], '') for u in users if u['name'] in main_user_uuids},
    'user_settings': {u['name']: {'traffic_limit_gb': u.get('traffic_limit_gb', 0), 'reset_day': u.get('reset_day', 1)} for u in users}
}

# 生成订阅服务器脚本
sub_server_script = '''#!/usr/bin/env python3
import http.server
import ssl
import json
import os
import mimetypes
from datetime import datetime
from urllib.parse import urlparse, unquote

SUB_DIR = "/var/www/sub"
DOWNLOAD_DIR = "/var/www/downloads"
CONFIG_FILE = os.path.join(SUB_DIR, "multi_node_config.json")

class SubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_HEAD(self):
        self._handle_request(head_only=True)

    def do_GET(self):
        self._handle_request(head_only=False)

    def _handle_request(self, head_only=False):
        path = unquote(urlparse(self.path).path).strip('/')

        # 下载服务
        if path.startswith('download'):
            self._handle_download(path, head_only)
            return

        # 加载配置
        try:
            with open(CONFIG_FILE, 'r') as f:
                config = json.load(f)
        except:
            self.send_error(500, "Config not found")
            return

        nodes = config.get('nodes', [])
        users = config.get('users', {})
        user_settings = config.get('user_settings', {})

        # 检查用户
        if path not in users:
            self.send_error(404, "Not Found")
            return

        uuid = users[path]
        settings = user_settings.get(path, {})

        # 生成 Clash 配置
        proxies = []
        proxy_names = []
        for node in nodes:
            proxy = {
                'name': node['name'],
                'type': 'vless',
                'server': node['server'],
                'port': node['port'],
                'uuid': uuid,
                'network': 'tcp',
                'tls': True,
                'udp': True,
                'flow': 'xtls-rprx-vision',
                'servername': 'www.apple.com',
                'reality-opts': {
                    'public-key': node['public_key'],
                    'short-id': node['short_id']
                },
                'client-fingerprint': 'chrome'
            }
            proxies.append(proxy)
            proxy_names.append(node['name'])

        clash_config = {
            'proxies': proxies,
            'proxy-groups': [
                {
                    'name': 'Proxy',
                    'type': 'select',
                    'proxies': proxy_names + ['DIRECT']
                },
                {
                    'name': 'Auto',
                    'type': 'url-test',
                    'proxies': proxy_names,
                    'url': 'http://www.gstatic.com/generate_204',
                    'interval': 300
                }
            ],
            'rules': [
                'GEOIP,CN,DIRECT',
                'MATCH,Proxy'
            ]
        }

        # 转换为 YAML
        import yaml
        yaml_content = f"# Clash Meta Configuration for {path}\\n"
        yaml_content += f"# Nodes: {', '.join(proxy_names)}\\n\\n"
        yaml_content += yaml.dump(clash_config, allow_unicode=True, default_flow_style=False, sort_keys=False)

        # 计算流量信息
        traffic_limit_gb = settings.get('traffic_limit_gb', 0)
        total = traffic_limit_gb * 1024 * 1024 * 1024 if traffic_limit_gb > 0 else 0
        upload = 0
        download = 0
        expire = 0

        if traffic_limit_gb > 0:
            reset_day = settings.get('reset_day', 1)
            now = datetime.now()
            year, month = now.year, now.month
            if now.day >= reset_day:
                month += 1
                if month > 12:
                    month = 1
                    year += 1
            try:
                expire = int(datetime(year, month, reset_day).timestamp())
            except:
                pass

        self.send_response(200)
        self.send_header('Content-Type', 'text/yaml; charset=utf-8')

        if total > 0:
            userinfo = f"upload={upload}; download={download}; total={total}"
            if expire > 0:
                userinfo += f"; expire={expire}"
            self.send_header('subscription-userinfo', userinfo)

        self.end_headers()
        if not head_only:
            self.wfile.write(yaml_content.encode('utf-8'))

    def _handle_download(self, path, head_only):
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
    server = http.server.HTTPServer(('0.0.0.0', port), SubHandler)
    if use_ssl and os.path.exists('/etc/nginx/ssl/origin.crt'):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain('/etc/nginx/ssl/origin.crt', '/etc/nginx/ssl/origin.key')
        server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"Multi-node subscription server running on port {port} (SSL: {use_ssl})")
    server.serve_forever()

if __name__ == '__main__':
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8443
    use_ssl = os.path.exists('/etc/nginx/ssl/origin.crt')
    run_server(port, use_ssl)
'''

# 保存配置和脚本到临时文件
with open('/tmp/multi_node_config.json', 'w') as f:
    json.dump(sub_config, f, indent=2)

with open('/tmp/sub_server_multi.py', 'w') as f:
    f.write(sub_server_script)

# 上传到主 VPS 并重启订阅服务
print("\n[INFO] 更新主 VPS 订阅服务...")

upload_expect = f'''
set timeout 60
spawn scp -P {main_vps.get('ssh_port', 22)} -o StrictHostKeyChecking=no /tmp/multi_node_config.json /tmp/sub_server_multi.py {main_vps.get('user', 'root')}@{main_vps['ip']}:/var/www/sub/
expect {{
    "password:" {{ send "{main_vps['password']}\\r" }}
    timeout {{ exit 1 }}
}}
expect eof

spawn ssh -p {main_vps.get('ssh_port', 22)} -o StrictHostKeyChecking=no {main_vps.get('user', 'root')}@{main_vps['ip']}
expect {{
    "password:" {{ send "{main_vps['password']}\\r" }}
    timeout {{ exit 1 }}
}}
expect "#"
send "mv /var/www/sub/sub_server_multi.py /var/www/sub/sub_server.py && chmod 755 /var/www/sub/sub_server.py && systemctl restart sub-server && sleep 2 && systemctl is-active sub-server\\r"
expect "#"
send "exit\\r"
expect eof
'''

result = subprocess.run(['expect', '-c', upload_expect], capture_output=True, text=True, timeout=90)
if 'active' in result.stdout:
    print("[INFO] 订阅服务已更新并重启")
else:
    print("[WARN] 订阅服务可能未正常启动")

# 生成订阅链接
cf_domain = cloudflare.get('domain', '')
cf_subdomain = cloudflare.get('subdomain', '')

if cf_domain and cf_subdomain:
    base_url = f"https://{cf_subdomain}.{cf_domain}:{sub_port}"
else:
    base_url = f"http://{main_vps['ip']}:{sub_port}"

print("\n" + "=" * 60)
print("订阅链接:")
print("=" * 60)

with open(f'{SCRIPT_DIR}/subscriptions.txt', 'w') as f:
    for user in users:
        name = user['name']
        url = f"{base_url}/{name}"
        print(f"{name}: {url}")
        f.write(f"{name}: {url}\n")

print("=" * 60)
print(f"\n[INFO] 订阅链接已保存到 {SCRIPT_DIR}/subscriptions.txt")
print("[INFO] 同步完成!")
PYTHON_SCRIPT

export SCRIPT_DIR="$SCRIPT_DIR"
