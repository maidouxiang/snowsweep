import Foundation

public enum MoleBridgeError: Error, LocalizedError {
    case executableNotFound
    case versionMismatch(found: String, required: String)
    case commandFailed(status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "未找到 Mole CLI（mo），已切换到内置扫描器"
        case let .versionMismatch(found, required):
            return "Mole 版本 \(found) 不受支持（需要 \(required) 以上），已切换到内置扫描器"
        case let .commandFailed(status, stderr):
            return "Mole 命令失败（退出码 \(status)）：\(stderr)"
        }
    }
}

/// Mole CLI 适配层。上游 JSON 变化只影响这里，不污染领域模型。
public struct MoleBridge: Scanning, Sendable {
    public let executableURL: URL?
    public var sourceLabel: String { "Mole CLI" }
    /// 契约测试所依据的最低版本；低于此版本走内置扫描器。
    public static let minimumSupportedVersion = "1.0.0"

    public init(executableURL: URL? = nil) {
        if let executableURL {
            self.executableURL = executableURL
        } else {
            self.executableURL = Self.lookup()
        }
    }

    private static func lookup() -> URL? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/mo",  // Apple Silicon（本机 M3 Pro）
            "/usr/local/bin/mo",     // Intel
            "\(home)/.local/bin/mo",
            "\(home)/bin/mo"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    public var isAvailable: Bool { executableURL != nil }

    public func version() throws -> String {
        let data = try run(["--version"])
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 执行 `mo <args>` 并返回标准输出。只读命令优先使用 --json。
    @discardableResult
    public func run(_ arguments: [String]) throws -> Data {
        guard let executableURL else { throw MoleBridgeError.executableNotFound }

        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        try task.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MoleBridgeError.commandFailed(status: task.terminationStatus, stderr: message)
        }
        return output
    }

    public func statusJSON() throws -> Data {
        try run(["status", "--json"])
    }

    public func analyzeJSON(path: String? = nil) throws -> Data {
        if let path {
            return try run(["analyze", path, "--json"])
        }
        return try run(["analyze", "--json"])
    }

    /// 清理预览永远带 --dry-run；这是本项目的硬约束。
    public func cleanPreviewJSON() throws -> Data {
        try run(["clean", "--dry-run", "--json"])
    }
}
