#!/usr/bin/env bash
# shellcheck disable=SC2034 # Registry arrays are consumed by separately sourced modules.

declare -a PROTO_KEYS=()
declare -A PROTO_LABEL=()
declare -A PROTO_TRANSPORT=()
declare -A PROTO_CREATE=()
declare -A PROTO_EDIT=()
declare -A PROTO_VALIDATE=()
declare -A PROTO_INBOUND=()
declare -A PROTO_URI=()
declare -A PROTO_SURGE=()
declare -A PROTO_CLASH=()
declare -A PROTO_OUTBOUND=()
declare -A PROTO_FIREWALL=()
declare -A PROTO_EXPECTED=()

# key label transport create edit validate inbound uri surge clash outbound firewall expected
proto_register() {
    local key="$1" label="$2" transport="$3"
    PROTO_KEYS+=("$key")
    PROTO_LABEL["$key"]="$label"
    PROTO_TRANSPORT["$key"]="$transport"
    PROTO_CREATE["$key"]="$4"
    PROTO_EDIT["$key"]="$5"
    PROTO_VALIDATE["$key"]="$6"
    PROTO_INBOUND["$key"]="$7"
    PROTO_URI["$key"]="$8"
    PROTO_SURGE["$key"]="$9"
    PROTO_CLASH["$key"]="${10}"
    PROTO_OUTBOUND["$key"]="${11}"
    PROTO_FIREWALL["$key"]="${12}"
    PROTO_EXPECTED["$key"]="${13}"
}

load_protocols() {
    [[ "${SB_PROTOCOLS_LOADED:-false}" == "true" ]] && return 0
    SB_PROTOCOLS_LOADED=true
    local file
    for file in "$SB_APP_DIR"/protocols/*.sh; do
        [[ -f "$file" ]] || continue
        # shellcheck source=/dev/null
        source "$file"
    done
    ((${#PROTO_KEYS[@]} > 0))
}

proto_exists() {
    [[ -n "${PROTO_VALIDATE[${1^^}]+x}" ]]
}
