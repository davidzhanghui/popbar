import Cocoa
import SwiftUI
import AVFoundation
import EventKit
import PopBarCore
import PopBarPlatform
import PopBarDesign

/// 权限的当前状态与申请方式。只列已开启模块真正需要的权限；辅助功能是划词的前提，总是列出。
@MainActor
enum PermissionCheck {
    static func title(_ k: PermissionKind) -> String {
        switch k {
        case .accessibility: return L10n.t("辅助功能", "Accessibility")
        case .screenRecording: return L10n.t("屏幕录制", "Screen Recording")
        case .reminders: return L10n.t("提醒事项", "Reminders")
        case .calendar: return L10n.t("日历", "Calendars")
        case .localNetwork: return L10n.t("本地网络", "Local Network")
        case .microphone: return L10n.t("麦克风", "Microphone")
        case .camera: return L10n.t("摄像头", "Camera")
        }
    }

    static func reason(_ k: PermissionKind) -> String {
        switch k {
        case .accessibility: return L10n.t("读取选中的文字、替换原文。没有它浮动条无法工作。", "Read and replace selected text. The bar can't work without it.")
        case .screenRecording: return L10n.t("截屏、录屏和截图 OCR。", "Screenshots, recordings and screenshot OCR.")
        case .reminders: return L10n.t("今日待办与提醒事项双向同步。", "Two-way sync between To-Do and Reminders.")
        case .calendar: return L10n.t("把完成的专注记到日历。", "Log finished focus sessions to Calendar.")
        case .localNetwork: return L10n.t("扫描并连接局域网里的电视。", "Find and connect to TVs on your network.")
        case .microphone: return L10n.t("录屏时录入麦克风声音。", "Record your voice with screen recordings.")
        case .camera: return L10n.t("录屏时的摄像头画中画。", "Camera overlay in recordings.")
        }
    }

    static func icon(_ k: PermissionKind) -> String {
        switch k {
        case .accessibility: return "text-cursor-input"
        case .screenRecording: return "monitor"
        case .reminders: return "list-checks"
        case .calendar: return "calendar"
        case .localNetwork: return "wifi"
        case .microphone: return "mic"
        case .camera: return "camera"
        }
    }

    /// nil 表示无法预先判断（本地网络只在第一次连接时由系统询问）
    static func granted(_ k: PermissionKind) -> Bool? {
        switch k {
        case .accessibility: return AXSupport.isTrusted
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .reminders: return SystemStore.hasAccess(.reminder)
        case .calendar: return SystemStore.hasAccess(.event)
        case .localNetwork: return nil
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }

    static func request(_ k: PermissionKind) async {
        switch k {
        case .accessibility:
            _ = AXSupport.promptIfNeeded()
            AppRouter.openAccessibilitySettings()
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { AppRouter.openPrivacyPane("Privacy_ScreenCapture") }
        case .reminders:
            if !(await SystemStore.requestAccess(.reminder)) { SystemStore.showDenied(.reminder) }
        case .calendar:
            if !(await SystemStore.requestAccess(.event)) { SystemStore.showDenied(.event) }
        case .localNetwork:
            AppRouter.openPrivacyPane("Privacy_LocalNetwork")
        case .microphone:
            _ = await MicPermission.ensure()
        case .camera:
            _ = await CameraPermission.ensure()
        }
    }

    static var needed: [PermissionKind] {
        var list: [PermissionKind] = [.accessibility]
        for k in ModuleRegistry.shared.requiredPermissions where !list.contains(k) { list.append(k) }
        return list
    }
}

/// 欢迎与权限页：首次启动自动打开；之后从「设置 → 通用」进来
struct WelcomePage: View {
    @ObservedObject var state: DeckState
    @State private var refresh = 0
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        DSPageShell(L10n.t("欢迎使用 PopBar", "Welcome to PopBar"),
                    subtitle: L10n.t("选中文字就弹出工具条：复制、翻译、搜索、朗读、加入待办。", "Select text and a toolbar appears: copy, translate, search, speak, add to To-Do.")) {
            DSButton(L10n.t("开始使用", "Get Started"), icon: "arrow-right", kind: .primary) { finish() }
        } content: {
            HStack(spacing: 12) {
                tip("text-cursor", L10n.t("划词", "Select"), L10n.t("在任何 App 里拖选或双击文字", "Drag or double-click text in any app"))
                tip("keyboard", KeyCombo.display(ConfigStore.shared.config.hotkeys.showBar), L10n.t("用键盘选中后按它唤起", "Summon after selecting with the keyboard"))
                tip("layout-grid", KeyCombo.display(ConfigStore.shared.config.hotkeys.deck), L10n.t("打开 Deck：工具与设置都在这里", "Open the Deck: tools and settings"))
            }
            DSEyebrow(L10n.t("权限", "Permissions"))
            VStack(spacing: 0) {
                ForEach(Array(PermissionCheck.needed.enumerated()), id: \.element) { i, k in
                    if i > 0 { DSDivider() }
                    permissionRow(k)
                }
            }
            .dsCardBackground()
            .id(refresh)
            Text(L10n.t("PopBar 不联网收集任何数据；翻译请求只发给你自己配置的服务。",
                        "PopBar collects nothing; translation requests go only to services you configure."))
                .font(DS.caption).foregroundStyle(DS.muted)
        }
        .onReceive(timer) { _ in refresh &+= 1 }
    }

    private func tip(_ icon: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Icon(icon, size: 18, color: DS.accent)
            Text(title).font(DS.font(14, .semibold)).foregroundStyle(DS.text)
            Text(text).font(DS.caption).foregroundStyle(DS.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .dsCardBackground()
    }

    private func permissionRow(_ k: PermissionKind) -> some View {
        let granted = PermissionCheck.granted(k)
        return HStack(spacing: 12) {
            Icon(PermissionCheck.icon(k), size: 16, color: granted == true ? DS.success : DS.muted)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(granted == true ? DS.successSoft : DS.surface2))
            VStack(alignment: .leading, spacing: 2) {
                Text(PermissionCheck.title(k)).font(DS.font(13, .medium)).foregroundStyle(DS.text)
                Text(PermissionCheck.reason(k)).font(DS.caption).foregroundStyle(DS.muted)
            }
            Spacer()
            switch granted {
            case .some(true): DSChip(L10n.t("已授权", "Granted"), tone: .success, icon: "check")
            case .some(false): DSButton(L10n.t("去授权", "Allow"), kind: .primary) { Task { await PermissionCheck.request(k) } }
            case .none: DSChip(L10n.t("首次使用时询问", "Asked on first use"))
            }
        }
        .padding(.horizontal, 16).frame(height: 62)
    }

    private func finish() {
        if !ConfigStore.shared.config.onboarded {
            var c = ConfigStore.shared.config
            c.onboarded = true
            try? ConfigStore.shared.save(c)
        }
        state.page = ModuleRegistry.shared.enabled.first.map { .module($0.id) } ?? .settings
    }
}
