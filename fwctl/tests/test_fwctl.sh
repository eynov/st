#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail() {
    echo "not ok - $*" >&2
    exit 1
}
ok() {
    pass=$((pass + 1))
    echo "ok $pass - $*"
}

make_state() {
    local path=$1 mode=$2 address=$3
    jq \
        --arg mode "$mode" \
        --arg address "$address" \
        '.nat_mode = $mode
         | .snat_address = (if $address == "" then null else $address end)
         | .forwards = [
             {"sport":"29312","dport":"29312","dip":"192.0.2.20","proto":"tcp","dest_port":"29312"},
             {"sport":"29312","dport":"29312","dip":"192.0.2.20","proto":"udp","dest_port":"29312"}
           ]' \
        "$PROJECT_DIR/state.json" > "$path"
}

render_case() {
    local name=$1 state=$2 public_ip=$3 local_ips=$4
    local output_dir="$TEST_ROOT/$name"
    mkdir -p "$output_dir"
    FWCTL_ALLOW_UNPRIVILEGED=1 \
    FWCTL_SKIP_SYSTEM_SETUP=1 \
    FWCTL_APPLY=0 \
    FWCTL_STATE_FILE="$state" \
    FWCTL_BUILD_DIR="$output_dir/build" \
    FWCTL_SYSTEM_CONF="$output_dir/nftables.conf" \
    FWCTL_NFT_BIN="$PROJECT_DIR/tests/fake-nft" \
    FWCTL_LOCKFILE="$output_dir/render.lock" \
    FWCTL_PUBLIC_IPV4="$public_ip" \
    FWCTL_LOCAL_IPV4S="$local_ips" \
    FWCTL_SSH_PORT=37091 \
        bash "$PROJECT_DIR/render.sh" --render-only >"$output_dir/stdout" 2>"$output_dir/stderr"
}

state="$TEST_ROOT/auto-local.json"
make_state "$state" auto ""
render_case auto-local "$state" 198.51.100.10 "127.0.0.1 198.51.100.10"
grep -q 'snat to 198.51.100.10' "$TEST_ROOT/auto-local/build/nft.conf" || fail "auto local address"
ok "auto uses explicit SNAT when public IPv4 is local"

state="$TEST_ROOT/auto-eip.json"
make_state "$state" auto ""
render_case auto-eip "$state" 198.51.100.10 "127.0.0.1 10.0.0.10"
grep -q 'dport 29312 masquerade' "$TEST_ROOT/auto-eip/build/nft.conf" || fail "auto EIP fallback"
ok "auto uses masquerade when public IPv4 is not local"

state="$TEST_ROOT/forced-masq.json"
make_state "$state" masquerade "198.51.100.10"
render_case forced-masq "$state" 198.51.100.10 "198.51.100.10"
grep -q 'dport 29312 masquerade' "$TEST_ROOT/forced-masq/build/nft.conf" || fail "forced masquerade"
ok "masquerade mode always uses masquerade"

state="$TEST_ROOT/invalid-snat.json"
make_state "$state" snat "198.51.100.10"
if render_case invalid-snat "$state" 198.51.100.10 "10.0.0.10"; then
    fail "non-local forced SNAT should fail"
fi
grep -q '未配置在本机' "$TEST_ROOT/invalid-snat/stderr" || fail "missing forced SNAT error"
ok "snat mode rejects a non-local address"

state="$TEST_ROOT/invalid-mode.json"
make_state "$state" invalid ""
if render_case invalid-mode "$state" 198.51.100.10 "10.0.0.10"; then
    fail "invalid mode should fail"
fi
grep -q '允许值' "$TEST_ROOT/invalid-mode/stderr" || fail "missing invalid mode error"
ok "invalid nat_mode fails with allowed values"

CLI_ROOT="$TEST_ROOT/cli"
cp -a "$PROJECT_DIR" "$CLI_ROOT"
export FWCTL_SKIP_SYSTEM_SETUP=1
export FWCTL_APPLY=0
export FWCTL_BUILD_DIR="$CLI_ROOT/build"
export FWCTL_SYSTEM_CONF="$TEST_ROOT/cli-system.conf"
export FWCTL_NFT_BIN="$CLI_ROOT/tests/fake-nft"
export FWCTL_LOCKFILE="$TEST_ROOT/cli.lock"
export FWCTL_PUBLIC_IPV4=198.51.100.10
export FWCTL_LOCAL_IPV4S=10.0.0.10
export FWCTL_SSH_PORT=37091

bash "$CLI_ROOT/fw.sh" port add tcp 10443 >/dev/null
jq -e '.open_ports.tcp == ["10443"]' "$CLI_ROOT/state.json" >/dev/null || fail "TCP add"
ok "port CLI adds a TCP port"

bash "$CLI_ROOT/fw.sh" port add udp 10443 >/dev/null
jq -e '.open_ports.udp == ["10443"]' "$CLI_ROOT/state.json" >/dev/null || fail "UDP add"
ok "port CLI adds a UDP port"

before=$(sha256sum "$CLI_ROOT/state.json")
bash "$CLI_ROOT/fw.sh" port add tcp 10443 >/dev/null
after=$(sha256sum "$CLI_ROOT/state.json")
[[ "$before" == "$after" ]] || fail "duplicate add changed state"
ok "duplicate port add is idempotent"

bash "$CLI_ROOT/fw.sh" port remove tcp 10443 >/dev/null
jq -e '.open_ports.tcp == []' "$CLI_ROOT/state.json" >/dev/null || fail "TCP remove"
ok "port CLI removes a port"

if bash "$CLI_ROOT/fw.sh" port add sctp 10443 >"$TEST_ROOT/bad-proto.out" 2>&1; then
    fail "invalid protocol should fail"
fi
grep -q '只允许 tcp 或 udp' "$TEST_ROOT/bad-proto.out" || fail "invalid protocol message"
ok "port CLI rejects an invalid protocol"

if bash "$CLI_ROOT/fw.sh" port add tcp 65536 >"$TEST_ROOT/bad-port.out" 2>&1; then
    fail "out-of-range port should fail"
fi
grep -q '1-65535' "$TEST_ROOT/bad-port.out" || fail "invalid port message"
ok "port CLI rejects an out-of-range port"

bash "$CLI_ROOT/fw.sh" port add tcp 443 >/dev/null
bash "$CLI_ROOT/fw.sh" render >/dev/null
first=$(sha256sum "$CLI_ROOT/build/nft.conf")
bash "$CLI_ROOT/fw.sh" render >/dev/null
second=$(sha256sum "$CLI_ROOT/build/nft.conf")
[[ "$first" == "$second" ]] || fail "render is not stable"
grep -q 'elements = { 443 }' "$CLI_ROOT/build/nft.conf" || fail "port disappeared after render"
! grep -q 'elements = { 65535 }' "$CLI_ROOT/build/nft.conf" || fail "placeholder returned"
ok "ports persist and two renders are byte-identical"

echo "1..$pass"
