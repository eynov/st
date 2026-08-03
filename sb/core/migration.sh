#!/usr/bin/env bash

migration_fault() {
    [[ "${SB_TEST_MIGRATION_FAIL_AT:-}" != "$1" ]] || {
        err "injected migration failure: $1"
        return 1
    }
}

layout_prepare() {
    safe_mkdir "$SB_CONFIG_DIR" || return 1
    safe_mkdir "$SB_DATA_DIR" || return 1
    safe_mkdir "$SB_CERT_DIR" || return 1
    safe_mkdir "$SB_GENERATIONS_DIR" || return 1
    safe_mkdir "$SB_BACKUP_DIR" || return 1
    safe_mkdir "$SB_LOCK_DIR" || return 1
}

layout_create_empty() (
    layout_prepare || return 1
    [[ -L "$SB_CURRENT_LINK" ]] && return 0
    settings_bootstrap_prepare || return 1
    local generation id
    id=$(new_generation_id)
    generation="${SB_GENERATIONS_DIR}/.migrate-${id}"
    trap '[[ -z "${generation:-}" ]] || rm -rf -- "$generation"' EXIT
    safe_mkdir "$generation" || return 1
    state_empty_json | atomic_write "$generation/instances.json" 600 || return 1
    cp -- "$SB_SETTINGS_BOOTSTRAP" "$generation/settings.json" || return 1
    chmod 600 "$generation/settings.json" || return 1
    runtime_render "$generation/instances.json" "$generation/output" \
      "$generation/settings.json" "$id" || return 1
    runtime_check_config "$generation/output/config.json" || return 1
    mv -- "$generation" "${SB_GENERATIONS_DIR}/${id}" || return 1
    generation=""
    ln -s "generations/${id}" "${SB_DATA_DIR}/.current.new.$$" || return 1
    mv -fT -- "${SB_DATA_DIR}/.current.new.$$" "$SB_CURRENT_LINK" || return 1
    settings_link_publish
)

layout_upgrade_generation_settings() (
    local current id candidate
    current=$(readlink -f "$SB_CURRENT_LINK") || return 1
    [[ -f "$current/settings.json" ]] && {
        settings_link_publish
        return
    }
    settings_bootstrap_prepare || return 1
    id=$(new_generation_id)
    candidate="${SB_GENERATIONS_DIR}/.migrate-${id}"
    trap '[[ -z "${candidate:-}" ]] || rm -rf -- "$candidate"' EXIT
    cp -a -- "$current" "$candidate" || return 1
    cp -- "$SB_SETTINGS_BOOTSTRAP" "$candidate/settings.json" || return 1
    chmod 600 "$candidate/settings.json" || return 1
    rm -rf -- "$candidate/output"
    runtime_render "$candidate/instances.json" "$candidate/output" \
      "$candidate/settings.json" "$id" || return 1
    runtime_check_config "$candidate/output/config.json" || return 1
    mv -- "$candidate" "${SB_GENERATIONS_DIR}/${id}" || return 1
    candidate=""
    ln -s "generations/${id}" "${SB_DATA_DIR}/.current.new.$$" || return 1
    mv -fT -- "${SB_DATA_DIR}/.current.new.$$" "$SB_CURRENT_LINK" || return 1
    settings_link_publish
)

# sb v2 never stored an endpoint. It re-detected the public address every time
# it compiled client output and rendered the result straight into the artifacts
# under ${SB_LEGACY_DIR}/output, so those artifacts are the only place the old
# install recorded which address its clients actually dial.
#
# Emit one candidate per line. sb v2 wrote its clash proxies as one compact JSON
# object per line under `proxies:`, each carrying the endpoint as "server". Only
# that structured field is read: scanning free text would also pick up SNI and
# masquerade hosts, which are not endpoints and would make an otherwise
# unambiguous recovery look ambiguous.
migration_legacy_endpoint_candidates() {
    local output_dir="${SB_LEGACY_DIR}/output" file
    [[ -d "$output_dir" ]] || return 0
    while IFS= read -r file; do
        sed -n 's/^[[:space:]]*-[[:space:]]*\({.*}\)[[:space:]]*$/\1/p' "$file" |
          jq -r 'fromjson? | select(type == "object") | .server // empty' -R
    done < <(find "$output_dir" -maxdepth 2 -type f)
}

# Recover the sb v2 endpoint into $1 (a settings file) and print it.
#
# Deliberately fail-closed: the value is accepted only when every legacy client
# artifact agrees on it and it still passes the unchanged v3 endpoint policy.
# sb v2's detection could fall back to a route-local address, so a recovered
# value is not trusted for being present - it is validated exactly like one an
# operator types.
migration_recover_endpoint() {
    local file="$1" candidates count value
    candidates=$(migration_legacy_endpoint_candidates | sed '/^$/d' | sort -u) || return 1
    [[ -n "$candidates" ]] || {
        err "no sb v2 client output under ${SB_LEGACY_DIR}/output records an endpoint"
        return 1
    }
    count=$(printf '%s\n' "$candidates" | wc -l) || return 1
    ((count == 1)) || {
        err "sb v2 client output records ${count} different endpoints; refusing to guess"
        return 1
    }
    value="$candidates"
    endpoint_valid "$value" false || {
        err "the endpoint recorded by sb v2 is not a usable public endpoint: ${value}"
        return 1
    }
    endpoint_set_file "$file" "$value" false || return 1
    local tmp
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if ! jq --arg updated_at "$(now_iso)" '
      .endpoint.source="sb-v2-migration" | .endpoint.updated_at=$updated_at
    ' "$file" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -fT -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    settings_validate_file "$file" || return 1
    printf '%s\n' "$value"
}

# Whether the migrated generation will contain at least one enabled instance and
# therefore need an endpoint to render. This mirrors the hopping rule applied in
# migrate_legacy below: a legacy HY2 node with an unacknowledged hopping range is
# migrated disabled, so on its own it does not require an endpoint. The guard in
# migrate_legacy re-checks the real candidate state, so a drift between the two
# costs a later stop, never a wrong migration.
migration_legacy_requires_endpoint() {
    local legacy_state="$1" enabled
    enabled=$(jq '[.instances[]? |
      select((.enabled != false) and
        ((.protocol != "HY2") or ((.hop_ports // null) == null)))] | length' \
      "$legacy_state") || return 1
    ((enabled > 0))
}

# Bring the endpoint into the bootstrap settings before anything is modified.
# Returns SB_EX_MIGRATION_INPUT when the upgrade cannot proceed without an
# operator-supplied endpoint; the caller must keep the new manager installed so
# that command is actually runnable.
migration_endpoint_prepare() {
    local legacy_state="$1" mode recovered
    migration_legacy_requires_endpoint "$legacy_state" || return 0
    mode=$(jq -r '.endpoint.mode' "$SB_SETTINGS_BOOTSTRAP") || return 1
    # An endpoint supplied on this invocation always wins over a recovered one.
    [[ "$mode" == "unset" ]] || return 0
    if recovered=$(migration_recover_endpoint "$SB_SETTINGS_BOOTSTRAP"); then
        info "endpoint recovered from sb v2 client output: ${recovered}"
        return 0
    fi
    err "the sb v2 endpoint could not be recovered automatically"
    err "no legacy data was changed; supply it once to complete the migration:"
    err "  sb install --endpoint <domain-or-public-ip> --yes"
    return "$SB_EX_MIGRATION_INPUT"
}

migration_normalize_tls() {
    local file="$1" tmp id protocol cert key sni pin cert_fingerprint
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if ! jq '
      .instances |= with_entries(
        if (.value.protocol=="HY2" or .value.protocol=="ANYTLS") then
          .value.tls={
            mode:(.value.tls_mode // "insecure"),
            sni:(.value.sni // "invalid.local"),
            certificate_path:.value.cert,key_path:.value.key,
            public_key_sha256:null,certificate_sha256:null
          } | del(.value.tls_mode,.value.sni,.value.cert,.value.key)
        else . end
      )' "$file" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -fT -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }

    while IFS=$'\t' read -r id protocol cert key sni; do
        [[ "$protocol" == "HY2" || "$protocol" == "ANYTLS" ]] || continue
        [[ -r "$cert" && -r "$key" ]] || {
            err "legacy TLS files missing for $id"
            return 1
        }
        tls_certificate_matches_sni "$cert" "$sni" || {
            err "legacy certificate does not match SNI for $id"
            return 1
        }
        pin=$(tls_public_key_pin "$cert") || return 1
        cert_fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 |
            cut -d= -f2-) || return 1
        tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
        if ! jq --arg id "$id" --arg pin "$pin" --arg fingerprint "$cert_fingerprint" '
          .instances[$id].tls.public_key_sha256=$pin |
          .instances[$id].tls.certificate_sha256=$fingerprint
        ' "$file" >"$tmp"; then
            rm -f -- "$tmp"
            return 1
        fi
        chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
        mv -fT -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
    done < <(jq -r '.instances | to_entries[] |
      [.key,.value.protocol,(.value.tls.certificate_path//""),
       (.value.tls.key_path//""),(.value.tls.sni//"")] | @tsv' "$file")
}

legacy_backup_create() (
    local id candidate final
    id="$(date -u '+%Y%m%dT%H%M%SZ')-legacy-$$-$(openssl rand -hex 3)"
    safe_mkdir "$SB_BACKUP_DIR" || return 1
    candidate=$(mktemp -d "${SB_BACKUP_DIR}/.backup-${id}.XXXXXX") || return 1
    final="${SB_BACKUP_DIR}/${id}"
    trap '[[ -z "${candidate:-}" ]] || rm -rf -- "$candidate"' EXIT
    backup_copy_tree legacy-root "$SB_LEGACY_DIR" "$candidate/legacy" || return 1
    jq -e '.instances|type=="object"' "$candidate/legacy/instances.json" >/dev/null ||
        return 1
    [[ ! -e "$SB_SETTINGS_BOOTSTRAP" ]] ||
        cp -- "$SB_SETTINGS_BOOTSTRAP" "$candidate/settings.json" || return 1
    [[ ! -f "$SB_SERVICE_FILE" ]] ||
        cp -- "$SB_SERVICE_FILE" "$candidate/sb-core.service" || return 1
    [[ ! -x "$SB_BIN" ]] ||
        cp --preserve=mode,timestamps -- "$SB_BIN" "$candidate/sing-box" || return 1
    jq -n --arg id "$id" --arg created_at "$(now_iso)" '{
      schema_version:1,id:$id,reason:"pre-legacy-migration",created_at:$created_at,
      kind:"legacy"
    }' | atomic_write "$candidate/metadata.json" 600 || return 1
    find "$candidate" -type d -exec chmod 700 {} + || return 1
    find "$candidate" -type f -exec chmod go-rwx {} + || return 1
    [[ -f "$candidate/legacy/instances.json" &&
       -f "$candidate/metadata.json" ]] || return 1
    backup_permissions_validate "$candidate" || return 1
    mv -- "$candidate" "$final" || return 1
    candidate=""
    printf '%s\n' "$final"
)

migrate_legacy() (
    layout_prepare || return 1
    if [[ -L "$SB_CURRENT_LINK" ]]; then
        layout_upgrade_generation_settings
        return
    fi
    settings_bootstrap_prepare || return 1
    local legacy_state="${SB_LEGACY_DIR}/instances.json"
    [[ -f "$legacy_state" ]] || {
        layout_create_empty
        return
    }
    # Before the backup, before the certificate swap, before anything: settle
    # the endpoint. Failing here leaves the legacy install byte-for-byte intact.
    migration_endpoint_prepare "$legacy_state" || return $?

    local legacy_backup id generation state cert_candidate cert_previous="" published=false
    legacy_backup=$(legacy_backup_create) || {
        err "legacy backup failed; migration stopped before live data changed"
        return 1
    }
    info "legacy backup created: $legacy_backup"
    id=$(new_generation_id)
    generation="${SB_GENERATIONS_DIR}/.migrate-${id}"
    cert_candidate="${SB_DATA_DIR}/.cert-migrate-${id}"
    trap '
      [[ -z "${generation:-}" ]] || rm -rf -- "$generation"
      [[ -z "${cert_candidate:-}" ]] || rm -rf -- "$cert_candidate"
      if [[ "$published" != "true" && -n "$cert_previous" && -d "$cert_previous" ]]; then
        rm -rf -- "$SB_CERT_DIR"
        mv -- "$cert_previous" "$SB_CERT_DIR" ||
          printf "CRITICAL: certificate directory not restored; move %s to %s\n" \
            "$cert_previous" "$SB_CERT_DIR" >&2
      fi
    ' EXIT
    safe_mkdir "$generation" || return 1
    safe_mkdir "$cert_candidate" || return 1
    [[ ! -d "$SB_CERT_DIR" ]] ||
        cp -a -- "$SB_CERT_DIR/." "$cert_candidate/" || return 1
    [[ ! -d "${SB_LEGACY_DIR}/certs" ]] ||
        cp -a -- "${SB_LEGACY_DIR}/certs/." "$cert_candidate/" || return 1
    find "$cert_candidate" -type d -exec chmod 700 {} + || return 1
    find "$cert_candidate" -type f -exec chmod 600 {} + || return 1

    cert_previous="${SB_DATA_DIR}/.cert-previous-${id}"
    mv -- "$SB_CERT_DIR" "$cert_previous" || return 1
    mv -- "$cert_candidate" "$SB_CERT_DIR" || return 1
    cert_candidate=""
    migration_fault after-cert-swap || return 1

    state="${generation}/instances.json"
    state_migrate_json "$legacy_state" | atomic_write "$state" 600 || return 1
    # An unacknowledged legacy hopping node is retained but disabled. It can only
    # be enabled after an explicit port-hopping acknowledgement.
    local tmp
    tmp=$(mktemp "${state}.tmp.XXXXXX")
    jq '.instances |= with_entries(
      if .value.protocol=="HY2" and .value.hop.enabled and
         (.value.hop.acknowledged|not)
      then .value.enabled=false | .value.hop.confirmation_required=true
      else . end)' "$state" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -fT -- "$tmp" "$state" || { rm -f -- "$tmp"; return 1; }
    migration_normalize_tls "$state" || return 1
    cp -- "$SB_SETTINGS_BOOTSTRAP" "$generation/settings.json" || return 1
    chmod 600 "$generation/settings.json" || return 1
    state_validate_file "$state" || return 1
    # The candidate state is the real input to the render, so re-check it rather
    # than trusting the pre-flight prediction. The EXIT trap restores the
    # certificate directory and drops every candidate, so stopping here is still
    # a no-change stop and the operator still gets a runnable command.
    if (( $(state_enabled_count_file "$state") > 0 )) &&
      [[ "$(jq -r '.endpoint.mode' "$generation/settings.json")" == "unset" ]]; then
        err "the migrated nodes need an endpoint and none could be recovered"
        err "no legacy data was changed; supply it once to complete the migration:"
        err "  sb install --endpoint <domain-or-public-ip> --yes"
        return "$SB_EX_MIGRATION_INPUT"
    fi
    runtime_render "$state" "$generation/output" "$generation/settings.json" "$id" ||
        return 1
    runtime_check_config "$generation/output/config.json" || return 1
    migration_fault after-render || return 1
    mv -- "$generation" "${SB_GENERATIONS_DIR}/${id}" || return 1
    generation=""
    ln -s "generations/${id}" "${SB_DATA_DIR}/.current.new.$$" || return 1
    mv -fT -- "${SB_DATA_DIR}/.current.new.$$" "$SB_CURRENT_LINK" || return 1
    settings_link_publish || return 1
    published=true
    rm -rf -- "$cert_previous"
    cert_previous=""
    ok "legacy data migrated; source retained at $SB_LEGACY_DIR"
)
