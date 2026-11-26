import Foundation
import Testing
@testable import SnowSweepCore

private let gb: Int64 = 1_000_000_000

private func snapshot(
    hoursAgo: Double,
    freeGB: Int64?,
    entries: [(String, Int64, Bool)]
) -> SpaceSnapshot {
    let at = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-hoursAgo * 3_600)
    return SpaceSnapshot(
        at: at,
        diskTotalBytes: 500 * gb,
        diskFreeBytes: freeGB.map { $0 * gb },
        source: "test",
        entries: entries.map {
            SpaceSnapshotEntry(path: $0.0, bytes: $0.1 * gb, isPartial: $0.2)
        }
    )
}

@Test func spaceDeltaQueryParsesAfternoonAndDays() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let afternoon = SpaceDeltaQuery.parse("为什么一下午少了 40G", now: now)
    #expect(afternoon.label == "这一下午")
    #expect(abs(afternoon.end.timeIntervalSince(afternoon.start) - 5 * 3_600) < 1)

    let threeDays = SpaceDeltaQuery.parse("最近 3 天空间少了多少", now: now)
    #expect(threeDays.label == "最近 3 天")
    #expect(abs(threeDays.end.timeIntervalSince(threeDays.start) - 3 * 86_400) < 1)
}

@Test func spaceDeltaQuestionDoesNotHijackLogComplaints() {
    #expect(SpaceDeltaQuery.isChangeQuestion("为什么一下午少了 40G"))
    #expect(SpaceDeltaQuery.isChangeQuestion("空间去哪了，磁盘怎么满了"))
    #expect(SpaceDeltaQuery.isChangeQuestion("我40G的内存哪里去了？"))
    #expect(!SpaceDeltaQuery.isChangeQuestion("日志少了几条"))
    #expect(!SpaceDeltaQuery.isChangeQuestion("微信缓存有多大"))
}

@Test func spaceDeltaAttributesFortyGigabytesAndKeepsUnknownExplicit() {
    let baseline = snapshot(
        hoursAgo: 6,
        freeGB: 100,
        entries: [("/Users/test/Desktop", 20, false),
                  ("/Users/test/Library", 10, false)]
    )
    let current = snapshot(
        hoursAgo: 0,
        freeGB: 60,
        entries: [("/Users/test/Desktop", 50, false),
                  ("/Users/test/Library", 15, false),
                  ("/Users/test/Downloads", 2, false)]
    )
    let query = SpaceDeltaQuery(rawText: "为什么一下午少了 40G", label: "这一下午",
                                start: baseline.at, end: current.at)
    let report = SpaceDeltaDiagnostic.report(snapshots: [baseline, current], query: query)

    #expect(report.dataSufficient)
    #expect(report.diskFreeDelta == -40 * gb)
    #expect(report.usedDelta == 40 * gb)
    #expect(report.attributedBytes == 37 * gb)
    #expect(report.unexplainedBytes == 3 * gb)
    #expect(report.topChanges.first?.path == "/Users/test/Desktop")
    #expect(report.topChanges.first?.deltaBytes == 30 * gb)
    #expect(report.explanation.contains("未归因"))
    #expect(report.topChanges.contains { $0.state == .appeared && $0.path == "/Users/test/Downloads" })
}

@Test func spaceDeltaComparesLeafDirectoriesWithoutDoubleCountingParent() {
    let baseline = snapshot(
        hoursAgo: 4,
        freeGB: 100,
        entries: [("/Users/test/Library", 100, false),
                  ("/Users/test/Library/Caches", 60, false)]
    )
    let current = snapshot(
        hoursAgo: 0,
        freeGB: 92,
        entries: [("/Users/test/Library", 110, false),
                  ("/Users/test/Library/Caches", 70, false)]
    )
    let query = SpaceDeltaQuery(rawText: "空间变化", label: "最近四小时",
                                start: baseline.at, end: current.at)
    let report = SpaceDeltaDiagnostic.report(snapshots: [baseline, current], query: query)

    #expect(report.attributedBytes == 10 * gb)
    #expect(report.unexplainedBytes == -2 * gb)
    #expect(report.topChanges.count == 1)
    #expect(report.topChanges.first?.path == "/Users/test/Library/Caches")
    #expect(report.topChanges.first?.deltaBytes == 10 * gb)
}

@Test func spaceDeltaWithoutSnapshotsSaysInsufficientData() {
    let report = SpaceDeltaDiagnostic.report(
        snapshots: [],
        query: SpaceDeltaQuery(rawText: "为什么少了 40G", label: "最近七天",
                               start: Date(), end: Date())
    )
    #expect(!report.dataSufficient)
    #expect(report.reason?.contains("还没有任何空间快照") == true)
    #expect(report.topChanges.isEmpty)
}

@Test func spaceDeltaWithSingleSnapshotSaysInsufficientData() {
    let only = snapshot(hoursAgo: 0, freeGB: 100,
                        entries: [("/Users/test/Desktop", 20, false)])
    let query = SpaceDeltaQuery(rawText: "为什么少了 40G", label: "最近七天",
                                start: only.at.addingTimeInterval(-7 * 86_400), end: only.at)
    let report = SpaceDeltaDiagnostic.report(snapshots: [only], query: query)

    #expect(!report.dataSufficient)
    #expect(report.reason?.contains("只有一次快照") == true)
}

@Test func spaceDeltaMarksPartialEntries() {
    let baseline = snapshot(hoursAgo: 2, freeGB: 100,
                            entries: [("/Users/test/Library", 10, true)])
    let current = snapshot(hoursAgo: 0, freeGB: 90,
                           entries: [("/Users/test/Library", 25, true)])
    let query = SpaceDeltaQuery(rawText: "空间变化", label: "最近两小时",
                                start: baseline.at, end: current.at)
    let report = SpaceDeltaDiagnostic.report(snapshots: [baseline, current], query: query)

    #expect(report.partialCount == 1)
    #expect(report.caveat.contains("没读全"))
}

@Test func spaceSnapshotStoreAppendsAndBuildsReport() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("snow-space-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = SpaceSnapshotStore(fileURL: root.appendingPathComponent("space.jsonl"))
    let now = Date()
    let before = SpaceSnapshot(
        at: now.addingTimeInterval(-3_600),
        diskFreeBytes: 100 * gb,
        entries: [SpaceSnapshotEntry(path: "/Users/test/Desktop", bytes: 20 * gb)]
    )
    let after = SpaceSnapshot(
        at: now,
        diskFreeBytes: 80 * gb,
        entries: [SpaceSnapshotEntry(path: "/Users/test/Desktop", bytes: 40 * gb)]
    )
    try store.append(before)
    try store.append(after)

    let loaded = try store.snapshots()
    #expect(loaded.count == 2)
    let report = try store.report(for: "为什么少空间了", now: now)
    #expect(report.diskFreeDelta == -20 * gb)
    #expect(report.topChanges.first?.deltaBytes == 20 * gb)
}

@Test func spaceSnapshotStoreSkipsCorruptLines() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("snow-space-bad-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("space.jsonl")
    let store = SpaceSnapshotStore(fileURL: file)
    try store.append(SpaceSnapshot(at: Date(), diskFreeBytes: 10 * gb, entries: []))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{bad json}\n".utf8))
    try handle.close()

    #expect(try store.snapshots().count == 1)
}

@Test func spaceTimelineIncludesSuccessfulCleanupEventsOnly() {
    let now = Date()
    let before = now.addingTimeInterval(-3_600)
    let snapshot = SpaceSnapshot(at: before, diskFreeBytes: 10 * gb, entries: [])
    let success = AuditEvent(
        at: now.addingTimeInterval(-60), action: .moveToTrash,
        path: "/Users/test/Downloads/a.zip", sizeBytes: 2 * gb,
        success: true, previousHash: "genesis"
    )
    let failure = AuditEvent(
        at: now.addingTimeInterval(-30), action: .moveToTrashFailed,
        path: "/Users/test/Downloads/b.zip", sizeBytes: 3 * gb,
        success: false, previousHash: "genesis"
    )
    let events = SpaceTimelineBuilder.events(
        snapshots: [snapshot],
        audit: [success, failure],
        start: before,
        end: now
    )

    #expect(events.count == 2)
    #expect(events.contains { $0.kind == .snapshot })
    #expect(events.contains { $0.kind == .cleanup && $0.detail == "a.zip" })
    #expect(!events.contains { $0.detail == "b.zip" })
}

@Test func spaceDeltaExplainsZeroSystemDeltaInsteadOfCallingItRelease() {
    let baseline = snapshot(hoursAgo: 2, freeGB: 100,
                            entries: [("/Users/test/Desktop", 10, false)])
    let current = snapshot(hoursAgo: 0, freeGB: 100,
                           entries: [("/Users/test/Desktop", 11, false)])
    let query = SpaceDeltaQuery(rawText: "空间变化", label: "最近两小时",
                                start: baseline.at, end: current.at)
    let report = SpaceDeltaDiagnostic.report(snapshots: [baseline, current], query: query)

    #expect(report.diskFreeDelta == 0)
    #expect(report.attributedBytes == 1 * gb)
    #expect(report.unexplainedBytes == -1 * gb)
    #expect(report.explanation.contains("口径没有变化"))
    #expect(report.explanation.contains("不能当成净增"))
    #expect(report.caveat.contains("不能当净增或净减"))
}


@Test func spaceDeltaHistoricalWindowDoesNotBorrowFutureSnapshot() {
    let now = Date()
    let calendar = Calendar(identifier: .gregorian)
    let startOfToday = calendar.startOfDay(for: now)
    let snapshotNow = SpaceSnapshot(at: startOfToday.addingTimeInterval(3_600),
                                    diskFreeBytes: 100 * gb,
                                    entries: [SpaceSnapshotEntry(path: "/Users/test/Desktop", bytes: 10 * gb)])
    let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
    let query = SpaceDeltaQuery(rawText: "为什么昨天少了 10G", label: "昨天",
                                start: yesterdayStart, end: startOfToday)
    let report = SpaceDeltaDiagnostic.report(snapshots: [snapshotNow], query: query)

    #expect(!report.dataSufficient)
    #expect(report.reason?.contains("快照") == true)
    #expect(report.baseline == nil)
    #expect(report.current == nil)
}

@Test func spaceSnapshotScheduleDefaultsToSevenDays() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(SpaceSnapshotSchedule.isDue(lastAt: nil, now: now))
    #expect(!SpaceSnapshotSchedule.isDue(lastAt: now.addingTimeInterval(-6 * 86_400), now: now))
    #expect(SpaceSnapshotSchedule.isDue(lastAt: now.addingTimeInterval(-7 * 86_400), now: now))
}

@Test func spaceDeltaNamesDirectoryOverExplanationAsNetIncrease() {
    let baseline = snapshot(hoursAgo: 2, freeGB: 100,
                            entries: [("/Users/test/Desktop", 10, false)])
    let current = snapshot(hoursAgo: 0, freeGB: 97,
                           entries: [("/Users/test/Desktop", 14, false)])
    let query = SpaceDeltaQuery(rawText: "空间变化", label: "最近两小时",
                                start: baseline.at, end: current.at)
    let report = SpaceDeltaDiagnostic.report(snapshots: [baseline, current], query: query)

    #expect(report.usedDelta == 3 * gb)
    #expect(report.attributedBytes == 4 * gb)
    #expect(report.unexplainedBytes == -1 * gb)
    #expect(report.explanation.contains("目录账面净增比系统实际占用多出"))
}
