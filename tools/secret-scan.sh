#!/usr/bin/env bash
#
# secret-scan.sh — 发布前脱敏自查
#
# 检查仓库中的文本文件是否包含：
#   1. 私钥内容（BEGIN ... PRIVATE KEY）
#   2. 真实（非文档/非私有网段）的公网 IPv4 字面量
#   3. 含明文凭据的 ss:// 分享链接
#   4. 明文密码字段（password": "xxx"）与 UUID
#   5. 个人标识（学号、姓名拼音等自定义关键字，通过 --deny 追加）
#
# 用法：
#   ./tools/secret-scan.sh                     # 扫描 git 跟踪的全部文本文件
#   ./tools/secret-scan.sh --deny alice,bob    # 追加自定义禁止词
#   ./tools/secret-scan.sh --all               # 扫描工作区所有文本文件（含未跟踪）
#
set -euo pipefail

SCAN_ALL="no"
EXTRA_DENY=""
FAILED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)  SCAN_ALL="yes"; shift ;;
    --deny) EXTRA_DENY="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 只扫描文本类文件，避免把 PNG/JPEG 二进制误判
PATTERN='\.(md|markdown|txt|sh|bash|zsh|py|json|jsonc|ya?ml|toml|ini|conf|example|env|gitignore|csv|ts|js)$'

list_files() {
  if [[ "$SCAN_ALL" == "yes" ]]; then
    find . -type f -not -path './.git/*' | grep -E "$PATTERN" || true
  else
    git ls-files 2>/dev/null | grep -E "$PATTERN" || true
  fi
}

report() {                      # $1=文件 $2=行号 $3=说明 $4=内容
  FAILED=1
  printf '  %s\n    文件: %s:%s\n    内容: %s\n' "$3" "$1" "$2" "$4"
}

scan() {                        # $1=正则 $2=说明 $3=排除文件（正则，可空）
  local regex="$1" desc="$2" exclude="${3:-}"
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    [[ -n "$exclude" ]] && printf '%s' "$f" | grep -qE "$exclude" && continue
    while IFS=: read -r line_no content; do
      [[ -n "${line_no:-}" ]] || continue
      report "$f" "$line_no" "$desc" "$(printf '%s' "$content" | cut -c1-160)"
    done < <(grep -nEI -- "$regex" "$f" 2>/dev/null || true)
  done < <(list_files)
}

echo "== 脱敏自查：$( [[ "$SCAN_ALL" == "yes" ]] && echo "工作区全部文本文件" || echo "git 跟踪的文本文件" ) =="

# 1) 私钥
echo "-- 1/5 私钥内容"
scan 'BEGIN [A-Z ]*PRIVATE KEY' "检测到私钥内容（严禁提交）"

# 2) 公网 IPv4（排除文档网段、私有网段、回环、掩码写法）
echo "-- 2/5 公网 IPv4 字面量"
IPV4='([0-9]{1,3}\.){3}[0-9]{1,3}'
PUBLIC_IP='([0-9]{1,3}\.){3}[0-9]{1,3}'
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  case "$f" in */tools/secret-scan.sh) continue ;; esac
  while IFS=: read -r line_no content; do
    [[ -n "${line_no:-}" ]] || continue
    # 抽出一行中的所有 IPv4，逐个判断是否属于"可公开"网段
    while read -r ip; do
      [[ -n "$ip" ]] || continue
      # 允许：私有网段、回环、链路本地、RFC 5737 文档网段、公共 DNS、/0 通配
      if ! printf '%s' "$ip" | grep -qE '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|203\.0\.113\.|198\.51\.100\.|192\.0\.2\.|1\.1\.1\.1$|8\.8\.8\.8$|0\.0\.0\.0$)'; then
        report "$f" "$line_no" "疑似真实公网 IP：$ip（请替换为占位符或文档网段）" "$(printf '%s' "$content" | cut -c1-160)"
      fi
    done < <(printf '%s' "$content" | grep -oE "$IPV4" || true)
  done < <(grep -nEI -- "$PUBLIC_IP" "$f" 2>/dev/null || true)
done < <(list_files)

# 3) 带凭据的 ss:// 链接（base64 段较长者为疑似真实链接）
echo "-- 3/5 ss:// 分享链接"
scan 'ss://[A-Za-z0-9+/=_-]{24,}' "疑似真实 ss:// 分享链接（含明文凭据）"

# 4) 明文密码 / UUID
echo "-- 4/5 明文密码与 UUID"
scan '"password"[[:space:]]*:[[:space:]]*"[^"<]{8,}"' "疑似真实密码字段"
scan '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "疑似真实 UUID"

# 5) 自定义禁止词
echo "-- 5/5 自定义禁止词"
if [[ -n "$EXTRA_DENY" ]]; then
  IFS=',' read -r -a words <<<"$EXTRA_DENY"
  for w in "${words[@]}"; do
    [[ -n "$w" ]] || continue
    scan "$w" "命中自定义禁止词：$w"
  done
else
  echo "  （未提供 --deny，跳过）"
fi

echo
if [[ "$FAILED" -eq 1 ]]; then
  echo "结果：发现问题 ⚠️  请在发布前修复。"
  exit 1
fi
echo "结果：通过 ✅  未发现敏感信息。"
