#!/usr/bin/env bash

SB_INSTALL_ROOT="${SB_INSTALL_ROOT:-/opt/sb}"
SB_RELEASES_DIR="${SB_RELEASES_DIR:-${SB_INSTALL_ROOT}/releases}"
SB_APP_LINK="${SB_APP_LINK:-${SB_INSTALL_ROOT}/app}"
SB_COMMAND_LINK="${SB_COMMAND_LINK:-/usr/local/bin/sb}"

manager_validate_source() {
    local source="$1" file source_version
    [[ -x "$source/sb" && -f "$source/version.json" && -f "$source/checksums.json" ]] || {
        err "invalid sb source directory: $source"
        return 1
    }
    while IFS= read -r file; do
        bash -n "$file" || return 1
    done < <(find "$source" -type f \( -name '*.sh' -o -name 'sb' \) -print)
    source_version=$(jq -er '.project_version | select(type == "string" and length > 0)' \
      "$source/version.json") || {
        err "source project version is missing"
        return 1
    }
    grep -Fqx "SB_PROJECT_VERSION=\"${source_version}\"" "$source/core/common.sh" || {
        err "source version metadata does not match core/common.sh"
        return 1
    }
    local checksums_hash declared_hash
    checksums_hash=$(sha256sum "$source/checksums.json" | awk '{print $1}') || return 1
    declared_hash=$(sed -n 's/^SB_CHECKSUMS_SHA256="\([0-9a-f]*\)"$/\1/p' \
      "$source/core/common.sh")
    [[ "$checksums_hash" == "$declared_hash" ]] || {
        err "checksums.json does not match the pinned source integrity value"
        return 1
    }
}

# Undo an application link switch and discard the rejected release.
#
# Returns 0 when the previous application state was fully restored, and
# SB_EX_UNRECOVERABLE when the link itself could not be restored. In the latter
# case the rejected release is deliberately kept: it is the only artifact an
# operator can use to work out what the app link is currently pointing at.
manager_rollback_app() {
    local previous_link="$1" release_dir="$2" reason="$3"
    if [[ -n "$previous_link" ]]; then
        if ! symlink_switch "$previous_link" "$SB_APP_LINK" \
          "${SB_INSTALL_ROOT}/.app.rollback.$$" app-rollback; then
            err "CRITICAL: ${reason}, and the application link could not be restored"
            err "CRITICAL: ${SB_APP_LINK} may still reference the rejected release"
            err "manual recovery: point ${SB_APP_LINK} at ${previous_link}"
            err "rejected release retained at: ${release_dir}"
            return "$SB_EX_UNRECOVERABLE"
        fi
    elif ! rm -f -- "$SB_APP_LINK"; then
        err "CRITICAL: ${reason}, and the partial application link could not be removed"
        err "manual recovery: remove ${SB_APP_LINK}"
        err "rejected release retained at: ${release_dir}"
        return "$SB_EX_UNRECOVERABLE"
    fi
    if ! rm -rf -- "$release_dir"; then
        err "failed to remove the rejected release: $release_dir"
        return 1
    fi
    err "${reason}; application link rolled back"
    return 1
}

# Classify the management command path before touching it, so an unrelated file
# or another project's symlink is never silently replaced.
manager_command_link_conflict() {
    local target
    if [[ -L "$SB_COMMAND_LINK" ]]; then
        target=$(readlink -- "$SB_COMMAND_LINK") || return 0
        case "$target" in
            "${SB_APP_LINK}/sb"|"${SB_INSTALL_ROOT}"/*) return 1 ;;
        esac
        err "$SB_COMMAND_LINK is a symlink to ${target}, which sb does not manage"
        err "remove it explicitly, then rerun the installation"
        return 0
    fi
    if [[ -e "$SB_COMMAND_LINK" ]]; then
        err "$SB_COMMAND_LINK exists and is not a managed symlink; refusing replacement"
        return 0
    fi
    return 1
}

manager_install_source() {
    local source="$1" source_version release_id release_dir stage previous_link=""
    local rollback_rc
    manager_validate_source "$source" || return 1
    source_version=$(jq -r '.project_version' "$source/version.json") || return 1
    safe_mkdir "$SB_INSTALL_ROOT" 755 || return 1
    safe_mkdir "$SB_RELEASES_DIR" 755 || return 1
    release_id="${source_version}-$(date -u '+%Y%m%dT%H%M%SZ')-$(openssl rand -hex 3)" || return 1

    local stage_template="${SB_RELEASES_DIR}/.stage-${release_id}.XXXXXX"
    if fault_armed release-stage-mkdir; then
        stage_template="${SB_RELEASES_DIR}/.sb-fault-missing/.stage.XXXXXX"
    fi
    stage=$(mktemp -d "$stage_template") || {
        err "failed to create the release staging directory"
        return 1
    }
    # Redirect the copy into a directory that does not exist so cp(1) fails with
    # a real errno; a mode-based fault would be bypassed when running as root.
    local copy_dest="${stage}/"
    if fault_armed release-copy; then
        copy_dest="${stage}/.sb-fault-missing/"
    fi
    if ! cp -a -- "$source/." "$copy_dest"; then
        err "failed to copy the source tree into the release staging directory"
        rm -rf -- "$stage"
        return 1
    fi
    if fault_armed release-validate; then
        rm -f -- "$stage/version.json"
    fi
    if ! manager_validate_source "$stage"; then
        err "the staged release failed validation"
        rm -rf -- "$stage"
        return 1
    fi
    release_dir="${SB_RELEASES_DIR}/${release_id}"
    if fault_armed release-final-mv; then
        mkdir -p -- "$release_dir" && : >"${release_dir}/.occupied"
    fi
    if ! mv -T -- "$stage" "$release_dir"; then
        err "failed to publish the staged release: $release_dir"
        rm -rf -- "$stage"
        return 1
    fi
    SB_MANAGER_INSTALLED_RELEASE="$release_dir"
    export SB_MANAGER_INSTALLED_RELEASE

    if [[ -L "$SB_APP_LINK" ]]; then
        previous_link=$(readlink -- "$SB_APP_LINK") || previous_link=""
    elif [[ -e "$SB_APP_LINK" ]]; then
        err "$SB_APP_LINK exists and is not a managed symlink; refusing replacement"
        rm -rf -- "$release_dir"
        SB_MANAGER_INSTALLED_RELEASE=""
        export SB_MANAGER_INSTALLED_RELEASE
        return 1
    fi

    # Refuse before the app link moves, so a conflicting command path never
    # leaves a half-installed manager behind.
    if manager_command_link_conflict; then
        rm -rf -- "$release_dir"
        SB_MANAGER_INSTALLED_RELEASE=""
        export SB_MANAGER_INSTALLED_RELEASE
        return 1
    fi

    if ! symlink_switch "releases/${release_id}" "$SB_APP_LINK" \
      "${SB_INSTALL_ROOT}/.app.new.$$" app-new; then
        err "failed to switch the application link; the previous release stays live"
        rm -rf -- "$release_dir"
        SB_MANAGER_INSTALLED_RELEASE=""
        export SB_MANAGER_INSTALLED_RELEASE
        return 1
    fi

    if fault_armed app-selfcheck ||
      ! env -u SB_APP_DIR "$SB_APP_LINK/sb" self-check >/dev/null; then
        manager_rollback_app "$previous_link" "$release_dir" \
          "new manager self-check failed"
        rollback_rc=$?
        SB_MANAGER_INSTALLED_RELEASE=""
        export SB_MANAGER_INSTALLED_RELEASE
        return "$rollback_rc"
    fi

    if ! safe_mkdir "$(dirname "$SB_COMMAND_LINK")" 755; then
        manager_rollback_app "$previous_link" "$release_dir" \
          "failed to create the management command directory"
        rollback_rc=$?
        SB_MANAGER_INSTALLED_RELEASE=""
        export SB_MANAGER_INSTALLED_RELEASE
        return "$rollback_rc"
    fi

    # Stage the command link beside its target and rename it into place so a
    # failure can never leave a dangling /usr/local/bin/sb behind.
    if ! symlink_switch "${SB_APP_LINK}/sb" "$SB_COMMAND_LINK" \
      "${SB_COMMAND_LINK}.new.$$" cli-link; then
        manager_rollback_app "$previous_link" "$release_dir" \
          "failed to create the management command link"
        rollback_rc=$?
        SB_MANAGER_INSTALLED_RELEASE=""
        export SB_MANAGER_INSTALLED_RELEASE
        return "$rollback_rc"
    fi
    ok "sb manager installed: $release_dir"
}
