# VLESS + Reality 多节点部署

一键部署 VLESS + Reality 代理服务器，支持多节点、自动配置、多用户管理。

## 功能特性

- **多节点支持** - 单个订阅链接包含多个 VPS 节点
- **一键部署** - 自动安装 Xray、生成密钥、配置服务
- **自动测速** - 客户端自动选择最快节点
- **Cloudflare 集成** - DNS 配置、SSL 证书、隐藏真实 IP
- **多用户管理** - 独立订阅链接、流量限制
- **客户端下载** - 内置下载服务，无需梯子

## 部署流程

```
┌─────────────────────────────────────────────────────────┐
│  1. 配置 config.yaml                                    │
│     - 填写所有 VPS 的 SSH 信息                           │
│     - 配置 Cloudflare（可选）                            │
└─────────────────────┬───────────────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────────────┐
│  2. ./deploy.sh                                         │
│     - 部署主节点（第一个节点）                            │
│     - 自动获取密钥并更新 config.yaml                     │
│     - 配置 Cloudflare DNS                               │
└─────────────────────┬───────────────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────────────┐
│  3. ./deploy_node.sh <节点名>                           │
│     - 部署其他远程节点                                   │
│     - 自动获取密钥并更新 config.yaml                     │
└─────────────────────┬───────────────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────────────┐
│  4. ./sync_users.sh                                     │
│     - 同步用户到所有节点                                 │
│     - 启动订阅服务                                       │
│     - 生成订阅链接                                       │
└─────────────────────┬───────────────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────────────┐
│  5. ./setup_downloads.sh（可选）                        │
│     - 设置客户端下载服务                                 │
└─────────────────────────────────────────────────────────┘
```

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/ylongwang2782/vless-reality-deploy.git
cd vless-reality-deploy
```

### 2. 配置文件

```bash
cp config.yaml.example config.yaml
cp users.yaml.example users.yaml
```

编辑 `config.yaml`：

```yaml
# Cloudflare 配置（推荐）
cloudflare:
  api_token: "your_token"
  domain: "example.com"
  subdomain: "sub"

sub_port: 8443

# 节点列表（第一个为主节点）
nodes:
  - name: "HK"           # 香港 - 主节点
    server: "1.2.3.4"
    port: 443
    ssh:
      user: "root"
      password: "password"
      port: 22
    public_key: ""       # 部署后自动填充
    short_id: ""

  - name: "USA"          # 美国
    server: "5.6.7.8"
    port: 443
    ssh:
      user: "root"
      password: "password"
      port: 22
    public_key: ""
    short_id: ""
```

编辑 `users.yaml`：

```yaml
users:
  - name: myself
    traffic_limit_gb: 0    # 0 = 无限制
    reset_day: 1

  - name: friend1
    traffic_limit_gb: 100  # 100GB/月
    reset_day: 1
```

### 3. 部署节点

```bash
# 部署主节点
./deploy.sh

# 部署其他节点
./deploy_node.sh USA
./deploy_node.sh NL
# ...

# 查看节点状态
./deploy_node.sh
```

### 4. 同步用户

```bash
./sync_users.sh
```

### 5. 设置客户端下载（可选）

```bash
./setup_downloads.sh
```

## 日常管理

### 添加用户

1. 编辑 `users.yaml` 添加用户
2. 运行 `./sync_users.sh`

### 添加节点

1. 编辑 `config.yaml` 添加节点配置
2. 运行 `./deploy_node.sh <节点名>`
3. 运行 `./sync_users.sh`

### 查看订阅链接

```bash
cat subscriptions.txt
```

## 客户端推荐

| 平台 | 推荐客户端 |
|------|-----------|
| Windows | Clash Verge Rev |
| macOS | Clash Verge Rev / Stash |
| Android | Clash Meta for Android |
| iOS | Shadowrocket / Stash |

## 文件说明

| 文件 | 说明 |
|------|------|
| `deploy.sh` | 部署主节点 |
| `deploy_node.sh` | 部署远程节点 |
| `sync_users.sh` | 同步用户 + 更新订阅服务 |
| `setup_downloads.sh` | 设置客户端下载 |
| `config.yaml` | 节点配置（敏感） |
| `users.yaml` | 用户配置（敏感） |
| `subscriptions.txt` | 生成的订阅链接 |

## 注意事项

- VPS 需要 Ubuntu 22.04/24.04
- 确保 443 和 8443 端口可用
- `config.yaml` 和 `users.yaml` 包含敏感信息，勿公开

## Cloudflare API Token

需要权限：
- Zone - DNS - Edit
- Zone - Zone - Read

创建：Cloudflare Dashboard → My Profile → API Tokens

## License

MIT
