import Cocoa

/// 工具条上的一个动作。内置、上下文、AI、扩展动作统一用它表示,
/// id 带命名空间(builtin.* / ctx.* / ai.* / ext.*),排序、隐藏、按应用过滤都基于 id。
struct BarAction {
    let id: String
    /// 每次构建时生成,L10n 即时生效
    let title: String
    let symbol: String          // SF Symbols 名
    let color: NSColor
    /// 色块动作等需要自定义图标的场合(M3 颜色识别)
    var swatchColor: NSColor? = nil
    /// 子菜单;非空时点击弹出菜单而不是直接执行
    var menu: ((SourceContext) -> NSMenu)? = nil
    /// 附加可用性判断(默认 true)
    var isAvailable: (SourceContext) -> Bool = { _ in true }
    let perform: (SourceContext) -> Void
}

/// 汇总各类动作来源并按配置排序/分流到主条与溢出菜单
enum ActionRegistry {
    static func actions(for ctx: SourceContext) -> [BarAction] {
        var all = BuiltinActions.all()
        all += contextualActions(for: ctx)
        all += Extensions.barActions()
        return all.filter { $0.isAvailable(ctx) }
    }

    /// 把动作分为「主条可见」和「溢出菜单」两组
    static func resolve(for ctx: SourceContext) -> (visible: [BarAction], overflow: [BarAction]) {
        let config = ConfigStore.shared.config
        var all = actions(for: ctx)

        // #2 按应用规则:custom 模式只保留列出的动作
        if let rule = config.appRule(for: ctx.bundleID), rule.mode == "custom" {
            let allowed = Set(rule.actions)
            all = all.filter { allowed.contains($0.id) }
        }

        // 上下文动作(打开链接/发邮件/复制结果/时间戳等)的位置由 contextPosition 控制
        let ctxActions = all.filter { $0.id.hasPrefix("ctx.") }
        let nonCtx = all.filter { !$0.id.hasPrefix("ctx.") }

        let items = config.toolbar.items
        var ordered: [(BarAction, Bool)]    // (action, 用户标记可见)
        if items.isEmpty {
            // 默认顺序:保持 0.1 版外观
            let order = BuiltinActions.defaultOrder
            var rest = nonCtx.sorted { a, b in
                let ia = order.firstIndex(of: a.id) ?? Int.max
                let ib = order.firstIndex(of: b.id) ?? Int.max
                return (ia, a.id) < (ib, b.id)
            }
            // Dev 工具箱固定最右(扩展之后)
            if let i = rest.firstIndex(where: { $0.id == "builtin.devtools" }) {
                rest.append(rest.remove(at: i))
            }
            ordered = rest.map { ($0, true) }
        } else {
            let indexOf = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
            let listed = nonCtx.filter { indexOf[$0.id] != nil }
                .sorted { indexOf[$0.id]! < indexOf[$1.id]! }
            // 配置里没有的新动作:追加到末尾并放入溢出菜单
            let unlisted = nonCtx.filter { indexOf[$0.id] == nil }
            let visById = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.visible) })
            ordered = listed.map { ($0, visById[$0.id] ?? true) } + unlisted.map { ($0, false) }
        }

        // #20 perApp 排序:该应用最常用的 3 个动作提前
        if config.toolbar.order == "perApp", let bid = ctx.bundleID {
            let top = UsageStats.shared.topActions(for: bid, limit: 3)
            if !top.isEmpty {
                ordered.sort { lhs, rhs in
                    let la = top.firstIndex(of: lhs.0.id) ?? Int.max
                    let lb = top.firstIndex(of: rhs.0.id) ?? Int.max
                    return (la, indexInOrdered(lhs)) < (lb, indexInOrdered(rhs))
                }
                func indexInOrdered(_ x: (BarAction, Bool)) -> Int {
                    ordered.firstIndex { $0.0.id == x.0.id } ?? Int.max
                }
            }
        }

        switch config.toolbar.contextPosition {
        case "front": ordered = ctxActions.map { ($0, true) } + ordered
        case "back":  ordered = ordered + ctxActions.map { ($0, true) }
        default:      // "afterEdit":跟在编辑组(大小写/清理)之后,与 0.1 版一致
            let idx = ordered.firstIndex { $0.0.id == "builtin.case" }
                .map { $0 + 1 } ?? min(5, ordered.count)
            ordered.insert(contentsOf: ctxActions.map { ($0, true) }, at: idx)
        }

        // Dev 排在末尾时给它预留末位,超出 maxVisible 时其他动作先进溢出菜单
        let devPinned = ordered.last.map { $0.0.id == "builtin.devtools" && $0.1 } ?? false
        let cap = devPinned ? config.toolbar.maxVisible - 1 : config.toolbar.maxVisible
        var visible: [BarAction] = []
        var overflow: [BarAction] = []
        for (action, wantsVisible) in ordered {
            if devPinned && action.id == "builtin.devtools" {
                visible.append(action)
            } else if wantsVisible && visible.count < cap {
                visible.append(action)
            } else {
                overflow.append(action)
            }
        }
        return (visible, overflow)
    }

    // MARK: - 上下文动作(ctx.*)

    /// 把识别结果映射为动作;最多 3 个上下文按钮,避免工具条膨胀
    static func contextualActions(for ctx: SourceContext) -> [BarAction] {
        Array(ContextDetector.detect(ctx.text).prefix(3)).compactMap { kind in
            switch kind {
            case .url(let u):
                return BarAction(
                    id: "ctx.openURL", title: L10n.t("打开链接", "Open Link"),
                    symbol: "link", color: .systemIndigo) { _ in
                    var s = u
                    if !s.contains("://") && !s.contains("@") { s = "https://" + s }
                    if let url = URL(string: s) { NSWorkspace.shared.open(url) }
                    FloatingBarController.shared.hide()
                }
            case .email(let e):
                return BarAction(
                    id: "ctx.mail", title: L10n.t("发邮件", "Send Email"),
                    symbol: "envelope", color: .systemCyan) { _ in
                    openMail(to: e)
                    FloatingBarController.shared.hide()
                }
            case .calc(let r):
                return BarAction(
                    id: "ctx.calc", title: L10n.t("复制结果", "Copy") + " \(r)",
                    symbol: "equal.circle", color: .systemRed) { _ in
                    PasteboardGuard.write(r)
                    FloatingBarController.shared.hide()
                }
            case .timestamp(let d):
                let str = timestampString(d)
                return BarAction(
                    id: "ctx.timestamp", title: str,
                    symbol: "clock", color: .systemMint) { _ in
                    PasteboardGuard.write(str)
                    FloatingBarController.shared.hide()
                }
            case .json:
                return BarAction(
                    id: "ctx.json", title: "JSON",
                    symbol: "curlybraces", color: .systemOrange,
                    menu: { c in
                        ContextMenu.build([
                            ContextMenu.Item(L10n.t("格式化 → 复制", "Pretty → Copy"), "doc.on.doc") {
                                if let s = jsonPretty(c.text) { PasteboardGuard.write(s) }
                            },
                            ContextMenu.Item(L10n.t("压缩 → 复制", "Minify → Copy"), "arrow.up.left.and.arrow.down.right") {
                                if let s = jsonMinified(c.text) { PasteboardGuard.write(s) }
                            },
                            ContextMenu.Item(L10n.t("格式化 → 替换原文", "Pretty → Replace"), "arrow.down.doc") {
                                if let s = jsonPretty(c.text) { TextReplacer.replaceInline(s) }
                            },
                            ContextMenu.Item(L10n.t("压缩 → 替换原文", "Minify → Replace"), "arrow.down.doc") {
                                if let s = jsonMinified(c.text) { TextReplacer.replaceInline(s) }
                            },
                        ])
                    }) { _ in }
            case .base64:
                return BarAction(
                    id: "ctx.base64", title: "Base64",
                    symbol: "number.square", color: .systemBrown,
                    menu: { c in
                        ContextMenu.build([
                            ContextMenu.Item(L10n.t("解码 → 复制", "Decode → Copy"), "lock.open") {
                                if let s = base64Decode(c.text) { PasteboardGuard.write(s) }
                            },
                            ContextMenu.Item(L10n.t("解码 → 替换原文", "Decode → Replace"), "arrow.down.doc") {
                                if let s = base64Decode(c.text) { TextReplacer.replaceInline(s) }
                            },
                            ContextMenu.Item(L10n.t("编码 → 复制", "Encode → Copy"), "lock") {
                                if let d = c.text.data(using: .utf8) {
                                    PasteboardGuard.write(d.base64EncodedString())
                                }
                            },
                            ContextMenu.Item(L10n.t("编码 → 替换原文", "Encode → Replace"), "arrow.down.doc") {
                                if let d = c.text.data(using: .utf8) {
                                    TextReplacer.replaceInline(d.base64EncodedString())
                                }
                            },
                        ])
                    }) { _ in }
            case .urlEncoded:
                return BarAction(
                    id: "ctx.urlEnc", title: "URL " + L10n.t("解码", "Decode"),
                    symbol: "link.badge.plus", color: .systemTeal,
                    menu: { c in
                        ContextMenu.build([
                            ContextMenu.Item(L10n.t("解码 → 复制", "Decode → Copy"), "doc.on.doc") {
                                if let s = c.text.removingPercentEncoding {
                                    PasteboardGuard.write(s)
                                }
                            },
                            ContextMenu.Item(L10n.t("解码 → 替换原文", "Decode → Replace"), "arrow.down.doc") {
                                if let s = c.text.removingPercentEncoding {
                                    TextReplacer.replaceInline(s)
                                }
                            },
                            ContextMenu.Item(L10n.t("编码 → 复制", "Encode → Copy"), "doc.on.doc") {
                                if let s = c.text.addingPercentEncoding(
                                    withAllowedCharacters: .urlQueryAllowed) {
                                    PasteboardGuard.write(s)
                                }
                            },
                        ])
                    }) { _ in }
            case .color(let c):
                var a = BarAction(
                    id: "ctx.color", title: "Hex",
                    symbol: "paintpalette", color: .systemPink,
                    menu: { _ in
                        ContextMenu.build([
                            ContextMenu.Item("HEX " + colorHex(c), "number") { PasteboardGuard.write(colorHex(c)) },
                            ContextMenu.Item(colorRGB(c), "eyedropper") { PasteboardGuard.write(colorRGB(c)) },
                            ContextMenu.Item(colorHSL(c), "circle.lefthalf.filled") { PasteboardGuard.write(colorHSL(c)) },
                        ])
                    }) { _ in }
                a.swatchColor = c
                return a
            case .filePath(let p):
                return BarAction(
                    id: "ctx.filePath", title: L10n.t("在 Finder 中显示", "Reveal in Finder"),
                    symbol: "folder", color: .systemOrange) { _ in
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                    FloatingBarController.shared.hide()
                }
            case .phone(let n):
                return BarAction(
                    id: "ctx.phone", title: L10n.t("呼叫", "Call"),
                    symbol: "phone", color: .systemGreen) { _ in
                        let digits = n.filter { $0.isNumber || $0 == "+" }
                        if let url = URL(string: "tel:\(digits)") { NSWorkspace.shared.open(url) }
                        FloatingBarController.shared.hide()
                    }
            case .address(let a):
                return BarAction(
                    id: "ctx.address", title: L10n.t("在地图中打开", "Open in Maps"),
                    symbol: "map", color: .systemGreen) { _ in
                        if let url = URL(string: "https://maps.apple.com/?q="
                            + (a.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) {
                            NSWorkspace.shared.open(url)
                        }
                        FloatingBarController.shared.hide()
                    }
            case .date(let d):
                return BarAction(
                    id: "ctx.calendar", title: L10n.t("创建日历事件", "New Event"),
                    symbol: "calendar.badge.plus", color: .systemRed) { _ in
                        CalendarHelper.createEvent(date: d, title: ctx.text)
                        FloatingBarController.shared.hide()
                    }
            case .money(let amount, let code):
                let conv = convertMoney(amount, code)
                return BarAction(
                    id: "ctx.money", title: conv,
                    symbol: "dollarsign.circle", color: .systemGreen) { _ in
                    PasteboardGuard.write(conv)
                    FloatingBarController.shared.hide()
                }
            case .unit(let amount, let unit):
                let conv = convertUnit(amount, unit)
                return BarAction(
                    id: "ctx.unit", title: conv,
                    symbol: "ruler", color: .systemBlue) { _ in
                    PasteboardGuard.write(conv)
                    FloatingBarController.shared.hide()
                }
            }
        }
    }

    /// mailto 默认交给系统 handler;但默认 handler 是浏览器时(典型:Chrome 注册了
    /// Gmail 处理却未开启),点击只会拉起浏览器、没有写信界面——回退用 Mail.app 打开
    private static func openMail(to address: String) {
        guard let url = URL(string: "mailto:\(address)") else { NSSound.beep(); return }
        let ws = NSWorkspace.shared
        let browsers: Set<String> = [
            "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
            "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser",
        ]
        let handlerIsBrowser = ws.urlForApplication(toOpen: url)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
            .map { browsers.contains($0) } ?? false
        if handlerIsBrowser,
           let mail = ws.urlForApplication(withBundleIdentifier: "com.apple.mail") {
            ws.open([url], withApplicationAt: mail,
                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            ws.open(url)
        }
    }

    // MARK: - 上下文动作辅助(纯函数,供测试)

    static func timestampString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        return f.string(from: d)
    }

    static func jsonPretty(_ s: String) -> String? {
        guard let data = s.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    static func jsonMinified(_ s: String) -> String? {
        guard let data = s.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return (try? JSONSerialization.data(withJSONObject: obj))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    static func base64Decode(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: t) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func colorHex(_ c: NSColor) -> String {
        guard let rgb = c.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(rgb.redComponent * 255 + 0.5),
                      Int(rgb.greenComponent * 255 + 0.5),
                      Int(rgb.blueComponent * 255 + 0.5))
    }

    static func colorRGB(_ c: NSColor) -> String {
        guard let rgb = c.usingColorSpace(.sRGB) else { return "rgb(0,0,0)" }
        return String(format: "rgb(%d, %d, %d)",
                      Int(rgb.redComponent * 255 + 0.5),
                      Int(rgb.greenComponent * 255 + 0.5),
                      Int(rgb.blueComponent * 255 + 0.5))
    }

    static func colorHSL(_ c: NSColor) -> String {
        guard let rgb = c.usingColorSpace(.sRGB) else { return "hsl(0,0%,0%)" }
        var h: CGFloat = 0, s: CGFloat = 0, l: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &l, alpha: &a)
        return String(format: "hsl(%d, %d%%, %d%%)", Int(h * 360 + 0.5),
                      Int(s * 100 + 0.5), Int(l * 100 + 0.5))
    }

    /// 近似汇率(离线估算,提示「约」);主币种间互转
    static func convertMoney(_ amount: Double, _ code: String) -> String {
        // 以 USD 为基准的静态近似汇率,仅作快速估算
        let toUSD: [String: Double] = [
            "USD": 1, "CNY": 7.2, "RMB": 7.2, "EUR": 0.92,
            "JPY": 150, "GBP": 0.79, "HKD": 7.8,
        ]
        guard let rate = toUSD[code.uppercased()], rate != 0 else { return code }
        let usd = amount / rate
        var parts: [String] = []
        for c in ["USD", "CNY", "EUR", "JPY", "GBP", "HKD"] where c != code.uppercased() {
            if let r = toUSD[c] { parts.append("\(c) \(fmt(usd * r))") }
        }
        return "≈ " + parts.prefix(3).joined(separator: " · ")
    }

    static func convertUnit(_ v: Double, _ unit: String) -> String {
        let g: (Double, String) -> String = { fmt($0) + $1 }
        switch unit {
        case "cm": return g(v / 2.54, " in")
        case "in", "inch": return g(v * 2.54, " cm")
        case "mm": return g(v / 25.4, " in")
        case "km": return g(v / 1.609, " mi")
        case "mi", "mile": return g(v * 1.609, " km")
        case "m": return g(v * 3.281, " ft")
        case "ft": return g(v / 3.281, " m")
        case "kg": return g(v * 2.205, " lb")
        case "lb": return g(v / 2.205, " kg")
        case "oz": return g(v * 28.35, " g")
        case "g": return g(v / 28.35, " oz")
        case "ml": return g(v * 0.0338, " fl oz")
        case "l": return g(v * 33.8, " fl oz")
        case "°c", "c": return g(v * 9 / 5 + 32, "°F")
        case "°f", "f": return g((v - 32) * 5 / 9, "°C")
        case "mb": return g(v / 1024, " GB")
        case "gb": return g(v * 1024, " MB")
        case "kb": return g(v / 1024, " MB")
        case "tb": return g(v * 1024, " GB")
        default: return "\(v) \(unit)"
        }
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(format: "%.0f", v)
                                          : String(format: "%.2f", v)
    }
}

/// 弹出菜单构造:NSMenuItem 回调通过单例字典分发
enum ContextMenu {
    /// 菜单项;init 末尾参数是闭包,支持 ContextMenu.Item("标题","符号") { ... } 写法
    struct Item {
        let title: String
        let symbol: String
        let run: () -> Void
        init(_ title: String, _ symbol: String, _ run: @escaping () -> Void) {
            self.title = title; self.symbol = symbol; self.run = run
        }
    }

    static func build(_ items: [Item]) -> NSMenu {
        let menu = NSMenu()
        for it in items {
            let (title, symbol, run) = (it.title, it.symbol, it.run)
            let item = NSMenuItem(title: title, action: #selector(MenuDispatch.run(_:)),
                                  keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = MenuDispatch.shared
            item.representedObject = MenuDispatch.register(run)
            menu.addItem(item)
        }
        return menu
    }

    /// 用完清理(单次菜单生命周期)
    static func drain() { MenuDispatch.shared.clear() }
}

final class MenuDispatch: NSObject {
    static let shared = MenuDispatch()
    private var closures: [String: () -> Void] = [:]
    private var seq = 0

    static func register(_ run: @escaping () -> Void) -> String {
        shared.seq += 1
        let key = "m\(shared.seq)"
        shared.closures[key] = run
        return key
    }

    @objc func run(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String {
            closures[key]?()
            FloatingBarController.shared.hide()
        }
    }

    func clear() { closures.removeAll() }
}

/// #4 日期命中 → EventKit 建事件;未授权则提示
enum CalendarHelper {
    static func createEvent(date: Date, title: String) {
        // 用系统日历 URL 打开「新建事件」对话框最简单可靠;EventKit 需要 Calendars 权限。
        // 优先尝试 EventKit,失败降级为打开 Calendar.app。
        var comps = DateComponents()
        let cal = Calendar.current
        comps.year = cal.component(.year, from: date)
        comps.month = cal.component(.month, from: date)
        comps.day = cal.component(.day, from: date)
        comps.hour = cal.component(.hour, from: date)
        comps.minute = cal.component(.minute, from: date)
        // iCalendar 通过 webcal 不可靠;直接用 NSAppleScript 让 Calendar.app 建事件
        let fmt = DateFormatter()
        fmt.dateFormat = "date \"%@\""
        _ = fmt
        let script = """
        set theDate to (current date)
        set year of theDate to \(comps.year ?? 2000)
        set month of theDate to \(comps.month ?? 1)
        set day of theDate to \(comps.day ?? 1)
        set hours of theDate to \(comps.hour ?? 9)
        set minutes of theDate to \(comps.minute ?? 0)
        set seconds of theDate to 0
        tell application "Calendar"
            activate
            tell calendar 1 to make new event with properties {summary:"\(
                title.replacingOccurrences(of: "\"", with: "'").prefix(100))", start date:theDate}
        end tell
        """
        if let s = NSAppleScript(source: script) {
            var err: NSDictionary?
            s.executeAndReturnError(&err)
        }
    }
}
