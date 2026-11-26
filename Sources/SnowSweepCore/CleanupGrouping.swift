import Foundation

/// 清理页分组。分组只影响“怎么展示”，不改变判定、默认勾选或删除闸门。
public enum CleanupGroup: String, CaseIterable, Identifiable, Sendable {
    case systemCache
    case logs
    case browser
    case developer
    case trash
    case installers
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .systemCache: return "系统与应用缓存"
        case .logs: return "日志与崩溃报告"
        case .browser: return "浏览器缓存"
        case .developer: return "开发缓存"
        case .trash: return "废纸篓"
        case .installers: return "安装包（大文件）"
        case .other: return "其他安全项"
        }
    }

    /// 组头一句话，说明为什么这些项可以放在一起。
    public var subtitle: String {
        switch self {
        case .systemCache: return "系统与 App 自动生成的缓存，重建后会自动恢复"
        case .logs: return "日志与崩溃报告，保留最近记录通常足够"
        case .browser: return "浏览器页面缓存，首次再访问会略慢"
        case .developer: return "Xcode、包管理器与构建产物，下次构建可重建"
        case .trash: return "已移到废纸篓的条目，清空后不可恢复"
        case .installers: return "下载目录里的旧安装包，确认不再需要再清理"
        case .other: return "规则命中但未归入以上分类的安全项"
        }
    }
}

public extension Verdict {
    /// 按规则 ID 优先分组，旧报告没有规则 ID 时退回路径特征。
    var cleanupGroup: CleanupGroup {
        if let ruleID {
            if ruleID.hasPrefix("browser-") { return .browser }
            if ruleID == "trash" { return .trash }
            if ruleID.hasPrefix("installers-") { return .installers }
            if ruleID == "system-caches" || ruleID == "user-app-caches" || ruleID == "sandbox-app-caches" {
                return .systemCache
            }
            if ruleID == "system-logs" || ruleID == "user-log-files" || ruleID == "crash-reports" {
                return .logs
            }
            if ["xcode-", "npm-", "yarn-", "pnpm-", "gradle-", "cocoapods-", "dist-", "pycache-"]
                .contains(where: { ruleID.hasPrefix($0) }) {
                return .developer
            }
        }

        let path = item.path.lowercased()
        if path.contains("/.trash/") { return .trash }
        if path.contains("/library/logs/") || path.contains("diagnosticreports") { return .logs }
        if path.contains("com.google.chrome") || path.contains("com.apple.safari")
            || path.contains("org.mozilla.firefox") {
            return .browser
        }
        if path.contains("/developer/") || path.contains("/.npm/") || path.contains("/.gradle/")
            || path.contains("cocoapods") || path.contains("/pnpm/") || path.contains("/dist/")
            || path.contains("__pycache__") {
            return .developer
        }
        if path.contains("/library/caches/") || path.contains("/library/containers/") {
            return .systemCache
        }
        if path.contains("/downloads/") && (path.hasSuffix(".dmg") || path.hasSuffix(".pkg")) {
            return .installers
        }
        return .other
    }
}
