import SwiftUI
import Cocoa
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 磁盘清理面板的 SwiftUI 内容（配色沿用系统监控的 SysTheme）。

/// 分类 tab：四个清理分类 + 只展示的手动管理
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
                        if vm.lockedCount > 0 {
                            Text(L10n.t("已锁定 \(vm.lockedCount) 项使用中", "\(vm.lockedCount) in use"))
                                .foregroundStyle(SysTheme.secondary)
                        }
                        if vm.hasUnmeasured {
                            Text(L10n.t("部分受保护条目未能测量", "Some protected items couldn’t be measured"))
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
            HStack(spacing: 8) {
                if s.failedCount > 0 {
                    Button(L10n.t("查看日志", "View Log")) { vm.openLog() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(SysTheme.brand)
                }
                if s.trashedCount > 0 {
                    Button(L10n.t("打开废纸篓", "Open Trash")) {
                        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".Trash"))
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(SysTheme.brand)
                }
                Button { vm.dismissSummary() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SysTheme.tertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(L10n.t("关闭提示", "Dismiss"))
            }
        }
        .padding(10)
        .background(CardBackground())
    }

    /// 底栏只作用于当前 tab 的分类：其他 tab 里的勾选不会被统计、也不会被清理
    private func footer(_ c: CleanCategory) -> some View {
        let picked = vm.selectedItems(in: c)
        let bytes = vm.selectedBytes(in: c)
        let busy = vm.isWorking || vm.isScanning
        let blocked = picked.isEmpty || busy
        let actionTitle = actionButtonTitle(for: picked, bytes: bytes, working: vm.isWorking)

        return HStack(spacing: 14) {
            Text(L10n.t("已选 \(picked.count) 项", "\(picked.count) selected"))
                .font(.system(size: 12)).foregroundStyle(SysTheme.secondary)
            link(L10n.t("全选", "All"), disabled: busy) { vm.selectAll(in: c) }
            link(L10n.t("全不选", "None"), disabled: busy) { vm.selectNone(in: c) }
            link(L10n.t("推荐", "Recommended"), disabled: busy) { vm.selectRecommended(in: c) }
            Spacer()
            Button {
                if CleanConfirm.confirm(items: picked) { vm.cleanSelected(in: c) }
            } label: {
                Text(actionTitle)
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

    private func actionButtonTitle(for picked: [CleanItem], bytes: Int64, working: Bool) -> String {
        if working { return L10n.t("正在清理…", "Cleaning…") }
        let hasPath = picked.contains { $0.kind == .path }
        let hasNpm = picked.contains { $0.kind == .npmCache }
        if hasNpm && !hasPath {
            return L10n.t("直接清理 · \(ByteFormat.string(bytes))", "Clean Directly · \(ByteFormat.string(bytes))")
        }
        if hasNpm && hasPath {
            return L10n.t("清理所选 · \(ByteFormat.string(bytes))", "Clean Selected · \(ByteFormat.string(bytes))")
        }
        return L10n.t("移入废纸篓 · \(ByteFormat.string(bytes))", "Move to Trash · \(ByteFormat.string(bytes))")
    }

    private func link(_ title: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(SysTheme.brand)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

extension PanelTheme {
    static var brandColor: Color { Color(nsColor: PanelTheme.brand) }
}

/// 执行前确认：区分废纸篓移入与 npm 直接永久删除，避免误导用户
@MainActor
enum CleanConfirm {
    static func confirm(items: [CleanItem]) -> Bool {
        guard !items.isEmpty else { return false }
        let pathItems = items.filter { $0.kind == .path }
        let npmItems = items.filter { $0.kind == .npmCache }
        let totalBytes = items.compactMap(\.sizeBytes).reduce(0, +)
        let hasRemnant = items.contains { $0.category == .remnants }

        let a = NSAlert()
        a.alertStyle = .warning

        if npmItems.isEmpty {
            if pathItems.count == 1, let only = pathItems.first {
                let label = only.ownerAppName ?? only.name
                a.messageText = L10n.t("将「\(label)」移入废纸篓？", "Move “\(label)” to the Trash?")
            } else {
                a.messageText = L10n.t("将 \(pathItems.count) 项移入废纸篓？", "Move \(pathItems.count) items to the Trash?")
            }
            var info = L10n.t(
                "共 \(ByteFormat.string(totalBytes))。项目会进入废纸篓，可随时放回原处；清倒废纸篓后才会真正释放空间。",
                "\(ByteFormat.string(totalBytes)) in total. Items go to the Trash and can be put back; space is freed once you empty it.")
            if hasRemnant {
                info += "\n" + L10n.t("包含疑似卸载残留，请确认对应应用已不再使用。",
                                      "Includes suspected leftovers; please make sure those apps are no longer needed.")
            }
            a.informativeText = info
            a.addButton(withTitle: L10n.t("移入废纸篓", "Move to Trash"))
        } else if pathItems.isEmpty {
            a.messageText = L10n.t("直接清理 npm 孤儿缓存？", "Clean orphan npm cache directly?")
            a.informativeText = L10n.t(
                "预计释放 \(ByteFormat.string(totalBytes))。仅删除无索引引用的孤儿数据与临时文件，会直接清除且不进入废纸篓，有效缓存保持不变。",
                "About \(ByteFormat.string(totalBytes)) to reclaim. Only unreferenced orphan blobs and temp files are removed directly (not sent to Trash); live cache is untouched.")
            a.addButton(withTitle: L10n.t("直接清理", "Clean Directly"))
        } else {
            let pathBytes = pathItems.compactMap(\.sizeBytes).reduce(0, +)
            let npmBytes = npmItems.compactMap(\.sizeBytes).reduce(0, +)
            a.messageText = L10n.t("清理所选 \(items.count) 项？", "Clean \(items.count) selected items?")
            a.informativeText = L10n.t(
                "其中 \(pathItems.count) 项（\(ByteFormat.string(pathBytes))）会移入废纸篓并可随时恢复；npm 孤儿缓存（\(ByteFormat.string(npmBytes))）会直接永久清除。",
                "\(pathItems.count) items (\(ByteFormat.string(pathBytes))) will move to the Trash and can be restored; orphan npm cache (\(ByteFormat.string(npmBytes))) will be deleted directly.")
            a.addButton(withTitle: L10n.t("开始清理", "Clean"))
        }

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
        .buttonStyle(.plain).help(help).disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }
}

// MARK: - 分类页（一个 tab 的内容）

private struct CleanCategoryPage: View {
    @ObservedObject var vm: CleanViewModel
    let category: CleanCategory
    let items: [CleanItem]

    private var selectedCount: Int { vm.selectedItems(in: category).count }
    private var selectedBytes: Int64 { vm.selectedBytes(in: category) }
    private var totalBytes: Int64 { items.filter(\.isSelectable).compactMap(\.sizeBytes).reduce(0, +) }
    private var busy: Bool { vm.isWorking || vm.isScanning }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CleanCheckbox(
                    state: vm.selectionState(category),
                    enabled: !busy && items.contains(where: \.isSelectable)
                ) {
                    vm.toggleSection(category)
                }
                Text(category.title).font(.system(size: 13, weight: .semibold))
                Text("\(selectedCount)/\(items.count)")
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
        // 条目少时卡片也撑满剩余高度，底栏才会固定在窗口底部
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CardBackground())
    }
}

private struct CleanItemRow: View {
    @ObservedObject var vm: CleanViewModel
    let item: CleanItem

    private var busy: Bool { vm.isWorking || vm.isScanning }

    var body: some View {
        HStack(spacing: 10) {
            CleanCheckbox(state: item.isSelected ? .all : .none, enabled: item.isSelectable && !busy) {
                vm.toggle(item.id)
            }
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
                        action: {
                            if CleanConfirm.confirm(items: [item]) { vm.trashItem(item.id) }
                        },
                        enabled: item.isSelectable && !busy)
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

            Text(L10n.t("仅显示占用，不参与清理，可到对应 App 处置", "Shown for reference only; manage them in the apps themselves"))
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
