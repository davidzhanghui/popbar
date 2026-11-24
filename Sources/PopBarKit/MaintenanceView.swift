import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

@MainActor
final class MaintenanceViewModel: ObservableObject {
    enum TaskOutcome: Equatable {
        case success(at: Date, detail: String?)
        case cancelled
        case failure(String)
    }

    @Published var running: MaintenanceTask.ID?
    @Published var results: [MaintenanceTask.ID: TaskOutcome] = [:]
    @Published var snapshotState: SnapshotState = .loading
    @Published var spotlightState: SpotlightState = .loading
    @Published var isRefreshing = false
    @Published var confirming: MaintenanceTask?

    private let executor: MaintenanceExecutor
    private var loadTask: Task<Void, Never>?

    init(executor: MaintenanceExecutor = .live) {
        self.executor = executor
    }

    func load() {
        loadTask?.cancel()
        isRefreshing = true
        let exec = executor
        loadTask = Task {
            let (snaps, spot) = await Task.detached(priority: .utility) {
                (Maintenance.localSnapshotState(executor: exec), Maintenance.spotlightState(executor: exec))
            }.value
            guard !Task.isCancelled else { return }
            self.snapshotState = snaps
            self.spotlightState = spot
            self.isRefreshing = false
        }
    }

    func trigger(_ task: MaintenanceTask) {
        guard running == nil else { return }
        if task.confirmKind == .none {
            run(task)
        } else {
            confirming = task
        }
    }

    func run(_ task: MaintenanceTask, enableSpotlightIfDisabled: Bool = false) {
        guard running == nil else { return }
        running = task.id
        results[task.id] = nil
        let exec = executor
        let beforeCount: Int? = {
            if case .loaded(let c, _) = snapshotState { return c }
            return nil
        }()
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Maintenance.run(task.id,
                                enableSpotlightIfDisabled: enableSpotlightIfDisabled,
                                beforeSnapshotCount: beforeCount,
                                executor: exec)
            }.value
            self.running = nil
            switch result {
            case .success(let detail):
                self.results[task.id] = .success(at: Date(), detail: detail)
            case .cancelled:
                self.results[task.id] = .cancelled
            case .failure(let msg):
                self.results[task.id] = .failure(msg)
            }
            if task.id == .thinSnapshots || task.id == .reindexSpotlight {
                self.load()
            }
        }
    }
}

/// Deck「维护」页内容：只提供确有效果的维护操作；需要管理员权限的任务会弹出系统密码框。
struct MaintenanceView: View {
    @ObservedObject var vm: MaintenanceViewModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(Maintenance.tasks) { card($0) }
                rationaleCard
            }
        }
        .confirmationDialog(vm.confirming?.title ?? "",
                            isPresented: Binding(get: { vm.confirming != nil }, set: { if !$0 { vm.confirming = nil } }),
                            titleVisibility: .visible, presenting: vm.confirming) { task in
            if task.id == .reindexSpotlight, case .disabled = vm.spotlightState {
                Button(L10n.t("开启索引并重建", "Enable & Rebuild"), role: .destructive) {
                    vm.run(task, enableSpotlightIfDisabled: true)
                }
            } else if task.confirmKind == .destructive {
                Button(L10n.t("继续运行", "Run Anyway"), role: .destructive) { vm.run(task) }
            } else {
                Button(L10n.t("运行", "Run")) { vm.run(task) }
            }
            Button(L10n.t("取消", "Cancel"), role: .cancel) { vm.confirming = nil }
        } message: { task in
            if task.id == .reindexSpotlight, case .disabled = vm.spotlightState {
                Text(L10n.t("当前系统卷已关闭 Spotlight 索引。确认后将先开启索引，再触发后台重建。\n需要输入管理员密码。",
                            "Spotlight indexing is currently disabled on /. Confirming will enable indexing and start rebuilding.\nAdministrator password required."))
            } else {
                Text(task.detail + (task.needsAdmin ? L10n.t("\n需要输入管理员密码。", "\nAdministrator password required.") : ""))
            }
        }
    }

    private func card(_ task: MaintenanceTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            DSIconTile(task.icon, color: tileColor(for: task), size: 34)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(DS.font(13, .semibold))
                        .foregroundStyle(DS.text)
                    if task.needsAdmin {
                        Icon("lock", size: 11, color: DS.faint)
                            .help(L10n.t("需要管理员权限", "Needs admin rights"))
                            .accessibilityLabel(L10n.t("需要管理员权限", "Requires administrator privileges"))
                    }
                    statusBadge(for: task)
                }

                Text(task.detail)
                    .font(DS.caption)
                    .foregroundStyle(DS.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let outcome = vm.results[task.id] {
                    outcomeView(outcome)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            Group {
                if vm.running == task.id {
                    ProgressView().controlSize(.small)
                        .frame(width: 60, height: 30)
                } else {
                    DSButton(L10n.t("运行", "Run"), kind: .secondary) {
                        vm.trigger(task)
                    }
                    .disabled(isDisabled(task))
                }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCardBackground()
    }

    @ViewBuilder
    private func statusBadge(for task: MaintenanceTask) -> some View {
        switch task.id {
        case .thinSnapshots:
            switch vm.snapshotState {
            case .loading:
                DSChip(L10n.t("读取中…", "Loading…"), tone: .neutral)
            case .loaded(let count, let latest):
                let label = L10n.t(
                    "本地快照 \(count) 个",
                    count == 1 ? "1 local snapshot" : "\(count) local snapshots"
                )
                let text = latest.map { L10n.t("\(label)（最新 \($0)）", "\(label) (latest \($0))") } ?? label
                DSChip(text, tone: count > 0 ? .accent : .neutral)
            case .failed(let err):
                DSChip(L10n.t("读取失败", "Read failed"), tone: .warning)
                    .help(err)
            }
        case .reindexSpotlight:
            switch vm.spotlightState {
            case .loading:
                DSChip(L10n.t("检测中…", "Checking…"), tone: .neutral)
            case .enabled:
                DSChip(L10n.t("索引已启用", "Indexing on"), tone: .success)
            case .disabled:
                DSChip(L10n.t("索引已禁用", "Indexing off"), tone: .warning)
            case .failed(let err):
                DSChip(L10n.t("状态未知", "Status unknown"), tone: .neutral)
                    .help(err)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func outcomeView(_ outcome: MaintenanceViewModel.TaskOutcome) -> some View {
        let (text, color): (String, Color) = {
            switch outcome {
            case .success(let at, let detail):
                let time = at.formatted(date: .omitted, time: .shortened)
                let prefix = L10n.t("已完成 · \(time)", "Done · \(time)")
                if let detail, !detail.isEmpty {
                    return ("\(prefix) — \(detail)", DS.success)
                }
                return (prefix, DS.success)
            case .cancelled:
                return (L10n.t("已取消管理员授权", "Administrator authorization cancelled"), DS.muted)
            case .failure(let msg):
                return (L10n.t("失败：\(msg)", "Failed: \(msg)"), DS.danger)
            }
        }()
        Text(text)
            .font(DS.small)
            .foregroundStyle(color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var rationaleCard: some View {
        DSCard(padding: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Icon("info", size: 13, color: DS.muted)
                    Text(L10n.t("为什么没有「释放内存」「修复磁盘权限」", "Why no “Free Memory” or “Repair Permissions”"))
                        .font(DS.font(12.5, .semibold))
                        .foregroundStyle(DS.text)
                }
                Text(L10n.t("macOS 会自动管理内存，强行「释放」只是短暂制造内存压力，随后系统又会把缓存装回来；「修复权限」会重置家目录的访问控制，风险大于收益；周期维护脚本 (periodic) 在新版 macOS 中已移除。",
                            "macOS manages memory itself — forcing a “free” only causes brief memory pressure before caches reload. “Repair permissions” resets home-folder access control, which risks more than it helps. The periodic maintenance scripts were removed in recent macOS."))
                    .font(DS.small)
                    .foregroundStyle(DS.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isDisabled(_ task: MaintenanceTask) -> Bool {
        if vm.running != nil { return true }
        if task.id == .thinSnapshots, case .loaded(let count, _) = vm.snapshotState, count == 0 {
            return true
        }
        return false
    }

    private func tileColor(for task: MaintenanceTask) -> Color {
        switch task.id {
        case .flushDNS: return Color(nsColor: IconPalette.sky)
        case .thinSnapshots: return Color(nsColor: IconPalette.amber)
        case .reindexSpotlight: return DS.accent
        case .rebuildLaunchServices: return Color(nsColor: IconPalette.blue)
        case .resetQuickLook: return Color(nsColor: IconPalette.green)
        case .restartFinderAndDock: return Color(nsColor: IconPalette.slate)
        case .restartAudio: return Color(nsColor: IconPalette.pink)
        case .clearFontCache: return Color(nsColor: IconPalette.purple)
        }
    }
}
