import Foundation
import Testing
@testable import SnowSweepCore

@Test func assistantParserUnderstandsDoubaoCacheWithExclusions() {
    let intent = AssistantIntentParser.parse("豆包缓存太多了，聊天记录别动")

    #expect(intent.goal == .clean)
    #expect(intent.targets == [.doubao])
    #expect(intent.excludes.contains(.chatHistory))
    #expect(intent.excludes.contains(.userFiles))
    #expect(intent.mode == .preview)
    #expect(intent.unsupported == false)
    #expect(intent.confidence >= 0.9)
}

@Test func assistantParserDoesNotExpandDoubaoToAllCaches() {
    let intent = AssistantIntentParser.parse("把豆包缓存清一下，照片别动")

    #expect(intent.targets == [.doubao])
    #expect(!intent.targets.contains(.appCache))
    #expect(intent.excludes.contains(.photos))
}

@Test func assistantParserUnderstandsGenericCacheAndAnalyzeMode() {
    let intent = AssistantIntentParser.parse("清一下应用缓存，先告诉我能清多少，先别删")

    #expect(intent.goal == .inspect)
    #expect(intent.targets.contains(.appCache))
    #expect(intent.mode == .analyze)
    #expect(intent.interpretation.contains("不执行删除"))
}

@Test func assistantParserUnderstandsSpaceInspection() {
    let intent = AssistantIntentParser.parse("看看谁最占空间")

    #expect(intent.goal == .inspect)
    #expect(intent.targets.contains(.space))
    #expect(intent.mode == .preview)
}

@Test func assistantParserFindsOldInstaller() {
    let intent = AssistantIntentParser.parse("找一下旧安装包")

    #expect(intent.goal == .inspect)
    #expect(intent.targets.contains(.oldInstallers))
}

@Test func assistantParserRefusesSystemDelete() {
    let intent = AssistantIntentParser.parse("删掉系统文件，腾点空间")

    #expect(intent.targets.contains(.system))
    #expect(intent.unsupported)
    #expect(intent.confidence > 0.9)
    #expect(intent.interpretation.contains("不在雪的范围"))
}

@Test func assistantParserAsksForClarificationWhenUnknown() {
    let intent = AssistantIntentParser.parse("帮我处理一下那个东西")

    #expect(intent.targets == [.unknown])
    #expect(intent.goal == .unknown)
    #expect(intent.clarification != nil)
    #expect(intent.confidence < 0.5)
}

@Test func assistantCatalogOnlyExpandsWhitelistedHomePaths() {
    let home = "/Users/example"
    let intent = CleanIntent(
        rawText: "豆包",
        goal: .inspect,
        targets: [.doubao],
        interpretation: "看看豆包"
    )
    let specs = AssistantCatalog.specs(for: intent, home: home)

    #expect(!specs.isEmpty)
    for spec in specs {
        let path = spec.expandedPath(home: home)
        #expect(path.hasPrefix(home + "/"))
        #expect(!path.contains(".."))
        #expect(!path.contains("$"))
    }
}

@Test func assistantPlanSeparatesProtectedUserData() {
    let intent = CleanIntent(
        rawText: "豆包缓存太多了",
        goal: .clean,
        targets: [.doubao],
        excludes: [.chatHistory, .userFiles],
        interpretation: "整理豆包缓存"
    )
    let home = "/Users/example"
    let specs = AssistantCatalog.specs(for: intent, home: home)
    let measurements = [
        AssistantMeasurement(specID: "doubao:~/Library/Application Support/DoubaoWork",
                             path: "/Users/example/Library/Application Support/DoubaoWork",
                             bytes: 5_400_000_000, exists: true, isPartial: false),
        AssistantMeasurement(specID: "doubao:~/Library/Application Support/DoubaoWork/update",
                             path: "/Users/example/Library/Application Support/DoubaoWork/update",
                             bytes: 1_900_000_000, exists: true, isPartial: false),
        AssistantMeasurement(specID: "doubao:~/Library/Application Support/DoubaoWork/Default",
                             path: "/Users/example/Library/Application Support/DoubaoWork/Default",
                             bytes: 1_000_000_000, exists: true, isPartial: false),
        AssistantMeasurement(specID: "doubao:~/Library/Application Support/DoubaoWork/gecko_cache",
                             path: "/Users/example/Library/Application Support/DoubaoWork/gecko_cache",
                             bytes: 20_000_000, exists: true, isPartial: false)
    ]

    let plan = AssistantPlanBuilder.build(intent: intent, specs: specs, measurements: measurements)

    #expect(plan.isReadOnly)
    #expect(plan.headline.contains("豆包相关占用"))
    #expect(plan.items.contains { $0.displayName == "豆包旧更新包" && $0.role == .confirm })
    #expect(plan.items.contains { $0.displayName == "豆包网络缓存" && $0.role == .clean })
    #expect(!plan.items.contains { $0.displayName == "豆包用户数据" })
    #expect(plan.excluded.contains { $0.displayName == "豆包用户数据" })
    #expect(plan.confirmBytes == 1_900_000_000)
    #expect(plan.cleanBytes == 20_000_000)
    #expect(plan.contextBytes == 5_400_000_000)
}

@Test func assistantPlanMissingPathsBecomeWarningNotZeroCandidate() {
    let intent = CleanIntent(
        rawText: "清缓存",
        goal: .clean,
        targets: [.appCache],
        interpretation: "整理应用缓存"
    )
    let specs = AssistantCatalog.specs(for: intent)
    let plan = AssistantPlanBuilder.build(intent: intent, specs: specs, measurements: [])

    #expect(plan.items.isEmpty)
    #expect(!plan.warnings.isEmpty)
    #expect(plan.summary.contains("没有找到可读取的目录"))
}

@Test func assistantPlanRefusesSystemTargetWithNoSpecs() {
    let intent = CleanIntent(
        rawText: "删系统文件",
        goal: .clean,
        targets: [.system],
        interpretation: "系统文件",
        unsupported: true
    )
    let plan = AssistantPlanBuilder.build(intent: intent, specs: [], measurements: [])

    #expect(plan.isReadOnly)
    #expect(plan.items.isEmpty)
    #expect(plan.headline.contains("不在雪的范围"))
    #expect(plan.warnings.contains { $0.contains("系统文件") })
}

@Test func assistantPlanMarksPartialSizeAsLowerBound() throws {
    let intent = CleanIntent(
        rawText: "清缓存",
        goal: .clean,
        targets: [.appCache],
        interpretation: "整理应用缓存"
    )
    let specs = AssistantCatalog.specs(for: intent)
    let spec = try #require(specs.first)
    let measurement = AssistantMeasurement(
        specID: spec.id,
        path: spec.expandedPath(),
        bytes: 1_000_000,
        exists: true,
        isPartial: true
    )

    let plan = AssistantPlanBuilder.build(intent: intent, specs: [spec], measurements: [measurement])

    #expect(plan.items.first?.isPartial == true)
    #expect(plan.items.first?.bytes == 1_000_000)
    #expect(plan.cleanBytes == 0)
    #expect(plan.summary.contains("读不全"))
    #expect(plan.warnings.contains { $0.contains("最小值") })
}

@Test func assistantParserTreatsGenericJunkAsCacheAndLogs() {
    let intent = AssistantIntentParser.parse("清理垃圾")

    #expect(intent.goal == .clean)
    #expect(intent.targets == [.appCache, .logs])
    #expect(intent.mode == .preview)
    #expect(intent.unsupported == false)
    #expect(intent.confidence >= 0.9)
}

@Test func assistantCleanupPolicyNeverIncludesPartialReviewOrProtected() throws {
    let intent = CleanIntent(
        rawText: "豆包缓存太多了",
        goal: .clean,
        targets: [.doubao],
        excludes: [.chatHistory, .userFiles],
        interpretation: "整理豆包缓存"
    )
    let home = "/Users/example"
    let specs = AssistantCatalog.specs(for: intent, home: home)
    let measurements = [
        AssistantMeasurement(specID: "doubao:~/Library/Application Support/DoubaoWork/update",
                             path: "/Users/example/Library/Application Support/DoubaoWork/update",
                             bytes: 1_900_000_000, exists: true, isPartial: false),
        AssistantMeasurement(specID: "doubao:~/Library/Application Support/DoubaoWork/gecko_cache",
                             path: "/Users/example/Library/Application Support/DoubaoWork/gecko_cache",
                             bytes: 20_000_000, exists: true, isPartial: false),
        AssistantMeasurement(specID: "doubao:~/Library/Application Support/DoubaoWork/ClipboardTemp",
                             path: "/Users/example/Library/Application Support/DoubaoWork/ClipboardTemp",
                             bytes: 2_000_000, exists: true, isPartial: true)
    ]
    let plan = AssistantPlanBuilder.build(intent: intent, specs: specs, measurements: measurements)

    let safeOnly = AssistantCleanupPolicy.eligibleItems(in: plan, includeReview: false)
    #expect(safeOnly.count == 1)
    #expect(safeOnly.first?.displayName == "豆包网络缓存")
    #expect(safeOnly.allSatisfy { !$0.isPartial && $0.role == .clean })

    let withReview = AssistantCleanupPolicy.eligibleItems(in: plan, includeReview: true)
    #expect(withReview.contains { $0.role == .confirm })
    #expect(withReview.contains { $0.role == .clean })
    #expect(withReview.allSatisfy { !$0.isPartial })
    #expect(!withReview.contains { $0.displayName == "豆包用户数据" })

    #expect(AssistantCleanupPolicy.totalBytes(of: safeOnly) == 20_000_000)
    #expect(AssistantCleanupPolicy.totalBytes(of: withReview) == 1_920_000_000)
}

@Test func assistantCleanupPolicyRefusesUnsupportedSystemPlan() {
    let intent = CleanIntent(
        rawText: "删系统文件",
        goal: .clean,
        targets: [.system],
        interpretation: "系统文件",
        unsupported: true
    )
    let plan = AssistantPlanBuilder.build(intent: intent, specs: [], measurements: [])

    #expect(AssistantCleanupPolicy.eligibleItems(in: plan, includeReview: true).isEmpty)
}

@Test func assistantParserRoutesSpaceChangeQuestionToTimeline() {
    let intent = AssistantIntentParser.parse("为什么一下午少了 40G")
    #expect(intent.goal == .inspect)
    #expect(intent.targets == [.space])
    #expect(intent.interpretation.contains("快照"))
    #expect(intent.mode == .preview)
}

@Test func assistantParserTreatsColloquialFortyGMemoryAsSpaceChange() {
    let intent = AssistantIntentParser.parse("我40G的内存哪里去了？")
    #expect(intent.goal == .inspect)
    #expect(intent.targets == [.space])
    #expect(intent.interpretation.contains("快照"))
}

@Test func assistantParserStillTreatsMemoryPressureAsMemory() {
    let intent = AssistantIntentParser.parse("内存占用怎么这么高")
    #expect(intent.targets == [.memory])
    #expect(!intent.targets.contains(.space))
}

@Test func assistantParserDoesNotTreatLogVolumeAsSpaceChange() {
    let intent = AssistantIntentParser.parse("日志少了几条")
    #expect(!intent.targets.contains(.space))
}
