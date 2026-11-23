import Darwin
import Foundation
import PopBarCore

/// 远程采集 + 本地端口检查 + 可选的 VLESS 端到端 204 测试。
enum VPSProbe {
    /// 所有命令都带失败兜底，最后一行 OK=1 表示脚本跑完。
    /// 只读取状态，不改服务器配置。
    static let remoteScript = #"""
export LC_ALL=C
printf 'HOSTNAME=%s\n' "$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null)"
if [ -r /etc/os-release ]; then . /etc/os-release; fi
printf 'OS_NAME=%s\n' "${PRETTY_NAME:-${NAME:-unknown}}"
printf 'OS_ID=%s\n' "${ID:-unknown}"
printf 'OS_VERSION=%s\n' "${VERSION_ID:-unknown}"
printf 'KERNEL=%s\n' "$(uname -r 2>/dev/null)"
printf 'UPTIME=%s\n' "$(cut -d. -f1 /proc/uptime 2>/dev/null)"
printf 'LOAD=%s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
printf 'CORES=%s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
C1=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat 2>/dev/null)
sleep 0.4
C2=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat 2>/dev/null)
T1=${C1%% *}; I1=${C1##* }; T2=${C2%% *}; I2=${C2##* }
DT=$((T2 - T1)); DI=$((I2 - I1))
if [ "$DT" -gt 0 ]; then CPU_PCT=$((100 * (DT - DI) / DT)); else CPU_PCT=0; fi
[ "$CPU_PCT" -lt 0 ] 2>/dev/null && CPU_PCT=0
[ "$CPU_PCT" -gt 100 ] 2>/dev/null && CPU_PCT=100
printf 'CPU_PCT=%s\n' "$CPU_PCT"
MEM=$(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^MemFree:/{f=$2}/^Buffers:/{b=$2}/^Cached:/{c=$2}END{if(a=="")a=f+b+c; print t+0, a+0}' /proc/meminfo 2>/dev/null)
printf 'MEM_TOTAL_KB=%s\n' "${MEM%% *}"
printf 'MEM_AVAIL_KB=%s\n' "${MEM##* }"
SWAP=$(awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{print t+0, f+0}' /proc/meminfo 2>/dev/null)
printf 'SWAP_TOTAL_KB=%s\n' "${SWAP%% *}"
printf 'SWAP_FREE_KB=%s\n' "${SWAP##* }"
DISK=$(df -Pk / 2>/dev/null | awk 'NR==2{p=$5; gsub("%","",p); print $2+0, $3+0, p+0}')
printf 'DISK_TOTAL_KB=%s\n' "${DISK%% *}"
REST=${DISK#* }; printf 'DISK_USED_KB=%s\n' "${REST%% *}"; printf 'DISK_PCT=%s\n' "${REST##* }"
XRAY_ACTIVE=$(systemctl is-active xray 2>/dev/null || true)
printf 'XRAY_ACTIVE=%s\n' "${XRAY_ACTIVE:-unknown}"
EXEC=$(systemctl show -p ExecStart --value xray 2>/dev/null)
XRAY_BIN=$(printf '%s' "$EXEC" | sed -n 's/.*path=\([^ ;}]*\).*/\1/p' | head -n1)
XRAY_VERSION=$(/usr/local/bin/xray version 2>/dev/null | head -n1)
if [ -z "$XRAY_VERSION" ] && command -v xray >/dev/null 2>&1; then XRAY_VERSION=$(xray version 2>/dev/null | head -n1); fi
if [ -z "$XRAY_VERSION" ] && [ -n "$XRAY_BIN" ] && [ -x "$XRAY_BIN" ]; then XRAY_VERSION=$("$XRAY_BIN" version 2>/dev/null | head -n1); fi
printf 'XRAY_VERSION=%s\n' "$XRAY_VERSION"
XRAY_PORTS=$(ss -lntp 2>/dev/null | awk '/xray/ {split($4,a,":"); p=a[length(a)]; if ($4 !~ /^(127\.|\[::1\])/) print p}' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
printf 'XRAY_PORTS=%s\n' "$XRAY_PORTS"
XRAY_CONFIG=$(printf '%s' "$EXEC" | sed -n 's/.*-config[ =]\([^ ;}]*\).*/\1/p' | head -n1)
if [ -z "$XRAY_CONFIG" ] && [ -f /usr/local/etc/xray/config.json ]; then XRAY_CONFIG=/usr/local/etc/xray/config.json; fi
if [ -n "$XRAY_CONFIG" ] && [ -f "$XRAY_CONFIG" ]; then
  printf 'XRAY_CONFIG=%s\n' "$XRAY_CONFIG"
  printf 'XRAY_CONFIG_MODE=%s\n' "$(stat -c %a "$XRAY_CONFIG" 2>/dev/null)"
  printf 'XRAY_CONFIG_OWNER=%s\n' "$(stat -c %U:%G "$XRAY_CONFIG" 2>/dev/null)"
fi
FAIL2BAN=$(systemctl is-active fail2ban 2>/dev/null || true)
printf 'FAIL2BAN=%s\n' "${FAIL2BAN:-unknown}"
if [ "$FAIL2BAN" = "active" ]; then
  JAILS=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ' ')
  BAN=0
  for j in $(printf '%s' "$JAILS" | tr ',' ' '); do
    N=$(fail2ban-client status "$j" 2>/dev/null | sed -n 's/.*Currently banned:[[:space:]]*//p' | tr -d ' ')
    [ -n "$N" ] && BAN=$((BAN + N))
  done
  printf 'FAIL2BAN_JAILS=%s\n' "$JAILS"
  printf 'FAIL2BAN_BANNED=%s\n' "$BAN"
fi
FIREWALL_KIND=""
FIREWALL=unknown
if command -v firewall-cmd >/dev/null 2>&1; then
  FS=$(firewall-cmd --state 2>/dev/null)
  if [ "$FS" = "running" ]; then FIREWALL_KIND=firewalld; FIREWALL=running; fi
fi
if [ -z "$FIREWALL_KIND" ] && command -v ufw >/dev/null 2>&1; then
  US=$(ufw status 2>/dev/null | head -n1 | sed 's/^Status:[[:space:]]*//')
  FIREWALL_KIND=ufw; FIREWALL=$US
fi
printf 'FIREWALL_KIND=%s\n' "$FIREWALL_KIND"
printf 'FIREWALL=%s\n' "$FIREWALL"
if command -v sshd >/dev/null 2>&1; then
  SSHT=$(sshd -T 2>/dev/null)
  SP=$(printf '%s\n' "$SSHT" | awk '$1=="passwordauthentication"{print $2; exit}')
  SX=$(printf '%s\n' "$SSHT" | awk '$1=="x11forwarding"{print $2; exit}')
  SM=$(printf '%s\n' "$SSHT" | awk '$1=="maxauthtries"{print $2; exit}')
  SR=$(printf '%s\n' "$SSHT" | awk '$1=="permitrootlogin"{print $2; exit}')
  printf 'SSH_PASSWORD=%s\nSSH_X11=%s\nSSH_MAXAUTH=%s\nSSH_ROOT=%s\n' "${SP:-unknown}" "${SX:-unknown}" "${SM:-unknown}" "${SR:-unknown}"
fi
PENDING=-1
AUTO=unknown
if command -v apt-get >/dev/null 2>&1; then
  PENDING=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst')
  AUTO=$(systemctl is-enabled unattended-upgrades 2>/dev/null || true)
elif command -v dnf >/dev/null 2>&1; then
  if command -v timeout >/dev/null 2>&1; then
    PENDING=$(timeout 12 dnf -q check-update 2>/dev/null | awk 'NF>=3 && $1 !~ /^Last/ {n++} END{print n+0}')
  else
    PENDING=$(dnf -q check-update 2>/dev/null | awk 'NF>=3 && $1 !~ /^Last/ {n++} END{print n+0}')
  fi
  AUTO=$(systemctl is-enabled dnf-automatic.timer 2>/dev/null || true)
fi
printf 'PENDING=%s\n' "${PENDING:--1}"
printf 'AUTO_UPDATES=%s\n' "${AUTO:-unknown}"
TIME_SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
if [ -z "$TIME_SYNC" ]; then TIME_SYNC=$(timedatectl 2>/dev/null | sed -n 's/.*synchronized: //p'); fi
printf 'TIME_SYNC=%s\n' "${TIME_SYNC:-unknown}"
if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then echo NEED_REBOOT=1; else echo NEED_REBOOT=0; fi
DOCKER=$(systemctl is-active docker 2>/dev/null || true)
printf 'DOCKER=%s\n' "${DOCKER:-unknown}"
VLESS_LINK=""
for f in /root/vless-client.txt /root/xray-client.txt; do
  if [ -r "$f" ]; then
    L=$(sed -n 's/^link=//p' "$f" | head -n1)
    if [ -z "$L" ]; then L=$(sed -n 's/^[[:space:]]*导入:[[:space:]]*//p' "$f" | head -n1); fi
    if [ -n "$L" ]; then VLESS_LINK=$L; break; fi
  fi
done
printf 'VLESS_LINK=%s\n' "$VLESS_LINK"
if command -v python3 >/dev/null 2>&1; then
  python3 - "${XRAY_CONFIG:-}" /usr/local/etc/xray/config.json /etc/xray/config.json /etc/xray/conf/*.json <<'PYAUTO'
import json, os, re, sys
from urllib.parse import urlencode, quote, urlparse, unquote

items, seen_urls = [], set()
for path in ["/root/vless-client.txt", "/root/xray-client.txt"]:
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except Exception:
        continue
    for match in re.findall(r"vless://[^\s\"'<>]+", text):
        url = match.strip()
        key = url.split("#", 1)[0]
        if not url or key in seen_urls:
            continue
        seen_urls.add(key)
        parsed = urlparse(url)
        name = unquote(parsed.fragment).strip()
        if not name:
            name = f"自动 {parsed.port}" if parsed.port else "自动"
        items.append({"name": name, "url": url})

if not items:
    paths, seen_paths = [], set()
    for raw in sys.argv[1:]:
        if not raw:
            continue
        path = os.path.realpath(raw)
        if path in seen_paths or not os.path.isfile(path):
            continue
        seen_paths.add(path)
        paths.append(path)

    seen_links = set()
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            continue
        if not isinstance(data, dict):
            continue
        inbounds = data.get("inbounds")
        if inbounds is None and data.get("protocol"):
            inbounds = [data]
        for ib in inbounds or []:
            if not isinstance(ib, dict) or ib.get("protocol") != "vless":
                continue
            stream = ib.get("streamSettings") or {}
            if stream.get("security") != "reality":
                continue
            if (stream.get("network") or "tcp") != "tcp":
                continue
            rs = stream.get("realitySettings") or {}
            pbk = rs.get("publicKey")
            if not pbk:
                continue
            port = ib.get("port")
            if isinstance(port, list):
                port = port[0] if port else None
            try:
                port = int(port)
            except Exception:
                continue
            names = rs.get("serverNames") or []
            sni = next((n for n in names if n), None) or rs.get("serverName")
            if not sni:
                sni = (rs.get("dest") or "").split(":")[0]
            if not sni:
                continue
            sids = rs.get("shortIds") or [""]
            if not isinstance(sids, list):
                sids = [sids]
            clients = (ib.get("settings") or {}).get("clients") or []
            for cl in clients:
                if not isinstance(cl, dict):
                    continue
                uid = cl.get("id")
                if not uid:
                    continue
                flow = cl.get("flow") or ""
                for sid in sids:
                    key = (uid, port, sni, pbk, str(sid))
                    if key in seen_links:
                        continue
                    seen_links.add(key)
                    q = [("encryption", "none")]
                    if flow:
                        q.append(("flow", flow))
                    q += [("security", "reality"), ("sni", sni), ("fp", "chrome"), ("pbk", pbk)]
                    if sid:
                        q.append(("sid", str(sid)))
                    q += [("type", "tcp"), ("headerType", "none")]
                    name = f"自动 {port}"
                    url = f"vless://{uid}@__HOST__:{port}?{urlencode(q)}#{quote(name)}"
                    items.append({"name": name, "url": url})

print("AUTO_VLESS_JSON=" + json.dumps(items, ensure_ascii=False, separators=(",", ":")))
PYAUTO
fi
printf 'OK=1\n'
"""#

    static func probe(_ host: VPSHost) async -> VPSHostResult {
        let alias = host.alias
        guard VPSHost.validAlias(alias) else {
            return .offline(host, error: L10n.t("SSH Host 为空或包含不支持的字符", "SSH host is empty or contains unsupported characters"))
        }

        let started = Date()
        async let destination = VPSHostResolver.resolve(alias)
        let out = await Shell.run(Shell.Request("/usr/bin/ssh", [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=3",
            "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=ERROR",
            alias, remoteScript,
        ], timeout: 22))
        let latency = Int(Date().timeIntervalSince(started) * 1000)

        guard out.ok else {
            let reason = out.error.isEmpty ? L10n.t("SSH 连接失败", "SSH connection failed") : out.error
            return .offline(host, error: reason)
        }
        guard let remote = VPSRemoteParser.parse(out.text) else {
            return .offline(host, error: L10n.t("远程输出无法解析", "Could not parse the remote output"))
        }

        let dest = await destination
        var result = VPSHostResult(host: host, online: true, error: nil, latencyMs: latency,
                                   remote: remote, tcp: nil, vlessChecks: [], checkedAt: Date())
        let primary: String
        if let auto = remote.autoLinks.first, let h = dest.host {
            primary = auto.url.replacingOccurrences(of: "__HOST__", with: h)
        } else {
            primary = remote.vlessLink
        }
        if let endpoint = VLESSEndpoint.parse(primary) {
            result.tcp = await tcpCheck(host: endpoint.host, port: endpoint.port)
        } else if let h = dest.host, let p = remote.xrayPorts.first {
            result.tcp = await tcpCheck(host: h, port: p)
        }

        result.vlessChecks = linkChecks(for: host, remote: remote, hostName: dest.host)
        return result
    }

    /// 只整理链接清单，不在整页刷新时自动跑端到端；连通性和测速由卡片按钮按需触发。
    /// 没有手工链接时先读客户端文件，再回退到服务器 Xray 配置里自动整理出的链接。
    private static func linkChecks(for host: VPSHost, remote: VPSRemoteSnapshot, hostName: String?) -> [VPSLinkCheck] {
        var links: [VPSLink] = []
        if !remote.autoLinks.isEmpty {
            let h = hostName ?? ""
            links = remote.autoLinks.map { original in
                var link = original
                if !h.isEmpty {
                    link.url = link.url.replacingOccurrences(of: "__HOST__", with: h)
                }
                link.id = "auto:" + link.url
                return link
            }
        } else {
            let auto = remote.vlessLink.trimmingCharacters(in: .whitespacesAndNewlines)
            if !auto.isEmpty {
                links = [VPSLink(id: "auto:" + auto, name: L10n.t("自动读取", "Auto"), url: auto)]
            }
        }
        return links.map { link in
            let endpoint = VLESSEndpoint.parse(link.url)
            let message = endpoint == nil ? L10n.t("VLESS 链接格式不支持", "Unsupported VLESS link") : ""
            return VPSLinkCheck(id: link.id,
                                name: link.displayName,
                                endpoint: endpoint?.display ?? "",
                                check: .skipped(message, endpoint: endpoint?.display ?? ""),
                                url: link.url,
                                speed: nil)
        }
    }

    static func tcpCheck(host: String, port: Int) async -> VPSTCPCheck {
        let started = Date()
        let out = await Shell.run(Shell.Request("/usr/bin/nc", ["-z", "-G", "4", "-w", "4", host, "\(port)"], timeout: 6))
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return VPSTCPCheck(host: host, port: port, ok: out.ok,
                           latencyMs: out.ok ? ms : nil,
                           error: out.ok ? nil : out.error)
    }
}

struct SSHDestination: Sendable {
    var host: String?
    var port: Int = 22
}

enum VPSHostResolver {
    /// `ssh -G` 会按 ~/.ssh/config 解析出最终 HostName，避免自己解析 Include / Match。
    static func resolve(_ alias: String) async -> SSHDestination {
        let out = await Shell.run(Shell.Request("/usr/bin/ssh", ["-G", alias], timeout: 5))
        guard out.ok else { return SSHDestination() }
        var dest = SSHDestination()
        for line in out.text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "hostname": dest.host = String(parts[1])
            case "port": dest.port = Int(parts[1]) ?? dest.port
            default: break
            }
        }
        return dest
    }
}

/// 用本机 xray 临时起一个 socks 入口，访问 generate_204 验证真正的 VLESS 链路。
/// 只用于测试，配置和监听都只在本机临时目录 / 127.0.0.1，测试完立即清理。
enum VPSXrayTester {
    static func findBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/xray",
            "/usr/local/bin/xray",
            "/Applications/V2rayU.app/Contents/Resources/bin/xray-core",
            "\(home)/.local/bin/xray",
            "\(home)/bin/xray",
            "/usr/bin/xray",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private struct XraySession {
        let pid: pid_t
        let port: Int
        let dir: URL
    }

    private enum XrayStartError: Error {
        case noBinary
        case failed(String)
    }

    static func run(_ endpoint: VLESSEndpoint) async -> VLESSCheck {
        switch await startSession(endpoint) {
        case .failure(.noBinary):
            return .skipped(L10n.t("未找到本地 xray，只检查了端口", "Local xray not found; checked the port only"),
                            endpoint: endpoint.display)
        case .failure(.failed(let message)):
            return VLESSCheck(state: .failed, latencyMs: nil, message: message, endpoint: endpoint.display)
        case .success(let session):
            defer { finish(session) }
            let out = await Shell.run(Shell.Request("/usr/bin/curl", [
                "--socks5-hostname", "127.0.0.1:\(session.port)",
                "-sS", "-o", "/dev/null", "--max-time", "12",
                "-w", "%{http_code} %{time_starttransfer}",
                "https://www.gstatic.com/generate_204",
            ], timeout: 15))
            guard out.ok else {
                let reason = out.error.isEmpty ? L10n.t("端到端请求失败", "End-to-end request failed") : out.error
                return VLESSCheck(state: .failed, latencyMs: nil, message: reason, endpoint: endpoint.display)
            }
            let line = out.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            let code = parts.first.flatMap { Int($0) } ?? 0
            let seconds = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
            let ok = code == 204 || code == 200
            return VLESSCheck(state: ok ? .ok : .failed,
                              latencyMs: ok ? Int(seconds * 1000) : nil,
                              message: ok ? "" : L10n.t("HTTP \(code)", "HTTP \(code)"),
                              endpoint: endpoint.display)
        }
    }

    /// 通过临时 xray 下载 10MB，返回 MB/s。只在用户点「测速」时运行。
    static func speedTest(_ endpoint: VLESSEndpoint) async -> VLESpeedCheck {
        switch await startSession(endpoint) {
        case .failure(.noBinary):
            return VLESpeedCheck(state: .failed, megabytesPerSecond: nil, latencyMs: nil,
                                 message: L10n.t("未找到本地 xray", "Local xray not found"))
        case .failure(.failed(let message)):
            return VLESpeedCheck(state: .failed, megabytesPerSecond: nil, latencyMs: nil, message: message)
        case .success(let session):
            defer { finish(session) }
            let out = await Shell.run(Shell.Request("/usr/bin/curl", [
                "--socks5-hostname", "127.0.0.1:\(session.port)",
                "-sS", "-o", "/dev/null", "--max-time", "30",
                "-w", "%{http_code} %{speed_download} %{time_starttransfer}",
                "https://speed.cloudflare.com/__down?bytes=10000000",
            ], timeout: 38))
            guard out.ok else {
                let reason = out.error.isEmpty ? L10n.t("测速请求失败", "Speed test failed") : out.error
                return VLESpeedCheck(state: .failed, megabytesPerSecond: nil, latencyMs: nil, message: reason)
            }
            let line = out.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            let code = parts.first.flatMap { Int($0) } ?? 0
            let bytesPerSecond = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
            let seconds = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
            let ok = (code == 200 || code == 206) && bytesPerSecond > 0
            return VLESpeedCheck(state: ok ? .ok : .failed,
                                 megabytesPerSecond: ok ? bytesPerSecond / 1_000_000 : nil,
                                 latencyMs: ok ? Int(seconds * 1000) : nil,
                                 message: ok ? "" : L10n.t("HTTP \(code)", "HTTP \(code)"))
        }
    }

    private static func startSession(_ endpoint: VLESSEndpoint) async -> Result<XraySession, XrayStartError> {
        guard let binary = findBinary() else { return .failure(.noBinary) }
        guard let port = freePort() else {
            return .failure(.failed(L10n.t("无法分配本地测试端口", "Could not allocate a local test port")))
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopBarVPS-\(UUID().uuidString)", isDirectory: true)
        let config = dir.appendingPathComponent("config.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let data = try JSONSerialization.data(withJSONObject: configuration(endpoint, port: port),
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return .failure(.failed(L10n.t("无法写入临时配置", "Could not write the temporary config")))
        }
        let spawned = Shell.spawnDetached(binary, ["run", "-c", config.path])
        guard case .success(let pid) = spawned else {
            try? FileManager.default.removeItem(at: dir)
            return .failure(.failed(L10n.t("本地 xray 启动失败", "Could not start local xray")))
        }
        guard await waitForPort(port) else {
            stop(pid)
            try? FileManager.default.removeItem(at: dir)
            return .failure(.failed(L10n.t("本地 xray 未就绪", "Local xray did not become ready")))
        }
        return .success(XraySession(pid: pid, port: port, dir: dir))
    }

    private static func finish(_ session: XraySession) {
        stop(session.pid)
        try? FileManager.default.removeItem(at: session.dir)
    }

    private static func configuration(_ e: VLESSEndpoint, port: Int) -> [String: Any] {
        var user: [String: Any] = ["id": e.uuid, "encryption": "none"]
        if !e.flow.isEmpty { user["flow"] = e.flow }
        return [
            "log": ["loglevel": "warning"],
            "inbounds": [[
                "listen": "127.0.0.1",
                "port": port,
                "protocol": "socks",
                "settings": ["auth": "noauth", "udp": false],
            ]],
            "outbounds": [[
                "protocol": "vless",
                "settings": ["vnext": [[
                    "address": e.host,
                    "port": e.port,
                    "users": [user],
                ]]],
                "streamSettings": [
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": [
                        "serverName": e.sni,
                        "fingerprint": e.fingerprint,
                        "publicKey": e.publicKey,
                        "shortId": e.shortID,
                        "spiderX": "",
                    ],
                ],
            ]],
        ]
    }

    private static func stop(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        usleep(120_000)
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
    }

    private static func waitForPort(_ port: Int) async -> Bool {
        for _ in 0..<45 {
            if canConnect(port) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private static func canConnect(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
