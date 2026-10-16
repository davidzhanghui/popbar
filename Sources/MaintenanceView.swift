import SwiftUI

@MainActor
final class MaintenanceViewModel: ObservableObject {
    @Published var running: MaintenanceTask.ID?
    @Published var results: [MaintenanceTask.ID: String] = [:]
    @Published var snapshotCount = 0
    @Published var confirming: MaintenanceTask?

    func load() {
        Task.detached(priority: .utility) {
            let n = Maintenance.localSnapshotCount()
            await MainActor.run { self.snapshotCount = n }
        }
    }

    func run(_ task: MaintenanceTask) {
        guard running == nil else { return }
        running = task.id
        Task.detached(priority: .userInitiated) {
            let err = Maintenance.run(task.id)
            await MainActor.run {
                self.running = nil
                self.results[task.id] = err.map { L10n.t("失败:", "Failed: ") + $0 }
                    ?? L10n.t("已完成 · ", "Done · ") + Date().formatted(date: .omitted, time: .shortened)
                if task.id == .thinSnapshots { self.load() }
            }
        }
    }
}

/// 菜单栏「系统维护」:只提供确有效果的维护操作;需要管理员权限的任务会弹出系统密码框。
struct MaintenanceView: View {
    @ObservedObject var vm: MaintenanceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("只提供确有效果的维护操作;需要管理员权限的任务会弹出系统密码框",
                        "Only maintenance that actually helps. Tasks needing admin rights show the system password prompt."))
                .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                .padding(.horizontal, 4)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(Maintenance.tasks) { card($0) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t("为什么没有「释放内存」「修复磁盘权限」", "Why no “Free Memory” or “Repair Permissions”"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(L10n.t("macOS 会自动管理内存,强行「释放」只是短暂制造内存压力,随后系统又会把缓存装回来;「修复权限」会重置家目录的访问控制,风险大于收益;周期维护脚本 (periodic) 在新版 macOS 中已移除。",
                                    "macOS manages memory itself — forcing a “free” only causes brief memory pressure before caches reload. “Repair permissions” resets home-folder access control, which risks more than it helps. The periodic maintenance scripts were removed in recent macOS."))
                            .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(CardBackground())
                }
            }
        }
        .confirmationDialog(vm.confirming?.title ?? "",
                            isPresented: Binding(get: { vm.confirming != nil }, set: { if !$0 { vm.confirming = nil } }),
                            titleVisibility: .visible, presenting: vm.confirming) { task in
            Button(L10n.t("运行", "Run")) { vm.run(task) }
        } message: { task in
            Text(task.detail + (task.needsAdmin ? L10n.t("\n需要输入管理员密码。", "\nAdministrator password required.") : ""))
        }
    }

    private func card(_ task: MaintenanceTask) -> some View {
        HStack(spacing: 12) {
            Image(systemName: task.symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white).frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(PanelTheme.brandColor))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title).font(.system(size: 13, weight: .semibold))
                    if task.needsAdmin {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(SysTheme.tertiary)
                            .help(L10n.t("需要管理员权限", "Needs admin rights"))
                    }
                    if task.id == .thinSnapshots {
                        Text(L10n.t("本地快照 \(vm.snapshotCount) 个", "\(vm.snapshotCount) local snapshots"))
                            .font(.system(size: 10)).foregroundStyle(SysTheme.secondary)
                    }
                }
                Text(task.detail).font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let r = vm.results[task.id] {
                    Text(r).font(.system(size: 10.5)).foregroundStyle(SysTheme.brand)
                }
            }
            Spacer(minLength: 6)
            if vm.running == task.id {
                ProgressView().controlSize(.small)
            } else {
                let disabled = vm.running != nil || (task.id == .thinSnapshots && vm.snapshotCount == 0)
                Button(L10n.t("运行", "Run")) { vm.confirming = task }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SysTheme.brand)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Capsule().fill(SysTheme.track))
                    .opacity(disabled ? 0.4 : 1).disabled(disabled)
            }
        }
        .padding(10)
        .background(CardBackground())
    }
}
