import SwiftUI
import Cocoa

/// 系统监控面板的 SwiftUI 内容(移植自 mole-demo 的状态页)。
/// 配色与 PopBar 其它面板一致:卡片底/描边取自 PanelTheme,文字用系统语义色,
/// 明暗外观自动适配;各指标的点缀色只用于小圆点、进度条和曲线。

enum SysTheme {
    /// 与 RecordPanelKit.dyn 同一思路:随外观动态取色,不用在建面板时固化
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let card = dyn(PanelTheme(dark: false).surface, PanelTheme(dark: true).surface)
    static let cardBorder = dyn(PanelTheme(dark: false).surfaceBorder, PanelTheme(dark: true).surfaceBorder)
    static let brand = dyn(PanelTheme(dark: false).brandText, PanelTheme(dark: true).brandText)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let track = Color(nsColor: .labelColor).opacity(0.09)
    static let separator = Color(nsColor: .separatorColor)
    /// 详情窗底色:不透明,浅色接近白,深色为深灰
    /// 详情窗头部的淡紫底
    static let headerTint = dyn(PanelTheme(dark: false).gradientTop, PanelTheme(dark: true).gradientTop)
    static let sheet = dyn(NSColor(white: 0.99, alpha: 1), NSColor(white: 0.15, alpha: 1))

    static let cpu = Color(red: 0.45, green: 0.62, blue: 1.0)
    static let gpu = Color(red: 0.64, green: 0.45, blue: 1.0)
    static let mem = Color(red: 0.25, green: 0.74, blue: 0.62)
    static let battery = Color(red: 0.40, green: 0.78, blue: 0.40)
    static let disk = Color(red: 0.95, green: 0.65, blue: 0.25)
    static let net = Color(red: 0.30, green: 0.68, blue: 0.98)
    static let temp = Color(red: 0.98, green: 0.48, blue: 0.36)
}

struct SystemMonitorView: View {
    @ObservedObject var vm: SystemMonitorModel
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                HealthHero(report: s.health)
                    .frame(width: 190)

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        CPUTile(s: s)
                        GPUTile(s: s)
                    }
                    HStack(spacing: 10) {
                        MemoryTile(s: s)
                        BatteryTile(s: s)
                    }
                }
            }
            .frame(height: 236)

            HStack(spacing: 10) {
                DiskTile(s: s)
                NetworkTile(s: s)
                TempTile(s: s)
            }
            .frame(height: 124)

            ProcessSection(groups: s.groups, pinned: vm.pinned, onTogglePin: vm.togglePin,
                           onOpen: vm.openDetail, onClose: onClose)
        }
        .overlay {
            if vm.detailKey != nil { ProcessDetailOverlay(vm: vm) }
        }
    }

    private var s: SystemMonitorSnapshot { vm.snap }
}

typealias SystemMonitorSnapshot = StatusSnapshot

// MARK: - Health

private struct HealthHero: View {
    let report: HealthReport

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.34), .clear],
                                         center: .center, startRadius: 6, endRadius: 64))
                    .frame(width: 104, height: 104)
                Image(systemName: report.symbolName)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [tint, tint.opacity(0.7)],
                                                    startPoint: .top, endPoint: .bottom))
                    .shadow(color: tint.opacity(0.4), radius: 12)
            }
            .frame(height: 84)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(report.score)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(report.band)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }

            Text(report.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(SysTheme.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if !report.factors.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(report.factors.prefix(3)) { f in
                        Text(f.sentence)
                            .font(.system(size: 10))
                            .foregroundStyle(SysTheme.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(14)
        .background(CardBackground())
    }

    private var tint: Color {
        if report.score > 84 { return Color(red: 0.22, green: 0.74, blue: 0.46) }
        if report.score > 64 { return Color(red: 0.30, green: 0.62, blue: 0.98) }
        if report.score > 44 { return Color(red: 0.95, green: 0.68, blue: 0.20) }
        return Color(red: 0.98, green: 0.45, blue: 0.28)
    }
}

// MARK: - Tiles

private struct CPUTile: View {
    let s: StatusSnapshot

    var body: some View {
        HUDTile(title: "CPU", accent: SysTheme.cpu) {
            BigNumber(text: pct(s.cpuPercent), extra: s.cpuTemp > 0 ? temp(s.cpuTemp) : nil)
            PerCoreStrip(values: s.perCore)
                .frame(height: 24)
                .padding(.top, 4)
            FootRow(left: LoadLabel.from(watts: s.chipWatts), right: watts(s.cpuWatts))
        }
    }
}

private struct GPUTile: View {
    let s: StatusSnapshot

    var body: some View {
        HUDTile(title: "GPU", accent: SysTheme.gpu) {
            BigNumber(text: pct(s.gpuPercent), extra: s.gpuTemp > 0 ? temp(s.gpuTemp) : nil)
            Sparkline(values: s.gpuHistory, color: SysTheme.gpu)
                .frame(height: 24)
                .padding(.top, 4)
            FootRow(left: s.aneWatts + s.dramWatts > 0
                        ? String(format: "ANE %.1fW · DRAM %.1fW", s.aneWatts, s.dramWatts)
                        : L10n.t("芯片功耗", "Chip power"),
                    right: watts(s.gpuWatts))
        }
    }
}

private struct MemoryTile: View {
    let s: StatusSnapshot

    var body: some View {
        HUDTile(title: L10n.t("内存", "Memory"), accent: SysTheme.mem) {
            BigNumber(text: pct(s.memPercent),
                      extra: PressureLabel.from(s.pressure),
                      extraColor: s.pressure == 0 ? SysTheme.secondary : .orange)
            Sparkline(values: s.memHistory, color: SysTheme.mem, fill: true)
                .frame(height: 24)
                .padding(.top, 4)
            FootRow(left: "\(bytes(s.memUsed)) / \(bytes(s.memPhys))",
                    right: L10n.t("交换 ", "Swap ") + bytes(s.swapUsed))
        }
    }
}

private struct BatteryTile: View {
    let s: StatusSnapshot

    var body: some View {
        HUDTile(title: L10n.t("电池", "Battery"), accent: SysTheme.battery) {
            if s.hasBattery {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(pct(s.batteryLevel))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(state)
                        .font(.system(size: 11))
                        .foregroundStyle(SysTheme.secondary)
                    Spacer(minLength: 0)
                    BatteryRing(percent: s.batteryHealth)
                }
                Text(L10n.t("健康 \(pct(s.batteryHealth)) · \(s.batteryCycles) 循环",
                            "Health \(pct(s.batteryHealth)) · \(s.batteryCycles) cycles"))
                    .font(.system(size: 11))
                    .foregroundStyle(SysTheme.secondary)
                    .padding(.top, 8)
                Text(L10n.t("\(s.topPowerName) 最耗电", "\(s.topPowerName) uses the most"))
                    .font(.system(size: 11))
                    .foregroundStyle(SysTheme.secondary)
                    .lineLimit(1)
                    .padding(.top, 3)
            } else {
                Text(L10n.t("台式机", "Desktop"))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(L10n.t("无内置电池", "No built-in battery"))
                    .font(.system(size: 11))
                    .foregroundStyle(SysTheme.secondary)
                    .padding(.top, 2)
                Text(L10n.t("\(s.topPowerName) 最耗电", "\(s.topPowerName) uses the most"))
                    .font(.system(size: 11))
                    .foregroundStyle(SysTheme.secondary)
                    .lineLimit(1)
                    .padding(.top, 8)
            }
        }
    }

    private var state: String {
        if s.isCharging { return L10n.t("充电中", "Charging") }
        if s.isAC { return s.batteryLevel >= 99 ? L10n.t("已充满", "Full") : L10n.t("电源适配器", "On AC") }
        return L10n.t("未充电", "On battery")
    }
}

private struct DiskTile: View {
    let s: StatusSnapshot

    var body: some View {
        HUDTile(title: L10n.t("磁盘", "Disk"), accent: SysTheme.disk) {
            let used = s.diskTotal > s.diskAvail ? s.diskTotal - s.diskAvail : 0
            let usedFrac = frac(used: used, total: s.diskTotal)
            Text(L10n.t("可用 ", "Free ") + bytes(s.diskAvail))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SysTheme.track)
                    Capsule()
                        .fill(SysTheme.disk)
                        .frame(width: max(6, geo.size.width * usedFrac))
                }
            }
            .frame(height: 6)
            .padding(.top, 8)
            Text(L10n.t("共 \(bytes(s.diskTotal)) · 已用 \(pct(usedFrac * 100))",
                        "\(bytes(s.diskTotal)) total · \(pct(usedFrac * 100)) used"))
                .font(.system(size: 11))
                .foregroundStyle(SysTheme.secondary)
                .lineLimit(1)
                .padding(.top, 6)
        }
    }
}

private struct NetworkTile: View {
    let s: StatusSnapshot

    var body: some View {
        HUDTile(title: L10n.t("网络", "Network"), accent: SysTheme.net) {
            Text(rate(s.netDown + s.netUp))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
            DualSparkline(down: s.netDownHistory, up: s.netUpHistory)
                .frame(height: 24)
                .padding(.top, 4)
            FootRow(left: s.isWifi ? "Wi-Fi" : (s.netIface.isEmpty ? L10n.t("有线", "Wired") : s.netIface),
                    right: "↓\(rate(s.netDown)) ↑\(rate(s.netUp))")
        }
    }
}

private struct TempTile: View {
    let s: StatusSnapshot

    var body: some View {
        HUDTile(title: L10n.t("温度", "Temperature"), accent: SysTheme.temp) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(s.cpuTemp > 0 ? temp(s.cpuTemp) : "—")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("/").foregroundStyle(SysTheme.secondary)
                Text(s.gpuTemp > 0 ? temp(s.gpuTemp) : "—")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                TempBar(label: "CPU", value: s.cpuTemp)
                TempBar(label: "GPU", value: s.gpuTemp)
            }
            .padding(.top, 6)
            FootRow(left: L10n.t("5 分钟峰值 \(temp(s.cpuTempPeak))/\(temp(s.gpuTempPeak))",
                                 "5-min peak \(temp(s.cpuTempPeak))/\(temp(s.gpuTempPeak))"),
                    right: ThermalLabel.from(s.thermalState))
        }
    }
}

private struct TempBar: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(SysTheme.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SysTheme.track)
                    Capsule()
                        .fill(SysTheme.temp)
                        .frame(width: max(4, geo.size.width * min(1, value / 100)))
                }
            }
            .frame(height: 5)
        }
    }
}

// MARK: - Process table

/// 小图标缓存:App 用应用图标,其余用可执行文件图标
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for g: ProcessGroup) -> NSImage {
        if let i = cache[g.id] { return i }
        let base: NSImage
        if let p = g.appPath ?? g.exePath { base = NSWorkspace.shared.icon(forFile: p) }
        else { base = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage() }
        let i = (base.copy() as? NSImage) ?? base
        i.size = NSSize(width: 32, height: 32)
        cache[g.id] = i
        return i
    }
}

private struct ProcessSection: View {
    let groups: [ProcessGroup]
    let pinned: Set<String>
    let onTogglePin: (String) -> Void
    let onOpen: (ProcessGroup) -> Void
    let onClose: () -> Void
    @State private var query = ""

    /// 按应用名、PID(任一成员)或路径过滤,不区分大小写;固定行排在最前
    private var filtered: [ProcessGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = q.isEmpty ? groups : groups.filter { g in
            g.name.lowercased().contains(q)
                || (g.appPath ?? g.exePath ?? "").lowercased().contains(q)
                || g.members.contains { String($0.pid).contains(q) || $0.name.lowercased().contains(q) }
        }
        return base.filter { pinned.contains($0.id) } + base.filter { !pinned.contains($0.id) }
    }

    var body: some View {
        let shown = filtered
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.t("进程", "Processes"))
                    .font(.system(size: 12, weight: .semibold))
                Text(query.isEmpty ? "\(groups.count)" : "\(shown.count) / \(groups.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(SysTheme.secondary)
                Spacer()
                searchField
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            columns(nil, L10n.t("名称", "Name"), L10n.t("内存", "Memory"), "%CPU",
                    L10n.t("能耗", "Energy"), "PID", trailing: false)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SysTheme.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 5)

            Rectangle().fill(SysTheme.separator).frame(height: 1)

            if groups.isEmpty {
                Text(L10n.t("正在采样进程…", "Sampling processes…"))
                    .font(.system(size: 11))
                    .foregroundStyle(SysTheme.secondary)
                    .padding(14)
            } else if shown.isEmpty {
                Text(L10n.t("没有匹配的进程", "No matching processes"))
                    .font(.system(size: 11))
                    .foregroundStyle(SysTheme.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { g in
                            GroupRow(group: g, pinned: pinned.contains(g.id), onOpen: onOpen) {
                                columns(g, g.name, ProcessText.bytes(g.memoryBytes),
                                        String(format: "%.1f%%", g.cpuPercent),
                                        String(format: "%.1f", g.powerScore), String(g.mainPID),
                                        pin: pinned.contains(g.id), menu: { menuItems(g) })
                            }
                            .contextMenu { menuItems(g) }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardBackground())
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(SysTheme.secondary)
            TextField(L10n.t("搜索应用、PID 或路径", "Search app, PID or path"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onExitCommand { query.isEmpty ? onClose() : (query = "") }   // Esc:先清空,再关闭
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(SysTheme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 190, height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SysTheme.track))
    }

    /// 右键菜单与行尾「…」按钮共用
    @ViewBuilder
    private func menuItems(_ g: ProcessGroup) -> some View {
        let isPinned = pinned.contains(g.id)
        Button { onTogglePin(g.id) } label: {
            Label(isPinned ? L10n.t("取消固定", "Unpin Row") : L10n.t("固定行", "Pin Row"),
                  systemImage: isPinned ? "pin.slash" : "pin")
        }
        Divider()
        Button { onOpen(g) } label: {
            Label(L10n.t("为什么在运行?", "Why Is This Running?"), systemImage: "lightbulb")
        }
        Button { SystemMonitorActions.revealInFinder(g) } label: {
            Label(L10n.t("在访达中显示", "Show in Finder"), systemImage: "folder")
        }
        Divider()
        Button { SystemMonitorActions.copy(g.name) } label: {
            Label(L10n.t("复制进程名称", "Copy Process Name"), systemImage: "doc.on.doc")
        }
        Button { SystemMonitorActions.copy(String(g.mainPID)) } label: {
            Label(L10n.t("复制 PID", "Copy PID"), systemImage: "doc.on.doc")
        }
        Divider()
        Button { SystemMonitorActions.terminateAndReport(g, force: false) } label: {
            Label(L10n.t("终止", "Terminate"), systemImage: "rectangle.portrait.and.arrow.right")
        }
        Button(role: .destructive) { SystemMonitorActions.terminateAndReport(g, force: true) } label: {
            Label(L10n.t("强制退出", "Force Quit"), systemImage: "xmark.circle")
        }
    }

    /// group 为 nil 表示表头(只占位,保证列对齐)
    private func columns(_ g: ProcessGroup?, _ name: String, _ mem: String, _ cpu: String, _ power: String,
                         _ pid: String, trailing: Bool = true, pin: Bool = false,
                         @ViewBuilder menu: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if let g {
                    Image(nsImage: IconCache.icon(for: g))
                        .resizable().frame(width: 16, height: 16)
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
                if pin {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(SysTheme.brand)
                }
                Text(name).lineLimit(1)
                if let g, g.count > 1 {
                    Text(verbatim: String(g.count))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(SysTheme.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(SysTheme.track))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(mem).frame(width: 80, alignment: .trailing)
            Text(cpu).frame(width: 56, alignment: .trailing)
            Text(power).frame(width: 50, alignment: .trailing)
            Text(pid).frame(width: 50, alignment: .trailing).foregroundStyle(SysTheme.secondary)
            Group {
                if trailing {
                    Menu { menu() } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SysTheme.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    Color.clear
                }
            }
            .frame(width: 22, height: 16)
        }
    }
}

/// 一行:悬停高亮,点击打开详情(「…」按钮自己处理点击,不会触发)。
/// 点击用底层的 Button 接收而不是 onTapGesture:搜索框有焦点时 SwiftUI 会把手势的第一次点击
/// 用来取消焦点,导致要点两次;Button 没有这个问题
private struct GroupRow<Content: View>: View {
    let group: ProcessGroup
    let pinned: Bool
    let onOpen: (ProcessGroup) -> Void
    @ViewBuilder let content: Content
    @State private var hover = false

    var body: some View {
        ZStack {
            Button { onOpen(group) } label: {
                Rectangle().fill(hover ? SysTheme.track : Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            content
                .font(.system(size: 11).monospacedDigit())
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
        }
        .onHover { hover = $0 }
    }
}

// MARK: - Shared chrome

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(SysTheme.card)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SysTheme.cardBorder, lineWidth: 1))
    }
}

private struct HUDTile<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SysTheme.secondary)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 7)
            content
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardBackground())
    }
}

private struct BigNumber: View {
    let text: String
    var extra: String?
    var extraColor: Color = SysTheme.secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
            if let extra {
                Text(extra)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(extraColor)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct FootRow: View {
    let left: String
    let right: String

    var body: some View {
        HStack(spacing: 6) {
            Text(left).lineLimit(1)
            Spacer(minLength: 0)
            Text(right).lineLimit(1)
        }
        .font(.system(size: 10))
        .foregroundStyle(SysTheme.secondary)
        .padding(.top, 5)
    }
}

private struct PerCoreStrip: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let n = max(values.count, 1)
            let gap: CGFloat = 2
            let w = max(2, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(SysTheme.cpu.opacity(0.35 + 0.65 * min(1, v / 100)))
                        .frame(width: w, height: max(3, geo.size.height * CGFloat(min(1, v / 100))))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    let color: Color
    var fill: Bool = false

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            if pts.count >= 2 {
                Path { p in
                    p.move(to: pts[0])
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                if fill {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        p.addLine(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.14))
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let maxV = max(values.max() ?? 1, 1)
        let minV = min(values.min() ?? 0, 0)
        let span = max(maxV - minV, 1)
        return values.enumerated().map { i, v in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                    y: size.height * (1 - CGFloat((v - minV) / span)))
        }
    }
}

private struct DualSparkline: View {
    let down: [Double]
    let up: [Double]

    var body: some View {
        ZStack {
            Sparkline(values: down, color: Color(red: 0.22, green: 0.74, blue: 0.52), fill: true)
            Sparkline(values: up, color: SysTheme.disk)
        }
    }
}

private struct BatteryRing: View {
    let percent: Double

    var body: some View {
        ZStack {
            Circle().stroke(SysTheme.track, lineWidth: 4)
            Circle()
                .trim(from: 0, to: min(1, percent / 100))
                .stroke(SysTheme.battery, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(String(format: "%.0f", percent))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .frame(width: 30, height: 30)
    }
}

// MARK: - Format

private func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }
private func temp(_ v: Double) -> String { String(format: "%.0f°", v) }
private func watts(_ v: Double) -> String { String(format: "%.1fW", v) }
private func bytes(_ v: UInt64) -> String { ByteFormat.string(Int64(clamping: v)) }

private func rate(_ v: Double) -> String {
    if v < 1024 { return String(format: "%.0f B/s", max(0, v)) }
    if v < 1024 * 1024 { return String(format: "%.0f KB/s", v / 1024) }
    return String(format: "%.1f MB/s", v / 1024 / 1024)
}

private func frac(used: UInt64, total: UInt64) -> CGFloat {
    guard total > 0 else { return 0 }
    return CGFloat(used) / CGFloat(total)
}
