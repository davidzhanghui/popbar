import Foundation

/// 删除前路径复核(执行阶段对每一项重新调用,不信任评审阶段的旧状态)
enum CleanPathGuard {

    static func allowedRoots(home: URL) -> [String] {
        ["Library/Caches", "Library/Logs", "Library/Containers", "Library/Application Support",
         "Library/Developer", ".cache", ".npm", ".cargo", ".gradle", ".m2", ".pub-cache", "go"]
            .map { home.appendingPathComponent($0).standardizedFileURL.path }
    }

    private static let bannedPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/Library", "/Applications",
    ]

    /// 返回拒绝原因;nil 表示通过
    static func rejection(for url: URL, home: URL) -> String? {
        guard url.path.hasPrefix("/") else { return L10n.t("不是绝对路径", "Not an absolute path") }
        if url.path.rangeOfCharacter(from: .controlCharacters) != nil {
            return L10n.t("包含控制字符", "Contains control characters")
        }
        if url.pathComponents.contains("..") { return L10n.t("路径包含 ..", "Path contains ..") }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return L10n.t("符号链接不清理", "Symlinks are not cleaned")
        }

        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        // 用户目录之外才套系统目录黑名单(测试用的临时 home 本身就在 /private/var 下)
        if !path.hasPrefix(homePath + "/") {
            for p in bannedPrefixes where path == p || path.hasPrefix(p + "/") {
                return L10n.t("系统关键路径", "System-critical path")
            }
        }
        // 必须位于允许根之下,且不能是允许根本身
        guard allowedRoots(home: home).contains(where: { path.hasPrefix($0 + "/") }) else {
            return L10n.t("不在允许的清理范围内", "Outside the allowed cleanup scope")
        }
        return nil
    }
}

/// 目录大小探测(du -skP)
enum CleanSizeProbe {
    /// nil 表示无法测量(权限不足或路径不存在)
    static func size(of url: URL) async -> Int64? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: syncSize(of: url)) }
        }
    }

    static func syncSize(of url: URL) -> Int64? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-skP", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8),
              let line = text.split(separator: "\n").first,
              let kb = Int64(line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "")
        else { return nil }
        return kb * 1024
    }
}

/// 移入废纸篓
enum CleanTrash {
    /// 成功返回废纸篓里的新位置(测试据此回收)
    static func trash(_ url: URL) -> Result<URL?, Error> {
        do {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return .success(result as URL?)
        } catch {
            // ~/Library/Containers 下的目录受 macOS 容器保护:即使属主是自己,第三方程序也会被拒(513)。
            // Finder 有这个权限,改让 Finder 移入废纸篓(同样可恢复)
            if isPermissionError(error), trashViaFinder(url) { return .success(nil) }
            return .failure(error)
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain { return [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(e.code) }
        if e.domain == NSPOSIXErrorDomain { return [Int(EPERM), Int(EACCES)].contains(e.code) }
        return false
    }

    /// 路径经参数传入 AppleScript(不拼进脚本文本),成功以「原路径已不存在」为准
    static func trashViaFinder(_ url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e", "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)",
                       "-e", "end run", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0 && !FileManager.default.fileExists(atPath: url.path)
    }

    /// 给用户看的失败原因:权限类说明成因,其余用系统描述
    static func reason(for error: Error) -> String {
        isPermissionError(error)
            ? L10n.t("macOS 拒绝访问(受保护目录,需允许 PopBar 控制「访达」或授予完全磁盘访问权限)",
                     "macOS denied access (protected folder; allow PopBar to control Finder or grant Full Disk Access)")
            : error.localizedDescription
    }
}

/// 操作记账:时间 \t 操作 \t RAN/SKIPPED \t 条目数 \t 描述
enum CleanLog {
    private static let queue = DispatchQueue(label: "dev.popbar.clean-log")
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

/// npm/node 是否在运行(运行中不与缓存 GC 竞争)
enum CleanProcessCheck {
    static func isNpmActive() async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: ["node", "npm"].contains { run("/usr/bin/pgrep", ["-x", $0]) == 0 })
            }
        }
    }

    private static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
