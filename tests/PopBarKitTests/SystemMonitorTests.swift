import XCTest
@testable import PopBarKit

final class SystemMonitorTests: XCTestCase {
    @MainActor
    func testBackgroundSamplerDoesNotOverflowStack() async throws {
        let model = SystemMonitorModel()
        model.start()
        defer { model.stop() }

        let deadline = Date().addingTimeInterval(5.0)
        while !model.snap.primed && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(model.snap.primed, "后台采样器应在超时前完成首轮采样")
        XCTAssertGreaterThan(model.snap.memPhys, 0, "物理内存应成功采集")
        XCTAssertFalse(model.snap.groups.isEmpty, "首轮应完成进程枚举与分组")
    }

    @MainActor
    func testSelectionServiceCancelPendingInvalidatesInFlightFetch() async {
        let exp = expectation(description: "cancelled fetch completes with nil")
        SelectionService.fetch(expectedPID: -1) { result in
            XCTAssertNil(result)
            exp.fulfill()
        }
        SelectionService.cancelPending()
        await fulfillment(of: [exp], timeout: 1.5)
    }

    @MainActor
    func testConfigStoreDetectsSameLengthExternalEditWithinOneSecond() async throws {
        let oldEnv = getenv("POPBAR_CONFIG_DIR").map { String(cString: $0) }
        let tmpDir = NSTemporaryDirectory() + "popbar-config-test-\(UUID().uuidString)"
        setenv("POPBAR_CONFIG_DIR", tmpDir, 1)
        defer {
            if let oldEnv {
                setenv("POPBAR_CONFIG_DIR", oldEnv, 1)
            } else {
                unsetenv("POPBAR_CONFIG_DIR")
            }
            try? FileManager.default.removeItem(atPath: tmpDir)
        }

        let store = ConfigStore()
        store.start()
        var c = store.config
        c.language = "zh"
        try store.save(c)

        // 模拟 1 秒内外部原地等长修改（"zh" -> "en"，文件字节数完全相同）
        let raw = try String(contentsOf: PopBarConfig.fileURL, encoding: .utf8)
        let mutated = raw.replacingOccurrences(of: "\"language\" : \"zh\"", with: "\"language\" : \"en\"")
        XCTAssertNotEqual(raw, mutated, "配置中应包含 language 字段")
        XCTAssertEqual(raw.utf8.count, mutated.utf8.count, "应构造等长文件以验证纳秒级 stat 判重")
        try mutated.write(to: PopBarConfig.fileURL, atomically: false, encoding: .utf8)

        let deadline = Date().addingTimeInterval(2.0)
        while store.config.language != "en" && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(store.config.language, "en", "同秒内外部等长改动不应被误判为自身写入")
    }
}
