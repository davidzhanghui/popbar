import XCTest
@testable import PopBarCore

final class KeyComboTests: XCTestCase {
    func testParseAndDisplay() {
        let c = KeyCombo("ctrl+opt+b")
        XCTAssertEqual(c?.modifiers, [.control, .option])
        XCTAssertEqual(c?.keyCode, 11)
        XCTAssertEqual(c?.display, "⌃⌥B")
        XCTAssertEqual(c?.spec, "ctrl+opt+b")
        XCTAssertEqual(KeyCombo("Control + Option + Space")?.display, "⌃⌥Space")
        XCTAssertEqual(KeyCombo("opt+cmd+v")?.display, "⌥⌘V")
        XCTAssertEqual(KeyCombo("ctrl+opt+shift+r")?.spec, "ctrl+opt+shift+r")
        XCTAssertNil(KeyCombo(""))
        XCTAssertNil(KeyCombo("ctrl+opt+nope"))
        XCTAssertEqual(KeyCombo.display("ctrl+f5"), "⌃F5")
    }

    func testSpecRoundTrip() {
        for s in ["ctrl+opt+p", "cmd+shift+4", "ctrl+opt+space", "opt+cmd+v", "ctrl+f12", "ctrl+opt+return"] {
            XCTAssertEqual(KeyCombo(KeyCombo(s)!.spec), KeyCombo(s), s)
        }
    }

    func testIssuesDetectDuplicatesReservedAndInvalid() {
        let issues = HotkeyAnalysis.issues([
            (id: "showBar", spec: "ctrl+opt+space"),
            (id: "snap", spec: "ctrl+opt+p"),
            (id: "todo", spec: "ctrl+opt+p"),
            (id: "ocr", spec: ""),
            (id: "bad", spec: "ctrl+opt+zz"),
            (id: "bare", spec: "a"),
        ])
        if case .systemReserved = issues["showBar"] {} else { XCTFail("ctrl+opt+space 应提示系统占用") }
        XCTAssertEqual(issues["todo"], .duplicate("snap"))
        XCTAssertEqual(issues["snap"], .duplicate("todo"))
        XCTAssertNil(issues["ocr"], "空串表示未设置，不报问题")
        XCTAssertEqual(issues["bad"], .invalid)
        XCTAssertEqual(issues["bare"], .invalid)
    }

    func testTableSkipsInvalidAndDuplicates() {
        let t = HotkeyAnalysis.table([
            (id: "a", spec: "ctrl+opt+b"), (id: "b", spec: "ctrl+opt+b"), (id: "c", spec: ""), (id: "d", spec: "x"),
        ])
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[KeyCombo("ctrl+opt+b")!], "a")
    }
}

final class LenientEnumTests: XCTestCase {
    struct Box: Codable { var mode: TriggerMode; var g: GuardMode }

    func testUnknownValuesFallBack() throws {
        let b = try JSONDecoder().decode(Box.self, from: Data(#"{"mode":"keyboard","g":"whatever"}"#.utf8))
        XCTAssertEqual(b.mode, .both)
        XCTAssertEqual(b.g, .ask)
        let b2 = try JSONDecoder().decode(Box.self, from: Data(#"{"mode":"drag","g":"mask"}"#.utf8))
        XCTAssertEqual(b2.mode, .drag)
        XCTAssertEqual(b2.g, .mask)
        let enc = String(decoding: try JSONEncoder().encode(b2), as: UTF8.self)
        XCTAssertTrue(enc.contains(#""mode":"drag""#))
    }

    func testSearchEngineURL() {
        XCTAssertEqual(SearchEngine.baidu.url(for: "a b")?.absoluteString, "https://www.baidu.com/s?wd=a%20b")
        XCTAssertEqual(SearchEngine(lenient: "nope"), .google)
    }
}

final class ConfigMigrationTests: XCTestCase {
    func testOldDefaultsAreReplacedButCustomKept() {
        var j: [String: Any] = ["hotkeys": ["showBar": "ctrl+opt+space", "snap": "ctrl+opt+p"], "triggerMode": "keyboard"]
        XCTAssertTrue(ConfigMigration.migrate(&j))
        let hk = j["hotkeys"] as? [String: Any]
        XCTAssertEqual(hk?["showBar"] as? String, "ctrl+opt+b")
        XCTAssertEqual(hk?["snap"] as? String, "ctrl+opt+p")
        XCTAssertEqual(j["triggerMode"] as? String, "both")
        XCTAssertEqual(j["schemaVersion"] as? Int, ConfigMigration.currentVersion)

        var custom: [String: Any] = ["hotkeys": ["showBar": "ctrl+shift+x"]]
        ConfigMigration.migrate(&custom)
        XCTAssertEqual((custom["hotkeys"] as? [String: Any])?["showBar"] as? String, "ctrl+shift+x", "用户改过的不动")
    }

    func testModuleDefaultsAndIdempotent() {
        var j: [String: Any] = ["modules": ["tv": true]]
        ConfigMigration.migrate(&j)
        let m = j["modules"] as? [String: Bool]
        XCTAssertEqual(m?["tv"], true, "已有的开关保留")
        XCTAssertEqual(m?["print"], false)
        XCTAssertEqual(m?["today"], true)
        XCTAssertFalse(ConfigMigration.migrate(&j), "已经是新版本时不再迁移")
    }

    func testSearchButtonsMerged() {
        var j: [String: Any] = ["toolbar": ["items": [
            ["id": "builtin.copy", "visible": true], ["id": "builtin.google", "visible": false],
            ["id": "builtin.baidu", "visible": true], ["id": "builtin.ai", "visible": true],
        ], "contextPosition": "front"]]
        ConfigMigration.migrate(&j)
        let tb = j["toolbar"] as? [String: Any]
        let ids = (tb?["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["builtin.copy", "builtin.search", "builtin.ai"])
        XCTAssertEqual(tb?["searchEngine"] as? String, "baidu")
        XCTAssertNil(tb?["contextPosition"])
    }

    func testFileMigrationWritesBackup() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("popbar-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.json")
        let original = #"{"hotkeys":{"showBar":"ctrl+opt+space"},"providers":[{"apiKey":"sk-1"}]}"#
        try original.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotNil(ConfigMigration.migrateFile(at: file))
        let backup = try String(contentsOf: dir.appendingPathComponent("config.v2.json"), encoding: .utf8)
        XCTAssertEqual(backup, original)
        let migrated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(migrated.contains("ctrl+opt+b"))
        XCTAssertTrue(migrated.contains("sk-1"), "API Key 原样保留")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertNil(ConfigMigration.migrateFile(at: file), "第二次不再迁移")
    }
}

final class ContextDetectorCoreTests: XCTestCase {
    func testColorWithoutAppKit() {
        let c = ContextDetector.asColor("#FF6600")
        XCTAssertEqual(c?.r, 1)
        XCTAssertEqual(c.map { Int(($0.g * 255).rounded()) }, 102)
        let h = ContextDetector.asColor("hsl(0, 100%, 100%)")
        XCTAssertEqual(h?.r, 1)
        XCTAssertEqual(h?.g, 0)
    }

    func testCalc() {
        XCTAssertEqual(ContextDetector.evaluate("12*(3+4)"), "84")
        XCTAssertTrue(ContextDetector.detect("12*(3+4)").contains(.calc("84")))
    }
}
