import Foundation
import PopBarCore

// MARK: - 验机状态与核心数据模型

enum MCStatus: String, Codable, Sendable, Hashable {
    case pass
    case warning
    case critical
    case skipped
    case unsupported

    var label: String {
        switch self {
        case .pass: return L10n.t("正常", "Passed")
        case .warning: return L10n.t("注意", "Warning")
        case .critical: return L10n.t("严重", "Critical")
        case .skipped: return L10n.t("已跳过", "Skipped")
        case .unsupported: return L10n.t("不适用", "Unsupported")
        }
    }

    var icon: String {
        switch self {
        case .pass: return "circle-check"
        case .warning: return "triangle-alert"
        case .critical: return "shield-alert"
        case .skipped, .unsupported: return "minus"
        }
    }

    /// 用于同一分类下聚合取最严重等级
    var severityRank: Int {
        switch self {
        case .critical: return 4
        case .warning: return 3
        case .pass: return 2
        case .skipped: return 1
        case .unsupported: return 0
        }
    }
}

/// 键值明细项（保持插入顺序，便于界面与报告稳定渲染）
struct MCDetailPair: Codable, Sendable, Hashable, Identifiable {
    var id: String { key }
    var key: String
    var value: String
    var mono: Bool = false

    init(_ key: String, _ value: String, mono: Bool = false) {
        self.key = key
        self.value = value
        self.mono = mono
    }
}

/// 单项检测结果（自动探测或交互测试共用）
struct MCCheckItem: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var category: MCCategory
    var title: String
    var status: MCStatus
    var summary: String
    var details: [MCDetailPair] = []
    /// 命中二手机高风险项时的显著提示（例如 MDM 监管、绕过痕迹、激活锁开启）
    var riskNotice: String? = nil
}

/// 自动检测分类
enum MCCategory: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case specs
    case battery
    case security
    case storage
    case network
    case ports
    case interactive

    var id: String { rawValue }

    static let autoCategories: [MCCategory] = [.specs, .battery, .security, .storage, .network, .ports]

    var title: String {
        switch self {
        case .specs: return L10n.t("硬件规格", "Hardware Specs")
        case .battery: return L10n.t("电池健康", "Battery Health")
        case .security: return L10n.t("安全与锁定", "Security & Locks")
        case .storage: return L10n.t("存储与寿命", "Storage & SMART")
        case .network: return L10n.t("无线网络", "Wi-Fi & Bluetooth")
        case .ports: return L10n.t("外部接口", "USB & Thunderbolt")
        case .interactive: return L10n.t("硬件测试", "Hardware Tests")
        }
    }

    var icon: String {
        switch self {
        case .specs: return "cpu"
        case .battery: return "battery-charging"
        case .security: return "shield-check"
        case .storage: return "hard-drive"
        case .network: return "wifi"
        case .ports: return "zap"
        case .interactive: return "sliders-horizontal"
        }
    }
}

/// 10 项硬件交互测试类型
enum MCInteractiveKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case keyboard
    case screen
    case audio
    case microphone
    case camera
    case touchID
    case trackpad
    case stress
    case diskSpeed
    case portsLive

    var id: String { rawValue }

    var resultID: String { "interactive.\(rawValue)" }

    var needsFullscreen: Bool { self == .keyboard || self == .screen }

    var title: String {
        switch self {
        case .keyboard: return L10n.t("键盘逐键测试", "Keyboard Test")
        case .screen: return L10n.t("屏幕坏点与灰阶", "Display Test")
        case .audio: return L10n.t("扬声器与声道", "Speakers & Channels")
        case .microphone: return L10n.t("麦克风录音回放", "Microphone Test")
        case .camera: return L10n.t("摄像头画面", "Camera Preview")
        case .touchID: return "Touch ID"
        case .trackpad: return L10n.t("触控板与压感", "Trackpad & Force")
        case .stress: return L10n.t("CPU 性能压测", "CPU Stress Test")
        case .diskSpeed: return L10n.t("硬盘读写测速", "Disk Benchmark")
        case .portsLive: return L10n.t("接口热插拔实测", "Live Port Check")
        }
    }

    var subtitle: String {
        switch self {
        case .keyboard: return L10n.t("全屏逐键点亮、媒体键与卡键识别", "Fullscreen per-key, media keys and stuck-key check")
        case .screen: return L10n.t("纯色、灰阶与棋盘格检查坏点偏色", "Solid colors, grayscale and grid for dead pixels")
        case .audio: return L10n.t("左、右及立体声合成音验证扬声器", "Left, right and stereo tones for speakers")
        case .microphone: return L10n.t("实时电平监测与 3 秒录音回放", "Live meter and 3-second loopback recording")
        case .camera: return L10n.t("实时预览检查清晰度与传感器坏点", "Live preview for sharpness and blemishes")
        case .touchID: return L10n.t("验证指纹识别模块是否工作正常", "Verify biometric sensor availability")
        case .trackpad: return L10n.t("检测点击、压感、滚动与多指触控", "Test clicks, Force Touch, scroll and multitouch")
        case .stress: return L10n.t("多核满载压测并实时监控温度与风扇", "Multi-core load with live temp & fan telemetry")
        case .diskSpeed: return L10n.t("绕过页缓存测量 SSD 真实顺序读写", "Direct F_NOCACHE sequential read/write speed")
        case .portsLive: return L10n.t("基于 IOKit 事件实时监听外设热插拔", "Event-driven USB/TB hot-plug verification")
        }
    }

    var icon: String {
        switch self {
        case .keyboard: return "keyboard"
        case .screen: return "monitor"
        case .audio: return "volume-2"
        case .microphone: return "mic"
        case .camera: return "camera"
        case .touchID: return "lock"
        case .trackpad: return "mouse-pointer-2"
        case .stress: return "flame"
        case .diskSpeed: return "gauge"
        case .portsLive: return "zap"
        }
    }
}

/// Deck 页面顶部子标签
enum MCTab: String, CaseIterable, Hashable {
    case overview
    case system
    case tests
    case ai
    case history

    var title: String {
        switch self {
        case .overview: return L10n.t("概览", "Overview")
        case .system: return L10n.t("系统检测", "System")
        case .tests: return L10n.t("硬件测试", "Tests")
        case .ai: return L10n.t("AI 算力", "AI Fit")
        case .history: return L10n.t("历史快照", "History")
        }
    }
}

/// 机器基础档案（Phase 1 亚毫秒级组装，Phase 2 补充完整信息）
struct MCDeviceProfile: Codable, Sendable, Equatable {
    var marketingName: String
    var modelIdentifier: String
    var chip: String
    var architecture: String
    var physicalCores: Int
    var pCores: Int
    var eCores: Int
    var memoryBytes: UInt64
    var macOSVersion: String
    var serialNumber: String
    var modelYear: String
    var hardwareUUID: String
    var scanElapsedMs: Int

    var memoryGB: Int {
        Int((Double(memoryBytes) / 1_073_741_824.0).rounded())
    }

    var memoryDisplay: String {
        "\(memoryGB) GB"
    }
}

/// 完整验机报告（支持评分与导出）
struct MCReport: Codable, Sendable, Equatable {
    var generatedAt: Date
    var appVersion: String
    var profile: MCDeviceProfile?
    var items: [MCCheckItem]

    var criticalRisks: [MCCheckItem] {
        items.filter { $0.status == .critical || $0.riskNotice != nil }
    }

    var warningItems: [MCCheckItem] {
        items.filter { $0.status == .warning }
    }

    /// 综合健康评分（0–100）：严重红旗每项 -35，警告每项 -10；存在严重红旗时最高不超过 55 分
    var score: Int {
        Self.computeScore(items: items)
    }

    static func computeScore(items: [MCCheckItem]) -> Int {
        var s = 100
        var hasCritical = false
        for item in items {
            switch item.status {
            case .critical:
                s -= 35
                hasCritical = true
            case .warning:
                s -= 10
            case .pass, .skipped, .unsupported:
                break
            }
        }
        if hasCritical { s = min(s, 55) }
        return max(0, min(100, s))
    }

    var gradeLabel: String {
        if !criticalRisks.filter({ $0.status == .critical }).isEmpty || score < 60 {
            return L10n.t("高风险", "High Risk")
        }
        if score < 88 {
            return L10n.t("需留意", "Attention")
        }
        return L10n.t("状态良好", "Healthy")
    }
}

/// 历史快照条目
struct MCSavedSnapshot: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var savedAt: Date
    var deviceName: String
    var serial: String
    var score: Int
    var batteryCycles: Int?
    var batteryHealthPct: Int?
    var ssdWearPct: Int?
    var report: MCReport
}

// MARK: - 历史记录存储（存入 PopBar 统一数据目录）

enum MCHistoryStore {
    static var fileURL: URL {
        PopBarConfig.directoryURL.appendingPathComponent("maccheck-history.json")
    }

    static func load(from url: URL? = nil) -> [MCSavedSnapshot] {
        let target = url ?? fileURL
        guard let data = try? Data(contentsOf: target),
              let list = try? JSONDecoder().decode([MCSavedSnapshot].self, from: data) else {
            return []
        }
        return list.sorted { $0.savedAt > $1.savedAt }
    }

    @discardableResult
    static func save(_ list: [MCSavedSnapshot], to url: URL? = nil) -> Bool {
        let target = url ?? fileURL
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(list)
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 序列号解码器（纯函数，易于单测）

struct MCSerialInfo: Sendable, Equatable {
    var serial: String
    var isRandomized: Bool
    var estimatedYear: Int?
    var estimatedWeek: Int?
    var factory: String?
}

enum MCSerialDecoder {
    /// 2010–2021 年 12 位序列号第 4 位年份码（每半年一档，共 20 字符循环）
    private static let yearTable: [Character: (year: Int, secondHalf: Bool)] = [
        "C": (2010, false), "D": (2010, true),
        "F": (2011, false), "G": (2011, true),
        "H": (2012, false), "J": (2012, true),
        "K": (2013, false), "L": (2013, true),
        "M": (2014, false), "N": (2014, true),
        "P": (2015, false), "Q": (2015, true),
        "R": (2016, false), "S": (2016, true),
        "T": (2017, false), "V": (2017, true),
        "W": (2018, false), "X": (2018, true),
        "Y": (2019, false), "Z": (2019, true),
    ]

    /// 第 5 位周数编码（1..9 + 跳过 A/E/I/O/U/B/S/Z 的 18 个字母，共 27 周/半年）
    private static let weekAlphabet: [Character] = Array("123456789CDFGHJKLMNPQRTVWXY")

    private static let factories: [String: String] = [
        "C02": "Quanta Computer (Shanghai)",
        "C07": "Quanta Computer (Shanghai)",
        "FVH": "Foxconn (China)",
        "FVF": "Foxconn (China)",
        "C1M": "Foxconn (China)",
        "G8W": "Foxconn (China)",
        "DLX": "Foxconn (China)",
        "H0Y": "Foxconn (China)",
        "W80": "Shanghai, China",
        "W88": "Shanghai, China",
    ]

    static func decode(_ raw: String) -> MCSerialInfo {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // 2021 年起 Apple 改用 10 位完全随机序列号，无法反推生产日期与产地
        if s.count == 10 {
            return MCSerialInfo(serial: s, isRandomized: true, estimatedYear: nil, estimatedWeek: nil, factory: nil)
        }
        guard s.count == 11 || s.count == 12 else {
            return MCSerialInfo(serial: s, isRandomized: false, estimatedYear: nil, estimatedWeek: nil, factory: nil)
        }
        let chars = Array(s)
        let prefix3 = String(chars[0..<3])
        let yInfo = yearTable[chars[3]]
        let weekOffset = weekAlphabet.firstIndex(of: chars[4])
        let week: Int? = {
            guard let yInfo, let off = weekOffset else { return nil }
            return min(53, (yInfo.secondHalf ? 27 : 1) + off)
        }()
        return MCSerialInfo(
            serial: s,
            isRandomized: false,
            estimatedYear: yInfo?.year,
            estimatedWeek: week,
            factory: factories[prefix3]
        )
    }

    static func estimatedAgeText(modelYear: String, nowYear: Int = Calendar.current.component(.year, from: Date())) -> String? {
        guard let y = Int(modelYear), y >= 2005, y <= nowYear + 1 else { return nil }
        let age = nowYear - y
        if age <= 0 { return L10n.t("当年款（约 1 年内）", "Current year (<1 yr)") }
        return L10n.t("约 \(age) 年", age == 1 ? "~1 year" : "~\(age) years")
    }
}

// MARK: - AI 大模型本地可跑性评估（纯函数）

enum MCAIFitLevel: String, Sendable, Equatable {
    case smooth
    case tight
    case insufficient

    var label: String {
        switch self {
        case .smooth: return L10n.t("流畅运行", "Smooth")
        case .tight: return L10n.t("勉强可跑", "Tight")
        case .insufficient: return L10n.t("内存不足", "Too Large")
        }
    }
}

struct MCAIModelTier: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let params: String
    let quantization: String
    let requiredMemoryGB: Int
    let examples: String
    let fit: MCAIFitLevel
    let note: String
}

struct MCAIResourceLink: Identifiable, Sendable {
    var id: String { url }
    let title: String
    let subtitle: String
    let url: String
}

enum MCAIAdvisor {
    /// Apple Silicon 统一内存可分配约 75% 给 Metal/GPU，Intel 机型按常规内存折算
    static func usableBudgetGB(totalMemoryGB: Int, isAppleSilicon: Bool) -> Int {
        let ratio = isAppleSilicon ? 0.75 : 0.55
        return max(4, Int((Double(totalMemoryGB) * ratio).rounded(.down)))
    }

    static func evaluate(totalMemoryGB: Int, isAppleSilicon: Bool) -> [MCAIModelTier] {
        let budget = usableBudgetGB(totalMemoryGB: totalMemoryGB, isAppleSilicon: isAppleSilicon)
        let specs: [(id: String, name: String, params: String, quant: String, req: Int, ex: String)] = [
            ("3b", L10n.t("端侧轻量级", "Ultra-Light"), "3B – 4B", "Q4_K_M", 4, "Qwen3-4B / Llama-3.2-3B / Gemma-3-4B"),
            ("7b", L10n.t("日常主力级", "Everyday"), "7B – 9B", "Q4_K_M", 7, "Qwen3-8B / Llama-3.1-8B / DeepSeek-R1-8B"),
            ("14b", L10n.t("高智商甜点级", "Sweet Spot"), "14B – 16B", "Q4_K_M", 12, "Qwen3-14B / DeepSeek-R1-14B / Phi-4-14B"),
            ("32b", L10n.t("专业编码推理级", "Pro Coding"), "27B – 32B", "Q4_K_M", 22, "Qwen3-32B / Qwen2.5-Coder-32B / Gemma-3-27B"),
            ("70b", L10n.t("旗舰大模型", "Flagship"), "70B – 72B", "Q4_K_M", 46, "Llama-3.3-70B / Qwen3-72B / DeepSeek-R1-70B"),
            ("moe", L10n.t("超大 MoE / 120B+", "Large MoE"), "120B – 235B", "Q4_K_M", 88, "Qwen3-235B-A22B / Command-A / Mistral-Large"),
        ]
        return specs.map { sp in
            let fit: MCAIFitLevel
            let note: String
            if budget >= sp.req + 4 {
                fit = .smooth
                note = L10n.t("留有充足上下文与系统余量，适合长期挂后台使用", "Plenty of headroom for long context and multitasking")
            } else if budget >= sp.req {
                fit = .tight
                note = L10n.t("建议关闭大型应用并限制上下文长度（4K–8K）", "Close heavy apps and keep context length modest (4K–8K)")
            } else {
                fit = .insufficient
                note = L10n.t("需要约 \(sp.req) GB 可用显存/统一内存（本机可用约 \(budget) GB）", "Needs ~\(sp.req) GB available memory (~\(budget) GB usable here)")
            }
            return MCAIModelTier(
                id: sp.id,
                name: sp.name,
                params: sp.params,
                quantization: sp.quant,
                requiredMemoryGB: sp.req,
                examples: sp.ex,
                fit: fit,
                note: note
            )
        }
    }

    /// 推荐甜点档：能流畅运行的最大档位（若均非流畅则退回勉强可跑的最高档）
    static func sweetSpot(totalMemoryGB: Int, isAppleSilicon: Bool) -> MCAIModelTier? {
        let tiers = evaluate(totalMemoryGB: totalMemoryGB, isAppleSilicon: isAppleSilicon)
        return tiers.last(where: { $0.fit == .smooth }) ?? tiers.last(where: { $0.fit == .tight })
    }

    static var resourceLinks: [MCAIResourceLink] {
        [
            .init(title: L10n.t("Ollama 模型库", "Ollama Library"),
                  subtitle: L10n.t("一行命令本地运行主流开源模型", "Run open models locally with a single command"),
                  url: "https://ollama.com/library"),
            .init(title: "LM Studio",
                  subtitle: L10n.t("开箱即用的桌面端本地模型客户端", "Desktop client for local GGUF / MLX models"),
                  url: "https://lmstudio.ai"),
            .init(title: "Apple MLX",
                  subtitle: L10n.t("Apple Silicon 统一内存原生优化框架", "Apple Silicon native inference framework"),
                  url: "https://github.com/ml-explore/mlx"),
            .init(title: "Hugging Face",
                  subtitle: L10n.t("开源权重与量化模型社区", "Open-source model weights and community"),
                  url: "https://huggingface.co/models"),
        ]
    }
}
