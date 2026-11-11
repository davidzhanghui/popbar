import Cocoa
import Quartz
import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 待打印文件的预览窗口(思路同 stone-brook 的附件预览):系统 QLPreviewView,
/// PDF / 图片 / Office / iWork 都和访达里按空格看到的一样,可滚动翻页。
///
/// 转换过的文件(Office、文本、HEIC…)可在「打印效果」(实际要送进 CUPS 的 PDF)与「原文件」之间切换,
/// 方便对照转换有没有走样。
@MainActor
final class PrintPreviewWindow: NSObject, NSWindowDelegate {
    static let shared = PrintPreviewWindow()

    private var window: NSWindow?
    private let state = PrintPreviewState()

    func show(_ file: PreparedFile) {
        state.file = file
        state.showOriginal = false
        let w = window ?? make()
        window = w
        w.title = file.displayName
        // 盖在打印面板(可能是浮动 / 弹出层级)之上
        let base = NSApp.keyWindow?.level ?? .normal
        w.level = NSWindow.Level(rawValue: max(base.rawValue + 1, NSWindow.Level.floating.rawValue))
        if !w.isVisible, let vf = ScreenPlacement.screen(containing: NSEvent.mouseLocation)?.visibleFrame {
            let size = NSSize(width: min(820, vf.width - 80), height: min(980, vf.height - 60))
            w.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height), display: false)
        }
        NSApp.activateForUI()
        w.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let w = EscClosableWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 980),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 420, height: 360)
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.delegate = self
        w.contentView = NSHostingView(rootView: PrintPreviewContent(state: state))
        return w
    }

    func windowWillClose(_ notification: Notification) {
        state.file = nil        // 释放 QLPreviewView 持有的文件,暂存件随后可能被删
    }
}

@MainActor
final class PrintPreviewState: ObservableObject {
    @Published var file: PreparedFile?
    @Published var showOriginal = false
}

private struct PrintPreviewContent: View {
    @ObservedObject var state: PrintPreviewState

    var body: some View {
        VStack(spacing: 0) {
            if let f = state.file {
                header(f)
                Divider()
                let url = shownURL(f)
                if FileManager.default.fileExists(atPath: url.path) {
                    QuickLookView(url: url).id(url)
                } else {
                    placeholder(L10n.t("文件已不存在（可能已被移动或删除）", "The file no longer exists (moved or deleted)"))
                }
            } else {
                placeholder(L10n.t("没有可预览的文件", "Nothing to preview"))
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(SysTheme.card)
    }

    private func canCompare(_ f: PreparedFile) -> Bool {
        guard let src = f.source, !f.conversion.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: src.path)
    }

    private func shownURL(_ f: PreparedFile) -> URL {
        if state.showOriginal, canCompare(f), let s = f.source { return s }
        return f.url
    }

    private func header(_ f: PreparedFile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(f.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(PrintFileInfo.line(f)).font(.system(size: 11)).foregroundStyle(SysTheme.secondary).lineLimit(1)
            }
            Spacer()
            if canCompare(f) {
                Picker("", selection: $state.showOriginal) {
                    Text(L10n.t("打印效果", "As printed")).tag(false)
                    Text(L10n.t("原文件", "Original")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help(L10n.t("打印效果 = 转换后实际送去打印的 PDF", "As printed = the converted PDF that is actually sent to the printer"))
            }
            if let src = f.source, FileManager.default.fileExists(atPath: src.path) {
                PIcon(symbol: "arrow.up.forward.app", help: L10n.t("用默认应用打开原文件", "Open the original with its default app")) {
                    NSWorkspace.shared.open(src)
                }
                PIcon(symbol: "folder", help: L10n.t("在访达中显示", "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([src])
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.questionmark").font(.system(size: 28)).foregroundStyle(SysTheme.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(SysTheme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// QLPreviewView 包装
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.shouldCloseWithWindow = false
        v.previewItem = url as NSURL
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) {
        v.close()
    }
}

/// 文件说明行(列表与预览窗共用):大小 · 页数 · 转换
enum PrintFileInfo {
    static func line(_ f: PreparedFile) -> String {
        var p = [ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file)]
        if let n = f.pages { p.append(L10n.t("\(n) 页", "\(n) pg")) }
        if !f.conversion.isEmpty { p.append(f.conversion) }
        return p.joined(separator: " · ")
    }
}
