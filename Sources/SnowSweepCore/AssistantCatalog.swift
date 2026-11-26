import Foundation

/// 路径白名单：模型只能选择 target，具体目录由这里决定。
/// 任何模型输出都不会进入 `path` 字段。
public enum AssistantSpecRole: String, Codable, Sendable {
    case clean       // 可清，默认勾选
    case confirm     // 可清，但必须逐项确认
    case protected   // 不动的用户数据 / 运行时
    case info        // 只展示占用，不进入清理候选
}

public struct AssistantPathSpec: Identifiable, Hashable, Sendable {
    public let id: String
    public let target: AssistantTarget
    public let displayName: String
    public let rawPath: String
    public let role: AssistantSpecRole
    public let reason: String
    public let category: String

    public init(
        target: AssistantTarget,
        displayName: String,
        rawPath: String,
        role: AssistantSpecRole,
        reason: String,
        category: String
    ) {
        self.id = "\(target.rawValue):\(rawPath)"
        self.target = target
        self.displayName = displayName
        self.rawPath = rawPath
        self.role = role
        self.reason = reason
        self.category = category
    }

    public func expandedPath(home: String = NSHomeDirectory()) -> String {
        if rawPath == "~" { return home }
        if rawPath.hasPrefix("~/") {
            return home + String(rawPath.dropFirst())
        }
        return rawPath
    }
}

/// 只读目录清单。每一项都要能回答“为什么可以碰 / 为什么不能碰”。
public enum AssistantCatalog {
    public static func specs(for intent: CleanIntent, home: String = NSHomeDirectory()) -> [AssistantPathSpec] {
        var result: [AssistantPathSpec] = []
        for target in intent.targets {
            result.append(contentsOf: specs(for: target))
        }

        // 目标去重后，同一路径仍然可能被两个 target 命中；保留优先级最高的一条。
        var byPath: [String: AssistantPathSpec] = [:]
        for spec in result {
            if let existing = byPath[spec.id] {
                if priority(spec.role) < priority(existing.role) {
                    byPath[spec.id] = spec
                }
            } else {
                byPath[spec.id] = spec
            }
        }
        return byPath.values.sorted {
            if priority($0.role) != priority($1.role) { return priority($0.role) < priority($1.role) }
            return $0.id < $1.id
        }
    }

    public static func specs(for target: AssistantTarget) -> [AssistantPathSpec] {
        switch target {
        case .appCache:
            return [
                .init(target: .appCache, displayName: "应用缓存", rawPath: "~/Library/Caches",
                      role: .clean, reason: "应用会自动重建；不含文稿、照片、聊天记录",
                      category: "缓存"),
                .init(target: .appCache, displayName: "崩溃报告", rawPath: "~/Library/Logs/DiagnosticReports",
                      role: .clean, reason: "崩溃诊断文件，系统可重新生成",
                      category: "日志")
            ]

        case .doubao:
            return [
                .init(target: .doubao, displayName: "豆包相关总占用", rawPath: "~/Library/Application Support/DoubaoWork",
                      role: .info, reason: "只作为总量参照，不把整目录当清理项",
                      category: "豆包"),
                .init(target: .doubao, displayName: "豆包旧更新包", rawPath: "~/Library/Application Support/DoubaoWork/update",
                      role: .confirm, reason: "旧版本更新包，删除后下次更新可能需要重新下载",
                      category: "安装包"),
                .init(target: .doubao, displayName: "豆包网络缓存", rawPath: "~/Library/Application Support/DoubaoWork/gecko_cache",
                      role: .clean, reason: "网络资源缓存，应用会按需重新下载",
                      category: "缓存"),
                .init(target: .doubao, displayName: "豆包着色器缓存", rawPath: "~/Library/Application Support/DoubaoWork/ShaderCache",
                      role: .clean, reason: "GPU 着色器缓存，可自动重建",
                      category: "缓存"),
                .init(target: .doubao, displayName: "豆包 Gr 着色器缓存", rawPath: "~/Library/Application Support/DoubaoWork/GrShaderCache",
                      role: .clean, reason: "GPU 着色器缓存，可自动重建",
                      category: "缓存"),
                .init(target: .doubao, displayName: "豆包剪贴板临时文件", rawPath: "~/Library/Application Support/DoubaoWork/ClipboardTemp",
                      role: .clean, reason: "剪贴板临时中转文件，不属于聊天记录",
                      category: "缓存"),
                .init(target: .doubao, displayName: "豆包缓存目录", rawPath: "~/Library/Caches/DoubaoWork",
                      role: .clean, reason: "应用缓存，自动重建；不碰聊天数据库",
                      category: "缓存"),
                .init(target: .doubao, displayName: "豆包用户数据", rawPath: "~/Library/Application Support/DoubaoWork/Default",
                      role: .protected, reason: "可能包含登录状态、会话与本地资料，默认不动",
                      category: "用户数据"),
                .init(target: .doubao, displayName: "豆包运行时", rawPath: "~/Library/Application Support/DoubaoWork/sandbox_runtime",
                      role: .protected, reason: "应用运行所需运行时，删除可能打不开",
                      category: "运行时"),
                .init(target: .doubao, displayName: "豆包本地资料", rawPath: "~/Library/Application Support/DoubaoWork/aha",
                      role: .protected, reason: "本地资料目录，默认不动",
                      category: "用户数据"),
                .init(target: .doubao, displayName: "豆包 SDK 数据", rawPath: "~/Library/Application Support/DoubaoWork/sdk_storage",
                      role: .protected, reason: "SDK 本地存储，默认不动",
                      category: "用户数据")
            ]

        case .wechat:
            return [
                .init(target: .wechat, displayName: "微信容器总占用", rawPath: "~/Library/Containers/com.tencent.xinWeChat",
                      role: .info, reason: "只作为总量参照，不把整个容器当清理项",
                      category: "微信"),
                .init(target: .wechat, displayName: "微信缓存", rawPath: "~/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches",
                      role: .clean, reason: "微信缓存目录；聊天数据库不在这里，不会被选中",
                      category: "缓存"),
                .init(target: .wechat, displayName: "微信缓存（容器外）", rawPath: "~/Library/Caches/com.tencent.xinWeChat",
                      role: .clean, reason: "微信应用缓存，自动重建",
                      category: "缓存"),
                .init(target: .wechat, displayName: "微信聊天数据", rawPath: "~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat",
                      role: .protected, reason: "聊天记录与账号数据，默认不动",
                      category: "聊天记录")
            ]

        case .logs:
            return [
                .init(target: .logs, displayName: "用户日志", rawPath: "~/Library/Logs",
                      role: .confirm, reason: "日志体积通常不大；删除后排查问题会少线索",
                      category: "日志")
            ]

        case .developerCache:
            return [
                .init(target: .developerCache, displayName: "Xcode 编译缓存", rawPath: "~/Library/Developer/Xcode/DerivedData",
                      role: .clean, reason: "编译中间产物，删除后重新编译会慢一些，不影响源码",
                      category: "开发者缓存"),
                .init(target: .developerCache, displayName: "模拟器缓存", rawPath: "~/Library/Developer/CoreSimulator/Caches",
                      role: .clean, reason: "模拟器临时缓存，可自动重建",
                      category: "开发者缓存"),
                .init(target: .developerCache, displayName: "Xcode 归档包", rawPath: "~/Library/Developer/Xcode/Archives",
                      role: .protected, reason: "可能是上架或回溯用的归档版本，默认不动",
                      category: "归档")
            ]

        case .oldInstallers:
            return [
                .init(target: .oldInstallers, displayName: "下载目录", rawPath: "~/Downloads",
                      role: .info, reason: "旧安装包需要逐项确认，不把整个下载目录当清理项",
                      category: "下载")
            ]

        case .space:
            return [
                .init(target: .space, displayName: "桌面", rawPath: "~/Desktop", role: .info, reason: "占用分布", category: "空间"),
                .init(target: .space, displayName: "下载", rawPath: "~/Downloads", role: .info, reason: "占用分布", category: "空间"),
                .init(target: .space, displayName: "文稿", rawPath: "~/Documents", role: .info, reason: "占用分布", category: "空间"),
                .init(target: .space, displayName: "图片", rawPath: "~/Pictures", role: .info, reason: "占用分布", category: "空间"),
                .init(target: .space, displayName: "影片", rawPath: "~/Movies", role: .info, reason: "占用分布", category: "空间"),
                .init(target: .space, displayName: "音乐", rawPath: "~/Music", role: .info, reason: "占用分布", category: "空间"),
                .init(target: .space, displayName: "资源库", rawPath: "~/Library", role: .info, reason: "占用分布", category: "空间"),
                .init(target: .space, displayName: "应用程序", rawPath: "/Applications", role: .info, reason: "占用分布", category: "空间")
            ]

        case .memory, .battery, .network, .system, .unknown:
            return []
        }
    }

    private static func priority(_ role: AssistantSpecRole) -> Int {
        switch role {
        case .confirm: return 0
        case .clean: return 1
        case .info: return 2
        case .protected: return 3
        }
    }
}
