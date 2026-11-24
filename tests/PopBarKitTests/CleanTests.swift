import XCTest
import CryptoKit
@testable import PopBarKit

/// 清理模块专项回归测试（全沙箱隔离，覆盖 P0 安全红线、P1 正确性/并发与 P2 覆盖全面性）。
final class CleanTests: XCTestCase {

    private var tempHome: URL!
    private var tempOutside: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        let suffix = UUID().uuidString.prefix(8)
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("popbar-clean-unit-\(suffix)").resolvingSymlinksInPath()
        tempOutside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("popbar-clean-unit-out-\(suffix)").resolvingSymlinksInPath()
        try? fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try? fm.createDirectory(at: tempOutside, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: tempHome)
        try? fm.removeItem(at: tempOutside)
        super.tearDown()
    }

    private func writeFile(_ relPath: String, bytes: Int = 2048, under base: URL? = nil) -> URL {
        let root = base ?? tempHome!
        let url = root.appendingPathComponent(relPath)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(repeating: 0x42, count: bytes).write(to: url)
        return url
    }

    private func writeBundle(at relPath: String, bundleID: String, displayName: String? = nil) {
        let plist = tempHome.appendingPathComponent(relPath).appendingPathComponent("Contents/Info.plist")
        try? fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        var dict: [String: Any] = ["CFBundleIdentifier": bundleID]
        if let displayName { dict["CFBundleName"] = displayName }
        (dict as NSDictionary).write(to: plist, atomically: true)
    }

    private func sri512(of data: Data) -> (sri: String, rel: String) {
        let digest = Data(SHA512.hash(data: data))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return ("sha512-" + digest.base64EncodedString(),
                "sha512/\(hex.prefix(2))/\(hex.dropFirst(2).prefix(2))/\(hex.dropFirst(4))")
    }

    private func sri1(of data: Data) -> (sri: String, rel: String) {
        let digest = Data(Insecure.SHA1.hash(data: data))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return ("sha1-" + digest.base64EncodedString(),
                "sha1/\(hex.prefix(2))/\(hex.dropFirst(2).prefix(2))/\(hex.dropFirst(4))")
    }

    // MARK: - P0-1: 非 com.apple.* Apple 系统与 TCC 缓存全面保护

    func testProtectedSystemAndTCCCachesExcludedAndRejectedByGuard() {
        let protectedDirs = [
            "CloudKit", "FamilyCircle", "familycircled", "GeoServices",
            "PassKit", "Animoji", "askpermissiond", "AudioUnitCache",
            "Metadata", "com.apple.Safari", "com.apple.Safari.SafeBrowsing",
            "com.apple.HomeKit", "com.apple.findmy.fmfcore", "docker-secrets-engine",
            "dev.popbar.app",
        ]
        for dir in protectedDirs {
            _ = writeFile("Library/Caches/\(dir)/data.bin")
        }
        // 顶层单文件（如 Apple ID 头像、系统缓存文件）也应跳过
        _ = writeFile("Library/Caches/AAProfilePicture_1234.png")
        _ = writeFile("Library/Caches/com.apple.tiswitcher.cache")
        _ = writeFile("Library/Caches/com.safe.thirdparty/data.bin")

        let index = CleanScanner.buildAppIndex(home: tempHome, extraRoots: [])
        let targets = CleanScanner.buildTargets(home: tempHome, appIndex: index, runningBundleIDs: [])
        let cacheNames = Set(targets.filter { $0.url.path.contains("/Library/Caches/") }.map { $0.url.lastPathComponent })

        XCTAssertEqual(cacheNames, ["com.safe.thirdparty"])
        for dir in protectedDirs {
            let url = tempHome.appendingPathComponent("Library/Caches/\(dir)")
            XCTAssertNotNil(CleanPathGuard.rejection(for: url, home: tempHome), "Guard 必须拦截 \(dir)")
        }
    }

    // MARK: - P0-2: 活跃占用锁定（子标识、TeamID 前缀、非 Bundle ID 目录名、CLI 工具）

    func testLockResolverCoversSubIDsTeamIDsAndToolProcesses() {
        let snap = CleanLockResolver.ActivitySnapshot(
            runningBundleIDsLower: ["com.google.chrome", "com.tencent.workbuddy.mac", "com.jetbrains.intellij", "com.apple.dt.xcode"],
            runningAppNamesLower: ["google chrome", "feishu"],
            runningProcessNamesLower: ["go", "claude", "cargo"]
        )

        // 1. 子标识（如 .BundleMigration / .ShipIt）
        XCTAssertTrue(CleanLockResolver.isLocked(
            ownerBundleID: "com.tencent.workbuddy.mac.BundleMigration",
            ownerAppName: nil, lockBundlePrefixes: [], lockProcessNames: [], snapshot: snap))

        // 2. Team ID 前缀（5ZSL2CJU2T.com.google.chrome.helper）
        XCTAssertTrue(CleanLockResolver.isLocked(
            ownerBundleID: "5ZSL2CJU2T.com.google.chrome.helper",
            ownerAppName: nil, lockBundlePrefixes: [], lockProcessNames: [], snapshot: snap))

        // 3. 非 Bundle ID 目录名映射（Google / JetBrains / LarkShell）
        let googleRule = CleanRules.directoryLockRules["google"]!
        XCTAssertTrue(CleanLockResolver.isLocked(
            ownerBundleID: nil, ownerAppName: nil,
            lockBundlePrefixes: googleRule.bundlePrefixes, lockProcessNames: googleRule.processNames, snapshot: snap))

        let jbRule = CleanRules.directoryLockRules["jetbrains"]!
        XCTAssertTrue(CleanLockResolver.isLocked(
            ownerBundleID: nil, ownerAppName: nil,
            lockBundlePrefixes: jbRule.bundlePrefixes, lockProcessNames: jbRule.processNames, snapshot: snap))

        let larkRule = CleanRules.directoryLockRules["larkshell"]!
        XCTAssertTrue(CleanLockResolver.isLocked(
            ownerBundleID: nil, ownerAppName: nil,
            lockBundlePrefixes: larkRule.bundlePrefixes, lockProcessNames: larkRule.processNames, snapshot: snap))

        // 4. CLI 进程锁定（go / claude / cargo）
        XCTAssertTrue(CleanLockResolver.isLocked(
            ownerBundleID: nil, ownerAppName: nil,
            lockBundlePrefixes: [], lockProcessNames: ["go"], snapshot: snap))
        XCTAssertTrue(CleanLockResolver.isLocked(
            ownerBundleID: nil, ownerAppName: nil,
            lockBundlePrefixes: [], lockProcessNames: ["claude"], snapshot: snap))

        // 5. 未运行的应用不应误锁
        XCTAssertFalse(CleanLockResolver.isLocked(
            ownerBundleID: "com.other.stoppedapp", ownerAppName: "Stopped",
            lockBundlePrefixes: ["com.other.stoppedapp"], lockProcessNames: ["stopped"], snapshot: snap))
    }

    // MARK: - P0-3: 卸载残留防误报（递归子目录、内嵌扩展、同厂商关联、版本号排除、UUID 容器）

    func testRemnantDetectionPreventsFalsePositivesAndCoversExtendedLocations() {
        let appsRoot = tempHome.appendingPathComponent("Applications")
        // 嵌套子目录中的应用（如 Setapp / Chrome Apps / Vendor 子目录）
        writeBundle(at: "Applications/Setapp/NestedApp.app", bundleID: "com.setapp.nested", displayName: "Nested")
        // 内嵌 PlugIn / Helper 拥有不同 Bundle ID
        writeBundle(at: "Applications/Main.app", bundleID: "com.vendor.main", displayName: "Main")
        writeBundle(at: "Applications/Main.app/Contents/PlugIns/Share.appex", bundleID: "org.other.shareext")
        // Muse 场景：主 App 为 com.meta.endo，数据目录为 com.meta.prototypes.endo.tokens
        writeBundle(at: "Applications/Muse.app", bundleID: "com.meta.endo", displayName: "Muse")

        // 不应被误判为残留的目录
        _ = writeFile("Library/Containers/com.setapp.nested/Data/a.bin")
        _ = writeFile("Library/Containers/org.other.shareext/Data/a.bin")
        _ = writeFile("Library/Application Support/com.meta.prototypes.endo.tokens/transaction.lock")
        _ = writeFile("Library/Application Support/com.vendor.mainHelper/cfg.json")
        _ = writeFile("Library/Application Support/v1.2.3/data.bin")
        _ = writeFile("Library/Application Support/Google/Chrome/Default/Preferences")

        // 真实卸载残留（覆盖 Containers、UUID 容器、Application Support、Saved State、HTTPStorages、WebKit、Preferences）
        _ = writeFile("Library/Containers/com.removed.legacy/Data/x.bin")
        let uuidContainer = tempHome.appendingPathComponent("Library/Containers/2BDAA90A-0C56-44BD-81B0-AFD2E74199DC")
        _ = writeFile("Library/Containers/2BDAA90A-0C56-44BD-81B0-AFD2E74199DC/Data/x.bin")
        (["MCMMetadataIdentifier": "com.removed.uuidapp"] as NSDictionary)
            .write(to: uuidContainer.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"), atomically: true)
        _ = writeFile("Library/Application Support/com.removed.support/db.sqlite")
        _ = writeFile("Library/Saved Application State/com.removed.saved.savedState/data.data")
        _ = writeFile("Library/HTTPStorages/com.removed.http/httpstorages.sqlite")
        _ = writeFile("Library/WebKit/com.removed.web/WebsiteData")
        _ = writeFile("Library/Preferences/com.removed.pref.plist")

        let index = CleanScanner.buildAppIndex(home: tempHome, extraRoots: [appsRoot], useLaunchServices: false)
        let targets = CleanScanner.buildTargets(home: tempHome, appIndex: index, runningBundleIDs: [])
        let remnants = targets.filter { $0.category == .remnants }
        let remnantPaths = Set(remnants.map { $0.url.lastPathComponent })

        XCTAssertFalse(remnantPaths.contains("com.setapp.nested"), "子目录安装的 App 不得误判为残留")
        XCTAssertFalse(remnantPaths.contains("org.other.shareext"), "内嵌 PlugIn 不得误判为残留")
        XCTAssertFalse(remnantPaths.contains("com.meta.prototypes.endo.tokens"), "同厂商关联产品目录（Muse）不得误判为残留")
        XCTAssertFalse(remnantPaths.contains("com.vendor.mainHelper"), "Helper 变体不得误判为残留")
        XCTAssertFalse(remnantPaths.contains("v1.2.3"), "版本号目录不得误判为 Bundle ID 残留")
        XCTAssertFalse(remnantPaths.contains("Google"), "受保护 Application Support 顶层不得误判")

        XCTAssertTrue(remnantPaths.contains("com.removed.legacy"))
        XCTAssertTrue(remnantPaths.contains("2BDAA90A-0C56-44BD-81B0-AFD2E74199DC"))
        XCTAssertEqual(remnants.first { $0.url.lastPathComponent == "2BDAA90A-0C56-44BD-81B0-AFD2E74199DC" }?.ownerBundleID,
                       "com.removed.uuidapp")
        XCTAssertTrue(remnantPaths.contains("com.removed.support"))
        XCTAssertTrue(remnantPaths.contains("com.removed.saved.savedState"))
        XCTAssertTrue(remnantPaths.contains("com.removed.http"))
        XCTAssertTrue(remnantPaths.contains("com.removed.web"))
        XCTAssertTrue(remnantPaths.contains("com.removed.pref.plist"))
        XCTAssertTrue(remnants.allSatisfy { $0.safety == .review })
    }

    func testBundleIDLikeRejectsVersionNumbersAndSupportsTeamID() {
        XCTAssertTrue(CleanScanner.isBundleIDLike("com.tencent.xinWeChat"))
        XCTAssertTrue(CleanScanner.isBundleIDLike("5ZSL2CJU2T.com.dingtalk.mac.tblive"))
        XCTAssertFalse(CleanScanner.isBundleIDLike("v1.2.3"))
        XCTAssertFalse(CleanScanner.isBundleIDLike("1.2.3"))
        XCTAssertFalse(CleanScanner.isBundleIDLike("a.1.2"))
        XCTAssertFalse(CleanScanner.isBundleIDLike("only.two"))
    }

    // MARK: - P0-4: CleanPathGuard 祖先符号链接逃逸与敏感根目录保护

    func testPathGuardBlocksAncestorSymlinkEscapeAndAppSupportRoot() throws {
        // 造一个外部目录，把 ~/Library/Developer/Xcode 软链接指向外部目录
        let externalDerived = writeFile("DerivedData/precious.bin", under: tempOutside)
        let devRoot = tempHome.appendingPathComponent("Library/Developer", isDirectory: true)
        try fm.createDirectory(at: devRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: devRoot.appendingPathComponent("Xcode"), withDestinationURL: tempOutside)

        // 叶节点 DerivedData 本身不是 symlink，但祖先 Xcode 逃逸到了 tempHome 外部！
        let escapedTarget = tempHome.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        XCTAssertFalse(CleanPathGuard.isSymlink(escapedTarget))
        XCTAssertNotNil(CleanPathGuard.rejection(for: escapedTarget, home: tempHome),
                        "必须拒绝祖先路径通过符号链接逃逸到允许根之外的目标")
        XCTAssertTrue(fm.fileExists(atPath: externalDerived.path))

        // Application Support 顶层受保护目录（如 Google / Cursor）必须拒绝，但内部定点子缓存允许通过
        _ = writeFile("Library/Application Support/Google/Chrome/Default/Cache/c.bin")
        XCTAssertNotNil(CleanPathGuard.rejection(
            for: tempHome.appendingPathComponent("Library/Application Support/Google"), home: tempHome))
        XCTAssertNil(CleanPathGuard.rejection(
            for: tempHome.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cache"), home: tempHome))
        XCTAssertNotNil(CleanPathGuard.rejection(
            for: tempHome.appendingPathComponent("Library/Containers/com.docker.docker"), home: tempHome))
        XCTAssertNotNil(CleanPathGuard.rejection(
            for: tempHome.appendingPathComponent("Library/Preferences/com.apple.finder.plist"), home: tempHome))
    }

    // MARK: - P0-5: CleanNpmGC 多算法 SSRI 与 Fail-Closed 保护

    func testNpmGCMultiHashSSRIAndFailClosedOnCorruptIndex() async throws {
        let npm = tempHome.appendingPathComponent(".npm/_cacache")
        let payload = Data("multi-algo-package".utf8)
        let h512 = sri512(of: payload)
        let h1 = sri1(of: payload)
        let orphan = sri512(of: Data("orphan-blob".utf8))

        let blob512 = writeFile(".npm/_cacache/content-v2/\(h512.rel)", bytes: 1500)
        let blob1 = writeFile(".npm/_cacache/content-v2/\(h1.rel)", bytes: 1200)
        let blobOrphan = writeFile(".npm/_cacache/content-v2/\(orphan.rel)", bytes: 3000)
        let tmpFile = writeFile(".npm/_cacache/tmp/nested/part", bytes: 600)

        let idxFile = npm.appendingPathComponent("index-v5/aa/bb/entry")
        try fm.createDirectory(at: idxFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 多算法空格分隔 SSRI + JSON 键带空格
        let line = "deadbeef\t{ \"key\": \"k\", \"integrity\": \"\(h512.sri) \(h1.sri)\", \"time\": 1 }\n"
        try line.write(to: idxFile, atomically: true, encoding: .utf8)

        let ana = await CleanNpmGC.analyze(cacheRoot: npm)
        XCTAssertNotNil(ana)
        XCTAssertEqual(ana?.orphanCount, 1, "多算法 SSRI 引用的两个 blob 都必须保留")
        XCTAssertEqual(ana?.orphanBytes, 3000)
        XCTAssertEqual(ana?.tmpBytes, 600)
        XCTAssertEqual(ana?.reclaimableBytes, 3600)

        // 模拟坏索引文件（非法 UTF-8）-> 必须 Fail-Closed 返回 nil，绝不删任何有效 blob！
        let corruptIdx = npm.appendingPathComponent("index-v5/cc/dd/bad")
        try fm.createDirectory(at: corruptIdx.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: corruptIdx)

        let badAna = await CleanNpmGC.analyze(cacheRoot: npm)
        XCTAssertNil(badAna, "存在不可读/坏 UTF-8 索引时必须 Fail-Closed 返回 nil")
        let badGC = await CleanNpmGC.cleanup(cacheRoot: npm)
        XCTAssertNil(badGC, "存在坏索引时必须中止清理")
        XCTAssertTrue(fm.fileExists(atPath: blobOrphan.path), "Fail-Closed 中止后连孤儿也不得误动")

        // 移除坏索引后正常清理
        try fm.removeItem(at: corruptIdx)
        let gc = await CleanNpmGC.cleanup(cacheRoot: npm)
        XCTAssertEqual(gc?.removedBlobs, 1)
        XCTAssertEqual(gc?.removedTmp, 1)
        XCTAssertEqual(gc?.freedBytes, 3600)
        XCTAssertTrue(fm.fileExists(atPath: blob512.path))
        XCTAssertTrue(fm.fileExists(atPath: blob1.path))
        XCTAssertFalse(fm.fileExists(atPath: blobOrphan.path))
        XCTAssertFalse(fm.fileExists(atPath: tmpFile.path))
    }

    // MARK: - P0-6 & P2: 统一分类、安全分级与高价值覆盖（沙盒缓存、Chromium/Electron 子缓存、大依赖仓）

    func testUnifiedClassificationSafetyTiersAndExtendedCoverage() {
        let appsRoot = tempHome.appendingPathComponent("Applications")
        writeBundle(at: "Applications/WeChat.app", bundleID: "com.tencent.xinWeChat", displayName: "微信")

        // macOS ~/Library/Caches 中的开发/AI 工具应正确分类而非落入 App 缓存
        _ = writeFile("Library/Caches/go-build/a.bin")
        _ = writeFile("Library/Caches/pip/a.bin")
        _ = writeFile("Library/Caches/ms-playwright/chromium.bin")
        _ = writeFile("Library/Caches/JetBrains/index.bin")
        _ = writeFile("Library/Caches/puccinialin/rust.bin")
        _ = writeFile("Library/Caches/claude-cli-nodejs/a.bin")
        _ = writeFile(".cache/codex-runtimes/rt.bin")
        _ = writeFile(".cache/whisper/model.bin")
        _ = writeFile(".cache/modelscope/weights.bin")

        // 大依赖仓应全部为 .review（决策 1）
        _ = writeFile(".m2/repository/a.jar")
        _ = writeFile(".gradle/caches/a.bin")
        _ = writeFile(".gradle/wrapper/dists/a.zip")
        _ = writeFile(".cargo/registry/a.crate")
        _ = writeFile(".pub-cache/a.tar")
        _ = writeFile("Library/pnpm/store/v3/a.bin")
        _ = writeFile("Library/Developer/Xcode/Archives/a.xcarchive")

        // 新增快速构建/包缓存应为 .safe
        _ = writeFile(".bun/install/cache/a.bin")
        _ = writeFile(".npm/_npx/a.bin")
        _ = writeFile("Library/Developer/Xcode/watchOS DeviceSupport/a.bin")

        // 沙盒容器内缓存（已安装微信）
        _ = writeFile("Library/Containers/com.tencent.xinWeChat/Data/Library/Caches/img.dat")

        // Chromium / Electron Application Support 定点子缓存（决策 2：默认 .review）
        _ = writeFile("Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage/sw.bin")
        _ = writeFile("Library/Application Support/Cursor/CachedData/cd.bin")

        // DiagnosticReports -> .review
        _ = writeFile("Library/Logs/DiagnosticReports/crash.ips")

        // 手动管理大户
        _ = writeFile("Library/Developer/CoreSimulator/Devices/sim.bin")
        _ = writeFile("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        _ = writeFile(".lmstudio/models/m.gguf")

        let index = CleanScanner.buildAppIndex(home: tempHome, extraRoots: [appsRoot], useLaunchServices: false)
        let targets = CleanScanner.buildTargets(home: tempHome, appIndex: index, runningBundleIDs: [])
        func find(_ suffix: String) -> CleanScanner.Target? { targets.first { $0.url.path.hasSuffix(suffix) } }

        // 分类 & 安全等级验证
        XCTAssertEqual(find("Library/Caches/go-build")?.category, .developerTools)
        XCTAssertEqual(find("Library/Caches/go-build")?.safety, .safe)
        XCTAssertEqual(find("Library/Caches/pip")?.category, .developerTools)
        XCTAssertEqual(find("Library/Caches/puccinialin")?.category, .developerTools)
        XCTAssertEqual(find("Library/Caches/ms-playwright")?.category, .developerTools)
        XCTAssertEqual(find("Library/Caches/ms-playwright")?.safety, .review)
        XCTAssertEqual(find("Library/Caches/JetBrains")?.category, .developerTools)
        XCTAssertEqual(find("Library/Caches/JetBrains")?.safety, .review)
        XCTAssertEqual(find("Library/Caches/claude-cli-nodejs")?.category, .aiTools)
        XCTAssertEqual(find(".cache/codex-runtimes")?.category, .aiTools)
        XCTAssertEqual(find(".cache/codex-runtimes")?.safety, .review)
        XCTAssertEqual(find(".cache/whisper")?.safety, .review)
        XCTAssertNil(find(".cache/modelscope"), "modelscope 应归手动管理")

        // 决策 1：大依赖仓与 Archives 全部为 .review
        for reviewPath in [".m2/repository", ".gradle/caches", ".gradle/wrapper/dists",
                           ".cargo/registry", ".pub-cache", "Library/pnpm/store",
                           "Library/Developer/Xcode/Archives"] {
            XCTAssertEqual(find(reviewPath)?.safety, .review, "\(reviewPath) 应为 .review")
        }

        // 新增 .safe 开发缓存
        XCTAssertEqual(find(".bun/install/cache")?.safety, .safe)
        XCTAssertEqual(find(".npm/_npx")?.safety, .safe)
        XCTAssertEqual(find("Xcode/watchOS DeviceSupport")?.safety, .safe)

        // 沙盒应用缓存
        let wechatCache = find("com.tencent.xinWeChat/Data/Library/Caches")
        XCTAssertEqual(wechatCache?.category, .appCache)
        XCTAssertEqual(wechatCache?.safety, .safe)
        XCTAssertEqual(wechatCache?.ownerBundleID, "com.tencent.xinWeChat")
        XCTAssertEqual(wechatCache?.allowFinderFallback, false)

        // 决策 2：Chromium / Electron 定点子缓存为 .review 且绑定宿主锁定
        let chromeSW = find("Google/Chrome/Default/Service Worker/CacheStorage")
        XCTAssertEqual(chromeSW?.category, .appCache)
        XCTAssertEqual(chromeSW?.safety, .review)
        XCTAssertTrue(chromeSW?.lockBundlePrefixes.contains("com.google.Chrome") == true)

        let cursorCD = find("Cursor/CachedData")
        XCTAssertEqual(cursorCD?.category, .appCache)
        XCTAssertEqual(cursorCD?.safety, .review)

        // DiagnosticReports -> .review
        XCTAssertEqual(find("Library/Logs/DiagnosticReports")?.safety, .review)

        // 手动管理大户
        let manualNames = Set(CleanScanner.buildManualItems(home: tempHome).map(\.name))
        XCTAssertTrue(manualNames.contains("Xcode 模拟器设备"))
        XCTAssertTrue(manualNames.contains("Docker 磁盘镜像"))
        XCTAssertTrue(manualNames.contains("ModelScope 模型"))
        XCTAssertTrue(manualNames.contains("LM Studio 模型"))
    }

    // MARK: - P1: 空目录过滤 & 取消扫描不竞态

    @MainActor
    func testEmptyDirectoriesFilteredAndCancelPreventsStaleState() async throws {
        // 创建一个 0 字节空目录与一个有内容的目录
        try fm.createDirectory(at: tempHome.appendingPathComponent("Library/Caches/com.empty.zero"), withIntermediateDirectories: true)
        _ = writeFile("Library/Caches/com.nonempty.app/data.bin", bytes: 8192)

        let vm = CleanViewModel(home: tempHome, appIndexRoots: [])
        vm.scan()
        vm.cancel()
        XCTAssertFalse(vm.isScanning)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(vm.hasScanned, "取消后旧任务不得错误把 hasScanned 置为 true")

        // 重新扫描应正常完成，并过滤 0 字节空目录
        vm.scan()
        var waited = 0
        while vm.isScanning && waited < 200 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        XCTAssertTrue(vm.hasScanned)
        XCTAssertTrue(vm.items.contains { $0.url.lastPathComponent == "com.nonempty.app" })
        XCTAssertFalse(vm.items.contains { $0.url.lastPathComponent == "com.empty.zero" }, "0 字节空缓存目录应自动过滤")
    }
}
