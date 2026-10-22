import Foundation

/// 命令执行:同步阻塞,只在后台线程调用。超时先 SIGTERM,2 秒后 SIGKILL。
enum ShellRun {
    typealias Result = (status: Int32, out: String, err: String)

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> Result {
        let r = runData(path, args, timeout: timeout)
        return (r.status, String(decoding: r.out, as: UTF8.self), r.err)
    }

    /// 同 run,但 stdout 保持原始字节(截图等二进制输出)
    static func runData(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return (-1, Data(), error.localizedDescription) }

        final class Box: @unchecked Sendable { var data = Data() }
        let outBox = Box(), errBox = Box()
        let readers = DispatchGroup()
        for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            readers.wait()
            return (-2, Data(), L10n.t("执行超时", "Timed out"))
        }
        readers.wait()
        return (p.terminationStatus, outBox.data,
                String(decoding: errBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 以管理员权限运行固定的 shell 命令(系统弹出密码框)。nil 表示成功,否则为错误描述。
    /// 只允许传入代码内的常量命令,不要拼接任何外部输入。
    static func runAsAdmin(_ shell: String, timeout: TimeInterval = 900) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let r = run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"],
                    timeout: timeout)
        if r.status == 0 { return nil }
        if r.err.contains("-128") { return L10n.t("已取消授权", "Authorization cancelled") }
        return r.err.isEmpty ? L10n.t("执行失败", "Failed") : r.err
    }
}

/// 维护任务:只做有实际效果的;不做「释放内存」「修复磁盘权限」这类收益小于风险的项目。
struct MaintenanceTask: Identifiable, Hashable {
    enum ID: String, CaseIterable {
        case flushDNS, thinSnapshots, reindexSpotlight, rebuildLaunchServices, resetQuickLook
    }
    let id: ID
    let title: String
    let detail: String
    let needsAdmin: Bool
    let symbol: String
}

enum Maintenance {
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    static var tasks: [MaintenanceTask] {
        [
            .init(id: .flushDNS, title: L10n.t("刷新 DNS 缓存", "Flush DNS Cache"),
                  detail: L10n.t("网站打不开、解析到旧地址时使用。清空本机 DNS 缓存并重启 mDNSResponder。",
                                 "For sites that won't load or resolve to a stale address. Clears the DNS cache and restarts mDNSResponder."),
                  needsAdmin: true, symbol: "network"),
            .init(id: .thinSnapshots, title: L10n.t("精简 Time Machine 本地快照", "Thin Time Machine Local Snapshots"),
                  detail: L10n.t("删除本机磁盘上的 Time Machine 本地快照以释放空间,不影响备份盘上的备份。",
                                 "Deletes local Time Machine snapshots on this disk to free space. Backups on the backup drive are untouched."),
                  needsAdmin: true, symbol: "clock.arrow.circlepath"),
            .init(id: .reindexSpotlight, title: L10n.t("重建 Spotlight 索引", "Rebuild Spotlight Index"),
                  detail: L10n.t("搜索结果缺失或异常时使用。重建期间搜索暂时不可用,CPU 占用会升高一段时间。",
                                 "For missing or odd search results. Search is unavailable and CPU usage rises while it rebuilds."),
                  needsAdmin: true, symbol: "magnifyingglass"),
            .init(id: .rebuildLaunchServices, title: L10n.t("整理「打开方式」数据库", "Tidy the “Open With” Database"),
                  detail: L10n.t("右键「打开方式」出现重复或已删除的应用时使用 (lsregister -gc)。",
                                 "For duplicate or deleted apps in the “Open With” menu (lsregister -gc)."),
                  needsAdmin: false, symbol: "square.stack.3d.up"),
            .init(id: .resetQuickLook, title: L10n.t("重置快速查看缓存", "Reset Quick Look Cache"),
                  detail: L10n.t("空格预览显示旧缩略图或无法预览时使用 (qlmanage -r cache)。",
                                 "For stale thumbnails or failing Space-bar previews (qlmanage -r cache)."),
                  needsAdmin: false, symbol: "eye"),
        ]
    }

    /// 本地快照数量(只读,不需要管理员)
    static func localSnapshotCount() -> Int {
        let r = ShellRun.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30)
        guard r.status == 0 else { return 0 }
        return r.out.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
    }

    /// 执行任务。nil 表示成功,否则为错误描述。
    static func run(_ id: MaintenanceTask.ID) -> String? {
        switch id {
        case .flushDNS:
            return ShellRun.runAsAdmin("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")
        case .thinSnapshots:
            // 请求释放尽可能多的空间、最高紧急度:系统会删除可删除的本地快照
            return ShellRun.runAsAdmin("/usr/bin/tmutil thinlocalsnapshots / 999999999999999 4")
        case .reindexSpotlight:
            return ShellRun.runAsAdmin("/usr/bin/mdutil -E /")
        case .rebuildLaunchServices:
            return failure(ShellRun.run(lsregister, ["-gc"], timeout: 300))
        case .resetQuickLook:
            return failure(ShellRun.run("/usr/bin/qlmanage", ["-r", "cache"], timeout: 60))
        }
    }

    private static func failure(_ r: ShellRun.Result) -> String? {
        r.status == 0 ? nil : (r.err.isEmpty ? L10n.t("执行失败", "Failed") : r.err)
    }
}
