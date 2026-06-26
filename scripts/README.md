# deploy_web.sh 使用说明

本项目提供了一个通用静态网页自动部署脚本：

- 脚本：`scripts/deploy_web.sh`
- 配置模板：`scripts/deploy_web.conf.example`
- 当前配置：`scripts/deploy_web.conf`

适用场景：把本地静态网页目录发布到阿里云 ECS（Nginx），支持多域名站点、可选 HTTPS 自动化。

## 功能概览

- 通过配置文件部署。
- 支持任意站点：
  - 任意域名（如 `demo.kokopal.com`）
  - 任意本地目录（如 `demo-site`）
  - 任意远程目录（如 `/usr/share/nginx/demo`）
- 自动上传文件：
  - 优先 `rsync`（远端有 rsync）
  - 自动降级为 `tar | ssh tar`（远端无 rsync）
- 自动写入 Nginx 站点配置（`confd` 模式默认）。
- 自动校验并重启 Nginx（`nginx -t` + `systemctl restart nginx`）。
- 自动部署后自检（检查 `nginx -T` 是否命中 `server_name` 和 `root`）。
- 可选 HTTPS 自动化：
  - `certbot certonly --webroot` 申请证书
  - 自动写入 443 配置
  - 可选 HTTP -> HTTPS 跳转
  - 本机 HTTPS 自检

## 执行流程

按一次部署的实际顺序：

1. 检查本地静态文件目录。
2. 检查 SSH 认证与连通性。
3. 创建远程目录。
4. 上传静态文件（rsync 或 tar 降级）。
5. 修正远程目录权限。
6. 更新 Nginx 配置并重启。
7. 自检 Nginx 生效配置命中。
8. （可选）申请 HTTPS 证书并切换到 443 配置，自检 HTTPS。

## 配置说明

编辑 `scripts/deploy_web.conf`：

```bash
# 必填
HOST="服务器ip"
DOMAIN="demo.kokopal.com"
LOCAL_DIR="demo-site"
REMOTE_DIR="/usr/share/nginx/demo"

# 可选
USER="root"
PORT="22"
SSH_KEY="/xxx/xxx/kokopal-website/scripts/web-deploy.pem"
SSH_EXTRA_OPTS=""
SITE_NAME=""
NGINX_MODE="confd"
SKIP_NGINX_CONFIG="false"
DRY_RUN="false"
ENSURE_CONFD_INCLUDE="true"
ENABLE_HTTPS="true"
CERTBOT_EMAIL="自己的邮箱"
HTTPS_REDIRECT="true"
```

字段解释：

- `HOST`：服务器公网 IP 或域名。
- `DOMAIN`：站点访问域名。
- `LOCAL_DIR`：本地待部署静态文件目录。
- `REMOTE_DIR`：服务器网页目录。
- `USER` / `PORT`：SSH 登录用户和端口。
- `SSH_KEY`：SSH 私钥绝对路径。
- `SSH_EXTRA_OPTS`：额外 SSH 参数（如跳板机）。
- `SITE_NAME`：站点名，默认从 `DOMAIN` 自动推导，用于 conf 文件名。
- `NGINX_MODE`：
  - `confd`：写入 `/etc/nginx/conf.d/<site>.conf`（推荐）
  - `full`：覆盖 `/etc/nginx/nginx.conf`（谨慎）
- `SKIP_NGINX_CONFIG=true`：只上传文件，不改 Nginx。
- `DRY_RUN=true`：只打印命令，不执行。
- `ENSURE_CONFD_INCLUDE=true`：自动确保 `nginx.conf` 加载 `conf.d`。
- `ENABLE_HTTPS=true`：启用证书申请和 HTTPS 配置。
- `CERTBOT_EMAIL`：Certbot 邮箱，建议填写。
- `HTTPS_REDIRECT=true`：HTTP 自动 301 到 HTTPS。

## 运行方式

### 1) 标准运行（推荐）

```bash
cd /xxx/xxx/kokopal-website
scripts/deploy_web.sh --config scripts/deploy_web.conf
```

### 2) 预演模式（不执行）

```bash
scripts/deploy_web.sh --config scripts/deploy_web.conf --dry-run
```

### 3) 命令行参数覆盖配置文件

```bash
scripts/deploy_web.sh \
  --config scripts/deploy_web.conf \
  --domain test.kokopal.com \
  --local-dir demo-site \
  --remote-dir /usr/share/nginx/test
```

## HTTPS 使用建议

启用 HTTPS 前请确认：

- 域名已解析到当前 ECS 公网 IP。
- 安全组已放行 `80/443`。
- 服务器防火墙已放行 `80/443`（如启用 firewalld）。

推荐配置：

```bash
ENABLE_HTTPS="true"
CERTBOT_EMAIL="your-email@example.com"
HTTPS_REDIRECT="true"
```

## 常见问题

### 1) `Permission denied (publickey,...)`

SSH 认证失败。检查：

- `USER` 是否正确（不一定是 `root`）。
- `SSH_KEY` 路径是否正确。
- 私钥权限是否为 `600`：

```bash
chmod 600 /path/to/your-key.pem
```

### 2) 远端提示 `rsync: 未找到命令`

已内置自动降级为 `tar` 传输，无需手工安装 rsync。

### 3) 访问域名命中主站而不是新站

脚本已内置自检与 `conf.d` include 修复。仍异常时重点检查：

- `DOMAIN` 是否解析到正确 IP。
- 远端是否存在同名冲突 `server_name` 配置。

## 安全建议

- `scripts/deploy_web.conf` 包含服务器和密钥路径信息，建议不要提交真实生产配置到公共仓库。
- 推荐提交 `deploy_web.conf.example`，生产用 `deploy_web.conf` 放在私有环境。
