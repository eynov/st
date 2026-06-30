#!/bin/bash
# ==============================================================================
# Protocol Plugin: Hysteria2
# ==============================================================================

proto_register "HY2" "Hysteria2 (UDP / QUIC)" "udp" \
    "build_hy2" "edit_hy2" "info_hy2" \
    "inbound_hy2" "uri_hy2" "surge_hy2" "clash_hy2"

# ------------------------------------------------------------------------------
# wizard：交互收集参数，返回 meta JSON
# ------------------------------------------------------------------------------
_hy2_wizard() {
    local port="$1"

    read -p "SNI 域名 [默认: www.apple.com]: " sni
    sni="${sni:-www.apple.com}"
    sni="${sni#https://}"; sni="${sni#http://}"; sni="${sni%%/*}"; sni="${sni%/}"

    read -p "伪装回落域名 [回车与 SNI 相同]: " masq_input
    if [ -z "$masq_input" ]; then
        masq="https://${sni}"
    else
        masq_input="${masq_input#https://}"; masq_input="${masq_input#http://}"
        masq="https://${masq_input%/}"
    fi

    read -p "端口跳跃范围 [如 20000-29999，回车不启用]: " hop_ports
    local hop_interval=""
    if [ -n "$hop_ports" ]; then
        while [[ ! "$hop_ports" =~ ^[0-9]+(-[0-9]+)?$ ]]; do
            read -p "格式有误，如 20000-29999: " hop_ports
        done
        read -p "跳跃间隔秒数 [默认 30]: " hop_interval
        hop_interval="${hop_interval:-30}"
        while [[ ! "$hop_interval" =~ ^[0-9]+$ ]] || (( hop_interval < 5 )); do
            read -p "须为 ≥5 的整数: " hop_interval
        done
    fi

    local password cert key
    password=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
    cert="${CERT_DIR}/hy2_${port}.crt"
    key="${CERT_DIR}/hy2_${port}.key"

    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$key" -out "$cert" \
        -subj "/CN=${sni}" >/dev/null 2>&1

    local hop_ports_val hop_interval_val
    [ -n "$hop_ports"    ] && hop_ports_val="\"${hop_ports}\""  || hop_ports_val="null"
    [ -n "$hop_interval" ] && hop_interval_val="${hop_interval}" || hop_interval_val="null"

    jq -n \
        --arg  protocol      "HY2" \
        --argjson port       "$port" \
        --arg  password      "$password" \
        --arg  sni           "$sni" \
        --arg  masq          "$masq" \
        --arg  cert          "$cert" \
        --arg  key           "$key" \
        --argjson hop_ports     "$hop_ports_val" \
        --argjson hop_interval  "$hop_interval_val" \
        --arg  created_at    "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{
            protocol:     $protocol,
            port:         $port,
            password:     $password,
            sni:          $sni,
            masq:         $masq,
            cert:         $cert,
            key:          $key,
            hop_ports:    $hop_ports,
            hop_interval: $hop_interval,
            created_at:   $created_at,
            updated_at:   $created_at,
            enabled:      true
        }'
}

# ------------------------------------------------------------------------------
# build
# ------------------------------------------------------------------------------
build_hy2() {
    local port="$1"

    if port_used_udp "$port"; then
        err "端口 [${port}] UDP 已被占用"
        return 1
    fi

    local meta id
    meta=$(_hy2_wizard "$port") || return 1
    id=$(state_next_id)
    meta=$(echo "$meta" | jq --arg id "$id" '. + {id: $id}')

    state_set "$id" "$meta"
    ok "Hysteria2 [${id}] 端口 ${port} 已创建"
}

# ------------------------------------------------------------------------------
# edit：可修改 sni / masq / hop_ports / hop_interval / port
# ------------------------------------------------------------------------------
edit_hy2() {
    local id="$1"
    local payload="$2"

    local cur_sni cur_masq cur_hop cur_port
    cur_sni=$(echo "$payload"  | jq -r '.sni')
    cur_masq=$(echo "$payload" | jq -r '.masq')
    cur_hop=$(echo "$payload"  | jq -r '.hop_ports // "未启用"')
    cur_port=$(echo "$payload" | jq -r '.port')

    echo "当前 SNI:      ${cur_sni}"
    read -p "新 SNI [回车保持]: " new_sni

    echo "当前伪装回落:  ${cur_masq}"
    read -p "新回落 URL [回车保持]: " new_masq

    echo "当前端口跳跃:  ${cur_hop}"
    read -p "新跳跃范围 [回车保持, 输入 - 清除]: " new_hop

    echo "当前端口:      ${cur_port}"
    read -p "新端口 [回车保持]: " new_port

    local filter=""

    if [ -n "$new_sni" ]; then
        new_sni=$(echo "$new_sni" | tr -cd 'a-zA-Z0-9.-')
        filter+=" | .sni = \"${new_sni}\""
    fi

    if [ -n "$new_masq" ]; then
        new_masq="${new_masq#https://}"; new_masq="${new_masq#http://}"
        filter+=" | .masq = \"https://${new_masq%/}\""
    fi

    if [ "$new_hop" = "-" ]; then
        filter+=" | .hop_ports = null | .hop_interval = null"
    elif [ -n "$new_hop" ]; then
        [[ "$new_hop" =~ ^[0-9]+(-[0-9]+)?$ ]] || { err "跳跃范围格式有误"; return 1; }
        filter+=" | .hop_ports = \"${new_hop}\""
    fi

    if [ -n "$new_port" ]; then
        port_valid "$new_port" || { err "端口号非法"; return 1; }
        if port_used_udp "$new_port"; then
            err "端口 [${new_port}] UDP 已被占用"
            return 1
        fi
        filter+=" | .port = ${new_port}"
    fi

    [ -z "$filter" ] && { info "无变更"; return 0; }

    state_patch "$id" "${filter# | }"
    ok "HY2 [${id}] 已更新"
}

# ------------------------------------------------------------------------------
# info
# ------------------------------------------------------------------------------
info_hy2() {
    local payload="$1"
    local ipv4="$2"

    local id port password sni masq hop_ports hop_interval enabled created updated

    id=$(echo "$payload"           | jq -r '.id')
    port=$(echo "$payload"         | jq -r '.port')
    password=$(echo "$payload"     | jq -r '.password')
    sni=$(echo "$payload"          | jq -r '.sni')
    masq=$(echo "$payload"         | jq -r '.masq')
    hop_ports=$(echo "$payload"    | jq -r '.hop_ports // "未启用"')
    hop_interval=$(echo "$payload" | jq -r '.hop_interval // "-"')
    enabled=$(echo "$payload"      | jq -r '.enabled')
    created=$(echo "$payload"      | jq -r '.created_at')
    updated=$(echo "$payload"      | jq -r '.updated_at // "-"')

    local status="🟢 启用"
    [ "$enabled" = "false" ] && status="🔴 停用"

    echo ""
    echo "┌─────────────────────────────────────────┐"
    echo "│  Hysteria2                              │"
    echo "├─────────────────────────────────────────┤"
    printf "│  %-12s %-26s │\n" "ID"        "$id"
    printf "│  %-12s %-26s │\n" "状态"      "$status"
    printf "│  %-12s %-26s │\n" "端口"      "$port"
    printf "│  %-12s %-26s │\n" "SNI"       "$sni"
    printf "│  %-12s %-26s │\n" "伪装回落"  "$masq"
    printf "│  %-12s %-26s │\n" "密码"      "$password"
    printf "│  %-12s %-26s │\n" "端口跳跃"  "$hop_ports"
    printf "│  %-12s %-26s │\n" "跳跃间隔"  "${hop_interval}s"
    printf "│  %-12s %-26s │\n" "创建时间"  "$created"
    printf "│  %-12s %-26s │\n" "更新时间"  "$updated"
    echo "└─────────────────────────────────────────┘"
}

# ------------------------------------------------------------------------------
# inbound
# ------------------------------------------------------------------------------
inbound_hy2() {
    local meta="$1"

    jq -n \
        --argjson port    "$(echo "$meta" | jq -r '.port')" \
        --arg  password   "$(echo "$meta" | jq -r '.password')" \
        --arg  sni        "$(echo "$meta" | jq -r '.sni')" \
        --arg  masq       "$(echo "$meta" | jq -r '.masq')" \
        --arg  cert       "$(echo "$meta" | jq -r '.cert')" \
        --arg  key        "$(echo "$meta" | jq -r '.key')" \
        '{
            "type": "hysteria2",
            "listen": "::",
            "listen_port": $port,
            "users": [{ "password": $password }],
            "masquerade": { "type": "proxy", "url": $masq },
            "tls": {
                "enabled": true,
                "server_name": $sni,
                "certificate_path": $cert,
                "key_path": $key
            }
        }'
}

# ------------------------------------------------------------------------------
# uri / surge / clash
# ------------------------------------------------------------------------------
uri_hy2() {
    local meta="$1" ipv4="$2"

    local port password sni hop_ports id
    port=$(echo "$meta"      | jq -r '.port')
    password=$(echo "$meta"  | jq -r '.password')
    sni=$(echo "$meta"       | jq -r '.sni')
    hop_ports=$(echo "$meta" | jq -r '.hop_ports // empty')
    id=$(echo "$meta"        | jq -r '.id')

    local pw_enc sni_enc tag_enc
    pw_enc=$(urlencode "$password")
    sni_enc=$(urlencode "$sni")
    tag_enc=$(urlencode "HY2-${id}")

    if [ -n "$hop_ports" ]; then
        echo "hysteria2://${pw_enc}@${ipv4}:${port}?sni=${sni_enc}&insecure=1&mport=${hop_ports}#${tag_enc}"
    else
        echo "hysteria2://${pw_enc}@${ipv4}:${port}?sni=${sni_enc}&insecure=1#${tag_enc}"
    fi
}

surge_hy2() {
    local meta="$1" ipv4="$2"

    local port password sni hop_ports hop_interval id
    port=$(echo "$meta"         | jq -r '.port')
    password=$(echo "$meta"     | jq -r '.password')
    sni=$(echo "$meta"          | jq -r '.sni')
    hop_ports=$(echo "$meta"    | jq -r '.hop_ports // empty')
    hop_interval=$(echo "$meta" | jq -r '.hop_interval // 30')
    id=$(echo "$meta"           | jq -r '.id')

    if [ -n "$hop_ports" ]; then
        echo "HY2-${id} = hysteria2, ${ipv4}, ${port}, password=${password}, sni=${sni}, skip-cert-verify=true, port-hopping=${hop_ports}, port-hopping-interval=${hop_interval}"
    else
        echo "HY2-${id} = hysteria2, ${ipv4}, ${port}, password=${password}, sni=${sni}, skip-cert-verify=true"
    fi
}

clash_hy2() {
    local meta="$1" ipv4="$2"

    local port password sni hop_ports hop_interval id
    port=$(echo "$meta"         | jq -r '.port')
    password=$(echo "$meta"     | jq -r '.password')
    sni=$(echo "$meta"          | jq -r '.sni')
    hop_ports=$(echo "$meta"    | jq -r '.hop_ports // empty')
    hop_interval=$(echo "$meta" | jq -r '.hop_interval // 30')
    id=$(echo "$meta"           | jq -r '.id')

    if [ -n "$hop_ports" ]; then
        jq -n \
            --arg  name          "HY2-${id}" \
            --arg  server        "$ipv4" \
            --argjson port       "$port" \
            --arg  password      "$password" \
            --arg  sni           "$sni" \
            --arg  hop_ports     "$hop_ports" \
            --argjson hop_interval "$hop_interval" \
            '{
                "name": $name, "type": "hysteria2",
                "server": $server, "port": $port,
                "password": $password, "sni": $sni,
                "skip-cert-verify": true,
                "ports": $hop_ports,
                "hop-interval": $hop_interval
            }'
    else
        jq -n \
            --arg  name     "HY2-${id}" \
            --arg  server   "$ipv4" \
            --argjson port  "$port" \
            --arg  password "$password" \
            --arg  sni      "$sni" \
            '{
                "name": $name, "type": "hysteria2",
                "server": $server, "port": $port,
                "password": $password, "sni": $sni,
                "skip-cert-verify": true
            }'
    fi
}
