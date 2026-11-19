#!/usr/bin/env bash
# box/90ssh.sh - SSH port migration and key/auth bootstrap for Debian-family hosts.
#
# Supported: Debian 12/13, Ubuntu 22.04/24.04 (OpenSSH 8.9-10.0), service ssh
# (or sshd), with or without ssh.socket.  Nothing else is claimed: there are no
# RHEL/SELinux/firewalld branches, by design.
#
# Safety model
#   * The port commands never write authentication policy, and the auth commands
#     never write ports.  Each operation has its own drop-in, its own backup
#     directory, its own pending marker, its own confirmation token and its own
#     auto-rollback guard, and each refuses to run while the other is pending.
#   * dual mode keeps every port that is live right now (sshd -T + socket unit +
#     --keep-port).  If the current port cannot be determined, it refuses.
#   * final mode closes every other port and is only accepted with --confirmed
#     plus an evidence file produced by a real publickey login on the new port
#     from another host.  Local listening state never counts.
#   * The rollback guard is armed from a root-owned copy of this script before
#     anything is written.  If it cannot be armed, nothing is changed.
#   * After every write: sshd -t, reload, then compare the effective `sshd -T`
#     with the pre-change snapshot.  Any difference outside the intended switch
#     (port/listenaddress, or the two auth switches) rolls the change back.
#   * authorized_keys is only ever appended to, by bootstrap-key.
#
# Workflow: move a port (typical)
#   1) 90ssh.sh status
#   2) 90ssh.sh apply --port 47032 --mode dual --guard 300 --take-over
#      (old and new port listen together; the guard undoes everything in 300s
#       unless you finish the next two steps)
#   3) on this host:   90ssh.sh verify --issue-token --port 47032
#      on another host: 90ssh.sh verify --port 47032 --host <host> \
#                         --key <private-key> --user root --token <token> \
#                         --evidence /tmp/ev.txt
#   4) 90ssh.sh apply --port 47032 --mode final --confirmed \
#        --evidence /tmp/ev.txt
#   Instead of step 4 you may run `confirm --token <token>`, which keeps both
#   ports open and disarms the guard.
#
# Workflow: install a key
#   90ssh.sh bootstrap-key --user root --pubkey ~/mykey.pub
#   Appends by key type+blob (comments and options are irrelevant, so repeating
#   it changes nothing), keeps every existing line, sets ~/.ssh 0700 and
#   authorized_keys 0600, and writes a backup directory containing RESTORE.sh.
#   It refuses symlinks, unknown users and private keys.
#
# Workflow: turn password logins off (key-only)
#   1) 90ssh.sh auth status              # what decides the policy right now
#   2) 90ssh.sh auth plan --mode key-only
#      Prints REFUSED, with the offending file and line, if another file is read
#      before ours or a Match block re-enables passwords.  Nothing is written.
#   3) prove the key works, on this host: 90ssh.sh verify --issue-token \
#        --port 47032 --purpose auth-key-only
#      on another host: 90ssh.sh verify --port 47032 --host <host> \
#        --key <private-key> --user root --token <token> \
#        --purpose auth-key-only --evidence /tmp/ev-pre.txt
#   4) 90ssh.sh auth apply --mode key-only --user root \
#        --evidence /tmp/ev-pre.txt --console-ok --guard 600
#      --console-ok is your statement that a console/IPMI/serial path exists.
#      Existing sessions keep working; the guard restores the old policy on
#      timeout.
#   5) prove the new policy, with --probe (which only reads the server's method
#      list, no password is sent):
#      90ssh.sh verify ... --purpose auth-post --probe --evidence /tmp/ev-post.txt
#      90ssh.sh auth confirm --token <token> --evidence /tmp/ev-post.txt
#   Only two directives are written, into 00-90ssh-auth.conf:
#   PasswordAuthentication no and KbdInteractiveAuthentication no.
#   PermitRootLogin, PubkeyAuthentication, AuthorizedKeysFile, Match blocks,
#   ports and authorized_keys are never touched by this command.
#
# Evidence: what makes a record trustworthy
#   verify logs in with PreferredAuthentications=publickey from another machine
#   and reads back: the server side of SSH_CONNECTION (address and the port the
#   login actually reached), a one-shot token from /run/90ssh/verify.token, the
#   machine-id, a digest of the whole sshd configuration tree, the key
#   fingerprint and a timestamp.  A record is rejected when it comes from this
#   host or loopback, is older than --max-evidence-age, names another port or
#   user, was made under a different configuration digest, or carries a token
#   that is no longer current.  Evidence from a private address needs
#   --allow-private-verifier, because it proves a LAN path rather than a
#   provider route.
#
# Restoring
#   90ssh.sh status                     # shows both pending markers
#   90ssh.sh rollback                   # last port backup
#   90ssh.sh auth rollback              # last auth backup
#   90ssh.sh rollback --backup DIR      # a specific one
#   A rollback restores exactly the files its own backup lists, so restoring a
#   port change never resurrects an authentication drop-in and vice versa.
#   bootstrap-key backups carry RESTORE.sh; old authorized_keys are never
#   merged back automatically.
#
# Known limits
#   * A cloud security group is invisible from inside the host: when the host
#     firewall drops input, a warning is printed and final mode relies on the
#     external login record instead.
#   * Never combine the guard with a reboot: the transient timer does not
#     survive it.  Both ports stay open meanwhile, so there is no lockout, but
#     the pending marker must be resolved by hand (`status` shows it).
#   * Match blocks that re-enable passwords for other users are not rewritten;
#     auth apply only guarantees and verifies the target account.
#   * sshd is reloaded, not restarted, so existing sessions stay up; a
#     socket-activated host picks the new policy up on the next connection.
#   * Rocky/AlmaLinux are untested: no SELinux port labelling, no firewalld
#     handling, no sshd.service-specific behaviour beyond name detection.
#
# Usage
#   90ssh.sh status
#   90ssh.sh plan  --port N [--mode dual|final]
#   90ssh.sh apply --port N [--mode dual|final] [--guard SEC] [--take-over]
#                  [--confirmed --evidence FILE] [--keep-port N] [--listen ADDR]
#   90ssh.sh verify --issue-token --port N [--purpose port-final|auth-key-only|auth-post]
#   90ssh.sh verify --port N --host H --key PATH --token T [--user U]
#                  [--known-hosts FILE] [--probe] [--purpose P] [--evidence FILE]
#   90ssh.sh confirm --token T
#   90ssh.sh rollback [--backup DIR] [--reason R]
#   90ssh.sh bootstrap-key --user U --pubkey FILE
#   90ssh.sh auth status [--user U]
#   90ssh.sh auth plan  --mode key-only [--user U]
#   90ssh.sh auth apply --mode key-only --evidence FILE --console-ok
#                        [--user U] [--guard SEC]
#   90ssh.sh auth confirm --token T --evidence FILE
#   90ssh.sh auth rollback [--backup DIR]
#   90ssh.sh menu            # interactive menu (also used for no arguments on a tty)
#   90ssh.sh test            # built-in isolated test suite
#
# Options
#   --port N            port to add (dual) or keep (final)
#   --mode dual|final   default dual; key-only for the auth commands
#   --guard SEC         arm an auto-rollback timer (minimum 5); without it a
#                       port change is kept and an auth change stays pending
#   --take-over         comment out Port lines owned by other files (backed up)
#   --keep-port N       keep an extra port in dual mode (repeatable)
#   --listen ADDR       final mode: write this single ListenAddress
#   --evidence FILE     record of a real publickey login from another host
#   --confirmed         required for final mode
#   --host/--key/--token/--user/--known-hosts/--probe    used by verify
#   --purpose P         evidence purpose: port-final (default), auth-key-only, auth-post
#   --user U            account for bootstrap-key / auth (default root)
#   --pubkey FILE       file with one or more public keys
#   --console-ok        confirm console/IPMI/serial access exists (auth apply)
#   --backup DIR        explicit backup directory for a rollback
#   --allow-private-verifier  accept evidence from an RFC1918 client
#   --max-evidence-age SEC    evidence freshness, default 86400
#   --force-pending     ignore a pending change of the same kind
#   --reason R          text recorded in the rollback log
#   --dry-run           print what would be done, write nothing
#
# Exit codes: 0 ok, 3 sshd -t failed (rolled back), 4 reload failed (rolled back),
#             5 port missing or lost (rolled back), 6 effective port/policy set
#             wrong (rolled back), 7 unrelated configuration drift (rolled back).
#
# Isolated testing: PREFIX=/tmp/x makes the script work on $PREFIX/etc/ssh and
# skip systemctl/ss, so a full migration can be rehearsed against the real sshd
# parser without touching the host.  `90ssh.sh test` does exactly that.
set -uo pipefail

VER=2.2.0
PREFIX="${PREFIX:-}"
DRY="${DRY_RUN:-0}"
CMD=""
ACMD=""
PORT=""
MODE="dual"
GUARD=0
TAKEOVER=0
CONFIRMED=0
EVIDENCE=""
ALLOW_PRIVATE=0
MAXAGE=86400
GHOST=""
GKEY=""
GUSER="root"
GKNOWN=""
ISSUE=0
TOKEN=""
BACKUP=""
REASON="manual"
KEEP=""
LISTEN=""
CREATE_INC=0
FORCE=0
AUSER="root"
PUBKEY=""
CONSOLE_OK=0
PURPOSE=""
PROBE=0
GKIND=""
KROLLBACK=0
KIND=""

S_DIR="$PREFIX/etc/ssh"
S_CFG="$S_DIR/sshd_config"
D_DIR="$S_DIR/sshd_config.d"
PORT_DROPIN="90-ssh-port.conf"
AUTH_DROPIN="00-90ssh-auth.conf"
SVC="ssh"
SOCKET_UNIT=""
SOCK_DIR=""
STATE="$PREFIX/var/lib/90ssh"
RUN="$PREFIX/run/90ssh"
SELF="$0"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
fake() { [ -n "$PREFIX" ]; }

run() {
    if [ "$DRY" = 1 ]; then printf '  [dry] %s\n' "$*"; return 0; fi
    "$@"
}

# ------------------------------------------------------------------ sshd ---
sshd_bin() { command -v sshd 2>/dev/null || echo /usr/sbin/sshd; }

# sshd -t / -T against $PREFIX (fake) or the live configuration.
sshd_t() {
    if fake; then "$(sshd_bin)" -t -f "$S_CFG" 2>&1
    else "$(sshd_bin)" -t 2>&1; fi
}
sshd_T() {   # sshd_T [user]
    local u="${1:-}"
    if [ -n "$u" ]; then
        if fake; then "$(sshd_bin)" -T -f "$S_CFG" -C "user=$u,host=localhost,addr=203.0.113.7" 2>/dev/null
        else "$(sshd_bin)" -T -C "user=$u,host=localhost,addr=203.0.113.7" 2>/dev/null; fi
    else
        if fake; then "$(sshd_bin)" -T -f "$S_CFG" 2>/dev/null
        else "$(sshd_bin)" -T 2>/dev/null; fi
    fi
}
no_port_lines()  { grep -Eiv '^(port|listenaddress) ' || true; }
no_auth_lines()  { grep -Eiv '^(passwordauthentication|kbdinteractiveauthentication) ' || true; }

# --------------------------------------------------------------- units -----
# Debian/Ubuntu use ssh.service and optionally ssh.socket.  sshd.service only
# exists on hosts that renamed it; one fallback line covers that.
svc_resolve() {
    SVC="ssh"
    if ! fake && ! systemctl cat ssh.service >/dev/null 2>&1 && systemctl cat sshd.service >/dev/null 2>&1; then
        SVC="sshd"
    fi
    [ -n "${FAKE_SVC:-}" ] && SVC="$FAKE_SVC"
    SOCKET_UNIT=""
    if fake; then
        [ -n "${FAKE_SOCKET:-}" ] && SOCKET_UNIT="$FAKE_SOCKET"
    else
        local s
        for s in ssh.socket sshd.socket; do
            systemctl is-active --quiet "$s" 2>/dev/null && { SOCKET_UNIT="$s"; break; }
        done
    fi
    SOCK_DIR=""
    [ -n "$SOCKET_UNIT" ] && SOCK_DIR="$PREFIX/etc/systemd/system/$SOCKET_UNIT.d"
    return 0
}

svc_active()  { fake && { echo fake; return; }; local v; v="$(systemctl is-active "$SVC.service" 2>/dev/null)"; printf '%s' "${v:-unknown}"; }
svc_enabled() { fake && { echo fake; return; }; local v; v="$(systemctl is-enabled "$SVC.service" 2>/dev/null)"; printf '%s' "${v:-unknown}"; }
socket_live() { [ -n "$SOCKET_UNIT" ] && { fake && return 0; systemctl is-active --quiet "$SOCKET_UNIT"; }; }

# Listen entries of the active socket unit: "<addr>:<port>" words.
sock_listens() {
    [ -n "$SOCKET_UNIT" ] || return 0
    if fake; then printf '%s\n' ${FAKE_SOCK_STREAMS:-} | tr ' ' '\n' | grep -E ':[0-9]+$'; return 0; fi
    local out
    out="$(systemctl show -p Listen --value "$SOCKET_UNIT" 2>/dev/null)"
    [ -n "$out" ] || out="$(systemctl show -p ListenStream --value "$SOCKET_UNIT" 2>/dev/null)"
    printf '%s\n' "$out" | tr ' ' '\n' | grep -E ':[0-9]+$'
}

# Ports that are effective right now: config + live socket + --keep-port.
live_ports() {
    {
        sshd_T | awk '$1=="port"{print $2}'
        sock_listens | sed 's/.*://'
        printf '%s\n' $KEEP
    } | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ' | sed 's/ $//'
}

# ------------------------------------------------------------- sockets -----
# Ports bound by a listening TCP socket (ss is optional; a missing ss only
# removes a cross-check, never changes the decision by itself).
ss_ports() {
    fake && { printf '%s' "${FAKE_LISTEN:-${FAKE_PORTS:-}}"; return 0; }
    command -v ss >/dev/null 2>&1 || return 0
    ss -Hltn 2>/dev/null | awk '{print $4}' | sed 's/.*[:.]//' | sort -un | tr '\n' ' ' | sed 's/ $//'
}
port_bound() {
    local p="$1" got
    got=" $(ss_ports) "
    case "$got" in *" $p "*) return 0;; esac
    return 1
}

# ---------------------------------------------------------------- drop-in ---
managed() { printf '%s/%s' "$D_DIR" "$PORT_DROPIN"; }

# A v2.0 host may already carry 10-homelab-ssh.conf; keep it instead of adding
# a second Port source.
dropin_resolve() {
    local n f
    # A host that already carries a managed drop-in (v2.0 used 10-homelab-ssh.conf,
    # the PVE host 10-homelab-ssh-pve.conf) keeps that file, so the tool stays
    # idempotent instead of adding a second Port source.
    for n in 90-ssh-port.conf 10-homelab-ssh.conf; do
        [ -f "$D_DIR/$n" ] && { PORT_DROPIN="$n"; return 0; }
    done
    for f in "$D_DIR"/*.conf; do
        [ -f "$f" ] || continue
        grep -q '^# Managed by box/90ssh.sh' "$f" 2>/dev/null || continue
        grep -q '^# Only these two directives are managed here' "$f" 2>/dev/null && continue
        PORT_DROPIN="$(basename "$f")"
        return 0
    done
    PORT_DROPIN="90-ssh-port.conf"
}

include_present() { grep -Eq "^[[:space:]]*Include[[:space:]]+${D_DIR//./\\.}/\\*\\.conf([[:space:]]|$)" "$S_CFG" 2>/dev/null; }

# Port / ListenAddress directives from files we do not own.  Printed as
# "<file>:<line>:<text>" so the caller can report and, with --take-over, edit.
foreign() {   # foreign Port|ListenAddress
    local kw="$1" f
    [ -f "$S_CFG" ] && grep -nE "^[[:space:]]*$kw[[:space:]]+" "$S_CFG" 2>/dev/null | sed "s|^|$S_CFG:|"
    if [ -d "$D_DIR" ]; then
        for f in "$D_DIR"/*.conf; do
            [ -f "$f" ] || continue
            [ "$f" = "$(managed)" ] && continue
            grep -nE "^[[:space:]]*$kw[[:space:]]+" "$f" 2>/dev/null | sed "s|^|$f:|"
        done
    fi
}

# -------------------------------------------------------------- evidence ---
new_token() { od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n'; }
token_path() { printf '%s/verify.token' "$RUN"; }
ev_get() { sed -n "s/^$1=//p" "$2" | tail -1; }

# Digest of everything that decides authentication, in read order.  Computed the
# same way here and on the remote host during verify, so a record cannot be
# replayed after any sshd configuration change.
cfg_digest() {
    { echo "== $S_CFG"; cat "$S_CFG" 2>/dev/null
      for f in "$D_DIR"/*.conf; do [ -f "$f" ] || continue; echo "== $f"; cat "$f"; done
    } | sha256sum | awk '{print $1}'
}

is_private_ip() {
    case "$1" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*|fc*|fd*|fe80*) return 0;;
    esac
    return 1
}

local_ips() {
    { printf '127.0.0.1\n::1\n'
      if ! fake; then ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1; fi
    } | sort -u | tr '\n' ' '
}
is_local_ip() {
    local ip="$1" i
    case "$ip" in 127.*|::1|0.0.0.0|"") return 0;; esac
    for i in $(local_ips); do [ "$i" = "$ip" ] && return 0; done
    return 1
}

# One validator for every purpose.  phase "post" additionally requires that the
# record was made after the auth change and that no password method is offered.
check_evidence() {
    local f="$1" purpose="$2" phase="${3:-pre}"
    [ -f "$f" ] || die "evidence file not found: $f"
    [ "$(ev_get ver "$f")" = 2 ] || die "evidence version $(ev_get ver "$f") != 2 (regenerate with this script)"
    [ "$(ev_get result "$f")" = ok ] || die "evidence does not record a successful login"
    local evp evu evport evsrv evip evid evtok evep evcfg
    evp="$(ev_get purpose "$f")"; evu="$(ev_get user "$f")"
    evport="$(ev_get port "$f")"; evsrv="$(ev_get server_port "$f")"
    evip="$(ev_get client_ip "$f")"; evid="$(ev_get server_id "$f")"
    evtok="$(ev_get token "$f")"; evep="$(ev_get epoch "$f")"; evcfg="$(ev_get cfg_digest "$f")"
    [ "$evp" = "$purpose" ] || die "evidence purpose is '$evp', this step needs '$purpose'"
    [ -n "$evip" ] || die "evidence has no client_ip"
    is_local_ip "$evip" && die "evidence came from $evip, which is this host; a local login proves nothing"
    is_private_ip "$evip" && [ "$ALLOW_PRIVATE" != 1 ] \
        && die "evidence client $evip is private; that proves a LAN path, not a provider route. Add --allow-private-verifier if intended"
    case "$evep" in ''|*[!0-9]*) die "evidence has no timestamp";; esac
    local now age; now="$(date +%s)"; age=$(( now - evep ))
    [ "$age" -ge -300 ] || die "evidence timestamp is in the future"
    [ "$age" -le "$MAXAGE" ] || die "evidence is ${age}s old (max $MAXAGE); run verify again"
    if [ -r /etc/machine-id ] && [ -n "$evid" ] && [ "$evid" != "$(cat /etc/machine-id)" ]; then
        die "evidence server_id does not match this machine"
    fi
    if [ -n "$evtok" ] && [ -f "$(token_path)" ] && [ "$evtok" != "$(cat "$(token_path)")" ]; then
        die "evidence token does not match this host's current token (rerun verify --issue-token)"
    fi

    case "$purpose" in
        port-final)
            [ -n "$PORT" ] && [ "$evport" = "$PORT" ] || die "evidence is for port $evport, not ${PORT:-?}"
            [ "$evsrv" = "$PORT" ] || die "evidence login reached server port $evsrv (SSH_CONNECTION), not $PORT"
            ;;
        auth-key-only|auth-post)
            [ "$evu" = "$AUSER" ] || die "evidence is for user '$evu', not '$AUSER'"
            [ -n "$(ev_get uid "$f")" ] || die "evidence has no uid"
            case " $(live_ports) " in
                *" $evport "*) ;;
                *) die "evidence is for port $evport, but this host serves [$(live_ports)]" ;;
            esac
            [ "$evsrv" = "$evport" ] || die "evidence reached server port $evsrv, not $evport"
            local cur; cur="$(cfg_digest)"
            [ -n "$evcfg" ] && [ "$evcfg" = "$cur" ] \
                || die "the sshd configuration changed since this record (${evcfg:-missing} != $cur); rerun verify"
            ;;
        *) die "internal: unknown purpose $purpose";;
    esac
    if [ "$phase" = post ]; then
        [ "$(ev_get password_offered "$f")" = no ] \
            || die "the record says a password method is still offered ($(ev_get password_offered "$f")); fix that first"
        local applied; applied="$(sed -n 's/^applied_at=//p' "$(auth_pending)" 2>/dev/null | head -1)"
        case "$applied" in ''|*[!0-9]*) die "no auth change in flight; nothing to confirm";; esac
        [ "$evep" -ge "$applied" ] || die "the record predates the change; it cannot prove the new policy"
    fi
    log "  evidence: $purpose user=${evu:-?} port=$evport via $evip (age ${age}s, key $(ev_get key_fp "$f"))"
}

# --------------------------------------------------------------- backups ---
take_backup() {   # take_backup <kind> <file...>
    local kind="$1"; shift
    local ts dir p n=1 suffix=""
    ts="$(date '+%Y%m%d-%H%M%S')"
    [ "$kind" = auth ] && suffix="-auth"
    dir="$PREFIX/root/90ssh$suffix-backup-$ts"
    while [ -e "$dir" ]; do n=$((n + 1)); dir="$PREFIX/root/90ssh$suffix-backup-$ts-$n"; done
    run install -d -m 0700 "$dir" || return 1
    { echo "manifest=2"; echo "kind=$kind"; } > "$dir/MANIFEST"
    { echo "version=$VER"; echo "ts=$ts"; echo "svc=$SVC"; echo "svc_active=$(svc_active)"
      echo "svc_enabled=$(svc_enabled)"; echo "socket=${SOCKET_UNIT:-none}"; echo "ports=$(ss_ports)"; } > "$dir/state"
    for p in "$@"; do
        [ -n "$p" ] || continue
        if [ -e "$p" ] || [ -L "$p" ]; then
            run mkdir -p "$dir/files$(dirname "$p")" || return 1
            run cp -a "$p" "$dir/files$p" || return 1
            echo "FILE $p present" >> "$dir/MANIFEST"
        else
            echo "FILE $p absent" >> "$dir/MANIFEST"
        fi
    done
    sshd_T > "$dir/sshd-T.before" 2>/dev/null
    sshd_T "$AUSER" > "$dir/sshd-T.before.user" 2>/dev/null
    [ -n "$EVIDENCE" ] && [ -f "$EVIDENCE" ] && cp -p "$EVIDENCE" "$dir/evidence"
    log "  backup: $dir"
    BACKUP_DIR_CREATED="$dir"
    return 0
}

latest_backup()    { ls -1d "$PREFIX"/root/90ssh-backup-* 2>/dev/null | sort | tail -1; }
latest_auth_backup() { ls -1d "$PREFIX"/root/90ssh-auth-backup-* 2>/dev/null | sort | tail -1; }
pending_path()     { printf '%s/pending' "$STATE"; }
auth_pending()     { printf '%s/auth-pending' "$STATE"; }

# Restore exactly the files the backup lists, nothing else.  A file that did not
# exist before is removed; a file that did is copied back.  Files another
# operation owns (e.g. the auth drop-in during a port rollback) are not in the
# list and are therefore never touched.
restore() {   # restore <kind> <dir> <reason>
    local kind="$1" dir="$2" reason="$3" tag p state f
    [ -n "$dir" ] && [ -d "$dir" ] || die "rollback: backup dir not found: ${dir:-<none>}"
    log "ROLLBACK ($reason, $kind) from $dir"
    if grep -qx 'manifest=2' "$dir/MANIFEST" 2>/dev/null; then
        while read -r tag p state; do
            [ "$tag" = FILE ] || continue
            case "$state" in
                present)
                    if [ -e "$dir/files$p" ]; then
                        run mkdir -p "$(dirname "$p")"
                        run cp -a "$dir/files$p" "$p" && log "  restored $p"
                    else
                        warn "missing backup copy of $p; left as is"
                    fi ;;
                absent)
                    if [ -e "$p" ] || [ -L "$p" ]; then run rm -f "$p"; log "  removed $p"; fi ;;
            esac
        done < "$dir/MANIFEST"
    else
        warn "backup $dir uses the v2.1 layout; restoring it with this version is not supported"
        warn "use the v2.1 script for that directory, or restore the files by hand"
        return 1
    fi
    if sshd_t >/dev/null; then log "  sshd -t OK"; else warn "sshd -t fails after restore"; fi
    if ! fake; then
        run systemctl daemon-reload
        if socket_live; then
            run systemctl restart "$SOCKET_UNIT" || run systemctl restart "$SVC.service"
        else
            run systemctl reload "$SVC.service" || run systemctl restart "$SVC.service"
        fi
        sleep 2
        log "  ssh=$(svc_active) ports=[$(ss_ports)]"
    fi
    if [ -f "$dir/sshd-T.before" ] && [ "$kind" = auth ]; then
        if [ "$(sshd_T | no_auth_lines)" = "$(no_auth_lines < "$dir/sshd-T.before")" ]; then
            log "  every directive except the two auth switches is back to the pre-change state"
        else
            warn "sshd -T differs from the pre-change snapshot; check 'auth status'"
        fi
    fi
    clear_pending "$kind" "$dir"
    log "ROLLBACK done"
    return 0
}

clear_pending() {   # clear_pending <kind> [dir]
    local kind="$1" dir="${2:-}" pf tok
    case "$kind" in auth) pf="$(auth_pending)";; *) pf="$(pending_path)";; esac
    [ -f "$pf" ] || return 0
    if [ -z "$dir" ] || grep -qxF "backup=$dir" "$pf"; then
        tok="$(sed -n 's/^token=//p' "$pf" | head -1)"
        [ -n "$tok" ] && stop_guard "$kind" "$tok"
        rm -f "$pf"
        log "  cleared pending marker ($kind)"
    fi
}

# ------------------------------------------------------------------ guard ---
guard_unit() { case "$1" in auth) printf '90ssh-auth-guard-%s' "$2";; *) printf '90ssh-guard-%s' "$2";; esac; }

stop_guard() {
    local kind="$1" tok="$2" u
    [ -n "$tok" ] || return 0
    u="$(guard_unit "$kind" "$tok")"
    fake && return 0
    systemctl stop "$u.timer" 2>/dev/null
    systemctl stop "$u.service" 2>/dev/null
    systemctl reset-failed "$u.service" "$u.timer" 2>/dev/null
}

self_path() {
    local s="$1"
    case "$s" in */*) ;; *) s="$(command -v -- "$s" 2>/dev/null || printf '%s/%s' "$PWD" "$s")";; esac
    readlink -f -- "$s" 2>/dev/null
}

# Arms the auto-rollback timer from a root-owned copy of this script.  Returns 1
# when it cannot be armed: the caller must then abort before writing anything.
arm_guard() {   # arm_guard <kind> <token> <backup> <desc> [extra-kv...]
    local kind="$1" tok="$2" dir="$3" desc="$4"; shift 4
    local pf u
    pf="$STATE/$([ "$kind" = auth ] && echo auth-pending || echo pending)"
    u="$(guard_unit "$kind" "$tok")"
    if fake; then
        case "${FAKE_GUARD:-none}" in
            ok) install -d -m 0700 "$STATE" || return 1
                { echo "kind=$kind"; echo "token=$tok"; echo "deadline=$(( $(date +%s) + GUARD ))"
                  echo "backup=$dir"; echo "desc=$desc"; echo "armed=fake"
                  for kv in "$@"; do echo "$kv"; done; } > "$pf" || return 1
                return 0;;
            fail) return 1;;
            *) return 2;;
        esac
    fi
    command -v systemd-run >/dev/null 2>&1 || { warn "systemd-run not available"; return 1; }
    local src copy
    src="$(self_path "$SELF")"
    [ -n "$src" ] || { warn "cannot resolve an absolute path for $SELF"; return 1; }
    install -d -m 0700 "$STATE" || return 1
    copy="$STATE/90ssh.sh"
    install -m 0700 "$src" "$copy" || { warn "cannot stage $copy"; return 1; }
    { echo "kind=$kind"; echo "token=$tok"; echo "deadline=$(( $(date +%s) + GUARD ))"
      echo "backup=$dir"; echo "desc=$desc"; echo "armed=$(date -Iseconds)"
      for kv in "$@"; do echo "$kv"; done; } > "$pf.tmp" || return 1
    if ! systemd-run --unit="$u" --on-active="$GUARD" --collect \
            --description="90ssh safety net ($desc)" \
            "$copy" guard-check --token "$tok" --kind "$kind" --backup "$dir" >/dev/null 2>&1; then
        rm -f "$pf.tmp"
        warn "systemd-run could not arm the guard"
        return 1
    fi
    mv -f "$pf.tmp" "$pf" || return 1
    log "  guard armed: ${GUARD}s ($u)"
    return 0
}

do_guard_check() {
    [ -n "$TOKEN" ] || die "guard-check: --token required"
    local kind="${GKIND:-port}" dir pf
    pf="$STATE/$([ "$kind" = auth ] && echo auth-pending || echo pending)"
    [ -f "$pf" ] || { kind=port; pf="$(pending_path)"; }
    [ -f "$pf" ] || { kind=auth; pf="$(auth_pending)"; }
    if [ -f "$RUN/$TOKEN.ok" ]; then
        log "guard $TOKEN: confirmed, standing down"
        clear_pending "$kind" ""
        return 0
    fi
    logger -t 90ssh "guard $TOKEN ($kind) expired without confirmation -> rolling back" 2>/dev/null
    dir="${BACKUP:-$(sed -n 's/^backup=//p' "$pf" 2>/dev/null | head -1)}"
    restore "$kind" "$dir" "guard-timeout-$TOKEN"
}
# ----------------------------------------------------------------- verify ---
issue_token() {
    install -d -m 0700 "$RUN" || die "verify: cannot create $RUN"
    [ -n "$PURPOSE" ] || PURPOSE=port-final
    case "$PURPOSE" in
        port-final|auth-key-only|auth-post) ;;
        *) die "verify: unknown --purpose '$PURPOSE' (port-final|auth-key-only|auth-post)";;
    esac
    local t; t="$(new_token)"
    [ -n "$t" ] || die "verify: cannot read /dev/urandom"
    ( umask 077; printf '%s\n' "$t" > "$(token_path)" )
    chmod 0600 "$(token_path)" 2>/dev/null
    log "VERIFY TOKEN: $t   (purpose=$PURPOSE, port ${PORT:-<live>})"
    log ""
    log "Run this on a different host:"
    log "  90ssh.sh verify --port ${PORT:-<port>} --host <this-host> --key <private-key> \\"
    log "      --user <account> --token $t --purpose $PURPOSE \\"
    log "      $([ "$PURPOSE" = auth-post ] && printf -- '--probe ')--evidence /tmp/ev-$PURPOSE.txt"
    case "$PURPOSE" in
        port-final)    log "Then here: 90ssh.sh apply --port ${PORT:-N} --mode final --confirmed --evidence /tmp/ev-port-final.txt";;
        auth-key-only) log "Then here: 90ssh.sh auth apply --mode key-only --evidence /tmp/ev-auth-key-only.txt --console-ok";;
        auth-post)     log "Then here: 90ssh.sh auth confirm --token <token from auth apply> --evidence /tmp/ev-auth-post.txt";;
    esac
}

do_verify() {
    if [ "$ISSUE" = 1 ]; then issue_token; return 0; fi
    [ -n "$PORT" ] || die "verify: --port is required (or use --issue-token)"
    log "== local listening state (informational) =="
    if port_bound "$PORT"; then log "  OK  tcp/$PORT is bound locally"; else warn "tcp/$PORT is NOT bound locally"; fi
    fake && return 0
    [ -n "$GHOST" ] || die "verify: --host is required"
    [ -n "$GKEY" ]  || die "verify: --key is required with --host"
    [ -n "$TOKEN" ] || die "verify: --token is required with --host"
    [ -n "$PURPOSE" ] || PURPOSE=port-final
    local evf="${EVIDENCE:-/tmp/ev-$PURPOSE.txt}"
    [ -r "$GKEY" ] || die "verify: cannot read private key $GKEY"
    local keyfp; keyfp="$(ssh-keygen -lf "$GKEY" 2>/dev/null | awk '{print $2}')"
    [ -n "$keyfp" ] || die "verify: $GKEY is not an OpenSSH private key"

    local args=(-p "$PORT" -i "$GKEY" -o BatchMode=yes -o IdentitiesOnly=yes
                -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes
                -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
                -o ConnectTimeout=10 -o LogLevel=ERROR)
    [ -n "$GKNOWN" ] && args+=(-o "UserKnownHostsFile=$GKNOWN" -o StrictHostKeyChecking=yes)
    # SSHD_CFG_ROOT is the configuration root (/etc on a normal host).  Set it
    # only to test against a staging sshd whose tree lives elsewhere; the digest
    # is then computed over the same files on both sides.
    [ -n "${SSHD_CFG_ROOT:-}" ] && args+=(-o "SetEnv=SSHD_CFG_ROOT=$SSHD_CFG_ROOT")

    log "== publickey login $GUSER@$GHOST:$PORT =="
    local out
    if out="$(ssh "${args[@]}" "$GUSER@$GHOST" 'sh -s' <<'REMOTE' 2>&1
r="${SSHD_CFG_ROOT:-/etc}"; d="$r/ssh"
printf 'VHOST=%s\n' "$(hostname)"
printf 'VMID=%s\n' "$(cat /etc/machine-id 2>/dev/null)"
printf 'VPID=%s\n' "$(cat /run/sshd.pid 2>/dev/null || pgrep -o sshd 2>/dev/null)"
printf 'VCONN=%s\n' "$SSH_CONNECTION"
printf 'VTOKEN=%s\n' "$(cat /run/90ssh/verify.token 2>/dev/null)"
printf 'VUID=%s\n' "$(id -u)"
printf 'VCFG=%s\n' "$( { echo "== $d/sshd_config"; cat "$d/sshd_config" 2>/dev/null
  for f in "$d"/sshd_config.d/*.conf; do [ -f "$f" ] || continue; echo "== $f"; cat "$f"; done; } | sha256sum | cut -d' ' -f1)"
REMOTE
)"; then
        printf '%s\n' "$out" | sed 's/^/  /'
        local vtok vconn sip srvport svid svhost vuid vcfg
        vtok="$(printf '%s\n' "$out" | sed -n 's/^VTOKEN=//p' | tail -1)"
        vconn="$(printf '%s\n' "$out" | sed -n 's/^VCONN=//p' | tail -1)"
        svid="$(printf '%s\n' "$out" | sed -n 's/^VMID=//p' | tail -1)"
        svhost="$(printf '%s\n' "$out" | sed -n 's/^VHOST=//p' | tail -1)"
        vuid="$(printf '%s\n' "$out" | sed -n 's/^VUID=//p' | tail -1)"
        vcfg="$(printf '%s\n' "$out" | sed -n 's/^VCFG=//p' | tail -1)"
        sip="$(printf '%s' "$vconn" | awk '{print $1}')"
        srvport="$(printf '%s' "$vconn" | awk '{print $4}')"
        local bad=0
        [ "$vtok" = "$TOKEN" ] || { warn "remote token does not match (wrong host or token rotated)"; bad=1; }
        [ "$srvport" = "$PORT" ] || { warn "server-side port is $srvport, not $PORT"; bad=1; }

        # Did the server still offer a password method?  Nothing is sent: the
        # method list is read from the rejection message.
        local poff=unknown methods=""
        if [ "$PROBE" = 1 ]; then
            local perr pargs=(-p "$PORT" -o BatchMode=yes -o PubkeyAuthentication=no
                              -o PreferredAuthentications=password,keyboard-interactive
                              -o NumberOfPasswordPrompts=0 -o ConnectTimeout=10 -o LogLevel=ERROR)
            # the probe must trust the host the same way the login did, otherwise
            # a host-key prompt would be mistaken for "no password method"
            [ -n "$GKNOWN" ] && pargs+=(-o "UserKnownHostsFile=$GKNOWN" -o StrictHostKeyChecking=yes)
            perr="$(ssh "${pargs[@]}" "$GUSER@$GHOST" true 2>&1)"
            methods="$(printf '%s' "$perr" | sed -n 's/.*Permission denied (\(.*\)).*/\1/p' | tail -1)"
            case "$methods" in
                "") poff=unknown ;;
                *password*|*keyboard*) poff=yes ;;
                *publickey*) poff=no ;;
            esac
            log "  probe: password methods offered = $poff${methods:+ [$methods]}"
        fi
        if [ "$bad" = 0 ]; then
            {
                echo "ver=2"; echo "purpose=$PURPOSE"; echo "result=ok"
                echo "port=$PORT"; echo "server_port=$srvport"; echo "host=$GHOST"
                echo "user=$GUSER"; echo "uid=$vuid"
                echo "client_ip=$sip"; echo "client_host=$(hostname)"
                echo "server_host=$svhost"; echo "server_id=$svid"
                echo "sshd_pid=$(printf '%s\n' "$out" | sed -n 's/^VPID=//p' | tail -1)"
                echo "password_offered=$poff"; echo "cfg_digest=$vcfg"
                echo "key_fp=$keyfp"; echo "token=$TOKEN"
                echo "ts=$(date -Iseconds)"; echo "epoch=$(date +%s)"
            } > "$evf"
            chmod 0600 "$evf" 2>/dev/null
            log "  PASS $GUSER@$GHOST:$PORT from $sip (uid $vuid)"
            log "  evidence: $evf"
        else
            warn "login worked but the record cannot be trusted; no evidence written"
            return 1
        fi
    else
        printf '%s\n' "$out" | tail -5 | sed 's/^/  /'
        warn "publickey login FAILED on port $PORT"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------- port ---
do_status() {
    log "90ssh.sh v$VER  host=$(hostname)"
    log "config   : $S_CFG"
    log "service  : $SVC.service (enabled=$(svc_enabled) active=$(svc_active))  socket: ${SOCKET_UNIT:-none}"
    log "drop-in  : $(managed) $([ -f "$(managed)" ] && echo '(present)' || echo '(absent)')"
    [ -f "$(managed)" ] && sed 's/^/  | /' "$(managed)"
    log "include  : $(include_present && echo present || echo MISSING)"
    log "effective ports: [$(live_ports)]   bound: [$(ss_ports)]"
    [ -n "$SOCK_DIR" ] && log "socket drop-in: $SOCK_DIR/zz-90ssh.conf $([ -f "$SOCK_DIR/zz-90ssh.conf" ] && echo '(present)')"
    local fp; fp="$(foreign Port)"
    if [ -n "$fp" ]; then log "foreign Port directives:"; printf '%s\n' "$fp" | sed 's/^/  | /'
    else log "foreign Port directives: none"; fi
    local fl; fl="$(foreign ListenAddress)"
    [ -n "$fl" ] && { log "foreign ListenAddress directives:"; printf '%s\n' "$fl" | sed 's/^/  | /'; }

    local pf; pf="$(pending_path)"
    if [ -f "$pf" ]; then
        log "PENDING port change:"; sed 's/^/  | /' "$pf"
        log "  confirm: 90ssh.sh confirm --token <token>   |   undo: 90ssh.sh rollback"
    fi
    log "auth     : user=$AUSER drop-in=$D_DIR/$AUTH_DROPIN $([ -f "$D_DIR/$AUTH_DROPIN" ] && echo '(present)' || echo '(absent)')"
    log "           passwordauthentication=$(sshd_T | awk '$1=="passwordauthentication"{print $2}') kbdinteractive=$(sshd_T | awk '$1=="kbdinteractiveauthentication"{print $2}')  ($(key_only_on && echo key-only || echo preserve))"
    [ -f "$(auth_pending)" ] && { log "PENDING auth change:"; sed 's/^/  | /' "$(auth_pending)"; }
    [ -f "$(token_path)" ] && log "verify token: present"
    log "last backup: $(latest_backup || echo none)  |  auth backup: $(latest_auth_backup || echo none)"
}

do_plan() {
    [ -n "$PORT" ] || die "plan: --port is required"
    log "PLAN v$VER host=$(hostname)"
    log "  current  : ports=[$(live_ports)] bound=[$(ss_ports)] socket=${SOCKET_UNIT:-none} service=$SVC.service"
    if [ "$MODE" = final ]; then
        log "  target   : port $PORT only${LISTEN:+ on $LISTEN}; every other port closes"
        log "  requires : --confirmed --evidence <record of a publickey login on $PORT from another host>"
    else
        local keep; keep="$(live_ports | tr ' ' '\n' | grep -vx "$PORT" | tr '\n' ' ' | sed 's/ $//')"
        log "  target   : port $PORT added, keeping [$keep]"
        [ -z "$keep" ] && log "  blocking : no current port detected; pass --keep-port N"
    fi
    log "  drop-in  : $(managed)"
    log "  writes   : $(managed)$([ -n "$SOCK_DIR" ] && printf ' + %s/zz-90ssh.conf' "$SOCK_DIR")"
    local fp; fp="$(foreign Port)"
    [ -n "$fp" ] && { log "  foreign Port lines (need --take-over):"; printf '%s\n' "$fp" | sed 's/^/    | /'; }
    [ -n "$(foreign ListenAddress)" ] && log "  note      : other files set ListenAddress; they keep applying"
    include_present || log "  note      : sshd_config has no Include for $D_DIR; apply appends it (backed up)"
    [ -f "$(auth_pending)" ] && log "  blocking  : an auth change is pending"
    log "  auth      : not touched by port commands"
    selftest_hint
}

selftest_hint() {   # a single advisory line about host firewall state
    fake && return 0
    if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qE 'hook input.*policy drop'; then
        log "  firewall  : nft input default-drop; make sure tcp/$PORT is allowed before final"
    elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -q '^-P INPUT DROP'; then
        log "  firewall  : iptables INPUT default-drop; make sure tcp/$PORT is allowed before final"
    fi
}

do_apply() {
    local mode="$MODE" p="$PORT" dir before after eff keep fp fl
    [ -n "$p" ] || die "apply: --port is required"
    case "$p" in *[!0-9]*) die "apply: --port must be numeric";; esac
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "apply: --port out of range"
    case "$mode" in dual|final) ;; *) die "apply: --mode must be dual or final";; esac
    [ -f "$S_CFG" ] || die "apply: $S_CFG is missing"
    if [ "$mode" = final ]; then
        [ "$CONFIRMED" = 1 ] || die "apply: final closes every other port and needs --confirmed --evidence <record>"
        [ -n "$EVIDENCE" ] || die "apply: final needs --evidence from a real login on port $p from another host"
    fi
    dropin_resolve

    log "== preflight =="
    local inc_line match_line
    inc_line="$(grep -nE '^[[:space:]]*Include[[:space:]]+' "$S_CFG" | head -1 | cut -d: -f1)"
    match_line="$(grep -nE '^[[:space:]]*Match[[:space:]]+' "$S_CFG" | head -1 | cut -d: -f1)"
    if [ -n "$inc_line" ] && [ -n "$match_line" ] && [ "$match_line" -lt "$inc_line" ]; then
        die "apply: the Include line sits after a Match block; a drop-in there would be Match-scoped"
    fi
    if include_present; then log "  include: present"; else
        log "  include: missing, will append 'Include $D_DIR/*.conf' (backed up, reverted by rollback)"
        CREATE_INC=1
    fi

    keep="$(live_ports | tr ' ' '\n' | grep -vx "$p" | tr '\n' ' ' | sed 's/ $//')"
    if [ "$mode" = dual ] && [ -z "$keep" ]; then
        die "apply: cannot determine a current port to keep; pass --keep-port N"
    fi
    log "  keeping [$keep]  adding $p  socket=${SOCKET_UNIT:-none}  service=$SVC.service"

    [ -f "$(auth_pending)" ] && die "apply: an auth change is pending; finish it with 'auth confirm' or 'auth rollback' first"
    local pf; pf="$(pending_path)"
    if [ -f "$pf" ] && [ "$FORCE" != 1 ]; then
        log "  pending: $(tr '\n' ' ' < "$pf")"
        die "apply: an earlier port transition is unconfirmed; confirm or roll back first (--force-pending overrides)"
    fi
    fp="$(foreign Port 2>/dev/null)"
    fl="$(foreign ListenAddress 2>/dev/null)"
    if [ -n "$fp" ] && [ "$TAKEOVER" != 1 ]; then
        printf '%s\n' "$fp" | sed 's/^/  foreign: /'
        die "apply: Port directives exist outside $(managed); rerun with --take-over (they are commented out and backed up)"
    fi
    if [ "$mode" = final ]; then check_evidence "$EVIDENCE" port-final; fi
    if ! fake && port_bound "$p" && ! grep -qE "^[[:space:]]*Port[[:space:]]+$p([[:space:]]|$)" "$(managed)" 2>/dev/null; then
        if [ -z "$fp" ]; then
            command -v ss >/dev/null 2>&1 && ss -ltnp 2>/dev/null | grep -E "[:.]$p\$" | sed 's/^/  /'
            die "apply: tcp/$p is already in use by another service"
        fi
    fi
    selftest_hint

    local files="$S_CFG $(managed)"
    [ -n "$SOCK_DIR" ] && files="$files $SOCK_DIR/zz-90ssh.conf"
    local l
    for l in $fp; do files="$files ${l%%:*}"; done
    files="$(printf '%s\n' $files | awk '!seen[$0]++' | tr '\n' ' ')"
    take_backup port $files || die "apply: backup failed"
    dir="$BACKUP_DIR_CREATED"

    local tok="" grc=2
    if [ "$GUARD" -gt 0 ]; then
        [ "$GUARD" -ge 5 ] || die "apply: --guard needs at least 5 seconds"
        tok="$(date +%Y%m%d-%H%M%S)-$$"
        arm_guard port "$tok" "$dir" "port $p ($mode)" "port=$p" "mode=$mode"; grc=$?
        if [ "$grc" = 1 ]; then die "apply: the rollback guard could not be armed; refusing to touch sshd (nothing written)"; fi
        [ "$grc" = 2 ] && { warn "guard not armed (isolated test mode)"; tok=""; }
    fi

    if [ "$CREATE_INC" = 1 ]; then
        run sh -c "printf '\n# Added by box/90ssh.sh\nInclude %s/*.conf\n' '$D_DIR' >> '$S_CFG'"
    fi
    if [ -n "$fp" ] && [ "$TAKEOVER" = 1 ]; then
        printf '%s\n' "$fp" | while IFS=: read -r f _; do
            run sed -i -E 's|^([[:space:]]*)(Port[[:space:]]+.*)$|\1#90ssh-disabled # \2|' "$f"
            log "  commented Port in $f"
        done
    fi

    before="$(sshd_T | no_port_lines)"
    log "== write =="
    write_port_dropin "$p" "$mode" "$keep"
    write_socket_dropin "$p" "$mode" "$keep"

    log "== syntax =="
    if ! sshd_t >/dev/null; then
        sshd_t | sed 's/^/  /'
        warn "sshd -t failed -> rollback"
        restore port "$dir" "sshd-t-failed"
        return 3
    fi
    log "  sshd -t OK"

    if ! fake && [ "$DRY" != 1 ]; then
        log "== reload =="
        if socket_live; then
            systemctl daemon-reload; systemctl restart "$SOCKET_UNIT" \
                || { warn "socket restart failed -> rollback"; restore port "$dir" "socket-restart-failed"; return 4; }
        else
            systemctl reload "$SVC.service" || systemctl restart "$SVC.service" \
                || { warn "reload failed -> rollback"; restore port "$dir" "reload-failed"; return 4; }
        fi
        sleep 2

        log "== post-checks =="
        if ! port_bound "$p"; then
            warn "tcp/$p is not listening -> rollback"; restore port "$dir" "new-port-missing"; return 5
        fi
        if [ "$mode" = dual ]; then
            for l in $keep; do
                port_bound "$l" || { warn "previous port $l was lost -> rollback"; restore port "$dir" "old-port-lost"; return 5; }
            done
        else
            eff="$(sshd_T | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ' | sed 's/ $//')"
            if [ "$eff" != "$p" ]; then
                warn "effective ports are [$eff], expected [$p] -> rollback"; restore port "$dir" "final-port-set"; return 6
            fi
            for l in $keep; do
                port_bound "$l" && { warn "old port $l still bound -> rollback"; restore port "$dir" "final-old-port-open"; return 6; }
            done
        fi
        after="$(sshd_T | no_port_lines)"
        if [ "$before" != "$after" ]; then
            warn "sshd changed outside the port surface -> rollback"
            diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/  /'
            restore port "$dir" "policy-drift"
            return 7
        fi
        log "  every non-port directive is unchanged"
    fi

    [ "$mode" = final ] && rm -f "$(token_path)"
    log "APPLY OK mode=$mode ports=[$(live_ports)] backup=$dir"
    if [ -n "$tok" ]; then
        log ""
        log "  port $p is live but UNCONFIRMED; everything rolls back in ${GUARD}s unless you:"
        log "    a) verify from another host, then 'apply --port $p --mode final --confirmed --evidence <file>'"
        log "    b) or 'confirm --token $tok' to keep the dual-port state"
    elif [ "$mode" = dual ]; then
        log "  next: verify from another host, then 'apply --port $p --mode final --confirmed --evidence <file>'"
    fi
    return 0
}

write_port_dropin() {
    local p="$1" mode="$2" keep="$3" target tmp k
    target="$(managed)"
    run install -d -m 0755 "$D_DIR"
    tmp="$(mktemp)"
    {
        echo "# Managed by box/90ssh.sh v$VER -- do not edit by hand."
        echo "# Authentication policy is deliberately not set here."
        if [ "$mode" = final ]; then
            echo "# mode: final, port $p only"
            echo "Port $p"
            [ -n "$LISTEN" ] && echo "ListenAddress $LISTEN"
        else
            echo "# mode: dual, keeps the ports that were live when this was written"
            for k in $keep; do echo "Port $k"; done
            echo "Port $p"
        fi
    } > "$tmp"
    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then rm -f "$tmp"; log "  drop-in unchanged: $target"; return 0; fi
    run install -m 0644 "$tmp" "$target"
    rm -f "$tmp"
    log "  wrote $target"
}

# Socket-activated hosts take their listen list from the socket unit, so the
# drop-in list has to be rewritten too.  Addresses are reused as they are now;
# only the ports change.
write_socket_dropin() {
    local p="$1" mode="$2" keep="$3" f tmp addr addrs="" e k
    [ -n "$SOCK_DIR" ] || return 0
    [ -n "$SOCKET_UNIT" ] || return 0
    socket_live || return 0
    for e in $(sock_listens); do
        addr="${e%:*}"
        case " $addrs " in *" $addr "*) ;; *) addrs="$addrs $addr";; esac
    done
    [ -n "$addrs" ] || addrs="0.0.0.0 [::]"
    [ -n "$LISTEN" ] && [ "$mode" = final ] && addrs="$LISTEN"
    f="$SOCK_DIR/zz-90ssh.conf"
    run install -d -m 0755 "$SOCK_DIR"
    tmp="$(mktemp)"
    {
        echo "# Managed by box/90ssh.sh v$VER"
        echo "[Socket]"
        echo "ListenStream="
        if [ "$mode" = final ]; then
            for addr in $addrs; do echo "ListenStream=$addr:$p"; done
        else
            for k in $keep $p; do for addr in $addrs; do echo "ListenStream=$addr:$k"; done; done
        fi
    } > "$tmp"
    if [ -f "$f" ] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; log "  socket drop-in unchanged"; return 0; fi
    run install -m 0644 "$tmp" "$f"
    rm -f "$tmp"
    log "  wrote $f"
}

do_confirm() {
    [ -n "$TOKEN" ] || die "confirm: --token required"
    local pf; pf="$(pending_path)"
    [ -f "$pf" ] || die "confirm: no pending port transition on this host"
    local want; want="$(sed -n 's/^token=//p' "$pf" | head -1)"
    [ "$want" = "$TOKEN" ] || die "confirm: token does not match the pending transition ($want)"
    install -d -m 0700 "$RUN"
    : > "$RUN/$TOKEN.ok"
    stop_guard port "$TOKEN"
    rm -f "$pf"
    log "confirmed: guard disarmed, the dual-port state is kept"
    log "  finish with: apply --port <new> --mode final --confirmed --evidence <file>"
}
# ------------------------------------------------------------------- auth ---
# key-only touches exactly two directives, in its own drop-in, behind its own
# backup/pending/token/guard.  Everything else (PermitRootLogin, Pubkey,
# AuthorizedKeysFile, Match blocks, ports, authorized_keys) is left alone and is
# verified to be unchanged afterwards.
AUTH_KEYS='passwordauthentication|kbdinteractiveauthentication'

key_only_on() {
    local g u
    g="$(sshd_T | awk '$1=="passwordauthentication"{print $2}')$(sshd_T | awk '$1=="kbdinteractiveauthentication"{print $2}')"
    u="$(sshd_T "$AUSER" | awk '$1=="passwordauthentication"{print $2}')$(sshd_T "$AUSER" | awk '$1=="kbdinteractiveauthentication"{print $2}')"
    [ "$g" = nono ] && [ "$u" = nono ]
}

# Directives that decide the auth policy, in the order sshd reads them.
auth_sources() {
    local f
    [ -f "$S_CFG" ] && grep -nEi "^[[:space:]]*($AUTH_KEYS|authenticationmethods)[[:space:]]+" "$S_CFG" 2>/dev/null | sed "s|^|$S_CFG:|"
    [ -d "$D_DIR" ] || return 0
    for f in "$D_DIR"/*.conf; do
        [ -f "$f" ] || continue
        grep -nEi "^[[:space:]]*($AUTH_KEYS|authenticationmethods)[[:space:]]+" "$f" 2>/dev/null | sed "s|^|$f:|"
    done
}

# Sources that would win over our drop-in and re-enable a password method.
auth_losers() {
    local inc f base n
    inc="$(grep -nE '^[[:space:]]*Include[[:space:]]+' "$S_CFG" 2>/dev/null | head -1 | cut -d: -f1)"
    if [ -n "$inc" ]; then
        awk -v n="$inc" 'NR<n && tolower($1) ~ /^(passwordauthentication|kbdinteractiveauthentication)$/ && tolower($2)=="yes" {print FILENAME":"NR": "$0}' "$S_CFG" 2>/dev/null
    fi
    [ -d "$D_DIR" ] || return 0
    for f in "$D_DIR"/*.conf; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        [ "$base" = "$AUTH_DROPIN" ] && continue
        # shellcheck disable=SC2012
        [ "$(printf '%s\n%s\n' "$base" "$AUTH_DROPIN" | sort | head -1)" = "$base" ] || continue
        n="$(grep -nEi "^[[:space:]]*($AUTH_KEYS)[[:space:]]+yes([[:space:]]|$)" "$f" 2>/dev/null | head -1 | cut -d: -f1)"
        [ -n "$n" ] && echo "$f:$n"
    done
}

match_auth() {
    grep -nEi '^[[:space:]]*Match[[:space:]]' -A4 "$S_CFG" 2>/dev/null | grep -Ei "^[0-9]+[-:][[:space:]]*($AUTH_KEYS)[[:space:]]+yes" | head -3
}

cloud_init_auth() {
    local f
    for f in "$D_DIR"/50-cloud-init.conf "$D_DIR"/60-cloudimg-settings.conf \
             "$PREFIX"/etc/cloud/cloud.cfg "$PREFIX"/etc/cloud/cloud.cfg.d/*.cfg; do
        [ -f "$f" ] || continue
        grep -qEi '(ssh_pwauth|disable_root|PasswordAuthentication|KbdInteractive)' "$f" 2>/dev/null && echo "$f"
    done
}

do_auth_status() {
    [ -f "$S_CFG" ] || die "auth status: $S_CFG is missing"
    local g u
    g="$(sshd_T | grep -E "^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication|authenticationmethods) " | tr '\n' ' ')"
    u="$(sshd_T "$AUSER" | grep -E "^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication|authenticationmethods) " | tr '\n' ' ')"
    log "90ssh.sh v$VER  auth status  host=$(hostname)"
    log "account   : $AUSER (home $(user_home "$AUSER"))"
    log "drop-in   : $D_DIR/$AUTH_DROPIN $([ -f "$D_DIR/$AUTH_DROPIN" ] && echo '(present)' || echo '(absent)')"
    [ -f "$D_DIR/$AUTH_DROPIN" ] && sed 's/^/  | /' "$D_DIR/$AUTH_DROPIN"
    log "global    : $g"
    log "account   : $u"
    log "policy    : $(key_only_on && echo key-only || echo preserve)"
    log "include   : $(include_present && echo present || echo MISSING)"
    local s; s="$(auth_sources)"
    if [ -n "$s" ]; then log "sources (read order):"; printf '%s\n' "$s" | sed 's/^/  | /'; else log "sources   : none (sshd defaults)"; fi
    local ci; ci="$(cloud_init_auth)"
    [ -n "$ci" ] && { log "cloud-init/image files:"; printf '%s\n' "$ci" | sed 's/^/  | /'; }
    local m; m="$(match_auth)"
    [ -n "$m" ] && { log "Match rules that re-enable passwords:"; printf '%s\n' "$m" | sed 's/^/  | /'; }
    if [ -f "$(auth_pending)" ]; then
        log "PENDING auth change:"; sed 's/^/  | /' "$(auth_pending)"
        log "  confirm: auth confirm --token <token> --evidence <post-change record>"
        log "  undo   : auth rollback"
    fi
    [ -f "$(pending_path)" ] && log "pending port change: yes (blocks auth apply)"
    log "last auth backup: $(latest_auth_backup || echo none)"
}

# Read-only prediction.  Apply re-checks the live configuration afterwards and
# rolls back if the prediction was wrong, so this does not need a config mirror.
do_auth_plan() {
    [ "$MODE" = key-only ] || die "auth plan: --mode key-only is required (preserve is the default and needs no change)"
    [ -f "$S_CFG" ] || die "auth plan: $S_CFG is missing"
    log "AUTH PLAN v$VER host=$(hostname) user=$AUSER"
    log "  drop-in : $D_DIR/$AUTH_DROPIN"
    log "  before  : $(sshd_T "$AUSER" | awk '$1~/^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication|authenticationmethods)$/{printf "%s=%s ",$1,$2}')"
    local inc; inc="$(grep -nE '^[[:space:]]*Include[[:space:]]+' "$S_CFG" | head -1 | cut -d: -f1)"
    log "  include : ${inc:+line $inc}${inc:-MISSING (apply prepends it)}"
    if key_only_on; then
        log "  verdict : ALREADY KEY-ONLY (nothing to change)"
        return 0
    fi
    local losers; losers="$(auth_losers)"
    if [ -n "$losers" ]; then
        log "  verdict : REFUSED -- these lines are read before the drop-in and re-enable a password method:"
        printf '%s\n' "$losers" | sed 's/^/    | /'
        log "  options :"
        log "    * comment those lines out in a change window (they are the real policy), or"
        log "    * merge the two switches into the file that already wins"
        return 1
    fi
    local m; m="$(match_auth)"
    if [ -n "$m" ]; then
        log "  risk    : a Match block re-enables password auth for some users:"
        printf '%s\n' "$m" | sed 's/^/    | /'
        log "            apply checks the effective policy for $AUSER afterwards and rolls back if it is not off"
    fi
    local ci; ci="$(cloud_init_auth)"
    [ -n "$ci" ] && { log "  cloud-init files present:"; printf '%s\n' "$ci" | sed 's/^/    | /'; }
    log "  verdict : OK -- both switches will be off for $AUSER"
    log "  requires: --evidence <key-only record> and --console-ok"
    return 0
}

do_auth_apply() {
    local dir pf tok="" grc=2 ports_before after
    [ "$MODE" = key-only ] || die "auth apply: --mode key-only is the only supported value"
    [ -f "$S_CFG" ] || die "auth apply: $S_CFG is missing"
    [ -f "$(pending_path)" ] && die "auth apply: a port transition is pending; confirm or roll that back first"
    pf="$(auth_pending)"
    if [ -f "$pf" ] && [ "$FORCE" != 1 ]; then
        log "  pending: $(tr '\n' ' ' < "$pf")"
        die "auth apply: an auth change is already pending; confirm or roll it back (--force-pending overrides)"
    fi
    [ "$CONSOLE_OK" = 1 ] || die "auth apply: refusing to disable password logins without --console-ok (provider console, IPMI or serial access)"
    [ -n "$EVIDENCE" ] || die "auth apply: --evidence from a real publickey login by $AUSER is required"
    check_evidence "$EVIDENCE" auth-key-only

    log "== auth preflight =="
    if key_only_on; then
        log "  $AUSER already gets passwordauthentication=no kbdinteractiveauthentication=no"
        log "AUTH APPLY OK mode=key-only (nothing to change)"
        return 0
    fi
    local inc; inc="$(grep -nE '^[[:space:]]*Include[[:space:]]+' "$S_CFG" | head -1 | cut -d: -f1)"
    local mline; mline="$(grep -nE '^[[:space:]]*Match[[:space:]]+' "$S_CFG" | head -1 | cut -d: -f1)"
    if [ -n "$inc" ] && [ -n "$mline" ] && [ "$mline" -lt "$inc" ]; then
        die "auth apply: the Include line sits after a Match block; the drop-in would be Match-scoped"
    fi
    local losers; losers="$(auth_losers)"
    if [ -n "$losers" ]; then
        printf '%s\n' "$losers" | sed 's/^/  earlier: /'
        die "auth apply: a file read before ours re-enables a password method; fix that first"
    fi
    if ! include_present; then
        log "  include: missing, will be prepended at the top of sshd_config (backed up)"
        CREATE_INC=1
    else
        log "  include: present"
    fi
    log "  target  : $AUSER, ports [$(live_ports)] stay unchanged"

    take_backup auth "$S_CFG" "$D_DIR/$AUTH_DROPIN" || die "auth apply: backup failed"
    dir="$BACKUP_DIR_CREATED"

    # A confirmation token always exists, so 'auth confirm' can retire the
    # pending record even when no timer was armed (--guard 0).
    tok="$(date +%Y%m%d-%H%M%S)-$$"
    if [ "$GUARD" -gt 0 ]; then
        [ "$GUARD" -ge 5 ] || die "auth apply: --guard needs at least 5 seconds"
        arm_guard auth "$tok" "$dir" "key-only for $AUSER" "user=$AUSER"; grc=$?
        if [ "$grc" = 1 ]; then die "auth apply: the rollback guard could not be armed; refusing to change authentication (nothing written)"; fi
        [ "$grc" = 2 ] && warn "no timer armed (isolated/staging mode); the change is still recorded as pending"
    fi

    ports_before="$(live_ports)"
    if [ "$CREATE_INC" = 1 ]; then
        run sh -c "awk 'BEGIN{d=0} {if(!d){print \"Include $D_DIR/*.conf\"; d=1} print}' '$S_CFG' > '$S_CFG.90ssh' && cat '$S_CFG.90ssh' > '$S_CFG' && rm -f '$S_CFG.90ssh'"
        log "  prepended Include to $S_CFG"
    fi

    log "== write =="
    run install -d -m 0755 "$D_DIR"
    local tmp; tmp="$(mktemp)"
    {
        echo "# Managed by box/90ssh.sh v$VER -- key-only for $AUSER."
        echo "# Only these two directives are managed here."
        echo "# PermitRootLogin, PubkeyAuthentication, AuthorizedKeysFile, Match blocks,"
        echo "# ports and authorized_keys are NOT touched."
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
    } > "$tmp"
    if [ -f "$D_DIR/$AUTH_DROPIN" ] && cmp -s "$tmp" "$D_DIR/$AUTH_DROPIN"; then
        log "  drop-in unchanged"
    else
        run install -m 0644 "$tmp" "$D_DIR/$AUTH_DROPIN" || { rm -f "$tmp"; restore auth "$dir" "write-failed"; die "auth apply: cannot write the drop-in"; }
        log "  wrote $D_DIR/$AUTH_DROPIN"
    fi
    rm -f "$tmp"

    log "== syntax =="
    if ! sshd_t >/dev/null; then
        sshd_t | sed 's/^/  /'
        warn "sshd -t failed -> rollback"
        restore auth "$dir" "sshd-t-failed"
        return 3
    fi
    log "  sshd -t OK"

    if ! fake && [ "$DRY" != 1 ]; then
        log "== reload =="
        if svc_active | grep -qx active; then
            systemctl reload "$SVC.service" || systemctl restart "$SVC.service" \
                || { warn "reload failed -> rollback"; restore auth "$dir" "reload-failed"; return 4; }
        elif socket_live; then
            log "  socket-activated: each new connection re-reads the configuration"
        else
            warn "neither $SVC.service nor a socket is active -> rollback"
            restore auth "$dir" "no-active-unit"
            return 4
        fi
        sleep 1
    fi

    log "== post-checks =="
    local g u
    g="$(sshd_T | grep -E '^(passwordauthentication|kbdinteractiveauthentication) ' | awk '{print $2}' | tr '\n' ' ')"
    u="$(sshd_T "$AUSER" | grep -E '^(passwordauthentication|kbdinteractiveauthentication) ' | awk '{print $2}' | tr '\n' ' ')"
    if [ "$g" != "no no " ] || [ "$u" != "no no " ]; then
        warn "effective policy is [$g] for the host and [$u] for $AUSER -> rollback"
        restore auth "$dir" "auth-not-effective"
        return 6
    fi
    after="$(live_ports)"
    if [ "$after" != "$ports_before" ]; then
        warn "ports changed during an auth operation ([$ports_before] -> [$after]) -> rollback"
        restore auth "$dir" "port-drift"
        return 7
    fi
    if [ -f "$dir/sshd-T.before" ] && \
       [ "$(sshd_T | no_auth_lines)" != "$(no_auth_lines < "$dir/sshd-T.before")" ]; then
        warn "a directive other than the two auth switches changed -> rollback"
        diff <(no_auth_lines < "$dir/sshd-T.before") <(sshd_T | no_auth_lines) | sed 's/^/  /'
        restore auth "$dir" "policy-drift"
        return 7
    fi
    log "  passwordauthentication=no kbdinteractiveauthentication=no, for the host and for $AUSER"
    log "  ports unchanged [$after]; every other directive unchanged"

    install -d -m 0700 "$STATE" "$RUN"
    local vt; vt="$(new_token)"
    ( umask 077; printf '%s\n' "$vt" > "$(token_path)" )
    {
        echo "kind=auth"; echo "mode=key-only"; echo "user=$AUSER"
        echo "token=$tok"; echo "backup=$dir"; echo "applied_at=$(date +%s)"
        echo "verify_token=$vt"
        [ -n "$tok" ] && echo "deadline=$(( $(date +%s) + GUARD ))"
    } > "$pf"
    log "AUTH APPLY OK mode=key-only user=$AUSER backup=$dir"
    log ""
    log "  the change is live but UNCONFIRMED; existing sessions keep working."
    log "  prove it from another host, then confirm:"
    log "    90ssh.sh verify --port $(printf '%s' "$after" | awk '{print $1}') --host <this-host> --key <key> \\"
    log "       --user $AUSER --token $vt --purpose auth-post --probe --evidence /tmp/ev-auth-post.txt"
    log "    90ssh.sh auth confirm --token $tok --evidence /tmp/ev-auth-post.txt"
    [ -n "$tok" ] && log "  without confirmation everything is restored in ${GUARD}s."
    return 0
}

do_auth_confirm() {
    [ -n "$TOKEN" ] || die "auth confirm: --token required"
    local pf; pf="$(auth_pending)"
    [ -f "$pf" ] || die "auth confirm: no pending auth change on this host"
    local want; want="$(sed -n 's/^token=//p' "$pf" | head -1)"
    [ "$want" = "$TOKEN" ] || die "auth confirm: token does not match the pending change ($want)"
    [ -n "$EVIDENCE" ] || die "auth confirm: --evidence from a login made after the change is required"
    AUSER="$(sed -n 's/^user=//p' "$pf" | head -1)"; [ -n "$AUSER" ] || AUSER=root
    check_evidence "$EVIDENCE" auth-post post
    install -d -m 0700 "$RUN"
    : > "$RUN/$TOKEN.ok"
    stop_guard auth "$TOKEN"
    rm -f "$pf" "$(token_path)"
    log "AUTH CONFIRMED: key-only is in force for $AUSER, guard disarmed"
    log "  managed drop-in kept: $D_DIR/$AUTH_DROPIN"
}

do_auth_rollback() { restore auth "${BACKUP:-$(latest_auth_backup)}" "${REASON:-manual}"; }

# ---------------------------------------------------------- bootstrap-key ---
user_home() {
    if [ -n "${FAKE_HOME:-}" ]; then printf '%s' "$FAKE_HOME"; return; fi
    getent passwd "$1" 2>/dev/null | cut -d: -f6
}
user_group() {
    if [ -n "${FAKE_UID:-}" ]; then printf '%s' "${FAKE_GID:-$FAKE_UID}"; return; fi
    getent passwd "$1" 2>/dev/null | cut -d: -f4
}
own_as() {
    local p="$1" u="$2" g
    fake && return 0
    [ "$(id -u)" = 0 ] || return 0
    g="$(user_group "$u")"
    chown "$u:$g" "$p" 2>/dev/null || chown "$u" "$p" 2>/dev/null || warn "cannot set owner of $p to $u"
}

# Pull "type blob" out of an authorized_keys style line (options are dropped).
key_body() {
    local b
    set -- $1
    while [ $# -gt 0 ]; do
        case "$1" in
            ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
                b="${2:-}"
                [ -n "$b" ] || return 1
                printf '%s %s\n' "$1" "$b"
                return 0 ;;
        esac
        shift
    done
    return 1
}

key_fp() {
    local tf; tf="$(mktemp)"
    printf '%s\n' "$1" > "$tf"
    ssh-keygen -l -f "$tf" 2>/dev/null | awk '{print $2}'
    rm -f "$tf"
}

do_bootstrap_key() {
    local u="$AUSER" home kd akf ts dir line kb tmp added=0
    [ -n "$PUBKEY" ] || die "bootstrap-key: --pubkey FILE is required"
    [ -f "$PUBKEY" ] && [ -r "$PUBKEY" ] || die "bootstrap-key: cannot read $PUBKEY"
    case "$u" in ''|*[!A-Za-z0-9._-]*) die "bootstrap-key: invalid user '$u'";; esac
    [ "$(id -u)" = 0 ] || [ "$u" = "$(id -un)" ] || die "bootstrap-key: root is required to install a key for $u"
    home="$(user_home "$u")"
    [ -n "$home" ] && [ -d "$home" ] || die "bootstrap-key: no home directory for $u"
    case "$home" in /) die "bootstrap-key: refusing home '/'";; esac
    kd="$home/.ssh"; akf="$kd/authorized_keys"
    [ -L "$kd" ] && die "bootstrap-key: $kd is a symlink; fix that by hand first"
    [ -e "$kd" ] && [ ! -d "$kd" ] && die "bootstrap-key: $kd is not a directory"
    [ -L "$akf" ] && die "bootstrap-key: $akf is a symlink; fix that by hand first"
    [ -e "$akf" ] && [ ! -f "$akf" ] && die "bootstrap-key: $akf is not a regular file"

    tmp="$(mktemp -d)" || die "bootstrap-key: mktemp failed"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue;; esac
        case "$line" in *'PRIVATE KEY'*) rm -rf "$tmp"; die "bootstrap-key: $PUBKEY contains a private key; only public keys are accepted";; esac
        kb="$(key_body "$line")" || { rm -rf "$tmp"; die "bootstrap-key: '$line' is not a usable SSH public key"; }
        printf '%s' "$kb" | awk '{print $2}' | base64 -d >/dev/null 2>&1 \
            || { rm -rf "$tmp"; die "bootstrap-key: malformed key blob in $PUBKEY"; }
        key_fp "$kb" >/dev/null || { rm -rf "$tmp"; die "bootstrap-key: ssh-keygen cannot parse that key"; }
        printf '%s\n' "$kb" >> "$tmp/new"
    done < "$PUBKEY"
    [ -s "$tmp/new" ] || { rm -rf "$tmp"; die "bootstrap-key: no public key found in $PUBKEY"; }

    : > "$tmp/have"
    if [ -f "$akf" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|'#'*) continue;; esac
            kb="$(key_body "$line")" || continue
            printf '%s\n' "$kb" >> "$tmp/have"
        done < "$akf"
    fi
    : > "$tmp/add"
    while IFS= read -r kb; do
        if grep -qxF "$kb" "$tmp/have"; then
            log "  already present: $(key_fp "$kb")"
            continue
        fi
        printf '%s\n' "$kb" >> "$tmp/add"
        printf '%s\n' "$kb" >> "$tmp/have"
        added=$((added + 1))
    done < "$tmp/new"
    if [ "$added" = 0 ]; then
        log "bootstrap-key: nothing to do, all keys are already in $akf"
        rm -rf "$tmp"
        return 0
    fi

    ts="$(date '+%Y%m%d-%H%M%S')"; local n=1
    dir="$PREFIX/root/90ssh-key-backup-$ts"
    while [ -e "$dir" ]; do n=$((n + 1)); dir="$PREFIX/root/90ssh-key-backup-$ts-$n"; done
    run install -d -m 0700 "$dir" || { rm -rf "$tmp"; die "bootstrap-key: cannot create $dir"; }
    if [ -f "$akf" ]; then run cp -p "$akf" "$dir/authorized_keys" || die "bootstrap-key: backup failed"; fi
    { echo "user=$u"; echo "file=$akf"; echo "existed=$([ -f "$akf" ] && echo yes || echo no)"
      echo "sha256=$([ -f "$akf" ] && sha256sum "$akf" | awk '{print $1}' || echo -)"; } > "$dir/state"
    {
        echo '#!/bin/sh'
        echo '# restores authorized_keys as it was before this bootstrap-key run'
        echo 'set -e'
        if [ -f "$akf" ]; then
            echo "cp -p '$dir/authorized_keys' '$akf'"
        else
            echo "rm -f '$akf'"
        fi
        echo "chmod 600 '$akf' 2>/dev/null || true"
    } > "$dir/RESTORE.sh"
    chmod 0700 "$dir/RESTORE.sh"
    log "  backup: $dir (RESTORE.sh restores this file)"

    log "== bootstrap-key user=$u =="
    run install -d -m 0700 "$kd" || { rm -rf "$tmp"; die "bootstrap-key: cannot create $kd"; }
    own_as "$kd" "$u"
    local newf="$kd/.authorized_keys.90ssh.$$"
    ( umask 077; : > "$newf" ) || { rm -rf "$tmp"; die "bootstrap-key: cannot create $newf"; }
    [ -f "$akf" ] && cat "$akf" > "$newf"
    if [ -s "$newf" ] && [ -n "$(tail -c 1 "$newf")" ]; then printf '\n' >> "$newf"; fi
    while IFS= read -r kb; do printf '%s\n' "$kb" >> "$newf"; done < "$tmp/add"
    run chmod 0600 "$newf"
    own_as "$newf" "$u"
    run mv -f "$newf" "$akf" || { run rm -f "$newf"; rm -rf "$tmp"; die "bootstrap-key: atomic replace failed"; }
    own_as "$akf" "$u"
    [ "$(stat -c %a "$akf" 2>/dev/null)" = 600 ] || run chmod 0600 "$akf"

    while IFS= read -r kb; do log "  ADDED $(key_fp "$kb")  $(printf '%s' "$kb" | awk '{print $1}')"; done < "$tmp/add"
    log "  authorized_keys: $akf mode $(stat -c %a "$akf" 2>/dev/null) sha256 $(sha256sum "$akf" | awk '{print $1}')"
    local akfile; akfile="$(sshd_T "$u" | awk '$1=="authorizedkeysfile"{print $2; exit}')"
    case "$akfile" in
        *authorized_keys*) ;;
        *) warn "AuthorizedKeysFile is '${akfile:-?}' and may not include $akf";;
    esac
    [ "$(stat -c %a "$home" 2>/dev/null)" -gt 755 ] 2>/dev/null \
        && warn "$home is group/world writable; StrictModes will ignore the key until that is fixed"
    rm -rf "$tmp"
    log "bootstrap-key: OK added=$added backup=$dir"
    log "  test it before relying on it: ssh -i <private-key> -p <port> $u@<host> true"
    return 0
}
# ------------------------------------------------------------------ menu ---
ask() { printf '%s' "$1"; ANS=""; IFS= read -r ANS || ANS=""; }

do_menu() {
    local c g
    while :; do
        printf '\n==============================================\n'
        printf ' 90ssh.sh v%s   SSH port / key / auth\n' "$VER"
        printf ' host %s   ports [%s]   auth %s\n' "$(hostname)" "$(live_ports)" "$(key_only_on && echo key-only || echo preserve)"
        [ -f "$(pending_path)" ] && printf ' PENDING port change\n'
        [ -f "$(auth_pending)" ] && printf ' PENDING auth change\n'
        printf '==============================================\n'
        printf ' 1) status              2) plan port\n'
        printf ' 3) apply dual-port     4) verify token\n'
        printf ' 5) apply final         6) confirm port\n'
        printf ' 7) rollback port       8) self-test\n'
        printf ' 9) auth status        10) install key\n'
        printf '11) auth plan          12) auth apply\n'
        printf '13) auth confirm       14) auth rollback\n'
        printf ' 0) exit\n'
        printf '==============================================\n'
        ask 'select: '; c="$ANS"
        case "$c" in
            1) do_status;;
            2) ask 'port: '; PORT="$ANS"; [ -n "$PORT" ] && do_plan || warn "no port";;
            3) ask 'port: '; PORT="$ANS"
               [ -n "$PORT" ] || { warn "no port"; continue; }
               ask "guard seconds (0=off) [300]: "; g="$ANS"; [ -n "$g" ] || g=300
               ask "add port $PORT next to [$(live_ports)]? [y/N]: "
               case "$ANS" in y|Y|yes) GUARD="$g"; MODE=dual; ( do_apply ) || warn "apply did not finish";; *) log "cancelled";; esac;;
            4) ask 'port: '; PORT="$ANS"; [ -n "$PORT" ] || { warn "no port"; continue; }
               ask 'purpose [port-final]: '; PURPOSE="${ANS:-port-final}"; ISSUE=1; issue_token; ISSUE=0;;
            5) ask 'port: '; PORT="$ANS"; ask 'evidence file: '; EVIDENCE="$ANS"
               [ -n "$PORT" ] && [ -n "$EVIDENCE" ] || { warn "port and evidence are required"; continue; }
               ask "close every other port and keep only $PORT? type yes: "
               case "$ANS" in yes) MODE=final CONFIRMED=1; ( do_apply ) || warn "apply did not finish";; *) log "cancelled";; esac;;
            6) ask 'token: '; TOKEN="$ANS"; [ -n "$TOKEN" ] && ( do_confirm ) || warn "no token";;
            7) ask 'backup dir (empty = latest): '; BACKUP="$ANS"; ask 'roll back? [y/N]: '
               case "$ANS" in y|Y|yes) ( restore port "${BACKUP:-$(latest_backup)}" menu ) || warn "rollback failed";; *) log "cancelled";; esac;;
            8) do_selftest;;
            9) do_auth_status;;
           10) ask 'user [root]: '; AUSER="${ANS:-root}"; ask 'public key file: '; PUBKEY="$ANS"
               [ -n "$PUBKEY" ] && { ( do_bootstrap_key ) || warn "bootstrap-key failed"; } || warn "no file";;
           11) ask 'user [root]: '; AUSER="${ANS:-root}"; MODE=key-only
               ( do_auth_plan ) || warn "plan says no (see above)";;
           12) ask 'user [root]: '; AUSER="${ANS:-root}"; ask 'evidence file: '; EVIDENCE="$ANS"
               [ -n "$EVIDENCE" ] || { warn "evidence is required"; continue; }
               ask "disable password logins for $AUSER? type yes: "
               case "$ANS" in
                   yes) ask 'console/IPMI/serial access available? [y/N]: '
                        case "$ANS" in
                            y|Y) CONSOLE_OK=1; MODE=key-only
                                 ask 'guard seconds (0=off) [300]: '; g="$ANS"; [ -n "$g" ] || g=300; GUARD="$g"
                                 ( do_auth_apply ) || warn "auth apply did not finish";;
                            *) log "cancelled: no console acknowledgement";;
                        esac;;
                   *) log "cancelled";;
               esac;;
           13) ask 'token: '; TOKEN="$ANS"; ask 'post-change evidence: '; EVIDENCE="$ANS"
               [ -n "$TOKEN" ] && [ -n "$EVIDENCE" ] && { ( do_auth_confirm ) || warn "confirm failed"; } || warn "token and evidence are required";;
           14) ask 'backup dir (empty = latest auth backup): '; BACKUP="$ANS"; ask 'roll back the auth change? [y/N]: '
               case "$ANS" in y|Y|yes) ( do_auth_rollback ) || warn "auth rollback failed";; *) log "cancelled";; esac;;
            0|q|Q|"") log "bye"; return 0;;
            *) warn "unknown choice: $c";;
        esac
    done
}

# ------------------------------------------------------------------- test ---
do_selftest() {
    local rc=0 base; base="$(mktemp -d)"
    ok()  { log "  PASS $*"; }
    bad() { log "  FAIL $*"; rc=1; }
    is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

    fixture() {   # fixture <dir> [extra dropin name]
        install -d -m 0755 "$1/etc/ssh/sshd_config.d"
        ssh-keygen -q -t ed25519 -N '' -f "$1/hk" >/dev/null 2>&1
        cat > "$1/etc/ssh/sshd_config" <<EOF
Include $1/etc/ssh/sshd_config.d/*.conf
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PubkeyAuthentication yes
HostKey $1/hk
EOF
        printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY test@fixture\n' > "$1/etc/ssh/authorized_keys"
        [ -n "${2:-}" ] && printf '%s\n' "$3" > "$1/etc/ssh/sshd_config.d/$2"
        return 0
    }
    E()  { sshd -T -f "$1/etc/ssh/sshd_config" 2>/dev/null; }
    eh() { sshd -T -f "$1/etc/ssh/sshd_config" 2>/dev/null > "$1/.eff"; grep -qx "$2" "$1/.eff"; }
    P()  { PREFIX="$1" FAKE_PORTS="${2:-22}" FAKE_SOCK_STREAMS="${FAKE_SOCK_STREAMS:-}" \
           FAKE_HOME="$1/home" FAKE_UID="${FAKE_UID:-1000}" FAKE_GUARD="${FG:-none}" \
           bash "$0" "${@:3}" 2>&1; }
    NP() { PREFIX="$1" FAKE_HOME="$1/home" FAKE_UID=1000 bash "$0" "${@:2}" 2>&1; }
    dg() { { echo "== $1/etc/ssh/sshd_config"; cat "$1/etc/ssh/sshd_config"
             for f in "$1"/etc/ssh/sshd_config.d/*.conf; do [ -f "$f" ] || continue; echo "== $f"; cat "$f"; done
           } | sha256sum | awk '{print $1}'; }
    tok(){ PREFIX="$1" bash "$0" verify --issue-token --port "${2:-22}" --purpose "${3:-port-final}" >/dev/null 2>&1; }
    # ev <dir> <purpose> <user> <password_offered> [epoch] [token] [port]
    ev() {
        local d="$1" pu="$2" u="$3" pw="$4" ep="${5:-}" tk="${6:-}" pt="${7:-}"
        [ -n "$ep" ] || ep="$(date +%s)"
        [ -n "$tk" ] || tk="$(cat "$d/run/90ssh/verify.token" 2>/dev/null)"
        [ -n "$pt" ] || pt="$(E "$d" | awk '$1=="port"{p=$2} END{print p}')"
        { echo "ver=2"; echo "purpose=$pu"; echo "result=ok"; echo "port=$pt"; echo "server_port=$pt"
          echo "host=test-host"; echo "user=$u"; echo "uid=1000"
          echo "client_ip=198.51.100.7"; echo "client_host=test-client"
          echo "server_host=test-host"; echo "server_id=$(cat /etc/machine-id 2>/dev/null)"
          echo "sshd_pid=1"; echo "password_offered=$pw"; echo "cfg_digest=$(dg "$d")"
          echo "key_fp=SHA256:testkey"; echo "token=$tk"; echo "ts=x"; echo "epoch=$ep"
        } > "$d/ev-$pu.txt"
        printf '%s' "$d/ev-$pu.txt"
    }

    log "== self-test: prefix=$base, $(sshd -V 2>&1 | head -1) =="

    # ---- A: dual port ------------------------------------------------------
    local a="$base/a"; fixture "$a"; tok "$a" 47032
    local ak; ak="$(sha256sum "$a/etc/ssh/authorized_keys" | awk '{print $1}')"
    P "$a" 22 apply --port 47032 --mode dual > "$a/o1"
    grep -q 'APPLY OK mode=dual' "$a/o1" && ok "A dual apply" || { bad "A dual apply"; tail -4 "$a/o1"; }
    is "A two ports effective" "$(E "$a" | grep -c '^port ')" 2
    eh "$a" 'port 22' && eh "$a" 'port 47032' && ok "A old+new port present" || bad "A port set wrong"
    eh "$a" 'passwordauthentication yes' && ok "A auth untouched by port apply" || bad "A auth changed"
    is "A authorized_keys untouched" "$(sha256sum "$a/etc/ssh/authorized_keys" | awk '{print $1}')" "$ak"
    local ah; ah="$(sha256sum "$a/etc/ssh/sshd_config.d/90-ssh-port.conf" | awk '{print $1}')"
    P "$a" 22 apply --port 47032 --mode dual > "$a/o2"
    grep -q 'drop-in unchanged' "$a/o2" && ok "A apply is idempotent" || bad "A second apply rewrote the drop-in"
    is "A drop-in bytes stable" "$(sha256sum "$a/etc/ssh/sshd_config.d/90-ssh-port.conf" | awk '{print $1}')" "$ah"

    # ---- B: final gate -----------------------------------------------------
    local b="$base/b"; fixture "$b"; tok "$b" 47032
    P "$b" 22 apply --port 47032 --mode final > "$b/o1"
    grep -q 'needs --confirmed' "$b/o1" && ok "B final needs --confirmed" || bad "B final ran unconfirmed"
    P "$b" 22 apply --port 47032 --mode final --confirmed > "$b/o2"
    grep -q 'needs --evidence' "$b/o2" && ok "B final needs evidence" || bad "B final ran without evidence"
    [ -f "$b/etc/ssh/sshd_config.d/90-ssh-port.conf" ] && bad "B wrote before the gate" || ok "B nothing written"

    P "$b" 22 apply --port 47032 --mode dual > /dev/null
    tok "$b" 47032
    ev "$b" port-final root yes "" "" 47032 > /dev/null
    sed -i 's/^client_ip=.*/client_ip=127.0.0.1/' "$b/ev-port-final.txt"
    P "$b" 22 apply --port 47032 --mode final --confirmed --evidence "$b/ev-port-final.txt" > "$b/o3"
    grep -q 'which is this host' "$b/o3" && ok "B loopback evidence refused" || bad "B loopback evidence accepted"
    ev "$b" port-final root yes "$(( $(date +%s) - 90000 ))" "" 47032 > /dev/null
    P "$b" 22 apply --port 47032 --mode final --confirmed --evidence "$b/ev-port-final.txt" > "$b/o4"
    grep -q 's old' "$b/o4" && ok "B stale evidence refused" || bad "B stale evidence accepted"
    ev "$b" port-final root yes "" deadbeef 47032 > /dev/null
    P "$b" 22 apply --port 47032 --mode final --confirmed --evidence "$b/ev-port-final.txt" > "$b/o5"
    grep -q 'token does not match' "$b/o5" && ok "B wrong token refused" || bad "B wrong token accepted"
    ev "$b" port-final root yes "" "" 2299 > /dev/null
    P "$b" 22 apply --port 47032 --mode final --confirmed --evidence "$b/ev-port-final.txt" > "$b/o6"
    grep -q 'not 47032' "$b/o6" && ok "B evidence for another port refused" || bad "B wrong-port evidence accepted"
    ev "$b" auth-post root no > /dev/null
    P "$b" 22 apply --port 47032 --mode final --confirmed --evidence "$b/ev-auth-post.txt" > "$b/o7"
    grep -q 'this step needs' "$b/o7" && ok "B evidence purpose enforced" || bad "B wrong-purpose evidence accepted"
    ev "$b" port-final root yes "" "" 47032 > /dev/null
    P "$b" 22 apply --port 47032 --mode final --confirmed --evidence "$b/ev-port-final.txt" > "$b/o8"
    grep -q 'APPLY OK mode=final' "$b/o8" && ok "B final apply" || { bad "B final failed"; tail -4 "$b/o8"; }
    is "B single port after final" "$(E "$b" | awk '$1=="port"' | wc -l)" 1
    eh "$b" 'port 47032' && ok "B kept the target port" || bad "B target port missing"

    # ---- C: guard ---------------------------------------------------------
    local c="$base/c"; fixture "$c"; tok "$c" 47040
    FG=fail P "$c" 22 apply --port 47040 --mode dual --guard 30 > "$c/o1"
    grep -q 'guard could not be armed' "$c/o1" && ok "C unarmed guard refuses the change" || bad "C apply ran without a guard"
    [ -f "$c/etc/ssh/sshd_config.d/90-ssh-port.conf" ] && bad "C wrote despite guard failure" || ok "C nothing written"
    FG=ok P "$c" 22 apply --port 47040 --mode dual --guard 30 > "$c/o2"
    grep -q 'APPLY OK' "$c/o2" && ok "C guarded apply" || bad "C guarded apply failed"
    P "$c" 22 status > "$c/o3"
    grep -q 'PENDING port change' "$c/o3" && ok "C pending survives a new process" || bad "C pending not visible"
    local ctok; ctok="$(sed -n 's/^token=//p' "$c/var/lib/90ssh/pending")"
    P "$c" 22 guard-check --token "$ctok" --kind port --backup "$(sed -n 's/^backup=//p' "$c/var/lib/90ssh/pending")" > "$c/o4"
    grep -q 'ROLLBACK done' "$c/o4" && ok "C guard timeout rolls back" || { bad "C guard rollback failed"; tail -4 "$c/o4"; }
    is "C one port after rollback" "$(E "$c" | awk '$1=="port"' | wc -l)" 1

    # ---- D: pending ---------------------------------------------
    local d="$base/d"; fixture "$d"; tok "$d" 47040
    FG=ok P "$d" 22 apply --port 47040 --mode dual --guard 30 > /dev/null
    P "$d" 22 apply --port 47041 --mode dual > "$d/o1"
    grep -q 'unconfirmed' "$d/o1" && ok "D second apply refused while pending" || bad "D second apply ran"
    P "$d" 22 apply --port 47041 --mode dual --force-pending > "$d/o2"
    grep -q 'APPLY OK' "$d/o2" && ok "D --force-pending overrides" || bad "D --force-pending failed"
    local dtok; dtok="$(sed -n 's/^token=//p' "$d/var/lib/90ssh/pending")"
    P "$d" 22 confirm --token "$dtok" > "$d/o3"
    grep -q 'confirmed' "$d/o3" && ok "D confirm" || bad "D confirm failed"
    P "$d" 22 confirm --token "$dtok" > "$d/o4"
    grep -q 'no pending' "$d/o4" && ok "D second confirm refused" || bad "D second confirm accepted"

    # ---- E: configuration shape -------------------------------------------
    local e="$base/e"; fixture "$e"; tok "$e" 47040
    printf '# Managed by box/90ssh.sh v2.0.0 -- do not edit by hand.\nPort 47032\n' > "$e/etc/ssh/sshd_config.d/10-homelab-ssh.conf"
    P "$e" 47032 apply --port 47032 --mode dual > "$e/o1"
    [ -f "$e/etc/ssh/sshd_config.d/90-ssh-port.conf" ] && bad "E created a second drop-in" || ok "E reuses the v2.0 drop-in"
    local f="$base/f"; fixture "$f"; tok "$f" 47040
    printf 'Port 2222\n' > "$f/etc/ssh/sshd_config.d/50-custom.conf"
    P "$f" 22 apply --port 47040 --mode dual > "$f/o1"
    grep -q 'rerun with --take-over' "$f/o1" && ok "E foreign Port needs --take-over" || bad "E foreign Port ignored"
    P "$f" 22 apply --port 47040 --mode dual --take-over > "$f/o2"
    grep -q 'APPLY OK' "$f/o2" && grep -q '#90ssh-disabled' "$f/etc/ssh/sshd_config.d/50-custom.conf" \
        && ok "E --take-over comments the foreign line" || bad "E --take-over failed"
    local g="$base/g"; fixture "$g"; tok "$g" 47040
    sed -i '/^Include/d' "$g/etc/ssh/sshd_config"
    P "$g" 22 apply --port 47040 --mode dual > "$g/o1"
    grep -q 'Include' "$g/etc/ssh/sshd_config" && ok "E missing Include appended" || bad "E Include not added"
    local h="$base/h"; fixture "$h"; tok "$h" 47040
    printf 'Match User nobody\n    PasswordAuthentication yes\n' >> "$h/etc/ssh/sshd_config"
    sed -i '/^Include/d' "$h/etc/ssh/sshd_config"
    printf 'Include %s/etc/ssh/sshd_config.d/*.conf\n' "$h" >> "$h/etc/ssh/sshd_config"
    P "$h" 22 apply --port 47040 --mode dual > "$h/o1"
    grep -q 'after a Match block' "$h/o1" && ok "E Include inside Match refused" || bad "E Match-scoped include accepted"

    # ---- F: bootstrap-key -------------------------------------------------
    local k="$base/k"; fixture "$k"; mkdir -p "$k/home"
    ssh-keygen -q -t ed25519 -N '' -f "$k/key1" >/dev/null 2>&1
    ssh-keygen -y -f "$k/key1" > "$k/key1.pub"
    P "$k" 22 bootstrap-key --user tester --pubkey "$k/key1.pub" > "$k/o1"
    is "F .ssh mode" "$(stat -c %a "$k/home/.ssh")" 700
    is "F authorized_keys mode" "$(stat -c %a "$k/home/.ssh/authorized_keys")" 600
    grep -q "$(cut -d' ' -f1-2 "$k/key1.pub")" "$k/home/.ssh/authorized_keys" && ok "F key installed" || bad "F key missing"
    grep -q 'ADDED SHA256:' "$k/o1" && ok "F fingerprint printed" || bad "F no fingerprint"
    local kh; kh="$(sha256sum "$k/home/.ssh/authorized_keys" | awk '{print $1}')"
    P "$k" 22 bootstrap-key --user tester --pubkey "$k/key1.pub" > "$k/o2"
    grep -q 'nothing to do' "$k/o2" && ok "F second run is a no-op" || bad "F second run did not report no-op"
    is "F bytes unchanged" "$(sha256sum "$k/home/.ssh/authorized_keys" | awk '{print $1}')" "$kh"
    printf 'from="10.0.0.0/8",no-pty %s old@comment\n' "$(cat "$k/key1.pub")" >> "$k/home/.ssh/authorized_keys"
    ssh-keygen -q -t ed25519 -N '' -f "$k/key2" >/dev/null 2>&1
    ssh-keygen -y -f "$k/key2" > "$k/key2.pub"
    cat "$k/key2.pub" "$k/key2.pub" > "$k/dup.pub"
    P "$k" 22 bootstrap-key --user tester --pubkey "$k/dup.pub" > "$k/o3"
    is "F duplicate in input added once" "$(grep -c "$(cut -d' ' -f2 "$k/key2.pub")" "$k/home/.ssh/authorized_keys")" 1
    grep -q 'no-pty' "$k/home/.ssh/authorized_keys" && ok "F existing options preserved" || bad "F options line lost"
    local kh2; kh2="$(sha256sum "$k/home/.ssh/authorized_keys" | awk '{print $1}')"
    printf 'definitely not a key\n' > "$k/bad.pub"
    P "$k" 22 bootstrap-key --user tester --pubkey "$k/bad.pub" > "$k/o4"
    grep -q 'not a usable' "$k/o4" && ok "F garbage refused" || bad "F garbage accepted"
    is "F refused write changed nothing" "$(sha256sum "$k/home/.ssh/authorized_keys" | awk '{print $1}')" "$kh2"
    P "$k" 22 bootstrap-key --user tester --pubkey "$k/key1" > "$k/o5"
    grep -q 'private key' "$k/o5" && ok "F private key refused" || bad "F private key accepted"
    mv "$k/home/.ssh/authorized_keys" "$k/home/.ssh/real"
    ln -s "$k/home/.ssh/real" "$k/home/.ssh/authorized_keys"
    P "$k" 22 bootstrap-key --user tester --pubkey "$k/key2.pub" > "$k/o6"
    grep -q 'symlink' "$k/o6" && ok "F symlinked file refused" || bad "F wrote through a symlink"
    rm -f "$k/home/.ssh/authorized_keys"; mv "$k/home/.ssh/real" "$k/home/.ssh/authorized_keys"
    sh "$(ls -1d "$k"/root/90ssh-key-backup-* | head -1)/RESTORE.sh"
    [ -f "$k/home/.ssh/authorized_keys" ] && bad "F RESTORE.sh did not remove a file that did not exist" || ok "F RESTORE.sh restores the absent state"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY test@fixture\n' > "$k/home/.ssh/authorized_keys"
    chmod 600 "$k/home/.ssh/authorized_keys"
    local kref; kref="$(sha256sum "$k/home/.ssh/authorized_keys" | awk '{print $1}')"
    P "$k" 22 bootstrap-key --user tester --pubkey "$k/key2.pub" > /dev/null
    sh "$(ls -1d "$k"/root/90ssh-key-backup-* | tail -1)/RESTORE.sh"
    is "F RESTORE.sh restores the previous bytes" "$(sha256sum "$k/home/.ssh/authorized_keys" | awk '{print $1}')" "$kref"

    # ---- G: key-only ------------------------------------------------------
    local m="$base/m"; fixture "$m" ""
    printf 'PasswordAuthentication yes\n' > "$m/etc/ssh/sshd_config.d/50-cloud-init.conf"
    P "$m" 22 auth plan --mode key-only > "$m/o1"
    grep -q 'verdict : OK' "$m/o1" && ok "G plan OK with cloud-init drop-in" || { bad "G plan refused"; tail -4 "$m/o1"; }
    printf 'PasswordAuthentication yes\n' > "$m/etc/ssh/sshd_config.d/0-early.conf"
    P "$m" 22 auth plan --mode key-only > "$m/o2"
    grep -q 'verdict : REFUSED' "$m/o2" && ok "G plan refuses when an earlier file wins" || bad "G plan accepted a losing drop-in"
    rm -f "$m/etc/ssh/sshd_config.d/0-early.conf"
    printf 'Match User root\n    PasswordAuthentication yes\n' >> "$m/etc/ssh/sshd_config"
    P "$m" 22 auth plan --mode key-only > "$m/o3"
    grep -q 'risk' "$m/o3" && ok "G plan flags a Match block" || bad "G plan missed the Match block"
    P "$m" 22 auth apply --mode key-only --console-ok > "$m/o4"
    grep -q 'evidence from a real publickey login' "$m/o4" && ok "G apply needs evidence" || bad "G apply ran without evidence"
    [ -f "$m/etc/ssh/sshd_config.d/00-90ssh-auth.conf" ] && bad "G wrote without evidence" || ok "G nothing written yet"

    local n="$base/n"; fixture "$n"; tok "$n" 22 auth-key-only
    ev "$n" auth-key-only root yes > /dev/null
    P "$n" 22 auth apply --mode key-only --evidence "$n/ev-auth-key-only.txt" > "$n/o1"
    grep -q 'console-ok' "$n/o1" && ok "G apply needs --console-ok" || bad "G console gate missing"
    ev "$n" auth-key-only bob yes > /dev/null
    P "$n" 22 auth apply --mode key-only --evidence "$n/ev-auth-key-only.txt" --console-ok > "$n/o2"
    grep -q "not 'root'" "$n/o2" && ok "G evidence for another user refused" || bad "G wrong-user evidence accepted"
    ev "$n" auth-key-only root yes > /dev/null
    local nak; nak="$(sha256sum "$n/etc/ssh/authorized_keys" | awk '{print $1}')"
    FG=ok P "$n" 22 auth apply --mode key-only --evidence "$n/ev-auth-key-only.txt" --console-ok --guard 30 > "$n/o3"
    grep -q 'AUTH APPLY OK' "$n/o3" && ok "G auth apply" || { bad "G auth apply failed"; tail -5 "$n/o3"; }
    is "G host password auth off" "$(E "$n" | awk '$1=="passwordauthentication"{print $2}')" no
    is "G host kbd-interactive off" "$(E "$n" | awk '$1=="kbdinteractiveauthentication"{print $2}')" no
    is "G authorized_keys untouched" "$(sha256sum "$n/etc/ssh/authorized_keys" | awk '{print $1}')" "$nak"
    is "G port unchanged" "$(E "$n" | awk '$1=="port"{print $2}')" 22
    [ -f "$n/var/lib/90ssh/auth-pending" ] && ok "G auth pending recorded" || bad "G no auth pending"
    local ntok; ntok="$(sed -n 's/^token=//p' "$n/var/lib/90ssh/auth-pending")"
    ev "$n" auth-post root yes > /dev/null
    P "$n" 22 auth confirm --token "$ntok" --evidence "$n/ev-auth-post.txt" > "$n/o4"
    grep -q 'still offered' "$n/o4" && ok "G confirm refuses while passwords are offered" || bad "G confirm ignored the probe"
    ev "$n" auth-post root no "$(( $(date +%s) - 600 ))" > /dev/null
    P "$n" 22 auth confirm --token "$ntok" --evidence "$n/ev-auth-post.txt" > "$n/o5"
    grep -q 'predates the change' "$n/o5" && ok "G confirm refuses an older record" || bad "G confirm took a stale record"
    ev "$n" auth-post root no > /dev/null
    P "$n" 22 auth confirm --token "$ntok" --evidence "$n/ev-auth-post.txt" > "$n/o6"
    grep -q 'AUTH CONFIRMED' "$n/o6" && ok "G confirm" || { bad "G confirm failed"; tail -4 "$n/o6"; }
    [ -f "$n/var/lib/90ssh/auth-pending" ] && bad "G pending survived confirm" || ok "G pending cleared"
    P "$n" 22 auth rollback > "$n/o7"
    is "G rollback restores password auth" "$(E "$n" | awk '$1=="passwordauthentication"{print $2}')" yes
    [ -f "$n/etc/ssh/sshd_config.d/00-90ssh-auth.conf" ] && bad "G drop-in survived rollback" || ok "G drop-in removed"

    # ---- H: port and auth stay independent --------------------------------
    local q="$base/q"; fixture "$q"; tok "$q" 47040
    P "$q" 22 apply --port 47040 --mode dual > /dev/null
    tok "$q" 22 auth-key-only
    ev "$q" auth-key-only root yes > /dev/null
    P "$q" 22 auth apply --mode key-only --evidence "$q/ev-auth-key-only.txt" --console-ok > "$q/o1"
    grep -q 'AUTH APPLY OK' "$q/o1" && ok "H auth apply after a port transition" || { bad "H auth apply blocked"; tail -4 "$q/o1"; }
    grep -q 'Port 47040' "$q/etc/ssh/sshd_config.d/90-ssh-port.conf" && ok "H port drop-in intact" || bad "H port drop-in damaged"
    P "$q" 22 apply --port 47041 --mode dual --force-pending > "$q/o2"
    grep -q 'auth change is pending' "$q/o2" && ok "H port apply blocked by auth pending" || bad "H port apply ran during auth pending"
    P "$q" 22 auth rollback > /dev/null
    grep -q 'Port 47040' "$q/etc/ssh/sshd_config.d/90-ssh-port.conf" && ok "H auth rollback leaves the port drop-in" || bad "H auth rollback touched the port"
    local r="$base/r"; fixture "$r"; tok "$r" 47042
    P "$r" 22 apply --port 47042 --mode dual > /dev/null
    tok "$r" 22 auth-key-only
    ev "$r" auth-key-only root yes > /dev/null
    P "$r" 22 auth apply --mode key-only --evidence "$r/ev-auth-key-only.txt" --console-ok > /dev/null
    local rtok; rtok="$(sed -n 's/^token=//p' "$r/var/lib/90ssh/auth-pending")"
    ev "$r" auth-post root no > /dev/null
    P "$r" 22 auth confirm --token "$rtok" --evidence "$r/ev-auth-post.txt" > /dev/null
    P "$r" 22 rollback --backup "$(ls -1d "$r"/root/90ssh-backup-* | tail -1)" > "$r/o1"
    [ -f "$r/etc/ssh/sshd_config.d/00-90ssh-auth.conf" ] && ok "H port rollback keeps the auth drop-in" || bad "H port rollback removed auth"
    is "H auth policy survives a port rollback" "$(E "$r" | awk '$1=="passwordauthentication"{print $2}')" no

    # ---- I: entry points ---------------------------------------------------
    local s="$base/s"; fixture "$s"
    bash "$0" </dev/null > "$s/o1" 2>&1
    grep -q '90ssh.sh status' "$s/o1" && grep -q 'bootstrap-key' "$s/o1" && ok "I non-tty prints usage" || bad "I usage output wrong"
    P "$s" 22 verify --issue-token --port 47040 --purpose port-final > "$s/o2"
    grep -q 'VERIFY TOKEN:' "$s/o2" && is "I token mode" "$(stat -c %a "$s/run/90ssh/verify.token")" 600
    P "$s" 22 auth > "$s/o3"
    grep -q 'subcommand required' "$s/o3" && ok "I auth without subcommand is refused" || bad "I auth without subcommand ran"
    printf '1\n0\n' | PREFIX="$s" FAKE_HOME="$s/home" bash "$0" menu > "$s/o4" 2>&1
    grep -q 'effective ports' "$s/o4" && grep -q 'bye' "$s/o4" && ok "I menu status and exit" || bad "I menu failed"
    printf '9\n0\n' | PREFIX="$s" FAKE_HOME="$s/home" bash "$0" menu > "$s/o5" 2>&1
    grep -q 'auth preserve' "$s/o5" && ok "I menu auth status" || bad "I menu auth status failed"
    P "$s" 22 apply --port > "$s/o6"
    grep -q 'needs a value' "$s/o6" && ok "I missing option value refused" || bad "I option parsing accepted a dangling flag"

    log "== self-test $([ $rc = 0 ] && echo PASS || echo FAIL) =="
    [ "$rc" = 0 ] && rm -rf "$base" || log "  (kept: $base)"
    return $rc
}

usage() { sed -n '/^# Supported:/,/^# Isolated testing/p' "$0" | sed 's/^# \{0,1\}//'; }

# -------------------------------------------------------------------- main --
if [ $# -gt 0 ]; then CMD="$1"; shift || true
elif [ -t 0 ]; then CMD=menu
else usage; exit 0; fi

case "$CMD" in -h|--help|help) usage; exit 0;; esac

case "$CMD" in
    auth)
        ACMD="${1:-}"; shift || true
        case "$ACMD" in
            status|plan|apply|confirm|rollback) ;;
            *) die "auth: subcommand required: status|plan|apply|confirm|rollback" ;;
        esac ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --port|--mode|--guard|--host|--key|--user|--known-hosts|--token|--backup|--reason|\
        --keep-port|--listen|--evidence|--max-evidence-age|--pubkey|--purpose|--kind)
            [ $# -ge 2 ] || die "option $1 needs a value" ;;
    esac
    case "$1" in
        --port) PORT="${2:-}"; shift 2;;
        --mode) MODE="${2:-}"; shift 2;;
        --guard) GUARD="${2:-0}"; shift 2;;
        --keep-port) KEEP="$KEEP ${2:-}"; shift 2;;
        --listen) LISTEN="${2:-}"; shift 2;;
        --take-over) TAKEOVER=1; shift;;
        --confirmed) CONFIRMED=1; shift;;
        --evidence) EVIDENCE="${2:-}"; shift 2;;
        --host) GHOST="${2:-}"; shift 2;;
        --key) GKEY="${2:-}"; shift 2;;
        --user) GUSER="${2:-root}"; AUSER="${2:-root}"; shift 2;;
        --known-hosts) GKNOWN="${2:-}"; shift 2;;
        --token) TOKEN="${2:-}"; shift 2;;
        --issue-token) ISSUE=1; shift;;
        --purpose) PURPOSE="${2:-}"; shift 2;;
        --probe) PROBE=1; shift;;
        --pubkey) PUBKEY="${2:-}"; shift 2;;
        --console-ok) CONSOLE_OK=1; shift;;
        --backup) BACKUP="${2:-}"; shift 2;;
        --reason) REASON="${2:-manual}"; shift 2;;
        --kind) GKIND="${2:-}"; shift 2;;
        --allow-private-verifier) ALLOW_PRIVATE=1; shift;;
        --max-evidence-age) MAXAGE="${2:-86400}"; shift 2;;
        --force-pending) FORCE=1; shift;;
        --dry-run) DRY=1; shift;;
        -h|--help) usage; exit 0;;
        *) die "unknown option: $1";;
    esac
done

[ "$MODE" = key-only ] && MODE=key-only
[ "$CMD" = test ] || { svc_resolve; dropin_resolve; }

case "$CMD" in
    status)  do_status;;
    plan)    do_plan;;
    apply)   do_apply;;
    verify)  do_verify;;
    confirm) do_confirm;;
    rollback) restore port "${BACKUP:-$(latest_backup)}" "$REASON";;
    guard-check) do_guard_check;;
    bootstrap-key) do_bootstrap_key;;
    auth)
        case "$ACMD" in
            status)   do_auth_status;;
            plan)     do_auth_plan;;
            apply)    do_auth_apply;;
            confirm)  do_auth_confirm;;
            rollback) do_auth_rollback;;
        esac;;
    menu) do_menu;;
    test) do_selftest;;
    *) usage; die "unknown command: $CMD";;
esac
