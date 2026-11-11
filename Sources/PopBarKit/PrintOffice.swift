import Cocoa
import PopBarCore

/// Office / iWork / 富文本 → PDF。
///
/// CUPS 不认这些格式,必须先在本机转成 PDF。按保真度依次尝试三条路(装了哪个用哪个):
///   1. LibreOffice 无头转换(`soffice --headless --convert-to pdf`):全格式、版式最准
///   2. iWork(Pages / Numbers / Keynote)经 AppleScript 导出 PDF:macOS 自带,能打开 doc/xls/ppt 全家
///   3. 系统富文本引擎(NSAttributedString + TextKit 分页):只适用文字类(doc/docx/odt/rtf/html),
///      页眉页脚、浮动图形会丢,作为兜底
enum PrintOffice {
    enum Family: String { case word, sheet, slide, rich }

    /// 扩展名 → 类别。只在 magic 已确认是对应容器(ZIP / OLE2 / RTF / 文本)后使用
    static func family(ext: String) -> Family? {
        switch ext.lowercased() {
        case "doc", "docx", "docm", "dotx", "odt", "pages", "wps": return .word
        case "xls", "xlsx", "xlsm", "ods", "numbers", "et": return .sheet
        case "ppt", "pptx", "pptm", "ppsx", "odp", "key", "dps": return .slide
        case "rtf", "rtfd", "html", "htm": return .rich
        default: return nil
        }
    }

    static let zipExts: Set<String> = ["docx", "docm", "dotx", "xlsx", "xlsm", "pptx", "pptm", "ppsx",
                                       "odt", "ods", "odp", "pages", "numbers", "key"]
    static let oleExts: Set<String> = ["doc", "xls", "ppt", "wps", "et", "dps"]

    static func mime(ext: String) -> String {
        switch ext.lowercased() {
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "doc", "wps": return "application/msword"
        case "xls", "et": return "application/vnd.ms-excel"
        case "ppt", "dps": return "application/vnd.ms-powerpoint"
        case "odt": return "application/vnd.oasis.opendocument.text"
        case "ods": return "application/vnd.oasis.opendocument.spreadsheet"
        case "odp": return "application/vnd.oasis.opendocument.presentation"
        case "pages": return "application/vnd.apple.pages"
        case "numbers": return "application/vnd.apple.numbers"
        case "key": return "application/vnd.apple.keynote"
        case "rtf", "rtfd": return "application/rtf"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }

    /// 给界面看的短标签(文件列表的类型角标)
    static func label(ext: String) -> String {
        switch family(ext: ext) {
        case .word: return ext.lowercased() == "pages" ? "Pages" : "Word"
        case .sheet: return ext.lowercased() == "numbers" ? "Numbers" : "Excel"
        case .slide: return ext.lowercased() == "key" ? "Keynote" : "PPT"
        case .rich: return ext.lowercased().hasPrefix("htm") ? "HTML" : "RTF"
        case nil: return ext.uppercased()
        }
    }

    // MARK: - 引擎探测

    static func sofficePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cands = ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
                     "\(home)/Applications/LibreOffice.app/Contents/MacOS/soffice",
                     "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"]
        return cands.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// iWork 应用名与 bundle id(老版本叫 com.apple.iWork.*,新版本 App Store 版同 id)
    static func iWorkApp(for f: Family, ext: String) -> (name: String, bundle: String)? {
        switch f {
        case .word: return ("Pages", "com.apple.iWork.Pages")
        case .sheet: return ("Numbers", "com.apple.iWork.Numbers")
        case .slide: return ("Keynote", "com.apple.iWork.Keynote")
        case .rich: return nil
        }
    }

    static func installed(bundle: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil
    }

    /// 当前机器可用的转换方式(给界面提示用)
    static func availableEngines() -> [String] {
        var e: [String] = []
        if sofficePath() != nil { e.append("LibreOffice") }
        for (n, b) in [("Pages", "com.apple.iWork.Pages"), ("Numbers", "com.apple.iWork.Numbers"), ("Keynote", "com.apple.iWork.Keynote")]
        where installed(bundle: b) { e.append(n) }
        return e
    }

    // MARK: - 转换

    /// 把 `src` 转成 PDF 写到 `out`。成功返回使用的引擎名;只在后台线程调用(会阻塞到转换结束)
    static func convert(_ src: URL, ext: String, to out: URL, onEngine: (String) -> Void = { _ in }) -> Result<String, PrintError> {
        guard let fam = family(ext: ext) else { return .failure(.message(L10n.t("不支持的文档格式", "Unsupported document format"))) }
        var errs: [String] = []
        let fm = FileManager.default

        // 富文本:系统引擎就是最准的,不必绕远路
        if fam == .rich {
            onEngine(L10n.t("系统排版", "System"))
            if renderNative(src, ext: ext, to: out) { return .success(L10n.t("系统排版", "System")) }
            return .failure(.message(L10n.t("文档解析失败", "Failed to parse the document")))
        }

        if let soffice = sofficePath() {
            onEngine("LibreOffice")
            switch convertSoffice(soffice, src: src, to: out) {
            case .success: return .success("LibreOffice")
            case .failure(let e): errs.append("LibreOffice:\(e.text)")
            }
        }
        if let app = iWorkApp(for: fam, ext: ext), installed(bundle: app.bundle) {
            onEngine(app.name)
            switch convertIWork(app.name, src: src, to: out) {
            case .success: return .success(app.name)
            case .failure(let e): errs.append("\(app.name):\(e.text)")
            }
        }
        if fam == .word, ["doc", "docx", "docm", "dotx", "odt"].contains(ext.lowercased()) {
            onEngine(L10n.t("系统排版", "System"))
            if renderNative(src, ext: ext, to: out) { return .success(L10n.t("系统排版", "System")) }
            errs.append(L10n.t("系统排版：解析失败", "System: failed to parse"))
        }
        try? fm.removeItem(at: out)
        if errs.isEmpty {
            let need = fam == .sheet ? "Numbers" : (fam == .slide ? "Keynote" : "Pages")
            return .failure(.message(L10n.t("没有可用的转换工具：请安装 LibreOffice（免费）或 \(need)",
                                            "No converter available: install LibreOffice (free) or \(need)")))
        }
        return .failure(.message(L10n.t("转换失败：", "Conversion failed: ") + errs.joined(separator: ";")))
    }

    /// LibreOffice 无头转换。用独立的用户配置目录:用户正开着 LibreOffice 时也不会冲突(否则会静默失败)
    static func convertSoffice(_ soffice: String, src: URL, to out: URL) -> Result<Void, PrintError> {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("popbar-lo-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let profile = PrintStorage.directory.appendingPathComponent("lo-profile", isDirectory: true)
        let r = Shell.exec(.init(soffice, ["-env:UserInstallation=" + profile.absoluteString,
                                           "--headless", "--norestore", "--nologo", "--nodefault", "--nolockcheck",
                                           "--convert-to", "pdf", "--outdir", work.path, src.path],
                                 timeout: 180))
        let produced = work.appendingPathComponent(src.deletingPathExtension().lastPathComponent + ".pdf")
        guard fm.fileExists(atPath: produced.path) else {
            return .failure(.message(r.ok ? L10n.t("没有生成 PDF", "No PDF produced") : r.error))
        }
        try? fm.removeItem(at: out)
        do { try fm.moveItem(at: produced, to: out) } catch { return .failure(.message(error.localizedDescription)) }
        return .success(())
    }

    /// iWork 经 osascript 导出 PDF。路径走 argv,不拼进脚本;应用原本没开的话导出完顺手退出
    static func convertIWork(_ app: String, src: URL, to out: URL) -> Result<Void, PrintError> {
        let script = """
        on run argv
            set src to POSIX file (item 1 of argv)
            set dst to POSIX file (item 2 of argv)
            set wasRunning to application "\(app)" is running
            tell application "\(app)"
                set d to open src
                export d to dst as PDF
                close d saving no
                if not wasRunning then quit
            end tell
        end run
        """
        try? FileManager.default.removeItem(at: out)
        let r = Shell.exec(.init("/usr/bin/osascript", ["-e", script, src.path, out.path], timeout: 180))
        if FileManager.default.fileExists(atPath: out.path) { return .success(()) }
        var why = r.error
        if r.stderr.contains("-1743") || r.stderr.contains("Not authorized") {
            why = L10n.t("未授权 PopBar 控制 \(app)（系统设置 → 隐私与安全性 → 自动化）",
                         "PopBar is not allowed to control \(app) (System Settings → Privacy & Security → Automation)")
        }
        return .failure(.message(why.isEmpty ? L10n.t("没有生成 PDF", "No PDF produced") : why))
    }

    // MARK: - 系统富文本引擎

    static func attributedString(_ src: URL, ext: String) -> NSAttributedString? {
        let type: NSAttributedString.DocumentType?
        switch ext.lowercased() {
        case "docx", "docm", "dotx": type = .officeOpenXML
        case "doc": type = .docFormat
        case "odt": type = .openDocument
        case "rtf": type = .rtf
        case "rtfd": type = .rtfd
        case "html", "htm": type = .html
        default: type = nil
        }
        guard let type else { return nil }
        // HTML 导入走 WebKit,必须在主线程;其它格式在主线程做也只是毫秒级
        let work = { () -> NSAttributedString? in
            try? NSAttributedString(url: src, options: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue],
                                    documentAttributes: nil)
        }
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    static func renderNative(_ src: URL, ext: String, to out: URL) -> Bool {
        guard let s = attributedString(src, ext: ext), s.length > 0 else { return false }
        return renderAttributedPDF(s, to: out)
    }

    /// 富文本 → A4 PDF。用 TextKit(而不是 CoreText 直排):表格(NSTextTable)、内嵌图片(附件)都能正确分页绘制
    static func renderAttributedPDF(_ s: NSAttributedString, to url: URL,
                                    page: CGSize = CGSize(width: 595.28, height: 841.89), margin: CGFloat = 54) -> Bool {
        // 深色文字默认值:docx 里没写颜色的段落在某些系统外观下会被当成「标签色」(深色模式下是白色)
        let m = NSMutableAttributedString(attributedString: s)
        m.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: m.length)) { v, r, _ in
            if v == nil { m.addAttribute(.foregroundColor, value: NSColor.black, range: r) }
        }
        let storage = NSTextStorage(attributedString: m)
        let lm = NSLayoutManager()
        lm.allowsNonContiguousLayout = false
        storage.addLayoutManager(lm)
        let size = CGSize(width: page.width - margin * 2, height: page.height - margin * 2)
        var containers: [NSTextContainer] = []
        repeat {
            let c = NSTextContainer(size: size)
            c.lineFragmentPadding = 0
            lm.addTextContainer(c)
            containers.append(c)
            _ = lm.glyphRange(for: c)        // 触发这一页的排版
            let laid = NSMaxRange(lm.glyphRange(for: c))
            if laid >= lm.numberOfGlyphs { break }
            if lm.glyphRange(for: c).length == 0 { break }      // 一页都放不下(超大图片):防死循环
        } while containers.count < 2000

        var box = CGRect(origin: .zero, size: page)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        let prev = NSGraphicsContext.current
        defer { NSGraphicsContext.current = prev }
        for c in containers {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // TextKit 用翻转坐标系画
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let g = lm.glyphRange(for: c)
            let origin = CGPoint(x: margin, y: margin)
            lm.drawBackground(forGlyphRange: g, at: origin)
            lm.drawGlyphs(forGlyphRange: g, at: origin)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return !containers.isEmpty
    }
}
