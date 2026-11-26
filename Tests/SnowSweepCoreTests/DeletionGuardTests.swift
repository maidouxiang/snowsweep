import Foundation
import Testing
@testable import SnowSweepCore

private func guardTempURL(_ name: String) -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SnowSweepGuardTest-\(UUID().uuidString)-\(name)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func guardCompleteReport() -> ScanReport {
    ScanReport(scanStatus: "complete", totalBytes: 1, verdicts: [])
}

private final class GuardTrasher: FileTrashing, @unchecked Sendable {
    var trashCalls: [String] = []
    var removeCalls: [String] = []
    func trashItem(at path: String) throws -> URL? { trashCalls.append(path); return nil }
    func removeItem(at path: String) throws { removeCalls.append(path) }
}

// MARK: - 文件身份捕获

@Test func fileIdentityCapturesRealFileWithoutFollowingSymlink() throws {
    let root = guardTempURL("identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real.txt")
    try Data("hello".utf8).write(to: real)
    let link = root.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let realIdentity = try #require(FileIdentity.capture(at: real.path))
    #expect(realIdentity.kind == .file)
    #expect(try #require(FileIdentity.capture(at: link.path)).kind == .symlink)

    // 同一文件重复捕获身份一致
    #expect(realIdentity == FileIdentity.capture(at: real.path))
    // 身份不同的文件不匹配
    let other = root.appendingPathComponent("other.txt")
    try Data("other".utf8).write(to: other)
    #expect(!realIdentity.matches(try #require(FileIdentity.capture(at: other.path))))
}

@Test func fileIdentityReturnsNilForMissingPath() {
    #expect(FileIdentity.capture(at: "/tmp/definitely-not-exists-\(UUID().uuidString)") == nil)
}

// MARK: - 删除前复核

@Test func replacedFileIsRejectedBeforeTrash() throws {
    let root = guardTempURL("replaced")
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("cache")
    try Data("old".utf8).write(to: target)
    let oldIdentity = try #require(FileIdentity.capture(at: target.path))

    // 扫描后被替换：删除旧文件、建同名新文件（不同 inode）
    try FileManager.default.removeItem(at: target)
    try Data("new".utf8).write(to: target)

    let trasher = GuardTrasher()
    let coordinator = DeletionCoordinator(
        trasher: trasher,
        audit: AuditLog(fileURL: root.appendingPathComponent("audit.jsonl")),
        requireIdentity: true
    )
    let item = ScanItem(path: target.path, sizeBytes: 3, identity: oldIdentity)

    #expect(throws: TargetRevalidationError.self) {
        try coordinator.moveToTrash(item, ruleID: nil, report: guardCompleteReport())
    }
    #expect(trasher.trashCalls.isEmpty)
    let events = try coordinator.audit.events()
    #expect(events.last?.action == .targetRejected)
    #expect(events.last?.success == false)
}

@Test func symlinkSwapIsRejectedBeforePermanentDelete() throws {
    let root = guardTempURL("symlink")
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("item")
    try Data("payload".utf8).write(to: target)
    let original = try #require(FileIdentity.capture(at: target.path))

    // 换成指向重要文件的符号链接
    let important = root.appendingPathComponent("important.txt")
    try Data("do not delete".utf8).write(to: important)
    try FileManager.default.removeItem(at: target)
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: important)

    let trasher = GuardTrasher()
    let coordinator = DeletionCoordinator(
        trasher: trasher,
        audit: AuditLog(fileURL: root.appendingPathComponent("audit.jsonl")),
        policy: DeletionPolicy(allowPermanentDelete: true)
    )
    let item = ScanItem(path: target.path, sizeBytes: 7, identity: original)
    let confirmation = DeleteConfirmation(phrase: "我确认永久删除", acknowledgedIrreplaceable: true)

    #expect(throws: TargetRevalidationError.self) {
        try coordinator.permanentlyDelete(
            item, ruleID: nil, report: guardCompleteReport(), confirmation: confirmation
        )
    }
    #expect(trasher.removeCalls.isEmpty)
    #expect(FileManager.default.fileExists(atPath: important.path))
}

@Test func protectedPathIsRejectedEvenWithValidIdentity() throws {
    let root = guardTempURL("protected")
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: target)
    let identity = try #require(FileIdentity.capture(at: target.path))
    let trasher = GuardTrasher()
    let coordinator = DeletionCoordinator(
        trasher: trasher,
        audit: AuditLog(fileURL: root.appendingPathComponent("audit.jsonl")),
        protectionCheck: { $0.hasSuffix("keep.txt") }
    )
    let item = ScanItem(path: target.path, sizeBytes: 4, identity: identity)

    #expect(throws: TargetRevalidationError.self) {
        try coordinator.moveToTrash(item, ruleID: nil, report: guardCompleteReport())
    }
    #expect(trasher.trashCalls.isEmpty)
}

@Test func strictModeRejectsReportWithoutIdentity() throws {
    let root = guardTempURL("strict")
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("old-report.txt")
    try Data("x".utf8).write(to: target)
    let trasher = GuardTrasher()
    let coordinator = DeletionCoordinator(
        trasher: trasher,
        audit: AuditLog(fileURL: root.appendingPathComponent("audit.jsonl")),
        requireIdentity: true
    )
    let legacyItem = ScanItem(path: target.path, sizeBytes: 1)  // 旧报告，无身份

    #expect(throws: TargetRevalidationError.self) {
        try coordinator.moveToTrash(legacyItem, ruleID: nil, report: guardCompleteReport())
    }
    #expect(trasher.trashCalls.isEmpty)
}

@Test func unchangedFileStillDeletesNormally() throws {
    let root = guardTempURL("unchanged")
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("cache.tmp")
    try Data("junk".utf8).write(to: target)
    let identity = try #require(FileIdentity.capture(at: target.path))
    let trasher = GuardTrasher()
    let coordinator = DeletionCoordinator(
        trasher: trasher,
        audit: AuditLog(fileURL: root.appendingPathComponent("audit.jsonl")),
        requireIdentity: true
    )
    let item = ScanItem(path: target.path, sizeBytes: 4, identity: identity)

    let event = try coordinator.moveToTrash(item, ruleID: nil, report: guardCompleteReport())
    #expect(event?.action == .moveToTrash)
    #expect(trasher.trashCalls == [target.path])
}

// MARK: - 规则导入指纹

private func overlayData(_ ruleCount: Int, protected: [String] = []) throws -> Data {
    let rules = (0..<ruleCount).map { index in
        Rule(
            id: "user-rule-\(index)",
            risk: .review,
            name: "用户规则 \(index)",
            pathPattern: "~/Library/Caches/user-\(index)/**",
            reason: "测试用",
            needConfirm: true,
            source: "user"
        )
    }
    return try RuleBookMigrator.exportOverlay(
        UserRuleOverlay(protectedPaths: protected, rules: rules)
    )
}

@Test func overlayFingerprintIsStableAndContentSensitive() throws {
    let first = try overlayData(2)
    let overlay = try RuleBookMigrator.importOverlay(jsonData: first)
    let hash1 = try OverlayImportGuard.fingerprint(of: overlay)

    // 同一叠加层重新编码指纹不变
    let same = try RuleBookMigrator.importOverlay(jsonData: try RuleBookMigrator.exportOverlay(overlay))
    #expect(try OverlayImportGuard.fingerprint(of: same) == hash1)

    // 规则数量变化 → 指纹变化
    let changed = try RuleBookMigrator.importOverlay(jsonData: try overlayData(3))
    #expect(try OverlayImportGuard.fingerprint(of: changed) != hash1)
}

@Test func overlayImportFirstTimeSucceedsAndRecordsFingerprint() throws {
    let root = guardTempURL("overlay-first")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = OverlayImportReceiptStore(fileURL: root.appendingPathComponent("receipt.json"))
    #expect(try store.load() == nil)

    let data = try overlayData(1, protected: ["~/Documents/重要"])
    let overlay = try OverlayImportGuard.importOverlay(
        jsonData: data, source: "我的规则.json",
        confirmation: .automatic, store: store
    )
    #expect(overlay.rules.count == 1)

    let receipt = try #require(try store.load())
    #expect(receipt.source == "我的规则.json")
    #expect(receipt.ruleCount == 1)
    #expect(receipt.protectedPathCount == 1)
}

@Test func changedOverlayRequiresExplicitConfirmation() throws {
    let root = guardTempURL("overlay-change")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = OverlayImportReceiptStore(fileURL: root.appendingPathComponent("receipt.json"))

    try OverlayImportGuard.importOverlay(
        jsonData: try overlayData(1), source: "旧规则.json",
        confirmation: .automatic, store: store
    )
    let newData = try overlayData(2)

    #expect(throws: OverlayImportGuardError.self) {
        try OverlayImportGuard.importOverlay(
            jsonData: newData, source: "新规则.json",
            confirmation: .automatic, store: store
        )
    }
    // 被拒后指纹不应被覆盖
    #expect(try store.load()?.source == "旧规则.json")

    // 显式确认后通过，并更新指纹与来源
    let overlay = try OverlayImportGuard.importOverlay(
        jsonData: newData, source: "新规则.json",
        confirmation: .userConfirmed, store: store
    )
    #expect(overlay.rules.count == 2)
    let receipt = try #require(try store.load())
    #expect(receipt.source == "新规则.json")
    #expect(receipt.ruleCount == 2)
}

@Test func unchangedOverlayReimportDoesNotRequireConfirmation() throws {
    let root = guardTempURL("overlay-same")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = OverlayImportReceiptStore(fileURL: root.appendingPathComponent("receipt.json"))
    let data = try overlayData(1)

    try OverlayImportGuard.importOverlay(
        jsonData: data, source: "规则.json", confirmation: .automatic, store: store
    )
    // 同一份内容重复导入，自动通过
    #expect(throws: Never.self) {
        try OverlayImportGuard.importOverlay(
            jsonData: data, source: "规则.json", confirmation: .automatic, store: store
        )
    }
}

@Test func corruptReceiptRefusesImport() throws {
    let root = guardTempURL("overlay-corrupt")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = OverlayImportReceiptStore(fileURL: root.appendingPathComponent("receipt.json"))
    try Data("not json".utf8).write(to: store.fileURL)

    #expect(throws: OverlayImportGuardError.self) {
        try OverlayImportGuard.importOverlay(
            jsonData: try overlayData(1), source: "规则.json",
            confirmation: .automatic, store: store
        )
    }
}
