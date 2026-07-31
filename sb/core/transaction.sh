#!/usr/bin/env bash

transaction_cleanup_created_paths() {
    local list="${SB_TXN_CREATED_PATHS:-}" path
    [[ -n "$list" && -f "$list" ]] || return 0
    while IFS= read -r path; do
        [[ -n "$path" && "$path" == "$SB_CERT_DIR"/* && "$path" != "$SB_CERT_DIR" ]] || continue
        [[ -d "$path" ]] && rm -rf -- "$path"
    done <"$list"
}

transaction_status_write() {
    local result="$1" description="$2" generation="${3:-}" rollback="${4:-false}"
    local rollback_result="${5:-not-required}"
    jq -n --arg result "$result" --arg description "$description" \
      --arg generation "$generation" --argjson rollback "$rollback" \
      --arg rollback_result "$rollback_result" \
      --arg timestamp "$(now_iso)" '
      {
        last_publish:{result:$result,description:$description,generation:$generation,timestamp:$timestamp},
        last_rollback:{
          performed:$rollback,
          result:$rollback_result,
          timestamp:(if $rollback then $timestamp else null end)
        }
      }' | atomic_write "$SB_STATUS_FILE" 600
}

transaction_show_dry_run() (
    local old_state="$1" new_state="$2" output="$3"
    local old_settings="$4" new_settings="$5" old_redacted new_redacted
    old_redacted=$(mktemp)
    new_redacted=$(mktemp)
    trap 'rm -f -- "$old_redacted" "$new_redacted"' EXIT
    state_export_file "$old_state" false >"$old_redacted"
    state_export_file "$new_state" false >"$new_redacted"
    printf '%s\n' 'Dry-run state diff (secrets redacted):'
    diff -u "$old_redacted" "$new_redacted" || true
    printf '%s\n' 'Dry-run settings diff:'
    diff -u "$old_settings" "$new_settings" || true
    printf '%s\n' 'Candidate output hashes:'
    find "$output" -type f -exec sha256sum {} + | sed "s#${output}/##"
)

# Restore the current generation link to its pre-publish target.
# Every step is checked; the caller must treat a non-zero status as an
# unrecoverable rollback failure rather than an ordinary publish failure.
transaction_restore_link() {
    local old_link="$1"
    symlink_switch "$old_link" "$SB_CURRENT_LINK" \
      "${SB_DATA_DIR}/.current.rollback.$$" current-rollback
}

# Report an unrecoverable rollback failure with the operator-actionable paths
# needed for manual recovery. Deliberately prints no credentials.
transaction_report_unrecoverable() {
    local old_link="$1" old_generation="$2" new_generation="$3" id="$4"
    err "CRITICAL: the current generation link could not be restored"
    err "CRITICAL: ${SB_CURRENT_LINK} may still reference the unverified generation ${id}"
    err "manual recovery: point ${SB_CURRENT_LINK} at ${old_link}"
    err "previous generation retained at: ${old_generation}"
    err "unverified generation retained at: ${new_generation}"
    err "run 'sb doctor' after recovery to confirm state, current and service agree"
}

# Usage: transaction_run <description> <mutator_function> [args...]
# Mutator receives the candidate state path as its first argument.
transaction_run() (
    local description="$1" mutator="$2"
    shift 2
    safe_mkdir "$SB_LOCK_DIR" || return 1
    if ! lock_is_inherited; then
        SB_LOCK_FD=9
        exec 9>"$SB_LOCK_FILE"
        flock -n "$SB_LOCK_FD" || {
            err "another sb operation holds the exclusive lock"
            return 75
        }
        SB_LOCK_HELD=true
        export SB_LOCK_FD SB_LOCK_HELD
    fi
    layout_prepare || return 1
    [[ -L "$SB_CURRENT_LINK" ]] || layout_create_empty
    layout_upgrade_generation_settings || return 1

    local old_link old_generation id candidate final state settings enabled backup rc
    local created_paths_file old_manifest
    old_link=$(readlink "$SB_CURRENT_LINK") || return 1
    old_generation=$(readlink -f "$SB_CURRENT_LINK") || return 1
    id=$(new_generation_id) || return 1
    candidate=$(mktemp -d "${SB_GENERATIONS_DIR}/.txn-${id}.XXXXXX") || {
        err "failed to create the candidate generation directory"
        return 1
    }
    created_paths_file=$(mktemp) || return 1
    SB_TXN_CREATED_PATHS="$created_paths_file"
    export SB_TXN_CREATED_PATHS
    trap 'transaction_cleanup_created_paths; [[ -n "${candidate:-}" ]] && rm -rf -- "$candidate"; rm -f -- "${created_paths_file:-}"' EXIT

    cp -a -- "$old_generation/." "$candidate/" || {
        err "failed to seed the candidate generation from: $old_generation"
        return 1
    }
    state="${candidate}/instances.json"
    settings="${candidate}/settings.json"
    SB_TXN_SETTINGS_FILE="$settings"
    export SB_TXN_SETTINGS_FILE
    old_manifest="${old_generation}/output/manifest.json"
    rm -rf -- "${candidate}/output" || {
        err "failed to reset the candidate output directory"
        return 1
    }

    "$mutator" "$state" "$@" || {
        transaction_status_write "failed" "$description" "" false
        return 1
    }
    state_validate_file "$state" || {
        transaction_status_write "failed" "$description" "" false
        return 1
    }
    settings_validate_file "$settings" || {
        transaction_status_write "failed" "$description" "" false
        return 1
    }
    runtime_render "$state" "$candidate/output" "$settings" "$id" || {
        transaction_status_write "failed" "$description" "" false
        return 1
    }
    runtime_check_config "$candidate/output/config.json" || {
        transaction_status_write "failed" "$description" "" false
        return 1
    }
    runtime_check_client_config "$candidate/output/clients/sing-box.json" || {
        transaction_status_write "failed" "$description" "" false
        return 1
    }
    runtime_validate_generation "$candidate" false "$id" || {
        transaction_status_write "failed" "$description" "" false
        return 1
    }

    if [[ "$SB_DRY_RUN" == "true" ]]; then
        transaction_show_dry_run "$old_generation/instances.json" "$state" \
          "$candidate/output" "$old_generation/settings.json" "$settings"
        return 0
    fi

    local salvage_allowed=false
    [[ -n "${SB_TXN_SALVAGE_BACKUP:-}" &&
       "${SB_TXN_SALVAGE_BACKUP}" == "$SB_INTERNAL_MARKER" ]] && salvage_allowed=true
    backup=$(backup_create "pre-publish: ${description}" false false \
      "$salvage_allowed") || return 1
    info "backup created: $backup"
    final="${SB_GENERATIONS_DIR}/${id}"

    # Stage 1: candidate becomes a final generation directory. Nothing observes
    # it yet, so a failure here only has to discard the candidate.
    if fault_armed generation-final-mv; then
        mkdir -p -- "$final" && : >"${final}/.occupied"
    fi
    if ! mv -T -- "$candidate" "$final"; then
        err "failed to publish the candidate generation: $final"
        transaction_status_write "failed" "$description" "$id" false
        return 1
    fi
    candidate=""

    # Stage 2: the current link starts resolving to the new generation. Until
    # this rename succeeds the live generation is unchanged, so a failure must
    # discard the final directory and leave no trace of a publish.
    if ! symlink_switch "generations/${id}" "$SB_CURRENT_LINK" \
      "${SB_DATA_DIR}/.current.new.$$" current-new; then
        err "failed to switch the current generation link; live generation unchanged"
        rm -rf -- "$final"
        transaction_status_write "failed" "$description" "$id" false
        return 1
    fi

    enabled=$(state_enabled_count_file "$SB_CURRENT_STATE") || return 1
    rc=0
    if ((enabled == 0)); then
        service_stop || rc=$?
        if ((rc == 0)) && [[ "${SB_SKIP_LISTENER_CHECK:-false}" != "true" ]]; then
            service_verify_removed_listeners "$old_manifest" \
              "$SB_CURRENT_OUTPUT/manifest.json" || rc=$?
        fi
    else
        service_apply || rc=$?
        if ((rc == 0)) && [[ "${SB_SKIP_LISTENER_CHECK:-false}" != "true" ]]; then
            service_verify_listeners || rc=$?
            ((rc != 0)) ||
                service_verify_removed_listeners "$old_manifest" "$SB_CURRENT_OUTPUT/manifest.json" ||
                rc=$?
        fi
    fi

    if ((rc != 0)); then
        err "publish verification failed; rolling back generation and service"
        # Stage 3 rollback: restore the current link first. If this fails the
        # manager cannot guarantee anything about the live installation, so it
        # reports an unrecoverable failure and preserves every artifact that a
        # human might need, including the candidate certificate material.
        if ! transaction_restore_link "$old_link"; then
            transaction_report_unrecoverable "$old_link" "$old_generation" "$final" "$id"
            transaction_status_write "rollback-failed" "$description" "$id" true \
              "current-link-restore-failed"
            SB_TXN_CREATED_PATHS=""
            return "$SB_EX_UNRECOVERABLE"
        fi
        local old_enabled rollback_rc=0 rollback_result
        old_enabled=$(state_enabled_count_file "$SB_CURRENT_STATE") || rollback_rc=$?
        if ((old_enabled == 0)); then
            service_stop || rollback_rc=$?
            if ((rollback_rc == 0)) &&
              [[ "${SB_SKIP_LISTENER_CHECK:-false}" != "true" ]]; then
                service_verify_removed_listeners "$final/output/manifest.json" \
                  "$old_manifest" || rollback_rc=$?
            fi
        else
            if ! service_apply; then
                service_restart || rollback_rc=$?
            fi
            if ((rollback_rc == 0)) && [[ "${SB_SKIP_LISTENER_CHECK:-false}" != "true" ]]; then
                service_verify_listeners || rollback_rc=$?
                ((rollback_rc != 0)) ||
                    service_verify_removed_listeners "$final/output/manifest.json" "$old_manifest" ||
                    rollback_rc=$?
            fi
        fi
        if ((rollback_rc == 0)); then
            # The old generation is fully live again; the rejected generation is
            # now unreferenced and safe to discard.
            rollback_result="success"
            transaction_cleanup_created_paths
            rm -rf -- "$final"
        else
            # Files were restored but the service did not come back cleanly, so
            # it may still be running out of the rejected generation. Keep that
            # directory: deleting it could pull the filesystem out from under a
            # live process and destroy recovery evidence.
            rollback_result="service-restore-failed"
            err "rollback restored the current link but service verification failed"
            err "the rejected generation is retained for recovery: $final"
            err "run 'sb doctor' to compare current, state and the running service"
            # That generation is only useful with the certificate material it
            # references, so the EXIT trap must not reclaim those paths either.
            SB_TXN_CREATED_PATHS=""
        fi
        transaction_status_write "rolled-back" "$description" "$id" true "$rollback_result"
        return 1
    fi

    transaction_status_write "success" "$description" "$id" false
    SB_TXN_CREATED_PATHS=""
    ok "publish completed: $description"
)
