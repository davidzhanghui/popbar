import Foundation

/// 打印管理的数据模型与纯逻辑(状态映射、能力矩阵、墨量、参数校验 → IPP 属性、页码解析)。
/// 全是无副作用的函数,tests/print.swift 逐条覆盖。

// MARK: - 墨量 / 能力

struct PrintMarker: Codable, Equatable {
    var name: String
    var color: String
    /// 0–100;nil = 打印机没报(IPP 用 -1/-2/-3 表示未知)
    var level: Int?
    var max: Int = 100
}

struct PrintCaps: Codable, Equatable {
    var media: [String] = []
    var mediaReady: [String] = []
    var mediaDefault = ""
    var mediaTypes: [String] = []
    var sides: [String] = ["one-sided"]
    var colorModes: [String] = ["color", "monochrome"]
    var qualities: [String] = []
    var numberUp: [Int] = [1]
    var orientations: [String] = []
    var scaling: [String] = ["auto", "fit"]
    var formats: [String] = []
    var holdUntil: [String] = []
    var pageRanges = false
    var color = true
    var copiesMax = 999

    static let numberUpAll = [1, 2, 4, 6, 9, 16]
    static let quality: [Int: String] = [3: "draft", 4: "normal", 5: "high"]
    static let orientation: [Int: String] = [3: "portrait", 4: "landscape", 5: "reverse-landscape", 6: "reverse-portrait"]

    /// printer 属性组 → 能力矩阵
    init(_ p: IPPGroup) {
        media = p.strs("media-supported")
        mediaReady = p.strs("media-ready")
        mediaDefault = p.str("media-default") ?? ""
        mediaTypes = p.strs("media-type-supported")
        let s = p.strs("sides-supported"); if !s.isEmpty { sides = s }
        let c = p.strs("print-color-mode-supported"); if !c.isEmpty { colorModes = c }
        qualities = p.ints("print-quality-supported").compactMap { Self.quality[$0] }
        let n = p.ints("number-up-supported").filter { Self.numberUpAll.contains($0) }
        numberUp = n.isEmpty ? [1] : n
        orientations = p.ints("orientation-requested-supported").compactMap { Self.orientation[$0] }
        let sc = p.strs("print-scaling-supported"); if !sc.isEmpty { scaling = sc }
        formats = p.strs("document-format-supported")
        holdUntil = p.strs("job-hold-until-supported")
        pageRanges = p.bool("page-ranges-supported") == true
        color = p.bool("color-supported") != false
        if let r = p.ranges("copies-supported").first { copiesMax = r.1 }
        else if let i = p.int("copies-supported") { copiesMax = i }
    }
    init() {}
}

enum PrintMarkers {
    /// marker-levels / names / colors / high-levels 是平行数组
    static func parse(_ p: IPPGroup) -> [PrintMarker] {
        let levels = p.ints("marker-levels")
        let names = p.strs("marker-names")
        guard !levels.isEmpty, !names.isEmpty else { return [] }
        let colors = p.strs("marker-colors")
        let highs = p.ints("marker-high-levels")
        return names.enumerated().map { i, name in
            let lv = i < levels.count ? levels[i] : -1
            return PrintMarker(name: name,
                               color: i < colors.count ? colors[i] : "",
                               level: lv >= 0 ? lv : nil,
                               max: i < highs.count && highs[i] > 0 ? highs[i] : 100)
        }
    }

    /// 低于阈值的耗材,按打印机归组由调用方处理
    static func low(_ markers: [PrintMarker], threshold: Int) -> [PrintMarker] {
        markers.filter { ($0.level ?? 100) <= threshold }
    }

    /// 墨盒色名(CUPS 给的是 #RRGGBB 或空)→ 近似颜色分量;空则按名称猜
    static func rgb(_ m: PrintMarker) -> (Double, Double, Double) {
        let hex = m.color.split(separator: ";").first.map(String.init) ?? m.color
        if hex.hasPrefix("#"), hex.count >= 7, let v = Int(hex.dropFirst().prefix(6), radix: 16) {
            return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
        }
        let n = m.name.lowercased()
        if n.contains("cyan") || n.contains("青") { return (0.0, 0.7, 0.9) }
        if n.contains("magenta") || n.contains("品红") { return (0.9, 0.2, 0.55) }
        if n.contains("yellow") || n.contains("黄") { return (0.95, 0.8, 0.1) }
        if n.contains("black") || n.contains("黑") { return (0.2, 0.2, 0.22) }
        return (0.5, 0.5, 0.55)
    }
}

// MARK: - 状态

enum PrinterStateCode {
    static let idle = 3, processing = 4, stopped = 5

    static func label(_ s: Int) -> String {
        switch s {
        case idle: return L10n.t("空闲", "Idle")
        case processing: return L10n.t("打印中", "Printing")
        case stopped: return L10n.t("已暂停", "Paused")
        default: return L10n.t("未知", "Unknown")
        }
    }
}

enum JobState: String, Codable, CaseIterable {
    case pending, held, processing, stopped, canceled, aborted, completed, unknown

    init(cups: Int) {
        switch cups {
        case 3: self = .pending
        case 4: self = .held
        case 5: self = .processing
        case 6: self = .stopped
        case 7: self = .canceled
        case 8: self = .aborted
        case 9: self = .completed
        default: self = .unknown
        }
    }

    var isActive: Bool { self == .pending || self == .held || self == .processing || self == .stopped }
    var isFailed: Bool { self == .canceled || self == .aborted }
    var isTerminal: Bool { self == .completed || isFailed }

    var label: String {
        switch self {
        case .pending: return L10n.t("排队中", "Queued")
        case .held: return L10n.t("已挂起", "Held")
        case .processing: return L10n.t("打印中", "Printing")
        case .stopped: return L10n.t("已停止", "Stopped")
        case .canceled: return L10n.t("已取消", "Canceled")
        case .aborted: return L10n.t("已中止", "Aborted")
        case .completed: return L10n.t("已完成", "Completed")
        case .unknown: return L10n.t("未知", "Unknown")
        }
    }
}

enum PrintReasons {
    /// 对用户没有信息量的原因:`processing-to-stop-point` 是正常结束原因,
    /// 已完成/已取消的作业会长期带着它,不过滤的话看起来像「还在打印」
    private static let quiet: Set<String> = [
        "none", "processing-to-stop-point", "job-completed-successfully", "job-incoming", "job-queued",
        "job-printing", "printer-stopped", "job-canceled-by-user",
    ]

    /// 去掉 -report / -warning / -error 后缀的基名
    static func base(_ r: String) -> String {
        for suf in ["-report", "-warning", "-error"] where r.hasSuffix(suf) {
            return String(r.dropLast(suf.count))
        }
        return r
    }

    static func severity(_ r: String) -> Int {
        if r.hasSuffix("-error") { return 2 }
        if r.hasSuffix("-warning") { return 1 }
        return 0
    }

    static func label(_ reason: String) -> String? {
        if quiet.contains(reason) { return nil }
        let b = base(reason)
        let map: [String: (String, String)] = [
            "media-empty": ("缺纸", "Out of paper"),
            "media-needed": ("需要装纸", "Paper needed"),
            "media-jam": ("卡纸", "Paper jam"),
            "media-low": ("纸张不足", "Paper low"),
            "cover-open": ("盖板未关", "Cover open"),
            "door-open": ("舱门未关", "Door open"),
            "marker-supply-low": ("墨量偏低", "Ink low"),
            "marker-supply-empty": ("墨水耗尽", "Ink empty"),
            "marker-waste-almost-full": ("废墨仓将满", "Waste ink almost full"),
            "marker-waste-full": ("废墨仓已满", "Waste ink full"),
            "toner-low": ("碳粉偏低", "Toner low"),
            "toner-empty": ("碳粉耗尽", "Toner empty"),
            "offline": ("离线", "Offline"),
            "paused": ("已暂停", "Paused"),
            "connecting-to-device": ("正在连接设备", "Connecting to device"),
            "other": ("需要处理", "Needs attention"),
            "input-tray-missing": ("纸盒未插好", "Input tray missing"),
            "output-area-full": ("出纸区已满", "Output area full"),
            "spool-area-full": ("缓冲区已满", "Spool area full"),
            "cups-waiting-for-job-completed": ("等待上一个作业完成", "Waiting for previous job"),
            "job-hold-until-specified": ("定时挂起", "Held until scheduled"),
            "job-held-for-authentication": ("等待认证", "Held for authentication"),
            "job-canceled-at-device": ("在打印机上被取消", "Canceled at the printer"),
            "job-canceled-by-operator": ("被管理员取消", "Canceled by operator"),
            "job-errors-detected": ("文档有错误", "Errors in document"),
            "document-format-error": ("文件格式错误", "Document format error"),
            "document-unprintable-error": ("文档无法打印", "Document unprintable"),
            "cups-insecure-filter": ("过滤器不安全", "Insecure filter"),
            "printer-stopped-partly": ("打印机部分停止", "Printer partly stopped"),
            "resources-are-not-ready": ("资源未就绪", "Resources not ready"),
            "job-held-on-create": ("作业已挂起", "Held on creation"),
        ]
        if let t = map[b] { return L10n.t(t.0, t.1) }
        return reason
    }

    /// 用户可读的原因列表(去重、去静默)
    static func labels(_ reasons: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for r in reasons {
            guard let l = label(r), seen.insert(l).inserted else { continue }
            out.append(l)
        }
        return out
    }

    /// 打印机是否有需要用户处理的错误级原因
    static func hasError(_ reasons: [String]) -> Bool {
        reasons.contains { severity($0) == 2 && label($0) != nil }
    }
}

// MARK: - 打印参数

/// 提交打印的参数。空字符串 = 不指定(用打印机默认)。
struct PrintOptions: Codable, Equatable {
    var copies = 1
    var color = ""          // color | monochrome | auto
    var quality = ""        // draft | normal | high
    var media = ""
    var mediaType = ""
    var orientation = ""    // portrait | landscape | reverse-landscape | reverse-portrait
    var sides = ""          // one-sided | two-sided-long-edge | two-sided-short-edge
    var numberUp = 1
    var scaling = ""        // auto | fit | fill | none
    var pageRange = ""
    /// 提交后先挂起(job-hold-until=indefinite),在任务页点「继续」才真正打印
    var hold = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrintOptions()
        copies = (try? c.decode(Int.self, forKey: .copies)) ?? d.copies
        color = (try? c.decode(String.self, forKey: .color)) ?? d.color
        quality = (try? c.decode(String.self, forKey: .quality)) ?? d.quality
        media = (try? c.decode(String.self, forKey: .media)) ?? d.media
        mediaType = (try? c.decode(String.self, forKey: .mediaType)) ?? d.mediaType
        orientation = (try? c.decode(String.self, forKey: .orientation)) ?? d.orientation
        sides = (try? c.decode(String.self, forKey: .sides)) ?? d.sides
        numberUp = (try? c.decode(Int.self, forKey: .numberUp)) ?? d.numberUp
        scaling = (try? c.decode(String.self, forKey: .scaling)) ?? d.scaling
        pageRange = (try? c.decode(String.self, forKey: .pageRange)) ?? d.pageRange
        hold = (try? c.decode(Bool.self, forKey: .hold)) ?? d.hold
    }

    /// 预设只保存白名单内的键;份数、页码范围、挂起不进预设(每次打印都不一样)
    func presetSanitized() -> PrintOptions {
        var o = self
        o.copies = min(max(copies, 1), 999)
        o.numberUp = max(numberUp, 1)
        o.pageRange = ""
        o.hold = false
        return o
    }
}

enum PrintOptionBuilder {
    static let openEnd = 2147483647
    private static let qualityEnum = ["draft": 3, "normal": 4, "high": 5]
    private static let orientEnum = ["portrait": 3, "landscape": 4, "reverse-portrait": 6, "reverse-landscape": 5]

    /// "1-3,5,8-" → [(1,3),(5,5),(8,openEnd)];空 → nil
    static func parsePageRanges(_ str: String) throws -> [(Int, Int)]? {
        let s = str.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        var out: [(Int, Int)] = []
        for raw in s.split(separator: ",") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            let nums = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            func n(_ x: String) -> Int? { x.allSatisfy(\.isASCII) && !x.isEmpty ? Int(x) : nil }
            if nums.count == 1, let a = n(nums[0]) {
                if a < 1 { throw PrintError.message(L10n.t("页码必须从 1 开始:\(part)", "Pages start at 1: \(part)")) }
                out.append((a, a))
            } else if nums.count == 2, let a = n(nums[0]), let b = n(nums[1]) {
                if a < 1 || b < a { throw PrintError.message(L10n.t("页码范围不合法:\(part)", "Invalid page range: \(part)")) }
                out.append((a, b))
            } else if nums.count == 2, let a = n(nums[0]), nums[1].isEmpty {
                if a < 1 { throw PrintError.message(L10n.t("页码必须从 1 开始:\(part)", "Pages start at 1: \(part)")) }
                out.append((a, openEnd))
            } else {
                throw PrintError.message(L10n.t("页码范围格式应为 1-3,5:\(part)", "Page ranges look like 1-3,5: \(part)"))
            }
        }
        return out.isEmpty ? nil : out
    }

    /// 选中的页集合(页码从 1 起)→ "1-3,5" 文本;全选返回空串(= 不指定)
    static func rangeString(pages: Set<Int>, total: Int) -> String {
        let sel = pages.filter { $0 >= 1 && $0 <= total }.sorted()
        if sel.isEmpty || sel.count == total { return "" }
        var parts: [String] = [], i = 0
        while i < sel.count {
            var j = i
            while j + 1 < sel.count, sel[j + 1] == sel[j] + 1 { j += 1 }
            parts.append(j > i ? "\(sel[i])-\(sel[j])" : "\(sel[i])")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    /// 页码范围文本 → 页集合(供缩略图网格回显);无法解析返回 nil
    static func pageSet(_ str: String, total: Int) -> Set<Int>? {
        guard let rs = try? parsePageRanges(str) else { return nil }
        var s = Set<Int>()
        for (a, b) in rs where a <= total { for p in a...min(b, total) { s.insert(p) } }
        return s
    }

    /// Validate-Job 对不支持的参数也会放行(本机实测),所以服务端自己按能力矩阵校验。
    /// UI 置灰只是体验,不是防线。
    static func build(_ o: PrintOptions, caps: PrintCaps, pageCount: Int?) throws -> [IPPAttrOut] {
        var out: [IPPAttrOut] = []
        func add(_ name: String, _ v: IPPOut) { out.append(IPPAttrOut(group: IPP_TAG_JOB, name: name, value: v)) }
        func reject(_ name: String, _ value: String) -> PrintError {
            .message(L10n.t("这台打印机不支持 \(name) = \(value)", "This printer does not support \(name) = \(value)"))
        }

        guard o.copies >= 1 else { throw PrintError.message(L10n.t("份数必须是 ≥1 的整数", "Copies must be at least 1")) }
        if o.copies > caps.copiesMax {
            throw PrintError.message(L10n.t("份数不能超过 \(caps.copiesMax)", "Copies cannot exceed \(caps.copiesMax)"))
        }
        if o.copies > 1 { add("copies", .int(o.copies)) }

        if !o.media.isEmpty {
            if !caps.media.isEmpty && !caps.media.contains(o.media) { throw reject("media", o.media) }
            add("media", .keyword([o.media]))
        }
        if !o.mediaType.isEmpty {
            if !caps.mediaTypes.isEmpty && !caps.mediaTypes.contains(o.mediaType) { throw reject("media-type", o.mediaType) }
            add("media-type", .keyword([o.mediaType]))
        }
        if !o.color.isEmpty {
            if !caps.colorModes.contains(o.color) { throw reject("print-color-mode", o.color) }
            add("print-color-mode", .keyword([o.color]))
        }
        if !o.quality.isEmpty {
            guard let e = qualityEnum[o.quality], caps.qualities.contains(o.quality) else { throw reject("print-quality", o.quality) }
            add("print-quality", .enumValue(e))
        }
        if !o.orientation.isEmpty {
            guard let e = orientEnum[o.orientation], caps.orientations.contains(o.orientation) else {
                throw reject("orientation-requested", o.orientation)
            }
            add("orientation-requested", .enumValue(e))
        }
        if !o.sides.isEmpty {
            if !caps.sides.contains(o.sides) { throw reject("sides", o.sides) }
            if o.sides != "one-sided" { add("sides", .keyword([o.sides])) }
        }
        if o.numberUp > 1 {
            if !caps.numberUp.contains(o.numberUp) { throw reject("number-up", String(o.numberUp)) }
            add("number-up", .int(o.numberUp))
        }
        if !o.scaling.isEmpty {
            if !caps.scaling.isEmpty && !caps.scaling.contains(o.scaling) { throw reject("print-scaling", o.scaling) }
            add("print-scaling", .keyword([o.scaling]))
        }
        if o.hold {
            guard caps.holdUntil.contains("indefinite") else { throw reject("job-hold-until", "indefinite") }
            add("job-hold-until", .keyword(["indefinite"]))
        }
        if let ranges = try parsePageRanges(o.pageRange) {
            if !caps.pageRanges {
                throw PrintError.message(L10n.t("这台打印机不支持指定页码范围", "This printer does not support page ranges"))
            }
            if let total = pageCount {
                for (a, b) in ranges where a > total || (b != openEnd && b > total) {
                    throw PrintError.message(L10n.t("页码范围超出文档页数(共 \(total) 页)", "Page range exceeds the document (\(total) pages)"))
                }
            }
            add("page-ranges", .ranges(ranges))
        }
        return out
    }

    /// 打印机是否能收这种格式。CUPS 会把图片统一走 image/* 过滤器,只对明显不支持的报错
    static func checkMime(_ mime: String, caps: PrintCaps) throws {
        if caps.formats.isEmpty || caps.formats.contains(mime) { return }
        if mime.hasPrefix("image/"), caps.formats.contains(where: { $0.hasPrefix("image/") }) { return }
        // 打印机原生不收 PDF 时 CUPS 会转换;只有 formats 里一个 PDF 都没有且有别的原生格式才拒绝
        if caps.formats.contains("application/pdf") || caps.formats.contains("application/vnd.cups-pdf") { return }
        throw PrintError.message(L10n.t("这台打印机不支持 \(mime) 格式", "This printer does not support \(mime)"))
    }
}

// MARK: - 选项中文名

enum PrintLabels {
    static func media(_ key: String) -> String {
        let map: [String: String] = [
            "iso_a4_210x297mm": "A4", "iso_a3_297x420mm": "A3", "iso_a5_148x210mm": "A5", "iso_a6_105x148mm": "A6",
            "iso_b5_176x250mm": "B5", "na_letter_8.5x11in": "Letter", "na_legal_8.5x14in": "Legal",
            "na_executive_7.25x10.5in": "Executive", "na_index-4x6_4x6in": "4×6 in", "na_5x7_5x7in": "5×7 in",
            "na_index-5x8_5x8in": "5×8 in", "jpn_hagaki_100x148mm": L10n.t("明信片", "Hagaki"),
            "na_number-10_4.125x9.5in": "#10 Envelope", "iso_dl_110x220mm": "DL Envelope",
            "iso_c5_162x229mm": "C5 Envelope",
        ]
        if let n = map[key] { return n }
        // 其余 "<类>_<名>_<宽>x<高><单位>" 取名字与尺寸
        let parts = key.split(separator: "_")
        if parts.count >= 3 { return "\(parts[1]) \(parts[2])" }
        return key
    }

    static func mediaType(_ key: String) -> String {
        let map: [String: (String, String)] = [
            "stationery": ("普通纸", "Plain paper"), "photographic": ("相纸", "Photo paper"),
            "photographic-glossy": ("光面相纸", "Glossy photo"), "photographic-matte": ("哑光相纸", "Matte photo"),
            "photographic-semi-gloss": ("半光相纸", "Semi-gloss photo"), "envelope": ("信封", "Envelope"),
            "labels": ("标签纸", "Labels"), "cardstock": ("卡纸", "Cardstock"),
            "stationery-letterhead": ("信头纸", "Letterhead"), "transparency": ("投影片", "Transparency"),
            "stationery-coated": ("涂层纸", "Coated"), "stationery-inkjet": ("喷墨纸", "Inkjet paper"),
            "stationery-heavyweight": ("厚纸", "Heavy paper"), "stationery-lightweight": ("薄纸", "Light paper"),
            "other": ("其他", "Other"), "auto": ("自动", "Auto"),
        ]
        if let t = map[key] { return L10n.t(t.0, t.1) }
        return key
    }

    static func color(_ k: String) -> String {
        switch k {
        case "color": return L10n.t("彩色", "Color")
        case "monochrome": return L10n.t("黑白", "Black & white")
        case "auto": return L10n.t("自动", "Auto")
        case "bi-level": return L10n.t("纯黑白", "Bi-level")
        case "process-monochrome": return L10n.t("灰度", "Grayscale")
        default: return k
        }
    }

    static func quality(_ k: String) -> String {
        switch k {
        case "draft": return L10n.t("草稿", "Draft")
        case "normal": return L10n.t("标准", "Normal")
        case "high": return L10n.t("高质量", "High")
        default: return k
        }
    }

    static func sides(_ k: String) -> String {
        switch k {
        case "one-sided": return L10n.t("单面", "One-sided")
        case "two-sided-long-edge": return L10n.t("双面(长边翻转)", "Two-sided (long edge)")
        case "two-sided-short-edge": return L10n.t("双面(短边翻转)", "Two-sided (short edge)")
        default: return k
        }
    }

    static func orientation(_ k: String) -> String {
        switch k {
        case "": return L10n.t("自动", "Auto")
        case "portrait": return L10n.t("纵向", "Portrait")
        case "landscape": return L10n.t("横向", "Landscape")
        case "reverse-landscape": return L10n.t("横向(反向)", "Reverse landscape")
        case "reverse-portrait": return L10n.t("纵向(反向)", "Reverse portrait")
        default: return k
        }
    }

    static func scaling(_ k: String) -> String {
        switch k {
        case "auto": return L10n.t("自动", "Auto")
        case "fit": return L10n.t("适合页面", "Fit to page")
        case "fill": return L10n.t("填满页面", "Fill page")
        case "none": return L10n.t("原始大小", "Actual size")
        case "auto-fit": return L10n.t("自动适合", "Auto fit")
        default: return k
        }
    }
}
