#!/bin/bash
# 标准化 Systemd 多实例模版生成器 (动态绑定当前 instances 物理地址)

# 🔥 核心：确保引入正确的 common 基座
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/core/common.sh"

gen_service() {
    local port=$1
    cat > /etc/systemd/system/sb-${port}.service <<EOF
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
