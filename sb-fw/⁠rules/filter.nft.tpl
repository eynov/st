table ip sb_filter {
    set blacklist {
        type ipv4_addr
        flags interval
        elements = { #BLACKLIST# }
    }

    set allowed_ports_tcp {
        type inet_service
        flags interval
        elements = { #TCP_PORTS# }
    }

    set allowed_ports_udp {
        type inet_service
        flags interval
        elements = { #UDP_PORTS# }
    }

    chain input {
        # 🚨 核心加固：默认策略改为 drop，未命中的流量全部直接丢弃
        type filter hook input priority filter; policy drop;

        # 1. 放行本地回环 (127.0.0.1) 通信
        iifname "lo" accept

        # 2. 放行已建立和相关的连接 (确保服务器主动向外请求的回程流量不被掐断)
        ct state established,related accept

        # 3. 拦截黑名单
        ip saddr @blacklist drop

        # 4. 基础抗 D 策略 (仅对放行的端口生效)
        tcp flags syn tcp dinitrate rate over 50/second drop

        # 5. 🛡️ 智能放行系统当前的 SSH 端口 (由编译器动态注入，防止失联)
        tcp dport #SSH_PORT# accept

        # 6. 动态放行通过 fw 面板手动开放的本地业务端口
        tcp dport @allowed_ports_tcp accept
        udp dport @allowed_ports_udp accept
    }

    chain forward {
        # 💡 保持 accept：流量经 prerouting 链 DNAT 转换后走 forward 链，不受 input 默认 drop 的影响，转发依然百分百畅通
        type filter hook forward priority filter; policy accept;
    }
}
