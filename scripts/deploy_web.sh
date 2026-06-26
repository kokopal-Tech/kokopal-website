#!/usr/bin/env bash
set -euo pipefail

# 通用静态网页部署脚本（Nginx）
# 示例（推荐配置文件模式）：
#   scripts/deploy_web.sh --config scripts/deploy_web.conf
# 也支持命令行参数覆盖配置文件

HOST=""
USER="root"
PORT="22"
SSH_KEY=""
SSH_EXTRA_OPTS=""
DOMAIN=""
ALT_DOMAINS=""
LOCAL_DIR=""
REMOTE_DIR=""
SITE_NAME=""
DRY_RUN="false"
SKIP_NGINX_CONFIG="false"
ENSURE_CONFD_INCLUDE="true"
ENABLE_HTTPS="false"
CERTBOT_EMAIL=""
HTTPS_REDIRECT="true"

# nginx 配置策略：
# confd: 仅写入 /etc/nginx/conf.d/<site>.conf（默认，推荐）
# full: 覆盖 /etc/nginx/nginx.conf（兼容旧流程）
NGINX_MODE="confd"
CONFIG_FILE=""

usage() {
  cat <<USAGE
Usage:
  $0 --config <配置文件> [options]
  $0 --host <服务器IP或域名> --domain <域名> --local-dir <本地目录> --remote-dir <远程目录> [options]

Required:
  --config <value>              配置文件路径（推荐）
  或同时提供:
  --host / --domain / --local-dir / --remote-dir

Options:
  --user <value>                SSH 用户名 (default: root)
  --port <value>                SSH 端口 (default: 22)
  --site-name <value>           站点标识，用于 conf 文件名 (default: 从 domain 推导)
  --ssh-key <value>             SSH 私钥路径，如 ~/.ssh/id_rsa
  --ssh-extra-opts <value>      额外 SSH 参数，如 "-o ProxyJump=bastion"
  --alt-domains <value>         附加域名，空格分隔，如 "www.example.com m.example.com"
  --nginx-mode <confd|full>     Nginx 配置方式 (default: confd)
  --skip-nginx-config           仅上传文件，不改 Nginx 配置
  --ensure-confd-include <true|false>
                                confd 模式下自动确保 nginx.conf 加载 conf.d (default: true)
  --enable-https <true|false>   自动申请/配置 HTTPS (default: false)
  --certbot-email <value>       申请证书使用邮箱（enable-https=true 时建议填写）
  --https-redirect <true|false> HTTP 自动跳转 HTTPS (default: true)
  --dry-run                     仅打印将执行命令
  -h, --help                    显示帮助

Notes:
  1) confd 模式不会覆盖主 nginx.conf，更适合多站点。
  2) full 模式会覆盖 /etc/nginx/nginx.conf，请谨慎使用。
USAGE
}

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err() { echo "[ERROR] $*" >&2; }

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] $*"
  else
    eval "$@"
  fi
}

sanitize_site_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g'
}

load_config() {
  local cfg="$1"
  if [[ ! -f "$cfg" ]]; then
    err "Config file not found: $cfg"
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$cfg"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="$2"; shift 2 ;;
    --host)
      HOST="$2"; shift 2 ;;
    --user)
      USER="$2"; shift 2 ;;
    --port)
      PORT="$2"; shift 2 ;;
    --domain)
      DOMAIN="$2"; shift 2 ;;
    --alt-domains)
      ALT_DOMAINS="$2"; shift 2 ;;
    --local-dir)
      LOCAL_DIR="$2"; shift 2 ;;
    --remote-dir)
      REMOTE_DIR="$2"; shift 2 ;;
    --site-name)
      SITE_NAME="$2"; shift 2 ;;
    --ssh-key)
      SSH_KEY="$2"; shift 2 ;;
    --ssh-extra-opts)
      SSH_EXTRA_OPTS="$2"; shift 2 ;;
    --nginx-mode)
      NGINX_MODE="$2"; shift 2 ;;
    --skip-nginx-config)
      SKIP_NGINX_CONFIG="true"; shift ;;
    --ensure-confd-include)
      ENSURE_CONFD_INCLUDE="$2"; shift 2 ;;
    --enable-https)
      ENABLE_HTTPS="$2"; shift 2 ;;
    --certbot-email)
      CERTBOT_EMAIL="$2"; shift 2 ;;
    --https-redirect)
      HTTPS_REDIRECT="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN="true"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 1 ;;
  esac
done

if [[ -n "$CONFIG_FILE" ]]; then
  load_config "$CONFIG_FILE"
fi

if [[ -z "$HOST" || -z "$DOMAIN" || -z "$LOCAL_DIR" || -z "$REMOTE_DIR" ]]; then
  err "missing required fields: host/domain/local_dir/remote_dir"
  err "use --config scripts/deploy_web.conf or pass all required flags"
  usage
  exit 1
fi

if [[ ! -d "$LOCAL_DIR" ]]; then
  err "Local dir not found: $LOCAL_DIR"
  exit 1
fi

if [[ "$NGINX_MODE" != "confd" && "$NGINX_MODE" != "full" ]]; then
  err "--nginx-mode must be one of: confd, full"
  exit 1
fi
if [[ "$ENSURE_CONFD_INCLUDE" != "true" && "$ENSURE_CONFD_INCLUDE" != "false" ]]; then
  err "--ensure-confd-include must be true or false"
  exit 1
fi
if [[ "$ENABLE_HTTPS" != "true" && "$ENABLE_HTTPS" != "false" ]]; then
  err "--enable-https must be true or false"
  exit 1
fi
if [[ "$HTTPS_REDIRECT" != "true" && "$HTTPS_REDIRECT" != "false" ]]; then
  err "--https-redirect must be true or false"
  exit 1
fi

if [[ -z "$SITE_NAME" ]]; then
  SITE_NAME="$(sanitize_site_name "$DOMAIN")"
fi

ALL_DOMAINS=("$DOMAIN")
if [[ -n "$ALT_DOMAINS" ]]; then
  read -r -a ALT_DOMAIN_LIST <<< "$ALT_DOMAINS"
  for alt_domain in "${ALT_DOMAIN_LIST[@]}"; do
    if [[ -n "$alt_domain" ]]; then
      ALL_DOMAINS+=("$alt_domain")
    fi
  done
fi

ALIAS_SERVER_NAMES=""
if [[ ${#ALL_DOMAINS[@]} -gt 1 ]]; then
  for ((i=1; i<${#ALL_DOMAINS[@]}; i++)); do
    if [[ -n "$ALIAS_SERVER_NAMES" ]]; then
      ALIAS_SERVER_NAMES="${ALIAS_SERVER_NAMES} ${ALL_DOMAINS[$i]}"
    else
      ALIAS_SERVER_NAMES="${ALL_DOMAINS[$i]}"
    fi
  done
fi

SSH_OPTS="-p ${PORT} -o StrictHostKeyChecking=accept-new"
if [[ -n "$SSH_KEY" ]]; then
  SSH_OPTS="${SSH_OPTS} -i ${SSH_KEY}"
fi
if [[ -n "$SSH_EXTRA_OPTS" ]]; then
  SSH_OPTS="${SSH_OPTS} ${SSH_EXTRA_OPTS}"
fi
REMOTE="${USER}@${HOST}"
CONF_PATH="/etc/nginx/conf.d/${SITE_NAME}.conf"

log "Step 1/5: 检查本地目录"
run_cmd "find '$LOCAL_DIR' -maxdepth 2 -type f | head"

log "Step 2/5: 检查 SSH 连通与认证"
run_cmd "ssh $SSH_OPTS '$REMOTE' 'echo \"ssh auth ok\"'"

log "Step 2.5/5: 创建远程目录"
run_cmd "ssh $SSH_OPTS '$REMOTE' 'mkdir -p \"$REMOTE_DIR\"'"

log "Step 3/5: 上传静态文件"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY RUN] 检查远端 rsync，存在则 rsync 上传，否则 tar 管道上传"
else
  if ssh $SSH_OPTS "$REMOTE" "command -v rsync >/dev/null 2>&1"; then
    rsync -avz --delete -e "ssh $SSH_OPTS" "$LOCAL_DIR/" "$REMOTE:$REMOTE_DIR/"
  else
    warn "远端未安装 rsync，自动降级为 tar 管道上传"
    # 先清空远端目录内容，确保与本地一致（等价于 rsync --delete）
    ssh $SSH_OPTS "$REMOTE" "find \"$REMOTE_DIR\" -mindepth 1 -maxdepth 1 -exec rm -rf {} +"
    tar -C "$LOCAL_DIR" -cf - . | ssh $SSH_OPTS "$REMOTE" "tar -C \"$REMOTE_DIR\" -xf -"
  fi
fi

log "Step 4/5: 修正远程目录权限"
run_cmd "ssh $SSH_OPTS '$REMOTE' 'chmod -R 755 \"$REMOTE_DIR\"'"

if [[ "$SKIP_NGINX_CONFIG" == "false" ]]; then
  log "Step 5/5: 更新 Nginx 配置并重载"
  if [[ "$NGINX_MODE" == "confd" ]]; then
    if [[ "$ENSURE_CONFD_INCLUDE" == "true" ]]; then
      log "Step 5.0/5: 检查并修复 nginx.conf 对 conf.d 的 include"
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] 若 /etc/nginx/nginx.conf 缺少 include /etc/nginx/conf.d/*.conf; 则自动插入"
      else
        ssh $SSH_OPTS "$REMOTE" "bash -s" <<'EOF'
set -euo pipefail
CONF_FILE="/etc/nginx/nginx.conf"
INCLUDE_LINE="include /etc/nginx/conf.d/*.conf;"
if grep -F "$INCLUDE_LINE" "$CONF_FILE" >/dev/null 2>&1; then
  echo "[INFO] nginx.conf 已包含 conf.d include"
else
  cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  awk -v include_line="$INCLUDE_LINE" '
    BEGIN { inserted=0 }
    {
      print $0
      if (!inserted && $0 ~ /default_type[[:space:]]+application\/octet-stream;/) {
        print "  " include_line
        inserted=1
      }
    }
  ' "$CONF_FILE" > "${CONF_FILE}.tmp"
  mv "${CONF_FILE}.tmp" "$CONF_FILE"
  echo "[INFO] 已向 nginx.conf 注入 conf.d include"
fi
EOF
      fi
    fi

    SITE_CONF=$(cat <<CONF
server {
  listen 80;
  server_name ${DOMAIN}${ALIAS_SERVER_NAMES:+ ${ALIAS_SERVER_NAMES}};
  root ${REMOTE_DIR};
  index index.html;

  location / {
    try_files \$uri \$uri/ /index.html;
  }
}
CONF
)
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY RUN] 将写入 ${CONF_PATH}"
      echo "[DRY RUN] 之后执行 nginx -t && systemctl restart nginx"
    else
      ssh $SSH_OPTS "$REMOTE" "cat > ${CONF_PATH} <<'EOF_SITE_CONF'
$SITE_CONF
EOF_SITE_CONF"
      ssh $SSH_OPTS "$REMOTE" "nginx -t"
      ssh $SSH_OPTS "$REMOTE" "systemctl restart nginx"
    fi
  else
    FULL_CONF=$(cat <<CONF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;

events {
  worker_connections 1024;
}

http {
  log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                  '\$status \$body_bytes_sent "\$http_referer" '
                  '"\$http_user_agent" "\$http_x_forwarded_for"';
  access_log /var/log/nginx/access.log main;
  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 65;
  types_hash_max_size 4096;
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  include /etc/nginx/conf.d/*.conf;

  server {
    listen 80;
    server_name ${DOMAIN}${ALIAS_SERVER_NAMES:+ ${ALIAS_SERVER_NAMES}};
    root ${REMOTE_DIR};
    index index.html;
  }
}
CONF
)
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY RUN] 将覆盖 /etc/nginx/nginx.conf"
      echo "[DRY RUN] 之后执行 nginx -t && systemctl restart nginx"
    else
      ssh $SSH_OPTS "$REMOTE" "cat > /etc/nginx/nginx.conf <<'EOF_NGINX'
$FULL_CONF
EOF_NGINX"
      ssh $SSH_OPTS "$REMOTE" "nginx -t"
      ssh $SSH_OPTS "$REMOTE" "systemctl restart nginx"
    fi
  fi
else
  warn "已跳过 Nginx 配置更新（--skip-nginx-config）"
fi

log "Step 5.5/5: 部署后自检（Nginx 配置命中）"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY RUN] 将在远端执行 nginx -T 并校验 server_name/root 是否包含目标站点"
else
  CHECK_CMD=$(cat <<'EOF'
set -e
OUT="$(nginx -T 2>/dev/null || true)"
if [[ -z "$OUT" ]]; then
  echo "[ERROR] nginx -T 无输出，无法完成自检"
  exit 1
fi
echo "$OUT" | grep -F "server_name __DOMAIN__" >/dev/null || {
  echo "[ERROR] 未在 nginx 生效配置中找到 server_name __DOMAIN__"
  exit 1
}
if [[ -n "__ALIAS_SERVER_NAMES__" ]]; then
  echo "$OUT" | grep -F "server_name __DOMAIN__ __ALIAS_SERVER_NAMES__" >/dev/null || {
    echo "[ERROR] 未在 nginx 生效配置中找到 server_name __DOMAIN__ __ALIAS_SERVER_NAMES__"
    exit 1
  }
fi
echo "$OUT" | grep -F "root __REMOTE_DIR__;" >/dev/null || {
  echo "[ERROR] 未在 nginx 生效配置中找到 root __REMOTE_DIR__;"
  exit 1
}
echo "[INFO] 自检通过：已命中 __DOMAIN__ -> __REMOTE_DIR__"
EOF
)
  CHECK_CMD="${CHECK_CMD//__DOMAIN__/$DOMAIN}"
  CHECK_CMD="${CHECK_CMD//__REMOTE_DIR__/$REMOTE_DIR}"
  CHECK_CMD="${CHECK_CMD//__ALIAS_SERVER_NAMES__/$ALIAS_SERVER_NAMES}"
  ssh $SSH_OPTS "$REMOTE" "$CHECK_CMD"
fi

if [[ "$ENABLE_HTTPS" == "true" ]]; then
  log "Step 6/6: 配置 HTTPS（Certbot + Nginx）"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] 将安装 certbot（如缺失）、申请证书并写入 HTTPS 配置"
  else
    HTTPS_CMD=$(cat <<'EOF'
set -euo pipefail
domain="__DOMAIN__"
root_dir="__REMOTE_DIR__"
conf_path="__CONF_PATH__"
email="__CERTBOT_EMAIL__"
alias_domains="__ALIAS_SERVER_NAMES__"

if ! command -v certbot >/dev/null 2>&1; then
  (dnf install -y certbot || yum install -y certbot) >/dev/null
fi

certbot_args=(certbot certonly --webroot -w "$root_dir" --cert-name "$domain" --expand -d "$domain")
if [[ -n "$alias_domains" ]]; then
  read -r -a alias_domain_list <<< "$alias_domains"
  for alias_domain in "${alias_domain_list[@]}"; do
    certbot_args+=(-d "$alias_domain")
  done
fi
if [[ -n "$email" ]]; then
  certbot_args+=(--agree-tos --email "$email" --non-interactive)
else
  certbot_args+=(--agree-tos --register-unsafely-without-email --non-interactive)
fi
"${certbot_args[@]}" || true

if [[ ! -f "/etc/letsencrypt/live/${domain}/fullchain.pem" || ! -f "/etc/letsencrypt/live/${domain}/privkey.pem" ]]; then
  echo "[WARN] HTTPS 证书未就绪，保留 HTTP 配置不切换"
  exit 0
fi

cat > "$conf_path" <<CONF
server {
  listen 80;
  server_name ${domain}${alias_domains:+ ${alias_domains}};
  root ${root_dir};
  index index.html;
  location / {
    try_files \$uri \$uri/ /index.html;
  }
}

server {
  listen 443 ssl;
  server_name ${domain}${alias_domains:+ ${alias_domains}};
  root ${root_dir};
  index index.html;

  ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
  include /etc/letsencrypt/options-ssl-nginx.conf;
  ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

  location / {
    try_files \$uri \$uri/ /index.html;
  }
}
CONF

nginx -t
systemctl restart nginx
curl -Ik -H "Host: ${domain}" https://127.0.0.1 >/dev/null
echo "[INFO] HTTPS 自检通过: https://${domain}"
EOF
)
    HTTPS_CMD="${HTTPS_CMD//__DOMAIN__/$DOMAIN}"
    HTTPS_CMD="${HTTPS_CMD//__REMOTE_DIR__/$REMOTE_DIR}"
    HTTPS_CMD="${HTTPS_CMD//__CONF_PATH__/$CONF_PATH}"
    HTTPS_CMD="${HTTPS_CMD//__CERTBOT_EMAIL__/$CERTBOT_EMAIL}"
    HTTPS_CMD="${HTTPS_CMD//__ALIAS_SERVER_NAMES__/$ALIAS_SERVER_NAMES}"
    ssh $SSH_OPTS "$REMOTE" "$HTTPS_CMD"
  fi
fi

log "部署完成。请访问: http://${DOMAIN}"
if [[ "$ENABLE_HTTPS" == "true" ]]; then
  log "如证书申请成功，也可访问: https://${DOMAIN}"
  if [[ -n "$ALIAS_SERVER_NAMES" ]]; then
    log "附加域名也已一并配置: ${ALIAS_SERVER_NAMES}"
  fi
fi
log "请确认 DNS A 记录已指向服务器 IP。"
