import Foundation

/// 敏感权限种类。unknown 保留原始英文服务名，绝不猜成某个具体权限。
public enum PermissionKind: String, Codable, Sendable, CaseIterable {
    case camera
    case microphone
    case location
    case screenRecording
    case accessibility
    case fullDiskAccess
    case inputMonitoring
    case folders
    case bluetooth
    case motion
    case contacts
    case calendar
    case reminders
    case photos
    case appleEvents
    case other
}

/// 权限中文词典：一条权限 = 中文名 + 一句人话 + 为什么可能需要 + 建议。
public struct PermissionDefinition: Codable, Hashable, Sendable {
    public let tccService: String
    public let kind: PermissionKind
    public let zhName: String
    public let explain: String
    public let whyNeeded: String
    public let suggestion: String
    public let risk: RiskLevel
    public let settingsPath: String

    public init(
        tccService: String,
        kind: PermissionKind,
        zhName: String,
        explain: String,
        whyNeeded: String,
        suggestion: String,
        risk: RiskLevel,
        settingsPath: String
    ) {
        self.tccService = tccService
        self.kind = kind
        self.zhName = zhName
        self.explain = explain
        self.whyNeeded = whyNeeded
        self.suggestion = suggestion
        self.risk = risk
        self.settingsPath = settingsPath
    }
}

public enum PermissionCatalog {
    public static let all: [PermissionDefinition] = [
        .init(tccService: "kTCCServiceCamera", kind: .camera,
              zhName: "摄像头",
              explain: "允许程序打开摄像头拍画面。",
              whyNeeded: "视频通话、扫码、人脸识别会用到。",
              suggestion: "不用视频的程序却申请了，建议去系统设置关掉。",
              risk: .review, settingsPath: "隐私与安全性 › 摄像头"),
        .init(tccService: "kTCCServiceMicrophone", kind: .microphone,
              zhName: "麦克风",
              explain: "允许程序听到你说话。",
              whyNeeded: "语音通话、录音、语音输入会用到。",
              suggestion: "不讲话的程序却申请了，建议复核。",
              risk: .review, settingsPath: "隐私与安全性 › 麦克风"),
        .init(tccService: "kTCCServiceLocation", kind: .location,
              zhName: "定位服务",
              explain: "允许程序知道你大概在哪。",
              whyNeeded: "地图、天气、打车会用到。",
              suggestion: "与位置无关的程序建议关掉。",
              risk: .review, settingsPath: "隐私与安全性 › 定位服务"),
        .init(tccService: "kTCCServiceScreenCapture", kind: .screenRecording,
              zhName: "屏幕录制",
              explain: "允许程序看到或录下你的屏幕。",
              whyNeeded: "录屏、远程协助、截图工具会用到。",
              suggestion: "权限很大，不该有的建议关掉。",
              risk: .protected, settingsPath: "隐私与安全性 › 屏幕与系统音频录制"),
        .init(tccService: "kTCCServiceAccessibility", kind: .accessibility,
              zhName: "辅助功能",
              explain: "允许程序模拟点击、读取别的软件界面。",
              whyNeeded: "输入法、自动化工具会用到。",
              suggestion: "权限很大，只留你确实认识的程序。",
              risk: .protected, settingsPath: "隐私与安全性 › 辅助功能"),
        .init(tccService: "kTCCServiceSystemPolicyAllFiles", kind: .fullDiskAccess,
              zhName: "完全磁盘访问",
              explain: "允许程序读取几乎整个硬盘。",
              whyNeeded: "备份、清理、杀毒工具会申请。",
              suggestion: "只给真正需要的工具，用完可以关掉。",
              risk: .protected, settingsPath: "隐私与安全性 › 完全磁盘访问权限"),
        .init(tccService: "kTCCServiceListenEvents", kind: .inputMonitoring,
              zhName: "输入监控",
              explain: "允许程序监听你的键盘输入。",
              whyNeeded: "按键映射、游戏宏工具会用到。",
              suggestion: "敏感权限，不认识的程序建议关掉。",
              risk: .protected, settingsPath: "隐私与安全性 › 输入监控"),
        .init(tccService: "kTCCServiceSystemPolicyDesktopFolder", kind: .folders,
              zhName: "桌面文件夹访问",
              explain: "允许程序读取桌面上的文件。",
              whyNeeded: "网盘同步、文件管理工具会用到。",
              suggestion: "按实际需要保留或关掉。",
              risk: .review, settingsPath: "隐私与安全性 › 文件和文件夹"),
        .init(tccService: "kTCCServiceSystemPolicyDocumentsFolder", kind: .folders,
              zhName: "文稿文件夹访问",
              explain: "允许程序读取文稿文件夹里的文件。",
              whyNeeded: "文档同步、编辑器会用到。",
              suggestion: "按实际需要保留或关掉。",
              risk: .review, settingsPath: "隐私与安全性 › 文件和文件夹"),
        .init(tccService: "kTCCServiceBluetoothPeripheral", kind: .bluetooth,
              zhName: "蓝牙设备",
              explain: "允许程序连接蓝牙配件。",
              whyNeeded: "耳机、鼠标、手环配套软件会用到。",
              suggestion: "不使用蓝牙的程序建议关掉。",
              risk: .review, settingsPath: "隐私与安全性 › 蓝牙"),
        .init(tccService: "kTCCServiceMotion", kind: .motion,
              zhName: "运动与方向",
              explain: "允许程序读取设备的运动数据。",
              whyNeeded: "健身、指南针类程序会用到。",
              suggestion: "与运动无关的程序建议关掉。",
              risk: .review, settingsPath: "隐私与安全性 › 运动与方向"),
        .init(tccService: "kTCCServiceAddressBook", kind: .contacts,
              zhName: "通讯录",
              explain: "允许程序读取你的联系人。",
              whyNeeded: "聊天、邮件客户端会用到。",
              suggestion: "不需要同步联系人的程序建议关掉。",
              risk: .review, settingsPath: "隐私与安全性 › 通讯录"),
        .init(tccService: "kTCCServiceCalendar", kind: .calendar,
              zhName: "日历",
              explain: "允许程序读取你的日程。",
              whyNeeded: "日程管理、会议软件会用到。",
              suggestion: "不用日程的程序建议关掉。",
              risk: .review, settingsPath: "隐私与安全性 › 日历"),
        .init(tccService: "kTCCServiceReminders", kind: .reminders,
              zhName: "提醒事项",
              explain: "允许程序读取你的待办清单。",
              whyNeeded: "任务管理工具会用到。",
              suggestion: "不用提醒事项的程序建议关掉。",
              risk: .review, settingsPath: "隐私与安全性 › 提醒事项"),
        .init(tccService: "kTCCServicePhotos", kind: .photos,
              zhName: "照片",
              explain: "允许程序读取你的照片库。",
              whyNeeded: "图片编辑、备份工具会用到。",
              suggestion: "不需要修图的程序建议关掉。",
              risk: .review, settingsPath: "隐私与安全性 › 照片"),
        .init(tccService: "kTCCServiceAppleEvents", kind: .appleEvents,
              zhName: "控制其他软件",
              explain: "允许程序给别的软件发指令。",
              whyNeeded: "自动化、快捷键工具会用到。",
              suggestion: "不认识的程序建议关掉。",
              risk: .review, settingsPath: "隐私与安全性 › 自动化")
    ]

    public static let byService: [String: PermissionDefinition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.tccService, $0) }
    )

    public static func definition(forService service: String) -> PermissionDefinition? {
        byService[service]
    }
}

/// TCC 数据库里的一行原始授权（只含只读查询得到的字段）。
public struct PermissionRawGrant: Codable, Hashable, Sendable {
    public let service: String
    public let client: String
    public let authValue: Int
    public let clientType: Int
    public let database: String

    public init(service: String, client: String, authValue: Int, clientType: Int, database: String) {
        self.service = service
        self.client = client
        self.authValue = authValue
        self.clientType = clientType
        self.database = database
    }
}

public struct PermissionReadResult: Sendable {
    public let grants: [PermissionRawGrant]
    public let gaps: [InspectionGap]
    public init(grants: [PermissionRawGrant], gaps: [InspectionGap] = []) {
        self.grants = grants
        self.gaps = gaps
    }
}

public protocol PermissionReading: Sendable {
    func readGrants() -> PermissionReadResult
}

/// 已经翻译成中文的一条授权；原始英文服务名与程序标识单独保留供折叠查看。
public struct PermissionGrant: Codable, Hashable, Sendable, Identifiable {
    public let appName: String
    public let rawClient: String
    public let permissionName: String
    public let rawService: String
    public let explain: String
    public let whyNeeded: String
    public let suggestion: String
    public let risk: RiskLevel
    public let settingsPath: String
    public let granted: Bool
    public let database: String

    public var id: String { "\(database)|\(rawService)|\(rawClient)" }
}

public struct PermissionSnapshot: Codable, Sendable {
    public let grants: [PermissionGrant]
    public let gaps: [InspectionGap]
    public let collectedAt: Date
    public let sourceLabel: String

    public var isComplete: Bool { gaps.allSatisfy { !$0.blocksResult } }

    public init(grants: [PermissionGrant], gaps: [InspectionGap], collectedAt: Date = Date(), sourceLabel: String) {
        self.grants = grants
        self.gaps = gaps
        self.collectedAt = collectedAt
        self.sourceLabel = sourceLabel
    }
}

public struct PermissionInspector: Sendable {
    public let reader: any PermissionReading

    public init(reader: any PermissionReading = TCCDatabaseReader()) {
        self.reader = reader
    }

    public func snapshot() -> PermissionSnapshot {
        let result = reader.readGrants()
        // auth_value: 0=拒绝 1=未知 2=允许 3=受限。只列出已授权项。
        let grants = result.grants.compactMap { raw -> PermissionGrant? in
            guard raw.authValue >= 2 else { return nil }
            let definition = PermissionCatalog.definition(forService: raw.service)
            return PermissionGrant(
                appName: InspectionChineseNames.appName(for: raw.client),
                rawClient: raw.client,
                permissionName: definition?.zhName ?? "未知权限（原文见详情）",
                rawService: raw.service,
                explain: definition?.explain ?? "这台 Mac 上有程序申请了这个权限，但词典里还没有它。",
                whyNeeded: definition?.whyNeeded ?? "暂时无法判断用途，建议先查原始名称。",
                suggestion: definition?.suggestion ?? "不认识就先不要改，查清楚再说。",
                risk: definition?.risk ?? .unknown,
                settingsPath: definition?.settingsPath ?? "系统设置 › 隐私与安全性",
                granted: true,
                database: raw.database
            )
        }
        return PermissionSnapshot(
            grants: grants,
            gaps: result.gaps,
            sourceLabel: "系统授权数据库（只读）"
        )
    }
}

/// 用系统自带 sqlite3 只读打开 TCC 数据库。
/// 只有 SELECT，且显式带 -readonly 与 query_only，不允许任何写操作。
public struct TCCDatabaseReader: PermissionReading, Sendable {
    public let databasePaths: [String]

    public init(databasePaths: [String]? = nil) {
        if let paths = databasePaths {
            self.databasePaths = paths
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.databasePaths = [
                home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
                "/Library/Application Support/com.apple.TCC/TCC.db"
            ]
        }
    }

    public static let selectSQL = "PRAGMA query_only=ON; SELECT service, client, auth_value, client_type FROM access;"
    public static let sqliteToolPath = "/usr/bin/sqlite3"

    public static func sqliteArguments(databasePath: String, sql: String) -> [String] {
        ["-bail", "-readonly", "-separator", "\t", databasePath, sql]
    }

    public func readGrants() -> PermissionReadResult {
        guard FileManager.default.isExecutableFile(atPath: Self.sqliteToolPath) else {
            return PermissionReadResult(grants: [], gaps: [
                InspectionGap(kind: .toolUnavailable, message: "找不到系统自带 sqlite3，无法只读查询授权。")
            ])
        }

        var grants: [PermissionRawGrant] = []
        var gaps: [InspectionGap] = []
        for path in databasePaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                grants.append(contentsOf: try Self.query(path: path))
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                gaps.append(InspectionGap(
                    kind: reason.contains("denied") || reason.contains("授权") ? .tccDenied : .unreadable,
                    message: "权限数据库读不到（\(path)）：\(reason)。请在系统设置授予完全磁盘访问权限。",
                    blocksResult: true
                ))
            }
        }
        if grants.isEmpty && gaps.isEmpty {
            gaps.append(InspectionGap(
                kind: .databaseMissing,
                message: "没有找到系统授权数据库，无法列出已授权程序。",
                blocksResult: true
            ))
        }
        // 有部分数据时保留缺口说明，但不能让"读不到"遮住已读到的内容。
        let adjusted = grants.isEmpty ? gaps : gaps.map {
            InspectionGap(kind: $0.kind, message: $0.message, blocksResult: false)
        }
        return PermissionReadResult(grants: grants, gaps: adjusted)
    }

    private static func query(path: String) throws -> [PermissionRawGrant] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqliteToolPath)
        process.arguments = sqliteArguments(databasePath: path, sql: selectSQL)
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw InspectionError.readFailed(reason.isEmpty ? "sqlite3 退出码 \(process.terminationStatus)" : reason)
        }
        let text = String(decoding: data, as: UTF8.self)
        let databaseLabel = path.contains("/Library/Application Support/") && !path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path)
            ? "系统级授权" : "用户级授权"
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { return nil }
            return PermissionRawGrant(
                service: fields[0],
                client: fields[1],
                authValue: Int(fields[2]) ?? 0,
                clientType: Int(fields[3]) ?? 0,
                database: databaseLabel
            )
        }
    }
}
