import Foundation

/// 导出脱敏器。默认开启：把报告里出现的真实用户名收敛掉，
/// 但保留目录结构、判定结果与证据链——报告仍可用来排查，只是不再暴露"你是谁"。
///
/// 注意：这是"少说一点"，不是加密。用户如果想要原始路径，关掉开关即可；
/// 本软件不会把脱敏后的路径当成新的事实来源，更不会反过来改扫描报告。
public struct ReportRedactor: Sendable, Equatable {
    public let username: String
    public let isEnabled: Bool

    /// 这些是 macOS 的系统共享账户，不是个人隐私，收敛反而会让报告看不懂。
    private static let sharedAccounts: Set<String> = ["Shared", "Guest", "root", "daemon", "nobody"]

    public init(username: String = NSUserName(), isEnabled: Bool = true) {
        self.username = username
        self.isEnabled = isEnabled
    }

    public static var `default`: ReportRedactor { ReportRedactor() }

    public func redact(_ text: String) -> String {
        guard isEnabled, !username.isEmpty else { return text }
        var result = text

        // 1) 当前用户的家目录：/Users/example/... → ~/...
        let absoluteHome = "/Users/\(username)"
        result = result.replacingOccurrences(of: absoluteHome + "/", with: "~/")
        if result == absoluteHome || result.hasSuffix(absoluteHome) {
            result = result.replacingOccurrences(of: absoluteHome, with: "~")
        }

        // 2) 其他人的家目录：/Users/other/... → /Users/〈用户〉/...
        //    先排除当前用户（已处理）与系统共享账户。
        let pattern = #"/Users/([^/\s"',;)]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let nameRange = Range(match.range(at: 1), in: result) else { continue }
            let name = String(result[nameRange])
            guard name != username, !Self.sharedAccounts.contains(name) else { continue }
            result.replaceSubrange(range, with: "/Users/〈用户〉")
        }
        return result
    }

    public func redacted(_ gap: ScanGap) -> ScanGap {
        ScanGap(
            kind: gap.kind,
            path: redact(gap.path),
            detail: gap.detail.map(redact),
            severity: gap.severity,
            scope: gap.scope
        )
    }
}
