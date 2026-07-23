#!/bin/bash
set -euo pipefail

LOCKFILE="${FWCTL_LOCKFILE:-/var/lock/fwctl_render.lock}"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    echo "❌ render 正在执行，跳过" >&2
    exit 1
fi

REAL_SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
BASE_DIR="$(cd "$(dirname "$REAL_SCRIPT_PATH")" && pwd)"
STATE_FILE="${FWCTL_STATE_FILE:-$BASE_DIR/state.json}"
BUILD_DIR="${FWCTL_BUILD_DIR:-$BASE_DIR/build}"
BUILD_CONF="$BUILD_DIR/nft.conf"
SYSTEM_CONF="${FWCTL_SYSTEM_CONF:-/etc/nftables.conf}"
NFT_BIN="${FWCTL_NFT_BIN:-nft}"
APPLY_RULES="${FWCTL_APPLY:-1}"

usage() {
    echo "用法: render.sh [--check|--render-only]"
}

case "${1:-}" in
    "") ;;
    --check|--render-only) APPLY_RULES=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

if [[ $EUID -ne 0 && "${FWCTL_ALLOW_UNPRIVILEGED:-0}" != 1 ]]; then
    echo "❌ 编译器必须以 root 权限运行" >&2
    exit 1
fi

for command in jq flock "$NFT_BIN"; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "❌ 缺少依赖：$command" >&2
        exit 1
    fi
done

is_ipv4() {
    local ip=$1 octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
}

local_ipv4s() {
    if [[ -n "${FWCTL_LOCAL_IPV4S:-}" ]]; then
        tr ' ,' '\n\n' <<< "$FWCTL_LOCAL_IPV4S" | sed '/^$/d'
    else
        ip -4 -o addr show | awk '{split($4, addr, "/"); print addr[1]}'
    fi
}

address_is_local() {
    local candidate=$1
    local_ipv4s | grep -Fxq "$candidate"
}

discover_public_ipv4() {
    local candidate=""
    if [[ -n "${FWCTL_PUBLIC_IPV4:-}" ]]; then
        candidate=$FWCTL_PUBLIC_IPV4
    elif command -v curl >/dev/null 2>&1; then
        local endpoint
        for endpoint in \
            https://api.ip.sb/ip \
            https://ifconfig.me \
            https://api.ipify.org \
            https://ip4.seeip.org; do
            candidate=$(curl -fsS4 -m 5 "$endpoint" 2>/dev/null || true)
            candidate=${candidate//$'\n'/}
            is_ipv4 "$candidate" && break
            candidate=""
        done
    fi
    [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

validate_state() {
    jq empty "$STATE_FILE" >/dev/null 2>&1 || {
        echo "❌ state.json 不是合法 JSON" >&2
        return 1
    }

    jq -e '
        (.forwards | type == "array") and
        (.open_ports | type == "object") and
        (.open_ports.tcp | type == "array") and
        (.open_ports.udp | type == "array") and
        (.blacklist | type == "array") and
        ((.nat_mode // "auto") | IN("auto", "snat", "masquerade")) and
        ([.open_ports.tcp[], .open_ports.udp[]] |
            all(type == "string" and test("^[0-9]+$")
                and ((tonumber >= 1) and (tonumber <= 65535)))) and
        (.forwards | all(
            (.proto | IN("tcp", "udp")) and
            (.sport | type == "string" and test("^[0-9]+$")) and
            (.dport | type == "string" and test("^[0-9]+$")) and
            ((.sport | tonumber) >= 1 and (.sport | tonumber) <= 65535) and
            ((.dport | tonumber) >= (.sport | tonumber)
                and (.dport | tonumber) <= 65535) and
            ((.dest_port // .sport) | type == "string" and test("^[0-9]+$")) and
            (((.dest_port // .sport) | tonumber) >= 1
                and ((.dest_port // .sport) | tonumber) <= 65535)
        ))
    ' "$STATE_FILE" >/dev/null || {
        mode=$(jq -r '.nat_mode // "auto"' "$STATE_FILE" 2>/dev/null || true)
        if [[ ! "$mode" =~ ^(auto|snat|masquerade)$ ]]; then
            echo "❌ 非法 nat_mode '$mode'；允许值：auto、snat、masquerade" >&2
        else
            echo "❌ state.json schema 或端口范围无效" >&2
        fi
        return 1
    }
}

select_nat_action() {
    local mode configured candidate
    mode=$(jq -r '.nat_mode // "auto"' "$STATE_FILE")
    configured=$(jq -r '.snat_address // empty' "$STATE_FILE")

    case "$mode" in
        masquerade)
            echo "ℹ️ NAT 模式：masquerade（使用出口接口地址）" >&2
            printf 'masquerade\n'
            ;;
        snat)
            if [[ -z "$configured" ]] || ! is_ipv4 "$configured"; then
                echo "❌ nat_mode=snat 要求提供合法的 snat_address" >&2
                return 1
            fi
            if ! address_is_local "$configured"; then
                echo "❌ snat_address $configured 未配置在本机任一 IPv4 接口，拒绝生成规则" >&2
                return 1
            fi
            echo "ℹ️ NAT 模式：snat to $configured" >&2
            printf 'snat to %s\n' "$configured"
            ;;
        auto)
            candidate=$configured
            [[ -n "$candidate" ]] || candidate=$(discover_public_ipv4 || true)
            if [[ -n "$candidate" ]] && is_ipv4 "$candidate" && address_is_local "$candidate"; then
                echo "ℹ️ NAT auto：公网地址 $candidate 存在于本机接口，使用显式 SNAT" >&2
                printf 'snat to %s\n' "$candidate"
            else
                if [[ -z "$candidate" ]]; then
                    echo "⚠️ NAT auto：无法可靠获取公网 IPv4，安全回退到 masquerade" >&2
                elif ! is_ipv4 "$candidate"; then
                    echo "⚠️ NAT auto：候选公网地址 '$candidate' 无效，安全回退到 masquerade" >&2
                else
                    echo "ℹ️ NAT auto：公网地址 $candidate 不在本机接口（1:1 NAT/EIP），使用 masquerade" >&2
                fi
                printf 'masquerade\n'
            fi
            ;;
    esac
}

atomic_copy() {
    local source=$1 target=$2 target_dir tmp
    target_dir=$(dirname "$target")
    mkdir -p "$target_dir"
    tmp=$(mktemp "$target_dir/.fwctl.$(basename "$target").XXXXXX")
    cp "$source" "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$target"
}

validate_state
mkdir -p "$BUILD_DIR"
BUILD_TMP=$(mktemp "$BUILD_DIR/.nft.conf.XXXXXX")
trap 'rm -f "$BUILD_TMP"' EXIT

if [[ "${FWCTL_SKIP_SYSTEM_SETUP:-0}" != 1 ]]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-forward.conf
fi

SSH_PORT="${FWCTL_SSH_PORT:-}"
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=$(ss -tlnp | awk '/sshd/ {sub(/^.*:/, "", $4); print $4; exit}')
    [[ -n "$SSH_PORT" ]] || SSH_PORT=$(awk '/^[[:space:]]*Port[[:space:]]/ {print $2; exit}' /etc/ssh/sshd_config)
    [[ -n "$SSH_PORT" ]] || SSH_PORT=22
fi
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && ((SSH_PORT >= 1 && SSH_PORT <= 65535)) || {
    echo "❌ 无法确定合法的 SSH 端口" >&2
    exit 1
}

BLACKLIST=$(jq -r '.blacklist | join(", ")' "$STATE_FILE")
[[ -n "$BLACKLIST" ]] || BLACKLIST=127.0.0.2
TCP_PORTS=$(jq -r '.open_ports.tcp | map(tonumber) | unique | sort | join(", ")' "$STATE_FILE")
UDP_PORTS=$(jq -r '.open_ports.udp | map(tonumber) | unique | sort | join(", ")' "$STATE_FILE")
[[ -n "$TCP_PORTS" ]] || TCP_PORTS=65535
[[ -n "$UDP_PORTS" ]] || UDP_PORTS=65535

NAT_ACTION=$(select_nat_action)
DNAT_RULES=""
SNAT_RULES=""
while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    sport=$(jq -r '.sport' <<< "$row")
    dport=$(jq -r '.dport' <<< "$row")
    dip=$(jq -r '.dip' <<< "$row")
    proto=$(jq -r '.proto' <<< "$row")
    dest_port=$(jq -r '.dest_port // .sport' <<< "$row")
    port_range=$sport
    [[ "$sport" == "$dport" ]] || port_range="$sport-$dport"
    DNAT_RULES+="        $proto dport $port_range dnat to $dip:$dest_port"$'\n'
    SNAT_RULES+="        ip daddr $dip $proto dport $dest_port $NAT_ACTION"$'\n'
done < <(jq -c '.forwards[]?' "$STATE_FILE")

{
    echo "flush ruleset"
    sed \
        -e "s/#BLACKLIST#/$BLACKLIST/g" \
        -e "s/#TCP_PORTS#/$TCP_PORTS/g" \
        -e "s/#UDP_PORTS#/$UDP_PORTS/g" \
        -e "s/#SSH_PORT#/$SSH_PORT/g" \
        "$BASE_DIR/rules/filter.nft.tpl"
    while IFS= read -r line; do
        case "$line" in
            *#DNAT_RULES#*) printf '%s' "$DNAT_RULES" ;;
            *#SNAT_RULES#*) printf '%s' "$SNAT_RULES" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$BASE_DIR/rules/nat.nft.tpl"
} > "$BUILD_TMP"

"$NFT_BIN" -c -f "$BUILD_TMP"

if [[ "$APPLY_RULES" == 1 ]]; then
    # 含 flush 的整个 nft 文件作为单个原子 netlink batch 提交，不存在空规则窗口。
    "$NFT_BIN" -f "$BUILD_TMP"
    atomic_copy "$BUILD_TMP" "$BUILD_CONF"
    atomic_copy "$BUILD_TMP" "$SYSTEM_CONF"
    systemctl enable nftables >/dev/null 2>&1
    echo "✅ 规则已安全加载并持久化"
else
    atomic_copy "$BUILD_TMP" "$BUILD_CONF"
    echo "✅ 配置已生成并通过语法检查（未加载）"
fi
