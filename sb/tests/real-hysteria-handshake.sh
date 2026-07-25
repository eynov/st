#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

HYSTERIA_BIN="${1:?hysteria binary is required}"
URI="${2:?Hysteria URI is required}"
CERT="${3:?server certificate is required}"
KEY="${4:?server key is required}"
CA_BUNDLE="${5:-}"

root=$(mktemp -d)
server_pid=""
client_pid=""
http_pid=""
cleanup() {
    [[ -z "$client_pid" ]] || kill "$client_pid" 2>/dev/null || true
    [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
    [[ -z "$http_pid" ]] || kill "$http_pid" 2>/dev/null || true
    rm -rf -- "$root"
}
trap cleanup EXIT

free_port() {
    python3 -c 'import socket
s=socket.socket()
s.bind(("127.0.0.1",0))
print(s.getsockname()[1])
s.close()'
}

hy_port=$(sed -nE 's#^hysteria2://.*@127\.0\.0\.1:([0-9]+)/.*#\1#p' <<<"$URI")
[[ "$hy_port" =~ ^[0-9]+$ ]] || {
    printf 'URI must use a literal 127.0.0.1 test endpoint and one base port\n' >&2
    exit 64
}
socks_port=$(free_port)
http_port=$(free_port)

printf '%s\n' \
  "listen: 127.0.0.1:${hy_port}" \
  'tls:' \
  "  cert: ${CERT}" \
  "  key: ${KEY}" \
  'auth:' \
  '  type: password' \
  '  password: test-hysteria-password' \
  >"$root/server.yaml"
printf '%s\n' \
  "server: \"${URI}\"" \
  'socks5:' \
  "  listen: 127.0.0.1:${socks_port}" \
  >"$root/client.yaml"
printf 'sb-real-hysteria-handshake\n' >"$root/probe.txt"

python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$root" \
  >"$root/http.log" 2>&1 &
http_pid=$!
"$HYSTERIA_BIN" server --disable-update-check -l warn -c "$root/server.yaml" \
  >"$root/server.log" 2>&1 &
server_pid=$!

client_env=()
[[ -z "$CA_BUNDLE" ]] || client_env=("SSL_CERT_FILE=$CA_BUNDLE")
env "${client_env[@]}" "$HYSTERIA_BIN" client --disable-update-check -l warn \
  -c "$root/client.yaml" >"$root/client.log" 2>&1 &
client_pid=$!

ready=false
for _ in {1..50}; do
    kill -0 "$server_pid" "$client_pid" "$http_pid" 2>/dev/null || break
    if ss -H -lnt | awk -v port="$socks_port" '$4 ~ (":" port "$"){found=1} END{exit !found}'; then
        ready=true
        break
    fi
    sleep 0.1
done
[[ "$ready" == "true" ]] || {
    sed -n '1,120p' "${root}/server.log" >&2
    sed -n '1,120p' "${root}/client.log" >&2
    exit 1
}

result=$(curl -fsS --connect-timeout 3 --max-time 8 \
  --socks5-hostname "127.0.0.1:${socks_port}" \
  "http://127.0.0.1:${http_port}/probe.txt") || {
    sed -n '1,120p' "${root}/server.log" >&2
    sed -n '1,120p' "${root}/client.log" >&2
    exit 1
}
[[ "$result" == "sb-real-hysteria-handshake" ]]
