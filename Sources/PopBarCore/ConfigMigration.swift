import Foundation

/// 配置迁移：在 JSON 层面做，和 Kit 里的 Codable 结构解耦，便于单测。
///
/// v3（PopBar 3.0）做三件事：
/// 1. 快捷键默认值替换——只替换仍是旧默认值的，用户改过的不动；
/// 2. 字符串改枚举——无法识别的旧值（如 `triggerMode = "keyboard"`）改成默认值；
/// 3. 补上模块开关的默认值。
/// 迁移前把原文件备份成 `config.v2.json`。
public enum ConfigMigration {
    public static let currentVersion = 3

    /// 模块开关默认值（docs 3.9）
    public static let moduleDefaults: [String: Bool] = [
        "today": true, "clipboard": true, "snap": true, "record": true,
        "monitor": true, "clean": true,
        "startup": false, "maintenance": false, "print": false, "tv": false,
    ]

    /// 旧默认 → 新默认
    public static let hotkeyDefaultChanges: [String: (old: String, new: String)] = [
        // 与系统「下一个输入法」冲突
        "showBar": ("ctrl+opt+space", "ctrl+opt+b"),
    ]

    /// 原地迁移，返回是否有改动
    @discardableResult
    public static func migrate(_ json: inout [String: Any]) -> Bool {
        let version = (json["schemaVersion"] as? Int) ?? 0
        guard version < currentVersion else { return false }

        // 1. 快捷键
        var hotkeys = json["hotkeys"] as? [String: Any] ?? [:]
        for (key, change) in hotkeyDefaultChanges {
            if let v = hotkeys[key] as? String,
               v.replacingOccurrences(of: " ", with: "").lowercased() == change.old {
                hotkeys[key] = change.new
            }
        }
        if !hotkeys.isEmpty { json["hotkeys"] = hotkeys }

        // 2. 字符串改枚举
        if let t = json["triggerMode"] as? String, TriggerMode(rawValue: t) == nil {
            json["triggerMode"] = TriggerMode.fallback.rawValue
        }
        if var privacy = json["privacy"] as? [String: Any],
           let g = privacy["guard"] as? String, GuardMode(rawValue: g) == nil {
            privacy["guard"] = GuardMode.fallback.rawValue
            json["privacy"] = privacy
        }
        // 浮动条：Google / 百度两个按钮合并为一个「搜索」，引擎由设置决定
        if var toolbar = json["toolbar"] as? [String: Any] {
            if var items = toolbar["items"] as? [[String: Any]] {
                let ids = items.compactMap { $0["id"] as? String }
                if toolbar["searchEngine"] == nil {
                    let google = items.first { ($0["id"] as? String) == "builtin.google" }
                    let baidu = items.first { ($0["id"] as? String) == "builtin.baidu" }
                    let googleOn = (google?["visible"] as? Bool) ?? (google != nil)
                    let baiduOn = (baidu?["visible"] as? Bool) ?? false
                    toolbar["searchEngine"] = (!googleOn && baiduOn) ? "baidu" : "google"
                }
                if ids.contains("builtin.google") || ids.contains("builtin.baidu") {
                    var out: [[String: Any]] = []
                    var addedSearch = ids.contains("builtin.search")
                    for item in items {
                        let id = item["id"] as? String
                        if id == "builtin.google" || id == "builtin.baidu" {
                            if !addedSearch {
                                out.append(["id": "builtin.search", "visible": true])
                                addedSearch = true
                            }
                        } else {
                            out.append(item)
                        }
                    }
                    items = out
                }
                toolbar["items"] = items
            }
            toolbar.removeValue(forKey: "contextPosition")
            json["toolbar"] = toolbar
        }

        // 3. 模块开关
        var modules = json["modules"] as? [String: Any] ?? [:]
        for (k, v) in moduleDefaults where modules[k] == nil { modules[k] = v }
        json["modules"] = modules

        json["schemaVersion"] = currentVersion
        return true
    }

    /// 迁移磁盘上的配置文件；需要迁移时先备份为同目录下的 `config.v2.json`（已有备份不覆盖）。
    /// 返回迁移后的数据；文件不存在 / 不是 JSON 对象 / 无需迁移时返回 nil。
    @discardableResult
    public static func migrateFile(at url: URL, backupName: String = "config.v2.json") -> Data? {
        guard let data = try? Data(contentsOf: url),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              migrate(&json),
              let out = try? JSONSerialization.data(withJSONObject: json,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        let backup = url.deletingLastPathComponent().appendingPathComponent(backupName)
        let fm = FileManager.default
        if !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: url, to: backup)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try? out.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return out
    }
}
