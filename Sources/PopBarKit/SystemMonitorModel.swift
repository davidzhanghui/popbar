import CMetrics
import Foundation
import Combine
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 系统监控 —— 采集与健康评分(移植自 mole-demo 的状态页)。
/// 采样只在 Deck 的监控页可见时运行(start/stop 由 MonitorModule 控制),空闲时零开销。

enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.zeroPadsFractionDigits = true
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 KB" }
        return formatter.string(fromByteCount: bytes)
    }
}

// CMetrics 的 C 声明经 Native/CMetrics.h 桥接头文件导入

struct ProcessRow: Identifiable, Equatable {
    var id: Int { pid }
    let pid: Int
    let name: String
    let memoryBytes: UInt64
    let cpuPercent: Double
    let powerScore: Double
}

struct FanReading: Equatable {
    var rpm: Double
    var min: Double
    var max: Double
}

struct StatusSnapshot: Equatable {
    var cpuPercent: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var loadAvg: [Double] = [0, 0, 0]
    var perCore: [Double] = []
    var cpuBrand: String = ""
    var pCores: Int = 0
    var eCores: Int = 0
    var cpuWatts: Double = 0
    /// 有真实功耗来源才显示瓦数,否则隐藏而不是显示 0W
    var hasCPUPower = false
    var hasGPUPower = false
    var hasGPUUtil = false
    var gpuName: String = ""
    var gpuMem: UInt64 = 0
    var gpuPercent: Double = 0
    var gpuWatts: Double = 0
    var aneWatts: Double = 0
    var dramWatts: Double = 0
    var chipWatts: Double = 0
    var cpuTemp: Double = 0
    var gpuTemp: Double = 0
    var cpuTempPeak: Double = 0
    var gpuTempPeak: Double = 0
    var memPercent: Double = 0
    var memUsed: UInt64 = 0
    var memPhys: UInt64 = 0
    var swapUsed: UInt64 = 0
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var memCached: UInt64 = 0
    var memFree: UInt64 = 0
    var pressure: Int = 0
    var fans: [FanReading] = []
    /// SMC PSTR 整机功耗,0 表示没有
    var systemWatts: Double = 0
    var dcInWatts: Double = 0
    var batteryLevel: Double = 0
    var batteryHealth: Double = 100
    var batteryCycles: Int = 0
    var hasBattery: Bool = false
    var isCharging: Bool = false
    var isAC: Bool = false
    var batteryTemp: Double = 0
    var batteryVoltage: Double = 0
    /// 正:充电;负:放电
    var batteryWatts: Double = 0
    var timeToEmpty: Int = -1
    var timeToFull: Int = -1
    var adapterWatts: Int = 0
    var capacityNow: Int = 0
    var capacityFull: Int = 0
    var capacityDesign: Int = 0
    var diskTotal: UInt64 = 0
    var diskAvail: UInt64 = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var netDown: Double = 0
    var netUp: Double = 0
    var netIface: String = ""
    var isWifi: Bool = true
    var netRxTotal: UInt64 = 0
    var netTxTotal: UInt64 = 0
    var groups: [ProcessGroup] = []
    var topPowerName: String = "—"
    var health = HealthReport(score: 100, band: L10n.t("很好", "Excellent"), factors: [])
    var thermalState: Int = 0
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var memHistory: [Double] = []
    var netDownHistory: [Double] = []
    var netUpHistory: [Double] = []
    var primed: Bool = false
}

/// 采样在专用串行队列上：C 采集、进程 CPU 差分、可执行路径查询与分组都不占主线程。
/// CMSnapshot 含 1024 条进程（>100KB），在堆上复用缓冲并通过 pointer(to:) 读取，
/// 避免 GCD 后台线程（默认 512KB 栈）栈溢出。
private final class MonitorSampler: @unchecked Sendable {
    struct Result {
        var cpu: CMCPUSample
        var memory: CMMemorySample
        var chip: CMChipSample
        var temp: CMTempSample
        var sensors: CMSensorSample
        var battery: CMBatterySample
        var disk: CMDiskSample
        var net: CMNetCounters
        var procsDiskioTotal: UInt64
        var driveFailing: Int32
        var uptimeSec: Double
        var elapsedSec: Double
        var info: CMSystemInfo?          // 仅第一次非 nil
        var groups: [ProcessGroup]?      // nil = 本轮没采进程
        var slow: Bool
    }

    private let queue = DispatchQueue(label: "popbar.monitor.sampler", qos: .utility)
    private let rawBuf: UnsafeMutablePointer<CMSnapshot>
    private var ptr: OpaquePointer?
    private var invalidated = false
    private var infoSent = false
    private var prevCPU: [Int: UInt64] = [:]
    private var prevProcAt: Date?
    private var pathCache: [Int: String?] = [:]

    init() {
        rawBuf = .allocate(capacity: 1)
        UnsafeMutableRawPointer(rawBuf).initializeMemory(
            as: UInt8.self, repeating: 0, count: MemoryLayout<CMSnapshot>.size
        )
    }

    deinit {
        if let p = ptr { cm_sampler_destroy(p) }
        rawBuf.deallocate()
    }

    func poll(procs: Bool, slow: Bool) async -> Result? {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.pollOnQueue(procs: procs, slow: slow)) }
        }
    }

    func invalidate() {
        queue.async {
            self.invalidated = true
            if let p = self.ptr { cm_sampler_destroy(p) }
            self.ptr = nil
        }
    }

    private func pollOnQueue(procs: Bool, slow: Bool) -> Result? {
        guard !invalidated else { return nil }
        if ptr == nil { ptr = cm_sampler_create() }
        guard let ptr else { return nil }

        var info: CMSystemInfo?
        if !infoSent {
            infoSent = true
            var sysInfo = CMSystemInfo()
            cm_system_info(ptr, &sysInfo)
            info = sysInfo
        }

        var flags: Int32 = 0
        if procs { flags |= CM_POLL_PROCS }
        if slow { flags |= CM_POLL_SLOW }

        guard cm_sampler_poll_ex(ptr, rawBuf, flags) == 0 else { return nil }

        var groups: [ProcessGroup]?
        if procs {
            let now = Date()
            var rows: [ProcessRow] = []
            var newCPU: [Int: UInt64] = [:]
            let procElapsed = prevProcAt.map { now.timeIntervalSince($0) } ?? 1.0
            let procsPtr = UnsafePointer(rawBuf.pointer(to: \.procs)!)
            for p in copyProcs(procsPtr) {
                newCPU[p.pid] = p.cpu_ns
                let dns: Double
                if let prev = prevCPU[p.pid], procElapsed > 0.05, p.cpu_ns >= prev {
                    dns = Double(p.cpu_ns - prev)
                } else {
                    dns = 0
                }
                let cpuPct = min(100, 100.0 * dns / (procElapsed * 1e9))
                rows.append(ProcessRow(
                    pid: p.pid,
                    name: p.name,
                    memoryBytes: p.phys_footprint,
                    cpuPercent: cpuPct,
                    powerScore: cpuPct
                ))
            }
            prevCPU = newCPU
            prevProcAt = now
            var paths: [Int: String] = [:]
            var newCache: [Int: String?] = [:]
            for r in rows {
                let p = pathCache[r.pid] ?? LibProc.path(r.pid)
                newCache[r.pid] = p
                if let p { paths[r.pid] = p }
            }
            pathCache = newCache
            groups = ProcessGrouping.group(rows, paths: paths)
        }

        return Result(
            cpu: rawBuf.pointer(to: \.cpu)!.pointee,
            memory: rawBuf.pointer(to: \.memory)!.pointee,
            chip: rawBuf.pointer(to: \.chip)!.pointee,
            temp: rawBuf.pointer(to: \.temp)!.pointee,
            sensors: rawBuf.pointer(to: \.sensors)!.pointee,
            battery: rawBuf.pointer(to: \.battery)!.pointee,
            disk: rawBuf.pointer(to: \.disk)!.pointee,
            net: rawBuf.pointer(to: \.net)!.pointee,
            procsDiskioTotal: rawBuf.pointer(to: \.procs.diskio_total)!.pointee,
            driveFailing: rawBuf.pointer(to: \.drive_failing)!.pointee,
            uptimeSec: rawBuf.pointer(to: \.uptime_sec)!.pointee,
            elapsedSec: rawBuf.pointer(to: \.elapsed_sec)!.pointee,
            info: info,
            groups: groups,
            slow: slow
        )
    }
}

@MainActor
final class SystemMonitorModel: ObservableObject {
    @Published var snap = StatusSnapshot()
    @Published var running = false
    /// 固定在表头的进程(仅内存,面板关闭后保留到应用退出)
    @Published var pinned: Set<String> = []
    /// 仅截图工具(shot)使用:只展示满足条件的进程组,避免把个人机器上的应用名截进文档图
    var groupFilter: ((ProcessGroup) -> Bool)?

    func togglePin(_ key: String) {
        if pinned.contains(key) { pinned.remove(key) } else { pinned.insert(key) }
    }

    // MARK: 进程详情(点击进程行打开)

    @Published var detailKey: String?
    @Published var detail: ProcessDetail?
    @Published var detailLoading = false
    /// 终止 / 强制退出的结果提示(详情窗底部)
    @Published var detailMessage: String?
    @Published var detailFailed = false
    private var detailSnapshot: ProcessGroup?
    private var inspectTask: Task<Void, Never>?

    /// 详情窗里显示的组:优先用最新采样,进程已退出则用打开时的快照
    var detailGroup: ProcessGroup? {
        guard let k = detailKey else { return nil }
        return snap.groups.first { $0.id == k } ?? detailSnapshot
    }
    var detailAlive: Bool { detailKey.map { k in snap.groups.contains { $0.id == k } } ?? false }

    func openDetail(_ g: ProcessGroup) {
        detailKey = g.id
        detailSnapshot = g
        detailMessage = nil
        loadDetail()
    }

    func loadDetail() {
        guard let g = detailGroup else { return }
        detail = nil
        detailLoading = true
        inspectTask?.cancel()
        let key = g.id
        inspectTask = Task { [weak self] in
            let d = await Task.detached(priority: .userInitiated) { ProcessInspector.inspect(g) }.value
            guard let self, !Task.isCancelled, self.detailKey == key else { return }
            self.detail = d
            self.detailLoading = false
        }
    }

    func closeDetail() {
        inspectTask?.cancel()
        detailKey = nil
        detail = nil
        detailSnapshot = nil
        detailLoading = false
        detailMessage = nil
    }

    func terminateDetail(force: Bool) {
        guard let g = detailGroup else { return }
        let r = SystemMonitorActions.terminate(g, force: force, expectedStart: detail?.startKeys)
        detailFailed = !(r == .done || r == .cancelled)
        switch r {
        case .cancelled: detailMessage = nil
        case .done: detailMessage = force ? L10n.t("已强制退出。", "Force quit.") : L10n.t("已发送终止信号。", "Terminate signal sent.")
        default: detailMessage = r.message
        }
    }

    private var sampler: MonitorSampler?
    private var task: Task<Void, Never>?
    private var lastPoll: Date?
    private var lastProc: Date?
    private var lastSlow: Date?
    private var fallbackDiskDelta: UInt64 = 0
    private var prevDiskIO: UInt64 = 0
    private var haveDiskIO = false
    private var prevDiskRead: UInt64 = 0
    private var prevDiskWrite: UInt64 = 0
    private var haveDiskBytes = false
    private var prevRx: UInt64 = 0
    private var prevTx: UInt64 = 0
    private var haveNet = false
    private var cpuTempHist: [(Date, Double)] = []
    private var gpuTempHist: [(Date, Double)] = []
    private var display = StatusSnapshot()

    func start() {
        guard !running else { return }
        running = true
        sampler = MonitorSampler()
        task = Task { [weak self] in
            await self?.tick()
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self.tick()
            }
        }
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
        sampler?.invalidate()
        sampler = nil
        lastPoll = nil
        lastProc = nil
        lastSlow = nil
    }

    private func tick() async {
        guard let sampler else { return }
        let now = Date()
        if let last = lastPoll, now.timeIntervalSince(last) < 0.5 {
            return
        }
        lastPoll = now

        let wantProcs = lastProc == nil || now.timeIntervalSince(lastProc!) >= 1.0
        let wantSlow = lastSlow == nil || now.timeIntervalSince(lastSlow!) >= 2.0

        guard let r = await sampler.poll(procs: wantProcs, slow: wantSlow),
              running, self.sampler === sampler else { return }

        if wantProcs { lastProc = now }
        if wantSlow { lastSlow = now }

        var next = display
        if let info = r.info {
            next.cpuBrand = cChars(info.cpu_brand).trimmingCharacters(in: .whitespaces)
            next.pCores = Int(info.pcores)
            next.eCores = Int(info.ecores)
        }
        let cpu = blend(display.cpuPercent, r.cpu.package_percent)
        next.cpuPercent = cpu
        next.cpuUser = blend(display.cpuUser, r.cpu.user_percent)
        next.cpuSystem = blend(display.cpuSystem, r.cpu.system_percent)
        next.loadAvg = [r.cpu.load_avg.0, r.cpu.load_avg.1, r.cpu.load_avg.2]
        next.perCore = copyCores(r.cpu)
        next.hasCPUPower = r.chip.has_cpu_power != 0
        next.hasGPUPower = r.chip.has_gpu_power != 0
        next.hasGPUUtil = r.chip.has_gpu_util != 0
        next.gpuName = cChars(r.chip.gpu_name)
        next.gpuMem = r.chip.gpu_mem_bytes
        next.cpuWatts = blend(display.cpuWatts, r.chip.cpu_watts)
        next.gpuPercent = blend(display.gpuPercent, r.chip.gpu_percent)
        next.gpuWatts = blend(display.gpuWatts, r.chip.gpu_watts)
        next.aneWatts = r.chip.ane_watts
        next.dramWatts = r.chip.dram_watts
        next.chipWatts = next.cpuWatts + next.gpuWatts + next.aneWatts + next.dramWatts

        if r.slow {
            next.fans = copyFans(r.sensors)
            next.systemWatts = r.sensors.system_watts > 0 ? blend(display.systemWatts, r.sensors.system_watts) : 0
            next.dcInWatts = r.sensors.dcin_watts

            if r.temp.have_cpu != 0 {
                next.cpuTemp = blend(display.cpuTemp == 0 ? r.temp.cpu_temp : display.cpuTemp, r.temp.cpu_temp)
                cpuTempHist.append((now, next.cpuTemp))
            }
            if r.temp.have_gpu != 0 {
                next.gpuTemp = blend(display.gpuTemp == 0 ? r.temp.gpu_temp : display.gpuTemp, r.temp.gpu_temp)
                gpuTempHist.append((now, next.gpuTemp))
            }
        }
        let cutoff = now.addingTimeInterval(-300)
        cpuTempHist.removeAll { $0.0 < cutoff }
        gpuTempHist.removeAll { $0.0 < cutoff }
        next.cpuTempPeak = cpuTempHist.map(\.1).max() ?? next.cpuTemp
        next.gpuTempPeak = gpuTempHist.map(\.1).max() ?? next.gpuTemp

        next.memPercent = blend(display.memPercent, r.memory.used_percent)
        next.memUsed = r.memory.used_bytes
        next.memPhys = r.memory.phys_bytes
        next.swapUsed = r.memory.swap_used
        next.memApp = r.memory.app_bytes
        next.memWired = r.memory.wired_bytes
        next.memCompressed = r.memory.compressed_bytes
        next.memCached = r.memory.cached_bytes
        next.memFree = r.memory.free_bytes
        next.pressure = Int(r.memory.pressure_level)

        if r.slow {
            next.hasBattery = r.battery.has_battery != 0
            next.batteryLevel = r.battery.level_percent
            next.batteryHealth = r.battery.health_percent
            next.batteryCycles = Int(r.battery.cycle_count)
            next.isCharging = r.battery.is_charging != 0
            next.isAC = r.battery.is_ac != 0
            next.batteryTemp = r.battery.temperature
            next.batteryVoltage = r.battery.voltage
            next.batteryWatts = blend(display.batteryWatts, r.battery.watts)
            next.timeToEmpty = Int(r.battery.time_to_empty)
            next.timeToFull = Int(r.battery.time_to_full)
            next.adapterWatts = Int(r.battery.adapter_watts)
            next.capacityNow = Int(r.battery.cur_capacity_mah)
            next.capacityFull = Int(r.battery.max_capacity_mah)
            next.capacityDesign = Int(r.battery.design_capacity_mah)
        }

        next.diskTotal = r.disk.total_bytes
        next.diskAvail = r.disk.available_important
        next.netIface = cChars(r.net.iface)
        next.isWifi = r.net.is_wifi != 0

        let elapsed = r.elapsedSec > 0.05 ? r.elapsedSec : 0.5
        if haveNet, elapsed >= 0.5 {
            let dr = Double(r.net.rx_bytes &- prevRx) / elapsed
            let dt = Double(r.net.tx_bytes &- prevTx) / elapsed
            next.netDown = max(0, dr)
            next.netUp = max(0, dt)
        }
        prevRx = r.net.rx_bytes
        prevTx = r.net.tx_bytes
        haveNet = true
        next.netRxTotal = r.net.rx_bytes
        next.netTxTotal = r.net.tx_bytes

        // 磁盘读写:优先用 IOBlockStorageDriver 的累计字节(不受进程退出影响),没有再退回进程 rusage 之和
        var diskDelta: UInt64 = 0
        let dRead = r.disk.read_bytes, dWrite = r.disk.write_bytes
        if dRead > 0 || dWrite > 0 {
            if haveDiskBytes, dRead >= prevDiskRead, dWrite >= prevDiskWrite, elapsed >= 0.2 {
                let dr = dRead - prevDiskRead, dw = dWrite - prevDiskWrite
                diskDelta = dr + dw
                next.diskRead = blend(display.diskRead, Double(dr) / elapsed)
                next.diskWrite = blend(display.diskWrite, Double(dw) / elapsed)
            }
            prevDiskRead = dRead
            prevDiskWrite = dWrite
            haveDiskBytes = true
        } else if wantProcs {
            if haveDiskIO, r.procsDiskioTotal >= prevDiskIO {
                diskDelta = r.procsDiskioTotal - prevDiskIO
            }
            prevDiskIO = r.procsDiskioTotal
            haveDiskIO = true
            fallbackDiskDelta = diskDelta
        } else {
            diskDelta = fallbackDiskDelta
        }

        if let groups = r.groups {
            next.groups = groups.filter { groupFilter?($0) ?? true }
            next.topPowerName = next.groups.first.map(\.name) ?? "—"
        }

        append(&next.cpuHistory, cpu)
        append(&next.gpuHistory, next.gpuPercent)
        append(&next.memHistory, next.memPercent)
        append(&next.netDownHistory, next.netDown)
        append(&next.netUpHistory, next.netUp)

        let diskUsedPct: Double
        if next.diskTotal > 0, next.diskTotal > next.diskAvail {
            diskUsedPct = 100.0 * Double(next.diskTotal - next.diskAvail) / Double(next.diskTotal)
        } else {
            diskUsedPct = 0
        }
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        next.thermalState = thermal
        next.health = HealthScore.evaluate(
            cpuPercent: cpu,
            memoryPressure: next.pressure,
            diskUsedPercent: diskUsedPct,
            hasBattery: next.hasBattery,
            batteryHealth: next.batteryHealth,
            cycleCount: next.batteryCycles,
            thermalState: thermal,
            diskIODelta: diskDelta,
            uptimeSec: r.uptimeSec,
            driveFailing: r.driveFailing != 0
        )
        next.primed = true

        display = next
        snap = next
    }

    private func blend(_ old: Double, _ new: Double) -> Double {
        if !display.primed { return new }
        return 0.5 * old + 0.5 * new
    }

    private func append(_ hist: inout [Double], _ value: Double) {
        hist.append(value)
        if hist.count > 120 { hist.removeFirst(hist.count - 120) }
    }
}

private struct CProc {
    var pid: Int
    var name: String
    var phys_footprint: UInt64
    var cpu_ns: UInt64
    var diskio: UInt64
}

private func copyFans(_ s: CMSensorSample) -> [FanReading] {
    let n = max(0, min(Int(s.fan_count), Int(CM_MAX_FANS)))
    let rpm = withUnsafeBytes(of: s.fan_rpm) { Array($0.bindMemory(to: Double.self)) }
    let lo = withUnsafeBytes(of: s.fan_min) { Array($0.bindMemory(to: Double.self)) }
    let hi = withUnsafeBytes(of: s.fan_max) { Array($0.bindMemory(to: Double.self)) }
    return (0..<n).map { FanReading(rpm: rpm[$0], min: lo[$0], max: hi[$0]) }
}

private func copyCores(_ cpu: CMCPUSample) -> [Double] {
    let count = max(0, min(Int(cpu.core_count), Int(CM_MAX_CORES)))
    return withUnsafeBytes(of: cpu.per_core) { raw in
        let ptr = raw.bindMemory(to: Double.self)
        return (0..<count).map { min(100, max(0, ptr[$0])) }
    }
}

private func cChars<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { raw in
        guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
        return String(cString: base)
    }
}

private func copyProcs(_ samplePtr: UnsafePointer<CMProcSample>) -> [CProc] {
    let count = max(0, min(Int(samplePtr.pointer(to: \.count)!.pointee), Int(CM_MAX_PROCS)))
    let rowsPtr = UnsafeRawPointer(samplePtr.pointer(to: \.rows)!)
        .assumingMemoryBound(to: CMProcRow.self)
    var out: [CProc] = []
    out.reserveCapacity(count)
    for i in 0..<count {
        let rowPtr = rowsPtr.advanced(by: i)
        let namePtr = UnsafeRawPointer(rowPtr.pointer(to: \.name)!)
            .assumingMemoryBound(to: CChar.self)
        out.append(CProc(
            pid: Int(rowPtr.pointer(to: \.pid)!.pointee),
            name: String(cString: namePtr),
            phys_footprint: rowPtr.pointer(to: \.phys_footprint)!.pointee,
            cpu_ns: rowPtr.pointer(to: \.cpu_ns)!.pointee,
            diskio: rowPtr.pointer(to: \.diskio)!.pointee
        ))
    }
    return out
}

// MARK: - Health score

struct HealthFactor: Identifiable, Equatable {
    let id: String
    let title: String
    let points: Int

    var sentence: String { L10n.t("\(title)，影响 \(points) 分", "\(title) (−\(points))") }
}

struct HealthReport: Equatable {
    var score: Int
    var band: String
    var factors: [HealthFactor]

    var subtitle: String {
        if let first = factors.first {
            return first.title
        }
        return L10n.t("当前指标正常", "All metrics look normal")
    }

    var symbolName: String {
        if score > 84 { return "sun.max.fill" }
        if score > 64 { return "sun.max.fill" }
        if score > 44 { return "cloud.sun.fill" }
        return "cloud.fill"
    }
}

enum HealthScore {
    static func evaluate(
        cpuPercent: Double,
        memoryPressure: Int,
        diskUsedPercent: Double,
        hasBattery: Bool,
        batteryHealth: Double,
        cycleCount: Int,
        thermalState: Int,
        diskIODelta: UInt64,
        uptimeSec: Double,
        driveFailing: Bool
    ) -> HealthReport {
        var score = 100
        var factors: [HealthFactor] = []

        if cpuPercent > 85 {
            factors.append(.init(id: "cpu", title: L10n.t("CPU 负载偏高", "High CPU load"), points: 20))
            score = 80
        } else if cpuPercent > 50 {
            factors.append(.init(id: "cpu", title: L10n.t("CPU 负载偏高", "High CPU load"), points: 10))
            score = 90
        }

        if memoryPressure != 0 {
            if memoryPressure == 1 {
                factors.append(.init(id: "memory", title: L10n.t("内存压力偏高", "High memory pressure"), points: 10))
                score -= 10
            } else {
                factors.append(.init(id: "memory", title: L10n.t("内存压力偏高", "High memory pressure"), points: 20))
                score -= 20
            }
        }

        if diskUsedPercent > 93 {
            factors.append(.init(id: "disk", title: L10n.t("磁盘空间不足", "Low disk space"), points: 20))
            score -= 20
        } else if diskUsedPercent > 80 {
            factors.append(.init(id: "disk", title: L10n.t("磁盘空间不足", "Low disk space"), points: 10))
            score -= 10
        }

        if hasBattery && cycleCount >= 801 {
            factors.append(.init(id: "batteryCycles", title: L10n.t("电池老化", "Battery aging"), points: 10))
            score -= 10
        }

        if hasBattery {
            if batteryHealth <= 59 {
                factors.append(.init(id: "batteryHealth", title: L10n.t("电池健康度偏低", "Low battery health"), points: 20))
                score -= 20
            } else if batteryHealth < 80 {
                factors.append(.init(id: "batteryHealth", title: L10n.t("电池健康度偏低", "Low battery health"), points: 10))
                score -= 10
            }
        }

        if thermalState == 2 {
            factors.append(.init(id: "thermal", title: L10n.t("温度偏高", "Running hot"), points: 5))
            score -= 5
        } else if thermalState == 3 {
            factors.append(.init(id: "thermal", title: L10n.t("温度偏高", "Running hot"), points: 15))
            score -= 15
        }

        if diskIODelta > 150 * 1024 * 1024 {
            factors.append(.init(id: "diskIO", title: L10n.t("磁盘读写繁忙", "Heavy disk I/O"), points: 5))
            score -= 5
        }

        if uptimeSec > 14 * 86400 {
            factors.append(.init(id: "uptime", title: L10n.t("很久没重启了", "Long uptime, consider a restart"), points: 6))
            score -= 6
        } else if uptimeSec > 7 * 86400 {
            factors.append(.init(id: "uptime", title: L10n.t("很久没重启了", "Long uptime, consider a restart"), points: 3))
            score -= 3
        }

        if driveFailing {
            let pts: Int
            if score - 44 > 30 {
                pts = score - 44
            } else {
                pts = 30
            }
            factors.append(.init(id: "driveFailing", title: L10n.t("硬盘存在故障风险", "Drive failure risk"), points: pts))
            score -= pts
        }

        score = max(0, min(100, score))
        let band: String
        if score > 84 {
            band = L10n.t("很好", "Excellent")
        } else if score > 64 {
            band = L10n.t("良好", "Good")
        } else if score > 44 {
            band = L10n.t("一般", "Fair")
        } else {
            band = L10n.t("需要留意", "Needs attention")
        }
        return HealthReport(score: score, band: band, factors: factors)
    }
}

enum LoadLabel {
    /// 按 CPU 占用率分档。原先按芯片瓦数分档,Apple Silicon 日常远低于 20W、Intel 拿不到功耗,
    /// 结果几乎永远显示「低负载」;占用率在两种架构上都可靠
    static func from(percent: Double) -> String {
        if percent < 25 { return L10n.t("低负载", "Light") }
        if percent < 60 { return L10n.t("正常", "Normal") }
        if percent < 85 { return L10n.t("繁忙", "Busy") }
        return L10n.t("高负载", "Heavy")
    }
}

enum PressureLabel {
    static func from(_ level: Int) -> String {
        switch level {
        case 0: return L10n.t("压力正常", "Pressure OK")
        case 1: return L10n.t("压力偏高", "Pressure high")
        default: return L10n.t("压力很高", "Pressure critical")
        }
    }
}

enum ThermalLabel {
    static func from(_ state: Int) -> String {
        switch state {
        case 2: return L10n.t("偏热", "Warm")
        case 3: return L10n.t("过热", "Hot")
        default: return L10n.t("正常", "Normal")
        }
    }
}
