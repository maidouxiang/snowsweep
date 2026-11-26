import Foundation

/// 测量结果只包含体积，不包含文件内容。
public struct AssistantMeasurement: Identifiable, Hashable, Sendable {
    public let specID: String
    public let path: String
    public let bytes: Int64?
    public let exists: Bool
    public let isPartial: Bool

    public var id: String { specID }

    public init(specID: String, path: String, bytes: Int64?, exists: Bool, isPartial: Bool) {
        self.specID = specID
        self.path = path
        self.bytes = bytes
        self.exists = exists
        self.isPartial = isPartial
    }
}

public struct AssistantPlanItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let path: String
    public let bytes: Int64
    public let risk: RiskLevel
    public let role: AssistantSpecRole
    public let reason: String
    public let category: String
    public let defaultSelected: Bool
    public let isPartial: Bool

    public init(
        id: String,
        displayName: String,
        path: String,
        bytes: Int64,
        risk: RiskLevel,
        role: AssistantSpecRole,
        reason: String,
        category: String,
        defaultSelected: Bool,
        isPartial: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.bytes = bytes
        self.risk = risk
        self.role = role
        self.reason = reason
        self.category = category
        self.defaultSelected = defaultSelected
        self.isPartial = isPartial
    }
}

public struct AssistantObservation: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let bytes: Int64
    public let reason: String
    public let category: String
}

public struct AssistantExcluded: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let bytes: Int64?
    public let reason: String
}

public struct AssistantPlan: Identifiable, Sendable {
    public let id: UUID
    public let intent: CleanIntent
    public let headline: String
    public let summary: String
    public let steps: [String]
    public let items: [AssistantPlanItem]
    public let observations: [AssistantObservation]
    public let excluded: [AssistantExcluded]
    public let cleanBytes: Int64
    public let confirmBytes: Int64
    public let contextBytes: Int64
    public let excludedBytes: Int64
    public let warnings: [String]
    public let generatedAt: Date
    public let isReadOnly: Bool

    public var candidateBytes: Int64 { cleanBytes + confirmBytes }
    public var itemCount: Int { items.count }
    public var hasAnyData: Bool { !items.isEmpty || !observations.isEmpty }

    public init(
        id: UUID = UUID(),
        intent: CleanIntent,
        headline: String,
        summary: String,
        steps: [String],
        items: [AssistantPlanItem],
        observations: [AssistantObservation],
        excluded: [AssistantExcluded],
        cleanBytes: Int64,
        confirmBytes: Int64,
        contextBytes: Int64,
        excludedBytes: Int64,
        warnings: [String],
        generatedAt: Date = Date(),
        isReadOnly: Bool = true
    ) {
        self.id = id
        self.intent = intent
        self.headline = headline
        self.summary = summary
        self.steps = steps
        self.items = items
        self.observations = observations
        self.excluded = excluded
        self.cleanBytes = cleanBytes
        self.confirmBytes = confirmBytes
        self.contextBytes = contextBytes
        self.excludedBytes = excludedBytes
        self.warnings = warnings
        self.generatedAt = generatedAt
        self.isReadOnly = isReadOnly
    }
}

public enum AssistantPlanBuilder {
    public static func build(
        intent: CleanIntent,
        specs: [AssistantPathSpec],
        measurements: [AssistantMeasurement],
        diskFreeBytes: Int64? = nil
    ) -> AssistantPlan {
        let measurementByID = Dictionary(uniqueKeysWithValues: measurements.map { ($0.specID, $0) })
        var items: [AssistantPlanItem] = []
        var observations: [AssistantObservation] = []
        var excluded: [AssistantExcluded] = []
        var warnings: [String] = []
        var missing: [String] = []

        for spec in specs {
            guard let measurement = measurementByID[spec.id] else {
                missing.append(spec.displayName)
                continue
            }
            guard measurement.exists else {
                missing.append(spec.displayName)
                continue
            }
            let bytes = max(0, measurement.bytes ?? 0)

            switch spec.role {
            case .clean, .confirm:
                let risk: RiskLevel = spec.role == .clean ? .safe : .review
                items.append(
                    AssistantPlanItem(
                        id: spec.id,
                        displayName: spec.displayName,
                        path: measurement.path,
                        bytes: bytes,
                        risk: risk,
                        role: spec.role,
                        reason: spec.reason,
                        category: spec.category,
                        defaultSelected: spec.role == .clean,
                        isPartial: measurement.isPartial
                    )
                )
            case .protected:
                excluded.append(
                    AssistantExcluded(
                        id: spec.id,
                        displayName: spec.displayName,
                        bytes: measurement.bytes,
                        reason: spec.reason
                    )
                )
            case .info:
                observations.append(
                    AssistantObservation(
                        id: spec.id,
                        displayName: spec.displayName,
                        bytes: bytes,
                        reason: spec.reason,
                        category: spec.category
                    )
                )
            }
        }

        let cleanBytes = items.filter { $0.role == .clean && !$0.isPartial }.reduce(0) { $0 + $1.bytes }
        let confirmBytes = items.filter { $0.role == .confirm && !$0.isPartial }.reduce(0) { $0 + $1.bytes }
        let partialCount = items.filter { $0.isPartial }.count
        let excludedBytes = excluded.compactMap(\.bytes).reduce(0, +)
        let contextBytes = observations
            .filter { $0.bytes > 0 }
            .map(\.bytes)
            .max() ?? 0

        items.sort {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.displayName < $1.displayName
        }
        observations.sort { $0.bytes > $1.bytes }

        if intent.unsupported {
            warnings.append("系统文件不在雪的范围；不会生成任何系统目录候选。")
        }
        if !missing.isEmpty {
            let names = missing.prefix(3).joined(separator: "、")
            let more = missing.count > 3 ? "等 \(missing.count) 项" : ""
            warnings.append("没有找到或读不到：\(names)\(more)。这些项没有计入。")
        }
        if items.contains(where: { $0.isPartial }) {
            warnings.append("有候选没读全，显示的是已读到的最小值；不会按估算执行删除。")
        }
        if intent.clarification != nil {
            warnings.append(intent.clarification ?? "")
        }

        let targetText = intent.targetSummary.isEmpty ? "这台电脑" : intent.targetSummary
        let headline: String
        if intent.unsupported {
            headline = "这件事不在雪的范围"
        } else if contextBytes > 0 && contextBytes >= cleanBytes + confirmBytes {
            headline = "\(targetText)相关占用 \(AssistantBytes.text(contextBytes))"
        } else if cleanBytes + confirmBytes > 0 {
            headline = "找到 \(AssistantBytes.text(cleanBytes + confirmBytes)) 可清候选"
        } else if partialCount > 0 {
            headline = "有 \(partialCount) 项没读全"
        } else if !observations.isEmpty {
            headline = "已完成只读统计"
        } else {
            headline = "没有找到可统计的项目"
        }

        let summary = makeSummary(
            intent: intent,
            targetText: targetText,
            cleanBytes: cleanBytes,
            confirmBytes: confirmBytes,
            excludedCount: excluded.count,
            partialCount: partialCount,
            observationCount: observations.count,
            diskFreeBytes: diskFreeBytes
        )

        let steps: [String]
        if intent.unsupported {
            steps = [
                "识别到系统目录：直接拒绝生成清理候选",
                "没有读取系统文件，也没有调用删除",
                "可以改为查看空间分布，或到专家模式逐项了解"
            ]
        } else {
            steps = [
                "听懂目标：\(intent.interpretation)",
                "按白名单量体积：只读 \(specs.count) 个已知目录，不碰其他位置",
                "按风险分组：可清 \(items.filter { $0.role == .clean && !$0.isPartial }.count) 项，需确认 \(items.filter { $0.role == .confirm && !$0.isPartial }.count) 项，读不全 \(partialCount) 项",
                intent.mode == .analyze ? "停在分析：这一轮只看数字，不执行删除" : "停在预览：这一轮只给候选，不执行删除"
            ]
        }

        return AssistantPlan(
            intent: intent,
            headline: headline,
            summary: summary,
            steps: steps,
            items: items,
            observations: observations,
            excluded: excluded,
            cleanBytes: cleanBytes,
            confirmBytes: confirmBytes,
            contextBytes: contextBytes,
            excludedBytes: excludedBytes,
            warnings: warnings.filter { !$0.isEmpty },
            generatedAt: Date()
        )
    }

    private static func makeSummary(
        intent: CleanIntent,
        targetText: String,
        cleanBytes: Int64,
        confirmBytes: Int64,
        excludedCount: Int,
        partialCount: Int,
        observationCount: Int,
        diskFreeBytes: Int64?
    ) -> String {
        if intent.unsupported {
            return "系统目录只读不删；这不是模型能放宽的边界。"
        }

        var parts: [String] = []
        if cleanBytes > 0 {
            parts.append("可清 \(AssistantBytes.text(cleanBytes))")
        }
        if confirmBytes > 0 {
            parts.append("需确认 \(AssistantBytes.text(confirmBytes))")
        }
        if partialCount > 0 {
            parts.append("\(partialCount) 项读不全，未计入体积")
        }
        if excludedCount > 0 {
            parts.append("\(excludedCount) 项用户数据/运行时不动")
        }
        if parts.isEmpty, observationCount > 0 {
            parts.append("只读统计了 \(observationCount) 个位置")
        }
        if parts.isEmpty {
            parts.append("没有找到可读取的目录")
        }

        var sentence = "\(targetText)：\(parts.joined(separator: "；"))。"
        if intent.mode == .analyze {
            sentence += "这次只分析，不会执行删除。"
        } else {
            sentence += "确认后才移废纸篓；不会永久删除。"
        }
        if let diskFreeBytes, diskFreeBytes > 0 {
            sentence += "当前可用 \(AssistantBytes.text(diskFreeBytes))。"
        }
        return sentence
    }
}

public enum AssistantBytes {
    /// 与 Finder、概览页一致的十进制口径：1 GB = 1,000,000,000 字节。
    /// 以前这里用 1024³ 却仍写 GB，模型观察和界面会差出几十 GB。
    public static func text(_ bytes: Int64) -> String {
        let value = max(0, bytes)
        if value >= 1_000_000_000 {
            return String(format: "%.2f GB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1f MB", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0f KB", Double(value) / 1_000)
        }
        return "\(value) B"
    }
}

/// 真正允许进入废纸篓的候选判定。模型和界面都不能绕过这里。
/// 只接受白名单计划里的 `clean`（可选 `confirm`），读不全一律排除。
public enum AssistantCleanupPolicy {
    public static func eligibleItems(in plan: AssistantPlan, includeReview: Bool) -> [AssistantPlanItem] {
        guard !plan.intent.unsupported else { return [] }
        return plan.items.filter { item in
            guard !item.isPartial else { return false }
            switch item.role {
            case .clean: return true
            case .confirm: return includeReview
            case .protected, .info: return false
            }
        }
    }

    public static func totalBytes(of items: [AssistantPlanItem]) -> Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }
}
