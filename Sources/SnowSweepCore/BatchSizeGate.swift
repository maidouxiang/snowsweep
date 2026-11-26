import Foundation

/// 单批次规模的上限。超过任一上限，必须让用户单独确认后才能执行。
/// 取 200 项 / 5GB：小批量清理几乎不会碰到，真正碰到时值得多看一眼。
public struct BatchSizeLimits: Sendable, Equatable {
    public let maxItems: Int
    public let maxBytes: Int64

    public init(maxItems: Int = 200, maxBytes: Int64 = 5 * 1024 * 1024 * 1024) {
        self.maxItems = max(1, maxItems)
        self.maxBytes = max(0, maxBytes)
    }

    public static let `default` = BatchSizeLimits()
}

/// 闸门结论。需要确认时携带全部原因，方便界面一次说清楚"为什么"。
public enum BatchGateDecision: Sendable, Equatable {
    case allowed
    case requiresConfirmation(reasons: [String])

    public var requiresConfirmation: Bool {
        if case .requiresConfirmation = self { return true }
        return false
    }

    public var reasons: [String] {
        if case let .requiresConfirmation(reasons) = self { return reasons }
        return []
    }

    /// 唯一的放行条件：未超限，或超限且用户已显式确认。
    public func allows(acknowledged: Bool) -> Bool {
        switch self {
        case .allowed: return true
        case .requiresConfirmation: return acknowledged
        }
    }
}

/// 纯函数闸门：只根据条数与字节数判断，不触碰文件、不依赖 UI。
/// 它是一道"额外"限制，绝不替代 `report.canClean`、`CleanupSelection` 与删除前复核。
public enum BatchSizeGate: Sendable {
    public static func check(
        count: Int,
        bytes: Int64,
        limits: BatchSizeLimits = .default
    ) -> BatchGateDecision {
        var reasons: [String] = []
        if count > limits.maxItems {
            reasons.append("本次共 \(count) 项，超过 \(limits.maxItems) 项的上限")
        }
        if bytes > limits.maxBytes {
            let limit = ByteCountFormatter.string(fromByteCount: limits.maxBytes, countStyle: .file)
            let actual = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            reasons.append("预计释放 \(actual)，超过 \(limit) 的上限")
        }
        return reasons.isEmpty ? .allowed : .requiresConfirmation(reasons: reasons)
    }

    public static func check(_ entries: [CleanupSelection.Entry], limits: BatchSizeLimits = .default) -> BatchGateDecision {
        let summary = CleanupSelection.summary(entries)
        return check(count: summary.count, bytes: summary.bytes, limits: limits)
    }
}
