#!/bin/bash
# core/model.sh —— 模型层
#
# 职责：Target / Service / Rule 的 CRUD、引用解析、确定性 ID 分配、
#       Service 不可变性强制、引用完整性与级联删除。
#
# 依赖：core/common.sh、core/state.sh
# 用法：本文件只能被 source，不能直接执行。
#
# 所有写函数的约定：读入状态文件，把修改后的完整状态输出到 stdout，
# 不直接落盘。持久化是事务层的职责，这样每个修改都能先被校验再决定是否提交。

[[ -n "${FWCTL_MODEL_LOADED:-}" ]] && return 0
FWCTL_MODEL_LOADED=1

# ── ID 分配 ───────────────────────────────────────────────────────────

# 派生某类对象的规范化内容串，作为 ID 哈希的输入。
# 内容取自对象的「值」，不取自 name——name 可以重命名，而 ID 必须稳定。
# 参数：$1=类型，其余为该类型的值字段。
_model_id_content() {
    local kind=$1
    shift
    case "$kind" in
        target)
            # 地址集合（已排序去重）
            printf '%s' "$1"
            ;;
        service)
            # protocol|ports
            printf '%s|%s' "$1" "$2"
            ;;
        rule)
            # type|service|target|source|translate_port
            printf '%s|%s|%s|%s|%s' "$1" "$2" "$3" "$4" "$5"
            ;;
        *)
            fwctl_err "未知对象类型：$kind"
            return 1
            ;;
    esac
}

# 分配一个在当前状态中尚未被使用的 ID。
# 碰撞时向哈希输入追加 #2、#3…… 重算，直到不冲突——顺序确定，可复现。
# 参数：$1=状态文件，$2=类型，$3=内容串。
model_allocate_id() {
    local state=$1 kind=$2 content=$3
    local candidate salt="" attempt=1 existing

    existing=$(jq -r '[ (.targets[].id), (.services[].id), (.rules[].id) ] | .[]' \
        "$state" 2>/dev/null) || existing=""

    while :; do
        candidate=$(fwctl_object_id "$kind" "$content" "$salt") || return 1
        if ! grep -Fxq "$candidate" <<< "$existing"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        attempt=$((attempt + 1))
        salt="#$attempt"
        # 12 位十六进制有 2^48 种取值，正常使用不可能走到这里；设上限只是
        # 为了在哈希函数出问题时不至于死循环。
        if ((attempt > 1000)); then
            fwctl_err "无法为 $kind 分配唯一 ID：连续 1000 次碰撞"
            return 1
        fi
    done
}

# ── 引用解析 ──────────────────────────────────────────────────────────

# 把用户输入的 name 或 id 解析成 id。
# 参数：$1=状态文件，$2=类型（target|service|rule），$3=引用串。
# 输出：id。找不到或有歧义时报错并返回 1。
model_resolve() {
    local state=$1 kind=$2 ref=$3 array matches count

    case "$kind" in
        target)  array=targets ;;
        service) array=services ;;
        rule)    array=rules ;;
        *)
            fwctl_err "未知对象类型：$kind"
            return 1
            ;;
    esac

    matches=$(jq -r --arg ref "$ref" --arg array "$array" '
        .[$array] | map(select(.id == $ref or .name == $ref)) | .[].id
    ' "$state") || return 1

    count=$(grep -c . <<< "$matches")
    [[ -z "$matches" ]] && count=0

    case "$count" in
        0)
            fwctl_err "找不到 $kind：$ref"
            return 1
            ;;
        1)
            printf '%s\n' "$matches"
            return 0
            ;;
        *)
            # name 唯一性由校验保证，正常不会走到这里；真出现时明确报错而不是
            # 随便选一个。
            fwctl_err "$kind 引用 '$ref' 有歧义，匹配到多个对象"
            return 1
            ;;
    esac
}

# 列出引用了指定对象的规则名。
# 参数：$1=状态文件，$2=对象 id。
model_referencing_rules() {
    local state=$1 id=$2
    jq -r --arg id "$id" '
        .rules[]
        | select(.service == $id or .target == $id or .source == $id)
        | .name
    ' "$state"
}

# ── Target ────────────────────────────────────────────────────────────

# 新增 Target。
# 参数：$1=状态文件，$2=name，$3=地址（逗号分隔），$4=description，
#       $5=kind（ipv4|hostname），$6=hostname（kind=hostname 时）。
model_target_add() {
    local state=$1 name=$2 addresses=$3 description=${4:-} kind=${5:-ipv4}
    local hostname=${6:-} now id sorted address address_list

    # 逐个校验地址，错误信息指向具体的那一个。
    IFS=',' read -r -a address_list <<< "$addresses"
    ((${#address_list[@]} > 0)) || {
        fwctl_err "至少需要一个地址"
        return 1
    }
    for address in "${address_list[@]}"; do
        fwctl_is_address "$address" || {
            fwctl_err "非法地址 '$address'；必须是 IPv4 或 IPv4 CIDR"
            return 1
        }
    done

    if jq -e --arg name "$name" '.targets | any(.name == $name)' "$state" >/dev/null; then
        fwctl_err "Target 名称 '$name' 已存在"
        return 1
    fi

    # 排序后的地址串既是 ID 的输入，也是存储形态，保证同一集合总得到同一 ID。
    sorted=$(printf '%s\n' "${address_list[@]}" | sort -u -t. -k1,1n -k2,2n -k3,3n -k4,4n | paste -sd,)
    id=$(model_allocate_id "$state" target "$sorted") || return 1
    now=$(fwctl_now) || return 1

    jq --arg id "$id" --arg name "$name" --arg description "$description" \
       --arg kind "$kind" --arg hostname "$hostname" --arg now "$now" \
       --argjson addresses "$(printf '%s\n' "${address_list[@]}" | jq -R . | jq -sc 'unique')" '
        .targets += [
            ({
                id: $id, name: $name, description: $description,
                kind: $kind, addresses: $addresses, enabled: true,
                created_at: $now, updated_at: $now
            })
            + (if $kind == "hostname"
               then { hostname: $hostname, resolved_at: $now }
               else {} end)
        ]
    ' "$state"
}

# 修改 Target。地址变更会影响全部引用它的规则——这是 Target 作为实体的预期行为。
# 参数：$1=状态文件，$2=id，其余为 key=value 形式的字段。
model_target_edit() {
    local state=$1 id=$2
    shift 2
    local now key value new_name="" new_desc="" new_addresses="" has_name=0 has_desc=0 has_addr=0

    for kv in "$@"; do
        key=${kv%%=*}
        value=${kv#*=}
        case "$key" in
            name)      new_name=$value; has_name=1 ;;
            description) new_desc=$value; has_desc=1 ;;
            addresses) new_addresses=$value; has_addr=1 ;;
            *)
                fwctl_err "未知字段：$key"
                return 1
                ;;
        esac
    done

    if ((has_name)); then
        if jq -e --arg name "$new_name" --arg id "$id" \
            '.targets | any(.name == $name and .id != $id)' "$state" >/dev/null; then
            fwctl_err "Target 名称 '$new_name' 已存在"
            return 1
        fi
    fi

    local addresses_json='null'
    if ((has_addr)); then
        local address address_list
        IFS=',' read -r -a address_list <<< "$new_addresses"
        for address in "${address_list[@]}"; do
            fwctl_is_address "$address" || {
                fwctl_err "非法地址 '$address'；必须是 IPv4 或 IPv4 CIDR"
                return 1
            }
        done
        addresses_json=$(printf '%s\n' "${address_list[@]}" | jq -R . | jq -sc 'unique')
    fi

    now=$(fwctl_now) || return 1

    # ID 不随任何编辑重算，这是 ADR 0001 冻结的约束。
    jq --arg id "$id" --arg now "$now" \
       --arg name "$new_name" --argjson has_name "$has_name" \
       --arg description "$new_desc" --argjson has_desc "$has_desc" \
       --argjson addresses "$addresses_json" '
        .targets |= map(
            if .id == $id then
                (if $has_name == 1 then .name = $name else . end)
                | (if $has_desc == 1 then .description = $description else . end)
                | (if $addresses != null then .addresses = $addresses else . end)
                | .updated_at = $now
            else . end
        )
    ' "$state"
}

# 删除 Target。默认拒绝删除仍被引用的对象。
# 参数：$1=状态文件，$2=id，$3=cascade（1 时连同引用它的规则一起删除）。
model_target_delete() {
    local state=$1 id=$2 cascade=${3:-0} refs

    refs=$(model_referencing_rules "$state" "$id")
    if [[ -n "$refs" && "$cascade" != 1 ]]; then
        fwctl_err "Target 仍被以下 Rule 引用，拒绝删除：$(paste -sd'、' <<< "$refs")"
        fwctl_err "确认要一并删除这些规则时使用 --cascade"
        return 1
    fi

    jq --arg id "$id" '
        .rules |= map(select(.target != $id and .source != $id))
        | .targets |= map(select(.id != $id))
        | .comments |= with_entries(select(.key != $id))
    ' "$state"
}

# 启用或禁用 Target。
# 参数：$1=状态文件，$2=id，$3=true|false。
model_target_set_enabled() {
    local state=$1 id=$2 enabled=$3 now
    now=$(fwctl_now) || return 1
    jq --arg id "$id" --argjson enabled "$enabled" --arg now "$now" '
        .targets |= map(
            if .id == $id then .enabled = $enabled | .updated_at = $now else . end
        )
    ' "$state"
}

# ── Service ───────────────────────────────────────────────────────────

# 新增 Service。
# 参数：$1=状态文件，$2=name，$3=protocol，$4=端口（逗号分隔），$5=description。
model_service_add() {
    local state=$1 name=$2 protocol=$3 ports=$4 description=${5:-}
    local proto now id normalized port port_list ports_json

    proto=$(fwctl_validate_protocol "$protocol") || return 1

    IFS=',' read -r -a port_list <<< "$ports"
    ((${#port_list[@]} > 0)) || {
        fwctl_err "至少需要一个端口"
        return 1
    }
    normalized=()
    for port in "${port_list[@]}"; do
        local canonical
        canonical=$(fwctl_normalize_port_spec "$port") || return 1
        normalized+=("$canonical")
    done

    if jq -e --arg name "$name" '.services | any(.name == $name)' "$state" >/dev/null; then
        fwctl_err "Service 名称 '$name' 已存在"
        return 1
    fi

    ports_json=$(printf '%s\n' "${normalized[@]}" | jq -R . | jq -sc 'unique')

    # ID 由「值」派生：protocol 与端口集合。相同值的两个 Service 会碰撞并由
    # 盐区分，这不影响正确性，但提示用户可能重复。
    if jq -e --arg proto "$proto" --argjson ports "$ports_json" \
        '.services | any(.protocol == $proto and (.ports | sort) == ($ports | sort))' \
        "$state" >/dev/null; then
        fwctl_warn "已存在协议与端口完全相同的 Service，可直接复用而不必新建"
    fi

    id=$(model_allocate_id "$state" service \
        "$(_model_id_content service "$proto" "$(printf '%s' "$ports_json")")") || return 1
    now=$(fwctl_now) || return 1

    jq --arg id "$id" --arg name "$name" --arg description "$description" \
       --arg protocol "$proto" --argjson ports "$ports_json" --arg now "$now" '
        .services += [{
            id: $id, name: $name, description: $description,
            protocol: $protocol, ports: $ports,
            created_at: $now, updated_at: $now
        }]
    ' "$state"
}

# 修改 Service 的显示元数据。
# 只允许改 name 与 description——(protocol, ports) 是不可变的值，
# 改值必须走 model_service_replace，见 ADR 0001。
# 参数：$1=状态文件，$2=id，其余为 key=value。
model_service_edit_metadata() {
    local state=$1 id=$2
    shift 2
    local now key value new_name="" new_desc="" has_name=0 has_desc=0

    for kv in "$@"; do
        key=${kv%%=*}
        value=${kv#*=}
        case "$key" in
            name)        new_name=$value; has_name=1 ;;
            description) new_desc=$value; has_desc=1 ;;
            protocol|ports)
                fwctl_err "Service 的 $key 是不可变的值，不能原地修改"
                fwctl_err "请使用 fw service edit <name> --$key ... --refs <规则> 或 --all-refs"
                return 1
                ;;
            *)
                fwctl_err "未知字段：$key"
                return 1
                ;;
        esac
    done

    if ((has_name)); then
        if jq -e --arg name "$new_name" --arg id "$id" \
            '.services | any(.name == $name and .id != $id)' "$state" >/dev/null; then
            fwctl_err "Service 名称 '$new_name' 已存在"
            return 1
        fi
    fi

    now=$(fwctl_now) || return 1
    jq --arg id "$id" --arg now "$now" \
       --arg name "$new_name" --argjson has_name "$has_name" \
       --arg description "$new_desc" --argjson has_desc "$has_desc" '
        .services |= map(
            if .id == $id then
                (if $has_name == 1 then .name = $name else . end)
                | (if $has_desc == 1 then .description = $description else . end)
                | .updated_at = $now
            else . end
        )
    ' "$state"
}

# 用新值替换 Service：新建对象并重写指定的引用。
# 这是「修改 Service 端口/协议」的唯一途径，爆炸半径由调用方显式声明。
# 参数：$1=状态文件，$2=旧 id，$3=新 name，$4=protocol，$5=端口（逗号分隔），
#       $6=要重写的规则 id（逗号分隔；空串表示不重写任何引用）。
model_service_replace() {
    local state=$1 old_id=$2 new_name=$3 protocol=$4 ports=$5 rule_ids=$6
    local proto now id normalized port port_list ports_json rules_json

    proto=$(fwctl_validate_protocol "$protocol") || return 1

    IFS=',' read -r -a port_list <<< "$ports"
    normalized=()
    for port in "${port_list[@]}"; do
        local canonical
        canonical=$(fwctl_normalize_port_spec "$port") || return 1
        normalized+=("$canonical")
    done
    ports_json=$(printf '%s\n' "${normalized[@]}" | jq -R . | jq -sc 'unique')

    if jq -e --arg name "$new_name" '.services | any(.name == $name)' "$state" >/dev/null; then
        fwctl_err "Service 名称 '$new_name' 已存在"
        return 1
    fi

    id=$(model_allocate_id "$state" service \
        "$(_model_id_content service "$proto" "$(printf '%s' "$ports_json")")") || return 1
    now=$(fwctl_now) || return 1

    if [[ -n "$rule_ids" ]]; then
        rules_json=$(tr ',' '\n' <<< "$rule_ids" | jq -R . | jq -sc 'map(select(. != ""))')
    else
        rules_json='[]'
    fi

    # 旧 Service 保留：它可能仍被其他规则引用，即使没有也可能还有复用价值。
    # 失去引用后由 state_warnings 报告为孤儿。
    jq --arg id "$id" --arg name "$new_name" --arg protocol "$proto" \
       --argjson ports "$ports_json" --arg now "$now" \
       --argjson rules "$rules_json" --arg old_id "$old_id" '
        .services += [{
            id: $id, name: $name, description: "",
            protocol: $protocol, ports: $ports,
            created_at: $now, updated_at: $now
        }]
        | .rules |= map(
            # 规则的 id 必须先绑定：在 `$rules | index(.id)` 里，`.` 指的是
            # $rules 数组本身，而不是当前规则。
            . as $rule
            | if ($rule.service == $old_id) and (($rules | index($rule.id)) != null)
              then .service = $id | .updated_at = $now
              else . end
        )
    ' "$state"
}

# 删除 Service。
# 参数：$1=状态文件，$2=id，$3=cascade。
model_service_delete() {
    local state=$1 id=$2 cascade=${3:-0} refs

    refs=$(model_referencing_rules "$state" "$id")
    if [[ -n "$refs" && "$cascade" != 1 ]]; then
        fwctl_err "Service 仍被以下 Rule 引用，拒绝删除：$(paste -sd'、' <<< "$refs")"
        fwctl_err "确认要一并删除这些规则时使用 --cascade"
        return 1
    fi

    jq --arg id "$id" '
        .rules |= map(select(.service != $id))
        | .services |= map(select(.id != $id))
        | .comments |= with_entries(select(.key != $id))
    ' "$state"
}

# ── Rule ──────────────────────────────────────────────────────────────

# 新增 Rule。
# 参数：$1=状态文件，$2=name，$3=type，$4=service id 或空，$5=target id 或空，
#       $6=source id 或空，$7=translate port 或空，$8=priority，$9=description。
model_rule_add() {
    local state=$1 name=$2 type=$3 service=${4:-} target=${5:-} source=${6:-}
    local translate=${7:-} priority=${8:-100} description=${9:-}
    local now id canonical

    case "$type" in
        accept|forward|block) ;;
        *)
            fwctl_err "非法规则类型 '$type'；只允许 accept、forward 或 block"
            return 1
            ;;
    esac

    if jq -e --arg name "$name" '.rules | any(.name == $name)' "$state" >/dev/null; then
        fwctl_err "Rule 名称 '$name' 已存在"
        return 1
    fi

    if [[ -n "$translate" ]]; then
        canonical=$(fwctl_normalize_port_spec "$translate") || return 1
        if [[ "$canonical" == *-* ]]; then
            fwctl_err "translate.port 必须是单端口，不能是范围"
            return 1
        fi
        translate=$canonical
    fi

    if [[ ! "$priority" =~ ^[0-9]+$ ]] || ((priority > 1000)); then
        fwctl_err "priority 必须是 0-1000 的整数"
        return 1
    fi

    id=$(model_allocate_id "$state" rule \
        "$(_model_id_content rule "$type" "$service" "$target" "$source" "$translate")") || return 1
    now=$(fwctl_now) || return 1

    jq --arg id "$id" --arg name "$name" --arg description "$description" \
       --arg type "$type" --argjson priority "$priority" --arg now "$now" \
       --arg service "$service" --arg target "$target" --arg source "$source" \
       --arg translate "$translate" '
        def nullable($v): if $v == "" then null else $v end;
        .rules += [{
            id: $id, name: $name, description: $description,
            type: $type, enabled: true, priority: $priority,
            service: nullable($service),
            target: nullable($target),
            source: nullable($source),
            translate: { port: nullable($translate) },
            created_at: $now, updated_at: $now
        }]
    ' "$state"
}

# 修改 Rule。
# 参数：$1=状态文件，$2=id，其余为 key=value。
model_rule_edit() {
    local state=$1 id=$2
    shift 2
    local now key value filter='.' kv

    now=$(fwctl_now) || return 1

    # 逐个字段构造 jq 更新表达式。值通过 --arg 传入，不做字符串拼接。
    local -a jq_args=()
    for kv in "$@"; do
        key=${kv%%=*}
        value=${kv#*=}
        case "$key" in
            name)
                if jq -e --arg name "$value" --arg id "$id" \
                    '.rules | any(.name == $name and .id != $id)' "$state" >/dev/null; then
                    fwctl_err "Rule 名称 '$value' 已存在"
                    return 1
                fi
                jq_args+=(--arg "v_name" "$value")
                filter="$filter | .name = \$v_name"
                ;;
            description)
                jq_args+=(--arg "v_description" "$value")
                filter="$filter | .description = \$v_description"
                ;;
            priority)
                if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value > 1000)); then
                    fwctl_err "priority 必须是 0-1000 的整数"
                    return 1
                fi
                jq_args+=(--argjson "v_priority" "$value")
                filter="$filter | .priority = \$v_priority"
                ;;
            service|target|source)
                jq_args+=(--arg "v_$key" "$value")
                filter="$filter | .$key = (if \$v_$key == \"\" then null else \$v_$key end)"
                ;;
            translate)
                if [[ -n "$value" ]]; then
                    local canonical
                    canonical=$(fwctl_normalize_port_spec "$value") || return 1
                    if [[ "$canonical" == *-* ]]; then
                        fwctl_err "translate.port 必须是单端口，不能是范围"
                        return 1
                    fi
                    value=$canonical
                fi
                jq_args+=(--arg "v_translate" "$value")
                filter="$filter | .translate.port = (if \$v_translate == \"\" then null else \$v_translate end)"
                ;;
            *)
                fwctl_err "未知字段：$key"
                return 1
                ;;
        esac
    done

    jq --arg id "$id" --arg now "$now" "${jq_args[@]}" "
        .rules |= map(if .id == \$id then ($filter | .updated_at = \$now) else . end)
    " "$state"
}

# 删除 Rule。Rule 不被任何对象引用，因此无需 cascade。
# 参数：$1=状态文件，$2=id。
model_rule_delete() {
    local state=$1 id=$2
    jq --arg id "$id" '
        .rules |= map(select(.id != $id))
        | .comments |= with_entries(select(.key != $id))
    ' "$state"
}

# 启用或禁用 Rule。
# 参数：$1=状态文件，$2=id，$3=true|false。
model_rule_set_enabled() {
    local state=$1 id=$2 enabled=$3 now
    now=$(fwctl_now) || return 1
    jq --arg id "$id" --argjson enabled "$enabled" --arg now "$now" '
        .rules |= map(
            if .id == $id then .enabled = $enabled | .updated_at = $now else . end
        )
    ' "$state"
}

# ── 注释 ──────────────────────────────────────────────────────────────

# 设置或清除对象注释。注释会渲染进 nftables comment，因此有长度与字符限制。
# 参数：$1=状态文件，$2=对象 id 或合成键，$3=注释文本（空串表示删除）。
model_comment_set() {
    local state=$1 key=$2 text=$3

    if [[ "$text" == *'"'* || "$text" == *$'\n'* ]]; then
        fwctl_err "注释不得包含双引号或换行"
        return 1
    fi
    # nftables 的 comment 上限是 128 字节，超出会在 apply 时报错，
    # 因此在写入时就截断而不是等到渲染。
    if ((${#text} > 128)); then
        text=${text:0:128}
        fwctl_warn "注释超过 128 字节，已截断"
    fi

    jq --arg key "$key" --arg text "$text" '
        if $text == "" then .comments |= with_entries(select(.key != $key))
        else .comments[$key] = $text end
    ' "$state"
}

# 清理指向已不存在对象的注释。
# 参数：$1=状态文件。
model_comment_prune() {
    local state=$1
    jq '
        ([ (.targets[].id), (.services[].id), (.rules[].id) ]) as $ids
        | .comments |= with_entries(
            select((.key as $k | $ids | index($k)) != null
                   or (.key | test("^(tcp|udp):[0-9]+(-[0-9]+)?$")))
          )
    ' "$state"
}

# ── 端口清单 ──────────────────────────────────────────────────────────
# ports 是旧版本 open_ports 的等价物，语义逐字保留。

# 增删放行端口。
# 参数：$1=状态文件，$2=add|remove，$3=协议，$4=端口规范。
model_port_update() {
    local state=$1 action=$2 protocol=$3 port=$4
    local proto canonical targets_json

    proto=$(fwctl_validate_protocol "$protocol") || return 1
    canonical=$(fwctl_normalize_port_spec "$port") || return 1

    if [[ "$proto" == both ]]; then
        targets_json='["tcp","udp"]'
    else
        targets_json="[\"$proto\"]"
    fi

    jq --argjson targets "$targets_json" --arg port "$canonical" --arg action "$action" "
        $(fwctl_jq_port_sort_def)
        reduce \$targets[] as \$proto (.;
            if \$action == \"add\"
            then .ports[\$proto] = ((.ports[\$proto] + [\$port]) | sorted_ports)
            else .ports[\$proto] = ((.ports[\$proto] - [\$port]) | sorted_ports)
            end
        )
    " "$state"
}

# 判断某个端口变更是否是空操作，供 CLI 输出「已存在 / 不存在」提示。
# 参数：$1=状态文件，$2=add|remove，$3=协议，$4=端口规范。
# 返回：0 表示会产生变更；1 表示空操作。
model_port_would_change() {
    local state=$1 action=$2 protocol=$3 port=$4
    local proto canonical targets_json

    proto=$(fwctl_validate_protocol "$protocol") || return 1
    canonical=$(fwctl_normalize_port_spec "$port") || return 1

    if [[ "$proto" == both ]]; then
        targets_json='["tcp","udp"]'
    else
        targets_json="[\"$proto\"]"
    fi

    if [[ "$action" == add ]]; then
        # 全部目标协议都已包含该端口 → 空操作
        jq -e --argjson targets "$targets_json" --arg port "$canonical" '
            . as $state
            | all($targets[]; . as $proto | $state.ports[$proto] | index($port) != null)
        ' "$state" >/dev/null && return 1
    else
        # 任一目标协议都不含该端口 → 空操作
        jq -e --argjson targets "$targets_json" --arg port "$canonical" '
            . as $state
            | any($targets[]; . as $proto | $state.ports[$proto] | index($port) != null)
        ' "$state" >/dev/null || return 1
    fi
    return 0
}
