import Foundation

/// 扫描缺口报告的纯数据生成器。只输出用户已经看到的缺口，
/// 不推断原因、不把“读不到”写成失败，也不包含任何文件内容。
public enum ScanGapReport {
    public static func grouped(_ gaps: [ScanGap]) -> [(severity: ScanGap.Severity, gaps: [ScanGap])] {
        [ScanGap.Severity.critical, .warning, .info].compactMap { severity in
            let rows = gaps.filter { $0.severity == severity }
            return rows.isEmpty ? nil : (severity, rows)
        }
    }

    public static func markdown(
        gaps: [ScanGap],
        scanScope: String,
        generatedAt: Date = Date()
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "# 雪 · 扫描缺口报告",
            "",
            "- 生成时间：\(formatter.string(from: generatedAt))",
            "- 扫描范围：\(scanScope)",
            "- 缺口总数：\(gaps.count)",
            ""
        ]

        if gaps.isEmpty {
            lines.append("上次扫描没有留下缺口。")
        } else {
            for group in grouped(gaps) {
                lines.append("## \(title(for: group.severity))（\(group.gaps.count) 项）")
                lines.append("")
                for gap in group.gaps {
                    lines.append("### \(gap.displayText)")
                    lines.append("")
                    lines.append("- 路径：`\(gap.path)`")
                    lines.append("- 级别：\(title(for: gap.severity))")
                    lines.append("- 范围：\(gap.scope == .wholeScan ? "整次扫描" : "单个目录")")
                    if let detail = gap.detail, !detail.isEmpty {
                        lines.append("- 说明：\(detail)")
                    }
                    lines.append("")
                }
            }
        }

        lines.append("> 这份报告只记录读不到的位置，不代表这些目录里有可删除文件。")
        return lines.joined(separator: "\n")
    }

    public enum SeverityTitle: String, Sendable {
        case info = "提示"
        case warning = "局部缺口"
        case critical = "全盘级缺口"
    }

    public static func severityTitle(_ severity: ScanGap.Severity) -> String {
        switch severity {
        case .info: return SeverityTitle.info.rawValue
        case .warning: return SeverityTitle.warning.rawValue
        case .critical: return SeverityTitle.critical.rawValue
        }
    }

    private static func title(for severity: ScanGap.Severity) -> String {
        severityTitle(severity)
    }
}
