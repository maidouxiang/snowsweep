import Foundation

/// 一次清理/卸载聚合成的批次。显式批次来自审计 detail 里的 `[batch:…]`；
/// 旧日志没有批次号时，每条记录单独成批，绝不擅自把不同时间的操作合并。
public struct AuditBatch: Identifiable, Sendable, Equatable {
    public let id: String
    public let events: [AuditEvent]
    public let isExplicit: Bool

    public init(id: String, events: [AuditEvent], isExplicit: Bool) {
        self.id = id
        self.events = events.sorted { $0.at < $1.at }
        self.isExplicit = isExplicit
    }

    public var startAt: Date { events.first?.at ?? .distantPast }
    public var endAt: Date { events.last?.at ?? .distantPast }

    public var title: String {
        if id.hasPrefix("uninstall-") { return "卸载批次" }
        if id.hasPrefix("clean-") { return "清理批次" }
        if events.allSatisfy({ $0.action == .dryRun }) { return "预览批次" }
        if let first = events.first, events.allSatisfy({ $0.action == first.action }) {
            return first.action.chineseLabel
        }
        return "混合操作"
    }

    /// 真实清理只统计成功移入废纸篓/备份的体积；纯预览批次统计预计释放体积，避免显示 0。
    public var totalBytes: Int64 {
        if events.allSatisfy({ $0.action == .dryRun }) {
            return events.filter(\.success).reduce(0) { $0 + $1.sizeBytes }
        }
        return events.filter {
            $0.success && [.moveToTrash, .movedToBackup, .permanentDelete].contains($0.action)
        }.reduce(0) { $0 + $1.sizeBytes }
    }

    public var successCount: Int { events.filter(\.success).count }
    public var failureCount: Int { events.filter { !$0.success }.count }

    public var resultLabel: String {
        if failureCount > 0 { return successCount > 0 ? "部分失败" : "失败" }
        if events.allSatisfy({ $0.action == .dryRun }) { return "仅预览" }
        return "成功"
    }

    public var bytesText: String {
        totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) : "—"
    }

    public var headline: String {
        "\(title) · \(events.count) 条 · \(bytesText)"
    }

    public var actionLabels: String {
        Array(Set(events.map { $0.action.chineseLabel })).sorted().joined(separator: " / ")
    }
}

public enum AuditBatchBuilder {
    /// 输入顺序不限；输出按结束时间倒序，适合历史页直接展示。
    public static func build(from events: [AuditEvent]) -> [AuditBatch] {
        var groups: [String: [AuditEvent]] = [:]
        for event in events {
            if let batchID = event.batchID {
                groups[batchID, default: []].append(event)
            } else {
                groups["event-\(event.id.uuidString)", default: []].append(event)
            }
        }
        return groups.map { key, value in
            AuditBatch(id: key, events: value, isExplicit: !key.hasPrefix("event-"))
        }
        .sorted {
            if $0.endAt != $1.endAt { return $0.endAt > $1.endAt }
            return $0.id > $1.id
        }
    }
}

/// 历史导出。只导出本地审计内容，不上传；JSON 供机器核对，Markdown 供人阅读。
public enum AuditBatchExporter {
    private struct ExportEvent: Codable {
        let id: UUID
        let at: Date
        let action: AuditAction
        let path: String
        let ruleID: String?
        let sizeBytes: Int64
        let success: Bool
        let detail: String
        let displayDetail: String
        let sha256: String

        init(_ event: AuditEvent) {
            id = event.id
            at = event.at
            action = event.action
            path = event.path
            ruleID = event.ruleID
            sizeBytes = event.sizeBytes
            success = event.success
            detail = event.displayDetail
            displayDetail = event.displayDetail
            sha256 = event.sha256
        }
    }

    private struct ExportBatch: Codable {
        let id: String
        let title: String
        let startAt: Date
        let endAt: Date
        let totalBytes: Int64
        let successCount: Int
        let failureCount: Int
        let events: [ExportEvent]
    }

    private struct ExportPayload: Codable {
        let exportedAt: Date
        let batchCount: Int
        let eventCount: Int
        let batches: [ExportBatch]
    }

    public static func jsonData(batches: [AuditBatch], exportedAt: Date = Date()) throws -> Data {
        let payload = ExportPayload(
            exportedAt: exportedAt,
            batchCount: batches.count,
            eventCount: batches.reduce(0) { $0 + $1.events.count },
            batches: batches.map { batch in
                ExportBatch(
                    id: batch.id,
                    title: batch.title,
                    startAt: batch.startAt,
                    endAt: batch.endAt,
                    totalBytes: batch.totalBytes,
                    successCount: batch.successCount,
                    failureCount: batch.failureCount,
                    events: batch.events.map(ExportEvent.init)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    public static func markdown(batches: [AuditBatch], exportedAt: Date = Date()) -> String {
        let stamp = exportedAt.formatted(date: .numeric, time: .shortened)
        var lines = [
            "# 雪操作历史",
            "",
            "- 导出时间：\(stamp)",
            "- 批次数：\(batches.count)",
            "- 条目数：\(batches.reduce(0) { $0 + $1.events.count })",
            "- 说明：日志只存本机；批次按一次清理/卸载聚合。",
            ""
        ]

        for (index, batch) in batches.enumerated() {
            let start = batch.startAt.formatted(date: .numeric, time: .shortened)
            let end = batch.endAt.formatted(date: .numeric, time: .shortened)
            lines.append("## \(index + 1). \(batch.title)")
            lines.append("")
            lines.append("- 时间：\(start) → \(end)")
            lines.append("- 结果：\(batch.resultLabel)（成功 \(batch.successCount) / 失败 \(batch.failureCount)）")
            lines.append("- 预计释放：\(batch.bytesText)")
            lines.append("- 动作：\(batch.actionLabels)")
            lines.append("")
            lines.append("| 时间 | 动作 | 路径 | 大小 | 结果 |")
            lines.append("|---|---|---|---:|---|")
            for event in batch.events {
                let time = event.at.formatted(date: .numeric, time: .shortened)
                let path = event.path.replacingOccurrences(of: "|", with: "\\|")
                let size = event.sizeBytes > 0
                    ? ByteCountFormatter.string(fromByteCount: event.sizeBytes, countStyle: .file)
                    : "—"
                lines.append("| \(time) | \(event.action.chineseLabel) | `\(path)` | \(size) | \(event.success ? "成功" : "失败") |")
                if !event.displayDetail.isEmpty {
                    lines.append("")
                    lines.append("> \(event.displayDetail)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
