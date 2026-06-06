import json
import os
from pathlib import Path

CONFIG_FILE = Path(__file__).parent.parent / 'data' / 'network_test_config.json'

config_data = {
    'ADMIN_USERS': [],
    'AUTHORIZED_USERS': [],
    'SERVERS': []
}

try:
    from config import config as main_config
    if main_config.ADMIN_IDS:
        config_data['ADMIN_USERS'] = main_config.ADMIN_IDS.copy()
except ImportError:
    pass

if CONFIG_FILE.exists():
    try:
        with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
            loaded_data = json.load(f)
            config_data.update(loaded_data)
    except Exception as e:
        print(f"加载网络测试配置失败: {e}")

ADMIN_USERS = config_data.get('ADMIN_USERS', [])
AUTHORIZED_USERS = config_data.get('AUTHORIZED_USERS', [])
SERVERS = config_data.get('SERVERS', [])

def save_config():
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    
    config_data['AUTHORIZED_USERS'] = AUTHORIZED_USERS
    config_data['SERVERS'] = SERVERS
    config_data['ADMIN_USERS'] = ADMIN_USERS
    
    with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
        json.dump(config_data, f, indent=2, ensure_ascii=False)
