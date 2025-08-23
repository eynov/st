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

# 从环境变量中加载配置
BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
ADMIN_ID = os.getenv("ADMIN_USER_ID")

# 检查环境变量
if not BOT_TOKEN:
    raise ValueError("请设置环境变量 TELEGRAM_BOT_TOKEN")
if not ADMIN_ID:
    raise ValueError("请设置环境变量 ADMIN_USER_ID")

ADMIN_ID = int(ADMIN_ID)  # 确保 ADMIN_ID 是整数

# 存储管理员转发消息 ID 与用户 ID 的映射
message_context_map = {}

# 创建数据库并存储消息
def create_db():
    conn = sqlite3.connect('messages.db')
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS messages (
                    user_id INTEGER,
                    message TEXT,
                    timestamp DATETIME
                )''')
    conn.commit()
    conn.close()

# 存储消息到数据库
def save_message(user_id, message):
    conn = sqlite3.connect('messages.db')
    c = conn.cursor()
    c.execute('INSERT INTO messages (user_id, message, timestamp) VALUES (?, ?, ?)', 
              (user_id, message, datetime.now()))
    conn.commit()
    conn.close()

# 获取过去七天的消息
def get_last_seven_days_messages():
    seven_days_ago = datetime.now() - timedelta(days=7)
    conn = sqlite3.connect('messages.db')
    c = conn.cursor()
    c.execute('SELECT * FROM messages WHERE timestamp > ?', (seven_days_ago,))
    rows = c.fetchall()
    conn.close()
    return rows


# 启动命令
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("Hello!")


# 转发用户消息到管理员
async def forward_to_admin(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.message.from_user
    user_id = user.id

    # 构造消息头
    admin_message = f"@{user.username or user.first_name} (ID: {user_id}) 发送的消息:\n"

    try:
        if update.message.text:
            # 文本消息
            admin_message += update.message.text
            sent_message = await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message)
            save_message(user_id, update.message.text)  # 存储消息

        elif update.message.photo:
            # 照片消息
            sent_message = await context.bot.send_photo(
                chat_id=ADMIN_ID,
                photo=update.message.photo[-1].file_id,
                caption=admin_message + "(照片)"
            )
            save_message(user_id, "发送了一张照片")  # 存储消息

        elif update.message.sticker:
            # 贴纸消息
            sent_message = await context.bot.send_sticker(
                chat_id=ADMIN_ID,
                sticker=update.message.sticker.file_id
            )
            await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message + "(贴纸)")
            save_message(user_id, "发送了一张贴纸")  # 存储消息

        elif update.message.voice:
            # 语音消息
            voice_file_id = update.message.voice.file_id
            duration = update.message.voice.duration
            sent_message = await context.bot.send_voice(
                chat_id=ADMIN_ID,
                voice=voice_file_id,
                caption=admin_message + f"(语音，时长: {duration}秒)"
            )
            save_message(user_id, f"发送了语音消息，时长: {duration}秒")  # 存储消息

        elif update.message.video:
            # 视频消息
            sent_message = await context.bot.send_video(
                chat_id=ADMIN_ID,
                video=update.message.video.file_id,
                caption=admin_message + "(视频)"
            )
            save_message(user_id, "发送了一段视频")  # 存储消息

        elif update.message.animation:
            # 动图 (GIF)
            sent_message = await context.bot.send_animation(
                chat_id=ADMIN_ID,
                animation=update.message.animation.file_id,
                caption=admin_message + "(动图)"
            )
            save_message(user_id, "发送了动图")  # 存储消息

        elif update.message.document:
            # 文档
            sent_message = await context.bot.send_document(
                chat_id=ADMIN_ID,
                document=update.message.document.file_id,
                caption=admin_message + "(文档)"
            )
            save_message(user_id, "发送了文档")  # 存储消息

        elif update.message.location:
            # 位置
            sent_message = await context.bot.send_location(
                chat_id=ADMIN_ID,
                latitude=update.message.location.latitude,
                longitude=update.message.location.longitude
            )
            await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message + "(位置)")
            save_message(user_id, "发送了位置")  # 存储消息

        elif update.message.contact:
            # 联系人
            sent_message = await context.bot.send_contact(
                chat_id=ADMIN_ID,
                phone_number=update.message.contact.phone_number,
                first_name=update.message.contact.first_name,
                last_name=update.message.contact.last_name or "",
                vcard=update.message.contact.vcard or None
            )
            await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message + "(联系人)")
            save_message(user_id, "发送了联系人")  # 存储消息

        elif update.message.video_note:
            # 视频笔记
            sent_message = await context.bot.send_video_note(
                chat_id=ADMIN_ID,
                video_note=update.message.video_note.file_id
            )
            await context.bot.send_message(chat_id=ADMIN_ID, text=admin_message + "(视频笔记)")
            save_message(user_id, "发送了视频笔记")  # 存储消息

        else:
            # 不支持的消息类型
            await update.message.reply_text("暂时不支持此类型的消息。")
            return

        # 记录消息映射
        message_context_map[sent_message.message_id] = user_id

    except BadRequest as e:
        if "Voice_messages_forbidden" in str(e):
            await update.message.reply_text("管理员无法接收语音消息，请发送其他类型的消息。")
        else:
            await update.message.reply_text("发送消息时发生未知错误，请稍后再试。")
        print(f"转发消息失败: {e}")


# 管理员回复处理
async def handle_admin_reply(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.reply_to_message:
        reply_to_message_id = update.message.reply_to_message.message_id

        # 查找原始用户 ID
        user_id = message_context_map.get(reply_to_message_id)
        if user_id:
            try:
                if update.message.text:
                    await context.bot.send_message(chat_id=user_id, text=update.message.text)

                elif update.message.photo:
                    await context.bot.send_photo(
                        chat_id=user_id,
                        photo=update.message.photo[-1].file_id,
                        caption=update.message.caption
                    )

                elif update.message.sticker:
                    await context.bot.send_sticker(
                        chat_id=user_id,
                        sticker=update.message.sticker.file_id
                    )

                elif update.message.voice:
                    await context.bot.send_voice(
                        chat_id=user_id,
                        voice=update.message.voice.file_id,
                        caption=update.message.caption
                    )

                elif update.message.video:
                    await context.bot.send_video(
                        chat_id=user_id,
                        video=update.message.video.file_id,
                        caption=update.message.caption
                    )

                elif update.message.animation:
                    await context.bot.send_animation(
                        chat_id=user_id,
                        animation=update.message.animation.file_id,
                        caption=update.message.caption
                    )

                elif update.message.document:
                    await context.bot.send_document(
                        chat_id=user_id,
                        document=update.message.document.file_id,
                        caption=update.message.caption
                    )

                elif update.message.location:
                    await context.bot.send_location(
                        chat_id=user_id,
                        latitude=update.message.location.latitude,
                        longitude=update.message.location.longitude
                    )

                elif update.message.contact:
                    await context.bot.send_contact(
                        chat_id=user_id,
                        phone_number=update.message.contact.phone_number,
                        first_name=update.message.contact.first_name,
                        last_name=update.message.contact.last_name or "",
                        vcard=update.message.contact.vcard or None
                    )

                elif update.message.video_note:
                    await context.bot.send_video_note(
                        chat_id=user_id,
                        video_note=update.message.video_note.file_id
                    )

                else:
                    await context.bot.send_message(
                        chat_id=ADMIN_ID,
                        text="暂时不支持此类型的回复。"
                    )
            except BadRequest as e:
                await context.bot.send_message(chat_id=ADMIN_ID, text=f"回复失败: {e}")
        else:
            await context.bot.send_message(
                chat_id=ADMIN_ID, text="无法找到用户，请检查原消息是否是转发的用户消息。"
            )
    else:
        await context.bot.send_message(
            chat_id=ADMIN_ID, text="请回复某条用户消息进行转发。"
        )


# 查看过去七天的消息
async def show_last_seven_days(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message.from_user.id == ADMIN_ID:
        messages = get_last_seven_days_messages()
        if messages:
            response = "\n".join([f"用户 ID: {msg[0]} | 消息: {msg[1]} | 时间: {msg[2]}" for msg in messages])
        else:
            response = "没有找到过去七天的记录。"
        await update.message.reply_text(response)
    else:
        await update.message.reply_text("您没有权限查看历史记录。")


# 主函数
def main():
    create_db()  # 创建数据库

    application = ApplicationBuilder().token(BOT_TOKEN).build()

    # 添加命令处理器
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("history", show_last_seven_days))  # 查询历史记录命令

    # 添加消息处理器
    application.add_handler(
        MessageHandler(
            filters.ALL & ~filters.Chat(ADMIN_ID),  # 用户的所有消息
            forward_to_admin
        )
    )
    application.add_handler(
        MessageHandler(
            filters.ALL & filters.Chat(ADMIN_ID),  # 管理员的所有回复
            handle_admin_reply
        )
    )

    # 启动 Bot
    application.run_polling()


if __name__ == "__main__":
    main()
