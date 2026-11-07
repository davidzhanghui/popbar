import XCTest
@testable import PopBarCore

/// 迁移自 Decklet `shell.rs` / `extensions.rs` 的三个用例，外加 SIGPIPE、截断与启动失败。
final class ShellTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        Shell.ignoreSIGPIPE()
    }

    /// stdout、stderr 同时写满几 MB 也不会互相卡死（以前 >64KB 就卡到超时）
    func testBigStdoutAndStderrDoNotDeadlock() {
        let start = Date()
        let o = Shell.sh("yes out | head -c 3000000; yes err | head -c 3000000 1>&2", timeout: 10)
        XCTAssertEqual(o.status, .exited(0))
        XCTAssertEqual(o.stdout.count, 3_000_000)
        XCTAssertFalse(o.truncated)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// 文档验收：扩展脚本 `yes | head -c 1000000` 在 1 秒内返回
    func testMegabyteOutputReturnsQuickly() {
        let start = Date()
        let o = Shell.sh("yes | head -c 1000000", timeout: 10)
        XCTAssertTrue(o.ok)
        XCTAssertEqual(o.stdout.count, 1_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    /// 超时杀掉整个进程组：脚本派生出来的子进程也一起结束
    func testTimeoutKillsGroup() {
        let marker = NSTemporaryDirectory() + "popbar-shell-\(UUID().uuidString)"
        let start = Date()
        // 子进程 sleep 2 秒后写文件；整组被杀则文件不会出现
        let o = Shell.sh("(sleep 2; touch '\(marker)') & sleep 30", timeout: 0.5)
        XCTAssertEqual(o.status, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "子进程没有随进程组一起结束")
    }

    /// 文本只走 stdin，不会被当成命令执行
    func testShellReadsStdinWithoutInjection() {
        let evil = "$(touch /tmp/popbar-pwned); `id`; echo hi"
        let o = Shell.sh("cat", stdin: Data(evil.utf8), timeout: 5)
        XCTAssertTrue(o.ok)
        XCTAssertEqual(o.text, evil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/popbar-pwned"))
    }

    /// 文档验收：脚本 `exit 0`（不读 stdin）而 stdin 有 1MB 时，App 不退出（SIGPIPE 已忽略）
    func testScriptIgnoringLargeStdinDoesNotCrash() {
        let big = Data(repeating: 0x61, count: 1 << 20)
        let o = Shell.sh("exit 0", stdin: big, timeout: 5)
        XCTAssertEqual(o.status, .exited(0))
    }

    func testOutputIsTruncatedAtLimit() {
        let o = Shell.sh("yes | head -c 200000", timeout: 5, maxOutput: 1000)
        XCTAssertTrue(o.ok)
        XCTAssertEqual(o.stdout.count, 1000)
        XCTAssertTrue(o.truncated)
    }

    func testEnvironmentAndExitCode() {
        let o = Shell.sh("printf %s \"$POPBAR_TEXT\"; echo oops 1>&2; exit 3", environment: ["POPBAR_TEXT": "你好"])
        XCTAssertEqual(o.status, .exited(3))
        XCTAssertEqual(o.code, 3)
        XCTAssertEqual(o.text, "你好")
        XCTAssertEqual(o.stderr, "oops")
        XCTAssertEqual(o.error, "oops")
    }

    func testSpawnFailure() {
        let o = Shell.run("/nonexistent/popbar-bin", [])
        if case .spawnFailed = o.status {} else { XCTFail("应为启动失败，得到 \(o.status)") }
        XCTAssertEqual(o.code, -1)
    }

    func testQuote() {
        XCTAssertEqual(Shell.quote("a'b"), "'a'\\''b'")
        let o = Shell.sh("printf %s " + Shell.quote("it's $HOME"))
        XCTAssertEqual(o.text, "it's $HOME")
    }
}
