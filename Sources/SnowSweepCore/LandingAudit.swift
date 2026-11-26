import Foundation

/// 首屏体检的决策类型。雪只把「能清的」放进可执行按钮，
/// 个人文件和需确认项仍要用户逐项点头，保护项没有任何删除入口。
public enum AuditDecision: String, Sendable, CaseIterable {
    case clean
    case confirm
    case personal
    case keep

    public var title: String {
        switch self {
        case .clean: return "可清"
        case .confirm: return "需你确认"
        case .personal: return "你的文件"
        case .keep: return "不动"
        }
    }

    public var isTrashable: Bool {
        switch self {
        case .clean, .confirm, .personal: return true
        case .keep: return false
        }
    }
}

/// 一条体检结论。标题是给人看的中文名，路径只作证据，不拿来当主标题。
public struct AuditFinding: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let path: String
    public let bytes: Int64
    public let decision: AuditDecision
    public let category: String
    public let reason: String
    public let needConfirm: Bool
    public let modifiedAt: Date?

    public init(
        title: String,
        path: String,
        bytes: Int64,
        decision: AuditDecision,
        category: String,
        reason: String,
        needConfirm: Bool = false,
        modifiedAt: Date? = nil
    ) {
        self.id = path
        self.title = title
        self.path = path
        self.bytes = bytes
        self.decision = decision
        self.category = category
        self.reason = reason
        self.needConfirm = needConfirm
        self.modifiedAt = modifiedAt
    }

    public var isTrashable: Bool { decision.isTrashable }
}

/// 首屏一次全盘体检的结果。列表只放最大的若干项，
/// 总数和字节仍按全量统计，避免用户被“只列了 20 项”误导。
public struct LandingAuditResult: Sendable {
    public let clean: [AuditFinding]
    public let confirm: [AuditFinding]
    public let personal: [AuditFinding]
    public let keep: [AuditFinding]
    public let cleanCount: Int
    public let confirmCount: Int
    public let personalCount: Int
    public let keepCount: Int
    public let cleanBytes: Int64
    public let confirmBytes: Int64
    public let personalBytes: Int64
    public let recentPersonalCount: Int
    public let recentPersonalBytes: Int64
    public let scannedItemCount: Int
    public let reportComplete: Bool
    public let warning: String?

    public init(
        clean: [AuditFinding],
        confirm: [AuditFinding],
        personal: [AuditFinding],
        keep: [AuditFinding],
        cleanCount: Int,
        confirmCount: Int,
        personalCount: Int,
        keepCount: Int,
        cleanBytes: Int64,
        confirmBytes: Int64,
        personalBytes: Int64,
        recentPersonalCount: Int,
        recentPersonalBytes: Int64,
        scannedItemCount: Int,
        reportComplete: Bool,
        warning: String?
    ) {
        self.clean = clean
        self.confirm = confirm
        self.personal = personal
        self.keep = keep
        self.cleanCount = cleanCount
        self.confirmCount = confirmCount
        self.personalCount = personalCount
        self.keepCount = keepCount
        self.cleanBytes = cleanBytes
        self.confirmBytes = confirmBytes
        self.personalBytes = personalBytes
        self.recentPersonalCount = recentPersonalCount
        self.recentPersonalBytes = recentPersonalBytes
        self.scannedItemCount = scannedItemCount
        self.reportComplete = reportComplete
        self.warning = warning
    }

    public var decisions: [AuditFinding] { clean + confirm + personal }
    public var totalDecisionCount: Int { cleanCount + confirmCount + personalCount }
    public var decisionBytes: Int64 { cleanBytes + confirmBytes + personalBytes }
    public var isEmpty: Bool {
        clean.isEmpty && confirm.isEmpty && personal.isEmpty && keep.isEmpty
    }
}

public enum LandingAuditBuilder {
    /// 把规则判定和大文件扫描收成一份“全盘决策单”。
    /// - clean：规则说安全且不需要二次确认；
    /// - confirm：规则要求确认，或需要用户先看懂；
    /// - personal：个人目录里的大文件/最近改动，雪不判断内容，只列证据；
    /// - keep：保护项与读不准项，只解释为什么不动。
    public static func build(
        verdicts: [Verdict],
        bigFiles: [LargeFileRecord],
        now: Date = Date(),
        reportComplete: Bool = true,
        warning: String? = nil,
        maxPerSection: Int = 40,
        maxCleanItems: Int = 200
    ) -> LandingAuditResult {
        var clean: [AuditFinding] = []
        var confirm: [AuditFinding] = []
        var keep: [AuditFinding] = []
        var seen = Set<String>()

        for verdict in verdicts {
            let path = verdict.item.path
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            let base = AuditFinding(
                title: title(for: verdict),
                path: path,
                bytes: verdict.item.sizeBytes,
                decision: decision(for: verdict),
                category: category(for: verdict),
                reason: reason(for: verdict),
                needConfirm: verdict.needConfirm,
                modifiedAt: verdict.item.modifiedAt
            )
            switch base.decision {
            case .clean: clean.append(base)
            case .confirm: confirm.append(base)
            case .keep: keep.append(base)
            case .personal: break
            }
        }

        var personal: [AuditFinding] = []
        for record in bigFiles {
            guard !record.path.isEmpty, seen.insert(record.path).inserted else { continue }
            let recent = now.timeIntervalSince(record.modifiedAt) <= 7 * 86_400
            personal.append(AuditFinding(
                title: record.name,
                path: record.path,
                bytes: record.bytes,
                decision: .personal,
                category: recent ? "最近 7 天改过的大文件（≥20MB）" : "个人大文件（≥20MB）",
                reason: recent
                    ? "这是你自己的文件，最近改过。雪不判断内容，只有你确认才移废纸篓。"
                    : "这是你自己的文件。雪不判断内容，只有你确认才移废纸篓。",
                needConfirm: true,
                modifiedAt: record.modifiedAt
            ))
        }

        let cleanAll = clean.sorted(by: sizeThenPath)
        let confirmAll = confirm.sorted(by: sizeThenPath)
        let personalAll = personal.sorted(by: sizeThenPath)
        let keepAll = keep.sorted(by: sizeThenPath)
        let recentAll = personalAll.filter { finding in
            guard let modifiedAt = finding.modifiedAt else { return false }
            return now.timeIntervalSince(modifiedAt) <= 7 * 86_400
        }
        // 最近改动优先：用户问“一下午少 40G”时，先看今天动过什么；
        // 同时保留最大的老文件，问“谁最占空间”也能回答。
        let recentPicked = Array(recentAll.prefix(8))
        let recentIDs = Set(recentPicked.map(\.id))
        let largestPicked = personalAll.filter { !recentIDs.contains($0.id) }.prefix(8)
        let personalPicked = Array((recentPicked + Array(largestPicked)).prefix(min(16, maxPerSection)))

        return LandingAuditResult(
            clean: Array(cleanAll.prefix(max(1, maxCleanItems))),
            confirm: Array(confirmAll.prefix(maxPerSection)),
            personal: personalPicked,
            keep: Array(keepAll.prefix(min(10, maxPerSection))),
            cleanCount: cleanAll.count,
            confirmCount: confirmAll.count,
            personalCount: personalAll.count,
            keepCount: keepAll.count,
            cleanBytes: cleanAll.reduce(0) { $0 + $1.bytes },
            confirmBytes: confirmAll.reduce(0) { $0 + $1.bytes },
            personalBytes: personalAll.reduce(0) { $0 + $1.bytes },
            recentPersonalCount: recentAll.count,
            recentPersonalBytes: recentAll.reduce(0) { $0 + $1.bytes },
            scannedItemCount: verdicts.count,
            reportComplete: reportComplete,
            warning: warning
        )
    }

    private static func decision(for verdict: Verdict) -> AuditDecision {
        switch verdict.risk {
        case .safe:
            return verdict.needConfirm ? .confirm : .clean
        case .review:
            return .confirm
        case .protected, .unknown:
            return .keep
        }
    }

    private static func title(for verdict: Verdict) -> String {
        let last = (verdict.item.path as NSString).lastPathComponent
        if let rule = verdict.ruleID {
            if rule == "user-app-caches" || rule == "sandbox-app-caches",
               !last.isEmpty, last != "Caches" {
                return "\(last) 缓存"
            }
            if let name = ruleTitles[rule] { return name }
        }
        return last.isEmpty ? verdict.item.path : last
    }

    private static func category(for verdict: Verdict) -> String {
        if let rule = verdict.ruleID, let category = ruleCategories[rule] {
            return category
        }
        switch verdict.risk {
        case .safe: return "可清理"
        case .review: return "需要确认"
        case .protected: return "受保护"
        case .unknown: return "读不准"
        }
    }

    private static func reason(for verdict: Verdict) -> String {
        if let ai = verdict.aiExplanation, !ai.isEmpty { return ai }
        if !verdict.explanation.isEmpty { return verdict.explanation }
        switch verdict.risk {
        case .safe: return "规则判断可以清理；移入废纸篓，不会永久删除。"
        case .review: return "删掉后可能需要重新下载或重新生成，请你看过再决定。"
        case .protected: return "在保护清单或系统必需位置内，雪不会删除。"
        case .unknown: return "扫描没读全，不能判断，保守起见不动。"
        }
    }

    private static func sizeThenPath(_ a: AuditFinding, _ b: AuditFinding) -> Bool {
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        return a.path.localizedStandardCompare(b.path) == .orderedAscending
    }

    private static let ruleTitles: [String: String] = [
        "xcode-derived-data": "Xcode 编译缓存",
        "xcode-device-support": "Xcode 设备支持文件",
        "xcode-archives": "Xcode 归档",
        "xcode-simulator-caches": "模拟器缓存",
        "npm-cache": "npm 缓存",
        "yarn-cache": "Yarn 缓存",
        "pnpm-store": "pnpm 存储",
        "gradle-cache": "Gradle 缓存",
        "cocoapods-cache": "CocoaPods 缓存",
        "browser-chrome-cache": "Chrome 缓存",
        "browser-safari-cache": "Safari 缓存",
        "browser-firefox-cache": "Firefox 缓存",
        "crash-reports": "崩溃报告",
        "sandbox-app-caches": "应用沙盒缓存",
        "dist-projects": "项目构建产物",
        "dist-developer": "开发目录构建产物",
        "dist-code": "代码目录构建产物",
        "pycache-projects": "Python 缓存（项目）",
        "pycache-developer": "Python 缓存（开发目录）",
        "pycache-code": "Python 缓存（代码目录）",
        "installers-dmg": "旧 DMG 安装包",
        "installers-pkg": "旧 PKG 安装包",
        "time-machine-local-snapshots": "本地时间机器快照",
        "system-caches": "系统缓存",
        "system-logs": "系统日志",
        "user-app-caches": "应用缓存",
        "user-log-files": "用户日志",
        "trash": "废纸篓",
        "chat-cache-tencent": "腾讯应用缓存",
        "chat-cache-tencent-sandbox": "腾讯应用沙盒缓存",
        "chat-cache-bytedance": "飞书/豆包缓存",
        "chat-cache-doubao-browser": "豆包浏览器缓存",
        "chat-cache-doubao-work": "豆包工作缓存",
        "chat-cache-alibaba": "钉钉等办公缓存",
        "office-cache-kingsoft": "WPS 缓存",
        "office-cache-kingsoft-sandbox": "WPS 沙盒缓存",
        "browser-edge-cache": "Edge 缓存",
        "browser-edge-legacy": "Microsoft Edge 缓存",
        "browser-edge-app": "Edge 应用缓存",
        "browser-arc-cache": "Arc 缓存",
        "mail-downloads": "邮件附件",
        "adobe-media-cache": "Adobe 媒体缓存",
        "premiere-media-cache": "Premiere 缓存",
        "davinci-render-cache": "达芬奇渲染缓存",
        "homebrew-cache": "Homebrew 缓存",
        "pip-cache": "pip 缓存",
        "protected-ios-backup": "iPhone/iPad 备份",
        "protected-photos-library": "照片图库",
        "protected-messages": "iMessage 聊天记录",
        "protected-safari": "Safari 书签与历史"
    ]

    private static let ruleCategories: [String: String] = [
        "xcode-derived-data": "开发工具",
        "xcode-device-support": "开发工具",
        "xcode-archives": "开发工具",
        "xcode-simulator-caches": "开发工具",
        "npm-cache": "开发工具",
        "yarn-cache": "开发工具",
        "pnpm-store": "开发工具",
        "gradle-cache": "开发工具",
        "cocoapods-cache": "开发工具",
        "browser-chrome-cache": "浏览器",
        "browser-safari-cache": "浏览器",
        "browser-firefox-cache": "浏览器",
        "crash-reports": "诊断日志",
        "sandbox-app-caches": "应用缓存",
        "dist-projects": "构建产物",
        "dist-developer": "构建产物",
        "dist-code": "构建产物",
        "pycache-projects": "开发工具",
        "pycache-developer": "开发工具",
        "pycache-code": "开发工具",
        "installers-dmg": "安装包",
        "installers-pkg": "安装包",
        "time-machine-local-snapshots": "备份快照",
        "system-caches": "系统缓存",
        "system-logs": "系统日志",
        "user-app-caches": "应用缓存",
        "user-log-files": "日志",
        "trash": "废纸篓",
        "chat-cache-tencent": "聊天缓存",
        "chat-cache-tencent-sandbox": "聊天缓存",
        "chat-cache-bytedance": "办公缓存",
        "chat-cache-doubao-browser": "办公缓存",
        "chat-cache-doubao-work": "办公缓存",
        "chat-cache-alibaba": "办公缓存",
        "office-cache-kingsoft": "文档缓存",
        "office-cache-kingsoft-sandbox": "文档缓存",
        "browser-edge-cache": "浏览器",
        "browser-edge-legacy": "浏览器",
        "browser-edge-app": "浏览器",
        "browser-arc-cache": "浏览器",
        "mail-downloads": "邮件附件",
        "adobe-media-cache": "媒体缓存",
        "premiere-media-cache": "媒体缓存",
        "davinci-render-cache": "媒体缓存",
        "homebrew-cache": "开发工具",
        "pip-cache": "开发工具",
        "protected-ios-backup": "你的备份",
        "protected-photos-library": "你的照片",
        "protected-messages": "你的聊天记录",
        "protected-safari": "浏览器数据"
    ]
}
