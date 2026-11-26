import Foundation

/// 本地观测只吃“已经由规则和日常记录算好的数字”，不吃文件内容。
/// 这份事实快照可以安全地交给本机模型；它不包含文件正文，也不产生删除权。
public struct LocalObservationFacts: Codable, Equatable, Sendable {
    public struct TrendPoint: Codable, Equatable, Sendable {
        public let day: String
        public let freeBytes: Int64

        public init(day: String, freeBytes: Int64) {
            self.day = day
            self.freeBytes = freeBytes
        }
    }

    public struct Cluster: Codable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let count: Int
        public let bytes: Int64

        public init(id: String, label: String, count: Int, bytes: Int64) {
            self.id = id
            self.label = label
            self.count = count
            self.bytes = bytes
        }
    }

    public struct TopItem: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let bytes: Int64
        public let risk: String
        public let ruleID: String?

        public init(id: String, name: String, bytes: Int64, risk: String, ruleID: String?) {
            self.id = id
            self.name = name
            self.bytes = bytes
            self.risk = risk
            self.ruleID = ruleID
        }
    }

    public struct Evidence: Codable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let value: String

        public init(id: String, label: String, value: String) {
            self.id = id
            self.label = label
            self.value = value
        }
    }

    public let capturedAt: Date
    public let diskFreeBytes: Int64?
    public let diskTotalBytes: Int64?
    public let trendDays: Int
    public let trendStartBytes: Int64?
    public let trendEndBytes: Int64?
    public let candidateCount: Int
    public let candidateBytes: Int64
    public let gapCount: Int
    public let scanAgeMinutes: Int?
    public let clusters: [Cluster]
    public let topItems: [TopItem]
    public let evidence: [Evidence]

    public init(
        capturedAt: Date,
        diskFreeBytes: Int64?,
        diskTotalBytes: Int64?,
        trendDays: Int,
        trendStartBytes: Int64?,
        trendEndBytes: Int64?,
        candidateCount: Int,
        candidateBytes: Int64,
        gapCount: Int,
        scanAgeMinutes: Int?,
        clusters: [Cluster],
        topItems: [TopItem],
        evidence: [Evidence]
    ) {
        self.capturedAt = capturedAt
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
        self.trendDays = trendDays
        self.trendStartBytes = trendStartBytes
        self.trendEndBytes = trendEndBytes
        self.candidateCount = candidateCount
        self.candidateBytes = candidateBytes
        self.gapCount = gapCount
        self.scanAgeMinutes = scanAgeMinutes
        self.clusters = clusters
        self.topItems = topItems
        self.evidence = evidence
    }

    public var hasEnoughFacts: Bool {
        !evidence.isEmpty
    }
}

public enum LocalObservationFactsBuilder {
    public static func build(
        report: ScanReport?,
        diskFreeBytes: Int64?,
        diskTotalBytes: Int64?,
        summaries: [DailyBatterySummary],
        now: Date = Date()
    ) -> LocalObservationFacts {
        let sorted = summaries.sorted { $0.day < $1.day }
        let points = sorted.compactMap { summary -> LocalObservationFacts.TrendPoint? in
            guard let free = summary.diskFreeEnd else { return nil }
            let day = summary.day.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
            return LocalObservationFacts.TrendPoint(day: day, freeBytes: free)
        }

        var evidence: [LocalObservationFacts.Evidence] = []
        if let free = diskFreeBytes, let total = diskTotalBytes, total > 0 {
            let percent = Double(free) / Double(total) * 100
            evidence.append(.init(
                id: "disk.free",
                label: "当前磁盘可用",
                value: "\(AssistantBytes.text(free)) / 共 \(AssistantBytes.text(total))（可用 \(String(format: "%.1f", percent))%）"
            ))
        }
        if points.count >= 2, let first = points.first, let last = points.last {
            let delta = last.freeBytes - first.freeBytes
            let deltaText = delta == 0 ? "没有变化" : (delta > 0 ? "增加 \(AssistantBytes.text(delta))" : "减少 \(AssistantBytes.text(-delta))")
            let daySpan = max(1, points.count - 1)
            let perDay = abs(delta) / Int64(daySpan)
            evidence.append(.init(
                id: "disk.trend",
                label: "日常记录里的可用空间",
                value: "\(first.day) \(AssistantBytes.text(first.freeBytes)) → \(last.day) \(AssistantBytes.text(last.freeBytes))，\(daySpan) 天窗口合计\(deltaText)，约每天 \(AssistantBytes.text(perDay))"
            ))
        }

        var candidateCount = 0
        var candidateBytes: Int64 = 0
        var gapCount = 0
        var clusters: [LocalObservationFacts.Cluster] = []
        var topItems: [LocalObservationFacts.TopItem] = []
        var scanAgeMinutes: Int?

        if let report {
            candidateCount = report.verdicts.count
            candidateBytes = report.verdicts.reduce(0) { $0 + max(0, $1.item.sizeBytes) }
            gapCount = report.scanGaps.count
            scanAgeMinutes = max(0, Int(now.timeIntervalSince(report.scannedAt) / 60))

            evidence.append(.init(
                id: "scan.summary",
                label: "最近一次扫描",
                value: "\(candidateCount) 项候选，合计 \(AssistantBytes.text(candidateBytes))；\(gapCount) 个读取缺口；\(scanAgeMinutes ?? 0) 分钟前"
            ))

            let grouped = Dictionary(grouping: report.verdicts) { $0.ruleID ?? "no-rule" }
            clusters = grouped
                .map { ruleID, verdicts in
                    let label = verdicts.first?.explanation ?? "规则库未覆盖"
                    return LocalObservationFacts.Cluster(
                        id: ruleID,
                        label: String(label.prefix(36)),
                        count: verdicts.count,
                        bytes: verdicts.reduce(0) { $0 + max(0, $1.item.sizeBytes) }
                    )
                }
                .sorted {
                    if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                    return $0.count > $1.count
                }
                .prefix(6)
                .enumerated()
                .map { index, cluster in
                    let id = "cluster.\(index)"
                    evidence.append(.init(
                        id: id,
                        label: "规则命中：\(cluster.label)",
                        value: "\(cluster.count) 项，合计 \(AssistantBytes.text(cluster.bytes))；规则 ID \(cluster.id)"
                    ))
                    return LocalObservationFacts.Cluster(
                        id: id,
                        label: cluster.label,
                        count: cluster.count,
                        bytes: cluster.bytes
                    )
                }

            topItems = report.verdicts
                .sorted { $0.item.sizeBytes > $1.item.sizeBytes }
                .prefix(8)
                .enumerated()
                .map { index, verdict in
                    let name = (verdict.item.path as NSString).lastPathComponent
                    let id = "item.\(index)"
                    evidence.append(.init(
                        id: id,
                        label: "扫描条目：\(name)",
                        value: "\(AssistantBytes.text(max(0, verdict.item.sizeBytes)))，风险 \(verdict.risk.rawValue)，规则 \(verdict.ruleID ?? "未命中")"
                    ))
                    return LocalObservationFacts.TopItem(
                        id: id,
                        name: String(name.prefix(48)),
                        bytes: max(0, verdict.item.sizeBytes),
                        risk: verdict.risk.rawValue,
                        ruleID: verdict.ruleID
                    )
                }
        }

        if gapCount > 0 {
            evidence.append(.init(
                id: "scan.gaps",
                label: "扫描缺口",
                value: "\(gapCount) 个位置没有读到；缺口不等于垃圾，只表示这次没看见"
            ))
        }

        return LocalObservationFacts(
            capturedAt: now,
            diskFreeBytes: diskFreeBytes,
            diskTotalBytes: diskTotalBytes,
            trendDays: sorted.count,
            trendStartBytes: points.first?.freeBytes,
            trendEndBytes: points.last?.freeBytes,
            candidateCount: candidateCount,
            candidateBytes: candidateBytes,
            gapCount: gapCount,
            scanAgeMinutes: scanAgeMinutes,
            clusters: clusters,
            topItems: topItems,
            evidence: evidence
        )
    }
}

public struct LocalObservationFinding: Identifiable, Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable {
        case attention
        case note
        case ok
    }

    public let id: String
    public let level: Level
    public let title: String
    public let detail: String
    public let evidence: [String]
    public let confidence: Double

    public init(id: String, level: Level, title: String, detail: String, evidence: [String], confidence: Double) {
        self.id = id
        self.level = level
        self.title = title
        self.detail = detail
        self.evidence = evidence
        self.confidence = confidence
    }

    public var levelText: String {
        switch level {
        case .attention: return "值得看一眼"
        case .note: return "可以知道"
        case .ok: return "正常"
        }
    }
}

public struct LocalObservationReport: Codable, Equatable, Sendable {
    public let headline: String
    public let summary: String
    public let findings: [LocalObservationFinding]
    public let generatedAt: Date
    public let promptVersion: String

    public init(
        headline: String,
        summary: String,
        findings: [LocalObservationFinding],
        generatedAt: Date = Date(),
        promptVersion: String = LocalObservationPrompt.version
    ) {
        self.headline = headline
        self.summary = summary
        self.findings = findings
        self.generatedAt = generatedAt
        self.promptVersion = promptVersion
    }
}

public enum LocalObservationPrompt {
    public static let version = "snow-observe-v2"

    public static let instructions = """
    你是雪的本机观察员，只做只读观察。你看到的是规则和日常记录已经算好的数字，不是文件正文。
    任务：找出值得注意的变化、重复或读取缺口，并用简体中文解释；最多 3 条发现。
    硬规则：
    1. 每条发现必须引用 evidence 列表里的 id，至少一个；只能引用列表里的 id。
    2. 没有足够证据就少说或不说，不要补猜，不要编造文件名、体积或时间。
    3. 不要输出删除、清空、sudo、rm、路径操作或“建议删除”这类指令；你无权决定能不能删。
    4. 规则命中只代表“像缓存”，不代表允许删除；缺口只代表“没看见”，不等于垃圾。
    5. 只返回 JSON，不要 Markdown，不要代码块，不要额外解释。
    6. 只复述 evidence.value 里已有的数字、百分比和“每天/合计”口径；不要自己再算百分比、日均或倍率。证据里没有的数字不要写。
    JSON 字段：headline（一句中文，最多 40 字）、summary（最多 120 字）、findings（数组，最多 3 条）。
    每条 finding：level（attention/note/ok）、title（最多 24 字）、detail（最多 90 字）、evidence（id 数组）、confidence（0~1）。
    """
}

public enum LocalObservationError: LocalizedError, Equatable {
    case noFacts
    case invalidConfiguration
    case networkUnavailable
    case timeout
    case badStatus(Int)
    case emptyResponse
    case invalidResponse
    case unsafeOutput
    case ungrounded

    public var errorDescription: String? {
        switch self {
        case .noFacts:
            return "现在还没有足够的只读事实；先做一次体检或打开日常记录。"
        case .invalidConfiguration:
            return "本地模型地址不完整；检查本地小模型配置。"
        case .networkUnavailable:
            return "连不上本机模型；这次观察没有采用。"
        case .timeout:
            return "本地模型在限定时间内没有返回；可以直接重试。"
        case let .badStatus(code):
            return "本地模型返回 HTTP \(code)；这次观察没有采用。"
        case .emptyResponse:
            return "本地模型没有返回内容；这次观察没有采用。"
        case .invalidResponse:
            return "本地模型没有按约定返回观察结构；这次结果已丢弃。"
        case .unsafeOutput:
            return "本地模型输出了删除类指令；按只读边界整条丢弃。"
        case .ungrounded:
            return "本地模型的发现没有引用可核对的事实；按只读边界丢弃。"
        }
    }
}

struct LocalObservationRawFinding: Codable, Sendable {
    public let level: String?
    public let title: String?
    public let detail: String?
    public let evidence: [String]?
    public let confidence: Double?
}

struct LocalObservationRawPayload: Codable, Sendable {
    public let headline: String?
    public let summary: String?
    public let findings: [LocalObservationRawFinding]?
}

/// 模型可以复述证据，但不许自己造百分比。只拦这种最容易看出来的越界；
/// 其余数字仍靠 UI 里逐条展示的 evidence 供人核对。
enum NumericClaimGuard {
    private static let percentPattern = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*%"#)

    static func hasUnsupportedPercent(in text: String, evidenceText: [String]) -> Bool {
        guard let regex = percentPattern else { return false }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return false }
        let allowed = evidenceText.joined(separator: " ")
        for match in matches {
            guard match.numberOfRanges > 1 else { return true }
            let claim = ns.substring(with: match.range(at: 1))
            if !allowed.contains(claim) { return true }
        }
        return false
    }
}

public enum LocalObservationDecoder {

    public static func decode(
        content: String,
        allowedEvidence: Set<String>,
        evidenceText: [String] = []
    ) throws -> LocalObservationReport {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end,
              let data = String(text[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(LocalObservationRawPayload.self, from: data)
        else {
            throw LocalObservationError.invalidResponse
        }

        let combined = [payload.headline ?? "", payload.summary ?? ""]
            + (payload.findings ?? []).flatMap { [$0.title ?? "", $0.detail ?? ""] }
        guard AIOutputGuard.detectedInstructions(in: combined.joined(separator: " ")).isEmpty else {
            throw LocalObservationError.unsafeOutput
        }

        let headline = String((payload.headline ?? "本机观察").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let summary = String((payload.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        var findings: [LocalObservationFinding] = []
        for raw in (payload.findings ?? []).prefix(3) {
            let title = String((raw.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            let detail = String((raw.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(90))
            let cited = Array(Set((raw.evidence ?? []).filter { allowedEvidence.contains($0) })).sorted()
            guard !title.isEmpty, !detail.isEmpty, !cited.isEmpty else { continue }
            // 模型只允许复述证据里已经给出的百分比；自己算的 14.3% 这类数字整条丢弃。
            guard !NumericClaimGuard.hasUnsupportedPercent(in: "\(title) \(detail)", evidenceText: evidenceText) else {
                continue
            }
            let level = LocalObservationFinding.Level(rawValue: raw.level ?? "") ?? .note
            findings.append(
                LocalObservationFinding(
                    id: "finding-\(findings.count)",
                    level: level,
                    title: title,
                    detail: detail,
                    evidence: cited,
                    confidence: min(1, max(0, raw.confidence ?? 0.5))
                )
            )
        }
        guard !findings.isEmpty else {
            throw LocalObservationError.ungrounded
        }
        return LocalObservationReport(headline: headline, summary: summary, findings: findings)
    }
}

public enum LocalObservationBridge {
    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
        }
    }

    public static func observe(
        facts: LocalObservationFacts,
        configuration: AssistantProviderConfiguration,
        apiKey: String
    ) async throws -> LocalObservationReport {
        guard facts.hasEnoughFacts else { throw LocalObservationError.noFacts }
        let normalized = configuration.normalized()
        guard normalized.chatCompletionsURL != nil else {
            throw LocalObservationError.invalidConfiguration
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let factsData = try? encoder.encode(facts),
              let factsJSON = String(data: factsData, encoding: .utf8)
        else {
            throw LocalObservationError.invalidResponse
        }
        let userPrompt = """
        下面是已经由本机规则和日常记录算好的只读事实，请只根据这些事实观察：
        \(factsJSON)
        """

        guard let url = normalized.chatCompletionsURL else {
            throw LocalObservationError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(normalized.timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("雪/\(AppVersion.current.number)", forHTTPHeaderField: "User-Agent")

        let body = ChatRequest(
            model: normalized.model,
            messages: [
                .init(role: "system", content: LocalObservationPrompt.instructions),
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0.1,
            maxTokens: 700
        )
        request.httpBody = try JSONEncoder().encode(body)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = TimeInterval(normalized.timeoutSeconds)
        sessionConfiguration.timeoutIntervalForResource = TimeInterval(normalized.timeoutSeconds)
        sessionConfiguration.waitsForConnectivity = false
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut { throw LocalObservationError.timeout }
            throw LocalObservationError.networkUnavailable
        } catch {
            throw LocalObservationError.networkUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw LocalObservationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalObservationError.badStatus(http.statusCode)
        }
        guard let chat = try? JSONDecoder().decode(AssistantRemoteChatResponse.self, from: data),
              let content = chat.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else {
            throw LocalObservationError.emptyResponse
        }

        return try LocalObservationDecoder.decode(
            content: content,
            allowedEvidence: Set(facts.evidence.map(\.id)),
            evidenceText: facts.evidence.map { "\($0.label) \($0.value)" }
        )
    }
}
