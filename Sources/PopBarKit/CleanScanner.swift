import AppKit
import Foundation
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 已安装 App 与内嵌组件索引：支持精确匹配、大小写不敏感匹配、子标识/扩展匹配与 LaunchServices 兜底
struct CleanAppIndex: Sendable {
    /// 主 App bundleID -> 展示名
    let names: [String: String]
    /// 全部已安装的主 App 及内嵌 PlugIns/XPC/Helpers/InputMethods 的小写 bundleID
    let installedLowerIDs: Set<String>
    /// 小写 bundleID -> 展示名
    private let lowerToName: [String: String]
    /// 是否使用 LaunchServices 兜底（真实环境为 true，沙箱单元测试为 false）
    let useLaunchServices: Bool

    init(names: [String: String], installedLowerIDs: Set<String>? = nil, useLaunchServices: Bool = false) {
        self.names = names
        var map: [String: String] = [:]
        for (k, v) in names { map[k.lowercased()] = v }
        self.lowerToName = map
        self.installedLowerIDs = installedLowerIDs ?? Set(map.keys)
        self.useLaunchServices = useLaunchServices
    }

    func appName(forBundleID id: String) -> String? {
        if let exact = names[id] { return exact }
        let stripped = CleanScanner.stripTeamIDPrefix(id)
        if let direct = lowerToName[stripped.lowercased()] { return direct }
        // 若是子标识（如 com.foo.app.ShipIt），尝试匹配宿主 App 展示名
        if let host = hostInstalledLowerID(for: stripped) {
            return lowerToName[host]
        }
        return nil
    }

    func contains(_ id: String) -> Bool {
        let stripped = CleanScanner.stripTeamIDPrefix(id).lowercased()
        if installedLowerIDs.contains(stripped) { return true }
        if useLaunchServices, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
           FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        return false
    }

    /// 是否是某个已安装 App 的子标识或常见助手变体（如 .ShipIt / .BundleMigration / Helper / Updater）
    func hasInstalledHost(for identifier: String) -> Bool {
        let stripped = CleanScanner.stripTeamIDPrefix(identifier)
        return hostInstalledLowerID(for: stripped) != nil
    }

    /// 查找宿主已安装 App 的小写 bundleID
    func hostInstalledLowerID(for identifier: String) -> String? {
        let lower = identifier.lowercased()
        let helperSuffixes = [
            "helper", "updater", "agent", "launcher", "shipit",
            "extension", "widget", "service", "daemon", "bundlemigration",
        ]
        for installed in installedLowerIDs {
            if lower == installed { return installed }
            if lower.hasPrefix(installed + ".") || lower.hasPrefix(installed + "-") || lower.hasPrefix(installed + "_") {
                return installed
            }
            if lower.hasPrefix(installed) {
                let tail = String(lower.dropFirst(installed.count))
                if helperSuffixes.contains(where: { tail == $0 || tail.hasPrefix($0 + ".") || tail.hasPrefix($0 + "-") }) {
                    return installed
                }
            }
        }
        return nil
    }

    /// 针对 ~/Library/Application Support 的保守关联检查：
    /// 若反向域名厂商前缀（前两段如 com.meta）与某已安装 App 相同，且包含该 App 的产品核心段（如 endo），
    /// 则视为在装应用的关联目录（如 com.meta.prototypes.endo.tokens <-> com.meta.endo），避免误判为卸载残留。
    func hasRelatedInstalledVendorProduct(for identifier: String) -> Bool {
        let parts = CleanScanner.stripTeamIDPrefix(identifier).lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return false }
        let vendor = "\(parts[0]).\(parts[1])"
        let restTokens = Set(parts.dropFirst(2))
        for installed in installedLowerIDs {
            let iparts = installed.split(separator: ".").map(String.init)
            guard iparts.count >= 3, "\(iparts[0]).\(iparts[1])" == vendor else { continue }
            for seg in iparts.dropFirst(2) where seg.count >= 3 && restTokens.contains(seg) {
                return true
            }
        }
        return false
    }
}

/// 活跃占用锁定解析器：统一扫描期与执行期的「使用中」判断
enum CleanLockResolver {
    struct ActivitySnapshot: Sendable {
        let runningBundleIDsLower: Set<String>
        let runningAppNamesLower: Set<String>
        let runningProcessNamesLower: Set<String>

        @MainActor
        static func captureFromWorkspace(processNames: Set<String>) -> ActivitySnapshot {
            let apps = NSWorkspace.shared.runningApplications
            let ids = Set(apps.compactMap { $0.bundleIdentifier?.lowercased() })
            let names = Set(apps.compactMap { $0.localizedName?.lowercased() })
            return ActivitySnapshot(
                runningBundleIDsLower: ids,
                runningAppNamesLower: names,
                runningProcessNamesLower: Set(processNames.map { $0.lowercased() })
            )
        }
    }

    static func isLocked(
        ownerBundleID: String?,
        ownerAppName: String?,
        lockBundlePrefixes: [String],
        lockProcessNames: [String],
        snapshot: ActivitySnapshot
    ) -> Bool {
        // 1. ownerBundleID 精确或宿主前缀匹配（支持 TeamID 前缀与 .ShipIt/.BundleMigration 等子标识）
        if let rawID = ownerBundleID {
            let cleanID = CleanScanner.stripTeamIDPrefix(rawID).lowercased()
            if snapshot.runningBundleIDsLower.contains(cleanID) { return true }
            if snapshot.runningBundleIDsLower.contains(where: {
                cleanID.hasPrefix($0 + ".") || cleanID.hasPrefix($0 + "-") || $0.hasPrefix(cleanID + ".")
            }) {
                return true
            }
        }

        // 2. 显式 Bundle 前缀匹配（如 JetBrains -> com.jetbrains.*, Google -> com.google.chrome）
        for rawPrefix in lockBundlePrefixes {
            let p = rawPrefix.lowercased()
            guard !p.isEmpty else { continue }
            if p.hasSuffix(".") {
                if snapshot.runningBundleIDsLower.contains(where: { $0.hasPrefix(p) }) { return true }
            } else if snapshot.runningBundleIDsLower.contains(where: {
                $0 == p || $0.hasPrefix(p + ".") || $0.hasPrefix(p + "-")
            }) {
                return true
            }
        }

        // 3. 显式进程名匹配（覆盖 CLI/构建工具与非 Bundle ID 命名的 App 缓存）
        for rawProc in lockProcessNames {
            let proc = rawProc.lowercased()
            guard !proc.isEmpty else { continue }
            if snapshot.runningProcessNamesLower.contains(proc) || snapshot.runningAppNamesLower.contains(proc) {
                return true
            }
        }

        // 4. 已解析出的 App 展示名命中正在运行的应用名
        if let appName = ownerAppName?.lowercased(), !appName.isEmpty,
           snapshot.runningAppNamesLower.contains(appName) {
            return true
        }

        return false
    }
}

/// 扫描器：枚举已知根目录，产出清理候选。所有路径由传入的 home 派生，便于在沙箱目录里测试。
enum CleanScanner {

    struct Target: Sendable {
        let url: URL
        let name: String?
        let category: CleanCategory
        let kind: CleanKind
        let safety: CleanSafety
        let hint: String?
        let ownerBundleID: String?
        let ownerAppName: String?
        let lockBundlePrefixes: [String]
        let lockProcessNames: [String]
        let allowFinderFallback: Bool

        init(
            url: URL,
            name: String? = nil,
            category: CleanCategory,
            kind: CleanKind = .path,
            safety: CleanSafety,
            hint: String? = nil,
            ownerBundleID: String? = nil,
            ownerAppName: String? = nil,
            lockBundlePrefixes: [String] = [],
            lockProcessNames: [String] = [],
            allowFinderFallback: Bool = false
        ) {
            self.url = url
            self.name = name
            self.category = category
            self.kind = kind
            self.safety = safety
            self.hint = hint
            self.ownerBundleID = ownerBundleID
            self.ownerAppName = ownerAppName
            self.lockBundlePrefixes = lockBundlePrefixes
            self.lockProcessNames = lockProcessNames
            self.allowFinderFallback = allowFinderFallback
        }
    }

    static func buildAppIndex(home: URL, extraRoots: [URL]? = nil, useLaunchServices: Bool? = nil) -> CleanAppIndex {
        let roots = extraRoots ?? [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            URL(fileURLWithPath: "/Library/Input Methods"),
            URL(fileURLWithPath: "/Library/PreferencePanes"),
            home.appendingPathComponent("Applications", isDirectory: true),
            home.appendingPathComponent("Library/Input Methods", isDirectory: true),
            home.appendingPathComponent("Library/PreferencePanes", isDirectory: true),
        ]
        var names: [String: String] = [:]
        var installedLower = Set<String>()

        for root in roots {
            scanAppBundles(under: root, depth: 0, maxDepth: 3, names: &names, installedLower: &installedLower)
        }

        let queryLS = useLaunchServices ?? (extraRoots == nil)
        return CleanAppIndex(names: names, installedLowerIDs: installedLower, useLaunchServices: queryLS)
    }

    /// 递归扫描应用目录（深度 <= maxDepth），同时索引 .app 内嵌的 PlugIns / XPCServices / LoginItems / Helpers
    private static func scanAppBundles(
        under dir: URL,
        depth: Int,
        maxDepth: Int,
        names: inout [String: String],
        installedLower: inout Set<String>
    ) {
        guard depth <= maxDepth else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        else { return }

        let bundleExts: Set<String> = ["app", "prefpane", "appex", "xpc"]
        for entry in entries {
            let ext = entry.pathExtension.lowercased()
            if bundleExts.contains(ext) {
                let plist = entry.appendingPathComponent("Contents/Info.plist")
                if let d = NSDictionary(contentsOf: plist) as? [String: Any],
                   let id = d["CFBundleIdentifier"] as? String, !id.isEmpty {
                    let display = (d["CFBundleDisplayName"] as? String)
                        ?? (d["CFBundleName"] as? String)
                        ?? entry.deletingPathExtension().lastPathComponent
                    if names[id] == nil { names[id] = display }
                    installedLower.insert(id.lowercased())
                }
                if ext == "app" {
                    indexEmbeddedBundles(inApp: entry, installedLower: &installedLower)
                }
            } else if depth < maxDepth {
                // 仅进入真实子目录（覆盖 Setapp、JetBrains Toolbox、Chrome Apps.localized、Vendor 目录）
                let vals = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if vals?.isDirectory == true, vals?.isSymbolicLink != true {
                    scanAppBundles(under: entry, depth: depth + 1, maxDepth: maxDepth,
                                   names: &names, installedLower: &installedLower)
                }
            }
        }
    }

    /// 提取 .app 内嵌扩展、XPC 服务、登录项和 Helper 的 Bundle ID，防止其容器或支持目录被误判为残留
    private static func indexEmbeddedBundles(inApp appURL: URL, installedLower: inout Set<String>) {
        let fm = FileManager.default
        let subDirs = [
            "Contents/PlugIns",
            "Contents/XPCServices",
            "Contents/Library/LoginItems",
            "Contents/Helpers",
        ]
        for rel in subDirs {
            let base = appURL.appendingPathComponent(rel, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                let plist = item.appendingPathComponent("Contents/Info.plist")
                if let d = NSDictionary(contentsOf: plist) as? [String: Any],
                   let id = d["CFBundleIdentifier"] as? String, !id.isEmpty {
                    installedLower.insert(id.lowercased())
                }
            }
        }
    }

    static func buildTargets(home: URL, appIndex: CleanAppIndex, runningBundleIDs: Set<String>) -> [Target] {
        var targets: [Target] = []
        var seen = Set<String>()
        let fm = FileManager.default

        func add(
            _ url: URL,
            category: CleanCategory,
            kind: CleanKind = .path,
            safety: CleanSafety,
            name: String? = nil,
            hint: String? = nil,
            ownerBundleID: String? = nil,
            ownerAppName: String? = nil,
            lockBundlePrefixes: [String] = [],
            lockProcessNames: [String] = [],
            allowFinderFallback: Bool = false
        ) {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), fm.fileExists(atPath: key) else { return }
            // 扫描阶段即跳过符号链接，避免默认勾选后再在执行期触发失败告警（Guard 仍保留纵深防御）
            guard !CleanPathGuard.isSymlink(url) else { return }
            seen.insert(key)

            let leaf = url.lastPathComponent
            let lockRule = CleanRules.directoryLockRules[leaf.lowercased()]
            let mergedBundles = lockBundlePrefixes + (lockRule?.bundlePrefixes ?? [])
            let mergedProcs = lockProcessNames + (lockRule?.processNames ?? [])

            targets.append(Target(
                url: url,
                name: name,
                category: category,
                kind: kind,
                safety: safety,
                hint: hint,
                ownerBundleID: ownerBundleID,
                ownerAppName: ownerAppName,
                lockBundlePrefixes: mergedBundles,
                lockProcessNames: mergedProcs,
                allowFinderFallback: allowFinderFallback
            ))
        }

        // 1. 开发工具固定路径
        for e in CleanRules.developerPaths {
            add(home.appendingPathComponent(e.path, isDirectory: true),
                category: .developerTools,
                safety: e.safety,
                name: e.name,
                hint: e.hint,
                lockBundlePrefixes: e.lockBundles,
                lockProcessNames: e.lockProcesses)
        }

        // 2. npm cacache（引用图清理：只删无索引引用的孤儿 blob 与 tmp）
        add(home.appendingPathComponent(CleanRules.npmCachePath, isDirectory: true),
            category: .developerTools,
            kind: .npmCache,
            safety: .safe,
            name: L10n.t("npm 缓存（_cacache）", "npm cache (_cacache)"),
            hint: L10n.t("仅清理无索引引用的孤儿内容，有效缓存保留", "Only orphan blobs with no index reference; live cache is kept"),
            lockProcessNames: ["node", "npm", "npx", "corepack", "yarn", "pnpm"])

        // 3. ~/.cache（统一查 AI / 开发工具表；未在已知表中的目录归入「需确认」）
        for child in children(of: home.appendingPathComponent(".cache", isDirectory: true)) {
            let name = child.lastPathComponent
            if CleanRules.manualCacheExcludes.contains(name.lowercased()) || CleanRules.isProtectedName(name) { continue }
            guard isDirectory(child) else { continue }
            if let classified = CleanRules.classifyKnownToolCache(name) {
                add(child, category: classified.category, safety: classified.safety, hint: classified.hint)
            } else {
                add(child, category: .appCache, safety: .review,
                    hint: L10n.t("未在已知工具表中，需确认", "Not in the known-tools list; please review"))
            }
        }

        // 4. ~/Library/Caches（与 ~/.cache 共享 AI / 开发工具表，保护全部系统/TCC 缓存并忽略单文件元数据）
        for child in children(of: home.appendingPathComponent("Library/Caches", isDirectory: true)) {
            let name = child.lastPathComponent
            if CleanRules.isProtectedName(name) || name == "Homebrew" { continue }
            // ~/Library/Caches 顶层单文件几乎都是系统元数据缓存（如 tiswitcher.cache、AAProfilePicture_*.png），跳过
            guard isDirectory(child) else { continue }
            if let classified = CleanRules.classifyKnownToolCache(name) {
                add(child, category: classified.category, safety: classified.safety, hint: classified.hint)
            } else if name.lowercased().hasPrefix("com.apple.") {
                add(child, category: .appCache, safety: .review,
                    hint: L10n.t("系统组件缓存，建议保留", "System component cache; best kept"))
            } else {
                add(child, category: .appCache, safety: .safe)
            }
        }

        // 5. Chromium / Electron 位于 ~/Library/Application Support 下的定点安全子缓存（默认 .review 不勾选，宿主运行时锁定）
        let appSupportRoot = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        for rule in CleanRules.appSupportSubCacheRules {
            let base = appSupportRoot.appendingPathComponent(rule.baseRelPath, isDirectory: true)
            guard isDirectory(base), !CleanPathGuard.isSymlink(base) else { continue }
            let profileRoots: [(label: String?, dir: URL)]
            if rule.hasProfiles {
                profileRoots = chromiumProfileDirs(in: base)
            } else {
                profileRoots = [(nil, base)]
            }
            for prof in profileRoots {
                for sub in rule.subDirs {
                    let subURL = prof.dir.appendingPathComponent(sub, isDirectory: true)
                    guard isDirectory(subURL), !CleanPathGuard.isSymlink(subURL) else { continue }
                    let labelParts = [rule.appName, prof.label, sub].compactMap { $0 }
                    add(subURL,
                        category: .appCache,
                        safety: .review,
                        name: labelParts.joined(separator: " · "),
                        hint: L10n.t("应用子缓存，删除后会自动重建，不影响登录与数据",
                                     "App sub-cache, rebuilt automatically without losing sign-ins or data"),
                        ownerBundleID: rule.lockBundles.first,
                        ownerAppName: rule.appName,
                        lockBundlePrefixes: rule.lockBundles,
                        lockProcessNames: rule.lockProcesses)
                }
            }
        }

        // 6. ~/Library/Logs（排除 PopBar 自身日志与系统二进制记录；DiagnosticReports 作为 .review 可选清理）
        let skippedLogFiles: Set<String> = ["fsck_hfs.log", "discrecording.log"]
        for child in children(of: home.appendingPathComponent("Library/Logs", isDirectory: true)) {
            let name = child.lastPathComponent
            let lower = name.lowercased()
            if CleanRules.isProtectedName(name) || name == "PopBar" { continue }
            if lower.hasSuffix(".aapbz") || skippedLogFiles.contains(lower) { continue }
            if name == "DiagnosticReports" {
                add(child, category: .appCache, safety: .review,
                    hint: L10n.t("系统与应用崩溃报告，无需排查故障时可清理",
                                 "System and app crash reports; safe to clean if not debugging"))
            } else {
                add(child, category: .appCache, safety: .safe)
            }
        }

        // 7. 沙盒容器分析：
        //    - 已安装非 Apple App -> 扫描其内部 Data/Library/Caches 作为 App 缓存
        //    - 未找到宿主且未运行的非 Apple App -> 整容器归为卸载残留（allowFinderFallback = true）
        let containersRoot = home.appendingPathComponent("Library/Containers", isDirectory: true)
        for child in children(of: containersRoot) {
            guard isDirectory(child), !CleanPathGuard.isSymlink(child) else { continue }
            let rawName = child.lastPathComponent
            let resolvedID = resolveContainerBundleID(containerURL: child) ?? rawName
            guard isBundleIDLike(resolvedID) else { continue }
            let lowerID = resolvedID.lowercased()
            if lowerID.hasPrefix("com.apple.") || CleanRules.isProtectedName(resolvedID) || CleanRules.isProtectedName(rawName) {
                continue
            }

            let isActiveOrInstalled = appIndex.contains(resolvedID)
                || runningBundleIDs.contains(resolvedID)
                || appIndex.hasInstalledHost(for: resolvedID)
                || hasRunningHost(for: resolvedID, running: runningBundleIDs)

            if isActiveOrInstalled {
                // 已安装沙盒 App：只扫其容器内可再生的 Data/Library/Caches
                let innerCaches = child.appendingPathComponent("Data/Library/Caches", isDirectory: true)
                if isDirectory(innerCaches), !CleanPathGuard.isSymlink(innerCaches) {
                    let appName = appIndex.appName(forBundleID: resolvedID) ?? resolvedID
                    add(innerCaches,
                        category: .appCache,
                        safety: .safe,
                        name: L10n.t("\(appName)（沙盒缓存）", "\(appName) (Sandbox Cache)"),
                        hint: L10n.t("沙盒应用内部缓存，不影响应用数据", "Sandboxed app cache; app data is kept"),
                        ownerBundleID: resolvedID,
                        ownerAppName: appName,
                        allowFinderFallback: false)
                }
            } else {
                add(child,
                    category: .remnants,
                    safety: .review,
                    name: resolvedID,
                    hint: L10n.t("未找到对应 App，疑似卸载残留（沙盒容器）", "No matching app found; likely an uninstalled container"),
                    ownerBundleID: resolvedID,
                    allowFinderFallback: true)
            }
        }

        // 8. 卸载残留（Application Support / Saved Application State / HTTPStorages / WebKit / Preferences）
        let appSupportDir = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        for child in children(of: appSupportDir) {
            let name = child.lastPathComponent
            guard isDirectory(child), isBundleIDLike(name),
                  !name.lowercased().hasPrefix("com.apple."),
                  !CleanRules.isProtectedName(name),
                  !CleanRules.protectedAppSupportNames.contains(where: { $0.lowercased() == name.lowercased() })
            else { continue }
            guard !isOwnedOrActive(name, appIndex: appIndex, running: runningBundleIDs, checkVendorRelation: true) else { continue }
            add(child,
                category: .remnants,
                safety: .review,
                hint: L10n.t("未找到对应 App，含应用数据与配置，请确认已卸载",
                             "No matching app found; contains app data and settings, verify before removing"),
                ownerBundleID: name)
        }

        let extraRemnantSpecs: [(root: String, stripSuffix: String?, hint: String)] = [
            ("Library/Saved Application State", ".savedState",
             L10n.t("已卸载应用的窗口恢复状态", "Saved window state from a removed app")),
            ("Library/HTTPStorages", nil,
             L10n.t("已卸载应用的网络存储缓存", "HTTP storage left by a removed app")),
            ("Library/WebKit", nil,
             L10n.t("已卸载应用的 WebKit 网页缓存", "WebKit cache left by a removed app")),
            ("Library/Preferences", ".plist",
             L10n.t("已卸载应用的偏好设置文件", "Preferences file left by a removed app")),
        ]
        for spec in extraRemnantSpecs {
            for child in children(of: home.appendingPathComponent(spec.root, isDirectory: true)) {
                let rawName = child.lastPathComponent
                let candidateID: String
                if let suffix = spec.stripSuffix {
                    guard rawName.hasSuffix(suffix) else { continue }
                    candidateID = String(rawName.dropLast(suffix.count))
                } else {
                    candidateID = rawName
                }
                guard isBundleIDLike(candidateID),
                      !candidateID.lowercased().hasPrefix("com.apple."),
                      !CleanRules.isProtectedName(candidateID),
                      !CleanRules.isProtectedName(rawName)
                else { continue }
                guard !isOwnedOrActive(candidateID, appIndex: appIndex, running: runningBundleIDs, checkVendorRelation: true) else { continue }
                add(child,
                    category: .remnants,
                    safety: .review,
                    name: candidateID,
                    hint: spec.hint,
                    ownerBundleID: candidateID)
            }
        }

        return targets
    }

    static func buildManualItems(home: URL) -> [CleanManualItem] {
        CleanRules.manualTargets.compactMap { e in
            let url = home.appendingPathComponent(e.path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return CleanManualItem(id: UUID(), url: url, name: e.name,
                                   displayPath: CleanDisplayPath.shorten(url, home: home),
                                   hint: e.hint, sizeBytes: nil)
        }
    }

    // MARK: - 工具方法

    /// 去除 10 位 Apple Team ID 前缀（如 5ZSL2CJU2T.com.dingtalk.mac.tblive -> com.dingtalk.mac.tblive）
    static func stripTeamIDPrefix(_ value: String) -> String {
        let parts = value.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return value }
        let prefix = parts[0]
        let isTeamID = prefix.count == 10 && prefix.allSatisfy {
            ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9")
        }
        return isTeamID ? String(parts[1]) : value
    }

    /// 形如 com.tencent.codebuddycn 的反向域名 Bundle ID 判定（至少三段，排除 v1.2.3 等版本号目录）
    static func isBundleIDLike(_ value: String) -> Bool {
        let stripped = stripTeamIDPrefix(value)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard stripped.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let first = String(parts[0])
        // 首段必须纯字母（反向域名 TLD / 组织根），排除 v1.2.3、1.0.0 等版本号
        guard first.count >= 2, first.allSatisfy(\.isLetter) else { return false }
        // 至少两段包含字母，避免 a.1.2 误判
        let alphaSegments = parts.filter { $0.contains(where: \.isLetter) }.count
        return alphaSegments >= 2
    }

    /// 读取 macOS 容器目录内隐藏的 .com.apple.containermanagerd.metadata.plist 中的 MCMMetadataIdentifier
    static func resolveContainerBundleID(containerURL: URL) -> String? {
        let meta = containerURL.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let d = NSDictionary(contentsOf: meta) as? [String: Any],
              let id = d["MCMMetadataIdentifier"] as? String, !id.isEmpty else {
            return nil
        }
        return id
    }

    private static func isOwnedOrActive(
        _ id: String,
        appIndex: CleanAppIndex,
        running: Set<String>,
        checkVendorRelation: Bool
    ) -> Bool {
        let stripped = stripTeamIDPrefix(id)
        if appIndex.contains(stripped) || running.contains(id) || running.contains(stripped) { return true }
        if appIndex.hasInstalledHost(for: stripped) || hasRunningHost(for: stripped, running: running) { return true }
        if checkVendorRelation, appIndex.hasRelatedInstalledVendorProduct(for: stripped) { return true }
        return false
    }

    private static func hasRunningHost(for identifier: String, running: Set<String>) -> Bool {
        let lower = stripTeamIDPrefix(identifier).lowercased()
        return running.contains {
            let r = $0.lowercased()
            return lower == r || lower.hasPrefix(r + ".") || lower.hasPrefix(r + "-")
        }
    }

    private static func chromiumProfileDirs(in base: URL) -> [(label: String?, dir: URL)] {
        var result: [(String?, URL)] = []
        for child in children(of: base) {
            let name = child.lastPathComponent
            guard isDirectory(child), !CleanPathGuard.isSymlink(child) else { continue }
            if name == "Default" || name.hasPrefix("Profile ") {
                result.append((name == "Default" ? nil : name, child))
            }
        }
        return result
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func children(of dir: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
