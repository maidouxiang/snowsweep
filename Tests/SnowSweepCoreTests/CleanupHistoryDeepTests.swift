import Foundation
import Testing
@testable import SnowSweepCore

private func deepTempURL(_ name: String) -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SnowSweepDeep-\(UUID().uuidString)-\(name)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func verdictRuleIDComesFromEvidence() {
    let item = ScanItem(path: "/Users/me/Library/Developer/Xcode/DerivedData/a", sizeBytes: 10)
    let verdict = Verdict(
        item: item,
        risk: .safe,
        explanation: "Xcode 编译缓存",
        evidence: ["rule:xcode-derived-data", "rebuildCost:low"]
    )
    #expect(verdict.ruleID == "xcode-derived-data")
    #expect(verdict.cleanupGroup == .developer)
}

@Test func cleanupGroupUsesRuleIDAndPathFallback() {
    let item = ScanItem(path: "/Users/me/Library/Logs/DiagnosticReports/a.ips", sizeBytes: 10)
    let noRule = Verdict(item: item, risk: .safe, explanation: "日志", evidence: ["no-rule"])
    #expect(noRule.ruleID == nil)
    #expect(noRule.cleanupGroup == .logs)

    let browser = Verdict(
        item: ScanItem(path: "/Users/me/Library/Caches/com.google.Chrome/x", sizeBytes: 1),
        risk: .safe,
        explanation: "Chrome 缓存",
        evidence: ["rule:browser-chrome-cache"]
    )
    #expect(browser.cleanupGroup == .browser)

    let installer = Verdict(
        item: ScanItem(path: "/Users/me/Downloads/old.dmg", sizeBytes: 1),
        risk: .safe,
        explanation: "旧安装包",
        evidence: ["rule:installers-dmg"]
    )
    #expect(installer.cleanupGroup == .installers)
}

@Test func auditBatchKeepsExplicitBatchAndLeavesLegacySingle() throws {
    let root = deepTempURL("batches")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    try log.append(action: .dryRun, path: "批次共 2 项", success: true,
                   detail: "预览生成，无文件操作", batchID: "clean-test-1", at: start)
    try log.append(action: .moveToTrash, path: "/tmp/a.dat", sizeBytes: 100,
                   success: true, detail: "已移到废纸篓", batchID: "clean-test-1",
                   at: start.addingTimeInterval(3))
    try log.append(action: .moveToTrash, path: "/tmp/b.dat", sizeBytes: 200,
                   success: false, detail: "失败", batchID: "clean-test-1",
                   at: start.addingTimeInterval(4))
    try log.append(action: .moveToTrash, path: "/tmp/legacy.dat", sizeBytes: 300,
                   success: true, detail: "旧记录", at: start.addingTimeInterval(60))

    let events = try log.events()
    #expect(events[1].batchID == "clean-test-1")
    #expect(events[1].displayDetail == "已移到废纸篓")
    #expect(events[3].batchID == nil)

    let batches = AuditBatchBuilder.build(from: events)
    #expect(batches.count == 2)
    let batch = try #require(batches.first { $0.isExplicit })
    #expect(batch.id == "clean-test-1")
    #expect(batch.events.count == 3)
    #expect(batch.successCount == 2)
    #expect(batch.failureCount == 1)
    #expect(batch.totalBytes == 100)
    #expect(batch.title == "清理批次")

    let legacy = try #require(batches.first { !$0.isExplicit })
    #expect(legacy.events.count == 1)
    #expect(legacy.events.first?.path.hasSuffix("legacy.dat") == true)
}

@Test func auditBatchExporterWritesMarkdownAndJSON() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let events = [
        AuditEvent(at: start, action: .moveToTrash, path: "/tmp/a.dat",
                   sizeBytes: 128, success: true, detail: "已移到废纸篓 [batch:clean-x]"),
        AuditEvent(at: start.addingTimeInterval(1), action: .moveToTrashFailed,
                   path: "/tmp/b.dat", sizeBytes: 64, success: false,
                   detail: "失败 [batch:clean-x]")
    ]
    let batch = AuditBatch(id: "clean-x", events: events, isExplicit: true)
    let markdown = AuditBatchExporter.markdown(batches: [batch], exportedAt: start)
    #expect(markdown.contains("# 雪操作历史"))
    #expect(markdown.contains("清理批次"))
    #expect(markdown.contains("a.dat"))
    #expect(markdown.contains("成功 1 / 失败 1"))
    #expect(!markdown.contains("[batch:clean-x]"))

    let data = try AuditBatchExporter.jsonData(batches: [batch], exportedAt: start)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("\"id\" : \"clean-x\""))
    #expect(text.contains("a.dat"))
    #expect(!text.contains("[batch:clean-x]"))
}

@Test func previewOnlyBatchShowsExpectedBytes() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let batch = AuditBatch(
        id: "clean-preview",
        events: [
            AuditEvent(at: start, action: .dryRun, path: "批次共 2 项",
                       sizeBytes: 300, success: true, detail: "预览生成，无文件操作")
        ],
        isExplicit: true
    )
    #expect(batch.totalBytes == 300)
    #expect(batch.bytesText != "—")
    #expect(batch.resultLabel == "仅预览")
}
