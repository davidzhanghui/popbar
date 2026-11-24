import Foundation
import Darwin
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 删除前路径复核（执行阶段对每一项重新调用，不信任评审阶段的旧状态）
enum CleanPathGuard {

    static func allowedRoots(home: URL) -> [String] {
        [
            "Library/Caches",
            "Library/Logs",
            "Library/Containers",
            "Library/Application Support",
            "Library/Developer",
            "Library/WebKit",
            "Library/HTTPStorages",
            "Library/Saved Application State",
            "Library/Preferences",
            "Library/pnpm",
            ".cache",
            ".npm",
            ".cargo",
            ".gradle",
            ".m2",
            ".ivy2",
            ".pub-cache",
            ".bun",
            ".yarn",
            ".pnpm-store",
            ".android",
            ".composer",
            ".conda",
            "go",
        ].map { home.appendingPathComponent($0).standardizedFileURL.path }
    }

    private static let bannedPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/Library", "/Applications",
    ]

    /// 使用 POSIX lstat 实时检测是否为符号链接（不受 URL resourceValues 缓存影响）
    static func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// 解析路径的真实绝对路径（存在时返回 realpath，否则返回 nil）
    static func realPath(of path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// 返回拒绝原因；nil 表示通过
    static func rejection(for url: URL, home: URL) -> String? {
        let rawPath = url.path
        guard rawPath.hasPrefix("/") else { return L10n.t("不是绝对路径", "Not an absolute path") }
        if rawPath.rangeOfCharacter(from: .controlCharacters) != nil {
            return L10n.t("包含控制字符", "Contains control characters")
        }
        if url.pathComponents.contains("..") { return L10n.t("路径包含 ..", "Path contains ..") }
        if isSymlink(url) {
            return L10n.t("符号链接不清理", "Symlinks are not cleaned")
        }

        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        // 用户目录之外才套系统目录黑名单（测试用的临时 home 本身就在 /private/var 下）
        if !path.hasPrefix(homePath + "/") {
            for p in bannedPrefixes where path == p || path.hasPrefix(p + "/") {
                return L10n.t("系统关键路径", "System-critical path")
            }
        }

        // 逻辑路径必须严格位于允许根之下，且不能是允许根本身
        let roots = allowedRoots(home: home)
        guard let matchedRoot = roots.first(where: { path.hasPrefix($0 + "/") }) else {
            return L10n.t("不在允许的清理范围内", "Outside the allowed cleanup scope")
        }

        // 防祖先目录符号链接逃逸：若父目录和允许根在磁盘上存在，校验真实父路径仍在允许根真实路径之内
        let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
        if let realParent = realPath(of: parentPath), let realRoot = realPath(of: matchedRoot) {
            guard realParent == realRoot || realParent.hasPrefix(realRoot + "/") else {
                return L10n.t("祖先路径包含指向外部的符号链接", "Ancestor path escapes cleanup root via symlink")
            }
        }

        // 纵深防御：执行期也强制拦截核心受保护名称与系统高危目录
        let leaf = url.lastPathComponent
        if CleanRules.isProtectedName(leaf) {
            return L10n.t("受保护的系统或应用目录", "Protected system or app folder")
        }

        // 对敏感根下的顶层目录做额外拦截
        let rel = String(path.dropFirst(matchedRoot.count + 1))
        let firstSeg = rel.split(separator: "/").first.map(String.init) ?? ""
        let lowerFirst = firstSeg.lowercased()

        if matchedRoot.hasSuffix("/Library/Containers") {
            if lowerFirst.hasPrefix("com.apple.") || lowerFirst == "com.docker.docker" {
                return L10n.t("受保护的系统或核心容器", "Protected system or core container")
            }
        } else if matchedRoot.hasSuffix("/Library/Application Support") {
            if lowerFirst.hasPrefix("com.apple.") {
                return L10n.t("受保护的系统支持目录", "Protected system support folder")
            }
            // 不允许直接删除已知核心应用在 Application Support 下的顶层目录（只允许删精准子缓存）
            if !rel.contains("/"), CleanRules.protectedAppSupportNames.contains(where: { $0.lowercased() == lowerFirst }) {
                return L10n.t("受保护的应用数据根目录", "Protected application data root")
            }
        } else if matchedRoot.hasSuffix("/Library/Preferences") {
            if lowerFirst.hasPrefix("com.apple.") || lowerFirst.hasPrefix(".globalpreferences") {
                return L10n.t("受保护的系统偏好设置", "Protected system preferences")
            }
        }

        return nil
    }
}

/// 目录大小探测（du -skP）
enum CleanSizeProbe {
    /// nil 表示无法测量（权限不足、已取消或路径不存在）
    static func size(of url: URL) async -> Int64? {
        if Task.isCancelled { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: syncSize(of: url))
            }
        }
    }

    /// du 的 stderr 会被并发读完；遇到无权限的子目录仍输出总数时采纳，全无权限时返回 nil
    static func syncSize(of url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let o = Shell.run("/usr/bin/du", ["-skP", "--", url.path], timeout: 60)
        guard case .exited = o.status,
              let line = o.text.split(separator: "\n").first,
              let kb = Int64(line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "")
        else { return nil }
        return kb * 1024
    }
}

/// 移入废纸篓
enum CleanTrash {
    /// 成功返回废纸篓里的新位置（测试据此回收）。
    /// `allowFinderFallback` 默认为 false，仅允许对明确标记的已卸载容器残留开启，避免对 TCC 受保护系统缓存静默提权。
    static func trash(_ url: URL, allowFinderFallback: Bool = false) -> Result<URL?, Error> {
        do {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return .success(result as URL?)
        } catch {
            // ~/Library/Containers 下的已卸载残留受 macOS 容器保护（513），仅对显式允许的项回退给 Finder
            if allowFinderFallback, isPermissionError(error), trashViaFinder(url) {
                return .success(nil)
            }
            return .failure(error)
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain { return [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(e.code) }
        if e.domain == NSPOSIXErrorDomain { return [Int(EPERM), Int(EACCES)].contains(e.code) }
        return false
    }

    /// 路径经参数传入 AppleScript（不拼进脚本文本），执行前再次确认非符号链接，成功以「原路径已不存在」为准
    static func trashViaFinder(_ url: URL) -> Bool {
        guard !CleanPathGuard.isSymlink(url) else { return false }
        let o = Shell.run("/usr/bin/osascript",
                          ["-e", "on run argv", "-e", "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)",
                           "-e", "end run", url.path], timeout: 30)
        return o.ok && !FileManager.default.fileExists(atPath: url.path)
    }

    /// 给用户看的失败原因：权限类说明成因，其余用系统描述
    static func reason(for error: Error) -> String {
        isPermissionError(error)
            ? L10n.t("macOS 拒绝访问（受保护目录，需允许 PopBar 控制「访达」或授予完全磁盘访问权限）",
                     "macOS denied access (protected folder; allow PopBar to control Finder or grant Full Disk Access)")
            : error.localizedDescription
    }
}

/// 操作记账：时间 \t 操作 \t RAN/SKIPPED \t 条目数 \t 描述（超过 2 MB 自动轮转）
enum CleanLog {
    private static let queue = DispatchQueue(label: "dev.popbar.clean-log")
    private static let maxBytes: Int64 = 2 * 1024 * 1024
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PopBar/clean.log")
    }

    static func append(action: String, status: String, count: Int, detail: String) {
        let line = "\(formatter.string(from: Date()))\t\(action)\t\(status)\t\(count)\t\(detail)\n"
        let url = fileURL
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber,
               size.int64Value >= maxBytes {
                let backup = url.deletingLastPathComponent().appendingPathComponent("clean.log.1")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: url, to: backup)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// 进程快照与工具活跃检查（单次 ps 快照，避免频繁 spawn 多个 pgrep）
enum CleanProcessCheck {
    /// 获取当前所有活跃进程的短名集合（全部小写）
    static func runningProcessNamesSync() -> Set<String> {
        let o = Shell.run("/bin/ps", ["-axo", "comm="], timeout: 10)
        guard o.ok else { return [] }
        var result = Set<String>()
        for raw in o.text.split(separator: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let base = URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
            if !base.isEmpty { result.insert(base) }
        }
        return result
    }

    static func runningProcessNames() async -> Set<String> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: runningProcessNamesSync())
            }
        }
    }

    /// npm / node / npx / corepack / yarn / pnpm 是否在运行（运行中不与 npm 缓存 GC 竞争）
    static func isNpmActive() async -> Bool {
        let procs = await runningProcessNames()
        let activeTools: Set<String> = ["node", "npm", "npx", "corepack", "yarn", "pnpm"]
        return !procs.isDisjoint(with: activeTools)
    }
}
