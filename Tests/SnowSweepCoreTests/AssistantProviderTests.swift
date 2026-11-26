import Foundation
import Testing
@testable import SnowSweepCore

@Test func assistantProviderDefaultsToSystemAndKeepsConfig() throws {
    let config = AssistantProviderConfiguration.default
    #expect(config.route == .system)
    #expect(config.timeoutSeconds == 12)

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AssistantProviderConfiguration.self, from: data)
    #expect(decoded == config)
}

@Test func assistantProviderNormalizesTrailingSlashAndClampsTimeout() {
    let config = AssistantProviderConfiguration(
        route: .openAICompatible,
        baseURL: "  https://api.example.com/v1/  ",
        model: "  gpt-test  ",
        timeoutSeconds: 99
    ).normalized()
    #expect(config.baseURL == "https://api.example.com/v1")
    #expect(config.model == "gpt-test")
    #expect(config.timeoutSeconds == 30)
}

@Test func assistantProviderAcceptsHTTPSAndLocalHTTPOnly() {
    #expect(AssistantProviderConfiguration(baseURL: "https://api.openai.com/v1").validatedBaseURL() != nil)
    #expect(AssistantProviderConfiguration(baseURL: "http://localhost:11434/v1").validatedBaseURL() != nil)
    #expect(AssistantProviderConfiguration(baseURL: "http://127.0.0.1:8080").validatedBaseURL() != nil)
    #expect(AssistantProviderConfiguration(baseURL: "http://api.example.com/v1").validatedBaseURL() == nil)
    #expect(AssistantProviderConfiguration(baseURL: "file:///tmp/api").validatedBaseURL() == nil)
    #expect(AssistantProviderConfiguration(baseURL: "https://user:pass@api.example.com").validatedBaseURL() == nil)
    #expect(AssistantProviderConfiguration(baseURL: "https://api.example.com/v1?token=x").validatedBaseURL() == nil)
}

@Test func assistantProviderBuildsChatCompletionsEndpointOnce() {
    let base = AssistantProviderConfiguration(baseURL: "https://api.example.com/v1")
    #expect(base.chatCompletionsURL?.absoluteString == "https://api.example.com/v1/chat/completions")
    let full = AssistantProviderConfiguration(baseURL: "https://api.example.com/v1/chat/completions")
    #expect(full.chatCompletionsURL?.absoluteString == "https://api.example.com/v1/chat/completions")
}

@Test func assistantProviderRejectsModelWithSpaces() {
    #expect(AssistantProviderConfiguration(model: "gpt-4.1-mini").modelIsValid)
    #expect(AssistantProviderConfiguration(model: "gpt 4.1").modelIsValid == false)
    #expect(AssistantProviderConfiguration(model: "   ").modelIsValid == false)
}

@Test func assistantRemoteRequestContainsOnlyOneUserSentence() throws {
    let request = AssistantRemoteChatRequest(model: "gpt-test", userText: "清一下应用缓存，聊天记录别动")
    let data = try request.encoded()
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"role\":\"system\""))
    #expect(text.contains("\"role\":\"user\""))
    #expect(text.contains("清一下应用缓存，聊天记录别动"))
    #expect(text.contains("\"max_tokens\":300"))
    #expect(text.contains("/Users/") == false)
    #expect(text.contains("SnowSweep") == false)
    #expect(text.contains("audit") == false)
}

@Test func assistantRemoteIntentDecoderAcceptsCodeFenceAndMissingFields() {
    let fenced = """
    ```json
    {"goal":"clean","targets":["appCache"],"excludes":["chatHistory"],"mode":"preview"}
    ```
    """
    let payload = AssistantRemoteIntentDecoder.decode(content: fenced)
    #expect(payload?.goal == "clean")
    #expect(payload?.targets == ["appCache"])
    #expect(payload?.excludes == ["chatHistory"])
    #expect(payload?.understanding == "")

    let prose = "结果如下：{\"goal\":\"inspect\",\"targets\":[\"space\"]} 请查收"
    #expect(AssistantRemoteIntentDecoder.decode(content: prose)?.goal == "inspect")
}

@Test func assistantRemoteIntentDecoderRejectsNonJSON() {
    #expect(AssistantRemoteIntentDecoder.decode(content: "我建议先清理缓存") == nil)
    #expect(AssistantRemoteIntentDecoder.decode(content: "{broken") == nil)
}

@Test func assistantIntentMappingRejectsUnknownOnlyAndUsesFallback() {
    let fallback = CleanIntent(
        rawText: "看看",
        goal: .inspect,
        targets: [.space],
        interpretation: "规则结果"
    )
    let mapped = AssistantIntentMapping.makeIntent(
        goal: "unknown",
        targets: ["unknown"],
        excludes: [],
        mode: "preview",
        rawText: "看看",
        fallback: fallback,
        origin: .remote
    )
    #expect(mapped == fallback, "模型没有给出可用对象时必须退回规则，不生成空计划")
}

@Test func assistantIntentMappingKeepsSystemUnsupported() {
    let mapped = AssistantIntentMapping.makeIntent(
        goal: "clean",
        targets: ["system"],
        excludes: [],
        mode: "preview",
        rawText: "删掉系统文件",
        fallback: nil,
        origin: .remote
    )
    #expect(mapped?.unsupported == true)
    #expect(mapped?.origin == .remote)
    #expect(mapped?.interpretation.contains("不在雪的范围") == true)
}

@Test func assistantIntentMappingPrefersExplicitExclusions() {
    let fallback = CleanIntent(
        rawText: "清理缓存",
        goal: .clean,
        targets: [.appCache],
        excludes: [.documents],
        interpretation: "规则"
    )
    let mapped = AssistantIntentMapping.makeIntent(
        goal: "clean",
        targets: ["appCache", "doubao"],
        excludes: ["chatHistory", "photos"],
        mode: "analyze",
        rawText: "清缓存，别动聊天记录和照片",
        fallback: fallback,
        origin: .remote
    )
    #expect(mapped?.targets == [.appCache, .doubao])
    #expect(mapped?.excludes == [.chatHistory, .photos])
    #expect(mapped?.mode == .analyze)
    #expect(mapped?.origin == .remote)
    #expect(mapped?.interpretation.contains("聊天记录") == true)
}

@Test func assistantProviderErrorsNameTheCauseWithoutPaths() {
    #expect(AssistantProviderValidationError.timeout.localizedDescription.contains("没有返回"))
    #expect(AssistantProviderValidationError.networkUnavailable.localizedDescription.contains("连不上"))

    let unauthorized = AssistantProviderValidationError.badStatus(401).localizedDescription
    #expect(unauthorized.contains("HTTP 401"))
    #expect(unauthorized.contains("API Key"))

    let missing = AssistantProviderValidationError.badStatus(404).localizedDescription
    #expect(missing.contains("/v1"))

    let busy = AssistantProviderValidationError.badStatus(429).localizedDescription
    #expect(busy.contains("HTTP 429"))

    let server = AssistantProviderValidationError.badStatus(503).localizedDescription
    #expect(server.contains("HTTP 503"))
    #expect(server.contains("服务器"))

    for error in [
        AssistantProviderValidationError.networkUnavailable,
        .timeout,
        .badStatus(401),
        .badStatus(404),
        .badStatus(429),
        .badStatus(503),
        .emptyResponse,
        .unreadableResponse
    ] {
        let text = error.localizedDescription
        #expect(text.contains("/Users/") == false)
        #expect(text.contains("/Applications") == false)
    }
}
