import Foundation

// 电视遥控的核心层:纯解析函数(可单测)+ ADB 封装 + 设备注册表。
// 思路移植自 tv-hub:电视走 ADB over TCP(端口 5555),adb 命令行自己处理授权与重连,
// 这里只负责拼命令、解析输出、把英文报错翻成人话。

// MARK: - 数据模型

/// 登记过的电视。身份优先按 MAC(IP 变了也能认回),拿不到 MAC 时退回 IP
struct TVDevice: Codable, Identifiable, Equatable {
    var id: String
    var ip: String
    var mac: String
    var name: String
    var room: String = ""
    var brand: String = ""
    var model: String = ""
    /// unknown | standby(待机可远程唤醒) | wol(支持网络唤醒) | manual(只能遥控器开机)
    var powerMode: String = "unknown"

    var serial: String { "\(ip):\(TVParse.adbPort)" }
    var title: String { room.isEmpty ? name : "\(name) · \(room)" }

    static func makeID(mac: String, ip: String) -> String { mac.isEmpty ? "ip:\(ip)" : "mac:\(mac)" }
}

/// 一次探测的状态快照
struct TVState: Equatable {
    var online = false
    var awake = false
    var currentApp = ""
    var currentLabel = ""
    var volume: Int?
    var muted: Bool?
    var resolution = ""
    var error = ""
}

struct TVApp: Identifiable, Equatable {
    var id: String { package }
    let package: String
    let label: String
    let system: Bool
}

/// 候选设备的判定结果
enum TVKind: Int, Comparable {
    /// 已读到型号,确认是电视 / 电视盒子
    case tv
    /// ADB 在应答,但电视还没授权这台 Mac(读不到型号)
    case pending
    /// ADB 在应答,但看起来是手机 / 平板等非电视设备
    case otherAndroid
    /// 只有 SSDP 应答(DLNA 媒体设备),没开 ADB
    case mediaOnly

    static func < (a: TVKind, b: TVKind) -> Bool { a.rawValue < b.rawValue }
}

/// 扫描发现的候选设备
struct TVCandidate: Identifiable, Equatable {
    var id: String { ip }
    var ip: String
    var mac: String = ""
    /// ADB 协议握手成功(不是仅仅端口能连:透明代理会替所有地址完成 TCP 握手)
    var adbOpen = false
    /// SSDP 描述里的名字 / 厂商(没开 ADB 的 DLNA 电视也能被看到)
    var friendlyName = ""
    var manufacturer = ""
    var model = ""
    var brand = ""
    var kind: TVKind = .mediaOnly

    var brandName: String { TVBrand.displayName(brand) }

    /// 给人看的名字:SSDP 友好名 > 品牌 + 型号 > 型号 > 兜底
    var displayName: String {
        TVBrand.deviceName(friendly: friendlyName, brand: brand, manufacturer: manufacturer, model: model, fallback: "")
    }
}

/// 品牌识别:先看 MAC 前缀(OUI),再看厂商 / 型号 / 名字里的关键字
enum TVBrand {
    static let oui: [String: String] = [
        "bc:6b:ff": "letv",
        "78:11:dc": "xiaomi", "f0:b4:29": "xiaomi", "64:09:80": "xiaomi", "28:6c:07": "xiaomi", "8c:be:be": "xiaomi",
        "3c:5a:b4": "google", "d8:6c:63": "google",
        "f8:0f:84": "sony", "54:42:49": "sony", "00:0f:b3": "sony",
        "d0:03:4b": "hisense", "34:8a:7b": "hisense", "b8:97:5a": "hisense",
        "c8:dd:c9": "tcl", "a0:c9:a0": "tcl", "28:ed:6a": "tcl",
    ]

    static let names: [String: String] = [
        "letv": "乐视", "xiaomi": "小米", "sony": "索尼", "hisense": "海信", "tcl": "TCL", "google": "Google",
        "skyworth": "创维", "konka": "康佳", "changhong": "长虹", "huawei": "华为", "samsung": "三星",
        "lg": "LG", "philips": "飞利浦", "sharp": "夏普", "haier": "海尔",
    ]

    static let keywords: [(String, String)] = [
        ("letv", "letv"), ("乐视", "letv"), ("le.com", "letv"),
        ("xiaomi", "xiaomi"), ("小米", "xiaomi"), ("mi tv", "xiaomi"), ("redmi", "xiaomi"),
        ("sony", "sony"), ("bravia", "sony"), ("hisense", "hisense"), ("海信", "hisense"),
        ("tcl", "tcl"), ("skyworth", "skyworth"), ("创维", "skyworth"), ("konka", "konka"), ("康佳", "konka"),
        ("changhong", "changhong"), ("长虹", "changhong"), ("huawei", "huawei"), ("华为", "huawei"),
        ("samsung", "samsung"), ("lg ", "lg"), ("philips", "philips"), ("sharp", "sharp"), ("haier", "haier"),
    ]

    /// 只做电视的品牌:型号里没写 tv 也按电视处理
    static let tvOnly: Set<String> = ["letv", "hisense", "tcl", "skyworth", "konka", "changhong"]

    static func guess(mac: String, texts: [String]) -> String {
        let blob = texts.joined(separator: " ").lowercased() + " "
        for (key, brand) in keywords where blob.contains(key) { return brand }
        let prefix = mac.lowercased().split(separator: ":").prefix(3).joined(separator: ":")
        return oui[prefix] ?? ""
    }

    static func displayName(_ brand: String) -> String { names[brand] ?? "" }

    /// 命名优先级:SSDP 友好名 > 品牌 + 型号 > 厂商 + 型号 > 兜底
    static func deviceName(friendly: String, brand: String, manufacturer: String, model: String, fallback: String) -> String {
        let bn = displayName(brand)
        if !friendly.isEmpty {
            // 纯品牌名信息量太低("乐视"),补上型号
            return (friendly == bn && !model.isEmpty) ? "\(bn) \(model)" : friendly
        }
        let head = bn.isEmpty ? manufacturer : bn
        let n = [head, model].filter { !$0.isEmpty }.joined(separator: " ")
        return n.isEmpty ? fallback : n
    }

    /// 是不是电视:ro.build.characteristics 含 tv 最可靠,其次型号带 tv / 电视专营品牌
    static func looksLikeTV(characteristics: String, brand: String, model: String) -> Bool {
        let chars = characteristics.lowercased().split(whereSeparator: { $0 == "," || $0 == " " })
        if chars.contains("tv") || chars.contains("television") { return true }
        if chars.contains("phone") || chars.contains("tablet") { return false }
        if model.lowercased().contains("tv") { return true }
        return tvOnly.contains(brand)
    }

    /// 路由器 / 打印机 / NAS 也会广播 SSDP,按名字剔除
    static let notTVHints = ["router", "交换机", "gateway", "nas", "printer", "打印机", "路由器", "无线", "wireless", "access point", "igd", "wdr"]

    static func looksLikeNonTVMedia(_ text: String) -> Bool {
        let t = text.lowercased()
        return notTVHints.contains { t.contains($0) }
    }
}

struct TVError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - 纯解析

enum TVParse {
    static let adbPort = 5555

    /// Android keycode(只列用到的)
    static let keycodes: [String: Int] = [
        "up": 19, "down": 20, "left": 21, "right": 22, "ok": 23,
        "back": 4, "home": 3, "menu": 82, "info": 165,
        "play_pause": 85, "play": 126, "pause": 127, "next": 87, "prev": 88,
        "vol_up": 24, "vol_down": 25, "mute": 164, "power": 26,
    ]

    /// 厂商包名 → 常见中文名(电视上的应用名只有包名可取)
    static let appLabels: [String: String] = [
        "com.cibn.tv": "优酷 TV", "com.gitvvideo.letv": "乐视视频", "com.tencent.start.tv": "腾讯视频",
        "com.newtv.cboxtv": "云视听极光", "com.newtv.sport": "云视听体育",
        "com.ixigua.android.tv.bestv": "西瓜视频", "com.ixigua.android.tv.wasu": "西瓜视频(华数)",
        "com.kwai.tv.yst": "快手 TV", "com.ktcp.tvvideo": "云视听小电视", "com.baidu.netdisk.tv": "百度网盘",
        "com.hpplay.happyplay.aw": "乐播投屏", "com.letv.tv": "乐视电视", "com.letv.combine": "乐视综合",
        "com.hongen.app.word.ott": "洪恩识字", "com.yougu.ultraman.leshi": "优谷奥特曼",
        "com.xiaodianshi.tv.yst": "小电视", "com.iptv.ylhb": "IPTV", "com.iptv.ylhb.leshi": "IPTV(乐视)",
        "com.iptv.liyuanhang_ott": "IPTV(梨园行)", "air.com.gongfubb.wksz.tv": "悟空识字",
        "com.hunantv.license": "芒果 TV", "com.lap.devicescanner": "设备扫描",
        "com.letv.tvos.intermodal": "乐视互通", "com.stv.screenflyter": "乐视桌面服务",
        "com.tencent.qqlivetv": "腾讯视频", "com.qiyi.video.sdkplayer": "爱奇艺", "com.mgtv.tv": "芒果 TV",
        "tv.danmaku.bili": "哔哩哔哩", "com.bilibili.bilitv": "哔哩哔哩 TV", "com.google.android.youtube.tv": "YouTube",
        "com.netflix.ninja": "Netflix", "org.chromium.webview_shell": "WebView",
    ]

    /// 空转服务:会抢走 resumed activity 但用户并没在用(乐视熄屏后拉起的屏保服务)
    static let idlePackages: Set<String> = ["com.stv.screenflyter"]
    static let launcherHints = ["launcher", "deskplatform", "letv.tv", "com.letv.combine", "tvos.home"]

    static func label(for package: String) -> String { appLabels[package] ?? package }

    static func isLauncher(_ package: String) -> Bool { launcherHints.contains { package.contains($0) } }

    static func validPackage(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z][A-Za-z0-9_.]*$", options: .regularExpression) != nil
    }

    // MARK: 输出解析

    /// 把 `=POWER=` 这类分隔标记切成字典(一条 shell 命令取回多段信息)
    static func splitBlocks(_ raw: String) -> [String: String] {
        var blocks: [String: [String]] = [:]
        var current: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.count > 2, t.hasPrefix("="), t.hasSuffix("="),
               t.dropFirst().dropLast().allSatisfy({ $0.isUppercase }) {
                current = String(t.dropFirst().dropLast())
                blocks[current!] = []
                continue
            }
            if let c = current { blocks[c, default: []].append(String(line)) }
        }
        return blocks.mapValues { $0.joined(separator: "\n") }
    }

    /// "com.foo/.MainActivity" 里的包名
    static func extractPackage(_ line: String) -> String {
        guard let r = line.range(of: "([A-Za-z][A-Za-z0-9_.]*)/[A-Za-z0-9_.$]+", options: .regularExpression) else { return "" }
        let hit = String(line[r])
        return String(hit.prefix(while: { $0 != "/" }))
    }

    /// 栈顶是空转服务时,往下找真正在用的 App
    static func pickForeground(_ dumpsys: String) -> String {
        for line in dumpsys.split(separator: "\n") {
            let pkg = extractPackage(String(line))
            if !pkg.isEmpty && !idlePackages.contains(pkg) { return pkg }
        }
        return ""
    }

    /// 解析 dumpsys audio 的 STREAM_MUSIC 段;不同固件格式不同,多种写法都认
    static func parseVolume(_ text: String) -> (volume: Int?, muted: Bool?) {
        var vol: Int?
        var muted: Bool?
        for line in text.split(separator: "\n") {
            let l = String(line)
            if let r = l.range(of: "Muted:\\s*(true|false)", options: .regularExpression) {
                muted = l[r].hasSuffix("true")
            }
            if vol == nil, let r = l.range(of: "\\(speaker\\):\\s*\\d+", options: .regularExpression) {
                vol = Int(l[r].filter(\.isNumber))
                continue
            }
            if vol == nil, let r = l.range(of: "streamVolume:\\d+", options: .regularExpression) {
                vol = Int(l[r].filter(\.isNumber))
            }
        }
        return (vol, muted)
    }

    /// `pm list packages` 输出 → 包名(兼容 -f / -U 带路径与 uid 的格式)
    static func parsePackages(_ output: String) -> [String] {
        var out: [String] = []
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("package:") else { continue }
            var body = String(line.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces)
            if let r = body.range(of: "\\s+uid:\\d+.*$", options: .regularExpression) { body.removeSubrange(r) }
            let pkg = body.contains("=") ? String(body.split(separator: "=").last ?? "") : body
            if validPackage(pkg) { out.append(pkg) }
        }
        return Array(Set(out)).sorted()
    }

    /// 前台应用的显示名
    static func foregroundLabel(_ package: String) -> String {
        if package.isEmpty { return "" }
        return isLauncher(package) ? L10n.t("桌面", "Home") : label(for: package)
    }

    /// getprop 四行:model / manufacturer / device / build.characteristics(第四行旧调用方可缺省)
    static func parseGetprop(_ output: String) -> (model: String, manufacturer: String, device: String, characteristics: String) {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func at(_ i: Int) -> String { i < lines.count ? lines[i] : "" }
        return (at(0), at(1), at(2), at(3))
    }

    // MARK: ADB 协议握手

    /// 最小的 ADB CNXN 报文(24 字节头 + "host::\0"):真正的 adbd 会回 CNXN 或 AUTH,
    /// 透明代理 / 其它服务不会按协议应答——据此剔除「端口能连但不是 ADB」的假阳性
    static func adbConnectPacket() -> Data {
        let payload = Array("host::\0".utf8)
        func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24 & 255)] }
        let cmd: UInt32 = 0x4e584e43   // "CNXN"
        let sum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        return Data(le(cmd) + le(0x0100_0000) + le(4096) + le(UInt32(payload.count)) + le(sum) + le(cmd ^ 0xFFFF_FFFF) + payload)
    }

    /// 应答头:命令是 CNXN / AUTH 且 magic = ~command
    static func isADBReply(_ d: Data) -> Bool {
        guard d.count >= 24 else { return false }
        func u32(_ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[d.startIndex + o + $1]) << UInt32(8 * $1) } }
        let cmd = u32(0)
        return (cmd == 0x4e584e43 || cmd == 0x48545541) && u32(20) == cmd ^ 0xFFFF_FFFF
    }

    // MARK: ADB 报错 → 人话

    /// adb 原始报错里常见的几类,翻成用户能照做的提示
    static func humanizeAdbError(_ raw: String) -> String {
        let e = raw.lowercased()
        let rules: [([String], String)] = [
            (["unauthorized"], L10n.t("电视还没授权这台 Mac:请在电视上点「允许」并勾选「一律允许」", "The TV has not authorized this Mac: tap Allow (and Always allow) on the TV")),
            (["offline"], L10n.t("设备处于离线状态,请重新打开电视的 ADB 调试开关后重试", "The device is offline; toggle ADB debugging on the TV and retry")),
            (["connection refused", "failed to connect", "cannot connect", "unable to connect"],
             L10n.t("无法连接电视:请确认电视已开机、与 Mac 在同一网络,并已开启 ADB 调试", "Cannot reach the TV: make sure it is on, on the same network, with ADB debugging enabled")),
            (["not found", "no devices", "no such device"], L10n.t("找不到设备,电视可能已关机或换了 IP", "Device not found; the TV may be off or have a new IP")),
            (["timed out", "timeout", "执行超时"], L10n.t("电视响应超时", "The TV timed out")),
            (["more than one device"], L10n.t("连接了多台设备,无法确定目标", "More than one device is connected")),
        ]
        for (keys, msg) in rules where keys.contains(where: { e.contains($0) }) { return msg }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? L10n.t("未知错误", "Unknown error") : String(t.prefix(300))
    }

    /// adb install 的错误码 → 人话(原始信息附在末尾,翻译是为了好懂而不是藏细节)
    static func humanizeInstallError(_ raw: String) -> String {
        let e = raw.lowercased()
        let rules: [([String], String)] = [
            (["insufficient_storage", "no space"], L10n.t("电视存储空间不足,请先清理一些应用或缓存", "Not enough storage on the TV")),
            (["version_downgrade"], L10n.t("电视上已装了更高版本,请先卸载旧版", "A newer version is installed; uninstall it first")),
            (["update_incompatible"], L10n.t("与已安装版本的签名不一致,请先卸载旧版再装", "Signature differs from the installed version; uninstall it first")),
            (["already_exists"], L10n.t("应用已存在(覆盖安装被拒),请先卸载", "Already installed (overwrite refused); uninstall first")),
            (["no_matching_abis"], L10n.t("这个 APK 不含电视 CPU 架构所需的原生库", "The APK has no native libraries for this TV's CPU")),
            (["install_failed_incompatible"], L10n.t("这个 APK 的架构或系统版本与电视不兼容", "The APK is incompatible with this TV")),
            (["test_only"], L10n.t("这是仅供测试的 APK,无法正式安装", "Test-only APK")),
            (["missing_shared_library"], L10n.t("APK 依赖的共享库在电视上不存在", "A shared library the APK needs is missing on the TV")),
            (["verification"], L10n.t("APK 签名校验失败,可能被篡改或签名不完整", "APK signature verification failed")),
            (["internal_error"], L10n.t("电视系统内部错误,重启电视后再试", "Internal TV error; reboot the TV and retry")),
            (["blocked", "not allowed to install"], L10n.t("这台电视的策略禁止安装未知来源应用,请到电视「设置 → 安全」里允许", "The TV blocks unknown sources; allow them in Settings → Security")),
            (["parse_failed", "corrupt", "invalid_apk"], L10n.t("APK 内容无效(损坏或不是真正的安装包)", "The APK is invalid or corrupt")),
        ]
        for (keys, msg) in rules where keys.contains(where: { e.contains($0) }) {
            return L10n.t("安装失败:", "Install failed: ") + msg
        }
        if raw.contains("超时") || e.contains("timed out") {
            return L10n.t("安装超时。大文件可能仍在后台安装,稍等片刻刷新应用列表确认", "Install timed out; a large file may still be installing — refresh the app list shortly")
        }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return L10n.t("安装失败:", "Install failed: ") + (t.isEmpty ? L10n.t("未知错误", "unknown error") : String(t.prefix(300)))
    }

    static func humanizeUninstallError(_ raw: String, package: String) -> String {
        let e = raw.lowercased()
        if e.contains("internal_error") || e.contains("not installed for") {
            return L10n.t("卸载失败:\(package) 可能是系统应用,或当前无 root 权限无法移除", "Uninstall failed: \(package) may be a system app that can't be removed without root")
        }
        if e.contains("device_policy") {
            return L10n.t("卸载失败:\(package) 被设备策略保护(设备管理员应用)", "Uninstall failed: \(package) is protected by a device admin policy")
        }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return L10n.t("卸载失败:", "Uninstall failed: ") + (t.isEmpty ? L10n.t("未知错误", "unknown error") : String(t.prefix(200)))
    }

    // MARK: 网络

    /// arp 输出的 MAC 会省略前导 0("bc:6b:f:30" 这种),统一补成两位小写
    static func normalizeMAC(_ raw: String) -> String {
        let parts = raw.lowercased().split(separator: ":")
        guard parts.count == 6 else { return "" }
        let fixed = parts.map { $0.count == 1 ? "0" + $0 : String($0) }
        guard fixed.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return "" }
        let mac = fixed.joined(separator: ":")
        return mac == "ff:ff:ff:ff:ff:ff" || mac == "00:00:00:00:00:00" ? "" : mac
    }

    /// `arp -an` → ip: mac
    static func parseARP(_ output: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in output.split(separator: "\n") {
            // ? (192.168.0.109) at bc:6b:ff:30:e3:1c on en0 ifscope [ethernet]
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close else { continue }
            let ip = String(line[line.index(after: open)..<close])
            guard let at = line.range(of: " at ") else { continue }
            let mac = normalizeMAC(String(line[at.upperBound...].prefix(while: { $0 != " " })))
            if !mac.isEmpty { map[ip] = mac }
        }
        return map
    }

    static func ipv4(_ s: String) -> UInt32? {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return nil }
        var v: UInt32 = 0
        for x in p {
            guard let n = UInt32(x), n <= 255, x == String(n) else { return nil }
            v = v << 8 | n
        }
        return v
    }

    static func ipv4String(_ v: UInt32) -> String {
        "\(v >> 24 & 255).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)"
    }

    /// 子网内的全部主机地址(去掉网络号与广播),过大的网段只取本机所在的 /24
    static func hosts(ip: String, mask: String, limit: Int = 1022) -> [String] {
        guard let a = ipv4(ip), var m = ipv4(mask) else { return [] }
        var net = a & m
        var count = Int(~m) - 1
        if count > limit {
            m = 0xFFFF_FF00
            net = a & m
            count = 254
        }
        guard count > 0 else { return [] }
        return (1...count).map { ipv4String(net + UInt32($0)) }
    }

    static func broadcast(ip: String, mask: String) -> String? {
        guard let a = ipv4(ip), let m = ipv4(mask) else { return nil }
        return ipv4String(a & m | ~m)
    }

    /// 合法的局域网 IPv4 字面量(手动添加设备时校验,避免把任意字符串拼进命令)
    static func validHost(_ s: String) -> Bool { ipv4(s) != nil }

    // MARK: SSDP

    static func parseSSDPHeaders(_ text: String) -> [String: String] {
        var h: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let c = line.firstIndex(of: ":") else { continue }
            h[line[..<c].trimmingCharacters(in: .whitespaces).uppercased()] =
                line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        return h
    }

    /// UPnP 描述 XML 里取一个标签的文本(够用的轻量写法,避免为几个字段引 XML 解析器)
    static func xmlTag(_ xml: String, _ tag: String) -> String {
        guard let s = xml.range(of: "<\(tag)>"), let e = xml.range(of: "</\(tag)>", range: s.upperBound..<xml.endIndex) else { return "" }
        return xml[s.upperBound..<e.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉 "客厅(Mi TV)-cf8c" 这类括号与随机后缀
    static func cleanName(_ raw: String) -> String {
        var n = raw
        while let r = n.range(of: "\\([^)]*\\)", options: .regularExpression) { n.removeSubrange(r) }
        if let r = n.range(of: "-[0-9a-fA-F]{4,}$", options: .regularExpression) { n.removeSubrange(r) }
        let t = n.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? raw : t
    }

    // MARK: 投屏意图

    static let videoExtensions: Set<String> = ["mp4", "m3u8", "mkv", "mov", "avi", "flv", "ts", "webm", "m4v", "mpd"]

    /// 取 http(s) 链接;裸域名补 https://;其它协议一律拒绝(会被拼进设备 shell 命令)
    static func castURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count < 2000, !s.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = u.host, host.contains(".") else { return nil }
        return u
    }

    /// 单引号 shell 转义:设备端 sh 执行,URL 里的 ' 要断开重接
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// 在电视上打开链接的 am 命令;直链视频带 MIME,让电视直接用播放器而不是浏览器
    static func openURLCommand(_ url: URL) -> String {
        var cmd = "am start -a android.intent.action.VIEW -d \(shellQuote(url.absoluteString))"
        if videoExtensions.contains(url.pathExtension.lowercased()) {
            cmd += url.pathExtension.lowercased() == "m3u8" ? " -t application/x-mpegURL" : " -t video/*"
        }
        return cmd
    }

    /// `input text` 只认 ASCII:空格转 %s,引号丢弃,其它非 ASCII 换成空格
    static func sanitizeInputText(_ text: String) -> String {
        let ascii = String(text.map { c -> Character in
            guard let a = c.asciiValue, a >= 0x20, a < 0x7f else { return " " }
            return c
        })
        return ascii.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: " ", with: "%s")
    }

    /// APK 文件校验:扩展名、体积上限、ZIP 文件头
    static func validateAPK(_ url: URL) -> String? {
        guard url.pathExtension.lowercased() == "apk" else { return L10n.t("只支持 .apk 文件", "Only .apk files are supported") }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 { return L10n.t("APK 文件为空", "The APK is empty") }
        if size > 2 << 30 { return L10n.t("APK 超过 2GB 上限", "The APK exceeds the 2GB limit") }
        guard let h = try? FileHandle(forReadingFrom: url) else { return L10n.t("无法读取文件", "Cannot read the file") }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4)) ?? Data()
        return head == Data([0x50, 0x4B, 0x03, 0x04]) ? nil : L10n.t("不是有效的 APK(文件头不是 ZIP)", "Not a valid APK (no ZIP header)")
    }
}

// MARK: - ADB 定位

enum TVAdbLocator {
    /// 菜单栏应用拿不到 shell 的 PATH,按常见安装位置逐个找
    static func candidates() -> [String] {
        var list = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/opt/local/bin/adb"]
        let home = NSHomeDirectory()
        list.append(home + "/Library/Android/sdk/platform-tools/adb")
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let r = ProcessInfo.processInfo.environment[key], !r.isEmpty { list.append(r + "/platform-tools/adb") }
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            list += path.split(separator: ":").map { $0 + "/adb" }
        }
        return list
    }

    static func find() -> String? {
        candidates().first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let installCommand = "brew install android-platform-tools"
}

// MARK: - ADB 封装

/// 一台电视的 ADB 通道。控制命令与截图各用一条串行队列:
/// 同设备的控制命令串行(adb 对同一 transport 并发调用会互相阻塞),
/// 截图单独一条队列,不会因为慢截图而卡住按键。
final class TVAdb: @unchecked Sendable {
    let adb: String
    let serial: String
    private let control: DispatchQueue
    private let shot: DispatchQueue
    private let lock = NSLock()
    private var lastOK = Date.distantPast

    init(adb: String, serial: String) {
        self.adb = adb
        self.serial = serial
        control = DispatchQueue(label: "popbar.tv.ctl.\(serial)")
        shot = DispatchQueue(label: "popbar.tv.shot.\(serial)")
    }

    typealias Raw = (status: Int32, out: Data, err: String)

    private func exec(_ args: [String], timeout: TimeInterval, on q: DispatchQueue) async -> Raw {
        let adb = self.adb
        return await withCheckedContinuation { cont in
            q.async { cont.resume(returning: ShellRun.runData(adb, args, timeout: timeout)) }
        }
    }

    private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    // MARK: 连接

    private func markOK() { lock.lock(); lastOK = Date(); lock.unlock() }
    private func markFailed() { lock.lock(); lastOK = .distantPast; lock.unlock() }
    private var recentlyOK: Bool { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastOK) < 20 }

    /// 确保已连上:先看 get-state,不通再 adb connect(connect 会"假装成功",最后仍以 get-state 为准)
    func ensureConnected() async throws {
        if recentlyOK { return }
        func online() async -> (Bool, String) {
            let r = await exec(["-s", serial, "get-state"], timeout: 5, on: control)
            return (r.status == 0 && text(r.out).contains("device"), text(r.out) + r.err)
        }
        let first = await online()
        if first.0 { markOK(); return }
        let c = await exec(["connect", serial], timeout: 10, on: control)
        let second = await online()
        if second.0 { markOK(); return }
        markFailed()
        let msg = [text(c.out), c.err, second.1].joined(separator: " ")
        throw TVError(TVParse.humanizeAdbError(msg))
    }

    func disconnect() async {
        _ = await exec(["disconnect", serial], timeout: 3, on: control)
        markFailed()
    }

    // MARK: 命令

    /// 设备上跑一条 shell。不因非零退出码抛错(grep 无匹配也是 1),调用方自己看输出
    func shellRaw(_ command: String, timeout: TimeInterval = 8) async throws -> (status: Int32, out: String) {
        try await ensureConnected()
        let r = await exec(["-s", serial, "shell", command], timeout: timeout, on: control)
        if r.status == -1 { throw TVError(L10n.t("无法运行 adb:", "Cannot run adb: ") + r.err) }
        if r.status == -2 { markFailed(); throw TVError(L10n.t("电视响应超时", "The TV timed out")) }
        let out = text(r.out)
        if r.status != 0 && out.isEmpty {
            markFailed()
            throw TVError(TVParse.humanizeAdbError(r.err))
        }
        markOK()
        return (r.status, out)
    }

    @discardableResult
    func shell(_ command: String, timeout: TimeInterval = 8) async throws -> String {
        try await shellRaw(command, timeout: timeout).out
    }

    func key(_ name: String) async throws {
        guard let code = TVParse.keycodes[name] else { throw TVError("unsupported key: \(name)") }
        try await shell("input keyevent \(code)")
    }

    /// 截图走 exec-out,PNG 直接走 stdout(比落盘再 pull 快一半);单独队列
    func screenshot() async throws -> Data {
        try await ensureConnected()
        let r = await exec(["-s", serial, "exec-out", "screencap -p"], timeout: 15, on: shot)
        guard r.status == 0, r.out.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw TVError(r.status == -2 ? L10n.t("截图超时", "Screenshot timed out")
                          : L10n.t("截图失败(电视息屏或正在播放受保护内容时会这样)", "Screenshot failed (the screen is off, or DRM content is playing)"))
        }
        return r.out
    }

    /// adb 自身的子命令(install / uninstall 等),大文件传输给足超时
    func run(_ args: [String], timeout: TimeInterval) async -> (status: Int32, out: String, err: String) {
        let r = await exec(["-s", serial] + args, timeout: timeout, on: control)
        return (r.status, text(r.out), r.err)
    }

    // MARK: 探测

    /// 一条 shell 取回全部状态(合并前分四次调用要 7–20 秒,合并后 1 秒内)
    func probe() async -> TVState {
        var st = TVState()
        do { try await ensureConnected() } catch {
            st.error = (error as? TVError)?.message ?? error.localizedDescription
            return st
        }
        let cmd = "echo '=POWER='; dumpsys power | grep -E 'mWakefulness='; "
            + "echo '=ACT='; dumpsys activity activities | grep -E 'mResumedActivity|mLastPausedActivity' | head -4; "
            + "echo '=VOL='; dumpsys audio | grep -A8 'STREAM_MUSIC:'; "
            + "echo '=SIZE='; wm size"
        let raw: String
        do { raw = try await shell(cmd, timeout: 12) } catch {
            st.error = (error as? TVError)?.message ?? error.localizedDescription
            return st
        }
        let b = TVParse.splitBlocks(raw)
        st.online = true
        st.awake = (b["POWER"] ?? "").contains("mWakefulness=Awake")
        st.currentApp = TVParse.pickForeground(b["ACT"] ?? "")
        st.currentLabel = TVParse.foregroundLabel(st.currentApp)
        let v = TVParse.parseVolume(b["VOL"] ?? "")
        st.volume = v.volume
        st.muted = v.muted
        if let r = (b["SIZE"] ?? "").range(of: "\\d+x\\d+", options: .regularExpression) { st.resolution = String((b["SIZE"] ?? "")[r]) }
        return st
    }

    // MARK: 音量

    func readVolume() async -> Int? {
        guard let out = try? await shell("dumpsys audio | grep -A8 'STREAM_MUSIC:'") else { return nil }
        return TVParse.parseVolume(out).volume
    }

    /// 降级链:media_session 直设 → 回读校验 → 不行就按键连发
    func setVolume(_ level: Int) async throws {
        let level = max(0, min(100, level))
        if (try? await shell("cmd media_session volume --stream 3 --set \(level)")) != nil,
           let actual = await readVolume(), abs(actual - level) <= 1 { return }
        guard let current = await readVolume() else { throw TVError(L10n.t("读取音量失败", "Cannot read the volume")) }
        let steps = abs(level - current)
        if steps == 0 { return }
        let code = level > current ? 24 : 25
        try await shell("input keyevent " + Array(repeating: String(code), count: min(steps, 60)).joined(separator: " "))
    }

    // MARK: 应用

    func launch(_ package: String) async throws {
        guard TVParse.validPackage(package) else { throw TVError(L10n.t("包名不合法", "Invalid package name")) }
        let out = try await shell("monkey -p \(package) -c android.intent.category.LAUNCHER 1", timeout: 10)
        if out.contains("No activities found") {
            throw TVError(L10n.t("这个应用没有可启动的入口", "This app has no launchable activity"))
        }
    }

    func listApps(includeSystem: Bool) async throws -> [TVApp] {
        let third = TVParse.parsePackages(try await shell("pm list packages -3", timeout: 12))
        var apps = third.map { TVApp(package: $0, label: TVParse.label(for: $0), system: false) }
        if includeSystem {
            let sys = TVParse.parsePackages(try await shell("pm list packages -s", timeout: 12))
            apps += sys.filter { !third.contains($0) }.map { TVApp(package: $0, label: TVParse.label(for: $0), system: true) }
        }
        return apps.sorted { ($0.system ? 1 : 0, $0.label.lowercased()) < ($1.system ? 1 : 0, $1.label.lowercased()) }
    }

    func installAPK(_ url: URL) async throws -> String {
        try await ensureConnected()
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.doubleValue ?? 0) / 1_048_576
        let timeout = max(60, 60 + size * 2)   // adb install 先推后装,中间没进度,按体积给足超时
        var last = ""
        for extra in [["-r", "-g"], ["-r"], []] {
            let r = await run(["install"] + extra + [url.path], timeout: timeout)
            if r.status == -2 { throw TVError(TVParse.humanizeInstallError("超时")) }
            if r.out.contains("Success") { return String(format: L10n.t("安装成功(%.1f MB)", "Installed (%.1f MB)"), size) }
            last = (r.out + " " + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw TVError(TVParse.humanizeInstallError(last))
    }

    func uninstall(_ package: String) async throws {
        guard TVParse.validPackage(package) else { throw TVError(L10n.t("包名不合法", "Invalid package name")) }
        let out = try await shell("pm uninstall \(package)", timeout: 30)
        if out.contains("Success") { return }
        let r = await run(["uninstall", package], timeout: 30)
        if r.out.contains("Success") { return }
        throw TVError(TVParse.humanizeUninstallError(out + " " + r.out + " " + r.err, package: package))
    }

    // MARK: 其它

    func openURL(_ url: URL) async throws {
        let out = try await shell(TVParse.openURLCommand(url), timeout: 10)
        let l = out.lowercased()
        if l.contains("unable to resolve") || l.contains("no activity found") || l.contains("error:") {
            throw TVError(L10n.t("电视上没有能打开这个链接的应用(需要浏览器或视频 App)", "No app on the TV can open this link (a browser or video app is needed)"))
        }
    }

    func inputText(_ text: String) async throws {
        let safe = TVParse.sanitizeInputText(text)
        if safe.isEmpty { return }
        try await shell("input text '\(safe)'")
    }

    func identity() async -> (model: String, manufacturer: String, device: String, characteristics: String)? {
        guard let out = try? await shell("getprop ro.product.model; getprop ro.product.manufacturer; getprop ro.product.device; getprop ro.build.characteristics", timeout: 6) else { return nil }
        return TVParse.parseGetprop(out)
    }

    enum Inspection {
        case info(model: String, manufacturer: String, device: String, characteristics: String)
        /// 已连上但电视还没授权这台 Mac
        case unauthorized
        case unreachable
    }

    /// 扫描阶段识别一台设备:connect → 看 get-state → 读型号。不走 ensureConnected(它会把授权失败翻成人话抛错)
    func inspect() async -> Inspection {
        _ = await exec(["connect", serial], timeout: 6, on: control)
        let st = await exec(["-s", serial, "get-state"], timeout: 5, on: control)
        let msg = (text(st.out) + " " + st.err).lowercased()
        if msg.contains("unauthorized") { return .unauthorized }
        guard st.status == 0, msg.contains("device") else { return .unreachable }
        markOK()
        guard let i = await identity() else { return .unreachable }
        return .info(model: i.model, manufacturer: i.manufacturer, device: i.device, characteristics: i.characteristics)
    }
}

// MARK: - 设备注册表

/// 登记的电视存成一个 JSON(Application Support/PopBar/tv-devices.json),设备不多,无需数据库
@MainActor
final class TVStore {
    static let shared = TVStore()
    private(set) var devices: [TVDevice] = []
    private let url: URL

    init(directory: URL = PopBarConfig.directoryURL) {
        url = directory.appendingPathComponent("tv-devices.json")
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([TVDevice].self, from: data) {
            devices = list
        }
    }

    var hasDevices: Bool { !devices.isEmpty }

    /// 新增或按 id / MAC / IP 合并;IP 变了就更新地址
    @discardableResult
    func upsert(_ d: TVDevice) -> TVDevice {
        var d = d
        if let i = devices.firstIndex(where: { $0.id == d.id || (!d.mac.isEmpty && $0.mac == d.mac) || $0.ip == d.ip }) {
            let old = devices[i]
            d.id = old.id
            if d.room.isEmpty { d.room = old.room }
            if d.powerMode == "unknown" { d.powerMode = old.powerMode }
            if d.name.isEmpty { d.name = old.name }
            devices[i] = d
        } else {
            devices.append(d)
        }
        save()
        return d
    }

    func update(_ d: TVDevice) {
        guard let i = devices.firstIndex(where: { $0.id == d.id }) else { return }
        devices[i] = d
        save()
    }

    func remove(id: String) {
        devices.removeAll { $0.id == id }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(devices).write(to: url, options: .atomic)
        } catch {}
    }
}
