import Cocoa
import Darwin
import Foundation
import PopBarCore

// Agent 管理核心层（无 SwiftUI 依赖，全部可在后台线程运行）：
// 1. 定义受管 Agent（一期：Claude Code 命令行、Claude Desktop 桌面端、Command Code、OpenCode）；
// 2. 探测本机安装路径、安装方式与当前版本（CLI 构造完整 PATH；Desktop 读 Info.plist）；
// 3. 查询远程最新版本并执行更新/安装（全部子进程走 PopBarCore.Shell）；
// 4. 复用 LibProc 原生扫描运行中的 Agent 进程，严格分离 Claude Code CLI 与 Claude Desktop 进程。

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
    case commandCode = "command-code"
    case openCode = "opencode"

    var id: String { rawValue }

    var isDesktopApp: Bool {
        self == .claudeDesktop
    }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .commandCode: return "Command Code"
        case .openCode: return "OpenCode"
        }
    }

    var shortName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .commandCode: return "Command Code"
        case .openCode: return "OpenCode"
        }
    }

    /// 形态标签（帮助一眼区分 CLI 与桌面应用）
    var formTag: String {
        isDesktopApp ? L10n.t("桌面端", "Desktop") : "CLI"
    }

    var primaryCommand: String {
        switch self {
        case .claudeCode: return "claude"
        case .claudeDesktop: return "Claude.app"
        case .commandCode: return "command-code"
        case .openCode: return "opencode"
        }
    }

    /// 本地 CLI 探测时按顺序尝试的可执行文件名（桌面端不走 PATH 查找）
    var executableNames: [String] {
        switch self {
        case .claudeCode: return ["claude"]
        case .claudeDesktop: return []
        case .commandCode: return ["command-code", "commandcode"]
        case .openCode: return ["opencode"]
        }
    }

    var iconName: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .claudeDesktop: return "app-window-mac"
        case .commandCode: return "command"
        case .openCode: return "code"
        }
    }

    var homepageURL: URL {
        switch self {
        case .claudeCode: return URL(string: "https://docs.anthropic.com/en/docs/claude-code")!
        case .claudeDesktop: return URL(string: "https://claude.ai/download")!
        case .commandCode: return URL(string: "https://commandcode.ai")!
        case .openCode: return URL(string: "https://opencode.ai")!
        }
    }

    var summary: String {
        switch self {
        case .claudeCode:
            return L10n.t("Anthropic 官方终端编码代理（命令行）", "Anthropic's official terminal coding agent (CLI)")
        case .claudeDesktop:
            return L10n.t("Anthropic 官方 macOS 桌面客户端（Claude.app）", "Anthropic's official macOS desktop app (Claude.app)")
        case .commandCode:
            return L10n.t("持续学习代码风格的终端编码代理", "Coding agent that continuously learns your coding taste")
        case .openCode:
            return L10n.t("开源终端 AI 编码代理（SST / Anomaly）", "Open-source terminal AI coding agent")
        }
    }

    var npmPackageName: String {
        switch self {
        case .claudeCode: return "@anthropic-ai/claude-code"
        case .claudeDesktop: return ""
        case .commandCode: return "command-code"
        case .openCode: return "@opencode/cli"
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
    case updated(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .updating, .installing: return true
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
        let pattern = #"(?:^|[^0-9A-Za-z._-])v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)"#
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

    /// 解析 GitHub `/releases?per_page=10` 列表，取最高正式版 SemVer
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
            guard let tag = item.tag_name, let v = SemVer(tag) else { continue }
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

    /// 精确匹配受管 Agent 进程，严格分离「Claude Code 命令行」与「Claude Desktop 桌面端」
    static func match(processName: String, executablePath: String?, argv: [String]) -> Match? {
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

        // 3. Command Code
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

        // 4. OpenCode（排除未来可能存在的桌面端 Helper）
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

// MARK: - 运行时操作（探测 / 查最新版本 / 更新安装 / 进程采集与终止）

enum AgentRuntime {
    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// 探测单个 Agent 的本机安装路径、安装方式与当前版本
    static func inspectLocal(_ kind: AgentKind) -> AgentCLIState {
        if kind == .claudeDesktop {
            return inspectClaudeDesktopLocal()
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

    /// 探测 Claude Desktop（`/Applications/Claude.app` 或 `~/Applications/Claude.app`）
    private static func inspectClaudeDesktopLocal() -> AgentCLIState {
        var state = AgentCLIState(kind: .claudeDesktop)
        let fm = FileManager.default
        let candidates = [
            "/Applications/Claude.app",
            "\(NSHomeDirectory())/Applications/Claude.app",
        ]
        guard let appPath = candidates.first(where: { fm.fileExists(atPath: "\($0)/Contents/Info.plist") }) else {
            return state
        }
        state.installed = true
        state.executablePath = appPath
        state.resolvedPath = URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path

        let isBrewCask = fm.fileExists(atPath: "/opt/homebrew/Caskroom/claude")
            || fm.fileExists(atPath: "/usr/local/Caskroom/claude")
        state.installMethod = isBrewCask ? .homebrew(formula: "claude") : .appBundle

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

    /// 异步查询远程最新版本
    static func fetchLatestVersion(for kind: AgentKind) async -> Result<AgentLatestVersion, Error> {
        switch kind {
        case .claudeCode:
            if let text = await httpGetText("https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest"),
               let v = AgentVersionParser.extractSemVer(from: text) {
                return .success(AgentLatestVersion(version: v, source: "Anthropic Releases"))
            }
            if let data = await httpGetData("https://registry.npmjs.org/@anthropic-ai/claude-code/latest"),
               let v = AgentVersionParser.parseNpmRegistryLatest(data) {
                return .success(AgentLatestVersion(version: v, source: "npm"))
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 Claude Code 最新版本", "Unable to fetch latest Claude Code version")))

        case .claudeDesktop:
            if let data = await httpGetData("https://downloads.claude.ai/releases/darwin/universal/RELEASES.json"),
               let latest = AgentVersionParser.parseClaudeDesktopReleasesJSON(data) {
                return .success(latest)
            }
            if let data = await httpGetData("https://formulae.brew.sh/api/cask/claude.json"),
               let latest = AgentVersionParser.parseHomebrewCaskJSON(data) {
                return .success(latest)
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 Claude Desktop 最新版本", "Unable to fetch latest Claude Desktop version")))

        case .commandCode:
            if let data = await httpGetData("https://registry.npmjs.org/command-code/latest"),
               let v = AgentVersionParser.parseNpmRegistryLatest(data) {
                return .success(AgentLatestVersion(version: v, source: "npm"))
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 Command Code 最新版本", "Unable to fetch latest Command Code version")))

        case .openCode:
            if let data = await httpGetData("https://registry.npmjs.org/@opencode/cli/latest"),
               let v = AgentVersionParser.parseNpmRegistryLatest(data) {
                return .success(AgentLatestVersion(version: v, source: "npm"))
            }
            if let data = await httpGetData("https://api.github.com/repos/anomalyco/opencode/releases?per_page=10"),
               let v = AgentVersionParser.parseGitHubHighestStableRelease(data) {
                return .success(AgentLatestVersion(version: v, source: "GitHub Releases"))
            }
            return .failure(AgentLookupError.unavailable(L10n.t("无法获取 OpenCode 最新版本", "Unable to fetch latest OpenCode version")))
        }
    }

    /// 执行单个 Agent 的更新或安装（阻塞，在后台线程调用）
    static func updateOrInstall(_ state: AgentCLIState) -> AgentCommandResult {
        let env = AgentShellEnv.enrichedEnvironment()
        let kind = state.kind

        if kind == .claudeDesktop {
            return updateOrInstallClaudeDesktop(state, env: env)
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

            case .claudeDesktop:
                return updateOrInstallClaudeDesktop(state, env: env)
            }
        } else {
            switch kind {
            case .claudeCode:
                return runShellScript("curl -fsSL https://claude.ai/install.sh | bash",
                                      display: "curl -fsSL https://claude.ai/install.sh | bash",
                                      env: env, timeout: 300)
            case .commandCode:
                return runNpmGlobalInstall(package: kind.npmPackageName, nearExecutable: nil, env: env)
            case .openCode:
                return runShellScript("curl -fsSL https://opencode.ai/v2/install | bash",
                                      display: "curl -fsSL https://opencode.ai/v2/install | bash",
                                      env: env, timeout: 300)
            case .claudeDesktop:
                return updateOrInstallClaudeDesktop(state, env: env)
            }
        }
    }

    /// 更新或安装 Claude Desktop：Homebrew Cask 走 `brew upgrade --cask claude`，否则下载官方 zip 安全替换 `.app`
    private static func updateOrInstallClaudeDesktop(_ state: AgentCLIState, env: [String: String]) -> AgentCommandResult {
        if case .homebrew = state.installMethod, state.installed {
            return runBrewUpgrade(formula: "claude", cask: true, env: env)
        }

        // 获取最新官方下载地址（若状态中尚未缓存，则实时拉取一次）
        var zipURL = state.latestDownloadURL
        if zipURL == nil {
            let probe = Shell.run("/usr/bin/curl", ["-fsSL", "--max-time", "15", "https://downloads.claude.ai/releases/darwin/universal/RELEASES.json"], environment: env, timeout: 20)
            if probe.ok, let parsed = AgentVersionParser.parseClaudeDesktopReleasesJSON(probe.stdout) {
                zipURL = parsed.downloadURL
            }
        }
        guard let downloadURL = zipURL else {
            return AgentCommandResult(
                ok: false,
                commandDisplay: "Claude Desktop update",
                output: "",
                errorMessage: L10n.t("未获取到 Claude Desktop 官方下载链接，请先点击检查更新或前往官网下载。",
                                     "Could not resolve Claude Desktop download URL. Check for updates again or download from the website.")
            )
        }

        let targetApp = state.executablePath ?? "/Applications/Claude.app"
        let display = "curl -fL \(downloadURL.absoluteString) -> \(targetApp)"
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: claudeDesktopBundleID).isEmpty

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("popbar-claude-desktop-\(UUID().uuidString)")
        let zipFile = workDir.appendingPathComponent("Claude.zip")
        let unpackDir = workDir.appendingPathComponent("unpack")
        defer { try? fm.removeItem(at: workDir) }

        do {
            try fm.createDirectory(at: unpackDir, withIntermediateDirectories: true)
        } catch {
            return AgentCommandResult(ok: false, commandDisplay: display, output: "", errorMessage: error.localizedDescription)
        }

        var logs: [String] = []
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

        let extractedApp = unpackDir.appendingPathComponent("Claude.app")
        guard fm.fileExists(atPath: extractedApp.appendingPathComponent("Contents/Info.plist").path) else {
            return AgentCommandResult(
                ok: false,
                commandDisplay: display,
                output: logs.joined(separator: "\n"),
                errorMessage: L10n.t("下载包中未找到有效的 Claude.app", "Valid Claude.app not found in downloaded archive")
            )
        }

        // 若 Claude Desktop 正在运行，先温和退出以便替换应用包
        if wasRunning {
            logs.append("Quitting running Claude Desktop…")
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: claudeDesktopBundleID)
            for app in apps { app.terminate() }
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if NSRunningApplication.runningApplications(withBundleIdentifier: claudeDesktopBundleID).allSatisfy(\.isTerminated) {
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: claudeDesktopBundleID) where !app.isTerminated {
                app.forceTerminate()
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        let targetURL = URL(fileURLWithPath: targetApp)
        let parentDir = targetURL.deletingLastPathComponent()
        let backupURL = parentDir.appendingPathComponent("Claude.app.popbar-backup")

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
            logs.append("Relaunching Claude Desktop…")
            _ = Shell.run("/usr/bin/open", ["-a", targetURL.path], environment: env, timeout: 10)
        }

        return AgentCommandResult(ok: true, commandDisplay: display, output: logs.joined(separator: "\n"), errorMessage: nil)
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

        var matched: [MatchedRaw] = []
        for rawPID in pids.prefix(Int(got)) {
            let pid = Int(rawPID)
            if pid <= 1 || pid == myPID { continue }
            let name = LibProc.name(pid)
            let exe = LibProc.path(pid)
            if !isCandidate(name: name, exe: exe) { continue }
            let argv = LibProc.args(pid)?.argv ?? []
            if let m = AgentProcessMatcher.match(processName: name, executablePath: exe, argv: argv) {
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

    private static func isCandidate(name: String, exe: String?) -> Bool {
        let lowerName = name.lowercased()
        if lowerName.contains("claude") || lowerName.contains("opencode") || lowerName.contains("command")
            || lowerName == "node" || lowerName == "bun" || lowerName == "deno" {
            return true
        }
        if let exe {
            let lowerExe = exe.lowercased()
            if lowerExe.contains("claude") || lowerExe.contains("opencode") || lowerExe.contains("command-code")
                || lowerExe.hasSuffix("/node") || lowerExe.hasSuffix("/bun") {
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

    private static func httpGetData(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("PopBar-AgentManager", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func httpGetText(_ urlString: String) async -> String? {
        guard let data = await httpGetData(urlString) else { return nil }
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
