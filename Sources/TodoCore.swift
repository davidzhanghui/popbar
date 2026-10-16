import Foundation

/// 今日待办的纯逻辑层:Markdown 读写 + 顺延。不碰 UI / 磁盘,方便单测。
/// 文件格式(一天一个 YYYY-MM-DD.md,普通 Markdown,放进网盘手机也能看):
///
///     # 2026-10-16
///
///     - [ ] 写周报 <!--src:Safari--> <!--rid:ABC-123-->
///     - [x] 回邮件
///     - [>] 昨天没做完、已顺延到今天的事
struct TodoItem: Equatable, Identifiable {
    var id = UUID()
    var text: String
    var done = false
    /// 从哪个 App 划词加入的(可空)
    var source: String? = nil
    /// 对应的提醒事项 id(开启「同步到提醒事项」后才有)
    var rid: String? = nil
}

/// 解析结果:任务 + 无法识别的行(用户手写的备注、已顺延的 `[>]` 行),
/// 重写文件时原样放在任务之后,避免丢用户自己加的内容
struct TodoDoc: Equatable {
    var items: [TodoItem] = []
    var extras: [String] = []
}

enum TodoMarkdown {
    private static let srcSuffix = "-->"

    static func parse(_ text: String) -> TodoDoc {
        var doc = TodoDoc()
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("# ") && doc.items.isEmpty && doc.extras.isEmpty { continue }
            if let (done, body) = taskBody(trimmed) {
                let (rawText, tags) = splitTags(body)
                let t = rawText.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                doc.items.append(TodoItem(text: t, done: done, source: tags["src"], rid: tags["rid"]))
            } else {
                doc.extras.append(line)
            }
        }
        return doc
    }

    static func render(day: String, doc: TodoDoc) -> String {
        var out = "# \(day)\n\n"
        for it in doc.items {
            out += "- [\(it.done ? "x" : " ")] \(oneLine(it.text))"
            if let s = it.source, !s.isEmpty { out += " \(tag("src", s))" }
            if let r = it.rid, !r.isEmpty { out += " \(tag("rid", r))" }
            out += "\n"
        }
        if !doc.extras.isEmpty { out += "\n" + doc.extras.joined(separator: "\n") + "\n" }
        return out
    }

    /// 任务文本不能含换行(一行一条)
    static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func taskBody(_ line: String) -> (Bool, String)? {
        for (marker, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] where line.hasPrefix(marker) {
            return (done, String(line.dropFirst(marker.count)))
        }
        return nil
    }

    private static func tag(_ key: String, _ value: String) -> String {
        "<!--\(key):\(value.replacingOccurrences(of: "-->", with: ""))-->"
    }

    /// 剥掉行尾的 `<!--key:value-->` 标记(可有多个,顺序不限),返回正文与标记表
    private static func splitTags(_ body: String) -> (String, [String: String]) {
        var rest = body.trimmingCharacters(in: .whitespaces)
        var tags: [String: String] = [:]
        while rest.hasSuffix(srcSuffix), let r = rest.range(of: "<!--", options: .backwards) {
            let inner = rest[r.upperBound..<rest.index(rest.endIndex, offsetBy: -srcSuffix.count)]
            guard let colon = inner.firstIndex(of: ":") else { break }
            let key = String(inner[..<colon])
            guard key == "src" || key == "rid" else { break }
            let value = String(inner[inner.index(after: colon)...])
            if !value.isEmpty, tags[key] == nil { tags[key] = value }
            rest = String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (rest, tags)
    }

    /// 顺延:把旧文件里未完成的 `- [ ]` 取出,并在旧文件里改写为 `- [>]`(防止重复顺延)
    static func carry(from oldText: String) -> (carried: [TodoItem], rewritten: String) {
        let carried = parse(oldText).items.filter { !$0.done }
        guard !carried.isEmpty else { return ([], oldText) }
        let lines = oldText.components(separatedBy: "\n").map { line -> String in
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line.dropFirst(lead.count)
            return rest.hasPrefix("- [ ] ") ? lead + "- [>] " + rest.dropFirst(6) : line
        }
        return (carried, lines.joined(separator: "\n"))
    }

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func isDayFile(_ name: String) -> Bool {
        name.count == 13 && name.hasSuffix(".md") && name.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil
    }
}

/// 番茄钟的纯函数部分
enum PomodoroMath {
    /// 剩余秒数 → "25:00"
    static func format(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - 提醒事项同步的对账规则(纯逻辑)

/// 提醒事项里一条的快照
struct ReminderSnap: Equatable {
    var id: String
    var title: String
    var done: Bool
}

/// 上次同步成功时两边一致的状态;用来判断「这次是谁改了」
struct ReminderMark: Codable, Equatable {
    var title: String
    var done: Bool
}

struct ReminderUpdate: Equatable {
    var rid: String
    var title: String
    var done: Bool
}

struct ReminderPlan {
    /// 对账后的本地列表(顺序保持,新导入的追加在后)
    var items: [TodoItem] = []
    /// 需要在提醒事项里新建的本地条目
    var creates: [UUID] = []
    var updates: [ReminderUpdate] = []
    var deletes: [String] = []
    var state: [String: ReminderMark] = [:]
    /// 本地列表相对输入有变化(拉取了改动 / 导入 / 删除 / 清除失效的 rid)
    var changedLocal = false
}

enum ReminderSync {
    /// 两边都没变 → 无动作;只有一边改 → 以改的一边为准;两边都改 → 本地优先。
    /// - 提醒事项里被删了(曾同步过)→ 本地也删;没同步过的 rid(别的电脑写进文件的)→ 清掉重新建
    /// - 提醒事项里新增的未完成项 → 导入为本地待办
    /// - 本地删掉的(deleted)→ 删对应的未完成提醒;已完成的提醒保留
    static func plan(items: [TodoItem], remote: [ReminderSnap],
                     state: [String: ReminderMark], deleted: Set<String>) -> ReminderPlan {
        let byID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out = ReminderPlan(state: state)
        var localRids = Set<String>()

        for var it in items {
            guard let rid = it.rid else {
                if !it.done { out.creates.append(it.id) }
                out.items.append(it)
                continue
            }
            localRids.insert(rid)
            guard let r = byID[rid] else {
                out.changedLocal = true
                if state[rid] != nil {            // 在提醒事项里被删除
                    out.state[rid] = nil
                    continue
                }
                it.rid = nil                       // 陌生 rid:重新建
                if !it.done { out.creates.append(it.id) }
                out.items.append(it)
                continue
            }
            var title = it.text
            var done = it.done
            if let last = state[rid] {
                if it.text == last.title, r.title != last.title { title = r.title }
                if it.done == last.done, r.done != last.done { done = r.done }
            }
            if title != it.text || done != it.done {
                it.text = title
                it.done = done
                out.changedLocal = true
            }
            if title != r.title || done != r.done {
                out.updates.append(ReminderUpdate(rid: rid, title: title, done: done))
            }
            out.state[rid] = ReminderMark(title: title, done: done)
            out.items.append(it)
        }

        for r in remote where !r.done && !localRids.contains(r.id) && state[r.id] == nil && !deleted.contains(r.id) {
            let t = TodoMarkdown.oneLine(r.title)
            guard !t.isEmpty else { continue }
            out.items.append(TodoItem(text: t, rid: r.id))
            out.state[r.id] = ReminderMark(title: t, done: false)
            out.changedLocal = true
        }

        for rid in deleted {
            if let r = byID[rid], !r.done { out.deletes.append(rid) }
            out.state[rid] = nil
        }
        return out
    }
}
