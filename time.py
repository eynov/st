import os
import logging
from logging.handlers import RotatingFileHandler
from telethon import TelegramClient, functions
from datetime import datetime, timedelta, timezone
import asyncio

# 日志文件路径
log_path = '/var/log/tg_time.log'

# 如果日志文件所在目录不存在，创建它
if not os.path.exists(os.path.dirname(log_path)):
    os.makedirs(os.path.dirname(log_path))

# 创建 RotatingFileHandler 来进行日志轮换
handler = RotatingFileHandler(
    log_path,         # 日志文件路径
    maxBytes=2*1024*1024,  # 最大文件大小（2MB）
    backupCount=0     # 不保留备份文件
)

# 设置日志格式
formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)

# 创建 logger
logger = logging.getLogger()
logger.setLevel(logging.INFO)
logger.addHandler(handler)

# 日志记录：脚本开始运行
logger.info("脚本开始运行...")
# 从环境变量中获取 API 信息
api_id = int(os.getenv('API_ID', ''))
api_hash = os.getenv('API_HASH', '')

if not api_id or not api_hash:
    raise ValueError("API_ID 和 API_HASH 环境变量未设置或不正确")

# 获取当前脚本的目录
script_dir = os.path.dirname(os.path.abspath(__file__))

# 会话文件路径设置为脚本所在目录
session_file = os.path.join(script_dir, 'time.session')

# 创建 Telegram 客户端，使用指定的会话文件
client = TelegramClient(session_file, api_id, api_hash)

# 设置 UTC+8 时区
timezone_utc_8 = timezone(timedelta(hours=8))

# 定义一个函数，根据小时数和分钟数选择相应的时钟图标
def get_clock_icon(hour, minute):
    # 如果分钟 >= 30，则增加半小时
    hour_24 = hour
    if minute >= 30:
        hour_24 += 0.5  # 增加半小时
    hour_24 = round(hour_24 * 2) / 2  # 确保是 0.5 或整数

    # 时钟图标字典（基于 24 小时制）
    clock_icons = {
        0: "\U0001F55B",   # 🕛 12:00
        0.5: "\U0001F567", # 🕧 12:30
        1: "\U0001F550",   # 🕐 1:00
        1.5: "\U0001F55C", # 🕜 1:30
        2: "\U0001F551",   # 🕑 2:00
        2.5: "\U0001F55D", # 🕝 2:30
        3: "\U0001F552",   # 🕒 3:00
        3.5: "\U0001F55E", # 🕞 3:30
        4: "\U0001F553",   # 🕓 4:00
        4.5: "\U0001F55F", # 🕟 4:30
        5: "\U0001F554",   # 🕔 5:00
        5.5: "\U0001F560", # 🕠 5:30
        6: "\U0001F555",   # 🕕 6:00
        6.5: "\U0001F561", # 🕡 6:30
        7: "\U0001F556",   # 🕖 7:00
        7.5: "\U0001F562", # 🕢 7:30
        8: "\U0001F557",   # 🕗 8:00
        8.5: "\U0001F563", # 🕣 8:30
        9: "\U0001F558",   # 🕘 9:00
        9.5: "\U0001F564", # 🕤 9:30
        10: "\U0001F559",  # 🕙 10:00
        10.5: "\U0001F565",# 🕥 10:30
        11: "\U0001F55A",  # 🕚 11:00
        11.5: "\U0001F566",# 🕦 11:30
        12: "\U0001F55B",  # 🕛 12:00
    }

    # 映射到 12 小时制图标
    hour_mapped = hour_24 % 12
    return clock_icons.get(hour_mapped, "\U0001F55B")

# 定义异步函数，更新昵称
async def update_nickname():
    async with client:
        while True:
            try:
                # 获取当前时间，并转换为 24 小时制
                now = datetime.now(timezone_utc_8)
                current_time_24hr = now.strftime('%H:%M')  # 24小时制
                am_pm = now.strftime('%p')  # AM/PM

                # 获取当前小时和分钟，选择相应的时钟图标
                clock_icon = get_clock_icon(now.hour, now.minute)

                # 获取当前的名字，并仅修改姓氏
                user = await client.get_me()
                first_name = user.first_name
                new_last_name = f"{current_time_24hr} {am_pm} UTC+8 {clock_icon}"

                # 更新 Telegram 昵称
                await client(functions.account.UpdateProfileRequest(
                    first_name=first_name,
                    last_name=new_last_name
                ))

                logging.info(f"昵称已更新为: {first_name} {new_last_name}")
                print(f"昵称已更新为: {first_name} {new_last_name}")

                # 设置更新时间间隔（例如，每60秒更新一次）
                await asyncio.sleep(30)

            except Exception as e:
                logging.error(f"更新昵称时出错: {e}")
                print(f"更新昵称时出错: {e}")
                await asyncio.sleep(60)  # 如果出错，等待60秒后重试

# 启动客户端并运行异步函数
async def main():
    await client.start()
    await update_nickname()

# 运行异步主函数（Python 3.6 兼容）
if __name__ == "__main__":
    loop = asyncio.get_event_loop()
    loop.run_until_complete(main())
