import Foundation
import Testing
@testable import SnowSweepCore

private func manualTempRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SnowSweepManual-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private final class ManualTrasher: FileTrashing, @unchecked Sendable {
    var trashCalls: [String] = []
    var removeCalls: [String] = []
    func trashItem(at path: String) throws -> URL? {
        trashCalls.append(path)
        return URL(fileURLWithPath: "/tmp/trash/\(URL(fileURLWithPath: path).lastPathComponent)")
    }
    func removeItem(at path: String) throws { removeCalls.append(path) }
}

@Test func manualPreviewCapturesIdentityAndSize() throws {
    let root = try manualTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("old.dmg")
    try Data(repeating: 1, count: 32).write(to: file)

    let service = ManualDeletionService(allowedRoots: [root.path])
    let plan = try service.preview(path: file.path, reason: "旧安装包")
    #expect(plan.identity.kind == .file)
    #expect(plan.sizeBytes == 32)
    #expect(plan.reason == "旧安装包")
}

@Test func manualDeletionRejectsReplacedFile() throws {
    let root = try manualTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("copy.bin")
    try Data("old".utf8).write(to: file)

    let service = ManualDeletionService(
        trasher: ManualTrasher(),
        audit: AuditLog(fileURL: root.appendingPathComponent("audit.jsonl")),
        allowedRoots: [root.path]
    )
    let plan = try service.preview(path: file.path, reason: "重复副本")

    try FileManager.default.removeItem(at: file)
    try Data("new".utf8).write(to: file)

    #expect(throws: ManualDeletionError.self) {
        try service.moveToTrash(plan, source: "大文件")
    }
    let events = try service.audit.events()
    #expect(events.last?.action == .targetRejected)
}

@Test func manualDeletionMovesToTrashAndWritesAudit() throws {
    let root = try manualTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("old.zip")
    try Data("zip".utf8).write(to: file)
    let trasher = ManualTrasher()
    let service = ManualDeletionService(
        trasher: trasher,
        audit: AuditLog(fileURL: root.appendingPathComponent("audit.jsonl")),
        allowedRoots: [root.path]
    )
    let plan = try service.preview(path: file.path, reason: "旧压缩包")
    let event = try service.moveToTrash(plan, source: "大文件")

    #expect(trasher.trashCalls == [file.path])
    #expect(trasher.removeCalls.isEmpty)
    #expect(event.action == .moveToTrash)
    #expect(event.ruleID?.hasPrefix("manual:") == true)
    #expect(event.success)
}

@Test func manualDeletionRejectsProtectedPath() throws {
    let root = try manualTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: file)
    let service = ManualDeletionService(
        protectionCheck: { $0.hasSuffix("keep.txt") },
        allowedRoots: [root.path]
    )
    #expect(throws: ManualDeletionError.self) {
        try service.preview(path: file.path, reason: "测试")
    }
}

@Test func manualDeletionRejectsSymlinkAndOutsideRoot() throws {
    let root = try manualTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real.txt")
    try Data("x".utf8).write(to: real)
    let link = root.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let service = ManualDeletionService(allowedRoots: [root.path])

    #expect(throws: ManualDeletionError.self) {
        try service.preview(path: link.path, reason: "测试")
    }
    #expect(throws: ManualDeletionError.self) {
        try service.preview(path: "/etc/hosts", reason: "测试")
    }
}
