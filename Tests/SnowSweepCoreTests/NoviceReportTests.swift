import Foundation
import Testing
@testable import SnowSweepCore

@Test func noviceReportUsesRealTotalsAndDecisions() {
    let result = LandingAuditResult(
        clean: [], confirm: [], personal: [], keep: [],
        cleanCount: 4, confirmCount: 2, personalCount: 3, keepCount: 9,
        cleanBytes: 1_024, confirmBytes: 2_048, personalBytes: 4_096,
        recentPersonalCount: 1, recentPersonalBytes: 1_000,
        scannedItemCount: 120,
        reportComplete: true,
        warning: nil
    )
    let report = NoviceReportBuilder.build(
        result: result,
        totalBytes: 500_000,
        freeBytes: 200_000
    )
    #expect(report.usedBytes == 300_000)
    #expect(report.usedFraction == 0.6)
    #expect(report.cleanCount == 4)
    #expect(report.decideCount == 5)
    #expect(report.decideBytes == 6_144)
    #expect(report.keepCount == 9)
    #expect(report.scannedItemCount == 120)
    #expect(report.guidance.count == 3)
    #expect(report.guidance[0].contains("4 项"))
    #expect(report.guidance[2].contains("不动"))
}

@Test func noviceReportClampsImpossibleVolumeValues() {
    let report = NoviceReportBuilder.build(
        result: nil,
        totalBytes: 100,
        freeBytes: 200
    )
    #expect(report.freeBytes == 100)
    #expect(report.usedBytes == 0)
    #expect(report.usedFraction == 0)
    #expect(!report.reportComplete)
}

@Test func noviceReportKeepsTopSixUniqueSpaceItems() {
    let spaces = (0..<9).map { index in
        NoviceSpaceItem(
            name: "目录\(index)",
            path: "/tmp/\(index)",
            bytes: Int64(index * 10),
            category: "测试",
            risk: "只读",
            isPersonal: false
        )
    } + [
        NoviceSpaceItem(name: "重复", path: "/tmp/3", bytes: 30, category: "测试", risk: "只读", isPersonal: false),
        NoviceSpaceItem(name: "空", path: "/tmp/empty", bytes: 0, category: "测试", risk: "只读", isPersonal: false)
    ]
    let report = NoviceReportBuilder.build(
        result: nil,
        totalBytes: 1,
        freeBytes: 1,
        systemSpaces: spaces
    )
    #expect(report.systemSpaces.count == 6)
    #expect(report.systemSpaces.first?.path == "/tmp/8")
    #expect(!report.systemSpaces.contains { $0.path == "/tmp/empty" })
    #expect(Set(report.systemSpaces.map(\.path)).count == 6)
}

@Test func noviceReportKeepsProtectedItemsReadableAndLimited() {
    let keep = (0..<8).map { index in
        NoviceSpaceItem(
            name: "保护\(index)",
            path: "/tmp/protected/\(index)",
            bytes: Int64(index * 100),
            category: "保护项",
            risk: "只读",
            isPersonal: false
        )
    }
    let report = NoviceReportBuilder.build(
        result: nil,
        totalBytes: 1,
        freeBytes: 1,
        keepSpaces: keep
    )
    #expect(report.keepSpaces.count == 6)
    #expect(report.keepSpaces.first?.name == "保护7")
    #expect(report.keepSpaces.allSatisfy { $0.risk == "只读" })
}

@Test func noviceReportCarriesScanGapWarning() {
    let result = LandingAuditResult(
        clean: [], confirm: [], personal: [], keep: [],
        cleanCount: 0, confirmCount: 0, personalCount: 0, keepCount: 0,
        cleanBytes: 0, confirmBytes: 0, personalBytes: 0,
        recentPersonalCount: 0, recentPersonalBytes: 0,
        scannedItemCount: 10,
        reportComplete: true,
        warning: "有 107 个位置没读全，已从可清清单里排除。"
    )
    let report = NoviceReportBuilder.build(result: result, totalBytes: 1, freeBytes: 1)
    #expect(report.reportComplete)
    #expect(report.warning == "有 107 个位置没读全，已从可清清单里排除。")
}

@Test func noviceReportWithoutCleanItemsSaysSoWithoutPretending() {
    let report = NoviceReportBuilder.build(result: nil, totalBytes: 1, freeBytes: 1)
    #expect(report.cleanCount == 0)
    #expect(report.guidance[0].contains("没有扫到"))
    #expect(report.guidance[0].contains("不等于可以乱删"))
}

@Test func protectedLifeRulesProduceReadableKeepTitles() throws {
    let engine = try RuleEngine(jsonURL: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Rules/rules.json"))
    let verdicts = [
        engine.verdict(for: ScanItem(path: "~/Library/Application Support/MobileSync/Backup/00008110/Manifest.db", sizeBytes: 100)),
        engine.verdict(for: ScanItem(path: "~/Pictures/Photos Library.photoslibrary/originals/a.jpg", sizeBytes: 100))
    ]
    let result = LandingAuditBuilder.build(verdicts: verdicts, bigFiles: [])
    let titles = Set(result.keep.map(\.title))
    #expect(titles.contains("iPhone/iPad 备份"))
    #expect(titles.contains("照片图库"))
    #expect(result.keep.allSatisfy { $0.decision == .keep })
}
