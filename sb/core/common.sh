#!/usr/bin/env bash
# shellcheck disable=SC2034 # Constants are consumed by scripts that source this library.

# Shared constants and side-effect free helpers.
# Every executable entry point must source this file before creating files.

umask 077

SB_PROJECT_VERSION="3.0.0"
SB_STATE_SCHEMA_VERSION=2
SB_SETTINGS_SCHEMA_VERSION=2
SB_CONFIG_SCHEMA_VERSION=1
SB_CORE_VERSION="1.13.14"
SB_CHECKSUMS_SHA256="d05be2ebf7dd93d691c82f5d04b0ed239abe0baeac8ad6773e6a957ef5c90103"

SB_APP_DIR="${SB_APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SB_CONFIG_DIR="${SB_CONFIG_DIR:-/etc/sb}"
SB_DATA_DIR="${SB_DATA_DIR:-/var/lib/sb}"
SB_CERT_DIR="${SB_CERT_DIR:-${SB_DATA_DIR}/certs}"
SB_GENERATIONS_DIR="${SB_GENERATIONS_DIR:-${SB_DATA_DIR}/generations}"
SB_CURRENT_LINK="${SB_CURRENT_LINK:-${SB_DATA_DIR}/current}"
SB_SETTINGS_LINK="${SB_SETTINGS_LINK:-${SB_CONFIG_DIR}/settings.json}"
SB_SETTINGS_BOOTSTRAP="${SB_SETTINGS_BOOTSTRAP:-${SB_CONFIG_DIR}/settings.bootstrap.json}"
SB_SETTINGS_FILE="${SB_CURRENT_LINK}/settings.json"
SB_STATUS_FILE="${SB_STATUS_FILE:-${SB_DATA_DIR}/status.json}"
SB_CORE_RECEIPT="${SB_CORE_RECEIPT:-${SB_DATA_DIR}/core.json}"
SB_BACKUP_DIR="${SB_BACKUP_DIR:-/var/backups/sb}"
SB_LOCK_DIR="${SB_LOCK_DIR:-/run/lock/sb}"
SB_LOCK_FILE="${SB_LOCK_FILE:-${SB_LOCK_DIR}/manager.lock}"
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
SB_SERVICE="${SB_SERVICE:-sb-core}"
SB_SERVICE_FILE="${SB_SERVICE_FILE:-/etc/systemd/system/${SB_SERVICE}.service}"
SB_SYSTEMCTL="${SB_SYSTEMCTL:-systemctl}"
SB_JOURNALCTL="${SB_JOURNALCTL:-journalctl}"
SB_LEGACY_DIR="${SB_LEGACY_DIR:-/opt/sb}"

SB_CURRENT_STATE="${SB_CURRENT_LINK}/instances.json"
SB_CURRENT_OUTPUT="${SB_CURRENT_LINK}/output"
SB_CURRENT_CONFIG="${SB_CURRENT_OUTPUT}/config.json"
SB_CURRENT_CLIENTS="${SB_CURRENT_OUTPUT}/clients"

SB_JSON="${SB_JSON:-false}"
SB_YES="${SB_YES:-false}"
SB_DRY_RUN="${SB_DRY_RUN:-false}"
SB_SHOW_SECRETS="${SB_SHOW_SECRETS:-false}"

ok() {
    if [[ "$SB_JSON" == "true" ]]; then printf 'OK: %s\n' "$*" >&2
    else printf 'OK: %s\n' "$*"; fi
}
info() {
    if [[ "$SB_JSON" == "true" ]]; then printf 'INFO: %s\n' "$*" >&2
    else printf 'INFO: %s\n' "$*"; fi
}
warn() { printf 'WARN: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

die() {
    err "$*"
    return 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

now_iso() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

new_generation_id() {
    printf '%s-%s-%s\n' "$(date -u '+%Y%m%dT%H%M%S')" "$$" "$(openssl rand -hex 4)"
}

port_valid() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

domain_valid() {
    local value="${1:-}"
    [[ ${#value} -le 253 ]] || return 1
    [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

ipv4_valid() {
    local ip="${1:-}" a b c d
    IFS=. read -r a b c d <<<"$ip"
    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
    local octet
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( octet >= 0 && octet <= 255 )) || return 1
    done
}

ipv4_nonpublic() {
    local ip="$1" a b _c _d
    IFS=. read -r a b _c _d <<<"$ip"
    (( a == 0 || a == 10 || a == 127 || a >= 224 ||
       (a == 100 && b >= 64 && b <= 127) ||
       (a == 169 && b == 254) ||
       (a == 172 && b >= 16 && b <= 31) ||
       (a == 192 && (b == 0 || b == 168)) ||
       (a == 192 && b == 0 && _c == 2) ||
       (a == 198 && (b == 18 || b == 19)) ||
       (a == 198 && b == 51 && _c == 100) ||
       (a == 203 && b == 0 && _c == 113) ))
}

ipv6_valid() {
    local ip="${1:-}" left right part
    local -a left_parts=() right_parts=() all_parts=()
    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    if [[ "$ip" == *"::"* ]]; then
        [[ "${ip#*::}" != *"::"* ]] || return 1
        left="${ip%%::*}"
        right="${ip#*::}"
        [[ -z "$left" ]] || IFS=: read -r -a left_parts <<<"$left"
        [[ -z "$right" ]] || IFS=: read -r -a right_parts <<<"$right"
        ((${#left_parts[@]} + ${#right_parts[@]} < 8)) || return 1
        all_parts=("${left_parts[@]}" "${right_parts[@]}")
    else
        IFS=: read -r -a all_parts <<<"$ip"
        ((${#all_parts[@]} == 8)) || return 1
    fi
    for part in "${all_parts[@]}"; do
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
}

ipv6_nonpublic() {
    local ip="${1,,}" first
    [[ "$ip" == "::" || "$ip" == "::1" ]] && return 0
    [[ "$ip" == 2001:db8:* || "$ip" == 2001:db8::* ]] && return 0
    first="${ip%%:*}"
    [[ "$first" =~ ^f[c-d][0-9a-f]{2}$ ]] && return 0
    [[ "$first" =~ ^fe[89ab][0-9a-f]$ ]] && return 0
    [[ "$first" =~ ^ff[0-9a-f]{2}$ ]] && return 0
    [[ "$first" =~ ^[23][0-9a-f]{3}$ ]] || return 0
    return 1
}

endpoint_valid() {
    local value="${1:-}" allow_private="${2:-false}"
    if ipv4_valid "$value"; then
        [[ "$allow_private" == "true" ]] || ! ipv4_nonpublic "$value"
        return
    fi
    if ipv6_valid "$value"; then
        [[ "$allow_private" == "true" ]] || ! ipv6_nonpublic "$value"
        return
    fi
    domain_valid "$value"
}

endpoint_domain_resolves_global() {
    local value="$1" allow_nonpublic="${2:-false}" address found=false
    [[ "${SB_SKIP_DNS_VALIDATION:-false}" != "true" ]] || return 0
    while IFS= read -r address; do
        [[ -n "$address" ]] || continue
        found=true
        endpoint_valid "$address" "$allow_nonpublic" || {
            err "endpoint domain resolves to a non-global address: $value -> $address"
            return 1
        }
    done < <("${SB_GETENT:-getent}" ahosts "$value" 2>/dev/null |
        awk '{print $1}' | sort -u)
    [[ "$found" == "true" ]] || {
        err "endpoint domain did not resolve: $value"
        return 1
    }
}

endpoint_host() {
    local value="$1"
    if ipv6_valid "$value"; then
        printf '[%s]' "$value"
    else
        printf '%s' "$value"
    fi
}

urlencode() {
    local LC_ALL=C raw="$1" length i c
    length="${#raw}"
    for ((i = 0; i < length; i++)); do
        c="${raw:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

base64_urlsafe() {
    base64 | tr -d '\n=' | tr '+/' '-_'
}

redact() {
    local value="${1:-}"
    if [[ "$SB_SHOW_SECRETS" == "true" ]]; then
        printf '%s' "$value"
    elif ((${#value} <= 8)); then
        printf '[REDACTED]'
    else
        printf '%s…%s' "${value:0:4}" "${value: -4}"
    fi
}

confirm() {
    local prompt="$1" reply
    [[ "$SB_YES" == "true" ]] && return 0
    [[ -t 0 ]] || die "${prompt}; rerun with --yes for non-interactive use"
    read -r -p "${prompt} [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

safe_mkdir() {
    local path="$1" mode="${2:-700}"
    mkdir -p -- "$path"
    chmod "$mode" -- "$path"
}

lock_is_inherited() {
    [[ "${SB_LOCK_HELD:-false}" == "true" &&
       "${SB_LOCK_FD:-}" =~ ^[0-9]+$ &&
       -e "/proc/self/fd/${SB_LOCK_FD}" ]] || return 1
    [[ "$(readlink -f "/proc/self/fd/${SB_LOCK_FD}")" == "$(readlink -f "$SB_LOCK_FILE")" ]]
}

with_exclusive_lock() (
    if lock_is_inherited; then
        "$@"
        return
    fi
    safe_mkdir "$SB_LOCK_DIR"
    SB_LOCK_FD=9
    exec 9>"$SB_LOCK_FILE"
    flock -n "$SB_LOCK_FD" || {
        err "another sb operation holds the exclusive lock"
        return 75
    }
    SB_LOCK_HELD=true
    export SB_LOCK_FD SB_LOCK_HELD
    "$@"
)

atomic_write() {
    local target="$1" mode="${2:-600}" tmp
    safe_mkdir "$(dirname "$target")"
    tmp=$(mktemp "${target}.tmp.XXXXXX")
    if ! cat >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod "$mode" "$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    mv -fT -- "$tmp" "$target" || {
        rm -f -- "$tmp"
        return 1
    }
}

json_file_valid() {
    jq -e . "$1" >/dev/null 2>&1
}

yaml_scalar_quote() {
    jq -Rn --arg value "$1" '$value'
}
