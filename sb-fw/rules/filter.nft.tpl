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
        type filter hook input priority filter; policy drop;

        iifname "lo" accept
        ct state established,related accept

        ip saddr @blacklist drop

        tcp flags syn limit rate over 50/second burst 5 packets drop
        tcp dport #SSH_PORT# accept

        tcp dport @allowed_ports_tcp accept
        udp dport @allowed_ports_udp accept
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
    }
}
