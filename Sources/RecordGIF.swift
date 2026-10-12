import Cocoa
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum GIFError: LocalizedError {
    case noVideo
    case cancelled
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noVideo: return L10n.t("文件里没有可导出的视频轨", "No video track to export")
        case .cancelled: return L10n.t("已取消", "Cancelled")
        case .writeFailed: return L10n.t("GIF 写入失败", "Failed to write GIF")
        }
    }
}

struct GIFParams {
    /// 5 | 10 | 15
    var fps: Int = 10
    /// 0 = 原始宽度
    var width: Int = 800
    var start: Double = 0
    /// nil = 到结尾
    var end: Double? = nil
    var loop: Bool = true

    /// 「直接录 GIF」:≤800 宽、10fps、整段
    static var auto: GIFParams {
        let cfg = ConfigStore.shared.config.snap.record.gif
        return GIFParams(fps: min(max(cfg.fps, 5), 15),
                         width: cfg.width > 0 ? min(cfg.width, 800) : 800,
                         start: 0, end: nil, loop: true)
    }

    static var defaults: GIFParams {
        let cfg = ConfigStore.shared.config.snap.record.gif
        return GIFParams(fps: min(max(cfg.fps, 1), 30), width: cfg.width, start: 0, end: nil, loop: true)
    }
}

enum RecordGIF {
    /// 帧数与输出尺寸(纯逻辑,便于测试):width ≤ 0 表示原始宽度
    static func plan(duration: Double, size: CGSize, fps: Int, width: Int) -> (frames: Int, size: CGSize) {
        let count = max(Int((max(duration, 0) * Double(max(fps, 1))).rounded()), 1)
        let naturalW = max(Int(size.width.rounded()), 1)
        let w = width > 0 ? max(min(width, naturalW), 1) : naturalW
        let h = max(Int((size.height * CGFloat(w) / max(size.width, 1)).rounded()), 1)
        return (count, CGSize(width: w, height: h))
    }

    /// 起止钳位(纯逻辑,便于测试):span 为有效视频时长
    static func clampRange(span: Double, start: Double, end: Double?) -> (Double, Double) {
        let s = min(max(start, 0), max(span - 0.01, 0))
        let e = min(max(end ?? span, s + 0.01), span)
        return (s, e)
    }

    static func export(url: URL, params: GIFParams,
                       progress: @escaping @Sendable (Double) -> Void = { _ in },
                       isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { throw GIFError.noVideo }
        let seconds = ((try? await asset.load(.duration)) ?? .zero).seconds
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let raw = natural.applying(transform)
        let size = CGSize(width: abs(raw.width), height: abs(raw.height))
        guard seconds > 0.01, size.width >= 1, size.height >= 1 else { throw GIFError.noVideo }

        // 录制中掉帧时视频轨可能比音频/容器短,取帧范围以视频轨实际时长为准,
        // 否则超出末尾的请求点会报 Cannot Open
        let videoDur = ((try? await track.load(.timeRange))?.duration.seconds ?? 0)
        let span = videoDur > 0.01 ? min(seconds, videoDur) : seconds
        let (start, end) = clampRange(span: span, start: params.start, end: params.end)
        let (frames, outSize) = plan(duration: end - start, size: size, fps: params.fps, width: params.width)
        let times = (0..<frames).map { i in
            CMTime(seconds: start + (end - start) * (Double(i) / Double(frames)), preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = outSize       // 解码时就缩到目标尺寸,避免整段 1080p 常驻内存

        let dest = RecordUtil.uniqueURL(in: url.deletingLastPathComponent(),
                                        stem: url.deletingPathExtension().lastPathComponent, ext: "gif")
        do {
            try await write(generator: generator, times: times, to: dest,
                            fps: params.fps, loop: params.loop, progress: progress, isCancelled: isCancelled)
        } catch {
            try? FileManager.default.removeItem(at: dest)   // 中途失败/取消不留半成品
            throw error
        }
        progress(1)
        return dest
    }

    /// 逐帧解码并边写边丢:generateCGImagesAsynchronously 一次性并发全部请求会让硬件解码器
    /// 过载,中段帧批量报 Cannot Decode(-11821);串行 copyCGImage 实测全部成功且 99 帧 ≈1s。
    /// 边解边写同时把内存峰值从整段帧降到单帧。
    private static func write(generator: AVAssetImageGenerator, times: [CMTime], to url: URL,
                              fps: Int, loop: Bool,
                              progress: @escaping @Sendable (Double) -> Void,
                              isCancelled: @escaping @Sendable () -> Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                             times.count, nil) else { throw GIFError.writeFailed }
            CGImageDestinationSetProperties(dest, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop ? 0 : 1],
            ] as CFDictionary)
            let delay = 1.0 / Double(max(fps, 1))
            let props = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay],
            ] as CFDictionary
            for (i, t) in times.enumerated() {
                if isCancelled() { throw GIFError.cancelled }
                let img: CGImage = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CGImage, Error>) in
                    generator.generateCGImageAsynchronously(for: t) { image, _, error in
                        if let image { c.resume(returning: image) }
                        else { c.resume(throwing: error ?? GIFError.noVideo) }
                    }
                }
                CGImageDestinationAddImage(dest, img, props)
                if (i + 1) % 5 == 0 || i + 1 == times.count {
                    progress(Double(i + 1) / Double(times.count) * 0.95)
                }
            }
            guard CGImageDestinationFinalize(dest) else { throw GIFError.writeFailed }
        }.value
    }
}

/// 导出面板:参数 + 进度 + 取消(M4 FR-23/FR-24)
@MainActor
final class GIFExportController: NSObject {
    static let shared = GIFExportController()

    private var window: NSWindow?
    private var url: URL?
    private var task: Task<Void, Never>?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var estimateLabel: NSTextField?
    private var fpsSeg: NSSegmentedControl?
    private var widthSeg: NSSegmentedControl?
    private var startField: NSTextField?
    private var endField: NSTextField?
    private var actionButton: NSButton?
    private var duration: Double = 0
    private var videoSize: CGSize = .zero

    private final class Flag: @unchecked Sendable {
        var cancelled = false
        let lock = NSLock()
        var value: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
    }
    private var flag = Flag()

    var isExporting: Bool { task != nil }

    // MARK: 手动导出(菜单 / 通知按钮)

    func show(url: URL) {
        self.url = url
        duration = 0
        videoSize = .zero
        flag = Flag()
        buildWindow()
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            duration = ((try? await asset.load(.duration)) ?? .zero).seconds
            if let t = try? await asset.loadTracks(withMediaType: .video).first {
                let natural = (try? await t.load(.naturalSize)) ?? .zero
                let raw = natural.applying((try? await t.load(.preferredTransform)) ?? .identity)
                videoSize = CGSize(width: abs(raw.width), height: abs(raw.height))
                // 视频轨可能短于容器时长(录制掉帧),预估按视频轨算才和实际导出一致
                let vd = ((try? await t.load(.timeRange))?.duration.seconds ?? 0)
                if vd > 0.01, vd < duration { duration = vd }
            }
            refreshEstimate()
        }
        NSApp.activateForUI()
        window?.center()
        // accessory 应用未激活时 makeKeyAndOrderFront 的排序不可靠,
        // orderFrontRegardless 保证落到屏幕最前
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    // MARK: 「直接录 GIF」自动流程

    func run(url: URL, params: GIFParams, deleteSource: Bool, duration: Double) async {
        self.url = url
        flag = Flag()
        self.duration = duration
        videoSize = .zero
        buildWindow()
        setRunning(true)
        statusLabel?.stringValue = L10n.t("正在导出 GIF…", "Exporting GIF…")
        NSApp.activateForUI()
        window?.center()
        window?.orderFrontRegardless()
        await perform(params: params, deleteSource: deleteSource)
        setRunning(false)
        window?.close()
        window = nil
    }

    // MARK: 界面

    private func buildWindow() {
        window?.close()
        typealias K = RecordPanelKit
        let width: CGFloat = 420, height: CGFloat = 380
        let w = EscClosableWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = L10n.t("导出 GIF", "Export GIF")
        // 从通知 action / 菜单触发时 App 可能完全未激活、用户也不在 PopBar 上次的 Space:
        // 让窗口直接落在当前活跃的桌面上
        w.collectionBehavior = [.moveToActiveSpace]
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let bg = GradientView(top: K.dyn(K.lightTheme.gradientTop, K.darkTheme.gradientTop),
                              bottom: K.dyn(K.lightTheme.gradientBottom, K.darkTheme.gradientBottom))
        bg.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bg)

        let fps = NSSegmentedControl(labels: ["5", "10", "15"], trackingMode: .selectOne,
                                     target: self, action: #selector(paramChanged))
        fps.selectedSegment = [5, 10, 15].firstIndex(of: GIFParams.defaults.fps) ?? 1
        let widths = [L10n.t("原始", "Original"), "800", "480"]
        let width_ = NSSegmentedControl(labels: widths, trackingMode: .selectOne,
                                        target: self, action: #selector(paramChanged))
        width_.selectedSegment = [0, 800, 480].firstIndex(of: GIFParams.defaults.width) ?? 1
        fpsSeg = fps
        widthSeg = width_

        let start = NSTextField(string: "0.0")
        let end = NSTextField(string: "")
        start.placeholderString = "0.0"
        end.placeholderString = L10n.t("结尾", "End")
        [start, end].forEach { $0.widthAnchor.constraint(equalToConstant: 70).isActive = true }
        startField = start
        endField = end
        let range = NSStackView(views: [start, K.label("→"), end])
        range.orientation = .horizontal
        range.spacing = 6

        let est = K.label("", size: 11, secondary: true)
        est.lineBreakMode = .byTruncatingTail
        estimateLabel = est

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        progressBar = bar

        let status = K.label(L10n.t("调整参数后导出", "Adjust parameters, then export"), size: 11, secondary: true)
        status.lineBreakMode = .byTruncatingTail
        statusLabel = status

        let action = NSButton(title: L10n.t("导出", "Export"), target: self, action: #selector(startExport))
        action.bezelStyle = .rounded
        action.keyEquivalent = "\r"
        let cancel = NSButton(title: L10n.t("取消", "Cancel"), target: self, action: #selector(cancelExport))
        cancel.bezelStyle = .rounded
        actionButton = action
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, action])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let main = NSStackView(views: [
            K.sectionHeader(L10n.t("参数", "Parameters")),
            K.card([K.row(L10n.t("帧率", "FPS"), L10n.t("帧数越多越流畅,体积也越大", "More frames: smoother, bigger"), fps),
                    K.row(L10n.t("宽度", "Width"), L10n.t("只缩小,不放大", "Only scales down"), width_)]),
            K.sectionHeader(L10n.t("裁剪", "Trim")),
            K.card([K.row(L10n.t("区间(秒)", "Range (s)"), L10n.t("结尾留空表示到最后", "Leave the end empty for the whole clip"), range)]),
        ])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 14
        main.translatesAutoresizingMaskIntoConstraints = false
        for v in main.arrangedSubviews { v.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true }

        let footer = NSStackView(views: [est, bar, status, buttons])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(main)
        root.addSubview(sep)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bg.topAnchor.constraint(equalTo: root.topAnchor),
            bg.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            main.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            bar.widthAnchor.constraint(equalTo: footer.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: footer.widthAnchor),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
        ])
        w.contentView = root
        window = w
        refreshEstimate()
    }

    private func currentParams() -> GIFParams {
        let fps = [5, 10, 15][max(fpsSeg?.selectedSegment ?? 1, 0)]
        let width = [0, 800, 480][max(widthSeg?.selectedSegment ?? 1, 0)]
        var p = GIFParams.defaults
        p.fps = fps
        p.width = width
        p.start = Double(startField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        p.end = Double(endField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "")
        return p
    }

    private func refreshEstimate() {
        guard let est = estimateLabel else { return }
        let p = currentParams()
        let range = max((p.end ?? duration) - p.start, 0)
        let (frames, size) = RecordGIF.plan(duration: range > 0 ? range : duration,
                                            size: videoSize.width > 0 ? videoSize : CGSize(width: 1920, height: 1080),
                                            fps: p.fps, width: p.width)
        let bytes = RecordUtil.gifBytes(frames: frames, width: Int(size.width), height: Int(size.height))
        est.stringValue = L10n.t("预估:", "Estimated: ") + RecordUtil.byteText(bytes)
            + " · \(frames) " + L10n.t("帧", "frames") + " · \(Int(size.width))×\(Int(size.height))"
        est.textColor = bytes > 20 * 1024 * 1024 ? .systemOrange : .secondaryLabelColor
    }

    @objc private func paramChanged() { refreshEstimate() }

    @objc private func cancelExport() {
        flag.lock.lock(); flag.cancelled = true; flag.lock.unlock()
        task?.cancel()
        task = nil
        setRunning(false)
        statusLabel?.stringValue = L10n.t("已取消", "Cancelled")
        window?.close()
        window = nil
    }

    @objc private func startExport() {
        guard url != nil, task == nil else { return }
        flag = Flag()
        setRunning(true)
        let params = currentParams()
        task = Task { @MainActor in
            await perform(params: params, deleteSource: false)
            task = nil
            setRunning(false)
        }
    }

    private func setRunning(_ on: Bool) {
        progressBar?.isHidden = !on
        progressBar?.doubleValue = 0
        actionButton?.isEnabled = !on
        fpsSeg?.isEnabled = !on
        widthSeg?.isEnabled = !on
        startField?.isEnabled = !on
        endField?.isEnabled = !on
    }

    private func perform(params: GIFParams, deleteSource: Bool) async {
        guard let url else { return }
        let flag = self.flag
        do {
            let gif = try await RecordGIF.export(
                url: url, params: params,
                progress: { v in Task { @MainActor in GIFExportController.shared.setProgress(v) } },
                isCancelled: { flag.value })
            if ConfigStore.shared.config.snap.record.gif.copyToClipboard { PasteboardGuard.write(urls: [gif]) }
            if deleteSource { try? FileManager.default.removeItem(at: url) }
            let d = max((params.end ?? duration) - params.start, 0)
            RecordHistory.shared.add(url: gif, duration: d, isGIF: true)
            RecordNotify.saved(gif, duration: d, interrupted: false,
                               title: L10n.t("GIF 已导出", "GIF exported"))
            statusLabel?.stringValue = L10n.t("导出完成", "Export complete")
        } catch GIFError.cancelled {
            statusLabel?.stringValue = L10n.t("已取消", "Cancelled")
        } catch {
            statusLabel?.stringValue = error.localizedDescription
            // 自动流程失败:保留原视频并记进「最近录制」,别让文件找不到
            if deleteSource {
                RecordHistory.shared.add(url: url, duration: duration, isGIF: false)
                RecordNotify.saved(url, duration: duration, interrupted: false)
            } else {
                RecordNotify.fallback(url, text: error.localizedDescription)
            }
        }
    }

    private func setProgress(_ v: Double) {
        progressBar?.doubleValue = v
        statusLabel?.stringValue = L10n.t("正在导出 GIF…", "Exporting GIF…")
            + " \(Int((v * 100).rounded()))%"
    }
}
