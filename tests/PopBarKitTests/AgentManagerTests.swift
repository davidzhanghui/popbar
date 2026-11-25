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

    func testNewAgentMetadataAndZshrcProxyMapping() {
        XCTAssertEqual(AgentKind.allCases.count, 9)
        XCTAssertEqual(AgentKind.claudeCode.zshrcProxyAlias, "claude-proxy")
        XCTAssertEqual(AgentKind.claudeDesktop.zshrcProxyAlias, "claude-desktop-proxy")
        XCTAssertEqual(AgentKind.codexCLI.zshrcProxyAlias, "codex-proxy")
        XCTAssertEqual(AgentKind.codexDesktop.zshrcProxyAlias, "codex-desktop-proxy")
        XCTAssertEqual(AgentKind.commandCode.zshrcProxyAlias, "cmd-proxy")
        XCTAssertEqual(AgentKind.openCode.zshrcProxyAlias, "opencode-proxy")
        XCTAssertEqual(AgentKind.pi.zshrcProxyAlias, "pi-proxy")
        // DeepSeek Harness 直接启动，不使用代理
        XCTAssertNil(AgentKind.deepSeekHarness.zshrcProxyAlias)
        XCTAssertFalse(AgentKind.deepSeekHarness.usesProxyLaunch)
        XCTAssertTrue(AgentKind.deepSeekHarness.isDesktopApp)
        // Antigravity 桌面版走 antigravity-desktop-proxy
        XCTAssertEqual(AgentKind.antigravity.zshrcProxyAlias, "antigravity-desktop-proxy")
        XCTAssertTrue(AgentKind.antigravity.usesProxyLaunch)
        XCTAssertTrue(AgentKind.antigravity.isDesktopApp)
        XCTAssertEqual(AgentKind.antigravity.bundleIdentifier, "com.google.antigravity")
        XCTAssertTrue(AgentKind.codexDesktop.isDesktopApp)
        XCTAssertFalse(AgentKind.codexCLI.isDesktopApp)
        XCTAssertFalse(AgentKind.pi.isDesktopApp)
    }

    func testParseSparkleAppcastAndElectronUpdaterYAMLAndPrefixedGitHubTag() throws {
        // 1. Codex Desktop Sparkle appcast.xml（忽略 delta，按架构挑最高版本）
        let appcast = Data("""
        <?xml version='1.0' encoding='utf-8'?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <title>Codex</title>
            <item>
              <title>26.1120.50957</title>
              <sparkle:shortVersionString>26.1120.50957</sparkle:shortVersionString>
              <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
              <enclosure url="https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-26.1120.50957.zip" type="application/octet-stream" />
              <sparkle:deltas>
                <enclosure url="https://persistent.oaistatic.com/codex-app-prod/ChatGPT30866-30607-arm64.delta" />
              </sparkle:deltas>
            </item>
            <item>
              <title>26.1121.99999</title>
              <sparkle:shortVersionString>26.1121.99999</sparkle:shortVersionString>
              <sparkle:hardwareRequirements>x86_64</sparkle:hardwareRequirements>
              <enclosure url="https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-x64-26.1121.99999.zip" type="application/octet-stream" />
            </item>
          </channel>
        </rss>
        """.utf8)
        let arm64Release = try XCTUnwrap(AgentVersionParser.parseSparkleAppcastXML(appcast, arch: "arm64", source: "OpenAI Releases"))
        XCTAssertEqual(arm64Release.version, SemVer(major: 26, minor: 1120, patch: 50957))
        XCTAssertEqual(arm64Release.downloadURL?.absoluteString, "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-26.1120.50957.zip")
        XCTAssertEqual(arm64Release.source, "OpenAI Releases")

        let x64Release = try XCTUnwrap(AgentVersionParser.parseSparkleAppcastXML(appcast, arch: "x86_64", source: "OpenAI Releases"))
        XCTAssertEqual(x64Release.version, SemVer(major: 26, minor: 1121, patch: 99999))

        // 2. DeepSeek Harness electron-updater nightly-mac.yml（含 >- 多行折叠 URL）
        let dshYAML = Data("""
        version: 0.2.3-alpha.2
        files:
          - url: >-
              https://download.deepseek.com/dsh-desk/bin/mac-arm64/deepseek-harness-0.2.3-alpha.2-mac-arm64.zip
            size: 365597921
        path: >-
          https://download.deepseek.com/dsh-desk/bin/mac-arm64/deepseek-harness-0.2.3-alpha.2-mac-arm64.zip
        releaseDate: '2026-11-23T03:12:30.263Z'
        """.utf8)
        let dshRelease = try XCTUnwrap(AgentVersionParser.parseElectronUpdaterYAML(dshYAML, source: "DeepSeek Releases"))
        XCTAssertEqual(dshRelease.version, SemVer(major: 0, minor: 2, patch: 3, prerelease: ["alpha", "2"]))
        XCTAssertEqual(dshRelease.downloadURL?.absoluteString, "https://download.deepseek.com/dsh-desk/bin/mac-arm64/deepseek-harness-0.2.3-alpha.2-mac-arm64.zip")
        XCTAssertTrue(dshRelease.version > SemVer("0.2.2-rc.5")!)

        // 3. Antigravity electron-updater latest-arm64-mac.yml（行内 URL）
        let agyYAML = Data("""
        version: 2.35.1
        files:
          - url: https://storage.googleapis.com/antigravity-public/antigravity-hub/2.35.1-4615540875067392/darwin-arm/Antigravity.zip
            sha512: abcdef==
            size: 216134092
        path: Antigravity.zip
        """.utf8)
        let agyRelease = try XCTUnwrap(AgentVersionParser.parseElectronUpdaterYAML(agyYAML, source: "Google Releases"))
        XCTAssertEqual(agyRelease.version, SemVer(major: 2, minor: 35, patch: 1))
        XCTAssertEqual(agyRelease.downloadURL?.absoluteString, "https://storage.googleapis.com/antigravity-public/antigravity-hub/2.35.1-4615540875067392/darwin-arm/Antigravity.zip")
        XCTAssertEqual(agyRelease.source, "Google Releases")

        // 4. OpenAI Codex GitHub release tag（rust-v0.172.0）
        let codexGH = Data("""
        [
          {"tag_name": "rust-v0.173.0-alpha.1", "draft": false, "prerelease": true},
          {"tag_name": "rust-v0.172.0", "draft": false, "prerelease": false},
          {"tag_name": "rust-v0.170.0", "draft": false, "prerelease": false}
        ]
        """.utf8)
        XCTAssertEqual(AgentVersionParser.parseGitHubHighestStableRelease(codexGH), SemVer(major: 0, minor: 172, patch: 0))
    }

    func testProcessMatcherForPiDeepSeekHarnessAndCodex() {
        let codexBundles: Set<String> = ["/applications/chatgpt.app"]

        // 1. Pi CLI（node 执行 pi-coding-agent）
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "node",
                executablePath: "/Users/test/.nvm/versions/node/v24.14.0/bin/node",
                argv: ["node", "/Users/test/.nvm/versions/node/v24.14.0/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"]
            ),
            AgentProcessMatcher.Match(kind: .pi, role: .cli)
        )
        // 不误伤含 "pi" 子串的普通进程
        XCTAssertNil(
            AgentProcessMatcher.match(
                processName: "pip3",
                executablePath: "/usr/local/bin/pip3",
                argv: ["pip3", "install", "requests"]
            )
        )

        // 2. DeepSeek Harness 主应用与 Electron Helper
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "DeepSeek Harness",
                executablePath: "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness",
                argv: ["/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness"]
            ),
            AgentProcessMatcher.Match(kind: .deepSeekHarness, role: .desktopApp, appBundlePath: "/Applications/DeepSeek Harness.app")
        )
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "DeepSeek Harness Helper (Renderer)",
                executablePath: "/Applications/DeepSeek Harness.app/Contents/Frameworks/DeepSeek Harness Helper (Renderer).app/Contents/MacOS/DeepSeek Harness Helper (Renderer)",
                argv: ["--type=renderer"]
            ),
            AgentProcessMatcher.Match(kind: .deepSeekHarness, role: .desktopApp, appBundlePath: "/Applications/DeepSeek Harness.app")
        )

        // 2b. Antigravity 主应用、Electron Helper 与内置 language_server
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "Antigravity",
                executablePath: "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
                argv: ["/Applications/Antigravity.app/Contents/MacOS/Antigravity"]
            ),
            AgentProcessMatcher.Match(kind: .antigravity, role: .desktopApp, appBundlePath: "/Applications/Antigravity.app")
        )
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "Antigravity Helper (Renderer)",
                executablePath: "/Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper (Renderer).app/Contents/MacOS/Antigravity Helper (Renderer)",
                argv: ["--type=renderer"]
            ),
            AgentProcessMatcher.Match(kind: .antigravity, role: .desktopApp, appBundlePath: "/Applications/Antigravity.app")
        )
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "language_server",
                executablePath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
                argv: ["/Applications/Antigravity.app/Contents/Resources/bin/language_server", "--override_ide_name", "antigravity"]
            ),
            AgentProcessMatcher.Match(kind: .antigravity, role: .desktopApp, appBundlePath: "/Applications/Antigravity.app")
        )

        // 3. Codex CLI 与 Codex Desktop 严格区分
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "codex",
                executablePath: "/Users/test/.nvm/versions/node/v24.14.0/lib/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex",
                argv: ["codex", "--dangerously-bypass-approvals-and-sandbox"],
                codexDesktopBundlePaths: codexBundles
            ),
            AgentProcessMatcher.Match(kind: .codexCLI, role: .cli)
        )
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "ChatGPT",
                executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                argv: ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", "--proxy-server=http://127.0.0.1:1087"],
                codexDesktopBundlePaths: codexBundles
            ),
            AgentProcessMatcher.Match(kind: .codexDesktop, role: .desktopApp, appBundlePath: "/Applications/ChatGPT.app")
        )
        XCTAssertEqual(
            AgentProcessMatcher.match(
                processName: "codex",
                executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/codex",
                argv: ["codex", "app-server"],
                codexDesktopBundlePaths: codexBundles
            ),
            AgentProcessMatcher.Match(kind: .codexDesktop, role: .desktopChild)
        )
        // 未在 codexDesktopBundlePaths 中的普通 ChatGPT.app 不误判为 Codex Desktop
        XCTAssertNil(
            AgentProcessMatcher.match(
                processName: "ChatGPT",
                executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                argv: ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"],
                codexDesktopBundlePaths: []
            )
        )
    }

    func testLaunchBuilderScripts() {
        let desktopScript = AgentLaunchBuilder.buildDesktopProxyScript(
            aliasName: "codex-desktop-proxy",
            fallbackOpenCommand: "open -b 'com.openai.codex'"
        )
        XCTAssertTrue(desktopScript.contains("setopt aliases"))
        XCTAssertTrue(desktopScript.contains("source \"$HOME/.zshrc\""))
        XCTAssertTrue(desktopScript.contains("eval 'codex-desktop-proxy'"))

        XCTAssertEqual(
            AgentLaunchBuilder.restartCommandDisplay(for: .deepSeekHarness, appPath: "/Applications/DeepSeek Harness.app"),
            "open -a '/Applications/DeepSeek Harness.app'"
        )
        XCTAssertEqual(
            AgentLaunchBuilder.restartCommandDisplay(for: .codexDesktop),
            "~/.zshrc → codex-desktop-proxy"
        )
        XCTAssertEqual(
            AgentLaunchBuilder.restartCommandDisplay(for: .antigravity),
            "~/.zshrc → antigravity-desktop-proxy"
        )
    }

    func testZshrcProxyParsingAndUpdateEnvironment() {
        let sampleZshrc = """
        # export HTTPS_PROXY='http://127.0.0.1:9999'
        with-proxy() (
          unset ALL_PROXY all_proxy
          export HTTPS_PROXY='http://127.0.0.1:1087'
          export HTTP_PROXY='http://127.0.0.1:1087'
          exec "$@"
        )
        """
        XCTAssertEqual(AgentShellEnv.parseProxyURL(fromZshrc: sampleZshrc), "http://127.0.0.1:1087")
        XCTAssertNil(AgentShellEnv.parseProxyURL(fromZshrc: "# no proxy configured\nexport PATH=/usr/bin"))

        let baseEnv = [
            "PATH": "/usr/bin",
            "ALL_PROXY": "socks5://127.0.0.1:1080",
            "HTTPS_PROXY": "http://old.proxy:8080",
        ]

        // 非 DeepSeek Agent 注入 ~/.zshrc 代理并清理 ALL_PROXY
        let codexEnv = AgentShellEnv.updateEnvironment(for: .codexDesktop, base: baseEnv, proxyURL: "http://127.0.0.1:1087")
        XCTAssertEqual(codexEnv["HTTPS_PROXY"], "http://127.0.0.1:1087")
        XCTAssertEqual(codexEnv["HTTP_PROXY"], "http://127.0.0.1:1087")
        XCTAssertEqual(codexEnv["NODE_USE_ENV_PROXY"], "1")
        XCTAssertNil(codexEnv["ALL_PROXY"])

        // DeepSeek Harness 强制清空所有代理变量直连
        let dshEnv = AgentShellEnv.updateEnvironment(for: .deepSeekHarness, base: baseEnv, proxyURL: "http://127.0.0.1:1087")
        XCTAssertNil(dshEnv["HTTPS_PROXY"])
        XCTAssertNil(dshEnv["HTTP_PROXY"])
        XCTAssertNil(dshEnv["ALL_PROXY"])
    }
}
