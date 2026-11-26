import Foundation

/// 页面快照里真正占内存的几组数据。轻量指标（磁盘、内存、电池）不在这里，
/// 切页后永远保留，所以概览与菜单栏不会因为释放而变空。
public enum SnapshotGroup: String, CaseIterable, Sendable, Hashable {
    case space
    case storageReview
    case apps
    case audit
    case device
}

/// V0.8.0：导航切换后只留当前页要用的重快照；性能模式不释放，避免扫描中来回重建。
public enum SnapshotRetentionPolicy {
    public static func retainedGroups(for page: String) -> Set<SnapshotGroup> {
        switch page {
        case "空间分析":
            return [.space]
        case "大文件":
            return [.storageReview]
        case "重复":
            return [.storageReview]
        case "卸载":
            return [.apps]
        case "历史":
            return [.audit]
        case "内存", "蓝牙", "状态":
            return [.device]
        default:
            return []
        }
    }

    public static func groupsToRelease(for page: String, runMode: RunMode) -> Set<SnapshotGroup> {
        guard runMode != .performance else { return [] }
        return Set(SnapshotGroup.allCases).subtracting(retainedGroups(for: page))
    }
}
