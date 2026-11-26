import Foundation
import Testing
@testable import SnowSweepCore

@Test func plainChineseFlagsBannedOfficialese() {
    #expect(PlainChinese.forbiddenHits(in: "旨在清理缓存") == ["旨在"])
    let hits = PlainChinese.forbiddenHits(in: "用于缓存，从而加快启动")
    #expect(hits.contains("用于") && hits.contains("从而"))
    #expect(PlainChinese.isPlain("这是软件缓存，删掉会自己重建"))
}

@Test func plainChineseLimitsOneSentenceToFortyCharacters() {
    let forty = String(repeating: "缓", count: 40)
    let fortyOne = String(repeating: "缓", count: 41)
    #expect(PlainChinese.isWithinLength(forty))
    #expect(!PlainChinese.isWithinLength(fortyOne))
    #expect(!PlainChinese.isPlain(fortyOne))
}

@Test func glossaryKeepsChineseMainLineAndEnglishOriginal() throws {
    let glossary = try Glossary.loadBundled()
    #expect(!glossary.entries.isEmpty)
    for entry in glossary.entries {
        #expect(!entry.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!entry.zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!entry.say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(PlainChinese.forbiddenHits(in: entry.zh + entry.say).isEmpty,
                "词典词条不应出现书面套话：\(entry.en)")
    }
}

#if canImport(FoundationModels) && !SNOWSWEEP_DISABLE_AI
@Test func plannerInstructionsForbidOfficialeseAndKeepPromptVersion() {
    #expect(AIPolicy().promptVersion == "snow-ai-v2")
    let instructions = AIPlanner.instructions
    #expect(instructions.contains("不要翻译腔"))
    #expect(instructions.contains("40 个汉字"))
    for word in PlainChinese.forbiddenWords {
        #expect(instructions.contains(word))
    }
}
#endif

@Test func modelSampleChineseCanBeCheckedWithoutChangingRisk() {
    let model = ModelSuggestion(level: .review, what: "这是应用缓存，删掉会自动重建",
                                impact: "清理后首次打开会慢一点", confidence: 0.7,
                                promptVersion: "snow-ai-v2")
    #expect(PlainChinese.isPlain(model.what))
    #expect(PlainChinese.isPlain(model.impact))
    let bad = ModelSuggestion(level: .safe, what: "旨在用于清理临时文件",
                              impact: "将会进行重建", confidence: 0.9,
                              promptVersion: "snow-ai-v2")
    #expect(!PlainChinese.isPlain(bad.what))
    #expect(bad.level == .safe, "中文检查只标黄，不改变风险等级")
}
