import Foundation

// MARK: - 规则缺失报告

/// 现有规则里最接近的一条。只给线索，不把“接近”当成“已命中”。
public struct RuleHint: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let pathPattern: String
    public let reason: String
    public let score: Int

    public init(id: String, name: String, pathPattern: String, reason: String, score: Int) {
        self.id = id
        self.name = name
        self.pathPattern = pathPattern
        self.reason = reason
        self.score = score
    }
}

/// 一条完全未知的情况。报告只写“我知道什么、我不知道什么”，
/// 不写文件正文，也不把用户原话改写成删除建议。
public struct UnknownCase: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let query: String
    public let reason: String
    public let closestRules: [RuleHint]
    public let observedPaths: [String]
    public let allowedProbes: [String]
    public let redaction: String
    public let boundary: String

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        query: String,
        reason: String,
        closestRules: [RuleHint] = [],
        observedPaths: [String] = [],
        allowedProbes: [String] = UnknownCaseReportBuilder.defaultProbes,
        redaction: String = "当前用户名已替换为 ~ 或 〈用户〉；不包含文件正文、聊天记录、照片或文稿内容。",
        boundary: String = "这是只读诊断。独立 agent 只能返回规则草稿，不能要求雪执行删除、shell 或永久删除。"
    ) {
        self.id = id
        self.createdAt = createdAt
        self.query = query
        self.reason = reason
        self.closestRules = closestRules
        self.observedPaths = observedPaths
        self.allowedProbes = allowedProbes
        self.redaction = redaction
        self.boundary = boundary
    }

    public var markdown: String {
        var lines: [String] = []
        lines.append("# 雪 · 规则缺失报告")
        lines.append("")
        lines.append("- 报告编号：`\(id)`")
        lines.append("- 生成时间：\(Self.dateText(createdAt))")
        lines.append("- 脱敏：\(redaction)")
        lines.append("")
        lines.append("## 用户原话")
        lines.append("")
        lines.append("> \(query)")
        lines.append("")
        lines.append("## 为什么现有规则没命中")
        lines.append("")
        lines.append(reason)
        lines.append("")
        lines.append("## 现有规则里最接近的")
        lines.append("")
        if closestRules.isEmpty {
            lines.append("没有找到明显接近的内置规则。")
        } else {
            for rule in closestRules {
                lines.append("- **\(rule.name)**（`\(rule.id)`，接近度 \(rule.score)）")
                lines.append("  - 路径：`\(rule.pathPattern)`")
                lines.append("  - 理由：\(rule.reason)")
            }
        }
        lines.append("")
        lines.append("## 已知路径线索")
        lines.append("")
        for path in observedPaths {
            lines.append("- `\(path)`")
        }
        lines.append("")
        lines.append("## 允许的只读探测")
        lines.append("")
        for probe in allowedProbes {
            lines.append("- \(probe)")
        }
        lines.append("")
        lines.append("## 期望返回：规则草稿")
        lines.append("")
        lines.append("请只返回下面这种 JSON。草稿不会直接生效，必须由雪在本地校验、试扫，再由用户确认启用。")
        lines.append("")
        lines.append("```json")
        lines.append(RuleDraftTemplate.json)
        lines.append("```")
        lines.append("")
        lines.append("## 边界")
        lines.append("")
        lines.append(boundary)
        lines.append("")
        lines.append("不要返回 shell、命令、永久删除动作，也不要要求雪绕过保护路径。")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

public enum UnknownCaseReportBuilder {
    public static let defaultProbes = [
        "只读统计目录体积（du 语义），不读取文件内容",
        "只读读取文件数量、扩展名分布与最近修改时间",
        "只读检查是否与内置保护路径重叠",
        "只读检查路径是否位于 ~/ 家目录内",
        "不执行 shell、不监听端口、不修改文件"
    ]

    /// 根据一次未命中的对话生成报告。用户名会先脱敏，再进入 Markdown / JSON。
    public static func build(
        query rawQuery: String,
        reason rawReason: String,
        builtin: RuleBook?,
        now: Date = Date(),
        redactor: ReportRedactor = .default
    ) -> UnknownCase {
        let query = redactor.redact(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        let reason = redactor.redact(rawReason.trimmingCharacters(in: .whitespacesAndNewlines))
        let hints = builtin.map { closestRules(for: rawQuery, in: $0.rules, redactor: redactor) } ?? []
        var paths = observedPaths(in: query)
        if paths.isEmpty {
            paths = ["未提供具体路径；只能从原话和现有规则反推候选目录"]
        }
        return UnknownCase(
            query: query,
            reason: reason.isEmpty ? "没有命中已注册的目标或规则。" : reason,
            closestRules: hints,
            observedPaths: paths
        )
    }

    public static func closestRules(
        for query: String,
        in rules: [Rule],
        redactor: ReportRedactor = .default,
        limit: Int = 3
    ) -> [RuleHint] {
        let grams = bigrams(of: query)
        guard !grams.isEmpty else { return [] }
        let scored = rules.compactMap { rule -> RuleHint? in
            let haystack = normalize("\(rule.id) \(rule.name) \(rule.reason) \(rule.pathPattern)")
            let score = grams.reduce(0) { partial, gram in
                partial + (haystack.contains(gram) ? 1 : 0)
            }
            guard score > 0 else { return nil }
            return RuleHint(
                id: rule.id,
                name: redactor.redact(rule.name),
                pathPattern: redactor.redact(rule.pathPattern),
                reason: redactor.redact(rule.reason),
                score: score
            )
        }
        return Array(scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id
        }.prefix(limit))
    }

    private static func observedPaths(in text: String) -> [String] {
        let pattern = #"(~/[^\s，。；、,;:：]+|/Applications/[^\s，。；、,;:：]+|/Library/[^\s，。；、,;:：]+|/Users/[^\s，。；、,;:：]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var seen = Set<String>()
        return matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let value = String(text[range])
            return seen.insert(value).inserted ? value : nil
        }
    }

    private static func bigrams(of text: String) -> [String] {
        let normalized = normalize(text)
        guard normalized.count >= 2 else { return [] }
        let chars = Array(normalized)
        var seen = Set<String>()
        var result: [String] = []
        for index in 0..<(chars.count - 1) {
            let gram = String(chars[index...index + 1])
            if seen.insert(gram).inserted { result.append(gram) }
        }
        return result
    }

    private static func normalize(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "~/._-"))
        return text.lowercased().unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
    }
}

/// 本机 JSONL。只保存已经脱敏的报告，损坏行跳过，不因一行坏掉丢掉全部历史。
public struct UnknownCaseStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            self.fileURL = support
                .appendingPathComponent(SnowIdentity.supportDirectoryName, isDirectory: true)
                .appendingPathComponent("unknown-cases.jsonl")
        }
    }

    public func append(_ item: UnknownCase) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var line = try encoder.encode(item)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: fileURL, options: .atomic)
        }
    }

    public func cases(limit: Int = 30) throws -> [UnknownCase] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let values = data.split(separator: UInt8(ascii: "\n")).compactMap { line -> UnknownCase? in
            let bytes = Data(line)
            guard !bytes.isEmpty else { return nil }
            return try? decoder.decode(UnknownCase.self, from: bytes)
        }
        return Array(values.sorted { $0.createdAt > $1.createdAt }.prefix(max(1, limit)))
    }

    public func remove(id: String) throws {
        let remaining = try cases(limit: Int.max).filter { $0.id != id }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let text = try remaining.map { item -> String in
            let data = try encoder.encode(item)
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + (remaining.isEmpty ? "" : "\n")
        try Data(text.utf8).write(to: fileURL, options: .atomic)
    }
}

// MARK: - 规则草稿

public struct RuleDraft: Codable, Sendable {
    public let kind: String
    public let schemaVersion: Int
    public let caseID: String?
    public let generatedAt: String?
    public let source: String?
    public let notes: String?
    public let rules: [Rule]

    public init(
        kind: String = RuleDraftTemplate.kind,
        schemaVersion: Int = 1,
        caseID: String? = nil,
        generatedAt: String? = nil,
        source: String? = nil,
        notes: String? = nil,
        rules: [Rule]
    ) {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.caseID = caseID
        self.generatedAt = generatedAt
        self.source = source
        self.notes = notes
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        caseID = try container.decodeIfPresent(String.self, forKey: .caseID)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        rules = try container.decode([Rule].self, forKey: .rules)
    }
}

public enum RuleDraftError: Error, LocalizedError, Sendable {
    case wrongKind(String)
    case unsupportedSchema(Int)
    case emptyRules
    case forbiddenField(String)
    case normalizationFailed

    public var errorDescription: String? {
        switch self {
        case let .wrongKind(kind):
            return "不是雪认识的规则草稿：kind = \(kind)，应为 snow-rule-draft"
        case let .unsupportedSchema(version):
            return "规则草稿 schema 版本不支持：\(version)，当前只接受 1"
        case .emptyRules:
            return "规则草稿里没有 rules"
        case let .forbiddenField(field):
            return "规则草稿包含不允许的字段：\(field)"
        case .normalizationFailed:
            return "规则草稿无法转成用户规则叠加层"
        }
    }
}

public enum RuleDraftTemplate {
    public static let kind = "snow-rule-draft"

    public static let json: String = """
    {
      "kind": "snow-rule-draft",
      "schemaVersion": 1,
      "caseID": "把上面的报告编号填在这里",
      "generatedAt": "2026-11-25T12:00:00Z",
      "source": "independent-agent",
      "notes": "只写你能从报告里证明的事实；不确定就把 risk 设为 review。",
      "rules": [
        {
          "id": "example-cache",
          "risk": "review",
          "name": "示例缓存",
          "pathPattern": "~/Library/Caches/ExampleApp/**",
          "reason": "示例：应用可重建缓存，删除前仍需确认",
          "needConfirm": true,
          "priority": 10,
          "actionType": "trash",
          "source": "user",
          "excludeParents": [],
          "excludePatterns": [],
          "allowOverrideProtection": false,
          "requiresAppQuit": false,
          "sourceKind": "community",
          "confidence": 0.5
        }
      ]
    }
    """
}

public enum RuleDraftImporter {
    /// 把草稿信封校验并转换成 `UserRuleOverlay` JSON。
    /// 只做结构校验；路径、保护重叠和 schema 由 `UserRuleRegistry.importRules` 再跑一遍。
    private static let envelopeFields: Set<String> = [
        "kind", "schemaVersion", "caseID", "generatedAt", "source", "notes", "rules"
    ]

    private static let ruleFields: Set<String> = [
        "id", "risk", "name", "pathPattern", "owner", "rebuildCost", "reason",
        "needConfirm", "priority", "excludeParents", "excludePatterns",
        "allowOverrideProtection", "source", "actionType", "requiresAppQuit",
        "minAgeDays", "sourceKind", "sourceURL", "confidence", "verifiedAt",
        "bundleID", "allowPaths", "guide"
    ]

    public static func normalizedOverlayData(from data: Data) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuleDraftError.normalizationFailed
        }
        if let key = object.keys.first(where: { !envelopeFields.contains($0) }) {
            throw RuleDraftError.forbiddenField(key)
        }
        if let rules = object["rules"] as? [[String: Any]] {
            for rule in rules {
                if let key = rule.keys.first(where: { !ruleFields.contains($0) }) {
                    throw RuleDraftError.forbiddenField(key)
                }
            }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let draft: RuleDraft
        do {
            draft = try decoder.decode(RuleDraft.self, from: data)
        } catch {
            throw RuleDraftError.normalizationFailed
        }
        guard draft.kind == RuleDraftTemplate.kind else {
            throw RuleDraftError.wrongKind(draft.kind)
        }
        guard draft.schemaVersion == 1 else {
            throw RuleDraftError.unsupportedSchema(draft.schemaVersion)
        }
        guard !draft.rules.isEmpty else { throw RuleDraftError.emptyRules }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let ruleData = try? encoder.encode(draft.rules),
              var ruleObjects = try? JSONSerialization.jsonObject(with: ruleData) as? [[String: Any]] else {
            throw RuleDraftError.normalizationFailed
        }
        for index in ruleObjects.indices {
            ruleObjects[index]["source"] = "user"
            ruleObjects[index]["allowOverrideProtection"] = false
        }
        let overlay: [String: Any] = [
            "schemaVersion": 1,
            "protectedPaths": [],
            "rules": ruleObjects
        ]
        guard let normalized = try? JSONSerialization.data(withJSONObject: overlay, options: [.sortedKeys]) else {
            throw RuleDraftError.normalizationFailed
        }
        return normalized
    }

    public static func templateData() -> Data {
        Data(RuleDraftTemplate.json.utf8)
    }
}
