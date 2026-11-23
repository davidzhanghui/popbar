import XCTest
@testable import PopBarCore

final class UpdateCoreTests: XCTestCase {
    func testSemVerParsingAndComparison() {
        XCTAssertEqual(SemVer("v3.1.0"), SemVer(major: 3, minor: 1, patch: 0))
        XCTAssertEqual(SemVer("3.2"), SemVer(major: 3, minor: 2, patch: 0))
        XCTAssertEqual(SemVer("V3.1.2+42"), SemVer(major: 3, minor: 1, patch: 2))
        XCTAssertEqual(SemVer("3.1.0-beta.2"), SemVer(major: 3, minor: 1, patch: 0, prerelease: ["beta", "2"]))
        XCTAssertNil(SemVer("dev"))
        XCTAssertNil(SemVer("3"))
        XCTAssertNil(SemVer("3.1.0-"))
        XCTAssertNil(SemVer("3.1.0.1"))

        XCTAssertLessThan(SemVer("3.1.0")!, SemVer("3.1.1")!)
        XCTAssertLessThan(SemVer("3.1.9")!, SemVer("3.2.0")!)
        XCTAssertLessThan(SemVer("3.9.9")!, SemVer("4.0.0")!)
        XCTAssertLessThan(SemVer("3.2.0-beta.1")!, SemVer("3.2.0")!)
        XCTAssertLessThan(SemVer("3.2.0-beta.2")!, SemVer("3.2.0-beta.10")!)
        XCTAssertLessThan(SemVer("3.2.0-alpha.1")!, SemVer("3.2.0-beta.1")!)
    }

    func testParseGitHubReleaseAndAssetSelection() throws {
        let json = """
        {
          "tag_name": "v3.2.0",
          "name": "PopBar v3.2.0",
          "html_url": "https://github.com/davidzhanghui/popbar/releases/tag/v3.2.0",
          "published_at": "2026-11-22T10:00:00Z",
          "draft": false,
          "prerelease": false,
          "body": "## 下载 | Downloads\\n安装说明\\n---\\n## What's Changed\\n* feat: auto update",
          "assets": [
            { "name": "PopBar-3.2.0-arm64.dmg", "browser_download_url": "https://example.com/PopBar-3.2.0-arm64.dmg", "size": 5242880 },
            { "name": "PopBar-3.2.0-x86_64.dmg", "browser_download_url": "https://example.com/PopBar-3.2.0-x86_64.dmg", "size": 5300000 },
            { "name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt", "size": 180 }
          ]
        }
        """
        let rel = try UpdateRelease.parseGitHubRelease(Data(json.utf8))
        XCTAssertEqual(rel.version, SemVer("3.2.0"))
        XCTAssertEqual(rel.name, "PopBar v3.2.0")
        XCTAssertNotNil(rel.publishedAt)
        XCTAssertEqual(rel.preferredDMG(for: "arm64")?.name, "PopBar-3.2.0-arm64.dmg")
        XCTAssertEqual(rel.preferredDMG(for: "x86_64")?.name, "PopBar-3.2.0-x86_64.dmg")
        XCTAssertEqual(rel.checksumAsset?.name, "SHA256SUMS.txt")
        XCTAssertEqual(rel.changelogText, "## What's Changed\n* feat: auto update")
    }

    func testUniversalAndFallbackDMGSelection() {
        let relUni = UpdateRelease(
            tagName: "v3.2.0", version: SemVer("3.2.0")!, name: "v3.2.0", body: "plain notes",
            htmlURL: URL(string: "https://example.com")!, publishedAt: nil,
            assets: [
                UpdateAsset(name: "PopBar-3.2.0-universal.dmg", downloadURL: URL(string: "https://example.com/u.dmg")!, size: 100)
            ]
        )
        XCTAssertEqual(relUni.preferredDMG(for: "arm64")?.name, "PopBar-3.2.0-universal.dmg")
        XCTAssertEqual(relUni.preferredDMG(for: "x86_64")?.name, "PopBar-3.2.0-universal.dmg")
        XCTAssertEqual(relUni.changelogText, "plain notes")

        // 只有另一架构包时不应误选
        let relArmOnly = UpdateRelease(
            tagName: "v3.2.0", version: SemVer("3.2.0")!, name: "v3.2.0", body: "",
            htmlURL: URL(string: "https://example.com")!, publishedAt: nil,
            assets: [
                UpdateAsset(name: "PopBar-3.2.0-arm64.dmg", downloadURL: URL(string: "https://example.com/a.dmg")!, size: 100)
            ]
        )
        XCTAssertEqual(relArmOnly.preferredDMG(for: "arm64")?.name, "PopBar-3.2.0-arm64.dmg")
        XCTAssertNil(relArmOnly.preferredDMG(for: "x86_64"))
    }

    func testRejectsDraftOrPrerelease() {
        let json = """
        {
          "tag_name": "v3.3.0-beta.1",
          "html_url": "https://example.com/r",
          "draft": false,
          "prerelease": true,
          "assets": []
        }
        """
        XCTAssertThrowsError(try UpdateRelease.parseGitHubRelease(Data(json.utf8))) { err in
            XCTAssertEqual(err as? UpdateRelease.ParseError, .draftOrPrerelease)
        }
    }

    func testParseSHA256Sums() {
        let h1 = String(repeating: "a", count: 64)
        let h2 = String(repeating: "B", count: 64)
        let text = """
        # comment
        \(h1)  PopBar-3.2.0-arm64.dmg
        \(h2) *./PopBar-3.2.0-x86_64.dmg
        not-a-hash PopBar-3.2.0-bad.dmg
        """
        XCTAssertEqual(UpdateRelease.parseSHA256Sums(text, filename: "PopBar-3.2.0-arm64.dmg"), h1)
        XCTAssertEqual(UpdateRelease.parseSHA256Sums(text, filename: "PopBar-3.2.0-x86_64.dmg"), h2.lowercased())
        XCTAssertNil(UpdateRelease.parseSHA256Sums(text, filename: "PopBar-3.2.0-bad.dmg"))
        XCTAssertNil(UpdateRelease.parseSHA256Sums(text, filename: "missing.dmg"))
    }

    func testInstallTargetResolution() {
        let apps = URL(fileURLWithPath: "/Applications")

        let normal = UpdateInstallTarget.resolve(bundleURL: URL(fileURLWithPath: "/Applications/PopBar.app"), defaultApplications: apps)
        XCTAssertEqual(normal.destinationURL.path, "/Applications/PopBar.app")
        XCTAssertTrue(normal.isInPlace)

        let custom = UpdateInstallTarget.resolve(bundleURL: URL(fileURLWithPath: "/Users/test/Apps/PopBar.app"), defaultApplications: apps)
        XCTAssertEqual(custom.destinationURL.path, "/Users/test/Apps/PopBar.app")
        XCTAssertTrue(custom.isInPlace)

        let dmg = UpdateInstallTarget.resolve(bundleURL: URL(fileURLWithPath: "/Volumes/PopBar/PopBar.app"), defaultApplications: apps)
        XCTAssertEqual(dmg.destinationURL.path, "/Applications/PopBar.app")
        XCTAssertFalse(dmg.isInPlace)

        let translocated = UpdateInstallTarget.resolve(
            bundleURL: URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/UUID/d/PopBar.app"),
            defaultApplications: apps
        )
        XCTAssertEqual(translocated.destinationURL.path, "/Applications/PopBar.app")
        XCTAssertFalse(translocated.isInPlace)

        let bare = UpdateInstallTarget.resolve(bundleURL: URL(fileURLWithPath: "/tmp/.build/debug/PopBar"), defaultApplications: apps)
        XCTAssertEqual(bare.destinationURL.path, "/Applications/PopBar.app")
        XCTAssertFalse(bare.isInPlace)
    }

    /// 端到端验证实际替换脚本：等待旧 PID 退出 → 原子覆盖目标目录 → 清理备份 → 调用启动器
    func testSwapScriptReplacesAndLaunches() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("popbar-swap-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let target = root.appendingPathComponent("PopBar.app")
        let staged = root.appendingPathComponent(".PopBar-staged.app")
        let backup = root.appendingPathComponent(".PopBar-backup.app")
        let launchedMarker = root.appendingPathComponent("launched.txt")
        let mockLauncher = root.appendingPathComponent("mock-open.sh")

        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("version.txt"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("version.txt"))

        let launcherCode = "#!/bin/sh\nprintf '%s' \"$1\" > \(Shell.quote(launchedMarker.path))\n"
        try Data(launcherCode.utf8).write(to: mockLauncher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockLauncher.path)

        // 起一个 0.2 秒后自动退出的假旧进程，验证脚本会等旧进程退出后再替换
        let dummyRes = Shell.spawnDetached("/bin/sleep", ["0.2"])
        guard case .success(let dummyPid) = dummyRes else {
            return XCTFail("无法启动测试进程")
        }
        defer { var st: Int32 = 0; _ = waitpid(dummyPid, &st, 0) }

        let res = Shell.spawnDetached("/bin/sh", [
            "-c", UpdateScript.swapAndRelaunch, "popbar-updater",
            String(dummyPid), target.path, staged.path, backup.path, mockLauncher.path
        ])
        guard case .success(let updaterPid) = res else {
            return XCTFail("spawnDetached 失败：\(res)")
        }
        defer { var st: Int32 = 0; _ = waitpid(updaterPid, &st, 0) }

        let deadline = Date().addingTimeInterval(5.0)
        while !fm.fileExists(atPath: launchedMarker.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertTrue(fm.fileExists(atPath: launchedMarker.path), "启动器未被调用")
        XCTAssertEqual(try String(contentsOf: launchedMarker, encoding: .utf8), target.path)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("version.txt"), encoding: .utf8), "new")
        XCTAssertFalse(fm.fileExists(atPath: staged.path), "暂存目录未清理")
        XCTAssertFalse(fm.fileExists(atPath: backup.path), "备份目录未清理")
    }
}
