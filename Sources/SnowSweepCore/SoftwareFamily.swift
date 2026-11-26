import Foundation

/// 软件族谱中的一个家族，例如 Adobe、Red Giant、Maxon。
/// 只描述“谁和谁可能是一家”，不包含任何删除动作。
public struct SoftwareFamily: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let aliases: [String]
    public let teamIDs: [String]
    public let bundlePrefixes: [String]
    public let hostBundleIDs: [String]
    public let hostBundlePrefixes: [String]
    public let receiptPrefixes: [String]
    public let pluginRoots: [String]
    public let protectedTokens: [String]
    public let notes: String

    public init(
        id: String,
        name: String,
        aliases: [String] = [],
        teamIDs: [String] = [],
        bundlePrefixes: [String] = [],
        hostBundleIDs: [String] = [],
        hostBundlePrefixes: [String] = [],
        receiptPrefixes: [String] = [],
        pluginRoots: [String] = [],
        protectedTokens: [String] = [],
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.teamIDs = teamIDs
        self.bundlePrefixes = bundlePrefixes
        self.hostBundleIDs = hostBundleIDs
        self.hostBundlePrefixes = hostBundlePrefixes
        self.receiptPrefixes = receiptPrefixes
        self.pluginRoots = pluginRoots
        self.protectedTokens = protectedTokens
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, aliases, teamIDs, bundlePrefixes
        case hostBundleIDs, hostBundlePrefixes, receiptPrefixes
        case pluginRoots, protectedTokens, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        teamIDs = try c.decodeIfPresent([String].self, forKey: .teamIDs) ?? []
        bundlePrefixes = try c.decodeIfPresent([String].self, forKey: .bundlePrefixes) ?? []
        hostBundleIDs = try c.decodeIfPresent([String].self, forKey: .hostBundleIDs) ?? []
        hostBundlePrefixes = try c.decodeIfPresent([String].self, forKey: .hostBundlePrefixes) ?? []
        receiptPrefixes = try c.decodeIfPresent([String].self, forKey: .receiptPrefixes) ?? []
        pluginRoots = try c.decodeIfPresent([String].self, forKey: .pluginRoots) ?? []
        protectedTokens = try c.decodeIfPresent([String].self, forKey: .protectedTokens) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    /// 展开 `~`，并把相对路径按主目录处理。
    public func expandedPath(_ path: String, home: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            return home.appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return home.appendingPathComponent(trimmed)
    }

    public func expandedPluginRoots(home: URL) -> [URL] {
        pluginRoots.map { expandedPath($0, home: home) }
    }

    public func matchesBundleID(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if hostBundleIDs.contains(bundleID) { return true }
        if bundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
        return hostBundlePrefixes.contains(where: { bundleID.hasPrefix($0) })
    }

    /// 路径是否落在该家族的插件根里；返回命中的根，便于做证据展示。
    public func matchingPluginRoot(for path: String, home: URL) -> URL? {
        let expanded = path.hasPrefix("/") ? path : home.appendingPathComponent(path).path
        for root in expandedPluginRoots(home: home) {
            let rootPath = root.standardizedFileURL.path
            // macOS 默认大小写不敏感；Aescripts / aescripts 要能命中同一根。
            if expanded.compare(rootPath, options: .caseInsensitive) == .orderedSame
                || expanded.lowercased().hasPrefix(rootPath.lowercased() + "/") {
                return root
            }
        }
        return nil
    }

    public func containsProtectedToken(_ path: String) -> Bool {
        let lower = path.lowercased()
        return protectedTokens.contains { lower.contains($0.lowercased()) }
    }
}

public struct SoftwareFamilyFile: Codable, Sendable {
    public let schemaVersion: Int
    public let updatedAt: String
    public let families: [SoftwareFamily]

    public init(schemaVersion: Int, updatedAt: String, families: [SoftwareFamily]) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.families = families
    }
}

public enum SoftwareFamilyError: Error, LocalizedError {
    case notFound
    case duplicateID(String)
    case emptyName(String)
    case emptyRoot(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "找不到软件族谱库 software-families.json"
        case let .duplicateID(id): return "族谱库存在重复家族 ID：\(id)"
        case let .emptyName(id): return "家族 \(id) 的名称为空"
        case let .emptyRoot(id): return "家族 \(id) 存在空插件根"
        }
    }
}

/// 只读族谱库。随 App 打包，离线可用；用户覆盖库后续再加。
public struct SoftwareFamilyStore: Sendable {
    public let schemaVersion: Int
    public let updatedAt: String
    public let families: [SoftwareFamily]

    public init(schemaVersion: Int, updatedAt: String, families: [SoftwareFamily]) throws {
        var seen = Set<String>()
        for family in families {
            guard seen.insert(family.id).inserted else {
                throw SoftwareFamilyError.duplicateID(family.id)
            }
            guard !family.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SoftwareFamilyError.emptyName(family.id)
            }
            guard family.pluginRoots.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                throw SoftwareFamilyError.emptyRoot(family.id)
            }
        }
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.families = families
    }

    public init(jsonURL: URL) throws {
        let data = try Data(contentsOf: jsonURL)
        let file = try JSONDecoder().decode(SoftwareFamilyFile.self, from: data)
        try self.init(schemaVersion: file.schemaVersion,
                      updatedAt: file.updatedAt,
                      families: file.families)
    }

    public static func loadBundled() throws -> SoftwareFamilyStore {
        var candidates: [URL] = []
        if let moduleResource = Bundle.module.url(forResource: "software-families", withExtension: "json") {
            candidates.append(moduleResource)
        }
        if let bundled = Bundle.main.url(forResource: "software-families", withExtension: "json", subdirectory: "Rules") {
            candidates.append(bundled)
        }
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Rules/software-families.json"))
        candidates.append(URL(fileURLWithPath: "Rules/software-families.json"))
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try SoftwareFamilyStore(jsonURL: url)
        }
        throw SoftwareFamilyError.notFound
    }

    public func family(matchingBundleID bundleID: String) -> SoftwareFamily? {
        guard !bundleID.isEmpty else { return nil }
        for family in families where family.hostBundleIDs.contains(bundleID) {
            return family
        }
        var best: (family: SoftwareFamily, prefixLength: Int)?
        for family in families {
            let prefixes = family.bundlePrefixes + family.hostBundlePrefixes
            for prefix in prefixes where bundleID.hasPrefix(prefix) {
                if best == nil || prefix.count > best!.prefixLength {
                    best = (family, prefix.count)
                }
            }
        }
        return best?.family
    }

    /// 路径命中：插件根是强证据，家族别名是弱证据。
    public func family(matchingPath path: String, home: URL) -> (family: SoftwareFamily, evidence: SoftwareEvidence)? {
        let expanded = path.hasPrefix("/") ? path : home.appendingPathComponent(path).path
        for family in families {
            if let root = family.matchingPluginRoot(for: expanded, home: home) {
                return (family, SoftwareEvidence(
                    kind: .pluginRoot,
                    value: root.path,
                    strength: .strong,
                    note: "路径落在 \(family.name) 插件根"
                ))
            }
        }
        let lowerPath = expanded.lowercased()
        for family in families {
            for alias in family.aliases where !alias.isEmpty {
                if lowerPath.contains(alias.lowercased()) {
                    return (family, SoftwareEvidence(
                        kind: .pathAlias,
                        value: alias,
                        strength: .medium,
                        note: "路径包含家族别名 \(alias)"
                    ))
                }
            }
        }
        return nil
    }

    public var totalPluginRoots: Int {
        families.reduce(0) { $0 + $1.pluginRoots.count }
    }
}
