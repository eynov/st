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
install_all() {
    [[ -L "$SB_APP_LINK" ]] && PREVIOUS_APP_LINK=$(readlink "$SB_APP_LINK")
    if [[ -L "$SB_COMMAND_LINK" ]]; then
        PREVIOUS_COMMAND_LINK=$(readlink "$SB_COMMAND_LINK")
        PREVIOUS_COMMAND_EXISTS=true
    elif [[ -e "$SB_COMMAND_LINK" ]]; then
        PREVIOUS_COMMAND_EXISTS=true
    fi
    manager_install_source "$SOURCE_DIR"

    args=(install)
    [[ "$YES" == "true" ]] && args+=(--yes)
    [[ -n "$ENDPOINT" ]] && args+=(--endpoint "$ENDPOINT")
    [[ -n "$LISTEN_MODE" ]] && args+=(--listen-mode "$LISTEN_MODE")
    [[ "$ALLOW_PRIVATE" == "true" ]] && args+=(--allow-private-endpoint)
    if ! env -u SB_APP_DIR "$SB_APP_LINK/sb" "${args[@]}"; then
        if [[ -n "$PREVIOUS_APP_LINK" ]]; then
            ln -s "$PREVIOUS_APP_LINK" "${SB_INSTALL_ROOT}/.app.install-rollback.$$"
            mv -fT "${SB_INSTALL_ROOT}/.app.install-rollback.$$" "$SB_APP_LINK"
        else
            rm -f "$SB_APP_LINK"
        fi
        if [[ -n "$PREVIOUS_COMMAND_LINK" ]]; then
            ln -sfn "$PREVIOUS_COMMAND_LINK" "$SB_COMMAND_LINK"
        elif [[ "$PREVIOUS_COMMAND_EXISTS" == "false" &&
                -L "$SB_COMMAND_LINK" &&
                "$(readlink "$SB_COMMAND_LINK")" == "$SB_APP_LINK/sb" ]]; then
            rm -f -- "$SB_COMMAND_LINK"
        fi
        [[ -z "${SB_MANAGER_INSTALLED_RELEASE:-}" ]] ||
            rm -rf -- "$SB_MANAGER_INSTALLED_RELEASE"
        printf 'ERROR: sb initialization failed; application link rolled back\n' >&2
        return 1
    fi
}

with_exclusive_lock install_all
