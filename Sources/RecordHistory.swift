import Cocoa
import QuickLookThumbnailing

struct RecordEntry: Codable, Equatable {
    var path: String
    var createdAt: Double
    var duration: Double
    var bytes: Int64
    /// GIF 导出产物,也算一条录制记录
    var isGIF: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// 「最近录制」:只存路径元数据,文件被删则条目自动清理(M3 FR-21)
@MainActor
final class RecordHistory {
    static let shared = RecordHistory()
    static let limit = 10
    static let didChange = Notification.Name("PopBarRecordHistoryChanged")

    private(set) var entries: [RecordEntry] = []

    static var fileURL: URL { PopBarConfig.directoryURL.appendingPathComponent("recordings.json") }

    private init() { load() }

    func add(url: URL, duration: Double, isGIF: Bool = false) {
        let e = RecordEntry(path: url.path, createdAt: Date().timeIntervalSince1970,
                            duration: duration, bytes: RecordUtil.fileSize(url), isGIF: isGIF)
        entries.removeAll { $0.path == e.path }
        entries.insert(e, at: 0)
        prune()
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func remove(path: String) {
        entries.removeAll { $0.path == path }
        save()
        RecordDataStore.remove(for: URL(fileURLWithPath: path))
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// 文件已不在磁盘上的条目直接丢弃,顺手清掉对应的旁挂数据目录
    func prune() {
        let before = entries.count
        entries = entries.filter { $0.exists }
        if entries.count > Self.limit { entries = Array(entries.prefix(Self.limit)) }
        if entries.count != before { save() }
        RecordDataStore.pruneOrphans()
    }

    func clear() {
        entries = []
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: PopBarConfig.directoryURL, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// 损坏时静默重建
    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let list = try? JSONDecoder().decode([RecordEntry].self, from: data) else {
            entries = []
            return
        }
        entries = list
        prune()
    }

    // MARK: - 菜单

    func menuItem() -> NSMenuItem? {
        prune()
        guard !entries.isEmpty else { return nil }
        let sub = NSMenu()
        for e in entries {
            let item = NSMenuItem(title: title(e), action: nil, keyEquivalent: "")
            item.image = Self.placeholderIcon(e)
            item.representedObject = e.path
            let actions = NSMenu()
            for (title, sel) in [
                (L10n.t("播放", "Play"), #selector(RecordMenuActions.open(_:))),
                (L10n.t("编辑并导出…", "Edit & Export…"), #selector(RecordMenuActions.exportVideo(_:))),
                (L10n.t("导出 GIF…", "Export GIF…"), #selector(RecordMenuActions.exportGIF(_:))),
                (L10n.t("在 Finder 中显示", "Show in Finder"), #selector(RecordMenuActions.reveal(_:))),
                (L10n.t("复制路径", "Copy Path"), #selector(RecordMenuActions.copyPath(_:))),
                (L10n.t("复制文件", "Copy File"), #selector(RecordMenuActions.copyFile(_:))),
                (L10n.t("删除", "Delete"), #selector(RecordMenuActions.trash(_:))),
            ] {
                let a = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                a.target = RecordMenuActions.shared
                a.representedObject = e.path
                actions.addItem(a)
            }
            item.submenu = actions
            sub.addItem(item)
            Self.loadThumbnail(e.url) { image in
                guard let image else { return }
                item.image = image
            }
        }
        sub.addItem(.separator())
        let clearItem = NSMenuItem(title: L10n.t("清空列表", "Clear List"),
                                   action: #selector(RecordMenuActions.clearList), keyEquivalent: "")
        clearItem.target = RecordMenuActions.shared
        sub.addItem(clearItem)
        let root = NSMenuItem(title: L10n.t("最近录制", "Recent Recordings"), action: nil, keyEquivalent: "")
        root.submenu = sub
        return root
    }

    private func title(_ e: RecordEntry) -> String {
        let name = e.url.lastPathComponent
        let dur = RecordUtil.durationText(e.duration)
        return "\(name) · \(dur) · \(RecordUtil.byteText(e.bytes))"
    }

    private static func placeholderIcon(_ e: RecordEntry) -> NSImage? {
        let symbol = e.isGIF ? "photo" : "film"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        img?.size = NSSize(width: 16, height: 16)
        return img
    }

    /// 缩略图异步补上,生成前显示符号图标
    private static func loadThumbnail(_ url: URL, done: @escaping (NSImage?) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumb, _ in
            guard let cg = thumb?.cgImage else { return done(nil) }
            let aspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
            let image = NSImage(cgImage: cg, size: CGSize(width: 32 * aspect, height: 32))
            DispatchQueue.main.async { done(image) }
        }
    }
}

final class RecordMenuActions: NSObject {
    static let shared = RecordMenuActions()

    private func url(_ item: NSMenuItem) -> URL? {
        guard let p = item.representedObject as? String else { return nil }
        return URL(fileURLWithPath: p)
    }

    @objc func open(_ item: NSMenuItem) {
        guard let u = url(item) else { return }
        NSWorkspace.shared.open(u)
    }

    @objc func reveal(_ item: NSMenuItem) {
        guard let u = url(item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    @objc func copyPath(_ item: NSMenuItem) {
        guard let p = item.representedObject as? String else { return }
        PasteboardGuard.write(p)
    }

    @objc func copyFile(_ item: NSMenuItem) {
        guard let u = url(item) else { return }
        PasteboardGuard.write(urls: [u])
    }

    /// 删除走废纸篓,不直接 rm
    @objc func trash(_ item: NSMenuItem) {
        guard let u = url(item) else { return }
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: u, resultingItemURL: &trashed)
        } catch {
            NSSound.beep()
            return
        }
        Task { @MainActor in RecordHistory.shared.remove(path: u.path) }
    }

    @objc func exportGIF(_ item: NSMenuItem) {
        guard let u = url(item) else { return }
        Task { @MainActor in GIFExportController.shared.show(url: u) }
    }

    /// 统一导出面板:裁剪 / 压缩 / 涟漪 / 摄像头 / 水印(FR-36)
    @objc func exportVideo(_ item: NSMenuItem) {
        guard let u = url(item) else { return }
        Task { @MainActor in RecordExportController.shared.show(url: u) }
    }

    @objc func clearList() {
        Task { @MainActor in RecordHistory.shared.clear() }
    }
}
