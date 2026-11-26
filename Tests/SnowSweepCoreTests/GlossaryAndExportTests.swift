import Foundation
import Testing
@testable import SnowSweepCore

private func projectRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

@Test func bundledGlossaryMatchesRulesDirectoryCopy() throws {
    let rulesCopy = try Data(contentsOf: projectRoot().appendingPathComponent("Rules/glossary.json"))
    let bundled = try #require(Bundle.module.url(forResource: "glossary", withExtension: "json"))
    let bundledCopy = try Data(contentsOf: bundled)
    #expect(rulesCopy == bundledCopy)
}

@Test func glossaryLoadsAndCoversEveryBuiltinRule() throws {
    let glossary = try Glossary(jsonURL: projectRoot().appendingPathComponent("Rules/glossary.json"))
    #expect(glossary.entries.count >= 30)
    let engine = try RuleEngine(jsonURL: projectRoot().appendingPathComponent("Rules/rules.json"))
    for rule in engine.ruleBook.rules {
        let label = glossary.chineseLabel(for: rule.pathPattern)
        #expect(label != "其他项目", "规则 \(rule.id) 的路径没有中文词条：\(rule.pathPattern)")
        #expect(label.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF })
    }
    for path in engine.ruleBook.protectedPaths {
        #expect(glossary.chineseLabel(for: path) != "其他项目", "保护路径缺中文词条：\(path)")
    }
}

@Test func glossaryRejectsDuplicateAndEmptyTerms() {
    #expect(throws: Glossary.GlossaryError.self) {
        try Glossary(version: "test", entries: [
            GlossaryEntry(en: "Caches", zh: "缓存", say: "说明"),
            GlossaryEntry(en: "caches", zh: "缓存", say: "说明")
        ])
    }
    #expect(throws: Glossary.GlossaryError.self) {
        try Glossary(version: "test", entries: [
            GlossaryEntry(en: "Caches", zh: "", say: "说明")
        ])
    }
}

@Test func reportJSONExportKeepsEvidenceAndChineseName() throws {
    let glossary = try Glossary(jsonURL: projectRoot().appendingPathComponent("Rules/glossary.json"))
    let report = ScanReport(
        scanStatus: "complete", totalBytes: 100,
        verdicts: [
            Verdict(
                item: ScanItem(path: "~/Library/Caches/com.google.Chrome/Temp", sizeBytes: 42),
                risk: .review, explanation: "规则原文", evidence: ["rule:chrome", "prompt:snow-ai-v1"],
                modelAssisted: true, needConfirm: true, aiExplanation: "本地解释", confidence: 0.55
            )
        ]
    )
    let data = try ReportExporter.json(report: report, glossary: glossary)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ReportExporter.ExportedReport.self, from: data)
    #expect(decoded.items.count == 1)
    #expect(decoded.items[0].risk == "review")
    #expect(decoded.items[0].needConfirm)
    #expect(!decoded.items[0].defaultSelected)
    #expect(decoded.items[0].evidence == ["rule:chrome", "prompt:snow-ai-v1"])
    #expect(decoded.items[0].aiExplanation == "本地解释")
    #expect(decoded.items[0].chineseLabelIsChinese())
}

private extension ExportedVerdict {
    func chineseLabelIsChinese() -> Bool {
        chineseName.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }
}

@Test func reportCSVExportEscapesSpecialCharacters() throws {
    let glossary = try Glossary(jsonURL: projectRoot().appendingPathComponent("Rules/glossary.json"))
    let report = ScanReport(
        scanStatus: "partial", totalBytes: 7,
        verdicts: [
            Verdict(
                item: ScanItem(path: "~/Library/Caches/带,逗号/与\"引号\"", sizeBytes: 7),
                risk: .safe, explanation: "第一行\n第二行", evidence: []
            )
        ],
        scanGaps: [ScanGap(kind: .tccDenied, path: "/Library")]
    )
    let csv = ReportExporter.csv(report: report, glossary: glossary)
    #expect(csv.hasPrefix("\u{FEFF}中文名,风险等级,原始路径"))
    #expect(csv.contains("\"\"引号\"\""))
    #expect(csv.contains("\"第一行\n第二行\""))
    #expect(csv.contains("\r\n"))
}
