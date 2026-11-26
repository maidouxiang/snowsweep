import Foundation
import Testing
@testable import SnowSweepCore

private func projectRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

@Test func builtinRulesAllHaveChineseNameAndReason() throws {
    let data = try Data(contentsOf: projectRoot().appendingPathComponent("Rules/rules.json"))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let rules = try #require(object?["rules"] as? [[String: Any]])
    #expect(!rules.isEmpty)
    for rule in rules {
        let id = rule["id"] as? String ?? "<无 id>"
        let name = rule["name"] as? String ?? ""
        let reason = rule["reason"] as? String ?? ""
        #expect(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(id) 缺少 name")
        #expect(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(id) 缺少 reason")
    }
}

@Test func specialCharacterPathsDoNotCrashRuleEngine() throws {
    let engine = try RuleEngine(jsonURL: projectRoot().appendingPathComponent("Rules/rules.json"))
    let paths = [
        "~/Library/Caches/中文 空格 \"引号\",逗号.txt",
        "~/Library/Caches/\(String(repeating: "超长", count: 400))/temp",
        "~/Library/Caches/emoji-\u{1F32F}-文件",
        ""
    ]
    for path in paths {
        let verdict = engine.verdict(for: ScanItem(path: path, sizeBytes: 0))
        #expect(["safe", "review", "protected", "unknown"].contains(verdict.risk.rawValue))
        #expect(!verdict.explanation.isEmpty)
    }
}

@Test func zeroByteItemIsStillJudged() throws {
    let engine = try RuleEngine(jsonURL: projectRoot().appendingPathComponent("Rules/rules.json"))
    let verdict = engine.verdict(for: ScanItem(path: "~/Library/Caches/empty", sizeBytes: 0))
    #expect(verdict.risk != .unknown)
    #expect(verdict.item.sizeBytes == 0)
}

@Test func confidenceThresholdBoundaryIsExact() {
    func verdict(_ confidence: Double) -> Verdict {
        Verdict(
            item: ScanItem(path: "~/.config/x/state.json", sizeBytes: 1),
            risk: .review, explanation: "测试", aiExplanation: "说明", confidence: confidence
        )
    }
    #expect(!verdict(0.6).isLowConfidence)
    #expect(verdict(0.59).isLowConfidence)
    #expect(!Verdict(item: ScanItem(path: "x", sizeBytes: 1), risk: .safe, explanation: "无模型").isLowConfidence)
}

@Test func safeWithNeedConfirmIsNeverDefaultSelected() {
    let verdict = Verdict(
        item: ScanItem(path: "~/.Trash/a", sizeBytes: 1),
        risk: .safe, explanation: "历史数据：该规则现在应标为 review", needConfirm: true
    )
    #expect(!verdict.defaultSelected)
}

@Test func userOverlayExportImportRoundTrip() throws {
    let rule = Rule(
        id: "my-cache", risk: .safe, name: "我的缓存", pathPattern: "~/MyProject/**/cache/**",
        reason: "自己项目的缓存", needConfirm: false, source: "user"
    )
    let overlay = UserRuleOverlay(protectedPaths: ["~/MyProject/private/**"], rules: [rule])
    let data = try RuleBookMigrator.exportOverlay(overlay)
    let restored = try RuleBookMigrator.importOverlay(jsonData: data)
    #expect(restored.schemaVersion == overlay.schemaVersion)
    #expect(restored.protectedPaths == overlay.protectedPaths)
    #expect(restored.rules == overlay.rules)

    let merged = RuleBookMigrator.merge(
        builtIn: RuleBook(version: "1", updatedAt: nil, protectedPaths: [], rules: []),
        overlay: restored
    )
    #expect(merged.rules.first?.source == "user")
    #expect(merged.protectedPaths.contains("~/MyProject/private/**"))
}

@Test func userOverlayImportRejectsBuiltinSourceAndOverride() throws {
    let json = """
    {"schemaVersion":1,"protectedPaths":[],"rules":[{"id":"bad","risk":"safe","name":"坏规则","pathPattern":"~/X/**","reason":"测试","needConfirm":false,"source":"builtin","allowOverrideProtection":true}]}
    """
    #expect(throws: OverlayIOError.self) {
        try RuleBookMigrator.importOverlay(jsonData: Data(json.utf8))
    }
}

@Test func schemaRejectsCapitalizedRisk() throws {
    let text = try String(contentsOf: projectRoot().appendingPathComponent("Rules/rules.json"), encoding: .utf8)
    let broken = Data(text
        .replacingOccurrences(of: "\"risk\": \"safe\"", with: "\"risk\": \"Safe\"").utf8)
    let issues = RuleBookValidator.validate(jsonData: broken)
    #expect(issues.contains { $0.severity == .error && $0.message.contains("风险等级") })
}
