#!/bin/bash
# tests/run.sh —— 测试入口
#
# 逐个执行 tests/t-*.sh，汇总结果。默认全部用例在无 root、无真实内核的环境中
# 运行；两个可选开关追加更严格的验证：
#
#   FWCTL_TEST_REAL_NFT=1   用真实 nft -c 复核渲染产物的语法
#   FWCTL_TEST_NETNS=1      在隔离 netns 中跑真实 apply / 回滚 / 崩溃恢复
#
# 用法：
#   fwctl/tests/run.sh              运行全部套件
#   fwctl/tests/run.sh t-schema     只运行指定套件

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 供子套件识别可选能力。
export FWCTL_TEST_REAL_NFT="${FWCTL_TEST_REAL_NFT:-0}"
export FWCTL_TEST_NETNS="${FWCTL_TEST_NETNS:-0}"
export FWCTL_TEST_NETNS_NAME="${FWCTL_TEST_NETNS_NAME:-fwctl-test}"

# ── 前置检查 ──────────────────────────────────────────────────────────

missing=0
for command in jq flock sha256sum; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Bail out! 缺少测试依赖：%s\n' "$command"
        missing=1
    fi
done
((missing == 0)) || exit 1

if [[ "$FWCTL_TEST_REAL_NFT" == 1 ]] && ! command -v nft >/dev/null 2>&1; then
    printf 'Bail out! FWCTL_TEST_REAL_NFT=1 但找不到 nft\n'
    exit 1
fi

if [[ "$FWCTL_TEST_NETNS" == 1 ]]; then
    if [[ $EUID -ne 0 ]]; then
        printf 'Bail out! FWCTL_TEST_NETNS=1 需要 root 才能创建 network namespace\n'
        exit 1
    fi
    if ! command -v ip >/dev/null 2>&1; then
        printf 'Bail out! FWCTL_TEST_NETNS=1 但找不到 ip 命令\n'
        exit 1
    fi
fi

# 销毁测试 netns，避免污染宿主机。
cleanup_netns() {
    [[ "$FWCTL_TEST_NETNS" == 1 ]] || return 0
    ip netns list 2>/dev/null | grep -qw "$FWCTL_TEST_NETNS_NAME" || return 0
    ip netns del "$FWCTL_TEST_NETNS_NAME" 2>/dev/null || true
}

# 开始前先清理：上一次异常中断的运行可能留下同名 netns，那会让本次的
# apply/回滚断言在一个非预期的初始状态上执行。
cleanup_netns
trap cleanup_netns EXIT

# ── 执行 ──────────────────────────────────────────────────────────────

declare -a suites=()
if (($# > 0)); then
    for name in "$@"; do
        suites+=("$TESTS_DIR/${name%.sh}.sh")
    done
else
    while IFS= read -r path; do
        suites+=("$path")
    done < <(find "$TESTS_DIR" -maxdepth 1 -name 't-*.sh' | sort)
fi

((${#suites[@]} > 0)) || {
    printf 'Bail out! 没有找到任何测试套件\n'
    exit 1
}

total_pass=0
total_fail=0
declare -a failed_suites=()

for suite in "${suites[@]}"; do
    name=$(basename "$suite" .sh)
    if [[ ! -f "$suite" ]]; then
        printf 'Bail out! 套件不存在：%s\n' "$suite"
        exit 1
    fi

    output=$(bash "$suite" 2>&1)
    status=$?
    printf '%s\n' "$output"

    # 从套件的汇总行里取通过与失败数。
    summary=$(grep -E "^# $name: " <<< "$output" | tail -1)
    pass=$(grep -oE '[0-9]+ passed' <<< "$summary" | grep -oE '[0-9]+' || echo 0)
    fail=$(grep -oE '[0-9]+ FAILED' <<< "$summary" | grep -oE '[0-9]+' || echo 0)
    total_pass=$((total_pass + ${pass:-0}))
    total_fail=$((total_fail + ${fail:-0}))

    if ((status != 0)); then
        failed_suites+=("$name")
        # 套件可能在输出汇总行之前就崩溃，这种情况也要计为失败。
        ((fail > 0)) || total_fail=$((total_fail + 1))
    fi
done

printf '\n'
printf '========================================\n'
printf ' 总计：%d 通过，%d 失败\n' "$total_pass" "$total_fail"
if ((${#failed_suites[@]} > 0)); then
    printf ' 失败套件：%s\n' "${failed_suites[*]}"
fi
printf ' 真实 nft 复核：%s\n' \
    "$([[ "$FWCTL_TEST_REAL_NFT" == 1 ]] && echo 已启用 || echo 未启用)"
printf ' netns 真实内核：%s\n' \
    "$([[ "$FWCTL_TEST_NETNS" == 1 ]] && echo 已启用 || echo 未启用)"
printf '========================================\n'

((total_fail == 0)) || exit 1
printf '全部通过\n'
exit 0
