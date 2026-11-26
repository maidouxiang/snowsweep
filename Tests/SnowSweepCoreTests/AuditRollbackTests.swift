import Foundation
import Testing
@testable import SnowSweepCore

private func rollbackTempURL(_ name: String) -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SnowSweepRollbackTest-\(UUID().uuidString)-\(name)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func rollbackListsOnlySuccessfulTrashAndBackupMoves() throws {
    let root = rollbackTempURL("candidates")
    defer { try? FileManager.default.removeItem(at: root) }
    let audit = AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))

    try audit.append(action: .dryRun, path: "批次共 3 项", success: true)
    try audit.append(action: .moveToTrash, path: "/Users/me/Library/Caches/a.dat",
                     ruleID: "cache-a", sizeBytes: 100, success: true, detail: "已移到废纸篓")
    try audit.append(action: .moveToTrash, path: "/Users/me/Library/Caches/b.dat",
                     sizeBytes: 200, success: false, detail: "移入失败")
    try audit.append(action: .movedToBackup, path: "/Users/me/Library/Caches/c.dat",
                     sizeBytes: 300, success: true,
                     detail: "废纸篓失败后按用户选择备份到 /Users/me/Backup/c.dat")
    try audit.append(action: .permanentDelete, path: "/Users/me/d.dat", success: true)

    let candidates = try AuditRollback(audit: audit).candidates()
    #expect(candidates.count == 2)
    let trashed = try #require(candidates.first { $0.displayName == "a.dat" })
    #expect(trashed.destination == .trash)
    #expect(trashed.ruleID == "cache-a")
    #expect(trashed.sizeBytes == 100)
    let backed = try #require(candidates.first { $0.displayName == "c.dat" })
    #expect(backed.destination == .backup("/Users/me/Backup/c.dat"))
    #expect(candidates.allSatisfy { $0.displayName != "b.dat" && $0.displayName != "d.dat" })
}

@Test func rollbackOrdersCandidatesNewestFirst() throws {
    let root = rollbackTempURL("order")
    defer { try? FileManager.default.removeItem(at: root) }
    let audit = AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))
    let now = Date()
    try audit.append(action: .moveToTrash, path: "/tmp/old.dat",
                     success: true, at: now.addingTimeInterval(-3600))
    try audit.append(action: .moveToTrash, path: "/tmp/new.dat",
                     success: true, at: now)
    let candidates = try AuditRollback(audit: audit).candidates()
    #expect(candidates.map(\.displayName) == ["new.dat", "old.dat"])
}

@Test func rollbackRefusesBrokenAuditChain() throws {
    let root = rollbackTempURL("broken")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("audit.jsonl")
    let audit = AuditLog(fileURL: file)
    try audit.append(action: .moveToTrash, path: "/tmp/a.dat", success: true)

    // 篡改第一条记录的说明，制造"记录损坏"，同时让后续链对不上。
    var text = try String(contentsOf: file, encoding: .utf8)
    text = text.replacingOccurrences(of: "\"detail\":\"\"", with: "\"detail\":\"被改过\"")
    try text.write(to: file, atomically: true, encoding: .utf8)

    #expect(throws: RollbackError.self) {
        try AuditRollback(audit: audit).candidates()
    }
}

@Test func rollbackBackupDestinationChecksDirectoryExists() throws {
    let root = rollbackTempURL("backup")
    defer { try? FileManager.default.removeItem(at: root) }
    let backup = root.appendingPathComponent("backup")
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    let audit = AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))
    try audit.append(action: .movedToBackup, path: "/tmp/a.dat", success: true,
                     detail: "废纸篓失败后按用户选择备份到 \(backup.path)")
    let helper = AuditRollback(audit: audit)
    let candidate = try #require(try helper.candidates().first)
    #expect(helper.backupDestination(for: candidate)?.path == backup.path)

    try FileManager.default.removeItem(at: backup)
    #expect(helper.backupDestination(for: candidate) == nil)
}

@Test func rollbackNeverTreatsPermanentDeleteAsRecoverable() throws {
    let root = rollbackTempURL("permanent")
    defer { try? FileManager.default.removeItem(at: root) }
    let audit = AuditLog(fileURL: root.appendingPathComponent("audit.jsonl"))
    try audit.append(action: .permanentDelete, path: "/tmp/gone.dat", success: true)
    try audit.append(action: .targetRejected, path: "/tmp/kept.dat", success: false)
    #expect(try AuditRollback(audit: audit).candidates().isEmpty)
}
