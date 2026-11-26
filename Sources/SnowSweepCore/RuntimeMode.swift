import Foundation

/// V0.9.8「雪息」：把“常驻”和“按需”分开。
/// 静默只留轻量菜单栏；扫描和智能清理按需唤醒，结束回到静默。
public enum RuntimeMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case silent
    case scan
    case assist

    public var id: String { rawValue }

    public var chineseName: String {
        switch self {
        case .silent: return "静默"
        case .scan: return "扫描"
        case .assist: return "智能清理"
        }
    }

    public var detail: String {
        switch self {
        case .silent:
            return "只留菜单栏和低频空间采样；不加载模型，不保留扫描结果与页面快照。"
        case .scan:
            return "按需启动扫描；只读目录与元数据，不加载模型；扫描结束回到静默。"
        case .assist:
            return "按需唤醒模型，只处理证据摘要并生成受约束计划；模型会话结束即释放。"
        }
    }

    /// 该状态是否允许加载本地/系统模型。
    public var allowsModel: Bool {
        self == .assist
    }

    /// 该状态是否允许后台扫描。扫描必须由用户触发，不在静默态自行开始。
    public var allowsScanning: Bool {
        self == .scan
    }

    /// 目标常驻内存上限，单位 MB。用于日志、验收和内存压力回退，不是硬性系统限制。
    public var residentMemoryBudgetMB: Int {
        switch self {
        case .silent: return 60
        case .scan: return 600
        case .assist: return 3_600
        }
    }
}

/// 三态资源预算的单一事实来源。数字只用于验收，不写进判定逻辑。
public enum RuntimeMemoryBudget {
    public static let silentResidentMB = 60
    public static let silentHardCapMB = 120
    public static let scanPeakMB = 600
    public static let assistSystemIncrementMB = 100
    public static let assistLocal3BPeakMB = 3_600
}

/// 三态切换的合法性：静默可以进扫描/智能清理；扫描和智能清理结束回到静默。
/// 扫描与智能清理不互相自动抢占，避免一边扫盘一边加载模型把峰值叠高。
public enum RuntimeTransition: Equatable, Sendable {
    case enterSilent
    case enterScan
    case enterAssist
    case rejected

    public static func next(from current: RuntimeMode, to target: RuntimeMode) -> RuntimeTransition {
        if current == target {
            switch target {
            case .silent: return .enterSilent
            case .scan: return .enterScan
            case .assist: return .enterAssist
            }
        }
        switch (current, target) {
        case (.silent, .scan): return .enterScan
        case (.silent, .assist): return .enterAssist
        case (.scan, .silent): return .enterSilent
        case (.assist, .silent): return .enterSilent
        // 扫描中不加载模型；模型运行时不再起全盘扫描，避免内存叠加。
        case (.scan, .assist), (.assist, .scan): return .rejected
        default: return .rejected
        }
    }
}
