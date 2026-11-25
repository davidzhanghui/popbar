import AppKit
@preconcurrency import AVFoundation
import CMetrics
import Foundation
import IOKit
import IOKit.usb
import LocalAuthentication
import PopBarCore
import PopBarDesign
import SwiftUI

// MARK: - 1. 扬声器 / 耳机声道测试（纯内存合成正弦波，零音频文件）

@MainActor
final class MCAudioToneModel: ObservableObject {
    enum Channel: String, CaseIterable {
        case left, right, stereo
        var title: String {
            switch self {
            case .left: return L10n.t("左声道（440 Hz）", "Left (440 Hz)")
            case .right: return L10n.t("右声道（523 Hz）", "Right (523 Hz)")
            case .stereo: return L10n.t("立体声双通道", "Stereo Both")
            }
        }
    }

    @Published var playing: Channel?
    private var engine: AVAudioEngine?
    private var stopWork: DispatchWorkItem?

    func play(_ ch: Channel) {
        stop()
        let eng = AVAudioEngine()
        let format = eng.mainMixerNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44100.0
        let leftFreq: Double = 440.0
        let rightFreq: Double = 523.25
        var phaseL: Double = 0
        var phaseR: Double = 0
        let incL = 2.0 * .pi * leftFreq / sampleRate
        let incR = 2.0 * .pi * rightFreq / sampleRate

        let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let channelCount = abl.count
            for frame in 0..<Int(frameCount) {
                let sL = Float(sin(phaseL) * 0.22)
                let sR = Float(sin(phaseR) * 0.22)
                phaseL += incL
                phaseR += incR
                for chIdx in 0..<channelCount {
                    guard let ptr = abl[chIdx].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    switch ch {
                    case .left: ptr[frame] = (chIdx == 0) ? sL : 0
                    case .right: ptr[frame] = (chIdx == 1 || channelCount == 1) ? sR : 0
                    case .stereo: ptr[frame] = (chIdx == 0) ? sL : sR
                    }
                }
            }
            return noErr
        }

        eng.attach(source)
        eng.connect(source, to: eng.mainMixerNode, format: format)
        do {
            try eng.start()
            self.engine = eng
            self.playing = ch
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            self.stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
        } catch {
            self.playing = nil
        }
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        engine?.stop()
        engine = nil
        playing = nil
    }
}

struct MCAudioTestView: View {
    @StateObject private var model = MCAudioToneModel()
    let onComplete: (MCCheckItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("依次播放左声道、右声道与双声道纯音，确认无破音、杂音或单侧无声。",
                        "Play left, right and stereo tones to verify clear output without distortion or dead channels."))
                .font(DS.body).foregroundStyle(DS.muted)

            HStack(spacing: 10) {
                ForEach(MCAudioToneModel.Channel.allCases, id: \.self) { ch in
                    let active = model.playing == ch
                    DSButton(ch.title, icon: active ? "stop-circle" : "volume-2", kind: active ? .primary : .secondary) {
                        if active { model.stop() } else { model.play(ch) }
                    }
                }
            }

            DSDivider(inset: 0)
            HStack(spacing: 10) {
                DSButton(L10n.t("双声道清晰正常", "Audio Normal"), icon: "check", kind: .primary) {
                    model.stop()
                    onComplete(MCCheckItem(
                        id: MCInteractiveKind.audio.resultID,
                        category: .interactive,
                        title: MCInteractiveKind.audio.title,
                        status: .pass,
                        summary: L10n.t("左右声道发音正常，无破音或杂音", "Left & right speakers clean with no distortion")
                    ))
                }
                DSButton(L10n.t("存在异常或破音", "Audio Issue"), kind: .danger) {
                    model.stop()
                    onComplete(MCCheckItem(
                        id: MCInteractiveKind.audio.resultID,
                        category: .interactive,
                        title: MCInteractiveKind.audio.title,
                        status: .warning,
                        summary: L10n.t("用户反馈扬声器存在破音、杂音或单侧无声", "User reported speaker distortion or dead channel")
                    ))
                }
            }
        }
        .onDisappear { model.stop() }
    }
}

// MARK: - 2. 麦克风测试（实时电平 + 内存 3 秒录音回放，零临时文件）

@MainActor
final class MCMicTestModel: ObservableObject {
    @Published var level: Double = 0
    @Published var isMonitoring = false
    @Published var isRecording = false
    @Published var isPlayingBack = false
    @Published var hasRecording = false
    @Published var permissionDenied = false

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var recordedChunks: [AVAudioPCMBuffer] = []
    private var recordedFormat: AVAudioFormat?
    private var recordWork: DispatchWorkItem?
    private var lastLevelUpdate: TimeInterval = 0

    func startMonitor() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if !granted {
                    self.permissionDenied = true
                    return
                }
                self.permissionDenied = false
                self.beginEngine()
            }
        }
    }

    private func beginEngine() {
        stop()
        let eng = AVAudioEngine()
        let input = eng.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else { return }
        recordedFormat = fmt

        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(n))
            let db = max(-60, 20 * log10(max(rms, 1e-6)))
            let norm = Double((db + 60) / 60)

            // 拷贝用于录音缓冲（仅在录音阶段拷贝）
            let copyBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: buf.frameLength)
            if let copyBuf {
                copyBuf.frameLength = buf.frameLength
                if let dst = copyBuf.floatChannelData?[0] {
                    memcpy(dst, ch, n * MemoryLayout<Float>.size)
                }
            }

            let now = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isRecording, let copyBuf {
                    self.recordedChunks.append(copyBuf)
                }
                if now - self.lastLevelUpdate >= 0.06 {
                    self.lastLevelUpdate = now
                    self.level = norm
                }
            }
        }

        do {
            try eng.start()
            engine = eng
            isMonitoring = true
        } catch {
            isMonitoring = false
        }
    }

    func recordThreeSeconds() {
        if !isMonitoring { startMonitor() }
        recordedChunks.removeAll()
        hasRecording = false
        isRecording = true
        recordWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isRecording = false
            self.hasRecording = !self.recordedChunks.isEmpty
        }
        recordWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    func playBack() {
        guard let fmt = recordedFormat, !recordedChunks.isEmpty else { return }
        stopPlaybackOnly()
        let playEng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        playEng.attach(node)
        playEng.connect(node, to: playEng.mainMixerNode, format: fmt)
        do {
            try playEng.start()
            player = node
            isPlayingBack = true
            let total = recordedChunks.count
            nonisolated(unsafe) let engRef = playEng
            for (idx, chunk) in recordedChunks.enumerated() {
                if idx == total - 1 {
                    node.scheduleBuffer(chunk) { [weak self] in
                        Task { @MainActor in
                            self?.isPlayingBack = false
                            engRef.stop()
                        }
                    }
                } else {
                    node.scheduleBuffer(chunk)
                }
            }
            node.play()
        } catch {
            isPlayingBack = false
        }
    }

    private func stopPlaybackOnly() {
        player?.stop()
        player = nil
        isPlayingBack = false
    }

    func stop() {
        recordWork?.cancel()
        recordWork = nil
        stopPlaybackOnly()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isMonitoring = false
        isRecording = false
        level = 0
    }
}

struct MCMicTestView: View {
    @StateObject private var model = MCMicTestModel()
    let onComplete: (MCCheckItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("对着麦克风说话观察实时电平变化，或录制 3 秒语音回放检查收音清晰度。",
                        "Speak into the microphone to watch the live meter, or record a 3-second loopback clip."))
                .font(DS.body).foregroundStyle(DS.muted)

            if model.permissionDenied {
                VStack(alignment: .leading, spacing: 10) {
                    DSChip(L10n.t("麦克风权限未授权，请在系统设置中允许 PopBar 访问麦克风", "Microphone access denied; allow PopBar in System Settings"), tone: .warning, icon: "triangle-alert")
                    HStack(spacing: 8) {
                        DSButton(L10n.t("打开麦克风隐私设置", "Open Microphone Settings"), icon: "settings", kind: .secondary) {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                        DSButton(L10n.t("重新检测", "Retry"), icon: "refresh-cw", kind: .ghost) {
                            model.startMonitor()
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.t("实时输入电平", "Input Level")).font(DS.caption).foregroundStyle(DS.muted)
                        Spacer()
                        Text("\(Int((model.level * 100).rounded()))%").font(DS.mono).foregroundStyle(DS.text)
                    }
                    DSProgress(model.level, tint: model.level > 0.78 ? DS.danger : DS.success)
                }

                HStack(spacing: 10) {
                    DSButton(model.isRecording ? L10n.t("正在录制（3 秒）…", "Recording (3s)…") : L10n.t("录制 3 秒测试", "Record 3s"),
                             icon: "mic", kind: .secondary) {
                        model.recordThreeSeconds()
                    }
                    .disabled(model.isRecording)

                    DSButton(model.isPlayingBack ? L10n.t("回放中…", "Playing…") : L10n.t("回放录音", "Play Back"),
                             icon: "play", kind: .secondary) {
                        model.playBack()
                    }
                    .disabled(!model.hasRecording || model.isRecording || model.isPlayingBack)
                }
            }

            DSDivider(inset: 0)
            HStack(spacing: 10) {
                DSButton(L10n.t("收音清晰正常", "Mic Normal"), icon: "check", kind: .primary) {
                    model.stop()
                    onComplete(MCCheckItem(
                        id: MCInteractiveKind.microphone.resultID,
                        category: .interactive,
                        title: MCInteractiveKind.microphone.title,
                        status: .pass,
                        summary: L10n.t("麦克风电平响应与回放清晰正常", "Microphone input and playback verified")
                    ))
                }
                DSButton(L10n.t("收音异常或无声", "Mic Issue"), kind: .danger) {
                    model.stop()
                    onComplete(MCCheckItem(
                        id: MCInteractiveKind.microphone.resultID,
                        category: .interactive,
                        title: MCInteractiveKind.microphone.title,
                        status: .warning,
                        summary: L10n.t("用户反馈麦克风无声或存在明显底噪", "User reported silent or noisy microphone")
                    ))
                }
            }
        }
        .onAppear { model.startMonitor() }
        .onDisappear { model.stop() }
    }
}

// MARK: - 3. 摄像头测试（后台队列安全启停，离开即灭绿灯）

@MainActor
final class MCCameraTestModel: ObservableObject {
    @Published var permissionDenied = false
    @Published var running = false
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "popbar.maccheck.camera", qos: .userInitiated)
    private var configured = false

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.permissionDenied = true
                    return
                }
                self.permissionDenied = false
                nonisolated(unsafe) let s = self.session
                let already = self.configured
                self.configured = true
                self.queue.async {
                    if !already {
                        s.beginConfiguration()
                        s.sessionPreset = .high
                        if let dev = AVCaptureDevice.default(for: .video),
                           let input = try? AVCaptureDeviceInput(device: dev),
                           s.canAddInput(input) {
                            s.addInput(input)
                        }
                        s.commitConfiguration()
                    }
                    if !s.isRunning { s.startRunning() }
                    let active = s.isRunning
                    Task { @MainActor [weak self] in self?.running = active }
                }
            }
        }
    }

    func stop() {
        nonisolated(unsafe) let s = session
        running = false
        queue.async {
            if s.isRunning { s.stopRunning() }
        }
    }
}

private struct MCCameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = layer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct MCCameraTestView: View {
    @StateObject private var model = MCCameraTestModel()
    let onComplete: (MCCheckItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("观察实时预览画面是否清晰、对焦正常，无坏点或明显色斑。离开页面会自动关闭摄像头。",
                        "Verify sharpness and check for blemishes. The camera turns off automatically when you leave."))
                .font(DS.body).foregroundStyle(DS.muted)

            if model.permissionDenied {
                VStack(alignment: .leading, spacing: 10) {
                    DSChip(L10n.t("摄像头权限被拒，请在系统设置中授权 PopBar", "Camera denied; allow PopBar in System Settings"), tone: .warning, icon: "triangle-alert")
                    HStack(spacing: 8) {
                        DSButton(L10n.t("打开摄像头隐私设置", "Open Camera Settings"), icon: "settings", kind: .secondary) {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                        DSButton(L10n.t("重新检测", "Retry"), icon: "refresh-cw", kind: .ghost) {
                            model.start()
                        }
                    }
                }
            } else {
                MCCameraPreviewView(session: model.session)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
            }

            DSDivider(inset: 0)
            HStack(spacing: 10) {
                DSButton(L10n.t("画面清晰正常", "Camera Normal"), icon: "check", kind: .primary) {
                    model.stop()
                    onComplete(MCCheckItem(
                        id: MCInteractiveKind.camera.resultID,
                        category: .interactive,
                        title: MCInteractiveKind.camera.title,
                        status: .pass,
                        summary: L10n.t("摄像头成像清晰，无坏点或色斑", "Camera preview clear and normal")
                    ))
                }
                DSButton(L10n.t("画面异常", "Camera Issue"), kind: .danger) {
                    model.stop()
                    onComplete(MCCheckItem(
                        id: MCInteractiveKind.camera.resultID,
                        category: .interactive,
                        title: MCInteractiveKind.camera.title,
                        status: .warning,
                        summary: L10n.t("用户反馈摄像头画面异常或无法开启", "User reported camera preview issue")
                    ))
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

// MARK: - 4. Touch ID 测试

struct MCTouchIDTestView: View {
    @State private var message: String = ""
    @State private var testing = false
    @State private var available = true
    let onComplete: (MCCheckItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("调用 macOS LocalAuthentication 验证 Touch ID 传感器是否正常工作。",
                        "Invoke macOS LocalAuthentication to verify the Touch ID sensor."))
                .font(DS.body).foregroundStyle(DS.muted)

            if !available {
                DSChip(message.isEmpty ? L10n.t("本机无 Touch ID 或尚未录入指纹", "Touch ID unavailable or no fingerprints enrolled") : message,
                       tone: .neutral, icon: "info")
            } else if !message.isEmpty {
                Text(message).font(DS.caption).foregroundStyle(DS.text2)
            }

            HStack(spacing: 10) {
                if available {
                    DSButton(testing ? L10n.t("等待指纹验证…", "Waiting for Touch ID…") : L10n.t("发起 Touch ID 验证", "Verify Touch ID"),
                             icon: "lock", kind: .primary) {
                        runAuth()
                    }
                    .disabled(testing)
                }

                DSButton(available ? L10n.t("跳过此项", "Skip") : L10n.t("记为不适用", "Mark Unsupported"), kind: .ghost) {
                    onComplete(MCCheckItem(
                        id: MCInteractiveKind.touchID.resultID,
                        category: .interactive,
                        title: "Touch ID",
                        status: available ? .skipped : .unsupported,
                        summary: available
                            ? L10n.t("已跳过 Touch ID 测试", "Touch ID check skipped")
                            : L10n.t("本机无 Touch ID 或未录入指纹", "No Touch ID hardware or enrolled fingerprints")
                    ))
                }
            }
        }
        .onAppear { checkAvailability() }
    }

    private func checkAvailability() {
        let ctx = LAContext()
        var err: NSError?
        if !ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) {
            available = false
            message = err?.localizedDescription ?? L10n.t("本机不支持 Touch ID 或未录入指纹", "Touch ID unavailable or no fingerprints enrolled")
        } else {
            available = true
        }
    }

    private func runAuth() {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            available = false
            message = err?.localizedDescription ?? L10n.t("设备不支持生物识别或未录入指纹", "Biometrics unavailable")
            return
        }
        testing = true
        message = L10n.t("请将手指轻放在 Touch ID 传感器上…", "Place your finger on the Touch ID sensor…")
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: L10n.t("验证 Touch ID 指纹模块是否正常", "Verify Touch ID hardware sensor")) { ok, error in
            Task { @MainActor in
                testing = false
                if ok {
                    message = L10n.t("Touch ID 验证通过", "Touch ID verified")
                    onComplete(MCCheckItem(
                        id: MCInteractiveKind.touchID.resultID,
                        category: .interactive,
                        title: "Touch ID",
                        status: .pass,
                        summary: L10n.t("Touch ID 指纹识别验证通过", "Touch ID biometric check passed")
                    ))
                } else {
                    let code = (error as? LAError)?.code
                    if code == .userCancel || code == .systemCancel || code == .appCancel {
                        message = L10n.t("已取消验证，可点击上方按钮重新尝试", "Verification cancelled; click above to try again")
                    } else {
                        let msg = error?.localizedDescription ?? L10n.t("指纹识别未通过，请重试", "Fingerprint not recognized; try again")
                        message = msg
                        onComplete(MCCheckItem(
                            id: MCInteractiveKind.touchID.resultID,
                            category: .interactive,
                            title: "Touch ID",
                            status: .warning,
                            summary: msg
                        ))
                    }
                }
            }
        }
    }
}

// MARK: - 5. 触控板测试（跟手轨迹 + 四象限点击 + Force Touch 压感 + 多指与缩放/旋转手势）

@MainActor
final class MCTrackpadModel: ObservableObject {
    @Published var trail: [CGPoint] = []
    @Published var quadrants: Set<Int> = []
    @Published var gestures: Set<String> = []   // "scroll" | "magnify" | "rotate"
    @Published var maxPressure: Double = 0
    @Published var maxFingers: Int = 0
    @Published var sawForceClick = false
    @Published var livePressure: Double = 0
    @Published var liveFingers: Int = 0

    func addTrailPoint(_ pt: CGPoint) {
        trail.append(pt)
        if trail.count > 420 { trail.removeFirst(trail.count - 420) }
    }

    func recordClick(normX: Double, normY: Double) {
        let q = (normX >= 0.5 ? 1 : 0) + (normY >= 0.5 ? 2 : 0)
        quadrants.insert(q)
    }

    func recordPressure(_ p: Double, stage: Int) {
        livePressure = p
        if p > maxPressure { maxPressure = p }
        if stage >= 2 { sawForceClick = true }
    }

    func recordTouches(_ count: Int) {
        liveFingers = count
        if count > maxFingers { maxFingers = count }
    }

    func noteGesture(_ name: String) {
        gestures.insert(name)
    }

    func reset() {
        trail.removeAll()
        quadrants.removeAll()
        gestures.removeAll()
        maxPressure = 0
        maxFingers = 0
        sawForceClick = false
        livePressure = 0
        liveFingers = 0
    }
}

private final class MCTrackpadSurfaceView: NSView {
    weak var model: MCTrackpadModel?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { appendPoint(event) }
    override func mouseDragged(with event: NSEvent) { appendPoint(event) }

    private func appendPoint(_ event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pt) else { return }
        let flipped = CGPoint(x: pt.x, y: bounds.height - pt.y)
        MainActor.assumeIsolated { model?.addTrailPoint(flipped) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let nx = Double(max(0, min(1, pt.x / bounds.width)))
        let ny = Double(max(0, min(1, pt.y / bounds.height)))
        MainActor.assumeIsolated { model?.recordClick(normX: nx, normY: ny) }
    }

    override func pressureChange(with event: NSEvent) {
        let p = Double(event.pressure)
        let s = event.stage
        MainActor.assumeIsolated { model?.recordPressure(p, stage: s) }
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > 0.2 || abs(event.scrollingDeltaY) > 0.2 {
            MainActor.assumeIsolated { model?.noteGesture("scroll") }
        }
    }

    override func magnify(with event: NSEvent) {
        MainActor.assumeIsolated { model?.noteGesture("magnify") }
    }

    override func rotate(with event: NSEvent) {
        MainActor.assumeIsolated { model?.noteGesture("rotate") }
    }

    override func swipe(with event: NSEvent) {
        MainActor.assumeIsolated { model?.noteGesture("scroll") }
    }

    override func touchesBegan(with event: NSEvent) { updateTouches(event) }
    override func touchesMoved(with event: NSEvent) { updateTouches(event) }
    override func touchesEnded(with event: NSEvent) { updateTouches(event) }
    override func touchesCancelled(with event: NSEvent) {
        MainActor.assumeIsolated { model?.recordTouches(0) }
    }

    private func updateTouches(_ event: NSEvent) {
        let n = event.touches(matching: .touching, in: self).count
        MainActor.assumeIsolated { model?.recordTouches(n) }
    }
}

private struct MCTrackpadBridge: NSViewRepresentable {
    let model: MCTrackpadModel

    func makeNSView(context: Context) -> MCTrackpadSurfaceView {
        let v = MCTrackpadSurfaceView()
        v.model = model
        return v
    }

    func updateNSView(_ nsView: MCTrackpadSurfaceView, context: Context) {
        nsView.model = model
    }
}

struct MCTrackpadTestView: View {
    @StateObject private var model = MCTrackpadModel()
    let onComplete: (MCCheckItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("在下方画布滑动画线检查跟手与断触，点击四角、用力深按测 Force Touch，并尝试双指滚动 / 捏合缩放 / 旋转。",
                            "Move or drag to inspect tracking smoothness, click all corners, deep-press for Force Touch, and test scroll / pinch / rotate."))
                    .font(DS.body).foregroundStyle(DS.muted)
                Spacer()
                DSButton(L10n.t("清除", "Clear"), kind: .ghost) { model.reset() }
            }

            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(DS.surface2)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        quadrantBox(2, L10n.t("左上角", "Top-Left"))
                        quadrantBox(3, L10n.t("右上角", "Top-Right"))
                    }
                    HStack(spacing: 0) {
                        quadrantBox(0, L10n.t("左下角", "Bottom-Left"))
                        quadrantBox(1, L10n.t("右下角", "Bottom-Right"))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                MCTrackpadBridge(model: model)

                Canvas { ctx, _ in
                    guard model.trail.count > 1 else { return }
                    var path = Path()
                    path.addLines(model.trail)
                    ctx.stroke(path, with: .color(DS.accent), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
                .allowsHitTesting(false)

                if model.livePressure > 0.05 {
                    Circle()
                        .stroke(DS.warning, lineWidth: 2.5)
                        .frame(width: 28 + model.livePressure * 56, height: 28 + model.livePressure * 56)
                        .opacity(0.65)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 200)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(DS.border, lineWidth: 1))

            HStack(spacing: 8) {
                DSChip(L10n.t("轨迹点 \(model.trail.count)", "Points \(model.trail.count)"), tone: model.trail.count > 10 ? .success : .neutral)
                DSChip(L10n.t("四象限 \(model.quadrants.count)/4", "Corners \(model.quadrants.count)/4"),
                       tone: model.quadrants.count == 4 ? .success : .neutral)
                DSChip(L10n.t("手势 \(model.gestures.count)/3", "Gestures \(model.gestures.count)/3"),
                       tone: !model.gestures.isEmpty ? .success : .neutral)
                DSChip(L10n.t("最多 \(model.maxFingers) 指", "Max \(model.maxFingers)F"),
                       tone: model.maxFingers >= 2 ? .success : .neutral)
                DSChip(L10n.t("Force Touch", "Force Touch"), tone: model.sawForceClick ? .success : .neutral)
                DSChip(String(format: L10n.t("压力 %.0f%%", "Press %.0f%%"), model.livePressure * 100), tone: .accent)
            }

            DSDivider(inset: 0)
            HStack(spacing: 10) {
                DSButton(L10n.t("跟手 / 手势 / 压感均正常", "Trackpad Normal"), icon: "check", kind: .primary) {
                    let details: [MCDetailPair] = [
                        .init(L10n.t("跟手轨迹采样", "Track Points"), "\(model.trail.count)"),
                        .init(L10n.t("四象限点击", "Corner Clicks"), "\(model.quadrants.count) / 4"),
                        .init(L10n.t("识别多指手势", "Gestures Detected"), model.gestures.isEmpty ? L10n.t("未测", "None") : model.gestures.sorted().joined(separator: "、")),
                        .init(L10n.t("最多同时指触", "Max Fingers"), "\(model.maxFingers)"),
                        .init("Force Touch", model.sawForceClick ? L10n.t("已触发", "Triggered") : L10n.t("未触发", "Not triggered")),
                    ]
                    onComplete(MCCheckItem(
                        id: MCInteractiveKind.trackpad.resultID,
                        category: .interactive,
                        title: MCInteractiveKind.trackpad.title,
                        status: .pass,
                        summary: L10n.t("跟手轨迹、点击、多指手势与压感响应正常", "Tracking, clicks, gestures and pressure verified"),
                        details: details
                    ))
                }
                DSButton(L10n.t("存在异常", "Trackpad Issue"), kind: .danger) {
                    onComplete(MCCheckItem(
                        id: MCInteractiveKind.trackpad.resultID,
                        category: .interactive,
                        title: MCInteractiveKind.trackpad.title,
                        status: .warning,
                        summary: L10n.t("用户反馈触控板漂移、断触或按压异常", "User reported trackpad tracking or click issue")
                    ))
                }
            }
        }
    }

    private func quadrantBox(_ id: Int, _ title: String) -> some View {
        let hit = model.quadrants.contains(id)
        return ZStack {
            Rectangle().fill(hit ? DS.successSoft : .clear)
            Text(hit ? "✓ \(title)" : title)
                .font(DS.caption)
                .foregroundStyle(hit ? DS.success : DS.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(Rectangle().strokeBorder(DS.border.opacity(0.6), lineWidth: 0.5))
    }
}

// MARK: - 6. CPU 性能压测（复用 CMetrics 实时温度 / 静置基线 / 算力吞吐 / 风扇）

@MainActor
final class MCStressTestModel: ObservableObject {
    @Published var running = false
    @Published var elapsedSec: Int = 0
    @Published var cpuPercent: Double = 0
    @Published var opsPerSecM: Double = 0
    @Published var idleTemp: Double?
    @Published var cpuTemp: Double?
    @Published var peakTemp: Double?
    @Published var fanRPMs: [Double] = []
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var peakThermal: ProcessInfo.ThermalState = .nominal
    @Published var finished = false

    let durationSec = 30
    private var stopFlag = AtomicFlag()
    private var opsCounter = AtomicCounter()
    private var monitorTask: Task<Void, Never>?

    deinit {
        stopFlag.set()
        monitorTask?.cancel()
    }

    private final class AtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _stopped = false
        var stopped: Bool { lock.withLock { _stopped } }
        func reset() { lock.withLock { _stopped = false } }
        func set() { lock.withLock { _stopped = true } }
    }

    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _ops: UInt64 = 0
        func add(_ n: UInt64) { lock.withLock { _ops &+= n } }
        func takeAndReset() -> UInt64 {
            lock.withLock {
                let v = _ops
                _ops = 0
                return v
            }
        }
    }

    func start() {
        guard !running else { return }
        stopFlag.reset()
        _ = opsCounter.takeAndReset()
        running = true
        finished = false
        elapsedSec = 0
        opsPerSecM = 0
        idleTemp = nil
        peakTemp = nil
        peakThermal = .nominal

        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let flag = stopFlag
        let counter = opsCounter

        monitorTask = Task { [weak self] in
            guard let self else { return }
            let sampler = cm_sampler_create()
            let snapBuf = UnsafeMutablePointer<CMSnapshot>.allocate(capacity: 1)
            UnsafeMutableRawPointer(snapBuf).initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<CMSnapshot>.size)
            defer {
                if let sampler { cm_sampler_destroy(sampler) }
                snapBuf.deallocate()
            }
            // 先采一次静置基线温度，再启动全核计算线程
            if let sampler, cm_sampler_poll_ex(sampler, snapBuf, CM_POLL_SLOW) == 0 {
                let t = snapBuf.pointer(to: \.temp)!.pointee
                if t.have_cpu != 0 {
                    self.idleTemp = t.cpu_temp
                    self.cpuTemp = t.cpu_temp
                }
            }

            for _ in 0..<cores {
                DispatchQueue.global(qos: .userInitiated).async {
                    var x = 1.000_000_1
                    var y = 0.999_999_9
                    let batch: UInt64 = 100_000
                    while !flag.stopped {
                        for _ in 0..<batch {
                            x = x * 1.000_000_3 + x.squareRoot()
                            y = y * 0.999_999_7 + 0.000_001
                            if x > 1e6 || x < -1e6 { x = 1.000_000_1 }
                        }
                        counter.add(batch)
                    }
                    _ = x + y
                }
            }

            let startAt = ProcessInfo.processInfo.systemUptime
            var lastTick = startAt
            while !Task.isCancelled && self.running {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled && self.running else { break }
                let now = ProcessInfo.processInfo.systemUptime
                let dt = max(0.1, now - lastTick)
                lastTick = now
                let deltaOps = counter.takeAndReset()
                self.opsPerSecM = (Double(deltaOps) / dt) / 1_000_000.0

                if let sampler, cm_sampler_poll_ex(sampler, snapBuf, CM_POLL_SLOW) == 0 {
                    let cpuPct = snapBuf.pointer(to: \.cpu.package_percent)!.pointee
                    let tempSample = snapBuf.pointer(to: \.temp)!.pointee
                    let sensorSample = snapBuf.pointer(to: \.sensors)!.pointee
                    let fansCount = max(0, min(Int(sensorSample.fan_count), Int(CM_MAX_FANS)))
                    let rpms: [Double] = withUnsafeBytes(of: sensorSample.fan_rpm) { raw in
                        let arr = Array(raw.bindMemory(to: Double.self))
                        return Array(arr.prefix(fansCount))
                    }
                    self.cpuPercent = cpuPct
                    if tempSample.have_cpu != 0 {
                        self.cpuTemp = tempSample.cpu_temp
                        self.peakTemp = max(self.peakTemp ?? tempSample.cpu_temp, tempSample.cpu_temp)
                    }
                    self.fanRPMs = rpms
                }
                let th = ProcessInfo.processInfo.thermalState
                self.thermalState = th
                if th.rawValue > self.peakThermal.rawValue { self.peakThermal = th }
                let sec = Int(now - startAt)
                self.elapsedSec = min(sec, self.durationSec)
                if sec >= self.durationSec {
                    self.stop(completed: true)
                    break
                }
            }
        }
    }

    func stop(completed: Bool = false) {
        stopFlag.set()
        monitorTask?.cancel()
        monitorTask = nil
        running = false
        if completed { finished = true }
    }

    func buildResult() -> MCCheckItem {
        let hot = (peakTemp ?? 0) >= 98 || peakThermal == .critical
        var details: [MCDetailPair] = [
            .init(L10n.t("压测时长", "Duration"), "\(elapsedSec) s"),
            .init(L10n.t("逻辑线程", "Threads"), "\(ProcessInfo.processInfo.activeProcessorCount)"),
            .init(L10n.t("浮点吞吐", "Throughput"), String(format: "%.0f M ops/s", opsPerSecM), mono: true),
            .init(L10n.t("最高热状态", "Peak Thermal"), thermalText(peakThermal)),
        ]
        if let idleTemp {
            details.append(.init(L10n.t("静置基线温度", "Idle Baseline Temp"), String(format: "%.1f °C", idleTemp)))
        }
        if let peakTemp {
            details.append(.init(L10n.t("CPU 峰值温度", "Peak CPU Temp"), String(format: "%.1f °C", peakTemp)))
        }
        if !fanRPMs.isEmpty {
            details.append(.init(L10n.t("风扇转速", "Fan RPM"), fanRPMs.map { "\(Int($0.rounded())) RPM" }.joined(separator: " / ")))
        }
        let tempDesc = peakTemp.map { String(format: "%.1f °C", $0) } ?? thermalText(peakThermal)
        return MCCheckItem(
            id: MCInteractiveKind.stress.resultID,
            category: .interactive,
            title: MCInteractiveKind.stress.title,
            status: hot ? .warning : .pass,
            summary: hot
                ? L10n.t("满载峰值 \(tempDesc)（\(Int(opsPerSecM)) M ops/s），出现明显高温或降频，建议关注散热与清灰",
                         "Peak \(tempDesc) (\(Int(opsPerSecM)) M ops/s) with heavy thermal throttling")
                : L10n.t("\(elapsedSec) 秒多核满载稳定，峰值 \(tempDesc)，吞吐约 \(Int(opsPerSecM)) M ops/s",
                         "Stable for \(elapsedSec)s; peak \(tempDesc), ~\(Int(opsPerSecM)) M ops/s"),
            details: details
        )
    }

    private func thermalText(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return L10n.t("正常", "Nominal")
        case .fair: return L10n.t("温热", "Fair")
        case .serious: return L10n.t("偏热", "Serious")
        case .critical: return L10n.t("过热降频", "Critical")
        @unknown default: return L10n.t("正常", "Nominal")
        }
    }
}

struct MCStressTestView: View {
    @StateObject private var model = MCStressTestModel()
    let onComplete: (MCCheckItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("启动全核高强度计算 30 秒，先记录静置基线温度，再借助 CMetrics 实时观测算力吞吐、CPU 温度与风扇转速。",
                        "Records idle temperature baseline, then runs a 30-second all-core load monitoring throughput, live temperature and fan RPM via CMetrics."))
                .font(DS.body).foregroundStyle(DS.muted)

            HStack(spacing: 16) {
                DSStat(L10n.t("CPU 占用", "CPU Load"), value: String(format: "%.0f%%", model.cpuPercent))
                DSStat(L10n.t("算力吞吐", "Throughput"), value: model.opsPerSecM > 0 ? String(format: "%.0f M/s", model.opsPerSecM) : "—")
                DSStat(L10n.t("实时 / 峰值温度", "Temp / Peak"),
                       value: model.cpuTemp.map { String(format: "%.1f°C", $0) } ?? "—",
                       detail: {
                           var parts: [String] = []
                           if let idle = model.idleTemp { parts.append(String(format: L10n.t("基线 %.0f°C", "Idle %.0f°C"), idle)) }
                           if let peak = model.peakTemp { parts.append(String(format: L10n.t("峰值 %.0f°C", "Peak %.0f°C"), peak)) }
                           return parts.isEmpty ? nil : parts.joined(separator: " · ")
                       }())
                DSStat(L10n.t("风扇转速", "Fans"),
                       value: model.fanRPMs.isEmpty ? L10n.t("无风扇 / 静默", "Fanless / 0") : model.fanRPMs.map { "\(Int($0.rounded()))" }.joined(separator: " / "),
                       detail: model.fanRPMs.isEmpty ? nil : "RPM")
            }

            if model.running || model.finished {
                VStack(alignment: .leading, spacing: 6) {
                    DSProgress(Double(model.elapsedSec) / Double(model.durationSec), tint: DS.accent)
                    Text(L10n.t("进度 \(model.elapsedSec) / \(model.durationSec) 秒", "Elapsed \(model.elapsedSec) / \(model.durationSec) s"))
                        .font(DS.small).foregroundStyle(DS.faint).monospacedDigit()
                }
            }

            DSDivider(inset: 0)
            HStack(spacing: 10) {
                if model.running {
                    DSButton(L10n.t("立即停止", "Stop"), icon: "stop-circle", kind: .danger) { model.stop() }
                } else {
                    DSButton(model.finished ? L10n.t("重新压测", "Run Again") : L10n.t("开始 30 秒压测", "Start 30s Stress"),
                             icon: "flame", kind: .primary) { model.start() }
                    if model.finished || model.elapsedSec >= 5 {
                        DSButton(L10n.t("保存结果", "Save Result"), icon: "check", kind: .secondary) {
                            onComplete(model.buildResult())
                        }
                    }
                }
            }
        }
        .onDisappear { model.stop() }
    }
}

// MARK: - 7. 硬盘真实顺序测速（F_NOCACHE + fsync + 可选容量 + 必删临时文件）

@MainActor
final class MCDiskSpeedModel: ObservableObject {
    @Published var sizeMB: Int = 512
    @Published var running = false
    @Published var phase = ""
    @Published var progress: Double = 0
    @Published var writeMBps: Double?
    @Published var readMBps: Double?
    @Published var errorMessage: String?
    @Published var finished = false

    private var task: Task<Void, Never>?

    func start() {
        guard !running else { return }
        running = true
        finished = false
        writeMBps = nil
        readMBps = nil
        errorMessage = nil
        progress = 0
        let totalBytes = sizeMB * 1024 * 1024
        task = Task { await runBenchmark(totalBytes: totalBytes) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }

    private struct BenchError: Error, Sendable {
        let message: String
    }

    private func runBenchmark(totalBytes: Int) async {
        let tempPath = NSTemporaryDirectory() + "popbar_mc_bench_\(UUID().uuidString).tmp"
        let chunkBytes = 16 * 1024 * 1024
        let (stream, cont) = AsyncStream.makeStream(of: (String, Double).self)

        let worker = Task.detached(priority: .userInitiated) { () -> Result<(Double, Double), BenchError> in
            defer {
                try? FileManager.default.removeItem(atPath: tempPath)
                cont.finish()
            }
            do {
                let w = try Self.runDirectIO(path: tempPath, total: totalBytes, chunk: chunkBytes, writing: true) {
                    cont.yield((L10n.t("顺序写入中", "Sequential Write"), $0))
                }
                try Task.checkCancellation()
                let r = try Self.runDirectIO(path: tempPath, total: totalBytes, chunk: chunkBytes, writing: false) {
                    cont.yield((L10n.t("顺序读取中", "Sequential Read"), $0))
                }
                return .success((w, r))
            } catch is CancellationError {
                return .failure(BenchError(message: ""))
            } catch {
                return .failure(BenchError(message: L10n.t("测速失败，请确认磁盘有足够可用空间", "Benchmark failed; check available disk space")))
            }
        }

        for await (ph, p) in stream {
            phase = ph
            progress = p
        }

        switch await worker.value {
        case .success(let (w, r)):
            writeMBps = w
            readMBps = r
            finished = true
        case .failure(let err):
            if !err.message.isEmpty { errorMessage = err.message }
        }
        running = false
    }

    nonisolated private static func runDirectIO(
        path: String, total: Int, chunk: Int, writing: Bool,
        onProgress: (Double) -> Void
    ) throws -> Double {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { buf.deallocate() }
        if writing { memset(buf, 0x5A, chunk) }

        let flags = writing ? (O_WRONLY | O_CREAT | O_TRUNC) : O_RDONLY
        let fd = open(path, flags, 0o600)
        guard fd >= 0 else { throw NSError(domain: "MCDiskBench", code: Int(errno)) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let t0 = DispatchTime.now().uptimeNanoseconds
        var transferred = 0
        while transferred < total {
            try Task.checkCancellation()
            let n = min(chunk, total - transferred)
            let moved = writing ? write(fd, buf, n) : read(fd, buf, n)
            if moved <= 0 { throw NSError(domain: "MCDiskBench", code: Int(errno)) }
            transferred += moved
            onProgress(Double(transferred) / Double(total))
        }
        if writing { _ = fsync(fd) }
        let sec = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000.0
        return sec > 0 ? (Double(transferred) / 1_048_576.0) / sec : 0
    }

    func buildResult() -> MCCheckItem {
        let w = writeMBps ?? 0
        let r = readMBps ?? 0
        let slow = (w > 0 && w < 250) || (r > 0 && r < 250)
        return MCCheckItem(
            id: MCInteractiveKind.diskSpeed.resultID,
            category: .interactive,
            title: MCInteractiveKind.diskSpeed.title,
            status: slow ? .warning : .pass,
            summary: String(format: L10n.t("写入 %.0f MB/s · 读取 %.0f MB/s", "Write %.0f MB/s · Read %.0f MB/s"), w, r),
            details: [
                .init(L10n.t("顺序写入", "Sequential Write"), String(format: "%.0f MB/s", w), mono: true),
                .init(L10n.t("顺序读取", "Sequential Read"), String(format: "%.0f MB/s", r), mono: true),
                .init(L10n.t("测试体量", "Payload"), "\(sizeMB) MB (F_NOCACHE + fsync)"),
            ]
        )
    }
}

struct MCDiskSpeedTestView: View {
    @StateObject private var model = MCDiskSpeedModel()
    let onComplete: (MCCheckItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("绕过系统页缓存执行真实落盘读写测速，结束后自动清理临时测试文件。",
                            "Direct F_NOCACHE + fsync benchmark; cleans up temporary test files automatically."))
                    .font(DS.body).foregroundStyle(DS.muted)
                Spacer()
                DSSegmented(selection: $model.sizeMB, options: [(512, "512 MB"), (1024, "1 GB")])
                    .disabled(model.running)
            }

            HStack(spacing: 24) {
                DSStat(L10n.t("顺序写入", "Seq Write"), value: model.writeMBps.map { String(format: "%.0f MB/s", $0) } ?? "—")
                DSStat(L10n.t("顺序读取", "Seq Read"), value: model.readMBps.map { String(format: "%.0f MB/s", $0) } ?? "—")
            }

            if model.running {
                VStack(alignment: .leading, spacing: 6) {
                    DSProgress(model.progress, tint: DS.accent)
                    Text("\(model.phase) \(Int((model.progress * 100).rounded()))%")
                        .font(DS.small).foregroundStyle(DS.faint).monospacedDigit()
                }
            }
            if let err = model.errorMessage {
                DSChip(err, tone: .danger, icon: "triangle-alert")
            }

            DSDivider(inset: 0)
            HStack(spacing: 10) {
                if model.running {
                    DSButton(L10n.t("取消测速", "Cancel"), kind: .danger) { model.cancel() }
                } else {
                    DSButton(model.finished ? L10n.t("重新测速", "Run Again") : L10n.t("开始测速", "Start Benchmark"),
                             icon: "gauge", kind: .primary) { model.start() }
                    if model.finished {
                        DSButton(L10n.t("保存结果", "Save Result"), icon: "check", kind: .secondary) {
                            onComplete(model.buildResult())
                        }
                    }
                }
            }
        }
        .onDisappear { model.cancel() }
    }
}

// MARK: - 8. 接口逐口热插拔实测（基于 IOKit 三类总线事件通知，零轮询开销：USB 含速率 + 雷电 PCIe + SD/外置盘）

struct MCPortEvent: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let deviceName: String
    let busTag: String
    let isAttach: Bool
}

@MainActor
final class MCPortsLiveModel: ObservableObject {
    @Published var events: [MCPortEvent] = []
    @Published var attachCount: Int = 0
    @Published var listening = false

    private enum BusKind { case usb, thunderbolt, externalMedia }

    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var primed = false

    deinit {
        for it in iterators where it != 0 { IOObjectRelease(it) }
        if let port = notifyPort { IONotificationPortDestroy(port) }
    }

    static func usbSpeedLabel(_ raw: Int?) -> String {
        switch raw {
        case 0: return "USB 1.0"
        case 1: return "USB 1.1"
        case 2: return "USB 2.0"
        case 3: return "USB 3.0 (5 Gbps)"
        case 4: return "USB 3.1 (10 Gbps)"
        case 5: return "USB 3.2 (20 Gbps)"
        default: return "USB"
        }
    }

    func start() {
        guard !listening else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        register(port: port, className: "IOUSBHostDevice", kind: .usb)
        register(port: port, className: "IOThunderboltSwitch", kind: .thunderbolt)
        register(port: port, className: "IOMedia", kind: .externalMedia)

        primed = true
        listening = true
    }

    func clearLog() {
        events.removeAll()
        attachCount = 0
    }

    func stop() {
        for it in iterators where it != 0 {
            IOObjectRelease(it)
        }
        iterators.removeAll()
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        listening = false
        primed = false
    }

    private func register(port: IONotificationPortRef, className: String, kind: BusKind) {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let makeAddCB: (BusKind) -> IOServiceMatchingCallback = { k in
            switch k {
            case .usb:
                return { refcon, it in
                    guard let refcon else { return }
                    let me = Unmanaged<MCPortsLiveModel>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { me.drain(it, kind: .usb, isAttach: true) }
                }
            case .thunderbolt:
                return { refcon, it in
                    guard let refcon else { return }
                    let me = Unmanaged<MCPortsLiveModel>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { me.drain(it, kind: .thunderbolt, isAttach: true) }
                }
            case .externalMedia:
                return { refcon, it in
                    guard let refcon else { return }
                    let me = Unmanaged<MCPortsLiveModel>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { me.drain(it, kind: .externalMedia, isAttach: true) }
                }
            }
        }
        let makeRemCB: (BusKind) -> IOServiceMatchingCallback = { k in
            switch k {
            case .usb:
                return { refcon, it in
                    guard let refcon else { return }
                    let me = Unmanaged<MCPortsLiveModel>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { me.drain(it, kind: .usb, isAttach: false) }
                }
            case .thunderbolt:
                return { refcon, it in
                    guard let refcon else { return }
                    let me = Unmanaged<MCPortsLiveModel>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { me.drain(it, kind: .thunderbolt, isAttach: false) }
                }
            case .externalMedia:
                return { refcon, it in
                    guard let refcon else { return }
                    let me = Unmanaged<MCPortsLiveModel>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { me.drain(it, kind: .externalMedia, isAttach: false) }
                }
            }
        }

        var addIt: io_iterator_t = 0
        if let m = IOServiceMatching(className),
           IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, m, makeAddCB(kind), selfPtr, &addIt) == KERN_SUCCESS {
            drain(addIt, kind: kind, isAttach: true)
            iterators.append(addIt)
        }
        var remIt: io_iterator_t = 0
        if let m = IOServiceMatching(className),
           IOServiceAddMatchingNotification(port, kIOTerminatedNotification, m, makeRemCB(kind), selfPtr, &remIt) == KERN_SUCCESS {
            drain(remIt, kind: kind, isAttach: false)
            iterators.append(remIt)
        }
    }

    private func drain(_ iterator: io_iterator_t, kind: BusKind, isAttach: Bool) {
        var svc = IOIteratorNext(iterator)
        while svc != 0 {
            defer {
                IOObjectRelease(svc)
                svc = IOIteratorNext(iterator)
            }
            guard primed, let info = describe(svc, kind: kind) else { continue }
            if isAttach { attachCount += 1 }
            events.insert(MCPortEvent(time: Date(), deviceName: info.name, busTag: info.bus, isAttach: isAttach), at: 0)
            if events.count > 24 { events.removeLast(events.count - 24) }
        }
    }

    private func describe(_ svc: io_service_t, kind: BusKind) -> (name: String, bus: String)? {
        switch kind {
        case .usb:
            let name = ioString(svc, "USB Product Name") ?? ioString(svc, "Product Name") ?? ioRegistryName(svc)
            guard let name, !name.isEmpty else { return nil }
            let speed = Self.usbSpeedLabel(ioInt(svc, "Device Speed"))
            return (name, speed)

        case .thunderbolt:
            // Depth == 0 是主机内置根交换机，仅记录 Depth >= 1 的外接雷电设备
            guard let depth = ioInt(svc, "Depth"), depth > 0 else { return nil }
            let vendor = ioString(svc, "Device Vendor Name") ?? ""
            let model = ioString(svc, "Device Model Name") ?? L10n.t("雷电设备", "Thunderbolt Device")
            let full = [vendor, model].filter { !$0.isEmpty }.joined(separator: " ")
            return (full, L10n.t("雷电 / TB", "Thunderbolt"))

        case .externalMedia:
            // 仅捕获整盘且非 USB 的外置介质（SD 读卡器、雷电 NVMe 硬盘盒等），避免与 USB 重复
            guard (IORegistryEntryCreateCFProperty(svc, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) == true else {
                return nil
            }
            let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            guard let proto = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, "Protocol Characteristics" as CFString, kCFAllocatorDefault, opts) as? [String: Any] else {
                return nil
            }
            let interconnect = (proto["Physical Interconnect"] as? String) ?? ""
            let location = (proto["Physical Interconnect Location"] as? String) ?? ""
            let isSD = interconnect == "Secure Digital"
            guard (location == "External" || isSD), interconnect != "USB" else { return nil }
            let devDict = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, "Device Characteristics" as CFString, kCFAllocatorDefault, opts) as? [String: Any]
            let prod = (devDict?["Product Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var name = (prod?.isEmpty == false ? prod! : L10n.t("外置存储介质", "External Storage"))
            if let sz = ioInt64(svc, "Size"), sz > 0 {
                name += " · " + ByteCountFormatter.string(fromByteCount: sz, countStyle: .decimal)
            }
            let tag = isSD ? L10n.t("SD 读卡器", "SD Reader") : (interconnect.isEmpty ? L10n.t("外置盘", "External") : interconnect)
            return (name, tag)
        }
    }

    private func ioString(_ svc: io_service_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private func ioInt(_ svc: io_service_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
    }

    private func ioInt64(_ svc: io_service_t, _ key: String) -> Int64? {
        (IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.int64Value
    }

    private func ioRegistryName(_ svc: io_service_t) -> String? {
        var buf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(svc, &buf) == KERN_SUCCESS else { return nil }
        return String(cString: buf)
    }
}

struct MCPortsLiveTestView: View {
    @StateObject private var model = MCPortsLiveModel()
    let onComplete: (MCCheckItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("请将 U 盘、雷电硬盘盒、SD 卡或扩展坞依次插入每个物理接口，系统通过 IOKit 事件实时捕获设备名与协商速率。",
                            "Plug a USB drive, Thunderbolt enclosure, SD card or hub into each port. Devices and link speeds appear in real time via IOKit."))
                    .font(DS.body).foregroundStyle(DS.muted)
                Spacer()
                HStack(spacing: 8) {
                    DSChip(L10n.t("已检出接入 \(model.attachCount) 次", "\(model.attachCount) plug-ins"), tone: model.attachCount > 0 ? .success : .neutral)
                    if !model.events.isEmpty {
                        DSButton(L10n.t("清除", "Clear"), kind: .ghost) { model.clearLog() }
                    }
                }
            }

            if model.events.isEmpty {
                HStack(spacing: 8) {
                    Icon("zap", size: 15, color: DS.accent)
                    Text(L10n.t("监听中（USB / 雷电 PCIe / SD 卡槽），等待插入外设…", "Listening on USB / Thunderbolt / SD slots…"))
                        .font(DS.caption).foregroundStyle(DS.muted)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(DS.surface2))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.events.prefix(10).enumerated()), id: \.element.id) { idx, ev in
                        if idx > 0 { DSDivider(inset: 12) }
                        HStack(spacing: 10) {
                            DSChip(ev.isAttach ? L10n.t("接入", "Attached") : L10n.t("拔出", "Removed"),
                                   tone: ev.isAttach ? .success : .neutral)
                            Text(ev.deviceName).font(DS.body).foregroundStyle(DS.text).lineLimit(1)
                            Spacer()
                            DSChip(ev.busTag, tone: .accent)
                            Text(ev.time.formatted(date: .omitted, time: .standard))
                                .font(DS.mono).foregroundStyle(DS.faint)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(DS.surface2))
            }

            DSDivider(inset: 0)
            HStack(spacing: 10) {
                DSButton(L10n.t("所有接口正常", "All Ports Normal"), icon: "check", kind: .primary) {
                    model.stop()
                    let attached = model.events.filter(\.isAttach).map { "\($0.deviceName)（\($0.busTag)）" }
                    var details: [MCDetailPair] = [.init(L10n.t("检测到接入次数", "Plug-in Events"), "\(model.attachCount)")]
                    if !attached.isEmpty {
                        details.append(.init(L10n.t("接入设备记录", "Connected Log"), attached.prefix(8).joined(separator: "；")))
                    }
                    onComplete(MCCheckItem(
                        id: MCInteractiveKind.portsLive.resultID,
                        category: .interactive,
                        title: MCInteractiveKind.portsLive.title,
                        status: .pass,
                        summary: L10n.t("实测检测到 \(model.attachCount) 次外设接入，接口工作正常", "Verified \(model.attachCount) hot-plug events"),
                        details: details
                    ))
                }
                DSButton(L10n.t("有接口无反应", "Port Issue"), kind: .danger) {
                    model.stop()
                    onComplete(MCCheckItem(
                        id: MCInteractiveKind.portsLive.resultID,
                        category: .interactive,
                        title: MCInteractiveKind.portsLive.title,
                        status: .warning,
                        summary: L10n.t("用户反馈部分物理接口无响应或松动", "User reported unresponsive or loose physical port")
                    ))
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
