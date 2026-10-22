import Cocoa
import UserNotifications

enum PrintTab: String, CaseIterable, Identifiable {
    case overview, printers, jobs, submit, stats, manage
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L10n.t("总览", "Overview")
        case .printers: return L10n.t("打印机", "Printers")
        case .jobs: return L10n.t("任务", "Jobs")
        case .submit: return L10n.t("打印", "Print")
        case .stats: return L10n.t("统计", "Stats")
        case .manage: return L10n.t("管理", "Manage")
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .printers: return "printer"
        case .jobs: return "list.bullet.rectangle"
        case .submit: return "doc.badge.plus"
        case .stats: return "chart.bar"
        case .manage: return "gearshape"
        }
    }
}

/// 打印管理的引擎:同步轮询、通知、提交 / 重打、作业与打印机控制、清理与备份。
///
/// 轮询只在「面板打开」或「有本系统活跃作业」时进行,其余时间没有任何定时器,
/// 保持 PopBar 空闲 CPU ≈ 0。
@MainActor
final class PrintCenter: ObservableObject {
    static let shared = PrintCenter()

    @Published private(set) var data: PrintData
    @Published var tab: PrintTab = .overview
    @Published private(set) var cupsOK = true
    @Published private(set) var cupsError = ""
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    /// 面板底部的一次性消息
    @Published var notice: String?
    /// 任务页预设的打印机过滤(从打印机卡片跳转过来时用)
    @Published var jobsPrinterFilter: String?
    @Published private(set) var lastCleanup: String = ""
    let submit = PrintSubmitModel()

    private var timer: Timer?
    private var failures = 0
    private var firstSyncDone = false
    private var maintenanceTimer: Timer?
    private var noticeToken = 0
    private let ioQueue = DispatchQueue(label: "popbar.print.io", qos: .utility)

    init() {
        PrintStorage.ensureDirs()
        data = PrintStorage.load()
    }

    // MARK: - 持久化

    private func setData(_ d: PrintData) {
        guard d != data else { return }
        data = d
        let snap = d
        ioQueue.async { try? PrintStorage.save(snap) }
    }

    private func mutate(_ f: (inout PrintData) -> Void) {
        var d = data
        f(&d)
        setData(d)
    }

    func say(_ s: String) {
        notice = s
        noticeToken += 1
        let t = noticeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated { if self?.noticeToken == t { self?.notice = nil } }
        }
    }

    // MARK: - 同步

    private typealias Fetched = Result<(printers: [CupsPrinter], jobs: [String: [CupsJob]]), PrintError>

    /// 未完成 + 最近完成:历史全靠本地库,CUPS 清理了也不影响
    nonisolated private static func fetch() -> Fetched {
        switch PrintCUPS.listPrinters() {
        case .failure(let e): return .failure(e)
        case .success(let ps):
            var jobs: [String: [CupsJob]] = [:]
            for p in ps {
                var list: [CupsJob] = []
                if case .success(let a) = PrintCUPS.jobs(printer: p.name, which: "not-completed", limit: 100) { list += a }
                if case .success(let b) = PrintCUPS.jobs(printer: p.name, which: "completed", limit: 30) { list += b }
                jobs[p.name] = list
            }
            return .success((ps, jobs))
        }
    }

    /// 单飞:上一轮没结束就跳过本轮
    func syncNow() {
        guard !syncing else { return }
        syncing = true
        Task.detached(priority: .utility) {
            let r = Self.fetch()
            await MainActor.run { self.apply(r) }
        }
    }

    private func apply(_ r: Fetched) {
        syncing = false
        switch r {
        case .failure(let e):
            failures += 1
            cupsOK = false
            cupsError = e.text
        case .success(let f):
            failures = 0
            cupsOK = true
            cupsError = ""
            var d = data
            let ev = d.merge(printers: f.printers, jobs: f.jobs)
            setData(d)
            lastSync = Date()
            if firstSyncDone { notify(ev) }
            firstSyncDone = true
        }
        scheduleNext()
    }

    /// 面板打开 / 有活跃作业时才排下一轮;连不上 CUPS 时指数退避
    private func pollInterval() -> TimeInterval? {
        let open = ToolPanels.printing.isVisible
        let live = !data.liveJobs.isEmpty
        var base: TimeInterval?
        if open { base = live ? 2 : 6 } else if live { base = 4 }
        guard let b = base else { return nil }
        if failures > 0 { return min(b * pow(2, Double(min(failures, 5))), 60) }
        return b
    }

    private func scheduleNext() {
        timer?.invalidate()
        timer = nil
        guard let iv = pollInterval() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: iv, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
    }

    /// 面板打开时调用
    func panelOpened() {
        syncNow()
        scheduleNext()
    }

    // MARK: - 通知

    private func notify(_ ev: PrintData.SyncEvents) {
        guard data.settings.notify, Bundle.main.bundleIdentifier != nil else { return }
        for j in ev.completed {
            post(title: L10n.t("打印完成", "Print complete"),
                 body: "\(j.title) · \(data.printer(j.printer)?.displayName ?? j.printer)"
                    + (PrintStats.pages(j) > 0 ? L10n.t(" · \(PrintStats.pages(j)) 页", " · \(PrintStats.pages(j)) pages") : ""))
        }
        for j in ev.failed {
            let why = PrintReasons.labels(j.reasons).first ?? j.state.label
            post(title: L10n.t("打印未完成", "Print did not finish"), body: "\(j.title) · \(why)")
        }
    }

    private func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: - 作业控制

    private func run(ok: String, _ work: @escaping @Sendable () -> PrintError?) async {
        let err = await Task.detached(priority: .userInitiated) { work() }.value
        say(err?.text ?? ok)
        syncNow()
    }

    func cancel(_ j: JobRecord) async {
        await run(ok: L10n.t("已取消「\(j.title)」", "Canceled “\(j.title)”")) { PrintCUPS.cancel(printer: j.printer, job: j.cupsJobId) }
    }
    func hold(_ j: JobRecord) async {
        await run(ok: L10n.t("已挂起「\(j.title)」", "Held “\(j.title)”")) { PrintCUPS.hold(printer: j.printer, job: j.cupsJobId) }
    }
    func release(_ j: JobRecord) async {
        await run(ok: L10n.t("已继续「\(j.title)」", "Released “\(j.title)”")) { PrintCUPS.release(printer: j.printer, job: j.cupsJobId) }
    }
    func moveToFront(_ j: JobRecord) async {
        await run(ok: L10n.t("已把「\(j.title)」提到队首", "Moved “\(j.title)” to the front")) {
            PrintCUPS.setPriority(printer: j.printer, job: j.cupsJobId, priority: 99)
        }
    }

    /// 取消该打印机上所有本系统与外部的活跃作业
    func cancelAll(printer: String) async {
        let jobs = data.liveJobs.filter { $0.printer == printer }
        guard !jobs.isEmpty else { return }
        await run(ok: L10n.t("已取消 \(jobs.count) 个任务", "Canceled \(jobs.count) jobs")) {
            var first: PrintError?
            for j in jobs { if let e = PrintCUPS.cancel(printer: j.printer, job: j.cupsJobId), first == nil { first = e } }
            return first
        }
    }

    // MARK: - 打印机控制

    func pause(_ name: String) async { await run(ok: L10n.t("已暂停", "Paused")) { PrintCUPS.pause(name) } }
    func resume(_ name: String) async { await run(ok: L10n.t("已恢复", "Resumed")) { PrintCUPS.resume(name) } }
    func setAccepting(_ name: String, _ on: Bool) async {
        await run(ok: on ? L10n.t("已开始接收作业", "Accepting jobs") : L10n.t("已停止接收作业", "Rejecting jobs")) {
            PrintCUPS.setAccepting(name, on)
        }
    }

    // MARK: - 打印机本地信息

    func updateLocal(_ name: String, alias: String? = nil, note: String? = nil, favorite: Bool? = nil) {
        mutate { d in
            guard let i = d.printers.firstIndex(where: { $0.name == name }) else { return }
            if let alias { d.printers[i].alias = String(alias.trimmingCharacters(in: .whitespaces).prefix(60)) }
            if let note { d.printers[i].note = String(note.prefix(200)) }
            if let favorite { d.printers[i].favorite = favorite }
        }
    }

    func setDefault(_ name: String, syncSystem: Bool) async {
        mutate { $0.settings.defaultPrinter = name }
        if syncSystem {
            let err = await Task.detached { PrintCUPS.setSystemDefault(name) }.value
            say(err?.text ?? L10n.t("已设为默认打印机(含系统默认)", "Set as default (including the system default)"))
        } else {
            say(L10n.t("已设为 PopBar 默认打印机", "Set as PopBar's default printer"))
        }
    }

    // MARK: - 添加 / 删除 / 恢复

    @discardableResult
    func addPrinter(name: String, uri: String, description: String = "", location: String = "") async -> Bool {
        let err = await Task.detached(priority: .userInitiated) {
            PrintCUPS.add(name: name, uri: uri, description: description, location: location)
        }.value
        if let err { say(err.text); return false }
        // 同名的软删除记录:显式恢复,而不是插一条新的
        mutate { d in
            if let i = d.printers.firstIndex(where: { $0.name == name }) { d.printers[i].hidden = false; d.printers[i].missing = false }
        }
        say(L10n.t("已添加打印机「\(name)」", "Added printer “\(name)”"))
        syncNow()
        return true
    }

    /// 删除打印机:真删 CUPS 队列,本地只做软删除。
    /// 绝不能把记录整个删掉——它的历史作业与统计要保留,管理页还能恢复
    func removePrinter(_ name: String) async {
        let err = await Task.detached(priority: .userInitiated) { PrintCUPS.remove(name) }.value
        if let err { say(err.text); return }
        mutate { d in
            if let i = d.printers.firstIndex(where: { $0.name == name }) {
                d.printers[i].hidden = true
                d.printers[i].queued = 0
            }
            for k in d.jobs.indices where d.jobs[k].printer == name && d.jobs[k].state.isActive { d.jobs[k].cupsMissing = true }
            if d.settings.defaultPrinter == name { d.settings.defaultPrinter = "" }
        }
        say(L10n.t("已删除「\(name)」(历史任务保留,可在管理页恢复)", "Removed “\(name)” (history kept; restore from Manage)"))
        syncNow()
    }

    func restorePrinter(_ name: String) {
        mutate { d in
            if let i = d.printers.firstIndex(where: { $0.name == name }) { d.printers[i].hidden = false }
        }
        say(L10n.t("已恢复「\(name)」", "Restored “\(name)”"))
        syncNow()
    }

    func discover() async -> [PrintCUPS.Discovered] {
        let existing = await Task.detached { () -> [CupsPrinter] in
            if case .success(let p) = PrintCUPS.listPrinters() { return p }
            return []
        }.value
        return await Task.detached(priority: .userInitiated) { PrintCUPS.discover(existing: existing) }.value
    }

    // MARK: - 提交 / 重打

    /// 提交一个已准备好的文件。成功返回新作业记录。
    func submitFile(_ f: PreparedFile, printer name: String, options: PrintOptions,
                    title: String? = nil) async -> Result<JobRecord, PrintError> {
        guard let pr = data.printer(name), !pr.hidden, !pr.missing else {
            return .failure(.message(L10n.t("打印机不存在或已删除", "The printer does not exist or was removed")))
        }
        if !pr.accepting { return .failure(.message(L10n.t("打印机当前不接受新作业(已停止接收)", "The printer is not accepting jobs"))) }
        if pr.state == PrinterStateCode.stopped {
            return .failure(.message(L10n.t("打印机已暂停,请先恢复后再提交", "The printer is paused — resume it first")))
        }
        let caps = pr.caps
        let jobTitle = String((title ?? f.displayName).prefix(200))
        let id = UUID().uuidString

        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Int, PrintError> in
            do {
                try PrintOptionBuilder.checkMime(f.mime, caps: caps)
                let ipp = try PrintOptionBuilder.build(options, caps: caps, pageCount: f.pages)
                // 预检:参数组合不合规在这里就会返回,不会产生作业
                if let e = PrintCUPS.validate(printer: name, file: f.url.path, mime: f.mime, title: jobTitle, options: ipp) {
                    return .failure(e)
                }
                return PrintCUPS.submit(printer: name, file: f.url.path, mime: f.mime, title: jobTitle, options: ipp)
            } catch let e as PrintError {
                return .failure(e)
            } catch {
                return .failure(.message(error.localizedDescription))
            }
        }.value

        switch outcome {
        case .failure(let e): return .failure(e)
        case .success(let cupsId):
            var rec = JobRecord(id: id, printer: name, cupsJobId: cupsId, state: .pending, reasons: ["job-queued"],
                                created: Date(), source: .app, title: jobTitle, fileName: f.displayName,
                                mime: f.mime, sizeBytes: f.size, pageCount: f.pages,
                                copies: options.copies, options: options)
            // 原文件复制进作业目录长期保存(暂存区随后清掉),重打要用
            let persisted = await Task.detached { Self.persist(file: f.url, kind: f.kind, jobID: id) }.value
            rec.storedFile = persisted.file
            rec.hasThumb = persisted.thumb
            rec.localError = persisted.error
            mutate { $0.addAppJob(rec) }
            syncNow()      // 暂存文件不在这里删:提交后页缩略图还要用,由「移除/清空」或重打流程清理
            scheduleNext()
            return .success(data.job(rec.id) ?? rec)
        }
    }

    nonisolated private static func persist(file: URL, kind: PrintFileKind, jobID: String) -> (file: String, thumb: Bool, error: String) {
        let fm = FileManager.default
        let rel = "jobs/\(jobID)"
        let dir = PrintStorage.path(rel)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let dest = dir.appendingPathComponent("orig." + (file.pathExtension.isEmpty ? "pdf" : file.pathExtension))
            try fm.copyItem(at: file, to: dest)
            var thumb = false
            if let png = PrintFiles.thumbnailPNG(for: dest, kind: kind, side: 140) {
                thumb = (try? png.write(to: dir.appendingPathComponent("thumb.png"))) != nil
            }
            return ("\(rel)/\(dest.lastPathComponent)", thumb, "")
        } catch {
            return ("", false, L10n.t("保存文件副本失败:", "Failed to keep a copy: ") + error.localizedDescription)
        }
    }

    func fileURL(_ j: JobRecord) -> URL? {
        guard !j.storedFile.isEmpty else { return nil }
        let u = PrintStorage.path(j.storedFile)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func thumbURL(_ j: JobRecord) -> URL? {
        guard j.hasThumb else { return nil }
        let u = PrintStorage.path("jobs/\(j.id)/thumb.png")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 原样重打:复用保存的原文件与原参数
    func reprint(_ j: JobRecord, copies: Int? = nil, hold: Bool = false) async -> Result<JobRecord, PrintError> {
        guard let src = fileURL(j) else {
            return .failure(.message(L10n.t("原文件已被清理,无法重新打印", "The original file was cleaned up — cannot reprint")))
        }
        let kind: PrintFileKind = j.mime == "application/pdf" ? .pdf : .image
        // 复制一份进暂存区:提交成功后暂存文件会被删掉,不能动作业目录里的原件
        let staged = PrintStorage.stagingDir.appendingPathComponent("\(UUID().uuidString).\(src.pathExtension)")
        do { try FileManager.default.copyItem(at: src, to: staged) } catch {
            return .failure(.message(error.localizedDescription))
        }
        var opts = j.options
        if let copies { opts.copies = copies }
        opts.hold = hold       // 重打不继承原来的「先挂起」
        let f = PreparedFile(id: UUID().uuidString, displayName: j.fileName.isEmpty ? j.title : j.fileName, url: staged,
                             mime: j.mime, originalMime: j.mime, kind: kind, size: j.sizeBytes, pages: j.pageCount)
        let r = await submitFile(f, printer: j.printer, options: opts, title: j.title)
        try? FileManager.default.removeItem(at: staged)     // 无论成败,重打的暂存副本都用完了
        return r
    }

    // MARK: - 设置 / 预设

    func updateSettings(_ f: (inout PrintSettings) -> Void) { mutate { f(&$0.settings) } }

    func addPreset(name: String, printer: String?, options: PrintOptions) -> String? {
        var d = data
        do { _ = try d.addPreset(name: name, printer: printer, options: options) } catch { return (error as? PrintError)?.text ?? "\(error)" }
        setData(d)
        return nil
    }
    func deletePreset(_ id: String) { mutate { $0.deletePreset(id) } }
    func renamePreset(_ id: String, name: String) -> String? {
        var d = data
        do { try d.renamePreset(id, name: name) } catch { return (error as? PrintError)?.text ?? "\(error)" }
        setData(d)
        return nil
    }
    func updatePreset(_ id: String, options: PrintOptions) { mutate { $0.updatePresetOptions(id, options: options) } }

    // MARK: - 维护:清理

    /// 外部作业超期连记录删;本系统作业只删超期原文件;顺带清孤儿目录与过期暂存。
    /// 活跃作业永远不碰
    @discardableResult
    func runCleanup(dryRun: Bool = false) -> PrintData.CleanupResult {
        var d = data
        var res = d.cleanup(dryRun: dryRun)
        let live = Set(d.jobs.map(\.id))
        let orphans = PrintStorage.orphanJobDirs(live: live)
        let stale = PrintStorage.staleStaging()
        res.filesDeleted += orphans.count   // 孤儿目录按「文件」计
        if !dryRun {
            setData(d)
            let dirs = res.dirsToRemove.map { PrintStorage.path($0) } + orphans + stale
            ioQueue.async { for u in dirs { try? FileManager.default.removeItem(at: u) } }
            lastCleanup = L10n.t("\(Date().formatted(date: .abbreviated, time: .shortened)) · 清理 \(res.rowsDeleted) 条记录、\(res.filesDeleted) 份原文件",
                                 "\(Date().formatted(date: .abbreviated, time: .shortened)) · removed \(res.rowsDeleted) records, \(res.filesDeleted) files")
        }
        return res
    }

    /// 启动后延迟 60 秒跑第一次(不和首轮同步抢 IO),之后每 maintenanceIntervalHours 小时一次
    func startMaintenance() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.runCleanup()
                let hours = Double(self.data.settings.maintenanceIntervalHours)
                self.maintenanceTimer = Timer.scheduledTimer(withTimeInterval: hours * 3600, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { _ = self?.runCleanup() }
                }
            }
        }
    }

    // MARK: - 备份 / 恢复

    /// 打包 Print 目录(print.json + jobs/,不含暂存区)
    func backup(to url: URL) async -> PrintError? {
        let parent = PrintStorage.directory.deletingLastPathComponent().path
        let r = await Task.detached(priority: .userInitiated) {
            ShellRun.run("/usr/bin/tar", ["-czf", url.path, "--exclude", "Print/staging", "-C", parent, "Print"], timeout: 300)
        }.value
        return r.status == 0 ? nil : .message(r.err.isEmpty ? L10n.t("备份失败", "Backup failed") : r.err)
    }

    /// 恢复:先校验归档只含 Print/ 下的条目,旧数据改名保留为 Print.bak-<时间>
    func restore(from url: URL) async -> PrintError? {
        let parent = PrintStorage.directory.deletingLastPathComponent()
        let dir = PrintStorage.directory
        let err: PrintError? = await Task.detached(priority: .userInitiated) {
            let list = ShellRun.run("/usr/bin/tar", ["-tzf", url.path], timeout: 60)
            guard list.status == 0 else { return .message(L10n.t("不是有效的备份文件", "Not a valid backup archive")) }
            let names = list.out.split(separator: "\n").map(String.init)
            guard !names.isEmpty, names.allSatisfy({ ($0 == "Print/" || $0.hasPrefix("Print/")) && !$0.contains("..") }) else {
                return .message(L10n.t("备份文件内容不符合预期,已拒绝恢复", "Unexpected archive contents — restore refused"))
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: dir.path) {
                let bak = parent.appendingPathComponent("Print.bak-\(Int(Date().timeIntervalSince1970))")
                do { try fm.moveItem(at: dir, to: bak) } catch { return .message(error.localizedDescription) }
            }
            let x = ShellRun.run("/usr/bin/tar", ["-xzf", url.path, "-C", parent.path], timeout: 300)
            return x.status == 0 ? nil : .message(x.err)
        }.value
        if err == nil {
            PrintStorage.ensureDirs()
            data = PrintStorage.load()
            syncNow()
        }
        return err
    }
}
