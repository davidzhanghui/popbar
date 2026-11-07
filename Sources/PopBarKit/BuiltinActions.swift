import Cocoa
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 内置动作(builtin.*):复制/剪切/大小写/搜索/AI 翻译/朗读/字数统计,
/// 以及二维码、脱敏、Dev 工具箱。待办、打印、电视投送由各自模块提供。
@MainActor
enum BuiltinActions {
    /// 默认顺序;前 5 个是常用按钮:复制 翻译 搜索 朗读 待办
    static let defaultOrder = [
        "builtin.copy", "builtin.ai", "builtin.search", "builtin.speak", "builtin.todo",
        "builtin.cut", "builtin.case", "builtin.stats", "builtin.qrcode", "builtin.mask",
        "builtin.devtools", "builtin.print",
    ]
    static let defaultPrimary = Array(defaultOrder.prefix(5))

    /// 设置页（浮动条排序、按应用自定义）列出的动作；所属模块关闭的不列
    static var catalog: [(id: String, title: String, icon: String)] {
        let m = ModuleRegistry.shared
        var list: [(id: String, title: String, icon: String)] = [
            ("builtin.copy", L10n.t("复制", "Copy"), "copy"),
            ("builtin.ai", L10n.t("翻译", "Translate"), "languages"),
            ("builtin.search", L10n.t("搜索", "Search"), "search"),
            ("builtin.speak", L10n.t("朗读", "Speak"), "volume-2"),
        ]
        if m.isEnabled("today") { list.append(("builtin.todo", L10n.t("待办", "To-Do"), "list-plus")) }
        list += [
            ("builtin.cut", L10n.t("剪切", "Cut"), "scissors"),
            ("builtin.case", L10n.t("大小写", "Case"), "case-sensitive"),
            ("builtin.stats", L10n.t("字数", "Count"), "hash"),
            ("builtin.qrcode", L10n.t("二维码", "QR Code"), "qr-code"),
            ("builtin.mask", L10n.t("脱敏", "Mask"), "eye-off"),
            ("builtin.devtools", "Dev", "terminal"),
        ]
        if m.isEnabled("print") { list.append(("builtin.print", L10n.t("打印", "Print"), "printer")) }
        for e in ConfigStore.shared.config.extensions where e.enabled {
            list.append(("ext.\(e.id)", e.name, Extensions.lucideIcon(e.symbol)))
        }
        return list
    }

    static func all() -> [BarAction] {
        let bar = FloatingBarController.shared
        return [
            BarAction(id: "builtin.copy", title: L10n.t("复制", "Copy"), icon: "copy") { ctx in
                PasteboardGuard.write(ctx.text)
                UsageStats.shared.record("builtin.copy", bundleID: ctx.bundleID)
                bar.hide()
            },
            BarAction(id: "builtin.ai", title: L10n.t("翻译", "Translate"), icon: "languages") { ctx in
                bar.hide()
                // 没配服务也打开面板：面板里给出空状态与「添加服务」按钮
                TranslationPanelController.shared.show(ctx: ctx)
            },
            BarAction(id: "builtin.search", title: L10n.t("搜索", "Search"), icon: "search") { ctx in
                let engine = ConfigStore.shared.config.toolbar.searchEngine
                if let u = engine.url(for: ctx.text) { NSWorkspace.shared.open(u) }
                bar.hide()
            },
            BarAction(id: "builtin.speak", title: L10n.t("朗读", "Speak"), icon: "volume-2") { ctx in
                // 不隐藏工具条:朗读中图标变「停止」,再点一次即停;条被收起时朗读一并停止
                bar.speak(ctx.text)
            },
            BarAction(id: "builtin.cut", title: L10n.t("剪切", "Cut"), icon: "scissors") { _ in
                bar.hide()
                Actions.postKeyCombo(key: 7)   // kVK_ANSI_X
            },
            BarAction(id: "builtin.case", title: L10n.t("大小写", "Case"), icon: "case-sensitive",
                      isAvailable: { $0.canReplace }) { ctx in
                let t = ctx.text
                bar.hide()
                TextReplacer.replaceInline(t == t.uppercased() ? t.lowercased() : t.uppercased())
            },
            BarAction(id: "builtin.stats", title: L10n.t("字数", "Count"), icon: "hash") { ctx in
                let chars = ctx.text.count
                let words = ctx.text.split { $0.isWhitespace }.count
                bar.showInfo(L10n.t("字符 \(chars) · 词 \(words)", "\(chars) chars · \(words) words"))
            },
        ] + optionalActions()
    }

    /// 有条件出现的动作;返回 nil 表示不适用
    private static func optionalActions() -> [BarAction] {
        var out: [BarAction] = []
        if let a = QRCodePanel.barAction() { out.append(a) }
        if let a = SensitiveGuard.maskAction() { out.append(a) }
        if let a = DevTools.barAction() { out.append(a) }
        return out
    }
}
