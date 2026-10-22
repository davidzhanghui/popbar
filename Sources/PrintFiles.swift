import Cocoa
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import CoreText

/// 待打印文件的准备:magic 嗅探 → 暂存 → (HEIC/WebP 转换、文本转 PDF)→ 页数 → 缩略图。
///
/// 判断文件类型只认 magic bytes,不信扩展名:docx 改名成 .pdf 会被拒,
/// 不会让 CUPS 过滤器崩在半路。页数与缩略图用系统 PDFKit,不再依赖 poppler。
enum PrintFileKind: String, Codable { case pdf, image, heic, webp, text }

struct PrintSniff: Equatable {
    var kind: PrintFileKind
    var mime: String
    var ext: String
}

/// 准备好、可以提交的文件(位于暂存区)
struct PreparedFile: Identifiable, Equatable {
    var id: String                 // token
    var displayName: String        // 原文件名(用于作业标题)
    var url: URL                   // 实际提交的文件(转换后的)
    var mime: String               // 提交时的 MIME
    var originalMime: String
    var kind: PrintFileKind        // 转换后的类别(heic/webp 已变 image,text 已变 pdf)
    var size: Int
    var pages: Int?
    var warnings: [String] = []
}

enum PrintFiles {
    static let maxBytes = 200 * 1024 * 1024

    // MARK: - magic 嗅探

    static func sniff(_ head: Data) -> PrintSniff? {
        let b = [UInt8](head.prefix(8192))
        func starts(_ bytes: [UInt8], at o: Int = 0) -> Bool {
            b.count >= o + bytes.count && Array(b[o..<o + bytes.count]) == bytes
        }
        func ascii(_ r: Range<Int>) -> String {
            guard b.count >= r.upperBound else { return "" }
            return String(decoding: b[r], as: UTF8.self)
        }
        if starts([0x25, 0x50, 0x44, 0x46, 0x2d]) { return .init(kind: .pdf, mime: "application/pdf", ext: "pdf") }
        if starts([0xff, 0xd8, 0xff]) { return .init(kind: .image, mime: "image/jpeg", ext: "jpg") }
        if starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return .init(kind: .image, mime: "image/png", ext: "png") }
        if starts([0x47, 0x49, 0x46, 0x38]) { return .init(kind: .image, mime: "image/gif", ext: "gif") }
        if starts([0x49, 0x49, 0x2a, 0x00]) || starts([0x4d, 0x4d, 0x00, 0x2a]) { return .init(kind: .image, mime: "image/tiff", ext: "tiff") }
        if starts([0x42, 0x4d]) { return .init(kind: .image, mime: "image/bmp", ext: "bmp") }
        if starts([0x52, 0x49, 0x46, 0x46]) && ascii(8..<12) == "WEBP" { return .init(kind: .webp, mime: "image/webp", ext: "webp") }
        if ascii(4..<8) == "ftyp" {
            let brand = ascii(8..<12)
            if ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(brand) {
                return .init(kind: .heic, mime: "image/heic", ext: "heic")
            }
        }
        // 纯文本:没有 NUL 字节,控制字符占比极低(UTF-8 / GBK / UTF-16 带 BOM 之外的常见编码都能过)
        if !b.isEmpty, !b.contains(0) {
            let ctrl = b.filter { $0 < 32 && ![9, 10, 12, 13, 27].contains($0) }.count
            if ctrl * 100 < b.count { return .init(kind: .text, mime: "text/plain", ext: "txt") }
        }
        return nil
    }

    // MARK: - 准备

    static func prepare(_ source: URL, staging: URL = PrintStorage.stagingDir) -> Result<PreparedFile, PrintError> {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: source.path), let size = (attrs[.size] as? NSNumber)?.intValue else {
            return .failure(.message(L10n.t("无法读取文件", "Cannot read the file")))
        }
        if size == 0 { return .failure(.message(L10n.t("文件是空的", "The file is empty"))) }
        if size > maxBytes {
            return .failure(.message(L10n.t("文件超过 \(maxBytes >> 20) MB 上限", "File exceeds the \(maxBytes >> 20) MB limit")))
        }
        guard let fh = try? FileHandle(forReadingFrom: source) else {
            return .failure(.message(L10n.t("无法读取文件", "Cannot read the file")))
        }
        let head = (try? fh.read(upToCount: 8192)) ?? Data()
        try? fh.close()
        guard let sn = sniff(head) else {
            return .failure(.message(L10n.t("无法识别的文件类型(支持 PDF / JPG / PNG / GIF / TIFF / BMP / WEBP / HEIC / 纯文本)",
                                            "Unrecognized file type (PDF / JPG / PNG / GIF / TIFF / BMP / WEBP / HEIC / plain text)")))
        }

        try? fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let token = UUID().uuidString
        var url = staging.appendingPathComponent("\(token).\(sn.ext)")
        do { try fm.copyItem(at: source, to: url) } catch {
            return .failure(.message(L10n.t("复制文件失败:", "Copy failed: ") + error.localizedDescription))
        }
        var kind = sn.kind, mime = sn.mime
        var warnings: [String] = []

        // CUPS 的图片过滤器不认 HEIC / WebP:转成 JPEG / PNG
        if kind == .heic || kind == .webp {
            let asPNG = kind == .webp
            let out = staging.appendingPathComponent("\(token).\(asPNG ? "png" : "jpg")")
            if convertImage(url, to: out, png: asPNG) {
                try? fm.removeItem(at: url)
                url = out; kind = .image; mime = asPNG ? "image/png" : "image/jpeg"
            } else {
                warnings.append(L10n.t("图片格式转换失败,打印结果可能异常", "Image conversion failed; the print may look wrong"))
                kind = .image
            }
        }

        // 文本先转成 PDF:CUPS 的 text 过滤器对中文换行/宽度处理很差
        if kind == .text {
            let out = staging.appendingPathComponent("\(token).pdf")
            if let text = readText(url), renderTextPDF(text, to: out) {
                try? fm.removeItem(at: url)
                url = out; kind = .pdf; mime = "application/pdf"
            } else {
                warnings.append(L10n.t("文本转 PDF 失败,将按纯文本直接打印", "Text-to-PDF failed; printing as plain text"))
            }
        }

        var pages: Int? = nil
        switch kind {
        case .pdf:
            if let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 { pages = doc.pageCount }
            else { warnings.append(L10n.t("这个 PDF 读不出页数(可能已加密)", "Cannot read the page count (the PDF may be encrypted)")) }
        case .image: pages = 1
        case .text: pages = nil
        default: break
        }
        return .success(PreparedFile(id: token, displayName: source.lastPathComponent, url: url, mime: mime,
                                     originalMime: sn.mime, kind: kind, size: size, pages: pages, warnings: warnings))
    }

    /// 由一段选中文字生成待打印文件(划词打印)
    static func prepare(text: String, title: String, staging: URL = PrintStorage.stagingDir) -> Result<PreparedFile, PrintError> {
        let fm = FileManager.default
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let token = UUID().uuidString
        let out = staging.appendingPathComponent("\(token).pdf")
        guard renderTextPDF(text, to: out), let doc = PDFDocument(url: out) else {
            return .failure(.message(L10n.t("文本转 PDF 失败", "Text-to-PDF failed")))
        }
        let size = (try? fm.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        return .success(PreparedFile(id: token, displayName: title, url: out, mime: "application/pdf",
                                     originalMime: "text/plain", kind: .pdf, size: size, pages: doc.pageCount))
    }

    static func readText(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        if let s = String(data: d, encoding: .utf8) { return s }
        // 带 BOM 的 UTF-16 / GBK 常见于 Windows 文本
        if let s = String(data: d, encoding: .utf16) { return s }
        let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: d, encoding: String.Encoding(rawValue: gbk))
    }

    // MARK: - 转换

    static func convertImage(_ src: URL, to dst: URL, png: Bool, maxPixel: Int = 4000) -> Bool {
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil) else { return false }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,      // 按 EXIF 方向转正
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary),
              let d = CGImageDestinationCreateWithURL(dst as CFURL, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(d, img, png ? nil : [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(d)
    }

    /// 文本 → A4 PDF(CoreText 排版,中文字体自动回退,按页宽折行、自动分页)
    static func renderTextPDF(_ text: String, to url: URL) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = 2
        para.defaultTabInterval = 28
        // Tab 展开成空格,CoreText 对制表位的处理在 PDF 里不稳定
        let body = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
        let attr = NSAttributedString(string: body.isEmpty ? " " : body, attributes: [
            .font: font, .foregroundColor: NSColor.black, .paragraphStyle: para,
        ])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let frameRect = box.insetBy(dx: 56, dy: 56)
        var loc = 0
        let total = attr.length
        var pages = 0
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: loc, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let vis = CTFrameGetVisibleStringRange(frame)
            if vis.length == 0 { break }       // 一行也放不下:防死循环
            loc += vis.length
            pages += 1
        } while loc < total && pages < 2000
        ctx.closePDF()
        return pages > 0
    }

    // MARK: - 缩略图

    /// 指定页(从 1 起)的缩略图 PNG 数据;失败返回 nil。image 类只有第 1 页
    static func thumbnailPNG(for file: URL, kind: PrintFileKind, page: Int = 1, side: CGFloat = 260) -> Data? {
        let img: NSImage?
        if kind == .pdf {
            guard let doc = PDFDocument(url: file), page >= 1, page <= doc.pageCount, let p = doc.page(at: page - 1) else { return nil }
            img = p.thumbnail(of: NSSize(width: side, height: side * 1.5), for: .mediaBox)
        } else {
            guard let s = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(side * 2)] as CFDictionary) else { return nil }
            img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        }
        guard let tiff = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]), png.count > 0 else { return nil }
        return png
    }

    // MARK: - 快速渲染(页网格用)

    /// 渲染专用串行队列:CGPDFDocument 不保证多线程安全,而单页渲染只要几毫秒,串行足够快
    private static let renderQueue = DispatchQueue(label: "popbar.print.render", qos: .userInitiated)
    private static var docCache: [String: CGPDFDocument] = [:]   // 只在 renderQueue 上访问

    /// 指定页(从 1 起)渲染成 NSImage。每个文件只打开一次 PDF,直接画进位图,不经过 PNG 编解码。
    /// 失败(文件没了、页码越界)返回 nil,调用方要显示占位而不是一直转圈
    static func renderThumbnail(file: URL, kind: PrintFileKind, page: Int, side: CGFloat = 200) async -> NSImage? {
        await withCheckedContinuation { cont in
            renderQueue.async { cont.resume(returning: renderSync(file: file, kind: kind, page: page, side: side)) }
        }
    }

    /// 文件不再使用时释放缓存的 PDF 句柄
    static func forgetDocument(_ file: URL) {
        renderQueue.async { docCache[file.path] = nil }
    }

    private static func renderSync(file: URL, kind: PrintFileKind, page: Int, side: CGFloat) -> NSImage? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let scale = (NSScreen.main?.backingScaleFactor ?? 2)
        guard kind == .pdf else {
            guard let s = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(side * scale)] as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
        }
        let doc: CGPDFDocument
        if let d = docCache[file.path] { doc = d }
        else if let d = CGPDFDocument(file as CFURL) {
            if docCache.count > 4 { docCache.removeAll() }
            docCache[file.path] = d; doc = d
        } else { return nil }
        guard page >= 1, page <= doc.numberOfPages, let pg = doc.page(at: page) else { return nil }

        let box = pg.getBoxRect(.cropBox)
        let rot = pg.rotationAngle
        let swap = rot == 90 || rot == 270
        let pw = swap ? box.height : box.width, ph = swap ? box.width : box.height
        guard pw > 0, ph > 0 else { return nil }
        let f = min(side / pw, side * 1.5 / ph) * scale        // 像素 / 点
        let w = max(Int(pw * f), 1), h = max(Int(ph * f), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.concatenate(pg.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(pg)
        guard let img = ctx.makeImage() else { return nil }
        return NSImage(cgImage: img, size: NSSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale))
    }
}
