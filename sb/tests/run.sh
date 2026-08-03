#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_CORE="${SB_TEST_REAL_CORE:-/tmp/sb-core-1.13.15/sing-box}"
[[ -x "$REAL_CORE" ]] || {
    printf 'ERROR: required real sing-box test binary not found: %s\n' "$REAL_CORE" >&2
    exit 1
}

PASS=0
FAIL=0
TEST_ROOTS=()
TEST_TEMP_FILES=()

cleanup() {
    local root pid
    [[ "${SB_TEST_KEEP:-false}" != "true" ]] || return 0
    for root in "${TEST_ROOTS[@]}"; do
        if [[ -f "$root/runtime/service.pid" ]]; then
            pid=$(cat "$root/runtime/service.pid")
            kill "$pid" 2>/dev/null || true
        fi
        rm -rf -- "$root"
    done
    for root in "${TEST_TEMP_FILES[@]}"; do
        rm -f -- "$root"
    done
}
trap cleanup EXIT

pass() {
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1" >&2
}

assert() {
    local name="$1"
    shift
    if "$@"; then pass "$name"; else fail "$name"; return 1; fi
}

new_env() {
    local root
    root=$(mktemp -d)
    TEST_ROOTS+=("$root")
    TEST_ROOT="$root"
    export SB_TEST_MODE=true
    export SB_APP_DIR="$APP_DIR"
    export SB_CONFIG_DIR="$root/etc"
    export SB_DATA_DIR="$root/data"
    export SB_CERT_DIR="$root/data/certs"
    export SB_GENERATIONS_DIR="$root/data/generations"
    export SB_CURRENT_LINK="$root/data/current"
    export SB_SETTINGS_LINK="$root/etc/settings.json"
    unset SB_SETTINGS_FILE
    export SB_STATUS_FILE="$root/data/status.json"
    export SB_BACKUP_DIR="$root/backups"
    export SB_LOCK_DIR="$root/lock"
    export SB_LOCK_FILE="$root/lock/manager.lock"
    export SB_BIN="$root/bin/sing-box"
    export SB_SERVICE_FILE="$root/systemd/sb-core.service"
    export SB_SYSTEMCTL="$APP_DIR/tests/fixtures/mock-systemctl"
    export SB_SS="$APP_DIR/tests/fixtures/mock-ss"
    export SB_TEST_RUNTIME_DIR="$root/runtime"
    export SB_TEST_DATA_DIR="$root/data"
    export SB_LEGACY_DIR="$root/legacy"
    export SB_INSTALL_ROOT="$root/opt"
    export SB_RELEASES_DIR="$root/opt/releases"
    export SB_APP_LINK="$root/opt/app"
    export SB_COMMAND_LINK="$root/bin/sb"
    export SB_SKIP_PACKAGES=true
    export SB_SKIP_LISTENER_CHECK=false
    export SB_VALIDATE_FILES=true
    export SB_CORE_ARCHIVE="/tmp/sb-core-1.13.15/sing-box.tar.gz"
    export SB_GETENT="$APP_DIR/tests/fixtures/mock-getent"
    unset SB_CA_BUNDLE
    SB_TEST_OUTPUT_FILE=$(mktemp)
    TEST_TEMP_FILES+=("$SB_TEST_OUTPUT_FILE")
    export SB_TEST_OUTPUT_FILE
}

sb() {
    "$APP_DIR/sb" "$@"
}

free_udp_port() {
    python3 -c 'import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.bind(("127.0.0.1",0))
print(s.getsockname()[1])
s.close()'
}

generation_hashes() {
    local root="$1"
    find "$root/data/current" -type f -print0 |
      sort -z |
      xargs -0 sha256sum |
      sed "s#${root}/data/current/##" |
      sha256sum |
      awk '{print $1}'
}

init_env() {
    sb install --endpoint node.example.com --yes >/dev/null
}

test_all_protocols() {
    local root ss_id ss2022_id anytls_id vless_id hy2_id
    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 10001 --yes >/dev/null
    sb add SS2022 --port 10002 --method 2022-blake3-aes-256-gcm --yes >/dev/null
    sb add ANYTLS --port 10003 --sni any.example.com --tls-mode self-signed --yes >/dev/null
    sb add VLESS --port 10004 --server-name www.icloud.com --yes >/dev/null
    sb add HY2 --port 10005 --sni hy.example.com --tls-mode self-signed \
      --masquerade https://hy.example.com --no-hop --yes >/dev/null
    assert "all protocols added" test "$(jq '.instances|length' "$root/data/current/instances.json")" -eq 5
    assert "five inbounds rendered" test "$(jq '.inbounds|length' "$root/data/current/output/config.json")" -eq 5
    assert "five sing-box outbounds rendered" test "$(jq '.outbounds|length' "$root/data/current/output/clients/sing-box.json")" -eq 5
    assert "fixed core accepts multi-protocol config" "$REAL_CORE" check -c "$root/data/current/output/config.json"
    assert "fixed core accepts generated client outbounds" "$REAL_CORE" check -c "$root/data/current/output/clients/sing-box.json"
    assert "service enabled" test -f "$root/runtime/enabled"
    assert "service active" test -f "$root/runtime/active"
    assert "sensitive state mode" test "$(stat -c %a "$root/data/current/instances.json")" = 600
    assert "sensitive config mode" test "$(stat -c %a "$root/data/current/output/config.json")" = 600

    ss_id=$(jq -r '.instances|to_entries[]|select(.value.protocol=="SS")|.key' "$root/data/current/instances.json")
    ss2022_id=$(jq -r '.instances|to_entries[]|select(.value.protocol=="SS2022")|.key' "$root/data/current/instances.json")
    anytls_id=$(jq -r '.instances|to_entries[]|select(.value.protocol=="ANYTLS")|.key' "$root/data/current/instances.json")
    vless_id=$(jq -r '.instances|to_entries[]|select(.value.protocol=="VLESS")|.key' "$root/data/current/instances.json")
    hy2_id=$(jq -r '.instances|to_entries[]|select(.value.protocol=="HY2")|.key' "$root/data/current/instances.json")
    sb edit "$ss_id" --port 10101 --method chacha20-ietf-poly1305 --yes >/dev/null
    sb edit "$ss2022_id" --port 10102 --method 2022-blake3-chacha20-poly1305 --yes >/dev/null
    sb edit "$anytls_id" --port 10103 --sni any2.example.com --yes >/dev/null
    sb edit "$vless_id" --port 10104 --server-name www.apple.com --yes >/dev/null
    sb edit "$hy2_id" --port 10105 --sni hy2.example.com \
      --masquerade https://hy2.example.com --yes >/dev/null
    assert "all protocol edits pass fixed core" "$REAL_CORE" check -c "$root/data/current/output/config.json"
    for id in "$ss_id" "$ss2022_id" "$anytls_id" "$vless_id" "$hy2_id"; do
        sb disable "$id" --yes >/dev/null
        sb enable "$id" --yes >/dev/null
    done
    assert "all protocol disable-enable cycles preserve count" test "$(jq '.instances|length' "$root/data/current/instances.json")" -eq 5
    for id in "$ss_id" "$ss2022_id" "$anytls_id" "$vless_id" "$hy2_id"; do
        sb delete "$id" --yes >/dev/null
    done
    assert "all protocol delete paths empty state" jq -e '.instances=={}' "$root/data/current/instances.json"
}

test_conflicts_and_check_failure() {
    local root before
    new_env
    root="$TEST_ROOT"
    init_env
    sb add ANYTLS --port 17001 --sni any.example.com --tls-mode self-signed --yes >/dev/null
    before=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    if sb add VLESS --port 17001 --server-name www.icloud.com --yes >/dev/null 2>&1; then
        fail "TCP port conflict rejected"
    else
        pass "TCP port conflict rejected"
    fi
    assert "port conflict rolls state back" test "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$before"
    sb add HY2 --port 17001 --sni hy.example.com --tls-mode insecure \
      --masquerade https://hy.example.com --no-hop --yes >/dev/null
    assert "same numeric TCP and UDP port can coexist" test "$(jq '.instances|length' "$root/data/current/instances.json")" -eq 2

    before=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    if SB_BIN="$APP_DIR/tests/fixtures/mock-sing-box-fail-check" \
      sb edit is01 --port 17002 --yes >/dev/null 2>&1; then
        fail "sing-box check failure rejected"
    else
        pass "sing-box check failure rejected"
    fi
    assert "check failure preserves state hash" test "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$before"
}

test_legacy_migration() {
    local root password state_hash cert_hash
    new_env
    root="$TEST_ROOT"
    mkdir -p "$root/legacy/certs" "$root/legacy/output"
    printf 'legacy-derived-output\n' >"$root/legacy/output/uris.txt"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$root/legacy/certs/hy2_18001.key" \
      -out "$root/legacy/certs/hy2_18001.crt" \
      -subj '/CN=legacy.example.com' \
      -addext 'subjectAltName=DNS:legacy.example.com' >/dev/null 2>&1
    password="legacy-password-stable"
    jq -n --arg password "$password" \
      --arg cert "$root/legacy/certs/hy2_18001.crt" \
      --arg key "$root/legacy/certs/hy2_18001.key" '
      {instances:{is01:{
        id:"is01",protocol:"HY2",port:18001,password:$password,
        sni:"legacy.example.com",masq:"https://legacy.example.com",
        cert:$cert,key:$key,hop_ports:"20000-20100",hop_interval:30,
        enabled:true,created_at:"2026-01-01 00:00:00",updated_at:"2026-01-01 00:00:00"
      }}}' >"$root/legacy/instances.json"
    cert_hash=$(sha256sum "$root/legacy/certs/hy2_18001.crt" | awk '{print $1}')
    sb install --endpoint node.example.com --yes >/dev/null
    state_hash=$(jq -r '.instances.is01.password' "$root/data/current/instances.json")
    assert "legacy password preserved" test "$state_hash" = "$password"
    assert "legacy schema migrated" jq -e '
      .schema_version==2 and .instances.is01.tls.mode=="insecure" and
      .instances.is01.hop.enabled==true and .instances.is01.enabled==false and
      .instances.is01.hop.confirmation_required==true
    ' "$root/data/current/instances.json"
    if sb doctor --json >"$SB_TEST_OUTPUT_FILE" 2>/dev/null; then
        fail "legacy hopping without acknowledgement is reported"
    else
        pass "legacy hopping without acknowledgement is reported"
    fi
    assert "doctor names required hopping acknowledgement" \
      jq -e '.results[]|select(.name=="hy2_port_hopping_ack" and .status=="fail")' \
      "$SB_TEST_OUTPUT_FILE"
    assert "legacy certificate hash preserved" test "$(sha256sum "$root/data/certs/hy2_18001.crt" | awk '{print $1}')" = "$cert_hash"
    assert "legacy source retained" test -f "$root/legacy/instances.json"
    assert "migration backup includes legacy output" sh -c \
      "find '$root/backups' -path '*/legacy/output/uris.txt' -type f | grep -q ."
    sb install --endpoint node.example.com --yes >/dev/null
    assert "migration is idempotent" test "$(jq -r '.instances.is01.password' "$root/data/current/instances.json")" = "$password"
}

# Build a legacy sb v2 installation. sb v2 kept no endpoint setting: it detected
# the address whenever it compiled client output and rendered it into sub.yaml,
# so that file is where the endpoint of a real v2 host actually lives.
make_legacy_v2_install() {
    local root="$1" password="${2:-legacy-v2-password}"
    mkdir -p "$root/legacy/certs" "$root/legacy/output" || return 1
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$root/legacy/certs/hy2_18001.key" \
      -out "$root/legacy/certs/hy2_18001.crt" \
      -subj '/CN=legacy.example.com' \
      -addext 'subjectAltName=DNS:legacy.example.com' >/dev/null 2>&1 || return 1
    jq -n --arg password "$password" \
      --arg cert "$root/legacy/certs/hy2_18001.crt" \
      --arg key "$root/legacy/certs/hy2_18001.key" '{instances:{
        is01:{id:"is01",protocol:"HY2",port:18001,password:$password,
          sni:"legacy.example.com",masq:"https://legacy.example.com",
          cert:$cert,key:$key,hop_ports:null,hop_interval:null,
          enabled:true,created_at:"2026-01-01 00:00:00",
          updated_at:"2026-01-01 00:00:00"},
        is02:{id:"is02",protocol:"SS",port:18002,password:"legacy-ss-password",
          method:"chacha20-ietf-poly1305",enabled:true,
          created_at:"2026-01-01 00:00:00",updated_at:"2026-01-01 00:00:00"}
      }}' >"$root/legacy/instances.json" || return 1
}

# Reproduce sb v2's sub.yaml exactly: one compact clash proxy JSON per line under
# `proxies:`, plus the commented Surge block it appended.
write_legacy_v2_sub() {
    local root="$1"
    shift
    local servers=("$@") index=0 server
    {
        printf '# 自动生成 - 2026-01-01 00:00:00\n\n'
        printf 'proxies:\n'
        for server in "${servers[@]}"; do
            index=$((index + 1))
            jq -cn --arg name "HY2-is0${index}" --arg server "$server" \
              --argjson port $((18000 + index)) '{
                name:$name,type:"hysteria2",server:$server,port:$port,
                password:"legacy-v2-password",sni:"legacy.example.com",
                "skip-cert-verify":true
              }' | sed 's/^/  - /'
        done
        printf '\n# [Proxy]\n'
        printf '# HY2-is01 = hysteria2, %s, 18001, password=legacy-v2-password\n' \
          "${servers[0]}"
    } >"$root/legacy/output/sub.yaml"
}

test_legacy_endpoint_recovery() {
    local root rc out endpoint="203.0.114.20"
    # 1. The production path: a legacy install upgraded with no --endpoint at all.
    new_env
    root="$TEST_ROOT"
    make_legacy_v2_install "$root"
    write_legacy_v2_sub "$root" "$endpoint" "$endpoint"
    sb install --yes >/dev/null
    assert "legacy migration without --endpoint publishes a generation" \
      test -L "$root/data/current"
    assert "recovered endpoint is the value sb v2 published" test \
      "$(jq -r '.endpoint.value' "$root/data/current/settings.json")" = "$endpoint"
    assert "recovered endpoint records its provenance" test \
      "$(jq -r '.endpoint.source' "$root/data/current/settings.json")" = "sb-v2-migration"
    assert "recovered endpoint is not marked private" jq -e \
      '.endpoint.allow_private == false' "$root/data/current/settings.json"
    assert "recovered endpoint reaches the client output" \
      rg -q "$endpoint" "$root/data/current/output/clients/uris.txt"
    assert "recovery preserves the legacy password" test \
      "$(jq -r '.instances.is01.password' "$root/data/current/instances.json")" = \
      "legacy-v2-password"
    assert "recovery keeps the legacy source" test -f "$root/legacy/instances.json"
    sb install --yes >/dev/null
    assert "repeated upgrade after recovery is idempotent" test \
      "$(jq -r '.endpoint.value' "$root/data/current/settings.json")" = "$endpoint"

    # 2. An endpoint given on the invocation always wins over a recovered one.
    new_env
    root="$TEST_ROOT"
    make_legacy_v2_install "$root"
    write_legacy_v2_sub "$root" "$endpoint"
    sb install --endpoint node.example.com --yes >/dev/null
    assert "explicit endpoint overrides recovery" test \
      "$(jq -r '.endpoint.value' "$root/data/current/settings.json")" = "node.example.com"
    assert "explicit endpoint keeps its own provenance" test \
      "$(jq -r '.endpoint.source' "$root/data/current/settings.json")" = "explicit"

    # 3. Refusals. Each must stop before touching the legacy install.
    local case_name
    for case_name in absent ambiguous nonpublic; do
        new_env
        root="$TEST_ROOT"
        make_legacy_v2_install "$root"
        case "$case_name" in
            absent) : ;;
            ambiguous) write_legacy_v2_sub "$root" "$endpoint" "203.0.114.21" ;;
            nonpublic) write_legacy_v2_sub "$root" "172.31.5.10" ;;
        esac
        rc=0
        out=$(sb install --yes 2>&1) || rc=$?
        assert "recovery ${case_name}: returns EX_CONFIG" test "$rc" -eq 78
        assert "recovery ${case_name}: names the completing command" sh -c \
          "printf '%s' \"\$1\" | rg -q -- 'sb install --endpoint'" _ "$out"
        assert "recovery ${case_name}: publishes no generation" \
          test ! -L "$root/data/current"
        assert "recovery ${case_name}: leaves the legacy state untouched" \
          test -f "$root/legacy/instances.json"
        assert "recovery ${case_name}: leaves the legacy certificates untouched" \
          test -f "$root/legacy/certs/hy2_18001.crt"
        assert "recovery ${case_name}: creates no legacy backup" sh -c \
          "! find '$root/backups' -maxdepth 1 -name '*-legacy-*' 2>/dev/null | grep -q ."
        assert "recovery ${case_name}: leaves no candidate residue" sh -c \
          "! find '$root/data' -mindepth 1 -maxdepth 2 \\( -name '.migrate-*' -o -name '.cert-migrate-*' -o -name '.cert-previous-*' \\) | grep -q ."
        # The refusal is recoverable: one supported command finishes the job.
        sb install --endpoint "$endpoint" --yes >/dev/null
        assert "recovery ${case_name}: retry with an endpoint completes" test \
          "$(jq -r '.instances.is01.password' "$root/data/current/instances.json")" = \
          "legacy-v2-password"
        assert "recovery ${case_name}: retry records the supplied endpoint" test \
          "$(jq -r '.endpoint.value' "$root/data/current/settings.json")" = "$endpoint"
    done

    # 4. A legacy install whose only node migrates disabled needs no endpoint,
    #    so requiring one would be a regression of its own.
    new_env
    root="$TEST_ROOT"
    mkdir -p "$root/legacy/certs" "$root/legacy/output"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$root/legacy/certs/hy2.key" -out "$root/legacy/certs/hy2.crt" \
      -subj '/CN=hop.example.com' -addext 'subjectAltName=DNS:hop.example.com' \
      >/dev/null 2>&1
    jq -n --arg cert "$root/legacy/certs/hy2.crt" --arg key "$root/legacy/certs/hy2.key" '{
      instances:{is01:{id:"is01",protocol:"HY2",port:18001,password:"legacy-hop-password",
        sni:"hop.example.com",masq:"https://hop.example.com",cert:$cert,key:$key,
        hop_ports:"20000-20100",hop_interval:30,enabled:true,
        created_at:"2026-01-01 00:00:00",updated_at:"2026-01-01 00:00:00"}}}' \
      >"$root/legacy/instances.json"
    sb install --yes >/dev/null
    assert "unacknowledged hopping node migrates without an endpoint" \
      jq -e '.instances.is01.enabled == false' "$root/data/current/instances.json"
    assert "endpoint stays unset when no node needs one" test \
      "$(jq -r '.endpoint.mode' "$root/data/current/settings.json")" = "unset"
}

test_legacy_bootstrap_no_deadlock() {
    local root rc out releases_after endpoint="203.0.114.20"
    # 1. The reported deadlock: the root installer on a legacy host with no
    #    recoverable endpoint must keep the manager it just installed.
    new_env
    root="$TEST_ROOT"
    make_legacy_v2_install "$root"
    rc=0
    out=$("$APP_DIR/../file.sh" sb --source-dir "$APP_DIR" --yes 2>&1) || rc=$?
    assert "installer surfaces EX_CONFIG for a missing legacy endpoint" test "$rc" -eq 78
    assert "installer keeps the new application link" test -L "$SB_APP_LINK"
    assert "installer keeps the new manager runnable" \
      env -u SB_APP_DIR "$SB_APP_LINK/sb" self-check
    assert "installer keeps the management command" test -x "$root/bin/sb"
    assert "installer retains the new release" test "$(manager_release_count)" -ge 1
    assert "installer names the completing command" sh -c \
      "printf '%s' \"\$1\" | rg -q -- 'install --endpoint'" _ "$out"
    assert "installer migrated no data" test ! -L "$root/data/current"
    assert "installer left the legacy install intact" test -f "$root/legacy/instances.json"

    # 2. The recovery command is runnable because the manager survived.
    env -u SB_APP_DIR "$SB_APP_LINK/sb" install --endpoint "$endpoint" --yes >/dev/null
    assert "recovery command completes the migration" test -L "$root/data/current"
    assert "recovery command preserves legacy secrets" test \
      "$(jq -r '.instances.is01.password' "$root/data/current/instances.json")" = \
      "legacy-v2-password"
    assert "recovery command creates the systemd unit" test -f "$root/systemd/sb-core.service"
    "$APP_DIR/../file.sh" sb --source-dir "$APP_DIR" --yes >/dev/null
    assert "repeated installer run after recovery stays idempotent" test \
      "$(jq -r '.endpoint.value' "$root/data/current/settings.json")" = "$endpoint"

    # 3. The whole production flow with nothing supplied by hand.
    new_env
    root="$TEST_ROOT"
    make_legacy_v2_install "$root"
    write_legacy_v2_sub "$root" "$endpoint" "$endpoint"
    "$APP_DIR/../file.sh" sb --source-dir "$APP_DIR" --yes >/dev/null
    assert "legacy install upgrades end to end with no manual input" \
      test -L "$root/data/current"
    assert "end-to-end upgrade recovers the published endpoint" test \
      "$(jq -r '.endpoint.value' "$root/data/current/settings.json")" = "$endpoint"
    assert "end-to-end upgrade keeps the manager installed" \
      env -u SB_APP_DIR "$SB_APP_LINK/sb" validate

    # 4. Every other install failure must still roll the switch back and drop
    #    the release, including one interrupted after the endpoint was recovered.
    new_env
    root="$TEST_ROOT"
    make_legacy_v2_install "$root"
    write_legacy_v2_sub "$root" "$endpoint"
    rc=0
    out=$(SB_TEST_MIGRATION_FAIL_AT=after-render \
      "$APP_DIR/../file.sh" sb --source-dir "$APP_DIR" --yes 2>&1) || rc=$?
    releases_after=$(manager_release_count)
    assert "interrupted migration does not return EX_CONFIG" test "$rc" -ne 78
    assert "interrupted migration returns nonzero" test "$rc" -ne 0
    assert "interrupted migration rolls the application link back" test ! -e "$SB_APP_LINK"
    assert "interrupted migration discards the release" test "$releases_after" -eq 0
    assert "interrupted migration publishes no generation" test ! -L "$root/data/current"
    assert "interrupted migration keeps the legacy install" test -f "$root/legacy/instances.json"
    "$APP_DIR/../file.sh" sb --source-dir "$APP_DIR" --yes >/dev/null
    assert "retry after an interrupted migration succeeds" test \
      "$(jq -r '.instances.is01.password' "$root/data/current/instances.json")" = \
      "legacy-v2-password"
}

test_migration_failure_cleanup_and_retry() {
    local root password cert_hash rc
    for point in legacy-backup after-cert-swap after-render; do
        new_env
        root="$TEST_ROOT"
        mkdir -p "$root/legacy/certs" "$root/legacy/output"
        printf 'old-output\n' >"$root/legacy/output/subscription.txt"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
          -keyout "$root/legacy/certs/hy2.key" \
          -out "$root/legacy/certs/hy2.crt" \
          -subj '/CN=migrate.example.com' \
          -addext 'subjectAltName=DNS:migrate.example.com' >/dev/null 2>&1
        password="migration-stable-password"
        cert_hash=$(sha256sum "$root/legacy/certs/hy2.crt" | awk '{print $1}')
        jq -n --arg password "$password" \
          --arg cert "$root/legacy/certs/hy2.crt" \
          --arg key "$root/legacy/certs/hy2.key" '{
            instances:{is01:{
              id:"is01",protocol:"HY2",port:26501,password:$password,
              sni:"migrate.example.com",masq:"https://migrate.example.com",
              cert:$cert,key:$key,hop_ports:null,hop_interval:null,
              enabled:true,created_at:"2026-01-01",updated_at:"2026-01-01"
            }}
          }' >"$root/legacy/instances.json"
        rc=0
        if [[ "$point" == "legacy-backup" ]]; then
            SB_TEST_BACKUP_FAIL_AT=legacy-root \
              sb install --endpoint node.example.com --yes >/dev/null 2>&1 || rc=$?
        else
            SB_TEST_MIGRATION_FAIL_AT="$point" \
              sb install --endpoint node.example.com --yes >/dev/null 2>&1 || rc=$?
        fi
        assert "migration ${point} failure returns nonzero" test "$rc" -ne 0
        assert "migration ${point} retains legacy state" test -f "$root/legacy/instances.json"
        assert "migration ${point} publishes no current generation" test ! -L "$root/data/current"
        assert "migration ${point} removes candidate directories" sh -c \
          "! find '$root/data' -mindepth 1 -maxdepth 2 \\( -name '.migrate-*' -o -name '.cert-migrate-*' -o -name '.cert-previous-*' \\) | grep -q ."
        sb install --endpoint node.example.com --yes >/dev/null
        assert "migration ${point} retry preserves password" test \
          "$(jq -r '.instances.is01.password' "$root/data/current/instances.json")" = "$password"
        assert "migration ${point} retry preserves certificate hash" test \
          "$(sha256sum "$root/data/certs/hy2.crt" | awk '{print $1}')" = "$cert_hash"
    done
}

# Build a self-contained previous-pin manager/core fixture.  The fake 1.13.14
# binary reports the previous version while delegating all real config checks
# to the current, independently verified test core.  Its archive and manifest
# are still digest-pinned, so the production download/receipt path is exercised
# without adding a second binary dependency to the repository.
make_previous_pin_source() {
    local destination="$1" archive="$2" payload binary archive_sha binary_sha checksums_sha
    cp -a "$APP_DIR/." "$destination/" || return 1
    payload=$(mktemp -d "$TEST_ROOT/previous-core-payload.XXXXXX") || return 1
    binary="$payload/sing-box-1.13.14-linux-amd64/sing-box"
    mkdir -p "$(dirname "$binary")" || return 1
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'if [[ "${1:-}" == version ]]; then' \
      '  printf "sing-box version 1.13.14\\n"' \
      'else' \
      "  exec \"$REAL_CORE\" \"\$@\"" \
      'fi' >"$binary" || return 1
    chmod 755 "$binary" || return 1
    tar -czf "$archive" -C "$payload" sing-box-1.13.14-linux-amd64 || return 1
    archive_sha=$(sha256sum "$archive" | awk '{print $1}') || return 1
    binary_sha=$(sha256sum "$binary" | awk '{print $1}') || return 1
    jq -n --arg archive_sha "$archive_sha" --arg binary_sha "$binary_sha" '{
      schema_version:1,
      source:"https://api.github.com/repos/SagerNet/sing-box/releases/tags/v1.13.14",
      versions:{"1.13.14":{"linux-amd64":{
        url:"https://github.com/SagerNet/sing-box/releases/download/v1.13.14/sing-box-1.13.14-linux-amd64.tar.gz",
        sha256:$archive_sha,binary_sha256:$binary_sha
      }}}
    }' >"$destination/checksums.json" || return 1
    jq '.sing_box_version="1.13.14"' "$destination/version.json" \
      >"$destination/version.json.new" || return 1
    mv -f "$destination/version.json.new" "$destination/version.json" || return 1
    sed -i 's/^SB_CORE_VERSION=.*/SB_CORE_VERSION="1.13.14"/' \
      "$destination/core/common.sh" || return 1
    checksums_sha=$(sha256sum "$destination/checksums.json" | awk '{print $1}') || return 1
    sed -i "s/^SB_CHECKSUMS_SHA256=.*/SB_CHECKSUMS_SHA256=\"${checksums_sha}\"/" \
      "$destination/core/common.sh" || return 1
}

setup_previous_pin_install() {
    local old_source old_archive
    new_env
    old_source="$TEST_ROOT/old-source"
    old_archive="$TEST_ROOT/sing-box-1.13.14.tar.gz"
    mkdir -p "$old_source" || return 1
    make_previous_pin_source "$old_source" "$old_archive" || return 1
    SB_APP_DIR="$old_source" SB_CORE_ARCHIVE="$old_archive" \
      "$old_source/sb" install --endpoint node.example.com --yes >/dev/null || return 1
    SB_APP_DIR="$old_source" bash -c '
      source "$SB_APP_DIR/core/common.sh"
      source "$SB_APP_DIR/core/manager.sh"
      manager_install_source "$SB_APP_DIR"
    ' >/dev/null || return 1
    PREVIOUS_PIN_CORE_SHA=$(sha256sum "$SB_BIN" | awk '{print $1}') || return 1
    PREVIOUS_PIN_APP=$(readlink "$SB_APP_LINK") || return 1
}

test_cross_pin_upgrade_bootstrap() {
    local root before_state before_releases invalid_source out rc
    setup_previous_pin_install
    root="$TEST_ROOT"
    env -u SB_APP_DIR "$SB_APP_LINK/sb" add SS --port 18901 --yes >/dev/null
    before_state=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    before_releases=$(manager_release_count)

    out=$(env -u SB_APP_DIR "$APP_DIR/sb" upgrade --source "$APP_DIR" --yes 2>&1) &&
      rc=0 || rc=$?
    assert "cross-pin manager upgrade without authorization returns EX_USAGE" test "$rc" -eq 64
    assert "cross-pin refusal names the old and new pins" sh -c \
      "printf '%s' \"\$1\" | rg -q '1.13.14 -> 1.13.15'" _ "$out"
    assert "cross-pin refusal gives the explicit bootstrap flag" sh -c \
      "printf '%s' \"\$1\" | rg -q -- '--upgrade-core'" _ "$out"
    assert "cross-pin refusal leaves the manager link unchanged" \
      test "$(readlink "$SB_APP_LINK")" = "$PREVIOUS_PIN_APP"
    assert "cross-pin refusal leaves the previous core unchanged" \
      test "$(sha256sum "$SB_BIN" | awk '{print $1}')" = "$PREVIOUS_PIN_CORE_SHA"
    assert "cross-pin refusal creates no release" \
      test "$(manager_release_count)" -eq "$before_releases"

    invalid_source="$root/invalid-source"
    cp -a "$APP_DIR" "$invalid_source"
    jq '.sing_box_version="9.9.9"' "$invalid_source/version.json" \
      >"$invalid_source/version.json.new"
    mv -fT "$invalid_source/version.json.new" "$invalid_source/version.json"
    out=$(env -u SB_APP_DIR "$APP_DIR/sb" upgrade --source "$invalid_source" \
      --upgrade-core --yes 2>&1) && rc=0 || rc=$?
    assert "cross-pin source rejects inconsistent core metadata" test "$rc" -ne 0
    assert "cross-pin metadata rejection is actionable" sh -c \
      "printf '%s' \"\$1\" | rg -q 'does not match core/common.sh'" _ "$out"
    assert "invalid cross-pin source leaves the manager unchanged" \
      test "$(readlink "$SB_APP_LINK")" = "$PREVIOUS_PIN_APP"
    assert "invalid cross-pin source leaves the previous core unchanged" \
      test "$(sha256sum "$SB_BIN" | awk '{print $1}')" = "$PREVIOUS_PIN_CORE_SHA"
    assert "invalid cross-pin source creates no release" \
      test "$(manager_release_count)" -eq "$before_releases"

    env -u SB_APP_DIR "$APP_DIR/sb" upgrade --source "$APP_DIR" \
      --upgrade-core --yes >/dev/null
    assert "authorized cross-pin upgrade switches the manager" \
      test "$(readlink "$SB_APP_LINK")" != "$PREVIOUS_PIN_APP"
    assert "authorized cross-pin upgrade installs the new core version" \
      test "$("$SB_BIN" version | awk 'NR==1{print $3}')" = "1.13.15"
    assert "authorized cross-pin upgrade installs the pinned core digest" \
      test "$(sha256sum "$SB_BIN" | awk '{print $1}')" = \
      "$(jq -r '.versions["1.13.15"]["linux-amd64"].binary_sha256' "$APP_DIR/checksums.json")"
    assert "authorized cross-pin upgrade writes the new receipt" \
      jq -e '.version=="1.13.15"' "$root/data/core.json"
    assert "authorized cross-pin upgrade preserves state" \
      test "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$before_state"
    assert "authorized cross-pin upgrade validates with the new manager" \
      env -u SB_APP_DIR "$SB_APP_LINK/sb" validate
    assert "authorized cross-pin upgrade passes doctor" \
      env -u SB_APP_DIR "$SB_APP_LINK/sb" doctor --json
}

test_manager_upgrade_preserves_data() {
    local root before after password uuid cert_hash releases password_hash uuid_hash
    new_env
    root="$TEST_ROOT"
    init_env
    manager_baseline
    sb add ANYTLS --port 19001 --sni any.example.com --tls-mode self-signed --yes >/dev/null
    sb add VLESS --port 19002 --server-name www.icloud.com --yes >/dev/null
    before=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    password=$(jq -r '.instances[]|select(.protocol=="ANYTLS")|.password' \
      "$root/data/current/instances.json")
    uuid=$(jq -r '.instances[]|select(.protocol=="VLESS")|.uuid' \
      "$root/data/current/instances.json")
    cert_hash=$(find "$root/data/certs" -type f -exec sha256sum {} + |
      sort | sha256sum | awk '{print $1}')
    sb upgrade --source "$APP_DIR" --yes >/dev/null
    sb upgrade --source "$APP_DIR" --yes >/dev/null
    after=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    assert "manager upgrade preserves state" test "$after" = "$before"
    assert "manager upgrade preserves password" test \
      "$(jq -r '.instances[]|select(.protocol=="ANYTLS")|.password' \
        "$root/data/current/instances.json")" = "$password"
    assert "manager upgrade preserves UUID" test \
      "$(jq -r '.instances[]|select(.protocol=="VLESS")|.uuid' \
        "$root/data/current/instances.json")" = "$uuid"
    assert "manager upgrade preserves certificate hash" test \
      "$(find "$root/data/certs" -type f -exec sha256sum {} + |
        sort | sha256sum | awk '{print $1}')" = "$cert_hash"
    password_hash=$(printf '%s' "$password" | sha256sum | awk '{print $1}')
    uuid_hash=$(printf '%s' "$uuid" | sha256sum | awk '{print $1}')
    printf 'EVIDENCE upgrade_hashes state_before=%s state_after=%s password_sha256=%s uuid_sha256=%s cert_tree_sha256=%s\n' \
      "$before" "$after" "$password_hash" "$uuid_hash" "$cert_hash"
    releases=$(find "$root/opt/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)
    assert "manager upgrades use staged releases" test "$releases" -eq 3
    assert "manager app is atomic symlink" test -L "$root/opt/app"
}

test_hy2_hopping_matrix() {
    local root id before rc
    new_env
    root="$TEST_ROOT"
    init_env
    rc=0
    sb add HY2 --port 443 --sni hy.example.com --tls-mode insecure \
      --masquerade https://hy.example.com --hop-range 20000-21000 \
      --hop-interval 30 --yes >/dev/null 2>&1 || rc=$?
    assert "non-interactive hopping requires explicit acknowledgement" test "$rc" -ne 0
    sb add HY2 --port 443 --sni hy.example.com --tls-mode insecure \
      --masquerade https://hy.example.com --hop-range 20000-21000 \
      --hop-interval 30 --ack-port-hopping --yes >/dev/null
    id=$(jq -r '.instances|keys[0]' "$root/data/current/instances.json")
    assert "HY2 server keeps base port" jq -e '.inbounds[0].listen_port==443' "$root/data/current/output/config.json"
    assert "HY2 URI uses official range authority" rg -q '@node\.example\.com:20000-21000/' "$root/data/current/output/clients/uris.txt"
    assert "HY2 Clash range" jq -e '.proxies[0].ports=="20000-21000" and .proxies[0]["hop-interval"]==30' "$root/data/current/output/clients/clash.yaml"
    assert "HY2 sing-box range" jq -e '.outbounds[0].server_ports==["20000:21000"] and .outbounds[0].hop_interval=="30s"' "$root/data/current/output/clients/sing-box.json"
    assert "HY2 Surge range" rg -q 'port-hopping=20000-21000, port-hopping-interval=30' "$root/data/current/output/clients/surge.conf"
    assert "HY2 firewall redirect declared" jq -e '.instances[0].redirect=="udp:20000-21000 -> udp:443"' "$root/data/current/output/firewall-requirements.json"
    before=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    if sb edit "$id" --hop-range 21000-20000 --ack-port-hopping --yes >/dev/null 2>&1; then
        fail "HY2 reverse range rejected"
    else
        pass "HY2 reverse range rejected"
    fi
    assert "failed hop edit preserves state" test "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$before"
    for invalid_range in 0-100 400-500 20000-23000 65535-65536; do
        if sb edit "$id" --hop-range "$invalid_range" --ack-port-hopping --yes >/dev/null 2>&1; then
            fail "HY2 invalid range $invalid_range rejected"
        else
            pass "HY2 invalid range $invalid_range rejected"
        fi
    done
    assert "all invalid hop edits preserve state" test \
      "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$before"
}

test_root_routing_and_no_implicit_yes() {
    local root fake_sb generic failing args_file rc
    new_env
    root="$TEST_ROOT"
    fake_sb=$(mktemp -d)
    generic=$(mktemp -d)
    failing=$(mktemp -d)
    TEST_ROOTS+=("$fake_sb" "$generic" "$failing")
    args_file="$root/install.args"
    printf '%s\n' '#!/usr/bin/env bash' \
      'printf "%s\n" "$@" >"${SB_TEST_CAPTURE_ARGS:?}"' >"$fake_sb/install.sh"
    chmod 755 "$fake_sb/install.sh"
    SB_TEST_CAPTURE_ARGS="$args_file" "$APP_DIR/../file.sh" sb \
      --source-dir "$fake_sb" >/dev/null
    assert "root sb installer does not inject --yes" sh -c \
      "! grep -Fx -- '--yes' '$args_file'"

    printf '%s\n' '#!/usr/bin/env bash' 'printf "generic-ok\\n"' >"$generic/tool.sh"
    chmod 755 "$generic/tool.sh"
    GENERIC_INSTALL_ROOT="$root/generic-opt" GENERIC_COMMAND_ROOT="$root/generic-bin" \
      "$APP_DIR/../file.sh" demo --source-dir "$generic" --command tool.sh >/dev/null
    assert "root file.sh retains generic project routing" \
      test -x "$root/generic-opt/demo/tool.sh"
    assert "generic project command link is created" \
      test -L "$root/generic-bin/tool"

    mkdir -p "$root/generic-opt/faildemo"
    printf 'old-data\n' >"$root/generic-opt/faildemo/marker"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$failing/install.sh"
    chmod 755 "$failing/install.sh"
    rc=0
    GENERIC_INSTALL_ROOT="$root/generic-opt" GENERIC_COMMAND_ROOT="$root/generic-bin" \
      "$APP_DIR/../file.sh" faildemo --source-dir "$failing" >/dev/null 2>&1 || rc=$?
    assert "generic initialization failure returns nonzero" test "$rc" -ne 0
    assert "generic initialization failure restores previous project" \
      test -f "$root/generic-opt/faildemo/marker"

    new_env
    root="$TEST_ROOT"
    rc=0
    SB_SYSTEMCTL=/bin/false "$APP_DIR/install.sh" --source "$APP_DIR" \
      --endpoint node.example.com --yes >/dev/null 2>&1 || rc=$?
    assert "first sb initialization failure returns nonzero" test "$rc" -ne 0
    assert "failed first install removes broken manager app link" \
      test ! -e "$root/opt/app"
    assert "failed first install removes broken command link" \
      test ! -e "$root/bin/sb"
    assert "failed first install removes invalid release directory" sh -c \
      "! find '$root/opt/releases' -mindepth 1 -maxdepth 1 -type d | grep -q ."
}

test_no_hop_residue() {
    local root
    new_env
    root="$TEST_ROOT"
    init_env
    sb add HY2 --port 8443 --sni hy.example.com --tls-mode insecure \
      --masquerade https://hy.example.com --no-hop --yes >/dev/null
    assert "no-hop URI has no range parameter" sh -c "! rg -q 'mport|20000-' '$root/data/current/output/clients/uris.txt'"
    assert "no-hop Clash omits hopping" jq -e '.proxies[0] | (has("ports")|not) and (has("hop-interval")|not)' "$root/data/current/output/clients/clash.yaml"
    assert "no-hop sing-box omits hopping" jq -e '.outbounds[0] | has("server_port") and (has("server_ports")|not) and (has("hop_interval")|not)' "$root/data/current/output/clients/sing-box.json"
}

test_restart_and_rollback() {
    local root id before after
    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 11001 --yes >/dev/null
    id=$(jq -r '.instances|keys[0]' "$root/data/current/instances.json")
    sb edit "$id" --port 11002 --yes >/dev/null
    assert "publish restarts to prove generation load" rg -q '^restart ' "$root/runtime/systemctl.log"
    before=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    touch "$root/runtime/fail-restart-once"
    if sb edit "$id" --port 11003 --yes >/dev/null 2>&1; then
        fail "reload and restart failure returns nonzero"
    else
        pass "reload and restart failure returns nonzero"
    fi
    after=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    assert "failed publish rolls back state hash" test "$before" = "$after"
    assert "rollback status recorded and verified" jq -e \
      '.last_rollback.performed==true and .last_rollback.result=="success"' \
      "$root/data/status.json"
    touch "$root/runtime/fail-restart"
    if sb edit "$id" --port 11004 --yes >/dev/null 2>&1; then
        fail "persistent systemctl failure returns nonzero"
    else
        pass "persistent systemctl failure returns nonzero"
    fi
    assert "unrecoverable service rollback is reported honestly" jq -e \
      '.last_rollback.performed==true and
       .last_rollback.result=="service-restore-failed"' \
      "$root/data/status.json"
    assert "service restore failure is not conflated with a link restore failure" \
      jq -e '.last_publish.result=="rolled-back"' "$root/data/status.json"
}

test_last_node_semantics() {
    local root id
    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 12001 --yes >/dev/null
    id=$(jq -r '.instances|keys[0]' "$root/data/current/instances.json")
    sb disable "$id" --yes >/dev/null
    assert "disable last node writes empty config" jq -e '.inbounds==[]' "$root/data/current/output/config.json"
    assert "disable last node stops service" test ! -f "$root/runtime/active"
    sb enable "$id" --yes >/dev/null
    assert "enable last node starts service" test -f "$root/runtime/active"
    sb delete "$id" --yes >/dev/null
    assert "delete last node removes state" jq -e '.instances=={}' "$root/data/current/instances.json"
    assert "delete last node stops service" test ! -f "$root/runtime/active"
}

test_repeat_install_preserves_secrets() {
    local root state_hash cert_hash
    new_env
    root="$TEST_ROOT"
    init_env
    sb add ANYTLS --port 13001 --sni any.example.com --tls-mode self-signed --yes >/dev/null
    state_hash=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    cert_hash=$(find "$root/data/certs" -type f -exec sha256sum {} + | sort | sha256sum | awk '{print $1}')
    sb install --endpoint node.example.com --yes >/dev/null
    assert "repeat install preserves state hash" test "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$state_hash"
    assert "repeat install preserves certificate hash" test "$(find "$root/data/certs" -type f -exec sha256sum {} + | sort | sha256sum | awk '{print $1}')" = "$cert_hash"
}

test_concurrency_lock() {
    local root id rc=0 backup_rc=0
    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 14001 --yes >/dev/null
    id=$(jq -r '.instances|keys[0]' "$root/data/current/instances.json")
    touch "$root/runtime/sleep-restart"
    sb edit "$id" --port 14002 --yes >/dev/null &
    first_pid=$!
    sleep 0.2
    sb backup >/dev/null 2>&1 || backup_rc=$?
    sb edit "$id" --port 14003 --yes >/dev/null 2>&1 || rc=$?
    wait "$first_pid"
    assert "concurrent writer rejected with EX_TEMPFAIL" test "$rc" -eq 75
    assert "concurrent backup rejected with EX_TEMPFAIL" test "$backup_rc" -eq 75
    assert "transaction directories cleaned" sh -c "! find '$root/data/generations' -maxdepth 1 -name '.txn-*' | grep -q ."
}

test_endpoint_validation_and_dry_run() {
    local root before output_before cert_count_before cert_count_after address
    new_env
    root="$TEST_ROOT"
    sb install --endpoint node.example.com --yes >/dev/null
    for address in 10.0.0.1 100.64.0.1 127.0.0.1 169.254.1.1 172.16.0.1 \
      192.168.1.2 192.0.2.1 198.51.100.1 203.0.113.1 224.0.0.1 \
      :: ::1 fc00::10 fe80::1 ff02::1 2001:db8::1; do
        if sb endpoint set "$address" --yes >/dev/null 2>&1; then
            fail "non-global endpoint ${address} rejected"
        else
            pass "non-global endpoint ${address} rejected"
        fi
    done
    if sb endpoint set private.example.com --yes >/dev/null 2>&1; then
        fail "domain resolving to private address is rejected"
    else
        pass "domain resolving to private address is rejected"
    fi
    if sb endpoint set unresolved.example.com --yes >/dev/null 2>&1; then
        fail "unresolved endpoint domain is rejected"
    else
        pass "unresolved endpoint domain is rejected"
    fi
    sb endpoint set 2606:4700:4700::1111 --yes >/dev/null
    sb add SS --port 15000 --yes >/dev/null
    assert "IPv6 endpoint is bracketed in URI" rg -q '@\[2606:4700:4700::1111\]:15000' \
      "$root/data/current/output/clients/uris.txt"
    output_before=$(sha256sum "$root/data/current/output/clients/uris.txt" | awk '{print $1}')
    sb endpoint set node.example.com --yes >/dev/null
    assert "endpoint update regenerates client output" test \
      "$(sha256sum "$root/data/current/output/clients/uris.txt" | awk '{print $1}')" != "$output_before"
    sb listen set ipv4 --yes >/dev/null
    assert "IPv4 listen mode regenerates all inbounds" jq -e \
      '[.inbounds[].listen] | all(.=="0.0.0.0")' "$root/data/current/output/config.json"
    sb listen set dual --yes >/dev/null
    before=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    cert_count_before=$(find "$root/data/certs" -type f | wc -l)
    sb add ANYTLS --port 15001 --sni any.example.com --tls-mode self-signed --dry-run --yes >/dev/null
    cert_count_after=$(find "$root/data/certs" -type f | wc -l)
    assert "dry-run preserves state" test "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$before"
    assert "dry-run removes candidate certificates" test "$cert_count_before" -eq "$cert_count_after"
}

test_settings_schema_migration() {
    local root
    new_env
    root="$TEST_ROOT"
    mkdir -p "$root/etc"
    jq -n '{schema_version:1,endpoint:{
      mode:"domain",value:"node.example.com",allow_private:false,
      source:"explicit",updated_at:"2026-01-01T00:00:00Z"
    }}' >"$root/etc/settings.json"
    chmod 600 "$root/etc/settings.json"
    sb install --yes >/dev/null
    assert "settings v1 migrates to v2" jq -e \
      '.schema_version==2 and .listen.mode=="dual" and .listen.address=="::"' \
      "$root/etc/settings.json"
}

test_protocol_parameter_matrix() {
    local root state server client clash id
    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 21001 --method chacha20-ietf-poly1305 --yes >/dev/null
    sb add SS2022 --port 21002 --method 2022-blake3-aes-128-gcm --yes >/dev/null
    sb add ANYTLS --port 21003 --sni any.example.com --tls-mode self-signed --yes >/dev/null
    sb add VLESS --port 21004 --server-name www.icloud.com --yes >/dev/null
    sb add HY2 --port 21005 --sni hy.example.com --tls-mode insecure \
      --masquerade https://hy.example.com --no-hop --yes >/dev/null
    state="$root/data/current/instances.json"
    server="$root/data/current/output/config.json"
    client="$root/data/current/output/clients/sing-box.json"
    clash="$root/data/current/output/clients/clash.yaml"

    id=$(jq -r '.instances|to_entries[]|select(.value.protocol=="SS")|.key' "$state")
    assert "SS server/client matrix" jq -e --arg id "$id" --slurpfile s "$state" \
      --slurpfile c "$client" '
      $s[0].instances[$id] as $m |
      .inbounds[] | select(.tag=="in-"+$id) |
      .listen_port==$m.port and .method==$m.method and .password==$m.password and
      ($c[0].outbounds[]|select(.tag=="SS-"+$id)|
       .server_port==$m.port and .method==$m.method and .password==$m.password)
      ' "$server"
    id=$(jq -r '.instances|to_entries[]|select(.value.protocol=="SS2022")|.key' "$state")
    assert "SS2022 server/client matrix" jq -e --arg id "$id" --slurpfile s "$state" \
      --slurpfile c "$client" '
      $s[0].instances[$id] as $m |
      .inbounds[] | select(.tag=="in-"+$id) |
      .listen_port==$m.port and .method==$m.method and .password==$m.password and
      ($c[0].outbounds[]|select(.tag=="SS2022-"+$id)|
       .server_port==$m.port and .method==$m.method and .password==$m.password)
      ' "$server"
    id=$(jq -r '.instances|to_entries[]|select(.value.protocol=="ANYTLS")|.key' "$state")
    assert "AnyTLS server/client TLS matrix" jq -e --arg id "$id" --slurpfile s "$state" \
      --slurpfile c "$client" '
      $s[0].instances[$id] as $m |
      .inbounds[] | select(.tag=="in-"+$id) |
      .listen_port==$m.port and .users[0].password==$m.password and
      .tls.server_name==$m.tls.sni and
      ($c[0].outbounds[]|select(.tag=="ANYTLS-"+$id)|
       .server_port==$m.port and .password==$m.password and
       .tls.server_name==$m.tls.sni and
       .tls.certificate_public_key_sha256[0]==$m.tls.public_key_sha256)
      ' "$server"
    id=$(jq -r '.instances|to_entries[]|select(.value.protocol=="VLESS")|.key' "$state")
    assert "VLESS Reality server/client matrix" jq -e --arg id "$id" --slurpfile s "$state" \
      --slurpfile c "$client" '
      $s[0].instances[$id] as $m |
      .inbounds[] | select(.tag=="in-"+$id) |
      .listen_port==$m.port and .users[0].uuid==$m.uuid and
      .tls.reality.private_key==$m.private_key and
      .tls.reality.short_id[0]==$m.short_id and
      ($c[0].outbounds[]|select(.tag=="VLESS-"+$id)|
       .server_port==$m.port and .uuid==$m.uuid and
       .tls.server_name==$m.server_name and
       .tls.reality.public_key==$m.public_key and
       .tls.reality.short_id==$m.short_id)
      ' "$server"
    id=$(jq -r '.instances|to_entries[]|select(.value.protocol=="HY2")|.key' "$state")
    assert "HY2 server/client matrix" jq -e --arg id "$id" --slurpfile s "$state" \
      --slurpfile c "$client" '
      $s[0].instances[$id] as $m |
      .inbounds[] | select(.tag=="in-"+$id) |
      .listen_port==$m.port and .users[0].password==$m.password and
      .masquerade.url==$m.masquerade and .tls.server_name==$m.tls.sni and
      ($c[0].outbounds[]|select(.tag=="HY2-"+$id)|
       .server_port==$m.port and .password==$m.password and
       .tls.server_name==$m.tls.sni and .tls.insecure==true)
      ' "$server"
    assert "Mihomo output contains exactly all supported protocols" jq -e \
      '[.proxies[].type] | sort == ["anytls","hysteria2","ss","ss","vless"]' "$clash"
}

test_vless_three_mode_contract() {
    local root state server client clash vision_id reality_id ws_id
    local backup_id before export_file invalid_file legacy_file uri
    new_env
    root="$TEST_ROOT"
    init_env
    manager_baseline

    sb add VLESS --port 21101 --server-name www.icloud.com --yes >/dev/null
    sb add VLESS --port 21102 --mode reality \
      --server-name www.apple.com --yes >/dev/null
    sb add VLESS --port 21103 --mode ws --path /vless \
      --sni ws.example.com --tls-mode self-signed --yes >/dev/null

    state="$root/data/current/instances.json"
    server="$root/data/current/output/config.json"
    client="$root/data/current/output/clients/sing-box.json"
    clash="$root/data/current/output/clients/clash.yaml"
    vision_id=is01
    reality_id=is02
    ws_id=is03

    assert "VLESS default mode is vision-reality" jq -e \
      --arg id "$vision_id" '.instances[$id].mode=="vision-reality"' "$state"
    assert "VLESS compatibility mode is plain Reality" jq -e \
      --arg id "$reality_id" '.instances[$id].mode=="reality"' "$state"
    assert "VLESS WS mode stores only WS/TLS fields" jq -e --arg id "$ws_id" '
      .instances[$id] |
      .mode=="ws" and .path=="/vless" and (.tls|type=="object") and
      (has("private_key")|not) and (has("public_key")|not) and
      (has("short_id")|not) and (has("server_name")|not)
    ' "$state"

    assert "Vision Reality inbound and outbound flows match" jq -e \
      --arg id "$vision_id" --slurpfile c "$client" '
      (.inbounds[] | select(.tag=="in-"+$id) |
        .users[0].flow=="xtls-rprx-vision" and
        .tls.reality.enabled==true and (has("transport")|not)) and
      ($c[0].outbounds[] | select(.tag=="VLESS-"+$id) |
        .flow=="xtls-rprx-vision" and .tls.reality.enabled==true and
        (has("transport")|not))
    ' "$server"
    assert "plain Reality omits flow on both sides" jq -e \
      --arg id "$reality_id" --slurpfile c "$client" '
      (.inbounds[] | select(.tag=="in-"+$id) |
        (.users[0]|has("flow")|not) and .tls.reality.enabled==true) and
      ($c[0].outbounds[] | select(.tag=="VLESS-"+$id) |
        (has("flow")|not) and .tls.reality.enabled==true)
    ' "$server"
    assert "WS TLS inbound and outbound transports match" jq -e \
      --arg id "$ws_id" --slurpfile c "$client" '
      (.inbounds[] | select(.tag=="in-"+$id) |
        .transport=={type:"ws",path:"/vless"} and .tls.enabled==true and
        (.tls|has("reality")|not) and (.users[0]|has("flow")|not)) and
      ($c[0].outbounds[] | select(.tag=="VLESS-"+$id) |
        .transport=={type:"ws",path:"/vless"} and .tls.enabled==true and
        (.tls|has("reality")|not) and (has("flow")|not))
    ' "$server"

    assert "fixed core accepts all three VLESS server modes" \
      "$REAL_CORE" check -c "$server"
    assert "fixed core accepts all three VLESS client outbounds" \
      "$REAL_CORE" check -c "$client"

    uri=$(sb output "$vision_id" uri)
    assert "Vision Reality URI carries flow and Reality keys" sh -c \
      'case "$1" in *"security=reality"*"pbk="*"sid="*"type=tcp"*"flow=xtls-rprx-vision"*) exit 0;; *) exit 1;; esac' \
      sh "$uri"
    uri=$(sb output "$reality_id" uri)
    assert "plain Reality URI omits flow" sh -c \
      'case "$1" in *"security=reality"*"type=tcp"*) case "$1" in *"flow="*) exit 1;; *) exit 0;; esac;; *) exit 1;; esac' \
      sh "$uri"
    uri=$(sb output "$ws_id" uri)
    assert "WS TLS URI carries WS path, host and TLS" sh -c \
      'case "$1" in *"security=tls"*"type=ws"*"host=ws.example.com"*"path=%2Fvless"*) exit 0;; *) exit 1;; esac' \
      sh "$uri"

    assert "Mihomo three-mode VLESS contract" jq -e '
      (.proxies[] | select(.name=="VLESS-is01") |
        .network=="tcp" and .flow=="xtls-rprx-vision" and
        ((."reality-opts"."public-key"|length)>20)) and
      (.proxies[] | select(.name=="VLESS-is02") |
        .network=="tcp" and (has("flow")|not) and
        (."reality-opts"."short-id"|length)>0) and
      (.proxies[] | select(.name=="VLESS-is03") |
        .network=="ws" and .tls==true and ."ws-opts".path=="/vless" and
        (has("flow")|not) and (has("reality-opts")|not))
    ' "$clash"

    sb edit "$vision_id" --mode reality --yes >/dev/null
    assert "edit Vision Reality to plain Reality removes both flows" jq -e \
      --arg id "$vision_id" --slurpfile c "$root/data/current/output/clients/sing-box.json" '
      (.inbounds[] | select(.tag=="in-"+$id) | .users[0]|has("flow")|not) and
      ($c[0].outbounds[] | select(.tag=="VLESS-"+$id)|has("flow")|not)
    ' "$root/data/current/output/config.json"
    sb edit "$vision_id" --mode vision-reality --yes >/dev/null
    sb edit "$ws_id" --path /vless-edited --yes >/dev/null
    assert "edit WS path updates both render sides" jq -e \
      --arg id "$ws_id" --slurpfile c "$root/data/current/output/clients/sing-box.json" '
      (.inbounds[] | select(.tag=="in-"+$id) | .transport.path=="/vless-edited") and
      ($c[0].outbounds[] | select(.tag=="VLESS-"+$id) |
        .transport.path=="/vless-edited")
    ' "$root/data/current/output/config.json"
    sb edit "$reality_id" --mode ws --path /converted \
      --sni converted.example.com --tls-mode self-signed --yes >/dev/null
    assert "edit Reality to WS removes Reality material" jq -e \
      --arg id "$reality_id" '
      .instances[$id] |
      .mode=="ws" and .path=="/converted" and (.tls|type=="object") and
      (has("private_key")|not) and (has("server_name")|not)
    ' "$state"
    sb edit "$reality_id" --mode reality \
      --server-name www.apple.com --yes >/dev/null
    assert "edit WS to Reality regenerates Reality material" jq -e \
      --arg id "$reality_id" '
      .instances[$id] |
      .mode=="reality" and (.private_key|length)>20 and
      (.public_key|length)>20 and (.short_id|length)>0 and
      (has("tls")|not) and (has("path")|not)
    ' "$state"

    if sb add VLESS --port 21104 --mode ws --path /bad --sni bad.example.com \
      --tls-mode self-signed --server-name forbidden.example.com --yes >/dev/null 2>&1; then
        fail "WS plus Reality fields is rejected"
    else
        pass "WS plus Reality fields is rejected"
    fi
    if sb add VLESS --port 21104 --mode reality --server-name www.example.com \
      --path /bad --yes >/dev/null 2>&1; then
        fail "Reality plus WS fields is rejected"
    else
        pass "Reality plus WS fields is rejected"
    fi
    before=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    invalid_file="$root/invalid-vless-state.json"
    jq '.instances.is03.private_key="forbidden-mode-mix"' "$state" >"$invalid_file"
    if sb state import "$invalid_file" --yes >/dev/null 2>&1; then
        fail "state import rejects mixed WS and Reality schema"
    else
        pass "state import rejects mixed WS and Reality schema"
    fi
    assert "rejected VLESS import leaves state unchanged" test \
      "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$before"

    legacy_file="$root/legacy-vless-state.json"
    jq 'del(.instances.is02.mode)' "$state" >"$legacy_file"
    sb state import "$legacy_file" --yes >/dev/null
    assert "pre-mode VLESS state remains plain Reality after import" jq -e \
      --arg id "$reality_id" --slurpfile c "$root/data/current/output/clients/sing-box.json" '
      (.inbounds[] | select(.tag=="in-"+$id) | .users[0]|has("flow")|not) and
      ($c[0].outbounds[] | select(.tag=="VLESS-"+$id)|has("flow")|not)
    ' "$root/data/current/output/config.json"
    sb edit "$reality_id" --mode reality --yes >/dev/null

    for vision_id in is01 is02 is03; do
        sb disable "$vision_id" --yes >/dev/null
        sb enable "$vision_id" --yes >/dev/null
    done
    assert "three VLESS modes survive disable-enable" jq -e \
      '[.instances[].enabled] | all' "$state"

    backup_id=$(basename "$(sb backup)")
    before=$(sha256sum "$state" | awk '{print $1}')
    sb edit "$reality_id" --port 21112 --yes >/dev/null
    sb restore "$backup_id" --yes >/dev/null
    assert "VLESS backup restore preserves complete three-mode state" test \
      "$(sha256sum "$state" | awk '{print $1}')" = "$before"

    export_file="$root/vless-state-export.json"
    sb state export --show-secrets >"$export_file"
    sb delete "$reality_id" --yes >/dev/null
    sb state import "$export_file" --yes >/dev/null
    assert "VLESS state export import round-trip is lossless" test \
      "$(sha256sum "$state" | awk '{print $1}')" = "$before"

    sb upgrade --source "$APP_DIR" --yes >/dev/null
    assert "manager upgrade preserves complete VLESS state" test \
      "$(sha256sum "$state" | awk '{print $1}')" = "$before"
    assert "post-upgrade fixed core accepts VLESS server config" \
      "$REAL_CORE" check -c "$root/data/current/output/config.json"
    assert "post-upgrade fixed core accepts VLESS client config" \
      "$REAL_CORE" check -c "$root/data/current/output/clients/sing-box.json"

    for vision_id in is01 is02 is03; do
        sb delete "$vision_id" --yes >/dev/null
    done
    assert "all three VLESS modes delete cleanly" jq -e '.instances=={}' "$state"
}

test_backup_restore_schema_json_doctor() {
    local root id backup_id before
    new_env
    root="$TEST_ROOT"
    init_env
    sb add ANYTLS --port 22001 --sni any.example.com --tls-mode self-signed --yes >/dev/null
    id=$(jq -r '.instances|keys[0]' "$root/data/current/instances.json")
    before=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    backup_id=$(basename "$(sb backup)")
    assert "manual backup validates" test -f "$root/backups/$backup_id/metadata.json"
    assert "manual backup files are private" sh -c \
      "! find '$root/backups/$backup_id' -type f ! \\( -perm 600 -o -perm 700 \\) | grep -q ."
    mv "$root/data/certs" "$root/data/certs-away"
    mkdir -m 700 "$root/data/certs"
    sb restore "$backup_id" --yes >/dev/null
    assert "restore validates and recovers certificates absent from live storage" \
      test -f "$(jq -r ".instances.$id.tls.certificate_path" "$root/data/current/instances.json")"
    rm -rf -- "$root/data/certs-away"
    assert "backup JSON output parses" jq -e '.result=="success" and (.id|length)>0' \
      <(sb backup --json)
    if sb backup --dry-run >/dev/null 2>&1; then
        fail "unsupported backup dry-run is rejected"
    else
        pass "unsupported backup dry-run is rejected"
    fi
    sb edit "$id" --port 22002 --yes >/dev/null
    sb restore "$backup_id" --yes >/dev/null
    assert "restore returns original state hash" test \
      "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$before"
    assert "status JSON parses" jq -e '.enabled==true and .instances.total==1' \
      <(sb status --json)
    assert "doctor JSON is read-only and passes" jq -e '.passed==true' <(sb doctor --json)
    assert "state export redacts secrets" sh -c \
      "! '$APP_DIR/sb' state export | grep -q 'BEGIN PRIVATE KEY\\|\"password\": \"[^[]'"

    jq '.schema_version=999' "$root/data/current/instances.json" \
      >"$root/data/current/instances.new"
    mv "$root/data/current/instances.new" "$root/data/current/instances.json"
    if sb state validate >/dev/null 2>&1; then
        fail "unknown future state schema rejected"
    else
        pass "unknown future state schema rejected"
    fi
}

test_certificate_rotation_transaction() {
    local root id before after
    new_env
    root="$TEST_ROOT"
    init_env
    sb add HY2 --port 23001 --sni hy.example.com --tls-mode self-signed \
      --masquerade https://hy.example.com --no-hop --yes >/dev/null
    id=$(jq -r '.instances|keys[0]' "$root/data/current/instances.json")
    before=$(jq -r ".instances.$id.tls.certificate_sha256" "$root/data/current/instances.json")
    sb edit "$id" --rotate-certificate --yes >/dev/null
    after=$(jq -r ".instances.$id.tls.certificate_sha256" "$root/data/current/instances.json")
    assert "self-signed certificate rotation changes fingerprint" test "$after" != "$before"
    assert "rotated certificate still covers SNI" openssl x509 \
      -in "$(jq -r ".instances.$id.tls.certificate_path" "$root/data/current/instances.json")" \
      -noout -checkhost hy.example.com
}

# A documented default must survive a non-interactive run.
#
# prompt_value() used to return failure whenever stdin was not a TTY, throwing
# away the default it had been handed. The TLS-mode call site is the only one
# that supplies a default and the only one with no error message of its own, so
# `sb add hy2 --yes` and `sb add anytls --yes` without --tls-mode exited 1 with
# no output at all. Required arguments must keep failing loudly.
test_noninteractive_tls_mode_default() {
    local root out rc G

    new_env
    root="$TEST_ROOT"
    init_env

    # 1. HY2 without --tls-mode falls back to the documented default.
    assert "HY2 adds non-interactively without --tls-mode" \
      sb add HY2 --port 24501 --sni hy2.example.com --yes
    assert "HY2 defaulted to self-signed" jq -e \
      '[.instances[]|select(.protocol=="HY2")][0].tls.mode == "self-signed"' \
      "$root/data/current/instances.json"

    # 2. AnyTLS likewise.
    assert "AnyTLS adds non-interactively without --tls-mode" \
      sb add ANYTLS --port 24502 --sni anytls.example.com --yes
    assert "AnyTLS defaulted to self-signed" jq -e \
      '[.instances[]|select(.protocol=="ANYTLS")][0].tls.mode == "self-signed"' \
      "$root/data/current/instances.json"

    # 3. Generated state and configuration remain valid.
    assert "state is valid with defaulted TLS mode" sb validate
    G="$root/data/current"
    assert "server config passes the pinned core" \
      "$REAL_CORE" check -c "$G/output/config.json"
    assert "client config passes the pinned core" \
      "$REAL_CORE" check -c "$G/output/clients/sing-box.json"

    # 4. An explicit value still overrides the default.
    assert "explicit --tls-mode is honoured" \
      sb add ANYTLS --port 24503 --sni explicit.example.com --tls-mode insecure --yes
    assert "explicit insecure recorded, not the default" jq -e \
      '[.instances[]|select(.port==24503)][0].tls.mode == "insecure"' \
      "$root/data/current/instances.json"

    # 5. Arguments with no default stay required, with their existing messages.
    out=$(sb add HY2 --port 24504 --yes 2>&1) && rc=0 || rc=$?
    assert "missing --sni still fails" test "$rc" -ne 0
    assert "missing --sni keeps its message" sh -c \
      "printf '%s' \"$out\" | grep -q -- '--sni is required'"

    out=$(sb add SS --yes 2>&1) && rc=0 || rc=$?
    assert "missing --port still fails" test "$rc" -ne 0
    assert "missing --port keeps its message" sh -c \
      "printf '%s' \"$out\" | grep -q -- '--port is required'"

    out=$(sb add vless --port 24505 --yes 2>&1) && rc=0 || rc=$?
    assert "missing --server-name still fails" test "$rc" -ne 0
    assert "missing --server-name keeps its message" sh -c \
      "printf '%s' \"$out\" | grep -q -- '--server-name is required'"

    # 6. No failure may be silent: every rejection above printed something.
    out=$(sb add ANYTLS --port 24506 --yes 2>&1) && rc=0 || rc=$?
    assert "a rejected add is never silent" sh -c \
      "test -n \"\$(printf '%s' \"$out\" | tr -d '[:space:]')\""

    # 7. The prompt/default contract itself, lifted straight out of the
    #    shipping script so the test cannot drift from the implementation.
    local probe="$root/prompt-probe.sh"
    { sed -n '/^prompt_value()/,/^}/p' "$APP_DIR/sb"
      printf '%s\n' 'prompt_value "$@"'; } >"$probe"

    out=$(bash "$probe" "TLS mode" "self-signed" </dev/null) && rc=0 || rc=$?
    assert "non-TTY with a default succeeds" test "$rc" -eq 0
    assert "non-TTY returns that default" test "$out" = "self-signed"
    out=$(bash "$probe" "Listen port" </dev/null) && rc=0 || rc=$?
    assert "non-TTY without a default still fails" test "$rc" -ne 0

    # 8. Interactive behaviour is unchanged. `script` supplies a real PTY so
    #    the TTY branch is genuinely exercised, not simulated.
    if command -v script >/dev/null 2>&1; then
        out=$(printf 'insecure\n' | script -qec "bash $probe 'TLS mode' self-signed" /dev/null 2>/dev/null | tr -d '\r')
        assert "interactive answer overrides the default" sh -c \
          "printf '%s' \"$out\" | grep -q insecure"
        out=$(printf '\n' | script -qec "bash $probe 'TLS mode' self-signed" /dev/null 2>/dev/null | tr -d '\r')
        assert "empty interactive answer falls back to the default" sh -c \
          "printf '%s' \"$out\" | grep -q self-signed"
    else
        pass "interactive answer overrides the default (skipped: no script(1))"
        pass "empty interactive answer falls back to the default (skipped: no script(1))"
    fi
}

test_tls_mode_contracts() {
    local root cert key
    new_env
    root="$TEST_ROOT"
    init_env
    cert="$root/source-cert.pem"
    key="$root/source-key.pem"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$key" -out "$cert" -subj '/CN=tls.example.com' \
      -addext 'subjectAltName=DNS:tls.example.com' >/dev/null 2>&1
    if sb add ANYTLS --port 24001 --sni tls.example.com --tls-mode trusted \
      --certificate "$cert" --key "$key" --yes >/dev/null 2>&1; then
        fail "trusted mode rejects an untrusted self-signed chain"
    else
        pass "trusted mode rejects an untrusted self-signed chain"
    fi
    sb add ANYTLS --port 24001 --sni tls.example.com --tls-mode provided \
      --certificate "$cert" --key "$key" --yes >/dev/null
    assert "provided mode emits verified public-key pin" jq -e \
      '.outbounds[0].tls.insecure==false and
       (.outbounds[0].tls.certificate_public_key_sha256[0]|length)>20' \
      "$root/data/current/output/clients/sing-box.json"
    assert "provided certificate and key are private" sh -c \
      "! find '$root/data/certs' -type f ! -perm 600 | grep -q ."
}

test_root_installer_and_core_archive() {
    local root state_hash archive
    new_env
    root="$TEST_ROOT"
    archive="/tmp/sb-core-1.13.15/sing-box.tar.gz"
    "$APP_DIR/../file.sh" sb --source-dir "$APP_DIR" --endpoint node.example.com --yes >/dev/null
    assert "root installer creates manager command" test -L "$root/bin/sb"
    assert "root installer creates systemd unit" test -f "$root/systemd/sb-core.service"
    state_hash=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    "$APP_DIR/../file.sh" sb --source-dir "$APP_DIR" --endpoint node.example.com --yes >/dev/null
    assert "root installer repeat preserves state" test \
      "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$state_hash"

    export SB_BIN="$root/bin/staged-sing-box"
    export SB_CORE_ARCHIVE="$archive"
    sb core install >/dev/null
    assert "pinned archive installs expected core" test \
      "$("$SB_BIN" version | awk 'NR==1{print $3}')" = "1.13.15"
    rm -f "$SB_BIN"
    if SB_CORE_SHA256_OVERRIDE="$(printf '0%.0s' {1..64})" sb core install >/dev/null 2>&1; then
        fail "core checksum mismatch rejected"
    else
        pass "core checksum mismatch rejected"
    fi
    assert "checksum failure does not install binary" test ! -e "$SB_BIN"
}

test_core_upgrade_flow() {
    local root before backup_count
    new_env
    root="$TEST_ROOT"
    mkdir -p "$root/bin"
    cp "$REAL_CORE" "$root/bin/sing-box"
    chmod 755 "$root/bin/sing-box"
    export SB_BIN="$root/bin/sing-box"
    export SB_CORE_ARCHIVE="/tmp/sb-core-1.13.15/sing-box.tar.gz"
    init_env
    sb add SS --port 25001 --yes >/dev/null
    before=$(sha256sum "$SB_BIN" | awk '{print $1}')
    sb core upgrade --yes >/dev/null
    assert "explicit core upgrade keeps expected binary hash" test \
      "$(sha256sum "$SB_BIN" | awk '{print $1}')" = "$before"
    backup_count=$(find "$root/backups" -name sing-box -type f | wc -l)
    assert "core upgrade backs up previous binary" test "$backup_count" -ge 1
    assert "active core upgrade restarts service" rg -q '^restart ' \
      "$root/runtime/systemctl.log"

    "$SB_SYSTEMCTL" stop sb-core
    sb core upgrade --yes >/dev/null
    assert "core upgrade restores an unexpectedly inactive service with enabled nodes" \
      test -f "$root/runtime/active"

    touch "$root/runtime/fail-restart"
    if sb core upgrade --yes >/dev/null 2>&1; then
        fail "core runtime verification failure is nonzero"
    else
        pass "core runtime verification failure is nonzero"
    fi
    assert "failed core upgrade restores binary hash" test \
      "$(sha256sum "$SB_BIN" | awk '{print $1}')" = "$before"
}

test_version_and_failure_messages() {
    local root output rc=0
    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 16001 --yes >/dev/null
    output=$(sb version 2>&1)
    if grep -q 'local: can only' <<<"$output"; then
        fail "sb version has no local error"
    else
        pass "sb version has no local error"
    fi
    if SB_SYSTEMCTL=/bin/false sb reload --yes >"$SB_TEST_OUTPUT_FILE" 2>&1; then
        fail "systemctl failure is nonzero"
    else
        pass "systemctl failure is nonzero"
    fi
    assert "systemctl failure does not claim publish success" \
      sh -c "! grep -q 'publish completed' '$SB_TEST_OUTPUT_FILE'"
    sb add SS --port >/dev/null 2>&1 || rc=$?
    assert "missing option value returns EX_USAGE" test "$rc" -eq 64
    rc=0
    sb restore ../../etc --yes >/dev/null 2>&1 || rc=$?
    assert "backup path traversal returns EX_USAGE" test "$rc" -eq 64
}

test_backup_failure_atomicity() {
    local root before_count after_count before_state point rc
    new_env
    root="$TEST_ROOT"
    init_env
    sb add ANYTLS --port 26001 --sni backup.example.com \
      --tls-mode self-signed --yes >/dev/null
    before_count=$(find "$root/backups" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l)
    for point in state-copy generation-copy cert-copy settings-copy metadata-write target-dir; do
        rc=0
        SB_TEST_BACKUP_FAIL_AT="$point" sb backup >/dev/null 2>&1 || rc=$?
        assert "backup fault ${point} returns nonzero" test "$rc" -ne 0
        after_count=$(find "$root/backups" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l)
        assert "backup fault ${point} publishes no visible backup" \
          test "$after_count" -eq "$before_count"
        assert "backup fault ${point} removes candidate" sh -c \
          "! find '$root/backups' -mindepth 1 -maxdepth 1 -type d -name '.backup-*' | grep -q ."
    done
    before_state=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    rc=0
    SB_TEST_BACKUP_FAIL_AT=state-copy sb add SS --port 26002 --yes >/dev/null 2>&1 || rc=$?
    assert "publish stops when pre-publish backup fails" test "$rc" -ne 0
    assert "backup failure leaves live state unchanged" test \
      "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$before_state"
}

test_settings_transaction_concurrency_and_rollback() {
    local root before_settings before_generation rc first_backup
    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 26101 --yes >/dev/null
    before_settings=$(sha256sum "$root/data/current/settings.json" | awk '{print $1}')
    before_generation=$(generation_hashes "$root")
    touch "$root/runtime/fail-restart-once"
    rc=0
    sb endpoint set rollback.example.com --yes >/dev/null 2>&1 || rc=$?
    assert "settings publish failure returns nonzero" test "$rc" -ne 0
    assert "settings rollback restores settings" test \
      "$(sha256sum "$root/data/current/settings.json" | awk '{print $1}')" = "$before_settings"
    assert "settings rollback restores state/config/output generation" test \
      "$(generation_hashes "$root")" = "$before_generation"
    touch "$root/runtime/fail-restart-once"
    rc=0
    sb install --endpoint install-rollback.example.com --listen-mode ipv4 \
      --yes >/dev/null 2>&1 || rc=$?
    assert "combined install endpoint/listen failure returns nonzero" test "$rc" -ne 0
    assert "combined install endpoint/listen failure rolls both settings back" test \
      "$(sha256sum "$root/data/current/settings.json" | awk '{print $1}')" = "$before_settings"

    first_backup=$(basename "$(sb backup)")
    touch "$root/runtime/sleep-restart"
    sb endpoint set concurrent-a.example.com --yes >/dev/null 2>&1 &
    local writer_pid=$!
    for _ in {1..30}; do
        if ! flock -n "$root/lock/manager.lock" true; then break; fi
        sleep 0.1
    done
    rc=0
    sb add SS --port 26102 --yes >/dev/null 2>&1 || rc=$?
    assert "endpoint update versus node add returns EX_TEMPFAIL" test "$rc" -eq 75
    rc=0
    sb backup >/dev/null 2>&1 || rc=$?
    assert "endpoint update versus backup returns EX_TEMPFAIL" test "$rc" -eq 75
    rc=0
    sb restore "$first_backup" --yes >/dev/null 2>&1 || rc=$?
    assert "endpoint update versus restore returns EX_TEMPFAIL" test "$rc" -eq 75
    rc=0
    sb endpoint set concurrent-b.example.com --yes >/dev/null 2>&1 || rc=$?
    assert "two endpoint writers use one global lock" test "$rc" -eq 75
    wait "$writer_pid"
    rm -f "$root/runtime/sleep-restart"

    touch "$root/runtime/sleep-restart"
    sb listen set ipv4 --yes >/dev/null 2>&1 &
    writer_pid=$!
    for _ in {1..30}; do
        if ! flock -n "$root/lock/manager.lock" true; then break; fi
        sleep 0.1
    done
    rc=0
    sb edit is01 --port 26103 --yes >/dev/null 2>&1 || rc=$?
    assert "listen update versus node edit returns EX_TEMPFAIL" test "$rc" -eq 75
    wait "$writer_pid"
    rm -f "$root/runtime/sleep-restart"
    assert "final settings and manifest listen mode agree" jq -e \
      --slurpfile settings "$root/data/current/settings.json" \
      '.listen.mode==$settings[0].listen.mode and .listen.address==$settings[0].listen.address' \
      "$root/data/current/output/manifest.json"
}

test_listener_ownership_and_generation() {
    local root before rc
    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 26201 --yes >/dev/null
    touch "$root/runtime/wrong-pid"
    "$SB_SYSTEMCTL" restart sb-core >/dev/null
    if sb doctor --json >/dev/null 2>&1; then
        fail "other process on expected port is rejected"
    else
        pass "other process on expected port is rejected"
    fi
    rm -f "$root/runtime/wrong-pid"
    "$SB_SYSTEMCTL" restart sb-core >/dev/null
    rm -f "$root/runtime/sockets.tsv"
    if sb doctor --json >/dev/null 2>&1; then
        fail "active sb-core without socket is rejected"
    else
        pass "active sb-core without socket is rejected"
    fi
    "$SB_SYSTEMCTL" restart sb-core >/dev/null
    touch "$root/runtime/wrong-address"
    "$SB_SYSTEMCTL" restart sb-core >/dev/null
    if sb doctor --json >/dev/null 2>&1; then
        fail "wrong listen address is rejected"
    else
        pass "wrong listen address is rejected"
    fi
    rm -f "$root/runtime/wrong-address"
    "$SB_SYSTEMCTL" restart sb-core >/dev/null

    before=$(generation_hashes "$root")
    touch "$root/runtime/stale-generation"
    rc=0
    sb edit is01 --port 26202 --yes >/dev/null 2>&1 || rc=$?
    assert "restart success with stale generation is rejected" test "$rc" -ne 0
    assert "stale generation publish rolls back all derived data" \
      test "$(generation_hashes "$root")" = "$before"
    rm -f "$root/runtime/stale-generation"
    "$SB_SYSTEMCTL" restart sb-core >/dev/null

    printf 'tcp\t::\t26201\t99999\told\nudp\t::\t26201\t99999\told\n' \
      >"$root/runtime/old-socket.tsv"
    rc=0
    sb delete is01 --yes >/dev/null 2>&1 || rc=$?
    assert "removed socket residue rejects delete publish" test "$rc" -ne 0
    assert "failed delete preserves node" jq -e '.instances|length==1' \
      "$root/data/current/instances.json"
    rm -f "$root/runtime/old-socket.tsv"
}

# --- MEDIUM-01: expected/observed decoupling ------------------------------
#
# The mock derives observed sockets from config.json (what a daemon binds),
# never from manifest.json (what the verifier expects). These tests drive the
# observed side directly so a divergence between the two is provably detected.

observe_socket() {
    # observe_socket <runtime> <network> <address> <port> <pid> <generation>
    printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" >>"$1/observed-sockets.tsv"
}

observe_reset() {
    rm -f "$1/observed-sockets.tsv" "$1/observed-generation" "$1/observed-mainpid"
}

test_listener_expected_observed_divergence() {
    local root runtime generation cases description
    new_env
    root="$TEST_ROOT"
    runtime="$root/runtime"
    init_env
    sb add SS --port 26401 --yes >/dev/null
    generation=$(jq -r '.generation_id' "$root/data/current/output/manifest.json")

    assert "config-derived observation satisfies the manifest" \
      sb doctor --json >/dev/null

    # Each case replaces the observed world with one deliberate divergence from
    # the expected manifest (tcp+udp on :: port 26401 owned by MainPID).
    cases=(
      "expected TCP observed UDP only|udp|::|26401|MAINPID"
      "expected IPv4-mapped observed IPv6 literal|tcp|127.0.0.1|26401|MAINPID"
      "observed port differs|tcp|::|26999|MAINPID"
      "observed PID differs|tcp|::|26401|99999"
    )
    for entry in "${cases[@]}"; do
        IFS='|' read -r description network address port pid <<<"$entry"
        observe_reset "$runtime"
        observe_socket "$runtime" "$network" "$address" "$port" "$pid" "$generation"
        "$SB_SYSTEMCTL" restart sb-core >/dev/null 2>&1 || true
        if sb doctor --json >/dev/null 2>&1; then
            fail "listener verifier rejects: $description"
        else
            pass "listener verifier rejects: $description"
        fi
    done

    # A missing socket and a surplus stale socket.
    observe_reset "$runtime"
    observe_socket "$runtime" tcp "::" 26401 MAINPID "$generation"
    "$SB_SYSTEMCTL" restart sb-core >/dev/null 2>&1 || true
    if sb doctor --json >/dev/null 2>&1; then
        fail "listener verifier rejects: one expected socket missing"
    else
        pass "listener verifier rejects: one expected socket missing"
    fi

    # Loaded generation divergence: process cwd points at an older generation.
    observe_reset "$runtime"
    mkdir -p "$root/other-generation"
    printf '%s\n' "$root/other-generation" >"$runtime/observed-generation"
    "$SB_SYSTEMCTL" restart sb-core >/dev/null 2>&1 || true
    if sb doctor --json >/dev/null 2>&1; then
        fail "listener verifier rejects: loaded generation differs"
    else
        pass "listener verifier rejects: loaded generation differs"
    fi

    # MainPID divergence reported by systemd itself.
    observe_reset "$runtime"
    printf '99999\n' >"$runtime/observed-mainpid"
    "$SB_SYSTEMCTL" restart sb-core >/dev/null 2>&1 || true
    if sb doctor --json >/dev/null 2>&1; then
        fail "listener verifier rejects: MainPID does not own the sockets"
    else
        pass "listener verifier rejects: MainPID does not own the sockets"
    fi
    observe_reset "$runtime"

    assert "mock-systemctl never reads expected_listeners" sh -c \
      "! rg -q 'expected_listeners' '$APP_DIR/tests/fixtures/mock-systemctl'"
    assert "mock-ss never reads the generation manifest" sh -c \
      "! rg -q 'manifest' '$APP_DIR/tests/fixtures/mock-ss'"
}

# --- MEDIUM-02: endpoint special-purpose classification -------------------

test_endpoint_special_purpose_matrix() {
    local address expected verdict
    # Samples taken from the IANA IPv4/IPv6 Special-Purpose Address Registries,
    # plus the three addresses the previous review observed being accepted.
    local -a matrix=(
      "0.0.0.0 reject"         "10.1.2.3 reject"        "127.0.0.1 reject"
      "100.64.0.1 reject"      "169.254.1.1 reject"     "172.16.0.1 reject"
      "192.0.0.1 reject"       "192.0.2.1 reject"       "192.31.196.1 reject"
      "192.52.193.1 reject"    "192.88.99.1 reject"     "192.168.1.1 reject"
      "192.175.48.1 reject"    "198.18.0.1 reject"      "198.51.100.1 reject"
      "203.0.113.1 reject"     "224.0.0.1 reject"       "240.0.0.1 reject"
      "255.255.255.255 reject"
      "8.8.8.8 accept"         "1.1.1.1 accept"         "192.0.3.1 accept"
      "172.32.0.1 accept"      "100.128.0.1 accept"     "198.20.0.1 accept"
      ":: reject"              "::1 reject"             "64:ff9b::1 reject"
      "100::1 reject"          "2001::1 reject"         "2001:2::1 reject"
      "2001:20::1 reject"      "2001:db8::1 reject"     "2002::1 reject"
      "3fff::1 reject"         "5f00::1 reject"         "fc00::1 reject"
      "fd12:3456::1 reject"    "fe80::1 reject"         "ff02::1 reject"
      "2606:4700:4700::1111 accept" "2400:cb00::1 accept"
      "2a00:1450:4001::1 accept"    "2001:db9::1 accept"
    )
    local entry failures=0
    for entry in "${matrix[@]}"; do
        read -r address expected <<<"$entry"
        if bash -c 'source "$1/core/common.sh"; endpoint_valid "$2" false' \
          _ "$APP_DIR" "$address" >/dev/null 2>&1; then
            verdict=accept
        else
            verdict=reject
        fi
        [[ "$verdict" == "$expected" ]] || {
            printf '  endpoint %s: got %s want %s\n' "$address" "$verdict" "$expected" >&2
            failures=$((failures + 1))
        }
    done
    assert "IANA special-purpose endpoint matrix classifies all samples" \
      test "$failures" -eq 0

    local root
    new_env
    root="$TEST_ROOT"
    init_env
    # The three addresses the review observed being wrongly accepted.
    for address in 2001::1 2001:2::1 3fff::1; do
        if sb endpoint set "$address" --yes >/dev/null 2>&1; then
            fail "special-purpose endpoint rejected: $address"
        else
            pass "special-purpose endpoint rejected: $address"
        fi
    done
    assert "rejected endpoints never reach live settings" \
      test "$(jq -r '.endpoint.value' "$root/data/current/settings.json")" = node.example.com

    # The override is a separate flag: --yes alone must not bypass the policy.
    if sb endpoint set 10.0.0.1 --yes >/dev/null 2>&1; then
        fail "--yes alone does not bypass the special-purpose policy"
    else
        pass "--yes alone does not bypass the special-purpose policy"
    fi
    sb endpoint set 10.0.0.1 --allow-private-endpoint --yes >"$SB_TEST_OUTPUT_FILE" 2>&1
    assert "explicit override is accepted and flagged as risky" \
      rg -q 'special-purpose address accepted only because' "$SB_TEST_OUTPUT_FILE"
}

test_core_digest_adversarial() {
    local root fake_dir bad_app rc wrong_archive wrong_hash
    new_env
    root="$TEST_ROOT"
    init_env
    printf '%s\n' '#!/usr/bin/env bash' \
      'if [[ "${1:-}" == version ]]; then echo "sing-box version 1.13.15"; else exit 0; fi' \
      >"$root/bin/sing-box"
    chmod 755 "$root/bin/sing-box"
    if sb doctor --json >/dev/null 2>&1; then
        fail "same-version forged core is rejected by digest"
    else
        pass "same-version forged core is rejected by digest"
    fi
    rc=0
    sb add SS --port 26701 --yes >/dev/null 2>&1 || rc=$?
    assert "ordinary node operation rejects an untrusted core" test "$rc" -ne 0
    assert "ordinary node operation never replaces the core" rg -q \
      'sing-box version 1.13.15' "$root/bin/sing-box"
    sb core install >/dev/null
    assert "same-version forged core is repaired" test \
      "$(sha256sum "$root/bin/sing-box" | awk '{print $1}')" = \
      "$(jq -r '.versions["1.13.15"]["linux-amd64"].binary_sha256' "$APP_DIR/checksums.json")"

    chmod 600 "$root/bin/sing-box"
    if sb doctor --json >/dev/null 2>&1; then
        fail "correct digest but non-executable core is rejected"
    else
        pass "correct digest but non-executable core is rejected"
    fi
    chmod 755 "$root/bin/sing-box"

    bad_app=$(mktemp -d)
    TEST_ROOTS+=("$bad_app")
    cp -a "$APP_DIR/." "$bad_app/"
    jq '.versions["1.13.15"]["linux-amd64"].sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
      "$bad_app/checksums.json" >"$bad_app/checksums.new"
    mv "$bad_app/checksums.new" "$bad_app/checksums.json"
    rc=0
    SB_APP_DIR="$bad_app" "$bad_app/sb" core install >/dev/null 2>&1 || rc=$?
    assert "tampered checksum source is rejected" test "$rc" -ne 0

    fake_dir=$(mktemp -d)
    TEST_ROOTS+=("$fake_dir")
    printf '%s\n' '#!/usr/bin/env bash' 'printf "mips64\\n"' >"$fake_dir/uname"
    chmod 755 "$fake_dir/uname"
    rc=0
    SB_UNAME="$fake_dir/uname" sb core install >/dev/null 2>&1 || rc=$?
    assert "unsupported architecture mapping is rejected" test "$rc" -ne 0

    printf 'not an archive\n' >"$fake_dir/not-archive"
    rm -f "$root/bin/sing-box"
    rc=0
    SB_CORE_ARCHIVE="$fake_dir/not-archive" sb core install >/dev/null 2>&1 || rc=$?
    assert "non-archive core download is rejected" test "$rc" -ne 0
    assert "bad archive does not install a core" test ! -e "$root/bin/sing-box"

    mkdir -p "$fake_dir/unexpected"
    printf 'wrong payload\n' >"$fake_dir/unexpected/not-sing-box"
    wrong_archive="$fake_dir/wrong-path.tar.gz"
    tar -czf "$wrong_archive" -C "$fake_dir" unexpected
    wrong_hash=$(sha256sum "$wrong_archive" | awk '{print $1}')
    rc=0
    SB_CORE_ARCHIVE="$wrong_archive" SB_CORE_SHA256_OVERRIDE="$wrong_hash" \
      sb core install >/dev/null 2>&1 || rc=$?
    assert "archive without the pinned internal binary path is rejected" test "$rc" -ne 0
}

test_existing_data_validation() {
    local root rc
    for corruption in unknown-schema missing-schema state-json settings-json broken-current missing-output zero-node; do
        new_env
        root="$TEST_ROOT"
        init_env
        case "$corruption" in
            unknown-schema) jq '.schema_version=999' "$root/data/current/instances.json" \
              >"$root/state.new"; mv "$root/state.new" "$root/data/current/instances.json" ;;
            missing-schema) jq 'del(.schema_version)' "$root/data/current/instances.json" \
              >"$root/state.new"; mv "$root/state.new" "$root/data/current/instances.json" ;;
            state-json) printf '{broken\n' >"$root/data/current/instances.json" ;;
            settings-json) printf '{broken\n' >"$root/data/current/settings.json" ;;
            broken-current) rm "$root/data/current"; ln -s generations/missing "$root/data/current" ;;
            missing-output) rm "$root/data/current/output/manifest.json" ;;
            zero-node) printf '{\"schema_version\":2,\"instances\":\"bad\"}\n' \
              >"$root/data/current/instances.json" ;;
        esac
        rc=0
        sb install --endpoint node.example.com --yes >"$SB_TEST_OUTPUT_FILE" 2>&1 || rc=$?
        assert "existing ${corruption} data rejects repeat install" test "$rc" -ne 0
        assert "existing ${corruption} failure has no success claim" \
          sh -c "! grep -q 'initialization verified' '$SB_TEST_OUTPUT_FILE'"
    done
}

test_zero_node_reboot_policy() {
    local root
    new_env
    root="$TEST_ROOT"
    init_env
    assert "zero-node installation remains enabled" test -f "$root/runtime/enabled"
    assert "zero-node installation is stopped" test ! -f "$root/runtime/active"
    "$SB_SYSTEMCTL" start sb-core
    assert "zero-node simulated reboot start is blocked by ExecCondition" \
      test ! -f "$root/runtime/active"
    sb add SS --port 26401 --yes >/dev/null
    assert "first node starts service" test -f "$root/runtime/active"
    "$SB_SYSTEMCTL" stop sb-core
    "$SB_SYSTEMCTL" start sb-core
    assert "enabled node starts after simulated reboot" test -f "$root/runtime/active"
    sb disable is01 --yes >/dev/null
    assert "disabled last node stops service" test ! -f "$root/runtime/active"
    "$SB_SYSTEMCTL" start sb-core
    assert "disabled last node stays stopped after simulated reboot" \
      test ! -f "$root/runtime/active"
    sb enable is01 --yes >/dev/null
    sb delete is01 --yes >/dev/null
    "$SB_SYSTEMCTL" start sb-core
    assert "deleted last node stays stopped after simulated reboot" \
      test ! -f "$root/runtime/active"
}

test_sensitive_logging_and_permissions() {
    local root password_file marker
    new_env
    root="$TEST_ROOT"
    init_env
    marker='SB-SECRET-LEAK-CANARY-7c5f55f2'
    password_file="$root/password"
    printf '%s\n' "$marker" >"$password_file"
    sb add SS --port 26601 --password-file "$password_file" --yes >/dev/null
    {
        SB_BIN="$APP_DIR/tests/fixtures/mock-sing-box-fail-check" \
          sb edit is01 --port 26602 --yes || true
        sb status
        sb doctor || true
        sb state export
        sb edit is01 --port 26602 --dry-run --yes
    } >"$SB_TEST_OUTPUT_FILE" 2>&1
    assert "operational, failure and dry-run logs redact passwords" \
      sh -c "! grep -Fq '$marker' '$SB_TEST_OUTPUT_FILE'"
    assert "all current generation files remain mode 0600 after atomic publishes" sh -c \
      "! find '$root/data/current' -type f ! -perm 600 | grep -q ."
}

# Redaction must cover every secret field, not just `password`.
#
# `|` binds looser than `|=`, so an unparenthesised update body silently drops
# out of `.value` after the first condition: `password` was redacted while
# `uuid` and `private_key` were emitted verbatim. Passwords were the only field
# any assertion checked, so the gap survived a green suite. These cases pin all
# three fields, on a UUID/key protocol and on a password protocol, across both
# consumers of state_export_file.
test_secret_redaction_matrix() {
    local root password_file marker export_file dry_file
    local uuid private_key public_key short_id reimport

    new_env
    root="$TEST_ROOT"
    init_env

    marker='SB-SECRET-LEAK-CANARY-3d90ab14'
    password_file="$root/password"
    printf '%s\n' "$marker" >"$password_file"

    # One VLESS Reality node (uuid + private_key) and one password protocol.
    sb add vless --port 27101 --server-name www.icloud.com --yes >/dev/null
    sb add SS --port 27102 --password-file "$password_file" --yes >/dev/null

    # Real generated values, read straight from live state.
    uuid=$(jq -r '.instances.is01.uuid' "$root/data/current/instances.json")
    private_key=$(jq -r '.instances.is01.private_key' "$root/data/current/instances.json")
    public_key=$(jq -r '.instances.is01.public_key' "$root/data/current/instances.json")
    short_id=$(jq -r '.instances.is01.short_id' "$root/data/current/instances.json")
    assert "fixture produced a real uuid" sh -c "[ -n '$uuid' ] && [ '$uuid' != null ]"
    assert "fixture produced a real private_key" \
      sh -c "[ -n '$private_key' ] && [ '$private_key' != null ]"

    # ── consumer 1: sb state export without --show-secrets ────────────────
    export_file="$root/export-redacted.json"
    sb state export >"$export_file" 2>&1

    assert "export redacts password" jq -e \
      '.instances.is02.password == "[REDACTED]"' "$export_file"
    assert "export redacts uuid" jq -e \
      '.instances.is01.uuid == "[REDACTED]"' "$export_file"
    assert "export redacts private_key" jq -e \
      '.instances.is01.private_key == "[REDACTED]"' "$export_file"
    assert "export keeps public_key visible" jq -e \
      --arg v "$public_key" '.instances.is01.public_key == $v' "$export_file"
    assert "export keeps short_id visible" jq -e \
      --arg v "$short_id" '.instances.is01.short_id == $v' "$export_file"
    assert "no cleartext uuid anywhere in export" \
      sh -c "! grep -Fq '$uuid' '$export_file'"
    assert "no cleartext private_key anywhere in export" \
      sh -c "! grep -Fq '$private_key' '$export_file'"
    assert "no cleartext password anywhere in export" \
      sh -c "! grep -Fq '$marker' '$export_file'"

    # ── consumer 2: dry-run state diff ────────────────────────────────────
    dry_file="$root/dryrun.log"
    sb edit is01 --port 27103 --dry-run --yes >"$dry_file" 2>&1

    assert "dry-run diff leaks no uuid" sh -c "! grep -Fq '$uuid' '$dry_file'"
    assert "dry-run diff leaks no private_key" \
      sh -c "! grep -Fq '$private_key' '$dry_file'"
    assert "dry-run diff leaks no password" sh -c "! grep -Fq '$marker' '$dry_file'"
    assert "dry-run diff shows the redaction marker" \
      sh -c "grep -q '\\[REDACTED\\]' '$dry_file'"
    # Read-only: the dry-run must not have moved the port it proposed.
    assert "dry-run left state untouched" jq -e \
      '.instances.is01.port == 27101' "$root/data/current/instances.json"

    # ── explicit secret export stays complete and importable ──────────────
    reimport="$root/export-secrets.json"
    sb state export --show-secrets >"$reimport" 2>&1
    assert "--show-secrets emits the real uuid" jq -e \
      --arg v "$uuid" '.instances.is01.uuid == $v' "$reimport"
    assert "--show-secrets emits the real private_key" jq -e \
      --arg v "$private_key" '.instances.is01.private_key == $v' "$reimport"
    assert "--show-secrets emits the real password" jq -e \
      --arg v "$marker" '.instances.is02.password == $v' "$reimport"
    assert "--show-secrets export is still importable" sb state import "$reimport" --yes
    assert "import preserved the uuid" jq -e \
      --arg v "$uuid" '.instances.is01.uuid == $v' "$root/data/current/instances.json"
}

# MainPID ownership must survive systemd's fork-before-exec window.
#
# Reproduced on a real Debian 12 host: for ~30-50ms after `systemctl restart`
# the unit reports a valid MainPID, already in the sb-core cgroup, whose
# /proc/<pid>/exe still resolves to /usr/lib/systemd/systemd. The old
# single-shot check rejected that healthy service. These cases pin the settle
# loop without letting either predicate weaken.
sb_ownership_probe() {
    # Drive service_wait_ownership directly with scripted transients.
    local runtime="$1" timeout="${2:-0.4}"
    env SB_TEST_MODE=true SB_TEST_RUNTIME_DIR="$runtime" \
        SB_OWNERSHIP_SETTLE_TIMEOUT="$timeout" SB_OWNERSHIP_SETTLE_INTERVAL=0.02 \
        SB_SERVICE=sb-core \
        bash -c '
          source "$0/core/common.sh" 2>/dev/null
          source "$0/core/service.sh"
          service_wait_ownership
        ' "$APP_DIR"
}

test_mainpid_ownership_settle() {
    local root runtime out rc

    new_env
    root="$TEST_ROOT"
    runtime="$root/ownership"
    mkdir -p "$runtime"

    # 1. MainPID initially zero, then valid.
    printf '0\n0\n4242\n4242\n' >"$runtime/pid.sequence"
    printf 'pass\n' >"$runtime/belongs.sequence"
    out=$(sb_ownership_probe "$runtime"); rc=$?
    assert "MainPID 0 then valid settles" test "$rc" -eq 0
    assert "settled PID is the valid one" test "$out" = "4242"

    # 2. Executable initially wrong (the real fork-before-exec window).
    printf '4242\n' >"$runtime/pid.sequence"
    printf 'fail-exe\nfail-exe\npass\n' >"$runtime/belongs.sequence"
    out=$(sb_ownership_probe "$runtime"); rc=$?
    assert "transient wrong executable settles" test "$rc" -eq 0
    assert "settles on the same PID" test "$out" = "4242"

    # 3. Cgroup initially wrong, then correct.
    printf '4242\n' >"$runtime/pid.sequence"
    printf 'fail-cgroup\npass\n' >"$runtime/belongs.sequence"
    out=$(sb_ownership_probe "$runtime"); rc=$?
    assert "transient wrong cgroup settles" test "$rc" -eq 0

    # 4. PID changes during startup: must settle on the final PID, not the first.
    printf '1111\n2222\n3333\n3333\n' >"$runtime/pid.sequence"
    printf 'pass\n' >"$runtime/belongs.sequence"
    out=$(sb_ownership_probe "$runtime"); rc=$?
    assert "PID change during startup still settles" test "$rc" -eq 0
    assert "settles on the final PID, not a moving one" test "$out" = "3333"

    # 5. Timeout when the executable never matches, naming that predicate.
    printf '4242\n' >"$runtime/pid.sequence"
    printf 'fail-exe\n' >"$runtime/belongs.sequence"
    out=$(sb_ownership_probe "$runtime" 0.2 2>&1) && rc=0 || rc=$?
    assert "executable never matching times out" test "$rc" -ne 0
    assert "timeout names the executable predicate" sh -c \
      "printf '%s' \"$out\" | grep -q executable"

    # 6. Timeout when the cgroup never matches, naming that predicate.
    printf '4242\n' >"$runtime/pid.sequence"
    printf 'fail-cgroup\n' >"$runtime/belongs.sequence"
    out=$(sb_ownership_probe "$runtime" 0.2 2>&1) && rc=0 || rc=$?
    assert "cgroup never matching times out" test "$rc" -ne 0
    assert "timeout names the cgroup predicate" sh -c \
      "printf '%s' \"$out\" | grep -q cgroup"

    # 7. A MainPID that never appears is still a failure, not a pass.
    printf '0\n' >"$runtime/pid.sequence"
    printf 'pass\n' >"$runtime/belongs.sequence"
    out=$(sb_ownership_probe "$runtime" 0.2 2>&1) && rc=0 || rc=$?
    assert "MainPID never published times out" test "$rc" -ne 0
    assert "timeout explains no valid MainPID" sh -c \
      "printf '%s' \"$out\" | grep -q 'valid MainPID'"

    # 8. Strictness: ownership is never assumed. A PID that is stable but never
    #    owned must fail, however long we wait.
    printf '4242\n' >"$runtime/pid.sequence"
    printf 'fail-exe\nfail-cgroup\nfail-exe\nfail-cgroup\n' >"$runtime/belongs.sequence"
    out=$(sb_ownership_probe "$runtime" 0.2 2>&1) && rc=0 || rc=$?
    assert "stable but unowned PID is rejected" test "$rc" -ne 0

    # 9. Rollback still happens when verification times out: a real publish with
    #    a permanently unowned PID must leave no node behind.
    new_env
    root="$TEST_ROOT"
    init_env
    # The mock rewrites service.pid when it starts the unit, so drive the
    # ownership verdict directly: this PID is stable but never owned.
    mkdir -p "$SB_TEST_RUNTIME_DIR"
    printf 'fail-exe\n' >"$SB_TEST_RUNTIME_DIR/belongs.sequence"
    SB_OWNERSHIP_SETTLE_TIMEOUT=0.2 SB_OWNERSHIP_SETTLE_INTERVAL=0.02 \
      sb add SS --port 26801 --yes >/dev/null 2>&1 && rc=0 || rc=$?
    rm -f "$SB_TEST_RUNTIME_DIR/belongs.sequence"
    assert "publish fails when ownership never settles" test "$rc" -ne 0
    assert "failed publish left no instance behind" sh -c \
      "! jq -e '.instances | length > 0' '$root/data/current/instances.json' >/dev/null 2>&1"
}

test_real_uri_parsers_and_hysteria_tls() {
    local hysteria="${SB_TEST_HYSTERIA_BIN:-/tmp/hysteria-v2.10.0-linux-amd64}"
    local ssurl="${SB_TEST_SSURL_BIN:-/tmp/shadowsocks-rust-v1.24.0/ssurl}"
    local root ca_key ca_cert leaf_key leaf_csr leaf_cert ext password_file
    local port uri parsed mode cert key fingerprint pin spki
    assert "official Hysteria parser binary is available" test -x "$hysteria"
    assert "official shadowsocks-rust ssurl parser is available" test -x "$ssurl"

    new_env
    root="$TEST_ROOT"
    sb install --endpoint node.example.com --yes >/dev/null
    password_file="$root/ss2022.password"
    printf '%s\n' 'YctPZ6U7xPPcU+gp3u+0tx/tRizJN9K8y+uKlW2qjlI=' >"$password_file"
    sb add SS2022 --port 26301 --method 2022-blake3-aes-256-gcm \
      --password-file "$password_file" --yes >/dev/null
    uri=$(sb output is01 uri)
    [[ "$uri" == *'%2B'* && "$uri" == *'%2F'* && "$uri" == *'%3D'* ]]
    parsed=$("$ssurl" -d "$uri")
    assert "ssurl parses AEAD-2022 method" rg -q \
      'method: "2022-blake3-aes-256-gcm"' <<<"$parsed"
    assert "ssurl parses Base64 PSK with reserved characters" rg -Fq \
      'password: "YctPZ6U7xPPcU+gp3u+0tx/tRizJN9K8y+uKlW2qjlI="' <<<"$parsed"
    sb endpoint set 8.8.8.8 --yes >/dev/null
    "$ssurl" -d "$(sb output is01 uri)" >/dev/null
    pass "ssurl parses SS2022 IPv4 endpoint"
    sb endpoint set 2606:4700:4700::1111 --yes >/dev/null
    "$ssurl" -d "$(sb output is01 uri)" >/dev/null
    pass "ssurl parses SS2022 IPv6 endpoint"
    sb endpoint set node.example.com --yes >/dev/null
    "$ssurl" -d "$(sb output is01 uri)" >/dev/null
    pass "ssurl parses SS2022 domain endpoint"
    local encoded_tag
    encoded_tag=$(bash -c 'source "$1/core/common.sh"; urlencode "节点 one"' _ "$APP_DIR")
    parsed=$("$ssurl" -d "${uri%%#*}#${encoded_tag}")
    assert "ssurl parses percent-encoded Unicode/space tag" rg -q '节点 one' <<<"$parsed"

    for mode in trusted provided self-signed insecure; do
        new_env
        root="$TEST_ROOT"
        ca_key="$root/ca.key"; ca_cert="$root/ca.pem"
        leaf_key="$root/leaf.key"; leaf_csr="$root/leaf.csr"; leaf_cert="$root/leaf.pem"
        ext="$root/leaf.ext"; password_file="$root/hy.password"
        printf '%s\n' 'subjectAltName=DNS:local.test' 'extendedKeyUsage=serverAuth' >"$ext"
        openssl req -x509 -nodes -newkey rsa:2048 -days 2 -subj '/CN=sb-test-ca' \
          -keyout "$ca_key" -out "$ca_cert" >/dev/null 2>&1
        openssl req -nodes -newkey rsa:2048 -subj '/CN=local.test' \
          -keyout "$leaf_key" -out "$leaf_csr" >/dev/null 2>&1
        openssl x509 -req -in "$leaf_csr" -CA "$ca_cert" -CAkey "$ca_key" \
          -CAcreateserial -days 2 -extfile "$ext" -out "$leaf_cert" >/dev/null 2>&1
        printf '%s\n' 'test-hysteria-password' >"$password_file"
        export SB_CA_BUNDLE="$ca_cert"
        sb install --endpoint 127.0.0.1 --allow-private-endpoint --yes >/dev/null
        port=$(free_udp_port)
        case "$mode" in
            trusted|provided)
                sb add HY2 --port "$port" --sni local.test --tls-mode "$mode" \
                  --certificate "$leaf_cert" --key "$leaf_key" \
                  --password-file "$password_file" --masquerade https://local.test \
                  --no-hop --yes >/dev/null ;;
            self-signed|insecure)
                sb add HY2 --port "$port" --sni local.test --tls-mode "$mode" \
                  --password-file "$password_file" --masquerade https://local.test \
                  --no-hop --yes >/dev/null ;;
        esac
        uri=$(sb output is01 uri)
        cert=$(jq -r '.instances.is01.tls.certificate_path' "$root/data/current/instances.json")
        key=$(jq -r '.instances.is01.tls.key_path' "$root/data/current/instances.json")
        case "$mode" in
            trusted)
                [[ "$uri" != *insecure* && "$uri" != *pinSHA256* ]]
                "$APP_DIR/tests/real-hysteria-handshake.sh" \
                  "$hysteria" "$uri" "$cert" "$key" "$ca_cert" ;;
            provided|self-signed)
                [[ "$uri" == *'insecure=1'* && "$uri" == *'pinSHA256='* ]]
                fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | cut -d= -f2-)
                pin=$(python3 -c 'import sys,urllib.parse
print(urllib.parse.parse_qs(urllib.parse.urlsplit(sys.argv[1]).query)["pinSHA256"][0])' "$uri")
                spki=$(openssl x509 -in "$cert" -pubkey -noout |
                  openssl pkey -pubin -outform der |
                  openssl dgst -sha256 -binary |
                  openssl enc -base64 -A)
                assert "HY2 ${mode} URI pins full certificate DER fingerprint" \
                  test "$pin" = "$fingerprint"
                assert "HY2 ${mode} URI does not put SPKI in pinSHA256" \
                  test "$pin" != "$spki"
                "$APP_DIR/tests/real-hysteria-handshake.sh" \
                  "$hysteria" "$uri" "$cert" "$key" ;;
            insecure)
                [[ "$uri" == *'insecure=1'* && "$uri" != *pinSHA256* ]]
                "$APP_DIR/tests/real-hysteria-handshake.sh" \
                  "$hysteria" "$uri" "$cert" "$key" ;;
        esac
        pass "official Hysteria client completes low-flow ${mode} TLS handshake"
        unset SB_CA_BUNDLE
    done
}

# --- HIGH-01: publish / rollback fault injection --------------------------
#
# Every fault below makes a real command fail with a real errno (a staging path
# redirected into a missing directory, or an occupied rename target). None of
# them fakes a return code, so each case proves the specific command's status is
# actually inspected.

txn_probe() {
    # txn_probe <name> <fault> <command...>
    # Runs the command under an armed fault and records the resulting state.
    local name="$1" fault="$2"
    shift 2
    PROBE_BEFORE_CURRENT=$(readlink "$SB_CURRENT_LINK")
    PROBE_BEFORE_STATE=$(sha256sum "$SB_CURRENT_LINK/instances.json" | awk '{print $1}')
    PROBE_BEFORE_SETTINGS=$(sha256sum "$SB_CURRENT_LINK/settings.json" | awk '{print $1}')
    PROBE_OUTPUT=$(SB_TEST_FAULTS="$fault" "$@" 2>&1) && PROBE_RC=0 || PROBE_RC=$?
    PROBE_AFTER_CURRENT=$(readlink "$SB_CURRENT_LINK")
    PROBE_AFTER_STATE=$(sha256sum "$SB_CURRENT_LINK/instances.json" | awk '{print $1}')
    PROBE_AFTER_SETTINGS=$(sha256sum "$SB_CURRENT_LINK/settings.json" | awk '{print $1}')
    printf '  [%s] rc=%s current=%s state=%s\n' "$name" "$PROBE_RC" \
      "$([[ "$PROBE_BEFORE_CURRENT" == "$PROBE_AFTER_CURRENT" ]] && printf unchanged || printf SWITCHED)" \
      "$([[ "$PROBE_BEFORE_STATE" == "$PROBE_AFTER_STATE" ]] && printf unchanged || printf CHANGED)"
}

assert_publish_failed_cleanly() {
    local name="$1"
    assert "${name}: returns nonzero" test "$PROBE_RC" -ne 0
    assert "${name}: current still points at the old generation" \
      test "$PROBE_BEFORE_CURRENT" = "$PROBE_AFTER_CURRENT"
    assert "${name}: live state hash unchanged" \
      test "$PROBE_BEFORE_STATE" = "$PROBE_AFTER_STATE"
    assert "${name}: live settings hash unchanged" \
      test "$PROBE_BEFORE_SETTINGS" = "$PROBE_AFTER_SETTINGS"
    assert "${name}: no publish success message" \
      sh -c "! printf '%s' \"\$1\" | rg -q 'publish completed'" _ "$PROBE_OUTPUT"
    assert "${name}: no business success message" \
      sh -c "! printf '%s' \"\$1\" | rg -q 'instance created|instance updated|endpoint updated|listen mode updated'" \
      _ "$PROBE_OUTPUT"
}

test_transaction_publish_fault_injection() {
    local root fault
    for fault in generation-final-mv current-new-create current-new-switch; do
        new_env
        root="$TEST_ROOT"
        init_env
        txn_probe "$fault" "$fault" sb add SS --port 27001 --yes
        assert_publish_failed_cleanly "publish fault ${fault}"
        assert "publish fault ${fault}: live state has no new instance" \
          jq -e '.instances|length==0' "$root/data/current/instances.json"
        assert "publish fault ${fault}: status records a failed publish" \
          jq -e '.last_publish.result=="failed"' "$root/data/status.json"
        assert "publish fault ${fault}: no staging link left behind" sh -c \
          "! find '$root/data' -maxdepth 1 -name '.current.*' | grep -q ."
    done

    # The exact scenario the previous review reproduced: rc=0 with an unchanged
    # current link but a printed success message. Assert it cannot recur.
    new_env
    root="$TEST_ROOT"
    init_env
    txn_probe regression current-new-create sb add SS --port 27002 --yes
    assert "regression: unswitched current can never report success" \
      sh -c "test \"\$1\" -ne 0 || ! printf '%s' \"\$2\" | rg -q 'publish completed'" \
      _ "$PROBE_RC" "$PROBE_OUTPUT"
}

test_transaction_rollback_fault_injection() {
    local root
    # Rollback path with the link restore intact.
    new_env
    root="$TEST_ROOT"
    init_env
    touch "$root/runtime/fail-start"
    txn_probe rollback-clean "" sb add SS --port 27101 --yes
    assert_publish_failed_cleanly "rollback (service failure)"
    assert "rollback (service failure): status records a successful rollback" \
      jq -e '.last_rollback.performed==true and .last_rollback.result=="success"' \
      "$root/data/status.json"
    assert "rollback (service failure): rejected generation discarded" \
      test "$(find "$root/data/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1

    local fault
    for fault in current-rollback-create current-rollback-switch; do
        new_env
        root="$TEST_ROOT"
        init_env
        touch "$root/runtime/fail-start"
        txn_probe "$fault" "$fault" sb add SS --port 27102 --yes
        assert "rollback fault ${fault}: returns the unrecoverable exit code" \
          test "$PROBE_RC" -eq 70
        assert "rollback fault ${fault}: no success message" \
          sh -c "! printf '%s' \"\$1\" | rg -q 'publish completed|instance created'" \
          _ "$PROBE_OUTPUT"
        assert "rollback fault ${fault}: reports a critical failure" \
          sh -c "printf '%s' \"\$1\" | rg -q 'CRITICAL'" _ "$PROBE_OUTPUT"
        assert "rollback fault ${fault}: prints the manual recovery target" \
          sh -c "printf '%s' \"\$1\" | rg -q 'manual recovery'" _ "$PROBE_OUTPUT"
        assert "rollback fault ${fault}: status records the failed rollback" \
          jq -e '.last_publish.result=="rollback-failed" and
                 .last_rollback.result=="current-link-restore-failed"' \
          "$root/data/status.json"
        assert "rollback fault ${fault}: both generations retained for recovery" \
          test "$(find "$root/data/generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" -ge 2
        assert "rollback fault ${fault}: no credentials in the failure output" \
          sh -c "! printf '%s' \"\$1\" | rg -q 'password|BEGIN .*PRIVATE KEY'" _ "$PROBE_OUTPUT"
        assert "rollback fault ${fault}: doctor reports the drift" sh -c \
          "'$APP_DIR/sb' doctor --json 2>/dev/null | jq -e '.results[]|select(.name==\"last_publish\")|.status==\"fail\"' >/dev/null"
    done

    # Service recovery failure after a successful link restore is a distinct,
    # less severe outcome and must not be conflated with the above.
    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 27201 --yes >/dev/null
    touch "$root/runtime/fail-restart"
    txn_probe rollback-service-restore "" sb edit is01 --port 27202 --yes
    assert "rollback with failed service restore returns nonzero" test "$PROBE_RC" -ne 0
    assert "rollback with failed service restore is not reported as unrecoverable" \
      test "$PROBE_RC" -ne 70
    assert "rollback with failed service restore keeps the current link restored" \
      test "$PROBE_BEFORE_CURRENT" = "$PROBE_AFTER_CURRENT"
    assert "rollback with failed service restore is labelled distinctly" \
      jq -e '.last_rollback.result=="service-restore-failed"' "$root/data/status.json"
}

test_transaction_fault_across_operations() {
    # Every state-changing operation must fail the same way when the current
    # link switch fails, not just `sb add`.
    local root
    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 27301 --yes >/dev/null
    sb add HY2 --port 27302 --sni hy.example.com --tls-mode self-signed \
      --masquerade https://hy.example.com --no-hop --yes >/dev/null

    txn_probe edit current-new-switch sb edit is01 --port 27311 --yes
    assert_publish_failed_cleanly "edit with failed current switch"
    txn_probe disable current-new-switch sb disable is01 --yes
    assert_publish_failed_cleanly "disable with failed current switch"
    txn_probe delete current-new-switch sb delete is02 --yes
    assert_publish_failed_cleanly "delete with failed current switch"
    assert "delete with failed current switch keeps both instances" \
      jq -e '.instances|length==2' "$root/data/current/instances.json"
    txn_probe endpoint current-new-switch sb endpoint set 203.0.113.9 --allow-private-endpoint --yes
    assert_publish_failed_cleanly "endpoint update with failed current switch"
    txn_probe listen current-new-switch sb listen set ipv4 --yes
    assert_publish_failed_cleanly "listen update with failed current switch"
    assert "listen update failure leaves the live listen mode intact" \
      test "$(jq -r '.listen.mode' "$root/data/current/settings.json")" = dual
}

# --- HIGH-02 / MEDIUM-04: manager app switch and CLI link -----------------

manager_probe() {
    # manager_probe <fault> ; runs manager_install_source in a subshell
    local fault="$1"
    PROBE_BEFORE_APP=$(readlink "$SB_APP_LINK" 2>/dev/null || printf '')
    PROBE_BEFORE_CLI=$(readlink "$SB_COMMAND_LINK" 2>/dev/null || printf '')
    PROBE_BEFORE_RELEASES=$(manager_release_count)
    PROBE_OUTPUT=$( (
        export SB_TEST_FAULTS="$fault"
        # shellcheck source=/dev/null
        source "$APP_DIR/core/common.sh"
        # shellcheck source=/dev/null
        source "$APP_DIR/core/manager.sh"
        manager_install_source "$APP_DIR"
    ) 2>&1 ) && PROBE_RC=0 || PROBE_RC=$?
    PROBE_AFTER_APP=$(readlink "$SB_APP_LINK" 2>/dev/null || printf '')
    PROBE_AFTER_CLI=$(readlink "$SB_COMMAND_LINK" 2>/dev/null || printf '')
    PROBE_AFTER_RELEASES=$(manager_release_count)
}

manager_release_count() {
    # Count only real releases: an injected rename obstruction is not one.
    # The directory legitimately does not exist before the first install, and
    # find's failure there must not look like a counting error under pipefail.
    [[ -d "$SB_RELEASES_DIR" ]] || {
        printf '0\n'
        return 0
    }
    find "$SB_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d \
      -exec test -x '{}/sb' \; -print | wc -l
}

manager_baseline() {
    ( # shellcheck source=/dev/null
      source "$APP_DIR/core/common.sh"
      # shellcheck source=/dev/null
      source "$APP_DIR/core/manager.sh"
      manager_install_source "$APP_DIR" ) >/dev/null 2>&1
}

test_manager_app_switch_fault_injection() {
    local root fault
    for fault in release-stage-mkdir release-copy release-validate release-final-mv \
                 app-new-create app-new-switch app-selfcheck \
                 cli-link-create cli-link-switch; do
        new_env
        root="$TEST_ROOT"
        init_env
        manager_baseline
        manager_probe "$fault"
        assert "manager fault ${fault}: returns nonzero" test "$PROBE_RC" -ne 0
        assert "manager fault ${fault}: app link unchanged" \
          test "$PROBE_BEFORE_APP" = "$PROBE_AFTER_APP"
        assert "manager fault ${fault}: no orphan release" \
          test "$PROBE_AFTER_RELEASES" -eq "$PROBE_BEFORE_RELEASES"
        assert "manager fault ${fault}: no install success message" \
          sh -c "! printf '%s' \"\$1\" | rg -q 'sb manager installed'" _ "$PROBE_OUTPUT"
        assert "manager fault ${fault}: no .app.new residue" sh -c \
          "! find '$root/opt' -maxdepth 1 -name '.app.*' | grep -q ."
        assert "manager fault ${fault}: command link unchanged" \
          test "$PROBE_BEFORE_CLI" = "$PROBE_AFTER_CLI"
        assert "manager fault ${fault}: no broken command link" \
          sh -c "[ ! -L '$SB_COMMAND_LINK' ] || [ -x '$SB_COMMAND_LINK' ]"
        assert "manager fault ${fault}: previous manager still runs" \
          env -u SB_APP_DIR "$SB_APP_LINK/sb" self-check
    done

    for fault in app-rollback-create app-rollback-switch; do
        new_env
        root="$TEST_ROOT"
        init_env
        manager_baseline
        manager_probe "app-selfcheck:$fault"
        assert "manager rollback fault ${fault}: unrecoverable exit code" \
          test "$PROBE_RC" -eq 70
        assert "manager rollback fault ${fault}: reports a critical failure" \
          sh -c "printf '%s' \"\$1\" | rg -q 'CRITICAL'" _ "$PROBE_OUTPUT"
        assert "manager rollback fault ${fault}: prints manual recovery guidance" \
          sh -c "printf '%s' \"\$1\" | rg -q 'manual recovery'" _ "$PROBE_OUTPUT"
        assert "manager rollback fault ${fault}: rejected release retained for recovery" \
          sh -c "printf '%s' \"\$1\" | rg -q 'rejected release retained'" _ "$PROBE_OUTPUT"
        assert "manager rollback fault ${fault}: no install success message" \
          sh -c "! printf '%s' \"\$1\" | rg -q 'sb manager installed'" _ "$PROBE_OUTPUT"
    done

    # Regression: the reproduced scenario was rc=0, app link unchanged, orphan
    # release created and "sb manager installed" printed.
    new_env
    init_env
    manager_baseline
    manager_probe app-new-create
    assert "regression: unswitched app link can never report installed" sh -c \
      "test \"\$1\" -ne 0 && ! printf '%s' \"\$2\" | rg -q 'sb manager installed'" \
      _ "$PROBE_RC" "$PROBE_OUTPUT"
}

test_command_link_conflicts() {
    local root
    # A plain file at the command path must never be silently replaced.
    new_env
    root="$TEST_ROOT"
    init_env
    mkdir -p "$(dirname "$SB_COMMAND_LINK")"
    printf 'not-sb\n' >"$SB_COMMAND_LINK"
    manager_probe ""
    assert "plain file at the command path is refused" test "$PROBE_RC" -ne 0
    assert "plain file at the command path is preserved" \
      test "$(cat "$SB_COMMAND_LINK")" = not-sb
    assert "refusing a plain command path leaves no orphan release" \
      test "$PROBE_AFTER_RELEASES" -eq "$PROBE_BEFORE_RELEASES"

    # A symlink owned by another project must not be hijacked.
    new_env
    root="$TEST_ROOT"
    init_env
    mkdir -p "$(dirname "$SB_COMMAND_LINK")"
    printf '#!/bin/sh\n' >"$root/other-project"
    chmod 755 "$root/other-project"
    ln -sfn "$root/other-project" "$SB_COMMAND_LINK"
    manager_probe ""
    assert "foreign symlink at the command path is refused" test "$PROBE_RC" -ne 0
    assert "foreign symlink at the command path is preserved" \
      test "$(readlink "$SB_COMMAND_LINK")" = "$root/other-project"
    assert "refusing a foreign command path leaves no orphan release" \
      test "$PROBE_AFTER_RELEASES" -eq "$PROBE_BEFORE_RELEASES"

    # An unwritable command directory is a plain creation failure.
    new_env
    root="$TEST_ROOT"
    init_env
    manager_baseline
    manager_probe cli-link-create
    assert "unwritable command directory rolls the app link back" \
      test "$PROBE_BEFORE_APP" = "$PROBE_AFTER_APP"
    assert "unwritable command directory leaves no broken command link" \
      sh -c "[ ! -L '$SB_COMMAND_LINK' ] || [ -x '$SB_COMMAND_LINK' ]"
}

# --- MEDIUM-03: upgrade data rollback -------------------------------------

# Build a source tree that installs cleanly but whose `sb install` mutates live
# data and then fails, simulating a migration that dies halfway through.
make_failing_upgrade_source() {
    local destination="$1" mutation="$2"
    cp -a "$APP_DIR/." "$destination/" || return 1
    rm -rf "${destination:?}/tests"
    python3 - "$destination/sb" "$mutation" <<'PY'
import sys, pathlib
target, mutation = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = target.read_text().splitlines(keepends=True)
hook = f'''
if [[ "${{1:-}}" == "install" && "${{SB_UPGRADE_MUTATION_DONE:-}}" != "true" ]]; then
    export SB_UPGRADE_MUTATION_DONE=true
    _gen=$(readlink -f "$SB_CURRENT_LINK")
    case "{mutation}" in
        state)
            jq '.instances.injected={{"protocol":"SS"}}' "$_gen/instances.json" \\
              >"$_gen/instances.tmp" && mv "$_gen/instances.tmp" "$_gen/instances.json" ;;
        settings)
            jq '.endpoint.value="mutated.example.com"' "$_gen/settings.json" \\
              >"$_gen/settings.tmp" && mv "$_gen/settings.tmp" "$_gen/settings.json" ;;
        generation)
            printf 'corrupted\\n' >"$_gen/output/config.json" ;;
        certs)
            find "$SB_CERT_DIR" -name 'certificate.pem' -exec sh -c \\
              'printf "corrupted\\n" >"$1"' _ {{}} \\; ;;
    esac
    printf 'simulated migration failure after mutating {mutation}\\n' >&2
    exit 1
fi
'''
# Insert immediately after the global option parsing block.
for index, line in enumerate(lines):
    if line.startswith('export SB_JSON SB_YES SB_DRY_RUN SB_SHOW_SECRETS'):
        lines.insert(index + 1, hook)
        break
else:
    raise SystemExit('anchor not found')
target.write_text(''.join(lines))
PY
    chmod 755 "$destination/sb"
}

test_cross_pin_upgrade_rollback() {
    local root source before_state before_settings before_receipt before_releases out rc
    setup_previous_pin_install
    root="$TEST_ROOT"
    env -u SB_APP_DIR "$SB_APP_LINK/sb" add SS --port 27201 --yes >/dev/null
    before_state=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
    before_settings=$(sha256sum "$root/data/current/settings.json" | awk '{print $1}')
    before_receipt=$(sha256sum "$root/data/core.json" | awk '{print $1}')
    before_releases=$(manager_release_count)
    source="$root/failing-cross-pin-source"
    mkdir -p "$source"
    make_failing_upgrade_source "$source" state

    out=$(env -u SB_APP_DIR "$APP_DIR/sb" upgrade --source "$source" \
      --upgrade-core --yes 2>&1) && rc=0 || rc=$?
    assert "failed cross-pin install returns nonzero" test "$rc" -ne 0
    assert "failed cross-pin install reports the manager rollback" sh -c \
      "printf '%s' \"\$1\" | rg -q 'manager upgrade rolled back'" _ "$out"
    assert "failed cross-pin install restores the previous manager" \
      test "$(readlink "$SB_APP_LINK")" = "$PREVIOUS_PIN_APP"
    assert "failed cross-pin install restores the previous core binary" \
      test "$(sha256sum "$SB_BIN" | awk '{print $1}')" = "$PREVIOUS_PIN_CORE_SHA"
    assert "failed cross-pin install restores the previous core receipt" \
      test "$(sha256sum "$root/data/core.json" | awk '{print $1}')" = "$before_receipt"
    assert "failed cross-pin install restores the previous state" \
      test "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$before_state"
    assert "failed cross-pin install restores the previous settings" \
      test "$(sha256sum "$root/data/current/settings.json" | awk '{print $1}')" = "$before_settings"
    assert "failed cross-pin install removes the rejected manager release" \
      test "$(manager_release_count)" -eq "$before_releases"
    assert "failed cross-pin install validates with the previous manager/core" \
      env -u SB_APP_DIR "$SB_APP_LINK/sb" validate
    assert "failed cross-pin install passes previous manager doctor" \
      env -u SB_APP_DIR "$SB_APP_LINK/sb" doctor --json

    # A failure inside the new manager's core upgrade is also inside the same
    # outer rollback boundary.  core_upgrade first restores its local switch;
    # cmd_upgrade then restores the old app/core/receipt/data snapshot.
    setup_previous_pin_install
    out=$(SB_TEST_FAULTS=core-post-switch-verify env -u SB_APP_DIR "$APP_DIR/sb" \
      upgrade --source "$APP_DIR" --upgrade-core --yes 2>&1) && rc=0 || rc=$?
    assert "failed bootstrap core switch returns nonzero" test "$rc" -ne 0
    assert "failed bootstrap core switch restores the previous manager" \
      test "$(readlink "$SB_APP_LINK")" = "$PREVIOUS_PIN_APP"
    assert "failed bootstrap core switch restores the previous core" \
      test "$(sha256sum "$SB_BIN" | awk '{print $1}')" = "$PREVIOUS_PIN_CORE_SHA"
    assert "failed bootstrap core switch validates after rollback" \
      env -u SB_APP_DIR "$SB_APP_LINK/sb" validate

    # If restoring the old core itself fails, the command must stop with rc=70,
    # retain both the pre-upgrade backup and staged old binary, and print the
    # exact manual recovery path instead of attempting a data restore under a
    # mismatched manager/core pair.
    setup_previous_pin_install
    root="$TEST_ROOT"
    source="$root/failing-cross-pin-source"
    mkdir -p "$source"
    make_failing_upgrade_source "$source" state
    out=$(SB_TEST_FAULTS=upgrade-core-restore env -u SB_APP_DIR "$APP_DIR/sb" \
      upgrade --source "$source" --upgrade-core --yes 2>&1) && rc=0 || rc=$?
    assert "cross-pin core rollback failure is unrecoverable" test "$rc" -eq 70
    assert "cross-pin core rollback failure prints manual recovery" sh -c \
      "printf '%s' \"\$1\" | rg -q 'manual recovery: move .*sing-box.manager-rollback'" _ "$out"
    local artifact
    artifact=$(rg -o '/[^ ]*\.sing-box\.manager-rollback\.[A-Za-z0-9]+' <<<"$out" | head -1)
    assert "cross-pin core rollback retains the staged previous binary" test -f "$artifact"
    assert "cross-pin core rollback retains the pre-upgrade backup" sh -c \
      "printf '%s' \"\$1\" | rg -q 'pre-upgrade backup retained at:'" _ "$out"
    assert "cross-pin core rollback prints no upgrade success" sh -c \
      "! printf '%s' \"\$1\" | rg -q 'sb manager upgraded'" _ "$out"
}

test_upgrade_data_rollback() {
    local root mutation source rc
    for mutation in state settings generation certs; do
        new_env
        root="$TEST_ROOT"
        init_env
        sb add HY2 --port 27401 --sni hy.example.com --tls-mode self-signed \
          --masquerade https://hy.example.com --no-hop --yes >/dev/null
        manager_baseline

        local before_state before_settings before_certs before_current
        before_state=$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')
        before_settings=$(sha256sum "$root/data/current/settings.json" | awk '{print $1}')
        before_certs=$(find "$root/data/certs" -type f -exec sha256sum {} + |
          sort | sha256sum | awk '{print $1}')
        before_current=$(readlink "$root/data/current")

        source="$root/upgrade-source-$mutation"
        mkdir -p "$source"
        make_failing_upgrade_source "$source" "$mutation"

        rc=0
        env -u SB_APP_DIR "$SB_APP_LINK/sb" upgrade --source "$source" --yes \
          >"$SB_TEST_OUTPUT_FILE" 2>&1 || rc=$?

        assert "upgrade (${mutation} mutated): returns nonzero" test "$rc" -ne 0
        assert "upgrade (${mutation} mutated): no upgrade success message" \
          sh -c "! rg -q 'sb manager upgraded' '$SB_TEST_OUTPUT_FILE'"
        assert "upgrade (${mutation} mutated): state restored to the pre-upgrade hash" \
          test "$(sha256sum "$root/data/current/instances.json" | awk '{print $1}')" = "$before_state"
        assert "upgrade (${mutation} mutated): settings restored to the pre-upgrade hash" \
          test "$(sha256sum "$root/data/current/settings.json" | awk '{print $1}')" = "$before_settings"
        assert "upgrade (${mutation} mutated): certificates restored to the pre-upgrade hash" \
          test "$(find "$root/data/certs" -type f -exec sha256sum {} + | sort |
            sha256sum | awk '{print $1}')" = "$before_certs"
        assert "upgrade (${mutation} mutated): generation output passes the fixed core" \
          "$REAL_CORE" check -c "$root/data/current/output/config.json"
        assert "upgrade (${mutation} mutated): current link resolves to a valid generation" \
          test -f "$root/data/current/output/manifest.json"
        assert "upgrade (${mutation} mutated): restored installation validates" \
          env -u SB_APP_DIR "$SB_APP_LINK/sb" validate
        assert "upgrade (${mutation} mutated): app link points at a usable release" \
          env -u SB_APP_DIR "$SB_APP_LINK/sb" self-check
        assert "upgrade (${mutation} mutated): all restored files remain mode 0600" sh -c \
          "! find '$root/data/current' -type f ! -perm 600 | grep -q ."
        [[ "$before_current" == "$(readlink "$root/data/current")" ]] ||
          printf '  note: current link legitimately advanced during restore\n'
    done
}

# --- HIGH-A: mutator-level state write failure ----------------------------
#
# The symlink fault matrix cannot reach this: the failure happens inside the
# mutator, before any generation is published. The trailing result-file write in
# mutator_add used to become the function's return status and mask it.

test_mutator_state_write_fault_injection() {
    local root
    new_env
    root="$TEST_ROOT"
    init_env

    txn_probe add-state-write state-set-write sb add SS --port 28001 --yes
    assert_publish_failed_cleanly "add with failed state write"
    assert "add with failed state write: no instance in live state" \
      jq -e '.instances|length==0' "$root/data/current/instances.json" >/dev/null
    assert "add with failed state write: no state staging residue" sh -c \
      "! find '$root/data' -name '*.tmp.*' | grep -q ."

    # The exact scenario the second review reproduced.
    assert "regression: failed state write never prints instance created" \
      sh -c "! printf '%s' \"\$1\" | rg -q 'instance created'" _ "$PROBE_OUTPUT"
    assert "regression: failed state write never prints publish completed" \
      sh -c "! printf '%s' \"\$1\" | rg -q 'publish completed'" _ "$PROBE_OUTPUT"

    sb add SS --port 28002 --yes >/dev/null
    txn_probe edit-state-write state-set-write sb edit is01 --port 28003 --yes
    assert_publish_failed_cleanly "edit with failed state write"
    txn_probe enable-state-write state-set-write sb disable is01 --yes
    assert_publish_failed_cleanly "disable with failed state write"
    txn_probe delete-state-write state-set-write sb delete is01 --yes
    assert_publish_failed_cleanly "delete with failed state write"
    assert "delete with failed state write keeps the instance" \
      jq -e '.instances|length==1' "$root/data/current/instances.json" >/dev/null
}

# --- HIGH-B / M1 / M2: salvage mode boundaries ----------------------------

test_salvage_mode_boundaries() {
    local root backup_id newest rc out
    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 28101 --yes >/dev/null

    # Healthy live data: the pre-publish snapshot must be a validated backup.
    assert "live installation validates before restore" sb validate
    backup_id=$(basename "$(sb backup)")
    out=$(sb restore "$backup_id" --yes 2>&1)
    newest=$(find "$root/backups" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' |
      sort -rn | head -1 | cut -d' ' -f2-)
    assert "healthy restore does not enter salvage mode" \
      test "$(jq -r '.salvage' "$root/backups/$newest/metadata.json")" = false
    assert "healthy restore prints no salvage warning" \
      sh -c "! printf '%s' \"\$1\" | rg -q 'did not validate'" _ "$out"

    # Live data that fails validation: salvage is the only way the recovery can
    # proceed. Broken permissions on the live generation make the source invalid
    # while leaving contents that backup_create normalises to 0600, so the
    # resulting snapshot is both marked salvage and genuinely restorable — which
    # is what makes the override path testable end to end.
    latest_backup() {
        find "$root/backups" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' |
          sort -rn | head -1 | cut -d' ' -f2-
    }

    chmod 644 "$root/data/current/instances.json"
    out=$(sb restore "$backup_id" --yes 2>&1) && rc=0 || rc=$?
    local salvage_restorable
    salvage_restorable=$(latest_backup)
    assert "invalid live data enters salvage mode" \
      test "$(jq -r '.salvage' "$root/backups/$salvage_restorable/metadata.json")" = true
    assert "invalid live data warns that the snapshot is unvalidated" \
      sh -c "printf '%s' \"\$1\" | rg -q 'did not validate'" _ "$out"
    assert "restore still succeeds from invalid live data" test "$rc" -eq 0
    assert "restored state is valid again" sb validate

    # Now a salvage snapshot whose *contents* are genuinely corrupt.
    printf 'not json\n' >"$root/data/current/instances.json"
    out=$(sb restore "$backup_id" --yes 2>&1) && rc=0 || rc=$?
    local salvage_corrupt
    salvage_corrupt=$(latest_backup)
    assert "corrupt live data also enters salvage mode" \
      test "$(jq -r '.salvage' "$root/backups/$salvage_corrupt/metadata.json")" = true
    assert "restore from a validated backup repairs corrupt live state" test "$rc" -eq 0
    assert "repaired live state validates" sb validate

    # M1: a salvage snapshot must not be restorable without an explicit flag.
    out=$(sb restore "$salvage_restorable" --yes 2>&1) && rc=0 || rc=$?
    assert "salvage snapshot restore is refused by default" test "$rc" -ne 0
    assert "salvage refusal explains the risk" \
      sh -c "printf '%s' \"\$1\" | rg -q 'unvalidated salvage snapshot and is refused'" _ "$out"
    assert "salvage refusal names the override flag" \
      sh -c "printf '%s' \"\$1\" | rg -q 'restore-unvalidated-salvage'" _ "$out"
    assert "default salvage refusal is not a generic invalid-backup error" \
      sh -c "! printf '%s' \"\$1\" | rg -q '^ERROR: invalid backup'" _ "$out"

    out=$(sb restore "$salvage_restorable" --restore-unvalidated-salvage --yes 2>&1) &&
      rc=0 || rc=$?
    assert "salvage snapshot with sound contents restores under the override" test "$rc" -eq 0
    assert "salvage override emits an unmistakable warning" \
      sh -c "printf '%s' \"\$1\" | rg -q 'DANGEROUS: restoring an UNVALIDATED salvage snapshot'" _ "$out"
    assert "salvage restore is recorded in the publish status" \
      jq -e '.last_publish.description | test("UNVALIDATED salvage snapshot")' \
      "$root/data/status.json" >/dev/null

    # The override is an acknowledgement, not a bypass: content validation still
    # refuses a snapshot that is actually corrupt.
    out=$(sb restore "$salvage_corrupt" --restore-unvalidated-salvage --yes 2>&1) &&
      rc=0 || rc=$?
    assert "override does not bypass validation of genuinely corrupt contents" \
      test "$rc" -ne 0
    assert "corrupt salvage restore leaves the live state valid" sb validate

    # M-3.2: the acknowledgement is per-invocation. An inherited or exported
    # value must not authorise a restore, or one deliberate recovery would
    # silently authorise every later salvage restore in the session.
    out=$(SB_ALLOW_SALVAGE_RESTORE=true sb restore "$salvage_restorable" --yes 2>&1) &&
      rc=0 || rc=$?
    assert "an inherited acknowledgement does not authorise a salvage restore" \
      test "$rc" -ne 0
    assert "an inherited acknowledgement still produces the refusal message" \
      sh -c "printf '%s' \"\$1\" | rg -q 'unvalidated salvage snapshot and is refused'" _ "$out"
    assert "an inherited acknowledgement prints no DANGEROUS warning" \
      sh -c "! printf '%s' \"\$1\" | rg -q 'DANGEROUS'" _ "$out"

    # The same must hold across a process boundary, including the internal
    # `sb restore` that upgrade_rollback spawns.
    out=$(SB_ALLOW_SALVAGE_RESTORE=true env bash -c \
      "'$APP_DIR/sb' restore '$salvage_restorable' --yes" 2>&1) && rc=0 || rc=$?
    assert "an exported acknowledgement does not reach a child sb process" \
      test "$rc" -ne 0

    # Typing the flag on this invocation still works.
    out=$(sb restore "$salvage_restorable" --restore-unvalidated-salvage --yes 2>&1) &&
      rc=0 || rc=$?
    assert "the explicit flag still authorises the invocation that types it" test "$rc" -eq 0

    # M2: the environment must not be able to turn salvage on.
    new_env
    root="$TEST_ROOT"
    init_env
    SB_TXN_SALVAGE_BACKUP=true sb add SS --port 28102 --yes >/dev/null
    newest=$(find "$root/backups" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' |
      sort -rn | head -1 | cut -d' ' -f2-)
    assert "SB_TXN_SALVAGE_BACKUP from the environment cannot enable salvage" \
      test "$(jq -r '.salvage' "$root/backups/$newest/metadata.json")" = false
    SB_TXN_SALVAGE_BACKUP=true sb backup >/dev/null
    newest=$(find "$root/backups" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' |
      sort -rn | head -1 | cut -d' ' -f2-)
    assert "SB_TXN_SALVAGE_BACKUP cannot weaken an explicit sb backup" \
      test "$(jq -r '.salvage' "$root/backups/$newest/metadata.json")" = false
}

# --- HIGH-C: the unrecoverable exit code must survive every caller --------

test_unrecoverable_code_reaches_the_cli() {
    local root backup_id rc out
    new_env
    root="$TEST_ROOT"
    init_env
    sb add HY2 --port 28201 --sni hy.example.com --tls-mode self-signed \
      --masquerade https://hy.example.com --no-hop --yes >/dev/null
    backup_id=$(basename "$(sb backup)")
    touch "$root/runtime/fail-restart"
    out=$(SB_TEST_FAULTS=current-rollback-create sb restore "$backup_id" --yes 2>&1) &&
      rc=0 || rc=$?
    assert "sb restore surfaces the unrecoverable code at the CLI boundary" \
      test "$rc" -eq 70
    assert "sb restore reports the link restore failure" \
      sh -c "printf '%s' \"\$1\" | rg -q 'current generation link could not be restored'" _ "$out"
    assert "sb restore leaves the certificate directory alone after that failure" \
      sh -c "printf '%s' \"\$1\" | rg -q 'leaving the certificate directory untouched'" _ "$out"
    assert "sb restore retains the pre-restore certificates" \
      sh -c "find '$root/data' -maxdepth 1 -name '.cert-before-restore.*' | grep -q ."
    rm -f "$root/runtime/fail-restart"

    # core upgrade must not flatten core_switch's 70 either.
    new_env
    root="$TEST_ROOT"
    init_env
    out=$(SB_TEST_FAULTS="core-post-switch-verify:core-backup-restore" \
      sb core upgrade --yes 2>&1) && rc=0 || rc=$?
    assert "sb core upgrade surfaces the unrecoverable code at the CLI boundary" \
      test "$rc" -eq 70

    # sb install reaches core_switch through core_install, which is a separate
    # call site from `sb core upgrade` and used to flatten the code to 1.
    new_env
    root="$TEST_ROOT"
    init_env
    # Break the receipt digest so core_validate_installed fails while the version
    # still matches: core_install then proceeds into core_switch instead of
    # short-circuiting on "already installed".
    jq '.binary_sha256="0000000000000000000000000000000000000000000000000000000000000000"' \
      "$root/data/core.json" >"$root/data/core.json.tmp"
    mv "$root/data/core.json.tmp" "$root/data/core.json"
    out=$(SB_TEST_FAULTS="core-post-switch-verify:core-backup-restore" \
      sb install --endpoint node.example.com --yes 2>&1) && rc=0 || rc=$?
    assert "sb install surfaces the unrecoverable code at the CLI boundary" \
      test "$rc" -eq 70
    assert "sb install reports the core rollback failure" \
      sh -c "printf '%s' \"\$1\" | rg -q 'previous sing-box binary could not be restored'" _ "$out"
    assert "sb install prints no initialization success message" \
      sh -c "! printf '%s' \"\$1\" | rg -q 'sb manager initialization verified'" _ "$out"
}

# --- HIGH-D: named recovery artifacts must outlive the process ------------

test_recovery_artifacts_survive_exit() {
    local root out rc artifact
    new_env
    root="$TEST_ROOT"
    init_env
    out=$(SB_TEST_FAULTS="core-post-switch-verify:core-backup-restore" \
      sb core upgrade --yes 2>&1) && rc=0 || rc=$?
    assert "core_switch rollback failure is unrecoverable" test "$rc" -eq 70
    artifact=$(rg -o '/[^ ]*\.sing-box\.backup\.[A-Za-z0-9]+' <<<"$out" | head -1)
    assert "core_switch names the retained old binary" test -n "$artifact"
    assert "core_switch's named old binary still exists after exit" test -f "$artifact"

    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 28301 --yes >/dev/null
    touch "$root/runtime/fail-restart"
    out=$(SB_TEST_FAULTS="core-upgrade-restore" sb core upgrade --yes 2>&1) && rc=0 || rc=$?
    assert "core_upgrade rollback failure is unrecoverable" test "$rc" -eq 70
    artifact=$(rg -o '/[^ ]*\.sing-box\.restore\.[A-Za-z0-9]+' <<<"$out" | head -1)
    assert "core_upgrade names the staged old binary" test -n "$artifact"
    assert "core_upgrade's named staged binary still exists after exit" test -f "$artifact"

    # A retained generation is only useful together with its certificate material.
    new_env
    root="$TEST_ROOT"
    init_env
    sb add HY2 --port 28302 --sni hy.example.com --tls-mode self-signed \
      --masquerade https://hy.example.com --no-hop --yes >/dev/null
    touch "$root/runtime/fail-restart"
    out=$(sb edit is01 --port 28303 --yes 2>&1) && rc=0 || rc=$?
    assert "service restore failure returns nonzero" test "$rc" -ne 0
    if rg -q 'rejected generation is retained' <<<"$out"; then
        artifact=$(rg -o '/[^ ]*/generations/[A-Za-z0-9-]+' <<<"$out" | head -1)
        assert "the retained generation still exists after exit" test -d "$artifact"
        assert "the retained generation keeps its certificate material" \
          sh -c "find '$root/data/certs' -name '*.pem' | grep -q ."
    fi
}

# --- M3 / M4 -------------------------------------------------------------

test_ipv4_leading_zero_rejection() {
    local root address rc out
    new_env
    root="$TEST_ROOT"
    init_env
    # Ambiguous octal/decimal literals must never reach settings: the value that
    # would be validated is a different address from the one clients dial.
    for address in 010.0.0.1 0100.64.0.1 08.0.0.1 09.0.0.1 00.0.0.1 172.016.0.1; do
        out=$(sb endpoint set "$address" --yes 2>&1) && rc=0 || rc=$?
        assert "leading-zero literal rejected: $address" test "$rc" -ne 0
        assert "leading-zero literal leaks no raw shell error: $address" \
          sh -c "! printf '%s' \"\$1\" | rg -q 'value too great for base'" _ "$out"
    done
    assert "leading-zero rejections never reach live settings" \
      test "$(jq -r '.endpoint.value' "$root/data/current/settings.json")" = node.example.com
    sb endpoint set 8.8.8.8 --yes >/dev/null
    assert "canonical IPv4 endpoints still work" \
      test "$(jq -r '.endpoint.value' "$root/data/current/settings.json")" = 8.8.8.8
    assert "all-numeric final label is not a hostname" sh -c \
      "! bash -c 'source \"\$1/core/common.sh\"; domain_valid 010.0.0.1' _ '$APP_DIR'"
}

test_doctor_drift_check_without_proc_access() {
    local root
    new_env
    root="$TEST_ROOT"
    init_env
    sb add SS --port 28401 --yes >/dev/null
    # Report a MainPID whose /proc entry cannot be read. That is missing
    # information, not evidence of drift, and must not fail a healthy install.
    printf '99999\n' >"$root/runtime/observed-mainpid"
    assert "unobservable loaded generation is reported as info, not a failure" sh -c \
      "'$APP_DIR/sb' doctor --json 2>/dev/null | jq -e '.results[]|select(.name==\"generation_drift\")|.status==\"info\"' >/dev/null"
    rm -f "$root/runtime/observed-mainpid"
}

test_errexit_audit_guard() {
    assert "no safety-critical command relies on implicit errexit" \
      "$APP_DIR/tests/errexit-audit.sh"
}

TESTS=(
    test_all_protocols
    test_conflicts_and_check_failure
    test_legacy_migration
    test_legacy_endpoint_recovery
    test_legacy_bootstrap_no_deadlock
    test_migration_failure_cleanup_and_retry
    test_cross_pin_upgrade_bootstrap
    test_manager_upgrade_preserves_data
    test_hy2_hopping_matrix
    test_root_routing_and_no_implicit_yes
    test_no_hop_residue
    test_restart_and_rollback
    test_last_node_semantics
    test_repeat_install_preserves_secrets
    test_concurrency_lock
    test_endpoint_validation_and_dry_run
    test_settings_schema_migration
    test_version_and_failure_messages
    test_protocol_parameter_matrix
    test_vless_three_mode_contract
    test_backup_restore_schema_json_doctor
    test_certificate_rotation_transaction
    test_tls_mode_contracts
    test_noninteractive_tls_mode_default
    test_root_installer_and_core_archive
    test_core_upgrade_flow
    test_backup_failure_atomicity
    test_settings_transaction_concurrency_and_rollback
    test_listener_ownership_and_generation
    test_core_digest_adversarial
    test_existing_data_validation
    test_zero_node_reboot_policy
    test_sensitive_logging_and_permissions
    test_secret_redaction_matrix
    test_mainpid_ownership_settle
    test_transaction_publish_fault_injection
    test_transaction_rollback_fault_injection
    test_transaction_fault_across_operations
    test_manager_app_switch_fault_injection
    test_command_link_conflicts
    test_cross_pin_upgrade_rollback
    test_upgrade_data_rollback
    test_listener_expected_observed_divergence
    test_endpoint_special_purpose_matrix
    test_mutator_state_write_fault_injection
    test_salvage_mode_boundaries
    test_unrecoverable_code_reaches_the_cli
    test_recovery_artifacts_survive_exit
    test_ipv4_leading_zero_rejection
    test_doctor_drift_check_without_proc_access
    test_errexit_audit_guard
    test_real_uri_parsers_and_hysteria_tls
)
for test_name in "${TESTS[@]}"; do
    if [[ -z "${SB_TEST_FILTER:-}" || "$test_name" == *"$SB_TEST_FILTER"* ]]; then
        "$test_name"
    fi
done

printf 'RESULT: pass=%d fail=%d\n' "$PASS" "$FAIL"
((FAIL == 0))
