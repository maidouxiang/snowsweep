import Foundation
import Testing
@testable import SnowSweepCore

@Test func scannerRequestRoundTripsThroughData() throws {
    let book = RuleBook(
        version: "test",
        updatedAt: nil,
        protectedPaths: [],
        rules: []
    )
    let request = ScannerXPCRequest(
        ruleBook: book,
        scope: .userOnly,
        home: "/tmp/snowsweep-test",
        maxConcurrentRoots: 2,
        maxItemsPerRoot: 50,
        extraProtectedPaths: ["/tmp/snowsweep-protected"],
        cancelAfterSeconds: 3
    )
    let encoded = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(ScannerXPCRequest.self, from: encoded)
    #expect(decoded.scope == .userOnly)
    #expect(decoded.maxConcurrentRoots == 2)
    #expect(decoded.maxItemsPerRoot == 50)
    #expect(decoded.cancelAfterSeconds == 3)
    #expect(decoded.ruleBook.version == "test")
}

@Test func scannerResponseCarriesCancelledSummary() throws {
    let response = ScannerXPCResponse(
        items: [],
        gaps: [],
        summary: ScanStreamSummary(scanned: 12, kept: 3, cancelled: true),
        failure: nil
    )
    let decoded = try JSONDecoder().decode(
        ScannerXPCResponse.self,
        from: JSONEncoder().encode(response)
    )
    #expect(decoded.cancelled)
    #expect(decoded.summary.scanned == 12)
    #expect(decoded.summary.kept == 3)
}

@Test func local3BConfigurationNormalizesPortAndTilde() {
    let config = AssistantProviderConfiguration(
        route: .local3B,
        localModelPath: "  ~/Models/demo.gguf ",
        localRuntimePath: "~/bin/llama-server",
        localPort: 18_000
    ).normalized()
    #expect(config.route == .local3B)
    #expect(config.localPort == 19_000)
    #expect(config.localModelPath == NSString(string: "~/Models/demo.gguf").expandingTildeInPath)
    #expect(config.localRuntimePath == NSString(string: "~/bin/llama-server").expandingTildeInPath)
}

@Test func local3BIsNotConfiguredWhenFilesAreMissing() {
    let config = AssistantProviderConfiguration(
        route: .local3B,
        localModelPath: "/tmp/snowsweep-no-such-model.gguf",
        localRuntimePath: "/tmp/snowsweep-no-such-runtime",
        localPort: 19191
    )
    #expect(!config.localIsConfigured)
    #expect(!config.localModelIsPresent)
    #expect(!config.localRuntimeIsPresent)
}

@Test func oldProviderConfigurationDecodesWithDefaults() throws {
    let old = """
    {"route":"system","baseURL":"https://api.openai.com/v1","model":"gpt-4.1-mini","timeoutSeconds":12}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AssistantProviderConfiguration.self, from: old)
    #expect(config.route == .system)
    #expect(config.localModelPath == nil)
    #expect(config.localRuntimePath == nil)
    #expect(config.localPort == 19191)
}

@Test func modelHostRequestEncodesLocal3BRoute() throws {
    let fallback = CleanIntent(
        rawText: "清理缓存",
        goal: .clean,
        targets: [],
        mode: .preview,
        interpretation: "测试"
    )
    let request = ModelHostRequest(
        text: "清一下缓存",
        fallback: fallback,
        route: .local3B,
        apiConfiguration: .init(route: .local3B, localPort: 19191),
        apiKey: nil,
        localModelPath: "/tmp/model.gguf",
        localRuntimePath: "/tmp/llama-server",
        localPort: 19191
    )
    let decoded = try JSONDecoder().decode(
        ModelHostRequest.self,
        from: JSONEncoder().encode(request)
    )
    #expect(decoded.route == .local3B)
    #expect(decoded.localPort == 19191)
    #expect(decoded.localModelPath == "/tmp/model.gguf")
}
