import Foundation

/// 导出的单条判定。保留规则原文、模型解释和证据链，中文名排在第一行。
public struct ExportedVerdict: Codable, Sendable {
    public let chineseName: String
    public let risk: String
    public let path: String
    public let sizeBytes: Int64
    public let defaultSelected: Bool
    public let needConfirm: Bool
    public let explanation: String
    public let aiExplanation: String?
    public let confidence: Double?
    public let evidence: [String]
    public let modelAssisted: Bool
}

/// 报告导出。只做序列化，不改变任何判定，也不触发文件删除。
public enum ReportExporter: Sendable {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static func exportedVerdicts(
        _ report: ScanReport,
        glossary: Glossary? = nil,
        redactor: ReportRedactor = .default
    ) -> [ExportedVerdict] {
        let dictionary = glossary ?? (try? Glossary.loadBundled())
        return report.verdicts.map { verdict in
            ExportedVerdict(
                chineseName: dictionary?.chineseLabel(for: verdict.item.path) ?? "其他项目",
                risk: verdict.risk.rawValue,
                path: redactor.redact(verdict.item.path),
                sizeBytes: verdict.item.sizeBytes,
                defaultSelected: verdict.defaultSelected,
                needConfirm: verdict.needConfirm,
                explanation: redactor.redact(verdict.explanation),
                aiExplanation: verdict.aiExplanation.map(redactor.redact),
                confidence: verdict.confidence,
                evidence: verdict.evidence.map(redactor.redact),
                modelAssisted: verdict.modelAssisted
            )
        }
    }

    public static func json(
        report: ScanReport,
        glossary: Glossary? = nil,
        redactor: ReportRedactor = .default
    ) throws -> Data {
        let payload = ExportedReport(
            scannedAt: report.scannedAt,
            scanStatus: report.scanStatus,
            canClean: report.canClean,
            totalBytes: report.totalBytes,
            gaps: report.scanGaps.map(redactor.redacted),
            items: exportedVerdicts(report, glossary: glossary, redactor: redactor)
        )
        return try encoder.encode(payload)
    }

    /// CSV 带 UTF-8 BOM，方便 Excel 直接打开中文不乱码。
    public static func csv(
        report: ScanReport,
        glossary: Glossary? = nil,
        redactor: ReportRedactor = .default
    ) -> String {
        let header = [
            "中文名", "风险等级", "原始路径", "大小（字节）", "默认勾选", "需单独确认",
            "判定依据", "本地模型解释", "置信度", "证据链", "模型参与"
        ]
        var rows: [[String]] = [header]
        for item in exportedVerdicts(report, glossary: glossary, redactor: redactor) {
            rows.append([
                item.chineseName,
                item.risk,
                item.path,
                String(item.sizeBytes),
                item.defaultSelected ? "是" : "否",
                item.needConfirm ? "是" : "否",
                item.explanation,
                item.aiExplanation ?? "",
                item.confidence.map { String(format: "%.2f", $0) } ?? "",
                item.evidence.joined(separator: " | "),
                item.modelAssisted ? "是" : "否"
            ])
        }
        let body = rows.map { $0.map(escapeCSV).joined(separator: ",") }.joined(separator: "\r\n")
        return "\u{FEFF}" + body + "\r\n"
    }

    private static func escapeCSV(_ value: String) -> String {
        let needsQuoting = value.contains(",") || value.contains("\"") ||
            value.contains("\n") || value.contains("\r")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public struct ExportedReport: Codable, Sendable {
        public let scannedAt: Date
        public let scanStatus: String
        public let canClean: Bool
        public let totalBytes: Int64
        public let gaps: [ScanGap]
        public let items: [ExportedVerdict]
    }
}
