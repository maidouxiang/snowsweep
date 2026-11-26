import Foundation
import SnowSweepCore

enum ChildServiceError: LocalizedError {
    case missingExecutable(String)
    case launchFailed(String)
    case exited(String)

    var errorDescription: String? {
        switch self {
        case let .missingExecutable(name):
            return "App 包里缺少 \(name) 可执行文件。"
        case let .launchFailed(detail):
            return "\(detail)"
        case let .exited(detail):
            return detail
        }
    }
}

/// 子进程行协议。App 与 ScannerService / ModelHost 之间仍然只传 JSON，
/// 但传输从 XPC 换成 stdin/stdout；在没有有效 Apple 开发证书、XPC 服务被 AMFI 拒绝时，
/// 扫描和模型依旧各自在独立进程里跑，峰值不回到主进程。
final class ServiceChildProcess: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writeQueue = DispatchQueue(label: "com.selfuse.xue.child.write")
    private let stateLock = NSLock()
    private var buffer = Data()
    private var exited = false
    private var stopped = false

    var onLine: (@Sendable (String) -> Void)?
    var onExit: (@Sendable (String) -> Void)?

    init(executable: URL, arguments: [String] = ["--stdio"]) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ChildServiceError.missingExecutable(executable.lastPathComponent)
        }
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                self?.handleEOF()
                return
            }
            self?.consume(data)
        }
        process.terminationHandler = { [weak self] process in
            let reason = process.terminationReason == .uncaughtSignal
                ? "子进程被信号 \(process.terminationStatus) 结束"
                : "子进程退出，状态 \(process.terminationStatus)"
            self?.handleEOF(reason: reason)
        }
        do {
            try process.run()
        } catch {
            throw ChildServiceError.launchFailed(error.localizedDescription)
        }
    }

    func send(_ object: [String: Any]) throws {
        try sendRaw(JSONSerialization.data(withJSONObject: object))
    }

    func sendRaw(_ data: Data) throws {
        writeQueue.sync {
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0A]))
        }
    }

    func stop() {
        stateLock.lock()
        if stopped || exited {
            stateLock.unlock()
            return
        }
        stopped = true
        stateLock.unlock()
        if process.isRunning {
            process.terminate()
        }
    }

    private func consume(_ data: Data) {
        stateLock.lock()
        buffer.append(data)
        var complete: [Data] = []
        // 只消费真正以换行结尾的完整行；结果 JSON 可能有几十 KB，
        // 不能把管道分段当成一整行提前回调。
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { complete.append(line) }
        }
        stateLock.unlock()

        for line in complete {
            guard let text = String(data: line, encoding: .utf8) else { continue }
            onLine?(text)
        }
    }

    private func handleEOF(reason: String? = nil) {
        stateLock.lock()
        guard !exited else { stateLock.unlock(); return }
        exited = true
        let wasStopped = stopped
        stateLock.unlock()
        onExit?(wasStopped ? "已取消扫描" : (reason ?? "服务进程已结束"))
    }
}

enum ChildServicePaths {
    static func url(named name: String) throws -> URL {
        let bundle = Bundle.main.bundleURL
        let candidates = [
            bundle.appendingPathComponent("Contents/Helpers/\(name).app/Contents/MacOS/\(name)"),
            bundle.appendingPathComponent("Contents/Helpers/\(name)"),
            bundle.appendingPathComponent("Contents/XPCServices/\(name).xpc/Contents/MacOS/\(name)")
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw ChildServiceError.missingExecutable(name)
    }
}
