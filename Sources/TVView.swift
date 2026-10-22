import SwiftUI
import Cocoa

// MARK: - 面板注册

extension ToolPanels {
    @MainActor static let tv = ToolPanel(
        title: L10n.t("电视遥控", "TV Remote"), symbol: "tv",
        size: NSSize(width: 640, height: 720),
        onShow: { TVModel.shared.panelOpened() },
        content: { AnyView(TVView(model: TVModel.shared)) })
}

// MARK: - 主视图

struct TVView: View {
    @ObservedObject var model: TVModel

    var body: some View {
        VStack(spacing: 10) {
            if model.adbMissing {
                TVInstallGuide(model: model)
            } else {
                deviceBar
                if let d = model.selected { header(d) }
                tabBar
                Group {
                    switch model.tab {
                    case .remote: TVRemoteTab(model: model)
                    case .apps: TVAppsTab(model: model)
                    case .screen: TVScreenTab(model: model)
                    case .devices: TVDevicesTab(model: model)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            if let busy = model.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 11)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(SysTheme.brand).padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PanelTheme.brandColor.opacity(0.10)))
            }
            if let m = model.message {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11))
                    Text(m).font(.system(size: 11)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(SysTheme.brand).padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PanelTheme.brandColor.opacity(0.10)))
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    private var deviceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.devices) { d in
                    let on = d.id == model.selectedID
                    let st = model.state(of: d)
                    Button { model.select(d) } label: {
                        HStack(spacing: 5) {
                            Circle().fill(st.online ? (st.awake ? Color.green : Color.orange) : Color.gray.opacity(0.6))
                                .frame(width: 7, height: 7)
                            Text(d.title).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1)
                        }
                        .foregroundStyle(on ? Color.white : SysTheme.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(on ? PanelTheme.brandColor : SysTheme.track))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                PBtn(title: L10n.t("添加电视", "Add TV"), symbol: "plus") { model.tab = .devices }
            }
            .padding(.horizontal, 2)
        }
    }

    private func header(_ d: TVDevice) -> some View {
        let st = model.selectedState
        return HStack(spacing: 10) {
            Image(systemName: "tv.fill").font(.system(size: 18)).foregroundStyle(SysTheme.brand)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SysTheme.track))
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title).font(.system(size: 14, weight: .bold)).lineLimit(1)
                Text(statusLine(d, st)).font(.system(size: 11)).foregroundStyle(SysTheme.secondary).lineLimit(1)
            }
            Spacer()
            PBadge(text: st.online ? (st.awake ? L10n.t("开机", "On") : L10n.t("待机", "Standby")) : L10n.t("离线", "Offline"),
                   color: st.online ? (st.awake ? .green : .orange) : .gray, filled: true)
        }
        .padding(10).background(CardBackground())
    }

    private func statusLine(_ d: TVDevice, _ st: TVState) -> String {
        guard st.online else { return st.error.isEmpty ? "\(d.ip) · " + L10n.t("连接中…", "Connecting…") : st.error }
        var parts = [d.ip]
        if st.awake && !st.currentLabel.isEmpty { parts.append(L10n.t("正在使用 \(st.currentLabel)", "Running \(st.currentLabel)")) }
        if let v = st.volume { parts.append(st.muted == true ? L10n.t("静音", "Muted") : L10n.t("音量 \(v)", "Vol \(v)")) }
        if !st.resolution.isEmpty { parts.append(st.resolution) }
        return parts.joined(separator: " · ")
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(TVTab.allCases, id: \.self) { t in
                let on = model.tab == t
                Button {
                    model.tab = t
                    if t == .apps && model.apps.isEmpty { Task { await model.refreshApps() } }
                    if t == .screen { Task { await model.refreshScreenshot() } }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: t.symbol).font(.system(size: 11))
                        Text(t.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                    }
                    .foregroundStyle(on ? Color.white : SysTheme.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? PanelTheme.brandColor : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SysTheme.track))
    }
}

// MARK: - 未安装 adb

struct TVInstallGuide: View {
    @ObservedObject var model: TVModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 10)
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.orange)
            Text(L10n.t("需要先安装 adb", "adb is required")).font(.system(size: 16, weight: .bold))
            Text(L10n.t("电视遥控通过 Android 调试桥(adb)控制电视。PopBar 不自带它,请在终端里执行下面的命令安装:",
                        "TV Remote controls the TV through the Android Debug Bridge (adb). PopBar doesn't bundle it — install it from Terminal:"))
                .font(.system(size: 12)).foregroundStyle(SysTheme.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(TVAdbLocator.installCommand).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                PIcon(symbol: "doc.on.doc", help: L10n.t("复制命令", "Copy command")) {
                    PasteboardGuard.write(TVAdbLocator.installCommand)
                    model.flash(L10n.t("命令已复制", "Command copied"))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).background(CardBackground())
            Text(L10n.t("没有 Homebrew?也可以装 Android Studio 的 platform-tools,PopBar 会自动识别 ~/Library/Android/sdk/platform-tools/adb。",
                        "No Homebrew? Android Studio's platform-tools works too — PopBar finds ~/Library/Android/sdk/platform-tools/adb."))
                .font(.system(size: 11)).foregroundStyle(SysTheme.tertiary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                PBtn(title: L10n.t("我已安装,重新检测", "Installed — recheck"), symbol: "arrow.clockwise", prominent: true) { model.recheckADB() }
                PBtn(title: L10n.t("打开 Homebrew 官网", "Open brew.sh"), symbol: "safari") {
                    if let u = URL(string: "https://brew.sh") { NSWorkspace.shared.open(u) }
                }
            }
            Spacer()
        }
        .frame(maxWidth: 460).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 遥控

struct TVRemoteTab: View {
    @ObservedObject var model: TVModel
    @State private var text = ""
    @State private var link = ""
    @FocusState private var padFocused: Bool

    private var online: Bool { model.selectedState.online }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if model.devices.isEmpty { emptyState } else {
                    powerRow
                    pad
                    volumeRow
                    inputRows
                    Text(L10n.t("键盘:方向键移动 · 回车确认 · 退格返回 · H 主页 · M 菜单 · 空格播放/暂停 · +/- 音量",
                                "Keys: arrows move · Return OK · Delete Back · H Home · M Menu · Space Play/Pause · +/- Volume"))
                        .font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
        .focusable().focused($padFocused).focusEffectDisabled()
        .onAppear { padFocused = true }
        .onKeyPress(phases: .down) { p in handle(p) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tv.slash").font(.system(size: 30)).foregroundStyle(SysTheme.tertiary)
            Text(L10n.t("还没有电视", "No TV yet")).font(.system(size: 14, weight: .semibold))
            Text(L10n.t("先在电视上打开 ADB 调试,再到「设备」页扫描添加。", "Enable ADB debugging on the TV, then scan on the Devices tab."))
                .font(.system(size: 11.5)).foregroundStyle(SysTheme.secondary)
            PBtn(title: L10n.t("去添加", "Add a TV"), symbol: "plus", prominent: true) { model.tab = .devices }
        }
        .padding(40)
    }

    private func handle(_ p: KeyPress) -> KeyPress.Result {
        guard model.tab == .remote, online else { return .ignored }
        let map: [(KeyEquivalent, String)] = [
            (.upArrow, "up"), (.downArrow, "down"), (.leftArrow, "left"), (.rightArrow, "right"),
            (.return, "ok"), (.delete, "back"), (.space, "play_pause"),
            (KeyEquivalent("h"), "home"), (KeyEquivalent("m"), "menu"),
            (KeyEquivalent("+"), "vol_up"), (KeyEquivalent("="), "vol_up"), (KeyEquivalent("-"), "vol_down"),
        ]
        guard let key = map.first(where: { $0.0 == p.key })?.1 else { return .ignored }
        model.press(key)
        return .handled
    }

    private func tap(_ key: String) { padFocused = true; model.press(key) }

    private var powerRow: some View {
        HStack(spacing: 8) {
            let st = model.selectedState
            PBtn(title: st.online ? (st.awake ? L10n.t("待机", "Standby") : L10n.t("唤醒", "Wake")) : L10n.t("开机", "Power on"),
                 symbol: "power", prominent: true, disabled: !st.online && (model.selected?.powerMode == "manual")) {
                model.powerToggle()
            }
            .help(model.selected?.powerMode == "manual" ? L10n.t("这台电视只能用遥控器开机", "This TV can only be powered on with its remote") : "")
            PBtn(title: L10n.t("重启", "Reboot"), symbol: "arrow.triangle.2.circlepath", destructive: true, disabled: !online) { model.reboot() }
            Spacer()
            if let d = model.selected {
                PBadge(text: powerLabel(d.powerMode), color: d.powerMode == "manual" ? .orange : SysTheme.secondary)
            }
        }
    }

    private func powerLabel(_ mode: String) -> String {
        switch mode {
        case "standby": return L10n.t("待机可唤醒", "Wakes from standby")
        case "wol": return L10n.t("支持网络唤醒", "Wake-on-LAN")
        case "manual": return L10n.t("仅遥控器开机", "Remote-only power on")
        default: return L10n.t("开机能力未测", "Power-on untested")
        }
    }

    private var pad: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                padKey("chevron.up", "up")
                HStack(spacing: 6) {
                    padKey("chevron.left", "left")
                    Button { tap("ok") } label: {
                        Text("OK").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(PanelTheme.brandColor))
                    }
                    .buttonStyle(.plain).disabled(!online).opacity(online ? 1 : 0.4)
                    padKey("chevron.right", "right")
                }
                padKey("chevron.down", "down")
            }
            HStack(spacing: 10) {
                labelKey("arrow.uturn.backward", L10n.t("返回", "Back"), "back")
                labelKey("house", L10n.t("主页", "Home"), "home")
                labelKey("line.3.horizontal", L10n.t("菜单", "Menu"), "menu")
                labelKey("info.circle", L10n.t("信息", "Info"), "info")
            }
            HStack(spacing: 10) {
                labelKey("backward.end", L10n.t("上一个", "Prev"), "prev")
                labelKey("playpause", L10n.t("播放/暂停", "Play/Pause"), "play_pause")
                labelKey("forward.end", L10n.t("下一个", "Next"), "next")
            }
        }
        .padding(14).frame(maxWidth: .infinity).background(CardBackground())
    }

    private func padKey(_ symbol: String, _ key: String) -> some View {
        Button { tap(key) } label: {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(SysTheme.brand)
                .frame(width: 64, height: 40).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SysTheme.track))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!online).opacity(online ? 1 : 0.4)
    }

    private func labelKey(_ symbol: String, _ title: String, _ key: String) -> some View {
        Button { tap(key) } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 10.5))
            }
            .foregroundStyle(SysTheme.brand).frame(width: 78, height: 44)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SysTheme.track))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!online).opacity(online ? 1 : 0.4)
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            PIcon(symbol: model.selectedState.muted == true ? "speaker.slash.fill" : "speaker.fill",
                  help: L10n.t("静音", "Mute")) { tap("mute") }
            Slider(value: $model.volumeDraft, in: 0...100, step: 1) { editing in
                model.draggingVolume = editing
                if !editing { model.commitVolume() }
            }
            .disabled(!online)
            Text("\(Int(model.volumeDraft))").font(.system(size: 12).monospacedDigit()).frame(width: 28, alignment: .trailing)
            PIcon(symbol: "minus", help: L10n.t("音量减", "Volume down")) { tap("vol_down") }
            PIcon(symbol: "plus", help: L10n.t("音量加", "Volume up")) { tap("vol_up") }
        }
        .padding(10).background(CardBackground())
    }

    private var inputRows: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard").font(.system(size: 11)).foregroundStyle(SysTheme.tertiary)
                TextField(L10n.t("向电视输入文字(仅英文 / 数字 / 符号)", "Type on the TV (ASCII only)"), text: $text)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { send() }
                PBtn(title: L10n.t("发送", "Send"), disabled: text.isEmpty || !online) { send() }
            }
            .padding(.horizontal, 10).padding(.vertical, 7).background(CardBackground())
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 11)).foregroundStyle(SysTheme.tertiary)
                TextField(L10n.t("粘贴网页或视频直链,让电视用浏览器 / 播放器打开(电视需装有对应 App)", "Paste a web page or direct video link to open on the TV (needs a browser or player app on the TV)"), text: $link)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { cast() }
                PBtn(title: L10n.t("投到电视", "Open on TV"), symbol: "tv", prominent: true,
                     disabled: link.trimmingCharacters(in: .whitespaces).isEmpty || !online) { cast() }
            }
            .padding(.horizontal, 10).padding(.vertical, 7).background(CardBackground())
        }
    }

    private func send() {
        guard !text.isEmpty else { return }
        model.sendText(text)
        text = ""
        padFocused = true
    }

    private func cast() {
        model.castFromPanel(link)
        link = ""
        padFocused = true
    }
}

// MARK: - 应用

struct TVAppsTab: View {
    @ObservedObject var model: TVModel
    @State private var dropTargeted = false
    @State private var pendingUninstall: TVApp?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(SysTheme.tertiary)
                    TextField(L10n.t("搜索应用", "Search apps"), text: $model.appQuery).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SysTheme.track))
                PBtn(title: L10n.t("安装 APK", "Install APK"), symbol: "shippingbox", prominent: true, disabled: model.busy != nil) { model.chooseAPK() }
                PBtn(title: model.manageApps ? L10n.t("完成", "Done") : L10n.t("管理", "Manage"), symbol: "slider.horizontal.3") {
                    model.manageApps.toggle()
                    pendingUninstall = nil
                }
                PIcon(symbol: "arrow.clockwise", help: L10n.t("刷新", "Refresh")) { Task { await model.refreshApps() } }
            }
            HStack(spacing: 8) {
                Toggle(L10n.t("显示系统应用", "Show system apps"), isOn: $model.showSystemApps)
                    .toggleStyle(.checkbox).font(.system(size: 11)).controlSize(.small)
                    .onChange(of: model.showSystemApps) { _, _ in Task { await model.refreshApps() } }
                Spacer()
                Text(L10n.t("\(model.filteredApps.count) 个应用 · 也可把 .apk 拖进来安装", "\(model.filteredApps.count) apps · drop an .apk here to install"))
                    .font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary)
            }
            if let app = pendingUninstall {
                HStack(spacing: 8) {
                    Image(systemName: "trash").foregroundStyle(.red)
                    Text(L10n.t("卸载「\(app.label)」?应用数据会一并删除", "Uninstall “\(app.label)”? Its data will be removed too"))
                        .font(.system(size: 11.5))
                    Spacer()
                    PBtn(title: L10n.t("取消", "Cancel")) { pendingUninstall = nil }
                    PBtn(title: L10n.t("卸载", "Uninstall"), destructive: true) { model.uninstall(app); pendingUninstall = nil }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.10)))
            }
            ScrollView {
                if model.appsLoading && model.apps.isEmpty {
                    ProgressView().padding(40)
                } else if model.filteredApps.isEmpty {
                    Text(model.selectedState.online ? L10n.t("没有应用", "No apps") : L10n.t("电视离线,无法读取应用", "TV offline — can't list apps"))
                        .font(.system(size: 12)).foregroundStyle(SysTheme.secondary).padding(40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                        ForEach(model.filteredApps) { app in tile(app) }
                    }
                    .padding(8)
                }
            }
            .background(
                CardBackground().overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        .foregroundStyle(PanelTheme.brandColor).opacity(dropTargeted ? 1 : 0)))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { model.install(urls: [url]) } }
                    }
                }
                return true
            }
        }
        .task { if model.apps.isEmpty { await model.refreshApps() } }
    }

    private func tile(_ app: TVApp) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { model.launch(app) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(app.label).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        if app.system { PBadge(text: L10n.t("系统", "System")) }
                    }
                    Text(app.package).font(.system(size: 10)).foregroundStyle(SysTheme.tertiary).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SysTheme.track))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(L10n.t("点一下在电视上打开", "Click to open on the TV"))
            if model.manageApps && !app.system {
                Button { pendingUninstall = app } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.red)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                }
                .buttonStyle(.plain).offset(x: 5, y: -5)
            }
        }
    }
}

// MARK: - 画面

struct TVScreenTab: View {
    @ObservedObject var model: TVModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Toggle(L10n.t("每 3 秒自动刷新", "Auto-refresh every 3 s"), isOn: $model.autoShot)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 11.5))
                Spacer()
                PBtn(title: L10n.t("刷新", "Refresh"), symbol: "arrow.clockwise") { Task { await model.refreshScreenshot() } }
                PBtn(title: L10n.t("复制", "Copy"), symbol: "doc.on.doc", disabled: model.screenshot == nil) { model.copyScreenshot() }
                PBtn(title: L10n.t("保存", "Save"), symbol: "square.and.arrow.down", disabled: model.screenshot == nil) { model.saveScreenshot() }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.85))
                if let img = model.screenshot {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).padding(6)
                } else {
                    Text(model.shotError ?? (model.selectedState.online ? L10n.t("正在获取画面…", "Fetching the picture…") : L10n.t("电视离线", "TV offline")))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).padding(30)
                }
            }
            .frame(maxHeight: .infinity)
            if model.screenshot != nil, let e = model.shotError {
                Text(e).font(.system(size: 10.5)).foregroundStyle(.orange)
            }
            Text(L10n.t("画面是截图,约每 3 秒一帧;电视息屏或播放受保护内容(DRM)时会失败或全黑。",
                        "The picture is a screenshot about every 3 s; it fails or goes black when the screen is off or DRM content is playing."))
                .font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary)
        }
    }
}

// MARK: - 设备

struct TVDevicesTab: View {
    @ObservedObject var model: TVModel
    @State private var manualIP = ""
    @State private var pendingRemove: TVDevice?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !model.devices.isEmpty {
                    PSection(title: L10n.t("我的电视(\(model.devices.count))", "My TVs (\(model.devices.count))")) {
                        VStack(spacing: 0) {
                            ForEach(model.devices) { d in
                                TVDeviceRow(model: model, device: d, onRemove: { pendingRemove = d })
                                if d.id != model.devices.last?.id { Divider() }
                            }
                        }
                        .background(CardBackground())
                    }
                }
                if let d = pendingRemove {
                    HStack(spacing: 8) {
                        Image(systemName: "trash").foregroundStyle(.red)
                        Text(L10n.t("从列表移除「\(d.title)」?(不会影响电视本身)", "Remove “\(d.title)” from the list? (The TV itself is unaffected)"))
                            .font(.system(size: 11.5))
                        Spacer()
                        PBtn(title: L10n.t("取消", "Cancel")) { pendingRemove = nil }
                        PBtn(title: L10n.t("移除", "Remove"), destructive: true) { model.remove(d); pendingRemove = nil }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.10)))
                }

                PSection(title: L10n.t("发现设备", "Discover"),
                         trailing: AnyView(PBtn(title: model.scanning ? L10n.t("扫描中…", "Scanning…") : L10n.t("扫描局域网", "Scan network"),
                                                symbol: "dot.radiowaves.left.and.right", prominent: true, disabled: model.scanning) { model.scan() })) {
                    discoverBody
                }

                PSection(title: L10n.t("手动添加", "Add by IP")) {
                    HStack(spacing: 8) {
                        TextField("192.168.0.109", text: $manualIP).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                            .onSubmit { addManual() }
                        PBtn(title: L10n.t("连接并添加", "Connect & add"), symbol: "plus", disabled: manualIP.isEmpty || model.busy != nil) { addManual() }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8).background(CardBackground())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("如何打开电视的 ADB 调试", "Enabling ADB debugging on the TV")).font(.system(size: 11.5, weight: .semibold))
                    Text(L10n.t("乐视:设置 → 关于 → 连续点版本号进入开发者模式 → 打开「USB 调试 / ADB 调试」。小米:设置 → 账号与安全 → ADB 调试。首次连接时电视会弹窗,点「允许」并勾选「一律允许」。",
                                "Letv: Settings → About → tap the build number repeatedly → enable USB/ADB debugging. Xiaomi: Settings → Account & Security → ADB debugging. On first connect, tap Allow (and Always allow) on the TV."))
                        .font(.system(size: 11)).foregroundStyle(SysTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SysTheme.track))
            }
            .padding(.vertical, 2)
        }
    }

    private var tvs: [TVCandidate] { model.candidates.filter { $0.kind == .tv } }
    private var pendings: [TVCandidate] { model.candidates.filter { $0.kind == .pending } }
    private var medias: [TVCandidate] { model.candidates.filter { $0.kind == .mediaOnly } }
    private var others: [TVCandidate] { model.candidates.filter { $0.kind == .otherAndroid } }

    @ViewBuilder private var discoverBody: some View {
        VStack(spacing: 8) {
            if model.scanning {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.scanPhase).font(.system(size: 11.5)) }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(CardBackground())
            } else if !model.scanned {
                Text(L10n.t("点「扫描局域网」自动找出电视:会识别每台设备的品牌和型号,只把电视列在最前面。首次扫描时 macOS 会请求「本地网络」权限,请点允许。",
                            "Tap Scan to find TVs automatically: each device's brand and model are identified and TVs are listed first. macOS asks for Local Network access on the first scan — please allow it."))
                    .font(.system(size: 11.5)).foregroundStyle(SysTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(CardBackground())
            } else {
                Text(summary).font(.system(size: 11.5, weight: .medium)).foregroundStyle(tvs.isEmpty && pendings.isEmpty ? Color.orange : SysTheme.brand)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if tvs.isEmpty && pendings.isEmpty {
                    Text(L10n.t("没有发现电视。请确认电视已开机、与 Mac 在同一 Wi-Fi/网络,并已在电视设置里打开 ADB 调试;也可以在下面手动输入电视的 IP。",
                                "No TV found. Make sure the TV is on, on the same network, with ADB debugging enabled — or enter its IP below."))
                        .font(.system(size: 11.5)).foregroundStyle(SysTheme.secondary).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(CardBackground())
                }
            }
            ForEach(tvs + pendings + medias) { c in
                TVCandidateRow(model: model, c: c)
            }
            if !others.isEmpty {
                DisclosureGroup {
                    VStack(spacing: 0) {
                        ForEach(others) { c in
                            HStack(spacing: 8) {
                                Image(systemName: "iphone").font(.system(size: 11)).foregroundStyle(SysTheme.tertiary)
                                Text([c.displayName, c.ip].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.system(size: 11.5)).foregroundStyle(SysTheme.secondary).lineLimit(1)
                                Spacer()
                                PBtn(title: L10n.t("仍然添加", "Add anyway"), disabled: model.busy != nil) { model.add(ip: c.ip, mac: c.mac, hint: c.friendlyName) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                    }
                    .background(CardBackground()).padding(.top, 4)
                } label: {
                    Text(L10n.t("其他 Android 设备(\(others.count))——看起来不是电视,已折叠", "Other Android devices (\(others.count)) — don't look like TVs, collapsed"))
                        .font(.system(size: 11.5)).foregroundStyle(SysTheme.secondary)
                }
            }
        }
    }

    private var summary: String {
        var parts = [L10n.t("找到 \(tvs.count) 台电视", "Found \(tvs.count) TV(s)")]
        if !pendings.isEmpty { parts.append(L10n.t("\(pendings.count) 台待授权", "\(pendings.count) awaiting authorization")) }
        if !medias.isEmpty { parts.append(L10n.t("\(medias.count) 台未开 ADB", "\(medias.count) without ADB")) }
        return parts.joined(separator: " · ")
    }

    private func addManual() {
        model.add(ip: manualIP)
        manualIP = ""
    }
}

/// 扫描结果里的一台设备:名字 + 品牌型号 + IP/MAC + 状态徽标,一眼看出是不是电视
private struct TVCandidateRow: View {
    @ObservedObject var model: TVModel
    let c: TVCandidate

    private var title: String {
        let n = c.displayName
        return n.isEmpty ? L10n.t("未知设备", "Unknown device") : n
    }

    private var detail: String {
        [c.brandName, c.model, c.ip, c.mac].filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: c.kind == .tv ? "tv.fill" : "tv")
                .font(.system(size: 16)).foregroundStyle(c.kind == .tv ? SysTheme.brand : SysTheme.tertiary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SysTheme.track))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    switch c.kind {
                    case .tv: PBadge(text: L10n.t("电视", "TV"), color: .green, filled: true)
                    case .pending: PBadge(text: L10n.t("待授权", "Needs approval"), color: .orange, filled: true)
                    default: PBadge(text: L10n.t("未开 ADB", "ADB off"))
                    }
                }
                Text(detail).font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary).lineLimit(1).truncationMode(.middle)
                if c.kind == .pending {
                    Text(L10n.t("ADB 在应答但还没授权这台 Mac:点「连接并授权」,然后在电视上点「允许」(勾选「一律允许」)",
                                "ADB responds but hasn't approved this Mac: tap Connect, then tap Allow (and Always allow) on the TV"))
                        .font(.system(size: 10.5)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                } else if c.kind == .mediaOnly {
                    Text(L10n.t("发现了媒体设备,但没开 ADB 调试——请在电视设置里打开后重新扫描", "Media device found, but ADB debugging is off — enable it in the TV settings and rescan"))
                        .font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if c.kind == .tv || c.kind == .pending {
                PBtn(title: c.kind == .pending ? L10n.t("连接并授权", "Connect") : L10n.t("添加", "Add"), symbol: "plus",
                     prominent: c.kind == .tv, disabled: model.busy != nil) {
                    model.add(ip: c.ip, mac: c.mac, hint: c.friendlyName)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9).background(CardBackground())
    }
}

private struct TVDeviceRow: View {
    @ObservedObject var model: TVModel
    let device: TVDevice
    let onRemove: () -> Void
    @State private var name = ""
    @State private var room = ""
    @State private var editing = false

    var body: some View {
        let st = model.state(of: device)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(st.online ? (st.awake ? Color.green : Color.orange) : Color.gray.opacity(0.6)).frame(width: 8, height: 8)
                if editing {
                    TextField(L10n.t("名称", "Name"), text: $name).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    TextField(L10n.t("房间", "Room"), text: $room).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 90)
                    PBtn(title: L10n.t("保存", "Save"), prominent: true) {
                        model.rename(device, name: name, room: room)
                        editing = false
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.title).font(.system(size: 12.5, weight: .medium))
                        Text([device.ip, device.mac, device.model].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary).lineLimit(1)
                    }
                    Spacer()
                    PIcon(symbol: "pencil", help: L10n.t("改名 / 房间", "Rename / room")) {
                        name = device.name
                        room = device.room
                        editing = true
                    }
                    PIcon(symbol: "trash", help: L10n.t("移除", "Remove"), tint: .red, action: onRemove)
                }
            }
            if !editing {
                HStack(spacing: 8) {
                    PBadge(text: powerText)
                    Spacer()
                    PBtn(title: L10n.t("实测开机能力", "Test power-on"), symbol: "bolt.badge.clock",
                         disabled: !st.online || model.busy != nil || device.id != model.selectedID) { confirmTest() }
                        .help(device.id == model.selectedID ? "" : L10n.t("先在上方选中这台电视", "Select this TV above first"))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var powerText: String {
        switch device.powerMode {
        case "standby": return L10n.t("待机可远程唤醒", "Wakes from standby remotely")
        case "wol": return L10n.t("支持网络唤醒", "Supports Wake-on-LAN")
        case "manual": return L10n.t("只能用遥控器开机", "Remote-only power on")
        default: return L10n.t("开机能力未测", "Power-on untested")
        }
    }

    /// 实测会真的把电视关一下,先确认
    private func confirmTest() {
        let a = NSAlert()
        a.messageText = L10n.t("实测开机能力?", "Test power-on?")
        a.informativeText = L10n.t("会让电视进入待机,再尝试远程唤醒(约 1 分钟)。请确认人在电视旁、手边有遥控器。",
                                   "The TV will go to standby and PopBar will try to wake it remotely (about a minute). Keep the TV's remote at hand.")
        a.addButton(withTitle: L10n.t("开始实测", "Start"))
        a.addButton(withTitle: L10n.t("取消", "Cancel"))
        NSApp.activateForUI()
        if a.runModal() == .alertFirstButtonReturn { model.measurePower() }
    }
}
