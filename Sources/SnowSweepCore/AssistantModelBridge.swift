import Foundation
import FoundationModels

/// 系统本地模型只做一件事：把一句话补成受约束的意图字段。
/// 它看不到路径、文件名、体积，也不能生成命令。
@available(macOS 26, *)
@MainActor
public enum AssistantModelBridge {
    @Generable
    struct ModelIntent {
        @Guide(description: "目标，只能是 clean、inspect、uninstall、optimize、unknown")
        var goal: String

        @Guide(description: "对象，只能从 appCache、doubao、wechat、logs、developerCache、oldInstallers、space、memory、battery、network、system、unknown 中选，最多 4 个")
        var targets: [String]

        @Guide(description: "不能碰的内容，只能从 chatHistory、photos、documents、userFiles、systemFiles、trash 中选，没有就返回空数组")
        var excludes: [String]

        @Guide(description: "模式，只能是 analyze 或 preview；用户说只看看/别删时用 analyze")
        var mode: String

        @Guide(description: "一句中文说明你理解的目标，不要写体积数字，不要写文件路径")
        var understanding: String
    }

    public static var availabilityText: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "系统本地模型可用"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "这台设备不支持 Apple Intelligence"
            case .appleIntelligenceNotEnabled: return "Apple Intelligence 未开启"
            case .modelNotReady: return "系统模型尚未准备好"
            @unknown default: return "系统模型暂不可用"
            }
        }
    }

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public static func parse(_ text: String, fallback: CleanIntent) async -> CleanIntent? {
        guard isAvailable else { return nil }

        let session = LanguageModelSession(
            instructions: """
            你是雪的意图解析器。只把用户的话翻译成结构化字段，不解释系统知识，不给清理建议。
            你不能输出路径、命令、文件名或体积数字。用户没有明确点名的对象，不要自行扩大。
            如果用户说“别动聊天记录/照片/文稿”，必须放进 excludes。
            如果用户说“只看看/先别删/预览”，mode 必须是 analyze。
            如果用户要求删除系统文件，targets 填 system，并在 understanding 里说明这不在清理范围。
            """
        )

        do {
            let response = try await session.respond(to: text, generating: ModelIntent.self)
            return map(response.content, rawText: text, fallback: fallback)
        } catch {
            return nil
        }
    }

    private static func map(_ model: ModelIntent, rawText: String, fallback: CleanIntent) -> CleanIntent? {
        let goal = canonicalGoal(model.goal) ?? .unknown
        let targets = model.targets.compactMap(canonicalTarget)
        let excludes = model.excludes.compactMap(canonicalExclusion)
        let mode = (normalize(model.mode) == "analyze") ? AssistantMode.analyze : .preview

        // 模型没有给出可用对象时，退回规则解析，避免空计划。
        guard !targets.isEmpty else { return fallback }

        let unsupported = targets.contains(.system)
        let targetText = targets.filter { $0 != .unknown }.map(\.chineseName).joined(separator: "、")
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
            excludes: excludes.isEmpty ? fallback.excludes : excludes,
            mode: mode,
            origin: .model,
            confidence: 0.86,
            interpretation: interpretation,
            clarification: nil,
            unsupported: unsupported
        )
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func canonicalGoal(_ value: String) -> AssistantGoal? {
        switch normalize(value) {
        case "clean", "清理": return .clean
        case "inspect", "查看", "分析": return .inspect
        case "uninstall", "卸载": return .uninstall
        case "optimize", "优化": return .optimize
        case "unknown", "未知": return .unknown
        default: return nil
        }
    }

    private static func canonicalTarget(_ value: String) -> AssistantTarget? {
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

    private static func canonicalExclusion(_ value: String) -> AssistantExclusion? {
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
