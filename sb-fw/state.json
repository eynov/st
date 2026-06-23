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
        type filter hook input priority filter; policy accept;

        iifname "lo" accept
        ct state established,related accept

        # 黑名单无条件拦截
        ip saddr @blacklist drop

        # DDOS 基础防护 (SYN 限流)
        tcp flags syn tcp dinitrate rate over 50/second drop

        # SSH 防爆破 (1分钟内连接超过5次，拉黑10分钟)
        tcp dport 22 ct state new meter ssh_meter { ip saddr timeout 10m limit rate over 5/minute } drop

        # 动态放行开放的本地端口
        tcp dport @allowed_ports_tcp accept
        udp dport @allowed_ports_udp accept
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
    }
}
