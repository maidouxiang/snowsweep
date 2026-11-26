import Foundation

/// 规则动作。guide 只给处理入口，不进清理候选；protect 与 protected 风险等级等价。
public enum RuleAction: String, Codable, Sendable, CaseIterable {
    case trash
    case guide
    case protect
}

/// 单条清理规则，来自 Rules/rules.json。
public struct Rule: Codable, Hashable, Sendable {
    public let id: String
    public let risk: RiskLevel
    public let name: String
    public let pathPattern: String
    public let owner: String?
    public let rebuildCost: RebuildCost
    public let reason: String
    public let needConfirm: Bool
    /// 数值越大越优先。具体规则应显式设高优先级，通配规则设低优先级。
    public let priority: Int
    /// 命中路径若位于这些父目录下，规则不生效（防御 dist/__pycache__ 误伤系统目录）。
    public let excludeParents: [String]
    /// 命中路径若匹配这些 glob，规则不生效。比父目录排除更精确。
    public let excludePatterns: [String]
    /// 仅显式为 true 的规则可穿透保护清单，例如 /Library/Caches、/private/var/log。
    public let allowOverrideProtection: Bool
    /// 规则来源：builtin 为随包内置，user 为用户自定义。用户规则永不允许穿透保护。
    public let source: String
    /// trash 可进入清理候选；guide 只给引导；protect 永不进入候选。
    public let actionType: RuleAction
    /// 清理前是否要求退出所属 App。只降低误删风险，不自动操作 App。
    public let requiresAppQuit: Bool
    /// 只处理至少这么多天未修改的文件；nil 表示不限制。
    public let minAgeDays: Int?
    /// 证据来源类型：official / vendor / community / local-test / builtin。
    public let sourceKind: String?
    public let sourceURL: String?
    /// 0...1。低于 0.8 的来源默认只应给 review。
    public let confidence: Double?
    public let verifiedAt: String?
    public let bundleID: String?
    /// 允许穿透保护清单的精确子路径，当前仅作显式白名单记录。
    public let allowPaths: [String]
    /// 给用户的处理入口，例如“请在 Final Cut Pro 内删除未使用渲染文件”。
    public let guide: String?

    public init(
        id: String,
        risk: RiskLevel,
        name: String,
        pathPattern: String,
        owner: String? = nil,
        rebuildCost: RebuildCost = .none,
        reason: String,
        needConfirm: Bool = false,
        priority: Int = 0,
        excludeParents: [String] = [],
        excludePatterns: [String] = [],
        allowOverrideProtection: Bool = false,
        source: String = "builtin",
        actionType: RuleAction = .trash,
        requiresAppQuit: Bool = false,
        minAgeDays: Int? = nil,
        sourceKind: String? = nil,
        sourceURL: String? = nil,
        confidence: Double? = nil,
        verifiedAt: String? = nil,
        bundleID: String? = nil,
        allowPaths: [String] = [],
        guide: String? = nil
    ) {
        self.id = id
        self.risk = risk
        self.name = name
        self.pathPattern = pathPattern
        self.owner = owner
        self.rebuildCost = rebuildCost
        self.reason = reason
        self.needConfirm = needConfirm
        self.priority = priority
        self.excludeParents = excludeParents
        self.excludePatterns = excludePatterns
        self.allowOverrideProtection = source == "user" ? false : allowOverrideProtection
        self.source = source
        self.actionType = actionType
        self.requiresAppQuit = requiresAppQuit
        self.minAgeDays = minAgeDays
        self.sourceKind = sourceKind
        self.sourceURL = sourceURL
        self.confidence = confidence
        self.verifiedAt = verifiedAt
        self.bundleID = bundleID
        self.allowPaths = allowPaths
        self.guide = guide
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        risk = try c.decode(RiskLevel.self, forKey: .risk)
        name = try c.decode(String.self, forKey: .name)
        pathPattern = try c.decode(String.self, forKey: .pathPattern)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        rebuildCost = try c.decodeIfPresent(RebuildCost.self, forKey: .rebuildCost) ?? .none
        reason = try c.decode(String.self, forKey: .reason)
        needConfirm = try c.decodeIfPresent(Bool.self, forKey: .needConfirm) ?? false
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        excludeParents = try c.decodeIfPresent([String].self, forKey: .excludeParents) ?? []
        excludePatterns = try c.decodeIfPresent([String].self, forKey: .excludePatterns) ?? []
        let decodedSource = try c.decodeIfPresent(String.self, forKey: .source) ?? "builtin"
        source = decodedSource
        allowOverrideProtection = decodedSource == "user"
            ? false
            : (try c.decodeIfPresent(Bool.self, forKey: .allowOverrideProtection) ?? false)
        actionType = try c.decodeIfPresent(RuleAction.self, forKey: .actionType) ?? .trash
        requiresAppQuit = try c.decodeIfPresent(Bool.self, forKey: .requiresAppQuit) ?? false
        minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays)
        sourceKind = try c.decodeIfPresent(String.self, forKey: .sourceKind)
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        verifiedAt = try c.decodeIfPresent(String.self, forKey: .verifiedAt)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        allowPaths = try c.decodeIfPresent([String].self, forKey: .allowPaths) ?? []
        guide = try c.decodeIfPresent(String.self, forKey: .guide)
    }
}

/// 完整规则库。
public struct RuleBook: Codable, Sendable {
    public let version: String
    public let updatedAt: String?
    public let protectedPaths: [String]
    public let rules: [Rule]

    public init(version: String, updatedAt: String?, protectedPaths: [String], rules: [Rule]) {
        self.version = version
        self.updatedAt = updatedAt
        self.protectedPaths = protectedPaths
        self.rules = rules
    }
}

/// 进程占用判定的精度。粗判不能当成 protected，否则会误伤用户自己在项目目录跑 python 的情况。
public enum Occupancy: Sendable, Equatable {
    case unknown       // 尚未检测
    case none          // 已检测，未占用
    case exact         // 精确匹配到运行中的 App 或进程占用该路径
    case approximate   // 只能按父目录粗判，存在不确定性
}

/// 端侧模型输出经适配后的统一形态。模型不直接决定删除，只提供解释与置信度。
public struct ModelSuggestion: Sendable, Hashable {
    public var level: RiskLevel
    public var what: String
    public var impact: String
    public var confidence: Double
    /// 生成这条解释时使用的 prompt 版本，写入 evidence 证据链。
    public var promptVersion: String?
    /// 输出含删除类指令词汇时标记幻觉，绝不据此改变判定。
    public var hallucinationFlagged: Bool

    public init(
        level: RiskLevel,
        what: String,
        impact: String,
        confidence: Double,
        promptVersion: String? = nil,
        hallucinationFlagged: Bool = false
    ) {
        self.level = level
        self.what = what
        self.impact = impact
        self.confidence = confidence
        self.promptVersion = promptVersion
        self.hallucinationFlagged = hallucinationFlagged
    }
}

/// 确定性判定引擎：保护清单 > 精确进程占用 > 规则库 > 粗判降级 > unknown。
public struct RuleEngine: Sendable {
    public let ruleBook: RuleBook

    /// 低于此置信度的模型输出不视为可靠判定，UI 必须标注人工复核。
    public static let modelConfidenceThreshold = 0.6

    private let protectedRegex: [NSRegularExpression]
    private let ruleRegex: [(Rule, NSRegularExpression)]
    private let excludeRegex: [String: [NSRegularExpression]]

    /// - Parameter customProtectedPaths: 用户自定义保护路径，只做加法，不能削弱内置保护。
    public init(ruleBook: RuleBook, customProtectedPaths: [String] = []) throws {
        self.ruleBook = ruleBook
        var allPaths = ruleBook.protectedPaths
        for path in customProtectedPaths where !allPaths.contains(path) { allPaths.append(path) }
        self.protectedRegex = try allPaths.map { try Self.compile($0) }

        // 显式排序，JSON 里的书写顺序不再决定判定结果。
        let sorted = ruleBook.rules.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            let lhsSpecificity = Self.specificity(of: lhs.pathPattern)
            let rhsSpecificity = Self.specificity(of: rhs.pathPattern)
            if lhsSpecificity != rhsSpecificity { return lhsSpecificity > rhsSpecificity }
            return lhs.id < rhs.id
        }
        self.ruleRegex = try sorted.map { ($0, try Self.compile($0.pathPattern)) }
        self.excludeRegex = try sorted.reduce(into: [String: [NSRegularExpression]]()) { result, rule in
            guard !rule.excludePatterns.isEmpty else { return }
            result[rule.id] = try rule.excludePatterns.map { try Self.compile($0) }
        }
    }

    public init(jsonURL: URL, customProtectedPaths: [String] = []) throws {
        let data = try Data(contentsOf: jsonURL)
        // typo（如 "risk": "Safe"）必须在这里失败，不能静默变成 unknown。
        try RuleBookValidator.assertValid(jsonData: data)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        try self.init(
            ruleBook: try decoder.decode(RuleBook.self, from: data),
            customProtectedPaths: customProtectedPaths
        )
    }

    /// 通配符语义与 shell glob 一致：
    /// * 匹配除 / 外的任意字符；** 跨目录层；? 匹配单个非 / 字符。
    /// 其余字符全部转义，避免正则注入。
    private static func compile(_ pattern: String) throws -> NSRegularExpression {
        let expanded = canonicalPattern(NSString(string: pattern).expandingTildeInPath)
        var output = ""
        var index = expanded.startIndex
        while index < expanded.endIndex {
            let character = expanded[index]
            let next = expanded.index(after: index)
            switch character {
            case "*":
                if next < expanded.endIndex, expanded[next] == "*" {
                    output += ".*"
                    index = expanded.index(after: next)
                } else {
                    output += "[^/]*"
                    index = next
                }
            case "?":
                output += "[^/]"
                index = next
            default:
                output += NSRegularExpression.escapedPattern(for: String(character))
                index = next
            }
        }
        return try NSRegularExpression(pattern: "^" + output + "$")
    }

    /// 规则特异性：具体字符权重高于通配符，用于同优先级时的确定性排序。
    private static func specificity(of pattern: String) -> Int {
        var score = 0
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            let next = pattern.index(after: index)
            switch character {
            case "*":
                if next < pattern.endIndex, pattern[next] == "*" {
                    score -= 1
                    index = expandedNext(pattern, from: next)
                } else {
                    score += 1
                    index = next
                }
            case "?":
                index = next
            default:
                score += 2
                index = next
            }
        }
        return score
    }

    private static func expandedNext(_ text: String, from next: String.Index) -> String.Index {
        text.index(after: next)
    }

    private func matches(_ regex: NSRegularExpression, canonicalPath: String) -> Bool {
        let range = NSRange(canonicalPath.startIndex..., in: canonicalPath)
        return regex.firstMatch(in: canonicalPath, range: range) != nil
    }

    /// `/var` 与 `/private/var` 这类 firmlink 会让规则与候选路径字符串不同，
    /// 统一走 realpath，避免真实命中被判成 unknown。
    private static func canonicalPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// 通配符规则只解析第一个通配符之前的真实目录，保留通配段原样。
    private static func canonicalPattern(_ pattern: String) -> String {
        guard let wildcard = pattern.firstIndex(where: { $0 == "*" || $0 == "?" }) else {
            return canonicalPath(pattern)
        }
        let prefix = String(pattern[..<wildcard])
        let directory: String
        let suffix: String
        if prefix.hasSuffix("/") {
            directory = String(prefix.dropLast())
            suffix = String(pattern[wildcard...])
        } else {
            directory = (prefix as NSString).deletingLastPathComponent
            suffix = (prefix as NSString).lastPathComponent + String(pattern[wildcard...])
        }
        return canonicalPath(directory) + "/" + suffix
    }

    /// 保护清单按「路径本身或其任一祖先命中」判定，避免只保护根不保护子树。
    /// 每一层只做一次 realpath，再交给全部保护正则复用，避免逐条正则重复系统调用。
    private func protectedAncestor(of path: String) -> String? {
        let normalized = NSString(string: path).expandingTildeInPath
        var current = normalized
        while true {
            let canonical = Self.canonicalPath(current)
            if protectedRegex.contains(where: { matches($0, canonicalPath: canonical) }) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty || parent == "/" { return nil }
            current = parent
        }
    }

    public func isProtected(_ path: String) -> Bool {
        protectedAncestor(of: path) != nil
    }

    private func isExcluded(_ rule: Rule, path: String) -> Bool {
        let normalized = NSString(string: path).expandingTildeInPath
        if rule.excludeParents.contains(where: { parent in
            normalized == parent || normalized.hasPrefix(parent + "/")
        }) {
            return true
        }
        guard let regexes = excludeRegex[rule.id], !regexes.isEmpty else { return false }
        let canonical = Self.canonicalPath(normalized)
        return regexes.contains { matches($0, canonicalPath: canonical) }
    }

    private func firstMatchingRule(for path: String) -> Rule? {
        let canonical = Self.canonicalPath(NSString(string: path).expandingTildeInPath)
        return ruleRegex.first { rule, regex in
            matches(regex, canonicalPath: canonical) && !isExcluded(rule, path: path)
        }?.0
    }

    /// 生成判定。
    /// - Parameters:
    ///   - occupancy: 进程占用精度。exact 强制 protected；approximate 只把 safe 降为 review。
    ///   - occupiedByProcess: 旧接口兼容；true 等价于 .exact。
    public func verdict(
        for item: ScanItem,
        occupancy: Occupancy = .unknown,
        occupiedByProcess: Bool = false
    ) -> Verdict {
        let effectiveOccupancy: Occupancy = occupiedByProcess ? .exact : occupancy
        let matched = firstMatchingRule(for: item.path)
        let protectedAncestorPath = protectedAncestor(of: item.path)

        // 保护清单优先；仅 allowOverrideProtection 规则可穿透（如系统缓存、系统日志）。
        if let ancestor = protectedAncestorPath, matched?.allowOverrideProtection != true {
            // 保护条目如果自己也有一条 protected 规则，用规则的中文名和人话解释，
            // 让新手报告能写“这是 iPhone 备份 / 照片图库”，而不是一串 UUID。
            if let rule = matched, rule.risk == .protected {
                return Verdict(
                    item: item,
                    risk: .protected,
                    explanation: rule.reason,
                    evidence: ["rule:\(rule.id)", "protected-list", "path:\(ancestor)"],
                    needConfirm: true
                )
            }
            return Verdict(
                item: item,
                risk: .protected,
                explanation: "命中保护清单（\(ancestor)）：该目录属于模型权重、凭证、系统关键数据或外接卷，不允许清理。",
                evidence: ["protected-list", "path:\(ancestor)"],
                needConfirm: true
            )
        }

        // 精确占用高于规则库。
        if effectiveOccupancy == .exact {
            return Verdict(
                item: item,
                risk: .protected,
                explanation: "该路径正被运行中的 App 或进程占用，删除可能导致应用异常。",
                evidence: ["process-occupied-exact"],
                needConfirm: true
            )
        }

        if let rule = matched {
            var risk = rule.risk
            var evidence = ["rule:\(rule.id)", "rebuildCost:\(rule.rebuildCost.rawValue)"]
            var explanation = rule.reason

            // 动作优先于风险等级：guide 只给入口，protect 永不进入清理候选。
            if rule.actionType != .trash {
                risk = .protected
                evidence.append("action:\(rule.actionType.rawValue)")
                if let guide = rule.guide, !guide.isEmpty {
                    explanation += " \(guide)"
                }
            } else if risk == .protected {
                evidence.append("action:protect")
            } else {
                evidence.append("action:trash")
            }

            if rule.requiresAppQuit {
                evidence.append("requires-app-quit")
                explanation += " 清理前请先退出 \(rule.owner ?? "所属 App")。"
                if risk == .safe {
                    risk = .review
                    explanation += " 已降级为需确认，避免 App 正在写文件。"
                }
            }

            if let minAgeDays = rule.minAgeDays, let modifiedAt = item.modifiedAt {
                let ageDays = Date().timeIntervalSince(modifiedAt) / 86_400
                if ageDays < Double(minAgeDays) {
                    evidence.append("min-age:\(minAgeDays)")
                    explanation += " 最近 \(minAgeDays) 天内改过，暂不自动勾选。"
                    if risk == .safe {
                        risk = .review
                    }
                }
            }

            if let sourceKind = rule.sourceKind, !sourceKind.isEmpty {
                evidence.append("source:\(sourceKind)")
            }
            if let confidence = rule.confidence {
                evidence.append("confidence:\(String(format: "%.2f", confidence))")
            }
            if let bundleID = rule.bundleID, !bundleID.isEmpty {
                evidence.append("bundle:\(bundleID)")
            }

            // 粗判占用不判 protected，只把 safe 降为 review，避免误伤。
            if effectiveOccupancy == .approximate && risk == .safe {
                risk = .review
                evidence.append("process-occupied-approximate")
                explanation += " 该路径可能被运行中的进程使用，已降级为需确认。"
            }
            if let ancestor = protectedAncestorPath {
                evidence.append("protection-overridden-by:\(rule.id)")
                _ = ancestor
            }

            return Verdict(
                item: item,
                risk: risk,
                explanation: explanation,
                evidence: evidence,
                needConfirm: rule.needConfirm || risk == .review || risk == .protected,
                // trash 规则里的 guide 是操作前提，不是删除动作本身；
                // 露给证据面板，避免只埋在 reason 里被漏读。protect 不提供处理入口。
                guide: rule.actionType == .protect ? nil : rule.guide
            )
        }

        // 粗判占用但无规则：不假装知道，交给用户复核。
        if effectiveOccupancy == .approximate {
            return Verdict(
                item: item,
                risk: .review,
                explanation: "规则库未覆盖该路径，且可能被运行中的进程使用，请人工复核。",
                evidence: ["no-rule", "process-occupied-approximate"],
                needConfirm: true
            )
        }

        return Verdict(
            item: item,
            risk: .unknown,
            explanation: "规则库未覆盖该路径，等待端侧模型解释后再决定。",
            evidence: ["no-rule"],
            needConfirm: true
        )
    }

    /// 目录候选用“目录 + 一个探针子路径”做规则匹配：
    /// 规则库大量写法是 `root/**`，目录本身不带尾斜杠时不会命中；
    /// 返回的 Verdict 仍绑定真实目录条目，证据与体积不变。
    public func verdictForDirectory(
        _ item: ScanItem,
        occupancy: Occupancy = .unknown,
        occupiedByProcess: Bool = false
    ) -> Verdict {
        let probePath = item.path.hasSuffix("/")
            ? item.path + ".snowsweep-dir-probe"
            : item.path + "/.snowsweep-dir-probe"
        let probe = ScanItem(
            path: probePath,
            sizeBytes: item.sizeBytes,
            modifiedAt: item.modifiedAt,
            owner: item.owner,
            identity: item.identity
        )
        let base = verdict(for: probe, occupancy: occupancy, occupiedByProcess: occupiedByProcess)
        return Verdict(
            item: item,
            risk: base.risk,
            explanation: base.explanation,
            evidence: base.evidence,
            modelAssisted: base.modelAssisted,
            needConfirm: base.needConfirm,
            aiExplanation: base.aiExplanation,
            confidence: base.confidence,
            guide: base.guide
        )
    }

    /// 模型建议只能把 unknown 降为 review，且 reason 保留规则原文，模型输出放进独立字段。
    public func applyingModelSuggestion(_ suggestion: ModelSuggestion, to verdict: Verdict) -> Verdict {
        var evidence = verdict.evidence
        if let promptVersion = suggestion.promptVersion, !promptVersion.isEmpty {
            evidence.append("prompt:\(promptVersion)")
        }

        // 幻觉关键词命中：保留原判定，不采纳模型等级，并把证据链标脏。
        if suggestion.hallucinationFlagged {
            evidence.append("model-dangerous-delete-keyword")
            return Verdict(
                item: verdict.item,
                risk: verdict.risk,
                explanation: verdict.explanation,
                evidence: evidence,
                modelAssisted: true,
                needConfirm: true,
                aiExplanation: "本地模型输出含删除类指令词，已忽略该建议，请人工复核。",
                confidence: 0,
                guide: verdict.guide
            )
        }

        guard verdict.risk == .unknown,
              suggestion.level == .review || suggestion.level == .safe else { return verdict }

        evidence.append("model-suggestion")
        let lowConfidence = suggestion.confidence < Self.modelConfidenceThreshold
        if lowConfidence { evidence.append("model-low-confidence") }

        let parts = [suggestion.what, suggestion.impact].filter { !$0.isEmpty }
        let explanation = parts.isEmpty ? nil : parts.joined(separator: " ")

        return Verdict(
            item: verdict.item,
            risk: .review,
            explanation: verdict.explanation,
            evidence: evidence,
            modelAssisted: true,
            needConfirm: true,
            aiExplanation: explanation,
            confidence: suggestion.confidence,
            guide: verdict.guide
        )
    }

    /// 旧接口兼容：仅传等级，不传解释与置信度。
    public func applyingModelSuggestion(_ level: RiskLevel, to verdict: Verdict) -> Verdict {
        applyingModelSuggestion(
            ModelSuggestion(level: level, what: "", impact: "", confidence: 1.0),
            to: verdict
        )
    }
}
