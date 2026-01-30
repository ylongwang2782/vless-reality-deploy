# VLESS + Reality 一键部署

一键部署 VLESS + Reality 代理服务器，支持 Cloudflare DNS 自动配置、SSL 证书和多用户管理。

## 功能特性

- **一键部署** - 自动安装 Xray、配置 VLESS + Reality
- **Cloudflare 集成** - 自动创建 DNS 记录、配置 SSL、启用代理隐藏真实 IP
- **订阅链接** - 生成 Clash Meta 兼容的 YAML 订阅链接
- **多用户管理** - 为不同用户生成独立的订阅链接
- **BBR 加速** - 自动开启 TCP BBR 拥塞控制

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/ylongwang2782/vless-reality-deploy.git
cd vless-reality-deploy
```

### 2. 配置

```bash
cp config.env.example config.env
```

编辑 `config.env`：

```bash
# VPS 配置
VPS_IP="你的VPS IP"
VPS_PASSWORD="你的VPS密码"
VPS_USER="root"

# Cloudflare 配置（可选）
CF_API_TOKEN="你的Cloudflare API Token"
CF_DOMAIN="你的域名"
CF_SUBDOMAIN="sub"

# 订阅端口
SUB_PORT="8443"

# 节点名称
NODE_NAME="My_Reality"
```

### 3. 部署

```bash
chmod +x deploy.sh
./deploy.sh
```

部署完成后会生成：
- `vless_link.txt` - VLESS 链接（用于 Shadowrocket、Hiddify 等）
- `clash_sub_url.txt` - Clash 订阅链接
- `vless_qr.png` - 二维码图片

## 添加用户

为朋友生成独立的订阅链接：

```bash
./add_user.sh <用户名> [流量限制GB] [重置日期]

# 示例：添加用户 friend，200GB/月，每月27号重置
./add_user.sh friend 200 27
```

## 客户端支持

### Clash Meta 内核
- Clash Verge
- Clash Verge Rev
- ClashX Meta
- Stash (iOS/macOS)

### 其他客户端
- Shadowrocket (iOS)
- Hiddify (全平台)
- v2rayN (Windows)
- v2rayNG (Android)

## 文件说明

| 文件 | 说明 |
|------|------|
| `deploy.sh` | 主部署脚本 |
| `install_vless.sh` | VPS 安装脚本 |
| `add_user.sh` | 添加用户脚本 |
| `config.env.example` | 配置模板 |
| `deploy_vless.exp` | Expect 部署脚本（旧版） |
| `fetch_logs.exp` | 日志获取脚本 |

## Cloudflare API Token

需要以下权限：
- Zone - DNS - Edit
- Zone - Zone - Read

创建方式：Cloudflare Dashboard → My Profile → API Tokens → Create Token

## 注意事项

- VPS 需要是全新的 Ubuntu 系统（推荐 22.04/24.04）
- 确保 VPS 的 443 和 8443 端口未被占用
- 部署前确保能 SSH 连接到 VPS

## License

MIT
