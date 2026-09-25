import Cocoa

/// #20 本地使用统计:只记录「动作 id × 应用 bundleID」的次数与最后使用时间,
/// 不记录任何文本内容。数据存 usage.json;可以用 usage.enabled=false 完全关闭。
final class UsageStats {
    static let shared = UsageStats()

    struct Entry: Codable, Equatable {
        var count: Int = 0
        var lastUsed: TimeInterval = 0
    }

    /// key = "actionId|bundleID"
    private var entries: [String: Entry] = [:]
    private var dirty = false
    private var flushTimer: Timer?

    private init() { load() }

    var enabled: Bool { ConfigStore.shared.config.usage.enabled }

    func record(_ actionID: String, bundleID: String?) {
        guard enabled else { return }
        let key = "\(actionID)|\(bundleID ?? "")"
        var e = entries[key] ?? Entry()
        e.count += 1
        e.lastUsed = Date().timeIntervalSince1970
        entries[key] = e
        dirty = true
        scheduleFlush()
    }

    /// 某应用内最常用动作,按次数降序
    func topActions(for bundleID: String, limit: Int) -> [String] {
        let suffix = "|\(bundleID)"
        return entries
            .filter { $0.key.hasSuffix(suffix) }
            .sorted { $0.value.count > $1.value.count }
            .prefix(limit)
            .map { String($0.key.dropLast(suffix.count)) }
    }

    /// 全局最常用的动作(建议提示条用)
    func topOverall(limit: Int, sinceDays: Int = 7) -> [(id: String, count: Int)] {
        let cutoff = Date().timeIntervalSince1970 - Double(sinceDays) * 86400
        var totals: [String: Int] = [:]
        for (key, e) in entries where e.lastUsed >= cutoff {
            let id = String(key.split(separator: "|").first ?? "")
            totals[id, default: 0] += e.count
        }
        return totals.sorted { $0.value > $1.value }
            .prefix(limit).map { ($0.key, $0.value) }
    }

    // MARK: - 智能建议

    /// 建议阈值:7 天内使用 ≥ 15 次,且当前在溢出菜单/未列出
    private let suggestThreshold = 15
    private let suggestInterval: TimeInterval = 7 * 86400

    /// 启动后调用:找到常用但未固定的动作,每周最多弹一次询问
    /// 「是否加入主工具条?」确认才改排序;不自动动用户排序。
    func maybeSuggest() {
        guard enabled else { return }
        let last = UserDefaults.standard.double(forKey: "PopBarSuggestAt")
        guard Date().timeIntervalSince1970 - last > suggestInterval else { return }
        let config = ConfigStore.shared.config
        let listed = Set(config.toolbar.items.filter { $0.visible }.map { $0.id })
        // 找一个:7 天高频 + 不在主条可见列表里 + 之前没建议过
        let asked = Set(UserDefaults.standard.stringArray(forKey: "PopBarSuggestedIDs") ?? [])
        guard let top = topOverall(limit: 5)
            .first(where: { $0.count >= suggestThreshold
                            && !listed.contains($0.id)
                            && !asked.contains($0.id) }) else { return }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "PopBarSuggestAt")
        var asked2 = asked
        asked2.insert(top.id)
        UserDefaults.standard.set(Array(asked2), forKey: "PopBarSuggestedIDs")

        let a = NSAlert()
        a.messageText = L10n.t("把「\(top.id)」固定到主工具条?",
                               "Pin \(top.id) to the main bar?")
        a.informativeText = L10n.t(
            "这个动作最近用了 \(top.count) 次。固定后会更靠前,排序可在偏好设置里调整。",
            "Used \(top.count) times recently. Pinning puts it first; reorder anytime in Preferences.")
        a.addButton(withTitle: L10n.t("固定", "Pin"))
        a.addButton(withTitle: L10n.t("不了", "No"))
        NSApp.activateForUI()
        guard a.runModal() == .alertFirstButtonReturn else { return }

        var c = ConfigStore.shared.config
        // 追加到 items 开头(固定=排在主条最前)
        c.toolbar.items.insert(ToolbarItem(id: top.id, visible: true), at: 0)
        try? ConfigStore.shared.save(c)
    }

    /// 某动作最后使用时间(「30 天没用过」建议用)
    func lastUsed(_ actionID: String) -> TimeInterval {
        entries.filter { $0.key.hasPrefix(actionID + "|") }
            .map { $0.value.lastUsed }.max() ?? 0
    }

    func clear() {
        entries.removeAll()
        dirty = true
        flush()
    }

    // MARK: - 持久化

    private var fileURL: URL {
        PopBarConfig.directoryURL.appendingPathComponent("usage.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.flush()
        }
        flushTimer?.tolerance = 10
    }

    func flush() {
        guard dirty else { return }
        dirty = false
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: PopBarConfig.directoryURL,
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
