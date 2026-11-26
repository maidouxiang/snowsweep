import Foundation
import Testing
@testable import SnowSweepCore

private var fixedNow: Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = 2026
    components.month = 11
    components.day = 24
    components.hour = 12
    return components.date!
}

private func daysAgo(_ days: Int) -> Date {
    Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: fixedNow)!
}

@Test func largeFileKindUsesExtensionWithoutGuessing() {
    #expect(LargeFileKind.classify(ext: "MP4") == .video)
    #expect(LargeFileKind.classify(ext: "psd") == .image)
    #expect(LargeFileKind.classify(ext: "dmg") == .installer)
    #expect(LargeFileKind.classify(ext: "zip") == .archive)
    #expect(LargeFileKind.classify(ext: "pdf") == .document)
    #expect(LargeFileKind.classify(ext: "") == .other)
}

@Test func largeFileFilterCombinesEveryCondition() {
    let records = [
        LargeFileRecord(path: "/Users/me/Downloads/a.mp4", bytes: 2_000_000_000, modifiedAt: daysAgo(10)),
        LargeFileRecord(path: "/Users/me/Pictures/b.psd", bytes: 600_000_000, modifiedAt: daysAgo(200)),
        LargeFileRecord(path: "/Users/me/Downloads/c.dmg", bytes: 1_200_000_000, modifiedAt: daysAgo(400)),
        LargeFileRecord(path: "/Users/me/Movies/d.mov", bytes: 90_000_000, modifiedAt: daysAgo(1)),
        LargeFileRecord(path: "/Users/me/Downloads/archive.zip", bytes: 120_000_000, modifiedAt: daysAgo(800))
    ]
    let filter = LargeFileFilter(query: "downloads", kind: .video, age: .recent365,
                                 minMegabytes: 100, sort: .size)
    let result = filter.apply(to: records, now: fixedNow)
    #expect(result.count == 1)
    #expect(result.first?.name == "a.mp4")
}

@Test func largeFileFilterAgeKeepsBoundariesRecent() {
    let boundaries = LargeFileRecord(path: "/tmp/30.mov", bytes: 1_000_000_000,
                                     modifiedAt: daysAgo(30))
    let earlier = LargeFileRecord(path: "/tmp/31.mov", bytes: 1_000_000_000,
                                    modifiedAt: daysAgo(31))
    let old = LargeFileRecord(path: "/tmp/500.mov", bytes: 1_000_000_000,
                               modifiedAt: daysAgo(500))
    let recent = LargeFileFilter(age: .recent30, sort: .name)
        .apply(to: [old, boundaries, earlier], now: fixedNow)
    #expect(recent.map(\.name) == ["30.mov"])
    let older = LargeFileFilter(age: .older365, sort: .name)
        .apply(to: [old, boundaries, earlier], now: fixedNow)
    #expect(older.map(\.name) == ["500.mov"])
}

@Test func largeFileFilterSortsByNameAndDateDeterministically() {
    let records = [
        LargeFileRecord(path: "/tmp/z.mov", bytes: 300_000_000, modifiedAt: daysAgo(2)),
        LargeFileRecord(path: "/tmp/a.mov", bytes: 100_000_000, modifiedAt: daysAgo(1)),
        LargeFileRecord(path: "/tmp/m.mov", bytes: 200_000_000, modifiedAt: daysAgo(2))
    ]
    let byName = LargeFileFilter(sort: .name).apply(to: records, now: fixedNow)
    #expect(byName.map(\.name) == ["a.mov", "m.mov", "z.mov"])
    let byDate = LargeFileFilter(sort: .modified).apply(to: records, now: fixedNow)
    #expect(byDate.map(\.name) == ["a.mov", "m.mov", "z.mov"])
    let bySize = LargeFileFilter(sort: .size).apply(to: records, now: fixedNow)
    #expect(bySize.map(\.name) == ["z.mov", "m.mov", "a.mov"])
}

@Test func largeFileFilterTrimsQueryAndEnforcesSizeFloor() {
    let records = [
        LargeFileRecord(path: "/tmp/alpha.MOV", bytes: 100_000_000, modifiedAt: fixedNow),
        LargeFileRecord(path: "/tmp/beta.mov", bytes: 99_999_999, modifiedAt: fixedNow)
    ]
    let result = LargeFileFilter(query: "  alpha  ").apply(to: records, now: fixedNow)
    #expect(result.count == 1)
    #expect(result.first?.path == "/tmp/alpha.MOV")
}

@Test func duplicateGrouperRequiresSameSizeAndDigest() {
    let a = DuplicateFileRecord(path: "/tmp/a.jpg", bytes: 2_000_000, modifiedAt: fixedNow, digest: "aa")
    let b = DuplicateFileRecord(path: "/tmp/b.jpg", bytes: 2_000_000, modifiedAt: fixedNow, digest: "aa")
    let c = DuplicateFileRecord(path: "/tmp/c.jpg", bytes: 2_000_000, modifiedAt: fixedNow, digest: "bb")
    let d = DuplicateFileRecord(path: "/tmp/d.jpg", bytes: 2_000_000, modifiedAt: fixedNow, digest: "")
    let groups = DuplicateGrouper.group([a, b, c, d])
    #expect(groups.count == 1)
    #expect(groups.first?.files.map(\.name) == ["a.jpg", "b.jpg"])
    #expect(groups.first?.recoverableBytes == 2_000_000)
}

@Test func duplicateGrouperSortsByRecoverableBytesAndFileCount() {
    let tripleA = [
        DuplicateFileRecord(path: "/tmp/a1.zip", bytes: 1_000, modifiedAt: fixedNow, digest: "a"),
        DuplicateFileRecord(path: "/tmp/a2.zip", bytes: 1_000, modifiedAt: fixedNow, digest: "a"),
        DuplicateFileRecord(path: "/tmp/a3.zip", bytes: 1_000, modifiedAt: fixedNow, digest: "a")
    ]
    let doubleB = [
        DuplicateFileRecord(path: "/tmp/b1.zip", bytes: 4_000, modifiedAt: fixedNow, digest: "b"),
        DuplicateFileRecord(path: "/tmp/b2.zip", bytes: 4_000, modifiedAt: fixedNow, digest: "b")
    ]
    let single = DuplicateFileRecord(path: "/tmp/c.zip", bytes: 10_000, modifiedAt: fixedNow, digest: "c")
    let groups = DuplicateGrouper.group(tripleA + doubleB + [single])
    #expect(groups.count == 2)
    #expect(groups.first?.digest == "b")
    #expect(groups.first?.recoverableBytes == 4_000)
    #expect(groups.last?.digest == "a")
    #expect(groups.last?.recoverableBytes == 2_000)
}

@Test func duplicateReviewIsReviewOnlyAndSumsWaste() {
    let records = [
        DuplicateFileRecord(path: "/tmp/a.mov", bytes: 1_500, modifiedAt: fixedNow, digest: "aa"),
        DuplicateFileRecord(path: "/tmp/b.mov", bytes: 1_500, modifiedAt: fixedNow, digest: "aa"),
        DuplicateFileRecord(path: "/tmp/c.mov", bytes: 2_000, modifiedAt: fixedNow, digest: "bb"),
        DuplicateFileRecord(path: "/tmp/d.mov", bytes: 2_000, modifiedAt: fixedNow, digest: "bb")
    ]
    let review = DuplicateReview(groups: DuplicateGrouper.group(records), candidates: 4,
                                 hashedFiles: 4, skippedFiles: 0, truncated: false, timedOut: false)
    #expect(review.fileCount == 4)
    #expect(review.recoverableBytes == 3_500)
    #expect(DuplicateReview.policy.contains("不删除"))
    #expect(DuplicateReview.policy.contains("不勾选"))
}

@Test func halfYearDimensionFindsPersonalDocumentsWithoutGuessingContent() {
    let oldProject = LargeFileRecord(path: "/Users/me/Desktop/策划/方案.pptx",
                                     bytes: 175_000_000, modifiedAt: daysAgo(200))
    let recentProject = LargeFileRecord(path: "/Users/me/Desktop/策划/新案.pptx",
                                        bytes: 175_000_000, modifiedAt: daysAgo(20))
    #expect(oldProject.matches(.oldLarge, home: "/Users/me", now: fixedNow))
    #expect(!recentProject.matches(.oldLarge, home: "/Users/me", now: fixedNow))
    #expect(oldProject.judgement(home: "/Users/me", now: fixedNow).title == "半年以上未改")
    let summary = StorageDimensionSummary.summarize([oldProject, recentProject],
                                                    home: "/Users/me", now: fixedNow)
    let oldLarge = summary.first { $0.dimension == .oldLarge }
    #expect(oldLarge?.count == 1)
    #expect(oldLarge?.bytes == 175_000_000)
}

@Test func oldDownloadDimensionOnlyCoversDownloadsAndRespects180Days() {
    let oldDownload = LargeFileRecord(path: "/Users/me/Downloads/old.pdf",
                                      bytes: 120_000_000, modifiedAt: daysAgo(181))
    let newDownload = LargeFileRecord(path: "/Users/me/Downloads/new.pdf",
                                      bytes: 120_000_000, modifiedAt: daysAgo(179))
    let oldDesktop = LargeFileRecord(path: "/Users/me/Desktop/old.pdf",
                                     bytes: 120_000_000, modifiedAt: daysAgo(181))
    #expect(oldDownload.matches(.oldDownload, home: "/Users/me", now: fixedNow))
    #expect(!newDownload.matches(.oldDownload, home: "/Users/me", now: fixedNow))
    #expect(!oldDesktop.matches(.oldDownload, home: "/Users/me", now: fixedNow))
}
