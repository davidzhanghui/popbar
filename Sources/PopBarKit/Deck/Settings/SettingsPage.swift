import Cocoa
import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 设置的二级导航（合并原 SettingsWindow + PreferencesWindow）
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, selection, bar, ai, hotkeys, privacy, apps, extensions, modules, today, media, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.t("通用", "General")
        case .selection: return L10n.t("划词", "Selection")
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

    var body: some View {
        DSPageShell(L10n.t("设置", "Settings"), subtitle: state.settings.title, scrolls: false) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.allCases) { s in
                        SidebarRow(icon: s.icon, title: s.title, badge: nil, selected: state.settings == s) {
                            state.settings = s
                        }
                    }
                }
                .frame(width: 190)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section
                    }
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(state.settings)
            }
        }
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

/// 下拉选择（选项多于 3 个时代替分段控件）
struct DSMenuPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var width: CGFloat = 180

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                Button(o.1) { selection = o.0 }
            }
        } label: {
            HStack {
                Text(options.first { $0.0 == selection }?.1 ?? "—").font(DS.body).foregroundStyle(DS.text).lineLimit(1)
                Spacer()
                Icon("chevron-down", size: 13)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button).strokeBorder(DS.borderStrong, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
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
