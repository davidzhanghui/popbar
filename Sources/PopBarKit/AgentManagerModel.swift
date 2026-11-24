import Cocoa
import Foundation
import PopBarCore
import PopBarDesign

/// Agent 管理视图模型：维护三个 Agent CLI 的版本、自动更新调度与实时进程列表。
@MainActor
final class AgentManagerModel: ObservableObject {
    static let stateChanged = Notification.Name("PopBarAgentManagerStateChanged")

    @Published var states: [AgentCLIState] = AgentKind.allCases.map { AgentCLIState(kind: $0) }
    @Published var processes: [AgentProcessItem] = []
    @Published var isRefreshing = false
    @Published var hasLoaded = false
    @Published var autoUpdate: Bool
    @Published var lastCheckAt: Date?
    @Published var banner: (text: String, tone: DSTone)?
    @Published var terminatingIDs: Set<String> = []
    @Published var expandedLogKinds: Set<AgentKind> = []

    /// 进程采样定时器（仅页面打开时运行）
    private var processTimer: Timer?
    /// 后台自动更新轮询定时器（仅开启自动更新且模块启用时运行，每 15 分钟检查是否到期）
    private var autoUpdateTimer: Timer?
    private var isPageVisible = false
    private var isProcessScanning = false
    private var activeUpdateKinds: Set<AgentKind> = []
    private var refreshTask: Task<Void, Never>?
    private let cpuSampler = AgentCPUSamplerBox()

    init() {
        let cfg = ConfigStore.shared.config.agent
        self.autoUpdate = cfg.autoUpdate
        self.lastCheckAt = cfg.lastCheckAt.map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: - 统计属性

    var installedCount: Int { states.filter(\.installed).count }
    var updatableStates: [AgentCLIState] { states.filter { $0.hasUpdate && !$0.actionState.isBusy } }
    var updatableCount: Int { states.filter(\.hasUpdate).count }
    var runningProcessCount: Int { processes.count }
    var totalProcessMemory: UInt64 { processes.reduce(0) { $0 + $1.memoryBytes } }
    var isAnyUpdating: Bool { !activeUpdateKinds.isEmpty }

    /// 侧栏角标：优先提示运行中的进程数；没有运行进程但有可更新 CLI 时显示可更新数
    var sidebarBadge: Int? {
        if runningProcessCount > 0 { return runningProcessCount }
        if updatableCount > 0 { return updatableCount }
        return nil
    }

    func processCount(for kind: AgentKind) -> Int {
        processes.filter { $0.kind == kind }.count
    }

    // MARK: - 生命周期

    func startModule() {
        syncConfigFromStore()
        rescheduleAutoUpdateTimer()
        if autoUpdate {
            triggerAutoUpdateCheckIfDue()
        }
    }

    func stopModule() {
        stopProcessTimer()
        autoUpdateTimer?.invalidate()
        autoUpdateTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func pageDidAppear() {
        isPageVisible = true
        syncConfigFromStore()
        scanProcessesOnce()
        startProcessTimer()

        let needsRemoteCheck = !hasLoaded
            || AgentUpdatePolicy.shouldCheck(lastCheck: lastCheckAt, intervalHours: 1)
        refreshAll(checkRemote: needsRemoteCheck, triggerAutoUpdate: autoUpdate)
    }

    func pageDidDisappear() {
        isPageVisible = false
        stopProcessTimer()
    }

    // MARK: - 配置与自动更新

    func setAutoUpdate(_ enabled: Bool) {
        guard autoUpdate != enabled else { return }
        autoUpdate = enabled
        var cfg = ConfigStore.shared.config
        cfg.agent.autoUpdate = enabled
        try? ConfigStore.shared.save(cfg)
        rescheduleAutoUpdateTimer()
        if enabled {
            banner = (L10n.t("已开启自动下载更新，将在后台定期检查并升级已安装的 Agent CLI。",
                             "Auto-update enabled. Installed Agent CLIs will be checked and updated automatically."), .success)
            // 如果当前已经发现有更新，立即执行后台更新
            if !updatableStates.isEmpty {
                updateAllAvailable(isAutomatic: true)
            } else {
                refreshAll(checkRemote: true, triggerAutoUpdate: true)
            }
        } else {
            banner = (L10n.t("已关闭自动下载更新，仍可随时手动检查与更新。",
                             "Auto-update turned off. You can still check and update manually anytime."), .neutral)
        }
    }

    private func syncConfigFromStore() {
        let cfg = ConfigStore.shared.config.agent
        if autoUpdate != cfg.autoUpdate { autoUpdate = cfg.autoUpdate }
        if let ts = cfg.lastCheckAt {
            let d = Date(timeIntervalSince1970: ts)
            if lastCheckAt != d { lastCheckAt = d }
        }
    }

    private func persistLastCheck(_ date: Date) {
        lastCheckAt = date
        var cfg = ConfigStore.shared.config
        cfg.agent.lastCheckAt = date.timeIntervalSince1970
        try? ConfigStore.shared.save(cfg)
    }

    private func rescheduleAutoUpdateTimer() {
        autoUpdateTimer?.invalidate()
        autoUpdateTimer = nil
        guard autoUpdate else { return }
        autoUpdateTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerAutoUpdateCheckIfDue()
            }
        }
    }

    private func triggerAutoUpdateCheckIfDue() {
        let interval = ConfigStore.shared.config.agent.checkIntervalHours
        guard AgentUpdatePolicy.shouldCheck(lastCheck: lastCheckAt, intervalHours: interval) else { return }
        refreshAll(checkRemote: true, triggerAutoUpdate: true)
    }

    // MARK: - 检测与版本刷新

    func refreshAll(checkRemote: Bool = true, triggerAutoUpdate: Bool = false) {
        refreshTask?.cancel()
        isRefreshing = true
        banner = nil
        scanProcessesOnce()

        refreshTask = Task { [weak self] in
            guard let self else { return }

            // 第一阶段：并发探测本地安装状态与当前版本（快）
            let localStates = await Task.detached(priority: .userInitiated) {
                AgentKind.allCases.map { AgentRuntime.inspectLocal($0) }
            }.value
            guard !Task.isCancelled else { return }

            for local in localStates {
                if let idx = self.states.firstIndex(where: { $0.kind == local.kind }) {
                    let prev = self.states[idx]
                    var merged = local
                    merged.latestVersion = prev.latestVersion
                    merged.latestSource = prev.latestSource
                    merged.latestDownloadURL = prev.latestDownloadURL
                    merged.latestCheckError = prev.latestCheckError
                    merged.lastCheckedAt = prev.lastCheckedAt
                    merged.lastOutput = prev.lastOutput
                    if self.activeUpdateKinds.contains(local.kind) {
                        merged.actionState = prev.actionState
                    }
                    self.states[idx] = merged
                }
            }
            self.hasLoaded = true
            self.notifyChanged()

            guard checkRemote else {
                self.isRefreshing = false
                return
            }

            // 第二阶段：并发请求三个 Agent 的远程最新版本
            for idx in self.states.indices where !self.activeUpdateKinds.contains(self.states[idx].kind) {
                self.states[idx].actionState = .checking
            }

            let remoteResults = await withTaskGroup(of: (AgentKind, Result<AgentLatestVersion, Error>).self) { group in
                for kind in AgentKind.allCases {
                    group.addTask {
                        let res = await AgentRuntime.fetchLatestVersion(for: kind)
                        return (kind, res)
                    }
                }
                var out: [AgentKind: Result<AgentLatestVersion, Error>] = [:]
                for await (kind, res) in group {
                    out[kind] = res
                }
                return out
            }
            guard !Task.isCancelled else { return }

            let now = Date()
            var anySuccess = false
            for idx in self.states.indices {
                let kind = self.states[idx].kind
                if !self.activeUpdateKinds.contains(kind) {
                    self.states[idx].actionState = .idle
                }
                guard let result = remoteResults[kind] else { continue }
                switch result {
                case .success(let latest):
                    anySuccess = true
                    self.states[idx].latestVersion = latest.version
                    self.states[idx].latestSource = latest.source
                    self.states[idx].latestDownloadURL = latest.downloadURL
                    self.states[idx].latestCheckError = nil
                    self.states[idx].lastCheckedAt = now
                case .failure(let err):
                    self.states[idx].latestCheckError = err.localizedDescription
                }
            }

            if anySuccess {
                self.persistLastCheck(now)
            }
            self.isRefreshing = false
            self.notifyChanged()

            if triggerAutoUpdate && self.autoUpdate && !self.updatableStates.isEmpty {
                self.updateAllAvailable(isAutomatic: true)
            }
        }
    }

    func checkSingle(_ kind: AgentKind) {
        guard !activeUpdateKinds.contains(kind) else { return }
        updateState(kind) { $0.actionState = .checking; $0.latestCheckError = nil }

        Task { [weak self] in
            guard let self else { return }
            let local = await Task.detached(priority: .userInitiated) {
                AgentRuntime.inspectLocal(kind)
            }.value
            let remote = await AgentRuntime.fetchLatestVersion(for: kind)
            let now = Date()

            self.updateState(kind) { s in
                s.installed = local.installed
                s.executablePath = local.executablePath
                s.resolvedPath = local.resolvedPath
                s.installMethod = local.installMethod
                s.currentVersionRaw = local.currentVersionRaw
                s.currentVersion = local.currentVersion
                if !self.activeUpdateKinds.contains(kind) {
                    s.actionState = .idle
                }
                switch remote {
                case .success(let latest):
                    s.latestVersion = latest.version
                    s.latestSource = latest.source
                    s.latestDownloadURL = latest.downloadURL
                    s.latestCheckError = nil
                    s.lastCheckedAt = now
                case .failure(let err):
                    s.latestCheckError = err.localizedDescription
                }
            }
            self.notifyChanged()
        }
    }

    // MARK: - 更新与安装

    func updateOrInstall(_ kind: AgentKind, isAutomatic: Bool = false) {
        guard !activeUpdateKinds.contains(kind),
              let snapshot = states.first(where: { $0.kind == kind }) else { return }
        activeUpdateKinds.insert(kind)

        let wasInstalled = snapshot.installed
        updateState(kind) {
            $0.actionState = wasInstalled ? .updating : .installing
            $0.latestCheckError = nil
        }

        Task { [weak self] in
            guard let self else { return }
            let cmdResult = await Task.detached(priority: .userInitiated) {
                AgentRuntime.updateOrInstall(snapshot)
            }.value

            // 更新/安装完成后重新探测本地版本
            let refreshedLocal = await Task.detached(priority: .userInitiated) {
                AgentRuntime.inspectLocal(kind)
            }.value

            self.activeUpdateKinds.remove(kind)

            let logText: String = {
                var lines = ["$ \(cmdResult.commandDisplay)"]
                if !cmdResult.output.isEmpty { lines.append(cmdResult.output) }
                if let err = cmdResult.errorMessage, !err.isEmpty, !cmdResult.output.contains(err) {
                    lines.append(err)
                }
                return lines.joined(separator: "\n")
            }()

            self.updateState(kind) { s in
                s.installed = refreshedLocal.installed
                s.executablePath = refreshedLocal.executablePath
                s.resolvedPath = refreshedLocal.resolvedPath
                s.installMethod = refreshedLocal.installMethod
                s.currentVersionRaw = refreshedLocal.currentVersionRaw
                s.currentVersion = refreshedLocal.currentVersion
                s.lastOutput = logText
                if cmdResult.ok {
                    let msg = wasInstalled
                        ? L10n.t("已更新至 \(s.currentVersionText)", "Updated to \(s.currentVersionText)")
                        : L10n.t("已安装 \(s.currentVersionText)", "Installed \(s.currentVersionText)")
                    s.actionState = .updated(msg)
                } else {
                    s.actionState = .failed(cmdResult.errorMessage ?? L10n.t("执行失败", "Command failed"))
                    self.expandedLogKinds.insert(kind)
                }
            }

            if cmdResult.ok {
                let prefix = isAutomatic ? L10n.t("自动更新完成：", "Auto-update finished: ") : ""
                let ver = self.states.first(where: { $0.kind == kind })?.currentVersionText ?? ""
                self.banner = ("\(prefix)\(kind.displayName) \(ver)", .success)
            } else {
                let reason = cmdResult.errorMessage ?? L10n.t("执行失败", "Command failed")
                self.banner = (L10n.t("\(kind.displayName) 更新失败：\(reason)", "\(kind.displayName) update failed: \(reason)"), .danger)
            }

            self.scanProcessesOnce()
            self.notifyChanged()
        }
    }

    func updateAllAvailable(isAutomatic: Bool = false) {
        var targets = updatableStates.map(\.kind)
        // 后台自动更新时，如果 Claude Desktop 正在运行则跳过，避免突然关掉用户正在使用的桌面窗口
        if isAutomatic {
            let desktopRunning = processes.contains { $0.kind == .claudeDesktop && $0.role == .desktopApp }
                || !NSRunningApplication.runningApplications(withBundleIdentifier: AgentRuntime.claudeDesktopBundleID).isEmpty
            if desktopRunning {
                targets.removeAll { $0 == .claudeDesktop }
            }
        }
        guard !targets.isEmpty else { return }
        for kind in targets {
            updateOrInstall(kind, isAutomatic: isAutomatic)
        }
    }

    // MARK: - 进程监控与管理

    private func startProcessTimer() {
        stopProcessTimer()
        processTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPageVisible else { return }
                self.scanProcessesOnce()
            }
        }
    }

    private func stopProcessTimer() {
        processTimer?.invalidate()
        processTimer = nil
    }

    func scanProcessesOnce() {
        guard !isProcessScanning else { return }
        isProcessScanning = true
        let sampler = cpuSampler
        Task { [weak self] in
            let list = await Task.detached(priority: .utility) {
                sampler.scan()
            }.value
            guard let self else { return }
            let oldCount = self.processes.count
            self.processes = list
            self.isProcessScanning = false
            if oldCount != list.count {
                self.notifyChanged()
            }
        }
    }

    func stopProcess(_ item: AgentProcessItem, force: Bool = false) {
        guard !terminatingIDs.contains(item.id) else { return }
        terminatingIDs.insert(item.id)

        Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                AgentRuntime.terminateProcess(item, force: force)
            }.value

            // 给进程一点退出缓冲再刷新列表
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.terminatingIDs.remove(item.id)
            self.scanProcessesOnce()

            switch result {
            case .success:
                self.banner = (
                    force
                        ? L10n.t("已强制结束 \(item.kind.displayName)（PID \(item.pid)）",
                                 "Force stopped \(item.kind.displayName) (PID \(item.pid))")
                        : L10n.t("已发送结束信号至 \(item.kind.displayName)（PID \(item.pid)）",
                                 "Sent stop signal to \(item.kind.displayName) (PID \(item.pid))"),
                    .success
                )
            case .failure(let err):
                self.banner = (err.localizedDescription, .danger)
            }
        }
    }

    // MARK: - 快捷工具

    func revealInFinder(_ path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func copyText(_ text: String, notice: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        banner = (notice, .neutral)
    }

    func openHomepage(_ kind: AgentKind) {
        NSWorkspace.shared.open(kind.homepageURL)
    }

    func launchApp(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }

    func toggleLog(_ kind: AgentKind) {
        if expandedLogKinds.contains(kind) {
            expandedLogKinds.remove(kind)
        } else {
            expandedLogKinds.insert(kind)
        }
    }

    // MARK: - 内部

    private func updateState(_ kind: AgentKind, _ mutate: (inout AgentCLIState) -> Void) {
        guard let idx = states.firstIndex(where: { $0.kind == kind }) else { return }
        mutate(&states[idx])
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.stateChanged, object: nil)
    }
}

/// 线程安全的 CPU 差值采样器封装
private final class AgentCPUSamplerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state = AgentRuntime.CPUSampleState()

    func scan() -> [AgentProcessItem] {
        lock.lock()
        defer { lock.unlock() }
        return AgentRuntime.scanProcesses(cpuState: &state)
    }
}
