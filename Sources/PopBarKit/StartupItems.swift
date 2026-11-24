import Cocoa
import ServiceManagement
import PopBarCore
import PopBarPlatform
import PopBarDesign

enum StartupKind: String, Equatable, Hashable {
    case loginItem
    case launchAgent
    case launchDaemon
    case appAgent
    case appDaemon

    var title: String {
        switch self {
        case .loginItem: return L10n.t("登录项", "Login Item")
        case .launchAgent: return "LaunchAgent"
        case .launchDaemon: return "LaunchDaemon"
        case .appAgent: return L10n.t("应用后台代理", "App Agent")
        case .appDaemon: return L10n.t("应用守护进程", "App Daemon")
        }
    }

    var isService: Bool { self != .loginItem }
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
/// 用户级传统 LaunchAgent 使用 `launchctl enable/disable` 开关（重新登录生效），不改写第三方 plist；
/// 系统级及 macOS 13+ 系统设置管辖项（登录项 / 应用内嵌服务 / BTM 禁用项）展示真实状态并可直达系统设置。
struct StartupItem: Identifiable, Equatable {
    let id: String
    let label: String
    let displayName: String
    let kind: StartupKind
    let path: String
    var enabled: Bool
    var btmDisallowed: Bool
    let systemLevel: Bool
    let managedBySystemSettings: Bool
    let targetsBackgroundSession: Bool
    let program: String?
    let sourceAppName: String?
    let sourceAppPath: String?
    let developerName: String?
    let trigger: StartupTrigger
    var runningPID: Int?
    /// 指向的程序或脚本已不存在（且没有关联的已安装应用）
    let broken: Bool

    /// 结合 launchctl 覆盖表与 BTM 禁止状态的最终生效状态
    var effectiveEnabled: Bool { enabled && !btmDisallowed }

    /// 是否允许直接在 PopBar 内通过 launchctl 切换
    var canToggle: Bool { !systemLevel && !managedBySystemSettings && !btmDisallowed && !broken }

    /// 是否允许作为损坏的用户级传统代理移入废纸篓
    var canRemoveBroken: Bool { broken && !systemLevel && !managedBySystemSettings && kind == .launchAgent }
}

struct BTMRecord: Equatable {
    enum RecordType: String, Equatable {
        case app
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
}

struct BTMSnapshot: Equatable {
    struct ParentApp: Equatable {
        let name: String?
        let path: String
    }

    let records: [BTMRecord]
    /// `identifier` -> `.app` 路径（用于解析相对 `Contents/Library/...` 路径与来源 App）
    let parentApps: [String: ParentApp]
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

        for entry in rawEntries where entry.uid == -2 || entry.uid == targetUID {
            let f = entry.fields
            let identifier = f["Identifier"] ?? ""
            guard !identifier.isEmpty else { continue }

            let typeStr = (f["Type"] ?? "").lowercased()
            let rtype: BTMRecord.RecordType = {
                if typeStr.hasPrefix("app ") || typeStr == "app" { return .app }
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
            let stripped = stripIdentifierPrefix(identifier)

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
                parentIdentifier: parentID
            )
            records.append(record)

            if rtype == .app, let appPath = urlPath, appPath.hasPrefix("/") {
                let cleanApp = (appPath as NSString).standardizingPath
                parentApps[identifier] = BTMSnapshot.ParentApp(name: name, path: cleanApp)
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
                parentIdentifier: rec.parentIdentifier
            )
        }

        return BTMSnapshot(records: resolvedRecords, parentApps: parentApps)
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
            let appPath = (Bundle.main.bundlePath as NSString).standardizingPath
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
                managedBySystemSettings: true,
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
                merged[i].btmDisallowed = rec.isDisallowed
                if merged[i].developerName == nil {
                    let dev = rec.developerName
                    let srcName = merged[i].sourceAppName ?? rec.parentIdentifier.flatMap { btm.parentApps[$0]?.name }
                    let srcPath = merged[i].sourceAppPath ?? rec.parentIdentifier.flatMap { btm.parentApps[$0]?.path }
                    merged[i] = StartupItem(
                        id: merged[i].id,
                        label: merged[i].label,
                        displayName: merged[i].displayName,
                        kind: merged[i].kind,
                        path: merged[i].path,
                        enabled: merged[i].enabled,
                        btmDisallowed: rec.isDisallowed,
                        systemLevel: merged[i].systemLevel,
                        managedBySystemSettings: merged[i].managedBySystemSettings,
                        targetsBackgroundSession: merged[i].targetsBackgroundSession,
                        program: merged[i].program ?? rec.executablePath,
                        sourceAppName: srcName,
                        sourceAppPath: srcPath,
                        developerName: dev,
                        trigger: merged[i].trigger,
                        runningPID: merged[i].runningPID ?? runningPIDs[merged[i].label],
                        broken: merged[i].broken
                    )
                }
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
                let appName = rec.name ?? ((normPath as NSString).lastPathComponent as NSString).deletingPathExtension
                let broken = !fileExists(normPath)
                merged.append(StartupItem(
                    id: "btm:app:\(rec.strippedIdentifier):\(normPath)",
                    label: rec.strippedIdentifier,
                    displayName: appName,
                    kind: .loginItem,
                    path: normPath,
                    enabled: true,
                    btmDisallowed: rec.isDisallowed,
                    systemLevel: false,
                    managedBySystemSettings: true,
                    targetsBackgroundSession: false,
                    program: rec.executablePath,
                    sourceAppName: appName,
                    sourceAppPath: fileExists(normPath) ? normPath : nil,
                    developerName: rec.developerName,
                    trigger: .atLogin,
                    runningPID: nil,
                    broken: broken
                ))
                seenAdded.insert(normPath)
                seenLabels.insert(rec.strippedIdentifier)

            case .loginItem:
                let parent = rec.parentIdentifier.flatMap { btm.parentApps[$0] }
                let display = rec.name ?? rec.strippedIdentifier
                let itemPath = !normPath.isEmpty ? normPath : (parent?.path ?? "")
                let broken = !normPath.isEmpty && !fileExists(normPath) && !(parent.map { fileExists($0.path) } ?? false)
                merged.append(StartupItem(
                    id: "btm:loginItem:\(rec.strippedIdentifier)",
                    label: rec.strippedIdentifier,
                    displayName: display,
                    kind: .loginItem,
                    path: itemPath,
                    enabled: rec.isEnabled,
                    btmDisallowed: rec.isDisallowed,
                    systemLevel: false,
                    managedBySystemSettings: true,
                    targetsBackgroundSession: false,
                    program: rec.executablePath ?? (!normPath.isEmpty ? normPath : nil),
                    sourceAppName: parent?.name ?? appDisplayName(from: parent?.path),
                    sourceAppPath: parent?.path,
                    developerName: rec.developerName,
                    trigger: .atLogin,
                    runningPID: nil,
                    broken: broken
                ))
                if !normPath.isEmpty { seenAdded.insert(normPath) }
                seenLabels.insert(rec.strippedIdentifier)

            case .agent, .daemon:
                let parent = rec.parentIdentifier.flatMap { btm.parentApps[$0] }
                let isDaemon = (rec.type == .daemon) || (rec.uid == -2)
                let plistInfo: Plist? = (!normPath.isEmpty && fileExists(normPath)) ? parse(normPath) : nil
                let itemLabel = plistInfo?.label ?? rec.strippedIdentifier
                let appName = parent?.name ?? appDisplayName(from: parent?.path)
                let display = rec.name.flatMap { $0 == "true" || $0 == "false" ? nil : $0 } ?? appName ?? itemLabel
                let broken = plistInfo.map { isBroken($0, fileExists: fileExists, isInstalled: isInstalled) } ?? false
                merged.append(StartupItem(
                    id: !normPath.isEmpty ? normPath : "btm:\(rec.type.rawValue):\(itemLabel)",
                    label: itemLabel,
                    displayName: display,
                    kind: rec.type == .daemon ? .appDaemon : .appAgent,
                    path: !normPath.isEmpty ? normPath : (parent?.path ?? ""),
                    enabled: rec.isEnabled,
                    btmDisallowed: rec.isDisallowed,
                    systemLevel: isDaemon,
                    managedBySystemSettings: true,
                    targetsBackgroundSession: plistInfo?.targetsBackgroundSession ?? false,
                    program: plistInfo?.program ?? rec.executablePath,
                    sourceAppName: appName,
                    sourceAppPath: parent?.path,
                    developerName: rec.developerName,
                    trigger: plistInfo?.trigger ?? .atLogin,
                    runningPID: runningPIDs[itemLabel],
                    broken: broken
                ))
                if !normPath.isEmpty { seenAdded.insert(normPath) }
                seenLabels.insert(itemLabel)

            case .legacyAgent, .legacyDaemon, .other:
                continue
            }
        }

        return sortItems(merged)
    }

    static func scan() -> [StartupItem] {
        let base = scanFast()
        guard let btm = scanBTM() else { return base }
        let running = parseRunningPIDs(ShellRun.run("/bin/launchctl", ["list"], timeout: 10).out)
        return mergeBTM(base, btm, runningPIDs: running)
    }

    static func setEnabled(_ item: StartupItem, _ enabled: Bool) -> Bool {
        guard !item.systemLevel, !item.managedBySystemSettings, !item.btmDisallowed else { return false }
        let domain = item.targetsBackgroundSession ? "user/\(getuid())" : "gui/\(getuid())"
        let r = ShellRun.run("/bin/launchctl", [enabled ? "enable" : "disable", "\(domain)/\(item.label)"], timeout: 10)
        return r.status == 0
    }

    /// 清理损坏的传统用户级 LaunchAgent 前先从 launchd 会话中卸载（bootout），避免继续在内存中重试。
    static func bootout(_ item: StartupItem) {
        guard !item.systemLevel, !item.managedBySystemSettings else { return }
        let domain = item.targetsBackgroundSession ? "user/\(getuid())" : "gui/\(getuid())"
        _ = ShellRun.run("/bin/launchctl", ["bootout", "\(domain)/\(item.label)"], timeout: 10)
    }

    // MARK: - 辅助

    private static func sortItems(_ items: [StartupItem]) -> [StartupItem] {
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
