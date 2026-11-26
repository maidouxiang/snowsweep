import Foundation
import Testing
@testable import SnowSweepCore

private func bundledRuleURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Rules/rules.json")
}

private func bundledEngine() throws -> RuleEngine {
    try RuleEngine(jsonURL: bundledRuleURL())
}

// MARK: - 原有基础测试

@Test func protectedListWins() throws {
    let book = RuleBook(
        version: "test",
        updatedAt: nil,
        protectedPaths: ["~/.ollama/models/*"],
        rules: [
            Rule(
                id: "any-cache",
                risk: .safe,
                name: "缓存",
                pathPattern: "~/.ollama/*",
                owner: nil,
                rebuildCost: .none,
                reason: "测试",
                needConfirm: false
            )
        ]
    )
    let engine = try RuleEngine(ruleBook: book)
    let item = ScanItem(path: "~/.ollama/models/model.gguf", sizeBytes: 1024)
    #expect(engine.verdict(for: item).risk == .protected)
}

@Test func occupiedPathIsProtected() throws {
    let book = RuleBook(version: "test", updatedAt: nil, protectedPaths: [], rules: [])
    let engine = try RuleEngine(ruleBook: book)
    let item = ScanItem(path: "/tmp/anything", sizeBytes: 1)
    #expect(engine.verdict(for: item, occupiedByProcess: true).risk == .protected)
}

@Test func matchedRuleUsesItsRisk() throws {
    let book = RuleBook(
        version: "test",
        updatedAt: nil,
        protectedPaths: [],
        rules: [
            Rule(
                id: "xcode-derived-data",
                risk: .review,
                name: "Xcode 构建缓存",
                pathPattern: "~/Library/Developer/Xcode/DerivedData/*",
                owner: "Xcode",
                rebuildCost: .low,
                reason: "可重建但耗时",
                needConfirm: true
            )
        ]
    )
    let engine = try RuleEngine(ruleBook: book)
    let item = ScanItem(path: "~/Library/Developer/Xcode/DerivedData/App-abc", sizeBytes: 4096)
    let verdict = engine.verdict(for: item)
    #expect(verdict.risk == .review)
    #expect(verdict.needConfirm)
    #expect(verdict.evidence.contains("rule:xcode-derived-data"))
}

@Test func unmatchedPathIsUnknown() throws {
    let book = RuleBook(version: "test", updatedAt: nil, protectedPaths: [], rules: [])
    let engine = try RuleEngine(ruleBook: book)
    let item = ScanItem(path: "/Users/me/Documents/mystery", sizeBytes: 100)
    #expect(engine.verdict(for: item).risk == .unknown)
}

@Test func modelCannotPromoteRisk() throws {
    let book = RuleBook(version: "test", updatedAt: nil, protectedPaths: [], rules: [])
    let engine = try RuleEngine(ruleBook: book)
    let item = ScanItem(path: "/Users/me/Documents/mystery", sizeBytes: 100)
    let unknown = engine.verdict(for: item)

    let downgraded = engine.applyingModelSuggestion(.safe, to: unknown)
    #expect(downgraded.risk == .review)
    #expect(downgraded.modelAssisted)

    let protected = Verdict(item: item, risk: .protected, explanation: "测试")
    let unchanged = engine.applyingModelSuggestion(.safe, to: protected)
    #expect(unchanged.risk == .protected)
}

@Test func bundledRuleBookLoads() throws {
    let engine = try bundledEngine()
    #expect(!engine.ruleBook.rules.isEmpty)
    #expect(engine.isProtected("~/.claude/projects/session.json"))
}

// MARK: - Bug 1：先命中先生效（具体规则必须抢在通配规则之前）

@Test func specificRuleBeatsWildcardRegardlessOfJSONOrder() throws {
    // 通配规则故意写在前面，复现原 rules.json 的顺序 bug
    let book = RuleBook(
        version: "test",
        updatedAt: nil,
        protectedPaths: [],
        rules: [
            Rule(id: "user-app-caches", risk: .safe, name: "用户应用缓存",
                 pathPattern: "~/Library/Caches/**", reason: "通配", needConfirm: false, priority: 10),
            Rule(id: "browser-chrome-cache", risk: .safe, name: "Chrome 浏览器缓存",
                 pathPattern: "~/Library/Caches/com.google.Chrome/**", owner: "Chrome",
                 reason: "具体", needConfirm: false, priority: 100)
        ]
    )
    let engine = try RuleEngine(ruleBook: book)
    let verdict = engine.verdict(for: ScanItem(
        path: "~/Library/Caches/com.google.Chrome/Default/Cache/data", sizeBytes: 1
    ))
    #expect(verdict.evidence.contains("rule:browser-chrome-cache"))
    #expect(!verdict.evidence.contains("rule:user-app-caches"))
}

@Test func crashReportsBeatsUserLogs() throws {
    let engine = try bundledEngine()
    let verdict = engine.verdict(for: ScanItem(
        path: "~/Library/Logs/DiagnosticReports/crash-2026.log", sizeBytes: 1
    ))
    #expect(verdict.evidence.contains("rule:crash-reports"))
    #expect(!verdict.evidence.contains("rule:user-log-files"))
}

// MARK: - Bug 2：通配符语义与范围收紧

@Test func starDoesNotCrossDirectorySeparator() throws {
    let book = RuleBook(
        version: "test", updatedAt: nil, protectedPaths: [],
        rules: [Rule(id: "top-only", risk: .safe, name: "顶层", pathPattern: "~/Cache/*",
                     reason: "测试", needConfirm: false, priority: 10)]
    )
    let engine = try RuleEngine(ruleBook: book)
    #expect(engine.verdict(for: ScanItem(path: "~/Cache/a.txt", sizeBytes: 1))
        .evidence.contains("rule:top-only"))
    #expect(!engine.verdict(for: ScanItem(path: "~/Cache/sub/a.txt", sizeBytes: 1))
        .evidence.contains("rule:top-only"))
}

@Test func doubleStarCrossesDirectorySeparator() throws {
    let book = RuleBook(
        version: "test", updatedAt: nil, protectedPaths: [],
        rules: [Rule(id: "deep", risk: .safe, name: "递归", pathPattern: "~/Cache/**",
                     reason: "测试", needConfirm: false, priority: 10)]
    )
    let engine = try RuleEngine(ruleBook: book)
    #expect(engine.verdict(for: ScanItem(path: "~/Cache/sub/deep/a.txt", sizeBytes: 1))
        .evidence.contains("rule:deep"))
}

@Test func distRuleNeverHitsSystemApplications() throws {
    let engine = try bundledEngine()
    let verdict = engine.verdict(for: ScanItem(
        path: "/Applications/Xcode.app/Contents/Developer/dist/bundle.js", sizeBytes: 1
    ))
    #expect(verdict.risk == .protected)
    #expect(verdict.evidence.contains("protected-list"))
}

@Test func distRuleMatchesRealUserProject() throws {
    let engine = try bundledEngine()
    let verdict = engine.verdict(for: ScanItem(
        path: "~/Projects/foo/dist/bundle.js", sizeBytes: 1
    ))
    #expect(verdict.evidence.contains("rule:dist-projects"))
}

@Test func pycacheRuleMatchesUserProjectButNotSystem() throws {
    let engine = try bundledEngine()
    #expect(engine.verdict(for: ScanItem(path: "~/Developer/foo/__pycache__/main.pyc", sizeBytes: 1))
        .evidence.contains("rule:pycache-developer"))
    #expect(engine.verdict(for: ScanItem(path: "/usr/local/lib/__pycache__/main.pyc", sizeBytes: 1))
        .risk == .protected)
}

// MARK: - 缺口 1/2/3：保护清单

@Test func aiToolRootsFullyProtected() throws {
    let engine = try bundledEngine()
    let paths = [
        "~/.ollama/id_ed25519",
        "~/.ollama/models/model.gguf",
        "~/.claude/settings.json",
        "~/.claude/projects/session.json",
        "~/.codex/config.toml",
        "~/.codex/sessions/abc.jsonl",
        "~/.lmstudio/config.json",
        "~/.cache/huggingface/token"
    ]
    for path in paths {
        #expect(engine.isProtected(path), "\(path) 应被保护")
    }
}

@Test func systemCriticalPathsProtected() throws {
    let engine = try bundledEngine()
    let paths = [
        "/Library/Keychains/System.keychain",
        "/private/var/vm/swapfile0",
        "/private/var/db/ConfigurationProfiles",
        "/private/etc/passwd",
        "/System/Volumes/Data/Users/me/Documents/file.txt",
        "/usr/local/bin/python3",
        "/opt/homebrew/bin/mo",
        "/Applications/Safari.app/Contents/Info.plist"
    ]
    for path in paths {
        #expect(engine.isProtected(path), "\(path) 应被保护")
    }
}

@Test func icloudAndExternalVolumesProtected() throws {
    let engine = try bundledEngine()
    #expect(engine.isProtected("~/Library/Mobile Documents/com~apple~CloudDocs/合同.pdf"))
    #expect(engine.isProtected("/Volumes/备份盘/照片.jpg"))
}

@Test func allowOverrideRuleCanPassProtection() throws {
    let engine = try bundledEngine()
    let verdict = engine.verdict(for: ScanItem(
        path: "/Library/Caches/com.apple.foo/cache.db", sizeBytes: 1
    ))
    #expect(verdict.risk == .review)
    #expect(verdict.evidence.contains("protection-overridden-by:system-caches"))
}

@Test func nonOverrideRuleCannotPassProtection() throws {
    let engine = try bundledEngine()
    let verdict = engine.verdict(for: ScanItem(
        path: "/Library/Keychains/System.keychain", sizeBytes: 1
    ))
    #expect(verdict.risk == .protected)
}

// MARK: - needConfirm 与默认勾选：safe 规则禁止 needConfirm，需确认项统一标 review

@Test func needConfirmOverridesSafeDefaultSelection() throws {
    let engine = try bundledEngine()
    let trash = engine.verdict(for: ScanItem(path: "~/.Trash/old.txt", sizeBytes: 1))
    #expect(trash.risk == .review)
    #expect(trash.needConfirm)
    #expect(!trash.defaultSelected)

    let ordinaryCache = engine.verdict(for: ScanItem(
        path: "~/Library/Caches/com.example.app/cache.db", sizeBytes: 1
    ))
    #expect(ordinaryCache.risk == .safe)
    #expect(ordinaryCache.defaultSelected)
}

// MARK: - 缺口 5：开发缓存规则

@Test func developerCacheRulesArePresent() throws {
    let engine = try bundledEngine()
    let cases: [(String, String)] = [
        ("~/Library/Developer/Xcode/iOS DeviceSupport/17.0", "xcode-device-support"),
        ("~/Library/Developer/Xcode/Archives/2026-11.xcarchive", "xcode-archives"),
        ("~/Library/Developer/CoreSimulator/Caches/abc", "xcode-simulator-caches"),
        ("~/.npm/_cacache/index-v5/ab/cd", "npm-cache"),
        ("~/Library/Caches/Yarn/v6/abc", "yarn-cache"),
        ("~/Library/pnpm/store/v3/files/ab", "pnpm-store"),
        ("~/.gradle/caches/modules-2/files-2.1/x", "gradle-cache"),
        ("~/Library/Caches/CocoaPods/Pods/Release/A", "cocoapods-cache")
    ]
    for (path, expectedRule) in cases {
        #expect(engine.verdict(for: ScanItem(path: path, sizeBytes: 1))
            .evidence.contains("rule:\(expectedRule)"), "\(path) 应命中 \(expectedRule)")
    }
}

// MARK: - 安全边界：进程占用分级与模型输出

@Test func exactOccupancyIsProtectedButApproximateOnlyDowngrades() throws {
    let book = RuleBook(
        version: "test", updatedAt: nil, protectedPaths: [],
        rules: [Rule(id: "safe-cache", risk: .safe, name: "缓存", pathPattern: "~/Cache/**",
                     reason: "测试", needConfirm: false)]
    )
    let engine = try RuleEngine(ruleBook: book)
    let item = ScanItem(path: "~/Cache/x", sizeBytes: 1)

    #expect(engine.verdict(for: item, occupancy: .exact).risk == .protected)
    let approximate = engine.verdict(for: item, occupancy: .approximate)
    #expect(approximate.risk == .review)
    #expect(approximate.evidence.contains("process-occupied-approximate"))
    #expect(engine.verdict(for: item, occupancy: .none).risk == .safe)
}

@Test func modelExplanationNeverOverwritesRuleReason() throws {
    let engine = try bundledEngine()
    let unknown = engine.verdict(for: ScanItem(path: "/Users/me/Documents/mystery", sizeBytes: 100))
    let suggestion = ModelSuggestion(level: .safe, what: "一个文档文件", impact: "删了可能有用", confidence: 0.45)
    let result = engine.applyingModelSuggestion(suggestion, to: unknown)

    #expect(result.risk == .review)
    #expect(result.explanation == unknown.explanation)
    #expect(result.aiExplanation == "一个文档文件 删了可能有用")
    #expect(result.isLowConfidence)
    #expect(result.evidence.contains("model-low-confidence"))
}

@Test func highConfidenceModelOutputIsNotFlagged() throws {
    let engine = try bundledEngine()
    let unknown = engine.verdict(for: ScanItem(path: "/Users/me/Documents/mystery", sizeBytes: 100))
    let suggestion = ModelSuggestion(level: .review, what: "文档", impact: "需确认", confidence: 0.9)
    let result = engine.applyingModelSuggestion(suggestion, to: unknown)
    #expect(!result.isLowConfidence)
}

// MARK: - partial 报告禁止清理

@Test func partialReportCannotClean() throws {
    let report = ScanReport(
        scanStatus: "partial",
        totalBytes: 0,
        verdicts: [],
        scanGaps: [ScanGap(kind: .tccDenied, path: "/Library", detail: "需要完全磁盘访问")]
    )
    #expect(!report.isComplete)
    #expect(!report.canClean)
    #expect(report.scanGaps.first?.displayText.contains("完全磁盘访问") == true)

    let complete = ScanReport(scanStatus: "complete", totalBytes: 1, verdicts: [])
    #expect(complete.canClean)
}

@Test func bundledRuleBookPassesStrictValidation() throws {
    let data = try Data(contentsOf: bundledRuleURL())
    let issues = RuleBookValidator.validate(jsonData: data)
    #expect(!issues.contains { $0.severity == .error })
    // 保护清单存在父子重叠是允许的，但必须给出 warning 让维护者知道覆盖范围。
    #expect(issues.contains { $0.severity == .warning && $0.message.contains("子集") })
}
