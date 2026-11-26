import Foundation
import Security

/// 模型接入路由。默认系统本地模型；API 只是可插拔选项，规则解析始终兜底。
public enum AssistantProviderRoute: String, Codable, CaseIterable, Identifiable, Sendable {
    case rulesOnly
    case system
    case local3B
    case openAICompatible

    public var id: String { rawValue }

    public var chineseName: String {
        switch self {
        case .rulesOnly: return "仅本地规则"
        case .system: return "系统本地模型"
        case .local3B: return "本地小模型（可选）"
        case .openAICompatible: return "OpenAI 兼容 API"
        }
    }

    public var detail: String {
        switch self {
        case .rulesOnly: return "不调用任何模型；只按本地词典和规则解析，最省电。"
        case .system: return "Apple Foundation Models，本机推理；不可用时自动退回规则。"
        case .local3B: return "用你自己的 GGUF 权重和 llama-server 本机推理；推荐 4B 观测模型，没配置就退回规则。权重不随 App 分发。"
        case .openAICompatible: return "请求你配置的兼容接口；失败自动退回系统模型或规则。"
        }
    }

    public var usesModelHost: Bool { self != .rulesOnly }
}

/// 只描述接入方式，不包含 API Key。Key 单独进钥匙串，不写偏好、不进导入导出。
public struct AssistantProviderConfiguration: Codable, Equatable, Sendable {
    public static let storageKey = "snow.assistant.provider"
    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let defaultModel = "gpt-4.1-mini"

    public var route: AssistantProviderRoute
    public var baseURL: String
    public var model: String
    public var timeoutSeconds: Int
    /// 本地 3B 是可选能力：权重和 llama-server 都由用户自己提供，不随 App 分发。
    public var localModelPath: String?
    public var localRuntimePath: String?
    public var localPort: Int

    public init(
        route: AssistantProviderRoute = .system,
        baseURL: String = AssistantProviderConfiguration.defaultBaseURL,
        model: String = AssistantProviderConfiguration.defaultModel,
        timeoutSeconds: Int = 12,
        localModelPath: String? = nil,
        localRuntimePath: String? = nil,
        localPort: Int = 19191
    ) {
        self.route = route
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.localModelPath = localModelPath
        self.localRuntimePath = localRuntimePath
        self.localPort = localPort
    }

    private enum CodingKeys: String, CodingKey {
        case route, baseURL, model, timeoutSeconds
        case localModelPath, localRuntimePath, localPort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        route = try c.decodeIfPresent(AssistantProviderRoute.self, forKey: .route) ?? .system
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
            ?? AssistantProviderConfiguration.defaultBaseURL
        model = try c.decodeIfPresent(String.self, forKey: .model)
            ?? AssistantProviderConfiguration.defaultModel
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 12
        localModelPath = try c.decodeIfPresent(String.self, forKey: .localModelPath)
        localRuntimePath = try c.decodeIfPresent(String.self, forKey: .localRuntimePath)
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? 19191
    }

    public static let `default` = AssistantProviderConfiguration()

    public func normalized() -> AssistantProviderConfiguration {
        var copy = self
        copy.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while copy.baseURL.hasSuffix("/") { copy.baseURL.removeLast() }
        copy.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.timeoutSeconds = min(max(timeoutSeconds, 3), 30)
        copy.localModelPath = normalizedPath(localModelPath)
        copy.localRuntimePath = normalizedPath(localRuntimePath)
        copy.localPort = min(max(localPort, 19_000), 19_999)
        return copy
    }

    private func normalizedPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : NSString(string: trimmed).expandingTildeInPath
    }

    public var localIsConfigured: Bool {
        guard route == .local3B else { return false }
        let normalized = normalized()
        guard let model = normalized.localModelPath,
              let runtime = normalized.localRuntimePath
        else { return false }
        return FileManager.default.fileExists(atPath: model)
            && FileManager.default.isExecutableFile(atPath: runtime)
    }

    public var localRuntimeIsPresent: Bool {
        guard let runtime = normalized().localRuntimePath else { return false }
        return FileManager.default.isExecutableFile(atPath: runtime)
    }

    public var localModelIsPresent: Bool {
        guard let model = normalized().localModelPath else { return false }
        return FileManager.default.fileExists(atPath: model)
    }

    /// 只接受 HTTPS；本机调试允许 localhost / 127.0.0.1 的 HTTP。
    public func validatedBaseURL() -> URL? {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2_048 else { return nil }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { return nil }

        switch scheme {
        case "https":
            break
        case "http":
            let localHosts = ["localhost", "127.0.0.1", "::1"]
            guard localHosts.contains(host.lowercased()) else { return nil }
        default:
            return nil
        }

        return components.url
    }

    public var chatCompletionsURL: URL? {
        guard let base = validatedBaseURL() else { return nil }
        if base.path.lowercased().hasSuffix("/chat/completions") { return base }
        return base.appendingPathComponent("chat/completions")
    }

    public var modelIsValid: Bool {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120 else { return false }
        return value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    public var remoteIsConfigured: Bool {
        route == .openAICompatible && chatCompletionsURL != nil && modelIsValid
    }
}

public enum AssistantProviderValidationError: LocalizedError, Equatable {
    case invalidBaseURL
    case invalidModel
    case missingAPIKey
    case networkUnavailable
    case timeout
    case badStatus(Int)
    case emptyResponse
    case unreadableResponse

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "接口地址必须是 HTTPS，或以 http://localhost / 127.0.0.1 开头。"
        case .invalidModel:
            return "模型名不能为空，也不能包含空格。"
        case .missingAPIKey:
            return "还没有保存 API Key。"
        case .networkUnavailable:
            return "连不上接口，或网络中断；这次结果没有采用。"
        case .timeout:
            return "接口在限定时间内没有返回；这次结果没有采用。"
        case let .badStatus(code):
            switch code {
            case 401, 403:
                return "API Key 被拒绝（HTTP \(code)）；这次结果没有采用。"
            case 404:
                return "接口路径不对（HTTP 404）；检查地址是否以 /v1 结尾。"
            case 429:
                return "接口请求过多（HTTP 429）；稍后再试。"
            case 500...599:
                return "接口服务器出错（HTTP \(code)）；这次结果没有采用。"
            default:
                return "接口返回 HTTP \(code)；这次结果没有采用。"
            }
        case .emptyResponse:
            return "接口没有返回内容；这次结果没有采用。"
        case .unreadableResponse:
            return "接口返回的结构不是约定的意图字段；这次结果没有采用。"
        }
    }
}

/// 远程模型只拿得到用户这一句话，以及固定的字段说明；拿不到路径、文件名、体积或扫描结果。
public enum AssistantProviderPrompt {
    public static let instructions = """
    你是雪的意图解析器。只把用户的话翻译成结构化字段，不解释系统知识，不给清理建议。
    你不能输出路径、命令、文件名或体积数字。用户没有明确点名的对象，不要自行扩大。
    如果用户说“别动聊天记录/照片/文稿”，必须放进 excludes。
    如果用户说“只看看/先别删/预览”，mode 必须是 analyze。
    如果用户要求删除系统文件，targets 填 system，并在 understanding 里说明这不在清理范围。
    只返回一个 JSON 对象，不要 Markdown，不要代码块，不要额外解释。
    JSON 字段：goal（clean/inspect/uninstall/optimize/unknown）、targets（数组，最多 4 个）、excludes（数组）、mode（analyze/preview）、understanding（一句中文）。
    targets 只能从 appCache、doubao、wechat、logs、developerCache、oldInstallers、space、memory、battery、network、system、unknown 中选。
    excludes 只能从 chatHistory、photos、documents、userFiles、systemFiles、trash 中选。
    """
}

public struct AssistantRemoteChatRequest: Encodable, Sendable {
    public struct Message: Encodable, Sendable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public let model: String
    public let messages: [Message]
    public let temperature: Double
    public let maxTokens: Int

    private enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }

    public init(model: String, userText: String) {
        self.model = model
        self.messages = [
            Message(role: "system", content: AssistantProviderPrompt.instructions),
            Message(role: "user", content: userText)
        ]
        self.temperature = 0.2
        self.maxTokens = 300
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

public struct AssistantRemoteIntentPayload: Codable, Equatable, Sendable {
    public var goal: String
    public var targets: [String]
    public var excludes: [String]
    public var mode: String
    public var understanding: String

    public init(
        goal: String = "unknown",
        targets: [String] = [],
        excludes: [String] = [],
        mode: String = "preview",
        understanding: String = ""
    ) {
        self.goal = goal
        self.targets = targets
        self.excludes = excludes
        self.mode = mode
        self.understanding = understanding
    }

    private enum CodingKeys: String, CodingKey {
        case goal, targets, excludes, mode, understanding
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? "unknown"
        targets = try c.decodeIfPresent([String].self, forKey: .targets) ?? []
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? []
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "preview"
        understanding = try c.decodeIfPresent(String.self, forKey: .understanding) ?? ""
    }
}

public struct AssistantRemoteChatResponse: Decodable, Sendable {
    public struct Choice: Decodable, Sendable {
        public struct Message: Decodable, Sendable {
            public let content: String?
        }
        public let message: Message
    }
    public let choices: [Choice]
}

public enum AssistantRemoteIntentDecoder {
    /// 兼容模型偶尔加代码块、前后解释；只取第一个完整 JSON 对象。
    public static func decode(content: String) -> AssistantRemoteIntentPayload? {
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
              start <= end
        else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AssistantRemoteIntentPayload.self, from: data)
    }
}

/// 单一 API Key，service 固定；不按模型复制，换接口时由用户显式清除。
public struct AssistantKeychain: Sendable {
    public static let defaultService = SnowIdentity.assistantKeychainService
    public static let defaultAccount = "openai-compatible"

    public let service: String
    public let account: String

    public init(service: String = defaultService, account: String = defaultAccount) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete()
            return
        }
        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AssistantKeychainError.status(updateStatus)
        }

        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AssistantKeychainError.status(addStatus)
        }
    }

    public func delete() {
        _ = SecItemDelete(baseQuery as CFDictionary)
    }

    public var hasValue: Bool { read() != nil }
}

public enum AssistantKeychainError: LocalizedError, Equatable {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .status(code):
            return "钥匙串写入失败（\(code)），API Key 没有保存。"
        }
    }
}
