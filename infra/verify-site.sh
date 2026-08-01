#!/usr/bin/env bash
#
# 在服务器本地验证站点是否真的部署成功，不依赖 GitHub 网页或 gh CLI。
#
# 用法：
#   ./verify-site.sh --site-id androidphonesblog --domain androidphonesblog.com
#   ./verify-site.sh --site-id androidphonesblog --domain androidphonesblog.com \
#     --expect-revision <完整的 40 位 commit SHA>
#
# 关键点：容器起来了不等于部署内容对得上。带 --expect-revision 才会核对
# 线上实际跑的构建版本，这是唯一能确认"部署的就是最新代码"的检查。

set -uo pipefail

SITE_ID=""
DOMAIN=""
EXPECT_REVISION=""
PORT_BASE=""

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-id)         SITE_ID="${2:-}"; shift 2 ;;
    --domain)          DOMAIN="${2:-}"; shift 2 ;;
    --expect-revision) EXPECT_REVISION="${2:-}"; shift 2 ;;
    --port-base)       PORT_BASE="${2:-}"; shift 2 ;;
    -h|--help)         usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$SITE_ID" && -n "$DOMAIN" ]] || usage

DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"
DOMAIN="${DOMAIN#www.}"
DOMAIN_WWW="www.${DOMAIN}"

STATE_DIR="/opt/sites/${SITE_ID}/state"

PASS=0
FAIL=0

ok()   { echo "  ✅ $*"; PASS=$((PASS + 1)); }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL + 1)); }
info() { echo "     $*"; }

# CHECK_PORT 优先用参数，否则从生成的 nginx 配置里反查
if [[ -z "$PORT_BASE" ]]; then
  CHECK_PORT="$(
    grep -oE 'listen 127\.0\.0\.1:[0-9]+' \
      "/etc/nginx/conf.d/10-${SITE_ID}.conf" 2>/dev/null \
      | grep -oE '[0-9]+$' | head -1
  )"
else
  CHECK_PORT="$PORT_BASE"
fi

echo "站点 ${SITE_ID}  域名 ${DOMAIN_WWW}"
echo

echo "[1/6] 容器状态"
CONTAINERS="$(
  docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null \
    | grep -E "^${SITE_ID}-(blue|green)" || true
)"
if [[ -z "$CONTAINERS" ]]; then
  bad "没有运行中的 ${SITE_ID}-blue / -green 容器"
else
  while IFS= read -r line; do
    if [[ "$line" == *"(healthy)"* ]]; then
      ok "${line%%$'\t'*} 健康"
    elif [[ "$line" == *"(unhealthy)"* ]]; then
      bad "${line%%$'\t'*} 不健康"
    else
      info "${line%%$'\t'*} 状态：$(echo "$line" | cut -f2)"
    fi
  done <<< "$CONTAINERS"
fi

echo
echo "[2/6] 活动颜色"
ACTIVE="$(cat "${STATE_DIR}/active" 2>/dev/null || true)"
if [[ -n "$ACTIVE" ]]; then
  ok "当前活动：${ACTIVE}"
  LINK_TARGET="$(
    readlink -f "/etc/nginx/conf.d/00-${SITE_ID}-active.conf" 2>/dev/null || true
  )"
  if [[ "$LINK_TARGET" == *"${SITE_ID}-${ACTIVE}.conf" ]]; then
    ok "Nginx 软链与状态文件一致"
  else
    bad "Nginx 软链指向 $(basename "${LINK_TARGET:-无}")，与状态文件 ${ACTIVE} 不一致"
  fi
else
  bad "读不到 ${STATE_DIR}/active（还没成功部署过？）"
fi

echo
echo "[3/6] 容器直连健康检查"
for color in blue green; do
  PORT="$(
    docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
      | grep "^${SITE_ID}-${color} " \
      | grep -oE '127\.0\.0\.1:[0-9]+' | grep -oE '[0-9]+$' | head -1
  )"
  [[ -z "$PORT" ]] && continue
  if [[ "$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${PORT}/healthz" 2>/dev/null)" == "200" ]]; then
    ok "${color} (:${PORT}) 返回 200"
  else
    bad "${color} (:${PORT}) 健康检查失败"
  fi
done

echo
echo "[4/6] 宿主机 Nginx 转发"
if [[ -n "$CHECK_PORT" ]]; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${CHECK_PORT}/healthz" 2>/dev/null)"
  case "$CODE" in
    200) ok "内部检查端口 :${CHECK_PORT} 返回 200" ;;
    502) bad "返回 502 —— Nginx 正常但上游容器没起来"
         info "首次部署完成前出现 502 属预期" ;;
    *)   bad "内部检查端口 :${CHECK_PORT} 返回 ${CODE:-无响应}" ;;
  esac
else
  bad "找不到内部检查端口（站点配置缺失？用 --port-base 指定）"
fi

echo
echo "[5/6] HTTPS 与证书"
CODE="$(curl -sk -o /dev/null -w '%{http_code}' \
  --resolve "${DOMAIN_WWW}:443:127.0.0.1" \
  "https://${DOMAIN_WWW}/healthz" 2>/dev/null)"
if [[ "$CODE" == "200" ]]; then
  ok "本机经 HTTPS 访问返回 200"
else
  bad "本机经 HTTPS 访问返回 ${CODE:-失败}"
fi

echo
echo "[6/6] 部署版本核对"
BUILD_JSON="$(
  curl -sk --resolve "${DOMAIN_WWW}:443:127.0.0.1" \
    "https://${DOMAIN_WWW}/_meta/build.json" 2>/dev/null || true
)"
REVISION="$(printf '%s' "$BUILD_JSON" | jq -r '.revision // empty' 2>/dev/null || true)"

if [[ -z "$REVISION" ]]; then
  bad "读不到 /_meta/build.json"
else
  info "线上 revision：${REVISION}"
  if [[ -n "$EXPECT_REVISION" ]]; then
    if [[ "$REVISION" == "$EXPECT_REVISION" ]]; then
      ok "与期望的 commit 一致"
    else
      bad "与期望不一致，期望 ${EXPECT_REVISION}"
      info "说明线上跑的不是这个 commit —— 部署可能失败或被回滚过"
    fi
  else
    ok "构建元数据可读"
    info "加 --expect-revision <commit SHA> 可核对是否为最新代码"
  fi
fi

if [[ -f "${STATE_DIR}/releases.log" ]]; then
  echo
  echo "最近 3 次发布："
  tail -3 "${STATE_DIR}/releases.log" | sed 's/^/     /'
fi

echo
echo "————————————————————————"
if [[ "$FAIL" -eq 0 ]]; then
  echo "全部 ${PASS} 项通过。"
  exit 0
else
  echo "${PASS} 项通过，${FAIL} 项失败。"
  exit 1
fi
