import Foundation
import CoreFoundation

/// 规则库校验问题。error 会让 RuleEngine 拒绝加载，warning 只提示。
public struct ValidationIssue: Error, LocalizedError, CustomStringConvertible, Hashable, Sendable {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public let path: String
    public let message: String
    public let severity: Severity

    public init(path: String, message: String, severity: Severity) {
        self.path = path
        self.message = message
        self.severity = severity
    }

    public var description: String { "[\(severity.rawValue)] \(path): \(message)" }
    public var errorDescription: String? { description }
}

/// 加载期严格校验：不依赖任何第三方 JSON Schema 库，也不发网络请求。
/// 目的：一个 `risk: Safe` 的 typo 必须让加载失败，而不是静默变成 unknown。
public enum RuleBookValidator: Sendable {
    public static let allowedRootKeys: Set<String> = [
        "version", "updatedAt", "_readme", "protectedPaths", "rules"
    ]

    public static let allowedRuleKeys: Set<String> = [
        "id", "risk", "name", "pathPattern", "owner", "rebuildCost",
        "reason", "needConfirm", "priority", "excludeParents", "excludePatterns",
        "allowOverrideProtection", "source", "actionType", "requiresAppQuit",
        "minAgeDays", "sourceKind", "sourceURL", "confidence", "verifiedAt",
        "bundleID", "allowPaths", "guide"
    ]

    private static let validRisks: Set<String> = ["safe", "review", "protected"]
    private static let validSources: Set<String> = ["builtin", "user"]
    private static let validActions: Set<String> = ["trash", "guide", "protect"]
    private static let validSourceKinds: Set<String> = ["official", "vendor", "community", "local-test", "builtin"]
    private static let validRebuildCosts: Set<String> = ["none", "low", "high", "irreplaceable"]

    /// 返回所有问题；空数组表示通过。
    public static func validate(jsonData: Data) -> [ValidationIssue] {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData),
              let object = root as? [String: Any] else {
            return [ValidationIssue(path: "$", message: "规则库不是合法的 JSON 对象", severity: .error)]
        }

        var issues: [ValidationIssue] = []
        checkUnknownKeys(object, allowed: allowedRootKeys, path: "$", into: &issues)
        checkRequired(object, keys: ["version", "protectedPaths", "rules"], path: "$", into: &issues)

        if let version = object["version"] {
            checkString(version, path: "$.version", into: &issues)
            if let text = version as? String, !Self.isSemanticVersion(text) {
                issues.append(ValidationIssue(path: "$.version", message: "版本必须是 x.y.z 格式", severity: .error))
            }
        }
        if let updatedAt = object["updatedAt"] {
            checkString(updatedAt, path: "$.updatedAt", into: &issues)
        }

        if let protected = object["protectedPaths"] {
            checkStringArray(protected, path: "$.protectedPaths", into: &issues)
            if let paths = protected as? [String] {
                for (index, pattern) in paths.enumerated() {
                    checkPathPattern(pattern, path: "$.protectedPaths[\(index)]", into: &issues)
                }
                if Set(paths).count != paths.count {
                    issues.append(ValidationIssue(path: "$.protectedPaths", message: "保护清单存在重复路径", severity: .error))
                }
                issues.append(contentsOf: overlappingProtectedPaths(paths))
            }
        }

        guard let rules = object["rules"] as? [Any] else {
            if object["rules"] != nil {
                issues.append(ValidationIssue(path: "$.rules", message: "rules 必须是数组", severity: .error))
            }
            return issues
        }

        var seenIDs = Set<String>()
        for (index, rawRule) in rules.enumerated() {
            let base = "$.rules[\(index)]"
            guard let rule = rawRule as? [String: Any] else {
                issues.append(ValidationIssue(path: base, message: "规则必须是对象", severity: .error))
                continue
            }
            checkUnknownKeys(rule, allowed: allowedRuleKeys, path: base, into: &issues)
            checkRequired(
                rule,
                keys: ["id", "risk", "name", "pathPattern", "reason", "needConfirm"],
                path: base,
                into: &issues
            )

            if let id = rule["id"] {
                checkString(id, path: base + ".id", into: &issues)
                if let text = id as? String {
                    if !Self.isKebabID(text) {
                        issues.append(ValidationIssue(path: base + ".id", message: "id 只能用小写字母、数字和连字符", severity: .error))
                    }
                    if !seenIDs.insert(text).inserted {
                        issues.append(ValidationIssue(path: base + ".id", message: "重复的规则 id：\(text)", severity: .error))
                    }
                }
            }

            if let risk = rule["risk"] {
                checkString(risk, path: base + ".risk", into: &issues)
                if let text = risk as? String, !validRisks.contains(text) {
                    issues.append(ValidationIssue(
                        path: base + ".risk",
                        message: "非法风险等级 \"\(text)\"（允许值必须小写：safe/review/protected）",
                        severity: .error
                    ))
                }
            }

            if let source = rule["source"] {
                checkString(source, path: base + ".source", into: &issues)
                if let text = source as? String, !validSources.contains(text) {
                    issues.append(ValidationIssue(
                        path: base + ".source",
                        message: "未知规则来源 \"\(text)\"（只允许 builtin / user）",
                        severity: .error
                    ))
                }
            }

            // 安全-gated 口径：safe 且 needConfirm 自相矛盾，必须修数据而不是靠 UI 补丁。
            if rule["risk"] as? String == "safe",
               let confirmFlag = rule["needConfirm"],
               booleanValue(confirmFlag) == true {
                issues.append(ValidationIssue(
                    path: base,
                    message: "safe 规则不能同时 needConfirm:true；需确认的项应标为 review",
                    severity: .error
                ))
            }

            if let cost = rule["rebuildCost"] {
                checkString(cost, path: base + ".rebuildCost", into: &issues)
                if let text = cost as? String, !validRebuildCosts.contains(text) {
                    issues.append(ValidationIssue(path: base + ".rebuildCost", message: "非法重建成本 \"\(text)\"", severity: .error))
                }
            }

            for key in ["name", "pathPattern", "reason"] {
                if let value = rule[key] { checkString(value, path: base + "." + key, into: &issues) }
            }
            if let pattern = rule["pathPattern"] as? String {
                checkPathPattern(pattern, path: base + ".pathPattern", into: &issues)
            }
            if let owner = rule["owner"], !(owner is NSNull) {
                checkString(owner, path: base + ".owner", into: &issues)
            }
            if let needConfirm = rule["needConfirm"], booleanValue(needConfirm) == nil {
                issues.append(ValidationIssue(path: base + ".needConfirm", message: "必须是布尔值", severity: .error))
            }
            if let priority = rule["priority"], integerValue(priority) == nil {
                issues.append(ValidationIssue(path: base + ".priority", message: "必须是整数", severity: .error))
            }
            if let override = rule["allowOverrideProtection"], booleanValue(override) == nil {
                issues.append(ValidationIssue(path: base + ".allowOverrideProtection", message: "必须是布尔值", severity: .error))
            }
            if let excludes = rule["excludeParents"] {
                checkStringArray(excludes, path: base + ".excludeParents", into: &issues)
            }
            if let excludes = rule["excludePatterns"] {
                checkStringArray(excludes, path: base + ".excludePatterns", into: &issues)
                if let patterns = excludes as? [String] {
                    for (index, pattern) in patterns.enumerated() {
                        checkPathPattern(pattern, path: base + ".excludePatterns[\(index)]", into: &issues)
                    }
                }
            }
            if let allows = rule["allowPaths"] {
                checkStringArray(allows, path: base + ".allowPaths", into: &issues)
                if let patterns = allows as? [String] {
                    for (index, pattern) in patterns.enumerated() {
                        checkPathPattern(pattern, path: base + ".allowPaths[\(index)]", into: &issues)
                    }
                }
            }

            if let action = rule["actionType"] {
                checkString(action, path: base + ".actionType", into: &issues)
                if let text = action as? String {
                    if !validActions.contains(text) {
                        issues.append(ValidationIssue(path: base + ".actionType", message: "未知动作 \"\(text)\"（只允许 trash / guide / protect）", severity: .error))
                    }
                    if text == "guide", (rule["guide"] as? String)?.isEmpty != false {
                        issues.append(ValidationIssue(path: base + ".guide", message: "guide 动作必须提供处理入口文案", severity: .error))
                    }
                    if text == "protect", rule["risk"] as? String != "protected" {
                        issues.append(ValidationIssue(path: base, message: "protect 动作的 risk 必须是 protected", severity: .error))
                    }
                    if text == "trash", rule["risk"] as? String == "protected" {
                        issues.append(ValidationIssue(path: base, message: "protected 规则不能使用 trash 动作", severity: .error))
                    }
                }
            }

            if let quit = rule["requiresAppQuit"], booleanValue(quit) == nil {
                issues.append(ValidationIssue(path: base + ".requiresAppQuit", message: "必须是布尔值", severity: .error))
            }
            if let minAge = rule["minAgeDays"] {
                if let number = integerValue(minAge), number >= 0 {
                    // ok
                } else {
                    issues.append(ValidationIssue(path: base + ".minAgeDays", message: "必须是大于等于 0 的整数", severity: .error))
                }
            }

            if let sourceKind = rule["sourceKind"] {
                checkString(sourceKind, path: base + ".sourceKind", into: &issues)
                if let text = sourceKind as? String, !validSourceKinds.contains(text) {
                    issues.append(ValidationIssue(path: base + ".sourceKind", message: "未知来源类型 \"\(text)\"", severity: .error))
                }
                if let text = sourceKind as? String,
                   (text == "official" || text == "vendor"),
                   (rule["sourceURL"] as? String)?.isEmpty != false {
                    issues.append(ValidationIssue(path: base + ".sourceURL", message: "官方/厂商来源必须提供 sourceURL", severity: .error))
                }
            }
            if let sourceURL = rule["sourceURL"] {
                checkString(sourceURL, path: base + ".sourceURL", into: &issues)
            }
            if let confidence = rule["confidence"] {
                if let number = numericValue(confidence) {
                    if !(0...1).contains(number) {
                        issues.append(ValidationIssue(path: base + ".confidence", message: "置信度必须在 0...1", severity: .error))
                    }
                } else {
                    issues.append(ValidationIssue(path: base + ".confidence", message: "必须是数字", severity: .error))
                }
            }
            if let confidence = rule["confidence"],
               let number = numericValue(confidence),
               rule["risk"] as? String == "safe",
               rule["sourceKind"] as? String == "community" {
                issues.append(ValidationIssue(path: base, message: "社区来源且置信度 \(number) 的规则不能直接标 safe；请改 review 或补本地实测证据", severity: .error))
            }
            if let verifiedAt = rule["verifiedAt"] {
                checkString(verifiedAt, path: base + ".verifiedAt", into: &issues)
                if let text = verifiedAt as? String, !isISODate(text) {
                    issues.append(ValidationIssue(path: base + ".verifiedAt", message: "必须是 YYYY-MM-DD 格式", severity: .error))
                }
            }
            if let bundleID = rule["bundleID"] {
                checkString(bundleID, path: base + ".bundleID", into: &issues)
            }
            if let guide = rule["guide"] {
                checkString(guide, path: base + ".guide", into: &issues)
            }
        }
        return issues
    }

    /// 有 error 时抛出第一个错误；warning 不影响加载。
    public static func assertValid(jsonData: Data) throws {
        let issues = validate(jsonData: jsonData)
        if let first = issues.first(where: { $0.severity == .error }) {
            throw first
        }
    }

    // MARK: - 基础检查

    private static func checkUnknownKeys(_ object: [String: Any], allowed: Set<String>, path: String, into issues: inout [ValidationIssue]) {
        for key in object.keys.sorted() where !allowed.contains(key) {
            issues.append(ValidationIssue(path: "\(path).\(key)", message: "未知字段，可能是拼写错误", severity: .error))
        }
    }

    private static func checkRequired(_ object: [String: Any], keys: [String], path: String, into issues: inout [ValidationIssue]) {
        for key in keys where object[key] == nil {
            issues.append(ValidationIssue(path: "\(path).\(key)", message: "缺少必填字段", severity: .error))
        }
    }

    private static func checkString(_ value: Any, path: String, into issues: inout [ValidationIssue]) {
        guard let text = value as? String, !text.isEmpty else {
            issues.append(ValidationIssue(path: path, message: "必须是非空字符串", severity: .error))
            return
        }
    }

    private static func checkStringArray(_ value: Any, path: String, into issues: inout [ValidationIssue]) {
        guard let array = value as? [Any] else {
            issues.append(ValidationIssue(path: path, message: "必须是字符串数组", severity: .error))
            return
        }
        for (index, item) in array.enumerated() {
            checkString(item, path: "\(path)[\(index)]", into: &issues)
        }
    }

    /// 增强路径模式语法校验，同时供用户保护路径 UI 复用。
    public static func validatePatternSyntax(_ pattern: String) -> [String] {
        var problems: [String] = []
        guard pattern.hasPrefix("/") || pattern.hasPrefix("~/") else {
            return ["路径必须以 / 或 ~/ 开头"]
        }
        if pattern.contains("***") { problems.append("不允许三个以上连续星号") }
        if pattern.contains("//") { problems.append("路径中不应出现连续斜杠") }
        if pattern.contains("\\") { problems.append("不允许使用反斜杠") }
        if pattern.contains("/./") || pattern.contains("/../") || pattern.hasSuffix("/.") || pattern.hasSuffix("/..") {
            problems.append("不允许 . 或 .. 路径跳转")
        }
        // ** 必须独占一个路径段；foo**bar 属于未定义语义，拒绝加载。
        for segment in pattern.split(separator: "/") where segment.contains("**") && segment != "**" {
            problems.append("** 必须独占一个路径段，不能写成 \(segment)")
        }
        // 同一段内出现 two '*' 之外的情况（如 a*b*c）允许，语义是两段通配，保持不变。
        if pattern.hasSuffix("/") && pattern != "/" { problems.append("路径末尾不应带斜杠") }
        return problems
    }

    private static func checkPathPattern(_ pattern: String, path: String, into issues: inout [ValidationIssue]) {
        for problem in validatePatternSyntax(pattern) {
            issues.append(ValidationIssue(
                path: path,
                message: problem,
                severity: problem.contains("连续斜杠") ? .warning : .error
            ))
        }
    }

    /// 保护路径子集重叠提示：例如 /System/** 与 /System/Volumes/**。
    /// 只输出 warning —— 重叠本身安全，只是让维护者知道存在冗余，避免误删时误判覆盖范围。
    public static func overlappingProtectedPaths(_ paths: [String]) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let normalized = paths.map { literalPrefix(of: $0) }.filter { !$0.isEmpty }
        for i in normalized.indices {
            for j in normalized.indices where i != j {
                let a = normalized[i], b = normalized[j]
                guard a.count < b.count, b.hasPrefix(a) else { continue }
                let boundaryIndex = b.index(b.startIndex, offsetBy: a.count)
                guard boundaryIndex == b.endIndex || b[boundaryIndex] == "/" else { continue }
                issues.append(ValidationIssue(
                    path: "$.protectedPaths[\(j)]",
                    message: "保护路径 \(paths[j]) 是 \(paths[i]) 的子集，后者已覆盖前者",
                    severity: .warning
                ))
            }
        }
        return issues
    }

    /// 取通配符之前的可确定字面前缀，用于判断包含关系。
    private static func literalPrefix(of pattern: String) -> String {
        let expanded = NSString(string: pattern).expandingTildeInPath
        var result = ""
        for character in expanded {
            if character == "*" || character == "?" { break }
            result.append(character)
        }
        var trimmed = String(result.drop(while: { $0 == "/" && result.count > 1 }))
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private static func isSemanticVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func isKebabID(_ text: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !text.isEmpty,
              !text.hasPrefix("-"), !text.hasSuffix("-"),
              !text.contains("--") else { return false }
        return text.allSatisfy { allowed.contains($0) }
    }

    private static func booleanValue(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func integerValue(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded(.towardZero) == double else { return nil }
        return number.intValue
    }

    private static func numericValue(_ value: Any) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func isISODate(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        guard let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return false }
        return true
    }
}
