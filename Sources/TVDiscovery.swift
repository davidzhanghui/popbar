import Foundation
import Network

/// 局域网发现电视:5555 端口扫描(找开了 ADB 的)+ SSDP(看到没开 ADB 的 DLNA 电视)+ ARP 取 MAC。
/// 整个网段 6–10 秒扫完;首次扫描会触发 macOS「本地网络」授权弹窗。
enum TVDiscovery {
    struct LocalNet: Equatable { var ip: String; var mask: String }

    /// 本机主要的私有 IPv4 网段(优先 en0)
    static func localNet() -> LocalNet? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found: [(name: String, net: LocalNet)] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = cur.pointee.ifa_netmask else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            func str(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
                return String(cString: buf)
            }
            let ip = str(addr)
            guard isPrivate(ip) else { continue }
            found.append((name, LocalNet(ip: ip, mask: str(mask))))
        }
        return (found.first { $0.name == "en0" } ?? found.first)?.net
    }

    static func isPrivate(_ ip: String) -> Bool {
        guard let v = TVParse.ipv4(ip) else { return false }
        return v >> 24 == 10 || v >> 20 == 0xAC1 || v >> 16 == 0xC0A8
    }

    // MARK: 端口探测

    /// 单次 TCP 连接探测:超时或失败返回 false
    static func portOpen(_ host: String, port: Int = TVParse.adbPort, timeout: TimeInterval = 0.5) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tcp)
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { ok in
                if once.fire() { conn.cancel(); cont.resume(returning: ok) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// 端口之外再做一次真正的 ADB 协议握手。透明代理(TUN 模式的 v2ray 等)会替任意地址完成 TCP 握手,
    /// 只看端口会把整个网段都当成电视;真 adbd 才会回 CNXN / AUTH 报文。
    /// 用 POSIX socket 而不是 NWConnection:实测 adbd 会对后者的首包直接 RST
    static func adbHandshake(_ host: String, timeout: TimeInterval = 1.5) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: adbHandshakeSync(host, timeout: timeout)) }
        }
    }

    static func adbHandshakeSync(_ host: String, timeout: TimeInterval) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(TVParse.adbPort).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        // 非阻塞连接 + poll 等待,超时可控
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { return false }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return false }
        }
        _ = fcntl(fd, F_SETFL, flags)   // 回到阻塞,收发用超时控制
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let packet = [UInt8](TVParse.adbConnectPacket())
        guard send(fd, packet, packet.count, 0) == packet.count else { return false }
        var buf = [UInt8](repeating: 0, count: 24)
        var got = 0
        while got < 24 {
            let n = recv(fd, &buf[got], 24 - got, 0)
            if n <= 0 { return false }
            got += n
        }
        return TVParse.isADBReply(Data(buf))
    }

    static func scanADB(hosts: [String], concurrency: Int = 100) async -> [String] {
        var open: [String] = []
        await withTaskGroup(of: String?.self) { group in
            var it = hosts.makeIterator()
            func next() {
                if let h = it.next() { group.addTask { await portOpen(h) ? (await adbHandshake(h) ? h : nil) : nil } }
            }
            for _ in 0..<min(concurrency, hosts.count) { next() }
            while let r = await group.next() {
                if let r { open.append(r) }
                next()
            }
        }
        return open
    }

    // MARK: ARP

    static func arpTable() -> [String: String] {
        TVParse.parseARP(ShellRun.run("/usr/sbin/arp", ["-an"], timeout: 5).out)
    }

    // MARK: SSDP

    struct SSDPHit { var ip: String; var location: String }

    /// 发 M-SEARCH 并收一阵子应答(阻塞,放后台线程)
    static func ssdpSearch(duration: TimeInterval = 3) -> [SSDPHit] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)

        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n"
            + "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
        let bytes = Array(msg.utf8)
        for _ in 0..<2 {
            withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(fd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var hits: [String: SSDPHit] = [:]
        let end = Date().addingTimeInterval(duration)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < end {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &len)
                }
            }
            guard n > 0 else { continue }
            let h = TVParse.parseSSDPHeaders(String(decoding: buf[0..<n], as: UTF8.self))
            guard let loc = h["LOCATION"] else { continue }
            var addr = from.sin_addr
            var ipbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &ipbuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipbuf)
            hits[ip] = SSDPHit(ip: ip, location: loc)
        }
        return Array(hits.values)
    }

    static func describe(_ hit: SSDPHit) async -> (name: String, manufacturer: String) {
        guard let url = URL(string: hit.location), url.scheme == "http" else { return ("", "") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return ("", "") }
        let xml = String(decoding: data, as: UTF8.self)
        return (TVParse.cleanName(TVParse.xmlTag(xml, "friendlyName")), TVParse.xmlTag(xml, "manufacturer"))
    }

    // MARK: 汇总

    /// 扫描整个网段并识别每台设备是什么。
    /// 1) 端口 + ADB 协议握手找出真 ADB 设备,同时 SSDP 收集 DLNA 设备;
    /// 2) 对 ADB 设备 connect 后读 getprop(型号 / 厂商 / 类型),判定是电视、待授权还是别的 Android 设备;
    /// 3) 没开 ADB 的 SSDP 设备只保留「像电视」的(有已知品牌、不是路由器 / 打印机)。
    /// 结果电视在前。progress 汇报阶段文字。
    static func scan(adb: String, progress: @escaping @Sendable (String) -> Void = { _ in }) async -> [TVCandidate] {
        guard let net = localNet() else { return [] }
        let hosts = TVParse.hosts(ip: net.ip, mask: net.mask).filter { $0 != net.ip }

        progress(L10n.t("正在扫描网段(约 10 秒)…", "Scanning the subnet (~10 s)…"))
        async let adbOpen = scanADB(hosts: hosts)
        async let ssdp: [SSDPHit] = await Task.detached { ssdpSearch() }.value
        let (open, hits) = await (adbOpen, ssdp)
        // 连接尝试已经把对端写进 ARP 表,此时再读
        let arp = arpTable()

        var byIP: [String: TVCandidate] = [:]
        for ip in open { byIP[ip] = TVCandidate(ip: ip, mac: arp[ip] ?? "", adbOpen: true, kind: .otherAndroid) }
        await withTaskGroup(of: (String, String, String).self) { group in
            for h in hits where h.ip != net.ip {
                group.addTask { let d = await describe(h); return (h.ip, d.name, d.manufacturer) }
            }
            for await (ip, name, maker) in group {
                var c = byIP[ip] ?? TVCandidate(ip: ip, mac: arp[ip] ?? "")
                c.friendlyName = name
                c.manufacturer = maker
                byIP[ip] = c
            }
        }

        // 识别 ADB 设备:并发读型号。电视首次连接会弹授权框,所以只对握手成功的少数设备做
        let adbHosts = byIP.values.filter(\.adbOpen).map(\.ip)
        var done = 0
        await withTaskGroup(of: (String, TVAdb.Inspection).self) { group in
            var it = adbHosts.makeIterator()
            func next() {
                if let ip = it.next() {
                    group.addTask { (ip, await TVAdb(adb: adb, serial: "\(ip):\(TVParse.adbPort)").inspect()) }
                }
            }
            for _ in 0..<min(6, adbHosts.count) { next() }
            while let (ip, result) = await group.next() {
                done += 1
                progress(L10n.t("正在识别设备 \(done)/\(adbHosts.count)…", "Identifying devices \(done)/\(adbHosts.count)…"))
                if var c = byIP[ip] {
                    switch result {
                    case .info(let model, let maker, _, let chars):
                        c.model = model
                        c.manufacturer = maker
                        c.brand = TVBrand.guess(mac: c.mac, texts: [maker, model, c.friendlyName])
                        c.kind = TVBrand.looksLikeTV(characteristics: chars, brand: c.brand, model: model) ? .tv : .otherAndroid
                    case .unauthorized:
                        c.brand = TVBrand.guess(mac: c.mac, texts: [c.manufacturer, c.friendlyName])
                        c.kind = .pending
                    case .unreachable:
                        byIP[ip] = nil
                        next()
                        continue
                    }
                    byIP[ip] = c
                }
                next()
            }
        }

        // 没开 ADB 的 DLNA 设备:路由器 / 打印机 / 品牌未知的一律不要,免得列表里全是噪音
        var out: [TVCandidate] = []
        for var c in byIP.values {
            if !c.adbOpen {
                c.brand = TVBrand.guess(mac: c.mac, texts: [c.manufacturer, c.friendlyName])
                if c.brand.isEmpty || TVBrand.looksLikeNonTVMedia(c.friendlyName + " " + c.manufacturer) { continue }
                c.kind = .mediaOnly
            }
            out.append(c)
        }
        return out.sorted { ($0.kind, TVParse.ipv4($0.ip) ?? 0) < ($1.kind, TVParse.ipv4($1.ip) ?? 0) }
    }

    // MARK: Wake-on-LAN

    static func magicPacket(mac: String) -> [UInt8]? {
        let hex = mac.filter(\.isHexDigit)
        guard hex.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return Array(repeating: 0xFF, count: 6) + Array((0..<16).map { _ in bytes }.joined())
    }

    @discardableResult
    static func sendWOL(mac: String) -> Bool {
        guard let payload = magicPacket(mac: mac) else { return false }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var targets = ["255.255.255.255"]
        if let n = localNet(), let b = TVParse.broadcast(ip: n.ip, mask: n.mask) { targets.append(b) }
        var sent = false
        for t in targets {
            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = UInt16(9).bigEndian
            inet_pton(AF_INET, t, &dest.sin_addr)
            let r = withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, payload, payload.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if r > 0 { sent = true }
        }
        return sent
    }
}
