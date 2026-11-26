import Foundation

/// 四级风险等级。保护清单优先级最高，模型只能把 unknown 降为 review。
public enum RiskLevel: String, Codable, Sendable, CaseIterable {
    case safe
    case review
    case protected
    case unknown
}

/// 删除后重建成本，用于 UI 提示。
public enum RebuildCost: String, Codable, Sendable {
    case none
    case low
    case high
    case irreplaceable
}

/// 一个被扫描到的文件系统条目。
public struct ScanItem: Codable, Hashable, Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let modifiedAt: Date?
    public let owner: String?
    /// 扫描瞬间捕获的 (device, inode, 类型)。删除前据此复核，
    /// 防止扫描后被替换成符号链接或另一个文件。旧报告可为空。
    public let identity: FileIdentity?

    public init(
        path: String,
        sizeBytes: Int64,
        modifiedAt: Date? = nil,
        owner: String? = nil,
        identity: FileIdentity? = nil
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.owner = owner
        self.identity = identity
    }
}

extension ScanItem: Identifiable {
    public var id: String { path }
}

/// 最终判定结果，带证据链。
/// explanation 始终是规则原文；模型输出只放在 aiExplanation，绝不覆盖规则依据。
public struct Verdict: Codable, Hashable, Sendable {
    public let item: ScanItem
    public let risk: RiskLevel
    public let explanation: String
    public let evidence: [String]
    public let modelAssisted: Bool
    public let needConfirm: Bool
    public let aiExplanation: String?
    public let confidence: Double?
    /// 规则提供的处理入口；有值时 UI 应优先展示“怎么做”，而不是“删不删”。
    public let guide: String?

    public init(
        item: ScanItem,
        risk: RiskLevel,
        explanation: String,
        evidence: [String] = [],
        modelAssisted: Bool = false,
        needConfirm: Bool = false,
        aiExplanation: String? = nil,
        confidence: Double? = nil,
        guide: String? = nil
    ) {
        self.item = item
        self.risk = risk
        self.explanation = explanation
        self.evidence = evidence
        self.modelAssisted = modelAssisted
        self.needConfirm = needConfirm
        self.aiExplanation = aiExplanation
        self.confidence = confidence
        self.guide = guide
    }

    /// UI 唯一默认勾选口径：只有 safe 且不需要单独确认才默认勾选。
    public var defaultSelected: Bool { risk == .safe && !needConfirm }

    /// 从证据链里取命中的规则 ID；未命中规则时为空。
    /// 历史报告只有 evidence，不额外存字段，避免破坏旧 JSON 兼容性。
    public var ruleID: String? {
        evidence.first { $0.hasPrefix("rule:") }.map { String($0.dropFirst("rule:".count)) }
    }

    /// 置信度低于阈值时 UI 必须标注「本地模型不确定，请人工复核」。
    public var isLowConfidence: Bool {
        guard let confidence else { return false }
        return confidence < RuleEngine.modelConfidenceThreshold
    }
}

/// 扫描缺口。partial 报告不允许执行任何清理，且 UI 必须能展开看到缺了哪些目录。
/// severity 区分"整个盘没扫完"和"个别目录失败"；scope 决定 UI 用全盘警告还是局部提示。
public struct ScanGap: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case tccDenied          // 未授权完全磁盘访问
        case permissionDenied   // EACCES / EPERM
        case opendirFailed      // 路径存在但无法打开目录
        case symlinkLoop        // ELOOP
        case transientIO        // EINTR 等临时错误，已做有限重试仍失败
        case truncated          // 全盘扫描达到内存/条目上限
        case occupancyProbe     // 占用探测失败（保守降级）
        case other
    }

    public enum Severity: String, Codable, Sendable, CaseIterable {
        case info       // 已知且不影响判断的跳过（占位文件、符号链接）
        case warning    // 个别目录失败，局部结果不完整
        case critical   // 全盘截断或权限缺失，报告不可用于清理
    }

    public enum Scope: String, Codable, Sendable {
        case wholeScan
        case directory
    }

    public let kind: Kind
    public let path: String
    public let detail: String?
    public let severity: Severity
    public let scope: Scope

    public init(
        kind: Kind,
        path: String,
        detail: String? = nil,
        severity: Severity? = nil,
        scope: Scope? = nil
    ) {
        self.kind = kind
        self.path = path
        self.detail = detail
        self.severity = severity ?? Self.defaultSeverity(for: kind)
        self.scope = scope ?? Self.defaultScope(for: kind)
    }

    /// 默认分级：全盘级错误直接 critical，个别目录问题只 warning，跳过类只 info。
    public static func defaultSeverity(for kind: Kind) -> Severity {
        switch kind {
        case .tccDenied, .truncated: return .critical
        case .permissionDenied, .opendirFailed, .transientIO, .other: return .warning
        case .symlinkLoop, .occupancyProbe: return .info
        }
    }

    public static func defaultScope(for kind: Kind) -> Scope {
        switch kind {
        case .tccDenied, .truncated: return .wholeScan
        case .permissionDenied, .opendirFailed, .symlinkLoop, .transientIO, .occupancyProbe, .other: return .directory
        }
    }

    public var displayText: String {
        switch kind {
        case .tccDenied: return "没有完全磁盘访问权限，跳过了这个位置"
        case .permissionDenied: return "没有读写权限，跳过了这个位置"
        case .opendirFailed: return "目录存在但打不开，可能已损坏"
        case .symlinkLoop: return "遇到循环快捷方式，已跳过"
        case .transientIO: return "读取时遇到临时错误，重试后仍失败，已跳过"
        case .truncated: return "扫描条目达到上限，已截断，不能据此清理"
        case .occupancyProbe: return "无法确认该目录是否被占用，已保守跳过"
        case .other: return "扫描时遇到错误，已跳过"
        }
    }

    /// 可重试的缺口。UI 可以对这类缺口显示「重新扫描此目录」，其余缺口只能重新授权或人工处理。
    public var isRetryable: Bool { kind == .transientIO }
}

/// 全盘扫描报告。partial 状态下禁止执行任何清理。
public struct ScanReport: Codable, Sendable {
    public let scannedAt: Date
    public let scanStatus: String
    public let totalBytes: Int64
    public let verdicts: [Verdict]
    public let scanGaps: [ScanGap]

    public init(
        scannedAt: Date = Date(),
        scanStatus: String,
        totalBytes: Int64,
        verdicts: [Verdict],
        scanGaps: [ScanGap] = []
    ) {
        self.scannedAt = scannedAt
        self.scanStatus = scanStatus
        self.totalBytes = totalBytes
        self.verdicts = verdicts
        self.scanGaps = scanGaps
    }

    /// “完整”不再等同于“零缺口”：个别目录读不到只是局部缺口，不应锁死整机清理。
    /// 只有 critical（全盘截断 / 全盘级权限缺失）或用户取消才判定不可清理。
    public var isComplete: Bool { scanStatus != "cancelled" && !hasCriticalGaps }
    public var canClean: Bool { isComplete }

    /// 全盘级缺口：即使个别目录失败只是 warning，只要出现 critical 就必须阻止清理。
    public var hasCriticalGaps: Bool { scanGaps.contains { $0.severity == .critical } }

    /// UI 用一句话说明为什么清理按钮不可用。
    public var cleaningBlockedReason: String? {
        guard !canClean else { return nil }
        if hasCriticalGaps {
            return "扫描未完整完成（\(scanGaps.filter { $0.severity == .critical }.count) 项全盘级缺口），禁止清理"
        }
        if !scanGaps.isEmpty {
            return "有 \(scanGaps.count) 个位置未能读取，已跳过；不影响其他位置清理"
        }
        return "扫描状态为 \(scanStatus)，禁止清理"
    }
}
