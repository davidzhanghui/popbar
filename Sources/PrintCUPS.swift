import Foundation

/// CUPS 高层封装:查询打印机/作业、提交打印、控制队列、增删与发现打印机。
/// 全部是同步阻塞调用,只在后台线程使用。
///
/// 分工(移植自 easy-print,但 libcups 走本地 socket 自带认证,管理类操作也能直接走 IPP):
///   读 + 打印 + 作业/队列控制 → IPP
///   增删打印机(lpadmin)、局域网发现(ippfind)→ CLI,只看退出码,绝不解析本地化输出
struct CupsPrinter: Equatable {
    var name: String
    var info: String
    var makeModel: String
    var location: String
    var state: Int
    var reasons: [String]
    var stateMessage: String
    var accepting: Bool
    var queued: Int
    var markers: [PrintMarker]
    var caps: PrintCaps
    var uri: String
    var deviceURI: String
    var uuid: String
}

struct CupsJob: Equatable {
    var id: Int
    var printer: String
    var name: String
    var user: String
    var state: JobState
    var reasons: [String]
    var message: String
    var impressions: Int
    var impressionsDone: Int
    var kOctets: Int
    var created: Date
    var processing: Date?
    var completed: Date?
}

enum PrintCUPS {
    private static let printerAttrs = [
        "printer-name", "printer-info", "printer-make-and-model", "printer-location",
        "printer-state", "printer-state-reasons", "printer-state-message",
        "printer-is-accepting-jobs", "queued-job-count", "printer-uri-supported", "printer-uuid",
        "device-uri", "marker-levels", "marker-names", "marker-colors", "marker-high-levels",
        "media-default", "media-supported", "media-type-supported", "media-ready",
        "color-supported", "sides-supported", "copies-supported",
        "print-color-mode-supported", "print-quality-supported", "number-up-supported",
        "orientation-requested-supported", "page-ranges-supported", "print-scaling-supported",
        "document-format-supported", "job-hold-until-supported",
    ]
    private static let jobAttrs = [
        "job-id", "job-name", "job-state", "job-state-reasons", "job-printer-state-message",
        "job-originating-user-name", "time-at-creation", "time-at-processing", "time-at-completed",
        "job-impressions", "job-impressions-completed", "job-k-octets", "job-printer-uri",
    ]

    private static func op(_ name: String, _ v: IPPOut) -> IPPAttrOut {
        IPPAttrOut(group: IPP_TAG_OPERATION, name: name, value: v)
    }

    // MARK: - 打印机

    static func printer(from g: IPPGroup) -> CupsPrinter? {
        guard let name = g.str("printer-name") else { return nil }
        return CupsPrinter(
            name: name,
            info: g.str("printer-info") ?? name,
            makeModel: g.str("printer-make-and-model") ?? "",
            location: g.str("printer-location") ?? "",
            state: g.int("printer-state") ?? 0,
            reasons: g.strs("printer-state-reasons"),
            stateMessage: g.str("printer-state-message") ?? "",
            accepting: g.bool("printer-is-accepting-jobs") != false,
            queued: g.int("queued-job-count") ?? 0,
            markers: PrintMarkers.parse(g),
            caps: PrintCaps(g),
            uri: g.str("printer-uri-supported") ?? "",
            deviceURI: g.str("device-uri") ?? "",
            uuid: g.str("printer-uuid") ?? "")
    }

    /// 列出 CUPS 里所有打印机(一次请求拿全部)
    static func listPrinters() -> Result<[CupsPrinter], PrintError> {
        let r = IPPClient.call(IPP_OP_CUPS_GET_PRINTERS, attrs: [
            op("requested-attributes", .keyword(printerAttrs)),
            op("which-printers", .keyword(["all"])),
        ], timeoutMs: 8000)
        switch r {
        case .failure(let e): return .failure(e)
        case .success(let rsp):
            // 没有任何打印机时 CUPS-Get-Printers 可能返回 not-found:视为空列表
            if rsp.status == 0x0406 { return .success([]) }
            guard rsp.ok else { return .failure(.status(rsp.status, rsp.statusMessage)) }
            return .success(rsp.printers.compactMap(printer(from:)))
        }
    }

    // MARK: - 作业

    static func job(from g: IPPGroup, printer: String) -> CupsJob? {
        guard let id = g.int("job-id") else { return nil }
        func date(_ n: String) -> Date? {
            guard let s = g.int(n), s > 1_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(s))
        }
        return CupsJob(
            id: id, printer: printer,
            name: g.str("job-name") ?? "",
            user: g.str("job-originating-user-name") ?? "",
            state: JobState(cups: g.int("job-state") ?? 0),
            reasons: g.strs("job-state-reasons"),
            message: g.str("job-printer-state-message") ?? "",
            impressions: g.int("job-impressions") ?? 0,
            impressionsDone: g.int("job-impressions-completed") ?? 0,
            kOctets: g.int("job-k-octets") ?? 0,
            created: date("time-at-creation") ?? Date(),
            processing: date("time-at-processing"),
            completed: date("time-at-completed"))
    }

    /// 读作业列表。`which`:not-completed | completed | all。
    /// Get-Jobs 必须带 printer-uri,不带会返回「缺少必需的属性」
    static func jobs(printer: String, which: String, limit: Int) -> Result<[CupsJob], PrintError> {
        let r = IPPClient.call(IPP_OP_GET_JOBS, attrs: [
            op("printer-uri", .uri(IPPClient.printerURI(printer))),
            op("requested-attributes", .keyword(jobAttrs)),
            op("which-jobs", .keyword([which])),
            op("my-jobs", .bool(false)),
            op("limit", .int(limit)),
        ], timeoutMs: 8000)
        switch r {
        case .failure(let e): return .failure(e)
        case .success(let rsp):
            if rsp.status == 0x0406 { return .success([]) }
            guard rsp.ok else { return .failure(.status(rsp.status, rsp.statusMessage)) }
            return .success(rsp.jobs.compactMap { job(from: $0, printer: printer) })
        }
    }

    // MARK: - 提交

    private static func jobOps(printer: String, title: String, mime: String?, options: [IPPAttrOut]) -> [IPPAttrOut] {
        var a = [op("printer-uri", .uri(IPPClient.printerURI(printer))),
                 op("job-name", .name(title))]
        if let mime { a.append(op("document-format", .mime(mime))) }
        return a + options
    }

    /// 把 CUPS 的拒绝翻成人话(提交阶段)
    private static func submitError(_ rsp: IPPResponse, printer: String) -> PrintError {
        switch rsp.status {
        case 0x0406: return .message(L10n.t("CUPS 找不到打印机「\(printer)」", "CUPS cannot find printer “\(printer)”"))
        case 0x0506: return .message(L10n.t("打印机当前不接受新作业(已暂停或已停止接收)",
                                           "The printer is not accepting jobs (paused or rejecting)"))
        case 0x040b, 0x040c:
            if let u = rsp.unsupported, !u.attrs.isEmpty {
                return .message(L10n.t("打印机不支持该参数:", "Unsupported option: ") + u.attrs.keys.sorted().joined(separator: "、"))
            }
            return .status(rsp.status, rsp.statusMessage)
        default: return .status(rsp.status, rsp.statusMessage)
        }
    }

    /// Validate-Job:只校验参数,不创建作业(零副作用)
    static func validate(printer: String, file: String, mime: String, title: String,
                         options: [IPPAttrOut]) -> PrintError? {
        let r = IPPClient.call(IPP_OP_VALIDATE_JOB, resource: "/printers/" + printer,
                               attrs: jobOps(printer: printer, title: title, mime: mime, options: options),
                               timeoutMs: 15000)
        switch r {
        case .failure(let e): return e
        case .success(let rsp): return rsp.ok ? nil : submitError(rsp, printer: printer)
        }
    }

    /// Print-Job:提交并返回 CUPS 的 job-id
    static func submit(printer: String, file: String, mime: String, title: String,
                       options: [IPPAttrOut]) -> Result<Int, PrintError> {
        let r = IPPClient.call(IPP_OP_PRINT_JOB, resource: "/printers/" + printer,
                               attrs: jobOps(printer: printer, title: title, mime: mime, options: options),
                               file: file, timeoutMs: 60000)
        switch r {
        case .failure(let e): return .failure(e)
        case .success(let rsp):
            guard rsp.ok else { return .failure(submitError(rsp, printer: printer)) }
            guard let id = rsp.jobs.first?.int("job-id") else {
                return .failure(.message(L10n.t("CUPS 接受了请求但没有返回作业号", "CUPS accepted the job but returned no job id")))
            }
            return .success(id)
        }
    }

    // MARK: - 作业控制

    private static func jobOp(_ opCode: ipp_op_t, printer: String, job: Int, extra: [IPPAttrOut] = []) -> PrintError? {
        let r = IPPClient.call(opCode, resource: "/jobs/", attrs: [
            op("printer-uri", .uri(IPPClient.printerURI(printer))),
            op("job-id", .int(job)),
        ] + extra)
        switch r {
        case .failure(let e): return e
        case .success(let rsp): return rsp.ok ? nil : .status(rsp.status, rsp.statusMessage)
        }
    }

    static func cancel(printer: String, job: Int) -> PrintError? { jobOp(IPP_OP_CANCEL_JOB, printer: printer, job: job) }
    static func hold(printer: String, job: Int) -> PrintError? { jobOp(IPP_OP_HOLD_JOB, printer: printer, job: job) }
    static func release(printer: String, job: Int) -> PrintError? { jobOp(IPP_OP_RELEASE_JOB, printer: printer, job: job) }

    /// 改优先级 = 插队(CUPS 取值 1..100,默认 50;99 足以压过普通作业)。
    /// easy-print 里走 TCP 的 IPP 会被 policy 挡在 Basic 认证之外,本地 socket 上以 owner 身份认证则可以;
    /// 万一仍被拒,退回 `lp -i <printer>-<id> -o job-priority=N`
    static func setPriority(printer: String, job: Int, priority: Int = 99) -> PrintError? {
        let n = min(max(priority, 1), 100)
        let r = IPPClient.call(IPP_OP_SET_JOB_ATTRIBUTES, resource: "/jobs/", attrs: [
            op("printer-uri", .uri(IPPClient.printerURI(printer))),
            op("job-id", .int(job)),
            IPPAttrOut(group: IPP_TAG_JOB, name: "job-priority", value: .int(n)),
        ])
        if case .success(let rsp) = r, rsp.ok { return nil }
        let cli = ShellRun.run("/usr/bin/lp", ["-i", "\(printer)-\(job)", "-o", "job-priority=\(n)"], timeout: 10)
        if cli.status == 0 { return nil }
        return .message(L10n.t("CUPS 拒绝了调整顺序:", "CUPS refused to reorder: ") + cli.err)
    }

    // MARK: - 打印机控制

    private static func printerOp(_ opCode: ipp_op_t, _ printer: String, extra: [IPPAttrOut] = []) -> PrintError? {
        let r = IPPClient.call(opCode, resource: "/admin/", attrs: [
            op("printer-uri", .uri(IPPClient.printerURI(printer))),
        ] + extra)
        switch r {
        case .failure(let e): return e
        case .success(let rsp): return rsp.ok ? nil : .status(rsp.status, rsp.statusMessage)
        }
    }

    static func pause(_ printer: String) -> PrintError? {
        if printerOp(IPP_OP_PAUSE_PRINTER, printer,
                     extra: [op("printer-state-message", .text(L10n.t("由 PopBar 暂停", "Paused by PopBar")))]) == nil { return nil }
        return cli("/usr/sbin/cupsdisable", ["-r", "PopBar", printer])
    }

    static func resume(_ printer: String) -> PrintError? {
        if printerOp(IPP_OP_RESUME_PRINTER, printer) == nil { return nil }
        return cli("/usr/sbin/cupsenable", [printer])
    }

    static func setAccepting(_ printer: String, _ accepting: Bool) -> PrintError? {
        if printerOp(accepting ? IPP_OP_CUPS_ACCEPT_JOBS : IPP_OP_CUPS_REJECT_JOBS, printer) == nil { return nil }
        return cli(accepting ? "/usr/sbin/cupsaccept" : "/usr/sbin/cupsreject", [printer])
    }

    // MARK: - CLI

    /// 只看退出码。lpadmin 被拒绝时带上可直接复制的 sudo 命令
    private static func cli(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> PrintError? {
        let r = ShellRun.run(path, args, timeout: timeout)
        if r.status == 0 { return nil }
        let raw = r.err
        let denied = raw.range(of: "denied|not permitted|unauthoriz|authorization required|forbidden|not allowed|权限|拒绝|未授权",
                               options: [.regularExpression, .caseInsensitive]) != nil
        if denied {
            let cmd = ([path] + args).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
            return .message(L10n.t("CUPS 需要管理员权限。可在终端执行:sudo \(cmd)",
                                   "CUPS needs administrator rights. Run in Terminal: sudo \(cmd)"))
        }
        return .message(raw.isEmpty ? L10n.t("命令执行失败", "Command failed") : raw)
    }

    static func validPrinterName(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9_.-]{1,64}$", options: .regularExpression) != nil
    }

    /// 用 IPP Everywhere 免驱方式添加打印机
    static func add(name: String, uri: String, description: String = "", location: String = "") -> PrintError? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard validPrinterName(n) else {
            return .message(L10n.t("打印机名称只能包含字母、数字、下划线、点、减号,最长 64 个字符",
                                   "Printer names may only contain letters, digits, _ . - (max 64 chars)"))
        }
        guard uri.range(of: "^ipps?://", options: [.regularExpression, .caseInsensitive]) != nil else {
            return .message(L10n.t("设备地址必须是 ipp:// 或 ipps:// 开头的 URI", "The device address must start with ipp:// or ipps://"))
        }
        var args = ["-p", n, "-E", "-v", uri, "-m", "everywhere"]
        if !description.isEmpty { args += ["-D", description] }
        if !location.isEmpty { args += ["-L", location] }
        if let e = cli("/usr/sbin/lpadmin", args, timeout: 30) { return e }
        // -E 只是「启用并接受作业」,有些版本仍会留下停止态,再显式放行一次
        _ = ShellRun.run("/usr/sbin/cupsenable", [n], timeout: 10)
        return nil
    }

    /// 从 CUPS 删除打印机(本地记录只做软删除,见 PrintStore)
    static func remove(_ name: String) -> PrintError? {
        cli("/usr/sbin/lpadmin", ["-x", name])
    }

    // MARK: - 发现

    struct Discovered: Equatable {
        var uri: String
        var host: String
        var configured: Bool
    }

    /// ippfind 输出 → URI 列表。**不加 -l**:-l 会在 URI 后追加一列状态,
    /// 整行当 URI 会把状态文本带进路径;只取行首的 ipps?://\S+
    static func parseIppfind(_ out: String) -> [String] {
        var seen = Set<String>(), uris: [String] = []
        for line in out.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard let r = l.range(of: "^ipps?://\\S+", options: [.regularExpression, .caseInsensitive]) else { continue }
            let u = String(l[r])
            if seen.insert(u).inserted { uris.append(u) }
        }
        return uris
    }

    static func host(of uri: String) -> String {
        guard let r = uri.range(of: "^ipps?://(\\[[^\\]]+\\]|[^/:]+)", options: [.regularExpression, .caseInsensitive]) else { return uri }
        var h = String(uri[r])
        if let i = h.range(of: "://") { h = String(h[i.upperBound...]) }
        return h.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// 型号里的序列号片段(含数字、≥6 位大写字母数字,排除 SERIES/AIRPRINT 等通用词),
    /// 用来把广播主机名(HP644ED795E620.local)对回已配置的本机队列
    static func serialFragments(_ printers: [CupsPrinter]) -> [String] {
        let generic: Set<String> = ["SERIES", "AIRPRINT", "PRINTER", "SERIAL", "MODEL", "LOCAL"]
        var out: [String] = []
        for p in printers {
            let text = "\(p.makeModel) \(p.info) \(p.name)"
            guard let re = try? NSRegularExpression(pattern: "[A-Za-z0-9]{6,}") else { continue }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let s = (text as NSString).substring(with: m.range).uppercased()
                if s.contains(where: \.isNumber), !generic.contains(s) { out.append(s) }
            }
        }
        return out
    }

    /// 判断一个发现结果是否已经配置过。已配置的打印机在 CUPS 里是本机队列
    /// (ipp://127.0.0.1:631/printers/<名字>),URI 与广播地址对不上,所以还要比主机名与型号片段
    static func isConfigured(uri: String, existing: [CupsPrinter]) -> Bool {
        let h = host(of: uri)
        let known = Set(existing.flatMap { [$0.deviceURI, $0.uri] }.filter { !$0.isEmpty })
        if known.contains(uri) { return true }
        let hosts = Set(known.map(host(of:)).filter { !["127.0.0.1", "localhost"].contains($0.lowercased()) })
        if hosts.contains(h) { return true }
        let H = h.uppercased()
        return serialFragments(existing).contains { H.contains($0) }
    }

    static func discover(timeoutSec: Int = 4, existing: [CupsPrinter]) -> [Discovered] {
        let r = ShellRun.run("/usr/bin/ippfind", ["-T", String(timeoutSec)], timeout: TimeInterval(timeoutSec + 6))
        // 超时退出(1)也可能已经打印了一部分结果,所以不把非零退出码当失败
        return parseIppfind(r.out).map {
            Discovered(uri: $0, host: host(of: $0), configured: isConfigured(uri: $0, existing: existing))
        }
    }

    // MARK: - 默认打印机

    static var lpoptionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cups/lpoptions")
    }

    /// "Default <name>[/instance]" → name
    static func parseDefault(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Default ") {
                let v = t.dropFirst(8).split(separator: " ").first.map(String.init) ?? ""
                return v.split(separator: "/").first.map(String.init)
            }
        }
        return nil
    }

    static func systemDefault() -> String? {
        if let t = try? String(contentsOf: lpoptionsURL, encoding: .utf8), let d = parseDefault(t) { return d }
        let r = IPPClient.call(IPP_OP_CUPS_GET_DEFAULT, attrs: [
            op("requested-attributes", .keyword(["printer-name"])),
        ])
        if case .success(let rsp) = r, rsp.ok, let n = rsp.printers.first?.str("printer-name") { return n }
        return nil
    }

    /// 写系统默认(动 ~/.cups/lpoptions,先备份为 lpoptions.bak)
    static func setSystemDefault(_ name: String) -> PrintError? {
        let url = lpoptionsURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines: [String] = []
            if fm.fileExists(atPath: url.path) {
                let bak = url.appendingPathExtension("bak")
                try? fm.removeItem(at: bak)
                try fm.copyItem(at: url, to: bak)
                lines = (try String(contentsOf: url, encoding: .utf8)).split(separator: "\n")
                    .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("Default ") && !$0.isEmpty }
            }
            lines.append("Default \(name)")
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return .message(L10n.t("写入系统默认打印机失败:", "Failed to write the system default: ") + error.localizedDescription)
        }
    }
}
