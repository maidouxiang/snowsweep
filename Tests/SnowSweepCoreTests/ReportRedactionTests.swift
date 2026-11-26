import Foundation
import Testing
@testable import SnowSweepCore

@Test func redactorMasksCurrentUsersHomeDirectory() {
    let redactor = ReportRedactor(username: "example")
    #expect(redactor.redact("/Users/example/Library/Caches/foo") == "~/Library/Caches/foo")
    #expect(redactor.redact("/Users/example") == "~")
    #expect(redactor.redact("路径是 /Users/example/Documents/私人.txt，已跳过") ==
            "路径是 ~/Documents/私人.txt，已跳过")
}

@Test func redactorMasksOtherUsersButKeepsSystemAccounts() {
    let redactor = ReportRedactor(username: "example")
    #expect(redactor.redact("/Users/zhangshan/Documents/x") == "/Users/〈用户〉/Documents/x")
    #expect(redactor.redact("/Users/Shared/共享资料") == "/Users/Shared/共享资料")
    #expect(redactor.redact("/Users/example/文件 → /Users/other/文件") ==
            "~/文件 → /Users/〈用户〉/文件")
}

@Test func redactorLeavesTextAloneWhenDisabled() {
    let redactor = ReportRedactor(username: "example", isEnabled: false)
    let original = "/Users/example/Library/Caches/foo"
    #expect(redactor.redact(original) == original)
}

@Test func redactionDoesNotAlterRiskOrEvidenceSemantics() throws {
    let report = ScanReport(
        scanStatus: "complete", totalBytes: 1,
        verdicts: [
            Verdict(
                item: ScanItem(path: "/Users/example/Library/Caches/com.google.Chrome/Temp", sizeBytes: 1),
                risk: .safe, explanation: "规则原文",
                evidence: ["rule:chrome", "path:/Users/example/Library/Caches/com.google.Chrome"]
            )
        ],
        scanGaps: [ScanGap(kind: .other, path: "/Users/example/Library/foo",
                           detail: "读不到 /Users/other/Library/bar")]
    )
    let data = try ReportExporter.json(report: report, redactor: ReportRedactor(username: "example"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ReportExporter.ExportedReport.self, from: data)
    let item = try #require(decoded.items.first)
    #expect(item.path == "~/Library/Caches/com.google.Chrome/Temp")
    #expect(item.risk == "safe")
    #expect(item.explanation == "规则原文")
    #expect(item.evidence == ["rule:chrome", "path:~/Library/Caches/com.google.Chrome"])
    let gap = try #require(decoded.gaps.first)
    #expect(gap.path == "~/Library/foo")
    #expect(gap.detail == "读不到 /Users/〈用户〉/Library/bar")
    // 源头报告没有被改：脱敏只发生在导出的副本上。
    #expect(report.verdicts[0].item.path == "/Users/example/Library/Caches/com.google.Chrome/Temp")
}

@Test func csvExportRedactsByDefaultButKeepsHeader() {
    let report = ScanReport(
        scanStatus: "complete", totalBytes: 1,
        verdicts: [
            Verdict(
                item: ScanItem(path: "/Users/example/Library/Caches/foo", sizeBytes: 1),
                risk: .safe, explanation: "规则原文"
            )
        ]
    )
    let csv = ReportExporter.csv(report: report, redactor: ReportRedactor(username: "example"))
    #expect(csv.hasPrefix("\u{FEFF}中文名,风险等级,原始路径"))
    #expect(csv.contains("~/Library/Caches/foo"))
    #expect(!csv.contains("/Users/example"))
}
