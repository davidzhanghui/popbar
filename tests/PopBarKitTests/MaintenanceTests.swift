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
        // AppleScript 默认可能以 \r 分隔行，解析函数也应正确识别多行
        let crOut = "Thinned local snapshots:\rcom.apple.TimeMachine.2026-11-20-091500.local\rcom.apple.TimeMachine.2026-11-22-235959.local\rcom.apple.TimeMachine.2026-11-24-083012.local"
        XCTAssertEqual(Maintenance.parseThinnedSnapshotCount(crOut), 3)
        // 部分 macOS 版本仅输出纯时间戳行
        let dateOnlyOut = "Thinned local snapshots:\n2026-11-20-091500\n2026-11-22-235959\n"
        XCTAssertEqual(Maintenance.parseThinnedSnapshotCount(dateOnlyOut), 2)
        XCTAssertEqual(Maintenance.parseThinnedSnapshotCount(""), 0)
    }

    func testParseSpotlightEnabled() {
        XCTAssertEqual(Maintenance.parseSpotlightEnabled("/:\n\tIndexing enabled. \n"), true)
        XCTAssertEqual(Maintenance.parseSpotlightEnabled("/:\n\tIndexing disabled.\n"), false)
        XCTAssertEqual(Maintenance.parseSpotlightEnabled("/:\n\tIndexing and searching disabled.\n"), false)
        XCTAssertEqual(
            Maintenance.parseSpotlightEnabled("/:\n\tIndexing and searching disabled because of \".metadata_never_index\" file at root of volume.\n"),
            false
        )
        // 串联命令输出多行状态时应取最后一行最终状态
        XCTAssertEqual(Maintenance.parseSpotlightEnabled("/:\n\tIndexing enabled.\n/:\n\tIndexing disabled.\n"), false)
        XCTAssertEqual(Maintenance.parseSpotlightEnabled("/:\n\tIndexing disabled.\n/:\n\tIndexing enabled.\n"), true)
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
        XCTAssertTrue(script!.hasSuffix("without altering line endings"))

        let noPrompt = ShellRun.buildAdminScript(shell: "/bin/echo ok", prompt: nil)
        XCTAssertEqual(
            noPrompt,
            "do shell script \"/bin/echo ok\" with administrator privileges without altering line endings"
        )

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
                    return (0, "/:\n\tIndexing and searching disabled.\n", "")
                }
                return (0, "", "")
            },
            runAsAdmin: { _, _, _ in .success(output: "") }
        )
        XCTAssertEqual(Maintenance.spotlightState(executor: disabledExec), .disabled)
        if case .failure = Maintenance.run(.reindexSpotlight, enableSpotlightIfDisabled: false, executor: disabledExec) {
            // expected
        } else {
            XCTFail("Spotlight 禁用（含 Indexing and searching disabled）时不应假成功")
        }

        // 即使 enableSpotlightIfDisabled == true，若存在 .metadata_never_index 导致依然禁用也应报错而非假成功
        let lockedDisabledExec = MaintenanceExecutor(
            run: { _, _, _ in (0, "", "") },
            runAsAdmin: { _, _, _ in
                .success(output: "/:\n\tIndexing and searching disabled because of \".metadata_never_index\" file at root of volume.\n")
            }
        )
        if case .failure(let msg) = Maintenance.run(.reindexSpotlight, enableSpotlightIfDisabled: true, executor: lockedDisabledExec) {
            XCTAssertTrue(msg.contains(".metadata_never_index"))
        } else {
            XCTFail("存在 .metadata_never_index 导致开启失败时不应假成功")
        }

        // mdutil 输出 Error: 且无 enabled 状态时也不应假成功
        let errorOutExec = MaintenanceExecutor(
            run: { _, _, _ in (0, "/:\n\tIndexing enabled.\n", "") },
            runAsAdmin: { _, _, _ in .success(output: "/:\n\tError: unable to perform operation.\n") }
        )
        if case .failure(let msg) = Maintenance.run(.reindexSpotlight, enableSpotlightIfDisabled: false, executor: errorOutExec) {
            XCTAssertTrue(msg.localizedCaseInsensitiveContains("Error:"))
        } else {
            XCTFail("mdutil 输出 Error: 时不应假成功")
        }

        // 正常开启索引并重建应成功
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
            runAsAdmin: { _, _, _ in .cancelled },
            currentUser: "alice"
        )
        XCTAssertEqual(Maintenance.run(.resetQuickLook, executor: qlFailFirst), .failure("qlmanage reload failed"))
        XCTAssertEqual(calls.count, 1)

        calls.removeAll()
        let qlBothOK = MaintenanceExecutor(
            run: { path, args, _ in
                calls.append([path] + args)
                // ThumbnailsAgent 未运行时也不影响成功
                if path == "/usr/bin/killall" {
                    return (1, "", "No matching processes belonging to you were found")
                }
                return (0, "", "")
            },
            runAsAdmin: { _, _, _ in .cancelled },
            currentUser: "alice"
        )
        if case .success = Maintenance.run(.resetQuickLook, executor: qlBothOK) {
            XCTAssertEqual(calls, [
                ["/usr/bin/qlmanage", "-r"],
                ["/usr/bin/qlmanage", "-r", "cache"],
                ["/usr/bin/killall", "-u", "alice", "com.apple.quicklook.ThumbnailsAgent"]
            ])
        } else {
            XCTFail("QuickLook 应成功并尝试刷新当前用户的 ThumbnailsAgent")
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

    func testRestartFinderAndDockScopesToCurrentUserAndAudioUsesLaunchctlKickstart() {
        var calls: [[String]] = []
        let finderExec = MaintenanceExecutor(
            run: { path, args, _ in
                calls.append([path] + args)
                return (0, "", "")
            },
            runAsAdmin: { _, _, _ in .cancelled },
            currentUser: "david"
        )
        if case .success = Maintenance.run(.restartFinderAndDock, executor: finderExec) {
            XCTAssertEqual(calls, [
                ["/usr/bin/killall", "-u", "david", "Finder"],
                ["/usr/bin/killall", "-u", "david", "Dock"]
            ])
        } else {
            XCTFail("restartFinderAndDock 应成功")
        }

        var audioCmd = ""
        let audioExec = MaintenanceExecutor(
            run: { _, _, _ in (0, "", "") },
            runAsAdmin: { cmd, _, _ in
                audioCmd = cmd
                return .success(output: "service spawned with pid: 12345\n")
            }
        )
        if case .success = Maintenance.run(.restartAudio, executor: audioExec) {
            XCTAssertEqual(audioCmd, "/bin/launchctl kickstart -kp system/com.apple.audio.coreaudiod")
        } else {
            XCTFail("restartAudio 应使用 launchctl kickstart 并成功")
        }
        let audioTask = Maintenance.tasks.first { $0.id == .restartAudio }
        XCTAssertEqual(audioTask?.confirmKind, .standard)
    }

    func testThinSnapshotsReportsRemovedRemainingAndUnfreedCases() {
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

        // 未释放任何快照但仍有剩余时应提示占用说明
        let busyExec = MaintenanceExecutor(
            run: { path, args, _ in
                if path == "/usr/bin/tmutil" && args == ["listlocalsnapshots", "/"] {
                    return (0, "com.apple.TimeMachine.2026-11-24-080000.local\ncom.apple.TimeMachine.2026-11-24-090000.local\n", "")
                }
                return (0, "", "")
            },
            runAsAdmin: { _, _, _ in .success(output: "Thinned local snapshots:\n") }
        )
        if case .success(let detail) = Maintenance.run(.thinSnapshots, executor: busyExec) {
            XCTAssertNotNil(detail)
            XCTAssertTrue(detail!.contains("2"))
            XCTAssertTrue(detail!.contains("Time Machine"))
        } else {
            XCTFail("未释放但仍有剩余时应给出清晰说明")
        }
    }

    @MainActor
    func testViewModelClearsOldResultAndHandlesCancelledWithoutReloading() async throws {
        var probeCount = 0
        let exec = MaintenanceExecutor(
            run: { path, args, _ in
                if path == "/usr/bin/tmutil" || path == "/usr/bin/mdutil" {
                    probeCount += 1
                }
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

        let spotTask = Maintenance.tasks.first { $0.id == .reindexSpotlight }!
        vm.run(spotTask)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(vm.results[.reindexSpotlight], .cancelled)
        // 仅因预检调用 1 次 mdutil -s /，取消后不应额外触发 load()（2 次探测）
        XCTAssertEqual(probeCount, 1)
    }
}
