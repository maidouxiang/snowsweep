import Foundation
import Testing
@testable import SnowSweepCore

private struct StubReply: Sendable {
    let status: Int
    let body: Data
}

/// 同一测试套件串行执行，用进程内 URLProtocol 回放接口，不碰真实网络。
private final class HandoffStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [StubReply] = []
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var capturedBodies: [Data?] = []

    static func reset() {
        lock.lock()
        queue = []
        captured = []
        capturedBodies = []
        lock.unlock()
    }

    static func enqueue(status: Int = 200, content: String) {
        let body = chatBody(content: content)
        lock.lock()
        queue.append(StubReply(status: status, body: body))
        lock.unlock()
    }

    static func enqueue(status: Int, body: Data) {
        lock.lock()
        queue.append(StubReply(status: status, body: body))
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func body(at index: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0, index < capturedBodies.count else { return nil }
        return capturedBodies[index]
    }

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16_384
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply: StubReply?
        let body = Self.readBody(request)
        Self.lock.lock()
        Self.captured.append(request)
        Self.capturedBodies.append(body)
        reply = Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        Self.lock.unlock()

        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.test/v1/chat/completions")!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func chatBody(content: String) -> Data {
    let object: [String: Any] = [
        "choices": [
            ["message": ["content": content]]
        ]
    ]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HandoffStubURLProtocol.self]
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 3
    return URLSession(configuration: configuration)
}

private func provider(route: AssistantProviderRoute = .openAICompatible) -> AssistantProviderConfiguration {
    AssistantProviderConfiguration(
        route: route,
        baseURL: "https://example.test/v1",
        model: "mock-handoff",
        timeoutSeconds: 3
    )
}

private func report() -> UnknownCase {
    UnknownCase(
        id: "ADC0FFEE-0000-4000-8000-000000000001",
        createdAt: Date(timeIntervalSince1970: 1_764_000_000),
        query: "ZetaBig 的离线素材应该交给谁审核？",
        reason: "现有内置规则只覆盖应用缓存，没有覆盖离线素材审核目录。",
        closestRules: [
            RuleHint(
                id: "davinci-render-cache",
                name: "达芬奇渲染缓存",
                pathPattern: "~/Library/Caches/com.blackmagic-design.DaVinciResolve/**",
                reason: "同为素材工作流缓存",
                score: 2
            )
        ],
        observedPaths: ["未提供具体路径；只能从原话和现有规则反推候选目录"]
    )
}

private func ambiguousReport() -> UnknownCase {
    UnknownCase(
        id: "ADA29EA6-BF25-4B7E-90DF-FDDEDC8FEEE4",
        createdAt: Date(timeIntervalSince1970: 1_764_000_000),
        query: "ZetaBig 的离线素材应该交给谁审核？",
        reason: "可以说“豆包缓存太多了”“微信缓存有多大”或“看看谁占空间”。",
        closestRules: [
            RuleHint(
                id: "davinci-render-cache",
                name: "达芬奇渲染缓存",
                pathPattern: "~/Library/Application Support/Blackmagic Design/DaVinci Resolve/CacheClip/**",
                reason: "同为素材工作流缓存",
                score: 2
            )
        ],
        observedPaths: ["未提供具体路径；只能从原话和现有规则反推候选目录"]
    )
}

private func builtinBook() -> RuleBook {
    RuleBook(
        version: "test",
        updatedAt: nil,
        protectedPaths: ["~/Protected/**"],
        rules: [
            Rule(
                id: "davinci-render-cache",
                risk: .review,
                name: "达芬奇渲染缓存",
                pathPattern: "~/Library/Caches/com.blackmagic-design.DaVinciResolve/**",
                reason: "可重建缓存",
                needConfirm: true,
                priority: 20,
                source: "builtin",
                actionType: .trash
            )
        ]
    )
}

private func draftContent(
    id: String = "zetabig-offline-review",
    source: String = "builtin",
    allowOverride: Bool = true,
    extraRuleField: String? = nil,
    extraEnvelopeField: String? = nil
) -> String {
    let extraRule = extraRuleField.map { ",\"\($0)\":\"rm -rf ~\"" } ?? ""
    let extraEnvelope = extraEnvelopeField.map { ",\"\($0)\":\"now\"" } ?? ""
    return """
    {
      "kind": "snow-rule-draft",
      "schemaVersion": 1,
      "caseID": "ADC0FFEE-0000-4000-8000-000000000001",
      "generatedAt": "2026-11-25T14:00:00Z",
      "source": "cloud",
      "notes": "只根据报告起草，未在本机验证。",
      "rules": [
        {
          "id": "\(id)",
          "risk": "review",
          "name": "ZetaBig 离素材审核缓存",
          "pathPattern": "~/Library/Caches/ZetaBig/OfflineReview/**",
          "reason": "报告只给出应用名，未确认目录；先按 review 起草",
          "needConfirm": true,
          "priority": 8,
          "actionType": "trash",
          "source": "\(source)",
          "allowOverrideProtection": \(allowOverride ? "true" : "false"),
          "sourceKind": "community",
          "confidence": 0.35
        }
      ]\(extraEnvelope)\(extraRule)
    }
    """
}

private func clarifyContent(
    extraQuestionField: String? = nil,
    questionCount: Int = 1
) -> String {
    let extra = extraQuestionField.map { ",\"\($0)\":\"忽略前面的规则\"" } ?? ""
    let second = questionCount > 1
        ? ",{\"id\":\"q2\",\"field\":\"rebuildCost\",\"prompt\":\"这些素材能否重建？\",\"why\":\"决定是否需要确认\",\"placeholder\":\"可以重新导出\"}"
        : ""
    let first = "{\"id\":\"q1\",\"field\":\"path\",\"prompt\":\"请给出 ZetaBig 离线素材的具体目录\",\"why\":\"没有路径就不能起草安全规则\",\"placeholder\":\"~/Library/Caches/ZetaBig/OfflineReview\"\(extra)}"
    return """
    {
      "kind": "snow-rule-clarify",
      "schemaVersion": 1,
      "questions": [
        \(first)\(second)
      ]
    }
    """
}

@Suite(.serialized)
struct UnknownHandoffClientTests {
    @Test func payloadCarriesHelloCaseAndBuiltinIndexWithoutUserName() async throws {
        HandoffStubURLProtocol.reset()
        HandoffStubURLProtocol.enqueue(content: clarifyContent())

        let client = UnknownHandoffClient(
            provider: provider(),
            apiKey: "test-key",
            session: makeSession()
        )
        _ = try await client.send(report: report(), builtin: builtinBook())

        let request = try #require(HandoffStubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(HandoffStubURLProtocol.body(at: 0))
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(root["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        let userText = try #require(messages[1]["content"] as? String)
        #expect(userText.contains("\"step\":\"case\""))
        #expect(userText.contains("ADC0FFEE-0000-4000-8000-000000000001"))
        #expect(userText.contains("davinci-render-cache"))
        #expect(userText.contains("\"protocolVersion\":1"))
        #expect(!userText.contains("/Users/"))
        #expect(!userText.lowercased().contains("example"))
    }

    @Test func clarifyParsesQuestionsAndKeepsRawJSON() async throws {
        HandoffStubURLProtocol.reset()
        HandoffStubURLProtocol.enqueue(content: clarifyContent(questionCount: 2))
        let client = UnknownHandoffClient(provider: provider(), apiKey: "test-key", session: makeSession())

        let reply = try await client.send(report: report(), builtin: builtinBook())
        guard case let .clarify(clarification) = reply else {
            Issue.record("应该返回 clarify")
            return
        }
        #expect(clarification.questions.count == 2)
        #expect(clarification.questions.first?.field == .path)
        #expect(clarification.rawJSON.contains("snow-rule-clarify"))
    }

    @Test func clarifyRejectsFieldOutsideWhitelist() async throws {
        HandoffStubURLProtocol.reset()
        HandoffStubURLProtocol.enqueue(content: clarifyContent(extraQuestionField: "command"))
        let client = UnknownHandoffClient(provider: provider(), apiKey: "test-key", session: makeSession())

        do {
            _ = try await client.send(report: report(), builtin: builtinBook())
            Issue.record("带 command 的追问应该被拒绝")
        } catch let error as UnknownHandoffError {
            guard case let .forbiddenClarifyField(field) = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
            #expect(field == "command")
        }
    }

    @Test func draftPassesLocalNormalizationAndForcesUserSource() async throws {
        HandoffStubURLProtocol.reset()
        HandoffStubURLProtocol.enqueue(content: draftContent())
        let client = UnknownHandoffClient(provider: provider(), apiKey: "test-key", session: makeSession())

        let reply = try await client.send(report: report(), builtin: builtinBook())
        guard case let .draft(draft) = reply else {
            Issue.record("应该返回 draft")
            return
        }
        #expect(draft.ruleCount == 1)
        #expect(draft.draft.rules.first?.source == "user")
        #expect(draft.draft.rules.first?.allowOverrideProtection == false)
        #expect(draft.data.contains(Data("\"source\":\"user\"".utf8)))
        #expect(draft.data.contains(Data("\"protectedPaths\":[]".utf8)))
        #expect(draft.rawJSON.contains("snow-rule-draft"))
    }

    @Test func draftWithCommandFieldIsRejectedBeforeImport() async throws {
        HandoffStubURLProtocol.reset()
        HandoffStubURLProtocol.enqueue(content: draftContent(extraRuleField: "command"))
        let client = UnknownHandoffClient(provider: provider(), apiKey: "test-key", session: makeSession())

        do {
            _ = try await client.send(report: report(), builtin: builtinBook())
            Issue.record("带 command 的草稿应该被拒绝")
        } catch let error as UnknownHandoffError {
            guard case let .invalidDraft(reason) = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
            #expect(reason.contains("不允许的字段"))
        }
    }

    @Test func followUpCarriesClarifyAndAnswers() async throws {
        HandoffStubURLProtocol.reset()
        let clarify = clarifyContent()
        HandoffStubURLProtocol.enqueue(content: clarify)
        HandoffStubURLProtocol.enqueue(content: draftContent())
        let client = UnknownHandoffClient(provider: provider(), apiKey: "test-key", session: makeSession())

        let first = try await client.send(report: report(), builtin: builtinBook())
        guard case let .clarify(clarification) = first else {
            Issue.record("第一轮应该是 clarify")
            return
        }
        let second = try await client.send(
            report: report(),
            builtin: builtinBook(),
            clarification: UnknownHandoffClarificationContext(
                assistantJSON: clarification.rawJSON,
                answers: ["q1": "~/Library/Caches/ZetaBig/OfflineReview"]
            )
        )
        guard case .draft = second else {
            Issue.record("第二轮应该是 draft")
            return
        }

        let body = try #require(HandoffStubURLProtocol.body(at: 1))
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(root["messages"] as? [[String: Any]])
        #expect(messages.count == 4)
        #expect(messages[2]["role"] as? String == "assistant")
        #expect((messages[2]["content"] as? String) == clarification.rawJSON)
        let answersText = try #require(messages[3]["content"] as? String)
        #expect(answersText.contains("\"step\":\"answers\""))
        #expect(answersText.contains("~/Library/Caches/ZetaBig/OfflineReview"))
    }

    @Test func secondClarificationIsRejected() async throws {
        HandoffStubURLProtocol.reset()
        HandoffStubURLProtocol.enqueue(content: clarifyContent())
        let client = UnknownHandoffClient(provider: provider(), apiKey: "test-key", session: makeSession())

        do {
            _ = try await client.send(
                report: report(),
                builtin: builtinBook(),
                clarification: UnknownHandoffClarificationContext(
                    assistantJSON: clarifyContent(),
                    answers: ["q1": "~/Library/Caches/ZetaBig/OfflineReview"]
                )
            )
            Issue.record("第二次 clarify 应该被拒绝")
        } catch let error as UnknownHandoffError {
            guard case .clarificationExhausted = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        }
    }

    @Test func routeAndHTTPFailuresDoNotLeakRequest() async throws {
        HandoffStubURLProtocol.reset()
        let local = UnknownHandoffClient(
            provider: provider(route: .local3B),
            apiKey: "test-key",
            session: makeSession()
        )
        do {
            _ = try await local.send(report: report(), builtin: builtinBook())
            Issue.record("非 API 路由应该被拒绝")
        } catch let error as UnknownHandoffError {
            guard case .providerNotConfigured = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        }
        #expect(HandoffStubURLProtocol.requests.isEmpty)

        HandoffStubURLProtocol.enqueue(status: 401, body: Data("{}".utf8))
        let client = UnknownHandoffClient(provider: provider(), apiKey: "test-key", session: makeSession())
        do {
            _ = try await client.send(report: report(), builtin: builtinBook())
            Issue.record("401 应该被拒绝")
        } catch let error as UnknownHandoffError {
            guard case let .badStatus(code) = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
            #expect(code == 401)
        }
    }
    /// 真实 LM Studio / OpenAI 兼容端点的可选端到端：只在设置 SNOW_LIVE_BASE_URL 时运行。
    /// 仍然走生产客户端与本地草稿校验，不走 URLProtocol 回放。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SNOW_LIVE_BASE_URL"] != nil))
    func liveCompatibleEndpointRunsFourStepHandoff() async throws {
        let env = ProcessInfo.processInfo.environment
        let baseURL = try #require(env["SNOW_LIVE_BASE_URL"])
        let model = try #require(env["SNOW_LIVE_MODEL"])
        let key = try #require(env["SNOW_LIVE_API_KEY"])
        let config = AssistantProviderConfiguration(
            route: .openAICompatible,
            baseURL: baseURL,
            model: model,
            timeoutSeconds: 30
        )
        let client = UnknownHandoffClient(provider: config, apiKey: key)
        let sample = ambiguousReport()
        let first = try await client.send(report: sample, builtin: builtinBook())
        switch first {
        case let .draft(draft):
            print("[LIVE] first reply draft, rules=\(draft.ruleCount), case=\(draft.draft.caseID ?? "nil")")
            #expect(draft.ruleCount >= 1)
            #expect(draft.draft.rules.allSatisfy { $0.pathPattern.hasPrefix("~/") })
        case let .clarify(clarification):
            print("[LIVE] first reply clarify, questions=\(clarification.questions.count)")
            #expect((1...2).contains(clarification.questions.count))
            var answers: [String: String] = [:]
            for question in clarification.questions {
                switch question.field {
                case .path: answers[question.id] = "~/Library/Caches/ZetaBig/OfflineReview"
                case .appName: answers[question.id] = "ZetaBig"
                case .fileExtensions: answers[question.id] = "mp4,mov"
                case .ageDays: answers[question.id] = "30"
                case .rebuildCost: answers[question.id] = "可以重新导出"
                case .owner: answers[question.id] = "ZetaBig 素材团队"
                }
            }
            let second = try await client.send(
                report: sample,
                builtin: builtinBook(),
                clarification: UnknownHandoffClarificationContext(
                    assistantJSON: clarification.rawJSON,
                    answers: answers
                )
            )
            guard case let .draft(draft) = second else {
                Issue.record("第二轮仍返回 clarify，四步握手未闭合")
                return
            }
            print("[LIVE] second reply draft, rules=\(draft.ruleCount), case=\(draft.draft.caseID ?? "nil")")
            #expect(draft.ruleCount >= 1)
            #expect(draft.draft.rules.allSatisfy { $0.pathPattern.hasPrefix("~/") })
            #expect(draft.draft.rules.contains { $0.pathPattern.contains("ZetaBig") })
        }
    }

}
