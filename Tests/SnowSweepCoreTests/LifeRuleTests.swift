import Foundation
import Testing
@testable import SnowSweepCore

private func projectRules() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Rules/rules.json")
}

@Test func lifeScenarioCachesAreSafeAndSpecific() throws {
    let engine = try RuleEngine(jsonURL: projectRules())
    let cases: [(String, String)] = [
        ("~/Library/Caches/com.tencent.xinWeChat/a.db", "chat-cache-tencent"),
        ("~/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches/a.db", "chat-cache-tencent-sandbox"),
        ("~/Library/Caches/com.bytedance.macos.feishu/a.tmp", "chat-cache-bytedance"),
        ("~/Library/Caches/com.alibaba.DingTalkMac/a.tmp", "chat-cache-alibaba"),
        ("~/Library/Caches/com.kingsoft.wpsoffice.mac/a.tmp", "office-cache-kingsoft"),
        ("~/Library/Caches/com.microsoft.Edge/Cache/a", "browser-edge-cache"),
        ("~/Library/Caches/Microsoft Edge/Cache/a", "browser-edge-legacy"),
        ("~/Library/Caches/com.microsoft.edgemac/Cache/a", "browser-edge-app"),
        ("~/Library/Caches/com.work.pc.doubao.browser/Cache/a", "chat-cache-doubao-browser"),
        ("~/Library/Caches/company.thebrowser.Browser/Cache/a", "browser-arc-cache"),
        ("~/Library/Caches/Adobe/Premiere Pro/a.tmp", "premiere-media-cache"),
        ("~/Library/Caches/Homebrew/downloads/a.tar.gz", "homebrew-cache"),
        ("~/Library/Caches/pip/http/a", "pip-cache")
    ]
    for (path, ruleID) in cases {
        let verdict = engine.verdict(for: ScanItem(path: path, sizeBytes: 1))
        #expect(verdict.risk == .safe, "\(ruleID) 应判 safe")
        #expect(verdict.ruleID == ruleID, "\(ruleID) 应优先命中具体规则")
        #expect(!verdict.needConfirm, "\(ruleID) 不应要求二次确认")
    }
}

@Test func lifeScenarioReviewRulesNeedConfirmation() throws {
    let engine = try RuleEngine(jsonURL: projectRules())
    for path in [
        "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/report.pdf"
    ] {
        let verdict = engine.verdict(for: ScanItem(path: path, sizeBytes: 1))
        #expect(verdict.risk == .review)
        #expect(verdict.needConfirm)
    }
}

@Test func userDataUnderProtectionIsNeverCleanable() throws {
    let engine = try RuleEngine(jsonURL: projectRules())
    let cases: [(String, String)] = [
        ("~/Library/Application Support/MobileSync/Backup/00008110/Manifest.db", "protected-ios-backup"),
        ("~/Pictures/Photos Library.photoslibrary/originals/a.jpg", "protected-photos-library"),
        ("~/Library/Messages/chat.db", "protected-messages"),
        ("~/Library/Safari/History.db", "protected-safari")
    ]
    for (path, ruleID) in cases {
        let verdict = engine.verdict(for: ScanItem(path: path, sizeBytes: 1))
        #expect(verdict.risk == .protected, "\(ruleID) 应判 protected")
        #expect(verdict.ruleID == ruleID, "\(ruleID) 应保留可读中文名")
        #expect(verdict.needConfirm)
        #expect(!verdict.explanation.contains("命中保护清单"), "\(ruleID) 应使用规则自带的人话解释")
    }
}
