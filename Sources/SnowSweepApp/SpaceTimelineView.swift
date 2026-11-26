import Foundation
import SwiftUI
import AppKit
import SnowSweepCore

/// M3：空间分析页的时间线状态。只读写本机 JSONL；不联网、不执行删除。
@MainActor
final class SpaceTimelineModel: ObservableObject {
    @Published private(set) var snapshots: [SpaceSnapshot] = []
    @Published private(set) var report: SpaceDeltaReport?
    @Published private(set) var events: [SpaceTimelineEvent] = []
    @Published private(set) var isRecording = false
    @Published private(set) var note = ""
    @Published private(set) var error: String?

    let store: SpaceSnapshotStore
    static let automaticInterval: TimeInterval = SpaceSnapshotSchedule.automaticInterval

    init(store: SpaceSnapshotStore = SpaceSnapshotStore()) {
        self.store = store
    }

    var latest: SpaceSnapshot? { snapshots.last }
    var isLoaded: Bool { report != nil || !snapshots.isEmpty }

    func refresh(queryText: String = "") async {
        let store = store
        do {
            let values = try await Task.detached(priority: .utility) {
                try store.snapshots()
            }.value
            snapshots = values
            let auditEvents = (try? await Task.detached(priority: .utility) {
                try AuditLog().events()
            }.value) ?? []
            let query = SpaceDeltaQuery.parse(queryText)
            let nextReport = SpaceDeltaDiagnostic.report(snapshots: values, query: query)
            report = nextReport
            let start = nextReport.baseline?.at ?? query.start
            let end = nextReport.current?.at ?? query.end
            events = SpaceTimelineBuilder.events(
                snapshots: values, audit: auditEvents, start: start, end: end
            )
            error = nil
        } catch {
            self.error = "读取空间快照失败：\(error.localizedDescription)"
        }
    }

    /// 空间分析页兜底：每次成功扫描会另拍一张；这里只在距上一张满 7 天时补记，避免频繁 du。
    func recordIfNeeded(slices: [VolumeSlice], disk: DiskSnapshot?) async {
        guard !isRecording else { return }
        if report == nil {
            await refresh()
        }
        if let latest, Date().timeIntervalSince(latest.at) < Self.automaticInterval {
            note = "最近一次快照在 7 天内，本次自动跳过。"
            return
        }
        await record(slices: slices, disk: disk, source: "auto", force: false)
    }

    /// 手动记录允许强制写入；统计结果来自空间分析页当前一层，不额外读文件内容。
    func record(slices: [VolumeSlice], disk: DiskSnapshot?, source: String, force: Bool) async {
        guard !isRecording else { return }
        isRecording = true
        defer { isRecording = false }

        if !force, let latest, Date().timeIntervalSince(latest.at) < 60 {
            note = "刚刚记录过，这次没有重复写入。"
            return
        }

        let now = Date()
        let entries = slices
            .filter { $0.bytes > 0 || $0.isPartial }
            .map {
                SpaceSnapshotEntry(
                    path: ($0.path as NSString).standardizingPath,
                    bytes: max(0, $0.bytes),
                    isPartial: $0.isPartial
                )
            }
        guard !entries.isEmpty else {
            note = "当前还没有可记录的空间统计；先等「重新分析」完成。"
            return
        }

        let diskValue: DiskSnapshot
        if let disk {
            diskValue = disk
        } else {
            diskValue = await Task.detached(priority: .utility) {
                SystemMetrics.disk()
            }.value
        }
        let snapshot = SpaceSnapshot(
            at: now,
            diskTotalBytes: diskValue.totalBytes,
            diskFreeBytes: diskValue.freeBytes,
            source: source,
            note: source == "manual" ? "空间分析页手动记录" : "空间分析完成后自动记录",
            entries: entries
        )
        let store = store
        do {
            try await Task.detached(priority: .utility) {
                try store.append(snapshot)
            }.value
            note = "已记录 \(entries.count) 个目录 · 可用 \(AssistantBytes.text(diskValue.freeBytes))"
            await refresh()
        } catch {
            self.error = "写入空间快照失败：\(error.localizedDescription)"
        }
    }

    func revealStore() {
        if FileManager.default.fileExists(atPath: store.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
        } else {
            NSWorkspace.shared.open(store.fileURL.deletingLastPathComponent())
        }
    }

    var lastSnapshotText: String {
        guard let latest else { return "还没有快照" }
        return Self.dateFormatter.string(from: latest.at)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

/// 账单正文，空间时间线弹窗与首屏“为什么少了 40G”共用。
struct SpaceDeltaReportView: View {
    let report: SpaceDeltaReport
    var compact = false
    var onOpenTimeline: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if report.dataSufficient {
                overview
                statistics
                explanation
                changes
                attribution
            } else {
                insufficient
            }
            if !report.caveat.isEmpty {
                Text(report.caveat)
                    .font(.caption2)
                    .foregroundStyle(SnowSkin.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let onOpenTimeline {
                Button(action: onOpenTimeline) {
                    Label("打开空间时间线", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(SnowSkin.accent)
                Text("时间窗：\(report.query.label)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(SnowSkin.text)
                Spacer()
                Text("\(report.snapshotCount) 次快照")
                    .font(.caption2)
                    .foregroundStyle(SnowSkin.faint)
            }
            if let baseline = report.baseline, let current = report.current {
                Text("\(SpaceTimelineModel.dateFormatter.string(from: baseline.at)) → \(SpaceTimelineModel.dateFormatter.string(from: current.at))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SnowSkin.dim)
            }
            if let freeText = report.freeText {
                Text(freeText)
                    .font(.system(size: compact ? 22 : 28, weight: .semibold, design: .serif))
                    .foregroundStyle((report.diskFreeDelta ?? 0) > 0 ? SnowSkin.green : SnowSkin.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("这次没有记录磁盘可用空间，只能看目录变化。")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(SnowSkin.orange)
            }
        }
    }

    private var statistics: some View {
        HStack(spacing: 0) {
            stat("开始时可用", report.diskFreeStart, SnowSkin.dim)
            Divider().overlay(SnowSkin.overlay(0.08))
            stat("结束时可用", report.diskFreeEnd, SnowSkin.dim)
            Divider().overlay(SnowSkin.overlay(0.08))
            stat(report.diskFreeDelta == 0 ? "目录账面变化" : "目录可解释",
                 report.attributedBytes, SnowSkin.accent, signed: true)
        }
        .padding(.vertical, 10)
        .background(SnowSkin.overlay(0.04), in: RoundedRectangle(cornerRadius: 11))
    }

    private var explanation: some View {
        Text(report.explanation)
            .font(.callout)
            .foregroundStyle(SnowSkin.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SnowSkin.overlay(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("目录变化")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(SnowSkin.text)
                Spacer()
                Text("按变化绝对值排序")
                    .font(.caption2)
                    .foregroundStyle(SnowSkin.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if report.topChanges.isEmpty {
                Text("目录层面没有明显变化。")
                    .font(.caption)
                    .foregroundStyle(SnowSkin.dim)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                ForEach(report.topChanges) { change in
                    changeRow(change)
                }
            }
        }
        .background(SnowSkin.overlay(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private func changeRow(_ change: SpaceDeltaEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(folderCN(change.name))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(SnowSkin.text)
                    .lineLimit(1)
                Text(stateText(change.state))
                    .font(.caption2)
                    .foregroundStyle(change.deltaBytes > 0 ? SnowSkin.orange : SnowSkin.green)
                if change.isPartial {
                    Text("读不全")
                        .font(.caption2)
                        .foregroundStyle(SnowSkin.orange)
                }
                Spacer(minLength: 8)
                Text(deltaText(change.deltaBytes))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(change.deltaBytes > 0 ? SnowSkin.orange : SnowSkin.green)
            }
            HStack(spacing: 6) {
                Text((change.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(SnowSkin.faint)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(AssistantBytes.text(change.beforeBytes)) → \(AssistantBytes.text(change.afterBytes))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(SnowSkin.faint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().overlay(SnowSkin.overlay(0.06))
        }
    }

    @ViewBuilder
    private var attribution: some View {
        if let unexplained = report.unexplainedBytes {
            let absolute = abs(unexplained)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "questionmark.folder")
                        .foregroundStyle(absolute >= 10_000_000 ? SnowSkin.orange : SnowSkin.faint)
                    Text(report.diskFreeDelta == 0 ? "账面对照" : "未归因")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(SnowSkin.text)
                    Spacer()
                    Text("\(unexplained >= 0 ? "+" : "-")\(AssistantBytes.text(absolute))")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(absolute >= 10_000_000 ? SnowSkin.orange : SnowSkin.dim)
                }
                Text(report.diskFreeDelta == 0
                     ? "这次系统可用空间没有变化；目录账面合计 \(deltaText(report.attributedBytes)) 与 0 的差额单列，可能被 APFS 可回收空间、本地快照或统计取整抵消。"
                     : unexplained > 0
                     ? "这部分增长没有落到快照覆盖的目录，可能来自系统更新、APFS 本地快照、废纸篓、其他卷或未纳入快照的位置。"
                     : report.attributedBytes >= 0
                     ? "目录账面净增比系统实际占用多出 \(AssistantBytes.text(absolute))，差额可能被 APFS 可回收空间、统计取整或其他卷抵掉了。"
                     : "目录减少的体积比系统实际释放的多，差额可能被系统快照、缓存回写或其他卷抵掉了。")
                    .font(.caption2)
                    .foregroundStyle(SnowSkin.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(SnowSkin.overlay(0.04), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var insufficient: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SnowSkin.orange)
                Text("数据还不够，先不猜原因")
                    .font(.system(size: compact ? 20 : 24, weight: .semibold, design: .serif))
                    .foregroundStyle(SnowSkin.text)
            }
            Text(report.reason ?? "至少需要两次空间快照。")
                .font(.callout)
                .foregroundStyle(SnowSkin.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text("雪只比较本机快照里的目录体积和磁盘可用空间；没有快照时，不会用模型编一个原因。")
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnowSkin.overlay(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ title: String, _ bytes: Int64?, _ tint: Color, signed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
            Text(bytes.map { signed ? signedAmount($0) : AssistantBytes.text($0) } ?? "未记录")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private func stateText(_ state: SpaceDeltaEntryState) -> String {
        switch state {
        case .grew: return "增加"
        case .shrank: return "减少"
        case .appeared: return "新增"
        case .disappeared: return "消失"
        case .unchanged: return "不变"
        }
    }

    private func deltaText(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 B" }
        return signedAmount(bytes)
    }

    private func signedAmount(_ bytes: Int64) -> String {
        "\(bytes >= 0 ? "+" : "-")\(AssistantBytes.text(abs(bytes)))"
    }
}

struct SpaceTimelineSummaryCard: View {
    @ObservedObject var model: SpaceTimelineModel
    let onOpen: () -> Void

    var body: some View {
        ModuleCard(padding: 0) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SnowSkin.accent)
                        .frame(width: 34, height: 34)
                        .background(SnowSkin.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("空间时间线")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(SnowSkin.text)
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(SnowSkin.dim)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(SnowSkin.faint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var summary: String {
        if let error = model.error { return error }
        if let report = model.report, report.dataSufficient {
            if let free = report.freeText {
                return "\(report.query.label) · \(free) · \(report.snapshotCount) 次快照"
            }
            return "\(report.query.label) · 目录变化 \(report.topChanges.count) 项"
        }
        return "至少需要两次快照 · 已记录 \(model.snapshots.count) 次"
    }
}

struct SpaceTimelineSheet: View {
    @ObservedObject var model: SpaceTimelineModel
    let onCapture: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SnowSkin.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("空间时间线")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .foregroundStyle(SnowSkin.text)
                    Text("比较两次本机快照：先看系统可用空间，再看目录变化，差额单列“未归因”。")
                        .font(.caption)
                        .foregroundStyle(SnowSkin.faint)
                }
                Spacer()
                if model.isRecording {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await onCapture() }
                } label: {
                    Label("记录快照", systemImage: "camera.metering.center.weighted")
                }
                .buttonStyle(.borderedProminent)
                .tint(SnowSkin.accent)
                .disabled(model.isRecording)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SnowSkin.dim)
                        .frame(width: 26, height: 26)
                        .background(SnowSkin.overlay(0.06), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            Divider().overlay(SnowSkin.overlay(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let report = model.report {
                        SpaceDeltaReportView(report: report)
                    } else {
                        ProgressView("正在读取本机快照…")
                            .controlSize(.small)
                            .padding(.vertical, 20)
                    }
                    if !model.note.isEmpty {
                        Text(model.note)
                            .font(.caption2)
                            .foregroundStyle(SnowSkin.faint)
                    }
                    eventList
                    snapshotList
                }
                .padding(20)
            }
            Divider().overlay(SnowSkin.overlay(0.08))
            HStack(spacing: 10) {
                Text("快照只保存在本机；每次扫描后自动记录，未扫描时每 7 天至少记录一次；不联网、不记录文件内容、不执行删除。")
                    .font(.caption2)
                    .foregroundStyle(SnowSkin.faint)
                Spacer()
                Button("打开快照目录") { model.revealStore() }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(SnowSkin.accent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 660)
        .background(SnowSkin.background)
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("事件时间线")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(SnowSkin.text)
                Spacer()
                Text("快照与成功移入废纸篓")
                    .font(.caption2)
                    .foregroundStyle(SnowSkin.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if model.events.isEmpty {
                Text("这个时间窗里还没有快照或清理事件。")
                    .font(.caption)
                    .foregroundStyle(SnowSkin.dim)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                ForEach(Array(model.events.prefix(16))) { event in
                    HStack(spacing: 8) {
                        Image(systemName: event.kind == .snapshot
                              ? "camera.metering.center.weighted"
                              : "trash")
                            .font(.caption2)
                            .foregroundStyle(event.kind == .snapshot ? SnowSkin.accent : SnowSkin.orange)
                            .frame(width: 14)
                        Text(SpaceTimelineModel.dateFormatter.string(from: event.at))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(SnowSkin.faint)
                        Text(event.title)
                            .font(.caption)
                            .foregroundStyle(SnowSkin.text)
                        Text(event.detail)
                            .font(.caption2)
                            .foregroundStyle(SnowSkin.dim)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let bytes = event.bytes {
                            Text(AssistantBytes.text(bytes))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(SnowSkin.faint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) {
                        Divider().overlay(SnowSkin.overlay(0.06))
                    }
                }
            }
        }
        .background(SnowSkin.overlay(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private var snapshotList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("快照记录")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(SnowSkin.text)
                Spacer()
                Text("\(model.snapshots.count) 次 · 本地 JSONL")
                    .font(.caption2)
                    .foregroundStyle(SnowSkin.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if model.snapshots.isEmpty {
                Text("还没有快照。扫描完成后会自动记录；也可以在这里点“记录快照”。")
                    .font(.caption)
                    .foregroundStyle(SnowSkin.dim)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                ForEach(Array(model.snapshots.suffix(12).reversed())) { snapshot in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(snapshot.source == "manual" ? SnowSkin.green : SnowSkin.accent)
                            .frame(width: 6, height: 6)
                        Text(SpaceTimelineModel.dateFormatter.string(from: snapshot.at))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(SnowSkin.text)
                        Text(snapshot.sourceLabel)
                            .font(.caption2)
                            .foregroundStyle(SnowSkin.faint)
                        Spacer()
                        Text("\(snapshot.entries.count) 个目录")
                            .font(.caption2)
                            .foregroundStyle(SnowSkin.faint)
                        if let free = snapshot.diskFreeBytes {
                            Text("可用 \(AssistantBytes.text(free))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(SnowSkin.dim)
                        }
                        if snapshot.partialCount > 0 {
                            Text("\(snapshot.partialCount) 项读不全")
                                .font(.caption2)
                                .foregroundStyle(SnowSkin.orange)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) {
                        Divider().overlay(SnowSkin.overlay(0.06))
                    }
                }
            }
        }
        .background(SnowSkin.overlay(0.03), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension SpaceSnapshot {
    var sourceLabel: String {
        switch source {
        case "scan": return "扫描后自动"
        case "scheduled": return "每 7 天自动"
        case "auto": return "空间分析自动"
        default: return "手动"
        }
    }
}
