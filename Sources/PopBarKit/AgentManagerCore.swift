import Cocoa
import Darwin
import Foundation
import PopBarCore

// Agent 管理核心层（无 SwiftUI 依赖，全部可在后台线程运行）：
// 1. 定义受管 Agent（Claude Code CLI / Claude Desktop / Codex CLI / Codex Desktop /
//    Command Code / OpenCode / Pi / DeepSeek Harness / Antigravity）；
// 2. 探测本机安装路径、安装方式与当前版本（CLI 构造完整 PATH；Desktop 读 Info.plist）；
// 3. 查询远程最新版本并执行更新/安装（全部子进程走 PopBarCore.Shell）；
// 4. 复用 LibProc 原生扫描运行中的 Agent 进程，严格分离 CLI 与桌面端进程；
// 5. 支持按 ~/.zshrc 中的 *-proxy 别名重启各 Agent（DeepSeek Harness 直接启动不走代理）。

// MARK: - 配置

/// Agent 管理持久化配置
struct AgentConfig: Codable, Equatable, Sendable {
    /// 后台自动检查并自动更新已安装的 Agent（桌面应用运行中时会跳过自动覆盖，避免打断会话）
    var autoUpdate: Bool = false
    /// 自动检查间隔（小时），范围 1…24
    var checkIntervalHours: Int = 6
    /// 上次完整检查版本的时间戳（Unix 秒）
    var lastCheckAt: Double? = nil

    init() {}

    init(autoUpdate: Bool = false, checkIntervalHours: Int = 6, lastCheckAt: Double? = nil) {
        self.autoUpdate = autoUpdate
        self.checkIntervalHours = min(max(checkIntervalHours, 1), 24)
        self.lastCheckAt = lastCheckAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentConfig()
        autoUpdate = (try? c.decode(Bool.self, forKey: .autoUpdate)) ?? d.autoUpdate
        let rawHours = (try? c.decode(Int.self, forKey: .checkIntervalHours)) ?? d.checkIntervalHours
        checkIntervalHours = min(max(rawHours, 1), 24)
        lastCheckAt = try? c.decode(Double.self, forKey: .lastCheckAt)
    }
}

/// 自动检查周期策略
enum AgentUpdatePolicy {
    static func shouldCheck(lastCheck: Date?, intervalHours: Int, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        let interval = TimeInterval(max(1, intervalHours) * 3600)
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

// MARK: - 模型

/// 受管 Agent 类型（区分命令行 CLI 与桌面端 App）
enum AgentKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case claudeCode = "claude-code"
    case claudeDesktop = "claude-desktop"
    case codexCLI = "codex-cli"
    case codexDesktop = "codex-desktop"
    case commandCode = "command-code"
    case openCode = "opencode"
    case pi = "pi"
    case deepSeekHarness = "deepseek-harness"
    case antigravity = "antigravity"

    var id: String { rawValue }

    var isDesktopApp: Bool {
        switch self {
        case .claudeDesktop, .codexDesktop, .deepSeekHarness, .antigravity:
            return true
        case .claudeCode, .codexCLI, .commandCode, .openCode, .pi:
            return false
        }
    }

    /// 桌面端应用的 Bundle Identifier（用于精确探测、进程归属与温和退出）
    var bundleIdentifier: String? {
        switch self {
        case .claudeDesktop: return "com.anthropic.claudefordesktop"
        case .codexDesktop: return "com.openai.codex"
        case .deepSeekHarness: return "com.deepseek.dsh"
        case .antigravity: return "com.google.antigravity"
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .codexCLI: return "Codex CLI"
        case .codexDesktop: return "Codex Desktop"
        case .commandCode: return "Command Code"
        case .openCode: return "OpenCode"
        case .pi: return "Pi"
        case .deepSeekHarness: return "DeepSeek Harness"
        case .antigravity: return "Antigravity"
        }
    }

    var shortName: String {
        displayName
    }

    /// 形态标签（帮助一眼区分 CLI 与桌面应用）
    var formTag: String {
        isDesktopApp ? L10n.t("桌面端", "Desktop") : "CLI"
    }

    var primaryCommand: String {
        switch self {
        case .claudeCode: return "claude"
        case .claudeDesktop: return "Claude.app"
        case .codexCLI: return "codex"
        case .codexDesktop: return "ChatGPT.app"
        case .commandCode: return "command-code"
        case .openCode: return "opencode"
        case .pi: return "pi"
        case .deepSeekHarness: return "DeepSeek Harness.app"
        case .antigravity: return "Antigravity.app"
        }
    }

    /// `~/.zshrc` 中对应的带代理启动别名；`nil` 表示直接启动、不使用代理（如 DeepSeek Harness）
    var zshrcProxyAlias: String? {
        switch self {
        case .claudeCode: return "claude-proxy"
        case .claudeDesktop: return "claude-desktop-proxy"
        case .codexCLI: return "codex-proxy"
        case .codexDesktop: return "codex-desktop-proxy"
        case .commandCode: return "cmd-proxy"
        case .openCode: return "opencode-proxy"
        case .pi: return "pi-proxy"
        case .deepSeekHarness: return nil
        case .antigravity: return "antigravity-desktop-proxy"
        }
    }

    /// 启动 / 重启时是否应走 `~/.zshrc` 代理别名
    var usesProxyLaunch: Bool {
        zshrcProxyAlias != nil
    }

    /// 本地 CLI 探测时按顺序尝试的可执行文件名（桌面端不走 PATH 查找）
    var executableNames: [String] {
        switch self {
        case .claudeCode: return ["claude"]
        case .claudeDesktop: return []
        case .codexCLI: return ["codex"]
        case .codexDesktop: return []
        case .commandCode: return ["command-code", "commandcode", "cmd"]
        case .openCode: return ["opencode"]
        case .pi: return ["pi"]
        case .deepSeekHarness: return []
        case .antigravity: return []
        }
    }

    var iconName: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .claudeDesktop: return "app-window-mac"
        case .codexCLI: return "terminal"
        case .codexDesktop: return "app-window"
        case .commandCode: return "command"
        case .openCode: return "code"
        case .pi: return "cpu"
        case .deepSeekHarness: return "layers"
        case .antigravity: return "zap"
        }
    }

    var homepageURL: URL {
        switch self {
        case .claudeCode: return URL(string: "https://docs.anthropic.com/en/docs/claude-code")!
        case .claudeDesktop: return URL(string: "https://claude.ai/download")!
        case .codexCLI: return URL(string: "https://github.com/openai/codex")!
        case .codexDesktop: return URL(string: "https://openai.com/codex")!
        case .commandCode: return URL(string: "https://commandcode.ai")!
        case .openCode: return URL(string: "https://opencode.ai")!
        case .pi: return URL(string: "https://github.com/earendil-works/pi")!
        case .deepSeekHarness: return URL(string: "https://www.deepseek.com")!
        case .antigravity: return URL(string: "https://antigravity.google/product/antigravity-2")!
        }
    }

    var summary: String {
        switch self {
        case .claudeCode:
            return L10n.t("Anthropic 官方终端编码代理（命令行）", "Anthropic's official terminal coding agent (CLI)")
        case .claudeDesktop:
            return L10n.t("Anthropic 官方 macOS 桌面客户端（Claude.app）", "Anthropic's official macOS desktop app (Claude.app)")
        case .codexCLI:
            return L10n.t("OpenAI 官方终端编码代理（命令行）", "OpenAI's official terminal coding agent (CLI)")
        case .codexDesktop:
            return L10n.t("OpenAI 官方 Codex 桌面客户端（com.openai.codex）", "OpenAI's official Codex desktop app (com.openai.codex)")
        case .commandCode:
            return L10n.t("持续学习代码风格的终端编码代理", "Coding agent that continuously learns your coding taste")
        case .openCode:
            return L10n.t("开源终端 AI 编码代理（SST / Anomaly）", "Open-source terminal AI coding agent")
        case .pi:
            return L10n.t("轻量可扩展的终端 AI 编码代理（@earendil-works/pi-coding-agent）", "Extensible terminal AI coding agent (@earendil-works/pi-coding-agent)")
        case .deepSeekHarness:
            return L10n.t("DeepSeek 官方桌面编码代理应用（DeepSeek Harness.app）", "DeepSeek's official desktop coding agent app (DeepSeek Harness.app)")
        case .antigravity:
            return L10n.t("Google 官方桌面 AI 代理编排平台（Antigravity.app）", "Google's official desktop AI agent platform (Antigravity.app)")
        }
    }

    var npmPackageName: String {
        switch self {
        case .claudeCode: return "@anthropic-ai/claude-code"
        case .claudeDesktop: return ""
        case .codexCLI: return "@openai/codex"
        case .codexDesktop: return ""
        case .commandCode: return "command-code"
        case .openCode: return "@opencode/cli"
        case .pi: return "@earendil-works/pi-coding-agent"
        case .deepSeekHarness: return ""
        case .antigravity: return ""
        }
    }
}

/// 安装方式
enum AgentInstallMethod: Equatable, Sendable {
    case native
    case appBundle
    case homebrew(formula: String?)
    case npm
    case bun
    case unknown

    var displayName: String {
        switch self {
        case .native: return L10n.t("原生安装", "Native")
        case .appBundle: return L10n.t("应用程序（.app）", "Application (.app)")
        case .homebrew(let formula):
            if let formula, !formula.isEmpty { return "Homebrew (\(formula))" }
            return "Homebrew"
        case .npm: return "npm"
        case .bun: return "Bun"
        case .unknown: return L10n.t("独立二进制", "Standalone")
        }
    }

    var shortBadge: String {
        switch self {
        case .native: return "Native"
        case .appBundle: return "App"
        case .homebrew: return "Homebrew"
        case .npm: return "npm"
        case .bun: return "Bun"
        case .unknown: return "Binary"
        }
    }
}

/// 单个 Agent 的运行操作状态
enum AgentActionState: Equatable, Sendable {
    case idle
    case checking
    case updating
    case installing
    case restarting
    case updated(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .updating, .installing, .restarting: return true
        default: return false
        }
    }
}

/// 单个 Agent 的完整状态快照
struct AgentCLIState: Identifiable, Equatable, Sendable {
    let kind: AgentKind
    var installed: Bool = false
    /// CLI 为可执行路径；Desktop 为 `.app` 路径（如 `/Applications/Claude.app`）
    var executablePath: String? = nil
    var resolvedPath: String? = nil
    var installMethod: AgentInstallMethod = .unknown
    var currentVersionRaw: String? = nil
    var currentVersion: SemVer? = nil
    var latestVersion: SemVer? = nil
    var latestSource: String? = nil
    /// 桌面端直链下载地址（如 `downloads.claude.ai/.../Claude-xxx.zip`）
    var latestDownloadURL: URL? = nil
    var latestCheckError: String? = nil
    var lastCheckedAt: Date? = nil
    var actionState: AgentActionState = .idle
    var lastOutput: String = ""

    var id: AgentKind { kind }

    var currentVersionText: String {
        if let v = currentVersion { return "v\(v.description)" }
        if let raw = currentVersionRaw, !raw.isEmpty { return raw }
        return installed ? L10n.t("未知版本", "Unknown") : L10n.t("未安装", "Not Installed")
    }

    var latestVersionText: String? {
        latestVersion.map { "v\($0.description)" }
    }

    var hasUpdate: Bool {
        guard installed, let cur = currentVersion, let latest = latestVersion else { return false }
        return latest > cur
    }

    var isUpToDate: Bool {
        guard installed, let cur = currentVersion, let latest = latestVersion else { return false }
        return latest <= cur
    }
}

/// 进程运行角色（帮助区分终端 CLI、后台服务、桌面主应用、桌面内嵌 Code 子进程）
enum AgentProcessRole: String, Equatable, Sendable {
    case cli
    case server
    case desktopApp
    case desktopChild

    var title: String {
        switch self {
        case .cli: return L10n.t("终端会话", "CLI Session")
        case .server: return L10n.t("后台服务", "Server")
        case .desktopApp: return L10n.t("桌面应用", "Desktop App")
        case .desktopChild: return L10n.t("桌面 Code 会话", "Desktop Code")
        }
    }
}

/// 一个正在运行的 Agent 进程（桌面应用主进程会聚合其全部 Helper）
struct AgentProcessItem: Identifiable, Equatable, Sendable {
    let pid: Int
    let startKey: UInt64
    let kind: AgentKind
    let role: AgentProcessRole
    let processName: String
    let executablePath: String
    let command: String
    let cwd: String?
    let gitRepo: String?
    let sourceCompact: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let startedAt: Date?
    let uptimeSeconds: TimeInterval
    /// 聚合的子 Helper 数量（仅 `.desktopApp` 时 > 1）
    let memberCount: Int

    var id: String { "\(pid)-\(startKey)" }

    /// 优先显示 Git 仓库名，其次显示工作目录末段；桌面主应用显示应用名
    var projectTitle: String {
        if role == .desktopApp {
            return kind.displayName
        }
        if let repo = gitRepo, !repo.isEmpty {
            return URL(fileURLWithPath: repo).lastPathComponent
        }
        if let cwd, !cwd.isEmpty, cwd != "/" {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return kind.displayName
    }

    var displayCWD: String? {
        if role == .desktopApp { return nil }
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return nil }
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") {
            return "~" + String(cwd.dropFirst(home.count))
        }
        return cwd
    }
}

/// 远程版本查询结果
struct AgentLatestVersion: Equatable, Sendable {
    let version: SemVer
    let source: String
    let downloadURL: URL?

    init(version: SemVer, source: String, downloadURL: URL? = nil) {
        self.version = version
        self.source = source
        self.downloadURL = downloadURL
    }
}

/// 更新或安装执行结果
struct AgentCommandResult: Equatable, Sendable {
    let ok: Bool
    let commandDisplay: String
    let output: String
    let errorMessage: String?
}

// MARK: - 纯函数：版本解析、安装方式识别、进程匹配

enum AgentVersionParser {
    /// 从任意 CLI `--version` 输出中提取首个 SemVer（如 `2.1.331 (Claude Code)`、`opencode v2.3.1`、`1.93.2`）
    static func extractSemVer(from text: String) -> SemVer? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = SemVer(trimmed) { return direct }
        let pattern = #"(?:\b[vV]|^|[^0-9A-Za-z._-])(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = trimmed as NSString
        let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
        for m in matches where m.numberOfRanges >= 2 {
            let token = ns.substring(with: m.range(at: 1))
            if let v = SemVer(token) { return v }
        }
        return nil
    }

    /// 解析 npm registry `/latest` 响应 JSON 中的 `version` 字段
    static func parseNpmRegistryLatest(_ data: Data) -> SemVer? {
        struct Payload: Decodable { let version: String? }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let raw = payload.version else { return nil }
        return extractSemVer(from: raw)
    }

    /// 解析 GitHub `/releases?per_page=10` 列表，取最高正式版 SemVer（支持 `v2.4.1` 与 `rust-v0.172.0` 等带前缀的 tag）
    static func parseGitHubHighestStableRelease(_ data: Data) -> SemVer? {
        struct RawRelease: Decodable {
            let tag_name: String?
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let list = try? JSONDecoder().decode([RawRelease].self, from: data) else { return nil }
        var best: SemVer?
        for item in list {
            if item.draft == true || item.prerelease == true { continue }
            guard let tag = item.tag_name, let v = extractSemVer(from: tag), v.prerelease.isEmpty else { continue }
            if let cur = best {
                if v > cur { best = v }
            } else {
                best = v
            }
        }
        return best
    }

    /// 解析 Claude Desktop 官方 Squirrel `RELEASES.json`（返回版本与 universal zip 下载链接）
    static func parseClaudeDesktopReleasesJSON(_ data: Data) -> AgentLatestVersion? {
        struct UpdateTo: Decodable {
            let version: String?
            let url: String?
        }
        struct ReleaseEntry: Decodable {
            let version: String?
            let updateTo: UpdateTo?
        }
        struct Payload: Decodable {
            let currentRelease: String?
            let releases: [ReleaseEntry]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let targetRaw = payload.currentRelease ?? payload.releases?.last?.version
        guard let targetRaw, let version = extractSemVer(from: targetRaw) else { return nil }
        let urlStr = payload.releases?.first(where: { $0.version == targetRaw })?.updateTo?.url
            ?? payload.releases?.last?.updateTo?.url
        let url = urlStr.flatMap(URL.init(string:))
        return AgentLatestVersion(version: version, source: "Anthropic Releases", downloadURL: url)
    }

    /// 解析 Sparkle `appcast.xml`（如 Codex Desktop `appcast.xml`），按当前 CPU 架构挑选最高版本及完整包下载链接（跳过 `<sparkle:deltas>`）
    static func parseSparkleAppcastXML(_ data: Data, arch: String = currentArchName(), source: String = "Sparkle") -> AgentLatestVersion? {
        final class Delegate: NSObject, XMLParserDelegate {
            struct Item {
                var shortVersion: String?
                var hardware: String?
                var enclosureURL: String?
            }
            var items: [Item] = []
            private var current: Item?
            private var inDeltas = false
            private var currentElement = ""
            private var buffer = ""

            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
                let name = (qName ?? elementName).lowercased()
                currentElement = name
                buffer = ""
                if name == "item" {
                    current = Item()
                    inDeltas = false
                } else if name == "sparkle:deltas" || name == "deltas" {
                    inDeltas = true
                } else if name == "enclosure", !inDeltas, var item = current {
                    if let url = attributeDict["url"], !url.isEmpty, item.enclosureURL == nil {
                        item.enclosureURL = url
                        current = item
                    }
                    if let sv = attributeDict["sparkle:shortVersionString"], !sv.isEmpty, item.shortVersion == nil {
                        item.shortVersion = sv
                        current = item
                    }
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                buffer += string
            }

            func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
                let name = (qName ?? elementName).lowercased()
                let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if name == "sparkle:deltas" || name == "deltas" {
                    inDeltas = false
                } else if name == "item" {
                    if let item = current { items.append(item) }
                    current = nil
                } else if var item = current, !text.isEmpty {
                    if name == "sparkle:shortversionstring" || name == "shortversionstring" {
                        item.shortVersion = text
                    } else if name == "sparkle:hardwarerequirements" || name == "hardwarerequirements" {
                        item.hardware = text
                    } else if name == "title", item.shortVersion == nil {
                        item.shortVersion = text
                    }
                    current = item
                }
                buffer = ""
                currentElement = ""
            }
        }

        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        let wantedArch = arch.lowercased()
        let matchesArch: (String?) -> Bool = { hw in
            guard let hw = hw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !hw.isEmpty else {
                return true
            }
            if wantedArch == "arm64" { return hw.contains("arm64") }
            return hw.contains("x86_64") || hw.contains("x64") || hw.contains("intel")
        }

        var best: AgentLatestVersion?
        for item in delegate.items {
            guard matchesArch(item.hardware),
                  let rawVer = item.shortVersion,
                  let ver = extractSemVer(from: rawVer) else { continue }
            let url = item.enclosureURL.flatMap(URL.init(string:))
            if let cur = best {
                if ver > cur.version {
                    best = AgentLatestVersion(version: ver, source: source, downloadURL: url)
                }
            } else {
                best = AgentLatestVersion(version: ver, source: source, downloadURL: url)
            }
        }
        return best
    }

    /// 解析 electron-updater 的 `*-mac.yml`（如 DeepSeek Harness `nightly-mac.yml`），支持行内值与 `>-` 多行折叠值
    static func parseElectronUpdaterYAML(_ data: Data, baseURL: URL? = nil, source: String = "Releases") -> AgentLatestVersion? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)

        var versionRaw: String?
        var pathRaw: String?
        var firstFileURL: String?

        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                idx += 1
                continue
            }

            func readScalarValue(afterColon rawValue: String, keyIndent: Int) -> (value: String, nextIndex: Int) {
                let v = rawValue.trimmingCharacters(in: .whitespaces)
                if v == ">-" || v == ">" || v == "|-" || v == "|" {
                    var parts: [String] = []
                    var blockIndent: Int?
                    var j = idx + 1
                    while j < lines.count {
                        let nextLine = lines[j]
                        let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                        if nextTrimmed.isEmpty { break }
                        let nextIndent = nextLine.prefix(while: { $0 == " " || $0 == "\t" }).count
                        if nextIndent <= keyIndent { break }
                        if let expected = blockIndent {
                            if nextIndent < expected { break }
                        } else {
                            blockIndent = nextIndent
                        }
                        parts.append(nextTrimmed)
                        j += 1
                    }
                    return (parts.joined(separator: ""), j)
                }
                let unquoted = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return (unquoted, idx + 1)
            }

            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            if indent == 0, trimmed.hasPrefix("version:") {
                let rest = String(trimmed.dropFirst("version:".count))
                let res = readScalarValue(afterColon: rest, keyIndent: indent)
                versionRaw = res.value
                idx = res.nextIndex
                continue
            }
            if indent == 0, trimmed.hasPrefix("path:") {
                let rest = String(trimmed.dropFirst("path:".count))
                let res = readScalarValue(afterColon: rest, keyIndent: indent)
                pathRaw = res.value
                idx = res.nextIndex
                continue
            }
            if firstFileURL == nil, trimmed.hasPrefix("- url:") || trimmed.hasPrefix("url:") {
                let isListItem = trimmed.hasPrefix("- url:")
                let prefix = isListItem ? "- url:" : "url:"
                let keyColumn = isListItem ? indent + 2 : indent
                let rest = String(trimmed.dropFirst(prefix.count))
                let res = readScalarValue(afterColon: rest, keyIndent: keyColumn)
                if !res.value.isEmpty {
                    firstFileURL = res.value
                }
                idx = res.nextIndex
                continue
            }

            idx += 1
        }

        guard let versionRaw, let ver = extractSemVer(from: versionRaw) else { return nil }
        let rawURL = [firstFileURL, pathRaw].compactMap { $0 }.first { !$0.isEmpty }
        let downloadURL: URL? = rawURL.flatMap { str in
            if str.hasPrefix("http://") || str.hasPrefix("https://") {
                return URL(string: str)
            }
            return baseURL?.appendingPathComponent(str)
        }
        return AgentLatestVersion(version: ver, source: source, downloadURL: downloadURL)
    }

    /// 解析 Homebrew Cask API (`https://formulae.brew.sh/api/cask/claude.json`)
    /// 版本格式通常为 `"6.28899.6,2f5fc59b..."`，取逗号前半段
    static func parseHomebrewCaskJSON(_ data: Data) -> AgentLatestVersion? {
        struct Payload: Decodable {
            let version: String?
            let url: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let rawVersion = payload.version else { return nil }
        let mainPart = rawVersion.split(separator: ",").first.map(String.init) ?? rawVersion
        guard let version = extractSemVer(from: mainPart) else { return nil }
        let url = payload.url.flatMap(URL.init(string:))
        return AgentLatestVersion(version: version, source: "Homebrew Cask", downloadURL: url)
    }

    static func currentArchName() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

enum AgentInstallDetector {
    /// 根据可执行文件路径和符号链接解析后的真实路径，识别 CLI 安装方式
    static func detect(executablePath: String, resolvedPath: String, home: String = NSHomeDirectory()) -> AgentInstallMethod {
        let combined = [resolvedPath, executablePath]

        if executablePath.lowercased().hasSuffix(".app") {
            return .appBundle
        }

        // 1. Homebrew（Cellar / Caskroom / opt/homebrew）
        for p in combined {
            if let range = p.range(of: "/Cellar/") {
                let after = p[range.upperBound...]
                let formula = after.split(separator: "/").first.map(String.init)
                return .homebrew(formula: formula)
            }
            if let range = p.range(of: "/Caskroom/") {
                let after = p[range.upperBound...]
                let cask = after.split(separator: "/").first.map(String.init)
                return .homebrew(formula: cask)
            }
        }
        if combined.contains(where: { $0.hasPrefix("/opt/homebrew/") || $0.hasPrefix("/usr/local/Cellar/") }) {
            return .homebrew(formula: nil)
        }

        // 2. Bun
        if combined.contains(where: { $0.contains("/.bun/") }) {
            return .bun
        }

        // 3. npm / nvm / volta / fnm / pnpm / node_modules
        if combined.contains(where: {
            $0.contains("/node_modules/")
                || $0.contains("/.nvm/")
                || $0.contains("/.volta/")
                || $0.contains("/.fnm/")
                || $0.contains("/.pnpm")
                || $0.contains("/pnpm/")
        }) {
            return .npm
        }

        // 4. Native（~/.local/share/claude、~/.local/bin、~/.opencode 等）
        if combined.contains(where: {
            $0.contains("/.local/share/claude/")
                || $0.contains("/.local/bin/")
                || $0.contains("/.claude/")
                || $0.contains("/.opencode/")
                || (!home.isEmpty && $0.hasPrefix(home + "/.local/"))
        }) {
            return .native
        }

        return .unknown
    }
}

enum AgentProcessMatcher {
    struct Match: Equatable, Sendable {
        let kind: AgentKind
        let role: AgentProcessRole
        /// 仅 `.desktopApp` 使用：标识该进程属于哪个 `.app` 包以便合并主进程与 Helper
        let appBundlePath: String?

        init(kind: AgentKind, role: AgentProcessRole, appBundlePath: String? = nil) {
            self.kind = kind
            self.role = role
            self.appBundlePath = appBundlePath
        }
    }

    /// 精确匹配受管 Agent 进程，严格分离各 CLI 与桌面端进程
    /// `codexDesktopBundlePaths`：本机已确认 `CFBundleIdentifier == com.openai.codex` 的 `.app` 小写路径集合
    /// （如 `/applications/chatgpt.app`），避免把非 Codex 版 ChatGPT.app 误判为 Codex Desktop。
    static func match(
        processName: String,
        executablePath: String?,
        argv: [String],
        codexDesktopBundlePaths: Set<String> = []
    ) -> Match? {
        let exe = executablePath ?? ""
        let lowerExe = exe.lowercased()
        let lowerName = processName.lowercased()
        let exeBase = URL(fileURLWithPath: exe).lastPathComponent.lowercased()
        let argv0Base = argv.first.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() } ?? ""

        // 排除常见 shell 与检索工具噪声
        let ignoredBins: Set<String> = [
            "zsh", "bash", "sh", "fish", "dash", "awk", "grep", "egrep", "fgrep", "rg", "ps", "pgrep", "lsof", "curl", "python", "python3"
        ]
        if ignoredBins.contains(exeBase) || ignoredBins.contains(lowerName) {
            return nil
        }

        // 1. Claude Desktop 主应用及其 Electron Helper（排除短生命周期的 disclaimer 包装器避免干扰计数）
        if let bundle = AppIdentity.bundlePath(forExecutable: exe),
           URL(fileURLWithPath: bundle).lastPathComponent.lowercased() == "claude.app",
           !lowerExe.contains("/application support/claude") {
            if exeBase == "disclaimer" { return nil }
            return Match(kind: .claudeDesktop, role: .desktopApp, appBundlePath: bundle)
        }

        // 2. Claude Desktop 内嵌拉起的 Claude Code 会话子进程（位于 Application Support/Claude.../claude-code/... 或 stream-json 协议）
        let isClaudeBinary = exeBase == "claude" || lowerName == "claude" || argv0Base == "claude"
        let isClaudeNodeScript = isNodeRuntime(exeBase) && argv.dropFirst().contains {
            let s = $0.lowercased()
            return s.contains("@anthropic-ai/claude-code") || s.hasSuffix("/claude") || s.contains("/claude-code/")
        }
        if isClaudeBinary || isClaudeNodeScript {
            let isDesktopChild = lowerExe.contains("/application support/claude")
                || argv.contains { $0.contains("--input-format") && $0.contains("stream-json") }
                || argv.contains("stream-json")
            if isDesktopChild {
                return Match(kind: .claudeDesktop, role: .desktopChild)
            }
            // 纯命令行 Claude Code
            return Match(kind: .claudeCode, role: .cli)
        }

        // 3. DeepSeek Harness 桌面应用及其 Electron Helper
        if let bundle = AppIdentity.bundlePath(forExecutable: exe),
           URL(fileURLWithPath: bundle).lastPathComponent.lowercased() == "deepseek harness.app" {
            return Match(kind: .deepSeekHarness, role: .desktopApp, appBundlePath: bundle)
        }

        // 3b. Antigravity 桌面应用、Electron Helper 与内置 language_server
        if let bundle = AppIdentity.bundlePath(forExecutable: exe),
           URL(fileURLWithPath: bundle).lastPathComponent.lowercased() == "antigravity.app" {
            return Match(kind: .antigravity, role: .desktopApp, appBundlePath: bundle)
        }

        // 4. Codex Desktop（Codex.app 或 Bundle ID 为 com.openai.codex 的 ChatGPT.app）及其内嵌 codex-cli 子进程
        if let bundle = AppIdentity.bundlePath(forExecutable: exe) {
            let lowerBundle = bundle.lowercased()
            let bundleName = URL(fileURLWithPath: bundle).lastPathComponent.lowercased()
            let isCodexDesktopBundle = bundleName == "codex.app" || codexDesktopBundlePaths.contains(lowerBundle)
            if isCodexDesktopBundle {
                if lowerExe.contains("/contents/resources/codex-cli/") {
                    return Match(kind: .codexDesktop, role: .desktopChild)
                }
                return Match(kind: .codexDesktop, role: .desktopApp, appBundlePath: bundle)
            }
        }

        // 5. Codex CLI（以及 Codex Desktop 拉起的 app-server 子进程）
        let isCodexBinary = exeBase == "codex" || lowerName == "codex" || argv0Base == "codex"
        let isCodexNodeScript = isNodeRuntime(exeBase) && argv.dropFirst().contains {
            let s = $0.lowercased()
            return s.contains("/@openai/codex/") || s.hasSuffix("/codex") || s.hasSuffix("/codex.js")
        }
        if isCodexBinary || isCodexNodeScript {
            if lowerExe.contains("/contents/resources/codex-cli/") || argv.contains("app-server") {
                return Match(kind: .codexDesktop, role: .desktopChild)
            }
            let isServer = argv.dropFirst().contains { $0 == "mcp-server" || $0 == "serve" || $0 == "acp" }
            return Match(kind: .codexCLI, role: isServer ? .server : .cli)
        }

        // 6. Command Code
        let isCommandCodeBinary = exeBase == "command-code"
            || exeBase == "commandcode"
            || lowerName == "command-code"
            || lowerName == "commandcode"
            || argv0Base == "command-code"
            || argv0Base == "commandcode"
        let isCommandCodeNodeScript = isNodeRuntime(exeBase) && argv.dropFirst().contains {
            let s = $0.lowercased()
            return s.contains("/command-code/") || s.hasSuffix("/command-code") || s.hasSuffix("/commandcode")
        }
        if isCommandCodeBinary || isCommandCodeNodeScript {
            let isServer = argv.contains("acp") || argv.contains("serve")
            return Match(kind: .commandCode, role: isServer ? .server : .cli)
        }

        // 7. OpenCode（排除未来可能存在的桌面端 Helper）
        if lowerExe.contains("/applications/opencode.app/contents/frameworks/") {
            return nil
        }
        let isOpenCodeBinary = exeBase == "opencode" || lowerName == "opencode" || argv0Base == "opencode"
        let isOpenCodeNodeScript = isNodeRuntime(exeBase) && argv.dropFirst().contains {
            let s = $0.lowercased()
            return s.contains("/@opencode/cli/") || s.contains("/opencode-ai/") || s.hasSuffix("/opencode")
        }
        if isOpenCodeBinary || isOpenCodeNodeScript {
            let isServer = argv.dropFirst().contains { $0 == "serve" || $0 == "web" || $0 == "acp" }
            return Match(kind: .openCode, role: isServer ? .server : .cli)
        }

        // 8. Pi（精确匹配 pi 二进制或 @earendil-works/pi-coding-agent / @mariozechner/pi-coding-agent 脚本）
        let isPiBinary = exeBase == "pi" || lowerName == "pi" || argv0Base == "pi"
        let isPiNodeScript = isNodeRuntime(exeBase) && argv.dropFirst().contains {
            let s = $0.lowercased()
            return s.contains("pi-coding-agent") || s.hasSuffix("/pi") || s.contains("/@earendil-works/pi")
        }
        if isPiBinary || isPiNodeScript {
            let isServer = argv.dropFirst().contains { $0 == "serve" || $0 == "rpc" || $0 == "acp" }
            return Match(kind: .pi, role: isServer ? .server : .cli)
        }

        return nil
    }

    private static func isNodeRuntime(_ base: String) -> Bool {
        base == "node" || base == "bun" || base == "deno"
    }
}

// MARK: - 环境 PATH 解析

enum AgentShellEnv {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedLoginPath: String?

    /// 构造覆盖 Homebrew、nvm、fnm、volta、bun、~/.local/bin 的完整环境变量，解决 GUI App 缺 PATH 问题
    static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = buildSearchPaths().joined(separator: ":")
        env["PATH"] = path
        if env["HOME"] == nil || env["HOME"]!.isEmpty {
            env["HOME"] = NSHomeDirectory()
        }
        return env
    }

    /// 从 `~/.zshrc` 文本中解析 `with-proxy` / `HTTPS_PROXY` / `HTTP_PROXY` 的代理地址（如 `http://127.0.0.1:1087`）
    static func parseProxyURL(fromZshrc content: String) -> String? {
        let pattern = #"(?:^|[;\s])(?:export\s+)?(?:HTTPS_PROXY|HTTP_PROXY|https_proxy|http_proxy)\s*=\s*['"]?(https?://[^\s'";#]+)['"]?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var fallbackHTTP: String?
        for rawLine in content.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let ns = trimmed as NSString
            guard let m = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges >= 2 else { continue }
            let urlStr = ns.substring(with: m.range(at: 1))
            if trimmed.contains("HTTPS_PROXY") || trimmed.contains("https_proxy") {
                return urlStr
            }
            if fallbackHTTP == nil {
                fallbackHTTP = urlStr
            }
        }
        return fallbackHTTP
    }

    /// 读取本机 `~/.zshrc` 中的代理地址；若为本机回环地址则快速探测端口是否可达，避免代理未开时导致更新失败
    static func activeZshrcProxyURL(home: String = NSHomeDirectory(), checkReachability: Bool = true) -> String? {
        let zshrcPath = "\(home)/.zshrc"
        guard let content = try? String(contentsOfFile: zshrcPath, encoding: .utf8),
              let urlStr = parseProxyURL(fromZshrc: content) else {
            return nil
        }
        guard checkReachability else { return urlStr }
        guard let url = URL(string: urlStr),
              let host = url.host,
              let port = url.port ?? (url.scheme == "https" ? 443 : 80) as Int? else {
            return nil
        }
        if host == "127.0.0.1" || host == "localhost" {
            return isLocalPortOpen(host: "127.0.0.1", port: UInt16(clamping: port)) ? urlStr : nil
        }
        return urlStr
    }

    /// 构造用于版本检查 / 下载更新的环境变量：
    /// - DeepSeek Harness（`usesProxyLaunch == false`）：强制清空代理变量直连
    /// - 其他海外源 Agent：若检测到 `~/.zshrc` 代理可达，则注入 `HTTP_PROXY`/`HTTPS_PROXY` 并清理 `ALL_PROXY`
    static func updateEnvironment(for kind: AgentKind, base: [String: String] = enrichedEnvironment(), proxyURL: String? = activeZshrcProxyURL()) -> [String: String] {
        var env = base
        for key in ["ALL_PROXY", "all_proxy"] {
            env.removeValue(forKey: key)
        }
        guard kind.usesProxyLaunch else {
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
                env.removeValue(forKey: key)
            }
            return env
        }
        if let proxyURL, !proxyURL.isEmpty {
            env["HTTP_PROXY"] = proxyURL
            env["HTTPS_PROXY"] = proxyURL
            env["http_proxy"] = proxyURL
            env["https_proxy"] = proxyURL
            env["NO_PROXY"] = "localhost,127.0.0.1,::1"
            env["no_proxy"] = "localhost,127.0.0.1,::1"
            env["NODE_USE_ENV_PROXY"] = "1"
        }
        return env
    }

    private static func isLocalPortOpen(host: String, port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if res == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = Darwin.poll(&pfd, 1, 150)
        guard ready > 0 else { return false }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else { return false }
        return soError == 0
    }

    static func buildSearchPaths(home: String = NSHomeDirectory()) -> [String] {
        var dirs: [String] = []
        var seen = Set<String>()
        func add(_ dir: String) {
            let clean = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else { return }
            dirs.append(clean)
        }

        add("\(home)/.local/bin")
        add("/opt/homebrew/bin")
        add("/opt/homebrew/sbin")
        add("/usr/local/bin")
        add("\(home)/.bun/bin")
        add("\(home)/.volta/bin")
        add("\(home)/.fnm/current/bin")
        add("\(home)/.opencode/bin")
        add("\(home)/.npm-global/bin")

        let nvmRoot = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            let sorted = entries.sorted { a, b in
                switch (SemVer(a), SemVer(b)) {
                case let (va?, vb?): return va > vb
                default: return a > b
                }
            }
            for e in sorted {
                add("\(nvmRoot)/\(e)/bin")
            }
        }

        if let loginPath = loadLoginShellPath() {
            for part in loginPath.split(separator: ":") {
                add(String(part))
            }
        }

        if let cur = ProcessInfo.processInfo.environment["PATH"] {
            for part in cur.split(separator: ":") { add(String(part)) }
        }
        for sys in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] { add(sys) }

        return dirs
    }

    /// 在增强 PATH 中查找可执行文件绝对路径
    static func locateExecutable(_ names: [String]) -> String? {
        let fm = FileManager.default
        for dir in buildSearchPaths() {
            for name in names {
                let candidate = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: candidate) {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    private static func loadLoginShellPath() -> String? {
        lock.lock()
        if let cached = cachedLoginPath {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let out = Shell.run("/bin/zsh", ["-lc", "printf '%s' \"$PATH\""], timeout: 3)
        let value = out.ok ? out.text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        lock.lock()
        cachedLoginPath = value
        lock.unlock()
        return value.isEmpty ? nil : value
    }
}

// MARK: - 桌面端重启命令构造（纯函数，便于单测）

enum AgentLaunchBuilder {
    /// 单引号安全转义（POSIX shell）
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 构造在非交互 zsh 中加载 `~/.zshrc` 并执行指定代理别名的脚本（alias 不存在时走兜底命令）
    static func buildDesktopProxyScript(aliasName: String, fallbackOpenCommand: String) -> String {
        """
        setopt aliases
        [ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc" >/dev/null 2>&1
        if whence -w \(shellQuote(aliasName)) >/dev/null 2>&1; then
          eval \(shellQuote(aliasName))
        else
          \(fallbackOpenCommand)
        fi
        """
    }

    /// 为指定桌面端 Agent 返回重启按钮的展示命令描述（用于日志）
    static func restartCommandDisplay(for kind: AgentKind, appPath: String? = nil) -> String {
        if let alias = kind.zshrcProxyAlias {
            return "~/.zshrc → \(alias)"
        }
        let target = appPath ?? "/Applications/\(kind.primaryCommand)"
        return "open -a \(shellQuote(target))"
    }
}

// MARK: - 运行时操作（探测 / 查最新版本 / 更新安装 / 重启 / 进程采集与终止）

enum AgentRuntime {
    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"
    static let codexDesktopBundleID = "com.openai.codex"
    static let deepSeekHarnessBundleID = "com.deepseek.dsh"
    static let antigravityBundleID = "com.google.antigravity"

    /// 探测单个 Agent 的本机安装路径、安装方式与当前版本
    static func inspectLocal(_ kind: AgentKind) -> AgentCLIState {
        if kind.isDesktopApp {
            return inspectDesktopAppLocal(for: kind)
        }
        var state = AgentCLIState(kind: kind)
        guard let exePath = AgentShellEnv.locateExecutable(kind.executableNames) else {
            return state
        }
        let resolved = URL(fileURLWithPath: exePath).resolvingSymlinksInPath().path
        state.installed = true
        state.executablePath = exePath
        state.resolvedPath = resolved
        state.installMethod = AgentInstallDetector.detect(executablePath: exePath, resolvedPath: resolved)

        let env = AgentShellEnv.enrichedEnvironment()
        let out = Shell.run(exePath, ["--version"], environment: env, timeout: 8)
        let combined = [out.text, out.stderr].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = combined.split(whereSeparator: \.isNewline).first {
            state.currentVersionRaw = String(firstLine).trimmingCharacters(in: .whitespaces)
        }
        state.currentVersion = AgentVersionParser.extractSemVer(from: combined)
        return state
    }

    /// 探测桌面端 `.app`（Claude Desktop / Codex Desktop / DeepSeek Harness）
    private static func inspectDesktopAppLocal(for kind: AgentKind) -> AgentCLIState {
        var state = AgentCLIState(kind: kind)
        guard let appPath = resolveDesktopAppPath(for: kind) else {
            return state
        }
        state.installed = true
        state.executablePath = appPath
        state.resolvedPath = URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path

        let fm = FileManager.default
        let caskNames: [String] = {
            switch kind {
            case .claudeDesktop: return ["claude"]
            case .codexDesktop: return ["chatgpt", "codex-app"]
            case .deepSeekHarness: return ["deepseek-harness"]
            case .antigravity: return ["antigravity"]
            default: return []
            }
        }()
        if let matchedCask = caskNames.first(where: {
            fm.fileExists(atPath: "/opt/homebrew/Caskroom/\($0)")
                || fm.fileExists(atPath: "/usr/local/Caskroom/\($0)")
        }) {
            state.installMethod = .homebrew(formula: matchedCask)
        } else {
            state.installMethod = .appBundle
        }

        let plistPath = "\(appPath)/Contents/Info.plist"
        if let dict = NSDictionary(contentsOfFile: plistPath) {
            let shortVer = dict["CFBundleShortVersionString"] as? String
            let bundleVer = dict["CFBundleVersion"] as? String
            let raw = shortVer ?? bundleVer
            state.currentVersionRaw = raw
            if let raw {
                state.currentVersion = AgentVersionParser.extractSemVer(from: raw)
            }
        }
        return state
    }

    /// 解析本机桌面端 `.app` 路径（按 Bundle ID 与标准目录探测，避免误匹配同名不同产品的应用）
    static func resolveDesktopAppPath(for kind: AgentKind) -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        func bundleID(at appPath: String) -> String? {
            let plist = "\(appPath)/Contents/Info.plist"
            guard let dict = NSDictionary(contentsOfFile: plist) else { return nil }
            return dict["CFBundleIdentifier"] as? String
        }

        if let expectedBundleID = kind.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: expectedBundleID),
           fm.fileExists(atPath: "\(url.path)/Contents/Info.plist") {
            return url.path
        }

        let candidates: [(path: String, requireBundleID: String?)]
        switch kind {
        case .claudeDesktop:
            candidates = [
                ("/Applications/Claude.app", nil),
                ("\(home)/Applications/Claude.app", nil),
            ]
        case .codexDesktop:
            candidates = [
                ("/Applications/Codex.app", nil),
                ("\(home)/Applications/Codex.app", nil),
                ("/Applications/ChatGPT.app", codexDesktopBundleID),
                ("\(home)/Applications/ChatGPT.app", codexDesktopBundleID),
            ]
        case .deepSeekHarness:
            candidates = [
                ("/Applications/DeepSeek Harness.app", nil),
                ("\(home)/Applications/DeepSeek Harness.app", nil),
            ]
        case .antigravity:
            candidates = [
                ("/Applications/Antigravity.app", nil),
                ("\(home)/Applications/Antigravity.app", nil),
            ]
        default:
            candidates = []
        }

        for item in candidates {
            guard fm.fileExists(atPath: "\(item.path)/Contents/Info.plist") else { continue }
            if let required = item.requireBundleID {
                guard bundleID(at: item.path) == required else { continue }
            }
            return item.path
        }
        return nil
    }

    /// 异步查询远程最新版本（非 DeepSeek 优先复用 `~/.zshrc` 可达代理；DeepSeek Harness 强制直连）
    static func fetchLatestVersion(for kind: AgentKind) async -> Result<AgentLatestVersion, Error> {
        let useProxy = kind.usesProxyLaunch
        switch kind {
        case .claudeCode:
            if let text = await httpGetText("https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest", useProxy: useProxy),
               let v = AgentVersionParser.extractSemVer(from: text) {
                return .success(AgentLatestVersion(version: v, source: "Anthropic Releases"))
            }
            if let data = await httpGetData("https://registry.npmjs.org/@anthropic-ai/claude-code/latest", useProxy: useProxy),
               let v = AgentVersionParser.parseNpmRegistryLatest(data) {
                return .success(AgentLatestVersion(version: v, source: "npm"))
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 Claude Code 最新版本", "Unable to fetch latest Claude Code version")))

        case .claudeDesktop:
            if let data = await httpGetData("https://downloads.claude.ai/releases/darwin/universal/RELEASES.json", useProxy: useProxy),
               let latest = AgentVersionParser.parseClaudeDesktopReleasesJSON(data) {
                return .success(latest)
            }
            if let data = await httpGetData("https://formulae.brew.sh/api/cask/claude.json", useProxy: useProxy),
               let latest = AgentVersionParser.parseHomebrewCaskJSON(data) {
                return .success(latest)
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 Claude Desktop 最新版本", "Unable to fetch latest Claude Desktop version")))

        case .codexCLI:
            if let data = await httpGetData("https://registry.npmjs.org/@openai/codex/latest", useProxy: useProxy),
               let v = AgentVersionParser.parseNpmRegistryLatest(data) {
                return .success(AgentLatestVersion(version: v, source: "npm"))
            }
            if let data = await httpGetData("https://api.github.com/repos/openai/codex/releases?per_page=10", useProxy: useProxy),
               let v = AgentVersionParser.parseGitHubHighestStableRelease(data) {
                return .success(AgentLatestVersion(version: v, source: "GitHub Releases"))
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 Codex CLI 最新版本", "Unable to fetch latest Codex CLI version")))

        case .codexDesktop:
            if let data = await httpGetData("https://persistent.oaistatic.com/codex-app-prod/appcast.xml", accept: "application/xml, text/xml, */*", useProxy: useProxy),
               let latest = AgentVersionParser.parseSparkleAppcastXML(data, source: "OpenAI Releases") {
                return .success(latest)
            }
            if let data = await httpGetData("https://formulae.brew.sh/api/cask/chatgpt.json", useProxy: useProxy),
               let latest = AgentVersionParser.parseHomebrewCaskJSON(data) {
                return .success(latest)
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 Codex Desktop 最新版本", "Unable to fetch latest Codex Desktop version")))

        case .commandCode:
            if let data = await httpGetData("https://registry.npmjs.org/command-code/latest", useProxy: useProxy),
               let v = AgentVersionParser.parseNpmRegistryLatest(data) {
                return .success(AgentLatestVersion(version: v, source: "npm"))
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 Command Code 最新版本", "Unable to fetch latest Command Code version")))

        case .openCode:
            if let data = await httpGetData("https://registry.npmjs.org/@opencode/cli/latest", useProxy: useProxy),
               let v = AgentVersionParser.parseNpmRegistryLatest(data) {
                return .success(AgentLatestVersion(version: v, source: "npm"))
            }
            if let data = await httpGetData("https://api.github.com/repos/anomalyco/opencode/releases?per_page=10", useProxy: useProxy),
               let v = AgentVersionParser.parseGitHubHighestStableRelease(data) {
                return .success(AgentLatestVersion(version: v, source: "GitHub Releases"))
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 OpenCode 最新版本", "Unable to fetch latest OpenCode version")))

        case .pi:
            let pkg = resolvePiNpmPackageName()
            if let data = await httpGetData("https://registry.npmjs.org/\(pkg)/latest", useProxy: useProxy),
               let v = AgentVersionParser.parseNpmRegistryLatest(data) {
                return .success(AgentLatestVersion(version: v, source: "npm"))
            }
            if let data = await httpGetData("https://api.github.com/repos/earendil-works/pi/releases?per_page=10", useProxy: useProxy),
               let v = AgentVersionParser.parseGitHubHighestStableRelease(data) {
                return .success(AgentLatestVersion(version: v, source: "GitHub Releases"))
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 Pi 最新版本", "Unable to fetch latest Pi version")))

        case .deepSeekHarness:
            let feed = resolveDeepSeekHarnessFeed()
            if let data = await httpGetData(feed.yamlURL.absoluteString, accept: "text/yaml, text/plain, */*", useProxy: false),
               let latest = AgentVersionParser.parseElectronUpdaterYAML(data, baseURL: feed.baseURL, source: "DeepSeek Releases") {
                return .success(latest)
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 DeepSeek Harness 最新版本", "Unable to fetch latest DeepSeek Harness version")))

        case .antigravity:
            let feed = resolveAntigravityFeed()
            if let data = await httpGetData(feed.yamlURL.absoluteString, accept: "text/yaml, text/plain, */*", useProxy: useProxy),
               let latest = AgentVersionParser.parseElectronUpdaterYAML(data, baseURL: feed.baseURL, source: "Google Releases") {
                return .success(latest)
            }
            if let data = await httpGetData("https://formulae.brew.sh/api/cask/antigravity.json", useProxy: useProxy),
               let latest = AgentVersionParser.parseHomebrewCaskJSON(data) {
                let zipURL = (latest.downloadURL?.pathExtension.lowercased() == "zip") ? latest.downloadURL : nil
                return .success(AgentLatestVersion(version: latest.version, source: latest.source, downloadURL: zipURL))
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 Antigravity 最新版本", "Unable to fetch latest Antigravity version")))
        }
    }

    private static func resolvePiNpmPackageName(resolvedPath: String? = nil) -> String {
        let pathToCheck = resolvedPath
            ?? AgentShellEnv.locateExecutable(["pi"]).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            ?? ""
        if pathToCheck.contains("@mariozechner/pi-coding-agent") {
            return "@mariozechner/pi-coding-agent"
        }
        return "@earendil-works/pi-coding-agent"
    }

    /// 读取 DeepSeek Harness 内置 `app-update.yml` 确定更新频道与架构 feed URL
    private static func resolveDeepSeekHarnessFeed() -> (baseURL: URL, yamlURL: URL) {
        let archDir = AgentVersionParser.currentArchName() == "arm64" ? "mac-arm64" : "mac-x64"
        var baseStr = "https://download.deepseek.com/dsh-desk/feeds/\(archDir)/"
        var channel = "nightly"

        if let appPath = resolveDesktopAppPath(for: .deepSeekHarness),
           let content = try? String(contentsOfFile: "\(appPath)/Contents/Resources/app-update.yml", encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("url:") {
                    let v = String(t.dropFirst("url:".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !v.isEmpty { baseStr = v.hasSuffix("/") ? v : v + "/" }
                } else if t.hasPrefix("channel:") {
                    let v = String(t.dropFirst("channel:".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !v.isEmpty { channel = v }
                }
            }
        }
        let baseURL = URL(string: baseStr) ?? URL(string: "https://download.deepseek.com/dsh-desk/feeds/\(archDir)/")!
        let yamlURL = baseURL.appendingPathComponent("\(channel)-mac.yml")
        return (baseURL, yamlURL)
    }

    /// 读取 Antigravity 内置 `app-update.yml` 确定官方 electron-updater 清单 URL（按架构区分 `latest-arm64-mac.yml` / `latest-x64-mac.yml`）
    private static func resolveAntigravityFeed(arch: String = AgentVersionParser.currentArchName()) -> (baseURL: URL, yamlURL: URL) {
        let defaultBase = "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/"
        var baseStr = defaultBase

        if let appPath = resolveDesktopAppPath(for: .antigravity),
           let content = try? String(contentsOfFile: "\(appPath)/Contents/Resources/app-update.yml", encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("url:") {
                    let v = String(t.dropFirst("url:".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !v.isEmpty { baseStr = v.hasSuffix("/") ? v : v + "/" }
                }
            }
        }
        let archSuffix = arch.lowercased() == "arm64" ? "arm64" : "x64"
        let baseURL = URL(string: baseStr) ?? URL(string: defaultBase)!
        let yamlURL = baseURL.appendingPathComponent("latest-\(archSuffix)-mac.yml")
        return (baseURL, yamlURL)
    }

    /// 执行单个 Agent 的更新或安装（阻塞，在后台线程调用）
    static func updateOrInstall(_ state: AgentCLIState) -> AgentCommandResult {
        let kind = state.kind
        let env = AgentShellEnv.updateEnvironment(for: kind)

        if kind.isDesktopApp {
            return updateOrInstallDesktopApp(state, env: env)
        }

        if state.installed, let exe = state.executablePath {
            switch kind {
            case .claudeCode:
                switch state.installMethod {
                case .npm:
                    return runNpmGlobalInstall(package: kind.npmPackageName, nearExecutable: exe, env: env)
                case .homebrew(let formula):
                    let target = formula ?? "claude-code"
                    return runBrewUpgrade(formula: target, cask: false, env: env)
                case .bun:
                    return runBunGlobalInstall(package: kind.npmPackageName, env: env)
                case .native, .appBundle, .unknown:
                    return runCommand(exe, ["update"], display: "claude update", env: env, timeout: 240)
                }

            case .codexCLI:
                switch state.installMethod {
                case .npm:
                    return runNpmGlobalInstall(package: kind.npmPackageName, nearExecutable: exe, env: env)
                case .homebrew(let formula):
                    let isCask = (state.resolvedPath ?? exe).contains("/Caskroom/")
                    return runBrewUpgrade(formula: formula ?? "codex", cask: isCask, env: env)
                case .bun:
                    return runBunGlobalInstall(package: kind.npmPackageName, env: env)
                case .native, .appBundle, .unknown:
                    return runNpmGlobalInstall(package: kind.npmPackageName, nearExecutable: exe, env: env)
                }

            case .commandCode:
                switch state.installMethod {
                case .npm:
                    let r = runCommand(exe, ["update"], display: "command-code update", env: env, timeout: 240)
                    if r.ok { return r }
                    return runNpmGlobalInstall(package: kind.npmPackageName, nearExecutable: exe, env: env)
                case .bun:
                    return runBunGlobalInstall(package: kind.npmPackageName, env: env)
                default:
                    return runCommand(exe, ["update"], display: "command-code update", env: env, timeout: 240)
                }

            case .openCode:
                switch state.installMethod {
                case .homebrew(let formula):
                    let r = runCommand(exe, ["upgrade", "--method", "brew"], display: "opencode upgrade --method brew", env: env, timeout: 300)
                    if r.ok { return r }
                    let target = (formula == "opencode-v2") ? "anomalyco/tap/opencode-v2" : (formula ?? "opencode")
                    return runBrewUpgrade(formula: target, cask: false, env: env)
                case .npm:
                    return runNpmGlobalInstall(package: kind.npmPackageName, nearExecutable: exe, env: env)
                case .bun:
                    return runBunGlobalInstall(package: kind.npmPackageName, env: env)
                case .native, .appBundle, .unknown:
                    return runCommand(exe, ["upgrade"], display: "opencode upgrade", env: env, timeout: 240)
                }

            case .pi:
                let pkg = resolvePiNpmPackageName(resolvedPath: state.resolvedPath)
                switch state.installMethod {
                case .npm:
                    return runNpmGlobalInstall(package: pkg, nearExecutable: exe, env: env)
                case .bun:
                    return runBunGlobalInstall(package: pkg, env: env)
                case .homebrew(let formula):
                    return runBrewUpgrade(formula: formula ?? "pi", cask: false, env: env)
                case .native, .appBundle, .unknown:
                    return runNpmGlobalInstall(package: pkg, nearExecutable: exe, env: env)
                }

            case .claudeDesktop, .codexDesktop, .deepSeekHarness, .antigravity:
                return updateOrInstallDesktopApp(state, env: env)
            }
        } else {
            switch kind {
            case .claudeCode:
                return runShellScript("curl -fsSL https://claude.ai/install.sh | bash",
                                      display: "curl -fsSL https://claude.ai/install.sh | bash",
                                      env: env, timeout: 300)
            case .codexCLI:
                return runNpmGlobalInstall(package: kind.npmPackageName, nearExecutable: nil, env: env)
            case .commandCode:
                return runNpmGlobalInstall(package: kind.npmPackageName, nearExecutable: nil, env: env)
            case .openCode:
                return runShellScript("curl -fsSL https://opencode.ai/v2/install | bash",
                                      display: "curl -fsSL https://opencode.ai/v2/install | bash",
                                      env: env, timeout: 300)
            case .pi:
                return runNpmGlobalInstall(package: kind.npmPackageName, nearExecutable: nil, env: env)
            case .claudeDesktop, .codexDesktop, .deepSeekHarness, .antigravity:
                return updateOrInstallDesktopApp(state, env: env)
            }
        }
    }

    /// 通用桌面应用更新或安装（Claude Desktop / Codex Desktop / DeepSeek Harness）：
    /// Homebrew Cask 走 `brew upgrade --cask`，否则下载官方 zip 原子替换 `.app`
    private static func updateOrInstallDesktopApp(_ state: AgentCLIState, env: [String: String]) -> AgentCommandResult {
        let kind = state.kind
        if case .homebrew(let formula) = state.installMethod, state.installed {
            let cask = formula ?? {
                switch kind {
                case .claudeDesktop: return "claude"
                case .codexDesktop: return "chatgpt"
                case .deepSeekHarness: return "deepseek-harness"
                case .antigravity: return "antigravity"
                default: return kind.rawValue
                }
            }()
            return runBrewUpgrade(formula: cask, cask: true, env: env)
        }

        // 获取最新官方下载地址（若状态中尚未缓存，则实时拉取一次）
        var zipURL = state.latestDownloadURL
        if zipURL == nil {
            zipURL = probeDesktopDownloadURLSync(for: kind, env: env)
        }
        guard let downloadURL = zipURL else {
            return AgentCommandResult(
                ok: false,
                commandDisplay: "\(kind.displayName) update",
                output: "",
                errorMessage: L10n.t("未获取到 \(kind.displayName) 官方下载链接，请先点击检查更新或前往官网下载。",
                                     "Could not resolve \(kind.displayName) download URL. Check for updates again or download from the website.")
            )
        }

        let targetApp = state.executablePath ?? "/Applications/\(kind.primaryCommand)"
        let display = "curl -fL \(downloadURL.absoluteString) -> \(targetApp)"
        let bundleID = kind.bundleIdentifier
        let wasRunning = bundleID.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("popbar-\(kind.rawValue)-\(UUID().uuidString)")
        let zipFile = workDir.appendingPathComponent("release.zip")
        let unpackDir = workDir.appendingPathComponent("unpack")
        defer { try? fm.removeItem(at: workDir) }

        do {
            try fm.createDirectory(at: unpackDir, withIntermediateDirectories: true)
        } catch {
            return AgentCommandResult(ok: false, commandDisplay: display, output: "", errorMessage: error.localizedDescription)
        }

        var logs: [String] = []
        if let proxy = env["HTTPS_PROXY"] ?? env["HTTP_PROXY"] {
            logs.append("Proxy: \(proxy)")
        } else {
            logs.append("Proxy: direct (no proxy)")
        }
        logs.append("Downloading \(downloadURL.lastPathComponent)…")
        let dl = Shell.run("/usr/bin/curl", ["-fL", "--retry", "2", "-o", zipFile.path, downloadURL.absoluteString], environment: env, timeout: 600)
        guard dl.ok else {
            return AgentCommandResult(ok: false, commandDisplay: display, output: logs.joined(separator: "\n"), errorMessage: dl.error)
        }

        logs.append("Extracting archive…")
        let unzip = Shell.run("/usr/bin/ditto", ["-xk", zipFile.path, unpackDir.path], environment: env, timeout: 120)
        guard unzip.ok else {
            return AgentCommandResult(ok: false, commandDisplay: display, output: logs.joined(separator: "\n"), errorMessage: unzip.error)
        }

        // 在解压目录中找到有效的 .app（优先匹配同 Bundle ID）
        let unpackedApps = (try? fm.contentsOfDirectory(at: unpackDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "app" && fm.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path) } ?? []
        let extractedApp = unpackedApps.first(where: { appURL in
            guard let expected = bundleID,
                  let dict = NSDictionary(contentsOfFile: appURL.appendingPathComponent("Contents/Info.plist").path) else { return false }
            return (dict["CFBundleIdentifier"] as? String) == expected
        }) ?? unpackedApps.first

        guard let extractedApp else {
            return AgentCommandResult(
                ok: false,
                commandDisplay: display,
                output: logs.joined(separator: "\n"),
                errorMessage: L10n.t("下载包中未找到有效的 .app 应用包", "Valid .app bundle not found in downloaded archive")
            )
        }

        // 若桌面应用正在运行，先结束已有进程以便替换应用包
        if wasRunning {
            logs.append("Quitting running \(kind.displayName)…")
            terminateDesktopAppIfRunning(bundleID: bundleID, appPath: targetApp, waitSeconds: 8)
        }

        let targetURL = URL(fileURLWithPath: targetApp)
        let parentDir = targetURL.deletingLastPathComponent()
        let backupURL = parentDir.appendingPathComponent("\(targetURL.lastPathComponent).popbar-backup")

        do {
            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }
            if fm.fileExists(atPath: targetURL.path) {
                try fm.moveItem(at: targetURL, to: backupURL)
            }
            do {
                try fm.moveItem(at: extractedApp, to: targetURL)
                if fm.fileExists(atPath: backupURL.path) {
                    try? fm.removeItem(at: backupURL)
                }
            } catch {
                if fm.fileExists(atPath: backupURL.path) {
                    try? fm.moveItem(at: backupURL, to: targetURL)
                }
                throw error
            }
        } catch {
            return AgentCommandResult(
                ok: false,
                commandDisplay: display,
                output: logs.joined(separator: "\n"),
                errorMessage: L10n.t("替换 \(targetApp) 失败：\(error.localizedDescription)", "Failed to replace \(targetApp): \(error.localizedDescription)")
            )
        }

        _ = Shell.run("/usr/bin/xattr", ["-cr", targetURL.path], environment: env, timeout: 15)
        logs.append("Installed \(targetURL.path)")

        if wasRunning {
            logs.append("Relaunching \(kind.displayName)…")
            _ = launchDesktopApp(kind: kind, appPath: targetURL.path, env: env)
        }

        return AgentCommandResult(ok: true, commandDisplay: display, output: logs.joined(separator: "\n"), errorMessage: nil)
    }

    private static func probeDesktopDownloadURLSync(for kind: AgentKind, env: [String: String]) -> URL? {
        switch kind {
        case .claudeDesktop:
            let probe = Shell.run("/usr/bin/curl", ["-fsSL", "--max-time", "15", "https://downloads.claude.ai/releases/darwin/universal/RELEASES.json"], environment: env, timeout: 20)
            return probe.ok ? AgentVersionParser.parseClaudeDesktopReleasesJSON(probe.stdout)?.downloadURL : nil
        case .codexDesktop:
            let probe = Shell.run("/usr/bin/curl", ["-fsSL", "--max-time", "15", "https://persistent.oaistatic.com/codex-app-prod/appcast.xml"], environment: env, timeout: 20)
            return probe.ok ? AgentVersionParser.parseSparkleAppcastXML(probe.stdout, source: "OpenAI Releases")?.downloadURL : nil
        case .deepSeekHarness:
            let feed = resolveDeepSeekHarnessFeed()
            let probe = Shell.run("/usr/bin/curl", ["-fsSL", "--max-time", "15", feed.yamlURL.absoluteString], environment: env, timeout: 20)
            return probe.ok ? AgentVersionParser.parseElectronUpdaterYAML(probe.stdout, baseURL: feed.baseURL, source: "DeepSeek Releases")?.downloadURL : nil
        case .antigravity:
            let feed = resolveAntigravityFeed()
            let probe = Shell.run("/usr/bin/curl", ["-fsSL", "--max-time", "15", feed.yamlURL.absoluteString], environment: env, timeout: 20)
            return probe.ok ? AgentVersionParser.parseElectronUpdaterYAML(probe.stdout, baseURL: feed.baseURL, source: "Google Releases")?.downloadURL : nil
        default:
            return nil
        }
    }

    // MARK: - 桌面端统一重启（先 kill 已有进程，无则跳过，再按 ~/.zshrc 代理别名或直连启动）

    /// 启动桌面端应用：带代理别名的走 `~/.zshrc` 中的 `*-proxy`，DeepSeek Harness 直接启动不走代理
    static func launchDesktopApp(kind: AgentKind, appPath: String?, env: [String: String] = AgentShellEnv.enrichedEnvironment()) -> AgentCommandResult {
        let resolvedPath = appPath ?? resolveDesktopAppPath(for: kind) ?? "/Applications/\(kind.primaryCommand)"
        let display = AgentLaunchBuilder.restartCommandDisplay(for: kind, appPath: resolvedPath)

        // DeepSeek Harness（无代理别名）：清理可能残留的代理环境变量，直接启动
        guard let aliasName = kind.zshrcProxyAlias else {
            var cleanEnv = env
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
                cleanEnv.removeValue(forKey: key)
            }
            let out = Shell.run("/usr/bin/open", ["-a", resolvedPath], environment: cleanEnv, timeout: 15)
            return makeResult(out, display: display)
        }

        // 其他桌面端（Claude Desktop / Codex Desktop）：加载 ~/.zshrc 并执行对应的 *-proxy 别名
        let fallbackOpen: String = {
            if let bid = kind.bundleIdentifier {
                return "open -b \(AgentLaunchBuilder.shellQuote(bid))"
            }
            return "open -a \(AgentLaunchBuilder.shellQuote(resolvedPath))"
        }()
        let script = AgentLaunchBuilder.buildDesktopProxyScript(aliasName: aliasName, fallbackOpenCommand: fallbackOpen)
        let out = Shell.run("/bin/zsh", ["-c", script], environment: env, timeout: 25)
        return makeResult(out, display: display)
    }

    /// 桌面端统一重启：先检查并结束已有进程（含同应用包下的所有 Helper）；若未运行则直接跳过 kill，然后启动应用
    static func restartDesktopApp(kind: AgentKind, appPath: String?) -> AgentCommandResult {
        guard kind.isDesktopApp else {
            return AgentCommandResult(
                ok: false,
                commandDisplay: kind.displayName,
                output: "",
                errorMessage: L10n.t("仅桌面端应用支持重启操作", "Restart is only supported for desktop apps")
            )
        }
        let env = AgentShellEnv.enrichedEnvironment()
        let resolvedPath = appPath ?? resolveDesktopAppPath(for: kind) ?? "/Applications/\(kind.primaryCommand)"
        terminateDesktopAppIfRunning(bundleID: kind.bundleIdentifier, appPath: resolvedPath, waitSeconds: 4)
        return launchDesktopApp(kind: kind, appPath: resolvedPath, env: env)
    }

    /// 结束指定桌面端应用的所有已有进程；若当前没有运行中的进程则立即跳过返回
    private static func terminateDesktopAppIfRunning(bundleID: String?, appPath: String?, waitSeconds: TimeInterval) {
        let runningApps = bundleID.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0) } ?? []
        let bundlePIDs = appPath.map { findRunningPIDs(inAppBundle: $0) } ?? []

        guard !runningApps.isEmpty || !bundlePIDs.isEmpty else {
            return
        }

        // 1. 先温和退出（NSRunningApplication.terminate + SIGTERM）
        for app in runningApps { app.terminate() }
        for pid in bundlePIDs { _ = Darwin.kill(Int32(pid), SIGTERM) }

        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            let appsAlive = bundleID.map {
                !NSRunningApplication.runningApplications(withBundleIdentifier: $0).allSatisfy(\.isTerminated)
            } ?? false
            let pidsAlive = appPath.map { !findRunningPIDs(inAppBundle: $0).isEmpty } ?? false
            if !appsAlive && !pidsAlive {
                break
            }
            Thread.sleep(forTimeInterval: 0.15)
        }

        // 2. 若仍有残留进程则强杀（forceTerminate + SIGKILL）
        if let bundleID {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where !app.isTerminated {
                app.forceTerminate()
            }
        }
        if let appPath {
            let survivors = findRunningPIDs(inAppBundle: appPath)
            if !survivors.isEmpty {
                for pid in survivors { _ = Darwin.kill(Int32(pid), SIGKILL) }
                let killDeadline = Date().addingTimeInterval(1.0)
                while Date() < killDeadline {
                    if findRunningPIDs(inAppBundle: appPath).isEmpty { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }

    /// 扫描当前运行中属于指定 `.app` 包路径下的所有 PID（主进程 + Electron Helpers）
    private static func findRunningPIDs(inAppBundle appPath: String) -> [Int] {
        guard !appPath.isEmpty else { return [] }
        let prefix = appPath.hasSuffix("/") ? appPath.lowercased() : (appPath + "/").lowercased()
        let resolved = URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path
        let resolvedPrefix = resolved.hasSuffix("/") ? resolved.lowercased() : (resolved + "/").lowercased()

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return [] }

        let myPID = Int(getpid())
        var result: [Int] = []
        for rawPID in pids.prefix(Int(got)) {
            let pid = Int(rawPID)
            if pid <= 1 || pid == myPID { continue }
            guard let exe = LibProc.path(pid)?.lowercased() else { continue }
            if exe.hasPrefix(prefix) || exe.hasPrefix(resolvedPrefix) {
                result.append(pid)
            }
        }
        return result
    }

    // MARK: - 进程扫描与安全终止

    struct CPUSampleState: Sendable {
        var prevCPUTimeNS: [String: UInt64] = [:]
        var prevSampleAt: TimeInterval = 0
    }

    private struct MatchedRaw {
        let pid: Int
        let match: AgentProcessMatcher.Match
        let name: String
        let exe: String
        let argv: [String]
    }

    /// 扫描当前运行中的所有受管 Agent 进程（纯 Darwin libproc，无外部子进程）
    /// Claude Desktop 主应用与 Electron Helper 会聚合成 1 行，避免刷屏；其内嵌 Code 子进程单独列出。
    static func scanProcesses(cpuState: inout CPUSampleState) -> [AgentProcessItem] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return [] }

        let myPID = Int(getpid())
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let nowDate = Date()
        let dtNS: Double = cpuState.prevSampleAt > 0 ? max(0.1, nowUptime - cpuState.prevSampleAt) * 1_000_000_000 : 0
        var nextCPUMap: [String: UInt64] = [:]

        let codexDesktopBundlePaths: Set<String> = {
            var set = Set<String>()
            if let path = resolveDesktopAppPath(for: .codexDesktop) {
                set.insert(path.lowercased())
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path.lowercased()
                set.insert(resolved)
            }
            return set
        }()

        var matched: [MatchedRaw] = []
        for rawPID in pids.prefix(Int(got)) {
            let pid = Int(rawPID)
            if pid <= 1 || pid == myPID { continue }
            let name = LibProc.name(pid)
            let exe = LibProc.path(pid)
            if !isCandidate(name: name, exe: exe, codexDesktopBundlePaths: codexDesktopBundlePaths) { continue }
            let argv = LibProc.args(pid)?.argv ?? []
            if let m = AgentProcessMatcher.match(processName: name, executablePath: exe, argv: argv, codexDesktopBundlePaths: codexDesktopBundlePaths) {
                matched.append(MatchedRaw(pid: pid, match: m, name: name, exe: exe ?? "", argv: argv))
            }
        }

        guard !matched.isEmpty else {
            cpuState.prevCPUTimeNS = [:]
            cpuState.prevSampleAt = nowUptime
            return []
        }

        let parents = LibProc.parentMap()
        var standalone: [AgentProcessItem] = []
        var desktopBuckets: [String: [MatchedRaw]] = [:]

        for entry in matched {
            if entry.match.role == .desktopApp, let bundle = entry.match.appBundlePath {
                desktopBuckets[bundle, default: []].append(entry)
            } else {
                if let item = buildSingleItem(entry: entry, parents: parents, dtNS: dtNS, nowDate: nowDate,
                                              prevCPU: cpuState.prevCPUTimeNS, nextCPU: &nextCPUMap) {
                    standalone.append(item)
                }
            }
        }

        // 将每个 Claude Desktop 应用包的主进程 + 全部 Electron Helper 聚合成 1 行
        for (bundle, members) in desktopBuckets {
            let mainEntry = members.first(where: { AppIdentity.isMainExecutable($0.exe, bundle: bundle) })
                ?? members.min(by: { $0.pid < $1.pid })
            guard let main = mainEntry, let bsd = LibProc.bsd(main.pid) else { continue }
            let startKey = bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec

            var totalRSS: UInt64 = 0
            var totalCPU: Double = 0
            for m in members {
                guard let mBSD = LibProc.bsd(m.pid), let task = LibProc.taskInfo(m.pid) else { continue }
                totalRSS &+= task.pti_resident_size
                let mKey = "\(m.pid)-\(mBSD.pbi_start_tvsec &* 1_000_000 &+ mBSD.pbi_start_tvusec)"
                let totalNS = task.pti_total_user &+ task.pti_total_system
                nextCPUMap[mKey] = totalNS
                if dtNS > 0, let prev = cpuState.prevCPUTimeNS[mKey], totalNS >= prev {
                    totalCPU += min(Double(totalNS - prev) / dtNS * 100.0, 1600.0)
                }
            }

            let startedAt = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
            let uptime = max(0, nowDate.timeIntervalSince(startedAt))
            let helperCount = max(0, members.count - 1)
            let sourceText = helperCount > 0
                ? L10n.t("主进程 + \(helperCount) 个辅助进程", "Main + \(helperCount) helpers")
                : L10n.t("桌面应用主进程", "Desktop app main process")

            standalone.append(AgentProcessItem(
                pid: main.pid,
                startKey: startKey,
                kind: main.match.kind,
                role: .desktopApp,
                processName: main.name,
                executablePath: bundle,
                command: main.exe,
                cwd: nil,
                gitRepo: nil,
                sourceCompact: sourceText,
                cpuPercent: totalCPU,
                memoryBytes: totalRSS,
                startedAt: startedAt,
                uptimeSeconds: uptime,
                memberCount: members.count
            ))
        }

        cpuState.prevCPUTimeNS = nextCPUMap
        cpuState.prevSampleAt = nowUptime

        let order = Dictionary(uniqueKeysWithValues: AgentKind.allCases.enumerated().map { ($1, $0) })
        return standalone.sorted { a, b in
            let oa = order[a.kind] ?? 99
            let ob = order[b.kind] ?? 99
            if oa != ob { return oa < ob }
            if a.role == .desktopApp && b.role != .desktopApp { return true }
            if a.role != .desktopApp && b.role == .desktopApp { return false }
            return a.uptimeSeconds < b.uptimeSeconds
        }
    }

    /// 安全终止进程：桌面应用走 `NSRunningApplication.terminate/forceTerminate`，普通进程校验 `startKey` 后发信号
    static func terminateProcess(_ item: AgentProcessItem, force: Bool) -> Result<Void, AgentLookupError> {
        guard let currentKey = LibProc.startKey(item.pid) else {
            return .success(())
        }
        guard currentKey == item.startKey else {
            return .failure(.unavailable(L10n.t("进程已退出或 PID 已被复用，已取消操作", "Process exited or PID was reused; action cancelled")))
        }

        if item.role == .desktopApp,
           let app = NSRunningApplication(processIdentifier: pid_t(item.pid)) {
            let ok = force ? app.forceTerminate() : app.terminate()
            if ok || app.isTerminated { return .success(()) }
        }

        let sig: Int32 = force ? SIGKILL : SIGTERM
        if Darwin.kill(Int32(item.pid), sig) == 0 || errno == ESRCH {
            return .success(())
        }
        return .failure(.unavailable(L10n.t("无法终止进程：\(String(cString: strerror(errno)))", "Failed to stop process: \(String(cString: strerror(errno)))")))
    }

    // MARK: - 内部辅助

    private static func buildSingleItem(
        entry: MatchedRaw,
        parents: [Int: Int],
        dtNS: Double,
        nowDate: Date,
        prevCPU: [String: UInt64],
        nextCPU: inout [String: UInt64]
    ) -> AgentProcessItem? {
        let pid = entry.pid
        guard let bsd = LibProc.bsd(pid) else { return nil }
        let startKey = bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec
        let key = "\(pid)-\(startKey)"

        var rss: UInt64 = 0
        var cpuPct: Double = 0
        if let task = LibProc.taskInfo(pid) {
            rss = task.pti_resident_size
            let totalNS = task.pti_total_user &+ task.pti_total_system
            nextCPU[key] = totalNS
            if dtNS > 0, let prev = prevCPU[key], totalNS >= prev {
                cpuPct = min(Double(totalNS - prev) / dtNS * 100.0, 1600.0)
            }
        }

        let startedAt = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
        let uptime = max(0, nowDate.timeIntervalSince(startedAt))
        let cwd = LibProc.cwd(pid)
        let gitRepo = cwd.flatMap { $0 == "/" ? nil : findGitRoot(from: $0) }
        let sourceCompact = resolveSourceCompact(pid: pid, bsdPPID: Int(bsd.pbi_ppid), parents: parents)
        let commandText: String = {
            let raw = entry.argv.isEmpty ? entry.name : entry.argv.joined(separator: " ")
            return raw.count > 260 ? String(raw.prefix(260)) + "…" : raw
        }()

        return AgentProcessItem(
            pid: pid,
            startKey: startKey,
            kind: entry.match.kind,
            role: entry.match.role,
            processName: entry.name,
            executablePath: entry.exe,
            command: commandText,
            cwd: cwd,
            gitRepo: gitRepo,
            sourceCompact: sourceCompact,
            cpuPercent: cpuPct,
            memoryBytes: rss,
            startedAt: startedAt,
            uptimeSeconds: uptime,
            memberCount: 1
        )
    }

    private static func isCandidate(name: String, exe: String?, codexDesktopBundlePaths: Set<String>) -> Bool {
        let lowerName = name.lowercased()
        if lowerName.contains("claude")
            || lowerName.contains("codex")
            || lowerName.contains("deepseek")
            || lowerName.contains("antigravity")
            || lowerName.contains("opencode")
            || lowerName.contains("command")
            || lowerName == "pi"
            || lowerName == "node"
            || lowerName == "bun"
            || lowerName == "deno" {
            return true
        }
        if let exe {
            let lowerExe = exe.lowercased()
            if lowerExe.contains("claude")
                || lowerExe.contains("codex")
                || lowerExe.contains("deepseek harness.app")
                || lowerExe.contains("antigravity.app")
                || lowerExe.contains("opencode")
                || lowerExe.contains("command-code")
                || lowerExe.contains("pi-coding-agent")
                || lowerExe.hasSuffix("/pi")
                || lowerExe.hasSuffix("/node")
                || lowerExe.hasSuffix("/bun") {
                return true
            }
            for bundlePath in codexDesktopBundlePaths where lowerExe.hasPrefix(bundlePath + "/") {
                return true
            }
        }
        return false
    }

    private static func resolveSourceCompact(pid: Int, bsdPPID: Int, parents: [Int: Int]) -> String {
        var chain: [ChainNode] = []
        var cur = pid
        var guardN = 0
        while guardN < 14 {
            chain.append(chainNode(cur))
            let up: Int? = parents[cur] ?? (cur == pid ? bsdPPID : nil)
            guard let pp = up, pp > 0 else { break }
            if pp == 1 {
                chain.append(ChainNode(pid: 1, name: "launchd", appName: nil))
                break
            }
            cur = pp
            guardN += 1
        }
        let info = ProcessText.classify(chain: chain.reversed(), label: nil, hasPlist: false)
        return info.compact
    }

    private static func chainNode(_ pid: Int) -> ChainNode {
        if pid == 1 { return ChainNode(pid: 1, name: "launchd", appName: nil) }
        let app = LibProc.path(pid)
            .flatMap { AppIdentity.bundlePath(forExecutable: $0) }
            .map { AppIdentity.displayName(bundlePath: $0) }
        return ChainNode(pid: pid, name: LibProc.name(pid), appName: app)
    }

    private static func findGitRoot(from dir: String) -> String? {
        var url = URL(fileURLWithPath: dir)
        for _ in 0..<16 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            let up = url.deletingLastPathComponent()
            if up.path == url.path { break }
            url = up
        }
        return nil
    }

    private static func runNpmGlobalInstall(package: String, nearExecutable: String?, env: [String: String]) -> AgentCommandResult {
        var npmPath: String?
        if let nearExecutable {
            let sibling = (URL(fileURLWithPath: nearExecutable).deletingLastPathComponent().path as NSString)
                .appendingPathComponent("npm")
            if FileManager.default.isExecutableFile(atPath: sibling) {
                npmPath = sibling
            }
        }
        let resolvedNpm = npmPath ?? AgentShellEnv.locateExecutable(["npm"])
        guard let npm = resolvedNpm else {
            return AgentCommandResult(
                ok: false,
                commandDisplay: "npm install -g \(package)@latest",
                output: "",
                errorMessage: L10n.t("未找到 npm，请先安装 Node.js", "npm not found; please install Node.js first")
            )
        }
        return runCommand(npm, ["install", "-g", "\(package)@latest"],
                          display: "npm install -g \(package)@latest", env: env, timeout: 300)
    }

    private static func runBunGlobalInstall(package: String, env: [String: String]) -> AgentCommandResult {
        guard let bun = AgentShellEnv.locateExecutable(["bun"]) else {
            return AgentCommandResult(
                ok: false,
                commandDisplay: "bun install -g \(package)@latest",
                output: "",
                errorMessage: L10n.t("未找到 bun", "bun not found")
            )
        }
        return runCommand(bun, ["install", "-g", "\(package)@latest"],
                          display: "bun install -g \(package)@latest", env: env, timeout: 300)
    }

    private static func runBrewUpgrade(formula: String, cask: Bool, env: [String: String]) -> AgentCommandResult {
        guard let brew = AgentShellEnv.locateExecutable(["brew"]) else {
            return AgentCommandResult(
                ok: false,
                commandDisplay: cask ? "brew upgrade --cask \(formula)" : "brew upgrade \(formula)",
                output: "",
                errorMessage: L10n.t("未找到 Homebrew（brew）", "Homebrew (brew) not found")
            )
        }
        let args = cask ? ["upgrade", "--cask", formula] : ["upgrade", formula]
        let display = cask ? "brew upgrade --cask \(formula)" : "brew upgrade \(formula)"
        return runCommand(brew, args, display: display, env: env, timeout: 300)
    }

    private static func runShellScript(_ script: String, display: String, env: [String: String], timeout: TimeInterval) -> AgentCommandResult {
        let out = Shell.run("/bin/bash", ["-lc", script], environment: env, timeout: timeout)
        return makeResult(out, display: display)
    }

    private static func runCommand(_ exe: String, _ args: [String], display: String, env: [String: String], timeout: TimeInterval) -> AgentCommandResult {
        let out = Shell.run(exe, args, environment: env, timeout: timeout)
        return makeResult(out, display: display)
    }

    private static func makeResult(_ out: Shell.Output, display: String) -> AgentCommandResult {
        let combined = [out.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return AgentCommandResult(
            ok: out.ok,
            commandDisplay: display,
            output: combined,
            errorMessage: out.ok ? nil : (out.error.isEmpty ? L10n.t("执行失败", "Command failed") : out.error)
        )
    }

    private static func httpGetData(_ urlString: String, accept: String = "application/json", useProxy: Bool = true) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("PopBar-AgentManager", forHTTPHeaderField: "User-Agent")
        req.setValue(accept, forHTTPHeaderField: "Accept")

        let session: URLSession
        var needsInvalidate = false
        if !useProxy {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.connectionProxyDictionary = [:]
            session = URLSession(configuration: cfg)
            needsInvalidate = true
        } else if let proxyStr = AgentShellEnv.activeZshrcProxyURL(),
                  let proxyURL = URL(string: proxyStr),
                  let host = proxyURL.host,
                  let port = proxyURL.port {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": host,
                "HTTPPort": port,
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": port,
                "ExceptionsList": ["localhost", "127.0.0.1", "::1"],
            ]
            session = URLSession(configuration: cfg)
            needsInvalidate = true
        } else {
            session = .shared
        }
        defer {
            if needsInvalidate { session.finishTasksAndInvalidate() }
        }

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func httpGetText(_ urlString: String, useProxy: Bool = true) async -> String? {
        guard let data = await httpGetData(urlString, useProxy: useProxy) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AgentLookupError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let msg): return msg
        }
    }
}
