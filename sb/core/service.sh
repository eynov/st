#!/bin/bash
# ==============================================================================
# 服务控制：唯一 sing-box 进程，读取 output/config.json
# 职责：start / stop / restart / reload / status / logs
# 不感知协议，不读取 instances.json
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/core/common.sh"

SERVICE_FILE="/etc/systemd/system/${SB_SERVICE}.service"

# ------------------------------------------------------------------------------
# 生成 systemd service 文件
# ------------------------------------------------------------------------------
gen_service() {
    cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=sing-box unified proxy service
After=network.target nss-lookup.target

[Service]
WorkingDirectory=${OUTPUT_DIR}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${SB_BIN} run -c ${OUTPUT_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    ok "服务单元 ${SB_SERVICE}.service 已写入"
}

service_start() {
    _require_config || return 1
    _ensure_service
    systemctl start "$SB_SERVICE"
    ok "sing-box 已启动"
}

service_stop() {
    systemctl stop "$SB_SERVICE" 2>/dev/null
    ok "sing-box 已停止"
}

service_restart() {
    _require_config || return 1
    _ensure_service
    systemctl restart "$SB_SERVICE"
    ok "sing-box 已重启"
}

service_reload() {
    _require_config || return 1
    if systemctl is-active --quiet "$SB_SERVICE"; then
        systemctl reload "$SB_SERVICE" 2>/dev/null \
            || systemctl restart "$SB_SERVICE"
        ok "sing-box 已热重载"
    else
        service_start
    fi
}

service_status() {
    systemctl status "$SB_SERVICE" --no-pager
}

service_logs() {
    journalctl -u "$SB_SERVICE" -f --no-pager
}

_require_config() {
    [ -f "$OUTPUT_CONFIG" ] || { err "output/config.json 不存在，请先执行 'sb compile'"; return 1; }
}

_ensure_service() {
    if [ ! -f "$SERVICE_FILE" ]; then
        gen_service
        systemctl enable "$SB_SERVICE" --quiet
    fi
}
