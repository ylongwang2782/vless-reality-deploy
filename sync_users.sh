#!/bin/bash

# ==========================================
# 用户同步脚本
# 同步用户到所有节点，并更新订阅服务
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
USERS_FILE="$SCRIPT_DIR/users.yaml"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# 检查配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "配置文件不存在: $CONFIG_FILE"
    exit 1
fi

if [ ! -f "$USERS_FILE" ]; then
    log_error "用户配置不存在: $USERS_FILE"
    log_info "请先复制 users.yaml.example 为 users.yaml 并编辑"
    exit 1
fi

# 检查依赖
python3 -c "import yaml" 2>/dev/null || {
    log_info "安装 PyYAML..."
    pip3 install --user pyyaml -q 2>/dev/null || pip3 install pyyaml --break-system-packages -q
}

log_info "=========================================="
log_info "同步用户到所有节点"
log_info "=========================================="

# 生成远程同步脚本
cat > /tmp/sync_node_remote.sh << 'REMOTE_SCRIPT'
#!/bin/bash
# 远程同步脚本

USERS_FILE="/tmp/users_to_sync.yaml"

python3 << 'PYEOF'
import yaml
import json
import subprocess

with open('/tmp/users_to_sync.yaml', 'r') as f:
    users_config = yaml.safe_load(f)

users = users_config.get('users', [])

with open('/usr/local/etc/xray/config.json', 'r') as f:
    xray_config = json.load(f)

# 找到 VLESS inbound
vless_idx = 0
for i, inb in enumerate(xray_config['inbounds']):
    if inb.get('protocol') == 'vless':
        vless_idx = i
        break

existing = {c['email']: c['id'] for c in xray_config['inbounds'][vless_idx]['settings']['clients']}
user_uuids = {}

for user in users:
    name = user['name']
    email = f"{name}@vps"

    if email in existing:
        user_uuids[name] = existing[email]
    else:
        result = subprocess.run(['/usr/local/bin/xray', 'uuid'], capture_output=True, text=True)
        uuid = result.stdout.strip()
        xray_config['inbounds'][vless_idx]['settings']['clients'].append({
            "id": uuid,
            "flow": "xtls-rprx-vision",
            "email": email
        })
        user_uuids[name] = uuid
        print(f"Created: {name}")

with open('/usr/local/etc/xray/config.json', 'w') as f:
    json.dump(xray_config, f, indent=4)

print("USER_UUIDS_JSON:" + json.dumps(user_uuids))
PYEOF

# 重启 Xray
systemctl restart xray
sleep 2
[ "$(systemctl is-active xray)" = "active" ] && echo "SYNC_NODE_OK" || echo "SYNC_NODE_FAILED"
REMOTE_SCRIPT

# 使用 Python 执行同步
python3 << PYTHON_SCRIPT
import yaml
import json
import subprocess
import os
import sys

SCRIPT_DIR = "$SCRIPT_DIR"

# 读取配置
with open(f'{SCRIPT_DIR}/config.yaml', 'r') as f:
    config = yaml.safe_load(f)

with open(f'{SCRIPT_DIR}/users.yaml', 'r') as f:
    users_config = yaml.safe_load(f)

nodes = config.get('nodes', [])
cloudflare = config.get('cloudflare', {})
sub_port = config.get('sub_port', 8443)
users = users_config.get('users', [])

# 检查节点是否已部署
deployed_nodes = [n for n in nodes if n.get('public_key')]
if not deployed_nodes:
    print("[ERROR] 没有已部署的节点")
    print("请先运行 ./deploy.sh 部署主节点")
    sys.exit(1)

main_node = nodes[0]
if not main_node.get('public_key'):
    print("[ERROR] 主节点未部署")
    print("请先运行 ./deploy.sh")
    sys.exit(1)

print(f"[INFO] 已部署节点: {len(deployed_nodes)}")
print(f"[INFO] 用户数量: {len(users)}")

# 同步每个节点
user_uuids = {}

for node in deployed_nodes:
    if 'ssh' not in node:
        print(f"[WARN] 节点 {node['name']} 未配置 SSH，跳过")
        continue

    ssh = node['ssh']
    server = node['server']
    name = node['name']
    ssh_port = ssh.get('port', 22)
    ssh_user = ssh.get('user', 'root')
    ssh_pass = ssh['password']

    print(f"\n[STEP] 同步节点: {name} ({server})...")

    # 生成 expect 脚本
    expect_script = f'''
set timeout 120

# 上传脚本和用户配置
spawn scp -P {ssh_port} -o StrictHostKeyChecking=no /tmp/sync_node_remote.sh {SCRIPT_DIR}/users.yaml {ssh_user}@{server}:/tmp/
expect {{
    "password:" {{ send "{ssh_pass}\\r" }}
    timeout {{ puts "SCP timeout"; exit 1 }}
}}
expect eof

# 重命名用户文件
spawn ssh -p {ssh_port} -o StrictHostKeyChecking=no {ssh_user}@{server}
expect {{
    "password:" {{ send "{ssh_pass}\\r" }}
    timeout {{ puts "SSH timeout"; exit 1 }}
}}
expect "#"
send "mv /tmp/users.yaml /tmp/users_to_sync.yaml && chmod +x /tmp/sync_node_remote.sh && /tmp/sync_node_remote.sh\\r"
expect {{
    "SYNC_NODE_OK" {{ }}
    "SYNC_NODE_FAILED" {{ puts "Sync failed" }}
    timeout {{ puts "Script timeout" }}
}}
expect "#"
send "rm -f /tmp/sync_node_remote.sh /tmp/users_to_sync.yaml\\r"
expect "#"
send "exit\\r"
expect eof
'''

    result = subprocess.run(['expect', '-c', expect_script], capture_output=True, text=True, timeout=150)

    # 提取 UUID
    for line in result.stdout.split('\\n'):
        if 'USER_UUIDS_JSON:' in line:
            try:
                json_str = line.split('USER_UUIDS_JSON:')[1].strip()
                uuids = json.loads(json_str)
                user_uuids.update(uuids)
            except Exception as e:
                print(f"[DEBUG] Parse error: {e}")

    if 'SYNC_NODE_OK' in result.stdout:
        print(f"[INFO] {name} 同步完成")
    else:
        print(f"[WARN] {name} 同步可能失败")
        # 调试输出
        if 'Created:' in result.stdout:
            for line in result.stdout.split('\\n'):
                if 'Created:' in line:
                    print(f"  {line.strip()}")

if not user_uuids:
    print("[ERROR] 无法获取用户 UUID")
    print("[DEBUG] 尝试从主节点直接获取...")

    # 直接从主节点获取
    ssh = main_node['ssh']
    expect_script = f'''
set timeout 30
spawn ssh -p {ssh.get('port', 22)} -o StrictHostKeyChecking=no {ssh.get('user', 'root')}@{main_node['server']}
expect {{
    "password:" {{ send "{ssh['password']}\\r" }}
    timeout {{ exit 1 }}
}}
expect "#"
send "python3 -c \\"import json; c=json.load(open('/usr/local/etc/xray/config.json')); clients=[i for i in c['inbounds'] if i.get('protocol')=='vless'][0]['settings']['clients']; print('UUIDS:'+json.dumps({{cl['email'].replace('@vps',''):cl['id'] for cl in clients if '@vps' in cl['email']}}))\\"\r"
expect "#"
send "exit\\r"
expect eof
'''
    result = subprocess.run(['expect', '-c', expect_script], capture_output=True, text=True, timeout=60)

    for line in result.stdout.split('\\n'):
        if 'UUIDS:' in line:
            try:
                json_str = line.split('UUIDS:')[1].strip()
                user_uuids = json.loads(json_str)
                print(f"[INFO] 从主节点获取到 {len(user_uuids)} 个用户")
            except:
                pass

if not user_uuids:
    print("[ERROR] 仍然无法获取用户 UUID，请检查节点状态")
    sys.exit(1)

print(f"\\n[INFO] 获取到 {len(user_uuids)} 个用户")

# 生成订阅服务配置
print("\\n[STEP] 更新订阅服务...")

sub_config = {
    'nodes': [{
        'name': n['name'],
        'server': n['server'],
        'port': n.get('port', 443),
        'public_key': n['public_key'],
        'short_id': n['short_id']
    } for n in deployed_nodes],
    'users': user_uuids,
    'user_settings': {u['name']: {
        'traffic_limit_gb': u.get('traffic_limit_gb', 0),
        'reset_day': u.get('reset_day', 1)
    } for u in users}
}

# 订阅服务器脚本
sub_server = '''#!/usr/bin/env python3
import http.server, ssl, json, os, mimetypes, yaml
from datetime import datetime
from urllib.parse import urlparse, unquote

SUB_DIR = "/var/www/sub"
DOWNLOAD_DIR = "/var/www/downloads"
CONFIG_FILE = os.path.join(SUB_DIR, "config.json")

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def do_GET(self):
        path = unquote(urlparse(self.path).path).strip('/')

        if path.startswith('download'):
            self._download(path)
            return

        try:
            with open(CONFIG_FILE) as f:
                cfg = json.load(f)
        except:
            self.send_error(500)
            return

        if path not in cfg.get('users', {}):
            self.send_error(404)
            return

        uuid = cfg['users'][path]
        settings = cfg.get('user_settings', {}).get(path, {})

        proxies = []
        names = []
        for n in cfg.get('nodes', []):
            proxies.append({
                'name': n['name'], 'type': 'vless', 'server': n['server'],
                'port': n['port'], 'uuid': uuid, 'network': 'tcp', 'tls': True,
                'udp': True, 'flow': 'xtls-rprx-vision', 'servername': 'www.apple.com',
                'reality-opts': {'public-key': n['public_key'], 'short-id': n['short_id']},
                'client-fingerprint': 'chrome'
            })
            names.append(n['name'])

        clash = {
            'proxies': proxies,
            'proxy-groups': [
                {'name': 'Proxy', 'type': 'select', 'proxies': names + ['DIRECT']},
                {'name': 'Auto', 'type': 'url-test', 'proxies': names,
                 'url': 'http://www.gstatic.com/generate_204', 'interval': 300}
            ],
            'rules': ['GEOIP,CN,DIRECT', 'MATCH,Proxy']
        }

        NL = chr(10)
        content = "# Clash Meta - " + path + NL + "# Nodes: " + ", ".join(names) + NL + NL
        content += yaml.dump(clash, allow_unicode=True, default_flow_style=False, sort_keys=False)

        self.send_response(200)
        self.send_header('Content-Type', 'text/yaml; charset=utf-8')

        limit = settings.get('traffic_limit_gb', 0)
        if limit > 0:
            total = limit * 1024**3
            reset = settings.get('reset_day', 1)
            now = datetime.now()
            y, m = now.year, now.month
            if now.day >= reset:
                m += 1
                if m > 12: m, y = 1, y + 1
            try:
                exp = int(datetime(y, m, reset).timestamp())
                self.send_header('subscription-userinfo', 'upload=0; download=0; total=' + str(int(total)) + '; expire=' + str(exp))
            except: pass

        self.end_headers()
        self.wfile.write(content.encode())

    def _download(self, path):
        if path in ('download', 'download/'):
            idx = os.path.join(DOWNLOAD_DIR, 'index.html')
            if os.path.exists(idx):
                self.send_response(200)
                self.send_header('Content-Type', 'text/html')
                self.end_headers()
                self.wfile.write(open(idx, 'rb').read())
            else:
                self.send_error(404)
            return

        fn = path[len('download/'):]
        fp = os.path.join(DOWNLOAD_DIR, fn)
        if '..' in fn or not os.path.isfile(fp):
            self.send_error(404)
            return

        self.send_response(200)
        ct, _ = mimetypes.guess_type(fp)
        self.send_header('Content-Type', ct or 'application/octet-stream')
        self.send_header('Content-Length', os.path.getsize(fp))
        self.send_header('Content-Disposition', 'attachment; filename="' + fn + '"')
        self.end_headers()
        with open(fp, 'rb') as f:
            while True:
                c = f.read(65536)
                if not c:
                    break
                self.wfile.write(c)

if __name__ == '__main__':
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8443
    srv = http.server.HTTPServer(('0.0.0.0', port), Handler)
    if os.path.exists('/etc/nginx/ssl/origin.crt'):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain('/etc/nginx/ssl/origin.crt', '/etc/nginx/ssl/origin.key')
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print('Subscription server on port ' + str(port))
    srv.serve_forever()
'''

# 保存配置
with open('/tmp/sub_config.json', 'w') as f:
    json.dump(sub_config, f, indent=2)

with open('/tmp/sub_server.py', 'w') as f:
    f.write(sub_server)

# systemd 服务
systemd_svc = f'''[Unit]
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

with open('/tmp/sub-server.service', 'w') as f:
    f.write(systemd_svc)

# 上传到主节点
ssh = main_node['ssh']
server = main_node['server']
ssh_port = ssh.get('port', 22)
ssh_user = ssh.get('user', 'root')
ssh_pass = ssh['password']

expect_script = f'''
set timeout 60

spawn scp -P {ssh_port} -o StrictHostKeyChecking=no /tmp/sub_config.json /tmp/sub_server.py /tmp/sub-server.service {ssh_user}@{server}:/tmp/
expect {{
    "password:" {{ send "{ssh_pass}\\r" }}
    timeout {{ exit 1 }}
}}
expect eof

spawn ssh -p {ssh_port} -o StrictHostKeyChecking=no {ssh_user}@{server}
expect {{
    "password:" {{ send "{ssh_pass}\\r" }}
    timeout {{ exit 1 }}
}}
expect "#"
send "mv /tmp/sub_config.json /var/www/sub/config.json && mv /tmp/sub_server.py /var/www/sub/ && chmod 755 /var/www/sub/sub_server.py && mv /tmp/sub-server.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable sub-server && systemctl restart sub-server && sleep 2 && systemctl is-active sub-server\\r"
expect "#"
send "exit\\r"
expect eof
'''

result = subprocess.run(['expect', '-c', expect_script], capture_output=True, text=True, timeout=90)

if 'active' in result.stdout:
    print("[INFO] 订阅服务已更新")
else:
    print("[WARN] 订阅服务可能未正常启动")

# 生成订阅链接
cf_domain = cloudflare.get('domain', '')
cf_subdomain = cloudflare.get('subdomain', '')

if cf_domain and cf_subdomain:
    base_url = f"https://{cf_subdomain}.{cf_domain}:{sub_port}"
else:
    base_url = f"http://{main_node['server']}:{sub_port}"

print("\\n" + "=" * 60)
print("订阅链接:")
print("=" * 60)

with open(f'{SCRIPT_DIR}/subscriptions.txt', 'w') as f:
    for user in users:
        name = user['name']
        url = f"{base_url}/{name}"
        print(f"{name}: {url}")
        f.write(f"{name}: {url}\\n")

print("=" * 60)
print(f"\\n[INFO] 已保存到 {SCRIPT_DIR}/subscriptions.txt")
print("\\n包含节点:")
for n in deployed_nodes:
    print(f"  - {n['name']} ({n['server']})")
print("\\n[INFO] 同步完成!")
PYTHON_SCRIPT
