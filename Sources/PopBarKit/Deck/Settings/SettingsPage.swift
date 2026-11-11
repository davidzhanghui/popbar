import Cocoa
import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 设置的分组（在 Deck 侧栏里按组列出；关于放在侧栏底部）
enum SettingsGroup: CaseIterable {
    case basics, selection, features

    var title: String {
        switch self {
        case .basics: return L10n.t("常规", "General")
        case .selection: return L10n.t("划词", "Selection")
        case .features: return L10n.t("功能", "Features")
        }
    }

    var sections: [SettingsSection] {
        switch self {
        case .basics: return [.general, .modules, .hotkeys, .privacy]
        case .selection: return [.selection, .bar, .apps, .extensions]
        case .features: return [.ai, .media, .today]
        }
    }
}

/// 设置的二级导航（合并原 SettingsWindow + PreferencesWindow）
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, selection, bar, ai, hotkeys, privacy, apps, extensions, modules, today, media, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.t("通用", "General")
        case .selection: return L10n.t("取词", "Selection")
        case .bar: return L10n.t("浮动条", "Bar")
        case .ai: return L10n.t("翻译与 AI", "Translate & AI")
        case .hotkeys: return L10n.t("快捷键", "Shortcuts")
        case .privacy: return L10n.t("隐私", "Privacy")
        case .apps: return L10n.t("按应用", "Per App")
        case .extensions: return L10n.t("扩展", "Extensions")
        case .modules: return L10n.t("模块", "Modules")
        case .today: return L10n.t("待办", "To-Do")
        case .media: return L10n.t("截屏与录屏", "Capture")
        case .about: return L10n.t("关于", "About")
        }
    }

    /// 页头副标题：一句话说明这一页管什么
    var summary: String {
        switch self {
        case .general: return L10n.t("语言、外观、启动方式与配置文件", "Language, appearance, launch and the config file")
        case .selection: return L10n.t("选中文字后，浮动条何时、如何弹出", "When and how the bar appears after you select text")
        case .bar: return L10n.t("浮动条上的按钮、搜索引擎与朗读", "Buttons on the bar, search engine and speech")
        case .ai: return L10n.t("翻译语言、请求参数与翻译服务", "Languages, request options and translation services")
        case .hotkeys: return L10n.t("点击组合后直接按下新快捷键；Esc 取消，⌫ 清除。录制时全局快捷键会暂停",
                                     "Click a shortcut and press new keys; Esc cancels, ⌫ clears. Global shortcuts pause while recording")
        case .privacy: return L10n.t("敏感内容守卫、剪贴板记录与使用统计", "Sensitive content guard, clipboard history and usage stats")
        case .apps: return L10n.t("给特定 App 关掉划词、只保留快捷键，或只显示指定按钮",
                                  "Turn selection off for specific apps, keep only the shortcut, or show chosen buttons")
        case .extensions: return L10n.t("出现在浮动条「更多」面板里的自定义动作：打开网址、运行脚本或快捷指令",
                                        "Custom actions in the bar's More panel: open a URL, run a script or a Shortcut")
        case .modules: return L10n.t("关闭的模块不出现在侧栏、浮动条和菜单里，快捷键不注册，也不在后台运行",
                                     "Disabled modules leave the sidebar, bar and menu; their shortcuts and background work stop")
        case .today: return L10n.t("待办的存放位置、系统同步与番茄钟", "Where to-dos live, system sync and Pomodoro")
        case .media: return L10n.t("截图保存、录屏画面与声音、导出参数", "Screenshot saving, recording video and audio, export options")
        case .about: return L10n.t("版本信息与项目主页", "Version and project homepage")
        }
    }

    var icon: String {
        switch self {
        case .general: return "settings"
        case .selection: return "text-cursor"
        case .bar: return "panel-top"
        case .ai: return "languages"
        case .hotkeys: return "keyboard"
        case .privacy: return "shield"
        case .apps: return "app-window"
        case .extensions: return "puzzle"
        case .modules: return "layout-grid"
        case .today: return "list-checks"
        case .media: return "scan"
        case .about: return "info"
        }
    }
}

/// 设置页的配置编辑器：读 ConfigStore，改动后延迟写回 config.json（写入方式不变：0600、API Key 明文）
@MainActor
final class ConfigEditor: ObservableObject {
    @Published var c: PopBarConfig
    private var pending: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    init() {
        c = ConfigStore.shared.config
        observer = NotificationCenter.default.addObserver(forName: ConfigStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pending == nil else { return }
                let fresh = ConfigStore.shared.config
                if fresh != self.c { self.c = fresh }
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// 绑定到配置字段；改动 0.35 秒后保存（输入框连续输入只写一次盘）
    func bind<T>(_ kp: WritableKeyPath<PopBarConfig, T>) -> Binding<T> {
        Binding(get: { self.c[keyPath: kp] }, set: { v in
            self.c[keyPath: kp] = v
            self.scheduleSave()
        })
    }

    private final class LastValueBox<V> { var v: V; init(_ v: V) { self.v = v } }

    /// 数组元素字段绑定（带越界保护）。
    /// 删除条目后，SwiftUI 会在视图移除前再刷新一次旧绑定；直接用 `\.arr[i].x` 会下标越界崩溃。
    /// 这里越界时返回上次的值并忽略写入。
    func bind<E, T>(_ arr: WritableKeyPath<PopBarConfig, [E]>, _ i: Int, _ field: WritableKeyPath<E, T>) -> Binding<T> {
        let box = LastValueBox(c[keyPath: arr][i][keyPath: field])
        return Binding(get: {
            let list = self.c[keyPath: arr]
            guard list.indices.contains(i) else { return box.v }
            box.v = list[i][keyPath: field]
            return box.v
        }, set: { v in
            guard self.c[keyPath: arr].indices.contains(i) else { return }
            self.c[keyPath: arr][i][keyPath: field] = v
            self.scheduleSave()
        })
    }

    func update(_ body: (inout PopBarConfig) -> Void) {
        body(&c)
        scheduleSave()
    }

    func scheduleSave() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            try? ConfigStore.shared.save(self.c)
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    func saveNow() {
        pending?.cancel()
        pending = nil
        try? ConfigStore.shared.save(c)
    }
}

struct SettingsPage: View {
    @ObservedObject var state: DeckState
    @StateObject private var editor = ConfigEditor()

    /// 设置内容的最大宽度：太宽时标题和右侧控件离得太远，不好对应
    static let contentWidth: CGFloat = 680

    var body: some View {
        // 两栏布局：设置的分组导航在 Deck 侧栏里（DeckSidebar 切到设置模式），这里只放内容
        DSPageShell(state.settings.title, subtitle: state.settings.summary) {
            VStack(alignment: .leading, spacing: 24) {
                section
            }
            .frame(maxWidth: Self.contentWidth, alignment: .leading)
        }
        .id(state.settings)   // 换页时滚动位置回到顶部
        .environmentObject(editor)
        .onDisappear { editor.saveNow() }
    }

    @ViewBuilder private var section: some View {
        switch state.settings {
        case .general: GeneralSettings(state: state)
        case .selection: SelectionSettings()
        case .bar: BarSettings()
        case .ai: AISettings()
        case .hotkeys: HotkeySettings()
        case .privacy: PrivacySettings()
        case .apps: AppRuleSettings()
        case .extensions: ExtensionSettings()
        case .modules: ModuleSettings()
        case .today: TodaySettings()
        case .media: MediaSettings()
        case .about: AboutSettings()
        }
    }
}

// MARK: - 小控件

/// 数字输入（带范围）
struct DSNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix: String = ""
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(DS.body.monospacedDigit())
                .frame(width: 56)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(DS.surface2))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button).strokeBorder(DS.borderStrong, lineWidth: 1))
                .onSubmit(commit)
                .onChange(of: text) { _, _ in commit() }
            if !suffix.isEmpty { Text(suffix).font(DS.caption).foregroundStyle(DS.muted) }
        }
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, v in if Int(text) != v { text = "\(v)" } }
    }

    private func commit() {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
        let clamped = min(max(n, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
    }
}

/// 下拉选择（选项多于 3 个时代替分段控件）。
/// 不用 SwiftUI Menu：borderlessButton 样式会丢掉 label 的背景并把箭头挪到左边；这里自绘按钮，点击弹出 NSMenu。
struct DSMenuPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var width: CGFloat = 180
    @State private var hovering = false

    var body: some View {
        Button(action: popUp) {
            HStack(spacing: 6) {
                Text(options.first { $0.0 == selection }?.1 ?? "—").font(DS.body).foregroundStyle(DS.text).lineLimit(1)
                Spacer(minLength: 0)
                Icon("chevron-down", size: 13, color: DS.muted)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(hovering ? DS.surface2 : DS.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button).strokeBorder(DS.borderStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .fixedSize()
    }

    private func popUp() {
        let menu = NSMenu()
        var current: NSMenuItem?
        for (value, title) in options {
            let item = ClosureMenuItem(title: title) { selection = value }
            if value == selection { item.state = .on; current = item }
            menu.addItem(item)
        }
        // 屏幕坐标弹出：当前项对齐到鼠标位置，和系统弹出按钮的手感一致
        menu.popUp(positioning: current, at: NSEvent.mouseLocation, in: nil)
    }
}

/// 带闭包的菜单项
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// 滑块（0~1 或任意范围），右侧显示数值
struct DSSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range).frame(width: 160).tint(DS.accent)
            Text(format(value)).font(DS.caption.monospacedDigit()).foregroundStyle(DS.muted).frame(width: 44, alignment: .trailing)
        }
    }
}

/// 选择目录 / 文件
enum FilePick {
    static func directory(start: String) -> String? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: (start as NSString).expandingTildeInPath)
        NSApp.activateForUI()
        return p.runModal() == .OK ? p.url?.path : nil
    }

    static func app() -> (bundleID: String, name: String)? {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.allowedContentTypes = [.applicationBundle]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activateForUI()
        guard p.runModal() == .OK, let url = p.url, let b = Bundle(url: url), let id = b.bundleIdentifier else { return nil }
        let name = (b.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (b.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        return (id, name)
    }

    static func image() -> String? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        NSApp.activateForUI()
        return p.runModal() == .OK ? p.url?.path : nil
    }
}

extension Array {
    /// 越界返回 nil；设置页里删除条目后旧绑定还会被刷新一次，不能直接下标取值
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
