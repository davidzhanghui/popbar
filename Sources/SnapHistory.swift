import Cocoa
import ImageIO

/// 截图历史:默认关闭;PNG 存在 Application Support/PopBar/Snaps,文件名带 @Nx 记录缩放
enum SnapHistory {
    struct Entry {
        let url: URL
        let date: Date
        let scale: CGFloat
        let pixelSize: CGSize
    }

    static var dir: URL { PopBarConfig.directoryURL.appendingPathComponent("Snaps", isDirectory: true) }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    /// 按文件名(时间戳)倒序,返回超出 limit 的最旧文件
    static func toDelete(_ names: [String], limit: Int) -> [String] {
        let keep = min(max(limit, 1), 200)
        return Array(names.sorted(by: >).dropFirst(keep))
    }

    static func add(_ img: CGImage, scale: CGFloat) {
        let cfg = ConfigStore.shared.config.snap.history
        guard cfg.enabled else { return }
        let name = "\(formatter.string(from: Date()))@\(max(Int(scale.rounded()), 1))x.png"
        let dir = Self.dir
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent(name))
            }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".png") }
            for n in toDelete(names, limit: cfg.limit) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
        }
    }

    /// 最新在前
    static func entries() -> [Entry] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".png") }.sorted(by: >)
        return names.compactMap { n in
            let stamp = String(n.prefix { $0 != "@" })
            guard let date = formatter.date(from: stamp) else { return nil }
            let scaleText = n.drop { $0 != "@" }.dropFirst().prefix { $0 != "x" }
            let url = dir.appendingPathComponent(n)
            var size = CGSize.zero
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let pw = props[kCGImagePropertyPixelWidth] as? CGFloat, let ph = props[kCGImagePropertyPixelHeight] as? CGFloat {
                size = CGSize(width: pw, height: ph)
            }
            return Entry(url: url, date: date, scale: CGFloat(Int(scaleText) ?? 2), pixelSize: size)
        }
    }

    static func clear() {
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where n.hasSuffix(".png") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    // MARK: - 菜单

    /// 开启且有记录时返回「截图历史」子菜单项
    static func menuItem() -> NSMenuItem? {
        let cfg = ConfigStore.shared.config.snap.history
        guard cfg.enabled else { return nil }
        let list = Array(entries().prefix(min(max(cfg.limit, 1), 200)))
        guard !list.isEmpty else { return nil }
        let sub = NSMenu()
        let cal = Calendar.current
        let timeFmt = DateFormatter()
        for e in list {
            timeFmt.dateFormat = cal.isDateInToday(e.date) ? "HH:mm:ss" : "MM-dd HH:mm"
            let item = NSMenuItem(title: "\(timeFmt.string(from: e.date)) · \(Int(e.pixelSize.width))×\(Int(e.pixelSize.height))",
                                  action: nil, keyEquivalent: "")
            item.image = thumbnail(e.url)
            let actions = NSMenu()
            for (title, sel) in [(L10n.t("复制", "Copy"), #selector(HistoryActions.copy(_:))),
                                 (L10n.t("贴图", "Pin"), #selector(HistoryActions.pin(_:))),
                                 (L10n.t("在 Finder 中显示", "Show in Finder"), #selector(HistoryActions.reveal(_:)))] {
                let a = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                a.target = HistoryActions.shared
                a.representedObject = e
                actions.addItem(a)
            }
            item.submenu = actions
            sub.addItem(item)
        }
        sub.addItem(.separator())
        for (title, sel) in [(L10n.t("打开文件夹", "Open Folder"), #selector(HistoryActions.openFolder)),
                             (L10n.t("清空历史", "Clear History"), #selector(HistoryActions.clearAll))] {
            let a = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            a.target = HistoryActions.shared
            sub.addItem(a)
        }
        let root = NSMenuItem(title: L10n.t("截图历史", "Screenshot History"), action: nil, keyEquivalent: "")
        root.submenu = sub
        return root
    }

    private static func thumbnail(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
                  kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let aspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
        return NSImage(cgImage: cg, size: CGSize(width: 32 * aspect, height: 32))
    }

    final class HistoryActions: NSObject {
        static let shared = HistoryActions()

        private func entry(_ item: NSMenuItem) -> Entry? { item.representedObject as? Entry }

        private func load(_ e: Entry) -> CGImage? {
            NSImage(contentsOf: e.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        @objc func copy(_ item: NSMenuItem) {
            guard let e = entry(item), let img = load(e) else { return }
            SnapOutput.copy(img, scale: e.scale)
        }

        @objc func pin(_ item: NSMenuItem) {
            guard let e = entry(item), let img = load(e) else { return }
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
            var size = CGSize(width: CGFloat(img.width) / e.scale, height: CGFloat(img.height) / e.scale)
            let fit = min(screen.frame.width * 0.8 / size.width, screen.frame.height * 0.8 / size.height, 1)
            size = CGSize(width: size.width * fit, height: size.height * fit)
            let f = screen.frame
            SnapPinWindow.show(image: img, scale: e.scale, frame: CGRect(
                x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height))
        }

        @objc func reveal(_ item: NSMenuItem) {
            guard let e = entry(item) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([e.url])
        }

        @objc func openFolder() {
            try? FileManager.default.createDirectory(at: SnapHistory.dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(SnapHistory.dir)
        }

        @objc func clearAll() {
            let a = NSAlert()
            a.messageText = L10n.t("清空截图历史?", "Clear screenshot history?")
            a.informativeText = L10n.t("将删除历史目录中的所有截图,不可恢复。", "All screenshots in the history folder will be deleted permanently.")
            a.addButton(withTitle: L10n.t("清空", "Clear"))
            a.addButton(withTitle: L10n.t("取消", "Cancel"))
            NSApp.activateForUI()
            if a.runModal() == .alertFirstButtonReturn { SnapHistory.clear() }
        }
    }
}
