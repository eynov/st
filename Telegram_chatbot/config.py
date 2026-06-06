import os
from dotenv import load_dotenv

# 强制指向你的自定义环境变量文件路径
load_dotenv(dotenv_path="/etc/variable")

class Config:
    # 【已修改】映射你现有的 TELEGRAM_BOT_TOKEN
    BOT_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN')
    BOT_ID = None
    BOT_USERNAME = None
    
    # 论坛群组 ID，用于双向转发
    FORUM_GROUP_ID = int(os.getenv('FORUM_GROUP_ID') or 0)
    
    # 【已修改】映射你现有的 ADMIN_USER_ID
    ADMIN_IDS = [int(id) for id in os.getenv('ADMIN_USER_ID', '').split(',') if id]
    
    # AI 过滤相关配置
    GEMINI_API_KEY = os.getenv('GEMINI_API_KEY')
    GEMINI_BASE_URL = (os.getenv('GEMINI_BASE_URL') or '').strip() or None
    
    OPENAI_API_KEY = os.getenv('OPENAI_API_KEY')
    OPENAI_BASE_URL = os.getenv('OPENAI_BASE_URL', 'https://api.openai.com/v1')
    
    ENABLE_AI_FILTER = os.getenv('ENABLE_AI_FILTER', 'true').lower() == 'true'
    AI_CONFIDENCE_THRESHOLD = int(os.getenv('AI_CONFIDENCE_THRESHOLD', '70'))
    
    # 验证功能相关配置
    VERIFICATION_ENABLED = os.getenv('VERIFICATION_ENABLED', 'true').lower() == 'true'
    AUTO_UNBLOCK_ENABLED = os.getenv('AUTO_UNBLOCK_ENABLED', 'true').lower() == 'true'
    
    # 数据持久化路径
    DATABASE_PATH = os.getenv('DATABASE_PATH', './data/bot.db')
    
    # 性能与底层配额
    MAX_WORKERS = int(os.getenv('MAX_WORKERS', '5'))
    QUEUE_TIMEOUT = int(os.getenv('QUEUE_TIMEOUT', '30'))
    
    VERIFICATION_TIMEOUT = int(os.getenv('VERIFICATION_TIMEOUT', '300'))
    MAX_VERIFICATION_ATTEMPTS = int(os.getenv('MAX_VERIFICATION_ATTEMPTS', '3'))
    
    MAX_MESSAGES_PER_MINUTE = int(os.getenv('MAX_MESSAGES_PER_MINUTE', '30'))

    # RSS 功能
    RSS_ENABLED = os.getenv('RSS_ENABLED', 'false').lower() == 'true'
    RSS_DATA_FILE = os.getenv('RSS_DATA_FILE', './data/rss_subscriptions.json')
    RSS_CHECK_INTERVAL = int(os.getenv('RSS_CHECK_INTERVAL', '300'))
    RSS_AUTHORIZED_USER_IDS = [
        int(user_id) for user_id in os.getenv('RSS_AUTHORIZED_USER_IDS', '').split(',') if user_id
    ]
    
    @classmethod
    def validate(cls):
        if not cls.BOT_TOKEN:
            raise ValueError("TELEGRAM_BOT_TOKEN 未设置")
        if not cls.FORUM_GROUP_ID or not cls.ADMIN_IDS:
            print("警告: FORUM_GROUP_ID 或 ADMIN_USER_ID 未设置。只有 /getid 功能可用。")

config = Config()

