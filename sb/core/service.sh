#!/usr/bin/env bash

SB_SS="${SB_SS:-ss}"

service_generate_unit() (
    local tmp=""
    trap '[[ -z "$tmp" ]] || rm -f -- "$tmp"' EXIT
    safe_mkdir "$(dirname "$SB_SERVICE_FILE")" 755
    tmp=$(mktemp "${SB_SERVICE_FILE}.tmp.XXXXXX")
    {
        printf '%s\n' \
            '[Unit]' \
            'Description=sb managed sing-box service' \
            'Documentation=file:///opt/sb/app/README.md' \
            'After=network-online.target' \
            'Wants=network-online.target' \
            '' \
            '[Service]' \
            'Type=simple' \
            "WorkingDirectory=${SB_CURRENT_OUTPUT}" \
            "ExecCondition=${SB_APP_LINK:-/opt/sb/app}/sb internal should-run" \
            "ExecStartPre=${SB_BIN} check -c ${SB_CURRENT_CONFIG}" \
            "ExecStart=${SB_BIN} run -c ${SB_CURRENT_CONFIG}" \
            'ExecReload=/bin/kill -HUP $MAINPID' \
            'Restart=on-failure' \
            'RestartSec=5s' \
            'UMask=0077' \
            'LimitNOFILE=1048576' \
            'NoNewPrivileges=true' \
            'PrivateTmp=true' \
            'ProtectHome=true' \
            'ProtectSystem=strict' \
            'ProtectKernelTunables=true' \
            'ProtectKernelModules=true' \
            'ProtectControlGroups=true' \
            'RestrictSUIDSGID=true' \
            'LockPersonality=true' \
            'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' \
            'AmbientCapabilities=CAP_NET_BIND_SERVICE' \
            '' \
            '[Install]' \
            'WantedBy=multi-user.target'
    } >"$tmp"
    chmod 644 "$tmp" || return 1
    mv -fT "$tmp" "$SB_SERVICE_FILE" || {
        err "failed to install the systemd unit: $SB_SERVICE_FILE"
        return 1
    }
    tmp=""
    "$SB_SYSTEMCTL" daemon-reload || return 1
    "$SB_SYSTEMCTL" enable "$SB_SERVICE" >/dev/null || return 1
)

service_is_active() {
    "$SB_SYSTEMCTL" is-active --quiet "$SB_SERVICE"
}

service_is_enabled() {
    "$SB_SYSTEMCTL" is-enabled --quiet "$SB_SERVICE"
}

service_start() {
    runtime_check_config "$SB_CURRENT_CONFIG" || return 1
    "$SB_SYSTEMCTL" start "$SB_SERVICE" || return 1
    service_is_active || {
        err "$SB_SERVICE did not become active"
        return 1
    }
}

service_stop() {
    if service_is_active; then
        "$SB_SYSTEMCTL" stop "$SB_SERVICE" || return 1
    fi
    ! service_is_active
}

service_apply() {
    runtime_check_config "$SB_CURRENT_CONFIG" || return 1
    # A successful signal delivery does not prove that sing-box accepted a new
    # generation. Restarting gives us a new PID whose cwd can be tied to the
    # resolved current generation, which is independently verifiable.
    if service_is_active; then
        "$SB_SYSTEMCTL" restart "$SB_SERVICE" || return 1
    else
        "$SB_SYSTEMCTL" start "$SB_SERVICE" || return 1
    fi
    service_is_active || {
        err "$SB_SERVICE is inactive after apply"
        return 1
    }
}

service_restart() {
    runtime_check_config "$SB_CURRENT_CONFIG" || return 1
    "$SB_SYSTEMCTL" restart "$SB_SERVICE" || return 1
    service_is_active
}

service_verify_listeners() {
    local manifest="${1:-${SB_CURRENT_OUTPUT}/manifest.json}" network port address pid line
    [[ -f "$manifest" ]] || return 1
    service_is_active || return 1
    pid=$(service_pid)
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || {
        err "sb-core MainPID is invalid: $pid"
        return 1
    }
    service_pid_belongs "$pid" || {
        err "MainPID $pid does not belong to $SB_SERVICE"
        return 1
    }
    service_generation_loaded "$pid" || return 1
    address=$(jq -er '.listen.address' "$manifest") || return 1
    while IFS=$'\t' read -r network port; do
        line=$(service_socket_line "$network" "$port" "$pid") || {
            err "expected ${network^^} listener owned by PID $pid is missing: $port"
            return 1
        }
        service_listener_address_matches "$line" "$address" "$port" || {
            err "listener has the wrong address: ${network}:${port}, expected ${address}"
            return 1
        }
    done < <(jq -r '.expected_listeners[] | [.network,.port] | @tsv' "$manifest")
}

service_pid_belongs() {
    local pid="$1"
    if [[ "${SB_TEST_MODE:-false}" == "true" ]]; then
        [[ -f "${SB_TEST_RUNTIME_DIR}/service.pid" &&
           "$(cat "${SB_TEST_RUNTIME_DIR}/service.pid")" == "$pid" ]]
        return
    fi
    [[ "$(readlink -f "/proc/${pid}/exe" 2>/dev/null)" == "$(readlink -f "$SB_BIN")" ]] ||
        return 1
    grep -Eq "(^|/)${SB_SERVICE}\\.service($|/)" "/proc/${pid}/cgroup"
}

service_generation_loaded() {
    local pid="$1" actual expected
    actual=$(readlink -f "/proc/${pid}/cwd" 2>/dev/null) || return 1
    expected=$(readlink -f "$SB_CURRENT_OUTPUT") || return 1
    [[ "$actual" == "$expected" ]] || {
        err "sb-core still uses a different generation: $actual (expected $expected)"
        return 1
    }
}

service_socket_line() {
    local network="$1" port="$2" pid="$3"
    if [[ "$network" == "tcp" ]]; then
        "$SB_SS" -H -lntp
    else
        "$SB_SS" -H -lnup
    fi | awk -v port="$port" -v pid="$pid" '
      $4 ~ (":" port "$") && $0 ~ ("pid=" pid "([,)]|$)") {print; found=1; exit}
      END{exit !found}'
}

service_listener_address_matches() {
    local line="$1" expected="$2" port="$3" local_address
    local_address=$(awk '{print $4}' <<<"$line")
    case "$expected" in
        0.0.0.0) [[ "$local_address" == "0.0.0.0:${port}" ]] ;;
        ::) [[ "$local_address" == "[::]:${port}" || "$local_address" == "*:${port}" ]] ;;
        *) return 1 ;;
    esac
}

service_verify_removed_listeners() {
    local old_manifest="$1" new_manifest="$2" network port
    [[ -f "$old_manifest" && -f "$new_manifest" ]] || return 1
    while IFS=$'\t' read -r network port; do
        if jq -e --arg network "$network" --argjson port "$port" \
          '.expected_listeners[] | select(.network==$network and .port==$port)' \
          "$new_manifest" >/dev/null; then
            continue
        fi
        if { if [[ "$network" == "tcp" ]]; then
                "$SB_SS" -H -lntp
             else
                "$SB_SS" -H -lnup
             fi; } | awk -v port="$port" '
               $4 ~ (":" port "$") {found=1}
               END{exit !found}'; then
            err "removed listener is still present: ${network}:${port}"
            return 1
        fi
    done < <(jq -r '.expected_listeners[] | [.network,.port] | @tsv' "$old_manifest")
}

service_actual_listeners_json() {
    local manifest="${1:-${SB_CURRENT_OUTPUT}/manifest.json}" network port found result='[]'
    [[ -f "$manifest" ]] || {
        printf '[]\n'
        return
    }
    while IFS=$'\t' read -r network port; do
        found=false
        if [[ "$network" == "tcp" ]]; then
            "$SB_SS" -H -lntp | awk -v port="$port" \
              '$4 ~ (":" port "$") {found=1} END{exit !found}' && found=true
        else
            "$SB_SS" -H -lnup | awk -v port="$port" \
              '$4 ~ (":" port "$") {found=1} END{exit !found}' && found=true
        fi
        if [[ "$found" == "true" ]]; then
            result=$(jq -cn --argjson current "$result" --arg network "$network" \
              --argjson port "$port" '$current + [{network:$network,port:$port}]')
        fi
    done < <(jq -r '.expected_listeners[] | [.network,.port] | @tsv' "$manifest")
    printf '%s\n' "$result"
}

service_pid() {
    "$SB_SYSTEMCTL" show "$SB_SERVICE" --property MainPID --value 2>/dev/null || printf '0\n'
}

service_logs() {
    "$SB_JOURNALCTL" -u "$SB_SERVICE" -n "${1:-100}" --no-pager
}
