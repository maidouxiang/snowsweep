import Foundation
import Testing
@testable import SnowSweepCore

private func verdict(
    path: String,
    bytes: Int64,
    risk: RiskLevel,
    rule: String? = nil,
    needConfirm: Bool = false,
    explanation: String = "规则原文"
) -> Verdict {
    Verdict(
        item: ScanItem(path: path, sizeBytes: bytes, modifiedAt: Date()),
        risk: risk,
        explanation: explanation,
        evidence: rule.map { ["rule:\($0)"] } ?? [],
        needConfirm: needConfirm
    )
}

@Test func auditSplitsCleanConfirmAndKeep() {
    let result = LandingAuditBuilder.build(
        verdicts: [
            verdict(path: "/Users/a/Library/Caches/npm", bytes: 900, risk: .safe, rule: "npm-cache"),
            verdict(path: "/Users/a/Library/Developer/Xcode/DerivedData", bytes: 700, risk: .review, rule: "xcode-derived-data"),
            verdict(path: "/Users/a/Library/Caches/important", bytes: 500, risk: .safe, rule: "user-app-caches", needConfirm: true),
            verdict(path: "/System/Library/CoreServices", bytes: 400, risk: .protected, rule: "system-caches")
        ],
        bigFiles: []
    )

    #expect(result.clean.count == 1)
    #expect(result.clean.first?.title == "npm 缓存")
    #expect(result.confirm.count == 2)
    #expect(result.keep.count == 1)
    #expect(result.cleanBytes == 900)
    #expect(result.confirmBytes == 1_200)
    #expect(result.personal.isEmpty)
    #expect(result.scannedItemCount == 4)
}

@Test func auditOrdersBySizeAndCountsFullSet() {
    let result = LandingAuditBuilder.build(
        verdicts: [
            verdict(path: "/Users/a/cache-small", bytes: 100, risk: .safe, rule: "user-app-caches"),
            verdict(path: "/Users/a/cache-big", bytes: 900, risk: .safe, rule: "user-app-caches"),
            verdict(path: "/Users/a/cache-mid", bytes: 400, risk: .safe, rule: "user-app-caches")
        ],
        bigFiles: [],
        maxPerSection: 1,
        maxCleanItems: 1
    )

    #expect(result.clean.count == 1)
    #expect(result.clean.first?.path == "/Users/a/cache-big")
    #expect(result.cleanCount == 3)
    #expect(result.cleanBytes == 1_400)
}

@Test func auditDeduplicatesBigFilesAlreadyKnownToRules() {
    let now = Date()
    let result = LandingAuditBuilder.build(
        verdicts: [
            verdict(path: "/Users/a/Downloads/old.dmg", bytes: 600, risk: .review, rule: "installers-dmg")
        ],
        bigFiles: [
            LargeFileRecord(path: "/Users/a/Downloads/old.dmg", bytes: 600, modifiedAt: now),
            LargeFileRecord(path: "/Users/a/Movies/take.mov", bytes: 5_000, modifiedAt: now.addingTimeInterval(-2 * 86_400))
        ],
        now: now
    )

    #expect(result.confirm.count == 1)
    #expect(result.personal.count == 1)
    #expect(result.personal.first?.path == "/Users/a/Movies/take.mov")
    #expect(result.personal.first?.decision == .personal)
    #expect(result.personal.first?.category == "最近 7 天改过的大文件（≥20MB）")
    #expect(result.recentPersonalCount == 1)
    #expect(result.recentPersonalBytes == 5_000)
}

@Test func auditPutsRecentlyChangedFilesFirst() {
    let now = Date()
    let result = LandingAuditBuilder.build(
        verdicts: [],
        bigFiles: [
            LargeFileRecord(path: "/Users/a/Movies/huge-old.mov", bytes: 90_000, modifiedAt: now.addingTimeInterval(-300 * 86_400)),
            LargeFileRecord(path: "/Users/a/Downloads/today.zip", bytes: 1_000, modifiedAt: now.addingTimeInterval(-3_600))
        ],
        now: now
    )

    #expect(result.personal.count == 2)
    #expect(result.personal.first?.path == "/Users/a/Downloads/today.zip")
    #expect(result.personal.last?.path == "/Users/a/Movies/huge-old.mov")
    #expect(result.recentPersonalCount == 1)
}

@Test func auditKeepsProtectedItemsUnTrashable() {
    let result = LandingAuditBuilder.build(
        verdicts: [
            verdict(path: "/Users/a/photo-library", bytes: 3_000, risk: .unknown)
        ],
        bigFiles: []
    )

    #expect(result.keep.count == 1)
    #expect(result.keep.first?.isTrashable == false)
    #expect(result.keep.first?.title == "photo-library")
}

@Test func auditCarriesReportWarningAndLockState() {
    let result = LandingAuditBuilder.build(
        verdicts: [verdict(path: "/Users/a/npm", bytes: 10, risk: .safe, rule: "npm-cache")],
        bigFiles: [],
        reportComplete: false,
        warning: "扫描不完整，已锁定"
    )

    #expect(result.reportComplete == false)
    #expect(result.warning == "扫描不完整，已锁定")
    #expect(result.clean.first?.isTrashable == true)
}
