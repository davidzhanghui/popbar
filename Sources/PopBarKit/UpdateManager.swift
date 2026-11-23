import Cocoa
import CryptoKit
import PopBarCore

/// 轻量应用内自动更新：检查 GitHub Releases → 流式下载对应架构 DMG → 校验 SHA256 与签名 → 覆盖安装并重启。
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    static let stateChanged = Notification.Name("PopBarUpdateStateChanged")

    static let repo = "davidzhanghui/popbar"
    static let releasesPageURL = URL(string: "https://github.com/\(repo)/releases")!
    private static let latestAPIURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    private static let lastCheckKey = "PopBarUpdateLastCheckAt"
    private static let skippedVersionKey = "PopBarUpdateSkippedVersion"
    /// 启动自动检查的最小间隔（24 小时）
    private static let autoCheckInterval: TimeInterval = 24 * 3600

    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(UpdateRelease)
        case downloading(UpdateRelease, progress: Double, received: Int64, total: Int64)
        case installing(UpdateRelease, stage: String)
        case manualInstall(UpdateRelease, dmgURL: URL, reason: String)
        case failed(String, UpdateRelease?)
    }

    @Published private(set) var state: State = .idle {
        didSet {
            if state != oldValue {
                NotificationCenter.default.post(name: Self.stateChanged, object: nil)
            }
        }
    }

    /// 已发现的新版本（供侧栏角标与菜单栏常驻展示）
    @Published private(set) var availableRelease: UpdateRelease? {
        didSet {
            if availableRelease != oldValue {
                NotificationCenter.default.post(name: Self.stateChanged, object: nil)
            }
        }
    }

    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var skippedVersion: String?

    private var activeTask: Task<Void, Never>?
    private var activeDownload: DownloadHandle?

    var hasUpdate: Bool { availableRelease != nil }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static var currentVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    static var currentVersion: SemVer? {
        SemVer(currentVersionString)
    }

    private init() {
        let ts = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if ts > 0 { lastCheckedAt = Date(timeIntervalSince1970: ts) }
        skippedVersion = UserDefaults.standard.string(forKey: Self.skippedVersionKey)
    }

    // MARK: - 检查更新

    /// 启动后在后台静默检查：受 `update.autoCheck` 与 24 小时节流控制；失败不打扰用户。
    func checkOnLaunch() {
        guard ConfigStore.shared.config.update.autoCheck else { return }
        guard !isBusy else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if last > 0, Date().timeIntervalSince1970 - last < Self.autoCheckInterval {
            return
        }
        startCheck(manual: false)
    }

    /// 用户手动触发检查更新（不受节流和已跳过版本限制）
    func checkManually() {
        guard !isBusy else { return }
        startCheck(manual: true)
    }

    private func startCheck(manual: Bool) {
        activeTask?.cancel()
        if manual { state = .checking }
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await Self.fetchLatestRelease()
                try Task.checkCancellation()
                let now = Date()
                self.lastCheckedAt = now
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)

                let isNewer: Bool
                if let cur = Self.currentVersion {
                    isNewer = release.version > cur
                } else {
                    // 开发构建（无合法版本号）仅在手动检查时展示最新正式版
                    isNewer = manual
                }

                if isNewer {
                    self.availableRelease = release
                    self.state = .available(release)
                    if !manual && self.skippedVersion != release.version.description {
                        self.presentUpdateAlert(release)
                    }
                } else {
                    self.availableRelease = nil
                    if manual { self.state = .upToDate(now) }
                }
            } catch is CancellationError {
                if manual { self.state = .idle }
            } catch {
                if manual {
                    self.state = .failed(Self.describeError(error), self.availableRelease)
                }
            }
        }
    }

    /// 跳过当前发现的版本（启动自动检查不再弹窗，手动检查仍可安装）
    func skipAvailableVersion() {
        guard let rel = availableRelease else { return }
        skippedVersion = rel.version.description
        UserDefaults.standard.set(rel.version.description, forKey: Self.skippedVersionKey)
        availableRelease = nil
        state = .idle
    }

    func openReleasePage(_ release: UpdateRelease? = nil) {
        let url = release?.htmlURL ?? availableRelease?.htmlURL ?? Self.releasesPageURL
        NSWorkspace.shared.open(url)
    }

    func cancelDownload() {
        activeDownload?.cancel()
        activeDownload = nil
        activeTask?.cancel()
        activeTask = nil
        if let rel = availableRelease {
            state = .available(rel)
        } else {
            state = .idle
        }
    }

    // MARK: - 启动弹窗

    private func presentUpdateAlert(_ release: UpdateRelease) {
        let a = NSAlert()
        a.messageText = L10n.t("发现 PopBar 新版本 v\(release.version)",
                               "PopBar v\(release.version) is available")
        let notes = Self.compactNotes(release.changelogText, maxLines: 6)
        let current = Self.currentVersionString
        let header = L10n.t("当前版本 \(current)，可一键自动下载、覆盖安装并重启。",
                            "Current version \(current). PopBar can download, install and relaunch automatically.")
        a.informativeText = notes.isEmpty ? header : "\(header)\n\n\(notes)"
        a.addButton(withTitle: L10n.t("立即更新并重启", "Update & Relaunch"))
        a.addButton(withTitle: L10n.t("稍后", "Later"))
        a.addButton(withTitle: L10n.t("跳过此版本", "Skip This Version"))
        NSApp.activateForUI()
        switch a.runModal() {
        case .alertFirstButtonReturn:
            DeckController.shared.show(page: .settings, settings: .about)
            downloadAndInstall(release)
        case .alertThirdButtonReturn:
            skipAvailableVersion()
        default:
            break
        }
    }

    // MARK: - 下载、校验、覆盖安装与重启

    func downloadAndInstall(_ release: UpdateRelease? = nil) {
        guard let rel = release ?? availableRelease else { return }
        if RecordSession.shared.isRecording {
            state = .failed(L10n.t("正在录屏，请先停止录制后再更新",
                                   "Screen recording is in progress. Stop recording before updating."), rel)
            return
        }
        guard let asset = rel.preferredDMG(for: Self.currentArch) else {
            state = .failed(L10n.t("此版本未包含适配 \(Self.currentArch) 的 DMG 安装包，请前往发布页手动下载",
                                   "No DMG asset found for \(Self.currentArch). Please download manually from the release page."), rel)
            return
        }

        activeTask?.cancel()
        activeDownload?.cancel()
        state = .downloading(rel, progress: 0, received: 0, total: asset.size)

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 1. 下载 DMG（带实时进度）
                let cacheDir = Self.updatesCacheDirectory()
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                Self.pruneOldDownloads(in: cacheDir)
                let dmgURL = cacheDir.appendingPathComponent(asset.name)
                try? FileManager.default.removeItem(at: dmgURL)

                let handle = DownloadHandle()
                self.activeDownload = handle
                let tempFile = try await handle.download(from: asset.downloadURL) { [weak self] received, total in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let expected = total > 0 ? total : asset.size
                        let progress = expected > 0 ? min(max(Double(received) / Double(expected), 0), 1) : 0
                        self.state = .downloading(rel, progress: progress, received: received, total: expected)
                    }
                }
                self.activeDownload = nil
                try Task.checkCancellation()

                if FileManager.default.fileExists(atPath: dmgURL.path) {
                    try? FileManager.default.removeItem(at: dmgURL)
                }
                try FileManager.default.moveItem(at: tempFile, to: dmgURL)

                // 2. 校验文件大小与可选 SHA256SUMS.txt
                self.state = .installing(rel, stage: L10n.t("正在校验安装包…", "Verifying download…"))
                try await Self.verifyDownloadedDMG(dmgURL, asset: asset, checksumAsset: rel.checksumAsset)
                try Task.checkCancellation()

                // 3. 解析目标安装位置
                let bundleURL = Bundle.main.bundleURL
                let expectedBundleID = Bundle.main.bundleIdentifier ?? "dev.popbar.app"
                let target = UpdateInstallTarget.resolve(bundleURL: bundleURL)
                let parentDir = target.destinationURL.deletingLastPathComponent()

                guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
                    let msg = L10n.t("目标目录 \(parentDir.path) 无写入权限，已为你下载好安装包，请点击打开后手动拖入应用程序文件夹",
                                     "No write permission for \(parentDir.path). The DMG is downloaded; open it and drag PopBar into Applications.")
                    self.state = .manualInstall(rel, dmgURL: dmgURL, reason: msg)
                    return
                }

                // 4. 挂载 DMG、校验 .app、拷贝到同目录暂存包并清理 quarantine
                self.state = .installing(rel, stage: L10n.t("正在解压并验证应用…", "Extracting and verifying app…"))
                let stagedURL = try await Self.extractAndStageApp(
                    dmgURL: dmgURL,
                    parentDir: parentDir,
                    expectedBundleID: expectedBundleID
                )
                try? FileManager.default.removeItem(at: dmgURL)
                try Task.checkCancellation()

                // 5. 拉起独立后台替换重启进程，然后优雅退出当前进程
                self.state = .installing(rel, stage: L10n.t("正在覆盖安装并重启…", "Installing and relaunching…"))
                let backupURL = parentDir.appendingPathComponent(".PopBar-backup-\(UUID().uuidString).app")
                let spawn = Shell.spawnDetached("/bin/sh", [
                    "-c", UpdateScript.swapAndRelaunch, "popbar-updater",
                    String(getpid()),
                    target.destinationURL.path,
                    stagedURL.path,
                    backupURL.path
                ])
                switch spawn {
                case .success:
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    NSApp.terminate(nil)
                case .failure(let err):
                    try? FileManager.default.removeItem(at: stagedURL)
                    self.state = .failed(L10n.t("无法启动安装进程：\(err.message)", "Cannot launch installer: \(err.message)"), rel)
                }
            } catch is CancellationError {
                self.activeDownload = nil
                self.state = .available(rel)
            } catch {
                self.activeDownload = nil
                self.state = .failed(Self.describeError(error), rel)
            }
        }
    }

    // MARK: - 网络与校验（后台执行）

    private enum UpdateError: LocalizedError {
        case httpStatus(Int)
        case rateLimited
        case sizeMismatch(expected: Int64, actual: Int64)
        case checksumMismatch
        case mountFailed(String)
        case appNotFoundInDMG
        case bundleMismatch(String)
        case codeSignInvalid(String)
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code):
                return L10n.t("服务器返回状态码 \(code)", "Server returned HTTP \(code)")
            case .rateLimited:
                return L10n.t("GitHub API 请求频率受限，请稍后再试或直接访问发布页",
                              "GitHub API rate limit reached. Try again later or open the release page.")
            case .sizeMismatch:
                return L10n.t("安装包大小不完整，请重试", "Downloaded file size mismatch. Please try again.")
            case .checksumMismatch:
                return L10n.t("安装包 SHA256 校验未通过，已中止安装", "SHA256 checksum verification failed. Installation aborted.")
            case .mountFailed(let e):
                return L10n.t("挂载 DMG 失败：\(e)", "Failed to mount DMG: \(e)")
            case .appNotFoundInDMG:
                return L10n.t("安装包里未找到 PopBar.app", "PopBar.app was not found inside the DMG.")
            case .bundleMismatch(let id):
                return L10n.t("安装包标识不匹配（\(id)），已中止安装", "Unexpected bundle identifier (\(id)). Installation aborted.")
            case .codeSignInvalid(let e):
                return L10n.t("新版本完整性校验未通过：\(e)", "Code signature verification failed: \(e)")
            case .copyFailed(let e):
                return L10n.t("解压应用失败：\(e)", "Failed to extract app: \(e)")
            }
        }
    }

    private nonisolated static func makeRequest(url: URL, timeout: TimeInterval = 15) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        req.setValue("PopBar/\(ver)", forHTTPHeaderField: "User-Agent")
        return req
    }

    private nonisolated static func fetchLatestRelease() async throws -> UpdateRelease {
        let (data, response) = try await URLSession.shared.data(for: makeRequest(url: latestAPIURL))
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.httpStatus(0)
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            throw UpdateError.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return try UpdateRelease.parseGitHubRelease(data)
    }

    private nonisolated static func verifyDownloadedDMG(_ dmgURL: URL, asset: UpdateAsset, checksumAsset: UpdateAsset?) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: dmgURL.path)
        let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if asset.size > 0 && actualSize != asset.size {
            try? FileManager.default.removeItem(at: dmgURL)
            throw UpdateError.sizeMismatch(expected: asset.size, actual: actualSize)
        }
        guard let checksumAsset else { return }
        let (sumData, sumResp) = try await URLSession.shared.data(for: makeRequest(url: checksumAsset.downloadURL, timeout: 15))
        guard let http = sumResp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: sumData, encoding: .utf8),
              let expected = UpdateRelease.parseSHA256Sums(text, filename: asset.name) else {
            return
        }
        let actual = try await Task.detached(priority: .utility) {
            try Self.sha256Hex(of: dmgURL)
        }.value
        if actual != expected {
            try? FileManager.default.removeItem(at: dmgURL)
            throw UpdateError.checksumMismatch
        }
    }

    private nonisolated static func sha256Hex(of fileURL: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: fileURL)
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = try fh.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 挂载 DMG → 校验 PopBar.app 与代码签名 → 拷贝到目标目录同级暂存路径 → 清理 quarantine → 卸载 DMG
    private nonisolated static func extractAndStageApp(dmgURL: URL, parentDir: URL, expectedBundleID: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let uuid = UUID().uuidString
            let mountDir = fm.temporaryDirectory.appendingPathComponent("popbar-mnt-\(uuid)")
            try fm.createDirectory(at: mountDir, withIntermediateDirectories: true)

            var mounted = false
            defer {
                if mounted {
                    _ = Shell.run("/usr/bin/hdiutil", ["detach", mountDir.path, "-force", "-quiet"], timeout: 30)
                }
                try? fm.removeItem(at: mountDir)
            }

            let attach = Shell.run("/usr/bin/hdiutil", [
                "attach", dmgURL.path,
                "-nobrowse", "-readonly", "-noautoopen",
                "-mountpoint", mountDir.path, "-quiet"
            ], timeout: 60)
            guard attach.ok else {
                throw UpdateError.mountFailed(attach.error)
            }
            mounted = true

            // 定位挂载卷中的 PopBar.app
            let items = (try? fm.contentsOfDirectory(at: mountDir, includingPropertiesForKeys: nil)) ?? []
            let appURL = items.first { $0.lastPathComponent == "PopBar.app" }
                ?? items.first { $0.pathExtension.lowercased() == "app" }
            guard let appURL else {
                throw UpdateError.appNotFoundInDMG
            }

            // 校验 Bundle 结构和标识符
            let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
            let execURL = appURL.appendingPathComponent("Contents/MacOS/PopBar")
            guard fm.fileExists(atPath: infoURL.path), fm.isExecutableFile(atPath: execURL.path),
                  let dict = NSDictionary(contentsOf: infoURL) as? [String: Any],
                  let bundleID = dict["CFBundleIdentifier"] as? String else {
                throw UpdateError.appNotFoundInDMG
            }
            guard bundleID == expectedBundleID else {
                throw UpdateError.bundleMismatch(bundleID)
            }

            // 校验代码签名（ad-hoc 签名与 Developer ID 签名均能通过 --verify --deep --strict）
            let verify = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path], timeout: 30)
            guard verify.ok else {
                throw UpdateError.codeSignInvalid(verify.error)
            }

            // 拷贝到目标父目录同级暂存路径，确保后续 mv 在同卷内原子完成
            let stagedURL = parentDir.appendingPathComponent(".PopBar-update-\(uuid).app")
            try? fm.removeItem(at: stagedURL)
            let copy = Shell.run("/usr/bin/ditto", [appURL.path, stagedURL.path], timeout: 120)
            guard copy.ok else {
                try? fm.removeItem(at: stagedURL)
                throw UpdateError.copyFailed(copy.error)
            }

            // 清除 quarantine 扩展属性，避免重启后触发「已损坏」弹窗
            _ = Shell.run("/usr/bin/xattr", ["-cr", stagedURL.path], timeout: 30)
            return stagedURL
        }.value
    }

    private nonisolated static func updatesCacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("dev.popbar.app/updates", isDirectory: true)
    }

    private nonisolated static func pruneOldDownloads(in dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? fm.removeItem(at: f) }
    }

    private static func compactNotes(_ text: String, maxLines: Int) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count <= maxLines { return lines.joined(separator: "\n") }
        return lines.prefix(maxLines).joined(separator: "\n") + "\n…"
    }

    private static func describeError(_ error: Error) -> String {
        if let ue = error as? UpdateError, let desc = ue.errorDescription { return desc }
        if let pe = error as? UpdateRelease.ParseError {
            switch pe {
            case .invalidJSON: return L10n.t("无法解析发布信息", "Cannot parse release metadata.")
            case .missingVersion(let t): return L10n.t("版本号格式无法识别（\(t)）", "Unrecognized version tag (\(t)).")
            case .invalidURL: return L10n.t("发布页链接无效", "Invalid release URL.")
            case .draftOrPrerelease: return L10n.t("当前没有可用的正式版本", "No stable release available.")
            }
        }
        return error.localizedDescription
    }
}

// MARK: - 原生高速流式下载（支持进度回调、302 重定向与取消）

private final class DownloadHandle: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var lastProgressAt: TimeInterval = 0
    private var cancelled = false

    func download(from url: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock {
                if cancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                self.continuation = cont
                self.onProgress = onProgress
                let cfg = URLSessionConfiguration.ephemeral
                cfg.timeoutIntervalForRequest = 30
                cfg.timeoutIntervalForResource = 600
                let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
                self.session = s
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
                req.setValue("PopBar/\(ver)", forHTTPHeaderField: "User-Agent")
                let t = s.downloadTask(with: req)
                self.task = t
                t.resume()
            }
        }
    }

    func cancel() {
        let (t, s, cont) = lock.withLock { () -> (URLSessionDownloadTask?, URLSession?, CheckedContinuation<URL, Error>?) in
            cancelled = true
            let c = continuation
            continuation = nil
            let t = task
            task = nil
            let s = session
            session = nil
            return (t, s, c)
        }
        t?.cancel()
        s?.invalidateAndCancel()
        cont?.resume(throwing: CancellationError())
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date().timeIntervalSinceReferenceDate
        let cb: (@Sendable (Int64, Int64) -> Void)? = lock.withLock {
            guard !cancelled else { return nil }
            if now - lastProgressAt < 0.08 && totalBytesWritten != totalBytesExpectedToWrite { return nil }
            lastProgressAt = now
            return onProgress
        }
        cb?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 必须在回调返回前把系统临时文件移走，否则系统立即删除
        let moved = FileManager.default.temporaryDirectory
            .appendingPathComponent("popbar-dl-\(UUID().uuidString).dmg")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "PopBarUpdate", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: L10n.t("下载失败（HTTP \(http.statusCode)）",
                                                                           "Download failed (HTTP \(http.statusCode))")])
            }
            try FileManager.default.moveItem(at: location, to: moved)
            finish(with: .success(moved))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            finish(with: .failure(CancellationError()))
        } else {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<URL, Error>) {
        let (s, cont) = lock.withLock { () -> (URLSession?, CheckedContinuation<URL, Error>?) in
            let c = continuation
            continuation = nil
            let s = session
            session = nil
            task = nil
            return (s, c)
        }
        s?.finishTasksAndInvalidate()
        if let cont {
            cont.resume(with: result)
        } else if case .success(let url) = result {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
