<p align="center">
  <img src="icon/preview.png" width="128" alt="PopBar Logo">
</p>

<h1 align="center">PopBar</h1>

<p align="center">
  一个 macOS 划词工具条 —— 选中文字,即出菜单。<br>
  纯 Swift + AppKit 实现,无 Xcode 工程依赖,单文件编译打包。
</p>

<p align="center">
  中文 | <a href="README_EN.md">English</a>
</p>

<p align="center">
  <img src="docs/popbar-bar-light.png" width="520" alt="浅色模式"><br>
  <img src="docs/popbar-bar-dark.png" width="520" alt="深色模式">
</p>

<p align="center">
  <video src="docs/popbar-promo-v1.0.mp4" width="720" controls muted></video><br>
  <sub>52 秒宣传片:划词即弹 · 上下文感知 · AI 翻译面板 · 隐私脱敏</sub>
</p>

## 特性

- **划词即弹**:鼠标拖拽 / 双击选中文字后,浮动工具条出现在选区上方
- **内置动作 + 可编排工具条**:覆盖剪贴板、文本处理、搜索、翻译、语音等场景;偏好设置里可拖拽排序、显示/隐藏,多余的收进「…」溢出菜单
- **AI 翻译面板**:接入任意 OpenAI 兼容服务(DeepSeek / 硅基流动 / Ollama…),多个 provider 并行流式返回译文对比;支持**多轮追问**
- **上下文感知**:识别 URL / 邮箱 / 算式 / 时间戳 / JSON / Base64 / URL 编码 / 颜色 / 文件路径 / 电话 / 地址 / 日期 / 币种 / 单位,自动追加对应按钮(最多 3 个)
- **按应用规则**:1Password、终端等敏感应用可整体禁用弹条,或只保留指定按钮;菜单栏可一键对当前 App 禁用/启用
- **隐私优先**:AI 请求前检测手机号、身份证、银行卡、API Key、私钥、内网 IP,可选询问 / 自动脱敏;剪贴板历史默认关闭、默认不落盘
- **扩展系统**:URL 模板 / Shell 脚本(stdin 传文本,防注入)/ 快捷指令三类扩展,配置即生效
- **更多内置工具**:二维码生成、开发者工具箱(HTML/Unicode 转义、SHA256/MD5、JWT 解码、JSON 处理)
- **菜单栏翻译入口**:截图 OCR / 输入 / 剪贴板三种方式直接唤起翻译面板;截图与剪贴板图片还会识别二维码
- **剪贴板历史**:可选开启,菜单栏选择粘贴或追加;默认内存存储不落盘,密码类剪贴板标记一律跳过
- **键盘操作**:可配置全局快捷键唤起;键盘模式期间 ←/→ 移动高亮、Enter 执行、Esc 关闭,自动限时摘除拦截
- **中英双语界面**:菜单栏、浮动条、翻译面板、两个设置窗口均即时切换
- **智能排序建议**:本地使用统计(只记动作次数)驱动,每周最多一次建议把高频动作固定到主条
- **无侵入取词**:优先 Accessibility API,降级为模拟 `Cmd+C` 并自动还原剪贴板
- **就地替换**:大小写转换、Dev 菜单里的「→ 替换」项直接改写原文(剪贴板先备份后还原)
- **明暗双主题**:毛玻璃材质与图标颜色随系统外观自适应
- **零依赖后台运行**:`LSUIElement` 无 Dock 图标,纯事件驱动,空闲 CPU ≈ 0

## 按钮一览

| 图标 | 动作 | 说明 |
|---|---|---|
| 📄 | 复制 | 选中文字写入剪贴板 |
| ✂️ | 剪切 | 模拟 `Cmd+X` |
| Aa | 大小写转换 | 就地替换;全大写则转小写 |
| 🔍 | Google 搜索 | 浏览器打开搜索结果 |
| 🐾 | 百度搜索 | 同上 |
| 💬 | AI 翻译 | 打开多 provider 翻译面板,流式显示各家译文;未配置 provider 时打开设置窗口 |
| 🔊 | 朗读/停止 | AVSpeechSynthesizer,中文自动选中文语音 |
| #️⃣ | 字数统计 | 弹条内直接显示「字符 X · 词 Y」 |
| 🔗 | 打开链接 | 仅当选中内容像 URL 时出现 |
| ✉️ | 发邮件 | 仅当选中内容是邮箱时出现 |
| ⊖ | 计算 | 仅当选中内容是算式时出现,复制结果 |

> 工具条按钮悬停会显示名称提示;
> 上下文按钮最多显示 3 个,按识别优先级取前三个:URL、邮箱、算式、时间戳、JSON、
> 颜色、文件路径、Base64、URL 编码、币种、单位、电话、地址、日期。
> 扩展动作、二维码、脱敏、Dev 工具箱等都可在偏好设置里自由排序与显隐。

## 键盘模式

键盘选中(Shift+方向键/Home/End/PgUp/PgDn,防抖 0.45s 判定)同样能弹出工具条;
按下唤起快捷键(默认 `ctrl+opt+space`,可在偏好设置修改)则进入**键盘模式**:

- `←`/`→` 移动高亮,`Enter` 执行
- `Esc` 关闭;30 秒无操作自动退出(防 tap 卡死键盘)

## 隐私与安全

- **敏感信息检测**:AI 请求前检查手机号 / 身份证 / 银行卡 / 邮箱 / API Key / 私钥 / 内网 IP;可选「询问 / 自动脱敏 / 关闭」;脱敏用占位符发送,返回后原位还原;本地 provider(localhost / 内网地址)直接放行
- **API Key 不外泄**:key 明文存本机 config.json(权限 0600)
- **密码框豁免**:聚焦安全输入框(AXSecureTextField)时完全不取词,剪贴板兜底同样禁用
- **剪贴板保护**:自身写入统一登记,历史不误存降级取词的临时内容;ConcealedType / TransientType 一律跳过
- **扩展隔离**:Shell / Shortcut 扩展文本只走 stdin + 环境变量,不拼命令串;默认 10s 超时强杀
- **应用黑名单**:敏感应用可整体禁用取词;菜单栏可一键对当前 App 禁用/启用

## 工作原理

```mermaid
flowchart TD
    A[CGEventTap 全局监听<br/>鼠标/键盘事件] --> B{拖拽 > 4px<br/>或双击?}
    B -->|否| Z[忽略]
    B -->|是| C[延迟 120ms<br/>等待应用更新选区]
    C --> D[SelectionService.fetch]
    D --> E["① AX API:<br/>AXSelectedText + AXBoundsForRange"]
    D --> F["② 降级:<br/>备份剪贴板 → 模拟 Cmd+C<br/>→ 读文本 → 还原剪贴板"]
    E --> G[选区屏幕坐标定位]
    F --> H[鼠标位置定位]
    G & H --> I[NSPanel 非激活浮动条<br/>不抢焦点,选区保持]
    I --> J[点击动作执行]
    J --> K[自动隐藏]
```

关键实现:

- **事件监听** `.cgSessionEventTap` + `listenOnly`,不阻断系统事件流
- **取词降级链** AX → 剪贴板快照/还原(`(type, Data)` 物化,规避懒加载 item 的 `writeObjects:` 崩溃)
- **面板** `NSPanel` + `.nonactivatingPanel`,点击按钮时前台 App 焦点与选区不丢失——模拟按键替换选区等操作都依赖这一点
- **悬停反馈** `NSTrackingArea` + `.activeAlways`,accessory 应用下依然生效
- **Chrome/Electron 兼容** 自动设置 `AXEnhancedUserInterface`

## AI 翻译面板

<p align="center">
  <img src="docs/popbar-panel.png" width="480" alt="AI 翻译面板:多 provider 并行流式翻译">
</p>

点击弹条上的 💬 按钮,会打开一个翻译面板:顶部是原文(可选中、可朗读),
下面是每个 provider 一张卡片,译文**流式**逐字出现;每张卡片都有复制、朗读和重试,
失败的 provider 会单独显示错误,不影响其它家。面板出现在屏幕中上方,左上角 📌 可钉住
(钉住后点击面板外不关闭,Esc/✕ 仍可关)。

菜单栏还提供三种触发方式:

| 入口 | 说明 |
|---|---|
| 截图翻译(OCR) | 系统选区截图 → Vision 离线 OCR(中英)→ 进面板翻译;需要「屏幕录制」权限,首次会引导授权;识别后还会检测二维码,命中弹出可点击的结果条 |
| 输入翻译 | 面板原文区变为输入框,Enter 提交、Shift+Enter 换行,可反复修改重译 |
| 剪贴板翻译 | 剪贴板是文本直接翻;是图片则先 OCR 再翻 |

菜单里的其他条目:启用/停用划词弹条总开关、对当前 App 一键禁用/启用、
剪贴板历史(开启后显示)、AI 翻译设置、偏好设置、辅助功能设置、退出。
左键点菜单栏图标的行为可在偏好设置里改为「输入翻译 / 剪贴板翻译」,右键始终弹菜单。

### 设置窗口

<p align="center">
  <img src="docs/popbar-settings.png" width="700" alt="AI 翻译设置窗口">
</p>

菜单栏 →「AI 翻译设置…」打开设置窗口:左侧 provider 列表(绿点可用 / 橙点缺 key 或模型 / 灰点停用),
行内开关直接启停,**拖拽即可排序**(顺序即面板卡片顺序);右侧编辑名称、Base URL、模型、API Key、
深度思考与启用状态;「+」可选 DeepSeek、硅基流动、OpenAI、OpenRouter、Ollama 等预设,
「测试连接」会真实请求一次并显示耗时。下方是默认语言、超时、最大字符与温度。
点「保存」(⌘S)写回配置文件,有未保存修改时关闭窗口会提示。

### 偏好设置

<p align="center">
  <img src="docs/popbar-prefs.png" width="560" alt="偏好设置窗口">
</p>

菜单栏 →「偏好设置…」(⌘,)打开,改动**即时生效**,不需要点保存。窗口按**通用 / 功能 / 工具条 / 关于**分四个 tab,
窗口高度随 tab 内容自适应(超出屏幕可用高度时该 tab 内部滚动):

| tab | 内容 |
|---|---|
| 通用 | 外观、语言、托盘图标、面板位置、划词触发、剪贴板取词、敏感信息、开机启动 |
| 功能 | 剪贴板历史、历史持久化、OCR 结果、使用统计、唤起快捷键 |
| 工具条 | 动作与排序(拖拽调整)、应用规则 |
| 关于 | 版本号、配置目录 |

各项说明:

| 项 | 说明 |
|---|---|
| 外观 | 跟随系统 / 浅色 / 深色,立即切换所有窗口与面板 |
| 语言 | 跟随系统 / English / 中文,菜单栏、浮动条、翻译面板双语即时切换 |
| 托盘图标 | 左键点菜单栏图标的行为:菜单 / 输入翻译 / 剪贴板翻译(右键始终弹菜单) |
| 面板位置 | 翻译面板弹在屏幕中上方 / 跟随鼠标 |
| 划词触发 | 拖拽+双击 / 仅拖拽 / 仅双击 |
| 剪贴板取词 | AX 读不到选区时是否允许模拟 ⌘C 兜底(关掉更保护剪贴板隐私) |
| 敏感信息 | AI 请求前检查敏感内容:询问 / 自动脱敏 / 关闭 |
| 剪贴板历史 | 记录最近剪贴板,菜单栏可粘贴;默认关闭、默认不落盘 |
| OCR 结果 | 截图识别后弹翻译面板 / 完整工具条 |
| 使用统计 | 只记动作次数不记文本;用于每周一次的排序建议;可关 |
| 唤起快捷键 | 默认 `ctrl+opt+space`;格式 `ctrl+opt+space` 可改 |
| 开机启动 | SMAppService 登录项,与系统设置 → 登录项 同步 |

「关于」tab 显示版本号和配置目录,可一键在 Finder 打开。

### 配置文件

配置保存在 `~/Library/Application Support/PopBar/config.json`(首次启动自动生成,权限 0600)。

- **启动时加载,运行时自动刷新**:PopBar 监听该文件,外部编辑器保存后约 0.3 秒生效,无需重启
- JSON 写坏时保留上一次的有效配置,并在设置窗口提示错误
- 也可以直接手写,格式如下:

```json
{
  "appearance": "system",
  "language": "system",
  "trayClick": "menu",
  "panelPosition": "top",
  "triggerMode": "both",
  "clipboardFallback": true,
  "launchAtLogin": false,
  "sourceLanguage": "auto",
  "targetLanguage": "auto",
  "timeout": 30,
  "maxCharacters": 5000,
  "temperature": 0.2,
  "providers": [
    {
      "name": "DeepSeek",
      "baseURL": "https://api.deepseek.com/v1",
      "model": "deepseek-chat",
      "apiKey": "sk-你的key",
      "enabled": true
    },
    {
      "name": "本地 Ollama",
      "baseURL": "http://127.0.0.1:11434/v1",
      "model": "qwen2.5:7b",
      "apiKey": "ollama",
      "enabled": true
    },
    {
      "name": "词汇解释",
      "baseURL": "https://api.deepseek.com/v1",
      "model": "deepseek-chat",
      "apiKey": "sk-你的key",
      "enabled": true,
      "systemPrompt": "你是一名专业词汇解释助手。",
      "userPrompt": "请解释这个词:{$query.text}"
    }
  ]
}
```

- 任何 **OpenAI 兼容**服务都能用:填 `baseURL` + `model` + `apiKey` 即可,`enabled` 控制启用
- **深度思考**:每个 provider 可选「默认设置 / 启用思考 / 禁用思考」,按域名适配各家写法(DeepSeek `thinking.type`、OpenRouter `reasoning`、Qwen/硅基流动/vLLM 系 `enable_thinking`),未知服务走通用写法
- **自定义提示词**:provider 勾选「自定义提示词」后可改系统提示词和用户指令模板(把划词弹条变成解释、改写等任意任务)。模板变量:`$query.text` 原文、`$query.detectFromLang` 源语言、`$query.detectToLang` 目标语言(`{$…}` 带花括号的写法也认);面板仍按翻译样式流式展示结果。系统提示词留空则不发 system 消息
- `apiKey` 在设置窗口里填写,以明文保存在本机配置文件(权限 0600,仅本机当前用户可读)
- **扩展**:`extensions` 数组,`type` 取 `url / shell / shortcut`;文本通过 `{text}`/`{rawtext}` 模板变量(url 型)或 stdin(shell/shortcut)传入,shell 另有 `POPBAR_TEXT / POPBAR_APP / POPBAR_BUNDLE_ID` 环境变量;`output` 取 `none / copy / replace / show / panel`(show 与 panel 都弹结果窗口);`match` 正则命中才出现、`apps` 限定生效的 bundleID、`timeout` 超时强杀(默认 10s)、`enabled` 开关
- **应用规则**:`appRules`,每项 `{bundleID, name, mode, actions[]}`;`mode` 取 `disabled / custom`
- **工具条**:`toolbar.items` 按 `{id, visible}` 排序;`maxVisible` 控制主条按钮数(默认 12,可调 4–24),其余进溢出菜单;`contextPosition` 取 `afterEdit / front / back`;`order` 取 `manual / perApp`(perApp 按该应用的使用统计把常用动作提前)
- **首次启动预置**:没有配置时会写入模板,内含 2 个停用状态的 provider 模板(DeepSeek、硅基流动)、1 个 GitHub 搜索扩展,以及 5 条预置应用禁用规则(1Password / Bitwarden / 钥匙串访问 / 屏幕共享 / Windows App)
- **其余**:`clipboardHistory`、`ocr.after`、`usage.enabled`、`hotkeys`、`privacy` 等都可缺省手写
- `targetLanguage` 为 `auto` 时按原文自动判断方向(中文→英文,其它→中文)
- 面板里的语言下拉可以临时改方向,改动只对本次生效,不写回配置
- 支持本地服务(`http://127.0.0.1:...`,已在 Info.plist 声明 `NSAllowsLocalNetworking`)

> ⚠️ 使用该功能时,选中的文字会发送到**你自己配置的第三方 API**(或本地模型)。
> PopBar 本身没有服务端,不收集任何数据,但目标服务商的隐私政策适用于这次请求。
> `apiKey` 以明文保存在本机配置文件里(仅本机当前用户可读);如需更安全的存储,请改用本地模型(如 Ollama)。

## 构建与安装

```bash
./build.sh    # 一条命令:编译 → 打包 build.noindex/PopBar.app → 生成 build/PopBar-<版本>-<架构>.dmg
```

App 每次先删后增干净重建；同名 dmg 直接覆盖；打包暂存目录用完自动清理。打开 DMG，把 `PopBar.app` 拖到 `Applications` 文件夹，再从「应用程序」启动。应用只在菜单栏显示图标，不占用 Dock。也可直接运行本地构建：`open build.noindex/PopBar.app`。构建与打包暂存目录采用 `.noindex` 后缀，避免开发副本出现在系统应用搜索结果中。

要求:macOS 13+；源码构建需要 Swift 工具链（Xcode 或 Command Line Tools）。

> 从 GitHub Release 下载的 DMG 未经 Apple 公证,首次打开会提示"已损坏,无法打开"。
> 把 App 拖入 `Applications` 后在终端执行一次 `xattr -cr /Applications/PopBar.app` 即可正常启动。

## 权限

首次启动需授予 **系统设置 → 隐私与安全性 → 辅助功能**:

- 全局事件监听(划词检测)
- 读取选中文字
- 模拟按键(`Cmd+C/X/V`)

> AI 翻译面板需要网络访问(出站 HTTPS);其余动作全部离线。只有你主动使用搜索、在线翻译或 AI 翻译时,选中的文字才会被发送到对应服务。

> 安装 DMG 不会自动授予辅助功能权限。若系统列表中没有 PopBar，可在该页面点「+」并选择 `/Applications/PopBar.app`。本机若存在 `PopBar Dev` 证书则用它签名，否则回退 ad-hoc 签名；这两种方式都不是 Apple Developer ID 签名或公证，跨设备分发可能遇到 Gatekeeper 阻止，且无法保证辅助功能授权在更新后保持有效。

## 项目结构

```
popbar/
├── Sources/
│   ├── main.swift                    # 入口
│   ├── AppDelegate.swift             # 状态栏菜单 / 权限引导
│   ├── SelectionMonitor.swift        # CGEventTap 划词手势识别 + 键盘触发
│   ├── SelectionService.swift        # AX 取词 + 剪贴板降级/快照还原
│   ├── FloatingBarController.swift   # 浮动条 UI、键盘模式、信息条
│   ├── BarAction.swift               # 动作模型 + ActionRegistry 注册/排序/分流
│   ├── BuiltinActions.swift          # 内置动作集
│   ├── SourceContext.swift           # 一次取词的上下文(文本/选区/App)
│   ├── TextReplacer.swift            # 就地替换(剪贴板先备份后还原)
│   ├── PasteboardGuard.swift         # 剪贴板写入统一登记与快照还原
│   ├── ContextDetector.swift         # 上下文识别(URL/邮箱/算式/时间戳/JSON/颜色…)
│   ├── TranslationPanel.swift        # AI 翻译/动作面板(provider 卡片 + 追问)
│   ├── LLMClient.swift               # OpenAI 兼容流式客户端(messages 多轮)
│   ├── PopBarConfig.swift            # config.json 结构、路径与读写
│   ├── ConfigStore.swift             # 启动加载 + 文件监听热重载 + 变更通知
│   ├── SettingsWindow.swift          # AI 翻译设置窗口(provider 增删改、测试连接)
│   ├── PreferencesWindow.swift       # 偏好设置窗口(通用/功能/工具条/关于 四 tab,即时生效)
│   ├── PrefsSections.swift           # 工具条排序卡 / 应用规则卡
│   ├── TranslateTriggers.swift       # 截图 OCR / 输入 / 剪贴板翻译触发器
│   ├── SensitiveGuard.swift          # 敏感信息检测、占位符脱敏、拦截决策
│   ├── Extensions.swift              # URL/Shell/Shortcut 扩展执行器
│   ├── DevTools.swift                # 开发者工具箱(转义/哈希/JWT/JSON)
│   ├── ClipboardHistory.swift        # 剪贴板历史(默认关、默认内存)
│   ├── UsageStats.swift              # 使用统计与每周智能建议
│   ├── KeyboardTrigger.swift         # 快捷键解析 + 键盘模式拦截 tap
│   ├── QRCodePanel.swift             # 选中内容生成二维码(CoreImage 离线)
│   ├── L10n.swift                    # 中/英双语界面字符串
│   ├── Actions.swift                 # CGEvent 按键模拟(含 flagsChanged)
│   ├── AppActivation.swift           # accessory 应用激活前台 / Esc 可关窗口
│   ├── BarTooltip.swift              # 悬停提示(非激活面板下自绘 toolTip)
│   └── Screen.swift                  # CG/AX ↔ Cocoa 坐标系转换
├── tests/                            # 纯逻辑测试 + 弹窗可见性静态检查(tests/run.sh)
├── shot/main.swift                   # 截图工具(独立可执行,复用 Sources)
├── icon/make_icon.swift              # 图标生成器(矢量绘制 → iconset)
├── Resources/AppIcon.icns
├── Info.plist                        # LSUIElement / 版本 / 权限用途声明
├── docs/                             # README 截图
├── build.sh                          # App/DMG 打包
├── restart.sh                        # 杀旧进程 → 构建 → 启动开发副本
├── build/                            # 编译产物与 DMG（不入库）
└── build.noindex/                    # 开发 App 与打包暂存（不参与 Spotlight 索引）
```

## 工具脚本

```bash
# 重启 PopBar:杀旧进程 → 构建 → 启动开发副本(改完代码最常用)
./restart.sh              # 构建 + 重启
./restart.sh --no-build   # 只重启
./restart.sh --fg         # 前台运行,日志直接打在终端(Ctrl+C 退出)

# 运行测试:纯逻辑断言 + 弹窗可见性静态检查(显示前是否都激活到前台)
./tests/run.sh

# 重新生成图标(改 icon/make_icon.swift 中的配色/布局后执行)
swift icon/make_icon.swift icon/PopBar.iconset icon/preview.png
iconutil -c icns icon/PopBar.iconset -o Resources/AppIcon.icns

# 重新生成 README 里的弹条截图(浅色+深色)
swiftc -O -o build/shot $(ls Sources/*.swift | grep -v '/main.swift$') shot/main.swift
./build/shot docs/popbar-bar-light.png docs/popbar-bar-dark.png
```

## 已知限制

- AI 翻译只支持 OpenAI 兼容协议;Claude / Gemini 原生接口需要各自适配
- 完全无 AX 支持的应用里只能靠剪贴板降级取词,位置精度降为鼠标位置
- OCR 走 Vision 离线识别,长段落/小字体识别率有限
- 扩展系统为轻量三类(URL/Shell/Shortcut),暂不支持 YAML+JS 形式的插件
- 当前没有 Developer ID 签名和 Apple 公证；DMG 适合本机安装/内部测试，公开分发需按 Apple 要求签名、公证

## License

仅供学习交流使用。
