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

transaction_restore_link() {
    local old_link="$1"
    ln -s "$old_link" "${SB_DATA_DIR}/.current.rollback.$$"
    mv -fT "${SB_DATA_DIR}/.current.rollback.$$" "$SB_CURRENT_LINK"
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
    old_link=$(readlink "$SB_CURRENT_LINK")
    old_generation=$(readlink -f "$SB_CURRENT_LINK")
    id=$(new_generation_id)
    candidate=$(mktemp -d "${SB_GENERATIONS_DIR}/.txn-${id}.XXXXXX")
    created_paths_file=$(mktemp)
    SB_TXN_CREATED_PATHS="$created_paths_file"
    export SB_TXN_CREATED_PATHS
    trap 'transaction_cleanup_created_paths; [[ -n "${candidate:-}" ]] && rm -rf -- "$candidate"; rm -f -- "${created_paths_file:-}"' EXIT

    cp -a -- "$old_generation/." "$candidate/"
    state="${candidate}/instances.json"
    settings="${candidate}/settings.json"
    SB_TXN_SETTINGS_FILE="$settings"
    export SB_TXN_SETTINGS_FILE
    old_manifest="${old_generation}/output/manifest.json"
    rm -rf -- "${candidate}/output"

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
    runtime_validate_generation "$candidate" false "$id" || {
        transaction_status_write "failed" "$description" "" false
        return 1
    }

    if [[ "$SB_DRY_RUN" == "true" ]]; then
        transaction_show_dry_run "$old_generation/instances.json" "$state" \
          "$candidate/output" "$old_generation/settings.json" "$settings"
        return 0
    fi

    backup=$(backup_create "pre-publish: ${description}" false) || return 1
    info "backup created: $backup"
    final="${SB_GENERATIONS_DIR}/${id}"
    mv -- "$candidate" "$final"
    candidate=""
    ln -s "generations/${id}" "${SB_DATA_DIR}/.current.new.$$"
    mv -fT "${SB_DATA_DIR}/.current.new.$$" "$SB_CURRENT_LINK"

    enabled=$(state_enabled_count_file "$SB_CURRENT_STATE")
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
        transaction_restore_link "$old_link"
        local old_enabled rollback_rc=0 rollback_result
        old_enabled=$(state_enabled_count_file "$SB_CURRENT_STATE")
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
        transaction_cleanup_created_paths
        rm -rf -- "$final"
        if ((rollback_rc == 0)); then
            rollback_result="success"
        else
            rollback_result="failed"
            err "rollback restored files but service verification failed"
        fi
        transaction_status_write "rolled-back" "$description" "$id" true "$rollback_result"
        return 1
    fi

    transaction_status_write "success" "$description" "$id" false
    SB_TXN_CREATED_PATHS=""
    ok "publish completed: $description"
)
