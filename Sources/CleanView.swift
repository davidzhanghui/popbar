import SwiftUI
import Cocoa

/// 磁盘清理面板的 SwiftUI 内容(移植自 mole-demo 的评审页,配色沿用系统监控的 SysTheme)。

/// 分类 tab:四个清理分类 + 只展示的手动管理
enum CleanTab: Hashable {
    case category(CleanCategory)
    case manual
}

struct CleanView: View {
    @ObservedObject var vm: CleanViewModel
    @State private var tab: CleanTab = .category(.appCache)

    var body: some View {
        VStack(spacing: 10) {
            header
            tabBar
            if vm.hasScanned || vm.isScanning {
                page
            } else {
                Spacer()
            }
            if let s = vm.summary { summaryBanner(s) }
            if case .category(let c) = tab { footer(c) }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                if vm.isScanning {
                    Text(L10n.t("正在扫描缓存…", "Scanning caches…"))
                        .font(.system(size: 20, weight: .bold))
                    Text(L10n.t("已测量 \(vm.measuredCount)/\(vm.items.count) 项", "Measured \(vm.measuredCount)/\(vm.items.count)"))
                        .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                } else {
                    Text(ByteFormat.string(vm.totalBytes))
                        .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                    HStack(spacing: 8) {
                        Text(L10n.t("可清理 · \(vm.items.count) 项 · \(vm.groupedItems.count) 类",
                                    "Cleanable · \(vm.items.count) items · \(vm.groupedItems.count) groups"))
                        if vm.hasUnmeasured {
                            Text(L10n.t("部分条目未能测量", "Some items couldn’t be measured"))
                                .foregroundStyle(Color.orange)
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                }
            }
            Spacer()
            if vm.isScanning { ProgressView().controlSize(.small) }
            Button { vm.scan() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(SysTheme.track))
            }
            .buttonStyle(.plain)
            .disabled(vm.isScanning || vm.isWorking)
            .help(L10n.t("重新扫描", "Rescan"))
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Tab 栏

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(CleanCategory.allCases) { c in
                tabButton(.category(c), symbol: c.symbol, title: c.shortTitle,
                          count: vm.items.filter { $0.category == c }.count)
            }
            if !vm.manualItems.isEmpty {
                tabButton(.manual, symbol: "hand.raised", title: L10n.t("手动管理", "Manual"),
                          count: vm.manualItems.count)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SysTheme.track))
    }

    private func tabButton(_ t: CleanTab, symbol: String, title: String, count: Int) -> some View {
        let on = tab == t
        return Button { tab = t } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: on ? .semibold : .regular))
                Text("\(count)").font(.system(size: 10)).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(on ? Color.white.opacity(0.25) : SysTheme.track))
            }
            .foregroundStyle(on ? Color.white : SysTheme.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(on ? PanelTheme.brandColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 当前 tab 的内容

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .category(let c):
            CleanCategoryPage(vm: vm, category: c, items: vm.items.filter { $0.category == c })
        case .manual:
            ScrollView { CleanManualCard(vm: vm) }.frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - 结果横幅 / 底栏

    private func summaryBanner(_ s: CleanSummary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: s.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(s.failedCount == 0 ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 12, weight: .semibold))
                Text(s.text).font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if s.trashedCount > 0 {
                Button(L10n.t("打开废纸篓", "Open Trash")) {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".Trash"))
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(SysTheme.brand)
            }
        }
        .padding(10)
        .background(CardBackground())
    }

    /// 底栏只作用于当前 tab 的分类:其他 tab 里的勾选不会被统计、也不会被清理
    private func footer(_ c: CleanCategory) -> some View {
        let picked = vm.selectedItems(in: c)
        let bytes = vm.selectedBytes(in: c)
        let blocked = picked.isEmpty || vm.isWorking || vm.isScanning
        return HStack(spacing: 14) {
            Text(L10n.t("已选 \(picked.count) 项", "\(picked.count) selected"))
                .font(.system(size: 12)).foregroundStyle(SysTheme.secondary)
            link(L10n.t("全选", "All")) { vm.selectAll(in: c) }
            link(L10n.t("全不选", "None")) { vm.selectNone(in: c) }
            link(L10n.t("推荐", "Recommended")) { vm.selectRecommended(in: c) }
            Spacer()
            Button {
                if CleanConfirm.confirm(count: picked.count, bytes: bytes) { vm.cleanSelected(in: c) }
            } label: {
                Text(vm.isWorking ? L10n.t("正在清理…", "Cleaning…")
                     : L10n.t("移入废纸篓 · \(ByteFormat.string(bytes))", "Move to Trash · \(ByteFormat.string(bytes))"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Capsule().fill(PanelTheme.brandColor))
            }
            .buttonStyle(.plain)
            .opacity(blocked ? 0.4 : 1)
            .disabled(blocked)
        }
        .padding(.horizontal, 4)
    }

    private func link(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(SysTheme.brand)
        }.buttonStyle(.plain)
    }
}

extension PanelTheme {
    static var brandColor: Color { Color(nsColor: PanelTheme.brand) }
}

/// 执行前确认:说明进废纸篓、可恢复
@MainActor
enum CleanConfirm {
    static func confirm(count: Int, bytes: Int64) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L10n.t("将 \(count) 项移入废纸篓?", "Move \(count) items to the Trash?")
        a.informativeText = L10n.t(
            "共 \(ByteFormat.string(bytes))。项目会进入废纸篓,可随时放回原处;清倒废纸篓后才会真正释放空间。npm 孤儿缓存是可再生数据,会直接清除。",
            "\(ByteFormat.string(bytes)) in total. Items go to the Trash and can be put back; space is freed once you empty it. Orphan npm cache is regenerable and removed directly.")
        a.addButton(withTitle: L10n.t("移入废纸篓", "Move to Trash"))
        a.addButton(withTitle: L10n.t("取消", "Cancel"))
        NSApp.activateForUI()
        return a.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - 勾选框

private struct CleanCheckbox: View {
    let state: CleanSelState
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state == .none ? SysTheme.tertiary : PanelTheme.brandColor)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private var symbol: String {
        switch state {
        case .all: return "checkmark.square.fill"
        case .partial: return "minus.square.fill"
        case .none: return "square"
        }
    }
}

private struct RowIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var enabled = true

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(SysTheme.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).disabled(!enabled)
    }
}

// MARK: - 分类页(一个 tab 的内容)

private struct CleanCategoryPage: View {
    @ObservedObject var vm: CleanViewModel
    let category: CleanCategory
    let items: [CleanItem]

    private var selectedBytes: Int64 { items.filter(\.isSelected).compactMap(\.sizeBytes).reduce(0, +) }
    private var totalBytes: Int64 { items.compactMap(\.sizeBytes).reduce(0, +) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CleanCheckbox(state: vm.selectionState(category), enabled: items.contains(where: \.isSelectable)) {
                    vm.toggleSection(category)
                }
                Text(category.title).font(.system(size: 13, weight: .semibold))
                Text("\(items.filter(\.isSelected).count)/\(items.count)")
                    .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                Spacer()
                Text("\(ByteFormat.string(selectedBytes)) / \(ByteFormat.string(totalBytes))")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

            Text(category.summary).font(.system(size: 10)).foregroundStyle(SysTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 6)

            Divider().opacity(0.5)

            if items.isEmpty {
                Text(vm.isScanning ? L10n.t("扫描中…", "Scanning…") : L10n.t("这一类没有可清理的内容 🎉", "Nothing to clean here 🎉"))
                    .font(.system(size: 12)).foregroundStyle(SysTheme.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 40)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { CleanItemRow(vm: vm, item: $0) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        // 条目少时卡片也撑满剩余高度,底栏才会固定在窗口底部
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CardBackground())
    }
}

private struct CleanItemRow: View {
    @ObservedObject var vm: CleanViewModel
    let item: CleanItem

    var body: some View {
        HStack(spacing: 10) {
            CleanCheckbox(state: item.isSelected ? .all : .none, enabled: item.isSelectable) { vm.toggle(item.id) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if item.isLocked {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    } else if item.kind == .npmCache {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 9)).foregroundStyle(SysTheme.tertiary)
                    }
                    Text(item.ownerAppName ?? item.name).font(.system(size: 12)).lineLimit(1)
                    if let note = item.displayNote { noteTag(note) }
                }
                Text(item.displayPath).font(.system(size: 10)).foregroundStyle(SysTheme.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(item.sizeBytes.map(ByteFormat.string) ?? (vm.isScanning ? "…" : "—"))
                .font(.system(size: 11)).monospacedDigit()
            if item.kind == .path {
                RowIcon(symbol: "trash", help: L10n.t("移到废纸篓", "Move to Trash"),
                        action: { vm.trashItem(item.id) },
                        enabled: item.isSelectable && !vm.isWorking)
            }
            RowIcon(symbol: "folder", help: L10n.t("在访达中显示", "Show in Finder")) { vm.reveal(item.url) }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    @ViewBuilder
    private func noteTag(_ note: String) -> some View {
        if item.isLocked {
            Text(note).font(.system(size: 9)).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.22))).foregroundStyle(Color.orange)
        } else {
            Text(note).font(.system(size: 10)).foregroundStyle(SysTheme.secondary).lineLimit(1)
        }
    }
}

// MARK: - 手动管理

private struct CleanManualCard: View {
    @ObservedObject var vm: CleanViewModel

    private var total: Int64 { vm.manualItems.compactMap(\.sizeBytes).reduce(0, +) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised").font(.system(size: 13))
                    .foregroundStyle(SysTheme.brand).frame(width: 20)
                Text(L10n.t("手动管理", "Manual")).font(.system(size: 13, weight: .semibold))
                Text(L10n.t("仅展示", "view only")).font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                Spacer()
                Text(ByteFormat.string(total)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            Text(L10n.t("仅显示占用,不参与清理,可到对应 App 处置", "Shown for reference only; manage them in the apps themselves"))
                .font(.system(size: 10)).foregroundStyle(SysTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 6)

            ForEach(vm.manualItems) { item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 12)).lineLimit(1)
                        Text("\(item.displayPath) · \(item.hint)").font(.system(size: 10))
                            .foregroundStyle(SysTheme.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(item.sizeBytes.map(ByteFormat.string) ?? (vm.isScanning ? "…" : "—"))
                        .font(.system(size: 11)).monospacedDigit()
                    RowIcon(symbol: "folder", help: L10n.t("在访达中显示", "Show in Finder")) { vm.reveal(item.url) }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
        .padding(.vertical, 2)
        .background(CardBackground())
    }
}
