import Foundation
import SnowSweepCore

// MARK: - Scanner client

final class ScannerProgressRelay: NSObject, ScannerClientXPC {
    private let handler: (ScannerXPCProgress) -> Void

    init(handler: @escaping (ScannerXPCProgress) -> Void) {
        self.handler = handler
    }

    func scannerProgress(_ payload: Data) {
        guard let progress = try? JSONDecoder().decode(ScannerXPCProgress.self, from: payload) else { return }
        handler(progress)
    }
}

enum RemoteScannerError: LocalizedError {
    case serviceUnavailable(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case let .serviceUnavailable(detail): return "扫描服务不可用：\(detail)"
        case let .invalidResponse(detail): return "扫描服务返回了无法读取的结果：\(detail)"
        }
    }
}

/// 主 App 侧的一次扫描连接。调用方在后台线程等待，进度通过 XPC 回调送回。
final class RemoteScannerClient: @unchecked Sendable {
    static let serviceName = SnowIdentity.scannerServiceIdentifier

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var proxy: ScannerServiceXPC?
    private var child: ServiceChildProcess?
    private var finished = false
    private var result: Result<ScannerXPCResponse, Error>?

    func scan(
        request: ScannerXPCRequest,
        onProgress: @escaping @Sendable (ScannerXPCProgress) -> Void
    ) throws -> ScannerXPCResponse {
        // 自签名 App 的 .xpc 服务在 macOS 27 会被 AMFI 拒绝；优先走同协议子进程。
        // 子进程缺失时才尝试 XPC，XPC 也失败后由主扫描回退内置扫描。
        do {
            return try scanInChild(request: request, onProgress: onProgress)
        } catch let error as ChildServiceError {
            if case .missingExecutable = error {
                // 没有 Helper 时保留 XPC 机会；其他启动错误直接交给上层回退。
                return try scanInXPC(request: request, onProgress: onProgress)
            }
            throw error
        }
    }

    private func scanInChild(
        request: ScannerXPCRequest,
        onProgress: @escaping @Sendable (ScannerXPCProgress) -> Void
    ) throws -> ScannerXPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let child = try ServiceChildProcess(executable: ChildServicePaths.url(named: "ScannerService"))
        self.child = child
        child.onLine = { [weak self] text in
            guard let self,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { return }
            let type = object["type"] as? String ?? ""
            if type == "progress" {
                let progress = ScannerXPCProgress(
                    scanned: object["scanned"] as? Int ?? 0,
                    kept: object["kept"] as? Int ?? 0,
                    currentPath: object["currentPath"] as? String ?? ""
                )
                onProgress(progress)
                return
            }
            guard type == "result",
                  let base64 = object["data"] as? String,
                  let data = Data(base64Encoded: base64),
                  let response = try? JSONDecoder().decode(ScannerXPCResponse.self, from: data)
            else {
                self.finish(.failure(RemoteScannerError.invalidResponse("子进程返回不合约")), semaphore: semaphore)
                return
            }
            self.finish(.success(response), semaphore: semaphore)
        }
        child.onExit = { [weak self] reason in
            self?.finish(.failure(RemoteScannerError.serviceUnavailable(reason)), semaphore: semaphore)
        }
        try child.start()
        try child.sendRaw(JSONEncoder().encode(request))
        semaphore.wait()
        lock.lock()
        let final = result
        self.child = nil
        lock.unlock()
        child.stop()
        guard let final else {
            throw RemoteScannerError.serviceUnavailable("子进程没有返回结果")
        }
        switch final {
        case let .success(response): return response
        case let .failure(error): throw error
        }
    }

    private func scanInXPC(
        request: ScannerXPCRequest,
        onProgress: @escaping @Sendable (ScannerXPCProgress) -> Void
    ) throws -> ScannerXPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let connection = NSXPCConnection(serviceName: Self.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ScannerServiceXPC.self)
        connection.exportedInterface = NSXPCInterface(with: ScannerClientXPC.self)
        connection.exportedObject = ScannerProgressRelay(handler: onProgress)
        connection.invalidationHandler = { [weak self] in
            self?.finish(.failure(RemoteScannerError.serviceUnavailable("连接已断开")), semaphore: semaphore)
        }
        connection.interruptionHandler = { [weak self] in
            self?.finish(.failure(RemoteScannerError.serviceUnavailable("服务被中断")), semaphore: semaphore)
        }

        lock.lock()
        self.connection = connection
        lock.unlock()
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.finish(.failure(RemoteScannerError.serviceUnavailable(error.localizedDescription)), semaphore: semaphore)
        }) as? ScannerServiceXPC else {
            connection.invalidate()
            throw RemoteScannerError.serviceUnavailable("拿不到扫描服务代理")
        }

        lock.lock()
        self.proxy = proxy
        lock.unlock()

        let data: Data
        do {
            data = try JSONEncoder().encode(request)
        } catch {
            connection.invalidate()
            throw RemoteScannerError.invalidResponse(error.localizedDescription)
        }

        proxy.scan(data) { [weak self] responseData in
            guard let response = try? JSONDecoder().decode(ScannerXPCResponse.self, from: responseData) else {
                self?.finish(.failure(RemoteScannerError.invalidResponse("返回结构不合约")), semaphore: semaphore)
                return
            }
            self?.finish(.success(response), semaphore: semaphore)
        }

        semaphore.wait()
        lock.lock()
        let final = result
        self.proxy = nil
        self.connection = nil
        lock.unlock()
        connection.invalidate()

        guard let final else {
            throw RemoteScannerError.serviceUnavailable("扫描没有返回结果")
        }
        switch final {
        case let .success(response): return response
        case let .failure(error): throw error
        }
    }

    func cancel() {
        lock.lock()
        let proxy = self.proxy
        let child = self.child
        lock.unlock()
        child?.stop()
        proxy?.cancel()
    }

    private func finish(
        _ value: Result<ScannerXPCResponse, Error>,
        semaphore: DispatchSemaphore
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        result = value
        lock.unlock()
        semaphore.signal()
    }
}

// MARK: - ModelHost client

enum ModelHostClientError: LocalizedError {
    case unavailable(String)
    case invalidResponse
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(detail): return "模型宿主不可用：\(detail)"
        case .invalidResponse: return "模型宿主返回了无法读取的结果。"
        case let .timedOut(detail): return detail
        }
    }
}

/// 模型宿主是长连接：系统模型、API 和本地小模型都在独立进程里解析。
/// 主 App 只传用户原话、固定字段和回退意图，不传路径、文件名或扫描结果。
@MainActor
final class ModelHostClient {
    static let shared = ModelHostClient()
    static let serviceName = SnowIdentity.modelHostIdentifier

    private var connection: NSXPCConnection?
    private var proxy: ModelHostXPC?
    private var child: ServiceChildProcess?
    private var pending: [UUID: CheckedContinuation<ModelHostResponse, Error>] = [:]
    private var pendingStatus: [UUID: CheckedContinuation<ModelHostStatus, Error>] = [:]
    private var pendingObservation: [UUID: CheckedContinuation<ModelHostObservationResponse, Error>] = [:]
    private var watchdogs: [UUID: Task<Void, Never>] = [:]

    private init() {}

    func parse(_ request: ModelHostRequest) async throws -> ModelHostResponse {
        let data = try JSONEncoder().encode(request)
        let envelope: [String: Any] = [
            "kind": "parse",
            "data": data.base64EncodedString()
        ]
        return try await withCheckedThrowingContinuation { continuation in
            let token = UUID()
            pending[token] = continuation
            armWatchdog(token, seconds: 75,
                        message: "本地模型宿主 75 秒内没有回话；这次请求已取消，没有采用任何结果。")
            do {
                var payload = envelope
                payload["id"] = token.uuidString
                try ensureChild().send(payload)
            } catch {
                pending.removeValue(forKey: token)
                finishWatchdog(token)
                continuation.resume(throwing: ModelHostClientError.unavailable(error.localizedDescription))
            }
        }
    }

    func status() async throws -> ModelHostStatus {
        try await withCheckedThrowingContinuation { continuation in
            let token = UUID()
            pendingStatus[token] = continuation
            armWatchdog(token, seconds: 20, message: "模型宿主 20 秒内没有返回状态。")
            do {
                try ensureChild().send([
                    "id": token.uuidString,
                    "kind": "status"
                ])
            } catch {
                pendingStatus.removeValue(forKey: token)
                finishWatchdog(token)
                continuation.resume(throwing: ModelHostClientError.unavailable(error.localizedDescription))
            }
        }
    }

    func observe(_ request: ModelHostObservationRequest) async throws -> ModelHostObservationResponse {
        let data = try JSONEncoder().encode(request)
        let envelope: [String: Any] = [
            "kind": "observe",
            "data": data.base64EncodedString()
        ]
        return try await withCheckedThrowingContinuation { continuation in
            let token = UUID()
            pendingObservation[token] = continuation
            armWatchdog(token, seconds: 90,
                        message: "本地模型 90 秒内没有完成观察；这次观察已取消，模型没有进入清理判断。")
            do {
                var payload = envelope
                payload["id"] = token.uuidString
                try ensureChild().send(payload)
            } catch {
                pendingObservation.removeValue(forKey: token)
                finishWatchdog(token)
                continuation.resume(throwing: ModelHostClientError.unavailable(error.localizedDescription))
            }
        }
    }

    func unload() {
        try? child?.send(["id": UUID().uuidString, "kind": "unload"])
        proxy?.unload()
    }

    private func ensureChild() throws -> ServiceChildProcess {
        if let running = self.child, running.process.isRunning { return running }
        child = nil
        let child = try ServiceChildProcess(executable: ChildServicePaths.url(named: "ModelHost"))
        child.onLine = { [weak self] text in
            Task { @MainActor in self?.handleChildLine(text) }
        }
        child.onExit = { [weak self] reason in
            Task { @MainActor in
                self?.child = nil
                self?.failPending(reason)
            }
        }
        try child.start()
        self.child = child
        return child
    }

    private func handleChildLine(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let idString = object["id"] as? String,
              let token = UUID(uuidString: idString)
        else { return }
        if let error = object["error"] as? String {
            finishWatchdog(token)
            pending.removeValue(forKey: token)?.resume(throwing: ModelHostClientError.unavailable(error))
            pendingStatus.removeValue(forKey: token)?.resume(throwing: ModelHostClientError.unavailable(error))
            pendingObservation.removeValue(forKey: token)?.resume(throwing: ModelHostClientError.unavailable(error))
            return
        }
        guard let base64 = object["data"] as? String,
              let data = Data(base64Encoded: base64)
        else { return }
        if let continuation = pending.removeValue(forKey: token) {
            finishWatchdog(token)
            guard let response = try? JSONDecoder().decode(ModelHostResponse.self, from: data) else {
                continuation.resume(throwing: ModelHostClientError.invalidResponse)
                return
            }
            continuation.resume(returning: response)
            return
        }
        if let continuation = pendingStatus.removeValue(forKey: token) {
            finishWatchdog(token)
            guard let status = try? JSONDecoder().decode(ModelHostStatus.self, from: data) else {
                continuation.resume(throwing: ModelHostClientError.invalidResponse)
                return
            }
            continuation.resume(returning: status)
            return
        }
        if let continuation = pendingObservation.removeValue(forKey: token) {
            finishWatchdog(token)
            guard let observation = try? JSONDecoder().decode(ModelHostObservationResponse.self, from: data) else {
                continuation.resume(throwing: ModelHostClientError.invalidResponse)
                return
            }
            continuation.resume(returning: observation)
        }
    }

    private func armWatchdog(_ token: UUID, seconds: UInt64, message: String) {
        watchdogs[token]?.cancel()
        watchdogs[token] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.expire(token, message: message)
        }
    }

    private func finishWatchdog(_ token: UUID) {
        watchdogs.removeValue(forKey: token)?.cancel()
    }

    private func expire(_ token: UUID, message: String) {
        watchdogs.removeValue(forKey: token)?.cancel()
        let error = ModelHostClientError.timedOut(message)
        pending.removeValue(forKey: token)?.resume(throwing: error)
        pendingStatus.removeValue(forKey: token)?.resume(throwing: error)
        pendingObservation.removeValue(forKey: token)?.resume(throwing: error)
    }

    private func ensureProxy() throws -> ModelHostXPC {
        if let proxy, connection != nil { return proxy }
        let connection = NSXPCConnection(serviceName: Self.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ModelHostXPC.self)
        let invalidated: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.clearConnection() }
        }
        let interrupted: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.failPending("模型宿主连接被中断") }
        }
        connection.invalidationHandler = invalidated
        connection.interruptionHandler = interrupted
        connection.resume()
        let proxyError: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor in self?.failPending(error.localizedDescription) }
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(proxyError) as? ModelHostXPC else {
            connection.invalidate()
            throw ModelHostClientError.unavailable("拿不到模型宿主代理")
        }
        self.connection = connection
        self.proxy = proxy
        return proxy
    }

    private func clearConnection() {
        connection = nil
        proxy = nil
        failPending("模型宿主连接已断开")
    }

    private func failPending(_ message: String) {
        let continuations = pending.values
        let statusContinuations = pendingStatus.values
        let observationContinuations = pendingObservation.values
        pending.removeAll()
        pendingStatus.removeAll()
        pendingObservation.removeAll()
        for task in watchdogs.values { task.cancel() }
        watchdogs.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: ModelHostClientError.unavailable(message))
        }
        for continuation in statusContinuations {
            continuation.resume(throwing: ModelHostClientError.unavailable(message))
        }
        for continuation in observationContinuations {
            continuation.resume(throwing: ModelHostClientError.unavailable(message))
        }
    }
}
