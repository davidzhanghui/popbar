import Cocoa

/// 「AI 翻译设置」窗口:左侧 provider 列表,右侧编辑表单,下方通用设置。
/// 编辑的是一份草稿,点「保存」(⌘S)才写回 config.json;磁盘被外部修改时自动同步。
final class SettingsWindowController: NSObject, NSWindowDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate,
                                      NSTextFieldDelegate, NSTextViewDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var draft = PopBarConfig()
    private var selected = -1
    private var testTask: Task<Void, Never>?

    // 列表
    private let table = NSTableView()
    private let removeButton = NSButton()
    // 表单
    private let formContent = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "点左下角「+」添加一个 provider")
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let modelField = NSTextField()
    private let keySecure = NSSecureTextField()
    private let keyPlain = NSTextField()
    private let revealButton = NSButton()
    private let keyHint = NSTextField(labelWithString: "")
    private let thinkingPopup = NSPopUpButton()
    private let thinkingModes = ["default", "on", "off"]   // 默认设置 / 启用思考 / 禁用思考
    private let enabledCheck = NSButton(checkboxWithTitle: "启用(参与翻译)", target: nil, action: nil)
    private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let testLabel = NSTextField(labelWithString: "")
    // 自定义提示词(角色设定 + 用户指令模板,支持 $query.text 等变量)
    private let customPromptCheck = NSButton(checkboxWithTitle: "自定义提示词(不勾选则按翻译处理)",
                                           target: nil, action: nil)
    private let promptSection = NSStackView()
    private let sysPromptView = NSTextView()
    private let usrPromptView = NSTextView()
    private var promptRow: NSGridRow?
    // 通用
    private let sourcePopup = NSPopUpButton()
    private let targetPopup = NSPopUpButton()
    private let timeoutField = NSTextField()
    private let maxCharsField = NSTextField()
    private let temperatureField = NSTextField()
    // 底栏
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let revertButton = NSButton(title: "还原", target: nil, action: nil)

    private let languages: [(String, String, String)] = [
        ("auto", "自动", "Auto"), ("zh-CN", "中文简体", "Simplified Chinese"),
        ("en", "English", "English"), ("ja", "日本語", "Japanese"), ("ko", "한국어", "Korean"),
    ]

    private let presets: [LLMProvider] = [
        LLMProvider(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1",
                    model: "deepseek-chat", apiKey: "", enabled: true),
        LLMProvider(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1",
                    model: "deepseek-ai/DeepSeek-V3", apiKey: "", enabled: true),
        LLMProvider(name: "OpenAI", baseURL: "https://api.openai.com/v1",
                    model: "gpt-4o-mini", apiKey: "", enabled: true),
        LLMProvider(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                    model: "openai/gpt-4o-mini", apiKey: "", enabled: true),
        LLMProvider(name: "Ollama(本地)", baseURL: "http://127.0.0.1:11434/v1",
                    model: "qwen2.5:7b", apiKey: "ollama", enabled: true),
    ]

    // 与翻译面板同一套配色;窗口常驻,用动态颜色跟随系统明暗实时切换
    private let lightTheme = PanelTheme(dark: false)
    private let darkTheme = PanelTheme(dark: true)
    private func dyn(_ l: NSColor, _ d: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l }
    }
    private var surfaceColor: NSColor { dyn(lightTheme.surface, darkTheme.surface) }
    private var borderTint: NSColor { dyn(lightTheme.surfaceBorder, darkTheme.surfaceBorder) }
    private var accentText: NSColor { dyn(lightTheme.brandText, darkTheme.brandText) }

    var isVisible: Bool { window?.isVisible ?? false }
    var frame: CGRect { window?.frame ?? .zero }

    private var isDirty: Bool { draft != ConfigStore.shared.config }

    // MARK: - 双语

    /// 构建期注册的本地化闭包;语言切换时统一重放,不用重建窗口
    private var relocalizers: [() -> Void] = []
    private var wasEnglish = L10n.isEnglish

    private func loc(_ zh: String, _ en: String, _ apply: @escaping (String) -> Void) {
        apply(L10n.t(zh, en))
        relocalizers.append { apply(L10n.t(zh, en)) }
    }

    /// 语言切换:重放所有文案、刷新列表行与 popup 选项
    private func relocalize() {
        for r in relocalizers { r() }
        table.reloadData()
        updateKeyHint()
    }

    /// popup 的选项文案跟随语言,刷新时保持选中项
    private func localizePopup(_ popup: NSPopUpButton, _ titles: [(String, String)]) {
        let apply = {
            let sel = max(0, popup.indexOfSelectedItem)
            popup.removeAllItems()
            popup.addItems(withTitles: titles.map { L10n.t($0.0, $0.1) })
            popup.selectItem(at: min(sel, titles.count - 1))
        }
        apply()
        relocalizers.append(apply)
    }

    // MARK: - 显示

    func show() {
        if window == nil {
            buildWindow()
            NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                                   name: ConfigStore.didChange, object: nil)
        }
        if !isVisible || !isDirty { loadDraft(from: ConfigStore.shared.config) }
        showLoadErrorIfNeeded()
        TranslationPanelController.shared.close()
        NSApp.activateForUI()
        window?.makeKeyAndOrderFront(nil)
    }

    private func loadDraft(from config: PopBarConfig) {
        draft = config
        selected = draft.providers.isEmpty ? -1 : min(max(selected, 0), draft.providers.count - 1)
        table.reloadData()
        if selected >= 0 { table.selectRowIndexes([selected], byExtendingSelection: false) }
        fillForm()
        fillGeneral()
        refreshDirty()
    }

    @objc private func storeChanged() {
        guard window != nil else { return }
        // 语言偏好变了:重放所有文案(即使草稿有未保存修改也要换语言)
        if L10n.isEnglish != wasEnglish {
            wasEnglish = L10n.isEnglish
            relocalize()
        }
        if isDirty && isVisible {
            setStatus(L10n.t("config.json 已在外部修改;保存会覆盖它,点「还原」载入新内容",
                             "config.json changed on disk; saving overwrites it — Revert to reload"),
                      .systemOrange)
        } else {
            loadDraft(from: ConfigStore.shared.config)
            if isVisible {
                setStatus(L10n.t("已从磁盘重新加载", "Reloaded from disk"), .secondaryLabelColor)
            }
        }
        showLoadErrorIfNeeded()
    }

    private func showLoadErrorIfNeeded() {
        if let error = ConfigStore.shared.loadError { setStatus(error, .systemRed) }
    }

    // MARK: - 构建窗口

    private func buildWindow() {
        let w = EscClosableWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        loc("PopBar · AI 翻译设置", "PopBar · AI Translation") { w.title = $0 }
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        let root = NSView()
        // 淡紫渐变底,与翻译面板一致;动态颜色,跟随系统明暗
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

        let main = vstack(spacing: 14)
        main.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(main)
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            main.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        main.addArrangedSubview(sectionTitle("square.grid.2x2", "Provider", "Providers",
            "任何兼容 OpenAI Chat Completions 的服务;启用的 provider 会并行翻译",
            "Any OpenAI Chat Completions service; enabled providers translate in parallel"))

        let split = NSStackView(views: [buildSidebar(), buildForm()])
        split.orientation = .horizontal
        split.alignment = .top
        split.spacing = 16
        main.addArrangedSubview(split)

        main.addArrangedSubview(sectionTitle("slider.horizontal.3", "通用", "General",
            "默认语言与请求参数,对所有 provider 生效",
            "Default languages and request params, applied to all providers"))
        main.addArrangedSubview(buildGeneral())
        main.addArrangedSubview(buildBottomBar())
        for view in main.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        }

        // 宽度固定,高度按内容收紧,避免底部留白
        root.widthAnchor.constraint(equalToConstant: 780).isActive = true
        w.contentView = root
        root.layoutSubtreeIfNeeded()
        w.setContentSize(NSSize(width: 780, height: root.fittingSize.height))
        w.center()
        window = w
    }

    private func buildSidebar() -> NSView {
        let column = NSTableColumn(identifier: .init("provider"))
        column.width = 190
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 42
        table.style = .inset
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        // 行间拖拽排序(实时滑动让位)
        table.registerForDraggedTypes([ProviderRowView.pasteboardType])
        table.draggingDestinationFeedbackStyle = .gap

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let box = roundedBox(scroll, padding: 0, hugContent: true)   // 滚动视图没有固有高度,必须撑满
        box.heightAnchor.constraint(equalToConstant: 296).isActive = true

        let add = NSButton(image: NSImage(systemSymbolName: "plus",
                                          accessibilityDescription: L10n.t("添加", "Add"))!,
                           target: self, action: #selector(addTapped(_:)))
        add.bezelStyle = .smallSquare
        loc("添加 provider(可选预设)", "Add a provider (presets available)") { add.toolTip = $0 }
        removeButton.image = NSImage(systemSymbolName: "minus",
                                     accessibilityDescription: L10n.t("删除", "Remove"))
        removeButton.bezelStyle = .smallSquare
        for b in [add, removeButton] {
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        loc("删除选中的 provider", "Remove selected provider") { self.removeButton.toolTip = $0 }

        let buttons = NSStackView(views: [add, removeButton])
        buttons.spacing = 0

        let sidebar = vstack(spacing: 6)
        sidebar.addArrangedSubview(box)
        sidebar.addArrangedSubview(buttons)
        sidebar.widthAnchor.constraint(equalToConstant: 220).isActive = true
        box.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        return sidebar
    }

    private func buildForm() -> NSView {
        let fieldWidth: CGFloat = 360
        for (field, zh, en) in [(nameField, "显示名称,如 DeepSeek", "Display name, e.g. DeepSeek"),
                                (urlField, "https://api.example.com/v1", "https://api.example.com/v1"),
                                (modelField, "模型名,如 deepseek-chat", "Model, e.g. deepseek-chat"),
                                (keySecure, "sk-…", "sk-…"),
                                (keyPlain, "sk-…", "sk-…")] as [(NSTextField, String, String)] {
            loc(zh, en) { field.placeholderString = $0 }
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        }
        keySecure.widthAnchor.constraint(equalToConstant: fieldWidth - 30).isActive = true
        keyPlain.widthAnchor.constraint(equalToConstant: fieldWidth - 30).isActive = true
        keyPlain.isHidden = true

        revealButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: L10n.t("显示", "Show"))
        revealButton.bezelStyle = .inline
        revealButton.isBordered = false
        revealButton.target = self
        revealButton.action = #selector(toggleReveal)
        loc("显示 / 隐藏 API Key", "Show / hide API Key") { self.revealButton.toolTip = $0 }
        let keyRow = NSStackView(views: [keySecure, keyPlain, revealButton])
        keyRow.spacing = 6

        keyHint.font = .systemFont(ofSize: 11)
        keyHint.textColor = .secondaryLabelColor
        keyHint.lineBreakMode = .byTruncatingTail
        keyHint.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        localizePopup(thinkingPopup,
                      [("默认设置", "Default"), ("启用思考", "On"), ("禁用思考", "Off")])
        thinkingPopup.target = self
        thinkingPopup.action = #selector(thinkingChanged)

        loc("启用(参与翻译)", "Enabled (used in translation)") { self.enabledCheck.title = $0 }
        enabledCheck.target = self
        enabledCheck.action = #selector(enabledToggled)
        loc("自定义提示词(不勾选则按翻译处理)", "Custom prompts (default: translate)") {
            self.customPromptCheck.title = $0
        }
        customPromptCheck.target = self
        customPromptCheck.action = #selector(customPromptToggled)

        for tv in [sysPromptView, usrPromptView] {
            tv.isEditable = true
            tv.isRichText = false
            tv.importsGraphics = false
            tv.font = .systemFont(ofSize: 11)
            tv.textContainerInset = NSSize(width: 4, height: 4)
            tv.textContainer?.widthTracksTextView = true
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
            tv.delegate = self
        }
        promptSection.orientation = .vertical
        promptSection.alignment = .leading
        promptSection.spacing = 4
        promptSection.addArrangedSubview(hint("系统提示词(角色设定),留空则不发 system 消息",
                                              "System prompt (role); empty = no system message"))
        promptSection.addArrangedSubview(promptEditor(sysPromptView))
        promptSection.addArrangedSubview(hint("用户指令", "User prompt"))
        promptSection.addArrangedSubview(promptEditor(usrPromptView))
        let varsHint = hint(
            "变量:$query.text 原文 · $query.detectFromLang 源语言 · $query.detectToLang 目标语言(带{}花括号也认)",
            "Variables: $query.text source · $query.detectFromLang source lang · $query.detectToLang target lang ({$…} also works)")
        varsHint.maximumNumberOfLines = 2
        varsHint.lineBreakMode = .byWordWrapping
        varsHint.preferredMaxLayoutWidth = fieldWidth
        promptSection.addArrangedSubview(varsHint)
        promptSection.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        loc("测试连接", "Test") { self.testButton.title = $0 }
        testButton.target = self
        testButton.action = #selector(testTapped)
        testButton.controlSize = .small
        testLabel.font = .systemFont(ofSize: 11)
        testLabel.lineBreakMode = .byTruncatingTail
        testLabel.widthAnchor.constraint(equalToConstant: fieldWidth - 90).isActive = true
        let testRow = NSStackView(views: [testButton, testLabel])
        testRow.spacing = 8

        let grid = NSGridView(views: [
            [formLabel("名称", "Name"), nameField],
            [formLabel("Base URL", "Base URL"), urlField],
            [formLabel("模型", "Model"), modelField],
            [formLabel("API Key", "API Key"), keyRow],
            [NSGridCell.emptyContentView, keyHint],
            [formLabel("深度思考", "Thinking"), thinkingPopup],
            [NSGridCell.emptyContentView, enabledCheck],
            [NSGridCell.emptyContentView, customPromptCheck],
            [NSGridCell.emptyContentView, promptSection],
            [NSGridCell.emptyContentView, testRow],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.row(at: 4).topPadding = -4
        promptRow = grid.row(at: 8)
        promptRow?.isHidden = true

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        loc("点左下角「+」添加一个 provider", "Click + below to add a provider") {
            self.emptyLabel.stringValue = $0
        }

        formContent.orientation = .vertical
        formContent.alignment = .centerX
        formContent.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        formContent.addArrangedSubview(grid)
        formContent.addArrangedSubview(emptyLabel)

        // 表单区放进滚动视图:展开自定义提示词时内部滚动,窗口高度不变,
        // 避免动态改窗口高度引发的布局错乱
        let formScroll = NSScrollView()
        formScroll.drawsBackground = false
        formScroll.borderType = .noBorder
        formScroll.hasVerticalScroller = true
        formScroll.automaticallyAdjustsContentInsets = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        formScroll.documentView = doc
        formContent.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(formContent)
        NSLayoutConstraint.activate([
            formContent.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            formContent.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            formContent.topAnchor.constraint(equalTo: doc.topAnchor),
            formContent.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor),
        ])
        let box = roundedBox(formScroll, padding: 0, hugContent: true)
        box.heightAnchor.constraint(equalToConstant: 296).isActive = true
        return box
    }

    /// 多行提示词编辑器:带边框的可滚动 NSTextView
    private func promptEditor(_ tv: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 360).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 62).isActive = true
        return scroll
    }

    private func buildGeneral() -> NSView {
        for popup in [sourcePopup, targetPopup] {
            localizePopup(popup, languages.map { ($0.1, $0.2) })
            popup.target = self
            popup.action = #selector(generalChanged)
        }
        for (field, width) in [(timeoutField, 60), (maxCharsField, 70), (temperatureField, 60)]
            as [(NSTextField, CGFloat)] {
            field.delegate = self
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        let row1 = NSStackView(views: [formLabel("源语言", "Source"), sourcePopup,
                                       spacerFixed(18), formLabel("目标语言", "Target"), targetPopup])
        let row2 = NSStackView(views: [formLabel("超时(秒)", "Timeout (s)"), timeoutField,
                                       spacerFixed(18), formLabel("最大字符", "Max Chars"), maxCharsField,
                                       spacerFixed(18), formLabel("温度", "Temp"), temperatureField,
                                       hint("  0–2,越低越稳定", "  0–2, lower = more stable")])
        for row in [row1, row2] { row.spacing = 8; row.alignment = .firstBaseline }
        let column = vstack(spacing: 10)
        column.addArrangedSubview(row1)
        column.addArrangedSubview(row2)
        return roundedBox(column, padding: 14, hugContent: true)
    }

    private func buildBottomBar() -> NSView {
        let path = NSTextField(labelWithString: PopBarConfig.fileURL.path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        path.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        path.textColor = .tertiaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let reveal = NSButton(title: "", target: self, action: #selector(revealInFinder))
        loc("在 Finder 中显示", "Show in Finder") { reveal.title = $0 }
        reveal.bezelStyle = .inline
        reveal.controlSize = .small

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        revertButton.target = self
        revertButton.action = #selector(revertTapped)
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.bezelColor = PanelTheme.brand
        loc("保存", "Save") { self.saveButton.title = $0 }
        loc("还原", "Revert") { self.revertButton.title = $0 }
        loc("保存到 config.json (⌘S)", "Save to config.json (⌘S)") { self.saveButton.toolTip = $0 }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [path, reveal, spacer, statusLabel, revertButton, saveButton])
        bar.spacing = 8
        bar.alignment = .centerY
        return bar
    }

    // MARK: - 表单同步

    private func fillForm() {
        let has = selected >= 0 && selected < draft.providers.count
        formContent.arrangedSubviews.first?.isHidden = !has
        emptyLabel.isHidden = has
        removeButton.isEnabled = has
        testLabel.stringValue = ""
        testTask?.cancel()
        guard has else { return }
        let p = draft.providers[selected]
        nameField.stringValue = p.name
        urlField.stringValue = p.baseURL
        modelField.stringValue = p.model
        keySecure.stringValue = p.apiKey
        keyPlain.stringValue = p.apiKey
        enabledCheck.state = p.enabled ? .on : .off
        thinkingPopup.selectItem(at: max(0, thinkingModes.firstIndex(of: p.thinking ?? "default") ?? 0))
        let custom = p.systemPrompt != nil || p.userPrompt != nil
        customPromptCheck.state = custom ? .on : .off
        sysPromptView.string = p.systemPrompt ?? TranslatePrompt.customSystemTemplate
        usrPromptView.string = p.userPrompt ?? "{$query.text}"
        setPromptSectionVisible(custom)
        updateKeyHint()
    }

    private func fillGeneral() {
        sourcePopup.selectItem(at: languageIndex(draft.sourceLanguage))
        targetPopup.selectItem(at: languageIndex(draft.targetLanguage))
        timeoutField.stringValue = trim(draft.timeout)
        maxCharsField.stringValue = String(draft.maxCharacters)
        temperatureField.stringValue = trim(draft.temperature)
    }

    private func updateKeyHint() {
        guard selected >= 0 && selected < draft.providers.count else { return }
        let raw = draft.providers[selected].apiKey.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty {
            keyHint.stringValue = L10n.t("填入 API Key 后该 provider 才会参与翻译",
                                         "Fill in an API Key to enable this provider")
            keyHint.textColor = .secondaryLabelColor
        } else {
            keyHint.stringValue = L10n.t("明文保存在本机配置文件(权限 600)",
                                         "Stored in plain text in the local config file (0600)")
            keyHint.textColor = .secondaryLabelColor
        }
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        if selected >= 0 && selected < draft.providers.count {
            switch field {
            case nameField: draft.providers[selected].name = field.stringValue
            case urlField: draft.providers[selected].baseURL = field.stringValue
            case modelField: draft.providers[selected].model = field.stringValue
            case keySecure, keyPlain:
                draft.providers[selected].apiKey = field.stringValue
                (field === keySecure ? keyPlain : keySecure).stringValue = field.stringValue
                updateKeyHint()
            default: break
            }
            if [nameField, urlField, modelField, keySecure, keyPlain].contains(field) {
                reloadSelectedRow()
            }
        }
        switch field {
        case timeoutField: if let v = Double(field.stringValue) { draft.timeout = v }
        case maxCharsField: if let v = Int(field.stringValue) { draft.maxCharacters = v }
        case temperatureField: if let v = Double(field.stringValue) { draft.temperature = v }
        default: break
        }
        refreshDirty()
    }

    @objc private func enabledToggled() {
        guard selected >= 0 else { return }
        draft.providers[selected].enabled = enabledCheck.state == .on
        reloadSelectedRow()
        refreshDirty()
    }

    @objc private func thinkingChanged() {
        guard selected >= 0 else { return }
        let mode = thinkingModes[max(0, min(thinkingPopup.indexOfSelectedItem, 2))]
        draft.providers[selected].thinking = mode
        refreshDirty()
    }

    @objc private func customPromptToggled() {
        guard selected >= 0 else { return }
        let on = customPromptCheck.state == .on
        if on {
            // 首次勾选:预填默认模板,方便在翻译提示词基础上修改
            if draft.providers[selected].systemPrompt == nil
                && draft.providers[selected].userPrompt == nil {
                draft.providers[selected].systemPrompt = TranslatePrompt.customSystemTemplate
                draft.providers[selected].userPrompt = "{$query.text}"
            }
            sysPromptView.string = draft.providers[selected].systemPrompt ?? ""
            usrPromptView.string = draft.providers[selected].userPrompt ?? ""
        } else {
            draft.providers[selected].systemPrompt = nil
            draft.providers[selected].userPrompt = nil
        }
        setPromptSectionVisible(on)
        refreshDirty()
    }

    /// 展开/收起提示词编辑区(超出部分在表单区域内滚动)
    private func setPromptSectionVisible(_ visible: Bool) {
        promptRow?.isHidden = !visible
    }

    /// NSTextView 编辑回调:只在勾选状态下写回草稿(程序赋值也可能触发,避免误标脏)
    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView,
              selected >= 0, selected < draft.providers.count,
              customPromptCheck.state == .on else { return }
        if tv === sysPromptView {
            draft.providers[selected].systemPrompt = tv.string
        } else if tv === usrPromptView {
            draft.providers[selected].userPrompt = tv.string
        }
        refreshDirty()
    }

    @objc private func generalChanged() {
        draft.sourceLanguage = languages[max(0, sourcePopup.indexOfSelectedItem)].0
        draft.targetLanguage = languages[max(0, targetPopup.indexOfSelectedItem)].0
        refreshDirty()
    }

    @objc private func toggleReveal() {
        let showPlain = keyPlain.isHidden
        keyPlain.isHidden = !showPlain
        keySecure.isHidden = showPlain
        revealButton.image = NSImage(systemSymbolName: showPlain ? "eye.slash" : "eye",
                                     accessibilityDescription: nil)
    }

    private func refreshDirty() {
        saveButton.isEnabled = isDirty
        revertButton.isEnabled = isDirty
        window?.isDocumentEdited = isDirty
        if isDirty {
            setStatus(L10n.t("有未保存的修改", "Unsaved changes"), .secondaryLabelColor)
        } else if statusLabel.stringValue == L10n.t("有未保存的修改", "Unsaved changes") {
            setStatus("", .secondaryLabelColor)
        }
    }

    private func setStatus(_ text: String, _ color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }

    // MARK: - 列表

    func numberOfRows(in tableView: NSTableView) -> Int { draft.providers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ProviderRowView.id, owner: nil) as? ProviderRowView)
            ?? ProviderRowView()
        cell.configure(draft.providers[row])
        cell.onToggle = { [weak self] on in self?.toggleProvider(at: row, on: on) }
        return cell
    }

    /// 行内开关:直接改 enabled;如果改的是当前选中行,同步表单里的勾选框
    private func toggleProvider(at row: Int, on: Bool) {
        guard row >= 0 && row < draft.providers.count else { return }
        draft.providers[row].enabled = on
        if row == selected { enabledCheck.state = on ? .on : .off }
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
        refreshDirty()
    }

    // MARK: 拖拽排序(实时滑动:拖动经过时行即时让位)

    private var dragSourceRow = -1

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: ProviderRowView.pasteboardType)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        dragSourceRow = rowIndexes.first ?? -1
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragSourceRow = -1
        refreshDirty()   // 中途 Esc 取消的话,已发生的移动也算修改
    }

    /// validateDrop 在拖动过程中持续回调——在这里直接移动行,配合 moveRow 的滑动动画,
    /// 而不是只画一条落点线等松手再跳
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above, dragSourceRow >= 0 else { return [] }
        var to = row
        if dragSourceRow < to { to -= 1 }   // 往下拖越过自身,目标下标回退一格
        to = max(0, min(to, draft.providers.count - 1))
        if to != dragSourceRow {
            let from = dragSourceRow
            let moved = draft.providers.remove(at: from)
            draft.providers.insert(moved, at: to)
            tableView.beginUpdates()
            tableView.moveRow(at: from, to: to)
            tableView.endUpdates()
            // 选中高亮跟随行移动
            if selected == from { selected = to }
            else if from < selected && to >= selected { selected -= 1 }
            else if from > selected && to <= selected { selected += 1 }
            dragSourceRow = to
            if selected >= 0 { tableView.selectRowIndexes([selected], byExtendingSelection: false) }
        }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        refreshDirty()
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row != selected else { return }
        selected = row
        fillForm()
    }

    private func reloadSelectedRow() {
        guard selected >= 0 else { return }
        table.reloadData(forRowIndexes: [selected], columnIndexes: [0])
    }

    @objc private func addTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let custom = NSMenuItem(title: L10n.t("自定义…", "Custom…"),
                                action: #selector(addPreset(_:)), keyEquivalent: "")
        custom.target = self
        custom.tag = -1
        menu.addItem(custom)
        menu.addItem(.separator())
        for (i, preset) in presets.enumerated() {
            let item = NSMenuItem(title: "\(preset.name)  ·  \(preset.model)",
                                  action: #selector(addPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func addPreset(_ item: NSMenuItem) {
        let provider = item.tag >= 0 ? presets[item.tag] : .blank(index: draft.providers.count + 1)
        draft.providers.append(provider)
        selected = draft.providers.count - 1
        table.reloadData()
        table.selectRowIndexes([selected], byExtendingSelection: false)
        table.scrollRowToVisible(selected)
        fillForm()
        refreshDirty()
        window?.makeFirstResponder(item.tag >= 0 ? keySecure : nameField)
    }

    @objc private func removeTapped() {
        guard selected >= 0 && selected < draft.providers.count else { return }
        draft.providers.remove(at: selected)
        selected = min(selected, draft.providers.count - 1)
        table.reloadData()
        if selected >= 0 { table.selectRowIndexes([selected], byExtendingSelection: false) }
        fillForm()
        refreshDirty()
    }

    // MARK: - 测试连接

    @objc private func testTapped() {
        guard selected >= 0 else { return }
        testTask?.cancel()
        let provider = draft.providers[selected]
        if let problem = validate(provider, requireKey: true) {
            showTest("✕ \(problem)", .systemRed)
            return
        }
        showTest(L10n.t("连接中…", "Connecting…"), .secondaryLabelColor)
        testButton.isEnabled = false
        let started = Date()
        var got = ""
        let index = selected
        let msg = TranslatePrompt.messages(source: "auto", target: "zh-CN",
                                           text: "Hello, world.", provider: provider)
        testTask = LLMClient.stream(
            text: msg.user,
            systemPrompt: msg.system,
            provider: provider, timeout: min(draft.timeout, 20), temperature: 0) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.selected == index else { return }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                switch event {
                case .delta(let piece): got += piece
                case .done:
                    self.testButton.isEnabled = true
                    self.showTest(got.isEmpty
                                      ? L10n.t("⚠︎ 连接成功但没有返回内容", "⚠︎ Connected, empty response") + " · \(ms)ms"
                                      : L10n.t("✓ 连接成功", "✓ Connected") + " · \(ms)ms · \(got.prefix(24))",
                                  got.isEmpty ? .systemOrange : .systemGreen)
                case .failure(let message):
                    self.testButton.isEnabled = true
                    self.showTest("✕ \(message)", .systemRed)
                }
            }
        }
    }

    private func showTest(_ text: String, _ color: NSColor) {
        testLabel.stringValue = text
        testLabel.textColor = color
        testLabel.toolTip = text
    }

    // MARK: - 保存 / 还原

    @objc private func saveTapped() {
        window?.makeFirstResponder(nil)   // 提交正在编辑的字段
        if let problem = validateAll() {
            let alert = NSAlert()
            alert.messageText = L10n.t("无法保存", "Cannot Save")
            alert.informativeText = problem
            alert.alertStyle = .warning
            alert.beginSheetModal(for: window!)
            return
        }
        do {
            try ConfigStore.shared.save(draft)
            loadDraft(from: draft)   // 表单重新显示占位符后的值
            refreshDirty()
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            setStatus(L10n.t("✓ 已保存", "✓ Saved") + " \(time)", .systemGreen)
        } catch {
            setStatus(L10n.t("保存失败:", "Save failed: ") + error.localizedDescription, .systemRed)
        }
    }

    @objc private func revertTapped() {
        loadDraft(from: ConfigStore.shared.config)
        setStatus(L10n.t("已还原为磁盘上的配置", "Reverted to saved config"), .secondaryLabelColor)
    }

    @objc private func revealInFinder() {
        PopBarConfig.ensureExists()
        NSWorkspace.shared.activateFileViewerSelecting([PopBarConfig.fileURL])
    }

    private func validateAll() -> String? {
        for (i, p) in draft.providers.enumerated() where p.enabled {
            if let problem = validate(p, requireKey: false) {
                let name = p.name.isEmpty ? L10n.t("未命名", "Untitled") : p.name
                return L10n.t("第 \(i + 1) 个 provider", "Provider \(i + 1)") + "「\(name)」: \(problem)"
            }
        }
        guard let timeout = Double(timeoutField.stringValue), (5...300).contains(timeout) else {
            return L10n.t("超时需在 5–300 秒之间", "Timeout must be between 5 and 300 seconds")
        }
        guard let chars = Int(maxCharsField.stringValue), (100...50_000).contains(chars) else {
            return L10n.t("最大字符需在 100–50000 之间", "Max characters must be 100–50000")
        }
        guard let temp = Double(temperatureField.stringValue), (0...2).contains(temp) else {
            return L10n.t("温度需在 0–2 之间", "Temperature must be 0–2")
        }
        return nil
    }

    private func validate(_ p: LLMProvider, requireKey: Bool) -> String? {
        if p.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return L10n.t("名称不能为空", "Name is required")
        }
        guard let url = URL(string: p.baseURL.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !(url.host ?? "").isEmpty else {
            return L10n.t("Base URL 需要是完整的 http(s) 地址",
                          "Base URL must be a complete http(s) URL")
        }
        if p.model.trimmingCharacters(in: .whitespaces).isEmpty {
            return L10n.t("模型不能为空", "Model is required")
        }
        if requireKey && p.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return L10n.t("API Key 为空", "API Key is empty")
        }
        return nil
    }

    // MARK: - 关闭确认

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window?.makeFirstResponder(nil)
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.t("保存对 AI 翻译设置的修改吗?",
                                   "Save changes to AI Translation settings?")
        alert.informativeText = L10n.t("不保存的话,这些修改会丢失。",
                                       "Your changes will be lost if you don't save.")
        alert.addButton(withTitle: L10n.t("保存", "Save"))
        alert.addButton(withTitle: L10n.t("取消", "Cancel"))
        alert.addButton(withTitle: L10n.t("不保存", "Don't Save"))
        NSApp.activateForUI()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveTapped()
            return !isDirty
        case .alertThirdButtonReturn:
            loadDraft(from: ConfigStore.shared.config)
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        testTask?.cancel()
    }

    // MARK: - 小工具

    private func languageIndex(_ code: String) -> Int {
        languages.firstIndex { $0.0 == code } ?? 0
    }

    private func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func vstack(spacing: CGFloat) -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    private func sectionTitle(_ icon: String, _ zhTitle: String, _ enTitle: String,
                              _ zhSub: String, _ enSub: String) -> NSView {
        let iv = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil) ?? NSImage())
        iv.contentTintColor = accentText
        iv.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        let t = NSTextField(labelWithString: "")
        loc(zhTitle, enTitle) { t.stringValue = $0 }
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.textColor = accentText
        let s = hint(zhSub, enSub)
        let row = NSStackView(views: [iv, t, s])
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func hint(_ zh: String, _ en: String) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        loc(zh, en) { l.stringValue = $0 }
        return l
    }

    private func formLabel(_ zh: String, _ en: String) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.alignment = .right
        loc(zh, en) { l.stringValue = $0 }
        return l
    }

    private func spacerFixed(_ width: CGFloat) -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    /// 圆角浅底容器;NSBox 的颜色会随明暗外观自动更新
    private func roundedBox(_ content: NSView, padding: CGFloat, hugContent: Bool = false) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = borderTint
        box.fillColor = surfaceColor
        box.contentViewMargins = .zero
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let host = box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: padding),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -padding),
                content.topAnchor.constraint(equalTo: host.topAnchor, constant: padding),
                hugContent
                    ? content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -padding)
                    : content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -padding),
            ])
        }
        return box
    }
}

/// 列表行:状态点 + 名称 + 模型 + 启用开关
private final class ProviderRowView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("ProviderRow")
    static let pasteboardType = NSPasteboard.PasteboardType("dev.popbar.providerRow")

    var onToggle: ((Bool) -> Void)?

    private let dot = NSView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()

    init() {
        super.init(frame: .zero)
        identifier = ProviderRowView.id
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(toggleTapped)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [dot, text])
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(toggle)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            // 开关直接钉在行右缘,不进 stack——避免 stack 填充策略让开关跟着文本宽度走
            row.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleTapped() {
        onToggle?(toggle.state == .on)
    }

    func configure(_ p: LLMProvider) {
        name.stringValue = p.name.isEmpty ? L10n.t("未命名", "Untitled") : p.name
        toggle.state = p.enabled ? .on : .off
        let ready = !p.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !p.model.isEmpty && !p.baseURL.isEmpty
        let color: NSColor
        if !p.enabled {
            color = .tertiaryLabelColor
            detail.stringValue = L10n.t("已停用", "Disabled") + " · \(p.model)"
        } else if !ready {
            color = .systemOrange
            detail.stringValue = L10n.t("缺少 key 或模型", "Missing key or model")
        } else {
            color = .systemGreen
            detail.stringValue = p.model
        }
        dot.layer?.backgroundColor = color.cgColor
        toolTip = p.baseURL
    }
}
