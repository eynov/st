#!/bin/bash
# ==============================================================================
# Protocol Plugin: Shadowsocks AEAD
# ==============================================================================

proto_register "SS" "Shadowsocks (AEAD)" "tcp" \
    "build_ss" "edit_ss" "info_ss" \
    "inbound_ss" "uri_ss" "surge_ss" "clash_ss"

build_ss() {
    local port="$1"

    if port_used_tcp "$port"; then
        err "端口 [${port}] TCP 已被占用"
        return 1
    fi

    local password method
    password=$(openssl rand -hex 16)
    method="aes-256-gcm"

    local now id meta
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    id=$(state_next_id)

    meta=$(jq -n \
        --arg  id        "$id" \
        --arg  protocol  "SS" \
        --argjson port   "$port" \
        --arg  method    "$method" \
        --arg  password  "$password" \
        --arg  created_at "$now" \
        '{
            id: $id, protocol: $protocol,
            port: $port, method: $method, password: $password,
            created_at: $created_at, updated_at: $created_at, enabled: true
        }')

    state_set "$id" "$meta"
    ok "Shadowsocks [${id}] 端口 ${port} 已创建"
}

edit_ss() {
    local id="$1"
    local payload="$2"

    local cur_port cur_method cur_password
    cur_port=$(echo "$payload"     | jq -r '.port')
    cur_method=$(echo "$payload"   | jq -r '.method')
    cur_password=$(echo "$payload" | jq -r '.password')

    echo "当前端口:    ${cur_port}"
    read -p "新端口 [回车保持]: " new_port

    echo "当前加密:    ${cur_method}"
    echo "  1) aes-256-gcm  2) aes-128-gcm  3) chacha20-ietf-poly1305"
    read -p "新加密 [回车保持]: " new_method_choice

    read -p "重新生成密码？[y/N]: " regen_pw

    local filter=""

    if [ -n "$new_port" ]; then
        port_valid "$new_port" || { err "端口号非法"; return 1; }
        port_used_tcp "$new_port" && { err "端口 [${new_port}] TCP 已被占用"; return 1; }
        filter+=" | .port = ${new_port}"
    fi

    case "$new_method_choice" in
        1) filter+=" | .method = \"aes-256-gcm\"" ;;
        2) filter+=" | .method = \"aes-128-gcm\"" ;;
        3) filter+=" | .method = \"chacha20-ietf-poly1305\"" ;;
    esac

    if [[ "$regen_pw" == "y" || "$regen_pw" == "Y" ]]; then
        local new_pw
        new_pw=$(openssl rand -hex 16)
        filter+=" | .password = \"${new_pw}\""
    fi

    [ -z "$filter" ] && { info "无变更"; return 0; }

    state_patch "$id" "${filter# | }"
    ok "SS [${id}] 已更新"
}

info_ss() {
    local payload="$1"

    local id port method password enabled created updated
    id=$(echo "$payload"       | jq -r '.id')
    port=$(echo "$payload"     | jq -r '.port')
    method=$(echo "$payload"   | jq -r '.method')
    password=$(echo "$payload" | jq -r '.password')
    enabled=$(echo "$payload"  | jq -r '.enabled')
    created=$(echo "$payload"  | jq -r '.created_at')
    updated=$(echo "$payload"  | jq -r '.updated_at // "-"')

    local status="🟢 启用"
    [ "$enabled" = "false" ] && status="🔴 停用"

    echo ""
    echo "┌─────────────────────────────────────────┐"
    echo "│  Shadowsocks AEAD                       │"
    echo "├─────────────────────────────────────────┤"
    printf "│  %-12s %-26s │\n" "ID"      "$id"
    printf "│  %-12s %-26s │\n" "状态"    "$status"
    printf "│  %-12s %-26s │\n" "端口"    "$port"
    printf "│  %-12s %-26s │\n" "加密"    "$method"
    printf "│  %-12s %-26s │\n" "密码"    "$password"
    printf "│  %-12s %-26s │\n" "创建时间" "$created"
    printf "│  %-12s %-26s │\n" "更新时间" "$updated"
    echo "└─────────────────────────────────────────┘"
}

inbound_ss() {
    local meta="$1"
    jq -n \
        --argjson port   "$(echo "$meta" | jq -r '.port')" \
        --arg  method    "$(echo "$meta" | jq -r '.method')" \
        --arg  password  "$(echo "$meta" | jq -r '.password')" \
        '{
            "type": "shadowsocks",
            "listen": "::",
            "listen_port": $port,
            "method": $method,
            "password": $password
        }'
}

uri_ss() {
    local meta="$1" ipv4="$2"
    local port method password id b64
    port=$(echo "$meta"     | jq -r '.port')
    method=$(echo "$meta"   | jq -r '.method')
    password=$(echo "$meta" | jq -r '.password')
    id=$(echo "$meta"       | jq -r '.id')
    b64=$(echo -n "${method}:${password}" | base64 | tr -d '\n')
    echo "ss://${b64}@${ipv4}:${port}#$(urlencode "SS-${id}")"
}

surge_ss() {
    local meta="$1" ipv4="$2"
    local port method password id
    port=$(echo "$meta"     | jq -r '.port')
    method=$(echo "$meta"   | jq -r '.method')
    password=$(echo "$meta" | jq -r '.password')
    id=$(echo "$meta"       | jq -r '.id')
    echo "SS-${id} = ss, ${ipv4}, ${port}, encrypt-method=${method}, password=${password}"
}

clash_ss() {
    local meta="$1" ipv4="$2"
    local port method password id
    port=$(echo "$meta"     | jq -r '.port')
    method=$(echo "$meta"   | jq -r '.method')
    password=$(echo "$meta" | jq -r '.password')
    id=$(echo "$meta"       | jq -r '.id')
    jq -n \
        --arg  name     "SS-${id}" \
        --arg  server   "$ipv4" \
        --argjson port  "$port" \
        --arg  cipher   "$method" \
        --arg  password "$password" \
        '{ "name": $name, "type": "ss", "server": $server,
           "port": $port, "cipher": $cipher, "password": $password }'
}
