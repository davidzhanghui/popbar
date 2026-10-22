import SwiftUI

/// 任务行:点击展开详情(时间线、参数、原因、操作)。展开在行内,不开新窗口
struct PrintJobRow: View {
    @ObservedObject var center: PrintCenter
    let job: JobRecord
    var compact = false
    @State private var expanded = false

    private var printerName: String { center.data.printer(job.printer)?.displayName ?? job.printer }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PThumb(url: center.thumbURL(job), width: compact ? 28 : 34, height: compact ? 36 : 44,
                       symbol: job.mime.hasPrefix("image/") ? "photo" : "doc.text")
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary).lineLimit(1)
                    if let r = reasonLine {
                        Text(r).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                PBadge(text: PrintStyle.jobStateText(job), color: PrintStyle.jobColor(job), filled: job.state == .processing)
                actions
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SysTheme.tertiary).rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }

            if expanded { detail }
            Divider().opacity(0.4)
        }
    }

    private var subtitle: String {
        var parts = [printerName, PrintStyle.time(job.created)]
        if job.state == .processing, job.impressionsDone > 0 {
            // job-impressions 在作业结束前一直是 0,只能显示「已打印 N 页」,不能算百分比
            parts.append(L10n.t("已打印 \(job.impressionsDone) 页", "\(job.impressionsDone) page(s) printed"))
        } else if let p = job.pageCount {
            parts.append(job.copies > 1 ? L10n.t("\(p) 页 × \(job.copies) 份", "\(p) pg × \(job.copies)") : L10n.t("\(p) 页", "\(p) pg"))
        }
        if job.source == .external { parts.append(L10n.t("外部", "External")) }
        return parts.joined(separator: " · ")
    }

    /// 异常原因(去掉静默原因)
    private var reasonLine: String? {
        guard job.state != .completed else { return nil }
        let l = PrintReasons.labels(job.reasons)
        return l.isEmpty ? nil : l.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        if job.isLive {
            if job.state == .held { PIcon(symbol: "play.fill", help: L10n.t("继续", "Release")) { Task { await center.release(job) } } }
            PIcon(symbol: "xmark", help: L10n.t("取消任务", "Cancel job"), tint: .red) { Task { await center.cancel(job) } }
        } else if center.fileURL(job) != nil, job.source == .app {
            PIcon(symbol: "arrow.counterclockwise", help: L10n.t("原样重新打印", "Print again")) {
                Task {
                    switch await center.reprint(job) {
                    case .success: center.say(L10n.t("已重新提交「\(job.title)」", "Resubmitted “\(job.title)”"))
                    case .failure(let e): center.say(e.text)
                    }
                }
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("时间线", "Timeline")).font(.system(size: 11, weight: .semibold))
                    line(L10n.t("提交", "Submitted"), job.created)
                    if let p = job.processing { line(L10n.t("开始打印", "Started"), p) }
                    if let c = job.completed { line(job.state == .completed ? L10n.t("完成", "Done") : L10n.t("结束", "Ended"), c) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("参数", "Options")).font(.system(size: 11, weight: .semibold))
                    Text(optionSummary).font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if job.sizeBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(job.sizeBytes), countStyle: .file) + " · " + job.mime)
                            .font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            if !job.message.isEmpty {
                Text(job.message).font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary)
            }
            if !job.localError.isEmpty {
                Text(job.localError).font(.system(size: 10.5)).foregroundStyle(.orange)
            }
            HStack(spacing: 6) {
                if job.isLive {
                    if job.state == .held {
                        PBtn(title: L10n.t("继续", "Release"), symbol: "play.fill") { Task { await center.release(job) } }
                    } else if job.state == .pending {
                        PBtn(title: L10n.t("挂起", "Hold"), symbol: "pause.fill") { Task { await center.hold(job) } }
                    }
                    PBtn(title: L10n.t("提到队首", "Move to front"), symbol: "arrow.up.to.line") { Task { await center.moveToFront(job) } }
                    PBtn(title: L10n.t("取消", "Cancel"), symbol: "xmark", destructive: true) { Task { await center.cancel(job) } }
                }
                if let f = center.fileURL(job) {
                    PBtn(title: L10n.t("在访达中显示", "Reveal in Finder"), symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    PBtn(title: L10n.t("打开原文件", "Open original"), symbol: "doc.text.magnifyingglass") { NSWorkspace.shared.open(f) }
                } else if job.source == .app {
                    Text(L10n.t("原文件已清理,无法重新打印", "Original file cleaned up — cannot reprint"))
                        .font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary)
                }
                Spacer()
                Text("CUPS #\(job.cupsJobId)").font(.system(size: 10).monospacedDigit()).foregroundStyle(SysTheme.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
        .padding(.leading, 40)
    }

    private func line(_ t: String, _ d: Date) -> some View {
        HStack(spacing: 6) {
            Text(t).font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary).frame(width: 52, alignment: .leading)
            Text(d.formatted(date: .abbreviated, time: .standard)).font(.system(size: 10.5).monospacedDigit())
        }
    }

    private var optionSummary: String {
        let o = job.options
        var p: [String] = [L10n.t("\(o.copies) 份", "\(o.copies) cop.")]
        if !o.color.isEmpty { p.append(PrintLabels.color(o.color)) }
        if !o.quality.isEmpty { p.append(PrintLabels.quality(o.quality)) }
        if !o.media.isEmpty { p.append(PrintLabels.media(o.media)) }
        if !o.mediaType.isEmpty { p.append(PrintLabels.mediaType(o.mediaType)) }
        if !o.sides.isEmpty { p.append(PrintLabels.sides(o.sides)) }
        if !o.orientation.isEmpty { p.append(PrintLabels.orientation(o.orientation)) }
        if o.numberUp > 1 { p.append(L10n.t("每张 \(o.numberUp) 页", "\(o.numberUp)-up")) }
        if !o.scaling.isEmpty { p.append(PrintLabels.scaling(o.scaling)) }
        if !o.pageRange.isEmpty { p.append(L10n.t("第 \(o.pageRange) 页", "pages \(o.pageRange)")) }
        if o.hold { p.append(L10n.t("先挂起", "held")) }
        return job.source == .external ? L10n.t("外部应用提交,参数未知", "Submitted by another app (options unknown)") : p.joined(separator: " · ")
    }
}

/// 任务中心:筛选 / 搜索 / 展开操作
struct PrintJobsView: View {
    @ObservedObject var center: PrintCenter
    enum Filter: String, CaseIterable { case all, active, completed, failed }
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var limit = 50

    private var printerFilter: Binding<String> {
        Binding(get: { center.jobsPrinterFilter ?? "" }, set: { center.jobsPrinterFilter = $0.isEmpty ? nil : $0 })
    }

    private func matches(_ j: JobRecord) -> Bool {
        switch filter {
        case .all: break
        case .active: if !j.isLive { return false }
        case .completed: if j.state != .completed { return false }
        case .failed: if !j.state.isFailed { return false }
        }
        if let p = center.jobsPrinterFilter, j.printer != p { return false }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, !j.title.localizedCaseInsensitiveContains(q), !j.fileName.localizedCaseInsensitiveContains(q) { return false }
        return true
    }

    private func label(_ f: Filter, _ n: Int) -> String {
        switch f {
        case .all: return L10n.t("全部 \(n)", "All \(n)")
        case .active: return L10n.t("进行中 \(n)", "Active \(n)")
        case .completed: return L10n.t("已完成 \(n)", "Done \(n)")
        case .failed: return L10n.t("失败 \(n)", "Failed \(n)")
        }
    }

    var body: some View {
        let all = center.data.sortedJobs()
        let shown = all.filter(matches)
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Filter.allCases, id: \.self) { f in
                    let n = all.filter { j in
                        switch f {
                        case .all: return true
                        case .active: return j.isLive
                        case .completed: return j.state == .completed
                        case .failed: return j.state.isFailed
                        }
                    }.count
                    Button { filter = f; limit = 50 } label: {
                        Text(label(f, n)).font(.system(size: 11.5, weight: filter == f ? .semibold : .regular))
                            .foregroundStyle(filter == f ? Color.white : SysTheme.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(filter == f ? PanelTheme.brandColor : SysTheme.track))
                    }.buttonStyle(.plain)
                }
                Spacer()
                PMenu(label: L10n.t("全部打印机", "All printers"), selection: printerFilter,
                      options: [("", L10n.t("全部打印机", "All printers"))]
                        + center.data.printers.map { ($0.name, $0.displayName) })
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(SysTheme.tertiary)
                TextField(L10n.t("搜索任务名 / 文件名", "Search title / file name"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SysTheme.track))

            ScrollView {
                LazyVStack(spacing: 0) {
                    if shown.isEmpty {
                        Text(L10n.t("没有符合条件的任务", "No matching jobs"))
                            .font(.system(size: 12)).foregroundStyle(SysTheme.secondary).padding(30)
                    }
                    ForEach(shown.prefix(limit)) { PrintJobRow(center: center, job: $0) }
                    if shown.count > limit {
                        PBtn(title: L10n.t("加载更多(还有 \(shown.count - limit) 条)", "Load more (\(shown.count - limit) left)")) { limit += 50 }
                            .padding(10)
                    }
                }
                .padding(.horizontal, 4)
            }
            .background(CardBackground())
        }
    }
}
