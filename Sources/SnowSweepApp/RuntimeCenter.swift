import Foundation
import AppKit
import SnowSweepCore

extension Notification.Name {
    static let snowRuntimeModeChanged = Notification.Name("SnowSweepRuntimeModeChanged")
}

/// 三态运行时的唯一调度点：静默、扫描、智能清理。
/// 它只负责“什么时候该有重资源”，不参与任何清理判定。
@MainActor
final class RuntimeCenter {
    static let shared = RuntimeCenter()

    private weak var model: ScanViewModel?
    private weak var monitor: SystemMonitor?

    private(set) var mode: RuntimeMode = .silent
    private(set) var reason = "启动，只保留菜单栏"

    private init() {}

    func configure(model: ScanViewModel, monitor: SystemMonitor) {
        self.model = model
        self.monitor = monitor
        apply(.silent, reason: "启动，只保留菜单栏", releaseMemory: false)
    }

    @discardableResult
    func enterScan(reason: String) -> Bool {
        let transition = RuntimeTransition.next(from: mode, to: .scan)
        if transition == .rejected {
            // 扫描与模型互斥：模型还在收尾时，先让扫描排队，不强行叠加峰值。
            model?.lastAction = "智能清理还在收尾，稍后再开始扫描"
            return false
        }
        apply(.scan, reason: reason, releaseMemory: false)
        model?.prepareForScan()
        return true
    }

    @discardableResult
    func enterAssist(reason: String) -> Bool {
        let transition = RuntimeTransition.next(from: mode, to: .assist)
        if transition == .rejected {
            model?.lastAction = "扫描进行中，先等扫描结束再让模型接手"
            return false
        }
        apply(.assist, reason: reason, releaseMemory: false)
        model?.prepareForAssist()
        return true
    }

    /// 扫描结束但用户还在看结果：切回静默节奏，不立刻抹掉报告。
    func noteScanFinished() {
        apply(.silent, reason: "扫描结束，结果保留在界面", releaseMemory: false)
    }

    /// 模型回答结束但用户还在看计划：切回静默节奏，模型会话已随调用释放。
    func noteAssistFinished() {
        apply(.silent, reason: "模型回答结束，会话已释放", releaseMemory: false)
    }

    /// 关窗、退出或用户主动进入静默：释放报告、快照和可回收内存。
    func enterSilent(reason: String = "进入静默", releaseMemory: Bool = true) {
        apply(.silent, reason: reason, releaseMemory: releaseMemory)
    }

    func shutdown() {
        model?.enterSilentMode()
        monitor?.releaseTransientSnapshots()
        model = nil
        monitor = nil
        NotificationCenter.default.post(name: .snowRuntimeModeChanged, object: nil)
    }

    private func apply(_ next: RuntimeMode, reason: String, releaseMemory: Bool) {
        mode = next
        self.reason = reason
        model?.setRuntimeMode(next, reason: reason)
        if releaseMemory {
            model?.enterSilentMode()
            monitor?.releaseTransientSnapshots()
        }
        NotificationCenter.default.post(name: .snowRuntimeModeChanged, object: nil)
    }
}
