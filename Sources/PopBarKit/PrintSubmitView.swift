import CMetrics
import SwiftUI
import UniformTypeIdentifiers
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 打印页:文件(拖入 / 选择 / 选中文字)→ 打印机 → 预设与参数 → 选页 → 提交
struct PrintSubmitView: View {
    @ObservedObject var center: PrintCenter
    @ObservedObject var model: PrintSubmitModel
    @State private var dropTargeted = false
    @State private var confirming = false
    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var showPages = false

    private var printer: PrinterRecord? { center.data.printer(model.printer) }
    private var caps: PrintCaps { printer?.caps ?? PrintCaps() }

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    dropZone
                    if !model.items.isEmpty { fileList }
                    printerSection
                    optionsSection
                    if let f = model.single, f.kind == .pdf, let n = f.pages, n > 1 { pagesSection(f, total: n) }
                    if let m = model.message {
                        Text(m).font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                    }
                }
                .padding(.bottom, 4)
            }
            footer      // 固定在底部:主操作不能被挤到折叠线下面
        }
        .onAppear { model.ensureDefaults(center.data) }
        .onChange(of: center.data.printers) { _, _ in model.ensureDefaults(center.data) }
        .confirmationDialog(L10n.t("确认打印？", "Print now?"), isPresented: $confirming, titleVisibility: .visible) {
            Button(L10n.t("打印", "Print")) { Task { await model.submitAll(center: center) } }
        } message: { Text(confirmText) }
    }

    private var confirmText: String {
        var s = "\(printer?.displayName ?? model.printer) · " + L10n.t("\(model.pendingCount) 个文件", "\(model.pendingCount) file(s)")
        if let n = model.sheetEstimate() { s += L10n.t(" · 约 \(n) 页", " · about \(n) page(s)") }
        s += L10n.t(" · \(model.options.copies) 份", " · \(model.options.copies) copies")
        return s
    }

    // MARK: 文件

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.system(size: 22)).foregroundStyle(SysTheme.brand)
            Text(L10n.t("把文件拖到这里，或", "Drop files here, or"))
                .font(.system(size: 12)).foregroundStyle(SysTheme.secondary)
            HStack(spacing: 8) {
                PBtn(title: L10n.t("选择文件…", "Choose files…"), symbol: "folder", prominent: true) {
                    model.add(urls: PrintSubmitModel.chooseFiles())
                }
                PBtn(title: L10n.t("粘贴剪贴板文字", "Paste clipboard text"), symbol: "doc.on.clipboard") {
                    if let t = NSPasteboard.general.string(forType: .string), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        model.add(text: t, title: L10n.t("剪贴板文字", "Clipboard text"))
                    } else { model.message = L10n.t("剪贴板里没有文字", "The clipboard has no text") }
                }
            }
            Text(L10n.t("支持 ", "Supports ") + PrintFiles.supportedSummary
                 + L10n.t("；Office / iWork 自动转 PDF（优先 LibreOffice，其次 Pages / Numbers / Keynote）",
                          " — Office / iWork are converted to PDF (LibreOffice first, then Pages / Numbers / Keynote)"))
                .font(.system(size: 10)).foregroundStyle(SysTheme.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14).padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .foregroundStyle(dropTargeted ? PanelTheme.brandColor : SysTheme.cardBorder)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dropTargeted ? PanelTheme.brandColor.opacity(0.08) : SysTheme.card))
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.add(urls: [url]) } }
                }
            }
            return true
        }
    }

    private var fileList: some View {
        PSection(title: L10n.t("待打印（\(model.items.count)）", "To print (\(model.items.count))"),
                 trailing: AnyView(HStack(spacing: 6) {
                    statusSummary
                    if model.items.contains(where: \.isDone) {
                        PBtn(title: L10n.t("清除已提交", "Clear submitted")) { model.clearFinished() }
                    }
                    if model.items.contains(where: { if case .invalid = $0.status { return true }; return false }) {
                        PBtn(title: L10n.t("清除无法打印", "Clear unprintable")) { model.clearInvalid() }
                    }
                    PBtn(title: L10n.t("清空", "Clear all"), disabled: model.busy) { model.clear() }
                 })) {
            VStack(spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                    FileRow(item: item, job: jobRecord(item), busy: model.busy,
                            preview: { if let f = item.file { PrintPreviewWindow.shared.show(f) } },
                            retry: { retry(item) },
                            remove: { model.remove(item.id) })
                    if idx < model.items.count - 1 { Divider().opacity(0.35).padding(.leading, 54) }
                }
            }
        }
    }

    /// 标题栏右侧的状态计数:2 就绪 · 1 转换中 · 1 失败
    private var statusSummary: some View {
        var ready = 0, prep = 0, bad = 0, done = 0
        for it in model.items {
            switch it.status {
            case .ready: ready += 1
            case .preparing, .submitting: prep += 1
            case .invalid, .failed: bad += 1
            case .done: done += 1
            }
        }
        return HStack(spacing: 4) {
            if prep > 0 { PBadge(text: L10n.t("\(prep) 处理中", "\(prep) working"), color: SysTheme.brand) }
            if ready > 0 { PBadge(text: L10n.t("\(ready) 就绪", "\(ready) ready"), color: Color(red: 0.25, green: 0.70, blue: 0.40)) }
            if bad > 0 { PBadge(text: L10n.t("\(bad) 异常", "\(bad) issue(s)"), color: .red) }
            if done > 0 { PBadge(text: L10n.t("\(done) 已提交", "\(done) sent"), color: SysTheme.secondary) }
        }
    }

    private func jobRecord(_ item: PrintSubmitModel.Item) -> JobRecord? {
        if case .done(let id) = item.status { return center.data.job(id) }
        return nil
    }

    private func retry(_ item: PrintSubmitModel.Item) {
        switch item.status {
        case .invalid: model.retryPrepare(item.id)
        case .failed: Task { await model.retrySubmit(item.id, center: center) }
        default: break
        }
    }

    // MARK: 打印机与预设

    private var printerSection: some View {
        let presets = center.data.presets(for: model.printer)
        return PSection(title: L10n.t("打印机与预设", "Printer & presets")) {
            PTable {
                PRow(title: L10n.t("打印机", "Printer")) {
                    PMenu(label: L10n.t("选择打印机", "Choose printer"),
                          selection: Binding(get: { model.printer }, set: { model.selectPrinter($0, data: center.data) }),
                          options: center.data.visiblePrinters.map { ($0.name, $0.displayName) }, width: 300)
                    if let p = printer {
                        PBadge(text: PrintStyle.printerStateText(p), color: PrintStyle.printerColor(p))
                        if p.state == PrinterStateCode.stopped || !p.accepting {
                            Text(L10n.t("需先恢复才能提交", "Resume it before printing")).font(.system(size: 10.5)).foregroundStyle(.orange)
                        }
                    }
                }
                PRow(title: L10n.t("预设", "Presets")) {
                    if presets.isEmpty {
                        Text(L10n.t("还没有预设", "No presets yet")).font(.system(size: 11.5)).foregroundStyle(SysTheme.tertiary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(presets) { p in
                                    Button { model.applyPreset(p, caps: caps) } label: {
                                        Text(p.name).font(.system(size: 11.5, weight: model.presetID == p.id ? .semibold : .regular))
                                            .foregroundStyle(model.presetID == p.id ? Color.white : SysTheme.brand)
                                            .padding(.horizontal, 9).frame(height: PForm.fieldHeight)
                                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(model.presetID == p.id ? PanelTheme.brandColor : SysTheme.track))
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(L10n.t("用当前参数覆盖", "Overwrite with current options")) { center.updatePreset(p.id, options: model.options) }
                                        Button(L10n.t("删除", "Delete"), role: .destructive) {
                                            if model.presetID == p.id { model.presetID = nil }
                                            center.deletePreset(p.id)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: 420)
                    }
                    PBtn(title: L10n.t("存为预设", "Save preset"), symbol: "plus") { savingPreset.toggle(); presetName = "" }
                }
                if savingPreset {
                    PRow(title: L10n.t("预设名称", "Name")) {
                        PField(placeholder: L10n.t("如「双面黑白草稿」", "e.g. “Duplex draft”"), text: $presetName, width: 220)
                        PBtn(title: L10n.t("仅此打印机", "This printer only")) { savePreset(printer: model.printer) }
                        PBtn(title: L10n.t("所有打印机", "All printers"), prominent: true) { savePreset(printer: nil) }
                    }
                }
            }
        }
    }

    private func savePreset(printer: String?) {
        if let err = center.addPreset(name: presetName, printer: printer, options: model.options) { center.say(err); return }
        savingPreset = false
        center.say(L10n.t("已保存预设「\(presetName)」（份数、页码范围、先挂起不进预设）", "Preset saved (copies, page range and hold are not included)"))
    }

    // MARK: 参数

    private func mediaLabel(_ k: String) -> String {
        PrintLabels.media(k) + (k.contains("fullbleed") ? L10n.t(" · 无边距", " · borderless") : "")
    }

    /// 参数表:左右两栏各一张带边框的表,标签列、控件列在每栏内对齐;页码范围等长控件另起一张整行表
    private var optionsSection: some View {
        let c = caps
        let usable = c.media.filter { !$0.hasPrefix("custom_") }
        let W: CGFloat = 150
        let dflt = L10n.t("默认", "Default")
        var items: [(String, AnyView)] = []
        items.append((L10n.t("份数", "Copies"), AnyView(PStepper(value: $model.options.copies, range: 1...max(c.copiesMax, 1),
                                                              suffix: L10n.t(" 份", " copies"), width: W))))
        items.append((L10n.t("色彩", "Color"), AnyView(PMenu(label: "", selection: $model.options.color,
                      options: [("", dflt)] + c.colorModes.map { ($0, PrintLabels.color($0)) }, width: W))))
        if !c.qualities.isEmpty {
            items.append((L10n.t("质量", "Quality"), AnyView(PMenu(label: "", selection: $model.options.quality,
                          options: [("", dflt)] + c.qualities.map { ($0, PrintLabels.quality($0)) }, width: W))))
        }
        if !usable.isEmpty {
            items.append((L10n.t("纸张", "Paper"), AnyView(PMenu(label: "", selection: $model.options.media,
                          options: [("", L10n.t("默认（\(PrintLabels.media(c.mediaDefault))）", "Default (\(PrintLabels.media(c.mediaDefault)))"))]
                            + usable.map { ($0, mediaLabel($0)) }, width: W))))
        }
        if !c.mediaTypes.isEmpty {
            items.append((L10n.t("纸质", "Paper type"), AnyView(PMenu(label: "", selection: $model.options.mediaType,
                          options: [("", dflt)] + c.mediaTypes.map { ($0, PrintLabels.mediaType($0)) }, width: W))))
        }
        if c.sides.count > 1 {
            items.append((L10n.t("双面", "Duplex"), AnyView(PMenu(label: "", selection: $model.options.sides,
                          options: [("", dflt)] + c.sides.map { ($0, PrintLabels.sides($0)) }, width: W))))
        }
        if !c.orientations.isEmpty {
            items.append((L10n.t("方向", "Orientation"), AnyView(PMenu(label: "", selection: $model.options.orientation,
                          options: [("", PrintLabels.orientation(""))] + c.orientations.map { ($0, PrintLabels.orientation($0)) }, width: W))))
        }
        if c.numberUp.count > 1 {
            items.append((L10n.t("每张页数", "Pages/sheet"), AnyView(PMenu(label: "", selection: $model.options.numberUp,
                          options: c.numberUp.map { ($0, L10n.t("\($0) 页", "\($0) up")) }, width: W))))
        }
        if c.scaling.count > 1 {
            items.append((L10n.t("缩放", "Scaling"), AnyView(PMenu(label: "", selection: $model.options.scaling,
                          options: [("", dflt)] + c.scaling.map { ($0, PrintLabels.scaling($0)) }, width: W))))
        }
        let half = (items.count + 1) / 2
        let left = Array(items[..<half]), right = Array(items[half...])
        return PSection(title: L10n.t("打印参数", "Options"),
                        trailing: AnyView(PBtn(title: L10n.t("设为默认参数", "Make default")) {
                            center.updateSettings { $0.defaultOptions = model.options.presetSanitized() }
                            center.say(L10n.t("已保存为默认参数", "Saved as the default options"))
                        })) {
            HStack(alignment: .top, spacing: 10) {
                PTable { ForEach(left.indices, id: \.self) { i in PRow(title: left[i].0) { left[i].1 } } }
                PTable { ForEach(right.indices, id: \.self) { i in PRow(title: right[i].0) { right[i].1 } } }
            }
            PTable {
                if c.holdUntil.contains("indefinite") {
                    PRow(title: L10n.t("先挂起", "Hold")) {
                        Toggle(L10n.t("提交后先挂起，到「任务」页点继续才打印", "Hold after submit — release it from Jobs to print"),
                               isOn: $model.options.hold)
                            .toggleStyle(.checkbox).font(.system(size: 12))
                    }
                }
                if c.pageRanges {
                    PRow(title: L10n.t("页码范围", "Pages"),
                         hint: model.items.count > 1 ? L10n.t("批量时不可用", "Unavailable for batches") : nil) {
                        PField(placeholder: L10n.t("留空 = 全部，如 1-3,5", "Empty = all, e.g. 1-3,5"),
                               text: $model.options.pageRange, width: 220, disabled: model.items.count > 1)
                    }
                }
            }
        }
    }

    // MARK: 选页

    private func pagesSection(_ f: PreparedFile, total: Int) -> some View {
        let sel = model.selectedPages(total: total)
        return PSection(title: L10n.t("选择页面（\(sel.count)/\(total)）", "Pages (\(sel.count)/\(total))"),
                        trailing: AnyView(HStack(spacing: 6) {
                            PBtn(title: L10n.t("全选", "All")) { model.options.pageRange = "" }
                            PBtn(title: showPages ? L10n.t("收起", "Hide") : L10n.t("展开缩略图", "Show thumbnails")) { showPages.toggle() }
                        })) {
            if showPages {
                // 逐页缩略图只在展开时才渲染(200 页的文档不会拖垮界面)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                    ForEach(1...total, id: \.self) { p in
                        PageCell(file: f, page: p, selected: sel.contains(p)) { model.togglePage(p, total: total) }
                    }
                }
            } else {
                Text(L10n.t("展开后点击缩略图选择要打印的页；也可以直接在上面输入页码范围。", "Expand and click pages to pick them, or type a range above."))
                    .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
            }
        }
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.items.isEmpty ? L10n.t("还没有文件", "No files yet")
                     : model.pendingCount == 0 ? (model.preparing ? L10n.t("正在准备文件…", "Preparing files…") : L10n.t("没有待提交的文件", "Nothing left to print"))
                     : L10n.t("\(model.pendingCount) 个文件待打印", "\(model.pendingCount) file(s) to print")
                        + (model.sheetEstimate().map { L10n.t(" · 约 \($0) 页", " · about \($0) page(s)") } ?? ""))
                    .font(.system(size: 12, weight: .semibold))
                Text(printer.map { L10n.t("发送到 \($0.displayName)", "Send to \($0.displayName)") } ?? L10n.t("请选择打印机", "Choose a printer"))
                    .font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            PBtn(title: L10n.t("打印", "Print"), symbol: "printer.fill", prominent: true,
                 disabled: model.busy || !center.cupsOK || printer == nil || !hasPending) {
                if center.data.settings.confirmBeforePrint { confirming = true }
                else { Task { await model.submitAll(center: center) } }
            }
        }
        .padding(10)
        .background(CardBackground())
    }

    private var hasPending: Bool { model.pendingCount > 0 }
}

/// 待打印列表的一行:缩略图(点开预览)· 名称与说明 · 状态 · 操作
private struct FileRow: View {
    let item: PrintSubmitModel.Item
    let job: JobRecord?
    let busy: Bool
    let preview: () -> Void
    let retry: () -> Void
    let remove: () -> Void
    @State private var hover = false

    private static let green = Color(red: 0.25, green: 0.70, blue: 0.40)

    var body: some View {
        HStack(spacing: 10) {
            Button(action: preview) { FileThumb(item: item, hover: hover && item.file != nil) }
                .buttonStyle(.plain).disabled(item.file == nil)
                .help(item.file == nil ? "" : L10n.t("点击预览", "Click to preview"))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if item.file != nil { preview() } }
            status
            HStack(spacing: 4) {
                if canRetry {
                    PIcon(symbol: "arrow.clockwise", help: L10n.t("重试", "Retry"), tint: SysTheme.brand, action: retry)
                }
                if item.file != nil {
                    PIcon(symbol: "eye", help: L10n.t("预览", "Preview"), action: preview)
                }
                if item.status != .submitting {
                    PIcon(symbol: "xmark", help: L10n.t("移除", "Remove"), action: remove)
                }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? SysTheme.track.opacity(0.6) : .clear))
        .onHover { hover = $0 }
    }

    private var canRetry: Bool {
        switch item.status {
        case .invalid: return item.source != nil
        case .failed: return !busy
        default: return false
        }
    }

    @ViewBuilder private var detail: some View {
        switch item.status {
        case .preparing:
            Text(item.stage ?? L10n.t("正在识别与准备…", "Detecting and preparing…"))
                .font(.system(size: 10.5)).foregroundStyle(SysTheme.brand)
        case .invalid(let why), .failed(let why):
            if let f = item.file { Text(PrintFileInfo.line(f)).font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary) }
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5)).foregroundStyle(.red).labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        default:
            if let f = item.file { Text(PrintFileInfo.line(f)).font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary).lineLimit(1) }
        }
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .preparing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                PBadge(text: item.stage == nil ? L10n.t("准备中", "Preparing") : L10n.t("转换中", "Converting"), color: SysTheme.brand)
            }
        case .invalid:
            PBadge(text: L10n.t("无法打印", "Unprintable"), color: .orange, filled: true)
        case .ready:
            PBadge(text: L10n.t("就绪", "Ready"), color: Self.green)
        case .submitting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                PBadge(text: L10n.t("提交中", "Submitting"), color: SysTheme.brand)
            }
        case .done:
            if let j = job {
                // 提交后跟踪 CUPS 作业的实时状态:排队 → 打印中 → 已完成 / 出错
                HStack(spacing: 4) {
                    if j.state == .processing { ProgressView().controlSize(.mini) }
                    PBadge(text: PrintStyle.jobStateText(j) + (j.cupsJobId > 0 ? " #\(j.cupsJobId)" : ""),
                           color: PrintStyle.jobColor(j), filled: j.state == .completed || j.state == .aborted)
                }
                .help(L10n.t("作业状态会自动刷新；完整记录见「作业」页", "Job state refreshes automatically — see the Jobs tab for details"))
            } else {
                PBadge(text: L10n.t("已提交", "Submitted"), color: Self.green, filled: true)
            }
        case .failed:
            PBadge(text: L10n.t("提交失败", "Failed"), color: .red, filled: true)
        }
    }
}

/// 文件缩略图:首页,异步生成;左下角类型角标,悬停时显示「预览」
private struct FileThumb: View {
    let item: PrintSubmitModel.Item
    var hover = false
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(SysTheme.track)
            if let image { Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous)) }
            else if item.status == .preparing { ProgressView().controlSize(.mini) }
            else { Image(systemName: icon).foregroundStyle(SysTheme.tertiary) }
            if hover {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.35))
                Image(systemName: "eye.fill").font(.system(size: 12)).foregroundStyle(.white)
            }
        }
        .frame(width: 36, height: 46)
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(SysTheme.cardBorder, lineWidth: 0.5))
        .overlay(alignment: .bottomLeading) {
            if !typeLabel.isEmpty {
            Text(typeLabel).font(.system(size: 7.5, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(typeColor))
                .offset(x: -3, y: 3)
            }
        }
        .task(id: item.file?.id) {
            guard let f = item.file else { image = nil; return }
            image = await PrintFiles.renderThumbnail(file: f.url, kind: f.kind, page: 1, side: 120)
        }
    }

    private var ext: String { (item.file?.sourceExt).flatMap { $0.isEmpty ? nil : $0 } ?? (item.source?.pathExtension.lowercased() ?? "") }

    private var typeLabel: String {
        switch PrintOffice.family(ext: ext) {
        case .word: return ext == "pages" ? "PAGES" : "DOC"
        case .sheet: return ext == "numbers" ? "NUM" : "XLS"
        case .slide: return ext == "key" ? "KEY" : "PPT"
        case .rich: return ext.hasPrefix("htm") ? "HTML" : "RTF"
        case nil:
            if ext == "pdf" { return "PDF" }
            if ext.isEmpty { return item.file != nil ? "TXT" : "" }
            return String(ext.uppercased().prefix(4))
        }
    }

    private var typeColor: Color {
        switch PrintOffice.family(ext: ext) {
        case .word: return Color(red: 0.17, green: 0.36, blue: 0.85)
        case .sheet: return Color(red: 0.13, green: 0.55, blue: 0.30)
        case .slide: return Color(red: 0.85, green: 0.38, blue: 0.16)
        case .rich: return Color(red: 0.45, green: 0.45, blue: 0.55)
        case nil: return ext == "pdf" ? Color(red: 0.86, green: 0.20, blue: 0.20) : Color(red: 0.50, green: 0.40, blue: 0.80)
        }
    }

    private var icon: String {
        if case .invalid = item.status { return "doc.badge.ellipsis" }
        return "doc"
    }
}

/// 页网格里的一页:首次出现才渲染,结果进内存缓存;失败显示占位(不能一直转圈)
private struct PageCell: View {
    let file: PreparedFile
    let page: Int
    let selected: Bool
    let toggle: () -> Void
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(SysTheme.track)
                        if let image { Image(nsImage: image).resizable().scaledToFit() }
                        else if failed { Image(systemName: "doc.questionmark").foregroundStyle(SysTheme.tertiary) }
                        else { ProgressView().controlSize(.mini) }
                    }
                    .frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(selected ? PanelTheme.brandColor : Color.clear, lineWidth: 2))
                    .opacity(selected ? 1 : 0.4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(PanelTheme.brandColor)
                            .background(Circle().fill(Color.white)).padding(3)
                    }
                }
                Text("\(page)").font(.system(size: 10).monospacedDigit()).foregroundStyle(SysTheme.secondary)
            }
        }
        .buttonStyle(.plain)
        .task(id: page) {
            let key = "\(file.id)#\(page)" as NSString
            if let c = PrintThumbCache.cache.object(forKey: key) { image = c; return }
            if let img = await PrintFiles.renderThumbnail(file: file.url, kind: file.kind, page: page, side: 200) {
                PrintThumbCache.cache.setObject(img, forKey: key)
                image = img
            } else { failed = true }
        }
    }
}
