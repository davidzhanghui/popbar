import Foundation

/// npm cacache 引用图分析（对应 Mole 的 CleanNpmGC.ReferenceProof）
///
/// cacache 布局（以本机 cacache 20.x 为准）：
///   index-v5/<h1>/<h2>/<hash>      索引条目，JSON Lines，每行含被引用的 integrity
///   content-v2/<algo>/<h1>/<h2>/<h3>  内容 blob，h1h2h3 是完整内容 hash 拆成 3 段
///   tmp/                            临时文件
///
/// 算法：先构建"所有索引引用过的 content 地址"集合，再扫描 content-v2；
/// 不在集合中的 blob 即"孤儿"，可证明安全删除。索引本身不变动。
enum CleanNpmGC {

    struct Analysis: Sendable {
        var totalBlobs: Int
        var totalBytes: Int64
        var orphanCount: Int
        var orphanBytes: Int64
        var danglingIndexCount: Int
        var tmpBytes: Int64

        var keptBytes: Int64 { max(0, totalBytes - orphanBytes) }
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

    static func cacheExists(at root: URL = CleanNpmGC.defaultCacheRoot) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    // MARK: - 分析（只读，用于 UI 展示）

    static func analyze(cacheRoot: URL = CleanNpmGC.defaultCacheRoot) async -> Analysis? {
        await withCheckedContinuation { continuation in
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

                for (url, size) in snap.orphans {
                    do {
                        try fm.removeItem(at: url)
                        result.removedBlobs += 1
                        result.freedBytes += size
                    } catch {
                        result.failedBlobs += 1
                    }
                }

                for url in snap.tmpItems {
                    if (try? fm.removeItem(at: url)) != nil {
                        result.removedTmp += 1
                    }
                }

                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - 内部实现

    private struct Snapshot {
        var totalBlobs = 0
        var totalBytes: Int64 = 0
        var orphans: [(URL, Int64)] = []
        var orphanBytes: Int64 = 0
        var dangling = 0
        var tmpItems: [URL] = []
        var tmpBytes: Int64 = 0
    }

    private static func snapshot(cacheRoot: URL) -> Snapshot? {
        let fm = FileManager.default
        let indexRoot = cacheRoot.appendingPathComponent("index-v5", isDirectory: true)
        // 枚举器给出的是真实路径(如 /private/var/...),相对路径要基于同样的真实路径计算
        let contentRoot = realURL(cacheRoot.appendingPathComponent("content-v2", isDirectory: true))
        let tmpRoot = cacheRoot.appendingPathComponent("tmp", isDirectory: true)

        guard fm.fileExists(atPath: contentRoot.path) else { return nil }

        // 1. 引用集合：扫描 index-v5 的所有 integrity
        var referenced = Set<String>()
        for file in regularFiles(under: indexRoot) {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var searchStart = text.startIndex
            while let range = text.range(of: "\"integrity\":\"", range: searchStart..<text.endIndex) {
                let after = range.upperBound
                guard let end = text[after...].firstIndex(of: "\"") else { break }
                if let rel = contentRelativePath(fromIntegrity: String(text[after..<end])) {
                    referenced.insert(rel)
                }
                searchStart = end
            }
        }

        // 2. content-v2：比对出孤儿
        var snap = Snapshot()
        var contentPaths = Set<String>()
        for file in regularFiles(under: contentRoot) {
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

        // 3. tmp 残留
        for file in regularFiles(under: tmpRoot) {
            snap.tmpItems.append(file)
            snap.tmpBytes += fileSize(of: file)
        }

        return snap
    }

    /// integrity（如 sha512-<base64>）-> content-v2 下的相对路径
    /// cacache/lib/util/hash-to-segments.js: [hash[0:2], hash[2:4], hash[4:]]
    private static func contentRelativePath(fromIntegrity integrity: String) -> String? {
        guard let dash = integrity.firstIndex(of: "-") else { return nil }
        let algo = String(integrity[integrity.startIndex..<dash])
        let base64 = String(integrity[integrity.index(after: dash)...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard hex.count >= 4 else { return nil }
        return "\(algo)/\(hex.prefix(2))/\(hex.dropFirst(2).prefix(2))/\(hex.dropFirst(4))"
    }

    private static func realURL(_ url: URL) -> URL {
        guard let p = realpath(url.path, nil) else { return url }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: true)
    }

    private static func regularFiles(under root: URL) -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return result }

        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                result.append(url)
            }
        }
        return result
    }

    private static func fileSize(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
