#!/usr/bin/env bash

settings_default_json() {
    jq -n --argjson schema "$SB_SETTINGS_SCHEMA_VERSION" \
      --arg updated_at "$(now_iso)" '{
        schema_version:$schema,
        endpoint:{mode:"unset",value:null,allow_private:false,source:"unset",updated_at:$updated_at},
        listen:{mode:"dual",address:"::",updated_at:$updated_at}
      }'
}

settings_validate_file() {
    local file="$1" mode value allow_private
    jq -e --argjson schema "$SB_SETTINGS_SCHEMA_VERSION" '
      .schema_version == $schema
      and (.endpoint | type == "object")
      and (.endpoint.mode | IN("unset","domain","ipv4","ipv6","detected"))
      and (.endpoint.allow_private | type == "boolean")
      and (.endpoint.source | type == "string")
      and (.endpoint.updated_at | type == "string")
      and (.listen.mode | IN("dual","ipv4","ipv6"))
      and (.listen.address == (if .listen.mode=="ipv4" then "0.0.0.0" else "::" end))
      and (.listen.updated_at | type == "string")
    ' "$file" >/dev/null || {
        err "invalid settings file: $file"
        return 1
    }
    mode=$(jq -r '.endpoint.mode' "$file")
    value=$(jq -r '.endpoint.value // empty' "$file")
    allow_private=$(jq -r '.endpoint.allow_private' "$file")
    case "$mode" in
        unset) [[ -z "$value" ]] ;;
        domain) domain_valid "$value" ;;
        ipv4|detected) ipv4_valid "$value" &&
          { [[ "$allow_private" == "true" ]] || ! ipv4_nonpublic "$value"; } ;;
        ipv6) ipv6_valid "$value" &&
          { [[ "$allow_private" == "true" ]] || ! ipv6_nonpublic "$value"; } ;;
        *) return 1 ;;
    esac || {
        err "settings endpoint value does not match its mode or global-address policy"
        return 1
    }
}

settings_migrate_file() {
    local file="$1" version tmp
    version=$(jq -er '.schema_version' "$file") || return 1
    ((version <= SB_SETTINGS_SCHEMA_VERSION)) || {
        err "settings schema is newer than this program"
        return 1
    }
    ((version == SB_SETTINGS_SCHEMA_VERSION)) && {
        settings_validate_file "$file"
        return
    }
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if ! jq --argjson schema "$SB_SETTINGS_SCHEMA_VERSION" --arg updated_at "$(now_iso)" '
      if .schema_version == 1 then
        .schema_version=$schema
        | .listen={mode:"dual",address:"::",updated_at:$updated_at}
      else error("unsupported settings migration") end
    ' "$file" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -fT -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    settings_validate_file "$file"
}

settings_bootstrap_prepare() {
    safe_mkdir "$SB_CONFIG_DIR" || return 1
    if [[ -f "$SB_SETTINGS_BOOTSTRAP" ]]; then
        settings_migrate_file "$SB_SETTINGS_BOOTSTRAP"
        return
    fi
    if [[ -e "$SB_SETTINGS_LINK" && ! -L "$SB_SETTINGS_LINK" ]]; then
        cp -- "$SB_SETTINGS_LINK" "$SB_SETTINGS_BOOTSTRAP" || return 1
        chmod 600 "$SB_SETTINGS_BOOTSTRAP" || return 1
        settings_migrate_file "$SB_SETTINGS_BOOTSTRAP"
        return
    fi
    settings_default_json | atomic_write "$SB_SETTINGS_BOOTSTRAP" 600
}

settings_link_publish() {
    [[ -L "$SB_CURRENT_LINK" && -f "$SB_SETTINGS_FILE" ]] || return 1
    local temp="${SB_CONFIG_DIR}/.settings.link.$$"
    ln -s "$SB_SETTINGS_FILE" "$temp" || return 1
    if [[ -e "$SB_SETTINGS_LINK" && ! -L "$SB_SETTINGS_LINK" ]]; then
        mv -- "$SB_SETTINGS_LINK" "${SB_CONFIG_DIR}/settings.pre-generation.$(date -u +%Y%m%dT%H%M%SZ)" ||
            return 1
    fi
    mv -fT -- "$temp" "$SB_SETTINGS_LINK" || {
        err "failed to publish the settings compatibility symlink"
        rm -f -- "$temp"
        return 1
    }
}

settings_validate() {
    settings_validate_file "${1:-$SB_SETTINGS_FILE}"
}

listen_set_file() {
    local file="$1" mode="$2" address tmp
    case "$mode" in
        dual|ipv6) address="::" ;;
        ipv4) address="0.0.0.0" ;;
        *) err "listen mode must be dual, ipv4, or ipv6"; return 1 ;;
    esac
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if ! jq --arg mode "$mode" --arg address "$address" --arg updated_at "$(now_iso)" '
      .listen={mode:$mode,address:$address,updated_at:$updated_at}
    ' "$file" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -fT -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    settings_validate_file "$file"
}

listen_set() {
    listen_set_file "$SB_SETTINGS_FILE" "$1"
}

listen_address_get() {
    local file="${1:-${SB_RENDER_SETTINGS_FILE:-$SB_SETTINGS_FILE}}"
    settings_validate_file "$file" || return 1
    jq -er '.listen.address' "$file"
}

endpoint_validate_value() {
    local value="$1" allow_nonpublic="${2:-false}"
    endpoint_valid "$value" "$allow_nonpublic" || {
        err "invalid endpoint or non-global address not explicitly allowed: $value"
        return 1
    }
    # The override is a separate explicit flag; --yes never implies it. State the
    # risk every time it actually suppresses a rejection.
    if [[ "$allow_nonpublic" == "true" ]] &&
      { { ipv4_valid "$value" && ipv4_nonpublic "$value"; } ||
        { ipv6_valid "$value" && ipv6_nonpublic "$value"; }; }; then
        warn "endpoint ${value} is a special-purpose address accepted only because"
        warn "--allow-private-endpoint was given; clients outside this network cannot reach it"
    fi
    if domain_valid "$value"; then
        endpoint_domain_resolves_global "$value" "$allow_nonpublic"
    fi
}

endpoint_get() {
    local file="${1:-${SB_RENDER_SETTINGS_FILE:-$SB_SETTINGS_FILE}}"
    settings_validate_file "$file" || return 1
    local mode value allow_private
    mode=$(jq -r '.endpoint.mode' "$file")
    value=$(jq -r '.endpoint.value // empty' "$file")
    allow_private=$(jq -r '.endpoint.allow_private' "$file")
    [[ "$mode" != "unset" && -n "$value" ]] || {
        err "client endpoint is not configured; run: sb endpoint set <domain-or-ip>"
        return 1
    }
    endpoint_validate_value "$value" "$allow_private" || return 1
    printf '%s\n' "$value"
}

endpoint_set_file() {
    local file="$1" value="$2" allow_private="${3:-false}" mode tmp
    endpoint_validate_value "$value" "$allow_private" || return 1
    if ipv4_valid "$value"; then mode="ipv4"
    elif ipv6_valid "$value"; then mode="ipv6"
    else mode="domain"
    fi
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if ! jq --arg mode "$mode" --arg value "$value" \
      --argjson allow_private "$allow_private" --arg updated_at "$(now_iso)" '
      .endpoint={mode:$mode,value:$value,allow_private:$allow_private,
        source:"explicit",updated_at:$updated_at}
    ' "$file" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -fT -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    settings_validate_file "$file"
}

endpoint_set() {
    endpoint_set_file "$SB_SETTINGS_FILE" "$1" "${2:-false}"
}

endpoint_detect_file() {
    local file="$1" value=""
    value=$(curl -4fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)
    endpoint_valid "$value" false || {
        err "public endpoint detection failed; no interface-address fallback was written"
        return 1
    }
    endpoint_set_file "$file" "$value" false || return 1
    local tmp
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if ! jq --arg updated_at "$(now_iso)" '
      .endpoint.mode="detected" | .endpoint.source="api.ipify.org" |
      .endpoint.updated_at=$updated_at
    ' "$file" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -fT -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    settings_validate_file "$file" || return 1
    printf '%s\n' "$value"
}

endpoint_detect() {
    endpoint_detect_file "$SB_SETTINGS_FILE"
}
