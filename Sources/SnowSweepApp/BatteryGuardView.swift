import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import SnowSweepCore

private struct ChargePoint: Identifiable {
    let id: String
    let day: Date
    let value: Int
    let kind: String
}

/// V0.5.0 电池守护：把系统能读到的日常数据记在本机，用规则给行为建议。
/// V0.8.0 起拆成「日常趋势」与「建议」两个页签，V0.5 的完整页面仍作为默认合并视图保留。
/// 这里没有模型调用，也不修改任何系统设置；容量与循环仍以系统报告为准。
struct BatteryGuardView: View {
    enum Section: Hashable, CaseIterable {
        case trend
        case advice
    }

    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var model: ScanViewModel
    @State private var rangeDays = 7
    @State private var exportMessage: String?
    @State private var exportFailed = false
    let sections: Set<Section>

    init(sections: Set<Section> = Set(Section.allCases)) {
        self.sections = sections
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if let error = monitor.dailyError {
                    InfoBanner(text: error, color: .red)
                }
                if !monitor.dailyPruneNotice.isEmpty {
                    InfoBanner(text: monitor.dailyPruneNotice, color: .green)
                }
                if !model.dailyJournalEnabled {
                    InfoBanner(text: "日常记录已暂停。已经写入的历史不会被删除；重新打开开关后，从下一次采样开始继续。", color: .orange)
                }
                if let exportMessage {
                    InfoBanner(text: exportMessage, color: exportFailed ? .red : .green)
                }

                if monitor.dailyLoaded {
                    if sections.contains(.trend) {
                        metrics
                        chartCard
                        detailCard
                    }
                    if sections.contains(.advice) {
                        findingsCard
                    }
                } else {
                    InfoBanner(text: "正在读取本地日常记录…", color: .gray)
                }

                InfoBanner(text: "记录只保存在本机：~/Library/Application Support/雪/daily-metrics.jsonl。按运行模式每 30 / 10 / 5 分钟一条，雪退出后不补采；插电比例是样本占比，不是连续分钟数。每次启动会按 120 天保留策略自动裁剪旧记录。", color: .blue)
                InfoBanner(text: "温度只在 IORegistry 确实提供时记录，读不到就留空，不用估算值参与判断；电池健康度与循环次数仍以 macOS 系统报告为准。", color: .gray)
            }
            .padding(18)
        }
        .task { await monitor.refreshDailyJournal(days: rangeDays) }
        .onChange(of: rangeDays) { _, value in
            Task { await monitor.refreshDailyJournal(days: value) }
        }
    }

    private var isAdviceOnly: Bool {
        sections == [.advice]
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            PageHeader(title: isAdviceOnly ? "电池建议" : "日常趋势",
                       subtitle: isAdviceOnly
                       ? "规则命中才提示；记录只在本机，不参与清理判定。"
                       : "每 30 / 10 / 5 分钟记录一次电量、电源、热压力、磁盘与内存；只在本机看趋势，不上传。")
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Toggle("记录日常数据", isOn: Binding(
                    get: { model.dailyJournalEnabled },
                    set: { enabled in
                        model.dailyJournalEnabled = enabled
                        if enabled { Task { await monitor.recordDailySnapshot(force: true) } }
                    }
                ))
                .toggleStyle(.switch)
                HStack(spacing: 6) {
                    Button("立即记录") { Task { await monitor.recordDailySnapshot(force: true) } }
                        .disabled(monitor.isRecordingDaily)
                    Button("导出周报") { exportReport() }
                    Button("数据文件") { monitor.revealDailyJournal() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                            GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetricTile(title: "今日样本", value: "\(today?.sampleCount ?? 0)",
                       foot: monitor.dailyLatest.map { "最近 \(timeText($0.at))" } ?? "还没有记录",
                       color: .blue)
            MetricTile(title: "今日电量", value: chargeRangeText(today),
                       foot: today?.chargeEnd.map { "日末 \($0)%" } ?? "今天还没有样本",
                       color: .green)
            MetricTile(title: "7 天循环", value: cycleDeltaText,
                       foot: cycleFootText,
                       color: .purple)
            MetricTile(title: "热压力告警", value: "\(thermalAlertsLastSeven)",
                       foot: maxTempLastSeven.map { "最高 \(String(format: "%.1f", $0)) °C" } ?? "温度读不到",
                       color: thermalAlertsLastSeven > 0 ? .orange : .blue)
        }
    }

    private var chartCard: some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("电量趋势").font(.headline)
                    Text("最低 / 最高").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("统计范围", selection: $rangeDays) {
                        Text("7 天").tag(7)
                        Text("30 天").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                }
                if chargePoints.isEmpty {
                    InfoBanner(text: "这个范围里还没有电量样本。保持菜单栏常驻并点「立即记录」，就能开始画趋势。", color: .gray)
                } else {
                    Chart(chargePoints) { point in
                        LineMark(
                            x: .value("日期", point.day, unit: .day),
                            y: .value("电量", point.value)
                        )
                        .foregroundStyle(by: .value("曲线", point.kind))
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("日期", point.day, unit: .day),
                            y: .value("电量", point.value)
                        )
                        .foregroundStyle(by: .value("曲线", point.kind))
                        .symbolSize(26)
                    }
                    .chartYScale(domain: 0...100)
                    .chartXScale(domain: chartStart...chartEnd)
                    .chartYAxis {
                        AxisMarks(values: [0, 20, 40, 60, 80, 100])
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.month().day())
                        }
                    }
                    .chartLegend(position: .bottom)
                    .frame(height: 190)
                }
                Text("曲线用每天记录到的最低与最高电量；缺失的日子不补零，避免把「没记录」画成「掉到 0%」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var findingsCard: some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("本机建议").font(.headline)
                    Text("规则命中才提示").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(monitor.dailySummaries.count) 天 · \(totalSamples) 样本")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if monitor.dailyFindings.isEmpty {
                    Text("还没有足够的记录来给建议。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(monitor.dailyFindings) { finding in
                        findingRow(finding)
                    }
                }
            }
        }
    }

    private var detailCard: some View {
        ModuleCard(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("每日明细").font(.headline)
                    Spacer()
                    Text("按自然日 · 最近 \(monitor.dailySummaries.count) 天")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                Divider()
                if monitor.dailySummaries.isEmpty {
                    Text("暂无每日明细。")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    detailHeader
                    ForEach(Array(monitor.dailySummaries.reversed())) { day in
                        detailRow(day)
                    }
                }
            }
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 8) {
            Text("日期").frame(width: 64, alignment: .leading)
            Text("样本").frame(width: 42, alignment: .trailing)
            Text("电量").frame(width: 92, alignment: .leading)
            Text("插电").frame(width: 62, alignment: .trailing)
            Text("循环").frame(width: 96, alignment: .trailing)
            Text("健康").frame(width: 58, alignment: .trailing)
            Text("温度").frame(width: 72, alignment: .trailing)
            Text("磁盘").frame(width: 78, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func detailRow(_ day: DailyBatterySummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(day.day, format: .dateTime.month().day())
                    .frame(width: 64, alignment: .leading)
                Text("\(day.sampleCount)")
                    .frame(width: 42, alignment: .trailing)
                Text(chargeRangeText(day))
                    .frame(width: 92, alignment: .leading)
                Text(day.pluggedSampleRatio > 0 ? "\(Int((day.pluggedSampleRatio * 100).rounded()))%" : "—")
                    .frame(width: 62, alignment: .trailing)
                Text(cycleText(day))
                    .frame(width: 96, alignment: .trailing)
                Text(day.healthPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                    .frame(width: 58, alignment: .trailing)
                Text(day.maxTemperatureC.map { String(format: "%.1f", $0) } ?? "读不到")
                    .frame(width: 72, alignment: .trailing)
                Text(day.diskFreeEnd.map { SystemMetrics.bytesText($0) } ?? "—")
                    .frame(width: 78, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            Divider()
        }
    }

    private func findingRow(_ finding: BatteryGuardFinding) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: findingIcon(finding.level))
                .foregroundStyle(findingColor(finding.level))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).font(.callout.weight(.medium))
                Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(findingColor(finding.level).opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private var today: DailyBatterySummary? {
        monitor.dailySummaries.last { Calendar.current.isDateInToday($0.day) }
    }

    private var lastSeven: [DailyBatterySummary] {
        let start = Calendar.current.date(byAdding: .day, value: -6,
                                          to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return monitor.dailySummaries.filter { $0.day >= start }
    }

    private var totalSamples: Int {
        monitor.dailySummaries.reduce(0) { $0 + $1.sampleCount }
    }

    private var thermalAlertsLastSeven: Int {
        lastSeven.reduce(0) { $0 + $1.thermalAlertSamples }
    }

    private var maxTempLastSeven: Double? {
        lastSeven.compactMap(\.maxTemperatureC).max()
    }

    private var cycleDeltaText: String {
        guard let first = lastSeven.first, let last = lastSeven.last,
              let start = first.cycleStart, let end = last.cycleEnd else { return "—" }
        let delta = end - start
        return delta >= 0 ? "+\(delta)" : "\(delta)"
    }

    private var cycleFootText: String {
        guard let first = lastSeven.first, let last = lastSeven.last,
              let start = first.cycleStart, let end = last.cycleEnd else { return "还没有循环记录" }
        return "\(start) → \(end)"
    }

    private var chargePoints: [ChargePoint] {
        monitor.dailySummaries.flatMap { day -> [ChargePoint] in
            var points: [ChargePoint] = []
            if let low = day.chargeMin {
                points.append(ChargePoint(id: "\(day.id.timeIntervalSince1970)-low", day: day.day,
                                          value: low, kind: "最低"))
            }
            if let high = day.chargeMax {
                points.append(ChargePoint(id: "\(day.id.timeIntervalSince1970)-high", day: day.day,
                                          value: high, kind: "最高"))
            }
            return points
        }
    }

    private var chartStart: Date {
        Calendar.current.date(byAdding: .day, value: -(rangeDays - 1),
                              to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private var chartEnd: Date {
        Calendar.current.date(byAdding: .day, value: 1,
                              to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private func chargeRangeText(_ day: DailyBatterySummary?) -> String {
        guard let day else { return "—" }
        if let low = day.chargeMin, let high = day.chargeMax {
            return "\(low)–\(high)%"
        }
        return "—"
    }

    private func cycleText(_ day: DailyBatterySummary) -> String {
        guard let start = day.cycleStart, let end = day.cycleEnd else { return "—" }
        let delta = end - start
        if delta == 0 { return "\(end)" }
        return "\(start)→\(end) (\(delta > 0 ? "+" : "")\(delta))"
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func findingIcon(_ level: BatteryGuardFinding.Level) -> String {
        switch level {
        case .attention: return "exclamationmark.triangle.fill"
        case .insufficient: return "hourglass"
        case .good: return "checkmark.seal.fill"
        }
    }

    private func findingColor(_ level: BatteryGuardFinding.Level) -> Color {
        switch level {
        case .attention: return .orange
        case .insufficient: return .gray
        case .good: return .green
        }
    }

    private func exportReport() {
        Task {
            guard let report = await monitor.dailyReport(days: rangeDays) else {
                exportFailed = true
                exportMessage = monitor.dailyError ?? "生成周报失败。"
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "雪-电池周报-\(stamp()).md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                exportFailed = false
                exportMessage = "已导出周报：\(url.lastPathComponent)"
            } catch {
                exportFailed = true
                exportMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}
