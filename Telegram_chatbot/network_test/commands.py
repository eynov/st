import time
import ipaddress
from telegram import InlineKeyboardButton, InlineKeyboardMarkup
from .config import SERVERS, ADMIN_USERS, AUTHORIZED_USERS, save_config
from .state import user_data, last_ping_command_time
from .tasks import do_ping_in_background, do_nexttrace_in_background
from .utils import schedule_delete_message, check_authorization, check_is_admin

async def start_command(update, context):
    user_id = update.effective_user.id
    if not check_authorization(user_id, AUTHORIZED_USERS, ADMIN_USERS):
        await update.message.reply_text(
            "对不起，你没有权限使用本机器人\n\n"
            f"当前用户ID：`{user_id}`\n\n"
            "请联系管理员使用 `/adduser {user_id}` 命令将你添加到授权列表。",
            parse_mode="Markdown"
        )
        return

    await update.message.reply_text(
        "欢迎使用网络测试机器人！\n\n"
        "使用说明：\n"
        "1）Ping 测试：/ping 后按提示进行\n"
        "2）路由追踪：/nexttrace 后按提示进行\n\n"
        "管理员命令：/adduser, /rmuser, /addserver, /rmserver"
    )

async def ping_command(update, context):
    user_id = update.effective_user.id
    if not check_authorization(user_id, AUTHORIZED_USERS, ADMIN_USERS):
        await update.message.reply_text(
            f"对不起，你没有权限使用本机器人\n\n"
            f"当前用户ID：`{user_id}`\n\n"
            f"请联系管理员使用 `/adduser {user_id}` 命令将你添加到授权列表。",
            parse_mode="Markdown"
        )
        return

    now_ts = time.time()
    if user_id in last_ping_command_time:
        elapsed = now_ts - last_ping_command_time[user_id]
        if elapsed < 15:
            await update.message.reply_text(f"你在 {15 - int(elapsed)} 秒后才能再次使用 /ping 命令（每15秒限制一次）。")
            return
    last_ping_command_time[user_id] = now_ts

    if not SERVERS:
        await update.message.reply_text("当前没有配置可用的服务器，请联系管理员。")
        return

    if user_id in user_data:
        del user_data[user_id]

    args = context.args
    if len(args) >= 1:
        ip_or_domain = args[0]
        try:
            ping_count = int(args[1]) if len(args) >= 2 else 4
        except ValueError:
            await update.message.reply_text("输入的Ping次数无效，请输入数字！")
            return
        if ping_count > 50:
            ping_count = 50

        keyboard = []
        for idx, server_info in enumerate(SERVERS):
            btn = InlineKeyboardButton(server_info['name'], callback_data=f"nt_server_{idx}")
            keyboard.append([btn])
        reply_markup = InlineKeyboardMarkup(keyboard)
        text = f"你输入了：目标= {ip_or_domain} , 次数= {ping_count} 次\n请选择服务器："
        msg = await update.message.reply_text(text, reply_markup=reply_markup)
        user_data[user_id] = {
            "operation": "ping",
            "mode": "cmd",
            "server_info": None,
            "target": ip_or_domain,
            "count": ping_count,
            "chat_id": msg.chat_id,
            "message_id": msg.message_id
        }
    else:
        keyboard = []
        for idx, server_info in enumerate(SERVERS):
            btn = InlineKeyboardButton(server_info['name'], callback_data=f"nt_server_{idx}")
            keyboard.append([btn])
        reply_markup = InlineKeyboardMarkup(keyboard)
        text = "请选择要进行 Ping 测试的服务器："
        msg = await update.message.reply_text(text, reply_markup=reply_markup)
        user_data[user_id] = {
            "operation": "ping",
            "mode": "interactive",
            "server_info": None,
            "target": None,
            "count": None,
            "chat_id": msg.chat_id,
            "message_id": msg.message_id
        }

async def nexttrace_command(update, context):
    user_id = update.effective_user.id
    if not check_authorization(user_id, AUTHORIZED_USERS, ADMIN_USERS):
        await update.message.reply_text(
            f"对不起，你没有权限使用本机器人\n\n"
            f"当前用户ID：`{user_id}`\n\n"
            f"请联系管理员使用 `/adduser {user_id}` 命令将你添加到授权列表。",
            parse_mode="Markdown"
        )
        return

    now_ts = time.time()
    if user_id in last_ping_command_time:
        elapsed = now_ts - last_ping_command_time[user_id]
        if elapsed < 10:
            await update.message.reply_text(f"你在 {10 - int(elapsed)} 秒后才能再次使用命令（每10秒限制一次）。")
            return
    last_ping_command_time[user_id] = now_ts

    if not SERVERS:
        await update.message.reply_text("当前没有配置可用的服务器，请联系管理员。")
        return

    if user_id in user_data:
        del user_data[user_id]

    args = context.args
    if len(args) >= 1:
        target = args[0]
        
        keyboard = [
            [
                InlineKeyboardButton("ICMP模式", callback_data="nt_trace_mode_icmp"),
                InlineKeyboardButton("TCP模式", callback_data="nt_trace_mode_tcp")
            ]
        ]
        reply_markup = InlineKeyboardMarkup(keyboard)
        text = f"你输入了目标： {target}\n请选择追踪模式："
        msg = await update.message.reply_text(text, reply_markup=reply_markup)
        user_data[user_id] = {
            "operation": "nexttrace",
            "mode": "cmd",
            "server_info": None,
            "target": target,
            "ip_type": None,
            "trace_mode": None,
            "chat_id": msg.chat_id,
            "message_id": msg.message_id
        }
    else:
        keyboard = [
            [
                InlineKeyboardButton("ICMP模式", callback_data="nt_trace_mode_icmp"),
                InlineKeyboardButton("TCP模式", callback_data="nt_trace_mode_tcp")
            ]
        ]
        reply_markup = InlineKeyboardMarkup(keyboard)
        text = "请选择路由追踪模式："
        msg = await update.message.reply_text(text, reply_markup=reply_markup)
        user_data[user_id] = {
            "operation": "nexttrace",
            "mode": "interactive",
            "server_info": None,
            "target": None,
            "ip_type": None,
            "trace_mode": None,
            "chat_id": msg.chat_id,
            "message_id": msg.message_id
        }

async def add_user_command(update, context):
    user_id = update.effective_user.id
    if not check_is_admin(user_id, ADMIN_USERS):
        await update.message.reply_text(
            "你不是管理员，无法执行此操作。\n\n"
            f"当前用户ID：`{user_id}`",
            parse_mode="Markdown"
        )
        return

    args = context.args
    if len(args) < 1:
        await update.message.reply_text("用法：/adduser <user_id>")
        return

    try:
        new_user_id = int(args[0])
    except ValueError:
        await update.message.reply_text("请输入正确的 user_id（数字）。")
        return

    if new_user_id in AUTHORIZED_USERS:
        await update.message.reply_text(f"用户 {new_user_id} 已经在授权名单中。")
    else:
        AUTHORIZED_USERS.append(new_user_id)
        save_config()
        await update.message.reply_text(f"成功添加用户 {new_user_id} 到授权名单。")

async def rm_user_command(update, context):
    user_id = update.effective_user.id
    if not check_is_admin(user_id, ADMIN_USERS):
        await update.message.reply_text(
            "你不是管理员，无法执行此操作。\n\n"
            f"当前用户ID：`{user_id}`",
            parse_mode="Markdown"
        )
        return

    args = context.args
    if len(args) < 1:
        await update.message.reply_text("用法：/rmuser <user_id>")
        return

    try:
        del_user_id = int(args[0])
    except ValueError:
        await update.message.reply_text("请输入正确的 user_id（数字）。")
        return

    if del_user_id in AUTHORIZED_USERS:
        AUTHORIZED_USERS.remove(del_user_id)
        save_config()
        await update.message.reply_text(f"已将用户 {del_user_id} 从授权名单中移除。")
    else:
        await update.message.reply_text(f"用户 {del_user_id} 不在授权名单中。")

async def add_server_command(update, context):
    user_id = update.effective_user.id
    if not check_is_admin(user_id, ADMIN_USERS):
        await update.message.reply_text(
            "你不是管理员，无法执行此操作。\n\n"
            f"当前用户ID：`{user_id}`",
            parse_mode="Markdown"
        )
        return

    message_text = update.message.text.strip()
    
    if message_text == "/addserver":
        msg = await update.message.reply_text(
            "欢迎使用交互式添加服务器向导！\n\n"
            "请按照提示一步一步输入服务器信息。\n"
            "步骤 1/5: 请输入服务器名称（如：香港 - GCP）：\n\n"
            "您可以随时输入 /cancel 取消添加流程"
        )
        
        from .state import user_data
        user_data[user_id] = {
            "operation": "addserver",
            "step": 1,
            "server_data": {},
            "chat_id": msg.chat_id,
            "message_id": msg.message_id,
            "prompt_message_id": msg.message_id
        }
        
        try:
            await context.bot.delete_message(
                chat_id=update.message.chat_id,
                message_id=update.message.message_id
            )
        except Exception:
            pass
            
        return
    
    if message_text == "/cancel":
        from .state import user_data
        if user_id in user_data and user_data[user_id].get("operation") == "addserver":
            if user_data[user_id].get("prompt_message_id"):
                try:
                    await context.bot.delete_message(
                        chat_id=update.message.chat_id,
                        message_id=user_data[user_id]["prompt_message_id"]
                    )
                except Exception:
                    pass
                    
            del user_data[user_id]
            cancel_msg = await update.message.reply_text("已取消添加服务器操作。")
            
            context.application.create_task(schedule_delete_message(context, update.message.chat_id, cancel_msg.message_id, delay=5))
            
            try:
                await context.bot.delete_message(
                    chat_id=update.message.chat_id,
                    message_id=update.message.message_id
                )
            except Exception:
                pass
        else:
            await update.message.reply_text("当前没有正在进行的添加服务器操作。")
        return
    
    if ' ' in message_text:
        args_text = message_text.split(' ', 1)[1]
    else:
        await update.message.reply_text(
            "您可以通过以下两种方式添加服务器：\n\n"
            "1. 直接输入 /addserver 启动交互式添加向导\n"
            "2. 一次性提供所有参数：\n"
            "   /addserver <名称> <host> <port> <username> <password>\n\n"
            "名称可以包含空格，但需要用引号括起来，例如：\n"
            "/addserver \"香港 - GCP\" 1.2.3.4 22 user pass"
        )
        return
    
    try:
        import shlex
        args = shlex.split(args_text)
    except Exception as e:
        await update.message.reply_text(f"参数解析错误：{str(e)}\n\n请确保如果名称中包含空格，应该用引号括起来。")
        return
    
    if len(args) < 5:
        await update.message.reply_text(
            "您可以通过以下两种方式添加服务器：\n\n"
            "1. 直接输入 /addserver 启动交互式添加向导\n"
            "2. 一次性提供所有参数：\n"
            "   /addserver <名称> <host> <port> <username> <password>\n\n"
            "名称可以包含空格，但需要用引号括起来，例如：\n"
            "/addserver \"香港 - GCP\" 1.2.3.4 22 user pass"
        )
        return

    name = args[0]
    host = args[1]
    try:
        port = int(args[2])
    except ValueError:
        await update.message.reply_text("端口号必须是数字，请重新输入。")
        return
    username = args[3]
    password = args[4]

    new_server = {
        "name": name,
        "host": host,
        "port": port,
        "username": username,
        "password": password
    }

    SERVERS.append(new_server)
    save_config()

    await update.message.reply_text(f"成功添加服务器：{name} ({host}:{port})")

async def rm_server_command(update, context):
    user_id = update.effective_user.id
    if not check_is_admin(user_id, ADMIN_USERS):
        await update.message.reply_text(
            "你不是管理员，无法执行此操作。\n\n"
            f"当前用户ID：`{user_id}`",
            parse_mode="Markdown"
        )
        return

    message_text = update.message.text.strip()
    
    if message_text == "/rmserver":
        if not SERVERS:
            await update.message.reply_text("当前没有配置任何服务器。")
            return
            
        keyboard = []
        for idx, server_info in enumerate(SERVERS):
            btn = InlineKeyboardButton(
                f"{server_info['name']} ({server_info['host']}:{server_info['port']})", 
                callback_data=f"nt_rmserver_{idx}"
            )
            keyboard.append([btn])
        
        keyboard.append([InlineKeyboardButton("取消", callback_data="nt_rmserver_cancel")])
        
        reply_markup = InlineKeyboardMarkup(keyboard)
        msg = await update.message.reply_text(
            "请选择要删除的服务器：",
            reply_markup=reply_markup
        )
        
        from .state import user_data
        user_data[user_id] = {
            "operation": "rmserver",
            "chat_id": msg.chat_id,
            "message_id": msg.message_id,
            "prompt_message_id": msg.message_id
        }
        
        try:
            await context.bot.delete_message(
                chat_id=update.message.chat_id,
                message_id=update.message.message_id
            )
        except Exception:
            pass
        
        return
    
    if ' ' in message_text:
        args_text = message_text.split(' ', 1)[1]
        try:
            import shlex
            args = shlex.split(args_text)
        except Exception as e:
            await update.message.reply_text(f"参数解析错误：{str(e)}\n\n请确保如果名称中包含空格，应该用引号括起来。")
            return
    else:
        await update.message.reply_text("直接输入 /rmserver 可以查看所有服务器并选择要删除的服务器。\n\n如果要直接指定删除，用法：/rmserver <服务器名字>\n如果服务器名称包含空格，请用引号括起来，例如：\n/rmserver \"香港 - GCP\"")
        return
    
    if len(args) < 1:
        await update.message.reply_text("直接输入 /rmserver 可以查看所有服务器并选择要删除的服务器。\n\n如果要直接指定删除，用法：/rmserver <服务器名字>\n如果服务器名称包含空格，请用引号括起来，例如：\n/rmserver \"香港 - GCP\"")
        return

    target_name = args[0]
    found_index = None
    for i, s in enumerate(SERVERS):
        if s['name'] == target_name:
            found_index = i
            break

    if found_index is None:
        await update.message.reply_text(f"未找到服务器名称：{target_name}，请确认输入是否正确。")
    else:
        removed_server = SERVERS.pop(found_index)
        save_config()
        result_msg = await update.message.reply_text(f"成功删除服务器：{removed_server['name']} (host={removed_server['host']})")
        
        context.application.create_task(schedule_delete_message(context, update.message.chat_id, result_msg.message_id, delay=5))
        
        try:
            await context.bot.delete_message(
                chat_id=update.message.chat_id,
                message_id=update.message.message_id
            )
        except Exception:
            pass

async def install_nexttrace_command(update, context):
    user_id = update.effective_user.id
    if not check_is_admin(user_id, ADMIN_USERS):
        await update.message.reply_text(
            "你不是管理员，无法执行此操作。\n\n"
            f"当前用户ID：`{user_id}`",
            parse_mode="Markdown"
        )
        return

    if not SERVERS:
        await update.message.reply_text("当前没有配置任何服务器。\n请先使用 /addserver 添加服务器。")
        return
        
    try:
        await context.bot.delete_message(
            chat_id=update.message.chat_id,
            message_id=update.message.message_id
        )
    except Exception:
        pass
        
    keyboard = []
    for idx, server_info in enumerate(SERVERS):
        btn = InlineKeyboardButton(
            f"{server_info['name']} ({server_info['host']}:{server_info['port']})", 
            callback_data=f"nt_installnexttrace_{idx}"
        )
        keyboard.append([btn])
    
    keyboard.append([InlineKeyboardButton("取消", callback_data="nt_installnexttrace_cancel")])
    
    reply_markup = InlineKeyboardMarkup(keyboard)
    msg = await update.message.reply_text(
        "请选择要安装 NextTrace 的服务器：",
        reply_markup=reply_markup
    )
    
    from .state import user_data
    user_data[user_id] = {
        "operation": "installnexttrace",
        "chat_id": msg.chat_id,
        "message_id": msg.message_id,
        "prompt_message_id": msg.message_id
    }
