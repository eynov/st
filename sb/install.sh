#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YES=false
ENDPOINT=""
ALLOW_PRIVATE=false
LISTEN_MODE=""

while (($#)); do
    case "$1" in
        --source) (($# >= 2)) || { printf 'ERROR: --source requires a value\n' >&2; exit 64; }
            SOURCE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --endpoint) (($# >= 2)) || { printf 'ERROR: --endpoint requires a value\n' >&2; exit 64; }
            ENDPOINT="$2"; shift 2 ;;
        --listen-mode) (($# >= 2)) || { printf 'ERROR: --listen-mode requires a value\n' >&2; exit 64; }
            LISTEN_MODE="$2"; shift 2 ;;
        --allow-private-endpoint) ALLOW_PRIVATE=true; shift ;;
        --yes) YES=true; shift ;;
        *) printf 'ERROR: unknown install option: %s\n' "$1" >&2; exit 64 ;;
    esac
done

[[ $EUID -eq 0 || "${SB_TEST_MODE:-false}" == "true" ]] || {
    printf 'ERROR: installation requires root\n' >&2
    exit 1
}

export SB_YES="$YES"
# shellcheck source=core/common.sh
source "$SOURCE_DIR/core/common.sh"
# shellcheck source=core/manager.sh
source "$SOURCE_DIR/core/manager.sh"

PREVIOUS_APP_LINK=""
PREVIOUS_COMMAND_LINK=""
PREVIOUS_COMMAND_EXISTS=false
PREVIOUS_UNIT=""
PREVIOUS_UNIT_EXISTS=false

# Put the systemd unit back the way this run found it.
#
# sb install regenerates the unit before the service is verified, and the unit
# it writes points ExecCondition at ${SB_APP_LINK}/sb. Rolling the application
# link back and deleting the release without restoring the unit leaves a unit
# referencing a path that no longer exists: the service keeps running from
# memory, and then fails to start on the next restart or reboot. The rollback is
# only complete once the unit matches the manager it points at again.
restore_previous_unit() {
    if [[ "$PREVIOUS_UNIT_EXISTS" == "true" ]]; then
        cp -- "$PREVIOUS_UNIT" "$SB_SERVICE_FILE" || return 1
        chmod 644 "$SB_SERVICE_FILE" || return 1
    elif [[ -e "$SB_SERVICE_FILE" ]]; then
        rm -f -- "$SB_SERVICE_FILE" || return 1
    else
        return 0
    fi
    # The dangerous state - a unit referencing the release that is about to be
    # deleted - is gone as soon as the file itself is right. A daemon-reload
    # that cannot run (systemd unavailable) must not abort the rest of the
    # rollback: systemd re-reads the unit on its next reload or boot anyway.
    "${SB_SYSTEMCTL:-systemctl}" daemon-reload ||
        printf 'WARNING: daemon-reload failed after restoring %s\n' \
          "$SB_SERVICE_FILE" >&2
    return 0
}

install_all() {
    [[ -L "$SB_APP_LINK" ]] && PREVIOUS_APP_LINK=$(readlink "$SB_APP_LINK")
    if [[ -f "$SB_SERVICE_FILE" ]]; then
        PREVIOUS_UNIT=$(mktemp) || return 1
        # install_all runs inside the with_exclusive_lock subshell, so this trap
        # fires on every exit path of this run and leaves no stray copy behind.
        trap 'rm -f -- "${PREVIOUS_UNIT:-}"' EXIT
        cp -- "$SB_SERVICE_FILE" "$PREVIOUS_UNIT" || return 1
        PREVIOUS_UNIT_EXISTS=true
    fi
    if [[ -L "$SB_COMMAND_LINK" ]]; then
        PREVIOUS_COMMAND_LINK=$(readlink "$SB_COMMAND_LINK")
        PREVIOUS_COMMAND_EXISTS=true
    elif [[ -e "$SB_COMMAND_LINK" ]]; then
        PREVIOUS_COMMAND_EXISTS=true
    fi
    manager_install_source "$SOURCE_DIR" || return $?

    args=(install)
    [[ "$YES" == "true" ]] && args+=(--yes)
    [[ -n "$ENDPOINT" ]] && args+=(--endpoint "$ENDPOINT")
    [[ -n "$LISTEN_MODE" ]] && args+=(--listen-mode "$LISTEN_MODE")
    [[ "$ALLOW_PRIVATE" == "true" ]] && args+=(--allow-private-endpoint)
    local install_rc=0
    env -u SB_APP_DIR "$SB_APP_LINK/sb" "${args[@]}" || install_rc=$?
    # A legacy migration that stopped for a missing endpoint is the one failure
    # that must not roll the application switch back. Nothing was migrated, and
    # only the manager installed just now understands the option that supplies
    # the endpoint - discarding it here is what traps the host in a retry loop.
    if ((install_rc == SB_EX_MIGRATION_INPUT)); then
        printf 'ERROR: legacy migration needs an endpoint; nothing was migrated\n' >&2
        printf 'the new manager is installed and the legacy install is unchanged\n' >&2
        printf 'complete it with: %s install --endpoint <domain-or-public-ip> --yes\n' \
          "$SB_COMMAND_LINK" >&2
        return "$SB_EX_MIGRATION_INPUT"
    fi
    if ((install_rc != 0)); then
        if [[ -n "$PREVIOUS_APP_LINK" ]]; then
            symlink_switch "$PREVIOUS_APP_LINK" "$SB_APP_LINK" \
              "${SB_INSTALL_ROOT}/.app.install-rollback.$$" || {
                printf 'CRITICAL: the application link could not be restored\n' >&2
                printf 'manual recovery: point %s at %s\n' \
                  "$SB_APP_LINK" "$PREVIOUS_APP_LINK" >&2
                return 70
            }
        else
            rm -f "$SB_APP_LINK"
        fi
        if [[ -n "$PREVIOUS_COMMAND_LINK" ]]; then
            symlink_switch "$PREVIOUS_COMMAND_LINK" "$SB_COMMAND_LINK" \
              "${SB_COMMAND_LINK}.rollback.$$" || {
                printf 'CRITICAL: the management command link could not be restored\n' >&2
                return 70
            }
        elif [[ "$PREVIOUS_COMMAND_EXISTS" == "false" &&
                -L "$SB_COMMAND_LINK" &&
                "$(readlink "$SB_COMMAND_LINK")" == "$SB_APP_LINK/sb" ]]; then
            rm -f -- "$SB_COMMAND_LINK"
        fi
        restore_previous_unit || {
            printf 'CRITICAL: the systemd unit could not be restored: %s\n' \
              "$SB_SERVICE_FILE" >&2
            printf 'manual recovery: restore it from the pre-migration backup under %s\n' \
              "$SB_BACKUP_DIR" >&2
            return 70
        }
        [[ -z "${SB_MANAGER_INSTALLED_RELEASE:-}" ]] ||
            rm -rf -- "$SB_MANAGER_INSTALLED_RELEASE"
        printf 'ERROR: sb initialization failed; application link rolled back\n' >&2
        return 1
    fi
}

with_exclusive_lock install_all
