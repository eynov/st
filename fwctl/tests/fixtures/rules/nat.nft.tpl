table ip sb_nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        #DNAT_RULES#
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        #SNAT_RULES#
    }
}
