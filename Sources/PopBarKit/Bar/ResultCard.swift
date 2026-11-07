import Cocoa
import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 结果卡片：扩展输出、JWT 解码等较长结果的展示。宽 360，贴着选区出现（优先下方），
/// 可复制、Esc 或点别处关闭。取代原来的标题栏窗口 OutputPanel。
@MainActor
final class ResultCard {
    static let shared = ResultCard()
    static let width: CGFloat = 360

    private var panel: KeyablePanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(title: String, text: String, anchor: CGRect?, mono: Bool = false) {
        let p = panel ?? make()
        panel = p
        let view = ResultCardView(title: title, text: text, mono: mono,
                                  onCopy: { PasteboardGuard.write(text) },
                                  onClose: { [weak self] in self?.close() })
        let host = FirstMouseHostingView(rootView: view)
        let fit = host.fittingSize
        let size = CGSize(width: Self.width, height: min(max(fit.height, 96), 420))
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        p.setFrame(ScreenPlacement.frame(size: size, anchor: anchor, prefer: .below, gap: 8), display: true)
        NSApp.activateForUI()
        p.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    private func make() -> KeyablePanel {
        let p = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onEscape = { [weak self] in self?.close() }
        return p
    }
}

struct ResultCardView: View {
    let title: String
    let text: String
    let mono: Bool
    let onCopy: () -> Void
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(DS.font(13, .semibold)).foregroundStyle(DS.text)
                Spacer()
                DSIconButton(copied ? "check" : "copy", tint: copied ? DS.success : nil, help: L10n.t("复制", "Copy"), size: 24) {
                    onCopy()
                    copied = true
                }
                DSIconButton("x", help: L10n.t("关闭", "Close"), size: 24, action: onClose)
            }
            ScrollView {
                Text(text.isEmpty ? L10n.t("（没有输出）", "(no output)") : text)
                    .font(mono ? DS.mono : DS.body)
                    .foregroundStyle(text.isEmpty ? DS.faint : DS.text2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 340)
        }
        .padding(14)
        .frame(width: ResultCard.width, alignment: .topLeading)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(DS.border, lineWidth: 1))
    }
}
