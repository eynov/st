import os
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
import json
import random
import time # <-- 新增：用于处理时间锁

# ---------------------------
# 配置
# ---------------------------
BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
ADMIN_ID = os.getenv("ADMIN_USER_ID")

if not BOT_TOKEN:
    raise ValueError("请设置环境变量 TELEGRAM_BOT_TOKEN")
if not ADMIN_ID:
    raise ValueError("请设置环境变量 ADMIN_USER_ID")

ADMIN_ID = int(ADMIN_ID)

# ---------------------------
# 数据库初始化
# ---------------------------
def create_db():
    conn = sqlite3.connect("messages.db")
    c = conn.cursor()
    c.execute(
        """CREATE TABLE IF NOT EXISTS messages (
            user_id INTEGER,
            message TEXT,
            timestamp DATETIME
        )"""
    )
    conn.commit()
    conn.close()


def save_message(user_id, message):
    conn = sqlite3.connect("messages.db")
    c = conn.cursor()
    c.execute(
        "INSERT INTO messages (user_id, message, timestamp) VALUES (?, ?, ?)",
        (user_id, message, datetime.now()),
    )
    conn.commit()
    conn.close()


def get_last_seven_days_messages():
    seven_days_ago = datetime.now() - timedelta(days=7)
    conn = sqlite3.connect("messages.db")
    c = conn.cursor()
    c.execute("SELECT * FROM messages WHERE timestamp > ?", (seven_days_ago,))
    rows = c.fetchall()
    conn.close()
    return rows


# ---------------------------
# 用户验证文件
# ---------------------------
FAIL_FILE = "verify_fail.json"
VERIFIED_FILE = "verified_users.json"
PENDING_FILE = "pending_verification.json"

def load_json(path):
    if not os.path.exists(path):
        return {}
    with open(path, "r") as f:
        # 使用 str() 确保 key 是字符串，方便与 user_id 比较
        data = json.load(f)
        return {str(k): v for k, v in data.items()}

def save_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f)

def load_fail():
    if not os.path.exists(FAIL_FILE):
        return {}
    with open(FAIL_FILE, "r") as f:
        data = json.load(f)
        return {str(k): v for k, v in data.items()}

def save_fail(data):
    with open(FAIL_FILE, "w") as f:
        json.dump(data, f)

# 初始化加载数据
verify_fail = load_fail()
verified_users = load_json(VERIFIED_FILE)
pending_verification = load_json(PENDING_FILE)


# ---------------------------
# 广告检测
# ---------------------------
SENSITIVE_KEYWORDS = ["博彩", "赌博", "现金", "充值"] # 目前未使用，但保留
def is_ad(msg):
    if getattr(msg, "business_connection_id", None):
        return True
    if msg.via_bot:
        return True
    if msg.reply_markup and msg.reply_markup.inline_keyboard:
        for row in msg.reply_markup.inline_keyboard:
            for btn in row:
                if btn.url:
                    return True
    if msg.text:
        t = msg.text.lower()
        if any(keyword in t for keyword in SENSITIVE_KEYWORDS):
            return True
    # 如果要启用链接检测，可以解除注释以下代码
    # if msg.text:
    #     t = msg.text.lower()
    #     if any(x in t for x in ["http://", "https://", ".com", ".ru", ".top"]):
    #         return True
    return False

# ---------------------------
# Bot 命令
# ---------------------------
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.message.from_user
    user_id_str = str(user.id)
    
    # 1. 读取失败状态
    fail = verify_fail.get(user_id_str, {"fails": 0, "locked_until": 0, "banned": False})

    # 2. 永久封禁检查
    if fail.get("banned"):
        await update.message.reply_text("⚠️ 你已被永久禁止。")
        return

    # 3. 锁定检查
    if fail.get("locked_until", 0) > time.time():
        remain_seconds = int(fail["locked_until"] - time.time())
        # 向上取整到小时，至少显示1小时
        remain_hours = int(remain_seconds / 3600) + 1 if remain_seconds > 0 else 1
        await update.message.reply_text(f"⛔ 请 {remain_hours} 小时后再试。")
        return

    # 4. 验证检查
    if user_id_str not in verified_users:
        
        # 首次或重新生成数学题
        a = random.randint(5, 20)
        b = random.randint(5, 20)
        pending_verification[user_id_str] = {"answer": a + b}
        save_json(PENDING_FILE, pending_verification)
        
        # 提示用户进行验证
        await update.message.reply_text(f"🤖 请先通过验证：\n\n {a} + {b} = ?\n\n请直接发送答案。")
    
    else:
        # 已验证用户
        await update.message.reply_text("Hello!")

async def show_last_seven_days(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id == ADMIN_ID:
        messages = get_last_seven_days_messages()
        if messages:
            response = "\n".join(
                [f"用户 ID: {msg[0]} | 消息: {msg[1]} | 时间: {msg[2]}" for msg in messages]
            )
        else:
            response = "没有找到过去七天的记录。"
        await update.message.reply_text(response)
    else:
        await update.message.reply_text("您没有权限查看历史记录。")


# ---------------------------
# 核心：转发用户消息到管理员 + 数学验证回答检查 + 广告拦截
# ---------------------------
message_context_map = {}

async def forward_to_admin(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.message.from_user
    user_id = str(user.id)
    user_id_str = user_id

    # 读取失败状态
    fail = verify_fail.get(user_id_str, {"fails": 0, "locked_until": 0, "banned": False})

    # -------------------------
    # 1. 验证回答检查
    # -------------------------

    # 永久封禁
    if fail.get("banned"):
        await update.message.reply_text("⚠️ 你已被永久禁止。")
        return

    # 锁定中
    if fail.get("locked_until", 0) > time.time():
        remain_seconds = int(fail["locked_until"] - time.time())
        remain_hours = int(remain_seconds / 3600) + 1 if remain_seconds > 0 else 1
        await update.message.reply_text(f"⛔ 请 {remain_hours} 小时后再试。")
        return

    # 未验证且处于等待回答状态 (处理用户发送的回答)
    if user_id_str not in verified_users and user_id_str in pending_verification:
        
        correct_answer = pending_verification[user_id_str]["answer"]

        # 检查用户回答是否为纯数字
        if update.message.text and update.message.text.strip().isdigit():
            user_answer = int(update.message.text.strip())

            # 用户答对
            if user_answer == correct_answer:
                verified_users[user_id_str] = True
                save_json(VERIFIED_FILE, verified_users)
                pending_verification.pop(user_id_str)
                save_json(PENDING_FILE, pending_verification)

                # 成功清零失败记录
                verify_fail[user_id_str] = {"fails": 0, "locked_until": 0, "banned": False}
                save_fail(verify_fail)

                await update.message.reply_text("✅ 验证成功！")
                return
            
            # ❌ 答错 → 记录
            fail["fails"] += 1

            # 10 次 → 永久封禁
            if fail["fails"] >= 10:
                fail["banned"] = True
                verify_fail[user_id_str] = fail
                save_fail(verify_fail)
                await update.message.reply_text("❌ 你已错误 10 次，被永久禁止使用。")
                return

            # 每 3 次 → 锁定 24 小时
            if fail["fails"] % 3 == 0:
                fail["locked_until"] = time.time() + 24 * 3600
                verify_fail[user_id_str] = fail
                save_fail(verify_fail)
                await update.message.reply_text("⛔ 错误 3 次，已被锁定 24 小时。")
                return

            # 普通错误 → 重新生成新题
            verify_fail[user_id_str] = fail
            save_fail(verify_fail)

            a = random.randint(5, 20)
            b = random.randint(5, 20)
            pending_verification[user_id_str] = {"answer": a + b}
            save_json(PENDING_FILE, pending_verification)

            await update.message.reply_text(f"❌ 验证错误：\n\n {a} + {b} = ?")
            return
        
        else:
            # 用户发送了非数字消息，但仍在验证中
            await update.message.reply_text("请直接发送您的答案（纯数字）。")
            return

    # -------------------------
    # 2. 已验证用户或未开始验证的用户
    # -------------------------

    # 如果未验证且不在 pending 中 (即没有先执行 /start)
    if user_id_str not in verified_users:
        await update.message.reply_text("/start 。")
        return
        
    # 广告检测
    if is_ad(update.message):
        await update.message.reply_text("⛔ 检测到广告消息，已被拦截。")
        return

    # 转发消息到管理员
    user_name_display = user.username or user.first_name
    admin_message = f"@{user_name_display} (ID: {user_id}) 发送的消息:\n"

    try:
        # 转发逻辑（保持不变）
        if update.message.text:
            admin_message += update.message.text
            sent_message = await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message)
            save_message(user_id, update.message.text)

        elif update.message.photo:
            sent_message = await context.bot.send_photo(
                chat_id=ADMIN_ID,
                photo=update.message.photo[-1].file_id,
                caption=admin_message + "(照片)"
            )
            save_message(user_id, "发送了一张照片")

        elif update.message.sticker:
            sent_message = await context.bot.send_sticker(chat_id=ADMIN_ID, sticker=update.message.sticker.file_id)
            await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message + "(贴纸)")
            save_message(user_id, "发送了一张贴纸")

        elif update.message.voice:
            sent_message = await context.bot.send_voice(
                chat_id=ADMIN_ID,
                voice=update.message.voice.file_id,
                caption=admin_message + f"(语音，时长: {update.message.voice.duration}秒)"
            )
            save_message(user_id, f"发送了语音消息，时长: {update.message.voice.duration}秒")

        elif update.message.video:
            sent_message = await context.bot.send_video(
                chat_id=ADMIN_ID,
                video=update.message.video.file_id,
                caption=admin_message + "(视频)"
            )
            save_message(user_id, "发送了一段视频")

        elif update.message.animation:
            sent_message = await context.bot.send_animation(
                chat_id=ADMIN_ID,
                animation=update.message.animation.file_id,
                caption=admin_message + "(动图)"
            )
            save_message(user_id, "发送了动图")

        elif update.message.document:
            sent_message = await context.bot.send_document(
                chat_id=ADMIN_ID,
                document=update.message.document.file_id,
                caption=admin_message + "(文档)"
            )
            save_message(user_id, "发送了文档")

        elif update.message.location:
            sent_message = await context.bot.send_location(
                chat_id=ADMIN_ID,
                latitude=update.message.location.latitude,
                longitude=update.message.location.longitude
            )
            await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message + "(位置)")
            save_message(user_id, "发送了位置")

        elif update.message.contact:
            sent_message = await context.bot.send_contact(
                chat_id=ADMIN_ID,
                phone_number=update.message.contact.phone_number,
                first_name=update.message.contact.first_name,
                last_name=update.message.contact.last_name or "",
                vcard=update.message.contact.vcard or None
            )
            await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message + "(联系人)")
            save_message(user_id, "发送了联系人")

        elif update.message.video_note:
            sent_message = await context.bot.send_video_note(
                chat_id=ADMIN_ID,
                video_note=update.message.video_note.file_id
            )
            await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message + "(视频笔记)")
            save_message(user_id, "发送了视频笔记")

        else:
            await update.message.reply_text("暂时不支持此类型的消息。")
            return

        # 记录消息映射
        message_context_map[sent_message.message_id] = user_id

    except BadRequest as e:
        await update.message.reply_text(f"发送消息失败: {e}")


# ---------------------------
# 管理员回复处理 (保持不变)
# ---------------------------
async def handle_admin_reply(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.reply_to_message:
        reply_to_message_id = update.message.reply_to_message.message_id
        user_id = message_context_map.get(reply_to_message_id)
        if not user_id:
            await context.bot.send_message(chat_id=ADMIN_ID, text="无法找到用户，请检查原消息。")
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
            elif update.message.location:
                await context.bot.send_location(chat_id=user_id, latitude=update.message.location.latitude, longitude=update.message.location.longitude)
            elif update.message.contact:
                await context.bot.send_contact(chat_id=user_id, phone_number=update.message.contact.phone_number,
                                               first_name=update.message.contact.first_name,
                                               last_name=update.message.contact.last_name or "",
                                               vcard=update.message.contact.vcard or None)
            elif update.message.video_note:
                await context.bot.send_video_note(chat_id=user_id, video_note=update.message.video_note.file_id)
            else:
                await context.bot.send_message(chat_id=ADMIN_ID, text="暂时不支持此类型的回复。")
        except BadRequest as e:
            await context.bot.send_message(chat_id=ADMIN_ID, text=f"回复失败: {e}")
    else:
        await context.bot.send_message(chat_id=ADMIN_ID, text="请回复某条用户消息进行转发。")


# ---------------------------
# 启动
# ---------------------------
def main():
    create_db()

    app = ApplicationBuilder().token(BOT_TOKEN).build()

    # 1. /start 命令: 负责首次触发验证
    app.add_handler(CommandHandler("start", start))
    # 2. /history 命令
    app.add_handler(CommandHandler("history", show_last_seven_days))

    # 3. 用户消息 (核心处理): 
    #    - 负责验证回答
    #    - 负责已验证用户的消息转发
    #    - 排除所有命令 (filters.COMMAND)，因为 /start 已有专职处理
    app.add_handler(
        MessageHandler(
            (filters.ALL & ~filters.COMMAND) & ~filters.Chat(ADMIN_ID), 
            forward_to_admin
        )
    )
    
    # 4. 管理员回复
    app.add_handler(MessageHandler(filters.ALL & filters.Chat(ADMIN_ID), handle_admin_reply))

    app.run_polling()


if __name__ == "__main__":
    main()
