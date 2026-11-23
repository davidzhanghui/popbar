import Cocoa
import UserNotifications
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 今日待办的数据层:一天一个 Markdown 文件,每次改动立即原子写盘;
/// 面板每次打开都会重读磁盘,所以在编辑器 / 网盘里改文件也算数。
@MainActor
final class TodoStore: ObservableObject {
    static let shared = TodoStore()
    static let changed = Notification.Name("PopBarTodoChanged")

    @Published private(set) var items: [TodoItem] = []
    @Published private(set) var deleted: [TodoItem] = []
    @Published private(set) var pastDoneGroups: [TodoDayGroup] = []
    @Published private(set) var pastDeletedGroups: [TodoDayGroup] = []
    private var extras: [String] = []
    private(set) var day = TodoMarkdown.dayKey()

    var undone: [TodoItem] { items.filter { !$0.done } }
    var done: [TodoItem] { items.filter { $0.done } }
    var undoneCount: Int { items.lazy.filter { !$0.done }.count }

    /// 今日 + 往日的全部已完成分组（按日期倒序，今天排第一）
    var allDoneGroups: [TodoDayGroup] {
        var groups: [TodoDayGroup] = []
        let todayDone = done
        if !todayDone.isEmpty { groups.append(TodoDayGroup(day: day, items: todayDone)) }
        groups.append(contentsOf: pastDoneGroups)
        return groups
    }

    /// 今日 + 往日的全部已删除分组（按日期倒序，今天排第一）
    var allDeletedGroups: [TodoDayGroup] {
        var groups: [TodoDayGroup] = []
        if !deleted.isEmpty { groups.append(TodoDayGroup(day: day, items: deleted)) }
        groups.append(contentsOf: pastDeletedGroups)
        return groups
    }

    var allDoneCount: Int {
        done.count + pastDoneGroups.reduce(0) { $0 + $1.items.count }
    }

    var allDeletedCount: Int {
        deleted.count + pastDeletedGroups.reduce(0) { $0 + $1.items.count }
    }

    // MARK: - 位置

    /// 配置的目录;空则用 Application Support/PopBar/todo
    static func directory(for config: TodoConfig = ConfigStore.shared.config.todo) -> URL {
        let raw = config.dir.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return PopBarConfig.directoryURL.appendingPathComponent("todo") }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    private var directory: URL { Self.directory() }
    private func fileURL(_ day: String) -> URL { directory.appendingPathComponent("\(day).md") }

    // MARK: - 加载 / 顺延

    /// 跨天时切到新的一天;重读磁盘;今天的文件还不存在时把前几天没做完的顺延进来
    func reload() {
        day = TodoMarkdown.dayKey()
        let fm = FileManager.default
        let today = fileURL(day)
        if fm.fileExists(atPath: today.path) {
            apply(read(today))
        } else if ConfigStore.shared.config.todo.carryOver {
            carryOverIntoToday()
        } else {
            apply(TodoDoc())
        }
        reloadHistory()
    }

    /// 扫描往日 YYYY-MM-DD.md（最多 90 天，按日期倒序），汇总历史已完成与已删除
    func reloadHistory(limitDays: Int = 90) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { TodoMarkdown.isDayFile($0) && String($0.dropLast(3)) < day }
            .sorted(by: >)
            .prefix(limitDays)

        var doneGroups: [TodoDayGroup] = []
        var deletedGroups: [TodoDayGroup] = []
        for name in names {
            let dayStr = String(name.dropLast(3))
            let doc = read(directory.appendingPathComponent(name))
            let doneItems = doc.items.filter { $0.done }
            if !doneItems.isEmpty {
                doneGroups.append(TodoDayGroup(day: dayStr, items: doneItems))
            }
            if !doc.deleted.isEmpty {
                deletedGroups.append(TodoDayGroup(day: dayStr, items: doc.deleted))
            }
        }
        pastDoneGroups = doneGroups
        pastDeletedGroups = deletedGroups
    }

    private func read(_ url: URL) -> TodoDoc {
        TodoMarkdown.parse((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    private func apply(_ doc: TodoDoc) {
        // 保留已有条目的 id,避免 SwiftUI 列表整体重建丢失编辑状态
        var pool = items
        items = doc.items.map { new in
            if let i = pool.firstIndex(where: { $0.text == new.text }) {
                var kept = pool.remove(at: i)
                kept.done = new.done
                kept.source = new.source
                kept.rid = new.rid
                return kept
            }
            return new
        }
        var delPool = deleted
        deleted = doc.deleted.map { new in
            if let i = delPool.firstIndex(where: { $0.text == new.text && $0.source == new.source }) {
                return delPool.remove(at: i)
            }
            return new
        }
        extras = doc.extras
    }

    private func carryOverIntoToday() {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { TodoMarkdown.isDayFile($0) && String($0.dropLast(3)) < day }
            .sorted()
            .suffix(30)       // 最多回看 30 天
        var carried: [TodoItem] = []
        var rewrites: [(URL, String)] = []
        for n in names {
            let url = directory.appendingPathComponent(n)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let r = TodoMarkdown.carry(from: text)
            if !r.carried.isEmpty { carried += r.carried; rewrites.append((url, r.rewritten)) }
        }
        apply(TodoDoc(items: carried, extras: []))
        guard !carried.isEmpty else { return }
        // 先写今天,成功后再改旧文件,中途失败也不会丢任务
        if save() { for (url, text) in rewrites { try? text.write(to: url, atomically: true, encoding: .utf8) } }
    }

    // MARK: - 修改

    func add(_ text: String, source: String? = nil) {
        let t = TodoMarkdown.oneLine(text)
        guard !t.isEmpty else { return }
        reload()      // 先对齐磁盘与日期,再追加
        items.append(TodoItem(text: String(t.prefix(300)), source: source))
        save()
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle()
        save()
    }

    func rename(_ id: UUID, to text: String) {
        let t = TodoMarkdown.oneLine(text)
        guard let i = items.firstIndex(where: { $0.id == id }), !t.isEmpty else { return }
        items[i].text = t
        save()
    }

    /// 软删除：移入当日已删除列表（`- [-]`），同步通知提醒事项删除未完成提醒
    @discardableResult
    func remove(_ id: UUID) -> TodoItem? {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        var removed = items.remove(at: idx)
        if let rid = removed.rid { RemindersSync.noteDeleted(rid) }
        removed.done = false
        removed.rid = nil
        deleted.insert(removed, at: 0)
        save()
        return removed
    }

    /// 清空今日已完成：移入当日已删除列表，避免误清空找不回
    func clearDone() {
        let finished = items.filter { $0.done }
        guard !finished.isEmpty else { return }
        let trashed = finished.map { TodoItem(id: $0.id, text: $0.text, done: false, source: $0.source, rid: nil) }
        deleted.insert(contentsOf: trashed, at: 0)
        items.removeAll { $0.done }
        save()
    }

    // MARK: - 历史已完成 / 已删除管理

    /// 把某条已完成项重新打开为待办（今天直接取消勾选；往日则从旧文件移出并恢复到今日待办）
    func reopenDone(_ item: TodoItem, day targetDay: String) {
        if targetDay == day {
            toggle(item.id)
            return
        }
        guard mutatePastDay(targetDay, { doc in
            guard let i = doc.items.firstIndex(where: { $0.done && $0.text == item.text && $0.source == item.source }) else {
                return false
            }
            doc.items.remove(at: i)
            return true
        }) else { return }
        reload()
        items.append(TodoItem(text: item.text, done: false, source: item.source))
        save()
        reloadHistory()
    }

    /// 把某条已完成项移入已删除（今天直接软删除；往日则在旧文件里移至 `- [-]`）
    func deleteDone(_ item: TodoItem, day targetDay: String) {
        if targetDay == day {
            remove(item.id)
            return
        }
        guard mutatePastDay(targetDay, { doc in
            guard let i = doc.items.firstIndex(where: { $0.done && $0.text == item.text && $0.source == item.source }) else {
                return false
            }
            let removed = doc.items.remove(at: i)
            doc.deleted.insert(TodoItem(text: removed.text, done: false, source: removed.source, rid: nil), at: 0)
            return true
        }) else { return }
        reloadHistory()
    }

    /// 从「已删除」恢复到今日待办（支持指定恢复为已完成，用于撤销删除已完成项）
    func restoreDeleted(_ item: TodoItem, day targetDay: String, asDone: Bool = false) {
        if targetDay == day {
            if let i = deleted.firstIndex(where: { $0.id == item.id })
                ?? deleted.firstIndex(where: { $0.text == item.text && $0.source == item.source }) {
                let kept = deleted.remove(at: i)
                items.append(TodoItem(id: kept.id, text: kept.text, done: asDone, source: kept.source))
                save()
            }
            return
        }
        guard mutatePastDay(targetDay, { doc in
            guard let i = doc.deleted.firstIndex(where: { $0.text == item.text && $0.source == item.source }) else {
                return false
            }
            doc.deleted.remove(at: i)
            return true
        }) else { return }
        reload()
        items.append(TodoItem(text: item.text, done: asDone, source: item.source))
        save()
        reloadHistory()
    }

    /// 彻底删除回收站里的某一条（不可恢复）
    func purgeDeleted(_ item: TodoItem, day targetDay: String) {
        if targetDay == day {
            if let i = deleted.firstIndex(where: { $0.id == item.id })
                ?? deleted.firstIndex(where: { $0.text == item.text && $0.source == item.source }) {
                deleted.remove(at: i)
                save()
            }
            return
        }
        guard mutatePastDay(targetDay, { doc in
            guard let i = doc.deleted.firstIndex(where: { $0.text == item.text && $0.source == item.source }) else {
                return false
            }
            doc.deleted.remove(at: i)
            return true
        }) else { return }
        reloadHistory()
    }

    /// 清空全部已删除记录（包括今日与往日文件里的 `- [-]`）
    func emptyTrash() {
        if !deleted.isEmpty {
            deleted.removeAll()
            save()
        }
        let pastDays = pastDeletedGroups.map { $0.day }
        for d in pastDays {
            _ = mutatePastDay(d) { doc in
                guard !doc.deleted.isEmpty else { return false }
                doc.deleted.removeAll()
                return true
            }
        }
        reloadHistory()
    }

    /// 修改某个往日 Markdown 文件并原子写回
    private func mutatePastDay(_ targetDay: String, _ edit: (inout TodoDoc) -> Bool) -> Bool {
        let url = fileURL(targetDay)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var doc = read(url)
        guard edit(&doc) else { return false }
        let text = TodoMarkdown.render(day: targetDay, doc: doc)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("PopBar todo past-day save failed (\(targetDay)): \(error)")
            return false
        }
    }

    /// 拖拽排序只发生在「未完成」区;已完成保持在后
    func moveUndone(from: IndexSet, to: Int) {
        var u = undone
        u.move(fromOffsets: from, toOffset: to)
        items = u + done
        save()
    }

    /// 同步层回写(导入 / 拉取 / 关联 rid):静默落盘,不再触发新一轮同步
    func syncUpdate(_ newItems: [TodoItem]) {
        items = newItems
        save(notify: false)
    }

    @discardableResult
    private func save(notify: Bool = true) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let text = TodoMarkdown.render(day: day, doc: TodoDoc(items: items, deleted: deleted, extras: extras))
            try text.write(to: fileURL(day), atomically: true, encoding: .utf8)
        } catch {
            NSLog("PopBar todo save failed: \(error)")
            return false
        }
        if notify { NotificationCenter.default.post(name: Self.changed, object: nil) }
        return true
    }
}

// MARK: - 番茄钟

/// 番茄钟:基于结束时间戳计时(休眠 / 卡顿不漂移),只在运行时才有 1s Timer,空闲 CPU ≈ 0。
@MainActor
final class Pomodoro: ObservableObject {
    static let shared = Pomodoro()
    static let ticked = Notification.Name("PopBarPomodoroTicked")

    enum Phase { case focus, rest }

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var running = false
    @Published private(set) var remaining: Int
    @Published private(set) var todayCount: Int = 0

    private var endDate: Date?
    private var timer: Timer?
    private static let countsKey = "PopBarPomodoroCounts"

    private init() {
        remaining = ConfigStore.shared.config.todo.focusMinutes * 60
        todayCount = Self.counts()[TodoMarkdown.dayKey()] ?? 0
    }

    /// 本阶段的总秒数
    var total: Int {
        let c = ConfigStore.shared.config.todo
        return (phase == .focus ? c.focusMinutes : c.breakMinutes) * 60
    }

    /// 已开始(运行中或暂停中)
    var started: Bool { running || remaining != total }

    var progress: Double { total == 0 ? 0 : 1 - Double(remaining) / Double(total) }

    func start() {
        guard !running else { return }
        if remaining <= 0 { remaining = total }
        endDate = Date().addingTimeInterval(TimeInterval(remaining))
        running = true
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        post()
    }

    func pause() {
        guard running else { return }
        stopTimer()
        post()
    }

    func toggle() { running ? pause() : start() }

    /// 放弃当前阶段,回到本阶段的满时长
    func reset() {
        stopTimer()
        remaining = total
        post()
    }

    /// 跳到另一个阶段(专注 ↔ 休息),不计入完成数
    func switchPhase() {
        stopTimer()
        phase = phase == .focus ? .rest : .focus
        remaining = total
        post()
    }

    /// 配置里改了时长:没开始计时就同步显示
    func applyConfig() {
        if !started { remaining = total }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        endDate = nil
        running = false
    }

    private func tick() {
        guard let end = endDate else { return }
        remaining = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        if remaining == 0 { finish() } else { post() }
    }

    private func finish() {
        stopTimer()
        let finishedFocus = phase == .focus
        if finishedFocus { CalendarLog.logFocus(minutes: total / 60, endedAt: Date()) }
        if finishedFocus {
            var m = Self.counts()
            let key = TodoMarkdown.dayKey()
            m[key, default: 0] += 1
            // 只留最近一年
            if m.count > 400 { for k in m.keys.sorted().dropLast(366) { m[k] = nil } }
            UserDefaults.standard.set(m, forKey: Self.countsKey)
            todayCount = m[key] ?? 0
        }
        phase = finishedFocus ? .rest : .focus
        remaining = total
        post()
        NSSound(named: "Glass")?.play()
        if ConfigStore.shared.config.todo.notify { notifyFinished(focus: finishedFocus) }
    }

    private func notifyFinished(focus: Bool) {
        let c = ConfigStore.shared.config.todo
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = focus ? L10n.t("专注结束", "Focus complete")
                              : L10n.t("休息结束", "Break is over")
        content.body = focus ? L10n.t("休息 \(c.breakMinutes) 分钟，今天已专注 \(todayCount) 轮",
                                      "Take \(c.breakMinutes) min off — \(todayCount) rounds today")
                             : L10n.t("准备好开始下一轮专注了吗？", "Ready for the next focus round?")
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func post() { NotificationCenter.default.post(name: Self.ticked, object: nil) }

    private static func counts() -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int]) ?? [:]
    }
}
