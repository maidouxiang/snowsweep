import Foundation
import CryptoKit

/// 审计动作。所有清理相关操作（包括失败）都必须留痕。
public enum AuditAction: String, Codable, Sendable, CaseIterable {
    case dryRun
    case moveToTrash
    case moveToTrashFailed
    case skippedAfterTrashFailure
    case movedToBackup
    case backupFailed
    case permanentDelete
    case permanentDeleteFailed
    case policyRejected
    case protectionChanged
    case targetRejected

    public var chineseLabel: String {
        switch self {
        case .dryRun: return "预览"
        case .moveToTrash: return "移到废纸篓"
        case .moveToTrashFailed: return "移废纸篓失败"
        case .skippedAfterTrashFailure: return "失败后跳过"
        case .movedToBackup: return "移入备份"
        case .backupFailed: return "备份失败"
        case .permanentDelete: return "永久删除"
        case .permanentDeleteFailed: return "永久删除失败"
        case .policyRejected: return "策略拒绝"
        case .protectionChanged: return "保护清单变更"
        case .targetRejected: return "身份复核拒绝"
        }
    }

    /// 属于一次清理批次的动作。预览与成功/失败/跳过都算同一条清理链路。
    public var isCleanupAction: Bool {
        switch self {
        case .dryRun, .moveToTrash, .moveToTrashFailed, .skippedAfterTrashFailure,
             .movedToBackup, .permanentDelete, .permanentDeleteFailed:
            return true
        default:
            return false
        }
    }
}

/// 单条 JSONL 审计记录。sha256 覆盖除自身外的全部字段 + 前一条哈希，
/// 目的是发现"无意篡改"（编辑日志后发现链断了），不是防恶意攻击者。
public struct AuditEvent: Codable, Hashable, Sendable {
    public let id: UUID
    public let at: Date
    public let action: AuditAction
    public let path: String
    public let ruleID: String?
    public let sizeBytes: Int64
    public let success: Bool
    public let detail: String
    public let previousHash: String
    public let sha256: String

    public init(
        id: UUID = UUID(),
        at: Date = Date(),
        action: AuditAction,
        path: String,
        ruleID: String? = nil,
        sizeBytes: Int64 = 0,
        success: Bool,
        detail: String = "",
        previousHash: String = "genesis"
    ) {
        self.id = id
        self.at = at
        self.action = action
        self.path = path
        self.ruleID = ruleID
        self.sizeBytes = sizeBytes
        self.success = success
        self.detail = detail
        self.previousHash = previousHash
        self.sha256 = Self.digest(
            id: id, at: at, action: action, path: path, ruleID: ruleID,
            sizeBytes: sizeBytes, success: success, detail: detail, previousHash: previousHash
        )
    }

    /// 用固定分隔符拼接规范串，避免 JSON 键顺序影响哈希。
    public static func digest(
        id: UUID,
        at: Date,
        action: AuditAction,
        path: String,
        ruleID: String?,
        sizeBytes: Int64,
        success: Bool,
        detail: String,
        previousHash: String
    ) -> String {
        var fields = [
            id.uuidString,
            at.ISO8601Format(),
            action.rawValue,
            path,
            ruleID ?? "",
            String(sizeBytes),
            success ? "1" : "0",
            detail,
            previousHash
        ]
        // 路径或说明里出现分隔符时用转义保证唯一解码，避免构造碰撞。
        fields = fields.map { $0.replacingOccurrences(of: "\u{1f}", with: "\u{1f}1e") }
        let canonical = fields.joined(separator: "\u{1f}")
        let hash = SHA256.hash(data: Data(canonical.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    public var isHashValid: Bool {
        sha256 == Self.digest(
            id: id, at: at, action: action, path: path, ruleID: ruleID,
            sizeBytes: sizeBytes, success: success, detail: detail, previousHash: previousHash
        )
    }

    /// 批次标识写在 detail 末尾的 `[batch:…]`，这样不改变既有哈希字段与旧日志兼容性。
    public var batchID: String? {
        guard let start = detail.range(of: "[batch:"),
              let end = detail.range(of: "]", range: start.upperBound..<detail.endIndex) else {
            return nil
        }
        let value = detail[start.upperBound..<end.lowerBound]
        return value.isEmpty ? nil : String(value)
    }

    /// 废纸篓或备份目录里被移动后的精确位置。
    /// 以 `[result:<百分号编码路径>]` 写在 detail 里，避免改动既有哈希字段，
    /// 因而旧日志仍然能通过链校验。
    public var resultingItemURL: String? {
        guard let encoded = Self.tokenValue(in: detail, prefix: "[result:"),
              let decoded = encoded.removingPercentEncoding else { return nil }
        return decoded.isEmpty ? nil : decoded
    }

    public static func resultToken(for path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "[result:\(encoded)]"
    }

    /// 给界面展示的说明：去掉内部批次与结果位置标记，不把协议细节暴露给用户。
    public var displayDetail: String {
        var text = detail
        for prefix in ["[batch:", "[result:"] {
            while let start = text.range(of: prefix),
                  let end = text.range(of: "]", range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenValue(in text: String, prefix: String) -> String? {
        guard let start = text.range(of: prefix),
              let end = text.range(of: "]", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        let value = text[start.upperBound..<end.lowerBound]
        return value.isEmpty ? nil : String(value)
    }
}

public struct AuditVerification: Sendable, Equatable {
    public let lineCount: Int
    public let brokenLines: [Int]
    public let chainBrokenAt: [Int]

    public var isValid: Bool { brokenLines.isEmpty && chainBrokenAt.isEmpty }
}

/// 追加写 JSONL 审计日志，并在每条记录里写入 SHA256 与前一条哈希。
public struct AuditLog: Sendable {
    public let fileURL: URL
    private let encoder: JSONEncoder

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            self.fileURL = appSupport
                .appendingPathComponent(SnowIdentity.supportDirectoryName, isDirectory: true)
                .appendingPathComponent("audit.jsonl")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    private func lastHash() throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return "genesis" }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return text.split(separator: "\n").last.flatMap { line in
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(AuditEvent.self, from: data) else { return nil }
            return event.sha256
        } ?? "genesis"
    }

    @discardableResult
    public func append(
        action: AuditAction,
        path: String,
        ruleID: String? = nil,
        sizeBytes: Int64 = 0,
        success: Bool,
        detail: String = "",
        batchID: String? = nil,
        resultingItemURL: String? = nil,
        at: Date = Date()
    ) throws -> AuditEvent {
        var taggedDetail = detail
        if let resultingItemURL, !resultingItemURL.isEmpty {
            taggedDetail += taggedDetail.isEmpty ? AuditEvent.resultToken(for: resultingItemURL)
                                                : " \(AuditEvent.resultToken(for: resultingItemURL))"
        }
        if let batchID, !batchID.isEmpty {
            taggedDetail += taggedDetail.isEmpty ? "[batch:\(batchID)]" : " [batch:\(batchID)]"
        }
        let event = AuditEvent(
            at: at,
            action: action,
            path: path,
            ruleID: ruleID,
            sizeBytes: sizeBytes,
            success: success,
            detail: taggedDetail,
            previousHash: try lastHash()
        )
        try prepareFile()
        var line = try encoder.encode(event)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        return event
    }

    public func events() throws -> [AuditEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AuditEvent.self, from: data)
        }
    }

    public func verify() throws -> AuditVerification {
        let records = try events()
        var broken: [Int] = []
        var chain: [Int] = []
        var previous = "genesis"
        for (index, event) in records.enumerated() {
            let line = index + 1
            if !event.isHashValid { broken.append(line) }
            if event.previousHash != previous { chain.append(line) }
            previous = event.sha256
        }
        return AuditVerification(lineCount: records.count, brokenLines: broken, chainBrokenAt: chain)
    }

    private func prepareFile() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }
}
