import Cocoa
import SwiftUI
import PopBarCore
import PopBarDesign

struct VPSPage: View {
    @ObservedObject var model: VPSMonitorModel
    @State private var reportItem: VPSReportItem?

    init(model: VPSMonitorModel) {
        self.model = model
    }

    var body: some View {
        DSPageShell(L10n.t("VPS 监控", "VPS Monitor"),
                    subtitle: L10n.t("负载、性能与 VLESS 测试；VPS 自动来自 ~/.ssh/config，无结果或距上次检查超过 1 小时才自动检查",
                                     "Load, performance and VLESS tests; hosts come from ~/.ssh/config, auto-checked when results are missing or older than an hour")) {
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
            DSButton(L10n.t("刷新", "Refresh"), icon: "refresh-cw", kind: .ghost, iconSpacing: 3) {
                model.refresh()
            }
            .disabled(model.isBusy)
        } content: {
            if model.hosts.isEmpty {
                emptyState
            } else {
                summary
                ForEach(model.enabledHosts) { host in
                    VPSHostCard(model: model, host: host, result: model.results[host.id]) {
                        guard let result = model.results[host.id] else { return }
                        reportItem = VPSReportItem(id: host.id, host: host,
                                                   report: result.report,
                                                   checkedAt: result.checkedAt)
                    }
                }
                if !model.disabledHosts.isEmpty {
                    DSSectionHeader(L10n.t("已停用", "Disabled"))
                    ForEach(model.disabledHosts) { host in
                        VPSDisabledCard(model: model, host: host)
                    }
                }
            }
        }
        .sheet(item: $reportItem) { item in
            VPSReportSheet(item: item)
        }
    }

    private var emptyState: some View {
        DSEmptyState(icon: "server-cog",
                     title: L10n.t("没有读取到 SSH Host", "No SSH hosts found"),
                     message: L10n.t("在 ~/.ssh/config 里添加 Host 后点刷新。VPS 列表会自动读取，不需要手动添加。",
                                     "Add hosts to ~/.ssh/config and refresh. The list is read automatically."),
                     actionTitle: L10n.t("重新读取", "Reload")) {
            model.refresh()
        }
        .dsCardBackground()
    }

    private var summary: some View {
        HStack(spacing: 8) {
            let enabled = model.enabledHosts.count
            let online = model.onlineCount
            DSChip("\(online)/\(enabled) \(L10n.t("在线", "online"))",
                   tone: enabled == 0 ? .neutral : (online == enabled ? .success : (online == 0 ? .danger : .warning)),
                   icon: "server-cog")
            if !model.disabledHosts.isEmpty {
                DSChip("\(model.disabledHosts.count) \(L10n.t("停用", "disabled"))",
                       tone: .neutral, icon: "power")
            }
            if model.securityWarningCount > 0 {
                DSChip("\(model.securityWarningCount) \(L10n.t("项安全提醒", "security warnings"))",
                       tone: .warning, icon: "shield")
            }
            if model.vlessTestedCount > 0 {
                DSChip("VLESS \(model.vlessOKCount)/\(model.vlessTestedCount)",
                       tone: model.vlessOKCount == model.vlessTestedCount ? .success : .warning,
                       icon: "globe")
            }
            Spacer()
            if let last = model.lastRefresh {
                Text(L10n.t("上次检查 \(Self.clock.string(from: last))", "Last check \(Self.clock.string(from: last))"))
                    .font(DS.small).foregroundStyle(DS.faint)
            }
        }
        .padding(.horizontal, 4)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

private struct VPSHostCard: View {
    @ObservedObject var model: VPSMonitorModel
    let host: VPSHost
    let result: VPSHostResult?
    let onReport: () -> Void

    private var remote: VPSRemoteSnapshot? { result?.remote }
    private var isRefreshing: Bool { model.isRefreshing(host) }
    private var busy: Bool { model.isBusy }

    var body: some View {
        DSCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let result {
                    if result.online, let remote {
                        metrics(remote)
                        vless(result: result, remote: remote)
                        security(remote)
                    } else {
                        offline(result)
                    }
                } else if busy {
                    checking
                } else {
                    notChecked
                }
                footer
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.hosts.first(where: { $0.id == host.id })?.enabled ?? host.enabled },
                set: { model.setEnabled(host, $0) })
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let result {
                Text(L10n.t("检查于 \(Self.clock.string(from: result.checkedAt))",
                            "Checked \(Self.clock.string(from: result.checkedAt))"))
                    .font(DS.small).foregroundStyle(DS.faint)
            }
            Spacer()
            DSButton(isRefreshing ? L10n.t("刷新中…", "Refreshing…") : L10n.t("刷新", "Refresh"),
                     icon: "refresh-cw", kind: .ghost, iconSpacing: 3) { model.refresh(host) }
                .disabled(busy)
            DSButton(L10n.t("报告", "Report"), icon: "file-text", kind: .secondary, iconSpacing: 3, action: onReport)
                .disabled(result == nil)
        }
    }

    private var statusColor: Color {
        guard let result else { return DS.faint }
        if !result.online { return DS.danger }
        if result.vlessChecks.contains(where: { $0.check.state == .failed }) { return DS.danger }
        if result.vlessChecks.contains(where: { $0.speed?.state == .failed }) { return DS.danger }
        if let remote, !remote.securityWarnings.isEmpty { return DS.warning }
        return DS.success
    }

    private var header: some View {
        HStack(spacing: 10) {
            DSIconTile("server-cog", color: statusColor, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(DS.font(14, .semibold)).foregroundStyle(DS.text)
                Text(subtitle).font(DS.small).foregroundStyle(DS.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            DSToggle(isOn: enabledBinding)
                .help(L10n.t("开启或停用这台 VPS 的监控", "Enable or disable monitoring for this VPS"))
            if let result {
                DSChip(result.online ? L10n.t("在线", "Online") : L10n.t("离线", "Offline"),
                       tone: result.online ? .success : .danger,
                       icon: result.online ? "check" : "x")
                if result.online, let ms = result.latencyMs {
                    Text("\(ms) ms").font(DS.small.monospacedDigit()).foregroundStyle(DS.faint)
                }
            }
        }
    }

    private var subtitle: String {
        var parts = [host.sshAlias]
        if let remote, !remote.osName.isEmpty { parts.append(remote.osName) }
        if let remote, !remote.kernel.isEmpty { parts.append(remote.kernel) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func metrics(_ r: VPSRemoteSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                VPSMetric(label: "CPU", value: r.cpuPercent,
                          detail: "load \(Self.load(r.load))", foot: "")
                VPSMetric(label: L10n.t("内存", "Memory"), value: r.memPercent,
                          detail: "\(Self.bytes(r.memUsedKB)) / \(Self.bytes(r.memTotalKB))",
                          foot: r.swapTotalKB > 0
                            ? "swap \(Self.bytes(max(0, r.swapTotalKB - r.swapFreeKB))) / \(Self.bytes(r.swapTotalKB))"
                            : L10n.t("无 swap", "No swap"))
                VPSMetric(label: L10n.t("磁盘", "Disk"), value: r.diskPercent,
                          detail: "\(Self.bytes(r.diskUsedKB)) / \(Self.bytes(r.diskTotalKB))",
                          foot: "")
            }
            HStack(spacing: 6) {
                DSChip("\(r.cores) \(L10n.t("核", "cores"))", tone: .neutral, icon: "cpu")
                DSChip(Self.uptime(r.uptime), tone: .neutral, icon: "clock")
                if !r.loadWarnings.isEmpty {
                    DSChip(L10n.t("负载告警", "Load warning"), tone: .warning, icon: "triangle-alert")
                }
                Spacer()
            }
        }
    }

    /// 卡片上只保留安全评分与待处理项；完整信息在报告里。
    private func security(_ r: VPSRemoteSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.t("安全", "Security")).font(DS.font(12, .semibold)).foregroundStyle(DS.text)
                DSChip("\(r.securityScore) / 100", tone: Self.scoreTone(r.securityScore), icon: "shield-check")
                if r.securityWarnings.isEmpty {
                    DSChip(L10n.t("无告警", "No warnings"), tone: .success, icon: "check")
                } else {
                    DSChip(L10n.t("\(r.securityWarnings.count) 项待处理", "\(r.securityWarnings.count) to fix"),
                           tone: .warning, icon: "triangle-alert")
                }
                Spacer()
                Text("SSH \(r.sshKeyOnly ? L10n.t("密钥", "key") : L10n.t("密码", "password")) · fail2ban \(r.fail2banBanned) · \(r.firewallKind)")
                    .font(DS.small).foregroundStyle(DS.faint).lineLimit(1)
            }
            if !r.securityWarnings.isEmpty {
                Text(r.securityWarnings.joined(separator: " · "))
                    .font(DS.small).foregroundStyle(DS.warning).lineLimit(2)
            }
        }
    }

    private func vless(result: VPSHostResult, remote: VPSRemoteSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("VLESS").font(DS.font(12, .semibold)).foregroundStyle(DS.text)
                DSChip(Self.xrayVersion(remote), tone: remote.xrayRunning ? .success : .danger, icon: "server-cog")
                if let tcp = result.tcp {
                    DSChip(tcp.ok ? "TCP \(tcp.latencyMs ?? 0) ms" : L10n.t("端口不通", "Port unreachable"),
                           tone: tcp.ok ? .success : .danger, icon: "wifi")
                }
                Spacer()
            }
            if result.vlessChecks.isEmpty {
                Text(L10n.t("未发现 VLESS 链接；请检查服务器客户端文件或 Xray inbound 配置。",
                            "No VLESS link found; check the server client file or Xray inbound config."))
                    .font(DS.small).foregroundStyle(DS.faint)
            } else {
                ForEach(result.vlessChecks) { link in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            DSChip(link.name, tone: .neutral, icon: "link")
                            DSChip(Self.vlessLabel(link.check), tone: Self.vlessTone(link.check), icon: "globe")
                            if let speed = link.speed {
                                DSChip(Self.speedLabel(speed), tone: Self.speedTone(speed), icon: "gauge")
                            }
                            Text(link.endpoint).font(DS.mono).foregroundStyle(DS.faint).lineLimit(1)
                            Spacer(minLength: 6)
                            DSButton(L10n.t("复制", "Copy"), icon: "copy", kind: .ghost, iconSpacing: 3) {
                                let text = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
                                PasteboardGuard.write(text)
                            }
                            .disabled(link.url.isEmpty)
                            DSButton(L10n.t("连通性", "Connectivity"), icon: "wifi",
                                     kind: .ghost, iconSpacing: 3) {
                                model.testConnectivity(host: host, link: link)
                            }
                            .disabled(model.isBusy)
                            DSButton(L10n.t("测速", "Speed"), icon: "gauge",
                                     kind: .ghost, iconSpacing: 3) {
                                model.testSpeed(host: host, link: link)
                            }
                            .disabled(model.isBusy)
                            if model.isTestingConnectivity(host: host, link: link)
                                || model.isTestingSpeed(host: host, link: link) {
                                ProgressView().controlSize(.small)
                            }
                        }
                        if !link.check.message.isEmpty {
                            Text(link.check.message)
                                .font(DS.small)
                                .foregroundStyle(link.check.state == .failed ? DS.danger : DS.faint)
                                .lineLimit(2)
                        }
                        if let speed = link.speed, speed.state == .failed, !speed.message.isEmpty {
                            Text(speed.message)
                                .font(DS.small).foregroundStyle(DS.danger).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func offline(_ result: VPSHostResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.error ?? L10n.t("无法连接", "Unreachable"))
                .font(DS.small).foregroundStyle(DS.danger)
            Text(L10n.t("先在终端确认 ssh \(host.sshAlias) 可以直接登录。",
                        "First make sure ssh \(host.sshAlias) works in Terminal."))
                .font(DS.small).foregroundStyle(DS.faint)
        }
    }

    private var checking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.t("检查中…", "Checking…")).font(DS.small).foregroundStyle(DS.muted)
        }
    }

    private var notChecked: some View {
        HStack(spacing: 8) {
            Icon("clock", size: 14, color: DS.faint)
            Text(L10n.t("尚未检查，点下方「刷新」", "Not checked yet; use Refresh below"))
                .font(DS.small).foregroundStyle(DS.muted)
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func scoreTone(_ score: Int) -> DSTone {
        if score >= 85 { return .success }
        if score >= 65 { return .warning }
        return .danger
    }

    private static func load(_ l: [Double]) -> String {
        l.map { String(format: "%.2f", $0) }.joined(separator: " / ")
    }

    private static func bytes(_ kb: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: max(0, kb) * 1024)
    }

    private static func uptime(_ seconds: Double) -> String {
        let days = Int(seconds / 86400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600)
        if days > 0 { return L10n.t("\(days) 天 \(hours) 小时", "\(days)d \(hours)h") }
        return L10n.t("\(hours) 小时", "\(hours)h")
    }

    private static func xrayVersion(_ r: VPSRemoteSnapshot) -> String {
        guard r.xrayRunning else { return L10n.t("Xray 未运行", "Xray off") }
        let v = r.xrayVersion.split(separator: " ").prefix(2).joined(separator: " ")
        return v.isEmpty ? "Xray" : v
    }

    private static func vlessLabel(_ v: VLESSCheck) -> String {
        switch v.state {
        case .ok: return L10n.t("端到端 204 · \(v.latencyMs ?? 0) ms", "E2E 204 · \(v.latencyMs ?? 0) ms")
        case .failed: return L10n.t("端到端失败", "E2E failed")
        case .skipped: return L10n.t("未测试", "Not tested")
        }
    }

    private static func vlessTone(_ v: VLESSCheck) -> DSTone {
        switch v.state {
        case .ok: return .success
        case .failed: return .danger
        case .skipped: return .neutral
        }
    }

    private static func speedLabel(_ speed: VLESpeedCheck) -> String {
        if speed.state == .ok, let mb = speed.megabytesPerSecond {
            return String(format: "%.1f MB/s", mb)
        }
        return L10n.t("测速失败", "Speed failed")
    }

    private static func speedTone(_ speed: VLESpeedCheck) -> DSTone {
        speed.state == .ok ? .success : .danger
    }
}

private struct VPSDisabledCard: View {
    @ObservedObject var model: VPSMonitorModel
    let host: VPSHost

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.hosts.first(where: { $0.id == host.id })?.enabled ?? host.enabled },
                set: { model.setEnabled(host, $0) })
    }

    var body: some View {
        HStack(spacing: 10) {
            DSIconTile("server-cog", color: DS.muted, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(DS.font(13, .medium)).foregroundStyle(DS.text2)
                Text(host.sshAlias).font(DS.small).foregroundStyle(DS.faint)
            }
            Spacer()
            DSChip(L10n.t("已停用", "Disabled"), tone: .neutral, icon: "power")
            DSToggle(isOn: enabledBinding)
                .help(L10n.t("开启这台 VPS 的监控", "Enable monitoring for this VPS"))
        }
        .padding(14)
        .dsCardBackground()
    }
}

private struct VPSReportItem: Identifiable {
    let id: String
    let host: VPSHost
    let report: String
    let checkedAt: Date
}

private struct VPSReportSheet: View {
    let item: VPSReportItem
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DSIconTile("file-text", color: DS.accent, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("检测报告", "Health Report"))
                        .font(DS.font(16, .semibold)).foregroundStyle(DS.text)
                    Text("\(item.host.displayName) · \(item.host.sshAlias)")
                        .font(DS.small).foregroundStyle(DS.muted).lineLimit(1)
                }
                Spacer()
                DSIconButton("x", help: L10n.t("关闭", "Close"), size: 28) { dismiss() }
            }
            ScrollView {
                Text(item.report)
                    .font(DS.mono)
                    .foregroundStyle(DS.text2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).fill(DS.surface2))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .strokeBorder(DS.border, lineWidth: 1))
            HStack(spacing: 8) {
                Text(L10n.t("检查于 \(Self.clock.string(from: item.checkedAt))",
                            "Checked \(Self.clock.string(from: item.checkedAt))"))
                    .font(DS.small).foregroundStyle(DS.faint)
                Spacer()
                DSButton(L10n.t("关闭", "Close"), kind: .ghost) { dismiss() }
                DSButton(copied ? L10n.t("已复制", "Copied") : L10n.t("复制报告", "Copy Report"),
                         icon: copied ? "check" : "copy", kind: .primary, iconSpacing: 3) {
                    PasteboardGuard.write(item.report)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 560)
        .background(DS.bg)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

private struct VPSMetric: View {
    let label: String
    let value: Double
    let detail: String
    let foot: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label).font(DS.small).foregroundStyle(DS.muted)
                Spacer(minLength: 0)
                Text("\(Int(value.rounded()))%").font(DS.small.monospacedDigit()).foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.surface2)
                    Capsule().fill(tint)
                        .frame(width: max(4, geo.size.width * min(max(value, 0), 100) / 100))
                }
            }
            .frame(height: 5)
            Text(detail).font(DS.small).foregroundStyle(DS.faint).lineLimit(1)
            if !foot.isEmpty {
                Text(foot).font(DS.small).foregroundStyle(DS.faint).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tint: Color {
        if value >= 90 { return DS.danger }
        if value >= 75 { return DS.warning }
        return DS.success
    }
}
