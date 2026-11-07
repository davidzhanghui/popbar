import Cocoa
import SwiftUI
import AVFoundation
import PopBarCore
import PopBarPlatform
import PopBarDesign

// MARK: - 通用

struct GeneralSettings: View {
    @ObservedObject var state: DeckState
    @EnvironmentObject var e: ConfigEditor

    var body: some View {
        DSGroup {
            DSSettingRow(L10n.t("语言", "Language")) {
                DSSegmented(selection: e.bind(\.language), options: [
                    ("system", L10n.t("跟随系统", "System")), ("zh", "中文"), ("en", "English"),
                ])
            }
            DSDivider()
            DSSettingRow(L10n.t("外观", "Appearance")) {
                DSSegmented(selection: e.bind(\.appearance), options: [
                    (.system, L10n.t("跟随系统", "System")), (.light, L10n.t("浅色", "Light")), (.dark, L10n.t("深色", "Dark")),
                ])
            }
            DSDivider()
            DSSettingRow(L10n.t("登录时启动", "Launch at Login")) { DSToggle(isOn: e.bind(\.launchAtLogin)) }
            DSDivider()
            DSSettingRow(L10n.t("暂停划词", "Pause Selection"),
                         subtitle: L10n.t("暂停后选中文字不再弹出浮动条，快捷键仍可用", "Selecting text no longer shows the bar; shortcuts still work")) {
                DSToggle(isOn: e.bind(\.selectionPaused))
            }
            DSDivider()
            DSSettingRow(L10n.t("点击菜单栏图标", "Menu Bar Click"),
                         subtitle: L10n.t("右键始终弹出菜单", "Right-click always shows the menu")) {
                DSMenuPicker(selection: e.bind(\.trayClick), options: [
                    (.menu, L10n.t("弹出菜单", "Show menu")), (.deck, L10n.t("打开 Deck", "Open Deck")),
                    (.input, L10n.t("输入翻译", "Type to translate")), (.clipboard, L10n.t("翻译剪贴板", "Translate clipboard")),
                ])
            }
        }
        DSGroup {
            DSSettingRow(L10n.t("欢迎与权限", "Welcome & Permissions"),
                         subtitle: L10n.t("辅助功能、输入监控等；也可从 Deck 侧栏底部进入",
                                          "Accessibility, Input Monitoring, and more; also in the Deck sidebar footer")) {
                DSButton(L10n.t("打开", "Open")) { state.page = .welcome }
            }
            DSDivider()
            DSSettingRow(L10n.t("配置文件", "Config File"),
                         subtitle: L10n.t("可以手动编辑，保存后自动重新读取。配置文件包含 API Key，分享前请删除。",
                                          "Editable by hand; reloaded on save. It contains your API keys, so remove them before sharing.")) {
                DSButton(L10n.t("在访达中显示", "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([PopBarConfig.fileURL])
                }
            }
        }
        if let err = ConfigStore.shared.loadError {
            DSChip(err, tone: .danger, icon: "triangle-alert")
        }
    }
}

// MARK: - 划词

struct SelectionSettings: View {
    @EnvironmentObject var e: ConfigEditor

    var body: some View {
        DSGroup {
            DSSettingRow(L10n.t("触发方式", "Trigger"), subtitle: L10n.t("选中文字后怎样弹出浮动条", "How the bar appears after selecting text")) {
                DSSegmented(selection: e.bind(\.triggerMode), options: [
                    (.both, L10n.t("拖拽 + 双击", "Drag + Double-click")), (.drag, L10n.t("仅拖拽", "Drag only")),
                    (.doubleClick, L10n.t("仅双击", "Double-click only")),
                ])
            }
            DSDivider()
            DSSettingRow(L10n.t("延迟", "Delay"), subtitle: L10n.t("松开鼠标后等多久再取词", "Wait after releasing the mouse")) {
                DSNumberField(value: e.bind(\.selectionDelayMs), range: 0...1000, suffix: L10n.t("毫秒", "ms"))
            }
            DSDivider()
            DSSettingRow(L10n.t("最短字数", "Minimum Length"), subtitle: L10n.t("少于这么多字符时不弹出", "Ignore shorter selections")) {
                DSNumberField(value: e.bind(\.minChars), range: 1...50, suffix: L10n.t("个字符", "chars"))
            }
            DSDivider()
            DSSettingRow(L10n.t("剪贴板取词", "Clipboard Fallback"),
                         subtitle: L10n.t("读不到选区时模拟 ⌘C 兜底；剪贴板会被原样还原，并标记为临时写入",
                                          "Simulate ⌘C when the selection can't be read; the clipboard is restored and marked transient")) {
                DSToggle(isOn: e.bind(\.clipboardFallback))
            }
        }
        DSGroup(L10n.t("快捷键唤起", "Shortcut")) {
            DSSettingRow(L10n.t("唤起浮动条", "Show Bar"),
                         subtitle: L10n.t("键盘选中文字后按它弹出浮动条，←→ 切换、回车执行、Esc 关闭",
                                          "Press after selecting with the keyboard; ←→ to move, Return to run, Esc to close")) {
                DSKbd(KeyCombo.display(e.c.hotkeys.showBar))
            }
        }
    }
}

// MARK: - 浮动条

struct BarSettings: View {
    @EnvironmentObject var e: ConfigEditor

    /// 设置页里可排序的常用按钮（模块关闭的不列）
    private var catalog: [(id: String, title: String, icon: String)] { BuiltinActions.catalog }

    private var ordered: [ToolbarItem] {
        let ids = catalog.map(\.id)
        var items = e.c.toolbar.items.filter { ids.contains($0.id) }
        if items.isEmpty {
            items = ids.map { ToolbarItem(id: $0, visible: BuiltinActions.defaultPrimary.contains($0)) }
        } else {
            for id in ids where !items.contains(where: { $0.id == id }) { items.append(ToolbarItem(id: id, visible: false)) }
        }
        return items
    }

    var body: some View {
        DSGroup {
            DSSettingRow(L10n.t("智能胶囊", "Smart Capsule"),
                         subtitle: L10n.t("识别到链接、算式、颜色、路径等内容时，在最左侧给出一键操作", "One-tap action for links, math, colors, paths and more")) {
                DSToggle(isOn: e.bind(\.toolbar.smartCapsule))
            }
            DSDivider()
            DSSettingRow(L10n.t("搜索引擎", "Search Engine")) {
                DSSegmented(selection: e.bind(\.toolbar.searchEngine), options: SearchEngine.allCases.map { ($0, $0.title) })
            }
            DSDivider()
            DSSettingRow(L10n.t("常用按钮数量", "Primary Buttons"), subtitle: L10n.t("其余放进「更多」面板", "The rest go into More")) {
                DSNumberField(value: e.bind(\.toolbar.maxVisible), range: 1...8)
            }
            DSDivider()
            DSSettingRow(L10n.t("排序", "Order")) {
                DSSegmented(selection: e.bind(\.toolbar.order), options: [
                    (.manual, L10n.t("按下面的顺序", "As listed")), (.perApp, L10n.t("每个 App 常用的靠前", "Most used per app first")),
                ])
            }
        }
        DSGroup(L10n.t("按钮排序与显隐", "Buttons")) {
            let items = ordered
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { DSDivider() }
                let meta = catalog.first { $0.id == item.id }
                HStack(spacing: 12) {
                    DSCheckbox(isOn: Binding(get: { item.visible }, set: { v in
                        var list = items
                        list[i].visible = v
                        e.update { $0.toolbar.items = list }
                    }))
                    Icon(meta?.icon ?? "circle", size: 15)
                    Text(meta?.title ?? item.id).font(DS.body).foregroundStyle(DS.text)
                    Spacer()
                    Text(item.visible ? L10n.t("常用", "Primary") : L10n.t("更多", "More")).font(DS.small).foregroundStyle(DS.faint)
                    DSIconButton("chevron-up", size: 24) { move(items, i, -1) }.disabled(i == 0)
                    DSIconButton("chevron-down", size: 24) { move(items, i, 1) }.disabled(i == items.count - 1)
                }
                .padding(.horizontal, 16).frame(height: 44)
            }
            DSDivider()
            HStack {
                Spacer()
                DSButton(L10n.t("恢复默认", "Reset"), kind: .ghost) { e.update { $0.toolbar.items = [] } }
            }
            .padding(10)
        }
        SpeakSettings()
    }

    private func move(_ items: [ToolbarItem], _ i: Int, _ d: Int) {
        var list = items
        let j = i + d
        guard list.indices.contains(j) else { return }
        list.swapAt(i, j)
        e.update { $0.toolbar.items = list }
    }
}

struct SpeakSettings: View {
    @EnvironmentObject var e: ConfigEditor
    private let synth = AVSpeechSynthesizer()

    private var voices: [(String, String)] {
        [("", L10n.t("自动（跟随文字语言）", "Auto (follow text)"))] + AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
            .map { ($0.identifier, "\($0.name) · \($0.language)") }
    }

    var body: some View {
        DSGroup(L10n.t("朗读", "Speech")) {
            DSSettingRow(L10n.t("朗读声音", "Voice"), subtitle: L10n.t("浮动条与翻译面板共用", "Shared by the bar and translation panel")) {
                HStack(spacing: 8) {
                    DSMenuPicker(selection: e.bind(\.speak.voice), options: voices, width: 220)
                    DSButton(L10n.t("试听", "Preview"), icon: "volume-2", kind: .ghost) {
                        let u = AVSpeechUtterance(string: L10n.t("你好，这是 PopBar 的朗读声音。", "Hello, this is PopBar speaking."))
                        SpeakVoice.apply(u, fallbackLanguage: L10n.isEnglish ? "en-US" : "zh-CN")
                        synth.stopSpeaking(at: .immediate)
                        synth.speak(u)
                    }
                }
            }
            DSDivider()
            DSSettingRow(L10n.t("语速", "Rate"), subtitle: L10n.t("1.0 为系统默认", "1.0 is the system default")) {
                DSSlider(value: e.bind(\.speak.rate), range: 0.4...2.0) { String(format: "%.1f×", $0) }
            }
        }
    }
}

// MARK: - 隐私

struct PrivacySettings: View {
    @EnvironmentObject var e: ConfigEditor

    private let kinds: [(String, String)] = [
        ("phone", L10n.t("手机号", "Phone")), ("idcard", L10n.t("身份证号", "ID card")), ("bankcard", L10n.t("银行卡号", "Bank card")),
        ("email", L10n.t("邮箱", "Email")), ("apikey", "API Key"), ("privatekey", L10n.t("私钥", "Private key")),
        ("internalip", L10n.t("内网 IP", "Internal IP")),
    ]

    var body: some View {
        DSGroup(L10n.t("敏感内容守卫", "Sensitive Content")) {
            DSSettingRow(L10n.t("发给 AI 之前", "Before Sending to AI"),
                         subtitle: L10n.t("检测到手机号、密钥等内容时的处理方式", "What to do when phone numbers, keys, etc. are found")) {
                DSSegmented(selection: e.bind(\.privacy.guardMode), options: [
                    (.ask, L10n.t("询问", "Ask")), (.mask, L10n.t("自动脱敏", "Mask")), (.off, L10n.t("关闭", "Off")),
                ])
            }
            DSDivider()
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("检测这些类型", "Detect")).font(DS.font(13, .medium)).foregroundStyle(DS.text)
                FlowRow(spacing: 14) {
                    ForEach(kinds, id: \.0) { k in
                        HStack(spacing: 6) {
                            DSCheckbox(isOn: Binding(get: { e.c.privacy.types.contains(k.0) }, set: { on in
                                e.update { c in
                                    if on { if !c.privacy.types.contains(k.0) { c.privacy.types.append(k.0) } }
                                    else { c.privacy.types.removeAll { $0 == k.0 } }
                                }
                            }))
                            Text(k.1).font(DS.body).foregroundStyle(DS.text2)
                        }
                    }
                }
            }
            .padding(16)
        }
        DSGroup(L10n.t("剪贴板记录", "Clipboard History")) {
            DSSettingRow(L10n.t("记录剪贴板", "Record Clipboard"),
                         subtitle: L10n.t("密码管理器复制的内容会自动跳过", "Password-manager copies are skipped")) {
                DSToggle(isOn: e.bind(\.clipboardHistory.enabled))
            }
            DSDivider()
            DSSettingRow(L10n.t("保留条数", "Keep"), subtitle: L10n.t("最多 10 条，含置顶", "Up to 10, including pinned")) {
                DSNumberField(value: e.bind(\.clipboardHistory.limit), range: 1...10)
            }
            DSDivider()
            DSSettingRow(L10n.t("重启后保留", "Keep After Restart"),
                         subtitle: L10n.t("默认只在内存里；开启后图片以文件保存在本机", "Memory only by default; images are saved locally when on")) {
                DSToggle(isOn: e.bind(\.clipboardHistory.persist))
            }
            DSDivider()
            DSSettingRow(L10n.t("记录图片", "Images")) { DSToggle(isOn: e.bind(\.clipboardHistory.images)) }
            DSDivider()
            DSSettingRow(L10n.t("记录文件", "Files")) { DSToggle(isOn: e.bind(\.clipboardHistory.files)) }
        }
        DSGroup(L10n.t("使用统计", "Usage Stats")) {
            DSSettingRow(L10n.t("记录动作次数", "Count Actions"),
                         subtitle: L10n.t("只记次数，不记文字内容；用于按 App 排序按钮", "Counts only, never text; used to order buttons per app")) {
                HStack(spacing: 8) {
                    DSButton(L10n.t("清除", "Clear"), kind: .ghost) { UsageStats.shared.clear() }
                    DSToggle(isOn: e.bind(\.usage.enabled))
                }
            }
        }
    }
}

/// 简单的流式换行布局
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: min(width, maxW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - 模块

struct ModuleSettings: View {
    @EnvironmentObject var e: ConfigEditor
    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        Text(L10n.t("关闭的模块不出现在侧栏、浮动条和菜单里，快捷键不注册，也不在后台运行。",
                    "Disabled modules disappear from the sidebar, bar and menu; their shortcuts and background work stop."))
            .font(DS.caption).foregroundStyle(DS.muted)
        LazyVGrid(columns: cols, spacing: 12) {
            ForEach(ModuleRegistry.shared.all, id: \.id) { m in
                let on = e.c.isModuleEnabled(m.id)
                HStack(alignment: .top, spacing: 12) {
                    Icon(m.icon, size: 16, color: on ? DS.accent : DS.muted)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? DS.accentSoft : DS.surface2))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(m.title).font(DS.font(13, .medium)).foregroundStyle(DS.text)
                            if ConfigMigration.moduleDefaults[m.id] == true { DSChip(L10n.t("默认", "Default")) }
                        }
                        Text(m.summary).font(DS.caption).foregroundStyle(DS.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    DSToggle(isOn: Binding(get: { on }, set: { v in e.update { $0.modules[m.id] = v } }))
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
                .dsCardBackground()
            }
        }
    }
}

// MARK: - 待办

struct TodaySettings: View {
    @EnvironmentObject var e: ConfigEditor

    var body: some View {
        DSGroup {
            DSSettingRow(L10n.t("存放位置", "Folder"),
                         subtitle: e.c.todo.dir.isEmpty ? L10n.t("默认（Application Support）；一天一个 Markdown 文件", "Default (Application Support); one Markdown file per day")
                                                        : e.c.todo.dir) {
                HStack(spacing: 8) {
                    if !e.c.todo.dir.isEmpty { DSButton(L10n.t("恢复默认", "Default"), kind: .ghost) { e.update { $0.todo.dir = "" } } }
                    DSButton(L10n.t("选择…", "Choose…")) {
                        if let p = FilePick.directory(start: TodoStore.directory().path) { e.update { $0.todo.dir = p } }
                    }
                }
            }
            DSDivider()
            DSSettingRow(L10n.t("未完成顺延", "Carry Over"), subtitle: L10n.t("昨天没做完的自动带到今天", "Unfinished items move to today")) {
                DSToggle(isOn: e.bind(\.todo.carryOver))
            }
        }
        DSGroup(L10n.t("系统同步", "Sync")) {
            DSSettingRow(L10n.t("同步到提醒事项", "Sync with Reminders"),
                         subtitle: L10n.t("与「提醒事项」里的 PopBar 列表双向同步；首次开启会请求授权", "Two-way sync with the PopBar list in Reminders")) {
                DSToggle(isOn: Binding(get: { e.c.todo.syncReminders }, set: { v in
                    Task { @MainActor in
                        if v, !(await SystemStore.requestAccess(.reminder)) { SystemStore.showDenied(.reminder); return }
                        e.update { $0.todo.syncReminders = v }
                    }
                }))
            }
            DSDivider()
            DSSettingRow(L10n.t("专注写入日历", "Log Focus to Calendar"),
                         subtitle: L10n.t("每完成一轮专注，在日历的 PopBar 日历里记一个时间块", "Each finished focus session becomes a block in the PopBar calendar")) {
                DSToggle(isOn: Binding(get: { e.c.todo.syncCalendar }, set: { v in
                    Task { @MainActor in
                        if v, !(await SystemStore.requestAccess(.event)) { SystemStore.showDenied(.event); return }
                        e.update { $0.todo.syncCalendar = v }
                    }
                }))
            }
        }
        DSGroup(L10n.t("番茄钟", "Pomodoro")) {
            DSSettingRow(L10n.t("专注时长", "Focus")) { DSNumberField(value: e.bind(\.todo.focusMinutes), range: 1...180, suffix: L10n.t("分钟", "min")) }
            DSDivider()
            DSSettingRow(L10n.t("休息时长", "Break")) { DSNumberField(value: e.bind(\.todo.breakMinutes), range: 1...60, suffix: L10n.t("分钟", "min")) }
            DSDivider()
            DSSettingRow(L10n.t("结束提醒", "Notify"), subtitle: L10n.t("专注 / 休息结束时发系统通知", "Notify when a session ends")) {
                DSToggle(isOn: e.bind(\.todo.notify))
            }
        }
    }
}

// MARK: - 关于

struct AboutSettings: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

    var body: some View {
        DSCard {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("PopBar").font(DS.font(18, .semibold)).foregroundStyle(DS.text)
                    Text(L10n.t("划词即用的 macOS 工具条", "A selection toolbar for macOS")).font(DS.caption).foregroundStyle(DS.muted)
                    Text(L10n.t("版本 ", "Version ") + version).font(DS.small).foregroundStyle(DS.faint)
                }
                Spacer()
            }
        }
        DSGroup {
            DSSettingRow(L10n.t("配置目录", "Config Folder"), subtitle: PopBarConfig.directoryURL.path) {
                DSButton(L10n.t("打开", "Open")) { NSWorkspace.shared.open(PopBarConfig.directoryURL) }
            }
            DSDivider()
            DSSettingRow(L10n.t("项目主页", "Homepage"), subtitle: "github.com/davidzhanghui/popbar") {
                DSButton(L10n.t("访问", "Visit"), icon: "external-link", kind: .ghost) {
                    if let u = URL(string: "https://github.com/davidzhanghui/popbar") { NSWorkspace.shared.open(u) }
                }
            }
        }
    }
}
