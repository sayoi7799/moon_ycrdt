# moon_ycrdt

用 MoonBit 实现的、与 [Yjs](https://github.com/yjs/yjs) **二进制格式互通**的 CRDT 库。

MoonBit 程序可以直接读写 Yjs 的更新格式（update format v1），和浏览器里基于 Yjs
的编辑器（Tiptap、ProseMirror、CodeMirror 等的 Yjs 绑定）、y-websocket 服务以及
Yrs 后端交换同一份文档。

> MoonBit 黑客松 MVP。模块名 `sayoi7799/moon_ycrdt`，许可证 Apache-2.0。

## 定位

本项目不比拼 CRDT 算法，而是做**格式兼容**：Yjs 生态已经有大量编辑器绑定、
同步服务和存储后端，MoonBit 程序只要能产出和消费同样的字节，就能直接接入。
因此实现上处处以官方 Yjs 的行为为准，测试的期望值全部由官方 Yjs 生成。

### 和 MoonBit 生态中已有 CRDT 库的区别

| | moon_ycrdt | [dowdiness/event-graph-walker](https://mooncakes.io/docs/dowdiness/event-graph-walker) | [mizchi/converge](https://mooncakes.io/docs/mizchi/converge) |
|---|---|---|---|
| 算法 | YATA（Yjs 的算法） | eg-walker + FugueMax | 受 EG-Walker 启发 |
| 同步格式 | **Yjs update v1 二进制**、Yjs 状态向量 | 自有的同步消息 | 自有的同步格式 |
| 能否直接和 Yjs / Yrs / y-websocket 交换数据 | 能 | 不能 | 不能 |
| 侧重点 | 互通：字节级兼容 | 算法与文档容器（树、撤销等） | 本地优先同步引擎（含 BFT 校验等） |

（右两列根据各自 mooncakes 页面的描述整理。）它们和本库并不冲突：需要 MoonBit
内部的高级协同功能时可以选它们，需要和现有 Yjs 系统对接时选 moon_ycrdt。

## 快速上手

```moonbit
let alice = @doc.Doc::new(1001) // 每个副本一个唯一的 32 位 client id
let bob = @doc.Doc::new(2002)
let text = @types.Text::new(alice, "doc")
text.insert(0, "Hello world")

// 增量更新：和 Yjs 的 doc.on('update') 一样，每个事务一条
alice.on_update((update, is_local) => if is_local { send_to_peers(update) })

// 应用对方（MoonBit 或 Yjs）发来的更新；依赖缺失的更新会自动排队
bob.apply_update(update_bytes)

// 差量同步：对方先发状态向量，这边只回它缺的部分
let diff = @doc.encode_state_as_update(alice, target_state_vector=bob.encode_state_vector())

let map = @types.YMap::new(alice, "settings")
map.set("theme", String("dark"))
```

可运行示例：两个副本在同一位置并发编辑、乱序交换更新后收敛，并把结果导出为 base64：

```bash
moon run examples/concurrent
```

第二个示例演示 Yjs → MoonBit → Yjs 的往返：加载 Yjs 写的文档，用状态向量做差量同步，
乱序投递的更新先进入 pending、依赖到齐后自动应用，最后导出给 Yjs：

```bash
node scripts/make_example_input.mjs > input.txt
```

```bash
moon run examples/roundtrip -- "$(cat input.txt)"
```

不带参数运行时使用内置的样例文档（同一脚本生成）。

### 用 Node + Yjs 读取示例的输出

示例最后一行是 `update (base64): ...`。在 `scripts/` 里安装固定版本的 Yjs 后读取：

```bash
cd scripts && npm ci && cd ..
node scripts/read_update.mjs "<示例输出的 base64>" doc
```

`read_update.mjs` 做的事情就是：

```js
import * as Y from 'yjs'
const doc = new Y.Doc()
Y.applyUpdate(doc, new Uint8Array(Buffer.from(base64, 'base64')))
console.log(doc.getText('doc').toString()) // "hello, Alice, Bob world"
```

## 包结构

| package | 内容 |
|---|---|
| `lib0` | 与 lib0 一致的二进制编码：varUint、varInt（符号位在第一个字节的 0x40，不是 zigzag）、varString、字节数组、float32/64、bigint、`Any` |
| `update` | update v1 的纯数据层：`ID`、9 种 content、Item / GC / Skip、info 字节、`DeleteSet`、状态向量；解码再编码逐字节还原 |
| `doc` | `Doc`、按 client 存储的 struct store、YATA integrate、pending 队列、`apply_update`、`encode_state_as_update`、`encode_state_vector`、事务级 `on_update` |
| `types` | `Text`（insert / delete / to_string，UTF-16 下标）和 `YMap`（set / get / delete，值为 `Any`） |
| `tests` | 与 Yjs 的互通测试、300 组并发收敛、quickcheck 属性测试 |
| `cmd/export` | MoonBit → Yjs：执行编辑脚本并导出 JSON 报告，供 Node 验证 |
| `examples/concurrent` | 可运行示例 |

## 支持范围

| 功能 | 状态 | 说明 |
|---|---|---|
| lib0 编码（varUint / varInt / varString / bytes / Any） | ✅ | 全部有官方 lib0 字节对照 |
| update v1 解码 / 编码 | ✅ | Item、GC、Skip；9 种 content 全部可解码并原样写回 |
| 删除集、状态向量 | ✅ | |
| YATA 冲突解决 | ✅ | 与 Yjs 逐字节一致（见测试） |
| 依赖缺失的更新（pending） | ✅ | 依赖到齐自动应用；`encode_state_as_update` 会带上 pending 数据（中间以 Skip 填补），中继不丢数据 |
| `encode_state_as_update(doc, 状态向量?)` / `apply_update` | ✅ | |
| 事务级增量更新事件 | ✅ | `Doc::on_update`，字节与 Yjs 的 `update` 事件一致 |
| Y.Text 插入 / 删除 / 读取 | ✅ | UTF-16 码元下标；切开代理对时与 Yjs 一样替换为 U+FFFD |
| Y.Map set / get / delete（`Any` 值、字节数组） | ✅ | |
| 不支持的 content（Format、Embed、XML 类型、子文档、Y.Array 内容） | ✅ 保留 | 原样存储并在编码时写回；MoonBit 编辑带格式的文本后，Yjs 读到的格式、embed、XML、子文档都还在 |
| 文本格式属性的读写 API（`format`、`toDelta`） | ❌ | 数据会保留，但没有 API |
| update v2 | ❌ | |
| Y.Array、Y.Xml* 的 API | ❌ | 数据会保留 |
| 子文档加载、UndoManager、awareness、相对位置、快照 | ❌ | |
| 垃圾回收 | ❌ | 本地文档相当于 `gc: false`，但能解码对方发来的 GC 结构和 ContentDeleted |
| y-websocket 服务端、编辑器绑定 | ❌ | |

已知限制：

- **带格式文本里的编辑**：Yjs 在定位时使用内部的 search marker 缓存，所以在带格式的文本里，
  它清理多余格式标记的结果取决于这个 JS 对象之前的操作历史。本库模拟的是新加载的 Yjs
  文档的行为。纯文本完全一致；带格式时文字内容和各副本之间的收敛不受影响，
  个别情况下多余格式标记的取舍可能和某个具体的 Yjs 客户端不同。
- 不检测 client id 冲突（Yjs 会在冲突时换 id）。
- 性能是 MVP 水平：定位按链表线性查找，事务结束时对改动过的 client 做全量合并。

## 测试

所有期望值都来自官方 Yjs（`yjs@13.6.33`、`lib0@0.2.119`），不是手写的。

| 类别 | 内容 | 位置 |
|---|---|---|
| 1. lib0 编码 | 每种编码的字节对照，含 0、127、128、负数、2^31 以上、2^53−1、空串、中文、emoji、BOM、−0、Infinity、bigint、孤立代理项 | `lib0/lib0_test.mbt` |
| 2. 解码层 | 12 个 Yjs 生成的更新（gc / 非 gc 文本、Unicode、各种 Map 值、格式与 embed、嵌套与 XML 类型、子文档、GC 结构、多 client、差量、从 Item 中间开始的差量、含 Skip 的合并更新、旧版 ContentJSON）：解码结果与 `Y.decodeUpdate` 一致，再编码**逐字节相同** | `update/update_test.mbt` |
| 3a. Yjs → MoonBit | 15 个场景（含乱序、重复投递）：文本、Map、状态向量与 Yjs 一致，MoonBit 重新编码的整体状态与 Yjs 的**逐字节相同**；幂等；差量同步 | `tests/interop_test.mbt` |
| 3b. MoonBit → Yjs | `cmd/export` 导出 5 组编辑脚本（Unicode 文本、全部 Any 类型、2 / 3 副本并发、编辑含格式 / embed / XML / 子文档的 Yjs 文档）；`scripts/verify_moonbit.mjs` 用 Yjs 验证：完整状态读回一致、打乱顺序应用增量更新后收敛、在 Yjs 上用相同 client id 重放同样的操作得到**逐字节相同**的状态、不支持的内容仍在（共 42 项检查） | `cmd/export`、`scripts/verify_moonbit.mjs` |
| 4. 并发收敛 | 300 组随机场景（种子固定为 1–300，见 `scripts/gen_fixtures.mjs` 的 `convergenceScenario`），2–4 个副本、同位置并发插入删除、对同一组键并发写入和删除 Map、随机抽取（有重复）乱序交换：**每一步**的文本和 Map 都与 Yjs 一致，每个本地更新的字节都与 Yjs 发出的一致 | `tests/convergence_test.mbt` |
| 5. 属性测试 | quickcheck，每条 300 例：任意交换顺序收敛；重复应用幂等；缺依赖的更新进入 pending，补齐后自动应用（且 pending 数据经编码中继不丢失） | `tests/property_test.mbt` |

运行：

```bash
moon test --target wasm-gc
moon test --target js
moon test --target native
```

MoonBit → Yjs 验证（CI 里同样执行）：

```bash
cd scripts && npm ci && cd ..
moon run cmd/export --target native > fixtures/moonbit_out.json
node scripts/verify_moonbit.mjs fixtures/moonbit_out.json
```

## 重新生成 fixtures

- 生成脚本：[`scripts/gen_fixtures.mjs`](scripts/gen_fixtures.mjs)
- Yjs 版本：`yjs@13.6.33`、`lib0@0.2.119`，固定在 [`scripts/package.json`](scripts/package.json) 和 `package-lock.json`
- 输出：`fixtures/*.json`（可读的记录）以及内嵌同样数据的 MoonBit 文件
  `lib0/lib0_gen_test.mbt`、`update/updates_gen_test.mbt`、`tests/interop_gen_test.mbt`、
  `tests/convergence_gen_test.mbt`、`cmd/export/yjs_base_gen.mbt`
  （wasm-gc 后端的测试读不了文件，所以数据生成为代码）

```bash
cd scripts && npm ci && node gen_fixtures.mjs && cd .. && moon fmt
```

生成是确定性的（随机场景使用固定种子），CI 会重新生成并检查与仓库中的文件一致。

## 参考与许可证

本项目用 MoonBit 重新实现 Yjs 的协议和行为，只参考协议与行为，不逐行翻译代码。

| 项目 | 许可证 | 参考范围 |
|---|---|---|
| [yjs](https://github.com/yjs/yjs) | MIT | update v1 格式、struct store、YATA integrate、Y.Text / Y.Map 的语义（含定位、格式清理、删除集、pending 处理）；生成测试数据 |
| [lib0](https://github.com/dmonad/lib0) | MIT | 二进制编码（varUint、varInt、字符串、`Any`）；生成测试数据 |
| [y-protocols](https://github.com/yjs/y-protocols) | MIT | 状态向量 / 差量更新的同步语义 |

`fixtures/` 和 `*_gen_test.mbt` 中的测试数据由上述 MIT 许可的官方实现生成。
moon_ycrdt 本身使用 Apache-2.0 许可证（见 [LICENSE](LICENSE)）。
