import Cocoa
import UniformTypeIdentifiers

/// 「打印」页的状态:待打印文件列表(批量)、打印机、参数、预设。
///
/// 批量提交:每个文件独立准备、独立提交,天然支持部分成功——成功的照常打印,
/// 失败的单独标红,不整体回滚。提交串行:一次把整批塞进 CUPS 队列会瞬间占满,也看不清是谁失败。
@MainActor
final class PrintSubmitModel: ObservableObject {
    enum Status: Equatable { case ready, submitting, done, failed(String) }

    struct Item: Identifiable, Equatable {
        var id: String { file.id }
        var file: PreparedFile
        var status: Status = .ready
    }

    @Published var items: [Item] = []
    @Published var printer = ""
    @Published var options = PrintOptions()
    @Published var presetID: String?
    @Published var preparing = false
    @Published var busy = false
    @Published var message: String?

    private var initialized = false

    var single: PreparedFile? { items.count == 1 ? items[0].file : nil }

    /// 首次进入(或打印机列表变了)时套用默认打印机与默认参数
    func ensureDefaults(_ data: PrintData) {
        if !initialized {
            initialized = true
            options = data.settings.defaultOptions
        }
        if data.printer(printer) == nil || data.printer(printer)?.hidden == true {
            printer = data.defaultPrinter()?.name ?? ""
        }
        if let p = data.printer(printer) { normalize(p.caps) }
    }

    func selectPrinter(_ name: String, data: PrintData) {
        printer = name
        if let p = data.printer(name) { normalize(p.caps) }
        // 换了打印机,专属预设可能不再适用
        if let id = presetID, !data.presets(for: name).contains(where: { $0.id == id }) { presetID = nil }
    }

    /// 打印机不支持的选项退回「不指定」,份数不超过上限。UI 置灰只是体验,不是防线
    func normalize(_ caps: PrintCaps) {
        func fix(_ v: inout String, _ ok: [String], emptyOK: Bool = true) {
            if !v.isEmpty && !ok.isEmpty && !ok.contains(v) { v = "" }
            if !v.isEmpty && ok.isEmpty && v != "" && !emptyOK { v = "" }
        }
        fix(&options.color, caps.colorModes)
        if !options.quality.isEmpty && !caps.qualities.contains(options.quality) { options.quality = "" }
        fix(&options.media, caps.media)
        fix(&options.mediaType, caps.mediaTypes)
        if !options.orientation.isEmpty && !caps.orientations.contains(options.orientation) { options.orientation = "" }
        fix(&options.sides, caps.sides)
        fix(&options.scaling, caps.scaling)
        if !caps.numberUp.contains(options.numberUp) { options.numberUp = 1 }
        options.copies = min(max(options.copies, 1), caps.copiesMax)
    }

    func applyPreset(_ p: PrintPreset, caps: PrintCaps) {
        let keepCopies = options.copies, keepRange = options.pageRange
        options = p.options
        options.copies = keepCopies
        options.pageRange = keepRange
        presetID = p.id
        normalize(caps)
    }

    // MARK: - 文件

    func add(urls: [URL]) {
        guard !urls.isEmpty else { return }
        preparing = true
        message = nil
        Task.detached(priority: .userInitiated) {
            var ok: [PreparedFile] = [], errs: [String] = []
            for u in urls {
                switch PrintFiles.prepare(u) {
                case .success(let f): ok.append(f)
                case .failure(let e): errs.append("\(u.lastPathComponent):\(e.text)")
                }
            }
            let files = ok, failures = errs
            await MainActor.run {
                self.append(files)
                self.preparing = false
                if !failures.isEmpty { self.message = failures.joined(separator: "\n") }
            }
        }
    }

    func add(text: String, title: String) {
        preparing = true
        Task.detached(priority: .userInitiated) {
            let r = PrintFiles.prepare(text: text, title: title)
            await MainActor.run {
                self.preparing = false
                switch r {
                case .success(let f): self.append([f])
                case .failure(let e): self.message = e.text
                }
            }
        }
    }

    /// 暂存文件的统一出口:释放缓存的 PDF 句柄并删文件
    private func discard(_ url: URL) {
        PrintFiles.forgetDocument(url)
        try? FileManager.default.removeItem(at: url)
    }

    private func append(_ files: [PreparedFile]) {
        items += files.map { Item(file: $0) }
        // 批量时页码范围置空(每个文件页数不同,强行套用容易越界)
        if items.count > 1 { options.pageRange = "" }
        if let w = files.flatMap(\.warnings).first { message = w }
    }

    func remove(_ id: String) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            discard(items[i].file.url)
            items.remove(at: i)
        }
        if items.count != 1 { options.pageRange = "" }
    }

    /// 清空列表。已提交的文件暂存件已被提交流程删掉;没提交的在这里删
    func clear() {
        for it in items { discard(it.file.url) }
        items = []
        options.pageRange = ""
        message = nil
    }

    func clearFinished() {
        for it in items where it.status == .done { discard(it.file.url) }
        items.removeAll { $0.status == .done }
        if items.count != 1 { options.pageRange = "" }
    }

    // MARK: - 选页(单个多页 PDF)

    /// 当前选中的页;页码范围为空 = 全选
    func selectedPages(total: Int) -> Set<Int> {
        if options.pageRange.trimmingCharacters(in: .whitespaces).isEmpty { return Set(1...max(total, 1)) }
        return PrintOptionBuilder.pageSet(options.pageRange, total: total) ?? []
    }

    func togglePage(_ p: Int, total: Int) {
        var s = selectedPages(total: total)
        if s.contains(p) { s.remove(p) } else { s.insert(p) }
        options.pageRange = PrintOptionBuilder.rangeString(pages: s, total: total)
        // 全部取消:不能提交空范围,保持一页以免误打整份
        if s.isEmpty { options.pageRange = String(p) }
    }

    // MARK: - 提交

    /// 打印张数估算(页数 × 份数),用于确认弹窗
    func sheetEstimate() -> Int? {
        var total = 0
        for it in items where it.status != .done {
            guard var pages = it.file.pages else { return nil }
            if items.count == 1, let s = PrintOptionBuilder.pageSet(options.pageRange, total: pages), !s.isEmpty,
               !options.pageRange.isEmpty { pages = s.count }
            total += pages * options.copies
        }
        return total
    }

    func submitAll(center: PrintCenter) async {
        guard !busy, !printer.isEmpty else { return }
        busy = true
        message = nil
        var okCount = 0, failCount = 0
        for idx in items.indices {
            switch items[idx].status {
            case .done, .submitting: continue
            default: break
            }
            items[idx].status = .submitting
            let f = items[idx].file
            var o = options
            if items.count > 1 { o.pageRange = "" }
            let r = await center.submitFile(f, printer: printer, options: o)
            switch r {
            case .success: items[idx].status = .done; okCount += 1
            case .failure(let e): items[idx].status = .failed(e.text); failCount += 1
            }
        }
        busy = false
        if failCount == 0 {
            message = L10n.t("已提交 \(okCount) 个文件", "Submitted \(okCount) file(s)")
        } else {
            message = L10n.t("成功 \(okCount) 个,失败 \(failCount) 个(失败的可修改参数后重试)",
                             "\(okCount) succeeded, \(failCount) failed (adjust and retry the failed ones)")
        }
    }

    /// 文件选择面板
    static func chooseFiles() -> [URL] {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.message = L10n.t("选择要打印的文件", "Choose files to print")
        NSApp.activateForUI()
        return p.runModal() == .OK ? p.urls : []
    }
}
