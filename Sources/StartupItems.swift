import Cocoa

/// 登录项与后台服务(LaunchAgent / LaunchDaemon)。
/// 用户级只用 launchctl enable/disable 开关(launchd 覆盖表,重新登录生效),不改写第三方 plist;
/// 系统级只展示。
struct StartupItem: Identifiable, Equatable {
    var id: String { path }
    let label: String
    let kind: String          // LaunchAgent / LaunchDaemon
    let path: String
    var enabled: Bool
    let systemLevel: Bool
    let program: String?
    /// 指向的程序已不存在(且没有关联的已安装应用)
    let broken: Bool
}

enum StartupItems {
    struct Plist {
        var label: String
        var program: String?
        var associatedBundleIDs: [String]
        var disabledInPlist: Bool
    }

    /// 解析 plist;program 已展开 ~ 并拼接 WorkingDirectory,裸命令名(靠 PATH 查找)返回 nil
    static func parse(_ path: String) -> Plist? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return nil }
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let label = (dict["Label"] as? String) ?? file
        var program = (dict["Program"] as? String) ?? ((dict["ProgramArguments"] as? [Any])?.first as? String)
        if let p = program {
            var full = (p as NSString).expandingTildeInPath
            if !full.hasPrefix("/"), let wd = dict["WorkingDirectory"] as? String {
                full = ((wd as NSString).expandingTildeInPath as NSString).appendingPathComponent(full)
            }
            program = full.hasPrefix("/") ? (full as NSString).standardizingPath : nil
        }
        var assoc: [String] = []
        if let s = dict["AssociatedBundleIdentifiers"] as? String { assoc = [s] }
        if let a = dict["AssociatedBundleIdentifiers"] as? [String] { assoc = a }
        return Plist(label: label, program: program, associatedBundleIDs: assoc,
                     disabledInPlist: (dict["Disabled"] as? Bool) ?? false)
    }

    static func isBroken(_ p: Plist,
                         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                         isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) -> Bool {
        guard let program = p.program, !fileExists(program) else { return false }
        return !p.associatedBundleIDs.contains(where: isInstalled)
    }

    /// 解析 `launchctl print-disabled` 的输出:形如  "com.foo.bar" => disabled
    static func parseDisabled(_ output: String) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            map[label] = parts[1].trimmingCharacters(in: .whitespaces).hasPrefix("disabled")
        }
        return map
    }

    static func scan() -> [StartupItem] {
        let r = ShellRun.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"], timeout: 10)
        let overrides = r.status == 0 ? parseDisabled(r.out) : [:]
        let dirs: [(path: String, kind: String, system: Bool)] = [
            ("~/Library/LaunchAgents", "LaunchAgent", false),
            ("/Library/LaunchAgents", "LaunchAgent", true),
            ("/Library/LaunchDaemons", "LaunchDaemon", true),
        ]
        var out: [StartupItem] = []
        for d in dirs {
            let base = (d.path as NSString).expandingTildeInPath
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
            for name in files where name.hasSuffix(".plist") {
                let full = base + "/" + name
                guard let info = parse(full) else { continue }
                let disabled = d.system ? info.disabledInPlist : (overrides[info.label] ?? info.disabledInPlist)
                out.append(StartupItem(label: info.label, kind: d.kind, path: full, enabled: !disabled,
                                       systemLevel: d.system, program: info.program, broken: isBroken(info)))
            }
        }
        return out.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    static func setEnabled(_ item: StartupItem, _ enabled: Bool) -> Bool {
        guard !item.systemLevel else { return false }
        let r = ShellRun.run("/bin/launchctl", [enabled ? "enable" : "disable", "gui/\(getuid())/\(item.label)"], timeout: 10)
        return r.status == 0
    }
}
