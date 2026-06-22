#!/usr/bin/env bash
set -euo pipefail

echo "=== SSH Safe Port Switch ==="

read -rp "输入新 SSH 端口 (1024-65535): " SSH_PORT

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "❌ 端口不合法"
    exit 1
fi

# 1. 禁用 systemd socket（防止 22 复活）
echo "✔ 禁用 ssh.socket..."
systemctl disable --now ssh.socket sshd.socket 2>/dev/null || true
systemctl mask ssh.socket sshd.socket 2>/dev/null || true

# 2. 注释所有配置文件中的 Port 残留
echo "✔ 注释残留 Port 指令..."
find /etc/ssh -type f \( -name "sshd_config" -o -name "*.conf" \) \
  -exec sed -i 's/^[[:space:]]*Port[[:space:]]\+/#Port /' {} \;

# 3. 确保 Include 存在
grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config || \
  echo 'Include /etc/ssh/sshd_config.d/*.conf' >> /etc/ssh/sshd_config

# 4. 写入新配置
echo "✔ 写入新配置..."
install -d /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/90-ss.conf << EOF
Port $SSH_PORT
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
EOF

# 5. 语法检查
echo "✔ 检查配置语法..."
sshd -t

# 6. Reload（不断当前连接）
echo "⚠️  开始 reload，当前连接不受影响..."
systemctl reload ssh 2>/dev/null || systemctl reload sshd

echo ""
echo "=============================="
echo "请保持当前窗口不要关闭！"
echo "新开终端测试连接："
echo "  ssh -p $SSH_PORT root@你的IP"
echo "=============================="
echo ""

read -rp "是否确认新端口可登录？(yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "❌ 回滚配置..."

    # 恢复主配置中的 Port 22
    sed -i 's/^#Port .*$/Port 22/' /etc/ssh/sshd_config

    # 删除 drop-in
    rm -f /etc/ssh/sshd_config.d/90-ss.conf

    # 恢复 socket
    systemctl unmask ssh.socket sshd.socket 2>/dev/null || true
    systemctl enable --now ssh.socket 2>/dev/null || true

    systemctl reload ssh 2>/dev/null || systemctl reload sshd

    echo "✔ 已回滚到 22 端口"
    exit 1
fi

# 7. 验证
echo ""
echo "===== Effective Config ====="
sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication)'

echo "===== Listening Ports ====="
ss -tlnp | grep sshd

echo ""
echo "✔ 已安全切换到端口 $SSH_PORT"
