#!/bin/bash
# ==============================================================================
# Protocol Plugin: VLESS + Reality
# ==============================================================================

proto_register "VLESS" "VLESS Reality" "tcp" \
    "build_vless" "edit_vless" "info_vless" \
    "inbound_vless" "uri_vless" "surge_vless" "clash_vless"

# ------------------------------------------------------------------------------
# wizard：交互收集参数，返回 meta JSON（不写 state）
# ------------------------------------------------------------------------------
_vless_wizard() {
    local port="$1"
    local server_name short_id uuid keypair private_key public_key

    read -p "伪装域名 [默认: www.microsoft.com]: " server_name
    server_name="${server_name:-www.microsoft.com}"
    server_name=$(echo "$server_name" | tr -cd 'a-zA-Z0-9.-')

    uuid="$(cat /proc/sys/kernel/random/uuid)"
    short_id="$(openssl rand -hex 4)"

    keypair="$(sing-box generate reality-keypair 2>/dev/null)"
    private_key="$(echo "$keypair" | sed -n 's/^PrivateKey:[[:space:]]*//p')"
    public_key="$(echo "$keypair"  | sed -n 's/^PublicKey:[[:space:]]*//p')"

    [[ -z "$private_key" || -z "$public_key" ]] && { err "Reality 密钥对生成失败"; return 1; }

    jq -n \
        --arg  protocol    "VLESS" \
        --argjson port     "$port" \
        --arg  uuid        "$uuid" \
        --arg  server_name "$server_name" \
        --arg  public_key  "$public_key" \
        --arg  private_key "$private_key" \
        --arg  short_id    "$short_id" \
        --arg  created_at  "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{
            protocol:    $protocol,
            port:        $port,
            uuid:        $uuid,
            server_name: $server_name,
            public_key:  $public_key,
            private_key: $private_key,
            short_id:    $short_id,
            created_at:  $created_at,
            updated_at:  $created_at,
            enabled:     true
        }'
}

# ------------------------------------------------------------------------------
# build：新建实例
# ------------------------------------------------------------------------------
build_vless() {
    local port="$1"

    if port_used_tcp "$port"; then
        err "端口 [${port}] TCP 已被占用"
        return 1
    fi

    command -v sing-box &>/dev/null || { err "sing-box 未安装，请先执行 'sb install'"; return 1; }

    local meta id
    meta=$(_vless_wizard "$port") || return 1
    id=$(state_next_id)
    meta=$(echo "$meta" | jq --arg id "$id" '. + {id: $id}')

    state_set "$id" "$meta"
    ok "VLESS Reality [${id}] 端口 ${port} 已创建"
}

# ------------------------------------------------------------------------------
# edit：修改可编辑字段
# ------------------------------------------------------------------------------
edit_vless() {
    local id="$1"
    local payload="$2"

    local cur_server_name cur_port
    cur_server_name=$(echo "$payload" | jq -r '.server_name')
    cur_port=$(echo "$payload"        | jq -r '.port')

    echo "当前伪装域名: ${cur_server_name}"
    read -p "新伪装域名 [回车保持不变]: " new_sn
    echo "当前端口: ${cur_port}"
    read -p "新端口 [回车保持不变]: " new_port

    local filter=""

    if [ -n "$new_sn" ]; then
        new_sn=$(echo "$new_sn" | tr -cd 'a-zA-Z0-9.-')
        filter+=" | .server_name = \"${new_sn}\""
    fi

    if [ -n "$new_port" ]; then
        port_valid "$new_port" || { err "端口号非法"; return 1; }
        if port_used_tcp "$new_port"; then
            err "端口 [${new_port}] TCP 已被占用"
            return 1
        fi
        filter+=" | .port = ${new_port}"
    fi

    [ -z "$filter" ] && { info "无变更"; return 0; }

    state_patch "$id" "${filter# | }"
    ok "VLESS [${id}] 已更新"
}

# ------------------------------------------------------------------------------
# info：打印实例详情
# ------------------------------------------------------------------------------
info_vless() {
    local payload="$1"
    local ipv4="$2"

    local id port uuid server_name public_key short_id enabled created updated

    id=$(echo "$payload"          | jq -r '.id')
    port=$(echo "$payload"        | jq -r '.port')
    uuid=$(echo "$payload"        | jq -r '.uuid')
    server_name=$(echo "$payload" | jq -r '.server_name')
    public_key=$(echo "$payload"  | jq -r '.public_key')
    short_id=$(echo "$payload"    | jq -r '.short_id')
    enabled=$(echo "$payload"     | jq -r '.enabled')
    created=$(echo "$payload"     | jq -r '.created_at')
    updated=$(echo "$payload"     | jq -r '.updated_at // "-"')

    local status="🟢 启用"
    [ "$enabled" = "false" ] && status="🔴 停用"

    echo ""
    echo "┌─────────────────────────────────────────┐"
    echo "│  VLESS Reality                          │"
    echo "├─────────────────────────────────────────┤"
    printf "│  %-12s %-26s │\n" "ID"          "$id"
    printf "│  %-12s %-26s │\n" "状态"        "$status"
    printf "│  %-12s %-26s │\n" "端口"        "$port"
    printf "│  %-12s %-26s │\n" "伪装域名"    "$server_name"
    printf "│  %-12s %-26s │\n" "UUID"        "$uuid"
    printf "│  %-12s %-26s │\n" "Public Key"  "$public_key"
    printf "│  %-12s %-26s │\n" "Short ID"    "$short_id"
    printf "│  %-12s %-26s │\n" "创建时间"    "$created"
    printf "│  %-12s %-26s │\n" "更新时间"    "$updated"
    echo "├─────────────────────────────────────────┤"
    printf "│  %-12s %-26s │\n" "URI" ""
    local uri
    uri=$(uri_vless "$payload" "$ipv4")
    echo "│  ${uri:0:40}"
    echo "└─────────────────────────────────────────┘"
}

# ------------------------------------------------------------------------------
# inbound：生成 sing-box inbound 片段
# ------------------------------------------------------------------------------
inbound_vless() {
    local meta="$1"

    jq -n \
        --arg  uuid        "$(echo "$meta" | jq -r '.uuid')" \
        --argjson port     "$(echo "$meta" | jq -r '.port')" \
        --arg  server_name "$(echo "$meta" | jq -r '.server_name')" \
        --arg  private_key "$(echo "$meta" | jq -r '.private_key')" \
        --arg  short_id    "$(echo "$meta" | jq -r '.short_id')" \
        '{
            "type": "vless",
            "listen": "::",
            "listen_port": $port,
            "users": [{ "uuid": $uuid }],
            "tls": {
                "enabled": true,
                "server_name": $server_name,
                "reality": {
                    "enabled": true,
                    "handshake": { "server": $server_name, "server_port": 443 },
                    "private_key": $private_key,
                    "short_id": [$short_id]
                }
            }
        }'
}

# ------------------------------------------------------------------------------
# uri / surge / clash
# ------------------------------------------------------------------------------
uri_vless() {
    local meta="$1" ipv4="$2"

    local port uuid server_name public_key short_id id host

    port=$(echo "$meta"        | jq -r '.port')
    uuid=$(echo "$meta"        | jq -r '.uuid')
    server_name=$(echo "$meta" | jq -r '.server_name')
    public_key=$(echo "$meta"  | jq -r '.public_key')
    short_id=$(echo "$meta"    | jq -r '.short_id')
    id=$(echo "$meta"          | jq -r '.id')

    host="$ipv4"
    [[ "$host" == *:* ]] && host="[$host]"

    echo "vless://${uuid}@${host}:${port}?encryption=none&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#$(urlencode "VLESS-${id}")"
}

surge_vless() {
    local meta="$1" ipv4="$2"

    local port uuid server_name public_key short_id id

    port=$(echo "$meta"        | jq -r '.port')
    uuid=$(echo "$meta"        | jq -r '.uuid')
    server_name=$(echo "$meta" | jq -r '.server_name')
    public_key=$(echo "$meta"  | jq -r '.public_key')
    short_id=$(echo "$meta"    | jq -r '.short_id')
    id=$(echo "$meta"          | jq -r '.id')

    echo "VLESS-${id} = vless, ${ipv4}, ${port}, username=${uuid}, tls=true, reality=true, reality-public-key=${public_key}, reality-short-id=${short_id}, sni=${server_name}, client-fingerprint=chrome"
}

clash_vless() {
    local meta="$1" ipv4="$2"

    local port uuid server_name public_key short_id id

    port=$(echo "$meta"        | jq -r '.port')
    uuid=$(echo "$meta"        | jq -r '.uuid')
    server_name=$(echo "$meta" | jq -r '.server_name')
    public_key=$(echo "$meta"  | jq -r '.public_key')
    short_id=$(echo "$meta"    | jq -r '.short_id')
    id=$(echo "$meta"          | jq -r '.id')

    jq -n \
        --arg  name       "VLESS-${id}" \
        --arg  server     "$ipv4" \
        --argjson port    "$port" \
        --arg  uuid       "$uuid" \
        --arg  servername "$server_name" \
        --arg  pbk        "$public_key" \
        --arg  sid        "$short_id" \
        '{
            "name":    $name,
            "type":    "vless",
            "server":  $server,
            "port":    $port,
            "uuid":    $uuid,
            "network": "tcp",
            "tls":     true,
            "reality-opts": { "public-key": $pbk, "short-id": $sid },
            "servername": $servername,
            "client-fingerprint": "chrome"
        }'
}
