import XCTest
import PopBarCore
@testable import PopBarKit

final class AgentManagerTests: XCTestCase {

    func testExtractSemVerFromCLIOutputs() {
        XCTAssertEqual(AgentVersionParser.extractSemVer(from: "2.1.331 (Claude Code)"), SemVer(major: 2, minor: 1, patch: 331))
        XCTAssertEqual(AgentVersionParser.extractSemVer(from: "1.93.2\n"), SemVer(major: 1, minor: 93, patch: 2))
        XCTAssertEqual(AgentVersionParser.extractSemVer(from: "opencode v2.3.1"), SemVer(major: 2, minor: 3, patch: 1))
        XCTAssertEqual(AgentVersionParser.extractSemVer(from: "6.28899.6"), SemVer(major: 6, minor: 28899, patch: 6))
        XCTAssertEqual(AgentVersionParser.extractSemVer(from: "v2.4.0-beta.1"), SemVer(major: 2, minor: 4, patch: 0, prerelease: ["beta", "1"]))
        XCTAssertNil(AgentVersionParser.extractSemVer(from: "no version here"))
    }

    func testParseNpmGitHubAndClaudeDesktopReleases() throws {
        let npmJSON = Data(#"{"name":"command-code","version":"1.94.0"}"#.utf8)
        XCTAssertEqual(AgentVersionParser.parseNpmRegistryLatest(npmJSON), SemVer(major: 1, minor: 94, patch: 0))

        let ghJSON = Data("""
        [
          {"tag_name": "v2.5.0-rc.1", "draft": false, "prerelease": true},
          {"tag_name": "v2.6.0", "draft": true, "prerelease": false},
          {"tag_name": "v1.19.6", "draft": false, "prerelease": false},
          {"tag_name": "v2.4.1", "draft": false, "prerelease": false},
          {"tag_name": "v2.3.2", "draft": false, "prerelease": false}
        ]
        """.utf8)
        XCTAssertEqual(AgentVersionParser.parseGitHubHighestStableRelease(ghJSON), SemVer(major: 2, minor: 4, patch: 1))

        let desktopJSON = Data("""
        {
          "currentRelease": "6.28899.6",
          "releases": [
            {
              "version": "6.28899.6",
              "updateTo": {
                "version": "6.28899.6",
                "url": "https://downloads.claude.ai/releases/darwin/universal/6.28899.6/Claude-abc.zip"
              }
            }
          ]
        }
        """.utf8)
        let desktopRelease = try XCTUnwrap(AgentVersionParser.parseClaudeDesktopReleasesJSON(desktopJSON))
        XCTAssertEqual(desktopRelease.version, SemVer(major: 6, minor: 28899, patch: 6))
        XCTAssertEqual(desktopRelease.downloadURL?.absoluteString, "https://downloads.claude.ai/releases/darwin/universal/6.28899.6/Claude-abc.zip")

        let caskJSON = Data(#"{"version":"6.28899.6,2f5fc59b","url":"https://downloads.claude.ai/releases/darwin/universal/6.28899.6/Claude-2f5fc59b.zip"}"#.utf8)
        let caskRelease = try XCTUnwrap(AgentVersionParser.parseHomebrewCaskJSON(caskJSON))
        XCTAssertEqual(caskRelease.version, SemVer(major: 6, minor: 28899, patch: 6))
        XCTAssertEqual(caskRelease.source, "Homebrew Cask")
    }

    func testDetectInstallMethod() {
        XCTAssertEqual(
            AgentInstallDetector.detect(
                executablePath: "/Users/test/.local/bin/claude",
                resolvedPath: "/Users/test/.local/share/claude/versions/2.1.331",
                home: "/Users/test"
            ),
            .native
        )
        XCTAssertEqual(
            AgentInstallDetector.detect(
                executablePath: "/Applications/Claude.app",
                resolvedPath: "/Applications/Claude.app",
                home: "/Users/test"
            ),
            .appBundle
        )
        XCTAssertEqual(
            AgentInstallDetector.detect(
                executablePath: "/opt/homebrew/bin/opencode",
                resolvedPath: "/opt/homebrew/Cellar/opencode-v2/2.3.1/bin/opencode",
                home: "/Users/test"
            ),
            .homebrew(formula: "opencode-v2")
        )
        XCTAssertEqual(
            AgentInstallDetector.detect(
                executablePath: "/Users/test/.nvm/versions/node/v24.14.0/bin/command-code",
                resolvedPath: "/Users/test/.nvm/versions/node/v24.14.0/lib/node_modules/command-code/dist/index.mjs",
                home: "/Users/test"
            ),
            .npm
        )
        XCTAssertEqual(
            AgentInstallDetector.detect(
                executablePath: "/Users/test/.bun/bin/opencode",
                resolvedPath: "/Users/test/.bun/install/global/node_modules/@opencode/cli/bin/opencode",
                home: "/Users/test"
            ),
            .bun
        )
    }

    func testProcessMatcherSeparatesClaudeCodeAndClaudeDesktop() {
        // 1. Claude Code 命令行终端进程 -> .claudeCode / .cli
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "claude",
                executablePath: "/Users/test/.local/share/claude/versions/2.1.331",
                argv: ["claude", "--dangerously-skip-permissions"]
            ),
            AgentProcessMatcher.Match(kind: .claudeCode, role: .cli)
        )

        // 2. Claude Desktop 主应用与 Electron Helper -> .claudeDesktop / .desktopApp
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "Claude",
                executablePath: "/Applications/Claude.app/Contents/MacOS/Claude",
                argv: ["/Applications/Claude.app/Contents/MacOS/Claude"]
            ),
            AgentProcessMatcher.Match(kind: .claudeDesktop, role: .desktopApp, appBundlePath: "/Applications/Claude.app")
        )
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "Claude Helper (Renderer)",
                executablePath: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)",
                argv: ["--type=renderer"]
            ),
            AgentProcessMatcher.Match(kind: .claudeDesktop, role: .desktopApp, appBundlePath: "/Applications/Claude.app")
        )

        // 3. Claude Desktop 的 disclaimer 包装器应忽略
        XCTAssertNil(
            AgentProcessMatcher.match(
                processName: "disclaimer",
                executablePath: "/Applications/Claude.app/Contents/Helpers/disclaimer",
                argv: ["disclaimer", "--pgroup"]
            )
        )

        // 4. Claude Desktop 拉起的 stream-json 内嵌子进程 -> 归入 .claudeDesktop / .desktopChild，不混入 .claudeCode
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "claude",
                executablePath: "/Users/test/Library/Application Support/Claude-3p/claude-code/2.1.330/abc/claude.app/Contents/MacOS/claude",
                argv: ["claude", "--output-format", "stream-json"]
            ),
            AgentProcessMatcher.Match(kind: .claudeDesktop, role: .desktopChild)
        )

        // 5. Command Code 与 OpenCode
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "command-code",
                executablePath: "/Users/test/.nvm/versions/node/v24.14.0/bin/node",
                argv: ["command-code"]
            ),
            AgentProcessMatcher.Match(kind: .commandCode, role: .cli)
        )
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "node",
                executablePath: "/usr/local/bin/node",
                argv: ["node", "/usr/local/lib/node_modules/command-code/dist/index.mjs", "acp"]
            ),
            AgentProcessMatcher.Match(kind: .commandCode, role: .server)
        )
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "opencode",
                executablePath: "/opt/homebrew/Cellar/opencode-v2/2.3.1/bin/opencode",
                argv: ["opencode", "serve", "--port", "14096"]
            ),
            AgentProcessMatcher.Match(kind: .openCode, role: .server)
        )

        // 6. 排除普通 shell / grep 噪声
        XCTAssertNil(
            AgentProcessMatcher.match(
                processName: "zsh",
                executablePath: "/bin/zsh",
                argv: ["zsh", "-lc", "which claude opencode command-code"]
            )
        )
        XCTAssertNil(
            AgentProcessMatcher.match(
                processName: "grep",
                executablePath: "/usr/bin/grep",
                argv: ["grep", "claude"]
            )
        )
    }

    func testCLIStateUpdateFlags() {
        var s = AgentCLIState(kind: .openCode)
        s.installed = true
        s.currentVersion = SemVer(major: 2, minor: 3, patch: 1)
        s.latestVersion = SemVer(major: 2, minor: 4, patch: 1)
        XCTAssertTrue(s.hasUpdate)
        XCTAssertFalse(s.isUpToDate)

        s.currentVersion = SemVer(major: 2, minor: 4, patch: 1)
        XCTAssertFalse(s.hasUpdate)
        XCTAssertTrue(s.isUpToDate)

        s.installed = false
        XCTAssertFalse(s.hasUpdate)
        XCTAssertFalse(s.isUpToDate)
    }

    func testAgentConfigAndUpdatePolicy() throws {
        let raw = Data(#"{"autoUpdate":true,"checkIntervalHours":99,"lastCheckAt":1700000000}"#.utf8)
        let cfg = try JSONDecoder().decode(AgentConfig.self, from: raw)
        XCTAssertTrue(cfg.autoUpdate)
        XCTAssertEqual(cfg.checkIntervalHours, 24)
        XCTAssertEqual(cfg.lastCheckAt, 1_700_000_000)

        let now = Date(timeIntervalSince1970: 1_700_050_000)
        XCTAssertTrue(AgentUpdatePolicy.shouldCheck(lastCheck: nil, intervalHours: 6, now: now))
        XCTAssertFalse(AgentUpdatePolicy.shouldCheck(lastCheck: now.addingTimeInterval(-3600), intervalHours: 6, now: now))
        XCTAssertTrue(AgentUpdatePolicy.shouldCheck(lastCheck: now.addingTimeInterval(-6 * 3600 - 1), intervalHours: 6, now: now))
    }
}
