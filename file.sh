# ── 4. 参数或交互输入 ────────────────────────────────────
# ...（保持你原有的第 4 步代码不变）...

# ── 🌟 新增：提前精密赋予执行权限（为第 5 步策略 A 铺路） ──
echo "⚙️ 正在预设源码执行权限..."
find "$SRC_DIR/$PROJECT" -type f \( -name "*.sh" -o -name "*.py" -o ! -name "*.*" \) -exec chmod +x {} \;

# ── 5. ⚙️ 高精度自动检测主命令 ─────────────────────────────
# 此时策略 A 去找 -executable，就能完美、精准地把刚变绿的 fw.sh 或者是未来的二进制主程序揪出来了！
AUTO_BIN=$(find "$SRC_DIR/$PROJECT" \
# ...（保持你原有的第 5 步代码不变）...

# ── 6. 安装（安全原子替换）───────────────────────────────
INSTALL_DIR="/opt/$PROJECT"
NEW_DIR="${INSTALL_DIR}.new"

echo "🚀 开始安装 $PROJECT 到 $INSTALL_DIR ..."
rm -rf "$NEW_DIR"
mkdir -p "$NEW_DIR"

# 复制文件并保持属性（因为上面已经加过权限，cp -a 会把完美的权限一起带过去）
cp -a "$SRC_DIR/$PROJECT/." "$NEW_DIR/"

# 💡 这一行可以放心地删掉了，因为权限已经在源头处理完美了！
# find "$NEW_DIR" -type f \( -name "*.sh" ... \) -exec chmod +x {} \;
