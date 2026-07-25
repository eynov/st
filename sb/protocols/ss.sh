#!/usr/bin/env bash

proto_register "SS" "Shadowsocks AEAD" "tcp+udp" \
    "create_ss" "edit_ss" "validate_ss" \
    "inbound_ss" "uri_ss" "surge_ss" "clash_ss" \
    "outbound_ss" "firewall_ss" "expected_ss"

ss_method_valid() {
    [[ "${1:-}" =~ ^(aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305)$ ]]
}

validate_ss() {
    local meta="$1"
    jq -e '
      .protocol == "SS"
      and (.password | type == "string" and length >= 16)
      and (.method | type == "string")
    ' <<<"$meta" >/dev/null &&
        ss_method_valid "$(jq -r '.method' <<<"$meta")"
}

create_ss() {
    local id="$1" options="$2" port method password now
    port=$(jq -r '.port' <<<"$options")
    method=$(jq -r '.method // "aes-256-gcm"' <<<"$options")
    port_valid "$port" && ss_method_valid "$method" || return 1
    password=$(jq -r '.password // empty' <<<"$options")
    [[ -n "$password" ]] || password=$(openssl rand -base64 32 | tr -d '\n')
    now=$(now_iso)
    jq -n --arg id "$id" --arg protocol "SS" --argjson port "$port" \
      --arg method "$method" --arg password "$password" --arg now "$now" '
      {
        id:$id,protocol:$protocol,port:$port,method:$method,password:$password,
        enabled:true,created_at:$now,updated_at:$now
      }'
}

edit_ss() {
    local meta="$1" options="$2" updated
    updated=$(jq -n --argjson old "$meta" --argjson options "$options" --arg now "$(now_iso)" '
      $old
      | .port = ($options.port // .port)
      | .method = ($options.method // .method)
      | .password = ($options.password // .password)
      | .updated_at = $now')
    validate_ss "$updated" || return 1
    printf '%s\n' "$updated"
}

inbound_ss() {
    jq --arg listen "${SB_RENDER_LISTEN:-::}" '{
      type:"shadowsocks",tag:("in-" + .id),listen:$listen,listen_port:.port,
      method:.method,password:.password
    }' <<<"$1"
}

uri_ss() {
    local meta="$1" endpoint="$2" userinfo
    userinfo=$(printf '%s' "$(jq -r '"\(.method):\(.password)"' <<<"$meta")" | base64_urlsafe)
    printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$(endpoint_host "$endpoint")" \
      "$(jq -r '.port' <<<"$meta")" "$(urlencode "SS-$(jq -r '.id' <<<"$meta")")"
}

surge_ss() {
    local meta="$1" endpoint="$2"
    printf 'SS-%s = ss, %s, %s, encrypt-method=%s, password=%s, udp-relay=true\n' \
      "$(jq -r '.id' <<<"$meta")" "$endpoint" "$(jq -r '.port' <<<"$meta")" \
      "$(jq -r '.method' <<<"$meta")" "$(jq -r '.password' <<<"$meta")"
}

clash_ss() {
    jq -n --argjson meta "$1" --arg server "$2" '
      {
        name:("SS-" + $meta.id),type:"ss",server:$server,port:$meta.port,
        cipher:$meta.method,password:$meta.password,udp:true
      }'
}

outbound_ss() {
    jq -n --argjson meta "$1" --arg server "$2" '
      {
        type:"shadowsocks",tag:("SS-" + $meta.id),server:$server,
        server_port:$meta.port,method:$meta.method,password:$meta.password
      }'
}

firewall_ss() {
    jq '{allow:["tcp:\(.port)","udp:\(.port)"],redirect:null,external_confirmation_required:true}' <<<"$1"
}

expected_ss() {
    jq -c '[{network:"tcp",port:.port},{network:"udp",port:.port}]' <<<"$1"
}
