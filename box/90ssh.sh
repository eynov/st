#!/usr/bin/env bash
set -euo pipefail

echo "=== SSH Single-Port Safe Switch ==="

read -rp "输入新 SSH 端口 (1024-65535): " SSH_PORT

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || \
   [ "$SSH_PORT" -lt 1024 ] || \
   [ "$SSH_PORT" -gt 65535 ]; then
    echo "❌ 端口不合法"
    exit 1
fi

# 1. 预检查端口占用
echo "✔ 预检查端口占用..."
ss -tln | grep -q ":$SSH_PORT " && {
    echo "❌ 端口 $SSH_PORT 已被占用"
    exit 1
}

# 2. 检测 socket 模式
HAS_SOCKET=false
if systemctl is-enabled ssh.socket &>/dev/null && \
   systemctl is-active ssh.socket &>/dev/null; then
    HAS_SOCKET=true
fi
echo "✔ Socket 模式: $HAS_SOCKET"

# 3. 注释所有残留 Port 指令
echo "✔ 注释残留 Port 指令..."
find /etc/ssh -type f \( -name "sshd_config" -o -name "*.conf" \) \
  -exec sed -i 's/^[[:space:]]*Port[[:space:]]\+/#Port /' {} \;

# 4. 确保 Include 存在
grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' \
  /etc/ssh/sshd_config || \
  echo 'Include /etc/ssh/sshd_config.d/*.conf' >> /etc/ssh/sshd_config

# 5. 写入唯一 drop-in 配置
echo "✔ 写入新配置..."
install -d /etc/ssh/sshd_config.d
rm -f /etc/ssh/sshd_config.d/99-single-port.conf
cat > /etc/ssh/sshd_config.d/99-single-port.conf << EOF
Port $SSH_PORT
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
EOF

# 6. 根据 socket 模式处理
if $HAS_SOCKET; then
    echo "✔ 通过 socket override 修改监听端口..."
    mkdir -p /etc/systemd/system/ssh.socket.d/
    cat > /etc/systemd/system/ssh.socket.d/override.conf << EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:$SSH_PORT
ListenStream=[::]:$SSH_PORT
Accept=no
EOF
    systemctl daemon-reload
else
    echo "✔ sshd 直接管理端口..."
    systemctl disable --now ssh.socket sshd.socket 2>/dev/null || true
    systemctl daemon-reload
fi

# 7. 语法检查
echo "✔ 检查配置语法..."
sshd -t || {
    echo "❌ sshd 配置语法错误，中止"
    exit 1
}

# 8. 停止旧服务 + 清除 failed 状态 + 重启
echo "⚠️  重启 SSH 服务..."
systemctl stop ssh.service ssh.socket 2>/dev/null || true
systemctl reset-failed ssh.socket 2>/dev/null || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd
sleep 1

# 9. 验证监听
echo ""
echo "===== Effective Config ====="
sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication)'

echo "===== Listening Ports ====="
ss -H -tlnp "sport = :$SSH_PORT" | grep sshd || {
    echo "❌ 端口 $SSH_PORT 未监听，自动回滚..."
    rm -f /etc/ssh/sshd_config.d/99-single-port.conf
    rm -f /etc/systemd/system/ssh.socket.d/override.conf
    sed -i 's/^#Port .*$/Port 22/' /etc/ssh/sshd_config
    systemctl daemon-reload
    systemctl enable --now ssh.socket 2>/dev/null || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
    echo "✔ 已回滚到 22 端口"
    exit 1
}

# 10. 回滚函数
do_rollback() {
    rm -f /etc/ssh/sshd_config.d/99-single-port.conf
    rm -f /etc/systemd/system/ssh.socket.d/override.conf

    if $HAS_SOCKET; then
        systemctl daemon-reload
        systemctl stop ssh.service ssh.socket 2>/dev/null || true
        systemctl reset-failed ssh.socket 2>/dev/null || true
        systemctl restart ssh.socket
    else
        sed -i 's/^#Port .*$/Port 22/' /etc/ssh/sshd_config
        systemctl daemon-reload
        systemctl enable --now ssh.socket 2>/dev/null || true
    fi

    systemctl restart ssh 2>/dev/null || systemctl restart sshd
}

# 11. 启动自动回滚计时器（后台）
echo ""
echo "⏳ 启动安全回滚计时器（120秒）..."
(
    sleep 120
    echo ""
    echo "⚠️  超时未确认，自动回滚 SSH..."
    do_rollback
    echo "✔ 已自动回滚到 22 端口"
) &
ROLLBACK_PID=$!

echo ""
echo "=============================="
echo "⚠️  请保持当前窗口不要关闭！"
echo "新开终端测试连接："
echo "  ssh -p $SSH_PORT root@你的IP"
echo "=============================="
echo ""

read -rp "是否确认新端口可登录？(yes/no): " CONFIRM

# 取消计时器
kill $ROLLBACK_PID 2>/dev/null && echo "✔ 已取消自动回滚计时器" || true

if [[ "$CONFIRM" != "yes" ]]; then
    echo "❌ 手动回滚配置..."
    do_rollback
    echo "✔ 已回滚到 22 端口"
    exit 1
fi

echo ""
echo "✔ SSH 已成功切换为单端口模式：$SSH_PORT"
