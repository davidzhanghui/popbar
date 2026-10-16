import Cocoa
import EventKit

/// 与系统「提醒事项」「日历」的桥:共用一个 EKEventStore,各自在「PopBar」列表 / 日历里读写。
@MainActor
enum SystemStore {
    static let store = EKEventStore()

    static func hasAccess(_ type: EKEntityType) -> Bool {
        EKEventStore.authorizationStatus(for: type) == .fullAccess
    }

    /// 首次会弹系统授权框;PopBar 是 accessory 应用,先激活才不会被盖住
    static func requestAccess(_ type: EKEntityType) async -> Bool {
        if hasAccess(type) { return true }
        NSApp.activateForUI()
        do {
            return type == .reminder ? try await store.requestFullAccessToReminders()
                                      : try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    /// 「PopBar」列表 / 日历;不存在就建在默认账户(优先 iCloud)下
    static func popbarCalendar(_ type: EKEntityType) -> EKCalendar? {
        let name = "PopBar"
        if let c = store.calendars(for: type).first(where: { $0.title == name && $0.allowsContentModifications }) {
            return c
        }
        let c = EKCalendar(for: type, eventStore: store)
        c.title = name
        let fallback = type == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        guard let source = fallback?.source
                ?? store.sources.first(where: { $0.sourceType == .local })
                ?? store.sources.first else { return nil }
        c.source = source
        do { try store.saveCalendar(c, commit: true) } catch {
            NSLog("PopBar: 创建「PopBar」日历失败: \(error)")
            return nil
        }
        return c
    }

    /// 授权被拒时引导去系统设置
    static func showDenied(_ type: EKEntityType) {
        let reminders = type == .reminder
        let a = NSAlert()
        a.messageText = reminders ? L10n.t("没有「提醒事项」权限", "Reminders access denied")
                                  : L10n.t("没有「日历」权限", "Calendar access denied")
        a.informativeText = reminders
            ? L10n.t("请在 系统设置 → 隐私与安全性 → 提醒事项 中允许 PopBar,然后重新打开这个开关。",
                     "Allow PopBar in System Settings → Privacy & Security → Reminders, then turn this on again.")
            : L10n.t("请在 系统设置 → 隐私与安全性 → 日历 中允许 PopBar,然后重新打开这个开关。",
                     "Allow PopBar in System Settings → Privacy & Security → Calendars, then turn this on again.")
        a.addButton(withTitle: L10n.t("打开设置", "Open Settings"))
        a.addButton(withTitle: L10n.t("取消", "Cancel"))
        NSApp.activateForUI()
        if a.runModal() == .alertFirstButtonReturn,
           let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(reminders ? "Reminders" : "Calendars")") {
            NSWorkspace.shared.open(u)
        }
    }
}

/// 今日待办 ⇄ 提醒事项「PopBar」列表的双向同步。
/// 对账规则在 ReminderSync.plan(纯逻辑,有单测);这里只负责取快照、执行动作、落盘。
@MainActor
final class RemindersSync {
    static let shared = RemindersSync()

    private var running = false
    private var again = false
    private var debounce: DispatchWorkItem?
    private static let stateKey = "PopBarReminderState"
    private static let deletedKey = "PopBarReminderDeleted"

    /// 启动时调用:只挂观察者,没开同步时什么都不做
    func start() {
        NotificationCenter.default.addObserver(forName: TodoStore.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RemindersSync.shared.syncSoon() }
        }
        // 开关打开 / 配置文件被外部改动时也对一次账
        NotificationCenter.default.addObserver(forName: ConfigStore.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RemindersSync.shared.syncSoon() }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: SystemStore.store, queue: .main) { _ in
            MainActor.assumeIsolated { RemindersSync.shared.syncSoon() }
        }
        syncSoon()
    }

    var enabled: Bool { ConfigStore.shared.config.todo.syncReminders && SystemStore.hasAccess(.reminder) }

    func syncSoon() {
        guard enabled else { return }
        debounce?.cancel()
        let w = DispatchWorkItem { Task { @MainActor in await RemindersSync.shared.sync() } }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// 本地删除一条已关联的待办:记下,下次同步时删掉对应的未完成提醒
    static func noteDeleted(_ rid: String) {
        guard ConfigStore.shared.config.todo.syncReminders else { return }
        var d = Set(UserDefaults.standard.stringArray(forKey: deletedKey) ?? [])
        d.insert(rid)
        UserDefaults.standard.set(Array(d), forKey: deletedKey)
    }

    private func loadState() -> [String: ReminderMark] {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let s = try? JSONDecoder().decode([String: ReminderMark].self, from: data) else { return [:] }
        return s
    }

    private func saveState(_ s: [String: ReminderMark]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: Self.stateKey)
    }

    func sync() async {
        guard enabled else { return }
        if running { again = true; return }
        running = true
        defer {
            running = false
            if again { again = false; syncSoon() }
        }
        let store = SystemStore.store
        guard let cal = SystemStore.popbarCalendar(.reminder) else { return }

        // 1) 取提醒事项快照(异步),此后到落盘之间不再有 await,本地状态不会被插队修改
        let snaps: [ReminderSnap] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: store.predicateForReminders(in: [cal])) { list in
                cont.resume(returning: (list ?? []).map {
                    ReminderSnap(id: $0.calendarItemIdentifier, title: $0.title ?? "", done: $0.isCompleted)
                })
            }
        }

        // 2) 对齐磁盘 / 日期,再对账
        TodoStore.shared.reload()
        let deleted = Set(UserDefaults.standard.stringArray(forKey: Self.deletedKey) ?? [])
        let plan = ReminderSync.plan(items: TodoStore.shared.items, remote: snaps,
                                     state: loadState(), deleted: deleted)

        // 3) 执行到提醒事项;任何一步失败整体放弃,下次重来
        var items = plan.items
        var state = plan.state
        do {
            for u in plan.updates {
                guard let r = store.calendarItem(withIdentifier: u.rid) as? EKReminder else { continue }
                r.title = u.title
                r.isCompleted = u.done
                try store.save(r, commit: false)
            }
            for rid in plan.deletes {
                if let r = store.calendarItem(withIdentifier: rid) as? EKReminder { try store.remove(r, commit: false) }
            }
            for id in plan.creates {
                guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
                let r = EKReminder(eventStore: store)
                r.calendar = cal
                r.title = items[i].text
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                try store.save(r, commit: false)
                items[i].rid = r.calendarItemIdentifier
                state[r.calendarItemIdentifier] = ReminderMark(title: items[i].text, done: false)
            }
            if !plan.updates.isEmpty || !plan.deletes.isEmpty || !plan.creates.isEmpty { try store.commit() }
        } catch {
            NSLog("PopBar: 提醒事项同步失败: \(error)")
            store.reset()
            return
        }

        // 4) 回写本地
        if plan.changedLocal || !plan.creates.isEmpty { TodoStore.shared.syncUpdate(items) }
        saveState(state)
        UserDefaults.standard.removeObject(forKey: Self.deletedKey)
    }

    /// 关闭同步时清掉记录,下次重新开启按全新状态对账(不会删掉任何一边的内容)
    func reset() {
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
        UserDefaults.standard.removeObject(forKey: Self.deletedKey)
    }
}

/// 番茄钟 → 系统日历:每完成一轮专注记一个事件
@MainActor
enum CalendarLog {
    static func logFocus(minutes: Int, endedAt end: Date) {
        guard ConfigStore.shared.config.todo.syncCalendar, SystemStore.hasAccess(.event),
              let cal = SystemStore.popbarCalendar(.event) else { return }
        let e = EKEvent(eventStore: SystemStore.store)
        e.calendar = cal
        e.title = L10n.t("🍅 专注 \(minutes) 分钟", "🍅 Focus \(minutes) min")
        e.startDate = end.addingTimeInterval(-TimeInterval(minutes * 60))
        e.endDate = end
        let open = TodoStore.shared.undone.prefix(5).map { "· \($0.text)" }
        if !open.isEmpty { e.notes = L10n.t("当时的待办:\n", "Open to-dos:\n") + open.joined(separator: "\n") }
        do { try SystemStore.store.save(e, span: .thisEvent, commit: true) } catch {
            NSLog("PopBar: 写入日历失败: \(error)")
        }
    }
}
