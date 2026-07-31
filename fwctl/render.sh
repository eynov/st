#!/bin/bash
# render.sh —— 兼容入口
#
# 旧版本把渲染逻辑放在本文件里，文档中记录的
#     /opt/fwctl/render.sh --render-only
# 至今仍被运维脚本使用，因此这个入口保留。
#
# 实现已经移到 core/render.sh（渲染）与 core/transaction.sh（发布）。本文件
# 只是转发，不再自带锁——所有写路径共用同一个全局锁，见
# docs/adr/0003-single-transaction-boundary.md。

set -u

REAL_SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
BASE_DIR="$(cd "$(dirname "$REAL_SCRIPT_PATH")" && pwd)"

usage() {
    echo "用法: render.sh [--check|--render-only]"
}

APPLY_OVERRIDE=""
case "${1:-}" in
    "") ;;
    --check|--render-only) APPLY_OVERRIDE=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

[[ -n "$APPLY_OVERRIDE" ]] && export FWCTL_APPLY="$APPLY_OVERRIDE"

# shellcheck source=core/common.sh
source "$BASE_DIR/core/common.sh"
# shellcheck source=core/state.sh
source "$BASE_DIR/core/state.sh"
# shellcheck source=core/model.sh
source "$BASE_DIR/core/model.sh"
# shellcheck source=core/migration.sh
source "$BASE_DIR/core/migration.sh"
# shellcheck source=core/render.sh
source "$BASE_DIR/core/render.sh"
# shellcheck source=core/transaction.sh
source "$BASE_DIR/core/transaction.sh"
# shellcheck source=core/backup.sh
source "$BASE_DIR/core/backup.sh"
# shellcheck source=core/doctor.sh
source "$BASE_DIR/core/doctor.sh"
# shellcheck source=core/stats.sh
source "$BASE_DIR/core/stats.sh"
# shellcheck source=core/cli.sh
source "$BASE_DIR/core/cli.sh"

export FWCTL_STATE_FILE="${FWCTL_STATE_FILE:-$BASE_DIR/state.json}"
export FWCTL_BUILD_DIR="${FWCTL_BUILD_DIR:-$BASE_DIR/build}"

fwctl_require_root || exit "$FWCTL_EXIT_RUNTIME"
fwctl_require_commands jq flock "$(txn_nft_bin)" || exit "$FWCTL_EXIT_RUNTIME"

txn_recover || exit $?

cli_render
exit $?
