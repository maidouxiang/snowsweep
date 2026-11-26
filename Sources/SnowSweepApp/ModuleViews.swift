import SwiftUI
import AppKit
import SnowSweepCore

// MARK: - 共用小组件

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .tracking(0.3)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let foot: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(foot)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

struct MetricBar: View {
    let fraction: Double
    var color: Color = .blue
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(color).frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

struct InfoBanner: View {
    let text: String
    var color: Color = .orange
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(color)
                .font(.callout)
                .frame(width: 16, alignment: .center)
            Text(text)
                .font(.callout)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct ScoreRing: View {
    let score: Int
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.16), lineWidth: 11)
            Circle()
                .trim(from: 0, to: CGFloat(min(100, max(0, score))) / 100)
                .stroke(score >= 80 ? SnowSkin.green : (score >= 60 ? SnowSkin.orange : SnowSkin.danger),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text("\(score)").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("健康评分").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 132, height: 132)
    }
}

struct ModuleCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

/// 内存压力配色：与文案阈值保持一致，绿 60% 以下、橙 60–80%、红 80% 以上。
func pressureTint(_ fraction: Double?) -> Color {
    guard let f = fraction else { return .gray }
    if f < 0.6 { return SnowSkin.green }
    if f < 0.8 { return SnowSkin.orange }
    return SnowSkin.danger
}

/// 目录名中文化；英文原名保留在次要位置，方便对照 Finder。
func folderCN(_ name: String) -> String {
    switch name {
    case "Library": return "资源库"
    case "Desktop": return "桌面"
    case "Documents": return "文稿"
    case "Downloads": return "下载"
    case "Movies": return "影片"
    case "Music": return "音乐"
    case "Pictures": return "图片"
    case ".npm": return "npm 缓存"
    case ".gradle": return "Gradle 缓存"
    default: return name
    }
}

// MARK: - 概览

struct DashboardView: View {
    @EnvironmentObject var model: ScanViewModel
    @EnvironmentObject var monitor: SystemMonitor
    @ObservedObject private var provider = AssistantProviderSettings.shared
    @AppStorage("snow.main.selection") private var selection = "概览"

    @State private var showHealthDetail = true
    @State private var dailySummaries: [DailyBatterySummary] = []
    @State private var observationReport: LocalObservationReport?
    @State private var observationEvidence: [String: String] = [:]
    @State private var observationFailure: String?
    @State private var observationCapturedAt: Date?
    @State private var isObserving = false

    private var health: HealthScore? {
        guard let disk = monitor.disk, let memory = monitor.memory else { return nil }
        return HealthScore.evaluate(
            diskFreeRatio: Double(disk.freeBytes) / Double(max(1, disk.totalBytes)),
            memoryUsedFraction: memory.usedFraction,
            batteryHealthPercent: monitor.battery?.healthPercent
        )
    }

    private var score: Int { health?.total ?? 0 }
    private var scoreTitle: String { health?.title ?? "等待读取" }

    /// 建议只描述事实和可做的下一步，不制造“必须清理”的压力。
    private var healthAdvice: [(title: String, detail: String, section: String)] {
        guard let disk = monitor.disk, let memory = monitor.memory else {
            return [("还在读取本机指标", "磁盘和内存读完后才会给出建议。", "状态")]
        }
        var items: [(String, String, String)] = []
        let freeRatio = Double(disk.freeBytes) / Double(max(1, disk.totalBytes))
        if freeRatio < 0.15 {
            items.append(("磁盘可用低于 15%",
                          "当前可用 \(SystemMetrics.bytesText(disk.freeBytes))。先预览清理，再决定是否执行。",
                          "清理"))
        }
        if memory.usedFraction >= 0.6 {
            items.append(("内存压力偏高",
                          "已用 \(Int(memory.usedFraction * 100))%。到「内存分析」看看谁占得最多。",
                          "内存"))
        }
        if let battery = monitor.battery, let health = battery.healthPercent, health < 80 {
            items.append(("电池最大容量低于 80%",
                          "当前 \(Int(health))%，循环 \(battery.cycleCount ?? 0) 次。可查看电池健康页。",
                          "电池健康"))
        }
        if let gaps = model.report?.scanGaps, gaps.contains(where: { $0.severity == .critical }) {
            items.append(("上次扫描有完全磁盘访问缺口",
                          "关键位置没读到，报告已锁定清理；去「扫描缺口」查看具体位置。",
                          "缺口"))
        }
        if items.isEmpty {
            items.append(("没有需要立刻处理的项目",
                          "三项指标都在安全区间；定期体检即可，不必为了分数清理。",
                          "清理"))
        }
        return items
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    PageHeader(title: "概览", subtitle: "所有项目都用中文说明是什么、能不能删。数据只来自本机。")
                    Spacer()
                    Button("查看扫描缺口") { selection = "缺口" }
                    Button("立即体检") { model.startScan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isScanning)
                }

                HStack(alignment: .top, spacing: 14) {
                    ModuleCard {
                        VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 18) {
                            ScoreRing(score: score)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(scoreTitle).font(.title3.weight(.semibold))
                                Text(diskSummary).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    Button("看清理建议") { selection = "清理" }.buttonStyle(.borderedProminent)
                                    Button("电池健康") { selection = "电池健康" }
                                }
                            }
                        }

                        if let health {
                            Divider().padding(.vertical, 2)
                            DisclosureGroup(isExpanded: $showHealthDetail) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("分数 = 各项得分按权重相加。磁盘 / 内存是区间扣分，电池按真实最大容量；没有电池的机器不把电池按 90 分硬算。")
                                        .font(.caption).foregroundStyle(.secondary)
                                    ForEach(health.components) { component in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(component.label).font(.callout.weight(.medium))
                                                Spacer()
                                                Text("\(component.score) 分 · 权重 \(Int(component.weight * 100))%")
                                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            }
                                            ProgressView(value: Double(component.score), total: 100)
                                                .tint(component.score >= 80 ? SnowSkin.green : (component.score >= 60 ? SnowSkin.orange : SnowSkin.danger))
                                            Text(component.detail).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Divider()
                                    Text("建议").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    ForEach(Array(healthAdvice.enumerated()), id: \.offset) { _, advice in
                                        HStack(alignment: .top, spacing: 10) {
                                            Image(systemName: "arrow.right.circle.fill")
                                                .foregroundStyle(SnowSkin.accent).font(.caption).padding(.top, 2)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(advice.title).font(.callout.weight(.medium))
                                                Text(advice.detail).font(.caption).foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            Spacer(minLength: 8)
                                            Button("去\(advice.section)") { selection = advice.section }
                                                .buttonStyle(.link)
                                        }
                                    }
                                }
                                .padding(.top, 8)
                            } label: {
                                Text("评分明细与建议").font(.callout.weight(.medium))
                            }
                        }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                    GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricTile(title: "磁盘可用",
                               value: monitor.disk.map { SystemMetrics.bytesText($0.freeBytes) } ?? "读不到",
                               foot: monitor.disk.map { "共 " + SystemMetrics.bytesText($0.totalBytes) } ?? "未取到磁盘信息",
                               color: SnowSkin.accent)
                    MetricTile(title: "内存压力",
                               value: monitor.memory?.pressureLabel ?? "读不到",
                               foot: monitor.memory.map {
                                   SystemMetrics.bytesText($0.usedBytes) + " / " + SystemMetrics.bytesText($0.totalBytes)
                               } ?? "未取到内存信息",
                               color: pressureTint(monitor.memory?.usedFraction))
                    MetricTile(title: "电池健康",
                               value: monitor.battery?.healthPercent.map { "\(Int($0))%" } ?? "读不到",
                               foot: monitor.battery?.cycleCount.map { "循环 \($0) 次" } ?? "无电池或读不到",
                               color: SnowSkin.green)
                    MetricTile(title: "连接中的外设",
                               value: "\(monitor.bluetooth.filter(\.connected).count) 个",
                               foot: lowBatteryText,
                               color: SnowSkin.accent)
                }

                observationCard

                Text("快捷入口").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                    GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    QuickEntry(title: "清理垃圾", subtitle: model.report.map { "\($0.verdicts.count) 个候选" } ?? "还没扫描",
                               icon: "trash", color: SnowSkin.green) { selection = "清理" }
                    QuickEntry(title: "电池健康", subtitle: "容量与循环次数", icon: "battery.75", color: SnowSkin.accent) { selection = "电池健康" }
                    QuickEntry(title: "我的外设", subtitle: "鼠标键盘耳机", icon: "dot.radiowaves.left.and.right", color: SnowSkin.orange) { selection = "蓝牙外设" }
                    QuickEntry(title: "空间分析", subtitle: "哪里占得最多", icon: "chart.bar.xaxis", color: SnowSkin.accent) { selection = "空间分析" }
                }

                HStack {
                    Text("最近做了什么").font(.headline)
                    Text("每次操作都有本地记录，可追溯").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("打开操作历史") { selection = "操作历史" }.buttonStyle(.link)
                }

                ModuleCard {
                    if monitor.auditEvents.isEmpty {
                        Text(monitor.auditLoaded ? "还没有任何清理记录。第一次清理后，这里会出现可回查的条目。"
                                                  : "正在读取本地审计日志…")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(monitor.auditEvents.prefix(4), id: \.id) { event in
                                HStack(spacing: 10) {
                                    Circle().fill(event.success ? SnowSkin.green : SnowSkin.orange).frame(width: 7, height: 7)
                                    Text(SystemMetrics.actionText(event.action)).font(.callout)
                                    Text((event.path as NSString).lastPathComponent)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Text(event.sizeBytes > 0 ? SystemMetrics.bytesText(event.sizeBytes) : "—")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(event.at.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .task {
            await monitor.refreshDashboard()
            if !monitor.auditLoaded { await monitor.refreshAudit() }
            dailySummaries = (try? DailyJournal().summaries(days: 7)) ?? []
        }
    }

    private var localFacts: LocalObservationFacts {
        LocalObservationFactsBuilder.build(
            report: model.report,
            diskFreeBytes: monitor.disk?.freeBytes,
            diskTotalBytes: monitor.disk?.totalBytes,
            summaries: dailySummaries
        )
    }

    private var localModelReady: Bool {
        provider.route == .local3B && provider.configuration.localIsConfigured
    }

    private var observationCard: some View {
        let facts = localFacts
        return ModuleCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "eye.fill")
                        .font(.title3)
                        .foregroundStyle(SnowSkin.accent)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本机观察").font(.headline)
                        Text("日常只记只读数字；点一下才唤醒本地 4B，模型不进入删除判断。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if localModelReady {
                        Button {
                            runObservation()
                        } label: {
                            if isObserving {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("观察中")
                                }
                            } else {
                                Text("让本地模型观察")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isObserving)
                    } else {
                        Button("去设置本地模型") { selection = "设置" }
                    }
                }

                HStack(spacing: 18) {
                    observationFact(
                        title: "当前可用",
                        value: monitor.disk.map { SystemMetrics.bytesText($0.freeBytes) } ?? "读不到"
                    )
                    observationFact(
                        title: "日常趋势",
                        value: trendText(facts)
                    )
                    observationFact(
                        title: "最近扫描",
                        value: model.report.map { "\($0.verdicts.count) 项 · \($0.scanGaps.count) 缺口" } ?? "还没扫描"
                    )
                }

                if isObserving {
                    Text("正在启动本地模型；首次加载约 2.4 GB，之后的观察会快很多。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let failure = observationFailure {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(SnowSkin.orange).font(.caption)
                        Text(failure).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let report = observationReport {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.headline).font(.callout.weight(.semibold))
                        if !report.summary.isEmpty {
                            Text(report.summary).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(report.findings) { finding in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(observationTint(finding.level))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(finding.title).font(.callout.weight(.medium))
                                        Text(finding.levelText)
                                            .font(.caption2)
                                            .foregroundStyle(observationTint(finding.level))
                                    }
                                    Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    let evidenceText = finding.evidence
                                        .compactMap { observationEvidence[$0] }
                                        .joined(separator: " · ")
                                    if !evidenceText.isEmpty {
                                        Text("依据：\(evidenceText)")
                                            .font(.caption2).foregroundStyle(.tertiary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        if let capturedAt = observationCapturedAt {
                            Text("观察采样于 \(capturedAt.formatted(date: .omitted, time: .shortened))；上面的「当前可用」是实时值，和采样数字可能有差异。")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("本机模型只读观察 · prompt \(report.promptVersion) · 不参与规则判定")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else if dailySummaries.isEmpty {
                    Text("日常记录还没有样本。到设置打开「日常记录」后，雪会定期记下磁盘可用空间；只在本机，不上传。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("只读事实已经准备好。点「让本地模型观察」才会加载模型；不点就不占内存。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func observationFact(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit()).lineLimit(1)
        }
    }

    private func trendText(_ facts: LocalObservationFacts) -> String {
        guard facts.trendDays >= 2,
              let start = facts.trendStartBytes,
              let end = facts.trendEndBytes
        else { return facts.trendDays == 0 ? "还没有日常样本" : "样本还不够" }
        let delta = end - start
        if delta == 0 { return "近 \(facts.trendDays) 天没有变化" }
        return delta > 0
            ? "近 \(facts.trendDays) 天 +\(SystemMetrics.bytesText(delta))"
            : "近 \(facts.trendDays) 天 -\(SystemMetrics.bytesText(-delta))"
    }

    private func observationTint(_ level: LocalObservationFinding.Level) -> Color {
        switch level {
        case .attention: return SnowSkin.orange
        case .note: return SnowSkin.accent
        case .ok: return SnowSkin.green
        }
    }

    private func runObservation() {
        let configuration = provider.configuration
        guard configuration.route == .local3B else {
            observationFailure = "先把模型接入切到「本地小模型」，再让模型观察。"
            return
        }
        guard configuration.localIsConfigured else {
            observationFailure = "本地小模型还没配置完整；到设置填好 llama-server 和 GGUF 权重。"
            return
        }
        let facts = localFacts
        guard facts.hasEnoughFacts else {
            observationFailure = "现在还没有足够的只读事实；先做一次体检或打开日常记录。"
            return
        }

        isObserving = true
        observationFailure = nil
        observationReport = nil
        observationCapturedAt = facts.capturedAt
        Task {
            do {
                let response = try await ModelHostClient.shared.observe(
                    ModelHostObservationRequest(facts: facts, configuration: configuration)
                )
                if let report = response.report {
                    observationReport = report
                    observationEvidence = Dictionary(
                        uniqueKeysWithValues: facts.evidence.map { ($0.id, "\($0.label) \($0.value)") }
                    )
                    provider.noteRequestSuccess()
                } else {
                    let message = response.failure ?? "本地模型没有返回观察结果。"
                    observationFailure = message
                    provider.noteRequestFailure(message)
                }
            } catch {
                observationFailure = error.localizedDescription
                provider.noteRequestFailure(error.localizedDescription)
            }
            isObserving = false
        }
    }

    private var diskSummary: String {
        guard let disk = monitor.disk else { return "正在读取磁盘信息…" }
        let free = SystemMetrics.bytesText(disk.freeBytes)
        if let report = model.report {
            return "磁盘剩余 \(free)。上次扫描得到 \(report.verdicts.count) 个候选，\(report.scanGaps.count) 个缺口。"
        }
        return "磁盘剩余 \(free)。还没扫描，点右上角「立即体检」开始。"
    }

    private var lowBatteryText: String {
        if monitor.bluetooth.isEmpty { return "正在读取蓝牙外设…" }
        let connected = monitor.bluetooth.filter(\.connected)
        if connected.isEmpty { return "已配对 \(monitor.bluetooth.count) 个，当前都没连接" }
        let low = connected.filter { ($0.battery ?? 100) < 20 }
        return low.isEmpty ? "已连接 \(connected.count) 个，电量都还够用" : "\(low.count) 个电量偏低"
    }
}

private struct QuickEntry: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 38, height: 38)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 空间分析

struct AnalyzeView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var model: ScanViewModel
    @StateObject private var browser = SpaceBrowserModel()
    @StateObject private var timeline = SpaceTimelineModel()
    @State private var showTimeline = false
    @State private var selectedNote: SpaceFileNote?
    @State private var selectedNotePath = ""
    @State private var selectedNoteFullPath = ""
    @State private var selectedNoteIsDirectory = false
    @State private var externalVolumes: [ExternalVolumeSnapshot] = []
    @State private var deletePrompt: ManualDeletionPrompt?
    @State private var deleteNotice: String?
    @State private var deleteNoticeIsError = false
    @State private var showAdvice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            spaceHeader
            spaceToolbar

            if let deleteNotice {
                InfoBanner(text: deleteNotice, color: deleteNoticeIsError ? .red : .green)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
            }

            if monitor.isAnalyzing || browser.isLoading || browser.partialCount > 0 {
                spaceStatusStrip
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
            }

            GeometryReader { geo in
                HStack(alignment: .top, spacing: 12) {
                    spaceCanvas
                    spaceRail(width: geo.size.width < 1_080 ? 286 : 334)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
        }
        .task {
            refreshExternalVolumes()
            if monitor.slices.isEmpty && !monitor.isAnalyzing { await monitor.analyzeSpace() }
            browser.reset(slices: monitor.slices)
            await timeline.refresh()
            if !monitor.slices.isEmpty {
                await timeline.recordIfNeeded(slices: monitor.slices, disk: monitor.disk)
            }
        }
        .onChange(of: browser.selectedID) { _, id in
            guard let id,
                  let node = browser.nodes.first(where: { $0.id == id && !$0.isAggregate }) else {
                selectedNote = nil
                selectedNotePath = ""
                selectedNoteFullPath = ""
                return
            }
            selectedNote = makeSpaceFileNote(for: node)
            selectedNotePath = (node.path as NSString).abbreviatingWithTildeInPath
            selectedNoteFullPath = node.path
            selectedNoteIsDirectory = node.isDirectory
        }
        .onDisappear { browser.cancel() }
        .manualDeletionSheet(prompt: $deletePrompt) { result in
            switch result {
            case let .success(count):
                deleteNoticeIsError = false
                deleteNotice = "已将 \(count) 项移到废纸篓，并重新统计当前目录。"
                browser.reloadCurrentLayer()
                Task { await monitor.refreshBigFiles() }
            case let .failure(error):
                deleteNoticeIsError = true
                deleteNotice = error.localizedDescription
            }
        }
        .sheet(isPresented: $browser.showOther) {
            SpaceOtherSheet(items: browser.sheetNodes) { node in
                browser.open(node)
                browser.showOther = false
            }
        }
        .sheet(isPresented: $showTimeline) {
            SpaceTimelineSheet(model: timeline, onCapture: {
                await monitor.analyzeSpace()
                browser.reset(slices: monitor.slices)
                await timeline.record(slices: monitor.slices, disk: monitor.disk,
                                        source: "manual", force: true)
            })
        }
    }

    private var spaceHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("空间分析")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(0.2)
                Text(analyzeShortSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if monitor.isAnalyzing || browser.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                showTimeline = true
            } label: {
                Label("时间线", systemImage: "clock.arrow.circlepath")
            }
            .help("查看两次快照之间的空间变化，不执行删除")
            Button("重新分析") {
                if browser.isExternal || browser.isSystem {
                    browser.reloadCurrentLayer()
                } else {
                    Task {
                        await monitor.analyzeSpace()
                        browser.reset(slices: monitor.slices)
                        await timeline.recordIfNeeded(slices: monitor.slices, disk: monitor.disk)
                    }
                }
            }
            .disabled(monitor.isAnalyzing || browser.isLoading)
            .help("重新读取当前位置；不会删除任何文件")
            Button {
                exportReport()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(browser.nodes.isEmpty && monitor.slices.isEmpty)
            .help("导出当前空间报告")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var spaceToolbar: some View {
        HStack(spacing: 7) {
            Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(!browser.canGoBack)
                .help("后退")
            Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).disabled(!browser.canGoForward)
                .help("前进")
            Button { browser.goUp() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless).disabled(!browser.canGoUp)
                .help("上一级")

            Divider().frame(height: 18).padding(.horizontal, 3)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    rootChip(
                        name: "家目录",
                        detail: "内置盘 · 只读",
                        icon: "house",
                        selected: !browser.isExternal && !browser.isSystem
                    ) {
                        browser.reset(slices: monitor.slices)
                    }
                    rootChip(
                        name: "系统盘",
                        detail: "/ · 只读判读",
                        icon: "internaldrive",
                        selected: browser.isSystem
                    ) {
                        browser.showSystemRoot()
                    }
                    ForEach(externalVolumes) { volume in
                        rootChip(
                            name: volume.name,
                            detail: "\(volume.isReadOnly ? "只读 · " : "")可用 \(SystemMetrics.bytesText(volume.freeBytes))",
                            icon: "externaldrive",
                            selected: browser.rootPath == volume.path
                        ) {
                            browser.showExternalVolume(path: volume.path, name: volume.name)
                        }
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)

            Spacer(minLength: 8)
            Button {
                refreshExternalVolumes()
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }
            .buttonStyle(.borderless)
            .help("重新检测外置盘；不会扫描磁盘内容")
            Text("\(browser.nodes.count) 项 · \(SystemMetrics.bytesText(browser.totalBytes))")
                .font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .help("当前一层已统计的条目数与合计体积")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    private var analyzeShortSubtitle: String {
        if browser.isSystem {
            return browser.isAtRoot
                ? "系统盘 · 只读判读 · 方块面积就是占用，点方块进入下一层"
                : "系统位置 · 只读 · \(browser.displayPath)"
        }
        if browser.isExternal {
            return "外置盘「\(browser.rootName)」· 只读 · 方块面积就是占用"
        }
        return browser.isHome
            ? "只读 · 方块面积就是占用，点方块进入下一层"
            : "只读 · \(browser.displayPath)"
    }

    private var spaceStatusStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            if monitor.isAnalyzing {
                statusLine(monitor.analyzeNote)
            } else if browser.isLoading {
                statusLine(browser.isSystem && browser.isAtRoot
                           ? "正在只读统计 11 个系统位置，通常需要十几秒…"
                           : "正在统计「\(browser.displayName)」的当前一层…")
            }
            if browser.partialCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(browser.isSystem
                         ? "\(browser.partialCount) 个位置 45 秒没读完，合计会偏小：\(browser.partialNames.prefix(4).joined(separator: "、"))\(browser.partialCount > 4 ? " 等" : "")"
                         : "\(browser.partialCount) 个目录这次没读回体积，合计会偏小：\(browser.partialNames.prefix(4).joined(separator: "、"))\(browser.partialCount > 4 ? " 等" : "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 6)
                    Button("重试") { browser.reloadCurrentLayer() }
                        .controlSize(.small)
                    if browser.isSystem {
                        Button("权限体检") { AppWindow.showMain(section: "权限") }
                            .controlSize(.small)
                    } else if !browser.isExternal {
                        Button("系统设置") { model.openFullDiskAccessSettings() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var spaceCanvas: some View {
        ModuleCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                spaceBreadcrumbs
                Divider()
                ZStack {
                    TreemapView(
                        nodes: browser.treeNodes,
                        selectedID: browser.selectedID,
                        hoveredID: browser.hoveredID,
                        onOpen: { browser.open($0) },
                        onSelect: { browser.select($0) },
                        onHover: { browser.hover($0) }
                    )
                    if browser.nodes.isEmpty {
                        emptySpaceState.padding(18)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
                HStack(spacing: 10) {
                    Text("点方块进入目录；右键可在 Finder 中显示")
                    Spacer()
                    if browser.isSystem { Text("系统位置只读") }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var spaceBreadcrumbs: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(browser.crumbs.enumerated()), id: \.element.id) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Button {
                            browser.jump(to: crumb.path)
                        } label: {
                            Text(crumb.name)
                                .font(index == browser.crumbs.count - 1 ? .callout.weight(.semibold) : .callout)
                                .foregroundStyle(index == browser.crumbs.count - 1 ? Color.primary : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(SystemMetrics.bytesText(browser.totalBytes))
                .font(.callout.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var canDeleteSelected: Bool {
        !browser.isExternal && !browser.isSystem && !selectedNoteIsDirectory
    }

    private func spaceRail(width: CGFloat) -> some View {
        SpaceRailView(
            browser: browser,
            timeline: timeline,
            width: width,
            selectedNote: selectedNote,
            selectedNotePath: selectedNotePath,
            selectedNoteFullPath: selectedNoteFullPath,
            canDeleteSelected: canDeleteSelected,
            onRequestDelete: requestDeleteSelectedNote,
            onOpenTimeline: { showTimeline = true }
        )
    }

    @ViewBuilder
    private var browserSection: some View {
        if !browser.nodes.isEmpty {
            SpaceAdviceCard(nodes: browser.nodes, isExternal: browser.isExternal, isSystem: browser.isSystem)
        }

        if browser.nodes.isEmpty {
            emptySpaceState
        } else {
            DirectoryOverviewCard(
                browser: browser,
                selectedNote: selectedNote,
                selectedNotePath: selectedNotePath,
                selectedNoteFullPath: selectedNoteFullPath,
                selectedNoteIsDirectory: selectedNoteIsDirectory,
                canDeleteSelected: !browser.isExternal && !browser.isSystem && !selectedNoteIsDirectory,
                onDeleteSelected: requestDeleteSelectedNote
            )
        }
    }

    @ViewBuilder
    private var emptySpaceState: some View {
        if let errorText = browser.errorText, !browser.isLoading {
            InfoBanner(text: errorText, color: .orange)
            if errorText.contains("没有权限读取") {
                Button("打开「文件与文件夹」设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } else if !monitor.isAnalyzing && !browser.isLoading {
            IfEmptyState(isHome: browser.isHome)
        }
    }

    @ViewBuilder
    private var detailGridSection: some View {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 14),
                        GridItem(.flexible())
                    ],
                    alignment: .leading,
                    spacing: 14
                ) {
                    ModuleCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("当前目录明细").font(.headline)
                                Spacer()
                                if browser.hiddenCount > 0 {
                                    Text("另有 \(browser.hiddenCount) 项较小内容").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if browser.nodes.isEmpty {
                                Text(browser.isLoading ? "正在统计…" : "等待分析").font(.caption).foregroundStyle(.secondary)
                            } else {
                                ScrollView(.vertical, showsIndicators: true) {
                                    LazyVStack(spacing: 2) {
                                        ForEach(browser.listNodes) { node in
                                            Button {
                                                browser.open(node)
                                            } label: {
                                                HStack(spacing: 8) {
                                                    Circle().fill(treemapColor(browser.treeNodes.firstIndex(where: { $0.id == node.id }) ?? 0))
                                                        .frame(width: 8, height: 8)
                                                    Image(systemName: node.isDirectory ? "folder" : "doc")
                                                        .font(.caption2).foregroundStyle(.secondary)
                                                    VStack(alignment: .leading, spacing: 0) {
                                                        Text(node.isAggregate ? node.name : folderCN(node.name)).font(.callout)
                                                        HStack(spacing: 5) {
                                                            Text(node.path)
                                                                .font(.caption2).foregroundStyle(.secondary)
                                                                .lineLimit(1)
                                                            if node.category != "未判读" {
                                                                Text("\(node.category) · \(node.risk)")
                                                                    .font(.caption2.weight(.semibold))
                                                                    .foregroundStyle(node.risk == "高" || node.risk == "只读" ? .red : .orange)
                                                            }
                                                        }
                                                    }
                                                    Spacer()
                                                    Text(node.isPartial ? "读不到" : SystemMetrics.bytesText(node.bytes))
                                                        .font(.caption.monospacedDigit())
                                                        .foregroundStyle(node.isPartial ? .secondary : .primary)
                                                }
                                                .padding(.vertical, 3)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .background(node.id == browser.selectedID ? Color.blue.opacity(0.08) : Color.clear)
                                            .id(node.id)
                                        }
                                    }
                                }
                                .scrollPosition(id: $browser.listAnchor)
                                .frame(maxHeight: 300)
                                if browser.hiddenCount > 0 {
                                    Button {
                                        browser.showOther = true
                                    } label: {
                                        Text("查看完整列表（\(browser.otherCount) 项）").font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if browser.isExternal {
                        externalVolumeSummaryCard
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if browser.isSystem {
                        systemSummaryCard
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ModuleCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("最大的文件").font(.headline)
                                Text("100 MB 以上，按体积排序").font(.caption).foregroundStyle(.secondary)
                                if monitor.bigFiles.isEmpty {
                                    Text(monitor.bigFilesTimedOut
                                         ? "扫描超时：家目录里有目录没有响应，已跳过。空间分析仍可逐层查看可读目录。"
                                         : (monitor.isAnalyzing ? "正在查找 100 MB 以上的文件…" : "没有找到 100 MB 以上的文件，或还没分析。"))
                                        .font(.caption).foregroundStyle(monitor.bigFilesTimedOut ? .orange : .secondary)
                                } else {
                                    ForEach(monitor.bigFiles.prefix(10)) { file in
                                        Button {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                                        } label: {
                                            HStack(spacing: 8) {
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text((file.path as NSString).lastPathComponent)
                                                        .font(.callout).lineLimit(1)
                                                    Text(NSString(string: (file.path as NSString).deletingLastPathComponent).abbreviatingWithTildeInPath)
                                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                                }
                                                Spacer()
                                                Text(SystemMetrics.bytesText(file.bytes)).font(.caption.monospacedDigit())
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
    }

    private func requestDeleteSelectedNote() {
        guard !browser.isExternal, !browser.isSystem, !selectedNoteFullPath.isEmpty, !selectedNoteIsDirectory else { return }
        let check = model.manualProtectionCheck
        let path = selectedNoteFullPath
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                () -> Result<ManualDeletionPlan, Error> in
                let service = ManualDeletionService(protectionCheck: check)
                do {
                    return .success(try service.preview(path: path, reason: "空间分析选中文件"))
                } catch {
                    return .failure(error)
                }
            }.value
            await MainActor.run {
                switch result {
                case let .success(plan):
                    deletePrompt = ManualDeletionPrompt(
                        plans: [plan],
                        title: "把这个文件移到废纸篓？",
                        message: "这是空间分析里当前选中的文件。请先确认它不是项目正在引用的素材；删除只进废纸篓。",
                        source: "空间分析",
                        caution: .normal
                    )
                case let .failure(error):
                    deleteNoticeIsError = true
                    deleteNotice = error.localizedDescription
                }
            }
        }
    }

    private var analyzeSubtitle: String {
        if browser.isSystem {
            if browser.isAtRoot {
                return "系统盘：按关键位置只读统计，标出系统必需、缓存日志、应用残留、开发依赖。系统文件不提供删除。"
            }
            return "正在查看系统位置 \(browser.displayPath)。点目录继续进入；这里只读，删除建议只作为判断依据。"
        }
        if browser.isExternal {
            if browser.isAtRoot {
                return "外置盘「\(browser.rootName)」：只读统计，不删除、不改文件。方块越大占用越多，点方块进入目录。"
            }
            return "正在查看外置盘「\(browser.rootName)」的 \(browser.displayPath)。点方块继续进入，点「上一级」或面包屑返回。"
        }
        if browser.isHome {
            return "方块越大占用越多。点方块进入目录，面包屑或左右箭头返回；只读，不删除。"
        }
        return "正在查看 \(browser.displayPath)。点方块继续进入，点「上一级」或面包屑返回。"
    }

    private var analyzeRootCard: some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Label("读取位置", systemImage: "externaldrive")
                        .font(.headline)
                    Text(browser.isExternal
                         ? "当前：\(browser.rootName)（外置盘）"
                         : (browser.isSystem ? "当前：系统盘（只读）" : "当前：家目录（内置盘）"))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        refreshExternalVolumes()
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .help("重新读取当前挂载的外置盘；不会扫描磁盘内容")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        rootChip(
                            name: "家目录",
                            detail: "内置盘 · 只读",
                            icon: "house",
                            selected: !browser.isExternal && !browser.isSystem
                        ) {
                            browser.reset(slices: monitor.slices)
                        }
                        rootChip(
                            name: "系统盘",
                            detail: "/ · 只读判读",
                            icon: "internaldrive",
                            selected: browser.isSystem
                        ) {
                            browser.showSystemRoot()
                        }
                        ForEach(externalVolumes) { volume in
                            rootChip(
                                name: volume.name,
                                detail: "\(volume.isReadOnly ? "只读卷 · " : "")可用 \(SystemMetrics.bytesText(volume.freeBytes)) / \(SystemMetrics.bytesText(volume.totalBytes))",
                                icon: "externaldrive",
                                selected: browser.rootPath == volume.path
                            ) {
                                browser.showExternalVolume(path: volume.path, name: volume.name)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }

                Text(browser.isSystem
                     ? "系统盘按关键位置分组只读统计：不递归整盘、不把 Data 卷重复算一遍、不提供系统文件删除按钮。每项会标用途、风险和建议。"
                     : (externalVolumes.isEmpty
                        ? "没有检测到外置硬盘。插上后在 Finder 能看到卷，再点「重新检测」。"
                        : "外置盘只读统计：不删除、不改文件，也不进入清理判定。拔盘前先切回家目录。"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rootChip(name: String, detail: String, icon: String,
                          selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 128, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                            lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(selected ? "当前读取位置" : "切换到 \(name)（只读）")
    }

    private var systemSummaryCard: some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("系统盘只读说明").font(.headline)
                Text("这里只统计关键位置，不递归整盘，也不会把 Data 卷重复算一遍。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                summaryRow("已统计位置", "\(browser.nodes.count) 个")
                summaryRow("当前层合计", SystemMetrics.bytesText(browser.totalBytes))
                if browser.partialCount > 0 {
                    Text("\(browser.partialCount) 个位置读不到或超时，合计会偏小；明细里标「读不到」。")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("系统必需项没有删除按钮；缓存、日志和应用残留只给判断依据。需要 root 的删除动作，雪不会替你提权执行。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var externalVolumeSummaryCard: some View {
        let volume = externalVolumes.first { $0.path == browser.rootPath }
        return ModuleCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("外置盘概览").font(.headline)
                Text("\(browser.rootName) · 只读统计，不删除、不改文件")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let volume {
                    summaryRow("总容量", SystemMetrics.bytesText(volume.totalBytes))
                    summaryRow("可用空间", SystemMetrics.bytesText(volume.freeBytes))
                    summaryRow("已用空间", SystemMetrics.bytesText(volume.usedBytes))
                } else {
                    summaryRow("总容量", "未读到")
                    summaryRow("可用空间", "未读到")
                    summaryRow("已用空间", "未读到")
                }
                summaryRow("当前层已统计", SystemMetrics.bytesText(browser.totalBytes))

                if browser.isAtRoot, let volume {
                    let missing = volume.usedBytes - browser.totalBytes
                    if missing > 200_000_000 {
                        Text("另有 \(SystemMetrics.bytesText(missing)) 未计入：系统元数据、隐藏项或读不到的目录。")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if browser.partialCount > 0 {
                    Text("有 \(browser.partialCount) 个目录没读完，数字可能偏小；明细里标「读不到」。")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(volume?.isReadOnly == true
                     ? "这个卷本身是只读的；雪也只读，不尝试挂载写入。"
                     : "雪只读取目录与文件体积；清理页不处理外置盘。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private func refreshExternalVolumes() {
        externalVolumes = SystemMetrics.externalVolumes()
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "雪-空间分析-\(Date().formatted(date: .numeric, time: .omitted)).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = "# 雪空间分析\n\n生成时间：\(Date().formatted())\n\n## 当前目录：\(browser.displayPath)\n\n"
        for node in browser.nodes {
            text += "- \(node.isDirectory ? "[目录]" : "[文件]") \(node.name)：\(SystemMetrics.bytesText(node.bytes))（\(node.path)）\n"
        }
        text += "\n## 最大的文件\n\n"
        if browser.isExternal {
            text += "外置盘只读统计，本报告不扫描家目录大文件。\n"
        } else {
            for file in monitor.bigFiles {
                text += "- \(SystemMetrics.bytesText(file.bytes))　\(file.path)\n"
            }
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// 当前目录总览与明细列表。列表滚动锚点按目录保存，进入子目录再返回时不跳回顶部。
private struct DirectoryOverviewCard: View {
    @ObservedObject var browser: SpaceBrowserModel
    let selectedNote: SpaceFileNote?
    let selectedNotePath: String
    let selectedNoteFullPath: String
    let selectedNoteIsDirectory: Bool
    let canDeleteSelected: Bool
    let onDeleteSelected: () -> Void

    var body: some View {
        ModuleCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                navigationHeader
                breadcrumbs
                TreemapView(
                    nodes: browser.treeNodes,
                    selectedID: browser.selectedID,
                    hoveredID: browser.hoveredID,
                    onOpen: { browser.open($0) },
                    onSelect: { browser.select($0) },
                    onHover: { browser.hover($0) }
                )
                .frame(height: 330)
                .padding([.horizontal, .bottom], 12)

                if let note = selectedNote {
                    Divider().padding(.horizontal, 14)
                    SpaceFileNoteCard(
                        note: note,
                        path: selectedNotePath,
                        onReveal: {
                            guard !selectedNoteFullPath.isEmpty else { return }
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: selectedNoteFullPath)
                            ])
                        },
                        onGoFamily: { AppWindow.showMain(section: "族谱") },
                        onGoClean: (browser.isExternal || browser.isSystem)
                            ? nil
                            : { AppWindow.showMain(section: "清理") },
                        onDelete: canDeleteSelected ? onDeleteSelected : nil
                    )
                    .padding(14)
                }

                legend
            }
        }
    }

    private var navigationHeader: some View {
        HStack(spacing: 8) {
            Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(!browser.canGoBack)
            Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).disabled(!browser.canGoForward)
            Button { browser.goUp() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless).disabled(!browser.canGoUp).help("返回上一级")
            Text(browser.displayName).font(.headline)
            Text(browser.displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(SystemMetrics.bytesText(browser.totalBytes))
                .font(.callout.weight(.semibold))
        }
        .padding(14)
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(browser.crumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button {
                        browser.jump(to: crumb.path)
                    } label: {
                        Text(crumb.name)
                            .font(index == browser.crumbs.count - 1 ? .caption.weight(.semibold) : .caption)
                            .foregroundStyle(index == browser.crumbs.count - 1 ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 8)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(Array(browser.treeNodes.prefix(6).enumerated()), id: \.element.id) { index, node in
                HStack(spacing: 4) {
                    Circle().fill(treemapColor(index)).frame(width: 7, height: 7)
                    Text(node.isAggregate ? node.name : folderCN(node.name))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(browser.isSystem ? "系统位置只读 · 每个目录标用途与风险"
                 : (browser.isExternal ? "外置盘只读 · 右键在 Finder 中显示" : "只读总览 · 右键在 Finder 中显示"))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }
}

private struct IfEmptyState: View {
    let isHome: Bool

    var body: some View {
        if isHome {
            InfoBanner(text: "还没有分析结果。点「重新分析」会分别统计桌面、文稿、下载、资源库、影片、音乐、图片等目录的真实体积；只读，不删除任何文件。",
                       color: .blue)
        } else {
            InfoBanner(text: "这个目录没有可显示的子项，可能为空、没有权限，或只有隐藏的符号链接。",
                       color: .gray)
        }
    }
}

private struct SpaceRailView: View {
    @ObservedObject var browser: SpaceBrowserModel
    @ObservedObject var timeline: SpaceTimelineModel
    let width: CGFloat
    let selectedNote: SpaceFileNote?
    let selectedNotePath: String
    let selectedNoteFullPath: String
    let canDeleteSelected: Bool
    let onRequestDelete: () -> Void
    let onOpenTimeline: () -> Void
    @State private var showAdvice = false

    var body: some View {
        VStack(spacing: 10) {
            listCard
            SpaceTimelineSummaryCard(model: timeline, onOpen: onOpenTimeline)
            if let note = selectedNote {
                SpaceFileNoteCard(
                    note: note,
                    path: selectedNotePath,
                    onReveal: {
                        guard !selectedNoteFullPath.isEmpty else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: selectedNoteFullPath)
                        ])
                    },
                    onGoFamily: { AppWindow.showMain(section: "族谱") },
                    onGoClean: (browser.isExternal || browser.isSystem)
                        ? nil
                        : { AppWindow.showMain(section: "清理") },
                    onDelete: canDeleteSelected ? onRequestDelete : nil
                )
                .frame(maxHeight: 220)
            }
            adviceCard
        }
        .frame(width: width)
    }

    private var listCard: some View {
        ModuleCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("本层目录").font(.headline)
                    Spacer()
                    Text("\(browser.nodes.count) 项")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                Divider()
                listBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var listBody: some View {
        if browser.nodes.isEmpty {
            Text(browser.isLoading ? "正在统计…" : "还没有可显示的子项。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(browser.listNodes) { node in
                        row(node)
                        Divider().padding(.leading, 30)
                    }
                }
            }
            .scrollPosition(id: $browser.listAnchor)
            if browser.hiddenCount > 0 {
                Button {
                    browser.showOther = true
                } label: {
                    Text("查看完整列表（\(browser.otherCount) 项）")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 13).padding(.vertical, 8)
            }
        }
    }

    private func row(_ node: SpaceNode) -> some View {
        Button {
            if node.isDirectory || node.isAggregate {
                browser.open(node)
            } else {
                browser.select(node)
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(rowColor(node))
                    .frame(width: 5, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.isAggregate ? node.name : folderCN(node.name))
                        .font(.callout)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if node.category != "未判读" {
                            Text(node.category).foregroundStyle(categoryColor(node.category))
                            if node.risk == "高" || node.risk == "只读" {
                                Text(node.risk).foregroundStyle(.red)
                            } else if node.risk == "中" {
                                Text(node.risk).foregroundStyle(.orange)
                            }
                        } else {
                            Text(node.path).lineLimit(1)
                        }
                    }
                    .font(.caption2)
                }
                Spacer(minLength: 6)
                Text(node.isPartial ? "读不到" : SystemMetrics.bytesText(node.bytes))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(node.isPartial ? .secondary : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(node.id == browser.selectedID ? Color.accentColor.opacity(0.10) : Color.clear)
        .help(node.path)
    }

    private func rowColor(_ node: SpaceNode) -> Color {
        if node.isDirectory {
            let index = browser.treeNodes.firstIndex(where: { $0.id == node.id }) ?? 0
            return treemapColor(index).opacity(0.8)
        }
        return Color.secondary.opacity(0.35)
    }

    private func categoryColor(_ category: String) -> Color {
        if category == "系统必需" || category == "后台服务" { return .red }
        if category == "缓存与日志" || category == "日志" || category == "应用共享数据" { return .orange }
        if category == "应用程序" || category == "共享资源库" || category == "开发依赖" { return .blue }
        return .secondary
    }

    private var adviceCard: some View {
        ModuleCard(padding: 0) {
            DisclosureGroup(isExpanded: $showAdvice) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(adviceNodes) { node in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(treemapColor(browser.treeNodes.firstIndex(where: { $0.id == node.id }) ?? 0))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(folderCN(node.name)).font(.caption.weight(.semibold)).lineLimit(1)
                                if browser.isSystem, !node.advice.isEmpty {
                                    Text(node.advice).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                } else {
                                    Text(node.category).font(.caption2).foregroundStyle(categoryColor(node.category))
                                }
                            }
                            Spacer(minLength: 6)
                            Text(SystemMetrics.bytesText(node.bytes))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "lightbulb").foregroundStyle(.orange)
                    Text(browser.isSystem ? "系统盘判读建议" : "下一步建议")
                        .font(.callout.weight(.medium))
                    Spacer()
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
        }
    }

    private var adviceNodes: [SpaceNode] {
        if browser.isSystem {
            let actionable = browser.nodes.filter {
                ["共享资源库", "应用程序", "缓存与日志", "日志", "应用共享数据", "开发依赖", "未判读"].contains($0.category)
            }
            return Array((actionable.isEmpty ? browser.nodes : actionable).prefix(4))
        }
        return Array(browser.nodes.filter { !$0.isAggregate }.prefix(3))
    }
}

struct SpaceCrumb: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    var id: String { path }
}

/// 空间分析扫完后的可执行建议：不要求用户先点中某个文件，
/// 直接按当前层最大的几项给出“下一步去哪儿”。
@MainActor
struct SpaceAdviceCard: View {
    let nodes: [SpaceNode]
    var isExternal: Bool = false
    var isSystem: Bool = false

    private var top: [SpaceNode] {
        if isSystem {
            let actionable = nodes.filter {
                ["共享资源库", "应用程序", "缓存与日志", "日志", "应用共享数据", "开发依赖", "未判读"].contains($0.category)
            }
            if !actionable.isEmpty { return Array(actionable.prefix(4)) }
        }
        return Array(nodes.filter { !$0.isAggregate }.prefix(3))
    }

    var body: some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.orange)
                    Text(isSystem ? "系统盘判读建议" : "下一步建议").font(.headline)
                    Spacer()
                    Text(isExternal ? "外置盘只读，不进清理"
                         : (isSystem ? "只读查看，不替系统删" : "只给入口，不替你删"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                ForEach(top) { node in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folderCN(node.name))
                                .font(.callout.weight(.semibold))
                                .lineLimit(2)
                            Text(node.category)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(categoryColor(node.category))
                        }
                        .frame(width: 132, alignment: .leading)
                        Text(SystemMetrics.bytesText(node.bytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 78, alignment: .trailing)
                        Text(advice(for: node))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }

                if isExternal {
                    Text("这里只做占用排行；清理页只处理本机固定目录，不会动外置盘。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineSpacing(2)
                } else if isSystem {
                    Text("系统盘只读：系统必需项不提供删除；缓存、日志、应用残留只给建议，优先用对应软件自己的卸载/清理。真正删除前请确认归属和备份。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineSpacing(2)
                    HStack(spacing: 8) {
                        Button("看权限清单") { AppWindow.showMain(section: "权限") }
                            .buttonStyle(.borderedProminent)
                        Button("看软件归属") { AppWindow.showMain(section: "族谱") }
                        Button("看扫描缺口") { AppWindow.showMain(section: "缺口") }
                        Spacer()
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("按「正常」看清理建议") { AppWindow.showMain(section: "清理") }
                            .buttonStyle(.borderedProminent)
                        Button("核对大文件与重复") { AppWindow.showMain(section: "大文件") }
                        Button("看软件归属") { AppWindow.showMain(section: "族谱") }
                        Spacer()
                    }
                }
            }
        }
    }

    private func categoryColor(_ category: String) -> Color {
        if category == "系统必需" || category == "后台服务" { return .red }
        if category == "缓存与日志" || category == "日志" || category == "应用共享数据" { return .orange }
        if category == "开发依赖" || category == "应用程序" || category == "共享资源库" { return .blue }
        return .secondary
    }

    private func advice(for node: SpaceNode) -> String {
        if isSystem, !node.advice.isEmpty { return node.advice }
        if isExternal {
            return "进目录逐层看；外置盘只读，不进入清理判定。"
        }
        let n = node.name.lowercased()
        let path = node.path.lowercased()
        if n.contains("图片") || n.contains("影片") || n.contains("视频") || n == "pictures" || n == "movies" || path.contains("/pictures") || path.contains("/movies") {
            return "素材目录，先别整目录删；去「大文件与重复」核对重复副本和旧工程。"
        }
        if n.contains("资源库") || n == "library" || n.contains("缓存") || n.contains("cache") || n.contains("npm") || n.contains("gradle") {
            return "缓存和依赖占位，去「清理」按正常档看可清项；不确定的项会标「需确认」。"
        }
        if n.contains("下载") || n == "downloads" {
            return "旧安装包、压缩包常堆在这里；去「大文件」按时间筛，别先删正在用的。"
        }
        if n.contains("桌面") || n == "desktop" {
            return "临时素材多，先按「最近修改」挑；进目录点文件可看中文说明。"
        }
        if n.contains("文稿") || n == "documents" {
            return "工作文件为主，建议进目录看具体文件，再决定是否移动或归档。"
        }
        return "进目录逐层看；点中文件会显示「是什么、能不能删」，再决定动作。"
    }
}

@MainActor
final class SpaceBrowserModel: ObservableObject {
    enum RootKind {
        case home
        case external
        case system
    }

    @Published private(set) var currentPath: String
    @Published private(set) var rootPath: String
    @Published private(set) var rootName: String
    private(set) var rootKind: RootKind = .home
    @Published private(set) var crumbs: [SpaceCrumb] = []
    @Published private(set) var nodes: [SpaceNode] = []
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var partialCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published var selectedID: String?
    @Published var hoveredID: String?
    @Published var showOther = false
    /// 当前目录明细列表的滚动锚点。每个目录单独记，返回时恢复到原条目。
    @Published var listAnchor: String?
    /// 整页滚动锚点。进入子目录时不清零，停在哪一段就回到哪一段。
    @Published var outerAnchor: String?

    private let home: String
    private var history: [String] = []
    private var forward: [String] = []
    private var cache: [String: SpaceLayer] = [:]
    private var listAnchors: [String: String] = [:]
    private var outerAnchors: [String: String] = [:]
    private var loadTask: Task<Void, Never>?
    private var requestID = UUID()

    init() {
        let home = NSHomeDirectory()
        self.home = home
        self.rootPath = home
        self.rootName = "家目录"
        self.currentPath = home
        self.crumbs = [SpaceCrumb(name: "家目录", path: home)]
    }

    var isHome: Bool { rootKind == .home && rootPath == home && currentPath == home }
    var isExternal: Bool { rootKind == .external }
    var isSystem: Bool { rootKind == .system }
    var isAtRoot: Bool { currentPath == rootPath }
    var displayPath: String {
        (isExternal || isSystem) ? currentPath : (currentPath as NSString).abbreviatingWithTildeInPath
    }
    var displayName: String {
        currentPath == rootPath ? rootName : folderCN((currentPath as NSString).lastPathComponent)
    }
    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var canGoUp: Bool { currentPath != rootPath && currentPath.hasPrefix(rootPath + "/") }
    var partialNames: [String] {
        nodes.filter(\.isPartial).prefix(4).map { $0.isAggregate ? $0.name : folderCN($0.name) }
    }

    /// 列表最多展示 200 项；树图最多 24 项，余下合并成「其他小项」。
    var listNodes: [SpaceNode] { Array(nodes.prefix(200)) }
    var hiddenCount: Int { max(0, nodes.count - 200) }
    var otherCount: Int { max(0, nodes.count - 23) }
    var treeNodes: [SpaceNode] {
        guard nodes.count > 24 else { return nodes }
        let head = Array(nodes.prefix(23))
        let rest = nodes.dropFirst(23)
        let otherBytes = rest.reduce(0) { $0 + $1.bytes }
        return head + [SpaceNode(name: "其他小项", path: currentPath + "#other",
                                 bytes: otherBytes, isDirectory: false, isAggregate: true)]
    }
    var sheetNodes: [SpaceNode] { Array(nodes.dropFirst(23)) }

    func reset(slices: [VolumeSlice]) {
        loadTask?.cancel()
        requestID = UUID()
        rootKind = .home
        rootPath = home
        rootName = "家目录"
        currentPath = home
        history.removeAll()
        forward.removeAll()
        selectedID = nil
        hoveredID = nil
        showOther = false
        errorText = nil
        crumbs = [SpaceCrumb(name: "家目录", path: home)]
        let usable = !slices.isEmpty && !slices.contains(where: \.isPartial)
        guard usable else {
            // 概览那边的 slices 是边算边发布的，可能带着「资源库读不到」的中间结果。
            // 直接拿它填树图会把 133 GB 永久写成 85 GB，所以这里改为自己重新读一层。
            nodes = []
            totalBytes = 0
            partialCount = 0
            isLoading = false
            cache.removeAll()
            load(path: home, pushHistory: false)
            return
        }
        nodes = slices.map {
            SpaceNode(name: $0.name, path: $0.path, bytes: $0.bytes,
                      isDirectory: true, isPartial: $0.isPartial)
        }
        totalBytes = nodes.reduce(0) { $0 + $1.bytes }
        let partial = nodes.filter(\.isPartial).count
        partialCount = partial
        isLoading = false
        cache.removeAll()
        cache[home] = SpaceLayer(nodes: nodes, totalBytes: totalBytes, partialCount: partial)
    }

    /// 把扫描根切到外置卷；清空家目录历史与缓存，从卷根重新做一次只读单层统计。
    func showExternalVolume(path: String, name: String) {
        loadTask?.cancel()
        requestID = UUID()
        rootKind = .external
        rootPath = path
        rootName = name
        currentPath = path
        history.removeAll()
        forward.removeAll()
        selectedID = nil
        hoveredID = nil
        showOther = false
        errorText = nil
        crumbs = [SpaceCrumb(name: name, path: path)]
        nodes = []
        totalBytes = 0
        partialCount = 0
        isLoading = false
        cache.removeAll()
        guard FileManager.default.fileExists(atPath: path) else {
            errorText = "「\(name)」已经不在挂载列表里，可能被拔出或卸载。重新插上后点「重新检测」。"
            return
        }
        load(path: path, pushHistory: false)
    }

    /// 系统盘入口：按关键位置分组做只读统计，不把 `/` 整棵递归。
    func showSystemRoot() {
        loadTask?.cancel()
        requestID = UUID()
        rootKind = .system
        rootPath = "/"
        rootName = "系统盘"
        currentPath = "/"
        history.removeAll()
        forward.removeAll()
        selectedID = nil
        hoveredID = nil
        showOther = false
        errorText = nil
        crumbs = [SpaceCrumb(name: "系统盘", path: "/")]
        nodes = []
        totalBytes = 0
        partialCount = 0
        cache.removeAll()
        isLoading = true
        let request = UUID()
        requestID = request
        loadTask = Task { [weak self] in
            let layer = await Task.detached(priority: .utility) {
                SystemMetrics.systemSpaceLayer()
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.apply(layer, for: "/", request: request)
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard let self, self.requestID == request, self.isLoading else { return }
            self.isLoading = false
            self.errorText = "系统盘统计超过 90 秒：可能有目录被 SIP 拦住或 I/O 卡住。已显示已读到的位置，可点具体目录重试。"
        }
    }

    func reloadCurrentLayer() {
        guard rootKind == .external || rootKind == .system
                || currentPath == home || currentPath.hasPrefix(home + "/") else { return }
        if isSystem && currentPath == "/" {
            showSystemRoot()
            return
        }
        cache.removeValue(forKey: currentPath)
        load(path: currentPath, pushHistory: false)
    }

    func open(_ node: SpaceNode) {
        if node.isAggregate {
            showOther = true
            return
        }
        guard node.isDirectory else {
            selectedID = node.id
            return
        }
        load(path: node.path, pushHistory: true)
    }

    func select(_ node: SpaceNode) {
        selectedID = node.id
    }

    func hover(_ id: String?) {
        hoveredID = id
    }

    func jump(to path: String) {
        guard path != currentPath else { return }
        load(path: path, pushHistory: true)
    }

    func goBack() {
        guard let target = history.popLast() else { return }
        forward.append(currentPath)
        load(path: target, pushHistory: false)
    }

    func goForward() {
        guard let target = forward.popLast() else { return }
        history.append(currentPath)
        load(path: target, pushHistory: false)
    }

    func goUp() {
        guard canGoUp else { return }
        load(path: (currentPath as NSString).deletingLastPathComponent, pushHistory: true)
    }

    func cancel() {
        loadTask?.cancel()
        isLoading = false
    }

    private func load(path: String, pushHistory: Bool) {
        let path = (path as NSString).standardizingPath
        if !nodes.isEmpty {
            if let anchor = listAnchor {
                listAnchors[currentPath] = anchor
            } else {
                listAnchors.removeValue(forKey: currentPath)
            }
        }
        if let anchor = outerAnchor {
            outerAnchors[currentPath] = anchor
        } else {
            outerAnchors.removeValue(forKey: currentPath)
        }
        listAnchor = nil
        outerAnchor = nil
        if pushHistory {
            history.append(currentPath)
            forward.removeAll()
        }
        currentPath = path
        crumbs = makeCrumbs(for: path)
        selectedID = nil
        hoveredID = nil
        errorText = nil

        if let cached = cache[path] {
            apply(cached, for: path, request: nil)
            restoreListAnchor(for: path)
            return
        }

        loadTask?.cancel()
        nodes = []
        totalBytes = 0
        partialCount = 0
        isLoading = true
        errorText = nil
        let request = UUID()
        requestID = request
        let deepRead = self.isExternal || self.isSystem
        loadTask = Task { [weak self] in
            let layer = await Task.detached(priority: .utility) {
                if deepRead {
                    return SystemMetrics.externalSpaceLayer(of: path)
                }
                return SystemMetrics.spaceLayer(of: path)
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.apply(layer, for: path, request: request)
            self.restoreListAnchor(for: path)
        }
        // 目录枚举本身也可能卡在坏路径上（du 的超时管不到 readdir）。
        // 每个目录独立统计、单项上限 45 秒；这里只做兜底，不能比正常统计更早到。
        // 家目录 75 秒、系统位置 120 秒、外置盘 60 秒还没回来才给超时结论。
        let watchdog: UInt64 = isExternal ? 60_000_000_000 : (isSystem ? 120_000_000_000 : 75_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: watchdog)
            guard let self, self.requestID == request, self.isLoading else { return }
            self.isLoading = false
            if self.isExternal {
                // 外置盘首次读取可能停在系统授权弹窗上；保留 requestID，
                // 用户允许后结果回来仍能落进页面，不必再手动重扫。
                self.errorText = "读取「\(self.displayName)」超过 60 秒：外置盘可能休眠、接触不稳、目录树过大，或正在等待系统授权。允许后结果会自动显示，也可点「重新分析」。"
            } else if self.isSystem {
                self.errorText = "读取「\(self.displayName)」超过 120 秒：可能有目录被 SIP 拦住或 I/O 卡住。已显示已读到的内容，可点具体目录重试。"
            } else {
                self.errorText = "读取「\(self.displayName)」超时：目录没有响应，可能卡在外接盘、云盘或系统 I/O。已跳过，可稍后重试。"
                self.requestID = UUID()
            }
        }
    }

    private func apply(_ layer: SpaceLayer, for path: String, request: UUID?) {
        if let request, request != requestID { return }
        guard currentPath == path else { return }
        if layer.readError == nil {
            cache[path] = layer
        } else {
            cache.removeValue(forKey: path)
        }
        nodes = layer.nodes
        totalBytes = layer.totalBytes
        partialCount = layer.partialCount
        isLoading = false
        if let readError = layer.readError {
            errorText = readError
        } else if nodes.isEmpty {
            errorText = "这个目录没有可读子项，可能为空或没有权限。"
        } else {
            errorText = nil
        }
    }

    private func restoreListAnchor(for path: String) {
        let listTarget = listAnchors[path]
        let outerTarget = outerAnchors[path]
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentPath == path else { return }
            self.listAnchor = listTarget
            self.outerAnchor = outerTarget
        }
    }

    private func makeCrumbs(for path: String) -> [SpaceCrumb] {
        if path == rootPath {
            return [SpaceCrumb(name: rootName, path: rootPath)]
        }
        guard path.hasPrefix(rootPath + "/") else {
            return [SpaceCrumb(name: rootName, path: rootPath),
                    SpaceCrumb(name: folderCN((path as NSString).lastPathComponent), path: path)]
        }
        let relative = String(path.dropFirst(rootPath.count + 1))
        var result = [SpaceCrumb(name: rootName, path: rootPath)]
        var accumulated = rootPath
        for component in relative.split(separator: "/") {
            accumulated += "/\(component)"
            result.append(SpaceCrumb(name: folderCN(String(component)), path: accumulated))
        }
        return result
    }
}

private struct SpaceOtherSheet: View {
    let items: [SpaceNode]
    let onOpen: (SpaceNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("其他小项").font(.title3.weight(.semibold))
                    Text("树图里放不下的小项；点击目录可继续进入。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(items.count) 项").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { node in
                        Button {
                            onOpen(node)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: node.isDirectory ? "folder" : "doc")
                                    .font(.caption2).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(node.isAggregate ? node.name : folderCN(node.name)).font(.callout)
                                    Text(node.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(node.isPartial ? "读不到" : SystemMetrics.bytesText(node.bytes))
                                    .font(.caption.monospacedDigit())
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 520, height: 520)
    }
}

func treemapColor(_ index: Int) -> Color {
    let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint, .cyan, .yellow]
    return palette[index % palette.count]
}

private struct TreemapView: View {
    let nodes: [SpaceNode]
    let selectedID: String?
    let hoveredID: String?
    let onOpen: (SpaceNode) -> Void
    let onSelect: (SpaceNode) -> Void
    let onHover: (String?) -> Void

    var body: some View {
        GeometryReader { geo in
            let frames = Self.layout(Array(nodes.prefix(24)), in: CGRect(origin: .zero, size: geo.size), horizontal: true)
            ZStack(alignment: .topLeading) {
                ForEach(Array(frames.enumerated()), id: \.offset) { index, entry in
                    let active = entry.item.id == selectedID || entry.item.id == hoveredID
                    RoundedRectangle(cornerRadius: 6)
                        .fill(entry.item.isDirectory
                               ? treemapColor(index).opacity(0.72)
                               : Color.gray.opacity(0.55))
                        .overlay(
                            Group {
                                if entry.rect.width > 46 && entry.rect.height > 20 {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.item.isAggregate ? entry.item.name : folderCN(entry.item.name))
                                            .font(entry.rect.height > 52 ? .caption.weight(.medium) : .caption2.weight(.medium))
                                            .foregroundStyle(.white).lineLimit(1)
                                        if entry.rect.height > 52 && entry.rect.width > 58 {
                                            Text(entry.item.isPartial ? "读不到" : SystemMetrics.bytesText(entry.item.bytes))
                                                .font(.caption2).foregroundStyle(.white.opacity(0.85))
                                        }
                                    }
                                    .padding(entry.rect.height > 52 ? 6 : 4)
                                }
                            },
                            alignment: .topLeading
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(active ? Color.white.opacity(0.95) : Color.white.opacity(0.12),
                                        lineWidth: active ? 2 : 1)
                        )
                        .frame(width: max(4, entry.rect.width - 2), height: max(4, entry.rect.height - 2))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture {
                            if entry.item.isDirectory || entry.item.isAggregate {
                                onOpen(entry.item)
                            } else {
                                onSelect(entry.item)
                            }
                        }
                        .onHover { hovering in
                            onHover(hovering ? entry.item.id : nil)
                        }
                        .contextMenu {
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.item.path)])
                            }
                            if !entry.item.isDirectory && !entry.item.isAggregate {
                                Button("用默认应用打开") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: entry.item.path))
                                }
                            }
                        }
                        .help(entry.item.path)
                        .position(x: entry.rect.midX, y: entry.rect.midY)
                }
            }
        }
    }

    private struct Entry {
        let item: SpaceNode
        let rect: CGRect
    }

    private static func layout(_ items: [SpaceNode], in rect: CGRect, horizontal: Bool) -> [Entry] {
        guard !items.isEmpty else { return [] }
        if items.count == 1 { return [Entry(item: items[0], rect: rect)] }
        let total = items.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0 else {
            return items.map { Entry(item: $0, rect: rect) }
        }
        var accumulated = 0.0
        var splitIndex = 1
        for (index, item) in items.enumerated() {
            accumulated += Double(item.bytes)
            if accumulated >= total / 2 {
                splitIndex = max(1, index)
                break
            }
        }
        let first = Array(items[..<splitIndex])
        let second = Array(items[splitIndex...])
        let firstShare = first.reduce(0.0) { $0 + Double($1.bytes) } / total
        let firstRect: CGRect
        let secondRect: CGRect
        if horizontal {
            let width = rect.width * firstShare
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
            secondRect = CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
        } else {
            let height = rect.height * firstShare
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
            secondRect = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height)
        }
        return layout(first, in: firstRect, horizontal: !horizontal)
            + layout(second, in: secondRect, horizontal: !horizontal)
    }
}
