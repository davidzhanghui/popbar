import SwiftUI
import Charts

/// 用量统计:总量卡片 + 按日 / 按周柱状图 + 按打印机 / 状态 / 来源分布
struct PrintStatsView: View {
    @ObservedObject var center: PrintCenter
    @State private var days = 30
    @State private var metric = 0   // 0 页数 / 1 任务数

    var body: some View {
        let s = PrintStats.summary(center.data, days: days)
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                HStack {
                    Text(L10n.t("用量统计", "Usage")).font(.system(size: 15, weight: .bold))
                    Spacer()
                    PMenu(label: "", selection: $metric, options: [(0, L10n.t("按页数", "By pages")), (1, L10n.t("按任务数", "By jobs"))])
                    PMenu(label: "", selection: $days, options: [
                        (7, L10n.t("近 7 天", "7 days")), (30, L10n.t("近 30 天", "30 days")),
                        (90, L10n.t("近 90 天", "90 days")), (365, L10n.t("近一年", "1 year"))])
                }
                .padding(.horizontal, 4)

                HStack(spacing: 8) {
                    tile(L10n.t("页数", "Pages"), "\(s.pages)", PanelTheme.brandColor)
                    tile(L10n.t("任务", "Jobs"), "\(s.jobs)", SysTheme.cpu)
                    tile(L10n.t("已完成", "Completed"), "\(s.completed)", SysTheme.battery)
                    tile(L10n.t("失败/取消", "Failed"), "\(s.failed)", SysTheme.temp)
                }

                if s.jobs == 0 {
                    Text(L10n.t("这段时间没有打印记录", "No print activity in this period"))
                        .font(.system(size: 12)).foregroundStyle(SysTheme.secondary).padding(30)
                } else {
                    PSection(title: L10n.t("按日(最近 30 天内)", "Daily (last 30 days)")) {
                        Chart(s.byDay) { b in
                            BarMark(x: .value("d", b.key), y: .value("v", metric == 0 ? b.pages : b.jobs))
                                .foregroundStyle(PanelTheme.brandColor.gradient).cornerRadius(2)
                        }
                        .chartXAxis {
                            AxisMarks(values: s.byDay.enumerated().filter { $0.offset % max(s.byDay.count / 4, 1) == 0 }.map(\.element.key)) { v in
                                AxisValueLabel { if let k = v.as(String.self) { Text(String(k.suffix(5))).font(.system(size: 9)) } }
                            }
                        }
                        .frame(height: 130)
                    }
                    if days > 30 {
                        PSection(title: L10n.t("按周", "Weekly")) {
                            Chart(s.byWeek) { b in
                                BarMark(x: .value("w", b.key), y: .value("v", metric == 0 ? b.pages : b.jobs))
                                    .foregroundStyle(SysTheme.cpu.gradient).cornerRadius(2)
                            }
                            .chartXAxis {
                                AxisMarks(values: s.byWeek.enumerated().filter { $0.offset % max(s.byWeek.count / 6, 1) == 0 }.map(\.element.key)) { v in
                                    AxisValueLabel { if let k = v.as(String.self) { Text(k).font(.system(size: 9)) } }
                                }
                            }
                            .frame(height: 110)
                        }
                    }
                    PSection(title: L10n.t("按打印机", "By printer")) {
                        ForEach(s.byPrinter) { b in
                            bar(b.key, metric == 0 ? b.pages : b.jobs, max: (s.byPrinter.map { metric == 0 ? $0.pages : $0.jobs }.max() ?? 1),
                                detail: L10n.t("\(b.jobs) 个任务 · \(b.pages) 页", "\(b.jobs) jobs · \(b.pages) pg"))
                        }
                    }
                    HStack(alignment: .top, spacing: 10) {
                        PSection(title: L10n.t("任务状态", "Job states")) {
                            ForEach(s.byState) { b in
                                HStack {
                                    PBadge(text: JobState(rawValue: b.key)?.label ?? b.key, color: color(b.key))
                                    Spacer()
                                    Text("\(b.jobs)").font(.system(size: 12).monospacedDigit())
                                }
                            }
                        }
                        PSection(title: L10n.t("来源", "Source")) {
                            ForEach(s.bySource) { b in
                                HStack {
                                    Text(b.key == "app" ? L10n.t("PopBar 提交", "Via PopBar") : L10n.t("其它应用", "Other apps")).font(.system(size: 12))
                                    Spacer()
                                    Text(L10n.t("\(b.jobs) 个 · \(b.pages) 页", "\(b.jobs) · \(b.pages) pg")).font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(SysTheme.secondary)
                                }
                            }
                        }
                    }
                    Text(L10n.t("页数口径:作业上报的页数,缺失时退回「文档页数 × 份数」;只统计已完成的作业。",
                                "Pages = pages reported by the job, falling back to document pages × copies; completed jobs only."))
                        .font(.system(size: 10.5)).foregroundStyle(SysTheme.tertiary).padding(.horizontal, 4)
                }
            }
        }
    }

    private func color(_ state: String) -> Color {
        switch JobState(rawValue: state) ?? .unknown {
        case .completed: return .green
        case .canceled: return .gray
        case .aborted: return .red
        default: return PanelTheme.brandColor
        }
    }

    private func tile(_ title: String, _ value: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(title).font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary) }
            Text(value).font(.system(size: 20, weight: .bold).monospacedDigit())
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(CardBackground())
    }

    private func bar(_ name: String, _ v: Int, max m: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(name).font(.system(size: 12)); Spacer(); Text(detail).font(.system(size: 10.5)).foregroundStyle(SysTheme.secondary) }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(SysTheme.track)
                    Capsule().fill(PanelTheme.brandColor).frame(width: g.size.width * CGFloat(v) / CGFloat(Swift.max(m, 1)))
                }
            }.frame(height: 6)
        }
    }
}
