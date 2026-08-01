#!/usr/bin/env bash
#
# 在生产服务器上一次性初始化一个站点的蓝绿部署环境。
# 以 root 运行（sudo bash bootstrap-site.sh ...）。
#
# 用法：
#   sudo ./bootstrap-site.sh \
#     --site-id androidphonesblog \
#     --domain androidphonesblog.com \
#     --image ghcr.io/liuying3013/blog_template \
#     --port-base 18100
#
# site-id 是这台服务器上该站点的唯一标识，会同时决定：
#   /etc/nginx/conf.d/10-<id>.conf、/opt/sites/<id>/、
#   /usr/local/sbin/<id>-deploy、容器名 <id>-blue|green
# 建议用站点自己的名字（如 androidphonesblog），不要用模板仓库名。
#
# --port-base N 会分配：N=内部检查端口，N+1=blue，N+2=green。
# 多站点各用一个 base（18100 / 18200 / 18300 …），见方案 §29。
#
# 幂等：可重复运行以更新脚本与 Nginx 配置，不会动已运行的容器和 active 状态。
#
# 卸载（用错 site-id 时清理干净重来）：
#   sudo ./bootstrap-site.sh --uninstall --site-id 旧的id
#   加 --purge 连 /opt/sites/<id>/ 的发布历史一起删除。

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"

SITE_ID=""
DOMAIN=""
IMAGE_NAME=""
PORT_BASE=""
DEPLOY_USER="deploy"
UNINSTALL=0
PURGE=0

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-id)    SITE_ID="${2:-}"; shift 2 ;;
    --domain)     DOMAIN="${2:-}"; shift 2 ;;
    --image)      IMAGE_NAME="${2:-}"; shift 2 ;;
    --port-base)  PORT_BASE="${2:-}"; shift 2 ;;
    --deploy-user) DEPLOY_USER="${2:-}"; shift 2 ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --purge)      PURGE=1; shift ;;
    -h|--help)    usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "必须以 root 运行（sudo）。" >&2
  exit 1
fi

if ! [[ "$SITE_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "site-id 只能包含小写字母、数字和连字符。" >&2
  exit 2
fi

# ---------- 卸载模式 ----------

if [[ "$UNINSTALL" == "1" ]]; then
  echo "==> 卸载站点 ${SITE_ID}"

  for color in blue green; do
    container="${SITE_ID}-${color}"
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
      docker rm -f "$container" >/dev/null && echo "    删除容器 ${container}"
    fi
  done

  for f in \
    "/etc/nginx/conf.d/10-${SITE_ID}.conf" \
    "/etc/nginx/conf.d/00-${SITE_ID}-active.conf" \
    "/etc/nginx/site-upstreams/${SITE_ID}-blue.conf" \
    "/etc/nginx/site-upstreams/${SITE_ID}-green.conf" \
    "/usr/local/sbin/${SITE_ID}-deploy" \
    "/usr/local/sbin/${SITE_ID}-switch" \
    "/usr/local/sbin/${SITE_ID}-rollback" \
    "/etc/sudoers.d/${SITE_ID}-deploy"
  do
    if [[ -e "$f" || -L "$f" ]]; then
      rm -f "$f" && echo "    删除 ${f}"
    fi
  done

  if [[ -d "/opt/sites/${SITE_ID}" ]]; then
    if [[ "$PURGE" == "1" ]]; then
      rm -rf "/opt/sites/${SITE_ID}" && echo "    删除 /opt/sites/${SITE_ID}"
    else
      echo "    保留 /opt/sites/${SITE_ID}（含发布历史，加 --purge 可删除）"
    fi
  fi

  echo
  if nginx -t; then
    systemctl reload nginx && echo "==> Nginx 已重载"
  else
    echo "==> Nginx 配置仍未通过，请检查其他站点配置。" >&2
  fi

  echo "卸载完成。"
  exit 0
fi

# ---------- 安装模式 ----------

[[ -n "$DOMAIN" && -n "$IMAGE_NAME" && -n "$PORT_BASE" ]] || usage

if ! [[ "$PORT_BASE" =~ ^[0-9]{4,5}$ ]]; then
  echo "port-base 必须是 4-5 位数字。" >&2
  exit 2
fi

# ---------- 域名规范化 ----------
# 常见误输入：从聊天窗口复制时被转成 Markdown 链接
# "[www.example.com](https://www.example.com)"，或误传了 www 前缀。
# 这里统一清洗，清洗不掉的直接拒绝，避免生成一份坏掉的 Nginx 配置。

if [[ "$DOMAIN" == *"["* || "$DOMAIN" == *"]"* || "$DOMAIN" == *"("* ]]; then
  echo "域名看起来是从 Markdown 链接复制的：$DOMAIN" >&2
  echo "请只填裸域名，例如：--domain example.com" >&2
  exit 2
fi

DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"

if [[ "$DOMAIN" == www.* ]]; then
  DOMAIN="${DOMAIN#www.}"
  echo "提示：--domain 需要顶级域名，已自动去掉 www. 前缀 → ${DOMAIN}"
fi

if ! [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
  echo "域名格式不合法：$DOMAIN" >&2
  echo "应为裸域名，例如：example.com" >&2
  exit 2
fi

# GHCR 镜像名必须全小写，否则 docker pull 会失败。
# 用 tr 而非 ${var,,}，兼容 bash 3.2（便于在 macOS 上自测）。
IMAGE_NAME_LOWER="$(printf '%s' "$IMAGE_NAME" | tr '[:upper:]' '[:lower:]')"
if [[ "$IMAGE_NAME" != "$IMAGE_NAME_LOWER" ]]; then
  echo "镜像名必须全小写：$IMAGE_NAME" >&2
  exit 2
fi

CHECK_PORT="$PORT_BASE"
BLUE_PORT="$((PORT_BASE + 1))"
GREEN_PORT="$((PORT_BASE + 2))"

SITE_ID_UNDERSCORE="${SITE_ID//-/_}"
DOMAIN_APEX="$DOMAIN"
DOMAIN_WWW="www.${DOMAIN}"

BASE_DIR="/opt/sites/${SITE_ID}"

echo "==> 站点 ${SITE_ID}"
echo "    域名        ${DOMAIN_WWW}"
echo "    镜像        ${IMAGE_NAME}"
echo "    端口        check=${CHECK_PORT} blue=${BLUE_PORT} green=${GREEN_PORT}"
echo "    部署用户    ${DEPLOY_USER}"
echo

# ---------- 依赖检查 ----------

MISSING=()
for cmd in docker curl jq nginx flock; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done

if ! docker compose version >/dev/null 2>&1; then
  MISSING+=("docker-compose-plugin")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "缺少依赖：${MISSING[*]}" >&2
  echo >&2
  echo "Debian/Ubuntu 安装：" >&2
  echo "  apt-get install -y curl jq nginx" >&2
  echo >&2
  echo "Docker 请装官方包（不要用 Ubuntu 的 docker.io，" >&2
  echo "它依赖的 containerd 与官方源的 containerd.io 冲突）：" >&2
  echo "  apt-get install -y docker-ce docker-ce-cli containerd.io \\" >&2
  echo "    docker-buildx-plugin docker-compose-plugin" >&2
  exit 1
fi

# ---------- HTTP/2 语法适配 ----------
# Nginx 1.25.1 起 http2 从 listen 参数改为独立指令。
# Ubuntu 24.04 自带 1.24、22.04 自带 1.18，都要用旧写法，
# 否则 nginx -t 会直接报 "invalid parameter" 或 "unknown directive"。

NGINX_VERSION="$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')"

version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

if [[ -n "$NGINX_VERSION" ]] && version_ge "$NGINX_VERSION" "1.25.1"; then
  HTTP2_SUFFIX=""
  HTTP2_ON_LINE="    http2 on;"
  echo "==> Nginx ${NGINX_VERSION}：使用 http2 on; 指令"
else
  HTTP2_SUFFIX=" http2"
  HTTP2_ON_LINE=""
  echo "==> Nginx ${NGINX_VERSION:-未知}：使用 listen ... http2 旧写法"
fi

# ---------- 端口占用检查 ----------

for port in "$CHECK_PORT" "$BLUE_PORT" "$GREEN_PORT"; do
  if ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
    # 已被本站点自己的容器占用是正常的（重复运行 bootstrap）
    if ! docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null \
      | grep -q "^${SITE_ID}-.*:${port}->"; then
      echo "端口 ${port} 已被其他进程占用，请换一个 --port-base。" >&2
      exit 1
    fi
  fi
done

render() {
  local src="$1" dst="$2"
  sed \
    -e "s|__SITE_ID__|${SITE_ID}|g" \
    -e "s|__SITE_ID_UNDERSCORE__|${SITE_ID_UNDERSCORE}|g" \
    -e "s|__IMAGE_NAME__|${IMAGE_NAME}|g" \
    -e "s|__CHECK_PORT__|${CHECK_PORT}|g" \
    -e "s|__BLUE_PORT__|${BLUE_PORT}|g" \
    -e "s|__GREEN_PORT__|${GREEN_PORT}|g" \
    -e "s|__DOMAIN_APEX__|${DOMAIN_APEX}|g" \
    -e "s|__DOMAIN_WWW__|${DOMAIN_WWW}|g" \
    -e "s|__HTTP2_SUFFIX__|${HTTP2_SUFFIX}|g" \
    -e "s|__HTTP2_ON_LINE__|${HTTP2_ON_LINE}|g" \
    "$src" > "$dst"
}

# ---------- 目录 ----------

install -d -m 755 -o root -g root "${BASE_DIR}" "${BASE_DIR}/state" "${BASE_DIR}/logs"
install -d -m 755 -o root -g root /etc/nginx/site-upstreams
install -d -m 700 -o root -g root /etc/ssl/cloudflare

# ---------- Compose ----------

render "${TEMPLATE_DIR}/compose.yml.template" "${BASE_DIR}/compose.yml"
chmod 644 "${BASE_DIR}/compose.yml"
echo "==> 写入 ${BASE_DIR}/compose.yml"

# ---------- 部署脚本 ----------

for script in deploy switch rollback; do
  target="/usr/local/sbin/${SITE_ID}-${script}"
  render "${TEMPLATE_DIR}/${script}.sh.template" "$target"
  chown root:root "$target"
  chmod 750 "$target"
  bash -n "$target"
  echo "==> 写入 ${target}"
done

# ---------- Nginx upstream（蓝绿各一份）----------

for color in blue green; do
  case "$color" in
    blue)  color_port="$BLUE_PORT" ;;
    green) color_port="$GREEN_PORT" ;;
  esac

  target="/etc/nginx/site-upstreams/${SITE_ID}-${color}.conf"
  sed \
    -e "s|__SITE_ID__|${SITE_ID}|g" \
    -e "s|__SITE_ID_UNDERSCORE__|${SITE_ID_UNDERSCORE}|g" \
    -e "s|__COLOR__|${color}|g" \
    -e "s|__COLOR_PORT__|${color_port}|g" \
    "${TEMPLATE_DIR}/upstream.conf.template" > "$target"
  chmod 644 "$target"
  echo "==> 写入 ${target}"
done

# ---------- Nginx 站点配置 ----------

render "${TEMPLATE_DIR}/site-nginx.conf.template" \
  "/etc/nginx/conf.d/10-${SITE_ID}.conf"
chmod 644 "/etc/nginx/conf.d/10-${SITE_ID}.conf"
echo "==> 写入 /etc/nginx/conf.d/10-${SITE_ID}.conf"

# ---------- 活动软链（首次默认指向 blue，已存在则保留）----------

ACTIVE_LINK="/etc/nginx/conf.d/00-${SITE_ID}-active.conf"

if [[ ! -L "$ACTIVE_LINK" ]]; then
  ln -sfn "/etc/nginx/site-upstreams/${SITE_ID}-blue.conf" "$ACTIVE_LINK"
  echo "==> 初始化活动颜色为 blue"
else
  echo "==> 保留现有活动颜色：$(basename "$(readlink -f "$ACTIVE_LINK")")"
fi

# ---------- sudoers ----------

SUDOERS_FILE="/etc/sudoers.d/${SITE_ID}-deploy"

cat > "${SUDOERS_FILE}.tmp" <<EOF
# 由 bootstrap-site.sh 生成。
# deploy 用户只能调用这两个固定脚本，脚本内部严格校验镜像前缀与 digest 格式。
${DEPLOY_USER} ALL=(root) NOPASSWD: /usr/local/sbin/${SITE_ID}-deploy *
${DEPLOY_USER} ALL=(root) NOPASSWD: /usr/local/sbin/${SITE_ID}-rollback
EOF

chmod 440 "${SUDOERS_FILE}.tmp"

if visudo -cf "${SUDOERS_FILE}.tmp" >/dev/null; then
  mv "${SUDOERS_FILE}.tmp" "$SUDOERS_FILE"
  echo "==> 写入 ${SUDOERS_FILE}"
else
  rm -f "${SUDOERS_FILE}.tmp"
  echo "sudoers 校验失败，未写入。" >&2
  exit 1
fi

# ---------- Nginx 配置校验 ----------

echo
if nginx -t; then
  echo "==> Nginx 配置校验通过"
  echo
  echo "注意：证书文件尚未安装时 nginx reload 会失败，属正常。"
  echo "     安装 Cloudflare Origin Certificate 后再 reload："
  echo "       /etc/ssl/cloudflare/${SITE_ID}-origin.pem"
  echo "       /etc/ssl/cloudflare/${SITE_ID}-origin-key.pem"
else
  echo "==> Nginx 配置校验未通过（通常是证书文件缺失），装好证书后重跑 nginx -t" >&2
fi

echo
echo "完成。后续步骤："
echo "  1. 安装 Cloudflare Origin Certificate 到上述路径（key 权限 600）"
echo "  2. systemctl reload nginx"
echo "  3. root 执行一次 docker login ghcr.io（拉私有镜像用）"
echo "  4. 把 GitHub Actions 的公钥加入 ${DEPLOY_USER} 的 ~/.ssh/authorized_keys"
echo "  5. 在 GitHub 配置 Variables 与 Environment Secrets，push 到 main 触发首次部署"
