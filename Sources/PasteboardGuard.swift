import Cocoa

/// 统一封装 PopBar 对系统剪贴板的写入,并记录由自己产生的 changeCount。
/// 剪贴板历史(#8)用它排除自身写入(⌘C 降级取词、还原、复制、替换)。
enum PasteboardGuard {
    /// 最近产生的自身写入 changeCount;容量有限,够用即可
    private static var ownChanges: [Int] = []
    private static let cap = 32

    static func declareOwn(_ count: Int? = nil) {
        let c = count ?? NSPasteboard.general.changeCount
        ownChanges.append(c)
        if ownChanges.count > cap { ownChanges.removeFirst(ownChanges.count - cap) }
    }

    static func isOwnChange(_ count: Int) -> Bool { ownChanges.contains(count) }

    /// 写入纯文本并登记 changeCount
    static func write(_ text: String, to pb: NSPasteboard = .general) {
        pb.clearContents()
        pb.setString(text, forType: .string)
        declareOwn(pb.changeCount)
    }

    /// 写入富文本/多类型并登记(二维码「复制图片」等多类型剪贴板用);
    /// record=true 表示「用户意图写入」(如截屏复制),同时入剪贴板历史
    static func write(items: [NSPasteboardItem], to pb: NSPasteboard = .general,
                      record: Bool = false) {
        pb.clearContents()
        pb.writeObjects(items)
        declareOwn(pb.changeCount)
        if record, let png = items.lazy.compactMap({ $0.data(forType: .png) }).first {
            ClipboardHistory.shared.recordImageData(png)
        }
    }

    /// 写入文件 URL 列表并登记(剪贴板历史「粘贴文件」用)
    static func write(urls: [URL], to pb: NSPasteboard = .general) {
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        declareOwn(pb.changeCount)
    }

    /// ⌘C 兜底取词与还原都会产生写入,集中登记
    static func snapshot(_ pb: NSPasteboard) -> [[String: Data]] {
        SelectionService.snapshotPasteboard(pb)
    }

    static func restore(_ pb: NSPasteboard, _ snapshot: [[String: Data]]) {
        SelectionService.restorePasteboard(pb, snapshot)
        declareOwn(pb.changeCount)
    }
}
