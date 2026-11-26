import Foundation

/// 雪语的第一层：只把自然语言编译成「受约束的意图」，绝不生成路径或命令。
/// 模型可以填这些枚举，代码再按白名单目录去测量。
public enum AssistantGoal: String, Codable, Sendable, CaseIterable {
    case clean
    case inspect
    case uninstall
    case optimize
    case unknown

    public var chineseName: String {
        switch self {
        case .clean: return "清理"
        case .inspect: return "查看"
        case .uninstall: return "卸载"
        case .optimize: return "优化"
        case .unknown: return "未识别"
        }
    }
}

public enum AssistantTarget: String, Codable, Sendable, CaseIterable {
    case appCache
    case doubao
    case wechat
    case logs
    case developerCache
    case oldInstallers
    case space
    case memory
    case battery
    case network
    case system
    case unknown

    public var chineseName: String {
        switch self {
        case .appCache: return "应用缓存"
        case .doubao: return "豆包"
        case .wechat: return "微信"
        case .logs: return "日志"
        case .developerCache: return "开发者缓存"
        case .oldInstallers: return "旧安装包"
        case .space: return "空间分布"
        case .memory: return "内存"
        case .battery: return "电池"
        case .network: return "网络"
        case .system: return "系统文件"
        case .unknown: return "未识别对象"
        }
    }
}

public enum AssistantExclusion: String, Codable, Sendable, CaseIterable {
    case chatHistory
    case photos
    case documents
    case userFiles
    case systemFiles
    case trash

    public var chineseName: String {
        switch self {
        case .chatHistory: return "聊天记录"
        case .photos: return "照片"
        case .documents: return "文稿"
        case .userFiles: return "个人文件"
        case .systemFiles: return "系统文件"
        case .trash: return "废纸篓"
        }
    }
}

public enum AssistantMode: String, Codable, Sendable, CaseIterable {
    case analyze
    case preview

    public var chineseName: String {
        switch self {
        case .analyze: return "只分析"
        case .preview: return "先预览"
        }
    }
}

public enum AssistantOrigin: String, Codable, Sendable {
    case rule
    case model
    case remote
    case mixed

    public var chineseName: String {
        switch self {
        case .rule: return "本地规则解析"
        case .model: return "系统本地模型理解"
        case .remote: return "API 模型理解"
        case .mixed: return "规则 + 本地模型"
        }
    }
}

/// 意图结构。所有字段都是有限枚举或文本，没有 path / command / shell。
public struct CleanIntent: Codable, Hashable, Sendable {
    public let rawText: String
    public let goal: AssistantGoal
    public let targets: [AssistantTarget]
    public let excludes: [AssistantExclusion]
    public let mode: AssistantMode
    public let origin: AssistantOrigin
    public let confidence: Double
    public let interpretation: String
    public let clarification: String?
    public let unsupported: Bool

    public init(
        rawText: String,
        goal: AssistantGoal,
        targets: [AssistantTarget],
        excludes: [AssistantExclusion] = [],
        mode: AssistantMode = .preview,
        origin: AssistantOrigin = .rule,
        confidence: Double = 0.9,
        interpretation: String,
        clarification: String? = nil,
        unsupported: Bool = false
    ) {
        self.rawText = rawText
        self.goal = goal
        self.targets = Self.unique(targets)
        self.excludes = Self.unique(excludes)
        self.mode = mode
        self.origin = origin
        self.confidence = confidence
        self.interpretation = interpretation
        self.clarification = clarification
        self.unsupported = unsupported
    }

    public var targetSummary: String {
        targets.filter { $0 != .unknown }.map(\.chineseName).joined(separator: "、")
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// 确定性解析器：覆盖最常见的说法，保证模型不可用时也能完成意图编译。
public enum AssistantIntentParser {
    public static let examples = [
        "豆包缓存太多了，聊天记录别动",
        "清一下应用缓存，先告诉我能清多少",
        "看看谁最占空间",
        "微信缓存有多大",
        "找一下旧安装包",
        "Xcode 编译缓存清掉"
    ]

    public static func parse(_ rawText: String) -> CleanIntent {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "。", with: ".")

        guard !normalized.isEmpty else {
            return CleanIntent(
                rawText: text,
                goal: .unknown,
                targets: [.unknown],
                confidence: 0.1,
                interpretation: "我还没听到你想做什么。",
                clarification: "可以说“豆包缓存太多了”或“看看谁占空间”。"
            )
        }

        var targets: [AssistantTarget] = []
        var excludes: [AssistantExclusion] = []
        var unsupported = false

        // 先判断「别动什么」，排除项优先于目标项。
        if containsAny(normalized, ["聊天记录别动", "别动聊天", "不要聊天", "保留聊天", "聊天记录不要"]) {
            excludes.append(.chatHistory)
        }
        if containsAny(normalized, ["照片别动", "别动照片", "不要照片", "保留照片", "图片别动"]) {
            excludes.append(.photos)
        }
        if containsAny(normalized, ["文稿别动", "文档别动", "不要文稿", "保留文稿", "文件别动"]) {
            excludes.append(.documents)
        }
        if containsAny(normalized, ["废纸篓别动", "不要废纸篓", "保留废纸篓"]) {
            excludes.append(.trash)
        }
        if containsAny(normalized, ["系统文件别动", "系统目录别动", "不要系统文件"]) {
            excludes.append(.systemFiles)
        }

        let wantsSystemDelete = containsAny(normalized, ["系统文件", "系统目录", "systemlibrary"])
            && containsAny(normalized, ["删", "清", "移除", "干掉"])
        if wantsSystemDelete {
            targets.append(.system)
            unsupported = true
        }

        if containsAny(normalized, ["豆包", "doubao"]) {
            targets.append(.doubao)
        }
        if containsAny(normalized, ["微信", "wechat", "weixin"]) {
            targets.append(.wechat)
        }
        if containsAny(normalized, ["xcode", "编译缓存", "模拟器缓存", "开发者缓存", "deriveddata"]) {
            targets.append(.developerCache)
        }
        if containsAny(normalized, ["安装包", "旧包", "dmg", "pkg"]) {
            targets.append(.oldInstallers)
        }
        if containsAny(normalized, ["日志", "log"]) {
            targets.append(.logs)
        }
        // “豆包缓存”“微信缓存”已经命中具体对象，就不再额外加入整个应用缓存，
        // 避免把用户没点名的其他 App 一起卷进来。
        if containsAny(normalized, ["缓存", "cache"]) && targets.isEmpty {
            targets.append(.appCache)
        }
        if containsAny(normalized, ["内存", "卡顿", "卡住", "变慢", "performance"]) {
            targets.append(.memory)
        }
        if containsAny(normalized, ["电池", "耗电", "续航", "battery"]) {
            targets.append(.battery)
        }
        if containsAny(normalized, ["网络", "流量", "网速", "network"]) {
            targets.append(.network)
        }
        if containsAny(normalized, ["占空间", "谁占", "空间分布", "磁盘", "硬盘", "存储", "c盘", "容量", "看看空间"]) {
            targets.append(.space)
        }

        // V0.9.23：问“为什么少了 40G”不是清理，是变化账单。命中后只保留空间目标，
        // 不让“缓存”等字眼把它带成清理计划。
        let isDeltaQuestion = SpaceDeltaQuery.isChangeQuestion(normalized)
        if isDeltaQuestion {
            targets = [.space]
        }

        let inspectWords = ["看看", "多少", "占", "分析", "查", "哪儿", "哪里", "分布", "统计", "读一下", "有多大", "看一下", "找一下", "找找"]
        let cleanWords = ["清理", "清一下", "清掉", "释放", "删", "腾出", "收拾", "太占", "帮我清", "清空", "太多", "满了", "太大", "臃肿"]
        let goal: AssistantGoal
        if containsAny(normalized, inspectWords) {
            goal = .inspect
        } else if containsAny(normalized, cleanWords) {
            goal = .clean
        } else if containsAny(normalized, ["卸载", "uninstall"]) {
            goal = .uninstall
        } else if containsAny(normalized, ["优化", "加速"]) {
            goal = .optimize
        } else {
            goal = targets.isEmpty ? .unknown : .inspect
        }

        if targets.isEmpty {
            if goal == .clean {
                targets = [.appCache, .logs]
            } else if goal == .inspect {
                targets = [.space]
            } else {
                targets = [.unknown]
            }
        }

        let analyzeWords = ["只分析", "先看", "预览", "别删", "不要删", "只看", "算一下", "先算", "别执行", "不要执行", "只读"]
        let mode: AssistantMode = containsAny(normalized, analyzeWords) ? .analyze : .preview

        // 默认就把“个人文件”当成不可动项；具体目录由计划层的保护项再兜一层。
        if targets.contains(.doubao) || targets.contains(.wechat) || targets.contains(.appCache) {
            if !excludes.contains(.userFiles) { excludes.append(.userFiles) }
        }

        let recognized = targets.contains { $0 != .unknown }
        let confidence: Double
        if unsupported { confidence = 0.95 }
        else if recognized && !targets.isEmpty { confidence = 0.92 }
        else { confidence = 0.3 }

        let targetText = targets.filter { $0 != .unknown }.map(\.chineseName).joined(separator: "、")
        let interpretation: String
        if unsupported {
            interpretation = "你想动系统文件；这不在雪的范围。系统目录只会被读取，不会被清理。"
        } else if goal == .inspect {
            if isDeltaQuestion {
                interpretation = "你想知道这段时间空间为什么变了；我会只对两次本机快照，不猜原因。"
            } else {
                interpretation = "你想先看清\(targetText.isEmpty ? "磁盘占用" : targetText)的情况，不执行删除。"
            }
        } else if goal == .clean {
            let excludedText = excludes.map(\.chineseName).joined(separator: "、")
            interpretation = "你想整理\(targetText)\(excludedText.isEmpty ? "" : "，\(excludedText)不动")。"
        } else if goal == .uninstall {
            interpretation = "你想处理卸载相关的事情；我会先给候选和影响，不直接删。"
        } else if goal == .optimize {
            interpretation = "你想让电脑更顺；我可以先看内存和启动项，不执行优化。"
        } else {
            interpretation = "我还没完全听清你要处理什么。"
        }

        let clarification: String?
        if !recognized {
            clarification = "可以说“豆包缓存太多了”“微信缓存有多大”或“看看谁占空间”。"
        } else {
            clarification = nil
        }

        return CleanIntent(
            rawText: text,
            goal: goal,
            targets: targets,
            excludes: excludes,
            mode: mode,
            origin: .rule,
            confidence: confidence,
            interpretation: interpretation,
            clarification: clarification,
            unsupported: unsupported
        )
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
