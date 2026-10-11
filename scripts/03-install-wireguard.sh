#!/usr/bin/env bash
#
# 03-install-wireguard.sh — 在 Debian/Ubuntu 上部署 WireGuard 服务端
#
# 说明：这是"原理对照"实验用脚本，用于理解操作系统级 VPN 的虚拟网卡模型。
#       脚本会自动生成服务端/客户端密钥对，写出 wg0.conf，开启转发与 NAT，
#       并把客户端配置模板打印出来（含私钥，请勿外发）。
#
# 用法：
#   sudo ./03-install-wireguard.sh --port 51820
#   sudo ./03-install-wireguard.sh --port 51820 --endpoint 203.0.113.10 --client-name macbook
#   ./03-install-wireguard.sh --dry-run
#
set -euo pipefail

PORT="51820"
TUNNEL_NET="10.8.0"
SERVER_IP="${TUNNEL_NET}.1"
CLIENT_IP="${TUNNEL_NET}.2"
CLIENT_NAME="client1"
ENDPOINT="<SERVER_IP>"
EGRESS_IF=""
MODE="apply"
DNS="1.1.1.1"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi
info() { printf '%s[INFO]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK"   "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$C_ERR"  "$C_RESET" "$*" >&2; exit 1; }

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)        PORT="${2:?}"; shift 2 ;;
    --endpoint)    ENDPOINT="${2:?}"; shift 2 ;;
    --client-name) CLIENT_NAME="${2:?}"; shift 2 ;;
    --egress-if)   EGRESS_IF="${2:?}"; shift 2 ;;
    --dns)         DNS="${2:?}"; shift 2 ;;
    --dry-run)     MODE="dry-run"; shift ;;
    --apply)       MODE="apply"; shift ;;
    -h|--help)     usage ;;
    *)             die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

WG_DIR="/etc/wireguard"
SERVER_CONF="${WG_DIR}/wg0.conf"
KEY_DIR="${WG_DIR}/keys"

run() {
  if [[ "$MODE" == "dry-run" ]]; then
    printf '  %s$%s %s\n' "$C_INFO" "$C_RESET" "$*"
    return 0
  fi
  printf '  %s$%s %s\n' "$C_INFO" "$C_RESET" "$*"
  "$@"
}

detect_egress_if() {
  [[ -n "$EGRESS_IF" ]] && { printf '%s' "$EGRESS_IF"; return; }
  local iface=""
  if command -v ip >/dev/null 2>&1; then
    iface="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)"
  fi
  printf '%s' "${iface:-eth0}"
}

main() {
  [[ "$MODE" == "dry-run" ]] || {
    [[ "${EUID}" -eq 0 ]] || die "需要 root 权限，请用 sudo 执行。"
    [[ "$(uname -s)" == "Linux" ]] || die "本脚本仅支持 Linux。"
  }

  local egress; egress="$(detect_egress_if)"
  info "部署 WireGuard（端口 ${PORT}，出口网卡 ${egress}，隧道网段 ${TUNNEL_NET}.0/24）"

  info "步骤 1/5：安装 wireguard"
  run apt-get update
  run apt-get install -y wireguard wireguard-tools

  info "步骤 2/5：生成密钥对（权限 600）"
  local srv_priv srv_pub cli_priv cli_pub
  if [[ "$MODE" == "dry-run" ]]; then
    printf '  %s$%s umask 077 && wg genkey | tee server.key | wg pubkey > server.pub\n' "$C_INFO" "$C_RESET"
    printf '  %s$%s umask 077 && wg genkey | tee client.key | wg pubkey > client.pub\n' "$C_INFO" "$C_RESET"
    srv_priv="<SERVER_PRIVATE_KEY>"; srv_pub="<SERVER_PUBLIC_KEY>"
    cli_priv="<CLIENT_PRIVATE_KEY>"; cli_pub="<CLIENT_PUBLIC_KEY>"
  else
    umask 077
    install -d -m 700 "$KEY_DIR"
    [[ -f "${KEY_DIR}/server.key" ]] || wg genkey >"${KEY_DIR}/server.key"
    wg pubkey <"${KEY_DIR}/server.key" >"${KEY_DIR}/server.pub"
    [[ -f "${KEY_DIR}/client.key" ]] || wg genkey >"${KEY_DIR}/client.key"
    wg pubkey <"${KEY_DIR}/client.key" >"${KEY_DIR}/client.pub"
    srv_priv="$(cat "${KEY_DIR}/server.key")"; srv_pub="$(cat "${KEY_DIR}/server.pub")"
    cli_priv="$(cat "${KEY_DIR}/client.key")"; cli_pub="$(cat "${KEY_DIR}/client.pub")"
    ok "密钥已生成于 ${KEY_DIR}"
  fi

  info "步骤 3/5：写入服务端配置 ${SERVER_CONF}"
  if [[ "$MODE" == "dry-run" ]]; then
    printf '  %s$%s tee %s <<EOF  [Interface] Address=%s/24 ListenPort=%s + [Peer] AllowedIPs=%s/32\n' \
      "$C_INFO" "$C_RESET" "$SERVER_CONF" "$SERVER_IP" "$PORT" "$CLIENT_IP"
  else
    install -d -m 700 "$WG_DIR"
    local existing_peers=""
    if [[ -f "$SERVER_CONF" ]]; then
      existing_peers="$(sed -n '/^\[Peer\]/,$p' "$SERVER_CONF")"
      warn "检测到已有 ${SERVER_CONF}，将保留其中已有的 [Peer] 段落"
    fi
    cat >"$SERVER_CONF" <<EOF
# 由 vpn-proxy-lab/scripts/03-install-wireguard.sh 生成
[Interface]
Address    = ${SERVER_IP}/24
ListenPort = ${PORT}
PrivateKey = ${srv_priv}
PostUp     = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${egress} -j MASQUERADE
PostDown   = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${egress} -j MASQUERADE
EOF
    if [[ -n "$existing_peers" ]]; then
      printf '\n%s\n' "$existing_peers" >>"$SERVER_CONF"
    else
      cat >>"$SERVER_CONF" <<EOF

[Peer]
# ${CLIENT_NAME}
PublicKey  = ${cli_pub}
AllowedIPs = ${CLIENT_IP}/32
EOF
    fi
    chmod 600 "$SERVER_CONF"
    ok "配置已写入"
  fi

  info "步骤 4/5：开启内核转发并启动服务"
  if [[ "$MODE" == "dry-run" ]]; then
    printf '  %s$%s tee /etc/sysctl.d/99-wireguard.conf <<EOF  net.ipv4.ip_forward=1\n' "$C_INFO" "$C_RESET"
  else
    printf 'net.ipv4.ip_forward=1\n' >/etc/sysctl.d/99-wireguard.conf
    sysctl --system >/dev/null
  fi
  run systemctl enable "wg-quick@wg0"
  run systemctl restart "wg-quick@wg0"

  if [[ "$MODE" != "dry-run" ]]; then
    systemctl is-active --quiet "wg-quick@wg0" && ok "wg-quick@wg0 运行中" || die "启动失败，请查看：journalctl -u wg-quick@wg0 -n 50"
    wg show || true
  fi

  if [[ "$MODE" != "dry-run" ]] && command -v ufw >/dev/null 2>&1; then
    run ufw allow "${PORT}/udp"
  fi

  info "步骤 5/5：客户端配置（含私钥，请勿外发）"
  cat <<EOF

-------------------------------- 客户端配置开始 --------------------------------
[Interface]
PrivateKey = ${cli_priv}
Address    = ${CLIENT_IP}/24
DNS        = ${DNS}

[Peer]
PublicKey           = ${srv_pub}
Endpoint            = ${ENDPOINT}:${PORT}
AllowedIPs          = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
-------------------------------- 客户端配置结束 --------------------------------

EOF
  ok "完成。验证：sudo wg show；ping -c4 ${SERVER_IP}"
}

main "$@"
