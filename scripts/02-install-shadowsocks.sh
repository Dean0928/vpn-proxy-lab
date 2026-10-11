#!/usr/bin/env bash
#
# 02-install-shadowsocks.sh — 在 Debian/Ubuntu 上安装并配置 shadowsocks-libev
#
# 特点：
#   * 密码未指定时自动随机生成（不写死在脚本/仓库里）
#   * 配置文件权限 600，写入前做 JSON 语义校验
#   * 安装完成后打印 SIP002 格式的 ss:// 分享链接（含敏感信息，请勿外发）
#   * 支持 --dry-run 预览
#
# 用法：
#   sudo ./02-install-shadowsocks.sh --port 8388
#   sudo ./02-install-shadowsocks.sh --port 8388 --password 'your-strong-pass' --method chacha20-ietf-poly1305
#   ./02-install-shadowsocks.sh --dry-run --port 8388
#
set -euo pipefail

PORT="8388"
PASSWORD=""
METHOD="xchacha20-ietf-poly1305"
SERVER_ADDR="0.0.0.0"
TIMEOUT="300"
MODE="apply"
OPEN_FIREWALL="yes"
HOST_HINT=""

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi
info() { printf '%s[INFO]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK"   "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$C_ERR"  "$C_RESET" "$*" >&2; exit 1; }

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)       PORT="${2:?}"; shift 2 ;;
    --password)   PASSWORD="${2:?}"; shift 2 ;;
    --method)     METHOD="${2:?}"; shift 2 ;;
    --host)       HOST_HINT="${2:?}"; shift 2 ;;
    --listen)     SERVER_ADDR="${2:?}"; shift 2 ;;
    --no-firewall) OPEN_FIREWALL="no"; shift ;;
    --dry-run)    MODE="dry-run"; shift ;;
    --apply)      MODE="apply"; shift ;;
    -h|--help)    usage ;;
    *)            die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

CONFIG_DIR="/etc/shadowsocks-libev"
CONFIG_FILE="${CONFIG_DIR}/config.json"

run() {
  if [[ "$MODE" == "dry-run" ]]; then
    printf '  %s$%s %s\n' "$C_INFO" "$C_RESET" "$*"
    return 0
  fi
  printf '  %s$%s %s\n' "$C_INFO" "$C_RESET" "$*"
  "$@"
}

require_root() {
  [[ "$MODE" == "dry-run" ]] && return 0
  [[ "${EUID}" -eq 0 ]] || die "需要 root 权限，请用 sudo 执行。"
  [[ "$(uname -s)" == "Linux" ]] || die "本脚本仅支持 Linux。"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      debian|ubuntu) ok "检测到系统：${PRETTY_NAME:-$ID}" ;;
      *) die "仅支持 Debian/Ubuntu，当前为 ${ID:-unknown}。" ;;
    esac
  fi
}

gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '/+=' | cut -c1-24
  else
    # 退路：直接用 /dev/urandom（用 cut 读完全部输入，避免 SIGPIPE）
    LC_ALL=C dd if=/dev/urandom bs=64 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24
  fi
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "端口必须是数字：$1"
  (( $1 >= 1 && $1 <= 65535 )) || die "端口范围应为 1-65535：$1"
}

write_config() {
  local pw="$1"
  info "写入配置 ${CONFIG_FILE}（权限 600）"
  [[ "$MODE" == "dry-run" ]] || install -d -m 755 "$CONFIG_DIR"
  if [[ "$MODE" == "dry-run" ]]; then
    printf '  %s$%s tee %s <<EOF  { server: %s, server_port: %s, method: %s, password: **** }\n' \
      "$C_INFO" "$C_RESET" "$CONFIG_FILE" "$SERVER_ADDR" "$PORT" "$METHOD"
    return 0
  fi
  cat >"$CONFIG_FILE" <<EOF
{
    "server": ${SERVER_ADDR},
    "server_port": ${PORT},
    "password": "${pw}",
    "method": "${METHOD}",
    "timeout": ${TIMEOUT},
    "mode": "tcp_and_udp",
    "fast_open": false
}
EOF
  chmod 600 "$CONFIG_FILE"
  # 语义校验：JSON 不合法时立刻失败，避免"改完重启才发现起不来"
  python3 -m json.tool <"$CONFIG_FILE" >/dev/null || die "配置文件 JSON 校验失败"
  ok "配置校验通过"
}

main() {
  validate_port "$PORT"
  require_root

  if [[ -z "$PASSWORD" ]]; then
    PASSWORD="$(gen_password)"
    info "未提供 --password，已随机生成密码（仅本次输出，请妥善保存）"
  fi
  [[ ${#PASSWORD} -ge 12 ]] || warn "密码长度不足 12 位，建议使用更长的随机密码。"

  info "安装 shadowsocks-libev（Debian/Ubuntu 官方源）"
  run apt-get update
  run apt-get install -y shadowsocks-libev

  write_config "$PASSWORD"

  info "启用并启动服务"
  run systemctl enable shadowsocks-libev
  run systemctl restart shadowsocks-libev

  if [[ "$MODE" != "dry-run" ]]; then
    sleep 1
    systemctl is-active --quiet shadowsocks-libev && ok "服务运行中" || die "服务未启动，请执行：journalctl -u shadowsocks-libev -n 50"
    ss -tlnp 2>/dev/null | grep -q ":${PORT}" && ok "端口 ${PORT} 正在监听" || warn "未检测到端口 ${PORT} 监听，请检查日志"
  fi

  if [[ "$OPEN_FIREWALL" == "yes" ]]; then
    run ufw allow "${PORT}/tcp"
    run ufw allow "${PORT}/udp"
    warn "云服务商安全组同样需要放行 ${PORT}（TCP+UDP）。"
  fi

  local host="${HOST_HINT:-<SERVER_IP>}"
  info "客户端配置参数（含敏感信息，请勿外发或截图）："
  printf '       服务器  : %s\n       端口    : %s\n       密码    : %s\n       加密    : %s\n' \
    "$host" "$PORT" "$PASSWORD" "$METHOD"

  if command -v python3 >/dev/null 2>&1 && [[ "$host" != "<SERVER_IP>" ]]; then
    local uri
    uri="$(python3 "$(dirname "$0")/ss-uri.py" --host "$host" --port "$PORT" --method "$METHOD" --password "$PASSWORD" --tag "vps-node")"
    printf '       分享链接: %s\n' "$uri"
  else
    printf '       生成分享链接: ./scripts/ss-uri.py --host %s --port %s --method %s --password <密码> --tag my-node\n' \
      "$host" "$PORT" "$METHOD"
  fi

  ok "完成。验证命令：./scripts/04-verify-connectivity.sh --socks5 127.0.0.1:1080"
}

main "$@"
