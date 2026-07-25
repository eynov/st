#!/usr/bin/env bash

proto_register "ANYTLS" "AnyTLS" "tcp" \
    "create_anytls" "edit_anytls" "validate_anytls" \
    "inbound_anytls" "uri_anytls" "surge_anytls" "clash_anytls" \
    "outbound_anytls" "firewall_anytls" "expected_anytls"

validate_anytls() {
    local meta="$1"
    jq -e '
      .protocol == "ANYTLS"
      and (.password | type == "string" and length >= 16)
      and (.tls | type == "object")
    ' <<<"$meta" >/dev/null && tls_validate_meta "$meta"
}

create_anytls() {
    local id="$1" options="$2" port password tls now
    port=$(jq -r '.port' <<<"$options")
    port_valid "$port" || return 1
    password=$(jq -r '.password // empty' <<<"$options")
    [[ -n "$password" ]] || password=$(openssl rand -base64 32 | tr -d '\n')
    tls=$(tls_from_options "$id" "$options") || return 1
    now=$(now_iso)
    jq -n --arg id "$id" --arg protocol "ANYTLS" --argjson port "$port" \
      --arg password "$password" --argjson tls "$tls" --arg now "$now" '
      {
        id:$id,protocol:$protocol,port:$port,password:$password,tls:$tls,
        enabled:true,created_at:$now,updated_at:$now
      }'
}

edit_anytls() {
    local meta="$1" options="$2" id tls updated
    id=$(jq -r '.id' <<<"$meta")
    tls=$(tls_update_from_options "$id" "$meta" "$options") || return 1
    updated=$(jq -n --argjson old "$meta" --argjson options "$options" \
      --argjson tls "$tls" --arg now "$(now_iso)" '
      $old
      | .port = ($options.port // .port)
      | .password = ($options.password // .password)
      | .tls = $tls
      | .updated_at = $now')
    validate_anytls "$updated" || return 1
    printf '%s\n' "$updated"
}

inbound_anytls() {
    local meta="$1" tls
    tls=$(tls_inbound_json "$meta")
    jq -n --argjson meta "$meta" --argjson tls "$tls" \
      --arg listen "${SB_RENDER_LISTEN:-::}" '
      {
        type:"anytls",tag:("in-" + $meta.id),listen:$listen,listen_port:$meta.port,
        users:[{name:$meta.id,password:$meta.password}],tls:$tls
      }'
}

uri_anytls() {
    [[ "${SB_SUPPRESS_UNSUPPORTED_WARNINGS:-false}" == "true" ]] ||
      warn "AnyTLS URI output disabled: no versioned, interoperable URI contract is tested by this project"
    return 2
}

surge_anytls() {
    [[ "${SB_SUPPRESS_UNSUPPORTED_WARNINGS:-false}" == "true" ]] ||
      warn "Surge AnyTLS output disabled: Surge compatibility is not part of the tested matrix"
    return 2
}

clash_anytls() {
    local meta="$1" endpoint="$2" insecure fingerprint
    tls_client_insecure "$meta" && insecure=true || insecure=false
    fingerprint=$(jq -r '.tls.certificate_sha256 // empty' <<<"$meta")
    jq -n --argjson meta "$meta" --arg server "$endpoint" \
      --argjson insecure "$insecure" --arg fingerprint "$fingerprint" '
      {
        name:("ANYTLS-" + $meta.id),type:"anytls",server:$server,port:$meta.port,
        password:$meta.password,sni:$meta.tls.sni,udp:true,
        "skip-cert-verify":$insecure,"name-cert-verify":$meta.tls.sni
      }
      + (if ($fingerprint|length)>0 and $meta.tls.mode != "trusted"
         then {fingerprint:$fingerprint} else {} end)'
}

outbound_anytls() {
    local meta="$1" endpoint="$2" tls
    tls=$(tls_outbound_json "$meta")
    jq -n --argjson meta "$meta" --arg server "$endpoint" --argjson tls "$tls" '
      {
        type:"anytls",tag:("ANYTLS-" + $meta.id),server:$server,
        server_port:$meta.port,password:$meta.password,tls:$tls
      }'
}

firewall_anytls() {
    jq '{allow:["tcp:\(.port)"],redirect:null,external_confirmation_required:true}' <<<"$1"
}

expected_anytls() {
    jq -c '[{network:"tcp",port:.port}]' <<<"$1"
}
