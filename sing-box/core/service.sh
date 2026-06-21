#!/bin/bash
# 标准化 Systemd 多实例模版生成器 (解耦环境空间)

source /etc/sing-box/core/common.sh

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
