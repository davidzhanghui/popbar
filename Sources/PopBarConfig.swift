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

/// #8 剪贴板历史(默认关闭)
struct ClipboardHistoryConfig: Codable, Equatable {
    var enabled: Bool = false
    var limit: Int = 100
    var persist: Bool = false
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
}

/// #19 OCR
struct OCRConfig: Codable, Equatable {
    /// panel | bar
    var after: String = "panel"
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
    var usage = UsageConfig()

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
        usage = (try? c.decode(UsageConfig.self, forKey: .usage)) ?? d.usage
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
