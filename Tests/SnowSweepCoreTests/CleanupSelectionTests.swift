import Foundation
import Testing
@testable import SnowSweepCore

private func verdict(
    path: String,
    risk: RiskLevel,
    needConfirm: Bool = false,
    evidence: [String] = [],
    size: Int64 = 10
) -> Verdict {
    Verdict(
        item: ScanItem(path: path, sizeBytes: size),
        risk: risk,
        explanation: "test",
        evidence: evidence,
        needConfirm: needConfirm
    )
}

private func report(_ verdicts: [Verdict], complete: Bool = true) -> ScanReport {
    ScanReport(
        scanStatus: complete ? "complete" : "partial",
        totalBytes: 100,
        verdicts: verdicts,
        scanGaps: complete ? [] : [ScanGap(kind: .tccDenied, path: "/")]
    )
}

@Test func onlyDefaultSelectedItemsAreCleanable() {
    let r = report([
        verdict(path: "/safe/a", risk: .safe, evidence: ["rule:r1"], size: 10),
        verdict(path: "/review/b", risk: .review, needConfirm: true, size: 20),
        verdict(path: "/protected/c", risk: .protected, needConfirm: true, size: 30),
        verdict(path: "/unknown/d", risk: .unknown, needConfirm: true, size: 40),
        verdict(path: "/safe-confirm/e", risk: .safe, needConfirm: true, size: 50)
    ])
    // UI 恶意/误传：把所有路径都勾选
    let allPaths = Set(r.verdicts.map(\.item.path))
    let entries = CleanupSelection.safeEntries(from: r, selectedPaths: allPaths)

    #expect(entries.count == 1)
    #expect(entries.first?.verdict.item.path == "/safe/a")
    #expect(entries.first?.ruleID == "r1")
}

@Test func safeButNeedConfirmIsExcluded() {
    // needConfirm 优先于 safe，默认不勾选，也不允许被 selection 放行。
    let r = report([verdict(path: "/x", risk: .safe, needConfirm: true)])
    let entries = CleanupSelection.safeEntries(from: r, selectedPaths: ["/x"])
    #expect(entries.isEmpty)
}

@Test func incompleteReportYieldsNoEntries() {
    let r = report([verdict(path: "/safe/a", risk: .safe, evidence: ["rule:r1"])], complete: false)
    #expect(r.canClean == false)
    #expect(CleanupSelection.safeEntries(from: r, selectedPaths: ["/safe/a"]).isEmpty)
    #expect(CleanupSelection.allSafeEntries(from: r).isEmpty)
}

@Test func allSafeEntriesIgnoresSelection() {
    let r = report([
        verdict(path: "/safe/a", risk: .safe, evidence: ["rule:r1"], size: 10),
        verdict(path: "/safe/b", risk: .safe, evidence: ["rule:r2"], size: 15),
        verdict(path: "/review/c", risk: .review, needConfirm: true, size: 20)
    ])
    let entries = CleanupSelection.allSafeEntries(from: r)
    #expect(entries.count == 2)
    #expect(Set(entries.map(\.ruleID)) == Set(["r1", "r2"]))
}

@Test func summaryCountsBytes() {
    let r = report([
        verdict(path: "/a", risk: .safe, size: 10),
        verdict(path: "/b", risk: .safe, size: 32)
    ])
    let entries = CleanupSelection.allSafeEntries(from: r)
    let s = CleanupSelection.summary(entries)
    #expect(s.count == 2)
    #expect(s.bytes == 42)
}

@Test func ruleIDExtractionHandlesMissingEvidence() {
    let withRule = verdict(path: "/a", risk: .safe, evidence: ["rebuildCost:none", "rule:abc.def"])
    let without = verdict(path: "/b", risk: .safe, evidence: ["no-rule"])
    #expect(CleanupSelection.ruleID(for: withRule) == "abc.def")
    #expect(CleanupSelection.ruleID(for: without) == nil)
}

@Test func reviewNeedsExplicitAllowReview() {
    let r = report([
        verdict(path: "/review/cache", risk: .review, needConfirm: true, evidence: ["rule:system-caches"])
    ])
    let paths: Set<String> = ["/review/cache"]
    #expect(CleanupSelection.entries(from: r, selectedPaths: paths).isEmpty)
    #expect(CleanupSelection.entries(from: r, selectedPaths: paths, allowReview: true).count == 1)
}

@Test func cleanupAdviceThreeLevels() {
    let r = report([
        verdict(path: "/safe/a", risk: .safe, evidence: ["rule:safe"], size: 10),
        verdict(path: "/Library/Caches/b", risk: .review, needConfirm: true, evidence: ["rule:system-caches"], size: 20),
        verdict(path: "/Downloads/old.dmg", risk: .review, needConfirm: true, evidence: ["rule:installers-old"], size: 30),
        verdict(path: "/.Trash/c", risk: .review, needConfirm: true, evidence: ["rule:trash"], size: 40)
    ])
    let conservative = CleanupAdvisor.advice(from: r, level: .conservative)
    let normal = CleanupAdvisor.advice(from: r, level: .normal)
    let aggressive = CleanupAdvisor.advice(from: r, level: .aggressive)

    #expect(conservative.count == 1)
    #expect(normal.count == 2)
    #expect(aggressive.count == 4)
    #expect(Set(normal.verdicts.map(\.item.path)) == Set(["/safe/a", "/Library/Caches/b"]))
}

// MARK: - 祖先折叠（真机实测发现的缺陷回归）

@Test func nestedChildIsFoldedWhenParentIsAlsoAllowed() {
    // 扫描器会同时输出目录和目录内文件；两者都默认可清理时只保留父目录，
    // 否则父目录先移走会让子条目的删除前复核报 vanished 并中断整批。
    let r = report([
        verdict(path: "/cache/nested", risk: .safe, evidence: ["rule:r1"], size: 10),
        verdict(path: "/cache/nested/deep.dat", risk: .safe, evidence: ["rule:r1"], size: 20),
        verdict(path: "/cache/top.dat", risk: .safe, evidence: ["rule:r1"], size: 30)
    ])
    let entries = CleanupSelection.allSafeEntries(from: r)
    #expect(entries.count == 2)
    #expect(Set(entries.map(\.verdict.item.path)) == Set(["/cache/nested", "/cache/top.dat"]))
}

@Test func childSurvivesWhenParentIsNotAllowed() {
    // 父目录是 review 未被放行时，子文件仍可单独清理，不能误折叠掉。
    let r = report([
        verdict(path: "/cache/nested", risk: .review, needConfirm: true, size: 10),
        verdict(path: "/cache/nested/deep.dat", risk: .safe, evidence: ["rule:r1"], size: 20)
    ])
    let allPaths = Set(r.verdicts.map(\.item.path))
    let entries = CleanupSelection.safeEntries(from: r, selectedPaths: allPaths)
    #expect(entries.count == 1)
    #expect(entries.first?.verdict.item.path == "/cache/nested/deep.dat")
}

@Test func foldingHandlesTrailingSlashAndDuplicatePaths() {
    let r = report([
        verdict(path: "/cache/dir/", risk: .safe, evidence: ["rule:r1"], size: 10),
        verdict(path: "/cache/dir/child.dat", risk: .safe, evidence: ["rule:r1"], size: 20)
    ])
    let entries = CleanupSelection.allSafeEntries(from: r)
    #expect(entries.count == 1)
    #expect(entries.first?.verdict.item.path == "/cache/dir/")
}

// MARK: - 清理前访问预检（V0.8.1 系统保护目录）

@Test func accessibleTempFilePassesReadiness() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("snow-readiness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("ok.txt")
    try "ok".write(to: file, atomically: true, encoding: .utf8)
    #expect(CleanupSelection.Readiness.isAccessible(file.path))
}

@Test func unreadableOrUnwritableItemIsBlocked() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("snow-readiness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    let blocked = dir.appendingPathComponent("blocked.txt")
    try "secret".write(to: blocked, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
    #expect(!CleanupSelection.Readiness.isAccessible(blocked.path))
    #expect(CleanupSelection.Readiness.blocked(paths: [blocked.path]) == [blocked.path])
}
