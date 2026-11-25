import XCTest
@testable import PopBarKit

final class VPSMonitorTests: XCTestCase {
    private let sample45 = """
    HOSTNAME=test-host
    OS_NAME=Debian GNU/Linux 12 (bookworm)
    OS_ID=debian
    OS_VERSION=12
    KERNEL=6.1.0-56-amd64
    UPTIME=24752
    LOAD=0.00 0.01 0.02
    CORES=1
    CPU_PCT=3
    MEM_TOTAL_KB=983724
    MEM_AVAIL_KB=693352
    SWAP_TOTAL_KB=1049576
    SWAP_FREE_KB=1049576
    DISK_TOTAL_KB=19525484
    DISK_USED_KB=1940084
    DISK_PCT=11
    XRAY_ACTIVE=active
    XRAY_VERSION=Xray 26.11.9 (Xray, Penetrates Everything.) 676eaf6 (go1.27.3 linux/amd64)
    XRAY_PORTS=40028
    XRAY_CONFIG=/usr/local/etc/xray/config.json
    XRAY_CONFIG_MODE=600
    XRAY_CONFIG_OWNER=xray:xray
    FAIL2BAN=active
    FAIL2BAN_JAILS=sshd
    FAIL2BAN_BANNED=1
    FIREWALL_KIND=ufw
    FIREWALL=active
    SSH_PASSWORD=no
    SSH_X11=no
    SSH_MAXAUTH=3
    SSH_ROOT=without-password
    PENDING=0
    AUTO_UPDATES=enabled
    TIME_SYNC=yes
    NEED_REBOOT=0
    DOCKER=inactive
    VLESS_LINK=vless://11111111-2222-4333-8444-555555555555@203.0.113.10:40028?encryption=none&flow=xtls-rprx-vision&security=reality&sni=example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef&type=tcp&headerType=none#test-vps
    OK=1
    """

    func testParsesRemoteSnapshot() throws {
        let s = try XCTUnwrap(VPSRemoteParser.parse(sample45))
        XCTAssertEqual(s.hostname, "test-host")
        XCTAssertEqual(s.osID, "debian")
        XCTAssertEqual(s.osVersion, "12")
        XCTAssertEqual(s.cores, 1)
        XCTAssertEqual(s.cpuPercent, 3)
        XCTAssertEqual(s.load, [0, 0.01, 0.02])
        XCTAssertEqual(s.memTotalKB, 983724)
        XCTAssertEqual(s.memUsedKB, 290372)
        XCTAssertEqual(s.xrayPorts, [40028])
        XCTAssertEqual(s.xrayConfigMode, "600")
        XCTAssertEqual(s.fail2banBanned, 1)
        XCTAssertEqual(s.firewallKind, "ufw")
        XCTAssertEqual(s.pending, 0)
        XCTAssertTrue(s.autoUpdatesOn)
        XCTAssertTrue(s.timeSynced)
        XCTAssertTrue(s.sshKeyOnly)
        XCTAssertEqual(s.securityScore, 100)
        XCTAssertTrue(s.securityWarnings.isEmpty)
    }

    func testEOLAndSecurityScore() throws {
        let text = sample45
            .replacingOccurrences(of: "OS_ID=debian", with: "OS_ID=ubuntu")
            .replacingOccurrences(of: "OS_VERSION=12", with: "OS_VERSION=20.04")
        let s = try XCTUnwrap(VPSRemoteParser.parse(text))
        XCTAssertNotNil(s.eolNote)
        XCTAssertEqual(s.securityScore, 80)
    }

    func testUnknownPendingAndNon600Config() throws {
        let text = sample45
            .replacingOccurrences(of: "PENDING=0", with: "PENDING=12")
            .replacingOccurrences(of: "XRAY_CONFIG_MODE=600", with: "XRAY_CONFIG_MODE=644")
            .replacingOccurrences(of: "AUTO_UPDATES=enabled", with: "AUTO_UPDATES=unknown")
        let s = try XCTUnwrap(VPSRemoteParser.parse(text))
        XCTAssertEqual(s.pending, 12)
        XCTAssertEqual(s.securityScore, 65)
        XCTAssertTrue(s.securityWarnings.contains { $0.contains("12") })
    }

    func testNegativePendingBecomesUnknown() throws {
        let text = sample45.replacingOccurrences(of: "PENDING=0", with: "PENDING=-1")
        let s = try XCTUnwrap(VPSRemoteParser.parse(text))
        XCTAssertNil(s.pending)
        XCTAssertEqual(s.securityScore, 95)
    }

    func testParsesVLESSLink() throws {
        let link = "vless://11111111-2222-4333-8444-555555555555@203.0.113.10:40028?encryption=none&flow=xtls-rprx-vision&security=reality&sni=example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef&type=tcp&headerType=none#test-vps"
        let e = try XCTUnwrap(VLESSEndpoint.parse(link))
        XCTAssertEqual(e.host, "203.0.113.10")
        XCTAssertEqual(e.port, 40028)
        XCTAssertEqual(e.uuid, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(e.sni, "example.com")
        XCTAssertEqual(e.publicKey, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(e.shortID, "0123456789abcdef")
        XCTAssertEqual(e.flow, "xtls-rprx-vision")
        XCTAssertEqual(e.fingerprint, "chrome")
        XCTAssertEqual(e.display, "203.0.113.10:40028")
    }

    func testRejectsUnsupportedVLESSLinks() {
        XCTAssertNil(VLESSEndpoint.parse(""))
        XCTAssertNil(VLESSEndpoint.parse("https://example.com"))
        XCTAssertNil(VLESSEndpoint.parse("vless://uuid@example.com:443?security=tls&sni=example.com"))
        XCTAssertNil(VLESSEndpoint.parse("vless://uuid@example.com:443?security=reality&sni=example.com"))
        XCTAssertNil(VLESSEndpoint.parse("vless://uuid@example.com:443?security=reality&sni=example.com&pbk=x&type=ws"))
    }

    func testSSHConfigImport() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("popbar-ssh-\(UUID().uuidString)")
        let text = """
        # comment
        Host alpha
          HostName 1.2.3.4
        Host beta gamma
          HostName 5.6.7.8
        Host *
          ServerAliveInterval 30
        Host delta
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let found = VPSHostDiscovery.fromSSHConfig(at: url.path)
        XCTAssertEqual(found.map(\.sshAlias), ["alpha", "beta", "gamma", "delta"])
        XCTAssertEqual(found.map(\.id), ["alpha", "beta", "gamma", "delta"])
        XCTAssertTrue(found.allSatisfy(\.enabled))
    }

    func testLiveProbeWhenRequested() async throws {
        guard let alias = ProcessInfo.processInfo.environment["POPBAR_VPS_LIVE_HOST"], !alias.isEmpty else {
            throw XCTSkip("set POPBAR_VPS_LIVE_HOST=<ssh alias> to run the live probe")
        }
        let result = await VPSProbe.probe(VPSHost(name: alias, sshAlias: alias))
        XCTAssertTrue(result.online, result.error ?? "offline")
        XCTAssertNotNil(result.remote)
        XCTAssertEqual(result.remote?.sshPassword, "no")
        XCTAssertTrue(result.remote?.xrayRunning == true)
        XCTAssertFalse(result.vlessChecks.isEmpty)
        for (index, link) in result.vlessChecks.enumerated() {
            guard let endpoint = VLESSEndpoint.parse(link.url) else { continue }
            let check = await VPSXrayTester.run(endpoint)
            XCTAssertEqual(check.state, .ok, "\(link.name): \(check.message)")
            print("live connectivity:", link.name, "\(check.latencyMs ?? -1)ms")
            if index == 0, ProcessInfo.processInfo.environment["POPBAR_VPS_LIVE_SPEED"] == "1" {
                let speed = await VPSXrayTester.speedTest(endpoint)
                XCTAssertEqual(speed.state, .ok, speed.message)
                print("live speed:", String(format: "%.1f MB/s", speed.megabytesPerSecond ?? 0))
            }
        }
        print("live probe:", result.host.displayName,
              "score=\(result.remote?.securityScore ?? -1)",
              "tcp=\(result.tcp?.latencyMs ?? -1)ms",
              "links=\(result.vlessChecks.map { "\($0.name):\($0.check.state.rawValue)" }.joined(separator: ","))")
    }

    func testReportContainsLinkButNoSecrets() throws {
        let remote = try XCTUnwrap(VPSRemoteParser.parse(sample45))
        let host = VPSHost(name: "test-vps", sshAlias: "test-vps")
        let link = VPSLink(name: "主节点", url: "vless://11111111-2222-4333-8444-555555555555@203.0.113.10:40028?security=reality&sni=example.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef")
        let backup = VPSLink(name: "备用中转", url: "vless://relay")
        let result = VPSHostResult(
            host: host, online: true, error: nil, latencyMs: 42, remote: remote,
            tcp: VPSTCPCheck(host: "203.0.113.10", port: 40028, ok: true, latencyMs: 174, error: nil),
            vlessChecks: [
                VPSLinkCheck(id: link.id, name: link.name, endpoint: "203.0.113.10:40028",
                             check: VLESSCheck(state: .ok, latencyMs: 620, message: "",
                                               endpoint: "203.0.113.10:40028"),
                             url: link.url,
                             speed: VLESpeedCheck(state: .ok, megabytesPerSecond: 1.8,
                                                  latencyMs: 600, message: "")),
                VPSLinkCheck(id: backup.id, name: backup.name, endpoint: "203.0.113.10:8443",
                             check: VLESSCheck(state: .failed, latencyMs: nil, message: "timeout",
                                               endpoint: "203.0.113.10:8443")),
            ],
            checkedAt: Date(timeIntervalSince1970: 0))
        let report = VPSReportBuilder.make(result)
        XCTAssertTrue(report.contains("test-vps"))
        XCTAssertTrue(report.contains("主节点"))
        XCTAssertTrue(report.contains("203.0.113.10:40028"))
        XCTAssertTrue(report.contains("204"))
        XCTAssertTrue(report.contains("备用中转"))
        XCTAssertTrue(report.contains("203.0.113.10:8443"))
        XCTAssertTrue(report.contains("timeout"))
        XCTAssertTrue(report.contains("1.8 MB/s"))
        XCTAssertFalse(report.contains("11111111-2222-4333-8444-555555555555"))
        XCTAssertFalse(report.contains("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
    }

    func testParsesAutoLinksFromServerJSON() throws {
        let json = #"[{"name":"自动 49934","url":"vless://66666666-7777-4888-9999-000000000000@__HOST__:49934?encryption=none&security=reality&sni=example.com&fp=chrome&pbk=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB&type=tcp&headerType=none"}]"#
        let text = sample45 + "\nAUTO_VLESS_JSON=" + json + "\nOK=1\n"
        let s = try XCTUnwrap(VPSRemoteParser.parse(text))
        XCTAssertEqual(s.autoLinks.count, 1)
        XCTAssertEqual(s.autoLinks[0].name, "自动 49934")
        XCTAssertTrue(s.autoLinks[0].url.contains("__HOST__:49934"))
        XCTAssertFalse(s.autoLinks[0].url.contains("\n"))
        XCTAssertFalse(s.autoLinks[0].url.contains("\r"))
    }

    func testAutoRefreshPolicy() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 仅支持手动刷新，任何条件下均不自动刷新
        XCTAssertFalse(VPSRefreshPolicy.shouldAutoRefresh(lastRefresh: nil, needsData: false, now: now))
        XCTAssertFalse(VPSRefreshPolicy.shouldAutoRefresh(lastRefresh: nil, needsData: true, now: now))
        XCTAssertFalse(VPSRefreshPolicy.shouldAutoRefresh(lastRefresh: now.addingTimeInterval(-3600),
                                                          needsData: false, now: now))
        XCTAssertFalse(VPSRefreshPolicy.shouldAutoRefresh(lastRefresh: now.addingTimeInterval(-60),
                                                          needsData: true, now: now))
    }

    func testVPSConfigPersistsDisabledAliasesAndTime() throws {
        var config = VPSConfig()
        config.disabledAliases = ["sh-server", "bwg-248"]
        config.lastRefreshAt = 12_345
        let back = try JSONDecoder().decode(VPSConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back.disabledAliases, ["bwg-248", "sh-server"])
        XCTAssertEqual(back.lastRefreshAt, 12_345)
    }

    func testVPSConfigMigratesLegacyDisabledHosts() throws {
        let json = #"{"hosts":[{"sshAlias":"a","enabled":false},{"sshAlias":"b","enabled":true}],"lastRefreshAt":99}"#
        let config = try JSONDecoder().decode(VPSConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.disabledAliases, ["a"])
        XCTAssertEqual(config.lastRefreshAt, 99)
    }

    func testAliasValidation() {
        XCTAssertTrue(VPSHost.validAlias("racknerd-182"))
        XCTAssertTrue(VPSHost.validAlias("user@host"))
        XCTAssertFalse(VPSHost.validAlias(""))
        XCTAssertFalse(VPSHost.validAlias("-oProxyCommand=bad"))
        XCTAssertFalse(VPSHost.validAlias("host name"))
        XCTAssertFalse(VPSHost.validAlias("host;rm"))
    }

    func testSnapshotStoreRoundTripAndPermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("popbar-vps-snap-\(UUID().uuidString)")
        let fileURL = dir.appendingPathComponent("vps-snapshots.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let remote = try XCTUnwrap(VPSRemoteParser.parse(sample45))
        let host = VPSHost(name: "test-vps", sshAlias: "test-vps")
        let checkedAt = Date(timeIntervalSince1970: 1_764_000_000)
        let result = VPSHostResult(
            host: host,
            online: true,
            error: nil,
            latencyMs: 38,
            remote: remote,
            tcp: VPSTCPCheck(host: "203.0.113.10", port: 40028, ok: true, latencyMs: 165, error: nil),
            vlessChecks: [
                VPSLinkCheck(
                    id: "link-1",
                    name: "主节点",
                    endpoint: "203.0.113.10:40028",
                    check: VLESSCheck(state: .ok, latencyMs: 520, message: "", endpoint: "203.0.113.10:40028"),
                    url: "vless://11111111-2222-4333-8444-555555555555@203.0.113.10:40028?security=reality",
                    speed: VLESpeedCheck(state: .ok, megabytesPerSecond: 4.2, latencyMs: 510, message: "")
                )
            ],
            checkedAt: checkedAt
        )
        let cache = VPSSnapshotCache(lastRefresh: checkedAt, results: [host.id: result])
        VPSSnapshotStore.save(cache, to: fileURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)

        let restored = try XCTUnwrap(VPSSnapshotStore.load(from: fileURL))
        XCTAssertEqual(restored, cache)

        // 损坏文件应安全回退 nil
        try Data("not-json".utf8).write(to: fileURL)
        XCTAssertNil(VPSSnapshotStore.load(from: fileURL))
    }
}
