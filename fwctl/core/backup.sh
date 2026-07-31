#!/bin/bash
# core/backup.sh —— 备份与恢复
#
# 职责：创建备份、列举备份、从备份恢复。
#
# 依赖：core/common.sh、core/state.sh、core/transaction.sh
# 用法：本文件只能被 source，不能直接执行。
#
# 恢复走与其他写操作完全相同的事务，因此失败即整体回滚，不存在部分恢复。

[[ -n "${FWCTL_BACKUP_LOADED:-}" ]] && return 0
FWCTL_BACKUP_LOADED=1

backup_root() {
    printf '%s\n' "${FWCTL_BACKUP_DIR:-$(txn_var_dir)/backups}"
}

# 创建一次备份。
# 参数：$1=可选 label。输出：backup-id。
backup_create() {
    local label=${1:-} state="${FWCTL_STATE_FILE:?}" root id dir stamp

    [[ -f "$state" ]] || {
        fwctl_err "状态文件不存在，无法备份：$state"
        return 1
    }

    root=$(backup_root)
    stamp=$(fwctl_now | tr -d ':-')
    id="backup-$stamp"
    dir="$root/$id"

    # 同一秒内的多次备份不能互相覆盖。
    local suffix=2
    while [[ -d "$dir" ]]; do
        id="backup-$stamp-$suffix"
        dir="$root/$id"
        suffix=$((suffix + 1))
    done

    mkdir -p "$dir" || {
        fwctl_err "无法创建备份目录：$dir"
        return 1
    }

    if ! cp "$state" "$dir/state.json"; then
        rm -rf "$dir"
        fwctl_err "备份状态文件失败"
        return 1
    fi

    local conf="${FWCTL_BUILD_DIR:-$(txn_var_dir)/build}/nft.conf"
    [[ -f "$conf" ]] && cp "$conf" "$dir/nft.conf"

    if ! jq -n \
        --arg id "$id" \
        --arg label "$label" \
        --arg at "$(fwctl_now)" \
        --argjson generation "$(jq -r '.metadata.generation // 0' "$state")" \
        --arg version "$(jq -r '.metadata.fwctl_version // ""' "$state")" \
        '{id: $id, label: $label, created_at: $at,
          generation: $generation, fwctl_version: $version}' \
        > "$dir/metadata.json"; then
        rm -rf "$dir"
        fwctl_err "写入备份元数据失败"
        return 1
    fi

    printf '%s\n' "$id"
}

# 列举备份。
backup_list() {
    local root dir
    root=$(backup_root)

    if [[ ! -d "$root" ]]; then
        [[ "${FWCTL_JSON:-0}" == 1 ]] && printf '[]\n' || printf '没有备份\n'
        return 0
    fi

    if [[ "${FWCTL_JSON:-0}" == 1 ]]; then
        find "$root" -maxdepth 1 -mindepth 1 -type d -print0 |
            sort -z |
            xargs -0 -I{} sh -c 'cat "{}/metadata.json" 2>/dev/null || true' |
            jq -sc .
        return 0
    fi

    printf 'ID                              GENERATION  LABEL\n'
    while IFS= read -r dir; do
        [[ -f "$dir/metadata.json" ]] || continue
        jq -r '"\(.id)\t\(.generation)\t\(.label)"' "$dir/metadata.json" |
            while IFS=$'\t' read -r id generation label; do
                printf '%-31s %-11s %s\n' "$id" "$generation" "$label"
            done
    done < <(find "$root" -maxdepth 1 -mindepth 1 -type d | sort)
    return 0
}

# 显示单个备份的元数据。
backup_show() {
    local id=$1 dir
    dir="$(backup_root)/$id"
    [[ -f "$dir/metadata.json" ]] || {
        fwctl_err "找不到备份：$id"
        return 1
    }
    jq . "$dir/metadata.json"
}

# 解析备份或外部文件，输出其中的状态文件路径。
backup_resolve_state() {
    local source=$1 dir

    if [[ -f "$source" ]]; then
        printf '%s\n' "$source"
        return 0
    fi

    dir="$(backup_root)/$source"
    if [[ -f "$dir/state.json" ]]; then
        printf '%s\n' "$dir/state.json"
        return 0
    fi

    fwctl_err "找不到备份或状态文件：$source"
    return 1
}
