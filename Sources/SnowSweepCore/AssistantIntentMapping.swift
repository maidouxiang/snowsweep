import Foundation

/// 把有限字段映射成 CleanIntent。系统模型与 API 模型共用同一套白名单，避免接口返回越权对象。
public enum AssistantIntentMapping {
    public static func makeIntent(
        goal rawGoal: String,
        targets rawTargets: [String],
        excludes rawExcludes: [String],
        mode rawMode: String,
        rawText: String,
        fallback: CleanIntent?,
        origin: AssistantOrigin
    ) -> CleanIntent? {
        let goal = canonicalGoal(rawGoal) ?? .unknown
        let targets = rawTargets.compactMap(canonicalTarget)
        let namedTargets = targets.filter { $0 != .unknown }
        guard !namedTargets.isEmpty else { return fallback }
        let excludes = rawExcludes.compactMap(canonicalExclusion)
        let mode = normalize(rawMode) == "analyze" ? AssistantMode.analyze : .preview
        let unsupported = targets.contains(.system)

        let targetText = namedTargets.map(\.chineseName).joined(separator: "、")
        let excludedText = excludes.map(\.chineseName).joined(separator: "、")
        let interpretation: String
        if unsupported {
            interpretation = "你想动系统文件；这不在雪的范围。系统目录只会被读取，不会被清理。"
        } else if goal == .inspect {
            interpretation = "你想先看清\(targetText)的情况，不执行删除。"
        } else {
            interpretation = "你想整理\(targetText)\(excludedText.isEmpty ? "" : "，\(excludedText)不动")。"
        }

        return CleanIntent(
            rawText: rawText,
            goal: goal,
            targets: targets,
            excludes: excludes.isEmpty ? (fallback?.excludes ?? []) : excludes,
            mode: mode,
            origin: origin,
            confidence: 0.86,
            interpretation: interpretation,
            clarification: nil,
            unsupported: unsupported
        )
    }

    public static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    public static func canonicalGoal(_ value: String) -> AssistantGoal? {
        switch normalize(value) {
        case "clean", "清理": return .clean
        case "inspect", "查看", "分析": return .inspect
        case "uninstall", "卸载": return .uninstall
        case "optimize", "优化": return .optimize
        case "unknown", "未知": return .unknown
        default: return nil
        }
    }

    public static func canonicalTarget(_ value: String) -> AssistantTarget? {
        switch normalize(value) {
        case "appcache", "应用缓存", "缓存": return .appCache
        case "doubao", "豆包": return .doubao
        case "wechat", "weixin", "微信": return .wechat
        case "logs", "log", "日志": return .logs
        case "developercache", "开发者缓存", "xcode": return .developerCache
        case "oldinstallers", "旧安装包", "安装包": return .oldInstallers
        case "space", "空间", "空间分布": return .space
        case "memory", "内存": return .memory
        case "battery", "电池": return .battery
        case "network", "网络": return .network
        case "system", "系统", "系统文件": return .system
        case "unknown", "未知": return .unknown
        default: return nil
        }
    }

    public static func canonicalExclusion(_ value: String) -> AssistantExclusion? {
        switch normalize(value) {
        case "chathistory", "聊天记录": return .chatHistory
        case "photos", "photo", "照片", "图片": return .photos
        case "documents", "document", "文稿", "文档": return .documents
        case "userfiles", "个人文件": return .userFiles
        case "systemfiles", "系统文件": return .systemFiles
        case "trash", "废纸篓": return .trash
        default: return nil
        }
    }
}
