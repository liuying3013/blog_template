# 部署 FAQ

按**症状**查，不是按模块查。每条都来自真实踩过的坑。

完整流程见 [deploy-setup.md](deploy-setup.md)，架构原理见
[deployment-plan.md](../deployment-plan.md)。

---

## 一分钟自检

出任何问题，先在服务器上跑这条，它会告诉你六个环节里哪一环断了：

```bash
./infra/verify-site.sh --site-id <你的site-id> --domain <你的域名>
```

想确认线上跑的**确实是最新代码**（而不只是"容器起来了"）：

```bash
./infra/verify-site.sh --site-id <site-id> --domain <域名> --expect-revision <完整commit SHA>
```

这是唯一能证明部署内容对得上的检查。容器健康 ≠ 部署成功——旧版本容器一样健康。

---

## GitHub Actions 相关

### SSH 报 `Bad port ''`，退出码 255

Secrets 没读到，解析成了空字符串。**最常见的原因是 Environment 名字不匹配。**

workflow 里默认用 `production`，如果你在 GitHub 上建的 Environment 叫 `PROD`
或 `Production`，名字对不上，该 Environment 下的所有 Secrets 全部读不到。
**区分大小写。**

不用重建 Environment，加一个仓库变量即可：

```text
Settings → Secrets and variables → Actions → Variables
DEPLOY_ENVIRONMENT = PROD
```

现在 workflow 第一步会主动检查并打印实际使用的 Environment 名字，
不会再等到 SSH 那步才以 `Bad port ''` 的形式暴露。

### 怎么确认某个 Secret 到底读到没有

打开失败的 workflow run → 右上角齿轮 → Enable debug logging → 重跑，
日志里搜 `Evaluating: secrets.`。看到 `Result: null` 就是没读到。

三种可能：Environment 名字不匹配、Secret 建在 Repository 级别而不是
Environment 下、名字拼写不一致。

### 改了配置要重新 push 才能重试吗

不用。GitHub Actions 页面进入失败的 run，点 **Re-run failed jobs**。
补装证书、补 `docker login`、改 Variables 之后都适用。

---

## GHCR 镜像相关

### `docker login` 提示 Login Succeeded，拉镜像却 403 Forbidden

**PAT 类型选错了。** 这是最难自己想明白的一个坑，因为登录环节完全正常。

GHCR 对 **Fine-grained token**（`github_pat_` 开头）的包权限支持一直不可靠，
会出现登录成功但拉取 403 的情况。必须用 **Classic token**（`ghp_` 开头）：

```text
Settings → Developer settings → Personal access tokens → Tokens (classic)
→ Generate new token (classic) → 只勾 read:packages
```

拿到新 token 后重新登录覆盖旧凭证：

```bash
echo "ghp_你的token" | sudo docker login ghcr.io -u <你的GitHub用户名> --password-stdin
```

然后在 GitHub 上 Re-run failed jobs，不需要重新 push。

### 部署卡在 `docker compose pull`

服务器没登录 GHCR，而镜像仓库是 private。按上一条登录即可。

镜像设为 public 就完全不需要登录——如果内容本来就要公开发布，这是更省事的选择。

### 怎么确认服务器已经登录过

```bash
sudo jq '.auths | keys' /root/.docker/config.json
```

列出的数组里有 `ghcr.io` 就是登录过了。注意必须是 **root 的**凭证——
部署脚本以 root 身份运行，你用普通用户登录的凭证它读不到。

`bootstrap-site.sh` 跑完会自动检查这一项并提示。

---

## Nginx 相关

### `nginx -t` 报错说读不到别的站点的私钥

**你没加 sudo。** 普通用户没有证书私钥的读权限，会报出一堆和你改动完全无关的
错误，看起来像是服务器原有配置坏了。

多站点共享的服务器上，**永远用 `sudo nginx -t`**，普通用户的测试结果不可信。

### 装完证书前，能不能就这么放着

**不能放太久，有风险。** 证书缺失时 `nginx -t` 不通过，此时：

- nginx **不会**自己挂——内存里还是旧配置，其他站点照常服务
- 但只要 nginx **重启**（手动重启、服务器重启、系统更新触发），
  它会因为读不到证书而**拒绝启动**，把这台机器上所有站点一起带下线

要么尽快装证书，要么先把配置移走：

```bash
sudo mv /etc/nginx/conf.d/10-<site-id>.conf /root/ && sudo nginx -t
```

`nginx -t` 恢复通过就安全了，装好证书再挪回来。

### `protocol options redefined for 0.0.0.0:443` 警告

同一个监听地址上多个 server block 各自声明了 TLS 参数。**是 warning 不是
error**，不影响运行。多站点服务器上很常见，通常是原有站点的配置写法导致的，
和新加的站点无关。

### `http2` 相关的语法报错

Nginx 1.25.1 是分界线：之前用 `listen 443 ssl http2;`，之后用独立的
`http2 on;`。Ubuntu 24.04 自带 1.24，22.04 自带 1.18，都属于"之前"。

`bootstrap-site.sh` 会自动检测版本生成对应写法，**不需要换 nginx 源**。
如果你手工改过配置撞上这个报错，用 `nginx -v` 看版本再对照选写法。

---

## bootstrap 脚本相关

### 端口检测失败：`端口 xxxxx 被 yyy 占用`

先看提示里的占用者是谁：

- **`nginx`** 占着 CHECK_PORT：这是设计如此（站点配置自带内部检查端口），
  新版脚本会放行。还报错说明代码是旧的，`git pull` 后重试。
- **`docker-proxy`** 占着蓝绿端口，但不是本站容器：真的撞车了，
  换一个 `--port-base`。查是谁在用：`sudo ss -ltnp "sport = :端口号"`
- **其他进程**：换 `--port-base`，或者停掉那个进程。

多站点的端口分配建议见方案 §29：每站一个 base，18100 / 18200 / 18300…

### 站点跑起来之后还能重跑 bootstrap 吗

**能，是安全的。** 端口检测会识别 CHECK_PORT 上的宿主机 nginx 和蓝绿端口上
的本站容器，放行自己人；活动颜色和运行中的容器都不会被动。

> 早期版本确实存在"装好后无法重跑"的 bug——CHECK_PORT 被自家 nginx 占用却
> 不在放行名单里。更糟的是它会导致脚本在写入站点配置**之前**中途退出，
> 留下只有 upstream、没有 server block 的半截状态。已修复。

### `/etc/nginx/conf.d/10-<site-id>.conf` 不见了

上一条那个 bug 的典型后果：bootstrap 中途退出，upstream 和软链写了、
站点配置没写。

修复后重跑 bootstrap 会自动补齐。不想重跑的话，照着
`infra/templates/site-nginx.conf.template` 手动替换占位符也行。

### 站点名字取错了怎么办

`--site-id` 同时决定五处名字（nginx 配置、`/opt/sites/` 目录、部署脚本、
sudoers、容器名），所以别用模板仓库名，用站点自己的名字。

改名就是卸载重装，只影响该 site-id，不碰同机其他站点：

```bash
sudo ./infra/bootstrap-site.sh --uninstall --site-id 旧id
sudo ./infra/bootstrap-site.sh --site-id 新id --domain ... --image ... --port-base ...
```

默认保留 `/opt/sites/<id>/` 的发布历史，加 `--purge` 一并删除。
**改完记得同步更新 GitHub 仓库变量 `SITE_ID`**，否则 Actions 会去调用一个
不存在的部署脚本。

---

## 验证与排错

### 健康检查返回 502

**Nginx 正常，上游容器没起来。** 502 说明 Nginx 已经在正确转发了，
只是后面没人应答。

首次部署完成之前出现 502 是**预期的**，不是故障。部署跑完就会变成 `ok`。
如果部署已完成还是 502，看容器状态：

```bash
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep <site-id>
docker logs --tail=50 <site-id>-blue
```

### 怎么在服务器上确认部署成功（不看 GitHub 网页）

用 `verify-site.sh`，或者手动跑这几条：

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep <site-id>
cat /opt/sites/<site-id>/state/active
cat /opt/sites/<site-id>/state/releases.log
curl -s http://127.0.0.1:<CHECK_PORT>/healthz
curl -sk --resolve <域名>:443:127.0.0.1 https://<域名>/_meta/build.json
```

**最后一条最关键**：返回的 `revision` 要和 GitHub 上最新的 commit SHA 一致，
才能证明线上跑的是最新代码。前面几条只能证明"有个容器在跑"。

### 网站打不开，但服务器本地检查都正常

问题在 Cloudflare 或 DNS 那一层，不在服务器上。依次确认：

1. DNS 记录的橙色云朵开着（Proxied，不是 DNS only）
2. SSL/TLS 模式是 **Full (strict)**（选了 Flexible 会无限重定向）
3. 服务器防火墙放行 80/443
4. `curl -sI https://你的域名/healthz` 看响应头里的 `cf-cache-status`
   ——有这个头说明流量确实过了 Cloudflare

### 怎么回滚

```bash
sudo /usr/local/sbin/<site-id>-rollback
```

只切 Nginx 上游、reload，十秒内完成。不重新拉镜像、不重新构建——
上一个版本的容器一直在后台留着。

---

## 环境与权限

### 开发机和生产服务器是同一台，流程要改吗

**不用改。** GitHub Actions 依然是 SSH 连回这台机器执行部署。

唯一要注意：`PROD_HOST` 填**公网 IP**，不能填 `127.0.0.1` 或 `localhost`
——Actions 跑在 GitHub 的机器上，不是你的机器上。

### AI 助手没有 sudo 权限，怎么协作

让它写好脚本，你自己执行：

```bash
sudo bash /tmp/xxx.sh
```

比起把 root 密码交出去，这个模式更可控，而且脚本可以先读一遍再决定跑不跑。
本仓库的 `infra/*.sh` 都是按这个方式设计的——幂等、可重复执行、失败有明确提示。

### 首次 git commit 报 `Author identity unknown`

这台机器从没配过 git 身份。建议只设仓库级（不加 `--global`）：

```bash
git config user.name "你的名字" && git config user.email "你的邮箱"
```

### 私钥和 token 能不能贴给 AI 助手

按**复用范围**判断：

| 类型 | 建议 |
| --- | --- |
| Cloudflare Origin 私钥 | 用途单一，只服务这一个站的 TLS，风险可控 |
| GitHub Actions SSH 私钥 | **别贴**，它往往还兼作你推代码的身份，暴露面大得多 |
| GHCR PAT | **别贴**，能读你所有私有包 |

后两类的正确做法：自己在终端 `cat` 出来，直接复制粘贴到 GitHub Secrets 页面，
不经过任何中间环节。

已经贴出去了的话，去 GitHub 撤销重建一个即可，不用推倒重来。

---

## 日常操作速查

| 想做什么 | 命令 |
| --- | --- |
| 发文章 | 写 Markdown → `git push`，自动上线 |
| 全面体检 | `./infra/verify-site.sh --site-id <id> --domain <域名>` |
| 回滚 | `sudo /usr/local/sbin/<id>-rollback` |
| 看发布历史 | `cat /opt/sites/<id>/state/releases.log` |
| 看当前活动颜色 | `cat /opt/sites/<id>/state/active` |
| 看容器日志 | `docker logs --tail=100 <id>-blue` |
| 重试失败的部署 | GitHub Actions 页面点 Re-run failed jobs |
| 改 nginx 后验证 | `sudo nginx -t && sudo systemctl reload nginx` |
