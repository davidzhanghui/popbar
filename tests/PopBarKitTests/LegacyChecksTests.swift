import XCTest
@testable import PopBarKit

/// 原 tests/run.sh 编译运行的 851 项逻辑检查，现在由 `swift test` 驱动。
final class LegacyChecksTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        setvbuf(stdout, nil, _IOLBF, 0)   // 行缓冲：✓/✗ 输出不丢、不乱序
        // 指向临时目录，避免读写真实配置
        let dir = NSTemporaryDirectory() + "popbar-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("POPBAR_CONFIG_DIR", dir, 1)
    }

    @MainActor
    func testLegacyChecks() async throws {
        try await runLegacyMainChecks()
        await runExportPipelineTests()
        await runCleanTests()
        await runPrintTests()
        await runTVTests()
        print("\n========== 合计 \(checks) 项检查，\(failures) 项失败 ==========")
        XCTAssertEqual(failures, 0, "有 \(failures) 项检查失败，见上方 ✗ 行")
    }
}
