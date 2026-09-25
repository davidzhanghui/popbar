import Cocoa

/// #3 「工具条」区块:勾选显示哪些动作、拖拽排序、上下文按钮位置、最大可见数。
/// 改动即时写回 config.json(与偏好设置其它项一致,不需要点保存)。
final class ToolbarPrefsCard: NSBox, NSTableViewDataSource, NSTableViewDelegate {
    private var rows: [(id: String, title: String, symbol: String, visible: Bool)] = []
    private let table = NSTableView()
    private let dragType = NSPasteboard.PasteboardType("popbar.toolbar.row")
    private var seg: NSSegmentedControl?
    private var stepper: NSStepper?
    private var stepLabel: NSTextField?

    init() {
        super.init(frame: .zero)
        boxType = .custom
        cornerRadius = 10
        borderWidth = 1
        build()
        reloadRows()
        syncFooter()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let t = PanelTheme(dark: dark)
        borderColor = t.surfaceBorder
        fillColor = t.surface
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyTheme() }

    private func build() {
        let col = NSStackView()
        col.orientation = .vertical
        col.spacing = 0
        col.translatesAutoresizingMaskIntoConstraints = false

        // 表头
        let header = rowBar(title: L10n.t("动作与排序(拖拽调整)", "Actions (drag to reorder)"),
                            trailing: nil)
        col.addArrangedSubview(header)
        col.addArrangedSubview(sep())

        // 表格
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let visCol = NSTableColumn(identifier: .init("vis"))
        visCol.width = 34
        visCol.title = ""
        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = L10n.t("动作", "Action")
        table.addTableColumn(visCol)
        table.addTableColumn(nameCol)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([dragType])
        table.usesAutomaticRowHeights = false
        scroll.documentView = table
        col.addArrangedSubview(scroll)
        col.addArrangedSubview(sep())

        // 底部:上下文按钮位置 + 最多显示 + 恢复默认
        let seg = NSSegmentedControl(labels: [L10n.t("上下文靠后", "Ctx back"),
                                              L10n.t("编辑组后", "After edit"),
                                              L10n.t("上下文靠前", "Ctx front")],
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(segChanged))
        seg.controlSize = .small
        // 原生 toolTip 在 accessory 应用的窗口里不弹,改用 BarTooltip(与浮动条同款)
        seg.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        self.seg = seg
        let stepper = NSStepper()
        stepper.minValue = 4
        stepper.maxValue = 24
        stepper.increment = 1
        stepper.controlSize = .small
        stepper.target = self
        stepper.action = #selector(stepChanged)
        self.stepper = stepper
        let stepLabel = NSTextField(labelWithString: "")
        stepLabel.font = .systemFont(ofSize: 11)
        stepLabel.textColor = .secondaryLabelColor
        self.stepLabel = stepLabel
        let reset = ClosureButton(title: L10n.t("恢复默认", "Reset")) { [weak self] in
            self?.reset()
        }
        reset.isBordered = false
        reset.font = .systemFont(ofSize: 11)
        reset.contentTintColor = .secondaryLabelColor

        let bottom = NSStackView(views: [seg, NSView(), stepLabel, stepper, reset])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 8
        bottom.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        bottom.setContentHuggingPriority(.defaultLow, for: .horizontal)
        col.addArrangedSubview(bottom)

        contentViewMargins = .zero
        let host = NSView()
        contentView = host
        host.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            col.topAnchor.constraint(equalTo: host.topAnchor),
            col.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    private func rowBar(title: String, trailing: NSView?) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = .secondaryLabelColor
        var views: [NSView] = [l]
        if let trailing {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            views += [spacer, trailing]
        }
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 6, right: 14)
        return r
    }

    private func sep() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    // MARK: - 数据

    /// 用一段普通文本构造上下文,列出全部可排序动作(ctx.* 不参与排序)
    private func allActions() -> [BarAction] {
        let ctx = SourceContext(text: "example text", origin: .selection)
        return ActionRegistry.actions(for: ctx).filter { !$0.id.hasPrefix("ctx.") }
    }

    private func reloadRows() {
        let c = ConfigStore.shared.config
        let all = allActions()
        if c.toolbar.items.isEmpty {
            let order = BuiltinActions.defaultOrder
            rows = all.sorted {
                (order.firstIndex(of: $0.id) ?? Int.max, $0.id)
                    < (order.firstIndex(of: $1.id) ?? Int.max, $1.id)
            }.map { ($0.id, $0.title, $0.symbol, true) }
            // 与工具条一致:Dev 固定在最右
            if let i = rows.firstIndex(where: { $0.0 == "builtin.devtools" }) {
                rows.append(rows.remove(at: i))
            }
        } else {
            var list: [(String, String, String, Bool)] = []
            for item in c.toolbar.items {
                if let a = all.first(where: { $0.id == item.id }) {
                    list.append((a.id, a.title, a.symbol, item.visible))
                }
            }
            for a in all where !list.contains(where: { $0.0 == a.id }) {
                list.append((a.id, a.title, a.symbol, false))
            }
            rows = list
        }
        table.reloadData()
    }

    private func syncFooter() {
        let c = ConfigStore.shared.config
        switch c.toolbar.contextPosition {
        case "back": seg?.selectedSegment = 0
        case "front": seg?.selectedSegment = 2
        default: seg?.selectedSegment = 1
        }
        stepper?.integerValue = c.toolbar.maxVisible
        stepLabel?.stringValue = L10n.t("最多显示", "Max") + " \(c.toolbar.maxVisible)"
    }

    private func save() {
        var c = ConfigStore.shared.config
        c.toolbar.items = rows.map { ToolbarItem(id: $0.id, visible: $0.visible) }
        try? ConfigStore.shared.save(c)
    }

    // MARK: - 分段控件悬停提示(BarTooltip,悬停 0.35s 后显示)

    private var segTips: [String] {
        [L10n.t("上下文识别按钮(URL/邮箱/算式等)排在工具条最右端",
                "Context buttons (URL/email/calc…) go to the far right"),
         L10n.t("上下文识别按钮插在编辑组(复制/剪切/大小写)之后",
                "Context buttons are inserted after the edit group"),
         L10n.t("上下文识别按钮排在工具条最左端",
                "Context buttons go to the far left")]
    }

    override func mouseMoved(with event: NSEvent) {
        guard let seg, seg.segmentCount > 0 else { return }
        let p = seg.convert(event.locationInWindow, from: nil)
        guard seg.bounds.contains(p) else { BarTooltip.shared.hide(); return }
        let w = seg.bounds.width / CGFloat(seg.segmentCount)
        let i = min(seg.segmentCount - 1, max(0, Int(p.x / max(1, w))))
        BarTooltip.shared.show(segTips[i], above: seg, after: 0.35)
    }

    override func mouseExited(with event: NSEvent) { BarTooltip.shared.hide() }

    // MARK: - 控件回调

    @objc private func segChanged() {
        var c = ConfigStore.shared.config
        switch seg?.selectedSegment {
        case 0: c.toolbar.contextPosition = "back"
        case 2: c.toolbar.contextPosition = "front"
        default: c.toolbar.contextPosition = "afterEdit"
        }
        try? ConfigStore.shared.save(c)
    }

    @objc private func stepChanged() {
        var c = ConfigStore.shared.config
        c.toolbar.maxVisible = stepper?.integerValue ?? c.toolbar.maxVisible
        stepLabel?.stringValue = L10n.t("最多显示", "Max") + " \(c.toolbar.maxVisible)"
        try? ConfigStore.shared.save(c)
    }

    private func reset() {
        var c = ConfigStore.shared.config
        c.toolbar = ToolbarConfig()
        try? ConfigStore.shared.save(c)
        reloadRows()
        syncFooter()
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if tableColumn?.identifier.rawValue == "vis" {
            let check = NSButton(checkboxWithTitle: "", target: self,
                                 action: #selector(visToggled(_:)))
            check.tag = row
            check.state = rows[row].visible ? .on : .off
            check.controlSize = .small
            return check
        }
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        let iv = NSImageView(image: NSImage(systemSymbolName: rows[row].symbol,
                                            accessibilityDescription: nil) ?? NSImage())
        iv.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        iv.contentTintColor = .secondaryLabelColor
        let l = NSTextField(labelWithString: rows[row].title)
        l.font = .systemFont(ofSize: 12)
        l.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(iv)
        stack.addArrangedSubview(l)
        return stack
    }

    @objc private func visToggled(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].visible = sender.state == .on
        save()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(rows[row].id, forType: dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation)
        -> NSDragOperation {
        op == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let str = info.draggingPasteboard.string(forType: dragType),
              let from = rows.firstIndex(where: { $0.id == str }) else { return false }
        let item = rows.remove(at: from)
        let to = from < row ? row - 1 : row
        rows.insert(item, at: max(0, min(to, rows.count)))
        tableView.reloadData()
        save()
        return true
    }
}

/// #2 「应用规则」区块:按 App 禁用或限定动作。
final class AppRulesPrefsCard: NSBox, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var rules: [AppRule] = []

    init() {
        super.init(frame: .zero)
        boxType = .custom
        cornerRadius = 10
        borderWidth = 1
        build()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let t = PanelTheme(dark: dark)
        borderColor = t.surfaceBorder
        fillColor = t.surface
    }

    private func build() {
        let col = NSStackView()
        col.orientation = .vertical
        col.spacing = 0
        col.translatesAutoresizingMaskIntoConstraints = false

        // 表头:说明 + +/−
        let add = ClosureButton(title: "＋") { [weak self] in self?.addApp() }
        add.isBordered = false
        add.font = .systemFont(ofSize: 12, weight: .medium)
        let del = ClosureButton(title: "－") { [weak self] in self?.removeSelected() }
        del.isBordered = false
        del.font = .systemFont(ofSize: 12, weight: .medium)
        let hint = NSTextField(labelWithString: L10n.t("在这些应用里禁用或限定弹条",
                                                     "Disable or restrict the bar per app"))
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = .secondaryLabelColor
        let header = NSStackView(views: [hint, NSView(), add, del])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 6, right: 14)
        col.addArrangedSubview(header)
        col.addArrangedSubview(sep())

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        let nameCol = NSTableColumn(identifier: .init("name"))
        let modeCol = NSTableColumn(identifier: .init("mode"))
        modeCol.width = 130
        table.addTableColumn(nameCol)
        table.addTableColumn(modeCol)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        col.addArrangedSubview(scroll)

        contentViewMargins = .zero
        let host = NSView()
        contentView = host
        host.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            col.topAnchor.constraint(equalTo: host.topAnchor),
            col.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    private func sep() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    private func reload() {
        rules = ConfigStore.shared.config.appRules
        table.reloadData()
    }

    private func save() {
        var c = ConfigStore.shared.config
        c.appRules = rules
        try? ConfigStore.shared.save(c)
    }

    /// 「+」:列出正在运行的普通应用供选择
    private func addApp() {
        let menu = NSMenu()
        let existing = Set(rules.map { $0.bundleID })
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .filter { !existing.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in apps {
            let mi = NSMenuItem(title: app.localizedName ?? app.bundleIdentifier!,
                                action: #selector(pickApp(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = app
            if let icon = app.icon { icon.size = NSSize(width: 16, height: 16); mi.image = icon }
            menu.addItem(mi)
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: L10n.t("没有其他运行中的应用", "No other running apps"),
                                    action: nil, keyEquivalent: ""))
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func pickApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication,
              let bid = app.bundleIdentifier else { return }
        rules.append(AppRule(bundleID: bid, name: app.localizedName ?? bid, mode: "disabled"))
        save()
        table.reloadData()
    }

    private func removeSelected() {
        let i = table.selectedRow
        guard rules.indices.contains(i) else { return }
        rules.remove(at: i)
        save()
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rules.indices.contains(row) else { return nil }
        let rule = rules[row]
        if tableColumn?.identifier.rawValue == "name" {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
            let name = NSTextField(labelWithString:
                rule.name.isEmpty ? rule.bundleID : rule.name)
            name.font = .systemFont(ofSize: 12)
            let sub = NSTextField(labelWithString: rule.bundleID)
            sub.font = .systemFont(ofSize: 9)
            sub.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(name)
            stack.addArrangedSubview(sub)
            return stack
        }
        let seg = NSSegmentedControl(labels: [L10n.t("禁用", "Off"), L10n.t("限定", "Custom")],
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(modeChanged(_:)))
        seg.controlSize = .small
        seg.tag = row
        seg.selectedSegment = rule.mode == "custom" ? 1 : 0
        return seg
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        guard rules.indices.contains(sender.tag) else { return }
        rules[sender.tag].mode = sender.selectedSegment == 1 ? "custom" : "disabled"
        save()
    }
}
