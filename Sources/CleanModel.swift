import Foundation

/// 磁盘清理 —— 数据模型(移植自 mole-demo 的清理模块,A 档:只清理用户目录,删除一律进废纸篓)。

enum CleanSafety: String, Sendable {
    case safe       // 可再生,默认勾选
    case review     // 需确认,默认不勾选
    case blocked    // 永不清理
}

enum CleanKind: Equatable, Sendable {
    /// 整个目录/文件移入废纸篓
    case path
    /// npm cacache:引用图分析后只删孤儿 blob(可再生缓存,直接删除而不进废纸篓)
    case npmCache
}

enum CleanCategory: String, CaseIterable, Identifiable, Sendable {
    case appCache, developerTools, aiTools, remnants

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appCache: return L10n.t("App 缓存与日志", "App Caches & Logs")
        case .developerTools: return L10n.t("开发工具", "Developer Tools")
        case .aiTools: return L10n.t("AI 工具", "AI Tools")
        case .remnants: return L10n.t("卸载残留", "Uninstall Leftovers")
        }
    }

    /// tab 上用的短名
    var shortTitle: String {
        switch self {
        case .appCache: return L10n.t("App 缓存", "Caches")
        case .developerTools: return L10n.t("开发工具", "Dev")
        case .aiTools: return "AI"
        case .remnants: return L10n.t("卸载残留", "Leftovers")
        }
    }

    var summary: String {
        switch self {
        case .appCache:
            return L10n.t("App、浏览器和云盘缓存及旧日志,保留登录状态和浏览记录",
                          "App, browser and cloud-drive caches and old logs; sign-ins and history are kept")
        case .developerTools:
            return L10n.t("Xcode、编译与包管理器产生的可再生构建缓存",
                          "Rebuildable caches from Xcode, compilers and package managers")
        case .aiTools:
            return L10n.t("AI 编程工具与模型运行时产生的缓存",
                          "Caches from AI coding tools and model runtimes")
        case .remnants:
            return L10n.t("已卸载应用留下的容器与支持文件,默认不勾选",
                          "Containers and support files left by removed apps; unchecked by default")
        }
    }

    var symbol: String {
        switch self {
        case .appCache: return "shippingbox"
        case .developerTools: return "hammer"
        case .aiTools: return "sparkles"
        case .remnants: return "trash.slash"
        }
    }
}

enum CleanSelState {
    case none, partial, all

    static func from(selected: Int, total: Int) -> CleanSelState {
        if total == 0 || selected == 0 { return .none }
        return selected >= total ? .all : .partial
    }
}

struct CleanItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let url: URL
    let name: String
    let displayPath: String
    let category: CleanCategory
    let kind: CleanKind
    let safety: CleanSafety
    let hint: String?
    var ownerBundleID: String?
    var ownerAppName: String?
    var sizeBytes: Int64?
    var isSelected: Bool
    /// 所属 App 正在运行:加锁,不可勾选
    var isLocked: Bool
    /// 动态状态(使用中 / 分析结果),优先于 hint 展示
    var statusNote: String?

    var isSelectable: Bool { !isLocked && safety != .blocked }
    var displayNote: String? { statusNote ?? hint }
}

/// 手动管理项:只展示占用,不参与清理
struct CleanManualItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let url: URL
    let name: String
    let displayPath: String
    let hint: String
    var sizeBytes: Int64?
}

struct CleanSummary: Sendable {
    var trashedCount: Int
    var npmCount: Int
    var failedCount: Int
    /// 失败项的「名称:原因」,最多展示几条
    var failures: [String] = []
    var freedBytes: Int64
    /// 进了废纸篓的字节数:清倒废纸篓后才真正释放
    var trashedBytes: Int64

    var title: String {
        failedCount == 0 ? L10n.t("清理完成", "Cleanup Done") : L10n.t("清理结束", "Cleanup Finished")
    }

    var text: String {
        var parts: [String] = []
        if trashedCount > 0 {
            parts.append(L10n.t("已将 \(trashedCount) 项(\(ByteFormat.string(trashedBytes)))移入废纸篓,清倒废纸篓后释放空间",
                                "Moved \(trashedCount) items (\(ByteFormat.string(trashedBytes))) to the Trash; empty it to free the space"))
        }
        if npmCount > 0 {
            parts.append(L10n.t("npm 孤儿缓存已直接清除,释放 \(ByteFormat.string(freedBytes - trashedBytes))",
                                "npm orphan cache removed, freed \(ByteFormat.string(freedBytes - trashedBytes))"))
        }
        if parts.isEmpty { parts.append(L10n.t("没有可处理的项目", "Nothing to process")) }
        if failedCount > 0 {
            parts.append(L10n.t("失败 \(failedCount) 项,详见日志", "\(failedCount) failed, see the log"))
            parts.append(contentsOf: failures.prefix(3))
        }
        return parts.joined(separator: "\n")
    }
}

enum CleanDisplayPath {
    static func shorten(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}
