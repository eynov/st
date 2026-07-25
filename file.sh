#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
    cat <<'EOF'
Usage:
  file.sh sb --source-dir /path/to/st/sb [--endpoint host] [--yes]
  file.sh sb --archive-url HTTPS_URL --archive-sha256 SHA256 [--endpoint host] [--yes]
  file.sh PROJECT --source-dir /path/to/PROJECT [--command FILE]

The production installer intentionally has no unpinned "latest/main" default.
An archive URL must be HTTPS and its SHA256 must be supplied explicitly.
EOF
}

generic_install() (
    local project="$1"
    shift
    local source_dir="" command_name="" base target stage previous="" command_root=""
    [[ "$project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        printf 'ERROR: invalid project name\n' >&2
        return 64
    }
    while (($#)); do
        case "$1" in
            --source-dir)
                (($# >= 2)) || { printf 'ERROR: --source-dir requires a value\n' >&2; return 64; }
                source_dir="$(cd "$2" && pwd)"
                shift 2
                ;;
            --command)
                (($# >= 2)) || { printf 'ERROR: --command requires a value\n' >&2; return 64; }
                command_name="$2"
                shift 2
                ;;
            --yes) shift ;;
            *) printf 'ERROR: unsupported generic option: %s\n' "$1" >&2; return 64 ;;
        esac
    done
    [[ -d "$source_dir" ]] || {
        printf 'ERROR: generic installation requires --source-dir\n' >&2
        return 64
    }
    [[ -z "$command_name" ||
       ( "$command_name" != */* && -f "$source_dir/$command_name" ) ]] || {
        printf 'ERROR: --command must name a top-level source file\n' >&2
        return 64
    }

    base="${GENERIC_INSTALL_ROOT:-/opt}"
    target="${base}/${project}"
    if [[ -n "$command_name" ]]; then
        command_root="${GENERIC_COMMAND_ROOT:-/usr/local/bin}"
        [[ ! -e "$command_root/${command_name%.*}" ||
           -L "$command_root/${command_name%.*}" ]] || {
            printf 'ERROR: command destination is not a managed symlink\n' >&2
            return 1
        }
    fi
    mkdir -p -- "$base" || return 1
    stage=$(mktemp -d "${base}/.${project}.stage.XXXXXX") || return 1
    trap '[[ -z "${stage:-}" ]] || rm -rf -- "$stage"' EXIT
    cp -a -- "$source_dir/." "$stage/" || return 1
    find "$stage" -type f \( -name '*.sh' -o -name '*.py' -o ! -name '*.*' \) \
      -exec chmod u+x {} + || return 1
    if [[ -e "$target" ]]; then
        previous="${base}/.${project}.previous.$$"
        [[ ! -e "$previous" ]] || return 1
        mv -- "$target" "$previous" || return 1
    fi
    if ! mv -- "$stage" "$target"; then
        [[ -z "$previous" ]] || mv -- "$previous" "$target"
        return 1
    fi
    stage=""
    if [[ -x "$target/install.sh" ]] && ! "$target/install.sh"; then
        rm -rf -- "$target"
        [[ -z "$previous" ]] || mv -- "$previous" "$target"
        return 1
    fi
    if [[ -n "$command_name" ]]; then
        mkdir -p -- "$command_root" || return 1
        if ! ln -sfn "$target/$command_name" "$command_root/${command_name%.*}"; then
            rm -rf -- "$target"
            [[ -z "$previous" ]] || mv -- "$previous" "$target"
            return 1
        fi
    fi
    [[ -z "$previous" ]] || rm -rf -- "$previous"
    printf 'OK: %s installation completed\n' "$project"
)

[[ $EUID -eq 0 || "${SB_TEST_MODE:-false}" == "true" ]] || {
    printf 'ERROR: installation requires root\n' >&2
    exit 1
}

PROJECT="${1:-}"
[[ -n "$PROJECT" ]] || { usage >&2; exit 64; }
shift
if [[ "$PROJECT" != "sb" ]]; then
    generic_install "$PROJECT" "$@"
    exit
fi

SOURCE_DIR=""
ARCHIVE_URL=""
ARCHIVE_SHA256=""
ENDPOINT=""
YES=false
ALLOW_PRIVATE=false
LISTEN_MODE=""

while (($#)); do
    case "$1" in
        --source-dir) (($# >= 2)) || { printf 'ERROR: --source-dir requires a value\n' >&2; exit 64; }
            SOURCE_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --archive-url) (($# >= 2)) || { printf 'ERROR: --archive-url requires a value\n' >&2; exit 64; }
            ARCHIVE_URL="$2"; shift 2 ;;
        --archive-sha256) (($# >= 2)) || { printf 'ERROR: --archive-sha256 requires a value\n' >&2; exit 64; }
            ARCHIVE_SHA256="$2"; shift 2 ;;
        --endpoint) (($# >= 2)) || { printf 'ERROR: --endpoint requires a value\n' >&2; exit 64; }
            ENDPOINT="$2"; shift 2 ;;
        --listen-mode) (($# >= 2)) || { printf 'ERROR: --listen-mode requires a value\n' >&2; exit 64; }
            LISTEN_MODE="$2"; shift 2 ;;
        --allow-private-endpoint) ALLOW_PRIVATE=true; shift ;;
        --yes) YES=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 64 ;;
    esac
done

TMP_DIR=""
cleanup() {
    [[ -n "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
    return 0
}
trap cleanup EXIT

archive_paths_safe() {
    local archive="$1" entry
    while IFS= read -r entry; do
        [[ "$entry" != /* && "$entry" != ../* &&
           "$entry" != *"/../"* && "$entry" != *"/.." ]] || return 1
    done < <(tar -tzf "$archive")
}

if [[ -n "$SOURCE_DIR" ]]; then
    [[ -z "$ARCHIVE_URL" && -z "$ARCHIVE_SHA256" ]] || {
        printf 'ERROR: choose either --source-dir or --archive-url\n' >&2
        exit 64
    }
else
    [[ "$ARCHIVE_URL" == https://* ]] || {
        printf 'ERROR: --archive-url must use HTTPS\n' >&2
        exit 64
    }
    [[ "$ARCHIVE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || {
        printf 'ERROR: --archive-sha256 is required\n' >&2
        exit 64
    }
    TMP_DIR=$(mktemp -d)
    curl -fL --retry 3 --connect-timeout 10 --max-time 300 \
      "$ARCHIVE_URL" -o "$TMP_DIR/source.tar.gz"
    printf '%s  %s\n' "${ARCHIVE_SHA256,,}" "$TMP_DIR/source.tar.gz" |
      sha256sum -c -
    archive_paths_safe "$TMP_DIR/source.tar.gz" || {
        printf 'ERROR: archive contains an unsafe path\n' >&2
        exit 1
    }
    mkdir "$TMP_DIR/source"
    tar -xzf "$TMP_DIR/source.tar.gz" -C "$TMP_DIR/source" --no-same-owner
    SOURCE_DIR=$(find "$TMP_DIR/source" -type d -path '*/sb' -print -quit)
fi

[[ -x "$SOURCE_DIR/install.sh" ]] || {
    printf 'ERROR: real sb installer is missing: %s/install.sh\n' "$SOURCE_DIR" >&2
    exit 1
}

args=(--source "$SOURCE_DIR")
[[ "$YES" == "true" ]] && args+=(--yes)
[[ -n "$ENDPOINT" ]] && args+=(--endpoint "$ENDPOINT")
[[ -n "$LISTEN_MODE" ]] && args+=(--listen-mode "$LISTEN_MODE")
[[ "$ALLOW_PRIVATE" == "true" ]] && args+=(--allow-private-endpoint)
"$SOURCE_DIR/install.sh" "${args[@]}"

printf 'OK: sb installation and verification completed\n'
