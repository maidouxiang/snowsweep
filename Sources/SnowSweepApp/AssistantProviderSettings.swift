import Foundation
import SnowSweepCore

/// 推荐给雪的本地观测模型：Qwen3-4B-Instruct-2507 Q4_K_M，约 2.4 GB。
/// 权重优先用应用支持目录里的副本，避免每次加载都触发“可移除磁盘”系统授权；
/// 没有副本时才回退到用户外置盘的原文件。运行时借用 LM Studio 的 llama-server，不随 App 分发权重。
enum LocalModelPreset {
    static let internalModelPath = ("~/Library/Application Support/雪/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf" as NSString)
        .expandingTildeInPath
    static let externalModelPath = "/Volumes/Crucial X6/AI/models/lmstudio-community/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"

    /// 内部副本优先；内部没有才用外置盘，保证旧配置仍能工作。
    static var modelPath: String {
        if FileManager.default.fileExists(atPath: internalModelPath) {
            return internalModelPath
        }
        return externalModelPath
    }

    static func llamaServerPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let backendsRoot = ("~/.lmstudio/extensions/backends" as NSString).expandingTildeInPath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: backendsRoot) else {
            return nil
        }
        let sorted = names
            .filter { $0.hasPrefix("llama.cpp") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        for name in sorted {
            let path = (backendsRoot as NSString)
                .appendingPathComponent(name)
                .appending("/llama-server")
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static var isReady: Bool {
        FileManager.default.fileExists(atPath: modelPath)
            && llamaServerPath() != nil
    }
}

/// 一次连接测试或真实请求的结果；只在当前进程内有效，不把旧结果伪装成当前可用。
enum AssistantProviderConnectionState {
    case untested
    case verified
    case failed
}

/// 模型接入偏好：配置写 UserDefaults，API Key 只写钥匙串。
/// 导入导出不包含这个对象；换机后需要重新填地址与 Key。
@MainActor
final class AssistantProviderSettings: ObservableObject {
    static let shared = AssistantProviderSettings()

    @Published var route: AssistantProviderRoute {
        didSet { persist() }
    }
    @Published var baseURL: String {
        didSet { persist() }
    }
    @Published var model: String {
        didSet { persist() }
    }
    @Published var timeoutSeconds: Int {
        didSet { persist() }
    }
    @Published var localModelPath: String {
        didSet { persist() }
    }
    @Published var localRuntimePath: String {
        didSet { persist() }
    }
    @Published var localPort: Int {
        didSet { persist() }
    }
    @Published var apiKeyDraft = ""
    @Published private(set) var hasStoredKey = false
    @Published private(set) var statusText = "API Key 未保存"
    @Published private(set) var statusIsError = false
    @Published private(set) var isTesting = false
    @Published private(set) var connectionState: AssistantProviderConnectionState = .untested
    @Published private(set) var lastFailureText: String?

    private let keychain = AssistantKeychain()

    private init() {
        let saved = Self.load()
        self.route = saved.route
        self.baseURL = saved.baseURL
        self.model = saved.model
        self.timeoutSeconds = saved.timeoutSeconds
        let savedModel = saved.localModelPath ?? ""
        // 旧配置指向可移除磁盘时，自动换成应用支持目录里的同尺寸副本，
        // 免去每次启动都弹“访问可移除磁盘”的系统授权。
        if savedModel == LocalModelPreset.externalModelPath,
           FileManager.default.fileExists(atPath: LocalModelPreset.internalModelPath) {
            self.localModelPath = LocalModelPreset.internalModelPath
        } else {
            self.localModelPath = savedModel
        }
        self.localRuntimePath = saved.localRuntimePath ?? ""
        self.localPort = saved.localPort
        self.hasStoredKey = keychain.hasValue
        self.statusText = hasStoredKey ? "API Key 已保存在钥匙串" : "API Key 未保存"
    }

    var configuration: AssistantProviderConfiguration {
        AssistantProviderConfiguration(
            route: route,
            baseURL: baseURL,
            model: model,
            timeoutSeconds: timeoutSeconds,
            localModelPath: localModelPath.isEmpty ? nil : localModelPath,
            localRuntimePath: localRuntimePath.isEmpty ? nil : localRuntimePath,
            localPort: localPort
        ).normalized()
    }

    var isRemoteReady: Bool {
        configuration.remoteIsConfigured && hasStoredKey
    }

    var availabilityShort: String {
        switch route {
        case .rulesOnly:
            return "规则解析可用"
        case .system:
            return AssistantModelBridge.isAvailable ? "系统模型可用" : "系统模型不可用，规则兜底"
        case .local3B:
            guard configuration.localIsConfigured else { return "本地小模型未配置" }
            switch connectionState {
            case .verified: return "本地小模型已验证"
            case .failed: return "本地小模型连接失败"
            case .untested: return "本地小模型已配置，未验证"
            }
        case .openAICompatible:
            guard isRemoteReady else { return "API 未配置完整" }
            switch connectionState {
            case .verified:
                return "API 已验证"
            case .failed:
                return "API 连接失败"
            case .untested:
                return "API 已配置，未验证"
            }
        }
    }

    func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusText = "先填入 API Key，再保存。"
            statusIsError = true
            return
        }
        do {
            try keychain.save(trimmed)
            apiKeyDraft = ""
            hasStoredKey = true
            connectionState = .untested
            lastFailureText = nil
            statusText = "API Key 已保存到钥匙串；不会写入偏好或导入导出。"
            statusIsError = false
        } catch {
            hasStoredKey = keychain.hasValue
            statusText = error.localizedDescription
            statusIsError = true
        }
    }

    func clearAPIKey() {
        keychain.delete()
        apiKeyDraft = ""
        hasStoredKey = false
        connectionState = .untested
        lastFailureText = nil
        statusText = "API Key 已从钥匙串清除。"
        statusIsError = false
    }

    func noteRequestSuccess() {
        connectionState = .verified
        lastFailureText = nil
    }

    func noteRequestFailure(_ message: String) {
        connectionState = .failed
        lastFailureText = message
        statusText = message
        statusIsError = true
    }

    func applyLocalObservationPreset() {
        route = .local3B
        localModelPath = LocalModelPreset.modelPath
        if let runtime = LocalModelPreset.llamaServerPath() {
            localRuntimePath = runtime
        }
        localPort = 19_191
        timeoutSeconds = 30
        connectionState = .untested
        lastFailureText = nil
        if FileManager.default.fileExists(atPath: LocalModelPreset.modelPath),
           !localRuntimePath.isEmpty,
           FileManager.default.isExecutableFile(atPath: localRuntimePath) {
            statusText = "已填入 Qwen3-4B 观测预设；权重优先读应用支持目录，首次观察会加载约 2.4 GB。"
            statusIsError = false
        } else {
            statusText = "预设已填入，但权重或 llama-server 还没找到；把 2.4 GB GGUF 放到应用支持目录或外置盘。"
            statusIsError = true
        }
    }

    func testConnection() {
        guard route != .rulesOnly else {
            statusText = "仅本地规则不需要测试模型连接。"
            statusIsError = false
            return
        }
        let config = configuration
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = key.isEmpty ? keychain.read() : key
        if route == .openAICompatible {
            guard config.remoteIsConfigured else {
                statusText = "接口地址或模型名不完整；地址要 HTTPS，模型名不能带空格。"
                statusIsError = true
                return
            }
            guard let stored, !stored.isEmpty else {
                statusText = "先填入并保存 API Key，再测试。"
                statusIsError = true
                return
            }
        }
        if route == .local3B, !config.localIsConfigured {
            statusText = config.localModelIsPresent && config.localRuntimeIsPresent
                ? "本地小模型配置不完整；检查两个路径是否存在。"
                : "本地小模型未配置完整；需要 llama-server 路径和 GGUF 权重。"
            statusIsError = true
            return
        }

        isTesting = true
        statusIsError = false
        statusText = "正在请求模型宿主；只发一句测试话，不发路径或扫描结果。"
        Task {
            let probe = "清一下应用缓存，先告诉我能清多少"
            let request = ModelHostRequest(
                text: probe,
                fallback: AssistantIntentParser.parse(probe),
                route: ModelHostRoute(providerRoute: route),
                apiConfiguration: config,
                apiKey: route == .openAICompatible ? stored : nil,
                localModelPath: config.localModelPath,
                localRuntimePath: config.localRuntimePath,
                localPort: config.localPort
            )
            do {
                let response = try await ModelHostClient.shared.parse(request)
                if let intent = response.intent {
                    noteRequestSuccess()
                    statusText = "连接正常：\(response.providerLabel) · \(intent.interpretation)"
                    statusIsError = false
                } else {
                    let message = response.failure ?? "模型宿主没有返回可用结构。"
                    noteRequestFailure(message)
                    statusText = message
                    statusIsError = true
                }
            } catch {
                noteRequestFailure(error.localizedDescription)
                statusText = error.localizedDescription
                statusIsError = true
            }
            isTesting = false
        }
    }

    func keyForRequest() -> String? {
        let draft = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty { return draft }
        return keychain.read()
    }

    private func persist() {
        let config = configuration
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: AssistantProviderConfiguration.storageKey)
    }

    private static func load() -> AssistantProviderConfiguration {
        guard let data = UserDefaults.standard.data(forKey: AssistantProviderConfiguration.storageKey),
              let decoded = try? JSONDecoder().decode(AssistantProviderConfiguration.self, from: data)
        else { return .default }
        return decoded.normalized()
    }
}
