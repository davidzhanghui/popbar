import Foundation

/// 已安装 App 索引:bundle id -> 展示名
struct CleanAppIndex: Sendable {
    let names: [String: String]

    func appName(forBundleID id: String) -> String? { names[id] }
    func contains(_ id: String) -> Bool { names[id] != nil }

    /// 是否是某个已安装 App 的子标识(如 com.tencent.xinWeChat.WeChatMacShare 的宿主是微信)
    func hasInstalledHost(for identifier: String) -> Bool {
        let lower = identifier.lowercased()
        return names.keys.contains { lower.hasPrefix($0.lowercased() + ".") }
    }
}

/// 扫描器:枚举已知根目录,产出清理候选。所有路径由传入的 home 派生,便于在沙箱目录里测试。
enum CleanScanner {

    struct Target: Sendable {
        let url: URL
        let name: String?
        let category: CleanCategory
        let kind: CleanKind
        let safety: CleanSafety
        let hint: String?
    }

    static func buildAppIndex(home: URL, extraRoots: [URL]? = nil) -> CleanAppIndex {
        let fm = FileManager.default
        let roots = extraRoots ?? [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
        var names: [String: String] = [:]
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                let plist = entry.appendingPathComponent("Contents/Info.plist")
                guard let d = NSDictionary(contentsOf: plist) as? [String: Any],
                      let id = d["CFBundleIdentifier"] as? String else { continue }
                let display = (d["CFBundleDisplayName"] as? String)
                    ?? (d["CFBundleName"] as? String)
                    ?? entry.deletingPathExtension().lastPathComponent
                if names[id] == nil { names[id] = display }
            }
        }
        return CleanAppIndex(names: names)
    }

    static func buildTargets(home: URL, appIndex: CleanAppIndex, runningBundleIDs: Set<String>) -> [Target] {
        var targets: [Target] = []
        var seen = Set<String>()
        let fm = FileManager.default

        func add(_ url: URL, category: CleanCategory, kind: CleanKind = .path,
                 safety: CleanSafety, name: String? = nil, hint: String? = nil) {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), fm.fileExists(atPath: key) else { return }
            seen.insert(key)
            targets.append(Target(url: url, name: name, category: category, kind: kind, safety: safety, hint: hint))
        }

        // 1. 开发工具固定路径
        for e in CleanRules.developerPaths {
            add(home.appendingPathComponent(e.path, isDirectory: true),
                category: .developerTools, safety: e.safety, hint: e.hint)
        }

        // 2. npm cacache(引用图清理:只删无索引引用的孤儿 blob)
        add(home.appendingPathComponent(CleanRules.npmCachePath, isDirectory: true),
            category: .developerTools, kind: .npmCache, safety: .safe,
            name: L10n.t("npm 缓存(_cacache)", "npm cache (_cacache)"),
            hint: L10n.t("仅清理无索引引用的孤儿内容,有效缓存保留", "Only orphan blobs with no index reference; live cache is kept"))

        // 3. ~/.cache(未在内置表中的目录归入「需确认」)
        for child in children(of: home.appendingPathComponent(".cache", isDirectory: true)) {
            let name = child.lastPathComponent
            if CleanRules.manualCacheExcludes.contains(name) || CleanRules.protectedNames.contains(name) { continue }
            if CleanRules.aiCacheNames.contains(name) {
                let modelLike = ["torch", "ollama"].contains(name)
                add(child, category: .aiTools, safety: modelLike ? .review : .safe,
                    hint: modelLike ? L10n.t("模型缓存,删除后需重新下载", "Model cache, re-downloaded after removal") : nil)
            } else if CleanRules.devCacheNames.contains(name) {
                add(child, category: .developerTools, safety: .safe)
            } else {
                add(child, category: .appCache, safety: .review,
                    hint: L10n.t("未在已知工具表中,需确认", "Not in the known-tools list; please review"))
            }
        }

        // 4. ~/Library/Caches
        for child in children(of: home.appendingPathComponent("Library/Caches", isDirectory: true)) {
            let name = child.lastPathComponent
            if CleanRules.protectedNames.contains(name) || name == "Homebrew" { continue }
            if name.hasPrefix("com.apple.") {
                add(child, category: .appCache, safety: .review,
                    hint: L10n.t("系统组件缓存,建议保留", "System component cache; best kept"))
            } else {
                add(child, category: .appCache, safety: .safe)
            }
        }

        // 5. ~/Library/Logs
        for child in children(of: home.appendingPathComponent("Library/Logs", isDirectory: true)) {
            let name = child.lastPathComponent
            if name == "DiagnosticReports" || CleanRules.protectedNames.contains(name) || name == "PopBar" { continue }
            add(child, category: .appCache, safety: .safe)
        }

        // 6. 卸载残留:Containers / Application Support 中找不到宿主 App 的 bundle id 目录
        for rootPath in ["Library/Containers", "Library/Application Support"] {
            for child in children(of: home.appendingPathComponent(rootPath, isDirectory: true)) {
                let name = child.lastPathComponent
                guard isBundleIDLike(name), !name.hasPrefix("com.apple."),
                      !CleanRules.protectedNames.contains(name) else { continue }
                guard !appIndex.contains(name), !runningBundleIDs.contains(name),
                      !appIndex.hasInstalledHost(for: name),
                      !hasRunningHost(for: name, running: runningBundleIDs) else { continue }
                add(child, category: .remnants, safety: .review,
                    hint: L10n.t("未找到对应 App,疑似残留", "No matching app found; likely a leftover"))
            }
        }
        return targets
    }

    static func buildManualItems(home: URL) -> [CleanManualItem] {
        CleanRules.manualTargets.compactMap { e in
            let url = home.appendingPathComponent(e.path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return CleanManualItem(id: UUID(), url: url, name: e.name,
                                   displayPath: CleanDisplayPath.shorten(url, home: home),
                                   hint: e.hint, sizeBytes: nil)
        }
    }

    // MARK: - 工具

    /// 形如 com.tencent.codebuddycn 的 bundle id 判定(至少三段)
    static func isBundleIDLike(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let parts = value.split(separator: ".")
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty }
    }

    private static func hasRunningHost(for identifier: String, running: Set<String>) -> Bool {
        let lower = identifier.lowercased()
        return running.contains { lower.hasPrefix($0.lowercased() + ".") }
    }

    private static func children(of dir: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
