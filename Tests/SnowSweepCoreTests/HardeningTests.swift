import Foundation
import Testing
@testable import SnowSweepCore

// MARK: - 测试替身

private struct MockScanner: Scanning {
    let sourceLabel = "Mock 扫描源"
    let isAvailable: Bool
    let versionText: String
    let throwOnVersion: Bool

    init(available: Bool = true, version: String = "1.0.0", throwOnVersion: Bool = false) {
        self.isAvailable = available
        self.versionText = version
        self.throwOnVersion = throwOnVersion
    }

    func version() throws -> String {
        if throwOnVersion { throw NSError(domain: "mock", code: 1) }
        return versionText
    }
    func statusJSON() throws -> Data { Data() }
    func analyzeJSON(path: String?) throws -> Data { Data() }
    func cleanPreviewJSON() throws -> Data { Data() }
}

private struct MockProvider: ScanningProvider {
    let scanner: any Scanning
    func makeScanner() -> any Scanning { scanner }
}

private final class MockTrasher: FileTrashing, @unchecked Sendable {
    var failTrash = false
    var trashCalls: [String] = []
    var removeCalls: [String] = []

    func trashItem(at path: String) throws -> URL? {
        trashCalls.append(path)
        if failTrash { throw NSError(domain: "trash", code: 42, userInfo: [NSLocalizedDescriptionKey: "废纸篓不可用"]) }
        return nil
    }

    func removeItem(at path: String) throws { removeCalls.append(path) }
}

private final class TestCounter: @unchecked Sendable { var value = 0 }

private func tempURL(_ name: String) -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SnowSweepTest-\(UUID().uuidString)-\(name)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func completeReport() -> ScanReport {
    ScanReport(scanStatus: "complete", totalBytes: 1, verdicts: [])
}

private func bundledRuleBook() throws -> RuleBook {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Rules/rules.json")
    let data = try Data(contentsOf: url)
    try RuleBookValidator.assertValid(jsonData: data)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(RuleBook.self, from: data)
}

// MARK: - 架构：缺口分级 / 流式 / 注入

@Test func scanGapSeverityDistinguishesWholeScanFromDirectory() {
    #expect(ScanGap(kind: .tccDenied, path: "/Library").severity == .critical)
    #expect(ScanGap(kind: .tccDenied, path: "/Library").scope == .wholeScan)
    #expect(ScanGap(kind: .truncated, path: "/").severity == .critical)
    #expect(ScanGap(kind: .permissionDenied, path: "/tmp/a").severity == .warning)
    #expect(ScanGap(kind: .permissionDenied, path: "/tmp/a").scope == .directory)
    #expect(ScanGap(kind: .symlinkLoop, path: "/tmp/a").severity == .info)

    let critical = ScanReport(
        scanStatus: "partial", totalBytes: 0, verdicts: [],
        scanGaps: [ScanGap(kind: .truncated, path: "/")]
    )
    #expect(critical.hasCriticalGaps)
    #expect(critical.cleaningBlockedReason?.contains("全盘级缺口") == true)
}

@Test func collectorTruncatesLargePayload() {
    let collector = ScanPayloadCollector(maxItems: 3)
    for index in 0..<20 {
        collector.accept(ScanItem(path: "/tmp/\(index)", sizeBytes: 1))
    }
    collector.finish(truncated: false)
    #expect(collector.itemCount == 3)
    #expect(collector.droppedCount == 17)
    #expect(collector.payload.truncated)
}

@Test func scannerResolverUsesInjectedProvider() {
    let good = MockScanner()
    #expect(ScannerResolver.resolve(provider: MockProvider(scanner: good)).sourceLabel == good.sourceLabel)
    #expect(ScannerResolver.resolve(provider: MockProvider(scanner: MockScanner(available: false))) is NativeScanner)
    #expect(ScannerResolver.resolve(provider: MockProvider(scanner: MockScanner(version: "2.0.0"))) is NativeScanner)
    #expect(ScannerResolver.resolve(provider: MockProvider(scanner: MockScanner(throwOnVersion: true))) is NativeScanner)
}

@Test func streamScanCanBeCancelled() throws {
    let root = tempURL("stream")
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<12 {
        try Data("x".utf8).write(to: root.appendingPathComponent("f\(index).txt"))
    }
    let collector = ScanPayloadCollector(maxItems: 100)
    let counter = TestCounter()
    let summary = try NativeScanner().streamAnalyze(path: root.path, onProgress: { _ in
        counter.value += 1
        return counter.value < 4
    }, sink: collector)
    #expect(summary.cancelled)
    #expect(summary.kept < 12)
}

@Test func symlinkLoopIsNotFollowed() throws {
    let root = tempURL("symlink")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x".utf8).write(to: root.appendingPathComponent("real.txt"))
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("loop"),
        withDestinationURL: URL(fileURLWithPath: root.path)
    )
    let collector = ScanPayloadCollector(maxItems: 100)
    let summary = try NativeScanner().streamAnalyze(path: root.path, sink: collector)
    #expect(!summary.cancelled)
    #expect(summary.kept >= 1)
    #expect(summary.kept < 10_000)
}

@Test func cloudPlaceholderSuffixIsDetected() {
    let url = URL(fileURLWithPath: "/tmp/照片.pdf.icloud")
    #expect(NativeScanner.isCloudPlaceholder(url, values: nil))
}

// MARK: - 安全：审计 / 删除容错 / 保护白名单

@Test func auditLogHashChainDetectsTampering() throws {
    let root = tempURL("audit")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))
    _ = try log.append(action: .dryRun, path: "/tmp/a", success: true, detail: "预览")
    _ = try log.append(action: .moveToTrash, path: "/tmp/a", success: true, detail: "已移除")
    #expect(try log.verify().isValid)

    var text = try String(contentsOf: log.fileURL, encoding: .utf8)
    text = text.replacingOccurrences(of: "已移除", with: "被改过")
    try text.write(to: log.fileURL, atomically: true, encoding: .utf8)
    let result = try log.verify()
    #expect(result.brokenLines == [2])
    #expect(!result.isValid)
}

@Test func trashFailureNeverFallsBackToPermanentDelete() throws {
    let root = tempURL("trash")
    defer { try? FileManager.default.removeItem(at: root) }
    let trasher = MockTrasher()
    trasher.failTrash = true
    let coordinator = DeletionCoordinator(
        trasher: trasher,
        audit: AuditLog(fileURL: root.appendingPathComponent("audit.jsonl")),
        policy: DeletionPolicy(allowPermanentDelete: true)
    )
    let item = ScanItem(path: "/tmp/important.txt", sizeBytes: 10)

    #expect(throws: DeletionError.self) {
        try coordinator.moveToTrash(item, ruleID: nil, report: completeReport())
    }
    #expect(trasher.removeCalls.isEmpty)
    let events = try coordinator.audit.events()
    #expect(events.last?.action == .moveToTrashFailed)
    #expect(events.last?.success == false)
}

@Test func trashFailureCanSkipWithoutDeletingAnything() throws {
    let root = tempURL("trash-skip")
    defer { try? FileManager.default.removeItem(at: root) }
    let trasher = MockTrasher()
    trasher.failTrash = true
    let coordinator = DeletionCoordinator(
        trasher: trasher,
        audit: AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))
    )
    let item = ScanItem(path: "/tmp/keep-me.txt", sizeBytes: 10)
    let event = try coordinator.moveToTrash(
        item, ruleID: nil, report: completeReport(), resolution: .skip
    )
    #expect(event == nil)
    #expect(trasher.removeCalls.isEmpty)
    let events = try coordinator.audit.events()
    #expect(events.last?.action == .skippedAfterTrashFailure)
}

@Test func trashFailureCanMoveToUserBackupWithoutPermanentDelete() throws {
    let root = tempURL("trash-backup")
    defer { try? FileManager.default.removeItem(at: root) }
    let backup = root.appendingPathComponent("备份")
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("snapshot.dmg")
    try Data("payload".utf8).write(to: source)

    let trasher = MockTrasher()
    trasher.failTrash = true
    let coordinator = DeletionCoordinator(
        trasher: trasher,
        audit: AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))
    )
    let item = ScanItem(path: source.path, sizeBytes: 7)
    let event = try coordinator.moveToTrash(
        item, ruleID: nil, report: completeReport(), resolution: .backupTo(backup.path)
    )
    #expect(event?.action == .movedToBackup)
    #expect(trasher.removeCalls.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    let backedUp = try FileManager.default.contentsOfDirectory(atPath: backup.path)
    #expect(backedUp.count == 1)
    #expect(backedUp.first?.hasPrefix("snapshot.dmg.") == true)
}

@Test func backupDirectoryInsideSourceIsRejected() throws {
    let root = tempURL("trash-backup-guard")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("项目")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let trasher = MockTrasher()
    trasher.failTrash = true
    let coordinator = DeletionCoordinator(
        trasher: trasher,
        audit: AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))
    )
    #expect(throws: DeletionError.self) {
        try coordinator.moveToTrash(
            ScanItem(path: source.path, sizeBytes: 0), ruleID: nil, report: completeReport(),
            resolution: .backupTo(source.appendingPathComponent("备份").path)
        )
    }
    #expect(trasher.removeCalls.isEmpty)
}

@Test func transientIOErrorGapIsRetryable() {
    let gap = ScanGap(kind: .transientIO, path: "/tmp/x", detail: "EINTR")
    #expect(gap.isRetryable)
    #expect(gap.severity == .warning)
    #expect(gap.scope == .directory)
    #expect(gap.displayText.contains("临时错误"))
    #expect(!ScanGap(kind: .permissionDenied, path: "/tmp/y").isRetryable)
}

@Test func retryOnInterruptionSucceedsAfterTransientErrors() throws {
    let counter = TestCounter()
    let value = try retryOnInterruption(attempts: 3) {
        counter.value += 1
        if counter.value < 3 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINTR)) }
        return 42
    }
    #expect(value == 42)
    #expect(counter.value == 3)

    let permanent = TestCounter()
    #expect(throws: NSError.self) {
        try retryOnInterruption(attempts: 3) {
            permanent.value += 1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
    }
    #expect(permanent.value == 1)
}

@Test func permanentDeleteRequiresPolicyAndExactConfirmation() throws {
    let root = tempURL("perm")
    defer { try? FileManager.default.removeItem(at: root) }
    let trasher = MockTrasher()
    let audit = AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))
    let item = ScanItem(path: "/tmp/x.dmg", sizeBytes: 10)
    let goodConfirmation = DeleteConfirmation(phrase: "我确认永久删除", acknowledgedIrreplaceable: true)

    let closed = DeletionCoordinator(trasher: trasher, audit: audit)
    #expect(throws: DeletionError.self) {
        try closed.permanentlyDelete(item, ruleID: nil, report: completeReport(), confirmation: goodConfirmation)
    }

    let open = DeletionCoordinator(
        trasher: trasher, audit: audit, policy: DeletionPolicy(allowPermanentDelete: true)
    )
    #expect(throws: DeletionError.self) {
        try open.permanentlyDelete(
            item, ruleID: nil, report: completeReport(),
            confirmation: DeleteConfirmation(phrase: "删了吧", acknowledgedIrreplaceable: true)
        )
    }
    #expect(trasher.removeCalls.isEmpty)
    _ = try open.permanentlyDelete(item, ruleID: nil, report: completeReport(), confirmation: goodConfirmation)
    #expect(trasher.removeCalls == [item.path])
}

@Test func partialReportBlocksEveryDeletionPath() throws {
    let root = tempURL("partial")
    defer { try? FileManager.default.removeItem(at: root) }
    let trasher = MockTrasher()
    let coordinator = DeletionCoordinator(
        trasher: trasher, audit: AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))
    )
    let partial = ScanReport(
        scanStatus: "partial", totalBytes: 1, verdicts: [],
        scanGaps: [ScanGap(kind: .tccDenied, path: "/Library")]
    )
    let item = ScanItem(path: "/tmp/a", sizeBytes: 1)
    #expect(throws: DeletionError.self) { try coordinator.dryRun(items: [item], report: partial, engine: RuleEngine(ruleBook: bundledRuleBook())) }
    #expect(throws: DeletionError.self) { try coordinator.moveToTrash(item, ruleID: nil, report: partial) }
    #expect(trasher.trashCalls.isEmpty)
    #expect(trasher.removeCalls.isEmpty)
}

@Test func customProtectedPathsAreAdditiveOnly() throws {
    let book = RuleBook(
        version: "test", updatedAt: nil, protectedPaths: [],
        rules: [Rule(id: "safe-cache", risk: .safe, name: "缓存", pathPattern: "~/MyCache/**",
                     reason: "测试", needConfirm: false)]
    )
    let engine = try RuleEngine(ruleBook: book, customProtectedPaths: ["~/MyCache/private/**"])
    #expect(engine.verdict(for: ScanItem(path: "~/MyCache/private/secret", sizeBytes: 1)).risk == .protected)
    #expect(engine.verdict(for: ScanItem(path: "~/MyCache/other", sizeBytes: 1)).risk == .safe)
}

@Test func protectionListStoreRejectsBadPatterns() throws {
    let root = tempURL("protect")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProtectionListStore(fileURL: root.appendingPathComponent("custom.json"))
    _ = try store.add("~/Documents/合同")
    _ = try store.add("~/Documents/合同")
    #expect(try store.load() == ["~/Documents/合同"])
    #expect(throws: ProtectionListError.self) { try store.add("~/Documents/../etc/**") }
}

// MARK: - 规则库：校验 / 迁移 / 内置文案

@Test func validatorRejectsSafeWithNeedConfirm() {
    let json = """
    {"version":"0.2.0","protectedPaths":["/tmp/**"],"rules":[
      {"id":"x","risk":"safe","name":"缓存","pathPattern":"/tmp/a/**","reason":"测试","needConfirm":true}
    ]}
    """
    let issues = RuleBookValidator.validate(jsonData: Data(json.utf8))
    #expect(issues.contains { $0.message.contains("safe 规则不能同时") && $0.severity == .error })
}

@Test func validatorWarnsOnOverlappingProtectedPaths() {
    let json = """
    {"version":"0.2.0","protectedPaths":["/System/**","/System/Volumes/**"],"rules":[
      {"id":"x","risk":"safe","name":"缓存","pathPattern":"/tmp/a/**","reason":"测试","needConfirm":false}
    ]}
    """
    let issues = RuleBookValidator.validate(jsonData: Data(json.utf8))
    #expect(issues.contains { $0.severity == .warning && $0.message.contains("子集") })
    #expect(!issues.contains { $0.severity == .error })
}

@Test func validatorRejectsUndefinedGlobSyntax() {
    #expect(RuleBookValidator.validatePatternSyntax("~/Projects/foo**bar/**").contains { $0.contains("独占") })
    #expect(RuleBookValidator.validatePatternSyntax("~/Projects/../etc/**").contains { $0.contains("跳转") })
    #expect(RuleBookValidator.validatePatternSyntax("~/Projects/**/dist/**").isEmpty)
}

@Test func migrationPreservesUserRulesAcrossBuiltinUpgrade() {
    let old = RuleBook(version: "0.1.0", updatedAt: nil, protectedPaths: ["/System/**"], rules: [])
    let userRule = Rule(
        id: "my-private-cache", risk: .safe, name: "我的私有缓存",
        pathPattern: "~/MyApp/Cache/**", reason: "自建应用缓存", needConfirm: false,
        allowOverrideProtection: true, source: "user"
    )
    let overlay = UserRuleOverlay(protectedPaths: ["~/MyApp/Private/**"], rules: [userRule])
    let migrated = RuleBookMigrator.merge(builtIn: old, overlay: overlay)

    #expect(migrated.version == "0.1.0")
    #expect(migrated.rules.count == 1)
    #expect(migrated.rules.first?.source == "user")
    #expect(!migrated.rules.first!.allowOverrideProtection)
    #expect(migrated.protectedPaths.contains("/System/**"))
    #expect(migrated.protectedPaths.contains("~/MyApp/Private/**"))
}

@Test func overlayValidationRequiresUserSource() {
    let json = """
    {"schemaVersion":1,"protectedPaths":["~/MyApp/**"],"rules":[
      {"id":"x","risk":"safe","name":"缓存","pathPattern":"~/MyApp/Cache/**","reason":"测试","needConfirm":false,"source":"builtin"}
    ]}
    """
    let issues = RuleBookMigrator.validateOverlay(jsonData: Data(json.utf8))
    #expect(issues.contains { $0.path == "$.rules[0].source" && $0.severity == .error })
}

@Test func bundledRulesHaveChineseNameAndReason() throws {
    let book = try bundledRuleBook()
    #expect(book.rules.count == 89)
    for rule in book.rules {
        #expect(!rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(rule.id) 缺中文名")
        #expect(!rule.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(rule.id) 缺人话解释")
        #expect(rule.source == "builtin")
        #expect(!(rule.risk == .safe && rule.needConfirm), "\(rule.id) safe+needConfirm 冲突")
    }
}

// MARK: - SemVer 与模型策略

@Test func semVerDistinguishesBreakingAndCompatible() {
    #expect(ScannerVersion.compatibility(found: "1.4.2", required: "1.0.0") == .compatible)
    #expect(ScannerVersion.compatibility(found: "1.0.0-beta.1", required: "1.0.0") == .olderIncompatible)
    #expect(ScannerVersion.compatibility(found: "0.9.9", required: "1.0.0") == .breakingMajor)
    #expect(ScannerVersion.compatibility(found: "2.0.0", required: "1.0.0") == .futureMajor)
    #expect(ScannerVersion.compatibility(found: "unknown", required: "1.0.0") == .unparseable)
    #expect(SemanticVersion(parsing: "mole 1.2.3+build.7")?.patch == 3)
}

@Test func aiBudgetAndGuardBlockRunawayCalls() async {
    let budget = AICallBudget(limit: 2)
    #expect(await budget.reserve())
    #expect(await budget.reserve())
    let thirdCall = await budget.reserve()
    #expect(!thirdCall)

    let suggestion = ModelSuggestion(
        level: .safe, what: "这是缓存", impact: "建议删除即可释放空间", confidence: 0.95,
        promptVersion: "snow-ai-v1"
    )
    let guarded = AIOutputGuard.sanitized(suggestion, promptVersion: "snow-ai-v1")
    #expect(guarded.hallucinationFlagged)
    #expect(guarded.level == .unknown)
    #expect(guarded.confidence == 0)
    #expect(guarded.promptVersion == "snow-ai-v1")

    let normal = ModelSuggestion(level: .review, what: "日志文件", impact: "删除后不影响运行", confidence: 0.8)
    #expect(!AIOutputGuard.sanitized(normal, promptVersion: nil).hallucinationFlagged)
}

@Test func aiTimeoutReturnsInsteadOfHanging() async throws {
    let started = ContinuousClock.now
    await #expect(throws: AIPlannerError.self) {
        try await withAITimeout(seconds: 0.2) {
            try await Task.sleep(for: .seconds(5))
            return 1
        }
    }
    #expect(ContinuousClock.now - started < .seconds(2))
}

@Test func selfCheckQuantifiesChineseAndDangerousOutputs() {
    let good = ModelSelfCheckResult(
        path: "~/Library/Caches/abc",
        suggestion: ModelSuggestion(level: .review, what: "临时缓存文件", impact: "删除后会自动重建", confidence: 0.7)
    )
    let dangerous = ModelSelfCheckResult(
        path: "~/Documents/合同.pdf",
        suggestion: ModelSuggestion(level: .safe, what: "合同文档", impact: "建议删除", confidence: 0.95,
                                    hallucinationFlagged: true)
    )
    let metrics = SelfCheckEvaluator.evaluate([good, dangerous])
    #expect(metrics.samples == 2)
    #expect(metrics.chineseSamples == 2)
    #expect(metrics.dangerousOutputs == 1)
    #expect(metrics.overconfidentSensitive == 1)
    #expect(!metrics.passed)
}

@Test func modelEvidenceRecordsPromptVersionAndRejectsHallucination() throws {
    let book = RuleBook(version: "t", updatedAt: nil, protectedPaths: [], rules: [])
    let engine = try RuleEngine(ruleBook: book)
    let unknown = engine.verdict(for: ScanItem(path: "/tmp/未知文件", sizeBytes: 1))
    let flagged = ModelSuggestion(
        level: .safe, what: "未知文件", impact: "建议删除", confidence: 0.9,
        promptVersion: "snow-ai-v2", hallucinationFlagged: true
    )
    let result = engine.applyingModelSuggestion(flagged, to: unknown)
    #expect(result.risk == .unknown)
    #expect(result.evidence.contains("prompt:snow-ai-v2"))
    #expect(result.evidence.contains("model-dangerous-delete-keyword"))
}
