import Foundation

/// 只读检查阶段的公共错误与缺口描述。
/// 原则：读不到就明说，绝不拿假数据填空。
public enum InspectionError: Error, LocalizedError, Sendable {
    case toolUnavailable(String)
    case readFailed(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case let .toolUnavailable(tool): return "缺少只读查询工具：\(tool)"
        case let .readFailed(reason): return "只读读取失败：\(reason)"
        case let .malformed(reason): return "数据格式无法识别：\(reason)"
        }
    }
}

public struct InspectionGap: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case tccDenied
        case databaseMissing
        case unreadable
        case malformed
        case toolUnavailable
        case loginItemsNeedsSystemSettings
        case other
    }

    public let kind: Kind
    public let message: String
    /// 为 true 时界面必须显示"无法列出"，不能只显示空列表。
    public let blocksResult: Bool

    public var id: String { "\(kind.rawValue)-\(message)" }

    public init(kind: Kind, message: String, blocksResult: Bool = true) {
        self.kind = kind
        self.message = message
        self.blocksResult = blocksResult
    }
}

/// 英文原始标识 → 中文显示名。 Core 不依赖 AppKit，只做静态对照；
/// 查不到时返回"未知程序"/"后台服务（原文见详情）"，原始标识另存字段供用户折叠查看。
/// 匹配策略：按 key 长度降序取最长命中，避免 "hedge" 被 "edge" 这类短子串误命中。
public enum InspectionChineseNames {
    public static func appName(for client: String) -> String {
        longestMatch(client.lowercased(), in: appNames) ?? "未知程序"
    }

    public static func serviceName(for label: String) -> String {
        let key = label.lowercased()
        if let hit = longestMatch(key, in: serviceNames) { return hit }
        for (token, name) in serviceFallbacks where key.contains(token) { return name }
        return "后台服务（原文见详情）"
    }

    /// 具体词优先：先按长度降序，长 key 命中即返回。
    private static func longestMatch(_ text: String, in dict: [String: String]) -> String? {
        for (key, value) in dict.sorted(by: { $0.key.count > $1.key.count }) {
            if text.contains(key) { return value }
        }
        return nil
    }

    // 程序名词典。刻意不放裸 "edge"：否则 nl.syncfactory.HedgeHelper 会被认成 Edge 浏览器。
    private static let appNames: [String: String] = [
        "com.tencent.wechat": "微信", "wechat": "微信",
        "com.tencent.qq": "QQ", "qq": "QQ",
        "com.apple.safari": "Safari 浏览器", "safari": "Safari 浏览器",
        "com.google.chrome": "Chrome 浏览器", "chrome": "Chrome 浏览器",
        "com.microsoft.edgemac": "Edge 浏览器",
        "com.microsoft.edgeupdater": "Edge 浏览器更新服务",
        "msedge": "Edge 浏览器", "microsoft edge": "Edge 浏览器",
        "com.adobe.photoshop": "Adobe Photoshop（图像编辑）",
        "com.adobe.acrobat": "Adobe Acrobat（PDF 工具）",
        "com.adobe": "Adobe 软件", "adobe": "Adobe 软件",
        "com.microsoft": "微软软件", "microsoft": "微软软件",
        "com.sogou": "搜狗输入法", "sogou": "搜狗输入法",
        "com.maxon": "Maxon 软件（Cinema 4D 等）", "maxon": "Maxon 软件",
        "cleanmymac": "CleanMyMac", "clashx": "ClashX 代理工具",
        "v2ray": "V2Ray 网络代理工具", "hedgehelper": "Hedge 同步工具",
        "redgiant": "Red Giant 影视插件", "fxfactory": "FxFactory 影视插件",
        "aescripts": "Adobe 扩展脚本", "zxp-installer": "Adobe 扩展安装器",
        "rlm": "RLM 软件授权服务", "prograde": "ProGrade 工具",
        "com.apple.terminal": "终端", "com.apple.finder": "访达", "finder": "访达",
        "com.apple.mail": "邮件", "com.spotify.client": "Spotify 音乐",
        "com.valvesoftware.steam": "Steam 游戏平台"
    ]

    // 后台服务词典。key 覆盖本机实测的全部 LaunchAgents/Daemons 标签。
    private static let serviceNames: [String: String] = [
        "com.adobe.update": "Adobe 更新服务",
        "com.adobe.gc": "Adobe 正版验证服务",
        "adobe_genuine_software_integrity": "Adobe 正版验证服务",
        "com.adobe.adobecreativecloud": "Adobe 创意云服务",
        "com.adobe.adobedesktopservice": "Adobe 桌面服务",
        "com.adobe.acc.installer": "Adobe 安装服务",
        "com.adobe.ccxprocess": "Adobe 创意云体验服务",
        "aescripts": "Adobe 扩展安装服务",
        "com.google.keystone": "谷歌软件更新助手",
        "com.microsoft.autoupdate": "微软软件更新助手",
        "com.microsoft.update": "微软软件更新服务",
        "com.microsoft.edgeupdater": "Edge 浏览器更新服务",
        "com.microsoft.office.licensing": "微软 Office 授权服务",
        "com.maxon": "Maxon 软件服务（Cinema 4D 等）",
        "com.sogou": "搜狗输入法服务",
        "com.macpaw.cleanmymac": "CleanMyMac 后台服务",
        "com.west2online.clashx": "ClashX Pro 代理服务",
        "yanue.v2rayu": "V2RayU 网络代理服务",
        "com.rlmlicenseserver": "RLM 软件授权服务",
        "com.prograde": "ProGrade 工具服务",
        "com.redgiant": "Red Giant 影视插件服务",
        "com.fxfactory": "FxFactory 影视插件服务",
        "nl.syncfactory.hedgehelper": "Hedge 同步工具服务",
        "com.apple.timemachine": "时间机器备份服务",
        "com.apple.backupd": "时间机器备份服务",
        "com.apple.smbd": "文件共享服务",
        "com.openssh.sshd": "远程登录服务",
        "inputmethod": "输入法相关服务"
    ]

    private static let serviceFallbacks: [(String, String)] = [
        ("update", "软件更新服务"), ("license", "软件授权服务"),
        ("input", "输入法相关服务"), ("backup", "备份相关服务"),
        ("apple", "苹果系统服务"), ("helper", "系统辅助服务")
    ]
}
