#!/bin/bash

# ==========================================
# 客户端下载服务部署脚本
# 在服务器上提供代理客户端下载
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"

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
    log_error "config.yaml 不存在"
    exit 1
fi

source "$SCRIPT_DIR/config.sh"
if ! load_config "$NODE_ID"; then
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no"

log_info "=========================================="
log_info "部署客户端下载服务"
log_info "=========================================="
log_info "VPS: $VPS_IP"
log_info "SSH Host: $SSH_HOST"

# 客户端下载链接
CLASH_VERGE_URL="https://github.com/clash-verge-rev/clash-verge-rev/releases/download/v2.4.5/Clash.Verge_2.4.5_x64-setup.exe"
CLASH_ANDROID_URL="https://github.com/MetaCubeX/ClashMetaForAndroid/releases/download/v2.11.22/cmfa-2.11.22-meta-universal-release.apk"

# 生成远程安装脚本
cat > /tmp/setup_downloads_remote.sh << 'REMOTE_EOF'
#!/bin/bash

DOWNLOAD_DIR="/var/www/downloads"
mkdir -p "$DOWNLOAD_DIR"

echo "[INFO] 下载 Clash Verge (Windows)..."
curl -L -o "$DOWNLOAD_DIR/Clash.Verge_2.4.5_x64-setup.exe" \
    "https://github.com/clash-verge-rev/clash-verge-rev/releases/download/v2.4.5/Clash.Verge_2.4.5_x64-setup.exe" \
    --progress-bar

echo "[INFO] 下载 Clash Meta (Android)..."
curl -L -o "$DOWNLOAD_DIR/cmfa-2.11.22-meta-universal-release.apk" \
    "https://github.com/MetaCubeX/ClashMetaForAndroid/releases/download/v2.11.22/cmfa-2.11.22-meta-universal-release.apk" \
    --progress-bar

# 创建下载页面
cat > "$DOWNLOAD_DIR/index.html" << 'HTML_EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>客户端下载</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 20px;
        }
        .container {
            background: white;
            border-radius: 20px;
            padding: 40px;
            max-width: 500px;
            width: 100%;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
        }
        h1 {
            text-align: center;
            color: #333;
            margin-bottom: 30px;
            font-size: 24px;
        }
        .download-item {
            display: flex;
            align-items: center;
            padding: 20px;
            background: #f8f9fa;
            border-radius: 12px;
            margin-bottom: 15px;
            transition: transform 0.2s, box-shadow 0.2s;
        }
        .download-item:hover {
            transform: translateY(-2px);
            box-shadow: 0 5px 20px rgba(0,0,0,0.1);
        }
        .icon {
            font-size: 40px;
            margin-right: 20px;
        }
        .info { flex: 1; }
        .info h3 {
            color: #333;
            margin-bottom: 5px;
            font-size: 18px;
        }
        .info p {
            color: #666;
            font-size: 14px;
        }
        .download-btn {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 8px;
            cursor: pointer;
            font-size: 14px;
            text-decoration: none;
            transition: opacity 0.2s;
        }
        .download-btn:hover { opacity: 0.9; }
        .note {
            margin-top: 25px;
            padding: 15px;
            background: #fff3cd;
            border-radius: 8px;
            font-size: 13px;
            color: #856404;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>代理客户端下载</h1>

        <div class="download-item">
            <div class="icon">🖥️</div>
            <div class="info">
                <h3>Clash Verge</h3>
                <p>Windows 客户端 (v2.4.5)</p>
            </div>
            <a href="Clash.Verge_2.4.5_x64-setup.exe" class="download-btn">下载</a>
        </div>

        <div class="download-item">
            <div class="icon">📱</div>
            <div class="info">
                <h3>Clash Meta</h3>
                <p>Android 客户端 (v2.11.22)</p>
            </div>
            <a href="cmfa-2.11.22-meta-universal-release.apk" class="download-btn">下载</a>
        </div>

        <div class="note">
            <strong>使用说明：</strong><br>
            1. 下载并安装对应平台的客户端<br>
            2. 复制你的订阅链接<br>
            3. 在客户端中导入订阅<br>
            4. 选择节点并连接
        </div>
    </div>
</body>
</html>
HTML_EOF

echo "[INFO] 文件下载完成"
ls -lh "$DOWNLOAD_DIR"

# 更新订阅服务，添加下载功能
ROUTES_FILE="/var/www/sub/routes.json"
if [ -f "$ROUTES_FILE" ]; then
    python3 << 'PY_EOF'
import json

routes_file = "/var/www/sub/routes.json"
with open(routes_file, 'r') as f:
    routes = json.load(f)

# 添加下载路由标记
routes['__downloads__'] = {
    'type': 'downloads',
    'path': '/var/www/downloads'
}

with open(routes_file, 'w') as f:
    json.dump(routes, f, indent=2)

print("[INFO] Routes updated")
PY_EOF
fi

# 更新订阅服务代码，支持下载功能
cat > /var/www/sub/sub_server.py << 'PY_SUB_EOF'
#!/usr/bin/env python3
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

class SubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # 静默日志

    def do_HEAD(self):
        self._handle_request(head_only=True)

    def do_GET(self):
        self._handle_request(head_only=False)

    def _handle_request(self, head_only=False):
        path = unquote(urlparse(self.path).path).strip('/')

        # 处理下载请求
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

        # 跳过特殊路由
        if route.get('type') == 'downloads':
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
                total = traffic_limit_gb * 1024 * 1024 * 1024

            upload = user_config.get('upload_bytes', 0)
            download = user_config.get('download_bytes', 0)

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

        if total > 0:
            userinfo = f"upload={upload}; download={download}; total={total}"
            if expire > 0:
                userinfo += f"; expire={expire}"
            self.send_header('subscription-userinfo', userinfo)

        self.end_headers()
        if not head_only:
            self.wfile.write(yaml_content.encode('utf-8'))

    def _handle_download(self, path, head_only):
        # 移除 'download' 或 'download/' 前缀
        if path == 'download' or path == 'download/':
            # 返回下载页面
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

        # 获取文件名
        filename = path[len('download/'):]
        filepath = os.path.join(DOWNLOAD_DIR, filename)

        # 安全检查：防止路径遍历
        if '..' in filename or not os.path.abspath(filepath).startswith(DOWNLOAD_DIR):
            self.send_error(403, "Forbidden")
            return

        if not os.path.isfile(filepath):
            self.send_error(404, "Not Found")
            return

        # 获取文件大小和类型
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
                # 分块发送大文件
                while True:
                    chunk = f.read(65536)  # 64KB chunks
                    if not chunk:
                        break
                    self.wfile.write(chunk)

def run_server(port, use_ssl=False):
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
PY_SUB_EOF

chmod 755 /var/www/sub/sub_server.py

# 重启订阅服务
echo "[INFO] 重启订阅服务..."
systemctl restart sub-server
sleep 2

if [ "$(systemctl is-active sub-server)" = "active" ]; then
    echo "[INFO] 服务启动成功"
else
    echo "[ERROR] 服务启动失败"
    systemctl status sub-server
    exit 1
fi

echo ""
echo "================================================================"
echo "   下载服务部署完成！"
echo "================================================================"
REMOTE_EOF

log_info "上传并执行安装脚本..."

scp $SSH_OPTS /tmp/setup_downloads_remote.sh "$SSH_HOST:/tmp/"
ssh $SSH_OPTS "$SSH_HOST" "chmod +x /tmp/setup_downloads_remote.sh && /tmp/setup_downloads_remote.sh && rm -f /tmp/setup_downloads_remote.sh"

# 生成下载链接
if [ -n "$CF_SUBDOMAIN" ] && [ -n "$CF_DOMAIN" ]; then
    DOWNLOAD_URL="https://$CF_SUBDOMAIN.$CF_DOMAIN:$SUB_PORT/download"
else
    DOWNLOAD_URL="http://$VPS_IP:$SUB_PORT/download"
fi

echo ""
log_info "=========================================="
log_info "下载服务部署完成！"
log_info "=========================================="
echo ""
log_info "下载页面: $DOWNLOAD_URL"
log_info ""
log_info "直接下载链接:"
log_info "  Windows: $DOWNLOAD_URL/Clash.Verge_2.4.5_x64-setup.exe"
log_info "  Android: $DOWNLOAD_URL/cmfa-2.11.22-meta-universal-release.apk"
log_info "=========================================="

# 保存下载链接到文件
cat > "$SCRIPT_DIR/download_links.txt" << LINKS
下载页面: $DOWNLOAD_URL

Windows: $DOWNLOAD_URL/Clash.Verge_2.4.5_x64-setup.exe
Android: $DOWNLOAD_URL/cmfa-2.11.22-meta-universal-release.apk
LINKS

log_info "下载链接已保存到: $SCRIPT_DIR/download_links.txt"
