import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

enum StartupFilter: String, CaseIterable, Hashable {
    case all
    case loginItems
    case services
    case disabled
    case broken

    var title: String {
        switch self {
        case .all: return L10n.t("全部", "All")
        case .loginItems: return L10n.t("登录项", "Login")
        case .services: return L10n.t("后台服务", "Services")
        case .disabled: return L10n.t("已停用", "Disabled")
        case .broken: return L10n.t("异常", "Broken")
        }
    }
}

@MainActor
final class StartupViewModel: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var loaded = false
    @Published var isLoading = false
    @Published var isSyncingBTM = false
    @Published var filter: StartupFilter = .all
    @Published var query = ""
    @Published var pendingLabels: Set<String> = []
    @Published var message: (text: String, tone: DSTone)?

    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var btmTask: Task<Void, Never>?
    private var cachedBTM: (at: Date, snapshot: BTMSnapshot)?

    var filtered: [StartupItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            let matchesFilter: Bool = {
                switch filter {
                case .all: return true
                case .loginItems: return item.kind == .loginItem
                case .services: return item.kind.isService
                case .disabled: return !item.effectiveEnabled
                case .broken: return item.broken
                }
            }()
            guard matchesFilter else { return false }
            guard !q.isEmpty else { return true }
            return item.label.localizedCaseInsensitiveContains(q)
                || item.displayName.localizedCaseInsensitiveContains(q)
                || (item.sourceAppName?.localizedCaseInsensitiveContains(q) ?? false)
                || (item.developerName?.localizedCaseInsensitiveContains(q) ?? false)
                || (item.program?.localizedCaseInsensitiveContains(q) ?? false)
                || item.path.localizedCaseInsensitiveContains(q)
        }
    }

    var isFiltering: Bool {
        filter != .all || !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func load(forceBTM: Bool = false) {
        loadTask?.cancel()
        btmTask?.cancel()
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        message = nil

        let cached = (!forceBTM) ? cachedBTM.flatMap { Date().timeIntervalSince($0.at) < 60 ? $0.snapshot : nil } : nil

        loadTask = Task {
            let fastList = await Task.detached(priority: .utility) {
                StartupItems.scanFast()
            }.value
            guard !Task.isCancelled, self.loadGeneration == gen else { return }

            if let cached {
                self.items = StartupItems.mergeBTM(fastList, cached)
                self.loaded = true
                self.isLoading = false
                self.isSyncingBTM = false
                return
            }

            self.items = fastList
            self.loaded = true
            self.isLoading = false
            self.isSyncingBTM = true

            self.btmTask = Task {
                let result = await Task.detached(priority: .utility) { () -> (BTMSnapshot, [String: Int])? in
                    guard let snap = StartupItems.scanBTM() else { return nil }
                    let pids = StartupItems.parseRunningPIDs(ShellRun.run("/bin/launchctl", ["list"], timeout: 10).out)
                    return (snap, pids)
                }.value
                guard !Task.isCancelled, self.loadGeneration == gen else { return }
                self.isSyncingBTM = false
                if let (snap, pids) = result {
                    self.cachedBTM = (Date(), snap)
                    self.items = StartupItems.mergeBTM(self.items, snap, runningPIDs: pids)
                }
            }
        }
    }

    func set(_ item: StartupItem, enabled: Bool) {
        guard item.canToggle, !pendingLabels.contains(item.label) else { return }
        pendingLabels.insert(item.label)
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                StartupItems.setEnabled(item, enabled)
            }.value
            self.pendingLabels.remove(item.label)
            if ok {
                self.applyEnabled(enabled, forLabel: item.label)
                self.message = (
                    enabled
                        ? L10n.t("已启用 \(item.label)（重新登录生效）", "Enabled \(item.label) (takes effect after re-login)")
                        : L10n.t("已停用 \(item.label)（重新登录生效）", "Disabled \(item.label) (takes effect after re-login)"),
                    .success
                )
            } else {
                self.message = (L10n.t("修改失败：\(item.label)", "Failed to change \(item.label)"), .danger)
            }
        }
    }

    /// 同步更新所有同 `Label` 的启动项状态（防止同 Label 多 plist 状态不一致）。
    func applyEnabled(_ enabled: Bool, forLabel label: String) {
        for idx in items.indices where items[idx].label == label {
            items[idx].enabled = enabled
        }
    }

    /// 损坏的用户级启动代理：先从 launchd 会话卸载，再移入废纸篓（可恢复）。
    func removeBroken(_ item: StartupItem) {
        guard item.canRemoveBroken, !pendingLabels.contains(item.label) else { return }
        pendingLabels.insert(item.label)
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> Result<URL?, Error> in
                StartupItems.bootout(item)
                return CleanTrash.trash(URL(fileURLWithPath: item.path))
            }.value
            self.pendingLabels.remove(item.label)
            switch r {
            case .success:
                self.items.removeAll { $0.id == item.id }
                self.message = (L10n.t("已移除损坏的启动代理 \(item.label)", "Removed broken launch agent \(item.label)"), .success)
            case .failure(let e):
                self.message = (L10n.t("移除失败：", "Remove failed: ") + CleanTrash.reason(for: e), .danger)
            }
        }
    }

    func revealInFinder(_ item: StartupItem) {
        guard !item.path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    func copyIdentifier(_ item: StartupItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.label, forType: .string)
        message = (L10n.t("已复制标识 \(item.label)", "Copied identifier \(item.label)"), .neutral)
    }

    func openSystemLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Deck「启动项」页内容：登录项、应用内嵌服务与 LaunchAgent/LaunchDaemon。
struct StartupView: View {
    @ObservedObject var vm: StartupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DSSegmented(
                    selection: $vm.filter,
                    options: StartupFilter.allCases.map { ($0, $0.title) }
                )
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if vm.isSyncingBTM {
                        ProgressView().controlSize(.mini)
                        Text(L10n.t("正在同步系统登录项…", "Syncing system items…"))
                            .font(DS.small).foregroundStyle(DS.muted)
                    } else if vm.loaded {
                        let countText = vm.isFiltering
                            ? L10n.t("匹配 \(vm.filtered.count) / 共 \(vm.items.count) 项",
                                     "\(vm.filtered.count) of \(vm.items.count) items")
                            : L10n.t("共 \(vm.items.count) 项",
                                     vm.items.count == 1 ? "1 item" : "\(vm.items.count) items")
                        Text(countText).font(DS.small).foregroundStyle(DS.muted).monospacedDigit()
                    }
                }
            }

            DSSearchField(L10n.t("搜索名称、标识、应用或路径", "Search name, label, app or path"), text: $vm.query)

            listContainer

            if let m = vm.message {
                Text(m.text)
                    .font(DS.small)
                    .foregroundStyle(messageColor(m.tone))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private var listContainer: some View {
        if !vm.loaded && vm.isLoading {
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text(L10n.t("正在扫描启动项与后台服务…", "Scanning login items & background services…"))
                    .font(DS.caption).foregroundStyle(DS.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dsCardBackground()
        } else if vm.filtered.isEmpty {
            if vm.isFiltering {
                DSEmptyState(
                    icon: "search",
                    title: L10n.t("没有匹配的启动项", "No matching items"),
                    message: L10n.t("换个关键词或切换筛选条件试试。", "Try a different keyword or filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dsCardBackground()
            } else {
                DSEmptyState(
                    icon: "power",
                    title: L10n.t("没有发现登录项或后台服务", "No login items or background services"),
                    message: L10n.t("点击右上角刷新重新扫描。", "Click Refresh in the top right to scan again.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dsCardBackground()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(vm.filtered.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { DSDivider(inset: 14) }
                        StartupRow(
                            item: item,
                            isPending: vm.pendingLabels.contains(item.label),
                            onToggle: { vm.set(item, enabled: $0) },
                            onRemoveBroken: { vm.removeBroken(item) },
                            onReveal: { vm.revealInFinder(item) },
                            onCopyLabel: { vm.copyIdentifier(item) },
                            onOpenSettings: { vm.openSystemLoginItemsSettings() }
                        )
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .dsCardBackground()
        }
    }

    private func messageColor(_ tone: DSTone) -> Color {
        switch tone {
        case .success: return DS.success
        case .danger: return DS.danger
        case .warning: return DS.warning
        default: return DS.muted
        }
    }
}

private struct StartupRow: View {
    let item: StartupItem
    let isPending: Bool
    let onToggle: (Bool) -> Void
    let onRemoveBroken: () -> Void
    let onReveal: () -> Void
    let onCopyLabel: () -> Void
    let onOpenSettings: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(DS.font(13, .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if item.displayName != item.label {
                        Text(item.label)
                            .font(DS.small)
                            .foregroundStyle(DS.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if item.runningPID != nil {
                        DSChip(L10n.t("运行中", "Running"), tone: .success)
                    }
                    if item.broken {
                        DSChip(L10n.t("程序不存在", "Missing"), tone: .danger)
                    } else if item.btmDisallowed {
                        DSChip(L10n.t("系统设置已禁用", "Disabled in Settings"), tone: .warning)
                    }
                }

                Text(subtitleText)
                    .font(DS.small)
                    .foregroundStyle(item.broken ? DS.danger : DS.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if hovering {
                HStack(spacing: 2) {
                    if !item.path.isEmpty {
                        DSIconButton("folder-open", help: L10n.t("在访达中显示", "Reveal in Finder"), size: 26, action: onReveal)
                    }
                    DSIconButton("copy", help: L10n.t("复制标识", "Copy Identifier"), size: 26, action: onCopyLabel)
                    if item.btmDisallowed || item.managedBySystemSettings {
                        DSIconButton("external-link", help: L10n.t("在系统设置中管理", "Manage in System Settings"), size: 26, action: onOpenSettings)
                    }
                }
                .transition(.opacity)
            }

            if item.canRemoveBroken {
                DSButton(L10n.t("移入废纸篓", "Move to Trash"), icon: "trash-2", kind: .danger, action: onRemoveBroken)
                    .help(L10n.t("指向的程序已不存在，从会话卸载并移入废纸篓", "Program missing; boot out and move plist to Trash"))
            }

            if !item.canToggle && !item.broken {
                if item.managedBySystemSettings && !item.btmDisallowed {
                    DSChip(L10n.t("系统设置管理", "System Managed"), tone: .neutral)
                } else if item.systemLevel && !item.btmDisallowed {
                    DSChip(L10n.t("系统级", "System"), tone: .neutral)
                }
            }

            if isPending {
                ProgressView().controlSize(.small).frame(width: 36, height: 20)
            } else {
                DSToggle(isOn: Binding(
                    get: { item.effectiveEnabled },
                    set: { onToggle($0) }
                ))
                .disabled(!item.canToggle)
                .help(toggleHelpText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .background(hovering ? DS.hover : .clear)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let appPath = item.sourceAppPath, FileManager.default.fileExists(atPath: appPath) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appPath))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            let (iconName, color): (String, Color) = {
                if item.broken { return ("triangle-alert", DS.danger) }
                switch item.kind {
                case .loginItem: return ("app-window", Color(nsColor: IconPalette.blue))
                case .launchAgent, .appAgent: return ("zap", DS.accent)
                case .launchDaemon, .appDaemon: return ("server-cog", Color(nsColor: IconPalette.slate))
                }
            }()
            DSIconTile(iconName, color: color, size: 28)
        }
    }

    private var subtitleText: String {
        if item.broken {
            let target = item.program ?? item.path
            return L10n.t("\(item.kind.title) · 缺失：\(target)", "\(item.kind.title) · Missing: \(target)")
        }
        var parts: [String] = [item.kind.title]
        if item.systemLevel && item.kind != .launchDaemon && item.kind != .appDaemon {
            parts.append(L10n.t("系统级", "System"))
        }
        if !item.trigger.title.isEmpty && item.kind != .loginItem {
            parts.append(item.trigger.title)
        }
        if let source = item.sourceAppName, source != item.displayName {
            parts.append(source)
        } else if let dev = item.developerName, !dev.isEmpty {
            parts.append(dev)
        } else if let prog = item.program {
            parts.append(prog)
        }
        return parts.joined(separator: " · ")
    }

    private var toggleHelpText: String {
        if item.btmDisallowed {
            return L10n.t("已被 macOS「系统设置 → 登录项与扩展」禁用，请前往系统设置开启",
                          "Disallowed in macOS System Settings → Login Items & Extensions")
        }
        if item.managedBySystemSettings {
            return L10n.t("由 macOS 系统设置管理，点击左侧外部链接图标前往系统设置",
                          "Managed by macOS System Settings; use the link button to open Settings")
        }
        if item.systemLevel {
            return L10n.t("系统级启动项，仅展示状态", "System-level item (read-only)")
        }
        if item.broken {
            return L10n.t("程序已不存在，请直接移入废纸篓", "Program missing; move to Trash")
        }
        return item.effectiveEnabled
            ? L10n.t("点击停用（重新登录生效）", "Click to disable (takes effect after re-login)")
            : L10n.t("点击启用（重新登录生效）", "Click to enable (takes effect after re-login)")
    }
}
