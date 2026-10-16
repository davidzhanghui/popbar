import SwiftUI

@MainActor
final class StartupViewModel: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var loaded = false
    @Published var message: String?
    @Published var query = ""

    var filtered: [StartupItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? items : items.filter { $0.label.localizedCaseInsensitiveContains(q) }
    }

    func load() {
        Task.detached(priority: .utility) {
            let list = StartupItems.scan()
            await MainActor.run { self.items = list; self.loaded = true }
        }
    }

    func set(_ item: StartupItem, enabled: Bool) {
        Task.detached(priority: .userInitiated) {
            let ok = StartupItems.setEnabled(item, enabled)
            await MainActor.run {
                if ok {
                    if let i = self.items.firstIndex(where: { $0.id == item.id }) { self.items[i].enabled = enabled }
                    self.message = enabled
                        ? L10n.t("已启用 \(item.label)(重新登录生效)", "Enabled \(item.label) (takes effect after re-login)")
                        : L10n.t("已停用 \(item.label)(重新登录生效)", "Disabled \(item.label) (takes effect after re-login)")
                } else {
                    self.message = L10n.t("修改失败:\(item.label)", "Failed to change \(item.label)")
                }
            }
        }
    }

    /// 损坏的用户级启动代理:移入废纸篓(可恢复)
    func removeBroken(_ item: StartupItem) {
        guard item.broken, !item.systemLevel else { return }
        Task.detached(priority: .userInitiated) {
            let r = CleanTrash.trash(URL(fileURLWithPath: item.path))
            await MainActor.run {
                switch r {
                case .success:
                    self.items.removeAll { $0.id == item.id }
                    self.message = L10n.t("已移除损坏的启动代理 \(item.label)", "Removed broken launch agent \(item.label)")
                case .failure(let e):
                    self.message = L10n.t("移除失败:", "Remove failed: ") + CleanTrash.reason(for: e)
                }
            }
        }
    }
}

/// 菜单栏「启动项」:用户级 LaunchAgent 可开关(重新登录生效),系统级仅展示。
/// 进程占用榜已由「系统监控」承担,这里不重复。
struct StartupView: View {
    @ObservedObject var vm: StartupViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("\(vm.items.count) 项登录项与后台服务", "\(vm.items.count) login items & background services"))
                        .font(.system(size: 15, weight: .bold))
                    Text(L10n.t("用户级 LaunchAgent 可开关(重新登录生效) · 系统级仅展示",
                                "User LaunchAgents can be toggled (after re-login) · system-level items are read-only"))
                        .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                }
                Spacer()
                Button { vm.load() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26).background(Circle().fill(SysTheme.track))
                }
                .buttonStyle(.plain).help(L10n.t("刷新", "Refresh"))
            }
            .padding(.horizontal, 4)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(SysTheme.tertiary)
                TextField(L10n.t("搜索", "Search"), text: $vm.query).textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SysTheme.track))

            ScrollView {
                LazyVStack(spacing: 0) {
                    if vm.loaded && vm.filtered.isEmpty {
                        Text(L10n.t("没有找到登录项与后台服务", "No login items or background services found"))
                            .font(.system(size: 12)).foregroundStyle(SysTheme.secondary).padding(30)
                    }
                    ForEach(vm.filtered) { row($0) }
                }
            }
            .background(CardBackground())

            if let m = vm.message {
                Text(m).font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
        }
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == "LaunchDaemon" ? "gearshape.fill" : "bolt.fill")
                .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SysTheme.track))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                Text(item.broken ? L10n.t("\(item.kind) · 程序不存在:", "\(item.kind) · program missing: ") + (item.program ?? "")
                     : item.systemLevel ? item.kind + L10n.t(" · 系统级", " · system") : item.kind)
                    .font(.system(size: 10.5))
                    .foregroundStyle(item.broken ? Color.orange : SysTheme.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if item.broken && !item.systemLevel {
                Button(L10n.t("移除", "Remove")) { vm.removeBroken(item) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(SysTheme.brand)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(SysTheme.track))
                    .help(L10n.t("指向的程序已不存在,移入废纸篓", "The program is gone; move the plist to the Trash"))
            }
            if item.systemLevel {
                Text(L10n.t("受保护", "Protected")).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SysTheme.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(SysTheme.track))
            }
            Toggle("", isOn: Binding(get: { item.enabled }, set: { vm.set(item, enabled: $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().disabled(item.systemLevel)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

enum ToolPanels {
    @MainActor static let maintenanceModel = MaintenanceViewModel()
    @MainActor static let startupModel = StartupViewModel()

    @MainActor static let maintenance = ToolPanel(
        title: L10n.t("系统维护", "Maintenance"), symbol: "wrench.and.screwdriver",
        size: NSSize(width: 600, height: 640),
        onShow: { maintenanceModel.load() },
        content: { AnyView(MaintenanceView(vm: maintenanceModel)) })

    @MainActor static let startup = ToolPanel(
        title: L10n.t("启动项", "Startup Items"), symbol: "power",
        size: NSSize(width: 600, height: 640),
        onShow: { startupModel.load() },
        content: { AnyView(StartupView(vm: startupModel)) })
}
