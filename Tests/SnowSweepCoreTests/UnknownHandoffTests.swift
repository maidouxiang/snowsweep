import Foundation
import Testing
@testable import SnowSweepCore

private func draftJSON(id: String, path: String = "~/Library/Caches/DraftApp/**") -> Data {
    Data("""
    {
      "kind": "snow-rule-draft",
      "schemaVersion": 1,
      "caseID": "case-1",
      "generatedAt": "2026-11-25T12:00:00Z",
      "source": "independent-agent",
      "notes": "只读草稿",
      "rules": [
        {
          "id": "\(id)",
          "risk": "review",
          "name": "草稿缓存",
          "pathPattern": "\(path)",
          "reason": "独立 agent 根据报告起草",
          "needConfirm": true,
          "priority": 10,
          "actionType": "trash",
          "source": "builtin",
          "allowOverrideProtection": true,
          "sourceKind": "community",
          "confidence": 0.5
        }
      ]
    }
    """.utf8)
}

private func mixedDraftJSON() -> Data {
    Data("""
    {
      "kind": "snow-rule-draft",
      "schemaVersion": 1,
      "caseID": "case-mixed",
      "generatedAt": "2026-11-25T12:00:00Z",
      "source": "independent-agent",
      "notes": "一条安全，一条与保护路径重叠",
      "rules": [
        {
          "id": "draft-safe",
          "risk": "review",
          "name": "安全缓存",
          "pathPattern": "~/Library/Caches/Safe/**",
          "reason": "独立 agent 根据报告起草",
          "needConfirm": true,
          "priority": 10,
          "actionType": "trash",
          "source": "builtin",
          "allowOverrideProtection": true,
          "sourceKind": "community",
          "confidence": 0.5
        },
        {
          "id": "draft-protected",
          "risk": "review",
          "name": "保护子目录",
          "pathPattern": "~/Protected/2026/**",
          "reason": "独立 agent 试图细抠保护目录",
          "needConfirm": true,
          "priority": 10,
          "actionType": "trash",
          "source": "builtin",
          "allowOverrideProtection": true,
          "sourceKind": "community",
          "confidence": 0.5
        }
      ]
    }
    """.utf8)
}

private struct HandoffFixture {
    let registry: UserRuleRegistry
    let builtinURL: URL
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snow-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        registry = UserRuleRegistry(directoryURL: root.appendingPathComponent("registry", isDirectory: true))
        builtinURL = root.appendingPathComponent("builtin.json")
        let builtin = """
        {
          "version": "0.5.0",
          "protectedPaths": ["~/Protected/**"],
          "rules": [
            {"id":"protected-keep","risk":"protected","name":"受保护资料","pathPattern":"~/Protected/**",
             "reason":"内置保护","needConfirm":true,"actionType":"protect","source":"builtin"}
          ]
        }
        """
        try Data(builtin.utf8).write(to: builtinURL)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Test func unknownCaseReportRedactsNameAndCarriesDraftContract() throws {
    let builtin = RuleBook(
        version: "test",
        updatedAt: nil,
        protectedPaths: [],
        rules: [
            Rule(
                id: "zeta-cache",
                risk: .review,
                name: "Zeta 缓存",
                pathPattern: "~/Library/Caches/Zeta/**",
                reason: "Zeta 应用的可重建缓存",
                needConfirm: true
            )
        ]
    )
    let report = UnknownCaseReportBuilder.build(
        query: "Zeta 缓存太大，能清吗？ /Users/test/Secret",
        reason: "没有命中规则：Zeta 缓存",
        builtin: builtin,
        redactor: ReportRedactor(username: "test")
    )

    #expect(report.query.contains("~/Secret"))
    #expect(!report.query.contains("/Users/test"))
    #expect(report.closestRules.first?.id == "zeta-cache")
    #expect(report.markdown.contains("snow-rule-draft"))
    #expect(report.markdown.contains("不包含文件正文"))
    #expect(report.markdown.contains("不要返回 shell"))
}

@Test func unknownCaseStoreSurvivesCorruptLineAndDeletesOne() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("snow-cases-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = UnknownCaseStore(fileURL: root.appendingPathComponent("cases.jsonl"))
    let first = UnknownCase(query: "第一个未知问题", reason: "未命中")
    let second = UnknownCase(query: "第二个未知问题", reason: "未命中")
    try store.append(first)
    try store.append(second)
    let handle = try FileHandle(forWritingTo: store.fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{bad json}\n".utf8))
    try handle.close()

    let loaded = try store.cases()
    #expect(loaded.count == 2)
    try store.remove(id: first.id)
    #expect(try store.cases().count == 1)
    #expect(try store.cases().first?.query == "第二个未知问题")
}

@Test func ruleDraftNormalizesToUserOverlayAndRejectsWrongKind() throws {
    let normalized = try RuleDraftImporter.normalizedOverlayData(from: draftJSON(id: "draft-cache"))
    let object = try #require(JSONSerialization.jsonObject(with: normalized) as? [String: Any])
    let rules = try #require(object["rules"] as? [[String: Any]])
    #expect(rules.first?["source"] as? String == "user")
    #expect(rules.first?["allowOverrideProtection"] as? Bool == false)

    let wrong = Data("""
    {"kind":"draft","schemaVersion":1,"rules":[]}
    """.utf8)
    #expect(throws: RuleDraftError.self) {
        try RuleDraftImporter.normalizedOverlayData(from: wrong)
    }
}

@Test func draftImportStaysDisabledUntilTrialThenCanEnable() throws {
    let fixture = try HandoffFixture()
    defer { fixture.cleanUp() }
    let summary = try fixture.registry.importDrafts(
        jsonData: draftJSON(id: "draft-cache"),
        source: "agent.json",
        builtinURL: fixture.builtinURL
    )
    #expect(summary.importedIDs == ["draft-cache"])
    #expect(summary.enabledRules == 0)

    let state = fixture.registry.loadStateLenient()
    #expect(state.isDraft("draft-cache"))
    #expect(!state.isTrialed("draft-cache"))
    #expect(throws: UserRuleRegistryError.self) {
        try fixture.registry.setEnabled("draft-cache", enabled: true)
    }

    try fixture.registry.markTrialed("draft-cache")
    try fixture.registry.setEnabled("draft-cache", enabled: true)
    let engine = try fixture.registry.loadEngine(builtinURL: fixture.builtinURL)
    #expect(engine.ruleBook.rules.contains { $0.id == "draft-cache" && $0.source == "user" })
}

@Test func reimportingDraftClearsEarlierTrial() throws {
    let fixture = try HandoffFixture()
    defer { fixture.cleanUp() }
    _ = try fixture.registry.importDrafts(
        jsonData: draftJSON(id: "draft-cache"),
        source: "v1.json",
        builtinURL: fixture.builtinURL
    )
    try fixture.registry.markTrialed("draft-cache")
    _ = try fixture.registry.importDrafts(
        jsonData: draftJSON(id: "draft-cache", path: "~/Library/Caches/DraftApp2/**"),
        source: "v2.json",
        builtinURL: fixture.builtinURL
    )

    let state = fixture.registry.loadStateLenient()
    #expect(state.isDraft("draft-cache"))
    #expect(!state.isTrialed("draft-cache"))
    #expect(throws: UserRuleRegistryError.self) {
        try fixture.registry.setEnabled("draft-cache", enabled: true)
    }
}

@Test func draftCannotCarveOutProtectedSubfolder() throws {
    let fixture = try HandoffFixture()
    defer { fixture.cleanUp() }
    #expect(throws: UserRuleRegistryError.self) {
        try fixture.registry.importDrafts(
            jsonData: draftJSON(id: "protected-sub", path: "~/Protected/2026/**"),
            source: "bad-agent.json",
            builtinURL: fixture.builtinURL
        )
    }
    #expect(try fixture.registry.loadCatalog().rules.isEmpty)
}

@Test func mixedDraftImportsSafeSubsetAndListsProtectedRule() throws {
    let fixture = try HandoffFixture()
    defer { fixture.cleanUp() }
    let summary = try fixture.registry.importDrafts(
        jsonData: mixedDraftJSON(),
        source: "mixed-agent.json",
        builtinURL: fixture.builtinURL
    )
    #expect(summary.importedIDs == ["draft-safe"])
    #expect(summary.rejectedRules.count == 1)
    #expect(summary.rejectedRules.first?.id == "draft-protected")
    #expect(summary.rejectedRules.first?.reasons.joined().contains("保护") == true)

    let catalog = try fixture.registry.loadCatalog()
    #expect(catalog.rules.map(\.id) == ["draft-safe"])
    #expect(!catalog.rules.contains { $0.id == "draft-protected" })
    let state = fixture.registry.loadStateLenient()
    #expect(state.isDraft("draft-safe"))
}

@Test func draftWithUnknownCommandFieldIsRejectedByLocalSchema() throws {
    let fixture = try HandoffFixture()
    defer { fixture.cleanUp() }
    let malicious = Data("""
    {
      "kind":"snow-rule-draft","schemaVersion":1,
      "rules":[{"id":"bad","risk":"safe","name":"坏草稿","pathPattern":"~/Library/Caches/Bad/**",
      "reason":"x","actionType":"trash","source":"user","command":"rm -rf ~"}]
    }
    """.utf8)
    #expect(throws: (any Error).self) {
        try fixture.registry.importDrafts(
            jsonData: malicious,
            source: "bad.json",
            builtinURL: fixture.builtinURL
        )
    }
}

@Test func unknownCaseStoreRemovesOnlySelectedReport() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("snow-cases-delete-\(UUID().uuidString)", isDirectory: true)
    let fileURL = root.appendingPathComponent("unknown-cases.jsonl")
    let store = UnknownCaseStore(fileURL: fileURL)
    let builtin = RuleBook(version: "test", updatedAt: nil, protectedPaths: [], rules: [])
    let first = UnknownCaseReportBuilder.build(
        query: "ZetaBig 的离线素材应该交给谁审核？",
        reason: "没有命中规则",
        builtin: builtin
    )
    let second = UnknownCaseReportBuilder.build(
        query: "另一个未知应用缓存",
        reason: "没有命中规则",
        builtin: builtin
    )
    try store.append(first)
    try store.append(second)
    #expect(try store.cases(limit: Int.max).count == 2)

    try store.remove(id: first.id)
    let remaining = try store.cases(limit: Int.max)
    #expect(remaining.count == 1)
    #expect(remaining.first?.id == second.id)
    #expect(remaining.first?.query == "另一个未知应用缓存")
    try? FileManager.default.removeItem(at: root)
}
