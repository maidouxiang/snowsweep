import Foundation

/// 保护清单的对外交换格式。带版本与来源，便于以后扩展；
/// 导入仍兼容旧版的 `[String]` 裸数组，不要求用户手动改文件。
public struct ProtectionBundle: Codable, Sendable, Equatable {
    public var version: Int
    public var app: String
    public var exportedAt: String
    public var paths: [String]

    public init(
        version: Int = 1,
        app: String = SnowIdentity.displayName,
        exportedAt: String = ISO8601DateFormatter().string(from: Date()),
        paths: [String]
    ) {
        self.version = version
        self.app = app
        self.exportedAt = exportedAt
        self.paths = paths
    }
}

public enum ProtectionTransferError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version): return "保护清单版本 \(version) 暂不支持"
        case let .malformed(reason): return "保护清单格式不正确：\(reason)"
        }
    }
}

public enum ProtectionTransfer {
    public static func encode(paths: [String], at date: Date = Date()) throws -> Data {
        let formatter = ISO8601DateFormatter()
        let bundle = ProtectionBundle(exportedAt: formatter.string(from: date), paths: paths)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(bundle)
    }

    /// 支持当前 bundle 与旧版裸数组；空文件、非法类型都明确报错，不静默清空清单。
    public static func decode(_ data: Data) throws -> [String] {
        let decoder = JSONDecoder()
        if let bundle = try? decoder.decode(ProtectionBundle.self, from: data) {
            guard bundle.version <= 1 else {
                throw ProtectionTransferError.unsupportedVersion(bundle.version)
            }
            return normalized(bundle.paths)
        }
        if let paths = try? decoder.decode([String].self, from: data) {
            return normalized(paths)
        }
        throw ProtectionTransferError.malformed("既不是保护清单对象，也不是字符串数组")
    }

    private static func normalized(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public enum ProtectionOverlapKind: String, Sendable, Equatable {
    /// 与内置模式完全相同。
    case duplicate
    /// 用户路径已经被某条内置保护完整覆盖，加进来不会增加保护范围。
    case coveredByBuiltIn
    /// 用户路径比内置保护更宽，会额外保护内置清单之外的东西。
    case broaderThanBuiltIn
}

public struct ProtectionOverlap: Sendable, Equatable, Identifiable {
    public let path: String
    public let kind: ProtectionOverlapKind
    public let builtInPatterns: [String]
    public let message: String

    public var id: String { path }

    public init(path: String, kind: ProtectionOverlapKind, builtInPatterns: [String], message: String) {
        self.path = path
        self.kind = kind
        self.builtInPatterns = builtInPatterns
        self.message = message
    }
}

/// 保护路径与内置清单的重叠检查。
///
/// 这里只做“显然可解释”的路径前缀比较，不尝试把两套正则做语义求交：
/// 误报会让用户不敢加保护，过度承诺又会掩盖真实重叠。比较前统一展开 `~`、
/// 去掉结尾的 `/**`、`/*`、`/`，再按路径层级判断。
public enum ProtectionOverlapDetector {
    public static func inspect(
        paths: [String],
        builtInPatterns: [String],
        home: String = NSHomeDirectory()
    ) -> [ProtectionOverlap] {
        let builtIns = builtInPatterns.compactMap { literalPath($0, home: home) }
        return paths.compactMap { raw in
            guard let user = literalPath(raw, home: home) else { return nil }
            let exact = builtIns.filter { $0.normalized == user.normalized }
            if !exact.isEmpty {
                return ProtectionOverlap(
                    path: raw,
                    kind: .duplicate,
                    builtInPatterns: exact.map(\.original),
                    message: "与内置保护清单完全相同，重复添加不会扩大保护范围。"
                )
            }
            let covering = builtIns.filter { isAncestor($0.normalized, of: user.normalized) }
            if !covering.isEmpty {
                return ProtectionOverlap(
                    path: raw,
                    kind: .coveredByBuiltIn,
                    builtInPatterns: covering.map(\.original),
                    message: "该路径已在内置保护范围内，添加后不会增加新的保护。"
                )
            }
            let broader = builtIns.filter { isAncestor(user.normalized, of: $0.normalized) }
            if !broader.isEmpty {
                return ProtectionOverlap(
                    path: raw,
                    kind: .broaderThanBuiltIn,
                    builtInPatterns: broader.map(\.original),
                    message: "这条路径比内置保护更宽，会连带保护清单之外的内容；确认这是你想要的范围。"
                )
            }
            return nil
        }
    }

    private struct LiteralPath {
        let original: String
        let normalized: String
    }

    private static func literalPath(_ pattern: String, home: String) -> LiteralPath? {
        var value = NSString(string: pattern).expandingTildeInPath
        for suffix in ["/**", "/*", "/"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
            break
        }
        guard !value.isEmpty else { return nil }
        // 只比较本机路径；含正则元字符的模式不强行解释，避免给出错误结论。
        let meta = CharacterSet(charactersIn: "*?[](){}|+^$\\")
        guard value.rangeOfCharacter(from: meta) == nil else { return nil }
        if value == "~" { value = home }
        guard value.hasPrefix("/") else { return nil }
        return LiteralPath(original: pattern, normalized: value.lowercased())
    }

    private static func isAncestor(_ ancestor: String, of child: String) -> Bool {
        child == ancestor || child.hasPrefix(ancestor + "/")
    }
}
