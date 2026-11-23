import Cocoa
import SwiftUI
import PopBarCore
import PopBarDesign

/// Muse / Sparkle 2 风格的新版本就绪决策窗：
/// 非阻塞原生窗口，下载验签并解压就绪后才弹出，提供「跳过这个版本 / 退出应用时安装 / 安装并重启应用」三态分流
/// 以及就地勾选「以后自动下载并安装更新」。
@MainActor
final class UpdatePromptController {
    static let shared = UpdatePromptController()

    private var window: NSWindow?

    private init() {}

    func show() {
        guard case .ready = UpdateManager.shared.state else { return }
        if let win = window {
            NSApp.activateForUI()
            win.makeKeyAndOrderFront(nil)
            return
        }

        let view = UpdatePromptView { [weak self] in
            self?.close()
        }
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = ""
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.level = .floating
        win.setContentSize(NSSize(width: 500, height: 224))
        win.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window = nil
            }
        }
        window = win
        NSApp.activateForUI()
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }
}

private struct UpdatePromptView: View {
    @ObservedObject private var updater = UpdateManager.shared
    @State private var notesExpanded = false
    @State private var autoInstall = ConfigStore.shared.config.update.autoInstall
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if case .ready(let release, _) = updater.state {
                content(release)
            } else {
                EmptyView()
            }
        }
        .onAppear {
            autoInstall = ConfigStore.shared.config.update.autoInstall
        }
        .onReceive(NotificationCenter.default.publisher(for: ConfigStore.didChange)) { _ in
            autoInstall = ConfigStore.shared.config.update.autoInstall
        }
    }

    @ViewBuilder
    private func content(_ release: UpdateRelease) -> some View {
        let notes = release.changelogText
        let cur = UpdateManager.currentVersionString

        VStack(alignment: .leading, spacing: 16) {
            // 头部：应用图标 + 结论 + 一句话说明
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.t("新版本的 PopBar 可以安装了", "A New Version of PopBar Is Ready"))
                        .font(DS.font(16, .bold))
                        .foregroundStyle(DS.text)
                    Text(L10n.t(
                        "PopBar \(release.version) 已下载完毕并可以使用（当前 \(cur)）。要立刻安装并重启 PopBar 吗？",
                        "PopBar \(release.version) has been downloaded and verified (current \(cur)). Install and relaunch now?"
                    ))
                    .font(DS.font(13))
                    .foregroundStyle(DS.text2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            // 可折叠更新日志 + GitHub 发布页外链
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) { notesExpanded.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Text(L10n.t("查看本次更新内容", "View What's New"))
                                    .font(DS.font(12.5, .medium))
                                    .foregroundStyle(DS.text2)
                                Icon(notesExpanded ? "chevron-up" : "chevron-down", size: 13)
                                    .foregroundStyle(DS.muted)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            updater.openReleasePage(release)
                        } label: {
                            HStack(spacing: 4) {
                                Text(L10n.t("查看发布说明", "Release Notes"))
                                    .font(DS.font(12.5))
                                Icon("external-link", size: 12)
                            }
                            .foregroundStyle(DS.accent)
                        }
                        .buttonStyle(.plain)
                    }

                    if notesExpanded {
                        ScrollView {
                            Text(notes)
                                .font(DS.font(12))
                                .foregroundStyle(DS.text2)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).fill(DS.surface2))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
                    }
                }
            }

            // 就地偏好勾选框：以后自动下载并安装更新
            HStack(spacing: 8) {
                DSCheckbox(isOn: Binding(
                    get: { autoInstall },
                    set: { v in
                        autoInstall = v
                        updater.setAutoInstall(v)
                    }
                ))
                Text(L10n.t("以后自动下载并安装更新", "Automatically download and install updates in the future"))
                    .font(DS.font(13))
                    .foregroundStyle(DS.text)
                    .onTapGesture {
                        let next = !autoInstall
                        autoInstall = next
                        updater.setAutoInstall(next)
                    }
                Spacer()
            }

            // 底部三态操作按钮：左跳过、中退出时安装、右安装并重启
            HStack(spacing: 8) {
                DSButton(L10n.t("跳过这个版本", "Skip This Version"), kind: .ghost) {
                    updater.skipAvailableVersion()
                }
                Spacer()
                DSButton(
                    updater.installOnQuitArmed
                        ? L10n.t("已安排退出时安装", "Scheduled for Quit")
                        : L10n.t("退出应用时安装", "Install on Quit"),
                    kind: .secondary
                ) {
                    updater.armInstallOnQuit()
                }
                DSButton(L10n.t("安装并重启应用", "Install & Relaunch"), kind: .primary) {
                    updater.installReadyUpdate(relaunch: true)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 22)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(width: 500)
        .background(DS.surface)
    }
}
