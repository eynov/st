#!/usr/bin/env bash

doctor_add() {
    local results="$1" name="$2" status="$3" message="$4"
    jq -cn --argjson results "$results" --arg name "$name" --arg status "$status" \
      --arg message "$message" '$results + [{name:$name,status:$status,message:$message}]'
}

doctor_run_json() {
    local results='[]' version enabled active message file mode bad_permissions="" hop_count
    local listen_mode bindv6only

    if [[ -x "$SB_BIN" ]]; then
        version=$(core_installed_version || true)
        if core_validate_installed false; then
            results=$(doctor_add "$results" binary pass \
              "sing-box $version digest=$(core_installed_digest)")
        else
            results=$(doctor_add "$results" binary fail \
              "version/digest/receipt validation failed; observed ${version:-unknown}")
        fi
    else
        results=$(doctor_add "$results" binary fail "missing or not executable: $SB_BIN")
    fi

    if [[ -f "$SB_SERVICE_FILE" ]]; then
        results=$(doctor_add "$results" systemd_unit pass "$SB_SERVICE_FILE")
    else
        results=$(doctor_add "$results" systemd_unit fail "unit file missing")
    fi
    service_is_enabled && enabled=true || enabled=false
    service_is_active && active=true || active=false
    [[ "$enabled" == "true" ]] &&
        results=$(doctor_add "$results" systemd_enabled pass "enabled") ||
        results=$(doctor_add "$results" systemd_enabled fail "disabled")

    if [[ -f "$SB_CURRENT_STATE" ]] && state_validate_file "$SB_CURRENT_STATE"; then
        results=$(doctor_add "$results" state pass "schema and protocol validation passed")
    else
        results=$(doctor_add "$results" state fail "state validation failed")
    fi

    if [[ -f "$SB_CURRENT_CONFIG" ]] && runtime_check_config "$SB_CURRENT_CONFIG" >/dev/null 2>&1; then
        results=$(doctor_add "$results" config pass "sing-box check passed")
    else
        results=$(doctor_add "$results" config fail "sing-box check failed")
    fi

    if endpoint_get >/dev/null 2>&1; then
        message="$(endpoint_get) ($(jq -r '.endpoint.source' "$SB_SETTINGS_FILE"))"
        results=$(doctor_add "$results" endpoint pass "$message")
    else
        results=$(doctor_add "$results" endpoint fail "explicit public endpoint is not valid")
    fi

    listen_mode=$(jq -r '.listen.mode' "$SB_SETTINGS_FILE")
    if [[ "$listen_mode" == "dual" ]]; then
        bindv6only=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || printf 'unavailable')
        if [[ "$bindv6only" == "0" ]]; then
            results=$(doctor_add "$results" listen_mode pass "dual-stack bind on :: with bindv6only=0")
        else
            results=$(doctor_add "$results" listen_mode fail \
              "dual mode requires IPv6 and net.ipv6.bindv6only=0; observed ${bindv6only}")
        fi
    elif [[ "$listen_mode" == "ipv4" ]]; then
        results=$(doctor_add "$results" listen_mode pass "IPv4-only bind on 0.0.0.0")
    elif [[ -r /proc/sys/net/ipv6/bindv6only ]]; then
        results=$(doctor_add "$results" listen_mode pass "IPv6-only bind on ::")
    else
        results=$(doctor_add "$results" listen_mode fail "IPv6-only mode selected but IPv6 is unavailable")
    fi

    while IFS= read -r file; do
        mode=$(stat -c '%a' "$file")
        case "$mode" in
          600|700) ;;
          *) bad_permissions+="${file}:${mode} " ;;
        esac
    done < <(find "$SB_CONFIG_DIR" "$SB_DATA_DIR" "$SB_BACKUP_DIR" \
      -type f 2>/dev/null || true)
    [[ -z "$bad_permissions" ]] &&
        results=$(doctor_add "$results" permissions pass "all sensitive files are mode 0600 or stricter") ||
        results=$(doctor_add "$results" permissions fail "$bad_permissions")

    if [[ "$active" == "true" ]]; then
        if service_verify_listeners >/dev/null 2>&1; then
            results=$(doctor_add "$results" listeners pass "all expected listeners are present")
        else
            results=$(doctor_add "$results" listeners fail "one or more expected listeners are missing")
        fi
    else
        results=$(doctor_add "$results" listeners info "service is inactive; listener check skipped")
    fi

    local tls_id tls_meta tls_status days tls_mode
    while IFS= read -r tls_id; do
        tls_meta=$(jq -c --arg id "$tls_id" '.instances[$id]' "$SB_CURRENT_STATE")
        tls_status=$(tls_status_json "$tls_meta")
        days=$(jq -r '.days_remaining // -1' <<<"$tls_status")
        tls_mode=$(jq -r '.tls.mode' <<<"$tls_meta")
        if ((days < 0)); then
            results=$(doctor_add "$results" "certificate_${tls_id}" fail "certificate unreadable or expired")
        elif ((days < 30)); then
            results=$(doctor_add "$results" "certificate_${tls_id}" fail "certificate expires in ${days} days")
        else
            results=$(doctor_add "$results" "certificate_${tls_id}" pass "certificate valid for ${days} days")
        fi
        if [[ "$tls_mode" == "insecure" ]]; then
            results=$(doctor_add "$results" "tls_mode_${tls_id}" info "explicit insecure compatibility mode; server identity is not verified")
        fi
    done < <(jq -r '.instances | to_entries[] |
      select(.value.protocol=="HY2" or .value.protocol=="ANYTLS") | .key' \
      "$SB_CURRENT_STATE" 2>/dev/null || true)

    hop_count=$(jq -r '[.instances[] | select(.enabled and .protocol=="HY2" and .hop.enabled)] | length' \
      "$SB_CURRENT_STATE" 2>/dev/null || printf '0')
    if ((hop_count > 0)); then
        message="项目无法仅通过本地配置确认云安全组和外部防火墙是否已正确放行。请确认完整 UDP 跳跃范围均可到达本机，并已转发到基础端口。"
        results=$(doctor_add "$results" hy2_port_hopping info "$message")
    fi
    local unacknowledged_hop_count
    unacknowledged_hop_count=$(jq -r '[.instances[] |
      select(.protocol=="HY2" and .hop.enabled and (.hop.acknowledged|not))] | length' \
      "$SB_CURRENT_STATE" 2>/dev/null || printf '0')
    if ((unacknowledged_hop_count > 0)); then
        results=$(doctor_add "$results" hy2_port_hopping_ack fail \
          "${unacknowledged_hop_count} migrated HY2 hopping node(s) require explicit acknowledgement before enable")
    fi

    jq -n --arg project_version "$SB_PROJECT_VERSION" \
      --arg core_version "$SB_CORE_VERSION" --argjson results "$results" '
      {
        project_version:$project_version,
        expected_sing_box_version:$core_version,
        passed:([$results[]|select(.status=="fail")]|length==0),
        results:$results
      }'
}

doctor_run() {
    local output
    output=$(doctor_run_json)
    if [[ "$SB_JSON" == "true" ]]; then
        printf '%s\n' "$output"
    else
        jq -r '.results[] | "\(.status|ascii_upcase) \(.name): \(.message)"' <<<"$output"
    fi
    jq -e '.passed' <<<"$output" >/dev/null
}

status_json() {
    local enabled active pid version total active_count status='{}' listeners='[]'
    service_is_enabled && enabled=true || enabled=false
    service_is_active && active=true || active=false
    pid=$(service_pid)
    version=$(core_installed_version 2>/dev/null || true)
    total=$(state_count_file "$SB_CURRENT_STATE" 2>/dev/null || printf '0')
    active_count=$(state_enabled_count_file "$SB_CURRENT_STATE" 2>/dev/null || printf '0')
    [[ "$active" == "true" ]] && listeners=$(service_actual_listeners_json)
    [[ -f "$SB_STATUS_FILE" ]] && status=$(cat "$SB_STATUS_FILE")
    jq -n --argjson enabled "$enabled" --argjson active "$active" \
      --argjson pid "${pid:-0}" --arg version "${version:-not-installed}" \
      --argjson total "$total" --argjson active_count "$active_count" \
      --argjson status "$status" --argjson listeners "$listeners" \
      --slurpfile manifest "$SB_CURRENT_OUTPUT/manifest.json" '
      {
        enabled:$enabled,active:$active,pid:$pid,sing_box_version:$version,
        instances:{total:$total,enabled:$active_count},
        listeners:$listeners,
        expected_listeners:($manifest[0].expected_listeners // []),
        last_publish:($status.last_publish // null),
        last_rollback:($status.last_rollback // null)
      }'
}
