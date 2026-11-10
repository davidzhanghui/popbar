import Cocoa
import AVFoundation
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// AI 翻译面板:顶部原文,下方每个 provider 一张卡片,流式显示结果。
/// 面板会成为 key window(可滚动、可选中、可 Cmd+C),按 Esc 或点击面板外部关闭。
final class TranslationPanelController: NSObject, NSTextViewDelegate, NSTextFieldDelegate,
                                        AVSpeechSynthesizerDelegate {
    static let shared = TranslationPanelController()

    private var panel: KeyablePanel?
    private var contentColumn: NSStackView?
    private var providersHeight: NSLayoutConstraint?
    private var providersStack: NSStackView?
    private var sourceTextView: NSTextView?
    private var detectionLabel: NSTextField?
    private var sourcePopup: NSPopUpButton?
    private var targetPopup: NSPopUpButton?
    private var cards: [ProviderCardView] = []
    private let speech = AVSpeechSynthesizer()
    private var config = PopBarConfig()
    private var theme = PanelTheme(dark: false)
    private var sourceText = ""
    private var truncated = false
    private(set) var isPinned = false
    private var pinButton: NSButton?
    private var copySourceButton: NSButton?
    private var speakSourceButton: NSButton?
    private var inputMode = false
    private var badgeBox: NSView?
    /// #10 追问输入框与目标 provider 选择
    private var followupField: NSTextField?
    private var followupPopup: NSPopUpButton?
    private var followupTargets: [LLMProvider] = []
    private var followupSendButton: NSButton?
    private var translateButton: NSButton?
    private var swapButton: NSButton?
    private var footerHint: NSTextField?
    private var footerIcon: NSImageView?
    /// 输入模式:最近一次提交的原文(截断前),用来判断结果是否已过期
    private var submittedInput = ""
    /// 有未提交输入时 Esc 需要连按两次,这里记第一次的截止时间
    private var escArmedUntil: Date?
    /// 正在朗读的按钮与 utterance:按钮切成「停止」图标,结束时还原
    private var speakingButton: NSButton?
    private var speakingTip = ""
    private var speakingUtterance: AVSpeechUtterance?
    private var configObserver: NSObjectProtocol?

    override init() {
        super.init()
        speech.delegate = self
        // 在设置里增删/修改服务后,打开着的面板同步刷新卡片
        configObserver = NotificationCenter.default.addObserver(
            forName: ConfigStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.configDidChange()
        }
    }

    /// 宽 460;高度随卡片数量收缩,最高 640
    private let panelSize = NSSize(width: 460, height: 580)
    /// 选区位置(划词来源才有),面板放在它下方,不挡原文
    private var anchor: CGRect?

    /// 旧 SF Symbols 名 → Lucide
    private static let lucide: [String: String] = [
        "doc.on.doc": "copy", "speaker.wave.2": "volume-2", "xmark": "x",
        "arrow.left.arrow.right": "arrow-down-up", "arrow.up.circle": "send",
    ]

    var isVisible: Bool { panel?.isVisible ?? false }
    var windowNumber: Int { panel?.windowNumber ?? 0 }
    /// 截图工具用
    var contentView: NSView? { panel?.contentView }
    var frame: CGRect { panel?.frame ?? .zero }

    /// (语言代码, 中文名, 英文名);各语言母语名中英界面下保持一致
    private let languageOptions: [(String, String, String)] = [
        ("auto", "自动检测", "Auto"), ("zh-CN", "中文简体", "Simplified Chinese"),
        ("en", "English", "English"), ("ja", "日本語", "Japanese"), ("ko", "한국어", "Korean"),
    ]

    // MARK: - 显示 / 关闭

    func show(text: String) {
        inputMode = false
        anchor = nil
        open(text: text)
    }

    /// 划词来源
    func show(ctx: SourceContext) {
        inputMode = false
        anchor = ctx.bounds
        open(text: ctx.text)
    }

    /// 输入翻译:原文区可编辑,Enter 提交翻译
    func showInput() {
        inputMode = true
        anchor = nil
        open(text: "")
    }

    private func open(text: String) {
        // 钉住且仍开着时复用:保留用户拖过的位置
        let keepPosition = isPinned && isVisible
        teardown()
        if !keepPosition { isPinned = false }
        config = ConfigStore.shared.config
        theme = PanelTheme.current
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        truncated = trimmed.count > config.maxCharacters
        sourceText = truncated ? String(trimmed.prefix(config.maxCharacters)) : trimmed
        submittedInput = ""

        buildPanel()
        startAllRequests()
        refreshControlStates()
        updatePanelHeight()
        if !keepPosition { positionPanel() }
        NSApp.activateForUI()
        panel?.makeKeyAndOrderFront(nil)
        if inputMode { panel?.makeFirstResponder(sourceTextView) }
    }

    /// 卡片少时收缩面板高度,避免中间留出大片空白
    private func updatePanelHeight() {
        guard let panel, let column = contentColumn, let constraint = providersHeight else { return }
        column.layoutSubtreeIfNeeded()
        let cardsHeight = providersStack?.fittingSize.height ?? 0
        constraint.constant = min(430, max(96, cardsHeight))
        column.layoutSubtreeIfNeeded()
        let height = min(640, max(330, column.fittingSize.height + 24))
        let top = panel.frame.maxY
        panel.setContentSize(NSSize(width: panelSize.width, height: height))
        // setContentSize 以左下角为锚点,恢复顶边让面板向下生长
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
        if let f = (panel.screen ?? NSScreen.main)?.visibleFrame, panel.frame.minY < f.minY + 8 {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: f.minY + 8))
        }
    }

    /// 用户主动关闭:钉住状态只在本次面板生命周期内有效,关掉即复位
    func close() {
        teardown()
        isPinned = false
    }

    private func teardown() {
        for card in cards { card.cancel() }
        cards.removeAll()
        stopSpeaking()
        escArmedUntil = nil
        panel?.orderOut(nil)
    }

    /// Esc:有未提交的输入时需要 2 秒内连按两次,避免误触丢掉长文本
    private func requestClose() {
        if hasUnsubmittedInput, (escArmedUntil ?? .distantPast) < Date() {
            escArmedUntil = Date().addingTimeInterval(2)
            updateFooter()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let until = self.escArmedUntil, until <= Date() else { return }
                self.escArmedUntil = nil
                self.updateFooter()
            }
            return
        }
        close()
    }

    private func configDidChange() {
        guard isVisible else { return }
        let newConfig = ConfigStore.shared.config
        let providersChanged = newConfig.activeProviders != config.activeProviders
        config = newConfig
        guard providersChanged else { return }
        startAllRequests()
        refreshControlStates()
        updatePanelHeight()
    }

    // MARK: - 构建界面

    private func buildPanel() {
        let p: KeyablePanel
        if let existing = panel {
            p = existing
        } else {
            p = KeyablePanel(contentRect: NSRect(origin: .zero, size: panelSize),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.onEscape = { [weak self] in self?.requestClose() }
            p.onClose = { [weak self] in self?.close() }      // ⌘W
            panel = p
        }

        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = theme.surfaceBorder.cgColor

        // 毛玻璃之上叠一层淡紫渐变,让面板不再是一片灰
        let tint = GradientView(top: theme.gradientTop, bottom: theme.gradientBottom)
        tint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tint.topAnchor.constraint(equalTo: root.topAnchor),
            tint.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        // 头部:识别徽标 + 复制/朗读/关闭
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        let pin = makeIconButton(isPinned ? "pin-off" : "pin",
                                 isPinned ? L10n.t("取消钉住：恢复点击外部关闭", "Unpin: clicking outside closes")
                                          : L10n.t("钉住：点击面板外不自动关闭", "Pin: stay open when clicking outside")) { [weak self] in
            self?.togglePin()
        }
        pin.contentTintColor = isPinned ? theme.brandText : Theme.muted
        pinButton = pin
        header.addArrangedSubview(pin)
        header.setCustomSpacing(4, after: pin)
        let logo = NSImageView(image: Lucide.image("languages", size: 14))
        logo.contentTintColor = theme.brandText
        logo.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        let panelTitle = inputMode ? L10n.t("输入翻译", "Input Translate")
                                   : L10n.t("AI 翻译", "AI Translate")
        let title = NSTextField(labelWithString: panelTitle)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = theme.brandText
        header.addArrangedSubview(logo)
        header.addArrangedSubview(title)
        header.setCustomSpacing(10, after: title)
        let badge = makeBadge(directionText())
        badgeBox = badge               // 显隐与文案统一由 updateBadge() 决定
        header.addArrangedSubview(badge)
        header.addArrangedSubview(spacer())
        let copyTip = L10n.t("复制原文", "Copy source")
        var copySource: NSButton!
        copySource = makeIconButton("doc.on.doc", copyTip) { [weak self] in
            guard let self else { return }
            let text = self.currentSourceText()
            guard !text.isEmpty else { return }
            self.copyToPasteboard(text)
            flashCopied(copySource, icon: "copy", tip: copyTip)
        }
        copySourceButton = copySource
        header.addArrangedSubview(copySource)
        var speakSource: NSButton!
        speakSource = makeIconButton("speaker.wave.2", L10n.t("朗读原文", "Speak source")) { [weak self] in
            guard let self else { return }
            self.speak(self.currentSourceText(), from: speakSource)
        }
        speakSourceButton = speakSource
        header.addArrangedSubview(speakSource)
        header.addArrangedSubview(makeIconButton("xmark", L10n.t("关闭 (Esc)", "Close (Esc)")) { [weak self] in
            self?.close()
        })
        column.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        // 原文
        let sourceScroll = makeSourceScroll()
        column.addArrangedSubview(sourceScroll)
        sourceScroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        sourceScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true

        // 语言行
        let langRow = NSStackView()
        langRow.orientation = .horizontal
        langRow.alignment = .centerY
        langRow.spacing = 8
        let src = makeLanguagePopup(selected: config.sourceLanguage)
        let dst = makeLanguagePopup(selected: config.targetLanguage)
        src.target = self
        src.action = #selector(languageChanged)
        dst.target = self
        dst.action = #selector(languageChanged)
        sourcePopup = src
        targetPopup = dst
        let swap = makeIconButton("arrow.left.arrow.right", L10n.t("互换语言", "Swap languages")) { [weak self] in
            guard let self, let s = self.sourcePopup, let d = self.targetPopup else { return }
            let sv = self.code(at: s.indexOfSelectedItem)
            let dv = self.code(at: d.indexOfSelectedItem)
            guard sv != "auto" else { return }   // 按钮此时已置灰,这里只是兜底
            let detected = LanguageDetect.code(self.currentSourceText())
            s.selectItem(at: self.index(of: dv == "auto" ? detected : dv))
            d.selectItem(at: self.index(of: sv))
            self.languageChanged()
        }
        swapButton = swap
        // AI 动作模式:语言由动作自身的提示词决定,隐藏语言行
        langRow.addArrangedSubview(src)
        langRow.addArrangedSubview(swap)
        langRow.addArrangedSubview(dst)
        langRow.addArrangedSubview(spacer())
        if inputMode {
            // 请求进行中切成「停止」,空文本时置灰
            let go = ClosureButton(title: L10n.t("翻译 ⏎", "Translate ⏎")) { [weak self] in
                guard let self else { return }
                if self.isBusy { self.stopAll() } else { self.submitInput() }
            }
            go.bezelStyle = .rounded
            go.controlSize = .small
            go.bezelColor = PanelTheme.brand
            go.font = .systemFont(ofSize: 11, weight: .medium)
            go.toolTip = L10n.t("Enter 提交，Shift+Enter 换行", "Enter to translate, Shift+Enter for newline")
            translateButton = go
            langRow.addArrangedSubview(go)
        }
        column.addArrangedSubview(langRow)
        langRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        let divider = NSBox()
        divider.boxType = .separator
        column.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        // provider 卡片区
        let providersScroll = NSScrollView()
        providersScroll.hasVerticalScroller = true
        providersScroll.drawsBackground = false
        providersScroll.borderType = .noBorder
        providersScroll.translatesAutoresizingMaskIntoConstraints = false
        // documentView 必须是 flipped,否则卡片会被贴到底部
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        providersScroll.documentView = container
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalTo: providersScroll.contentView.widthAnchor),
        ])
        providersStack = stack
        column.addArrangedSubview(providersScroll)
        providersScroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        let heightConstraint = providersScroll.heightAnchor.constraint(equalToConstant: 260)
        heightConstraint.isActive = true
        providersHeight = heightConstraint
        contentColumn = column

        // 追问行(#10):目标 provider 下拉 + 输入框 + 发送
        let followRow = NSStackView()
        followRow.orientation = .horizontal
        followRow.alignment = .centerY
        followRow.spacing = 6
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = .systemFont(ofSize: 10)
        popup.controlSize = .small
        (popup.cell as? NSPopUpButtonCell)?.controlSize = .small
        popup.widthAnchor.constraint(equalToConstant: 110).isActive = true
        popup.autoenablesItems = false      // 逐项按卡片状态启用
        popup.target = self
        popup.action = #selector(followupTargetChanged)
        followupPopup = popup
        let field = NSTextField()
        field.placeholderString = L10n.t("对结果继续追问，Enter 发送…", "Ask a follow-up, Enter to send…")
        field.font = .systemFont(ofSize: 11)
        field.controlSize = .small
        field.target = self
        field.action = #selector(followup)
        field.delegate = self
        followupField = field
        let send = makeIconButton("arrow.up.circle", L10n.t("发送追问", "Send")) { [weak self] in
            self?.followup()
        }
        followupSendButton = send
        followRow.addArrangedSubview(popup)
        followRow.addArrangedSubview(field)
        followRow.addArrangedSubview(send)
        column.addArrangedSubview(followRow)
        followRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        // 底部隐私提示 + 打开配置
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        let lock = NSImageView(image: Lucide.image("shield", size: 14))
        lock.contentTintColor = Theme.faint
        lock.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        let hint = NSTextField(labelWithString: L10n.t("文本会发送到你配置的第三方 API",
                                                     "Text is sent to your configured API"))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = Theme.faint
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerHint = hint
        footerIcon = lock
        footer.addArrangedSubview(lock)
        footer.addArrangedSubview(hint)
        footer.addArrangedSubview(spacer())
        let settings = makeTextButton(L10n.t("设置", "Settings")) { [weak self] in
            // 面板是 floating 层级,不收起会盖住设置窗口;钉住时尊重用户意愿保留
            if let self, !self.isPinned { self.close() }
            MainActor.assumeIsolated { AppRouter.openSettings(.ai) }
        }
        settings.contentTintColor = theme.brandText
        footer.addArrangedSubview(settings)
        column.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        p.contentView = root
        p.setContentSize(panelSize)
        root.layoutSubtreeIfNeeded()
    }

    private func makeSourceScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 9
        scroll.layer?.backgroundColor = theme.surface.cgColor
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = theme.surfaceBorder.cgColor

        let tv = PlaceholderTextView()
        tv.isEditable = inputMode
        tv.isSelectable = true
        // 代码创建的 NSTextView 默认不开撤销,⌘Z/⇧⌘Z 会失效;
        // 纯文本模式避免粘贴网页时带入字体颜色;关掉智能替换,别把待译原文的引号/破折号改掉
        tv.allowsUndo = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 13.5)
        tv.textColor = Theme.text
        tv.textContainerInset = NSSize(width: 10, height: 8)
        tv.string = sourceText
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = self
        if inputMode {
            tv.placeholderString = L10n.t("输入或粘贴要翻译的文本",
                                         "Type or paste text to translate")
        }
        scroll.documentView = tv
        sourceTextView = tv
        return scroll
    }

    /// 按偏好「面板位置」摆放:默认屏幕中上方,也可跟随鼠标
    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        guard let f = ScreenPlacement.screen(containing: mouse)?.visibleFrame, let panel else { return }
        let size = panel.frame.size
        var origin: NSPoint
        if ConfigStore.shared.config.panelPosition == .cursor {
            panel.setFrame(ScreenPlacement.frame(size: size, anchor: nil, prefer: .below, gap: 12), display: true)
            return
        } else if let anchor {
            // 划词来源:选区所在屏,优先放在选区下方
            panel.setFrame(ScreenPlacement.frame(size: size, anchor: anchor, prefer: .below, gap: 10), display: true)
            return
        } else {
            origin = NSPoint(x: f.midX - size.width / 2,
                             y: f.maxY - size.height - 48)
        }
        origin.x = min(max(origin.x, f.minX + 8), f.maxX - size.width - 8)
        origin.y = min(max(origin.y, f.minY + 8), f.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    private func togglePin() {
        setPinned(!isPinned)
    }

    private func setPinned(_ on: Bool) {
        isPinned = on
        pinButton?.image = Lucide.image(isPinned ? "pin-off" : "pin", size: 14)
        pinButton?.contentTintColor = isPinned ? theme.brandText : Theme.muted
        pinButton?.toolTip = isPinned ? L10n.t("取消钉住：恢复点击外部关闭", "Unpin: clicking outside closes")
                                      : L10n.t("钉住：点击面板外不自动关闭", "Pin: stay open when clicking outside")
    }

    // MARK: - 请求

    private func startAllRequests() {
        guard let stack = providersStack else { return }
        // 旧卡片的流必须先取消:否则切语言/重新提交后旧请求仍在跑、继续花 token
        for card in cards { card.cancel() }
        if let b = speakingButton, b !== speakSourceButton { stopSpeaking() }
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        cards.removeAll()

        let providers = config.activeProviders
        // 追问目标列表
        followupTargets = providers
        followupPopup?.removeAllItems()
        followupPopup?.addItems(withTitles: providers.map { $0.name })
        guard !providers.isEmpty else {
            let empty = emptyStateCard()
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return
        }
        // 输入模式且还没提交:也照常列出 provider 卡片,只是不发请求
        let pending = inputMode && sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        for (index, provider) in providers.enumerated() {
            let card = ProviderCardView(provider: provider, accent: accentColor(index), theme: theme)
            card.onRetry = { [weak self, weak card] in
                guard let self, let card else { return }
                self.request(provider: provider, card: card)
            }
            card.onCopy = { text in TranslationPanelController.copyToPasteboard(text) }
            card.onSpeak = { [weak self] text, button in self?.speak(text, from: button) }
            card.onStateChange = { [weak self] in
                guard let self, self.isVisible else { return }
                self.refreshControlStates()
            }
            // 操作过哪张卡片,追问目标就跟到哪张
            card.onInteract = { [weak self] in self?.selectFollowupTarget(index) }
            cards.append(card)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if pending {
                card.showIdle(L10n.t("在上方输入文本，按 Enter 开始翻译",
                                     "Type above and press Enter to translate"))
            } else {
                request(provider: provider, card: card)
            }
        }
    }

    private func request(provider: LLMProvider, card: ProviderCardView) {
        // 输入模式未提交时 sourceText 为空,不能把空串发给 API
        guard !sourceText.isEmpty else { NSSound.beep(); return }
        card.cancel()
        card.beginLoading()

        let source = sourcePopup.map { code(at: $0.indexOfSelectedItem) } ?? config.sourceLanguage
        let target = TranslatePrompt.resolveTarget(
            targetPopup.map { code(at: $0.indexOfSelectedItem) } ?? config.targetLanguage,
            text: sourceText)
        let m = TranslatePrompt.messages(source: source, target: target,
                                         text: sourceText, provider: provider)
        let msg = (system: m.system, user: m.user)
        let temperature = config.temperature

        // #16 敏感信息检查:远端 provider 且文本含敏感信息时先拦截
        switch SensitiveGuard.check(text: msg.user, provider: provider) {
        case .clean:
            startStream(provider: provider, card: card,
                        systemPrompt: msg.system, userText: msg.user,
                        temperature: temperature, restore: nil)
        case .send(let text, let restore):
            startStream(provider: provider, card: card,
                        systemPrompt: msg.system, userText: text,
                        temperature: temperature, restore: restore)
        case .ask(let hits, let sendText, let map):
            let kinds = Array(Set(hits.map { $0.kind }))
            let names = kinds.map { $0.displayName }.joined(separator: "、")
            card.showSensitiveDecision(
                summary: L10n.t("检测到 \(hits.count) 处敏感信息：\(names)",
                                "\(hits.count) sensitive item(s): \(names)")) { [weak self] decision in
                guard let self else { return }
                switch decision {
                case .masked:
                    self.startStream(provider: provider, card: card, systemPrompt: msg.system,
                                     userText: sendText, temperature: temperature,
                                     restore: { SensitiveDetector.restore($0, map: map).0 })
                case .sendAnyway:
                    self.startStream(provider: provider, card: card, systemPrompt: msg.system,
                                     userText: msg.user, temperature: temperature, restore: nil)
                case .cancel:
                    card.fail(L10n.t("已取消发送", "Cancelled"))
                }
            }
        }
    }

    /// 发起一次流式请求;restore 用于把占位符换回原文再显示。
    /// 记录实际发出的 system/user 到卡片历史,作为追问的第一轮。
    private func startStream(provider: LLMProvider, card: ProviderCardView,
                             systemPrompt: String?, userText: String,
                             temperature: Double,
                             restore: ((String) -> String)?) {
        card.restore = restore
        card.beginLoading()
        card.beginConversation(system: systemPrompt, user: userText)
        let handler = streamHandler(for: card)
        card.task = LLMClient.stream(text: userText, systemPrompt: systemPrompt,
                                     provider: provider, timeout: config.timeout,
                                     temperature: temperature, onEvent: handler)
    }

    /// 流事件回调:只认发起时的那一轮(turn),被取消/被重试替换的旧流迟到的事件直接丢弃,
    /// 避免两个流的文字交错写进同一张卡片
    private func streamHandler(for card: ProviderCardView) -> (LLMClient.Event) -> Void {
        let turn = card.turn
        return { [weak self, weak card] event in
            DispatchQueue.main.async {
                guard let self, let card, self.isVisible, card.turn == turn else { return }
                switch event {
                case .delta(let piece): card.append(piece)
                case .done:
                    card.finish()
                    self.updatePanelHeight()      // 结果变长后重新量高度
                case .failure(let message):
                    card.fail(message)
                    self.updatePanelHeight()
                }
            }
        }
    }

    // MARK: - 追问(#10)

    /// 底部追问输入:Enter 或按钮发送,只请求目标卡片对应 provider
    @objc private func followup() {
        let q = followupField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let idx = followupPopup?.indexOfSelectedItem ?? -1
        // 只允许对「已有完成回答且当前空闲」的卡片追问
        guard !q.isEmpty, followupTargets.indices.contains(idx),
              cards.indices.contains(idx), cards[idx].canFollowUp else { NSSound.beep(); return }
        let provider = followupTargets[idx]
        let card = cards[idx]
        card.cancel()
        followupField?.stringValue = ""
        card.beginFollowup(q)
        updatePanelHeight()
        if !isPinned { setPinned(true) }   // 追问时自动钉住,避免误点外部丢失对话

        let messages = card.followupMessages(maxChars: config.maxCharacters * 3)
        card.task = LLMClient.stream(messages: messages, provider: provider,
                                     timeout: config.timeout,
                                     temperature: config.temperature,
                                     onEvent: streamHandler(for: card))
        refreshControlStates()
    }

    @objc private func followupTargetChanged() { refreshControlStates() }

    private func selectFollowupTarget(_ index: Int) {
        guard let popup = followupPopup, popup.itemArray.indices.contains(index),
              popup.item(at: index)?.isEnabled == true else { return }
        popup.selectItem(at: index)
        refreshControlStates()
    }

    private func emptyStateCard() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = theme.surface.cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = theme.surfaceBorder.cgColor

        let title = NSTextField(labelWithString: L10n.t("还没有可用的翻译服务", "No translation service yet"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: L10n.t(
            "添加一个 OpenAI 兼容的服务（DeepSeek、硅基流动、Ollama…），填好 Base URL、模型和 API Key 并启用即可。",
            "Add an OpenAI-compatible service (DeepSeek, SiliconFlow, Ollama…), fill in Base URL, model and API key, then enable it."))
        body.font = .systemFont(ofSize: 11)
        body.textColor = Theme.muted
        body.preferredMaxLayoutWidth = 400
        let open = ClosureButton(title: L10n.t("添加服务", "Add Service")) {
            MainActor.assumeIsolated { AppRouter.openSettings(.ai) }
        }
        open.bezelStyle = .rounded
        open.controlSize = .small
        open.bezelColor = Theme.accent

        let stack = NSStackView(views: [title, body, open])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
        ])
        return box
    }

    /// 输入模式:把原文区内容作为待翻译文本提交
    private func submitInput() {
        let text = currentSourceText()
        guard !text.isEmpty, !cards.isEmpty else { NSSound.beep(); return }
        submittedInput = text
        truncated = text.count > config.maxCharacters
        sourceText = truncated ? String(text.prefix(config.maxCharacters)) : text
        escArmedUntil = nil
        startAllRequests()
        refreshControlStates()
        updatePanelHeight()
    }

    private var isBusy: Bool { cards.contains { $0.state == .loading } }

    private func stopAll() {
        for card in cards where card.state == .loading { card.stop() }
        refreshControlStates()
    }

    /// 输入模式下,原文区与最近一次提交不一致 → 卡片里的结果已过期
    private var isStale: Bool {
        inputMode && !submittedInput.isEmpty && currentSourceText() != submittedInput
    }

    /// 有尚未翻译过的输入(关闭会丢)
    private var hasUnsubmittedInput: Bool {
        guard inputMode else { return false }
        let live = currentSourceText()
        return !live.isEmpty && live != submittedInput
    }

    private var selectedSource: String {
        code(at: sourcePopup?.indexOfSelectedItem ?? index(of: config.sourceLanguage))
    }

    private var selectedTarget: String {
        code(at: targetPopup?.indexOfSelectedItem ?? index(of: config.targetLanguage))
    }

    private var sameLanguagePicked: Bool {
        selectedSource != "auto" && selectedSource == selectedTarget
    }

    // MARK: - 统一刷新控件状态

    /// 所有「能不能点 / 显示什么」都从当前状态推导,任何状态变化后调用一次即可
    private func refreshControlStates() {
        updateSourceActionsEnabled()
        setEnabled(swapButton, selectedSource != "auto",
                   tip: selectedSource == "auto"
                       ? L10n.t("原文语言为自动检测时无法互换，先选定原文语言", "Pick a source language to swap")
                       : L10n.t("互换语言", "Swap languages"))
        if let go = translateButton {
            if isBusy {
                go.title = L10n.t("停止", "Stop")
                go.isEnabled = true
                go.toolTip = L10n.t("停止所有进行中的请求", "Stop all running requests")
            } else {
                go.title = L10n.t("翻译 ⏎", "Translate ⏎")
                go.isEnabled = !currentSourceText().isEmpty && !cards.isEmpty
                go.toolTip = L10n.t("Enter 提交，Shift+Enter 换行", "Enter to translate, Shift+Enter for newline")
            }
        }
        updateBadge()
        updateFooter()
        refreshFollowup()
    }

    private func updateSourceActionsEnabled() {
        let on = !currentSourceText().isEmpty
        for b in [copySourceButton, speakSourceButton] where b !== speakingButton {
            setEnabled(b, on)
        }
    }

    private func setEnabled(_ button: NSButton?, _ on: Bool, tip: String? = nil) {
        guard let button else { return }
        button.isEnabled = on
        button.contentTintColor = on ? Theme.muted : Theme.faint
        button.alphaValue = on ? 1 : 0.35
        if let tip { button.toolTip = tip }
    }

    /// 徽标:方向文案只有一套(directionText);过期/同语言时换成警示色提示
    private func updateBadge() {
        guard let label = detectionLabel, let box = badgeBox else { return }
        // 输入模式未提交过:没有可展示的识别结果
        if inputMode && submittedInput.isEmpty && !sameLanguagePicked {
            box.isHidden = true
            return
        }
        box.isHidden = false
        var warning: String?
        if isStale {
            warning = currentSourceText().isEmpty
                ? L10n.t("原文已清空 · 下方为旧结果", "Source cleared · showing old results")
                : L10n.t("原文已修改 · Enter 重新翻译", "Edited · Enter to retranslate")
        } else if sameLanguagePicked {
            warning = L10n.t("原文与目标语言相同", "Source and target are the same")
        }
        if let warning {
            label.stringValue = warning
            label.textColor = Theme.warning
            box.layer?.backgroundColor = Theme.warning.withAlphaComponent(0.14).cgColor
        } else {
            label.stringValue = directionText()
            label.textColor = theme.badgeText
            box.layer?.backgroundColor = theme.badgeFill.cgColor
        }
    }

    /// 底部提示:Esc 二次确认 > 超长截断 > 默认隐私提示
    private func updateFooter() {
        guard let hint = footerHint, let icon = footerIcon else { return }
        let limit = config.maxCharacters
        let liveTooLong = inputMode && currentSourceText().count > limit
        if escArmedUntil != nil {
            hint.stringValue = L10n.t("再按一次 Esc 关闭，未翻译的输入会丢失", "Press Esc again to close; unsent input will be lost")
            hint.textColor = Theme.warning
            icon.image = Lucide.image("triangle-alert", size: 14)
            icon.contentTintColor = Theme.warning
        } else if liveTooLong || (truncated && !isStale) {
            hint.stringValue = L10n.t("原文超过 \(limit) 字，只翻译前 \(limit) 字",
                                      "Over \(limit) chars; only the first \(limit) are translated")
            hint.textColor = Theme.warning
            icon.image = Lucide.image("triangle-alert", size: 14)
            icon.contentTintColor = Theme.warning
        } else {
            hint.stringValue = L10n.t("文本会发送到你配置的第三方 API", "Text is sent to your configured API")
            hint.textColor = Theme.faint
            icon.image = Lucide.image("shield", size: 14)
            icon.contentTintColor = Theme.faint
        }
    }

    /// 追问行:只有「已有完成回答且空闲」的卡片可选;输入框在有对话可续时可用
    private func refreshFollowup() {
        guard let popup = followupPopup, let field = followupField else { return }
        for (i, item) in popup.itemArray.enumerated() {
            item.isEnabled = cards.indices.contains(i) && cards[i].canFollowUp
        }
        if popup.selectedItem?.isEnabled != true,
           let first = popup.itemArray.firstIndex(where: { $0.isEnabled }) {
            popup.selectItem(at: first)
        }
        let anyConversation = cards.contains { $0.hasConversation }
        popup.isEnabled = anyConversation
        // 正在输入时不禁用输入框(否则会丢焦点),只禁发送
        let editing = panel?.firstResponder === field.currentEditor()
        field.isEnabled = anyConversation || editing
        field.placeholderString = anyConversation
            ? L10n.t("对结果继续追问，Enter 发送…", "Ask a follow-up, Enter to send…")
            : L10n.t("翻译完成后可在这里追问", "Follow up once a result is ready")
        let target = popup.indexOfSelectedItem
        let ready = cards.indices.contains(target) && cards[target].canFollowUp
        let hasText = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        setEnabled(followupSendButton, ready && hasText,
                   tip: ready ? L10n.t("发送追问", "Send")
                              : L10n.t("目标服务还没有完成的回答", "Target has no finished result yet"))
    }

    // MARK: - NSTextViewDelegate(原文区)

    func textDidChange(_ notification: Notification) {
        escArmedUntil = nil
        refreshControlStates()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // NSTextView 默认把 Esc 映射成 complete:(弹补全菜单),这里改成关闭面板
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            requestClose()
            return true
        }
        guard inputMode, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if textView.hasMarkedText() { return false }                  // 输入法组字中的回车交给输入法
        if NSEvent.modifierFlags.contains(.shift) { return false }   // Shift+Enter 换行
        submitInput()
        return true
    }

    // MARK: - NSTextFieldDelegate(追问框)

    func controlTextDidChange(_ obj: Notification) {
        refreshFollowup()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === followupField,
              commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        // 追问框里 Esc:有内容先清空,空了再走关闭流程
        if let field = followupField, !field.stringValue.isEmpty {
            field.stringValue = ""
            refreshFollowup()
        } else {
            requestClose()
        }
        return true
    }

    /// 翻译方向:「自动 · 英语 → 自动 · 简体中文」;手动选了语言就只写语言名
    private func directionText() -> String {
        let src = selectedSource
        let dst = selectedTarget
        let auto = L10n.t("自动", "Auto")
        let detected = LanguageDetect.code(sourceText)
        let from = src == "auto" ? (sourceText.isEmpty ? auto : "\(auto) · \(Self.languageTitle(detected))") : Self.languageTitle(src)
        let target = TranslatePrompt.resolveTarget(dst, text: sourceText)
        let to = dst == "auto" ? "\(auto) · \(Self.languageTitle(target))" : Self.languageTitle(target)
        return "\(from) → \(to)"
    }

    static func languageTitle(_ code: String) -> String {
        switch code {
        case "zh-CN", "zh": return L10n.t("简体中文", "Chinese")
        case "en": return L10n.t("英语", "English")
        case "ja": return L10n.t("日语", "Japanese")
        case "ko": return L10n.t("韩语", "Korean")
        default: return code
        }
    }

    /// 改语言:结果对应的原文没变时立即按新语言重译;
    /// 输入模式下原文已改动/未提交时只刷新提示,不偷偷提交;同语言不发请求
    @objc private func languageChanged() {
        let canRerun = !sourceText.isEmpty && !isStale && !sameLanguagePicked
        if canRerun {
            startAllRequests()
            updatePanelHeight()
        }
        refreshControlStates()
    }

    // MARK: - 小工具

    private func accentColor(_ index: Int) -> NSColor {
        // 多服务对比时区分卡片的小色点:只用令牌里的几种语义色
        let palette: [NSColor] = [Theme.accent, Theme.success, Theme.warning, Theme.muted, Theme.danger]
        return palette[index % palette.count]
    }

    private func code(at index: Int) -> String {
        guard index >= 0 && index < languageOptions.count else { return "auto" }
        return languageOptions[index].0
    }

    private func index(of code: String) -> Int {
        languageOptions.firstIndex { $0.0 == code } ?? 0
    }

    private func makeLanguagePopup(selected: String) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: languageOptions.map { L10n.t($0.1, $0.2) })
        popup.selectItem(at: index(of: selected))
        popup.font = .systemFont(ofSize: 11)
        popup.controlSize = .small
        return popup
    }

    private func makeBadge(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = theme.badgeText
        label.translatesAutoresizingMaskIntoConstraints = false
        detectionLabel = label

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 9.5
        box.layer?.backgroundColor = theme.badgeFill.cgColor
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 19),
        ])
        return box
    }

    private func makeIconButton(_ symbol: String, _ tip: String,
                                action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: "", action: action)
        button.image = Lucide.image(Self.lucide[symbol] ?? symbol, size: 14)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = Theme.muted
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func makeTextButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.contentTintColor = Theme.muted
        return button
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    /// 输入模式下以 TextView 现文为准（提交前 sourceText 可能还是空的）
    private func currentSourceText() -> String {
        let live = sourceTextView?.string ?? sourceText
        return live.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        PasteboardGuard.write(text)
    }

    private func copyToPasteboard(_ text: String) { TranslationPanelController.copyToPasteboard(text) }

    /// 朗读:同一个按钮再点一次=停止;点别的按钮=停掉当前、改读新的。
    /// 正在朗读的按钮切成「停止」图标,结束/取消时还原
    private func speak(_ text: String, from button: NSButton?) {
        let toggleOff = speech.isSpeaking && button != nil && button === speakingButton
        stopSpeaking()
        guard !toggleOff, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        if LanguageDetect.containsCJK(text) {
            SpeakVoice.apply(utterance, fallbackLanguage: LanguageDetect.code(text))
        } else {
            SpeakVoice.apply(utterance, fallbackLanguage: nil)
        }
        speakingUtterance = utterance
        if let button {
            speakingButton = button
            speakingTip = button.toolTip ?? ""
            button.image = Lucide.image("square", size: 14)
            button.contentTintColor = theme.brandText
            button.toolTip = L10n.t("停止朗读", "Stop speaking")
        }
        speech.speak(utterance)
    }

    private func stopSpeaking() {
        speakingUtterance = nil
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        restoreSpeakingButton()
    }

    private func restoreSpeakingButton() {
        guard let button = speakingButton else { return }
        speakingButton = nil
        button.image = Lucide.image("volume-2", size: 14)
        button.toolTip = speakingTip
        button.contentTintColor = button.isEnabled ? Theme.muted : Theme.faint
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speechEnded(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        speechEnded(utterance)
    }

    /// 只处理当前这句:stop 后立即开始新的一句时,旧句迟到的 didCancel 不能还原新按钮
    private func speechEnded(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, utterance === self.speakingUtterance else { return }
            self.speakingUtterance = nil
            self.restoreSpeakingButton()
            self.refreshControlStates()
        }
    }
}

/// 复制按钮短暂切成对勾 +「已复制」
fileprivate func flashCopied(_ button: NSButton, icon: String, tip: String) {
    button.image = Lucide.image("check", size: 14)
    button.contentTintColor = Theme.success
    button.toolTip = L10n.t("已复制", "Copied")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak button] in
        guard let button else { return }
        button.image = Lucide.image(icon, size: 14)
        // 1.5 秒内按钮可能已被置灰,按当前启用状态还原颜色
        button.contentTintColor = button.isEnabled ? Theme.muted : Theme.faint
        button.toolTip = tip
    }
}

/// flipped 容器:让 NSScrollView 的 documentView 从顶部开始排列
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 在 TextView 内按同一套 inset / padding 画占位文案，避免叠 NSTextField 与光标错位
final class PlaceholderTextView: NSTextView {
    var placeholderString = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let pad = textContainer?.lineFragmentPadding ?? 5
        let origin = CGPoint(x: textContainerInset.width + pad,
                             y: textContainerInset.height)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13.5),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let size = (placeholderString as NSString).size(withAttributes: attrs)
        placeholderString.draw(in: CGRect(origin: origin, size: size), withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// 面板配色：v3 起全部映射到 PopBarDesign 的设计令牌（暖灰中性色 + 朱红强调色），
/// 不再使用品牌紫与淡紫渐变。保留这个类型只是为了让老视图代码少改动。
struct PanelTheme {
    let dark: Bool

    static var current: PanelTheme {
        PanelTheme(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    static let brand = Theme.accent

    var gradientTop: NSColor { Theme.surface }
    var gradientBottom: NSColor { Theme.surface }
    var surface: NSColor { Theme.surface2 }
    var surfaceBorder: NSColor { Theme.border }
    var badgeFill: NSColor { Theme.accentSoft }
    var badgeText: NSColor { Theme.accent }
    var brandText: NSColor { Theme.accent }

    func cardFill(_ accent: NSColor) -> NSColor { Theme.surface }
    func cardHeaderFill(_ accent: NSColor) -> NSColor { Theme.surface2 }
    func cardBorder(_ accent: NSColor) -> NSColor { Theme.border }
}

/// 竖向渐变底色;传入动态 NSColor 时会随系统外观实时更新
final class GradientView: NSView {
    private let topColor: NSColor
    private let bottomColor: NSColor
    private var gradientLayer: CAGradientLayer? { layer as? CAGradientLayer }

    init(top: NSColor, bottom: NSColor) {
        topColor = top
        bottomColor = bottom
        super.init(frame: .zero)
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer = gradient
        wantsLayer = true
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        // cgColor 依赖当前外观上下文,必须在 performAsCurrentDrawingAppearance 里取
        effectiveAppearance.performAsCurrentDrawingAppearance {
            gradientLayer?.colors = [topColor.cgColor, bottomColor.cgColor]
        }
    }
}

/// 无边框但可以成为 key window 的面板
final class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?
    /// ⌘W:无边框窗口没有关闭按钮,默认 performClose 只会响一声;设置后改为调用它
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) {
        if let onClose { onClose() } else { super.performClose(sender) }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performClose(_:)), onClose != nil { return true }
        return super.validateMenuItem(menuItem)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// 用闭包当 action 的按钮
final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(invoke)
        setButtonType(.momentaryPushIn)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { handler() }
}

/// 单个 provider 的翻译卡片:名称 + 状态 + 流式结果 + 复制/朗读/重试
final class ProviderCardView: NSView {
    /// 卡片生命周期;按钮的启用/图标都由它推导(见 updateButtons)
    enum State { case idle, loading, done, failed, confirming }

    var onRetry: (() -> Void)?
    var onCopy: ((String) -> Void)?
    var onSpeak: ((String, NSButton) -> Void)?
    /// 状态变化(面板据此刷新翻译按钮、追问目标等)
    var onStateChange: (() -> Void)?
    /// 用户点了这张卡片上的任一按钮
    var onInteract: (() -> Void)?
    /// #16 脱敏发送时,把占位符换回原文的还原函数
    var restore: ((String) -> String)?
    var task: Task<Void, Never>?

    /// 每开始一轮(请求/追问/停止)自增;流回调只认发起时的 turn,旧流迟到的事件会被丢弃
    private(set) var turn = 0
    private(set) var state: State = .idle {
        didSet {
            updateButtons()
            if oldValue != state { onStateChange?() }
        }
    }

    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyField = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "", target: nil, action: nil)
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private let speakButton = NSButton(title: "", target: nil, action: nil)
    private let dot = NSView()
    private var decisionBox: NSView?

    private(set) var text = ""
    /// 显示用的文本(脱敏模式还原后);复制/朗读用这份
    var displayed: String { restore?(text) ?? text }
    /// #10 对话历史(实际发出的消息)与转写文本(前序轮次的展示累积)
    private(set) var history: [[String: String]] = []
    private var transcript = ""
    /// 当前这一轮是追问(失败时要把没得到回答的提问从历史里撤掉)
    private var inFollowup = false
    private let provider: LLMProvider

    /// 至少有一轮回答,可以续聊
    var hasConversation: Bool { history.contains { $0["role"] == "assistant" } }
    /// 可以立即发起追问:有回答且当前空闲
    var canFollowUp: Bool { hasConversation && state != .loading && state != .confirming }

    init(provider: LLMProvider, accent: NSColor, theme: PanelTheme) {
        self.provider = provider
        super.init(frame: .zero)

        // 白底轻染 provider 主色 + 同色细边 + 左侧色条,一眼区分各家结果
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = theme.cardFill(accent).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = theme.cardBorder(accent).cgColor

        let strip = NSView()
        strip.wantsLayer = true
        strip.layer?.backgroundColor = accent.withAlphaComponent(0.85).cgColor
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        let headerBand = NSView()
        headerBand.wantsLayer = true
        headerBand.layer?.backgroundColor = theme.cardHeaderFill(accent).cgColor
        headerBand.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBand)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.widthAnchor.constraint(equalToConstant: 3),
            headerBand.leadingAnchor.constraint(equalTo: strip.trailingAnchor),
            headerBand.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBand.topAnchor.constraint(equalTo: topAnchor),
            headerBand.heightAnchor.constraint(equalToConstant: 34),
        ])

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = accent.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        nameLabel.stringValue = provider.name
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = accent.blended(withFraction: theme.dark ? 0.35 : 0.25,
                                             of: theme.dark ? .white : .black) ?? accent
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        // 状态行始终带模型名:「deepseek-chat · 完成」,完成后也能看出用的哪个模型
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = Theme.faint
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setStatus(nil)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 13).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 13).isActive = true

        for (button, icon, action) in [(retryButton, "refresh-cw", #selector(retryTapped)),
                                       (copyButton, "copy", #selector(copyTapped)),
                                       (speakButton, "volume-2", #selector(speakTapped))] {
            button.image = Lucide.image(icon, size: 14)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = Theme.muted
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        }

        bodyField.font = .systemFont(ofSize: 13)
        bodyField.textColor = Theme.text
        bodyField.isSelectable = true
        bodyField.maximumNumberOfLines = 0
        bodyField.lineBreakMode = .byWordWrapping
        bodyField.preferredMaxLayoutWidth = 420
        bodyField.stringValue = L10n.t("等待请求…", "Waiting…")

        let header = NSStackView(views: [dot, nameLabel, statusLabel, NSView(), spinner,
                                        retryButton, copyButton, speakButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        let column = NSStackView(views: [header, bodyField])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 20),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            bodyField.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 状态与按钮

    private func setStatus(_ status: String?, color: NSColor = Theme.faint) {
        statusLabel.stringValue = status.map { "\(provider.model) · \($0)" } ?? provider.model
        statusLabel.textColor = color
    }

    private func setEnabled(_ button: NSButton, _ on: Bool) {
        button.isEnabled = on
        // 正在朗读时图标/颜色由面板控制,这里只管启用态
        if button.toolTip != L10n.t("停止朗读", "Stop speaking") {
            button.contentTintColor = on ? Theme.muted : Theme.faint
        }
        button.alphaValue = on ? 1 : 0.35
    }

    private var copyTip: String {
        transcript.isEmpty ? L10n.t("复制译文", "Copy result") : L10n.t("复制最新一轮回答", "Copy latest answer")
    }

    /// 空闲:三个都灰;请求中:↻ 变「停止」,复制/朗读灰;其它:按有无文本启用
    private func updateButtons() {
        let hasText = !displayed.isEmpty
        switch state {
        case .idle:
            setEnabled(retryButton, false)
            setEnabled(copyButton, false)
            setEnabled(speakButton, false)
            retryButton.image = Lucide.image("refresh-cw", size: 14)
            retryButton.toolTip = L10n.t("提交原文后可重新请求", "Available after submitting")
        case .loading:
            setEnabled(retryButton, true)
            setEnabled(copyButton, false)
            setEnabled(speakButton, false)
            retryButton.image = Lucide.image("square", size: 14)
            retryButton.toolTip = L10n.t("停止请求", "Stop")
        case .done, .failed, .confirming:
            setEnabled(retryButton, true)
            setEnabled(copyButton, hasText)
            setEnabled(speakButton, hasText)
            retryButton.image = Lucide.image("refresh-cw", size: 14)
            retryButton.toolTip = transcript.isEmpty
                ? L10n.t("重新请求", "Retry request")
                : L10n.t("重新请求（会清空追问记录）", "Retry (clears follow-ups)")
        }
        copyButton.toolTip = copyTip
        if speakButton.toolTip != L10n.t("停止朗读", "Stop speaking") {
            speakButton.toolTip = transcript.isEmpty ? L10n.t("朗读译文", "Speak result")
                                                     : L10n.t("朗读最新一轮回答", "Speak latest answer")
        }
    }

    /// 输入模式的待机占位:列表照常显示 provider(状态栏保留模型名),但不发请求
    func showIdle(_ hint: String) {
        bodyField.textColor = Theme.muted
        bodyField.stringValue = hint
        setStatus(nil)
        state = .idle
    }

    func beginLoading() {
        turn += 1
        text = ""
        inFollowup = false
        decisionBox?.removeFromSuperview()
        decisionBox = nil
        bodyField.stringValue = transcript
        bodyField.textColor = Theme.text
        setStatus(L10n.t("请求中…", "Requesting…"))
        spinner.startAnimation(nil)
        state = .loading
    }

    /// #16 ask 模式:正文显示提示,下面给出三个选择按钮
    func showSensitiveDecision(summary: String,
                               onChoice: @escaping (SensitiveDecision) -> Void) {
        spinner.stopAnimation(nil)
        setStatus(L10n.t("等待确认", "Needs confirmation"), color: Theme.warning)
        bodyField.textColor = Theme.muted
        bodyField.stringValue = "🔒 " + summary

        let mask = ClosureButton(title: L10n.t("脱敏后发送", "Mask & send")) {
            onChoice(.masked)
        }
        mask.bezelStyle = .rounded
        mask.controlSize = .small
        mask.bezelColor = PanelTheme.brand
        let send = ClosureButton(title: L10n.t("仍然发送", "Send anyway")) {
            onChoice(.sendAnyway)
        }
        send.bezelStyle = .rounded
        send.controlSize = .small
        let cancel = ClosureButton(title: L10n.t("取消", "Cancel")) {
            onChoice(.cancel)
        }
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        let row = NSStackView(views: [mask, send, cancel])
        row.orientation = .horizontal
        row.spacing = 8
        (subviews.compactMap { $0 as? NSStackView }.last)?.addArrangedSubview(row)
        decisionBox = row
        state = .confirming
    }

    func append(_ piece: String) {
        text += piece
        bodyField.stringValue = transcript + displayed
    }

    // MARK: - 追问/历史(#10)

    /// 记录实际发出的首轮消息
    func beginConversation(system: String?, user: String) {
        history = []
        transcript = ""
        if let s = system, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            history.append(["role": "system", "content": s])
        }
        history.append(["role": "user", "content": user])
        updateButtons()
    }

    /// 开始一轮追问:上一轮回答并入转写,提问写入转写与历史
    func beginFollowup(_ question: String) {
        turn += 1
        let answer = displayed
        if !answer.isEmpty { transcript += answer + "\n\n" }
        transcript += "↳ \(question)\n\n"
        history.append(["role": "user", "content": question])
        text = ""
        inFollowup = true
        decisionBox?.removeFromSuperview()
        decisionBox = nil
        bodyField.stringValue = transcript
        bodyField.textColor = Theme.text
        setStatus(L10n.t("追问中…", "Following up…"))
        spinner.startAnimation(nil)
        state = .loading
    }

    /// 组装追问请求:system + 最近若干条历史(已含本轮提问);超出字符上限从旧轮次成对丢弃
    func followupMessages(maxChars: Int) -> [[String: String]] {
        let sys = history.first { $0["role"] == "system" }
        var rest = history.filter { $0["role"] != "system" }
        if rest.count > 13 { rest = Array(rest.suffix(13)) }
        func total() -> Int {
            rest.reduce(0) { $0 + ($1["content"]?.count ?? 0) } + (sys?["content"]?.count ?? 0)
        }
        // 历史为 user/assistant 交替且以本轮提问结尾,成对丢弃保证至少留下这条提问
        while total() > maxChars && rest.count >= 3 { rest.removeFirst(2) }
        return (sys.map { [$0] } ?? []) + rest
    }

    /// 一轮没正常结束(失败/停止/空回答):有部分输出就作为回答入历史,
    /// 追问轮次没有任何输出则撤掉提问,保证下次追问的历史仍是 user/assistant 交替
    private func closeIncompleteTurn() {
        if !text.isEmpty {
            history.append(["role": "assistant", "content": text])
        } else if inFollowup, history.last?["role"] == "user" {
            history.removeLast()
        }
        inFollowup = false
    }

    func finish() {
        spinner.stopAnimation(nil)
        if text.isEmpty {
            setStatus(L10n.t("没有返回内容", "Empty response"), color: Theme.warning)
            bodyField.stringValue = transcript + L10n.t("（服务没有返回内容，可点 ↻ 重试）", "(Empty response — click ↻ to retry)")
            bodyField.textColor = transcript.isEmpty ? Theme.muted : Theme.text
            closeIncompleteTurn()
            state = .failed
        } else {
            history.append(["role": "assistant", "content": text])
            inFollowup = false
            setStatus(L10n.t("完成", "Done"))
            state = .done
        }
    }

    func fail(_ message: String) {
        spinner.stopAnimation(nil)
        setStatus(L10n.t("失败", "Failed"), color: Theme.danger)
        if text.isEmpty {
            bodyField.stringValue = transcript + message
            bodyField.textColor = transcript.isEmpty ? Theme.danger : Theme.text
        } else {
            // 已有部分输出:保留它,错误原因追加在后面,不再丢失
            bodyField.stringValue = transcript + displayed + "\n\n⚠ " + message
            bodyField.textColor = Theme.text
        }
        closeIncompleteTurn()
        state = .failed
    }

    /// 用户主动停止:保留已输出的部分
    func stop() {
        guard state == .loading else { return }
        cancel()
        turn += 1
        setStatus(L10n.t("已停止", "Stopped"), color: Theme.warning)
        if text.isEmpty {
            bodyField.stringValue = transcript + L10n.t("（已停止）", "(Stopped)")
            bodyField.textColor = transcript.isEmpty ? Theme.muted : Theme.text
        }
        closeIncompleteTurn()
        state = .failed
    }

    func cancel() {
        task?.cancel()
        task = nil
        spinner.stopAnimation(nil)
    }

    // MARK: - 按钮

    @objc private func copyTapped() {
        onInteract?()
        let text = displayed
        guard !text.isEmpty else { return }
        onCopy?(text)
        flashCopied(copyButton, icon: "copy", tip: copyTip)
    }

    @objc private func speakTapped() {
        onInteract?()
        onSpeak?(displayed, speakButton)
    }

    @objc private func retryTapped() {
        onInteract?()
        if state == .loading { stop() } else { onRetry?() }
    }
}
