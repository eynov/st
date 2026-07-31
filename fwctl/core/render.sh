#!/bin/bash
# core/render.sh —— 渲染层
#
# 职责：把状态编译成 nftables 配置文本。
#
# 依赖：core/common.sh
# 用法：本文件只能被 source，不能直接执行。
#
# 本模块是纯函数：输入是状态 JSON 加一份「外部事实」JSON，输出是 nft 文本。
# 它不查 DNS、不读网络接口、不调 sysctl、不读内核、不写任何文件。所有外部事实
# 由事务层探测后传入，因此渲染可以在无 root、无内核的环境中被完整测试，也可以
# 对同一输入反复重放得到逐字节相同的结果。
#
# 渲染契约见 docs/ARCHITECTURE.md 与 docs/adr/0002-own-table-no-flush.md：
# 只管理 table ip fwctl，绝不执行 flush ruleset。

[[ -n "${FWCTL_RENDER_LOADED:-}" ]] && return 0
FWCTL_RENDER_LOADED=1

# fwctl 拥有的表名。表内同时容纳 filter 与 nat 两类 chain，因此一次
# delete table 就能原子替换全部规则。
declare -rx FWCTL_TABLE=fwctl

# 渲染保留的 set 名。Target 的 set 直接用它自己的名字，因此这两个名字不能被
# Target 占用（由 state 语义校验拒绝）。
declare -rx FWCTL_RESERVED_SET_NAMES="allowed_ports_tcp allowed_ports_udp"

# ── 外部事实 ──────────────────────────────────────────────────────────

# 构造一份外部事实 JSON。
# 参数：$1=ssh 端口，$2=本机 IPv4 列表（空格分隔），$3=公网 IPv4，
#       $4=待接管的旧表（空格分隔）。
render_facts() {
    local ssh_port=${1:-22} local_ipv4s=${2:-} public_ipv4=${3:-} legacy=${4:-}
    jq -n \
        --argjson ssh_port "$ssh_port" \
        --arg local_ipv4s "$local_ipv4s" \
        --arg public_ipv4 "$public_ipv4" \
        --arg legacy "$legacy" '
        {
          ssh_port: $ssh_port,
          local_ipv4s: ($local_ipv4s | split(" ") | map(select(. != ""))),
          public_ipv4: (if $public_ipv4 == "" then null else $public_ipv4 end),
          legacy_tables: ($legacy | split(" ") | map(select(. != "")))
        }'
}

# ── NAT 动作选择 ──────────────────────────────────────────────────────

# 依据 nat 模式与外部事实决定源 NAT 动作。
# 语义与旧版本逐字一致：只有候选地址确实存在于本机接口时才生成显式 SNAT，
# 否则回退到 masquerade——把不属于本机接口的地址写进 snat to 会产生源地址
# 不属于本机的数据包，云网络可能直接丢弃（例如 AWS 的 EIP 属于 1:1 NAT，
# 实例网卡上只有私网地址）。
#
# 参数：$1=状态文件，$2=外部事实 JSON。
# 输出：nft 源 NAT 动作片段（masquerade 或 snat to <地址>）。
render_nat_action() {
    local state=$1 facts=$2
    local mode configured candidate

    mode=$(jq -r '.settings.nat.mode // "auto"' "$state")
    configured=$(jq -r '.settings.nat.snat_address // empty' "$state")

    case "$mode" in
        masquerade)
            printf 'masquerade\n'
            return 0
            ;;
        snat)
            if [[ -z "$configured" ]] || ! fwctl_is_ipv4 "$configured"; then
                fwctl_err "nat_mode=snat 要求提供合法的 snat_address"
                return 1
            fi
            if ! jq -e --arg address "$configured" --argjson facts "$facts" \
                -n '$facts.local_ipv4s | index($address) != null' >/dev/null; then
                fwctl_err "snat_address $configured 未配置在本机任一 IPv4 接口，拒绝生成规则"
                return 1
            fi
            printf 'snat to %s\n' "$configured"
            return 0
            ;;
        auto)
            candidate=$configured
            [[ -n "$candidate" ]] ||
                candidate=$(jq -r --argjson facts "$facts" -n \
                    '$facts.public_ipv4 // empty')

            if [[ -n "$candidate" ]] && fwctl_is_ipv4 "$candidate" &&
                jq -e --arg address "$candidate" --argjson facts "$facts" \
                    -n '$facts.local_ipv4s | index($address) != null' >/dev/null; then
                printf 'snat to %s\n' "$candidate"
            else
                printf 'masquerade\n'
            fi
            return 0
            ;;
        *)
            fwctl_err "非法 nat_mode '$mode'；允许值：auto、snat、masquerade"
            return 1
            ;;
    esac
}

# ── 渲染 ──────────────────────────────────────────────────────────────

# 输出渲染用的 jq 程序。
#
# 全部排序都是显式的，输出与对象的插入历史无关：规则按 (priority, id)，
# set 元素按数值区间，chain 按固定顺序。
_render_jq() {
    cat <<'JQ'
# ── 通用 ──
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
        | [$o[0], $o[1], $o[2], $o[3], ((split("/")[1] // "32") | tonumber)]
      );

# 单个元素直接写字面量，多个元素用匿名 set。
def port_match:
    if length == 1 then .[0] else "{ " + join(", ") + " }" end;

# protocol=both 在存储中是一个对象，渲染时展开成两条规则。
def protocols($p):
    if $p == "both" then ["tcp", "udp"] else [$p] end;

# ── 索引 ──
(.settings.render) as $render
| (.comments) as $comments
| (.settings.policy) as $policy
| ([ .targets[] | select(.enabled) | {key: .id, value: .} ] | from_entries) as $targets
| ([ .services[] | {key: .id, value: .} ] | from_entries) as $services

# 只渲染启用的规则，且其引用的对象也必须启用。禁用的对象不留占位规则。
| ([ .rules[]
     | select(.enabled)
     | select(.target == null or ($targets[.target] != null))
     | select(.source == null or ($targets[.source] != null))
   ] | sort_by(.priority, .id)) as $rules

| ([ $rules[] | select(.type == "block") ]) as $block_rules
| ([ $rules[] | select(.type == "accept") ]) as $accept_rules
| ([ $rules[] | select(.type == "forward") ]) as $forward_rules

# 需要具名 set 的 Target：被 block 规则用作来源匹配的那些。
#
# 来源匹配是集合成员判定，set 是对的工具，而且地址增减只影响 set 内容。
# DNAT 目的地则相反：nftables 的 `dnat to` 不接受 set，因此转发目标一律渲染成
# 字面量地址（多地址 Target 用作转发目的地已在语义校验中被拒绝）。
| ([ $rules[] | select(.type == "block") | .source ]
   | map(select(. != null)) | unique) as $source_ids
| ([ $source_ids[] | $targets[.] | select(. != null) ]
   | unique_by(.id) | sort_by(.name)) as $set_targets

# counter 与 comment 都可以整体关闭。comment 以 fwctl:<id> 开头，
# fw stats 依赖这个前缀把内核计数器关联回对象。
# 这两个 def 必须放在上面的绑定之后：jq 的 def 只能引用已经绑定的变量。
| def counter_frag:
      if $render.counters then " counter" else "" end;
  # nftables 的 comment 上限是 128 **字节**（不是字符）：43 个中文字就是 129
  # 字节，会被内核拒绝。因此必须按字节截断，否则一条中文注释就能产生加载不了
  # 的 ruleset。
  def clamp_bytes($max):
      . as $s
      | if ($s | utf8bytelength) <= $max then $s
        else ([ range(0; ($s | length) + 1) ]
              | map(select(($s[0:.] | utf8bytelength) <= $max))
              | last) as $n
             | $s[0:$n]
        end;
  def comment_frag($id):
      if $render.comments | not then ""
      else
          ($comments[$id] // "") as $text
          | (if $text == "" then "fwctl:\($id)" else "fwctl:\($id) \($text)" end)
          | clamp_bytes(128)
          | " comment \"\(.)\""
      end;
  # block 规则的来源：始终引用与 Target 同名的 set。
  # 即使只有一个地址也用 set，这样地址增减不改变规则文本，且与旧实现的
  # 渲染形态一致。
  def source_ref($id):
      "@\($targets[$id].name)";
  # 转发目的地：始终是字面量地址。dnat to @set 在 nftables 中非法，
  # 多地址 Target 用作转发目的地已在语义校验中被拒绝。
  def dest_ref($id):
      $targets[$id].addresses[0];
  # 内建规则（SSH、放行端口、SYN 限速）也要受 render.comments 开关约束，
  # 否则关闭注释后内核里仍会残留一半注释。
  def builtin_comment($tag):
      if $render.comments then " comment \"fwctl:\($tag)\"" else "" end;

# ── 片段生成 ──
  [
    "table ip \($table) { }",
    "delete table ip \($table)"
  ]
  + ( $legacy_tables
      | map(["table ip \(.) { }", "delete table ip \(.)"])
      | flatten )
  + [ "", "table ip \($table) {" ]

  # 放行端口的 set。即使为空也保留声明：规则引用空 set 时匹配不到任何流量，
  # 与旧实现用占位端口的效果相同，但不再需要伪造元素。
  + [ "    set allowed_ports_tcp {",
      "        type inet_service",
      "        flags interval" ]
  + (if (.ports.tcp | length) > 0
     then ["        elements = { " + (.ports.tcp | sorted_ports | join(", ")) + " }"]
     else [] end)
  + [ "    }", "" ]
  + [ "    set allowed_ports_udp {",
      "        type inet_service",
      "        flags interval" ]
  + (if (.ports.udp | length) > 0
     then ["        elements = { " + (.ports.udp | sorted_ports | join(", ")) + " }"]
     else [] end)
  + [ "    }", "" ]

  # 多地址 Target 的 set，名字就是 Target 的名字，便于 nft list 直接读懂。
  + ( $set_targets
      | map([
          "    set \(.name) {",
          "        type ipv4_addr",
          "        flags interval",
          "        elements = { " + (.addresses | sorted_addresses | join(", ")) + " }",
          "    }",
          ""
        ])
      | flatten )

  # ── input chain ──
  # 规则顺序与旧实现一致：lo、established、block、SSH、放行端口、accept 规则，
  # 最后才是 SYN 限速——限速必须在放行之后，否则已明确放行的端口会被面向
  # 未放行端口的聚合限速提前丢弃。
  + [ "    chain input {",
      "        type filter hook input priority filter; policy \($policy.input);",
      "",
      "        iifname \"lo\" accept",
      "        ct state established,related accept" ]
  + (if $policy.ct_invalid == "drop"
     then ["        ct state invalid" + counter_frag + " drop"] else [] end)
  + (if ($block_rules | length) > 0 then [""] else [] end)
  + ( $block_rules
      | map("        ip saddr " + source_ref(.source)
            + counter_frag + " drop" + comment_frag(.id)) )
  + [ "",
      "        tcp dport \($ssh_port)" + counter_frag + " accept" + builtin_comment("ssh"),
      "        tcp dport @allowed_ports_tcp" + counter_frag + " accept" + builtin_comment("ports-tcp"),
      "        udp dport @allowed_ports_udp" + counter_frag + " accept" + builtin_comment("ports-udp") ]
  + ( $accept_rules
      | map(. as $r
            | $services[$r.service] as $svc
            | protocols($svc.protocol)
            | map("        \(.) dport " + ($svc.ports | sorted_ports | port_match)
                  + counter_frag + " accept" + comment_frag($r.id)))
      | flatten )
  + (if $policy.icmp_echo == "accept"
     then ["", "        icmp type echo-request" + counter_frag + " accept"]
     elif $policy.icmp_echo == "limit"
     then ["", "        icmp type echo-request limit rate 10/second" + counter_frag + " accept"]
     else [] end)
  + (if $policy.syn_limit.enabled
     then ["",
           "        tcp flags syn limit rate over \($policy.syn_limit.rate) burst \($policy.syn_limit.burst) packets"
           + counter_frag + " drop" + builtin_comment("syn-limit")]
     else [] end)
  + [ "    }", "" ]

  # ── forward chain ──
  + [ "    chain forward {",
      "        type filter hook forward priority filter; policy \($policy.forward);",
      "    }", "" ]

  # ── nat chains ──
  # DNAT 匹配对外端口；SNAT 匹配转换后的端口，与旧实现一致。
  + [ "    chain prerouting {",
      "        type nat hook prerouting priority dstnat; policy accept;" ]
  + ( $forward_rules
      | map(. as $r
            | $services[$r.service] as $svc
            | dest_ref($r.target) as $dest
            | protocols($svc.protocol)
            | map("        \(.) dport " + ($svc.ports | sorted_ports | port_match)
                  + counter_frag
                  + (if $r.translate.port == null
                     then " dnat to \($dest)"
                     else " dnat to \($dest):\($r.translate.port)" end)
                  + comment_frag($r.id)))
      | flatten )
  + [ "    }", "" ]
  + [ "    chain postrouting {",
      "        type nat hook postrouting priority srcnat; policy accept;" ]
  + ( $forward_rules
      | map(. as $r
            | $services[$r.service] as $svc
            | dest_ref($r.target) as $dest
            | (if $r.translate.port == null
               then ($svc.ports | sorted_ports | port_match)
               else $r.translate.port end) as $dport
            | protocols($svc.protocol)
            | map("        ip daddr \($dest) \(.) dport \($dport)"
                  + counter_frag + " \($nat_action)" + comment_frag($r.id)))
      | flatten )
  + [ "    }" ]
  + [ "}" ]
| .[]
JQ
}

# 把状态渲染成 nftables 配置文本。
# 参数：$1=状态文件，$2=外部事实 JSON。
# 输出：nft 配置到 stdout。
render_ruleset() {
    local state=$1 facts=$2
    local nat_action ssh_port legacy_tables

    nat_action=$(render_nat_action "$state" "$facts") || return 1

    ssh_port=$(jq -r '.ssh_port // 22' <<< "$facts")
    if [[ ! "$ssh_port" =~ ^[0-9]+$ ]] || ((ssh_port < 1 || ssh_port > 65535)); then
        fwctl_err "无法确定合法的 SSH 端口：$ssh_port"
        return 1
    fi

    legacy_tables=$(jq -c '.legacy_tables // []' <<< "$facts")

    jq -r \
        --arg table "$FWCTL_TABLE" \
        --arg nat_action "$nat_action" \
        --argjson ssh_port "$ssh_port" \
        --argjson legacy_tables "$legacy_tables" \
        "$(_render_jq)" "$state"
}
