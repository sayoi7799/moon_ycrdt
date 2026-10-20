# 更新日志

本文件按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的格式记录每个版本的变化，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

**Y.Text 富文本**（issue #2）
- `Text::insert_with_attributes`、`Text::insert_embed`、`Text::format`、`Text::to_delta`、`Text::apply_delta`；
  `DeltaOp`（`Insert` / `Retain` / `Delete`，属性为有序的 `(String, Any)` 列表）、`delta_to_json` / `delta_from_json`。
  `Text::insert` 不带属性时继承所在位置的格式。
- `lib0`：`Any` 与 JSON 互转（`ToJson for Any`、`Any::from_json`、`Any::to_json_string`、`any_from_json_string`）。
- 格式清理与 Yjs 一致：本地删除后的 `cleanupFormattingGap`（完整移植，含对当前属性的修正），以及远端更新之后
  另开一个事务做的清理（`cleanupYTextAfterTransaction`），后者产生只含删除的本地更新。
- 测试（期望值全部由 `yjs@13.6.33` 生成）：13 个文档的 `toDelta()` 对照；带属性插入、`format`、`applyDelta`、并发格式化
  和类型晚取的逐步脚本（共 231 步）；300 组富文本随机并发场景（8734 步，含 149 次清理更新）；`cmd/export` 的
  `rich_text` 场景交给 Node 端 Yjs 验证（现在共 60 项检查）；README 的富文本示例。

### 修复

- 带格式文本里不带属性的 `insert` 和 `delete` 现在按 Yjs 的规则定位：整合过格式项的类型不再使用 search marker，
  从头累积属性。之前总是模拟一个全新的 marker，会丢掉位置左边的格式，只在根类型晚于内容取得时才正确。
- 适配 MoonBit 0.1.20261016：`x.to_json()` 改为 `Json(x)`，`moon fmt` 迁移了语法（`Int` → `Int32` 等），
  行为不变。

### 变更

- README“已知限制”改写为具体的规律（见该节）：marker 何时被关闭、根类型晚取的例外、对象属性值的比较方式等。

## [0.1.0] - 待发布

首个版本：用 MoonBit 读写 Yjs 更新格式 v1，并与官方 Yjs 逐字节互通。
发布到 mooncakes.io 时在这里补上发布日期。

### 新增

**`lib0` 包：二进制编码**
- varUint、varInt（符号位在第一个字节的 `0x40`，不是 zigzag）、varString（UTF-8，孤立代理项替换为 U+FFFD）、字节数组、
  大端 float32 / float64 / bigint64。
- `Any` 值模型与 lib0 一致的编解码：按值选择 integer / float32 / float64 的类型标记，解码后再编码字节不变。
- `to_hex` / `from_hex` 辅助函数。

**`update` 包：更新格式 v1**
- Item / GC / Skip 三种 struct、info 字节（origin、rightOrigin、parentSub 标志位）、9 种 content
  （Deleted、JSON、Binary、String、Embed、Format、Type、Any、Doc）、删除集、状态向量。
- 解码再编码逐字节还原；暂不解析的 content 保存原始数据并原样写回。

**`doc` 包：文档模型**
- `Doc`（带 client id）、按 client 存储的 struct store（二分查找、Item 切分、事务结束时合并相邻 Item）。
- YATA 冲突解决（origin / rightOrigin / client id），Map 键的覆盖语义，嵌套类型，GC 结构，删除集应用。
- 依赖缺失的更新进入 pending 队列，依赖到齐后自动应用；`encode_state_as_update` 会带上 pending 数据（中间以 Skip 填补）。
- `apply_update`、`encode_state_as_update`（可按对方状态向量求差量）、`encode_state_vector`、
  事务级更新事件 `Doc::on_update`。

**`types` 包：共享类型**
- `Text`：按 UTF-16 码元下标插入、删除、读取；切开代理对时与 Yjs 一样替换为 U+FFFD；删除时清理多余的格式标记。
- `YMap`：set / get / has / delete / keys / entries，值为 `Any`，字节数组存为 Binary。
- `YArray`：insert / push / delete / get / to_array，定位、值的打包和 `push` 的语义与 Yjs 一致。
- Format、Embed、XML 类型、子文档等暂不支持的 content 原样保留。

**`protocol` 包：y-protocols 同步消息**
- `SyncStep1` / `SyncStep2` / `Update` 的编解码、`handle_sync_message`（收到 Step1 自动回复 Step2）。
- y-websocket 外层封装：sync 帧被处理，awareness 等其他帧作为原始字节透传。

**测试：期望值全部来自官方 Yjs**（`yjs@13.6.33`、`lib0@0.2.119`、`y-protocols@1.0.7`，由 `scripts/gen_fixtures.mjs` 生成）
- lib0 编码的字节对照，含边界值（0、127、128、负数、2^31 以上、空串、中文、emoji 等）。
- 12 个 Yjs 更新的解码与再编码，15 个 Yjs → MoonBit 互通场景（整体状态逐字节相同）。
- MoonBit → Yjs：`cmd/export` 导出 6 组编辑脚本，`scripts/verify_moonbit.mjs` 用 Yjs 做 51 项验证。
- 300 组固定种子的并发收敛场景（2–4 个副本，共 10914 步）和 100 组 Y.Array 场景：每一步的内容与每个本地更新的字节都与 Yjs 一致。
- 55 个边界场景（在每个 UTF-16 位置插入 / 删除、空文档、client id 0 与 2^32−1、损坏输入），5 类不支持内容的保留测试。
- quickcheck 属性测试：收敛、幂等、pending 补齐后自动应用。
- README 示例代码由 `tests/readme_test.mbt` 实际运行。

**示例与工具**
- `examples/concurrent`（两个副本并发编辑后收敛并导出 base64）、`examples/roundtrip`（Yjs → MoonBit → Yjs 往返）。
- `scripts/read_update.mjs`、`scripts/make_example_input.mjs`。
- `benchmarks` 包（`moon bench`），README 的"性能"一节。

**持续集成**
- GitHub Actions 在 ubuntu、macos、windows 上运行 `moon check --deny-warn`、`moon build`、`moon test`（均为 `--target all`）、
  `moon fmt --check` 和 `moon info` 差异检查；另有 Node + 固定版本 Yjs 的互通验证 job。

**发布准备**
- `moon.mod` 声明 `supported_targets = "+wasm+wasm-gc+js+native"`，与 CI 实际验证的后端一致。
- 新增 `.moonignore`：发布包不含 `docs/`、`fixtures/` 和 `node_modules/`（压缩包约 320 KB）。
  从发布包解压出的目录单独运行 `moon check --deny-warn` 和 `moon test --target all` 均通过。
- 适配 MoonBit 0.1.20261016：`x.to_json()` 改为 `Json(x)`（新版弃用，`--deny-warn` 下是错误），`moon fmt`
  迁移了语法（`Int` → `Int32` 等），否则 CI 的 `moon fmt --check` 会失败。行为不变。

### 已知限制

- 不支持文本格式属性的读写 API、update v2、Y.Xml* 的 API、子文档加载、UndoManager、awareness 状态、相对位置、快照和垃圾回收。
- 在带格式的文本里编辑时，多余格式标记的取舍个别情况下可能与某个具体的 Yjs 客户端不同（详见 README "已知限制"）。
- 不检测 client id 冲突；定位按链表线性查找。
