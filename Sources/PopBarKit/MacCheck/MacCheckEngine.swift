import CMetrics
import CoreWLAN
import Foundation
import IOKit
import PopBarCore

/// 高性能两阶段硬件探测引擎：
/// - Phase 1（亚毫秒级，0 子进程）：sysctl + IOKit（序列号/机型名/电池/NVMe SMART）+ CoreWLAN + /etc/hosts 绕过检查 + 磁盘空间
/// - Phase 2（全并发 TaskGroup）：单次合并调用 `system_profiler`（6 类数据一次拉取）并行 `profiles` / `defaults`
enum MacCheckEngine {

    struct FastProbeResult: Sendable {
        var profile: MCDeviceProfile
        var items: [MCCheckItem]
        var batteryCycles: Int?
        var batteryHealthPct: Int?
        var ssdWearPct: Int?
    }

    struct FullProbeResult: Sendable {
        var profile: MCDeviceProfile
        var items: [MCCheckItem]
        var batteryCycles: Int?
        var batteryHealthPct: Int?
        var ssdWearPct: Int?
    }

    // MARK: - Phase 1：原生零子进程极速探测（通常 < 15ms）

    static func runFastProbe() -> FastProbeResult {
        let t0 = DispatchTime.now().uptimeNanoseconds

        let chip = sysctlString("machdep.cpu.brand_string")
        let modelID = sysctlString("hw.model")
        let physCores = sysctlInt("hw.physicalcpu")
        let pCores = sysctlInt("hw.perflevel0.physicalcpu")
        let eCores = sysctlInt("hw.perflevel1.physicalcpu")
        let memBytes = ProcessInfo.processInfo.physicalMemory
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let arch = "Apple Silicon (arm64)"
        #else
        let arch = sysctlInt("sysctl.proc_translated") == 1 ? "Apple Silicon (Rosetta)" : "Intel (x86_64)"
        #endif

        let ioPlatform = readPlatformExpertInfo()
        let rawProduct = readIORegistryProductName() ?? friendlyModelFallback(modelID: modelID, chip: chip)
        let productName = localizeMarketingName(rawProduct)
        let serialInfo = MCSerialDecoder.decode(ioPlatform.serial)
        let yearText = inferModelYear(productName: rawProduct, serialInfo: serialInfo)

        let profile = MCDeviceProfile(
            marketingName: productName,
            modelIdentifier: modelID.isEmpty ? L10n.t("未知", "Unknown") : modelID,
            chip: chip.isEmpty ? L10n.t("未知芯片", "Unknown Chip") : chip,
            architecture: arch,
            physicalCores: physCores,
            pCores: pCores,
            eCores: eCores,
            memoryBytes: memBytes,
            macOSVersion: "macOS \(osVer)",
            serialNumber: ioPlatform.serial,
            modelYear: yearText,
            hardwareUUID: ioPlatform.uuid,
            scanElapsedMs: elapsedMs(since: t0)
        )

        var items: [MCCheckItem] = []
        items.append(buildSpecsItem(profile: profile, serialInfo: serialInfo))

        let battery = probeBatteryNative()
        items.append(contentsOf: battery.items)

        let storage = probeStorageNative(nvmeInfo: nil)
        items.append(storage.item)

        items.append(probeWiFiNative())

        return FastProbeResult(
            profile: profile,
            items: items,
            batteryCycles: battery.cycles,
            batteryHealthPct: battery.healthPct,
            ssdWearPct: storage.wearPct
        )
    }

    // MARK: - Phase 2：并发外部探测（单次合并 system_profiler + 并行 profiles/defaults）

    static func runFullProbe(reusing fastInput: FastProbeResult? = nil) async -> FullProbeResult {
        let t0 = DispatchTime.now().uptimeNanoseconds

        async let fastTask: FastProbeResult = {
            if let fastInput { return fastInput }
            return await Task.detached(priority: .userInitiated) { runFastProbe() }.value
        }()
        // 关键性能点：将 6 类 system_profiler 合并为一次进程调用与一次 JSON 解析，较串行调用提速 3–5 倍
        async let spTask = Task.detached(priority: .userInitiated) {
            Shell.run(
                "/usr/sbin/system_profiler",
                [
                    "SPHardwareDataType",
                    "SPiBridgeDataType",
                    "SPNVMeDataType",
                    "SPBluetoothDataType",
                    "SPUSBDataType",
                    "SPThunderboltDataType",
                    "-json",
                ],
                timeout: 12,
                maxOutput: 8 << 20
            )
        }.value
        async let mdmTask = Task.detached(priority: .userInitiated) {
            Shell.run("/usr/bin/profiles", ["status", "-type", "enrollment"], timeout: 5)
        }.value
        async let icloudTask = Task.detached(priority: .userInitiated) {
            Shell.run("/usr/bin/defaults", ["read", "MobileMeAccounts", "Accounts"], timeout: 5)
        }.value

        let fast = await fastTask
        let spOut = await spTask
        let mdmOut = await mdmTask
        let icloudOut = await icloudTask

        let spJSON: [String: Any] = (try? JSONSerialization.jsonObject(with: spOut.stdout)) as? [String: Any] ?? [:]

        // 用 SPHardwareDataType 校准机型名称、芯片名（防 Rosetta 下显示 VirtualApple）与序列号
        var profile = fast.profile
        let hwDict = (spJSON["SPHardwareDataType"] as? [[String: Any]])?.first ?? [:]
        if let spName = hwDict["machine_name"] as? String, !spName.isEmpty, profile.marketingName == profile.modelIdentifier {
            profile.marketingName = localizeMarketingName(spName)
        }
        if let chipType = (hwDict["chip_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !chipType.isEmpty, chipType.lowercased() != "unknown" {
            profile.chip = chipType
        } else if let cpuType = (hwDict["cpu_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cpuType.isEmpty, cpuType.lowercased() != "unknown",
                  profile.chip.isEmpty || profile.chip.contains("VirtualApple") {
            profile.chip = cpuType
        }
        if profile.serialNumber.isEmpty, let sn = hwDict["serial_number"] as? String {
            profile.serialNumber = sn
        }
        profile.scanElapsedMs = fast.profile.scanElapsedMs + elapsedMs(since: t0)

        let serialInfo = MCSerialDecoder.decode(profile.serialNumber)
        var items: [MCCheckItem] = []

        // 1. 硬件规格
        items.append(buildSpecsItem(profile: profile, serialInfo: serialInfo, hwDict: hwDict))

        // 2. 电池（直接复用 Phase 1 原生 IOKit 结果，避免重复遍历）
        let batteryItems = fast.items.filter { $0.category == .battery }
        items.append(contentsOf: batteryItems)

        // 3. 安全与锁定（双源防篡改序列号/机型 + 安全芯片 + MDM & 绕过痕迹 + Apple ID + 激活锁）
        let ioSerial = fast.profile.serialNumber
        items.append(contentsOf: buildSecurityItems(
            profile: profile,
            ioSerial: ioSerial,
            serialInfo: serialInfo,
            hwDict: hwDict,
            spJSON: spJSON,
            mdmOutput: mdmOut.text,
            icloudOutput: icloudOut.text
        ))

        // 4. 存储与 NVMe SMART（IOKit C 直读 + SPNVMeDataType 合并 TRIM / SMART 状态）
        let storage = probeStorageNative(nvmeInfo: spJSON["SPNVMeDataType"] as? [[String: Any]])
        items.append(storage.item)

        // 5. 网络（复用 Phase 1 原生 CoreWLAN Wi-Fi + SPBluetoothDataType 蓝牙）
        if let wifi = fast.items.first(where: { $0.id == "network.wifi" }) {
            items.append(wifi)
        } else {
            items.append(probeWiFiNative())
        }
        items.append(buildBluetoothItem(spJSON: spJSON))

        // 6. 接口（USB + Thunderbolt）
        items.append(buildPortsItem(spJSON: spJSON))

        return FullProbeResult(
            profile: profile,
            items: items,
            batteryCycles: fast.batteryCycles,
            batteryHealthPct: fast.batteryHealthPct,
            ssdWearPct: storage.wearPct
        )
    }

    // MARK: - 1. 硬件规格

    private static func buildSpecsItem(
        profile: MCDeviceProfile,
        serialInfo: MCSerialInfo,
        hwDict: [String: Any] = [:]
    ) -> MCCheckItem {
        var details: [MCDetailPair] = [
            .init(L10n.t("机型名称", "Model Name"), profile.marketingName),
            .init(L10n.t("机型标识", "Model Identifier"), profile.modelIdentifier, mono: true),
            .init(L10n.t("芯片", "Chip"), profile.chip),
            .init(L10n.t("架构", "Architecture"), profile.architecture),
        ]
        if profile.pCores > 0 || profile.eCores > 0 {
            details.append(.init(
                L10n.t("处理器核心", "CPU Cores"),
                L10n.t("\(profile.physicalCores) 核（\(profile.pCores) 性能 + \(profile.eCores) 能效）",
                       "\(profile.physicalCores) cores (\(profile.pCores)P + \(profile.eCores)E)")
            ))
        } else if profile.physicalCores > 0 {
            details.append(.init(L10n.t("处理器核心", "CPU Cores"), "\(profile.physicalCores)"))
        }
        details.append(.init(L10n.t("物理内存", "Memory"), profile.memoryDisplay))
        details.append(.init(L10n.t("系统版本", "macOS"), profile.macOSVersion))
        if !profile.modelYear.isEmpty {
            details.append(.init(L10n.t("推算年款", "Model Year"), profile.modelYear))
            if let age = MCSerialDecoder.estimatedAgeText(modelYear: profile.modelYear) {
                details.append(.init(L10n.t("预计机龄", "Estimated Age"), age))
            }
        }
        if !profile.serialNumber.isEmpty {
            details.append(.init(L10n.t("序列号", "Serial Number"), profile.serialNumber, mono: true))
        }
        if let modelNum = hwDict["model_number"] as? String, !modelNum.isEmpty {
            details.append(.init(L10n.t("型号编号", "Part Number"), modelNum, mono: true))
        }
        if let year = serialInfo.estimatedYear, let week = serialInfo.estimatedWeek {
            details.append(.init(L10n.t("出厂批次", "Manufacture Batch"), L10n.t("\(year) 年第 \(week) 周", "Year \(year), Week \(week)")))
        }
        if let factory = serialInfo.factory {
            details.append(.init(L10n.t("代工厂", "Factory"), factory))
        }
        if !profile.hardwareUUID.isEmpty {
            details.append(.init(L10n.t("硬件 UUID", "Hardware UUID"), profile.hardwareUUID, mono: true))
        }

        return MCCheckItem(
            id: "specs.overview",
            category: .specs,
            title: L10n.t("硬件基础规格", "Hardware Specification"),
            status: .pass,
            summary: "\(profile.chip) · \(profile.memoryDisplay) · \(profile.modelIdentifier)",
            details: details
        )
    }

    // MARK: - 2. 电池（纯 IOKit AppleSmartBattery 直读，零子进程）

    private struct NativeBatteryResult {
        var items: [MCCheckItem]
        var cycles: Int?
        var healthPct: Int?
    }

    private static func probeBatteryNative() -> NativeBatteryResult {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return NativeBatteryResult(
                items: [MCCheckItem(
                    id: "battery.status",
                    category: .battery,
                    title: L10n.t("电池状态", "Battery"),
                    status: .unsupported,
                    summary: L10n.t("台式 Mac 无内置电池", "Desktop Mac without an internal battery")
                )],
                cycles: nil,
                healthPct: nil
            )
        }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = propsRef?.takeRetainedValue() as? [String: Any] else {
            return NativeBatteryResult(
                items: [MCCheckItem(
                    id: "battery.status",
                    category: .battery,
                    title: L10n.t("电池状态", "Battery"),
                    status: .warning,
                    summary: L10n.t("未能读取电池传感器属性", "Unable to read battery sensor properties")
                )],
                cycles: nil,
                healthPct: nil
            )
        }

        let cycles = dict["CycleCount"] as? Int ?? 0
        let designCap = dict["DesignCapacity"] as? Int ?? 0
        // Apple Silicon 上 AppleRawMaxCapacity 为真实 mAh；MaxCapacity 常为百分比 100
        let rawMaxCap = dict["AppleRawMaxCapacity"] as? Int ?? (dict["NominalChargeCapacity"] as? Int ?? (dict["MaxCapacity"] as? Int ?? 0))
        let rawCurCap = dict["AppleRawCurrentCapacity"] as? Int ?? (dict["CurrentCapacity"] as? Int ?? 0)
        let currentPct = dict["CurrentCapacity"] as? Int ?? (rawMaxCap > 0 ? Int((Double(rawCurCap) * 100.0 / Double(rawMaxCap)).rounded()) : 0)
        let tempRaw = dict["Temperature"] as? Int ?? 0
        let tempC = tempRaw > 0 ? Double(tempRaw) / 100.0 : nil
        let voltageMv = dict["Voltage"] as? Int ?? 0
        let isCharging = (dict["IsCharging"] as? Bool) ?? false
        let extConnected = (dict["ExternalConnected"] as? Bool) ?? false
        let batterySerial = (dict["BatterySerialNumber"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let adapterDict = dict["AdapterDetails"] as? [String: Any]
        let adapterWatts = adapterDict?["Watts"] as? Int

        let healthPct: Int = {
            guard designCap > 0, rawMaxCap > 0 else { return 100 }
            return min(100, max(1, Int((Double(rawMaxCap) * 100.0 / Double(designCap)).rounded())))
        }()

        let cycleStatus: MCStatus = cycles >= 800 ? .warning : .pass
        let cycleSummary: String = {
            if cycles >= 800 {
                return L10n.t("循环 \(cycles) 次，已接近设计寿命上限（1000 次）", "\(cycles) cycles, approaching the 1000-cycle rating")
            }
            if cycles >= 400 {
                return L10n.t("循环 \(cycles) 次，属于中度使用", "\(cycles) cycles, moderate usage")
            }
            return L10n.t("循环 \(cycles) 次，损耗较轻", "\(cycles) cycles, light wear")
        }()

        let healthStatus: MCStatus = healthPct < 75 ? .critical : (healthPct < 82 ? .warning : .pass)
        let healthSummary: String = {
            if healthPct < 75 {
                return L10n.t("健康度 \(healthPct)%，建议更换电池", "Health \(healthPct)%, battery service recommended")
            }
            if healthPct < 82 {
                return L10n.t("健康度 \(healthPct)%，已出现明显衰减", "Health \(healthPct)%, noticeable wear")
            }
            return L10n.t("健康度 \(healthPct)%，状态良好", "Health \(healthPct)%, good condition")
        }()

        var details: [MCDetailPair] = [
            .init(L10n.t("循环次数", "Cycle Count"), "\(cycles)"),
            .init(L10n.t("最大容量健康度", "Maximum Capacity"), "\(healthPct)%"),
            .init(L10n.t("当前电量", "Current Charge"), "\(currentPct)%"),
            .init(L10n.t("当前满充容量", "Full Charge Capacity"), "\(rawMaxCap) mAh"),
            .init(L10n.t("出厂设计容量", "Design Capacity"), "\(designCap) mAh"),
            .init(L10n.t("电源状态", "Power State"), isCharging ? L10n.t("充电中", "Charging") : (extConnected ? L10n.t("已接外接电源", "AC Connected") : L10n.t("电池供电", "On Battery"))),
        ]
        if let tempC {
            details.append(.init(L10n.t("电池温度", "Temperature"), String(format: "%.1f °C", tempC)))
        }
        if voltageMv > 0 {
            details.append(.init(L10n.t("当前电压", "Voltage"), String(format: "%.2f V", Double(voltageMv) / 1000.0)))
        }
        if let adapterWatts, adapterWatts > 0 {
            details.append(.init(L10n.t("适配器功率", "Adapter Power"), "\(adapterWatts) W"))
        }
        if !batterySerial.isEmpty {
            details.append(.init(L10n.t("电池序列号", "Battery Serial"), batterySerial, mono: true))
        }

        let itemCycle = MCCheckItem(
            id: "battery.cycles",
            category: .battery,
            title: L10n.t("电池循环次数", "Battery Cycle Count"),
            status: cycleStatus,
            summary: cycleSummary,
            details: Array(details.prefix(2))
        )
        let itemHealth = MCCheckItem(
            id: "battery.health",
            category: .battery,
            title: L10n.t("电池容量与状态", "Battery Health & Power"),
            status: healthStatus,
            summary: healthSummary,
            details: details
        )
        return NativeBatteryResult(items: [itemCycle, itemHealth], cycles: cycles, healthPct: healthPct)
    }

    // MARK: - 3. 安全与锁定（MDM、绕过痕迹、激活锁、Apple ID、安全芯片、序列号）

    struct MDMBypassCheck: Sendable, Equatable {
        var blockedHostsLines: [String] = []
        var forgedMarkerFiles: [String] = []
        var suspicious: Bool { !blockedHostsLines.isEmpty || !forgedMarkerFiles.isEmpty }
    }

    static let mdmProtectedHosts: Set<String> = [
        "deviceenrollment.apple.com",
        "mdmenrollment.apple.com",
        "iprofiles.apple.com",
        "acmdm.apple.com",
    ]

    /// 纯函数解析 `/etc/hosts`，检出重定向 Apple MDM/DEP 注册域名的有效行
    static func detectBlockedMDMHosts(in hostsText: String) -> [String] {
        var matched: [String] = []
        for rawLine in hostsText.split(whereSeparator: \.isNewline) {
            let clean = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = clean.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let domains = parts.dropFirst().map { tok -> String in
                let lower = tok.lowercased()
                return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
            }
            if domains.contains(where: { mdmProtectedHosts.contains($0) }) {
                matched.append(String(clean).trimmingCharacters(in: .whitespaces))
            }
        }
        return matched
    }

    private static func checkMDMBypass(mdmEnrolled: Bool?) -> MDMBypassCheck {
        var out = MDMBypassCheck()
        if let hosts = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) {
            out.blockedHostsLines = detectBlockedMDMHosts(in: hosts)
        }
        let dir = "/var/db/ConfigurationProfiles/Settings"
        let fm = FileManager.default
        let hasInstalled = fm.fileExists(atPath: "\(dir)/.cloudConfigProfileInstalled")
        let hasNotFound = fm.fileExists(atPath: "\(dir)/.cloudConfigRecordNotFound")
        if hasInstalled && hasNotFound && mdmEnrolled != true {
            out.forgedMarkerFiles = [".cloudConfigProfileInstalled", ".cloudConfigRecordNotFound"]
        }
        return out
    }

    private static func parseYesNoFlag(in text: String, after marker: String) -> Bool? {
        guard let r = text.range(of: marker) else { return nil }
        let tail = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
        if tail.hasPrefix("Yes") { return true }
        if tail.hasPrefix("No") { return false }
        return nil
    }

    private static func buildSecurityItems(
        profile: MCDeviceProfile,
        ioSerial: String,
        serialInfo: MCSerialInfo,
        hwDict: [String: Any],
        spJSON: [String: Any],
        mdmOutput: String,
        icloudOutput: String
    ) -> [MCCheckItem] {
        var out: [MCCheckItem] = []

        // 3.1 序列号与机型双源交叉防篡改核验（IOKit vs system_profiler）
        let spSerial = ((hwDict["serial_number"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let spModel = ((hwDict["machine_model"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let serialMismatch = !ioSerial.isEmpty && !spSerial.isEmpty && ioSerial != spSerial
        let modelMismatch = !profile.modelIdentifier.isEmpty && !spModel.isEmpty && profile.modelIdentifier != spModel
        let hasSerial = !profile.serialNumber.isEmpty

        var serialDetails: [MCDetailPair] = [
            .init(L10n.t("IOKit 序列号", "IOKit Serial"), ioSerial.isEmpty ? L10n.t("未读到", "Unavailable") : ioSerial, mono: true),
            .init(L10n.t("系统信息序列号", "System Profiler Serial"), spSerial.isEmpty ? L10n.t("未读到", "Unavailable") : spSerial, mono: true),
            .init(L10n.t("机型双源核对", "Model Cross-Check"), modelMismatch ? L10n.t("不一致（\(profile.modelIdentifier) vs \(spModel)）", "Mismatch (\(profile.modelIdentifier) vs \(spModel))") : L10n.t("一致（\(profile.modelIdentifier)）", "Match (\(profile.modelIdentifier))")),
            .init(L10n.t("编码格式", "Format"), serialInfo.isRandomized ? L10n.t("10 位随机号（2021 年后新规）", "10-char randomized (2021+)") : L10n.t("\(profile.serialNumber.count) 位传统编码", "\(profile.serialNumber.count)-char legacy")),
        ]
        if let y = serialInfo.estimatedYear, let w = serialInfo.estimatedWeek {
            serialDetails.append(.init(L10n.t("推算出厂时间", "Estimated Build"), L10n.t("\(y) 年第 \(w) 周", "Year \(y), Week \(w)")))
        }
        if serialMismatch || modelMismatch {
            out.append(MCCheckItem(
                id: "security.serial",
                category: .security,
                title: L10n.t("序列号与机型防篡改核验", "Serial & Model Integrity"),
                status: .critical,
                summary: L10n.t("IOKit 与系统信息读取到的序列号或机型不一致，存在篡改风险", "IOKit and System Profiler disagree on serial or model identifier"),
                details: serialDetails,
                riskNotice: L10n.t(
                    "两条独立底层通道读取的序列号或机型标识不一致，可能存在软件伪造或主板刷写异常。请勿仅凭软件截图交易，务必与底壳镭雕及 Apple 官网核对。",
                    "Two independent low-level queries disagree on serial number or model ID, indicating possible spoofing or logic-board tampering. Verify against chassis engraving and Apple's website."
                )
            ))
        } else {
            out.append(MCCheckItem(
                id: "security.serial",
                category: .security,
                title: L10n.t("序列号与机型防篡改核验", "Serial & Model Integrity"),
                status: hasSerial ? .pass : .warning,
                summary: hasSerial
                    ? L10n.t("双源核验一致（\(profile.serialNumber)），请与机身底壳及 Apple 官网保修页核对", "Cross-check passed (\(profile.serialNumber)); verify with chassis engraving and Apple coverage")
                    : L10n.t("未读取到主板序列号，存在换板或虚拟机环境风险", "Logic board serial missing; check for VM or board replacement"),
                details: serialDetails
            ))
        }

        // 3.2 安全芯片 / 启动安全性
        let iBridge = (spJSON["SPiBridgeDataType"] as? [[String: Any]])?.first
        let isArm = profile.architecture.contains("Apple Silicon")
        let secureTitle = L10n.t("安全芯片", "Security Chip")
        if isArm {
            out.append(MCCheckItem(
                id: "security.chip",
                category: .security,
                title: secureTitle,
                status: .pass,
                summary: L10n.t("Apple Silicon 内置安全隔区（Secure Enclave）", "Apple Silicon integrated Secure Enclave"),
                details: [.init(L10n.t("芯片类型", "Security Engine"), "Apple Silicon Secure Enclave")]
            ))
        } else if let model = iBridge?["ibridge_model_name"] as? String, !model.isEmpty {
            let boot = (iBridge?["ibridge_boot_uuid"] as? String) ?? ""
            var d: [MCDetailPair] = [.init(L10n.t("安全芯片", "Chip"), model)]
            if !boot.isEmpty { d.append(.init("Boot UUID", boot, mono: true)) }
            out.append(MCCheckItem(
                id: "security.chip",
                category: .security,
                title: secureTitle,
                status: .pass,
                summary: L10n.t("检测到 \(model)", "Detected \(model)"),
                details: d
            ))
        } else {
            out.append(MCCheckItem(
                id: "security.chip",
                category: .security,
                title: secureTitle,
                status: .unsupported,
                summary: L10n.t("未检测到独立 T2 安全芯片（老款 Intel 机型）", "No discrete T2 security chip (older Intel Mac)")
            ))
        }

        // 3.3 MDM 监管与绕过检测
        let dep = parseYesNoFlag(in: mdmOutput, after: "Enrolled via DEP:")
        let mdm = parseYesNoFlag(in: mdmOutput, after: "MDM enrollment:")
        let bypass = checkMDMBypass(mdmEnrolled: mdm)
        let mdmDetails: [MCDetailPair] = [
            .init(L10n.t("DEP 自动注册", "DEP Auto-Enrollment"), dep.map { $0 ? L10n.t("是", "Yes") : L10n.t("否", "No") } ?? L10n.t("未知", "Unknown")),
            .init(L10n.t("MDM 已监管", "MDM Supervised"), mdm.map { $0 ? L10n.t("是", "Yes") : L10n.t("否", "No") } ?? L10n.t("未知", "Unknown")),
            .init(L10n.t("hosts 屏蔽注册域名", "Blocked MDM Hosts"), bypass.blockedHostsLines.isEmpty ? L10n.t("无", "None") : bypass.blockedHostsLines.joined(separator: "；")),
            .init(L10n.t("伪造云配置标记", "Forged Cloud Markers"), bypass.forgedMarkerFiles.isEmpty ? L10n.t("无", "None") : bypass.forgedMarkerFiles.joined(separator: "、")),
        ]

        if mdm != true && bypass.suspicious {
            out.append(MCCheckItem(
                id: "security.mdm",
                category: .security,
                title: L10n.t("MDM 设备监管", "MDM Supervision"),
                status: .critical,
                summary: L10n.t("疑似存在脚本绕过 MDM 痕迹", "Suspected scripted MDM bypass traces found"),
                details: mdmDetails,
                riskNotice: L10n.t(
                    "本机表面显示未监管，但检测到 hosts 屏蔽 Apple 注册服务器或伪造的云配置标记。重装或升级系统后极可能重新锁回原企业管理，二手机交易请高度警惕。",
                    "This Mac appears unsupervised, yet hosts-file blocking or forged cloud-config markers were found. Reinstalling or updating macOS will likely re-lock it to an organization."
                )
            ))
        } else if mdm == true {
            out.append(MCCheckItem(
                id: "security.mdm",
                category: .security,
                title: L10n.t("MDM 设备监管", "MDM Supervision"),
                status: .critical,
                summary: L10n.t("此机处于企业或学校 MDM 监管之下", "Enrolled under organization MDM supervision"),
                details: mdmDetails,
                riskNotice: L10n.t(
                    "该设备受远程 MDM 监管，管理方可施加限制或远程抹除，普通重装系统无法解除。购买前必须确认原机构已在 Apple Business Manager 解绑。",
                    "Managed by an organization's MDM. Reinstalling macOS will not remove DEP supervision. Require proof of release before buying."
                )
            ))
        } else if dep == true {
            out.append(MCCheckItem(
                id: "security.mdm",
                category: .security,
                title: L10n.t("MDM 设备监管", "MDM Supervision"),
                status: .warning,
                summary: L10n.t("存在 DEP 自动注册记录，重装联网后可能重新受管", "DEP record present; reinstalling online may re-enroll MDM"),
                details: mdmDetails,
                riskNotice: L10n.t(
                    "检测到 DEP 记录，抹掉重装系统时可能自动拉回企业监管。",
                    "DEP enrollment flag detected; erasing macOS may trigger automatic management."
                )
            ))
        } else if mdm == nil {
            out.append(MCCheckItem(
                id: "security.mdm",
                category: .security,
                title: L10n.t("MDM 设备监管", "MDM Supervision"),
                status: .warning,
                summary: L10n.t("未能确认 MDM 状态，请在系统设置中核查描述文件", "Could not verify MDM status; check Profiles in System Settings"),
                details: mdmDetails
            ))
        } else {
            out.append(MCCheckItem(
                id: "security.mdm",
                category: .security,
                title: L10n.t("MDM 设备监管", "MDM Supervision"),
                status: .pass,
                summary: L10n.t("未受 MDM 监管，未发现绕过痕迹", "No MDM supervision or bypass traces found"),
                details: mdmDetails
            ))
        }

        // 3.4 激活锁
        let lockRaw = (hwDict["activation_lock_status"] as? String) ?? ""
        if !lockRaw.isEmpty {
            let locked = lockRaw.lowercased().contains("enabled")
            out.append(MCCheckItem(
                id: "security.activationLock",
                category: .security,
                title: L10n.t("激活锁（查找我的 Mac）", "Activation Lock"),
                status: locked ? .critical : .pass,
                summary: locked ? L10n.t("激活锁已开启，二手机过户前必须由原机主关闭", "Activation Lock is enabled; previous owner must turn it off") : L10n.t("激活锁已关闭", "Activation Lock is disabled"),
                details: [.init(L10n.t("系统原始状态", "Raw Status"), lockRaw, mono: true)],
                riskNotice: locked ? L10n.t("激活锁开启状态下重装系统将要求输入原 Apple ID 密码，二手机交易请勿直接付款。", "Erasing this Mac while Activation Lock is on requires the previous Apple ID password.") : nil
            ))
        }

        // 3.5 Apple ID 登录状态
        let signedIn = !icloudOutput.isEmpty && icloudOutput.contains("AccountID")
        out.append(MCCheckItem(
            id: "security.appleID",
            category: .security,
            title: L10n.t("Apple ID 登录状态", "Apple ID Sign-In"),
            status: signedIn ? .warning : .pass,
            summary: signedIn ? L10n.t("当前系统已登录 Apple ID（自检属正常，二手机过户前请确认退出）", "An Apple ID is currently signed in (normal for self-check; sign out before resale)") : L10n.t("未检测到已登录的 Apple ID", "No Apple ID signed in"),
            details: [.init(L10n.t("iCloud 账户", "iCloud Account"), signedIn ? L10n.t("已登录", "Signed in") : L10n.t("未登录", "Signed out"))]
        ))

        return out
    }

    // MARK: - 4. 存储与 NVMe SMART（纯 C IOKit 直读 + 卷容量）

    private struct StorageProbeOut {
        var item: MCCheckItem
        var wearPct: Int?
    }

    private static func probeStorageNative(nvmeInfo: [[String: Any]]?) -> StorageProbeOut {
        var totalBytes: Int64 = 0
        var availBytes: Int64 = 0
        let rootURL = URL(fileURLWithPath: "/")
        if let vals = try? rootURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            totalBytes = Int64(vals.volumeTotalCapacity ?? 0)
            availBytes = vals.volumeAvailableCapacityForImportantUsage ?? 0
        }

        var smart = CMNVMeSmart()
        let hasSmart = cm_read_nvme_smart(&smart) != 0

        var details: [MCDetailPair] = []
        if totalBytes > 0 {
            details.append(.init(L10n.t("系统卷总容量", "Volume Capacity"), formatBytes(Double(totalBytes))))
            details.append(.init(L10n.t("当前可用空间", "Available Space"), formatBytes(Double(availBytes))))
        }

        var status: MCStatus = .pass
        var summaryParts: [String] = []
        var wearPct: Int? = nil

        // 从 SPNVMeDataType 提取系统级 SMART 状态与 TRIM 支持（与 C 层详细日志互补）
        let spDrives = (nvmeInfo ?? []).flatMap { ($0["_items"] as? [[String: Any]]) ?? [] }
        let spFirst = spDrives.first
        let spSmartStatus = (spFirst?["smart_status"] as? String) ?? ""
        let spTrim = (spFirst?["spnvme_trim_support"] as? String) ?? ""
        if !spSmartStatus.isEmpty {
            details.append(.init(L10n.t("系统 SMART 状态", "System SMART Status"), spSmartStatus))
            if !spSmartStatus.lowercased().contains("verified") {
                status = .critical
            }
        }
        if !spTrim.isEmpty {
            details.append(.init(L10n.t("TRIM 支持", "TRIM Support"), spTrim))
        }

        if hasSmart {
            let modelStr = withUnsafeBytes(of: smart.model) { raw -> String in
                guard let p = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
                return String(cString: p)
            }
            let fwStr = withUnsafeBytes(of: smart.firmware) { raw -> String in
                guard let p = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
                return String(cString: p)
            }
            if !modelStr.isEmpty { details.append(.init(L10n.t("SSD 型号", "SSD Model"), modelStr, mono: true)) }
            if !fwStr.isEmpty { details.append(.init(L10n.t("固件版本", "Firmware"), fwStr, mono: true)) }

            let wear = Int(smart.percentage_used)
            wearPct = wear
            details.append(.init(L10n.t("已消耗寿命", "Percentage Used"), "\(wear)%"))
            details.append(.init(L10n.t("剩余备用块", "Available Spare"), "\(smart.available_spare)%"))
            details.append(.init(L10n.t("累计写入量（TBW）", "Total Data Written"), formatBytes(smart.bytes_written)))
            details.append(.init(L10n.t("累计读取量", "Total Data Read"), formatBytes(smart.bytes_read)))
            details.append(.init(L10n.t("通电总时长", "Power-On Hours"), L10n.t("\(smart.power_on_hours) 小时", "\(smart.power_on_hours) hrs")))
            details.append(.init(L10n.t("通电次数", "Power Cycles"), "\(smart.power_cycles)"))
            details.append(.init(L10n.t("异常断电次数", "Unsafe Shutdowns"), "\(smart.unsafe_shutdowns)"))
            details.append(.init(L10n.t("硬盘温度", "SSD Temperature"), "\(smart.temperature_celsius) °C"))
            details.append(.init(L10n.t("介质错误计数", "Media Errors"), "\(smart.media_errors)"))

            if smart.critical_warning != 0 || smart.media_errors > 0 || wear >= 90 || smart.available_spare < smart.available_spare_threshold {
                status = .critical
            } else if status != .critical && wear >= 50 {
                status = .warning
            }
            summaryParts.append(L10n.t("已写入 \(formatBytes(smart.bytes_written))", "Written \(formatBytes(smart.bytes_written))"))
            summaryParts.append(L10n.t("寿命消耗 \(wear)%", "\(wear)% wear"))
            summaryParts.append(L10n.t("通电 \(smart.power_on_hours) 小时", "\(smart.power_on_hours) hrs"))
        } else if let first = spFirst {
            if let name = first["_name"] as? String { details.append(.init(L10n.t("设备名", "Drive"), name)) }
            if !spSmartStatus.isEmpty {
                summaryParts.append("SMART: \(spSmartStatus)")
            }
        }

        if summaryParts.isEmpty {
            summaryParts.append(totalBytes > 0
                ? L10n.t("总容量 \(formatBytes(Double(totalBytes)))，可用 \(formatBytes(Double(availBytes)))",
                         "\(formatBytes(Double(totalBytes))) total, \(formatBytes(Double(availBytes))) free")
                : L10n.t("未能读取磁盘 SMART 详细信息", "Unable to read detailed SMART metrics"))
        }

        let risk: String? = (status == .critical)
            ? L10n.t("NVMe SSD 报告严重告警、介质错误或寿命即将耗尽，请立即备份数据并谨慎交易。",
                     "NVMe SSD reports critical warnings, media errors, or near-exhausted lifespan.")
            : nil

        return StorageProbeOut(
            item: MCCheckItem(
                id: "storage.nvme",
                category: .storage,
                title: L10n.t("内建 SSD 与 SMART 寿命", "Internal SSD & SMART"),
                status: status,
                summary: summaryParts.joined(separator: " · "),
                details: details,
                riskNotice: risk
            ),
            wearPct: wearPct
        )
    }

    // MARK: - 5. 网络（Wi-Fi 原生 CoreWLAN + 蓝牙 SPBluetoothDataType）

    private static func probeWiFiNative() -> MCCheckItem {
        guard let iface = CWWiFiClient.shared().interface() else {
            return MCCheckItem(
                id: "network.wifi",
                category: .network,
                title: "Wi-Fi",
                status: .unsupported,
                summary: L10n.t("未检测到无线网卡", "No Wi-Fi hardware detected")
            )
        }
        let on = iface.powerOn()
        var details: [MCDetailPair] = [
            .init(L10n.t("开关状态", "Power"), on ? L10n.t("已开启", "On") : L10n.t("已关闭", "Off")),
        ]
        if let mac = iface.hardwareAddress(), !mac.isEmpty {
            details.append(.init(L10n.t("网卡 MAC", "MAC Address"), mac, mono: true))
        }
        if let ssid = iface.ssid(), !ssid.isEmpty {
            let rssi = iface.rssiValue()
            let tx = iface.transmitRate()
            details.append(.init(L10n.t("当前网络", "Network"), ssid))
            details.append(.init(L10n.t("信号强度（RSSI）", "Signal (RSSI)"), "\(rssi) dBm"))
            details.append(.init(L10n.t("协商速率", "Link Rate"), String(format: "%.0f Mbps", tx)))
            details.append(.init(L10n.t("协议标准", "PHY Mode"), phyLabel(iface.activePHYMode())))
            return MCCheckItem(
                id: "network.wifi",
                category: .network,
                title: "Wi-Fi",
                status: .pass,
                summary: L10n.t("已连接「\(ssid)」· \(rssi) dBm · \(Int(tx)) Mbps", "Connected to \"\(ssid)\" · \(rssi) dBm · \(Int(tx)) Mbps"),
                details: details
            )
        }
        return MCCheckItem(
            id: "network.wifi",
            category: .network,
            title: "Wi-Fi",
            status: on ? .pass : .warning,
            summary: on ? L10n.t("Wi-Fi 网卡正常（当前未连接网络）", "Wi-Fi card active (not associated)") : L10n.t("Wi-Fi 当前已关闭", "Wi-Fi is turned off"),
            details: details
        )
    }

    private static func phyLabel(_ mode: CWPHYMode) -> String {
        // 按标准 CoreWLAN rawValue 匹配，兼顾旧版 macOS 15 SDK（无 .mode11be 符号）与新版 macOS SDK（0 警告）
        switch mode.rawValue {
        case 0: return L10n.t("未连接", "None")
        case 1: return "802.11a"
        case 2: return "802.11b"
        case 3: return "802.11g"
        case 4: return "Wi-Fi 4 (802.11n)"
        case 5: return "Wi-Fi 5 (802.11ac)"
        case 6: return "Wi-Fi 6/6E (802.11ax)"
        case 7: return "Wi-Fi 7 (802.11be)"
        default: return "Wi-Fi"
        }
    }

    private static func buildBluetoothItem(spJSON: [String: Any]) -> MCCheckItem {
        guard let list = spJSON["SPBluetoothDataType"] as? [[String: Any]],
              let first = list.first,
              let ctrl = first["controller_properties"] as? [String: Any] else {
            return MCCheckItem(
                id: "network.bluetooth",
                category: .network,
                title: L10n.t("蓝牙控制器", "Bluetooth Controller"),
                status: .warning,
                summary: L10n.t("未能读取蓝牙控制器信息", "Unable to read Bluetooth controller")
            )
        }
        let state = (ctrl["controller_state"] as? String) ?? ""
        let chipset = (ctrl["controller_chipset"] as? String) ?? ""
        let addr = (ctrl["controller_address"] as? String) ?? ""
        let isOn = state.lowercased().contains("on")
        let connected = (first["device_connected"] as? [[String: Any]])?.count ?? 0

        var details: [MCDetailPair] = [
            .init(L10n.t("控制器状态", "State"), isOn ? L10n.t("已开启", "On") : L10n.t("已关闭", "Off")),
        ]
        if !chipset.isEmpty { details.append(.init(L10n.t("芯片方案", "Chipset"), chipset)) }
        if !addr.isEmpty { details.append(.init(L10n.t("硬件地址", "Address"), addr, mono: true)) }
        details.append(.init(L10n.t("已连接设备", "Connected Devices"), "\(connected)"))

        return MCCheckItem(
            id: "network.bluetooth",
            category: .network,
            title: L10n.t("蓝牙控制器", "Bluetooth Controller"),
            status: isOn ? .pass : .warning,
            summary: isOn
                ? L10n.t("蓝牙工作正常（已连接 \(connected) 台设备）", "Bluetooth active (\(connected) connected)")
                : L10n.t("蓝牙处于关闭状态，无法验证射频", "Bluetooth is off; radio unverified"),
            details: details
        )
    }

    // MARK: - 6. USB & 雷雳接口

    private static func buildPortsItem(spJSON: [String: Any]) -> MCCheckItem {
        let usbBuses = (spJSON["SPUSBDataType"] as? [[String: Any]]) ?? []
        let tbBuses = (spJSON["SPThunderboltDataType"] as? [[String: Any]]) ?? []

        var usbDeviceNames: [String] = []
        func collectUSB(_ nodes: [[String: Any]]) {
            for node in nodes {
                if let name = node["_name"] as? String, !name.isEmpty, node["vendor_id"] != nil {
                    usbDeviceNames.append(name)
                }
                if let children = node["_items"] as? [[String: Any]] {
                    collectUSB(children)
                }
            }
        }
        collectUSB(usbBuses)

        let tbCount = tbBuses.count
        var details: [MCDetailPair] = [
            .init(L10n.t("USB 总线数", "USB Buses"), "\(usbBuses.count)"),
            .init(L10n.t("雷雳总线数", "Thunderbolt Buses"), "\(tbCount)"),
            .init(L10n.t("已枚举 USB 外设", "Enumerated USB Devices"), "\(usbDeviceNames.count)"),
        ]
        if !usbDeviceNames.isEmpty {
            details.append(.init(L10n.t("外设列表", "Device List"), usbDeviceNames.prefix(8).joined(separator: "、")))
        }

        return MCCheckItem(
            id: "ports.bus",
            category: .ports,
            title: L10n.t("USB 与雷雳控制器", "USB & Thunderbolt Buses"),
            status: (usbBuses.isEmpty && tbCount == 0) ? .warning : .pass,
            summary: L10n.t("\(tbCount) 条雷雳总线 · \(usbBuses.count) 条 USB 总线 · \(usbDeviceNames.count) 个在线设备",
                            "\(tbCount) TB buses · \(usbBuses.count) USB buses · \(usbDeviceNames.count) devices"),
            details: details
        )
    }

    // MARK: - 原生 IOKit / sysctl 工具函数

    private static func sysctlString(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sysctlInt(_ key: String) -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &v, &size, nil, 0) == 0 else { return 0 }
        return Int(v)
    }

    private static func readPlatformExpertInfo() -> (serial: String, uuid: String) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return ("", "") }
        defer { IOObjectRelease(service) }
        let sn = (IORegistryEntryCreateCFProperty(service, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? ""
        let uuid = (IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? ""
        return (sn.trimmingCharacters(in: .whitespacesAndNewlines), uuid.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 直接从 IORegistry 读取 product-name（等价 `ioreg -ar -k product-name`，但无需派生子进程）
    private static func readIORegistryProductName() -> String? {
        var it: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(it) }
        var entry = IOIteratorNext(it)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(it)
            }
            if let prop = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                if let data = prop as? Data,
                   let str = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet.controlCharacters.union(.whitespacesAndNewlines)),
                   !str.isEmpty {
                    return str
                }
                if let str = prop as? String, !str.isEmpty {
                    return str.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private static let legacyIntelModels: [String: String] = [
        "MacBookPro16,1": "MacBook Pro (16-inch, 2019)",
        "MacBookPro16,2": "MacBook Pro (13-inch, 2020)",
        "MacBookPro16,3": "MacBook Pro (13-inch, 2020)",
        "MacBookPro16,4": "MacBook Pro (16-inch, 2019)",
        "MacBookPro15,1": "MacBook Pro (15-inch, 2018)",
        "MacBookPro15,2": "MacBook Pro (13-inch, 2019)",
        "MacBookAir9,1": "MacBook Air (2020)",
        "MacBookAir8,2": "MacBook Air (2019)",
        "Macmini8,1": "Mac mini (2018)",
        "iMac20,1": "iMac (27-inch, 2020)",
        "iMac20,2": "iMac (27-inch, 2020)",
        "iMac19,1": "iMac (27-inch, 2019)",
        "iMacPro1,1": "iMac Pro (2017)",
    ]

    private static func friendlyModelFallback(modelID: String, chip: String) -> String {
        if let mapped = legacyIntelModels[modelID] { return mapped }
        if modelID.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if modelID.hasPrefix("MacBookAir") { return "MacBook Air" }
        if modelID.hasPrefix("Macmini") { return "Mac mini" }
        if modelID.hasPrefix("iMac") { return "iMac" }
        if !modelID.isEmpty { return modelID }
        return chip.isEmpty ? "Mac" : "Mac (\(chip))"
    }

    static func localizeMarketingName(_ raw: String) -> String {
        guard !L10n.isEnglish else { return raw }
        return raw
            .replacingOccurrences(of: "-inch", with: " 英寸")
            .replacingOccurrences(of: "‑inch", with: " 英寸")
            .replacingOccurrences(of: " (", with: "（")
            .replacingOccurrences(of: "(", with: "（")
            .replacingOccurrences(of: ")", with: "）")
            .replacingOccurrences(of: ", ", with: "，")
    }

    static func inferModelYear(productName: String, serialInfo: MCSerialInfo) -> String {
        if let range = productName.range(of: #"\b20[12]\d\b"#, options: .regularExpression) {
            return String(productName[range])
        }
        if let y = serialInfo.estimatedYear {
            return "\(y)"
        }
        return ""
    }

    static func formatBytes(_ bytes: Double) -> String {
        if bytes <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = bytes
        var idx = 0
        while value >= 1000 && idx < units.count - 1 {
            value /= 1000
            idx += 1
        }
        return idx >= 3 ? String(format: "%.2f %@", value, units[idx]) : String(format: "%.0f %@", value, units[idx])
    }

    private static func elapsedMs(since t0: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
    }
}
