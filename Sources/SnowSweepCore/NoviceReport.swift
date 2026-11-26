import Foundation

/// 新手报告的一个空间条目。只提供“这是什么、占多少、风险如何”，
/// 不携带删除动作；真正的清理仍走首屏决策单和废纸篓。
public struct NoviceSpaceItem: Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let bytes: Int64
    public let category: String
    public let risk: String
    public let isPersonal: Bool

    public var id: String { path }

    public init(
        name: String,
        path: String,
        bytes: Int64,
        category: String,
        risk: String,
        isPersonal: Bool
    ) {
        self.name = name
        self.path = path
        self.bytes = bytes
        self.category = category
        self.risk = risk
        self.isPersonal = isPersonal
    }
}

/// 首屏“第一次用，先看懂这台电脑”的只读报告。
/// 数字全部来自真实全盘体检和真实目录统计；没有读到的位置不会补零装完整。
public struct NoviceReport: Sendable {
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let cleanCount: Int
    public let cleanBytes: Int64
    public let confirmCount: Int
    public let confirmBytes: Int64
    public let personalCount: Int
    public let personalBytes: Int64
    public let keepCount: Int
    public let scannedItemCount: Int
    public let reportComplete: Bool
    public let warning: String?
    public let systemSpaces: [NoviceSpaceItem]
    public let homeSpaces: [NoviceSpaceItem]
    public let keepSpaces: [NoviceSpaceItem]

    public init(
        totalBytes: Int64,
        freeBytes: Int64,
        cleanCount: Int,
        cleanBytes: Int64,
        confirmCount: Int,
        confirmBytes: Int64,
        personalCount: Int,
        personalBytes: Int64,
        keepCount: Int,
        scannedItemCount: Int,
        reportComplete: Bool,
        warning: String? = nil,
        systemSpaces: [NoviceSpaceItem],
        homeSpaces: [NoviceSpaceItem],
        keepSpaces: [NoviceSpaceItem] = []
    ) {
        self.totalBytes = max(0, totalBytes)
        self.freeBytes = min(max(0, freeBytes), max(0, totalBytes))
        self.cleanCount = max(0, cleanCount)
        self.cleanBytes = max(0, cleanBytes)
        self.confirmCount = max(0, confirmCount)
        self.confirmBytes = max(0, confirmBytes)
        self.personalCount = max(0, personalCount)
        self.personalBytes = max(0, personalBytes)
        self.keepCount = max(0, keepCount)
        self.scannedItemCount = max(0, scannedItemCount)
        self.reportComplete = reportComplete
        self.warning = warning
        self.systemSpaces = systemSpaces
        self.homeSpaces = homeSpaces
        self.keepSpaces = keepSpaces
    }

    public var usedBytes: Int64 {
        max(0, totalBytes - freeBytes)
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    public var decideCount: Int { confirmCount + personalCount }
    public var decideBytes: Int64 { confirmBytes + personalBytes }

    /// 新手先看的三句话。数字是真实统计，动作仍然是“你点头才动”。
    public var guidance: [String] {
        var lines: [String] = []
        if cleanCount > 0 {
            lines.append("绿色「可清」\(cleanCount) 项、\(AssistantBytes.text(cleanBytes))：缓存、日志、旧安装包一类，删了通常会自动重建。")
        } else {
            lines.append("这次没有扫到规则确认可清的项；没扫到不等于没有垃圾，也不等于可以乱删。")
        }
        if decideCount > 0 {
            lines.append("橙色「要你决定」\(decideCount) 项、\(AssistantBytes.text(decideBytes))：里面有你的文件、聊天数据和需要确认的缓存，雪只列证据。")
        }
        lines.append("系统本体、应用、照片图库、聊天记录和 iPhone 备份不动；雪不提供整目录删除。")
        return lines
    }
}

public enum NoviceReportBuilder {
    /// 把一次首屏体检和两组目录统计收成新手报告。
    /// 目录条目去重、按体积降序，每栏最多 6 条，避免把一整棵树塞给第一次用的人。
    public static func build(
        result: LandingAuditResult?,
        totalBytes: Int64,
        freeBytes: Int64,
        systemSpaces: [NoviceSpaceItem] = [],
        homeSpaces: [NoviceSpaceItem] = [],
        keepSpaces: [NoviceSpaceItem] = [],
        warning: String? = nil,
        maxPerColumn: Int = 6
    ) -> NoviceReport {
        let cleanCount = result?.cleanCount ?? 0
        let cleanBytes = result?.cleanBytes ?? 0
        let confirmCount = result?.confirmCount ?? 0
        let confirmBytes = result?.confirmBytes ?? 0
        let personalCount = result?.personalCount ?? 0
        let personalBytes = result?.personalBytes ?? 0
        let keepCount = result?.keepCount ?? 0
        let scanned = result?.scannedItemCount ?? 0

        return NoviceReport(
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            cleanCount: cleanCount,
            cleanBytes: cleanBytes,
            confirmCount: confirmCount,
            confirmBytes: confirmBytes,
            personalCount: personalCount,
            personalBytes: personalBytes,
            keepCount: keepCount,
            scannedItemCount: scanned,
            reportComplete: result?.reportComplete ?? false,
            warning: warning ?? result?.warning,
            systemSpaces: trim(systemSpaces, limit: maxPerColumn),
            homeSpaces: trim(homeSpaces, limit: maxPerColumn),
            keepSpaces: trim(keepSpaces, limit: maxPerColumn)
        )
    }

    private static func trim(_ items: [NoviceSpaceItem], limit: Int) -> [NoviceSpaceItem] {
        var seen = Set<String>()
        return items
            .filter { $0.bytes > 0 && !$0.path.isEmpty }
            .filter { seen.insert($0.path).inserted }
            .sorted { lhs, rhs in
                if lhs.bytes == rhs.bytes { return lhs.path < rhs.path }
                return lhs.bytes > rhs.bytes
            }
            .prefix(max(1, limit))
            .map { $0 }
    }
}
