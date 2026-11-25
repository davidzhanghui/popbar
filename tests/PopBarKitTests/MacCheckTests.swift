import CMetrics
import XCTest
@testable import PopBarCore
@testable import PopBarKit

final class MacCheckTests: XCTestCase {

    func testSerialDecoderLegacyAndRandomized() {
        // 10 位新规随机序列号
        let rand = MCSerialDecoder.decode("H2W9X7Q1KP")
        XCTAssertTrue(rand.isRandomized)
        XCTAssertNil(rand.estimatedYear)
        XCTAssertNil(rand.estimatedWeek)

        // 12 位旧规序列号（C02 = Quanta Shanghai，Y = 2019 上半年，4 = 第 4 周）
        let legacy = MCSerialDecoder.decode("C02Y41ABCDEF")
        XCTAssertFalse(legacy.isRandomized)
        XCTAssertEqual(legacy.estimatedYear, 2019)
        XCTAssertEqual(legacy.estimatedWeek, 4)
        XCTAssertEqual(legacy.factory, "Quanta Computer (Shanghai)")

        // 下半年周数应从 27 开始
        let h2 = MCSerialDecoder.decode("FVFZ12345678")
        XCTAssertEqual(h2.estimatedYear, 2019)
        XCTAssertEqual(h2.estimatedWeek, 27)
        // 11 位早期序列号同样应能解码
        let legacy11 = MCSerialDecoder.decode("C02Y41ABCDE")
        XCTAssertFalse(legacy11.isRandomized)
        XCTAssertEqual(legacy11.estimatedYear, 2019)
        XCTAssertEqual(legacy11.estimatedWeek, 4)

        // 预计机龄与中文营销名本地化
        XCTAssertNotNil(MCSerialDecoder.estimatedAgeText(modelYear: "2021", nowYear: 2026))
        XCTAssertNil(MCSerialDecoder.estimatedAgeText(modelYear: "invalid", nowYear: 2026))
        let prevPref = L10n.preference
        L10n.preference = "zh"
        XCTAssertEqual(MacCheckEngine.localizeMarketingName("MacBook Pro (14-inch, 2021)"), "MacBook Pro（14 英寸，2021）")
        L10n.preference = prevPref
    }

    func testMDMBypassHostsDetection() {
        let sample = """
        # normal comment
        127.0.0.1 localhost
        # 0.0.0.0 deviceenrollment.apple.com
        0.0.0.0 deviceenrollment.apple.com
        127.0.0.1\tmdmenrollment.apple.com. # trailing comment
        ::1 iprofiles.apple.com
        """
        let hits = MacCheckEngine.detectBlockedMDMHosts(in: sample)
        XCTAssertEqual(hits.count, 3)
        XCTAssertTrue(hits[0].contains("deviceenrollment.apple.com"))
        XCTAssertTrue(hits[1].contains("mdmenrollment.apple.com"))
        XCTAssertTrue(hits[2].contains("iprofiles.apple.com"))

        let clean = """
        127.0.0.1 localhost
        255.255.255.255 broadcasthost
        """
        XCTAssertTrue(MacCheckEngine.detectBlockedMDMHosts(in: clean).isEmpty)
    }

    func testReportScoringRules() {
        let allPass = [
            MCCheckItem(id: "a", category: .specs, title: "A", status: .pass, summary: ""),
            MCCheckItem(id: "b", category: .battery, title: "B", status: .pass, summary: ""),
        ]
        XCTAssertEqual(MCReport.computeScore(items: allPass), 100)

        let oneWarn = allPass + [
            MCCheckItem(id: "c", category: .network, title: "C", status: .warning, summary: ""),
        ]
        XCTAssertEqual(MCReport.computeScore(items: oneWarn), 90)

        // 存在严重红旗时，分数封顶不超过 55
        let oneCritical = allPass + [
            MCCheckItem(id: "d", category: .security, title: "D", status: .critical, summary: ""),
        ]
        XCTAssertLessThanOrEqual(MCReport.computeScore(items: oneCritical), 55)
    }

    func testAIAdvisorMemoryBudgets() {
        let tiers16 = MCAIAdvisor.evaluate(totalMemoryGB: 16, isAppleSilicon: true)
        XCTAssertEqual(MCAIAdvisor.usableBudgetGB(totalMemoryGB: 16, isAppleSilicon: true), 12)
        XCTAssertEqual(tiers16.first(where: { $0.id == "3b" })?.fit, .smooth)
        XCTAssertEqual(tiers16.first(where: { $0.id == "14b" })?.fit, .tight)
        XCTAssertEqual(tiers16.first(where: { $0.id == "70b" })?.fit, .insufficient)

        let tiers64 = MCAIAdvisor.evaluate(totalMemoryGB: 64, isAppleSilicon: true)
        XCTAssertEqual(tiers64.first(where: { $0.id == "32b" })?.fit, .smooth)
        XCTAssertEqual(tiers64.first(where: { $0.id == "70b" })?.fit, .tight)
        XCTAssertEqual(MCAIAdvisor.sweetSpot(totalMemoryGB: 64, isAppleSilicon: true)?.id, "32b")
        XCTAssertEqual(MCAIAdvisor.resourceLinks.count, 4)
    }

    @MainActor
    func testPortSpeedLabelsAndKeyboardMapping() {
        XCTAssertEqual(MCPortsLiveModel.usbSpeedLabel(3), "USB 3.0 (5 Gbps)")
        XCTAssertEqual(MCPortsLiveModel.usbSpeedLabel(4), "USB 3.1 (10 Gbps)")
        XCTAssertEqual(MCPortsLiveModel.usbSpeedLabel(5), "USB 3.2 (20 Gbps)")
        XCTAssertEqual(MCKeyboardLayout.altVirtualKeyMap[160], 99)
        XCTAssertEqual(MCKeyboardLayout.mediaToFunctionKey[21], 97)
        XCTAssertEqual(MCKeyboardLayout.mediaToFunctionKey[17], 101)
    }

    func testHistoryStoreRoundTrip() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("popbar-mc-hist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rep = MCReport(generatedAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "3.7.1", profile: nil, items: [])
        let s1 = MCSavedSnapshot(id: UUID(), savedAt: Date(timeIntervalSince1970: 100), deviceName: "Mac A", serial: "SN1", score: 95, batteryCycles: 12, batteryHealthPct: 99, ssdWearPct: 1, report: rep)
        let s2 = MCSavedSnapshot(id: UUID(), savedAt: Date(timeIntervalSince1970: 200), deviceName: "Mac B", serial: "SN2", score: 80, batteryCycles: 320, batteryHealthPct: 86, ssdWearPct: 6, report: rep)

        XCTAssertTrue(MCHistoryStore.save([s1, s2], to: tmp))
        let loaded = MCHistoryStore.load(from: tmp)
        XCTAssertEqual(loaded.count, 2)
        // 按时间倒序排列
        XCTAssertEqual(loaded[0].serial, "SN2")
        XCTAssertEqual(loaded[1].serial, "SN1")
    }

    func testFastProbePerformanceAndModuleRegistration() async {
        // Phase 1 原生零子进程探测必须足够快（且能读出本机基础字段）
        let fast = MacCheckEngine.runFastProbe()
        XCTAssertFalse(fast.profile.chip.isEmpty)
        XCTAssertGreaterThan(fast.profile.memoryGB, 0)
        XCTAssertFalse(fast.items.isEmpty)
        XCTAssertLessThan(fast.profile.scanElapsedMs, 1500, "原生 Phase 1 探测不应耗时过长")

        // CMetrics NVMe SMART C 接口烟雾测试（不崩溃，若本机是 NVMe SSD 应返回合法温度与范围）
        var smart = CMNVMeSmart()
        if cm_read_nvme_smart(&smart) != 0 {
            XCTAssertEqual(smart.valid, 1)
            XCTAssertGreaterThan(smart.temperature_celsius, -20)
            XCTAssertLessThan(smart.temperature_celsius, 120)
            XCTAssertGreaterThanOrEqual(smart.percentage_used, 0)
        }

        // 默认配置中 maccheck 模块默认关闭且可注册查找
        XCTAssertEqual(ConfigMigration.moduleDefaults["maccheck"], false)
        await MainActor.run {
            XCTAssertNotNil(ModuleRegistry.shared.module("maccheck"))
        }
    }
}
