import Foundation
import Testing
@testable import SnowSweepCore

private struct FixedDirectoryChecker: DirectoryAccessChecking {
    let existsPaths: Set<String>
    let readablePaths: Set<String>

    func exists(_ path: String) -> Bool { existsPaths.contains(path) }
    func canList(_ path: String) -> Bool { readablePaths.contains(path) }
}

private final class ResultTrasher: FileTrashing, @unchecked Sendable {
    let resultingURL: URL
    var calls: [String] = []

    init(resultingURL: URL) { self.resultingURL = resultingURL }

    func trashItem(at path: String) throws -> URL? {
        calls.append(path)
        return resultingURL
    }

    func removeItem(at path: String) throws {}
}

// MARK: - 保护清单

@Test func protectionBundleRoundTripsWithVersionAndMetadata() throws {
    let data = try ProtectionTransfer.encode(paths: ["~/Pictures/**", "~/Documents/工作/**"])
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["version"] as? Int == 1)
    #expect(json["app"] as? String == SnowIdentity.displayName)
    #expect((json["paths"] as? [String])?.count == 2)
    #expect(try ProtectionTransfer.decode(data) == ["~/Pictures/**", "~/Documents/工作/**"])
}

@Test func protectionImportStillAcceptsLegacyStringArrayAndDeduplicates() throws {
    let data = try JSONEncoder().encode(["~/A/**", "~/A/**", "", " ~/B/** "])
    #expect(try ProtectionTransfer.decode(data) == ["~/A/**", "~/B/**"])
}

@Test func protectionImportRejectsFutureVersion() throws {
    let data = try JSONEncoder().encode(ProtectionBundle(version: 9, paths: ["~/A/**"]))
    #expect(throws: ProtectionTransferError.self) {
        try ProtectionTransfer.decode(data)
    }
}

@Test func protectionOverlapFindsExactCoveredAndBroaderCases() {
    let builtIns = ["~/Library/Mobile Documents/**", "~/.ssh/**", "/Library/**"]
    let overlaps = ProtectionOverlapDetector.inspect(
        paths: ["~/.ssh/**", "~/Library/Mobile Documents/com~apple~CloudDocs/**", "~/Library/**", "~/Pictures/**"],
        builtInPatterns: builtIns,
        home: "/Users/test"
    )
    #expect(overlaps.count == 3)
    #expect(overlaps.first { $0.path == "~/.ssh/**" }?.kind == .duplicate)
    #expect(overlaps.first { $0.path.contains("Mobile Documents") }?.kind == .coveredByBuiltIn)
    #expect(overlaps.first { $0.path == "~/Library/**" }?.kind == .broaderThanBuiltIn)
    #expect(overlaps.allSatisfy { $0.path != "~/Pictures/**" })
}

// MARK: - 目录访问

@Test func directoryAccessSnapshotExplainsMissingAndUnreadableDirectories() {
    let home = "/Users/tester"
    let desktop = home + "/Desktop"
    let documents = home + "/Documents"
    let photos = home + "/Pictures/Photos Library.photoslibrary"
    let checker = FixedDirectoryChecker(
        existsPaths: [desktop, documents, photos],
        readablePaths: [desktop]
    )
    let snapshot = RestrictedDirectoryCatalog.snapshot(home: home, checker: checker)
    let desktopRow = snapshot.directories.first { $0.path == desktop }
    let documentsRow = snapshot.directories.first { $0.path == documents }
    let photosRow = snapshot.directories.first { $0.path == photos }

    #expect(desktopRow?.readable == true)
    #expect(documentsRow?.exists == true)
    #expect(documentsRow?.readable == false)
    #expect(documentsRow?.stateLabel == "读不到")
    #expect(photosRow?.stateExplain.contains("照片") == true)
    // 照片图库不再碰路径，按未验证处理，不计入“读不到”。
    #expect(photosRow?.verified == false)
    #expect(photosRow?.stateLabel == "未验证")
    #expect(snapshot.unreadableCount == 1)
    #expect(snapshot.unverifiedCount >= 5)
}

// MARK: - 缺口报告

@Test func gapReportGroupsBySeverityAndNeverClaimsDeletion() {
    let gaps = [
        ScanGap(kind: .permissionDenied, path: "~/Library/A"),
        ScanGap(kind: .permissionDenied, path: "~/Library/B"),
        ScanGap(kind: .truncated, path: "/", detail: "达到 10000 项上限"),
        ScanGap(kind: .symlinkLoop, path: "~/Link")
    ]
    let groups = ScanGapReport.grouped(gaps)
    #expect(groups.map(\.severity) == [.critical, .warning, .info])
    #expect(groups.first(where: { $0.severity == .warning })?.gaps.count == 2)

    let markdown = ScanGapReport.markdown(gaps: gaps, scanScope: "仅我的用户目录")
    #expect(markdown.contains("局部缺口（2 项）"))
    #expect(markdown.contains("全盘级缺口（1 项）"))
    #expect(markdown.contains("~/Library/A"))
    #expect(markdown.contains("不代表这些目录里有可删除文件"))
}

// MARK: - 审计位置与恢复

@Test func auditResultTokenStaysOutOfDisplayAndHashChain() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SnowSweepResult-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let audit = AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))

    let event = try audit.append(
        action: .moveToTrash,
        path: root.appendingPathComponent("old.cache").path,
        success: true,
        detail: "已移到废纸篓",
        batchID: "clean-test",
        resultingItemURL: root.appendingPathComponent("新 名称 [x].cache").path
    )
    #expect(event.displayDetail == "已移到废纸篓")
    #expect(event.displayDetail.contains("[result:") == false)
    #expect(event.resultingItemURL == root.appendingPathComponent("新 名称 [x].cache").path)
    #expect(try audit.verify().isValid)
}

@Test func rollbackCandidateKeepsExactTrashLocationForNewAudit() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SnowSweepRollback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let moved = root.appendingPathComponent("moved.cache")
    try Data("x".utf8).write(to: moved)
    let audit = AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))

    _ = try audit.append(
        action: .moveToTrash,
        path: root.appendingPathComponent("original.cache").path,
        success: true,
        detail: "已移到废纸篓",
        resultingItemURL: moved.path
    )

    let candidate = try #require(try AuditRollback(audit: audit).candidates().first)
    #expect(candidate.resultingItemURL == moved.path)
    #expect(AuditRollback(audit: audit).exactLocation(for: candidate)?.path == moved.path)
}

@Test func moveToTrashRecordsSystemResultingURL() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SnowSweepTrashResult-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("cache.bin")
    try Data("cache".utf8).write(to: source)
    let trashed = root.appendingPathComponent("trashed-cache.bin")
    try Data("cache".utf8).write(to: trashed)

    let trasher = ResultTrasher(resultingURL: trashed)
    let audit = AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))
    let coordinator = DeletionCoordinator(trasher: trasher, audit: audit)
    let report = ScanReport(scanStatus: "complete", totalBytes: 5, verdicts: [])
    let item = ScanItem(path: source.path, sizeBytes: 5)

    let event = try #require(try coordinator.moveToTrash(item, ruleID: "test-rule", report: report))
    #expect(event.resultingItemURL == trashed.path)
    #expect(event.displayDetail == "已移到废纸篓")
    #expect(event.displayDetail.contains("[result:") == false)
}

@Test func startupDeduplicationKeepsSameNameDifferentRawIdentifiers() {
    let shared = { (label: String, path: String) -> StartupItem in
        StartupItem(
            displayName: "同名后台项", rawLabel: label, scope: .userAgent,
            sourceApp: "测试", rawCommand: "/tmp/bin/\(label)", launchMethod: "登录时自动启动",
            risk: .review, why: "测试", suggestion: "测试", rawPath: path
        )
    }
    let snapshot = StartupSnapshot(
        items: [shared("com.example.a", "/tmp/a.plist"),
                shared("com.example.a", "/tmp/a.plist"),
                shared("com.example.b", "/tmp/b.plist")],
        gaps: [], sourceLabel: "测试"
    )
    #expect(snapshot.items.count == 3)
    #expect(snapshot.deduplicatedItems.count == 2)
}

@Test func fullDiskDirectoriesAreUnverifiedWithoutFDA() {
    let home = "/Users/tester"
    let mail = home + "/Library/Mail"
    let checker = FixedDirectoryChecker(
        existsPaths: [mail],
        readablePaths: [mail]
    )
    let snapshot = RestrictedDirectoryCatalog.snapshot(home: home, checker: checker, hasFullDiskAccess: false)
    let mailRow = snapshot.directories.first { $0.path == mail }
    #expect(mailRow?.exists == true)
    #expect(mailRow?.verified == false)
    #expect(mailRow?.stateLabel == "未验证")
    #expect(mailRow?.stateExplain.contains("不会冒充已检查") == true)
    #expect(snapshot.unverifiedCount >= 1)
    #expect(snapshot.hasFullDiskAccess == false)
}

@Test func fullDiskAccessSnapshotMarksProtectedDirectoriesVerified() {
    let home = "/Users/tester"
    let mail = home + "/Library/Mail"
    let checker = FixedDirectoryChecker(existsPaths: [mail], readablePaths: [mail])
    let snapshot = RestrictedDirectoryCatalog.snapshot(home: home, checker: checker, hasFullDiskAccess: true)
    let mailRow = snapshot.directories.first { $0.path == mail }
    #expect(snapshot.hasFullDiskAccess == true)
    #expect(mailRow?.verified == true)
    #expect(mailRow?.readable == true)
    #expect(mailRow?.stateLabel == "可读取")
}
