import CMetrics
import Cocoa
import UniformTypeIdentifiers
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 「打印」页的状态:待打印文件列表(批量)、打印机、参数、预设。
///
/// 批量提交:每个文件独立准备、独立提交,天然支持部分成功——成功的照常打印,
/// 失败的单独标红,不整体回滚。提交串行:一次把整批塞进 CUPS 队列会瞬间占满,也看不清是谁失败。
@MainActor
final class PrintSubmitModel: ObservableObject {
    /// 行状态:准备中 →(准备失败)/ 就绪 → 提交中 → 已提交(跟踪作业)/ 提交失败
    enum Status: Equatable {
        case preparing
        case invalid(String)        // 准备失败(类型不支持、转换失败):不能提交,可重试准备
        case ready
        case submitting
        case done(jobID: String)    // JobRecord.id,用来在列表里显示作业的实时状态
        case failed(String)         // 提交失败:改参数后可重试
    }

    struct Item: Identifiable, Equatable {
        let id: String
        var name: String
        var source: URL?
        var file: PreparedFile?
        var status: Status
        var stage: String?          // 准备中的细分步骤,如「LibreOffice 转换中…」

        var isDone: Bool { if case .done = status { return true }; return false }
        /// 还需要提交的(就绪或提交失败)
        var isPending: Bool {
            switch status { case .ready, .failed: return file != nil; default: return false }
        }
    }

    @Published var items: [Item] = []
    @Published var printer = ""
    @Published var options = PrintOptions()
    @Published var presetID: String?
    var preparing: Bool { items.contains { $0.status == .preparing } }
    @Published var busy = false
    @Published var message: String?

    private var initialized = false

    var single: PreparedFile? { items.count == 1 ? items[0].file : nil }
    /// 可提交的文件数
    var pendingCount: Int { items.filter(\.isPending).count }

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
        message = nil
        let fresh = urls.map { Item(id: UUID().uuidString, name: $0.lastPathComponent, source: $0, status: .preparing) }
        items += fresh
        if items.count > 1 { options.pageRange = "" }
        prepare(fresh.map { ($0.id, $0.source!) })
    }

    /// 准备失败的行重新准备
    func retryPrepare(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), let src = items[i].source else { return }
        items[i].status = .preparing
        items[i].stage = nil
        prepare([(id, src)])
    }

    /// 串行准备:Office 转换可能要拉起 LibreOffice / Pages,并发反而更慢也更容易互相干扰
    private func prepare(_ jobs: [(String, URL)]) {
        Task.detached(priority: .userInitiated) {
            for (id, url) in jobs {
                let r = PrintFiles.prepare(url) { stage in
                    Task { @MainActor in self.setStage(id, stage) }
                }
                await MainActor.run { self.finishPrepare(id, r) }
            }
        }
    }

    private func setStage(_ id: String, _ stage: String) {
        if let i = items.firstIndex(where: { $0.id == id }), items[i].status == .preparing { items[i].stage = stage }
    }

    private func finishPrepare(_ id: String, _ r: Result<PreparedFile, PrintError>) {
        // 准备期间用户可能已经移除了这一行:结果作废,文件删掉
        guard let i = items.firstIndex(where: { $0.id == id }) else {
            if case .success(let f) = r { discard(f.url) }
            return
        }
        items[i].stage = nil
        switch r {
        case .success(let f):
            items[i].file = f
            items[i].status = .ready
            if let w = f.warnings.first { message = w }
        case .failure(let e):
            items[i].status = .invalid(e.text)
        }
    }

    func add(text: String, title: String) {
        let id = UUID().uuidString
        items.append(Item(id: id, name: title, status: .preparing, stage: L10n.t("生成 PDF…", "Rendering PDF…")))
        if items.count > 1 { options.pageRange = "" }
        Task.detached(priority: .userInitiated) {
            let r = PrintFiles.prepare(text: text, title: title)
            await MainActor.run { self.finishPrepare(id, r) }
        }
    }

    /// 暂存文件的统一出口:释放缓存的 PDF 句柄并删文件
    private func discard(_ url: URL) {
        PrintFiles.forgetDocument(url)
        try? FileManager.default.removeItem(at: url)
    }

    func remove(_ id: String) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            if let f = items[i].file { discard(f.url) }
            items.remove(at: i)
        }
        if items.count != 1 { options.pageRange = "" }
    }

    /// 清空列表。准备中的行结果回来时发现行已不在,会自己删掉暂存件
    func clear() {
        for it in items { if let f = it.file { discard(f.url) } }
        items = []
        options.pageRange = ""
        message = nil
    }

    func clearFinished() {
        for it in items where it.isDone { if let f = it.file { discard(f.url) } }
        items.removeAll { $0.isDone }
        if items.count != 1 { options.pageRange = "" }
    }

    func clearInvalid() {
        items.removeAll { if case .invalid = $0.status { return true }; return false }
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
        for it in items where it.isPending {
            guard var pages = it.file?.pages else { return nil }
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
        for id in items.filter(\.isPending).map(\.id) {
            if await submitOne(id, center: center) { okCount += 1 } else { failCount += 1 }
        }
        busy = false
        if failCount == 0 {
            message = L10n.t("已提交 \(okCount) 个文件", "Submitted \(okCount) file(s)")
        } else {
            message = L10n.t("成功 \(okCount) 个，失败 \(failCount) 个（失败的可修改参数后重试）",
                             "\(okCount) succeeded, \(failCount) failed (adjust and retry the failed ones)")
        }
    }

    /// 单行重试提交
    func retrySubmit(_ id: String, center: PrintCenter) async {
        guard !busy, !printer.isEmpty else { return }
        busy = true
        _ = await submitOne(id, center: center)
        busy = false
    }

    private func submitOne(_ id: String, center: PrintCenter) async -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }), let f = items[idx].file else { return false }
        items[idx].status = .submitting
        var o = options
        if items.count > 1 { o.pageRange = "" }
        let r = await center.submitFile(f, printer: printer, options: o)
        // 提交期间行可能被移除(提交中的行不显示移除按钮,但「清空」仍可用)
        guard let i = items.firstIndex(where: { $0.id == id }) else { return (try? r.get()) != nil }
        switch r {
        case .success(let job): items[i].status = .done(jobID: job.id); return true
        case .failure(let e): items[i].status = .failed(e.text); return false
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
