import Foundation
import Combine

/// 系统监控 —— 采集与健康评分(移植自 mole-demo 的状态页)。
/// 采样只在面板可见时运行(start/stop 由 SystemMonitorPanel 控制),空闲时零开销。

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

struct StatusSnapshot: Equatable {
    var cpuPercent: Double = 0
    var perCore: [Double] = []
    var cpuWatts: Double = 0
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
    var pressure: Int = 0
    var batteryLevel: Double = 0
    var batteryHealth: Double = 100
    var batteryCycles: Int = 0
    var hasBattery: Bool = false
    var isCharging: Bool = false
    var isAC: Bool = false
    var diskTotal: UInt64 = 0
    var diskAvail: UInt64 = 0
    var netDown: Double = 0
    var netUp: Double = 0
    var netIface: String = ""
    var isWifi: Bool = true
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

    /// pid → 路径缓存(proc_pidpath 对每个进程调一次即可)
    private var pathCache: [Int: String?] = [:]

    private var sampler: OpaquePointer?
    private var task: Task<Void, Never>?
    private var lastPoll: Date?
    private var lastProc: Date?
    private var prevCPU: [Int: UInt64] = [:]
    private var prevProcAt: Date?
    private var prevDiskIO: UInt64 = 0
    private var haveDiskIO = false
    private var prevRx: UInt64 = 0
    private var prevTx: UInt64 = 0
    private var haveNet = false
    private var cpuTempHist: [(Date, Double)] = []
    private var gpuTempHist: [(Date, Double)] = []
    private var display = StatusSnapshot()

    func start() {
        guard !running else { return }
        running = true
        sampler = cm_sampler_create()
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
        if let sampler {
            cm_sampler_destroy(sampler)
        }
        sampler = nil
    }

    private func tick() async {
        guard let sampler else { return }
        let now = Date()
        if let last = lastPoll, now.timeIntervalSince(last) < 0.5 {
            return
        }
        lastPoll = now

        var raw = CMSnapshot()
        guard cm_sampler_poll(sampler, &raw) == 0 else { return }

        let wantProcs = lastProc == nil || now.timeIntervalSince(lastProc!) >= 1.0
        if wantProcs { lastProc = now }

        var next = display
        let cpu = blend(display.cpuPercent, raw.cpu.package_percent)
        next.cpuPercent = cpu
        next.perCore = copyCores(raw.cpu)
        next.cpuWatts = blend(display.cpuWatts, raw.chip.cpu_watts)
        next.gpuPercent = blend(display.gpuPercent, raw.chip.gpu_percent)
        next.gpuWatts = blend(display.gpuWatts, raw.chip.gpu_watts)
        next.aneWatts = raw.chip.ane_watts
        next.dramWatts = raw.chip.dram_watts
        next.chipWatts = next.cpuWatts + next.gpuWatts + next.aneWatts + next.dramWatts

        if raw.temp.have_cpu != 0 {
            next.cpuTemp = blend(display.cpuTemp == 0 ? raw.temp.cpu_temp : display.cpuTemp, raw.temp.cpu_temp)
            cpuTempHist.append((now, next.cpuTemp))
        }
        if raw.temp.have_gpu != 0 {
            next.gpuTemp = blend(display.gpuTemp == 0 ? raw.temp.gpu_temp : display.gpuTemp, raw.temp.gpu_temp)
            gpuTempHist.append((now, next.gpuTemp))
        }
        let cutoff = now.addingTimeInterval(-300)
        cpuTempHist.removeAll { $0.0 < cutoff }
        gpuTempHist.removeAll { $0.0 < cutoff }
        next.cpuTempPeak = cpuTempHist.map(\.1).max() ?? next.cpuTemp
        next.gpuTempPeak = gpuTempHist.map(\.1).max() ?? next.gpuTemp

        next.memPercent = blend(display.memPercent, raw.memory.used_percent)
        next.memUsed = raw.memory.used_bytes
        next.memPhys = raw.memory.phys_bytes
        next.swapUsed = raw.memory.swap_used
        next.pressure = Int(raw.memory.pressure_level)

        next.hasBattery = raw.battery.has_battery != 0
        next.batteryLevel = raw.battery.level_percent
        next.batteryHealth = raw.battery.health_percent
        next.batteryCycles = Int(raw.battery.cycle_count)
        next.isCharging = raw.battery.is_charging != 0
        next.isAC = raw.battery.is_ac != 0

        next.diskTotal = raw.disk.total_bytes
        next.diskAvail = raw.disk.available_important
        next.netIface = cChars(raw.net.iface)
        next.isWifi = raw.net.is_wifi != 0

        let elapsed = raw.elapsed_sec > 0.05 ? raw.elapsed_sec : 0.5
        if haveNet, elapsed >= 0.5 {
            let dr = Double(raw.net.rx_bytes &- prevRx) / elapsed
            let dt = Double(raw.net.tx_bytes &- prevTx) / elapsed
            next.netDown = max(0, dr)
            next.netUp = max(0, dt)
        }
        prevRx = raw.net.rx_bytes
        prevTx = raw.net.tx_bytes
        haveNet = true

        var diskDelta: UInt64 = 0
        if haveDiskIO, raw.procs.diskio_total >= prevDiskIO {
            diskDelta = raw.procs.diskio_total - prevDiskIO
        }
        prevDiskIO = raw.procs.diskio_total
        haveDiskIO = true

        if wantProcs {
            var rows: [ProcessRow] = []
            var newCPU: [Int: UInt64] = [:]
            let procElapsed = prevProcAt.map { now.timeIntervalSince($0) } ?? 1.0
            for p in copyProcs(raw.procs) {
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
            next.groups = ProcessGrouping.group(rows, paths: paths).filter { groupFilter?($0) ?? true }
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
            uptimeSec: raw.uptime_sec,
            driveFailing: raw.drive_failing != 0
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

private func copyProcs(_ sample: CMProcSample) -> [CProc] {
    let count = Int(sample.count)
    return withUnsafeBytes(of: sample.rows) { raw in
        let ptr = raw.bindMemory(to: CMProcRow.self)
        var out: [CProc] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let row = ptr[i]
            let name = withUnsafePointer(to: row.name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 72) { String(cString: $0) }
            }
            out.append(CProc(
                pid: Int(row.pid),
                name: name,
                phys_footprint: row.phys_footprint,
                cpu_ns: row.cpu_ns,
                diskio: row.diskio
            ))
        }
        return out
    }
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
    static func from(watts: Double) -> String {
        if watts < 20 { return L10n.t("低负载", "Light") }
        if watts < 60 { return L10n.t("正常", "Normal") }
        if watts < 85 { return L10n.t("繁忙", "Busy") }
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
