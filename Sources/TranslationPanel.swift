import Cocoa
import AVFoundation

/// AI 翻译面板:顶部原文,下方每个 provider 一张卡片,流式显示结果。
/// 面板会成为 key window(可滚动、可选中、可 Cmd+C),按 Esc 或点击面板外部关闭。
final class TranslationPanelController: NSObject, NSTextViewDelegate {
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
    private var inputMode = false
    private var inputPlaceholder: NSTextField?
    private var badgeBox: NSView?
    /// #10 追问输入框与目标 provider 选择
    private var followupField: NSTextField?
    private var followupPopup: NSPopUpButton?
    private var followupTargets: [LLMProvider] = []

    private let panelSize = NSSize(width: 480, height: 580)

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect { panel?.frame ?? .zero }

    /// (语言代码, 中文名, 英文名);各语言母语名中英界面下保持一致
    private let languageOptions: [(String, String, String)] = [
        ("auto", "自动检测", "Auto"), ("zh-CN", "中文简体", "Simplified Chinese"),
        ("en", "English", "English"), ("ja", "日本語", "Japanese"), ("ko", "한국어", "Korean"),
    ]

    // MARK: - 显示 / 关闭

    func show(text: String) {
        inputMode = false
        open(text: text)
    }

    /// 划词来源
    func show(ctx: SourceContext) {
        inputMode = false
        open(text: ctx.text)
    }

    /// 输入翻译:原文区可编辑,Enter 提交翻译
    func showInput() {
        inputMode = true
        open(text: "")
    }

    private func open(text: String) {
        close()
        config = ConfigStore.shared.config
        theme = PanelTheme.current
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        truncated = trimmed.count > config.maxCharacters
        sourceText = truncated ? String(trimmed.prefix(config.maxCharacters)) : trimmed

        buildPanel()
        startAllRequests()
        updatePanelHeight()
        if !isPinned { positionPanel() }   // 钉住时保留用户拖过的位置
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

    func close() {
        for card in cards { card.cancel() }
        cards.removeAll()
        speech.stopSpeaking(at: .immediate)
        panel?.orderOut(nil)
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
            p.onEscape = { [weak self] in self?.close() }
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

        let pin = makeIconButton(isPinned ? "pin.fill" : "pin",
                                 isPinned ? L10n.t("取消钉住:恢复点击外部关闭", "Unpin: clicking outside closes")
                                          : L10n.t("钉住:点击面板外不自动关闭", "Pin: stay open when clicking outside")) { [weak self] in
            self?.togglePin()
        }
        pin.contentTintColor = isPinned ? theme.brandText : .secondaryLabelColor
        pinButton = pin
        header.addArrangedSubview(pin)
        header.setCustomSpacing(4, after: pin)
        let logo = NSImageView(image: NSImage(systemSymbolName: "sparkles",
                                              accessibilityDescription: nil) ?? NSImage())
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
        let badge = makeBadge(L10n.t("识别为 ", "Detected: ") + LanguageDetect.describe(sourceText))
        badge.isHidden = inputMode     // 输入模式下等提交后再显示识别结果
        badgeBox = badge
        header.addArrangedSubview(badge)
        header.addArrangedSubview(spacer())
        header.addArrangedSubview(makeIconButton("doc.on.doc", L10n.t("复制原文", "Copy source")) { [weak self] in
            self?.copyToPasteboard(self?.sourceText ?? "")
        })
        header.addArrangedSubview(makeIconButton("speaker.wave.2", L10n.t("朗读原文", "Speak source")) { [weak self] in
            self?.speak(self?.sourceText ?? "")
        })
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
            if sv == "auto" { return }
            s.selectItem(at: self.index(of: dv == "auto" ? LanguageDetect.code(self.sourceText) : dv))
            d.selectItem(at: self.index(of: sv))
            self.languageChanged()
        }
        // AI 动作模式:语言由动作自身的提示词决定,隐藏语言行
        langRow.addArrangedSubview(src)
        langRow.addArrangedSubview(swap)
        langRow.addArrangedSubview(dst)
        langRow.addArrangedSubview(spacer())
        if inputMode {
            let go = ClosureButton(title: L10n.t("翻译 ⏎", "Translate ⏎")) { [weak self] in self?.submitInput() }
            go.bezelStyle = .rounded
            go.controlSize = .small
            go.bezelColor = PanelTheme.brand
            go.font = .systemFont(ofSize: 11, weight: .medium)
            go.toolTip = L10n.t("Enter 提交,Shift+Enter 换行", "Enter to translate, Shift+Enter for newline")
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
        followupPopup = popup
        let field = NSTextField()
        field.placeholderString = L10n.t("对结果继续追问,Enter 发送…", "Ask a follow-up, Enter to send…")
        field.font = .systemFont(ofSize: 11)
        field.controlSize = .small
        field.target = self
        field.action = #selector(followup)
        followupField = field
        let send = makeIconButton("arrow.up.circle", L10n.t("发送追问", "Send")) { [weak self] in
            self?.followup()
        }
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
        let lock = NSImageView(image: NSImage(systemSymbolName: "lock.shield",
                                              accessibilityDescription: nil) ?? NSImage())
        lock.contentTintColor = .tertiaryLabelColor
        lock.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        let hint = NSTextField(labelWithString: L10n.t("文本会发送到你配置的第三方 API",
                                                     "Text is sent to your configured API"))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        footer.addArrangedSubview(lock)
        footer.addArrangedSubview(hint)
        footer.addArrangedSubview(spacer())
        let settings = makeTextButton(L10n.t("⚙︎ 设置", "⚙︎ Settings")) {
            AppDelegate.openTranslateConfig()
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

        let tv = NSTextView()
        tv.isEditable = inputMode
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 13.5)
        tv.textContainerInset = NSSize(width: 10, height: 8)
        tv.string = sourceText
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = self
        scroll.documentView = tv
        sourceTextView = tv
        if inputMode {
            let ph = NSTextField(labelWithString: L10n.t("输入或粘贴要翻译的文本",
                                                       "Type or paste text to translate"))
            ph.font = .systemFont(ofSize: 13.5)
            ph.textColor = .placeholderTextColor
            ph.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(ph)
            // 钉到 textView 的真实文字原点(textContainerInset + lineFragmentPadding),
            // 钉 scroll 边缘会和光标错位
            let textX = tv.textContainerInset.width + (tv.textContainer?.lineFragmentPadding ?? 0)
            ph.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: textX).isActive = true
            ph.topAnchor.constraint(equalTo: tv.topAnchor,
                                    constant: tv.textContainerInset.height).isActive = true
            inputPlaceholder = ph
        }
        return scroll
    }

    /// 按偏好「面板位置」摆放:默认屏幕中上方,也可跟随鼠标
    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let f = screen?.visibleFrame, let panel else { return }
        let size = panel.frame.size
        var origin: NSPoint
        if ConfigStore.shared.config.panelPosition == "cursor" {
            origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 8)
        } else {
            origin = NSPoint(x: f.midX - size.width / 2,
                             y: f.maxY - size.height - 48)
        }
        origin.x = min(max(origin.x, f.minX + 8), f.maxX - size.width - 8)
        origin.y = min(max(origin.y, f.minY + 8), f.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    private func togglePin() {
        isPinned.toggle()
        pinButton?.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin",
                                   accessibilityDescription: nil)
        pinButton?.contentTintColor = isPinned ? theme.brandText : .secondaryLabelColor
        pinButton?.toolTip = isPinned ? L10n.t("取消钉住:恢复点击外部关闭", "Unpin: clicking outside closes")
                                      : L10n.t("钉住:点击面板外不自动关闭", "Pin: stay open when clicking outside")
    }

    // MARK: - 请求

    private func startAllRequests() {
        guard let stack = providersStack else { return }
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
            card.onSpeak = { [weak self] text in self?.speak(text) }
            cards.append(card)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if pending {
                card.showIdle(L10n.t("在上方输入文本,按 Enter 开始翻译",
                                     "Type above and press Enter to translate"))
            } else {
                request(provider: provider, card: card)
            }
        }
    }

    private func request(provider: LLMProvider, card: ProviderCardView) {
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
                summary: L10n.t("检测到 \(hits.count) 处敏感信息:\(names)",
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
        let task = LLMClient.stream(text: userText, systemPrompt: systemPrompt,
                                    provider: provider, timeout: config.timeout,
                                    temperature: temperature) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.isVisible else { return }
                switch event {
                case .delta(let piece): card.append(piece)
                case .done:
                    card.finish()
                    card.completeTurn()
                    self.updatePanelHeight()      // 结果变长后重新量高度
                case .failure(let message):
                    card.fail(message)
                    self.updatePanelHeight()
                }
            }
        }
        card.task = task
    }

    // MARK: - 追问(#10)

    /// 底部追问输入:Enter 或按钮发送,只请求目标卡片对应 provider
    @objc private func followup() {
        let q = followupField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let idx = followupPopup?.indexOfSelectedItem ?? -1
        guard !q.isEmpty, followupTargets.indices.contains(idx),
              cards.indices.contains(idx) else { NSSound.beep(); return }
        let provider = followupTargets[idx]
        let card = cards[idx]
        followupField?.stringValue = ""
        card.beginFollowup(q)
        updatePanelHeight()
        if !isPinned { togglePin() }   // 追问时自动钉住,避免误点外部丢失对话

        let messages = card.followupMessages(question: q,
                                             maxChars: config.maxCharacters * 3)
        let task = LLMClient.stream(messages: messages, provider: provider,
                                    timeout: config.timeout,
                                    temperature: config.temperature) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.isVisible else { return }
                switch event {
                case .delta(let piece): card.append(piece)
                case .done:
                    card.finish()
                    card.completeTurn()
                    self.updatePanelHeight()
                case .failure(let message):
                    card.fail(message)
                    self.updatePanelHeight()
                }
            }
        }
        card.task = task
    }

    private func emptyStateCard() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = theme.surface.cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = theme.surfaceBorder.cgColor

        let title = NSTextField(labelWithString: L10n.t("还没有可用的 provider", "No providers available"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: L10n.t(
            "添加一个 OpenAI 兼容的服务(DeepSeek、硅基流动、Ollama…),填好 Base URL、模型和 API Key 并启用即可。",
            "Add an OpenAI-compatible service (DeepSeek, SiliconFlow, Ollama…), fill in Base URL, model and API key, then enable it."))
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 400
        let open = ClosureButton(title: L10n.t("打开 AI 翻译设置", "Open AI Translation Settings")) {
            AppDelegate.openTranslateConfig()
        }
        open.bezelStyle = .rounded
        open.controlSize = .small
        open.bezelColor = PanelTheme.brand

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
        let text = sourceTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { NSSound.beep(); return }
        truncated = text.count > config.maxCharacters
        sourceText = truncated ? String(text.prefix(config.maxCharacters)) : text
        badgeBox?.isHidden = false
        detectionLabel?.stringValue = L10n.t("识别为 ", "Detected: ") + LanguageDetect.describe(sourceText)
        startAllRequests()
        updatePanelHeight()
    }

    // MARK: - NSTextViewDelegate(输入模式)

    func textDidChange(_ notification: Notification) {
        guard inputMode else { return }
        inputPlaceholder?.isHidden = !(sourceTextView?.string.isEmpty ?? true)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard inputMode, commandSelector == NSSelectorFromString("insertNewline:") else { return false }
        if NSEvent.modifierFlags.contains(.shift) { return false }   // Shift+Enter 换行
        submitInput()
        return true
    }

    @objc private func languageChanged() {
        detectionLabel?.stringValue = L10n.t("识别为 ", "Detected: ") + LanguageDetect.describe(sourceText)
        startAllRequests()
        updatePanelHeight()
    }

    // MARK: - 小工具

    private func accentColor(_ index: Int) -> NSColor {
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemOrange,
                                  .systemGreen, .systemPink, .systemTeal, .systemIndigo]
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
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func makeTextButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private static func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyToPasteboard(_ text: String) { TranslationPanelController.copyToPasteboard(text) }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate); return }
        let utterance = AVSpeechUtterance(string: text)
        if LanguageDetect.containsCJK(text) {
            utterance.voice = AVSpeechSynthesisVoice(language: LanguageDetect.code(text))
        }
        speech.speak(utterance)
    }
}

/// flipped 容器:让 NSScrollView 的 documentView 从顶部开始排列
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 翻译面板的浅色调:品牌紫做点缀,浅色模式偏淡紫白,深色模式偏暗紫灰。
/// layer 颜色不会随外观自动刷新,所以每次建面板时按当前外观取一次
struct PanelTheme {
    let dark: Bool

    static var current: PanelTheme {
        PanelTheme(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    static let brand = NSColor(srgbRed: 0.45, green: 0.30, blue: 0.95, alpha: 1)

    var gradientTop: NSColor {
        dark ? rgb(0.22, 0.18, 0.36, 0.60) : rgb(0.93, 0.91, 1.00, 0.94)
    }
    var gradientBottom: NSColor {
        dark ? rgb(0.13, 0.13, 0.17, 0.40) : rgb(0.99, 0.99, 1.00, 0.90)
    }
    var surface: NSColor { dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 1, alpha: 0.88) }
    var surfaceBorder: NSColor { PanelTheme.brand.withAlphaComponent(dark ? 0.30 : 0.14) }
    var badgeFill: NSColor { PanelTheme.brand.withAlphaComponent(dark ? 0.30 : 0.11) }
    var badgeText: NSColor { dark ? rgb(0.80, 0.74, 1.00, 1) : rgb(0.36, 0.24, 0.84, 1) }
    var brandText: NSColor { dark ? rgb(0.74, 0.66, 1.00, 1) : PanelTheme.brand }

    func cardFill(_ accent: NSColor) -> NSColor {
        dark ? NSColor(white: 0.16, alpha: 1).blended(withFraction: 0.14, of: accent)!.withAlphaComponent(0.78)
             : NSColor.white.blended(withFraction: 0.05, of: accent)!.withAlphaComponent(0.94)
    }
    func cardHeaderFill(_ accent: NSColor) -> NSColor { accent.withAlphaComponent(dark ? 0.16 : 0.07) }
    func cardBorder(_ accent: NSColor) -> NSColor { accent.withAlphaComponent(dark ? 0.35 : 0.20) }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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
    var onRetry: (() -> Void)?
    var onCopy: ((String) -> Void)?
    var onSpeak: ((String) -> Void)?
    /// #16 脱敏发送时,把占位符换回原文的还原函数
    var restore: ((String) -> String)?
    var task: Task<Void, Never>?

    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyField = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton: NSButton
    private let dot = NSView()
    private var decisionBox: NSView?

    private(set) var text = ""
    /// 显示用的文本(脱敏模式还原后);复制/朗读用这份
    var displayed: String { restore?(text) ?? text }
    /// #10 对话历史(实际发出的消息)与转写文本(前序轮次的展示累积)
    private(set) var history: [[String: String]] = []
    private var transcript = ""
    private var finished = false
    private let provider: LLMProvider

    init(provider: LLMProvider, accent: NSColor, theme: PanelTheme) {
        self.provider = provider
        retryButton = ClosureButton(title: "") { }
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

        statusLabel.stringValue = provider.model
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 13).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 13).isActive = true

        (retryButton as? ClosureButton).map { _ in }
        retryButton.image = NSImage(systemSymbolName: "arrow.clockwise",
                                    accessibilityDescription: L10n.t("重试", "Retry"))
        retryButton.imagePosition = .imageOnly
        retryButton.isBordered = false
        retryButton.contentTintColor = .secondaryLabelColor
        retryButton.toolTip = L10n.t("重新请求", "Retry request")
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let copyButton = ClosureButton(title: "") { [weak self] in
            guard let self else { return }
            self.onCopy?(self.displayed)
        }
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc",
                                   accessibilityDescription: L10n.t("复制译文", "Copy result"))
        copyButton.imagePosition = .imageOnly
        copyButton.isBordered = false
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = L10n.t("复制译文", "Copy result")
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let speakButton = ClosureButton(title: "") { [weak self] in
            guard let self else { return }
            self.onSpeak?(self.displayed)
        }
        speakButton.image = NSImage(systemSymbolName: "speaker.wave.2",
                                    accessibilityDescription: L10n.t("朗读译文", "Speak result"))
        speakButton.imagePosition = .imageOnly
        speakButton.isBordered = false
        speakButton.contentTintColor = .secondaryLabelColor
        speakButton.toolTip = L10n.t("朗读译文", "Speak result")
        speakButton.translatesAutoresizingMaskIntoConstraints = false
        speakButton.widthAnchor.constraint(equalToConstant: 22).isActive = true

        bodyField.font = .systemFont(ofSize: 13)
        bodyField.textColor = .labelColor
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 输入模式的待机占位:列表照常显示 provider(状态栏保留模型名),但不发请求
    func showIdle(_ hint: String) {
        bodyField.textColor = .secondaryLabelColor
        bodyField.stringValue = hint
    }

    func beginLoading() {
        text = ""
        finished = false
        decisionBox?.removeFromSuperview()
        decisionBox = nil
        bodyField.stringValue = ""
        bodyField.textColor = .labelColor
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.stringValue = L10n.t("请求中…", "Requesting…")
        spinner.startAnimation(nil)
    }

    /// #16 ask 模式:正文显示提示,下面给出三个选择按钮
    func showSensitiveDecision(summary: String,
                               onChoice: @escaping (SensitiveDecision) -> Void) {
        finished = true
        spinner.stopAnimation(nil)
        statusLabel.stringValue = L10n.t("等待确认", "Needs confirmation")
        statusLabel.textColor = .systemOrange
        bodyField.textColor = .secondaryLabelColor
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
    }

    /// 开始一轮追问:上一轮回答并入转写,再追加提问行
    func beginFollowup(_ question: String) {
        let answer = displayed
        if !answer.isEmpty { transcript += answer + "\n\n" }
        transcript += "↳ \(question)\n\n"
        text = ""
        decisionBox?.removeFromSuperview()
        decisionBox = nil
        finished = false
        bodyField.stringValue = transcript
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.stringValue = L10n.t("追问中…", "Following up…")
        spinner.startAnimation(nil)
    }

    /// 一轮回答完成:assistant 消息入历史
    func completeTurn() {
        history.append(["role": "assistant", "content": text])
    }

    /// 组装追问请求:system + 最近 12 条 + 新问题;超出字符上限从旧轮次丢弃
    func followupMessages(question: String, maxChars: Int) -> [[String: String]] {
        let sys = history.first { $0["role"] == "system" }
        var rest = history.filter { $0["role"] != "system" }
        if rest.count > 12 { rest = Array(rest.suffix(12)) }
        func total() -> Int {
            rest.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
                + (sys?["content"]?.count ?? 0) + question.count
        }
        while total() > maxChars && rest.count > 2 { rest.removeFirst(2) }
        var msgs = sys.map { [$0] } ?? []
        msgs += rest
        msgs.append(["role": "user", "content": question])
        return msgs
    }

    func finish() {
        finished = true
        spinner.stopAnimation(nil)
        if text.isEmpty {
            statusLabel.stringValue = L10n.t("没有返回内容", "Empty response")
        } else {
            statusLabel.textColor = .tertiaryLabelColor
            statusLabel.stringValue = L10n.t("完成", "Done")
        }
    }

    func fail(_ message: String) {
        finished = true
        spinner.stopAnimation(nil)
        statusLabel.stringValue = L10n.t("失败", "Failed")
        statusLabel.textColor = .systemRed
        if text.isEmpty { bodyField.stringValue = message }
        bodyField.textColor = text.isEmpty ? .systemRed : .labelColor
    }

    func cancel() {
        task?.cancel()
        task = nil
        spinner.stopAnimation(nil)
    }

    @objc private func retryTapped() { onRetry?() }
}
