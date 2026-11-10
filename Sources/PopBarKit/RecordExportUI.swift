import Cocoa
@preconcurrency import AVFoundation
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 统一导出面板:裁剪 / 缩放 / 压缩 / 混音 / 点击涟漪 / 摄像头 PiP / 水印
/// (PRD-screen-recording-v2.md FR-36 ~ FR-44)
@MainActor
final class RecordExportController: NSObject {
    static let shared = RecordExportController()

    private var window: NSWindow?
    private var url: URL?
    private var sidecar: RecordSidecar?
    private var duration: Double = 0
    private var sourceSize: CGSize = .zero
    private var task: Task<Void, Never>?
    private var flag = Flag()

    private var startField: NSTextField?
    private var endField: NSTextField?
    private var markerRow: NSStackView?
    private var widthSeg: NSSegmentedControl?
    private var qualitySeg: NSSegmentedControl?
    private var containerSeg: NSSegmentedControl?
    private var gifFpsSeg: NSSegmentedControl?
    /// 上一次的容器选项,用来识别「刚切到 GIF」
    private var lastContainerIndex = 0
    private var clickSwitch: NSSwitch?
    private var cameraSwitch: NSSwitch?
    private var markSwitch: NSSwitch?
    private var markField: NSTextField?
    private var sysSlider: NSSlider?
    private var micSlider: NSSlider?
    private var sysLabel: NSTextField?
    private var micLabel: NSTextField?
    private var clipboardSwitch: NSSwitch?
    private var infoLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var exportButton: NSButton?
    private var presetButton: NSButton?

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func set() { lock.lock(); cancelled = true; lock.unlock() }
    }

    var isExporting: Bool { task != nil }

    // MARK: - 入口

    enum Format { case video, gif }

    /// 交互式打开(Deck 列表 / 菜单 / 通知按钮)。
    /// 传进来的是导出成品时自动换成它的原始录屏:点击坐标、摄像头、标记点都挂在原始文件上,
    /// 在成品上再导出既拿不到这些数据,重新编码还会再损一次画质。
    func show(url: URL, format: Format? = nil) {
        guard !isExporting else { return }
        let target = RecordHistory.shared.originalURL(for: url) ?? url
        Task { @MainActor in
            await load(url: target)
            buildWindow()
            if format == .gif { selectContainer(2) }
            NSApp.activateForUI()
            window?.center()
            window?.orderFrontRegardless()
            window?.makeKey()
        }
    }

    /// 录制结束后的自动导出:面板照常出现显示进度,结束后自关(FR-44)
    func runAutomatic(url: URL, params: RecordExportParams) async {
        await load(url: url)
        buildWindow()
        apply(params: params)
        NSApp.activateForUI()
        window?.center()
        window?.orderFrontRegardless()
        await perform()
        window?.close()
        window = nil
    }

    /// 「直接录 GIF」:按 GIF 偏好整段转换,成功后删掉中间视频
    func runAutomaticGIF(url: URL, duration total: Double) async {
        await load(url: url)
        if duration <= 0.01 { duration = total }
        buildWindow()
        let auto = GIFParams.auto
        var params = RecordExportParams()
        params.container = "gif"
        params.width = auto.width
        params.gifFps = auto.fps
        params.copyToClipboard = ConfigStore.shared.config.snap.record.gif.copyToClipboard
        apply(params: params)
        NSApp.activateForUI()
        window?.center()
        window?.orderFrontRegardless()
        await perform(override: params, deleteSource: true)
        window?.close()
        window = nil
    }

    // MARK: - 载入

    private func load(url: URL) async {
        self.url = url
        flag = Flag()
        sidecar = RecordDataStore.load(for: url)
        let asset = AVURLAsset(url: url)
        var seconds = ((try? await asset.load(.duration)) ?? .zero).seconds
        sourceSize = .zero
        if let t = try? await asset.loadTracks(withMediaType: .video).first {
            let n = (try? await t.load(.naturalSize)) ?? .zero
            let p = (try? await t.load(.preferredTransform)) ?? .identity
            let r = CGRect(origin: .zero, size: n).applying(p)
            sourceSize = CGSize(width: abs(r.width), height: abs(r.height))
            // 录制掉帧时视频轨短于容器,预估与裁剪都按视频轨算
            let vd = ((try? await t.load(.timeRange))?.duration.seconds) ?? 0
            if vd > 0.01, vd < seconds { seconds = vd }
        }
        duration = seconds
    }

    // MARK: - 界面

    private func label(_ s: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        RecordPanelKit.label(s, size: size, secondary: secondary)
    }
    private func sectionHeader(_ t: String) -> NSView { RecordPanelKit.sectionHeader(t) }
    private func row(_ title: String, _ subtitle: String = "", _ control: NSView) -> NSView {
        RecordPanelKit.row(title, subtitle, control)
    }
    private func plainRow(_ v: NSView) -> NSView { RecordPanelKit.plainRow(v) }
    private func card(_ rows: [NSView]) -> NSView { RecordPanelKit.card(rows) }
    private func dyn(_ l: NSColor, _ d: NSColor) -> NSColor { RecordPanelKit.dyn(l, d) }
    private var lightTheme: PanelTheme { RecordPanelKit.lightTheme }
    private var darkTheme: PanelTheme { RecordPanelKit.darkTheme }

    private func buildWindow() {
        window?.close()
        let width: CGFloat = 520
        let w = EscClosableWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 680),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = L10n.t("编辑并导出", "Edit & Export")
        w.collectionBehavior = [.moveToActiveSpace]
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 680))
        let bg = GradientView(top: dyn(lightTheme.gradientTop, darkTheme.gradientTop),
                              bottom: dyn(lightTheme.gradientBottom, darkTheme.gradientBottom))
        bg.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bg)

        // 区间
        let start = NSTextField(string: "0.0")
        let end = NSTextField(string: "")
        start.placeholderString = "0.0"
        end.placeholderString = L10n.t("结尾", "End")
        for f in [start, end] {
            f.widthAnchor.constraint(equalToConstant: 64).isActive = true
            f.delegate = self
        }
        startField = start
        endField = end
        let rangeRow = NSStackView(views: [start, label("→"), end])
        rangeRow.orientation = .horizontal
        rangeRow.spacing = 6

        // 标记点快捷定位
        let markers = NSStackView()
        markers.orientation = .horizontal
        markers.spacing = 6
        markerRow = markers

        // 分辨率 / 质量 / 容器
        let width_ = NSSegmentedControl(labels: [L10n.t("原始", "Original"), "1920", "1280", "854"],
                                        trackingMode: .selectOne, target: self, action: #selector(refresh))
        let quality = NSSegmentedControl(labels: [L10n.t("高", "High"), L10n.t("中", "Medium"), L10n.t("低", "Low")],
                                         trackingMode: .selectOne, target: self, action: #selector(refresh))
        let container = NSSegmentedControl(labels: ["MP4", "MOV", "GIF"], trackingMode: .selectOne,
                                           target: self, action: #selector(containerChanged))
        let gifFps = NSSegmentedControl(labels: ["5", "10", "15"], trackingMode: .selectOne,
                                        target: self, action: #selector(refresh))
        widthSeg = width_
        qualitySeg = quality
        containerSeg = container
        gifFpsSeg = gifFps

        // 开关(与设置窗口一致用小号)
        let clickSw = NSSwitch()
        let cameraSw = NSSwitch()
        let markSw = NSSwitch()
        let clipSw = NSSwitch()
        for s in [clickSw, cameraSw, markSw, clipSw] {
            s.controlSize = .small
            s.target = self
            s.action = #selector(refresh)
        }
        clickSwitch = clickSw
        cameraSwitch = cameraSw
        markSwitch = markSw
        clipboardSwitch = clipSw

        let markText = NSTextField(string: ConfigStore.shared.config.snap.record.watermark.text)
        markText.placeholderString = L10n.t("水印文字", "Watermark text")
        markText.widthAnchor.constraint(equalToConstant: 160).isActive = true
        markText.delegate = self
        markField = markText

        // 音量
        let sys = NSSlider(value: 1, minValue: 0, maxValue: 2, target: self, action: #selector(refresh))
        let mic = NSSlider(value: 1, minValue: 0, maxValue: 2, target: self, action: #selector(refresh))
        for s in [sys, mic] { s.widthAnchor.constraint(equalToConstant: 140).isActive = true }
        sysSlider = sys
        micSlider = mic
        let sysText = label("100%", size: 11, secondary: true)
        let micText = label("100%", size: 11, secondary: true)
        for t in [sysText, micText] { t.widthAnchor.constraint(equalToConstant: 36).isActive = true; t.alignment = .right }
        sysLabel = sysText
        micLabel = micText
        let sysStack = NSStackView(views: [sys, sysText])
        let micStack = NSStackView(views: [mic, micText])
        for s in [sysStack, micStack] { s.orientation = .horizontal; s.spacing = 6; s.alignment = .centerY }

        // 信息 / 进度 / 状态
        let info = label("", size: 11, secondary: true)
        info.lineBreakMode = .byTruncatingTail
        infoLabel = info
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.isHidden = true
        progressBar = bar
        let status = label(L10n.t("调整参数后导出", "Adjust parameters, then export"), size: 11, secondary: true)
        status.lineBreakMode = .byTruncatingTail
        statusLabel = status

        // 按钮
        let preset = NSButton(title: L10n.t("适配分享", "Sharing preset"), target: self, action: #selector(applySharingPreset))
        preset.bezelStyle = .rounded
        preset.toolTip = L10n.t("1280 宽 + 中等质量 + MP4 + 复制到剪贴板",
                               "1280 wide + medium quality + MP4 + copy to clipboard")
        presetButton = preset
        let doExport = NSButton(title: L10n.t("导出", "Export"), target: self, action: #selector(startExport))
        doExport.bezelStyle = .rounded
        doExport.keyEquivalent = "\r"
        exportButton = doExport
        let cancel = NSButton(title: L10n.t("取消", "Cancel"), target: self, action: #selector(cancelExport))
        cancel.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [preset, spacer, cancel, doExport])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        // 可滚动的参数区:分组卡片
        let main = NSStackView(views: [
            sectionHeader(L10n.t("裁剪", "Trim")),
            card([row(L10n.t("区间（秒）", "Range (s)"), L10n.t("起止时间，留空结尾表示到最后", "Leave the end empty for the whole clip"), rangeRow),
                  plainRow(markers)]),
            sectionHeader(L10n.t("输出", "Output")),
            card([row(L10n.t("分辨率", "Resolution"), "", width_),
                  row(L10n.t("质量", "Quality"), "", quality),
                  row(L10n.t("格式", "Format"),
                      L10n.t("GIF 适合 README / 文档 / 聊天里自动播放，没有声音", "GIF autoplays in READMEs, docs and chats; no audio"),
                      container),
                  row(L10n.t("GIF 帧率", "GIF FPS"),
                      L10n.t("帧数越多越流畅，体积也越大", "More frames: smoother, bigger"), gifFps)]),
            sectionHeader(L10n.t("画面", "Picture")),
            card([row(L10n.t("点击涟漪", "Click ripple"),
                      L10n.t("在每次点击处扩散一圈提示，烧进画面", "Draw a ripple at every click, baked in"), clickSw),
                  row(L10n.t("摄像头画中画", "Camera PiP"),
                      L10n.t("按录制时的位置叠加摄像头画面", "Overlay the camera footage"), cameraSw),
                  row(L10n.t("水印", "Watermark"),
                      L10n.t("图片水印与位置请在设置里调整", "Image and position are set in Settings"), markSw),
                  row(L10n.t("水印文字", "Watermark text"), "", markText)]),
            sectionHeader(L10n.t("声音", "Audio")),
            card([row(L10n.t("系统声音", "System audio"), "", sysStack),
                  row(L10n.t("麦克风", "Microphone"),
                      L10n.t("听感相反就交换两个滑块", "Swap the sliders if it sounds reversed"), micStack)]),
            sectionHeader(L10n.t("完成后", "After export")),
            card([row(L10n.t("复制到剪贴板", "Copy to clipboard"), "", clipSw)]),
        ])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 14
        main.translatesAutoresizingMaskIntoConstraints = false
        for v in main.arrangedSubviews { v.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(main)
        scroll.documentView = doc
        root.addSubview(scroll)

        // 固定底栏:信息 / 进度 / 状态 / 按钮,滚动时始终可见
        let footerStack = NSStackView(views: [info, bar, status, buttonRow])
        footerStack.orientation = .vertical
        footerStack.alignment = .leading
        footerStack.spacing = 8
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sep)
        root.addSubview(footerStack)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bg.topAnchor.constraint(equalTo: root.topAnchor),
            bg.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            bar.widthAnchor.constraint(equalTo: footerStack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: footerStack.widthAnchor),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -12),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: sep.topAnchor),

            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            main.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            main.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            main.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
            main.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
        ])
        w.contentView = root
        window = w
        syncFromConfig()
        refresh()
    }

    /// 面板初值来自偏好设置
    private func syncFromConfig() {
        let c = ConfigStore.shared.config.snap.record
        widthSeg?.selectedSegment = [0, 1920, 1280, 854].firstIndex(of: c.export.width) ?? 0
        qualitySeg?.selectedSegment = ["high", "medium", "low"].firstIndex(of: c.export.quality) ?? 0
        containerSeg?.selectedSegment = c.export.container == "mov" ? 1 : 0
        lastContainerIndex = containerSeg?.selectedSegment ?? 0
        gifFpsSeg?.selectedSegment = Self.gifFpsIndex(c.gif.fps)
        clickSwitch?.state = c.click.enabled ? .on : .off
        cameraSwitch?.state = (sidecar?.camera != nil) ? .on : .off
        markSwitch?.state = c.watermark.enabled ? .on : .off
        markField?.stringValue = c.watermark.text
        sysSlider?.doubleValue = c.export.systemVolume
        micSlider?.doubleValue = c.export.micVolume
        clipboardSwitch?.state = c.export.copyToClipboard ? .on : .off
        endField?.stringValue = ""
        startField?.stringValue = "0.0"
        rebuildMarkers()
    }

    private func apply(params: RecordExportParams) {
        widthSeg?.selectedSegment = [0, 1920, 1280, 854].firstIndex(of: params.width) ?? 0
        qualitySeg?.selectedSegment = ["high", "medium", "low"].firstIndex(of: params.quality) ?? 0
        containerSeg?.selectedSegment = Self.containers.firstIndex(of: params.container) ?? 0
        lastContainerIndex = containerSeg?.selectedSegment ?? 0
        gifFpsSeg?.selectedSegment = Self.gifFpsIndex(params.gifFps)
        clickSwitch?.state = params.burnClicks ? .on : .off
        cameraSwitch?.state = params.camera != nil ? .on : .off
        markSwitch?.state = params.watermark.enabled ? .on : .off
        markField?.stringValue = params.watermark.text
        sysSlider?.doubleValue = params.systemVolume
        micSlider?.doubleValue = params.micVolume
        clipboardSwitch?.state = params.copyToClipboard ? .on : .off
        startField?.stringValue = String(format: "%.1f", params.start)
        endField?.stringValue = params.end.map { String(format: "%.1f", $0) } ?? ""
        refresh()
    }

    private func rebuildMarkers() {
        guard let row = markerRow else { return }
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let marks = sidecar?.markers ?? []
        guard !marks.isEmpty else {
            row.addArrangedSubview(label(L10n.t("（录制中没有标记点）", "(no markers in this recording)"),
                                         size: 11, secondary: true))
            return
        }
        for (i, m) in marks.enumerated() {
            let b = NSButton(title: "\(i + 1) · \(RecordUtil.durationText(m.t))",
                             target: self, action: #selector(markerTapped(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = i
            b.toolTip = L10n.t("点一下设为起点，⌥ 点击设为终点",
                              "Click to set the start, ⌥-click to set the end")
            row.addArrangedSubview(b)
        }
    }

    // MARK: - 参数

    private static let containers = ["mp4", "mov", "gif"]
    private static let gifFpsOptions = [5, 10, 15]
    private static func gifFpsIndex(_ fps: Int) -> Int {
        gifFpsOptions.firstIndex(of: fps) ?? (fps < 8 ? 0 : fps < 13 ? 1 : 2)
    }

    @objc private func containerChanged() { selectContainer(containerSeg?.selectedSegment ?? 0) }

    /// 切到 GIF 时,原始分辨率的 GIF 动辄几十 MB:顺手降到 854 宽
    private func selectContainer(_ index: Int) {
        containerSeg?.selectedSegment = index
        if index == 2, lastContainerIndex != 2, (widthSeg?.selectedSegment ?? 0) == 0 {
            widthSeg?.selectedSegment = 3
        }
        lastContainerIndex = index
        refresh()
    }

    private func currentParams() -> RecordExportParams {
        var p = RecordExportParams()
        p.start = Double(startField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        p.end = Double(endField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "")
        p.width = [0, 1920, 1280, 854][max(widthSeg?.selectedSegment ?? 0, 0)]
        p.quality = ["high", "medium", "low"][max(qualitySeg?.selectedSegment ?? 0, 0)]
        p.container = Self.containers[min(max(containerSeg?.selectedSegment ?? 0, 0), 2)]
        p.gifFps = Self.gifFpsOptions[min(max(gifFpsSeg?.selectedSegment ?? 1, 0), 2)]
        p.systemVolume = sysSlider?.doubleValue ?? 1
        p.micVolume = micSlider?.doubleValue ?? 1
        p.burnClicks = (clickSwitch?.state ?? .off) == .on
        p.click = ConfigStore.shared.config.snap.record.click
        p.clicks = sidecar?.clicks ?? []
        p.micEnabled = sidecar?.micEnabled ?? false
        if (cameraSwitch?.state ?? .off) == .on, let cam = sidecar?.camera, let videoURL = url {
            let camURL = RecordDataStore.cameraURL(for: videoURL)
            if FileManager.default.fileExists(atPath: camURL.path) {
                p.camera = cam
                p.cameraURL = camURL
            }
        }
        var wm = ConfigStore.shared.config.snap.record.watermark
        wm.enabled = (markSwitch?.state ?? .off) == .on
        wm.text = markField?.stringValue ?? wm.text
        p.watermark = wm
        p.copyToClipboard = (clipboardSwitch?.state ?? .off) == .on
        return p
    }

    @objc private func refresh() {
        sysLabel?.stringValue = "\(Int(((sysSlider?.doubleValue ?? 1) * 100).rounded()))%"
        micLabel?.stringValue = "\(Int(((micSlider?.doubleValue ?? 1) * 100).rounded()))%"
        let p = currentParams()
        // 摄像头开关在没录到摄像头时置灰
        cameraSwitch?.isEnabled = sidecar?.camera != nil && !isExporting
        // GIF 没有声音、没有码率档位
        let running = isExporting
        gifFpsSeg?.isEnabled = p.isGIF && !running
        qualitySeg?.isEnabled = !p.isGIF && !running
        sysSlider?.isEnabled = !p.isGIF && !running
        micSlider?.isEnabled = !p.isGIF && !running
        let clipCount = p.clicks.filter { $0.t >= p.start && $0.t <= (p.end ?? duration) }.count
        let target = RecordExportUtil.targetSize(source: sourceSize.width > 0 ? sourceSize : CGSize(width: 1920, height: 1080),
                                                 width: p.width)
        let span = max((p.end ?? duration) - p.start, 0)
        var parts: [String] = []
        parts.append(L10n.t("成品 \(Int(target.width))×\(Int(target.height))",
                            "Output \(Int(target.width))×\(Int(target.height))"))
        parts.append(L10n.t("时长 \(RecordUtil.durationText(span))", "Length \(RecordUtil.durationText(span))"))
        if p.burnClicks { parts.append(L10n.t("\(clipCount) 次点击", "\(clipCount) clicks")) }
        if p.camera != nil { parts.append(L10n.t("含摄像头", "with camera")) }
        if p.isGIF {
            let plan = RecordGIF.plan(duration: span > 0 ? span : duration, size: target, fps: p.gifFps, width: 0)
            let bytes = RecordUtil.gifBytes(frames: plan.frames, width: Int(plan.size.width), height: Int(plan.size.height))
            parts.append(L10n.t("GIF 约 ", "GIF ≈ ") + RecordUtil.byteText(bytes))
            infoLabel?.textColor = bytes > 20 * 1024 * 1024 ? Theme.warning : Theme.muted
        } else {
            infoLabel?.textColor = Theme.muted
        }
        infoLabel?.stringValue = parts.joined(separator: " · ")
    }

    @objc private func markerTapped(_ sender: NSButton) {
        let marks = sidecar?.markers ?? []
        guard sender.tag >= 0, sender.tag < marks.count else { return }
        let t = marks[sender.tag].t
        let option = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        if option { endField?.stringValue = String(format: "%.1f", t) }
        else { startField?.stringValue = String(format: "%.1f", t) }
        refresh()
    }

    @objc private func applySharingPreset() {
        widthSeg?.selectedSegment = 2          // 1280
        qualitySeg?.selectedSegment = 1        // 中
        containerSeg?.selectedSegment = 0      // MP4
        clickSwitch?.state = .on
        clipboardSwitch?.state = .on
        refresh()
    }

    // MARK: - 导出

    @objc private func startExport() {
        guard url != nil, task == nil else { return }
        task = Task { @MainActor in
            await perform()
            task = nil
            setRunning(false)
        }
    }

    /// 取消 = 中止正在跑的导出(如果有)并关闭面板,和 GIF 导出面板的行为一致
    @objc private func cancelExport() {
        flag.set()
        task?.cancel()
        task = nil
        setRunning(false)
        window?.close()
        window = nil
    }

    private func setRunning(_ on: Bool) {
        progressBar?.isHidden = !on
        progressBar?.doubleValue = 0
        exportButton?.isEnabled = !on
        presetButton?.isEnabled = !on
        [startField, endField, markField].forEach { $0?.isEnabled = !on }
        [widthSeg, qualitySeg, containerSeg, gifFpsSeg].forEach { $0?.isEnabled = !on }
        [clickSwitch, markSwitch, clipboardSwitch].forEach { $0?.isEnabled = !on }
        cameraSwitch?.isEnabled = !on && sidecar?.camera != nil
        [sysSlider, micSlider].forEach { $0?.isEnabled = !on }
        if on { statusLabel?.stringValue = L10n.t("正在导出…", "Exporting…") }
        else { refresh() }
    }

    /// override 给自动流程用:直接按传入参数导出,不经面板控件回读(面板档位表达不了任意宽度)。
    /// deleteSource 只在「直接录 GIF」时为 true:成品出来后删掉中间视频,失败则保留它。
    private func perform(override: RecordExportParams? = nil, deleteSource: Bool = false) async {
        guard let url else { return }
        let params = override ?? currentParams()
        let dir = (ConfigStore.shared.config.snap.saveDir as NSString).expandingTildeInPath
        let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = params.isGIF ? "gif" : params.container
        let dest = RecordUtil.uniqueURL(in: deleteSource ? url.deletingLastPathComponent() : dirURL,
                                        stem: deleteSource ? stem : "\(stem)-edit", ext: ext)
        setRunning(true)
        let flag = self.flag
        let progress: @Sendable (Double) -> Void = { v in
            Task { @MainActor in RecordExportController.shared.setProgress(v) }
        }
        do {
            let out: URL
            if params.isGIF {
                out = try await exportGIF(source: url, params: params, to: dest,
                                          progress: progress, isCancelled: { flag.value })
            } else {
                out = try await RecordExport.export(source: url, params: params, to: dest,
                                                    progress: progress, isCancelled: { flag.value })
            }
            if params.copyToClipboard { PasteboardGuard.write(urls: [out]) }
            if deleteSource {
                try? FileManager.default.removeItem(at: url)
                RecordDataStore.remove(for: url)
            }
            let d = max((params.end ?? duration) - params.start, 0)
            RecordHistory.shared.add(url: out, duration: d, isGIF: params.isGIF,
                                     source: deleteSource ? nil : url)
            let title = params.isGIF ? L10n.t("GIF 已导出", "GIF exported") : L10n.t("导出完成", "Export finished")
            RecordNotify.saved(out, duration: d, interrupted: false, title: title)
            statusLabel?.stringValue = title
        } catch RecordExportError.cancelled {
            statusLabel?.stringValue = L10n.t("已取消", "Cancelled")
        } catch GIFError.cancelled {
            statusLabel?.stringValue = L10n.t("已取消", "Cancelled")
        } catch {
            statusLabel?.stringValue = error.localizedDescription
            if deleteSource {
                // 自动 GIF 失败:保留原视频并记进「最近录制」,别让文件找不到
                RecordHistory.shared.add(url: url, duration: duration)
                RecordNotify.saved(url, duration: duration, interrupted: false)
            } else {
                RecordNotify.fallback(url, text: error.localizedDescription)
            }
        }
        setRunning(false)
    }

    /// GIF:没有需要烧进画面的东西时直接从源视频抽帧(裁剪 + 缩放由 RecordGIF 完成);
    /// 有涟漪 / 水印 / 摄像头时先合成一段临时 MP4,再从它抽帧 —— 这样 GIF 里也能看到点击位置。
    private func exportGIF(source: URL, params: RecordExportParams, to dest: URL,
                           progress: @escaping @Sendable (Double) -> Void,
                           isCancelled: @escaping @Sendable () -> Bool) async throws -> URL {
        let end = params.end ?? duration
        let hasClicks = params.burnClicks && params.clicks.contains { $0.t >= params.start && $0.t <= end }
        let needsRender = hasClicks || params.watermark.enabled || params.camera != nil
        guard needsRender else {
            let gp = GIFParams(fps: params.gifFps, width: params.width,
                               start: params.start, end: params.end, loop: true)
            return try await RecordGIF.export(url: source, params: gp, to: dest,
                                              progress: progress, isCancelled: isCancelled)
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopBar-gif-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        var vp = params
        vp.container = "mp4"
        vp.quality = "high"
        vp.copyToClipboard = false
        _ = try await RecordExport.export(source: source, params: vp, to: temp,
                                          progress: { v in progress(v * 0.5) }, isCancelled: isCancelled)
        let gp = GIFParams(fps: params.gifFps, width: 0, start: 0, end: nil, loop: true)
        return try await RecordGIF.export(url: temp, params: gp, to: dest,
                                          progress: { v in progress(0.5 + v * 0.5) }, isCancelled: isCancelled)
    }

    private func setProgress(_ v: Double) {
        progressBar?.doubleValue = v
        statusLabel?.stringValue = L10n.t("正在导出…", "Exporting…")
            + " \(Int((v * 100).rounded()))%"
    }
}

extension RecordExportController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { refresh() }
}
