import Cocoa
import SwiftUI
import QuickLookThumbnailing
import PopBarCore
import PopBarPlatform
import PopBarDesign

// 各模块在 Deck 里的页面。原来的面板视图（监控、清理、打印、电视、启动项、维护、待办）
// 保留业务逻辑，外壳统一换成 DSPageShell，配色经 PanelTheme / SysTheme 映射到设计令牌。

// MARK: - 今日

struct TodayPage: View {
    @ObservedObject var store = TodoStore.shared
    @ObservedObject var pomo = Pomodoro.shared

    var body: some View {
        DSPageShell(L10n.t("今日", "Today"),
                    subtitle: L10n.t("待办与番茄钟；钉住后常驻桌面", "To-dos and Pomodoro; pin to keep it on screen"),
                    scrolls: false) {
            DSButton(L10n.t("钉在桌面", "Pin to Desktop"), icon: "pin") { TodayPinWindow.shared.pin() }
        } content: {
            TodoView(store: store, pomo: pomo)
                .frame(maxWidth: 560, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// 今日页的钉住模式：从 Deck 弹出的独立小窗（复用今日页的视图），常驻、点别处不收起、记住位置
@MainActor
final class TodayPinWindow: NSObject, NSWindowDelegate {
    static let shared = TodayPinWindow()
    private var panel: KeyablePanel?
    private let frameKey = "PopBarTodayPinFrame"

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect { panel?.frame ?? .zero }

    func toggle() { isVisible ? unpin() : pin() }

    func pin() {
        setPinned(true)
        show(activate: true)
    }

    func unpin() {
        setPinned(false)
        close()
    }

    /// 启动时恢复：只露出来，不抢焦点
    func restorePinned() {
        guard ConfigStore.shared.config.todo.pinned, !isVisible else { return }
        show(activate: false)
    }

    func close() { panel?.orderOut(nil) }

    private func setPinned(_ on: Bool) {
        var c = ConfigStore.shared.config
        guard c.todo.pinned != on else { return }
        c.todo.pinned = on
        try? ConfigStore.shared.save(c)
    }

    private func show(activate: Bool) {
        let p = panel ?? make()
        panel = p
        if activate {
            NSApp.activateForUI()
            p.makeKeyAndOrderFront(nil)
        } else {
            p.orderFrontRegardless()
        }
    }

    private func make() -> KeyablePanel {
        let size = NSSize(width: 360, height: 560)
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        let root = TodayPinView { [weak self] in self?.unpin() }
        let host = FirstMouseHostingView(rootView: root)
        host.wantsLayer = true
        host.layer?.cornerRadius = Theme.Radius.panel
        host.layer?.masksToBounds = true
        p.contentView = host
        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            let r = NSRectFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) { p.setFrame(r, display: false) }
        } else if let vf = ScreenPlacement.screen(containing: NSEvent.mouseLocation)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 24, y: vf.maxY - size.height - 24))
        }
        return p
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    private func saveFrame() {
        guard let f = panel?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(f), forKey: frameKey)
    }
}

struct TodayPinView: View {
    let onUnpin: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Icon("list-checks", size: 14, color: DS.accent)
                Text(L10n.t("今日", "Today")).font(DS.font(13, .semibold)).foregroundStyle(DS.text)
                Spacer()
                DSIconButton("pin-off", help: L10n.t("取消钉住", "Unpin"), size: 24, action: onUnpin)
            }
            TodoView(store: TodoStore.shared, pomo: Pomodoro.shared)
        }
        .padding(14)
        .background(DS.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(DS.border, lineWidth: 1))
        .tint(DS.accent)
    }
}

// MARK: - 剪贴板

struct ClipboardPage: View {
    @State private var config = ConfigStore.shared.config.clipboardHistory
    @State private var items: [ClipboardHistory.Item] = ClipboardHistory.shared.items
    @State private var query = ""
    private let changed = NotificationCenter.default.publisher(for: .init("PopBarClipboardHistoryChanged"))
    private let configChanged = NotificationCenter.default.publisher(for: ConfigStore.didChange)

    private var filtered: [ClipboardHistory.Item] {
        guard !query.isEmpty else { return items }
        return items.filter { ClipboardItemText.title($0).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        DSPageShell(L10n.t("剪贴板", "Clipboard"),
                    subtitle: L10n.t("最近 \(config.limit) 条；⌥⌘V 打开速选面板", "Last \(config.limit) items; ⌥⌘V opens the picker")) {
            if config.enabled && !items.isEmpty {
                DSButton(L10n.t("清空", "Clear"), icon: "trash-2", kind: .ghost) { ClipboardHistory.shared.clear() }
            }
        } content: {
            DSGroup {
                DSSettingRow(L10n.t("记录剪贴板", "Record Clipboard"),
                             subtitle: L10n.t("密码管理器复制的内容和临时写入会自动跳过", "Password-manager copies and transient writes are skipped")) {
                    DSToggle(isOn: Binding(get: { config.enabled }, set: { v in
                        var c = ConfigStore.shared.config
                        c.clipboardHistory.enabled = v
                        try? ConfigStore.shared.save(c)
                    }))
                }
            }
            if !config.enabled {
                DSEmptyState(icon: "clipboard", title: L10n.t("剪贴板记录已暂停", "Clipboard history is paused"),
                             message: L10n.t("打开上面的「记录剪贴板」后，复制过的文字、图片和文件会出现在这里。",
                                             "Turn on Record Clipboard above; copied text, images and files will show up here."))
                    .dsCardBackground()
            } else if items.isEmpty {
                DSEmptyState(icon: "clipboard", title: L10n.t("还没有记录", "Nothing yet"),
                             message: L10n.t("复制一段文字试试。", "Copy something to get started."))
                    .dsCardBackground()
            } else {
                DSField(L10n.t("搜索", "Search"), text: $query)
                VStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { DSDivider(inset: 14) }
                        ClipboardRow(item: item, index: i)
                    }
                }
                .dsCardBackground()
            }
        }
        .onReceive(changed) { _ in items = ClipboardHistory.shared.items }
        .onReceive(configChanged) { _ in
            config = ConfigStore.shared.config.clipboardHistory
            items = ClipboardHistory.shared.items
        }
    }
}

enum ClipboardItemText {
    static func title(_ item: ClipboardHistory.Item) -> String {
        switch item.payload {
        case .text(let s): return s.replacingOccurrences(of: "\n", with: " ")
        case .image(_, let size, _, _): return L10n.t("图片 \(Int(size.width))×\(Int(size.height))", "Image \(Int(size.width))×\(Int(size.height))")
        case .files(let urls):
            return urls.count == 1 ? urls[0].lastPathComponent : L10n.t("\(urls.count) 个文件", "\(urls.count) files")
        }
    }

    static func icon(_ item: ClipboardHistory.Item) -> String {
        switch item.payload {
        case .text: return "type"
        case .image: return "image"
        case .files: return "file"
        }
    }

    static func time(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: L10n.isEnglish ? "en_US" : "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

struct ClipboardRow: View {
    let item: ClipboardHistory.Item
    let index: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if let thumb = item.thumbnail {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Icon(ClipboardItemText.icon(item), size: 15).frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DS.surface2))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ClipboardItemText.title(item)).font(DS.body).foregroundStyle(DS.text).lineLimit(1)
                Text(ClipboardItemText.time(item.time)).font(DS.small).foregroundStyle(DS.faint)
            }
            Spacer()
            if item.pinned { DSChip(L10n.t("置顶", "Pinned"), tone: .accent) }
            if hovering {
                DSIconButton("copy", help: L10n.t("复制", "Copy"), size: 26) { ClipboardHistory.shared.writeBack(item) }
                DSIconButton(item.pinned ? "pin-off" : "pin", help: L10n.t("置顶", "Pin"), size: 26) { ClipboardHistory.shared.togglePin(item) }
                DSIconButton("trash-2", help: L10n.t("删除", "Delete"), size: 26) { ClipboardHistory.shared.remove(item) }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .contentShape(Rectangle())
        .background(hovering ? DS.hover : .clear)
        .onHover { hovering = $0 }
    }
}

// MARK: - 截屏

struct SnapPage: View {
    @State private var entries: [SnapHistory.Entry] = []
    @State private var historyOn = ConfigStore.shared.config.snap.history.enabled
    private let cols = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        DSPageShell(L10n.t("截屏", "Screenshot"),
                    subtitle: L10n.t("快捷键 \(KeyCombo.display(ConfigStore.shared.config.hotkeys.snap))；框选后可标注、贴图、长截屏",
                                     "Shortcut \(KeyCombo.display(ConfigStore.shared.config.hotkeys.snap)); annotate, pin or scroll after selecting")) {
            DSButton(L10n.t("设置", "Settings"), icon: "settings", kind: .ghost) { AppRouter.openSettings(.media) }
            DSButton(L10n.t("截屏", "Capture"), icon: "scan", kind: .primary) {
                DeckController.shared.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { AppRouter.snap() }
            }
        } content: {
            if !historyOn {
                DSEmptyState(icon: "image", title: L10n.t("截图历史未开启", "Screenshot history is off"),
                             message: L10n.t("开启后最近的截图会保存在本机，在这里浏览、复制或重新贴图。",
                                             "When on, recent captures are kept locally so you can browse, copy or pin them again."),
                             actionTitle: L10n.t("开启截图历史", "Turn On History")) {
                    var c = ConfigStore.shared.config
                    c.snap.history.enabled = true
                    try? ConfigStore.shared.save(c)
                    historyOn = true
                }
                .dsCardBackground()
            } else if entries.isEmpty {
                DSEmptyState(icon: "image", title: L10n.t("还没有截图", "No screenshots yet"),
                             message: L10n.t("按 \(KeyCombo.display(ConfigStore.shared.config.hotkeys.snap)) 截一张试试。", "Press the shortcut to capture."))
                    .dsCardBackground()
            } else {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(entries, id: \.url) { e in SnapTile(entry: e) { reload() } }
                }
            }
        }
        .onAppear(perform: reload)
    }

    static func load(_ e: SnapHistory.Entry) -> CGImage? {
        NSImage(contentsOf: e.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// 贴到鼠标所在屏幕中央，最大占屏幕 80%
    static func pin(_ img: CGImage, entry e: SnapHistory.Entry) {
        guard let screen = ScreenPlacement.screen(containing: NSEvent.mouseLocation) else { return }
        var size = CGSize(width: CGFloat(img.width) / e.scale, height: CGFloat(img.height) / e.scale)
        let fit = min(screen.frame.width * 0.8 / size.width, screen.frame.height * 0.8 / size.height, 1)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        let f = screen.frame
        SnapPinWindow.show(image: img, scale: e.scale, frame: CGRect(
            x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height))
    }

    private func reload() {
        historyOn = ConfigStore.shared.config.snap.history.enabled
        entries = SnapHistory.entries()
    }
}

struct SnapTile: View {
    let entry: SnapHistory.Entry
    let onChange: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(DS.surface2)
                if let img = NSImage(contentsOf: entry.url) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(6)
                }
                if hovering {
                    HStack(spacing: 4) {
                        DSIconButton("copy", tint: DS.text, help: L10n.t("复制", "Copy"), size: 26) {
                            if let img = SnapPage.load(entry) { SnapOutput.copy(img, scale: entry.scale) }
                        }
                        DSIconButton("pin", tint: DS.text, help: L10n.t("贴图", "Pin"), size: 26) {
                            if let img = SnapPage.load(entry) { SnapPage.pin(img, entry: entry) }
                        }
                        DSIconButton("folder-open", tint: DS.text, help: L10n.t("在访达中显示", "Reveal"), size: 26) {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                        DSIconButton("trash-2", tint: DS.danger, help: L10n.t("删除", "Delete"), size: 26) {
                            try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
                            onChange()
                        }
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DS.surface))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(6)
                }
            }
            .frame(height: 110)
            Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(DS.small).foregroundStyle(DS.muted)
            Text("\(Int(entry.pixelSize.width))×\(Int(entry.pixelSize.height))").font(DS.small).foregroundStyle(DS.faint)
        }
        .padding(10)
        .dsCardBackground()
        .onHover { hovering = $0 }
    }
}

// MARK: - 录屏

struct RecordPage: View {
    @State private var entries: [RecordEntry] = RecordHistory.shared.entries
    private let changed = NotificationCenter.default.publisher(for: RecordHistory.didChange)

    var body: some View {
        DSPageShell(L10n.t("录屏", "Recording"),
                    subtitle: L10n.t("快捷键 \(KeyCombo.display(ConfigStore.shared.config.hotkeys.record))；录制中再按一次停止",
                                     "Shortcut \(KeyCombo.display(ConfigStore.shared.config.hotkeys.record)); press again to stop")) {
            DSButton(L10n.t("设置", "Settings"), icon: "settings", kind: .ghost) { AppRouter.openSettings(.media) }
            DSButton(RecordSession.shared.isRecording ? L10n.t("停止录制", "Stop") : L10n.t("开始录屏", "Record"),
                     icon: "circle-dot", kind: .primary) {
                DeckController.shared.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { AppRouter.recordToggle() }
            }
        } content: {
            if entries.isEmpty {
                DSEmptyState(icon: "video", title: L10n.t("还没有录制", "No recordings yet"),
                             message: L10n.t("最近 \(RecordHistory.limit) 次录制会列在这里。", "Your last \(RecordHistory.limit) recordings show up here."))
                    .dsCardBackground()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.path) { i, e in
                        if i > 0 { DSDivider(inset: 14) }
                        RecordRow(entry: e)
                    }
                }
                .dsCardBackground()
                HStack {
                    Spacer()
                    DSButton(L10n.t("清空列表", "Clear List"), kind: .ghost) { RecordHistory.shared.clear() }
                }
            }
        }
        .onAppear { RecordHistory.shared.prune(); entries = RecordHistory.shared.entries }
        .onReceive(changed) { _ in entries = RecordHistory.shared.entries }
    }
}

struct RecordRow: View {
    let entry: RecordEntry
    @State private var thumb: NSImage?
    @State private var hovering = false

    private var sourceName: String {
        entry.source.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    }
    /// 原始录屏:视频本身;导出成品:仍在磁盘上的原始文件;录制时直接出的 GIF 没有源
    private var exportSource: URL? {
        if entry.isExported { return entry.sourceURL }
        return entry.isGIF ? nil : entry.url
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(DS.surface2)
                if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill) }
                else { Icon(entry.isGIF ? "image" : "film", size: 15) }
            }
            .frame(width: 56, height: 34).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.url.lastPathComponent).font(DS.body).foregroundStyle(DS.text).lineLimit(1)
                    if entry.isExported {
                        DSChip(L10n.t("已导出", "Exported"), tone: .accent)
                            .help(L10n.t("由 \(sourceName) 导出", "Exported from \(sourceName)"))
                    }
                }
                Text("\(RecordUtil.durationText(entry.duration)) · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)) · "
                     + Date(timeIntervalSince1970: entry.createdAt).formatted(date: .abbreviated, time: .shortened))
                    .font(DS.small).foregroundStyle(DS.faint)
            }
            Spacer()
            if hovering {
                DSIconButton("play", help: L10n.t("打开", "Open"), size: 26) { NSWorkspace.shared.open(entry.url) }
                // 导出永远从原始录屏出发:导出成品点这里会打开它的原始文件;原始文件已删就不给入口
                if let src = exportSource {
                    DSIconButton("wand-sparkles",
                                 help: entry.isExported ? L10n.t("从原始录屏重新导出…", "Re-export from the original…")
                                                        : L10n.t("编辑并导出…", "Edit & Export…"),
                                 size: 26) { RecordExportController.shared.show(url: src) }
                }
                DSIconButton("folder-open", help: L10n.t("在访达中显示", "Reveal"), size: 26) {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                }
                DSIconButton("trash-2", tint: DS.danger, help: L10n.t("移入废纸篓", "Move to Trash"), size: 26) {
                    try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
                    RecordHistory.shared.remove(path: entry.path)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .contentShape(Rectangle())
        .background(hovering ? DS.hover : .clear)
        .onHover { hovering = $0 }
        .task(id: entry.path) {
            let req = QLThumbnailGenerator.Request(fileAt: entry.url, size: CGSize(width: 112, height: 68),
                                                   scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                thumb = rep.nsImage
            }
        }
    }
}

// MARK: - 系统

struct MonitorPage: View {
    @ObservedObject var model: SystemMonitorModel
    var body: some View {
        DSPageShell(L10n.t("监控", "Monitor"), subtitle: L10n.t("CPU、内存、进程；只在这一页打开时采样", "CPU, memory and processes; sampled only while this page is open"),
                    scrolls: false) {
            SystemMonitorView(vm: model, onClose: { model.closeDetail() })
        }
    }
}

struct CleanPage: View {
    let module: CleanModule
    var body: some View {
        DSPageShell(L10n.t("清理", "Cleanup"), subtitle: L10n.t("勾选后移入废纸篓，可以随时从废纸篓恢复", "Selected items go to the Trash and can be restored"),
                    scrolls: false) {
            CleanView(vm: module.model)
        }
    }
}

struct StartupPage: View {
    @ObservedObject var model: StartupViewModel
    var body: some View {
        DSPageShell(L10n.t("启动项", "Startup"), subtitle: L10n.t("停用只是让它不再自动运行，可以随时恢复。", "Disabling only stops it from launching automatically; you can restore it anytime."),
                    scrolls: false) {
            StartupView(vm: model)
        }
    }
}

struct MaintenancePage: View {
    @ObservedObject var model: MaintenanceViewModel
    var body: some View {
        DSPageShell(L10n.t("维护", "Maintenance"), subtitle: L10n.t("只做有实际效果的维护；需要管理员权限的会弹出密码框", "Only tasks that actually help; admin tasks ask for your password"),
                    scrolls: false) {
            MaintenanceView(vm: model)
        }
    }
}

// MARK: - 设备

struct PrintPage: View {
    var body: some View {
        DSPageShell(L10n.t("打印", "Print"), subtitle: L10n.t("打印机、作业、批量打印与统计", "Printers, jobs, batch printing and stats"), scrolls: false) {
            PrintView(center: PrintCenter.shared)
        }
    }
}

struct TVPage: View {
    var body: some View {
        DSPageShell(L10n.t("电视", "TV"), subtitle: L10n.t("通过 ADB 遥控局域网里的安卓电视", "Remote-control Android TVs on your network over ADB"), scrolls: false) {
            TVView(model: TVModel.shared)
        }
    }
}

/// 面板不在前台时，第一次点击也直接生效（否则点一下只是把窗口激活，要点两次）
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
