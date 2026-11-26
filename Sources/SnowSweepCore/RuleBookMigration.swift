import Foundation

/// 用户规则叠加层。版本升级时只替换内置规则库，这一层原样保留。
public struct UserRuleOverlay: Codable, Sendable {
    public var schemaVersion: Int
    public var protectedPaths: [String]
    public var rules: [Rule]

    public init(schemaVersion: Int = 1, protectedPaths: [String] = [], rules: [Rule] = []) {
        self.schemaVersion = schemaVersion
        self.protectedPaths = protectedPaths
        self.rules = rules
    }
}

public enum OverlayIOError: Error, LocalizedError {
    case invalid([ValidationIssue])

    public var errorDescription: String? {
        switch self {
        case let .invalid(issues):
            let first = issues.first(where: { $0.severity == .error }) ?? issues.first
            return "用户规则导入失败：\(first?.message ?? "格式错误")（共 \(issues.count) 项问题）"
        }
    }
}

public enum RuleBookMigrator: Sendable {
    /// 导出用户叠加层，方便备份或在另一台自用 Mac 上恢复。
    public static func exportOverlay(_ overlay: UserRuleOverlay) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return try encoder.encode(overlay)
    }

    /// 导入前必须过校验器：格式错、用户规则标成 builtin、试图穿透保护都拒绝。
    public static func importOverlay(jsonData: Data) throws -> UserRuleOverlay {
        let issues = validateOverlay(jsonData: jsonData)
        if issues.contains(where: { $0.severity == .error }) {
            throw OverlayIOError.invalid(issues)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UserRuleOverlay.self, from: jsonData)
    }

    /// 用内置规则库替换旧版本，再叠加用户规则与保护路径。
    /// - 用户规则按 id 覆盖同 id 内置规则，不同 id 的新规则直接追加。
    /// - 用户规则的 allowOverrideProtection 强制为 false（Rule 初始化器已保证）。
    /// - 内置规则版本变化时，用户规则不丢失。
    public static func merge(builtIn: RuleBook, overlay: UserRuleOverlay?) -> RuleBook {
        guard let overlay else { return builtIn }
        let userIDs = Set(overlay.rules.map(\.id))
        var rules = builtIn.rules.filter { !userIDs.contains($0.id) }
        rules.append(contentsOf: overlay.rules)

        var protectedPaths = builtIn.protectedPaths
        for path in overlay.protectedPaths where !protectedPaths.contains(path) {
            protectedPaths.append(path)
        }
        return RuleBook(
            version: builtIn.version,
            updatedAt: builtIn.updatedAt,
            protectedPaths: protectedPaths,
            rules: rules
        )
    }

    /// 叠加层单独校验：用户规则必须标 source=user，且沿用内置规则的语法约束。
    public static func validateOverlay(jsonData: Data) -> [ValidationIssue] {
        guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return [ValidationIssue(path: "$", message: "用户规则库不是合法 JSON 对象", severity: .error)]
        }
        let allowed: Set<String> = ["schemaVersion", "protectedPaths", "rules"]
        var issues: [ValidationIssue] = []
        for key in object.keys.sorted() where !allowed.contains(key) {
            issues.append(ValidationIssue(path: "$.\(key)", message: "未知字段，可能是拼写错误", severity: .error))
        }
        guard let paths = object["protectedPaths"] as? [String] else {
            issues.append(ValidationIssue(path: "$.protectedPaths", message: "必须是字符串数组", severity: .error))
            return issues
        }
        for (index, path) in paths.enumerated() {
            for problem in RuleBookValidator.validatePatternSyntax(path) {
                issues.append(ValidationIssue(
                    path: "$.protectedPaths[\(index)]", message: problem, severity: .error
                ))
            }
        }
        guard let rules = object["rules"] as? [[String: Any]] else {
            issues.append(ValidationIssue(path: "$.rules", message: "必须是对象数组", severity: .error))
            return issues
        }
        var ids = Set<String>()
        for (index, rule) in rules.enumerated() {
            let base = "$.rules[\(index)]"
            if rule["source"] as? String != "user" {
                issues.append(ValidationIssue(path: base + ".source", message: "用户规则必须标 source=user", severity: .error))
            }
            if let id = rule["id"] as? String {
                if !ids.insert(id).inserted {
                    issues.append(ValidationIssue(path: base + ".id", message: "重复的用户规则 id：\(id)", severity: .error))
                }
            }
            if rule["allowOverrideProtection"] as? Bool == true {
                issues.append(ValidationIssue(
                    path: base + ".allowOverrideProtection",
                    message: "用户规则不允许穿透保护清单",
                    severity: .error
                ))
            }
            // 拼成完整规则库结构，复用内置校验器检查字段、枚举与文案。
            var synthetic: [String: Any] = ["version": "0.0.0", "protectedPaths": paths]
            synthetic["rules"] = [rule]
            if let data = try? JSONSerialization.data(withJSONObject: synthetic) {
                for issue in RuleBookValidator.validate(jsonData: data) {
                    let field = issue.path.split(separator: ".").last.map(String.init) ?? "unknown"
                    issues.append(ValidationIssue(
                        path: base + "." + field,
                        message: issue.message,
                        severity: issue.severity
                    ))
                }
            }
        }
        return issues
    }

    /// 便捷加载：内置规则库 + 用户叠加层，一步得到可直接使用的判定引擎。
    public static func loadEngine(
        builtinURL: URL,
        overlayURL: URL?,
        extraProtectedPaths: [String] = []
    ) throws -> RuleEngine {
        let builtinData = try Data(contentsOf: builtinURL)
        try RuleBookValidator.assertValid(jsonData: builtinData)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let builtin = try decoder.decode(RuleBook.self, from: builtinData)

        var overlay: UserRuleOverlay?
        if let overlayURL, FileManager.default.fileExists(atPath: overlayURL.path) {
            let data = try Data(contentsOf: overlayURL)
            let found = RuleBookMigrator.validateOverlay(jsonData: data)
            if let error = found.first(where: { $0.severity == .error }) { throw error }
            overlay = try decoder.decode(UserRuleOverlay.self, from: data)
        }

        let merged = merge(builtIn: builtin, overlay: overlay)
        return try RuleEngine(ruleBook: merged, customProtectedPaths: extraProtectedPaths)
    }
}
