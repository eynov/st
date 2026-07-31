# 测试固件

## 永久固件

以下文件是长期资产，**不随任何一次实现结束而删除**。

### `render-v3.sh` 与 `rules/`

重写前的旧渲染器及其模板的**逐字节快照**。它是迁移等价性测试的基准：

```text
v1 状态 --render-v3.sh--> ruleset A
v1 状态 --迁移--> 新状态 --core/render.sh--> ruleset B
归一化(A) == 归一化(B)
```

快照刻意保持与被替换版本完全一致，一个字符都没有改动（包括没有添加说明注释），
这样它作为「旧行为」的证据是可验证的：

```bash
git log --all --oneline -- fwctl/render.sh
git show <重写前的提交>:fwctl/render.sh | sha256sum
sha256sum fwctl/tests/fixtures/render-v3.sh
```

两个哈希必须相同。修改这个文件等于修改基准，会让等价性测试失去意义。

`rules/filter.nft.tpl` 与 `rules/nat.nft.tpl` 同理，是 `render-v3.sh` 运行所需的
模板快照。它们与项目根部 `fwctl/rules/` 下的同名文件当前内容相同，但**不是同一份
文件**——后者已降级为开发者参考，允许被修改；这里的副本不允许。

### `state-v1-*.json`

旧格式状态样本，覆盖 MIGRATION.md 的用例矩阵。同样永久保留。

## 说明

任何渲染改动都必须继续通过上述等价性链路，否则「升级不改变防火墙行为」这一承诺
就失去了回归保护。详见
[ADR 0004](../../docs/adr/0004-automatic-schema-migration.md)。

## 可变固件

- `fake-nft`：无内核环境下的 nft 替身，支持 `-c -f`、`-f`、`-j list table`，
  可注入失败。随测试需要演进。
- `netns-nft`：`ip netns exec` 包装，`FWCTL_TEST_NETNS=1` 时让 apply、回滚和崩溃
  恢复跑在真实内核上。
- `golden/*.nft`：渲染黄金文件。渲染行为有意变更时同步更新。
