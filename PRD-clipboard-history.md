# 需求文档：剪贴板历史支持图片与文件

> 状态：草稿 v2（已 review） · 日期：2026-10-12 · 关联代码：`Sources/ClipboardHistory.swift`、`Sources/PasteboardGuard.swift`、`Sources/SnapOutput.swift`、`Sources/SnapHistory.swift`

## 0. Review 修订记录（v1 → v2）

对照当前代码核对后修正了以下与事实不符或内部矛盾的地方，正文已同步更新：

| # | v1 原文 | 问题 | v2 处理 |
|---|---|---|---|
| 1 | 「截屏写入剪贴板的 PNG 自然进入图片历史，无需特殊处理」 | `SnapOutput.copy` 经 `PasteboardGuard.write(items:)` 写入，会被 `declareOwn` 登记为自身写入，`poll()` 直接跳过。**截图永远进不了历史**，验收 4 必然失败 | 新增 FR-8：区分「临时写入」与「用户意图写入」，截屏复制显式入库 |
| 2 | 「开启 persist 重启后文字+图片历史仍在」「旧 JSON 可无损升级」 | `save()` 当前**没有任何调用方**，persist 实际从未生效，磁盘上大概率不存在旧文件 | FR-2 增加保存时机；兼容要求降为「若存在旧文件则能读」 |
| 3 | 「追加置灰」「复制不粘贴操作保留」 | 当前菜单点击只有粘贴；`append()` 存在但**未接 UI**，「复制不粘贴」不存在（README 描述也已过期） | FR-4/FR-5 改为「新增每条目子菜单：粘贴 / 仅复制 / 追加 / 置顶」 |
| 4 | 配置示例 `"limit": 50` | 代码默认 `limit = 100`，两处都不对 | 按新需求改为默认 10、硬上限 10 |
| 5 | 「关闭 enabled 后内存与磁盘数据按现有语义清理」 | 现有语义是**只清内存、不删磁盘文件**；关 persist 也不删文件。图片落盘后这是隐私问题 | 第 6 节明确定义关闭开关 / 关闭 persist 时的磁盘清理行为 |
| 6 | 「单张超过 20MB 按比例压缩为 JPEG 存储」 | 与「统一存 PNG」「写回 `.png` 类型」矛盾，JPEG 数据贴 `.png` 类型会出错 | 改为「超阈值按比例缩小像素，仍存 PNG」 |
| 7 | 「右键/修饰键菜单提供置顶」 | `NSMenu` 条目不响应右键；`SnapHistory` 已采用「条目 → 子菜单」模式 | 统一走子菜单，与截图历史一致 |
| 8 | FR-6「不开历史也可预览」 vs 验收 1「关闭开关行为不变」 | 互相矛盾；且最新历史条目本就是当前剪贴板，信息重复 | FR-6 降为 P2 可选，仅在 enabled 时显示 |
| 9 | 「hover 或展开项可预览（`NSMenuItem.view` 自定义行）」 | 自定义 view 会丢失系统高亮/键盘导航样式，且与截图历史风格不一致 | 改为 `NSMenuItem.image` 缩略图 + 子菜单，与 `SnapHistory.menuItem()` 一致 |
| 10 | 未提及 | 菜单只显示 `prefix(20)`；`pinned` 不在 save/load 内；`persist` 运行中切换不会触发 `load()`；后台解码期间 `changeCount` 可能再变 | 均补入对应章节 |
| 11 | 「类型优先级 / 容量淘汰」测试 | `tests/run.sh` 是纯逻辑测试（无 NSPasteboard），直接测 `poll()` 不可行 | 第 9 节要求把可测逻辑抽成无副作用的静态函数（参考 `SnapHistory.toDelete`） |
| 12 | 新增需求 | 最多保存 10 条；不影响其他应用 | FR-2 硬上限 10（含置顶，置顶 ≤ 5）；§5 新增「不影响其他应用」硬性约束 + 验收 8a；新增 §11 可行性评估 |

## 1. 背景

macOS 剪贴板（`NSPasteboard.general`）是覆盖式的：每次复制整体替换上一次内容，系统无历史。
PopBar 已有剪贴板历史功能，但当前实现只采集纯文本（`pb.string(forType: .string)`），
图片、文件、富文本等类型被直接丢弃。本次扩展为支持多类型采集与预览。

### 1.1 现状（代码事实，2026-10-12）

- `ClipboardHistory.Item { text, time, pinned }`，`pinned` 字段存在但无 UI、不持久化；
- 0.5s `Timer` 轮询 `changeCount`；跳过 `PasteboardGuard.isOwnChange` 与 `ConcealedType`/`TransientType`；
- 去重：仅与 `items.first` 比较；上限：`limit`（默认 100）；菜单只显示前 20 条；
- 菜单点击 = 粘贴（写回 → ⌘V）；`append()` 存在但菜单未提供入口；
- `save()` 无调用方 → `persist` 开关实际无效；`load()` 只在轮询启动时调用一次；
- `enabled=false` 时只 `items.removeAll()`，不动磁盘；
- 截屏复制 `SnapOutput.copy` 写 `.png`+`.tiff` 双类型，经 `PasteboardGuard` 登记为自身写入；
- PopBar 自己的「复制」动作、Dev 工具结果、二维码复制图片等同样被登记为自身写入，**均不进历史**。

## 2. 目标

- 剪贴板历史能完整保存：文字、图片、文件三类内容；
- 菜单栏能直观预览各类型条目（文字片段 / 图片缩略图 / 文件名+图标）；
- 历史条目可粘贴回目标应用（模拟 ⌘V）、仅写回剪贴板、或追加（文字）；
- PopBar 自身产生的「用户意图写入」（截屏复制等）也能进历史；
- 不引入新的隐私风险：默认关闭、敏感标记跳过、可控容量、关闭即清理。

## 3. 范围

### In scope

| 类型 | 采集 | 菜单显示 | 粘贴行为 |
|---|---|---|---|
| 文字 | `.string` | 单行截断 60 字（现有） | 写回 `.string` → ⌘V（现有） |
| 图片 | `.png` 优先，否则 `.tiff` → `NSBitmapImageRep` 重编码 PNG | 缩略图（32pt 高，同截图历史）+ 像素尺寸 `800×600` | 写回 `.png`+`.tiff` 双类型 → ⌘V（复用 `SnapOutput.copy` 的写法） |
| 文件/文件夹 | `.fileURL`（可多选，`readObjects(forClasses: [NSURL.self])`） | `NSWorkspace.icon(forFile:)` + 文件名；多文件显示「N 个项目」，icon 取第一个 | 文件 URL 写回 → ⌘V |

- 截屏（截屏/长截图）「复制」结果显式入库（见 FR-8）；
- 条目置顶（pin）：补全 UI 与持久化——置顶条目不参与淘汰、固定在菜单顶部；
- 每条目子菜单（粘贴 / 仅复制 / 追加 / 置顶），替代现在的「点击即粘贴」。

### Out of scope

- RTF/HTML 富文本：采集时按纯文本处理，不保留格式；
- 文件承诺（`NSFilePromiseReceiver`，如从 Photos/Mail 拖出的「将来才落盘」文件）：不采集；
- 跨设备同步（Universal Clipboard 由系统处理，不干预）；
- 剪贴板内容编辑、搜索窗口（菜单够用，不单独做面板）；
- 把 PopBar 自身「复制」按钮 / Dev 工具 / 二维码等其它自身写入纳入历史（本期只处理截屏，其余后续按 FR-8 机制逐个接入）。

## 4. 功能需求

- **FR-1 采集**：沿用 0.5s 轮询 `changeCount`。一次复制含多种类型时按优先级取**唯一**主类型：
  文件 > 图片 > 文字（先看 `pb.types`，只对命中的主类型拉数据，避免触碰其它可能为 promised 的类型）。
  若主类型被配置关闭（`images:false` / `files:false`），**该次复制整体跳过**，不降级为文字
  （Finder 复制文件时 `.string` 只是文件名，用户关掉文件采集时多半也不想要它）。
  现有跳过规则全部保留：自身写入（`PasteboardGuard`）、`ConcealedType`/`TransientType`。
- **FR-2 存储**：`Item` 改为 `payload` 枚举：
  ```swift
  enum Payload {
      case text(String)
      case image(ImageBlob, pixelSize: CGSize)   // ImageBlob: 内存 Data 或 磁盘 URL（见 §5 隐私）
      case files([URL])
  }
  struct Item { let id: UUID; let payload: Payload; let time: Date; var pinned: Bool }
  ```
  - **总数硬上限 10 条**（含置顶）：`limit` 默认 10，解码时 clamp 到 `1...10`；置顶最多 5 条，第 6 次置顶提示并拒绝；
    超限淘汰最旧的非置顶条目；置顶 ≤ 5 保证始终至少有 5 个普通槽位，新内容永远能入库；
  - 图片额外受总容量限制（`imageSizeMB`，默认 50，见 §7），超限先淘汰最旧的**非置顶**图片条目；
  - **补齐保存时机**：`persist` 开启时，入库 / 置顶 / 清空后节流写盘（≤1 次/秒），`applicationWillTerminate` 再写一次；
    运行中把 `persist` 从关切开 → 立即 `save()`；从开切关 → 删除磁盘文件与图片目录（见 §6）。
- **FR-3 菜单**：条目 `image` 显示缩略图 / 文件图标 / 文字 SF 符号；标题：文字=截断文本，图片=`HH:mm · 800×600`，
  文件=文件名或「N 个项目」。置顶条目排最前并加 📌 前缀，其后一条分隔线，再是普通条目。总数 ≤ 10，全部显示，去掉现有 `prefix(20)`。
  不使用 `NSMenuItem.view` 自定义行，保持与「截图历史」一致的系统样式。
- **FR-4 条目操作**：每条目挂子菜单（与 `SnapHistory.menuItem()` 同模式）：
  「粘贴」（写回 → ⌘V，现有逻辑）、「仅复制」（只写回剪贴板）、「追加」（文字专用，见 FR-5）、「置顶/取消置顶」。
  图片写回复用 `SnapOutput.copy` 的 `.png`+`.tiff` 双写；文件写回 `writeObjects([NSURL])`。
  粘贴/复制历史条目后不新增、不重排条目（现状保持）。
- **FR-5 追加（append）**：现有 `append()` 接入子菜单；仅文字条目显示「追加」项，图片/文件条目**不显示**该项（不是置灰）。
- **FR-6 「当前剪贴板」预览（本期不做，已决定延后）**：仅在 `enabled` 时，子菜单第一项（disabled 样式）显示此刻剪贴板主类型的缩略描述；
  被跳过的内容（Concealed 等）显示「(已隐藏)」。不读取大数据：图片只用 `pb.types` + 已缓存条目的缩略图，
  若与最新历史条目相同则不显示本项。
- **FR-7 置顶**：子菜单「置顶/取消置顶」；置顶条目持久化（`pinned` 写入 JSON）；
  「清空历史」默认**保留置顶**，子菜单另给「清空全部（含置顶）」。
- **FR-8 自身写入分类**：`PasteboardGuard` 新增 `write(items:record: Bool)`（默认 `false`，行为不变）。
  `record=true` 表示「用户意图写入」：仍登记 `ownChanges`（避免 ⌘C 兜底等逻辑误判），但同时直接调用
  `ClipboardHistory.shared.record(payload)` 入库。本期只有 `SnapOutput.copy` 传 `record: true`；
  长截图复制同样走该入口。⌘C 兜底取词的 snapshot/restore、TextReplacer 还原等临时写入保持 `record=false`。

## 5. 非功能需求

- **隐私**：功能默认关闭（现状保持）。
  - `persist=false`：图片 Data 全部驻留内存，不落盘；
  - `persist=true`：图片以 PNG 文件存 `Application Support/PopBar/ClipboardHistory/<uuid>.png`
    （与 `Snaps/` 同级，目录权限 0700），`ImageBlob` 只持有 URL，粘贴时按需读取；
    索引文件 `clipboard-history.json` 写入后收紧为 0600（与 `config.json` 一致）；
  - 偏好设置「重启后保留剪贴板历史」开关下的说明文字须补充「开启后图片将以文件形式保存到本机」（中英双语）。
- **不影响其他应用**（硬性约束）：
  - 采集路径对剪贴板**只读**：只调用 `changeCount` / `types` / `data(forType:)` / `readObjects`，绝不 `clearContents` / 写入，
    `changeCount` 不因 PopBar 轮询而变化，其他应用的复制/粘贴感知不到 PopBar 存在；
  - 只有用户在菜单里主动点「粘贴 / 仅复制 / 追加」才写剪贴板，且走 `PasteboardGuard` 登记（现状）；
  - 不触发 Universal Clipboard 远端拉取：`pb.types` 含 `com.apple.is-remote-clipboard` 标记时整次跳过
    （否则 PopBar 读数据会让系统弹「正在从 iPhone 粘贴」HUD，并抢在用户之前消耗网络拉取）；
  - 不触碰 promised / 懒加载类型：只对命中的主类型拉数据，`.fileURL` 用 `readObjects` 而不是取私有类型；
  - 轮询回调（主线程）≤ 1ms：仅比较整数与类型数组，重活全部后台；菜单未弹出时不构建任何 UI；
  - 不监听、不拦截任何键盘/鼠标事件（与划词弹条的 `CGEventTap` 无关）；模拟 ⌘V 仅在用户点「粘贴」后发生一次；
  - 空闲 CPU 保持 ≈ 0：`Timer.tolerance = 0.2` 维持现状，`changeCount` 未变时立即返回。
- **性能**：
  - 轮询回调只做 `changeCount` / `types` 判断；主类型数据拉取、PNG 重编码、缩略图生成放
    `DispatchQueue.global(qos: .utility)`，完成后回主线程入库；
  - 入库前重新比对 `changeCount`，若期间剪贴板又变了则丢弃本次结果（避免乱序）；
  - 入库即生成 ≤ 64px 缩略图（`CGImageSourceCreateThumbnailAtIndex`，同 `SnapHistory.thumbnail`）并随条目缓存；
  - 单张 PNG 超过 `imageMaxMB`（默认 10）时按比例缩小像素（长边 ≤ 4096）后重编码 PNG，标题加「(已缩小)」；仍超则跳过不入库；
  - 菜单构建（主线程、同步）只用缓存缩略图，不读磁盘大图、不触碰剪贴板数据。
- **兼容**：macOS 14+（与 `build.sh` 一致）。
  旧 `clipboard-history.json`（`[{text,time}]` 数组）若存在，新 loader 把缺 `type` 字段的元素按文字条目读回；
  新格式每个元素带 `type: "text" | "image" | "files"`，图片元素存 `file`（相对文件名）+ `w`/`h`，文件元素存 `urls`（`file://` 字符串数组）。

## 6. 边界与异常

- 复制的是「图片文件」时，剪贴板同时含 `fileURL` 和图片数据 → 按文件处理（优先级规则）；
- 微信/QQ 截图工具写剪贴板常带私有类型 → 仍走 png/tiff 兜底；只声明私有类型、无 png/tiff 则跳过；
- 粘贴图片到只收文字的目标应用 → 由目标应用自行降级，PopBar 不做二次处理；
- 文件粘贴后被删除/移动 → 历史条目保留 URL，菜单仍显示文件名（图标退化为通用图标），粘贴时写回失效 URL，不做清理；
- 大图片频繁复制（如连续截图）→ 容量上限 + 去重：图片比较 `pixelSize` + PNG 字节数 + 数据哈希（避免逐字节比较大 Data）；
  文件比较 URL 数组；均只与最新一条比较（沿用现有去重粒度）；
- **关闭 `enabled`**：停轮询、清内存（现状），**并删除** `clipboard-history.json` 与 `ClipboardHistory/` 目录；
- **关闭 `persist`（enabled 仍开）**：内存条目保留，图片 URL 重新读回内存 Data（超容量则淘汰），然后删除磁盘文件与目录；
- `limit` 下调导致超限 → 下次入库时淘汰，不即时裁剪；配置里写了 > 10 的值一律按 10 处理；
- 置顶条目计入 10 条总数、最多 5 条；图片置顶条目仍计入 `imageSizeMB`（置顶图片不会被容量淘汰，普通图片被淘汰完仍超限则拒绝新图入库并 `NSSound.beep()`）；
- 剪贴板内容来自 Universal Clipboard（含 `com.apple.is-remote-clipboard`）→ 整次跳过，不读数据；
- 其他应用正在高频写剪贴板（如某些 IDE 每次选中都写）→ 0.5s 轮询天然采样，只记录轮询瞬间的内容，不追求每一次变化。

## 7. 配置项（`clipboardHistory` 扩展）

```jsonc
"clipboardHistory": {
  "enabled": false,
  "persist": false,
  "limit": 10,             // 默认 10，硬上限 10（含置顶），解码时 clamp 到 1...10；原默认 100 作废
  "images": true,          // 新增：是否采集图片
  "files": true,           // 新增：是否采集文件
  "imageSizeMB": 50,       // 新增：图片历史总容量上限（MB）；persist=false 时即内存占用上限
  "imageMaxMB": 10         // 新增：单张 PNG 阈值，超过则按比例缩小
}
```

旧配置缺字段时全部回退默认值（`ClipboardHistoryConfig` 已是 `Codable` 带默认值的 struct，沿用现有解码风格）；
旧配置里已有 `limit: 100` 的用户升级后自动按 10 生效。
偏好设置「功能」tab 增加「采集图片」「采集文件」两个 toggle；容量两项暂只允许改 JSON，不做 UI。

## 8. 验收标准

1. 关闭开关时菜单无「剪贴板历史」项、无轮询（现状）；开启后复制文字 / 图片 / 文件都能在菜单看到对应条目；
2. 图片条目显示缩略图与像素尺寸，「粘贴」到备忘录 / 微信聊天框成功；
3. 文件条目显示图标与文件名，「粘贴」到 Finder / 文稿成功；多选文件显示「N 个项目」；
4. 截屏（`ctrl+opt+p`）→「复制」后，菜单历史顶部出现该截图缩略图；长截图同样；
5. 密码管理器复制的内容不进入历史；从历史「粘贴」/「仅复制」不产生新条目；⌘C 兜底取词不产生条目；
6. 开启 `persist` 复制文字 + 图片后重启，历史仍在，图片可粘贴；关闭 `enabled` 后 `ClipboardHistory/` 目录与 JSON 被删除；
7. 置顶条目固定在顶部、不被淘汰、「清空历史」后仍在、重启后仍在；第 6 次置顶被拒绝并提示；
8. 连续复制 30 张 2000×2000 截图，历史始终 ≤ 10 条，内存占用不超过 `imageSizeMB` + 合理开销，菜单弹出无可感知卡顿；
8a. **不影响其他应用**：开启历史后，在任意 App 连续 ⌘C/⌘V 20 次，`changeCount` 增量 = 20（PopBar 未写入）；
    iPhone 复制一段文字后 Mac 上不出现「正在从 iPhone 粘贴」HUD，直到用户自己 ⌘V；
    Activity Monitor 中 PopBar 空闲 CPU ≈ 0%，复制 10MB 图片时主线程无 >16ms 卡顿（Instruments Hangs 无告警）；
9. 新增字符串全部走 `L10n.t`，中英切换即时生效；README / README_EN「剪贴板历史」一节同步更新（现 README 的「粘贴或追加」描述与实现不符，一并修正）；
10. `tests/run.sh` 全绿，新增纯逻辑测试：类型优先级（给定 types 集合与配置 → 主类型 / 跳过）、图片去重、容量淘汰（含置顶豁免、10 条硬上限、置顶 ≤ 5）、`limit` clamp、远端剪贴板标记跳过、旧 JSON 兼容解码、新 JSON 往返。

## 9. 技术要点

- **可测性**：把以下逻辑抽成无副作用的 `static func`（参考 `SnapHistory.toDelete`），不依赖 `NSPasteboard`：
  `pickType(types: [NSPasteboard.PasteboardType], cfg:) -> Kind?`、`evict(items:limit:imageBudget:) -> [Item]`、
  `isDuplicate(_:_:)`、`decode(json:) -> [Item]` / `encode`；
- 读取：先 `pb.types`，命中 `.fileURL` → `readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])`；
  命中 `.png` → `pb.data(forType: .png)`；否则 `.tiff` → `NSBitmapImageRep(data:)` → `representation(using: .png)`；
- 写回：图片走 `PasteboardGuard.write(items:)` 双类型（与 `SnapOutput.copy` 相同），文件 `NSPasteboardItem` 逐个 `setString(url.absoluteString, forType: .fileURL)` 或直接 `writeObjects([NSURL])`；
- 菜单行：沿用 `NSMenuItem` + `image` + `submenu`，复用 `MenuDispatch.register` 分发闭包；
- 采集重活：后台队列解码 / 缩略图，入库前二次校验 `changeCount`；
- `PasteboardGuard.write(items:record:)`：`record=true` 时 `declareOwn` 之后同步调用 `ClipboardHistory.shared.record(...)`，
  由历史模块自己判断 `enabled` / `images` 开关，调用方无需关心。

## 10. 风险

- 大图片进历史导致内存上涨 → 总容量上限 + 缩略图缓存 + persist 模式下只持 URL；
- 某些应用写剪贴板只声明类型不给数据（promised data / Universal Clipboard 远端内容）→ 拉取时可能阻塞或触发网络；
  远端剪贴板按标记整次跳过；其余只在后台串行队列、只对命中的主类型拉数据。`data(forType:)` 是同步调用、无法取消，
  所谓「超时」只能是主线程侧放弃等待结果（后台线程仍会阻塞到返回），因此用**串行队列**保证同一时刻最多一个阻塞中的读取；
- 持久化图片带来隐私面扩大 → 默认关闭 + 偏好设置文案明确提示 + 关闭即删文件；
- `PasteboardGuard` 改签名影响面：现有 `write(items:)` 调用点（二维码、截屏）行为不变，仅截屏新增 `record: true`；
- 菜单构建是同步的，条目数 × 缩略图若未命中缓存会卡顿 → 缩略图必须在入库时生成，菜单阶段只读缓存（10 条上限后此风险很小）。

## 11. 可行性评估

**结论：可行，无需新权限、新依赖或系统私有 API；整体属于对现有 143 行模块的扩展，而非重写。**

| 项 | 可行性 | 依据 / 说明 | 复杂度 |
|---|---|---|---|
| 图片采集（png/tiff → PNG） | 高 | `SnapOutput.copy` 已有相反方向（CGImage → png+tiff）的实现；`NSBitmapImageRep(data:)` 公开 API | 低 |
| 文件采集（`.fileURL`） | 高 | `readObjects(forClasses: [NSURL.self])` 公开 API，Finder 多选天然支持 | 低 |
| 类型优先级 / 禁用跳过 | 高 | 纯函数，`pb.types` 即可判定；可单测 | 低 |
| 缩略图 + 子菜单 | 高 | 直接复用 `SnapHistory.thumbnail` 与其 `item.image + submenu` 模式 | 低 |
| 图片 / 文件写回 → ⌘V | 高 | 图片复用 `SnapOutput.copy`；文件 `writeObjects([NSURL])`；⌘V 复用 `Actions.postKeyCombo(key: 9)` | 低 |
| 截屏复制入库（FR-8） | 高 | 仅给 `PasteboardGuard.write(items:)` 加一个默认参数，现有 3 个调用点不动 | 低 |
| 持久化（修复 save 无调用 + 图片落盘） | 高 | `PopBarConfig.directoryURL` / `SnapHistory.dir` 已有目录与权限处理先例；需补节流写盘与退出钩子 | 中 |
| 置顶 UI + 持久化 | 高 | 字段已在；主要是排序与淘汰规则，纯逻辑可测 | 低 |
| 后台解码 + changeCount 二次校验 | 高 | 标准 GCD 模式；注意入库必须回主线程（`items` 非线程安全，菜单在主线程读） | 中 |
| 不影响其他应用 | 高 | 采集路径本就是只读；新增的只是远端剪贴板标记判断。唯一不可控点是 `data(forType:)` 对 promised 类型可能阻塞后台线程，用串行队列限制影响面 | 低 |
| 旧 JSON 兼容 | 高 | 旧格式极简（`[{text,time}]`），缺 `type` 即文字 | 低 |
| 纯逻辑测试 | 高 | `tests/run.sh` 已编译全部 Sources；只要逻辑抽成静态函数即可覆盖 | 低 |

**需要注意的技术限制（不阻塞，但要接受）**

1. `NSPasteboard.data(forType:)` 没有异步 / 可取消版本。对极少数「只声明不给数据」的应用，后台线程可能挂住一次，
   串行队列保证不会堆积多个阻塞读取，主线程与其他应用完全不受影响。
2. 文件条目只能存 URL，无法感知文件后续被删除 / 移动（不做 FSEvents 监听，与系统行为一致）。
3. 10 条上限 + 单张 ≤ 10MB 的默认值下，最坏内存占用约 50MB（`imageSizeMB` 封顶），对一个常驻 accessory 应用是可接受范围；
   若希望更省，可把 `images` 默认改为 `false`，不影响其余功能。
4. FR-6「当前剪贴板」预览价值有限（信息与最新条目重复），建议本期不做，列为 P2。

**改动面预估**：`ClipboardHistory.swift`（主体重写，预计 300–400 行）、`PasteboardGuard.swift`（+1 参数）、`SnapOutput.swift`（+1 实参）、
`PopBarConfig.swift`（+4 字段 + clamp）、`PreferencesWindow.swift`（+2 toggle + 文案）、`AppDelegate.swift`（退出时 save）、
`tests/main.swift`（+1 section）、README / README_EN（文案修正）。不涉及 Info.plist、entitlements、新框架链接。
