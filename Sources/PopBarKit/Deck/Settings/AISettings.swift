import Cocoa
import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

// MARK: - 翻译与 AI

struct AISettings: View {
    @EnvironmentObject var e: ConfigEditor
    @State private var selected: String?
    @State private var testText = ""
    @State private var testTone: DSTone = .neutral
    @State private var testTask: Task<Void, Never>?

    static let presets: [LLMProvider] = [
        LLMProvider(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", apiKey: "", enabled: true),
        LLMProvider(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", model: "deepseek-ai/DeepSeek-V3", apiKey: "", enabled: true),
        LLMProvider(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini", apiKey: "", enabled: true),
        LLMProvider(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini", apiKey: "", enabled: true),
        LLMProvider(name: "Ollama（本地）", baseURL: "http://127.0.0.1:11434/v1", model: "qwen2.5:7b", apiKey: "ollama", enabled: true),
    ]

    private let langs = TranslateLanguage.options([("auto", L10n.t("自动", "Auto"))])
    private let primaryLangs = TranslateLanguage.options([("system", L10n.t("跟随系统", "System"))])
    private let secondaryLangs = TranslateLanguage.options([("auto", L10n.t("自动", "Auto"))])

    /// 当前偏好解析后的实际语言，显示在副标题里
    private var prefs: LanguagePrefs {
        LanguagePrefs.resolve(primary: e.c.primaryLanguage, secondary: e.c.secondaryLanguage)
    }

    private var index: Int? { e.c.providers.firstIndex { $0.id == selected } }

    var body: some View {
        DSGroup(L10n.t("翻译", "Translation")) {
            DSSettingRow(L10n.t("源语言", "From")) { DSMenuPicker(selection: e.bind(\.sourceLanguage), options: langs) }
            DSDivider()
            DSSettingRow(L10n.t("目标语言", "To"), subtitle: L10n.t("自动：原文是首选语言时译成第二语言，其余译成首选语言", "Auto: your primary language → second language, everything else → primary")) {
                DSMenuPicker(selection: e.bind(\.targetLanguage), options: langs)
            }
            DSDivider()
            DSSettingRow(L10n.t("首选语言", "Primary Language"),
                         subtitle: L10n.t("当前：\(TranslateLanguage.title(prefs.primary))", "Now: \(TranslateLanguage.title(prefs.primary))")) {
                DSMenuPicker(selection: e.bind(\.primaryLanguage), options: primaryLangs)
            }
            DSDivider()
            DSSettingRow(L10n.t("第二语言", "Second Language"),
                         subtitle: L10n.t("当前：\(TranslateLanguage.title(prefs.secondary))", "Now: \(TranslateLanguage.title(prefs.secondary))")) {
                DSMenuPicker(selection: e.bind(\.secondaryLanguage), options: secondaryLangs)
            }
            DSDivider()
            DSSettingRow(L10n.t("超时", "Timeout")) {
                DSNumberField(value: Binding(get: { Int(e.c.timeout) }, set: { v in e.update { $0.timeout = Double(v) } }),
                              range: 5...300, suffix: L10n.t("秒", "s"))
            }
            DSDivider()
            DSSettingRow(L10n.t("最大字符", "Max Characters"), subtitle: L10n.t("超过的部分不发送", "Anything longer is cut")) {
                DSNumberField(value: e.bind(\.maxCharacters), range: 100...50_000)
            }
            DSDivider()
            DSSettingRow(L10n.t("温度", "Temperature"), subtitle: L10n.t("越低越稳定", "Lower is more literal")) {
                DSSlider(value: e.bind(\.temperature), range: 0...2)
            }
            DSDivider()
            DSSettingRow(L10n.t("截图 OCR 之后", "After Screenshot OCR")) {
                DSSegmented(selection: e.bind(\.ocr.after), options: [
                    (.panel, L10n.t("翻译面板", "Translate")), (.bar, L10n.t("浮动条", "Bar")),
                ])
            }
            DSDivider()
            DSSettingRow(L10n.t("面板位置", "Panel Position")) {
                DSSegmented(selection: e.bind(\.panelPosition), options: [
                    (.top, L10n.t("选区下方", "Below selection")), (.cursor, L10n.t("鼠标旁", "Near cursor")),
                ])
            }
        }

        HStack {
            DSEyebrow(L10n.t("翻译服务", "Services"))
            Spacer()
            Menu {
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, p in
                    Button(p.name) { add(p) }
                }
                Divider()
                Button(L10n.t("空白服务", "Blank")) { add(.blank(index: e.c.providers.count + 1)) }
            } label: {
                Label(L10n.t("添加服务", "Add Service"), systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        if e.c.providers.isEmpty {
            DSEmptyState(icon: "languages", title: L10n.t("还没有翻译服务", "No translation service yet"),
                         message: L10n.t("填一个兼容 OpenAI 接口的服务就能用。API Key 只保存在本机配置文件里。",
                                         "Add any OpenAI-compatible service. The API key stays in your local config file."),
                         actionTitle: L10n.t("添加 DeepSeek", "Add DeepSeek")) { add(Self.presets[0]) }
                .dsCardBackground()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(e.c.providers.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { DSDivider() }
                    HStack(spacing: 12) {
                        DSToggle(isOn: Binding(get: { p.enabled }, set: { v in e.update { if $0.providers.indices.contains(i) { $0.providers[i].enabled = v } } }))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name.isEmpty ? L10n.t("未命名", "Untitled") : p.name).font(DS.font(13, .medium)).foregroundStyle(DS.text)
                            Text("\(p.model) · \(p.baseURL)").font(DS.small).foregroundStyle(DS.faint).lineLimit(1)
                        }
                        Spacer()
                        if let problem = Self.validate(p, requireKey: false) { DSChip(problem, tone: .danger) }
                        DSIconButton("chevron-up", size: 24) { move(i, -1) }.disabled(i == 0)
                        DSIconButton("chevron-down", size: 24) { move(i, 1) }.disabled(i == e.c.providers.count - 1)
                        DSIconButton(selected == p.id ? "chevron-right" : "pencil", help: L10n.t("编辑", "Edit"), size: 24) {
                            selected = selected == p.id ? nil : p.id
                            testText = ""
                        }
                    }
                    .padding(.horizontal, 16).frame(height: 54)
                    if selected == p.id { editor(i) }
                }
            }
            .dsCardBackground()
        }
    }

    @ViewBuilder private func editor(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            labeled(L10n.t("名称", "Name")) { DSField("DeepSeek", text: e.bind(\.providers, i, \.name)) }
            labeled("Base URL") { DSField("https://api.example.com/v1", text: e.bind(\.providers, i, \.baseURL)) }
            labeled(L10n.t("模型", "Model")) { DSField("deepseek-chat", text: e.bind(\.providers, i, \.model)) }
            labeled("API Key") { DSSecureField("sk-…", text: e.bind(\.providers, i, \.apiKey)) }
            labeled(L10n.t("深度思考", "Thinking")) {
                DSSegmented(selection: Binding(get: { e.c.providers[safe: i]?.thinking ?? "default" },
                                               set: { v in e.update { if $0.providers.indices.contains(i) { $0.providers[i].thinking = v } } }),
                            options: [("default", L10n.t("默认", "Default")), ("on", L10n.t("开启", "On")), ("off", L10n.t("关闭", "Off"))])
            }
            labeled(L10n.t("系统提示词", "System Prompt")) {
                promptEditor(Binding(get: { e.c.providers[safe: i]?.systemPrompt ?? "" },
                                     set: { v in e.update { if $0.providers.indices.contains(i) { $0.providers[i].systemPrompt = v.isEmpty ? nil : v } } }),
                             placeholder: L10n.t("留空用默认翻译提示词；可用 {$query.text}、{$query.target} 等变量",
                                                 "Empty uses the default; variables like {$query.text}, {$query.target}"))
            }
            labeled(L10n.t("用户消息模板", "User Template")) {
                promptEditor(Binding(get: { e.c.providers[safe: i]?.userPrompt ?? "" },
                                     set: { v in e.update { if $0.providers.indices.contains(i) { $0.providers[i].userPrompt = v.isEmpty ? nil : v } } }),
                             placeholder: L10n.t("留空直接发送原文", "Empty sends the text as is"))
            }
            HStack(spacing: 8) {
                DSButton(L10n.t("测试连接", "Test"), icon: "zap") { test(i) }
                if !testText.isEmpty { DSChip(testText, tone: testTone) }
                Spacer()
                DSButton(L10n.t("删除", "Delete"), icon: "trash-2", kind: .danger) {
                    let id = e.c.providers[i].id
                    selected = nil
                    e.update { $0.providers.removeAll { $0.id == id } }
                }
            }
        }
        .padding(16)
        .background(DS.surface2)
    }

    private func labeled<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(DS.caption).foregroundStyle(DS.muted).frame(width: 96, alignment: .trailing).padding(.top, 7)
            content()
        }
    }

    private func promptEditor(_ text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(DS.mono)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 72)
            if text.wrappedValue.isEmpty {
                Text(placeholder).font(DS.caption).foregroundStyle(DS.faint).padding(.horizontal, 11).padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button).strokeBorder(DS.borderStrong, lineWidth: 1))
    }

    private func add(_ p: LLMProvider) {
        var p = p
        p.id = UUID().uuidString
        e.update { $0.providers.append(p) }
        selected = p.id
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard e.c.providers.indices.contains(j) else { return }
        e.update { $0.providers.swapAt(i, j) }
    }

    private func test(_ i: Int) {
        testTask?.cancel()
        let provider = e.c.providers[i]
        if let problem = Self.validate(provider, requireKey: true) {
            testText = problem; testTone = .danger
            return
        }
        testText = L10n.t("连接中…", "Connecting…"); testTone = .neutral
        let started = Date()
        let direction = TranslateDirection(source: "auto", from: "en", target: "zh-CN", alternate: "en")
        let msg = TranslatePrompt.messages(direction, text: "Hello, world.", provider: provider)
        var got = ""
        testTask = LLMClient.stream(text: msg.user, systemPrompt: msg.system, provider: provider,
                                    timeout: min(e.c.timeout, 20), temperature: 0) { event in
            DispatchQueue.main.async {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                switch event {
                case .delta(let piece): got += piece
                case .done:
                    if got.isEmpty {
                        testText = L10n.t("连接成功，但没有返回内容 · \(ms)ms", "Connected, empty response · \(ms)ms"); testTone = .warning
                    } else {
                        testText = L10n.t("连接成功 · \(ms)ms · \(got.prefix(20))", "Connected · \(ms)ms · \(got.prefix(20))"); testTone = .success
                    }
                case .failure(let message):
                    testText = message; testTone = .danger
                }
            }
        }
    }

    static func validate(_ p: LLMProvider, requireKey: Bool) -> String? {
        if p.name.trimmingCharacters(in: .whitespaces).isEmpty { return L10n.t("名称不能为空", "Name is required") }
        guard let url = URL(string: p.baseURL.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !(url.host ?? "").isEmpty else {
            return L10n.t("Base URL 需要完整的 http(s) 地址", "Base URL must be a full http(s) URL")
        }
        if p.model.trimmingCharacters(in: .whitespaces).isEmpty { return L10n.t("模型不能为空", "Model is required") }
        if requireKey && p.apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return L10n.t("API Key 为空", "API key is empty") }
        return nil
    }
}

// MARK: - 快捷键

struct HotkeySettings: View {
    @EnvironmentObject var e: ConfigEditor
    @ObservedObject var manager = HotkeyManager.shared
    @State private var recording: String?

    var body: some View {
        Text(L10n.t("点击右侧的组合后直接按下新的快捷键；Esc 取消，⌫ 清除。录制时全局快捷键会暂停。",
                    "Click a shortcut and press the new keys; Esc cancels, ⌫ clears. Global shortcuts pause while recording."))
            .font(DS.caption).foregroundStyle(DS.muted)
        let all = manager.allBindings
        let titles = Dictionary(all.map { ($0.binding.id, $0.binding.title) }, uniquingKeysWith: { a, _ in a })
        let preview = HotkeyAnalysis.issues(all.filter(\.moduleEnabled).map { (id: $0.binding.id, spec: e.c.hotkeys[keyPath: $0.binding.keyPath]) })
        DSGroup {
            ForEach(Array(all.enumerated()), id: \.element.binding.id) { i, item in
                let b = item.binding
                if i > 0 { DSDivider() }
                let issue = item.moduleEnabled ? (preview[b.id] ?? manager.issues[b.id]) : nil
                DSSettingRow(b.title, subtitle: issue.map { HotkeyManager.describe($0, titles: titles) }
                             ?? (item.moduleEnabled ? nil : L10n.t("所属模块已关闭", "Module is off")),
                             subtitleTone: issue == nil ? nil : .danger) {
                    HotkeyRecorder(spec: e.bind((\PopBarConfig.hotkeys).appending(path: b.keyPath)),
                                   recording: Binding(get: { recording == b.id }, set: { recording = $0 ? b.id : nil }),
                                   conflict: issue != nil)
                        .opacity(item.moduleEnabled ? 1 : 0.5)
                }
            }
        }
        HStack {
            Spacer()
            DSButton(L10n.t("恢复默认", "Reset All"), kind: .ghost) { e.update { $0.hotkeys = HotkeysConfig() } }
        }
    }
}

/// 快捷键录制器：点一下进入录制，按下组合即写回；录制期间暂停全局热键
struct HotkeyRecorder: View {
    @Binding var spec: String
    @Binding var recording: Bool
    var conflict = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L10n.t("按下快捷键…", "Press keys…") : (spec.isEmpty ? L10n.t("未设置", "Not set") : KeyCombo.display(spec)))
                .font(DS.font(12, .medium).monospaced())
                .foregroundStyle(recording ? DS.accent : (conflict ? DS.danger : (spec.isEmpty ? DS.faint : DS.text)))
                .frame(minWidth: 110)
                .frame(height: 28)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(recording ? DS.accentSoft : DS.surface2))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button)
                    .strokeBorder(recording ? DS.accent : (conflict ? DS.danger : DS.borderStrong), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onDisappear { if recording { stop() } }
        .onChange(of: recording) { _, on in if !on { removeMonitor() } }
    }

    private func start() {
        recording = true
        HotkeyManager.shared.suspend()
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            switch ev.keyCode {
            case 53: stop(); return nil                       // Esc
            case 51, 117: spec = ""; stop(); return nil       // ⌫ / ⌦ 清除
            default: break
            }
            let mods = HotKeyCenter.modifiers(from: ev.modifierFlags)
            guard !mods.isEmpty else { NSSound.beep(); return nil }
            let combo = KeyCombo(modifiers: mods, keyCode: ev.keyCode)
            guard KeyCombo.names[ev.keyCode] != nil else { NSSound.beep(); return nil }
            spec = combo.spec
            stop()
            return nil
        }
    }

    private func stop() {
        removeMonitor()
        recording = false
        HotkeyManager.shared.resume()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - 按应用

struct AppRuleSettings: View {
    @EnvironmentObject var e: ConfigEditor
    @State private var editing: String?

    var body: some View {
        Text(L10n.t("给特定 App 关掉划词、只保留快捷键，或只显示指定按钮。",
                    "Turn selection off for specific apps, keep only the shortcut, or show chosen buttons."))
            .font(DS.caption).foregroundStyle(DS.muted)
        VStack(spacing: 0) {
            ForEach(Array(e.c.appRules.enumerated()), id: \.element.bundleID) { i, rule in
                if i > 0 { DSDivider() }
                HStack(spacing: 12) {
                    AppIcon(bundleID: rule.bundleID).frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.name.isEmpty ? rule.bundleID : rule.name).font(DS.font(13, .medium)).foregroundStyle(DS.text)
                        Text(rule.bundleID).font(DS.small).foregroundStyle(DS.faint)
                    }
                    Spacer()
                    DSMenuPicker(selection: e.bind(\.appRules, i, \.mode), options: [
                        (.disabled, L10n.t("不弹出", "Off")), (.hotkeyOnly, L10n.t("仅快捷键", "Shortcut only")),
                        (.custom, L10n.t("自定义按钮", "Custom buttons")),
                    ], width: 130)
                    if rule.mode == .custom {
                        DSIconButton("pencil", help: L10n.t("选择按钮", "Choose buttons"), size: 26) {
                            editing = editing == rule.bundleID ? nil : rule.bundleID
                        }
                    }
                    DSIconButton("trash-2", tint: DS.danger, size: 26) {
                        let id = rule.bundleID
                        e.update { $0.appRules.removeAll { $0.bundleID == id } }
                    }
                }
                .padding(.horizontal, 16).frame(height: 52)
                if editing == rule.bundleID && rule.mode == .custom {
                    FlowRow(spacing: 12) {
                        ForEach(BuiltinActions.catalog, id: \.id) { a in
                            HStack(spacing: 6) {
                                DSCheckbox(isOn: Binding(get: { (e.c.appRules[safe: i]?.actions.contains(a.id) ?? false) }, set: { on in
                                    e.update { c in
                                        guard c.appRules.indices.contains(i) else { return }
                                        if on { c.appRules[i].actions.append(a.id) } else { c.appRules[i].actions.removeAll { $0 == a.id } }
                                    }
                                }))
                                Text(a.title).font(DS.body).foregroundStyle(DS.text2)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.surface2)
                }
            }
            if !e.c.appRules.isEmpty { DSDivider() }
            HStack {
                DSButton(L10n.t("添加 App…", "Add App…"), icon: "plus") {
                    guard let app = FilePick.app() else { return }
                    guard !e.c.appRules.contains(where: { $0.bundleID == app.bundleID }) else { return }
                    e.update { $0.appRules.append(AppRule(bundleID: app.bundleID, name: app.name, mode: .disabled)) }
                }
                Spacer()
            }
            .padding(12)
        }
        .dsCardBackground()
    }
}

struct AppIcon: View {
    let bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Icon("app-window", size: 18)
        }
    }
}

// MARK: - 扩展

struct ExtensionSettings: View {
    @EnvironmentObject var e: ConfigEditor
    @State private var editing: String?

    var body: some View {
        Text(L10n.t("扩展是出现在浮动条「更多」面板里的自定义动作：打开网址、运行脚本或快捷指令。",
                    "Extensions are custom actions in the bar's More panel: open a URL, run a script or a Shortcut."))
            .font(DS.caption).foregroundStyle(DS.muted)
        VStack(spacing: 0) {
            ForEach(Array(e.c.extensions.enumerated()), id: \.element.id) { i, ext in
                if i > 0 { DSDivider() }
                HStack(spacing: 12) {
                    DSToggle(isOn: e.bind(\.extensions, i, \.enabled))
                    Icon(Extensions.lucideIcon(ext.symbol), size: 15)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ext.name).font(DS.font(13, .medium)).foregroundStyle(DS.text)
                        Text(ext.type.title).font(DS.small).foregroundStyle(DS.faint)
                    }
                    Spacer()
                    DSIconButton(editing == ext.id ? "chevron-up" : "pencil", size: 26) {
                        editing = editing == ext.id ? nil : ext.id
                    }
                    DSIconButton("trash-2", tint: DS.danger, size: 26) {
                        let id = ext.id
                        e.update { $0.extensions.removeAll { $0.id == id } }
                    }
                }
                .padding(.horizontal, 16).frame(height: 52)
                if editing == ext.id { editor(i) }
            }
            if !e.c.extensions.isEmpty { DSDivider() }
            HStack(spacing: 8) {
                DSButton(L10n.t("新建扩展", "New Extension"), icon: "plus") {
                    let x = ExtensionConfig(id: "ext.\(UUID().uuidString.prefix(8))", name: L10n.t("新扩展", "New Extension"),
                                            type: .url, template: "https://www.google.com/search?q={text}")
                    e.update { $0.extensions.append(x) }
                    editing = x.id
                }
                DSButton(L10n.t("恢复示例", "Restore Samples"), kind: .ghost) {
                    e.update { c in
                        for p in ExtensionConfig.presets where !c.extensions.contains(where: { $0.id == p.id }) { c.extensions.append(p) }
                    }
                }
                Spacer()
            }
            .padding(12)
        }
        .dsCardBackground()
    }

    @ViewBuilder private func editor(_ i: Int) -> some View {
        let ext = e.c.extensions[i]
        VStack(alignment: .leading, spacing: 12) {
            row(L10n.t("名称", "Name")) { DSField("", text: e.bind(\.extensions, i, \.name)) }
            row(L10n.t("类型", "Type")) {
                DSSegmented(selection: e.bind(\.extensions, i, \.type), options: ExtensionType.allCases.map { ($0, $0.title) })
            }
            switch ext.type {
            case .url:
                row(L10n.t("网址模板", "URL Template")) { DSField("https://…{text}", text: e.bind(\.extensions, i, \.template)) }
            case .shell:
                row(L10n.t("命令", "Command")) { DSField("echo \"$POPBAR_TEXT\" | …", text: e.bind(\.extensions, i, \.command)) }
                row(L10n.t("输出", "Output")) {
                    DSSegmented(selection: e.bind(\.extensions, i, \.output), options: ExtensionOutput.allCases.map { ($0, $0.title) })
                }
                row(L10n.t("超时", "Timeout")) {
                    DSNumberField(value: Binding(get: { Int(e.c.extensions[safe: i]?.timeout ?? 0) }, set: { v in e.update { if $0.extensions.indices.contains(i) { $0.extensions[i].timeout = Double(v) } } }),
                                  range: 1...120, suffix: L10n.t("秒", "s"))
                }
            case .shortcut:
                row(L10n.t("快捷指令", "Shortcut")) { DSField(L10n.t("快捷指令名称", "Shortcut name"), text: e.bind(\.extensions, i, \.shortcut)) }
                row(L10n.t("输出", "Output")) {
                    DSSegmented(selection: e.bind(\.extensions, i, \.output), options: ExtensionOutput.allCases.map { ($0, $0.title) })
                }
            }
            row(L10n.t("匹配", "Match")) { DSField(L10n.t("正则；留空表示总是显示", "Regex; empty means always"), text: e.bind(\.extensions, i, \.match)) }
            row(L10n.t("图标", "Icon")) {
                FlowRow(spacing: 6) {
                    ForEach(Extensions.iconChoices, id: \.self) { name in
                        Button { e.update { if $0.extensions.indices.contains(i) { $0.extensions[i].symbol = name } } } label: {
                            Icon(name, size: 14, color: ext.symbol == name ? DS.accent : DS.muted)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 6).fill(ext.symbol == name ? DS.accentSoft : DS.surface))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(DS.surface2)
    }

    private func row<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(DS.caption).foregroundStyle(DS.muted).frame(width: 80, alignment: .trailing).padding(.top, 7)
            content()
        }
    }
}

extension ExtensionType {
    var title: String {
        switch self {
        case .url: return L10n.t("打开网址", "Open URL")
        case .shell: return L10n.t("Shell 脚本", "Shell Script")
        case .shortcut: return L10n.t("快捷指令", "Shortcut")
        }
    }
}

extension ExtensionOutput {
    var title: String {
        switch self {
        case .none: return L10n.t("不处理", "None")
        case .replace: return L10n.t("替换原文", "Replace")
        case .copy: return L10n.t("复制", "Copy")
        case .show: return L10n.t("显示结果", "Show")
        case .panel: return L10n.t("结果卡片", "Result Card")
        }
    }
}
