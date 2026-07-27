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
jq -e '.open_ports.tcp == ["10443"] and .open_ports.udp == []' \
    "$CLI_ROOT/state.json" >/dev/null || fail "TCP add"
ok "port CLI adds a single TCP port"

bash "$CLI_ROOT/fw.sh" port add udp 10444 >/dev/null
jq -e '.open_ports.udp == ["10444"]' "$CLI_ROOT/state.json" >/dev/null || fail "UDP add"
ok "port CLI adds a single UDP port"

bash "$CLI_ROOT/fw.sh" port add BoTh 10445 >/dev/null
jq -e '
    (.open_ports.tcp | index("10445")) != null
    and (.open_ports.udp | index("10445")) != null
' "$CLI_ROOT/state.json" >/dev/null || fail "both single add"
ok "both is case-insensitive and adds one port to TCP and UDP"

bash "$CLI_ROOT/fw.sh" port add tcp 20000-20010 >/dev/null
jq -e '.open_ports.tcp | index("20000-20010") != null' \
    "$CLI_ROOT/state.json" >/dev/null || fail "TCP range add"
ok "port CLI adds a TCP range"

bash "$CLI_ROOT/fw.sh" port add udp 30000-30010 >/dev/null
jq -e '.open_ports.udp | index("30000-30010") != null' \
    "$CLI_ROOT/state.json" >/dev/null || fail "UDP range add"
ok "port CLI adds a UDP range"

bash "$CLI_ROOT/fw.sh" port add both 40000-40010 >/dev/null
jq -e '
    (.open_ports.tcp | index("40000-40010")) != null
    and (.open_ports.udp | index("40000-40010")) != null
' "$CLI_ROOT/state.json" >/dev/null || fail "both range add"
ok "both adds one range to TCP and UDP without expansion"

bash "$CLI_ROOT/fw.sh" port add tcp 1 >/dev/null
bash "$CLI_ROOT/fw.sh" port add udp 65535 >/dev/null
jq -e '
    (.open_ports.tcp | index("1")) != null
    and (.open_ports.udp | index("65535")) != null
' "$CLI_ROOT/state.json" >/dev/null || fail "boundary ports"
ok "port CLI accepts boundary ports 1 and 65535"

before=$(sha256sum "$CLI_ROOT/state.json")
bash "$CLI_ROOT/fw.sh" port add both 40000-40010 >/dev/null
after=$(sha256sum "$CLI_ROOT/state.json")
[[ "$before" == "$after" ]] || fail "duplicate both add changed state"
ok "duplicate range add is idempotent"

bash "$CLI_ROOT/fw.sh" port add tcp 50000-50010 >/dev/null
bash "$CLI_ROOT/fw.sh" port add both 50000-50010 >/dev/null
jq -e '
    ([.open_ports.tcp[] | select(. == "50000-50010")] | length) == 1
    and ([.open_ports.udp[] | select(. == "50000-50010")] | length) == 1
' "$CLI_ROOT/state.json" >/dev/null || fail "both and single coexistence"
ok "both fills the missing protocol without duplicating an existing single-protocol rule"

port_list_output=$(bash "$CLI_ROOT/fw.sh" port list)
grep -Fq 'TCP: 1, 10443, 20000-20010' <<< "$port_list_output" ||
    fail "TCP-only list"
grep -Fq 'UDP: 10444, 30000-30010, 65535' <<< "$port_list_output" ||
    fail "UDP-only list"
grep -Fq 'BOTH: 10445, 40000-40010, 50000-50010' <<< "$port_list_output" ||
    fail "both list"
ok "port list clearly separates TCP, UDP and BOTH entries"

bash "$CLI_ROOT/fw.sh" port remove tcp 10443 >/dev/null
jq -e '.open_ports.tcp | index("10443") == null' \
    "$CLI_ROOT/state.json" >/dev/null || fail "single TCP remove"
ok "port CLI removes a single port"

bash "$CLI_ROOT/fw.sh" port remove udp 30000-30010 >/dev/null
jq -e '.open_ports.udp | index("30000-30010") == null' \
    "$CLI_ROOT/state.json" >/dev/null || fail "UDP range remove"
ok "port CLI removes a port range"

bash "$CLI_ROOT/fw.sh" port remove both 40000-40010 >/dev/null
jq -e '
    (.open_ports.tcp | index("40000-40010")) == null
    and (.open_ports.udp | index("40000-40010")) == null
' "$CLI_ROOT/state.json" >/dev/null || fail "both remove"
ok "both removes the exact port specification from TCP and UDP"

invalid_case() {
    local name=$1 proto=$2 spec=$3 pattern=$4 before after
    before=$(sha256sum "$CLI_ROOT/state.json")
    if bash "$CLI_ROOT/fw.sh" port add "$proto" "$spec" \
        >"$TEST_ROOT/$name.out" 2>&1; then
        fail "$name should fail"
    fi
    grep -q "$pattern" "$TEST_ROOT/$name.out" || fail "$name error message"
    after=$(sha256sum "$CLI_ROOT/state.json")
    [[ "$before" == "$after" ]] || fail "$name changed state"
    ok "port CLI rejects $name without changing state"
}

invalid_case invalid-protocol sctp 10443 'tcp、udp 或 both'
invalid_case empty-port tcp '' '整数或 START-END'
invalid_case port-zero tcp 0 '1-65535'
invalid_case port-overflow tcp 65536 '1-65535'
invalid_case reversed-range tcp 61000-60000 '起始端口'
invalid_case missing-end tcp 60000- '整数或 START-END'
invalid_case missing-start tcp -61000 '整数或 START-END'
invalid_case multiple-hyphens tcp 60000-61000-62000 '整数或 START-END'
invalid_case alphabetic tcp abc '整数或 START-END'

before=$(sha256sum "$CLI_ROOT/state.json")
if FWCTL_NFT_BIN=/bin/false \
    bash "$CLI_ROOT/fw.sh" port add both 61000-62000 \
    >"$TEST_ROOT/render-failure.out" 2>&1; then
    fail "render failure should reject the port update"
fi
after=$(sha256sum "$CLI_ROOT/state.json")
[[ "$before" == "$after" ]] || fail "render failure changed state"
! find "$CLI_ROOT" -maxdepth 1 -name '.state.json.*' -print -quit | grep -q . ||
    fail "render failure left a candidate state"
ok "render failure preserves state and removes the candidate"

legacy_state="$TEST_ROOT/legacy-state.json"
jq '.open_ports = {"tcp":["443","80"],"udp":["53"]}' \
    "$PROJECT_DIR/state.json" > "$legacy_state"
render_case legacy "$legacy_state" 198.51.100.10 "10.0.0.10"
grep -q 'elements = { 80, 443 }' "$TEST_ROOT/legacy/build/nft.conf" ||
    fail "legacy TCP ports"
grep -q 'elements = { 53 }' "$TEST_ROOT/legacy/build/nft.conf" ||
    fail "legacy UDP ports"
ok "legacy single-port state remains compatible"

bash "$CLI_ROOT/fw.sh" port add both 60000-61000 >/dev/null
bash "$CLI_ROOT/fw.sh" render >/dev/null
first=$(sha256sum "$CLI_ROOT/build/nft.conf")
bash "$CLI_ROOT/fw.sh" render >/dev/null
second=$(sha256sum "$CLI_ROOT/build/nft.conf")
[[ "$first" == "$second" ]] || fail "render is not stable"
grep -q 'elements = { 1, 10445, 20000-20010, 50000-50010, 60000-61000 }' \
    "$CLI_ROOT/build/nft.conf" || fail "TCP range render"
grep -q 'elements = { 10444, 10445, 50000-50010, 60000-61000, 65535 }' \
    "$CLI_ROOT/build/nft.conf" || fail "UDP range render"
ok "ranges render as native interval elements and repeated renders are byte-identical"

ssh_line=$(grep -n 'tcp dport 37091 accept' "$CLI_ROOT/build/nft.conf" | cut -d: -f1)
allowed_line=$(grep -n 'tcp dport @allowed_ports_tcp accept' "$CLI_ROOT/build/nft.conf" | cut -d: -f1)
limit_line=$(grep -n 'tcp flags syn limit rate over' "$CLI_ROOT/build/nft.conf" | cut -d: -f1)
((ssh_line < limit_line && allowed_line < limit_line)) || fail "SYN limiter precedes allowed TCP ports"
ok "SSH and allowed TCP ports precede the global SYN limiter"

echo "1..$pass"
