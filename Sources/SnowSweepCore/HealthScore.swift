import Foundation

/// 概览健康分的可解释拆解。没有电池的台式机不把「电池」按 90 分硬算，
/// 而是把权重按磁盘/内存重新归一，避免制造不存在的扣分项。
public struct HealthScore: Equatable, Sendable {
    public struct Component: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let score: Int
        public let weight: Double
        public let detail: String

        public var contribution: Double { Double(score) * weight }
    }

    public let total: Int
    public let components: [Component]

    public var title: String {
        switch total {
        case ..<60: return "需要处理"
        case ..<80: return "还过得去"
        default: return "状态良好"
        }
    }

    public static func evaluate(
        diskFreeRatio: Double,
        memoryUsedFraction: Double,
        batteryHealthPercent: Double?
    ) -> HealthScore {
        let free = min(1, max(0, diskFreeRatio))
        let used = min(1, max(0, memoryUsedFraction))
        let diskValue: Double = free >= 0.15 ? 1.0 : (free >= 0.08 ? 0.8 : 0.5)
        let memoryValue: Double = used < 0.60 ? 1.0 : (used < 0.80 ? 0.8 : 0.5)

        var components: [Component] = [
            Component(
                id: "disk", label: "可用空间",
                score: Int(round(diskValue * 100)), weight: 0.35,
                detail: String(format: "可用 %.0f%%；低于 15%% 开始扣分", free * 100)
            ),
            Component(
                id: "memory", label: "内存压力",
                score: Int(round(memoryValue * 100)), weight: 0.35,
                detail: String(format: "已用 %.0f%%；60%% 以下不扣分", used * 100)
            )
        ]

        let effectiveBattery: Double
        if let batteryHealthPercent {
            effectiveBattery = min(1, max(0, batteryHealthPercent / 100))
            components.append(Component(
                id: "battery", label: "电池健康",
                score: Int(round(effectiveBattery * 100)), weight: 0.30,
                detail: String(format: "最大容量 %.0f%%", batteryHealthPercent)
            ))
        } else {
            effectiveBattery = 0
            // 无电池：两项各占 50%，不是“电池 0 分”。
            components[0] = Component(
                id: components[0].id, label: components[0].label,
                score: components[0].score, weight: 0.50, detail: components[0].detail
            )
            components[1] = Component(
                id: components[1].id, label: components[1].label,
                score: components[1].score, weight: 0.50, detail: components[1].detail
            )
        }

        let weighted = components.reduce(0.0) { $0 + Double($1.score) * $1.weight }
        let normalizedWeight = components.reduce(0.0) { $0 + $1.weight }
        let total = normalizedWeight > 0 ? Int(round(weighted / normalizedWeight)) : 0
        return HealthScore(total: total, components: components)
    }
}
