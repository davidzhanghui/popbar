import Foundation
import PopBarCore

/// 服务器自动发现/生成的一条 VLESS 链接。一个 VPS 可以有多条。
struct VPSLink: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var url: String

    init(id: String = UUID().uuidString, name: String = "", url: String = "") {
        self.id = id
        self.name = name
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
    }

    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? L10n.t("未命名链接", "Unnamed link") : n
    }

    var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 一台被监控的 VPS。完全由 ~/.ssh/config 的 Host 派生，id 用别名保持稳定。
struct VPSHost: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var sshAlias: String
    var enabled: Bool

    init(id: String? = nil, name: String, sshAlias: String, enabled: Bool = true) {
        let alias = sshAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? (alias.isEmpty ? UUID().uuidString : alias)
        self.name = name
        self.sshAlias = sshAlias
        self.enabled = enabled
    }

    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? alias : n
    }

    var alias: String { sshAlias.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// SSH Host 只允许常见的安全字符，避免把参数送进 ssh 命令。
    static func validAlias(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.hasPrefix("-"), s.count <= 128 else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || "._-@".contains($0) }
    }
}

/// 持久化配置只保留停用状态和上次完整检查时间；主机列表每次从 ~/.ssh/config 读取。
struct VPSConfig: Codable, Equatable, Sendable {
    /// 小写 SSH Host 别名；新出现的主机默认启用。
    var disabledAliases: [String] = []
    var lastRefreshAt: Double? = nil

    private struct LegacyHost: Decodable {
        var sshAlias: String?
        var name: String?
        var enabled: Bool?
    }

    private enum CodingKeys: String, CodingKey {
        case disabledAliases, lastRefreshAt, hosts
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disabledAliases = (try? c.decode([String].self, forKey: .disabledAliases)) ?? []
        lastRefreshAt = try? c.decode(Double.self, forKey: .lastRefreshAt)
        if let legacy = try? c.decode([LegacyHost].self, forKey: .hosts), disabledAliases.isEmpty {
            disabledAliases = legacy
                .filter { $0.enabled == false }
                .compactMap { ($0.sshAlias ?? $0.name)?.lowercased() }
                .filter { !$0.isEmpty }
        }
        disabledAliases = Array(Set(disabledAliases.map { $0.lowercased() }.filter { !$0.isEmpty })).sorted()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(disabledAliases, forKey: .disabledAliases)
        try c.encodeIfPresent(lastRefreshAt, forKey: .lastRefreshAt)
    }
}

/// 进入页面时是否自动检查：距上次完整检查超过 1 小时，或本次启动还没有结果。
enum VPSRefreshPolicy {
    static let minimumInterval: TimeInterval = 3600

    static func shouldAutoRefresh(lastRefresh: Date?, needsData: Bool, now: Date = Date()) -> Bool {
        if needsData { return true }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= minimumInterval
    }
}

enum VPSHostDiscovery {
    static var defaultConfigPath: String {
        NSString(string: "~/.ssh/config").expandingTildeInPath
    }

    /// 从 SSH 配置里读取 Host 别名。跳过通配符、否定和 Host *。
    static func fromSSHConfig(at path: String = defaultConfigPath) -> [VPSHost] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [VPSHost] = []
        var seen = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.first?.lowercased() == "host" else { continue }
            for alias in parts.dropFirst() {
                guard !alias.isEmpty, !alias.contains("*"), !alias.contains("?"),
                      !alias.hasPrefix("!"), !alias.contains("%") else { continue }
                let key = alias.lowercased()
                guard seen.insert(key).inserted else { continue }
                out.append(VPSHost(name: alias, sshAlias: alias))
                if out.count >= 30 { return out }
            }
        }
        return out
    }
}

/// 一次远程采集的结果。所有字段都有默认值，解析失败时不影响其它字段。
struct VPSRemoteSnapshot: Equatable, Sendable {
    var hostname = ""
    var osName = ""
    var osID = ""
    var osVersion = ""
    var kernel = ""
    var uptime: Double = 0
    var load: [Double] = [0, 0, 0]
    var cores: Int = 1
    var cpuPercent: Double = 0
    var memTotalKB: Int64 = 0
    var memAvailKB: Int64 = 0
    var swapTotalKB: Int64 = 0
    var swapFreeKB: Int64 = 0
    var diskTotalKB: Int64 = 0
    var diskUsedKB: Int64 = 0
    var diskPercent: Double = 0
    var xrayActive = "unknown"
    var xrayVersion = ""
    var xrayPorts: [Int] = []
    var xrayConfig = ""
    var xrayConfigMode = ""
    var xrayConfigOwner = ""
    var fail2ban = "unknown"
    var fail2banBanned = 0
    var fail2banJails = ""
    var firewall = "unknown"
    var firewallKind = ""
    var pending: Int? = nil
    var autoUpdates = "unknown"
    var timeSync = "unknown"
    var needReboot = false
    var sshPassword = "unknown"
    var sshX11 = "unknown"
    var sshMaxAuth = 0
    var sshRoot = "unknown"
    var docker = "unknown"
    var vlessLink = ""
    /// 从服务器 Xray 配置里自动整理出的链接（没有客户端文件时使用）。
    var autoLinks: [VPSLink] = []
    var eolNote: String? = nil

    var memUsedKB: Int64 { max(0, memTotalKB - memAvailKB) }
    var memPercent: Double {
        guard memTotalKB > 0 else { return 0 }
        return min(100, max(0, Double(memUsedKB) / Double(memTotalKB) * 100))
    }
    var xrayRunning: Bool { xrayActive == "active" }
    var firewallRunning: Bool { firewall == "active" || firewall == "running" }
    var fail2banRunning: Bool { fail2ban == "active" }
    var autoUpdatesOn: Bool { autoUpdates == "enabled" || autoUpdates == "active" }
    var timeSynced: Bool { timeSync == "yes" || timeSync == "true" }
    var sshKeyOnly: Bool { sshPassword == "no" }

    var securityWarnings: [String] {
        var out: [String] = []
        if !sshKeyOnly {
            out.append(L10n.t("SSH 密码登录未关闭", "SSH password login is on"))
        }
        if sshX11 == "yes" {
            out.append(L10n.t("SSH X11 转发开启", "SSH X11 forwarding is on"))
        }
        if !firewallRunning {
            out.append(L10n.t("防火墙未启用", "Firewall is not active"))
        }
        if !fail2banRunning {
            out.append(L10n.t("fail2ban 未运行", "fail2ban is not running"))
        }
        if let pending {
            if pending > 0 { out.append(L10n.t("\(pending) 个待更新", "\(pending) updates pending")) }
        } else {
            out.append(L10n.t("补丁状态未知", "Update status unknown"))
        }
        if !xrayConfigMode.isEmpty, xrayConfigMode != "600" {
            out.append(L10n.t("Xray 配置权限 \(xrayConfigMode)", "Xray config mode \(xrayConfigMode)"))
        }
        if !autoUpdatesOn {
            out.append(L10n.t("自动更新未启用", "Automatic updates are off"))
        }
        if !timeSynced {
            out.append(L10n.t("时间同步异常", "Time is not synchronized"))
        }
        if needReboot {
            out.append(L10n.t("需要重启", "Reboot required"))
        }
        if let eolNote {
            out.append(eolNote)
        }
        if !xrayRunning {
            out.append(L10n.t("Xray 未运行", "Xray is not running"))
        }
        return out
    }

    var securityScore: Int {
        var score = 100
        if !sshKeyOnly { score -= 25 }
        if sshX11 == "yes" { score -= 5 }
        if !firewallRunning { score -= 20 }
        if !fail2banRunning { score -= 15 }
        if let pending {
            if pending > 0 { score -= min(15, pending * 2) }
        } else {
            score -= 5
        }
        if !xrayConfigMode.isEmpty, xrayConfigMode != "600" { score -= 10 }
        if !autoUpdatesOn { score -= 10 }
        if !timeSynced { score -= 5 }
        if needReboot { score -= 5 }
        if eolNote != nil { score -= 20 }
        if !xrayRunning { score -= 10 }
        return min(100, max(0, score))
    }

    /// 负载层面的提醒，和“安全”分开显示。
    var loadWarnings: [String] {
        var out: [String] = []
        if cpuPercent >= 90 { out.append(L10n.t("CPU 占用高", "CPU is high")) }
        if memPercent >= 95 { out.append(L10n.t("内存接近耗尽", "Memory is nearly full")) }
        if diskPercent >= 90 { out.append(L10n.t("磁盘接近写满", "Disk is nearly full")) }
        return out
    }
}

enum VPSRemoteParser {
    static func parse(_ text: String) -> VPSRemoteSnapshot? {
        var d: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...])
            if !key.isEmpty { d[key] = value }
        }
        guard d["OK"] == "1" else { return nil }

        var s = VPSRemoteSnapshot()
        s.hostname = d["HOSTNAME"] ?? ""
        s.osName = d["OS_NAME"] ?? ""
        s.osID = d["OS_ID"] ?? ""
        s.osVersion = d["OS_VERSION"] ?? ""
        s.kernel = d["KERNEL"] ?? ""
        s.uptime = max(0, Double(d["UPTIME"] ?? "") ?? 0)
        let load = (d["LOAD"] ?? "").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        s.load = (0..<3).map { $0 < load.count ? load[$0] : 0 }
        s.cores = max(1, Int(d["CORES"] ?? "") ?? 1)
        s.cpuPercent = min(100, max(0, Double(d["CPU_PCT"] ?? "") ?? 0))
        s.memTotalKB = max(0, Int64(d["MEM_TOTAL_KB"] ?? "") ?? 0)
        s.memAvailKB = max(0, Int64(d["MEM_AVAIL_KB"] ?? "") ?? 0)
        s.swapTotalKB = max(0, Int64(d["SWAP_TOTAL_KB"] ?? "") ?? 0)
        s.swapFreeKB = max(0, Int64(d["SWAP_FREE_KB"] ?? "") ?? 0)
        s.diskTotalKB = max(0, Int64(d["DISK_TOTAL_KB"] ?? "") ?? 0)
        s.diskUsedKB = max(0, Int64(d["DISK_USED_KB"] ?? "") ?? 0)
        if let p = Double(d["DISK_PCT"] ?? ""), p > 0 {
            s.diskPercent = min(100, max(0, p))
        } else if s.diskTotalKB > 0 {
            s.diskPercent = min(100, max(0, Double(s.diskUsedKB) / Double(s.diskTotalKB) * 100))
        }
        s.xrayActive = d["XRAY_ACTIVE"] ?? "unknown"
        s.xrayVersion = d["XRAY_VERSION"] ?? ""
        s.xrayPorts = (d["XRAY_PORTS"] ?? "").split(separator: ",").compactMap { Int($0) }
        s.xrayConfig = d["XRAY_CONFIG"] ?? ""
        s.xrayConfigMode = d["XRAY_CONFIG_MODE"] ?? ""
        s.xrayConfigOwner = d["XRAY_CONFIG_OWNER"] ?? ""
        s.fail2ban = d["FAIL2BAN"] ?? "unknown"
        s.fail2banBanned = max(0, Int(d["FAIL2BAN_BANNED"] ?? "") ?? 0)
        s.fail2banJails = d["FAIL2BAN_JAILS"] ?? ""
        s.firewall = d["FIREWALL"] ?? "unknown"
        s.firewallKind = d["FIREWALL_KIND"] ?? ""
        if let p = Int(d["PENDING"] ?? ""), p >= 0 { s.pending = p }
        s.autoUpdates = d["AUTO_UPDATES"] ?? "unknown"
        s.timeSync = d["TIME_SYNC"] ?? "unknown"
        s.needReboot = d["NEED_REBOOT"] == "1"
        s.sshPassword = d["SSH_PASSWORD"] ?? "unknown"
        s.sshX11 = d["SSH_X11"] ?? "unknown"
        s.sshMaxAuth = max(0, Int(d["SSH_MAXAUTH"] ?? "") ?? 0)
        s.sshRoot = d["SSH_ROOT"] ?? "unknown"
        s.docker = d["DOCKER"] ?? "unknown"
        s.vlessLink = d["VLESS_LINK"] ?? ""
        if let raw = d["AUTO_VLESS_JSON"],
           let data = raw.data(using: .utf8),
           let links = try? JSONDecoder().decode([VPSLink].self, from: data) {
            s.autoLinks = links
        }
        s.eolNote = eolNote(osID: s.osID, version: s.osVersion)
        return s
    }

    static func eolNote(osID: String, version: String) -> String? {
        let id = osID.lowercased()
        if id == "ubuntu", version.hasPrefix("20.04") {
            return L10n.t("Ubuntu 20.04 已 EOL，无官方安全更新", "Ubuntu 20.04 is EOL; no official security updates")
        }
        if id == "debian", version.hasPrefix("10") {
            return L10n.t("Debian 10 已 EOL，无官方安全更新", "Debian 10 is EOL; no official security updates")
        }
        if id == "centos", version.hasPrefix("7") {
            return L10n.t("CentOS 7 已 EOL，无官方安全更新", "CentOS 7 is EOL; no official security updates")
        }
        return nil
    }
}

/// VLESS + REALITY 的最小解析结果，够本地 xray 客户端使用。
struct VLESSEndpoint: Equatable, Sendable {
    let host: String
    let port: Int
    let uuid: String
    let sni: String
    let publicKey: String
    let shortID: String
    let flow: String
    let fingerprint: String

    var display: String { "\(host):\(port)" }

    static func parse(_ raw: String) -> VLESSEndpoint? {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, let c = URLComponents(string: link),
              c.scheme?.lowercased() == "vless",
              let host = c.host, !host.isEmpty,
              let uuid = c.user, !uuid.isEmpty else { return nil }
        let port = c.port ?? 443
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name.lowercased()] = item.value ?? "" }
        guard q["security"]?.lowercased() == "reality",
              let sni = q["sni"], !sni.isEmpty,
              let pbk = q["pbk"], !pbk.isEmpty else { return nil }
        if let type = q["type"], !type.isEmpty, type.lowercased() != "tcp" { return nil }
        if let header = q["headertype"], !header.isEmpty, header.lowercased() != "none" { return nil }
        return VLESSEndpoint(host: host, port: port, uuid: uuid,
                             sni: sni, publicKey: pbk,
                             shortID: q["sid"] ?? "",
                             flow: q["flow"] ?? "",
                             fingerprint: q["fp"] ?? "chrome")
    }
}

struct VPSTCPCheck: Equatable, Sendable {
    var host: String
    var port: Int
    var ok: Bool
    var latencyMs: Int?
    var error: String?
}

struct VLESSCheck: Equatable, Sendable {
    enum State: String, Sendable { case ok, failed, skipped }
    var state: State
    var latencyMs: Int?
    var message: String
    var endpoint: String

    static func skipped(_ message: String, endpoint: String = "") -> VLESSCheck {
        VLESSCheck(state: .skipped, latencyMs: nil, message: message, endpoint: endpoint)
    }
}

struct VLESpeedCheck: Equatable, Sendable {
    enum State: String, Sendable { case ok, failed }
    var state: State
    var megabytesPerSecond: Double?
    var latencyMs: Int?
    var message: String
}

struct VPSLinkCheck: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var endpoint: String
    var check: VLESSCheck
    /// 只用于按需测试，不在界面或报告里显示完整链接。
    var url: String = ""
    var speed: VLESpeedCheck? = nil
}

struct VPSHostResult: Equatable, Identifiable, Sendable {
    var id: String { host.id }
    var host: VPSHost
    var online: Bool
    var error: String?
    var latencyMs: Int?
    var remote: VPSRemoteSnapshot?
    var tcp: VPSTCPCheck?
    var vlessChecks: [VPSLinkCheck]
    var checkedAt: Date

    var attention: Bool {
        if !online { return true }
        if let remote, !remote.securityWarnings.isEmpty { return true }
        if vlessChecks.contains(where: { $0.check.state == .failed }) { return true }
        if vlessChecks.contains(where: { $0.speed?.state == .failed }) { return true }
        return false
    }

    var report: String { VPSReportBuilder.make(self) }

    static func offline(_ host: VPSHost, error: String) -> VPSHostResult {
        VPSHostResult(host: host, online: false, error: error, latencyMs: nil,
                      remote: nil, tcp: nil, vlessChecks: [], checkedAt: Date())
    }
}

/// 把一次刷新结果整理成可复制的纯文本报告。报告里不包含完整 VLESS 链接或密钥，只写节点地址。
enum VPSReportBuilder {
    private struct ActionItem {
        enum Severity: Int {
            case high = 0, medium = 1, low = 2
            var label: String {
                switch self {
                case .high: return L10n.t("高", "High")
                case .medium: return L10n.t("中", "Medium")
                case .low: return L10n.t("低", "Low")
                }
            }
        }

        let severity: Severity
        let title: String
        let current: String
        let suggestion: String
    }

    static func make(_ result: VPSHostResult) -> String {
        let sep = L10n.isEnglish ? ": " : "："
        func bullet(_ key: String, _ value: String) -> String { "- \(key)\(sep)\(value)" }
        func heading(_ title: String) -> String { "## \(title)" }
        let actions = actionItems(for: result)
        var out: [String] = []

        out.append("# " + L10n.t("VPS 检测报告", "VPS Health Report"))
        out.append("")
        out.append(bullet(L10n.t("主机", "Host"), result.host.displayName))
        out.append(bullet("SSH Host", result.host.sshAlias))
        out.append(bullet(L10n.t("检查时间", "Checked"), date.string(from: result.checkedAt)))
        out.append(bullet(L10n.t("状态", "Status"),
                          result.online ? L10n.t("在线", "Online") : L10n.t("离线", "Offline")))
        if let r = result.remote {
            out.append(bullet(L10n.t("系统", "OS"), "\(r.osName) · \(r.kernel)"))
            out.append(bullet(L10n.t("安全评分", "Security score"), "\(r.securityScore)/100"))
        }
        out.append(bullet(L10n.t("待处理", "Action items"), "\(actions.count) \(L10n.t("项", "item(s)"))"))
        if let ms = result.latencyMs, result.online {
            out.append(bullet("SSH " + L10n.t("延迟", "latency"), "\(ms) ms"))
        }
        if let error = result.error {
            out.append(bullet(L10n.t("错误", "Error"), error))
        }

        out.append("")
        out.append(heading(L10n.t("待处理（优先处理）", "Action Items (priority)")))
        if actions.isEmpty {
            out.append("- " + L10n.t("未发现需要处理的问题。", "No issues found."))
        } else {
            out.append("- " + L10n.t("共 \(actions.count) 项；建议按顺序处理。修复前先备份配置，命令按实际发行版和服务用户调整。",
                                      "\(actions.count) item(s); handle in order. Back up configs first and adapt commands to the distro and service user."))
            for (index, action) in actions.enumerated() {
                out.append("")
                out.append("\(index + 1). [\(action.severity.label)] \(action.title)")
                out.append("   - \(L10n.t("现状", "Current"))\(sep)\(action.current)")
                out.append("   - \(L10n.t("建议", "Suggested fix"))\(sep)\(action.suggestion)")
            }
        }

        guard let r = result.remote else {
            out.append("")
            out.append(heading(L10n.t("建议", "Suggestion")))
            out.append("- " + L10n.t("先在终端确认 `ssh \(result.host.sshAlias)` 可以登录；检查网络、密钥、known_hosts 和服务器防火墙。",
                                      "First make sure `ssh \(result.host.sshAlias)` works in Terminal. Check network, keys, known_hosts and the server firewall."))
            return out.joined(separator: "\n")
        }

        out.append("")
        out.append(heading(L10n.t("性能", "Performance")))
        out.append(bullet(L10n.t("运行时长", "Uptime"), uptime(r.uptime)))
        out.append(bullet("CPU", "\(pct(r.cpuPercent)) · load \(load(r.load)) · \(r.cores) \(L10n.t("核", "cores"))"))
        out.append(bullet(L10n.t("内存", "Memory"),
                          "\(bytes(r.memUsedKB)) / \(bytes(r.memTotalKB)) (\(pct(r.memPercent)))"))
        if r.swapTotalKB > 0 {
            out.append(bullet("Swap", "\(bytes(max(0, r.swapTotalKB - r.swapFreeKB))) / \(bytes(r.swapTotalKB))"))
        } else {
            out.append(bullet("Swap", L10n.t("无", "none")))
        }
        out.append(bullet(L10n.t("磁盘", "Disk"),
                          "\(bytes(r.diskUsedKB)) / \(bytes(r.diskTotalKB)) (\(pct(r.diskPercent)))"))

        out.append("")
        out.append(heading(L10n.t("安全详情", "Security details")))
        let ssh = r.sshKeyOnly ? L10n.t("密钥登录", "key only") : L10n.t("密码登录", "password")
        out.append(bullet("SSH", "\(ssh) · X11 \(r.sshX11) · MaxAuthTries \(r.sshMaxAuth) · root \(r.sshRoot)"))
        out.append(bullet("fail2ban", "\(r.fail2ban) · \(L10n.t("封禁", "banned")) \(r.fail2banBanned) · \(r.fail2banJails)"))
        out.append(bullet(L10n.t("防火墙", "Firewall"), "\(r.firewallKind) \(r.firewall)"))
        out.append(bullet(L10n.t("待更新", "Pending updates"), pendingText(r.pending)))
        let auto = r.autoUpdatesOn ? L10n.t("已启用", "enabled")
            : (r.autoUpdates == "unknown" ? L10n.t("未知", "unknown") : L10n.t("未启用", "off"))
        out.append(bullet(L10n.t("自动更新", "Auto updates"), auto))
        out.append(bullet(L10n.t("时间同步", "Time sync"), r.timeSynced ? L10n.t("正常", "yes") : r.timeSync))
        out.append(bullet(L10n.t("需要重启", "Reboot"), yesNo(r.needReboot)))
        if !r.xrayConfig.isEmpty {
            out.append(bullet("Xray " + L10n.t("配置", "config"),
                              "\(r.xrayConfig) · \(r.xrayConfigMode) · \(r.xrayConfigOwner)"))
        }
        if let eol = r.eolNote {
            out.append(bullet("EOL", eol))
        }

        out.append("")
        out.append(heading("VLESS"))
        out.append(bullet("Xray", "\(r.xrayActive) · \(shortVersion(r.xrayVersion))"))
        if !r.xrayPorts.isEmpty {
            out.append(bullet(L10n.t("监听端口", "Listening ports"),
                              r.xrayPorts.map(String.init).joined(separator: ", ")))
        }
        if let tcp = result.tcp {
            let value = tcp.ok
                ? "\(tcp.host):\(tcp.port) · \(L10n.t("连通", "open")) · \(tcp.latencyMs ?? 0) ms"
                : "\(tcp.host):\(tcp.port) · \(L10n.t("不通", "unreachable")) · \(tcp.error ?? "")"
            out.append(bullet("TCP", value))
        } else {
            out.append(bullet("TCP", L10n.t("未测试", "not tested")))
        }
        if result.vlessChecks.isEmpty {
            out.append(bullet(L10n.t("订阅链接", "Links"), L10n.t("未发现", "not found")))
        } else {
            for l in result.vlessChecks {
                var value = "\(l.endpoint) · \(vlessState(l.check))"
                if l.check.state == .ok, let ms = l.check.latencyMs { value += " · \(ms) ms" }
                if let speed = l.speed {
                    if speed.state == .ok, let mb = speed.megabytesPerSecond {
                        value += String(format: " · %.1f MB/s", mb)
                    } else {
                        value += " · " + L10n.t("测速失败", "speed failed")
                    }
                }
                out.append(bullet(l.name, value))
                if !l.check.message.isEmpty { out.append("  - \(l.check.message)") }
                if let speed = l.speed, speed.state == .failed, !speed.message.isEmpty {
                    out.append("  - \(speed.message)")
                }
            }
        }

        out.append("")
        out.append(heading(L10n.t("备注", "Notes")))
        out.append("- " + L10n.t("本报告不包含 UUID、私钥或完整订阅链接，只包含节点地址和测试结果。",
                                  "This report does not contain UUIDs, private keys or full subscription links; only endpoint addresses and test results."))
        out.append("- " + L10n.t("修改 SSH、防火墙或 Xray 配置前先备份；重启服务后再验证端口与连通性。",
                                  "Back up SSH, firewall and Xray configs before changes; restart services and verify ports and connectivity afterward."))
        return out.joined(separator: "\n")
    }

    private static func actionItems(for result: VPSHostResult) -> [ActionItem] {
        guard let r = result.remote else {
            return [ActionItem(
                severity: .high,
                title: L10n.t("SSH 连接失败", "SSH connection failed"),
                current: result.error ?? L10n.t("无法连接服务器", "Cannot reach the server"),
                suggestion: L10n.t("先在终端执行 `ssh \(result.host.sshAlias)`，检查网络、密钥权限、known_hosts 和服务器防火墙。",
                                   "Run `ssh \(result.host.sshAlias)` in Terminal; check network, key permissions, known_hosts and the server firewall.")
            )]
        }

        var out: [ActionItem] = []
        let pm = packageManager(r.osID)
        let sshUnit = sshService(r.osID)

        if !r.sshKeyOnly {
            out.append(ActionItem(
                severity: .high,
                title: L10n.t("SSH 密码登录未关闭", "SSH password login is enabled"),
                current: L10n.t("`sshd -T` 显示 PasswordAuthentication \(r.sshPassword)，存在暴力破解风险。",
                                "`sshd -T` reports PasswordAuthentication \(r.sshPassword); brute-force risk."),
                suggestion: L10n.t("确认密钥登录可用后，在 `/etc/ssh/sshd_config` 设置 `PasswordAuthentication no`，再执行 `sudo systemctl reload \(sshUnit)`。",
                                   "After confirming key login works, set `PasswordAuthentication no` in `/etc/ssh/sshd_config` and run `sudo systemctl reload \(sshUnit)`.")
            ))
        }
        if r.sshX11 == "yes" {
            out.append(ActionItem(
                severity: .medium,
                title: L10n.t("SSH X11 转发开启", "SSH X11 forwarding is enabled"),
                current: L10n.t("`sshd -T` 显示 X11Forwarding yes；没有 X11 需求时应关闭。",
                                "`sshd -T` reports X11Forwarding yes; disable it if not needed."),
                suggestion: L10n.t("在 `/etc/ssh/sshd_config` 设置 `X11Forwarding no`，执行 `sudo systemctl reload \(sshUnit)`，再确认 `sshd -T | grep x11forwarding`。",
                                   "Set `X11Forwarding no` in `/etc/ssh/sshd_config`, run `sudo systemctl reload \(sshUnit)`, then verify `sshd -T | grep x11forwarding`.")
            ))
        }
        if !r.firewallRunning {
            let command = r.firewallKind == "firewalld"
                ? "sudo systemctl enable --now firewalld"
                : "sudo ufw enable"
            out.append(ActionItem(
                severity: .high,
                title: L10n.t("防火墙未启用", "Firewall is not active"),
                current: L10n.t("检测到的防火墙类型为 \(r.firewallKind.isEmpty ? "未知" : r.firewallKind)，当前状态 \(r.firewall)。",
                                "Firewall type \(r.firewallKind.isEmpty ? "unknown" : r.firewallKind), state \(r.firewall)."),
                suggestion: L10n.t("确认已放行 SSH 和代理端口后启用防火墙，例如 `\(command)`；再检查 `ufw status` 或 `firewall-cmd --list-all`。",
                                   "Allow SSH and proxy ports first, then enable the firewall, e.g. `\(command)`; verify with `ufw status` or `firewall-cmd --list-all`.")
            ))
        }
        if !r.fail2banRunning {
            let install = pm == "dnf"
                ? "sudo dnf install -y fail2ban"
                : "sudo apt-get install -y fail2ban"
            out.append(ActionItem(
                severity: .high,
                title: L10n.t("fail2ban 未运行", "fail2ban is not running"),
                current: L10n.t("systemd 状态为 \(r.fail2ban)，SSH 暴力破解不会被自动封禁。",
                                "systemd state is \(r.fail2ban); SSH brute force will not be banned."),
                suggestion: L10n.t("执行 `\(install) && sudo systemctl enable --now fail2ban`，确认 `/etc/fail2ban/jail.local` 的 backend 为 systemd，journalmatch 使用本机 SSH 单元，并用测试 IP 验证封禁。",
                                   "Run `\(install) && sudo systemctl enable --now fail2ban`; set backend to systemd in `/etc/fail2ban/jail.local`, use the local SSH unit in journalmatch, and verify a test ban.")
            ))
        }
        if let pending = r.pending, pending > 0 {
            let update = pm == "dnf"
                ? "sudo dnf -y upgrade"
                : "sudo apt-get update && sudo apt-get -y upgrade"
            out.append(ActionItem(
                severity: .medium,
                title: L10n.t("\(pending) 个系统更新未安装", "\(pending) system updates pending"),
                current: L10n.t("包管理器检测到 \(pending) 个待更新包；系统为 \(r.osName)。",
                                "Package manager reports \(pending) pending updates on \(r.osName)."),
                suggestion: L10n.t("先备份关键配置，再执行 `\(update)`；如果更新内核或 systemd，完成后重启并复查端口。",
                                   "Back up key configs, run `\(update)`, and reboot if the kernel or systemd changed; verify ports afterward.")
            ))
        } else if r.pending == nil {
            out.append(ActionItem(
                severity: .low,
                title: L10n.t("无法确认补丁状态", "Cannot determine patch status"),
                current: L10n.t("未识别包管理器或更新检查失败。",
                                "Package manager was not detected or the update check failed."),
                suggestion: L10n.t("手动执行 `apt-get -s upgrade` 或 `dnf check-update`，确认系统仍能获取安全更新。",
                                   "Run `apt-get -s upgrade` or `dnf check-update` manually to confirm security updates are available.")
            ))
        }
        if !r.xrayConfigMode.isEmpty, r.xrayConfigMode != "600" {
            out.append(ActionItem(
                severity: .high,
                title: L10n.t("Xray 配置权限过宽", "Xray config permissions are too open"),
                current: L10n.t("\(r.xrayConfig) 的权限为 \(r.xrayConfigMode)，属主 \(r.xrayConfigOwner)；REALITY 私钥可能被本机其他用户读取。",
                                "\(r.xrayConfig) has mode \(r.xrayConfigMode), owner \(r.xrayConfigOwner); the REALITY private key may be readable by other local users."),
                suggestion: L10n.t("先执行 `systemctl cat xray` 确认运行用户，然后在服务器执行 `sudo chown <运行用户>:<组> \(r.xrayConfig) && sudo chmod 600 \(r.xrayConfig)`，再重启 xray 并确认端口仍在监听。",
                                   "Run `systemctl cat xray` to find the service user, then `sudo chown <user>:<group> \(r.xrayConfig) && sudo chmod 600 \(r.xrayConfig)`, restart xray and verify the port still listens.")
            ))
        }
        if !r.autoUpdatesOn {
            let command = pm == "dnf"
                ? "sudo dnf install -y dnf-automatic && sudo systemctl enable --now dnf-automatic.timer"
                : "sudo apt-get install -y unattended-upgrades && sudo systemctl enable --now unattended-upgrades"
            out.append(ActionItem(
                severity: .medium,
                title: L10n.t("自动更新未启用", "Automatic updates are off"),
                current: L10n.t("自动更新状态为 \(r.autoUpdates)。",
                                "Automatic update state is \(r.autoUpdates)."),
                suggestion: L10n.t("执行 `\(command)`，并确认只启用安全更新源；不要配置自动重启生产服务。",
                                   "Run `\(command)` and restrict it to security origins; do not enable automatic reboots of production services.")
            ))
        }
        if !r.timeSynced {
            out.append(ActionItem(
                severity: .low,
                title: L10n.t("时间同步异常", "Time synchronization is off"),
                current: L10n.t("时间同步状态为 \(r.timeSync)。",
                                "Time sync state is \(r.timeSync)."),
                suggestion: L10n.t("执行 `sudo timedatectl set-ntp true`；如果仍不同步，检查 chrony/systemd-timesyncd 和 UDP 123。",
                                   "Run `sudo timedatectl set-ntp true`; if it still fails, check chrony/systemd-timesyncd and UDP 123.")
            ))
        }
        if r.needReboot {
            out.append(ActionItem(
                severity: .medium,
                title: L10n.t("系统需要重启", "System reboot required"),
                current: L10n.t("检测到 reboot-required 标记。",
                                "A reboot-required marker is present."),
                suggestion: L10n.t("在维护窗口执行 `sudo reboot`，重启后确认服务、端口和本报告中的检查项。",
                                   "Reboot in a maintenance window, then verify services, ports and the checks in this report.")
            ))
        }
        if let eol = r.eolNote {
            out.append(ActionItem(
                severity: .high,
                title: L10n.t("操作系统已 EOL", "Operating system is EOL"),
                current: eol,
                suggestion: L10n.t("尽快 attach Ubuntu Pro/ESM 或升级到受支持的发行版；升级前备份 Xray 配置、证书和防火墙规则。",
                                   "Attach Ubuntu Pro/ESM or upgrade to a supported release; back up Xray configs, certificates and firewall rules first.")
            ))
        }
        if !r.xrayRunning {
            out.append(ActionItem(
                severity: .high,
                title: L10n.t("Xray 未运行", "Xray is not running"),
                current: L10n.t("systemd 状态为 \(r.xrayActive)。",
                                "systemd state is \(r.xrayActive)."),
                suggestion: L10n.t("执行 `sudo systemctl status xray` 和 `sudo journalctl -u xray -n 200 --no-pager`；修复配置错误后重启。",
                                   "Run `sudo systemctl status xray` and `sudo journalctl -u xray -n 200 --no-pager`; fix config errors and restart.")
            ))
        }
        if let tcp = result.tcp, !tcp.ok {
            out.append(ActionItem(
                severity: .high,
                title: L10n.t("代理端口不通", "Proxy port unreachable"),
                current: L10n.t("\(tcp.host):\(tcp.port) 连接失败\(tcp.error.map { "：\($0)" } ?? "")。",
                                "Connection to \(tcp.host):\(tcp.port) failed\(tcp.error.map { ": \($0)" } ?? "")."),
                suggestion: L10n.t("检查服务器 `ss -lntp`、Xray 监听地址、云厂商安全组和本机防火墙；确认端口没有被运营商或防火墙拦截。",
                                   "Check `ss -lntp`, Xray listen address, cloud security groups and the local firewall; make sure the port is not blocked.")
            ))
        }
        for link in result.vlessChecks {
            let checkFailed = link.check.state == .failed
            let speedFailed = link.speed?.state == .failed
            guard checkFailed || speedFailed else { continue }
            var current = "\(link.name) · \(link.endpoint)"
            if checkFailed { current += L10n.t("；连通性失败：\(link.check.message)", "; connectivity failed: \(link.check.message)") }
            if speedFailed { current += L10n.t("；测速失败：\(link.speed?.message ?? "")", "; speed test failed: \(link.speed?.message ?? "")") }
            out.append(ActionItem(
                severity: checkFailed ? .high : .medium,
                title: L10n.t("VLESS 链接测试失败：\(link.name)", "VLESS link failed: \(link.name)"),
                current: current,
                suggestion: L10n.t("在服务器执行 `systemctl status xray` 和 `journalctl -u xray -n 200 --no-pager`；确认 `ss -lntp` 有该端口、防火墙/安全组已放行；核对 UUID、flow、REALITY 的 pbk/sid/sni；再检查本机 xray 版本。",
                                   "Run `systemctl status xray` and `journalctl -u xray -n 200 --no-pager`; verify `ss -lntp`, firewall/security groups, UUID, flow, REALITY pbk/sid/sni, and the local xray version.")
            ))
        }
        if result.vlessChecks.isEmpty {
            out.append(ActionItem(
                severity: .medium,
                title: L10n.t("未发现 VLESS 链接", "No VLESS link found"),
                current: L10n.t("客户端文件和 Xray inbound 配置都没有解析出可测试链接。",
                                "Neither the client file nor the Xray inbound configs produced a testable link."),
                suggestion: L10n.t("检查 `/root/vless-client.txt` 或 `/root/xray-client.txt`；如果从 Xray 配置生成，确认 inbound 的 realitySettings 包含 publicKey、serverNames 和 shortIds。",
                                   "Check `/root/vless-client.txt` or `/root/xray-client.txt`; if generated from Xray configs, ensure realitySettings has publicKey, serverNames and shortIds.")
            ))
        }
        if r.cpuPercent >= 90 {
            out.append(ActionItem(
                severity: .medium,
                title: L10n.t("CPU 使用率过高", "CPU usage is high"),
                current: "\(pct(r.cpuPercent)) · load \(load(r.load)) · \(r.cores) \(L10n.t("核", "cores"))",
                suggestion: L10n.t("执行 `top -b -n1 -o %CPU | head -20` 找出高占用进程；确认不是挖矿或异常 Xray 流量。",
                                   "Run `top -b -n1 -o %CPU | head -20` to find the top process; check for miners or abnormal Xray traffic.")
            ))
        }
        if r.memPercent >= 95 {
            out.append(ActionItem(
                severity: .medium,
                title: L10n.t("内存接近耗尽", "Memory is nearly full"),
                current: "\(bytes(r.memUsedKB)) / \(bytes(r.memTotalKB)) (\(pct(r.memPercent)))",
                suggestion: L10n.t("执行 `ps aux --sort=-%mem | head -20`，检查泄漏进程、容器和 Xray 内存；必要时增加 swap 或升配。",
                                   "Run `ps aux --sort=-%mem | head -20`; check for leaks, containers and Xray memory; add swap or resize if needed.")
            ))
        }
        if r.diskPercent >= 90 {
            out.append(ActionItem(
                severity: .medium,
                title: L10n.t("磁盘接近写满", "Disk is nearly full"),
                current: "\(bytes(r.diskUsedKB)) / \(bytes(r.diskTotalKB)) (\(pct(r.diskPercent)))",
                suggestion: L10n.t("执行 `df -h` 和 `sudo du -xh --max-depth=1 / | sort -h | tail -20`，优先清理日志、Docker 镜像和旧内核。",
                                   "Run `df -h` and `sudo du -xh --max-depth=1 / | sort -h | tail -20`; clean logs, Docker images and old kernels first.")
            ))
        }
        return out.sorted { $0.severity.rawValue < $1.severity.rawValue }
    }

    private static func packageManager(_ osID: String) -> String {
        ["almalinux", "rocky", "centos", "rhel", "fedora"].contains(osID.lowercased()) ? "dnf" : "apt-get"
    }

    private static func sshService(_ osID: String) -> String {
        ["ubuntu", "debian"].contains(osID.lowercased()) ? "ssh" : "sshd"
    }

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func bytes(_ kb: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: max(0, kb) * 1024)
    }

    private static func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }

    private static func load(_ l: [Double]) -> String {
        l.map { String(format: "%.2f", $0) }.joined(separator: " / ")
    }

    private static func uptime(_ seconds: Double) -> String {
        let days = Int(seconds / 86400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600)
        if days > 0 { return L10n.t("\(days) 天 \(hours) 小时", "\(days)d \(hours)h") }
        return L10n.t("\(hours) 小时", "\(hours)h")
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? L10n.t("是", "yes") : L10n.t("否", "no")
    }

    private static func pendingText(_ pending: Int?) -> String {
        guard let pending else { return L10n.t("未知", "unknown") }
        return pending == 0 ? L10n.t("已更新", "up to date") : L10n.t("\(pending) 个", "\(pending)")
    }

    private static func shortVersion(_ raw: String) -> String {
        let v = raw.split(separator: " ").prefix(2).joined(separator: " ")
        return v.isEmpty ? "—" : v
    }

    private static func vlessState(_ check: VLESSCheck) -> String {
        switch check.state {
        case .ok: return L10n.t("204 通过", "204 OK")
        case .failed: return L10n.t("失败", "failed")
        case .skipped: return L10n.t("未测试", "skipped")
        }
    }
}
