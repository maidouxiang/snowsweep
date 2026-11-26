import Foundation
import Testing
@testable import SnowSweepCore

private func inspectionTempURL(_ name: String) -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SnowSweepInspectTest-\(UUID().uuidString)-\(name)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func plistData(_ object: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
}

private struct FixedPermissionReader: PermissionReading {
    let result: PermissionReadResult
    func readGrants() -> PermissionReadResult { result }
}

private struct FixedStartupReader: StartupReading {
    let result: StartupReadResult
    func readPlists() -> StartupReadResult { result }
}

// MARK: - 权限清单

@Test func permissionCatalogExplainsEveryKnownServiceInChinese() {
    #expect(PermissionCatalog.all.count >= 15)
    for definition in PermissionCatalog.all {
        #expect(!definition.zhName.isEmpty)
        #expect(!definition.explain.isEmpty)
        #expect(!definition.whyNeeded.isEmpty)
        #expect(!definition.suggestion.isEmpty)
        #expect(!definition.settingsPath.isEmpty)
        #expect(definition.risk == .review || definition.risk == .protected)
        #expect(PermissionCatalog.definition(forService: definition.tccService) == definition)
    }
}

@Test func unknownTCCServiceIsNotGuessed() {
    let raw = PermissionRawGrant(
        service: "kTCCServiceNeverSeenBefore",
        client: "com.unknown.app",
        authValue: 2,
        clientType: 0,
        database: "用户级授权"
    )
    let snapshot = PermissionInspector(reader: FixedPermissionReader(
        result: PermissionReadResult(grants: [raw])
    )).snapshot()
    let grant = snapshot.grants.first
    #expect(grant?.risk == .unknown)
    #expect(grant?.permissionName.contains("未知") == true)
    #expect(grant?.rawService == "kTCCServiceNeverSeenBefore")
    #expect(grant?.settingsPath.contains("系统设置") == true)
}

@Test func permissionGrantsAreTranslatedAndDeniedRowsAreHidden() {
    let reader = FixedPermissionReader(result: PermissionReadResult(grants: [
        PermissionRawGrant(service: "kTCCServiceCamera", client: "com.tencent.wechat",
                           authValue: 2, clientType: 0, database: "用户级授权"),
        PermissionRawGrant(service: "kTCCServiceMicrophone", client: "com.tencent.wechat",
                           authValue: 0, clientType: 0, database: "用户级授权")
    ]))
    let snapshot = PermissionInspector(reader: reader).snapshot()
    #expect(snapshot.grants.count == 1)
    #expect(snapshot.grants[0].appName == "微信")
    #expect(snapshot.grants[0].permissionName == "摄像头")
    #expect(snapshot.grants[0].risk == .review)
    #expect(snapshot.grants[0].granted)
    #expect(snapshot.grants[0].rawClient == "com.tencent.wechat")
}

@Test func unreadableTCCProducesGapInsteadOfFakeList() {
    let reader = FixedPermissionReader(result: PermissionReadResult(
        grants: [], gaps: [InspectionGap(kind: .tccDenied, message: "未获得完全磁盘访问权限")]
    ))
    let snapshot = PermissionInspector(reader: reader).snapshot()
    #expect(snapshot.grants.isEmpty)
    #expect(!snapshot.isComplete)
    #expect(snapshot.gaps[0].kind == .tccDenied)
}

@Test func sqliteReaderIsStrictlyReadOnly() {
    let args = TCCDatabaseReader.sqliteArguments(databasePath: "/tmp/tcc.db", sql: TCCDatabaseReader.selectSQL)
    #expect(args.contains("-readonly"))
    #expect(args.last == TCCDatabaseReader.selectSQL)
    #expect(TCCDatabaseReader.selectSQL.hasPrefix("PRAGMA query_only=ON;"))
    let lowered = TCCDatabaseReader.selectSQL.lowercased()
    for forbidden in ["insert", "update", "delete", "drop", "replace"] {
        #expect(!lowered.contains(forbidden))
    }
}

// MARK: - 启动项

@Test func startupInspectorTranslatesScopeAndRisk() throws {
    let root = inspectionTempURL("startup")
    defer { try? FileManager.default.removeItem(at: root) }
    let agents = root.appendingPathComponent("LaunchAgents")
    let daemons = root.appendingPathComponent("LaunchDaemons")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)

    let user = agents.appendingPathComponent("com.adobe.update.plist")
    try plistData([
        "Label": "com.adobe.update",
        "ProgramArguments": ["/Applications/Adobe.app/Contents/update", "--daemon"],
        "RunAtLoad": true
    ]).write(to: user)
    let system = daemons.appendingPathComponent("com.openssh.sshd.plist")
    try plistData([
        "Label": "com.openssh.sshd",
        "Program": "/usr/sbin/sshd",
        "KeepAlive": true
    ]).write(to: system)

    let reader = StartupFileSystemReader(directories: [
        .init(path: agents.path, scope: .userAgent, required: true),
        .init(path: daemons.path, scope: .systemDaemon, required: true)
    ], loginItemFileURL: root.appendingPathComponent("no-login-items.btm"))
    let snapshot = StartupInspector(reader: reader).snapshot()

    #expect(snapshot.items.count == 2)
    let userItem = try #require(snapshot.items.first { $0.rawLabel == "com.adobe.update" })
    #expect(userItem.displayName == "Adobe 更新服务")
    #expect(userItem.risk == .review)
    #expect(userItem.launchMethod == "登录时自动启动")
    #expect(userItem.scope == .userAgent)
    #expect(userItem.why.contains("当前用户的登录项"))

    let systemItem = try #require(snapshot.items.first { $0.rawLabel == "com.openssh.sshd" })
    #expect(systemItem.risk == .protected)
    #expect(systemItem.launchMethod == "一直在后台运行")
    #expect(systemItem.suggestion.contains("不建议自行关闭"))
}

@Test func malformedStartupPlistBecomesGapNotCrash() throws {
    let root = inspectionTempURL("malformed")
    defer { try? FileManager.default.removeItem(at: root) }
    let bad = root.appendingPathComponent("broken.plist")
    try Data("这不是 plist".utf8).write(to: bad)

    let reader = FixedStartupReader(result: StartupReadResult(plists: [
        StartupPlist(path: bad.path, scope: .userAgent, data: Data("not a plist".utf8))
    ]))
    let snapshot = StartupInspector(reader: reader).snapshot()
    #expect(snapshot.items.isEmpty)
    #expect(snapshot.gaps.contains { $0.kind == .malformed })
    #expect(snapshot.gaps.allSatisfy { !$0.blocksResult })
}

@Test func startupInspectorNeverModifiesFixtures() throws {
    let root = inspectionTempURL("readonly")
    defer { try? FileManager.default.removeItem(at: root) }
    let plist = root.appendingPathComponent("com.example.helper.plist")
    try plistData([
        "Label": "com.example.helper",
        "Program": "/usr/bin/true",
        "RunAtLoad": true
    ]).write(to: plist)
    let before = try Data(contentsOf: plist)

    let reader = StartupFileSystemReader(directories: [
        .init(path: root.path, scope: .userAgent, required: true)
    ], loginItemFileURL: root.appendingPathComponent("absent.btm"))
    _ = StartupInspector(reader: reader).snapshot()

    let after = try Data(contentsOf: plist)
    #expect(before == after)
    #expect(FileManager.default.fileExists(atPath: plist.path))
}

@Test func loginItemNamesAreReadWithoutSystemSettingsEdit() throws {
    let root = inspectionTempURL("loginitems")
    defer { try? FileManager.default.removeItem(at: root) }
    let btm = root.appendingPathComponent("backgrounditems.btm")
    try plistData([
        "items": [
            ["Name": "微信"],
            ["Name": "输入法助手"]
        ]
    ]).write(to: btm)

    let reader = StartupFileSystemReader(directories: [], loginItemFileURL: btm)
    let snapshot = StartupInspector(reader: reader).snapshot()
    #expect(snapshot.items.count == 2)
    #expect(snapshot.items.allSatisfy { $0.scope == .loginItem })
    #expect(snapshot.items.allSatisfy { $0.risk == .review })
    #expect(snapshot.items.contains { $0.displayName == "微信" })
    #expect(snapshot.items.allSatisfy { $0.launchMethod.contains("系统设置") })
}

// MARK: - M4 真机验收发现的问题回归测试

@Test func realMachineServiceLabelsAreTranslatedToChinese() {
    // 本机实测 26 条启动项标签，中文名不能再是"后台服务（原文见详情）"。
    let labels = [
        "com.adobe.GC.Scheduler-1.0", "com.adobe.AdobeCreativeCloud", "com.adobe.ccxprocess",
        "com.adobe.AdobeDesktopService", "com.adobe.GC.AGM", "com.adobe.acc.installer.v2",
        "com.sogou.SogouServices", "com.sogou.SogouTaskManager", "com.maxon.mxnotify.agent",
        "com.maxon.mxredirect.agent", "com.microsoft.autoupdate.helper", "com.microsoft.update.agent",
        "com.microsoft.office.licensingV2.helper", "com.macpaw.CleanMyMac5.Agent",
        "com.west2online.ClashXPro.ProxyConfigHelper", "yanue.v2rayu.v2ray-core",
        "com.RLMLicenseServer", "com.redgiant.service", "com.fxfactory.FxFactory.helper",
        "Adobe_Genuine_Software_Integrity_Service", "com.aescripts.ZXP-Installer.helper",
        "nl.syncfactory.HedgeHelper.Mac", "com.microsoft.EdgeUpdater.wake.system"
    ]
    for label in labels {
        let name = InspectionChineseNames.serviceName(for: label)
        #expect(name != "后台服务（原文见详情）", "标签 \(label) 未被翻译成中文")
    }
}

@Test func hedgeIsNotMistakenForEdgeBrowser() {
    // 回归：旧逻辑用 contains("edge")，把 HedgeHelper 误认成 Edge 浏览器。
    #expect(InspectionChineseNames.serviceName(for: "nl.syncfactory.HedgeHelper.Mac") == "Hedge 同步工具服务")
    #expect(InspectionChineseNames.appName(for: "nl.syncfactory.HedgeHelper.Mac") == "Hedge 同步工具")
    #expect(InspectionChineseNames.appName(for: "com.microsoft.EdgeUpdater.wake.system") == "Edge 浏览器更新服务")
}

@Test func missingLoginDatabaseProducesExplicitGap() throws {
    // 注入一个不存在的候选路径，登录项读不到必须给出缺口而不是静默空白。
    let root = inspectionTempURL("no-login-db")
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = StartupFileSystemReader(
        directories: [],
        loginItemFileURL: root.appendingPathComponent("absent.btm")
    )
    let result = reader.readPlists()
    #expect(result.plists.isEmpty)
    #expect(result.gaps.contains { $0.kind == .loginItemsNeedsSystemSettings })
}

@Test func loginDatabaseDirectoryIsScannedForBtmFiles() throws {
    // macOS 14+ 候选是目录，应找到里面的 backgrounditems*.btm。
    let root = inspectionTempURL("login-dir")
    defer { try? FileManager.default.removeItem(at: root) }
    let dbDir = root.appendingPathComponent("com.apple.backgroundtaskmanagement")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    let btm = dbDir.appendingPathComponent("backgrounditems-v4.btm")
    try plistData(["items": [["Name": "微信"]]]).write(to: btm)

    let reader = StartupFileSystemReader(directories: [], loginItemFileURL: dbDir)
    let snapshot = StartupInspector(reader: reader).snapshot()
    #expect(snapshot.items.count == 1)
    #expect(snapshot.items.first?.displayName == "微信")
    #expect(snapshot.items.first?.scope == .loginItem)
}
