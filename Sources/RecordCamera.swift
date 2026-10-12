import Cocoa
@preconcurrency import AVFoundation

// MARK: - 布局(纯逻辑,便于测试)

/// 摄像头预览窗与成品叠加层的位置计算。
/// 归一化坐标一律 **左上原点**,和 RecordExportUtil.layerRect / renderRect 保持同一约定。
enum RecordCameraLayout {
    /// 预览窗尺寸:宽度取配置值,高度按摄像头画幅比
    static func panelSize(width: CGFloat, aspect: CGFloat) -> CGSize {
        let w = max(width, 64)
        let a = aspect > 0.01 ? aspect : 4.0 / 3.0
        return CGSize(width: w, height: (w / a).rounded())
    }

    /// 在录制区里按角落摆放,返回归一化矩形(左上原点)
    static func overlay(panelSize: CGSize, area: CGSize, position: String,
                        margin: Double = 0.02) -> (x: Double, y: Double, w: Double, h: Double) {
        let aw = max(Double(area.width), 1), ah = max(Double(area.height), 1)
        let w = min(Double(panelSize.width) / aw, 1)
        let h = min(Double(panelSize.height) / ah, 1)
        let m = margin
        let x: Double, y: Double
        switch position {
        case "bottomLeft":  x = m; y = max(1 - m - h, 0)
        case "topLeft":     x = m; y = m
        case "topRight":    x = max(1 - m - w, 0); y = m
        default:            x = max(1 - m - w, 0); y = max(1 - m - h, 0)
        }
        return (x, y, w, h)
    }

    /// 归一化矩形(左上原点)→ Cocoa 全局坐标(左下原点),用于摆放真实面板
    static func cocoaFrame(area: CGRect, overlay: (x: Double, y: Double, w: Double, h: Double)) -> CGRect {
        CGRect(x: area.minX + CGFloat(overlay.x) * area.width,
               y: area.minY + (1 - CGFloat(overlay.y) - CGFloat(overlay.h)) * area.height,
               width: CGFloat(overlay.w) * area.width,
               height: CGFloat(overlay.h) * area.height)
    }
}

// MARK: - 权限与设备

enum CameraPermission {
    static func ensure() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: .video) { c.resume(returning: $0) }
            }
        case .denied, .restricted:
            await MainActor.run { denyAlert() }
            return false
        @unknown default:
            return false
        }
    }

    static func devices() -> [(id: String, name: String)] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        return session.devices.map { (id: $0.uniqueID, name: $0.localizedName) }
    }

    static func device(matching nameOrID: String) -> AVCaptureDevice? {
        if !nameOrID.isEmpty,
           let d = AVCaptureDevice(uniqueID: nameOrID) { return d }
        let list = devices()
        if !nameOrID.isEmpty, let hit = list.first(where: { $0.name == nameOrID }) {
            return AVCaptureDevice(uniqueID: hit.id)
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// 画幅比(宽/高);拿不到格式时按 4:3
    static func aspect(_ device: AVCaptureDevice) -> CGFloat {
        let dim = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dim.width > 0, dim.height > 0 else { return 4.0 / 3.0 }
        return CGFloat(dim.width) / CGFloat(dim.height)
    }

    @MainActor private static func denyAlert() {
        let a = NSAlert()
        a.messageText = L10n.t("需要「摄像头」权限", "Camera Permission Required")
        a.informativeText = L10n.t(
            "录制摄像头画中画需要摄像头权限。\n请在 系统设置 → 隐私与安全性 → 摄像头 中允许 PopBar。",
            "Camera picture-in-picture needs camera access.\nPlease allow PopBar in System Settings → Privacy & Security → Camera.")
        a.addButton(withTitle: L10n.t("打开设置", "Open Settings"))
        a.addButton(withTitle: L10n.t("取消", "Cancel"))
        NSApp.activateForUI()
        if a.runModal() == .alertFirstButtonReturn,
           let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: - 采集

/// 摄像头旁挂录制:画面同时喂给预览层和 AVCaptureMovieFileOutput,
/// 停止后文件落在 RecordDataStore 的旁挂目录里,导出时再合成到成品上。
@MainActor
final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    private var session: AVCaptureSession?
    private var output: AVCaptureMovieFileOutput?
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    private(set) var isRunning = false
    private(set) var outputURL: URL?
    /// 录制结束时间超过这个秒数还没等到 delegate 回调,就当作已收尾,避免卡死
    private var finishWait: CheckedContinuation<Void, Never>?

    /// 启动采集并开始写文件;失败返回 nil
    func start(output url: URL, deviceID: String?, mirror: Bool) async -> AVCaptureVideoPreviewLayer? {
        await stop()
        guard let device = CameraPermission.device(matching: deviceID ?? "") else { return nil }
        let s = AVCaptureSession()
        s.beginConfiguration()
        s.sessionPreset = .high
        guard let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input) else {
            s.commitConfiguration(); return nil
        }
        s.addInput(input)
        let out = AVCaptureMovieFileOutput()
        guard s.canAddOutput(out) else { s.commitConfiguration(); return nil }
        s.addOutput(out)
        // 必须在 startRunning 之前提交配置:会话仍处于 begin 状态时启动会抛 ObjC 异常直接闪退
        s.commitConfiguration()
        Self.applyMirror(mirror, to: out.connection(with: .video))

        let layer = AVCaptureVideoPreviewLayer(session: s)
        layer.videoGravity = .resizeAspectFill
        Self.applyMirror(mirror, to: layer.connection)

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        session = s
        output = out
        previewLayer = layer
        outputURL = url
        await Self.run(s, start: true)
        guard s.isRunning else {
            session = nil; output = nil; previewLayer = nil
            return nil
        }
        isRunning = true
        out.startRecording(to: url, recordingDelegate: self)
        return layer
    }

    /// 停止并等待文件写完(带超时兜底)
    func stop() async {
        guard let s = session else { return }
        if let out = output, out.isRecording {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                finishWait = c
                out.stopRecording()
                Task { @MainActor in
                    // delegate 迟迟不来时兜底唤醒,别把收尾流程卡死
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.resumeFinish()
                }
            }
        }
        isRunning = false
        await Self.run(s, start: false)
        session = nil
        output = nil
        previewLayer = nil
    }

    /// App 退出路径:不等 delegate,尽量让文件可播放
    func stopSynchronously() {
        output?.stopRecording()
        if let s = session {
            DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
        }
        isRunning = false
        resumeFinish()
    }

    /// 幂等:delegate 与超时兜底谁先到都行
    private func resumeFinish() {
        finishWait?.resume()
        finishWait = nil
    }

    private static func applyMirror(_ mirror: Bool, to connection: AVCaptureConnection?) {
        guard let c = connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = mirror
    }

    private static func run(_ s: AVCaptureSession, start: Bool) async {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                if start { s.startRunning() } else { s.stopRunning() }
                c.resume()
            }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor [weak self] in self?.resumeFinish() }
    }
}

// MARK: - 预览窗

/// 录制中的摄像头预览:位置与成品里画中画的位置一致,所见即所得。
/// 本进程窗口已被 SCContentFilter 排除,不会录进画面。
final class RecordCameraPanel: NSPanel {
    init(frame: CGRect, preview: AVCaptureVideoPreviewLayer) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let host = NSView(frame: CGRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 2
        host.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        host.layer?.backgroundColor = NSColor.black.cgColor
        preview.frame = host.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        host.layer?.addSublayer(preview)
        contentView = host
    }

    override var canBecomeKey: Bool { false }
}
