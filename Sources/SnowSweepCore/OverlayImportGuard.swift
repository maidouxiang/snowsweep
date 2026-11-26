import Foundation
import CryptoKit

/// 一次规则叠加层导入的身份记录。内容指纹 + 来源 + 时间，
/// 目的是让"我到底导入了什么、什么时候改过"可追溯，防手滑导入误删规则。
public struct OverlayFingerprint: Codable, Hashable, Sendable {
    public let sha256: String
    public let importedAt: Date
    /// 来源文件名或"手动编辑"。
    public let source: String
    public let ruleCount: Int
    public let protectedPathCount: Int

    public init(
        sha256: String,
        importedAt: Date = Date(),
        source: String,
        ruleCount: Int,
        protectedPathCount: Int
    ) {
        self.sha256 = sha256
        self.importedAt = importedAt
        self.source = source
        self.ruleCount = ruleCount
        self.protectedPathCount = protectedPathCount
    }
}

/// 导入确认级别。首次导入或内容与上次一致时可自动通过；内容变化必须显式确认。
public enum OverlayImportConfirmation: Sendable {
    case automatic
    case userConfirmed
}

public enum OverlayImportGuardError: Error, LocalizedError, Equatable {
    /// 规则内容相对上次的指纹发生变化，但未获用户确认。
    case changeRequiresConfirmation(previous: OverlayFingerprint, current: OverlayFingerprint)
    /// 指纹记录文件损坏，无法安全比对——拒绝继续，提示用户确认后再导入。
    case receiptCorrupted(String)

    public var errorDescription: String? {
        switch self {
        case let .changeRequiresConfirmation(previous, _):
            let time = Self.displayDate(previous.importedAt)
            return "规则内容与上次导入（\(time)，来自「\(previous.source)」）不同，请确认后再次导入"
        case let .receiptCorrupted(reason):
            return "规则导入记录损坏（\(reason)），无法确认变更，请先检查该文件再导入"
        }
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// 持久化"上次导入的指纹"。默认放在 Application Support/雪，
/// 测试可注入临时路径。
public struct OverlayImportReceiptStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            self.fileURL = appSupport
                .appendingPathComponent(SnowIdentity.supportDirectoryName, isDirectory: true)
                .appendingPathComponent("overlay-import.json")
        }
    }

    public func load() throws -> OverlayFingerprint? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode(OverlayFingerprint.self, from: data)
        } catch {
            throw OverlayImportGuardError.receiptCorrupted(error.localizedDescription)
        }
    }

    public func save(_ fingerprint: OverlayFingerprint) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(fingerprint)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

/// 规则导入的指纹守卫。不替代 `RuleBookMigrator` 的格式/安全校验，
/// 而是在校验通过后增加"内容是否变化、是否获确认"这一层。
public enum OverlayImportGuard: Sendable {
    /// 用规范 JSON（排序键）计算内容指纹，避免纯排版差异被当成规则变更。
    public static func fingerprint(of overlay: UserRuleOverlay) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(overlay)
        let digest = SHA256.hash(data: canonical)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// 校验 + 指纹比对 + 记录。成功返回可用叠加层；内容变化且未确认则拒绝。
    @discardableResult
    public static func importOverlay(
        jsonData: Data,
        source: String,
        confirmation: OverlayImportConfirmation,
        store: OverlayImportReceiptStore
    ) throws -> UserRuleOverlay {
        // 先做原有格式与安全校验，坏的叠加层根本不进入指纹流程。
        let overlay = try RuleBookMigrator.importOverlay(jsonData: jsonData)
        let current = OverlayFingerprint(
            sha256: try fingerprint(of: overlay),
            source: source,
            ruleCount: overlay.rules.count,
            protectedPathCount: overlay.protectedPaths.count
        )

        if let previous = try store.load(), previous.sha256 != current.sha256,
           confirmation != .userConfirmed {
            throw OverlayImportGuardError.changeRequiresConfirmation(
                previous: previous, current: current
            )
        }

        // 首导、内容一致、或用户已确认：写入新指纹（含新来源与当前时间）。
        try store.save(current)
        return overlay
    }
}
