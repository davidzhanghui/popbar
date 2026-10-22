import Cocoa

/// 电视遥控的测试:解析 / 报错翻译 / 网络与 ARP / 投屏命令 / APK 校验 / 设备注册表 / 快捷键 / ADB 定位。
/// 纯逻辑,不连任何真实设备。用到的 expect / expectEqual / section 在 main.swift 里。

@MainActor
func runTVTests() async {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("popbar-tv-\(UUID().uuidString)")
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    section("电视 · 快捷键")
    let hk = HotkeysConfig()
    expectEqual(hk.tv, "ctrl+opt+v", "默认快捷键")
    expect(Hotkey.parse(hk.tv) != nil, "默认快捷键可解析")
    expect(![hk.showBar, hk.history, hk.snap, hk.record, hk.recordPause, hk.recordMarker, hk.todo, hk.printPanel].contains(hk.tv), "不与其它默认快捷键冲突")
    var cfg = PopBarConfig(); cfg.hotkeys.tv = "ctrl+opt+k"
    let back = try? JSONDecoder().decode(PopBarConfig.self, from: JSONEncoder().encode(cfg))
    expectEqual(back?.hotkeys.tv, "ctrl+opt+k", "快捷键往返编码")
    let legacy = try? JSONDecoder().decode(HotkeysConfig.self, from: Data(#"{"snap":"ctrl+opt+p"}"#.utf8))
    expectEqual(legacy?.tv, "ctrl+opt+v", "旧配置缺字段时回落默认")

    section("电视 · 输出解析")
    let blocks = TVParse.splitBlocks("""
    =POWER=
      mWakefulness=Awake
    =ACT=
      mResumedActivity: ActivityRecord{1 u0 com.stv.screenflyter/.Main t5}
      mLastPausedActivity: ActivityRecord{2 u0 com.cibn.tv/.HomeActivity t6}
    =VOL=
    STREAM_MUSIC:
       Muted: false
       Current: 2 (speaker): 15
    =SIZE=
    Physical size: 1920x1080
    """)
    expectEqual(Set(blocks.keys), ["POWER", "ACT", "VOL", "SIZE"], "分块标记")
    expect((blocks["POWER"] ?? "").contains("mWakefulness=Awake"), "POWER 块内容")
    expectEqual(TVParse.pickForeground(blocks["ACT"] ?? ""), "com.cibn.tv", "跳过空转服务取真正的前台应用")
    expectEqual(TVParse.extractPackage("ActivityRecord{1 u0 com.foo.bar/.Main t5}"), "com.foo.bar", "抠包名")
    expectEqual(TVParse.extractPackage("没有包名"), "", "无包名返回空")
    let vol = TVParse.parseVolume(blocks["VOL"] ?? "")
    expectEqual(vol.volume, 15, "speaker 音量")
    expectEqual(vol.muted, false, "静音状态")
    expectEqual(TVParse.parseVolume("streamVolume:7").volume, 7, "streamVolume 写法")
    expectEqual(TVParse.parseVolume("Muted: true").muted, true, "静音 true")
    expectEqual(TVParse.parseVolume("nothing").volume, nil, "无音量信息")
    expect(TVParse.isLauncher("com.letv.combine"), "识别桌面包名")
    expect(!TVParse.isLauncher("com.cibn.tv"), "普通应用不是桌面")
    expectEqual(TVParse.label(for: "com.cibn.tv"), "优酷 TV", "包名映射中文名")
    expectEqual(TVParse.label(for: "com.unknown.app"), "com.unknown.app", "未知包名原样显示")
    let pkgs = TVParse.parsePackages("""
    package:/data/app/x/base.apk=com.foo.a uid:10058
    package:com.foo.b
    package:/data/app/y/base.apk=com.foo.c
    garbage line
    package:com.foo.b
    """)
    expectEqual(pkgs, ["com.foo.a", "com.foo.b", "com.foo.c"], "pm list packages 三种格式 + 去重 + 排序")
    let props = TVParse.parseGetprop("G55ES\nLetv\nmaple\n")
    expectEqual(props.model, "G55ES", "getprop model")
    expectEqual(props.manufacturer, "Letv", "getprop manufacturer")
    expect(TVParse.validPackage("com.foo.bar_1"), "合法包名")
    expect(!TVParse.validPackage("com.foo;rm -rf /"), "包名含 shell 元字符被拒")
    expect(!TVParse.validPackage("1com.foo"), "包名不能数字开头")

    section("电视 · 设备识别")
    expectEqual(TVParse.parseGetprop("G55ES\nLetv\nmaple\ntv,default\n").characteristics, "tv,default", "getprop 第四行 characteristics")
    expectEqual(TVParse.parseGetprop("a\nb\nc").characteristics, "", "缺第四行时为空")
    expectEqual(TVBrand.guess(mac: "bc:6b:ff:30:e3:1c", texts: []), "letv", "OUI 认乐视")
    expectEqual(TVBrand.guess(mac: "", texts: ["Xiaomi", "MiTV-AESP0"]), "xiaomi", "关键字认小米")
    expectEqual(TVBrand.guess(mac: "06:b7:2d:d6:19:65", texts: ["", ""]), "", "随机 MAC 且无信息 → 未知")
    expectEqual(TVBrand.displayName("letv"), "乐视", "品牌中文名")
    expectEqual(TVBrand.deviceName(friendly: "", brand: "letv", manufacturer: "Letv", model: "G55ES", fallback: "x"), "乐视 G55ES", "品牌 + 型号命名")
    expectEqual(TVBrand.deviceName(friendly: "客厅电视", brand: "letv", manufacturer: "", model: "G55ES", fallback: "x"), "客厅电视", "友好名优先")
    expectEqual(TVBrand.deviceName(friendly: "乐视", brand: "letv", manufacturer: "", model: "G55ES", fallback: "x"), "乐视 G55ES", "纯品牌名补型号")
    expectEqual(TVBrand.deviceName(friendly: "", brand: "", manufacturer: "", model: "", fallback: "TV 1.2.3.4"), "TV 1.2.3.4", "全空用兜底")
    expectEqual(TVBrand.deviceName(friendly: "", brand: "", manufacturer: "Acme", model: "X1", fallback: ""), "Acme X1", "未知品牌用厂商名")
    expect(TVBrand.looksLikeTV(characteristics: "tv,default", brand: "", model: ""), "characteristics 含 tv → 电视")
    expect(!TVBrand.looksLikeTV(characteristics: "phone", brand: "xiaomi", model: "Redmi Note"), "手机不是电视")
    expect(!TVBrand.looksLikeTV(characteristics: "default", brand: "xiaomi", model: "Mi 13"), "小米手机不因品牌当电视")
    expect(TVBrand.looksLikeTV(characteristics: "", brand: "", model: "MiTV-AESP0"), "型号带 TV → 电视")
    expect(TVBrand.looksLikeTV(characteristics: "default", brand: "letv", model: "G55ES"), "电视专营品牌 → 电视")
    expect(TVBrand.looksLikeNonTVMedia("TP-Link Wireless Router"), "路由器被剔除")
    expect(!TVBrand.looksLikeNonTVMedia("客厅电视"), "电视不被剔除")
    expect(TVKind.tv < TVKind.pending && TVKind.pending < TVKind.otherAndroid && TVKind.otherAndroid < TVKind.mediaOnly, "电视排在最前")
    let pkt = TVParse.adbConnectPacket()
    expectEqual(pkt.count, 24 + 7, "CNXN 报文长度")
    expectEqual(Array(pkt.prefix(4)), Array("CNXN".utf8), "CNXN 命令字")
    expect(TVParse.isADBReply(Data(pkt.prefix(24))), "自己的 CNXN 头能通过校验")
    var authHdr = Data(Array("AUTH".utf8) + [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    authHdr.append(contentsOf: [0xBE, 0xAA, 0xAB, 0xB7])   // ~"AUTH"
    expect(TVParse.isADBReply(authHdr), "AUTH 应答被认出")
    expect(!TVParse.isADBReply(Data(repeating: 0, count: 24)), "全零头不是 ADB")
    expect(!TVParse.isADBReply(Data("HTTP/1.1 400 Bad Request\r\n".utf8)), "HTTP 应答不是 ADB")
    expect(!TVParse.isADBReply(Data()), "空应答不是 ADB")

    section("电视 · 报错翻译")
    expect(TVParse.humanizeAdbError("error: device unauthorized.").contains(L10n.t("允许", "Allow")), "未授权提示")
    expect(TVParse.humanizeAdbError("failed to connect to 1.2.3.4:5555").contains(L10n.t("无法连接", "Cannot reach")), "连接失败提示")
    expect(TVParse.humanizeAdbError("something odd").contains("something odd"), "未知错误保留原文")
    expect(TVParse.humanizeInstallError("Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]").contains(L10n.t("存储", "storage")), "存储不足")
    expect(TVParse.humanizeInstallError("INSTALL_FAILED_NO_MATCHING_ABIS").contains("CPU"), "ABI 不匹配")
    expect(TVParse.humanizeInstallError("Failure [FOO_BAR]").contains("FOO_BAR"), "未知安装错误保留原文")
    expect(TVParse.humanizeUninstallError("DELETE_FAILED_INTERNAL_ERROR", package: "com.x").contains("com.x"), "系统应用卸载失败提示")

    section("电视 · 网络")
    expectEqual(TVParse.normalizeMAC("BC:6B:F:30:E3:1C"), "bc:6b:0f:30:e3:1c", "ARP 省略前导 0 的补齐")
    expectEqual(TVParse.normalizeMAC("ff:ff:ff:ff:ff:ff"), "", "广播 MAC 丢弃")
    expectEqual(TVParse.normalizeMAC("(incomplete)"), "", "incomplete 丢弃")
    let arp = TVParse.parseARP("""
    ? (192.168.0.109) at bc:6b:ff:30:e3:1c on en0 ifscope [ethernet]
    ? (192.168.0.1) at 0:11:22:33:44:5 on en0 ifscope [ethernet]
    ? (192.168.0.77) at (incomplete) on en0 ifscope [ethernet]
    ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
    """)
    expectEqual(arp["192.168.0.109"], "bc:6b:ff:30:e3:1c", "ARP 解析")
    expectEqual(arp["192.168.0.1"], "00:11:22:33:44:05", "ARP 补零")
    expectEqual(arp["192.168.0.77"], nil, "未完成条目跳过")
    let hosts = TVParse.hosts(ip: "192.168.0.10", mask: "255.255.255.0")
    expectEqual(hosts.count, 254, "/24 有 254 个主机")
    expectEqual(hosts.first, "192.168.0.1", "起始主机")
    expectEqual(hosts.last, "192.168.0.254", "末尾主机")
    expectEqual(TVParse.hosts(ip: "10.1.2.3", mask: "255.255.252.0").count, 1022, "/22 有 1022 个主机")
    expectEqual(TVParse.hosts(ip: "10.1.2.3", mask: "255.0.0.0").count, 254, "过大网段只取本机所在 /24")
    expectEqual(TVParse.hosts(ip: "10.1.2.3", mask: "255.0.0.0").first, "10.1.2.1", "过大网段的 /24 起点")
    expectEqual(TVParse.broadcast(ip: "192.168.0.10", mask: "255.255.255.0"), "192.168.0.255", "广播地址")
    expect(TVParse.validHost("192.168.0.109"), "合法 IPv4")
    expect(!TVParse.validHost("192.168.0.109; reboot"), "带命令的 IP 被拒")
    expect(!TVParse.validHost("256.1.1.1"), "越界 IPv4 被拒")
    expect(!TVParse.validHost("01.2.3.4"), "前导 0 被拒")
    expect(TVDiscovery.isPrivate("192.168.1.5") && TVDiscovery.isPrivate("10.0.0.1") && TVDiscovery.isPrivate("172.20.1.1"), "私有网段")
    expect(!TVDiscovery.isPrivate("8.8.8.8") && !TVDiscovery.isPrivate("172.32.0.1"), "公网地址不扫")
    let magic = TVDiscovery.magicPacket(mac: "bc:6b:ff:30:e3:1c")
    expectEqual(magic?.count, 102, "WOL 魔术包 102 字节")
    expectEqual(Array(magic?.prefix(6) ?? []), Array(repeating: 0xFF, count: 6), "魔术包以 6 个 FF 开头")
    expectEqual(Array(magic?[6..<12] ?? []), [0xbc, 0x6b, 0xff, 0x30, 0xe3, 0x1c], "魔术包重复 MAC")
    expect(TVDiscovery.magicPacket(mac: "zz") == nil, "非法 MAC 无魔术包")
    let ssdp = TVParse.parseSSDPHeaders("HTTP/1.1 200 OK\r\nLOCATION: http://192.168.0.5:49152/desc.xml\r\nST: x\r\n\r\n")
    expectEqual(ssdp["LOCATION"], "http://192.168.0.5:49152/desc.xml", "SSDP LOCATION")
    expectEqual(TVParse.xmlTag("<root><friendlyName> 客厅(Mi TV)-cf8c </friendlyName></root>", "friendlyName"), "客厅(Mi TV)-cf8c", "XML 取标签")
    expectEqual(TVParse.cleanName("客厅(Mi TV)-cf8c"), "客厅", "去括号与随机后缀")
    expectEqual(TVParse.cleanName("(Only)"), "(Only)", "清空后回落原名")

    section("电视 · 投屏命令")
    expectEqual(TVParse.castURL("https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1", "https 链接")
    expectEqual(TVParse.castURL("www.bilibili.com/video/BV1")?.absoluteString, "https://www.bilibili.com/video/BV1", "裸域名补 https")
    expect(TVParse.castURL("file:///etc/passwd") == nil, "file 协议被拒")
    expect(TVParse.castURL("javascript:alert(1)") == nil, "javascript 协议被拒")
    expect(TVParse.castURL("https://a.com/x y") == nil, "含空白被拒")
    expect(TVParse.castURL("") == nil, "空串被拒")
    expect(TVParse.castURL("https://localhost/") == nil, "无点号主机被拒")
    expectEqual(TVParse.shellQuote("a'b"), "'a'\\''b'", "单引号转义")
    let page = TVParse.openURLCommand(URL(string: "https://example.com/page")!)
    expectEqual(page, "am start -a android.intent.action.VIEW -d 'https://example.com/page'", "网页只发 VIEW")
    expect(TVParse.openURLCommand(URL(string: "https://cdn.x.com/v.mp4")!).hasSuffix("-t video/*"), "mp4 直链带 video MIME")
    expect(TVParse.openURLCommand(URL(string: "https://cdn.x.com/live.m3u8")!).hasSuffix("-t application/x-mpegURL"), "m3u8 带 HLS MIME")
    let nasty = TVParse.openURLCommand(URL(string: "https://a.com/x'$(reboot)")!)
    expect(nasty.contains("'\\''") || !nasty.contains("x'$("), "URL 里的单引号不能逃出引号")
    expectEqual(TVParse.sanitizeInputText("hello world's \"x\""), "hello%sworlds%sx", "文本输入转义")
    expectEqual(TVParse.sanitizeInputText("你好a"), "%s%sa", "非 ASCII 换成空格")
    expect(TVParse.keycodes["ok"] == 23 && TVParse.keycodes["back"] == 4 && TVParse.keycodes["home"] == 3, "关键键码")

    section("电视 · APK 校验")
    let good = tmp.appendingPathComponent("ok.apk")
    try? Data([0x50, 0x4B, 0x03, 0x04, 0, 0]).write(to: good)
    expect(TVParse.validateAPK(good) == nil, "合法 APK")
    let wrongExt = tmp.appendingPathComponent("a.zip")
    try? Data([0x50, 0x4B, 0x03, 0x04]).write(to: wrongExt)
    expect(TVParse.validateAPK(wrongExt) != nil, "非 .apk 被拒")
    let fake = tmp.appendingPathComponent("fake.apk")
    try? Data("not a zip".utf8).write(to: fake)
    expect(TVParse.validateAPK(fake) != nil, "文件头不是 ZIP 被拒")
    let empty = tmp.appendingPathComponent("empty.apk")
    fm.createFile(atPath: empty.path, contents: Data())
    expect(TVParse.validateAPK(empty) != nil, "空文件被拒")
    expect(TVParse.validateAPK(tmp.appendingPathComponent("missing.apk")) != nil, "不存在的文件被拒")

    section("电视 · 设备注册表")
    let store = TVStore(directory: tmp)
    expect(!store.hasDevices, "初始为空")
    let a = store.upsert(TVDevice(id: TVDevice.makeID(mac: "bc:6b:ff:30:e3:1c", ip: "192.168.0.109"), ip: "192.168.0.109",
                                  mac: "bc:6b:ff:30:e3:1c", name: "Letv G55ES"))
    expectEqual(a.id, "mac:bc:6b:ff:30:e3:1c", "有 MAC 时按 MAC 作 id")
    expectEqual(TVDevice.makeID(mac: "", ip: "1.2.3.4"), "ip:1.2.3.4", "无 MAC 时按 IP 作 id")
    var named = a; named.room = "客厅"
    store.update(named)
    store.upsert(TVDevice(id: a.id, ip: "192.168.0.120", mac: a.mac, name: "Letv G55ES"))
    expectEqual(store.devices.count, 1, "同 MAC 换 IP 合并成一台")
    expectEqual(store.devices.first?.ip, "192.168.0.120", "IP 变了更新地址")
    expectEqual(store.devices.first?.room, "客厅", "合并时保留房间")
    var tested = store.devices[0]; tested.powerMode = "standby"
    store.update(tested)
    store.upsert(TVDevice(id: a.id, ip: "192.168.0.120", mac: a.mac, name: ""))
    expectEqual(store.devices.first?.powerMode, "standby", "重新发现不覆盖已实测的开机能力")
    expectEqual(store.devices.first?.name, "Letv G55ES", "重新发现不清空名称")
    expectEqual(store.devices.first?.serial, "192.168.0.120:5555", "ADB serial")
    expectEqual(store.devices.first?.title, "Letv G55ES · 客厅", "标题含房间")
    let reloaded = TVStore(directory: tmp)
    expectEqual(reloaded.devices, store.devices, "落盘后重新加载一致")
    store.remove(id: a.id)
    expect(!store.hasDevices, "删除设备")

    section("电视 · ADB 定位")
    expect(TVAdbLocator.candidates().contains("/opt/homebrew/bin/adb"), "候选含 Homebrew 路径")
    expect(TVAdbLocator.candidates().contains(NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"), "候选含 Android SDK 路径")
    if let found = TVAdbLocator.find() { expect(fm.isExecutableFile(atPath: found), "找到的 adb 可执行") }
    expectEqual(TVAdbLocator.installCommand, "brew install android-platform-tools", "安装命令")

    section("电视 · 本机联调(只读)")
    if let net = TVDiscovery.localNet() {
        expect(TVDiscovery.isPrivate(net.ip), "本机网段是私有地址")
        expect(TVParse.hosts(ip: net.ip, mask: net.mask).count > 0, "本机网段有主机")
    } else {
        print("  (无局域网网卡,跳过)")
    }
    expect(await TVDiscovery.portOpen("127.0.0.1", port: 1, timeout: 0.5) == false, "关闭端口探测为 false")
    if let adb = TVAdbLocator.find() {
        let v = ShellRun.run(adb, ["version"], timeout: 10)
        expect(v.status == 0 && v.out.contains("Android Debug Bridge"), "adb version 可运行")
        let ch = TVAdb(adb: adb, serial: "127.0.0.1:1")
        do { try await ch.ensureConnected(); expect(false, "连不上的设备应抛错") }
        catch { expect(!((error as? TVError)?.message.isEmpty ?? true), "连不上的设备抛出人话错误") }
    } else {
        print("  (未安装 adb,跳过)")
    }

    // 真实扫描(会连局域网里的 ADB 设备、电视可能弹授权框,默认不跑):POPBAR_TV_LIVE=1 ./tests/run.sh
    if ProcessInfo.processInfo.environment["POPBAR_TV_LIVE"] == "1", let adb = TVAdbLocator.find() {
        section("电视 · 真实扫描(POPBAR_TV_LIVE)")
        if let ip = ProcessInfo.processInfo.environment["POPBAR_TV_IP"] {
            print("  packet:", TVParse.adbConnectPacket().map { String(format: "%02x", $0) }.joined())
            print("  portOpen(\(ip)) = \(await TVDiscovery.portOpen(ip)), handshake = \(await TVDiscovery.adbHandshake(ip, timeout: 5))")
        }
        let found = await TVDiscovery.scan(adb: adb) { print("  … \($0)") }
        for c in found {
            print("  [\(c.kind)] \(c.displayName.isEmpty ? "(无名)" : c.displayName) | brand=\(c.brand) model=\(c.model) | \(c.ip) \(c.mac)")
        }
        print("  共 \(found.count) 项,其中电视 \(found.filter { $0.kind == .tv }.count) 台")
        // 对第一台电视做只读联调:状态 / 截图 / 应用列表(不按键、不改设置)
        if let tvc = found.first(where: { $0.kind == .tv }) {
            let ch = TVAdb(adb: adb, serial: "\(tvc.ip):\(TVParse.adbPort)")
            let st = await ch.probe()
            print("  probe: online=\(st.online) awake=\(st.awake) app=\(st.currentApp)(\(st.currentLabel)) vol=\(String(describing: st.volume)) muted=\(String(describing: st.muted)) res=\(st.resolution) err=\(st.error)")
            expect(st.online, "真机在线")
            if let png = try? await ch.screenshot() { print("  screenshot: \(png.count) bytes"); expect(NSImage(data: png) != nil, "截图可解码") }
            else { print("  screenshot: 失败(息屏/DRM 时正常)") }
            if let apps = try? await ch.listApps(includeSystem: false) {
                print("  apps(\(apps.count)): " + apps.prefix(6).map { "\($0.label)" }.joined(separator: ", "))
                expect(!apps.isEmpty, "应用列表非空")
            }
        }
    }
}
