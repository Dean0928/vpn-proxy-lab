# 07 · 安全加固与合规声明

> 自建代理服务器一旦上线就暴露在公网扫描之下。**搭起来只是开始，守得住才算数。**

## 1. 合规与伦理（请先读这一节）

- 本项目仅用于**在自己拥有或已获得明确授权的服务器上**学习网络原理与系统运维；
- 请遵守你所在国家/地区的法律法规，以及云服务商的服务条款；
- 不要使用本项目从事任何侵入他人系统、窃取数据或规避法律监管的行为；
- 实验中的一切凭据（IP / 端口 / 密码 / UUID / 域名）在归档时**均已脱敏**，`configs/` 中只有占位符。

## 2. SSH 加固（第一优先级）

服务器 99% 的被入侵方式是**密码暴力破解**。

```bash
# 1) 使用密钥登录（本地生成，只上传公钥）
ssh-keygen -t ed25519 -C "vpn-lab"
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@<server>

# 2) 加固 /etc/ssh/sshd_config
PermitRootLogin no                  # 禁止 root 直接登录
PasswordAuthentication no           # 关闭密码认证
PubkeyAuthentication yes
Port 22022                          # 可选：改为高位端口，减少扫描噪音
MaxAuthTries 3
LoginGraceTime 20

# 3) 校验并重载（先校验！配置写错会把自己锁在门外）
sudo sshd -t && sudo systemctl reload ssh
```

> ⚠️ **务必保留一个已登录的会话不要断开**，直到确认新配置下能重新登录成功。

依赖 SSH 的初始化工作可以交给 [`scripts/01-server-hardening.sh`](../scripts/01-server-hardening.sh)（支持 `--dry-run`，默认不改动系统）。

## 3. 防火墙：最小暴露面

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22022/tcp          # 你的 SSH 端口
sudo ufw allow <代理端口>/tcp
sudo ufw allow <代理端口>/udp
sudo ufw enable
sudo ufw status numbered
```

要点：

- **只放行必要的端口**，不要 `ufw allow 1:65535`；
- 云服务商控制台的安全组/防火墙需要**单独放行**（两层都要开）；
- 定期 `ss -tlnp` 复查有没有意外监听的服务。

## 4. 自动封禁暴力破解

```bash
sudo apt install -y fail2ban
sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[sshd]
enabled  = true
port     = 22022
maxretry = 3
bantime  = 1h
findtime = 10m
EOF
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

## 5. 密钥与凭据管理

| 凭据 | 风险 | 做法 |
| --- | --- | --- |
| SSH 私钥 | 泄露 = 服务器完全失守 | 本地 `~/.ssh` 权限 600，加 passphrase，绝不入 Git |
| 代理密码 | 泄露 = 别人白用你的流量与 IP | 随机 ≥16 字符，定期轮换 |
| WireGuard 私钥 | 泄露 = 可冒充节点 | `umask 077` 生成，权限 600 |
| `ss://` 链接 | **等同于密码**（base64 内含明文） | 视为机密，不截图外发（本仓库截图中已打码） |
| UUID / Reality 密钥 | 泄露 = 可被滥用或指纹识别 | 进私有仓库，不进公开仓库 |

检查方式：

```bash
# 确认没有把私钥/凭据提交进仓库
git grep -nE '(BEGIN (RSA|OPENSSH|PRIVATE) KEY|ss://|password"\s*:\s*"[^"<]{8,})' $(git rev-list --all) -- . | head
```

本仓库的 CI 中也有同样的自动扫描。

## 6. 系统更新与最小服务

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades     # 自动安全更新

# 停用用不到的服务，减少攻击面
systemctl list-unit-files --state=enabled
```

## 7. 日志、监控与可观测性

```bash
# 服务可用性
systemctl is-active shadowsocks-libev
# 最近错误
journalctl -u shadowsocks-libev -p err --since "24 hours ago"
# 出口 IP 是否变化（节点被回收/切换时的典型症状）
curl -s --max-time 8 https://ipinfo.io/ip
```

建议把上述检查做成定时任务（`systemd timer` / `cron`），异常时邮件或 webhook 告警。

## 8. 发布归档前的脱敏清单

| 检查项 | 处理方式 |
| --- | --- |
| 服务器公网 IP | 全部替换为 `<SERVER_IP>` 或文档保留地址 |
| 端口号 | 替换为 `<PORT>` 或示例值 |
| 密码 / UUID / 密钥 | 一律删除，模板用占位符 |
| `ss://` 链接 | 删除（base64 解码即明文凭据） |
| 个人域名 | 打码或替换为 `example.com` |
| 系统用户名 | 截图打码 |
| 云服务商实例 ID | 截图打码 |
| 时间线中的地理位置 | 可保留国家/城市级别（不构成个人身份信息） |

本仓库的截图处理方式：[`tools/redact-images.py`](../tools/redact-images.py) 对每个敏感矩形区域做**像素化（马赛克）**，而不是简单涂色——像素化不可逆，且能一眼看出是刻意脱敏。

之所以把打码脚本也纳入版本管理，是为了让"脱敏"这件事**可审计、可复现**：

```bash
# 用打码脚本重新生成 images/，输出应与仓库中的文件逐字节一致
python3 tools/redact-images.py --source-dir <原始截图目录> --out-dir /tmp/check
shasum -a 256 /tmp/check/* images/*      # 哈希一致 = 脱敏过程与仓库内容完全对应
```
