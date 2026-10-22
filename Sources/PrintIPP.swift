import Foundation

/// 对系统 libcups 的薄封装(移植自 easy-print 手写的 IPP 编解码):
/// 报文编解码、HTTP 传输都交给 libcups,这里只负责把 ipp_t 指针包成 Swift 值类型。
///
/// 要点(都是 easy-print 踩过的坑):
/// - 所有请求带 requesting-user-name(nameWithoutLanguage),否则 CUPS 连 job-name 都不返回(作业隐私)
/// - 每次调用单独建连接:http_t 不是线程安全的,而调用会在后台线程并发发生
/// - cupsd 走本地 Unix socket,libcups 自动附带本地证书认证,所以暂停/恢复/改优先级这类
///   管理操作不必再借 CLI;CLI 只留给 lpadmin(增删打印机)和 ippfind(发现)
enum IPPValue: Equatable {
    case int(Int)
    case bool(Bool)
    case string(String)
    case range(Int, Int)

    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// 一个属性组(operation / printer / job / unsupported)
struct IPPGroup {
    var tag: Int
    var attrs: [String: [IPPValue]] = [:]

    func str(_ name: String) -> String? { attrs[name]?.first?.stringValue }
    func strs(_ name: String) -> [String] { (attrs[name] ?? []).compactMap { $0.stringValue } }
    func int(_ name: String) -> Int? { attrs[name]?.first?.intValue }
    func ints(_ name: String) -> [Int] { (attrs[name] ?? []).compactMap { $0.intValue } }
    func bool(_ name: String) -> Bool? {
        guard case .bool(let b)? = attrs[name]?.first else { return nil }
        return b
    }
    func ranges(_ name: String) -> [(Int, Int)] {
        (attrs[name] ?? []).compactMap { if case .range(let a, let b) = $0 { return (a, b) } else { return nil } }
    }
}

struct IPPResponse {
    /// ipp_status_t 原始值;0x0000–0x00ff 为成功
    var status: Int
    var statusMessage: String
    var groups: [IPPGroup]

    var ok: Bool { status < 0x0100 }
    var printers: [IPPGroup] { groups.filter { $0.tag == Int(IPP_TAG_PRINTER.rawValue) } }
    var jobs: [IPPGroup] { groups.filter { $0.tag == Int(IPP_TAG_JOB.rawValue) } }
    var unsupported: IPPGroup? { groups.first { $0.tag == Int(IPP_TAG_UNSUPPORTED_GROUP.rawValue) } }
}

/// 请求里的属性值(只列出我们用到的 syntax)
enum IPPOut {
    case keyword([String])
    case name(String)
    case text(String)
    case uri(String)
    case mime(String)
    case int(Int)
    case enumValue(Int)
    case bool(Bool)
    case ranges([(Int, Int)])
}

struct IPPAttrOut {
    var group: ipp_tag_t
    var name: String
    var value: IPPOut
}

enum IPPClient {
    static var localUser: String {
        if let u = cupsUser() { return String(cString: u) }
        return NSUserName()
    }

    /// 打印机队列的 URI(本机 cupsd)
    static func printerURI(_ name: String) -> String {
        "ipp://localhost/printers/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
    }

    /// 发一次 IPP 请求。传输失败(连不上 cupsd)返回 nil 与原因;
    /// 只要 cupsd 回了 IPP 报文(哪怕是错误状态码)就返回 IPPResponse,由调用方看 status。
    @discardableResult
    static func call(_ op: ipp_op_t, resource: String = "/",
                     attrs: [IPPAttrOut], user: Bool = true, file: String? = nil,
                     timeoutMs: Int32 = 15000) -> Result<IPPResponse, PrintError> {
        guard let req = ippNewRequest(op) else { return .failure(.transport(L10n.t("无法创建请求", "Cannot create request"))) }
        if user {
            ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, localUser)
        }
        for a in attrs { add(req, a) }

        guard let http = httpConnect2(cupsServer(), ippPort(), nil, AF_UNSPEC,
                                      HTTP_ENCRYPTION_IF_REQUESTED, 1, timeoutMs, nil) else {
            ippDelete(req)
            return .failure(.transport(L10n.t("无法连接 CUPS 服务", "Cannot reach the CUPS service")))
        }
        defer { httpClose(http) }

        // cupsDo*Request 会释放 req;返回的响应归我们释放
        let rsp: OpaquePointer?
        if let file {
            rsp = cupsDoFileRequest(http, req, resource, file)
        } else {
            rsp = cupsDoRequest(http, req, resource)
        }
        guard let rsp else {
            // 响应不是 IPP(例如 CUPS 返回 HTML 错误页)或传输中断
            let err = cupsLastError()
            if err == IPP_STATUS_ERROR_NOT_AUTHORIZED || err == IPP_STATUS_ERROR_FORBIDDEN {
                return .failure(.denied(lastErrorString()))
            }
            return .failure(.transport(lastErrorString()))
        }
        defer { ippDelete(rsp) }
        return .success(decode(rsp))
    }

    static func lastErrorString() -> String {
        if let s = cupsLastErrorString() { return String(cString: s) }
        return L10n.t("未知错误", "Unknown error")
    }

    // MARK: - 编码

    private static func add(_ req: OpaquePointer, _ a: IPPAttrOut) {
        let g = a.group
        switch a.value {
        case .keyword(let ks):
            let cstrs = ks.map { strdup($0) }
            var ptrs: [UnsafePointer<CChar>?] = cstrs.map { UnsafePointer($0) }
            ippAddStrings(req, g, IPP_TAG_KEYWORD, a.name, Int32(ptrs.count), nil, &ptrs)
            cstrs.forEach { free($0) }
        case .name(let s): ippAddString(req, g, IPP_TAG_NAME, a.name, nil, s)
        case .text(let s): ippAddString(req, g, IPP_TAG_TEXT, a.name, nil, s)
        case .uri(let s): ippAddString(req, g, IPP_TAG_URI, a.name, nil, s)
        case .mime(let s): ippAddString(req, g, IPP_TAG_MIMETYPE, a.name, nil, s)
        case .int(let i): ippAddInteger(req, g, IPP_TAG_INTEGER, a.name, Int32(i))
        case .enumValue(let i): ippAddInteger(req, g, IPP_TAG_ENUM, a.name, Int32(i))
        case .bool(let b): ippAddBoolean(req, g, a.name, b ? 1 : 0)
        case .ranges(let rs):
            var lo = rs.map { Int32($0.0) }, hi = rs.map { Int32($0.1) }
            ippAddRanges(req, g, a.name, Int32(rs.count), &lo, &hi)
        }
    }

    // MARK: - 解码

    private static func decode(_ ipp: OpaquePointer) -> IPPResponse {
        var groups: [IPPGroup] = []
        var cur: IPPGroup?
        var attr = ippFirstAttribute(ipp)
        while let a = attr {
            let tag = ippGetGroupTag(a)
            if let n = ippGetName(a) {
                if cur == nil || cur!.tag != Int(tag.rawValue) {
                    if let c = cur { groups.append(c) }
                    cur = IPPGroup(tag: Int(tag.rawValue))
                }
                cur!.attrs[String(cString: n)] = values(of: a)
            } else if let c = cur {      // 组分隔符
                groups.append(c)
                cur = nil
            }
            attr = ippNextAttribute(ipp)
        }
        if let c = cur { groups.append(c) }
        let status = Int(ippGetStatusCode(ipp).rawValue)
        // 状态消息:成功时没有;失败时 CUPS 放在 status-message(text) 里,属于操作组
        let msg = groups.first { $0.tag == Int(IPP_TAG_OPERATION.rawValue) }?.str("status-message") ?? ""
        return IPPResponse(status: status, statusMessage: msg, groups: groups)
    }

    private static func values(of a: OpaquePointer) -> [IPPValue] {
        let n = Int(ippGetCount(a))
        var out: [IPPValue] = []
        switch ippGetValueTag(a) {
        case IPP_TAG_INTEGER, IPP_TAG_ENUM:
            for i in 0..<n { out.append(.int(Int(ippGetInteger(a, Int32(i))))) }
        case IPP_TAG_BOOLEAN:
            for i in 0..<n { out.append(.bool(ippGetBoolean(a, Int32(i)) != 0)) }
        case IPP_TAG_RANGE:
            for i in 0..<n {
                var hi: Int32 = 0
                let lo = ippGetRange(a, Int32(i), &hi)
                out.append(.range(Int(lo), Int(hi)))
            }
        case IPP_TAG_TEXT, IPP_TAG_NAME, IPP_TAG_KEYWORD, IPP_TAG_URI, IPP_TAG_URISCHEME,
             IPP_TAG_CHARSET, IPP_TAG_LANGUAGE, IPP_TAG_MIMETYPE, IPP_TAG_TEXTLANG, IPP_TAG_NAMELANG:
            for i in 0..<n {
                if let s = ippGetString(a, Int32(i), nil) { out.append(.string(String(cString: s))) }
            }
        default:
            break   // 日期、分辨率、集合等:当前功能用不到
        }
        return out
    }
}

/// 失败的统一表达:传输失败 / 被拒绝 / CUPS 返回的错误状态
enum PrintError: Error, Equatable {
    case transport(String)
    case denied(String)
    case status(Int, String)
    case message(String)

    var text: String {
        switch self {
        case .transport(let s): return s
        case .denied(let s):
            return L10n.t("CUPS 拒绝了该操作(权限不足):", "CUPS refused (not authorized): ") + s
        case .status(let code, let s): return s.isEmpty ? IPPStatus.explain(code) : s
        case .message(let s): return s
        }
    }
}

/// IPP 状态码 → 中文/英文说明
enum IPPStatus {
    static func explain(_ code: Int) -> String {
        switch code {
        case 0x0400: return L10n.t("请求格式错误", "Bad request")
        case 0x0401: return L10n.t("没有权限", "Forbidden")
        case 0x0402: return L10n.t("需要认证", "Authentication required")
        case 0x0404: return L10n.t("找不到对象", "Not found")
        case 0x0406: return L10n.t("找不到对象", "Not found")
        case 0x040a: return L10n.t("文件格式不被支持", "Document format not supported")
        case 0x040b: return L10n.t("不支持的属性或值", "Attributes or values not supported")
        case 0x0409: return L10n.t("请求实体过大", "Request entity too large")
        case 0x0506: return L10n.t("打印机当前不接受新作业", "Printer is not accepting jobs")
        case 0x0507: return L10n.t("打印机忙", "Printer busy")
        case 0x0508: return L10n.t("作业已被取消", "Job canceled")
        default: return L10n.t("CUPS 返回错误 0x", "CUPS error 0x") + String(code, radix: 16)
        }
    }
}
