#!/bin/bash
# ==============================================================================
# 协议注册表
# ==============================================================================

declare -a  PROTO_KEYS=()
declare -A  PROTO_MENU=()
declare -A  PROTO_BUILD=()
declare -A  PROTO_EDIT=()
declare -A  PROTO_INFO=()
declare -A  PROTO_INBOUND=()
declare -A  PROTO_URI=()
declare -A  PROTO_SURGE=()
declare -A  PROTO_CLASH=()
declare -A  PROTO_TRANSPORT=()

# ------------------------------------------------------------------------------
# 协议自注册
# 用法: proto_register <KEY> <菜单名> <transport> \
#           <build> <edit> <info> <inbound> <uri> <surge> <clash>
# transport: tcp | udp
# ------------------------------------------------------------------------------
proto_register() {
    local key="$1"       label="$2"    transport="$3"
    local build_fn="$4"  edit_fn="$5"  info_fn="$6"
    local inbound_fn="$7" uri_fn="$8"  surge_fn="$9"  clash_fn="${10}"

    PROTO_KEYS+=("$key")
    PROTO_MENU["$key"]="$label"
    PROTO_TRANSPORT["$key"]="$transport"

    [ -n "$build_fn"   ] && PROTO_BUILD["$key"]="$build_fn"
    [ -n "$edit_fn"    ] && PROTO_EDIT["$key"]="$edit_fn"
    [ -n "$info_fn"    ] && PROTO_INFO["$key"]="$info_fn"
    [ -n "$inbound_fn" ] && PROTO_INBOUND["$key"]="$inbound_fn"
    [ -n "$uri_fn"     ] && PROTO_URI["$key"]="$uri_fn"
    [ -n "$surge_fn"   ] && PROTO_SURGE["$key"]="$surge_fn"
    [ -n "$clash_fn"   ] && PROTO_CLASH["$key"]="$clash_fn"
}

# ------------------------------------------------------------------------------
# 加载所有协议插件
# 防止重复加载：进程内守卫变量（不 export，避免子进程被误锁死）
# ------------------------------------------------------------------------------
load_protocols() {
    [[ "${SB_PROTOCOL_LOADED:-}" == "1" ]] && return
    SB_PROTOCOL_LOADED=1

    # 防御性清空（双保险）
    PROTO_KEYS=()
    PROTO_MENU=()
    PROTO_BUILD=()
    PROTO_EDIT=()
    PROTO_INFO=()
    PROTO_INBOUND=()
    PROTO_URI=()
    PROTO_SURGE=()
    PROTO_CLASH=()
    PROTO_TRANSPORT=()

    local proto_dir
    proto_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/protocols"

    [ -d "$proto_dir" ] || { warn "protocols/ 目录不存在"; return 1; }

    local f
    for f in "$proto_dir"/*.sh; do
        [ -f "$f" ] && source "$f"
    done
}

