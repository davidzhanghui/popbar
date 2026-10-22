import Cocoa
import PDFKit

/// 打印管理的测试:嗅探 / 参数校验 / 同步合并 / 清理策略 / 统计 / 预设 / 存储 / 发现解析 / 文件准备,
/// 以及对本机 cupsd 的只读联调(有打印机才跑;只做 Validate-Job,**绝不出纸**)。
/// 用到的 expect / expectEqual / section 在 main.swift 里。

private func g(_ attrs: [String: [IPPValue]]) -> IPPGroup { IPPGroup(tag: Int(IPP_TAG_PRINTER.rawValue), attrs: attrs) }

private func cupsJob(_ id: Int, _ state: JobState, created: Date, printer: String = "P", name: String = "doc",
                     impressions: Int = 0, done: Int = 0, completed: Date? = nil) -> CupsJob {
    CupsJob(id: id, printer: printer, name: name, user: "u", state: state, reasons: [], message: "",
            impressions: impressions, impressionsDone: done, kOctets: 1, created: created, processing: nil, completed: completed)
}

private func cupsPrinter(_ name: String = "P", state: Int = 3, markers: [PrintMarker] = []) -> CupsPrinter {
    CupsPrinter(name: name, info: name, makeModel: "Model", location: "", state: state, reasons: ["none"], stateMessage: "",
                accepting: true, queued: 0, markers: markers, caps: PrintCaps(), uri: "ipp://localhost/printers/\(name)",
                deviceURI: "", uuid: "")
}

@MainActor
func runPrintTests() async {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("popbar-print-\(UUID().uuidString)")
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    let day: TimeInterval = 86400
    let now = Date()

    // MARK: 快捷键

    section("打印 · 快捷键")
    let hkc = HotkeysConfig()
    expectEqual(hkc.printPanel, "ctrl+opt+o", "默认快捷键")
    expect(Hotkey.parse(hkc.printPanel) != nil, "默认快捷键可解析")
    let others = [hkc.showBar, hkc.history, hkc.snap, hkc.record, hkc.recordPause, hkc.recordMarker, hkc.todo]
    expect(!others.contains(hkc.printPanel), "不与其它默认快捷键冲突")
    var cfgHK = PopBarConfig(); cfgHK.hotkeys.printPanel = "ctrl+opt+k"
    let backHK = try? JSONDecoder().decode(PopBarConfig.self, from: JSONEncoder().encode(cfgHK))
    expectEqual(backHK?.hotkeys.printPanel, "ctrl+opt+k", "自定义快捷键编码往返")
    expectEqual((try? JSONDecoder().decode(PopBarConfig.self, from: Data("{\"hotkeys\":{\"showBar\":\"ctrl+opt+x\"}}".utf8)))?.hotkeys.printPanel, "ctrl+opt+o", "旧配置缺字段 → 默认值")

    // MARK: 嗅探

    section("打印 · magic 嗅探")
    func sn(_ bytes: [UInt8]) -> PrintSniff? { PrintFiles.sniff(Data(bytes)) }
    expectEqual(sn(Array("%PDF-1.7\n".utf8))?.kind, .pdf, "pdf")
    expectEqual(sn([0xff, 0xd8, 0xff, 0xe0, 0, 0x10])?.mime, "image/jpeg", "jpeg")
    expectEqual(sn([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0])?.mime, "image/png", "png")
    expectEqual(sn(Array("GIF89a".utf8))?.mime, "image/gif", "gif")
    expectEqual(sn([0x49, 0x49, 0x2a, 0x00, 1, 2])?.mime, "image/tiff", "tiff")
    expectEqual(sn(Array("BM".utf8) + [1, 2, 3, 4, 5, 6])?.mime, "image/bmp", "bmp")
    expectEqual(sn(Array("RIFF".utf8) + [1, 2, 3, 4] + Array("WEBPVP8 ".utf8))?.kind, .webp, "webp")
    expectEqual(sn([0, 0, 0, 0x18] + Array("ftypheic".utf8))?.kind, .heic, "heic")
    expectEqual(sn(Array("你好,世界 hello\n".utf8))?.kind, .text, "utf8 文本")
    let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    expectEqual(PrintFiles.sniff("中文文本内容测试".data(using: String.Encoding(rawValue: gbk))!)?.kind, .text, "GBK 文本")
    expect(sn([0x50, 0x4b, 0x03, 0x04, 0x00, 0x00, 0x08]) == nil, "docx/zip(含 NUL)不识别")
    expect(sn([1, 2, 3, 4, 5, 6, 7, 8]) == nil, "纯二进制不识别")

    section("打印 · 文件准备")
    let fakePDF = tmp.appendingPathComponent("fake.pdf")      // docx 改名成 .pdf
    try? Data([0x50, 0x4b, 0x03, 0x04, 0, 0, 0, 0, 1]).write(to: fakePDF)
    if case .failure = PrintFiles.prepare(fakePDF, staging: tmp.appendingPathComponent("st")) { expect(true, "伪装成 pdf 的 zip 被拒") } else { expect(false, "伪装成 pdf 的 zip 被拒") }
    let empty = tmp.appendingPathComponent("empty.txt"); try? Data().write(to: empty)
    if case .failure = PrintFiles.prepare(empty, staging: tmp.appendingPathComponent("st")) { expect(true, "空文件被拒") } else { expect(false, "空文件被拒") }
    let txt = tmp.appendingPathComponent("long.txt")
    let line = "这是一行中文测试文本 with some English words to wrap around the page width 0123456789\n"
    try? String(repeating: line, count: 300).write(to: txt, atomically: true, encoding: .utf8)
    if case .success(let f) = PrintFiles.prepare(txt, staging: tmp.appendingPathComponent("st")) {
        expectEqual(f.mime, "application/pdf", "文本转成 PDF 提交")
        expectEqual(f.originalMime, "text/plain", "记录原始类型")
        expect((f.pages ?? 0) >= 3, "长文本自动分页(\(f.pages ?? 0) 页)")
        expect(PDFDocument(url: f.url)?.pageCount == f.pages, "PDF 页数与记录一致")
        expect(PrintFiles.thumbnailPNG(for: f.url, kind: .pdf, page: 2) != nil, "能出第 2 页缩略图")
        expect(PrintFiles.thumbnailPNG(for: f.url, kind: .pdf, page: 9999) == nil, "越界页码返回 nil")
        let t0 = Date()
        var rendered = 0
        for pg in 1...(f.pages ?? 1) { if await PrintFiles.renderThumbnail(file: f.url, kind: .pdf, page: pg) != nil { rendered += 1 } }
        expectEqual(rendered, f.pages ?? 0, "快速渲染:每一页都出图")
        expect(Date().timeIntervalSince(t0) < 2, "快速渲染:\(f.pages ?? 0) 页耗时 \(Int(Date().timeIntervalSince(t0) * 1000)) ms < 2s")
        let img = await PrintFiles.renderThumbnail(file: f.url, kind: .pdf, page: 1, side: 200)
        expect((img?.size.width ?? 0) > 50 && (img?.size.height ?? 0) > 50, "渲染尺寸合理")
        expect(await PrintFiles.renderThumbnail(file: f.url, kind: .pdf, page: 9999) == nil, "快速渲染:越界页码返回 nil(界面显示占位而非转圈)")
        expect(await PrintFiles.renderThumbnail(file: tmp.appendingPathComponent("gone.pdf"), kind: .pdf, page: 1) == nil, "快速渲染:文件不存在返回 nil")
    } else { expect(false, "文本文件准备成功") }
    let png = tmp.appendingPathComponent("a.png")
    if let tiff = NSImage(size: NSSize(width: 40, height: 30), flipped: false, drawingHandler: { r in NSColor.red.setFill(); r.fill(); return true }).tiffRepresentation,
       let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? data.write(to: png)
        if case .success(let f) = PrintFiles.prepare(png, staging: tmp.appendingPathComponent("st")) {
            expectEqual(f.pages, 1, "图片 1 页"); expectEqual(f.mime, "image/png", "png 直送")
            expect(PrintFiles.thumbnailPNG(for: f.url, kind: .image) != nil, "图片缩略图")
            let webp = tmp.appendingPathComponent("conv.png")
            expect(PrintFiles.convertImage(f.url, to: webp, png: true), "图片格式转换(ImageIO)")
        } else { expect(false, "png 准备成功") }
    }
    if case .success(let f) = PrintFiles.prepare(text: "选中的一段文字\nsecond line", title: "sel", staging: tmp.appendingPathComponent("st")) {
        expectEqual(f.pages, 1, "划词文字生成 1 页 PDF")
    } else { expect(false, "划词文字准备成功") }

    // MARK: 页码

    section("打印 · 页码范围")
    func ranges(_ s: String) -> [[Int]]? { (try? PrintOptionBuilder.parsePageRanges(s))?.map { [$0.0, $0.1] } }
    expectEqual(ranges("1-3,5,8-") ?? [], [[1, 3], [5, 5], [8, PrintOptionBuilder.openEnd]], "1-3,5,8-")
    do { let r = try PrintOptionBuilder.parsePageRanges(""); expect(r == nil, "空 = 不指定") } catch { expect(false, "空 = 不指定") }
    for bad in ["0", "3-1", "a", "1-2-3", "-3", "1,,x"] { expect(ranges(bad) == nil, "非法页码: \(bad)") }
    expectEqual(PrintOptionBuilder.rangeString(pages: [1, 2, 3, 5], total: 8), "1-3,5", "选页 → 文本")
    expectEqual(PrintOptionBuilder.rangeString(pages: Set(1...8), total: 8), "", "全选 = 空")
    expectEqual(PrintOptionBuilder.pageSet("1-3,5", total: 8) ?? [], [1, 2, 3, 5], "文本 → 选页")
    expectEqual(PrintOptionBuilder.pageSet("6-", total: 8) ?? [], [6, 7, 8], "开区间")

    // MARK: 参数 → IPP

    section("打印 · 参数校验与 IPP 映射")
    var caps = PrintCaps()
    caps.media = ["iso_a4_210x297mm", "na_letter_8.5x11in"]
    caps.mediaTypes = ["stationery", "photographic-glossy"]
    caps.qualities = ["draft", "normal", "high"]
    caps.orientations = ["portrait", "landscape"]
    caps.sides = ["one-sided"]
    caps.pageRanges = true
    caps.copiesMax = 10
    func names(_ o: PrintOptions, pages: Int? = 5) throws -> [String] { try PrintOptionBuilder.build(o, caps: caps, pageCount: pages).map(\.name) }
    expectEqual((try? names(PrintOptions())) ?? ["x"], [], "默认参数不产生任何属性")
    var o = PrintOptions(); o.copies = 3; o.color = "monochrome"; o.quality = "high"; o.media = "iso_a4_210x297mm"; o.numberUp = 1
    expectEqual((try? names(o)) ?? [], ["copies", "media", "print-color-mode", "print-quality"], "常规映射")
    let q = try? PrintOptionBuilder.build(o, caps: caps, pageCount: nil)
    if case .enumValue(let e)? = q?.first(where: { $0.name == "print-quality" })?.value { expectEqual(e, 5, "质量 high = 5") } else { expect(false, "质量 high = 5") }
    o = PrintOptions(); o.media = "iso_a3_297x420mm"
    expect((try? names(o)) == nil, "不支持的纸张被拒")
    o = PrintOptions(); o.sides = "two-sided-long-edge"
    expect((try? names(o)) == nil, "不支持双面被拒(Validate-Job 拦不住,必须自己校验)")
    o = PrintOptions(); o.copies = 11
    expect((try? names(o)) == nil, "份数超上限被拒")
    o = PrintOptions(); o.copies = 0
    expect((try? names(o)) == nil, "份数 0 被拒")
    o = PrintOptions(); o.pageRange = "1-9"
    expect((try? names(o, pages: 5)) == nil, "页码超出文档页数被拒")
    o.pageRange = "2-4"
    expectEqual((try? names(o)) ?? [], ["page-ranges"], "合法页码范围")
    caps.pageRanges = false
    expect((try? names(o)) == nil, "打印机不支持选页被拒")
    caps.pageRanges = true
    o = PrintOptions(); o.numberUp = 4
    expect((try? names(o)) == nil, "不支持的每张页数被拒")
    var capsFmt = PrintCaps(); capsFmt.formats = ["application/pdf", "image/jpeg", "text/plain"]
    expect((try? PrintOptionBuilder.checkMime("image/png", caps: capsFmt)) != nil, "图片走 image/* 过滤器放行")
    capsFmt.formats = ["application/vnd.cups-raw"]
    expect((try? PrintOptionBuilder.checkMime("application/pdf", caps: capsFmt)) == nil, "完全不支持的格式被拒")

    // MARK: 墨量 / 状态

    section("打印 · 墨量与状态")
    let marks = PrintMarkers.parse(g(["marker-names": [.string("black ink"), .string("cyan ink"), .string("x")],
                                      "marker-levels": [.int(8), .int(-1), .int(-3)],
                                      "marker-colors": [.string("#000000"), .string("#00FFFF")],
                                      "marker-high-levels": [.int(100), .int(100), .int(100)]]))
    expectEqual(marks.count, 3, "三个耗材")
    expectEqual(marks[0].level, 8, "黑墨 8%")
    expect(marks[1].level == nil && marks[2].level == nil, "负数 = 未知(nil)")
    expectEqual(PrintMarkers.low(marks, threshold: 15).map(\.name), ["black ink"], "只有已知且低于阈值的才预警(未知不预警)")
    expectEqual(PrintMarkers.parse(g([:])).count, 0, "没有墨量属性 → 空")
    expectEqual(JobState(cups: 9), .completed, "job-state 9 = completed")
    expectEqual(JobState(cups: 7), .canceled, "job-state 7 = canceled")
    expectEqual(JobState(cups: 99), .unknown, "未知状态")
    expect(JobState.processing.isActive && !JobState.completed.isActive && JobState.aborted.isFailed, "状态分类")
    expectEqual(PrintReasons.labels(["processing-to-stop-point", "none", "job-completed-successfully"]), [], "正常结束原因全部过滤")
    expectEqual(PrintReasons.labels(["media-empty-error", "media-empty-warning"]).count, 1, "同一原因去重")
    expect(PrintReasons.hasError(["marker-supply-low-warning"]) == false, "warning 不算错误")
    expect(PrintReasons.hasError(["media-jam-error"]), "error 级原因")
    let c = PrintCaps(g(["copies-supported": [.range(1, 9999)], "print-quality-supported": [.int(3), .int(4), .int(5)],
                         "page-ranges-supported": [.bool(true)], "number-up-supported": [.int(1), .int(2), .int(7)]]))
    expectEqual(c.copiesMax, 9999, "copies 上限取 range 上界")
    expectEqual(c.qualities, ["draft", "normal", "high"], "质量枚举映射")
    expectEqual(c.numberUp, [1, 2], "number-up 只保留标准取值")
    expect(c.pageRanges, "page-ranges-supported")

    // MARK: 同步合并

    section("打印 · 同步合并(字段分栏)")
    var data = PrintData()
    let t0 = now.addingTimeInterval(-3600)
    var ev = data.merge(printers: [cupsPrinter()], jobs: ["P": [cupsJob(1, .completed, created: t0, completed: t0), cupsJob(2, .pending, created: now)]], now: now)
    expectEqual(ev.completed.count, 0, "首次同步进来的历史完成作业不误报")
    expectEqual(ev.newJobs, 2, "两个新作业")
    expectEqual(data.jobs.filter { $0.source == .external }.count, 2, "新作业默认标 external")
    // 本地字段:用户改的别名/备注、本系统作业的标题与文件
    data.printers[0].alias = "书房"; data.printers[0].note = "二楼"; data.printers[0].favorite = true
    let j2 = data.jobs.firstIndex { $0.cupsJobId == 2 }!
    data.jobs[j2].source = .app; data.jobs[j2].title = "我的文件.pdf"; data.jobs[j2].storedFile = "jobs/x/orig.pdf"
    data.jobs[j2].options.copies = 3; data.jobs[j2].pageCount = 4; data.jobs[j2].copies = 3
    ev = data.merge(printers: [cupsPrinter(state: 4)], jobs: ["P": [cupsJob(1, .completed, created: t0), cupsJob(2, .completed, created: now, impressions: 12)]], now: now)
    expectEqual(ev.completed.map(\.cupsJobId), [2], "pending → completed 触发一次完成事件")
    expectEqual(data.printers[0].alias, "书房", "同步不覆盖别名")
    expectEqual(data.printers[0].note, "二楼", "同步不覆盖备注")
    expect(data.printers[0].favorite, "同步不覆盖收藏")
    expectEqual(data.printers[0].state, 4, "CUPS 字段被更新")
    expectEqual(data.jobs[j2].title, "我的文件.pdf", "同步不覆盖作业标题")
    expectEqual(data.jobs[j2].storedFile, "jobs/x/orig.pdf", "同步不覆盖文件路径")
    expectEqual(data.jobs[j2].options.copies, 3, "同步不覆盖打印参数")
    expectEqual(data.jobs[j2].state, .completed, "CUPS 字段(状态)被更新")
    ev = data.merge(printers: [cupsPrinter(state: 4)], jobs: ["P": [cupsJob(2, .completed, created: now, impressions: 12)]], now: now)
    expectEqual(ev.completed.count, 0, "已完成的不会重复通知")
    // CUPS 清掉的活跃作业
    data.jobs.append(JobRecord(id: "z", printer: "P", cupsJobId: 7, state: .processing, created: now, source: .app, title: "z"))
    _ = data.merge(printers: [cupsPrinter()], jobs: ["P": []], now: now)
    expect(data.job("z")?.cupsMissing == true, "活跃作业在 CUPS 消失 → 标 cupsMissing")
    expect(data.job("z")?.isLive == false, "cupsMissing 的不算进行中")
    expectEqual(data.liveJobs.count, 0, "没有进行中任务")
    // 作业号复用:created 差很远 → 当新作业
    let before = data.jobs.count
    _ = data.merge(printers: [cupsPrinter()], jobs: ["P": [cupsJob(1, .pending, created: now.addingTimeInterval(10 * day))]], now: now)
    expectEqual(data.jobs.count, before + 1, "CUPS 作业号复用 → 新记录而不是覆盖旧历史")
    // 失败事件只对本系统作业
    data.jobs.append(JobRecord(id: "f", printer: "P", cupsJobId: 50, state: .processing, created: now, source: .app, title: "f"))
    ev = data.merge(printers: [cupsPrinter()], jobs: ["P": [cupsJob(50, .aborted, created: now)]], now: now)
    expectEqual(ev.failed.map(\.id), ["f"], "本系统作业被中止 → 失败事件")
    data.jobs.append(JobRecord(id: "u", printer: "P", cupsJobId: 51, state: .pending, created: now, source: .app, title: "u"))
    var byUser = cupsJob(51, .canceled, created: now); byUser.reasons = ["job-canceled-by-user"]
    ev = data.merge(printers: [cupsPrinter()], jobs: ["P": [byUser]], now: now)
    expectEqual(ev.failed.count, 0, "用户自己取消不触发失败通知")
    data.jobs.append(JobRecord(id: "u2", printer: "P", cupsJobId: 52, state: .processing, created: now, source: .app, title: "u2"))
    var plainCancel = cupsJob(52, .canceled, created: now); plainCancel.reasons = ["processing-to-stop-point"]
    ev = data.merge(printers: [cupsPrinter()], jobs: ["P": [plainCancel]], now: now)
    expectEqual(ev.failed.count, 0, "CUPS 只回 processing-to-stop-point 的取消(多半是用户取消)不报警")
    data.jobs.append(JobRecord(id: "u3", printer: "P", cupsJobId: 53, state: .processing, created: now, source: .app, title: "u3"))
    var devCancel = cupsJob(53, .canceled, created: now); devCancel.reasons = ["job-canceled-at-device"]
    ev = data.merge(printers: [cupsPrinter()], jobs: ["P": [devCancel]], now: now)
    expectEqual(ev.failed.map(\.id), ["u3"], "在打印机上被取消 → 失败通知")
    // 打印机从 CUPS 消失
    _ = data.merge(printers: [], jobs: [:], now: now)
    expect(data.printers[0].missing, "CUPS 里没了 → 标 missing 但记录保留")
    expectEqual(data.printers[0].alias, "书房", "消失的打印机别名仍在")
    // 提交与同步交错:外部记录被「收编」
    var d2 = PrintData()
    _ = d2.merge(printers: [cupsPrinter()], jobs: ["P": [cupsJob(9, .processing, created: now)]], now: now)
    let adopted = JobRecord(id: "app9", printer: "P", cupsJobId: 9, state: .pending, created: now.addingTimeInterval(1), source: .app, title: "我的", storedFile: "jobs/app9/orig.pdf")
    d2.addAppJob(adopted)
    expectEqual(d2.jobs.count, 1, "addAppJob 收编同步先看到的外部记录,不重复")
    expectEqual(d2.jobs[0].source, .app, "收编后是本系统作业")
    expectEqual(d2.jobs[0].state, .processing, "收编后保留 CUPS 的最新状态")
    expectEqual(d2.jobs[0].title, "我的", "收编后带上本地字段")
    // 默认打印机
    var d3 = PrintData()
    _ = d3.merge(printers: [cupsPrinter("B"), cupsPrinter("A")], jobs: [:], now: now)
    expectEqual(d3.defaultPrinter()?.name, "A", "没设默认 → 退回排序第一台")
    d3.settings.defaultPrinter = "B"
    expectEqual(d3.defaultPrinter()?.name, "B", "设置里的默认优先")
    d3.printers[d3.printers.firstIndex { $0.name == "B" }!].hidden = true
    expectEqual(d3.defaultPrinter()?.name, "A", "默认打印机被软删除 → 退回可见的")
    let bi = d3.printers.firstIndex { $0.name == "B" }!
    d3.printers[bi].hidden = false; d3.printers[bi].favorite = true
    expectEqual(d3.visiblePrinters.first?.name, "B", "收藏的排在前面")
    var lowD = PrintData()
    _ = lowD.merge(printers: [cupsPrinter(markers: [PrintMarker(name: "c", color: "", level: 5), PrintMarker(name: "m", color: "", level: 9), PrintMarker(name: "y", color: "", level: 80)])], jobs: [:], now: now)
    expectEqual(lowD.lowInk().count, 1, "低墨量按打印机归组:一台缺多色只出现一次")
    expectEqual(lowD.lowInk().first?.markers.count, 2, "组内列出全部低色")

    // MARK: 清理

    section("打印 · 清理策略")
    func job(_ id: String, _ st: JobState, _ src: JobSource, daysAgo: Double, file: Bool = true) -> JobRecord {
        JobRecord(id: id, printer: "P", cupsJobId: Int(id.hashValue & 0xffff), state: st, created: now.addingTimeInterval(-daysAgo * day),
                  source: src, title: id, storedFile: file ? "jobs/\(id)/orig.pdf" : "")
    }
    var cd = PrintData()
    cd.settings.externalJobKeepDays = 7; cd.settings.jobFileRetentionDays = 30
    cd.jobs = [job("ext-old", .completed, .external, daysAgo: 10), job("ext-new", .completed, .external, daysAgo: 2),
               job("ext-old-active", .processing, .external, daysAgo: 20),
               job("app-old", .completed, .app, daysAgo: 40), job("app-new", .completed, .app, daysAgo: 5),
               job("app-old-active", .pending, .app, daysAgo: 90), job("app-old-nofile", .canceled, .app, daysAgo: 60, file: false)]
    let preview = cd.cleanup(now: now, dryRun: true)
    expectEqual(preview.rowsDeleted, 1, "预演:1 条外部记录")
    expectEqual(preview.filesDeleted, 1, "预演:1 份本系统超期原文件(无文件的、外部整条删的不计)")
    expectEqual(cd.jobs.count, 7, "预演不改数据")
    let res = cd.cleanup(now: now)
    expectEqual(res.rowsDeleted, 1, "外部超期记录被删")
    expectEqual(res.filesDeleted, 1, "清理了 1 份本系统超期原文件")
    expect(cd.job("ext-old") == nil, "ext-old 已删")
    expect(cd.job("ext-old-active") != nil, "活跃作业无论多老都不碰")
    expect(cd.job("app-old") != nil, "本系统作业记录永远保留")
    expectEqual(cd.job("app-old")?.storedFile, "", "本系统超期作业只清原文件")
    expect(!(cd.job("app-old")?.localError.isEmpty ?? true), "清理后记一行说明")
    expectEqual(cd.job("app-new")?.storedFile, "jobs/app-new/orig.pdf", "未超期的原文件保留")
    expectEqual(cd.job("app-old-active")?.storedFile, "jobs/app-old-active/orig.pdf", "活跃作业的文件不碰")
    expect(res.dirsToRemove.contains("jobs/ext-old") && res.dirsToRemove.contains("jobs/app-old"), "返回待删目录")
    // completed 缺失时退回 created
    var cd2 = PrintData(); cd2.jobs = [job("x", .completed, .app, daysAgo: 100)]
    expectEqual(cd2.cleanup(now: now).filesDeleted, 1, "完成时间缺失退回创建时间")

    // MARK: 统计

    section("打印 · 用量统计")
    func sj(_ id: String, _ st: JobState, daysAgo: Double, imp: Int = 0, done: Int = 0, pages: Int? = nil, copies: Int = 1, src: JobSource = .app) -> JobRecord {
        JobRecord(id: id, printer: "P", cupsJobId: 1, state: st, impressions: imp, impressionsDone: done,
                  created: now.addingTimeInterval(-daysAgo * day), source: src, title: id, pageCount: pages, copies: copies)
    }
    expectEqual(PrintStats.pages(sj("a", .completed, daysAgo: 0, imp: 7, done: 3, pages: 2)), 7, "页数口径 1:impressions")
    expectEqual(PrintStats.pages(sj("a", .completed, daysAgo: 0, done: 3, pages: 2)), 3, "页数口径 2:impressions-completed")
    expectEqual(PrintStats.pages(sj("a", .completed, daysAgo: 0, pages: 4, copies: 3)), 12, "页数口径 3:页数 × 份数")
    expectEqual(PrintStats.pages(sj("a", .canceled, daysAgo: 0, pages: 4)), 0, "未完成的不计页数")
    var sd = PrintData()
    _ = sd.merge(printers: [cupsPrinter()], jobs: [:], now: now)
    sd.jobs = [sj("1", .completed, daysAgo: 0, pages: 2), sj("2", .completed, daysAgo: 9, pages: 3, copies: 2),
               sj("3", .canceled, daysAgo: 9, pages: 5), sj("4", .completed, daysAgo: 400, pages: 9), sj("5", .pending, daysAgo: 0, src: .external)]
    let st = PrintStats.summary(sd, days: 30, now: now)
    expectEqual(st.jobs, 4, "近 30 天 4 个任务(400 天前的被排除)")
    expectEqual(st.pages, 8, "页数 2 + 3×2")
    expectEqual(st.completed, 2, "已完成 2"); expectEqual(st.failed, 1, "失败 1"); expectEqual(st.active, 1, "进行中 1")
    expectEqual(st.byDay.count, 31, "按日补成「30 天前 → 今天」的连续序列")
    expect(st.byDay.filter { $0.jobs == 0 }.count == 29, "没有数据的日子补 0(只有今天和 9 天前有任务)")
    expectEqual(st.byDay.last?.pages, 2, "今天的页数")
    expectEqual(st.bySource.first { $0.key == "external" }?.jobs, 1, "按来源")
    expectEqual(PrintStats.summary(sd, days: 7, now: now).jobs, 2, "近 7 天")
    expectEqual(PrintStats.summary(PrintData(), days: 30, now: now).byDay.count, 0, "无数据不画空序列")

    // MARK: 预设

    section("打印 · 预设")
    var pd = PrintData()
    var po = PrintOptions(); po.copies = 5; po.pageRange = "1-2"; po.color = "monochrome"; po.sides = "two-sided-long-edge"
    let preset = try? pd.addPreset(name: "  双面黑白  ", printer: nil, options: po)
    expectEqual(preset?.name, "双面黑白", "名称去空白")
    expectEqual(preset?.options.pageRange, "", "页码范围不进预设")
    expectEqual(preset?.options.color, "monochrome", "色彩进预设")
    expect((try? pd.addPreset(name: "双面黑白", printer: nil, options: po)) == nil, "同名预设被拒")
    expect((try? pd.addPreset(name: "   ", printer: nil, options: po)) == nil, "空名被拒")
    _ = try? pd.addPreset(name: "照片", printer: "P", options: PrintOptions())
    expectEqual(pd.presets(for: "P").count, 2, "通用 + 该打印机专属")
    expectEqual(pd.presets(for: "Q").count, 1, "别的打印机只看到通用预设")
    if let id = preset?.id { try? pd.renamePreset(id, name: "新名字"); expectEqual(pd.presets.first { $0.id == id }?.name, "新名字", "重命名"); pd.deletePreset(id) }
    expectEqual(pd.presets.count, 1, "删除")
    let m = PrintSubmitModel()
    m.options.copies = 2; m.options.pageRange = "3"
    var pc = PrintCaps(); pc.sides = ["one-sided", "two-sided-long-edge"]; pc.colorModes = ["color", "monochrome"]
    m.applyPreset(PrintPreset(name: "p", printer: nil, options: po.presetSanitized()), caps: pc)
    expectEqual(m.options.copies, 2, "套用预设保留当前份数")
    expectEqual(m.options.pageRange, "3", "套用预设保留当前页码范围")
    expectEqual(m.options.sides, "two-sided-long-edge", "预设里的双面生效")
    pc.sides = ["one-sided"]
    m.normalize(pc)
    expectEqual(m.options.sides, "", "换到不支持双面的打印机 → 选项退回默认")

    // MARK: 存储

    section("打印 · 存储")
    let jsonURL = tmp.appendingPathComponent("store/print.json")
    var sdata = PrintData(); sdata.settings.lowInkThreshold = 33
    _ = sdata.merge(printers: [cupsPrinter(markers: [PrintMarker(name: "k", color: "#000000", level: 50)])], jobs: ["P": [cupsJob(3, .completed, created: t0)]], now: now)
    sdata.printers[0].alias = "别名"
    try? PrintStorage.save(sdata, to: jsonURL)
    let loaded = PrintStorage.load(from: jsonURL)
    expectEqual(loaded.printers.first?.alias, "别名", "往返:别名")
    expectEqual(loaded.settings.lowInkThreshold, 33, "往返:设置")
    expectEqual(loaded.jobs.count, 1, "往返:作业")
    expectEqual(loaded.printers.first?.markers.first?.level, 50, "往返:墨量")
    expect(((try? fm.attributesOfItem(atPath: jsonURL.path)[.posixPermissions] as? Int) ?? 0) == 0o600, "文件权限 0600")
    try? Data("{ broken".utf8).write(to: jsonURL)
    expectEqual(PrintStorage.load(from: jsonURL).printers.count, 0, "损坏文件返回空数据")
    let left = (try? fm.contentsOfDirectory(atPath: jsonURL.deletingLastPathComponent().path)) ?? []
    expect(left.contains { $0.hasPrefix("print.corrupt-") }, "损坏文件改名留底,不静默覆盖")
    expectEqual(PrintStorage.load(from: tmp.appendingPathComponent("none.json")).printers.count, 0, "文件不存在 → 空数据")
    let partial = try? JSONDecoder.printDecoder.decode(PrintSettings.self, from: Data("{\"notify\":false}".utf8))
    expectEqual(partial?.notify, false, "设置缺字段 → 其余取默认")
    expectEqual(partial?.lowInkThreshold, 15, "缺字段取默认值")

    // MARK: 发现 / 默认打印机 / 名称

    section("打印 · 发现与解析")
    let ippfindOut = """
    ipps://HP644ED795E620.local:443/ipp/print
    ipp://192.168.1.20:631/ipp/print idle accepting-jobs none
    garbage line
    ipps://HP644ED795E620.local:443/ipp/print
    """
    expectEqual(PrintCUPS.parseIppfind(ippfindOut), ["ipps://HP644ED795E620.local:443/ipp/print", "ipp://192.168.1.20:631/ipp/print"],
                "只取行首 URI、去重、忽略状态列与噪声")
    expectEqual(PrintCUPS.host(of: "ipps://HP644ED795E620.local:443/ipp/print"), "HP644ED795E620.local", "URI → 主机名")
    expectEqual(PrintCUPS.host(of: "ipp://[fe80::1]:631/x"), "fe80::1", "IPv6 主机名")
    var known = cupsPrinter("HP_Smart_Tank_580_590_series__95E620_")
    known.info = "HP Smart Tank 580-590 series [95E620]"; known.makeModel = "HP Smart Tank 580-590 series-AirPrint"
    known.deviceURI = "dnssd://HP%20Smart%20Tank%20580-590%20series%20%5B95E620%5D._ipps._tcp.local./"
    expect(PrintCUPS.isConfigured(uri: "ipps://HP644ED795E620.local:443/ipp/print", existing: [known]), "已配置的打印机按序列号片段识别")
    expect(!PrintCUPS.isConfigured(uri: "ipp://Canon8899.local/ipp/print", existing: [known]), "别的机器不误判")
    expect(!PrintCUPS.serialFragments([known]).contains("SERIES") && !PrintCUPS.serialFragments([known]).contains("AIRPRINT"), "通用词不当序列号")
    expectEqual(PrintCUPS.parseDefault("Dest A\nDefault My_Printer/inst opt=1\n"), "My_Printer", "lpoptions Default 行")
    expect(PrintCUPS.parseDefault("Dest A\n") == nil, "没有 Default 行")
    expect(PrintCUPS.validPrinterName("HP_580.a-1") && !PrintCUPS.validPrinterName("a b") && !PrintCUPS.validPrinterName("") && !PrintCUPS.validPrinterName("a/b"), "打印机名校验")
    expect(PrintCUPS.add(name: "bad name", uri: "ipp://x") != nil, "非法名称被拒(不会调用 lpadmin)")
    expect(PrintCUPS.add(name: "ok", uri: "http://x") != nil, "非 ipp URI 被拒")

    // MARK: PrintCenter(不碰 CUPS 的部分)

    section("打印 · PrintCenter")
    let center = PrintCenter()
    let r = await center.submitFile(PreparedFile(id: "t", displayName: "x.pdf", url: tmp.appendingPathComponent("x.pdf"), mime: "application/pdf",
                                                 originalMime: "application/pdf", kind: .pdf, size: 1, pages: 1),
                                    printer: "不存在的打印机", options: PrintOptions())
    if case .failure = r { expect(true, "提交到不存在的打印机被拒,不产生作业") } else { expect(false, "提交到不存在的打印机被拒") }
    expectEqual(center.data.jobs.filter { $0.title == "x.pdf" }.count, 0, "失败的提交不留记录")

    // MARK: 本机 cupsd 只读联调

    section("打印 · 本机 CUPS 联调(只读,不出纸)")
    switch PrintCUPS.listPrinters() {
    case .failure(let e):
        print("  - 跳过:无法连接 CUPS(\(e.text))")
    case .success(let ps):
        expect(true, "能连上 cupsd,\(ps.count) 台打印机")
        if let p = ps.first {
            expect(!p.name.isEmpty && p.uri.hasPrefix("ipp://"), "打印机名与 URI 解析")
            expect(!p.caps.formats.isEmpty, "能力矩阵解析出文档格式")
            if case .success = PrintCUPS.jobs(printer: p.name, which: "not-completed", limit: 5) { expect(true, "读取作业列表") } else { expect(false, "读取作业列表") }
            if case .success = PrintCUPS.jobs(printer: p.name, which: "completed", limit: 5) { expect(true, "读取已完成作业") } else { expect(false, "读取已完成作业") }
            // Validate-Job:零副作用
            let pdf = tmp.appendingPathComponent("validate.pdf")
            if case .success(let f) = PrintFiles.prepare(text: "validate only", title: "v", staging: tmp.appendingPathComponent("st")) {
                try? fm.copyItem(at: f.url, to: pdf)
                var vo = PrintOptions(); vo.copies = 2
                let ipp = (try? PrintOptionBuilder.build(vo, caps: p.caps, pageCount: 1)) ?? []
                let err = PrintCUPS.validate(printer: p.name, file: pdf.path, mime: "application/pdf", title: "popbar-validate", options: ipp)
                expect(err == nil, "Validate-Job 通过(不创建作业)\(err.map { ":" + $0.text } ?? "")")
                let bogus = PrintCUPS.validate(printer: "popbar-no-such-printer", file: pdf.path, mime: "application/pdf", title: "x", options: [])
                expect(bogus != nil, "不存在的打印机 Validate 失败")
            }
            // 读到的 cups 状态必须能合并进本地数据
            var live = PrintData()
            _ = live.merge(printers: ps, jobs: [:], now: now)
            expectEqual(live.printers.count, ps.count, "真实打印机可合并入库")
        }
    }
}
