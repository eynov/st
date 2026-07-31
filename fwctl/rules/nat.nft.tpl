# 开发者参考——**这个文件不是运行时输入**。
#
# 渲染现在由 core/render.sh 完成，它直接从 state.json 生成完整的 nft 配置，
# 不再做模板替换。这份模板保留下来是为了让人快速看懂生成结果的形状；修改它
# 不会影响任何行为。
#
# 与实际渲染结果的主要差异：表名是 fwctl（不是 sb_filter/sb_nat）、filter 与
# nat 的 chain 在同一张表内、每条规则带 counter 与 comment、空 set 不再使用
# 占位元素。

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
