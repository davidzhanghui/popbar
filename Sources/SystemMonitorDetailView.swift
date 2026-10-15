import SwiftUI
import Cocoa

/// 点击进程行弹出的详情窗(叠在系统监控面板上):
/// 头部 → 指标小卡 → 启动链 → 警告 → 分组字段(来源 / 资源 / 环境)→ 成员进程 → 操作。
/// 配色沿用面板:卡片底 / 描边取自 PanelTheme,品牌紫做点缀。
struct ProcessDetailOverlay: View {
    @ObservedObject var vm: SystemMonitorModel
    @State private var fullChain = false
    @State private var showRaw = false
    @State private var copied = false

    private static let green = Color(red: 0.22, green: 0.74, blue: 0.46)
    private static let orange = Color(red: 0.95, green: 0.60, blue: 0.20)

    var body: some View {
        ZStack {
            // 遮罩:圆角与面板内容区一致,点击空白处关闭
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.32))
                .contentShape(Rectangle())
                .onTapGesture { vm.closeDetail() }
            if let g = vm.detailGroup {
                card(g)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.14), value: vm.detailKey)
    }

    // MARK: - 卡片骨架

    private func card(_ g: ProcessGroup) -> some View {
        VStack(spacing: 0) {
            header(g)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    stats(g)
                    if let d = vm.detail {
                        chain(d)
                        if !d.warnings.isEmpty { warnings(d) }
                        ForEach(Array(fieldGroups(g, d).enumerated()), id: \.offset) { _, grp in
                            fieldCard(grp.title, grp.rows)
                        }
                    } else {
                        loading
                    }
                    members(g)
                    if let d = vm.detail { raw(d) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            actions(g)
        }
        .frame(width: 568)
        .frame(maxHeight: 664)
        .background(SysTheme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(SysTheme.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
        .padding(.vertical, 10)
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.t("正在分析进程…", "Analyzing process…"))
                .font(.system(size: 12)).foregroundStyle(SysTheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    // MARK: - 头部

    private func header(_ g: ProcessGroup) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: IconCache.icon(for: g))
                .resizable().frame(width: 38, height: 38)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(g.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    if !vm.detailAlive {
                        badge(L10n.t("已停止运行", "Not running"), Self.orange)
                    }
                }
                Text(headerSubtitle(g))
                    .font(.system(size: 11))
                    .foregroundStyle(SysTheme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { vm.closeDetail() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SysTheme.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(SysTheme.track))
            }
            .buttonStyle(.plain)
            .help(L10n.t("关闭 (Esc)", "Close (Esc)"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            LinearGradient(colors: [SysTheme.headerTint, SysTheme.headerTint.opacity(0.35)],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .bottom) { Rectangle().fill(SysTheme.separator).frame(height: 1) }
    }

    private func headerSubtitle(_ g: ProcessGroup) -> String {
        var parts = ["PID \(g.mainPID)"]
        if let d = vm.detail { parts.insert(d.source.compact, at: 0) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 指标小卡

    private func stats(_ g: ProcessGroup) -> some View {
        HStack(spacing: 8) {
            statTile(L10n.t("进程", "Processes"), String(g.count))
            statTile("CPU", String(format: "%.1f%%", g.cpuPercent))
            statTile(L10n.t("内存", "Memory"), ProcessText.bytes(g.memoryBytes))
            statTile(L10n.t("已运行", "Uptime"),
                     vm.detail?.started.map { ProcessText.compactDuration(Date().timeIntervalSince($0)) } ?? "—")
        }
    }

    private func statTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(SysTheme.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    // MARK: - 启动链

    private func chain(_ d: ProcessDetail) -> some View {
        let nodes = fullChain ? d.chain : Array(d.chain.suffix(3))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                if !fullChain && d.chain.count > 3 {
                    Text("…").font(.system(size: 12)).foregroundStyle(SysTheme.tertiary)
                    chevron
                }
                ForEach(Array(nodes.enumerated()), id: \.offset) { i, n in
                    if i > 0 { chevron }
                    let last = i == nodes.count - 1
                    HStack(spacing: 4) {
                        Text(n.appName ?? n.name)
                            .font(.system(size: 11, weight: last ? .semibold : .regular))
                            .lineLimit(1)
                        Text(verbatim: String(n.pid))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(last ? SysTheme.brand.opacity(0.8) : SysTheme.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(last ? SysTheme.brand.opacity(0.14) : SysTheme.track))
                    .foregroundStyle(last ? SysTheme.brand : Color(nsColor: .labelColor))
                }
                Spacer(minLength: 0)
                if d.chain.count > 3 {
                    Button(fullChain ? L10n.t("收起链路", "Collapse") : L10n.t("完整链路", "Full chain")) {
                        fullChain.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SysTheme.brand)
                }
            }
            Text(d.source.summary)
                .font(.system(size: 12))
                .foregroundStyle(SysTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(SysTheme.tertiary)
    }

    // MARK: - 警告

    private func warnings(_ d: ProcessDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(d.warnings, id: \.self) { w in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Self.orange)
                        .padding(.top, 2)
                    Text(w)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.orange.opacity(0.11)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Self.orange.opacity(0.28), lineWidth: 1))
    }

    // MARK: - 字段(分组卡片)

    private struct Field {
        let label: String
        let value: String
        var tint: Color?        // 有值则以徽标样式显示
        var mono = false
    }

    private struct FieldGroup {
        let title: String
        let rows: [Field]
    }

    private func fieldCard(_ title: String, _ rows: [Field]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SysTheme.secondary)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 {
                    Rectangle().fill(SysTheme.separator.opacity(0.5)).frame(height: 1).padding(.leading, 14)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(r.label)
                        .font(.system(size: 11))
                        .foregroundStyle(SysTheme.secondary)
                        .frame(width: 104, alignment: .leading)
                    if let t = r.tint {
                        badge(r.value, t)
                    } else {
                        Text(r.value)
                            .font(r.mono ? .system(size: 11, design: .monospaced) : .system(size: 12))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
            Spacer().frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    private func fieldGroups(_ g: ProcessGroup, _ d: ProcessDetail) -> [FieldGroup] {
        var source: [Field] = []
        let (confText, confTint): (String, Color)
        switch d.confidence {
        case .high: (confText, confTint) = (L10n.t("高可信度", "High confidence"), Self.green)
        case .medium: (confText, confTint) = (L10n.t("中可信度", "Medium confidence"), SysTheme.cpu)
        case .possible: (confText, confTint) = (L10n.t("可能", "Possible"), Self.orange)
        }
        source.append(Field(label: L10n.t("置信度", "Confidence"), value: confText, tint: confTint))
        if !d.evidence.isEmpty { source.append(Field(label: L10n.t("识别依据", "Evidence"), value: d.evidence, mono: true)) }
        if let o = d.owner { source.append(Field(label: L10n.t("归属", "Owner"), value: L10n.t("子进程:\(o)", "Child of \(o)"))) }
        if let v = d.launchdReason { source.append(Field(label: L10n.t("launchd 触发原因", "launchd reason"), value: v)) }
        if let v = d.launchdService { source.append(Field(label: L10n.t("launchd 服务", "launchd service"), value: v, mono: true)) }
        if let v = d.plistPath { source.append(Field(label: "Plist", value: v, mono: true)) }
        if let k = d.keepAlive { source.append(Field(label: L10n.t("自动保活", "Keep alive"), value: k ? L10n.t("是", "Yes") : L10n.t("否", "No"))) }
        if !d.triggers.isEmpty { source.append(Field(label: L10n.t("触发条件", "Triggers"), value: d.triggers.joined(separator: " · "))) }

        var res: [Field] = [
            Field(label: L10n.t("线程数", "Threads"), value: String(d.threads)),
            Field(label: L10n.t("打开文件", "Open files"), value: String(d.openFiles)),
        ]
        if !d.ports.isEmpty {
            res.append(Field(label: L10n.t("监听端口", "Listening ports"),
                             value: d.ports.prefix(8).map { $0.address + ($0.isPublic ? " ⚠︎" : "") }.joined(separator: "  "),
                             mono: true))
        }
        if d.preventsSleep { res.append(Field(label: L10n.t("阻止睡眠", "Prevents sleep"), value: L10n.t("是", "Yes"), tint: Self.orange)) }
        res.append(Field(label: L10n.t("磁盘 I/O", "Disk I/O"),
                         value: "\(ProcessText.bytes(d.diskRead)) R · \(ProcessText.bytes(d.diskWritten)) W"))

        var env: [Field] = []
        if !d.user.isEmpty { env.append(Field(label: L10n.t("用户", "User"), value: d.user)) }
        if let s = d.started {
            env.append(Field(label: L10n.t("启动时间", "Started"), value: ProcessText.compactDuration(Date().timeIntervalSince(s))))
        }
        if let c = d.cwd { env.append(Field(label: L10n.t("工作目录", "Working dir"), value: c, mono: true)) }
        if let gi = d.gitRepo { env.append(Field(label: L10n.t("Git 仓库", "Git repo"), value: gi, mono: true)) }
        if !d.children.isEmpty { env.append(Field(label: L10n.t("子进程", "Children"), value: d.children.prefix(6).joined(separator: " · "))) }
        if let app = g.appPath {
            env.append(Field(label: L10n.t("可执行文件", "Executable"),
                             value: "\((app as NSString).lastPathComponent) / \(((d.rawPath ?? "") as NSString).lastPathComponent)"))
        } else if let p = d.rawPath {
            env.append(Field(label: L10n.t("可执行文件", "Executable"), value: (p as NSString).lastPathComponent))
        }
        return [FieldGroup(title: L10n.t("来源", "Source"), rows: source),
                FieldGroup(title: L10n.t("资源", "Resources"), rows: res),
                FieldGroup(title: L10n.t("环境", "Environment"), rows: env)].filter { !$0.rows.isEmpty }
    }

    // MARK: - 成员进程

    private func members(_ g: ProcessGroup) -> some View {
        let top = Array(g.members.prefix(6))
        let rest = g.members.dropFirst(6)
        let maxMem = Double(max(g.members.first?.memoryBytes ?? 1, 1))
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.t("进程", "Processes")).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(L10n.t("按内存", "By memory")).font(.system(size: 10))
            }
            .foregroundStyle(SysTheme.secondary)
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)

            memberRow("", L10n.t("名称", "Name"), "PID", "%CPU", L10n.t("内存", "Memory"), frac: nil)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SysTheme.secondary)
                .padding(.bottom, 4)
            Rectangle().fill(SysTheme.separator.opacity(0.6)).frame(height: 1)

            ForEach(top) { m in
                memberRow(m.name, m.name, String(m.pid), String(format: "%.1f%%", m.cpuPercent),
                          ProcessText.bytes(m.memoryBytes), frac: Double(m.memoryBytes) / maxMem,
                          sleeps: vm.detail?.sleepPIDs.contains(m.pid) == true,
                          port: vm.detail?.publicPortPIDs.contains(m.pid) == true)
                    .font(.system(size: 12).monospacedDigit())
            }
            if !rest.isEmpty {
                HStack {
                    Text(L10n.t("其余 \(rest.count) 个进程", "\(rest.count) more processes"))
                    Spacer()
                    Text(ProcessText.bytes(rest.reduce(0) { $0 + $1.memoryBytes }))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(SysTheme.secondary)
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
            Spacer().frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    private func memberRow(_ id: String, _ name: String, _ pid: String, _ cpu: String, _ mem: String,
                           frac: Double?, sleeps: Bool = false, port: Bool = false) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(name).lineLimit(1)
                if sleeps {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 9)).foregroundStyle(Self.orange)
                        .help(L10n.t("正在阻止系统睡眠", "Preventing system sleep"))
                }
                if port {
                    Image(systemName: "network").font(.system(size: 9)).foregroundStyle(Self.orange)
                        .help(L10n.t("正在监听公开网络接口", "Listening on a public interface"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(pid).foregroundStyle(SysTheme.secondary).frame(width: 52, alignment: .trailing)
            Text(cpu).frame(width: 48, alignment: .trailing)
            ZStack(alignment: .trailing) {
                if let frac {
                    GeometryReader { geo in
                        Capsule().fill(SysTheme.mem.opacity(0.22))
                            .frame(width: max(3, geo.size.width * frac))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .frame(height: 4)
                    .offset(y: 11)
                }
                Text(mem)
            }
            .frame(width: 76, height: 22, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
    }

    // MARK: - 原始路径与命令

    private func raw(_ d: ProcessDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.12)) { showRaw.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: showRaw ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold)).frame(width: 8)
                    Text(L10n.t("原始路径与命令", "Raw path and command")).font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(SysTheme.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showRaw {
                VStack(alignment: .leading, spacing: 6) {
                    Text(d.rawPath ?? "—")
                    if let c = d.command, !c.isEmpty { Text(c).foregroundStyle(SysTheme.secondary) }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    // MARK: - 操作栏

    private func actions(_ g: ProcessGroup) -> some View {
        let protected = SystemMonitorActions.isProtected(g)
        let canKill = !protected && vm.detailAlive
        return VStack(spacing: 8) {
            if let m = vm.detailMessage {
                HStack(spacing: 6) {
                    Image(systemName: vm.detailFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(vm.detailFailed ? Color.red : Self.green)
                    Text(m).font(.system(size: 11))
                        .foregroundStyle(vm.detailFailed ? Color.red : SysTheme.secondary)
                    Spacer(minLength: 0)
                    if vm.detailFailed {
                        Button(L10n.t("重试", "Retry")) { vm.loadDetail(); vm.detailMessage = nil }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SysTheme.brand)
                    }
                }
            } else if protected {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(SysTheme.secondary)
                    Text(L10n.t("系统进程,无法终止", "System process, can’t be terminated"))
                        .font(.system(size: 11)).foregroundStyle(SysTheme.secondary)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                pill(copied ? L10n.t("已复制", "Copied") : L10n.t("复制摘要", "Copy Summary"),
                     icon: copied ? "checkmark" : "doc.on.doc") {
                    SystemMonitorActions.copy(summaryText(g))
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                pill(L10n.t("在访达中显示", "Show in Finder"), icon: "folder") { SystemMonitorActions.revealInFinder(g) }
                Spacer(minLength: 0)
                pill(L10n.t("终止", "Terminate"), icon: "rectangle.portrait.and.arrow.right", disabled: !canKill) {
                    vm.terminateDetail(force: false)
                }
                pill(L10n.t("强制退出", "Force Quit"), icon: "xmark.circle.fill", destructive: true, disabled: !canKill) {
                    vm.terminateDetail(force: true)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(SysTheme.sheet)
        .overlay(alignment: .top) { Rectangle().fill(SysTheme.separator).frame(height: 1) }
    }

    private func pill(_ title: String, icon: String, destructive: Bool = false, disabled: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
        }
        .buttonStyle(DetailPillStyle(destructive: destructive))
        .disabled(disabled)
        .opacity(disabled ? 0.38 : 1)
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    // MARK: - 复制摘要

    private func summaryText(_ g: ProcessGroup) -> String {
        var lines = ["\(g.name) (PID \(g.mainPID))",
                     L10n.t("\(g.count) 个进程 · CPU \(String(format: "%.1f%%", g.cpuPercent)) · 内存 \(ProcessText.bytes(g.memoryBytes))",
                            "\(g.count) processes · CPU \(String(format: "%.1f%%", g.cpuPercent)) · memory \(ProcessText.bytes(g.memoryBytes))")]
        guard let d = vm.detail else { return lines.joined(separator: "\n") }
        lines.append(d.source.summary)
        lines.append(L10n.t("启动链:", "Launch chain: ") + d.chain.map { "\($0.appName ?? $0.name)(\($0.pid))" }.joined(separator: " > "))
        for grp in fieldGroups(g, d) { for r in grp.rows { lines.append("\(r.label): \(r.value)") } }
        if !d.warnings.isEmpty { lines.append(L10n.t("警告:", "Warnings: ") + d.warnings.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }
}

/// 胶囊按钮:悬停加深,按下略缩;强退用红色
private struct DetailPillStyle: ButtonStyle {
    let destructive: Bool
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(destructive ? Color.red : Color(nsColor: .labelColor))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(destructive ? Color.red.opacity(hover ? 0.2 : 0.11)
                                                    : SysTheme.track.opacity(hover ? 1.7 : 1)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .onHover { hover = $0 }
    }
}
