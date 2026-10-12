import Cocoa
import CryptoKit
import Foundation
import ImageIO

/// #8 剪贴板历史:默认关闭;轮询 changeCount,跳过自身写入与 ConcealedType/远端剪贴板标记。
/// 支持文字/图片/文件三类;内存存储,可选持久化(图片落盘为 PNG);
/// 菜单栏「剪贴板历史」子菜单提供 粘贴/仅复制/追加/置顶。
final class ClipboardHistory {
    static let shared = ClipboardHistory()

    enum Kind: String { case text, image, files }

    /// persist=false 持内存 Data;persist=true 只持磁盘 URL
    enum ImageBlob {
        case data(Data)
        case file(URL)

        var bytes: Data? {
            switch self {
            case .data(let d): return d
            case .file(let u): return try? Data(contentsOf: u)
            }
        }
    }

    enum Payload {
        case text(String)
        case image(ImageBlob, pixelSize: CGSize, byteCount: Int, hash: String)
        case files([URL])
    }

    struct Item {
        let id: UUID
        var payload: Payload
        let time: Date
        var pinned: Bool
        var thumbnail: NSImage?
        /// 单张超过 imageMaxMB 被按比例缩小过
        var downscaled = false
    }

    /// pick 结果:kind=采集主类型;skip=主类型被禁用/敏感标记,整次跳过;none=无可采集类型
    enum Pick: Equatable {
        case kind(Kind)
        case skip
        case none
    }

    private(set) var items: [Item] = []
    private var timer: Timer?
    private var lastChangeCount = -1
    /// 图片数据拉取/重编码/缩略图:串行队列保证同一时刻最多一个阻塞中的读
    private let queue = DispatchQueue(label: "popbar.cliphist", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private var prevEnabled = false
    private var prevPersist = false

    static let maxItems = 10
    static let maxPinned = 5

    private init() {}

    // MARK: - 纯逻辑(可测,不碰 NSPasteboard)

    /// 主类型判定:文件 > 图片 > 文字;敏感/远端标记整次跳过
    static func pick(types: [String], images: Bool, files: Bool) -> Pick {
        if types.contains("com.apple.is-remote-clipboard") { return .skip }
        if types.contains(where: { $0.contains("ConcealedType") || $0.contains("TransientType") }) {
            return .skip
        }
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            return files ? .kind(.files) : .skip
        }
        if types.contains(NSPasteboard.PasteboardType.png.rawValue)
            || types.contains(NSPasteboard.PasteboardType.tiff.rawValue) {
            return images ? .kind(.image) : .skip
        }
        if types.contains(NSPasteboard.PasteboardType.string.rawValue) { return .kind(.text) }
        return .none
    }

    /// 先按条数(超 min(limit,10) 从尾部淘汰最旧非置顶),再按图片总字节
    /// (超预算从尾部淘汰最旧非置顶图片条目);置顶永不淘汰
    static func evict(_ items: [Item], limit: Int, imageBudgetBytes: Int) -> [Item] {
        var out = items
        let cap = min(max(limit, 1), maxItems)
        while out.count > cap, let i = out.lastIndex(where: { !$0.pinned }) {
            out.remove(at: i)
        }
        func imageBytes() -> Int {
            out.reduce(0) { s, it in
                if case .image(_, _, let bytes, _) = it.payload { return s + bytes }
                return s
            }
        }
        while imageBytes() > imageBudgetBytes,
              let i = out.lastIndex(where: { !$0.pinned && isImage($0) }) {
            out.remove(at: i)
        }
        return out
    }

    private static func isImage(_ it: Item) -> Bool {
        if case .image = it.payload { return true }
        return false
    }

    /// 稳定哈希(persist 重启后仍可比对;hashValue 每进程随机不可用)
    static func stableHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 去重:text 比字符串;image 比 pixelSize+byteCount+hash;files 比 URL 数组
    static func isDuplicate(_ a: Payload, _ b: Payload) -> Bool {
        switch (a, b) {
        case (.text(let x), .text(let y)): return x == y
        case (.image(_, let s1, let b1, let h1), .image(_, let s2, let b2, let h2)):
            return s1 == s2 && b1 == b2 && h1 == h2
        case (.files(let x), .files(let y)): return x == y
        default: return false
        }
    }

    /// 新格式 {type,time,pinned,...};旧格式缺 type 按 text。图片 file 为相对文件名
    static func decode(_ json: Any, dir: URL) -> [Item] {
        guard let arr = json as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            func time() -> Date? {
                if let t = d["time"] as? Double { return Date(timeIntervalSince1970: t) }
                if let t = (d["time"] as? String).flatMap(Double.init) {
                    return Date(timeIntervalSince1970: t)
                }
                return nil
            }
            guard let t = time() else { return nil }
            let pinned = d["pinned"] as? Bool ?? false
            let type = d["type"] as? String ?? "text"
            var item = Item(id: UUID(), payload: .text(""), time: t, pinned: pinned, thumbnail: nil)
            switch type {
            case "image":
                guard let name = d["file"] as? String,
                      let w = d["w"] as? Double, let h = d["h"] as? Double else { return nil }
                let url = dir.appendingPathComponent(name)
                item.payload = .image(.file(url), pixelSize: CGSize(width: w, height: h),
                                      byteCount: d["bytes"] as? Int ?? 0,
                                      hash: d["hash"] as? String ?? "")
                item.thumbnail = Self.thumbnail(url)
            case "files":
                let urls = ((d["urls"] as? [String]) ?? []).compactMap { URL(string: $0) }
                guard !urls.isEmpty else { return nil }
                item.payload = .files(urls)
            default:
                guard let s = d["text"] as? String else { return nil }
                item.payload = .text(s)
            }
            return item
        }
    }

    static func encode(_ items: [Item]) -> [[String: Any]] {
        items.map { it in
            var d: [String: Any] = [
                "time": it.time.timeIntervalSince1970,
                "pinned": it.pinned,
            ]
            switch it.payload {
            case .text(let s):
                d["type"] = Kind.text.rawValue
                d["text"] = s
            case .image(let blob, let size, let bytes, let hash):
                d["type"] = Kind.image.rawValue
                if case .file(let url) = blob { d["file"] = url.lastPathComponent }
                d["w"] = Double(size.width)
                d["h"] = Double(size.height)
                d["bytes"] = bytes
                d["hash"] = hash
            case .files(let urls):
                d["type"] = Kind.files.rawValue
                d["urls"] = urls.map { $0.absoluteString }
            }
            return d
        }
    }

    // MARK: - 配置启停

    /// 配置变化时调用;enabled=false 停止轮询并清理内存与磁盘
    func applyConfig() {
        let cfg = ConfigStore.shared.config.clipboardHistory
        if cfg.enabled, timer == nil {
            lastChangeCount = NSPasteboard.general.changeCount
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.poll()
            }
            timer?.tolerance = 0.2
            if cfg.persist { load() }
        } else if !cfg.enabled {
            timer?.invalidate()
            timer = nil
            if prevEnabled || !items.isEmpty {
                items.removeAll()
                pendingSave?.cancel()
                deleteDisk()
            }
        }
        if cfg.enabled {
            if cfg.persist, !prevPersist {
                materializeImages()    // 关→开:内存图片立即写盘并保存
                save()
            } else if !cfg.persist, prevPersist {
                dematerializeImages()  // 开→关:读回内存,删磁盘
                items = Self.evict(items, limit: cfg.limit,
                                   imageBudgetBytes: cfg.imageSizeMB * 1024 * 1024)
                deleteDisk()
            }
        }
        prevEnabled = cfg.enabled
        prevPersist = cfg.persist
    }

    private func poll() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc
        guard !PasteboardGuard.isOwnChange(cc) else { return }
        let cfg = ConfigStore.shared.config.clipboardHistory
        let typeStrs = (pb.types ?? []).map { $0.rawValue }
        switch Self.pick(types: typeStrs, images: cfg.images, files: cfg.files) {
        case .none, .skip:
            return
        case .kind(.text):
            guard let text = pb.string(forType: .string)?.trimmingCharacters(
                in: .whitespacesAndNewlines), !text.isEmpty else { return }
            insert(.text(text), expectedChange: cc)
        case .kind(.files):
            let urls = (pb.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard !urls.isEmpty else { return }
            insert(.files(urls), expectedChange: cc)
        case .kind(.image):
            let maxBytes = max(cfg.imageMaxMB, 1) * 1024 * 1024
            queue.async { [weak self] in self?.fetchImage(cc: cc, maxBytes: maxBytes) }
        }
    }

    /// 后台线程:拉图片数据 → tiff 转 png → 超限缩小 → 缩略图 → 回主线程入库
    private func fetchImage(cc: Int, maxBytes: Int) {
        let pb = NSPasteboard.general
        var data = pb.data(forType: .png)
        if data == nil, let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let png = data,
              let prepared = Self.prepareImage(png, maxBytes: maxBytes) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.insert(.image(.data(prepared.png), pixelSize: prepared.size,
                                byteCount: prepared.png.count,
                                hash: Self.stableHash(prepared.png)),
                         expectedChange: cc, thumbnail: prepared.thumbnail,
                         downscaled: prepared.downscaled)
        }
    }

    /// png 解码尺寸/缩略图/超限缩小;返回 nil 表示不可用或仍超限
    static func prepareImage(_ data: Data, maxBytes: Int) -> (png: Data, size: CGSize,
                                                            thumbnail: NSImage?,
                                                            downscaled: Bool)? {
        var png = data
        guard var src = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        var size = Self.pixelSize(src) ?? .zero
        var downscaled = false
        if png.count > maxBytes, let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let long = CGFloat(max(cg.width, cg.height))
            let scale = min(1, 4096 / max(long, 1))
            let w = max(1, Int((CGFloat(cg.width) * scale).rounded()))
            let h = max(1, Int((CGFloat(cg.height) * scale).rounded()))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let repData = { () -> Data? in
                      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                      guard let small = ctx.makeImage() else { return nil }
                      return NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:])
                  }(), repData.count <= maxBytes,
                  let newSrc = CGImageSourceCreateWithData(repData as CFData, nil) else { return nil }
            png = repData
            src = newSrc
            size = CGSize(width: w, height: h)
            downscaled = true
        }
        return (png, size, Self.thumbnail(src), downscaled)
    }

    private static func pixelSize(_ src: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 缩略图 maxPixel 64、显示高 32pt(同 SnapHistory)
    static func thumbnail(_ src: CGImageSource) -> NSImage? {
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let aspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
        return NSImage(cgImage: cg, size: CGSize(width: 32 * aspect, height: 32))
    }

    static func thumbnail(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(src)
    }

    /// FR-8:自身「用户意图写入」的显式入库(如截屏复制);开关由历史模块自己判断
    func recordImageData(_ data: Data) {
        let cfg = ConfigStore.shared.config.clipboardHistory
        guard cfg.enabled, cfg.images else { return }
        let maxBytes = max(cfg.imageMaxMB, 1) * 1024 * 1024
        queue.async { [weak self] in
            guard let prepared = Self.prepareImage(data, maxBytes: maxBytes) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.insert(.image(.data(prepared.png), pixelSize: prepared.size,
                                    byteCount: prepared.png.count,
                                    hash: Self.stableHash(prepared.png)),
                             thumbnail: prepared.thumbnail, downscaled: prepared.downscaled)
            }
        }
    }

    /// 入库:去重(仅与最新一条)→ insert at 0 → evict → persist 写盘 → 节流 save → 通知
    private func insert(_ payload: Payload, expectedChange cc: Int? = nil,
                        thumbnail: NSImage? = nil, downscaled: Bool = false) {
        if let cc, NSPasteboard.general.changeCount != cc { return }
        if let first = items.first, Self.isDuplicate(first.payload, payload) { return }
        let item = Item(id: UUID(), payload: payload, time: Date(),
                        pinned: false, thumbnail: thumbnail, downscaled: downscaled)
        let cfg = ConfigStore.shared.config.clipboardHistory
        var new = items
        new.insert(item, at: 0)
        var evicted = Self.evict(new, limit: cfg.limit,
                                 imageBudgetBytes: cfg.imageSizeMB * 1024 * 1024)
        guard let ni = evicted.firstIndex(where: { $0.id == item.id }) else {
            // 普通图片被淘汰完仍超预算(或条数被置顶占满):拒绝入库
            NSSound.beep()
            return
        }
        if cfg.persist, case .image(let blob, let size, let bytes, let hash) = evicted[ni].payload,
           case .data(let d) = blob {
            evicted[ni].payload = .image(.file(writeImage(d, id: item.id)), pixelSize: size,
                                         byteCount: bytes, hash: hash)
        }
        removeImageFiles(of: new, notIn: evicted)
        items = evicted
        scheduleSave()
        NotificationCenter.default.post(name: .init("PopBarClipboardHistoryChanged"), object: nil)
    }

    // MARK: - 菜单动作

    /// 写回剪贴板(不新增、不重排)
    private func writeBack(_ item: Item) {
        switch item.payload {
        case .text(let s):
            PasteboardGuard.write(s)
        case .image(let blob, _, _, _):
            guard let data = blob.bytes else { return }
            let pbi = NSPasteboardItem()
            pbi.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation {
                pbi.setData(tiff, forType: .tiff)
            }
            PasteboardGuard.write(items: [pbi])
        case .files(let urls):
            PasteboardGuard.write(urls: urls)
        }
    }

    /// 粘贴某条:写回剪贴板 → 模拟 ⌘V
    func paste(_ item: Item) {
        writeBack(item)
        FloatingBarController.shared.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Actions.postKeyCombo(key: 9)   // kVK_ANSI_V
        }
    }

    /// 追加到当前剪贴板(仅文字)
    func append(_ item: Item) {
        guard case .text(let s) = item.payload else { return }
        let cur = NSPasteboard.general.string(forType: .string) ?? ""
        PasteboardGuard.write(cur.isEmpty ? s : cur + "\n" + s)
    }

    private func togglePin(_ item: Item) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        if !items[i].pinned,
           items.filter({ $0.pinned }).count >= Self.maxPinned {
            NSSound.beep()
            return
        }
        items[i].pinned.toggle()
        scheduleSave()
        NotificationCenter.default.post(name: .init("PopBarClipboardHistoryChanged"), object: nil)
    }

    /// 清空历史(保留置顶)
    func clear() {
        let removed = items.filter { !$0.pinned }
        for it in removed { deleteImageFile(it) }
        items = items.filter { $0.pinned }
        scheduleSave()
        NotificationCenter.default.post(name: .init("PopBarClipboardHistoryChanged"), object: nil)
    }

    /// 清空全部(含置顶)
    func clearAll() {
        for it in items { deleteImageFile(it) }
        items.removeAll()
        scheduleSave()
        NotificationCenter.default.post(name: .init("PopBarClipboardHistoryChanged"), object: nil)
    }

    // MARK: - 持久化

    /// 图片目录:Application Support/PopBar/ClipboardHistory(0700)
    private var dir: URL {
        PopBarConfig.directoryURL.appendingPathComponent("ClipboardHistory", isDirectory: true)
    }

    /// 索引文件保持在配置根目录(与旧格式同位置)
    private var fileURL: URL {
        PopBarConfig.directoryURL.appendingPathComponent("clipboard-history.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) else { return }
        items = Self.decode(json, dir: dir)
        let cfg = ConfigStore.shared.config.clipboardHistory
        items = Self.evict(items, limit: cfg.limit,
                           imageBudgetBytes: cfg.imageSizeMB * 1024 * 1024)
    }

    private func writeImage(_ data: Data, id: UUID) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let url = dir.appendingPathComponent("\(id.uuidString).png")
        try? data.write(to: url)
        return url
    }

    /// persist 开:把所有 .data blob 落成 .file
    private func materializeImages() {
        for i in items.indices {
            if case .image(let blob, let size, let bytes, let hash) = items[i].payload,
               case .data(let d) = blob {
                items[i].payload = .image(.file(writeImage(d, id: items[i].id)),
                                          pixelSize: size, byteCount: bytes, hash: hash)
            }
        }
    }

    /// persist 关:把 .file blob 读回 .data
    private func dematerializeImages() {
        for i in items.indices {
            if case .image(let blob, let size, let bytes, let hash) = items[i].payload,
               case .file(let url) = blob, let d = try? Data(contentsOf: url) {
                items[i].payload = .image(.data(d), pixelSize: size,
                                          byteCount: bytes, hash: hash)
            }
        }
    }

    private func deleteImageFile(_ item: Item) {
        if case .image(let blob, _, _, _) = item.payload,
           case .file(let url) = blob {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func removeImageFiles(of before: [Item], notIn after: [Item]) {
        let kept = Set(after.map { $0.id })
        for it in before where !kept.contains(it.id) { deleteImageFile(it) }
    }

    /// enabled 关 / persist 关:删除索引与图片目录
    private func deleteDisk() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: dir)
    }

    /// 节流写盘(≤1 次/秒),取消重排
    private func scheduleSave() {
        guard ConfigStore.shared.config.clipboardHistory.persist else { return }
        pendingSave?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    func save() {
        guard ConfigStore.shared.config.clipboardHistory.persist else { return }
        materializeImages()
        let arr = Self.encode(items)
        if let data = try? JSONSerialization.data(withJSONObject: arr) {
            try? data.write(to: fileURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: fileURL.path)
        }
    }

    // MARK: - 菜单构建

    /// 状态栏菜单子项;enabled=false 时返回 nil
    func menuItem() -> NSMenuItem? {
        guard ConfigStore.shared.config.clipboardHistory.enabled else { return nil }
        let top = NSMenuItem(title: L10n.t("剪贴板历史", "Clipboard History"),
                             action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if items.isEmpty {
            let e = NSMenuItem(title: L10n.t("(空)", "(empty)"), action: nil, keyEquivalent: "")
            e.isEnabled = false
            sub.addItem(e)
        } else {
            let pinned = items.filter { $0.pinned }
            let normal = items.filter { !$0.pinned }
            for it in pinned { sub.addItem(entryItem(it)) }
            if !pinned.isEmpty && !normal.isEmpty { sub.addItem(.separator()) }
            for it in normal { sub.addItem(entryItem(it)) }
            sub.addItem(.separator())
            sub.addItem(dispatchItem(L10n.t("清空历史", "Clear History")) { [weak self] in
                self?.clear()
            })
            if !pinned.isEmpty {
                sub.addItem(dispatchItem(
                    L10n.t("清空全部(含置顶)", "Clear All (incl. Pinned)")) { [weak self] in
                    self?.clearAll()
                })
            }
        }
        top.submenu = sub
        return top
    }

    private func dispatchItem(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(MenuDispatch.run(_:)),
                            keyEquivalent: "")
        mi.target = MenuDispatch.shared
        mi.representedObject = MenuDispatch.register(run)
        return mi
    }

    /// 单条历史:图标/缩略图 + 标题 + 子菜单(粘贴/仅复制/追加/置顶)
    private func entryItem(_ item: Item) -> NSMenuItem {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let title: String
        var icon: NSImage?
        var isText = false
        switch item.payload {
        case .text(let s):
            isText = true
            title = String(s.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(60))
            icon = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
            icon?.size = NSSize(width: 32, height: 32)
        case .image(_, let size, _, _):
            title = "\(fmt.string(from: item.time)) · \(Int(size.width))×\(Int(size.height))"
                + (item.downscaled ? L10n.t("(已缩小)", "(downscaled)") : "")
            icon = item.thumbnail
        case .files(let urls):
            title = urls.count == 1 ? urls[0].lastPathComponent
                : L10n.t("\(urls.count) 个项目", "\(urls.count) items")
            icon = NSWorkspace.shared.icon(forFile: urls[0].path)
            icon?.size = NSSize(width: 32, height: 32)
        }
        let mi = NSMenuItem(title: (item.pinned ? "📌 " : "") + title,
                            action: nil, keyEquivalent: "")
        mi.image = icon
        let actions = NSMenu()
        actions.addItem(dispatchItem(L10n.t("粘贴", "Paste")) { [weak self] in
            self?.paste(item)
        })
        actions.addItem(dispatchItem(L10n.t("仅复制", "Copy Only")) { [weak self] in
            self?.writeBack(item)
        })
        if isText {
            actions.addItem(dispatchItem(L10n.t("追加", "Append")) { [weak self] in
                self?.append(item)
            })
        }
        actions.addItem(dispatchItem(
            item.pinned ? L10n.t("取消置顶", "Unpin") : L10n.t("置顶", "Pin")) { [weak self] in
            self?.togglePin(item)
        })
        mi.submenu = actions
        return mi
    }
}
