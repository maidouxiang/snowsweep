import Foundation
import SnowSweepCore

enum ModelHostFailure: LocalizedError {
    case localNotConfigured
    case localRuntimeMissing(String)
    case localModelMissing(String)
    case localStartFailed(String)
    case localNotReady(String)
    case unknownRoute

    var errorDescription: String? {
        switch self {
        case .localNotConfigured:
            return "本地小模型还没配置；在设置里填 llama-server 路径和 GGUF 权重路径。"
        case let .localRuntimeMissing(path):
            return "找不到可执行的 llama-server：\(path)"
        case let .localModelMissing(path):
            return "找不到 GGUF 权重：\(path)"
        case let .localStartFailed(detail):
            return "本地小模型启动失败：\(detail)"
        case let .localNotReady(detail):
            return "本地小模型没有在限定时间内就绪：\(detail)"
        case .unknownRoute:
            return "模型宿主收到了未知的接入方式。"
        }
    }
}

/// 本地小模型是“可选能力”：权重和 llama-server 由用户提供，宿主只在需要时启动，
/// 空闲一段时间后退出，避免 3B 常驻吃掉内存。
final class Local3BServer: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var port: Int?
    private var idleWorkItem: DispatchWorkItem?
    private let idleSeconds: Int

    init(idleSeconds: Int = 120) {
        self.idleSeconds = idleSeconds
    }

    deinit {
        stop()
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let process else { return false }
        return process.isRunning
    }

    func startIfNeeded(configuration: AssistantProviderConfiguration) async throws {
        let config = configuration.normalized()
        guard let modelPath = config.localModelPath else {
            throw ModelHostFailure.localNotConfigured
        }
        guard let runtimePath = config.localRuntimePath else {
            throw ModelHostFailure.localNotConfigured
        }
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
            throw ModelHostFailure.localRuntimeMissing(runtimePath)
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ModelHostFailure.localModelMissing(modelPath)
        }

        let alreadyRunning = locked {
            if let running = self.process, running.isRunning, self.port == config.localPort { return true }
            return false
        }
        if alreadyRunning {
            touch()
            return
        }
        stop()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtimePath)
        process.arguments = [
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", "\(config.localPort)",
            "-c", "4096",
            "-ngl", "99"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.process === process {
                self.process = nil
                self.port = nil
            }
            self.lock.unlock()
        }

        do {
            try process.run()
        } catch {
            throw ModelHostFailure.localStartFailed(error.localizedDescription)
        }

        locked {
            self.process = process
            self.port = config.localPort
        }

        do {
            try await waitForHealth(port: config.localPort, process: process)
        } catch {
            stop()
            throw error
        }
        touch()
    }

    func touch() {
        lock.lock()
        idleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.stop()
        }
        idleWorkItem = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .seconds(max(1, idleSeconds)),
            execute: item
        )
    }

    func stop() {
        lock.lock()
        idleWorkItem?.cancel()
        idleWorkItem = nil
        let process = self.process
        self.process = nil
        self.port = nil
        lock.unlock()
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func waitForHealth(port: Int, process: Process) async throws {
        let deadline = Date().addingTimeInterval(45)
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        while Date() < deadline {
            guard process.isRunning else {
                throw ModelHostFailure.localStartFailed(
                    "llama-server 已退出（状态 \(process.terminationStatus)）；检查权重路径和端口 \(port)。"
                )
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            if let (_, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw ModelHostFailure.localNotReady("端口 \(port) 被占用，或模型加载超过 45 秒。")
    }
}

final class ReplyBox: @unchecked Sendable {
    let reply: (Data) -> Void
    init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
    func send(_ data: Data) { reply(data) }
}

final class ModelHostService: NSObject, ModelHostXPC, ModelHostObservationXPC, @unchecked Sendable {
    private let local = Local3BServer()
    private let configurationLock = NSLock()
    private var lastLocalConfiguration: AssistantProviderConfiguration?

    private func remember(_ configuration: AssistantProviderConfiguration) {
        configurationLock.lock()
        lastLocalConfiguration = configuration.normalized()
        configurationLock.unlock()
    }

    private func rememberedConfiguration() -> AssistantProviderConfiguration? {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        return lastLocalConfiguration
    }

    func status(withReply reply: @escaping (Data) -> Void) {
        let box = ReplyBox(reply)
        Task { @MainActor in
            let saved = self.rememberedConfiguration()
            let status = ModelHostStatus(
                systemModelAvailable: AssistantModelBridge.isAvailable,
                localRuntimeConfigured: saved?.localRuntimeIsPresent ?? false,
                localModelConfigured: saved?.localModelIsPresent ?? false,
                localServerRunning: self.local.isRunning,
                detail: AssistantModelBridge.isAvailable
                    ? "系统模型可用；本地小模型按需加载"
                    : "系统模型不可用；本地小模型按需加载，规则始终兜底"
            )
            box.send((try? JSONEncoder().encode(status)) ?? Data())
        }
    }

    func parse(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let decoded: ModelHostRequest
        do {
            decoded = try JSONDecoder().decode(ModelHostRequest.self, from: request)
        } catch {
            reply(encode(ModelHostResponse(intent: nil, failure: "模型宿主读不懂这次请求。", providerLabel: "未知")))
            return
        }

        let box = ReplyBox(reply)
        Task {
            let response: ModelHostResponse
            switch decoded.route {
            case .system:
                response = await self.parseSystem(decoded)
            case .openAICompatible:
                response = await self.parseAPI(decoded)
            case .local3B:
                response = await self.parseLocal(decoded)
            }
            box.send(self.encode(response))
        }
    }

    func unload() {
        local.stop()
    }

    func observe(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let decoded: ModelHostObservationRequest
        do {
            decoded = try JSONDecoder().decode(ModelHostObservationRequest.self, from: request)
        } catch {
            reply(encodeObservation(ModelHostObservationResponse(
                report: nil,
                failure: "模型宿主读不懂这次观察请求。",
                providerLabel: "本地观察"
            )))
            return
        }

        let box = ReplyBox(reply)
        Task {
            let response = await self.observeLocal(decoded)
            box.send(self.encodeObservation(response))
        }
    }

    private func observeLocal(_ request: ModelHostObservationRequest) async -> ModelHostObservationResponse {
        guard request.configuration.route == .local3B else {
            return ModelHostObservationResponse(
                report: nil,
                failure: "观察只走本地小模型；远程接口不接收扫描事实。",
                providerLabel: "本地观察"
            )
        }
        let configuration = request.configuration.normalized()
        remember(configuration)
        guard configuration.localIsConfigured else {
            return ModelHostObservationResponse(
                report: nil,
                failure: ModelHostFailure.localNotConfigured.localizedDescription,
                providerLabel: "本地观察"
            )
        }
        do {
            try await local.startIfNeeded(configuration: configuration)
            let localConfiguration = AssistantProviderConfiguration(
                route: .openAICompatible,
                baseURL: "http://127.0.0.1:\(configuration.localPort)/v1",
                model: "local-3b",
                timeoutSeconds: max(30, configuration.timeoutSeconds)
            )
            let report = try await LocalObservationBridge.observe(
                facts: request.facts,
                configuration: localConfiguration,
                apiKey: "local"
            )
            local.touch()
            return ModelHostObservationResponse(report: report, failure: nil, providerLabel: "本地观察")
        } catch {
            local.stop()
            return ModelHostObservationResponse(
                report: nil,
                failure: error.localizedDescription,
                providerLabel: "本地观察"
            )
        }
    }

    private func encodeObservation(_ response: ModelHostObservationResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }

    private func parseSystem(_ request: ModelHostRequest) async -> ModelHostResponse {
        guard await AssistantModelBridge.isAvailable else {
            return ModelHostResponse(intent: nil, failure: "系统模型不可用；这台机器没有可用的 Apple Foundation Models。", providerLabel: "系统模型")
        }
        let intent = await AssistantModelBridge.parse(request.text, fallback: request.fallback)
        guard let intent else {
            return ModelHostResponse(intent: nil, failure: "系统模型没有返回可用结构；这次结果没有采用。", providerLabel: "系统模型")
        }
        return ModelHostResponse(intent: intent, failure: nil, providerLabel: "系统模型")
    }

    private func parseAPI(_ request: ModelHostRequest) async -> ModelHostResponse {
        guard let configuration = request.apiConfiguration?.normalized() else {
            return ModelHostResponse(intent: nil, failure: "API 配置缺失。", providerLabel: "API")
        }
        do {
            let intent = try await AssistantRemoteBridge.parse(
                request.text,
                fallback: request.fallback,
                configuration: configuration,
                apiKey: request.apiKey
            )
            return ModelHostResponse(intent: intent, failure: nil, providerLabel: "API")
        } catch {
            return ModelHostResponse(intent: nil, failure: error.localizedDescription, providerLabel: "API")
        }
    }

    private func parseLocal(_ request: ModelHostRequest) async -> ModelHostResponse {
        guard let configuration = request.apiConfiguration?.normalized() else {
            return ModelHostResponse(intent: nil, failure: ModelHostFailure.localNotConfigured.localizedDescription, providerLabel: "本地小模型")
        }
        remember(configuration)
        do {
            try await local.startIfNeeded(configuration: configuration)
            let localConfiguration = AssistantProviderConfiguration(
                route: .openAICompatible,
                baseURL: "http://127.0.0.1:\(configuration.localPort)/v1",
                model: "local-3b",
                timeoutSeconds: max(20, configuration.timeoutSeconds)
            )
            let intent = try await AssistantRemoteBridge.parse(
                request.text,
                fallback: request.fallback,
                configuration: localConfiguration,
                apiKey: "local",
                origin: .model
            )
            local.touch()
            return ModelHostResponse(intent: intent, failure: nil, providerLabel: "本地小模型")
        } catch {
            local.stop()
            return ModelHostResponse(intent: nil, failure: error.localizedDescription, providerLabel: "本地小模型")
        }
    }

    private func encode(_ response: ModelHostResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }
}

/// 子进程行协议：请求带 id，响应按 id 回传；本地小模型进程仍由这个独立宿主管理。
enum ModelHostStdio {
    static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private final class LineBuffer: @unchecked Sendable {
        var data = Data()
    }

    static func run() {
        let service = ModelHostService()
        let buffer = LineBuffer()
        let queue = DispatchQueue(label: "com.selfuse.xue.modelhost.stdio")
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        source.setEventHandler {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty {
                exit(0)
            }
            buffer.data.append(chunk)
            while let newline = buffer.data.firstIndex(of: 0x0A) {
                let lineData = buffer.data[buffer.data.startIndex..<newline]
                buffer.data.removeSubrange(buffer.data.startIndex...newline)
                guard let line = String(data: Data(lineData), encoding: .utf8), !line.isEmpty else {
                    continue
                }
                handle(line, service: service)
            }
        }
        source.resume()
        dispatchMain()
    }

    private static func handle(_ line: String, service: ModelHostService) {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = envelope["id"] as? String,
              let kind = envelope["kind"] as? String
        else { return }

        if kind == "unload" {
            service.unload()
            write(["id": id, "data": Data().base64EncodedString()])
            return
        }
        if kind == "status" {
            service.status { response in
                write(["id": id, "data": response.base64EncodedString()])
            }
            return
        }
        if kind == "observe" {
            guard let payload = envelope["data"] as? String,
                  let request = Data(base64Encoded: payload)
            else {
                write(["id": id, "error": "模型宿主读不懂这次观察请求。"])
                return
            }
            service.observe(request) { response in
                write(["id": id, "data": response.base64EncodedString()])
            }
            return
        }
        guard let payload = envelope["data"] as? String,
              let request = Data(base64Encoded: payload)
        else {
            write(["id": id, "error": "模型宿主读不懂这次请求。"])
            return
        }
        service.parse(request) { response in
            write(["id": id, "data": response.base64EncodedString()])
        }
    }
}

final class ModelHostDelegate: NSObject, NSXPCListenerDelegate {
    let service = ModelHostService()

    func listener(_ listener: NSXPCListener, didReceiveNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ModelHostXPC.self)
        newConnection.exportedObject = service
        newConnection.resume()
        newConnection.invalidationHandler = { [weak self] in
            self?.service.unload()
        }
        return true
    }
}

if CommandLine.arguments.contains("--stdio") {
    ModelHostStdio.run()
    exit(0)
}

let delegate = ModelHostDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
// NSXPCListener.delegate 是弱引用；顶层 let 在 release 下可能提前释放，
// 用 withExtendedLifetime 把代理和监听器一起保活到进程结束。
withExtendedLifetime((delegate, listener)) {
    dispatchMain()
}
