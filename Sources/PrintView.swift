import SwiftUI
import Cocoa

// MARK: - 共用小组件

/// 圆角徽标
struct PBadge: View {
    let text: String
    var color: Color = SysTheme.secondary
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(filled ? color : color.opacity(0.14)))
            .lineLimit(1)
    }
}

/// 胶囊按钮(与系统维护 / 启动项面板同款)
struct PBtn: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    var destructive = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(prominent ? Color.white : (destructive ? Color.red : SysTheme.brand))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(prominent ? PanelTheme.brandColor : SysTheme.track))
            .opacity(disabled ? 0.4 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// 图标按钮
struct PIcon: View {
    let symbol: String
    var help: String = ""
    var tint: Color = SysTheme.secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(SysTheme.track))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// 下拉选择。默认是胶囊(筛选条用);给了 width 就是表单里的带边框等宽字段
struct PMenu<T: Hashable>: View {
    var label: String
    @Binding var selection: T
    var options: [(T, String)]
    var width: CGFloat? = nil
    var disabled = false

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button {
                    selection = options[i].0
                } label: {
                    if options[i].0 == selection { Label(options[i].1, systemImage: "checkmark") } else { Text(options[i].1) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(options.first { $0.0 == selection }?.1 ?? label)
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                if width != nil { Spacer(minLength: 0) }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(width != nil ? Color.primary : SysTheme.brand)
            .padding(.horizontal, 9)
            .frame(width: width, height: width != nil ? PForm.fieldHeight : nil)
            .padding(.vertical, width != nil ? 0 : 4)
            .background(PFieldBackground(capsule: width == nil))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .disabled(disabled).opacity(disabled ? 0.4 : 1)
    }
}

/// 表单字段底板:带边框的圆角矩形(胶囊用于筛选条)
struct PFieldBackground: View {
    var capsule = false
    var body: some View {
        if capsule {
            Capsule().fill(SysTheme.track)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SysTheme.card)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(SysTheme.separator, lineWidth: 1))
        }
    }
}

enum PForm {
    static let labelWidth: CGFloat = 76
    static let fieldHeight: CGFloat = 26
    static let fieldWidth: CGFloat = 190
}

/// 带边框的表单字段:文本输入
struct PField: View {
    var placeholder: String = ""
    @Binding var text: String
    var width: CGFloat? = PForm.fieldWidth
    var disabled = false
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain).font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(width: width, height: PForm.fieldHeight)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(PFieldBackground())
            .onSubmit(onSubmit)
            .disabled(disabled).opacity(disabled ? 0.45 : 1)
    }
}

/// 带边框的步进器:「− 值 +」,suffix 如「 天」「 %」
struct PStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step = 1
    var prefix = ""
    var suffix = ""
    var width: CGFloat = 120

    var body: some View {
        HStack(spacing: 0) {
            btn("minus") { value = max(range.lowerBound, value - step) }.disabled(value <= range.lowerBound)
            Divider().frame(height: PForm.fieldHeight - 10)
            Text("\(prefix)\(value)\(suffix)").font(.system(size: 12).monospacedDigit())
                .frame(maxWidth: .infinity).lineLimit(1)
            Divider().frame(height: PForm.fieldHeight - 10)
            btn("plus") { value = min(range.upperBound, value + step) }.disabled(value >= range.upperBound)
        }
        .frame(width: width, height: PForm.fieldHeight)
        .background(PFieldBackground())
    }

    private func btn(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(SysTheme.brand)
                .frame(width: 26, height: PForm.fieldHeight).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// 表单表格:整体一圈边框,行之间发丝线分隔(每行自己在底部画线,最后一行的线被遮掉)
struct PTable<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .mask(Rectangle().padding(.bottom, 1))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SysTheme.track.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SysTheme.separator, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 表单一行:固定宽度的标签列 + 控件,统一行高与内边距,底部发丝线
struct PRow<Content: View>: View {
    let title: String
    var hint: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(SysTheme.secondary)
                .frame(width: PForm.labelWidth, alignment: .leading)
            content
            Spacer(minLength: 0)
            if let hint { Text(hint).font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary).lineLimit(1) }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .overlay(alignment: .bottom) { Rectangle().fill(SysTheme.separator.opacity(0.6)).frame(height: 1) }
    }
}

/// 卡片分组
struct PSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

/// 墨量条:每色一根,低于阈值标红;不知道墨量时显示「未知」
struct PInkBars: View {
    let markers: [PrintMarker]
    var threshold = 15
    var compact = false

    var body: some View {
        if markers.isEmpty {
            Text(L10n.t("打印机未上报墨量", "No supply levels reported"))
                .font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary)
        } else {
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                    HStack(spacing: 6) {
                        let c = PrintMarkers.rgb(m)
                        Circle().fill(Color(red: c.0, green: c.1, blue: c.2)).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                        if !compact {
                            Text(m.name).font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary)
                                .frame(width: 78, alignment: .leading).lineLimit(1)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(SysTheme.track)
                                Capsule().fill((m.level ?? 100) <= threshold ? Color.red : Color(red: c.0, green: c.1, blue: c.2))
                                    .frame(width: g.size.width * CGFloat(m.level ?? 0) / CGFloat(max(m.max, 1)))
                            }
                        }
                        .frame(height: 5)
                        Text(m.level.map { "\($0)%" } ?? L10n.t("未知", "—"))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle((m.level ?? 100) <= threshold ? Color.red : SysTheme.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// 缩略图(磁盘 PNG,带内存缓存)
enum PrintThumbCache {
    static let cache = NSCache<NSString, NSImage>()
}

struct PThumb: View {
    let url: URL?
    var width: CGFloat = 36
    var height: CGFloat = 48
    var symbol = "doc"
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(SysTheme.track)
            if let image {
                Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(SysTheme.tertiary)
            }
        }
        .frame(width: width, height: height)
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = PrintThumbCache.cache.object(forKey: url.path as NSString) { image = c; return }
            let img = await Task.detached { NSImage(contentsOf: url) }.value
            if let img { PrintThumbCache.cache.setObject(img, forKey: url.path as NSString) }
            image = img
        }
    }
}

enum PrintStyle {
    static func printerColor(_ p: PrinterRecord) -> Color {
        if p.missing { return .gray }
        if PrintReasons.hasError(p.reasons) { return .red }
        switch p.state {
        case PrinterStateCode.idle: return Color(red: 0.25, green: 0.70, blue: 0.40)
        case PrinterStateCode.processing: return PanelTheme.brandColor
        case PrinterStateCode.stopped: return .orange
        default: return .gray
        }
    }

    static func printerStateText(_ p: PrinterRecord) -> String {
        if p.missing { return L10n.t("CUPS 中已不存在", "Gone from CUPS") }
        if !p.accepting { return L10n.t("停止接收", "Rejecting jobs") }
        return PrinterStateCode.label(p.state)
    }

    static func jobColor(_ j: JobRecord) -> Color {
        if j.cupsMissing && j.state.isActive { return .gray }
        switch j.state {
        case .completed: return Color(red: 0.25, green: 0.70, blue: 0.40)
        case .processing: return PanelTheme.brandColor
        case .pending: return Color(red: 0.30, green: 0.60, blue: 0.95)
        case .held, .stopped: return .orange
        case .canceled: return .gray
        case .aborted: return .red
        case .unknown: return .gray
        }
    }

    static func jobStateText(_ j: JobRecord) -> String {
        if j.cupsMissing && j.state.isActive { return L10n.t("已结束(CUPS 已清理)", "Finished (purged by CUPS)") }
        return j.state.label
    }

    static func time(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - 面板

struct PrintView: View {
    @ObservedObject var center: PrintCenter

    var body: some View {
        VStack(spacing: 10) {
            if !center.cupsOK { cupsBanner }
            if center.cupsOK || !center.data.printers.isEmpty { inkBanner }
            tabBar
            Group {
                switch center.tab {
                case .overview: PrintOverviewView(center: center)
                case .printers: PrintPrintersView(center: center)
                case .jobs: PrintJobsView(center: center)
                case .submit: PrintSubmitView(center: center, model: center.submit)
                case .stats: PrintStatsView(center: center)
                case .manage: PrintManageView(center: center)
                }
            }
            .frame(maxHeight: .infinity)
            if let n = center.notice {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11))
                    Text(n).font(.system(size: 11)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { center.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain)
                }
                .foregroundStyle(SysTheme.brand)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PanelTheme.brandColor.opacity(0.10)))
            }
        }
    }

    private var cupsBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t("无法连接 CUPS 打印服务", "Cannot reach the CUPS print service")).font(.system(size: 12, weight: .semibold))
                Text(L10n.t("页面显示的是上次缓存的数据,写操作暂不可用。", "Showing cached data; write actions are unavailable.")
                     + (center.cupsError.isEmpty ? "" : " " + center.cupsError))
                    .font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary)
            }
            Spacer()
            PBtn(title: L10n.t("重试", "Retry")) { center.syncNow() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.14)))
    }

    /// 耗材预警:按打印机归组后再显示
    @ViewBuilder private var inkBanner: some View {
        let low = center.data.lowInk()
        if !low.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(low, id: \.printer.id) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "drop.fill").font(.system(size: 11)).foregroundStyle(.red)
                        Text(L10n.t("\(item.printer.displayName) 墨量偏低:", "\(item.printer.displayName) is low on ink: ")
                             + item.markers.map { "\($0.name) \($0.level ?? 0)%" }.joined(separator: "、"))
                            .font(.system(size: 11.5)).lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.10)))
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PrintTab.allCases) { t in
                let on = center.tab == t
                let badge = t == .jobs ? center.data.liveJobs.count : 0
                Button { center.tab = t } label: {
                    HStack(spacing: 4) {
                        Image(systemName: t.symbol).font(.system(size: 11))
                        Text(t.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                        if badge > 0 {
                            Text("\(badge)").font(.system(size: 10).monospacedDigit())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(on ? Color.white.opacity(0.25) : PanelTheme.brandColor.opacity(0.18)))
                        }
                    }
                    .foregroundStyle(on ? Color.white : SysTheme.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? PanelTheme.brandColor : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SysTheme.track))
    }
}

// MARK: - 总览

struct PrintOverviewView: View {
    @ObservedObject var center: PrintCenter

    var body: some View {
        let d = center.data
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.visiblePrinters.isEmpty ? L10n.t("还没有打印机", "No printers yet")
                             : L10n.t("\(d.visiblePrinters.count) 台打印机 · \(d.liveJobs.count) 个任务进行中",
                                      "\(d.visiblePrinters.count) printer(s) · \(d.liveJobs.count) active job(s)"))
                            .font(.system(size: 15, weight: .bold))
                        Text(L10n.t("直接对接 macOS 自带的 CUPS,查看状态与墨量、提交打印、管理任务",
                                    "Talks directly to macOS's CUPS: status & ink, printing, job control"))
                            .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                    }
                    Spacer()
                    PBtn(title: L10n.t("打印文件", "Print File"), symbol: "doc.badge.plus", prominent: true) {
                        center.tab = .submit
                        center.submit.add(urls: PrintSubmitModel.chooseFiles())
                    }
                    PIcon(symbol: "arrow.clockwise", help: L10n.t("刷新", "Refresh")) { center.syncNow() }
                }
                .padding(.horizontal, 4)

                if d.visiblePrinters.isEmpty {
                    PSection(title: L10n.t("开始使用", "Get started")) {
                        Text(L10n.t("在「管理」页搜索局域网里的打印机并添加(免驱 IPP Everywhere),或先到系统设置里添加。",
                                    "Add a printer from the Manage tab (driverless IPP Everywhere) or in System Settings."))
                            .font(.system(size: 11.5)).foregroundStyle(SysTheme.secondary)
                        PBtn(title: L10n.t("去添加打印机", "Add a printer"), symbol: "plus", prominent: true) { center.tab = .manage }
                    }
                }

                ForEach(d.visiblePrinters) { p in printerCard(p) }

                let live = d.sortedJobs().filter(\.isLive)
                if !live.isEmpty {
                    PSection(title: L10n.t("进行中", "In progress")) {
                        VStack(spacing: 0) { ForEach(live) { PrintJobRow(center: center, job: $0, compact: true) } }
                    }
                }
                let recent = Array(d.sortedJobs().filter { !$0.isLive }.prefix(5))
                if !recent.isEmpty {
                    PSection(title: L10n.t("最近任务", "Recent jobs"),
                             trailing: AnyView(PBtn(title: L10n.t("全部", "All")) { center.tab = .jobs })) {
                        VStack(spacing: 0) { ForEach(recent) { PrintJobRow(center: center, job: $0, compact: true) } }
                    }
                }
            }
        }
    }

    private func printerCard(_ p: PrinterRecord) -> some View {
        let d = center.data
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "printer.fill").font(.system(size: 14)).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PanelTheme.brandColor))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if d.settings.defaultPrinter == p.name || (d.settings.defaultPrinter.isEmpty && d.defaultPrinter()?.name == p.name) {
                            PBadge(text: L10n.t("默认", "Default"), color: PanelTheme.brandColor)
                        }
                    }
                    Text(p.makeModel.isEmpty ? p.name : p.makeModel).font(.system(size: 10.5))
                        .foregroundStyle(SysTheme.secondary).lineLimit(1)
                }
                Spacer()
                PBadge(text: PrintStyle.printerStateText(p), color: PrintStyle.printerColor(p), filled: true)
            }
            let msgs = PrintReasons.labels(p.reasons)
            if !msgs.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10.5))
                    Text(msgs.joined(separator: " · ")).font(.system(size: 11))
                }
                .foregroundStyle(PrintReasons.hasError(p.reasons) ? Color.red : Color.orange)
            }
            PInkBars(markers: p.markers, threshold: d.settings.lowInkThreshold, compact: true)
            HStack(spacing: 6) {
                if p.state == PrinterStateCode.stopped {
                    PBtn(title: L10n.t("恢复", "Resume"), symbol: "play.fill", disabled: !center.cupsOK) { Task { await center.resume(p.name) } }
                } else {
                    PBtn(title: L10n.t("暂停", "Pause"), symbol: "pause.fill", disabled: !center.cupsOK) { Task { await center.pause(p.name) } }
                }
                PBtn(title: L10n.t("打印", "Print"), symbol: "doc.badge.plus") {
                    center.submit.selectPrinter(p.name, data: center.data)
                    center.tab = .submit
                }
                Spacer()
                Text(L10n.t("队列 \(p.queued)", "Queue \(p.queued)")).font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary)
            }
        }
        .padding(10)
        .background(CardBackground())
    }
}

// MARK: - 面板注册

extension ToolPanels {
    @MainActor static let printing = ToolPanel(
        title: L10n.t("打印管理", "Print"), symbol: "printer",
        size: NSSize(width: 720, height: 720),
        onShow: { PrintCenter.shared.panelOpened() },
        content: { AnyView(PrintView(center: PrintCenter.shared)) })
}

// MARK: - 划词打印

/// 工具条动作「打印选中文字」:把选中文字排成 PDF,放进「打印」页待打印列表,
/// 由用户选打印机与份数后确认——不会选中就直接出纸
enum PrintAction {
    static func barAction() -> BarAction? {
        BarAction(
            id: "builtin.print", title: L10n.t("打印选中文字", "Print Selection"),
            symbol: "printer.fill", color: .systemIndigo,
            isAvailable: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { ctx in
            let text = ctx.text
            let app = ctx.origin == .selection ? ctx.appName : nil
            FloatingBarController.shared.hide()
            Task { @MainActor in
                let c = PrintCenter.shared
                let stamp = Date().formatted(date: .abbreviated, time: .shortened)
                c.submit.clear()
                c.submit.add(text: text, title: (app.map { "\($0) · " } ?? "") + L10n.t("选中文字 \(stamp)", "Selection \(stamp)"))
                c.tab = .submit
                ToolPanels.printing.show()
            }
        }
    }
}
