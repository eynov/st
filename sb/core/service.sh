#!/bin/bash
# ==============================================================================
# Systemd 多实例服务单元模版生成器
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/core/common.sh"

gen_service() {
    local port="$1"
    cat > "/etc/systemd/system/sb-${port}.service" <<EOF
[Unit]
Description=sing-box multi-instance routing service (Port: ${port})
After=network.target nss-lookup.target

[Service]
WorkingDirectory=${INST_DIR}/${port}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${SB_BIN} run -c ${INST_DIR}/${port}/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}
