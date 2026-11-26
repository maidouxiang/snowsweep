import Foundation

/// 扫描范围。它决定"看多远"，不决定"能删什么"。
/// 判定仍然完全由规则引擎和保护清单负责；扩大范围绝不会让受保护路径变得可删。
public enum ScanScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case userOnly
    case wholeDisk

    public var id: String { rawValue }

    public var chineseName: String {
        switch self {
        case .userOnly: return "仅我的用户目录"
        case .wholeDisk: return "整个磁盘"
        }
    }

    public var explain: String {
        switch self {
        case .userOnly:
            return "只看你自己的用户文件夹。日常清理用这个，绝大多数可清理缓存都在这里。"
        case .wholeDisk:
            return "连系统卷和其他位置一起看。只读扫描，不会扩大删除权限；受保护路径依然不会进入清理候选。"
        }
    }

    /// 扫描根目录。userOnly 显式收敛到当前用户家目录，避免"顺手"扫到别人的文件。
    public func rootPath(home: String = NSHomeDirectory()) -> String {
        switch self {
        case .userOnly: return NSString(string: home).standardizingPath
        case .wholeDisk: return "/"
        }
    }

    public static let `default`: ScanScope = .userOnly
}

/// 完全磁盘访问（FDA）状态的**只读可视化**。
/// 严格区分三件事，绝不混为一谈：
/// 1. 系统授权数据库里有没有 SnowSweep 自己的 FDA 记录；
/// 2. 数据库能不能读到（能读到不等于本 App 有 FDA，可能是给了终端或辅助程序）；
/// 3. 用户选的扫描范围有多大（选择权在用户，不由授权状态决定）。
public enum FDAScopeStatus: Sendable, Equatable {
    case grantedToApp
    case databaseReadableWithoutAppGrant
    case inferredGrant
    case blocked
    case notChecked

    public var title: String {
        switch self {
        case .grantedToApp: return "本软件已获得完全磁盘访问授权"
        case .databaseReadableWithoutAppGrant: return "授权数据库可读，但没看到本软件自己的全盘授权"
        case .inferredGrant: return "受保护目录可读：本软件应已获得完全磁盘访问"
        case .blocked: return "系统授权数据库读不到，部分目录会被跳过"
        case .notChecked: return "还没有读取权限清单"
        }
    }

    public var explain: String {
        switch self {
        case .grantedToApp:
            return "系统允许本软件读取整个磁盘。默认仍只扫描你的用户目录；想看全盘由你在设置里主动切换。"
        case .databaseReadableWithoutAppGrant:
            return "能读到数据库不代表本软件拿到了全盘授权。权限清单里列出的授权属于其他程序；本软件不会因此扩大扫描范围。"
        case .inferredGrant:
            return "系统授权数据库本身被 SIP 或 root 独占，读不到；但雪已能打开 Safari、邮件等受保护目录，说明系统实际放行了完全磁盘访问。这是行为探测，不是数据库确认。"
        case .blocked:
            return "缺少必要授权时扫描报告会被标记不完整，清理会自动锁定。要到系统设置亲手开启，本软件不会代劳。"
        case .notChecked:
            return "到「权限清单」点一次重新读取，就能看到本机的授权状况。"
        }
    }

    public var isHealthy: Bool {
        switch self {
        case .grantedToApp, .databaseReadableWithoutAppGrant, .inferredGrant: return true
        case .blocked, .notChecked: return false
        }
    }
}

public enum FDAScopeInspector: Sendable {
    /// 从只读权限快照推导状态。默认同时匹配对外名与 bundle id；
    /// 测试可以注入任意标识来验证匹配逻辑，不需要真实 TCC 数据库。
    public static func status(
        from snapshot: PermissionSnapshot?,
        appTokens: [String] = [SnowIdentity.displayName, SnowIdentity.bundleIdentifier]
    ) -> FDAScopeStatus {
        guard let snapshot else { return .notChecked }
        guard !snapshot.gaps.contains(where: { $0.blocksResult }) else { return .blocked }
        let hasAppGrant = snapshot.grants.contains { grant in
            grant.permissionName == "完全磁盘访问" &&
            appTokens.contains { token in
                !token.isEmpty &&
                (grant.rawClient.localizedCaseInsensitiveContains(token) ||
                 grant.appName.localizedCaseInsensitiveContains(token))
            }
        }
        return hasAppGrant ? .grantedToApp : .databaseReadableWithoutAppGrant
    }
}
