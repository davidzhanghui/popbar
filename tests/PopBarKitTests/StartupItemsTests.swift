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

        // 启用的 App 登录项应被补全且允许直接操作，禁用的 App（Cursor/Docker 本体）不应作为已启用的登录项出现
        let quark = try XCTUnwrap(merged.first { $0.label == "com.quark.clouddrive.desktop" })
        XCTAssertEqual(quark.kind, .loginItem)
        XCTAssertTrue(quark.canToggle, "登录时打开的 App 应允许直接开关（通过 System Events 管理）")
        XCTAssertNil(merged.first { $0.label == "com.todesktop.230313mzl4w4u92" })

        // 应用内嵌服务和 LoginItem Helper 应归入后台服务分类（对应系统设置「App 后台活动」），不混入「登录项」
        let embeddedAgent = try XCTUnwrap(merged.first { $0.label == "com.todesktop.230313mzl4w4u92.BackgroundActivityCheck" })
        XCTAssertEqual(embeddedAgent.kind, .appAgent)
        XCTAssertEqual(embeddedAgent.displayName, "Cursor")
        XCTAssertEqual(embeddedAgent.runningPID, 999)

        let dockerHelper = try XCTUnwrap(merged.first { $0.label == "com.docker.helper" })
        XCTAssertEqual(dockerHelper.kind, .appLoginHelper)
        XCTAssertTrue(dockerHelper.kind.isService, "应用内嵌 LoginItem Helper 应归入后台服务，避免与系统设置「登录时打开」数量不一致")
        XCTAssertTrue(dockerHelper.btmDisallowed)
        XCTAssertFalse(dockerHelper.effectiveEnabled)
        XCTAssertFalse(dockerHelper.canToggle)
    }

    func testLoginItemPathNormalizationAndPermissionDetection() {
        XCTAssertEqual(StartupItems.normalizedLoginItemPath("/Applications/QuarkCloudDrive.app/"), "/Applications/QuarkCloudDrive.app")
        XCTAssertEqual(StartupItems.normalizedLoginItemPath("/Applications/QuarkCloudDrive.app///"), "/Applications/QuarkCloudDrive.app")
        XCTAssertEqual(StartupItems.normalizedLoginItemPath("/"), "/")

        XCTAssertTrue(StartupItems.isAutomationPermissionDenied("execution error: Not authorized to send Apple events to System Events. (-1743)"))
        XCTAssertTrue(StartupItems.isAutomationPermissionDenied("some error (-1743)"))
        XCTAssertFalse(StartupItems.isAutomationPermissionDenied("execution error: User canceled. (-128)"))

        XCTAssertTrue(StartupItems.isSelfApp(label: "dev.popbar.app", path: "/Applications/Other.app", currentBundleID: "dev.popbar.app", currentBundlePath: "/Applications/PopBar.app"))
        XCTAssertTrue(StartupItems.isSelfApp(label: "other.id", path: "/Applications/PopBar.app/", currentBundleID: "dev.popbar.app", currentBundlePath: "/Applications/PopBar.app"))
        XCTAssertFalse(StartupItems.isSelfApp(label: "com.quark.clouddrive.desktop", path: "/Applications/QuarkCloudDrive.app", currentBundleID: "dev.popbar.app", currentBundlePath: "/Applications/PopBar.app"))

        // 提权 launchctl 的 label 安全校验
        XCTAssertTrue(StartupItems.isSafeLaunchdLabel("yanue.v2rayu.tun-helper"))
        XCTAssertTrue(StartupItems.isSafeLaunchdLabel("homebrew.mxcl.postgresql@17"))
        XCTAssertFalse(StartupItems.isSafeLaunchdLabel(""))
        XCTAssertFalse(StartupItems.isSafeLaunchdLabel("bad; rm -rf /"))
        XCTAssertFalse(StartupItems.isSafeLaunchdLabel("bad/label"))
    }

    func testGroupingAlignsWithMacOSBackgroundActivityCountAndNaming() throws {
        let btmSample = """
        ========================
         Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
        ========================

         Items:

         #1:
                         UUID: A1
                         Name: sing-box-arm64
               Developer Name: (null)
                         Type: legacy daemon (0x10010)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 16.yanue.v2rayu.tun-helper
                          URL: file:///Library/LaunchDaemons/yanue.v2rayu.tun-helper.plist
              Executable Path: /usr/local/v2rayu/bin/sing-box/sing-box-arm64
            Parent Identifier: Unknown Developer

         #2:
                         UUID: A2
                         Name: Docker
               Developer Name: Docker
                         Type: developer (0x20)
                  Disposition: [disabled, allowed, not notified] (0x2)
                   Identifier: Docker
                          URL: (null)

         #3:
                         UUID: A3
                         Name: com.docker.vmnetd
               Developer Name: Docker
                         Type: legacy daemon (0x10010)
                  Disposition: [enabled, disallowed, notified] (0x9)
                   Identifier: 16.com.docker.vmnetd
                          URL: file:///Library/LaunchDaemons/com.docker.vmnetd.plist
            Assoc. Bundle IDs: [ com.docker.docker ]
            Parent Identifier: Docker

         #4:
                         UUID: A4
                         Name: Docker
               Developer Name: (null)
                         Type: app (0x2)
                  Disposition: [disabled, allowed, not notified] (0x2)
                   Identifier: 2.com.docker.docker
                          URL: file:///Applications/Docker.app/

         #5:
                         UUID: A5
                         Name: com.docker.socket
               Developer Name: Docker Inc
                         Type: legacy daemon (0x10010)
                  Disposition: [enabled, disallowed, notified] (0x9)
                   Identifier: 16.com.docker.socket
                          URL: file:///Library/LaunchDaemons/com.docker.socket.plist
            Parent Identifier: 2.com.docker.docker

         #6:
                         UUID: A6
                         Name: UU远程
               Developer Name: (null)
                         Type: app (0x2)
                  Disposition: [disabled, allowed, not notified] (0x2)
                   Identifier: 2.com.netease.uuremote
                          URL: file:///Applications/UURemote.app/

         #7:
                         UUID: A7
                         Name: UU远程
               Developer Name: Hangzhou Bobo
                         Type: legacy daemon (0x10010)
                  Disposition: [enabled, disallowed, notified] (0x9)
                   Identifier: 16.com.netease.uuremote.daemon
                          URL: file:///Library/LaunchDaemons/com.netease.uuremote.daemon.plist
            Parent Identifier: 2.com.netease.uuremote

        ========================
         Records for UID 501 : E6176039-DE82-4216-B54E-A3F08BBC9D4B
        ========================

         Items:

         #1:
                         UUID: B1
                         Name: DockerHelper
               Developer Name: Docker Inc
                         Type: login item (0x4)
                  Disposition: [enabled, disallowed, notified] (0x9)
                   Identifier: 4.com.docker.helper
                          URL: Contents/Library/LoginItems/DockerHelper.app
            Parent Identifier: 2.com.docker.docker

         #2:
                         UUID: B2
                         Name: UU远程
               Developer Name: Hangzhou Bobo
                         Type: legacy agent (0x10008)
                  Disposition: [enabled, disallowed, notified] (0x9)
                   Identifier: 8.com.netease.uuremote.agent
                          URL: file:///Library/LaunchAgents/com.netease.uuremote.agent.plist
            Parent Identifier: 2.com.netease.uuremote

         #3:
                         UUID: B3
                         Name: Ollama
               Developer Name: Infra Technologies, Inc
                         Type: app (0x2)
                  Disposition: [disabled, allowed, not notified] (0x2)
                   Identifier: 2.com.electron.ollama
                          URL: file:///Applications/Ollama.app/

         #4:
                         UUID: B4
                         Name: Squirrel
               Developer Name: (null)
                         Type: agent (0x8)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 8.com.ollama.ollama
                          URL: Contents/Library/LaunchAgents/com.ollama.ollama.plist
            Parent Identifier: 2.com.electron.ollama
        """

        let snap = StartupItems.parseBTM(btmSample, uid: 501)
        let baseItems = [
            StartupItem(id: "/Library/LaunchDaemons/yanue.v2rayu.tun-helper.plist", label: "yanue.v2rayu.tun-helper", displayName: "yanue.v2rayu.tun-helper", kind: .launchDaemon, path: "/Library/LaunchDaemons/yanue.v2rayu.tun-helper.plist", enabled: true, btmDisallowed: false, systemLevel: true, managedBySystemSettings: false, targetsBackgroundSession: false, program: "/usr/local/v2rayu/bin/sing-box/sing-box-arm64", sourceAppName: nil, sourceAppPath: nil, developerName: nil, trigger: .onDemand, runningPID: nil, broken: false),
            StartupItem(id: "/Library/LaunchDaemons/com.docker.vmnetd.plist", label: "com.docker.vmnetd", displayName: "com.docker.vmnetd", kind: .launchDaemon, path: "/Library/LaunchDaemons/com.docker.vmnetd.plist", enabled: true, btmDisallowed: false, systemLevel: true, managedBySystemSettings: false, targetsBackgroundSession: false, program: "/Library/PrivilegedHelperTools/com.docker.vmnetd", sourceAppName: nil, sourceAppPath: nil, developerName: nil, trigger: .atLogin, runningPID: nil, broken: false),
            StartupItem(id: "/Library/LaunchDaemons/com.docker.socket.plist", label: "com.docker.socket", displayName: "com.docker.socket", kind: .launchDaemon, path: "/Library/LaunchDaemons/com.docker.socket.plist", enabled: true, btmDisallowed: false, systemLevel: true, managedBySystemSettings: false, targetsBackgroundSession: false, program: "/Library/PrivilegedHelperTools/com.docker.socket", sourceAppName: "Docker", sourceAppPath: "/Applications/Docker.app", developerName: nil, trigger: .atLogin, runningPID: nil, broken: false),
            StartupItem(id: "/Library/LaunchDaemons/com.netease.uuremote.daemon.plist", label: "com.netease.uuremote.daemon", displayName: "com.netease.uuremote.daemon", kind: .launchDaemon, path: "/Library/LaunchDaemons/com.netease.uuremote.daemon.plist", enabled: true, btmDisallowed: false, systemLevel: true, managedBySystemSettings: false, targetsBackgroundSession: false, program: "/Applications/UURemote.app/Contents/MacOS/UURemoteDaemon", sourceAppName: "UURemote", sourceAppPath: "/Applications/UURemote.app", developerName: nil, trigger: .atLogin, runningPID: nil, broken: false),
            StartupItem(id: "/Library/LaunchAgents/com.netease.uuremote.agent.plist", label: "com.netease.uuremote.agent", displayName: "com.netease.uuremote.agent", kind: .launchAgent, path: "/Library/LaunchAgents/com.netease.uuremote.agent.plist", enabled: true, btmDisallowed: false, systemLevel: true, managedBySystemSettings: false, targetsBackgroundSession: false, program: "/Applications/UURemote.app/Contents/MacOS/UURemoteService", sourceAppName: "UURemote", sourceAppPath: "/Applications/UURemote.app", developerName: nil, trigger: .atLogin, runningPID: nil, broken: false)
        ]

        let merged = StartupItems.mergeBTM(baseItems, snap, fileExists: { _ in true }, isInstalled: { _ in true })
        XCTAssertEqual(merged.count, 7, "合并前共 7 条原始后台服务")

        let groups = StartupItems.groupItems(merged)
        // 聚合后应正好为 5 组：Docker(1: vmnetd)、Docker(2: socket+DockerHelper)、Ollama(1)、sing-box-arm64(1)、UU远程(2)
        XCTAssertEqual(groups.count, 5, "按 BTM Parent Identifier 聚合后应与 macOS App 后台活动行数一致")

        let uuGroup = try XCTUnwrap(groups.first { $0.title == "UU远程" })
        XCTAssertEqual(uuGroup.items.count, 2)
        XCTAssertTrue(uuGroup.isExpandable)
        XCTAssertTrue(uuGroup.allBtmDisallowed)

        let dockerGroups = groups.filter { $0.title == "Docker" }
        XCTAssertEqual(dockerGroups.count, 2)
        XCTAssertEqual(dockerGroups.map(\.items.count), [1, 2])

        let ollamaGroup = try XCTUnwrap(groups.first { $0.title == "Ollama" })
        XCTAssertEqual(ollamaGroup.items.count, 1)
        XCTAssertEqual(ollamaGroup.primaryItem.displayName, "Ollama", "Ollama 内嵌服务不应显示成内部更新器名 Squirrel")

        let tunGroup = try XCTUnwrap(groups.first { $0.primaryItem.label == "yanue.v2rayu.tun-helper" })
        XCTAssertEqual(tunGroup.title, "sing-box-arm64")
        XCTAssertTrue(tunGroup.canToggleGroup, "未被 BTM 禁用的传统 LaunchDaemon 应支持管理员提权开关")
        XCTAssertTrue(tunGroup.requiresAdmin)
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
                managedBySystemSettings: false,
                targetsBackgroundSession: false,
                program: nil,
                sourceAppName: "Quark",
                sourceAppPath: "/Applications/Quark.app",
                developerName: nil,
                trigger: .atLogin,
                runningPID: nil,
                broken: false
            ),
            StartupItem(
                id: "btm:loginItem:com.docker.helper",
                label: "com.docker.helper",
                displayName: "DockerHelper",
                kind: .appLoginHelper,
                path: "/Applications/Docker.app/Contents/Library/LoginItems/DockerHelper.app",
                enabled: true,
                btmDisallowed: true,
                systemLevel: false,
                managedBySystemSettings: true,
                targetsBackgroundSession: false,
                program: nil,
                sourceAppName: "Docker",
                sourceAppPath: "/Applications/Docker.app",
                developerName: "Docker Inc",
                trigger: .atLogin,
                runningPID: nil,
                broken: false
            )
        ]

        // 同 Label 同步更新
        vm.applyEnabled(false, forLabel: "com.dup.agent")
        XCTAssertEqual(vm.items.filter { $0.label == "com.dup.agent" }.map(\.enabled), [false, false])

        // 筛选：已停用 / 异常 / 登录项 / 后台服务 / 搜索来源应用
        vm.filter = .disabled
        XCTAssertEqual(vm.filtered.count, 3)

        vm.filter = .broken
        XCTAssertEqual(vm.filtered.count, 1)

        vm.filter = .loginItems
        XCTAssertEqual(vm.filtered.map(\.label), ["com.app.login"])

        vm.filter = .services
        XCTAssertTrue(vm.filtered.contains { $0.label == "com.docker.helper" })
        XCTAssertFalse(vm.filtered.contains { $0.label == "com.app.login" })

        vm.filter = .all
        vm.query = "MyApp"
        XCTAssertEqual(vm.filtered.count, 2)
    }
}
