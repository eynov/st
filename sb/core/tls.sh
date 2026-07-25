#!/usr/bin/env bash

tls_mode_valid() {
    [[ "${1:-}" =~ ^(trusted|provided|self-signed|insecure)$ ]]
}

tls_sni_valid() {
    domain_valid "${1:-}"
}

tls_generate_self_signed() {
    local id="$1" sni="$2"
    tls_sni_valid "$sni" || {
        err "invalid TLS SNI: $sni"
        return 1
    }

    local cert_dir cert key fingerprint cert_fingerprint
    cert_dir="${SB_CERT_DIR}/${id}/$(date -u '+%Y%m%dT%H%M%S')-$(openssl rand -hex 4)"
    safe_mkdir "$cert_dir"
    if [[ -n "${SB_TXN_CREATED_PATHS:-}" ]]; then
        printf '%s\n' "$cert_dir" >>"$SB_TXN_CREATED_PATHS"
    fi
    cert="${cert_dir}/certificate.pem"
    key="${cert_dir}/private-key.pem"

    if ! openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
        -keyout "$key" -out "$cert" \
        -subj "/CN=${sni}" \
        -addext "subjectAltName=DNS:${sni}" \
        -addext "keyUsage=digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1; then
        rm -rf -- "$cert_dir"
        err "self-signed certificate generation failed"
        return 1
    fi
    chmod 600 "$key" "$cert" || {
        rm -rf -- "$cert_dir"
        return 1
    }
    openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null || {
        rm -rf -- "$cert_dir"
        err "generated certificate validation failed"
        return 1
    }
    fingerprint=$(
        openssl x509 -in "$cert" -pubkey -noout |
            openssl pkey -pubin -outform der |
            openssl dgst -sha256 -binary |
            openssl enc -base64 -A
    )
    cert_fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | cut -d= -f2-)
    jq -n --arg mode "self-signed" --arg sni "$sni" \
        --arg cert "$cert" --arg key "$key" --arg pin "$fingerprint" \
        --arg cert_fingerprint "$cert_fingerprint" \
        '{mode:$mode,sni:$sni,certificate_path:$cert,key_path:$key,
          public_key_sha256:$pin,certificate_sha256:$cert_fingerprint}'
}

tls_public_key_pin() {
    openssl x509 -in "$1" -pubkey -noout |
        openssl pkey -pubin -outform der |
        openssl dgst -sha256 -binary |
        openssl enc -base64 -A
}

tls_certificate_matches_sni() {
    openssl x509 -in "$1" -noout -checkhost "$2" >/dev/null 2>&1
}

tls_certificate_is_system_trusted() {
    local cert="$1" ca_bundle="${SB_CA_BUNDLE:-}"
    if [[ -n "$ca_bundle" && ! -r "$ca_bundle" ]]; then
        err "configured CA bundle is unreadable: $ca_bundle"
        return 1
    elif [[ -n "$ca_bundle" ]]; then
        :
    elif [[ -r /etc/ssl/certs/ca-certificates.crt ]]; then
        ca_bundle=/etc/ssl/certs/ca-certificates.crt
    elif [[ -r /etc/pki/tls/certs/ca-bundle.crt ]]; then
        ca_bundle=/etc/pki/tls/certs/ca-bundle.crt
    else
        err "system CA bundle is unavailable"
        return 1
    fi
    openssl verify -purpose sslserver -CAfile "$ca_bundle" "$cert" >/dev/null 2>&1
}

tls_from_options() {
    local id="$1" options="$2" mode sni cert key pin cert_fingerprint managed_dir
    mode=$(jq -r '.tls_mode // empty' <<<"$options")
    sni=$(jq -r '.sni // empty' <<<"$options")
    tls_mode_valid "$mode" || {
        err "tls_mode must be trusted, provided, self-signed, or insecure"
        return 1
    }
    tls_sni_valid "$sni" || {
        err "invalid TLS SNI: $sni"
        return 1
    }
    if [[ "$mode" == "self-signed" ]]; then
        tls_generate_self_signed "$id" "$sni"
        return
    fi

    cert=$(jq -r '.certificate_path // empty' <<<"$options")
    key=$(jq -r '.key_path // empty' <<<"$options")
    if [[ "$mode" == "insecure" && ( -z "$cert" || -z "$key" ) ]]; then
        local generated
        generated=$(tls_generate_self_signed "$id" "$sni") || return 1
        jq '.mode = "insecure"' <<<"$generated"
        return
    fi
    [[ "$cert" == /* && "$key" == /* && -r "$cert" && -r "$key" ]] || {
        err "TLS certificate and key must be readable absolute paths"
        return 1
    }
    openssl pkey -in "$key" -noout >/dev/null 2>&1 || {
        err "invalid TLS private key"
        return 1
    }
    tls_certificate_matches_sni "$cert" "$sni" || {
        err "TLS certificate does not cover SNI: $sni"
        return 1
    }
    if [[ "$mode" == "trusted" ]] && ! tls_certificate_is_system_trusted "$cert"; then
        err "trusted TLS mode requires a certificate chain accepted by the system CA store"
        return 1
    fi
    managed_dir="${SB_CERT_DIR}/${id}/$(date -u '+%Y%m%dT%H%M%S')-$(openssl rand -hex 4)"
    safe_mkdir "$managed_dir" || return 1
    [[ -n "${SB_TXN_CREATED_PATHS:-}" ]] && printf '%s\n' "$managed_dir" >>"$SB_TXN_CREATED_PATHS"
    cp -- "$cert" "$managed_dir/certificate.pem" || return 1
    cp -- "$key" "$managed_dir/private-key.pem" || return 1
    chmod 600 "$managed_dir/certificate.pem" "$managed_dir/private-key.pem" || return 1
    cert="$managed_dir/certificate.pem"
    key="$managed_dir/private-key.pem"
    pin=$(tls_public_key_pin "$cert") || return 1
    cert_fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | cut -d= -f2-)
    jq -n --arg mode "$mode" --arg sni "$sni" --arg cert "$cert" \
        --arg key "$key" --arg pin "$pin" --arg cert_fingerprint "$cert_fingerprint" \
        '{mode:$mode,sni:$sni,certificate_path:$cert,key_path:$key,
          public_key_sha256:$pin,certificate_sha256:$cert_fingerprint}'
}

tls_update_from_options() {
    local id="$1" meta="$2" options="$3"
    if ! jq -e 'has("sni") or has("tls_mode") or has("certificate_path") or
      has("key_path") or .rotate_certificate == true' \
        <<<"$options" >/dev/null; then
        jq -c '.tls' <<<"$meta"
        return
    fi
    if jq -e '.rotate_certificate == true' <<<"$options" >/dev/null; then
        local current_mode
        current_mode=$(jq -r '.tls.mode' <<<"$meta")
        if [[ "$current_mode" != "self-signed" ]] &&
            ! jq -e 'has("certificate_path") and has("key_path")' <<<"$options" >/dev/null; then
            err "--rotate-certificate requires both --certificate and --key unless TLS mode is self-signed"
            return 1
        fi
    fi
    local merged
    merged=$(jq -n --argjson old "$meta" --argjson options "$options" '
      {
        tls_mode: ($options.tls_mode // $old.tls.mode),
        sni: ($options.sni // $old.tls.sni),
        certificate_path: ($options.certificate_path // $old.tls.certificate_path),
        key_path: ($options.key_path // $old.tls.key_path)
      }')
    tls_from_options "$id" "$merged"
}

tls_validate_meta() {
    local meta="$1" mode sni cert key
    mode=$(jq -r '.tls.mode' <<<"$meta")
    sni=$(jq -r '.tls.sni' <<<"$meta")
    tls_mode_valid "$mode" && tls_sni_valid "$sni" || return 1
    cert=$(jq -r '.tls.certificate_path // empty' <<<"$meta")
    key=$(jq -r '.tls.key_path // empty' <<<"$meta")
    [[ -n "$cert" && -n "$key" ]] || return 1
    [[ "$cert" == /* && "$key" == /* ]] || return 1
    if [[ "${SB_VALIDATE_FILES:-true}" == "true" ]]; then
        [[ -r "$cert" && -r "$key" ]] || return 1
        openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
        openssl pkey -in "$key" -noout >/dev/null 2>&1 || return 1
    fi
}

tls_inbound_json() {
    local meta="$1"
    jq -c '{
      enabled:true,
      server_name:.tls.sni,
      certificate_path:.tls.certificate_path,
      key_path:.tls.key_path
    }' <<<"$meta"
}

tls_outbound_json() {
    local meta="$1" mode
    mode=$(jq -r '.tls.mode' <<<"$meta")
    case "$mode" in
        trusted)
            jq -c '{enabled:true,server_name:.tls.sni,insecure:false}' <<<"$meta"
            ;;
        provided|self-signed)
            jq -c '{
              enabled:true,
              server_name:.tls.sni,
              insecure:false,
              certificate_public_key_sha256:[.tls.public_key_sha256]
            }' <<<"$meta"
            ;;
        insecure)
            jq -c '{enabled:true,server_name:.tls.sni,insecure:true}' <<<"$meta"
            ;;
    esac
}

tls_client_insecure() {
    [[ "$(jq -r '.tls.mode' <<<"$1")" == "insecure" ]]
}

tls_uri_query() {
    local meta="$1" mode sni pin
    mode=$(jq -r '.tls.mode' <<<"$meta")
    sni=$(urlencode "$(jq -r '.tls.sni' <<<"$meta")")
    case "$mode" in
        trusted)
            printf 'sni=%s&insecure=0' "$sni"
            ;;
        provided|self-signed)
            pin=$(urlencode "$(jq -r '.tls.public_key_sha256' <<<"$meta")")
            printf 'sni=%s&insecure=0&pinSHA256=%s' "$sni" "$pin"
            ;;
        insecure)
            printf 'sni=%s&insecure=1' "$sni"
            ;;
    esac
}

tls_hysteria_uri_query() {
    local meta="$1" mode sni fingerprint
    mode=$(jq -r '.tls.mode' <<<"$meta")
    sni=$(urlencode "$(jq -r '.tls.sni' <<<"$meta")")
    case "$mode" in
        trusted)
            printf 'sni=%s' "$sni"
            ;;
        provided|self-signed)
            fingerprint=$(jq -r '.tls.certificate_sha256 // empty' <<<"$meta")
            [[ -n "$fingerprint" ]] || {
                err "Hysteria URI requires the full certificate SHA-256 fingerprint"
                return 1
            }
            printf 'sni=%s&insecure=1&pinSHA256=%s' \
              "$sni" "$(urlencode "$fingerprint")"
            ;;
        insecure)
            printf 'sni=%s&insecure=1' "$sni"
            ;;
        *)
            return 1
            ;;
    esac
}

tls_status_json() {
    local meta="$1" cert
    cert=$(jq -r '.tls.certificate_path' <<<"$meta")
    if [[ -r "$cert" ]]; then
        local expires epoch now days
        expires=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-)
        epoch=$(date -d "$expires" +%s 2>/dev/null || printf '0')
        now=$(date +%s)
        days=$(((epoch - now) / 86400))
        jq -n --arg expires "$expires" --argjson days "$days" \
            '{readable:true,expires:$expires,days_remaining:$days}'
    else
        jq -n '{readable:false,expires:null,days_remaining:null}'
    fi
}
