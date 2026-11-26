import Foundation
import Testing
@testable import SnowSweepCore

private func projectRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func makeTempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnowSweepFamily-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeApp(home: URL, name: String, bundleID: String) throws -> URL {
    let app = home.appendingPathComponent("Applications/\(name).app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": bundleID,
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": name
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return app
}

private func makePlugin(home: URL, relative: String) throws -> URL {
    let url = home.appendingPathComponent(relative, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func bundledSoftwareFamiliesMatchesRulesDirectoryCopy() throws {
    let rulesCopy = try Data(contentsOf: projectRoot().appendingPathComponent("Rules/software-families.json"))
    let bundled = try #require(Bundle.module.url(forResource: "software-families", withExtension: "json"))
    let bundledCopy = try Data(contentsOf: bundled)
    #expect(rulesCopy == bundledCopy)
}

@Test func softwareFamilyMatchesBundleAndPluginRoot() throws {
    let store = try SoftwareFamilyStore(jsonURL: projectRoot().appendingPathComponent("Rules/software-families.json"))
    let home = URL(fileURLWithPath: "/Users/example")
    #expect(store.family(matchingBundleID: "com.adobe.Photoshop")?.id == "adobe")
    #expect(store.family(matchingBundleID: "com.redgiant.trapcode")?.id == "redgiant")
    let path = home.appendingPathComponent("Library/Application Support/Adobe/CEP/extensions/com.example").path
    let match = store.family(matchingPath: path, home: home)
    #expect(match?.family.id == "adobe")
    #expect(match?.evidence.strength == .strong)
}

@Test func softwareFamilyRootMatchingIsCaseInsensitive() throws {
    let store = try SoftwareFamilyStore(jsonURL: projectRoot().appendingPathComponent("Rules/software-families.json"))
    let home = URL(fileURLWithPath: "/Users/example")
    let path = home.appendingPathComponent("Library/Application Support/Aescripts/settings").path
    let match = store.family(matchingPath: path, home: home)
    #expect(match?.family.id == "aescripts")
    #expect(match?.evidence.strength == .strong)
}

@Test func softwareFamilyRejectsDuplicateIDs() {
    let family = SoftwareFamily(id: "dup", name: "重复", pluginRoots: ["~/Library/Test"])
    #expect(throws: SoftwareFamilyError.self) {
        try SoftwareFamilyStore(schemaVersion: 1, updatedAt: "test", families: [family, family])
    }
}

@Test func graphScannerKeepsPluginWhenHostInstalled() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    _ = try makeApp(home: home, name: "Photoshop", bundleID: "com.adobe.Photoshop")
    _ = try makePlugin(home: home, relative: "Library/Application Support/Adobe/CEP/extensions/com.example.plugin")

    let store = try SoftwareFamilyStore(jsonURL: projectRoot().appendingPathComponent("Rules/software-families.json"))
    let options = SoftwareGraphScanOptions(
        appRoots: [home.appendingPathComponent("Applications")],
        home: home, launchRoots: [],
        maxAppDepth: 2, maxPluginDepth: 1,
        readPackageReceipts: false, readLastUsed: false,
        computeSizes: false
    )
    let report = SoftwareGraphScanner.scan(store: store, options: options)
    let finding = try #require(report.findings.first { $0.node.name == "com.example.plugin" })
    #expect(finding.verdict == .keep)
    #expect(finding.isOwnerMissing == false)
    #expect(finding.isShared == false)
}

@Test func graphScannerMarksMissingHostAsPossibleButNotSuggested() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    _ = try makePlugin(home: home, relative: "Library/Application Support/Red Giant/Trapcode")

    let store = try SoftwareFamilyStore(jsonURL: projectRoot().appendingPathComponent("Rules/software-families.json"))
    let options = SoftwareGraphScanOptions(
        appRoots: [home.appendingPathComponent("Applications")],
        home: home, launchRoots: [],
        maxAppDepth: 2, maxPluginDepth: 1,
        readPackageReceipts: false, readLastUsed: false,
        computeSizes: false
    )
    let report = SoftwareGraphScanner.scan(store: store, options: options)
    let finding = try #require(report.findings.first { $0.node.name == "Trapcode" })
    #expect(finding.verdict == .possibleRedundancy)
    #expect(finding.isOwnerMissing)
    #expect(!finding.reasons.contains { $0.contains("建议清理") })
}

@Test func graphScannerMarksSharedPluginAsKeep() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    _ = try makeApp(home: home, name: "After Effects", bundleID: "com.adobe.AfterEffects")
    _ = try makeApp(home: home, name: "Premiere Pro", bundleID: "com.adobe.PremierePro")
    _ = try makePlugin(home: home, relative: "Library/Application Support/Adobe/CEP/extensions/com.shared.plugin")

    let store = try SoftwareFamilyStore(jsonURL: projectRoot().appendingPathComponent("Rules/software-families.json"))
    let options = SoftwareGraphScanOptions(
        appRoots: [home.appendingPathComponent("Applications")],
        home: home, launchRoots: [],
        maxAppDepth: 2, maxPluginDepth: 1,
        readPackageReceipts: false, readLastUsed: false,
        computeSizes: false
    )
    let report = SoftwareGraphScanner.scan(store: store, options: options)
    let finding = try #require(report.findings.first { $0.node.name == "com.shared.plugin" })
    #expect(finding.verdict == .keep)
    #expect(finding.isShared)
    #expect(finding.installedHosts.count == 2)
}

@Test func graphScannerProtectsLicensePath() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    _ = try makePlugin(home: home, relative: "Library/Application Support/RLM/License")

    let store = try SoftwareFamilyStore(jsonURL: projectRoot().appendingPathComponent("Rules/software-families.json"))
    let options = SoftwareGraphScanOptions(
        appRoots: [home.appendingPathComponent("Applications")],
        home: home, launchRoots: [],
        maxAppDepth: 2, maxPluginDepth: 1,
        readPackageReceipts: false, readLastUsed: false,
        computeSizes: false
    )
    let report = SoftwareGraphScanner.scan(store: store, options: options)
    let finding = try #require(report.findings.first { $0.node.name == "License" })
    #expect(finding.verdict == .protected)
    #expect(finding.node.kind == .license)
}

@Test func sharedHostSummaryDeduplicatesSortsAndExplainsShared() {
    let afterEffects = SoftwareHost(
        bundleID: "com.adobe.AfterEffects",
        name: "After Effects",
        path: "/Applications/Adobe After Effects.app"
    )
    let premiere = SoftwareHost(
        bundleID: "com.adobe.PremierePro",
        name: "Premiere Pro",
        path: "/Applications/Adobe Premiere Pro.app"
    )
    let summary = SharedHostSummary(hosts: [premiere, afterEffects, afterEffects])

    #expect(summary.count == 2)
    #expect(summary.isShared)
    #expect(summary.hosts.map(\.name) == ["After Effects", "Premiere Pro"])
    #expect(summary.headline.contains("同家族 2 个宿主"))
    #expect(summary.headline.contains("After Effects"))
    #expect(summary.conclusion.contains("可能被共用"))
    #expect(summary.conclusion.contains("不要删"))
}

@Test func sharedHostSummaryExplainsSingleAndMissingHost() {
    let single = SharedHostSummary(hosts: [
        SoftwareHost(bundleID: "com.adobe.Photoshop", name: "Photoshop")
    ])
    #expect(single.count == 1)
    #expect(!single.isShared)
    #expect(single.headline == "唯一宿主：Photoshop")
    #expect(single.conclusion.contains("不建议删"))

    let missing = SharedHostSummary(hosts: [])
    #expect(missing.count == 0)
    #expect(missing.headline == "没有已安装宿主")
    #expect(missing.conclusion.contains("可能冗余"))
}

@Test func graphScannerTreatsVersionedLightroomAsSharedAdobeHost() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    _ = try makeApp(home: home, name: "Photoshop", bundleID: "com.adobe.Photoshop")
    _ = try makeApp(home: home, name: "Lightroom Classic", bundleID: "com.adobe.LightroomClassicCC7")
    _ = try makePlugin(home: home, relative: "Library/Application Support/Adobe/CEP/extensions/com.shared.lightroom")

    let store = try SoftwareFamilyStore(jsonURL: projectRoot().appendingPathComponent("Rules/software-families.json"))
    let options = SoftwareGraphScanOptions(
        appRoots: [home.appendingPathComponent("Applications")],
        home: home, launchRoots: [],
        maxAppDepth: 2, maxPluginDepth: 1,
        readPackageReceipts: false, readLastUsed: false,
        computeSizes: false
    )
    let report = SoftwareGraphScanner.scan(store: store, options: options)
    let finding = try #require(report.findings.first { $0.node.name == "com.shared.lightroom" })
    #expect(finding.isShared)
    #expect(finding.verdict == .keep)
    #expect(finding.installedHosts.map(\.name).sorted() == ["Lightroom Classic", "Photoshop"])
}
