# VLESS + Reality 一键部署

一键部署 VLESS + Reality 代理服务器，支持 Cloudflare DNS 自动配置、SSL 证书和多用户管理。

## 功能特性

- **一键部署** - 自动安装 Xray、配置 VLESS + Reality
- **Cloudflare 集成** - 自动创建 DNS 记录、配置 SSL、启用代理隐藏真实 IP
- **订阅链接** - 生成 Clash Meta 兼容的 YAML 订阅链接
- **多用户管理** - 通过 YAML 配置文件管理用户，每个用户独立订阅链接
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
default_node: usa

cloudflare:
  api_token: "你的Cloudflare API Token"
  domain: "你的域名"

nodes:
  usa:
    name: "USA"
    ip: "你的VPS IP"
    ssh_host: "bwg-usa"
    subdomain: "sub"
    sub_port: 8443
  nl:
    name: "NL"
    ip: "你的VPS IP"
    ssh_host: "vultr-nl"
    subdomain: "nether"
    sub_port: 8443
```

说明：
- `ssh_host` 是 `~/.ssh/config` 中配置的主机别名（使用密钥登录）
- `default_node` 为默认节点，可通过 `--node <node_id>` 覆盖

### 3. 配置用户（可选）

```bash
cp users.yaml.example users.yaml
```

编辑 `users.yaml`：

```yaml
users:
  # 主用户（你自己）
  - name: owner
    traffic_limit_gb: 0      # 0 表示无限制
    reset_day: 1

  # 朋友1
  - name: friend1
    traffic_limit_gb: 200    # 每月 200GB
    reset_day: 27            # 每月 27 号重置

  # 朋友2
  - name: friend2
    traffic_limit_gb: 100
    reset_day: 1
```

### 4. 部署

```bash
chmod +x deploy.sh sync_users.sh
./deploy.sh
```

指定节点（可选）：
```bash
./deploy.sh --node usa
```

部署完成后，每个用户的链接保存在 `user_links/` 目录：
```
user_links/
├── owner_vless.txt    # owner 的 VLESS 链接
├── owner_sub.txt      # owner 的订阅链接
├── friend1_vless.txt
├── friend1_sub.txt
└── ...
```

## 用户管理

### 添加/修改用户

1. 编辑 `users.yaml` 添加或修改用户
2. 运行 `./sync_users.sh` 同步到服务器

```bash
./sync_users.sh
```

多节点场景（可选）：
```bash
./sync_users.sh --node nl
./add_user.sh owner 0 1 --node nl
```

### 用户配置说明

| 字段 | 说明 |
|------|------|
| `name` | 用户名，用于生成订阅链接 |
| `traffic_limit_gb` | 流量限制（GB），0 表示无限制 |
| `reset_day` | 流量重置日期（1-28） |

## 客户端支持

### Clash Meta 内核
- Clash Verge / Clash Verge Rev
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
| `sync_users.sh` | 用户同步脚本 |
| `install_vless.sh` | VPS 安装脚本 |
| `config.yaml.example` | 服务器配置模板 |
| `users.yaml.example` | 用户配置模板 |

## Cloudflare API Token

需要以下权限：
- Zone - DNS - Edit
- Zone - Zone - Read

创建方式：Cloudflare Dashboard → My Profile → API Tokens → Create Token

## 注意事项

- VPS 需要是全新的 Ubuntu 系统（推荐 22.04/24.04）
- 确保 VPS 的 443 和 8443 端口未被占用
- 部署前确保能 SSH 连接到 VPS（使用密钥登录，并配置 `~/.ssh/config` 的主机别名）
- `config.yaml` 和 `users.yaml` 包含敏感信息，请勿上传到公开仓库

## License

MIT
