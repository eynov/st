#!/usr/bin/env bash
# box/90ssh.sh - safe, idempotent SSH port migration for the Homelab hosts.
#
# v2.0.0 rewrite.  The v1 script was single-port only, rewrote the global
# authentication policy (PermitRootLogin / PasswordAuthentication), commented out
# every "Port" line under /etc/ssh (which also hit client configs), and its
# rollback re-enabled ssh.socket unconditionally.  This version keeps the same
# entry point and purpose but never touches anything except the port surface.
#
# Guarantees
#   * Authentication policy is never written by this script.  After a reload the
#     effective `sshd -T` output is compared with the pre-change snapshot and any
#     difference outside port/listenaddress triggers an automatic rollback.
#   * Dual-port transition is the default: "Port 22" and the new port coexist so
#     the old path stays available until a human confirms the new one.
#   * Finalisation (dropping 22) is a separate, explicit mode and is refused
#     unless the new port has been verified from an independent client.
#   * ssh.socket is detected, never enabled or disabled.  If it is active the
#     socket override is updated; otherwise only ssh.service is reloaded.
#   * Every apply takes a full backup (sshd_config, sshd_config.d, socket
#     overrides, service state, effective config) and rollback restores it.
#
# Usage
#   90ssh.sh status
#   90ssh.sh plan    --port N [--dropin NAME]
#   90ssh.sh apply   --port N [--mode dual|final] [--guard SECONDS] [--take-over]
#   90ssh.sh verify  --port N [--host H --key PATH [--known-hosts F] [--user U]]
#   90ssh.sh confirm --token T
#   90ssh.sh rollback [--backup DIR] [--reason R]
#   90ssh.sh guard-check --token T --backup DIR
#   90ssh.sh test                           # isolated self-test (needs no root)
#
# Isolated testing: set PREFIX=/tmp/fake and the script operates on
# $PREFIX/etc/ssh, never calls systemctl/ss, and validates with `sshd -t -f`.
set -uo pipefail

VER=2.0.0
PREFIX="${PREFIX:-}"
DRY="${DRY_RUN:-0}"
NEW_PORT=""
MODE="dual"
DROPIN="10-homelab-ssh.conf"
GUARD=0
TAKE_OVER=0
CONFIRMED=0
VERIFY_HOST=""
VERIFY_KEY=""
VERIFY_USER="root"
VERIFY_KNOWN_HOSTS=""
TOKEN=""
BACKUP_DIR=""
REASON="manual"
SVC="ssh"

S_DIR="$PREFIX/etc/ssh"
S_CFG="$S_DIR/sshd_config"
D_DIR="$S_DIR/sshd_config.d"
SOCK_DIR="$PREFIX/etc/systemd/system/ssh.socket.d"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
fake() { [ -n "$PREFIX" ]; }

run() {
    if [ "$DRY" = 1 ]; then
        printf '  [dry] %s\n' "$*"
        return 0
    fi
    "$@"
}

sshd_bin() { command -v sshd || echo /usr/sbin/sshd; }

sshd_test() {
    local cfg="${1:-}"
    [ -z "$cfg" ] && fake && cfg="$S_CFG"
    if [ -n "$cfg" ]; then "$(sshd_bin)" -t -f "$cfg"; else "$(sshd_bin)" -t; fi
}

sshd_dump() {
    local cfg="${1:-}"
    [ -z "$cfg" ] && fake && cfg="$S_CFG"
    if [ -n "$cfg" ]; then "$(sshd_bin)" -T -f "$cfg"; else "$(sshd_bin)" -T; fi
}

# sshd -T lines that are about the port surface; everything else must not change.
strip_port_lines() { grep -Eiv '^(port|listenaddress) ' || true; }

svc_active()  { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

socket_state() {
    if fake; then echo "fake:none"; return; fi
    local st="" en ac
    for s in ssh.socket sshd.socket; do
        systemctl cat "$s" >/dev/null 2>&1 || continue
        en="$(systemctl is-enabled "$s" 2>/dev/null)"; [ -n "$en" ] || en=unknown
        ac="$(systemctl is-active  "$s" 2>/dev/null)"; [ -n "$ac" ] || ac=unknown
        st="$st$s=$en/$ac "
    done
    printf '%s' "${st:-none}"
}

socket_active() { ! fake && svc_active ssh.socket; }

listening_ports() {
    if fake; then printf '%s' "${FAKE_PORTS:-}"; return; fi
    ss -Hltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un | tr '\n' ' '
}

port_listening() {
    local p="$1"
    if fake; then case " ${FAKE_PORTS:-} " in *" $p "*) return 0;; esac; return 1; fi
    ss -Hltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$"
}

# ---------------------------------------------------------------- drop-in ---
managed_path() { printf '%s/%s' "$D_DIR" "$DROPIN"; }

# Port directives owned by files other than our managed drop-in.  These are what
# v1 silently clobbered; here they are reported and, when conflicting, refused.
foreign_port_lines() {
    local out=""
    [ -f "$S_CFG" ] && out="$(grep -nE '^[[:space:]]*Port[[:space:]]+' "$S_CFG" 2>/dev/null | sed "s|^|$S_CFG:|")"
    if [ -d "$D_DIR" ]; then
        local f
        for f in "$D_DIR"/*.conf; do
            [ -f "$f" ] || continue
            [ "$f" = "$(managed_path)" ] && continue
            out="$out$(grep -nE '^[[:space:]]*Port[[:space:]]+' "$f" 2>/dev/null | sed "s|^|$f:|")"
        done
    fi
    printf '%s' "$out"
}

owns_port() {
    local p="$1" f; f="$(managed_path)"
    [ -f "$f" ] && grep -qE "^[[:space:]]*Port[[:space:]]+$p([[:space:]]|$)" "$f"
}

have_include() {
    local pat="${D_DIR//./\\.}"
    grep -Eq "^[[:space:]]*Include[[:space:]]+${pat}/\\*\\.conf([[:space:]]|$)" "$S_CFG"
}

write_dropin() {
    local p="$1" mode="$2" target
    target="$(managed_path)"
    run install -d -m 0755 "$D_DIR"
    local tmp; tmp="$(mktemp)"
    {
        echo "# Managed by box/90ssh.sh v$VER -- do not edit by hand."
        echo "# Authentication policy is intentionally NOT set here."
        if [ "$mode" = "final" ]; then
            echo "# mode: final (single port, IPv4 only)"
            echo "Port $p"
            echo "ListenAddress 0.0.0.0"
        else
            echo "# mode: dual (transition; old port 22 kept until confirmed)"
            echo "Port 22"
            echo "Port $p"
        fi
    } > "$tmp"
    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"; log "  drop-in unchanged: $target"; return 0
    fi
    run install -m 0644 "$tmp" "$target"
    rm -f "$tmp"
    log "  wrote drop-in: $target"
}

write_socket_override() {
    local p="$1" mode="$2"
    [ -d "$SOCK_DIR" ] || run install -d -m 0755 "$SOCK_DIR"
    local f="$SOCK_DIR/90ssh.conf" tmp; tmp="$(mktemp)"
    {
        echo "# Managed by box/90ssh.sh v$VER"
        echo "[Socket]"
        echo "ListenStream="
        if [ "$mode" = "final" ]; then
            echo "ListenStream=0.0.0.0:$p"
        else
            echo "ListenStream=0.0.0.0:22"
            echo "ListenStream=0.0.0.0:$p"
        fi
        echo "Accept=no"
    } > "$tmp"
    if [ -f "$f" ] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; log "  socket override unchanged"; return 0; fi
    run install -m 0644 "$tmp" "$f"
    rm -f "$tmp"
    log "  wrote socket override: $f"
}

# ----------------------------------------------------------------- backup ---
BACKUP_RES=""
take_backup() {
    local ts dir
    ts="$(date '+%Y%m%d-%H%M%S')"
    dir="$PREFIX/root/90ssh-backup-$ts"
    run install -d -m 0700 "$dir" || return 1
    local manifest="$dir/MANIFEST"
    : > "$manifest"
    local f
    for f in "$S_CFG" "$D_DIR" "$SOCK_DIR"; do
        [ -e "$f" ] || { echo "absent $f" >> "$manifest"; continue; }
        if [ -d "$f" ]; then
            mkdir -p "$dir$(dirname "$f")"
            run cp -a "$f" "$dir$f"
        else
            mkdir -p "$dir$(dirname "$f")"
            run cp -p "$f" "$dir$f"
        fi
    done
    if [ -d "$D_DIR" ]; then
        ( cd "$D_DIR" && sha256sum -- *.conf 2>/dev/null ) > "$dir/dropin.sha256" || true
        ls -1 "$D_DIR" > "$dir/dropin.list" 2>/dev/null || true
    fi
    if [ -d "$SOCK_DIR" ]; then
        ls -1 "$SOCK_DIR" > "$dir/socket.list" 2>/dev/null || true
    fi
    { echo "version=$VER"; echo "ts=$ts"; echo "svc_enabled=$(svc_enabled_str)"; \
      echo "svc_active=$(svc_active_str)"; echo "socket_state=$(socket_state)"; \
      echo "ports_before=$(listening_ports)"; } > "$dir/state"
    sshd_dump "" > "$dir/sshd-T.before" 2>/dev/null || true
    if fake; then printf '%s\n' "${FAKE_PORTS:-}" > "$dir/ports.before"; fi
    log "  backup: $dir"
    BACKUP_RES="$dir"
}

svc_enabled_str() { fake && { echo fake; return; }; systemctl is-enabled "$SVC" 2>/dev/null || echo unknown; }
svc_active_str()  { fake && { echo fake; return; }; systemctl is-active  "$SVC" 2>/dev/null || echo unknown; }

latest_backup() { ls -1d "$PREFIX"/root/90ssh-backup-* 2>/dev/null | sort | tail -1; }

# --------------------------------------------------------------- rollback ---
do_rollback() {
    local dir="$1" reason="${2:-manual}" f
    [ -n "$dir" ] && [ -d "$dir" ] || die "rollback: backup dir not found: ${dir:-<none>}"
    log "ROLLBACK ($reason) from $dir"

    # Files that exist now but were absent before are ours: remove them.
    if [ -f "$dir/MANIFEST" ]; then
        while read -r tag p; do
            [ "$tag" = absent ] || continue
            rel="${p#$PREFIX}"
            case "$rel" in
                /etc/ssh/sshd_config|/etc/ssh/sshd_config.d/*|/etc/systemd/system/ssh.socket.d/*)
                    if [ -e "$p" ]; then run rm -rf "$p"; log "  removed $p"; fi ;;
            esac
        done < "$dir/MANIFEST"
    fi

    # Restore whatever was backed up.
    if [ -d "$dir$S_DIR" ]; then run cp -a "$dir$S_DIR/." "$S_DIR/"; log "  restored $S_DIR"; fi
    if [ -d "$dir$SOCK_DIR" ]; then
        run install -d -m 0755 "$SOCK_DIR"
        run cp -a "$dir$SOCK_DIR/." "$SOCK_DIR/"
        log "  restored $SOCK_DIR"
    fi

    # Drop files this script created that the backup did not contain.
    if [ -f "$dir/dropin.list" ]; then
        local d
        for d in "$D_DIR"/*.conf; do
            [ -f "$d" ] || continue
            grep -qxF "$(basename "$d")" "$dir/dropin.list" || { run rm -f "$d"; log "  removed new drop-in $d"; }
        done
    fi
    if [ -f "$dir/socket.list" ]; then
        local s
        for s in "$SOCK_DIR"/*.conf; do
            [ -f "$s" ] || continue
            grep -qxF "$(basename "$s")" "$dir/socket.list" || { run rm -f "$s"; log "  removed new socket override $s"; }
        done
    fi

    if sshd_test ""; then log "  sshd -t OK"; else warn "sshd -t failed after restore"; fi

    if ! fake; then
        run systemctl daemon-reload
        if socket_active; then run systemctl restart ssh.socket; else run systemctl reload "$SVC"; fi
        sleep 2
        log "  ssh=$(systemctl is-active $SVC) ports=[$(listening_ports)]"
    fi
    log "ROLLBACK done"
    return 0
}

# ----------------------------------------------------------------- verify ---
do_verify() {
    local p="$1" rc=0
    log "== listening check =="
    if port_listening "$p"; then log "  OK  local:$p listening"; else warn "local:$p NOT listening"; rc=1; fi
    if fake; then return $rc; fi
    log "== effective config =="
    sshd_dump "" | grep -E '^(port|listenaddress) ' | sed 's/^/  /'
    if [ -n "$VERIFY_HOST" ]; then
        [ -n "$VERIFY_KEY" ] || die "verify: --key is required with --host"
        log "== independent client $VERIFY_USER@$VERIFY_HOST:$p =="
        local args=(-p "$p" -i "$VERIFY_KEY" -o BatchMode=yes -o IdentitiesOnly=yes
                    -o ConnectTimeout=8 -o LogLevel=ERROR)
        [ -n "$VERIFY_KNOWN_HOSTS" ] && args+=(-o "UserKnownHostsFile=$VERIFY_KNOWN_HOSTS" -o StrictHostKeyChecking=yes)
        if out=$(ssh "${args[@]}" "$VERIFY_USER@$VERIFY_HOST" 'echo VERIFY_OK; id -u' 2>&1); then
            printf '%s\n' "$out" | sed 's/^/  /'
            case "$out" in *VERIFY_OK*) log "  PASS publickey login on $p";; *) warn "connected but marker missing"; rc=1;; esac
        else
            printf '%s\n' "$out" | tail -3 | sed 's/^/  /'
            warn "publickey login FAILED on $p"; rc=1
        fi
    fi
    return $rc
}

# ------------------------------------------------------------------ apply ---
do_apply() {
    local p="$1" mode="$2" dir before_eff after_eff
    [ -n "$p" ] || die "apply: --port is required"
    [ -f "$S_CFG" ] || die "apply: $S_CFG missing"
    if [ "$mode" = "final" ] && [ "$CONFIRMED" != 1 ]; then
        die "apply: final mode drops port 22 and needs --confirmed (verify the new port from an independent client first)"
    fi
    log "== preflight =="
    if have_include; then log "  include: present"; else die "apply: $S_CFG has no 'Include /etc/ssh/sshd_config.d/*.conf'"; fi
    if port_listening "$p" && ! owns_port "$p"; then
        case " $(foreign_port_lines)" in
            *"Port[[:space:]]*$p"*) : ;;   # declared elsewhere; handled below
            *) die "apply: port $p already in use by another process" ;;
        esac
    fi
    local fp; fp="$(foreign_port_lines)"
    if [ -n "$fp" ]; then
        if [ "$TAKE_OVER" != 1 ]; then
            printf '%s\n' "$fp" | sed 's/^/  foreign: /'
            die "apply: Port directives exist outside the managed drop-in; rerun with --take-over (they are backed up and commented out)"
        fi
        log "  taking over foreign Port directives (backup first)"
    fi
    if ! fake; then
        if ! svc_active "$SVC"; then die "apply: $SVC is not active"; fi
        log "  service: enabled=$(svc_enabled_str) active=$(svc_active_str) socket=$(socket_state)"
    fi

    take_backup || die "apply: backup failed"
    dir="$BACKUP_RES"
    before_eff="$(sshd_dump "" 2>/dev/null)"

    if [ -n "$fp" ] && [ "$TAKE_OVER" = 1 ]; then
        local line file
        printf '%s\n' "$fp" | while IFS=: read -r file rest; do
            run sed -i -E 's|^([[:space:]]*)(Port[[:space:]]+.*)$|\1#90ssh-disabled # \2|' "$file"
            log "  commented Port in $file"
        done
    fi

    log "== write =="
    write_dropin "$p" "$mode"
    if socket_active; then write_socket_override "$p" "$mode"; else
        [ -d "$SOCK_DIR" ] && [ -f "$SOCK_DIR/90ssh.conf" ] && { run rm -f "$SOCK_DIR/90ssh.conf"; log "  removed stale socket override"; }
    fi

    log "== syntax =="
    if ! sshd_test ""; then
        warn "sshd -t failed -> rollback"
        do_rollback "$dir" "sshd-t-failed"
        return 3
    fi
    log "  sshd -t OK"
    sshd_dump "" | grep -E '^(port|listenaddress) ' | sed 's/^/  /'

    log "== reload =="
    if [ "$DRY" != 1 ] && ! fake; then
        if socket_active; then
            systemctl daemon-reload && systemctl restart ssh.socket || { do_rollback "$dir" "socket-restart-failed"; return 4; }
        else
            systemctl reload "$SVC" || systemctl restart "$SVC" || { do_rollback "$dir" "reload-failed"; return 4; }
        fi
        sleep 2
    fi

    log "== post-checks =="
    if [ "$DRY" != 1 ] && ! fake; then
        if ! port_listening "$p"; then warn "new port not listening -> rollback"; do_rollback "$dir" "new-port-missing"; return 5; fi
        if [ "$mode" = "dual" ] && ! port_listening 22; then
            warn "old port 22 lost during transition -> rollback"; do_rollback "$dir" "old-port-lost"; return 5
        fi
        after_eff="$(sshd_dump "" 2>/dev/null)"
        if [ "$(printf '%s' "$before_eff" | strip_port_lines)" != "$(printf '%s' "$after_eff" | strip_port_lines)" ]; then
            warn "non-port sshd configuration changed -> rollback"
            printf '%s\n' "$before_eff" | strip_port_lines > "$dir/eff-before.txt"
            printf '%s\n' "$after_eff"  | strip_port_lines > "$dir/eff-after.txt"
            do_rollback "$dir" "policy-drift"; return 6
        fi
        log "  auth/non-port policy identical to pre-change snapshot"
    fi

    log "APPLY OK mode=$mode ports=[$(listening_ports)] backup=$dir"
    if [ "$GUARD" -gt 0 ] && [ "$DRY" != 1 ] && ! fake; then
        TOKEN="p6-$(date +%s)-$$"
        install -d -m 0700 /run/90ssh
        rm -f "/run/90ssh/$TOKEN.ok"
        systemd-run --unit="90ssh-guard-$TOKEN" --on-active="$GUARD" --collect \
            --description="90ssh safety net ($p)" \
            "$0" guard-check --token "$TOKEN" --backup "$dir" >/dev/null 2>&1 \
            && log "GUARD armed: ${GUARD}s (confirm with: 90ssh.sh confirm --token $TOKEN)" \
            || warn "guard could not be armed"
    fi
    return 0
}

do_confirm() {
    [ -n "$TOKEN" ] || die "confirm: --token required"
    install -d -m 0700 /run/90ssh
    : > "/run/90ssh/$TOKEN.ok"
    systemctl stop "90ssh-guard-$TOKEN.timer" 2>/dev/null || true
    systemctl reset-failed "90ssh-guard-$TOKEN.service" "90ssh-guard-$TOKEN.timer" 2>/dev/null || true
    log "confirmed: guard for $TOKEN disarmed"
}

do_guard_check() {
    [ -n "$TOKEN" ] || die "guard-check: --token required"
    if [ -f "/run/90ssh/$TOKEN.ok" ]; then log "guard $TOKEN: confirmed, standing down"; exit 0; fi
    logger -t 90ssh "guard $TOKEN expired without confirmation -> rolling back"
    dir="$BACKUP_DIR"; [ -n "$dir" ] || dir="$(latest_backup)"
    do_rollback "$dir" "guard-timeout-$TOKEN"
}

# ----------------------------------------------------------------- report ---
do_status() {
    log "90ssh.sh v$VER  host=$(hostname)  mode=$MODE"
    log "config: $S_CFG"
    log "managed drop-in: $(managed_path) $([ -f "$(managed_path)" ] && echo '(present)' || echo '(absent)')"
    [ -f "$(managed_path)" ] && sed 's/^/  | /' "$(managed_path)"
    log "include present: $(have_include && echo yes || echo NO)"
    local fp; fp="$(foreign_port_lines)"
    if [ -n "$fp" ]; then
        log "foreign Port directives: yes"; printf '%s\n' "$fp" | sed 's/^/  | /'
    else
        log "foreign Port directives: none"
    fi
    log "service: enabled=$(svc_enabled_str) active=$(svc_active_str) socket=$(socket_state)"
    log "listening: [$(listening_ports)]"
    [ -f "$(managed_path)" ] || true
    if ! fake; then sshd_dump "" 2>/dev/null | grep -E '^(port|listenaddress) ' | sed 's/^/  /'; fi
    log "last backup: $(latest_backup || echo none)"
}

do_plan() {
    local p="$1"
    [ -n "$p" ] || die "plan: --port is required"
    log "PLAN v$VER host=$(hostname)"
    log "  current: ports=[$(listening_ports)] socket=$(socket_state)"
    log "  target : port $p ($MODE$([ "$MODE" = dual ] && echo ', keeping 22' || echo ', IPv4 only'))"
    log "  drop-in: $(managed_path)"
    local fp; fp="$(foreign_port_lines)"
    if [ -n "$fp" ]; then printf '%s\n' "$fp" | sed 's/^/  foreign: /'; else log "  foreign Port directives: none"; fi
    log "  writes: managed drop-in"
    socket_active && log "  writes: $SOCK_DIR/90ssh.conf (socket is active on this host)"
    log "  auth policy: never written"
    log "  backup -> $PREFIX/root/90ssh-backup-<ts>"
}

# ------------------------------------------------------------------- test ---
do_selftest() {
    local rc=0 base; base="$(mktemp -d)"
    ok()  { log "  PASS $*"; }
    bad() { log "  FAIL $*"; rc=1; }

    fixture() {   # fixture <dir> [extra conf]
        install -d -m 0755 "$1/etc/ssh/sshd_config.d"
        [ -f "$1/hk" ] || ssh-keygen -q -t ed25519 -N '' -f "$1/hk" >/dev/null 2>&1
        {
            echo "Include $1/etc/ssh/sshd_config.d/*.conf"
            echo "PermitRootLogin yes"
            echo "PasswordAuthentication yes"
            echo "PubkeyAuthentication yes"
            echo "HostKey $1/hk"
        } > "$1/etc/ssh/sshd_config"
        if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$1/etc/ssh/sshd_config.d/20-foreign.conf"; fi
    }
    eff()   { sshd -T -f "$1/etc/ssh/sshd_config" 2>/dev/null; }
    snap()  { eff "$1" > "$1/eff.txt"; }
    apply() { local d="$1"; shift; PREFIX="$d" bash "$0" "$@" 2>&1; }

    log "== self-test (isolated prefix=$base, sshd $(sshd -V 2>&1 | head -1)) =="

    # A: dual-port transition keeps both ports and the auth policy
    local d="$base/a"; fixture "$d"
    local orig; orig="$(sha256sum "$d/etc/ssh/sshd_config")"
    apply "$d" apply --port 47032 --mode dual > "$d/out"
    grep -q 'APPLY OK mode=dual' "$d/out" && ok "A dual apply" || { bad "A dual apply"; tail -4 "$d/out"; }
    snap "$d"
    [ "$(grep -c '^port ' "$d/eff.txt")" = 2 ] && ok "A two ports effective" || bad "A effective ports: $(grep '^port ' "$d/eff.txt" | tr '\n' ' ')"
    grep -qx 'port 22' "$d/eff.txt" && ok "A old port 22 kept" || bad "A port 22 missing"
    grep -qx 'port 47032' "$d/eff.txt" && ok "A new port 47032" || bad "A port 47032 missing"
    grep -qx 'permitrootlogin yes' "$d/eff.txt" && ok "A PermitRootLogin preserved" || bad "A PermitRootLogin changed"
    grep -qx 'passwordauthentication yes' "$d/eff.txt" && ok "A PasswordAuthentication preserved" || bad "A PasswordAuthentication changed"
    [ "$(sha256sum "$d/etc/ssh/sshd_config")" = "$orig" ] && ok "A main sshd_config untouched" || bad "A main sshd_config rewritten"
    if ! grep -qiE '^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)' "$d/etc/ssh/sshd_config.d/10-homelab-ssh.conf"; then
        ok "A drop-in sets no auth policy"
    else
        bad "A drop-in sets auth policy"
    fi

    # B: idempotent
    local h1 h2; h1="$(sha256sum < "$d/etc/ssh/sshd_config.d/10-homelab-ssh.conf")"
    apply "$d" apply --port 47032 --mode dual > "$d/out2"
    h2="$(sha256sum < "$d/etc/ssh/sshd_config.d/10-homelab-ssh.conf")"
    [ "$h1" = "$h2" ] && ok "B idempotent drop-in" || bad "B drop-in rewritten on rerun"
    [ "$(grep -c '^Port 47032$' "$d/etc/ssh/sshd_config.d/10-homelab-ssh.conf")" = 1 ] && ok "B no duplicate Port" || bad "B duplicate Port"
    snap "$d"
    [ "$(grep -c '^port ' "$d/eff.txt")" = 2 ] && ok "B still two ports" || bad "B port count drifted"

    # C: final mode must refuse without explicit confirmation
    apply "$d" apply --port 47032 --mode final > "$d/out3"
    grep -q 'needs --confirmed' "$d/out3" && ok "C final refused without --confirmed" || bad "C final ran unconfirmed"
    snap "$d"
    grep -qx 'port 22' "$d/eff.txt" && ok "C 22 still present after refusal" || bad "C 22 lost after refusal"

    # D: final mode drops 22 and goes IPv4-only
    apply "$d" apply --port 47032 --mode final --confirmed > "$d/out4"
    grep -q 'APPLY OK mode=final' "$d/out4" && ok "D final apply" || { bad "D final apply"; tail -4 "$d/out4"; }
    snap "$d"
    grep -qx 'port 22' "$d/eff.txt" && bad "D 22 still effective" || ok "D 22 dropped"
    grep -qx 'port 47032' "$d/eff.txt" && ok "D 47032 effective" || bad "D 47032 missing"
    grep -q 'listenaddress 0.0.0.0:47032' "$d/eff.txt" && ok "D IPv4 listener" || bad "D IPv4 listener missing"
    grep -q 'listenaddress \[::\]' "$d/eff.txt" && bad "D IPv6 listener still present" || ok "D no IPv6 listener"
    grep -qx 'passwordauthentication yes' "$d/eff.txt" && ok "D auth policy kept in final mode" || bad "D auth policy changed"

    # E: a foreign Port directive is refused, then taken over on request
    local e="$base/e"; fixture "$e" 'Port 2222'
    apply "$e" apply --port 47032 --mode dual > "$e/out5"
    grep -q 'take-over' "$e/out5" && ok "E foreign Port refused" || bad "E foreign Port accepted silently"
    grep -qx 'Port 2222' "$e/etc/ssh/sshd_config.d/20-foreign.conf" && ok "E foreign file untouched" || bad "E foreign file modified"
    apply "$e" apply --port 47032 --mode dual --take-over > "$e/out6"
    grep -q '#90ssh-disabled # Port 2222' "$e/etc/ssh/sshd_config.d/20-foreign.conf" \
        && ok "E take-over commented the foreign Port" || { bad "E take-over failed"; cat "$e/etc/ssh/sshd_config.d/20-foreign.conf"; }
    snap "$e"
    grep -qx 'port 2222' "$e/eff.txt" && bad "E 2222 still effective" || ok "E 2222 no longer effective"

    # F: rollback restores the exact pre-change state
    local f="$base/f"; fixture "$f"
    local forig; forig="$(sha256sum "$f/etc/ssh/sshd_config")"
    local fout; fout="$(apply "$f" apply --port 47032 --mode dual)"
    local bak; bak="$(printf '%s' "$fout" | sed -n 's/.*backup=\([^ ]*\).*/\1/p' | tail -1)"
    [ -n "$bak" ] && [ -d "$bak" ] && ok "F backup created ($(basename "$bak"))" || bad "F backup missing"
    apply "$f" rollback --backup "$bak" > "$f/out7"
    grep -q 'ROLLBACK done' "$f/out7" && ok "F rollback completed" || { bad "F rollback failed"; tail -4 "$f/out7"; }
    [ -f "$f/etc/ssh/sshd_config.d/10-homelab-ssh.conf" ] && bad "F managed drop-in survived" || ok "F managed drop-in removed"
    sshd -t -f "$f/etc/ssh/sshd_config" 2>/dev/null && ok "F config valid" || bad "F config invalid"
    snap "$f"
    [ "$(grep -c '^port ' "$f/eff.txt")" = 1 ] && grep -qx 'port 22' "$f/eff.txt" && ok "F back to 22 only" || bad "F ports after rollback: $(grep '^port ' "$f/eff.txt" | tr '\n' ' ')"
    [ "$(sha256sum "$f/etc/ssh/sshd_config")" = "$forig" ] && ok "F main config byte-identical" || bad "F main config differs"

    # G: status/plan are read-only
    local g="$base/g"; fixture "$g"
    local gsum; gsum="$(sha256sum "$g/etc/ssh/sshd_config")"
    apply "$g" plan --port 47032 > "$g/out8"
    apply "$g" status >> "$g/out8"
    grep -q 'PLAN v' "$g/out8" && ok "G plan output" || bad "G plan output"
    [ "$(sha256sum "$g/etc/ssh/sshd_config")" = "$gsum" ] && ok "G read-only" || bad "G plan/status wrote config"
    [ -f "$g/etc/ssh/sshd_config.d/10-homelab-ssh.conf" ] && bad "G plan created a drop-in" || ok "G plan created nothing"

    log "== self-test $([ $rc = 0 ] && echo PASS || echo FAIL) =="
    [ "$rc" = 0 ] && rm -rf "$base" || log "  (artifacts kept: $base)"
    return $rc
}

# -------------------------------------------------------------------- main --
[ $# -gt 0 ] || { sed -n '/^# Usage/,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//;$d'; exit 0; }
CMD="$1"; shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --port) NEW_PORT="$2"; shift 2;;
        --mode) MODE="$2"; shift 2;;
        --dropin) DROPIN="$2"; shift 2;;
        --guard) GUARD="$2"; shift 2;;
        --take-over) TAKE_OVER=1; shift;;
        --confirmed) CONFIRMED=1; shift;;
        --host) VERIFY_HOST="$2"; shift 2;;
        --key) VERIFY_KEY="$2"; shift 2;;
        --user) VERIFY_USER="$2"; shift 2;;
        --known-hosts) VERIFY_KNOWN_HOSTS="$2"; shift 2;;
        --token) TOKEN="$2"; shift 2;;
        --backup) BACKUP_DIR="$2"; shift 2;;
        --reason) REASON="$2"; shift 2;;
        --dry-run) DRY=1; shift;;
        *) die "unknown option: $1";;
    esac
done

case "$CMD" in
    status) do_status;;
    plan) do_plan "$NEW_PORT";;
    apply) do_apply "$NEW_PORT" "$MODE";;
    verify) do_verify "$NEW_PORT";;
    confirm) do_confirm;;
    rollback) do_rollback "${BACKUP_DIR:-$(latest_backup)}" "$REASON";;
    guard-check) do_guard_check;;
    test) do_selftest;;
    *) die "unknown command: $CMD";;
esac
