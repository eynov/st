#!/usr/bin/env bash
# shellcheck disable=SC2034 # Constants are consumed by scripts that source this library.

# Shared constants and side-effect free helpers.
# Every executable entry point must source this file before creating files.

umask 077

SB_PROJECT_VERSION="3.0.0"
SB_STATE_SCHEMA_VERSION=2
SB_SETTINGS_SCHEMA_VERSION=2
SB_CONFIG_SCHEMA_VERSION=1
SB_CORE_VERSION="1.13.15"
SB_CHECKSUMS_SHA256="cf75aaa33c37224a0f6c4759dec1036bc946f73d4a50e89dd85131c73c775063"

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

# Salvage mode relaxes backup validation and must never be reachable from the
# environment: an operator who exported it would silently lose the validated
# safety net on every ordinary command. Any inherited value is discarded here,
# before any command runs, and internal callers opt in by passing the
# per-process marker below, which cannot be guessed or injected.
unset SB_TXN_SALVAGE_BACKUP
SB_INTERNAL_MARKER="internal-$$-${RANDOM}${RANDOM}${RANDOM}"

# Operator-facing acknowledgement for restoring an unvalidated salvage snapshot.
#
# Deliberately NOT read from the environment. An exported value would authorise
# every later salvage restore in the same shell session and in every child sb
# process, turning a one-off decision into a standing permission. The
# acknowledgement must be typed on the invocation that performs the restore, so
# any inherited value is discarded here and only --restore-unvalidated-salvage
# can set it.
SB_ALLOW_SALVAGE_RESTORE=false

# Exit code reserved for failures that left the installation in a state the
# manager could not restore on its own. Operators must intervene.
SB_EX_UNRECOVERABLE=70
# Exit code reserved for global lock contention (EX_TEMPFAIL).
SB_EX_TEMPFAIL=75
# Exit code reserved for a legacy migration that stopped before changing
# anything because a required input could not be derived from the old install
# (EX_CONFIG). It is the one install failure the installer must NOT roll the
# application switch back for: the new manager is the only program that can
# accept the missing input, so discarding it would strand the host in a
# bootstrap loop. Nothing has been migrated when this code is returned.
SB_EX_MIGRATION_INPUT=78

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
    # The rightmost label of a hostname must not be all-numeric (RFC 1123 2.1).
    # Enforcing this also closes a bypass: a malformed dotted quad such as
    # 010.0.0.1 fails ipv4_valid, and without this rule it would fall through to
    # the domain branch and be accepted as a name.
    [[ "${value##*.}" =~ ^[0-9]+$ ]] && return 1
    [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

ipv4_valid() {
    local ip="${1:-}" a b c d
    IFS=. read -r a b c d <<<"$ip"
    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
    local octet
    for octet in "$a" "$b" "$c" "$d"; do
        # Reject leading zeros. "010" is octal to some resolvers and decimal to
        # others, so the address that gets validated here would not be the
        # address a client dials from the stored literal.
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( octet <= 255 )) || return 1
    done
}

# IPv4 prefixes that must never be published as a public endpoint.
#
# This is the IANA IPv4 Special-Purpose Address Registry plus the ranges that
# are globally routable but still unusable as a node endpoint (multicast and
# the reserved 240/4 space). Entries are "network/prefix-length"; the table is
# deliberately explicit rather than a hand-tuned approximation, because the
# previous octet heuristics silently accepted several special-purpose ranges.
SB_IPV4_SPECIAL_PURPOSE=(
    0.0.0.0/8            # "this network"
    10.0.0.0/8           # private
    100.64.0.0/10        # CGNAT / shared address space
    127.0.0.0/8          # loopback
    169.254.0.0/16       # link-local
    172.16.0.0/12        # private
    192.0.0.0/24         # IETF protocol assignments
    192.0.2.0/24         # documentation TEST-NET-1
    192.31.196.0/24      # AS112-v4
    192.52.193.0/24      # AMT
    192.88.99.0/24       # deprecated 6to4 relay anycast
    192.168.0.0/16       # private
    192.175.48.0/24      # direct delegation AS112 service
    198.18.0.0/15        # benchmarking
    198.51.100.0/24      # documentation TEST-NET-2
    203.0.113.0/24       # documentation TEST-NET-3
    224.0.0.0/4          # multicast
    240.0.0.0/4          # reserved, includes 255.255.255.255
)

ipv4_to_int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    printf '%s\n' $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

ipv4_nonpublic() {
    local ip="$1" entry network bits value network_value mask
    value=$(ipv4_to_int "$ip") || return 1
    for entry in "${SB_IPV4_SPECIAL_PURPOSE[@]}"; do
        network="${entry%%/*}"
        bits="${entry##*/}"
        network_value=$(ipv4_to_int "$network") || return 1
        mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
        (( (value & mask) == (network_value & mask) )) && return 0
    done
    return 1
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

# IPv6 prefixes that must never be published as a public endpoint.
#
# This mirrors the IANA IPv6 Special-Purpose Address Registry. Several entries
# are not aligned to a nibble boundary (2001::/23, fc00::/7, fe80::/10), so
# membership is decided by an explicit bit comparison instead of a string
# prefix test. Testing 2001::/23 in one entry covers IETF protocol assignments,
# TEREDO, benchmarking and ORCHIDv2 without enumerating each sub-allocation.
SB_IPV6_SPECIAL_PURPOSE=(
    ::/128               # unspecified
    ::1/128              # loopback
    ::ffff:0:0/96        # IPv4-mapped
    64:ff9b::/96         # IPv4-IPv6 translation
    64:ff9b:1::/48       # local-use IPv4-IPv6 translation
    100::/64             # discard-only
    2001::/23            # IETF protocol assignments, TEREDO, benchmarking, ORCHIDv2
    2001:db8::/32        # documentation
    2002::/16            # deprecated 6to4
    3fff::/20            # documentation (RFC 9637)
    5f00::/16            # segment routing SIDs
    fc00::/7             # unique-local
    fe80::/10            # link-local unicast
    ff00::/8             # multicast
)

# Expand an IPv6 address to its full 32 lowercase hex nibbles.
ipv6_expand() {
    local ip="${1,,}" left right part index
    local -a left_parts=() right_parts=() all_parts=()
    if [[ "$ip" == *"::"* ]]; then
        left="${ip%%::*}"
        right="${ip#*::}"
        [[ -z "$left" ]] || IFS=: read -r -a left_parts <<<"$left"
        [[ -z "$right" ]] || IFS=: read -r -a right_parts <<<"$right"
        all_parts=("${left_parts[@]}")
        for ((index = ${#left_parts[@]} + ${#right_parts[@]}; index < 8; index++)); do
            all_parts+=("0")
        done
        all_parts+=("${right_parts[@]}")
    else
        IFS=: read -r -a all_parts <<<"$ip"
    fi
    ((${#all_parts[@]} == 8)) || return 1
    for part in "${all_parts[@]}"; do
        printf '%04x' "$((16#${part:-0}))" || return 1
    done
    printf '\n'
}

# Compare two expanded IPv6 addresses over an arbitrary bit length.
ipv6_prefix_matches() {
    local addr="$1" network="$2" bits="$3" whole remainder mask
    whole=$((bits / 4))
    remainder=$((bits % 4))
    [[ "${addr:0:whole}" == "${network:0:whole}" ]] || return 1
    ((remainder == 0)) && return 0
    mask=$(( (0xF << (4 - remainder)) & 0xF ))
    (( (16#${addr:whole:1} & mask) == (16#${network:whole:1} & mask) ))
}

ipv6_nonpublic() {
    local ip="$1" entry network bits expanded expanded_network
    expanded=$(ipv6_expand "$ip") || return 0
    for entry in "${SB_IPV6_SPECIAL_PURPOSE[@]}"; do
        network="${entry%%/*}"
        bits="${entry##*/}"
        expanded_network=$(ipv6_expand "$network") || continue
        ipv6_prefix_matches "$expanded" "$expanded_network" "$bits" && return 0
    done
    # Anything outside 2000::/3 is not currently allocated as global unicast.
    ipv6_prefix_matches "$expanded" "$(ipv6_expand 2000::)" 3 || return 0
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

# Resolution policy for domain endpoints: every A/AAAA record must itself be a
# usable public endpoint. Requiring only "at least one" global answer would let
# a client silently pick a special-purpose address from a mixed result set, so a
# mixed answer is rejected outright rather than filtered. A resolution failure
# is also an error, which keeps unresolvable names out of live settings.
endpoint_domain_resolves_global() {
    local value="$1" allow_nonpublic="${2:-false}" address found=false
    [[ "${SB_SKIP_DNS_VALIDATION:-false}" != "true" ]] || return 0
    while IFS= read -r address; do
        [[ -n "$address" ]] || continue
        found=true
        endpoint_valid "$address" "$allow_nonpublic" || {
            err "endpoint domain resolves to a special-purpose address: $value -> $address"
            err "every resolved address must be publicly reachable; fix DNS or pass --allow-private-endpoint"
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
    if ! mkdir -p -- "$path"; then
        err "failed to create directory: $path"
        return 1
    fi
    if ! chmod "$mode" -- "$path"; then
        err "failed to set mode ${mode} on directory: $path"
        return 1
    fi
}

# Test-only fault injection.
#
# Callers arm a fault by naming it in the colon-separated SB_TEST_FAULTS list.
# Faults are ignored unless SB_TEST_MODE is true, so production paths can never
# take an injected branch. Injection never fakes a return code: it perturbs the
# filesystem so the real command fails with a real errno. That keeps the fault
# tests honest about which command actually failed.
fault_armed() {
    [[ "${SB_TEST_MODE:-false}" == "true" ]] || return 1
    case ":${SB_TEST_FAULTS:-}:" in
        *":$1:"*) return 0 ;;
    esac
    return 1
}

# Atomically repoint a symlink, checking every step explicitly.
#
# Usage: symlink_switch <target> <link> <staging> [fault_prefix]
#
# Callers must not depend on errexit: this function is routinely invoked from
# if/||/&& conditional contexts where errexit is disabled inside the callee, so
# each of rm, ln and mv propagates its own failure.
symlink_switch() {
    local target="$1" link="$2" staging="$3" fault="${4:-}"
    local create_path
    create_path="$staging"
    if ! rm -f -- "$staging"; then
        err "failed to clear the staging symlink path: $staging"
        return 1
    fi
    # Redirect creation into a directory that does not exist so ln(1) fails with
    # a genuine ENOENT rather than a simulated status.
    if [[ -n "$fault" ]] && fault_armed "${fault}-create"; then
        create_path="${staging%/*}/.sb-fault-missing/${staging##*/}"
    fi
    if ! ln -s -- "$target" "$create_path"; then
        err "failed to create the staging symlink: $create_path"
        return 1
    fi
    # Remove the staged symlink so the rename below fails for real.
    if [[ -n "$fault" ]] && fault_armed "${fault}-switch"; then
        rm -f -- "$staging"
    fi
    if ! mv -fT -- "$staging" "$link"; then
        err "failed to atomically switch the symlink: $link"
        rm -f -- "$staging"
        return 1
    fi
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
    safe_mkdir "$(dirname "$target")" || return 1
    tmp=$(mktemp "${target}.tmp.XXXXXX") || {
        err "failed to create a temporary file next to: $target"
        return 1
    }
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
