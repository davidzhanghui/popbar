import Foundation
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// npm cacache 引用图分析（对应 Mole 的 CleanNpmGC.ReferenceProof）
///
/// cacache 布局（以 cacache 20.x / ssri 规范为准）：
///   index-v5/<h1>/<h2>/<hash>         索引条目，每行 `<hex>\t<json>`，JSON 中含 integrity（可为多算法空格分隔）
///   content-v2/<algo>/<h1>/<h2>/<h3>  内容 blob，h1h2h3 是完整内容 hash 拆成 3 段
///   tmp/                              临时文件
///
/// 算法与安全原则（Fail-Closed）：
///   1. 必须同时可读 index-v5 与 content-v2；只要任意索引文件读取/解码失败或含无法解析的 integrity，
///      立即中止 GC（返回 nil），绝不基于不完整的引用集合误删有效 blob。
///   2. 完整解析每条索引的 JSON 与多算法 SSRI（空格分隔），将所有被引用的 content 相对路径加入集合。
///   3. 仅删除不在引用集合中的孤儿 blob 与 tmp 残留，删除前校验非符号链接且 realpath 仍在目标根下。
enum CleanNpmGC {

    struct Analysis: Sendable {
        var totalBlobs: Int
        var totalBytes: Int64
        var orphanCount: Int
        var orphanBytes: Int64
        var danglingIndexCount: Int
        var tmpBytes: Int64

        var keptBytes: Int64 { max(0, totalBytes - orphanBytes) }
        /// 本次清理预计释放的总字节数（孤儿 blob + tmp 残留）
        var reclaimableBytes: Int64 { orphanBytes + tmpBytes }
    }

    struct CleanupResult: Sendable {
        var removedBlobs: Int
        var freedBytes: Int64
        var failedBlobs: Int
        var removedTmp: Int
    }

    static var defaultCacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_cacache", isDirectory: true)
    }

    // MARK: - 分析（只读，用于 UI 展示）

    static func analyze(cacheRoot: URL = CleanNpmGC.defaultCacheRoot) async -> Analysis? {
        if Task.isCancelled { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let snap = snapshot(cacheRoot: cacheRoot) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Analysis(
                    totalBlobs: snap.totalBlobs,
                    totalBytes: snap.totalBytes,
                    orphanCount: snap.orphans.count,
                    orphanBytes: snap.orphanBytes,
                    danglingIndexCount: snap.dangling,
                    tmpBytes: snap.tmpBytes
                ))
            }
        }
    }

    // MARK: - 清理：重新分析后只删孤儿与 tmp

    static func cleanup(cacheRoot: URL = CleanNpmGC.defaultCacheRoot) async -> CleanupResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let snap = snapshot(cacheRoot: cacheRoot) else {
                    continuation.resume(returning: nil)
                    return
                }

                let fm = FileManager.default
                var result = CleanupResult(removedBlobs: 0, freedBytes: 0, failedBlobs: 0, removedTmp: 0)
                let contentRootPath = snap.contentRoot.path
                let tmpRootPath = snap.tmpRoot.path

                for (url, size) in snap.orphans {
                    guard isSafeDescendant(url, underRealRoot: contentRootPath) else {
                        result.failedBlobs += 1
                        continue
                    }
                    do {
                        try fm.removeItem(at: url)
                        result.removedBlobs += 1
                        result.freedBytes += size
                        pruneEmptyParents(from: url.deletingLastPathComponent(), stopAt: snap.contentRoot)
                    } catch {
                        result.failedBlobs += 1
                    }
                }

                for (url, size) in snap.tmpItems {
                    guard isSafeDescendant(url, underRealRoot: tmpRootPath) else {
                        result.failedBlobs += 1
                        continue
                    }
                    do {
                        try fm.removeItem(at: url)
                        result.removedTmp += 1
                        result.freedBytes += size
                        pruneEmptyParents(from: url.deletingLastPathComponent(), stopAt: snap.tmpRoot)
                    } catch {
                        result.failedBlobs += 1
                    }
                }

                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - 内部实现

    private struct Snapshot {
        let contentRoot: URL
        let tmpRoot: URL
        var totalBlobs = 0
        var totalBytes: Int64 = 0
        var orphans: [(URL, Int64)] = []
        var orphanBytes: Int64 = 0
        var dangling = 0
        var tmpItems: [(URL, Int64)] = []
        var tmpBytes: Int64 = 0
    }

    private static func snapshot(cacheRoot: URL) -> Snapshot? {
        let fm = FileManager.default
        guard !CleanPathGuard.isSymlink(cacheRoot) else { return nil }
        let indexRoot = realURL(cacheRoot.appendingPathComponent("index-v5", isDirectory: true))
        let contentRoot = realURL(cacheRoot.appendingPathComponent("content-v2", isDirectory: true))
        let tmpRoot = realURL(cacheRoot.appendingPathComponent("tmp", isDirectory: true))

        // Fail-Closed：content-v2 与 index-v5 必须同时存在，防止无索引时把全部有效内容判为孤儿
        var isContentDir: ObjCBool = false
        var isIndexDir: ObjCBool = false
        guard fm.fileExists(atPath: contentRoot.path, isDirectory: &isContentDir), isContentDir.boolValue,
              fm.fileExists(atPath: indexRoot.path, isDirectory: &isIndexDir), isIndexDir.boolValue
        else { return nil }

        // 1. 引用集合：严格读取 index-v5 下的全部索引文件，任一读取/解析异常即中止（Fail-Closed）
        guard let indexFiles = regularFilesStrict(under: indexRoot) else { return nil }
        var referenced = Set<String>()
        for file in indexFiles {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            guard collectReferencedPaths(fromIndexText: text, into: &referenced) else {
                return nil
            }
        }

        // 2. content-v2：比对出孤儿
        guard let contentFiles = regularFilesStrict(under: contentRoot) else { return nil }
        var snap = Snapshot(contentRoot: contentRoot, tmpRoot: tmpRoot)
        var contentPaths = Set<String>()
        for file in contentFiles {
            guard file.path.count > contentRoot.path.count + 1 else { continue }
            let rel = String(file.path.dropFirst(contentRoot.path.count + 1))
            contentPaths.insert(rel)
            let size = fileSize(of: file)
            snap.totalBlobs += 1
            snap.totalBytes += size
            if !referenced.contains(rel) {
                snap.orphans.append((file, size))
                snap.orphanBytes += size
            }
        }
        snap.dangling = referenced.subtracting(contentPaths).count

        // 3. tmp 残留（tmp 目录可选存在）
        var isTmpDir: ObjCBool = false
        if fm.fileExists(atPath: tmpRoot.path, isDirectory: &isTmpDir), isTmpDir.boolValue,
           let tmpFiles = regularFilesStrict(under: tmpRoot) {
            for file in tmpFiles {
                let size = fileSize(of: file)
                snap.tmpItems.append((file, size))
                snap.tmpBytes += size
            }
        }

        return snap
    }

    /// 逐行解析 index-v5 条目；支持 `<hex>\t<json>` 及多算法空格分隔 SSRI。
    /// 返回 false 表示遇到无法安全解析的索引条目，调用方应中止 GC。
    static func collectReferencedPaths(fromIndexText text: String, into referenced: inout Set<String>) -> Bool {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // cacache 行格式：<sha1-hex>\t<json>（兼容任意空白分隔）
            guard let jsonStart = line.firstIndex(of: "{") else {
                return false
            }
            let jsonSlice = String(line[jsonStart...])
            guard let jsonData = jsonSlice.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return false
            }
            if let integrity = obj["integrity"] as? String {
                let trimmed = integrity.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let paths = contentRelativePaths(fromIntegrity: trimmed)
                    guard !paths.isEmpty else { return false }
                    for p in paths { referenced.insert(p) }
                }
            }
        }
        return true
    }

    /// 解析 SSRI 字符串（支持单算法与多算法空格分隔，如 `sha512-xxx sha1-yyy`）-> content-v2 相对路径列表
    /// cacache/lib/util/hash-to-segments.js: [hash[0:2], hash[2:4], hash[4:]]
    static func contentRelativePaths(fromIntegrity integrity: String) -> [String] {
        var paths: [String] = []
        for rawToken in integrity.split(whereSeparator: \.isWhitespace) {
            // SSRI 允许算法后附带 ?options（如 sha512-xxx?foo=bar），先去掉选项段
            let token = rawToken.split(separator: "?", maxSplits: 1).first.map(String.init) ?? String(rawToken)
            guard let dash = token.firstIndex(of: "-") else { continue }
            let algo = String(token[token.startIndex..<dash]).lowercased()
            let base64 = String(token[token.index(after: dash)...])
            guard !algo.isEmpty, let data = Data(base64Encoded: base64) else { continue }
            let hex = data.map { String(format: "%02x", $0) }.joined()
            guard hex.count >= 4 else { continue }
            paths.append("\(algo)/\(hex.prefix(2))/\(hex.dropFirst(2).prefix(2))/\(hex.dropFirst(4))")
        }
        return paths
    }

    private static func isSafeDescendant(_ url: URL, underRealRoot rootPath: String) -> Bool {
        guard !CleanPathGuard.isSymlink(url) else { return false }
        guard let realParent = CleanPathGuard.realPath(of: url.deletingLastPathComponent().path) else { return false }
        return realParent == rootPath || realParent.hasPrefix(rootPath + "/")
    }

    private static func pruneEmptyParents(from dir: URL, stopAt root: URL) {
        let fm = FileManager.default
        let stopPath = root.standardizedFileURL.path
        var cur = dir.standardizedFileURL
        while cur.path != stopPath, cur.path.hasPrefix(stopPath + "/") {
            guard let contents = try? fm.contentsOfDirectory(atPath: cur.path), contents.isEmpty else { break }
            try? fm.removeItem(at: cur)
            cur = cur.deletingLastPathComponent().standardizedFileURL
        }
    }

    private static func realURL(_ url: URL) -> URL {
        guard let p = realpath(url.path, nil) else { return url }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: true)
    }

    /// 严格枚举常规文件：遇到目录枚举错误返回 nil（Fail-Closed），跳过符号链接
    private static func regularFilesStrict(under root: URL) -> [URL]? {
        var result: [URL] = []
        var encounteredError = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in
                encounteredError = true
                return false
            }
        ) else { return nil }

        for case let url as URL in enumerator {
            if encounteredError { return nil }
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if vals?.isSymbolicLink == true { continue }
            if vals?.isRegularFile == true {
                result.append(url)
            }
        }
        return encounteredError ? nil : result
    }

    private static func fileSize(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
