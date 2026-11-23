import Cocoa
import SwiftUI
import PopBarCore
import PopBarDesign

private enum VPSFilter: Hashable {
    case all, attention, disabled
}

struct VPSPage: View {
    @ObservedObject var model: VPSMonitorModel
    @State private var reportItem: VPSReportItem?
    @State private var filter: VPSFilter = .all
    @State private var query = ""
    @State private var collapsedIDs: Set<String> = []
    @State private var showDisabledInAll = false

    init(model: VPSMonitorModel) {
        self.model = model
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matchesQuery(_ host: VPSHost) -> Bool {
        guard !trimmedQuery.isEmpty else { return true }
        if host.displayName.lowercased().contains(trimmedQuery)
            || host.sshAlias.lowercased().contains(trimmedQuery) {
            return true
        }
        if let result = model.results[host.id] {
            if let os = result.remote?.osName, os.lowercased().contains(trimmedQuery) { return true }
            if result.vlessChecks.contains(where: {
                $0.endpoint.lowercased().contains(trimmedQuery)
                    || $0.name.lowercased().contains(trimmedQuery)
            }) {
                return true
            }
        }
        return false
    }

    private var visibleEnabledHosts: [VPSHost] {
        guard filter != .disabled else { return [] }
        return model.enabledHosts.filter { host in
            if filter == .attention {
                guard let result = model.results[host.id], result.attention else { return false }
            }
            return matchesQuery(host)
        }
    }

    private var visibleDisabledHosts: [VPSHost] {
        guard filter != .attention else { return [] }
        return model.disabledHosts.filter(matchesQuery)
    }

    private var allVisibleCollapsed: Bool {
        !visibleEnabledHosts.isEmpty && visibleEnabledHosts.allSatisfy { collapsedIDs.contains($0.id) }
    }

    private var filterOptions: [(VPSFilter, String)] {
        var opts: [(VPSFilter, String)] = [
            (.all, L10n.t("全部 \(model.hosts.count)", "All \(model.hosts.count)")),
            (.attention, L10n.t("需关注 \(model.attentionCount)", "Attention \(model.attentionCount)")),
        ]
        if !model.disabledHosts.isEmpty || filter == .disabled {
            opts.append((.disabled, L10n.t("已停用 \(model.disabledHosts.count)", "Disabled \(model.disabledHosts.count)")))
        }
        return opts
    }

    var body: some View {
        DSPageShell(L10n.t("VPS 监控", "VPS Monitor"),
                    subtitle: L10n.t("自动读取 ~/.ssh/config，按需测试 VLESS 链路与安全状态",
                                     "Auto-loaded from ~/.ssh/config with on-demand VLESS and security checks")) {
            if visibleEnabledHosts.count >= 2 {
                DSIconButton(allVisibleCollapsed ? "chevron-down" : "chevron-up",
                             help: allVisibleCollapsed
                                ? L10n.t("展开全部卡片", "Expand all cards")
                                : L10n.t("收起全部卡片", "Collapse all cards"),
                             size: 30) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        if allVisibleCollapsed {
                            collapsedIDs.subtract(visibleEnabledHosts.map(\.id))
                        } else {
                            collapsedIDs.formUnion(visibleEnabledHosts.map(\.id))
                        }
                    }
                }
            }
            if model.refreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("检查中…", "Checking…"))
                        .font(DS.font(12, .medium)).foregroundStyle(DS.muted)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
            } else {
                DSButton(L10n.t("全部刷新", "Refresh All"), icon: "refresh-cw", kind: .secondary, iconSpacing: 5) {
                    model.refresh()
                }
                .disabled(model.isBusy)
            }
        } content: {
            if model.hosts.isEmpty {
                emptyState
            } else {
                overviewStrip
                toolbar
                if visibleEnabledHosts.isEmpty && (filter != .all || visibleDisabledHosts.isEmpty) {
                    filteredEmptyState
                } else {
                    ForEach(visibleEnabledHosts) { host in
                        VPSHostCard(
                            model: model,
                            host: host,
                            result: model.results[host.id],
                            collapsed: collapsedIDs.contains(host.id),
                            onToggleCollapse: {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    if collapsedIDs.contains(host.id) {
                                        collapsedIDs.remove(host.id)
                                    } else {
                                        collapsedIDs.insert(host.id)
                                    }
                                }
                            },
                            onReport: {
                                guard let result = model.results[host.id] else { return }
                                reportItem = VPSReportItem(id: host.id, host: host,
                                                           result: result)
                            }
                        )
                    }
                    if !visibleDisabledHosts.isEmpty {
                        disabledSection
                    }
                }
            }
        }
        .sheet(item: $reportItem) { item in
            VPSReportSheet(item: item)
        }
        .onChange(of: model.disabledHosts.count) { _, count in
            if count == 0 && filter == .disabled { filter = .all }
        }
    }

    private var emptyState: some View {
        DSEmptyState(icon: "server-cog",
                     title: L10n.t("没有读取到 SSH Host", "No SSH hosts found"),
                     message: L10n.t("在 ~/.ssh/config 里添加 Host 后点刷新。VPS 列表会自动读取，不需要手动添加。",
                                     "Add hosts to ~/.ssh/config and refresh. The list is loaded automatically."),
                     actionTitle: L10n.t("重新读取", "Reload")) {
            model.refresh()
        }
        .dsCardBackground()
    }

    private var filteredEmptyState: some View {
        DSCard(padding: 24) {
            HStack(spacing: 12) {
                DSIconTile(filter == .attention ? "shield-check" : "search",
                           color: filter == .attention ? DS.success : DS.muted,
                           size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(filter == .attention && trimmedQuery.isEmpty
                         ? L10n.t("当前没有需要关注的 VPS", "All monitored hosts look healthy")
                         : L10n.t("没有匹配的 VPS", "No matching hosts"))
                        .font(DS.font(13, .semibold)).foregroundStyle(DS.text)
                    Text(filter == .attention && trimmedQuery.isEmpty
                         ? L10n.t("所有已启用主机均在线，且无安全或链路异常。",
                                  "All enabled hosts are online with no security or link issues.")
                         : L10n.t("试试清空搜索关键字或切回「全部」。",
                                  "Try clearing the search query or switching back to All."))
                        .font(DS.small).foregroundStyle(DS.muted)
                }
                Spacer()
                if filter != .all || !query.isEmpty {
                    DSButton(L10n.t("查看全部", "Show All"), kind: .ghost) {
                        filter = .all
                        query = ""
                    }
                }
            }
        }
    }

    private var overviewStrip: some View {
        let enabled = model.enabledHosts.count
        let online = model.onlineCount
        let onlineColor: Color = enabled == 0 ? DS.faint
            : (online == enabled ? DS.success : (online == 0 ? DS.danger : DS.warning))
        let warnings = model.securityWarningCount
        let vlessValue: String = {
            if model.vlessTestedCount > 0 {
                return "\(model.vlessOKCount) / \(model.vlessTestedCount)"
            }
            if model.vlessLinkCount > 0 {
                return L10n.t("\(model.vlessLinkCount) 条", "\(model.vlessLinkCount)")
            }
            return "—"
        }()
        let vlessDot: Color = {
            if model.vlessTestedCount > 0 {
                return model.vlessOKCount == model.vlessTestedCount ? DS.success : DS.warning
            }
            return model.vlessLinkCount > 0 ? DS.muted : DS.faint
        }()
        let vlessSub: String = model.vlessTestedCount > 0
            ? L10n.t("端到端已测", "E2E tested")
            : L10n.t("按需检测", "On demand")

        return HStack(spacing: 0) {
            VPSOverviewCell(
                label: L10n.t("在线主机", "Online"),
                value: "\(online) / \(enabled)",
                sub: model.disabledHosts.isEmpty
                    ? L10n.t("全部启用", "All active")
                    : L10n.t("\(model.disabledHosts.count) 台停用", "\(model.disabledHosts.count) disabled"),
                dot: onlineColor
            )
            overviewDivider
            VPSOverviewCell(
                label: L10n.t("安全提醒", "Security"),
                value: warnings == 0 ? L10n.t("正常", "Clean") : "\(warnings)",
                sub: warnings == 0
                    ? L10n.t("无待处理项", "No issues")
                    : L10n.t("\(model.attentionCount) 台需关注", "\(model.attentionCount) hosts"),
                dot: warnings == 0 ? DS.success : DS.warning
            )
            overviewDivider
            VPSOverviewCell(
                label: "VLESS",
                value: vlessValue,
                sub: vlessSub,
                dot: vlessDot
            )
            overviewDivider
            VPSOverviewCell(
                label: L10n.t("上次检查", "Last Check"),
                value: model.lastRefresh.map { Self.clock.string(from: $0) } ?? "—",
                sub: L10n.t("超 1 小时自动查", "Auto > 1h"),
                dot: model.refreshing ? DS.accent : DS.faint
            )
            .help(L10n.t("进入页面时若无结果或距上次完整检查超过 1 小时，才会自动检查一次。",
                         "Auto-checks on open only when results are missing or older than 1 hour."))
        }
        .padding(.vertical, 10)
        .dsCardBackground()
    }

    private var overviewDivider: some View {
        Rectangle().fill(DS.border).frame(width: 1, height: 28)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            DSSegmented(selection: $filter, options: filterOptions)
            Spacer(minLength: 8)
            if model.hosts.count >= 4 || !query.isEmpty {
                DSSearchField(L10n.t("筛选主机、系统或地址", "Filter host, OS or endpoint"), text: $query)
                    .frame(width: 210)
            }
        }
    }

    private var disabledSection: some View {
        let expanded = filter == .disabled || visibleEnabledHosts.isEmpty || showDisabledInAll
        return VStack(alignment: .leading, spacing: 8) {
            if filter == .all && !visibleEnabledHosts.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showDisabledInAll.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Icon(expanded ? "chevron-down" : "chevron-right", size: 12, color: DS.muted)
                        Text(L10n.t("已停用（\(visibleDisabledHosts.count)）",
                                    "Disabled (\(visibleDisabledHosts.count))"))
                            .font(DS.font(12, .semibold)).foregroundStyle(DS.muted)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(visibleDisabledHosts.enumerated()), id: \.element.id) { idx, host in
                        if idx > 0 { DSDivider(inset: 14) }
                        VPSDisabledRow(model: model, host: host)
                    }
                }
                .dsCardBackground()
            }
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 概览单元格

private struct VPSOverviewCell: View {
    let label: String
    let value: String
    let sub: String
    let dot: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(label).font(DS.font(11, .medium)).foregroundStyle(DS.muted).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(DS.font(15, .semibold))
                    .foregroundStyle(DS.text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(sub)
                    .font(DS.font(10.5))
                    .foregroundStyle(DS.faint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 主机卡片

private struct VPSHostCard: View {
    @ObservedObject var model: VPSMonitorModel
    let host: VPSHost
    let result: VPSHostResult?
    let collapsed: Bool
    let onToggleCollapse: () -> Void
    let onReport: () -> Void

    @State private var copiedSSH = false
    @State private var securityHover = false

    private var remote: VPSRemoteSnapshot? { result?.remote }
    private var isRefreshing: Bool { model.isRefreshing(host) }
    private var hostBusy: Bool { isRefreshing || model.isTestingAnyLink(for: host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                DSDivider(inset: 0)
                VStack(alignment: .leading, spacing: 10) {
                    if let result {
                        if result.online, let remote {
                            metricsGrid(remote)
                            vlessBox(result: result, remote: remote)
                            securityBar(remote, checkedAt: result.checkedAt)
                        } else {
                            offlineBox(result)
                        }
                    } else if isRefreshing {
                        checkingBox
                    } else {
                        notCheckedBox
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .dsCardBackground()
    }

    private var statusColor: Color {
        guard let result else { return DS.faint }
        if !result.online { return DS.danger }
        if result.vlessChecks.contains(where: { $0.check.state == .failed }) { return DS.danger }
        if result.vlessChecks.contains(where: { $0.speed?.state == .failed }) { return DS.danger }
        if let remote, !remote.securityWarnings.isEmpty || !remote.loadWarnings.isEmpty { return DS.warning }
        return DS.success
    }

    private var statusBadge: (text: String, color: Color) {
        if isRefreshing && result == nil {
            return (L10n.t("检查中", "Checking"), DS.accent)
        }
        guard let result else {
            return (L10n.t("未检查", "Idle"), DS.faint)
        }
        return result.online
            ? (L10n.t("在线", "Online"), DS.success)
            : (L10n.t("离线", "Offline"), DS.danger)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onToggleCollapse) {
                HStack(spacing: 10) {
                    DSIconTile("server-cog", color: statusColor, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Text(host.displayName)
                                .font(DS.font(14, .semibold))
                                .foregroundStyle(DS.text)
                                .lineLimit(1)
                            statusPill
                            if copiedSSH {
                                Text(L10n.t("已复制 SSH 命令", "SSH copied"))
                                    .font(DS.font(10.5, .medium))
                                    .foregroundStyle(DS.success)
                                    .transition(.opacity)
                            }
                        }
                        if collapsed, let result, result.online, let remote {
                            compactSummaryLine(remote)
                        } else {
                            Text(headerSubtitle)
                                .font(DS.font(11.5))
                                .foregroundStyle(DS.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(fullSystemTooltip)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 26)
                        .help(L10n.t("刷新中…", "Refreshing…"))
                } else {
                    DSIconButton("refresh-cw",
                                 help: L10n.t("刷新这台 VPS", "Refresh this host"),
                                 size: 26) {
                        model.refresh(host)
                    }
                    .disabled(hostBusy || model.refreshing)
                }

                VPSMiniButton(L10n.t("报告", "Report"), icon: "file-text", outlined: true) {
                    onReport()
                }
                .disabled(result == nil)

                moreMenu

                DSIconButton(collapsed ? "chevron-right" : "chevron-down",
                             help: collapsed ? L10n.t("展开详情", "Expand") : L10n.t("收起详情", "Collapse"),
                             size: 24,
                             action: onToggleCollapse)
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .animation(.easeOut(duration: 0.14), value: copiedSSH)
    }

    private var statusPill: some View {
        let badge = statusBadge
        return HStack(spacing: 4) {
            Circle().fill(badge.color).frame(width: 6, height: 6)
            Text(badge.text)
                .font(DS.font(11, .medium))
                .foregroundStyle(badge.color)
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(badge.color.opacity(0.11)))
    }

    private func compactSummaryLine(_ r: VPSRemoteSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("CPU \(Int(r.cpuPercent.rounded()))%")
            Text("·").foregroundStyle(DS.borderStrong)
            Text("\(L10n.t("内存", "Mem")) \(Int(r.memPercent.rounded()))%")
            Text("·").foregroundStyle(DS.borderStrong)
            Text("\(L10n.t("磁盘", "Disk")) \(Int(r.diskPercent.rounded()))%")
            Text("·").foregroundStyle(DS.borderStrong)
            Text("\(L10n.t("安全", "Sec")) \(r.securityScore)/100")
                .foregroundStyle(Self.scoreColor(r.securityScore))
            if let tcp = result?.tcp {
                Text("·").foregroundStyle(DS.borderStrong)
                Text(tcp.ok ? "TCP \(tcp.latencyMs ?? 0) ms" : L10n.t("端口不通", "Port closed"))
                    .foregroundStyle(tcp.ok ? DS.muted : DS.danger)
            }
        }
        .font(DS.font(11.5).monospacedDigit())
        .foregroundStyle(DS.muted)
        .lineLimit(1)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                PasteboardGuard.write("ssh \(host.sshAlias)")
                copiedSSH = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copiedSSH = false }
            } label: {
                Text(L10n.t("复制 SSH 命令（ssh \(host.sshAlias)）", "Copy SSH Command (ssh \(host.sshAlias))"))
            }
            if let first = result?.vlessChecks.first, !first.url.isEmpty {
                Button {
                    PasteboardGuard.write(first.url.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    Text(L10n.t("复制主 VLESS 链接", "Copy Primary VLESS Link"))
                }
            }
            if result != nil {
                Button(action: onReport) {
                    Text(L10n.t("查看检测报告", "View Health Report"))
                }
            }
            Button(action: onToggleCollapse) {
                Text(collapsed ? L10n.t("展开卡片", "Expand Card") : L10n.t("收起卡片", "Collapse Card"))
            }
            Divider()
            Button(role: .destructive) {
                model.setEnabled(host, false)
            } label: {
                Text(L10n.t("停用此 VPS 监控", "Disable Monitoring"))
            }
        } label: {
            Icon("ellipsis", size: 15, color: DS.muted)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).fill(Color.clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .help(L10n.t("更多操作", "More actions"))
    }

    private var headerSubtitle: String {
        var parts: [String] = []
        if host.displayName != host.sshAlias {
            parts.append(host.sshAlias)
        }
        if let remote {
            let os = Self.shortOS(remote.osName)
            if !os.isEmpty { parts.append(os) }
            parts.append(L10n.t("\(remote.cores) 核", "\(remote.cores) cores"))
            parts.append(L10n.t("运行 \(Self.uptime(remote.uptime))", "Up \(Self.uptime(remote.uptime))"))
        } else {
            parts.append("ssh \(host.sshAlias)")
        }
        return parts.joined(separator: " · ")
    }

    private var fullSystemTooltip: String {
        var lines = ["ssh \(host.sshAlias)"]
        if let remote {
            if !remote.osName.isEmpty { lines.append(remote.osName) }
            if !remote.kernel.isEmpty { lines.append("Kernel: \(remote.kernel)") }
        }
        if let result {
            lines.append(L10n.t("检查于 \(Self.clock.string(from: result.checkedAt))",
                                "Checked \(Self.clock.string(from: result.checkedAt))"))
            if let ms = result.latencyMs {
                lines.append(L10n.t("SSH 采集耗时 \(ms) ms", "SSH probe \(ms) ms"))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 1) 三列资源指标（等高对齐）

    private func metricsGrid(_ r: VPSRemoteSnapshot) -> some View {
        let swapUsedKB = max(0, r.swapTotalKB - r.swapFreeKB)
        let swapText = r.swapTotalKB > 0
            ? "Swap \(Self.bytes(swapUsedKB)) / \(Self.bytes(r.swapTotalKB))"
            : L10n.t("未启用 Swap", "No swap")
        let diskFreeKB = max(0, r.diskTotalKB - r.diskUsedKB)
        let cpuFoot = r.loadWarnings.isEmpty
            ? L10n.t("\(r.cores) 核 · 1/5/15 分钟", "\(r.cores) cores · 1/5/15m")
            : r.loadWarnings.joined(separator: " · ")

        return HStack(alignment: .top, spacing: 10) {
            VPSMetricTile(
                label: "CPU",
                value: r.cpuPercent,
                detail: "\(L10n.t("负载", "Load")) \(Self.load(r.load))",
                foot: cpuFoot,
                footWarning: !r.loadWarnings.isEmpty
            )
            VPSMetricTile(
                label: L10n.t("内存", "Memory"),
                value: r.memPercent,
                detail: "\(Self.bytes(r.memUsedKB)) / \(Self.bytes(r.memTotalKB))",
                foot: swapText,
                footWarning: false
            )
            VPSMetricTile(
                label: L10n.t("磁盘", "Disk"),
                value: r.diskPercent,
                detail: "\(Self.bytes(r.diskUsedKB)) / \(Self.bytes(r.diskTotalKB))",
                foot: L10n.t("可用 \(Self.bytes(diskFreeKB))", "\(Self.bytes(diskFreeKB)) free"),
                footWarning: r.diskPercent >= 90
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 2) VLESS 分组框

    private func vlessBox(result: VPSHostResult, remote: VPSRemoteSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Icon("globe", size: 12, color: DS.muted)
                Text("VLESS")
                    .font(DS.font(11.5, .semibold))
                    .foregroundStyle(DS.text)
                Circle()
                    .fill(remote.xrayRunning ? DS.success : DS.danger)
                    .frame(width: 6, height: 6)
                Text(Self.xrayVersion(remote))
                    .font(DS.font(11.5))
                    .foregroundStyle(remote.xrayRunning ? DS.text2 : DS.danger)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let tcp = result.tcp {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(tcp.ok ? DS.success : DS.danger)
                            .frame(width: 6, height: 6)
                        Text(tcp.ok ? "TCP \(tcp.latencyMs ?? 0) ms" : L10n.t("端口不通", "Port unreachable"))
                            .font(DS.font(11, .medium).monospacedDigit())
                            .foregroundStyle(tcp.ok ? DS.muted : DS.danger)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Rectangle().fill(DS.border.opacity(0.7)).frame(height: 1)

            if result.vlessChecks.isEmpty {
                Text(L10n.t("未发现 VLESS 链接，请检查服务器客户端文件或 Xray inbound 配置。",
                            "No VLESS link found; check the server client file or Xray inbound config."))
                    .font(DS.small)
                    .foregroundStyle(DS.faint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(result.vlessChecks.enumerated()), id: \.element.id) { idx, link in
                    if idx > 0 {
                        Rectangle().fill(DS.border.opacity(0.55)).frame(height: 1).padding(.horizontal, 10)
                    }
                    VPSLinkRow(model: model, host: host, link: link)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.surface2.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.border.opacity(0.8), lineWidth: 1))
    }

    // MARK: 3) 安全状态条（整条可点击直达报告）

    private func securityBar(_ r: VPSRemoteSnapshot, checkedAt: Date) -> some View {
        let hasWarnings = !r.securityWarnings.isEmpty
        let toneColor = Self.scoreColor(r.securityScore)
        let bgColor: Color = hasWarnings
            ? (r.securityScore < 65 ? DS.dangerSoft.opacity(0.45) : DS.warningSoft.opacity(0.45))
            : DS.successSoft.opacity(0.35)
        let borderColor: Color = securityHover
            ? toneColor.opacity(0.45)
            : (hasWarnings ? toneColor.opacity(0.22) : DS.border.opacity(0.75))

        return Button(action: onReport) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Icon(hasWarnings ? "shield-alert" : "shield-check", size: 13, color: toneColor)
                    Text(L10n.t("安全", "Security"))
                        .font(DS.font(11.5, .semibold))
                        .foregroundStyle(DS.text)
                    Text("\(r.securityScore) / 100")
                        .font(DS.font(11.5, .semibold).monospacedDigit())
                        .foregroundStyle(toneColor)
                    if hasWarnings {
                        Text(L10n.t("\(r.securityWarnings.count) 项待处理", "\(r.securityWarnings.count) to fix"))
                            .font(DS.font(11, .medium))
                            .foregroundStyle(DS.warning)
                    } else {
                        Text(L10n.t("全部通过", "All clear"))
                            .font(DS.font(11, .medium))
                            .foregroundStyle(DS.success)
                    }
                    Spacer(minLength: 6)
                    Text(Self.securityMeta(r, checkedAt: checkedAt))
                        .font(DS.font(10.5).monospacedDigit())
                        .foregroundStyle(DS.muted)
                        .lineLimit(1)
                    Icon("chevron-right", size: 12, color: DS.faint)
                }

                if hasWarnings {
                    let preview = r.securityWarnings.prefix(4)
                    let overflow = r.securityWarnings.count - preview.count
                    HStack(spacing: 6) {
                        Text(preview.joined(separator: "  ·  ")
                             + (overflow > 0 ? L10n.t("  ·  另 \(overflow) 项", "  ·  +\(overflow) more") : ""))
                            .font(DS.font(11))
                            .foregroundStyle(DS.text2)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bgColor))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(borderColor, lineWidth: 1))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: securityHover)
        }
        .buttonStyle(.plain)
        .onHover { securityHover = $0 }
        .help(L10n.t("点击查看完整检测报告与修复建议", "Click to view full report and remediation steps"))
    }

    // MARK: 离线 / 检查中 / 未检查

    private func offlineBox(_ result: VPSHostResult) -> some View {
        HStack(spacing: 10) {
            Icon("triangle-alert", size: 15, color: DS.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.error ?? L10n.t("无法连接", "Unreachable"))
                    .font(DS.font(12, .medium))
                    .foregroundStyle(DS.danger)
                    .lineLimit(2)
                Text(L10n.t("请先在终端确认 ssh \(host.sshAlias) 可直接免密登录。",
                            "Check that ssh \(host.sshAlias) logs in cleanly from Terminal."))
                    .font(DS.small)
                    .foregroundStyle(DS.muted)
            }
            Spacer(minLength: 8)
            VPSMiniButton(copiedSSH ? L10n.t("已复制", "Copied") : L10n.t("复制 SSH", "Copy SSH"),
                          icon: copiedSSH ? "check" : "terminal",
                          tint: copiedSSH ? DS.success : nil,
                          outlined: true) {
                PasteboardGuard.write("ssh \(host.sshAlias)")
                copiedSSH = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copiedSSH = false }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.dangerSoft.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.danger.opacity(0.22), lineWidth: 1))
    }

    private var checkingBox: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.t("正在通过 SSH 采集系统与安全状态…", "Collecting system and security status via SSH…"))
                .font(DS.small).foregroundStyle(DS.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.surface2.opacity(0.6)))
    }

    private var notCheckedBox: some View {
        HStack(spacing: 8) {
            Icon("clock", size: 13, color: DS.faint)
            Text(L10n.t("尚未检查", "Not checked yet"))
                .font(DS.small).foregroundStyle(DS.muted)
            Spacer()
            VPSMiniButton(L10n.t("立即检查", "Check Now"), icon: "refresh-cw", outlined: true) {
                model.refresh(host)
            }
            .disabled(model.refreshing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.surface2.opacity(0.6)))
    }

    // MARK: 格式化辅助

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func scoreColor(_ score: Int) -> Color {
        if score >= 85 { return DS.success }
        if score >= 65 { return DS.warning }
        return DS.danger
    }

    private static func shortOS(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let paren = trimmed.firstIndex(of: "(") {
            let head = trimmed[..<paren].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head }
        }
        return trimmed
    }

    private static func securityMeta(_ r: VPSRemoteSnapshot, checkedAt: Date) -> String {
        var parts = [
            "SSH \(r.sshKeyOnly ? L10n.t("密钥", "key") : L10n.t("密码", "pwd"))",
            "fail2ban \(r.fail2banBanned)",
        ]
        if !r.firewallKind.isEmpty { parts.append(r.firewallKind) }
        parts.append(clock.string(from: checkedAt))
        return parts.joined(separator: " · ")
    }

    private static func load(_ l: [Double]) -> String {
        l.map { String(format: "%.2f", $0) }.joined(separator: " / ")
    }

    private static func bytes(_ kb: Int64) -> String {
        if kb <= 0 { return "0 B" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: kb * 1024)
    }

    private static func uptime(_ seconds: Double) -> String {
        let days = Int(seconds / 86400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600)
        if days > 0 { return L10n.t("\(days) 天 \(hours) 小时", "\(days)d \(hours)h") }
        let mins = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 { return L10n.t("\(hours) 小时", "\(hours)h") }
        return L10n.t("\(max(1, mins)) 分钟", "\(max(1, mins))m")
    }

    private static func xrayVersion(_ r: VPSRemoteSnapshot) -> String {
        guard r.xrayRunning else { return L10n.t("Xray 未运行", "Xray stopped") }
        let v = r.xrayVersion.split(separator: " ").prefix(2).joined(separator: " ")
        return v.isEmpty ? "Xray" : v
    }
}

// MARK: - 单条 VLESS 链接行

private struct VPSLinkRow: View {
    @ObservedObject var model: VPSMonitorModel
    let host: VPSHost
    let link: VPSLinkCheck
    @State private var copied = false

    private var testingConn: Bool { model.isTestingConnectivity(host: host, link: link) }
    private var testingSpeed: Bool { model.isTestingSpeed(host: host, link: link) }
    private var linkBusy: Bool { testingConn || testingSpeed || model.isRefreshing(host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(link.name)
                        .font(DS.font(12, .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    if !link.endpoint.isEmpty {
                        Text(link.endpoint)
                            .font(DS.font(11.5).monospaced())
                            .foregroundStyle(DS.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .layoutPriority(1)

                statusTags

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    VPSMiniButton(copied ? L10n.t("已复制", "Copied") : L10n.t("复制", "Copy"),
                                  icon: copied ? "check" : "copy",
                                  tint: copied ? DS.success : nil) {
                        let text = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
                        PasteboardGuard.write(text)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                    .disabled(link.url.isEmpty)

                    VPSMiniButton(L10n.t("连通性", "Test"),
                                  icon: "wifi",
                                  loading: testingConn) {
                        model.testConnectivity(host: host, link: link)
                    }
                    .disabled(linkBusy)

                    VPSMiniButton(L10n.t("测速", "Speed"),
                                  icon: "gauge",
                                  loading: testingSpeed) {
                        model.testSpeed(host: host, link: link)
                    }
                    .disabled(linkBusy)
                }
                .fixedSize()
            }

            if !link.check.message.isEmpty {
                Text(link.check.message)
                    .font(DS.font(11))
                    .foregroundStyle(link.check.state == .failed ? DS.danger : DS.faint)
                    .lineLimit(2)
            }
            if let speed = link.speed, speed.state == .failed, !speed.message.isEmpty {
                Text(speed.message)
                    .font(DS.font(11))
                    .foregroundStyle(DS.danger)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .animation(.easeOut(duration: 0.14), value: copied)
    }

    @ViewBuilder
    private var statusTags: some View {
        switch link.check.state {
        case .ok:
            DSChip("204 · \(link.check.latencyMs ?? 0) ms", tone: .success)
        case .failed:
            DSChip(L10n.t("连通失败", "Failed"), tone: .danger)
        case .skipped:
            if link.speed == nil {
                Text(L10n.t("未测", "Untested"))
                    .font(DS.font(10.5))
                    .foregroundStyle(DS.faint)
            }
        }
        if let speed = link.speed {
            if speed.state == .ok, let mb = speed.megabytesPerSecond {
                DSChip(String(format: "%.1f MB/s", mb), tone: .success)
            } else {
                DSChip(L10n.t("测速失败", "Speed err"), tone: .danger)
            }
        }
    }
}

// MARK: - 资源指标小卡片

private struct VPSMetricTile: View {
    let label: String
    let value: Double
    let detail: String
    let foot: String
    let footWarning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(DS.font(11, .medium))
                    .foregroundStyle(DS.muted)
                Spacer(minLength: 0)
                Text("\(Int(value.rounded()))%")
                    .font(DS.font(12.5, .semibold).monospacedDigit())
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.border)
                    Capsule().fill(tint)
                        .frame(width: max(3, geo.size.width * min(max(value, 0), 100) / 100))
                }
            }
            .frame(height: 4)
            Text(detail)
                .font(DS.font(11).monospacedDigit())
                .foregroundStyle(DS.text2)
                .lineLimit(1)
            Text(foot)
                .font(DS.font(10.5).monospacedDigit())
                .foregroundStyle(footWarning ? DS.warning : DS.faint)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.surface2.opacity(0.65)))
    }

    private var tint: Color {
        if value >= 90 { return DS.danger }
        if value >= 75 { return DS.warning }
        return DS.success
    }
}

// MARK: - 紧凑操作按钮

private struct VPSMiniButton: View {
    let title: String
    let icon: String
    let tint: Color?
    let outlined: Bool
    let loading: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, icon: String, tint: Color? = nil, outlined: Bool = false,
         loading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.outlined = outlined
        self.loading = loading
        self.action = action
    }

    var body: some View {
        let fg = tint ?? (outlined ? DS.text : DS.text2)
        Button(action: action) {
            HStack(spacing: 4) {
                if loading {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else {
                    Icon(icon, size: 12, color: fg)
                }
                Text(title)
                    .font(DS.font(11.5, .medium))
                    .foregroundStyle(fg)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && enabled ? DS.hover : (outlined ? DS.surface : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(outlined ? DS.borderStrong : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.1), value: hovering)
        }
        .buttonStyle(DSPressStyle(scale: 0.96))
        .onHover { hovering = $0 }
    }
}

// MARK: - 已停用主机行

private struct VPSDisabledRow: View {
    @ObservedObject var model: VPSMonitorModel
    let host: VPSHost

    var body: some View {
        HStack(spacing: 10) {
            DSIconTile("server-cog", color: DS.faint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .font(DS.font(13, .medium))
                    .foregroundStyle(DS.text2)
                if host.displayName != host.sshAlias {
                    Text(host.sshAlias)
                        .font(DS.small)
                        .foregroundStyle(DS.faint)
                }
            }
            Spacer()
            VPSMiniButton(L10n.t("启用监控", "Enable"), icon: "power", outlined: true) {
                model.setEnabled(host, true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - 检测报告 Sheet

private struct VPSReportItem: Identifiable {
    let id: String
    let host: VPSHost
    let result: VPSHostResult
}

private struct VPSReportSheet: View {
    let item: VPSReportItem
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var remote: VPSRemoteSnapshot? { item.result.remote }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DSIconTile("file-text", color: DS.accent, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("检测报告", "Health Report"))
                        .font(DS.font(16, .semibold)).foregroundStyle(DS.text)
                    Text(subtitle)
                        .font(DS.small).foregroundStyle(DS.muted).lineLimit(1)
                }
                Spacer()
                if let remote {
                    DSChip("\(remote.securityScore) / 100",
                           tone: remote.securityScore >= 85 ? .success : (remote.securityScore >= 65 ? .warning : .danger),
                           icon: "shield-check")
                }
                DSIconButton("x", help: L10n.t("关闭", "Close"), size: 28) { dismiss() }
            }
            ScrollView {
                Text(item.result.report)
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
                Text(L10n.t("检查于 \(Self.clock.string(from: item.result.checkedAt))",
                            "Checked \(Self.clock.string(from: item.result.checkedAt))"))
                    .font(DS.small).foregroundStyle(DS.faint)
                Spacer()
                DSButton(L10n.t("关闭", "Close"), kind: .ghost) { dismiss() }
                DSButton(copied ? L10n.t("已复制", "Copied") : L10n.t("复制报告", "Copy Report"),
                         icon: copied ? "check" : "copy", kind: .primary, iconSpacing: 3) {
                    PasteboardGuard.write(item.result.report)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 560)
        .background(DS.bg)
    }

    private var subtitle: String {
        var parts = [item.host.displayName]
        if item.host.displayName != item.host.sshAlias { parts.append(item.host.sshAlias) }
        if let os = remote?.osName, !os.isEmpty { parts.append(os) }
        return parts.joined(separator: " · ")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
