import Foundation
import Testing
@testable import SnowSweepCore

private func schemaRuleURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Rules/rules.json")
}

@Test func bundledRulebookIsSchema051AndCoversCriticalData() throws {
    let engine = try RuleEngine(jsonURL: schemaRuleURL())
    #expect(engine.ruleBook.version == "0.5.2")
    #expect(engine.ruleBook.rules.count == 89)
    #expect(engine.ruleBook.protectedPaths.contains("~/Library/CloudStorage/**"))
    #expect(engine.ruleBook.protectedPaths.contains("~/Library/Group Containers/**"))
    #expect(engine.ruleBook.protectedPaths.contains("~/Library/Containers/*/Data/Documents/**"))

    let chrome = try #require(engine.ruleBook.rules.first { $0.id == "browser-chrome-cache" })
    #expect(chrome.pathPattern == "~/Library/Caches/Google/Chrome/**")
    #expect(chrome.sourceKind == "official")

    let archives = try #require(engine.ruleBook.rules.first { $0.id == "xcode-archives" })
    #expect(archives.risk == .protected)
    #expect(archives.actionType == .protect)

    let docker = try #require(engine.ruleBook.rules.first { $0.id == "docker-vm-disk" })
    #expect(docker.actionType == .guide)
    #expect(docker.guide?.contains("docker system prune") == true)
}

@Test func adobeTempAndBrowserCloneRulesPenetrateProtectionList() throws {
    let engine = try RuleEngine(jsonURL: schemaRuleURL())

    // 命中 /System/Volumes/** 保护清单，靠 allowOverrideProtection 穿透。
    let adobe = engine.verdict(for: ScanItem(
        path: "/System/Volumes/Data/.adobeTemp/D275756D-2A6C-4CB0-A8B8-CA490F6A94FD/2/universal",
        sizeBytes: 1024
    ))
    #expect(adobe.risk == .review)
    #expect(adobe.ruleID == "adobe-installer-temp")
    #expect(adobe.needConfirm)

    // 命中 /private/var/** 保护清单，靠 allowOverrideProtection 穿透。
    let clone = engine.verdict(for: ScanItem(
        path: "/private/var/folders/tk/vd218wg9663cyjkkm7tflrcr0000gn/X/com.microsoft.edgemac.code_sign_clone/code_sign_clone.No6SeO",
        sizeBytes: 1024
    ))
    #expect(clone.risk == .review)
    #expect(clone.ruleID == "browser-codesign-clone")
    #expect(clone.needConfirm)
}

@Test func guideActionNeverBecomesCleanable() throws {
    let book = RuleBook(
        version: "test",
        updatedAt: nil,
        protectedPaths: [],
        rules: [
            Rule(
                id: "guide-only",
                risk: .review,
                name: "引导",
                pathPattern: "~/Library/Caches/SnowSweepGuide/**",
                reason: "只在应用内处理",
                actionType: .guide,
                guide: "请在应用内清理"
            )
        ]
    )
    let engine = try RuleEngine(ruleBook: book)
    let verdict = engine.verdict(for: ScanItem(
        path: "~/Library/Caches/SnowSweepGuide/a", sizeBytes: 10
    ))
    #expect(verdict.risk == .protected)
    #expect(verdict.needConfirm)
    #expect(!verdict.defaultSelected)
    #expect(verdict.guide == "请在应用内清理")
}

@Test func trashRuleGuideReachesVerdict() throws {
    let book = RuleBook(
        version: "test",
        updatedAt: nil,
        protectedPaths: [],
        rules: [
            Rule(
                id: "trash-with-guide",
                risk: .review,
                name: "带处理前提的缓存",
                pathPattern: "~/Movies/SnowSweepGuideCache/**",
                reason: "缓存可重建，但要先退出应用",
                actionType: .trash,
                requiresAppQuit: true,
                guide: "先退出应用，再核对缓存里的素材副本。"
            )
        ]
    )
    let engine = try RuleEngine(ruleBook: book)
    let verdict = engine.verdict(for: ScanItem(
        path: "~/Movies/SnowSweepGuideCache/a", sizeBytes: 10
    ))
    #expect(verdict.risk == .review)
    #expect(verdict.guide == "先退出应用，再核对缓存里的素材副本。")
    #expect(verdict.explanation.contains("缓存可重建"))
    #expect(!verdict.explanation.contains("素材副本"))
}

@Test func protectRuleNeverShowsGuide() throws {
    let book = RuleBook(
        version: "test",
        updatedAt: nil,
        protectedPaths: [],
        rules: [
            Rule(
                id: "protected-with-guide",
                risk: .protected,
                name: "受保护数据",
                pathPattern: "~/Library/SnowSweepProtected/**",
                reason: "用户数据，不进入清理",
                actionType: .protect,
                guide: "请在应用内清理，不要直接删目录。"
            )
        ]
    )
    let engine = try RuleEngine(ruleBook: book)
    let verdict = engine.verdict(for: ScanItem(
        path: "~/Library/SnowSweepProtected/a", sizeBytes: 10
    ))
    #expect(verdict.risk == .protected)
    #expect(verdict.guide == nil)
    #expect(!verdict.defaultSelected)
}

@Test func minAgeDowngradesFreshSafeRule() throws {
    let book = RuleBook(
        version: "test",
        updatedAt: nil,
        protectedPaths: [],
        rules: [
            Rule(
                id: "aged-cache",
                risk: .safe,
                name: "旧缓存",
                pathPattern: "~/Library/Caches/SnowSweepAged/**",
                reason: "旧了才清",
                minAgeDays: 30
            )
        ]
    )
    let engine = try RuleEngine(ruleBook: book)

    let fresh = ScanItem(
        path: "~/Library/Caches/SnowSweepAged/a",
        sizeBytes: 10,
        modifiedAt: Date()
    )
    let freshVerdict = engine.verdict(for: fresh)
    #expect(freshVerdict.risk == .review)
    #expect(freshVerdict.evidence.contains("min-age:30"))

    let old = ScanItem(
        path: "~/Library/Caches/SnowSweepAged/a",
        sizeBytes: 10,
        modifiedAt: Date().addingTimeInterval(-90 * 86_400)
    )
    #expect(engine.verdict(for: old).risk == .safe)
}

@Test func excludePatternsSkipMatchedSubtree() throws {
    let book = RuleBook(
        version: "test",
        updatedAt: nil,
        protectedPaths: [],
        rules: [
            Rule(
                id: "cache-with-exclude",
                risk: .safe,
                name: "缓存",
                pathPattern: "~/Library/Caches/**",
                reason: "普通缓存",
                excludePatterns: ["~/Library/Caches/SnowSweepKeep/**"]
            )
        ]
    )
    let engine = try RuleEngine(ruleBook: book)
    #expect(engine.verdict(for: ScanItem(
        path: "~/Library/Caches/SnowSweepKeep/a", sizeBytes: 1
    )).risk == .unknown)
    #expect(engine.verdict(for: ScanItem(
        path: "~/Library/Caches/Other/a", sizeBytes: 1
    )).risk == .safe)
}

@Test func validatorRejectsSafeCommunityRule() {
    let json = """
    {"version":"0.5.0","protectedPaths":[],"rules":[
      {"id":"community-safe","risk":"safe","name":"缓存","pathPattern":"~/Library/Caches/X/**",
       "reason":"测试","needConfirm":false,"sourceKind":"community","confidence":0.7}
    ]}
    """
    let issues = RuleBookValidator.validate(jsonData: Data(json.utf8))
    #expect(issues.contains { $0.path == "$.rules[0]" && $0.message.contains("不能直接标 safe") })
}
