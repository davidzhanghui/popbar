import SwiftUI
import UniformTypeIdentifiers
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
    @Published var expandedGroupIDs: Set<String> = []
    @Published var message: (text: String, tone: DSTone)?

    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var btmTask: Task<Void, Never>?
    private var cachedBTM: (at: Date, snapshot: BTMSnapshot)?

    /// 按 macOS「登录项与扩展」口径归并后的全部分组
    var groupedAll: [StartupGroup] {
        StartupItems.groupItems(items)
    }

    /// 经筛选与搜索后的分组列表（用于主列表展示，数量与 macOS 系统设置对齐）
    var filteredGroups: [StartupGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return groupedAll.filter { group in
            let matchesFilter: Bool = {
                switch filter {
                case .all: return true
                case .loginItems: return group.isLoginItem
                case .services: return group.isService
                case .disabled: return !group.effectiveEnabled
                case .broken: return group.anyBroken
                }
            }()
            guard matchesFilter else { return false }
            guard !q.isEmpty else { return true }
            if group.title.localizedCaseInsensitiveContains(q) { return true }
            return group.items.contains { matchesQuery($0, q) }
        }
    }

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
            return matchesQuery(item, q)
        }
    }

    private func matchesQuery(_ item: StartupItem, _ q: String) -> Bool {
        item.label.localizedCaseInsensitiveContains(q)
            || item.displayName.localizedCaseInsensitiveContains(q)
            || (item.btmParentName?.localizedCaseInsensitiveContains(q) ?? false)
            || (item.sourceAppName?.localizedCaseInsensitiveContains(q) ?? false)
            || (item.developerName?.localizedCaseInsensitiveContains(q) ?? false)
            || (item.program?.localizedCaseInsensitiveContains(q) ?? false)
            || item.path.localizedCaseInsensitiveContains(q)
    }

    func isExpanded(_ group: StartupGroup) -> Bool {
        guard group.isExpandable else { return false }
        if expandedGroupIDs.contains(group.id) { return true }
        if filter == .broken && group.anyBroken { return true }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty && !group.title.localizedCaseInsensitiveContains(q) { return true }
        return false
    }

    func toggleExpanded(_ groupID: String) {
        if expandedGroupIDs.contains(groupID) {
            expandedGroupIDs.remove(groupID)
        } else {
            expandedGroupIDs.insert(groupID)
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
            let result = await Task.detached(priority: .userInitiated) {
                StartupItems.setEnabledResult(item, enabled)
            }.value
            self.pendingLabels.remove(item.label)
            switch result {
            case .success(let immediate):
                self.applyEnabled(enabled, forLabel: item.label)
                if item.kind == .loginItem {
                    self.cachedBTM = nil
                    if StartupItems.isSelfApp(label: item.label, path: item.path) {
                        self.syncSelfLaunchAtLogin(enabled)
                    }
                    self.message = (
                        enabled
                            ? L10n.t("已将 \(item.displayName) 加入登录项（立即生效）",
                                     "Added \(item.displayName) to Login Items (immediate)")
                            : L10n.t("已从登录项移除 \(item.displayName)（立即生效，可再次开启恢复）",
                                     "Removed \(item.displayName) from Login Items (immediate; toggle on to restore)"),
                        .success
                    )
                } else {
                    self.message = (
                        enabled
                            ? L10n.t("已启用 \(item.label)\(immediate ? "" : "（重新登录生效）")",
                                     "Enabled \(item.label)\(immediate ? "" : " (takes effect after re-login)")")
                            : L10n.t("已停用 \(item.label)\(immediate ? "" : "（重新登录生效）")",
                                     "Disabled \(item.label)\(immediate ? "" : " (takes effect after re-login)")"),
                        .success
                    )
                }

            case .managedBySystemSettings:
                for idx in self.items.indices where self.items[idx].id == item.id {
                    self.items[idx].managedBySystemSettings = true
                }
                self.message = (
                    L10n.t("\(item.displayName) 由应用自身注册开机启动，请点击「系统设置」或在其应用偏好中管理",
                           "\(item.displayName) registers its own login service; manage it in System Settings or the app's preferences"),
                    .warning
                )

            case .permissionDenied:
                self.message = (
                    L10n.t("未授权 PopBar 控制「系统事件」，请前往系统设置 → 隐私与安全性 → 自动化授权，或直接点击「系统设置」管理",
                           "PopBar needs Automation permission for System Events (System Settings → Privacy & Security → Automation)"),
                    .warning
                )

            case .cancelled:
                self.message = (
                    L10n.t("已取消管理员授权，未修改 \(item.displayName)",
                           "Administrator authorization cancelled; \(item.displayName) unchanged"),
                    .neutral
                )

            case .failure(let reason):
                self.message = (
                    L10n.t("修改失败（\(item.displayName)）：\(reason)",
                           "Failed to change \(item.displayName): \(reason)"),
                    .danger
                )
            }
        }
    }

    func setGroup(_ group: StartupGroup, enabled: Bool) {
        if group.items.count == 1 {
            set(group.primaryItem, enabled: enabled)
            return
        }
        guard group.canToggleGroup else { return }
        let targets = group.items.filter { !pendingLabels.contains($0.label) }
        guard !targets.isEmpty else { return }
        for t in targets { pendingLabels.insert(t.label) }
        Task {
            var failedReason: String?
            var cancelled = false
            var changedCount = 0
            for t in targets {
                let result = await Task.detached(priority: .userInitiated) {
                    StartupItems.setEnabledResult(t, enabled)
                }.value
                self.pendingLabels.remove(t.label)
                switch result {
                case .success:
                    self.applyEnabled(enabled, forLabel: t.label)
                    changedCount += 1
                case .cancelled:
                    cancelled = true
                case .managedBySystemSettings:
                    for idx in self.items.indices where self.items[idx].id == t.id {
                        self.items[idx].managedBySystemSettings = true
                    }
                    failedReason = L10n.t("部分项目受系统设置管辖", "Some items are managed by System Settings")
                case .permissionDenied:
                    failedReason = L10n.t("未授权控制「系统事件」", "System Events permission denied")
                case .failure(let r):
                    failedReason = r
                }
            }
            if let reason = failedReason {
                self.message = (L10n.t("\(group.title) 修改未完全生效：\(reason)", "\(group.title): \(reason)"), .warning)
            } else if cancelled && changedCount == 0 {
                self.message = (L10n.t("已取消管理员授权", "Administrator authorization cancelled"), .neutral)
            } else if changedCount > 0 {
                self.message = (
                    enabled
                        ? L10n.t("已启用 \(group.title) 的 \(changedCount) 个项目（重新登录生效）",
                                 "Enabled \(changedCount) items for \(group.title) (after re-login)")
                        : L10n.t("已停用 \(group.title) 的 \(changedCount) 个项目（重新登录生效）",
                                 "Disabled \(changedCount) items for \(group.title) (after re-login)"),
                    .success
                )
            }
        }
    }

    func pickAndAddLoginItem() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("选择登录时打开的应用", "Choose an Application to Open at Login")
        panel.prompt = L10n.t("添加", "Add")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activateForUI()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addLoginItem(url: url)
    }

    func addLoginItem(url: URL) {
        let candidate = StartupItems.makeLoginItem(from: url)
        guard !pendingLabels.contains(candidate.label) else { return }
        pendingLabels.insert(candidate.label)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                StartupItems.addLoginItem(at: candidate.path)
            }.value
            self.pendingLabels.remove(candidate.label)
            switch result {
            case .success:
                self.cachedBTM = nil
                if StartupItems.isSelfApp(label: candidate.label, path: candidate.path) {
                    self.syncSelfLaunchAtLogin(true)
                }
                if let idx = self.items.firstIndex(where: {
                    $0.kind == .loginItem && StartupItems.normalizedLoginItemPath($0.path) == candidate.path
                }) {
                    self.items[idx].enabled = true
                    self.items[idx].managedBySystemSettings = false
                } else {
                    self.items = StartupItems.sortItems(self.items + [candidate])
                }
                self.message = (
                    L10n.t("已添加登录项 \(candidate.displayName)（立即生效）",
                           "Added \(candidate.displayName) to Login Items (immediate)"),
                    .success
                )
            case .permissionDenied:
                self.message = (
                    L10n.t("未授权 PopBar 控制「系统事件」，请前往系统设置 → 隐私与安全性 → 自动化授权",
                           "PopBar needs Automation permission for System Events (System Settings → Privacy & Security → Automation)"),
                    .warning
                )
            case .managedBySystemSettings:
                self.message = (
                    L10n.t("请前往「系统设置 → 登录项与扩展」添加该应用",
                           "Please add this app in System Settings → Login Items & Extensions"),
                    .warning
                )
            case .cancelled:
                self.message = (L10n.t("已取消授权", "Authorization cancelled"), .neutral)
            case .failure(let reason):
                self.message = (
                    L10n.t("添加失败：\(reason)", "Failed to add: \(reason)"),
                    .danger
                )
            }
        }
    }

    private func syncSelfLaunchAtLogin(_ enabled: Bool) {
        var cfg = ConfigStore.shared.config
        guard cfg.launchAtLogin != enabled else { return }
        cfg.launchAtLogin = enabled
        try? ConfigStore.shared.save(cfg)
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
                        let shown = vm.filteredGroups.count
                        let total = vm.groupedAll.count
                        let countText = vm.isFiltering
                            ? L10n.t("匹配 \(shown) / 共 \(total) 项",
                                     "\(shown) of \(total) items")
                            : L10n.t("共 \(total) 项",
                                     total == 1 ? "1 item" : "\(total) items")
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
        } else if vm.filteredGroups.isEmpty {
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
                    ForEach(Array(vm.filteredGroups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { DSDivider(inset: 14) }
                        let expanded = vm.isExpanded(group)
                        StartupGroupRow(
                            group: group,
                            expanded: expanded,
                            isPending: group.items.contains { vm.pendingLabels.contains($0.label) },
                            onToggleExpand: { vm.toggleExpanded(group.id) },
                            onToggleGroup: { vm.setGroup(group, enabled: $0) },
                            onRemoveBroken: { vm.removeBroken(group.primaryItem) },
                            onReveal: { vm.revealInFinder(group.primaryItem) },
                            onCopyLabel: { vm.copyIdentifier(group.primaryItem) },
                            onOpenSettings: { vm.openSystemLoginItemsSettings() }
                        )
                        if expanded {
                            ForEach(group.items) { child in
                                DSDivider(inset: 54)
                                StartupChildRow(
                                    item: child,
                                    isPending: vm.pendingLabels.contains(child.label),
                                    onToggle: { vm.set(child, enabled: $0) },
                                    onRemoveBroken: { vm.removeBroken(child) },
                                    onReveal: { vm.revealInFinder(child) },
                                    onCopyLabel: { vm.copyIdentifier(child) },
                                    onOpenSettings: { vm.openSystemLoginItemsSettings() }
                                )
                            }
                        }
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

private struct StartupGroupRow: View {
    let group: StartupGroup
    let expanded: Bool
    let isPending: Bool
    let onToggleExpand: () -> Void
    let onToggleGroup: (Bool) -> Void
    let onRemoveBroken: () -> Void
    let onReveal: () -> Void
    let onCopyLabel: () -> Void
    let onOpenSettings: () -> Void

    @State private var hovering = false

    private var single: StartupItem? { group.isExpandable ? nil : group.primaryItem }

    var body: some View {
        HStack(spacing: 12) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.title)
                        .font(DS.font(13, .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let item = single, group.title != item.label {
                        Text(item.label)
                            .font(DS.small)
                            .foregroundStyle(DS.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if group.isExpandable {
                        Icon(expanded ? "chevron-down" : "chevron-right", size: 12, color: DS.muted)
                    }

                    if group.anyRunning {
                        DSChip(L10n.t("运行中", "Running"), tone: .success)
                    }
                    if group.anyBroken {
                        DSChip(L10n.t("程序不存在", "Missing"), tone: .danger)
                    } else if group.allBtmDisallowed {
                        DSChip(L10n.t("系统设置已禁用", "Disabled in Settings"), tone: .warning)
                    } else if group.anyBtmDisallowed {
                        DSChip(L10n.t("部分已禁用", "Partially Disabled"), tone: .warning)
                    }
                    if group.requiresAdmin && group.canToggleGroup {
                        DSChip(L10n.t("需管理员密码", "Admin"), tone: .neutral)
                    }
                }

                Text(subtitleText)
                    .font(DS.small)
                    .foregroundStyle(group.anyBroken ? DS.danger : DS.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if hovering, let item = single {
                HStack(spacing: 2) {
                    if !item.path.isEmpty {
                        DSIconButton("folder-open", help: L10n.t("在访达中显示", "Reveal in Finder"), size: 26, action: onReveal)
                    }
                    DSIconButton("copy", help: L10n.t("复制标识", "Copy Identifier"), size: 26, action: onCopyLabel)
                }
                .transition(.opacity)
            }

            if let item = single, item.canRemoveBroken {
                DSButton(L10n.t("移入废纸篓", "Move to Trash"), icon: "trash-2", kind: .danger, action: onRemoveBroken)
                    .help(L10n.t("指向的程序已不存在，从会话卸载并移入废纸篓", "Program missing; boot out and move plist to Trash"))
            }

            if isPending {
                ProgressView().controlSize(.small).frame(width: 36, height: 20)
            } else if group.canToggleGroup {
                DSToggle(isOn: Binding(
                    get: { group.effectiveEnabled },
                    set: { onToggleGroup($0) }
                ))
                .help(toggleHelpText)
            } else if !group.anyBroken {
                HStack(spacing: 6) {
                    if group.effectiveEnabled {
                        DSChip(L10n.t("已启用", "Enabled"), tone: .success)
                    }
                    DSButton(L10n.t("系统设置", "Settings"), icon: "external-link", kind: .ghost, action: onOpenSettings)
                        .help(toggleHelpText)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .background(hovering ? DS.hover : .clear)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture {
            if group.isExpandable { onToggleExpand() }
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let appPath = group.iconAppPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appPath))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            let item = group.primaryItem
            let (iconName, color): (String, Color) = {
                if group.anyBroken { return ("triangle-alert", DS.danger) }
                switch item.kind {
                case .loginItem: return ("app-window", Color(nsColor: IconPalette.blue))
                case .appLoginHelper: return ("puzzle", Color(nsColor: IconPalette.blue))
                case .launchAgent, .appAgent: return ("zap", DS.accent)
                case .launchDaemon, .appDaemon: return ("server-cog", Color(nsColor: IconPalette.slate))
                }
            }()
            DSIconTile(iconName, color: color, size: 28)
        }
    }

    private var subtitleText: String {
        if group.isExpandable {
            let countPart = L10n.t("\(group.items.count) 个项目", "\(group.items.count) items")
            var parts: [String] = [countPart]
            if group.systemItemCount > 0 {
                parts.append(L10n.t("\(group.systemItemCount) 个项目影响所有用户",
                                    "\(group.systemItemCount) affecting all users"))
            }
            let kinds = Array(NSOrderedSet(array: group.items.map(\.kind.title))) as? [String] ?? []
            if !kinds.isEmpty {
                parts.append(kinds.joined(separator: " / "))
            }
            return parts.joined(separator: " · ")
        }

        let item = group.primaryItem
        if item.broken {
            let target = item.program ?? item.path
            return L10n.t("\(item.kind.title) · 缺失：\(target)", "\(item.kind.title) · Missing: \(target)")
        }
        var parts: [String] = [item.kind.title]
        if item.systemLevel {
            parts.append(L10n.t("影响所有用户", "All users"))
        }
        if !item.trigger.title.isEmpty && item.kind != .loginItem {
            parts.append(item.trigger.title)
        }
        if let dev = item.developerName, !dev.isEmpty, dev != group.title {
            parts.append(dev)
        } else if let prog = item.program, !prog.isEmpty {
            parts.append(prog)
        }
        return parts.joined(separator: " · ")
    }

    private var toggleHelpText: String {
        if group.anyBtmDisallowed {
            return L10n.t("已被 macOS「系统设置 → 登录项与扩展」禁用，点击前往系统设置开启",
                          "Disallowed in macOS System Settings → Login Items & Extensions; click to open Settings")
        }
        if group.needsSystemSettings {
            return L10n.t("受 macOS 系统设置保护，点击前往「系统设置 → 登录项与扩展」管理",
                          "Protected by macOS System Settings; click to open Login Items & Extensions")
        }
        if group.anyBroken {
            return L10n.t("程序已不存在，请直接移入废纸篓", "Program missing; move to Trash")
        }
        if group.isLoginItem {
            return group.effectiveEnabled
                ? L10n.t("点击从登录项移除（立即生效）", "Click to remove from Login Items (immediate)")
                : L10n.t("点击重新加入登录项（立即生效）", "Click to add back to Login Items (immediate)")
        }
        if group.requiresAdmin {
            return group.effectiveEnabled
                ? L10n.t("点击停用系统服务（需要管理员密码，重启生效）", "Click to disable system service (requires admin password)")
                : L10n.t("点击启用系统服务（需要管理员密码，重启生效）", "Click to enable system service (requires admin password)")
        }
        return group.effectiveEnabled
            ? L10n.t("点击停用（重新登录生效）", "Click to disable (takes effect after re-login)")
            : L10n.t("点击启用（重新登录生效）", "Click to enable (takes effect after re-login)")
    }
}

private struct StartupChildRow: View {
    let item: StartupItem
    let isPending: Bool
    let onToggle: (Bool) -> Void
    let onRemoveBroken: () -> Void
    let onReveal: () -> Void
    let onCopyLabel: () -> Void
    let onOpenSettings: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(DS.font(12.5, .medium))
                        .foregroundStyle(DS.text2)
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

                Text(childSubtitle)
                    .font(DS.small)
                    .foregroundStyle(item.broken ? DS.danger : DS.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if hovering {
                HStack(spacing: 2) {
                    if !item.path.isEmpty {
                        DSIconButton("folder-open", help: L10n.t("在访达中显示", "Reveal in Finder"), size: 24, action: onReveal)
                    }
                    DSIconButton("copy", help: L10n.t("复制标识", "Copy Identifier"), size: 24, action: onCopyLabel)
                }
                .transition(.opacity)
            }

            if item.canRemoveBroken {
                DSButton(L10n.t("移入废纸篓", "Move to Trash"), icon: "trash-2", kind: .danger, action: onRemoveBroken)
            } else if isPending {
                ProgressView().controlSize(.small).frame(width: 36, height: 20)
            } else if item.canToggle {
                DSToggle(isOn: Binding(
                    get: { item.effectiveEnabled },
                    set: { onToggle($0) }
                ))
            } else if !item.broken {
                DSChip(
                    item.effectiveEnabled ? L10n.t("已启用", "Enabled") : L10n.t("已停用", "Disabled"),
                    tone: item.effectiveEnabled ? .success : .neutral
                )
                .onTapGesture { onOpenSettings() }
            }
        }
        .padding(.leading, 54)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(hovering ? DS.hover : DS.surface2.opacity(0.35))
        .animation(.easeOut(duration: 0.1), value: hovering)
        .onHover { hovering = $0 }
    }

    private var childSubtitle: String {
        if item.broken {
            let target = item.program ?? item.path
            return L10n.t("\(item.kind.title) · 缺失：\(target)", "\(item.kind.title) · Missing: \(target)")
        }
        var parts: [String] = [item.kind.title]
        if item.systemLevel {
            parts.append(L10n.t("影响所有用户", "All users"))
        }
        if !item.trigger.title.isEmpty {
            parts.append(item.trigger.title)
        }
        if let prog = item.program, !prog.isEmpty {
            parts.append(prog)
        } else if !item.path.isEmpty {
            parts.append(item.path)
        }
        return parts.joined(separator: " · ")
    }
}
