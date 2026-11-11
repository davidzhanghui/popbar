import Cocoa
import SwiftUI
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// Deck 的页面
enum DeckPage: Hashable {
    case welcome
    case module(String)
    case settings
}

/// Deck 的导航状态
@MainActor
final class DeckState: ObservableObject {
    @Published var page: DeckPage = .module("today") {
        didSet {
            if page != .settings { returnPage = page }
            if oldValue != page { DeckController.shared.pageChanged(from: oldValue, to: page) }
        }
    }
    /// 设置模式下侧栏「返回」回到的页面（最近一次停留的非设置页）
    var returnPage: DeckPage = .module("today")
    @Published var settings: SettingsSection = .general
    /// 侧栏角标等需要定期刷新的东西
    @Published var tick = 0
}

/// Deck 主窗口：取代所有 ToolPanel 浮窗和两个设置窗口。
/// 普通 NSWindow（Esc 关闭）+ 透明标题栏；默认 980×660，最小 820×520，记住位置和大小。
@MainActor
final class DeckController: NSObject, NSWindowDelegate {
    static let shared = DeckController()

    let state = DeckState()
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { window?.isVisible ?? false }
    var windowNumber: Int { window?.windowNumber ?? 0 }
    var frame: CGRect { window?.frame ?? .zero }

    /// 指定页面当前是否正显示在前台（打印 / 电视的轮询据此决定是否继续）
    func isShowing(_ page: DeckPage) -> Bool { isVisible && state.page == page }
    func isShowing(module id: String) -> Bool { isShowing(.module(id)) }

    func show(page: DeckPage? = nil, settings: SettingsSection? = nil) {
        if let settings { state.settings = settings }
        let w = window ?? makeWindow()
        window = w
        let wasVisible = w.isVisible
        if let page { state.page = resolve(page) } else { state.page = resolve(state.page) }
        if !wasVisible { moduleFor(state.page)?.pageDidAppear() }
        // 菜单栏菜单的 action 在菜单收起的瞬间同步执行，此时激活 accessory 应用会被系统吞掉，
        // 表现为「点设置没反应、要点好几次」。放到下一个 runloop，并在没成功时强制补一次。
        presentWindow(w)
        DispatchQueue.main.async { [weak self, weak w] in
            guard let self, let w else { return }
            self.presentWindow(w)
            if !NSApp.isActive || !w.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil) // popbar:no-activate 上一行已强制激活
            }
            if ProcessInfo.processInfo.environment["POPBAR_DEBUG"] != nil {
                NSLog("[Deck] show page=%@ active=%d key=%d visible=%d", String(describing: self.state.page),
                      NSApp.isActive ? 1 : 0, w.isKeyWindow ? 1 : 0, w.isVisible ? 1 : 0)
            }
        }
    }

    private func presentWindow(_ w: NSWindow) {
        NSApp.activateForUI()
        w.makeKeyAndOrderFront(nil)
    }

    /// 快捷键 ⌃⌥D：打开或关闭
    func toggle() {
        if isVisible && (window?.isKeyWindow ?? false) { close() } else { show() }
    }

    /// 打印 / 电视等快捷键：正显示这一页就关，否则切过去
    func toggle(page: DeckPage) {
        if isShowing(page) && (window?.isKeyWindow ?? false) { close() } else { show(page: page) }
    }

    func close() { window?.performClose(nil) }

    /// 关闭的模块不显示：落到第一个开启的模块或设置
    private func resolve(_ page: DeckPage) -> DeckPage {
        if case .module(let id) = page, !ModuleRegistry.shared.isEnabled(id) {
            return ModuleRegistry.shared.enabled.first.map { .module($0.id) } ?? .settings
        }
        return page
    }

    /// 模块被关闭时，若正停在它的页面就切走
    func modulesChanged() {
        let fixed = resolve(state.page)
        if fixed != state.page { state.page = fixed }
        state.tick &+= 1
    }

    private func moduleFor(_ page: DeckPage) -> PopBarModule? {
        if case .module(let id) = page { return ModuleRegistry.shared.module(id) }
        return nil
    }

    /// 页面生命周期：离开监控页停采样、离开打印页停刷新
    fileprivate func pageChanged(from old: DeckPage, to new: DeckPage) {
        guard isVisible else { return }
        moduleFor(old)?.pageDidDisappear()
        moduleFor(new)?.pageDidAppear()
    }

    func windowWillClose(_ notification: Notification) {
        moduleFor(state.page)?.pageDidDisappear()
    }

    private func makeWindow() -> NSWindow {
        let w = EscClosableWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = false
        w.minSize = NSSize(width: 820, height: 520)
        w.isReleasedWhenClosed = false
        w.backgroundColor = Theme.bg
        w.title = "PopBar"
        w.delegate = self
        w.contentView = NSHostingView(rootView: DeckRootView(state: state, registry: ModuleRegistry.shared))
        w.center()
        w.setFrameAutosaveName("PopBarDeck")
        // 侧栏角标（待办数、剪贴板条数）随数据变化刷新
        let nc = NotificationCenter.default
        for name in [TodoStore.changed, Notification.Name("PopBarClipboardHistoryChanged"), ConfigStore.didChange] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.state.tick &+= 1 }
            })
        }
        return w
    }
}

// MARK: - 根视图

struct DeckRootView: View {
    @ObservedObject var state: DeckState
    @ObservedObject var registry: ModuleRegistry
    @AppStorage("deck.sidebarWidth") private var sidebarWidthStorage = 220.0

    private var sidebarWidth: Binding<CGFloat> {
        Binding(get: { CGFloat(sidebarWidthStorage) },
                set: { sidebarWidthStorage = Double($0.rounded()) })
    }

    var body: some View {
        HStack(spacing: 0) {
            DeckSidebar(state: state, registry: registry)
                .frame(width: sidebarWidth.wrappedValue)
            DSColumnResize(width: sidebarWidth, range: 160...280)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.bg)
        .tint(DS.accent)
        .ignoresSafeArea()
    }

    @ViewBuilder private var content: some View {
        switch state.page {
        case .welcome:
            WelcomePage(state: state)
        case .settings:
            SettingsPage(state: state)
        case .module(let id):
            if let m = registry.module(id), registry.isEnabled(id) {
                m.page().id(id)
            } else {
                SettingsPage(state: state)
            }
        }
    }
}

struct DeckSidebar: View {
    @ObservedObject var state: DeckState
    @ObservedObject var registry: ModuleRegistry

    /// 两栏布局：进入设置后，侧栏整体切换成设置的分组导航，「返回」回到之前的页面
    private var inSettings: Bool { state.page == .settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 40)   // 红绿灯
            Group {
                if inSettings { settingsHeader } else { brand }
            }
            .frame(height: 36, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 14)
            ScrollView {
                Group {
                    if inSettings { settingsNav } else { moduleNav }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .id(state.tick)
            }
            .id(inSettings)
            .transition(.opacity)
            Spacer(minLength: 0)
            Rectangle().fill(DS.border).frame(height: 1).padding(.horizontal, 12)
            VStack(spacing: 2) {
                if inSettings {
                    SidebarRow(icon: SettingsSection.about.icon, title: SettingsSection.about.title, badge: nil,
                               selected: state.settings == .about) { state.settings = .about }
                } else {
                    // 欢迎与权限：侧栏常驻入口；缺辅助功能/输入监控时用角标提醒
                    SidebarRow(icon: missingCriticalPermissions > 0 ? "shield-alert" : "shield-check",
                               title: L10n.t("欢迎与权限", "Welcome & Permissions"),
                               badge: missingCriticalPermissions > 0 ? missingCriticalPermissions : nil,
                               selected: state.page == .welcome) { state.page = .welcome }
                    SidebarRow(icon: "settings", title: L10n.t("设置", "Settings"), badge: nil,
                               selected: false) { state.page = .settings }
                }
            }
            .padding(8)
            .id(state.tick)
        }
        .background(DS.bg)
        .animation(.easeOut(duration: 0.16), value: inSettings)
    }

    private var moduleNav: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(DeckGroup.allCases, id: \.self) { g in
                let mods = registry.enabled.filter { $0.group == g }
                if !mods.isEmpty {
                    SidebarSection(title: g.title) {
                        ForEach(mods, id: \.id) { m in
                            SidebarRow(icon: m.icon, title: m.title, badge: m.badge,
                                       selected: state.page == .module(m.id)) {
                                state.page = .module(m.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var settingsNav: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(SettingsGroup.allCases, id: \.self) { g in
                SidebarSection(title: g.title) {
                    ForEach(g.sections) { s in
                        SidebarRow(icon: s.icon, title: s.title, badge: nil, selected: state.settings == s) {
                            state.settings = s
                        }
                    }
                }
            }
        }
    }

    /// 设置模式的侧栏页头：返回按钮 + 「设置」
    private var settingsHeader: some View {
        SidebarBackButton(title: L10n.t("设置", "Settings")) {
            state.page = state.returnPage == .settings ? .module("today") : state.returnPage
        }
    }

    /// 划词必备权限缺失数（辅助功能、输入监控）
    private var missingCriticalPermissions: Int {
        [PermissionKind.accessibility, .inputMonitoring]
            .filter { PermissionCheck.granted($0) == false }
            .count
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("PopBar").font(DS.font(15, .semibold)).foregroundStyle(DS.text)
                Text(L10n.t("划词 · 工具箱", "Selection · Toolbox")).font(DS.small).foregroundStyle(DS.muted)
            }
        }
    }
}

/// 侧栏里的一组：小标题 + 若干行
struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DS.font(11, .semibold))
                .foregroundStyle(DS.faint)
                .padding(.horizontal, 12).padding(.bottom, 4)
            content
        }
    }
}

/// 设置模式侧栏顶部的返回按钮
struct SidebarBackButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon("chevron-left", size: 15, color: hovering ? DS.text : DS.muted)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? DS.hover : DS.surface2))
                Text(title).font(DS.font(15, .semibold)).foregroundStyle(DS.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L10n.t("返回", "Back"))
    }
}

struct SidebarRow: View {
    let icon: String
    let title: String
    let badge: Int?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(icon, size: 15, color: selected ? DS.accent : DS.muted)
                Text(title).font(DS.font(13, selected ? .medium : .regular)).foregroundStyle(DS.text).lineLimit(1)
                Spacer(minLength: 4)
                if let badge { Text("\(badge)").font(DS.small).foregroundStyle(DS.faint).monospacedDigit() }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button)
                .fill(selected ? DS.surface : (hovering ? DS.hover : .clear))
                .shadow(color: selected ? DS.shadow.opacity(0.5) : .clear, radius: 1.5, y: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
