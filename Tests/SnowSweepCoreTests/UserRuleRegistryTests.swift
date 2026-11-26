import Foundation
import Testing
@testable import SnowSweepCore

private struct RegistryFixture {
    let registry: UserRuleRegistry
    let builtinURL: URL
    let builtin: RuleBook
    let home: URL
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snow-user-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let registry = UserRuleRegistry(directoryURL: root.appendingPathComponent("registry", isDirectory: true))
        let builtinURL = root.appendingPathComponent("builtin.json")
        let builtinJSON = """
        {
          "version": "0.5.0",
          "protectedPaths": ["~/Protected/**"],
          "rules": [
            {"id":"protected-keep","risk":"protected","name":"受保护资料","pathPattern":"~/Protected/**",
             "reason":"内置保护","needConfirm":true,"actionType":"protect","source":"builtin"},
            {"id":"old-app-cache","risk":"safe","name":"旧应用缓存","pathPattern":"~/Library/Caches/OldApp/**",
             "reason":"可重建缓存","needConfirm":false,"actionType":"trash","source":"builtin"}
          ]
        }
        """
        try Data(builtinJSON.utf8).write(to: builtinURL)
        self.registry = registry
        self.builtinURL = builtinURL
        self.builtin = try UserRuleRegistry.loadBuiltin(url: builtinURL)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func overlayJSON(id: String, path: String, action: String = "trash", risk: String = "safe") -> Data {
    Data("""
    {
      "schemaVersion": 1,
      "protectedPaths": [],
      "rules": [
        {"id":"\(id)","risk":"\(risk)","name":"测试规则","pathPattern":"\(path)",
         "reason":"本地试扫","needConfirm":false,"actionType":"\(action)","source":"user"}
      ]
    }
    """.utf8)
}

@Test func importedUserRuleIsDisabledByDefault() throws {
    let fixture = try RegistryFixture()
    defer { fixture.cleanUp() }
    let summary = try fixture.registry.importRules(
        jsonData: overlayJSON(id: "new-cache", path: "~/Library/Caches/NewApp/**"),
        source: "new-cache.json",
        builtinURL: fixture.builtinURL
    )
    #expect(summary.importedIDs == ["new-cache"])
    #expect(summary.enabledRules == 0)
    #expect(try fixture.registry.loadCatalog().rules.count == 1)

    let engine = try fixture.registry.loadEngine(builtinURL: fixture.builtinURL)
    #expect(!engine.ruleBook.rules.contains { $0.id == "new-cache" })
}

@Test func enablingAndDisablingUserRuleTakesEffectWithoutRebuild() throws {
    let fixture = try RegistryFixture()
    defer { fixture.cleanUp() }
    _ = try fixture.registry.importRules(
        jsonData: overlayJSON(id: "new-cache", path: "~/Library/Caches/NewApp/**"),
        source: "new-cache.json",
        builtinURL: fixture.builtinURL
    )
    try fixture.registry.setEnabled("new-cache", enabled: true)

    let enabled = try fixture.registry.loadEngine(builtinURL: fixture.builtinURL)
    #expect(enabled.ruleBook.rules.contains { $0.id == "new-cache" && $0.source == "user" })
    #expect(fixture.registry.enabledCount() == 1)

    try fixture.registry.setEnabled("new-cache", enabled: false)
    let disabled = try fixture.registry.loadEngine(builtinURL: fixture.builtinURL)
    #expect(!disabled.ruleBook.rules.contains { $0.id == "new-cache" })
    #expect(fixture.registry.enabledCount() == 0)
}

@Test func userRuleCannotOverrideBuiltInProtectionRule() throws {
    let fixture = try RegistryFixture()
    defer { fixture.cleanUp() }
    #expect(throws: UserRuleRegistryError.self) {
        try fixture.registry.importRules(
            jsonData: overlayJSON(id: "protected-keep", path: "~/Protected/**"),
            source: "malicious.json",
            builtinURL: fixture.builtinURL
        )
    }
    #expect(try fixture.registry.loadCatalog().rules.isEmpty)
}

@Test func userRuleCannotCarveASubfolderOutOfBuiltInProtection() throws {
    let fixture = try RegistryFixture()
    defer { fixture.cleanUp() }
    #expect(throws: UserRuleRegistryError.self) {
        try fixture.registry.importRules(
            jsonData: overlayJSON(id: "protected-sub", path: "~/Protected/2024/**"),
            source: "narrow.json",
            builtinURL: fixture.builtinURL
        )
    }
}

@Test func userRuleMustStayInsideHomeAndCannotSweepWholeHome() throws {
    let fixture = try RegistryFixture()
    defer { fixture.cleanUp() }
    #expect(throws: UserRuleRegistryError.self) {
        try fixture.registry.importRules(
            jsonData: overlayJSON(id: "abs-rule", path: "/Library/Caches/Anything/**"),
            source: "abs.json",
            builtinURL: fixture.builtinURL
        )
    }
    #expect(throws: UserRuleRegistryError.self) {
        try fixture.registry.importRules(
            jsonData: overlayJSON(id: "all-home", path: "~/**"),
            source: "broad.json",
            builtinURL: fixture.builtinURL
        )
    }
}

@Test func reimportReplacesBodyButKeepsItDisabled() throws {
    let fixture = try RegistryFixture()
    defer { fixture.cleanUp() }
    _ = try fixture.registry.importRules(
        jsonData: overlayJSON(id: "new-cache", path: "~/Library/Caches/NewApp/**"),
        source: "v1.json",
        builtinURL: fixture.builtinURL
    )
    try fixture.registry.setEnabled("new-cache", enabled: true)

    let summary = try fixture.registry.importRules(
        jsonData: overlayJSON(id: "new-cache", path: "~/Library/Caches/NewApp-2/**"),
        source: "v2.json",
        builtinURL: fixture.builtinURL
    )
    #expect(summary.replacedIDs == ["new-cache"])
    #expect(summary.enabledRules == 0)
    #expect(try fixture.registry.loadCatalog().rules.first?.pathPattern == "~/Library/Caches/NewApp-2/**")
    #expect(try fixture.registry.loadEngine(builtinURL: fixture.builtinURL).ruleBook.rules.contains { $0.id == "new-cache" } == false)
}

@Test func trialFindsMatchingFilesWithoutDeleting() throws {
    let fixture = try RegistryFixture()
    defer { fixture.cleanUp() }
    let junk = fixture.home.appendingPathComponent("Caches/Junk", isDirectory: true)
    try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 1024).write(to: junk.appendingPathComponent("a.bin"))
    try Data(repeating: 0x42, count: 2048).write(to: junk.appendingPathComponent("b.bin"))

    let rule = Rule(
        id: "trial-junk",
        risk: .safe,
        name: "试扫垃圾",
        pathPattern: junk.path + "/**",
        reason: "试扫",
        source: "user"
    )
    let result = UserRuleRegistry.trial(rule: rule, builtin: fixture.builtin, home: fixture.home.path)
    #expect(result.rootCount == 1)
    #expect(result.itemCount >= 1)
    #expect(result.totalBytes > 0)
    #expect(result.errorMessage == nil)
    #expect(FileManager.default.fileExists(atPath: junk.appendingPathComponent("a.bin").path))
    #expect(FileManager.default.fileExists(atPath: junk.appendingPathComponent("b.bin").path))
}
