import Foundation
import Testing
@testable import SnowSweepCore

@Test func identityUsesXueAsSinglePublicName() {
    #expect(SnowIdentity.displayName == "雪")
    #expect(SnowIdentity.bundleIdentifier == "com.selfuse.xue")
    #expect(SnowIdentity.supportDirectoryName == "雪")
    #expect(SnowIdentity.legacyBundleIdentifier == "com.selfuse.snowso.sweep")
    #expect(SnowIdentity.legacySupportDirectoryName == "SnowSweep")
    #expect(SnowIdentity.scannerServiceIdentifier == "com.selfuse.xue.ScannerService")
    #expect(SnowIdentity.modelHostIdentifier == "com.selfuse.xue.ModelHost")
    #expect(SnowIdentity.assistantKeychainService == "com.selfuse.xue.assistant")
}

@Test func dataMigrationCopiesUserDataAndKeepsLegacyDirectory() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("snow-migration-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("SnowSweep", isDirectory: true)
    let destination = root.appendingPathComponent("雪", isDirectory: true)
    try fileManager.createDirectory(at: source, withIntermediateDirectories: true)

    let reportFile = source.appendingPathComponent("unknown-cases.jsonl")
    let reportText = "{\"id\":\"case-1\"}\n"
    try Data(reportText.utf8).write(to: reportFile)
    try fileManager.createDirectory(at: source.appendingPathComponent("models"), withIntermediateDirectories: true)
    try Data("model".utf8).write(to: source.appendingPathComponent("models/model.gguf"))
    try fileManager.createDirectory(
        at: source.appendingPathComponent("Rules/User", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("{\"rules\":[]}".utf8).write(to: source.appendingPathComponent("Rules/User/rules.json"))
    try fileManager.createDirectory(at: source.appendingPathComponent(".build"), withIntermediateDirectories: true)
    try Data("tool".utf8).write(to: source.appendingPathComponent("SoakTest"))
    defer { try? fileManager.removeItem(at: root) }

    let migration = SnowDataMigrator.migrateIfNeeded(
        fileManager: fileManager,
        source: source,
        destination: destination,
        now: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(migration.sourceFound)
    #expect(migration.alreadyMigrated == false)
    #expect(migration.failed.isEmpty)
    #expect(migration.copied.contains("unknown-cases.jsonl"))
    #expect(migration.copied.contains("Rules/User"))
    #expect(!migration.copied.contains("models"))
    #expect(!migration.copied.contains(".build"))
    #expect(!migration.copied.contains("SoakTest"))

    #expect(try String(contentsOf: destination.appendingPathComponent("unknown-cases.jsonl"), encoding: .utf8) == reportText)
    #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("Rules/User/rules.json").path))
    #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("models").path))

    // 迁移从不移动或删除旧目录。
    #expect(fileManager.fileExists(atPath: reportFile.path))
    #expect(try String(contentsOf: reportFile, encoding: .utf8) == reportText)

    let second = SnowDataMigrator.migrateIfNeeded(
        fileManager: fileManager,
        source: source,
        destination: destination,
        now: Date(timeIntervalSince1970: 1_800_000_001)
    )
    #expect(second.alreadyMigrated)
    #expect(second.copied.isEmpty)
}

@Test func defaultsMigrationCopiesOnlySnowKeysAndNeverOverwritesNewValues() {
    let legacyID = "com.selfuse.xue.tests.legacy.\(UUID().uuidString)"
    let newID = "com.selfuse.xue.tests.new.\(UUID().uuidString)"
    guard let legacy = UserDefaults(suiteName: legacyID),
          let current = UserDefaults(suiteName: newID) else {
        Issue.record("无法创建测试 UserDefaults")
        return
    }
    defer {
        legacy.removePersistentDomain(forName: legacyID)
        current.removePersistentDomain(forName: newID)
    }

    legacy.set("snowDay", forKey: "snow.appearance")
    legacy.set("旧值", forKey: "snow.onlyLegacy")
    legacy.set("不应迁移", forKey: "not.snow")
    current.set("snowNight", forKey: "snow.appearance")

    let copied = SnowDefaultsMigrator.migrateIfNeeded(defaults: current, legacyBundleIdentifier: legacyID)

    #expect(copied == 1)
    #expect(current.string(forKey: "snow.appearance") == "snowNight")
    #expect(current.string(forKey: "snow.onlyLegacy") == "旧值")
    #expect(current.object(forKey: "not.snow") == nil)
    #expect(current.bool(forKey: SnowDefaultsMigrator.markerKey))
}
