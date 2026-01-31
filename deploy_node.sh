#!/bin/bash

# ==========================================
# 远程节点部署脚本
# 用法: ./deploy_node.sh <节点名>
# 示例: ./deploy_node.sh USA
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"

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

# 检查参数
if [ -z "$1" ]; then
    log_error "请指定节点名"
    echo ""
    echo "用法: $0 <节点名>"
    echo ""
    echo "可用节点:"

    if [ -f "$CONFIG_FILE" ]; then
        python3 << 'PY'
import yaml
with open('config.yaml', 'r') as f:
    config = yaml.safe_load(f)
for i, node in enumerate(config.get('nodes', [])):
    marker = "(主节点)" if i == 0 else ""
    status = "✓" if node.get('public_key') else "○"
    print(f"  {status} {node['name']} - {node['server']} {marker}")
PY
    fi
    echo ""
    echo "  ✓ = 已部署, ○ = 未部署"
    exit 1
fi

NODE_NAME="$1"

# 检查配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "配置文件不存在: $CONFIG_FILE"
    exit 1
fi

# 检查依赖
python3 -c "import yaml" 2>/dev/null || {
    log_info "安装 PyYAML..."
    pip3 install --user pyyaml -q 2>/dev/null || pip3 install pyyaml --break-system-packages -q
}

log_info "=========================================="
log_info "部署远程节点: $NODE_NAME"
log_info "=========================================="

# 使用 Python 部署节点
python3 << PYTHON_SCRIPT
import yaml
import subprocess
import os
import sys

SCRIPT_DIR = os.getcwd()
NODE_NAME = "$NODE_NAME"

# 读取配置
with open(f'{SCRIPT_DIR}/config.yaml', 'r') as f:
    config = yaml.safe_load(f)

nodes = config.get('nodes', [])

# 查找目标节点
target_node = None
target_index = -1
for i, node in enumerate(nodes):
    if node['name'].lower() == NODE_NAME.lower():
        target_node = node
        target_index = i
        break

if not target_node:
    print(f"[ERROR] 未找到节点: {NODE_NAME}")
    print("\n可用节点:")
    for node in nodes:
        print(f"  - {node['name']}")
    sys.exit(1)

if 'ssh' not in target_node:
    print(f"[ERROR] 节点 {NODE_NAME} 未配置 SSH 信息")
    sys.exit(1)

ssh = target_node['ssh']
server = target_node['server']
name = target_node['name']

print(f"[INFO] 节点: {name}")
print(f"[INFO] 服务器: {server}")
print(f"[INFO] SSH 端口: {ssh.get('port', 22)}")

# 检查是否已部署
if target_node.get('public_key'):
    print(f"[WARN] 节点 {name} 已部署过")
    print(f"       Public Key: {target_node['public_key']}")
    print(f"       Short ID: {target_node['short_id']}")
    response = input("\n是否重新部署? (y/N): ")
    if response.lower() != 'y':
        sys.exit(0)

# 生成安装脚本
install_script = f'''#!/bin/bash
set -e

NODE_NAME="{name}"

echo "=== 开启 BBR ==="
if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
fi

echo "=== 安装 Xray ==="
apt-get update && apt-get install -y curl python3 python3-pip
pip3 install pyyaml -q 2>/dev/null || pip3 install pyyaml --break-system-packages -q

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

XRAY_BIN="/usr/local/bin/xray"
systemctl stop xray 2>/dev/null || true

echo "=== 生成密钥 ==="
KEYS=$($XRAY_BIN x25519)
PK=$(echo "$KEYS" | grep "Private" | awk '{{print $2}}')
PUB=$(echo "$KEYS" | grep -E "Public|Password" | awk '{{print $2}}')
UUID=$($XRAY_BIN uuid)
SID=$(openssl rand -hex 4)

echo "=== 写入配置 ==="
mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<XRAY_EOF
{{
    "log": {{ "loglevel": "warning" }},
    "stats": {{}},
    "api": {{ "tag": "api", "services": ["StatsService"] }},
    "policy": {{
        "levels": {{ "0": {{ "statsUserUplink": true, "statsUserDownlink": true }} }},
        "system": {{ "statsInboundUplink": true, "statsInboundDownlink": true, "statsOutboundUplink": true, "statsOutboundDownlink": true }}
    }},
    "inbounds": [
        {{ "tag": "api", "port": 10085, "listen": "127.0.0.1", "protocol": "dokodemo-door", "settings": {{ "address": "127.0.0.1" }} }},
        {{
            "tag": "vless-in", "port": 443, "protocol": "vless",
            "settings": {{ "clients": [{{ "id": "$UUID", "flow": "xtls-rprx-vision", "email": "admin@vps" }}], "decryption": "none" }},
            "streamSettings": {{
                "network": "tcp", "security": "reality",
                "realitySettings": {{
                    "show": false, "dest": "www.apple.com:443", "xver": 0,
                    "serverNames": ["www.apple.com"],
                    "privateKey": "$PK",
                    "shortIds": ["$SID"]
                }}
            }}
        }}
    ],
    "outbounds": [{{ "protocol": "freedom" }}],
    "routing": {{ "rules": [{{ "inboundTag": ["api"], "outboundTag": "api", "type": "field" }}] }}
}}
XRAY_EOF

echo "=== 配置服务用户 ==="
id -u xray >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin xray
mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/override.conf <<'SVC_EOF'
[Service]
User=xray
Group=xray
SVC_EOF

mkdir -p /var/log/xray /var/lib/xray/traffic
chown -R xray:xray /var/log/xray
chmod 644 /usr/local/etc/xray/config.json

systemctl daemon-reload
systemctl restart xray
systemctl enable xray

echo "=== 配置防火墙 ==="
if command -v ufw &> /dev/null; then
    ufw allow 443/tcp >/dev/null 2>&1
fi

sleep 2
if [ "$(systemctl is-active xray)" = "active" ]; then
    echo ""
    echo "=========================================="
    echo "NODE_KEYS:$PUB:$SID"
    echo "=========================================="
    echo "DEPLOY_SUCCESS"
else
    echo "DEPLOY_FAILED"
    exit 1
fi
'''

# 保存安装脚本
with open('/tmp/install_node.sh', 'w') as f:
    f.write(install_script)

# 生成 expect 脚本
ssh_port = ssh.get('port', 22)
ssh_user = ssh.get('user', 'root')
ssh_pass = ssh['password']

expect_script = f'''
set timeout 300

# 上传脚本
spawn scp -P {ssh_port} -o StrictHostKeyChecking=no /tmp/install_node.sh {ssh_user}@{server}:/tmp/
expect {{
    "password:" {{ send "{ssh_pass}\\r" }}
    timeout {{ puts "SCP timeout"; exit 1 }}
}}
expect eof

# 执行安装
spawn ssh -p {ssh_port} -o StrictHostKeyChecking=no {ssh_user}@{server}
expect {{
    "password:" {{ send "{ssh_pass}\\r" }}
    timeout {{ puts "SSH timeout"; exit 1 }}
}}
expect "#"
send "chmod +x /tmp/install_node.sh && /tmp/install_node.sh\\r"
expect {{
    "DEPLOY_SUCCESS" {{ }}
    "DEPLOY_FAILED" {{ puts "Deploy failed"; exit 1 }}
    timeout {{ puts "Install timeout"; exit 1 }}
}}
expect "#"
send "rm -f /tmp/install_node.sh\\r"
expect "#"
send "exit\\r"
expect eof
'''

print(f"\n[STEP] 部署节点 {name}...")
result = subprocess.run(['expect', '-c', expect_script], capture_output=True, text=True, timeout=360)

# 提取密钥信息
public_key = ""
short_id = ""
for line in result.stdout.split('\n'):
    if 'NODE_KEYS:' in line:
        parts = line.split('NODE_KEYS:')[1].split(':')
        if len(parts) >= 2:
            public_key = parts[0].strip()
            short_id = parts[1].strip()

if public_key and short_id:
    print(f"[INFO] Public Key: {public_key}")
    print(f"[INFO] Short ID: {short_id}")

    # 更新配置文件
    config['nodes'][target_index]['public_key'] = public_key
    config['nodes'][target_index]['short_id'] = short_id

    with open(f'{SCRIPT_DIR}/config.yaml', 'w') as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

    print("[INFO] 已更新 config.yaml")

    print("\n" + "=" * 50)
    print(f"[INFO] 节点 {name} 部署完成!")
    print("=" * 50)

    # 检查还有哪些节点未部署
    undeployed = [n['name'] for n in config['nodes'] if not n.get('public_key')]
    if undeployed:
        print(f"\n待部署节点: {', '.join(undeployed)}")
        print(f"运行: ./deploy_node.sh <节点名>")
    else:
        print("\n所有节点已部署完成!")
        print("运行 ./sync_users.sh 同步用户")
else:
    print("[ERROR] 部署失败，无法获取密钥信息")
    print(result.stdout[-2000:] if len(result.stdout) > 2000 else result.stdout)
    sys.exit(1)
PYTHON_SCRIPT
