#!/usr/bin/env bash
#
# 04-verify-connectivity.sh — 代理/隧道生效验证
#
# 做三件事：
#   1. 记录直连出口 IP
#   2. 通过代理/隧道出口再取一次 IP，比对是否改变
#   3. 检查 DNS 泄漏与链路延迟（可用 --skip-dns / --skip-ping 跳过）
#
# 用法：
#   ./04-verify-connectivity.sh                                   # 只做直连基线
#   ./04-verify-connectivity.sh --socks5 127.0.0.1:1080           # 验证 SOCKS5 代理
#   ./04-verify-connectivity.sh --http 127.0.0.1:8080 --expect-node vultr
#   ./04-verify-connectivity.sh --server-ip 203.0.113.10          # 直接对比 WireGuard 服务器
#
# 注意：本脚本只做只读的网络探测，不修改任何系统配置。
#
set -euo pipefail

PROXY_SOCKS5=""
PROXY_HTTP=""
SERVER_IP=""
EXPECT_NODE=""
SKIP_DNS="no"
SKIP_PING="no"
PING_COUNT="10"
TIMEOUT="10"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_BOLD=""
fi
info() { printf '%s[INFO]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK"   "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$C_ERR"  "$C_RESET" "$*"; }
die()  { fail "$*"; exit 1; }

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --socks5)     PROXY_SOCKS5="${2:?}"; shift 2 ;;
    --http)       PROXY_HTTP="${2:?}"; shift 2 ;;
    --server-ip)  SERVER_IP="${2:?}"; shift 2 ;;
    --expect-node) EXPECT_NODE="${2:?}"; shift 2 ;;
    --count)      PING_COUNT="${2:?}"; shift 2 ;;
    --skip-dns)   SKIP_DNS="yes"; shift ;;
    --skip-ping)  SKIP_PING="yes"; shift ;;
    -h|--help)    usage ;;
    *)            die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "需要 curl，请先安装。"

# ---------- 工具函数 ----------
curl_via() {           # $1 = proxy 参数（可为空）
  local proxy="$1" url="$2"
  if [[ -n "$proxy" ]]; then
    curl -s --max-time "$TIMEOUT" -x "$proxy" "$url"
  else
    curl -s --max-time "$TIMEOUT" "$url"
  fi
}

get_ip() { curl_via "$1" "https://ipinfo.io/ip" | tr -d '[:space:]'; }

get_info() { curl_via "$1" "https://ipinfo.io/json"; }

json_field() {         # $1 = json, $2 = field
  local json="$1" field="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // "unknown"'
  else
    printf '%s' "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
  fi
}

proxy_label() {
  if [[ -n "$PROXY_SOCKS5" ]]; then printf 'socks5://%s' "$PROXY_SOCKS5"
  elif [[ -n "$PROXY_HTTP" ]]; then printf 'http://%s' "$PROXY_HTTP"
  else printf ''; fi
}

# ---------- 主流程 ----------
PROXY="$(proxy_label)"
[[ -z "$PROXY" && -z "$SERVER_IP" ]] && warn "未指定代理或服务器 IP，将只采集直连基线。"

printf '\n%s=== 1. 直连出口 ===%s\n' "$C_BOLD" "$C_RESET"
DIRECT_IP="$(get_ip "")"
if [[ -z "$DIRECT_IP" ]]; then
  fail "无法获取直连出口 IP（检查本机网络）"
else
  ok "直连出口 IP：${DIRECT_IP}"
fi

TUNNEL_IP=""
if [[ -n "$PROXY" ]]; then
  printf '\n%s=== 2. 代理链路出口（%s）===%s\n' "$C_BOLD" "$PROXY" "$C_RESET"
  TUNNEL_IP="$(get_ip "$PROXY" || true)"
  if [[ -z "$TUNNEL_IP" ]]; then
    fail "通过代理无法访问网络：请检查客户端是否已开启、端口是否正确、服务器是否可达"
  else
    ok "代理出口 IP：${TUNNEL_IP}"
    INFO_JSON="$(get_info "$PROXY" || true)"
    if [[ -n "$INFO_JSON" ]]; then
      printf '       ISP/组织 : %s\n       地区     : %s, %s\n       ASN      : %s\n' \
        "$(json_field "$INFO_JSON" org)" "$(json_field "$INFO_JSON" city)" \
        "$(json_field "$INFO_JSON" country)" "$(json_field "$INFO_JSON" asn)"
      if [[ -n "$EXPECT_NODE" ]] && ! printf '%s' "$INFO_JSON" | grep -qi -- "$EXPECT_NODE"; then
        warn "组织信息中未匹配到关键字 '${EXPECT_NODE}'，请人工确认出口节点"
      fi
    fi
    if [[ -n "$DIRECT_IP" && "$TUNNEL_IP" == "$DIRECT_IP" ]]; then
      fail "出口 IP 与直连一致 —— 代理很可能没有生效（或存在分流规则放行）"
    else
      ok "出口 IP 已改变 —— 代理链路生效 ✅"
    fi
  fi
fi

if [[ -n "$SERVER_IP" ]]; then
  printf '\n%s=== 3. 服务器直连与延迟 ===%s\n' "$C_BOLD" "$C_RESET"
  if [[ "$SKIP_PING" != "yes" ]]; then
    if ping -c "$PING_COUNT" -W 2 "$SERVER_IP" >/tmp/vpn-ping.$$ 2>&1; then
      local_summary="$(grep -E 'packet loss|round-trip|rtt' /tmp/vpn-ping.$$ | tr '\n' ' ' || true)"
      ok "ping ${SERVER_IP}：${local_summary:-见原始输出}"
      grep -E 'packet loss|round-trip|rtt' /tmp/vpn-ping.$$ || true
    else
      warn "ping ${SERVER_IP} 失败（可能被 ICMP 限速或未放行 ICMP，不代表服务不可用）"
    fi
    rm -f /tmp/vpn-ping.$$
  fi
  if nc -z -w 5 "$SERVER_IP" "${SSH_PORT:-22}" 2>/dev/null; then
    ok "TCP 22 端口可达（nc 探测通过）"
  else
    info "TCP 22 端口探测未通过（若已改 SSH 端口属正常）"
  fi
fi

if [[ "$SKIP_DNS" != "yes" ]]; then
  printf '\n%s=== 4. DNS 解析与泄漏初查 ===%s\n' "$C_BOLD" "$C_RESET"
  if command -v dig >/dev/null 2>&1; then
    resolver="$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || true)"
    printf '       OpenDNS 看到的解析出口：%s\n' "${resolver:-查询失败（可能无 dig 权限或 UDP/53 被拦）}"
    warn "若此处返回的是本地 ISP 地址而代理出口是服务器地址，说明 DNS 查询走了直连（DNS 泄漏）。"
  else
    info "未安装 dig，跳过 DNS 出口检查（macOS/Linux 可安装 dnsutils）"
  fi
fi

printf '\n%s=== 小结 ===%s\n' "$C_BOLD" "$C_RESET"
printf '  直连出口   : %s\n  代理出口   : %s\n' "${DIRECT_IP:-未获取}" "${TUNNEL_IP:-未测试}"
if [[ -n "$TUNNEL_IP" && -n "$DIRECT_IP" && "$TUNNEL_IP" != "$DIRECT_IP" ]]; then
  ok "结论：代理已生效。"
else
  [[ -n "$PROXY" ]] && fail "结论：未能确认代理生效，请按 docs/06 的分层定位法排查。" || info "结论：仅采集了直连基线，使用 --socks5/--http 可验证代理。"
fi
