import Cocoa
import SwiftUI

enum TVTab: String, CaseIterable {
    case remote, apps, screen, devices

    var title: String {
        switch self {
        case .remote: return L10n.t("遥控", "Remote")
        case .apps: return L10n.t("应用", "Apps")
        case .screen: return L10n.t("画面", "Screen")
        case .devices: return L10n.t("设备", "Devices")
        }
    }
    var symbol: String {
        switch self {
        case .remote: return "av.remote"
        case .apps: return "square.grid.2x2"
        case .screen: return "tv"
        case .devices: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// 电视遥控面板的状态与动作。面板可见时才轮询,关掉就停;工具条「在电视上打开」不需要面板也能直接用。
@MainActor
final class TVModel: ObservableObject {
    static let shared = TVModel()

    @Published private(set) var devices: [TVDevice] = []
    @Published var selectedID: String?
    @Published private(set) var states: [String: TVState] = [:]
    @Published var tab: TVTab = .remote
    @Published private(set) var adbPath: String?
    @Published private(set) var message: String?

    // 应用
    @Published private(set) var apps: [TVApp] = []
    @Published private(set) var appsLoading = false
    @Published var showSystemApps = false
    @Published var manageApps = false
    @Published var appQuery = ""

    // 画面
    @Published private(set) var screenshot: NSImage?
    @Published var autoShot = true
    @Published private(set) var shotError: String?

    // 发现 / 忙碌
    @Published private(set) var scanning = false
    @Published private(set) var candidates: [TVCandidate] = []
    @Published private(set) var scanned = false
    @Published private(set) var scanPhase = ""
    @Published private(set) var busy: String?
    @Published var volumeDraft: Double = 0
    @Published var draggingVolume = false

    private let store: TVStore
    private var channels: [String: TVAdb] = [:]
    private var pollTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var shotInFlight = false

    init(store: TVStore? = nil) {
        let store = store ?? TVStore.shared
        self.store = store
        devices = store.devices
        selectedID = devices.first?.id
        adbPath = TVAdbLocator.find()
    }

    var selected: TVDevice? { devices.first { $0.id == selectedID } }
    var selectedState: TVState { selectedID.flatMap { states[$0] } ?? TVState() }
    func state(of d: TVDevice) -> TVState { states[d.id] ?? TVState() }
    var adbMissing: Bool { adbPath == nil }

    var filteredApps: [TVApp] {
        let q = appQuery.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? apps : apps.filter { $0.label.localizedCaseInsensitiveContains(q) || $0.package.localizedCaseInsensitiveContains(q) }
    }

    // MARK: 生命周期

    func panelOpened() {
        adbPath = TVAdbLocator.find()
        syncDevices()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, ToolPanels.tv.isVisible else { break }
                if tick % 4 == 0 { await self.probeAll() }
                if self.tab == .screen && self.autoShot && tick % 3 == 0 { await self.refreshScreenshot() }
                tick += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self?.pollTask = nil
        }
        if tab == .apps && apps.isEmpty { Task { await refreshApps() } }
    }

    func recheckADB() {
        adbPath = TVAdbLocator.find()
        if adbMissing { flash(L10n.t("仍未找到 adb,请先在终端执行安装命令", "adb still not found; run the install command in Terminal first")) }
        else { channels.removeAll(); Task { await probeAll() } }
    }

    private func syncDevices() {
        devices = store.devices
        if selected == nil { selectedID = devices.first?.id }
    }

    func flash(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { self?.message = nil }
        }
    }

    private func fail(_ error: Error) { flash((error as? TVError)?.message ?? error.localizedDescription) }

    private func channel(for d: TVDevice) -> TVAdb? {
        guard let adb = adbPath else { return nil }
        if let c = channels[d.id], c.serial == d.serial, c.adb == adb { return c }
        let c = TVAdb(adb: adb, serial: d.serial)
        channels[d.id] = c
        return c
    }

    /// 取当前设备的通道;没有设备或没装 adb 时给出提示
    private func current() -> (TVDevice, TVAdb)? {
        guard let d = selected else { flash(L10n.t("还没有电视,先到「设备」页添加", "No TV yet — add one on the Devices tab")); return nil }
        guard let c = channel(for: d) else { flash(L10n.t("未找到 adb", "adb not found")); return nil }
        return (d, c)
    }

    // MARK: 状态

    func probeAll() async {
        let list = devices
        await withTaskGroup(of: (String, TVState).self) { group in
            for d in list {
                guard let c = channel(for: d) else { continue }
                group.addTask { (d.id, await c.probe()) }
            }
            for await (id, st) in group {
                states[id] = st
                if id == selectedID, !draggingVolume, let v = st.volume { volumeDraft = Double(v) }
            }
        }
    }

    func probeSelected() async {
        guard let (d, c) = current() else { return }
        let st = await c.probe()
        states[d.id] = st
        if !draggingVolume, let v = st.volume { volumeDraft = Double(v) }
    }

    // MARK: 遥控

    func press(_ key: String) {
        guard let (_, c) = current() else { return }
        Task {
            do { try await c.key(key) } catch { fail(error) }
            if key.hasPrefix("vol") || key == "mute" { await probeSelected() }
        }
    }

    func commitVolume() {
        guard let (_, c) = current() else { return }
        let level = Int(volumeDraft.rounded())
        Task {
            do { try await c.setVolume(level) } catch { fail(error) }
            draggingVolume = false
            await probeSelected()
        }
    }

    func sendText(_ text: String) {
        guard let (_, c) = current() else { return }
        if text.contains(where: { !$0.isASCII }) {
            flash(L10n.t("电视的 ADB 只能输入英文、数字和符号,中文已忽略", "ADB can only type ASCII; non-ASCII characters were skipped"))
        }
        Task { do { try await c.inputText(text) } catch { fail(error) } }
    }

    // MARK: 电源

    func powerToggle() {
        guard let (d, c) = current() else { return }
        let st = state(of: d)
        Task {
            if st.online {
                do { try await c.key("power") } catch { fail(error) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await probeSelected()
                return
            }
            switch d.powerMode {
            case "wol":
                guard !d.mac.isEmpty else { flash(L10n.t("缺少 MAC 地址,无法网络唤醒", "No MAC address; cannot send Wake-on-LAN")); return }
                busy = L10n.t("已发送网络唤醒,等待电视上线…", "Wake-on-LAN sent, waiting for the TV…")
                defer { busy = nil }
                for _ in 0..<15 {
                    TVDiscovery.sendWOL(mac: d.mac)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if (try? await c.ensureConnected()) != nil { await probeSelected(); return }
                }
                flash(L10n.t("网络唤醒已发送,但电视 30 秒内未上线", "Wake-on-LAN sent but the TV did not come online in 30 s"))
            case "manual":
                flash(L10n.t("这台电视不支持远程开机,请用遥控器开机", "This TV can't be powered on remotely — use its remote"))
            default:
                flash(L10n.t("电视离线:可能已深度关机或 ADB 被关闭。可在「设备」页做一次开机能力实测", "TV is offline (deep power-off, or ADB off). Run the power test on the Devices tab"))
            }
        }
    }

    func reboot() {
        guard let (_, c) = current() else { return }
        Task {
            do {
                try await c.shell("reboot", timeout: 4)
                flash(L10n.t("已发送重启指令", "Reboot sent"))
            } catch { fail(error) }
        }
    }

    /// 开机能力实测:先让电视进待机,看网络还在不在;不在再试网络唤醒。会真的把电视关一下
    func measurePower() {
        guard let (d, c) = current(), busy == nil else { return }
        Task {
            busy = L10n.t("实测中:正在让电视进入待机…", "Testing: putting the TV to standby…")
            defer { busy = nil }
            let st = await c.probe()
            guard st.online else { flash(L10n.t("电视当前不可控,请先确认电视开着且 ADB 正常", "TV is not reachable — turn it on and check ADB first")); return }
            if !st.awake { try? await c.key("power"); try? await Task.sleep(nanoseconds: 4_000_000_000) }
            try? await c.key("power")
            try? await Task.sleep(nanoseconds: 10_000_000_000)

            var mode = "manual"
            busy = L10n.t("实测中:检查待机时网络是否还通…", "Testing: is the network still up in standby?")
            let after = await c.probe()
            if after.online && !after.awake {
                mode = "standby"
                busy = L10n.t("实测中:正在唤醒…", "Testing: waking up…")
                try? await c.key("power")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            } else if !after.online {
                busy = L10n.t("实测中:待机后网络已断,尝试网络唤醒…", "Testing: network dropped; trying Wake-on-LAN…")
                for _ in 0..<15 {
                    if !d.mac.isEmpty { TVDiscovery.sendWOL(mac: d.mac) }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if (try? await c.ensureConnected()) != nil { mode = "wol"; break }
                }
            } else {
                // 没睡下去:POWER 键在这台设备上不是待机
                mode = "manual"
            }
            var nd = d
            nd.powerMode = mode
            store.update(nd)
            syncDevices()
            await probeSelected()
            let text: [String: String] = [
                "standby": L10n.t("待机可远程唤醒:开机按钮可用", "Wakes from standby remotely: power-on works"),
                "wol": L10n.t("支持网络唤醒:开机约需 10 秒", "Supports Wake-on-LAN: power-on takes ~10 s"),
                "manual": L10n.t("只能遥控器开机:远程开机不可用", "Remote power-on is not available — use the remote"),
            ]
            flash(L10n.t("实测结果:", "Result: ") + (text[mode] ?? mode))
            let recovered = await c.probe().online
            if mode == "manual" && !recovered {
                flash(L10n.t("电视没有自动恢复,请用遥控器开机", "The TV did not come back — use its remote"))
            }
        }
    }

    // MARK: 应用

    func refreshApps() async {
        guard let (_, c) = current() else { return }
        appsLoading = true
        defer { appsLoading = false }
        do { apps = try await c.listApps(includeSystem: showSystemApps) } catch { fail(error) }
    }

    func launch(_ app: TVApp) {
        guard let (_, c) = current() else { return }
        Task {
            do { try await c.launch(app.package); flash(L10n.t("已打开 \(app.label)", "Opened \(app.label)")) }
            catch { fail(error) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await probeSelected()
        }
    }

    func uninstall(_ app: TVApp) {
        guard let (_, c) = current() else { return }
        Task {
            busy = L10n.t("正在卸载 \(app.label)…", "Uninstalling \(app.label)…")
            defer { busy = nil }
            do {
                try await c.uninstall(app.package)
                apps.removeAll { $0.package == app.package }
                flash(L10n.t("已卸载 \(app.label)", "Uninstalled \(app.label)"))
            } catch { fail(error) }
        }
    }

    func install(urls: [URL]) {
        guard let (_, c) = current(), busy == nil else { return }
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        Task {
            defer { busy = nil }
            for (i, u) in files.enumerated() {
                if let bad = TVParse.validateAPK(u) { flash("\(u.lastPathComponent):\(bad)"); continue }
                busy = L10n.t("正在传输并安装 \(u.lastPathComponent)(\(i + 1)/\(files.count)),大文件需要几分钟…",
                              "Pushing and installing \(u.lastPathComponent) (\(i + 1)/\(files.count)); large files take minutes…")
                do { flash(u.lastPathComponent + " · " + (try await c.installAPK(u))) } catch { fail(error) }
            }
            await refreshApps()
        }
    }

    func chooseAPK() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.init(filenameExtension: "apk") ?? .data]
        p.message = L10n.t("选择要安装到电视的 APK", "Choose APKs to install on the TV")
        NSApp.activateForUI()
        if p.runModal() == .OK { install(urls: p.urls) }
    }

    // MARK: 画面

    func refreshScreenshot() async {
        guard !shotInFlight, let (d, c) = current(), state(of: d).online else { return }
        shotInFlight = true
        defer { shotInFlight = false }
        do {
            let data = try await c.screenshot()
            if let img = NSImage(data: data) { screenshot = img; shotError = nil }
        } catch {
            shotError = (error as? TVError)?.message ?? error.localizedDescription
        }
    }

    func saveScreenshot() {
        guard let img = screenshot, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = "tv-\(Int(Date().timeIntervalSince1970)).png"
        NSApp.activateForUI()
        if p.runModal() == .OK, let url = p.url { try? png.write(to: url) }
    }

    func copyScreenshot() {
        guard let img = screenshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        flash(L10n.t("截图已复制", "Screenshot copied"))
    }

    // MARK: 设备管理

    func select(_ d: TVDevice) {
        guard selectedID != d.id else { return }
        selectedID = d.id
        apps = []
        screenshot = nil
        shotError = nil
        if let v = states[d.id]?.volume { volumeDraft = Double(v) }
        if tab == .apps { Task { await refreshApps() } }
    }

    func scan() {
        guard !scanning else { return }
        guard let adb = adbPath else { flash(L10n.t("未找到 adb", "adb not found")); return }
        scanning = true
        scanPhase = L10n.t("准备扫描…", "Preparing…")
        Task {
            let found = await TVDiscovery.scan(adb: adb) { phase in Task { @MainActor in TVModel.shared.scanPhase = phase } }
            let known = Set(devices.map(\.ip))
            candidates = found.filter { !known.contains($0.ip) }
            scanned = true
            scanning = false
            if TVDiscovery.localNet() == nil { flash(L10n.t("没有找到可用的局域网网卡", "No usable LAN interface found")) }
        }
    }

    /// 连接并登记一台电视。首次连接电视会弹窗询问是否允许调试
    func add(ip: String, mac: String = "", hint: String = "") {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        guard TVParse.validHost(ip) else { flash(L10n.t("IP 地址格式不对", "Invalid IP address")); return }
        guard let adb = adbPath else { flash(L10n.t("未找到 adb", "adb not found")); return }
        guard busy == nil else { return }
        Task {
            busy = L10n.t("正在连接 \(ip)…首次连接请在电视上点「允许」", "Connecting to \(ip)… accept the prompt on the TV the first time")
            defer { busy = nil }
            let c = TVAdb(adb: adb, serial: "\(ip):\(TVParse.adbPort)")
            do { try await c.ensureConnected() } catch { fail(error); return }
            let id = await c.identity()
            let mac = mac.isEmpty ? (TVDiscovery.arpTable()[ip] ?? "") : mac
            let maker = id?.manufacturer ?? ""
            let model = id?.model ?? ""
            let brand = TVBrand.guess(mac: mac, texts: [maker, model, hint])
            let name = TVBrand.deviceName(friendly: hint, brand: brand, manufacturer: maker, model: model, fallback: "TV \(ip)")
            let saved = store.upsert(TVDevice(id: TVDevice.makeID(mac: mac, ip: ip), ip: ip, mac: mac, name: name,
                                              brand: brand.isEmpty ? maker.lowercased() : brand, model: model))
            syncDevices()
            selectedID = saved.id
            candidates.removeAll { $0.ip == ip }
            flash(L10n.t("已添加 \(saved.name)", "Added \(saved.name)"))
            await probeAll()
        }
    }

    func rename(_ d: TVDevice, name: String, room: String) {
        var nd = d
        nd.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? d.name : name.trimmingCharacters(in: .whitespaces)
        nd.room = room.trimmingCharacters(in: .whitespaces)
        store.update(nd)
        syncDevices()
    }

    func remove(_ d: TVDevice) {
        if let c = channels[d.id] { Task { await c.disconnect() } }
        channels[d.id] = nil
        states[d.id] = nil
        store.remove(id: d.id)
        syncDevices()
    }

    // MARK: 投屏 / 工具条联动

    /// 在指定电视上打开链接(视频直链走播放器,网页走浏览器)。面板没开也能用
    func open(url: URL, on d: TVDevice) async -> String? {
        guard let adb = adbPath ?? TVAdbLocator.find() else {
            return L10n.t("未找到 adb:请先 brew install android-platform-tools", "adb not found: run brew install android-platform-tools")
        }
        adbPath = adb
        guard let c = channel(for: d) else { return L10n.t("未找到 adb", "adb not found") }
        do {
            try await c.ensureConnected()
            // 待机中的电视先唤醒,否则命令发了但屏幕是黑的
            let st = await c.probe()
            if st.online && !st.awake { try await c.key("power"); try? await Task.sleep(nanoseconds: 2_000_000_000) }
            try await c.openURL(url)
            return nil
        } catch {
            return (error as? TVError)?.message ?? error.localizedDescription
        }
    }

    func castFromPanel(_ text: String) {
        guard let d = selected else { flash(L10n.t("还没有电视", "No TV yet")); return }
        guard let url = TVParse.castURL(text) else { flash(L10n.t("请输入 http(s) 链接", "Enter an http(s) link")); return }
        Task {
            if let err = await open(url: url, on: d) { flash(err) }
            else { flash(L10n.t("已在 \(d.name) 上打开", "Opened on \(d.name)")) }
        }
    }
}

// MARK: - 工具条联动:在电视上打开选中的链接

enum TVCast {
    @MainActor
    static func barAction(for ctx: SourceContext) -> BarAction? {
        guard TVStore.shared.hasDevices, ContextDetector.isURLLike(ctx.text.trimmingCharacters(in: .whitespacesAndNewlines)),
              TVParse.castURL(ctx.text) != nil else { return nil }
        let devices = TVStore.shared.devices
        let single = devices.count == 1
        return BarAction(
            id: "ctx.tvOpen", title: L10n.t("在电视上打开", "Open on TV"),
            symbol: "tv", color: .systemPurple,
            menu: single ? nil : { c in
                ContextMenu.build(devices.map { d in
                    ContextMenu.Item(d.title, "tv") { cast(c.text, to: d) }
                })
            }) { c in
            if let d = devices.first, single { cast(c.text, to: d) }
        }
    }

    static func cast(_ text: String, to d: TVDevice) {
        guard let url = TVParse.castURL(text) else { return }
        FloatingBarController.shared.hide()
        Task { @MainActor in
            let err = await TVModel.shared.open(url: url, on: d)
            FloatingBarController.shared.showResult(
                err ?? L10n.t("已在「\(d.title)」上打开", "Opened on “\(d.title)”"))
        }
    }
}
