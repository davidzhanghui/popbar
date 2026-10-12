import Cocoa

enum SnapAction { case copy, save, ocr, pin }

/// 截屏会话:冻结所有屏幕 → 每屏一个覆盖窗口 → 完成/取消后统一销毁
final class SnapController {
    static let shared = SnapController()
    private(set) var isActive = false
    private(set) var isScrolling = false
    private var scrollSession: SnapScrollSession?
    private var scrollBorder: SnapScrollBorderWindow?
    private var scrollPanel: SnapScrollPanel?
    private var overlays: [SnapOverlayWindow] = []
    private var previousApp: NSRunningApplication?

    private init() {}

    func start() {
        guard !isActive, ScreenPermission.ensure() else { return }
        isActive = true
        FloatingBarController.shared.hide()
        if TranslationPanelController.shared.isVisible && !TranslationPanelController.shared.isPinned {
            TranslationPanelController.shared.close()
        }
        let rects = SnapCapture.windowRects()
        Task { @MainActor in
            do {
                let shots = try await SnapCapture.captureAll()
                guard self.isActive, !shots.isEmpty else { return self.cancel() }
                self.show(shots, windowRects: rects)
            } catch {
                self.cancel()
                NSSound.beep()
            }
        }
    }

    private func show(_ shots: [SnapDisplayShot], windowRects: [CGRect]) {
        overlays = shots.map { SnapOverlayWindow(shot: $0, windowRects: windowRects) }
        overlays.forEach { $0.overlayView.prepare() }
        let mouse = NSEvent.mouseLocation
        let key = overlays.first { $0.frame.contains(mouse) } ?? overlays[0]
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == getpid() ? nil : front
        NSApp.activateForUI()
        for o in overlays where o !== key { o.orderFront(nil) }
        key.makeKeyAndOrderFront(nil)
        key.overlayView.didShow()
    }

    func cancel() {
        teardown()
        restorePreviousApp()
    }

    private func restorePreviousApp() {
        defer { previousApp = nil }
        guard let app = previousApp else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    /// 合成图 → 销毁覆盖窗口 → 执行动作
    func complete(from view: SnapOverlayView, action: SnapAction) {
        view.commitText()
        guard let sel = view.selection else { return }
        let shot = view.shot
        let img = SnapOutput.compose(image: shot.image, scale: shot.scale, selection: sel,
                                     viewHeight: view.bounds.height, annotations: view.annotationItems,
                                     mosaicImage: view.exportMosaic)
        let globalRect = sel.offsetBy(dx: shot.screen.frame.minX, dy: shot.screen.frame.minY)
        teardown()
        switch action {
        case .copy:
            SnapOutput.copy(img, scale: shot.scale)
            restorePreviousApp()
        case .save:
            SnapOutput.save(img)
            restorePreviousApp()
        case .ocr:
            previousApp = nil
            SnapOutput.ocr(img)
        case .pin:
            SnapPinWindow.show(image: img, scale: shot.scale, frame: globalRect)
            restorePreviousApp()
        }
        SnapHistory.add(img, scale: shot.scale)
    }

    // MARK: - 长截图

    func beginScroll(from view: SnapOverlayView) {
        view.commitText()
        guard let sel = view.selection, view.annotationItems.isEmpty else { return }
        let screen = view.shot.screen
        let rect = sel.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        teardown(keepActive: true)
        restorePreviousApp()
        isScrolling = true

        let session = SnapScrollSession(screen: screen, rect: rect)
        let panel = SnapScrollPanel(selection: rect, screen: screen) { [weak self] action in
            if let action { self?.completeScroll(action) } else { self?.cancelScroll() }
        }
        let border = SnapScrollBorderWindow(rect: rect)
        session.onUpdate = { [weak panel] preview, status in
            panel?.update(preview: preview, scale: session.scale, status: status)
        }
        scrollSession = session
        scrollPanel = panel
        scrollBorder = border
        border.orderFrontRegardless()
        panel.orderFrontRegardless()
        Task { @MainActor in
            do { try await session.start() } catch {
                self.cancelScroll()
                NSSound.beep()
            }
        }
    }

    func cancelScroll() {
        guard isScrolling else { return }
        endScroll()
    }

    func completeScroll(_ action: SnapAction) {
        guard isScrolling, let session = scrollSession else { return }
        let img = session.finalImage()
        let scale = session.scale
        endScroll()
        guard let img else { return NSSound.beep() }
        switch action {
        case .save: SnapOutput.save(img)
        case .ocr: SnapOutput.ocr(img)
        default: SnapOutput.copy(img, scale: scale)
        }
        SnapHistory.add(img, scale: scale)
    }

    private func endScroll() {
        BarTooltip.shared.hide()
        scrollSession?.stop()
        scrollSession = nil
        scrollPanel?.orderOut(nil)
        scrollBorder?.orderOut(nil)
        let old: [NSWindow?] = [scrollPanel, scrollBorder]
        DispatchQueue.main.async { old.forEach { $0?.close() } }
        scrollPanel = nil
        scrollBorder = nil
        isScrolling = false
        isActive = false
        previousApp = nil
    }

    /// 选区只能在一个屏幕上:某屏开始拖选时,清掉其他屏的选区/悬停
    func claim(_ view: SnapOverlayView) {
        for o in overlays where o.overlayView !== view { o.overlayView.clear() }
    }

    var selectionView: SnapOverlayView? {
        overlays.map { $0.overlayView }.first { $0.selection != nil }
    }

    private func teardown(keepActive: Bool = false) {
        BarTooltip.shared.hide()
        let old = overlays
        overlays = []
        isActive = keepActive
        old.forEach { $0.orderOut(nil) }
        DispatchQueue.main.async { old.forEach { $0.close() } }
    }
}
