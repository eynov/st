#!/usr/bin/env bash

proto_register "SS2022" "Shadowsocks 2022" "tcp+udp" \
    "create_ss2022" "edit_ss2022" "validate_ss2022" \
    "inbound_ss2022" "uri_ss2022" "surge_ss2022" "clash_ss2022" \
    "outbound_ss2022" "firewall_ss2022" "expected_ss2022"

ss2022_method_valid() {
    [[ "${1:-}" =~ ^(2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)$ ]]
}

ss2022_password_generate() {
    case "$1" in
        2022-blake3-aes-128-gcm) openssl rand -base64 16 | tr -d '\n' ;;
        *) openssl rand -base64 32 | tr -d '\n' ;;
    esac
}

ss2022_password_valid() {
    local method="$1" password="$2" bytes expected
    bytes=$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c)
    [[ "$method" == "2022-blake3-aes-128-gcm" ]] && expected=16 || expected=32
    ((bytes == expected))
}

validate_ss2022() {
    local meta="$1" method password
    jq -e '.protocol == "SS2022" and (.method|type=="string") and (.password|type=="string")' \
        <<<"$meta" >/dev/null || return 1
    method=$(jq -r '.method' <<<"$meta")
    password=$(jq -r '.password' <<<"$meta")
    ss2022_method_valid "$method" && ss2022_password_valid "$method" "$password"
}

create_ss2022() {
    local id="$1" options="$2" port method password now
    port=$(jq -r '.port' <<<"$options")
    method=$(jq -r '.method // "2022-blake3-aes-128-gcm"' <<<"$options")
    port_valid "$port" && ss2022_method_valid "$method" || return 1
    password=$(jq -r '.password // empty' <<<"$options")
    [[ -n "$password" ]] || password=$(ss2022_password_generate "$method")
    now=$(now_iso)
    jq -n --arg id "$id" --arg protocol "SS2022" --argjson port "$port" \
      --arg method "$method" --arg password "$password" --arg now "$now" '
      {
        id:$id,protocol:$protocol,port:$port,method:$method,password:$password,
        enabled:true,created_at:$now,updated_at:$now
      }'
}

edit_ss2022() {
    local meta="$1" options="$2" old_method method password updated
    old_method=$(jq -r '.method' <<<"$meta")
    method=$(jq -r --arg old "$old_method" '.method // $old' <<<"$options")
    password=$(jq -r '.password // empty' <<<"$options")
    if [[ -z "$password" && "$method" != "$old_method" ]]; then
        password=$(ss2022_password_generate "$method")
    elif [[ -z "$password" ]]; then
        password=$(jq -r '.password' <<<"$meta")
    fi
    updated=$(jq -n --argjson old "$meta" --argjson options "$options" \
      --arg method "$method" --arg password "$password" --arg now "$(now_iso)" '
      $old
      | .port = ($options.port // .port)
      | .method = $method
      | .password = $password
      | .updated_at = $now')
    validate_ss2022 "$updated" || return 1
    printf '%s\n' "$updated"
}

inbound_ss2022() {
    jq --arg listen "${SB_RENDER_LISTEN:-::}" '{
      type:"shadowsocks",tag:("in-" + .id),listen:$listen,listen_port:.port,
      method:.method,password:.password
    }' <<<"$1"
}

uri_ss2022() {
    local meta="$1" endpoint="$2" method password userinfo
    method=$(jq -r '.method' <<<"$meta")
    password=$(jq -r '.password' <<<"$meta")
    userinfo="$(urlencode "$method"):$(urlencode "$password")"
    printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$(endpoint_host "$endpoint")" \
      "$(jq -r '.port' <<<"$meta")" "$(urlencode "SS2022-$(jq -r '.id' <<<"$meta")")"
}

surge_ss2022() {
    [[ "${SB_SUPPRESS_UNSUPPORTED_WARNINGS:-false}" == "true" ]] ||
      warn "Surge SS2022 output disabled: no tested project compatibility contract"
    return 2
}

clash_ss2022() {
    jq -n --argjson meta "$1" --arg server "$2" '
      {
        name:("SS2022-" + $meta.id),type:"ss",server:$server,port:$meta.port,
        cipher:$meta.method,password:$meta.password,udp:true
      }'
}

outbound_ss2022() {
    jq -n --argjson meta "$1" --arg server "$2" '
      {
        type:"shadowsocks",tag:("SS2022-" + $meta.id),server:$server,
        server_port:$meta.port,method:$meta.method,password:$meta.password
      }'
}

firewall_ss2022() {
    jq '{allow:["tcp:\(.port)","udp:\(.port)"],redirect:null,external_confirmation_required:true}' <<<"$1"
}

expected_ss2022() {
    jq -c '[{network:"tcp",port:.port},{network:"udp",port:.port}]' <<<"$1"
}
