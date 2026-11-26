import Foundation

/// 一次身份迁移的可审计结果。只写文件，不联网。
public struct SnowMigrationReport: Codable, Sendable, Equatable {
    public let source: String
    public let destination: String
    public let sourceFound: Bool
    public let copied: [String]
    public let skippedExisting: [String]
    public let failed: [String]
    public let migratedAt: Date
    public let alreadyMigrated: Bool

    public init(
        source: String,
        destination: String,
        sourceFound: Bool,
        copied: [String],
        skippedExisting: [String],
        failed: [String] = [],
        migratedAt: Date,
        alreadyMigrated: Bool = false
    ) {
        self.source = source
        self.destination = destination
        self.sourceFound = sourceFound
        self.copied = copied
        self.skippedExisting = skippedExisting
        self.failed = failed
        self.migratedAt = migratedAt
        self.alreadyMigrated = alreadyMigrated
    }

    public var summary: String {
        if alreadyMigrated {
            return "已完成过从 SnowSweep 到雪的数据迁移；本次没有重复复制。"
        }
        if !sourceFound {
            return "没有发现旧 SnowSweep 数据目录；按全新安装继续。"
        }
        if !failed.isEmpty {
            return "旧数据迁移有 \(failed.count) 项失败，已保留旧目录并等待下次重试。"
        }
        return "已把 \(copied.count) 项旧数据复制到雪；\(skippedExisting.count) 项因新位置已存在而跳过。旧目录保留不动。"
    }
}

/// 从旧 `Application Support/SnowSweep` 复制用户数据到 `Application Support/雪`。
///
/// 只复制，不移动、不删除旧目录：
/// - 顶级普通文件（报告库、日常记录、审计、保护清单、空间快照等）；
/// - `Rules/User/` 用户规则目录；
/// - 明确不复制 `models`、`.build`、浸泡压测工具与随包规则副本。
public enum SnowDataMigrator: Sendable {
    public static let markerName = "migration-from-snowsweep.json"

    private static let skippedTopLevel: Set<String> = [
        "models", ".build", "SoakTest", "soak-test.sh", "Rules", markerName
    ]

    public static func migrateIfNeeded(
        fileManager: FileManager = .default,
        source: URL? = nil,
        destination: URL? = nil,
        now: Date = Date()
    ) -> SnowMigrationReport {
        let sourceURL = source ?? SnowIdentity.legacySupportDirectory(fileManager: fileManager)
        let destinationURL = destination ?? SnowIdentity.supportDirectory(fileManager: fileManager)
        let markerURL = destinationURL.appendingPathComponent(markerName)

        if let data = try? Data(contentsOf: markerURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let existing = try? decoder.decode(SnowMigrationReport.self, from: data) {
                return SnowMigrationReport(
                    source: existing.source,
                    destination: existing.destination,
                    sourceFound: existing.sourceFound,
                    copied: [],
                    skippedExisting: existing.skippedExisting,
                    migratedAt: existing.migratedAt,
                    alreadyMigrated: true
                )
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return SnowMigrationReport(
                source: sourceURL.path,
                destination: destinationURL.path,
                sourceFound: false,
                copied: [],
                skippedExisting: [],
                failed: [],
                migratedAt: now
            )
        }

        try? fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        var copied: [String] = []
        var skipped: [String] = []
        var failed: [String] = []

        let items = (try? fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        )) ?? []

        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(".") || skippedTopLevel.contains(name) {
                continue
            }
            let target = destinationURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) {
                skipped.append(name)
                continue
            }
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if (try? fileManager.copyItem(at: item, to: target)) != nil {
                    copied.append(name)
                } else {
                    failed.append(name)
                }
            } else {
                if (try? fileManager.copyItem(at: item, to: target)) != nil {
                    copied.append(name)
                } else {
                    failed.append(name)
                }
            }
        }

        let legacyRules = sourceURL
            .appendingPathComponent("Rules", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
        if fileManager.fileExists(atPath: legacyRules.path) {
            let targetRules = destinationURL
                .appendingPathComponent("Rules", isDirectory: true)
                .appendingPathComponent("User", isDirectory: true)
            if fileManager.fileExists(atPath: targetRules.path) {
                skipped.append("Rules/User")
            } else {
                try? fileManager.createDirectory(
                    at: targetRules.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if (try? fileManager.copyItem(at: legacyRules, to: targetRules)) != nil {
                    copied.append("Rules/User")
                } else {
                    failed.append("Rules/User")
                }
            }
        }

        let report = SnowMigrationReport(
            source: sourceURL.path,
            destination: destinationURL.path,
            sourceFound: true,
            copied: copied,
            skippedExisting: skipped,
            failed: failed,
            migratedAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if failed.isEmpty, let data = try? encoder.encode(report) {
            try? data.write(to: markerURL, options: .atomic)
        }
        return report
    }
}

/// 把旧 bundle id 下的 `snow.*` 偏好复制到新域；不覆盖新域已有值。
public enum SnowDefaultsMigrator: Sendable {
    public static let markerKey = "snow.migration.from.snowsweep.v1"

    @discardableResult
    public static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        legacyBundleIdentifier: String = SnowIdentity.legacyBundleIdentifier
    ) -> Int {
        if defaults.bool(forKey: markerKey) { return 0 }
        guard let legacy = UserDefaults(suiteName: legacyBundleIdentifier) else {
            defaults.set(true, forKey: markerKey)
            return 0
        }

        let dictionary = legacy.dictionaryRepresentation()
        var copied = 0
        for (key, value) in dictionary where key.hasPrefix("snow.") {
            if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                copied += 1
            }
        }
        defaults.set(true, forKey: markerKey)
        return copied
    }
}
