import Foundation

/// 用户自定义保护路径。与内置保护清单合并后交给 RuleEngine，
/// 用户条目只能是"多加保护"，任何规则都不能因此获得删除权限。
public struct ProtectionListStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            self.fileURL = appSupport
                .appendingPathComponent(SnowIdentity.supportDirectoryName, isDirectory: true)
                .appendingPathComponent("custom-protections.json")
        }
    }

    private struct Storage: Codable {
        var version = 1
        var customProtectedPaths: [String] = []
    }

    public func load() throws -> [String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Storage.self, from: data).customProtectedPaths
    }

    public func save(_ paths: [String]) throws {
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        // 规则库模式语法与内置规则一致，错误路径不能写进保护清单。
        for path in unique {
            let problems = RuleBookValidator.validatePatternSyntax(path)
            guard problems.isEmpty else { throw ProtectionListError.invalidPattern(path, problems.first ?? "") }
        }
        var storage = Storage()
        storage.customProtectedPaths = unique
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(storage)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    public func add(_ path: String) throws -> [String] {
        var paths = try load()
        if !paths.contains(path) { paths.append(path) }
        try save(paths)
        return paths
    }

    @discardableResult
    public func remove(_ path: String) throws -> [String] {
        var paths = try load()
        paths.removeAll { $0 == path }
        try save(paths)
        return paths
    }
}

public enum ProtectionListError: Error, LocalizedError {
    case invalidPattern(String, String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPattern(path, reason):
            return "保护路径 \(path) 不合法：\(reason)"
        }
    }
}
