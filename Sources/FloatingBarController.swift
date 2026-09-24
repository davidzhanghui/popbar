import Cocoa
import AVFoundation

/// 浮动工具条:无边框 NSPanel + 毛玻璃背景 + 上下文动作按钮
final class FloatingBarController: NSObject {
    static let shared = FloatingBarController()

    private var panel: NSPanel?
    private var currentText = ""
    private var calcResult: String?
    private let speech = AVSpeechSynthesizer()

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect { panel?.frame ?? .zero }
    var windowID: Int { panel?.windowNumber ?? 0 }

    /// 仅截图工具用:强制指定浅色/深色外观
    func setAppearance(_ name: NSAppearance.Name) {
        panel?.appearance = NSAppearance(named: name)
    }

    private struct Item {
        let symbol: String
        let tip: String
        let color: NSColor
        let action: Selector
    }

    // MARK: - Show / Hide

    func show(text: String, anchor: CGRect?) {
        currentText = text
        calcResult = nil
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var items = [
            Item(symbol: "doc.on.doc",       tip: "复制",               color: .systemBlue,   action: #selector(copyText)),
            Item(symbol: "scissors",         tip: "剪切",               color: .systemOrange, action: #selector(cutText)),
            Item(symbol: "doc.on.clipboard", tip: "粘贴",               color: .systemGreen,  action: #selector(pasteText)),
            Item(symbol: "textformat",       tip: "大写/小写转换",       color: .systemPurple, action: #selector(toggleCase)),
            Item(symbol: "wand.and.stars",   tip: "清理换行与多余空格",  color: .systemTeal,   action: #selector(cleanText)),
        ]
        if isURLLike(t) {
            items.append(Item(symbol: "link", tip: "打开链接", color: .systemIndigo, action: #selector(openLink)))
        }
        if isEmail(t) {
            items.append(Item(symbol: "envelope", tip: "发邮件", color: .systemCyan, action: #selector(sendMail)))
        }
        if let r = evaluate(t) {
            calcResult = r
            items.append(Item(symbol: "equal.circle", tip: "复制结果 \(r)", color: .systemRed, action: #selector(copyCalc)))
        }
        items.append(contentsOf: [
            Item(symbol: "magnifyingglass",       tip: "Google 搜索", color: NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1), action: #selector(search)),
            Item(symbol: "pawprint.fill",         tip: "百度搜索",    color: NSColor(srgbRed: 0.16, green: 0.39, blue: 0.88, alpha: 1), action: #selector(searchBaidu)),
            Item(symbol: "globe",                 tip: "翻译",        color: .systemIndigo, action: #selector(translate)),
            Item(symbol: "b.circle.fill",         tip: "Bob 翻译",    color: NSColor(srgbRed: 0.0, green: 0.60, blue: 0.95, alpha: 1), action: #selector(bobTranslate)),
            Item(symbol: "character.book.closed", tip: "词典",        color: .systemBrown,  action: #selector(lookupDict)),
            Item(symbol: "speaker.wave.2.fill",   tip: "朗读/停止",   color: .systemPink,   action: #selector(speak)),
            Item(symbol: "number",                tip: "字数统计",    color: .systemGray,   action: #selector(showStats)),
        ])

        // ---- 构建 UI ----
        let stack = NSStackView(views: items.map(makeButton))
        stack.orientation = .horizontal
        stack.spacing = 4
        let fit = stack.fittingSize
        let pad: CGFloat = 8
        let size = CGSize(width: fit.width + pad * 2, height: fit.height + pad)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        stack.frame = NSRect(x: pad, y: pad / 2, width: fit.width, height: fit.height)
        effect.addSubview(stack)

        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.acceptsMouseMovedEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel = p
        }
        panel?.contentView = effect
        panel?.setContentSize(size)

        // ---- 定位:优先放在选区上方,放不下则放下方 ----
        var origin: CGPoint
        if let a = anchor {
            origin = CGPoint(x: a.midX - size.width / 2, y: a.maxY + 6)
        } else {
            let m = NSEvent.mouseLocation
            origin = CGPoint(x: m.x - size.width / 2, y: m.y + 12)
        }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) })
            ?? NSScreen.main ?? NSScreen.screens.first
        if let f = screen?.visibleFrame {
            if origin.y + size.height > f.maxY {
                origin.y = anchor.map { $0.minY - size.height - 6 } ?? (f.maxY - size.height - 4)
            }
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - size.height - 4)
        }
        panel?.setFrameOrigin(origin)
        panel?.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - 动作

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentText, forType: .string)
        hide()
    }

    @objc private func cutText() {
        hide()
        Actions.postKeyCombo(key: 7)   // kVK_ANSI_X
    }

    @objc private func pasteText() {
        hide()
        Actions.postKeyCombo(key: 9)   // kVK_ANSI_V
    }

    @objc private func search() {
        openURL("https://www.google.com/search?q=\(enc(currentText))")
    }

    @objc private func searchBaidu() {
        openURL("https://www.baidu.com/s?wd=\(enc(currentText))")
    }

    @objc private func lookupDict() {
        let w = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        openURL("dict://\(enc(w))")
    }

    @objc private func speak() {
        if speech.isSpeaking {
            speech.stopSpeaking(at: .immediate)
            hide()
            return
        }
        let utt = AVSpeechUtterance(string: currentText)
        if currentText.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil {
            utt.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        speech.speak(utt)
        hide()
    }

    @objc private func bobTranslate() {
        hide()
        ensureBobRunning {
            // ⌥D —— Bob 的"划词翻译"快捷键,需与 Bob 偏好设置一致
            Actions.postHotkey(key: 2, modifierKey: 58, flags: .maskAlternate)
        }
    }

    /// Bob 未运行时先拉起,等它注册好全局热键再发 ⌥D
    private func ensureBobRunning(_ block: @escaping () -> Void) {
        let bundleID = "com.hezongyidev.Bob"
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID
        }
        if running { block(); return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            showInfo("未安装 Bob.app,请先安装")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] app, err in
            DispatchQueue.main.async {
                if app != nil && err == nil {
                    // 等 Bob 完成启动并注册全局热键
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { block() }
                } else {
                    self?.showInfo("Bob 启动失败")
                }
            }
        }
    }

    @objc private func showStats() {
        let chars = currentText.count
        let words = currentText.split { $0.isWhitespace }.count
        showInfo("字符 \(chars) · 词 \(words)")
    }

    @objc private func toggleCase() {
        let t = currentText
        replaceSelection(with: t == t.uppercased() ? t.lowercased() : t.uppercased())
    }

    @objc private func cleanText() {
        var t = currentText
        t = t.replacingOccurrences(of: "\\s*\\n\\s*", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        replaceSelection(with: t.trimmingCharacters(in: .whitespaces))
    }

    /// 就地替换选中文本:备份剪贴板 → 写入新文本 → Cmd+V → 延时还原剪贴板
    private func replaceSelection(with newText: String) {
        let pb = NSPasteboard.general
        let backup = SelectionService.snapshotPasteboard(pb)
        pb.clearContents()
        pb.setString(newText, forType: .string)
        hide()
        Actions.postKeyCombo(key: 9)   // kVK_ANSI_V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            SelectionService.restorePasteboard(pb, backup)
        }
    }

    /// 把弹条内容临时换成一行文字(字数统计等),几秒后自动隐藏
    private func showInfo(_ info: String) {
        guard let panel else { return }
        let label = NSTextField(labelWithString: info)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        let fit = label.fittingSize
        let size = CGSize(width: fit.width + 28, height: 30)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        label.frame = NSRect(x: 14, y: (size.height - fit.height) / 2,
                             width: fit.width, height: fit.height)
        effect.addSubview(label)

        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.contentView = effect
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: center.x - size.width / 2,
                                     y: center.y - size.height / 2))
        panel.orderFront(nil)   // hide() 之后调 showInfo 时也要能重新显示
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.hide()
        }
    }

    @objc private func translate() {
        let hasCJK = currentText.range(
            of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil
        let tl = hasCJK ? "en" : "zh-CN"
        openURL("https://translate.google.com/?sl=auto&tl=\(tl)&text=\(enc(currentText))")
    }

    @objc private func openLink() {
        var s = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
        hide()
    }

    @objc private func sendMail() {
        openURL("mailto:\(currentText.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    @objc private func copyCalc() {
        guard let r = calcResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r, forType: .string)
        hide()
    }

    // MARK: - 工具

    private func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
        hide()
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    private func makeButton(_ item: Item) -> NSButton {
        let img = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tip)
        let b = BarButton(image: img ?? NSImage(), target: self, action: item.action)
        b.accentColor = item.color
        b.contentTintColor = item.color
        b.isBordered = false
        b.toolTip = item.tip
        b.imageScaling = .scaleProportionallyDown
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    private func isURLLike(_ s: String) -> Bool {
        s.range(of: "^(https?://|www\\.)\\S+$", options: [.regularExpression, .caseInsensitive]) != nil
            || s.range(of: "^[a-z0-9.-]+\\.[a-z]{2,}(/\\S*)?$",
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func isEmail(_ s: String) -> Bool {
        s.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil
    }

    private func evaluate(_ s: String) -> String? {
        guard s.count <= 200,
              s.range(of: "^[0-9+\\-*/().%\\s]+$", options: .regularExpression) != nil,
              s.range(of: "[+\\-*/]", options: .regularExpression) != nil,
              s.range(of: "\\d", options: .regularExpression) != nil else { return nil }
        var p = ExprParser(s)
        guard let d = p.parse(), d.isFinite else { return nil }
        return d == d.rounded() && abs(d) < 1e15
            ? String(format: "%.0f", d)
            : String(format: "%g", d)
    }
}

/// 四则运算解析器(替代 NSExpression,避免 "1/0" 这类输入抛 ObjC 异常)
private struct ExprParser {
    private let s: [Character]
    private var i = 0

    init(_ str: String) { s = Array(str) }

    mutating func parse() -> Double? {
        guard let v = expr() else { return nil }
        ws()
        return i == s.count ? v : nil
    }

    private mutating func ws() {
        while i < s.count && s[i] == " " { i += 1 }
    }

    private mutating func expr() -> Double? {
        guard var v = term() else { return nil }
        while true {
            ws()
            guard i < s.count, s[i] == "+" || s[i] == "-" else { return v }
            let add = s[i] == "+"
            i += 1
            guard let r = term() else { return nil }
            v = add ? v + r : v - r
        }
    }

    private mutating func term() -> Double? {
        guard var v = factor() else { return nil }
        while true {
            ws()
            guard i < s.count, s[i] == "*" || s[i] == "/" || s[i] == "%" else { return v }
            let op = s[i]
            i += 1
            guard let r = factor() else { return nil }
            switch op {
            case "*": v *= r
            case "/": if r == 0 { return nil }; v /= r
            default:  if r == 0 { return nil }; v = v.truncatingRemainder(dividingBy: r)
            }
        }
    }

    private mutating func factor() -> Double? {
        ws()
        guard i < s.count else { return nil }
        let c = s[i]
        if c == "-" { i += 1; return factor().map { -$0 } }
        if c == "+" { i += 1; return factor() }
        if c == "(" {
            i += 1
            guard let v = expr() else { return nil }
            ws()
            guard i < s.count, s[i] == ")" else { return nil }
            i += 1
            return v
        }
        var j = i, hasDot = false
        while j < s.count {
            if s[j].isNumber { j += 1 }
            else if s[j] == "." && !hasDot { hasDot = true; j += 1 }
            else { break }
        }
        guard j > i else { return nil }
        let num = Double(String(s[i..<j]))
        i = j
        return num
    }
}

/// 支持悬停高亮的图标按钮:
/// mouseEntered 时显示圆角淡色底(取按钮主题色) + 手型光标。
/// .activeAlways 很关键——App 是 accessory 且面板不抢焦点,普通 tracking 不会生效。
private final class BarButton: NSButton {
    var accentColor: NSColor = .labelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    init(image: NSImage, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.image = image
        self.target = target
        self.action = action
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = 6
        setButtonType(.momentaryPushIn)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = accentColor.withAlphaComponent(0.18).cgColor
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = .clear
        NSCursor.pop()
    }
}
