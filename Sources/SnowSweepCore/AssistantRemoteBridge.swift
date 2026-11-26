import Foundation

/// OpenAI-compatible 意图解析。只发送用户原话和固定字段说明，不发送路径、文件名、体积或扫描结果。
public enum AssistantRemoteBridge {
    public static func parse(
        _ text: String,
        fallback: CleanIntent?,
        configuration: AssistantProviderConfiguration,
        apiKey: String?,
        origin: AssistantOrigin = .remote
    ) async throws -> CleanIntent {
        let normalized = configuration.normalized()
        guard normalized.remoteIsConfigured, let endpoint = normalized.chatCompletionsURL else {
            throw AssistantProviderValidationError.invalidBaseURL
        }
        guard normalized.modelIsValid else {
            throw AssistantProviderValidationError.invalidModel
        }
        guard let apiKey, !apiKey.isEmpty else {
            throw AssistantProviderValidationError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(normalized.timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("雪/\(AppVersion.current.number)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try AssistantRemoteChatRequest(model: normalized.model, userText: text).encoded()

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
            if error.code == .timedOut {
                throw AssistantProviderValidationError.timeout
            }
            throw AssistantProviderValidationError.networkUnavailable
        } catch {
            throw AssistantProviderValidationError.networkUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw AssistantProviderValidationError.unreadableResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AssistantProviderValidationError.badStatus(http.statusCode)
        }

        let chat: AssistantRemoteChatResponse
        do {
            chat = try JSONDecoder().decode(AssistantRemoteChatResponse.self, from: data)
        } catch {
            throw AssistantProviderValidationError.unreadableResponse
        }
        guard let content = chat.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AssistantProviderValidationError.emptyResponse
        }
        guard let payload = AssistantRemoteIntentDecoder.decode(content: content) else {
            throw AssistantProviderValidationError.unreadableResponse
        }
        guard let intent = AssistantIntentMapping.makeIntent(
            goal: payload.goal,
            targets: payload.targets,
            excludes: payload.excludes,
            mode: payload.mode,
            rawText: text,
            fallback: fallback,
            origin: origin
        ) else {
            throw AssistantProviderValidationError.unreadableResponse
        }
        return intent
    }
}
