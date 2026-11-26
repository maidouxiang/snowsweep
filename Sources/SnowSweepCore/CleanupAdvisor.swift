import Foundation

/// 清理建议三档。只决定“建议选中哪些”，不直接删除；用户仍要预览、二次确认。
public enum CleanupAdviceLevel: String, CaseIterable, Identifiable, Sendable {
    case conservative
    case normal
    case aggressive

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .conservative: return "保守"
        case .normal: return "正常"
        case .aggressive: return "激进"
        }
    }

    public var subtitle: String {
        switch self {
        case .conservative: return "只动系统明确标安全的缓存和日志，不碰需确认项。"
        case .normal: return "在安全项之外，加上可重建的缓存、浏览器和开发缓存。"
        case .aggressive: return "连需确认项一起列进来；旧安装包、废纸篓和其他项也会出现。"
        }
    }
}

/// 把扫描结果翻译成三档可执行建议。纯函数，方便测试和 UI 预览共用。
public enum CleanupAdvisor {
    public struct Advice: Sendable {
        public let level: CleanupAdviceLevel
        public let verdicts: [Verdict]
        public let count: Int
        public let bytes: Int64
    }

    /// 正常档只多放“删了会自动重建”的组；安装包、废纸篓、其他项留给激进档。
    private static let normalReviewGroups: Set<CleanupGroup> = [
        .systemCache, .logs, .browser, .developer
    ]

    public static func advice(from report: ScanReport, level: CleanupAdviceLevel) -> Advice {
        guard report.canClean else {
            return Advice(level: level, verdicts: [], count: 0, bytes: 0)
        }

        let verdicts = report.verdicts.filter { verdict in
            switch level {
            case .conservative:
                return verdict.risk == .safe && !verdict.needConfirm
            case .normal:
                if verdict.risk == .safe && !verdict.needConfirm { return true }
                return verdict.risk == .review && normalReviewGroups.contains(verdict.cleanupGroup)
            case .aggressive:
                if verdict.risk == .safe && !verdict.needConfirm { return true }
                return verdict.risk == .review
            }
        }
        .sorted { $0.item.sizeBytes > $1.item.sizeBytes }

        let bytes = verdicts.reduce(Int64(0)) { $0 + $1.item.sizeBytes }
        return Advice(level: level, verdicts: verdicts, count: verdicts.count, bytes: bytes)
    }
}
