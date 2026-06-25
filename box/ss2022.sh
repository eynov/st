#!/bin/bash

# ========================================================
#  Shadowsocks-Rust
# ========================================================

# ========== 全局变量与目录配置 ==========
SS_DIR="/etc/shadowsocks"
SS_EXEC="/usr/local/bin/ss-server"
SS_BACKUP="/usr/local/bin/ss-server.bak"
INSTANCES_JSON="${SS_DIR}/instances.json"
SURGE_FILE="${SS_DIR}/surge_nodes.conf"
QR_DIR="${SS_DIR}/qrcodes"
LOCK_FILE="/tmp/ss.lock"
LOG_DIR="/var/log/shadowsocks"

# ========== 1. 核心防御：全局进程互斥锁 ==========
exec 200>"$LOCK_FILE"
flock -n 200 || {
  echo "❌ 另一个实例正在运行，请勿重复操作。"
  exit 1
}

# 确保核心目录存在
sudo mkdir -p "${SS_DIR}" "${QR_DIR}" "${LOG_DIR}"

# ========== 2. 初始化中央状态机 ==========
init_json() {
  if [ ! -f "$INSTANCES_JSON" ] || [ ! -s "$INSTANCES_JSON" ]; then
    sudo tee "$INSTANCES_JSON" > /dev/null << 'EOF'
{
  "core": {
    "current_version": "none",
    "backup_version": "none",
    "last_upgrade": "none"
  },
  "ports": {}
}
EOF
  fi
}

# ========== 3. 读写工具（环境变量传参 + fcntl 文件锁） ==========
# [F1] 全部改用环境变量传参，彻底消除 Shell → Python 字符串注入风险

update_json_core() {
  # [F2] 修复：每行一个 local 声明
  local cur_v=$1
  local bak_v=$2
  local time_str=$3

  CUR_V="$cur_v" BAK_V="$bak_v" TIME_STR="$time_str" \
  python3 - << 'PYEOF'
import json, fcntl, os
cur_v    = os.environ.get('CUR_V', '')
bak_v    = os.environ.get('BAK_V', '')
time_str = os.environ.get('TIME_STR', '')
path     = os.environ.get('INSTANCES_JSON', '/etc/shadowsocks/instances.json')
try:
    with open(path, 'r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        d = json.load(f)
        if cur_v:    d['core']['current_version'] = cur_v
        if bak_v:    d['core']['backup_version']  = bak_v
        if time_str: d['core']['last_upgrade']    = time_str
        f.seek(0); json.dump(d, f, indent=2); f.truncate()
        fcntl.flock(f, fcntl.LOCK_UN)
except Exception as e:
    print(f'❌ JSON 读写异常: {e}')
PYEOF
}

update_json_port() {
  local port=$1
  local proto=$2
  local method=$3
  local state=$4
  local sub_state=$5

  PORT="$port" PROTO="$proto" METHOD="$method" STATE="$state" SUB_STATE="$sub_state" \
  INSTANCES_JSON="$INSTANCES_JSON" \
  python3 - << 'PYEOF'
import json, datetime, fcntl, os
port      = os.environ['PORT']
proto     = os.environ['PROTO']
method    = os.environ['METHOD']
state     = os.environ['STATE']
sub_state = os.environ['SUB_STATE']
path      = os.environ['INSTANCES_JSON']
try:
    with open(path, 'r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        d = json.load(f)
        d['ports'][port] = {
            'protocol':   proto,
            'method':     method,
            'state':      state,
            'sub_state':  sub_state,
            'updated_at': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        }
        f.seek(0); json.dump(d, f, indent=2); f.truncate()
        fcntl.flock(f, fcntl.LOCK_UN)
except Exception as e:
    print(f'❌ 端口标记异常: {e}')
PYEOF
}

delete_json_port() {
  local port=$1

  PORT="$port" INSTANCES_JSON="$INSTANCES_JSON" \
  python3 - << 'PYEOF'
import json, fcntl, os
port = os.environ['PORT']
path = os.environ['INSTANCES_JSON']
try:
    with open(path, 'r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        d = json.load(f)
        if port in d['ports']:
            del d['ports'][port]
        f.seek(0); json.dump(d, f, indent=2); f.truncate()
        fcntl.flock(f, fcntl.LOCK_UN)
except Exception as e:
    print(f'❌ 注销端口异常: {e}')
PYEOF
}

# ========== 4. 高级原子升级（显式错误链替代 trap ERR） ==========
# [F4] 去掉不可靠的 trap ERR，改为 || return 1 显式链
# [F5] curl/wget 增加 --max-time / --timeout 与 --retry

upgrade_core() {
  echo ">> 启动自动化原子升级模块..."
  init_json

  local OLD_VERSION
  OLD_VERSION=$(INSTANCES_JSON="$INSTANCES_JSON" python3 - << 'PYEOF'
import json, os
try:
    print(json.load(open(os.environ['INSTANCES_JSON']))['core']['current_version'])
except:
    print('none')
PYEOF
)

  # GitHub API + 下载均走 fallback（部分 VPS 直连 api.github.com 被墙）
  local API_LIST=(
    "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
    "https://ghfast.top/https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
    "https://gh.con.sh/https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
  )

  local LATEST_DATA=""
  for api_url in "${API_LIST[@]}"; do
    echo "  >> 尝试获取 Release 信息: ${api_url%%repos*}..."
    LATEST_DATA=$(curl --max-time 15 --retry 2 -fsSL "$api_url" 2>/dev/null) && \
    echo "$LATEST_DATA" | grep -q "tag_name" && break
    LATEST_DATA=""
  done

  [ -n "$LATEST_DATA" ] || {
    echo "❌ 无法获取 GitHub Release 信息（所有 API 源均失败）"
    return 1
  }

  local URL LATEST_VERSION
  URL=$(echo "$LATEST_DATA" | grep browser_download_url | grep x86_64-unknown-linux-gnu.tar.xz | cut -d '"' -f4)
  LATEST_VERSION=$(echo "$LATEST_DATA" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

  if [ -z "$URL" ]; then
    echo "❌ 无法从 Release 信息中提取下载链接"
    return 1
  fi

  if [ "$OLD_VERSION" = "$LATEST_VERSION" ]; then
    echo "💎 当前系统内核已是最新版本 ($LATEST_VERSION)，无需更新。"
    return 0
  fi

  echo ">> 发现新版本: ${LATEST_VERSION} (本地当前版本: ${OLD_VERSION:-无})"

  local TMP_FILE="/tmp/ss_upgrade.tar.xz"
  local TMP_UNPACK="/tmp/ss_upgrade_unpack"
  rm -rf "$TMP_FILE" "$TMP_UNPACK" && mkdir -p "$TMP_UNPACK"

  echo ">> 正在安全下载最新生产包..."

  # 代理列表：先直连，失败依次 fallback
  local PROXY_LIST=(
    ""
    "https://ghfast.top/"
    "https://gh.con.sh/"
    "https://mirror.ghproxy.com/"
  )

  local download_ok=0
  for prefix in "${PROXY_LIST[@]}"; do
    local TRY_URL="${prefix}${URL}"
    if [ -z "$prefix" ]; then
      echo "  >> 尝试直连下载..."
    else
      echo "  >> 直连失败，尝试代理: ${prefix}"
    fi

    wget --timeout=30 --tries=2 -q --show-progress -O "$TMP_FILE" "$TRY_URL" &&     file "$TMP_FILE" 2>/dev/null | grep -q "XZ compressed data" && {
      download_ok=1
      break
    }
    rm -f "$TMP_FILE"
  done

  [ "$download_ok" -eq 1 ] || {
    echo "❌ 所有下载源均失败（直连 + 3 个代理），请检查 VPS 网络"
    return 1
  }

  file "$TMP_FILE" | grep -q "XZ compressed data" || {
    echo "❌ 下载文件损坏（非标准 XZ 压缩数据），终止操作"
    return 1
  }

  tar -xJf "$TMP_FILE" -C "$TMP_UNPACK" || {
    echo "❌ 解压失败"
    return 1
  }

  [ -f "${TMP_UNPACK}/ssserver" ] || {
    echo "❌ 架构安全校验失败：解压包中未包含 ssserver"
    return 1
  }

  "${TMP_UNPACK}/ssserver" -h >/dev/null 2>&1 || {
    echo "❌ 新版本 binary 不可执行（可能是架构不匹配或二进制损坏）"
    return 1
  }

  echo ">> 执行原子级替换与备份追踪..."
  if [ -f "$SS_EXEC" ]; then
    sudo cp -f "$SS_EXEC" "$SS_BACKUP" || {
      echo "❌ 备份旧版本失败"
      return 1
    }
    update_json_core "" "$OLD_VERSION" ""
  fi

  sudo mv "${TMP_UNPACK}/ssserver" "$SS_EXEC" || {
    echo "❌ 替换二进制失败"
    return 1
  }
  sudo chmod +x "$SS_EXEC"

  echo ">> 正在安全热重启所有预期状态为 active 的实例..."
  INSTANCES_JSON="$INSTANCES_JSON" python3 - << 'PYEOF'
import json, subprocess, os
path = os.environ['INSTANCES_JSON']
try:
    d = json.load(open(path))
    for port, info in d.get('ports', {}).items():
        if info.get('state') == 'active':
            r = subprocess.run(['sudo', 'systemctl', 'restart', f'ss{port}'], check=False)
            status = '✅' if r.returncode == 0 else '⚠️'
            print(f'{status} 端口 {port} 重启{"成功" if r.returncode == 0 else "失败（请手动检查）"}')
except Exception as e:
    print(f'❌ 批量重启异常: {e}')
PYEOF

  update_json_core "$LATEST_VERSION" "" "$(date +"%Y-%m-%d %H:%M:%S")"
  echo "✅ 原子替换升级圆满完成。当前在线版本: $LATEST_VERSION"
  rm -rf "$TMP_FILE" "$TMP_UNPACK"
}

# ========== 5. 一键回滚（物理备份校验） ==========
rollback_core() {
  init_json

  local cur_v
  local bak_v
  cur_v=$(INSTANCES_JSON="$INSTANCES_JSON" python3 -c \
    "import json,os; print(json.load(open(os.environ['INSTANCES_JSON']))['core']['current_version'])" 2>/dev/null)
  bak_v=$(INSTANCES_JSON="$INSTANCES_JSON" python3 -c \
    "import json,os; print(json.load(open(os.environ['INSTANCES_JSON']))['core']['backup_version'])" 2>/dev/null)

  [ -f "$SS_BACKUP" ] || {
    echo "❌ 无本地 backup binary，无法回滚"
    return 1
  }

  echo ">> 启动灾备恢复：正在回滚至历史稳定版 $bak_v ..."
  sudo mv -f "$SS_EXEC" /tmp/ss_failed_version_dump || true
  sudo mv -f "$SS_BACKUP" "$SS_EXEC" || {
    echo "❌ 回滚替换失败"
    return 1
  }
  sudo chmod +x "$SS_EXEC"

  echo ">> 正在重启受控节点实例..."
  INSTANCES_JSON="$INSTANCES_JSON" python3 - << 'PYEOF'
import json, subprocess, os
path = os.environ['INSTANCES_JSON']
try:
    d = json.load(open(path))
    for port, info in d.get('ports', {}).items():
        if info.get('state') == 'active':
            r = subprocess.run(['sudo', 'systemctl', 'restart', f'ss{port}'], check=False)
            status = '✅' if r.returncode == 0 else '⚠️'
            print(f'{status} 端口 {port} 重启{"成功" if r.returncode == 0 else "失败"}')
except Exception as e:
    print(f'❌ JSON 损坏或重启异常: {e}')
    exit(1)
PYEOF

  update_json_core "$bak_v" "$cur_v" "$(date +"%Y-%m-%d %H:%M:%S")"
  echo "✅ 灾备状态回滚成功！当前激活版本: $bak_v"
}

# ========== 工具函数：生成标准 ss:// URI ==========
# [OPT] 标准 Base64 URI，兼容 Shadowrocket / Clash 等客户端
gen_ss_uri() {
  local method=$1
  local password=$2
  local server=$3
  local port=$4
  local tag=$5
  # ss://BASE64(method:password)@server:port#tag
  local userinfo
  userinfo=$(echo -n "${method}:${password}" | base64 -w0)
  echo "ss://${userinfo}@${server}:${port}#${tag}"
}

# ========== 6. 扫描接管现有节点 ==========
import_existing() {
  init_json
  echo ">> 开始扫描现有 Shadowsocks 节点配置..."

  # 扫描所有 config*.json（支持 /etc/shadowsocks/ 及常见备选路径）
  local SCAN_DIRS="/etc/shadowsocks /etc/shadowsocks-libev"
  local found=0

  for SCAN_DIR in $SCAN_DIRS; do
    [ -d "$SCAN_DIR" ] || continue
    for CONF in "${SCAN_DIR}"/config*.json; do
      [ -f "$CONF" ] || continue

      # 用 Python 解析配置，避免 jq 依赖
      CONF="$CONF" python3 - << 'PYEOF'
import json, os, subprocess, sys

conf_path = os.environ['CONF']
inst_path = os.environ.get('INSTANCES_JSON', '/etc/shadowsocks/instances.json')

try:
    with open(conf_path) as f:
        c = json.load(f)
except Exception as e:
    print(f'  ⚠️  跳过 {conf_path}：JSON 解析失败 ({e})')
    sys.exit(0)

port   = str(c.get('server_port', ''))
method = c.get('method', 'unknown')

if not port:
    print(f'  ⚠️  跳过 {conf_path}：未找到 server_port')
    sys.exit(0)

# 判断协议类型
proto = 'ss2022' if '2022' in method else 'ss'

# 检查 systemd service 实际运行状态
svc = f'ss{port}'
res = subprocess.run(['systemctl', 'is-active', svc], capture_output=True, text=True)
real_state = 'running' if res.returncode == 0 else 'stopped'
expect_state = 'active' if real_state == 'running' else 'inactive'

import fcntl, datetime
try:
    with open(inst_path, 'r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        d = json.load(f)
        if port in d['ports']:
            print(f'  ℹ️  端口 {port} 已在状态机中，跳过（如需强制覆盖请先注销）')
            fcntl.flock(f, fcntl.LOCK_UN)
            sys.exit(0)
        d['ports'][port] = {
            'protocol':   proto,
            'method':     method,
            'state':      expect_state,
            'sub_state':  real_state,
            'conf_path':  conf_path,
            'updated_at': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        }
        f.seek(0); json.dump(d, f, indent=2); f.truncate()
        fcntl.flock(f, fcntl.LOCK_UN)
    print(f'  ✅ 端口 {port} | 协议: {proto} | 算法: {method} | 物理状态: {real_state} → 已接管')
except Exception as e:
    print(f'  ❌ 端口 {port} 写入状态机失败: {e}')
PYEOF
      found=$((found + 1))
    done
  done

  # 额外：扫描正在运行但没有 config*.json 的 ssserver 进程（兜底）
  echo ">> 扫描运行中 ssserver 进程（兜底检测）..."
  ss_pids=$(pgrep -x ssserver 2>/dev/null || pgrep -x ss-server 2>/dev/null || true)
  if [ -n "$ss_pids" ]; then
    for pid in $ss_pids; do
      cmdline=$(cat /proc/"$pid"/cmdline 2>/dev/null | tr '\0' ' ')
      conf=$(echo "$cmdline" | grep -oP '(?<=-c )\S+' || true)
      if [ -n "$conf" ] && [ -f "$conf" ]; then
        echo "  >> 进程 $pid 使用配置: $conf"
        CONF="$conf" INSTANCES_JSON="$INSTANCES_JSON" python3 - << 'PYEOF'
import json, os, fcntl, datetime, sys
conf_path = os.environ['CONF']
inst_path = os.environ['INSTANCES_JSON']
try:
    c = json.load(open(conf_path))
    port   = str(c.get('server_port', ''))
    method = c.get('method', 'unknown')
    proto  = 'ss2022' if '2022' in method else 'ss'
    if not port:
        sys.exit(0)
    with open(inst_path, 'r+') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        d = json.load(f)
        if port not in d['ports']:
            d['ports'][port] = {
                'protocol':   proto,
                'method':     method,
                'state':      'active',
                'sub_state':  'running',
                'conf_path':  conf_path,
                'updated_at': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            }
            f.seek(0); json.dump(d, f, indent=2); f.truncate()
            print(f'  ✅ 进程兜底接管：端口 {port} | 算法: {method}')
        fcntl.flock(f, fcntl.LOCK_UN)
except Exception as e:
    print(f'  ⚠️  进程兜底失败: {e}')
PYEOF
      fi
    done
  fi

  if [ "$found" -eq 0 ] && [ -z "$ss_pids" ]; then
    echo "  ℹ️  未发现任何现有节点配置文件，无需导入。"
  else
    echo ""
    echo "✅ 扫描接管完成，当前状态机快照："
    echo "--------------------------------------------------"
    INSTANCES_JSON="$INSTANCES_JSON" python3 - << 'PYEOF'
import json, os
path = os.environ['INSTANCES_JSON']
d = json.load(open(path))
for port, info in d.get('ports', {}).items():
    print(f"端口: {port} | 协议: {info.get('protocol')} | 算法: {info.get('method')} | 状态: {info.get('state')} / {info.get('sub_state')}")
PYEOF
    echo "--------------------------------------------------"
    echo ">> 现在可使用菜单选项 4 执行内核升级，升级后所有 active 节点将自动热重启。"
  fi
}

# ========== 初始化动作 ==========
init_json

# ========== 启动前自愈自检 ==========
if [ -f "$SS_EXEC" ]; then
  "$SS_EXEC" -h >/dev/null 2>&1 || {
    echo "❌ ss-server 已损坏或无法运行，触发自动修复程序..."
    upgrade_core || { echo "❌ 自动修复失败，请手动检查"; exit 1; }
  }
fi

# ========== 交互式主菜单 ==========
echo "=================================================="
echo " Shadowsocks-Rust 企业级控制台（高级加固版 v2）"
echo "=================================================="
echo "1) 批量新增并上线节点"
echo "2) 安全注销并删除节点"
echo "3) 全量查看活跃节点与 Core 状态"
echo "4) 检查并执行原子内核升级 (Upgrade)"
echo "5) 一键崩溃灾备回滚 (Rollback)"
echo "6) 扫描并接管现有节点 (Import)"
echo "0) 安全退出"
echo "=================================================="
read -rp "请输入操作代码 [0-6]: " MODE

case $MODE in
  4) upgrade_core; exit 0 ;;
  5) rollback_core; exit 0 ;;
  6) import_existing; exit 0 ;;
  2) DELETE_MODE=1 ;;
  3) LIST_MODE=1 ;;
  0) exit 0 ;;
  *) ;;
esac

# ========== 动态依赖补全 ==========
if [ ! -f "$SS_EXEC" ]; then
  echo ">> 系统未发现运行内核，正在触发首次环境构建..."
  upgrade_core || { echo "❌ 初始化运行环境失败"; exit 1; }
fi

if ! command -v qrencode >/dev/null 2>&1; then
  echo ">> 正在补全核心系统依赖组件 (qrencode)..."
  sudo apt update && sudo apt install -y qrencode file >/dev/null 2>&1
fi

# ========== 功能模块：删除节点 ==========
if [ "$DELETE_MODE" = "1" ]; then
  read -rp "请输入需要安全下线的端口号（空格分隔）: " PORTS
  for PORT in $PORTS; do
    sudo systemctl stop "ss${PORT}"   2>/dev/null || true
    sudo systemctl disable "ss${PORT}" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/ss${PORT}.service"
    sudo rm -f "${SS_DIR}/config${PORT}.json"
    delete_json_port "$PORT"
    echo "🗑 端口 ${PORT} 已彻底执行下线隔离并注销。"
  done
  sudo systemctl daemon-reload
  exit 0
fi

# ========== 功能模块：状态盘点 ==========
if [ "$LIST_MODE" = "1" ]; then
  echo "=================================================="
  CURRENT_VER=$(INSTANCES_JSON="$INSTANCES_JSON" python3 -c \
    "import json,os; print(json.load(open(os.environ['INSTANCES_JSON']))['core']['current_version'])" 2>/dev/null)
  echo "  Core 状态  | 运行内核: ${CURRENT_VER}"
  echo "=================================================="
  echo " 实例清单 (State Matrix) ："
  echo "--------------------------------------------------"

  INSTANCES_JSON="$INSTANCES_JSON" python3 - << 'PYEOF'
import json, subprocess, os
path = os.environ['INSTANCES_JSON']
try:
    d = json.load(open(path))
    for port, info in d.get('ports', {}).items():
        res = subprocess.run(['systemctl', 'is-active', f'ss{port}'],
                             capture_output=True, text=True)
        real_sub = 'running' if res.returncode == 0 else 'stopped'
        print(f"端口: {port} | 协议: {info.get('protocol')} | 算法: {info.get('method')}")
        print(f"预期状态(State): {info.get('state')} | 物理状态(Sub-state): {real_sub}")
        print('-' * 50)
except Exception as e:
    print(f'❌ JSON 损坏: {e}')
    exit(1)
PYEOF
  exit 0
fi

# ========== 功能模块：批量新增节点 ==========
read -rp "请输入中转域名/落地IP（留空则自动抓取本地公网 IP）: " SERVER_DOMAIN
# [F5] 增加超时
SERVER_IP=${SERVER_DOMAIN:-$(curl --max-time 10 -s -4 ifconfig.me)}
echo ">> 当前入站目标寻址地址: $SERVER_IP"

echo "请选择运行协议簇："
echo "  1) Shadowsocks Legacy (SS)"
echo "  2) Shadowsocks 2022 Standard (SS2022)"
read -rp "选择选项 (1-2, 默认 1): " PROTO_OPT
PROTO="ss"; [ "$PROTO_OPT" = "2" ] && PROTO="ss2022"

read -rp "请输入待部署的批量端口号（空格分隔）: " PORTS
echo "# Surge Declarative Proxy System" > "$SURGE_FILE"
# [OPT] 同步生成标准 ss:// URI 列表
SS_URI_FILE="${SS_DIR}/ss_uris.txt"
echo "# Standard ss:// URI List" > "$SS_URI_FILE"

for PORT in $PORTS; do
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo ">> [跳过] 无效非法端口规范: $PORT"
    continue
  fi

  SS_CONF="${SS_DIR}/config${PORT}.json"
  SYSTEMD_SERVICE="/etc/systemd/system/ss${PORT}.service"

  if [ "$PROTO" = "ss" ]; then
    echo "请指定传统端口 ${PORT} 的流控加密方式："
    echo "  1) none"
    echo "  2) aes-128-gcm"
    echo "  3) aes-256-gcm"
    echo "  4) chacha20-ietf-poly1305"
    read -rp "加密指引 (1-4, 默认 4): " METHOD_OPT
    case "$METHOD_OPT" in
      1) METHOD="none" ;;
      2) METHOD="aes-128-gcm" ;;
      3) METHOD="aes-256-gcm" ;;
      *) METHOD="chacha20-ietf-poly1305" ;;
    esac
    PASSWORD=$(openssl rand -hex 16)

    sudo tee "${SS_CONF}" > /dev/null << EOL
{
  "server": "0.0.0.0",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "method": "${METHOD}",
  "timeout": 300,
  "mode": "tcp_and_udp"
}
EOL

    SURGE_LINK="SS_${PORT} = ss, ${SERVER_IP}, ${PORT}, encrypt-method=${METHOD}, password=${PASSWORD}, udp-relay=true"
    # [OPT] 生成标准 URI
    SS_URI=$(gen_ss_uri "$METHOD" "$PASSWORD" "$SERVER_IP" "$PORT" "SS_${PORT}")

  else
    echo "请指定标准 2022 端口 ${PORT} 的强制对称加密算法："
    echo "  1) 2022-blake3-aes-128-gcm"
    echo "  2) 2022-blake3-aes-256-gcm"
    echo "  3) 2022-blake3-chacha20-poly1305"
    read -rp "算法指引 (1-3, 默认 1): " METHOD_OPT
    case "$METHOD_OPT" in
      2) METHOD="2022-blake3-aes-256-gcm";       KEY_SIZE=64 ;;
      3) METHOD="2022-blake3-chacha20-poly1305";  KEY_SIZE=64 ;;
      *) METHOD="2022-blake3-aes-128-gcm";        KEY_SIZE=32 ;;
    esac

    # [F3] 改用 hex 避免 base64 特殊字符污染 Surge/URI 格式
    MASTER_KEY=$(openssl rand -hex "$KEY_SIZE")
    SUB_KEY=$(openssl rand -hex "$KEY_SIZE")

    # SS2022 密码字段在配置文件中需要 base64 格式
    MASTER_KEY_B64=$(echo -n "$MASTER_KEY" | xxd -r -p | base64 -w0)
    SUB_KEY_B64=$(echo -n "$SUB_KEY"    | xxd -r -p | base64 -w0)

    sudo tee "${SS_CONF}" > /dev/null << EOL
{
  "server": "0.0.0.0",
  "server_port": ${PORT},
  "method": "${METHOD}",
  "password": "${MASTER_KEY_B64}",
  "users": [
    {
      "name": "user1",
      "password": "${SUB_KEY_B64}"
    }
  ]
}
EOL

    SURGE_LINK="SS2022_${PORT} = ss, ${SERVER_IP}, ${PORT}, encrypt-method=${METHOD}, password=${SUB_KEY_B64}, udp-relay=true"
    SS_URI=$(gen_ss_uri "$METHOD" "$SUB_KEY_B64" "$SERVER_IP" "$PORT" "SS2022_${PORT}")
  fi

  # [OPT] systemd 服务追加日志输出
  sudo tee "${SYSTEMD_SERVICE}" > /dev/null << EOL
[Unit]
Description=Shadowsocks Declarative Node Service on Port ${PORT}
After=network.target

[Service]
ExecStart=${SS_EXEC} -c ${SS_CONF}
StandardOutput=append:${LOG_DIR}/ss${PORT}.log
StandardError=append:${LOG_DIR}/ss${PORT}.log
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL

  sudo systemctl daemon-reload
  sudo systemctl enable "ss${PORT}" >/dev/null 2>&1
  sudo systemctl restart "ss${PORT}"

  update_json_port "$PORT" "$PROTO" "$METHOD" "active" "running"

  echo "✅ 端口 ${PORT} 已成功上线。"
  echo "$SURGE_LINK" >> "$SURGE_FILE"
  echo "$SS_URI"     >> "$SS_URI_FILE"

  # 生成两种二维码：Surge 格式 + 标准 ss:// URI
  qrencode -o "${QR_DIR}/${PORT}_surge.png" -t PNG "$SURGE_LINK"
  qrencode -o "${QR_DIR}/${PORT}_ssuri.png" -t PNG "$SS_URI"
done

echo ""
echo ">> 批量新增执行完毕。"
echo "   Surge 代理行  → $SURGE_FILE"
echo "   标准 ss:// URI → $SS_URI_FILE"
echo "   二维码目录     → $QR_DIR"
