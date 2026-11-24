import XCTest
@testable import PopBarKit

final class MaintenanceTests: XCTestCase {
    func testParseLocalSnapshotsFiltersOSUpdatesAndFindsLatestDate() {
        let output = """
        Snapshots for disk /:
        com.apple.os.update-0123456789ABCDEF
        com.apple.TimeMachine.2026-11-20-091500.local
        com.apple.TimeMachine.2026-11-24-083012.local
        com.apple.TimeMachine.2026-11-22-235959.local

        """
        let parsed = Maintenance.parseLocalSnapshots(output)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed.latestDate, "2026-11-24 08:30")

        let empty = Maintenance.parseLocalSnapshots("Snapshots for disk /:\ncom.apple.os.update-ABC\n")
        XCTAssertEqual(empty.count, 0)
        XCTAssertNil(empty.latestDate)
    }

    func testParseThinnedSnapshotCount() {
        let out = """
        Thinned local snapshots:
        com.apple.TimeMachine.2026-11-20-091500.local
        com.apple.TimeMachine.2026-11-22-235959.local
        """
        XCTAssertEqual(Maintenance.parseThinnedSnapshotCount(out), 2)
        XCTAssertEqual(Maintenance.parseThinnedSnapshotCount(""), 0)
    }

    func testParseSpotlightEnabled() {
        XCTAssertEqual(Maintenance.parseSpotlightEnabled("/:\n\tIndexing enabled. \n"), true)
        XCTAssertEqual(Maintenance.parseSpotlightEnabled("/:\n\tIndexing disabled.\n"), false)
        XCTAssertNil(Maintenance.parseSpotlightEnabled("Unknown output"))
    }

    func testAdminCancellationAndErrorCleaning() {
        XCTAssertTrue(ShellRun.isAdminCancelled("37:112: execution error: User canceled. (-128)\n"))
        XCTAssertFalse(ShellRun.isAdminCancelled("execution error: Exit code -128 failed (1)"))
        XCTAssertFalse(ShellRun.isAdminCancelled("(-128) something else"))

        XCTAssertEqual(
            ShellRun.cleanAdminError("37:112: execution error: Operation not permitted (1)\n"),
            "Operation not permitted"
        )
        XCTAssertEqual(
            ShellRun.cleanAdminError("execution error: Something failed (-2700)"),
            "Something failed"
        )
    }

    func testBuildAdminScriptEscapingAndRejectingNewlines() {
        let script = ShellRun.buildAdminScript(
            shell: "/bin/echo \"hi\" \\ test",
            prompt: "PopBar 需要管理员权限"
        )
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.contains("with prompt \"PopBar 需要管理员权限\""))
        XCTAssertTrue(script!.contains("\\\"hi\\\" \\\\ test"))

        XCTAssertNil(ShellRun.buildAdminScript(shell: "echo 1\nrm -rf /", prompt: nil))
        XCTAssertNil(ShellRun.buildAdminScript(shell: "echo 1\recho 2", prompt: nil))
    }

    func testLocalSnapshotStateHandlesFailureExplicitly() {
        let failExec = MaintenanceExecutor(
            run: { _, _, _ in (1, "", "tmutil permission error") },
            runAsAdmin: { _, _, _ in .cancelled }
        )
        XCTAssertEqual(Maintenance.localSnapshotState(executor: failExec), .failed("tmutil permission error"))
    }

    func testFlushDNSUsesAndChainingAndPropagatesCancelOrFailure() {
        var recordedCmd = ""
        let okExec = MaintenanceExecutor(
            run: { _, _, _ in (0, "", "") },
            runAsAdmin: { cmd, prompt, _ in
                recordedCmd = cmd
                XCTAssertNotNil(prompt)
                return .success(output: "")
            }
        )
        if case .success(let detail) = Maintenance.run(.flushDNS, executor: okExec) {
            XCTAssertNotNil(detail)
        } else {
            XCTFail("flushDNS 应成功")
        }
        XCTAssertTrue(recordedCmd.contains("dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"))

        let cancelExec = MaintenanceExecutor(
            run: { _, _, _ in (0, "", "") },
            runAsAdmin: { _, _, _ in .cancelled }
        )
        XCTAssertEqual(Maintenance.run(.flushDNS, executor: cancelExec), .cancelled)
    }

    func testSpotlightDisabledDoesNotReportFalseSuccess() {
        let disabledExec = MaintenanceExecutor(
            run: { path, args, _ in
                if path == "/usr/bin/mdutil" && args == ["-s", "/"] {
                    return (0, "/:\n\tIndexing disabled.\n", "")
                }
                return (0, "", "")
            },
            runAsAdmin: { _, _, _ in .success(output: "") }
        )
        if case .failure = Maintenance.run(.reindexSpotlight, enableSpotlightIfDisabled: false, executor: disabledExec) {
            // expected
        } else {
            XCTFail("Spotlight 禁用时未传 enableSpotlightIfDisabled 不应假成功")
        }

        // 即使跳过预检直接执行 mdutil -E /，若输出明确说 Indexing disabled 也应失败
        var ranEnableCmd = ""
        let enableExec = MaintenanceExecutor(
            run: { _, _, _ in (0, "", "") },
            runAsAdmin: { cmd, _, _ in
                ranEnableCmd = cmd
                return .success(output: "/:\n\tIndexing enabled.\n")
            }
        )
        if case .success = Maintenance.run(.reindexSpotlight, enableSpotlightIfDisabled: true, executor: enableExec) {
            XCTAssertEqual(ranEnableCmd, "/usr/bin/mdutil -i on / && /usr/bin/mdutil -E /")
        } else {
            XCTFail("开启索引并重建应成功")
        }
    }

    func testQuickLookAndLaunchServicesRunTwoStepsAndAbortOnFirstFailure() {
        var calls: [[String]] = []
        let qlFailFirst = MaintenanceExecutor(
            run: { path, args, _ in
                calls.append([path] + args)
                return (1, "", "qlmanage reload failed")
            },
            runAsAdmin: { _, _, _ in .cancelled }
        )
        XCTAssertEqual(Maintenance.run(.resetQuickLook, executor: qlFailFirst), .failure("qlmanage reload failed"))
        XCTAssertEqual(calls.count, 1)

        calls.removeAll()
        let qlBothOK = MaintenanceExecutor(
            run: { path, args, _ in
                calls.append([path] + args)
                return (0, "", "")
            },
            runAsAdmin: { _, _, _ in .cancelled }
        )
        if case .success = Maintenance.run(.resetQuickLook, executor: qlBothOK) {
            XCTAssertEqual(calls, [
                ["/usr/bin/qlmanage", "-r"],
                ["/usr/bin/qlmanage", "-r", "cache"]
            ])
        } else {
            XCTFail("QuickLook 两步应都成功")
        }

        calls.removeAll()
        let lsBothOK = MaintenanceExecutor(
            run: { path, args, _ in
                calls.append([path] + args)
                return (0, "", "")
            },
            runAsAdmin: { _, _, _ in .cancelled }
        )
        if case .success = Maintenance.run(.rebuildLaunchServices, executor: lsBothOK) {
            XCTAssertEqual(calls.map { Array($0.dropFirst()) }, [["-gc"], ["-apps", "u,l,s"]])
        } else {
            XCTFail("LaunchServices 两步应都成功")
        }
    }

    func testThinSnapshotsReportsRemovedAndRemainingCounts() {
        var listCalls = 0
        let exec = MaintenanceExecutor(
            run: { path, args, _ in
                if path == "/usr/bin/tmutil" && args == ["listlocalsnapshots", "/"] {
                    listCalls += 1
                    if listCalls == 1 {
                        return (0, "com.apple.TimeMachine.2026-11-24-080000.local\ncom.apple.TimeMachine.2026-11-24-090000.local\n", "")
                    }
                    return (0, "com.apple.TimeMachine.2026-11-24-090000.local\n", "")
                }
                return (0, "", "")
            },
            runAsAdmin: { _, _, _ in
                .success(output: "Thinned local snapshots:\ncom.apple.TimeMachine.2026-11-24-080000.local\n")
            }
        )
        if case .success(let detail) = Maintenance.run(.thinSnapshots, executor: exec) {
            XCTAssertNotNil(detail)
            XCTAssertTrue(detail!.contains("1"))
        } else {
            XCTFail("thinSnapshots 应返回成功详情")
        }
    }

    @MainActor
    func testViewModelClearsOldResultAndHandlesCancelledWithoutFailure() async throws {
        let exec = MaintenanceExecutor(
            run: { path, args, _ in
                if path == "/usr/bin/qlmanage" && args == ["-r"] {
                    return (1, "", "boom")
                }
                return (0, "", "")
            },
            runAsAdmin: { _, _, _ in .cancelled }
        )
        let vm = MaintenanceViewModel(executor: exec)
        let qlTask = Maintenance.tasks.first { $0.id == .resetQuickLook }!
        vm.run(qlTask)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(vm.results[.resetQuickLook], .failure("boom"))

        let dnsTask = Maintenance.tasks.first { $0.id == .flushDNS }!
        vm.run(dnsTask)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(vm.results[.flushDNS], .cancelled)
    }
}
