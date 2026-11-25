import Cocoa
import SwiftUI
import PopBarCore
import PopBarDesign

private enum AgentProcessFilter: Hashable {
    case all
    case kind(AgentKind)
}

/// Deck「Agent 管理」页面
struct AgentPage: View {
    @ObservedObject var model: AgentManagerModel
    @State private var processFilter: AgentProcessFilter = .all
    @State private var query = ""

    private var autoUpdateBinding: Binding<Bool> {
        Binding(
            get: { model.autoUpdate },
            set: { model.setAutoUpdate($0) }
        )
    }

    private var filteredProcesses: [AgentProcessItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.processes.filter { item in
            if case .kind(let k) = processFilter, item.kind != k {
                return false
            }
            guard !q.isEmpty else { return true }
            return item.kind.displayName.lowercased().contains(q)
                || item.projectTitle.lowercased().contains(q)
                || (item.cwd?.lowercased().contains(q) ?? false)
                || item.command.lowercased().contains(q)
                || item.sourceCompact.lowercased().contains(q)
                || "\(item.pid)".contains(q)
        }
    }

    private var filterOptions: [(AgentProcessFilter, String)] {
        var opts: [(AgentProcessFilter, String)] = [
            (.all, L10n.t("全部 \(model.runningProcessCount)", "All \(model.runningProcessCount)")),
        ]
        for kind in AgentKind.allCases {
            let count = model.processCount(for: kind)
            let label = count > 0 ? "\(kind.shortName) \(count)" : kind.shortName
            opts.append((.kind(kind), label))
        }
        return opts
    }

    var body: some View {
        DSPageShell(
            L10n.t("Agent 管理", "Agent Manager"),
            subtitle: L10n.t("统一管理 Claude、Codex、Command Code、OpenCode、Pi、DeepSeek Harness 与 Antigravity 的版本、更新、重启与进程",
                             "Manage Claude, Codex, Command Code, OpenCode, Pi, DeepSeek Harness, and Antigravity versions, updates, restarts, and processes")
        ) {
            autoUpdatePill

            if model.updatableCount > 0 {
                DSButton(
                    L10n.t("全部更新（\(model.updatableCount)）", "Update All (\(model.updatableCount))"),
                    icon: "download",
                    kind: .primary
                ) {
                    model.updateAllAvailable()
                }
                .disabled(model.isAnyUpdating)
            }

            if model.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("检查中…", "Checking…"))
                        .font(DS.font(12, .medium))
                        .foregroundStyle(DS.muted)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
            } else {
                DSButton(L10n.t("检查更新", "Check Updates"), icon: "refresh-cw", kind: .secondary, iconSpacing: 5) {
                    model.refreshAll(checkRemote: true, triggerAutoUpdate: model.autoUpdate)
                }
                .disabled(model.isAnyUpdating)
            }
        } pinned: {
            overviewStrip

            if let banner = model.banner {
                bannerView(text: banner.text, tone: banner.tone)
            }
        } content: {
            // 区块一：受管 Agent 列表（命令行与桌面端分开展示）
            VStack(alignment: .leading, spacing: 10) {
                DSSectionHeader(L10n.t("Agent 列表", "Managed Agents")) {
                    if let last = model.lastCheckAt {
                        Text(L10n.t("上次检查：\(relativeTimeText(last))", "Last checked: \(relativeTimeText(last))"))
                            .font(DS.small)
                            .foregroundStyle(DS.faint)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(model.states.enumerated()), id: \.element.id) { index, state in
                        if index > 0 { DSDivider(inset: 16) }
                        AgentCLIRow(
                            state: state,
                            runningCount: model.processCount(for: state.kind),
                            logExpanded: model.expandedLogKinds.contains(state.kind),
                            onCheck: { model.checkSingle(state.kind) },
                            onUpdateOrInstall: { model.updateOrInstall(state.kind) },
                            onRestart: { model.restartAgent(state.kind) },
                            onToggleLog: { model.toggleLog(state.kind) },
                            onRevealBinary: {
                                if let path = state.executablePath { model.revealInFinder(path) }
                            },
                            onCopyPath: {
                                if let path = state.executablePath {
                                    model.copyText(path, notice: L10n.t("已复制路径：\(path)", "Copied path: \(path)"))
                                }
                            },
                            onOpenHomepage: { model.openHomepage(state.kind) },
                            onFilterProcesses: {
                                processFilter = .kind(state.kind)
                            }
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .dsCardBackground()
            }

            // 区块二：已启动进程列表
            VStack(alignment: .leading, spacing: 10) {
                DSSectionHeader(L10n.t("已启动进程", "Running Processes")) {
                    HStack(spacing: 8) {
                        if model.runningProcessCount > 0 {
                            Text(L10n.t("共 \(model.runningProcessCount) 项 · 内存 \(ProcessText.bytes(model.totalProcessMemory))",
                                        "\(model.runningProcessCount) running · Memory \(ProcessText.bytes(model.totalProcessMemory))"))
                                .font(DS.small)
                                .foregroundStyle(DS.muted)
                                .monospacedDigit()
                        }
                        DSIconButton("refresh-cw", help: L10n.t("刷新进程列表", "Refresh processes"), size: 24) {
                            model.scanProcessesOnce()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        DSSegmented(selection: $processFilter, options: filterOptions)
                    }
                    DSSearchField(L10n.t("搜索项目、PID、目录或命令", "Search project, PID, path or command"), text: $query)
                }

                if model.processes.isEmpty {
                    DSEmptyState(
                        icon: "terminal",
                        title: L10n.t("当前没有运行中的 Agent 进程", "No running Agent processes"),
                        message: L10n.t("启动 Claude、Codex、Command Code、OpenCode、Pi、DeepSeek Harness 或 Antigravity 后，这里会自动实时显示进程状态。",
                                        "Start Claude, Codex, Command Code, OpenCode, Pi, DeepSeek Harness, or Antigravity to see live processes here.")
                    )
                    .dsCardBackground()
                } else if filteredProcesses.isEmpty {
                    DSEmptyState(
                        icon: "search",
                        title: L10n.t("没有匹配的运行进程", "No matching processes"),
                        message: L10n.t("换个关键词或切换筛选分类试试。", "Try a different keyword or filter.")
                    )
                    .dsCardBackground()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredProcesses.enumerated()), id: \.element.id) { index, proc in
                            if index > 0 { DSDivider(inset: 16) }
                            AgentProcessRow(
                                item: proc,
                                isTerminating: model.terminatingIDs.contains(proc.id),
                                isRestarting: model.restartingIDs.contains(proc.id),
                                onRevealCWD: {
                                    if let cwd = proc.cwd {
                                        model.revealInFinder(cwd)
                                    } else if proc.role == .desktopApp {
                                        model.revealInFinder(proc.executablePath)
                                    }
                                },
                                onRestart: {
                                    model.restartProcess(proc)
                                },
                                onStop: { force in
                                    model.stopProcess(proc, force: force)
                                }
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .dsCardBackground()
                }
            }
        }
    }

    // MARK: - 页头与概览

    private var autoUpdatePill: some View {
        HStack(spacing: 8) {
            Text(model.autoUpdate ? L10n.t("自动更新", "Auto-Update") : L10n.t("手动更新", "Manual"))
                .font(DS.font(12.5, .medium))
                .foregroundStyle(model.autoUpdate ? DS.text2 : DS.muted)
            DSToggle(isOn: autoUpdateBinding)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).strokeBorder(DS.borderStrong, lineWidth: 1))
        .dsFastHelp(L10n.t("开启后将每 6 小时自动检查并更新已安装的 Agent（运行中的桌面端会跳过自动覆盖）",
                           "Automatically check and update installed Agents every 6 hours (skips running desktop apps)"))
    }

    private var overviewStrip: some View {
        HStack(spacing: 10) {
            overviewTile(
                icon: "package",
                tint: Color(nsColor: IconPalette.indigo),
                label: L10n.t("已安装 Agent", "Installed"),
                value: "\(model.installedCount) / \(AgentKind.allCases.count)"
            )
            overviewTile(
                icon: "download",
                tint: model.updatableCount > 0 ? Color(nsColor: IconPalette.orange) : Color(nsColor: IconPalette.green),
                label: L10n.t("可用更新", "Updates"),
                value: model.updatableCount > 0 ? "\(model.updatableCount)" : L10n.t("全部最新", "Up to date")
            )
            overviewTile(
                icon: "terminal",
                tint: Color(nsColor: IconPalette.teal),
                label: L10n.t("运行中进程", "Running"),
                value: "\(model.runningProcessCount)"
            )
            overviewTile(
                icon: "memory-stick",
                tint: Color(nsColor: IconPalette.blue),
                label: L10n.t("进程内存", "Memory"),
                value: model.runningProcessCount > 0 ? ProcessText.bytes(model.totalProcessMemory) : "—"
            )
        }
    }

    private func overviewTile(icon: String, tint: Color, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            DSIconTile(icon, color: IconPalette.enabled ? tint : DS.muted, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(DS.font(11, .medium))
                    .foregroundStyle(DS.muted)
                Text(value)
                    .font(DS.font(14, .semibold))
                    .foregroundStyle(DS.text)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCardBackground()
    }

    private func bannerView(text: String, tone: DSTone) -> some View {
        let fg: Color = {
            switch tone {
            case .success: return DS.success
            case .danger: return DS.danger
            case .warning: return DS.warning
            case .accent: return DS.accent
            case .neutral: return DS.text2
            }
        }()
        let bg: Color = {
            switch tone {
            case .success: return DS.successSoft
            case .danger: return DS.dangerSoft
            case .warning: return DS.warningSoft
            case .accent: return DS.accentSoft
            case .neutral: return DS.surface2
            }
        }()
        return HStack(spacing: 8) {
            Icon(tone == .danger ? "triangle-alert" : (tone == .success ? "circle-check" : "info"), size: 14, color: fg)
            Text(text)
                .font(DS.font(12, .medium))
                .foregroundStyle(fg)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            DSIconButton("x", tint: fg.opacity(0.8), help: L10n.t("关闭提示", "Dismiss"), size: 22) {
                model.banner = nil
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).fill(bg))
    }

    private func relativeTimeText(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: L10n.isEnglish ? "en_US" : "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 单个 Agent 行

private struct AgentCLIRow: View {
    let state: AgentCLIState
    let runningCount: Int
    let logExpanded: Bool
    let onCheck: () -> Void
    let onUpdateOrInstall: () -> Void
    let onRestart: () -> Void
    let onToggleLog: () -> Void
    let onRevealBinary: () -> Void
    let onCopyPath: () -> Void
    let onOpenHomepage: () -> Void
    let onFilterProcesses: () -> Void

    @State private var hovering = false

    private var accentColor: Color {
        guard IconPalette.enabled else { return DS.muted }
        switch state.kind {
        case .claudeCode: return Color(nsColor: IconPalette.orange)
        case .claudeDesktop: return Color(nsColor: IconPalette.purple)
        case .codexCLI: return Color(nsColor: IconPalette.green)
        case .codexDesktop: return Color(nsColor: IconPalette.indigo)
        case .commandCode: return Color(nsColor: IconPalette.blue)
        case .openCode: return Color(nsColor: IconPalette.teal)
        case .pi: return Color(nsColor: IconPalette.pink)
        case .deepSeekHarness: return Color(nsColor: IconPalette.sky)
        case .antigravity: return Color(nsColor: IconPalette.amber)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                DSIconTile(state.kind.iconName, color: accentColor, size: 36, filled: state.installed)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(state.kind.displayName)
                            .font(DS.font(14, .semibold))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        DSChip(state.kind.formTag, tone: state.kind.isDesktopApp ? .accent : .neutral)
                            .fixedSize(horizontal: true, vertical: false)

                        statusChip
                            .fixedSize(horizontal: true, vertical: false)

                        if state.installed {
                            DSChip(state.installMethod.shortBadge, tone: .neutral)
                                .fixedSize(horizontal: true, vertical: false)
                                .dsFastHelp(state.installMethod.displayName)
                        }

                        if runningCount > 0 {
                            Button(action: onFilterProcesses) {
                                DSChip(L10n.t("\(runningCount) 运行中", "\(runningCount) running"), tone: .accent, icon: state.kind.isDesktopApp ? "app-window-mac" : "terminal")
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(.plain)
                            .dsFastHelp(L10n.t("点击筛选该 Agent 的运行进程", "Click to filter processes for this agent"))
                        }
                    }

                    versionMetaLine

                    if let path = state.executablePath {
                        HStack(spacing: 6) {
                            Text(abbreviateHome(path))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DS.faint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let resolved = state.resolvedPath, resolved != path {
                                Text("→ \(abbreviateHome(resolved))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DS.faint.opacity(0.8))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    } else {
                        Text(state.kind.summary)
                            .font(DS.small)
                            .foregroundStyle(DS.muted)
                    }

                    if let err = state.latestCheckError {
                        Text(err)
                            .font(DS.small)
                            .foregroundStyle(DS.warning)
                            .lineLimit(2)
                    } else if case .failed(let msg) = state.actionState {
                        Text(msg)
                            .font(DS.small)
                            .foregroundStyle(DS.danger)
                            .lineLimit(2)
                    } else if case .updated(let msg) = state.actionState {
                        Text(msg)
                            .font(DS.small)
                            .foregroundStyle(DS.success)
                    }
                }

                Spacer(minLength: 10)

                actionControls
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(hovering ? DS.hover.opacity(0.45) : .clear)
            .onHover { hovering = $0 }

            if logExpanded && !state.lastOutput.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.t("最近执行输出", "Last Command Output"))
                            .font(DS.font(11, .semibold))
                            .foregroundStyle(DS.muted)
                        Spacer()
                        DSIconButton("x", help: L10n.t("收起日志", "Hide log"), size: 22, action: onToggleLog)
                    }
                    ScrollView {
                        Text(state.lastOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DS.text2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(DS.surface2.opacity(0.65))
            }
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch state.actionState {
        case .checking:
            DSChip(L10n.t("检查中…", "Checking…"), tone: .neutral)
        case .updating:
            DSChip(L10n.t("更新中…", "Updating…"), tone: .accent)
        case .installing:
            DSChip(L10n.t("安装中…", "Installing…"), tone: .accent)
        case .restarting:
            DSChip(L10n.t("重启中…", "Restarting…"), tone: .accent)
        default:
            if !state.installed {
                DSChip(L10n.t("未安装", "Not Installed"), tone: .neutral)
            } else if state.hasUpdate, let latest = state.latestVersionText {
                DSChip(L10n.t("可升级", "Update"), tone: .warning, icon: "arrow-up")
                    .dsFastHelp(L10n.t("可升级至 \(latest)", "Update available: \(latest)"))
            } else if state.isUpToDate {
                DSChip(L10n.t("最新", "Latest"), tone: .success, icon: "check")
            } else {
                DSChip(L10n.t("已安装", "Installed"), tone: .neutral)
            }
        }
    }

    private var versionMetaLine: some View {
        HStack(spacing: 8) {
            if state.installed {
                Text(L10n.t("当前：\(state.currentVersionText)", "Current: \(state.currentVersionText)"))
                    .font(DS.font(12, .medium))
                    .foregroundStyle(DS.text2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if let latest = state.latestVersionText {
                Text(L10n.t("最新：\(latest)", "Latest: \(latest)"))
                    .font(DS.font(12, .regular))
                    .foregroundStyle(state.hasUpdate ? DS.warning : DS.muted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let src = state.latestSource {
                    Text("(\(src))")
                        .font(DS.small)
                        .foregroundStyle(DS.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    /// 固定列宽对齐的操作区（主按钮 | Play 重启 | 访达 | 复制命令路径 | 打开官网），
    /// 每一行的按钮与图标数量与位置完全一致，CLI 的 Play 图标置灰不可点击以保持整体视觉整齐。
    private var actionControls: some View {
        let iconSize: CGFloat = 26
        let busy = state.actionState.isBusy
        let canRestart = state.kind.isDesktopApp && state.installed && !busy

        return HStack(spacing: 4) {
            // 列 1：主操作按钮（固定 98pt 宽、右对齐，忙碌时原地切为加载指示器不跳动）
            Group {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                } else if !state.installed {
                    DSButton(L10n.t("一键安装", "Install"), icon: "download", kind: .primary, action: onUpdateOrInstall)
                        .dsFastHelp(L10n.t("安装 \(state.kind.displayName)", "Install \(state.kind.displayName)"))
                } else if state.hasUpdate {
                    DSButton(L10n.t("立即更新", "Update"), icon: "download", kind: .primary, action: onUpdateOrInstall)
                        .dsFastHelp(L10n.t("覆盖更新 \(state.kind.displayName) 至最新版本", "Update \(state.kind.displayName) to latest version"))
                } else {
                    DSButton(L10n.t("检查", "Check"), icon: "refresh-cw", kind: .secondary, action: onCheck)
                        .dsFastHelp(L10n.t("检查 \(state.kind.displayName) 是否有新版本", "Check for \(state.kind.displayName) updates"))
                }
            }
            .frame(width: 98, alignment: .trailing)
            .padding(.trailing, 4)

            // 列 2：重启按钮（Play 图标；桌面端可点击，CLI 或未安装时置灰不可点击保持 UI 一致）
            let restartHelp: String = {
                guard state.kind.isDesktopApp else {
                    return L10n.t("命令行 Agent 请在终端中启动", "Launch CLI agents from your terminal")
                }
                guard state.installed else {
                    return L10n.t("请先安装 \(state.kind.displayName)", "Install \(state.kind.displayName) first")
                }
                return L10n.t("重启 \(state.kind.displayName)", "Restart \(state.kind.displayName)")
            }()
            DSIconButton("play", help: restartHelp, size: iconSize, action: onRestart)
                .disabled(!canRestart)

            // 列 3：在访达中显示
            DSIconButton("folder-open", help: L10n.t("在访达中显示", "Reveal in Finder"), size: iconSize, action: onRevealBinary)
                .disabled(!state.installed)

            // 列 4：复制命令路径
            DSIconButton("copy", help: L10n.t("复制命令路径", "Copy command path"), size: iconSize, action: onCopyPath)
                .disabled(!state.installed)

            // 列 5：打开官网
            DSIconButton("external-link", help: L10n.t("打开官网", "Open website"), size: iconSize, action: onOpenHomepage)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}

// MARK: - 单个运行进程行

private struct AgentProcessRow: View {
    let item: AgentProcessItem
    let isTerminating: Bool
    let isRestarting: Bool
    let onRevealCWD: () -> Void
    let onRestart: () -> Void
    let onStop: (_ force: Bool) -> Void

    @State private var hovering = false
    @State private var confirmForce = false

    private var accentColor: Color {
        guard IconPalette.enabled else { return DS.muted }
        switch item.kind {
        case .claudeCode: return Color(nsColor: IconPalette.orange)
        case .claudeDesktop: return Color(nsColor: IconPalette.purple)
        case .codexCLI: return Color(nsColor: IconPalette.green)
        case .codexDesktop: return Color(nsColor: IconPalette.indigo)
        case .commandCode: return Color(nsColor: IconPalette.blue)
        case .openCode: return Color(nsColor: IconPalette.teal)
        case .pi: return Color(nsColor: IconPalette.pink)
        case .deepSeekHarness: return Color(nsColor: IconPalette.sky)
        case .antigravity: return Color(nsColor: IconPalette.amber)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            DSIconTile(item.kind.iconName, color: accentColor, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.projectTitle)
                        .font(DS.font(13, .semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)

                    DSChip(item.kind.displayName, tone: .neutral)
                    DSChip(item.role.title, tone: (item.role == .server || item.role == .desktopApp) ? .accent : .neutral)

                    Text("PID \(item.pid)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.faint)
                        .monospacedDigit()
                }

                HStack(spacing: 8) {
                    if let cwd = item.displayCWD {
                        HStack(spacing: 3) {
                            Icon(item.gitRepo != nil ? "git-branch" : "folder", size: 11, color: DS.faint)
                            Text(cwd)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DS.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Text(item.displayCWD != nil ? "· \(item.sourceCompact)" : item.sourceCompact)
                        .font(DS.small)
                        .foregroundStyle(DS.faint)
                        .lineLimit(1)
                }
            }
            .dsFastHelp(item.command)

            Spacer(minLength: 10)

            HStack(spacing: 14) {
                metricColumn(label: "CPU", value: String(format: "%.1f%%", item.cpuPercent))
                metricColumn(label: L10n.t("内存", "RAM"), value: ProcessText.bytes(item.memoryBytes))
                metricColumn(label: L10n.t("时长", "Up"), value: ProcessText.compactDuration(item.uptimeSeconds))
            }

            HStack(spacing: 4) {
                if isTerminating || isRestarting {
                    ProgressView().controlSize(.small).frame(width: 26, height: 26)
                } else {
                    if item.cwd != nil || item.role == .desktopApp {
                        DSIconButton("folder-open",
                                     help: L10n.t("打开工作区目录", "Open workspace directory"),
                                     size: 26,
                                     action: onRevealCWD)
                    } else {
                        Color.clear.frame(width: 26, height: 26)
                    }

                    let canRestartDesktop = item.kind.isDesktopApp && item.role == .desktopApp
                    let restartHelp = canRestartDesktop
                        ? L10n.t("重启 \(item.kind.displayName)", "Restart \(item.kind.displayName)")
                        : L10n.t("命令行 Agent 请在终端中启动", "Launch CLI agents from your terminal")
                    DSIconButton("play", help: restartHelp, size: 26, action: onRestart)
                        .disabled(!canRestartDesktop)

                    if confirmForce {
                        DSButton(L10n.t("强杀", "Kill"), icon: "square", kind: .danger) {
                            confirmForce = false
                            onStop(true)
                        }
                        DSIconButton("x", help: L10n.t("取消", "Cancel"), size: 24) {
                            confirmForce = false
                        }
                    } else {
                        DSIconButton("circle-stop",
                                     tint: DS.danger,
                                     help: item.role == .desktopApp
                                        ? L10n.t("退出桌面应用；再次点击可强制结束", "Quit desktop app; click again to force quit")
                                        : L10n.t("温和结束进程（SIGTERM）；再次点击可强杀", "Stop process (SIGTERM)"),
                                     size: 26) {
                            onStop(false)
                            confirmForce = true
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(hovering ? DS.hover.opacity(0.6) : .clear)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .onHover { hovering = $0 }
    }

    private func metricColumn(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(DS.font(12, .medium))
                .foregroundStyle(DS.text2)
                .monospacedDigit()
            Text(label)
                .font(DS.font(10, .regular))
                .foregroundStyle(DS.faint)
        }
        .frame(minWidth: 46, alignment: .trailing)
    }
}
