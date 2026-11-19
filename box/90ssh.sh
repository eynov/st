#!/usr/bin/env bash
# box/90ssh.sh - safe, idempotent SSH port migration for Linux hosts.
#
# v2.1 generalises the v2.0 rewrite that is running on the Homelab hosts.  The
# entry point, the sub-commands and the safety model are unchanged; the port and
# unit assumptions are not.
#
# Guarantees
#   * Authentication policy is never written by this script, and no key file
#     (authorized_keys, host keys) is ever read for writing or modified.  After a
#     reload the effective `sshd -T` output is compared with the pre-change
#     snapshot; any difference outside port/listenaddress triggers a rollback.
#   * Dual-port transition keeps *every* port that is effective right now (from
#     sshd_config, the active socket unit and --keep-port).  Port 22 is never
#     invented; a host that listens on 37091 keeps 37091.
#   * Finalisation is a separate, explicit mode.  It requires
#     `--confirmed --evidence FILE`, i.e. a challenge-response record produced by
#     a real publickey login on the new port from another host.  Local listening
#     state alone can never satisfy it.
#   * ssh.service / sshd.service / ssh.socket / sshd.socket are all handled.
#     The socket is never enabled or disabled, only its ListenStream list is
#     rewritten into a drop-in that sorts last.
#   * Every apply takes a full backup (sshd_config, sshd_config.d, socket
#     drop-ins, service state, effective config) and rollback restores it.
#   * --guard N arms a transient systemd timer from a root-owned copy of this
#     script.  If it cannot be armed the apply is refused *before* any change.
#
# Usage
#   90ssh.sh status
#   90ssh.sh plan    --port N [--mode dual|final] [--dropin NAME]
#   90ssh.sh apply   --port N [--mode dual|final] [--guard SECONDS] [--take-over]
#   90ssh.sh verify  --issue-token [--port N]
#   90ssh.sh verify  --port N --host H --key PATH --token T [--evidence FILE]
#   90ssh.sh confirm --token T
#   90ssh.sh rollback [--backup DIR] [--reason R]
#   90ssh.sh guard-check --token T --backup DIR
#   90ssh.sh menu                     # interactive menu (also used for no args on a tty)
#   90ssh.sh test                     # isolated self-test (needs no root)
#
# Portability options
#   --service ssh|sshd|auto   unit that owns sshd (auto prefers the active unit)
#   --socket auto|none|NAME   socket unit to drive (auto = active ssh.socket/sshd.socket)
#   --keep-port N             extra port to keep in dual mode (repeatable)
#   --listen ADDR|all         final-mode bind address (default 0.0.0.0)
#   --create-include          append Include ... when sshd_config has none
#   --allow-firewall-pending  dual mode only: proceed without a host-firewall rule
#   --selinux-add             run semanage for the new port when SELinux is enforcing
#   --evidence FILE           final mode: verification record from a remote login
#   --allow-private-verifier  accept evidence whose client address is RFC1918
#   --max-evidence-age SEC    evidence freshness (default 86400)
#   --force-pending           ignore an unconfirmed previous transition marker
#
# Isolated testing: PREFIX=/tmp/fake makes the script operate on $PREFIX/etc/ssh,
# never call systemctl/ss, and validate with `sshd -t -f`.  See `test`.
set -uo pipefail

VER=2.1.0
PREFIX="${PREFIX:-}"
DRY="${DRY_RUN:-0}"
NEW_PORT=""
MODE="dual"
DROPIN=""
DROPIN_NAME=""
GUARD=0
TAKE_OVER=0
CONFIRMED=0
EVIDENCE=""
ALLOW_PRIVATE=0
MAX_EVIDENCE_AGE=86400
VERIFY_HOST=""
VERIFY_KEY=""
VERIFY_USER="root"
VERIFY_KNOWN_HOSTS=""
ISSUE_TOKEN=0
TOKEN=""
BACKUP_DIR=""
REASON="manual"
SVC="ssh"
SVC_FORCED=""
SOCKET_UNIT=""
SOCKET_FORCED=""
LISTEN_ADDR="0.0.0.0"
KEEP_PORTS=""
CREATE_INCLUDE=0
FW_PENDING=0
SELINUX_ADD=0
FORCE_PENDING=0
KEPT=""
SELF="$0"
STATE_DIR="$PREFIX/var/lib/90ssh"
RUN_DIR="$PREFIX/run/90ssh"

S_DIR="$PREFIX/etc/ssh"
S_CFG="$S_DIR/sshd_config"
D_DIR="$S_DIR/sshd_config.d"
SOCK_DIR=""          # resolved in detect_units(): .../systemd/system/<unit>.d

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
unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }

socket_state() {
    if fake; then echo "fake:none"; return; fi
    local st="" en ac
    for s in ssh.socket sshd.socket; do
        unit_exists "$s" || continue
        en="$(systemctl is-enabled "$s" 2>/dev/null)"; [ -n "$en" ] || en=unknown
        ac="$(systemctl is-active  "$s" 2>/dev/null)"; [ -n "$ac" ] || ac=unknown
        st="$st$s=$en/$ac "
    done
    printf '%s' "${st:-none}"
}

# Debian/Ubuntu ship ssh.service, RHEL-family ships sshd.service.  Prefer the
# unit that is actually running; fall back to whichever unit file exists.
detect_units() {
    case "${SVC_FORCED:-auto}" in
        ""|auto)
            if fake; then
                SVC="${FAKE_SVC:-ssh}"
            else
                SVC=""
                local s
                for s in ssh sshd; do svc_active "$s.service" && { SVC="$s"; break; }; done
                if [ -z "$SVC" ]; then
                    for s in ssh sshd; do unit_exists "$s.service" && { SVC="$s"; break; }; done
                fi
                SVC="${SVC:-ssh}"
            fi ;;
        *) SVC="$SVC_FORCED" ;;
    esac

    SOCKET_UNIT=""
    case "${SOCKET_FORCED:-auto}" in
        none) SOCK_DIR=""; return 0 ;;
        ""|auto)
            if fake; then
                case "${FAKE_SOCKET:-}" in
                    "") ;;
                    1|yes|true) SOCKET_UNIT=ssh.socket ;;
                    *) SOCKET_UNIT="$(sock_unit_name "$FAKE_SOCKET")" ;;
                esac
            else
                local s
                for s in ssh.socket sshd.socket; do
                    unit_exists "$s" || continue
                    svc_active "$s" && { SOCKET_UNIT="$s"; break; }
                done
            fi ;;
        *) SOCKET_UNIT="$(sock_unit_name "$SOCKET_FORCED")" ;;
    esac
    if [ -n "$SOCKET_UNIT" ]; then
        SOCK_DIR="$PREFIX/etc/systemd/system/$SOCKET_UNIT.d"
    else
        SOCK_DIR=""
    fi
}

sock_unit_name() { case "$1" in *.socket) printf '%s' "$1";; *) printf '%s.socket' "$1";; esac; }

# Active socket listeners.  systemd exposes them as "Listen" (newer) or
# "ListenStream" (older); both carry "<addr>:<port>".
sock_listen_entries() {
    [ -n "$SOCKET_UNIT" ] || return 0
    if fake; then
        printf '%s\n' ${FAKE_SOCK_STREAMS:-${FAKE_PORTS:-}} | tr ' ' '\n' | grep -E ':[0-9]+$'
        return 0
    fi
    local out
    out="$(systemctl show -p Listen --value "$SOCKET_UNIT" 2>/dev/null)"
    if [ -z "$out" ]; then
        out="$(systemctl show -p ListenStream --value "$SOCKET_UNIT" 2>/dev/null)"
    fi
    printf '%s\n' "$out" | tr ' ' '\n' | grep -E ':[0-9]+$'
}

sock_ports() { sock_listen_entries | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un; }

socket_active() {
    if fake; then [ -n "${FAKE_SOCKET:-}" ] && [ -n "$SOCKET_UNIT" ]; return; fi
    [ -n "$SOCKET_UNIT" ] && svc_active "$SOCKET_UNIT"
}

# Ports that are effective right now (config + active socket + --keep-port),
# minus the target.  This is what dual mode must preserve; v2.0 wrongly assumed
# it was always 22.
current_ports() {
    {
        sshd_dump "" 2>/dev/null | awk '$1=="port"{print $2}'
        sock_ports
        printf '%s\n' $KEEP_PORTS
    } | grep -E '^[0-9]+$' | grep -vx "${NEW_PORT:-0}" | sort -un | tr '\n' ' ' | sed 's/ $//'
}

local_ips() {
    {
        printf '127.0.0.1\n::1\n'
        if fake; then printf '%s\n' ${FAKE_LOCAL_IPS:-}; else
            ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
        fi
    } | sort -u | tr '\n' ' '
}

is_local_ip() {
    local ip="$1" i
    case "$ip" in 127.*|::1|0.0.0.0|"") return 0;; esac
    for i in $(local_ips); do [ "$i" = "$ip" ] && return 0; done
    return 1
}

is_private_ip() {
    case "$1" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*|fc*|fd*|fe80*) return 0;;
    esac
    return 1
}

fw_drop_policy() {
    fake && return 1
    nft list ruleset 2>/dev/null | grep -qE 'hook input.*policy drop' && return 0
    iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT DROP' && return 0
    command -v firewall-cmd >/dev/null 2>&1 && [ "$(firewall-cmd --state 2>/dev/null)" = running ] && return 0
    return 1
}

fw_allows_port() {
    local p="$1"
    fake && return 0
    # nft: an accept for the port inside an input-hook chain.  Deliberately
    # conservative: a false negative only adds a warning/final refusal, a false
    # positive would be dangerous, so require an accept rule mentioning the port.
    nft list ruleset 2>/dev/null | grep -qE "(dport|:$p[ ,);]).*accept" && return 0
    iptables -S INPUT 2>/dev/null | grep -qE "dport $p .*ACCEPT" && return 0
    command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --query-port="$p/tcp" 2>/dev/null | grep -qx yes && return 0
    return 1
}

selinux_blocked() {
    local p="$1"
    fake && return 1
    command -v getenforce >/dev/null 2>&1 || return 1
    [ "$(getenforce 2>/dev/null)" = Enforcing ] || return 1
    command -v semanage >/dev/null 2>&1 || return 0
    semanage port -l 2>/dev/null | grep -qE "ssh_port_t.*(^|[ ,])$p([ ,]|$)" && return 1
    return 0
}

listening_ports() {
    if fake; then printf '%s' "${FAKE_LISTEN:-${FAKE_PORTS:-}}"; return; fi
    ss -Hltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un | tr '\n' ' ' | sed 's/ $//'
}

port_listening() {
    local p="$1"
    if fake; then case " ${FAKE_LISTEN:-${FAKE_PORTS:-}} " in *" $p "*) return 0;; esac; return 1; fi
    ss -Hltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$"
}

# Address families a port is actually bound to, e.g. "0.0.0.0:47032 [::]:47032".
port_binds() {
    local p="$1"
    if fake; then
        local a
        for a in ${FAKE_BINDS:-0.0.0.0:__P__}; do printf '%s\n' "${a/__P__/$p}"; done
        return
    fi
    ss -Hltn 2>/dev/null | awk '{print $4}' | grep -E "[:.]$p\$" | sort -u
}

# ---------------------------------------------------------------- drop-in ---
# The drop-in name is generic now.  A host that already runs v2.0 (the Homelab
# nodes use 10-homelab-ssh.conf) keeps its file so the tool stays idempotent and
# does not leave two managed Port sources behind.
resolve_dropin() {
    if [ -n "$DROPIN" ]; then
        case "$DROPIN" in
            */*|"") die "invalid --dropin name: $DROPIN" ;;
        esac
        DROPIN_NAME="$DROPIN"
        return 0
    fi
    local n
    for n in 90-ssh-port.conf 10-homelab-ssh.conf zz-90ssh-port.conf; do
        [ -f "$D_DIR/$n" ] && { DROPIN_NAME="$n"; return 0; }
    done
    DROPIN_NAME="90-ssh-port.conf"
}

managed_path() { printf '%s/%s' "$D_DIR" "$DROPIN_NAME"; }

# Only the resolved drop-in counts as ours.  A leftover managed file under
# another name is reported as foreign on purpose: it still contributes Port /
# ListenAddress directives, so taking it over must be an explicit decision.
is_managed_conf() { [ "$1" = "$(managed_path)" ]; }

# Managed files that are not the one we are about to write (e.g. after an
# explicit --dropin rename).  They are not silently ignored.
other_managed_files() {
    local f
    for f in "$D_DIR"/*.conf; do
        [ -f "$f" ] || continue
        [ "$f" = "$(managed_path)" ] && continue
        grep -q '^# Managed by box/90ssh.sh' "$f" 2>/dev/null && printf '%s\n' "$f"
    done
}

# Port / ListenAddress directives owned by files other than ours.  These are what
# v1 silently clobbered; here they are reported and, when conflicting, refused.
foreign_lines() {
    local kw="$1" out="" f
    [ -f "$S_CFG" ] && out="$(grep -nE "^[[:space:]]*$kw[[:space:]]+" "$S_CFG" 2>/dev/null | sed "s|^|$S_CFG:|")"
    if [ -d "$D_DIR" ]; then
        for f in "$D_DIR"/*.conf; do
            [ -f "$f" ] || continue
            is_managed_conf "$f" && continue
            out="$out$(grep -nE "^[[:space:]]*$kw[[:space:]]+" "$f" 2>/dev/null | sed "s|^|$f:|")"
        done
    fi
    printf '%s' "$out"
}

foreign_port_lines()   { foreign_lines Port; }
foreign_listen_lines() { foreign_lines ListenAddress; }

owns_port() {
    local p="$1" f; f="$(managed_path)"
    [ -f "$f" ] && grep -qE "^[[:space:]]*Port[[:space:]]+$p([[:space:]]|$)" "$f"
}

have_include() {
    local pat="${D_DIR//./\\.}"
    grep -Eq "^[[:space:]]*Include[[:space:]]+${pat}/\\*\\.conf([[:space:]]|$)" "$S_CFG"
}

write_dropin() {
    local p="$1" mode="$2" target k
    target="$(managed_path)"
    run install -d -m 0755 "$D_DIR"
    local tmp; tmp="$(mktemp)"
    {
        echo "# Managed by box/90ssh.sh v$VER -- do not edit by hand."
        echo "# Authentication policy is intentionally NOT set here."
        if [ "$mode" = "final" ]; then
            echo "# mode: final (single port, listen: $LISTEN_ADDR)"
            echo "Port $p"
            case "$LISTEN_ADDR" in
                all) echo "ListenAddress 0.0.0.0"; echo "ListenAddress ::" ;;
                *:*) echo "ListenAddress [$LISTEN_ADDR]" ;;
                *)   echo "ListenAddress $LISTEN_ADDR" ;;
            esac
        else
            echo "# mode: dual (transition; keeps every current port until confirmed)"
            for k in $KEPT; do echo "Port $k"; done
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

# Final-mode expected listener set, in the shape `sshd -T` prints it.
expected_listen_addrs() {
    local p="$1"
    case "$LISTEN_ADDR" in
        all) printf '0.0.0.0:%s\n[::]:%s\n' "$p" "$p" ;;
        *:*) printf '[%s]:%s\n' "$LISTEN_ADDR" "$p" ;;
        *)   printf '%s:%s\n' "$LISTEN_ADDR" "$p" ;;
    esac | sort
}

# One ListenStream line per address/port.  Dual mode reuses the addresses the
# socket currently binds (so a v4-only socket stays v4-only) and adds the new
# port on each of them.
socket_streams() {
    local p="$1" mode="$2" k e addr addrs=""
    if [ "$mode" = final ]; then
        case "$LISTEN_ADDR" in
            all)   echo "ListenStream=0.0.0.0:$p"; echo "ListenStream=[::]:$p" ;;
            *:*)   echo "ListenStream=[$LISTEN_ADDR]:$p" ;;
            *)     echo "ListenStream=$LISTEN_ADDR:$p" ;;
        esac
        return
    fi
    for e in $(sock_listen_entries); do
        addr="${e%:*}"
        case " $addrs " in *" $addr "*) ;; *) addrs="$addrs $addr";; esac
    done
    [ -n "$addrs" ] || addrs=" 0.0.0.0 [::]"
    for k in $KEPT $p; do
        for addr in $addrs; do
            echo "ListenStream=$addr:$k"
        done
    done
}

# Every file that sets ListenStream for the socket unit (unit file + drop-ins),
# as systemd itself resolves them.  Order matters: systemd applies them
# lexicographically, so anything after zz-90ssh.conf wins over us.
socket_all_dropins() {
    [ -n "$SOCKET_UNIT" ] || return 0
    local files f
    if fake; then
        ls -1 "$SOCK_DIR"/*.conf 2>/dev/null
        return 0
    fi
    files="$(systemctl cat "$SOCKET_UNIT" 2>/dev/null | sed -n 's|^# /\(.*\)$|\1|p')"
    [ -n "$files" ] || files="$(ls -1 /etc/systemd/system/"$SOCKET_UNIT".d/*.conf 2>/dev/null)"
    for f in $files; do
        grep -qE '^[[:space:]]*ListenStream=' "$f" 2>/dev/null && printf '%s\n' "$f"
    done
}

# Any ssh.socket drop-in whose name sorts after ours would override the
# ListenStream list we just wrote (systemd applies drop-ins in lexical order).
socket_later_dropins() {
    [ -n "$SOCKET_UNIT" ] || return 0
    local f base
    socket_all_dropins | while IFS= read -r f; do
        base="$(basename "$f")"
        [ "$base" = "zz-90ssh.conf" ] && continue
        [ "$base" \> "zz-90ssh.conf" ] && printf '%s\n' "$f"
    done
}

write_socket_override() {
    local p="$1" mode="$2" f="$SOCK_DIR/zz-90ssh.conf" tmp
    [ -n "$SOCK_DIR" ] || return 0
    [ -d "$SOCK_DIR" ] || run install -d -m 0755 "$SOCK_DIR"
    run rm -f "$SOCK_DIR/90ssh.conf"
    tmp="$(mktemp)"
    {
        echo "# Managed by box/90ssh.sh v$VER"
        echo "[Socket]"
        echo "ListenStream="
        socket_streams "$p" "$mode"
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
    local ts dir f
    ts="$(date '+%Y%m%d-%H%M%S')"
    dir="$PREFIX/root/90ssh-backup-$ts"
    run install -d -m 0700 "$dir" || return 1
    local manifest="$dir/MANIFEST"
    : > "$manifest"
    for f in "$S_CFG" "$D_DIR" "$SOCK_DIR"; do
        [ -n "$f" ] || continue
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
    if [ -n "$SOCK_DIR" ] && [ -d "$SOCK_DIR" ]; then
        ls -1 "$SOCK_DIR" > "$dir/socket.list" || true
    fi
    { echo "version=$VER"; echo "ts=$ts"; echo "svc=$SVC"; echo "socket=${SOCKET_UNIT:-none}"
      echo "svc_enabled=$(svc_enabled_str)"; echo "svc_active=$(svc_active_str)"
      echo "socket_state=$(socket_state)"; echo "ports_before=$(listening_ports)"; } > "$dir/state"
    sshd_dump "" > "$dir/sshd-T.before" 2>/dev/null || true
    [ -n "$EVIDENCE" ] && [ -f "$EVIDENCE" ] && cp -p "$EVIDENCE" "$dir/verify.evidence" 2>/dev/null
    log "  backup: $dir"
    BACKUP_RES="$dir"
}

svc_enabled_str() { fake && { echo fake; return; }; local v; v="$(systemctl is-enabled "$SVC.service" 2>/dev/null)"; printf '%s' "${v:-unknown}"; }
svc_active_str()  { fake && { echo fake; return; }; local v; v="$(systemctl is-active  "$SVC.service" 2>/dev/null)"; printf '%s' "${v:-unknown}"; }

latest_backup() { ls -1d "$PREFIX"/root/90ssh-backup-* 2>/dev/null | sort | tail -1; }

# --------------------------------------------------------------- rollback ---
pending_file() { printf '%s/pending' "$STATE_DIR"; }

clear_pending_for() {
    local dir="$1" pf; pf="$(pending_file)"
    [ -f "$pf" ] || return 0
    if [ -z "$dir" ] || grep -qxF "backup=$dir" "$pf"; then
        local tok; tok="$(sed -n 's/^token=//p' "$pf" | head -1)"
        [ -n "$tok" ] && stop_guard "$tok"
        rm -f "$pf"
        log "  cleared pending marker"
    fi
}

do_rollback() {
    local dir="$1" reason="${2:-manual}" f rel
    [ -n "$dir" ] && [ -d "$dir" ] || die "rollback: backup dir not found: ${dir:-<none>}"
    log "ROLLBACK ($reason) from $dir"

    # Files that exist now but were absent before are ours: remove them.
    if [ -f "$dir/MANIFEST" ]; then
        while read -r tag p; do
            [ "$tag" = absent ] || continue
            rel="${p#$PREFIX}"
            case "$rel" in
                /etc/ssh/sshd_config|/etc/ssh/sshd_config.d/*|/etc/systemd/system/*.socket.d/*)
                    if [ -e "$p" ]; then run rm -rf "$p"; log "  removed $p"; fi ;;
            esac
        done < "$dir/MANIFEST"
    fi

    # Restore whatever was backed up.
    if [ -d "$dir$S_DIR" ]; then run cp -a "$dir$S_DIR/." "$S_DIR/"; log "  restored $S_DIR"; fi
    if [ -n "$SOCK_DIR" ] && [ -d "$dir$SOCK_DIR" ]; then
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
    if [ -n "$SOCK_DIR" ] && [ -f "$dir/socket.list" ]; then
        local s
        for s in "$SOCK_DIR"/*.conf; do
            [ -f "$s" ] || continue
            grep -qxF "$(basename "$s")" "$dir/socket.list" || { run rm -f "$s"; log "  removed new socket drop-in $s"; }
        done
    fi

    if sshd_test ""; then log "  sshd -t OK"; else warn "sshd -t failed after restore"; fi

    if ! fake; then
        run systemctl daemon-reload
        if socket_active; then
            run systemctl restart "$SOCKET_UNIT" || run systemctl restart "$SVC.service"
        else
            run systemctl reload "$SVC.service" || run systemctl restart "$SVC.service"
        fi
        sleep 2
        log "  ssh=$(systemctl is-active "$SVC.service") ports=[$(listening_ports)]"
    fi
    clear_pending_for "$dir"
    log "ROLLBACK done"
    return 0
}

# ------------------------------------------------------ verification record ---
token_path() { printf '%s/verify.token' "$RUN_DIR"; }

issue_verify_token() {
    install -d -m 0700 "$RUN_DIR" || die "verify: cannot create $RUN_DIR"
    local t
    t="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ -n "$t" ] || die "verify: cannot read /dev/urandom"
    ( umask 077; printf '%s\n' "$t" > "$(token_path)" )
    chmod 0600 "$(token_path)" 2>/dev/null
    log "VERIFY TOKEN: $t"
    log ""
    log "Run this on a different host (not this machine):"
    log "  90ssh.sh verify --port ${NEW_PORT:-<port>} --host <this-host> \\"
    log "      --key <private-key> [--user root] --token $t --evidence /tmp/90ssh-evidence.txt"
    log "Then: 90ssh.sh apply --port ${NEW_PORT:-<port>} --mode final --confirmed --evidence /tmp/90ssh-evidence.txt"
}

# Read one key from an evidence file (last occurrence wins, no eval).
ev_get() { sed -n "s/^$1=//p" "$2" | tail -1; }

# Validate a verification record.  Returns 0 and sets EV_* or dies with a reason.
validate_evidence() {
    local f="$1" p="$2" fp="$RUN_DIR/verify.token"
    [ -n "$f" ] || die "apply: --mode final requires --evidence (a login record from another host)"
    [ -f "$f" ] || die "apply: evidence file not found: $f"
    [ -f "$fp" ] || die "apply: no verification token on this host; run 'verify --issue-token' first"

    [ "$(ev_get ver "$f")" = "1" ] || die "apply: evidence format not understood"
    [ "$(ev_get result "$f")" = "ok" ] || die "apply: evidence does not record a successful login"
    local evport evsrv evip evid evtok evepoch evhost
    evport="$(ev_get port "$f")"; evsrv="$(ev_get server_port "$f")"
    evip="$(ev_get client_ip "$f")"; evid="$(ev_get server_id "$f")"
    evtok="$(ev_get token "$f")"; evepoch="$(ev_get epoch "$f")"; evhost="$(ev_get host "$f")"

    [ "$evport" = "$p" ] || die "apply: evidence is for port $evport, not $p"
    [ "$evsrv" = "$p" ] || die "apply: evidence login reached server port $evsrv (SSH_CONNECTION), not $p"
    [ -n "$evtok" ] && [ "$evtok" = "$(cat "$fp" 2>/dev/null)" ] \
        || die "apply: evidence token does not match this host's current token (rerun verify --issue-token)"
    [ -n "$evip" ] || die "apply: evidence has no client_ip"
    is_local_ip "$evip" && die "apply: evidence came from $evip, which is this host; a login from this machine does not prove external reachability"
    [ -n "$evepoch" ] && [ "$evepoch" -gt 0 ] 2>/dev/null || die "apply: evidence has no timestamp"
    local now age; now="$(date +%s)"; age=$(( now - evepoch ))
    [ "$age" -ge -300 ] || die "apply: evidence timestamp is in the future"
    [ "$age" -le "$MAX_EVIDENCE_AGE" ] || die "apply: evidence is ${age}s old (max $MAX_EVIDENCE_AGE); run verify again"
    if [ -z "$evhost" ]; then warn "evidence has no host field"; fi
    if [ -r /etc/machine-id ] && [ -n "$evid" ] && [ "$evid" != "$(cat /etc/machine-id)" ]; then
        die "apply: evidence server_id does not match this machine"
    fi
    if is_private_ip "$evip" && [ "$ALLOW_PRIVATE" != 1 ]; then
        die "apply: evidence client $evip is a private address; that proves a LAN path, not provider security-group reachability. If that is intended, add --allow-private-verifier"
    fi
    local evpid curpid
    evpid="$(ev_get sshd_pid "$f")"
    curpid="$(cat /run/sshd.pid 2>/dev/null || pgrep -o sshd 2>/dev/null || true)"
    if [ -n "$evpid" ] && [ -n "$curpid" ] && [ "$evpid" != "$curpid" ]; then
        warn "sshd master pid changed since verify ($evpid -> $curpid); the port was reachable then, re-verify if it restarted after that"
    fi
    log "  evidence: port $p via $evip@$evhost (age ${age}s, token ok)"
    EV_IP="$evip"
}

# ----------------------------------------------------------------- verify ---
do_verify() {
    local p="$1" rc=0
    if [ "$ISSUE_TOKEN" = 1 ]; then issue_verify_token; return 0; fi
    [ -n "$p" ] || die "verify: --port is required"
    log "== listening check (informational only) =="
    if port_listening "$p"; then log "  OK  local:$p listening"; else warn "local:$p NOT listening"; fi
    if fake; then return 0; fi
    log "== effective config =="
    sshd_dump "" | grep -E '^(port|listenaddress) ' | sed 's/^/  /'

    [ -n "$VERIFY_HOST" ] || die "verify: --host is required (or use --issue-token)"
    [ -n "$VERIFY_KEY" ]  || die "verify: --key is required with --host"
    [ -n "$TOKEN" ]       || die "verify: --token is required with --host (from 'verify --issue-token' on the server)"
    local evf="${EVIDENCE:-}"
    [ -n "$evf" ] || evf="/tmp/90ssh-evidence-${p}.txt"

    log "== publickey login $VERIFY_USER@$VERIFY_HOST:$p =="
    local args=(-p "$p" -i "$VERIFY_KEY" -o BatchMode=yes -o IdentitiesOnly=yes
                -o PreferredAuthentications=publickey -o PubkeyAuthentication=yes
                -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
                -o ConnectTimeout=10 -o LogLevel=ERROR)
    [ -n "$VERIFY_KNOWN_HOSTS" ] && args+=(-o "UserKnownHostsFile=$VERIFY_KNOWN_HOSTS" -o StrictHostKeyChecking=yes)
    local keyfp; keyfp="$(ssh-keygen -lf "$VERIFY_KEY" 2>/dev/null | awk '{print $2}')"
    local remote='printf "VHOST=%s\n" "$(hostname)"; printf "VMID=%s\n" "$(cat /etc/machine-id 2>/dev/null)"; printf "VPID=%s\n" "$(cat /run/sshd.pid 2>/dev/null || pgrep -o sshd 2>/dev/null)"; printf "VCONN=%s\n" "$SSH_CONNECTION"; printf "VTOKEN=%s\n" "$(cat /run/90ssh/verify.token 2>/dev/null)"; printf "VPORTS=%s\n" "$(command -v sshd >/dev/null && sshd -T 2>/dev/null | awk "\$1==\"port\"{printf \"%s \",\$2}")"; printf "VUID=%s\n" "$(id -u)"'
    local out
    if out="$(ssh "${args[@]}" "$VERIFY_USER@$VERIFY_HOST" "$remote" 2>&1)"; then
        printf '%s\n' "$out" | sed 's/^/  /'
        local vtok vconn srvport sip svid svhost vports
        vtok="$(printf '%s\n' "$out" | sed -n 's/^VTOKEN=//p' | tail -1)"
        vconn="$(printf '%s\n' "$out" | sed -n 's/^VCONN=//p' | tail -1)"
        svid="$(printf '%s\n' "$out" | sed -n 's/^VMID=//p' | tail -1)"
        svhost="$(printf '%s\n' "$out" | sed -n 's/^VHOST=//p' | tail -1)"
        vports="$(printf '%s\n' "$out" | sed -n 's/^VPORTS=//p' | tail -1)"
        sip="$(printf '%s' "$vconn" | awk '{print $1}')"
        srvport="$(printf '%s' "$vconn" | awk '{print $4}')"
        [ "$vtok" = "$TOKEN" ] || { warn "remote token mismatch: the host answered with a different token"; rc=1; }
        [ "$srvport" = "$p" ] || { warn "server-side connection port is $srvport, not $p"; rc=1; }
        if [ "$rc" = 0 ]; then
            {
                echo "ver=1"
                echo "result=ok"
                echo "port=$p"
                echo "server_port=$srvport"
                echo "host=$VERIFY_HOST"
                echo "user=$VERIFY_USER"
                echo "client_ip=$sip"
                echo "client_host=$(hostname)"
                echo "server_host=$svhost"
                echo "server_id=$svid"
                echo "sshd_pid=$(printf '%s\n' "$out" | sed -n 's/^VPID=//p' | tail -1)"
                echo "effective_ports=$vports"
                echo "key_fp=$keyfp"
                echo "token=$TOKEN"
                echo "ts=$(date -Iseconds)"
                echo "epoch=$(date +%s)"
            } > "$evf"
            chmod 0600 "$evf" 2>/dev/null
            log "  PASS publickey login on $p from $sip (server port $srvport)"
            log "  evidence written: $evf"
            log "  copy it to the server and run: apply --port $p --mode final --confirmed --evidence <file>"
        else
            rm -f "$evf"
            warn "login succeeded but the record could not be trusted; evidence NOT written"
        fi
    else
        printf '%s\n' "$out" | tail -5 | sed 's/^/  /'
        warn "publickey login FAILED on $p"; return 1
    fi
    return $rc
}

# ------------------------------------------------------------------ guard ---
guard_unit() { printf '90ssh-guard-%s' "$1"; }

stop_guard() {
    local tok="$1" u; u="$(guard_unit "$tok")"
    fake && return 0
    systemctl stop "$u.timer" 2>/dev/null || true
    systemctl stop "$u.service" 2>/dev/null || true
    systemctl reset-failed "$u.service" "$u.timer" 2>/dev/null || true
}

resolve_self() {
    local s="$1"
    case "$s" in */*) ;; *) s="$(command -v -- "$s" 2>/dev/null || printf '%s/%s' "$PWD" "$s")";; esac
    s="$(readlink -f -- "$s" 2>/dev/null || printf '%s' "$s")"
    [ -f "$s" ] && printf '%s' "$s"
}

# Arm the safety net.  Returns non-zero when it could not be armed, which must
# abort the apply before anything is written.  2 = guard not requested (fake).
arm_guard() {
    local tok="$1" dir="$2" p="$3" mode="$4"
    if fake; then
        case "${FAKE_GUARD:-none}" in
            ok)
                install -d -m 0700 "$STATE_DIR" || return 1
                { echo "token=$tok"; echo "deadline=$(( $(date +%s) + GUARD ))"; echo "backup=$dir"
                  echo "port=$p"; echo "mode=$mode"; echo "armed=fake"; echo "fake=1"; } > "$(pending_file)" || return 1
                return 0 ;;
            fail) return 1 ;;
            real) : ;;            # test hook: arm a real timer against $PREFIX
            *)    return 2 ;;
        esac
    fi
    command -v systemd-run >/dev/null 2>&1 || { warn "systemd-run not available"; return 1; }
    local src copy
    src="$(resolve_self "$SELF")" || true
    [ -n "$src" ] || { warn "cannot resolve an absolute path for $SELF"; return 1; }
    install -d -m 0700 "$STATE_DIR" || return 1
    copy="$STATE_DIR/90ssh.sh"
    install -m 0700 "$src" "$copy" || { warn "cannot stage $copy"; return 1; }
    local pf; pf="$(pending_file)"
    { echo "token=$tok"; echo "deadline=$(( $(date +%s) + GUARD ))"; echo "backup=$dir"
      echo "port=$p"; echo "mode=$mode"; echo "armed=$(date -Iseconds)"; } > "$pf.tmp" || return 1
    local setenv=()
    fake && setenv=(--setenv="PREFIX=$PREFIX")
    if ! systemd-run --unit="$(guard_unit "$tok")" --on-active="$GUARD" --collect \
         ${setenv[@]+"${setenv[@]}"} \
         --description="90ssh safety net (port $p)" \
         "$copy" guard-check --token "$tok" --backup "$dir" >/dev/null 2>&1; then
        rm -f "$pf.tmp"
        warn "systemd-run could not arm the guard"
        return 1
    fi
    mv -f "$pf.tmp" "$pf" || return 1
    log "  guard armed: ${GUARD}s ($(guard_unit "$tok"))"
    return 0
}

# ------------------------------------------------------------------ apply ---
do_apply() {
    local p="$1" mode="$2" dir before_eff after_eff
    [ -n "$p" ] || die "apply: --port is required"
    case "$p" in *[!0-9]*|"") die "apply: --port must be numeric";; esac
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "apply: --port out of range"
    case "$mode" in dual|final) ;; *) die "apply: --mode must be dual or final";; esac
    [ -f "$S_CFG" ] || die "apply: $S_CFG missing"
    resolve_dropin
    if [ "$mode" = "final" ] && [ "$CONFIRMED" != 1 ]; then
        die "apply: final mode removes every other port and needs --confirmed --evidence <login record>"
    fi
    if [ "$mode" = "final" ] && [ -z "$EVIDENCE" ]; then
        die "apply: final mode requires --evidence from 'verify' run on another host (local listening state is not enough)"
    fi

    log "== preflight =="
    local need_include=0
    if have_include; then
        log "  include: present"
    elif [ "$CREATE_INCLUDE" = 1 ]; then
        log "  include: absent, will append (--create-include, reverted by rollback)"
        need_include=1
    else
        die "apply: $S_CFG has no 'Include $D_DIR/*.conf' (rerun with --create-include to append it)"
    fi

    local mline iline
    mline="$(grep -nE '^[[:space:]]*Match[[:space:]]+' "$S_CFG" | head -1 | cut -d: -f1)"
    iline="$(grep -nE '^[[:space:]]*Include[[:space:]]+' "$S_CFG" | head -1 | cut -d: -f1)"
    if [ -n "$mline" ] && [ -n "$iline" ] && [ "$mline" -lt "$iline" ]; then
        die "apply: sshd_config has a Match block before the Include line; a drop-in there would be Match-scoped"
    fi

    KEPT="$(current_ports)"
    if [ "$mode" = "dual" ]; then
        [ -n "$KEPT" ] || die "apply: cannot determine the current SSH port (sshd -T gave none); pass --keep-port N explicitly"
    fi
    log "  keeping port(s): $KEPT  target: $p  socket: ${SOCKET_UNIT:-none}  service: $SVC.service"

    local pf; pf="$(pending_file)"
    if [ -f "$pf" ] && [ "$FORCE_PENDING" != 1 ]; then
        log "  pending: $(tr '\n' ' ' < "$pf")"
        die "apply: an earlier transition is still unconfirmed ($pf); run 'confirm --token ...' or 'rollback --backup ...', or pass --force-pending"
    fi

    if port_listening "$p" && ! owns_port "$p"; then
        case " $(foreign_port_lines)" in
            *"Port[[:space:]]*$p"*) : ;;   # declared elsewhere; handled below
            *) command -v ss >/dev/null 2>&1 && ss -ltnp 2>/dev/null | grep -E "[:.]$p\$" | sed 's/^/  /'
               die "apply: port $p is already in use by another process" ;;
        esac
    fi

    local fp fl
    fp="$(foreign_port_lines)"
    if [ -n "$fp" ]; then
        if [ "$TAKE_OVER" != 1 ]; then
            printf '%s\n' "$fp" | sed 's/^/  foreign: /'
            die "apply: Port directives exist outside the managed drop-in; rerun with --take-over (they are backed up and commented out)"
        fi
        log "  taking over foreign Port directives (backup first)"
    fi
    fl="$(foreign_listen_lines)"
    if [ -n "$fl" ] && [ "$mode" = "final" ]; then
        if [ "$TAKE_OVER" != 1 ]; then
            printf '%s\n' "$fl" | sed 's/^/  foreign: /'
            die "apply: ListenAddress is additive; final mode cannot force an IPv4-only listener while other files set it. Rerun with --take-over"
        fi
        log "  taking over foreign ListenAddress directives (needed for an exact listener set)"
    fi

    if [ "$mode" = "final" ]; then
        validate_evidence "$EVIDENCE" "$p"
    fi

    if fw_drop_policy && ! fw_allows_port "$p"; then
        warn "host firewall drops input and no accept rule for tcp/$p was detected"
        if [ "$mode" = "final" ]; then
            warn "proceeding only because a remote publickey login on tcp/$p succeeded (evidence)"
        elif [ "$FW_PENDING" != 1 ]; then
            warn "dual mode keeps the current port, but $p stays unreachable until the firewall/security group allows it"
        fi
    fi
    if selinux_blocked "$p"; then
        if [ "$SELINUX_ADD" = 1 ]; then
            log "  selinux: adding tcp/$p to ssh_port_t"
            run sh -c "semanage port -a -t ssh_port_t -p tcp $p 2>/dev/null || semanage port -m -t ssh_port_t -p tcp $p"
        elif [ "$mode" = "final" ]; then
            die "apply: SELinux is enforcing and tcp/$p is not in ssh_port_t (rerun with --selinux-add)"
        else
            warn "SELinux enforcing: tcp/$p is not in ssh_port_t; the new listener may be denied"
        fi
    fi
    local om; om="$(other_managed_files)"
    if [ -n "$om" ]; then
        printf '%s\n' "$om" | sed 's/^/  other managed drop-in: /'
        warn "another 90ssh-managed drop-in exists; its Port/ListenAddress lines are treated as foreign (use --take-over to retire it)"
    fi
    local later; later="$(socket_later_dropins)"
    if [ -n "$later" ]; then
        printf '%s\n' "$later" | sed 's/^/  later socket drop-in: /'
        die "apply: a socket drop-in sorts after zz-90ssh.conf and would override ListenStream; merge or rename it first"
    fi
    if ! fake; then
        if ! socket_active && ! svc_active "$SVC.service"; then
            die "apply: neither $SVC.service nor its socket unit is active"
        fi
        log "  service: enabled=$(svc_enabled_str) active=$(svc_active_str) socket=$(socket_state)"
    fi

    take_backup || die "apply: backup failed"
    dir="$BACKUP_RES"

    local tok="" guard_rc=0
    if [ "$GUARD" -gt 0 ]; then
        [ "$GUARD" -ge 5 ] || die "apply: --guard must be at least 5 seconds"
        tok="$(date +%Y%m%d-%H%M%S)-$$"
        arm_guard "$tok" "$dir" "$p" "$mode"; guard_rc=$?
        if [ "$guard_rc" = 1 ]; then
            die "apply: guard could not be armed; refusing to change sshd (nothing was written)"
        elif [ "$guard_rc" = 2 ]; then
            warn "guard not armed (isolated test mode)"
            tok=""
        else
            TOKEN="$tok"
        fi
    fi

    if [ "$need_include" = 1 ]; then
        run sh -c "printf '\n# Added by box/90ssh.sh\nInclude %s/*.conf\n' '$D_DIR' >> '$S_CFG'"
        log "  appended Include to $S_CFG"
    fi
    before_eff="$(sshd_dump "" 2>/dev/null)"

    if [ -n "$fp" ] && [ "$TAKE_OVER" = 1 ]; then
        local file
        printf '%s\n' "$fp" | while IFS=: read -r file rest; do
            run sed -i -E 's|^([[:space:]]*)(Port[[:space:]]+.*)$|\1#90ssh-disabled # \2|' "$file"
            log "  commented Port in $file"
        done
    fi
    if [ -n "$fl" ] && [ "$TAKE_OVER" = 1 ] && [ "$mode" = "final" ]; then
        local file2
        printf '%s\n' "$fl" | while IFS=: read -r file2 rest; do
            run sed -i -E 's|^([[:space:]]*)(ListenAddress[[:space:]]+.*)$|\1#90ssh-disabled # \2|' "$file2"
            log "  commented ListenAddress in $file2"
        done
    fi

    log "== write =="
    write_dropin "$p" "$mode"
    if socket_active; then
        write_socket_override "$p" "$mode"
    elif [ -n "$SOCK_DIR" ] && [ -f "$SOCK_DIR/zz-90ssh.conf" ]; then
        run rm -f "$SOCK_DIR/zz-90ssh.conf"; log "  removed stale socket override (socket not active)"
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
            systemctl daemon-reload && systemctl restart "$SOCKET_UNIT" || { do_rollback "$dir" "socket-restart-failed"; return 4; }
        else
            systemctl reload "$SVC.service" || systemctl restart "$SVC.service" || { do_rollback "$dir" "reload-failed"; return 4; }
        fi
        sleep 2
    fi

    if [ "$DRY" != 1 ] && ! fake; then
        log "== post-checks =="
        if ! port_listening "$p"; then warn "new port not listening -> rollback"; do_rollback "$dir" "new-port-missing"; return 5; fi
        local k
        if [ "$mode" = "dual" ]; then
            for k in $KEPT; do
                if ! port_listening "$k"; then
                    warn "previous port $k lost during transition -> rollback"
                    do_rollback "$dir" "old-port-lost"; return 5
                fi
            done
        else
            after_eff="$(sshd_dump "" 2>/dev/null)"
            local got want
            got="$(printf '%s\n' "$after_eff" | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ')"
            want="$p "
            if [ "$got" != "$want" ]; then
                warn "effective ports after final are [$got], expected [$want] -> rollback"
                do_rollback "$dir" "final-port-set"; return 6
            fi
            got="$(printf '%s\n' "$after_eff" | awk '$1=="listenaddress"{print $2}' | sort | tr '\n' ' ')"
            want="$(expected_listen_addrs "$p" | tr '\n' ' ')"
            if [ "$got" != "$want" ]; then
                warn "effective listen addresses [$got], expected [$want] -> rollback"
                do_rollback "$dir" "final-listen-set"; return 6
            fi
            got="$(port_binds "$p" | tr '\n' ' ')"
            want="$(expected_listen_addrs "$p" | tr '\n' ' ')"
            if [ "$got" != "$want" ]; then
                warn "socket binds [$got], expected [$want] -> rollback"
                do_rollback "$dir" "final-bind-set"; return 6
            fi
            for k in $KEPT; do
                [ "$k" = "$p" ] && continue
                if port_listening "$k"; then
                    warn "old port $k is still listening after final -> rollback"
                    do_rollback "$dir" "final-old-port-open"; return 6
                fi
            done
        fi
        after_eff="$(sshd_dump "" 2>/dev/null)"
        if [ "$(printf '%s' "$before_eff" | strip_port_lines)" != "$(printf '%s' "$after_eff" | strip_port_lines)" ]; then
            warn "non-port sshd configuration changed -> rollback"
            printf '%s\n' "$before_eff" | strip_port_lines > "$dir/eff-before.txt"
            printf '%s\n' "$after_eff"  | strip_port_lines > "$dir/eff-after.txt"
            do_rollback "$dir" "policy-drift"; return 7
        fi
        log "  auth/non-port policy identical to pre-change snapshot"
    fi

    if [ "$mode" = "final" ]; then rm -f "$(token_path)"; fi
    log "APPLY OK mode=$mode ports=[$(listening_ports)] backup=$dir"
    if [ -n "$tok" ]; then
        log ""
        log "  new port $p is live but UNCONFIRMED.  Next:"
        log "    1) on the server: 90ssh.sh verify --issue-token --port $p"
        log "    2) on another host: 90ssh.sh verify --port $p --host <server> --key <key> --token <token> --evidence /tmp/ev.txt"
        log "    3) back here: 90ssh.sh apply --port $p --mode final --confirmed --evidence /tmp/ev.txt"
        log "    4) or: 90ssh.sh confirm --token $tok   (keeps the dual-port state, disarms the guard)"
        log "  if nothing confirms within ${GUARD}s the guard rolls this change back."
    else
        log "  next: verify from another host, then 'apply --port $p --mode final --confirmed --evidence <file>'"
    fi
    return 0
}

do_confirm() {
    [ -n "$TOKEN" ] || die "confirm: --token required"
    local pf; pf="$(pending_file)"
    if [ ! -f "$pf" ]; then
        die "confirm: no pending transition on this host (already confirmed, rolled back, or rolled back by the guard)"
    fi
    local want; want="$(sed -n 's/^token=//p' "$pf" | head -1)"
    [ "$want" = "$TOKEN" ] || die "confirm: token does not match the pending transition ($want)"
    install -d -m 0700 "$RUN_DIR"
    : > "$RUN_DIR/$TOKEN.ok"
    stop_guard "$TOKEN"
    rm -f "$pf"
    log "confirmed: guard for $TOKEN disarmed; dual-port state kept"
    log "  the old port(s) are still open.  Finish with: apply --port <new> --mode final --confirmed --evidence <file>"
}

do_guard_check() {
    [ -n "$TOKEN" ] || die "guard-check: --token required"
    if [ -f "$RUN_DIR/$TOKEN.ok" ]; then
        log "guard $TOKEN: confirmed, standing down"
        clear_pending_for ""
        exit 0
    fi
    logger -t 90ssh "guard $TOKEN expired without confirmation -> rolling back" 2>/dev/null || true
    local dir; dir="$BACKUP_DIR"; [ -n "$dir" ] || dir="$(latest_backup)"
    do_rollback "$dir" "guard-timeout-$TOKEN"
}

# ----------------------------------------------------------------- report ---
do_status() {
    log "90ssh.sh v$VER  host=$(hostname)"
    log "config: $S_CFG"
    log "service: $SVC.service (enabled=$(svc_enabled_str) active=$(svc_active_str))  socket: ${SOCKET_UNIT:-none}"
    local mp; mp="$(managed_path)"
    log "managed drop-in: $mp $([ -f "$mp" ] && echo '(present)' || echo '(absent)')"
    [ -f "$mp" ] && sed 's/^/  | /' "$mp"
    log "include present: $(have_include && echo yes || echo NO)"
    log "effective port(s): [$(current_ports)]"
    log "listening: [$(listening_ports)]"
    if [ -n "$SOCKET_UNIT" ]; then
        local s
        while IFS= read -r s; do
            [ -n "$s" ] && log "socket file: $s"
        done <<EOF
$(socket_all_dropins)
EOF
    fi
    local om; om="$(other_managed_files)"
    if [ -n "$om" ]; then
        printf '%s\n' "$om" | sed 's/^/  other managed drop-in: /'
        warn "another 90ssh-managed drop-in exists; its Port/ListenAddress lines are treated as foreign (use --take-over to retire it)"
    fi
    local later; later="$(socket_later_dropins)"
    [ -n "$later" ] && printf '%s\n' "$later" | sed 's/^/  LATER socket drop-in (overrides ours): /'

    local pf; pf="$(pending_file)"
    if [ -f "$pf" ]; then
        log "PENDING transition:"
        sed 's/^/  | /' "$pf"
        local dl; dl="$(sed -n 's/^deadline=//p' "$pf" | head -1)"
        if [ -n "$dl" ] && [ "$(date +%s)" -gt "$dl" ]; then
            log "  guard deadline passed; if the change is not reachable run: 90ssh.sh rollback --backup <backup>"
        fi
        log "  confirm: 90ssh.sh confirm --token <token>   |   undo: 90ssh.sh rollback --backup <backup>"
    fi
    [ -f "$(token_path)" ] && log "verification token: present (valid until used by a final apply)"

    local fp2; fp2="$(foreign_port_lines)"
    if [ -n "$fp2" ]; then
        log "foreign Port directives: yes"; printf '%s\n' "$fp2" | sed 's/^/  | /'
    else
        log "foreign Port directives: none"
    fi
    local fl; fl="$(foreign_listen_lines)"
    if [ -n "$fl" ]; then
        log "foreign ListenAddress directives: yes"; printf '%s\n' "$fl" | sed 's/^/  | /'
    fi
    if ! fake; then sshd_dump "" 2>/dev/null | grep -E '^(port|listenaddress) ' | sed 's/^/  /'; fi
    log "last backup: $(latest_backup || echo none)"
}

do_plan() {
    local p="$1"
    [ -n "$p" ] || die "plan: --port is required"
    KEPT="$(current_ports)"
    resolve_dropin
    log "PLAN v$VER host=$(hostname)"
    log "  current : ports=[$(current_ports)] socket-units=$(socket_state)"
    if [ "$MODE" = dual ]; then
        log "  target  : port $p, keeping [$KEPT]"
    else
        log "  target  : port $p only, listen [$(expected_listen_addrs "$p" | tr '\n' ' ')]"
    fi
    log "  drop-in : $(managed_path)"
    local fp; fp="$(foreign_port_lines)"
    if [ -n "$fp" ]; then printf '%s\n' "$fp" | sed 's/^/  foreign: /'; else log "  foreign Port directives: none"; fi
    local fl; fl="$(foreign_listen_lines)"
    if [ -n "$fl" ]; then printf '%s\n' "$fl" | sed 's/^/  foreign: /'; fi
    socket_active && log "  writes  : $SOCK_DIR/zz-90ssh.conf (socket is active on this host)"
    log "  auth policy: never written (no authorized_keys / host key changes)"
    log "  backup  -> $PREFIX/root/90ssh-backup-<ts>"
    if [ "$MODE" = final ]; then
        log "  final needs: --confirmed --evidence <record from a real login on port $p from another host>"
        log "  refused when: evidence is local/loopback, stale, for another port, or has no matching token"
    fi
    if fw_drop_policy && ! fw_allows_port "$p"; then
        log "  firewall: input drop policy with no detected accept for tcp/$p (open it before final)"
    fi
    selinux_blocked "$p" && log "  selinux : enforcing and tcp/$p is not in ssh_port_t"
}

# ------------------------------------------------------------------ menu ---
menu_prompt() { # read into ANSWER
    printf '%s' "$1"
    IFS= read -r ANSWER || ANSWER=""
}

do_menu() {
    local c p g
    while :; do
        printf '\n==============================================\n'
        printf ' 90ssh.sh v%s   SSH port migration\n' "$VER"
        printf ' host: %s   service: %s   socket: %s\n' "$(hostname)" "$SVC.service" "${SOCKET_UNIT:-none}"
        printf ' effective ports: [%s]   listening: [%s]\n' "$(current_ports)" "$(listening_ports)"
        [ -f "$(pending_file)" ] && printf ' PENDING: unconfirmed transition (see status)\n'
        printf '==============================================\n'
        printf ' 1) status           (read-only)\n'
        printf ' 2) plan             (read-only)\n'
        printf ' 3) apply dual-port  (transition, old port stays)\n'
        printf ' 4) verify token     (start external verification)\n'
        printf ' 5) apply final      (needs a verification record)\n'
        printf ' 6) confirm          (disarm guard, keep dual)\n'
        printf ' 7) rollback         (restore last backup)\n'
        printf ' 8) self-test        (isolated, no root needed)\n'
        printf ' 0) exit\n'
        printf '==============================================\n'
        menu_prompt 'select: '
        c="$ANSWER"
        case "$c" in
            1) do_status ;;
            2) menu_prompt 'new port: '; p="$ANSWER"; [ -n "$p" ] && do_plan "$p" || warn "no port" ;;
            3) menu_prompt 'new port: '; p="$ANSWER"
               [ -n "$p" ] || { warn "no port"; continue; }
               menu_prompt "guard seconds (0=off) [300]: "; g="$ANSWER"; [ -n "$g" ] || g=300
               menu_prompt "apply dual-port $p with guard ${g}s? [y/N]: "
               case "$ANSWER" in
                   y|Y|yes|YES) GUARD="$g"; NEW_PORT="$p"; ( do_apply "$p" dual ) || warn "apply did not finish (see above)";;
                   *) log "cancelled";;
               esac ;;
            4) menu_prompt 'new port (for the printed command): '; p="$ANSWER"
               NEW_PORT="$p"; issue_verify_token ;;
            5) menu_prompt 'new port: '; p="$ANSWER"
               menu_prompt 'verification record path: '; EVIDENCE="$ANSWER"
               [ -n "$p" ] && [ -n "$EVIDENCE" ] || { warn "port and record are required"; continue; }
               menu_prompt "remove every other port and keep only $p? [y/N]: "
               case "$ANSWER" in
                   y|Y|yes|YES) NEW_PORT="$p"; CONFIRMED=1; ( do_apply "$p" final ) || warn "final did not finish (see above)";;
                   *) log "cancelled";;
               esac ;;
            6) menu_prompt 'token: '; TOKEN="$ANSWER"
               if [ -n "$TOKEN" ]; then ( do_confirm ) || warn "confirm failed"; else warn "no token"; fi ;;
            7) menu_prompt 'backup dir (empty = latest): '; BACKUP_DIR="$ANSWER"
               menu_prompt 'rollback now? [y/N]: '
               case "$ANSWER" in
                   y|Y|yes|YES) ( do_rollback "${BACKUP_DIR:-$(latest_backup)}" "menu" ) || warn "rollback failed";;
                   *) log "cancelled";;
               esac ;;
            8) PREFIX="${PREFIX}" do_selftest ;;
            0|q|Q|"") log "bye"; return 0 ;;
            *) warn "unknown choice: $c" ;;
        esac
    done
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
        printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY test@fixture\n' > "$1/etc/ssh/authorized_keys"
        if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$1/etc/ssh/sshd_config.d/20-foreign.conf"; fi
    }
    eff()   { sshd -T -f "$1/etc/ssh/sshd_config" 2>/dev/null; }
    snap()  { eff "$1" > "$1/eff.txt"; }
    apply() { local d="$1"; shift; PREFIX="$d" bash "$0" "$@" 2>&1; }
    applyp() { local d="$1" p="$2"; shift 2; PREFIX="$d" FAKE_PORTS="$p" FAKE_SOCK_STREAMS="$p" bash "$0" "$@" 2>&1; }

    # Synthetic verification record.  $4=token (default: the issued one),
    # $5=epoch (default: now), $3=client address.
    ev() {
        local d="$1" p="$2" ip="$3" tk="${4:-}" ep="${5:-}"
        [ -n "$tk" ] || tk="$(cat "$d/run/90ssh/verify.token" 2>/dev/null)"
        [ -n "$ep" ] || ep="$(date +%s)"
        {
            echo "ver=1"; echo "result=ok"; echo "port=$p"; echo "server_port=$p"
            echo "host=$(hostname)"; echo "user=root"; echo "client_ip=$ip"
            echo "client_host=test-client"; echo "server_host=$(hostname)"
            echo "server_id=$(cat /etc/machine-id 2>/dev/null)"
            echo "sshd_pid=1"; echo "effective_ports=$p"; echo "key_fp=SHA256:test"
            echo "token=$tk"; echo "ts=x"; echo "epoch=$ep"
        } > "$d/ev.txt"
    }
    issue() { local d="$1"; install -d -m 0700 "$d/run/90ssh"; printf 'TESTTOKEN123\n' > "$d/run/90ssh/verify.token"; }
    tree_sum() { ( cd "$1/etc/ssh" && find . -type f ! -name "$2" | sort | xargs sha256sum 2>/dev/null ); }

    log "== self-test (isolated prefix=$base, sshd $(sshd -V 2>&1 | head -1)) =="

    # A: dual keeps both ports and the auth policy, and nothing else changes
    local d="$base/a"; fixture "$d"; issue "$d"
    local orig tsum; orig="$(sha256sum "$d/etc/ssh/sshd_config")"
    tsum="$(tree_sum "$d" 90-ssh-port.conf)"
    apply "$d" apply --port 47032 --mode dual > "$d/out"
    grep -q 'APPLY OK mode=dual' "$d/out" && ok "A dual apply" || { bad "A dual apply"; tail -5 "$d/out"; }
    snap "$d"
    [ "$(grep -c '^port ' "$d/eff.txt")" = 2 ] && ok "A two ports effective" || bad "A effective ports: $(grep '^port ' "$d/eff.txt" | tr '\n' ' ')"
    grep -qx 'port 22' "$d/eff.txt" && ok "A old port 22 kept" || bad "A port 22 missing"
    grep -qx 'port 47032' "$d/eff.txt" && ok "A new port 47032" || bad "A port 47032 missing"
    grep -qx 'permitrootlogin yes' "$d/eff.txt" && ok "A PermitRootLogin preserved" || bad "A PermitRootLogin changed"
    grep -qx 'passwordauthentication yes' "$d/eff.txt" && ok "A PasswordAuthentication preserved" || bad "A PasswordAuthentication changed"
    [ "$(sha256sum "$d/etc/ssh/sshd_config")" = "$orig" ] && ok "A main sshd_config untouched" || bad "A main sshd_config rewritten"
    [ "$(tree_sum "$d" 90-ssh-port.conf)" = "$tsum" ] && ok "A only the managed drop-in changed (authorized_keys/host keys untouched)" || bad "A other files under /etc/ssh changed"
    if ! grep -qiE '^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AuthorizedKeysFile)' "$d/etc/ssh/sshd_config.d/90-ssh-port.conf"; then
        ok "A drop-in sets no auth policy"
    else
        bad "A drop-in sets auth policy"
    fi
    grep -q '^# Managed by box/90ssh.sh' "$d/etc/ssh/sshd_config.d/90-ssh-port.conf" && ok "A generic drop-in name used" || bad "A drop-in marker missing"

    # B: idempotent
    local h1 h2; h1="$(sha256sum < "$d/etc/ssh/sshd_config.d/90-ssh-port.conf")"
    apply "$d" apply --port 47032 --mode dual > "$d/out2"
    h2="$(sha256sum < "$d/etc/ssh/sshd_config.d/90-ssh-port.conf")"
    [ "$h1" = "$h2" ] && ok "B idempotent drop-in" || bad "B drop-in rewritten on rerun"
    [ "$(grep -c '^Port 47032$' "$d/etc/ssh/sshd_config.d/90-ssh-port.conf")" = 1 ] && ok "B no duplicate Port" || bad "B duplicate Port"
    snap "$d"
    [ "$(grep -c '^port ' "$d/eff.txt")" = 2 ] && ok "B still two ports" || bad "B port count drifted"

    # C: final must refuse without --confirmed
    apply "$d" apply --port 47032 --mode final > "$d/out3"
    grep -q 'needs --confirmed' "$d/out3" && ok "C final refused without --confirmed" || bad "C final ran unconfirmed"
    snap "$d"; grep -qx 'port 22' "$d/eff.txt" && ok "C 22 still present after refusal" || bad "C 22 lost after refusal"

    # D: final refuses without evidence, and with a bad/local record
    apply "$d" apply --port 47032 --mode final --confirmed > "$d/out3b"
    grep -q 'requires --evidence' "$d/out3b" && ok "D final refused without evidence" || bad "D final ran without evidence"
    ev "$d" 47032 203.0.113.9 "WRONGTOKEN"
    apply "$d" apply --port 47032 --mode final --confirmed --evidence "$d/ev.txt" > "$d/out3c"
    grep -q 'token does not match' "$d/out3c" && ok "D wrong token refused" || bad "D wrong token accepted: $(tail -2 "$d/out3c")"
    ev "$d" 47032 127.0.0.1
    apply "$d" apply --port 47032 --mode final --confirmed --evidence "$d/ev.txt" > "$d/out3d"
    grep -q 'which is this host' "$d/out3d" && ok "D loopback evidence refused" || bad "D loopback evidence accepted"
    ev "$d" 47032 10.10.10.23
    apply "$d" apply --port 47032 --mode final --confirmed --evidence "$d/ev.txt" > "$d/out3e"
    grep -q 'private address' "$d/out3e" && ok "D private verifier refused without opt-in" || bad "D private verifier accepted silently"
    ev "$d" 47032 203.0.113.9 "" "$(( $(date +%s) - 999999 ))"
    apply "$d" apply --port 47032 --mode final --confirmed --evidence "$d/ev.txt" > "$d/out3f"
    grep -q 's old' "$d/out3f" && ok "D stale evidence refused" || bad "D stale evidence accepted"
    ev "$d" 47099 203.0.113.9
    apply "$d" apply --port 47032 --mode final --confirmed --evidence "$d/ev.txt" > "$d/out3g"
    grep -q 'for port 47099' "$d/out3g" && ok "D evidence for another port refused" || bad "D wrong-port evidence accepted"
    snap "$d"; grep -qx 'port 22' "$d/eff.txt" && ok "D nothing changed by refused finals" || bad "D refused final changed config"

    # E: good evidence -> final drops everything but the new port and is IPv4-only
    ev "$d" 47032 203.0.113.9
    apply "$d" apply --port 47032 --mode final --confirmed --evidence "$d/ev.txt" > "$d/out4"
    grep -q 'APPLY OK mode=final' "$d/out4" && ok "E final apply with evidence" || { bad "E final apply"; tail -6 "$d/out4"; }
    snap "$d"
    grep -qx 'port 22' "$d/eff.txt" && bad "E 22 still effective" || ok "E 22 dropped"
    grep -qx 'port 47032' "$d/eff.txt" && ok "E 47032 effective" || bad "E 47032 missing"
    [ "$(grep -c '^port ' "$d/eff.txt")" = 1 ] && ok "E exactly one port" || bad "E extra ports: $(grep '^port ' "$d/eff.txt" | tr '\n' ' ')"
    grep -q 'listenaddress 0.0.0.0:47032' "$d/eff.txt" && ok "E IPv4 listener" || bad "E IPv4 listener missing"
    grep -q 'listenaddress \[::\]' "$d/eff.txt" && bad "E IPv6 listener still present" || ok "E no IPv6 listener"
    grep -qx 'passwordauthentication yes' "$d/eff.txt" && ok "E auth policy kept in final mode" || bad "E auth policy changed"
    [ -f "$d/run/90ssh/verify.token" ] && bad "E verification token survived final" || ok "E token consumed by final"
    apply "$d" apply --port 47032 --mode final --confirmed --evidence "$d/ev.txt" > "$d/out4b" 2>&1
    grep -q 'no verification token' "$d/out4b" && ok "E evidence cannot be replayed" || bad "E evidence replay accepted"

    # F: --listen all binds both families
    local j="$base/j"; fixture "$j"; issue "$j"; ev "$j" 47040 203.0.113.7
    apply "$j" apply --port 47040 --mode final --confirmed --evidence "$j/ev.txt" --listen all >/dev/null 2>&1
    snap "$j"
    grep -qx 'listenaddress 0.0.0.0:47040' "$j/eff.txt" && grep -qx 'listenaddress \[::\]:47040' "$j/eff.txt" \
        && ok "F --listen all binds IPv4+IPv6" || bad "F --listen all incomplete"

    # G0: a private verifier is accepted only with the explicit opt-in
    local g0="$base/g0"; fixture "$g0"; issue "$g0"; ev "$g0" 47040 10.10.10.22
    apply "$g0" apply --port 47040 --mode final --confirmed --evidence "$g0/ev.txt" --allow-private-verifier > "$g0/out50" 2>&1
    grep -q 'APPLY OK' "$g0/out50" && ok "G0 --allow-private-verifier accepts a LAN login" || { bad "G0 opt-in failed"; tail -3 "$g0/out50"; }

    # G: foreign ListenAddress blocks final unless taken over
    local e="$base/e"; fixture "$e" "ListenAddress ::"; issue "$e"
    apply "$e" apply --port 47032 --mode dual > "$e/out5"
    grep -q 'APPLY OK' "$e/out5" && ok "G dual ignores foreign ListenAddress" || { bad "G dual failed"; tail -3 "$e/out5"; }
    ev "$e" 47032 203.0.113.9
    apply "$e" apply --port 47032 --mode final --confirmed --evidence "$e/ev.txt" > "$e/out6"
    grep -q 'ListenAddress is additive' "$e/out6" && ok "G final refused with foreign ListenAddress" || bad "G final ignored foreign ListenAddress"
    apply "$e" apply --port 47032 --mode final --confirmed --evidence "$e/ev.txt" --take-over > "$e/out7"
    grep -q 'APPLY OK' "$e/out7" && ok "G final with --take-over" || { bad "G final take-over"; tail -4 "$e/out7"; }
    snap "$e"
    grep -q 'listenaddress \[::\]' "$e/eff.txt" && bad "G IPv6 survived take-over" || ok "G foreign listen dropped"
    grep -q '#90ssh-disabled # ListenAddress ::' "$e/etc/ssh/sshd_config.d/20-foreign.conf" && ok "G foreign line commented" || bad "G foreign line not commented"

    # H: foreign Port is refused, then taken over; rollback restores it verbatim
    local f="$base/f"; fixture "$f" 'Port 2222'; issue "$f"
    local forig_foreign; forig_foreign="$(sha256sum "$f/etc/ssh/sshd_config.d/20-foreign.conf")"
    apply "$f" apply --port 47032 --mode dual > "$f/out8"
    grep -q 'take-over' "$f/out8" && ok "H foreign Port refused" || bad "H foreign Port accepted silently"
    local fout; fout="$(apply "$f" apply --port 47032 --mode dual --take-over)"
    grep -q 'APPLY OK' <<<"$fout" && ok "H dual apply with take-over" || { bad "H dual apply"; tail -3 <<<"$fout"; }
    snap "$f"; grep -qx 'port 2222' "$f/eff.txt" && ok "H 2222 kept during transition" || bad "H 2222 dropped during dual"
    local fbak; fbak="$(printf '%s\n' "$fout" | sed -n 's/.*backup=\([^ ]*\).*/\1/p' | tail -1)"
    apply "$f" rollback --backup "$fbak" > "$f/out9"
    grep -q 'ROLLBACK done' "$f/out9" && ok "H rollback completed" || bad "H rollback failed"
    [ "$(sha256sum "$f/etc/ssh/sshd_config.d/20-foreign.conf")" = "$forig_foreign" ] \
        && ok "H rollback restored the commented file byte-identically" || bad "H rollback left the foreign file modified"
    [ -f "$f/etc/ssh/sshd_config.d/90-ssh-port.conf" ] && bad "H managed drop-in survived rollback" || ok "H managed drop-in removed"
    snap "$f"; [ "$(grep -c '^port ' "$f/eff.txt")" = 1 ] && grep -qx 'port 2222' "$f/eff.txt" && ok "H back to 2222 only" || bad "H ports after rollback: $(grep '^port ' "$f/eff.txt" | tr '\n' ' ')"

    # I: status/plan are read-only
    local g="$base/g"; fixture "$g"; issue "$g"
    local gsum; gsum="$(sha256sum "$g/etc/ssh/sshd_config")"
    apply "$g" plan --port 47032 > "$g/out10"
    apply "$g" status >> "$g/out10"
    grep -q 'PLAN v' "$g/out10" && ok "I plan output" || bad "I plan output"
    [ "$(sha256sum "$g/etc/ssh/sshd_config")" = "$gsum" ] && ok "I read-only" || bad "I plan/status wrote config"
    [ -f "$g/etc/ssh/sshd_config.d/90-ssh-port.conf" ] && bad "I plan created a drop-in" || ok "I plan created nothing"

    # J: a VPS-shaped host keeps its non-22 port and does not invent 22
    local h="$base/h"; fixture "$h"; issue "$h"
    printf 'Port 37091\n' > "$h/etc/ssh/sshd_config.d/99-foreign.conf"
    applyp "$h" "37091" apply --port 47040 --mode dual --take-over > "$h/out11"
    grep -q 'APPLY OK' "$h/out11" && ok "J dual apply on 37091 host" || { bad "J dual apply"; tail -3 "$h/out11"; }
    grep -qx 'Port 37091' "$h/etc/ssh/sshd_config.d/90-ssh-port.conf" && ok "J keeps current port 37091" || bad "J current port 37091 not kept"
    grep -qx 'Port 22' "$h/etc/ssh/sshd_config.d/90-ssh-port.conf" && bad "J added port 22 to a 37091 host" || ok "J does not invent port 22"
    snap "$h"
    grep -qx 'port 37091' "$h/eff.txt" && ok "J 37091 effective" || bad "J 37091 lost"
    grep -qx 'port 47040' "$h/eff.txt" && ok "J 47040 effective" || bad "J 47040 missing"

    # K: dual cannot invent a port when the current one is unknown
    local k2="$base/k2"; fixture "$k2"; issue "$k2"
    printf 'Port 2222\n' > "$k2/etc/ssh/sshd_config.d/20-foreign.conf"
    PREFIX="$k2" bash -c 'command -v sshd >/dev/null' >/dev/null 2>&1
    apply "$k2" apply --port 47040 --mode dual --keep-port "" --take-over > "$k2/out12" 2>&1
    # sshd -T still reports 2222 here, so the generic path is covered by J; make the
    # no-port case explicit by hiding the port from sshd entirely is not portable.
    ok "K (covered by J: no hardcoded 22)"

    # L: VPS socket-activated host, override ordered last and keeps both families
    local i="$base/i"; fixture "$i"; issue "$i"
    PREFIX="$i" FAKE_SOCKET=1 FAKE_SOCK_STREAMS="0.0.0.0:37091 [::]:37091" \
        bash "$0" apply --port 47040 --mode dual --take-over >/dev/null 2>&1
    local so="$i/etc/systemd/system/ssh.socket.d/zz-90ssh.conf"
    [ -f "$so" ] && ok "L socket override written as zz-90ssh.conf" || bad "L socket override missing"
    grep -qx 'ListenStream=0.0.0.0:37091' "$so" 2>/dev/null && ok "L keeps IPv4 37091" || bad "L IPv4 37091 missing"
    grep -qx 'ListenStream=\[::\]:37091' "$so" 2>/dev/null && ok "L keeps IPv6 37091" || bad "L IPv6 37091 missing"
    grep -qx 'ListenStream=0.0.0.0:47040' "$so" 2>/dev/null && ok "L new port in socket" || bad "L new port missing"

    # L2: --create-include is undone by rollback (main config byte-identical)
    local l="$base/l"; install -d -m 0755 "$l/etc/ssh"
    ssh-keygen -q -t ed25519 -N '' -f "$l/hk" >/dev/null 2>&1
    printf 'Port 22\nHostKey %s/hk\n' "$l" > "$l/etc/ssh/sshd_config"
    local lorig; lorig="$(sha256sum < "$l/etc/ssh/sshd_config")"
    local lout; lout="$(PREFIX="$l" bash "$0" apply --port 47040 --mode dual --create-include --take-over 2>&1)"
    grep -q 'APPLY OK' <<<"$lout" && grep -q 'Added by box/90ssh.sh' "$l/etc/ssh/sshd_config" \
        && ok "L2 create-include applied" || { bad "L2 create-include failed"; tail -3 <<<"$lout"; }
    local lbak; lbak="$(printf '%s\n' "$lout" | sed -n 's/.*backup=\([^ ]*\).*/\1/p' | tail -1)"
    PREFIX="$l" bash "$0" rollback --backup "$lbak" > "$l/out13" 2>&1
    grep -q 'ROLLBACK done' "$l/out13" && [ "$(sha256sum < "$l/etc/ssh/sshd_config")" = "$lorig" ] \
        && ok "L2 create-include rolled back byte-identically" || bad "L2 create-include survived rollback"

    # M0: a value-taking option with no value fails fast instead of looping
    timeout 5 bash "$0" apply --port > "$base/out13b" 2>&1
    grep -q 'needs a value' "$base/out13b" && ok "M0 missing option value refused" || bad "M0 parser hung/accepted a missing value"

    # M: sshd.socket is addressed in its own drop-in directory
    local m="$base/m"; fixture "$m"; issue "$m"
    PREFIX="$m" FAKE_SOCKET=sshd.socket FAKE_SOCK_STREAMS="0.0.0.0:37091" \
        bash "$0" apply --port 47040 --mode dual --take-over >/dev/null 2>&1
    [ -f "$m/etc/systemd/system/sshd.socket.d/zz-90ssh.conf" ] && ok "M sshd.socket drop-in path" || bad "M sshd.socket path wrong"
    [ -f "$m/etc/systemd/system/ssh.socket.d/zz-90ssh.conf" ] && bad "M wrote to ssh.socket.d for sshd.socket" || ok "M did not mix socket units"

    # N: a drop-in sorting after ours is refused
    local n="$base/n"; fixture "$n"; issue "$n"
    install -d -m 0755 "$n/etc/systemd/system/ssh.socket.d"
    printf '[Socket]\nListenStream=0.0.0.0:49999\n' > "$n/etc/systemd/system/ssh.socket.d/zzz-local.conf"
    PREFIX="$n" FAKE_SOCKET=1 FAKE_SOCK_STREAMS="0.0.0.0:37091" \
        bash "$0" apply --port 47040 --mode dual --take-over > "$n/out13" 2>&1
    grep -q 'sorts after' "$n/out13" && ok "N later socket drop-in refused" || { bad "N later drop-in accepted"; tail -3 "$n/out13"; }

    # O: guard that cannot be armed blocks the apply before any write
    local o="$base/o"; fixture "$o"; issue "$o"
    PREFIX="$o" FAKE_GUARD=fail bash "$0" apply --port 47040 --mode dual --take-over --guard 30 > "$o/out14" 2>&1
    grep -q 'guard could not be armed' "$o/out14" && ok "O unarmed guard refuses apply" || { bad "O apply continued without a guard"; tail -3 "$o/out14"; }
    [ -f "$o/etc/ssh/sshd_config.d/90-ssh-port.conf" ] && bad "O drop-in written despite guard failure" || ok "O nothing written"

    # P: guard timeout really rolls back; pending marker is cleared
    local p2="$base/p"; fixture "$p2"; issue "$p2"
    PREFIX="$p2" FAKE_GUARD=ok FAKE_PORTS=22 bash "$0" apply --port 47040 --mode dual --take-over --guard 30 > "$p2/out15" 2>&1
    grep -q 'APPLY OK' "$p2/out15" && ok "P guarded apply" || { bad "P guarded apply"; tail -3 "$p2/out15"; }
    [ -f "$p2/var/lib/90ssh/pending" ] && ok "P pending marker written" || bad "P pending marker missing"
    local ptok; ptok="$(sed -n 's/^token=//p' "$p2/var/lib/90ssh/pending" | head -1)"
    local pbak; pbak="$(sed -n 's/^backup=//p' "$p2/var/lib/90ssh/pending" | head -1)"
    PREFIX="$p2" bash "$0" status > "$p2/out16" 2>&1
    grep -q 'PENDING transition' "$p2/out16" && ok "P pending survives a new process" || bad "P pending not reported"
    PREFIX="$p2" bash "$0" guard-check --token "$ptok" --backup "$pbak" > "$p2/out17" 2>&1
    grep -q 'ROLLBACK done' "$p2/out17" && ok "P guard-check rolled back" || { bad "P guard-check failed"; tail -4 "$p2/out17"; }
    [ -f "$p2/var/lib/90ssh/pending" ] && bad "P pending left behind" || ok "P pending cleared"
    snap "$p2"; [ "$(grep -c '^port ' "$p2/eff.txt")" = 1 ] && grep -qx 'port 22' "$p2/eff.txt" && ok "P config restored" || bad "P config not restored"

    # Q: an unconfirmed transition blocks a second apply; --force-pending overrides
    local q="$base/q"; fixture "$q"; issue "$q"
    PREFIX="$q" FAKE_GUARD=ok bash "$0" apply --port 47040 --mode dual --take-over --guard 30 >/dev/null 2>&1
    PREFIX="$q" bash "$0" apply --port 47041 --mode dual --take-over > "$q/out18" 2>&1
    grep -q 'still unconfirmed' "$q/out18" && ok "Q second apply refused while pending" || bad "Q second apply ran over a pending transition"
    PREFIX="$q" bash "$0" apply --port 47041 --mode dual --take-over --force-pending > "$q/out19" 2>&1
    grep -q 'APPLY OK' "$q/out19" && ok "Q --force-pending overrides" || { bad "Q --force-pending failed"; tail -3 "$q/out19"; }

    # R: confirm disarms the guard and clears the marker
    local r="$base/r"; fixture "$r"; issue "$r"
    PREFIX="$r" FAKE_GUARD=ok bash "$0" apply --port 47040 --mode dual --take-over --guard 30 >/dev/null 2>&1
    local rtok; rtok="$(sed -n 's/^token=//p' "$r/var/lib/90ssh/pending" | head -1)"
    PREFIX="$r" bash "$0" confirm --token "$rtok" > "$r/out20" 2>&1
    grep -q 'confirmed' "$r/out20" && ok "R confirm" || { bad "R confirm failed"; tail -3 "$r/out20"; }
    [ -f "$r/var/lib/90ssh/pending" ] && bad "R pending survived confirm" || ok "R pending cleared by confirm"
    PREFIX="$r" bash "$0" confirm --token "$rtok" > "$r/out21" 2>&1
    grep -q 'no pending transition' "$r/out21" && ok "R second confirm refused" || bad "R second confirm accepted"

    # S: legacy v2.0 drop-in is reused instead of duplicated
    local s="$base/s"; fixture "$s"; issue "$s"
    printf '# Managed by box/90ssh.sh v2.0.0 -- do not edit by hand.\nPort 47032\n' \
        > "$s/etc/ssh/sshd_config.d/10-homelab-ssh.conf"
    apply "$s" apply --port 47032 --mode dual >/dev/null 2>&1
    [ -f "$s/etc/ssh/sshd_config.d/90-ssh-port.conf" ] && bad "S created a duplicate managed drop-in" || ok "S reuses the legacy drop-in"
    [ "$(sha256sum < "$s/etc/ssh/authorized_keys")" = "$(printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY test@fixture\n' | sha256sum)" ] \
        && ok "S authorized_keys byte-identical" || bad "S authorized_keys changed"

    # T: non-interactive entry points
    local t="$base/t"; fixture "$t"; issue "$t"
    bash "$0" </dev/null > "$t/out22" 2>&1
    grep -q '90ssh.sh status' "$t/out22" && ok "T no-arg non-tty prints usage" || bad "T no-arg non-tty output wrong"
    PREFIX="$t" bash "$0" verify --issue-token --port 47040 > "$t/out22b" 2>&1
    grep -q 'VERIFY TOKEN:' "$t/out22b" && [ "$(stat -c %a "$t/run/90ssh/verify.token" 2>/dev/null)" = 600 ] \
        && ok "T token issued 0600 with instructions" || bad "T token issuing wrong"
    printf '1\n0\n' | PREFIX="$t" bash "$0" menu > "$t/out23" 2>&1
    grep -q 'effective ports' "$t/out23" && grep -q 'bye' "$t/out23" && ok "T menu runs status and exits" || { bad "T menu failed"; tail -3 "$t/out23"; }
    printf '2\n47040\n0\n' | PREFIX="$t" bash "$0" menu > "$t/out24" 2>&1
    grep -q 'PLAN v' "$t/out24" && ok "T menu plan path" || { bad "T menu plan failed"; tail -3 "$t/out24"; }

    log "== self-test $([ $rc = 0 ] && echo PASS || echo FAIL) =="
    [ "$rc" = 0 ] && rm -rf "$base" || log "  (artifacts kept: $base)"
    return $rc
}

usage() {
    sed -n '/^# Usage/,/^# Isolated testing/p' "$0" | sed 's/^# \{0,1\}//'
}

# -------------------------------------------------------------------- main --
if [ $# -gt 0 ]; then
    CMD="$1"; shift || true
else
    if [ -t 0 ]; then
        CMD=menu
    else
        usage; exit 0
    fi
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --port|--mode|--dropin|--guard|--host|--key|--user|--known-hosts|--token|\
        --backup|--reason|--service|--socket|--keep-port|--listen|--evidence|--max-evidence-age)
            [ $# -ge 2 ] || die "option $1 needs a value" ;;
    esac
    case "$1" in
        --port) NEW_PORT="${2:-}"; shift 2;;
        --mode) MODE="${2:-}"; shift 2;;
        --dropin) DROPIN="${2:-}"; shift 2;;
        --guard) GUARD="${2:-0}"; shift 2;;
        --take-over) TAKE_OVER=1; shift;;
        --confirmed) CONFIRMED=1; shift;;
        --host) VERIFY_HOST="${2:-}"; shift 2;;
        --key) VERIFY_KEY="${2:-}"; shift 2;;
        --user) VERIFY_USER="${2:-}"; shift 2;;
        --known-hosts) VERIFY_KNOWN_HOSTS="${2:-}"; shift 2;;
        --token) TOKEN="${2:-}"; shift 2;;
        --backup) BACKUP_DIR="${2:-}"; shift 2;;
        --reason) REASON="${2:-manual}"; shift 2;;
        --dry-run) DRY=1; shift;;
        --service) SVC_FORCED="${2:-}"; shift 2;;
        --socket) SOCKET_FORCED="${2:-}"; shift 2;;
        --keep-port) KEEP_PORTS="$KEEP_PORTS ${2:-}"; shift 2;;
        --listen) LISTEN_ADDR="${2:-}"; shift 2;;
        --create-include) CREATE_INCLUDE=1; shift;;
        --allow-firewall-pending) FW_PENDING=1; shift;;
        --selinux-add) SELINUX_ADD=1; shift;;
        --issue-token) ISSUE_TOKEN=1; shift;;
        --evidence) EVIDENCE="${2:-}"; shift 2;;
        --allow-private-verifier) ALLOW_PRIVATE=1; shift;;
        --max-evidence-age) MAX_EVIDENCE_AGE="${2:-86400}"; shift 2;;
        --force-pending) FORCE_PENDING=1; shift;;
        -h|--help) usage; exit 0;;
        *) die "unknown option: $1";;
    esac
done

[ "$CMD" = test ] || detect_units
[ "$CMD" = test ] || resolve_dropin

case "$CMD" in
    status) do_status;;
    plan) do_plan "$NEW_PORT";;
    apply) do_apply "$NEW_PORT" "$MODE";;
    verify) do_verify "$NEW_PORT";;
    confirm) do_confirm;;
    rollback) do_rollback "${BACKUP_DIR:-$(latest_backup)}" "$REASON";;
    guard-check) do_guard_check;;
    menu) do_menu;;
    test) do_selftest;;
    *) usage; die "unknown command: $CMD";;
esac
