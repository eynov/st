#!/bin/bash
# core/migration.sh —— 迁移层
#
# 职责：把旧的无版本号状态格式（下称 v1）转换成当前 schema。
#
# 依赖：core/common.sh、core/state.sh、core/model.sh
# 用法：本文件只能被 source，不能直接执行。
#
# 迁移必须是确定性且幂等的：同一份输入反复迁移产出逐字节相同的结果，不同机器上
# 迁移同一状态得到相同的对象 id。因此这里禁止使用随机数与当前时间——时间戳取自
# 源文件 mtime，id 由内容哈希派生。见 docs/adr/0004-automatic-schema-migration.md。
#
# 转换全程复用 core/model.sh 的写函数，而不是自己拼 JSON。这样迁移产出的对象与
# 用户用 CLI 创建的对象在 id 派生、字段布局和校验上完全一致，不存在两套实现。

[[ -n "${FWCTL_MIGRATION_LOADED:-}" ]] && return 0
FWCTL_MIGRATION_LOADED=1

# ── 判定 ──────────────────────────────────────────────────────────────

# 判断状态文件是否为需要迁移的旧格式。
# 参数：$1=状态文件路径。
# 返回：0 需要迁移；1 不需要或无法判断。
migration_is_legacy() {
    local path=$1 version
    version=$(state_detect_version "$path" 2>/dev/null) || return 1
    [[ "$version" == 0 ]]
}

# 校验 v1 状态的基本结构。转换前先确认输入可解析，避免在中途失败留下半成品。
# 参数：$1=v1 状态文件路径。
migration_validate_v1() {
    local path=$1 errors

    errors=$(jq -r '
        [ (if (.open_ports? // {}) | type != "object"
           then "open_ports 必须是对象" else empty end),
          (if (.forwards? // []) | type != "array"
           then "forwards 必须是数组" else empty end),
          (if (.blacklist? // []) | type != "array"
           then "blacklist 必须是数组" else empty end),
          (if ((.nat_mode // "auto") | IN("auto","snat","masquerade") | not)
           then "非法 nat_mode \(.nat_mode)；允许值：auto、snat、masquerade"
           else empty end),
          ( (.forwards? // [])[]
            | select((.proto // "") | IN("tcp","udp") | not)
            | "forwards 含非法协议 \(.proto // "(缺失)")" ),
          ( (.forwards? // [])[]
            | select((.dip // "") == "")
            | "forwards 含缺少 dip 的条目" )
        ] | .[]
    ' "$path" 2>&1) || {
        fwctl_err "无法解析旧状态：$errors"
        return 1
    }

    [[ -z "$errors" ]] && return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] && fwctl_err "$line"
    done <<< "$errors"
    return 1
}

# ── 名称派生 ──────────────────────────────────────────────────────────
# 名称必须匹配 ^[a-z0-9][a-z0-9_-]{0,31}$，因此派生结果要规范化并截断。

# 把地址转成可用作名称片段的形式：点和斜杠都换成连字符。
_migration_address_slug() {
    local address=$1
    printf '%s\n' "${address//[.\/]/-}"
}

# 规范化候选名称：截断到 32 字符，去掉尾部连字符。
_migration_clamp_name() {
    local name=$1
    name=${name:0:32}
    while [[ "$name" == *- ]]; do name=${name%-}; done
    printf '%s\n' "$name"
}

# 在指定对象类型中找一个尚未被占用的名称。
# 冲突时追加 -2、-3……，顺序确定。
# 参数：$1=状态文件，$2=类型（targets|services|rules），$3=候选名称。
_migration_unique_name() {
    local state=$1 array=$2 base=$3
    local candidate attempt=1 suffix=""

    base=$(_migration_clamp_name "$base")
    while :; do
        candidate=$(_migration_clamp_name "${base}${suffix}")
        if ! jq -e --arg name "$candidate" --arg array "$array" \
            '.[$array] | any(.name == $name)' "$state" >/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
        attempt=$((attempt + 1))
        suffix="-$attempt"
        # 截断后再加后缀仍可能超长，先把 base 缩短再拼。
        base=${base:0:$((32 - ${#suffix}))}
        ((attempt > 999)) && {
            fwctl_err "无法为 $array 分配唯一名称：$3"
            return 1
        }
    done
}

# ── 转换 ──────────────────────────────────────────────────────────────

# 把 v1 状态转换为当前 schema，结果输出到 stdout。
# 参数：$1=v1 状态文件路径。
#
# 处理顺序是确定的（见 docs/MIGRATION.md）：
#   Target  按 IP 的 32 位数值升序
#   Service 按 (protocol, 起始端口, 结束端口) 升序
#   Rule    按其在 v1 forwards[] 中的原始下标
migration_v1_to_current() {
    local source=$1
    local work now current next

    migration_validate_v1 "$source" || return 1

    # 时间戳取自源文件 mtime，保证同一份输入的迁移结果逐字节稳定。
    now=$(fwctl_file_mtime "$source") || return 1

    work=$(mktemp -d) || {
        fwctl_err "无法创建临时目录"
        return 1
    }
    current="$work/state.json"
    next="$work/next.json"

    # 所有 model_* 调用共用同一个时间源。
    local saved_now=${FWCTL_NOW:-}
    export FWCTL_NOW="$now"

    _migration_cleanup() {
        rm -rf "$work"
        if [[ -n "$saved_now" ]]; then
            export FWCTL_NOW="$saved_now"
        else
            unset FWCTL_NOW
        fi
    }

    if ! state_default > "$current"; then
        fwctl_err "无法生成基础状态"
        _migration_cleanup
        return 1
    fi

    # ── settings 与 ports ──
    # 端口原样搬运，只做去重与数值排序；语义与旧版本逐字一致。
    if ! jq --slurpfile v1 "$source" "
        $(fwctl_jq_port_sort_def)
        (\$v1[0]) as \$old
        | .settings.nat.mode = (\$old.nat_mode // \"auto\")
        | .settings.nat.snat_address = (\$old.snat_address // null)
        | .ports.tcp = ((\$old.open_ports.tcp // []) | sorted_ports)
        | .ports.udp = ((\$old.open_ports.udp // []) | sorted_ports)
        | .metadata.migrated_from = 1
    " "$current" > "$next"; then
        fwctl_err "settings 与 ports 迁移失败"
        _migration_cleanup
        return 1
    fi
    mv -f "$next" "$current" || { _migration_cleanup; return 1; }

    # ── blacklist ──
    # 空 blacklist 不生成任何对象：Target 的 addresses 必须非空，而一个空的
    # 地址集合渲染出来也匹配不到任何流量。两种做法的渲染结果相同。
    local blacklist
    blacklist=$(jq -r '(.blacklist // []) | unique | join(",")' "$source")
    if [[ -n "$blacklist" ]]; then
        if ! model_target_add "$current" blacklist "$blacklist" "" ipv4 > "$next"; then
            fwctl_err "blacklist 迁移失败"
            _migration_cleanup
            return 1
        fi
        mv -f "$next" "$current" || { _migration_cleanup; return 1; }

        local blacklist_id
        blacklist_id=$(model_resolve "$current" target blacklist) || {
            _migration_cleanup
            return 1
        }
        if ! model_rule_add "$current" blacklist block "" "" "$blacklist_id" "" 10 > "$next"; then
            fwctl_err "blacklist 规则生成失败"
            _migration_cleanup
            return 1
        fi
        mv -f "$next" "$current" || { _migration_cleanup; return 1; }
    fi

    # ── forwards ──
    # 第一步：抽取 Target，按 IP 数值升序。
    local dip
    while IFS= read -r dip; do
        [[ -n "$dip" ]] || continue
        local target_name
        target_name=$(_migration_unique_name "$current" targets \
            "t-$(_migration_address_slug "$dip")") || { _migration_cleanup; return 1; }
        if ! model_target_add "$current" "$target_name" "$dip" "" ipv4 > "$next"; then
            fwctl_err "Target $dip 迁移失败"
            _migration_cleanup
            return 1
        fi
        mv -f "$next" "$current" || { _migration_cleanup; return 1; }
    done < <(jq -r '
        [ (.forwards // [])[].dip ]
        | unique
        | sort_by(split(".") | map(tonumber))
        | .[]
    ' "$source")

    # 第二步与第三步：合并协议并抽取 Service。
    # 相同 (sport, dport, dip, dest_port) 只有 proto 不同的两条记录合并成一条
    # protocol=both 的规则；相同 (protocol, 端口区间) 的多条转发复用同一个 Service。
    local merged
    merged=$(jq -c '
        [ (.forwards // []) | to_entries[]
          | .key as $index | .value as $f
          | {
              index: $index,
              sport: $f.sport,
              dport: $f.dport,
              dip: $f.dip,
              proto: $f.proto,
              dest_port: ($f.dest_port // $f.sport),
              portspec: (if $f.sport == $f.dport
                         then $f.sport
                         else "\($f.sport)-\($f.dport)" end)
            }
        ]
        | group_by([.sport, .dport, .dip, .dest_port])
        | map({
            index: (map(.index) | min),
            dip: .[0].dip,
            portspec: .[0].portspec,
            dest_port: .[0].dest_port,
            protocol: (if (map(.proto) | unique | length) == 2
                       then "both" else .[0].proto end)
          })
        | sort_by(.index)
        | .[]
    ' "$source")

    # 先建 Service，按 (protocol, 起始端口, 结束端口) 升序，与规则创建顺序解耦。
    local svc_line
    while IFS= read -r svc_line; do
        [[ -n "$svc_line" ]] || continue
        local proto portspec service_name
        proto=$(jq -r '.protocol' <<< "$svc_line")
        portspec=$(jq -r '.portspec' <<< "$svc_line")

        # 相同 (protocol, ports) 的 Service 只建一次。
        if jq -e --arg proto "$proto" --arg port "$portspec" \
            '.services | any(.protocol == $proto and .ports == [$port])' \
            "$current" >/dev/null; then
            continue
        fi

        service_name=$(_migration_unique_name "$current" services \
            "s-$proto-$portspec") || { _migration_cleanup; return 1; }
        if ! model_service_add "$current" "$service_name" "$proto" "$portspec" "" \
            2>/dev/null > "$next"; then
            fwctl_err "Service $proto/$portspec 迁移失败"
            _migration_cleanup
            return 1
        fi
        mv -f "$next" "$current" || { _migration_cleanup; return 1; }
    done < <(printf '%s\n' "$merged" | jq -sc '
        map(select(. != null))
        | sort_by([
            .protocol,
            (.portspec | split("-")[0] | tonumber),
            (.portspec | split("-") | if length > 1 then .[1] else .[0] end | tonumber)
          ])
        | .[]
    ')

    # 第四步：生成 Rule，按 v1 数组原始下标排序以保留优先级。
    local rule_line
    while IFS= read -r rule_line; do
        [[ -n "$rule_line" ]] || continue
        local proto portspec dip dest_port index rule_name service_id target_id priority
        proto=$(jq -r '.protocol' <<< "$rule_line")
        portspec=$(jq -r '.portspec' <<< "$rule_line")
        dip=$(jq -r '.dip' <<< "$rule_line")
        dest_port=$(jq -r '.dest_port' <<< "$rule_line")
        index=$(jq -r '.index' <<< "$rule_line")

        service_id=$(jq -r --arg proto "$proto" --arg port "$portspec" '
            .services[] | select(.protocol == $proto and .ports == [$port]) | .id
        ' "$current")
        target_id=$(jq -r --arg address "$dip" '
            .targets[] | select(.addresses == [$address]) | .id
        ' "$current" | head -1)

        if [[ -z "$service_id" || -z "$target_id" ]]; then
            fwctl_err "无法为转发 $dip:$portspec 解析出 Service 或 Target"
            _migration_cleanup
            return 1
        fi

        # priority 保留 v1 的相对顺序。上限 65535 足以容纳任意规模的旧状态，
        # 因此不需要截断——截断会让重叠规则的 DNAT 优先级在升级时静默改变。
        priority=$((100 + index))
        if ((priority > 65535)); then
            fwctl_err "转发条目过多（下标 $index），priority 超出上限"
            _migration_cleanup
            return 1
        fi

        rule_name=$(_migration_unique_name "$current" rules \
            "f-$(_migration_address_slug "$dip")-$portspec") || {
            _migration_cleanup
            return 1
        }

        if ! model_rule_add "$current" "$rule_name" forward \
            "$service_id" "$target_id" "" "$dest_port" "$priority" > "$next"; then
            fwctl_err "转发规则 $rule_name 生成失败"
            _migration_cleanup
            return 1
        fi
        mv -f "$next" "$current" || { _migration_cleanup; return 1; }
    done < <(printf '%s\n' "$merged")

    # 规范化输出，保证结果与处理顺序无关。
    if ! state_normalize "$current"; then
        fwctl_err "迁移结果规范化失败"
        _migration_cleanup
        return 1
    fi

    _migration_cleanup
    return 0
}

# 迁移入口：按需把状态升级到当前 schema。
# 已是当前 schema 时原样输出，因此可以无条件调用（幂等）。
# 参数：$1=状态文件路径。输出：当前 schema 的状态 JSON。
migration_to_current() {
    local path=$1 version

    version=$(state_detect_version "$path") || return 1
    state_version_supported "$version" || return 1

    case "$version" in
        0)
            migration_v1_to_current "$path"
            ;;
        "$FWCTL_SCHEMA_VERSION")
            state_normalize "$path"
            ;;
        *)
            fwctl_err "没有从版本 $version 到 $FWCTL_SCHEMA_VERSION 的迁移路径"
            return 1
            ;;
    esac
}
