#!/bin/bash
# core/state.sh —— 状态层
#
# 职责：state.json 的加载、版本探测、schema 校验、语义校验、默认值补齐、
#       规范化排序和原子写回。
#
# 依赖：core/common.sh
# 用法：本文件只能被 source，不能直接执行。
#
# 本模块不认识「旧格式如何转换」——那是 core/migration.sh 的职责。这里只负责
# 判断「这份状态是不是当前 schema，以及它是否合法」。

[[ -n "${FWCTL_STATE_LOADED:-}" ]] && return 0
FWCTL_STATE_LOADED=1

# 当前 schema 版本。高于此值的状态一律拒绝加载，避免旧程序覆盖新程序的数据。
declare -rx FWCTL_SCHEMA_VERSION=4

# ── 默认状态 ──────────────────────────────────────────────────────────

# 输出一份合法的空状态。
# 注意 policy 的默认值刻意与旧版本行为一致（ct_invalid=ignore、icmp_echo=drop），
# 且升级与全新安装取同一套默认值，见 docs/STATE_SCHEMA.md。
state_default() {
    local now
    now=$(fwctl_now) || return 1
    jq -n --arg now "$now" --argjson version "$FWCTL_SCHEMA_VERSION" '
    {
      schema_version: $version,
      settings: {
        nat: { mode: "auto", snat_address: null },
        ssh: { mode: "auto", port: null },
        policy: {
          input: "drop",
          forward: "accept",
          syn_limit: { enabled: true, rate: "50/second", burst: 5 },
          ct_invalid: "ignore",
          icmp_echo: "drop"
        },
        render: { counters: true, comments: true }
      },
      ports: { tcp: [], udp: [] },
      targets: [],
      services: [],
      rules: [],
      comments: {},
      metadata: {
        created_at: $now,
        updated_at: $now,
        last_applied_at: null,
        generation: 0,
        fwctl_version: "4.0.0",
        migrated_from: null,
        legacy_adopted_at: null,
        ip_forward: null
      }
    }'
}

# ── 版本探测 ──────────────────────────────────────────────────────────

# 探测状态文件的 schema 版本。
# 输出：整数版本号；旧的无版本号格式输出 0。
# 返回：0 成功；1 文件不可读或不是合法 JSON。
state_detect_version() {
    local path=$1

    if [[ ! -f "$path" || ! -s "$path" ]]; then
        fwctl_err "状态文件不存在或为空：$path"
        return 1
    fi
    if ! jq empty "$path" >/dev/null 2>&1; then
        fwctl_err "状态文件不是合法 JSON：$path"
        fwctl_err "可以手工修复，或用 fw restore 从备份恢复"
        return 1
    fi

    jq -r '.schema_version // 0 | if type == "number" then . else "invalid" end' "$path"
}

# 检查探测到的版本是否可被本程序处理。
# 参数：$1=版本号。
# 返回：0 可处理（当前版本或需要迁移的旧版本）；1 拒绝。
state_version_supported() {
    local version=$1

    case "$version" in
        0|"$FWCTL_SCHEMA_VERSION")
            return 0
            ;;
        invalid)
            fwctl_err "schema_version 不是整数"
            return 1
            ;;
        *)
            if ((version > FWCTL_SCHEMA_VERSION)); then
                fwctl_err "状态 schema 版本 $version 高于本程序支持的 $FWCTL_SCHEMA_VERSION"
                fwctl_err "请升级 fwctl；旧程序不会覆盖新程序写入的状态"
            else
                fwctl_err "无法识别的 schema 版本：$version"
            fi
            return 1
            ;;
    esac
}

# ── 结构校验 ──────────────────────────────────────────────────────────

# 输出结构校验用的 jq 程序。
# 程序对输入状态求值，输出一个错误信息字符串数组；空数组表示通过。
_state_schema_jq() {
    cat <<'JQ'
# ── 判定原语 ──
def is_port_spec:
    type == "string"
    and test("^(0|[1-9][0-9]*)(-(0|[1-9][0-9]*))?$")
    and (
        capture("^(?<s>[0-9]+)(-(?<e>[0-9]+))?$")
        | ((.s | tonumber) as $s | ((.e // .s) | tonumber) as $e
           | $s >= 1 and $s <= 65535 and $e >= $s and $e <= 65535)
    );

def is_name:
    type == "string" and test("^[a-z0-9][a-z0-9_-]{0,31}$");

def is_id($prefix):
    type == "string" and test("^" + $prefix + "-[0-9a-f]{12}$");

def is_ts:
    type == "string"
    and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");

def is_text:
    type == "string";

def is_bool:
    type == "boolean";

# 对象的键集合必须恰好等于 required + 允许的可选键的某个子集。
def key_errors($what; $required; $optional):
    (keys_unsorted) as $k
    | (($required - $k) | map("\($what) 缺少必填字段 \(.)"))
    + (($k - $required - $optional) | map("\($what) 含未知字段 \(.)"));

# 对象图方向：Target 与 Service 不得出现指向其他对象类型的字段。
def graph_errors($what):
    (keys_unsorted) as $k
    | ([$k[] | select(. == "service" or . == "target" or . == "source"
                      or . == "rule" or . == "rules" or . == "services"
                      or . == "targets")]
       | map("\($what) 含跨类型引用字段 \(.)；对象图必须严格单向，只有 Rule 可以引用 Target 与 Service"));

# ── 顶层 ──
def top_errors:
    ((keys_unsorted | sort) as $k
     | if $k != ["comments","metadata","ports","rules","schema_version",
                 "services","settings","targets"]
       then ["顶层字段必须恰好是 schema_version、settings、ports、targets、services、rules、comments、metadata；当前为 \($k | join("、"))"]
       else [] end)
    + (if (.schema_version | type) != "number" or .schema_version != 4
       then ["schema_version 必须是 4"] else [] end)
    + (if (.settings | type) != "object" then ["settings 必须是对象"] else [] end)
    + (if (.ports | type) != "object" then ["ports 必须是对象"] else [] end)
    + (if (.targets | type) != "array" then ["targets 必须是数组"] else [] end)
    + (if (.services | type) != "array" then ["services 必须是数组"] else [] end)
    + (if (.rules | type) != "array" then ["rules 必须是数组"] else [] end)
    + (if (.comments | type) != "object" then ["comments 必须是对象"] else [] end)
    + (if (.metadata | type) != "object" then ["metadata 必须是对象"] else [] end);

# ── settings ──
def settings_errors:
    (.settings // {}) as $s
    | (if ($s.nat.mode // "auto") | IN("auto","snat","masquerade") | not
       then ["settings.nat.mode 必须是 auto、snat 或 masquerade"] else [] end)
    + (if ($s.nat.snat_address != null)
          and (($s.nat.snat_address | type) != "string")
       then ["settings.nat.snat_address 必须是字符串或 null"] else [] end)
    + (if ($s.ssh.mode // "auto") | IN("auto","fixed") | not
       then ["settings.ssh.mode 必须是 auto 或 fixed"] else [] end)
    + (if ($s.policy.input // "drop") | IN("drop","accept") | not
       then ["settings.policy.input 必须是 drop 或 accept"] else [] end)
    + (if ($s.policy.forward // "accept") | IN("accept","drop") | not
       then ["settings.policy.forward 必须是 accept 或 drop"] else [] end)
    + (if ($s.policy.ct_invalid // "ignore") | IN("ignore","drop") | not
       then ["settings.policy.ct_invalid 必须是 ignore 或 drop"] else [] end)
    + (if ($s.policy.icmp_echo // "drop") | IN("drop","accept","limit") | not
       then ["settings.policy.icmp_echo 必须是 drop、accept 或 limit"] else [] end)
    + (if ($s.policy.syn_limit.enabled // true) | is_bool | not
       then ["settings.policy.syn_limit.enabled 必须是布尔值"] else [] end)
    + (if ($s.render.counters // true) | is_bool | not
       then ["settings.render.counters 必须是布尔值"] else [] end)
    + (if ($s.render.comments // true) | is_bool | not
       then ["settings.render.comments 必须是布尔值"] else [] end);

# ── ports ──
def ports_errors:
    (.ports // {}) as $p
    | (if ($p.tcp | type) != "array" then ["ports.tcp 必须是数组"] else [] end)
    + (if ($p.udp | type) != "array" then ["ports.udp 必须是数组"] else [] end)
    + ([ ($p.tcp // [])[] | select(is_port_spec | not)
         | "ports.tcp 含非法端口规范 \(. | tostring)" ])
    + ([ ($p.udp // [])[] | select(is_port_spec | not)
         | "ports.udp 含非法端口规范 \(. | tostring)" ]);

# ── targets ──
def target_errors:
    [ (.targets // [])[]
      | . as $t
      | ("Target \($t.name // $t.id // "?")") as $what
      | key_errors($what;
            ["id","name","description","kind","addresses","enabled",
             "created_at","updated_at"];
            ["hostname","resolved_at"])
        + graph_errors($what)
        + (if ($t.id | is_id("tgt")) | not
           then ["\($what) 的 id 必须形如 tgt- 加 12 位小写十六进制"] else [] end)
        + (if ($t.name | is_name) | not
           then ["\($what) 的 name 不符合命名规则"] else [] end)
        + (if ($t.description | is_text) | not
           then ["\($what) 的 description 必须是字符串"] else [] end)
        + (if ($t.kind | IN("ipv4","hostname")) | not
           then ["\($what) 的 kind 必须是 ipv4 或 hostname"] else [] end)
        + (if ($t.addresses | type) != "array" or ($t.addresses | length) == 0
           then ["\($what) 的 addresses 必须是非空数组"] else [] end)
        + (if ($t.enabled | is_bool) | not
           then ["\($what) 的 enabled 必须是布尔值"] else [] end)
        + (if ($t.created_at | is_ts) | not
           then ["\($what) 的 created_at 必须是 RFC3339 UTC 时间戳"] else [] end)
        + (if ($t.updated_at | is_ts) | not
           then ["\($what) 的 updated_at 必须是 RFC3339 UTC 时间戳"] else [] end)
        + (if $t.kind == "hostname" and ($t.hostname | type) != "string"
           then ["\($what) 的 kind 为 hostname 时必须保存 hostname"] else [] end)
    ] | flatten;

# ── services ──
def service_errors:
    [ (.services // [])[]
      | . as $s
      | ("Service \($s.name // $s.id // "?")") as $what
      | key_errors($what;
            ["id","name","description","protocol","ports",
             "created_at","updated_at"];
            [])
        + graph_errors($what)
        + (if ($s | has("enabled"))
           then ["\($what) 不得含 enabled 字段；Service 是不可变值对象，启用状态属于 Rule"]
           else [] end)
        + (if ($s.id | is_id("svc")) | not
           then ["\($what) 的 id 必须形如 svc- 加 12 位小写十六进制"] else [] end)
        + (if ($s.name | is_name) | not
           then ["\($what) 的 name 不符合命名规则"] else [] end)
        + (if ($s.description | is_text) | not
           then ["\($what) 的 description 必须是字符串"] else [] end)
        + (if ($s.protocol | IN("tcp","udp","both")) | not
           then ["\($what) 的 protocol 必须是 tcp、udp 或 both"] else [] end)
        + (if ($s.ports | type) != "array" or ($s.ports | length) == 0
           then ["\($what) 的 ports 必须是非空数组"] else [] end)
        + ([ ($s.ports // [])[] | select(is_port_spec | not)
             | "\($what) 含非法端口规范 \(. | tostring)" ])
        + (if ($s.created_at | is_ts) | not
           then ["\($what) 的 created_at 必须是 RFC3339 UTC 时间戳"] else [] end)
        + (if ($s.updated_at | is_ts) | not
           then ["\($what) 的 updated_at 必须是 RFC3339 UTC 时间戳"] else [] end)
    ] | flatten;

# ── rules ──
def rule_errors:
    [ (.rules // [])[]
      | . as $r
      | ("Rule \($r.name // $r.id // "?")") as $what
      | key_errors($what;
            ["id","name","description","type","enabled","priority",
             "service","target","source","translate","created_at","updated_at"];
            [])
        + (if ($r.id | is_id("rule")) | not
           then ["\($what) 的 id 必须形如 rule- 加 12 位小写十六进制"] else [] end)
        + (if ($r.name | is_name) | not
           then ["\($what) 的 name 不符合命名规则"] else [] end)
        + (if ($r.description | is_text) | not
           then ["\($what) 的 description 必须是字符串"] else [] end)
        + (if ($r.type | IN("accept","forward","block")) | not
           then ["\($what) 的 type 必须是 accept、forward 或 block"] else [] end)
        + (if ($r.enabled | is_bool) | not
           then ["\($what) 的 enabled 必须是布尔值"] else [] end)
        + (if ($r.priority | type) != "number"
              or ($r.priority < 0) or ($r.priority > 65535)
              or (($r.priority | floor) != $r.priority)
           then ["\($what) 的 priority 必须是 0-65535 的整数"] else [] end)
        + (if ($r.translate | type) != "object" or ($r.translate | has("port") | not)
           then ["\($what) 的 translate 必须是含 port 字段的对象"] else [] end)
        + (if ($r.translate.port != null) and (($r.translate.port | is_port_spec) | not)
           then ["\($what) 的 translate.port 非法"] else [] end)
        + (if ($r.translate.port != null)
              and ($r.translate.port | type == "string")
              and ($r.translate.port | test("-"))
           then ["\($what) 的 translate.port 必须是单端口，不能是范围"] else [] end)
        + (if ($r.created_at | is_ts) | not
           then ["\($what) 的 created_at 必须是 RFC3339 UTC 时间戳"] else [] end)
        + (if ($r.updated_at | is_ts) | not
           then ["\($what) 的 updated_at 必须是 RFC3339 UTC 时间戳"] else [] end)
    ] | flatten;

# ── comments ──
def comment_errors:
    [ (.comments // {}) | to_entries[]
      | . as $c
      | (if ($c.value | type) != "string"
         then ["注释 \($c.key) 的内容必须是字符串"] else [] end)
        + (if ($c.value | type) == "string"
              and ($c.value | test("[\"\n]"))
           then ["注释 \($c.key) 不得包含双引号或换行"] else [] end)
    ] | flatten;

# ── metadata ──
def metadata_errors:
    (.metadata // {}) as $m
    | (if ($m.generation | type) != "number"
       then ["metadata.generation 必须是数字"] else [] end)
    + (if ($m.migrated_from != null) and (($m.migrated_from | type) != "number")
       then ["metadata.migrated_from 必须是数字或 null"] else [] end)
    + (if ($m.legacy_adopted_at != null) and (($m.legacy_adopted_at | is_ts) | not)
       then ["metadata.legacy_adopted_at 必须是 RFC3339 UTC 时间戳或 null"] else [] end);

top_errors as $top
| if ($top | length) > 0 then $top
  else
      settings_errors + ports_errors + target_errors
      + service_errors + rule_errors + comment_errors + metadata_errors
  end
JQ
}

# 对状态文件做结构校验。
# 参数：$1=状态文件路径。
# 返回：0 通过；1 有错误（逐条输出到 stderr）。
state_validate_schema() {
    local path=$1 errors

    if [[ ! -f "$path" ]]; then
        fwctl_err "状态文件不存在：$path"
        return 1
    fi
    # 空文件必须单独判断：`jq empty` 对空输入返回 0（没有输入就没有错误），
    # 后续的校验程序也不会产生任何输出，于是被截断的状态文件会被当成合法。
    if [[ ! -s "$path" ]]; then
        fwctl_err "状态文件为空：$path"
        return 1
    fi
    if ! jq -e 'type == "object"' "$path" >/dev/null 2>&1; then
        fwctl_err "状态文件不是合法的 JSON 对象：$path"
        return 1
    fi

    errors=$(jq -r "$(_state_schema_jq) | .[]" "$path" 2>&1) || {
        fwctl_err "结构校验执行失败：$errors"
        return 1
    }

    [[ -z "$errors" ]] && return 0

    while IFS= read -r line; do
        [[ -n "$line" ]] && fwctl_err "$line"
    done <<< "$errors"
    return 1
}

# ── 语义校验 ──────────────────────────────────────────────────────────

# 输出语义校验用的 jq 程序。
# 需要外部事实时通过 $facts 传入（本机 IPv4 列表等），离线模式传空对象。
_state_semantic_jq() {
    cat <<'JQ'
def dup($what; $list):
    $list
    | group_by(.)
    | map(select(length > 1) | .[0])
    | map("\($what) 重复：\(.)");

def refs:
    [ .rules[] | {rule: (.name // .id), service, target, source} ];

# id 与 name 唯一性
def unique_errors:
    dup("对象 id"; [ (.targets[].id), (.services[].id), (.rules[].id) ])
    + dup("Target name"; [ .targets[].name ])
    + dup("Service name"; [ .services[].name ])
    + dup("Rule name"; [ .rules[].name ]);

# 引用完整性
def ref_errors:
    ([ .targets[].id ]) as $tids
    | ([ .services[].id ]) as $sids
    | [ .rules[]
        | . as $r
        | ("Rule \($r.name // $r.id)") as $what
        | (if $r.service != null and ($sids | index($r.service) | not)
           then ["\($what) 引用了不存在的 Service \($r.service)"] else [] end)
          + (if $r.target != null and ($tids | index($r.target) | not)
             then ["\($what) 引用了不存在的 Target \($r.target)"] else [] end)
          + (if $r.source != null and ($tids | index($r.source) | not)
             then ["\($what) 引用了不存在的 Target \($r.source)"] else [] end)
      ] | flatten;

# 规则类型与字段组合
def combo_errors:
    [ .rules[]
      | . as $r
      | ("Rule \($r.name // $r.id)") as $what
      | if $r.type == "accept" then
            (if $r.service == null then ["\($what) 为 accept 时必须引用 Service"] else [] end)
            + (if $r.target != null then ["\($what) 为 accept 时 target 必须为 null"] else [] end)
            + (if $r.source != null then ["\($what) 为 accept 时 source 必须为 null"] else [] end)
            + (if $r.translate.port != null then ["\($what) 为 accept 时不允许 translate.port"] else [] end)
        elif $r.type == "forward" then
            (if $r.service == null then ["\($what) 为 forward 时必须引用 Service"] else [] end)
            + (if $r.target == null then ["\($what) 为 forward 时必须引用 Target"] else [] end)
            + (if $r.source != null then ["\($what) 为 forward 时 source 必须为 null"] else [] end)
        elif $r.type == "block" then
            (if $r.source == null then ["\($what) 为 block 时必须引用 Target 作为 source"] else [] end)
            + (if $r.service != null then ["\($what) 为 block 时 service 必须为 null"] else [] end)
            + (if $r.target != null then ["\($what) 为 block 时 target 必须为 null"] else [] end)
            + (if $r.translate.port != null then ["\($what) 为 block 时不允许 translate.port"] else [] end)
        else [] end
    ] | flatten;

# 地址合法性。
# 逐段做数值范围检查，不能只靠 [0-9]{1,3} 这种长度正则——它会放行 192.0.2.999。
# 同时拒绝前导零（192.000.2.20），保证存储形态是规范的。
def valid_address:
    type == "string"
    and (split("/") as $p
         | ($p | length) <= 2
         and ($p[0] | split(".") | length == 4)
         and ($p[0] | split(".")
              | all(test("^(0|[1-9][0-9]{0,2})$") and (tonumber <= 255)))
         and (($p | length) == 1
              or ($p[1] | test("^(0|[1-9][0-9]?)$") and (tonumber <= 32))));

def address_errors:
    [ .targets[]
      | . as $t
      | ("Target \($t.name)") as $what
      | [ $t.addresses[]
          | select(valid_address | not)
          | "\($what) 含非法地址 \(. | tostring)" ]
    ] | flatten;

# DNAT 的目的地必须是单个地址。
# nftables 的 `dnat to` 不接受 set（`dnat to @set` 会报 unknown raw payload base），
# 而且「转发到一组地址中的哪一个」本身也没有定义。多地址 Target 只能用作
# saddr 匹配（block 规则），不能用作转发目的地。
def dnat_target_errors:
    ([ .targets[] | {key: .id, value: .} ] | from_entries) as $targets
    | [ .rules[]
        | select(.type == "forward" and .target != null)
        | . as $r
        | $targets[$r.target] as $t
        | select($t != null and ($t.addresses | length) > 1)
        | "Rule \($r.name) 转发到多地址 Target \($t.name)；DNAT 目的地必须是单个地址，"
          + "多地址 Target 只能用于 block 规则的来源匹配" ];

# Target 名字会直接用作 nftables set 名，因此不能与渲染保留的 set 名冲突。
def reserved_name_errors:
    [ .targets[]
      | select(.name == "allowed_ports_tcp" or .name == "allowed_ports_udp")
      | "Target 名称 \(.name) 与渲染保留的 set 名冲突，请改用其他名称" ];

# comments 键：必须是存在的对象 id，或合法的 tcp:/udp: 合成键。
# 键必须先用 as 绑定：在 `$ids | index(.)` 里，`.` 指的是 $ids 本身而不是键，
# 那样写会让这条检查恒为通过。
def comment_key_errors:
    ([ (.targets[].id), (.services[].id), (.rules[].id) ]) as $ids
    | [ (.comments | keys_unsorted)[] as $key
        | select(($ids | index($key) | not)
                 and ($key | test("^(tcp|udp):(0|[1-9][0-9]*)(-(0|[1-9][0-9]*))?$") | not))
        | "注释键 \($key) 既不是已存在的对象 id，也不是合法的 tcp:/udp: 合成键" ];

# settings 中依赖外部事实的部分
def settings_semantic_errors($facts):
    .settings as $s
    | (if $s.nat.mode == "snat" then
           (if $s.nat.snat_address == null
            then ["nat.mode=snat 要求提供 snat_address"]
            elif ($s.nat.snat_address
                  | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$") | not)
            then ["snat_address \($s.nat.snat_address) 不是合法 IPv4"]
            elif ($facts.offline // false) then []
            elif (($facts.local_ipv4s // []) | index($s.nat.snat_address) | not)
            then ["snat_address \($s.nat.snat_address) 未配置在本机任一 IPv4 接口，拒绝生成规则"]
            else [] end)
       else [] end)
    + (if $s.ssh.mode == "fixed" then
           (if ($s.ssh.port | type) != "number"
                or $s.ssh.port < 1 or $s.ssh.port > 65535
            then ["ssh.mode=fixed 要求提供 1-65535 的 ssh.port"] else [] end)
       else [] end);

unique_errors + ref_errors + combo_errors + address_errors
+ dnat_target_errors + reserved_name_errors
+ comment_key_errors + settings_semantic_errors($facts)
JQ
}

# 对状态文件做语义校验。
# 参数：$1=状态文件路径，$2=外部事实 JSON（可选，默认离线）。
# 返回：0 通过；1 有错误。
state_validate_semantic() {
    local path=$1 facts=${2:-'{"offline":true}'} errors

    errors=$(jq -r --argjson facts "$facts" "$(_state_semantic_jq) | .[]" "$path" 2>&1) || {
        fwctl_err "语义校验执行失败：$errors"
        return 1
    }

    [[ -z "$errors" ]] && return 0

    while IFS= read -r line; do
        [[ -n "$line" ]] && fwctl_err "$line"
    done <<< "$errors"
    return 1
}

# 结构 + 语义完整校验。
# 参数：$1=状态文件路径，$2=外部事实 JSON（可选）。
state_validate() {
    local path=$1 facts=${2:-'{"offline":true}'}
    state_validate_schema "$path" || return 1
    state_validate_semantic "$path" "$facts" || return 1
    return 0
}

# ── 警告 ──────────────────────────────────────────────────────────────

# 输出不阻断的提醒。这些情况是合法的，只是值得用户注意。
# 参数：$1=状态文件路径。
# 输出：每行一条警告文本；无警告时无输出。始终返回 0。
state_warnings() {
    local path=$1
    jq -r '
    # 地址集合完全相同的多个 Target：允许，但通常是无意的重复。
    ([ .targets[] | {name, key: (.addresses | sort | join(","))} ]
     | group_by(.key)
     | map(select(length > 1))
     | map("以下 Target 的地址集合完全相同，可能重复："
           + (map(.name) | join("、")))) as $dup_targets

    # 失去全部引用的 Service：Service 不可变，改值会留下旧对象。
    | ([ .rules[].service ] | map(select(. != null))) as $used
    | ([ .services[] | select(.id as $id | $used | index($id) | not) | .name ]
       | if length > 0
         then ["以下 Service 已无任何 Rule 引用：" + join("、")]
         else [] end) as $orphans

    | ($dup_targets + $orphans)[]
    ' "$path" 2>/dev/null || true
}

# ── 规范化 ────────────────────────────────────────────────────────────

# 输出状态的规范形式：字段顺序固定，数组按稳定键排序，端口与地址去重排序。
#
# 规范化让 state.json 的内容与对象的插入历史无关，从而 git diff 与 fw diff
# 只反映真实的语义变化。见 docs/ARCHITECTURE.md 的「渲染确定性」。
#
# 参数：$1=状态文件路径。输出：规范化后的 JSON 到 stdout。
state_normalize() {
    local path=$1
    jq --sort-keys '
    def sorted_ports:
        unique
        | sort_by(
            capture("^(?<start>[0-9]+)(-(?<end>[0-9]+))?$")
            | [(.start | tonumber), ((.end // .start) | tonumber)]
          );

    def sorted_addresses:
        unique
        | sort_by(
            (split("/")[0] | split(".") | map(tonumber)) as $o
            | [$o[0], $o[1], $o[2], $o[3],
               ((split("/")[1] // "32") | tonumber)]
          );

    {
      schema_version,
      settings,
      ports: {
        tcp: (.ports.tcp | sorted_ports),
        udp: (.ports.udp | sorted_ports)
      },
      targets: (.targets | map(.addresses |= sorted_addresses) | sort_by(.id)),
      services: (.services | map(.ports |= sorted_ports) | sort_by(.id)),
      rules: (.rules | sort_by(.priority, .id)),
      comments,
      metadata
    }' "$path"
}

# ── 写回 ──────────────────────────────────────────────────────────────

# 规范化后原子写入目标路径。
# 参数：$1=源状态文件，$2=目标路径。
state_write() {
    local source=$1 target=$2 tmp rc

    tmp=$(fwctl_mktemp_beside "$target") || return 1

    if ! state_normalize "$source" > "$tmp"; then
        rm -f "$tmp"
        fwctl_err "状态规范化失败"
        return 1
    fi

    fwctl_atomic_install "$tmp" "$target" 0644
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

# 更新 metadata 中的时间戳与 generation，输出到 stdout。
# 参数：$1=状态文件路径。
state_touch() {
    local path=$1 now
    now=$(fwctl_now) || return 1
    jq --arg now "$now" '
        .metadata.updated_at = $now
        | .metadata.generation = ((.metadata.generation // 0) + 1)
    ' "$path"
}
