#!/usr/bin/env bash

state_empty_json() {
    jq -n \
        --argjson schema_version "$SB_STATE_SCHEMA_VERSION" \
        --arg project_version "$SB_PROJECT_VERSION" \
        --arg updated_at "$(now_iso)" \
        '{
            schema_version: $schema_version,
            project_version: $project_version,
            updated_at: $updated_at,
            instances: {}
        }'
}

state_migrate_json() {
    local source="$1"
    jq \
        --argjson current "$SB_STATE_SCHEMA_VERSION" \
        --arg project_version "$SB_PROJECT_VERSION" \
        --arg updated_at "$(now_iso)" \
        --arg legacy_cert_dir "${SB_LEGACY_DIR}/certs/" \
        --arg cert_dir "${SB_CERT_DIR}/" \
        '
        if (.schema_version // 1) > $current then
            error("state schema is newer than this program")
        elif (.schema_version // 1) == 1 then
            .schema_version = $current
            | .project_version = $project_version
            | .updated_at = $updated_at
            | .instances = ((.instances // {}) | with_entries(
                .value.enabled = (.value.enabled // true)
                | .value.updated_at = (.value.updated_at // .value.created_at // $updated_at)
                | if ((.value.cert? | type) == "string" and (.value.cert | startswith($legacy_cert_dir))) then
                    .value.cert |= ($cert_dir + ltrimstr($legacy_cert_dir))
                  else . end
                | if ((.value.key? | type) == "string" and (.value.key | startswith($legacy_cert_dir))) then
                    .value.key |= ($cert_dir + ltrimstr($legacy_cert_dir))
                  else . end
                | if .value.protocol == "HY2" then
                    .value as $v
                    | .value.masquerade = ($v.masquerade // $v.masq)
                    | .value.hop = (
                        if ($v.hop_ports? // null) == null then
                            {enabled:false, start:null, end:null, interval_seconds:null, acknowledged:false}
                        else
                            ($v.hop_ports | capture("^(?<start>[0-9]+)(-(?<end>[0-9]+))?$")) as $range
                            | {
                                enabled:true,
                                start:($range.start | tonumber),
                                end:(($range.end // $range.start) | tonumber),
                                interval_seconds:($v.hop_interval // 30),
                                acknowledged:false
                              }
                        end
                    )
                    | del(.value.hop_ports, .value.hop_interval, .value.masq)
                    | .value.tls_mode = (.value.tls_mode // "insecure")
                  else . end
                | if (.value.protocol == "ANYTLS") then
                    .value.tls_mode = (.value.tls_mode // "insecure")
                  else . end
            ))
        else
            .project_version = $project_version
            | .updated_at = $updated_at
        end
        ' "$source"
}

state_validate_file() {
    local file="$1"
    jq -e \
        --argjson schema "$SB_STATE_SCHEMA_VERSION" '
        type == "object"
        and .schema_version == $schema
        and (.project_version | type == "string" and length > 0)
        and (.updated_at | type == "string" and length > 0)
        and (.instances | type == "object")
        and ([.instances | to_entries[] |
            (.key | test("^is[0-9]{2,}$"))
            and (.value | type == "object")
            and (.value.id == .key)
            and (.value.protocol | type == "string")
            and (.value.port | type == "number")
            and (.value.port >= 1 and .value.port <= 65535)
            and (.value.enabled | type == "boolean")
            and (.value.created_at | type == "string" and length > 0)
            and (.value.updated_at | type == "string" and length > 0)
        ] | all)
        and (([.instances[].id] | length) == ([.instances[].id] | unique | length))
        and (([.instances[] | select(.enabled) | "\(.protocol):\(.port)"] | length)
             == ([.instances[] | select(.enabled) | "\(.protocol):\(.port)"] | unique | length))
        ' "$file" >/dev/null || {
            err "state common schema validation failed: $file"
            return 1
        }

    local id protocol fn payload
    while IFS=$'\t' read -r id protocol; do
        proto_exists "$protocol" || {
            err "state contains unsupported protocol: $id/$protocol"
            return 1
        }
        payload=$(jq -c --arg id "$id" '.instances[$id]' "$file")
        fn="${PROTO_VALIDATE[$protocol]}"
        "$fn" "$payload" || {
            err "protocol validation failed: $id/$protocol"
            return 1
        }
    done < <(jq -r '.instances | to_entries[] | [.key,.value.protocol] | @tsv' "$file")

    state_validate_port_uniqueness "$file"
}

state_validate_port_uniqueness() {
    local file="$1"
    local collisions
    collisions=$(jq -r '
        [.instances[] | select(.enabled) |
          if (.protocol == "HY2") then ["udp:\(.port)"]
          elif (.protocol == "SS" or .protocol == "SS2022") then ["tcp:\(.port)", "udp:\(.port)"]
          else ["tcp:\(.port)"] end
        ] | flatten | group_by(.)[] | select(length > 1) | .[0]
    ' "$file")
    [[ -z "$collisions" ]] || {
        err "enabled instance listen collision: ${collisions//$'\n'/, }"
        return 1
    }
}

state_next_id_file() {
    local file="$1" max
    max=$(jq -r '[.instances | keys[] | select(test("^is[0-9]+$")) |
        ltrimstr("is") | tonumber] | max // 0' "$file")
    printf 'is%02d\n' "$((max + 1))"
}

state_get_file() {
    local file="$1" id="$2"
    jq -ec --arg id "$id" '.instances[$id] // error("instance not found")' "$file"
}

# Staging template for state writes. In test mode the `state-set-write` fault
# redirects it into a directory that does not exist so mktemp(1) fails with a
# real ENOENT, exercising the mutator-level failure path.
state_tmp_template() {
    local file="$1"
    if fault_armed state-set-write; then
        printf '%s/.sb-fault-missing/state.tmp.XXXXXX\n' "${file%/*}"
    else
        printf '%s.tmp.XXXXXX\n' "$file"
    fi
}

state_set_file() {
    local file="$1" id="$2" payload="$3" tmp
    tmp=$(mktemp "$(state_tmp_template "$file")") || return 1
    if jq --arg id "$id" --argjson value "$payload" \
        --arg project_version "$SB_PROJECT_VERSION" \
        --arg updated_at "$(now_iso)" \
        '.instances[$id] = $value
         | .project_version = $project_version
         | .updated_at = $updated_at' "$file" >"$tmp"; then
        chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
        mv -fT "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    else
        rm -f "$tmp"
        return 1
    fi
}

state_delete_file() {
    local file="$1" id="$2" tmp
    jq -e --arg id "$id" '.instances | has($id)' "$file" >/dev/null || {
        err "instance not found: $id"
        return 1
    }
    tmp=$(mktemp "$(state_tmp_template "$file")") || return 1
    if jq --arg id "$id" --arg updated_at "$(now_iso)" \
        'del(.instances[$id]) | .updated_at = $updated_at' "$file" >"$tmp"; then
        chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
        mv -fT "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    else
        rm -f "$tmp"
        return 1
    fi
}

state_patch_file() {
    local file="$1" id="$2" patch="$3" tmp
    jq -e --arg id "$id" '.instances | has($id)' "$file" >/dev/null || {
        err "instance not found: $id"
        return 1
    }
    tmp=$(mktemp "$(state_tmp_template "$file")") || return 1
    if jq --arg id "$id" --argjson patch "$patch" --arg updated_at "$(now_iso)" \
        '.instances[$id] = (.instances[$id] * $patch)
         | .instances[$id].updated_at = $updated_at
         | .updated_at = $updated_at' "$file" >"$tmp"; then
        chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
        mv -fT "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    else
        rm -f "$tmp"
        return 1
    fi
}

state_count_file() {
    jq -r '.instances | length' "$1"
}

state_enabled_count_file() {
    jq -r '[.instances[] | select(.enabled)] | length' "$1"
}

state_export_file() {
    local file="$1" include_secrets="${2:-false}"
    if [[ "$include_secrets" == "true" ]]; then
        jq . "$file"
    else
        # The parentheses are load-bearing. `|` binds looser than `|=`, so
        # without them only the first condition runs against the instance
        # value; the rest are evaluated against the {key,value} entry, whose
        # has("uuid")/has("private_key") are false, and both secrets survive
        # verbatim. public_key and short_id are not secrets and stay visible.
        jq '
          .instances |= with_entries(
            .value |= (
              if has("password") then .password = "[REDACTED]" else . end
              | if has("uuid") then .uuid = "[REDACTED]" else . end
              | if has("private_key") then .private_key = "[REDACTED]" else . end
            )
          )' "$file"
    fi
}
