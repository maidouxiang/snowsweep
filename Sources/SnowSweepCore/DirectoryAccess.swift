import Foundation
import Darwin

/// 一个受限目录的只读探测结果。只检查“能不能列出目录”，不读取文件内容，
/// 也不根据目录里有什么去推断用户隐私。
public struct RestrictedDirectoryStatus: Codable, Hashable, Sendable, Identifiable {
    public let path: String
    public let chineseName: String
    public let impact: String
    public let permissionHint: String
    public let exists: Bool
    public let readable: Bool
    /// false 表示没有足够权限去验证，不能把“没测到”说成“读不到”。
    public let verified: Bool
    public let checkedAt: Date

    public var id: String { path }

    public var stateLabel: String {
        if !exists { return "目录不存在" }
        if !verified { return "未验证" }
        return readable ? "可读取" : "读不到"
    }

    public var stateExplain: String {
        if !exists {
            return "本机没有这个目录，不是权限失败。"
        }
        if !verified {
            return "没有足够权限确认这个目录，先按“未验证”处理，不会冒充已检查。\(permissionHint)"
        }
        if readable {
            return "当前可列出目录，扫描不会在这里留下权限缺口。"
        }
        return "目录存在但列不出内容。\(permissionHint)"
    }

    public init(
        path: String,
        chineseName: String,
        impact: String,
        permissionHint: String,
        exists: Bool,
        readable: Bool,
        verified: Bool = true,
        checkedAt: Date = Date()
    ) {
        self.path = path
        self.chineseName = chineseName
        self.impact = impact
        self.permissionHint = permissionHint
        self.exists = exists
        self.readable = readable
        self.verified = verified
        self.checkedAt = checkedAt
    }
}

public struct DirectoryAccessSnapshot: Codable, Sendable {
    public let directories: [RestrictedDirectoryStatus]
    public let collectedAt: Date
    /// 是否已经拿到完全磁盘访问权限（以能否读取 TCC 授权库为只读探针）。
    public let hasFullDiskAccess: Bool

    public var unreadableCount: Int {
        directories.filter { $0.exists && $0.verified && !$0.readable }.count
    }

    public var unverifiedCount: Int {
        directories.filter { $0.exists && !$0.verified }.count
    }

    public init(
        directories: [RestrictedDirectoryStatus],
        collectedAt: Date = Date(),
        hasFullDiskAccess: Bool = false
    ) {
        self.directories = directories
        self.collectedAt = collectedAt
        self.hasFullDiskAccess = hasFullDiskAccess
    }
}

public protocol DirectoryAccessChecking: Sendable {
    func exists(_ path: String) -> Bool
    func canList(_ path: String) -> Bool
}

public struct SystemDirectoryAccessChecker: DirectoryAccessChecking {
    public init() {}

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func canList(_ path: String) -> Bool {
        // 只打开目录读一个目录项，不枚举全部内容。调用方只对普通目录用它；
        // 照片图库 / 邮件 / 信息 / Safari / 手机备份不走这里，避免被 iCloud
        // 或授权提示无限阻塞。
        guard let handle = opendir(path) else { return false }
        defer { closedir(handle) }
        errno = 0
        let first = readdir(handle)
        return first != nil || errno == 0
    }
}

/// 权限页的固定目录清单。选的是“缺权限会直接影响清理判断”的位置，
/// 每个目录都写清楚会漏掉什么，而不是只抛一个系统错误码。
public enum RestrictedDirectoryCatalog {
    public enum Probe: Sendable {
        case openDirectory
        case fullDiskAccess
        case photoLibrary
    }

    public struct Definition: Sendable {
        public let relativePath: String
        public let chineseName: String
        public let impact: String
        public let permissionHint: String
        public let probe: Probe

        public init(
            relativePath: String,
            chineseName: String,
            impact: String,
            permissionHint: String,
            probe: Probe = .openDirectory
        ) {
            self.relativePath = relativePath
            self.chineseName = chineseName
            self.impact = impact
            self.permissionHint = permissionHint
            self.probe = probe
        }
    }

    public static let definitions: [Definition] = [
        .init(relativePath: "Desktop", chineseName: "桌面",
              impact: "桌面上未下载的 iCloud 文件、临时安装包和大文件可能漏扫。",
              permissionHint: "到「隐私与安全性 › 文件和文件夹」允许雪访问桌面。"),
        .init(relativePath: "Documents", chineseName: "文稿",
              impact: "工作文档、导出素材和旧备份可能漏扫，空间报告会偏小。",
              permissionHint: "到「隐私与安全性 › 文件和文件夹」允许雪访问文稿。"),
        .init(relativePath: "Downloads", chineseName: "下载",
              impact: "安装包、下载缓存和大文件可能漏扫，无法判断它们是否可清理。",
              permissionHint: "到「隐私与安全性 › 文件和文件夹」允许雪访问下载。"),
        .init(relativePath: "Pictures/Photos Library.photoslibrary", chineseName: "照片图库",
              impact: "照片图库整体体积无法确认；不会读取照片内容。",
              permissionHint: "到「隐私与安全性 › 照片」允许雪访问照片图库。",
              probe: .photoLibrary),
        .init(relativePath: "Library/Mail", chineseName: "邮件数据",
              impact: "邮件附件与本地邮件缓存可能漏扫，释放空间会被低估。",
              permissionHint: "到「隐私与安全性 › 完全磁盘访问权限」允许雪读取邮件数据。",
              probe: .fullDiskAccess),
        .init(relativePath: "Library/Messages", chineseName: "信息附件",
              impact: "信息里的图片、视频与附件缓存可能漏扫。",
              permissionHint: "到「隐私与安全性 › 完全磁盘访问权限」允许雪读取信息数据。",
              probe: .fullDiskAccess),
        .init(relativePath: "Library/Safari", chineseName: "Safari 数据",
              impact: "浏览器缓存与下载记录可能漏扫，无法给出准确的可释放空间。",
              permissionHint: "到「隐私与安全性 › 完全磁盘访问权限」允许雪读取 Safari 数据。",
              probe: .fullDiskAccess),
        .init(relativePath: "Library/Application Support/MobileSync", chineseName: "手机备份",
              impact: "iPhone/iPad 本地备份可能漏扫；这类数据只提示，不会自动选中。",
              permissionHint: "到「隐私与安全性 › 完全磁盘访问权限」允许雪读取手机备份。",
              probe: .fullDiskAccess)
    ]

    public static func snapshot(
        home: String = NSHomeDirectory(),
        checker: any DirectoryAccessChecking = SystemDirectoryAccessChecker(),
        hasFullDiskAccess: Bool = false,
        at date: Date = Date()
    ) -> DirectoryAccessSnapshot {
        let rows = definitions.map { definition -> RestrictedDirectoryStatus in
            let path = URL(fileURLWithPath: home).appendingPathComponent(definition.relativePath).path
            switch definition.probe {
            case .openDirectory:
                let exists = checker.exists(path)
                let readable = exists && checker.canList(path)
                return RestrictedDirectoryStatus(
                    path: path, chineseName: definition.chineseName,
                    impact: definition.impact, permissionHint: definition.permissionHint,
                    exists: exists, readable: readable, verified: true, checkedAt: date
                )
            case .fullDiskAccess:
                // 不看、不 stat 这些目录本身；没有 FDA 时连“存在”都可能触发授权。
                let readable = hasFullDiskAccess && checker.canList(path)
                return RestrictedDirectoryStatus(
                    path: path, chineseName: definition.chineseName,
                    impact: definition.impact, permissionHint: definition.permissionHint,
                    exists: true, readable: readable, verified: hasFullDiskAccess, checkedAt: date
                )
            case .photoLibrary:
                // 照片图库路径一碰就可能触发照片授权；本页完全不碰，
                // 明确显示“未验证”，而不是猜成读不到。
                return RestrictedDirectoryStatus(
                    path: path, chineseName: definition.chineseName,
                    impact: definition.impact, permissionHint: definition.permissionHint,
                    exists: true, readable: false, verified: false, checkedAt: date
                )
            }
        }
        return DirectoryAccessSnapshot(
            directories: rows,
            collectedAt: date,
            hasFullDiskAccess: hasFullDiskAccess
        )
    }
}
