#!/usr/bin/env bash

proto_register "HY2" "Hysteria2" "udp" \
    "create_hy2" "edit_hy2" "validate_hy2" \
    "inbound_hy2" "uri_hy2" "surge_hy2" "clash_hy2" \
    "outbound_hy2" "firewall_hy2" "expected_hy2"

hy2_hop_validate() {
    local meta="$1" enabled port start end interval acknowledged size
    enabled=$(jq -r '.hop.enabled' <<<"$meta")
    [[ "$enabled" == "true" || "$enabled" == "false" ]] || return 1
    [[ "$enabled" == "true" ]] || return 0
    port=$(jq -r '.port' <<<"$meta")
    start=$(jq -r '.hop.start' <<<"$meta")
    end=$(jq -r '.hop.end' <<<"$meta")
    interval=$(jq -r '.hop.interval_seconds' <<<"$meta")
    acknowledged=$(jq -r '.hop.acknowledged' <<<"$meta")
    port_valid "$start" && port_valid "$end" || return 1
    (( start < end )) || return 1
    (( port < start || port > end )) || return 1
    size=$((end - start + 1))
    (( size <= 2048 )) || return 1
    # Official URI does not encode hop interval. Pinning the supported value to
    # its documented default keeps URI, Surge, Mihomo and sing-box semantics equal.
    (( interval == 30 )) || return 1
    if [[ "$acknowledged" != "true" ]]; then
        [[ "$(jq -r '.enabled' <<<"$meta")" == "false" &&
           "$(jq -r '.hop.confirmation_required // false' <<<"$meta")" == "true" ]]
    fi
}

validate_hy2() {
    local meta="$1"
    jq -e '
      .protocol == "HY2"
      and (.password | type == "string" and length >= 16)
      and (.masquerade | type == "string" and test("^https://"))
      and (.hop | type == "object")
      and (.tls | type == "object")
    ' <<<"$meta" >/dev/null &&
        tls_validate_meta "$meta" &&
        hy2_hop_validate "$meta"
}

create_hy2() {
    local id="$1" options="$2" port password masquerade tls hop now
    port=$(jq -r '.port' <<<"$options")
    port_valid "$port" || return 1
    password=$(jq -r '.password // empty' <<<"$options")
    [[ -n "$password" ]] || password=$(openssl rand -base64 32 | tr -d '\n')
    masquerade=$(jq -r '.masquerade // empty' <<<"$options")
    [[ "$masquerade" =~ ^https://[^[:space:]]+$ ]] || {
        err "HY2 masquerade must be an https URL"
        return 1
    }
    tls=$(tls_from_options "$id" "$options") || return 1
    hop=$(jq -c '.hop // {
      enabled:false,start:null,end:null,interval_seconds:null,acknowledged:false
    }' <<<"$options")
    now=$(now_iso)
    jq -n --arg id "$id" --arg protocol "HY2" --argjson port "$port" \
        --arg password "$password" --arg masquerade "$masquerade" \
        --argjson tls "$tls" --argjson hop "$hop" --arg now "$now" '
      {
        id:$id,protocol:$protocol,port:$port,password:$password,
        masquerade:$masquerade,tls:$tls,hop:$hop,
        enabled:true,created_at:$now,updated_at:$now
      }'
}

edit_hy2() {
    local meta="$1" options="$2" id tls updated
    id=$(jq -r '.id' <<<"$meta")
    tls=$(tls_update_from_options "$id" "$meta" "$options") || return 1
    updated=$(jq -n --argjson old "$meta" --argjson options "$options" \
        --argjson tls "$tls" --arg now "$(now_iso)" '
      $old
      | .port = ($options.port // .port)
      | .password = ($options.password // .password)
      | .masquerade = ($options.masquerade // .masquerade)
      | .hop = ($options.hop // .hop)
      | .tls = $tls
      | .updated_at = $now')
    validate_hy2 "$updated" || return 1
    printf '%s\n' "$updated"
}

inbound_hy2() {
    local meta="$1" tls
    tls=$(tls_inbound_json "$meta")
    jq -n --argjson meta "$meta" --argjson tls "$tls" \
      --arg listen "${SB_RENDER_LISTEN:-::}" '
      {
        type:"hysteria2",
        tag:("in-" + $meta.id),
        listen:$listen,
        listen_port:$meta.port,
        users:[{name:$meta.id,password:$meta.password}],
        masquerade:{type:"proxy",url:$meta.masquerade},
        tls:$tls
      }'
}

uri_hy2() {
    local meta="$1" endpoint="$2" host address query tag
    host=$(endpoint_host "$endpoint")
    if jq -e '.hop.enabled' <<<"$meta" >/dev/null; then
        address="${host}:$(jq -r '"\(.hop.start)-\(.hop.end)"' <<<"$meta")"
    else
        address="${host}:$(jq -r '.port' <<<"$meta")"
    fi
    query=$(tls_hysteria_uri_query "$meta")
    tag=$(urlencode "HY2-$(jq -r '.id' <<<"$meta")")
    printf 'hysteria2://%s@%s/?%s#%s\n' \
        "$(urlencode "$(jq -r '.password' <<<"$meta")")" "$address" "$query" "$tag"
}

surge_hy2() {
    local meta="$1" endpoint="$2" mode hop="" insecure
    mode=$(jq -r '.tls.mode' <<<"$meta")
    if [[ "$mode" == "self-signed" || "$mode" == "provided" ]]; then
        [[ "${SB_SUPPRESS_UNSUPPORTED_WARNINGS:-false}" == "true" ]] ||
          warn "Surge HY2 output disabled: verified certificate pin mapping is not defined by this project"
        return 2
    fi
    [[ "$mode" == "insecure" ]] && insecure=true || insecure=false
    if jq -e '.hop.enabled' <<<"$meta" >/dev/null; then
        hop=", port-hopping=$(jq -r '"\(.hop.start)-\(.hop.end)"' <<<"$meta"), port-hopping-interval=30"
    fi
    printf 'HY2-%s = hysteria2, %s, %s, password=%s, sni=%s, skip-cert-verify=%s%s\n' \
        "$(jq -r '.id' <<<"$meta")" "$endpoint" "$(jq -r '.port' <<<"$meta")" \
        "$(jq -r '.password' <<<"$meta")" "$(jq -r '.tls.sni' <<<"$meta")" \
        "$insecure" "$hop"
}

clash_hy2() {
    local meta="$1" endpoint="$2" insecure fingerprint
    tls_client_insecure "$meta" && insecure=true || insecure=false
    fingerprint=$(jq -r '.tls.certificate_sha256 // empty' <<<"$meta")
    jq -n --argjson meta "$meta" --arg server "$endpoint" \
        --argjson insecure "$insecure" --arg fingerprint "$fingerprint" '
      {
        name:("HY2-" + $meta.id),type:"hysteria2",server:$server,
        port:$meta.port,password:$meta.password,sni:$meta.tls.sni,
        "skip-cert-verify":$insecure
      }
      + (if ($meta.hop.enabled) then
          {ports:("\($meta.hop.start)-\($meta.hop.end)"),"hop-interval":$meta.hop.interval_seconds}
        else {} end)
      + (if ($fingerprint | length) > 0 and ($meta.tls.mode != "trusted")
         then {fingerprint:$fingerprint} else {} end)'
}

outbound_hy2() {
    local meta="$1" endpoint="$2" tls
    tls=$(tls_outbound_json "$meta")
    jq -n --argjson meta "$meta" --arg server "$endpoint" --argjson tls "$tls" '
      {
        type:"hysteria2",tag:("HY2-" + $meta.id),server:$server,
        password:$meta.password,tls:$tls
      }
      + (if $meta.hop.enabled then
          {server_ports:["\($meta.hop.start):\($meta.hop.end)"],
           hop_interval:"\($meta.hop.interval_seconds)s"}
        else {server_port:$meta.port} end)'
}

firewall_hy2() {
    local meta="$1" port start end
    port=$(jq -r '.port' <<<"$meta")
    if jq -e '.hop.enabled' <<<"$meta" >/dev/null; then
        start=$(jq -r '.hop.start' <<<"$meta")
        end=$(jq -r '.hop.end' <<<"$meta")
        jq -n --argjson port "$port" --argjson start "$start" --argjson end "$end" '
          {
            allow:["udp:\($port)","udp:\($start)-\($end)"],
            redirect:"udp:\($start)-\($end) -> udp:\($port)",
            nftables:"add rule inet sb prerouting udp dport \($start)-\($end) redirect to :\($port)",
            iptables:"iptables -t nat -A PREROUTING -p udp --dport \($start):\($end) -j REDIRECT --to-ports \($port)",
            external_confirmation_required:true
          }'
    else
        jq -n --argjson port "$port" \
            '{allow:["udp:\($port)"],redirect:null,nftables:null,iptables:null,external_confirmation_required:true}'
    fi
}

expected_hy2() {
    jq -c '[{network:"udp",port:.port}]' <<<"$1"
}
