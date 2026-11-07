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
        didSet { if oldValue != page { DeckController.shared.pageChanged(from: oldValue, to: page) } }
    }
    @Published var settings: SettingsSection = .general
    /// 侧栏角标等需要定期刷新的东西
    @Published var tick = 0
}

/// Deck 主窗口：取代所有 ToolPanel 浮窗和两个设置窗口。
/// 普通 NSWindow + 透明标题栏；默认 980×660，最小 820×520，记住位置和大小。
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
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

    var body: some View {
        HStack(spacing: 0) {
            DeckSidebar(state: state, registry: registry)
                .frame(width: 220)
            Rectangle().fill(DS.border).frame(width: 1)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 40)   // 红绿灯
            brand.padding(.horizontal, 16).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(DeckGroup.allCases, id: \.self) { g in
                        let mods = registry.enabled.filter { $0.group == g }
                        if !mods.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                DSEyebrow(g.title).padding(.horizontal, 12).padding(.bottom, 4)
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
                .padding(.horizontal, 8)
                .id(state.tick)
            }
            Spacer(minLength: 0)
            Rectangle().fill(DS.border).frame(height: 1).padding(.horizontal, 12)
            SidebarRow(icon: "settings", title: L10n.t("设置", "Settings"), badge: nil,
                       selected: state.page == .settings) { state.page = .settings }
                .padding(8)
        }
        .background(DS.bg)
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
                Text(title).font(DS.font(13, selected ? .medium : .regular)).foregroundStyle(DS.text)
                Spacer()
                if let badge { Text("\(badge)").font(DS.small).foregroundStyle(DS.faint).monospacedDigit() }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button)
                .fill(selected ? DS.surface : (hovering ? DS.hover : .clear))
                .shadow(color: selected ? DS.shadow.opacity(0.5) : .clear, radius: 1.5, y: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
