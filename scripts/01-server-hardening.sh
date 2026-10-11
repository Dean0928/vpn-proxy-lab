#!/usr/bin/env bash
#
# 01-server-hardening.sh — Debian/Ubuntu 服务器初始化与 SSH 加固
#
# 设计原则：
#   * 默认只做 dry-run（打印将要执行的动作，不改动系统）
#   * 幂等：重复执行不会破坏已有配置
#   * 任何系统改动前都要求显式 --apply 并二次确认
#
# 用法：
#   ./01-server-hardening.sh --dry-run                     # 预览（默认）
#   sudo ./01-server-hardening.sh --apply                  # 实际执行
#   sudo ./01-server-hardening.sh --apply --ssh-port 22022 --user ops --pubkey ~/.ssh/id_ed25519.pub
#
set -euo pipefail

MODE="dry-run"
SSH_PORT="22"
NEW_USER=""
PUBKEY=""
TIMEZONE="UTC"
ENABLE_UFW="yes"
ENABLE_FAIL2BAN="yes"

# ---------- 输出工具 ----------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi
info() { printf '%s[INFO]%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK"   "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$C_ERR"  "$C_RESET" "$*" >&2; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      MODE="dry-run"; shift ;;
    --apply)        MODE="apply"; shift ;;
    --ssh-port)     SSH_PORT="${2:?--ssh-port 需要参数}"; shift 2 ;;
    --user)         NEW_USER="${2:?--user 需要参数}"; shift 2 ;;
    --pubkey)       PUBKEY="${2:?--pubkey 需要参数}"; shift 2 ;;
    --timezone)     TIMEZONE="${2:?--timezone 需要参数}"; shift 2 ;;
    --no-ufw)       ENABLE_UFW="no"; shift ;;
    --no-fail2ban)  ENABLE_FAIL2BAN="no"; shift ;;
    -h|--help)      usage ;;
    *)              die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

if [[ "$MODE" == "dry-run" ]]; then
  warn "当前为 dry-run 模式，不会改动系统。加 --apply 才会真正执行。"
fi

# ---------- 执行包装：dry-run 时只打印 ----------
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
}

require_linux() {
  [[ "$MODE" == "dry-run" ]] && return 0
  [[ "$(uname -s)" == "Linux" ]] || die "本脚本仅支持 Linux（Debian/Ubuntu）。"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      debian|ubuntu) ok "检测到系统：${PRETTY_NAME:-$ID}" ;;
      *) die "仅支持 Debian/Ubuntu，当前为 ${ID:-unknown}。" ;;
    esac
  fi
}

confirm() {
  [[ "$MODE" == "dry-run" ]] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "用户取消。"
}

# ---------- 步骤 ----------
step_update() {
  info "步骤 1/6：更新软件源并安装基础工具"
  run apt-get update
  run apt-get install -y --no-install-recommends ca-certificates curl sudo ufw fail2ban
}

step_user() {
  local user="$1" pubkey="$2"
  info "步骤 2/6：创建管理用户 ${user} 并写入 SSH 公钥"
  if id "$user" >/dev/null 2>&1; then
    ok "用户 ${user} 已存在，跳过创建"
  else
    run adduser --disabled-password --gecos "" "$user"
    run usermod -aG sudo "$user"
  fi
  [[ -n "$pubkey" ]] || { warn "未提供 --pubkey，跳过公钥写入（正式环境务必配置密钥登录）"; return 0; }
  [[ -f "$pubkey" ]] || die "找不到公钥文件：$pubkey"
  run install -d -m 700 -o "$user" -g "$user" "/home/${user}/.ssh"
  if [[ "$MODE" == "dry-run" ]]; then
    printf '  %s$%s install -m 600 %s /home/%s/.ssh/authorized_keys\n' "$C_INFO" "$C_RESET" "$pubkey" "$user"
  else
    install -m 600 -o "$user" -g "$user" "$pubkey" "/home/${user}/.ssh/authorized_keys"
  fi
}

step_sshd() {
  local port="$1"
  info "步骤 3/6：加固 sshd（端口 ${port}，禁用 root 直登与密码认证）"
  [[ "$MODE" == "dry-run" ]] || install -d -m 755 /etc/ssh/sshd_config.d
  if [[ "$MODE" == "dry-run" ]]; then
    printf '  %s$%s tee /etc/ssh/sshd_config.d/99-hardening.conf <<EOF\n' "$C_INFO" "$C_RESET"
    printf '        Port %s\n        PermitRootLogin no\n        PasswordAuthentication no\n' "$port"
    printf '        PubkeyAuthentication yes\n        MaxAuthTries 3\n        LoginGraceTime 20\n        EOF\n'
  else
    cat >/etc/ssh/sshd_config.d/99-hardening.conf <<EOF
# 由 vpn-proxy-lab/scripts/01-server-hardening.sh 生成
Port ${port}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 20
EOF
  fi
  run sshd -t
  run systemctl reload ssh
  warn "请保持当前会话不要断开，另开一个终端验证新配置可登录后再关闭本会话！"
}

step_ufw() {
  local port="$1"
  info "步骤 4/6：配置 ufw 防火墙"
  [[ "$ENABLE_UFW" == "yes" ]] || { warn "已通过 --no-ufw 跳过"; return 0; }
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow "${port}/tcp"
  run ufw --force enable
  run ufw status numbered
  warn "别忘了在云服务商控制台的安全组中同样放行端口 ${port}。"
}

step_fail2ban() {
  local port="$1"
  info "步骤 5/6：配置 fail2ban 防暴力破解"
  [[ "$ENABLE_FAIL2BAN" == "yes" ]] || { warn "已通过 --no-fail2ban 跳过"; return 0; }
  if [[ "$MODE" == "dry-run" ]]; then
    printf '  %s$%s tee /etc/fail2ban/jail.local <<EOF  (sshd, port=%s, maxretry=3)\n' "$C_INFO" "$C_RESET" "$port"
  else
    cat >/etc/fail2ban/jail.local <<EOF
[sshd]
enabled  = true
port     = ${port}
maxretry = 3
bantime  = 1h
findtime = 10m
EOF
  fi
  run systemctl enable --now fail2ban
}

step_misc() {
  local tz="$1"
  info "步骤 6/6：时区与自动安全更新"
  run timedatectl set-timezone "$tz"
  run apt-get install -y unattended-upgrades
  if [[ "$MODE" == "dry-run" ]]; then
    printf '  %s$%s dpkg-reconfigure -f noninteractive unattended-upgrades\n' "$C_INFO" "$C_RESET"
  else
    dpkg-reconfigure -f noninteractive unattended-upgrades
  fi
}

main() {
  info "服务器初始化与加固（模式：${MODE}）"
  require_root
  require_linux
  if [[ -n "$NEW_USER" ]]; then
    confirm "即将创建用户 ${NEW_USER} 并加固 SSH（端口 ${SSH_PORT}），继续？"
  else
    confirm "即将加固 SSH（端口 ${SSH_PORT}，禁用密码登录），继续？"
  fi
  step_update
  [[ -n "$NEW_USER" ]] && step_user "$NEW_USER" "$PUBKEY"
  [[ -n "$NEW_USER" ]] || warn "未指定 --user，跳过创建管理用户（不建议用 root 长期运维）"
  step_sshd "$SSH_PORT"
  step_ufw "$SSH_PORT"
  step_fail2ban "$SSH_PORT"
  step_misc "$TIMEZONE"
  ok "完成。接着可以执行：sudo ./scripts/02-install-shadowsocks.sh"
}

main "$@"
