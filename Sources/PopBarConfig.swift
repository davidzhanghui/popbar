import Foundation

/// 单个 OpenAI 兼容 provider 的配置
struct LLMProvider: Codable, Equatable {
    var name: String
    var baseURL: String
    var model: String
    /// 明文 key,保存在 config.json(权限 0600),在设置窗口里配置
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

    init(sourceLanguage: String = "auto", targetLanguage: String = "auto",
         timeout: Double = 30, maxCharacters: Int = 5000,
         temperature: Double = 0.2, providers: [LLMProvider] = []) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.timeout = timeout
        self.maxCharacters = maxCharacters
        self.temperature = temperature
        self.providers = providers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PopBarConfig()
        sourceLanguage = (try? c.decode(String.self, forKey: .sourceLanguage)) ?? d.sourceLanguage
        targetLanguage = (try? c.decode(String.self, forKey: .targetLanguage)) ?? d.targetLanguage
        timeout = (try? c.decode(Double.self, forKey: .timeout)) ?? d.timeout
        maxCharacters = (try? c.decode(Int.self, forKey: .maxCharacters)) ?? d.maxCharacters
        temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? d.temperature
        providers = (try? c.decode([LLMProvider].self, forKey: .providers)) ?? []
    }

    /// 已启用且字段完整的 provider
    var activeProviders: [LLMProvider] {
        providers.filter { p in
            let complete = [p.apiKey, p.baseURL, p.model]
                .allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return p.enabled && complete
        }
    }

    static let template = PopBarConfig(providers: [
        LLMProvider(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1",
                    model: "deepseek-chat", apiKey: "", enabled: false),
        LLMProvider(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1",
                    model: "deepseek-ai/DeepSeek-V3", apiKey: "", enabled: false),
    ])

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

    /// 早期版本的位置,首次启动时迁移过来(旧文件保留不删)
    static var legacyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/popbar/config.json")
    }

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

    /// 首次运行:优先迁移旧配置,否则写出模板;返回配置文件路径
    @discardableResult
    static func ensureExists() -> URL {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return fileURL }
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if fm.fileExists(atPath: legacyFileURL.path),
           (try? fm.copyItem(at: legacyFileURL, to: fileURL)) != nil {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } else {
            try? write(template)
        }
        return fileURL
    }
}
