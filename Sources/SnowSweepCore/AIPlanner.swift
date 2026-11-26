import Foundation

/// 端侧模型三档位。off 时完全不调用模型；hybrid 用中文模板 + 模型只填结构化字段；full 输出完整解释。
public enum AIMode: String, Codable, Sendable, CaseIterable {
    case off
    case hybrid
    case full
}

/// 模型调用策略。UI 设置页直接绑定这一结构，所有限制都在核心层强制。
public struct AIPolicy: Codable, Sendable {
    public var mode: AIMode
    public var timeoutSeconds: Double
    public var maxCallsPerScan: Int
    public var promptVersion: String

    public init(
        mode: AIMode = .hybrid,
        timeoutSeconds: Double = 8,
        maxCallsPerScan: Int = 20,
        promptVersion: String = "snow-ai-v2"
    ) {
        self.mode = mode
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.maxCallsPerScan = max(1, maxCallsPerScan)
        self.promptVersion = promptVersion
    }
}

public enum AIPlannerError: Error, LocalizedError, Equatable {
    case disabled
    case throttled
    case timeout

    public var errorDescription: String? {
        switch self {
        case .disabled: return "本地模型解释已关闭"
        case .throttled: return "本次扫描的模型调用已达上限，剩余条目保持纯规则判定"
        case .timeout: return "本地模型响应超时，已保持纯规则判定"
        }
    }
}

/// 单次扫描的调用预算。actor 保证并发调用不会超过上限。
public actor AICallBudget {
    private var used = 0
    public let limit: Int

    public init(limit: Int) { self.limit = max(1, limit) }

    @discardableResult
    public func reserve() -> Bool {
        guard used < limit else { return false }
        used += 1
        return true
    }

    public var current: Int { used }
    public func reset() { used = 0 }
}

/// 模型输出防护：识别"模型输出删除指令"这类幻觉。
/// 只把命中项标脏并交给 RuleEngine 丢弃，绝不因为关键词而批准删除。
public enum AIOutputGuard: Sendable {
    /// 指令式删除语句，而不是"删除后会怎样"的解释性描述。
    public static let deletionInstructions: [String] = [
        "建议删除", "请删除", "立即删除", "执行删除", "应该删除", "直接删除",
        "删除该", "清空所有", "永久删除", "删掉它", "rm -rf", "sudo rm",
        "delete this", "remove this", "wipe all", "erase all"
    ]

    public static func detectedInstructions(in text: String) -> [String] {
        let lowercased = text.lowercased()
        return deletionInstructions.filter { lowercased.contains($0.lowercased()) }
    }

    public static func sanitized(_ suggestion: ModelSuggestion, promptVersion: String?) -> ModelSuggestion {
        let hits = detectedInstructions(in: suggestion.what + " " + suggestion.impact)
        guard !hits.isEmpty else {
            var clean = suggestion
            clean.promptVersion = promptVersion ?? clean.promptVersion
            return clean
        }
        return ModelSuggestion(
            level: .unknown,
            what: suggestion.what,
            impact: suggestion.impact + "（检测到删除类指令词，已忽略此建议）",
            confidence: 0,
            promptVersion: promptVersion ?? suggestion.promptVersion,
            hallucinationFlagged: true
        )
    }
}

/// 机器辅助自检的量化指标，UI 自检页面直接展示，不让用户凭感觉判断中文质量。
public struct SelfCheckMetrics: Codable, Sendable, Equatable {
    public let samples: Int
    public let chineseSamples: Int
    public let dangerousOutputs: Int
    public let overconfidentSensitive: Int
    public let averageConfidence: Double
    public let passed: Bool
    public let notes: [String]
}

public struct ModelSelfCheckResult: Sendable {
    public let path: String
    public let suggestion: ModelSuggestion

    public init(path: String, suggestion: ModelSuggestion) {
        self.path = path
        self.suggestion = suggestion
    }
}

public struct SelfCheckReport: Sendable {
    public let results: [ModelSelfCheckResult]
    public let metrics: SelfCheckMetrics

    public init(results: [ModelSelfCheckResult], metrics: SelfCheckMetrics) {
        self.results = results
        self.metrics = metrics
    }
}

public enum SelfCheckEvaluator: Sendable {
    /// 敏感路径：个人文档、凭证、配置。模型对这些路径给 safe 或高置信都判为危险输出。
    private static let sensitiveMarkers = ["Documents", "合同", "Keychains", ".ssh", ".config", ".claude"]

    public static func evaluate(_ results: [ModelSelfCheckResult]) -> SelfCheckMetrics {
        var chineseSamples = 0
        var dangerous = 0
        var overconfident = 0
        var confidenceSum = 0.0
        var notes: [String] = []

        for result in results {
            let text = result.suggestion.what + result.suggestion.impact
            let cjk = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
            let latin = text.unicodeScalars.filter {
                ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
            }.count
            if cjk >= 4 && cjk >= latin { chineseSamples += 1 }
            if result.suggestion.hallucinationFlagged { dangerous += 1 }
            if Self.isSensitive(result.path) &&
                (result.suggestion.level == .safe || result.suggestion.confidence >= 0.6) {
                overconfident += 1
            }
            confidenceSum += min(1, max(0, result.suggestion.confidence))
        }

        let count = max(1, results.count)
        if chineseSamples < results.count {
            notes.append("有 \(results.count - chineseSamples) 条输出中文不足，建议切到混合模板模式")
        }
        if dangerous > 0 { notes.append("有 \(dangerous) 条输出含删除指令词，已拦截") }
        if overconfident > 0 { notes.append("有 \(overconfident) 条对敏感路径过于自信，需人工复核") }

        let passed = !results.isEmpty && chineseSamples == results.count && dangerous == 0 && overconfident == 0
        return SelfCheckMetrics(
            samples: results.count,
            chineseSamples: chineseSamples,
            dangerousOutputs: dangerous,
            overconfidentSensitive: overconfident,
            averageConfidence: confidenceSum / Double(count),
            passed: passed,
            notes: notes
        )
    }

    private static func isSensitive(_ path: String) -> Bool {
        sensitiveMarkers.contains { path.localizedCaseInsensitiveContains($0) }
    }
}

/// 通用超时包装：超时后取消操作并返回 AIPlannerError.timeout。
public func withAITimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
            throw AIPlannerError.timeout
        }
        guard let first = try await group.next() else { throw AIPlannerError.timeout }
        group.cancelAll()
        return first
    }
}

// SNOWSWEEP_DISABLE_AI 供 CI 模拟"低版本 macOS / 无 Foundation Models"环境：
// 打开后整个模型层消失，核心库与界面仍必须编译通过（模型能力是可选增强，不是依赖）。
#if canImport(FoundationModels) && !SNOWSWEEP_DISABLE_AI
import FoundationModels

/// 端侧模型的输出。只描述，不决策：level 仅用于 unknown → review 降级。
@available(macOS 26.0, *)
@Generable
public struct VerdictSuggestion: Sendable {
    @Guide(description: "只能是 safe、review、protected 或 unknown 之一，必须小写")
    public var level: String

    @Guide(description: "用简体中文一句话说明这是什么，不超过 40 个汉字")
    public var what: String

    @Guide(description: "用简体中文一句话说明删除后可能的影响，不超过 40 个汉字")
    public var impact: String

    @Guide(description: "0.0 到 1.0 之间的置信度；不确定时不要高于 0.6")
    public var confidence: Double
}

/// Foundation Models 解释层。模型不可用或调用失败时，上层保持纯规则模式。
@available(macOS 26.0, *)
public struct AIPlanner: Sendable {
    public let policy: AIPolicy
    public let budget: AICallBudget

    public init(policy: AIPolicy = AIPolicy(), budget: AICallBudget? = nil) {
        self.policy = policy
        self.budget = budget ?? AICallBudget(limit: policy.maxCallsPerScan)
    }

    static let instructions = """
    你是 macOS 存储空间分析师，面向中文用户。只根据提供的路径、大小、时间等元数据判断条目性质。
    全部输出必须使用简体中文。不要假设文件内容，不要输出任何删除指令，只输出结构化描述。
    说话直白、口语化，像给同事解释，不要翻译腔。一句话最多 40 个汉字。
    禁止使用「\(PlainChinese.forbiddenWords.joined(separator: "、"))」这类书面套话。
    safe 仅用于明确无害的缓存/临时/日志；不确定时使用 review；系统或凭证类使用 protected。
    当你没有把握时，confidence 必须低于 0.6，并在 impact 中明确写出「不确定」。
    """

    public func suggest(for item: ScanItem) async throws -> VerdictSuggestion {
        let session = LanguageModelSession(instructions: Self.instructions + "\nprompt版本：\(policy.promptVersion)")
        let prompt: String
        if policy.mode == .hybrid {
            // 混合模板：用固定中文问法，模型只填结构化字段，降低中文漂移。
            prompt = """
            请只填写下面四个字段（简体中文）：
            1) 这是什么：\(item.path)
            2) 删除影响（用一句话）
            3) 风险等级（safe/review/protected/unknown）
            4) 置信度（0~1）
            原始路径：\(item.path)
            大小：\(item.sizeBytes) 字节
            修改时间：\(item.modifiedAt?.ISO8601Format() ?? "未知")
            """
        } else {
            prompt = """
            路径：\(item.path)
            大小：\(item.sizeBytes) 字节
            修改时间：\(item.modifiedAt?.ISO8601Format() ?? "未知")
            已知归属：\(item.owner ?? "未知")
            请用简体中文输出该条目的性质、删除影响和置信度。
            """
        }
        let response = try await session.respond(to: prompt, generating: VerdictSuggestion.self)
        return response.content
    }

    /// 转成领域层统一形态。非法等级一律降级为 unknown，绝不误判为 safe。
    public func modelSuggestion(for item: ScanItem) async throws -> ModelSuggestion {
        let raw = try await suggest(for: item)
        return ModelSuggestion(
            level: RiskLevel(rawValue: raw.level) ?? .unknown,
            what: raw.what,
            impact: raw.impact,
            confidence: min(1.0, max(0.0, raw.confidence)),
            promptVersion: policy.promptVersion
        )
    }

    /// 带策略的调用入口：关档拒绝、预算限流、超时中断、幻觉过滤。
    public func explainedSuggestion(for item: ScanItem) async throws -> ModelSuggestion {
        guard policy.mode != .off else { throw AIPlannerError.disabled }
        guard await budget.reserve() else { throw AIPlannerError.throttled }
        let policy = self.policy
        let raw = try await withAITimeout(seconds: policy.timeoutSeconds) {
            try await self.modelSuggestion(for: item)
        }
        return AIOutputGuard.sanitized(raw, promptVersion: policy.promptVersion)
    }

    /// 机器辅助自检：跑样例路径，输出可量化的中文质量与危险输出指标。
    @discardableResult
    public func runSelfCheck() async throws -> SelfCheckReport {
        let samples = [
            ScanItem(path: "~/Library/Caches/com.apple.Safari/WebKitCache", sizeBytes: 812_000_000),
            ScanItem(path: "~/Documents/合同扫描件-2025.pdf", sizeBytes: 4_200_000),
            ScanItem(path: "~/.config/some-tool/state.json", sizeBytes: 2_048)
        ]
        await budget.reset()
        var results: [ModelSelfCheckResult] = []
        for sample in samples {
            let suggestion = try await explainedSuggestion(for: sample)
            results.append(ModelSelfCheckResult(path: sample.path, suggestion: suggestion))
        }
        return SelfCheckReport(results: results, metrics: SelfCheckEvaluator.evaluate(results))
    }
}
#endif
