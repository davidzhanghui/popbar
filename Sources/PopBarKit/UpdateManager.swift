import Cocoa
import CryptoKit
import PopBarCore

/// 轻量应用内自动更新（借鉴 Stonebrook / Sparkle 2 范式）：
/// - 启动与运行期每 6 小时后台检查（网络失败按 1/2/4/6 小时指数退避）；
/// - 发现新版本后后台静默预下载 → 强制 Ed25519 离线验签（`SHA256SUMS.txt.sig`）→ 校验 SHA-256 → 解压验签暂存；
/// - 就绪后弹出非阻塞的 Muse 风格决策窗：支持「跳过这个版本 / 退出应用时安装 / 安装并重启应用」与就地勾选「以后自动下载并安装更新」；
/// - 保留 PopBar 录屏保护、同卷原子替换、AppTranslocation / 只读 DMG 识别与可取消流式下载。
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    static let stateChanged = Notification.Name("PopBarUpdateStateChanged")

    static let repo = "davidzhanghui/popbar"
    static let releasesPageURL = URL(string: "https://github.com/\(repo)/releases")!
    private static let latestAPIURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    private static let lastCheckKey = "PopBarUpdateLastCheckAt"
    private static let retryAfterKey = "PopBarUpdateRetryAfter"
    private static let failureCountKey = "PopBarUpdateFailureCount"
    private static let skippedVersionKey = "PopBarUpdateSkippedVersion"
    private static let pendingUpdateKey = "PopBarUpdatePendingJSON"

    private struct PendingUpdate: Codable {
        let release: UpdateRelease
        let stagedPath: String
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(UpdateRelease)
        case downloading(UpdateRelease, progress: Double, received: Int64, total: Int64)
        case preparing(UpdateRelease, stage: String)
        /// 已下载、验签并解压就绪，随时可秒装或退出时安装
        case ready(UpdateRelease, stagedURL: URL)
        case installing(UpdateRelease, stage: String)
        case manualInstall(UpdateRelease, packageURL: URL, reason: String)
        case failed(String, UpdateRelease?)
    }

    @Published private(set) var state: State = .idle {
        didSet {
            if state != oldValue {
                NotificationCenter.default.post(name: Self.stateChanged, object: nil)
            }
        }
    }

    /// 已发现或已就绪的新版本（供侧栏角标与菜单栏常驻展示）
    @Published private(set) var availableRelease: UpdateRelease? {
        didSet {
            if availableRelease != oldValue {
                NotificationCenter.default.post(name: Self.stateChanged, object: nil)
            }
        }
    }

    /// 本次会话用户是否已显式选择「退出应用时安装」
    @Published private(set) var installOnQuitArmed: Bool = false {
        didSet {
            if installOnQuitArmed != oldValue {
                NotificationCenter.default.post(name: Self.stateChanged, object: nil)
            }
        }
    }

    /// 上次退出替换失败时记录的提示信息（下次启动展示一次）
    @Published private(set) var lastInstallFailure: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var skippedVersion: String?

    private var activeTask: Task<Void, Never>?
    private var activeDownload: DownloadHandle?
    private var periodicTimer: Timer?
    private var promptedVersion: String?

    var hasUpdate: Bool { availableRelease != nil }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .preparing, .installing: return true
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

    // MARK: - 生命周期与定时检查

    /// 应用启动时调用：恢复已预下载的更新、清理旧暂存、读取上次安装失败标记，并开启运行期定时检查。
    func startLifecycle(allowAutoCheck: Bool) {
        restorePending()
        let keepVersion: String?
        if case .ready(let rel, _) = state {
            keepVersion = rel.version.description
        } else {
            keepVersion = nil
        }
        Self.pruneCache(keepingVersion: keepVersion)
        consumeInstallFailure()

        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: UpdateSchedule.periodicPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.autoCheckIfDue()
            }
        }

        guard allowAutoCheck else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .ready(let rel, _) = self.state {
                    self.maybePresentReadyPrompt(for: rel)
                } else {
                    self.autoCheckIfDue()
                }
            }
        }
    }

    /// 后台静默检查：受 `update.autoCheck`、6 小时间隔与失败指数退避控制；失败静默。
    func autoCheckIfDue() {
        guard ConfigStore.shared.config.update.autoCheck else { return }
        guard !isBusy, !isReady else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let retry = UserDefaults.standard.double(forKey: Self.retryAfterKey)
        let lastDate = last > 0 ? Date(timeIntervalSince1970: last) : nil
        let retryDate = retry > 0 ? Date(timeIntervalSince1970: retry) : nil
        guard UpdateSchedule.isDue(now: Date(), lastChecked: lastDate, retryAfter: retryDate) else { return }
        startCheck(manual: false)
    }

    /// 兼容旧入口名。
    func checkOnLaunch() {
        startLifecycle(allowAutoCheck: true)
    }

    /// 用户手动触发检查更新（不受节流和已跳过版本限制）；若已有就绪包直接弹出决策窗。
    func checkManually() {
        if case .ready = state {
            presentReadyPrompt()
            return
        }
        guard !isBusy else { return }
        startCheck(manual: true)
    }

    /// 打开 Muse 风格更新就绪弹窗。
    func presentReadyPrompt() {
        guard case .ready = state else { return }
        UpdatePromptController.shared.show()
    }

    private func maybePresentReadyPrompt(for release: UpdateRelease) {
        if ConfigStore.shared.config.update.autoInstall { return }
        if RecordSession.shared.isRecording { return }
        let ver = release.version.description
        guard promptedVersion != ver else { return }
        promptedVersion = ver
        UpdatePromptController.shared.show()
    }

    private func startCheck(manual: Bool) {
        activeTask?.cancel()
        if manual {
            lastInstallFailure = nil
            state = .checking
        }
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await Self.fetchLatestRelease()
                try Task.checkCancellation()
                let now = Date()
                self.recordCheckSuccess(now: now)

                let isNewer: Bool
                if let cur = Self.currentVersion {
                    isNewer = release.version > cur
                } else {
                    isNewer = manual
                }

                if isNewer {
                    if !manual && self.skippedVersion == release.version.description {
                        return
                    }
                    self.availableRelease = release
                    self.downloadAndPrepare(release, interactive: manual)
                } else {
                    self.availableRelease = nil
                    if manual { self.state = .upToDate(now) }
                }
            } catch is CancellationError {
                if manual { self.state = .idle }
            } catch {
                self.recordCheckFailure()
                if manual {
                    self.state = .failed(Self.describeError(error), self.availableRelease)
                }
            }
        }
    }

    // MARK: - 后台静默下载、离线验签与解压暂存

    /// 下载并准备新版本（完成后进入 `.ready`，不会直接强制重启）。
    func downloadAndPrepare(_ release: UpdateRelease? = nil, interactive: Bool = true) {
        guard let rel = release ?? availableRelease else { return }
        if case .ready(let existing, _) = state, existing.version == rel.version {
            if interactive { presentReadyPrompt() }
            return
        }
        guard let asset = rel.preferredPackage(for: Self.currentArch) else {
            let msg = L10n.t("此版本未包含适配 \(Self.currentArch) 的安装包，请前往发布页手动下载",
                             "No package found for \(Self.currentArch). Please download manually from the release page.")
            if interactive { state = .failed(msg, rel) }
            return
        }

        activeTask?.cancel()
        activeDownload?.cancel()
        state = .downloading(rel, progress: 0, received: 0, total: asset.size)

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 1. 下载前先强校验 SHA256SUMS.txt 与 Ed25519 离线签名（缺失或验签失败立即中止，不浪费流量）
                let expectedHash = try await Self.fetchAndVerifyExpectedSHA256(for: asset, in: rel)
                try Task.checkCancellation()

                // 2. 流式下载安装包（支持进度与取消）
                let versionDir = Self.versionDirectory(for: rel.version.description)
                try? FileManager.default.removeItem(at: versionDir)
                try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
                let archiveURL = versionDir.appendingPathComponent(asset.name)

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

                try? FileManager.default.removeItem(at: archiveURL)
                try FileManager.default.moveItem(at: tempFile, to: archiveURL)

                // 3. 校验安装包大小与 SHA-256
                self.state = .preparing(rel, stage: L10n.t("正在校验安装包完整性…", "Verifying package integrity…"))
                try await Self.verifyArchive(archiveURL, expectedSize: asset.size, expectedSHA256: expectedHash)
                try Task.checkCancellation()

                // 4. 解压并校验 .app 结构、Bundle ID 与代码签名，暂存到缓存目录（不污染 /Applications）
                self.state = .preparing(rel, stage: L10n.t("正在解压并验证应用…", "Extracting and verifying app…"))
                let expectedBundleID = Bundle.main.bundleIdentifier ?? "dev.popbar.app"
                let stagedAppURL = try await Self.extractAndVerifyApp(
                    archiveURL: archiveURL,
                    into: versionDir,
                    expectedBundleID: expectedBundleID
                )
                try? FileManager.default.removeItem(at: archiveURL)
                try Task.checkCancellation()

                // 5. 持久化待安装信息，进入就绪态
                self.savePending(PendingUpdate(release: rel, stagedPath: stagedAppURL.path))
                if self.skippedVersion == rel.version.description {
                    self.skippedVersion = nil
                    UserDefaults.standard.removeObject(forKey: Self.skippedVersionKey)
                }
                Self.pruneCache(keepingVersion: rel.version.description)
                self.availableRelease = rel
                self.state = .ready(rel, stagedURL: stagedAppURL)
                if !interactive {
                    self.maybePresentReadyPrompt(for: rel)
                }
            } catch is CancellationError {
                self.activeDownload = nil
                self.state = .available(rel)
            } catch {
                self.activeDownload = nil
                self.recordCheckFailure()
                if interactive {
                    self.state = .failed(Self.describeError(error), rel)
                } else {
                    self.state = .idle
                }
            }
        }
    }

    /// 兼容旧调用：若已就绪直接安装重启，否则下载并准备。
    func downloadAndInstall(_ release: UpdateRelease? = nil) {
        if case .ready = state {
            installReadyUpdate(relaunch: true)
            return
        }
        downloadAndPrepare(release, interactive: true)
    }

    // MARK: - 就绪后的三态操作：立即重启 / 退出时安装 / 跳过

    /// 立即替换并重启，或（`relaunch == false`）静默安排在退出后替换不重启。
    func installReadyUpdate(relaunch: Bool) {
        guard case .ready(let rel, let stagedURL) = state else { return }
        if relaunch && RecordSession.shared.isRecording {
            state = .failed(L10n.t("正在录屏，请先停止录制后再更新",
                                   "Screen recording is in progress. Stop recording before updating."), rel)
            return
        }
        guard FileManager.default.fileExists(atPath: stagedURL.path) else {
            clearPendingPersistence()
            state = .available(rel)
            return
        }

        let target = UpdateInstallTarget.resolve(bundleURL: Bundle.main.bundleURL)
        let parentDir = target.destinationURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
            UpdatePromptController.shared.close()
            let msg = L10n.t("目标目录 \(parentDir.path) 无写入权限，已为你准备好新版本应用，请点击打开后手动拖入应用程序文件夹",
                             "No write permission for \(parentDir.path). Open the folder and drag PopBar into Applications.")
            state = .manualInstall(rel, packageURL: stagedURL, reason: msg)
            return
        }

        UpdatePromptController.shared.close()
        if relaunch {
            state = .installing(rel, stage: L10n.t("正在覆盖安装并重启…", "Installing and relaunching…"))
        }

        let uuid = UUID().uuidString
        let siblingStaged = parentDir.appendingPathComponent(".PopBar-update-\(uuid).app")
        let backupURL = parentDir.appendingPathComponent(".PopBar-backup-\(uuid).app")
        do {
            try? FileManager.default.removeItem(at: siblingStaged)
            // 同卷优先 O(1) move，跨卷回退 ditto
            do {
                try FileManager.default.moveItem(at: stagedURL, to: siblingStaged)
            } catch {
                let copy = Shell.run("/usr/bin/ditto", [stagedURL.path, siblingStaged.path], timeout: 120)
                guard copy.ok else { throw UpdateError.copyFailed(copy.error) }
            }
        } catch {
            try? FileManager.default.removeItem(at: siblingStaged)
            if relaunch {
                state = .failed(Self.describeError(error), rel)
            }
            return
        }

        let cacheDir = Self.updatesCacheDirectory()
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let logURL = cacheDir.appendingPathComponent("install.log")
        let markURL = cacheDir.appendingPathComponent("install-failed")

        let spawn = Shell.spawnDetached("/bin/sh", [
            "-c", UpdateScript.swapAndRelaunch, "popbar-updater",
            String(getpid()),
            target.destinationURL.path,
            siblingStaged.path,
            backupURL.path,
            relaunch ? "open" : "skip",
            logURL.path,
            markURL.path
        ])
        switch spawn {
        case .success:
            // 已交给独立替换脚本：清空状态防止 applicationWillTerminate 重复触发
            installOnQuitArmed = false
            clearPendingPersistence()
            availableRelease = nil
            state = .idle
            if relaunch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    NSApp.terminate(nil)
                }
            }
        case .failure(let err):
            // 移回暂存包，避免丢失已下载的新版
            if !FileManager.default.fileExists(atPath: stagedURL.path) {
                try? FileManager.default.moveItem(at: siblingStaged, to: stagedURL)
            } else {
                try? FileManager.default.removeItem(at: siblingStaged)
            }
            if relaunch {
                state = .failed(L10n.t("无法启动安装进程：\(err.message)", "Cannot launch installer: \(err.message)"), rel)
            }
        }
    }

    /// 授权「退出应用时安装」：关闭决策窗，保留就绪包，等用户主动退出时静默替换。
    func armInstallOnQuit() {
        guard case .ready = state else { return }
        installOnQuitArmed = true
        UpdatePromptController.shared.close()
    }

    /// 在 `applicationWillTerminate` 中调用：仅当用户点了「退出应用时安装」或开启了「以后自动下载并安装更新」时才安装。
    func installOnQuitIfAuthorized() {
        guard case .ready = state else { return }
        let authorized = installOnQuitArmed || ConfigStore.shared.config.update.autoInstall
        guard authorized else { return }
        installReadyUpdate(relaunch: false)
    }

    /// 跳过当前版本（同步清理已下载暂存包与持久化记录，防止下次启动复活）。
    func skipAvailableVersion() {
        let version: String?
        switch state {
        case .available(let r), .ready(let r, _), .manualInstall(let r, _, _):
            version = r.version.description
        case .failed(_, let r):
            version = r?.version.description ?? availableRelease?.version.description
        default:
            version = availableRelease?.version.description
        }
        guard let version else { return }
        skippedVersion = version
        UserDefaults.standard.set(version, forKey: Self.skippedVersionKey)
        installOnQuitArmed = false
        clearPendingPersistence()
        try? FileManager.default.removeItem(at: Self.versionDirectory(for: version))
        UpdatePromptController.shared.close()
        availableRelease = nil
        state = .idle
    }

    /// 就地切换「以后自动下载并安装更新」（开启时顺手确保自动检查也开启）。
    func setAutoInstall(_ on: Bool) {
        var cfg = ConfigStore.shared.config
        cfg.update.autoInstall = on
        if on { cfg.update.autoCheck = true }
        try? ConfigStore.shared.save(cfg)
    }

    func dismissInstallFailure() {
        lastInstallFailure = nil
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

    // MARK: - 持久化与启动恢复

    private func savePending(_ pending: PendingUpdate) {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.pendingUpdateKey)
        }
    }

    private func clearPendingPersistence() {
        UserDefaults.standard.removeObject(forKey: Self.pendingUpdateKey)
    }

    private func restorePending() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingUpdateKey),
              let pending = try? JSONDecoder().decode(PendingUpdate.self, from: data) else {
            return
        }
        let stagedURL = URL(fileURLWithPath: pending.stagedPath)
        let isNewer = Self.currentVersion.map { pending.release.version > $0 } ?? false
        let notSkipped = skippedVersion != pending.release.version.description
        let cacheRoot = Self.updatesCacheDirectory().standardizedFileURL.path
        let insideCache = stagedURL.standardizedFileURL.path.hasPrefix(cacheRoot + "/")
        let bundleVersion = Self.readBundleShortVersion(at: stagedURL)
        let versionMatches = bundleVersion.flatMap(SemVer.init) == pending.release.version

        if isNewer && notSkipped && insideCache && versionMatches && FileManager.default.fileExists(atPath: stagedURL.path) {
            availableRelease = pending.release
            state = .ready(pending.release, stagedURL: stagedURL)
        } else {
            clearPendingPersistence()
        }
    }

    private func consumeInstallFailure() {
        let markURL = Self.updatesCacheDirectory().appendingPathComponent("install-failed")
        guard let raw = try? String(contentsOf: markURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: markURL)
        let msg = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        lastInstallFailure = msg.isEmpty
            ? L10n.t("上次更新安装失败，已保留旧版本", "Previous update failed to install. Your previous version was kept.")
            : L10n.t("上次更新安装失败，已保留旧版本：\(msg)", "Previous update failed to install: \(msg)")
    }

    private func recordCheckSuccess(now: Date) {
        lastCheckedAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
        UserDefaults.standard.set(0.0, forKey: Self.retryAfterKey)
        UserDefaults.standard.set(0, forKey: Self.failureCountKey)
    }

    private func recordCheckFailure() {
        let count = UserDefaults.standard.integer(forKey: Self.failureCountKey) + 1
        UserDefaults.standard.set(count, forKey: Self.failureCountKey)
        let retryAt = Date().addingTimeInterval(UpdateSchedule.retryDelay(failures: count))
        UserDefaults.standard.set(retryAt.timeIntervalSince1970, forKey: Self.retryAfterKey)
    }

    // MARK: - 网络与强校验（后台执行）

    private enum UpdateError: LocalizedError {
        case httpStatus(Int)
        case rateLimited
        case missingChecksum
        case missingSignature
        case signatureInvalid
        case checksumMissingEntry(String)
        case sizeMismatch(expected: Int64, actual: Int64)
        case checksumMismatch
        case mountFailed(String)
        case unzipFailed(String)
        case appNotFoundInPackage
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
            case .missingChecksum:
                return L10n.t("发布中缺少校验文件 SHA256SUMS.txt，为安全起见已拒绝安装",
                              "Release is missing SHA256SUMS.txt. Installation aborted for security.")
            case .missingSignature:
                return L10n.t("发布中缺少签名文件 SHA256SUMS.txt.sig，为安全起见已拒绝安装",
                              "Release is missing SHA256SUMS.txt.sig. Installation aborted for security.")
            case .signatureInvalid:
                return L10n.t("发布签名校验失败（Ed25519 不匹配），安装包可能被篡改，已拒绝安装",
                              "Release signature verification failed (Ed25519 mismatch). Installation aborted.")
            case .checksumMissingEntry(let name):
                return L10n.t("校验文件中未找到 \(name) 的摘要，已拒绝安装",
                              "Checksum entry for \(name) not found. Installation aborted.")
            case .sizeMismatch:
                return L10n.t("安装包大小不完整，请重试", "Downloaded file size mismatch. Please try again.")
            case .checksumMismatch:
                return L10n.t("安装包 SHA256 校验未通过，已中止安装", "SHA256 checksum verification failed. Installation aborted.")
            case .mountFailed(let e):
                return L10n.t("挂载 DMG 失败：\(e)", "Failed to mount DMG: \(e)")
            case .unzipFailed(let e):
                return L10n.t("解压安装包失败：\(e)", "Failed to unzip update package: \(e)")
            case .appNotFoundInPackage:
                return L10n.t("安装包里未找到 PopBar.app", "PopBar.app was not found inside the package.")
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

    /// 强校验：先下载并验证 `SHA256SUMS.txt` 的 Ed25519 离线签名，再取出对应安装包的期望 SHA-256。
    private nonisolated static func fetchAndVerifyExpectedSHA256(for asset: UpdateAsset, in release: UpdateRelease) async throws -> String {
        guard let checksumAsset = release.checksumAsset else {
            throw UpdateError.missingChecksum
        }
        guard let sigAsset = release.signatureAsset else {
            throw UpdateError.missingSignature
        }
        let (sumData, sumResp) = try await URLSession.shared.data(for: makeRequest(url: checksumAsset.downloadURL, timeout: 15))
        guard let sumHTTP = sumResp as? HTTPURLResponse, (200..<300).contains(sumHTTP.statusCode) else {
            throw UpdateError.httpStatus((sumResp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let (sigData, sigResp) = try await URLSession.shared.data(for: makeRequest(url: sigAsset.downloadURL, timeout: 15))
        guard let sigHTTP = sigResp as? HTTPURLResponse, (200..<300).contains(sigHTTP.statusCode) else {
            throw UpdateError.httpStatus((sigResp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do {
            try UpdateSignature.verify(sumData, signature: sigData)
        } catch {
            throw UpdateError.signatureInvalid
        }
        guard let text = String(data: sumData, encoding: .utf8),
              let expected = UpdateRelease.parseSHA256Sums(text, filename: asset.name) else {
            throw UpdateError.checksumMissingEntry(asset.name)
        }
        return expected
    }

    private nonisolated static func verifyArchive(_ archiveURL: URL, expectedSize: Int64, expectedSHA256: String) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if expectedSize > 0 && actualSize != expectedSize {
            try? FileManager.default.removeItem(at: archiveURL)
            throw UpdateError.sizeMismatch(expected: expectedSize, actual: actualSize)
        }
        let actual = try await Task.detached(priority: .utility) {
            try Self.sha256Hex(of: archiveURL)
        }.value
        if actual != expectedSHA256 {
            try? FileManager.default.removeItem(at: archiveURL)
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

    /// 解压 `.app.zip` 或挂载 `.dmg` → 校验 PopBar.app 与代码签名 → 暂存到 `versionDir/app/PopBar.app` → 清理 quarantine。
    private nonisolated static func extractAndVerifyApp(archiveURL: URL, into versionDir: URL, expectedBundleID: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let unpackedDir = versionDir.appendingPathComponent("app", isDirectory: true)
            try? fm.removeItem(at: unpackedDir)
            try fm.createDirectory(at: unpackedDir, withIntermediateDirectories: true)

            let stagedApp: URL
            if archiveURL.lastPathComponent.lowercased().hasSuffix(".zip") {
                let unzip = Shell.run("/usr/bin/ditto", ["-x", "-k", archiveURL.path, unpackedDir.path], timeout: 120)
                guard unzip.ok else { throw UpdateError.unzipFailed(unzip.error) }
                let items = (try? fm.contentsOfDirectory(at: unpackedDir, includingPropertiesForKeys: nil)) ?? []
                guard let found = items.first(where: { $0.lastPathComponent == "PopBar.app" })
                    ?? items.first(where: { $0.pathExtension.lowercased() == "app" }) else {
                    throw UpdateError.appNotFoundInPackage
                }
                stagedApp = found
            } else {
                let mountDir = fm.temporaryDirectory.appendingPathComponent("popbar-mnt-\(UUID().uuidString)")
                try fm.createDirectory(at: mountDir, withIntermediateDirectories: true)
                var mounted = false
                defer {
                    if mounted {
                        _ = Shell.run("/usr/bin/hdiutil", ["detach", mountDir.path, "-force", "-quiet"], timeout: 30)
                    }
                    try? fm.removeItem(at: mountDir)
                }
                let attach = Shell.run("/usr/bin/hdiutil", [
                    "attach", archiveURL.path,
                    "-nobrowse", "-readonly", "-noautoopen",
                    "-mountpoint", mountDir.path, "-quiet"
                ], timeout: 60)
                guard attach.ok else { throw UpdateError.mountFailed(attach.error) }
                mounted = true

                let items = (try? fm.contentsOfDirectory(at: mountDir, includingPropertiesForKeys: nil)) ?? []
                guard let appURL = items.first(where: { $0.lastPathComponent == "PopBar.app" })
                    ?? items.first(where: { $0.pathExtension.lowercased() == "app" }) else {
                    throw UpdateError.appNotFoundInPackage
                }
                let dst = unpackedDir.appendingPathComponent("PopBar.app")
                let copy = Shell.run("/usr/bin/ditto", [appURL.path, dst.path], timeout: 120)
                guard copy.ok else { throw UpdateError.copyFailed(copy.error) }
                stagedApp = dst
            }

            // 校验 Bundle 结构和标识符
            let infoURL = stagedApp.appendingPathComponent("Contents/Info.plist")
            let execURL = stagedApp.appendingPathComponent("Contents/MacOS/PopBar")
            guard fm.fileExists(atPath: infoURL.path), fm.isExecutableFile(atPath: execURL.path),
                  let dict = NSDictionary(contentsOf: infoURL) as? [String: Any],
                  let bundleID = dict["CFBundleIdentifier"] as? String else {
                throw UpdateError.appNotFoundInPackage
            }
            guard bundleID == expectedBundleID else {
                throw UpdateError.bundleMismatch(bundleID)
            }

            // 校验代码签名（ad-hoc 签名与 Developer ID 签名均能通过 --verify --deep --strict）
            let verify = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path], timeout: 30)
            guard verify.ok else {
                throw UpdateError.codeSignInvalid(verify.error)
            }

            // 清除 quarantine 扩展属性，避免重启后触发「已损坏」弹窗
            _ = Shell.run("/usr/bin/xattr", ["-cr", stagedApp.path], timeout: 30)
            return stagedApp
        }.value
    }

    private nonisolated static func readBundleShortVersion(at appURL: URL) -> String? {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: infoURL) as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    private nonisolated static func updatesCacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("dev.popbar.app/updates", isDirectory: true)
    }

    private nonisolated static func versionDirectory(for version: String) -> URL {
        let safe = version.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
        let name = safe.isEmpty || safe.hasPrefix(".") ? "staged" : safe
        return updatesCacheDirectory().appendingPathComponent(name, isDirectory: true)
    }

    private nonisolated static func pruneCache(keepingVersion keep: String?) {
        let fm = FileManager.default
        let dir = updatesCacheDirectory()
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for e in entries {
            let name = e.lastPathComponent
            if name == "install.log" || name == "install-failed" || name == keep { continue }
            try? fm.removeItem(at: e)
        }
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
            .appendingPathComponent("popbar-dl-\(UUID().uuidString).pkg")
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
