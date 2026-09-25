import Cocoa

/// 内置动作(builtin.*):复制/剪切/大小写/搜索/AI 翻译/朗读/字数统计,
/// 以及二维码、脱敏、Dev 工具箱等后续里程碑加入的动作。
enum BuiltinActions {
    /// 默认按钮顺序;上下文按钮插在 builtin.case 之后。
    /// builtin.devtools 不列在这里:它在 ActionRegistry.resolve 里被固定到工具条最右(扩展之后)
    static let defaultOrder = [
        "builtin.copy", "builtin.cut", "builtin.case",
        "builtin.google", "builtin.baidu", "builtin.ai",
        "builtin.speak", "builtin.stats",
        "builtin.qrcode", "builtin.mask",
    ]

    static func all() -> [BarAction] {
        let bar = FloatingBarController.shared
        return [
            BarAction(id: "builtin.copy", title: L10n.t("复制", "Copy"),
                      symbol: "doc.on.doc", color: .systemBlue) { ctx in
                PasteboardGuard.write(ctx.text)
                UsageStats.shared.record("builtin.copy", bundleID: ctx.bundleID)
                bar.hide()
            },
            BarAction(id: "builtin.cut", title: L10n.t("剪切", "Cut"),
                      symbol: "scissors", color: .systemOrange) { _ in
                bar.hide()
                Actions.postKeyCombo(key: 7)   // kVK_ANSI_X
            },
            BarAction(id: "builtin.case", title: L10n.t("大写/小写转换", "Upper/Lower"),
                      symbol: "textformat", color: .systemPurple,
                      isAvailable: { $0.canReplace }) { ctx in
                let t = ctx.text
                bar.hide()
                TextReplacer.replaceInline(t == t.uppercased() ? t.lowercased() : t.uppercased())
            },
            BarAction(id: "builtin.google", title: "Google",
                      symbol: "magnifyingglass",
                      color: NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1)) { ctx in
                bar.openURL("https://www.google.com/search?q=\(bar.enc(ctx.text))")
            },
            BarAction(id: "builtin.baidu", title: L10n.t("百度搜索", "Baidu"),
                      symbol: "pawprint.fill",
                      color: NSColor(srgbRed: 0.16, green: 0.39, blue: 0.88, alpha: 1)) { ctx in
                bar.openURL("https://www.baidu.com/s?wd=\(bar.enc(ctx.text))")
            },
            BarAction(id: "builtin.ai", title: L10n.t("AI 翻译(多模型对比)", "AI Translate"),
                      symbol: "text.bubble.fill",
                      color: NSColor(srgbRed: 0.45, green: 0.30, blue: 0.95, alpha: 1)) { ctx in
                bar.hide()
                guard !ConfigStore.shared.config.activeProviders.isEmpty else {
                    AppDelegate.openTranslateConfig()
                    return
                }
                TranslationPanelController.shared.show(ctx: ctx)
            },
            BarAction(id: "builtin.speak", title: L10n.t("朗读/停止", "Speak/Stop"),
                      symbol: "speaker.wave.2.fill", color: .systemPink) { ctx in
                bar.hide()
                bar.speak(ctx.text)
            },
            BarAction(id: "builtin.stats", title: L10n.t("字数统计", "Word Count"),
                      symbol: "number", color: .systemTeal) { ctx in
                let chars = ctx.text.count
                let words = ctx.text.split { $0.isWhitespace }.count
                bar.showInfo(L10n.t("字符 \(chars) · 词 \(words)",
                                    "\(chars) chars · \(words) words"))
            },
            // —— 后续里程碑注册的动作 ——
        ] + milestoneActions()
    }

    /// 各里程碑追加的动作提供者;返回 nil 表示该功能未启用/不适用
    private static func milestoneActions() -> [BarAction] {
        var out: [BarAction] = []
        if let a = QRCodePanel.barAction() { out.append(a) }
        if let a = SensitiveGuard.maskAction() { out.append(a) }
        if let a = DevTools.barAction() { out.append(a) }
        return out
    }
}
