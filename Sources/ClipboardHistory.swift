import Cocoa
import Foundation

/// #8 剪贴板历史:默认关闭;轮询 changeCount,跳过自身写入与 ConcealedType 标记。
/// 内存存储,可选持久化;菜单栏「剪贴板历史」子菜单选择粘贴或追加。
final class ClipboardHistory {
    static let shared = ClipboardHistory()

    struct Item {
        let text: String
        let time: Date
        var pinned = false
    }

    private(set) var items: [Item] = []
    private var timer: Timer?
    private var lastChangeCount = -1

    private init() {}

    /// 配置变化时调用;enabled=false 完全停止轮询
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
            items.removeAll()
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc
        guard !PasteboardGuard.isOwnChange(cc) else { return }
        // 跳过密码管理器等标记的敏感内容
        if pb.types?.contains(where: { $0.rawValue.contains("ConcealedType")
                                      || $0.rawValue.contains("TransientType") }) == true {
            return
        }
        guard let text = pb.string(forType: .string)?.trimmingCharacters(
            in: .whitespacesAndNewlines), !text.isEmpty else { return }
        if items.first?.text == text { return }
        let limit = ConfigStore.shared.config.clipboardHistory.limit
        items.insert(Item(text: text, time: Date()), at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        NotificationCenter.default.post(name: .init("PopBarClipboardHistoryChanged"), object: nil)
    }

    /// 粘贴某条:写入剪贴板 → 模拟 ⌘V
    func paste(_ item: Item) {
        PasteboardGuard.write(item.text)
        FloatingBarController.shared.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Actions.postKeyCombo(key: 9)   // kVK_ANSI_V
        }
    }

    /// 追加到当前剪贴板(与现有内容拼接)
    func append(_ item: Item) {
        let cur = NSPasteboard.general.string(forType: .string) ?? ""
        PasteboardGuard.write(cur.isEmpty ? item.text : cur + "\n" + item.text)
    }

    func clear() {
        items.removeAll()
        NotificationCenter.default.post(name: .init("PopBarClipboardHistoryChanged"), object: nil)
    }

    // MARK: - 可选持久化

    private var fileURL: URL {
        PopBarConfig.directoryURL.appendingPathComponent("clipboard-history.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return }
        items = arr.compactMap { d in
            guard let t = d["text"], let ts = d["time"].flatMap(Double.init) else { return nil }
            return Item(text: t, time: Date(timeIntervalSince1970: ts))
        }
    }

    func save() {
        guard ConfigStore.shared.config.clipboardHistory.persist else { return }
        let arr = items.map {
            ["text": $0.text, "time": "\($0.time.timeIntervalSince1970)"]
        }
        if let data = try? JSONSerialization.data(withJSONObject: arr) {
            try? data.write(to: fileURL)
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
            for (i, item) in items.prefix(20).enumerated() {
                let title = item.text.replacingOccurrences(of: "\n", with: " ⏎ ")
                    .prefix(60)
                let mi = NSMenuItem(title: String(title),
                                    action: #selector(MenuDispatch.run(_:)),
                                    keyEquivalent: "")
                mi.target = MenuDispatch.shared
                mi.representedObject = MenuDispatch.register { [weak self] in
                    self?.paste(item)
                }
                sub.addItem(mi)
                _ = i
            }
            sub.addItem(.separator())
            let clear = NSMenuItem(title: L10n.t("清空历史", "Clear History"),
                                   action: #selector(MenuDispatch.run(_:)),
                                   keyEquivalent: "")
            clear.target = MenuDispatch.shared
            clear.representedObject = MenuDispatch.register { [weak self] in
                self?.clear()
            }
            sub.addItem(clear)
        }
        top.submenu = sub
        return top
    }
}
