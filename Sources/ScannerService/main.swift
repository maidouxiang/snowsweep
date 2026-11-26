import Foundation
import SnowSweepCore

/// 主 App 的进度回调。XPC 服务只回传计数和当前路径，不回传文件内容。
final class ScannerClientProxy: NSObject, ScannerClientXPC {
    private let handler: (ScannerXPCProgress) -> Void

    init(handler: @escaping (ScannerXPCProgress) -> Void) {
        self.handler = handler
    }

    func scannerProgress(_ payload: Data) {
        guard let progress = try? JSONDecoder().decode(ScannerXPCProgress.self, from: payload) else {
            return
        }
        handler(progress)
    }
}

/// XPC 的 reply 回调由 Objective-C 运行时注入，本身没有 Sendable 标注。
/// 只在这里包一层，保证回调仍然只执行一次，不把整条 XPC 接口改成非安全并发。
private final class ScannerReplyBox: @unchecked Sendable {
    let send: (Data) -> Void

    init(_ send: @escaping (Data) -> Void) {
        self.send = send
    }
}

/// 扫描服务只做只读扫描。规则判定仍在主 App 的 RuleEngine 里完成；
/// 服务传回候选和缺口，不接触删除、审计或用户文件内容。
final class ScannerService: NSObject, ScannerServiceXPC, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var replySent = false
    private var lastProgressSent = 0.0
    private var client: ScannerClientXPC?

    func attach(client: ScannerClientXPC?) {
        self.client = client
    }

    func scan(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        lock.lock()
        cancelled = false
        replySent = false
        lastProgressSent = 0
        lock.unlock()

        let replyBox = ScannerReplyBox(reply)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let response: ScannerXPCResponse
            do {
                let decoded = try JSONDecoder().decode(ScannerXPCRequest.self, from: request)
                response = self.run(decoded)
            } catch {
                response = ScannerXPCResponse(
                    summary: ScanStreamSummary(scanned: 0, kept: 0),
                    failure: "扫描服务读不懂这次请求：\(error.localizedDescription)"
                )
            }
            let data = (try? JSONEncoder().encode(response)) ?? Data()
            self.lock.lock()
            guard !self.replySent else {
                self.lock.unlock()
                return
            }
            self.replySent = true
            self.lock.unlock()
            replyBox.send(data)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private func run(_ request: ScannerXPCRequest) -> ScannerXPCResponse {
        do {
            let engine = try RuleEngine(
                ruleBook: request.ruleBook,
                customProtectedPaths: request.extraProtectedPaths
            )
            let collector = ScanPayloadCollector(maxItems: 10_000)
            let scanner = RuleRootScanner(
                engine: engine,
                home: request.home,
                maxItemsPerRoot: request.maxItemsPerRoot,
                maxConcurrentRoots: request.maxConcurrentRoots,
                overallTimeout: request.overallTimeoutSeconds.map(TimeInterval.init),
                cancellationCheck: { [weak self] in
                    guard let self else { return true }
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    return self.cancelled
                }
            )

            if let seconds = request.cancelAfterSeconds, seconds > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
                    self?.cancel()
                }
            }

            let summary = try scanner.streamAnalyze(
                scope: request.scope,
                onProgress: { [weak self] progress in
                    guard let self else { return false }
                    self.lock.lock()
                    let isCancelled = self.cancelled
                    self.lock.unlock()
                    if isCancelled { return false }
                    self.sendProgress(progress)
                    return true
                },
                sink: collector
            )
            let payload = collector.payload
            sendProgress(
                ScanProgress(
                    scanned: summary.scanned,
                    kept: summary.kept,
                    currentPath: ""
                )
            )
            return ScannerXPCResponse(
                items: payload.items,
                gaps: payload.gaps,
                summary: summary,
                failure: nil
            )
        } catch {
            return ScannerXPCResponse(
                summary: ScanStreamSummary(scanned: 0, kept: 0),
                failure: "扫描服务启动失败：\(error.localizedDescription)"
            )
        }
    }

    private func sendProgress(_ progress: ScanProgress) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let shouldSend = now - lastProgressSent >= 0.20 || progress.currentPath.isEmpty
        if shouldSend { lastProgressSent = now }
        let client = self.client
        lock.unlock()
        guard shouldSend, let client else { return }
        let payload = ScannerXPCProgress(
            scanned: progress.scanned,
            kept: progress.kept,
            currentPath: progress.currentPath
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        client.scannerProgress(data)
    }
}

/// 子进程行协议：App 通过 stdin 发一行请求，服务把进度和最终结果各写一行 JSON 到 stdout。
/// 这是无有效 Apple 开发证书时仍能把扫描峰值放进独立进程的传输方式，协议载荷与 XPC 完全相同。
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func set() { lock.lock(); cancelled = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum ScannerStdio {
    static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            do {
                let request = try JSONDecoder().decode(ScannerXPCRequest.self, from: data)
                let engine = try RuleEngine(
                    ruleBook: request.ruleBook,
                    customProtectedPaths: request.extraProtectedPaths
                )
                let collector = ScanPayloadCollector(maxItems: 10_000)
                let flag = CancelFlag()
                if let seconds = request.cancelAfterSeconds, seconds > 0 {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(max(1, seconds))) {
                        flag.set()
                    }
                }
                let scanner = RuleRootScanner(
                    engine: engine,
                    home: request.home,
                    maxItemsPerRoot: request.maxItemsPerRoot,
                    maxConcurrentRoots: request.maxConcurrentRoots,
                    overallTimeout: request.overallTimeoutSeconds.map(TimeInterval.init),
                    cancellationCheck: { flag.isSet }
                )
                let summary = try scanner.streamAnalyze(
                    scope: request.scope,
                    onProgress: { progress in
                        write([
                            "type": "progress",
                            "scanned": progress.scanned,
                            "kept": progress.kept,
                            "currentPath": progress.currentPath
                        ])
                        return true
                    },
                    sink: collector
                )
                let payload = collector.payload
                let response = ScannerXPCResponse(
                    items: payload.items,
                    gaps: payload.gaps,
                    summary: summary,
                    failure: nil
                )
                let encoded = try JSONEncoder().encode(response)
                write(["type": "result", "data": encoded.base64EncodedString()])
            } catch {
                let response = ScannerXPCResponse(
                    summary: ScanStreamSummary(scanned: 0, kept: 0),
                    failure: "扫描服务启动失败：\(error.localizedDescription)"
                )
                if let encoded = try? JSONEncoder().encode(response) {
                    write(["type": "result", "data": encoded.base64EncodedString()])
                }
            }
        }
    }
}

final class ScannerServiceDelegate: NSObject, NSXPCListenerDelegate {
    let service = ScannerService()

    func listener(_ listener: NSXPCListener, didReceiveNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ScannerServiceXPC.self)
        newConnection.exportedObject = service
        newConnection.remoteObjectInterface = NSXPCInterface(with: ScannerClientXPC.self)
        newConnection.resume()
        if let proxy = newConnection.remoteObjectProxy as? ScannerClientXPC {
            service.attach(client: proxy)
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.service.attach(client: nil)
        }
        return true
    }
}

if CommandLine.arguments.contains("--stdio") {
    ScannerStdio.run()
    exit(0)
}

let delegate = ScannerServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
// NSXPCListener.delegate 是弱引用；顶层 let 在 release 下可能提前释放，
// 用 withExtendedLifetime 把代理和监听器一起保活到进程结束。
withExtendedLifetime((delegate, listener)) {
    dispatchMain()
}
