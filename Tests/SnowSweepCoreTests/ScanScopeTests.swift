import Foundation
import Testing
@testable import SnowSweepCore

@Test func scanScopeDefaultsToUserDirectory() {
    #expect(ScanScope.default == .userOnly)
    #expect(ScanScope.userOnly.rootPath(home: "/Users/tester") == "/Users/tester")
    #expect(ScanScope.wholeDisk.rootPath(home: "/Users/tester") == "/")
    #expect(ScanScope.allCases.count == 2)
}

@Test func scanScopeHasChineseLabelsAndNeverPromisesDeletionRights() {
    for scope in ScanScope.allCases {
        #expect(scope.chineseName.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF })
        #expect(scope.explain.contains("受保护") || scope == .userOnly)
    }
}

@Test func fdaStatusIsNotCheckedBeforeSnapshot() {
    #expect(FDAScopeInspector.status(from: nil) == .notChecked)
}

@Test func fdaStatusDistinguishesAppGrantFromReadableDatabase() {
    let foreign = PermissionGrant(
        appName: "终端", rawClient: "com.apple.Terminal",
        permissionName: "完全磁盘访问", rawService: "kTCCServiceSystemPolicyAllFiles",
        explain: "", whyNeeded: "", suggestion: "", risk: .protected,
        settingsPath: "", granted: true, database: "用户级授权"
    )
    let own = PermissionGrant(
        appName: "SnowSweep 雪扫", rawClient: "cn.snowsweep.app",
        permissionName: "完全磁盘访问", rawService: "kTCCServiceSystemPolicyAllFiles",
        explain: "", whyNeeded: "", suggestion: "", risk: .protected,
        settingsPath: "", granted: true, database: "用户级授权"
    )
    let onlyForeign = PermissionSnapshot(
        grants: [foreign], gaps: [], sourceLabel: "测试"
    )
    let withOwn = PermissionSnapshot(
        grants: [foreign, own], gaps: [], sourceLabel: "测试"
    )
    #expect(FDAScopeInspector.status(from: onlyForeign) == .databaseReadableWithoutAppGrant)
    #expect(FDAScopeInspector.status(from: withOwn) == .grantedToApp)
}

@Test func fdaStatusIsBlockedWhenSnapshotHasBlockingGap() {
    let snapshot = PermissionSnapshot(
        grants: [],
        gaps: [InspectionGap(kind: .tccDenied, message: "读不到", blocksResult: true)],
        sourceLabel: "测试"
    )
    #expect(FDAScopeInspector.status(from: snapshot) == .blocked)
    #expect(!FDAScopeStatus.blocked.isHealthy)
}
