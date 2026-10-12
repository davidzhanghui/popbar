import Cocoa
@preconcurrency import AVFoundation
import QuartzCore

enum RecordExportError: LocalizedError {
    case sourceMissing
    case noVideo
    case cancelled
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing: return L10n.t("源文件不存在或已被移动", "Source file is missing or was moved")
        case .noVideo: return L10n.t("文件里没有可导出的视频轨", "No video track to export")
        case .cancelled: return L10n.t("已取消", "Cancelled")
        case .writeFailed(let s): return s.isEmpty ? L10n.t("导出失败", "Export failed") : s
        }
    }
}

/// 一次导出的全部参数 —— 裁剪 / 缩放 / 压缩 / 混音 / 涟漪 / PiP / 水印走同一条管线
struct RecordExportParams {
    var start: Double = 0
    /// nil = 到结尾
    var end: Double?
    /// 目标宽度,0 = 原始(不放大)
    var width: Int = 0
    /// high | medium | low
    var quality: String = "high"
    /// mp4 | mov
    var container: String = "mp4"
    var systemVolume: Double = 1
    var micVolume: Double = 1
    var burnClicks: Bool = false
    var click = ClickHighlightConfig()
    var watermark = WatermarkConfig()
    /// 摄像头旁挂视频与它在画面上的归一化矩形
    var camera: CameraSidecar?
    var cameraURL: URL?
    /// 录制时记下的点击与音轨布局
    var clicks: [ClickMark] = []
    var micEnabled: Bool = false
    var copyToClipboard: Bool = false
}

// MARK: - 纯逻辑(全部进 tests/)

enum RecordExportUtil {
    /// 渲染尺寸:不放大、宽高对齐偶数、最小 2
    static func targetSize(source: CGSize, width: Int) -> CGSize {
        let w0 = max(source.width, 2), h0 = max(source.height, 2)
        guard width > 0, CGFloat(width) < w0 else {
            return CGSize(width: even(w0), height: even(h0 * even(w0) / w0))
        }
        let w = even(CGFloat(width))
        return CGSize(width: w, height: max(even(h0 * w / w0), 2))
    }

    private static func even(_ v: CGFloat) -> CGFloat {
        max((v.rounded() / 2).rounded(.down) * 2, 2)
    }

    /// 起止钳位:span 为有效视频时长;跨度至少 0.01s
    static func clampRange(span: Double, start: Double, end: Double?) -> (Double, Double) {
        let s = min(max(start, 0), max(span - 0.01, 0))
        let e = min(max(end ?? span, s + 0.01), span)
        return (s, e)
    }

    /// 质量档 → 导出预设。宽度也参与:小尺寸没必要用最高档编码
    static func presetName(quality: String, width: Int) -> String {
        switch quality {
        case "low": return AVAssetExportPreset1280x720
        case "medium": return width > 0 && width <= 1280 ? AVAssetExportPreset1280x720
                                                         : AVAssetExportPreset1920x1080
        default: return AVAssetExportPresetHighestQuality
        }
    }

    /// 归一化坐标(左上原点) → Core Animation 位置(左下原点)
    static func layerPoint(x: Double, y: Double, renderSize: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(x) * renderSize.width,
                y: (1 - CGFloat(y)) * renderSize.height)
    }

    /// 归一化矩形(左上原点) → Core Animation 矩形(左下原点)。
    /// 只给 CA 动画层(涟漪 / 水印 / 边框)用。
    static func layerRect(x: Double, y: Double, w: Double, h: Double, renderSize: CGSize) -> CGRect {
        CGRect(x: CGFloat(x) * renderSize.width,
               y: (1 - CGFloat(y) - CGFloat(h)) * renderSize.height,
               width: CGFloat(w) * renderSize.width,
               height: CGFloat(h) * renderSize.height)
    }

    /// 归一化矩形(左上原点) → 渲染坐标矩形(左上原点)。
    /// layerInstruction 的 transform 用左上原点坐标系,和 CA 层不是一回事,不能混用 ——
    /// 混用的结果就是摄像头被摆到画面垂直镜像的位置上。
    static func renderRect(x: Double, y: Double, w: Double, h: Double, renderSize: CGSize) -> CGRect {
        CGRect(x: CGFloat(x) * renderSize.width,
               y: CGFloat(y) * renderSize.height,
               width: CGFloat(w) * renderSize.width,
               height: CGFloat(h) * renderSize.height)
    }

    /// 水印矩形(CA 坐标):按位置贴四角,margin 为渲染宽度的比例
    static func watermarkFrame(size: CGSize, renderSize: CGSize, position: String, margin: CGFloat = 0.025) -> CGRect {
        let m = renderSize.width * margin
        let x: CGFloat, y: CGFloat
        switch position {
        case "topLeft":     x = m; y = renderSize.height - m - size.height
        case "bottomLeft":  x = m; y = m
        case "bottomRight": x = renderSize.width - m - size.width; y = m
        default:            x = renderSize.width - m - size.width; y = renderSize.height - m - size.height
        }
        return CGRect(x: max(x, 0), y: max(y, 0), width: size.width, height: size.height)
    }

    /// 涟漪半径按渲染高度等比缩放(以 1080p 为基准)
    static func scaledRadius(_ radius: Double, renderSize: CGSize) -> CGFloat {
        max(CGFloat(radius) * renderSize.height / 1080, 6)
    }

    /// 水印字号同理等比缩放
    static func scaledFontSize(_ size: Int, renderSize: CGSize) -> CGFloat {
        max(CGFloat(size) * renderSize.height / 1080, 8)
    }

    /// 把源视频(自然尺寸 + preferredTransform)摆进目标矩形:
    /// 等比缩放居中,先摆正再缩放再平移
    static func placeTransform(naturalSize: CGSize, preferred: CGAffineTransform,
                               renderSize: CGSize) -> CGAffineTransform {
        let bbox = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let disp = CGSize(width: max(abs(bbox.width), 1), height: max(abs(bbox.height), 1))
        let s = min(renderSize.width / disp.width, renderSize.height / disp.height)
        let offset = CGPoint(x: (renderSize.width - disp.width * s) / 2,
                             y: (renderSize.height - disp.height * s) / 2)
        // p → preferred → 平移到原点 → 缩放 → 居中
        return preferred
            .concatenating(CGAffineTransform(translationX: -bbox.minX, y: -bbox.minY))
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))
    }

    /// 每一条音轨的音量。
    /// SCRecordingOutput 不告诉我们哪条是系统声音、哪条是麦克风:
    /// 开麦克风且有 ≥2 轨时,约定最后一轨是麦克风;只有一轨说明已被混成一条。
    static func volumePlan(trackCount: Int, micEnabled: Bool, system: Double, mic: Double) -> [Double] {
        guard trackCount > 0 else { return [] }
        if trackCount == 1 { return [micEnabled ? min(system, mic) : system] }
        var plan = [Double](repeating: system, count: trackCount)
        if micEnabled { plan[trackCount - 1] = mic }
        return plan
    }

    /// "#RRGGBB" / "#RGB" → 分量;解析失败返回 nil
    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

// MARK: - 导出

enum RecordExport {
    static func export(source: URL, params: RecordExportParams, to dest: URL,
                       progress: @escaping @Sendable (Double) -> Void,
                       isCancelled: @escaping @Sendable () -> Bool) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw RecordExportError.sourceMissing }

        let asset = AVURLAsset(url: source)
        defer { _ = asset }     // 同 camAsset:asset 一释放,轨道就失效
        guard let srcVideo = try? await asset.loadTracks(withMediaType: .video).first else {
            throw RecordExportError.noVideo
        }
        let srcAudio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let assetSeconds = ((try? await asset.load(.duration)) ?? .zero).seconds
        let videoSeconds = ((try? await srcVideo.load(.timeRange))?.duration.seconds) ?? 0
        // 录制掉帧时视频轨可能短于容器,取两者较小值
        let span = videoSeconds > 0.01 ? min(assetSeconds, videoSeconds) : assetSeconds
        guard span > 0.01 else { throw RecordExportError.noVideo }

        let (start, end) = RecordExportUtil.clampRange(span: span, start: params.start, end: params.end)
        let outSeconds = end - start

        let natural = (try? await srcVideo.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let preferred = (try? await srcVideo.load(.preferredTransform)) ?? .identity
        let bbox = CGRect(origin: .zero, size: natural).applying(preferred)
        let srcDisplay = CGSize(width: max(abs(bbox.width), 1), height: max(abs(bbox.height), 1))
        let renderSize = RecordExportUtil.targetSize(source: srcDisplay, width: params.width)
        let rawFps = (try? await srcVideo.load(.nominalFrameRate)) ?? 30
        let fps = min(max(Int(rawFps.rounded()), 10), 60)

        // 摄像头旁挂视频。camAsset 必须活到导出结束:AVAssetTrack.asset 是 weak,
        // asset 一旦释放,轨道就失效,后面的 insertTimeRange 会静默失败。
        var camAssetRef: AVURLAsset?
        var camTrack: AVAssetTrack?
        var camSeconds = 0.0
        if params.camera != nil, let camURL = params.cameraURL, fm.fileExists(atPath: camURL.path) {
            let camAsset = AVURLAsset(url: camURL)
            camAssetRef = camAsset
            camTrack = try? await camAsset.loadTracks(withMediaType: .video).first
            camSeconds = ((try? await camAsset.load(.duration)) ?? .zero).seconds
        }
        defer { _ = camAssetRef }

        let watermark = params.watermark.enabled ? params.watermark : nil
        let ripple = params.burnClicks ? params.click : nil
        let needComposition = camTrack != nil || watermark != nil
            || (ripple != nil && !params.clicks.isEmpty)
            || renderSize != srcDisplay
            || params.systemVolume != 1 || params.micVolume != 1

        // 快路径:不需要重新合成时直接 passthrough 裁一段,快且无损
        if !needComposition {
            try await passthrough(source: source, range: CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: outSeconds, preferredTimescale: 600)),
                container: params.container, to: dest, progress: progress, isCancelled: isCancelled)
            progress(1)
            return dest
        }

        // ① 组装 composition:主视频 + 各音轨 + 摄像头
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordExportError.noVideo
        }
        let insertRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                      duration: CMTime(seconds: outSeconds, preferredTimescale: 600))
        do { try vTrack.insertTimeRange(insertRange, of: srcVideo, at: .zero) }
        catch { throw RecordExportError.writeFailed(error.localizedDescription) }

        var audioTracks: [AVMutableCompositionTrack] = []
        for a in srcAudio {
            let avail = ((try? await a.load(.timeRange))?.duration.seconds) ?? outSeconds
            let dur = min(outSeconds, max(avail - start, 0))
            guard dur > 0.01,
                  let t = comp.addMutableTrack(withMediaType: .audio,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            do {
                try t.insertTimeRange(CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                                  duration: CMTime(seconds: dur, preferredTimescale: 600)),
                                      of: a, at: .zero)
                audioTracks.append(t)
            } catch {
                // 空轨道留在 composition 里会让整次导出失败,宁可这条音轨不要
                comp.removeTrack(t)
            }
        }

        var camCompTrack: AVMutableCompositionTrack?
        if let camTrack {
            let dur = min(outSeconds, camSeconds)
            if dur > 0.01,
               let t = comp.addMutableTrack(withMediaType: .video,
                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                do {
                    try t.insertTimeRange(CMTimeRange(start: .zero,
                                                      duration: CMTime(seconds: dur, preferredTimescale: 600)),
                                          of: camTrack, at: .zero)
                    camCompTrack = t
                } catch {
                    comp.removeTrack(t)   // 摄像头合成不了就只导正片,别整个失败
                }
            }
        }

        // ② 视频合成:第一个 layerInstruction 在最上层,所以摄像头放前面
        let vc = AVMutableVideoComposition()
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero,
                                            duration: CMTime(seconds: outSeconds, preferredTimescale: 600))
        var layers: [AVVideoCompositionLayerInstruction] = []

        if let camCompTrack, let camTrack {
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: camCompTrack)
            let overlay = params.camera
            let target = RecordExportUtil.renderRect(x: overlay?.x ?? 0.75, y: overlay?.y ?? 0.75,
                                                     w: overlay?.width ?? 0.2, h: overlay?.height ?? 0.2,
                                                     renderSize: renderSize)
            let camNatural = (try? await camTrack.load(.naturalSize)) ?? CGSize(width: 640, height: 480)
            let camPreferred = (try? await camTrack.load(.preferredTransform)) ?? .identity
            li.setTransform(RecordExportUtil.placeTransform(naturalSize: camNatural, preferred: camPreferred,
                                                            renderSize: target.size)
                                .concatenating(CGAffineTransform(translationX: target.minX, y: target.minY)),
                            at: .zero)
            // 摄像头比正片短时,到点后隐掉,避免留黑块
            if camSeconds < outSeconds {
                li.setOpacity(0, at: CMTime(seconds: camSeconds, preferredTimescale: 600))
            }
            layers.append(li)
        }

        let main = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        main.setTransform(RecordExportUtil.placeTransform(naturalSize: natural, preferred: preferred,
                                                         renderSize: renderSize), at: .zero)
        layers.append(main)
        instruction.layerInstructions = layers
        vc.instructions = [instruction]

        // ③ Core Animation 层:涟漪 + 水印 + 摄像头边框
        // 点击时间记的是源片时间轴,裁剪后要整体平移到成品时间轴
        let visibleClicks = params.clicks
            .filter { $0.t >= start && $0.t <= end }
            .map { ClickMark(t: $0.t - start, x: $0.x, y: $0.y, button: $0.button) }
        let overlayLayer = overlayAnimationLayer(ripple: ripple, watermark: watermark,
                                                 camera: camCompTrack == nil ? nil : params.camera,
                                                 clicks: visibleClicks, renderSize: renderSize)
        if let overlayLayer {
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: renderSize)
            parent.beginTime = AVCoreAnimationBeginTimeAtZero
            let videoLayer = CALayer()
            videoLayer.frame = CGRect(origin: .zero, size: renderSize)
            parent.addSublayer(videoLayer)
            parent.addSublayer(overlayLayer)
            vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer,
                                                                  in: parent)
        }

        // ④ 混音
        let plan = RecordExportUtil.volumePlan(trackCount: audioTracks.count, micEnabled: params.micEnabled,
                                              system: params.systemVolume, mic: params.micVolume)
        var audioMix: AVMutableAudioMix?
        if !plan.isEmpty, plan.contains(where: { $0 != 1 }) {
            let mix = AVMutableAudioMix()
            mix.inputParameters = zip(audioTracks, plan).map { track, vol in
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(Float(vol), at: .zero)
                return p
            }
            audioMix = mix
        }

        // ⑤ 导出(选定的档位不被支持时退回最高质量)
        let fileType: AVFileType = params.container == "mp4" ? .mp4 : .mov
        let presets = [RecordExportUtil.presetName(quality: params.quality, width: Int(renderSize.width)),
                       AVAssetExportPresetHighestQuality]
        var lastError: Error = RecordExportError.writeFailed("")
        for (i, preset) in presets.enumerated() {
            guard let exporter = AVAssetExportSession(asset: comp, presetName: preset) else { continue }
            exporter.videoComposition = vc
            exporter.audioMix = audioMix
            exporter.shouldOptimizeForNetworkUse = true
            do {
                try await run(exporter, to: dest, as: fileType, progress: progress, isCancelled: isCancelled)
                progress(1)
                return dest
            } catch RecordExportError.cancelled {
                throw RecordExportError.cancelled
            } catch {
                lastError = error
                if i == presets.count - 1 { break }
            }
        }
        throw lastError
    }

    // MARK: 分步

    private static func passthrough(source: URL, range: CMTimeRange, container: String, to dest: URL,
                                    progress: @escaping @Sendable (Double) -> Void,
                                    isCancelled: @escaping @Sendable () -> Bool) async throws {
        guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: source),
                                                  presetName: AVAssetExportPresetPassthrough) else {
            throw RecordExportError.writeFailed("")
        }
        exporter.timeRange = range
        exporter.shouldOptimizeForNetworkUse = true
        try await run(exporter, to: dest, as: container == "mp4" ? .mp4 : .mov,
                      progress: progress, isCancelled: isCancelled)
    }

    /// 跑一次导出;失败或取消时不留半成品
    private static func run(_ exporter: AVAssetExportSession, to dest: URL, as fileType: AVFileType,
                            progress: @escaping @Sendable (Double) -> Void,
                            isCancelled: @escaping @Sendable () -> Bool) async throws {
        try? FileManager.default.removeItem(at: dest)
        let monitor = Task {
            for await state in exporter.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
                if isCancelled() { exporter.cancelExport() }
            }
        }
        defer { monitor.cancel() }
        do {
            try await exporter.export(to: dest, as: fileType)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            if isCancelled() { throw RecordExportError.cancelled }
            throw RecordExportError.writeFailed(describe(error, exporter: exporter))
        }
    }

    /// 导出失败时的可读原因 —— AVFoundation 常常只给一句 "Operation Stopped",
    /// 真正的原因藏在 underlyingError 里,把它一并带出来
    private static func describe(_ error: Error, exporter: AVAssetExportSession) -> String {
        _ = exporter
        var parts: [String] = []
        let ns = error as NSError
        parts.append("\(ns.domain) \(ns.code): \(ns.localizedDescription)")
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("← \(under.domain) \(under.code): \(under.localizedDescription)")
        }
        return parts.joined(separator: " | ")
    }

    /// 涟漪 + 水印 + 摄像头边框;都没有则返回 nil(不进 CA 渲染,导出更快)
    private static func overlayAnimationLayer(ripple: ClickHighlightConfig?, watermark: WatermarkConfig?,
                                              camera: CameraSidecar?, clicks: [ClickMark],
                                              renderSize: CGSize) -> CALayer? {
        var shapes: [CALayer] = []
        if let ripple, !clicks.isEmpty {
            let (r, g, b) = RecordExportUtil.rgb(ripple.color) ?? (1, 0.23, 0.19)
            let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            for c in clicks {
                shapes.append(rippleLayer(c, cfg: ripple, color: color, renderSize: renderSize))
            }
        }
        if let watermark, watermark.enabled, let w = watermarkLayer(watermark, renderSize: renderSize) {
            shapes.append(w)
        }
        if let camera {
            let rect = RecordExportUtil.layerRect(x: camera.x, y: camera.y,
                                                 w: camera.width, h: camera.height, renderSize: renderSize)
            let border = CAShapeLayer()
            border.path = CGPath(rect: rect, transform: nil)
            border.fillColor = nil
            border.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
            border.lineWidth = max(renderSize.width / 640, 1.5)
            shapes.append(border)
        }
        guard !shapes.isEmpty else { return nil }
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        root.beginTime = AVCoreAnimationBeginTimeAtZero
        shapes.forEach { root.addSublayer($0) }
        return root
    }

    private static func rippleLayer(_ click: ClickMark, cfg: ClickHighlightConfig,
                                    color: NSColor, renderSize: CGSize) -> CALayer {
        let radius = RecordExportUtil.scaledRadius(cfg.radius, renderSize: renderSize)
        let shape = CAShapeLayer()
        shape.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        shape.position = RecordExportUtil.layerPoint(x: click.x, y: click.y, renderSize: renderSize)
        shape.path = CGPath(ellipseIn: shape.bounds, transform: nil)
        shape.fillColor = color.withAlphaComponent(0.16).cgColor
        shape.strokeColor = color.cgColor
        shape.lineWidth = max(radius * 0.12, 1.5)
        shape.opacity = 0     // 模型值 0:点击之前/之后都不可见
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.55
        scale.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        for a in [scale, fade] as [CAAnimation] {
            // 动画时间轴是视频的时间轴;beginTime 必须是小正数,0 会被换成当前时间
            a.beginTime = max(click.t, AVCoreAnimationBeginTimeAtZero)
            a.duration = cfg.duration
            // 只能是 .forwards:.backwards 会在动画开始前显示「起始值」,
            // 结果就是第一次点击之前,涟漪就已经整场可见了
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shape.add(a, forKey: nil)
        }
        return shape
    }

    private static func watermarkLayer(_ cfg: WatermarkConfig, renderSize: CGSize) -> CALayer? {
        let path = (cfg.imagePath as NSString).expandingTildeInPath
        if !path.isEmpty, let img = NSImage(contentsOfFile: path),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.height > 0 {
            let h = RecordExportUtil.scaledFontSize(cfg.size, renderSize: renderSize) * 2
            let w = h * CGFloat(cg.width) / CGFloat(cg.height)
            let layer = CALayer()
            layer.contents = cg
            layer.contentsGravity = .resizeAspect
            layer.frame = RecordExportUtil.watermarkFrame(size: CGSize(width: w, height: h),
                                                         renderSize: renderSize, position: cfg.position)
            layer.opacity = Float(cfg.opacity)
            return layer
        }
        guard !cfg.text.isEmpty else { return nil }
        // CATextLayer 要的是 CGColor/CTFont 属性,AppKit 的 NSColor 会被忽略(文字变黑,
        // 叠在半透明黑底上等于看不见)。先画成位图再当普通层贴上去,最稳。
        let font = NSFont.systemFont(ofSize: RecordExportUtil.scaledFontSize(cfg.size, renderSize: renderSize),
                                     weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
        let size = (cfg.text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = max(font.pointSize * 0.5, 4)
        let box = CGSize(width: ceil(size.width + pad * 2), height: ceil(size.height + pad))
        let img = NSImage(size: box, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            (cfg.text as NSString).draw(at: NSPoint(x: pad, y: (rect.height - size.height) / 2), withAttributes: attrs)
            return true
        }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let layer = CALayer()
        layer.contents = cg
        layer.contentsGravity = .resize
        layer.frame = RecordExportUtil.watermarkFrame(size: box, renderSize: renderSize, position: cfg.position)
        layer.opacity = Float(cfg.opacity)
        return layer
    }
}
