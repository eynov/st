#!/bin/bash
# core/common.sh —— 基础设施层
#
# 职责：日志输出、退出码常量、全局写锁、临时文件、原子替换、时间源、
#       以及被多个模块共享的地址与端口校验原语。
#
# 依赖：无。这是依赖图的最底层，不得 source 任何其他 core 模块。
# 用法：本文件只能被 source，不能直接执行。
#
# 约定：安全关键命令逐条显式检查退出码并向上传播，不依赖调用方的 set -e。

# 防止重复 source 导致只读常量被重新赋值而报错。
[[ -n "${FWCTL_COMMON_LOADED:-}" ]] && return 0
FWCTL_COMMON_LOADED=1

# ── 退出码 ABI ────────────────────────────────────────────────────────
# 这套语义已冻结，是对外承诺的接口，见 docs/CLI.md。各模块一律引用这些常量，
# 不散写字面量。
#
# 用 -rx 声明：readonly 防止被意外覆盖，export 让子进程（render.sh 兼容入口、
# 测试中被当作子命令拉起的 fw.sh）也能引用同一套取值。
declare -rx FWCTL_EXIT_OK=0
declare -rx FWCTL_EXIT_VALIDATION=1   # schema、语义、引用不存在
declare -rx FWCTL_EXIT_USAGE=2        # 未知命令、参数个数不对
declare -rx FWCTL_EXIT_RUNTIME=3      # 渲染、apply、系统调用失败
declare -rx FWCTL_EXIT_LOCK=4         # 获取全局写锁失败
declare -rx FWCTL_EXIT_ROLLBACK=5     # 已应用后失败，内核状态已回滚

# ── 日志 ──────────────────────────────────────────────────────────────
# 成功与信息走 stdout，警告与错误走 stderr。FWCTL_QUIET=1 时只保留错误。

# 普通信息。
fwctl_info() {
    [[ "${FWCTL_QUIET:-0}" == 1 ]] && return 0
    printf 'ℹ️ %s\n' "$*"
}

# 成功提示。只允许在整个操作真正完成后调用。
fwctl_ok() {
    [[ "${FWCTL_QUIET:-0}" == 1 ]] && return 0
    printf '✅ %s\n' "$*"
}

# 警告：不阻断流程，但用户需要知道。
fwctl_warn() {
    [[ "${FWCTL_QUIET:-0}" == 1 ]] && return 0
    printf '⚠️ %s\n' "$*" >&2
}

# 错误：始终输出，不受 FWCTL_QUIET 影响。
fwctl_err() {
    printf '❌ %s\n' "$*" >&2
}

# 输出错误并以指定退出码结束进程。
# 参数：$1=退出码，其余为错误信息。
fwctl_die() {
    local code=$1
    shift
    fwctl_err "$@"
    exit "$code"
}

# ── 时间源 ────────────────────────────────────────────────────────────
# FWCTL_NOW 是唯一的时间注入点。迁移与测试依赖它产出确定性结果，因此任何需要
# 时间戳的地方都必须走这里，不得直接调用 date。

# 输出 RFC3339 UTC 时间戳。
fwctl_now() {
    if [[ -n "${FWCTL_NOW:-}" ]]; then
        printf '%s\n' "$FWCTL_NOW"
        return 0
    fi
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# 输出指定文件 mtime 的 RFC3339 UTC 表示。
# 迁移用它派生时间戳，从而对同一份输入始终产出相同结果。
# 参数：$1=文件路径。
fwctl_file_mtime() {
    local path=$1
    [[ -e "$path" ]] || {
        fwctl_err "无法读取时间戳：$path 不存在"
        return 1
    }
    date -u -r "$path" +%Y-%m-%dT%H:%M:%SZ
}

# ── 依赖检查 ──────────────────────────────────────────────────────────

# 检查一组命令是否可用，缺失时逐个报告。
# 参数：命令名列表。
fwctl_require_commands() {
    local command missing=0
    for command in "$@"; do
        if ! command -v "$command" >/dev/null 2>&1; then
            fwctl_err "缺少依赖：$command"
            missing=1
        fi
    done
    return "$missing"
}

# 要求以 root 运行。FWCTL_ALLOW_UNPRIVILEGED=1 时跳过，供测试使用。
fwctl_require_root() {
    [[ "${FWCTL_ALLOW_UNPRIVILEGED:-0}" == 1 ]] && return 0
    [[ $EUID -eq 0 ]] && return 0
    fwctl_err "请以 root 权限运行"
    return 1
}

# ── 全局写锁 ──────────────────────────────────────────────────────────
# 所有写路径共用同一个锁文件，见 docs/adr/0003-single-transaction-boundary.md。
# 只读命令不获取锁，避免巡检脚本阻塞真正的写操作。

FWCTL_LOCK_FD=""

# 以非阻塞方式获取全局写锁。
# 成功返回 0；已被占用返回 FWCTL_EXIT_LOCK，调用方据此退出。
fwctl_lock_acquire() {
    local lockfile="${FWCTL_LOCKFILE:-/run/lock/fwctl/fwctl.lock}"
    local lockdir fd

    lockdir=$(dirname "$lockfile")
    if ! mkdir -p "$lockdir"; then
        fwctl_err "无法创建锁目录：$lockdir"
        return "$FWCTL_EXIT_RUNTIME"
    fi

    # 动态分配 fd，避免固定 fd 与调用方的重定向冲突。
    if ! exec {fd}>"$lockfile"; then
        fwctl_err "无法打开锁文件：$lockfile"
        return "$FWCTL_EXIT_RUNTIME"
    fi

    if ! flock -n "$fd"; then
        exec {fd}>&-
        fwctl_err "另一个 fwctl 事务正在进行，请稍后重试"
        return "$FWCTL_EXIT_LOCK"
    fi

    FWCTL_LOCK_FD=$fd
    return 0
}

# 释放全局写锁。未持有锁时是空操作，可安全重复调用。
fwctl_lock_release() {
    [[ -n "$FWCTL_LOCK_FD" ]] || return 0
    exec {FWCTL_LOCK_FD}>&-
    FWCTL_LOCK_FD=""
}

# ── 临时文件与原子替换 ────────────────────────────────────────────────

# 在目标文件所在的同一文件系统内创建临时文件，保证后续 mv 是原子的。
# 参数：$1=最终目标路径（只用来决定目录，不会被创建）。
fwctl_mktemp_beside() {
    local target=$1 dir
    dir=$(dirname "$target")
    if ! mkdir -p "$dir"; then
        fwctl_err "无法创建目录：$dir"
        return 1
    fi
    mktemp "$dir/.fwctl.$(basename "$target").XXXXXX"
}

# 原子地把源文件内容放到目标路径。
# 跨文件系统时 mv 不是原子的，因此先在目标目录内建临时文件再 mv。
# 参数：$1=源文件，$2=目标路径，$3=权限（可选，默认 0644）。
fwctl_atomic_install() {
    local source=$1 target=$2 mode=${3:-0644} tmp

    tmp=$(fwctl_mktemp_beside "$target") || return 1

    if ! cp "$source" "$tmp"; then
        rm -f "$tmp"
        fwctl_err "无法写入临时文件：$tmp"
        return 1
    fi
    if ! chmod "$mode" "$tmp"; then
        rm -f "$tmp"
        fwctl_err "无法设置权限：$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        fwctl_err "无法原子替换：$target"
        return 1
    fi
    return 0
}

# ── 确定性 ID ─────────────────────────────────────────────────────────
# ID 由内容哈希派生，禁止随机数与当前时间——迁移的确定性依赖这一点，
# 见 docs/adr/0004-automatic-schema-migration.md。

# 由类型和规范化内容派生 12 位十六进制 ID。
# 参数：$1=类型（target|service|rule），$2=规范化内容，$3=盐（可选，碰撞时使用）。
# 输出：<前缀>-<12 位小写十六进制>
fwctl_object_id() {
    local kind=$1 content=$2 salt=${3:-} prefix digest

    case "$kind" in
        target)  prefix=tgt ;;
        service) prefix=svc ;;
        rule)    prefix=rule ;;
        *)
            fwctl_err "未知对象类型：$kind"
            return 1
            ;;
    esac

    # 用 NUL 分隔各字段，避免 "ab"+"c" 与 "a"+"bc" 产生相同的哈希输入。
    digest=$(printf '%s\0%s\0%s' "$kind" "$content" "$salt" |
        sha256sum | cut -c1-12) || return 1

    printf '%s-%s\n' "$prefix" "$digest"
}

# ── 地址原语 ──────────────────────────────────────────────────────────

# 判断是否为合法的点分十进制 IPv4 地址。
fwctl_is_ipv4() {
    local ip=$1 octet octets
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        # 前导零会被 10# 正确处理；超出 255 的段判为非法。
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
    return 0
}

# 判断是否为合法的 IPv4 CIDR（a.b.c.d/len，len 为 0-32）。
fwctl_is_ipv4_cidr() {
    local spec=$1 addr len
    [[ "$spec" == */* ]] || return 1
    addr=${spec%%/*}
    len=${spec##*/}
    [[ "$len" =~ ^[0-9]{1,2}$ ]] || return 1
    ((10#$len >= 0 && 10#$len <= 32)) || return 1
    fwctl_is_ipv4 "$addr"
}

# 判断是否为合法的地址元素：单个 IPv4 或 IPv4 CIDR。
fwctl_is_address() {
    local spec=$1
    if [[ "$spec" == */* ]]; then
        fwctl_is_ipv4_cidr "$spec"
    else
        fwctl_is_ipv4 "$spec"
    fi
}

# 把 IPv4 地址转成 32 位整数，用于确定性排序。
# 参数：$1=IPv4 地址（可带 /len，前缀长度不参与主排序值）。
fwctl_ipv4_to_int() {
    local spec=$1 addr octets
    addr=${spec%%/*}
    IFS=. read -r -a octets <<< "$addr"
    printf '%s\n' "$(( (10#${octets[0]} << 24) + (10#${octets[1]} << 16) +
                       (10#${octets[2]} << 8) + 10#${octets[3]} ))"
}

# ── 端口原语 ──────────────────────────────────────────────────────────
# 语义与旧版本逐字一致，错误文案也保持不变——测试与用户文档都依赖这些文案。

# 校验协议名，输出规范化后的小写形式。
# 参数：$1=协议（大小写不敏感）。
fwctl_validate_protocol() {
    local proto=${1,,}
    case "$proto" in
        tcp|udp|both)
            printf '%s\n' "$proto"
            ;;
        *)
            fwctl_err "非法协议 '$1'；只允许 tcp、udp 或 both"
            return 1
            ;;
    esac
}

# 校验并规范化端口规范，输出 "N" 或 "N-M"。
# 去掉前导零；单端口区间（N-N）折叠为 N。
# 参数：$1=端口规范。
fwctl_normalize_port_spec() {
    local spec=$1 start end

    if [[ ! "$spec" =~ ^([0-9]+)(-([0-9]+))?$ ]]; then
        fwctl_err "非法端口 '$spec'；必须是 1-65535 的整数或 START-END 范围"
        return 1
    fi

    start=${BASH_REMATCH[1]}
    end=${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}
    while [[ ${#start} -gt 1 && ${start:0:1} == 0 ]]; do start=${start:1}; done
    while [[ ${#end} -gt 1 && ${end:0:1} == 0 ]]; do end=${end:1}; done

    if [[ ${#start} -gt 5 || ${#end} -gt 5 ]] ||
        ((10#$start < 1 || 10#$start > 65535 ||
          10#$end < 1 || 10#$end > 65535)); then
        fwctl_err "非法端口 '$spec'；端口必须位于 1-65535"
        return 1
    fi
    if ((10#$start > 10#$end)); then
        fwctl_err "非法端口范围 '$spec'；起始端口必须小于或等于结束端口"
        return 1
    fi

    if [[ "$start" == "$end" ]]; then
        printf '%s\n' "$start"
    else
        printf '%s-%s\n' "$start" "$end"
    fi
}

# 输出一段可复用的 jq 函数定义，供各模块对端口规范数组做确定性排序。
# 排序键是 (起始端口, 结束端口) 的数值，因此 "80" 排在 "443" 之前，
# 而不是按字符串比较。
fwctl_jq_port_sort_def() {
    cat <<'JQ'
def sorted_ports:
    unique
    | sort_by(
        capture("^(?<start>[0-9]+)(-(?<end>[0-9]+))?$")
        | [(.start | tonumber), ((.end // .start) | tonumber)]
      );
JQ
}
