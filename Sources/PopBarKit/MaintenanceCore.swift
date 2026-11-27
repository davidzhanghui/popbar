import Foundation
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 维护任务：只做有实际效果的；不做「释放内存」「修复磁盘权限」这类收益小于风险的项目。
struct MaintenanceTask: Identifiable, Hashable {
    enum ID: String, CaseIterable {
        case flushDNS
        case thinSnapshots
        case reindexSpotlight
        case rebuildLaunchServices
        case resetQuickLook
        case restartFinderAndDock
        case restartAudio
        case clearFontCache
    }

    enum ConfirmKind: Equatable, Hashable {
        case none
        case standard
        case destructive
    }

    let id: ID
    let title: String
    let detail: String
    let needsAdmin: Bool
    let icon: String
    let confirmKind: ConfirmKind
}

/// 命令执行器抽象：生产默认走 `ShellRun`，单测可注入无副作用替身。
struct MaintenanceExecutor {
    var run: (String, [String], TimeInterval) -> ShellRun.Result
    var runAsAdmin: (String, String?, TimeInterval) -> AdminRunResult
    var currentUser: String = NSUserName()

    static let live = MaintenanceExecutor(
        run: { path, args, timeout in ShellRun.run(path, args, timeout: timeout) },
        runAsAdmin: { shell, prompt, timeout in ShellRun.runAsAdminResult(shell, prompt: prompt, timeout: timeout) }
    )
}

enum SnapshotState: Equatable {
    case loading
    case loaded(count: Int, latestDate: String?)
    case failed(String)
}

enum SpotlightState: Equatable {
    case loading
    case enabled
    case disabled
    case failed(String)
}

enum MaintenanceRunResult: Equatable {
    case success(detail: String?)
    case cancelled
    case failure(String)
}

enum Maintenance {
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    static var tasks: [MaintenanceTask] {
        [
            .init(id: .flushDNS,
                  title: L10n.t("刷新 DNS 缓存", "Flush DNS Cache"),
                  detail: L10n.t("网站打不开、解析到旧地址时使用。清空本机 DNS 缓存并通知 mDNSResponder 刷新。",
                                 "For sites that won't load or resolve to a stale address. Clears the DNS cache and signals mDNSResponder to reload."),
                  needsAdmin: true, icon: "globe", confirmKind: .none),
            .init(id: .thinSnapshots,
                  title: L10n.t("精简 Time Machine 本地快照", "Thin Time Machine Local Snapshots"),
                  detail: L10n.t("删除本机磁盘上的 Time Machine 本地快照以释放空间，不影响备份盘上的备份。",
                                 "Deletes local Time Machine snapshots on this disk to free space. Backups on the backup drive are untouched."),
                  needsAdmin: true, icon: "history", confirmKind: .destructive),
            .init(id: .reindexSpotlight,
                  title: L10n.t("重建 Spotlight 索引", "Rebuild Spotlight Index"),
                  detail: L10n.t("搜索结果缺失或异常时使用（仅重建系统启动卷）。重建期间搜索暂时不可用，CPU 占用会升高一段时间。",
                                 "For missing or odd search results (startup volume only). Search is unavailable and CPU usage rises while it rebuilds."),
                  needsAdmin: true, icon: "search", confirmKind: .destructive),
            .init(id: .rebuildLaunchServices,
                  title: L10n.t("整理「打开方式」数据库", "Tidy the “Open With” Database"),
                  detail: L10n.t("右键「打开方式」出现重复或已删除的应用时使用（清理旧关联并重扫应用目录）。",
                                 "For duplicate or deleted apps in the “Open With” menu (garbage-collects stale records and re-scans apps)."),
                  needsAdmin: false, icon: "layers", confirmKind: .none),
            .init(id: .resetQuickLook,
                  title: L10n.t("重置快速查看缓存", "Reset Quick Look Cache"),
                  detail: L10n.t("空格预览显示旧缩略图或无法预览时使用（重载生成器并清空缩略图缓存）。",
                                 "For stale thumbnails or failing Space-bar previews (reloads generators and clears thumbnail cache)."),
                  needsAdmin: false, icon: "eye", confirmKind: .none),
            .init(id: .restartFinderAndDock,
                  title: L10n.t("重启访达与程序坞", "Restart Finder & Dock"),
                  detail: L10n.t("访达假死、右键菜单未刷新或程序坞动画卡顿时使用。请先确认没有正在进行的文件拷贝或移动，访达窗口会尝试重新打开。",
                                 "Fixes unresponsive Finder, stale context menus or Dock glitches. Make sure no file copies or moves are in progress; Finder windows will attempt to reopen."),
                  needsAdmin: false, icon: "app-window-mac", confirmKind: .standard),
            .init(id: .restartAudio,
                  title: L10n.t("重启系统音频服务", "Restart Audio Service"),
                  detail: L10n.t("外接显示器、蓝牙耳机或休眠唤醒后无声/声道异常时使用。会中断当前音频播放、通话或录音，系统会自动拉起 coreaudiod。",
                                 "Fixes missing audio or routing glitches after sleep or switching devices. Interrupts active playback, calls or recordings; launchd restarts coreaudiod automatically."),
                  needsAdmin: true, icon: "volume-2", confirmKind: .standard),
            .init(id: .clearFontCache,
                  title: L10n.t("清理用户字体缓存", "Clear User Font Cache"),
                  detail: L10n.t("系统或办公软件出现字体乱码、缺失或排版错位时使用（建议注销或重启生效）。",
                                 "Fixes garbled, missing or misaligned fonts in apps (log out or restart to fully take effect)."),
                  needsAdmin: false, icon: "type", confirmKind: .none),
        ]
    }

    // MARK: - 纯解析函数

    /// 解析 `tmutil listlocalsnapshots /` 输出：仅统计 Time Machine 快照，跳过系统更新快照，并提取最新时间戳。
    static func parseLocalSnapshots(_ output: String) -> (count: Int, latestDate: String?) {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains("com.apple.TimeMachine") }
        guard !lines.isEmpty else { return (0, nil) }

        var latest: String?
        for line in lines {
            if let stamp = extractSnapshotDate(from: line) {
                if latest == nil || stamp > latest! { latest = stamp }
            }
        }
        return (lines.count, latest)
    }

    private static func extractSnapshotDate(from line: String) -> String? {
        // 形如 com.apple.TimeMachine.2026-11-24-081530.local
        guard let r = line.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        let raw = String(line[r]) // 2026-11-24-081530
        let parts = raw.split(separator: "-")
        guard parts.count == 4, parts[3].count == 6 else { return nil }
        let hh = parts[3].prefix(2)
        let mm = parts[3].dropFirst(2).prefix(2)
        return "\(parts[0])-\(parts[1])-\(parts[2]) \(hh):\(mm)"
    }

    /// 解析 `tmutil thinlocalsnapshots` 的 stdout 中被删除的快照数量。
    /// 同时兼容 `\r`/`\n` 分隔以及完整快照名（`com.apple.TimeMachine.…`）或纯时间戳行（`YYYY-MM-DD-HHMMSS`）。
    static func parseThinnedSnapshotCount(_ output: String) -> Int {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                line.contains("com.apple.TimeMachine")
                    || line.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil
            }
            .count
    }

    /// 解析 `mdutil -s /`、`mdutil -i on /` 或 `mdutil -E /` 的索引开关状态。
    /// 逆序取最后一条明确的状态行，并同时识别 `Indexing disabled` 与 `Indexing and searching disabled`（含 `.metadata_never_index`）。
    static func parseSpotlightEnabled(_ output: String) -> Bool? {
        for rawLine in output.split(whereSeparator: \.isNewline).reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.localizedCaseInsensitiveContains("Indexing and searching disabled")
                || line.localizedCaseInsensitiveContains("Indexing disabled") {
                return false
            }
            if line.localizedCaseInsensitiveContains("Indexing enabled") {
                return true
            }
        }
        return nil
    }

    // MARK: - 只读探测

    static func localSnapshotState(executor: MaintenanceExecutor = .live) -> SnapshotState {
        let r = executor.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], 30)
        guard r.status == 0 else {
            let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(msg.isEmpty ? L10n.t("读取快照失败", "Failed to read snapshots") : msg)
        }
        let parsed = parseLocalSnapshots(r.out)
        return .loaded(count: parsed.count, latestDate: parsed.latestDate)
    }

    static func spotlightState(executor: MaintenanceExecutor = .live) -> SpotlightState {
        let r = executor.run("/usr/bin/mdutil", ["-s", "/"], 15)
        let combined = r.out + "\n" + r.err
        if let enabled = parseSpotlightEnabled(combined) {
            return enabled ? .enabled : .disabled
        }
        if r.status != 0 {
            let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(msg.isEmpty ? L10n.t("读取索引状态失败", "Failed to read Spotlight status") : msg)
        }
        return .failed(L10n.t("无法识别索引状态", "Unrecognized Spotlight status"))
    }

    // MARK: - 执行

    static func adminPrompt(for id: MaintenanceTask.ID) -> String {
        let title = tasks.first { $0.id == id }?.title ?? L10n.t("系统维护", "System Maintenance")
        return L10n.t("PopBar 需要管理员权限来执行「\(title)」", "PopBar needs administrator privileges to run “\(title)”")
    }

    static func run(_ id: MaintenanceTask.ID,
                    enableSpotlightIfDisabled: Bool = false,
                    beforeSnapshotCount: Int? = nil,
                    executor: MaintenanceExecutor = .live) -> MaintenanceRunResult {
        switch id {
        case .flushDNS:
            let cmd = "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder && (/usr/bin/killall -HUP mDNSResponderHelper 2>/dev/null || true)"
            return mapAdmin(executor.runAsAdmin(cmd, adminPrompt(for: id), 900)) { _ in
                L10n.t("已通知 mDNSResponder 刷新（代理工具或浏览器内置 DoH 缓存不受影响）",
                       "mDNSResponder reloaded (proxy tools and browser DoH caches are unaffected)")
            }

        case .thinSnapshots:
            let before: Int
            if let beforeSnapshotCount {
                before = beforeSnapshotCount
            } else if case .loaded(let c, _) = localSnapshotState(executor: executor) {
                before = c
            } else {
                before = 0
            }
            let cmd = "/usr/bin/tmutil thinlocalsnapshots / 999999999999999 4"
            return mapAdmin(executor.runAsAdmin(cmd, adminPrompt(for: id), 900)) { output in
                let parsedRemoved = parseThinnedSnapshotCount(output)
                let afterState = localSnapshotState(executor: executor)
                let afterCount: Int? = {
                    if case .loaded(let c, _) = afterState { return c }
                    return nil
                }()
                let diffRemoved = afterCount.map { max(0, before - $0) }
                let removed = parsedRemoved > 0 ? parsedRemoved : (diffRemoved ?? 0)
                if let afterCount {
                    if removed == 0 {
                        if afterCount > 0 {
                            return L10n.t(
                                "未释放任何快照（剩余 \(afterCount) 个，可能正被 Time Machine 备份或系统占用）",
                                "No snapshots freed (\(afterCount) remaining; may be in use by Time Machine or macOS)"
                            )
                        }
                        return L10n.t("当前没有可清理的本地快照", "No local snapshots to remove")
                    }
                    return L10n.t(
                        "已清理 \(removed) 个本地快照（剩余 \(afterCount) 个）",
                        "Removed \(removed) local \(removed == 1 ? "snapshot" : "snapshots") (\(afterCount) remaining)"
                    )
                }
                return L10n.t(
                    "已清理 \(removed) 个本地快照",
                    "Removed \(removed) local \(removed == 1 ? "snapshot" : "snapshots")"
                )
            }

        case .reindexSpotlight:
            if !enableSpotlightIfDisabled {
                let probe = spotlightState(executor: executor)
                if case .disabled = probe {
                    return .failure(L10n.t(
                        "当前系统卷已关闭 Spotlight 索引，无法直接重建；请确认开启索引后再重建",
                        "Spotlight indexing is disabled on /. Enable indexing before rebuilding."
                    ))
                }
            }
            let cmd = enableSpotlightIfDisabled
                ? "/usr/bin/mdutil -i on / && /usr/bin/mdutil -E /"
                : "/usr/bin/mdutil -E /"
            let res = executor.runAsAdmin(cmd, adminPrompt(for: id), 900)
            switch res {
            case .cancelled:
                return .cancelled
            case .failure(let msg):
                return .failure(msg)
            case .success(let output):
                let finalState = parseSpotlightEnabled(output)
                if finalState == false {
                    if output.localizedCaseInsensitiveContains(".metadata_never_index") {
                        return .failure(L10n.t(
                            "根目录存在 .metadata_never_index 文件，Spotlight 索引被锁定为禁用，未触发重建",
                            "Found .metadata_never_index at volume root; Spotlight indexing stays disabled and rebuild was not triggered."
                        ))
                    }
                    if enableSpotlightIfDisabled {
                        return .failure(L10n.t(
                            "未能开启系统卷 Spotlight 索引，未触发重建",
                            "Failed to enable Spotlight indexing on /; rebuild was not triggered."
                        ))
                    }
                    return .failure(L10n.t(
                        "当前系统卷已关闭 Spotlight 索引，未触发重建",
                        "Spotlight indexing is disabled on /; rebuild was not triggered."
                    ))
                }
                if finalState != true, let errorLine = firstSpotlightErrorLine(in: output) {
                    return .failure(errorLine)
                }
                return .success(detail: L10n.t(
                    "已开始后台重建（可能需要数分钟至数小时）",
                    "Background rebuild started (may take several minutes to hours)"
                ))
            }

        case .rebuildLaunchServices:
            let gc = executor.run(lsregister, ["-gc"], 300)
            if let err = failureMessage(gc) { return .failure(err) }
            let rescan = executor.run(lsregister, ["-apps", "u,l,s"], 300)
            if let err = failureMessage(rescan) { return .failure(err) }
            return .success(detail: L10n.t(
                "已完成整理；如右键「打开方式」仍显示旧项，可运行「重启访达与程序坞」、重新登录或检查下载与构建目录中是否仍有应用副本",
                "Database tidied; if “Open With” still shows old entries, run “Restart Finder & Dock”, log out, or check Downloads/build folders for duplicate app copies"
            ))

        case .resetQuickLook:
            let reload = executor.run("/usr/bin/qlmanage", ["-r"], 60)
            if let err = failureMessage(reload) { return .failure(err) }
            let clearCache = executor.run("/usr/bin/qlmanage", ["-r", "cache"], 60)
            if let err = failureMessage(clearCache) { return .failure(err) }
            // macOS 15+ 缩略图与预览由 ThumbnailsAgent 接管，按需重启当前用户实例（未运行时静默忽略）。
            _ = executor.run("/usr/bin/killall", killallArgs(user: executor.currentUser, process: "com.apple.quicklook.ThumbnailsAgent"), 15)
            return .success(detail: L10n.t(
                "已重载快速查看生成器并清空缩略图缓存",
                "Quick Look generators reloaded and thumbnail cache cleared"
            ))

        case .restartFinderAndDock:
            let finder = executor.run("/usr/bin/killall", killallArgs(user: executor.currentUser, process: "Finder"), 15)
            if finder.status != 0, !finder.err.localizedCaseInsensitiveContains("No matching processes") {
                if let err = failureMessage(finder) { return .failure(err) }
            }
            let dock = executor.run("/usr/bin/killall", killallArgs(user: executor.currentUser, process: "Dock"), 15)
            if dock.status != 0, !dock.err.localizedCaseInsensitiveContains("No matching processes") {
                if let err = failureMessage(dock) { return .failure(err) }
            }
            return .success(detail: L10n.t("已重新启动访达与程序坞", "Finder and Dock relaunched"))

        case .restartAudio:
            return mapAdmin(
                executor.runAsAdmin("/bin/launchctl kickstart -kp system/com.apple.audio.coreaudiod", adminPrompt(for: id), 900)
            ) { _ in
                L10n.t("已重启音频守护进程（系统会自动重新连接输出设备）",
                       "Audio daemon restarted (output devices will reconnect automatically)")
            }

        case .clearFontCache:
            let r = executor.run("/usr/bin/atsutil", ["databases", "-removeUser"], 60)
            if let err = failureMessage(r) { return .failure(err) }
            return .success(detail: L10n.t(
                "已清理用户字体缓存，建议重新登录或重启生效",
                "User font cache cleared; log out or restart to fully apply"
            ))
        }
    }

    private static func killallArgs(user: String, process: String) -> [String] {
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [process] : ["-u", trimmed, process]
    }

    private static func firstSpotlightErrorLine(in output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.localizedCaseInsensitiveContains("error:") }
    }

    private static func mapAdmin(_ result: AdminRunResult, detail: (String) -> String?) -> MaintenanceRunResult {
        switch result {
        case .success(let output):
            return .success(detail: detail(output))
        case .cancelled:
            return .cancelled
        case .failure(let msg):
            return .failure(msg)
        }
    }

    private static func failureMessage(_ r: ShellRun.Result) -> String? {
        guard r.status != 0 else { return nil }
        let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? L10n.t("执行失败", "Failed") : msg
    }
}
