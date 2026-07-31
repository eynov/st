#!/usr/bin/env bash

runtime_append_json() {
    local array="$1" value="$2"
    jq -cn --argjson array "$array" --argjson value "$value" '$array + [$value]'
}

runtime_render() {
    local state_file="$1" output_dir="$2"
    local settings_file="${3:-${SB_RENDER_SETTINGS_FILE:-$SB_SETTINGS_FILE}}"
    local generation_id="${4:-${SB_RENDER_GENERATION_ID:-unknown}}" endpoint ids
    state_validate_file "$state_file" || return 1
    settings_validate_file "$settings_file" || return 1
    safe_mkdir "$output_dir"
    safe_mkdir "$output_dir/clients"

    mapfile -t ids < <(jq -r '.instances | to_entries[] | select(.value.enabled) | .key' "$state_file")
    if ((${#ids[@]} > 0)); then
        endpoint=$(endpoint_get "$settings_file") || return 1
    else
        endpoint=""
    fi

    local inbounds='[]' clash='[]' outbounds='[]' firewall='[]' listeners='[]'
    SB_RENDER_LISTEN=$(listen_address_get "$settings_file") || return 1
    local uri_file surge_file
    uri_file="$output_dir/clients/uris.txt"
    surge_file="$output_dir/clients/surge.conf"
    : >"$uri_file"
    printf '[Proxy]\n' >"$surge_file"

    local id meta protocol fragment fn rc
    for id in "${ids[@]}"; do
        meta=$(jq -c --arg id "$id" '.instances[$id]' "$state_file")
        protocol=$(jq -r '.protocol' <<<"$meta")

        fn="${PROTO_INBOUND[$protocol]}"
        fragment=$("$fn" "$meta") || return 1
        inbounds=$(runtime_append_json "$inbounds" "$fragment") || return 1

        fn="${PROTO_OUTBOUND[$protocol]}"
        fragment=$("$fn" "$meta" "$endpoint") || return 1
        outbounds=$(runtime_append_json "$outbounds" "$fragment") || return 1

        fn="${PROTO_CLASH[$protocol]}"
        if fragment=$(SB_SUPPRESS_UNSUPPORTED_WARNINGS=true "$fn" "$meta" "$endpoint"); then
            clash=$(runtime_append_json "$clash" "$fragment") || return 1
        else
            rc=$?
            ((rc == 2)) || return "$rc"
        fi

        fn="${PROTO_URI[$protocol]}"
        if fragment=$(SB_SUPPRESS_UNSUPPORTED_WARNINGS=true "$fn" "$meta" "$endpoint"); then
            printf '%s\n' "$fragment" >>"$uri_file"
        else
            rc=$?
            ((rc == 2)) || return "$rc"
        fi

        fn="${PROTO_SURGE[$protocol]}"
        if fragment=$(SB_SUPPRESS_UNSUPPORTED_WARNINGS=true "$fn" "$meta" "$endpoint"); then
            [[ -n "$fragment" ]] && printf '%s\n' "$fragment" >>"$surge_file"
        else
            rc=$?
            ((rc == 2)) || return "$rc"
        fi

        fn="${PROTO_FIREWALL[$protocol]}"
        fragment=$("$fn" "$meta") || return 1
        firewall=$(runtime_append_json "$firewall" "$fragment") || return 1

        fn="${PROTO_EXPECTED[$protocol]}"
        fragment=$("$fn" "$meta") || return 1
        listeners=$(jq -cn --argjson current "$listeners" --argjson extra "$fragment" \
            '$current + $extra') || return 1
    done

    jq -n --argjson inbounds "$inbounds" '
      {
        log:{level:"info",timestamp:true},
        inbounds:$inbounds
      }' | atomic_write "$output_dir/config.json" 600

    jq -n --argjson proxies "$clash" '{proxies:$proxies}' |
        atomic_write "$output_dir/clients/clash.yaml" 600

    jq -n --argjson outbounds "$outbounds" '{outbounds:$outbounds}' |
        atomic_write "$output_dir/clients/sing-box.json" 600

    jq -n --argjson requirements "$firewall" \
        '{notice:"Examples only. No firewall command is executed.",instances:$requirements}' |
        atomic_write "$output_dir/firewall-requirements.json" 600

    jq -n --argjson schema "$SB_CONFIG_SCHEMA_VERSION" \
        --arg project_version "$SB_PROJECT_VERSION" \
        --arg core_version "$SB_CORE_VERSION" \
        --arg generation_id "$generation_id" \
        --arg endpoint "$endpoint" \
        --arg endpoint_source "$(jq -r '.endpoint.source' "$settings_file")" \
        --arg listen_mode "$(jq -r '.listen.mode' "$settings_file")" \
        --arg listen_address "$SB_RENDER_LISTEN" \
        --arg rendered_at "$(now_iso)" \
        --argjson count "${#ids[@]}" \
        --argjson listeners "$listeners" '
      {
        schema_version:$schema,project_version:$project_version,generation_id:$generation_id,
        sing_box_version:$core_version,rendered_at:$rendered_at,
        endpoint:{value:(if $endpoint=="" then null else $endpoint end),source:$endpoint_source},
        listen:{mode:$listen_mode,address:$listen_address},
        enabled_instances:$count,expected_listeners:$listeners
      }' | atomic_write "$output_dir/manifest.json" 600

    chmod 600 "$uri_file" "$surge_file" || return 1
    runtime_validate_outputs "$output_dir"
}

runtime_validate_generation() {
    local generation="$1" require_core_check="${2:-true}" expected_id="${3:-}"
    [[ -d "$generation" && -f "$generation/instances.json" &&
       -f "$generation/settings.json" && -d "$generation/output" ]] || {
        err "generation is incomplete: $generation"
        return 1
    }
    state_validate_file "$generation/instances.json" || return 1
    settings_validate_file "$generation/settings.json" || return 1
    runtime_validate_outputs "$generation/output" || return 1
    [[ -n "$expected_id" ]] || expected_id=$(basename "$generation")
    jq -e --arg id "$expected_id" --argjson schema "$SB_CONFIG_SCHEMA_VERSION" \
      '.schema_version==$schema and .generation_id==$id and
       (.expected_listeners|type=="array")' "$generation/output/manifest.json" >/dev/null || {
        err "generation manifest does not match its directory: $generation"
        return 1
    }
    if [[ "$require_core_check" == "true" ]]; then
        runtime_check_config "$generation/output/config.json" || return 1
        runtime_check_client_config "$generation/output/clients/sing-box.json" || return 1
    fi
    find "$generation" -type f -exec sh -c '
      for file do
        mode=$(stat -c %a "$file") || exit 1
        [ "$mode" = 600 ] || exit 1
      done
    ' sh {} + || {
        err "generation contains a file with unsafe permissions"
        return 1
    }
}

runtime_validate_outputs() {
    local output_dir="$1" file
    for file in \
        "$output_dir/config.json" \
        "$output_dir/clients/clash.yaml" \
        "$output_dir/clients/sing-box.json" \
        "$output_dir/firewall-requirements.json" \
        "$output_dir/manifest.json"; do
        json_file_valid "$file" || {
            err "generated JSON/YAML document is invalid: $file"
            return 1
        }
    done
    awk '
      /^$/ || /^\[Proxy\]$/ || /^[A-Za-z0-9_-]+ = / {next}
      {exit 1}
    ' "$output_dir/clients/surge.conf" || {
        err "generated Surge document is invalid"
        return 1
    }
    while IFS= read -r uri; do
        [[ -z "$uri" || "$uri" =~ ^(ss|vless|hysteria2)://[^[:space:]]+$ ]] || {
            err "generated URI is invalid"
            return 1
        }
    done <"$output_dir/clients/uris.txt"
}

runtime_check_config() {
    local config="$1"
    core_validate_installed false || {
        err "fixed sing-box binary version/digest/receipt validation failed"
        return 1
    }
    "$SB_BIN" check -c "$config"
}

runtime_check_client_config() {
    local config="$1"
    core_validate_installed false || {
        err "fixed sing-box binary version/digest/receipt validation failed"
        return 1
    }
    "$SB_BIN" check -c "$config"
}
