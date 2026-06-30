#!/bin/bash
# ==============================================================================
# Protocol Plugin: AnyTLS
#
# 官方 schema 来源（build / edit / info / inbound 严格遵循）：
#   https://sing-box.sagernet.org/configuration/inbound/anytls/
#   自 sing-box 1.12.0 起原生支持。inbound 必须包含 users 数组（每个用户
#   含 name + password），TLS 必须 enabled。
#
# 以下三处官方未定义标准，本插件采用社区事实标准（已在注释中标注来源，
# 非 sing-box 官方规范）：
#   - uri_anytls    采用 anytls-go 参考实现的 URI 格式
#                   anytls://password@host:port（Shadowrocket 等已支持）
#   - clash_anytls  采用 mihomo 实际支持的 proxy 节点字段
#                   type: anytls / server / port / username / password / tls
#   - surge_anytls  Surge 官方未支持 AnyTLS，本函数仅返回空字符串并打印警告，
#                   不编造 Surge 不存在的协议名
#
# 个人单用户场景：本插件内部固定写入一个 name="user" 的 AnyTLS 用户，
# 不在交互层暴露多用户管理。
# ==============================================================================

proto_register "ANYTLS" "AnyTLS" "tcp" \
    "build_anytls" "edit_anytls" "info_anytls" \
    "inbound_anytls" "uri_anytls" "surge_anytls" "clash_anytls"

# ------------------------------------------------------------------------------
# build：新建实例
# ------------------------------------------------------------------------------
build_anytls() {
    local port="$1"

    if port_used_tcp "$port"; then
        err "端口 [${port}] TCP 已被占用"
        return 1
    fi

    read -p "TLS server_name / SNI [默认: www.bing.com]: " sni
    sni="${sni:-www.bing.com}"
    sni=$(echo "$sni" | tr -cd 'a-zA-Z0-9.-')

    # AnyTLS 官方示例 password 为 16 字节随机数据的 base64 编码
    local password cert key
    password=$(openssl rand -base64 16 | tr -d '\n')
    cert="${CERT_DIR}/anytls_${port}.crt"
    key="${CERT_DIR}/anytls_${port}.key"

    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$key" -out "$cert" \
        -subj "/CN=${sni}" >/dev/null 2>&1

    local now id meta
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    id=$(state_next_id)

    meta=$(jq -n \
        --arg  id         "$id" \
        --arg  protocol   "ANYTLS" \
        --argjson port    "$port" \
        --arg  password   "$password" \
        --arg  sni        "$sni" \
        --arg  cert       "$cert" \
        --arg  key        "$key" \
        --arg  created_at "$now" \
        '{
            id:         $id,
            protocol:   $protocol,
            port:       $port,
            password:   $password,
            sni:        $sni,
            cert:       $cert,
            key:        $key,
            created_at: $created_at,
            updated_at: $created_at,
            enabled:    true
        }')

    state_set "$id" "$meta"
    ok "AnyTLS [${id}] 端口 ${port} 已创建"
}

# ------------------------------------------------------------------------------
# edit：可改 port / sni / 重新生成 password
# ------------------------------------------------------------------------------
edit_anytls() {
    local id="$1"
    local payload="$2"

    local cur_port cur_sni
    cur_port=$(echo "$payload" | jq -r '.port')
    cur_sni=$(echo "$payload"  | jq -r '.sni')

    echo "当前端口: ${cur_port}"
    read -p "新端口 [回车保持]: " new_port

    echo "当前 SNI: ${cur_sni}"
    read -p "新 SNI [回车保持]: " new_sni

    read -p "重新生成密码？[y/N]: " regen_pw

    local filter=""

    if [ -n "$new_port" ]; then
        port_valid "$new_port" || { err "端口号非法"; return 1; }
        port_used_tcp "$new_port" && { err "端口 [${new_port}] TCP 已被占用"; return 1; }
        filter+=" | .port = ${new_port}"
    fi

    if [ -n "$new_sni" ]; then
        new_sni=$(echo "$new_sni" | tr -cd 'a-zA-Z0-9.-')
        filter+=" | .sni = \"${new_sni}\""
    fi

    if [[ "$regen_pw" == "y" || "$regen_pw" == "Y" ]]; then
        local new_pw
        new_pw=$(openssl rand -base64 16 | tr -d '\n')
        filter+=" | .password = \"${new_pw}\""
    fi

    [ -z "$filter" ] && { info "无变更"; return 0; }

    state_patch "$id" "${filter# | }"
    ok "AnyTLS [${id}] 已更新"
}

# ------------------------------------------------------------------------------
# info：查看详情
# ------------------------------------------------------------------------------
info_anytls() {
    local payload="$1"

    local id port password sni enabled created updated
    id=$(echo "$payload"       | jq -r '.id')
    port=$(echo "$payload"     | jq -r '.port')
    password=$(echo "$payload" | jq -r '.password')
    sni=$(echo "$payload"      | jq -r '.sni')
    enabled=$(echo "$payload"  | jq -r '.enabled')
    created=$(echo "$payload"  | jq -r '.created_at')
    updated=$(echo "$payload"  | jq -r '.updated_at // "-"')

    local status="🟢 启用"
    [ "$enabled" = "false" ] && status="🔴 停用"

    echo ""
    echo "┌─────────────────────────────────────────┐"
    echo "│  AnyTLS                                 │"
    echo "├─────────────────────────────────────────┤"
    printf "│  %-12s %-26s │\n" "ID"       "$id"
    printf "│  %-12s %-26s │\n" "状态"     "$status"
    printf "│  %-12s %-26s │\n" "端口"     "$port"
    printf "│  %-12s %-26s │\n" "SNI"      "$sni"
    printf "│  %-12s %-26s │\n" "密码"     "$password"
    printf "│  %-12s %-26s │\n" "创建时间" "$created"
    printf "│  %-12s %-26s │\n" "更新时间" "$updated"
    echo "└─────────────────────────────────────────┘"
}

# ------------------------------------------------------------------------------
# inbound：严格按 sing-box 官方 AnyTLS inbound schema
# https://sing-box.sagernet.org/configuration/inbound/anytls/
# ------------------------------------------------------------------------------
inbound_anytls() {
    local meta="$1"

    jq -n \
        --argjson port   "$(echo "$meta" | jq -r '.port')" \
        --arg  password  "$(echo "$meta" | jq -r '.password')" \
        --arg  sni       "$(echo "$meta" | jq -r '.sni')" \
        --arg  cert      "$(echo "$meta" | jq -r '.cert')" \
        --arg  key       "$(echo "$meta" | jq -r '.key')" \
        '{
            "type": "anytls",
            "listen": "::",
            "listen_port": $port,
            "users": [
                { "name": "user", "password": $password }
            ],
            "tls": {
                "enabled": true,
                "server_name": $sni,
                "certificate_path": $cert,
                "key_path": $key
            }
        }'
}

# ------------------------------------------------------------------------------
# uri：非官方标准。采用 anytls-go 参考实现的事实格式
# anytls://password@host:port  (来源: github.com/anytls/anytls-go)
# ------------------------------------------------------------------------------
uri_anytls() {
    local meta="$1"
    local ipv4="$2"

    local port password id
    port=$(echo "$meta"     | jq -r '.port')
    password=$(echo "$meta" | jq -r '.password')
    id=$(echo "$meta"       | jq -r '.id')

    echo "anytls://$(urlencode "$password")@${ipv4}:${port}#$(urlencode "ANYTLS-${id}")"
}

# ------------------------------------------------------------------------------
# surge：Surge 官方未支持 AnyTLS，返回空字符串，避免编造不存在的协议名
# ------------------------------------------------------------------------------
surge_anytls() {
    warn "Surge 官方未支持 AnyTLS 协议，已跳过 Surge 节点生成" >&2
    echo ""
}

# ------------------------------------------------------------------------------
# clash：非官方标准。采用 mihomo 实际支持的字段
# type: anytls / server / port / username / password / tls / skip-cert-verify
# （来源: MetaCubeX/mihomo 实测配置，非 sing-box 官方文档）
# ------------------------------------------------------------------------------
clash_anytls() {
    local meta="$1"
    local ipv4="$2"

    local port password id sni
    port=$(echo "$meta"     | jq -r '.port')
    password=$(echo "$meta" | jq -r '.password')
    sni=$(echo "$meta"      | jq -r '.sni')
    id=$(echo "$meta"       | jq -r '.id')

    jq -n \
        --arg  name     "ANYTLS-${id}" \
        --arg  server   "$ipv4" \
        --argjson port  "$port" \
        --arg  username "user" \
        --arg  password "$password" \
        --arg  sni      "$sni" \
        '{
            "name":     $name,
            "type":     "anytls",
            "server":   $server,
            "port":     $port,
            "username": $username,
            "password": $password,
            "sni":      $sni,
            "udp":      false,
            "skip-cert-verify": true
        }'
}
