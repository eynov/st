#!/usr/bin/env bash

proto_register "VLESS" "VLESS Reality" "tcp" \
    "create_vless" "edit_vless" "validate_vless" \
    "inbound_vless" "uri_vless" "surge_vless" "clash_vless" \
    "outbound_vless" "firewall_vless" "expected_vless"

validate_vless() {
    local meta="$1" server_name
    jq -e '
      .protocol == "VLESS"
      and (.uuid | type=="string" and
        test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))
      and (.private_key | type=="string" and length>20)
      and (.public_key | type=="string" and length>20)
      and (.short_id | type=="string" and test("^[0-9a-fA-F]{2,16}$"))
      and ((.short_id|length) % 2 == 0)
    ' <<<"$meta" >/dev/null || return 1
    server_name=$(jq -r '.server_name' <<<"$meta")
    domain_valid "$server_name"
}

create_vless() {
    local id="$1" options="$2" port server_name uuid short_id keypair private_key public_key now
    port=$(jq -r '.port' <<<"$options")
    server_name=$(jq -r '.server_name // empty' <<<"$options")
    port_valid "$port" && domain_valid "$server_name" || return 1
    [[ -x "$SB_BIN" ]] || {
        err "fixed sing-box core is required to generate Reality keys"
        return 1
    }
    uuid=$(jq -r '.uuid // empty' <<<"$options")
    [[ -n "$uuid" ]] || uuid=$(cat /proc/sys/kernel/random/uuid)
    short_id=$(jq -r '.short_id // empty' <<<"$options")
    [[ -n "$short_id" ]] || short_id=$(openssl rand -hex 4)
    private_key=$(jq -r '.private_key // empty' <<<"$options")
    public_key=$(jq -r '.public_key // empty' <<<"$options")
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        keypair=$("$SB_BIN" generate reality-keypair) || return 1
        private_key=$(sed -n 's/^PrivateKey:[[:space:]]*//p' <<<"$keypair")
        public_key=$(sed -n 's/^PublicKey:[[:space:]]*//p' <<<"$keypair")
    fi
    now=$(now_iso)
    jq -n --arg id "$id" --arg protocol "VLESS" --argjson port "$port" \
      --arg uuid "$uuid" --arg server_name "$server_name" \
      --arg private_key "$private_key" --arg public_key "$public_key" \
      --arg short_id "$short_id" --arg now "$now" '
      {
        id:$id,protocol:$protocol,port:$port,uuid:$uuid,server_name:$server_name,
        private_key:$private_key,public_key:$public_key,short_id:$short_id,
        enabled:true,created_at:$now,updated_at:$now
      }'
}

edit_vless() {
    local meta="$1" options="$2" updated
    updated=$(jq -n --argjson old "$meta" --argjson options "$options" --arg now "$(now_iso)" '
      $old
      | .port = ($options.port // .port)
      | .server_name = ($options.server_name // .server_name)
      | .updated_at = $now')
    validate_vless "$updated" || return 1
    printf '%s\n' "$updated"
}

inbound_vless() {
    jq --arg listen "${SB_RENDER_LISTEN:-::}" '{
      type:"vless",tag:("in-" + .id),listen:$listen,listen_port:.port,
      users:[{name:.id,uuid:.uuid}],
      tls:{
        enabled:true,server_name:.server_name,
        reality:{
          enabled:true,
          handshake:{server:.server_name,server_port:443},
          private_key:.private_key,
          short_id:[.short_id]
        }
      }
    }' <<<"$1"
}

uri_vless() {
    local meta="$1" endpoint="$2" query
    query="encryption=none&security=reality&sni=$(urlencode "$(jq -r '.server_name' <<<"$meta")")"
    query+="&fp=chrome&pbk=$(urlencode "$(jq -r '.public_key' <<<"$meta")")"
    query+="&sid=$(urlencode "$(jq -r '.short_id' <<<"$meta")")&type=tcp"
    printf 'vless://%s@%s:%s?%s#%s\n' \
      "$(jq -r '.uuid' <<<"$meta")" "$(endpoint_host "$endpoint")" \
      "$(jq -r '.port' <<<"$meta")" "$query" \
      "$(urlencode "VLESS-$(jq -r '.id' <<<"$meta")")"
}

surge_vless() {
    [[ "${SB_SUPPRESS_UNSUPPORTED_WARNINGS:-false}" == "true" ]] ||
      warn "Surge VLESS Reality output disabled: no tested project compatibility contract"
    return 2
}

clash_vless() {
    jq -n --argjson meta "$1" --arg server "$2" '
      {
        name:("VLESS-" + $meta.id),type:"vless",server:$server,port:$meta.port,
        uuid:$meta.uuid,network:"tcp",tls:true,servername:$meta.server_name,
        "client-fingerprint":"chrome",
        "reality-opts":{"public-key":$meta.public_key,"short-id":$meta.short_id}
      }'
}

outbound_vless() {
    jq -n --argjson meta "$1" --arg server "$2" '
      {
        type:"vless",tag:("VLESS-" + $meta.id),server:$server,
        server_port:$meta.port,uuid:$meta.uuid,
        tls:{
          enabled:true,server_name:$meta.server_name,
          utls:{enabled:true,fingerprint:"chrome"},
          reality:{enabled:true,public_key:$meta.public_key,short_id:$meta.short_id}
        }
      }'
}

firewall_vless() {
    jq '{allow:["tcp:\(.port)"],redirect:null,external_confirmation_required:true}' <<<"$1"
}

expected_vless() {
    jq -c '[{network:"tcp",port:.port}]' <<<"$1"
}
