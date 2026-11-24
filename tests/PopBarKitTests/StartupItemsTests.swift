import XCTest
@testable import PopBarKit

final class StartupItemsTests: XCTestCase {
    func testParseEmptyAndInvalidPlistReturnNil() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("popbar-startup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let emptyPlist = dir.appendingPathComponent("com.google.keystone.agent.plist")
        try ([:] as NSDictionary).write(to: emptyPlist)
        XCTAssertNil(StartupItems.parse(emptyPlist.path), "空字典 plist（如 keystone 占位文件）应返回 nil")

        let corruptPlist = dir.appendingPathComponent("corrupt.plist")
        try Data("not a plist".utf8).write(to: corruptPlist)
        XCTAssertNil(StartupItems.parse(corruptPlist.path), "损坏的 plist 应返回 nil")
    }

    func testParseRelativeWorkingDirectoryBundleProgramAndInterpreterScript() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("popbar-startup-parse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1) 相对路径 + WorkingDirectory + 按需触发
        let relPlist = dir.appendingPathComponent("rel.plist")
        try ([
            "Label": "yanue.v2rayu.v2ray-core",
            "ProgramArguments": ["./v2ray-core/v2ray", "-config", "config.json"],
            "WorkingDirectory": "/tmp/v2rayu",
            "RunAtLoad": false,
            "KeepAlive": false
        ] as NSDictionary).write(to: relPlist)
        let rel = StartupItems.parse(relPlist.path)
        XCTAssertEqual(rel?.program, "/tmp/v2rayu/v2ray-core/v2ray")
        XCTAssertEqual(rel?.trigger, .onDemand)

        // 2) BundleProgram 相对 .app 根目录
        let appContents = dir.appendingPathComponent("Demo.app/Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: appContents, withIntermediateDirectories: true)
        let bundlePlist = appContents.appendingPathComponent("com.demo.agent.plist")
        try ([
            "Label": "com.demo.agent",
            "BundleProgram": "Contents/MacOS/DemoHelper",
            "StartInterval": 3600,
            "LimitLoadToSessionType": "Background"
        ] as NSDictionary).write(to: bundlePlist)
        let bp = StartupItems.parse(bundlePlist.path)
        XCTAssertEqual(bp?.program, dir.appendingPathComponent("Demo.app/Contents/MacOS/DemoHelper").path)
        XCTAssertEqual(bp?.trigger, .scheduled)
        XCTAssertEqual(bp?.targetsBackgroundSession, true)

        // 3) 解释器脚本：/bin/sh 存在但脚本不存在应判损坏
        let scriptPlist = dir.appendingPathComponent("script.plist")
        try ([
            "Label": "com.demo.script",
            "ProgramArguments": ["/bin/sh", "/nonexistent/run.sh"],
            "RunAtLoad": true
        ] as NSDictionary).write(to: scriptPlist)
        let sp = try XCTUnwrap(StartupItems.parse(scriptPlist.path))
        XCTAssertEqual(sp.scriptPath, "/nonexistent/run.sh")
        XCTAssertEqual(sp.trigger, .atLogin)
        XCTAssertTrue(
            StartupItems.isBroken(sp, fileExists: { $0 == "/bin/sh" }, isInstalled: { _ in false }),
            "解释器存在但脚本文件缺失且无已安装关联应用时应判为损坏"
        )
    }

    func testParseDisabledAndRunningPIDs() {
        let disabledOut = """
        disabled services = {
            "com.foo.bar" => disabled
            "com.foo.baz" => enabled
            "com.foo.old" => true
            "com.foo.new" => false
        }
        """
        let map = StartupItems.parseDisabled(disabledOut)
        XCTAssertEqual(map["com.foo.bar"], true)
        XCTAssertEqual(map["com.foo.baz"], false)
        XCTAssertEqual(map["com.foo.old"], true)
        XCTAssertEqual(map["com.foo.new"], false)

        let listOut = """
        PID\tStatus\tLabel
        -\t0\tcom.idle.job
        570\t0\thomebrew.mxcl.postgresql@17
        1234\t-15\tcom.running.agent
        """
        let pids = StartupItems.parseRunningPIDs(listOut)
        XCTAssertNil(pids["com.idle.job"])
        XCTAssertEqual(pids["homebrew.mxcl.postgresql@17"], 570)
        XCTAssertEqual(pids["com.running.agent"], 1234)
    }

    func testParseBTMAndMergeOverridesAndModernItems() throws {
        let btmSample = """
        ========================
         Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
        ========================

         Items:

         #1:
                         UUID: 11111111-1111-1111-1111-111111111111
                         Name: com.docker.socket
               Developer Name: Docker Inc
                         Type: legacy daemon (0x10010)
                  Disposition: [enabled, disallowed, notified] (0x9)
                   Identifier: 16.com.docker.socket
                          URL: file:///Library/LaunchDaemons/com.docker.socket.plist
              Executable Path: /Library/PrivilegedHelperTools/com.docker.socket
            Embedded Item Identifiers:
            #1: 16.ignore.embedded

         #2:
                         UUID: 22222222-2222-2222-2222-222222222222
                         Name: com.netease.uuremote.agent
               Developer Name: Hangzhou Bobo
                         Type: legacy agent (0x10008)
                  Disposition: [enabled, allowed, not notified] (0x3)
                   Identifier: 8.com.netease.uuremote.agent
                          URL: file:///Library/LaunchAgents/com.netease.uuremote.agent.plist

        ========================
         Records for UID 501 : E6176039-DE82-4216-B54E-A3F08BBC9D4B
        ========================

         Items:

         #1:
                         UUID: 33333333-3333-3333-3333-333333333333
                         Name: com.netease.uuremote.agent
               Developer Name: Hangzhou Bobo
                         Type: legacy agent (0x10008)
                  Disposition: [enabled, disallowed, notified] (0x9)
                   Identifier: 8.com.netease.uuremote.agent
                          URL: file:///Library/LaunchAgents/com.netease.uuremote.agent.plist

         #2:
                         UUID: 44444444-4444-4444-4444-444444444444
                         Name: Cursor
               Developer Name: (null)
                         Type: app (0x2)
                  Disposition: [disabled, allowed, not notified] (0x2)
                   Identifier: 2.com.todesktop.230313mzl4w4u92
                          URL: file:///Applications/Cursor.app/

         #3:
                         UUID: 55555555-5555-5555-5555-555555555555
                         Name: true
               Developer Name: (null)
                         Type: agent (0x8)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 8.com.todesktop.230313mzl4w4u92.BackgroundActivityCheck
                          URL: Contents/Library/LaunchAgents/com.todesktop.230313mzl4w4u92.BackgroundActivityCheck.plist
            Parent Identifier: 2.com.todesktop.230313mzl4w4u92

         #4:
                         UUID: 66666666-6666-6666-6666-666666666666
                         Name: 夸克网盘
               Developer Name: (null)
                         Type: app (0x2)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 2.com.quark.clouddrive.desktop
                          URL: file:///Applications/QuarkCloudDrive.app/

         #5:
                         UUID: 77777777-7777-7777-7777-777777777777
                         Name: DockerHelper
               Developer Name: Docker
                         Type: login item (0x4)
                  Disposition: [enabled, disallowed, notified] (0x9)
                   Identifier: 4.com.docker.helper
                          URL: Contents/Library/LoginItems/DockerHelper.app
            Parent Identifier: 2.com.docker.docker

         #6:
                         UUID: 88888888-8888-8888-8888-888888888888
                         Name: Docker
               Developer Name: (null)
                         Type: app (0x2)
                  Disposition: [disabled, allowed, not notified] (0x2)
                   Identifier: 2.com.docker.docker
                          URL: file:///Applications/Docker.app/
        """

        let snap = StartupItems.parseBTM(btmSample, uid: 501)
        // 验证未将 Embedded Item 子行误解析为新记录，且相对路径已补全
        let cursorAgent = snap.records.first { $0.strippedIdentifier == "com.todesktop.230313mzl4w4u92.BackgroundActivityCheck" }
        XCTAssertEqual(cursorAgent?.urlPath, "/Applications/Cursor.app/Contents/Library/LaunchAgents/com.todesktop.230313mzl4w4u92.BackgroundActivityCheck.plist")

        let baseItems = [
            StartupItem(
                id: "/Library/LaunchDaemons/com.docker.socket.plist",
                label: "com.docker.socket",
                displayName: "com.docker.socket",
                kind: .launchDaemon,
                path: "/Library/LaunchDaemons/com.docker.socket.plist",
                enabled: true,
                btmDisallowed: false,
                systemLevel: true,
                managedBySystemSettings: false,
                targetsBackgroundSession: false,
                program: "/Library/PrivilegedHelperTools/com.docker.socket",
                sourceAppName: "Docker",
                sourceAppPath: "/Applications/Docker.app",
                developerName: nil,
                trigger: .atLogin,
                runningPID: nil,
                broken: false
            ),
            StartupItem(
                id: "/Library/LaunchAgents/com.netease.uuremote.agent.plist",
                label: "com.netease.uuremote.agent",
                displayName: "com.netease.uuremote.agent",
                kind: .launchAgent,
                path: "/Library/LaunchAgents/com.netease.uuremote.agent.plist",
                enabled: true,
                btmDisallowed: false,
                systemLevel: true,
                managedBySystemSettings: false,
                targetsBackgroundSession: false,
                program: "/Applications/UURemote.app/Contents/MacOS/UURemoteService",
                sourceAppName: "UURemote",
                sourceAppPath: "/Applications/UURemote.app",
                developerName: nil,
                trigger: .atLogin,
                runningPID: nil,
                broken: false
            )
        ]

        let merged = StartupItems.mergeBTM(
            baseItems,
            snap,
            runningPIDs: ["com.todesktop.230313mzl4w4u92.BackgroundActivityCheck": 999],
            fileExists: { _ in true },
            isInstalled: { _ in true }
        )

        let dockerSocket = try XCTUnwrap(merged.first { $0.label == "com.docker.socket" })
        XCTAssertTrue(dockerSocket.btmDisallowed)
        XCTAssertFalse(dockerSocket.effectiveEnabled)
        XCTAssertEqual(dockerSocket.developerName, "Docker Inc")

        // UID 501 的 disallowed 应覆盖 UID -2 的 allowed
        let uuAgent = try XCTUnwrap(merged.first { $0.label == "com.netease.uuremote.agent" })
        XCTAssertTrue(uuAgent.btmDisallowed)
        XCTAssertFalse(uuAgent.effectiveEnabled)

        // 启用的 App 登录项应被补全，禁用的 App（Cursor/Docker 本体）不应作为已启用的登录项出现
        XCTAssertNotNil(merged.first { $0.label == "com.quark.clouddrive.desktop" && $0.kind == .loginItem })
        XCTAssertNil(merged.first { $0.label == "com.todesktop.230313mzl4w4u92" })

        // 应用内嵌服务和 LoginItem Helper 应被补全，且 Name 为 "true" 时回退到父应用名 Cursor
        let embeddedAgent = try XCTUnwrap(merged.first { $0.label == "com.todesktop.230313mzl4w4u92.BackgroundActivityCheck" })
        XCTAssertEqual(embeddedAgent.kind, .appAgent)
        XCTAssertEqual(embeddedAgent.displayName, "Cursor")
        XCTAssertEqual(embeddedAgent.runningPID, 999)

        let dockerHelper = try XCTUnwrap(merged.first { $0.label == "com.docker.helper" })
        XCTAssertEqual(dockerHelper.kind, .loginItem)
        XCTAssertTrue(dockerHelper.btmDisallowed)
        XCTAssertFalse(dockerHelper.effectiveEnabled)
    }

    @MainActor
    func testViewModelFilteringAndSyncingDuplicateLabels() {
        let vm = StartupViewModel()
        vm.items = [
            StartupItem(
                id: "/Users/test/Library/LaunchAgents/a.plist",
                label: "com.dup.agent",
                displayName: "Dup Agent",
                kind: .launchAgent,
                path: "/Users/test/Library/LaunchAgents/a.plist",
                enabled: true,
                btmDisallowed: false,
                systemLevel: false,
                managedBySystemSettings: false,
                targetsBackgroundSession: false,
                program: "/usr/local/bin/dup",
                sourceAppName: "MyApp",
                sourceAppPath: "/Applications/MyApp.app",
                developerName: nil,
                trigger: .atLogin,
                runningPID: nil,
                broken: false
            ),
            StartupItem(
                id: "/Users/test/Library/LaunchAgents/b.plist",
                label: "com.dup.agent",
                displayName: "Dup Agent Copy",
                kind: .launchAgent,
                path: "/Users/test/Library/LaunchAgents/b.plist",
                enabled: true,
                btmDisallowed: false,
                systemLevel: false,
                managedBySystemSettings: false,
                targetsBackgroundSession: false,
                program: "/usr/local/bin/dup",
                sourceAppName: "MyApp",
                sourceAppPath: nil,
                developerName: nil,
                trigger: .onDemand,
                runningPID: nil,
                broken: true
            ),
            StartupItem(
                id: "btm:app:com.app.login",
                label: "com.app.login",
                displayName: "Quark",
                kind: .loginItem,
                path: "/Applications/Quark.app",
                enabled: true,
                btmDisallowed: false,
                systemLevel: false,
                managedBySystemSettings: true,
                targetsBackgroundSession: false,
                program: nil,
                sourceAppName: "Quark",
                sourceAppPath: "/Applications/Quark.app",
                developerName: nil,
                trigger: .atLogin,
                runningPID: nil,
                broken: false
            )
        ]

        // 同 Label 同步更新
        vm.applyEnabled(false, forLabel: "com.dup.agent")
        XCTAssertEqual(vm.items.filter { $0.label == "com.dup.agent" }.map(\.enabled), [false, false])

        // 筛选：已停用 / 异常 / 登录项 / 搜索来源应用
        vm.filter = .disabled
        XCTAssertEqual(vm.filtered.count, 2)

        vm.filter = .broken
        XCTAssertEqual(vm.filtered.count, 1)

        vm.filter = .loginItems
        XCTAssertEqual(vm.filtered.map(\.label), ["com.app.login"])

        vm.filter = .all
        vm.query = "MyApp"
        XCTAssertEqual(vm.filtered.count, 2)
    }
}
