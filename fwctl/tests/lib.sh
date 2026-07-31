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

# ── 渲染等价性归一化 ──────────────────────────────────────────────────

# 把一份 nft 配置归一化成「语义行」清单，用于比较新旧渲染器的行为。
#
# 只消除 ADR 0004 声明的三类差异，此外不做任何宽容：
#   1. nftables 对象标识符——表名（sb_filter/sb_nat → fwctl）；
#   2. counter 与 comment 的增加；
#   3. 空 set 的占位元素 127.0.0.2 与 65535（仅当它是集合中唯一的元素时，
#      这正是旧实现使用占位符的条件）。
#
# 比较的是「哪条 chain 里有哪些规则、哪个 set 里有哪些元素」，而不是文件文本，
# 因此新实现把两张表合并成一张不会造成假阳性——表的分组方式不影响包处理。
normalize_ruleset() {
    local path=$1 raw
    raw=$(_normalize_ruleset_lines "$path")
    # set 的声明顺序在 nftables 里没有语义——它们是具名对象，声明先后不影响
    # 匹配。因此 set 行排序后输出，chain 内的规则行严格保持原顺序（那是有语义的）。
    local empty_sets
    # 元素为空的 set（含仅有占位符的情形）匹配不到任何流量，引用它的规则因此
    # 是惰性的。旧实现用占位符伪造非空集合并保留该规则，新实现两者都不生成；
    # 这是 ADR 0004 声明的占位符差异的直接后果，比较时一并消除。
    empty_sets=$(printf '%s\n' "$raw" | sed -n 's/^set \([A-Za-z0-9_]*\) = $/@\1/p')

    printf '%s\n' "$raw" | grep '^set ' | grep -v ' = $' | sort
    if [[ -n "$empty_sets" ]]; then
        printf '%s\n' "$raw" | grep '^chain ' | grep -vF "$empty_sets"
    else
        printf '%s\n' "$raw" | grep '^chain '
    fi
}

_normalize_ruleset_lines() {
    local path=$1
    awk '
        # 去掉注释行与 flush ruleset。
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*flush ruleset/ { next }
        # 表的预声明与删除是新实现的原子替换惯用法，不是规则。
        /^[[:space:]]*table ip [a-z_]+ \{ \}[[:space:]]*$/ { next }
        /^[[:space:]]*delete table/ { next }

        /^[[:space:]]*set [A-Za-z0-9_]+ \{/ {
            match($0, /set [A-Za-z0-9_]+/)
            set_name = substr($0, RSTART + 4, RLENGTH - 4)
            in_set = 1
            elements = ""
            next
        }
        in_set && /elements[[:space:]]*=/ {
            line = $0
            sub(/^[^{]*\{/, "", line)
            sub(/\}.*$/, "", line)
            gsub(/[[:space:]]+/, "", line)
            elements = line
            next
        }
        in_set && /^[[:space:]]*\}/ {
            # 唯一元素为占位符时视为空集合。
            if (elements == "127.0.0.2" || elements == "65535") elements = ""
            printf "set %s = %s\n", set_name, elements
            in_set = 0
            next
        }
        in_set { next }

        /^[[:space:]]*chain [a-z]+ \{/ {
            match($0, /chain [a-z]+/)
            chain_name = substr($0, RSTART + 6, RLENGTH - 6)
            in_chain = 1
            next
        }
        in_chain && /^[[:space:]]*\}/ { in_chain = 0; next }
        in_chain {
            line = $0
            sub(/[[:space:]]*comment[[:space:]]*"[^"]*"/, "", line)
            gsub(/[[:space:]]counter[[:space:]]/, " ", line)
            sub(/[[:space:]]counter$/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            gsub(/[[:space:]]+/, " ", line)
            if (line == "") next
            printf "chain %s: %s\n", chain_name, line
        }
    ' "$path"
}

# 断言两份 nft 配置在归一化后等价。
assert_ruleset_equivalent() {
    local message=$1 a=$2 b=$3
    local na nb
    na=$(normalize_ruleset "$a")
    nb=$(normalize_ruleset "$b")
    if [[ "$na" == "$nb" ]]; then
        ok "$message"
    else
        not_ok "$message" "归一化后仍有差异：" \
            "$(diff <(printf '%s\n' "$na") <(printf '%s\n' "$nb") | head -24 | tr '\n' '|')"
    fi
}

# 用冻结的旧渲染器渲染一份旧格式状态。
# 参数：$1=旧状态文件，$2=输出路径，$3=ssh 端口，$4=公网 IPv4，$5=本机 IPv4 列表。
render_with_v3() {
    local state=$1 out=$2 ssh_port=$3 public=$4 locals=$5
    local dir
    dir=$(mktemp -d)
    if FWCTL_ALLOW_UNPRIVILEGED=1 \
        FWCTL_SKIP_SYSTEM_SETUP=1 \
        FWCTL_APPLY=0 \
        FWCTL_STATE_FILE="$state" \
        FWCTL_BUILD_DIR="$dir/build" \
        FWCTL_SYSTEM_CONF="$dir/nftables.conf" \
        FWCTL_NFT_BIN=/bin/true \
        FWCTL_LOCKFILE="$dir/lock" \
        FWCTL_PUBLIC_IPV4="$public" \
        FWCTL_LOCAL_IPV4S="$locals" \
        FWCTL_SSH_PORT="$ssh_port" \
        bash "$TEST_PROJECT_DIR/tests/fixtures/render-v3.sh" --render-only \
        >/dev/null 2>&1; then
        cp "$dir/build/nft.conf" "$out"
        rm -rf "$dir"
        return 0
    fi
    rm -rf "$dir"
    return 1
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
