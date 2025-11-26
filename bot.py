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
# ---------------------------
# 新增：验证失败与封禁管理
# ---------------------------
FAIL_FILE = "verify_fail.json"

def load_fail():
    if not os.path.exists(FAIL_FILE):
        return {}
    with open(FAIL_FILE, "r") as f:
        return json.load(f)

def save_fail(data):
    with open(FAIL_FILE, "w") as f:
        json.dump(data, f)

verify_fail = load_fail()  # user_id : {"fails": int, "locked_until": timestamp, "banned": bool}


VERIFIED_FILE = "verified_users.json"
PENDING_FILE = "pending_verification.json"

def load_json(path):
    if not os.path.exists(path):
        return {}
    with open(path, "r") as f:
        return json.load(f)

def save_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f)

verified_users = load_json(VERIFIED_FILE)
pending_verification = load_json(PENDING_FILE)

# ---------------------------
# 广告检测
# ---------------------------
SENSITIVE_KEYWORDS = ["博彩", "赌博", "现金", "充值"]
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
#    if msg.text:
#        t = msg.text.lower()
#        if any(x in t for x in ["http://", "https://", ".com", ".ru", ".top"]):
#            return True
    return False

# ---------------------------
# Bot 命令
# ---------------------------
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
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
# 核心：转发用户消息到管理员 + 首次数学验证 + 广告拦截
# ---------------------------
message_context_map = {}

async def forward_to_admin(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.message.from_user
    user_id = str(user.id)

    # -------------------------
     # -------------------------
    # 1. 首次验证（强化版）
    # -------------------------
    user_id_str = user_id

    # 读取失败状态
    fail = verify_fail.get(user_id_str, {"fails": 0, "locked_until": 0, "banned": False})

    # 永久封禁
    if fail.get("banned"):
        await update.message.reply_text("⚠️ 你已被永久禁止使用此 Bot。")
        return

    # 判断是否锁定中
    if fail.get("locked_until", 0) > time.time():
        remain = int((fail["locked_until"] - time.time()) / 3600)
        await update.message.reply_text(f"⛔ 错误次数过多，请 {remain} 小时后再试。")
        return

    # 未验证
    if user_id_str not in verified_users:

        # 已存在数学题 → 检查用户回答
        if user_id_str in pending_verification:

            correct_answer = pending_verification[user_id_str]["answer"]

            # 用户答对
            if update.message.text and update.message.text.strip().isdigit() and int(update.message.text.strip()) == correct_answer:
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

            await update.message.reply_text(f"❌ 验证错误！请回答新的问题：\n\n {a} + {b} = ?")
            return

        # 未产生数学题 → 第一次验证
        else:
            a = random.randint(5, 20)
            b = random.randint(5, 20)
            pending_verification[user_id_str] = {"answer": a + b}
            save_json(PENDING_FILE, pending_verification)
            await update.message.reply_text(f"🤖 为了防止广告，请先通过验证：\n\n {a} + {b} = ?")
            return
    # -------------------------
    # 2. 广告检测
    # -------------------------
    if is_ad(update.message):
        await update.message.reply_text("⛔ 检测到广告消息，已被拦截。")
        return

    # -------------------------
    # 3. 转发消息到管理员
    # -------------------------
    admin_message = f"@{user.username or user.first_name} (ID: {user_id}) 发送的消息:\n"

    try:
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
# 管理员回复处理
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

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("history", show_last_seven_days))

    # 用户消息
    app.add_handler(MessageHandler(filters.ALL & ~filters.Chat(ADMIN_ID), forward_to_admin))
    # 管理员回复
    app.add_handler(MessageHandler(filters.ALL & filters.Chat(ADMIN_ID), handle_admin_reply))

    app.run_polling()


if __name__ == "__main__":
    main()