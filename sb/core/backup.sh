#!/usr/bin/env bash

backup_fault() {
    [[ "${SB_TEST_BACKUP_FAIL_AT:-}" != "$1" ]] || {
        err "injected backup failure: $1"
        return 1
    }
}

backup_copy_tree() {
    local label="$1" source="$2" destination="$3"
    backup_fault "$label" || return 1
    cp -a -- "$source" "$destination" || {
        err "backup copy failed: $label"
        return 1
    }
}

backup_permissions_validate() {
    local root="$1"
    find "$root" -type d -exec sh -c '
      for path do
        mode=$(stat -c %a "$path") || exit 1
        [ "$mode" = 700 ] || exit 1
      done
    ' sh {} + || return 1
    find "$root" -type f -exec sh -c '
      for path do
        mode=$(stat -c %a "$path") || exit 1
        case "$mode" in 600|700) ;; *) exit 1 ;; esac
      done
    ' sh {} +
}

backup_tls_files_validate() {
    local dir="$1" id live_cert live_key sni expected_fingerprint
    local cert_relative key_relative backup_cert backup_key cert_public key_public actual_fingerprint
    while IFS=$'\t' read -r id live_cert live_key sni expected_fingerprint; do
        [[ "$live_cert" == "$SB_CERT_DIR"/* && "$live_key" == "$SB_CERT_DIR"/* ]] || {
            err "TLS files are outside the managed certificate directory: $id"
            return 1
        }
        cert_relative=${live_cert#"$SB_CERT_DIR"/}
        key_relative=${live_key#"$SB_CERT_DIR"/}
        backup_cert="$dir/certs/$cert_relative"
        backup_key="$dir/certs/$key_relative"
        [[ -f "$backup_cert" && -f "$backup_key" ]] || {
            err "backup is missing managed TLS material: $id"
            return 1
        }
        openssl x509 -in "$backup_cert" -noout -checkend 0 >/dev/null 2>&1 || return 1
        openssl pkey -in "$backup_key" -noout >/dev/null 2>&1 || return 1
        tls_certificate_matches_sni "$backup_cert" "$sni" || return 1
        cert_public=$(openssl x509 -in "$backup_cert" -pubkey -noout |
          openssl pkey -pubin -outform der |
          sha256sum | awk '{print $1}') || return 1
        key_public=$(openssl pkey -in "$backup_key" -pubout -outform der |
          sha256sum | awk '{print $1}') || return 1
        [[ "$cert_public" == "$key_public" ]] || return 1
        actual_fingerprint=$(openssl x509 -in "$backup_cert" -noout \
          -fingerprint -sha256 | cut -d= -f2-) || return 1
        [[ "$actual_fingerprint" == "$expected_fingerprint" ]] || return 1
    done < <(jq -r '.instances | to_entries[] | .value |
      select(.protocol=="HY2" or .protocol=="ANYTLS") |
      [.id,.tls.certificate_path,.tls.key_path,.tls.sni,.tls.certificate_sha256] |
      @tsv' "$dir/generation/instances.json")
}

backup_validate() {
    local dir="$1" generation_id
    [[ -d "$dir" && -f "$dir/metadata.json" && -d "$dir/generation" &&
       -f "$dir/generation/instances.json" && -f "$dir/generation/settings.json" &&
       -d "$dir/generation/output" && -d "$dir/certs" ]] || return 1
    jq -e '
      .schema_version==1 and (.id|type=="string" and length>0) and
      (.reason|type=="string") and (.created_at|type=="string") and
      (.project_version|type=="string") and (.sing_box_version|type=="string")
    ' "$dir/metadata.json" >/dev/null || return 1
    generation_id=$(jq -er '.generation_id' "$dir/generation/output/manifest.json") || return 1
    SB_VALIDATE_FILES=false \
      runtime_validate_generation "$dir/generation" false "$generation_id" || return 1
    backup_tls_files_validate "$dir" || return 1
    backup_permissions_validate "$dir"
}

# Is the live generation itself in a restorable, self-consistent state?
#
# Salvage mode keys off this, not off the half-built backup candidate. Probing
# the candidate cannot work: backup_validate hard-requires metadata.json, which
# does not exist until the end of backup_create, so such a probe always fails
# and would drive every salvage-eligible call into salvage mode regardless of
# the health of the data being snapshotted.
backup_live_source_valid() {
    local target="$1" generation_id
    [[ -d "$target" && -f "$target/instances.json" && -f "$target/settings.json" &&
       -d "$target/output" && -f "$target/output/manifest.json" ]] || return 1
    generation_id=$(jq -er '.generation_id' "$target/output/manifest.json" 2>/dev/null) || return 1
    SB_VALIDATE_FILES=false \
      runtime_validate_generation "$target" false "$generation_id" >/dev/null 2>&1 || return 1
    state_validate_file "$target/instances.json" >/dev/null 2>&1 || return 1
    settings_validate_file "$target/settings.json" >/dev/null 2>&1 || return 1
}

# backup_create <reason> [include_app] [include_core] [salvage]
#
# salvage=true is for recovery paths only. A recovery runs precisely when the
# live generation may already be invalid, and refusing to snapshot invalid data
# would block the restore that fixes it. In salvage mode a *validation* failure
# downgrades the backup to a marked salvage snapshot instead of aborting.
# Injected faults and real copy, permission or metadata failures stay fatal in
# every mode, so this does not weaken the backup-atomicity guarantees.
backup_create() (
    local reason="${1:-manual}" include_app="${2:-false}" include_core="${3:-false}"
    local salvage="${4:-false}" salvage_used=false
    local id candidate final current_target
    id="$(date -u '+%Y%m%dT%H%M%SZ')-$$-$(openssl rand -hex 3)"
    safe_mkdir "$SB_BACKUP_DIR" || return 1
    backup_fault target-dir || return 1
    candidate=$(mktemp -d "${SB_BACKUP_DIR}/.backup-${id}.XXXXXX") || return 1
    final="${SB_BACKUP_DIR}/${id}"
    trap '[[ -z "${candidate:-}" ]] || rm -rf -- "$candidate"' EXIT

    current_target=$(readlink -f "$SB_CURRENT_LINK") || {
        err "current generation is unavailable; refusing an incomplete backup"
        return 1
    }
    [[ -d "$current_target" ]] || return 1
    # Decide salvage from the live source before anything is copied.
    if [[ "$salvage" == "true" ]] && ! backup_live_source_valid "$current_target"; then
        salvage_used=true
    fi
    backup_copy_tree generation-copy "$current_target" "$candidate/generation" || return 1
    backup_fault state-copy || return 1
    cp -- "$current_target/instances.json" "$candidate/generation/instances.json" || return 1
    backup_fault settings-copy || return 1
    cp -- "$current_target/settings.json" "$candidate/generation/settings.json" || return 1

    if [[ -d "$SB_CERT_DIR" ]]; then
        backup_copy_tree cert-copy "$SB_CERT_DIR" "$candidate/certs" || return 1
    else
        safe_mkdir "$candidate/certs" || return 1
    fi
    [[ ! -f "$SB_SERVICE_FILE" ]] ||
        { backup_fault unit-copy && cp -a -- "$SB_SERVICE_FILE" "$candidate/sb-core.service"; } ||
        return 1
    if [[ "$include_core" == "true" && -x "$SB_BIN" ]]; then
        backup_fault core-copy || return 1
        cp --preserve=mode,timestamps -- "$SB_BIN" "$candidate/sing-box" || return 1
        "$SB_BIN" version >"$candidate/sing-box.version" 2>&1 || return 1
        [[ ! -f "$SB_CORE_RECEIPT" ]] ||
            cp -- "$SB_CORE_RECEIPT" "$candidate/core.json" || return 1
    fi
    if [[ "$include_app" == "true" && -d "$SB_APP_DIR" ]]; then
        backup_copy_tree app-copy "$SB_APP_DIR" "$candidate/app" || return 1
    fi

    backup_fault metadata-write || return 1
    jq -n --arg id "$id" --arg reason "$reason" --arg created_at "$(now_iso)" \
      --arg project_version "$SB_PROJECT_VERSION" --arg core_version "$SB_CORE_VERSION" \
      --argjson salvage "$salvage_used" '{
        schema_version:1,id:$id,reason:$reason,created_at:$created_at,
        project_version:$project_version,sing_box_version:$core_version,
        salvage:$salvage
      }' | atomic_write "$candidate/metadata.json" 600 || return 1

    find "$candidate" -type d -exec chmod 700 {} + || return 1
    find "$candidate" -type f -exec chmod go-rwx {} + || return 1
    if [[ "$salvage_used" == "true" ]]; then
        warn "live data did not validate; keeping an unvalidated salvage snapshot"
        warn "salvage snapshot is for forensics only and is not restorable: ${id}"
    else
        backup_validate "$candidate" || {
            err "backup candidate validation failed"
            return 1
        }
    fi
    [[ ! -e "$final" ]] || return 1
    mv -- "$candidate" "$final" || return 1
    candidate=""
    printf '%s\n' "$final"
)

backup_list() {
    [[ -d "$SB_BACKUP_DIR" ]] || return 0
    find "$SB_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' |
        sort -r
}
