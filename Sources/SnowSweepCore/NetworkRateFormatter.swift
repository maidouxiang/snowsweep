import Foundation

/// 网络速率显示：固定用十进制单位，不跟随磁盘页的 GB/MB 偏好。
/// 面板每秒刷新，速率文本必须短、稳定，避免“0.00 GB/s”这类不可读结果。
public enum NetworkRateFormatter {
    public static func string(bytesPerSecond: Double) -> String {
        let value = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        if value < 999.5 {
            return String(format: "%.0f B/s", value)
        }
        if value < 999_500 {
            return String(format: "%.0f KB/s", value / 1_000)
        }
        if value < 999_500_000 {
            return String(format: "%.1f MB/s", value / 1_000_000)
        }
        return String(format: "%.2f GB/s", value / 1_000_000_000)
    }
}
