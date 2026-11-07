import Cocoa
import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 剪贴板速选（⌥⌘V）：宽 420，出现在鼠标所在屏的光标附近。
/// ↑↓ 选择、⌘1–9 直接选第 n 条、回车粘贴到当前 App、⇧回车只复制、直接打字过滤、Esc 关闭。
/// 面板不激活 PopBar（nonactivating），前台 App 保持不变，粘贴才能落到原处。
@MainActor
final class ClipboardPicker {
    static let shared = ClipboardPicker()
    static let width: CGFloat = 420

    final class Model: ObservableObject {
        @Published var query = ""
        @Published var selected = 0
        @Published var items: [ClipboardHistory.Item] = []
        @Published var enabled = true

        var filtered: [ClipboardHistory.Item] {
            guard !query.isEmpty else { return items }
            return items.filter { ClipboardItemText.title($0).localizedCaseInsensitiveContains(query) }
        }
    }

    private var panel: PickerPanel?
    private let model = Model()

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? close() : show() }

    func show() {
        model.enabled = ConfigStore.shared.config.clipboardHistory.enabled
        model.items = ClipboardHistory.shared.items
        model.query = ""
        model.selected = 0
        FloatingBarController.shared.hide()
        let p = panel ?? make()
        panel = p
        let rows = max(1, min(model.items.count, 9))
        let height: CGFloat = model.enabled && !model.items.isEmpty ? CGFloat(rows) * 44 + 86 : 200
        let size = CGSize(width: Self.width, height: height)
        let m = NSEvent.mouseLocation
        p.setFrame(ScreenPlacement.frame(size: size, anchor: CGRect(x: m.x, y: m.y - 8, width: 1, height: 16), prefer: .below, gap: 10),
                   display: true)
        p.makeKeyAndOrderFront(nil)   // popbar:no-activate（不激活 PopBar，前台 App 不变，⌘V 才能粘回原处）
    }

    func close() { panel?.orderOut(nil) }

    private func make() -> PickerPanel {
        let p = PickerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.onKey = { [weak self] ev in self?.handle(ev) ?? false }
        p.onResign = { [weak self] in self?.close() }
        let host = FirstMouseHostingView(rootView: ClipboardPickerView(model: model,
            onPick: { [weak self] i, copyOnly in self?.choose(i, copyOnly: copyOnly) },
            onEnable: { [weak self] in
                var c = ConfigStore.shared.config
                c.clipboardHistory.enabled = true
                try? ConfigStore.shared.save(c)
                self?.model.enabled = true
            }))
        p.contentView = host
        return p
    }

    /// 返回 true 表示已处理
    private func handle(_ ev: NSEvent) -> Bool {
        let list = model.filtered
        let cmd = ev.modifierFlags.contains(.command)
        switch ev.keyCode {
        case 53: close(); return true                                    // Esc
        case 125: if !list.isEmpty { model.selected = (model.selected + 1) % list.count }; return true   // ↓
        case 126: if !list.isEmpty { model.selected = (model.selected - 1 + list.count) % list.count }; return true   // ↑
        case 36, 76:                                                     // 回车 / ⇧回车
            choose(model.selected, copyOnly: ev.modifierFlags.contains(.shift))
            return true
        case 51:                                                         // ⌫ 删过滤字
            if !model.query.isEmpty { model.query.removeLast(); model.selected = 0 }
            return true
        default: break
        }
        if cmd, let ch = ev.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
            choose(n - 1, copyOnly: ev.modifierFlags.contains(.shift))
            return true
        }
        if !cmd, let s = ev.characters, !s.isEmpty, s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            model.query += s
            model.selected = 0
            return true
        }
        return false
    }

    private func choose(_ index: Int, copyOnly: Bool) {
        let list = model.filtered
        guard list.indices.contains(index) else { NSSound.beep(); return }
        let item = list[index]
        close()
        if copyOnly {
            ClipboardHistory.shared.writeBack(item)
        } else {
            ClipboardHistory.shared.paste(item)
        }
    }
}

final class PickerPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

struct ClipboardPickerView: View {
    @ObservedObject var model: ClipboardPicker.Model
    let onPick: (Int, Bool) -> Void
    let onEnable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Icon("clipboard", size: 14, color: DS.accent)
                Text(model.query.isEmpty ? L10n.t("剪贴板", "Clipboard") : model.query)
                    .font(DS.font(13, .semibold)).foregroundStyle(model.query.isEmpty ? DS.text : DS.accent)
                Spacer()
                if model.enabled && !model.items.isEmpty {
                    Text(L10n.t("打字过滤", "Type to filter")).font(DS.small).foregroundStyle(DS.faint)
                }
            }
            .padding(.horizontal, 14).frame(height: 40)
            DSDivider(inset: 0)
            if !model.enabled {
                DSEmptyState(icon: "clipboard", title: L10n.t("剪贴板记录已暂停", "Clipboard history is paused"),
                             message: L10n.t("开启后最近复制的内容会出现在这里。", "Turn it on to see recent copies here."),
                             actionTitle: L10n.t("开启记录", "Turn On"), action: onEnable)
                    .frame(maxHeight: .infinity)
            } else if model.filtered.isEmpty {
                DSEmptyState(icon: "clipboard", title: model.items.isEmpty ? L10n.t("还没有记录", "Nothing yet") : L10n.t("没有匹配的内容", "No matches"))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.filtered.prefix(30).enumerated()), id: \.element.id) { i, item in
                            row(item, index: i)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if model.enabled && !model.items.isEmpty {
                DSDivider(inset: 0)
                HStack(spacing: 12) {
                    hint("↩", L10n.t("粘贴", "Paste"))
                    hint("⇧↩", L10n.t("只复制", "Copy"))
                    hint("⌘1–9", L10n.t("快速选择", "Quick pick"))
                    Spacer()
                    hint("esc", L10n.t("关闭", "Close"))
                }
                .padding(.horizontal, 14).frame(height: 34)
            }
        }
        .frame(width: ClipboardPicker.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(DS.border, lineWidth: 1))
    }

    private func row(_ item: ClipboardHistory.Item, index i: Int) -> some View {
        let selected = i == model.selected
        return Button { onPick(i, false) } label: {
            HStack(spacing: 10) {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24).clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Icon(ClipboardItemText.icon(item), size: 14).frame(width: 24, height: 24)
                }
                Text(ClipboardItemText.title(item)).font(DS.body).foregroundStyle(DS.text).lineLimit(1)
                Spacer()
                if item.pinned { Icon("pin", size: 12, color: DS.faint) }
                if i < 9 { DSKbd("⌘\(i + 1)") }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(selected ? DS.accentSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { if $0 { model.selected = i } }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(DS.small.monospaced()).foregroundStyle(DS.muted)
            Text(text).font(DS.small).foregroundStyle(DS.faint)
        }
    }
}
