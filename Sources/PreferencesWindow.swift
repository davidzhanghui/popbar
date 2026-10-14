import Cocoa
import AVFoundation
import ServiceManagement

/// 「偏好设置」窗口:分组列表样式,每个改动立即写入 config.json 并生效。
/// 与「AI 翻译设置」不同——这里没有草稿态,不需要点保存。
final class PreferencesWindowController: NSObject, NSTextFieldDelegate {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private var segs: [NSSegmentedControl] = []
    private var switches: [NSSwitch] = []
    private var textFields: [NSTextField] = []
    private var textFieldKeys: [ObjectIdentifier: String] = [:]
    private var micDevicePopup: NSPopUpButton?
    private let micMonitor = MicLevelMonitor()
    private var micLevelMeter: WaveBarsView?
    private var micTestButton: NSButton?
    private var speakVoicePopup: NSPopUpButton?
    private var speakRateSlider: NSSlider?
    private var speakRateLabel: NSTextField?
    private let previewSpeech = AVSpeechSynthesizer()
    private var cameraDevicePopup: NSPopUpButton?
    private var watermarkOpacitySlider: NSSlider?
    private var watermarkOpacityLabel: NSTextField?

    private let lightTheme = PanelTheme(dark: false)
    private let darkTheme = PanelTheme(dark: true)
    private func dyn(_ l: NSColor, _ d: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l }
    }
    private var surfaceColor: NSColor { dyn(lightTheme.surface, darkTheme.surface) }
    private var borderTint: NSColor { dyn(lightTheme.surfaceBorder, darkTheme.surfaceBorder) }
    private var accentText: NSColor { dyn(lightTheme.brandText, darkTheme.brandText) }

    private var segKeys: [ObjectIdentifier: (key: String, values: [String])] = [:]
    private var switchKeys: [ObjectIdentifier: String] = [:]

    /// 当前 tab 序号、各 tab 的滚动视图(切换时显隐)与顶部 tab 栏
    private var tabIndex = 0
    private var tabScrolls: [NSScrollView] = []
    private var tabHeights: [CGFloat] = []
    private var tabBarControl: NSSegmentedControl?

    var isVisible: Bool { window?.isVisible ?? false }
    var frame: CGRect { window?.frame ?? .zero }

    /// 「AI 翻译」在 tab 栏里的位置(通用/功能/截屏/录屏/AI 翻译/工具条/关于)
    static let aiTabIndex = 4
    /// 窗口宽高固定,与旧的「AI 翻译设置」窗口一致
    static let contentWidth: CGFloat = 780

    // MARK: - 显示

    /// tab 传 nil 时保持上次停留的 tab;显式传入则切到该 tab
    func show(tab: Int? = nil) {
        if let tab { tabIndex = tab }
        if window == nil { buildWindow() }
        rebuild()          // 语言切换后重建界面,文字即时生效
        syncControls()
        SettingsWindowController.shared.windowShown()
        NSApp.activateForUI()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let w = EscClosableWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        // AI 翻译 tab 的未保存草稿关闭确认由它处理
        w.delegate = SettingsWindowController.shared
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: w, queue: .main) { [weak self] _ in
            self?.stopMicTest()   // 测试中的采集随窗口关闭停止
            self?.previewSpeech.stopSpeaking(at: .immediate)
        }
        window = w
    }

    // MARK: - 界面

    private func rebuild() {
        guard let w = window else { return }
        w.title = L10n.t("设置", "Settings")
        stopMicTest()   // 重建界面时控件对象换新,顺手把测试停掉
        segs.removeAll()
        switches.removeAll()
        segKeys.removeAll()
        switchKeys.removeAll()
        textFields.removeAll()
        textFieldKeys.removeAll()

        let root = NSView()
        let bg = GradientView(top: dyn(lightTheme.gradientTop, darkTheme.gradientTop),
                              bottom: dyn(lightTheme.gradientBottom, darkTheme.gradientBottom))
        bg.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bg.topAnchor.constraint(equalTo: root.topAnchor),
            bg.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // 顶部 tab 栏;每个 tab 一份独立滚动内容,切换时显隐
        let ft = featuresTabs()
        let tabs: [(String, [NSView])] = [
            (L10n.t("通用", "General"), generalTab()),
            (L10n.t("功能", "Features"), ft.features),
            (L10n.t("截屏", "Screenshot"), ft.snap),
            (L10n.t("录屏", "Recording"), ft.record),
            (L10n.t("AI 翻译", "AI"), [SettingsWindowController.shared.buildContent(in: w)]),
            (L10n.t("工具条", "Toolbar"), toolbarTab()),
            (L10n.t("关于", "About"), aboutTab()),
        ]
        let tabBar = NSSegmentedControl(labels: tabs.map { $0.0 }, trackingMode: .selectOne,
                                        target: self, action: #selector(tabChanged(_:)))
        tabBar.selectedSegment = min(tabIndex, tabs.count - 1)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBarControl = tabBar
        root.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
        ])

        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 12),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        tabScrolls = []
        tabHeights = []
        for (i, tab) in tabs.enumerated() {
            let (scroll, contentH) = contentScroll(tab.1)
            host.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: host.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            scroll.isHidden = i != tabIndex
            tabScrolls.append(scroll)
            tabHeights.append(contentH)
        }

        root.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        w.contentView = root
        root.layoutSubtreeIfNeeded()
        applyFixedSize()
    }

    // MARK: - 各 tab 内容

    private func generalTab() -> [NSView] {
        [sectionHeader(L10n.t("偏好", "Preferences")), card([
            row(L10n.t("外观", "Appearance"),
                L10n.t("浅色、深色,或跟随系统", "Light, Dark, or follow system"),
                seg("appearance", L10n.t("跟随系统", "System"), L10n.t("浅色", "Light"), L10n.t("深色", "Dark"),
                    values: ["system", "light", "dark"])),
            row(L10n.t("语言", "Language"),
                L10n.t("界面语言,立即生效", "UI language, applies instantly"),
                seg("language", L10n.t("跟随系统", "System"), "English", "中文",
                    values: ["system", "en", "zh"])),
            row(L10n.t("托盘图标", "Tray Icon"),
                L10n.t("左键点击菜单栏 PopBar 图标", "Left-click action on the menu bar icon"),
                seg("trayClick", L10n.t("菜单", "Menu"), L10n.t("输入翻译", "Input"), L10n.t("剪贴板翻译", "Clipboard"),
                    values: ["menu", "input", "clipboard"])),
            row(L10n.t("面板位置", "Panel Position"),
                L10n.t("翻译面板弹出的位置", "Where the translation panel appears"),
                seg("panelPosition", L10n.t("屏幕中上方", "Top Center"), L10n.t("跟随鼠标", "At Cursor"),
                    values: ["top", "cursor"])),
            row(L10n.t("划词触发", "Trigger"),
                L10n.t("弹出浮动工具条的方式", "How the floating bar appears"),
                seg("triggerMode", L10n.t("拖拽+双击", "Drag+Click"), L10n.t("仅拖拽", "Drag"), L10n.t("仅双击", "DblClick"),
                    values: ["both", "drag", "doubleClick"])),
            row(L10n.t("剪贴板取词", "Clipboard Fallback"),
                L10n.t("读不到选区时模拟 ⌘C 兜底", "Simulate ⌘C when selection can't be read"),
                toggle("clipboardFallback")),
            row(L10n.t("敏感信息", "Privacy Guard"),
                L10n.t("发给第三方 AI 前检查手机号/密钥等", "Check sensitive info before sending to AI"),
                seg("privacyGuard", L10n.t("询问", "Ask"), L10n.t("自动脱敏", "Auto-mask"), L10n.t("关闭", "Off"),
                    values: ["ask", "mask", "off"])),
            row(L10n.t("开机启动", "Launch at Login"),
                L10n.t("登录后自动运行 PopBar", "Start PopBar automatically after login"),
                toggle("launchAtLogin")),
        ])]
    }

    /// 功能(M5/M8):剪贴板历史、OCR、使用统计、快捷键
    private func featuresTabs() -> (features: [NSView], snap: [NSView], record: [NSView]) {
        let hotkeyField = NSTextField()
        hotkeyField.placeholderString = "ctrl+opt+space"
        hotkeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hotkeyField.delegate = self
        textFieldKeys[ObjectIdentifier(hotkeyField)] = "hotkeys.showBar"
        textFields.append(hotkeyField)
        let snapHotkeyField = NSTextField()
        snapHotkeyField.placeholderString = "ctrl+opt+p"
        snapHotkeyField.stringValue = ConfigStore.shared.config.hotkeys.snap
        snapHotkeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        snapHotkeyField.delegate = self
        textFieldKeys[ObjectIdentifier(snapHotkeyField)] = "hotkeys.snap"
        textFields.append(snapHotkeyField)
        let limitField = NSTextField()
        limitField.placeholderString = "20"
        limitField.stringValue = String(ConfigStore.shared.config.snap.history.limit)
        limitField.alignment = .right
        limitField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        limitField.delegate = self
        textFieldKeys[ObjectIdentifier(limitField)] = "snap.historyLimit"
        textFields.append(limitField)
        let dirButton = ClosureButton(title: ConfigStore.shared.config.snap.saveDir) {}
        dirButton.bezelStyle = .rounded
        dirButton.lineBreakMode = .byTruncatingMiddle
        dirButton.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        dirButton.target = self
        dirButton.action = #selector(chooseSnapDir(_:))

        let recordHotkeyField = makeHotkeyField(placeholder: "ctrl+opt+r", key: "hotkeys.record",
                                                value: ConfigStore.shared.config.hotkeys.record)
        let recordPauseField = makeHotkeyField(placeholder: "ctrl+opt+shift+r", key: "hotkeys.recordPause",
                                               value: ConfigStore.shared.config.hotkeys.recordPause)
        let maxDurationField = NSTextField()
        maxDurationField.placeholderString = "0"
        maxDurationField.stringValue = String(ConfigStore.shared.config.snap.record.maxDuration)
        maxDurationField.alignment = .right
        maxDurationField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        maxDurationField.delegate = self
        textFieldKeys[ObjectIdentifier(maxDurationField)] = "snap.record.maxDuration"
        textFields.append(maxDurationField)

        // 麦克风设备:第一项是「系统默认」,后面是 DiscoverySession 列出的输入设备
        let micPop = NSPopUpButton()
        micPop.addItem(withTitle: L10n.t("系统默认", "System Default"))
        micPop.menu?.items.first?.representedObject = ""
        for d in MicPermission.devices() {
            micPop.addItem(withTitle: d.name)
            micPop.menu?.items.last?.representedObject = d.id
        }
        micPop.font = .systemFont(ofSize: 12)
        micPop.target = self
        micPop.action = #selector(micDeviceChanged(_:))
        micPop.widthAnchor.constraint(equalToConstant: 220).isActive = true
        micDevicePopup = micPop

        // 麦克风测试:点「测试」后按所选设备采集,电平条实时显示输入音量
        let meter = WaveBarsView()
        meter.widthAnchor.constraint(equalToConstant: 130).isActive = true
        meter.heightAnchor.constraint(equalToConstant: 24).isActive = true
        micLevelMeter = meter
        let testButton = ClosureButton(title: L10n.t("测试", "Test")) { [weak self] in
            self?.toggleMicTest()
        }
        testButton.bezelStyle = .rounded
        testButton.controlSize = .small
        micTestButton = testButton
        let micTest = NSStackView(views: [meter, testButton])
        micTest.spacing = 8
        micTest.alignment = .centerY

        // MARK: 录屏 v2:倒计时 / 标记 / 涟漪 / 摄像头 / 水印 / 导出
        let markerHotkeyField = makeHotkeyField(placeholder: "ctrl+opt+shift+m",
                                                key: "hotkeys.recordMarker",
                                                value: ConfigStore.shared.config.hotkeys.recordMarker)

        // 摄像头设备:第一项「系统默认」
        let cameraPop = NSPopUpButton()
        cameraPop.addItem(withTitle: L10n.t("系统默认", "System Default"))
        cameraPop.menu?.items.first?.representedObject = ""
        for d in CameraPermission.devices() {
            cameraPop.addItem(withTitle: d.name)
            cameraPop.menu?.items.last?.representedObject = d.id
        }
        cameraPop.font = .systemFont(ofSize: 12)
        cameraPop.target = self
        cameraPop.action = #selector(cameraDeviceChanged(_:))
        cameraPop.widthAnchor.constraint(equalToConstant: 220).isActive = true
        cameraDevicePopup = cameraPop

        // 水印文字
        let wmField = NSTextField()
        wmField.placeholderString = "PopBar"
        wmField.stringValue = ConfigStore.shared.config.snap.record.watermark.text
        wmField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        wmField.delegate = self
        textFieldKeys[ObjectIdentifier(wmField)] = "snap.record.watermark.text"
        textFields.append(wmField)

        // 水印不透明度
        let wmOpacity = NSSlider(value: ConfigStore.shared.config.snap.record.watermark.opacity,
                                 minValue: 0.05, maxValue: 1,
                                 target: self, action: #selector(watermarkOpacityChanged(_:)))
        wmOpacity.widthAnchor.constraint(equalToConstant: 130).isActive = true
        watermarkOpacitySlider = wmOpacity
        let wmOpacityLabel = NSTextField(labelWithString:
            "\(Int((ConfigStore.shared.config.snap.record.watermark.opacity * 100).rounded()))%")
        wmOpacityLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        wmOpacityLabel.textColor = .secondaryLabelColor
        watermarkOpacityLabel = wmOpacityLabel

        // 一键套用「产品演示」参数:贴近 1080p、体积可控、兼容性最好
        let demoButton = ClosureButton(title: L10n.t("套用产品演示参数", "Apply demo preset")) { [weak self] in
            self?.applyDemoPreset()
        }
        demoButton.bezelStyle = .rounded
        demoButton.controlSize = .small

        // 朗读声音:第一项「自动」,后面按语言分组列出已安装语音
        let voicePop = NSPopUpButton()
        voicePop.addItem(withTitle: L10n.t("自动(跟随语言)", "Auto (follow language)"))
        voicePop.menu?.items.first?.representedObject = ""
        var lastLang = ""
        for v in AVSpeechSynthesisVoice.speechVoices()
            .sorted(by: { ($0.language, $0.name) < ($1.language, $1.name) }) {
            if v.language != lastLang {
                lastLang = v.language
                let header = NSMenuItem(
                    title: Locale.current.localizedString(
                        forIdentifier: v.language.replacingOccurrences(of: "-", with: "_")) ?? v.language,
                    action: nil, keyEquivalent: "")
                header.isEnabled = false
                voicePop.menu?.addItem(header)
            }
            var title = v.name
            if v.quality == .enhanced { title += " · " + L10n.t("增强", "Enhanced") }
            else if v.quality == .premium { title += " · " + L10n.t("极致", "Premium") }
            voicePop.addItem(withTitle: title)
            voicePop.menu?.items.last?.representedObject = v.identifier
        }
        voicePop.font = .systemFont(ofSize: 12)
        voicePop.target = self
        voicePop.action = #selector(speakVoiceChanged(_:))
        voicePop.widthAnchor.constraint(equalToConstant: 220).isActive = true
        speakVoicePopup = voicePop

        let previewButton = ClosureButton(title: L10n.t("试听", "Preview")) { [weak self] in
            self?.previewVoice()
        }
        previewButton.bezelStyle = .rounded
        previewButton.controlSize = .small

        let rateSlider = NSSlider(value: ConfigStore.shared.config.speak.rate, minValue: 0.5, maxValue: 2,
                                  target: self, action: #selector(speakRateChanged(_:)))
        rateSlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        speakRateSlider = rateSlider
        let rateLabel = NSTextField(labelWithString: String(format: "%.2f×", ConfigStore.shared.config.speak.rate))
        rateLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        rateLabel.textColor = .secondaryLabelColor
        speakRateLabel = rateLabel
        let rateStack = NSStackView(views: [rateSlider, rateLabel])
        rateStack.spacing = 6
        rateStack.alignment = .centerY

        let features: [NSView] = [sectionHeader(L10n.t("功能", "Features")), card([
            row(L10n.t("剪贴板历史", "Clipboard History"),
                L10n.t("记录最近剪贴板,菜单栏可选粘贴;跳过密码类标记",
                       "Recent clipboard items from the menu; skips concealed types"),
                toggle("clipHistory")),
            row(L10n.t("历史持久化", "Persist History"),
                L10n.t("重启后保留剪贴板历史(默认仅内存);开启后图片将以文件保存在本机",
                       "Keep history across restarts (memory-only by default); images are saved as files on this Mac"),
                toggle("clipPersist")),
            row(L10n.t("采集图片", "Capture Images"),
                L10n.t("剪贴板历史记录复制的图片(缩略图预览)",
                       "Clipboard history records copied images (with thumbnails)"),
                toggle("clipImages")),
            row(L10n.t("采集文件", "Capture Files"),
                L10n.t("剪贴板历史记录复制的文件/文件夹",
                       "Clipboard history records copied files/folders"),
                toggle("clipFiles")),
            row(L10n.t("OCR 结果", "OCR Result"),
                L10n.t("截图识别后弹翻译面板还是完整工具条",
                       "After screenshot OCR: translate panel or full action bar"),
                seg("ocrAfter", L10n.t("翻译面板", "Panel"), L10n.t("工具条", "Bar"),
                    values: ["panel", "bar"])),
            row(L10n.t("使用统计", "Usage Stats"),
                L10n.t("只记动作次数,不记文本;用于排序建议",
                       "Counts actions only, never text; powers ordering suggestions"),
                toggle("usageEnabled")),
            row(L10n.t("唤起快捷键", "Bar Hotkey"),
                L10n.t("格式 ctrl+opt+space;键盘选中后按它呼出工具条",
                       "Format: ctrl+opt+space; press after selecting via keyboard"),
                hotkeyField),
        ]), sectionHeader(L10n.t("朗读", "Speech")), card([
            row(L10n.t("朗读声音", "Voice"),
                L10n.t("划词朗读与翻译面板共用;「自动」跟随文本语言",
                       "Shared by the bar and translation panel; Auto follows the text language"),
                NSStackView(views: [voicePop, previewButton])),
            row(L10n.t("语速", "Rate"),
                L10n.t("1.0 = 系统默认语速", "1.0 = system default rate"),
                rateStack),
        ])]
        let snap: [NSView] = [sectionHeader(L10n.t("截屏", "Screenshot")), card([
            row(L10n.t("截屏快捷键", "Screenshot Hotkey"),
                L10n.t("格式 ctrl+opt+p;全局唤起截屏", "Format: ctrl+opt+p; starts a screenshot anywhere"),
                snapHotkeyField),
            row(L10n.t("保存位置", "Save Folder"),
                L10n.t("⌘S 保存截屏的目录", "Where ⌘S saves screenshots"),
                dirButton),
            row(L10n.t("保存格式", "Save Format"),
                L10n.t("PNG 无损,JPG 体积小", "PNG is lossless, JPG is smaller"),
                seg("snapFormat", "PNG", "JPG", values: ["png", "jpg"])),
            row(L10n.t("放大镜", "Magnifier"),
                L10n.t("选区时显示像素放大镜与颜色值", "Show pixel magnifier and color value while selecting"),
                toggle("snapMagnifier")),
            row(L10n.t("截图历史", "Screenshot History"),
                L10n.t("保存到本机 Application Support/PopBar/Snaps,默认关闭",
                       "Stored locally in Application Support/PopBar/Snaps; off by default"),
                toggle("snapHistory")),
            row(L10n.t("保留数量", "History Limit"),
                L10n.t("1–200,超出自动删除最旧的", "1–200; oldest are removed beyond this"),
                limitField),
        ])]
        let record: [NSView] = [sectionHeader(L10n.t("录屏", "Screen Recording")), card([
            row(L10n.t("录屏快捷键", "Record Hotkey"),
                L10n.t("格式 ctrl+opt+r;录制中再按一次即停止", "Format: ctrl+opt+r; press again while recording to stop"),
                recordHotkeyField),
            row(L10n.t("暂停快捷键", "Pause Hotkey"),
                L10n.t("格式 ctrl+opt+shift+r;录制中暂停/继续", "Format: ctrl+opt+shift+r; pause/resume while recording"),
                recordPauseField),
            row(L10n.t("帧率", "Frame Rate"),
                L10n.t("60fps 更流畅,文件与占用也更大", "60fps is smoother but larger and heavier"),
                seg("recordFps", "30", "60", values: ["30", "60"])),
            row(L10n.t("分辨率", "Resolution"),
                L10n.t("1x 逻辑像素,2x 原生像素", "1x logical pixels, 2x native pixels"),
                seg("recordScale", "1x", "2x", values: ["1", "2"])),
            row(L10n.t("编码", "Codec"),
                L10n.t("H.264 兼容性最好;HEVC 文件更小", "H.264 is most compatible; HEVC is smaller"),
                seg("recordCodec", "H.264", "HEVC", values: ["h264", "hevc"])),
            row(L10n.t("容器", "Container"),
                L10n.t("MOV 与 MP4 均可被 QuickTime 直接播放", "Both MOV and MP4 play directly in QuickTime"),
                seg("recordContainer", "MOV", "MP4", values: ["mov", "mp4"])),
            row(L10n.t("显示光标", "Show Cursor"),
                L10n.t("录制画面里保留鼠标指针", "Keep the mouse pointer in the recording"),
                toggle("recordCursor")),
            row(L10n.t("系统声音", "System Audio"),
                L10n.t("录制电脑内部声音;PopBar 自己的声音始终排除",
                       "Record internal audio; PopBar's own audio is always excluded"),
                toggle("recordSystemAudio")),
            row(L10n.t("麦克风", "Microphone"),
                L10n.t("默认关闭;开启需要「麦克风」权限", "Off by default; needs Microphone permission"),
                toggle("recordMic")),
            row(L10n.t("麦克风设备", "Microphone Device"),
                L10n.t("录制时使用的输入设备", "Input device used for recordings"),
                micPop),
            row(L10n.t("麦克风测试", "Mic Test"),
                L10n.t("对着麦克风说话,电平条实时显示输入音量",
                       "Speak to see live input level"),
                micTest),
            row(L10n.t("最长时长", "Max Duration"),
                L10n.t("秒,0 = 不限;到时自动停止并保存", "Seconds, 0 = unlimited; stops and saves automatically"),
                maxDurationField),
            row(L10n.t("GIF 帧率", "GIF FPS"),
                L10n.t("导出 GIF 时的帧率", "Frame rate when exporting GIF"),
                seg("gifFps", "5", "10", "15", values: ["5", "10", "15"])),
            row(L10n.t("GIF 宽度", "GIF Width"),
                L10n.t("宽度越小体积越小;「原始」不缩放", "Smaller width = smaller file; Original keeps size"),
                seg("gifWidth", L10n.t("原始", "Original"), "800", "480", values: ["0", "800", "480"])),
            row(L10n.t("GIF 到剪贴板", "Copy GIF"),
                L10n.t("导出后自动复制 GIF 文件,可直接粘贴", "Copy the GIF file after export, ready to paste"),
                toggle("gifClipboard")),
        ]), sectionHeader(L10n.t("录屏:开录与跟随", "Recording: Start & Follow")), card([
            row(L10n.t("倒计时", "Countdown"),
                L10n.t("确认选区后先倒数几秒再开始录,留出切换窗口的时间",
                       "Wait a few seconds before capturing, so you can switch to the app"),
                seg("recordCountdown", "0", "3", "5", "10", values: ["0", "3", "5", "10"])),
            row(L10n.t("跟随窗口", "Follow Window"),
                L10n.t("选区正好选中一个窗口时,窗口移动/缩放自动跟随",
                       "When the selection is exactly a window, follow it as it moves and resizes"),
                toggle("recordWindowFollow")),
            row(L10n.t("标记快捷键", "Marker Hotkey"),
                L10n.t("格式 ctrl+opt+shift+m;录制中打标记点,导出时可一键跳到该时刻",
                       "Format: ctrl+opt+shift+m; drop a marker while recording, jump to it when exporting"),
                markerHotkeyField),
            row(L10n.t("产品演示参数", "Demo Preset"),
                L10n.t("一键改成 1x + MP4 + H.264 + 30fps + 倒计时 3 秒",
                       "Set 1x + MP4 + H.264 + 30fps + 3s countdown in one click"),
                demoButton),
        ]), sectionHeader(L10n.t("录屏:点击涟漪", "Recording: Click Ripple")), card([
            row(L10n.t("点击涟漪", "Click Ripple"),
                L10n.t("录制时记录每次点击,导出时在点击处画扩散圆环",
                       "Record every click and draw a ripple at that spot when exporting"),
                toggle("recordClick")),
            row(L10n.t("涟漪时长", "Ripple Duration"),
                L10n.t("单次圆环扩散的持续时间", "How long one ripple takes to expand"),
                seg("recordClickDuration", L10n.t("短", "Short"), L10n.t("标准", "Normal"), L10n.t("长", "Long"),
                    values: ["0.3", "0.6", "1.0"])),
            row(L10n.t("涟漪颜色", "Ripple Color"),
                L10n.t("深色与浅色画面上都看得清的颜色", "Pick one that stands out on both light and dark screens"),
                seg("recordClickColor", L10n.t("红", "Red"), L10n.t("蓝", "Blue"), L10n.t("黄", "Yellow"),
                    values: ["#FF3B30", "#0A84FF", "#FFD60A"])),
        ]), sectionHeader(L10n.t("录屏:摄像头画中画", "Recording: Camera PiP")), card([
            row(L10n.t("摄像头", "Camera"),
                L10n.t("开启后需要「摄像头」权限;录制时显示预览窗,导出时叠加到成品上",
                       "Needs Camera permission; shows a preview while recording and is composited on export"),
                toggle("recordCamera")),
            row(L10n.t("摄像头设备", "Camera Device"),
                L10n.t("录制时使用的摄像头", "Camera used for recordings"),
                cameraPop),
            row(L10n.t("位置", "Position"),
                L10n.t("预览窗与成品里画中画的位置一致", "The preview matches where it lands in the exported video"),
                seg("recordCameraPos", L10n.t("右下", "BR"), L10n.t("左下", "BL"),
                    L10n.t("右上", "TR"), L10n.t("左上", "TL"),
                    values: ["bottomRight", "bottomLeft", "topRight", "topLeft"])),
            row(L10n.t("尺寸", "Size"),
                L10n.t("预览窗宽度,高度按摄像头画幅比", "Preview width; height follows the camera aspect"),
                seg("recordCameraSize", "120", "160", "220", values: ["120", "160", "220"])),
            row(L10n.t("镜像", "Mirror"),
                L10n.t("像照镜子一样左右翻转,自拍时更自然", "Flip horizontally like a mirror; natural for self-view"),
                toggle("recordCameraMirror")),
        ]), sectionHeader(L10n.t("录屏:水印", "Recording: Watermark")), card([
            row(L10n.t("水印", "Watermark"),
                L10n.t("导出时在画面上打一个标识", "Stamp a mark onto the exported video"),
                toggle("recordWatermark")),
            row(L10n.t("文字", "Text"),
                L10n.t("成品上显示的文字", "Text shown on the exported video"),
                wmField),
            row(L10n.t("位置", "Position"),
                L10n.t("贴在哪一个角", "Which corner to place it in"),
                seg("recordWatermarkPos", L10n.t("右上", "TR"), L10n.t("左上", "TL"),
                    L10n.t("右下", "BR"), L10n.t("左下", "BL"),
                    values: ["topRight", "topLeft", "bottomRight", "bottomLeft"])),
            row(L10n.t("不透明度", "Opacity"),
                L10n.t("越低越不打扰画面", "Lower is less intrusive"),
                NSStackView(views: [wmOpacity, wmOpacityLabel])),
        ]), sectionHeader(L10n.t("录屏:导出与分发", "Recording: Export")), card([
            row(L10n.t("录完自动导出", "Auto Export"),
                L10n.t("录制结束后直接按下面的参数出成品,省一步手工操作",
                       "Export with the settings below right after recording stops"),
                toggle("recordAutoExport")),
            row(L10n.t("目标宽度", "Target Width"),
                L10n.t("越小越省体积;「原始」不缩放", "Smaller is lighter; Original keeps the recorded size"),
                seg("recordExportWidth", L10n.t("原始", "Original"), "1920", "1280", "854",
                    values: ["0", "1920", "1280", "854"])),
            row(L10n.t("质量", "Quality"),
                L10n.t("高 = 保留原画质;中/低 明显更小", "High keeps the original quality; Medium/Low are much smaller"),
                seg("recordExportQuality", L10n.t("高", "High"), L10n.t("中", "Medium"), L10n.t("低", "Low"),
                    values: ["high", "medium", "low"])),
            row(L10n.t("容器", "Container"),
                L10n.t("MP4 最通用,微信/网页/剪辑软件都吃", "MP4 is the most compatible for sharing and editing"),
                seg("recordExportContainer", "MP4", "MOV", values: ["mp4", "mov"])),
            row(L10n.t("录完复制到剪贴板", "Copy on Finish"),
                L10n.t("录制完成后直接 ⌘V 就能把文件发给别人",
                       "Press ⌘V right after recording to paste the file"),
                toggle("recordCopyClipboard")),
            row(L10n.t("导出后复制到剪贴板", "Copy After Export"),
                L10n.t("导出成品后自动复制文件", "Copy the exported file automatically"),
                toggle("recordExportClipboard")),
        ])]
        return (features, snap, record)
    }

    /// 快捷键输入框:提交即写配置
    private func makeHotkeyField(placeholder: String, key: String, value: String) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.stringValue = value
        f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        f.delegate = self
        textFieldKeys[ObjectIdentifier(f)] = key
        textFields.append(f)
        return f
    }

    @objc private func chooseSnapDir(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        NSApp.activateForUI()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var c = ConfigStore.shared.config
        c.snap.saveDir = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        sender.title = c.snap.saveDir
        try? ConfigStore.shared.save(c)
    }

    /// 工具条(#3)与应用规则(#2)
    private func toolbarTab() -> [NSView] {
        [sectionHeader(L10n.t("工具条", "Toolbar")), ToolbarPrefsCard(),
         sectionHeader(L10n.t("应用规则", "Per-App Rules")), AppRulesPrefsCard()]
    }

    private func aboutTab() -> [NSView] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let versionLabel = NSTextField(labelWithString: version)
        versionLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        let pathLabel = NSTextField(labelWithString:
            PopBarConfig.directoryURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let openButton = ClosureButton(title: L10n.t("打开", "Open")) {
            PopBarConfig.ensureExists()
            NSWorkspace.shared.activateFileViewerSelecting([PopBarConfig.fileURL])
        }
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        return [sectionHeader(L10n.t("关于", "About")), card([
            row(L10n.t("版本", "Version"),
                L10n.t("当前版本", "Current version"),
                versionLabel),
            row(L10n.t("配置目录", "Config Folder"),
                L10n.t("provider、提示词与这些设置", "Providers, prompts and these preferences"),
                NSStackView(views: [pathLabel, openButton])),
        ])]
    }

    /// 一个 tab 的内容装进滚动视图,行数超出可用高度时滚动;返回视图与内容高度
    private func contentScroll(_ views: [NSView]) -> (NSScrollView, CGFloat) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 14
        main.translatesAutoresizingMaskIntoConstraints = false
        for v in views {
            main.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        }
        // 内容高度:各块高度之和 + 块间距 + 上下留白。行高已固定,这里算出来就是准确值,
        // 不能等布局收敛后再量(卡片高度要过几轮才稳定)
        let contentH = views.reduce(CGFloat(0)) { $0 + $1.fittingSize.height }
            + CGFloat(max(0, views.count - 1)) * main.spacing + 32

        // flipped 容器:内容从顶部开始排,高度显式给出
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(main)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            doc.heightAnchor.constraint(equalToConstant: contentH),
            main.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            main.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            main.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
            main.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
        ])
        return (scroll, contentH)
    }

    /// 窗口宽高固定:与旧的「AI 翻译设置」窗口一致,多出的只有顶部 tab 栏;
    /// 其他 tab 内容更高时在区域内滚动
    private func applyFixedSize() {
        guard let w = window, tabHeights.indices.contains(Self.aiTabIndex) else { return }
        let chrome = 14 + (tabBarControl?.frame.height ?? 24) + 12
        w.setContentSize(NSSize(width: Self.contentWidth,
                                height: chrome + tabHeights[Self.aiTabIndex]))
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        tabIndex = max(0, min(sender.selectedSegment, tabScrolls.count - 1))
        for (i, s) in tabScrolls.enumerated() { s.isHidden = i != tabIndex }
    }

    private func sectionHeader(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = .secondaryLabelColor
        let wrap = NSView()
        wrap.addSubview(l)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14).isActive = true
        l.topAnchor.constraint(equalTo: wrap.topAnchor).isActive = true
        l.bottomAnchor.constraint(equalTo: wrap.bottomAnchor).isActive = true
        return wrap
    }

    /// 一行:左标题+副标题,右控件
    private func row(_ title: String, _ subtitle: String, _ control: NSView) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        let s = NSTextField(labelWithString: subtitle)
        s.font = .systemFont(ofSize: 11)
        s.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [t, s])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        // 弹性 spacer 吸收所有剩余宽度,把控件顶到卡片右缘,保证所有行右对齐
        let spring = NSView()
        spring.setContentHuggingPriority(.init(1), for: .horizontal)
        spring.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let r = NSStackView(views: [labels, spring, control])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 12
        r.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        // 行高显式给定:竖向堆栈自报的 fittingSize 会把行压小,导致卡片最后一行被裁
        let natural = max(labels.fittingSize.height, control.fittingSize.height) + 20
        r.heightAnchor.constraint(equalToConstant: natural).isActive = true
        return r
    }

    /// 卡片:多行 + 行间分隔线
    private func card(_ rows: [NSView]) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 0
        for (i, r) in rows.enumerated() {
            col.addArrangedSubview(r)
            r.leadingAnchor.constraint(equalTo: col.leadingAnchor).isActive = true
            r.trailingAnchor.constraint(equalTo: col.trailingAnchor).isActive = true
            if i < rows.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                col.addArrangedSubview(sep)
                sep.leadingAnchor.constraint(equalTo: col.leadingAnchor, constant: 14).isActive = true
                sep.trailingAnchor.constraint(equalTo: col.trailingAnchor).isActive = true
            }
        }
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = borderTint
        box.fillColor = surfaceColor
        box.contentViewMargins = .zero

        col.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(col)
        if let host = box.contentView {
            NSLayoutConstraint.activate([
                col.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                col.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                col.topAnchor.constraint(equalTo: host.topAnchor),
                col.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        return box
    }

    private func seg(_ key: String, _ titles: String..., values: [String]) -> NSSegmentedControl {
        let s = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: self,
                                   action: #selector(segChanged(_:)))
        s.controlSize = .regular
        segs.append(s)
        segKeys[ObjectIdentifier(s)] = (key, values)
        return s
    }

    private func toggle(_ key: String) -> NSSwitch {
        let s = NSSwitch()
        s.controlSize = .small
        s.target = self
        s.action = #selector(switchChanged(_:))
        switches.append(s)
        switchKeys[ObjectIdentifier(s)] = key
        return s
    }

    // MARK: - 控件 ↔ 配置

    private func syncControls() {
        let c = ConfigStore.shared.config
        for s in segs {
            guard let (key, values) = segKeys[ObjectIdentifier(s)] else { continue }
            let current: String
            switch key {
            case "appearance":    current = c.appearance
            case "language":      current = c.language
            case "trayClick":     current = c.trayClick
            case "panelPosition": current = c.panelPosition
            case "triggerMode":   current = c.triggerMode
            case "privacyGuard":  current = c.privacy.guardMode
            case "ocrAfter":      current = c.ocr.after
            case "snapFormat":    current = c.snap.format
            case "recordFps":     current = String(c.snap.record.fps)
            case "recordScale":   current = String(c.snap.record.scale)
            case "recordCodec":   current = c.snap.record.codec
            case "recordContainer": current = c.snap.record.container
            case "gifFps":        current = String(c.snap.record.gif.fps)
            case "gifWidth":      current = String(c.snap.record.gif.width)
            case "recordCountdown": current = String(c.snap.record.countdown)
            case "recordClickDuration":
                current = String(format: "%.1f", c.snap.record.click.duration)
            case "recordClickColor": current = c.snap.record.click.color
            case "recordCameraPos":  current = c.snap.record.camera.position
            case "recordCameraSize": current = String(c.snap.record.camera.size)
            case "recordWatermarkPos": current = c.snap.record.watermark.position
            case "recordExportWidth":  current = String(c.snap.record.export.width)
            case "recordExportQuality": current = c.snap.record.export.quality
            case "recordExportContainer": current = c.snap.record.export.container
            default: continue
            }
            s.selectedSegment = max(0, values.firstIndex(of: current) ?? 0)
        }
        for s in switches {
            switch switchKeys[ObjectIdentifier(s)] {
            case "clipboardFallback": s.state = c.clipboardFallback ? .on : .off
            case "clipHistory":  s.state = c.clipboardHistory.enabled ? .on : .off
            case "clipPersist":  s.state = c.clipboardHistory.persist ? .on : .off
            case "clipImages":   s.state = c.clipboardHistory.images ? .on : .off
            case "clipFiles":    s.state = c.clipboardHistory.files ? .on : .off
            case "usageEnabled": s.state = c.usage.enabled ? .on : .off
            case "snapMagnifier": s.state = c.snap.showMagnifier ? .on : .off
            case "snapHistory":   s.state = c.snap.history.enabled ? .on : .off
            case "recordCursor":  s.state = c.snap.record.showsCursor ? .on : .off
            case "recordSystemAudio": s.state = c.snap.record.systemAudio ? .on : .off
            case "recordMic":     s.state = c.snap.record.microphone ? .on : .off
            case "gifClipboard":  s.state = c.snap.record.gif.copyToClipboard ? .on : .off
            case "recordWindowFollow": s.state = c.snap.record.windowFollow ? .on : .off
            case "recordClick":   s.state = c.snap.record.click.enabled ? .on : .off
            case "recordCamera":  s.state = c.snap.record.camera.enabled ? .on : .off
            case "recordCameraMirror": s.state = c.snap.record.camera.mirror ? .on : .off
            case "recordWatermark": s.state = c.snap.record.watermark.enabled ? .on : .off
            case "recordAutoExport": s.state = c.snap.record.export.autoExport ? .on : .off
            case "recordCopyClipboard": s.state = c.snap.record.copyToClipboard ? .on : .off
            case "recordExportClipboard": s.state = c.snap.record.export.copyToClipboard ? .on : .off
            case "launchAtLogin":
                // 以系统实际登录项状态为准(用户可能在系统设置里关过)
                s.state = SMAppService.mainApp.status == .enabled ? .on : .off
            default: break
            }
        }
        // 麦克风设备:config 里存的可能是 uniqueID 或设备名,按 representedObject/标题双匹配
        if let pop = micDevicePopup, let items = pop.menu?.items {
            let want = ConfigStore.shared.config.snap.record.microphoneDevice
            var idx = 0
            if !want.isEmpty {
                for (i, item) in items.enumerated() {
                    if (item.representedObject as? String) == want || item.title == want {
                        idx = i
                        break
                    }
                }
            }
            pop.selectItem(at: idx)
        }
        if let pop = cameraDevicePopup, let items = pop.menu?.items {
            let want = ConfigStore.shared.config.snap.record.camera.device
            var idx = 0
            if !want.isEmpty {
                for (i, item) in items.enumerated() {
                    if (item.representedObject as? String) == want || item.title == want {
                        idx = i
                        break
                    }
                }
            }
            pop.selectItem(at: idx)
        }
        if let s = watermarkOpacitySlider {
            let v = ConfigStore.shared.config.snap.record.watermark.opacity
            s.doubleValue = v
            watermarkOpacityLabel?.stringValue = "\(Int((v * 100).rounded()))%"
        }
        // 朗读声音:按 identifier 匹配;配置的声音已卸载时回落「自动」
        if let pop = speakVoicePopup, let items = pop.menu?.items {
            let want = ConfigStore.shared.config.speak.voice
            var idx = 0
            if !want.isEmpty {
                for (i, item) in items.enumerated() where (item.representedObject as? String) == want {
                    idx = i
                    break
                }
            }
            pop.selectItem(at: idx)
        }
        if let slider = speakRateSlider {
            slider.doubleValue = ConfigStore.shared.config.speak.rate
            speakRateLabel?.stringValue = String(format: "%.2f×", ConfigStore.shared.config.speak.rate)
        }
    }

    @objc private func micDeviceChanged(_ sender: NSPopUpButton) {
        var c = ConfigStore.shared.config
        c.snap.record.microphoneDevice = sender.selectedItem?.representedObject as? String ?? ""
        try? ConfigStore.shared.save(c)
    }

    @objc private func cameraDeviceChanged(_ sender: NSPopUpButton) {
        var c = ConfigStore.shared.config
        c.snap.record.camera.device = sender.selectedItem?.representedObject as? String ?? ""
        try? ConfigStore.shared.save(c)
    }

    @objc private func watermarkOpacityChanged(_ sender: NSSlider) {
        var c = ConfigStore.shared.config
        c.snap.record.watermark.opacity = (sender.doubleValue * 100).rounded() / 100
        watermarkOpacityLabel?.stringValue = "\(Int((c.snap.record.watermark.opacity * 100).rounded()))%"
        try? ConfigStore.shared.save(c)
    }

    /// 「产品演示」一键参数:分辨率贴近 1080p、MP4、兼容性最好、留出倒计时
    private func applyDemoPreset() {
        var c = ConfigStore.shared.config
        c.snap.record.scale = 1
        c.snap.record.container = "mp4"
        c.snap.record.codec = "h264"
        c.snap.record.fps = 30
        c.snap.record.countdown = 3
        c.snap.record.showsCursor = true
        c.snap.record.export.width = 1920
        c.snap.record.export.quality = "medium"
        c.snap.record.export.container = "mp4"
        try? ConfigStore.shared.save(c)
        syncControls()
    }

    @objc private func speakVoiceChanged(_ sender: NSPopUpButton) {
        var c = ConfigStore.shared.config
        c.speak.voice = sender.selectedItem?.representedObject as? String ?? ""
        try? ConfigStore.shared.save(c)
    }

    @objc private func speakRateChanged(_ sender: NSSlider) {
        var c = ConfigStore.shared.config
        c.speak.rate = (sender.doubleValue * 100).rounded() / 100
        speakRateLabel?.stringValue = String(format: "%.2f×", c.speak.rate)
        try? ConfigStore.shared.save(c)
    }

    /// 试听:用当前下拉选中的声音念一句;「自动」时按中文默认声音
    private func previewVoice() {
        let id = speakVoicePopup?.selectedItem?.representedObject as? String ?? ""
        let v = id.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: id)
        let zh = v?.language.hasPrefix("zh") ?? true
        let utt = AVSpeechUtterance(string: zh
            ? "你好,这是 PopBar 的朗读试听。"
            : "Hello, this is the PopBar voice preview.")
        utt.voice = v ?? AVSpeechSynthesisVoice(language: "zh-CN")
        let r = ConfigStore.shared.config.speak.rate
        if r != 1.0 { utt.rate = AVSpeechUtteranceDefaultSpeechRate * Float(r) }
        previewSpeech.stopSpeaking(at: .immediate)
        previewSpeech.speak(utt)
    }

    /// 麦克风测试:再点一次停止;没授权先走授权流程,被拒则 MicPermission 自己弹引导
    private func toggleMicTest() {
        if micMonitor.running { return stopMicTest() }
        micTestButton?.title = L10n.t("停止", "Stop")
        Task { @MainActor in
            guard await MicPermission.ensure() else { return self.stopMicTest() }
            self.micMonitor.onLevel = { [weak self] v in
                self?.micLevelMeter?.doubleValue = Double(v)
            }
            self.micMonitor.start(deviceUID: ConfigStore.shared.config.snap.record.microphoneDevice)
        }
    }

    private func stopMicTest() {
        micMonitor.stop()
        micMonitor.onLevel = nil
        micTestButton?.title = L10n.t("测试", "Test")
        micLevelMeter?.doubleValue = 0
    }

    @objc private func segChanged(_ sender: NSSegmentedControl) {
        guard let (key, values) = segKeys[ObjectIdentifier(sender)],
              sender.selectedSegment >= 0, sender.selectedSegment < values.count else { return }
        var c = ConfigStore.shared.config
        let v = values[sender.selectedSegment]
        switch key {
        case "appearance":    c.appearance = v
        case "language":      c.language = v
        case "trayClick":     c.trayClick = v
        case "panelPosition": c.panelPosition = v
        case "triggerMode":   c.triggerMode = v
        case "ocrAfter":      c.ocr.after = v
        case "snapFormat":    c.snap.format = v
        case "privacyGuard":  c.privacy.guardMode = v
        case "recordFps":     c.snap.record.fps = Int(v) ?? 30
        case "recordScale":   c.snap.record.scale = Int(v) ?? 2
        case "recordCodec":   c.snap.record.codec = v
        case "recordContainer": c.snap.record.container = v
        case "gifFps":        c.snap.record.gif.fps = Int(v) ?? 10
        case "gifWidth":      c.snap.record.gif.width = Int(v) ?? 800
        case "recordCountdown": c.snap.record.countdown = Int(v) ?? 3
        case "recordClickDuration": c.snap.record.click.duration = Double(v) ?? 0.6
        case "recordClickColor": c.snap.record.click.color = v
        case "recordCameraPos": c.snap.record.camera.position = v
        case "recordCameraSize": c.snap.record.camera.size = Int(v) ?? 160
        case "recordWatermarkPos": c.snap.record.watermark.position = v
        case "recordExportWidth": c.snap.record.export.width = Int(v) ?? 0
        case "recordExportQuality": c.snap.record.export.quality = v
        case "recordExportContainer": c.snap.record.export.container = v
        default: return
        }
        try? ConfigStore.shared.save(c)
        if key == "language" {          // 本窗口的文字也要跟着换
            rebuild()
            syncControls()
        }
    }

    @objc private func switchChanged(_ sender: NSSwitch) {
        guard let key = switchKeys[ObjectIdentifier(sender)] else { return }
        var c = ConfigStore.shared.config
        switch key {
        case "clipboardFallback":
            c.clipboardFallback = sender.state == .on
        case "launchAtLogin":
            c.launchAtLogin = sender.state == .on
            do {
                if c.launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
                c.launchAtLogin = sender.state == .on
            }
        case "clipHistory":   c.clipboardHistory.enabled = sender.state == .on
        case "clipPersist":   c.clipboardHistory.persist = sender.state == .on
        case "clipImages":    c.clipboardHistory.images = sender.state == .on
        case "clipFiles":     c.clipboardHistory.files = sender.state == .on
        case "usageEnabled":  c.usage.enabled = sender.state == .on
        case "snapMagnifier": c.snap.showMagnifier = sender.state == .on
        case "snapHistory":   c.snap.history.enabled = sender.state == .on
        case "recordCursor":  c.snap.record.showsCursor = sender.state == .on
        case "recordSystemAudio": c.snap.record.systemAudio = sender.state == .on
        case "recordWindowFollow": c.snap.record.windowFollow = sender.state == .on
        case "recordClick":   c.snap.record.click.enabled = sender.state == .on
        case "recordCamera":  c.snap.record.camera.enabled = sender.state == .on
        case "recordCameraMirror": c.snap.record.camera.mirror = sender.state == .on
        case "recordWatermark": c.snap.record.watermark.enabled = sender.state == .on
        case "recordAutoExport": c.snap.record.export.autoExport = sender.state == .on
        case "recordCopyClipboard": c.snap.record.copyToClipboard = sender.state == .on
        case "recordExportClipboard": c.snap.record.export.copyToClipboard = sender.state == .on
        case "gifClipboard":  c.snap.record.gif.copyToClipboard = sender.state == .on
        case "recordMic":
            c.snap.record.microphone = sender.state == .on
            if c.snap.record.microphone {       // 首次开启:顺带触发系统授权
                Task { @MainActor in
                    let ok = await MicPermission.ensure()
                    if !ok {
                        var off = ConfigStore.shared.config
                        off.snap.record.microphone = false
                        try? ConfigStore.shared.save(off)
                        self.syncControls()
                    }
                }
            }
        default: return
        }
        try? ConfigStore.shared.save(c)
    }

    /// 文本输入框(唤起快捷键):提交即写配置
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let key = textFieldKeys[ObjectIdentifier(field)] else { return }
        var c = ConfigStore.shared.config
        switch key {
        case "hotkeys.showBar":
            let v = field.stringValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty || Hotkey.parse(v) != nil {
                c.hotkeys.showBar = v.isEmpty ? "ctrl+opt+space" : v
            } else {
                field.stringValue = c.hotkeys.showBar
                NSSound.beep()
                return
            }
        case "snap.historyLimit":
            if let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), (1...200).contains(n) {
                c.snap.history.limit = n
            } else {
                field.stringValue = String(c.snap.history.limit)
                NSSound.beep()
                return
            }
        case "hotkeys.snap":
            let v = field.stringValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty || Hotkey.parse(v) != nil {
                c.hotkeys.snap = v.isEmpty ? "ctrl+opt+p" : v
            } else {
                field.stringValue = c.hotkeys.snap
                NSSound.beep()
                return
            }
        case "hotkeys.record":
            let v = field.stringValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty || Hotkey.parse(v) != nil {
                c.hotkeys.record = v.isEmpty ? "ctrl+opt+r" : v
            } else {
                field.stringValue = c.hotkeys.record
                NSSound.beep()
                return
            }
        case "hotkeys.recordPause":
            let v = field.stringValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty || Hotkey.parse(v) != nil {
                c.hotkeys.recordPause = v.isEmpty ? "ctrl+opt+shift+r" : v
            } else {
                field.stringValue = c.hotkeys.recordPause
                NSSound.beep()
                return
            }
        case "hotkeys.recordMarker":
            let v = field.stringValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty || Hotkey.parse(v) != nil {
                c.hotkeys.recordMarker = v.isEmpty ? "ctrl+opt+shift+m" : v
            } else {
                field.stringValue = c.hotkeys.recordMarker
                NSSound.beep()
                return
            }
        case "snap.record.watermark.text":
            c.snap.record.watermark.text = field.stringValue
        case "snap.record.maxDuration":
            if let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), n >= 0 {
                c.snap.record.maxDuration = n
            } else {
                field.stringValue = String(c.snap.record.maxDuration)
                NSSound.beep()
                return
            }
        default: return
        }
        try? ConfigStore.shared.save(c)
    }
}


/// 麦克风测试的柱状波浪:每来一个电平就把历史整体左移一格,新值从右侧进入,
/// 柱子以中线对称绘制;低电平灰绿、接近削波变黄/红。value 归零时回落成一排小圆点。
final class WaveBarsView: NSView {
    private let barCount = 26
    private var history: [CGFloat]
    private var smoothed: CGFloat = 0

    override init(frame: NSRect) {
        history = Array(repeating: 0, count: barCount)
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 0...1;和原 NSLevelIndicator.doubleValue 同名,调用方不用改
    var doubleValue: Double = 0 {
        didSet {
            let v = CGFloat(min(max(doubleValue, 0), 1))
            // 简单平滑:上升快、下降慢,避免柱子抖得太碎
            smoothed = v > smoothed ? v : smoothed * 0.6 + v * 0.4
            if v == 0 { smoothed = 0; history = Array(repeating: 0, count: barCount) }
            else {
                history.removeFirst()
                // 加一点随机起伏,让相邻柱子高度有错落,更像声波
                history.append(min(1, smoothed * CGFloat.random(in: 0.75...1.0)))
            }
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 2
        let w = (bounds.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
        let minH: CGFloat = w   // 静音时是圆点
        for (i, v) in history.enumerated() {
            let h = max(minH, v * bounds.height)
            let r = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            let color: NSColor = v == 0 ? .tertiaryLabelColor
                : v > 0.9 ? .systemRed : v > 0.7 ? .systemYellow : .systemGreen
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}
