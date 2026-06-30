#!/bin/bash
# ==============================================================================
# Protocol Plugin: Shadowsocks 2022
# ==============================================================================

proto_register "SS2022" "Shadowsocks 2022 (Blake3)" "tcp" \
    "build_ss2022" "edit_ss2022" "info_ss2022" \
    "inbound_ss2022" "uri_ss2022" "surge_ss2022" "clash_ss2022"

build_ss2022() {
    local port="$1"

    if port_used_tcp "$port"; then
        err "端口 [${port}] TCP 已被占用"
        return 1
    fi

    echo ""
    echo "加密方式："
    echo "  1) 2022-blake3-aes-128-gcm  [默认]"
    echo "  2) 2022-blake3-aes-256-gcm"
    echo "  3) 2022-blake3-chacha20-poly1305"
    read -rp "选择 [1-3]: " cipher
    cipher="${cipher:-1}"

    local method password
    case "$cipher" in
        2) method="2022-blake3-aes-256-gcm";      password=$(openssl rand -base64 32 | tr -d '\n') ;;
        3) method="2022-blake3-chacha20-poly1305"; password=$(openssl rand -base64 32 | tr -d '\n') ;;
        *) method="2022-blake3-aes-128-gcm";       password=$(openssl rand -base64 16 | tr -d '\n') ;;
    esac

    local now id meta
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    id=$(state_next_id)

    meta=$(jq -n \
        --arg  id         "$id" \
        --arg  protocol   "SS2022" \
        --argjson port    "$port" \
        --arg  method     "$method" \
        --arg  password   "$password" \
        --arg  created_at "$now" \
        '{
            id: $id, protocol: $protocol,
            port: $port, method: $method, password: $password,
            created_at: $created_at, updated_at: $created_at, enabled: true
        }')

    state_set "$id" "$meta"
    ok "Shadowsocks 2022 [${id}] 端口 ${port} 已创建"
}

edit_ss2022() {
    local id="$1"
    local payload="$2"

    local cur_port cur_method
    cur_port=$(echo "$payload"   | jq -r '.port')
    cur_method=$(echo "$payload" | jq -r '.method')

    echo "当前端口:  ${cur_port}"
    read -p "新端口 [回车保持]: " new_port

    echo "当前加密:  ${cur_method}"
    echo "  1) 2022-blake3-aes-128-gcm"
    echo "  2) 2022-blake3-aes-256-gcm"
    echo "  3) 2022-blake3-chacha20-poly1305"
    read -p "新加密 [回车保持]: " new_cipher

    read -p "重新生成密码？[y/N]: " regen_pw

    local filter=""

    if [ -n "$new_port" ]; then
        port_valid "$new_port" || { err "端口号非法"; return 1; }
        port_used_tcp "$new_port" && { err "端口 [${new_port}] TCP 已被占用"; return 1; }
        filter+=" | .port = ${new_port}"
    fi

    local new_method=""
    case "$new_cipher" in
        1) new_method="2022-blake3-aes-128-gcm" ;;
        2) new_method="2022-blake3-aes-256-gcm" ;;
        3) new_method="2022-blake3-chacha20-poly1305" ;;
    esac
    [ -n "$new_method" ] && filter+=" | .method = \"${new_method}\""

    if [[ "$regen_pw" == "y" || "$regen_pw" == "Y" ]]; then
        local new_pw
        new_pw=$(openssl rand -base64 16 | tr -d '\n')
        filter+=" | .password = \"${new_pw}\""
    fi

    [ -z "$filter" ] && { info "无变更"; return 0; }

    state_patch "$id" "${filter# | }"
    ok "SS2022 [${id}] 已更新"
}

info_ss2022() {
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
    echo "│  Shadowsocks 2022                       │"
    echo "├─────────────────────────────────────────┤"
    printf "│  %-12s %-26s │\n" "ID"       "$id"
    printf "│  %-12s %-26s │\n" "状态"     "$status"
    printf "│  %-12s %-26s │\n" "端口"     "$port"
    printf "│  %-12s %-26s │\n" "加密"     "$method"
    printf "│  %-12s %-26s │\n" "密码"     "$password"
    printf "│  %-12s %-26s │\n" "创建时间" "$created"
    printf "│  %-12s %-26s │\n" "更新时间" "$updated"
    echo "└─────────────────────────────────────────┘"
}

inbound_ss2022() {
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

uri_ss2022() {
    local meta="$1" ipv4="$2"
    local port method password id
    port=$(echo "$meta"     | jq -r '.port')
    method=$(echo "$meta"   | jq -r '.method')
    password=$(echo "$meta" | jq -r '.password')
    id=$(echo "$meta"       | jq -r '.id')
    local userinfo tag
    userinfo=$(urlencode "${method}:${password}")
    tag=$(urlencode "SS2022-${id}")
    echo "ss://${userinfo}@${ipv4}:${port}#${tag}"
}

surge_ss2022() {
    local meta="$1" ipv4="$2"
    local port method password id
    port=$(echo "$meta"     | jq -r '.port')
    method=$(echo "$meta"   | jq -r '.method')
    password=$(echo "$meta" | jq -r '.password')
    id=$(echo "$meta"       | jq -r '.id')
    echo "SS2022-${id} = ss, ${ipv4}, ${port}, encrypt-method=${method}, password=${password}"
}

clash_ss2022() {
    local meta="$1" ipv4="$2"
    local port method password id
    port=$(echo "$meta"     | jq -r '.port')
    method=$(echo "$meta"   | jq -r '.method')
    password=$(echo "$meta" | jq -r '.password')
    id=$(echo "$meta"       | jq -r '.id')
    jq -n \
        --arg  name     "SS2022-${id}" \
        --arg  server   "$ipv4" \
        --argjson port  "$port" \
        --arg  cipher   "$method" \
        --arg  password "$password" \
        '{ "name": $name, "type": "ss", "server": $server,
           "port": $port, "cipher": $cipher, "password": $password }'
}
