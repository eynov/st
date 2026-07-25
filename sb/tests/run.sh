#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_CORE="${SB_TEST_REAL_CORE:-/tmp/sb-core-1.13.14/sing-box}"
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
    export SB_CORE_ARCHIVE="/tmp/sb-core-1.13.14/sing-box.tar.gz"
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
    sb add VLESS --port 10004 --server-name www.microsoft.com --yes >/dev/null
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
    if sb add VLESS --port 17001 --server-name www.microsoft.com --yes >/dev/null 2>&1; then
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

test_manager_upgrade_preserves_data() {
    local root before after password uuid cert_hash releases password_hash uuid_hash
    new_env
    root="$TEST_ROOT"
    init_env
    sb add ANYTLS --port 19001 --sni any.example.com --tls-mode self-signed --yes >/dev/null
    sb add VLESS --port 19002 --server-name www.microsoft.com --yes >/dev/null
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
    assert "manager upgrades use staged releases" test "$releases" -eq 2
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
      '.last_rollback.performed==true and .last_rollback.result=="failed"' \
      "$root/data/status.json"
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
    sb add VLESS --port 21004 --server-name www.microsoft.com --yes >/dev/null
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
    archive="/tmp/sb-core-1.13.14/sing-box.tar.gz"
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
      "$("$SB_BIN" version | awk 'NR==1{print $3}')" = "1.13.14"
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
    export SB_CORE_ARCHIVE="/tmp/sb-core-1.13.14/sing-box.tar.gz"
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

test_core_digest_adversarial() {
    local root fake_dir bad_app rc wrong_archive wrong_hash
    new_env
    root="$TEST_ROOT"
    init_env
    printf '%s\n' '#!/usr/bin/env bash' \
      'if [[ "${1:-}" == version ]]; then echo "sing-box version 1.13.14"; else exit 0; fi' \
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
      'sing-box version 1.13.14' "$root/bin/sing-box"
    sb core install >/dev/null
    assert "same-version forged core is repaired" test \
      "$(sha256sum "$root/bin/sing-box" | awk '{print $1}')" = \
      "$(jq -r '.versions["1.13.14"]["linux-amd64"].binary_sha256' "$APP_DIR/checksums.json")"

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
    jq '.versions["1.13.14"]["linux-amd64"].sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
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

TESTS=(
    test_all_protocols
    test_conflicts_and_check_failure
    test_legacy_migration
    test_migration_failure_cleanup_and_retry
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
    test_backup_restore_schema_json_doctor
    test_certificate_rotation_transaction
    test_tls_mode_contracts
    test_root_installer_and_core_archive
    test_core_upgrade_flow
    test_backup_failure_atomicity
    test_settings_transaction_concurrency_and_rollback
    test_listener_ownership_and_generation
    test_core_digest_adversarial
    test_existing_data_validation
    test_zero_node_reboot_policy
    test_sensitive_logging_and_permissions
    test_real_uri_parsers_and_hysteria_tls
)
for test_name in "${TESTS[@]}"; do
    if [[ -z "${SB_TEST_FILTER:-}" || "$test_name" == *"$SB_TEST_FILTER"* ]]; then
        "$test_name"
    fi
done

printf 'RESULT: pass=%d fail=%d\n' "$PASS" "$FAIL"
((FAIL == 0))
