# 更新日志

本文件按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的格式记录每个版本的变化，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.3.0] - 2026-10-25

在 0.2.0 的基础上加入更新格式 v2、不加载文档的更新操作、search marker 加速定位，以及 y-websocket 服务端示例。

### 新增

**更新格式 v2，以及不加载文档的更新操作**（issue #10）
- v2 的编码和解码：`decode_update_v2`、`Update::encode_v2`、`Doc::encode_state_as_update_v2`、`Doc::apply_update_v2`、
  `Doc::on_update_v2`（`@doc` 下有对应的函数形式）。v2 把字段分到 9 列，用 `Rle`、`UintOptRle`、`IntDiffOptRle` 和字符串
  编码器压缩，这些编码器在 `lib0` 里（`RleEncoder`、`UintOptRleEncoder`、`IntDiffOptRleEncoder`、`StringEncoder`
  和对应的解码器）。`update` 包新增 `UpdateEncoder` / `UpdateDecoder`，v1 与 v2 共用同一套 struct、content 和删除集的读写。
- `merge_updates`、`diff_update`、`encode_state_vector_from_update`，各有 v1 和 v2 版本，不需要加载文档。
- `Update::normalized`、`StructRef::normalized`：把更新读成 Yjs 读出的样子（见 README）。
- 测试（期望值由 `yjs@13.6.33` 生成）：12 个样例更新转 v2；60 + 40 + 20 组全程交换 v2 更新的场景；接收方每一步的整体状态和
  差量；36 个更新池的 `mergeUpdates`、`diffUpdate`、`encodeStateVectorFromUpdate`；lib0 游程编码器；`cmd/export` 的 v2
  状态、合并和差量交给 Node 端 Yjs 验证（现在共 132 项检查）。

**测试**（issue #8）
- 20 组各约 100 步的富文本长序列（根类型在格式化内容到达后才取得）和 15 组各 300 步的 `Y.Array` 长序列，期望值由
  `yjs@13.6.33` 生成；`tests/marker_test.mbt` 用朴素模型检查结果，并检查每个 marker 的位置。
- 基准：10 万字符文本、10 万个值的数组上的随机插入和删除。

**发布前的补齐**（issue #12）
- Y.Array 的随机并发场景从 100 组加到 200 组（种子 1–200，由 `yjs@13.6.33` 生成），满足申报书"每类至少 200 组"。
- Y.Array 和富文本的 quickcheck 属性测试（任意交换顺序收敛、重复应用幂等，每条 300 例），在 `tests/property_array_rich_test.mbt`。
- `scripts/bench_yjs.mjs`：在 `benchmarks` 同样的负载上跑 Yjs（同样的随机数、种子和规模，最终长度一致）；README
  "性能"一节有与 Yjs 的对比表。结论：短文档的编辑与 Yjs 同一量级；10 万字符 / 10 万个值上的随机插入删除慢约 2.3 到 2.9 倍，
  加载和导出整个文档约慢 2 倍。
- README 的"支持范围表"和"已知限制"更新到当前状态：未实现的 awareness 编解码、数组里的嵌套类型如实列出。

**协作编辑演示**（issue #6）
- `examples/ws_server`：用本库写的 y-websocket 服务端（`moonbitlang/async`，native）。按连接路径分房间，处理
  SyncStep1 / SyncStep2 / Update，把更新和 awareness 消息转发给同房间的其他连接；有改动的房间定期保存为
  `.ydoc` 文件（`Y.applyUpdate` 可读），首次使用时从文件恢复。独立模块（自己的 `moon.mod` 和 `moon.work`），
  不进发布包，不影响库的依赖和多后端 CI。
- `examples/web`：官方 `yjs` + `y-websocket` 客户端加 textarea 的最小网页（Vite）。
- `examples/web/test/e2e.mjs`：两个官方客户端经服务端的端到端测试，包括服务端重启后文档仍在；CI 新增只在
  ubuntu 上运行的 job。
- README 增加运行步骤。

### 修复

- 带 pending 数据时的 `encode_state_as_update`（v1 也一样）：Yjs 此时把存储的状态与 pending 数据合并，合并会重新读出每个
  struct，有 origin 的 map 条目写出来时不再带"有 key"那一位。之前我们保留了这一位，字节与 Yjs 不同（文档内容不受影响）。

### 变更

- 更新格式 v1 的读写只为 v2 分配 9 个游程编码流：重构为 `UpdateEncoder` / `UpdateDecoder` 时每个 v1 更新都建了这些流，
  3 个副本的同步基准曾从 9.6 ms 变成 13.2 ms，现在是 10 ms。

**search marker**（issue #8）
- `Y.Text` 和 `Y.Array` 的定位改用 Yjs 的 search marker（每个类型最多 80 个），不再每次从链表头走：数组的 `get`、
  `insert`、`delete`、`push`，文本的不带属性的 `insert` 和 `delete`。marker 的选取、移动、替换、编辑后平移、合并时调整、
  远端更新后清空，以及整合格式项后关闭，都按 `AbstractType.js` 移植。所有已有测试不改期望值，输出字节不变。
- 取代原先"模拟一个全新 marker"的做法：现在 marker 在多次操作之间累积，和 Yjs 一致。
- 10 万字符文本的随机插入删除基准（5000 + 5000 次）从 668 ms 降到 188 ms，数组从 744 ms 降到 192 ms；
  2000 次随机插入 9.21 → 4.82 ms，1000 次随机删除 18.8 → 7.96 ms。剩余的开销来自 struct 数组的中间插入和删除（见 README）。
- `doc` 包新增 `Marker`、`MAX_SEARCH_MARKER`、`YType::find_marker`、`YType::update_marker_changes`。

## [0.2.0] - 2026-10-22

在 0.1.0 的基础上加入 Y.Text 富文本（格式属性、Delta），可与 ProseMirror / Quill 一类编辑器绑定的数据格式对接。

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

### 变更

- README“已知限制”改写为具体的规律（见该节）：marker 何时被关闭、根类型晚取的例外、对象属性值的比较方式等。

## [0.1.0] - 已发布

首个版本：用 MoonBit 读写 Yjs 更新格式 v1，并与官方 Yjs 逐字节互通。

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
