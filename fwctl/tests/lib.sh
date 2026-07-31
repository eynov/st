#!/bin/bash
# tests/lib.sh —— 测试公共库
#
# 提供 TAP 风格的断言与固件构造。被各 t-*.sh 套件 source。
#
# 设计原则：断言失败时输出足够定位问题的上下文（期望值、实际值、相关文件），
# 不只是「failed」。测试的价值在于告诉你哪里错了。

FWCTL_TEST_PASS=0
FWCTL_TEST_FAIL=0
FWCTL_TEST_SUITE=""

# 项目根目录，供各套件定位 core/ 与 fixtures/。
TEST_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEST_PROJECT_DIR

# 声明当前套件名。
suite() {
    FWCTL_TEST_SUITE=$1
    printf '# %s\n' "$1"
}

# 记录一条通过的断言。
ok() {
    FWCTL_TEST_PASS=$((FWCTL_TEST_PASS + 1))
    printf 'ok %d - %s\n' "$((FWCTL_TEST_PASS + FWCTL_TEST_FAIL))" "$*"
}

# 记录一条失败的断言。附加信息通过后续参数输出为诊断行。
not_ok() {
    local message=$1
    shift
    FWCTL_TEST_FAIL=$((FWCTL_TEST_FAIL + 1))
    printf 'not ok %d - %s\n' "$((FWCTL_TEST_PASS + FWCTL_TEST_FAIL))" "$message"
    local line
    for line in "$@"; do
        printf '#   %s\n' "$line"
    done
}

# 断言两个字符串相等。
# 参数：$1=描述，$2=实际值，$3=期望值。
assert_eq() {
    local message=$1 actual=$2 expected=$3
    if [[ "$actual" == "$expected" ]]; then
        ok "$message"
    else
        not_ok "$message" "expected: $expected" "actual:   $actual"
    fi
}

# 断言命令成功。
# 参数：$1=描述，其余为命令。
assert_ok() {
    local message=$1
    shift
    local output rc
    output=$("$@" 2>&1)
    rc=$?
    if ((rc == 0)); then
        ok "$message"
    else
        not_ok "$message" "exit code: $rc" "output: ${output:0:400}"
    fi
}

# 断言命令失败，并可选地检查退出码。
# 参数：$1=描述，$2=期望退出码（0 表示不检查具体值，只要非零），其余为命令。
assert_fails() {
    local message=$1 want_code=$2
    shift 2
    local output rc
    output=$("$@" 2>&1)
    rc=$?
    if ((rc == 0)); then
        not_ok "$message" "命令本应失败但返回 0" "output: ${output:0:400}"
        return
    fi
    if ((want_code != 0)) && ((rc != want_code)); then
        not_ok "$message" "expected exit: $want_code" "actual exit:   $rc" \
            "output: ${output:0:400}"
        return
    fi
    ok "$message"
}

# 断言输出包含指定子串。
# 参数：$1=描述，$2=实际输出，$3=期望包含的子串。
assert_contains() {
    local message=$1 haystack=$2 needle=$3
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$message"
    else
        not_ok "$message" "expected to contain: $needle" \
            "actual: ${haystack:0:400}"
    fi
}

# 断言输出不包含指定子串。
assert_not_contains() {
    local message=$1 haystack=$2 needle=$3
    if [[ "$haystack" != *"$needle"* ]]; then
        ok "$message"
    else
        not_ok "$message" "expected NOT to contain: $needle" \
            "actual: ${haystack:0:400}"
    fi
}

# 断言两个文件内容逐字节相同。
assert_files_eq() {
    local message=$1 a=$2 b=$3
    if cmp -s "$a" "$b"; then
        ok "$message"
    else
        not_ok "$message" "文件不一致：$a vs $b" \
            "$(diff "$a" "$b" 2>&1 | head -20 | tr '\n' '|')"
    fi
}

# 输出 TAP 计划行并以合适的退出码结束。
finish() {
    local total=$((FWCTL_TEST_PASS + FWCTL_TEST_FAIL))
    printf '1..%d\n' "$total"
    if ((FWCTL_TEST_FAIL > 0)); then
        printf '# %s: %d passed, %d FAILED\n' \
            "$FWCTL_TEST_SUITE" "$FWCTL_TEST_PASS" "$FWCTL_TEST_FAIL"
        exit 1
    fi
    printf '# %s: %d passed\n' "$FWCTL_TEST_SUITE" "$FWCTL_TEST_PASS"
    exit 0
}

# ── 固件构造 ──────────────────────────────────────────────────────────

# 构造一份包含 Target / Service / Rule 的样例状态，写入指定路径。
# 时间戳固定，便于确定性比对。
make_sample_state() {
    local path=$1
    FWCTL_NOW=2026-07-31T00:00:00Z state_default | jq '
        .targets = [
          {id:"tgt-9f2c41a7be03", name:"edge", description:"", kind:"ipv4",
           addresses:["192.0.2.20"], enabled:true,
           created_at:"2026-07-31T00:00:00Z", updated_at:"2026-07-31T00:00:00Z"},
          {id:"tgt-0b5e77d1a942", name:"blacklist", description:"", kind:"ipv4",
           addresses:["198.51.100.7","203.0.113.0/24"], enabled:true,
           created_at:"2026-07-31T00:00:00Z", updated_at:"2026-07-31T00:00:00Z"}
        ]
      | .services = [
          {id:"svc-3d81c0be5f24", name:"https", description:"", protocol:"both",
           ports:["443"],
           created_at:"2026-07-31T00:00:00Z", updated_at:"2026-07-31T00:00:00Z"}
        ]
      | .rules = [
          {id:"rule-7a0e4b19cc85", name:"edge-https", description:"", type:"forward",
           enabled:true, priority:100, service:"svc-3d81c0be5f24",
           target:"tgt-9f2c41a7be03", source:null, translate:{port:null},
           created_at:"2026-07-31T00:00:00Z", updated_at:"2026-07-31T00:00:00Z"},
          {id:"rule-c41d8f5a2e60", name:"blacklist-drop", description:"", type:"block",
           enabled:true, priority:10, service:null, target:null,
           source:"tgt-0b5e77d1a942", translate:{port:null},
           created_at:"2026-07-31T00:00:00Z", updated_at:"2026-07-31T00:00:00Z"}
        ]
      | .ports = {tcp:["22","443"], udp:["60000-61000"]}
    ' > "$path"
}
