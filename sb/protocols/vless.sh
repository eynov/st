#!/usr/bin/env bash

proto_register "VLESS" "VLESS" "tcp" \
    "create_vless" "edit_vless" "validate_vless" \
    "inbound_vless" "uri_vless" "surge_vless" "clash_vless" \
    "outbound_vless" "firewall_vless" "expected_vless"

vless_mode() {
    # State written before the three-mode schema had no mode and represented
    # plain TCP Reality. Preserve that meaning during manager upgrades.
    jq -r '.mode // "reality"' <<<"$1"
}

vless_mode_valid() {
    [[ "${1:-}" =~ ^(vision-reality|reality|ws)$ ]]
}

vless_path_valid() {
    [[ "${1:-}" == /* && "${1:-}" != *[[:space:]]* ]]
}

vless_uuid_valid() {
    [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

vless_reality_keys() {
    local options="$1" short_id keypair private_key public_key
    [[ -x "$SB_BIN" ]] || {
        err "fixed sing-box core is required to generate Reality keys"
        return 1
    }
    short_id=$(jq -r '.short_id // empty' <<<"$options")
    [[ -n "$short_id" ]] || short_id=$(openssl rand -hex 4)
    private_key=$(jq -r '.private_key // empty' <<<"$options")
    public_key=$(jq -r '.public_key // empty' <<<"$options")
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        keypair=$("$SB_BIN" generate reality-keypair) || return 1
        private_key=$(sed -n 's/^PrivateKey:[[:space:]]*//p' <<<"$keypair")
        public_key=$(sed -n 's/^PublicKey:[[:space:]]*//p' <<<"$keypair")
    fi
    jq -n --arg private_key "$private_key" --arg public_key "$public_key" \
      --arg short_id "$short_id" \
      '{private_key:$private_key,public_key:$public_key,short_id:$short_id}'
}

validate_vless() {
    local meta="$1" mode
    jq -e '
      .protocol == "VLESS"
      and (.uuid | type=="string" and
        test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))
    ' <<<"$meta" >/dev/null || return 1
    mode=$(vless_mode "$meta")
    vless_mode_valid "$mode" || return 1
    case "$mode" in
        vision-reality|reality)
            jq -e '
              (.private_key | type=="string" and length>20)
              and (.public_key | type=="string" and length>20)
              and (.short_id | type=="string" and test("^[0-9a-fA-F]{2,16}$"))
              and ((.short_id|length) % 2 == 0)
              and (.server_name | type=="string")
              and (has("tls")|not)
              and (has("path")|not)
              and (has("flow")|not)
              and (has("transport")|not)
              and (has("security")|not)
              and (has("packet_encoding")|not)
              and (has("spiderX")|not)
            ' <<<"$meta" >/dev/null || return 1
            domain_valid "$(jq -r '.server_name' <<<"$meta")"
            ;;
        ws)
            jq -e '
              (.path | type=="string")
              and (.tls | type=="object")
              and (has("private_key")|not)
              and (has("public_key")|not)
              and (has("short_id")|not)
              and (has("server_name")|not)
              and (has("flow")|not)
              and (has("transport")|not)
              and (has("security")|not)
              and (has("packet_encoding")|not)
              and (has("spiderX")|not)
            ' <<<"$meta" >/dev/null || return 1
            vless_path_valid "$(jq -r '.path' <<<"$meta")" &&
                tls_validate_meta "$meta"
            ;;
    esac
}

create_vless() {
    local id="$1" options="$2" port mode uuid now reality tls path server_name
    port=$(jq -r '.port' <<<"$options")
    mode=$(jq -r '.mode // "vision-reality"' <<<"$options")
    port_valid "$port" && vless_mode_valid "$mode" || return 1
    uuid=$(jq -r '.uuid // empty' <<<"$options")
    [[ -n "$uuid" ]] || uuid=$(cat /proc/sys/kernel/random/uuid) || return 1
    vless_uuid_valid "$uuid" || return 1
    now=$(now_iso)
    case "$mode" in
        vision-reality|reality)
            server_name=$(jq -r '.server_name // empty' <<<"$options")
            domain_valid "$server_name" || return 1
            jq -e 'has("path") or has("sni") or has("tls_mode") or
              has("certificate_path") or has("key_path")' <<<"$options" >/dev/null &&
                { err "Reality modes accept only --server-name, not WS/TLS options"; return 1; }
            reality=$(vless_reality_keys "$options") || return 1
            jq -n --arg id "$id" --arg protocol "VLESS" --argjson port "$port" \
              --arg mode "$mode" --arg uuid "$uuid" --arg server_name "$server_name" \
              --argjson reality "$reality" --arg now "$now" '
              {
                id:$id,protocol:$protocol,port:$port,mode:$mode,uuid:$uuid,
                server_name:$server_name,
                private_key:$reality.private_key,public_key:$reality.public_key,
                short_id:$reality.short_id,
                enabled:true,created_at:$now,updated_at:$now
              }'
            ;;
        ws)
            jq -e 'has("server_name")' <<<"$options" >/dev/null &&
                { err "WS mode uses --sni and does not accept --server-name"; return 1; }
            path=$(jq -r '.path // empty' <<<"$options")
            vless_path_valid "$path" || {
                err "VLESS WS path must start with / and contain no whitespace"
                return 1
            }
            tls=$(tls_from_options "$id" "$options") || return 1
            jq -n --arg id "$id" --arg protocol "VLESS" --argjson port "$port" \
              --arg mode "$mode" --arg uuid "$uuid" --arg path "$path" \
              --argjson tls "$tls" --arg now "$now" '
              {
                id:$id,protocol:$protocol,port:$port,mode:$mode,uuid:$uuid,
                path:$path,tls:$tls,enabled:true,created_at:$now,updated_at:$now
              }'
            ;;
    esac
}

edit_vless() {
    local meta="$1" options="$2" old_mode new_mode id port uuid now updated
    local server_name reality tls path
    old_mode=$(vless_mode "$meta")
    new_mode=$(jq -r --arg old "$old_mode" '.mode // $old' <<<"$options")
    vless_mode_valid "$new_mode" || {
        err "VLESS mode must be vision-reality, reality, or ws"
        return 1
    }
    id=$(jq -r '.id' <<<"$meta")
    port=$(jq -r --argjson old "$meta" '.port // $old.port' <<<"$options")
    uuid=$(jq -r '.uuid' <<<"$meta")
    now=$(now_iso)
    case "$new_mode" in
        vision-reality|reality)
            jq -e 'has("path") or has("sni") or has("tls_mode") or
              has("certificate_path") or has("key_path") or .rotate_certificate==true' \
              <<<"$options" >/dev/null &&
                { err "Reality modes do not accept WS/TLS options"; return 1; }
            if [[ "$old_mode" == "ws" ]]; then
                server_name=$(jq -r '.server_name // empty' <<<"$options")
                domain_valid "$server_name" || {
                    err "switching WS to Reality requires --server-name"
                    return 1
                }
                reality=$(vless_reality_keys '{}') || return 1
            else
                server_name=$(jq -r --argjson old "$meta" \
                  '.server_name // $old.server_name' <<<"$options")
                reality=$(jq -c '{
                  uuid:.uuid,private_key:.private_key,public_key:.public_key,short_id:.short_id
                }' <<<"$meta")
            fi
            updated=$(jq -n --argjson old "$meta" --argjson port "$port" \
              --arg mode "$new_mode" --arg server_name "$server_name" \
              --argjson reality "$reality" --arg now "$now" '
              $old
              | .port=$port | .mode=$mode | .server_name=$server_name
              | .private_key=$reality.private_key | .public_key=$reality.public_key
              | .short_id=$reality.short_id | .updated_at=$now
              | del(.path,.tls)')
            ;;
        ws)
            jq -e 'has("server_name")' <<<"$options" >/dev/null &&
                { err "WS mode uses --sni and does not accept --server-name"; return 1; }
            if [[ "$old_mode" == "ws" ]]; then
                path=$(jq -r --argjson old "$meta" '.path // $old.path' <<<"$options")
                tls=$(tls_update_from_options "$id" "$meta" "$options") || return 1
            else
                path=$(jq -r '.path // empty' <<<"$options")
                vless_path_valid "$path" || {
                    err "switching Reality to WS requires --path"
                    return 1
                }
                tls=$(tls_from_options "$id" "$options") || return 1
            fi
            updated=$(jq -n --argjson old "$meta" --argjson port "$port" \
              --arg mode "$new_mode" --arg path "$path" --argjson tls "$tls" \
              --arg now "$now" '
              $old | .port=$port | .mode=$mode | .path=$path | .tls=$tls
              | .updated_at=$now
              | del(.server_name,.private_key,.public_key,.short_id)')
            ;;
    esac
    validate_vless "$updated" || return 1
    printf '%s\n' "$updated"
}

inbound_vless() {
    local meta="$1" mode tls flow
    mode=$(vless_mode "$meta")
    if [[ "$mode" == "ws" ]]; then
        tls=$(tls_inbound_json "$meta") || return 1
        jq -n --argjson meta "$meta" --argjson tls "$tls" \
          --arg listen "${SB_RENDER_LISTEN:-::}" '{
          type:"vless",tag:("in-" + $meta.id),listen:$listen,listen_port:$meta.port,
          users:[{name:$meta.id,uuid:$meta.uuid}],tls:$tls,
          transport:{type:"ws",path:$meta.path}
        }'
        return
    fi
    [[ "$mode" == "vision-reality" ]] && flow="xtls-rprx-vision" || flow=""
    jq --arg listen "${SB_RENDER_LISTEN:-::}" --arg flow "$flow" '{
      type:"vless",tag:("in-" + .id),listen:$listen,listen_port:.port,
      users:[{name:.id,uuid:.uuid} + (if $flow!="" then {flow:$flow} else {} end)],
      tls:{
        enabled:true,server_name:.server_name,
        reality:{
          enabled:true,
          handshake:{server:.server_name,server_port:443},
          private_key:.private_key,
          short_id:[.short_id]
        }
      }
    }' <<<"$meta"
}

uri_vless() {
    local meta="$1" endpoint="$2" mode query tls_mode insecure
    mode=$(vless_mode "$meta")
    if [[ "$mode" == "ws" ]]; then
        tls_mode=$(jq -r '.tls.mode' <<<"$meta")
        [[ "$tls_mode" == "trusted" ]] && insecure=0 || insecure=1
        query="encryption=none&security=tls&sni=$(urlencode "$(jq -r '.tls.sni' <<<"$meta")")"
        query+="&type=ws&host=$(urlencode "$(jq -r '.tls.sni' <<<"$meta")")"
        query+="&path=$(urlencode "$(jq -r '.path' <<<"$meta")")&allowInsecure=${insecure}"
    else
        query="encryption=none&security=reality&sni=$(urlencode "$(jq -r '.server_name' <<<"$meta")")"
        query+="&fp=chrome&pbk=$(urlencode "$(jq -r '.public_key' <<<"$meta")")"
        query+="&sid=$(urlencode "$(jq -r '.short_id' <<<"$meta")")&type=tcp"
        [[ "$mode" != "vision-reality" ]] ||
            query+="&flow=xtls-rprx-vision"
    fi
    printf 'vless://%s@%s:%s?%s#%s\n' \
      "$(jq -r '.uuid' <<<"$meta")" "$(endpoint_host "$endpoint")" \
      "$(jq -r '.port' <<<"$meta")" "$query" \
      "$(urlencode "VLESS-$(jq -r '.id' <<<"$meta")")"
}

surge_vless() {
    [[ "${SB_SUPPRESS_UNSUPPORTED_WARNINGS:-false}" == "true" ]] ||
      warn "Surge VLESS output disabled: no tested project compatibility contract"
    return 2
}

clash_vless() {
    local meta="$1" endpoint="$2" mode insecure
    mode=$(vless_mode "$meta")
    if [[ "$mode" == "ws" ]]; then
        tls_client_insecure "$meta" && insecure=true || insecure=false
        [[ "$(jq -r '.tls.mode' <<<"$meta")" == "trusted" ]] || insecure=true
        jq -n --argjson meta "$meta" --arg server "$endpoint" \
          --argjson insecure "$insecure" '{
          name:("VLESS-" + $meta.id),type:"vless",server:$server,port:$meta.port,
          uuid:$meta.uuid,network:"ws",tls:true,servername:$meta.tls.sni,
          "skip-cert-verify":$insecure,
          "ws-opts":{path:$meta.path,headers:{Host:$meta.tls.sni}}
        }'
        return
    fi
    jq -n --argjson meta "$meta" --arg server "$endpoint" --arg mode "$mode" '
      {
        name:("VLESS-" + $meta.id),type:"vless",server:$server,port:$meta.port,
        uuid:$meta.uuid,network:"tcp",tls:true,servername:$meta.server_name,
        "client-fingerprint":"chrome",
        "reality-opts":{"public-key":$meta.public_key,"short-id":$meta.short_id}
      }
      + (if $mode=="vision-reality" then {flow:"xtls-rprx-vision"} else {} end)'
}

outbound_vless() {
    local meta="$1" endpoint="$2" mode tls
    mode=$(vless_mode "$meta")
    if [[ "$mode" == "ws" ]]; then
        tls=$(tls_outbound_json "$meta") || return 1
        jq -n --argjson meta "$meta" --arg server "$endpoint" --argjson tls "$tls" '{
          type:"vless",tag:("VLESS-" + $meta.id),server:$server,
          server_port:$meta.port,uuid:$meta.uuid,tls:$tls,
          transport:{type:"ws",path:$meta.path}
        }'
        return
    fi
    jq -n --argjson meta "$meta" --arg server "$endpoint" --arg mode "$mode" '
      {
        type:"vless",tag:("VLESS-" + $meta.id),server:$server,
        server_port:$meta.port,uuid:$meta.uuid,
        tls:{
          enabled:true,server_name:$meta.server_name,
          utls:{enabled:true,fingerprint:"chrome"},
          reality:{enabled:true,public_key:$meta.public_key,short_id:$meta.short_id}
        }
      }
      + (if $mode=="vision-reality" then {flow:"xtls-rprx-vision"} else {} end)'
}

firewall_vless() {
    jq '{allow:["tcp:\(.port)"],redirect:null,external_confirmation_required:true}' <<<"$1"
}

expected_vless() {
    jq -c '[{network:"tcp",port:.port}]' <<<"$1"
}
