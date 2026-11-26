import Foundation
import Testing
@testable import SnowSweepCore

private func appNode(name: String, bundleID: String, familyID: String?, familyName: String?) -> SoftwareNode {
    SoftwareNode(id: "/Applications/\(name).app", name: name, path: "/Applications/\(name).app",
                 kind: .app, bundleID: bundleID, familyID: familyID, familyName: familyName)
}

private func pluginFinding(name: String, familyID: String, familyName: String,
                           size: Int64? = nil, kind: SoftwareNodeKind = .plugin,
                           protected: Bool = false) -> SoftwareFinding {
    SoftwareFinding(
        node: SoftwareNode(id: "/Library/Plug-ins/\(name)", name: name,
                           path: "/Library/Plug-ins/\(name)", kind: kind,
                           familyID: familyID, familyName: familyName,
                           isProtected: protected, sizeBytes: size),
        familyID: familyID, familyName: familyName,
        installedHosts: [], missingHostBundleIDs: [], sharedByHosts: [],
        verdict: protected ? .protected : .possibleRedundancy,
        reasons: [], evidence: [], isShared: false, isOwnerMissing: true,
        lastUsed: nil, lastModified: nil, sizeBytes: size
    )
}

private func makeReport(nodes: [SoftwareNode], findings: [SoftwareFinding]) -> SoftwareGraphReport {
    SoftwareGraphReport(schemaVersion: 1, generatedAt: Date(), storeUpdatedAt: "test",
                        nodes: nodes, edges: [], findings: findings,
                        stats: SoftwareGraphStats())
}

@Test func uninstallImpactKeepsSharedFamilyPlugins() {
    let photoshop = UninstallAppRef(name: "Photoshop", bundleID: "com.adobe.Photoshop",
                                    path: "/Applications/Photoshop.app")
    let report = makeReport(
        nodes: [
            SoftwareNode(id: "family:adobe", name: "Adobe", path: "family:adobe",
                         kind: .family, familyID: "adobe", familyName: "Adobe"),
            appNode(name: "Photoshop", bundleID: "com.adobe.Photoshop", familyID: "adobe", familyName: "Adobe"),
            appNode(name: "Illustrator", bundleID: "com.adobe.Illustrator", familyID: "adobe", familyName: "Adobe")
        ],
        findings: [pluginFinding(name: "CEP", familyID: "adobe", familyName: "Adobe", size: 12)]
    )
    let impact = UninstallImpactEvaluator.evaluate(report: report, selectedApps: [photoshop])
    #expect(impact.affectedFamilyCount == 1)
    #expect(impact.sharedFamilyCount == 1)
    #expect(impact.orphanFamilyCount == 0)
    #expect(impact.families.first?.remainingHosts.map(\.name) == ["Illustrator"])
    #expect(impact.summaryText.contains("插件继续保留"))
    #expect(impact.summaryText.contains("不会自动清理"))
}

@Test func uninstallImpactMarksOrphanPluginsWhenLastHostLeaves() {
    let app = UninstallAppRef(name: "Cinema 4D", bundleID: "com.maxon.c4d",
                              path: "/Applications/Cinema 4D.app")
    let report = makeReport(
        nodes: [
            SoftwareNode(id: "family:maxon", name: "Maxon", path: "family:maxon",
                         kind: .family, familyID: "maxon", familyName: "Maxon"),
            appNode(name: "Cinema 4D", bundleID: "com.maxon.c4d", familyID: "maxon", familyName: "Maxon")
        ],
        findings: [
            pluginFinding(name: "MxContentService", familyID: "maxon", familyName: "Maxon", size: 334)
        ]
    )
    let impact = UninstallImpactEvaluator.evaluate(report: report, selectedApps: [app])
    #expect(impact.orphanFamilyCount == 1)
    #expect(impact.orphanPluginCount == 1)
    #expect(impact.orphanBytes == 334)
    #expect(impact.families.first?.becomesOrphan == true)
    #expect(impact.summaryText.contains("失去最后一个宿主"))
    #expect(impact.summaryText.contains("1 个插件或组件"))
}

@Test func uninstallImpactExcludesLicensesAndProtectedNodesFromOrphanCount() {
    let app = UninstallAppRef(name: "Resolve", bundleID: "com.blackmagic-design.DaVinciResolve",
                              path: "/Applications/Resolve.app")
    let report = makeReport(
        nodes: [
            SoftwareNode(id: "family:blackmagic", name: "Blackmagic", path: "family:blackmagic",
                         kind: .family, familyID: "blackmagic", familyName: "Blackmagic"),
            appNode(name: "Resolve", bundleID: "com.blackmagic-design.DaVinciResolve",
                    familyID: "blackmagic", familyName: "Blackmagic")
        ],
        findings: [
            pluginFinding(name: "Fusion", familyID: "blackmagic", familyName: "Blackmagic", size: 10),
            pluginFinding(name: "license.dat", familyID: "blackmagic", familyName: "Blackmagic",
                          kind: .license, protected: true),
            pluginFinding(name: "SystemPlugin", familyID: "blackmagic", familyName: "Blackmagic", protected: true)
        ]
    )
    let impact = UninstallImpactEvaluator.evaluate(report: report, selectedApps: [app])
    #expect(impact.orphanPluginCount == 1)
    #expect(impact.orphanBytes == 10)
}

@Test func uninstallImpactReportsAppsOutsideLocalFamilies() {
    let app = UninstallAppRef(name: "未知工具", bundleID: "com.example.unknown",
                              path: "/Applications/未知工具.app")
    let report = makeReport(nodes: [], findings: [])
    let impact = UninstallImpactEvaluator.evaluate(report: report, selectedApps: [app])
    #expect(impact.families.isEmpty)
    #expect(impact.unregisteredApps.count == 1)
    #expect(impact.summaryText.contains("不在本地族谱"))
}

@Test func uninstallImpactMatchesSelectedAppByPathNotBundleID() {
    let selected = UninstallAppRef(name: "测试宿主", bundleID: "com.adobe.Photoshop",
                                   path: "/Applications/测试宿主.app")
    let report = makeReport(
        nodes: [
            SoftwareNode(id: "family:adobe", name: "Adobe", path: "family:adobe",
                         kind: .family, familyID: "adobe", familyName: "Adobe"),
            appNode(name: "测试宿主", bundleID: "com.adobe.Photoshop",
                    familyID: "adobe", familyName: "Adobe"),
            appNode(name: "Adobe Photoshop 2027", bundleID: "com.adobe.Photoshop",
                    familyID: "adobe", familyName: "Adobe")
        ],
        findings: [pluginFinding(name: "CEP", familyID: "adobe", familyName: "Adobe", size: 12)]
    )
    let impact = UninstallImpactEvaluator.evaluate(report: report, selectedApps: [selected])
    #expect(impact.families.first?.selectedHosts.map(\.name) == ["测试宿主"])
    #expect(impact.families.first?.remainingHosts.map(\.name) == ["Adobe Photoshop 2027"])
    #expect(impact.sharedFamilyCount == 1)
    #expect(impact.orphanPluginCount == 0)
}

@Test func uninstallImpactTreatsKnownAppWithoutFamilyAsUnregistered() {
    let app = UninstallAppRef(name: "普通工具", bundleID: "com.example.tool",
                              path: "/Applications/普通工具.app")
    let report = makeReport(
        nodes: [appNode(name: "普通工具", bundleID: "com.example.tool",
                        familyID: nil, familyName: nil)],
        findings: []
    )
    let impact = UninstallImpactEvaluator.evaluate(report: report, selectedApps: [app])
    #expect(impact.families.isEmpty)
    #expect(impact.unregisteredApps.count == 1)
    #expect(impact.summaryText.contains("不在本地族谱"))
}

@Test func uninstallImpactHandlesEmptySelection() {
    let report = makeReport(nodes: [], findings: [])
    let impact = UninstallImpactEvaluator.evaluate(report: report, selectedApps: [])
    #expect(impact.families.isEmpty)
    #expect(impact.unregisteredApps.isEmpty)
    #expect(!impact.hasAnyImpact)
}
