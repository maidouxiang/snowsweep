import Foundation
import Testing
@testable import SnowSweepCore

@Test func runModeSetsScanConcurrencyFromCores() {
    #expect(RunMode.silent.scanConcurrency(activeProcessorCount: 12) == 2)
    #expect(RunMode.performance.scanConcurrency(activeProcessorCount: 12) == 12)
    let balanced = RunMode.balanced.scanConcurrency(activeProcessorCount: 12)
    #expect(balanced >= 2 && balanced <= 4)
    #expect(RunMode.silent.scanConcurrency(activeProcessorCount: 1) == 1)
    #expect(RunMode.performance.scanConcurrency(activeProcessorCount: 0) == 1)
}

@Test func snapshotPolicyRetainsOnlyCurrentPageHeavyData() {
    #expect(SnapshotRetentionPolicy.retainedGroups(for: "空间分析") == [.space])
    #expect(SnapshotRetentionPolicy.retainedGroups(for: "大文件") == [.storageReview])
    #expect(SnapshotRetentionPolicy.retainedGroups(for: "卸载") == [.apps])
    #expect(SnapshotRetentionPolicy.retainedGroups(for: "历史") == [.audit])
    #expect(SnapshotRetentionPolicy.retainedGroups(for: "内存") == [.device])
    #expect(SnapshotRetentionPolicy.retainedGroups(for: "概览").isEmpty)
}

@Test func snapshotPolicyReleasesEverythingWhenLeavingOverviewExceptPerformance() {
    let released = SnapshotRetentionPolicy.groupsToRelease(for: "概览", runMode: .silent)
    #expect(released == Set(SnapshotGroup.allCases))
    #expect(SnapshotRetentionPolicy.groupsToRelease(for: "空间分析", runMode: .balanced) == [.storageReview, .apps, .audit, .device])
    #expect(SnapshotRetentionPolicy.groupsToRelease(for: "空间分析", runMode: .performance).isEmpty)
}

@Test func snapshotPolicyNeverDropsLightMetricsOnBatteryPage() {
    let released = SnapshotRetentionPolicy.groupsToRelease(for: "电池", runMode: .silent)
    #expect(released.contains(.space))
    #expect(released.contains(.device))
    // 磁盘、内存、电池不在 SnapshotGroup 里，释放列表里没有它们。
    #expect(released.contains(.storageReview))
}
