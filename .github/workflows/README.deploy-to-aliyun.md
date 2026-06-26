# GitHub Actions 自动部署说明

本仓库的 `.github/workflows/deploy-to-aliyun.yml` 会在 `main` 分支有新的 push 或合并后自动运行，也可以在 GitHub Actions 页面手动运行。

## 部署规则

Action 会把仓库根目录下的网页文件夹同步到阿里云服务器：

- `customerservice/` -> `/usr/share/nginx/customerservice/`
- `demo/` -> `/usr/share/nginx/demo/`
- `html/` -> `/usr/share/nginx/html/`
- `kidsfocus/` -> `/usr/share/nginx/kidsfocus/`
- `privacy/` -> `/usr/share/nginx/privacy/`

它会自动跳过：

- `scripts/`
- `.git/`
- `.github/`
- `.tmp_pdf/`
- `.DS_Store`

如果之后新增同级网页目录，例如 `modules/`，合入 `main` 后也会自动部署到 `/usr/share/nginx/modules/`。

## 需要配置的 GitHub Secrets

在 GitHub 仓库页面进入 `Settings` -> `Secrets and variables` -> `Actions`，新增：

| Secret 名称 | 示例 | 说明 |
| --- | --- | --- |
| `ALIYUN_HOST` | `39.97.235.81` | 阿里云服务器公网 IP 或域名 |
| `ALIYUN_USER` | `root` | SSH 登录用户 |
| `ALIYUN_PORT` | `22` | SSH 端口 |
| `ALIYUN_SSH_PRIVATE_KEY` | 私钥完整内容 | 用于登录服务器的私钥内容 |
| `ALIYUN_REMOTE_BASE_DIR` | `/usr/share/nginx` | 远程 Nginx 网页根目录，可不填 |

`ALIYUN_SSH_PRIVATE_KEY` 要粘贴完整私钥，包括开头和结尾：

```text
-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----
```

## 服务器要求

服务器需要满足：

- GitHub Actions 使用的 SSH 公钥已经加入服务器用户的 `~/.ssh/authorized_keys`。
- 服务器已安装 `nginx`。如果已安装 `rsync` 会优先使用 `rsync --delete`，否则会自动降级为 `tar` 传输。
- SSH 用户有权限写入 `/usr/share/nginx/*`，并能执行 `nginx -t && systemctl reload nginx`。

如果用的不是 `root` 用户，需要给部署用户配置对应目录权限和免密 sudo，或者把 workflow 中的 reload 命令调整成服务器允许的方式。
