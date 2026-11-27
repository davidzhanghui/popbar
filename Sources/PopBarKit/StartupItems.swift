import Cocoa
import ServiceManagement
import PopBarCore
import PopBarPlatform
import PopBarDesign

enum StartupKind: String, Equatable, Hashable {
    case loginItem
    case launchAgent
    case launchDaemon
    case appLoginHelper
    case appAgent
    case appDaemon

    var title: String {
        switch self {
        case .loginItem: return L10n.t("登录项", "Login Item")
        case .launchAgent: return "LaunchAgent"
        case .launchDaemon: return "LaunchDaemon"
        case .appLoginHelper: return L10n.t("应用后台助手", "App Helper")
        case .appAgent: return L10n.t("应用后台代理", "App Agent")
        case .appDaemon: return L10n.t("应用守护进程", "App Daemon")
        }
    }

    /// 仅「登录时打开」的主应用归入登录项；应用内嵌 LoginItems Helper 在 macOS 13+ 归属「App 后台活动」
    var isService: Bool { self != .loginItem }
}

enum StartupToggleResult: Equatable {
    /// 操作成功；`immediate` 表示立即生效（登录项），`false` 表示重新登录/重启生效（LaunchAgent / LaunchDaemon）
    case success(immediate: Bool)
    /// 该项由 macOS 系统设置（BTM）管辖，第三方应用无法直接开关，需前往系统设置
    case managedBySystemSettings
    /// 用户尚未授予 PopBar 控制「系统事件（System Events）」的自动化权限
    case permissionDenied
    /// 用户取消了系统管理员密码授权
    case cancelled
    /// 其它执行错误
    case failure(String)
}

enum StartupTrigger: Equatable, Hashable {
    case atLogin
    case scheduled
    case onDemand
    case unknown

    var title: String {
        switch self {
        case .atLogin: return L10n.t("登录启动", "At Login")
        case .scheduled: return L10n.t("定时运行", "Scheduled")
        case .onDemand: return L10n.t("按需触发", "On Demand")
        case .unknown: return ""
        }
    }
}

/// 登录项与后台服务（登录项 / 应用内嵌服务 / LaunchAgent / LaunchDaemon）。
/// 登录项（登录时打开）支持直接添加/移除（System Events 或本应用 SMAppService）；
/// 传统 LaunchAgent（免密）与系统级 LaunchDaemon（管理员提权）使用 `launchctl enable/disable` 开关，不改写第三方 plist；
/// macOS 13+ 系统设置（BTM）管辖的应用内嵌服务或已禁用项展示真实状态并可直达系统设置。
struct StartupItem: Identifiable, Equatable {
    let id: String
    let label: String
    let displayName: String
    let kind: StartupKind
    let path: String
    var enabled: Bool
    var btmDisallowed: Bool
    let systemLevel: Bool
    var managedBySystemSettings: Bool
    let targetsBackgroundSession: Bool
    let program: String?
    let sourceAppName: String?
    let sourceAppPath: String?
    let developerName: String?
    let trigger: StartupTrigger
    var runningPID: Int?
    /// 指向的程序或脚本已不存在（且没有关联的已安装应用）
    let broken: Bool
    /// BTM 父应用/开发者标识（不含 Unknown Developer），用于与 macOS「App 后台活动」按归属合并展示
    let btmParentID: String?
    /// BTM 父应用/开发者友好名称（如 Cursor / Docker / Ollama / UU远程）
    let btmParentName: String?

    init(
        id: String,
        label: String,
        displayName: String,
        kind: StartupKind,
        path: String,
        enabled: Bool,
        btmDisallowed: Bool,
        systemLevel: Bool,
        managedBySystemSettings: Bool,
        targetsBackgroundSession: Bool,
        program: String?,
        sourceAppName: String?,
        sourceAppPath: String?,
        developerName: String?,
        trigger: StartupTrigger,
        runningPID: Int?,
        broken: Bool,
        btmParentID: String? = nil,
        btmParentName: String? = nil
    ) {
        self.id = id
        self.label = label
        self.displayName = displayName
        self.kind = kind
        self.path = path
        self.enabled = enabled
        self.btmDisallowed = btmDisallowed
        self.systemLevel = systemLevel
        self.managedBySystemSettings = managedBySystemSettings
        self.targetsBackgroundSession = targetsBackgroundSession
        self.program = program
        self.sourceAppName = sourceAppName
        self.sourceAppPath = sourceAppPath
        self.developerName = developerName
        self.trigger = trigger
        self.runningPID = runningPID
        self.broken = broken
        self.btmParentID = btmParentID
        self.btmParentName = btmParentName
    }

    /// 结合 launchctl 覆盖表与 BTM 禁止状态的最终生效状态
    var effectiveEnabled: Bool { enabled && !btmDisallowed }

    /// 系统级传统 LaunchDaemon 通过管理员提权调用 `launchctl enable/disable system/<label>` 开关
    var requiresAdminToggle: Bool {
        systemLevel && kind == .launchDaemon && !managedBySystemSettings && !btmDisallowed && !broken
    }

    /// 是否允许直接在 PopBar 内切换（用户登录项 / 本应用登录项 / 传统 LaunchAgent / 可提权的 LaunchDaemon）
    var canToggle: Bool {
        !managedBySystemSettings && !btmDisallowed && !broken && (!systemLevel || kind == .launchAgent || requiresAdminToggle)
    }

    /// 是否允许作为损坏的用户级传统代理移入废纸篓
    var canRemoveBroken: Bool { broken && !systemLevel && !managedBySystemSettings && kind == .launchAgent }
}

/// 按 macOS「登录项与扩展」口径归并后的展示组：
/// - 登录项：每项独立
/// - 有已知应用/开发者归属的后台服务：按 BTM `Parent Identifier` 聚合为 1 组（可展开查看明细）
/// - 身份不明开发者（Unknown Developer）的传统服务：每项独立
struct StartupGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [StartupItem]

    var primaryItem: StartupItem { items[0] }
    var isLoginItem: Bool { primaryItem.kind == .loginItem }
    var isService: Bool { !isLoginItem }
    var isExpandable: Bool { items.count > 1 }
    var systemItemCount: Int { items.filter(\.systemLevel).count }
    var effectiveEnabled: Bool { items.contains(where: \.effectiveEnabled) }
    var allBtmDisallowed: Bool { !items.isEmpty && items.allSatisfy(\.btmDisallowed) }
    var anyBtmDisallowed: Bool { items.contains(where: \.btmDisallowed) }
    var anyRunning: Bool { items.contains { $0.runningPID != nil } }
    var anyBroken: Bool { items.contains(where: \.broken) }
    var canToggleGroup: Bool { !items.isEmpty && items.allSatisfy(\.canToggle) }
    var requiresAdmin: Bool { items.contains(where: \.requiresAdminToggle) }
    var needsSystemSettings: Bool { !canToggleGroup && items.contains { $0.managedBySystemSettings || $0.btmDisallowed } }
    var iconAppPath: String? {
        items.compactMap(\.sourceAppPath).first { FileManager.default.fileExists(atPath: $0) }
    }
}

struct BTMRecord: Equatable {
    enum RecordType: String, Equatable {
        case app
        case developer
        case loginItem
        case agent
        case daemon
        case legacyAgent
        case legacyDaemon
        case other
    }

    let uid: Int32
    let name: String?
    let developerName: String?
    let type: RecordType
    let isEnabled: Bool
    let isDisallowed: Bool
    let identifier: String
    let strippedIdentifier: String
    let urlPath: String?
    let executablePath: String?
    let parentIdentifier: String?
    let associatedBundleIDs: [String]
}

struct BTMSnapshot: Equatable {
    struct ParentApp: Equatable {
        let name: String?
        let path: String
    }

    let records: [BTMRecord]
    /// `identifier` -> `.app` 路径（用于解析相对 `Contents/Library/...` 路径与来源 App）
    let parentApps: [String: ParentApp]
    /// `developer identifier` -> 开发者展示名称（排除 Unknown Developer）
    let parentDevelopers: [String: String]
}

enum StartupItems {
    struct Plist: Equatable {
        var label: String
        var program: String?
        var scriptPath: String?
        var associatedBundleIDs: [String]
        var disabledInPlist: Bool
        var trigger: StartupTrigger
        var targetsBackgroundSession: Bool
    }

    private static let interpreterNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "python", "python3", "ruby", "perl", "osascript", "node"
    ]

    /// 解析 plist；空 plist 或既无 `Program` / `ProgramArguments` 也无 `BundleProgram` 的无效占位文件返回 nil。
    static func parse(_ path: String) -> Plist? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return nil }

        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let label = (dict["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? file

        let explicitProgram = dict["Program"] as? String
        let args = (dict["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        let bundleProgram = dict["BundleProgram"] as? String

        let rawProgram = explicitProgram ?? args.first ?? bundleProgram
        guard let rawProgram, !rawProgram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let workingDir = dict["WorkingDirectory"] as? String
        let program = resolveExecutablePath(rawProgram, workingDirectory: workingDir, plistPath: path)
        let scriptPath = resolveScriptPath(executable: program ?? rawProgram, args: args, workingDirectory: workingDir)

        var assoc: [String] = []
        if let s = dict["AssociatedBundleIdentifiers"] as? String { assoc = [s] }
        if let a = dict["AssociatedBundleIdentifiers"] as? [String] { assoc = a }

        let runAtLoad = dict["RunAtLoad"] as? Bool
        let keepAliveBool = dict["KeepAlive"] as? Bool
        let keepAliveDict = dict["KeepAlive"] as? [String: Any]
        let hasKeepAlive = (keepAliveBool == true) || (keepAliveDict != nil && !(keepAliveDict?.isEmpty ?? true))
        let hasSchedule = dict["StartInterval"] != nil || dict["StartCalendarInterval"] != nil
        let hasOnDemandPort = dict["MachServices"] != nil || dict["Sockets"] != nil

        let trigger: StartupTrigger = {
            if runAtLoad == true || hasKeepAlive { return .atLogin }
            if hasSchedule { return .scheduled }
            if runAtLoad == false || keepAliveBool == false || hasOnDemandPort { return .onDemand }
            return .unknown
        }()

        let sessionTypes: [String] = {
            if let s = dict["LimitLoadToSessionType"] as? String { return [s] }
            if let a = dict["LimitLoadToSessionType"] as? [String] { return a }
            return []
        }()
        let targetsBackground = !sessionTypes.isEmpty && sessionTypes.contains("Background") && !sessionTypes.contains("Aqua")

        return Plist(
            label: label,
            program: program,
            scriptPath: scriptPath,
            associatedBundleIDs: assoc,
            disabledInPlist: (dict["Disabled"] as? Bool) ?? false,
            trigger: trigger,
            targetsBackgroundSession: targetsBackground
        )
    }

    private static func resolveExecutablePath(_ raw: String, workingDirectory: String?, plistPath: String) -> String? {
        var full = (raw as NSString).expandingTildeInPath
        if !full.hasPrefix("/") {
            if let wd = workingDirectory, !wd.isEmpty {
                full = ((wd as NSString).expandingTildeInPath as NSString).appendingPathComponent(full)
            } else if let appRoot = enclosingAppBundlePath(from: plistPath) {
                // 处理 BundleProgram 相对路径（如 Contents/MacOS/Helper）
                let candidate = (appRoot as NSString).appendingPathComponent(full)
                if candidate.hasPrefix("/") { full = candidate }
            }
        }
        return full.hasPrefix("/") ? (full as NSString).standardizingPath : nil
    }

    private static func resolveScriptPath(executable: String, args: [String], workingDirectory: String?) -> String? {
        let exeName = (executable as NSString).lastPathComponent.lowercased()
        guard interpreterNames.contains(exeName), args.count > 1 else { return nil }
        for arg in args.dropFirst() {
            if arg.hasPrefix("-") { continue }
            var candidate = (arg as NSString).expandingTildeInPath
            if !candidate.hasPrefix("/"), let wd = workingDirectory, !wd.isEmpty {
                candidate = ((wd as NSString).expandingTildeInPath as NSString).appendingPathComponent(candidate)
            }
            if candidate.hasPrefix("/") {
                return (candidate as NSString).standardizingPath
            }
            break
        }
        return nil
    }

    static func isBroken(_ p: Plist,
                         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                         isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) -> Bool {
        let missingProgram = p.program.map { !fileExists($0) } ?? false
        let missingScript = p.scriptPath.map { !fileExists($0) } ?? false
        guard missingProgram || missingScript else { return false }
        return !p.associatedBundleIDs.contains(where: isInstalled)
    }

    /// 解析 `launchctl print-disabled` 的输出：形如 `"com.foo.bar" => disabled`（兼容 `true`/`false`）。
    static func parseDisabled(_ output: String) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            guard !label.isEmpty else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            map[label] = value.hasPrefix("disabled") || value.hasPrefix("true")
        }
        return map
    }

    /// 解析 `launchctl list` 输出，提取正在运行的进程 PID（`label -> pid`）。
    static func parseRunningPIDs(_ output: String) -> [String: Int] {
        var map: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3, let pid = Int(cols[0].trimmingCharacters(in: .whitespaces)), pid > 0 else { continue }
            let label = String(cols[2]).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty { map[label] = pid }
        }
        return map
    }

    // MARK: - BTM（Background Task Management）解析与合并

    /// 解析 `sfltool dumpbtm` 文本输出，提取 `-2`（系统级）与当前用户记录，并补全相对父路径。
    static func parseBTM(_ output: String, uid: uid_t = getuid()) -> BTMSnapshot {
        var currentUID: Int32?
        var rawEntries: [(uid: Int32, fields: [String: String])] = []
        var activeFields: [String: String]?

        func flushCurrent() {
            if let uidVal = currentUID, let fields = activeFields, !fields.isEmpty {
                rawEntries.append((uidVal, fields))
            }
            activeFields = nil
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Records for UID ") {
                flushCurrent()
                let rest = trimmed.dropFirst("Records for UID ".count)
                if let numStr = rest.split(separator: " ").first, let parsed = Int32(numStr) {
                    currentUID = parsed
                } else {
                    currentUID = nil
                }
                continue
            }

            // 顶层条目形如 " #1:"（单个空格前缀），区别于 "    #1: ..." 的 Embedded Item Identifiers 子项
            if line.hasPrefix(" #"), trimmed.hasSuffix(":") {
                let digits = trimmed.dropFirst().dropLast()
                if !digits.isEmpty && digits.allSatisfy(\.isNumber) {
                    flushCurrent()
                    activeFields = [:]
                    continue
                }
            }

            guard activeFields != nil else { continue }
            // 仅读取顶层字段（缩进中的冒号键值对；跳过 4 空格缩进的 Embedded Item 子项）
            if line.hasPrefix("    #") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let valRaw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            activeFields?[key] = (valRaw == "(null)") ? "" : valRaw
        }
        flushCurrent()

        let targetUID = Int32(uid)
        var records: [BTMRecord] = []
        var parentApps: [String: BTMSnapshot.ParentApp] = [:]
        var parentDevelopers: [String: String] = [:]

        for entry in rawEntries where entry.uid == -2 || entry.uid == targetUID {
            let f = entry.fields
            let identifier = f["Identifier"] ?? ""
            guard !identifier.isEmpty else { continue }

            let typeStr = (f["Type"] ?? "").lowercased()
            let rtype: BTMRecord.RecordType = {
                if typeStr.hasPrefix("app ") || typeStr == "app" { return .app }
                if typeStr.hasPrefix("developer ") || typeStr == "developer" { return .developer }
                if typeStr.hasPrefix("login item") { return .loginItem }
                if typeStr.hasPrefix("legacy agent") { return .legacyAgent }
                if typeStr.hasPrefix("legacy daemon") { return .legacyDaemon }
                if typeStr.hasPrefix("agent ") || typeStr == "agent" { return .agent }
                if typeStr.hasPrefix("daemon ") || typeStr == "daemon" { return .daemon }
                return .other
            }()
            guard rtype != .other else { continue }

            let disp = (f["Disposition"] ?? "").lowercased()
            let dispTokens = parseDispositionTokens(disp)
            let isEnabled = dispTokens.contains("enabled") && !dispTokens.contains("disabled")
            let isDisallowed = dispTokens.contains("disallowed")

            let name = nonEmpty(f["Name"])
            let devName = nonEmpty(f["Developer Name"])
            let urlPath = normalizeBTMURL(nonEmpty(f["URL"]))
            let execPath = nonEmpty(f["Executable Path"])
            let parentID = nonEmpty(f["Parent Identifier"])
            let assocBundleIDs = parseBracketList(f["Assoc. Bundle IDs"])
            let stripped = stripIdentifierPrefix(identifier)

            if rtype == .developer {
                if identifier.caseInsensitiveCompare("Unknown Developer") != .orderedSame {
                    parentDevelopers[identifier] = name ?? devName ?? identifier
                }
                continue
            }

            let record = BTMRecord(
                uid: entry.uid,
                name: name,
                developerName: devName,
                type: rtype,
                isEnabled: isEnabled,
                isDisallowed: isDisallowed,
                identifier: identifier,
                strippedIdentifier: stripped,
                urlPath: urlPath,
                executablePath: execPath,
                parentIdentifier: parentID,
                associatedBundleIDs: assocBundleIDs
            )
            records.append(record)

            if rtype == .app, let appPath = urlPath, appPath.hasPrefix("/") {
                let cleanApp = (appPath as NSString).standardizingPath
                let existing = parentApps[identifier]
                parentApps[identifier] = BTMSnapshot.ParentApp(name: name ?? existing?.name, path: cleanApp)
            }
        }

        // 二次遍历：把相对 URL（如 Contents/Library/LaunchAgents/...）解析为完整绝对路径
        let resolvedRecords = records.map { rec -> BTMRecord in
            guard let urlPath = rec.urlPath, !urlPath.hasPrefix("/"),
                  let pid = rec.parentIdentifier, let parent = parentApps[pid]
            else { return rec }
            let joined = ((parent.path as NSString).appendingPathComponent(urlPath) as NSString).standardizingPath
            return BTMRecord(
                uid: rec.uid,
                name: rec.name,
                developerName: rec.developerName,
                type: rec.type,
                isEnabled: rec.isEnabled,
                isDisallowed: rec.isDisallowed,
                identifier: rec.identifier,
                strippedIdentifier: rec.strippedIdentifier,
                urlPath: joined,
                executablePath: rec.executablePath,
                parentIdentifier: rec.parentIdentifier,
                associatedBundleIDs: rec.associatedBundleIDs
            )
        }

        return BTMSnapshot(records: resolvedRecords, parentApps: parentApps, parentDevelopers: parentDevelopers)
    }

    private static func parseBracketList(_ raw: String?) -> [String] {
        guard let raw, let l = raw.firstIndex(of: "["), let r = raw.firstIndex(of: "]"), l < r else { return [] }
        return raw[raw.index(after: l)..<r]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parseDispositionTokens(_ raw: String) -> Set<String> {
        guard let l = raw.firstIndex(of: "["), let r = raw.firstIndex(of: "]"), l < r else { return [] }
        let inside = raw[raw.index(after: l)..<r]
        let tokens = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return Set(tokens)
    }

    private static func stripIdentifierPrefix(_ id: String) -> String {
        guard let dot = id.firstIndex(of: ".") else { return id }
        let prefix = id[..<dot]
        if !prefix.isEmpty && prefix.allSatisfy(\.isNumber) {
            return String(id[id.index(after: dot)...])
        }
        return id
    }

    private static func normalizeBTMURL(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            return (url.path as NSString).standardizingPath
        }
        return raw.removingPercentEncoding ?? raw
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    // MARK: - 两阶段扫描（Stage 1 极速扫描 + Stage 2 BTM 同步）

    /// Stage 1：扫描传统 LaunchAgent/LaunchDaemon 目录、launchctl 覆盖表与当前运行 PID，并包含本应用自身登录项。
    static func scanFast() -> [StartupItem] {
        let uid = getuid()
        let guiOverrides = parseDisabled(ShellRun.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"], timeout: 10).out)
        let userOverrides = parseDisabled(ShellRun.run("/bin/launchctl", ["print-disabled", "user/\(uid)"], timeout: 10).out)
        let systemOverrides = parseDisabled(ShellRun.run("/bin/launchctl", ["print-disabled", "system"], timeout: 10).out)
        let runningPIDs = parseRunningPIDs(ShellRun.run("/bin/launchctl", ["list"], timeout: 10).out)

        let dirs: [(path: String, kind: StartupKind, system: Bool)] = [
            ("~/Library/LaunchAgents", .launchAgent, false),
            ("/Library/LaunchAgents", .launchAgent, true),
            ("/Library/LaunchDaemons", .launchDaemon, true),
        ]

        var out: [StartupItem] = []
        for d in dirs {
            let base = (d.path as NSString).expandingTildeInPath
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            for name in files where name.hasSuffix(".plist") {
                let full = ((base + "/" + name) as NSString).standardizingPath
                guard let info = parse(full) else { continue }

                let disabled: Bool = {
                    if d.kind == .launchDaemon {
                        return systemOverrides[info.label] ?? info.disabledInPlist
                    }
                    // /Library/LaunchAgents 同样运行在用户 gui/user 会话下，必须结合 gui/user 覆盖表
                    if info.targetsBackgroundSession {
                        return userOverrides[info.label] ?? guiOverrides[info.label] ?? info.disabledInPlist
                    }
                    return guiOverrides[info.label] ?? userOverrides[info.label] ?? info.disabledInPlist
                }()

                let appInfo = resolveSourceApp(bundleIDs: info.associatedBundleIDs, executablePath: info.program, plistPath: full)
                let broken = isBroken(info)
                out.append(StartupItem(
                    id: full,
                    label: info.label,
                    displayName: info.label,
                    kind: d.kind,
                    path: full,
                    enabled: !disabled,
                    btmDisallowed: false,
                    systemLevel: d.system,
                    managedBySystemSettings: false,
                    targetsBackgroundSession: info.targetsBackgroundSession,
                    program: info.program,
                    sourceAppName: appInfo.name,
                    sourceAppPath: appInfo.path,
                    developerName: nil,
                    trigger: info.trigger,
                    runningPID: runningPIDs[info.label],
                    broken: broken
                ))
            }
        }

        // 若当前应用已通过 SMAppService.mainApp 开启登录自启，在 Stage 1 立即补充（Stage 2 BTM 合并时按路径去重）
        if SMAppService.mainApp.status == .enabled,
           let bundleID = Bundle.main.bundleIdentifier {
            let appPath = normalizedLoginItemPath(Bundle.main.bundlePath)
            let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? "PopBar"
            out.append(StartupItem(
                id: "btm:login:\(bundleID)",
                label: bundleID,
                displayName: appName,
                kind: .loginItem,
                path: appPath,
                enabled: true,
                btmDisallowed: false,
                systemLevel: false,
                managedBySystemSettings: false,
                targetsBackgroundSession: false,
                program: Bundle.main.executablePath,
                sourceAppName: appName,
                sourceAppPath: appPath,
                developerName: nil,
                trigger: .atLogin,
                runningPID: nil,
                broken: false
            ))
        }

        return sortItems(out)
    }

    /// Stage 2：运行 `sfltool dumpbtm` 获取系统真实 BTM 允许状态、登录项及应用内嵌服务。
    /// 该命令在系统级 XPC 上通常耗时 5–25 秒；超时或失败返回 nil 以便静默降级。
    static func scanBTM() -> BTMSnapshot? {
        let r = ShellRun.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 35)
        guard r.status == 0, !r.out.isEmpty else { return nil }
        return parseBTM(r.out)
    }

    /// 将 `BTMSnapshot` 合并进 `scanFast()` 结果：
    /// 1) 修正已有 plist 项的 `btmDisallowed` 与来源元数据；
    /// 2) 补齐登录项（app / login item）及应用内嵌后台服务（SMAppService agent / daemon）。
    static func mergeBTM(_ baseItems: [StartupItem],
                         _ btm: BTMSnapshot,
                         runningPIDs: [String: Int] = [:],
                         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                         isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) -> [StartupItem] {
        // 同一项可能同时出现在 UID -2 与当前 UID，后者优先级更高
        var orderedRecords: [BTMRecord] = []
        var seenKey: [String: Int] = [:]
        for rec in btm.records {
            let key = "\(rec.type.rawValue):\(rec.strippedIdentifier):\(rec.urlPath ?? "")"
            if let idx = seenKey[key] {
                if rec.uid != -2 { orderedRecords[idx] = rec }
            } else {
                seenKey[key] = orderedRecords.count
                orderedRecords.append(rec)
            }
        }

        var merged = baseItems
        var matchedPaths = Set<String>()
        var matchedLabels = Set<String>()

        // 先匹配并修正已扫描到的传统 plist 项
        for i in merged.indices {
            let itemPath = (merged[i].path as NSString).standardizingPath
            if let rec = orderedRecords.first(where: { r in
                if let p = r.urlPath, (p as NSString).standardizingPath == itemPath { return true }
                return (r.type == .legacyAgent || r.type == .legacyDaemon) && r.strippedIdentifier == merged[i].label
            }) {
                let knownParent = resolveKnownParent(for: rec, in: btm)
                let assocApp = (merged[i].sourceAppPath == nil && !rec.associatedBundleIDs.isEmpty)
                    ? resolveSourceApp(bundleIDs: rec.associatedBundleIDs, executablePath: rec.executablePath, plistPath: merged[i].path)
                    : (name: nil, path: nil)
                let srcName = merged[i].sourceAppName ?? knownParent.appName ?? assocApp.name
                let srcPath = merged[i].sourceAppPath ?? knownParent.appPath ?? assocApp.path
                let dev = merged[i].developerName ?? rec.developerName
                let programPath = merged[i].program ?? rec.executablePath
                let friendlyDisplay: String = {
                    if knownParent.id == nil {
                        if let recName = rec.name, !recName.isEmpty, recName != merged[i].label { return recName }
                        if let prog = programPath, !prog.isEmpty {
                            let exe = (prog as NSString).lastPathComponent
                            if !exe.isEmpty { return exe }
                        }
                    }
                    return merged[i].displayName
                }()
                merged[i] = StartupItem(
                    id: merged[i].id,
                    label: merged[i].label,
                    displayName: friendlyDisplay,
                    kind: merged[i].kind,
                    path: merged[i].path,
                    enabled: merged[i].enabled,
                    btmDisallowed: rec.isDisallowed,
                    systemLevel: merged[i].systemLevel,
                    managedBySystemSettings: merged[i].managedBySystemSettings,
                    targetsBackgroundSession: merged[i].targetsBackgroundSession,
                    program: programPath,
                    sourceAppName: srcName,
                    sourceAppPath: srcPath,
                    developerName: dev,
                    trigger: merged[i].trigger,
                    runningPID: merged[i].runningPID ?? runningPIDs[merged[i].label],
                    broken: merged[i].broken,
                    btmParentID: knownParent.id,
                    btmParentName: knownParent.name
                )
                if let p = rec.urlPath { matchedPaths.insert((p as NSString).standardizingPath) }
                matchedLabels.insert(rec.strippedIdentifier)
            }
        }

        // 再追加现代登录项与应用内嵌后台服务
        var seenAdded = Set(merged.map { ($0.path as NSString).standardizingPath })
        var seenLabels = Set(merged.map(\.label))

        for rec in orderedRecords {
            let normPath = rec.urlPath.map { ($0 as NSString).standardizingPath } ?? ""
            if !normPath.isEmpty && (matchedPaths.contains(normPath) || seenAdded.contains(normPath)) { continue }
            if matchedLabels.contains(rec.strippedIdentifier) || seenLabels.contains(rec.strippedIdentifier) { continue }

            switch rec.type {
            case .app:
                guard rec.isEnabled, !normPath.isEmpty else { continue }
                let cleanPath = normalizedLoginItemPath(normPath)
                let appName = rec.name ?? ((cleanPath as NSString).lastPathComponent as NSString).deletingPathExtension
                let broken = !fileExists(cleanPath)
                merged.append(StartupItem(
                    id: "btm:app:\(rec.strippedIdentifier):\(cleanPath)",
                    label: rec.strippedIdentifier,
                    displayName: appName,
                    kind: .loginItem,
                    path: cleanPath,
                    enabled: true,
                    btmDisallowed: rec.isDisallowed,
                    systemLevel: false,
                    managedBySystemSettings: false,
                    targetsBackgroundSession: false,
                    program: rec.executablePath,
                    sourceAppName: appName,
                    sourceAppPath: fileExists(cleanPath) ? cleanPath : nil,
                    developerName: rec.developerName,
                    trigger: .atLogin,
                    runningPID: nil,
                    broken: broken
                ))
                seenAdded.insert(cleanPath)
                seenLabels.insert(rec.strippedIdentifier)

            case .loginItem:
                // BTM 的 `Type: login item (0x4)` 是应用内嵌的 Contents/Library/LoginItems/*.app 辅助程序，
                // 在 macOS 13+ 系统设置中归属于「App 后台活动」而非「登录时打开」，因此归入后台服务分类。
                let knownParent = resolveKnownParent(for: rec, in: btm)
                let display = rec.name ?? rec.strippedIdentifier
                let itemPath = !normPath.isEmpty ? normPath : (knownParent.appPath ?? "")
                let broken = !normPath.isEmpty && !fileExists(normPath) && !(knownParent.appPath.map { fileExists($0) } ?? false)
                merged.append(StartupItem(
                    id: "btm:loginItem:\(rec.strippedIdentifier)",
                    label: rec.strippedIdentifier,
                    displayName: display,
                    kind: .appLoginHelper,
                    path: itemPath,
                    enabled: rec.isEnabled,
                    btmDisallowed: rec.isDisallowed,
                    systemLevel: false,
                    managedBySystemSettings: true,
                    targetsBackgroundSession: false,
                    program: rec.executablePath ?? (!normPath.isEmpty ? normPath : nil),
                    sourceAppName: knownParent.appName ?? appDisplayName(from: knownParent.appPath),
                    sourceAppPath: knownParent.appPath,
                    developerName: rec.developerName,
                    trigger: .atLogin,
                    runningPID: nil,
                    broken: broken,
                    btmParentID: knownParent.id,
                    btmParentName: knownParent.name
                ))
                if !normPath.isEmpty { seenAdded.insert(normPath) }
                seenLabels.insert(rec.strippedIdentifier)

            case .agent, .daemon:
                let knownParent = resolveKnownParent(for: rec, in: btm)
                let isDaemon = (rec.type == .daemon) || (rec.uid == -2)
                let plistInfo: Plist? = (!normPath.isEmpty && fileExists(normPath)) ? parse(normPath) : nil
                let itemLabel = plistInfo?.label ?? rec.strippedIdentifier
                let appName = knownParent.appName ?? appDisplayName(from: knownParent.appPath)
                // 对内嵌后台服务优先使用父应用名（避免 Ollama 显示成内部更新器名 Squirrel 或 true）
                let display = appName ?? rec.name.flatMap { $0 == "true" || $0 == "false" ? nil : $0 } ?? itemLabel
                let broken = plistInfo.map { isBroken($0, fileExists: fileExists, isInstalled: isInstalled) } ?? false
                merged.append(StartupItem(
                    id: !normPath.isEmpty ? normPath : "btm:\(rec.type.rawValue):\(itemLabel)",
                    label: itemLabel,
                    displayName: display,
                    kind: rec.type == .daemon ? .appDaemon : .appAgent,
                    path: !normPath.isEmpty ? normPath : (knownParent.appPath ?? ""),
                    enabled: rec.isEnabled,
                    btmDisallowed: rec.isDisallowed,
                    systemLevel: isDaemon,
                    managedBySystemSettings: true,
                    targetsBackgroundSession: plistInfo?.targetsBackgroundSession ?? false,
                    program: plistInfo?.program ?? rec.executablePath,
                    sourceAppName: appName,
                    sourceAppPath: knownParent.appPath,
                    developerName: rec.developerName,
                    trigger: plistInfo?.trigger ?? .atLogin,
                    runningPID: runningPIDs[itemLabel],
                    broken: broken,
                    btmParentID: knownParent.id,
                    btmParentName: knownParent.name ?? appName
                ))
                if !normPath.isEmpty { seenAdded.insert(normPath) }
                seenLabels.insert(itemLabel)

            case .developer, .legacyAgent, .legacyDaemon, .other:
                continue
            }
        }

        return sortItems(merged)
    }

    private static func resolveKnownParent(for rec: BTMRecord, in btm: BTMSnapshot) -> (id: String?, name: String?, appName: String?, appPath: String?) {
        guard let pid = rec.parentIdentifier,
              !pid.isEmpty,
              pid.caseInsensitiveCompare("Unknown Developer") != .orderedSame
        else { return (nil, nil, nil, nil) }

        if let app = btm.parentApps[pid] {
            let resolvedName = app.name ?? appDisplayName(from: app.path) ?? rec.name
            return (pid, resolvedName, resolvedName, app.path)
        }
        if let devName = btm.parentDevelopers[pid] {
            return (pid, devName, nil, nil)
        }
        let fallbackName = rec.developerName ?? rec.name ?? stripIdentifierPrefix(pid)
        return (pid, fallbackName, nil, nil)
    }

    /// 按 macOS「登录项与扩展」口径将平铺条目聚合成组，使后台服务数量与系统设置一一对应。
    static func groupItems(_ items: [StartupItem]) -> [StartupGroup] {
        var bucketOrder: [String] = []
        var buckets: [String: [StartupItem]] = [:]

        for item in items {
            let key: String = {
                if item.kind == .loginItem { return item.id }
                if let pid = item.btmParentID, !pid.isEmpty { return "group:\(pid)" }
                return item.id
            }()
            if buckets[key] == nil { bucketOrder.append(key) }
            buckets[key, default: []].append(item)
        }

        let groups = bucketOrder.compactMap { key -> StartupGroup? in
            guard let rawList = buckets[key], !rawList.isEmpty else { return nil }
            let sortedChildren = sortItems(rawList)
            let first = sortedChildren[0]
            let title: String = {
                if first.kind == .loginItem { return first.displayName }
                if let parentName = sortedChildren.compactMap(\.btmParentName).first(where: { !$0.isEmpty }) {
                    return parentName
                }
                if first.btmParentID != nil, let src = sortedChildren.compactMap(\.sourceAppName).first(where: { !$0.isEmpty }) {
                    return src
                }
                return first.displayName
            }()
            return StartupGroup(id: key, title: title, items: sortedChildren)
        }

        return groups.sorted { a, b in
            let cmp = a.title.localizedCaseInsensitiveCompare(b.title)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            if a.items.count != b.items.count { return a.items.count < b.items.count }
            return a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
        }
    }

    static func scan() -> [StartupItem] {
        let base = scanFast()
        guard let btm = scanBTM() else { return base }
        let running = parseRunningPIDs(ShellRun.run("/bin/launchctl", ["list"], timeout: 10).out)
        return mergeBTM(base, btm, runningPIDs: running)
    }

    static func setEnabled(_ item: StartupItem, _ enabled: Bool) -> Bool {
        if case .success = setEnabledResult(item, enabled) { return true }
        return false
    }

    static func setEnabledResult(_ item: StartupItem, _ enabled: Bool,
                                 currentBundleID: String? = Bundle.main.bundleIdentifier,
                                 currentBundlePath: String = Bundle.main.bundlePath) -> StartupToggleResult {
        guard !item.managedBySystemSettings, !item.btmDisallowed else {
            return .managedBySystemSettings
        }
        if item.kind == .loginItem {
            if isSelfApp(label: item.label, path: item.path, currentBundleID: currentBundleID, currentBundlePath: currentBundlePath) {
                return setSelfLoginItemEnabled(enabled)
            }
            return enabled ? addLoginItem(at: item.path) : removeLoginItem(at: item.path)
        }
        let action = enabled ? "enable" : "disable"
        if item.requiresAdminToggle {
            guard isSafeLaunchdLabel(item.label) else {
                return .failure(L10n.t("无效的服务标识", "Invalid service label"))
            }
            let prompt = enabled
                ? L10n.t("PopBar 需要管理员权限以启用系统服务 \(item.label)", "PopBar needs administrator permission to enable \(item.label)")
                : L10n.t("PopBar 需要管理员权限以停用系统服务 \(item.label)", "PopBar needs administrator permission to disable \(item.label)")
            switch ShellRun.runAsAdminResult("/bin/launchctl \(action) system/\(item.label)", prompt: prompt, timeout: 120) {
            case .success:
                return .success(immediate: false)
            case .cancelled:
                return .cancelled
            case .failure(let msg):
                return .failure(msg)
            }
        }
        guard !item.systemLevel || item.kind == .launchAgent else {
            return .managedBySystemSettings
        }
        let domain = item.targetsBackgroundSession ? "user/\(getuid())" : "gui/\(getuid())"
        let r = ShellRun.run("/bin/launchctl", [action, "\(domain)/\(item.label)"], timeout: 10)
        if r.status == 0 { return .success(immediate: false) }
        let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(msg.isEmpty ? L10n.t("launchctl 执行失败", "launchctl failed") : msg)
    }

    /// 校验 launchd 服务标识字符集（仅允许字母、数字及 `. _ @ -`），防止提权命令拼接注入。
    static func isSafeLaunchdLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 255 else { return false }
        return label.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) // 0-9
            || (scalar.value >= 65 && scalar.value <= 90) // A-Z
            || (scalar.value >= 97 && scalar.value <= 122) // a-z
            || scalar == "." || scalar == "_" || scalar == "-" || scalar == "@"
        }
    }

    /// 将指定应用路径加入 macOS「登录时打开」列表（路径通过 argv 传给 System Events，避免脚本注入）。
    static func addLoginItem(at path: String,
                             currentBundleID: String? = Bundle.main.bundleIdentifier,
                             currentBundlePath: String = Bundle.main.bundlePath) -> StartupToggleResult {
        let target = normalizedLoginItemPath(path)
        guard !target.isEmpty, FileManager.default.fileExists(atPath: target) else {
            return .failure(L10n.t("应用路径不存在", "Application path does not exist"))
        }
        if normalizedLoginItemPath(currentBundlePath) == target {
            return setSelfLoginItemEnabled(true)
        }
        let script = """
        on run argv
            set targetPath to item 1 of argv
            tell application "System Events"
                repeat with li in every login item
                    set p to path of li
                    if p ends with "/" and length of p > 1 then set p to text 1 thru -2 of p
                    if p is targetPath then return "exists"
                end repeat
                make login item at end with properties {path:targetPath, hidden:false}
            end tell
            return "added"
        end run
        """
        let r = ShellRun.run("/usr/bin/osascript", ["-e", script, target], timeout: 20)
        if r.status == 0 { return .success(immediate: true) }
        if isAutomationPermissionDenied(r.err) { return .permissionDenied }
        let cleaned = ShellRun.cleanAdminError(r.err)
        return .failure(cleaned.isEmpty ? L10n.t("添加登录项失败", "Failed to add login item") : cleaned)
    }

    /// 从 macOS「登录时打开」列表移除指定路径的登录项；若不在 System Events 列表中则说明由第三方 SMAppService 管理。
    static func removeLoginItem(at path: String) -> StartupToggleResult {
        let target = normalizedLoginItemPath(path)
        guard !target.isEmpty else {
            return .failure(L10n.t("无效的应用路径", "Invalid application path"))
        }
        let script = """
        on run argv
            set targetPath to item 1 of argv
            set removedCount to 0
            tell application "System Events"
                set itemsList to every login item
                repeat with i from (count of itemsList) to 1 by -1
                    set li to item i of itemsList
                    set p to path of li
                    if p ends with "/" and length of p > 1 then set p to text 1 thru -2 of p
                    if p is targetPath then
                        delete li
                        set removedCount to removedCount + 1
                    end if
                end repeat
            end tell
            return removedCount as string
        end run
        """
        let r = ShellRun.run("/usr/bin/osascript", ["-e", script, target], timeout: 20)
        if r.status == 0 {
            let removed = Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return removed > 0 ? .success(immediate: true) : .managedBySystemSettings
        }
        if isAutomationPermissionDenied(r.err) { return .permissionDenied }
        let cleaned = ShellRun.cleanAdminError(r.err)
        return .failure(cleaned.isEmpty ? L10n.t("移除登录项失败", "Failed to remove login item") : cleaned)
    }

    static func makeLoginItem(from url: URL) -> StartupItem {
        let cleanPath = normalizedLoginItemPath(url.path)
        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier ?? cleanPath
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.displayName(atPath: cleanPath).replacingOccurrences(of: ".app", with: "")
        return StartupItem(
            id: "btm:app:\(bundleID):\(cleanPath)",
            label: bundleID,
            displayName: name,
            kind: .loginItem,
            path: cleanPath,
            enabled: true,
            btmDisallowed: false,
            systemLevel: false,
            managedBySystemSettings: false,
            targetsBackgroundSession: false,
            program: bundle?.executablePath,
            sourceAppName: name,
            sourceAppPath: cleanPath,
            developerName: nil,
            trigger: .atLogin,
            runningPID: nil,
            broken: !FileManager.default.fileExists(atPath: cleanPath)
        )
    }

    static func normalizedLoginItemPath(_ path: String) -> String {
        var norm = (path as NSString).standardizingPath
        while norm.count > 1 && norm.hasSuffix("/") {
            norm.removeLast()
        }
        return norm
    }

    static func isAutomationPermissionDenied(_ stderr: String) -> Bool {
        stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("Not authorized to send Apple events")
    }

    static func isSelfApp(label: String, path: String,
                          currentBundleID: String? = Bundle.main.bundleIdentifier,
                          currentBundlePath: String = Bundle.main.bundlePath) -> Bool {
        if let bid = currentBundleID, !bid.isEmpty, label == bid { return true }
        return !path.isEmpty && normalizedLoginItemPath(path) == normalizedLoginItemPath(currentBundlePath)
    }

    private static func setSelfLoginItemEnabled(_ enabled: Bool) -> StartupToggleResult {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(immediate: true)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// 清理损坏的传统用户级 LaunchAgent 前先从 launchd 会话中卸载（bootout），避免继续在内存中重试。
    static func bootout(_ item: StartupItem) {
        guard !item.systemLevel, !item.managedBySystemSettings else { return }
        let domain = item.targetsBackgroundSession ? "user/\(getuid())" : "gui/\(getuid())"
        _ = ShellRun.run("/bin/launchctl", ["bootout", "\(domain)/\(item.label)"], timeout: 10)
    }

    /// 将损坏的用户级启动代理 plist 移入废纸篓（可恢复）。
    static func trashFile(_ url: URL) -> Result<URL?, Error> {
        do {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return .success(result as URL?)
        } catch {
            return .failure(error)
        }
    }

    static func trashErrorReason(for error: Error) -> String {
        let e = error as NSError
        let denied = (e.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(e.code))
            || (e.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(e.code))
        return denied
            ? L10n.t("macOS 拒绝访问该文件", "macOS denied access to this file")
            : error.localizedDescription
    }

    // MARK: - 辅助

    static func sortItems(_ items: [StartupItem]) -> [StartupItem] {
        items.sorted {
            let lhs = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if lhs != .orderedSame { return lhs == .orderedAscending }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private static func resolveSourceApp(bundleIDs: [String], executablePath: String?, plistPath: String) -> (name: String?, path: String?) {
        for bid in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                let p = (url.path as NSString).standardizingPath
                return (appDisplayName(from: p), p)
            }
        }
        if let exec = executablePath, let appPath = enclosingAppBundlePath(from: exec) {
            return (appDisplayName(from: appPath), appPath)
        }
        if let appPath = enclosingAppBundlePath(from: plistPath) {
            return (appDisplayName(from: appPath), appPath)
        }
        return (nil, nil)
    }

    static func enclosingAppBundlePath(from path: String) -> String? {
        var current = (path as NSString).standardizingPath
        while current != "/" && !current.isEmpty {
            if current.hasSuffix(".app") { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func appDisplayName(from appPath: String?) -> String? {
        guard let appPath, !appPath.isEmpty else { return nil }
        let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.isEmpty ? nil : name
    }
}
