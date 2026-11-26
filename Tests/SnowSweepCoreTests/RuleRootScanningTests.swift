import Foundation
import Testing
@testable import SnowSweepCore

private func makeRule(_ id: String, _ pattern: String, risk: RiskLevel) -> Rule {
    Rule(id: id, risk: risk, name: id, pathPattern: pattern, reason: "测试规则")
}

private func makeFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("snowsweep-roots-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func boundedDirectoryListsNormalAndHiddenNames() throws {
    let dir = try makeFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appendingPathComponent("visible.txt"))
    try Data().write(to: dir.appendingPathComponent(".hidden"))

    let names = BoundedDirectoryLister.names(atPath: dir.path)
    #expect(names?.contains("visible.txt") == true)
    #expect(names?.contains(".hidden") == true)
    #expect(names?.contains(".") == false)
}

@Test func boundedDirectoryDistinguishesPermissionFromHardFailure() throws {
    let dir = try makeFixture()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)

    #expect(BoundedDirectoryLister.list(atPath: dir.path) == .permissionDenied)
    #expect(BoundedDirectoryLister.list(atPath: dir.appendingPathComponent("missing").path) == .permissionDenied)
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("snowsweep-missing-\(UUID().uuidString)").path
    #expect(BoundedDirectoryLister.list(atPath: missing) == .failed)
}

@Test func plannerCollapsesNestedRoots() throws {
    let home = try makeFixture()
    defer { try? FileManager.default.removeItem(at: home) }

    let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    let yarn = caches.appendingPathComponent("Yarn", isDirectory: true)
    let npm = home.appendingPathComponent(".npm/_cacache", isDirectory: true)
    for dir in [yarn, npm] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let rules = [
        makeRule("broad-cache", "~/Library/Caches/**", risk: .safe),
        makeRule("yarn-cache", "~/Library/Caches/Yarn/**", risk: .safe),
        makeRule("npm-cache", "~/.npm/_cacache/**", risk: .review)
    ]
    let plan = RuleRootPlanner.plan(rules: rules, home: home.path)
    #expect(plan.roots.contains(caches.path))
    #expect(plan.roots.contains(npm.path))
    #expect(!plan.roots.contains(yarn.path), "父根覆盖后不应重复扫子根")
}

@Test func plannerExpandsMiddleWildcardWithoutFallingBackToWholeParent() throws {
    let home = try makeFixture()
    defer { try? FileManager.default.removeItem(at: home) }

    let containers = home.appendingPathComponent("Library/Containers", isDirectory: true)
    let first = containers.appendingPathComponent("com.example.one/Data/Library/Caches", isDirectory: true)
    let second = containers.appendingPathComponent("com.example.two/Data/Library/Caches", isDirectory: true)
    let unrelated = containers.appendingPathComponent("com.example.three/Data/Library/Logs", isDirectory: true)
    for dir in [first, second, unrelated] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let rule = makeRule("container-cache", "~/Library/Containers/*/Data/Library/Caches/**", risk: .safe)
    let plan = RuleRootPlanner.plan(rules: [rule], home: home.path)
    #expect(plan.roots.contains(first.path))
    #expect(plan.roots.contains(second.path))
    #expect(!plan.roots.contains(containers.path), "不能退化成整个 Containers 根")
    #expect(!plan.roots.contains(unrelated.path))
}

@Test func scannerAggregatesDirectoryAndKeepsOnlyRuleCoveredCandidates() throws {
    let home = try makeFixture()
    defer { try? FileManager.default.removeItem(at: home) }

    let cache = home.appendingPathComponent("Library/Caches/AppCache", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 4096).write(to: cache.appendingPathComponent("blob.bin"))

    let npm = home.appendingPathComponent(".npm/_cacache", isDirectory: true)
    try FileManager.default.createDirectory(at: npm, withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 512).write(to: npm.appendingPathComponent("index.bin"))

    let book = RuleBook(
        version: "test",
        updatedAt: nil,
        protectedPaths: [],
        rules: [
            makeRule("cache", "\(home.path)/Library/Caches/**", risk: .safe),
            makeRule("npm", "\(home.path)/.npm/_cacache/**", risk: .review)
        ]
    )
    let engine = try RuleEngine(ruleBook: book)
    let collector = ScanPayloadCollector(maxItems: 100)
    let summary = try RuleRootScanner(engine: engine, home: home.path).streamAnalyze(sink: collector)

    let payload = collector.payload
    #expect(summary.kept == 2)
    #expect(payload.items.count == 2)
    // 临时目录在 APFS 上会呈现为 /private/var，按路径尾段断言聚合结果。
    #expect(payload.items.contains { $0.path.hasSuffix("/Library/Caches/AppCache") && $0.sizeBytes == 4096 })
    #expect(payload.items.contains { $0.path.hasSuffix("/.npm/_cacache/index.bin") && $0.sizeBytes == 512 })
    #expect(payload.items.allSatisfy { engine.verdict(for: $0).risk != .unknown })
}

@Test func scannerWithParallelRootsKeepsAllCandidatesOnce() throws {
    let home = try makeFixture()
    defer { try? FileManager.default.removeItem(at: home) }

    let roots = ["Caches/One", "Caches/Two", "Logs/Three"]
    for root in roots {
        let directory = home.appendingPathComponent(root, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data(repeating: 0x55, count: 128)
                .write(to: directory.appendingPathComponent("item-\(index).bin"))
        }
    }
    let rules = [
        makeRule("one", "\(home.path)/Caches/One/**", risk: .safe),
        makeRule("two", "\(home.path)/Caches/Two/**", risk: .safe),
        makeRule("three", "\(home.path)/Logs/Three/**", risk: .review)
    ]
    let engine = try RuleEngine(ruleBook: RuleBook(version: "test", updatedAt: nil,
                                                   protectedPaths: [], rules: rules))
    let collector = ScanPayloadCollector(maxItems: 100)
    let summary = try RuleRootScanner(engine: engine, home: home.path, maxConcurrentRoots: 3)
        .streamAnalyze(sink: collector)

    let paths = Set(collector.payload.items.map(\.path))
    #expect(summary.scanned == 9)
    #expect(summary.kept == 9)
    #expect(paths.count == 9, "并发扫描不能重复收同一条候选")
    #expect(!summary.truncated)
}


@Test func warningGapDoesNotLockCleaning() {
    let warning = ScanGap(kind: .permissionDenied, path: "/Users/me/Library/Caches/private")
    let report = ScanReport(
        scanStatus: "complete",
        totalBytes: 1,
        verdicts: [],
        scanGaps: [warning]
    )
    #expect(warning.severity == .warning)
    #expect(report.canClean)
    #expect(report.cleaningBlockedReason == nil)

    let critical = ScanGap(kind: .truncated, path: "/Users/me", severity: .critical, scope: .wholeScan)
    let locked = ScanReport(scanStatus: "complete", totalBytes: 1, verdicts: [], scanGaps: [critical])
    #expect(!locked.canClean)
}
