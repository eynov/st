#!/usr/bin/env bash
# Guard against safety-critical commands that rely on implicit errexit.
#
# Why this exists: sb's library functions are routinely called from conditional
# contexts (`if fn; then`, `fn || return`, `! fn`, `fn && ...`). Bash disables
# errexit inside a function invoked that way, so a bare `mv`/`ln`/`cp` in the
# callee silently continues after a failure. Both High findings in the previous
# review were exactly this bug, so the pattern gets a standing check.
#
# Scope and limits:
#   * Only function bodies in production files are analysed. A statement at the
#     top level of a `set -e` script is not subject to the conditional-context
#     trap, and the test driver is not shipped.
#   * Only commands whose failure means the intended state change did NOT
#     happen are treated as blocking: mkdir, cp, mv, ln, chmod, chown, install,
#     tar, sha256sum. Best-effort cleanup (rm, touch, rmdir) is reported
#     separately as advisory, because a failed unlink cannot fabricate success.
#   * This is a heuristic. It cannot prove correctness and is NOT a substitute
#     for reading the code; it exists to stop the specific regression from
#     coming back unnoticed.
#
# An intentional exception carries a trailing `# errexit-audit: ok <reason>`.
set -Eeuo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$APP_DIR/.." && pwd)"

BLOCKING='mkdir|cp|mv|ln|chmod|chown|install|tar|sha256sum'
ADVISORY='rm|rmdir|touch'

FILES=(
    "$ROOT_DIR/file.sh"
    "$APP_DIR/sb"
    "$APP_DIR/install.sh"
    "$APP_DIR"/core/*.sh
    "$APP_DIR"/protocols/*.sh
)

blocking_hits=0
advisory_hits=0

for file in "${FILES[@]}"; do
    [[ -f "$file" ]] || continue
    lineno=0
    in_function=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # Track function bodies: `name() {` / `name() (` opened at column 0 and
        # closed by `}` / `)` at column 0, which is this codebase's style.
        if ((in_function == 0)); then
            [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*[\{\(] ]] && in_function=1
            continue
        fi
        if [[ "$line" =~ ^[\}\)][[:space:]]*$ ]]; then
            in_function=0
            continue
        fi

        stripped="${line#"${line%%[![:space:]]*}"}"
        [[ "$stripped" == \#* ]] && continue
        [[ "$line" == *"errexit-audit: ok"* ]] && continue
        # Status consumed on the same line, or statement continues.
        [[ "$line" == *"||"* || "$line" == *"&&"* || "$line" == *"|"* ]] && continue
        [[ "$line" == *\\ ]] && continue
        # `if ! cmd`, `while cmd`, `until cmd` already test the status.
        [[ "$stripped" =~ ^(if|while|until|elif)[[:space:]] ]] && continue

        relative="${file#"$ROOT_DIR/"}"
        if [[ "$stripped" =~ ^(${BLOCKING})[[:space:]] ]]; then
            printf 'BLOCKING %s:%s: %s\n' "$relative" "$lineno" "$stripped" >&2
            blocking_hits=$((blocking_hits + 1))
        elif [[ "$stripped" =~ ^(${ADVISORY})[[:space:]] ]]; then
            printf 'advisory %s:%s: %s\n' "$relative" "$lineno" "$stripped" >&2
            advisory_hits=$((advisory_hits + 1))
        fi
    done <"$file"
done

printf 'errexit audit: %d blocking, %d advisory\n' "$blocking_hits" "$advisory_hits"
((blocking_hits == 0))
