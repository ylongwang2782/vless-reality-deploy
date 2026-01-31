# VLESS + Reality 一键部署

一键部署 VLESS + Reality 代理服务器，支持多节点、Cloudflare DNS 自动配置、SSL 证书和多用户管理。

## 功能特性

- **一键部署** - 自动安装 Xray、配置 VLESS + Reality
- **多节点支持** - 单个订阅链接包含多个 VPS 节点，支持自动测速切换
- **Cloudflare 集成** - 自动创建 DNS 记录、配置 SSL、启用代理隐藏真实 IP
- **订阅链接** - 生成 Clash Meta 兼容的 YAML 订阅链接
- **多用户管理** - 通过 YAML 配置文件管理用户，每个用户独立订阅链接
- **客户端下载** - 内置下载服务，无需梯子即可下载客户端
- **BBR 加速** - 自动开启 TCP BBR 拥塞控制

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/ylongwang2782/vless-reality-deploy.git
cd vless-reality-deploy
```

### 2. 配置服务器

```bash
cp config.yaml.example config.yaml
```

编辑 `config.yaml`：

```yaml
# 主 VPS 配置（托管订阅服务）
main_vps:
  ip: "你的主VPS IP"
  user: "root"
  password: "你的密码"
  ssh_port: 22

# Cloudflare 配置（可选）
cloudflare:
  api_token: "你的 API Token"
  domain: "你的域名"
  subdomain: "sub"

# 订阅服务端口
sub_port: 8443

# 节点列表
nodes:
  # 主节点（部署在 main_vps 上）
  - name: "USA"
    type: "local"

  # 远程节点（可选，添加更多 VPS）
  - name: "Japan"
    type: "remote"
    server: "远程VPS IP"
    port: 443
    public_key: "节点公钥"
    short_id: "节点短ID"
    ssh:
      user: "root"
      password: "密码"
      port: 22
```

### 3. 配置用户

```bash
cp users.yaml.example users.yaml
```

编辑 `users.yaml`：

```yaml
users:
  - name: owner
    traffic_limit_gb: 0      # 0 表示无限制
    reset_day: 1

  - name: friend1
    traffic_limit_gb: 200    # 每月 200GB
    reset_day: 27
```

### 4. 部署

```bash
chmod +x deploy.sh sync_users.sh setup_downloads.sh
./deploy.sh
```

### 5. 设置客户端下载服务（可选）

```bash
./setup_downloads.sh
```

部署后用户可通过 `https://你的域名:8443/download` 下载客户端。

## 多节点管理

### 添加远程节点

1. 在远程 VPS 上运行 `./deploy.sh` 完成基础部署
2. 获取节点信息：
   ```bash
   # 在远程 VPS 上执行
   cat /usr/local/etc/xray/config.json | python3 -c "
   import sys,json
   c = json.load(sys.stdin)
   for i in c['inbounds']:
       if 'streamSettings' in i:
           rs = i['streamSettings']['realitySettings']
           print('private_key:', rs['privateKey'])
           print('short_id:', rs['shortIds'][0])
   "
   # 计算公钥
   /usr/local/bin/xray x25519 -i <private_key>
   ```
3. 将节点信息添加到 `config.yaml` 的 `nodes` 列表
4. 运行 `./sync_users.sh` 同步

### 同步用户到所有节点

```bash
./sync_users.sh
```

脚本会自动：
- 同步用户到所有配置了 SSH 的节点
- 生成包含所有节点的订阅配置
- 更新订阅服务

## 用户管理

| 字段 | 说明 |
|------|------|
| `name` | 用户名，用于生成订阅链接路径 |
| `traffic_limit_gb` | 流量限制（GB），0 表示无限制 |
| `reset_day` | 流量重置日期（1-28） |

## 客户端支持

### 推荐客户端
- **Windows**: Clash Verge Rev
- **macOS**: Clash Verge Rev / Stash
- **Android**: Clash Meta for Android
- **iOS**: Shadowrocket / Stash

### 其他支持的客户端
- Hiddify (全平台)
- v2rayN (Windows)
- v2rayNG (Android)

## 文件说明

| 文件 | 说明 |
|------|------|
| `deploy.sh` | 主部署脚本 |
| `sync_users.sh` | 多节点用户同步脚本 |
| `setup_downloads.sh` | 客户端下载服务部署 |
| `install_vless.sh` | VPS 安装脚本 |
| `config.yaml.example` | 多节点配置模板 |
| `users.yaml.example` | 用户配置模板 |

## Cloudflare API Token

需要以下权限：
- Zone - DNS - Edit
- Zone - Zone - Read
- Zone - Origin Rules - Edit（可选，用于端口转发）

创建方式：Cloudflare Dashboard → My Profile → API Tokens → Create Token

## 注意事项

- VPS 需要是全新的 Ubuntu 系统（推荐 22.04/24.04）
- 确保 VPS 的 443 和 8443 端口未被占用
- 部署前确保能 SSH 连接到 VPS
- `config.yaml` 和 `users.yaml` 包含敏感信息，请勿上传到公开仓库

## License

MIT
