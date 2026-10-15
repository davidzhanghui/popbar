import Cocoa
import Darwin

/// 系统监控进程表的动作:在访达中显示 / 复制 / 终止 / 强制退出。
/// 操作对象是一个进程组(一个应用的全部进程,或一个独立程序)。
@MainActor
enum SystemMonitorActions {
    enum Result: Equatable {
        case done, cancelled, notFound, permission, protected, changed
        case failed(String)

        var message: String {
            switch self {
            case .done, .cancelled: return ""
            case .notFound: return L10n.t("进程已停止运行。", "The process is no longer running.")
            case .permission: return L10n.t("权限不足:该进程属于系统或其他用户。", "Permission denied: the process belongs to the system or another user.")
            case .protected: return L10n.t("系统进程,无法终止。", "System process, can’t be terminated.")
            case .changed: return L10n.t("进程在查看过程中已变化,请刷新后重试。", "The process changed while you were looking at it. Refresh and try again.")
            case .failed(let s): return s
            }
        }
    }

    // MARK: - 简单动作

    static func revealInFinder(_ g: ProcessGroup) {
        guard let p = g.appPath ?? g.exePath ?? LibProc.path(g.mainPID) else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    static func copy(_ text: String) {
        PasteboardGuard.write(text)
    }

    // MARK: - 终止 / 强制退出

    /// 系统关键进程:PID 1、PopBar 自己、系统目录下由 root 运行的程序
    static func isProtected(_ g: ProcessGroup) -> Bool {
        if g.pids.contains(where: { $0 <= 1 || $0 == Int(getpid()) }) { return true }
        if ProcessText.isSystemPath(g.exePath) || ProcessText.isSystemPath(LibProc.path(g.mainPID)) {
            return LibProc.bsd(g.mainPID)?.pbi_uid == 0
        }
        return false
    }

    /// 弹确认框 → 校验 PID 没被复用 → 发信号。expectedStart 为打开详情时记录的启动时刻(没有则不校验)
    static func terminate(_ g: ProcessGroup, force: Bool, expectedStart: [Int: UInt64]?) -> Result {
        if isProtected(g) { return .protected }

        let a = NSAlert()
        a.alertStyle = force ? .critical : .warning
        let extra = g.count > 1 ? L10n.t("(共 \(g.count) 个进程)", " (\(g.count) processes)") : ""
        a.messageText = force
            ? L10n.t("强制退出「\(g.name)」?", "Force quit “\(g.name)”?")
            : L10n.t("终止「\(g.name)」?", "Terminate “\(g.name)”?")
        a.informativeText = force
            ? L10n.t("将立即结束该进程\(extra),未保存的数据会丢失。",
                     "Ends the process\(extra) immediately; unsaved data is lost.")
            : L10n.t("将请求该进程\(extra)退出,允许它先保存数据。",
                     "Asks the process\(extra) to quit so it can save its data.")
        a.addButton(withTitle: force ? L10n.t("强制退出", "Force Quit") : L10n.t("终止", "Terminate"))
        a.addButton(withTitle: L10n.t("取消", "Cancel"))
        NSApp.activateForUI()
        guard a.runModal() == .alertFirstButtonReturn else { return .cancelled }

        // PID 复用校验:启动时刻对不上说明这个 PID 已是另一个进程
        var targets: [Int] = []
        var gone = 0
        for pid in g.pids {
            guard let now = LibProc.startKey(pid) else { gone += 1; continue }
            if let exp = expectedStart?[pid], exp != now { return .changed }
            targets.append(pid)
        }
        if targets.isEmpty { return .notFound }

        // 正常终止:App 走 NSRunningApplication(等同 ⌘Q,允许保存);其余发 SIGTERM。
        // 强制:对全部成员 SIGKILL,Helper 不会遗留
        var denied = 0, signaled = 0
        if !force, g.appPath != nil,
           let app = NSRunningApplication(processIdentifier: pid_t(g.mainPID)), app.terminate() {
            return .done
        }
        for pid in (force || g.appPath == nil) ? targets : [g.mainPID] {
            if kill(pid_t(pid), force ? SIGKILL : SIGTERM) == 0 { signaled += 1 }
            else if errno == EPERM { denied += 1 }
        }
        if signaled > 0 { return .done }
        return denied > 0 ? .permission : .notFound
    }

    /// 右键菜单用:失败时弹框说明原因(详情窗里则是行内提示)
    static func terminateAndReport(_ g: ProcessGroup, force: Bool) {
        let r = terminate(g, force: force, expectedStart: nil)
        guard r != .done, r != .cancelled else { return }
        let e = NSAlert()
        e.alertStyle = .warning
        e.messageText = L10n.t("无法结束「\(g.name)」", "Couldn’t end “\(g.name)”")
        e.informativeText = r.message
        NSApp.activateForUI()
        e.runModal()
    }
}
