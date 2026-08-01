#!/usr/bin/env bash

SB_SS="${SB_SS:-ss}"

# systemd publishes MainPID at fork and moves the child into the service cgroup
# *before* the child execs the target binary. For roughly 30-50ms after
# `systemctl restart` the unit therefore reports a valid, correctly-cgrouped
# MainPID whose /proc/<pid>/exe still resolves to systemd itself. A single-shot
# ownership check rejects a perfectly healthy service in that window, which is
# what "MainPID N does not belong to sb-core" meant on real systemd. Isolated
# runs never saw it because the mock reports a settled PID immediately.
#
# The answer is to wait for the unit to settle, never to relax the predicates:
# both the executable and the cgroup check still have to pass, on a PID that has
# stopped moving, before a publish is accepted.
SB_OWNERSHIP_SETTLE_TIMEOUT="${SB_OWNERSHIP_SETTLE_TIMEOUT:-5}"
SB_OWNERSHIP_SETTLE_INTERVAL="${SB_OWNERSHIP_SETTLE_INTERVAL:-0.05}"

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
    # Ownership is checked against a settled PID; see the note on
    # SB_OWNERSHIP_SETTLE_TIMEOUT for why a single sample is not enough.
    pid=$(service_wait_ownership) || return 1
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

# Records which predicate rejected the PID, so a settle timeout can say which
# one never became true instead of just "does not belong".
SB_OWNERSHIP_LAST_FAIL=""

service_pid_belongs() {
    local pid="$1"
    SB_OWNERSHIP_LAST_FAIL=""
    if [[ "${SB_TEST_MODE:-false}" == "true" ]]; then
        # Tests drive the transient startup states through a scripted sequence:
        # one verdict per call, the last entry repeating once exhausted.
        local seq="${SB_TEST_RUNTIME_DIR}/belongs.sequence"
        if [[ -f "$seq" ]]; then
            local verdict
            verdict=$(head -n1 "$seq")
            if (( $(wc -l <"$seq") > 1 )); then
                tail -n +2 "$seq" >"${seq}.next" && mv -f "${seq}.next" "$seq"
            fi
            case "$verdict" in
                pass) return 0 ;;
                fail-exe) SB_OWNERSHIP_LAST_FAIL="executable"; return 1 ;;
                fail-cgroup) SB_OWNERSHIP_LAST_FAIL="cgroup"; return 1 ;;
            esac
        fi
        [[ -f "${SB_TEST_RUNTIME_DIR}/service.pid" &&
           "$(cat "${SB_TEST_RUNTIME_DIR}/service.pid")" == "$pid" ]] ||
            { SB_OWNERSHIP_LAST_FAIL="executable"; return 1; }
        return 0
    fi
    [[ "$(readlink -f "/proc/${pid}/exe" 2>/dev/null)" == "$(readlink -f "$SB_BIN")" ]] || {
        SB_OWNERSHIP_LAST_FAIL="executable"
        return 1
    }
    grep -Eq "(^|/)${SB_SERVICE}\\.service($|/)" "/proc/${pid}/cgroup" || {
        SB_OWNERSHIP_LAST_FAIL="cgroup"
        return 1
    }
    return 0
}

# Wait for the unit to present a stable, owned MainPID.
#
# Succeeds only when a nonzero MainPID is unchanged between two consecutive
# samples and both ownership predicates pass on it. Returns as soon as that
# holds, so the healthy path costs one extra sample at most. On timeout it
# names the predicate that never became true and fails, leaving the caller's
# rollback path and exit code untouched.
# Output: the settled PID on stdout.
service_wait_ownership() {
    local pid last_pid="" waited=0 deadline_reached=0
    local interval="$SB_OWNERSHIP_SETTLE_INTERVAL"
    local timeout="$SB_OWNERSHIP_SETTLE_TIMEOUT"
    local last_fail="" last_seen_pid=""

    while :; do
        pid=$(service_pid)
        if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]; then
            last_seen_pid="$pid"
            # Require the PID to hold still: a restart mid-check must not be
            # mistaken for a settled service.
            if [[ "$pid" == "$last_pid" ]] && service_pid_belongs "$pid"; then
                printf '%s\n' "$pid"
                return 0
            fi
            [[ -n "$SB_OWNERSHIP_LAST_FAIL" ]] && last_fail="$SB_OWNERSHIP_LAST_FAIL"
            last_pid="$pid"
        else
            last_pid=""
        fi

        (( deadline_reached )) && break
        sleep "$interval"
        waited=$(awk -v w="$waited" -v i="$interval" 'BEGIN{printf "%.3f", w+i}')
        awk -v w="$waited" -v t="$timeout" 'BEGIN{exit !(w >= t)}' && deadline_reached=1
    done

    if [[ -z "$last_seen_pid" ]]; then
        err "sb-core did not publish a valid MainPID within ${timeout}s"
    else
        err "sb-core MainPID ${last_seen_pid} never satisfied the ${last_fail:-ownership} check within ${timeout}s"
    fi
    return 1
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
    # Tests script the MainPID progression (0 → valid, or a PID change during
    # startup) through a sequence file: one value per call, last entry repeats.
    if [[ "${SB_TEST_MODE:-false}" == "true" && -f "${SB_TEST_RUNTIME_DIR}/pid.sequence" ]]; then
        local seq="${SB_TEST_RUNTIME_DIR}/pid.sequence" value
        value=$(head -n1 "$seq")
        if (( $(wc -l <"$seq") > 1 )); then
            tail -n +2 "$seq" >"${seq}.next" && mv -f "${seq}.next" "$seq"
        fi
        printf '%s\n' "$value"
        return 0
    fi
    "$SB_SYSTEMCTL" show "$SB_SERVICE" --property MainPID --value 2>/dev/null || printf '0\n'
}

service_logs() {
    "$SB_JOURNALCTL" -u "$SB_SERVICE" -n "${1:-100}" --no-pager
}
