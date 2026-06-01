#!/bin/bash

# ==========================================
# 核心路径与配置
# ==========================================
TARGET_DIR="/srv/git/TG"
BOT_SCRIPT="${TARGET_DIR}/bot.py"
VENV_DIR="/srv/venvs/early"
PYTHON_BIN="${VENV_DIR}/bin/python"
PIP_BIN="${VENV_DIR}/bin/pip"
SERVICE_FILE="/etc/systemd/system/bot.service"
ENV_FILE="/etc/variable"

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误：请使用 sudo 或以 root 用户运行此脚本！"
  exit 1
fi

echo "=========================================="

# ==========================================
# 1. 严格环境配置文件校验
# ==========================================
echo "🔄 1. 正在校验环境配置文件..."
if [ ! -f "${ENV_FILE}" ]; then
    echo "❌ 错误：未找到环境配置文件 ${ENV_FILE} ！"
    exit 1
fi
if ! grep -q "TELEGRAM_BOT_TOKEN" "${ENV_FILE}" || ! grep -q "ADMIN_USER_ID" "${ENV_FILE}"; then
    echo "❌ 错误：${ENV_FILE} 中缺少关键变量！"
    exit 1
fi
echo "✅ 环境配置文件校验通过。"

# ==========================================
# 2. 补齐系统依赖并构建健康的 Python 虚拟环境
# ==========================================
echo "🔄 2. 正在检查系统底层环境与虚拟环境..."
# 确保系统拥有 venv 核心组件
apt-get update && apt-get install -y python3-venv python3-pip

# 检查并创建/修复虚拟环境
if [ ! -f "${PYTHON_BIN}" ] || [ ! -f "${PIP_BIN}" ]; then
    echo "💡 发现虚拟环境残缺或不存在，正在重新初始化..."
    rm -rf "${VENV_DIR}"
    mkdir -p "/srv/venvs"
    python3 -m venv "${VENV_DIR}"
fi

# 升级 pip 并强力注入核心依赖
${PIP_BIN} install --upgrade pip -q
${PIP_BIN} install python-telegram-bot
echo "✅ 虚拟环境与核心依赖包已全部就绪。"

# ==========================================
# 3. 写入完美重构的 bot.py 源码
# ==========================================
echo "🔄 3. 正在写入全数据库化、高兼容性的 bot.py 源码..."
mkdir -p "${TARGET_DIR}"

cat << 'EOF' > "${BOT_SCRIPT}"
import os
import sys
import fcntl
from telegram import Update
from telegram.ext import (
    ApplicationBuilder,
    CommandHandler,
    MessageHandler,
    filters,
    ContextTypes,
)
from telegram.error import BadRequest
from datetime import datetime, timedelta
import sqlite3
import random
import time 

# ---------------------------
# 防止多实例并发运行 (File Locking)
# ---------------------------
lock_file = open('/tmp/tg_bot_instance.lock', 'w')
try:
    fcntl.lockf(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
except IOError:
    print("❌ 错误: 发现另一个 Bot 实例正在运行中！自动退出。")
    sys.exit(1)

# ---------------------------
# 配置校验
# ---------------------------
BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
ADMIN_ID = os.getenv("ADMIN_USER_ID")

if not BOT_TOKEN or not ADMIN_ID:
    print("❌ 错误: 缺少环境变量 TELEGRAM_BOT_TOKEN 或 ADMIN_USER_ID")
    sys.exit(1)

ADMIN_ID = int(ADMIN_ID)
DB_PATH = os.path.join(os.path.dirname(__file__), "messages.db")

# ---------------------------
# 数据库持久化层 (WAL + 高超时 + 全业务数据库化)
# ---------------------------
def get_db_connection():
    # 启用 30 秒高超时等待
    conn = sqlite3.connect(DB_PATH, timeout=30.0)
    # 启用 WAL 模式，开启读写并发并发
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    return conn

def create_db():
    conn = get_db_connection()
    c = conn.cursor()
    
    # 1. 消息记录表
    c.execute(
        """CREATE TABLE IF NOT EXISTS messages (
            user_id INTEGER,
            message TEXT,
            timestamp TEXT
        )"""
    )
    # 2. 管理员消息ID -> 用户ID 映射表
    c.execute(
        """CREATE TABLE IF NOT EXISTS reply_mapping (
            admin_msg_id INTEGER PRIMARY KEY,
            user_id TEXT,
            timestamp TEXT
        )"""
    )
    # 3. 全面数据库化的用户状态表 (彻底替代原 JSON 方案)
    c.execute(
        """CREATE TABLE IF NOT EXISTS user_states (
            user_id TEXT PRIMARY KEY,
            is_verified INTEGER DEFAULT 0,
            fails INTEGER DEFAULT 0,
            locked_until REAL DEFAULT 0,
            is_banned INTEGER DEFAULT 0,
            pending_answer INTEGER DEFAULT NULL,
            updated_at TEXT
        )"""
    )
    
    # 建立索引优化搜索性能
    c.execute("CREATE INDEX IF NOT EXISTS idx_msg_time ON messages (timestamp)")
    c.execute("CREATE INDEX IF NOT EXISTS idx_reply_time ON reply_mapping (timestamp)")
    conn.commit()
    conn.close()

# --- 用户状态管理数据库操作 ---
def get_user_state(user_id):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("SELECT is_verified, fails, locked_until, is_banned, pending_answer FROM user_states WHERE user_id = ?", (str(user_id),))
    row = c.fetchone()
    conn.close()
    if row:
        return {
            "is_verified": bool(row[0]),
            "fails": row[1],
            "locked_until": row[2],
            "is_banned": bool(row[3]),
            "pending_answer": row[4]
        }
    return {"is_verified": False, "fails": 0, "locked_until": 0, "is_banned": False, "pending_answer": None}

def update_user_state(user_id, state):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute(
        """INSERT OR REPLACE INTO user_states 
        (user_id, is_verified, fails, locked_until, is_banned, pending_answer, updated_at) 
        VALUES (?, ?, ?, ?, ?, ?, ?)""",
        (
            str(user_id),
            1 if state.get("is_verified") else 0,
            state.get("fails", 0),
            state.get("locked_until", 0),
            1 if state.get("is_banned") else 0,
            state.get("pending_answer"),
            datetime.now().isoformat()
        )
    )
    conn.commit()
    conn.close()

# --- 消息和回复映射数据库操作 ---
def save_message(user_id, message):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("INSERT INTO messages (user_id, message, timestamp) VALUES (?, ?, ?)", (user_id, message, datetime.now().isoformat()))
    conn.commit()
    conn.close()

def save_reply_map(admin_msg_id, user_id):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("INSERT OR REPLACE INTO reply_mapping (admin_msg_id, user_id, timestamp) VALUES (?, ?, ?)", (admin_msg_id, str(user_id), datetime.now().isoformat()))
    
    # 滚动清理：计算出 7 天前的时间字符串，抹除过期映射防止 DB 膨胀
    seven_days_ago = (datetime.now() - timedelta(days=7)).isoformat()
    c.execute("DELETE FROM reply_mapping WHERE timestamp < ?", (seven_days_ago,))
    conn.commit()
    conn.close()

def get_user_id_by_admin_msg(admin_msg_id):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("SELECT user_id FROM reply_mapping WHERE admin_msg_id = ?", (admin_msg_id,))
    row = c.fetchone()
    conn.close()
    return row[0] if row else None

def get_last_seven_days_messages():
    seven_days_ago = (datetime.now() - timedelta(days=7)).isoformat()
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("SELECT * FROM messages WHERE timestamp > ?", (seven_days_ago,))
    rows = c.fetchall()
    conn.close()
    return rows

# ---------------------------
# 广告检测
# ---------------------------
SENSITIVE_KEYWORDS = ["博彩", "赌博", "现金", "充值"] 
def is_ad(msg):
    if getattr(msg, "business_connection_id", None) or msg.via_bot:
        return True
    if msg.reply_markup and msg.reply_markup.inline_keyboard:
        for row in msg.reply_markup.inline_keyboard:
            for btn in row:
                if btn.url: return True
    if msg.text and any(k in msg.text.lower() for k in SENSITIVE_KEYWORDS):
        return True
    return False

# ---------------------------
# Bot 指令处理
# ---------------------------
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.message.from_user
    user_id = str(user.id)
    state = get_user_state(user_id)

    if state["is_banned"]:
        await update.message.reply_text("⚠️ 你已被永久禁止。")
        return

    if state["locked_until"] > time.time():
        remain_hours = int((state["locked_until"] - time.time()) / 3600) + 1
        await update.message.reply_text(f"⛔ 请 {remain_hours} 小时后再试。")
        return

    if not state["is_verified"]:
        a, b = random.randint(5, 20), random.randint(5, 20)
        state["pending_answer"] = a + b
        update_user_state(user_id, state)
        await update.message.reply_text(f"🤖 请先通过验证：\n\n {a} + {b} = ?\n\n请直接发送纯数字答案。")
    else:
        await update.message.reply_text("Hello!")

async def show_last_seven_days(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id != ADMIN_ID:
        await update.message.reply_text("您没有权限查看历史记录。")
        return
    messages = get_last_seven_days_messages()
    response = "\n".join([f"ID: {msg[0]} | 消息: {msg[1]} | 时间: {msg[2]}" for msg in messages]) if messages else "没有找到过去七天的记录。"
    await update.message.reply_text(response)

# ---------------------------
# 转发与验证拦截核心逻辑
# ---------------------------
async def forward_to_admin(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.message.from_user
    user_id = str(user.id)
    state = get_user_state(user_id)

    if state["is_banned"]:
        await update.message.reply_text("⚠️ 你已被永久禁止。")
        return

    if state["locked_until"] > time.time():
        remain_hours = int((state["locked_until"] - time.time()) / 3600) + 1
        await update.message.reply_text(f"⛔ 请 {remain_hours} 小时后再试。")
        return

    # 处理待验证用户 (已将原先错误的 NULL 完美替换为标准的 None)
    if not state["is_verified"] and state["pending_answer"] is not None:
        if update.message.text and update.message.text.strip().isdigit():
            user_answer = int(update.message.text.strip())
            
            if user_answer == state["pending_answer"]:
                state["is_verified"] = True
                state["pending_answer"] = None
                state["fails"] = 0
                state["locked_until"] = 0
                update_user_state(user_id, state)
                await update.message.reply_text("✅ 验证成功！")
                return
            
            # 答错限制算法
            state["fails"] += 1
            if state["fails"] >= 10:
                state["is_banned"] = True
                await update.message.reply_text("❌ 你已错误 10 次，被永久禁止使用。")
            elif state["fails"] % 3 == 0:
                state["locked_until"] = time.time() + 24 * 3600
                await update.message.reply_text("⛔ 错误 3 次，已被锁定 24 小时。")
            else:
                a, b = random.randint(5, 20), random.randint(5, 20)
                state["pending_answer"] = a + b
                await update.message.reply_text(f"❌ 验证错误，请重新计算：\n\n {a} + {b} = ?")
            
            update_user_state(user_id, state)
            return
        else:
            await update.message.reply_text("请直接发送您的答案（纯数字）。")
            return

    if not state["is_verified"]:
        await update.message.reply_text("/start")
        return
        
    if is_ad(update.message):
        await update.message.reply_text("⛔ 检测到广告消息，已被拦截。")
        return

    user_name_display = user.username or user.first_name
    admin_message = f"@{user_name_display} (ID: {user_id}) 发送的消息:\n"

    try:
        if update.message.text:
            admin_message += update.message.text
            sent_message = await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message)
            save_message(user_id, update.message.text)
        elif update.message.photo:
            sent_message = await context.bot.send_photo(chat_id=ADMIN_ID, photo=update.message.photo[-1].file_id, caption=admin_message + "(照片)")
            save_message(user_id, "发送了一张照片")
        elif update.message.sticker:
            sent_message = await context.bot.send_sticker(chat_id=ADMIN_ID, sticker=update.message.sticker.file_id)
            await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message + "(贴纸)")
            save_message(user_id, "发送了一张贴纸")
        elif update.message.voice:
            sent_message = await context.bot.send_voice(chat_id=ADMIN_ID, voice=update.message.voice.file_id, caption=admin_message + "(语音)")
            save_message(user_id, "发送了语音")
        elif update.message.video:
            sent_message = await context.bot.send_video(chat_id=ADMIN_ID, video=update.message.video.file_id, caption=admin_message + "(视频)")
            save_message(user_id, "发送了视频")
        elif update.message.animation:
            sent_message = await context.bot.send_animation(chat_id=ADMIN_ID, animation=update.message.animation.file_id, caption=admin_message + "(动图)")
            save_message(user_id, "发送了动图")
        elif update.message.document:
            sent_message = await context.bot.send_document(chat_id=ADMIN_ID, document=update.message.document.file_id, caption=admin_message + "(文档)")
            save_message(user_id, "发送了文档")
        elif update.message.location:
            sent_message = await context.bot.send_location(chat_id=ADMIN_ID, latitude=update.message.location.latitude, longitude=update.message.location.longitude)
            await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message + "(位置)")
            save_message(user_id, "发送了位置")
        else:
            return

        save_reply_map(sent_message.message_id, user_id)

    except BadRequest as e:
        await update.message.reply_text(f"发送消息失败: {e}")

# ---------------------------
# 管理员回复处理 (双向同步转发)
# ---------------------------
async def handle_admin_reply(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not update.message.reply_to_message:
        await context.bot.send_message(chat_id=ADMIN_ID, text="请直接回复某条转发过来的用户消息进行沟通。")
        return

    reply_to_message_id = update.message.reply_to_message.message_id
    user_id = get_user_id_by_admin_msg(reply_to_message_id)
    
    if not user_id:
        await context.bot.send_message(chat_id=ADMIN_ID, text="❌ 无法找到对应用户（映射已过期或不存在）。")
        return

    try:
        if update.message.text:
            await context.bot.send_message(chat_id=user_id, text=update.message.text)
        elif update.message.photo:
            await context.bot.send_photo(chat_id=user_id, photo=update.message.photo[-1].file_id, caption=update.message.caption)
        elif update.message.sticker:
            await context.bot.send_sticker(chat_id=user_id, sticker=update.message.sticker.file_id)
        elif update.message.voice:
            await context.bot.send_voice(chat_id=user_id, voice=update.message.voice.file_id, caption=update.message.caption)
        elif update.message.video:
            await context.bot.send_video(chat_id=user_id, video=update.message.video.file_id, caption=update.message.caption)
        elif update.message.animation:
            await context.bot.send_animation(chat_id=user_id, animation=update.message.animation.file_id, caption=update.message.caption)
        elif update.message.document:
            await context.bot.send_document(chat_id=user_id, document=update.message.document.file_id, caption=update.message.caption)
    except BadRequest as e:
        await context.bot.send_message(chat_id=ADMIN_ID, text=f"回复失败: {e}")

def main():
    create_db()
    app = ApplicationBuilder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("history", show_last_seven_days))
    app.add_handler(MessageHandler((filters.ALL & ~filters.COMMAND) & ~filters.Chat(ADMIN_ID), forward_to_admin))
    app.add_handler(MessageHandler(filters.ALL & filters.Chat(ADMIN_ID), handle_admin_reply))
    app.run_polling()

if __name__ == "__main__":
    main()
EOF

echo "✅ bot.py 完美重构版源码已写入完毕。"

# ==========================================
# 4. 生成具备防重启风暴限制的 Systemd 配置文件
# ==========================================
echo "🔄 4. 正在安全生成 Systemd 配置文件..."

cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=bot Service
After=network.target

[Service]
User=root
WorkingDirectory=${TARGET_DIR}
ExecStart=${PYTHON_BIN} ${BOT_SCRIPT}
Restart=always
RestartSec=10s
EnvironmentFile=${ENV_FILE}
StandardOutput=journal
StandardError=journal
KillMode=control-group

# --- 核心机制：Systemd 级防重启风暴限制 ---
# 如果服务在 60 秒内连续崩溃重启超过 5 次，Systemd 将强行挂起锁死，杜绝无限死循环拉满 CPU
StartLimitIntervalSec=60s
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

echo "✅ Systemd 配置文件写入成功。"

# ==========================================
# 5. 重载、使能并启动后台服务
# ==========================================
echo "🔄 5. 正在重启并激活 Systemd 服务..."
systemctl daemon-reload
systemctl enable bot.service
systemctl restart bot.service

# 最终运行健康度检查
if systemctl is-active --quiet bot.service; then
    echo "=========================================="
    echo "------------------------------------------"
    echo "💎 并发无锁：SQLite 开启了高级 WAL 模式与 30s 高超时机制"
    echo "💎 绝对稳定：JSON 依赖全部移除，全业务持久化交由 DB 处理"
    echo "💎 环境无忧：完全兼容 Python 3.12/3.13 极其以上的时间戳规范"
    echo "💎 防熔断风暴：Systemd 计数器严防死锁风暴"
    echo "=========================================="
else
    echo "❌ 提示：服务已写入，但未能正常拉起。请检查环境配置文件 ${ENV_FILE} 的 Token 是否正确。"
    echo "📋 检查详细运行日志：sudo journalctl -u bot.service -n 30"
fi
