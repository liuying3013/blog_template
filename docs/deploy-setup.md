# 自动部署上线清单

从"代码在 GitHub"到"push 即上线"，需要打通三段：**服务器**、**GitHub**、**Cloudflare**。
按顺序做，每段末尾都有验证方法。

完整原理见 [deployment-plan.md](../deployment-plan.md)，本文只讲操作步骤。

---

## 你需要先准备好的东西

| 项目 | 说明 |
| --- | --- |
| 一台 Linux 服务器 | Ubuntu 22.04/24.04 或 Debian 12，1核1G 起步够用 |
| 一个域名 | 已经把 DNS 托管到 Cloudflare |
| Cloudflare 账号 | 免费版即可 |
| WhatsApp 号码 | 接收询盘用，国际格式如 `8613800000000` |

---

## 第一段：服务器

### 1. 安装依赖

```bash
sudo apt-get update
sudo apt-get install -y curl jq nginx
```

Docker 装官方包。**不要用 Ubuntu 的 `docker.io`**——它依赖 Ubuntu 版
`containerd`，与 Docker 官方源提供的 `containerd.io` 互斥，同时存在会报
`containerd.io : Conflicts: containerd`：

```bash
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker nginx
```

> 先用 `docker --version && docker compose version` 确认是否已装好，
> 很多云厂商的镜像已经预装了 Docker 官方版。

**关于 Nginx 版本**：`http2 on;` 指令需要 Nginx ≥ 1.25.1，而 Ubuntu 24.04
自带 1.24、22.04 自带 1.18。bootstrap 脚本会自动检测版本并生成对应语法，
用发行版自带的 Nginx 即可，无需换源。

### 2. 创建部署用户

这个用户是 GitHub Actions 登录服务器用的。**不要**把它加进 `docker` 组——
`docker` 组等同于 root 权限。它只能通过 sudo 调用固定的部署脚本。

```bash
sudo adduser --disabled-password --gecos "" deploy
sudo install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
```

### 3. 运行 bootstrap 脚本

把仓库的 `infra/` 目录传到服务器（或直接 git clone 仓库），然后：

```bash
sudo ./infra/bootstrap-site.sh \
  --site-id blog-template \
  --domain example.com \
  --image ghcr.io/liuying3013/blog_template \
  --port-base 18100
```

这一步会自动生成：部署/回滚/切换脚本、Docker Compose 配置、Nginx 蓝绿配置、
sudoers 白名单。脚本是幂等的，改了模板可以重复运行。

> **多站点**：每个站点用不同的 `--port-base`（18100 / 18200 / 18300 …），
> 见方案 §29 的端口分配表。

### 4. 安装 Cloudflare Origin 证书

在 Cloudflare 后台 → SSL/TLS → Origin Server → Create Certificate，
把生成的两段内容存到服务器：

```bash
sudo nano /etc/ssl/cloudflare/blog-template-origin.pem      # 证书
sudo nano /etc/ssl/cloudflare/blog-template-origin-key.pem  # 私钥
sudo chmod 600 /etc/ssl/cloudflare/blog-template-origin-key.pem
sudo nginx -t && sudo systemctl reload nginx
```

### 5. 让服务器能拉取镜像

GHCR 上的私有镜像需要先登录。用一个只有 `read:packages` 权限的
Classic PAT（GitHub → Settings → Developer settings → Personal access tokens）：

```bash
echo "你的PAT" | sudo docker login ghcr.io -u liuying3013 --password-stdin
```

> 如果把 GHCR 包设为 public，这一步可以跳过。

### 6. 配置防火墙

```bash
sudo ufw allow 22/tcp
sudo ufw allow 80,443/tcp
sudo ufw enable
```

蓝绿端口（18101/18102）只监听 `127.0.0.1`，本来就不对外，无需额外规则。
更严格的做法是只允许 Cloudflare IP 段访问 80/443，见方案 §25。

**验证第一段**：

```bash
ls -l /usr/local/sbin/blog-template-*     # 三个脚本存在且 750 root:root
sudo nginx -t                              # 配置通过
sudo -u deploy sudo -ln                    # 只列出两条部署命令
```

---

## 第二段：GitHub

### 7. 生成部署用 SSH 密钥

**在你自己的电脑上**执行（不要在服务器上生成）：

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/blog_deploy -N ""
```

把**公钥**放到服务器：

```bash
ssh-copy-id -i ~/.ssh/blog_deploy.pub deploy@你的服务器IP
```

再抓取服务器指纹（防中间人攻击）：

```bash
ssh-keyscan -p 22 你的服务器IP
```

### 8. 配置 Repository Variables

GitHub 仓库 → Settings → Secrets and variables → Actions → **Variables** 页签。
这些会出现在网页源码里，不是机密：

| 名称 | 值示例 |
| --- | --- |
| `SITE_URL` | `https://www.example.com` |
| `SITE_ID` | `blog-template`（要和 bootstrap 的 `--site-id` 一致） |
| `PUBLIC_WHATSAPP_NUMBER` | `8613800000000` |
| `PUBLIC_GTM_ID` | `GTM-XXXXXXX`（没有就留空不建） |

### 9. 配置 Environment Secrets

同一页面 → Environments → 新建 `production` → Add secret。
这些是真机密，**不会**出现在网页里：

| 名称 | 值 |
| --- | --- |
| `PROD_HOST` | 服务器 IP |
| `PROD_PORT` | `22` |
| `PROD_USER` | `deploy` |
| `PROD_SSH_PRIVATE_KEY` | `~/.ssh/blog_deploy` 的**全部内容** |
| `PROD_SSH_KNOWN_HOSTS` | 上一步 `ssh-keyscan` 的输出 |
| `CF_ZONE_ID` | Cloudflare 域名概览页右下角 |
| `CF_CACHE_PURGE_TOKEN` | Cloudflare API Token，权限选 `Zone → Cache Purge → Purge` |

**验证第二段**：从本地试一次 SSH，应当能免密执行：

```bash
ssh -i ~/.ssh/blog_deploy deploy@服务器IP "sudo /usr/local/sbin/blog-template-rollback"
```

（首次没有部署过会报 "Unknown active color"，这是正常的——说明鉴权和 sudo 白名单都通了。）

---

## 第三段：Cloudflare

### 10. DNS

| 类型 | 名称 | 值 | 代理 |
| --- | --- | --- | --- |
| A | `@` | 服务器 IP | **已代理**（橙色云） |
| CNAME | `www` | `example.com` | **已代理**（橙色云） |

橙色云必须开启，否则源站 IP 会暴露、CDN 和 WAF 也不生效。

### 11. SSL/TLS

- Overview → 加密模式选 **Full (strict)**
- Edge Certificates → 开启 **HSTS**（Max-Age 先设 6 个月）

> 开 HSTS 前确认 HTTPS 已经稳定，浏览器一旦记住就无法回退到 HTTP。

### 12. 缓存规则

Rules → Caching Rules，按方案 §23.3–23.7 建五条。最关键的两条：

- `/healthz` 和 `/_meta/*` → **Bypass cache**（否则健康检查会读到缓存，部署验证失灵）
- HTML 页面 → **Eligible for cache**，Edge TTL 1 天（静态站没有个性化内容，可以放心缓存）

---

## 第四段：首次上线

一切就绪后，推一次代码：

```bash
git commit --allow-empty -m "触发首次部署"
git push
```

到 GitHub 仓库的 Actions 页签看流水线。正常会依次跑完：
构建镜像 → 推送 GHCR → SSH 部署到 blue → 健康检查 → 切换 Nginx →
清 Cloudflare 缓存 → 公网健康检查。

**验证上线成功**：

```bash
curl https://www.example.com/healthz              # 返回 ok
curl https://www.example.com/_meta/build.json     # revision 等于最新 commit SHA
curl -I https://www.example.com/blog              # 301 跳到 /blog/
```

---

## 日常操作

**发文章**：写 Markdown → push → 自动上线，无需其他操作。

**出问题回滚**（10 秒内完成，只切 Nginx 不重新拉镜像）：

```bash
ssh deploy@服务器IP "sudo /usr/local/sbin/blog-template-rollback"
```

**看发布历史**：

```bash
ssh deploy@服务器IP "cat /opt/sites/blog-template/state/releases.log"
```

---

## 别忘了：外部监控

上面所有检查都要手动敲命令，网站半夜挂了没人知道。
去 [UptimeRobot](https://uptimerobot.com)（免费）添加一个监控：

- 地址：`https://www.example.com/healthz`
- 间隔：5 分钟
- 通知：邮件或 Telegram

这是方案 §27 里唯一需要外部服务的一环，但省不得。
