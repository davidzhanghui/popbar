import Foundation

/// 单个 OpenAI 兼容 provider 的配置
struct LLMProvider: Codable, Equatable {
    /// 稳定 id,钥匙串 account 与 AI 动作引用都用它;旧配置缺省时解码后自动补
    var id: String = UUID().uuidString
    var name: String
    var baseURL: String
    var model: String
    /// 明文 API Key(存本机 config.json,权限 0600)
    var apiKey: String
    var enabled: Bool
    /// 深度思考:"default"(不传参)/ "on"(启用) / "off"(禁用);nil 等同 default
    var thinking: String? = nil
    /// 自定义系统提示词;nil 表示用默认翻译提示词。支持 {$query.text} 等变量
    var systemPrompt: String? = nil
    /// 自定义用户消息模板;nil 表示直接发送原文
    var userPrompt: String? = nil

    static func blank(index: Int) -> LLMProvider {
        LLMProvider(name: "Provider \(index)", baseURL: "https://", model: "", apiKey: "", enabled: true)
    }

    init(id: String = UUID().uuidString, name: String, baseURL: String, model: String,
         apiKey: String, enabled: Bool) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        baseURL = (try? c.decode(String.self, forKey: .baseURL)) ?? ""
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        apiKey = (try? c.decode(String.self, forKey: .apiKey)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        thinking = try? c.decode(String.self, forKey: .thinking)
        systemPrompt = try? c.decode(String.self, forKey: .systemPrompt)
        userPrompt = try? c.decode(String.self, forKey: .userPrompt)
    }
}

/// #3 工具条单项
struct ToolbarItem: Codable, Equatable {
    var id: String
    var visible: Bool = true
}

/// #3 工具条布局
struct ToolbarConfig: Codable, Equatable {
    var items: [ToolbarItem] = []
    var maxVisible: Int = 12
    /// 上下文按钮位置:front | back | afterEdit(默认,与 0.1 版一致)
    var contextPosition: String = "afterEdit"
    /// 排序方式:manual | perApp(每应用最常用提前)
    var order: String = "manual"
}

/// #2 按应用规则
struct AppRule: Codable, Equatable {
    var bundleID: String
    var name: String = ""
    /// disabled 完全不触发 | custom 只显示 actions 里的动作
    var mode: String = "disabled"
    var actions: [String] = []
}

/// #6 扩展
struct ExtensionConfig: Codable, Equatable {
    var id: String
    var name: String
    var symbol: String = "puzzlepiece.extension"
    /// url | shell | shortcut
    var type: String = "url"
    /// url 类型:{text} 百分号编码 / {rawtext} 原样
    var template: String = ""
    /// shell 类型:选中文本从 stdin 传入,另有 POPBAR_TEXT/POPBAR_APP/POPBAR_BUNDLE_ID 环境变量
    var command: String = ""
    /// shortcut 类型:快捷指令名称
    var shortcut: String = ""
    /// none | copy | replace | show | panel
    var output: String = "none"
    /// 只匹配才出现的正则(可选)
    var match: String = ""
    /// 只在这些 bundleID 里出现(可选)
    var apps: [String] = []
    var timeout: Double = 10
    var enabled: Bool = true
}

/// #8 剪贴板历史(默认关闭);limit 硬上限 10(含置顶,置顶 ≤5)
struct ClipboardHistoryConfig: Codable, Equatable {
    var enabled: Bool = false
    var limit: Int = 10
    var persist: Bool = false
    /// 是否采集图片
    var images: Bool = true
    /// 是否采集文件
    var files: Bool = true
    /// 图片历史总容量上限(MB)
    var imageSizeMB: Int = 50
    /// 单张 PNG 阈值,超过按比例缩小
    var imageMaxMB: Int = 10

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipboardHistoryConfig()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        let raw = (try? c.decode(Int.self, forKey: .limit)) ?? d.limit
        limit = min(max(raw, 1), 10)
        persist = (try? c.decode(Bool.self, forKey: .persist)) ?? d.persist
        images = (try? c.decode(Bool.self, forKey: .images)) ?? d.images
        files = (try? c.decode(Bool.self, forKey: .files)) ?? d.files
        imageSizeMB = (try? c.decode(Int.self, forKey: .imageSizeMB)) ?? d.imageSizeMB
        imageMaxMB = (try? c.decode(Int.self, forKey: .imageMaxMB)) ?? d.imageMaxMB
    }
}

/// #4 汇率(默认关闭)
struct CurrencyConfig: Codable, Equatable {
    var enabled: Bool = false
}

/// #16 敏感信息
struct PrivacyConfig: Codable, Equatable {
    /// ask | mask | off
    var guardMode: String = "ask"
    var types: [String] = ["phone", "idcard", "bankcard", "email", "apikey", "privatekey", "internalip"]

    enum CodingKeys: String, CodingKey { case guardMode = "guard", types }
}

/// #11/#19 快捷键
struct HotkeysConfig: Codable, Equatable {
    var showBar: String = "ctrl+opt+space"
    var ocr: String = ""
    var history: String = "opt+cmd+v"
    var snap: String = "ctrl+opt+p"
    /// 录屏:未录制时进入选区,录制中则停止
    var record: String = "ctrl+opt+r"
    /// 录屏暂停/继续(M3)
    var recordPause: String = "ctrl+opt+shift+r"
    /// 录制中打标记点(v2)
    var recordMarker: String = "ctrl+opt+shift+m"
    /// 今日待办面板开关
    var todo: String = "ctrl+opt+t"
    /// 打印管理面板开关
    var printPanel: String = "ctrl+opt+o"
    /// 电视遥控面板开关
    var tv: String = "ctrl+opt+v"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HotkeysConfig()
        showBar = (try? c.decode(String.self, forKey: .showBar)) ?? d.showBar
        ocr = (try? c.decode(String.self, forKey: .ocr)) ?? d.ocr
        history = (try? c.decode(String.self, forKey: .history)) ?? d.history
        snap = (try? c.decode(String.self, forKey: .snap)) ?? d.snap
        record = (try? c.decode(String.self, forKey: .record)) ?? d.record
        recordPause = (try? c.decode(String.self, forKey: .recordPause)) ?? d.recordPause
        recordMarker = (try? c.decode(String.self, forKey: .recordMarker)) ?? d.recordMarker
        todo = (try? c.decode(String.self, forKey: .todo)) ?? d.todo
        printPanel = (try? c.decode(String.self, forKey: .printPanel)) ?? d.printPanel
        tv = (try? c.decode(String.self, forKey: .tv)) ?? d.tv
    }
}

/// 今日待办 + 番茄钟
struct TodoConfig: Codable, Equatable {
    /// 待办 Markdown 文件夹;空 = ~/Library/Application Support/PopBar/todo
    var dir: String = ""
    /// 昨天没做完的自动带到今天
    var carryOver: Bool = true
    /// 面板钉住(常驻、失焦不关、启动时自动恢复)
    var pinned: Bool = false
    var focusMinutes: Int = 25
    var breakMinutes: Int = 5
    /// 专注 / 休息结束时发系统通知
    var notify: Bool = true
    /// 与系统「提醒事项」App 的「PopBar」列表双向同步
    var syncReminders: Bool = false
    /// 每完成一轮专注,在系统日历的「PopBar」日历里记一个事件
    var syncCalendar: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TodoConfig()
        syncReminders = (try? c.decode(Bool.self, forKey: .syncReminders)) ?? d.syncReminders
        syncCalendar = (try? c.decode(Bool.self, forKey: .syncCalendar)) ?? d.syncCalendar
        dir = (try? c.decode(String.self, forKey: .dir)) ?? d.dir
        carryOver = (try? c.decode(Bool.self, forKey: .carryOver)) ?? d.carryOver
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? d.pinned
        focusMinutes = min(max((try? c.decode(Int.self, forKey: .focusMinutes)) ?? d.focusMinutes, 1), 180)
        breakMinutes = min(max((try? c.decode(Int.self, forKey: .breakMinutes)) ?? d.breakMinutes, 1), 60)
        notify = (try? c.decode(Bool.self, forKey: .notify)) ?? d.notify
    }
}

/// 截屏历史(阶段 C 使用)
struct SnapHistoryConfig: Codable, Equatable {
    var enabled: Bool = false
    var limit: Int = 20

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SnapHistoryConfig()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        limit = (try? c.decode(Int.self, forKey: .limit)) ?? d.limit
    }
}

/// 录屏导出 GIF(M4);width = 0 表示原始宽度
struct GifConfig: Codable, Equatable {
    var fps: Int = 10
    var width: Int = 800
    var copyToClipboard: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GifConfig()
        fps = min(max((try? c.decode(Int.self, forKey: .fps)) ?? d.fps, 1), 30)
        width = max((try? c.decode(Int.self, forKey: .width)) ?? d.width, 0)
        copyToClipboard = (try? c.decode(Bool.self, forKey: .copyToClipboard)) ?? d.copyToClipboard
    }
}

/// 导出参数(v2):裁剪 / 缩放 / 压缩 / 混音 —— 见 PRD-screen-recording-v2.md
struct RecordExportConfig: Codable, Equatable {
    /// 录制结束后按这些默认值自动跑一次导出
    var autoExport: Bool = false
    /// high | medium | low
    var quality: String = "high"
    /// 目标宽度,0 = 原始(不放大)
    var width: Int = 0
    /// mp4 | mov
    var container: String = "mp4"
    /// 0–2(1 = 原音量)
    var systemVolume: Double = 1
    var micVolume: Double = 1
    /// 导出完成后复制文件到剪贴板
    var copyToClipboard: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordExportConfig()
        autoExport = (try? c.decode(Bool.self, forKey: .autoExport)) ?? d.autoExport
        let rawQuality = (try? c.decode(String.self, forKey: .quality)) ?? d.quality
        quality = ["high", "medium", "low"].contains(rawQuality) ? rawQuality : d.quality
        width = max((try? c.decode(Int.self, forKey: .width)) ?? d.width, 0)
        container = ((try? c.decode(String.self, forKey: .container)) ?? d.container) == "mov" ? "mov" : "mp4"
        systemVolume = min(max((try? c.decode(Double.self, forKey: .systemVolume)) ?? d.systemVolume, 0), 2)
        micVolume = min(max((try? c.decode(Double.self, forKey: .micVolume)) ?? d.micVolume, 0), 2)
        copyToClipboard = (try? c.decode(Bool.self, forKey: .copyToClipboard)) ?? d.copyToClipboard
    }
}

/// 点击涟漪(v2):录制时只记事件,导出时烧进画面
struct ClickHighlightConfig: Codable, Equatable {
    var enabled: Bool = true
    /// 半径(pt,按 1080p 高度为基准等比缩放)
    var radius: Double = 40
    /// 单次涟漪持续时间(秒)
    var duration: Double = 0.6
    var color: String = "#FF3B30"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClickHighlightConfig()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        radius = min(max((try? c.decode(Double.self, forKey: .radius)) ?? d.radius, 8), 200)
        duration = min(max((try? c.decode(Double.self, forKey: .duration)) ?? d.duration, 0.15), 3)
        color = (try? c.decode(String.self, forKey: .color)) ?? d.color
    }
}

/// 摄像头画中画(v2)
struct CameraConfig: Codable, Equatable {
    var enabled: Bool = false
    /// 空串 = 系统默认摄像头
    var device: String = ""
    /// 预览窗边长(pt)
    var size: Int = 160
    var mirror: Bool = true
    /// bottomRight | bottomLeft | topRight | topLeft
    var position: String = "bottomRight"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraConfig()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        device = (try? c.decode(String.self, forKey: .device)) ?? d.device
        size = min(max((try? c.decode(Int.self, forKey: .size)) ?? d.size, 64), 480)
        mirror = (try? c.decode(Bool.self, forKey: .mirror)) ?? d.mirror
        let pos = (try? c.decode(String.self, forKey: .position)) ?? d.position
        position = ["bottomRight", "bottomLeft", "topRight", "topLeft"].contains(pos) ? pos : d.position
    }
}

/// 水印(v2)
struct WatermarkConfig: Codable, Equatable {
    var enabled: Bool = false
    /// imagePath 非空时优先用图片
    var text: String = "PopBar"
    var imagePath: String = ""
    /// 0–1
    var opacity: Double = 0.6
    /// topRight | topLeft | bottomRight | bottomLeft
    var position: String = "topRight"
    /// 字号(pt,按 1080p 高度等比缩放)
    var size: Int = 14

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WatermarkConfig()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        text = (try? c.decode(String.self, forKey: .text)) ?? d.text
        imagePath = (try? c.decode(String.self, forKey: .imagePath)) ?? d.imagePath
        opacity = min(max((try? c.decode(Double.self, forKey: .opacity)) ?? d.opacity, 0.05), 1)
        let pos = (try? c.decode(String.self, forKey: .position)) ?? d.position
        position = ["topRight", "topLeft", "bottomRight", "bottomLeft"].contains(pos) ? pos : d.position
        size = min(max((try? c.decode(Int.self, forKey: .size)) ?? d.size, 8), 96)
    }
}

/// 录屏(M1 起)——复用截屏的 saveDir 与屏幕录制权限
struct RecordConfig: Codable, Equatable {
    /// 30 | 60
    var fps: Int = 30
    /// 1 = 逻辑像素,2 = 原生像素
    var scale: Int = 2
    /// h264 | hevc
    var codec: String = "h264"
    /// mov | mp4
    var container: String = "mov"
    var showsCursor: Bool = true
    var systemAudio: Bool = true
    var microphone: Bool = false
    /// 空串 = 系统默认麦克风
    var microphoneDevice: String = ""
    /// 秒,0 = 不限
    var maxDuration: Int = 0
    var gif = GifConfig()
    /// 按屏幕 UUID 记忆上次选区:UUID → "x,y,w,h"(Cocoa 全局坐标,整数)
    var lastRects: [String: String] = [:]
    // MARK: v2
    /// 确认选区后先倒计时几秒再开始采集(0/3/5/10)
    var countdown: Int = 3
    /// 选区吸附到窗口时跟随窗口移动/缩放
    var windowFollow: Bool = true
    /// 录制完成后自动把视频文件复制到剪贴板
    var copyToClipboard: Bool = false
    var export = RecordExportConfig()
    var click = ClickHighlightConfig()
    var camera = CameraConfig()
    var watermark = WatermarkConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordConfig()
        fps = min(max((try? c.decode(Int.self, forKey: .fps)) ?? d.fps, 1), 60)
        let rawScale = (try? c.decode(Int.self, forKey: .scale)) ?? d.scale
        scale = rawScale == 1 ? 1 : d.scale
        let rawCodec = (try? c.decode(String.self, forKey: .codec)) ?? d.codec
        codec = rawCodec == "hevc" ? "hevc" : "h264"
        let rawContainer = (try? c.decode(String.self, forKey: .container)) ?? d.container
        container = rawContainer == "mp4" ? "mp4" : "mov"
        showsCursor = (try? c.decode(Bool.self, forKey: .showsCursor)) ?? d.showsCursor
        systemAudio = (try? c.decode(Bool.self, forKey: .systemAudio)) ?? d.systemAudio
        microphone = (try? c.decode(Bool.self, forKey: .microphone)) ?? d.microphone
        microphoneDevice = (try? c.decode(String.self, forKey: .microphoneDevice)) ?? d.microphoneDevice
        maxDuration = max((try? c.decode(Int.self, forKey: .maxDuration)) ?? d.maxDuration, 0)
        gif = (try? c.decode(GifConfig.self, forKey: .gif)) ?? d.gif
        lastRects = (try? c.decode([String: String].self, forKey: .lastRects)) ?? d.lastRects
        let rawCountdown = (try? c.decode(Int.self, forKey: .countdown)) ?? d.countdown
        countdown = [0, 3, 5, 10].contains(rawCountdown) ? rawCountdown : d.countdown
        windowFollow = (try? c.decode(Bool.self, forKey: .windowFollow)) ?? d.windowFollow
        copyToClipboard = (try? c.decode(Bool.self, forKey: .copyToClipboard)) ?? d.copyToClipboard
        export = (try? c.decode(RecordExportConfig.self, forKey: .export)) ?? d.export
        click = (try? c.decode(ClickHighlightConfig.self, forKey: .click)) ?? d.click
        camera = (try? c.decode(CameraConfig.self, forKey: .camera)) ?? d.camera
        watermark = (try? c.decode(WatermarkConfig.self, forKey: .watermark)) ?? d.watermark
    }
}

/// 截屏
struct SnapConfig: Codable, Equatable {
    var saveDir: String = "~/Desktop"
    /// png | jpg
    var format: String = "png"
    var showMagnifier: Bool = true
    var history = SnapHistoryConfig()
    var lastColor: String = "#FF3B30"
    var lastWidth: Double = 3
    /// 录屏(M1 起与截屏并列的功能)
    var record = RecordConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SnapConfig()
        saveDir = (try? c.decode(String.self, forKey: .saveDir)) ?? d.saveDir
        format = (try? c.decode(String.self, forKey: .format)) ?? d.format
        showMagnifier = (try? c.decode(Bool.self, forKey: .showMagnifier)) ?? d.showMagnifier
        history = (try? c.decode(SnapHistoryConfig.self, forKey: .history)) ?? d.history
        lastColor = (try? c.decode(String.self, forKey: .lastColor)) ?? d.lastColor
        lastWidth = (try? c.decode(Double.self, forKey: .lastWidth)) ?? d.lastWidth
        record = (try? c.decode(RecordConfig.self, forKey: .record)) ?? d.record
    }
}

/// #19 OCR
struct OCRConfig: Codable, Equatable {
    /// panel | bar
    var after: String = "panel"
}

/// 朗读(划词工具条与翻译面板共用);voice 存 AVSpeechSynthesisVoice.identifier,空 = 自动跟随语言
struct SpeakConfig: Codable, Equatable {
    var voice: String = ""
    /// 语速倍率,1 = 系统默认
    var rate: Double = 1.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpeakConfig()
        voice = (try? c.decode(String.self, forKey: .voice)) ?? d.voice
        rate = min(max((try? c.decode(Double.self, forKey: .rate)) ?? d.rate, 0.4), 2.0)
    }
}

/// #20 使用统计
struct UsageConfig: Codable, Equatable {
    var enabled: Bool = true
}

/// ~/Library/Application Support/PopBar/config.json
/// 所有字段都允许缺省,方便手写配置
struct PopBarConfig: Codable, Equatable {
    var sourceLanguage: String = "auto"     // auto | zh-CN | en | ja | ko
    var targetLanguage: String = "auto"     // auto | zh-CN | en | ja | ko
    var timeout: Double = 30
    var maxCharacters: Int = 5000
    var temperature: Double = 0.2
    var providers: [LLMProvider] = []

    // 通用偏好(偏好设置窗口编辑,保存即时生效)
    var appearance: String = "system"        // system | light | dark
    var language: String = "system"          // system | zh | en
    var trayClick: String = "menu"           // menu | input | clipboard — 左键点菜单栏图标
    var panelPosition: String = "top"        // top | cursor
    var triggerMode: String = "both"         // both | drag | doubleClick | keyboard(键盘选区也触发)
    var clipboardFallback: Bool = true       // AX 取词失败时允许模拟 Cmd+C 兜底
    var launchAtLogin: Bool = false

    // 功能模块
    var toolbar = ToolbarConfig()
    var appRules: [AppRule] = []
    var extensions: [ExtensionConfig] = []
    var clipboardHistory = ClipboardHistoryConfig()
    var currency = CurrencyConfig()
    var privacy = PrivacyConfig()
    var hotkeys = HotkeysConfig()
    var ocr = OCRConfig()
    var speak = SpeakConfig()
    var usage = UsageConfig()
    var snap = SnapConfig()
    var todo = TodoConfig()

    func appRule(for bundleID: String?) -> AppRule? {
        guard let bundleID else { return nil }
        return appRules.first { $0.bundleID == bundleID }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PopBarConfig()
        sourceLanguage = (try? c.decode(String.self, forKey: .sourceLanguage)) ?? d.sourceLanguage
        targetLanguage = (try? c.decode(String.self, forKey: .targetLanguage)) ?? d.targetLanguage
        timeout = (try? c.decode(Double.self, forKey: .timeout)) ?? d.timeout
        maxCharacters = (try? c.decode(Int.self, forKey: .maxCharacters)) ?? d.maxCharacters
        temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? d.temperature
        providers = (try? c.decode([LLMProvider].self, forKey: .providers)) ?? []
        appearance = (try? c.decode(String.self, forKey: .appearance)) ?? d.appearance
        language = (try? c.decode(String.self, forKey: .language)) ?? d.language
        trayClick = (try? c.decode(String.self, forKey: .trayClick)) ?? d.trayClick
        panelPosition = (try? c.decode(String.self, forKey: .panelPosition)) ?? d.panelPosition
        triggerMode = (try? c.decode(String.self, forKey: .triggerMode)) ?? d.triggerMode
        clipboardFallback = (try? c.decode(Bool.self, forKey: .clipboardFallback)) ?? d.clipboardFallback
        launchAtLogin = (try? c.decode(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
        toolbar = (try? c.decode(ToolbarConfig.self, forKey: .toolbar)) ?? d.toolbar
        appRules = (try? c.decode([AppRule].self, forKey: .appRules)) ?? []
        extensions = (try? c.decode([ExtensionConfig].self, forKey: .extensions)) ?? []
        clipboardHistory = (try? c.decode(ClipboardHistoryConfig.self, forKey: .clipboardHistory)) ?? d.clipboardHistory
        currency = (try? c.decode(CurrencyConfig.self, forKey: .currency)) ?? d.currency
        privacy = (try? c.decode(PrivacyConfig.self, forKey: .privacy)) ?? d.privacy
        hotkeys = (try? c.decode(HotkeysConfig.self, forKey: .hotkeys)) ?? d.hotkeys
        ocr = (try? c.decode(OCRConfig.self, forKey: .ocr)) ?? d.ocr
        speak = (try? c.decode(SpeakConfig.self, forKey: .speak)) ?? d.speak
        usage = (try? c.decode(UsageConfig.self, forKey: .usage)) ?? d.usage
        snap = (try? c.decode(SnapConfig.self, forKey: .snap)) ?? d.snap
        todo = (try? c.decode(TodoConfig.self, forKey: .todo)) ?? d.todo
        seedDefaults()
    }

    /// 新安装时预置内容(provider 模板、默认 AI 动作、常用扩展、高危应用禁用规则)
    mutating func seedDefaults() {
        if providers.isEmpty {
            providers = [
                LLMProvider(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1",
                            model: "deepseek-chat", apiKey: "", enabled: false),
                LLMProvider(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1",
                            model: "deepseek-ai/DeepSeek-V3", apiKey: "", enabled: false),
            ]
        }
        if extensions.isEmpty { extensions = ExtensionConfig.presets }
        if appRules.isEmpty {
            appRules = [
                AppRule(bundleID: "com.1password.1password", name: "1Password", mode: "disabled"),
                AppRule(bundleID: "com.bitwarden.desktop", name: "Bitwarden", mode: "disabled"),
                AppRule(bundleID: "com.apple.keychainaccess", name: "Keychain Access", mode: "disabled"),
                AppRule(bundleID: "com.apple.ScreenSharing", name: "Screen Sharing", mode: "disabled"),
                AppRule(bundleID: "com.microsoft.rdc.macos", name: "Windows App", mode: "disabled"),
            ]
        }
    }

    /// 已启用且字段完整的 provider
    var activeProviders: [LLMProvider] {
        providers.filter { p in
            let complete = [p.apiKey, p.baseURL, p.model]
                .allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return p.enabled && complete
        }
    }

    // MARK: - 磁盘位置

    /// 默认 ~/Library/Application Support/PopBar;POPBAR_CONFIG_DIR 可覆盖(测试用)
    static var directoryURL: URL {
        if let custom = ProcessInfo.processInfo.environment["POPBAR_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("PopBar")
    }

    static var fileURL: URL { directoryURL.appendingPathComponent("config.json") }

    /// 从磁盘读取;文件损坏时返回 nil,由调用方决定是否沿用旧配置
    static func readFromDisk() -> PopBarConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PopBarConfig.self, from: data)
    }

    /// 原子写入并收紧权限(文件里可能有明文 key)
    static func write(_ config: PopBarConfig) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// 首次运行:没有配置就写出模板;返回配置文件路径
    @discardableResult
    static func ensureExists() -> URL {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return fileURL }
        var t = PopBarConfig()
        t.seedDefaults()
        try? write(t)
        return fileURL
    }
}

extension ExtensionConfig {
    static let presets: [ExtensionConfig] = [
        ExtensionConfig(id: "github", name: "GitHub 搜索",
                        symbol: "cat", type: "url",
                        template: "https://github.com/search?q={text}&type=repositories"),
    ]
}
