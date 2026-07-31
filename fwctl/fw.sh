#!/bin/bash
# fw.sh —— fwctl 的唯一入口
#
# 职责：定位项目目录、加载 core 模块、分发命令、提供交互菜单。
# 命令实现在 core/cli.sh，这里只做入口的事。
#
# 安装后的命令名跟随本文件名（见 install.sh），改名不需要改代码。

# ── 路径自动识别：通过软链接或真实文件位置反查项目目录 ──
if [ -L "${BASH_SOURCE[0]}" ]; then
    REAL_SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")
    if [ -z "$REAL_SCRIPT_PATH" ]; then
        # 兜底：readlink -f 不可用时直接读链接目标，不解析 ls 的输出。
        REAL_SCRIPT_PATH=$(readlink "${BASH_SOURCE[0]}")
    fi
else
    REAL_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
fi

BASE_DIR="$(cd "$(dirname "$REAL_SCRIPT_PATH")" 2>/dev/null && pwd)"

# 锚点校验：确认这确实是项目目录。
if [ -z "$BASE_DIR" ] || [ ! -d "$BASE_DIR/core" ]; then
    FOUND=$(find /opt -maxdepth 3 -type d -name core -path '*fwctl*' 2>/dev/null | head -n1)
    if [ -n "$FOUND" ]; then
        BASE_DIR="$(cd "$(dirname "$FOUND")" && pwd)"
    else
        echo "❌ 无法定位项目目录（找不到 core/）"
        echo "   请通过 install.sh 安装，或直接用完整路径运行本脚本"
        exit 1
    fi
fi

# 安装后的命令名，用于帮助文本。
FWCTL_COMMAND_NAME=$(basename "${BASH_SOURCE[0]}" .sh)
export FWCTL_COMMAND_NAME

# shellcheck source=core/common.sh
source "$BASE_DIR/core/common.sh"
# shellcheck source=core/state.sh
source "$BASE_DIR/core/state.sh"
# shellcheck source=core/model.sh
source "$BASE_DIR/core/model.sh"
# shellcheck source=core/migration.sh
source "$BASE_DIR/core/migration.sh"
# shellcheck source=core/render.sh
source "$BASE_DIR/core/render.sh"
# shellcheck source=core/transaction.sh
source "$BASE_DIR/core/transaction.sh"
# shellcheck source=core/backup.sh
source "$BASE_DIR/core/backup.sh"
# shellcheck source=core/doctor.sh
source "$BASE_DIR/core/doctor.sh"
# shellcheck source=core/stats.sh
source "$BASE_DIR/core/stats.sh"
# shellcheck source=core/cli.sh
source "$BASE_DIR/core/cli.sh"

# 状态文件默认位于项目目录，可用环境变量覆盖（测试与非标准部署需要）。
export FWCTL_STATE_FILE="${FWCTL_STATE_FILE:-$BASE_DIR/state.json}"
export FWCTL_BUILD_DIR="${FWCTL_BUILD_DIR:-$BASE_DIR/build}"

fwctl_require_root || exit "$FWCTL_EXIT_RUNTIME"

if ! fwctl_require_commands jq flock "$(txn_nft_bin)"; then
    exit "$FWCTL_EXIT_RUNTIME"
fi

# ── 交互菜单 ──────────────────────────────────────────────────────────
# 1–12 项的编号与含义与旧版本完全一致，新增项只追加在末尾。

menu_add_forward() {
    local dest_addr raw_host dip sport dport dest_port proto
    local target_name service_name rule_name

    read -r -p "🔹 请输入目标落地 IP 或域名 (可带端口如 127.0.0.1:443): " dest_addr

    if [[ "$dest_addr" =~ ^([^:]+):([0-9]+)$ ]]; then
        raw_host="${BASH_REMATCH[1]}"
        dest_port="${BASH_REMATCH[2]}"
    else
        raw_host="$dest_addr"
        dest_port=""
    fi

    if fwctl_is_ipv4 "$raw_host"; then
        dip="$raw_host"
    else
        dip=$(dig +short "$raw_host" 2>/dev/null | tail -n1)
        if [ -z "$dip" ]; then echo "❌ 域名解析失败！"; return; fi
    fi

    read -r -p "🔹 请输入起始端口: " sport
    read -r -p "🔹 请输入结束端口 (若单端口直接回车): " dport
    [ -z "$dport" ] && dport="$sport"

    if [ -n "$dest_port" ]; then
        echo "ℹ️  目标端口自动使用: $dest_port"
    else
        read -r -p "🔹 请输入目标端口 (直接回车默认与起始端口相同): " dest_port
        [ -z "$dest_port" ] && dest_port="$sport"
    fi

    read -r -p "🔹 请输入协议 (tcp/udp/both, 默认 both): " proto
    [ -z "$proto" ] && proto="both"

    # 转成对象：地址一个 Target、端口一个 Service、两者由一条 Rule 绑定。
    target_name="t-${dip//./-}"
    if [[ "$sport" == "$dport" ]]; then
        service_name="s-$proto-$sport"
    else
        service_name="s-$proto-$sport-$dport"
    fi
    rule_name="f-${dip//./-}-$sport"

    cli_object_dispatch target add "$target_name" "$dip" >/dev/null 2>&1
    if [[ "$sport" == "$dport" ]]; then
        cli_object_dispatch service add "$service_name" "$proto" "$sport" >/dev/null 2>&1
    else
        cli_object_dispatch service add "$service_name" "$proto" "$sport-$dport" >/dev/null 2>&1
    fi
    if cli_object_dispatch rule add "$rule_name" --type forward \
        --service "$service_name" --target "$target_name" --to-port "$dest_port"; then
        echo "✅ 编译成功，规则已实时应用！"
    else
        echo "❌ 编译或加载失败；上一份运行配置和持久配置保持不变。"
    fi
}

menu_del_forward() {
    local name
    cli_list rule
    read -r -p "❌ 请输入要删除的规则名称: " name
    [ -n "$name" ] || return
    if cli_object_dispatch rule delete "$name"; then
        echo "✅ 编译成功，规则已实时应用！"
    fi
}

menu_show_forward() {
    echo -e "\n=== 📍 当前端口转发规则列表 ==="
    cli_list rule
    echo ""
}

menu_add_port() {
    local port proto
    read -r -p "🔹 请输入放行端口或范围 (例如 443 或 60000-61000): " port
    read -r -p "🔹 协议类型 (tcp/udp/both): " proto
    cli_port_update add "$proto" "$port"
}

menu_del_port() {
    local port proto
    read -r -p "❌ 请输入要取消放行的端口或范围: " port
    read -r -p "🔹 协议类型 (tcp/udp/both): " proto
    cli_port_update remove "$proto" "$port"
}

menu_show_ports() {
    echo -e "\n=== 🔓 开放端口一览 ==="
    cli_port_list
    echo ""
}

menu_add_blacklist() {
    local ip work current existing
    read -r -p "🚫 请输入要封禁的 IP 或网段: " ip
    [ -n "$ip" ] || return

    # 黑名单就是一个名为 blacklist 的 Target 加一条 block 规则。
    work=$(mktemp -d)
    current="$work/current.json"
    if cli_read_state "$current" &&
        existing=$(model_resolve "$current" target blacklist 2>/dev/null); then
        local addresses
        addresses=$(jq -r --arg id "$existing" \
            '.targets[] | select(.id == $id) | .addresses | join(",")' "$current")
        rm -rf "$work"
        cli_object_dispatch target edit blacklist --address "$addresses,$ip"
    else
        rm -rf "$work"
        cli_object_dispatch target add blacklist "$ip" &&
            cli_object_dispatch rule add blacklist --type block \
                --source blacklist --priority 10
    fi
}

menu_del_blacklist() {
    local ip work current existing addresses remaining
    read -r -p "🟢 请输入要解封的 IP 或网段: " ip
    [ -n "$ip" ] || return

    work=$(mktemp -d)
    current="$work/current.json"
    if ! cli_read_state "$current" ||
        ! existing=$(model_resolve "$current" target blacklist 2>/dev/null); then
        rm -rf "$work"
        echo "ℹ️ 黑名单为空，未做修改"
        return
    fi
    addresses=$(jq -r --arg id "$existing" \
        '.targets[] | select(.id == $id) | .addresses | join(",")' "$current")
    rm -rf "$work"

    remaining=$(tr ',' '\n' <<< "$addresses" | grep -Fxv "$ip" | paste -sd,)
    if [[ "$remaining" == "$addresses" ]]; then
        echo "ℹ️ $ip 不在黑名单中，未做修改"
        return
    fi
    if [[ -z "$remaining" ]]; then
        # 最后一个地址被移除：Target 的 addresses 不能为空，连同规则一起删除。
        cli_object_dispatch target delete blacklist --cascade
    else
        cli_object_dispatch target edit blacklist --address "$remaining"
    fi
}

menu_show_blacklist() {
    local work current
    echo -e "\n=== 🚫 恶意 IP 黑名单 ==="
    work=$(mktemp -d)
    current="$work/current.json"
    if cli_read_state "$current"; then
        jq -r '.targets[] | select(.name == "blacklist") | .addresses[]' "$current" 2>/dev/null
    fi
    rm -rf "$work"
    echo ""
}

menu_objects() {
    echo -e "\n=== 📦 对象管理 ==="
    echo "--- Target ---"
    cli_list target
    echo "--- Service ---"
    cli_list service
    echo "--- Rule ---"
    cli_list rule
    echo ""
    echo "提示：使用 $FWCTL_COMMAND_NAME target/service/rule 子命令进行增删改。"
    echo ""
}

menu_backup() {
    local choice id
    echo "1. 创建备份   2. 查看备份列表   3. 从备份恢复"
    read -r -p "请选择 [1-3]: " choice
    case "$choice" in
        1) cli_backup create ;;
        2) cli_backup list ;;
        3)
            cli_backup list
            read -r -p "请输入要恢复的 backup-id: " id
            [ -n "$id" ] && cli_restore "$id"
            ;;
        *) echo "❌ 无效输入" ;;
    esac
}

run_menu() {
    local opt
    while true; do
        echo "========================="
        echo "   Firewall Manager   "
        echo "========================="
        echo "1. 添加端口转发    2. 删除端口转发    3. 查看端口转发"
        echo "-------------------------------------------------"
        echo "4. 放行端口        5. 删除放行端口    6. 查看放行端口"
        echo "-------------------------------------------------"
        echo "7. 封禁IP          8. 解封IP          9. 查看黑名单"
        echo "-------------------------------------------------"
        echo "10. SSH防爆破 (模版默认常开)"
        echo "11. DDOS防护  (模版默认常开)"
        echo "12. 重载配置  (强制重新编译)"
        echo "-------------------------------------------------"
        echo "13. 对象管理  (target / service / rule)"
        echo "14. 体检      (doctor)"
        echo "15. 备份与恢复 (backup / restore)"
        echo "16. 流量统计  (stats)"
        echo "0. 退出"
        echo "========================="
        read -r -p "请选择操作 [0-16]: " opt
        case $opt in
            1) menu_add_forward ;;
            2) menu_del_forward ;;
            3) menu_show_forward ;;
            4) menu_add_port ;;
            5) menu_del_port ;;
            6) menu_show_ports ;;
            7) menu_add_blacklist ;;
            8) menu_del_blacklist ;;
            9) menu_show_blacklist ;;
            10|11) echo "ℹ️ 防护逻辑由 settings.policy 控制，默认与旧版本一致。" ;;
            12) cli_render ;;
            13) menu_objects ;;
            14) cli_doctor ;;
            15) menu_backup ;;
            16) cli_stats ;;
            0) exit 0 ;;
            *) echo "❌ 无效输入" ;;
        esac
    done
}

# ── 入口 ──────────────────────────────────────────────────────────────

# 任何命令启动时都先收敛未完成的事务。
txn_recover || exit $?

cli_main "$@"
rc=$?

# 100 是 cli_main 用来表示「没有参数」的内部约定，转为交互菜单。
if ((rc == 100)); then
    run_menu
fi

exit "$rc"
