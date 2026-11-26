import SwiftUI
import AppKit
import SnowSweepCore

private enum HistoryActionFilter: String, CaseIterable, Identifiable {
    case all = "全部动作"
    case cleanup = "清理"
    case preview = "预览"
    case protection = "保护与拒绝"
    case failed = "失败"

    var id: String { rawValue }

    func matches(_ action: AuditAction) -> Bool {
        switch self {
        case .all: return true
        case .cleanup: return action.isCleanupAction && action != .dryRun
        case .preview: return action == .dryRun
        case .protection:
            return action == .policyRejected || action == .targetRejected || action == .protectionChanged
        case .failed: return action == .moveToTrashFailed || action == .backupFailed
            || action == .permanentDeleteFailed
        }
    }
}

private enum HistoryResultFilter: String, CaseIterable, Identifiable {
    case all = "全部结果"
    case success = "成功"
    case failed = "失败"

    var id: String { rawValue }

    func matches(_ event: AuditEvent) -> Bool {
        switch self {
        case .all: return true
        case .success: return event.success
        case .failed: return !event.success
        }
    }
}

/// 操作历史 V0.4.0：按动作/结果筛选，一次清理聚合为一批，支持导出 Markdown/JSON。
struct HistoryView: View {
    @EnvironmentObject var monitor: SystemMonitor

    @State private var actionFilter: HistoryActionFilter = .all
    @State private var resultFilter: HistoryResultFilter = .all
    @State private var search = ""
    @State private var expandedBatches: Set<String> = []
    @State private var message = ""
    @State private var isError = false

    private var visibleBatches: [AuditBatch] {
        let batches = AuditBatchBuilder.build(from: monitor.auditEvents)
        return batches.compactMap { batch in
            let events = batch.events.filter { event in
                guard actionFilter.matches(event.action), resultFilter.matches(event) else { return false }
                guard !search.isEmpty else { return true }
                return event.path.localizedCaseInsensitiveContains(search)
                    || event.displayDetail.localizedCaseInsensitiveContains(search)
                    || (event.ruleID ?? "").localizedCaseInsensitiveContains(search)
            }
            guard !events.isEmpty else { return nil }
            return AuditBatch(id: batch.id, events: events, isExplicit: batch.isExplicit)
        }
    }

    private var visibleEventCount: Int {
        visibleBatches.reduce(0) { $0 + $1.events.count }
    }

    private var visibleBytes: Int64 {
        visibleBatches.reduce(0) { $0 + $1.totalBytes }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let verification = monitor.auditVerification { verificationBanner(verification) }
                if !message.isEmpty { messageBanner }
                if !monitor.auditEvents.isEmpty { filterBar }

                if monitor.auditEvents.isEmpty {
                    ContentUnavailableView(
                        "还没有操作记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("预览、移到废纸篓、卸载与失败都会留下带哈希的记录；同一批操作会聚合成一条。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleBatches.isEmpty {
                    ContentUnavailableView(
                        "没有匹配的操作记录",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("试试切换动作或结果筛选，或清空搜索词。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    summaryRow
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleBatches) { batch in
                            batchCard(batch)
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await monitor.refreshAudit() }
        .onChange(of: actionFilter) { _, _ in expandedBatches.removeAll() }
        .onChange(of: resultFilter) { _, _ in expandedBatches.removeAll() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            PageHeader(
                title: "操作历史",
                subtitle: "读取本机 audit.jsonl。按一次清理/卸载聚合为批次，可展开看每条路径与哈希；日志只存本地。"
            )
            Spacer()
            Button("重新读取") {
                Task { await monitor.refreshAudit() }
            }
            Button("打开系统废纸篓") { monitor.openTrash() }
            Menu("导出") {
                Button("导出当前筛选 · Markdown") { exportMarkdown() }
                    .disabled(visibleBatches.isEmpty)
                Button("导出当前筛选 · JSON") { exportJSON() }
                    .disabled(visibleBatches.isEmpty)
                Divider()
                Button("导出原始 JSONL 副本") {
                    if let url = monitor.exportAuditCopy() {
                        message = "已导出原始日志到 \(url.path)"
                        isError = false
                    }
                }
            }
            .fixedSize()
        }
    }

    private func verificationBanner(_ verification: AuditVerification) -> some View {
        InfoBanner(
            text: verification.isValid
                ? "日志校验通过：\(verification.lineCount) 条，哈希链完整。"
                : "日志校验失败：损坏行 \(verification.brokenLines)，断链行 \(verification.chainBrokenAt)。请人工复核，不要据此清理。",
            color: verification.isValid ? .green : .red
        )
    }

    private var messageBanner: some View {
        HStack {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(isError ? .orange : .blue)
            Text(message).font(.caption)
            Spacer()
            Button("关闭") { message = "" }.buttonStyle(.borderless)
        }
        .padding(8)
        .background((isError ? Color.orange : Color.blue).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Picker("动作", selection: $actionFilter) {
                    ForEach(HistoryActionFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                Picker("结果", selection: $resultFilter) {
                    ForEach(HistoryResultFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 110)

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜路径、规则或说明", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .frame(maxWidth: 260)

                Spacer()

                Button(expandedBatches.isEmpty ? "展开全部" : "收起全部") {
                    if expandedBatches.isEmpty {
                        expandedBatches = Set(visibleBatches.map(\.id))
                    } else {
                        expandedBatches.removeAll()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 8) {
            HistoryChip(title: "批次", value: "\(visibleBatches.count)", color: .blue)
            HistoryChip(title: "条目", value: "\(visibleEventCount)", color: .secondary)
            HistoryChip(title: "预计释放", value: ByteCountFormatter.string(fromByteCount: visibleBytes, countStyle: .file), color: .green)
            if actionFilter != .all || resultFilter != .all || !search.isEmpty {
                Text("已筛选").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("批次按显式批次号聚合；旧记录没有批次号时逐条显示")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func batchCard(_ batch: AuditBatch) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expandedBatches.contains(batch.id) {
                    expandedBatches.remove(batch.id)
                } else {
                    expandedBatches.insert(batch.id)
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: expandedBatches.contains(batch.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(batch.title).font(.headline)
                            Text(batch.resultLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(batch.failureCount > 0 ? .orange : .green)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background((batch.failureCount > 0 ? Color.orange : Color.green).opacity(0.10), in: Capsule())
                            if batch.isExplicit {
                                Text("批次")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 8) {
                            Text(timeRange(batch))
                            Text("· \(batch.events.count) 条")
                            Text("· \(batch.bytesText)")
                            if batch.failureCount > 0 {
                                Text("· 失败 \(batch.failureCount)")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(batch.actionLabels)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedBatches.contains(batch.id) {
                Divider()
                VStack(spacing: 0) {
                    ForEach(batch.events, id: \.id) { event in
                        eventRow(event, batch: batch)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12)))
    }

    private func eventRow(_ event: AuditEvent, batch: AuditBatch) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: event.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(event.success ? .green : .orange)
                .font(.caption).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.action.chineseLabel)
                        .font(.caption.weight(.semibold))
                    Text((event.path as NSString).lastPathComponent)
                        .font(.caption).lineLimit(1)
                    if let rule = event.ruleID, !rule.isEmpty {
                        Text(rule).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Text(event.path)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    .textSelection(.enabled)
                if !event.displayDetail.isEmpty {
                    Text(event.displayDetail).font(.caption2).foregroundStyle(.secondary)
                }
                Text("哈希 \(event.sha256.prefix(12))…")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.at.formatted(date: .numeric, time: .shortened))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text(event.sizeBytes > 0 ? SystemMetrics.bytesText(event.sizeBytes) : "—")
                    .font(.caption2.monospacedDigit())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func timeRange(_ batch: AuditBatch) -> String {
        let start = batch.startAt
        let end = batch.endAt
        if start == end {
            return start.formatted(date: .numeric, time: .shortened)
        }
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        if sameDay {
            return start.formatted(date: .numeric, time: .shortened)
                + " → " + end.formatted(date: .omitted, time: .shortened)
        }
        return start.formatted(date: .numeric, time: .shortened)
            + " → " + end.formatted(date: .numeric, time: .shortened)
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "雪-操作历史-\(stamp()).md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AuditBatchExporter.markdown(batches: visibleBatches).write(to: url, atomically: true, encoding: .utf8)
            message = "已导出 \(visibleBatches.count) 个批次到 \(url.path)"
            isError = false
        } catch {
            message = "导出失败：\(error)"
            isError = true
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "雪-操作历史-\(stamp()).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try AuditBatchExporter.jsonData(batches: visibleBatches)
            try data.write(to: url, options: .atomic)
            message = "已导出 \(visibleBatches.count) 个批次到 \(url.path)"
            isError = false
        } catch {
            message = "导出失败：\(error)"
            isError = true
        }
    }

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}

private struct HistoryChip: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
