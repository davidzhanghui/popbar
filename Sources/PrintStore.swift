import Foundation

/// 打印管理的本地数据与纯逻辑:同步合并、清理策略、用量统计、预设。
///
/// **字段分栏**(移植自 easy-print 的核心约束):每条记录的字段分成两半,同步只写前半段。
///
/// | 归属 | PrinterRecord | JobRecord |
/// |---|---|---|
/// | CUPS(每轮覆盖) | state / reasons / markers / caps … | state / reasons / impressions / created … |
/// | 本系统(永不覆盖) | alias / note / favorite / hidden | title / fileName / storedFile / copies / options / source |
///
/// 一旦让同步碰到本地字段,用户改过的别名、备注和文件路径就会被轮询抹掉。
/// 数据存成一个 JSON 文件(print.json)+ jobs/ 目录里的原文件副本。

struct PrinterRecord: Codable, Equatable, Identifiable {
    var id: String { name }
    // —— CUPS 字段 ——
    var name: String
    var info: String
    var makeModel: String = ""
    var location: String = ""
    var state: Int = 0
    var reasons: [String] = []
    var stateMessage: String = ""
    var accepting: Bool = true
    var queued: Int = 0
    var markers: [PrintMarker] = []
    var caps = PrintCaps()
    var uri: String = ""
    var lastSeen: Date = .distantPast
    // —— 本地字段 ——
    var alias: String = ""
    var note: String = ""
    var favorite: Bool = false
    /// 软删除:lpadmin -x 成功后只标 hidden,历史作业原样保留
    var hidden: Bool = false
    /// CUPS 里已经没有这台打印机
    var missing: Bool = false

    var displayName: String { alias.isEmpty ? info : alias }
}

enum JobSource: String, Codable { case app, external }

struct JobRecord: Codable, Equatable, Identifiable {
    var id: String
    var printer: String
    var cupsJobId: Int
    // —— CUPS 字段 ——
    var state: JobState = .pending
    var reasons: [String] = []
    var message: String = ""
    var impressions: Int = 0
    var impressionsDone: Int = 0
    var created: Date
    var processing: Date?
    var completed: Date?
    var cupsUser: String = ""
    /// CUPS 已经清掉这个作业(完成后超出保留数量),本地历史还在
    var cupsMissing: Bool = false
    // —— 本地字段 ——
    var source: JobSource = .external
    var title: String
    var fileName: String = ""
    var mime: String = ""
    var sizeBytes: Int = 0
    var pageCount: Int?
    var copies: Int = 1
    var options = PrintOptions()
    /// 相对 Print 目录的原文件副本路径;空 = 没有(外部作业,或已被清理)
    var storedFile: String = ""
    var hasThumb: Bool = false
    var localError: String = ""

    /// 仍在队列里(CUPS 清理掉的不算:它的终态我们没看到)
    var isLive: Bool { state.isActive && !cupsMissing }
}

struct PrintPreset: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    /// nil = 通用预设,对每台打印机可见
    var printer: String?
    var options: PrintOptions
}

struct PrintSettings: Codable, Equatable {
    var defaultPrinter: String = ""
    var defaultOptions: PrintOptions = {
        var o = PrintOptions()
        o.color = "color"; o.quality = "normal"; o.sides = "one-sided"; o.scaling = "fit"
        return o
    }()
    var confirmBeforePrint = true
    /// 作业完成 / 失败时发系统通知
    var notify = true
    /// 墨量低于该百分比预警
    var lowInkThreshold = 15
    /// 本系统提交的作业:超过天数只保留记录,删掉原文件
    var jobFileRetentionDays = 30
    /// 外部作业:超过天数连记录一起删
    var externalJobKeepDays = 7
    var maintenanceIntervalHours = 6

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrintSettings()
        defaultPrinter = (try? c.decode(String.self, forKey: .defaultPrinter)) ?? d.defaultPrinter
        defaultOptions = (try? c.decode(PrintOptions.self, forKey: .defaultOptions)) ?? d.defaultOptions
        confirmBeforePrint = (try? c.decode(Bool.self, forKey: .confirmBeforePrint)) ?? d.confirmBeforePrint
        notify = (try? c.decode(Bool.self, forKey: .notify)) ?? d.notify
        lowInkThreshold = min(max((try? c.decode(Int.self, forKey: .lowInkThreshold)) ?? d.lowInkThreshold, 1), 90)
        jobFileRetentionDays = max((try? c.decode(Int.self, forKey: .jobFileRetentionDays)) ?? d.jobFileRetentionDays, 1)
        externalJobKeepDays = max((try? c.decode(Int.self, forKey: .externalJobKeepDays)) ?? d.externalJobKeepDays, 1)
        maintenanceIntervalHours = max((try? c.decode(Int.self, forKey: .maintenanceIntervalHours)) ?? d.maintenanceIntervalHours, 1)
    }
}

struct PrintData: Codable, Equatable {
    var printers: [PrinterRecord] = []
    var jobs: [JobRecord] = []
    var presets: [PrintPreset] = []
    var settings = PrintSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        printers = (try? c.decode([PrinterRecord].self, forKey: .printers)) ?? []
        jobs = (try? c.decode([JobRecord].self, forKey: .jobs)) ?? []
        presets = (try? c.decode([PrintPreset].self, forKey: .presets)) ?? []
        settings = (try? c.decode(PrintSettings.self, forKey: .settings)) ?? PrintSettings()
    }

    // MARK: - 查询

    func printer(_ name: String) -> PrinterRecord? { printers.first { $0.name == name } }
    func job(_ id: String) -> JobRecord? { jobs.first { $0.id == id } }

    /// 界面上可见的打印机:收藏优先,其次按名称
    var visiblePrinters: [PrinterRecord] {
        printers.filter { !$0.hidden }.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    var liveJobs: [JobRecord] { jobs.filter(\.isLive) }

    /// 默认打印机:设置里的唯一来源(CUPS 的默认存在 ~/.cups/lpoptions,常常读不到);没设就退回第一台可见的
    func defaultPrinter() -> PrinterRecord? {
        let vis = visiblePrinters
        return vis.first { $0.name == settings.defaultPrinter } ?? vis.first
    }

    /// 按时间倒序
    func sortedJobs() -> [JobRecord] {
        jobs.sorted { ($0.created, $0.id) > ($1.created, $1.id) }
    }

    /// 低墨量:按打印机归组(一台缺四个色时,不能把机器名重复四遍)
    func lowInk() -> [(printer: PrinterRecord, markers: [PrintMarker])] {
        visiblePrinters.compactMap { p in
            let low = PrintMarkers.low(p.markers, threshold: settings.lowInkThreshold)
            return low.isEmpty ? nil : (p, low)
        }
    }

    // MARK: - 同步合并

    struct SyncEvents: Equatable {
        /// 本轮刚从「未完成」迁移到「已完成」的作业
        var completed: [JobRecord] = []
        /// 本轮刚迁移到取消/中止的本系统作业
        var failed: [JobRecord] = []
        var newJobs = 0
    }

    /// CUPS → 本地。只写 CUPS 字段。`jobs` 以打印机名为键。
    /// 完成事件挂在「状态真的迁移到 completed」:首次同步进来的历史作业没有 prev,不会误报。
    mutating func merge(printers cups: [CupsPrinter], jobs cupsJobs: [String: [CupsJob]], now: Date = Date()) -> SyncEvents {
        var ev = SyncEvents()
        let seen = Set(cups.map(\.name))

        for p in cups {
            if let i = printers.firstIndex(where: { $0.name == p.name }) {
                printers[i].info = p.info
                printers[i].makeModel = p.makeModel
                printers[i].location = p.location
                printers[i].state = p.state
                printers[i].reasons = p.reasons
                printers[i].stateMessage = p.stateMessage
                printers[i].accepting = p.accepting
                printers[i].queued = p.queued
                printers[i].markers = p.markers
                printers[i].caps = p.caps
                printers[i].uri = p.uri
                // 不是每轮都写:否则数据每次同步都「变化」,白白触发落盘与界面刷新
                if now.timeIntervalSince(printers[i].lastSeen) > 300 { printers[i].lastSeen = now }
                printers[i].missing = false
            } else {
                printers.append(PrinterRecord(name: p.name, info: p.info, makeModel: p.makeModel, location: p.location,
                                              state: p.state, reasons: p.reasons, stateMessage: p.stateMessage,
                                              accepting: p.accepting, queued: p.queued, markers: p.markers,
                                              caps: p.caps, uri: p.uri, lastSeen: now))
            }
        }
        // CUPS 里消失的打印机:保留本地记录,标出来
        for i in printers.indices where !seen.contains(printers[i].name) { printers[i].missing = true }

        for (printer, list) in cupsJobs {
            var seenIds = Set<String>()
            for cj in list {
                if let i = jobs.firstIndex(where: { $0.printer == printer && $0.cupsJobId == cj.id
                                                    && abs($0.created.timeIntervalSince(cj.created)) < 60 }) {
                    let prev = jobs[i].state
                    jobs[i].state = cj.state
                    jobs[i].reasons = cj.reasons
                    jobs[i].message = cj.message
                    jobs[i].impressions = cj.impressions
                    jobs[i].impressionsDone = cj.impressionsDone
                    jobs[i].created = cj.created
                    jobs[i].processing = cj.processing
                    jobs[i].completed = cj.completed
                    jobs[i].cupsUser = cj.user
                    jobs[i].cupsMissing = false
                    seenIds.insert(jobs[i].id)
                    if prev != .completed && cj.state == .completed { ev.completed.append(jobs[i]) }
                    // 失败通知只给「中止」和「明确由设备 / 管理员取消」的本系统作业。
                    // CUPS 对用户自己取消只回 processing-to-stop-point,无法与别的取消区分,所以不对「取消」一概报警
                    else if jobs[i].source == .app, !prev.isFailed, prev != .completed,
                            cj.state == .aborted
                                || (cj.state == .canceled && cj.reasons.contains { $0 == "job-canceled-at-device" || $0 == "job-canceled-by-operator" }) {
                        ev.failed.append(jobs[i])
                    }
                } else {
                    let r = JobRecord(id: UUID().uuidString, printer: printer, cupsJobId: cj.id,
                                      state: cj.state, reasons: cj.reasons, message: cj.message,
                                      impressions: cj.impressions, impressionsDone: cj.impressionsDone,
                                      created: cj.created, processing: cj.processing, completed: cj.completed,
                                      cupsUser: cj.user, source: .external,
                                      title: cj.name.isEmpty ? "#\(cj.id)" : cj.name,
                                      pageCount: cj.impressions > 0 ? cj.impressions : nil)
                    jobs.append(r)
                    seenIds.insert(r.id)
                    ev.newJobs += 1
                }
            }
            // 这台打印机上本地仍「活跃」却没在 CUPS 列表里出现:CUPS 已完成并清理,保留历史
            for i in jobs.indices where jobs[i].printer == printer && jobs[i].state.isActive
                && !jobs[i].cupsMissing && !seenIds.contains(jobs[i].id) {
                jobs[i].cupsMissing = true
            }
        }
        return ev
    }

    /// 登记本系统刚提交的作业。提交与同步可能交错:同步先看到这个作业时它已作为「外部」记录入库,
    /// 这里把本地字段并进去(CUPS 字段保留同步来的最新值),不能再插一条重复的
    mutating func addAppJob(_ r: JobRecord) {
        guard let i = jobs.firstIndex(where: { $0.source == .external && $0.printer == r.printer
                                               && $0.cupsJobId == r.cupsJobId
                                               && abs($0.created.timeIntervalSince(r.created)) < 60 }) else {
            jobs.append(r)
            return
        }
        let ex = jobs[i]
        var n = r
        n.state = ex.state; n.reasons = ex.reasons; n.message = ex.message
        n.impressions = ex.impressions; n.impressionsDone = ex.impressionsDone
        n.created = ex.created; n.processing = ex.processing; n.completed = ex.completed
        n.cupsUser = ex.cupsUser; n.cupsMissing = ex.cupsMissing
        jobs[i] = n
    }

    // MARK: - 清理策略(唯一会删数据的地方,所以两条线分开)

    struct CleanupResult: Equatable {
        var rowsDeleted = 0
        var filesDeleted = 0
        /// 需要从磁盘删除的相对路径(作业目录)
        var dirsToRemove: [String] = []
    }

    /// 外部作业超期 → 连记录带文件删;本系统作业 → 记录永远保留(历史和统计要用),
    /// 只删超期的原文件并把 storedFile 置空、localError 记一行;活跃作业无论多老都不碰。
    /// `now` 可注入,测试时把时钟拨到未来。
    mutating func cleanup(now: Date = Date(), dryRun: Bool = false) -> CleanupResult {
        var res = CleanupResult()
        let extCutoff = now.addingTimeInterval(-Double(settings.externalJobKeepDays) * 86400)
        let fileCutoff = now.addingTimeInterval(-Double(settings.jobFileRetentionDays) * 86400)

        let dead = Set(jobs.filter { $0.source == .external && $0.created < extCutoff && !$0.state.isActive }.map(\.id))
        for j in jobs where dead.contains(j.id) && !j.storedFile.isEmpty {
            res.dirsToRemove.append((j.storedFile as NSString).deletingLastPathComponent)
        }
        res.rowsDeleted = dead.count

        for i in jobs.indices {
            let j = jobs[i]
            guard !dead.contains(j.id), !j.storedFile.isEmpty, !j.state.isActive else { continue }
            // 完成时间缺失时退回创建时间,否则老作业永远不会被清
            if (j.completed ?? j.created) < fileCutoff {
                res.filesDeleted += 1
                res.dirsToRemove.append((j.storedFile as NSString).deletingLastPathComponent)
                if !dryRun {
                    jobs[i].storedFile = ""
                    jobs[i].hasThumb = false
                    jobs[i].localError = L10n.t("原文件已按 \(settings.jobFileRetentionDays) 天保留策略清理",
                                                "Original file removed by the \(settings.jobFileRetentionDays)-day retention policy")
                }
            }
        }
        if !dryRun { jobs.removeAll { dead.contains($0.id) } }
        return res
    }

    // MARK: - 预设

    func presets(for printer: String?) -> [PrintPreset] {
        presets.filter { $0.printer == nil || $0.printer == printer }
    }

    static func cleanPresetName(_ s: String) throws -> String {
        let n = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { throw PrintError.message(L10n.t("预设名称不能为空", "Preset name is empty")) }
        return String(n.prefix(40))
    }

    mutating func addPreset(name: String, printer: String?, options: PrintOptions) throws -> PrintPreset {
        let n = try Self.cleanPresetName(name)
        if presets.contains(where: { $0.name == n && $0.printer == printer }) {
            throw PrintError.message(L10n.t("已经有同名预设", "A preset with this name already exists"))
        }
        let p = PrintPreset(name: n, printer: printer, options: options.presetSanitized())
        presets.append(p)
        return p
    }

    /// 清掉与某台打印机无关的预设引用(打印机永久不存在时用不到;软删除保留预设)
    mutating func deletePreset(_ id: String) { presets.removeAll { $0.id == id } }

    mutating func renamePreset(_ id: String, name: String) throws {
        let n = try Self.cleanPresetName(name)
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = n
    }

    mutating func updatePresetOptions(_ id: String, options: PrintOptions) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].options = options.presetSanitized()
    }
}

// MARK: - 用量统计

struct PrintStatsSummary: Equatable {
    struct Bucket: Equatable, Identifiable {
        var key: String
        var jobs: Int
        var pages: Int
        var id: String { key }
    }
    var days: Int
    var jobs = 0, completed = 0, failed = 0, active = 0, pages = 0
    var byWeek: [Bucket] = []
    var byDay: [Bucket] = []
    var byPrinter: [Bucket] = []
    var byState: [Bucket] = []
    var bySource: [Bucket] = []
}

enum PrintStats {
    /// 页数口径三段降级:job-impressions → job-impressions-completed → pageCount × copies。
    /// CUPS 的 impressions 在作业结束前一直是 0,而本系统作业记了页数与份数。
    /// 只统计已完成的作业。
    static func pages(_ j: JobRecord) -> Int {
        guard j.state == .completed else { return 0 }
        if j.impressions > 0 { return j.impressions }
        if j.impressionsDone > 0 { return j.impressionsDone }
        if let p = j.pageCount { return p * max(j.copies, 1) }
        return 0
    }

    private static func fmt(_ f: String, tz: TimeZone) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = tz
        d.dateFormat = f
        return d
    }

    static func summary(_ data: PrintData, days: Int, now: Date = Date(), calendar: Calendar = .current) -> PrintStatsSummary {
        let n = max(days, 1)
        let since = now.addingTimeInterval(-Double(n) * 86400)
        let jobs = data.jobs.filter { $0.created >= since }
        var s = PrintStatsSummary(days: n)
        s.jobs = jobs.count
        s.completed = jobs.filter { $0.state == .completed }.count
        s.failed = jobs.filter { $0.state.isFailed }.count
        s.active = jobs.filter(\.isLive).count
        s.pages = jobs.reduce(0) { $0 + pages($1) }

        func group(_ key: (JobRecord) -> String) -> [PrintStatsSummary.Bucket] {
            var m: [String: (Int, Int)] = [:]
            for j in jobs { let k = key(j); let o = m[k] ?? (0, 0); m[k] = (o.0 + 1, o.1 + pages(j)) }
            return m.map { .init(key: $0.key, jobs: $0.value.0, pages: $0.value.1) }
        }
        let tz = calendar.timeZone
        let weekF = fmt("yyyy-'W'ww", tz: tz), dayF = fmt("yyyy-MM-dd", tz: tz)
        s.byWeek = group { weekF.string(from: $0.created) }.sorted { $0.key < $1.key }
        // 按日:只取最近 30 天,并补成从起始日到今天连续的序列(缺的记 0)。
        // 只返回有数据的日子,柱状图上 9/23 的柱子会紧贴在 10/9 旁边,日历轴对不上
        let dayStart = calendar.startOfDay(for: max(since, now.addingTimeInterval(-30 * 86400)))
        var dayMap: [String: (Int, Int)] = [:]
        for j in jobs where j.created >= dayStart {
            let k = dayF.string(from: j.created); let o = dayMap[k] ?? (0, 0)
            dayMap[k] = (o.0 + 1, o.1 + pages(j))
        }
        var d = dayStart
        let today = calendar.startOfDay(for: now)
        if !jobs.isEmpty {
            while d <= today {
                let k = dayF.string(from: d)
                let v = dayMap[k] ?? (0, 0)
                s.byDay.append(.init(key: k, jobs: v.0, pages: v.1))
                guard let nx = calendar.date(byAdding: .day, value: 1, to: d) else { break }
                d = nx
            }
        }
        let names = Dictionary(uniqueKeysWithValues: data.printers.map { ($0.name, $0.displayName) })
        s.byPrinter = group { names[$0.printer] ?? $0.printer }.sorted { ($0.pages, $0.jobs) > ($1.pages, $1.jobs) }
        s.byState = group { $0.state.rawValue }.sorted { $0.jobs > $1.jobs }
        s.bySource = group { $0.source.rawValue }
        return s
    }
}

// MARK: - 磁盘

enum PrintStorage {
    /// ~/Library/Application Support/PopBar/Print;POPBAR_CONFIG_DIR 覆盖时跟着走(测试用)
    static var directory: URL { PopBarConfig.directoryURL.appendingPathComponent("Print", isDirectory: true) }
    static var jsonURL: URL { directory.appendingPathComponent("print.json") }
    static var jobsDir: URL { directory.appendingPathComponent("jobs", isDirectory: true) }
    static var stagingDir: URL { directory.appendingPathComponent("staging", isDirectory: true) }

    static func ensureDirs() {
        for d in [directory, jobsDir, stagingDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
    }

    /// 读盘;文件不存在返回空数据,损坏时把原文件改名留底再返回空数据(不静默覆盖用户数据)
    static func load(from url: URL = jsonURL) -> PrintData {
        guard let raw = try? Data(contentsOf: url) else { return PrintData() }
        if let d = try? JSONDecoder.printDecoder.decode(PrintData.self, from: raw) { return d }
        let bak = url.deletingLastPathComponent().appendingPathComponent("print.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: bak)
        return PrintData()
    }

    static func save(_ data: PrintData, to url: URL = jsonURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder.printEncoder
        try enc.encode(data).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func path(_ rel: String) -> URL { directory.appendingPathComponent(rel) }

    /// 作业目录里没有对应记录的孤儿目录
    static func orphanJobDirs(live: Set<String>) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: jobsDir.path)) ?? []
        return names.filter { !live.contains($0) }.map { jobsDir.appendingPathComponent($0) }
    }

    /// 暂存区里超过 keepDays 天的残留
    static func staleStaging(keepDays: Int = 7, now: Date = Date()) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter {
            let m = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return now.timeIntervalSince(m) > Double(keepDays) * 86400
        }
    }
}

extension JSONEncoder {
    static var printEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

extension JSONDecoder {
    static var printDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
