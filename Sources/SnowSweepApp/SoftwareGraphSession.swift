import Foundation
import SnowSweepCore

/// 族谱扫描结果的进程内缓存。
/// 族谱页离开再回来不重新扫；只有点「重新扫描」或卸载成功后作废。
@MainActor
final class SoftwareGraphSession {
    static let shared = SoftwareGraphSession()

    private(set) var report: SoftwareGraphReport?
    private(set) var scannedAt: Date?
    private(set) var duration: TimeInterval?

    /// 十分钟内复用；超过后再次进入会重新扫，避免拿过期关系网做卸载判断。
    var maxAge: TimeInterval = 600

    var cachedReport: SoftwareGraphReport? {
        guard let report, let scannedAt, Date().timeIntervalSince(scannedAt) < maxAge else {
            return nil
        }
        return report
    }

    var cachedDuration: TimeInterval? {
        guard cachedReport != nil else { return nil }
        return duration
    }

    func store(_ report: SoftwareGraphReport, duration: TimeInterval) {
        self.report = report
        self.scannedAt = Date()
        self.duration = duration
    }

    func invalidate() {
        report = nil
        scannedAt = nil
        duration = nil
    }
}
