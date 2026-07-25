#!/usr/bin/env bash

SB_INSTALL_ROOT="${SB_INSTALL_ROOT:-/opt/sb}"
SB_RELEASES_DIR="${SB_RELEASES_DIR:-${SB_INSTALL_ROOT}/releases}"
SB_APP_LINK="${SB_APP_LINK:-${SB_INSTALL_ROOT}/app}"
SB_COMMAND_LINK="${SB_COMMAND_LINK:-/usr/local/bin/sb}"

manager_validate_source() {
    local source="$1" file source_version
    [[ -x "$source/sb" && -f "$source/version.json" && -f "$source/checksums.json" ]] || {
        err "invalid sb source directory: $source"
        return 1
    }
    while IFS= read -r file; do
        bash -n "$file" || return 1
    done < <(find "$source" -type f \( -name '*.sh' -o -name 'sb' \) -print)
    source_version=$(jq -er '.project_version | select(type == "string" and length > 0)' \
      "$source/version.json") || {
        err "source project version is missing"
        return 1
    }
    grep -Fqx "SB_PROJECT_VERSION=\"${source_version}\"" "$source/core/common.sh" || {
        err "source version metadata does not match core/common.sh"
        return 1
    }
    local checksums_hash declared_hash
    checksums_hash=$(sha256sum "$source/checksums.json" | awk '{print $1}') || return 1
    declared_hash=$(sed -n 's/^SB_CHECKSUMS_SHA256="\([0-9a-f]*\)"$/\1/p' \
      "$source/core/common.sh")
    [[ "$checksums_hash" == "$declared_hash" ]] || {
        err "checksums.json does not match the pinned source integrity value"
        return 1
    }
}

manager_install_source() {
    local source="$1" source_version release_id release_dir stage previous_link=""
    manager_validate_source "$source" || return 1
    source_version=$(jq -r '.project_version' "$source/version.json")
    safe_mkdir "$SB_INSTALL_ROOT" 755
    safe_mkdir "$SB_RELEASES_DIR" 755
    release_id="${source_version}-$(date -u '+%Y%m%dT%H%M%SZ')-$(openssl rand -hex 3)"
    stage=$(mktemp -d "${SB_RELEASES_DIR}/.stage-${release_id}.XXXXXX")
    cp -a -- "$source/." "$stage/" || {
        rm -rf -- "$stage"
        return 1
    }
    manager_validate_source "$stage" || {
        rm -rf -- "$stage"
        return 1
    }
    release_dir="${SB_RELEASES_DIR}/${release_id}"
    mv -- "$stage" "$release_dir" || {
        rm -rf -- "$stage"
        return 1
    }
    SB_MANAGER_INSTALLED_RELEASE="$release_dir"
    export SB_MANAGER_INSTALLED_RELEASE

    [[ -L "$SB_APP_LINK" ]] && previous_link=$(readlink "$SB_APP_LINK")
    if [[ -e "$SB_APP_LINK" && ! -L "$SB_APP_LINK" ]]; then
        err "$SB_APP_LINK exists and is not a managed symlink; refusing replacement"
        rm -rf -- "$release_dir"
        return 1
    fi
    ln -s "releases/${release_id}" "${SB_INSTALL_ROOT}/.app.new.$$"
    mv -fT "${SB_INSTALL_ROOT}/.app.new.$$" "$SB_APP_LINK"
    if ! env -u SB_APP_DIR "$SB_APP_LINK/sb" self-check >/dev/null; then
        if [[ -n "$previous_link" ]]; then
            ln -s "$previous_link" "${SB_INSTALL_ROOT}/.app.rollback.$$"
            mv -fT "${SB_INSTALL_ROOT}/.app.rollback.$$" "$SB_APP_LINK"
        else
            rm -f "$SB_APP_LINK"
        fi
        rm -rf -- "$release_dir"
        err "new manager self-check failed; application link rolled back"
        return 1
    fi
    safe_mkdir "$(dirname "$SB_COMMAND_LINK")" 755
    if [[ -e "$SB_COMMAND_LINK" && ! -L "$SB_COMMAND_LINK" ]]; then
        err "$SB_COMMAND_LINK exists and is not a managed symlink; refusing replacement"
        if [[ -n "$previous_link" ]]; then
            ln -s "$previous_link" "${SB_INSTALL_ROOT}/.app.rollback.$$"
            mv -fT "${SB_INSTALL_ROOT}/.app.rollback.$$" "$SB_APP_LINK"
        else
            rm -f -- "$SB_APP_LINK"
        fi
        rm -rf -- "$release_dir"
        SB_MANAGER_INSTALLED_RELEASE=""
        export SB_MANAGER_INSTALLED_RELEASE
        return 1
    fi
    ln -sfn "$SB_APP_LINK/sb" "$SB_COMMAND_LINK"
    ok "sb manager installed: $release_dir"
}
