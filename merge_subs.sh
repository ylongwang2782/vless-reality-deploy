#!/bin/bash

# ==========================================
# 合并多节点订阅
# 从所有节点采集信息，生成合并订阅部署到主节点
# 用法: ./merge_subs.sh [--dry-run]
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
USERS_FILE="$SCRIPT_DIR/users.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

DRY_RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            echo "用法: $0 [--dry-run]"
            echo ""
            echo "从所有节点采集 Xray 信息，生成合并订阅部署到主节点。"
            echo "增删节点后重新运行此脚本即可更新订阅。"
            echo ""
            echo "  --dry-run  只采集信息并生成文件，不部署到服务器"
            exit 0
            ;;
        *) log_error "未知参数: $1"; exit 1 ;;
    esac
done

if [ ! -f "$CONFIG_FILE" ] || [ ! -f "$USERS_FILE" ]; then
    log_error "缺少 config.yaml 或 users.yaml"
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=5"

# ==========================================
# Step 1: 解析配置
# ==========================================
log_info "解析配置..."

MERGE_DATA=$(python3 "$SCRIPT_DIR/read_config.py" --file "$CONFIG_FILE" --merge-info 2>&1)
if [ $? -ne 0 ]; then
    log_error "解析配置失败: $MERGE_DATA"
    exit 1
fi
eval "$MERGE_DATA"

log_info "主节点: $PRIMARY_ID ($PRIMARY_SSH_HOST)"
log_info "所有节点: $ALL_NODE_IDS"

# ==========================================
# Step 2: 从各节点采集 Xray 信息
# ==========================================
log_info "采集节点信息..."

NODES_JSON_FILE=$(mktemp)
echo '{}' > "$NODES_JSON_FILE"

for node_entry in $ALL_NODE_IDS; do
    node_id=$(echo "$node_entry" | cut -d: -f1)
    ssh_host=$(echo "$node_entry" | cut -d: -f2)
    node_ip=$(echo "$node_entry" | cut -d: -f3)

    log_info "  采集 $node_id ($ssh_host)..."

    NODE_INFO=$(ssh $SSH_OPTS "$ssh_host" "python3 << 'PY'
import json, subprocess
with open(\"/usr/local/etc/xray/config.json\") as f:
    c = json.load(f)
for inb in c[\"inbounds\"]:
    if inb.get(\"protocol\") == \"vless\":
        rs = inb[\"streamSettings\"][\"realitySettings\"]
        pk = rs[\"privateKey\"]
        sid = rs[\"shortIds\"][0]
        pub_out = subprocess.run([\"/usr/local/bin/xray\",\"x25519\",\"-i\",pk], capture_output=True, text=True).stdout
        pub = [l for l in pub_out.splitlines() if \"Password\" in l or \"Public\" in l][0].split()[-1]
        users = {cl[\"email\"].replace(\"@vps\",\"\"): cl[\"id\"] for cl in inb[\"settings\"][\"clients\"]}
        print(json.dumps({\"pub\": pub, \"sid\": sid, \"users\": users}))
        break
PY" 2>/dev/null)

    if [ -z "$NODE_INFO" ]; then
        log_warn "  $node_id: 采集失败，跳过"
        continue
    fi

    # Merge into nodes JSON (name read from config.yaml by python later)
    python3 -c "
import json, sys
with open('$NODES_JSON_FILE') as f:
    data = json.load(f)
info = json.loads('''$NODE_INFO''')
data['$node_id'] = {
    'ip': '$node_ip',
    'pub': info['pub'],
    'sid': info['sid'],
    'users': info['users']
}
with open('$NODES_JSON_FILE', 'w') as f:
    json.dump(data, f, indent=2)
print(f'[OK] $node_id: {len(info[\"users\"])} users, pub={info[\"pub\"][:16]}...')
"
done

log_info "采集完成"

# ==========================================
# Step 3: 生成合并订阅 YAML
# ==========================================
log_info "生成合并订阅..."

OUTPUT_DIR=$(mktemp -d)

python3 << PYGEN
import json, os, sys
sys.path.insert(0, '$SCRIPT_DIR')
from read_config import parse_simple_yaml

with open('$NODES_JSON_FILE') as f:
    nodes = json.load(f)

if not nodes:
    print("[ERROR] 没有可用节点", file=sys.stderr)
    sys.exit(1)

# 从 config.yaml 读节点显示名
config = parse_simple_yaml('$CONFIG_FILE')
config_nodes = config.get('nodes', {})
for nid in nodes:
    nodes[nid]['name'] = config_nodes.get(nid, {}).get('name', nid)

# 读取 users.yaml 获取用户列表
import re
users_list = []
with open('$USERS_FILE') as f:
    for line in f:
        m = re.match(r'\s*-\s*name:\s*(\S+)', line)
        if m:
            users_list.append(m.group(1))

# 节点排序：主节点优先
primary_id = '$PRIMARY_ID'
node_order = sorted(nodes.keys(), key=lambda x: (0 if x == primary_id else 1, x))

def gen_proxy(node_name, ip, pub, sid, uuid):
    return f'''  - name: "{node_name}"
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
    client-fingerprint: chrome'''

for username in users_list:
    proxy_blocks = []
    node_names = []

    for nid in node_order:
        n = nodes[nid]
        uuid = n['users'].get(username)
        if not uuid:
            continue
        proxy_blocks.append(gen_proxy(n['name'], n['ip'], n['pub'], n['sid'], uuid))
        node_names.append(n['name'])

    if not proxy_blocks:
        print(f"[SKIP] {username}: no nodes")
        continue

    names_yaml = '\n'.join(f'      - "{n}"' for n in node_names)

    # AI 组：优先欧洲节点
    ai_proxies = sorted(node_names, key=lambda x: (0 if 'Europe' in x or 'EU' in x or 'Frankfurt' in x else 1))
    ai_yaml = '\n'.join(f'      - "{n}"' for n in ai_proxies)

    yaml_content = f'''# Clash Meta - {username} (Multi-Node Subscription)

proxies:
{chr(10).join(proxy_blocks)}

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - "Auto"
{names_yaml}
      - DIRECT

  - name: "Auto"
    type: url-test
    proxies:
{names_yaml}
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50

  - name: "Streaming"
    type: select
    proxies:
      - "Proxy"
{names_yaml}
      - DIRECT

  - name: "AI"
    type: select
    proxies:
{ai_yaml}
      - "Proxy"

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
  - RULE-SET,reject,AdBlock
  - RULE-SET,private,DIRECT
  - RULE-SET,lancidr,DIRECT,no-resolve
  - DOMAIN-SUFFIX,openai.com,AI
  - DOMAIN-SUFFIX,ai.com,AI
  - DOMAIN-SUFFIX,anthropic.com,AI
  - DOMAIN-SUFFIX,claude.ai,AI
  - DOMAIN-SUFFIX,gemini.google.com,AI
  - DOMAIN-SUFFIX,perplexity.ai,AI
  - DOMAIN-SUFFIX,netflix.com,Streaming
  - DOMAIN-SUFFIX,nflxvideo.net,Streaming
  - DOMAIN-SUFFIX,youtube.com,Streaming
  - DOMAIN-SUFFIX,googlevideo.com,Streaming
  - DOMAIN-SUFFIX,ytimg.com,Streaming
  - DOMAIN-SUFFIX,disneyplus.com,Streaming
  - DOMAIN-SUFFIX,spotify.com,Streaming
  - DOMAIN-SUFFIX,twitch.tv,Streaming
  - RULE-SET,telegramcidr,Proxy,no-resolve
  - RULE-SET,gfw,Proxy
  - RULE-SET,tld-not-cn,Proxy
  - RULE-SET,proxy,Proxy
  - RULE-SET,direct,DIRECT
  - RULE-SET,cncidr,DIRECT,no-resolve
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,Proxy
'''

    with open(f'$OUTPUT_DIR/{username}.yaml', 'w') as f:
        f.write(yaml_content)
    print(f'[OK] {username}: {len(node_names)} nodes')

print(f'[DONE] Generated {len(users_list)} files in $OUTPUT_DIR')
PYGEN

# ==========================================
# Step 4: 部署到主节点
# ==========================================
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] 生成的文件在: $OUTPUT_DIR"
    ls -la "$OUTPUT_DIR"
    rm -f "$NODES_JSON_FILE"
    exit 0
fi

log_info "部署订阅文件到主节点 ($PRIMARY_SSH_HOST)..."

scp $SSH_OPTS "$OUTPUT_DIR"/*.yaml "$PRIMARY_SSH_HOST:/var/www/sub/"

log_info "配置 nginx 静态订阅服务..."

# Generate and deploy nginx config + header updater
ssh $SSH_OPTS "$PRIMARY_SSH_HOST" bash << 'REMOTE'
# Stop Python sub-server if still running
systemctl stop sub-server 2>/dev/null || true
systemctl disable sub-server 2>/dev/null || true

# Generate nginx config from traffic data
python3 << 'PYGEN'
import json, os
from datetime import datetime

TRAFFIC_DIR = "/var/lib/xray/traffic"
NGINX_CONF = "/etc/nginx/sites-available/sub-static"

users = []
for fn in sorted(os.listdir(TRAFFIC_DIR)):
    if not fn.endswith(".json"):
        continue
    with open(os.path.join(TRAFFIC_DIR, fn)) as f:
        uc = json.load(f)
    name = uc.get("username", fn.replace(".json", ""))
    limit_gb = uc.get("traffic_limit_gb", 200)
    total = limit_gb * 1024 * 1024 * 1024
    upload = uc.get("upload_bytes", 0)
    download = uc.get("download_bytes", 0)
    reset_day = uc.get("reset_day", 1)
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
        expire = 0
    userinfo = f"upload={upload}; download={download}; total={total}"
    if expire > 0:
        userinfo += f"; expire={expire}"
    users.append((name, userinfo))

conf = """server {
    listen 8443 ssl http2;
    server_name _;

    ssl_certificate /etc/nginx/ssl/origin.crt;
    ssl_certificate_key /etc/nginx/ssl/origin.key;

    root /var/www/sub;

"""
for name, userinfo in users:
    conf += f"""    location = /{name} {{
        alias /var/www/sub/{name}.yaml;
        default_type 'text/yaml; charset=utf-8';
        add_header subscription-userinfo '{userinfo}';
        add_header Content-Disposition 'attachment; filename="{name}.yaml"';
    }}

"""
conf += """    location = /download/links.json {
        alias /var/www/sub/routes.json;
        default_type 'application/json; charset=utf-8';
    }

    location / {
        return 404;
    }
}
"""
with open(NGINX_CONF, "w") as f:
    f.write(conf)
print(f"[OK] nginx config: {len(users)} users")
PYGEN

ln -sf /etc/nginx/sites-available/sub-static /etc/nginx/sites-enabled/sub-static
rm -f /etc/nginx/sites-enabled/clash-sub 2>/dev/null || true
nginx -t && systemctl reload nginx
echo "[OK] nginx reloaded"
REMOTE

# Cleanup
rm -rf "$OUTPUT_DIR" "$NODES_JSON_FILE"

log_info "=========================================="
log_info "合并订阅部署完成！"
log_info "=========================================="
log_info "增删节点后重新运行 ./merge_subs.sh 即可更新"
log_info "=========================================="
