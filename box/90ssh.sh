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
# v2.1.0 portability options (v2.1 keeps every v2.0 interface):
#   --service ssh|sshd|auto   unit that owns sshd (auto detects sshd.service on RHEL)
#   --socket auto|none|NAME   socket unit to drive (auto detects ssh.socket)
#   --keep-port N             extra port to keep in dual mode (repeatable);
#                             defaults to every port currently effective, NOT 22
#   --listen ADDR|all         final-mode listen address (default 0.0.0.0; all = 0.0.0.0 + ::)
#   --create-include          append Include ... when sshd_config has none (explicit only)
#   --allow-firewall-pending  proceed although the host firewall has no rule for the new port
#   --selinux-add             run semanage for the new port when SELinux is enforcing
#
# Isolated testing: set PREFIX=/tmp/fake and the script operates on
# $PREFIX/etc/ssh, never calls systemctl/ss, and validates with `sshd -t -f`.
set -uo pipefail

VER=2.1.0
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
SVC_FORCED=""
SOCKET_UNIT=""
SOCKET_FORCED=""
LISTEN_ADDR="0.0.0.0"
KEEP_PORTS=""
CREATE_INCLUDE=0
FW_PENDING=0
SELINUX_ADD=0
KEPT=""
SELF="$0"
STATE_DIR="$PREFIX/var/lib/90ssh"

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

# v2.1: Debian/Ubuntu ship ssh.service, RHEL-family ships sshd.service.
detect_units() {
    [ -n "$SVC_FORCED" ] && SVC="$SVC_FORCED"
    if [ -z "$SVC_FORCED" ] && ! fake; then
        svc_active ssh || { svc_active sshd && SVC=sshd; }
        if ! systemctl cat "$SVC.service" >/dev/null 2>&1; then
            local s
            for s in ssh sshd; do
                systemctl cat "$s.service" >/dev/null 2>&1 && { SVC="$s"; break; }
            done
        fi
    fi
    SOCKET_UNIT=""
    case "${SOCKET_FORCED:-auto}" in
        none) return 0 ;;
        auto) ;;
        *)    SOCKET_UNIT="$SOCKET_FORCED"; return 0 ;;
    esac
    fake && return 0
    local s
    for s in ssh.socket sshd.socket; do
        systemctl cat "$s" >/dev/null 2>&1 || continue
        svc_active "$s" && { SOCKET_UNIT="$s"; break; }
    done
}

# Active socket listeners.  systemd exposes them as "Listen" (newer) or
# "ListenStream" (older); both carry "<addr>:<port>".
sock_ports() {
    [ -n "$SOCKET_UNIT" ] || return 0
    systemctl show -p Listen --value "$SOCKET_UNIT" 2>/dev/null | tr ' ' '\n' | sed -n 's/.*:\([0-9][0-9]*\).*/\1/p'
    systemctl show -p ListenStream --value "$SOCKET_UNIT" 2>/dev/null | tr ' ' '\n' | sed 's/.*://'
}

socket_active() { fake && { [ -n "${FAKE_SOCKET:-}" ] && return 0; return 1; }; [ -n "$SOCKET_UNIT" ] && svc_active "$SOCKET_UNIT"; }

# Ports that are effective right now (config + active socket), minus the target.
# This is what dual mode must preserve; v2.0 wrongly assumed it was always 22.
current_ports() {
    {
        if fake; then
            sshd_dump "" 2>/dev/null | awk '$1=="port"{print $2}'
            printf '%s\n' ${FAKE_PORTS:-}
        else
            sshd_dump "" 2>/dev/null | awk '$1=="port"{print $2}'
            sock_ports
        fi
        printf '%s\n' $KEEP_PORTS
    } | grep -E '^[0-9]+$' | grep -vx "${NEW_PORT:-0}" | sort -un | tr '\n' ' '
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

other_socket_dropins() {
    local f
    for f in "$SOCK_DIR"/*.conf; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = zz-90ssh.conf ] && continue
        grep -qE '^[[:space:]]*ListenStream=' "$f" && printf '%s\n' "$f"
    done
}

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
            if [ "$LISTEN_ADDR" = all ]; then
                echo "ListenAddress 0.0.0.0"
                echo "ListenAddress ::"
            else
                echo "ListenAddress $LISTEN_ADDR"
            fi
        else
            echo "# mode: dual (transition; keeps current port(s) until confirmed)"
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

# One ListenStream line per address/port.  Dual mode keeps both families for
# every retained port so an IPv6 client is not cut off by the transition.
socket_streams() {
    local p="$1" mode="$2" k a
    if [ "$mode" = final ]; then
        case "$LISTEN_ADDR" in
            all)   echo "ListenStream=0.0.0.0:$p"; echo "ListenStream=[::]:$p" ;;
            *:*)   echo "ListenStream=[$LISTEN_ADDR]:$p" ;;
            *)     echo "ListenStream=$LISTEN_ADDR:$p" ;;
        esac
        return
    fi
    for k in $KEPT $p; do
        echo "ListenStream=0.0.0.0:$k"
        echo "ListenStream=[::]:$k"
    done
}

write_socket_override() {
    local p="$1" mode="$2" f="$SOCK_DIR/zz-90ssh.conf" tmp
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
        if socket_active; then
            run systemctl restart "$SOCKET_UNIT" || run systemctl restart "$SVC"
        else
            run systemctl reload "$SVC" || run systemctl restart "$SVC"
        fi
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
    if have_include; then
        log "  include: present"
    elif [ "$CREATE_INCLUDE" = 1 ]; then
        log "  include: absent, appending (--create-include)"
        run sh -c "printf '\n# Added by box/90ssh.sh\nInclude %s/*.conf\n' '$D_DIR' >> '$S_CFG'"
    else
        die "apply: $S_CFG has no 'Include $D_DIR/*.conf' (rerun with --create-include to append it)"
    fi
    if grep -qE '^[[:space:]]*Match[[:space:]]+' "$S_CFG" && \
       [ "$(grep -nE '^[[:space:]]*Match[[:space:]]+' "$S_CFG" | head -1 | cut -d: -f1)" -lt \
         "$(grep -nE '^[[:space:]]*Include[[:space:]]+' "$S_CFG" | head -1 | cut -d: -f1)" ]; then
        die "apply: sshd_config has a Match block before the Include line; a drop-in there would be Match-scoped"
    fi
    KEPT="$(current_ports)"
    [ -n "$KEPT" ] || KEPT="22"
    log "  keeping port(s): $KEPT  target: $p"
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
    if fw_drop_policy && ! fw_allows_port "$p"; then
        warn "host firewall drops input and has no accept rule for tcp/$p"
        if [ "$FW_PENDING" != 1 ]; then
            if [ "$mode" = final ]; then
                die "apply: open tcp/$p in the host firewall and the provider security group first, then rerun with --allow-firewall-pending"
            fi
            warn "dual mode keeps the current port, but $p will be unreachable until the firewall/security group allows it"
        fi
    fi
    if selinux_blocked "$p"; then
        if [ "$SELINUX_ADD" = 1 ]; then
            log "  selinux: adding tcp/$p to ssh_port_t"
            run sh -c "semanage port -a -t ssh_port_t -p tcp $p 2>/dev/null || semanage port -m -t ssh_port_t -p tcp $p"
        elif [ "$mode" = final ]; then
            die "apply: SELinux is enforcing and tcp/$p is not in ssh_port_t (rerun with --selinux-add)"
        else
            warn "SELinux enforcing: tcp/$p is not in ssh_port_t; the new listener may be denied"
        fi
    fi
    local od; od="$(other_socket_dropins)"
    if [ -n "$od" ]; then
        printf '%s\n' "$od" | sed 's/^/  other socket drop-in: /'
        warn "another ssh.socket drop-in sets ListenStream; zz-90ssh.conf is ordered last but review the files above"
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
            systemctl daemon-reload && systemctl restart "$SOCKET_UNIT" || { do_rollback "$dir" "socket-restart-failed"; return 4; }
        else
            systemctl reload "$SVC" || systemctl restart "$SVC" || { do_rollback "$dir" "reload-failed"; return 4; }
        fi
        sleep 2
    fi

    log "== post-checks =="
    if [ "$DRY" != 1 ] && ! fake; then
        if ! port_listening "$p"; then warn "new port not listening -> rollback"; do_rollback "$dir" "new-port-missing"; return 5; fi
        if [ "$mode" = "dual" ]; then
            local k
            for k in $KEPT; do
                if ! port_listening "$k"; then
                    warn "previous port $k lost during transition -> rollback"
                    do_rollback "$dir" "old-port-lost"; return 5
                fi
            done
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
        install -d -m 0700 /run/90ssh "$STATE_DIR"
        rm -f "/run/90ssh/$TOKEN.ok"
        SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
        printf 'token=%s\ndeadline=%s\nbackup=%s\nport=%s\nmode=%s\n' \
            "$TOKEN" "$(( $(date +%s) + GUARD ))" "$dir" "$p" "$mode" > "$STATE_DIR/pending"
        if systemd-run --unit="90ssh-guard-$TOKEN" --on-active="$GUARD" --collect \
            --description="90ssh safety net ($p)" \
            "$SELF" guard-check --token "$TOKEN" --backup "$dir" >/dev/null 2>&1; then
            log "GUARD armed: ${GUARD}s (confirm with: 90ssh.sh confirm --token $TOKEN)"
        else
            warn "guard could not be armed; pending marker kept in $STATE_DIR/pending"
        fi
    fi
    return 0
}

do_confirm() {
    [ -n "$TOKEN" ] || die "confirm: --token required"
    install -d -m 0700 /run/90ssh
    : > "/run/90ssh/$TOKEN.ok"
    systemctl stop "90ssh-guard-$TOKEN.timer" 2>/dev/null || true
    systemctl reset-failed "90ssh-guard-$TOKEN.service" "90ssh-guard-$TOKEN.timer" 2>/dev/null || true
    rm -f "$STATE_DIR/pending"
    log "confirmed: guard for $TOKEN disarmed"
}

do_guard_check() {
    [ -n "$TOKEN" ] || die "guard-check: --token required"
    if [ -f "/run/90ssh/$TOKEN.ok" ]; then log "guard $TOKEN: confirmed, standing down"; rm -f "$STATE_DIR/pending"; exit 0; fi
    logger -t 90ssh "guard $TOKEN expired without confirmation -> rolling back"
    dir="$BACKUP_DIR"; [ -n "$dir" ] || dir="$(latest_backup)"
    do_rollback "$dir" "guard-timeout-$TOKEN"
    rm -f "$STATE_DIR/pending"
}

# ----------------------------------------------------------------- report ---
do_status() {
    log "90ssh.sh v$VER  host=$(hostname)  mode=$MODE"
    log "config: $S_CFG"
    log "service: $SVC.service (unit: $(svc_enabled_str)/$(svc_active_str))  socket: ${SOCKET_UNIT:-none}"
    log "managed drop-in: $(managed_path) $([ -f "$(managed_path)" ] && echo '(present)' || echo '(absent)')"
    [ -f "$(managed_path)" ] && sed 's/^/  | /' "$(managed_path)"
    log "include present: $(have_include && echo yes || echo NO)"
    log "effective port(s): [$(current_ports)]"
    if [ -f "$STATE_DIR/pending" ]; then
        log "PENDING transition: $(tr '\n' ' ' < "$STATE_DIR/pending")"
        log "  (a guard rollback may not have run: check 'rollback --backup <dir>' if the change was not confirmed)"
    fi
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
    log "  current: ssh ports=[$(current_ports)] socket=$(socket_state)"
    log "  target : port $p ($MODE$([ "$MODE" = dual ] && echo ", keeping [$(current_ports)]" || echo ", listen $LISTEN_ADDR"))"
    log "  drop-in: $(managed_path)"
    local fp; fp="$(foreign_port_lines)"
    if [ -n "$fp" ]; then printf '%s\n' "$fp" | sed 's/^/  foreign: /'; else log "  foreign Port directives: none"; fi
    log "  writes: managed drop-in"
    socket_active && log "  writes: $SOCK_DIR/zz-90ssh.conf (socket is active on this host)"
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
    grep -qx 'port 2222' "$e/eff.txt" && ok "E 2222 kept during transition" || bad "E 2222 dropped during dual"
    apply "$e" apply --port 47032 --mode final --confirmed > "$e/out7"
    snap "$e"
    grep -qx 'port 2222' "$e/eff.txt" && bad "E 2222 survived final" || ok "E 2222 dropped in final"

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

    applyp() { local d="$1" p="$2"; shift 2; PREFIX="$d" FAKE_PORTS="$p" bash "$0" "$@" 2>&1; }

    # H: VPS-shaped host whose current port is 37091, not 22
    local h="$base/h"; fixture "$h"
    printf 'Port 37091\n' > "$h/etc/ssh/sshd_config.d/99-foreign.conf"
    applyp "$h" "37091" apply --port 47040 --mode dual --take-over > "$h/out"
    grep -q 'APPLY OK' "$h/out" && ok "H dual apply on 37091 host" || { bad "H dual apply"; tail -3 "$h/out"; }
    grep -qx 'Port 37091' "$h/etc/ssh/sshd_config.d/10-homelab-ssh.conf" \
        && ok "H keeps current port 37091" || bad "H current port 37091 not kept"
    grep -qx 'Port 22' "$h/etc/ssh/sshd_config.d/10-homelab-ssh.conf" \
        && bad "H added port 22 to a 37091 host" || ok "H does not invent port 22"
    snap "$h"
    grep -qx 'port 37091' "$h/eff.txt" && ok "H 37091 effective" || bad "H 37091 lost"
    grep -qx 'port 47040' "$h/eff.txt" && ok "H 47040 effective" || bad "H 47040 missing"

    # I: socket-activated host (Ubuntu style), override must be ordered last
    local i="$base/i"; fixture "$i"
    PREFIX="$i" FAKE_PORTS=37091 FAKE_SOCKET=1 bash "$0" apply --port 47040 --mode dual --take-over >/dev/null 2>&1
    local so="$i/etc/systemd/system/ssh.socket.d/zz-90ssh.conf"
    [ -f "$so" ] && ok "I socket override written as zz-90ssh.conf" || bad "I socket override missing"
    grep -qx 'ListenStream=0.0.0.0:37091' "$so" 2>/dev/null && ok "I keeps IPv4 37091" || bad "I IPv4 37091 missing"
    grep -qx 'ListenStream=\[::\]:37091' "$so" 2>/dev/null && ok "I keeps IPv6 37091" || bad "I IPv6 37091 missing"
    grep -qx 'ListenStream=0.0.0.0:47040' "$so" 2>/dev/null && ok "I new port in socket" || bad "I new port missing"

    # J: final mode with --listen all keeps both families
    local j="$base/j"; fixture "$j"
    applyp "$j" "" apply --port 47040 --mode final --confirmed --listen all >/dev/null 2>&1
    snap "$j"
    grep -qx 'listenaddress 0.0.0.0:47040' "$j/eff.txt" && grep -qx 'listenaddress \[::\]:47040' "$j/eff.txt" \
        && ok "J --listen all binds IPv4+IPv6" || bad "J --listen all incomplete"

    # K: RHEL-style service name is selectable
    local k="$base/k"; fixture "$k"
    local kout; kout="$(PREFIX="$k" bash "$0" status --service sshd 2>&1)"
    case "$kout" in *"service: sshd.service"*) ok "K --service sshd";; *) bad "K --service sshd not honoured: $(printf '%s' "$kout" | head -2 | tr '\n' ' ')";; esac

    # L: no Include + --create-include appends one
    local l="$base/l"; install -d -m 0755 "$l/etc/ssh"; ssh-keygen -q -t ed25519 -N '' -f "$l/hk" >/dev/null 2>&1
    printf 'Port 22\nHostKey %s/hk\n' "$l" > "$l/etc/ssh/sshd_config"
    applyp "$l" "" apply --port 47040 --mode dual --create-include --take-over > "$l/out"
    grep -q 'APPLY OK' "$l/out" && grep -q "^Include $l/etc/ssh/sshd_config.d/\*\.conf" "$l/etc/ssh/sshd_config" \
        && ok "L --create-include works" || { bad "L --create-include failed"; tail -3 "$l/out"; }

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
        --service) SVC_FORCED="$2"; shift 2;;
        --socket) SOCKET_FORCED="$2"; shift 2;;
        --keep-port) KEEP_PORTS="$KEEP_PORTS $2"; shift 2;;
        --listen) LISTEN_ADDR="$2"; shift 2;;
        --create-include) CREATE_INCLUDE=1; shift;;
        --allow-firewall-pending) FW_PENDING=1; shift;;
        --selinux-add) SELINUX_ADD=1; shift;;
        *) die "unknown option: $1";;
    esac
done

[ "$CMD" = test ] || detect_units

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
