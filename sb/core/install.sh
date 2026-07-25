#!/usr/bin/env bash

core_arch() {
    case "$("${SB_UNAME:-uname}" -m)" in
        x86_64) printf 'linux-amd64\n' ;;
        aarch64|arm64) printf 'linux-arm64\n' ;;
        *) err "unsupported CPU architecture: $("${SB_UNAME:-uname}" -m)"; return 1 ;;
    esac
}

core_expected_sha256() {
    local arch="$1"
    jq -er --arg version "$SB_CORE_VERSION" --arg arch "$arch" \
      '.versions[$version][$arch].sha256' "$SB_APP_DIR/checksums.json"
}

core_checksums_validate() {
    local actual
    actual=$(sha256sum "$SB_APP_DIR/checksums.json" | awk '{print $1}') || return 1
    [[ "$actual" == "$SB_CHECKSUMS_SHA256" ]] || {
        err "checksums.json integrity verification failed"
        return 1
    }
    jq -e --arg version "$SB_CORE_VERSION" '
      .schema_version==1 and
      (.versions[$version] | type=="object") and
      ([.versions[$version][] |
        (.url|startswith("https://github.com/SagerNet/sing-box/releases/download/v"+$version+"/")) and
        (.sha256|test("^[0-9a-f]{64}$")) and
        (.binary_sha256|test("^[0-9a-f]{64}$"))] | all)
    ' "$SB_APP_DIR/checksums.json" >/dev/null || {
        err "checksums.json schema or source validation failed"
        return 1
    }
}

core_expected_binary_sha256() {
    local arch="$1"
    jq -er --arg version "$SB_CORE_VERSION" --arg arch "$arch" \
      '.versions[$version][$arch].binary_sha256' "$SB_APP_DIR/checksums.json"
}

core_asset_url() {
    local arch="$1"
    jq -er --arg version "$SB_CORE_VERSION" --arg arch "$arch" \
      '.versions[$version][$arch].url' "$SB_APP_DIR/checksums.json"
}

core_installed_version() {
    [[ -x "$SB_BIN" ]] || return 1
    "$SB_BIN" version 2>/dev/null | awk 'NR==1 {print $3}' | sed 's/^v//'
}

core_installed_digest() {
    [[ -x "$SB_BIN" ]] || return 1
    sha256sum "$SB_BIN" | awk '{print $1}'
}

core_receipt_write() {
    local arch expected actual
    arch=$(core_arch) || return 1
    expected=$(core_expected_binary_sha256 "$arch") || return 1
    actual=$(core_installed_digest) || return 1
    [[ "$actual" == "$expected" ]] || return 1
    jq -n --arg version "$SB_CORE_VERSION" --arg arch "$arch" \
      --arg digest "$actual" --arg source "$(core_asset_url "$arch")" \
      --arg verified_at "$(now_iso)" '{
        schema_version:1,version:$version,architecture:$arch,
        binary_sha256:$digest,source:$source,verified_at:$verified_at
      }' | atomic_write "$SB_CORE_RECEIPT" 600
}

core_validate_installed() {
    local check_config="${1:-true}" arch expected actual version
    core_checksums_validate || return 1
    arch=$(core_arch) || return 1
    expected=$(core_expected_binary_sha256 "$arch") || return 1
    [[ -x "$SB_BIN" ]] || return 1
    actual=$(core_installed_digest) || return 1
    [[ "$actual" == "$expected" ]] || {
        err "installed sing-box binary digest mismatch"
        return 1
    }
    version=$(core_installed_version) || return 1
    [[ "$version" == "$SB_CORE_VERSION" ]] || return 1
    jq -e --arg version "$version" --arg arch "$arch" --arg digest "$actual" '
      .schema_version==1 and .version==$version and
      .architecture==$arch and .binary_sha256==$digest
    ' "$SB_CORE_RECEIPT" >/dev/null || {
        err "sing-box installation receipt is missing or inconsistent"
        return 1
    }
    if [[ "$check_config" == "true" && -f "$SB_CURRENT_CONFIG" ]]; then
        "$SB_BIN" check -c "$SB_CURRENT_CONFIG" || return 1
    fi
}

core_install_dependencies() {
    [[ "${SB_SKIP_PACKAGES:-false}" == "true" ]] && return 0
    local command missing=()
    for command in bash ca-certificates curl jq tar gzip openssl flock ss diff systemctl; do
        case "$command" in
            ca-certificates)
                [[ -r /etc/ssl/certs/ca-certificates.crt ||
                   -r /etc/pki/tls/certs/ca-bundle.crt ]] || missing+=("$command")
                ;;
            *) command -v "$command" >/dev/null 2>&1 || missing+=("$command") ;;
        esac
    done
    ((${#missing[@]} == 0)) && return 0
    command -v apt-get >/dev/null 2>&1 || {
        err "missing dependencies: ${missing[*]}; install them with the host package manager"
        return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      bash ca-certificates curl jq tar gzip openssl util-linux iproute2 diffutils systemd >/dev/null
}

core_stage_binary() (
    local destination="$1" arch sha binary_sha url archive extracted actual asset_dir
    core_checksums_validate || return 1
    arch=$(core_arch) || return 1
    sha=$(core_expected_sha256 "$arch") || return 1
    binary_sha=$(core_expected_binary_sha256 "$arch") || return 1
    url=$(core_asset_url "$arch") || return 1
    asset_dir="sing-box-${SB_CORE_VERSION}-${arch}"
    archive=$(mktemp)
    extracted=$(mktemp -d)
    trap 'rm -f -- "$archive"; rm -rf -- "$extracted"' EXIT

    if [[ -n "${SB_CORE_ARCHIVE:-}" ]]; then
        cp -- "$SB_CORE_ARCHIVE" "$archive"
    else
        curl -fL --retry 3 --connect-timeout 10 --max-time 300 "$url" -o "$archive" || return 1
    fi
    actual=$(sha256sum "$archive" | awk '{print $1}')
    if [[ "${SB_TEST_MODE:-false}" == "true" && -n "${SB_CORE_SHA256_OVERRIDE:-}" ]]; then
        sha="$SB_CORE_SHA256_OVERRIDE"
    fi
    [[ "$actual" == "$sha" ]] || {
        err "sing-box archive SHA256 mismatch"
        return 1
    }
    tar -tzf "$archive" | while IFS= read -r entry; do
        [[ "$entry" != /* && "$entry" != ../* && "$entry" != *"/../"* ]] ||
            exit 1
    done || {
        err "sing-box archive contains an unsafe path"
        return 1
    }
    tar -xzf "$archive" -C "$extracted" --no-same-owner \
      "${asset_dir}/sing-box" || return 1
    [[ -x "$extracted/${asset_dir}/sing-box" ]] ||
        chmod 700 "$extracted/${asset_dir}/sing-box"
    actual=$(sha256sum "$extracted/${asset_dir}/sing-box" | awk '{print $1}')
    [[ "$actual" == "$binary_sha" ]] || {
        err "staged sing-box binary SHA256 mismatch"
        return 1
    }
    [[ "$("$extracted/${asset_dir}/sing-box" version | awk 'NR==1 {print $3}' | sed 's/^v//')" == "$SB_CORE_VERSION" ]] || {
        err "staged sing-box reports an unexpected version"
        return 1
    }
    cp -- "$extracted/${asset_dir}/sing-box" "$destination"
    chmod 755 "$destination"
)

core_switch() (
    local mode="$1" current="" stage="" backup_bin="" backup_receipt="" bin_dir
    trap 'rm -f -- "${stage:-}" "${backup_bin:-}" "${backup_receipt:-}"' EXIT
    bin_dir=$(dirname "$SB_BIN")
    safe_mkdir "$bin_dir" 755
    [[ -x "$SB_BIN" ]] && current=$(core_installed_version)
    if [[ "$mode" == "install" && -n "$current" && "$current" != "$SB_CORE_VERSION" ]]; then
        err "sing-box $current exists; use 'sb core upgrade' for an explicit replacement"
        return 1
    fi

    stage=$(mktemp "${bin_dir}/.sing-box.stage.XXXXXX")
    core_stage_binary "$stage" || {
        rm -f "$stage"
        return 1
    }
    if [[ -f "$SB_CURRENT_CONFIG" ]]; then
        "$stage" check -c "$SB_CURRENT_CONFIG" || {
            rm -f "$stage"
            err "current configuration is incompatible with staged sing-box"
            return 1
        }
    fi
    if [[ -x "$SB_BIN" ]]; then
        backup_bin=$(mktemp "${bin_dir}/.sing-box.backup.XXXXXX")
        cp -a "$SB_BIN" "$backup_bin"
    fi
    if [[ -f "$SB_CORE_RECEIPT" ]]; then
        backup_receipt=$(mktemp "${SB_DATA_DIR}/.core-receipt.backup.XXXXXX")
        cp -- "$SB_CORE_RECEIPT" "$backup_receipt" || return 1
    fi
    if ! mv -fT "$stage" "$SB_BIN"; then
        rm -f "$stage" "$backup_bin"
        return 1
    fi
    if ! core_receipt_write || ! core_validate_installed false; then
        [[ -n "$backup_bin" ]] && mv -fT "$backup_bin" "$SB_BIN"
        if [[ -n "$backup_receipt" ]]; then
            mv -fT "$backup_receipt" "$SB_CORE_RECEIPT"
        else
            rm -f -- "$SB_CORE_RECEIPT"
        fi
        err "sing-box post-switch version verification failed; old binary restored"
        return 1
    fi
    rm -f "$backup_bin" "$backup_receipt"
    ok "sing-box $SB_CORE_VERSION installed and verified"
)

core_install() {
    if core_validate_installed true; then
        info "sing-box $SB_CORE_VERSION is already installed"
        return 0
    fi
    core_install_dependencies || return 1
    if [[ -x "$SB_BIN" &&
       "$(core_installed_version 2>/dev/null || true)" != "$SB_CORE_VERSION" ]]; then
        err "a different sing-box version exists; use 'sb core upgrade'"
        return 1
    fi
    core_switch install
}

core_upgrade() (
    core_install_dependencies || return 1
    local backup was_active=false restore_stage="" enabled=0
    trap 'rm -f -- "${restore_stage:-}"' EXIT
    backup=$(backup_create "pre-core-upgrade" false true) || return 1
    info "upgrade backup: $backup"
    service_is_active && was_active=true
    [[ ! -f "$SB_CURRENT_STATE" ]] ||
        enabled=$(state_enabled_count_file "$SB_CURRENT_STATE") || return 1
    core_switch upgrade || return 1
    if [[ "$was_active" == "true" ]]; then
        if service_restart &&
            { [[ "${SB_SKIP_LISTENER_CHECK:-false}" == "true" ]] || service_verify_listeners; }; then
            return 0
        fi
        err "new core failed runtime verification; restoring previous binary"
        [[ -x "$backup/sing-box" ]] || return 1
        restore_stage=$(mktemp "$(dirname "$SB_BIN")/.sing-box.restore.XXXXXX")
        cp --preserve=mode,timestamps "$backup/sing-box" "$restore_stage"
        chmod 755 "$restore_stage"
        mv -fT "$restore_stage" "$SB_BIN"
        restore_stage=""
        if [[ -f "$backup/core.json" ]]; then
            cp -- "$backup/core.json" "${SB_CORE_RECEIPT}.restore" || return 1
            chmod 600 "${SB_CORE_RECEIPT}.restore"
            mv -fT "${SB_CORE_RECEIPT}.restore" "$SB_CORE_RECEIPT"
        else
            rm -f -- "$SB_CORE_RECEIPT"
        fi
        "$SB_BIN" check -c "$SB_CURRENT_CONFIG" || return 1
        "$SB_SYSTEMCTL" restart "$SB_SERVICE" || return 1
        service_is_active || return 1
        [[ "${SB_SKIP_LISTENER_CHECK:-false}" == "true" ]] || service_verify_listeners
        return 1
    fi
    if ((enabled > 0)); then
        service_start || return 1
        [[ "${SB_SKIP_LISTENER_CHECK:-false}" == "true" ]] ||
            service_verify_listeners || return 1
    fi
)
