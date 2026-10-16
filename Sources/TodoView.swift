import SwiftUI

/// 菜单栏「今日待办」:番茄钟 + 今天的待办清单。
/// 外壳是 ToolPanel(可钉住);样式与系统监控 / 维护面板一致。
struct TodoView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var pomo: Pomodoro
    @State private var draft = ""
    @State private var editing: UUID?
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            pomodoroCard
            addField
            list
        }
        .onAppear {
            // 面板刚显示、窗口成为 key 之后再抢输入焦点
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { addFocused = true }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Self.dateText)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(L10n.t("\(store.undoneCount) 项待办", "\(store.undoneCount) to do"))
                .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
        }
        .padding(.horizontal, 4)
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

    // MARK: - 添加

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(PanelTheme.brandColor)
            TextField(L10n.t("添加一件今天要做的事,回车确认", "Add something for today, press Return"), text: $draft)
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

    // MARK: - 列表

    @ViewBuilder
    private var list: some View {
        if store.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 26)).foregroundStyle(SysTheme.tertiary)
                Text(L10n.t("今天还没有待办", "Nothing planned yet"))
                    .font(.system(size: 12)).foregroundStyle(SysTheme.secondary)
                Text(L10n.t("选中文字,点工具条上的「加入待办」也行", "Or select text anywhere and tap “Add to To-Do” on the bar"))
                    .font(.system(size: 11)).foregroundStyle(SysTheme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.undone) { row($0) }
                    .onMove { store.moveUndone(from: $0, to: $1) }
                if !store.done.isEmpty {
                    HStack {
                        Text(L10n.t("已完成 \(store.done.count)", "Done \(store.done.count)"))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(SysTheme.secondary)
                        Spacer()
                        Button(L10n.t("清空", "Clear")) { store.clearDone() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                    }
                    .padding(.top, 8).padding(.horizontal, 4)
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    ForEach(store.done) { row($0) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ item: TodoItem) -> some View {
        TodoRow(item: item, store: store, editing: $editing)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
    }
}

private struct TodoRow: View {
    let item: TodoItem
    @ObservedObject var store: TodoStore
    @Binding var editing: UUID?
    @State private var text = ""
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Button { store.toggle(item.id) } label: {
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

            Button { store.remove(item.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SysTheme.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hover ? SysTheme.track : Color.clear))
        .onHover { hover = $0 }
        .contextMenu {
            Button(L10n.t("编辑", "Edit")) { editing = item.id }
            Button(L10n.t("复制", "Copy")) { PasteboardGuard.write(item.text) }
            Divider()
            Button(L10n.t("删除", "Delete"), role: .destructive) { store.remove(item.id) }
        }
    }

    private func commit() {
        store.rename(item.id, to: text)
        editing = nil
    }
}

extension ToolPanels {
    @MainActor static let todo = ToolPanel(
        title: L10n.t("今日待办", "Today"), symbol: "checklist",
        size: NSSize(width: 380, height: 640),
        pinnable: true, pinned: ConfigStore.shared.config.todo.pinned,
        onPinChanged: { pinned in
            var c = ConfigStore.shared.config
            c.todo.pinned = pinned
            try? ConfigStore.shared.save(c)
        },
        onShow: {
            TodoStore.shared.reload()
            Pomodoro.shared.applyConfig()
            RemindersSync.shared.syncSoon()
        },
        content: { AnyView(TodoView(store: TodoStore.shared, pomo: Pomodoro.shared)) })
}
