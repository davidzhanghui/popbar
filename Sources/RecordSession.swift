import Cocoa
import ScreenCaptureKit
@preconcurrency import AVFoundation
import UserNotifications

// MARK: - 纯逻辑(无副作用,便于测试)

enum RecordUtil {
    /// H.264 要求偶数边长:向下对齐,最小 2 px
    static func evenPixel(_ value: CGFloat) -> Int {
        max(Int(value.rounded()) & ~1, 2)
    }

    /// 选区(Cocoa 全局,左下原点) → SCK sourceRect(display 左上原点)
    static func sourceRect(global rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX - screenFrame.minX,
               y: screenFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// mm:ss;超过 1 小时显示 h:mm:ss
    static func durationText(_ t: TimeInterval) -> String {
        let total = max(Int(t.rounded()), 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func fileStem(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "PopBar-Rec-" + f.string(from: date)
    }

    /// 同名则追加 -2、-3 …
    static func uniqueURL(in dir: URL, stem: String, ext: String) -> URL {
        var url = dir.appendingPathComponent("\(stem).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem)-\(i).\(ext)")
            i += 1
        }
        return url
    }

    /// 录制码率粗估(byte/s):按「每像素每帧多少 bit」的经验系数,
    /// 用途是让用户在录之前对体积有个概念,不追求精确。
    static func estimatedBytesPerSecond(width: Int, height: Int, fps: Int, codec: String) -> Double {
        let bpp = codec == "hevc" ? 0.05 : 0.07
        return Double(max(width, 0)) * Double(max(height, 0)) * Double(max(fps, 1)) * bpp / 8
    }

    static func byteText(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(max(bytes, 0)) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    /// GIF 体积粗估:帧数 × 宽 × 高 × 0.3 byte
    static func gifBytes(frames: Int, width: Int, height: Int) -> Int64 {
        Int64(max(frames, 0)) * Int64(max(width, 0)) * Int64(max(height, 0)) * 3 / 10
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// 按屏幕记住上次录屏选区(M2 FR-16)
enum RecordRectMemory {
    static func key(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenUUID")] as? String)
            ?? "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    static func encode(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())),\(Int(rect.width.rounded())),\(Int(rect.height.rounded()))"
    }

    static func decode(_ s: String) -> CGRect? {
        let p = s.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4, p[2] >= 2, p[3] >= 2 else { return nil }
        return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
    }

    static func rect(for screen: NSScreen) -> CGRect? {
        guard let s = ConfigStore.shared.config.snap.record.lastRects[key(screen)] else { return nil }
        return decode(s)
    }

    static func save(_ rect: CGRect, screen: NSScreen) {
        var c = ConfigStore.shared.config
        c.snap.record.lastRects[key(screen)] = encode(rect)
        try? ConfigStore.shared.save(c)
    }
}

/// 麦克风(M3):只有开启麦克风时才触发授权
enum MicPermission {
    static func ensure() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
            }
        case .denied, .restricted:
            await MainActor.run { denyAlert() }
            return false
        @unknown default:
            return false
        }
    }

    /// id → 名称;列表为空表示没有可用设备
    static func devices() -> [(id: String, name: String)] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                       mediaType: .audio, position: .unspecified)
        return session.devices.map { (id: $0.uniqueID, name: $0.localizedName) }
    }

    static func deviceID(matching nameOrID: String) -> String? {
        guard !nameOrID.isEmpty else { return nil }
        let list = devices()
        return list.first { $0.id == nameOrID }?.id ?? list.first { $0.name == nameOrID }?.id
    }

    @MainActor private static func denyAlert() {
        let a = NSAlert()
        a.messageText = L10n.t("需要「麦克风」权限", "Microphone Permission Required")
        a.informativeText = L10n.t(
            "录屏带麦克风需要麦克风权限。\n请在 系统设置 → 隐私与安全性 → 麦克风 中允许 PopBar。",
            "Recording with microphone needs microphone access.\nPlease allow PopBar in System Settings → Privacy & Security → Microphone.")
        a.addButton(withTitle: L10n.t("打开设置", "Open Settings"))
        a.addButton(withTitle: L10n.t("取消", "Cancel"))
        NSApp.activateForUI()
        if a.runModal() == .alertFirstButtonReturn,
           let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(u)
        }
    }
}

/// 麦克风音量测试:AVCaptureSession 采集所选输入设备的 PCM,算 RMS 电平回调给 UI。
/// 授权由调用方先 MicPermission.ensure,这里只做采集。
final class MicLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "PopBarMicLevel")
    private(set) var running = false
    /// 电平 0..1(-60dB..0dB 映射),主线程回调
    var onLevel: ((Float) -> Void)?

    /// deviceUID 传 nil 或空串时用系统默认输入
    func start(deviceUID: String?) {
        stop()
        let device = deviceUID.flatMap({ $0.isEmpty ? nil : $0 })
            .flatMap { AVCaptureDevice(uniqueID: $0) }
            ?? AVCaptureDevice.default(for: .audio)
        guard let device else { return }
        let s = AVCaptureSession()
        s.beginConfiguration()
        defer { s.commitConfiguration() }
        guard let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input) else { return }
        s.addInput(input)
        let output = AVCaptureAudioDataOutput()
        guard s.canAddOutput(output) else { return }
        s.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session = s
        running = true
        queue.async { s.startRunning() }
    }

    func stop() {
        session?.stopRunning()
        session = nil
        running = false
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var data: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &data) == noErr,
              let data, length > 0 else { return }
        var sum: Float = 0
        var n = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            n = length / MemoryLayout<Float>.size
            data.withMemoryRebound(to: Float.self, capacity: n) { p in
                for i in 0..<n { sum += p[i] * p[i] }
            }
        } else {
            n = length / MemoryLayout<Int16>.size
            data.withMemoryRebound(to: Int16.self, capacity: n) { p in
                for i in 0..<n { let f = Float(p[i]) / 32768; sum += f * f }
            }
        }
        guard n > 0 else { return }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-5))
        let level = min(max((db + 60) / 60, 0), 1)
        DispatchQueue.main.async { self.onLevel?(level) }
    }
}

// MARK: - 完成通知

enum RecordNotify {
    static let categoryID = "PopBarRecordDone"
    static let gifActionID = "PopBarRecordGIF"
    static let exportActionID = "PopBarRecordExport"
    static let playActionID = "PopBarRecordPlay"
    /// GIF 成品只给「播放」:再导出 GIF / 编辑没有意义
    static let gifCategoryID = "PopBarRecordDoneGIF"
    static let pathKey = "path"

    private static var prepared = false

    /// 启动时调用:装上 delegate + 注册分类。
    /// 必须在应用启动早期执行——App 重启后点击历史通知的 action 时,
    /// 系统仍会投递响应,delegate 没装上就会被静默丢弃(点了没反应)。
    /// 不在这里请求通知授权,避免首次启动就弹窗。
    static func prepare() {
        guard !prepared else { return }
        prepared = true
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationRouter.shared
        let play = UNNotificationAction(identifier: playActionID,
                                        title: L10n.t("播放", "Play"), options: [])
        let edit = UNNotificationAction(identifier: exportActionID,
                                        title: L10n.t("编辑并导出", "Edit & Export"), options: [])
        let gif = UNNotificationAction(identifier: gifActionID,
                                       title: L10n.t("导出 GIF", "Export GIF"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: categoryID, actions: [play, edit, gif],
                                   intentIdentifiers: [], options: .customDismissAction),
            UNNotificationCategory(identifier: gifCategoryID, actions: [play],
                                   intentIdentifiers: [], options: .customDismissAction),
        ])
    }

    static func saved(_ url: URL, duration: TimeInterval, interrupted: Bool, title: String? = nil) {
        let size = RecordUtil.fileSize(url)
        let detail = "\(RecordUtil.durationText(duration)) · \(RecordUtil.byteText(size))"
        prepare()
        // 首次真正发通知时才请求授权
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title ?? (interrupted ? L10n.t("录制已中断,已保存", "Recording interrupted, saved")
                                             : L10n.t("录屏已保存", "Recording saved"))
        content.body = detail
        content.categoryIdentifier = url.pathExtension.lowercased() == "gif" ? gifCategoryID : categoryID
        content.userInfo = [pathKey: url.path]
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            guard error != nil else { return }
            Task { @MainActor in fallback(url, text: content.title + " · " + detail) }
        }
    }

    /// 未授权 / 通知失败时的兜底:浮动条 + 在 Finder 中显示
    @MainActor static func fallback(_ url: URL, text: String) {
        FloatingBarController.shared.showResult(text, buttons: [
            (L10n.t("在 Finder 中显示", "Show in Finder"), { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
        ])
    }
}

final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo[RecordNotify.pathKey] as? String
        let url = path.map { URL(fileURLWithPath: $0) }
        if let url {
            switch response.actionIdentifier {
            case RecordNotify.gifActionID:
                Task { @MainActor in GIFExportController.shared.show(url: url) }
            case RecordNotify.exportActionID:
                Task { @MainActor in RecordExportController.shared.show(url: url) }
            case RecordNotify.playActionID:
                NSWorkspace.shared.open(url)
            default:
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        completionHandler()
    }

    /// 前台也显示横幅(accessory 应用默认不弹)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - 录屏会话

/// 一次录屏 = 一个或多个 SCStream 片段(暂停会切成多段)→ 收尾时合并成单个文件
@MainActor
final class RecordSession: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    static let shared = RecordSession()
    /// 开始/结束/暂停状态变化
    static let stateChanged = Notification.Name("PopBarRecordStateChanged")
    /// 计时每秒刷新(userInfo: ["duration": TimeInterval])
    static let ticked = Notification.Name("PopBarRecordTicked")

    private(set) var isRecording = false
    private(set) var isPaused = false
    /// 暂停/继续切换中,避免重入
    private(set) var isBusy = false

    private var filter: SCContentFilter?
    private var screen: NSScreen?
    private var rect: CGRect?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var border: RecordBorderWindow?
    private var panel: RecordPanel?
    // MARK: v2
    /// 选区吸附到的窗口:非空时按窗口录,窗口移动/缩放自动跟随
    private var windowID: CGWindowID?
    /// 窗口当前的 Cocoa 全局 frame(轮询刷新;点击时再实时取一次)
    private var windowFrame: CGRect?
    /// 倒计时中的取消标记
    private var countdownCancelled = false
    private var countdownPanel: RecordCountdownPanel?
    private let clickRecorder = ClickRecorder()
    private var markers: [RecordMarker] = []
    private let camera = CameraRecorder()
    private var cameraPanel: RecordCameraPanel?
    private var cameraOverlay: CameraSidecar?
    private var cameraFailed = false
    /// 上一次下发给 SCStream 的输出尺寸,用来判断窗口缩放后要不要 updateConfiguration
    private var lastAppliedSize = CGSize.zero
    private var timer: Timer?
    private var startedAt = Date()
    private var accumulated: TimeInterval = 0
    private var segments: [URL] = []
    private var tempDir: URL?
    private var finalURL: URL?
    private var gifMode = false
    /// start() 的 await 窗口内防止重入(isRecording 还没置位)
    private var starting = false
    private var finishing = false
    private var segmentFinished = false
    /// 最后一段写盘失败(didFailWithError):完成通知按 interrupted 文案
    private var lastSegmentFailed = false
    private var finishWaits: [CheckedContinuation<Void, Never>] = []
    /// waitFinish 的兜底任务按代际校验,旧任务不许唤醒新段的等待者
    private var finishGeneration = 0

    /// 已录制时长(暂停不计)
    var duration: TimeInterval {
        guard isRecording else { return accumulated }
        return accumulated + (isPaused ? 0 : Date().timeIntervalSince(startedAt))
    }

    // MARK: 启动

    /// rect 为 Cocoa 全局坐标;nil = 整屏。windowID 非空时按该窗口录并跟随窗口。
    func start(screen: NSScreen, rect: CGRect?, gif: Bool = false,
               windowID: CGWindowID? = nil) async throws {
        guard !isRecording, !starting, !isBusy else { return }
        starting = true
        defer { starting = false }
        // 上次会话残留状态归位(stop 与 pause 并发时 pause 的 Task 可能晚于收尾写状态)
        isPaused = false
        isBusy = false
        lastSegmentFailed = false
        countdownCancelled = false
        markers = []
        cameraFailed = false
        cameraOverlay = nil
        let cfg = ConfigStore.shared.config.snap.record
        // 录之前再过一次权限:长时间挂着时系统可能已经撤销
        guard ScreenPermission.ensure() else { return }
        if cfg.microphone, !(await MicPermission.ensure()) { throw CocoaError(.fileReadNoPermission) }
        guard await Self.diskSpaceOK() else { return }

        let dir = Self.outputDirectory()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.screen = screen
        self.rect = rect
        self.windowID = windowID
        windowFrame = windowID.flatMap { CGWindowGeometry.cocoaFrame(of: $0) } ?? rect
        gifMode = gif

        let own = content.applications.filter { $0.processID == getpid() }
        if let windowID, let win = content.windows.first(where: { $0.windowID == windowID }) {
            filter = SCContentFilter(desktopIndependentWindow: win)
        } else {
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        }

        accumulated = 0
        segments = []
        finalURL = RecordUtil.uniqueURL(in: dir, stem: RecordUtil.fileStem(Date()), ext: cfg.container)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopBar-Rec-\(UUID().uuidString)", isDirectory: true)

        // 倒计时:留出切窗口、摆好界面、对准鼠标的时间,这段不进片子
        if cfg.countdown > 0 {
            let ok = await runCountdown(seconds: cfg.countdown)
            if !ok {
                isRecording = false
                filter = nil
                finalURL = nil
                self.rect = nil
                self.windowID = nil
                windowFrame = nil
                cleanupTemp()
                return
            }
            // 倒计时的这几秒里用户可能已经把窗口挪好了,重新读一次
            if let windowID { windowFrame = CGWindowGeometry.cocoaFrame(of: windowID) ?? windowFrame }
        }

        if cfg.camera.enabled { await startCamera(cfg) }

        do {
            try await startSegment()
        } catch {
            await stopCamera()
            cleanupTemp()
            isRecording = false
            throw error
        }
        isRecording = true
        startedAt = Date()
        showUI()
        startTimer()
        startClickRecording()
        NotificationCenter.default.post(name: Self.stateChanged, object: self)
    }

    /// 倒计时期间再按一次热键 / Esc 可取消
    func cancelCountdown() { countdownCancelled = true }

    var isCountingDown: Bool { countdownPanel != nil }

    /// 在录制区中央显示大号倒数;返回 false = 用户取消
    private func runCountdown(seconds: Int) async -> Bool {
        let area = recordArea ?? screen?.frame ?? .zero
        let p = RecordCountdownPanel(rect: area, seconds: seconds)
        countdownPanel = p
        p.orderFrontRegardless()
        defer {
            p.orderOut(nil)
            p.close()
            countdownPanel = nil
        }
        for n in stride(from: seconds, through: 1, by: -1) {
            if countdownCancelled { return false }
            p.setNumber(n)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return !countdownCancelled
    }

    // MARK: 摄像头

    private func startCamera(_ cfg: RecordConfig) async {
        guard await CameraPermission.ensure() else {
            cameraOverlay = nil
            return
        }
        let device = CameraPermission.device(matching: cfg.camera.device)
        let aspect = device.map { CameraPermission.aspect($0) } ?? 4.0 / 3.0
        let size = RecordCameraLayout.panelSize(width: CGFloat(cfg.camera.size), aspect: aspect)
        let area = recordArea ?? screen?.frame ?? .zero
        let ov = RecordCameraLayout.overlay(panelSize: size, area: area.size, position: cfg.camera.position)
        let sidecar = CameraSidecar(file: "camera.mov", x: ov.x, y: ov.y, width: ov.w, height: ov.h,
                                    mirror: cfg.camera.mirror)
        guard let video = finalURL,
              let layer = await camera.start(output: RecordDataStore.cameraURL(for: video),
                                             deviceID: cfg.camera.device,
                                             mirror: cfg.camera.mirror) else {
            cameraFailed = true
            cameraOverlay = nil
            return
        }
        cameraOverlay = sidecar
        let panel = RecordCameraPanel(frame: RecordCameraLayout.cocoaFrame(area: area, overlay: ov),
                                      preview: layer)
        cameraPanel = panel
        panel.orderFrontRegardless()
    }

    private func stopCamera() async {
        await camera.stop()
        cameraPanel?.orderOut(nil)
        cameraPanel?.close()
        cameraPanel = nil
        // 摄像头没写出文件就不要在旁挂数据里留引用
        if let video = finalURL, let cam = cameraOverlay {
            let u = RecordDataStore.cameraURL(for: video)
            if !FileManager.default.fileExists(atPath: u.path)
                || RecordUtil.fileSize(u) < 1024 { cameraOverlay = nil }
            _ = cam
        }
    }

    // MARK: 标记点与点击

    /// 打一个标记点(热键 / 面板按钮)
    func addMarker() {
        guard isRecording, !isPaused else { return }
        markers.append(RecordMarker(t: duration))
        panel?.setMarkerCount(markers.count)
    }

    private func startClickRecording() {
        clickRecorder.durationProvider = { [weak self] in
            guard let self, self.isRecording, !self.isPaused else { return -1 }
            return self.duration
        }
        clickRecorder.areaProvider = { [weak self] in self?.currentClickArea() }
        clickRecorder.ownRectsProvider = { [weak self] in self?.ownUIRects() ?? [] }
        clickRecorder.start()
    }

    /// 点击换算用的录制区。跟随窗口时实时取窗口 frame —— 轮询间隔内的移动也能算准。
    private func currentClickArea() -> CGRect? {
        if let windowID { return CGWindowGeometry.cocoaFrame(of: windowID) }
        if let rect { return rect }
        return screen?.frame
    }

    /// PopBar 自己的窗口:落在这些区域里的点击不算画面内的点击
    private func ownUIRects() -> [CGRect] {
        var rects: [CGRect] = []
        if let panel, panel.isVisible { rects.append(panel.frame) }
        // 红框(border)和倒计时层的 frame 覆盖整个录制区且忽略鼠标,不能算「自己的 UI」,
        // 否则区域内的点击会被全部丢掉

        if let cameraPanel, cameraPanel.isVisible { rects.append(cameraPanel.frame) }
        return rects
    }

    /// 录制区:Cocoa 全局坐标
    private var recordArea: CGRect? {
        if windowID != nil { return windowFrame }
        if let rect { return rect }
        return screen?.frame
    }

    /// 成片像素尺寸(与 SCStreamConfiguration 保持一致)
    private func videoPixelSize() -> CGSize {
        let cfg = ConfigStore.shared.config.snap.record
        let scale = CGFloat(cfg.scale == 1 ? 1 : 2)
        let area = recordArea ?? .zero
        return CGSize(width: RecordUtil.evenPixel(area.width * scale),
                      height: RecordUtil.evenPixel(area.height * scale))
    }

    // MARK: 停止 / 暂停

    func stop() {
        guard isRecording, !finishing, !isBusy else { return }
        Task { @MainActor in await stopAndSave(interrupted: false) }
    }

    func togglePause() { isPaused ? resume() : pause() }

    func pause() {
        guard isRecording, !isPaused, !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            await stopSegment()
            guard isRecording else { return }   // 等待期间已被 stop() 收尾,别写残留状态
            accumulated += Date().timeIntervalSince(startedAt)
            isPaused = true
            border?.setPaused(true)
            panel?.update(duration: accumulated, paused: true)
            NotificationCenter.default.post(name: Self.stateChanged, object: self)
        }
    }

    func resume() {
        guard isRecording, isPaused, !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await startSegment()
                guard isRecording else {
                    // 起段期间会话被异常收尾(如 didStopWithError):停掉刚起的孤儿段并删掉它的文件
                    try? await self.stream?.stopCapture()
                    if let orphan = segments.last {
                        try? FileManager.default.removeItem(at: orphan)
                    }
                    return
                }
                startedAt = Date()
                isPaused = false
                border?.setPaused(false)
                NotificationCenter.default.post(name: Self.stateChanged, object: self)
            } catch {
                NSSound.beep()
                await stopAndSave(interrupted: true)
            }
        }
    }

    func hidePanel() {
        BarTooltip.shared.hide()   // 面板按钮悬停提示是独立浮窗,不随面板收掉
        panel?.orderOut(nil)
    }

    /// 面板被用户隐藏(可经菜单「显示录制面板」找回)
    var hasHiddenPanel: Bool { panel != nil && panel?.isVisible == false }

    func showPanel() {
        panel?.orderFrontRegardless()
    }

    /// App 退出时同步收尾,保证 moov 写完
    func stopSynchronously() {
        guard isRecording else { return }
        camera.stopSynchronously()
        clickRecorder.stop()
        let clicks = clickRecorder.clicks
        stream?.stopCapture(completionHandler: nil)
        let deadline = Date().addingTimeInterval(3)
        while !segmentFinished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let total = duration
        let fm = FileManager.default
        var saved: [URL] = []
        if let dest = finalURL, fm.fileExists(atPath: dest.path) { saved.append(dest) }
        // 暂停过的额外片段无法同步走合并,移到输出目录保留,不丢数据
        if let dest = finalURL {
            let dir = dest.deletingLastPathComponent()
            let stem = dest.deletingPathExtension().lastPathComponent
            for (i, seg) in segments.dropFirst().enumerated() where fm.fileExists(atPath: seg.path) {
                let target = RecordUtil.uniqueURL(in: dir, stem: "\(stem)-part\(i + 2)", ext: seg.pathExtension)
                if let moved = move(seg, to: target) { saved.append(moved) }
            }
        }
        for url in saved { RecordHistory.shared.add(url: url, duration: total) }
        // 旁挂数据也落盘,退出后重开还能导出点击涟漪
        if let first = saved.first {
            var sidecar = RecordSidecar()
            sidecar.videoPath = first.path
            sidecar.duration = total
            sidecar.clicks = clicks
            sidecar.markers = markers
            sidecar.micEnabled = ConfigStore.shared.config.snap.record.microphone
            sidecar.camera = cameraOverlay
            RecordDataStore.save(sidecar, for: first)
        }
        isRecording = false
        isPaused = false
        hideUI()
        cameraPanel?.orderOut(nil)
        cameraPanel?.close()
        cameraPanel = nil
        stream = nil
        output = nil
        cleanupTemp()
    }

    // MARK: 内部

    private func startSegment() async throws {
        guard let filter, let finalURL else { throw CocoaError(.fileNoSuchFile) }
        let cfg = ConfigStore.shared.config.snap.record
        let stream = SCStream(filter: filter, configuration: makeConfiguration(), delegate: self)
        let outCfg = SCRecordingOutputConfiguration()
        let url: URL
        if segments.isEmpty {
            url = finalURL
        } else {
            let dir = tempDir ?? finalURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("seg-\(segments.count + 1).\(cfg.container)")
        }
        outCfg.outputURL = url
        outCfg.videoCodecType = cfg.codec == "hevc" ? .hevc : .h264
        outCfg.outputFileType = cfg.container == "mp4" ? .mp4 : .mov
        let out = SCRecordingOutput(configuration: outCfg, delegate: self)
        try stream.addRecordingOutput(out)
        segmentFinished = false
        self.stream = stream
        self.output = out
        try await stream.startCapture()
        lastAppliedSize = videoPixelSize()
        segments.append(url)
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let cfg = ConfigStore.shared.config.snap.record
        let c = SCStreamConfiguration()
        let size = videoPixelSize()
        c.width = Int(size.width)
        c.height = Int(size.height)
        // 跟随窗口时用 desktopIndependentWindow,窗口位置由 SCK 自己跟,
        // 这时候不能再设 sourceRect(那是相对 display 的裁剪)
        if windowID == nil, let rect, let frame = screen?.frame {
            c.sourceRect = RecordUtil.sourceRect(global: rect, screenFrame: frame)
        }
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cfg.fps))
        c.showsCursor = cfg.showsCursor
        c.capturesAudio = cfg.systemAudio
        c.excludesCurrentProcessAudio = true     // 不录 PopBar 自己的声音
        c.queueDepth = 5
        c.captureResolution = .best
        if cfg.microphone {
            c.captureMicrophone = true
            if let id = MicPermission.deviceID(matching: cfg.microphoneDevice) {
                c.microphoneCaptureDeviceID = id
            }
        }
        return c
    }

    private func stopSegment() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        await waitFinish()
    }

    private func stopAndSave(interrupted: Bool) async {
        guard isRecording, !finishing else { return }
        finishing = true
        defer { finishing = false }
        if !isPaused { await stopSegment() }
        let total = duration
        isRecording = false
        isPaused = false
        // 旁挂数据要在清空状态之前抓好
        clickRecorder.stop()
        let clicks = clickRecorder.clicks
        let marks = markers
        let area = recordArea
        let pixel = videoPixelSize()
        await stopCamera()               // 用得到 finalURL,必须早于清空
        let cam = cameraOverlay
        hideUI()
        NotificationCenter.default.post(name: Self.stateChanged, object: self)

        let urls = segments
        let dest = finalURL
        let temp = tempDir
        let wasGIF = gifMode
        let usedWindow = windowID
        segments = []
        finalURL = nil
        tempDir = nil
        stream = nil
        output = nil
        accumulated = 0
        gifMode = false
        windowID = nil
        windowFrame = nil
        markers = []
        cameraOverlay = nil

        var result: URL?
        if let dest, !urls.isEmpty {
            result = urls.count == 1 ? move(urls[0], to: dest) : await merge(urls, to: dest, temp: temp)
        }
        cleanup(temp)

        guard let file = result else {
            NSSound.beep()
            RecordNotify.fallback(dest ?? URL(fileURLWithPath: NSHomeDirectory()),
                                  text: L10n.t("录屏文件写入失败", "Failed to write the recording"))
            return
        }
        if wasGIF {
            await GIFExportController.shared.run(url: file, params: .auto, deleteSource: true, duration: total)
            return
        }

        var sidecar = RecordSidecar()
        sidecar.videoPath = file.path
        sidecar.duration = total
        sidecar.videoWidth = Int(pixel.width)
        sidecar.videoHeight = Int(pixel.height)
        sidecar.areaRect = area.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
        sidecar.windowID = usedWindow
        sidecar.micEnabled = ConfigStore.shared.config.snap.record.microphone
        sidecar.clicks = clicks
        sidecar.markers = marks
        sidecar.camera = cam
        RecordDataStore.save(sidecar, for: file)

        RecordHistory.shared.add(url: file, duration: total)
        let cfg = ConfigStore.shared.config.snap.record
        if cfg.copyToClipboard { PasteboardGuard.write(urls: [file]) }
        if cameraFailed {
            FloatingBarController.shared.showResult(
                L10n.t("摄像头不可用,本次只录了屏幕", "Camera unavailable; only the screen was recorded"))
        }
        // 开了自动导出就按当前导出参数直接出成品,不再单独发「已保存」通知
        if cfg.export.autoExport {
            var params = RecordExportParams()
            params.width = cfg.export.width
            params.quality = cfg.export.quality
            params.container = cfg.export.container
            params.systemVolume = cfg.export.systemVolume
            params.micVolume = cfg.export.micVolume
            params.burnClicks = cfg.click.enabled
            params.click = cfg.click
            params.watermark = cfg.watermark
            params.clicks = clicks
            params.micEnabled = sidecar.micEnabled
            params.copyToClipboard = cfg.export.copyToClipboard
            params.camera = cam
            params.cameraURL = cam == nil ? nil : RecordDataStore.cameraURL(for: file)
            await RecordExportController.shared.runAutomatic(url: file, params: params)
            return
        }
        RecordNotify.saved(file, duration: total, interrupted: interrupted || lastSegmentFailed)
    }

    private func move(_ src: URL, to dest: URL) -> URL? {
        let fm = FileManager.default
        if src.standardizedFileURL == dest.standardizedFileURL {
            return fm.fileExists(atPath: src.path) ? dest : nil
        }
        try? fm.removeItem(at: dest)
        do { try fm.moveItem(at: src, to: dest); return dest } catch { return nil }
    }

    /// 分段录制(暂停过)→ AVMutableComposition 拼接导出
    private func merge(_ urls: [URL], to dest: URL, temp: URL?) async -> URL? {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var audioTracks: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero
        for u in urls {
            let asset = AVURLAsset(url: u)
            let dur = (try? await asset.load(.duration)) ?? .zero
            guard dur.isValid, dur.seconds > 0 else { continue }
            let range = CMTimeRange(start: .zero, duration: dur)
            if let t = try? await asset.loadTracks(withMediaType: .video).first {
                try? video.insertTimeRange(range, of: t, at: cursor)
            }
            let audios = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            for (i, a) in audios.enumerated() {
                while audioTracks.count <= i {
                    if let track = composition.addMutableTrack(withMediaType: .audio,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) {
                        audioTracks.append(track)
                    } else { break }
                }
                guard i < audioTracks.count else { break }
                try? audioTracks[i].insertTimeRange(range, of: a, at: cursor)
            }
            cursor = cursor + dur
        }
        guard cursor.seconds > 0 else { return nil }

        let fileType: AVFileType = ConfigStore.shared.config.snap.record.container == "mp4" ? .mp4 : .mov
        let presets = AVAssetExportSession.allExportPresets()
        let tmp = (temp ?? dest.deletingLastPathComponent())
            .appendingPathComponent("merged.\(ConfigStore.shared.config.snap.record.container)")
        try? FileManager.default.removeItem(at: tmp)
        // 各段编码参数一致,优先 passthrough(不重编码);失败再退回转码
        if presets.contains(AVAssetExportPresetPassthrough),
           let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
           await runExport(exporter, to: tmp, as: fileType) {
            return replace(dest, with: tmp)
        }
        if let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality),
           await runExport(exporter, to: tmp, as: fileType) {
            return replace(dest, with: tmp)
        }
        try? FileManager.default.removeItem(at: tmp)
        return nil
    }

    private func runExport(_ exporter: AVAssetExportSession, to url: URL, as fileType: AVFileType) async -> Bool {
        do { try await exporter.export(to: url, as: fileType); return true } catch { return false }
    }

    private func replace(_ dest: URL, with tmp: URL) -> URL {
        let fm = FileManager.default
        do {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            return dest
        } catch {
            try? fm.removeItem(at: dest)
            try? fm.moveItem(at: tmp, to: dest)
            return dest
        }
    }

    // MARK: UI

    private func showUI() {
        guard let screen else { return }
        let r = recordArea ?? screen.frame
        let b = RecordBorderWindow(rect: r)
        let p = RecordPanel(selection: r, screen: screen,
                            onPause: mainClosure { Self.shared.togglePause() },
                            onMarker: mainClosure { Self.shared.addMarker() },
                            onHide: mainClosure { Self.shared.hidePanel() },
                            onStop: mainClosure { Self.shared.stop() })
        border = b
        panel = p
        update(0)
        p.setMarkerCount(markers.count)
        b.orderFrontRegardless()
        p.orderFrontRegardless()
    }

    private func hideUI() {
        timer?.invalidate()
        timer = nil
        BarTooltip.shared.hide()   // 按钮悬停提示是独立浮窗,不随面板收掉
        let old: [NSPanel?] = [panel, border]
        panel = nil
        border = nil
        old.forEach { $0?.orderOut(nil) }
        DispatchQueue.main.async { old.forEach { $0?.close() } }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in Self.shared.tick() }
        }
    }

    private func update(_ d: TimeInterval) {
        panel?.update(duration: d, paused: isPaused)
    }

    private func tick() {
        guard isRecording, !isPaused else { return }
        followWindow()
        let d = duration
        update(d)
        NotificationCenter.default.post(name: Self.ticked, object: self,
                                        userInfo: ["duration": d])
        var limit = ConfigStore.shared.config.snap.record.maxDuration
        if gifMode { limit = limit > 0 ? min(limit, 30) : 30 }
        if limit > 0, d >= Double(limit) { stop() }
    }

    /// 跟随窗口:窗口动了就重设输出尺寸与红框;窗口没了就按中断收尾
    private func followWindow() {
        guard let windowID else { return }
        guard let frame = CGWindowGeometry.cocoaFrame(of: windowID) else {
            // 窗口被关闭 / 最小化:CGS 里查不到了,保存已录部分
            Task { @MainActor in await stopAndSave(interrupted: true) }
            return
        }
        windowFrame = frame
        border?.move(to: frame)
        let size = videoPixelSize()
        guard size != lastAppliedSize else { return }
        guard let stream else { return }
        lastAppliedSize = size
        let cfg = makeConfiguration()
        Task { @MainActor in try? await stream.updateConfiguration(cfg) }
    }

    private func cleanupTemp() { cleanup(tempDir); tempDir = nil }

    private func cleanup(_ dir: URL?) {
        guard let dir else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: 目录与磁盘

    private static func outputDirectory() -> URL {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: (ConfigStore.shared.config.snap.saveDir as NSString).expandingTildeInPath,
                      isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue, fm.isWritableFile(atPath: dir.path) {
            return dir
        }
        if (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
           fm.isWritableFile(atPath: dir.path) {
            return dir
        }
        Task { @MainActor in
            RecordNotify.fallback(URL(fileURLWithPath: NSHomeDirectory()),
                                  text: L10n.t("录屏保存目录不可用,已改存到桌面", "Recording folder unavailable; saved to Desktop"))
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// 剩余空间 < 500 MB 时提示,用户可继续
    private static func diskSpaceOK() async -> Bool {
        let dir = URL(fileURLWithPath: (ConfigStore.shared.config.snap.saveDir as NSString).expandingTildeInPath,
                      isDirectory: true)
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, free < 500 * 1024 * 1024 else { return true }
        return await MainActor.run {
            let a = NSAlert()
            a.messageText = L10n.t("磁盘空间不足", "Low Disk Space")
            a.informativeText = String(
                format: L10n.t("剩余约 %@,录制可能提前中断。", "About %@ free; recording may stop early."),
                RecordUtil.byteText(free))
            a.addButton(withTitle: L10n.t("继续", "Continue"))
            a.addButton(withTitle: L10n.t("取消", "Cancel"))
            NSApp.activateForUI()
            return a.runModal() == .alertFirstButtonReturn
        }
    }

    // MARK: 等待片段写完

    /// 可能同时有多个等待者(例如暂停未完成时又点了停止),所以按数组管理
    private func waitFinish() async {
        if segmentFinished { return }
        finishGeneration += 1
        let gen = finishGeneration
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finishWaits.append(c)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)   // 兜底:5s 后不再等
                // 只放行本代的等待者;新段已开等时,旧任务不得越权唤醒
                if Self.shared.finishGeneration == gen { Self.shared.resumeFinishWaits() }
            }
        }
    }

    private func signalFinish() {
        segmentFinished = true
        resumeFinishWaits()
    }

    private func resumeFinishWaits() {
        let waits = finishWaits
        finishWaits = []
        waits.forEach { $0.resume() }
    }

    // MARK: SCStreamDelegate / SCRecordingOutputDelegate

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in Self.shared.signalFinish() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            Self.shared.lastSegmentFailed = true
            Self.shared.signalFinish()
        }
    }

    /// 显示器拔出、权限被撤销等情况:保存已录部分并提示
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            Self.shared.signalFinish()
            guard Self.shared.isRecording else { return }
            await Self.shared.stopAndSave(interrupted: true)
        }
    }
}
