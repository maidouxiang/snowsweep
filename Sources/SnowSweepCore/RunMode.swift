import Foundation

/// V0.6.0「静雪」：三档运行模式。
/// 模式只决定“多久刷新一次、后台读多少”，不改变任何清理判定。
public enum RunMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case silent
    case balanced
    case performance

    public var id: String { rawValue }

    public var chineseName: String {
        switch self {
        case .silent: return "静默"
        case .balanced: return "均衡"
        case .performance: return "性能"
        }
    }

    /// 一句话说明，设置页直接展示。
    public var detail: String {
        switch self {
        case .silent:
            return "后台最省：菜单栏 5 分钟刷新一次，日常记录 30 分钟一次，不在后台读审计、蓝牙、启动项。"
        case .balanced:
            return "日常默认：菜单栏 1 分钟刷新一次，日常记录 10 分钟一次，只在打开页面时读取重数据。"
        case .performance:
            return "扫描前后最积极：菜单栏 15 秒刷新一次，日常记录 5 分钟一次，扫描时优先唤醒读取。"
        }
    }

    /// 菜单栏状态刷新间隔。
    public var menuBarInterval: TimeInterval {
        switch self {
        case .silent: return 300
        case .balanced: return 60
        case .performance: return 15
        }
    }

    /// 日常记录采样间隔。
    public var dailyJournalInterval: TimeInterval {
        switch self {
        case .silent: return 1_800
        case .balanced: return 600
        case .performance: return 300
        }
    }

    /// 是否允许后台做重读取（审计、蓝牙、启动项、权限）。
    /// 静默和均衡都不在后台读；只有性能模式允许菜单栏顺带刷新重数据。
    public var allowsBackgroundHeavyReads: Bool {
        self == .performance
    }

    /// 扫描根目录的并发上限：静默 2，均衡取 CPU 的一半且最多 4，性能用全部可用核。
    public func scanConcurrency(activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        let cores = max(1, activeProcessorCount)
        switch self {
        case .silent:
            return min(2, cores)
        case .balanced:
            return min(4, max(2, cores / 2))
        case .performance:
            return cores
        }
    }

    public static let lowBatteryThreshold = 30
}

/// 一次模式计算的结果：实际模式 + 为什么 + 是否是临时状态。
public struct RunModeStatus: Equatable, Sendable {
    public let mode: RunMode
    public let reason: String
    public let isTemporary: Bool

    public init(mode: RunMode, reason: String, isTemporary: Bool) {
        self.mode = mode
        self.reason = reason
        self.isTemporary = isTemporary
    }
}

/// Dock 图标是否可见的唯一策略：主窗口关闭时一定收起；重开后按用户偏好恢复。
/// 单纯把 `showDockIcon` 直接交给 `setActivationPolicy` 会在关窗时留下 Dock 图标。
public enum DockVisibilityPolicy {
    public static func shouldShowDockIcon(preference: Bool, mainWindowClosed: Bool) -> Bool {
        preference && !mainWindowClosed
    }

    public static func activationPolicy(preference: Bool, mainWindowClosed: Bool) -> String {
        shouldShowDockIcon(preference: preference, mainWindowClosed: mainWindowClosed)
            ? "regular"
            : "accessory"
    }
}

/// 把用户偏好、扫描状态、电量与系统低电量模式合成实际模式。
/// 优先级：低电量/低电量模式强制静默 > 扫描中的临时性能 > 用户偏好。
public enum RunModePolicy {
    public static func status(
        preferred: RunMode,
        batteryPercent: Int?,
        lowPowerMode: Bool,
        isScanning: Bool,
        mainWindowClosed: Bool = false
    ) -> RunModeStatus {
        // 主窗口关闭后只留菜单栏，先压到静默；重开主界面会恢复用户偏好。
        if mainWindowClosed {
            return RunModeStatus(
                mode: .silent,
                reason: "主窗口已关闭，自动静默，只保留菜单栏。",
                isTemporary: true
            )
        }
        if lowPowerMode {
            return RunModeStatus(
                mode: .silent,
                reason: "系统已开启低电量模式，强制静默，减少后台活动。",
                isTemporary: true
            )
        }
        if let batteryPercent, batteryPercent < RunMode.lowBatteryThreshold {
            return RunModeStatus(
                mode: .silent,
                reason: "电量低于 \(RunMode.lowBatteryThreshold)%，强制静默，优先省电。",
                isTemporary: true
            )
        }
        if isScanning {
            return RunModeStatus(
                mode: .performance,
                reason: "扫描进行中，临时切到性能；扫描结束 60 秒后自动回退。",
                isTemporary: true
            )
        }
        return RunModeStatus(
            mode: preferred,
            reason: preferred == .silent ? "按你的偏好保持静默。" : "按你的偏好运行。",
            isTemporary: false
        )
    }
}
