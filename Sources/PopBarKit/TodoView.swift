import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 菜单栏「今日待办」:番茄钟 + 今日待办 / 已完成历史 / 已删除回收站。
/// 外壳是 Deck 的今日页或钉住小窗;样式与系统监控 / 维护面板一致。
struct TodoView: View {
    enum Tab: Hashable { case todo, done, deleted }

    private struct UndoNotice: Identifiable {
        let id = UUID()
        let message: String
        let actionLabel: String
        let action: () -> Void
    }

    @ObservedObject var store: TodoStore
    @ObservedObject var pomo: Pomodoro
    @State private var tab: Tab = .todo
    @State private var draft = ""
    @State private var query = ""
    @State private var editing: UUID?
    @State private var showTodayDone = false
    @State private var confirmEmptyTrash = false
    @State private var confirmResetTask: DispatchWorkItem?
    @State private var undoNotice: UndoNotice?
    @State private var undoDismissTask: DispatchWorkItem?
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            pomodoroCard
            tabBar
            tabBody
        }
        .overlay(alignment: .bottom) {
            if let notice = undoNotice {
                undoBanner(notice)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: undoNotice?.id)
        .onAppear {
            store.reloadHistory()
            // 面板刚显示、窗口成为 key 之后再抢输入焦点
            if tab == .todo {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { addFocused = true }
            }
        }
        .onChange(of: tab) { _, next in
            query = ""
            resetConfirmTrash()
            if next == .todo {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { addFocused = true }
            } else {
                store.reloadHistory()
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Self.dateText)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(headerSummary)
                .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var headerSummary: String {
        if store.done.isEmpty {
            return L10n.t("\(store.undoneCount) 项待办", "\(store.undoneCount) to do")
        }
        return L10n.t("\(store.undoneCount) 项待办 · 今日已完成 \(store.done.count)",
                      "\(store.undoneCount) to do · \(store.done.count) done today")
    }

    private static var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.isEnglish ? "en_US" : "zh_CN")
        f.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return f.string(from: Date())
    }

    // MARK: - 番茄钟

    private var pomodoroCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(SysTheme.track, lineWidth: 5)
                Circle().trim(from: 0, to: pomo.progress)
                    .stroke(pomo.phase == .focus ? PanelTheme.brandColor : SysTheme.mem,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: pomo.progress)
                Text(PomodoroMath.format(pomo.remaining))
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .frame(width: 78, height: 78)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(pomo.phase == .focus ? L10n.t("专注", "Focus") : L10n.t("休息", "Break"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(L10n.t("今天 \(pomo.todayCount) 轮", "\(pomo.todayCount) today"))
                        .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                }
                HStack(spacing: 8) {
                    pill(pomo.running ? L10n.t("暂停", "Pause") : (pomo.started ? L10n.t("继续", "Resume") : L10n.t("开始", "Start")),
                         symbol: pomo.running ? "pause.fill" : "play.fill", prominent: true) { pomo.toggle() }
                    pill(L10n.t("重置", "Reset"), symbol: "arrow.counterclockwise") { pomo.reset() }
                        .disabled(!pomo.started)
                    pill(pomo.phase == .focus ? L10n.t("去休息", "Break") : L10n.t("去专注", "Focus"),
                         symbol: "forward.end.fill") { pomo.switchPhase() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(CardBackground())
    }

    private func pill(_ title: String, symbol: String, prominent: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(Capsule().fill(prominent ? PanelTheme.brandColor : SysTheme.track))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 视图切换栏

    private var tabBar: some View {
        HStack(spacing: 8) {
            DSSegmented(selection: $tab, options: [
                (.todo, tabLabel(L10n.t("待办", "To-Do"), count: store.undoneCount)),
                (.done, tabLabel(L10n.t("已完成", "Done"), count: store.allDoneCount)),
                (.deleted, tabLabel(L10n.t("已删除", "Deleted"), count: store.allDeletedCount)),
            ])
            Spacer(minLength: 0)
        }
    }

    private func tabLabel(_ title: String, count: Int) -> String {
        count > 0 ? "\(title) \(count)" : title
    }

    // MARK: - 主内容区

    @ViewBuilder
    private var tabBody: some View {
        switch tab {
        case .todo:
            addField
            todoList
        case .done:
            historyDoneView
        case .deleted:
            deletedTrashView
        }
    }

    // MARK: - 添加

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(PanelTheme.brandColor)
            TextField(L10n.t("添加一件今天要做的事，回车确认", "Add something for today, press Return"), text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($addFocused)
                .onSubmit {
                    store.add(draft)
                    draft = ""
                    addFocused = true
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(CardBackground())
    }

    // MARK: - 「待办」列表 + 底部可折叠「今日已完成」

    @ViewBuilder
    private var todoList: some View {
        if store.undone.isEmpty && store.done.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 26)).foregroundStyle(SysTheme.tertiary)
                Text(L10n.t("今天还没有待办", "Nothing planned yet"))
                    .font(.system(size: 12)).foregroundStyle(SysTheme.secondary)
                Text(L10n.t("选中文字，点工具条上的「加入待办」也行", "Or select text anywhere and tap “Add to To-Do” on the bar"))
                    .font(.system(size: 11)).foregroundStyle(SysTheme.tertiary)
                    .multilineTextAlignment(.center)
                if store.allDoneCount > 0 {
                    Button { tab = .done } label: {
                        Text(L10n.t("查看 \(store.allDoneCount) 条已完成历史", "View \(store.allDoneCount) completed items"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DS.accent)
                            .padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let todayDoneExpanded = store.undone.isEmpty || showTodayDone
            List {
                if store.undone.isEmpty {
                    HStack(spacing: 8) {
                        Icon("circle-check", size: 15, color: DS.success)
                        Text(L10n.t("今天的待办已全部完成", "All caught up for today"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DS.text2)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.successSoft))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
                } else {
                    ForEach(store.undone) { row($0) }
                        .onMove { store.moveUndone(from: $0, to: $1) }
                }

                if !store.done.isEmpty {
                    todayDoneHeader(expanded: todayDoneExpanded)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 2, trailing: 0))
                    if todayDoneExpanded {
                        ForEach(store.done) { row($0) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func todayDoneHeader(expanded: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { showTodayDone.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Icon(expanded ? "chevron-down" : "chevron-right", size: 12, color: DS.muted)
                    Text(L10n.t("今日已完成 \(store.done.count)", "Completed today \(store.done.count)"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DS.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button { tab = .done } label: {
                Text(L10n.t("全部历史", "History"))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.accent)
            }
            .buttonStyle(.plain)

            Text("·").font(.system(size: 11)).foregroundStyle(DS.faint)

            Button {
                let count = store.done.count
                store.clearDone()
                showUndo(L10n.t("已将 \(count) 条移至「已删除」", "Moved \(count) items to Deleted"),
                         actionLabel: L10n.t("查看", "View")) {
                    tab = .deleted
                }
            } label: {
                Text(L10n.t("清空", "Clear"))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.surface2.opacity(0.75)))
    }

    private func row(_ item: TodoItem) -> some View {
        TodoRow(
            item: item,
            store: store,
            editing: $editing,
            onToggle: { handleToggle(item) },
            onDelete: { handleDelete(item) }
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
    }

    // MARK: - 「已完成」跨天历史视图

    @ViewBuilder
    private var historyDoneView: some View {
        let allGroups = store.allDoneGroups
        let filtered = TodoMarkdown.filterGroups(allGroups, query: query)

        DSSearchField(L10n.t("搜索已完成的历史…", "Search completed…"), text: $query)

        if allGroups.isEmpty {
            historyEmpty(
                icon: "circle-check",
                title: L10n.t("还没有已完成的待办", "No completed items yet"),
                subtitle: L10n.t("勾选待办后会按日期归档在这里", "Checked items are archived here by day")
            )
        } else if filtered.isEmpty {
            searchEmpty
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filtered) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            daySectionHeader(group.day, count: group.items.count)
                            ForEach(group.items) { item in
                                DoneHistoryRow(
                                    item: item,
                                    onReopen: {
                                        store.reopenDone(item, day: group.day)
                                        showUndo(L10n.t("已恢复到今日待办", "Restored to today’s to-dos"),
                                                 actionLabel: L10n.t("查看", "View")) {
                                            tab = .todo
                                        }
                                    },
                                    onDelete: {
                                        let targetDay = group.day
                                        store.deleteDone(item, day: targetDay)
                                        showUndo(L10n.t("已移至「已删除」", "Moved to Deleted")) {
                                            store.restoreDeleted(item, day: targetDay, asDone: true)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 「已删除」回收站视图

    @ViewBuilder
    private var deletedTrashView: some View {
        let allGroups = store.allDeletedGroups
        let filtered = TodoMarkdown.filterGroups(allGroups, query: query)

        HStack(spacing: 8) {
            DSSearchField(L10n.t("搜索已删除的待办…", "Search deleted…"), text: $query)
            if !allGroups.isEmpty {
                Button {
                    if confirmEmptyTrash {
                        resetConfirmTrash()
                        store.emptyTrash()
                    } else {
                        armConfirmTrash()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Icon("trash-2", size: 12, color: confirmEmptyTrash ? DS.onAccent : DS.danger)
                        Text(confirmEmptyTrash ? L10n.t("确认清空？", "Confirm?") : L10n.t("清空", "Empty"))
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(confirmEmptyTrash ? DS.onAccent : DS.danger)
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                            .fill(confirmEmptyTrash ? DS.danger : DS.dangerSoft)
                    )
                }
                .buttonStyle(DSPressStyle())
                .fixedSize()
            }
        }

        if allGroups.isEmpty {
            historyEmpty(
                icon: "trash-2",
                title: L10n.t("没有已删除的待办", "Trash is empty"),
                subtitle: L10n.t("删除的待办会暂存在这里，随时可以恢复", "Deleted items stay here so you can restore them anytime")
            )
        } else if filtered.isEmpty {
            searchEmpty
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filtered) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            daySectionHeader(group.day, count: group.items.count)
                            ForEach(group.items) { item in
                                DeletedHistoryRow(
                                    item: item,
                                    onRestore: {
                                        store.restoreDeleted(item, day: group.day)
                                        showUndo(L10n.t("已恢复到今日待办", "Restored to today’s to-dos"),
                                                 actionLabel: L10n.t("查看", "View")) {
                                            tab = .todo
                                        }
                                    },
                                    onPurge: {
                                        store.purgeDeleted(item, day: group.day)
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func daySectionHeader(_ day: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(TodoMarkdown.dayDisplayTitle(day, today: store.day))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(DS.muted)
            Spacer()
            Text(L10n.t("\(count) 项", "\(count)"))
                .font(.system(size: 10.5))
                .foregroundStyle(DS.faint)
        }
        .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 2)
    }

    private func historyEmpty(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Icon(icon, size: 22, color: DS.faint)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.surface2))
                .padding(.bottom, 2)
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.text2)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(DS.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchEmpty: some View {
        VStack(spacing: 6) {
            Icon("search", size: 20, color: DS.faint)
            Text(L10n.t("没有找到匹配的记录", "No matching items"))
                .font(.system(size: 12)).foregroundStyle(DS.muted)
            Button { query = "" } label: {
                Text(L10n.t("清空搜索", "Clear search"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 交互辅助（撤销提示 / 二次确认）

    private func handleToggle(_ item: TodoItem) {
        let wasDone = item.done
        store.toggle(item.id)
        if !wasDone {
            showUndo(L10n.t("已完成，可在「已完成」查看", "Marked done — view in Done")) {
                store.toggle(item.id)
            }
        }
    }

    private func handleDelete(_ item: TodoItem) {
        let wasDone = item.done
        let targetDay = store.day
        guard let trashed = store.remove(item.id) else { return }
        showUndo(L10n.t("已移至「已删除」", "Moved to Deleted")) {
            store.restoreDeleted(trashed, day: targetDay, asDone: wasDone)
        }
    }

    private func showUndo(_ message: String, actionLabel: String = L10n.t("撤销", "Undo"), action: @escaping () -> Void) {
        undoDismissTask?.cancel()
        undoNotice = UndoNotice(message: message, actionLabel: actionLabel, action: action)
        let work = DispatchWorkItem { undoNotice = nil }
        undoDismissTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6, execute: work)
    }

    private func undoBanner(_ notice: UndoNotice) -> some View {
        HStack(spacing: 10) {
            Text(notice.message)
                .font(.system(size: 11.5))
                .foregroundStyle(DS.text)
                .lineLimit(1)
            Button {
                undoDismissTask?.cancel()
                undoNotice = nil
                notice.action()
            } label: {
                Text(notice.actionLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DS.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(
            Capsule()
                .fill(DS.surface)
                .shadow(color: DS.shadow.opacity(0.45), radius: 8, y: 3)
        )
        .overlay(Capsule().strokeBorder(DS.borderStrong, lineWidth: 1))
    }

    private func armConfirmTrash() {
        confirmResetTask?.cancel()
        confirmEmptyTrash = true
        let work = DispatchWorkItem { confirmEmptyTrash = false }
        confirmResetTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func resetConfirmTrash() {
        confirmResetTask?.cancel()
        confirmResetTask = nil
        confirmEmptyTrash = false
    }
}

// MARK: - 行组件

private struct TodoRow: View {
    let item: TodoItem
    @ObservedObject var store: TodoStore
    @Binding var editing: UUID?
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var text = ""
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(item.done ? PanelTheme.brandColor : SysTheme.tertiary)
            }
            .buttonStyle(.plain)

            if editing == item.id {
                TextField("", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit { commit() }
                    .onAppear { text = item.text }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.text)
                        .font(.system(size: 13))
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? SysTheme.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let s = item.source {
                        Text(L10n.t("来自 \(s)", "from \(s)"))
                            .font(.system(size: 10)).foregroundStyle(SysTheme.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editing = item.id }
            }

            Button(action: onDelete) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SysTheme.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0)
            .help(L10n.t("移至已删除", "Move to Deleted"))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hover ? SysTheme.track : Color.clear))
        .onHover { hover = $0 }
        .contextMenu {
            Button(L10n.t("编辑", "Edit")) { editing = item.id }
            Button(L10n.t("复制", "Copy")) { PasteboardGuard.write(item.text) }
            Divider()
            Button(L10n.t("删除", "Delete"), role: .destructive, action: onDelete)
        }
    }

    private func commit() {
        store.rename(item.id, to: text)
        editing = nil
    }
}

private struct DoneHistoryRow: View {
    let item: TodoItem
    let onReopen: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onReopen) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(PanelTheme.brandColor.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help(L10n.t("恢复到待办", "Restore to To-Do"))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.system(size: 13))
                    .strikethrough(true)
                    .foregroundStyle(SysTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let s = item.source {
                    Text(L10n.t("来自 \(s)", "from \(s)"))
                        .font(.system(size: 10)).foregroundStyle(SysTheme.tertiary)
                }
            }

            HStack(spacing: 6) {
                Button(action: onReopen) {
                    Icon("rotate-ccw", size: 13, color: DS.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("恢复到待办", "Restore to To-Do"))

                Button(action: onDelete) {
                    Icon("trash-2", size: 13, color: DS.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("移至已删除", "Move to Deleted"))
            }
            .opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hover ? SysTheme.track : Color.clear))
        .onHover { hover = $0 }
        .contextMenu {
            Button(L10n.t("恢复到待办", "Restore to To-Do"), action: onReopen)
            Button(L10n.t("复制", "Copy")) { PasteboardGuard.write(item.text) }
            Divider()
            Button(L10n.t("移至已删除", "Move to Deleted"), role: .destructive, action: onDelete)
        }
    }
}

private struct DeletedHistoryRow: View {
    let item: TodoItem
    let onRestore: () -> Void
    let onPurge: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Icon("trash-2", size: 13, color: DS.faint)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.system(size: 13))
                    .strikethrough(true)
                    .foregroundStyle(DS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let s = item.source {
                    Text(L10n.t("来自 \(s)", "from \(s)"))
                        .font(.system(size: 10)).foregroundStyle(SysTheme.tertiary)
                }
            }

            HStack(spacing: 6) {
                Button(action: onRestore) {
                    Icon("rotate-ccw", size: 13, color: DS.accent)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("恢复到今日待办", "Restore to today"))

                Button(action: onPurge) {
                    Icon("x", size: 13, color: DS.danger)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("彻底删除", "Delete permanently"))
            }
            .opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hover ? SysTheme.track : Color.clear))
        .onHover { hover = $0 }
        .contextMenu {
            Button(L10n.t("恢复到今日待办", "Restore to today"), action: onRestore)
            Button(L10n.t("复制", "Copy")) { PasteboardGuard.write(item.text) }
            Divider()
            Button(L10n.t("彻底删除", "Delete permanently"), role: .destructive, action: onPurge)
        }
    }
}
