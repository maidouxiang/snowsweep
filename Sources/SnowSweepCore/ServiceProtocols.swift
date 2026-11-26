import Foundation

// MARK: - Scanner XPC

/// 主 App 与扫描服务之间的唯一传输契约。
/// 规则库随请求传入，扫描服务不读用户目录之外的配置，也不参与删除判定。
public struct ScannerXPCRequest: Codable, Sendable {
    public let ruleBook: RuleBook
    public let scope: ScanScope
    public let home: String
    public let maxConcurrentRoots: Int
    public let maxItemsPerRoot: Int
    public let extraProtectedPaths: [String]
    public let cancelAfterSeconds: Int?
    /// 整次扫描的硬上限。到点后返回已读到的部分，并写一条全局缺口；不会无限等卡住的目录。
    public let overallTimeoutSeconds: Int?

    public init(
        ruleBook: RuleBook,
        scope: ScanScope,
        home: String = NSHomeDirectory(),
        maxConcurrentRoots: Int = 1,
        maxItemsPerRoot: Int = 2_000,
        extraProtectedPaths: [String] = [],
        cancelAfterSeconds: Int? = nil,
        overallTimeoutSeconds: Int? = nil
    ) {
        self.ruleBook = ruleBook
        self.scope = scope
        self.home = home
        self.maxConcurrentRoots = max(1, maxConcurrentRoots)
        self.maxItemsPerRoot = max(1, maxItemsPerRoot)
        self.extraProtectedPaths = extraProtectedPaths
        self.cancelAfterSeconds = cancelAfterSeconds
        self.overallTimeoutSeconds = overallTimeoutSeconds
    }
}

public struct ScannerXPCProgress: Codable, Sendable {
    public let scanned: Int
    public let kept: Int
    public let currentPath: String

    public init(scanned: Int, kept: Int, currentPath: String) {
        self.scanned = scanned
        self.kept = kept
        self.currentPath = currentPath
    }
}

public struct ScannerXPCResponse: Codable, Sendable {
    public let items: [ScanItem]
    public let gaps: [ScanGap]
    public let summary: ScanStreamSummary
    public let failure: String?

    public init(
        items: [ScanItem] = [],
        gaps: [ScanGap] = [],
        summary: ScanStreamSummary,
        failure: String? = nil
    ) {
        self.items = items
        self.gaps = gaps
        self.summary = summary
        self.failure = failure
    }

    public var cancelled: Bool { summary.cancelled }
}

/// XPC 服务侧接口。所有参数都用 Data，避免 Objective-C 桥接对 Swift 结构体的限制。
@objc public protocol ScannerServiceXPC {
    func scan(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func cancel()
}

/// ModelHost 的本地观测入口。只接收已算好的只读事实，不接收文件正文。
@objc public protocol ModelHostObservationXPC {
    func observe(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

/// 主 App 侧接收进度的回调。
@objc public protocol ScannerClientXPC {
    func scannerProgress(_ payload: Data)
}

// MARK: - ModelHost XPC

public enum ModelHostRoute: String, Codable, Sendable {
    case system
    case openAICompatible
    case local3B

    public init(providerRoute: AssistantProviderRoute) {
        switch providerRoute {
        case .rulesOnly, .system: self = .system
        case .openAICompatible: self = .openAICompatible
        case .local3B: self = .local3B
        }
    }
}

public struct ModelHostRequest: Codable, Sendable {
    public let text: String
    public let fallback: CleanIntent
    public let route: ModelHostRoute
    public let apiConfiguration: AssistantProviderConfiguration?
    public let apiKey: String?
    public let localModelPath: String?
    public let localRuntimePath: String?
    public let localPort: Int

    public init(
        text: String,
        fallback: CleanIntent,
        route: ModelHostRoute,
        apiConfiguration: AssistantProviderConfiguration? = nil,
        apiKey: String? = nil,
        localModelPath: String? = nil,
        localRuntimePath: String? = nil,
        localPort: Int = 19191
    ) {
        self.text = text
        self.fallback = fallback
        self.route = route
        self.apiConfiguration = apiConfiguration
        self.apiKey = apiKey
        self.localModelPath = localModelPath
        self.localRuntimePath = localRuntimePath
        self.localPort = localPort
    }
}

public struct ModelHostResponse: Codable, Sendable {
    public let intent: CleanIntent?
    public let failure: String?
    public let providerLabel: String

    public init(intent: CleanIntent?, failure: String?, providerLabel: String) {
        self.intent = intent
        self.failure = failure
        self.providerLabel = providerLabel
    }
}

public struct ModelHostObservationRequest: Codable, Sendable {
    public let facts: LocalObservationFacts
    public let configuration: AssistantProviderConfiguration

    public init(facts: LocalObservationFacts, configuration: AssistantProviderConfiguration) {
        self.facts = facts
        self.configuration = configuration
    }
}

public struct ModelHostObservationResponse: Codable, Sendable {
    public let report: LocalObservationReport?
    public let failure: String?
    public let providerLabel: String

    public init(report: LocalObservationReport?, failure: String?, providerLabel: String) {
        self.report = report
        self.failure = failure
        self.providerLabel = providerLabel
    }
}

public struct ModelHostStatus: Codable, Sendable {
    public let systemModelAvailable: Bool
    public let localRuntimeConfigured: Bool
    public let localModelConfigured: Bool
    public let localServerRunning: Bool
    public let detail: String

    public init(
        systemModelAvailable: Bool,
        localRuntimeConfigured: Bool,
        localModelConfigured: Bool,
        localServerRunning: Bool,
        detail: String
    ) {
        self.systemModelAvailable = systemModelAvailable
        self.localRuntimeConfigured = localRuntimeConfigured
        self.localModelConfigured = localModelConfigured
        self.localServerRunning = localServerRunning
        self.detail = detail
    }
}

@objc public protocol ModelHostXPC: ModelHostObservationXPC {
    func status(withReply reply: @escaping (Data) -> Void)
    func parse(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func unload()
}
