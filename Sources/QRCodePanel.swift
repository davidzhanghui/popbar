import Cocoa
import CoreImage

/// #9 选中 URL / 短文本生成二维码,方便手机扫码。
enum QRCodePanel {
    static let maxInput = 1000

    /// 工具条动作:像 URL 时是上下文按钮,普通短文本默认放溢出菜单
    static func barAction() -> BarAction? {
        BarAction(
            id: "builtin.qrcode", title: L10n.t("生成二维码", "QR Code"),
            symbol: "qrcode", color: .systemBlue,
            isAvailable: { ctx in
                let t = ctx.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return !t.isEmpty && t.count <= maxInput
            }) { ctx in
            show(text: ctx.text.trimmingCharacters(in: .whitespacesAndNewlines))
            FloatingBarController.shared.hide()
        }
    }

    /// 由文本生成放大的二维码 NSImage(禁用插值保证清晰)
    static func image(for text: String, pixels: CGFloat = 480) -> NSImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scale = pixels / max(ci.extent.width, 1)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    private static var panel: KeyablePanel?

    static func show(text: String) {
        guard let img = image(for: text) else { NSSound.beep(); return }

        let p: KeyablePanel
        if let existing = panel {
            p = existing
        } else {
            p = KeyablePanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 280, height: 360)),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.onEscape = { panel?.orderOut(nil) }
            panel = p
        }

        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true

        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 12
        col.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        col.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            col.topAnchor.constraint(equalTo: root.topAnchor),
            col.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        let iv = NSImageView(image: img)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.widthAnchor.constraint(equalToConstant: 240).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 240).isActive = true
        col.addArrangedSubview(iv)

        let label = NSTextField(wrappingLabelWithString:
            text.count > 120 ? String(text.prefix(120)) + "…" : text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = 240
        col.addArrangedSubview(label)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let copyBtn = ClosureButton(title: L10n.t("复制图片", "Copy Image")) {
            PasteboardGuard.write(items: {
                let it = NSPasteboardItem()
                if let tiff = img.tiffRepresentation { it.setData(tiff, forType: .tiff) }
                if let png = pngData(img) { it.setData(png, forType: .png) }
                return [it]
            }())
            panel?.orderOut(nil)
        }
        copyBtn.bezelStyle = .rounded
        copyBtn.controlSize = .small
        let saveBtn = ClosureButton(title: L10n.t("存为 PNG", "Save PNG")) {
            savePNG(img, suggestedName: "qrcode.png")
            panel?.orderOut(nil)
        }
        saveBtn.bezelStyle = .rounded
        saveBtn.controlSize = .small
        buttons.addArrangedSubview(copyBtn)
        buttons.addArrangedSubview(saveBtn)
        col.addArrangedSubview(buttons)

        p.contentView = root
        root.layoutSubtreeIfNeeded()
        p.setContentSize(root.fittingSize)
        p.center()
        NSApp.activateForUI()
        p.makeKeyAndOrderFront(nil)
    }

    private static func pngData(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func savePNG(_ img: NSImage, suggestedName: String) {
        guard let data = pngData(img) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.title = L10n.t("保存二维码", "Save QR Code")
        panel.prompt = L10n.t("保存", "Save")
        NSApp.activateForUI()
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }
}
