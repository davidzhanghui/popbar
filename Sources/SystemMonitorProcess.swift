import Cocoa
import Darwin
import IOKit.pwr_mgt

// 系统监控的进程层:libproc 封装、按应用分组、来源判定、详情采集。
// 全部是无界面逻辑(纯函数 + 只读系统调用),不依赖主线程,可在后台线程跑。

// MARK: - libproc 封装

enum LibProc {
    static func path(_ pid: Int) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(Int32(pid), &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    static func name(_ pid: Int) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        if proc_name(Int32(pid), &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
        return path(pid).map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
    }

    static func bsd(_ pid: Int) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// 启动时刻(微秒)。同一个 PID 被系统回收复用后这个值一定不同,用来防误杀
    static func startKey(_ pid: Int) -> UInt64? {
        guard let i = bsd(pid) else { return nil }
        return i.pbi_start_tvsec &* 1_000_000 &+ i.pbi_start_tvusec
    }

    static func taskInfo(_ pid: Int) -> proc_taskinfo? {
        var t = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDTASKINFO, 0, &t, size) == size else { return nil }
        return t
    }

    static func fdCount(_ pid: Int) -> Int {
        let bytes = proc_pidinfo(Int32(pid), PROC_PIDLISTFDS, 0, nil, 0)
        return bytes > 0 ? Int(bytes) / MemoryLayout<proc_fdinfo>.size : 0
    }

    static func cwd(_ pid: Int) -> String? {
        var v = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDVNODEPATHINFO, 0, &v, size) == size else { return nil }
        let s = withUnsafeBytes(of: v.pvi_cdir.vip_path) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        return s.isEmpty ? nil : s
    }

    static func diskIO(_ pid: Int) -> (read: UInt64, written: UInt64)? {
        var ru = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(Int32(pid), RUSAGE_INFO_V4, $0)
            }
        }
        guard r == 0 else { return nil }
        return (ru.ri_diskio_bytesread, ru.ri_diskio_byteswritten)
    }

    /// 所有 PID → 父 PID
    static func parentMap() -> [Int: Int] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(n) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var map: [Int: Int] = [:]
        for pid in pids.prefix(Int(got)) where pid > 0 {
            if let b = bsd(Int(pid)) { map[Int(pid)] = Int(b.pbi_ppid) }
        }
        return map
    }

    /// 启动参数与环境变量(KERN_PROCARGS2);他人进程或受保护进程读不到
    static func args(_ pid: Int) -> (argv: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        var argc: Int32 = 0
        memcpy(&argc, buf, 4)
        var i = 4
        func readString() -> String? {
            guard i < size else { return nil }
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            let s = String(decoding: buf[start..<i], as: UTF8.self)
            i += 1
            return s
        }
        _ = readString()                                   // 可执行文件路径
        while i < size, buf[i] == 0 { i += 1 }             // 路径后的 NUL 填充
        var argv: [String] = []
        for _ in 0..<max(0, Int(argc)) { if let s = readString() { argv.append(s) } }
        var env: [String] = []
        while let s = readString(), !s.isEmpty { env.append(s) }
        return (argv, env)
    }
}

// MARK: - 应用归属

enum AppIdentity {
    /// 可执行文件所在的最外层 .app 包路径;不在 .app 里返回 nil。
    /// 例:…/Cursor.app/Contents/Frameworks/Cursor Helper.app/… → …/Cursor.app
    static func bundlePath(forExecutable exe: String) -> String? {
        let comps = exe.split(separator: "/", omittingEmptySubsequences: true)
        guard let idx = comps.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) else { return nil }
        return "/" + comps[...idx].joined(separator: "/")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var names: [String: String] = [:]

    /// 应用显示名(随系统语言,如「微信」),去掉 .app 后缀
    static func displayName(bundlePath: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let n = names[bundlePath] { return n }
        var n = FileManager.default.displayName(atPath: bundlePath)
        if n.hasSuffix(".app") { n.removeLast(4) }
        names[bundlePath] = n
        return n
    }

    /// 该进程是不是 App 的主可执行文件(Contents/MacOS/<exe>,且路径里只有一个 .app)
    static func isMainExecutable(_ exe: String, bundle: String) -> Bool {
        exe.hasPrefix(bundle + "/Contents/MacOS/") && !exe.dropFirst(bundle.count).contains(".app/")
    }
}

// MARK: - 分组

/// 进程表的一行:一个应用(主进程 + 全部 Helper)或一个独立程序
struct ProcessGroup: Identifiable, Equatable {
    let id: String                 // App 为 "app:<bundle>",独立进程为 "pid:<pid>"
    let name: String
    let appPath: String?
    let exePath: String?
    let mainPID: Int
    let members: [ProcessRow]      // 按内存降序
    let memoryBytes: UInt64
    let cpuPercent: Double
    let powerScore: Double

    var count: Int { members.count }
    var pids: [Int] { members.map(\.pid) }
}

enum ProcessGrouping {
    /// 只把 App 的进程(主进程 + 全部 Helper)归并成一行;非 App 进程各占一行,
    /// 这样「终止」只会作用于用户点的那个进程,不会连带结束同一程序的其它实例。
    /// 结果按能耗(CPU 合计)降序,同分按内存降序
    static func group(_ rows: [ProcessRow], paths: [Int: String]) -> [ProcessGroup] {
        var buckets: [String: [ProcessRow]] = [:]
        var keyInfo: [String: (app: String?, exe: String?)] = [:]
        for r in rows {
            let exe = paths[r.pid]
            let key: String
            let app: String? = exe.flatMap { AppIdentity.bundlePath(forExecutable: $0) }
            if let app { key = "app:" + app } else { key = "pid:\(r.pid)" }
            buckets[key, default: []].append(r)
            if keyInfo[key] == nil { keyInfo[key] = (app, app == nil ? exe : nil) }
        }
        var out: [ProcessGroup] = []
        out.reserveCapacity(buckets.count)
        for (key, raw) in buckets {
            let members = raw.sorted { $0.memoryBytes > $1.memoryBytes }
            let info = keyInfo[key]!
            let name: String
            if let app = info.app { name = AppIdentity.displayName(bundlePath: app) }
            else { name = members[0].name }
            // 主进程:App 取主可执行文件,否则取最早启动(PID 最小)的成员;非 App 取内存最大的
            var main = members[0].pid
            if let app = info.app {
                main = members.first(where: { m in
                    paths[m.pid].map { AppIdentity.isMainExecutable($0, bundle: app) } ?? false
                })?.pid ?? members.map(\.pid).min()!
            }
            out.append(ProcessGroup(
                id: key, name: name, appPath: info.app, exePath: info.exe ?? paths[main],
                mainPID: main, members: members,
                memoryBytes: members.reduce(0) { $0 + $1.memoryBytes },
                cpuPercent: members.reduce(0) { $0 + $1.cpuPercent },
                powerScore: members.reduce(0) { $0 + $1.powerScore }))
        }
        return out.sorted {
            $0.powerScore != $1.powerScore ? $0.powerScore > $1.powerScore : $0.memoryBytes > $1.memoryBytes
        }
    }
}

// MARK: - 文案与判定(纯函数)

enum ProcessText {
    /// 3h 7m / 2d 5h / 45s
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s % 60)s" }
        return "\(s)s"
    }

    static func bytes(_ v: UInt64) -> String {
        if v == 0 { return "0 KB" }   // ByteCountFormatter 对 0 会输出「Zero KB」
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: v), countStyle: .memory)
    }

    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "ksh", "nu", "xonsh"]
    static let wrapperNames: Set<String> = ["login", "tmux", "tmux: server", "screen", "sudo", "su"]
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/",
                                 "/Library/Apple/", "/usr/lib/"]

    static func isSystemPath(_ p: String?) -> Bool {
        guard let p else { return false }
        return systemPrefixes.contains { p.hasPrefix($0) }
    }
}

struct ChainNode: Equatable {
    let pid: Int
    let name: String
    /// 该进程所属 App 的显示名(不在 .app 里则 nil),用来说出「由 Ghostty 启动」
    let appName: String?
}

enum SourceKind: Equatable { case launchdLabel, launchd, ssh, shell, parent, unknown }

struct SourceInfo: Equatable {
    var kind: SourceKind
    var summary: String        // 详情里的完整一句话
    var compact: String        // 摘要行里的短语
}

enum Confidence: Equatable { case high, medium, possible }

extension ProcessText {
    /// 由启动链(launchd → … → 目标)判定来源;chain 最后一个是目标进程
    static func classify(chain: [ChainNode], label: String?, hasPlist: Bool) -> SourceInfo {
        let ancestors = Array(chain.dropLast())
        let parent = ancestors.last
        if hasPlist, let label {
            return SourceInfo(kind: .launchdLabel,
                              summary: L10n.t("launchd 通过 \(label) 启动或维持这个进程。",
                                              "launchd starts or keeps this process alive through \(label)."),
                              compact: L10n.t("由系统后台服务管理", "Managed by launchd"))
        }
        if parent?.pid == 1 {
            return SourceInfo(kind: .launchd,
                              summary: L10n.t("由系统后台服务管理。", "Managed by the system background service (launchd)."),
                              compact: L10n.t("由系统后台服务管理", "Managed by launchd"))
        }
        if ancestors.contains(where: { $0.name == "sshd" || $0.name.hasPrefix("sshd-") }) {
            return SourceInfo(kind: .ssh,
                              summary: L10n.t("通过 SSH 远程登录启动。", "Started from a remote SSH login."),
                              compact: L10n.t("SSH 远程登录", "SSH login"))
        }
        if let si = ancestors.lastIndex(where: { shellNames.contains($0.name) }) {
            // shell 之上第一个不是 login/tmux 之类包装的祖先,就是终端
            var term: ChainNode?
            var j = si - 1
            while j >= 0 {
                let n = ancestors[j]
                if n.pid != 1, !wrapperNames.contains(n.name) { term = n; break }
                j -= 1
            }
            let tname = term.map { $0.appName ?? $0.name } ?? L10n.t("终端", "a terminal")
            return SourceInfo(kind: .shell,
                              summary: L10n.t("由终端 \(tname) 启动。", "Started from the terminal \(tname)."),
                              compact: L10n.t("由 \(tname) 启动", "Started by \(tname)"))
        }
        if let parent {
            let pname = parent.appName ?? parent.name
            return SourceInfo(kind: .parent,
                              summary: L10n.t("由 \(pname) 启动。", "Started by \(pname)."),
                              compact: L10n.t("由 \(pname) 启动", "Started by \(pname)"))
        }
        return SourceInfo(kind: .unknown,
                          summary: L10n.t("没能确认明确来源,可能是进程已脱离父进程,或受系统权限限制。",
                                          "No clear source could be confirmed: the process may have detached from its parent, or system permissions limit what can be read."),
                          compact: L10n.t("来源未知", "Unknown source"))
    }

    /// 归属与可信度:在 App 包里 / 系统路径 / 有 launchd plist 为高;靠祖先里的 App 推断为中;其余为「可能」
    static func ownership(group: ProcessGroup, chain: [ChainNode], source: SourceInfo,
                          plistPath: String?) -> (confidence: Confidence, evidence: String, owner: String?) {
        if let app = group.appPath { return (.high, app, nil) }
        if isSystemPath(group.exePath) { return (.high, group.exePath ?? "", nil) }
        if let plistPath { return (.high, plistPath, nil) }
        let ancestors = chain.dropLast()
        if let a = ancestors.last(where: { $0.appName != nil }) {
            let viaShell = source.kind == .shell || source.kind == .ssh
            return (viaShell ? .possible : .medium,
                    L10n.t("启动链中的 \(a.appName ?? a.name)(PID \(a.pid))",
                           "\(a.appName ?? a.name) (PID \(a.pid)) in the launch chain"),
                    a.appName ?? a.name)
        }
        return (.possible, group.exePath ?? L10n.t("无", "none"), nil)
    }
}

// MARK: - 详情数据

struct PortInfo: Equatable {
    let pid: Int
    let address: String        // 如 *:61202
    let isPublic: Bool
}

struct ProcessDetail {
    var chain: [ChainNode] = []
    var source = SourceInfo(kind: .unknown, summary: "", compact: "")
    var confidence = Confidence.possible
    var evidence = ""
    var owner: String?
    var launchdReason: String?
    var launchdService: String?
    var plistPath: String?
    var keepAlive: Bool?
    var triggers: [String] = []
    var threads = 0
    var openFiles = 0
    var diskRead: UInt64 = 0
    var diskWritten: UInt64 = 0
    var user = ""
    var started: Date?
    var cwd: String?
    var gitRepo: String?
    var rawPath: String?
    var command: String?
    var ports: [PortInfo] = []
    var preventsSleep = false
    var children: [String] = []
    var warnings: [String] = []
    /// 每个成员的启动时刻,终止前用来确认 PID 没有被复用
    var startKeys: [Int: UInt64] = [:]
    var sleepPIDs: Set<Int> = []
    var publicPortPIDs: Set<Int> = []
}

enum ProcessInspector {
    /// 采集一个进程组的详情(阻塞,放后台线程调用)
    static func inspect(_ g: ProcessGroup) -> ProcessDetail {
        var d = ProcessDetail()
        let main = g.mainPID
        let parents = LibProc.parentMap()
        let mainBSD = LibProc.bsd(main)

        // 启动链:launchd → … → 主进程
        var chain: [ChainNode] = []
        var cur = main
        var guardN = 0
        while guardN < 16 {
            chain.append(node(cur))
            let up: Int? = parents[cur] ?? (cur == main ? mainBSD.map { Int($0.pbi_ppid) } : nil)
            guard let pp = up, pp > 0 else { break }
            if pp == 1 { chain.append(ChainNode(pid: 1, name: "launchd", appName: nil)); break }
            cur = pp
            guardN += 1
        }
        d.chain = chain.reversed()

        // launchd:触发原因(blame)、服务 label(list)、plist
        d.launchdReason = shell("/bin/launchctl", ["blame", String(main)], timeout: 3)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || $0.contains("Could not") || $0.contains("Usage") ? nil : $0 }
        d.launchdService = launchdLabel(pid: main)
        if let label = d.launchdService, let p = plistFor(label: label) {
            d.plistPath = p.path
            d.keepAlive = p.keepAlive
            d.triggers = p.triggers
        }

        d.source = ProcessText.classify(chain: d.chain, label: d.launchdService, hasPlist: d.plistPath != nil)
        let own = ProcessText.ownership(group: g, chain: d.chain, source: d.source, plistPath: d.plistPath)
        d.confidence = own.confidence
        d.evidence = own.evidence
        d.owner = own.owner

        // 汇总:线程 / 打开文件 / 磁盘 I/O / 启动时刻
        for pid in g.pids {
            if let t = LibProc.taskInfo(pid) { d.threads += Int(t.pti_threadnum) }
            d.openFiles += LibProc.fdCount(pid)
            if let io = LibProc.diskIO(pid) { d.diskRead += io.read; d.diskWritten += io.written }
            if let k = LibProc.startKey(pid) { d.startKeys[pid] = k }
        }

        if let b = mainBSD {
            if let pw = getpwuid(b.pbi_uid) { d.user = String(cString: pw.pointee.pw_name) }
            d.started = Date(timeIntervalSince1970: TimeInterval(b.pbi_start_tvsec))
        }
        d.rawPath = LibProc.path(main)
        d.cwd = LibProc.cwd(main)
        if let cwd = d.cwd, cwd != "/" { d.gitRepo = gitRoot(from: cwd) }

        // 命令与环境(DYLD 检查对所有成员做,命令取主进程)
        var dyld = false
        if let a = LibProc.args(main) {
            d.command = a.argv.joined(separator: " ")
            if d.command!.count > 600 { d.command = String(d.command!.prefix(600)) + "…" }
        }
        for pid in g.pids.prefix(64) {
            if let a = LibProc.args(pid), a.env.contains(where: { $0.hasPrefix("DYLD_") }) { dyld = true; break }
        }

        // 阻止睡眠
        d.sleepPIDs = sleepAssertionPIDs().intersection(Set(g.pids))
        d.preventsSleep = !d.sleepPIDs.isEmpty

        // 监听端口
        d.ports = listeningPorts(pids: Array(g.pids.prefix(200)))
        d.publicPortPIDs = Set(d.ports.filter(\.isPublic).map(\.pid))

        // 组外的直接子进程(如 App 拉起的 node / shell)
        let members = Set(g.pids)
        var kids: [String: Int] = [:]
        for (pid, pp) in parents where members.contains(pp) && !members.contains(pid) {
            kids[LibProc.name(pid), default: 0] += 1
        }
        d.children = kids.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }

        // 警告
        if let b = mainBSD {
            if b.pbi_uid == 0 { d.warnings.append(L10n.t("进程正在以 root 身份运行。", "The process is running as root.")) }
            if b.pbi_status == 4 { d.warnings.append(L10n.t("进程已暂停。", "The process is stopped.")) }
            if b.pbi_status == 5 { d.warnings.append(L10n.t("进程已是僵尸状态,无法自行退出。", "The process is a zombie and cannot exit by itself.")) }
        }
        if d.publicPortPIDs.count > 0 { d.warnings.append(L10n.t("进程正在监听公开网络接口。", "The process is listening on a public network interface.")) }
        if d.preventsSleep { d.warnings.append(L10n.t("进程正在阻止系统睡眠。", "The process is preventing system sleep.")) }
        if dyld { d.warnings.append(L10n.t("进程设置了 DYLD 调试或注入变量。", "The process sets DYLD debug or injection variables.")) }
        if let p = d.rawPath, !FileManager.default.fileExists(atPath: p) {
            d.warnings.append(L10n.t("程序文件在运行中被替换,通常是更新造成的。", "The program file was replaced while running, usually by an update."))
        }
        if let s = d.started, Date().timeIntervalSince(s) > 90 * 86400 {
            d.warnings.append(L10n.t("进程已连续运行超过 90 天。", "The process has been running for over 90 days."))
        }
        if d.source.kind == .unknown {
            d.warnings.append(L10n.t("没有识别到明确的启动来源或管理器。", "No clear launch source or manager was identified."))
        }
        return d
    }

    // MARK: 内部

    private static func node(_ pid: Int) -> ChainNode {
        if pid == 1 { return ChainNode(pid: 1, name: "launchd", appName: nil) }
        let app = LibProc.path(pid).flatMap { AppIdentity.bundlePath(forExecutable: $0) }
            .map { AppIdentity.displayName(bundlePath: $0) }
        return ChainNode(pid: pid, name: LibProc.name(pid), appName: app)
    }

    /// 带超时的子进程调用;失败/超时返回 nil
    static func shell(_ exe: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        var data = Data()
        let reader = DispatchQueue(label: "popbar.monitor.shell")
        let readDone = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        _ = readDone.wait(timeout: .now() + 1)
        return String(decoding: data, as: UTF8.self)
    }

    private static func launchdLabel(pid: Int) -> String? {
        guard let out = shell("/bin/launchctl", ["list"], timeout: 4) else { return nil }
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            if cols.count >= 3, Int(cols[0]) == pid { return String(cols[2]) }
        }
        return nil
    }

    private static func plistFor(label: String) -> (path: String, keepAlive: Bool, triggers: [String])? {
        let home = NSHomeDirectory()
        let dirs = [home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons",
                    "/System/Library/LaunchAgents", "/System/Library/LaunchDaemons",
                    "/Library/Apple/System/Library/LaunchAgents", "/Library/Apple/System/Library/LaunchDaemons"]
        for dir in dirs {
            let path = "\(dir)/\(label).plist"
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            var keep = false
            if let b = plist["KeepAlive"] as? Bool { keep = b } else if plist["KeepAlive"] is [String: Any] { keep = true }
            var t: [String] = []
            if plist["RunAtLoad"] as? Bool == true { t.append(L10n.t("加载时运行", "Run at load")) }
            if let n = plist["StartInterval"] as? Int { t.append(L10n.t("每 \(n) 秒", "Every \(n)s")) }
            if plist["StartCalendarInterval"] != nil { t.append(L10n.t("定时", "Calendar schedule")) }
            if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil { t.append(L10n.t("监视路径", "Watched paths")) }
            if plist["MachServices"] != nil { t.append(L10n.t("按需(Mach 服务)", "On demand (Mach service)")) }
            if plist["Sockets"] != nil { t.append(L10n.t("套接字激活", "Socket activation")) }
            return (path, keep, t)
        }
        return nil
    }

    private static func gitRoot(from dir: String) -> String? {
        var url = URL(fileURLWithPath: dir)
        for _ in 0..<24 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            let up = url.deletingLastPathComponent()
            if up.path == url.path { break }
            url = up
        }
        return nil
    }

    private static func sleepAssertionPIDs() -> Set<Int> {
        var ref: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess,
              let dict = ref?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let blocking: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion",
                                     "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
        var pids: Set<Int> = []
        for (pid, list) in dict {
            for a in list {
                let t = (a["AssertType"] as? String) ?? (a["AssertionTrueType"] as? String) ?? ""
                if blocking.contains(t) { pids.insert(pid.intValue); break }
            }
        }
        return pids
    }

    private static func listeningPorts(pids: [Int]) -> [PortInfo] {
        guard !pids.isEmpty,
              let out = shell("/usr/sbin/lsof", ["-nP", "-a", "-p", pids.map(String.init).joined(separator: ","),
                                                 "-iTCP", "-sTCP:LISTEN", "-F", "pn"], timeout: 4) else { return [] }
        var result: [PortInfo] = []
        var pid = 0
        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let rest = String(line.dropFirst())
            if tag == "p" { pid = Int(rest) ?? 0 }
            else if tag == "n", pid > 0 {
                let host = rest.split(separator: ":", omittingEmptySubsequences: false).dropLast().joined(separator: ":")
                let loopback = host.hasPrefix("127.") || host == "[::1]" || host == "localhost"
                let info = PortInfo(pid: pid, address: rest, isPublic: !loopback)
                if !result.contains(info) { result.append(info) }
            }
        }
        return result
    }
}
