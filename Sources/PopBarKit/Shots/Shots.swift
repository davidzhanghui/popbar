import Cocoa
import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 文档截图：离屏渲染各界面（不需要屏幕录制权限），浅色、深色各一张，
/// 文件名 `<模块>-<状态>[-dark].png`，写到 docs/screenshots/。
/// 配置读写指向临时目录（由 PopBarShot 设置 POPBAR_CONFIG_DIR），不碰真实配置、不读真实数据。
@MainActor
public enum PopBarShots {
    struct Shot {
        let name: String
        let make: () -> NSView
        var settle: TimeInterval = 0.6
        /// 截图前的异步准备（如等流式请求返回），在 make 之前执行
        var prepare: (() async -> Void)? = nil
    }

    public static func run(outDir: String, only: String? = nil) async {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        prepareConfig()
        let shots = catalog().filter { only == nil || $0.name.hasPrefix(only!) }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            for s in shots {
                if let prepare = s.prepare { await prepare() }
                let view = s.make()
                let url = URL(fileURLWithPath: outDir).appendingPathComponent(s.name + (dark ? "-dark" : "") + ".png")
                await render(view, appearance: appearance, settle: s.settle, to: url)
            }
        }
        NSApp.appearance = nil
    }

    /// 截图用的演示配置：几个模块全开，示例服务不带真实 Key
    private static func prepareConfig() {
        var c = PopBarConfig()
        c.onboarded = true
        for id in ConfigMigration.moduleDefaults.keys { c.modules[id] = true }
        c.modules["tv"] = false
        c.clipboardHistory.enabled = false
        // 宣传片 / 文档用：指向本地 fixture 服务（OpenAI 兼容流式接口），渲染翻译面板的真实结果态
        if let url = ProcessInfo.processInfo.environment["POPBAR_SHOT_LLM_URL"], !url.isEmpty {
            c.providers = [("DeepSeek", "deepseek-chat"), ("硅基流动", "Qwen/Qwen2.5-7B-Instruct"), ("Ollama", "qwen2.5:7b")]
                .map { LLMProvider(name: $0.0, baseURL: url, model: $0.1, apiKey: "sk-demo", enabled: true) }
            c.targetLanguage = "zh-CN"
        }
        let demo = ProcessInfo.processInfo.environment["POPBAR_SHOT_DEMO"] == "1"
        if demo {
            c.clipboardHistory.enabled = true
            c.clipboardHistory.persist = true
            c.snap.history.enabled = true
        }
        ConfigStore.shared.config = c
        if demo { seedDemoData() }
    }

    /// POPBAR_SHOT_DEMO=1：给今日 / 剪贴板 / 截图历史 / 录屏记录塞示例数据，Deck 各页渲染成「用过的样子」。
    /// 全部写在临时配置目录里；剪贴板载入后立刻停止轮询，不会记录本机真实剪贴板。
    private static func seedDemoData() {
        let todo = TodoStore.shared
        todo.reload()
        for (text, src) in [("整理 3.0 发布说明", "备忘录"), ("回复设计评审的意见", "邮件"),
                            ("给落地页换新截图", "Safari"), ("周五前确认合同", "微信")] {
            todo.add(text, source: src)
        }
        if let first = todo.items.first { todo.toggle(first.id) }

        let now = Date().timeIntervalSince1970
        let clips: [[String: Any]] = [
            ["type": "text", "text": "https://github.com/davidzhanghui/popbar", "time": now - 60, "pinned": true],
            ["type": "text", "text": "选中文字，事就办了", "time": now - 300, "pinned": false],
            ["type": "text", "text": "swift build -c release", "time": now - 900, "pinned": false],
            ["type": "text", "text": "#D9480F", "time": now - 1800, "pinned": false],
            ["type": "text", "text": "PopBar shows a floating toolbar right above your selection.", "time": now - 3600, "pinned": false],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: clips) {
            try? data.write(to: PopBarConfig.directoryURL.appendingPathComponent("clipboard-history.json"))
        }
        ClipboardHistory.shared.applyConfig()
        ClipboardHistory.shared.suspend()

        for name in ["deck-monitor", "translate-result", "bar-more", "deck-clean"] {
            if let img = NSImage(contentsOfFile: "docs/screenshots/\(name).png"),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                SnapHistory.add(cg, scale: 2)
            }
        }
        let video = URL(fileURLWithPath: "docs/popbar-promo-v2.0.mp4")
        if FileManager.default.fileExists(atPath: video.path) {
            for (i, title) in ["发布会彩排", "Bug 复现步骤", "新功能演示"].enumerated() {
                let dst = PopBarConfig.directoryURL.appendingPathComponent("\(title).mp4")
                try? FileManager.default.copyItem(at: video, to: dst)
                RecordHistory.shared.add(url: dst, duration: [42, 18, 69][i])
            }
        }
    }

    private static func catalog() -> [Shot] {
        var list: [Shot] = []
        let bar = FloatingBarController.shared
        list.append(Shot(name: "bar-default") {
            framed(bar.makeViews(for: SourceContext(text: "The quick brown fox jumps over the lazy dog.", origin: .selection)).bar)
        })
        list.append(Shot(name: "bar-capsule") {
            framed(bar.makeViews(for: SourceContext(text: "https://github.com/davidzhanghui/popbar", origin: .selection)).bar)
        })
        list.append(Shot(name: "bar-capsule-color") {
            framed(bar.makeViews(for: SourceContext(text: "#D9480F", origin: .selection)).bar)
        })
        list.append(Shot(name: "bar-capsule-time") {
            framed(bar.makeViews(for: SourceContext(text: "1794038400", origin: .selection)).bar)
        })
        list.append(Shot(name: "bar-more") {
            let v = bar.makeViews(for: SourceContext(text: "(12 + 30) * 2", origin: .selection))
            return framed(stack(v.bar, v.more))
        })
        list.append(Shot(name: "result-card") {
            framed(hosting(ResultCardView(title: L10n.t("扩展结果", "Extension Result"),
                                          text: "{\n  \"sub\": \"1234567890\",\n  \"name\": \"PopBar\",\n  \"iat\": 1516239022\n}",
                                          mono: true, onCopy: {}, onClose: {}), width: ResultCard.width))
        })
        list.append(Shot(name: "clipboard-paused") {
            let m = ClipboardPicker.Model()
            m.enabled = false
            return framed(hosting(ClipboardPickerView(model: m, onPick: { _, _ in }, onEnable: {}), width: ClipboardPicker.width, height: 200))
        })
        list.append(Shot(name: "translate-empty", make: {
            TranslationPanelController.shared.show(text: "Selection toolbar for macOS")
            let v = TranslationPanelController.shared.contentView ?? NSView()
            let snapshot = snapshotCopy(v)
            TranslationPanelController.shared.close()
            return framed(snapshot)
        }, settle: 0.2))
        if ProcessInfo.processInfo.environment["POPBAR_SHOT_LLM_URL"] != nil {
            list.append(Shot(name: "translate-result", make: {
                let v = TranslationPanelController.shared.contentView ?? NSView()
                let snapshot = snapshotCopy(v)
                TranslationPanelController.shared.close()
                return framed(snapshot)
            }, settle: 0.2, prepare: {
                TranslationPanelController.shared.show(text: "PopBar shows a floating toolbar right above your selection — copy, search, translate, without leaving the app.")
                try? await Task.sleep(nanoseconds: 4_000_000_000)   // 等三家流式返回完
            }))
            // 隐私：文本含手机号 / 邮箱时，发送前先询问（privacy.guard = ask）
            list.append(Shot(name: "translate-sensitive", make: {
                let v = TranslationPanelController.shared.contentView ?? NSView()
                let snapshot = snapshotCopy(v)
                TranslationPanelController.shared.close()
                return framed(snapshot)
            }, settle: 0.2, prepare: {
                TranslationPanelController.shared.show(text: "请把合同发给陈经理，手机 13812345678，邮箱 chen@example.com，周五前确认。")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }))
        }

        let state = DeckController.shared.state
        func deck(_ page: DeckPage, _ settings: SettingsSection = .general) -> () -> NSView {
            {
                state.settings = settings
                state.page = page
                let host = NSHostingView(rootView: DeckRootView(state: state, registry: ModuleRegistry.shared))
                host.frame = NSRect(x: 0, y: 0, width: 980, height: 660)
                return host
            }
        }
        list.append(Shot(name: "deck-welcome", make: deck(.welcome)))
        list.append(Shot(name: "deck-today", make: deck(.module("today"))))
        list.append(Shot(name: "deck-clipboard", make: deck(.module("clipboard"))))
        list.append(Shot(name: "deck-snap", make: deck(.module("snap"))))
        list.append(Shot(name: "deck-record", make: deck(.module("record"))))
        // 需要先加载数据的模块页：触发 pageDidAppear（监控采样、清理扫描、读启动项…），多等一会再截
        func live(_ id: String) -> () -> NSView {
            let make = deck(.module(id))
            return {
                let v = make()
                ModuleRegistry.shared.module(id)?.pageDidAppear()
                return v
            }
        }
        list.append(Shot(name: "deck-monitor", make: live("monitor"), settle: 4))
        list.append(Shot(name: "deck-clean", make: live("clean"), settle: 25))
        list.append(Shot(name: "deck-maintenance", make: live("maintenance"), settle: 2))
        // 启动项、打印两页展示的是本机真实的登录项与打印记录，不进文档截图
        list.append(Shot(name: "settings-general", make: deck(.settings, .general)))
        list.append(Shot(name: "settings-bar", make: deck(.settings, .bar)))
        list.append(Shot(name: "settings-ai-empty", make: deck(.settings, .ai)))
        list.append(Shot(name: "settings-hotkeys", make: deck(.settings, .hotkeys)))
        list.append(Shot(name: "settings-modules", make: deck(.settings, .modules)))
        list.append(Shot(name: "settings-privacy", make: deck(.settings, .privacy)))
        list.append(Shot(name: "settings-apps", make: deck(.settings, .apps)))
        return list
    }

    // MARK: - 渲染

    /// 把视图放进离屏窗口，等 SwiftUI 布局完再画到位图
    private static func render(_ view: NSView, appearance: NSAppearance?, settle: TimeInterval, to url: URL) async {
        let size = view.frame.size
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = appearance
        w.isOpaque = false
        w.backgroundColor = .clear
        w.contentView = view
        w.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("wrote \(url.path)")
        }
        w.orderOut(nil)
        w.contentView = nil
    }

    /// 浮动类窗口外面加一圈背景，接近真实观感
    private static func framed(_ content: NSView) -> NSView {
        // POPBAR_SHOT_BARE=1：不加背景，输出透明底的组件本身（叠加到宣传片画面里用）
        if ProcessInfo.processInfo.environment["POPBAR_SHOT_BARE"] == "1" {
            content.frame.origin = .zero
            return content
        }
        let pad: CGFloat = 28
        let size = content.frame.size
        let root = ThemedBox(frame: NSRect(x: 0, y: 0, width: size.width + pad * 2, height: size.height + pad * 2), radius: 0)
        root.fill = Theme.bg
        content.frame.origin = NSPoint(x: pad, y: pad)
        root.addSubview(content)
        return root
    }

    /// 浮动条在上、「更多」面板在下，左对齐，间隔 6
    private static func stack(_ top: NSView, _ bottom: NSView?) -> NSView {
        guard let bottom else { return top }
        let w = max(top.frame.width, bottom.frame.width)
        let h = top.frame.height + 6 + bottom.frame.height
        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bottom.frame.origin = .zero
        top.frame.origin = NSPoint(x: 0, y: bottom.frame.height + 6)
        v.addSubview(bottom)
        v.addSubview(top)
        return v
    }

    private static func hosting<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil) -> NSView {
        let host = NSHostingView(rootView: view)
        let fit = host.fittingSize
        host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? fit.height)
        return host
    }

    /// 已显示窗口里的视图：先画成图片再放进截图画布（原视图仍归原窗口所有）
    private static func snapshotCopy(_ v: NSView) -> NSView {
        v.layoutSubtreeIfNeeded()
        let iv = NSImageView(frame: v.bounds)
        if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            let img = NSImage(size: v.bounds.size)
            img.addRepresentation(rep)
            iv.image = img
        }
        return iv
    }
}
