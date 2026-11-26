import Foundation

/// 启动项来源范围。系统级项一律 protected：不引导普通用户去动它们。
public enum StartupScope: String, Codable, Sendable, CaseIterable {
    case userAgent
    case systemAgent
    case systemDaemon
    case loginItem

    public var chineseName: String {
        switch self {
        case .userAgent: return "当前用户的登录项"
        case .systemAgent: return "系统级登录项"
        case .systemDaemon: return "系统后台服务"
        case .loginItem: return "系统设置里的登录项"
        }
    }
}

/// 只读读到的原始 plist。测试可以注入假数据，真实读取只走 StartupFileSystemReader。
public struct StartupPlist: Sendable {
    public let path: String
    public let scope: StartupScope
    public let data: Data

    public init(path: String, scope: StartupScope, data: Data) {
        self.path = path
        self.scope = scope
        self.data = data
    }
}

public struct StartupReadResult: Sendable {
    public let plists: [StartupPlist]
    public let gaps: [InspectionGap]
    public init(plists: [StartupPlist], gaps: [InspectionGap] = []) {
        self.plists = plists
        self.gaps = gaps
    }
}

public protocol StartupReading: Sendable {
    func readPlists() -> StartupReadResult
}

/// 一条已经翻译过的启动项。原始标签与路径保留在详情里。
public struct StartupItem: Codable, Hashable, Sendable, Identifiable {
    public let displayName: String
    public let rawLabel: String
    public let scope: StartupScope
    public let sourceApp: String
    public let rawCommand: String
    public let launchMethod: String
    public let risk: RiskLevel
    public let why: String
    public let suggestion: String
    public let rawPath: String

    public var id: String { rawPath }
}

public struct StartupSnapshot: Codable, Sendable {
    public let items: [StartupItem]
    public let gaps: [InspectionGap]
    public let collectedAt: Date
    public let sourceLabel: String

    public var isComplete: Bool { gaps.allSatisfy { !$0.blocksResult } }

    /// 去重口径：来源范围 + 显示名 + 原始标识。
    /// 只按中文显示名去重会把同名但不同命令的登录项错误合并。
    public var deduplicatedItems: [StartupItem] {
        var seen = Set<String>()
        return items.filter {
            seen.insert("\($0.scope.rawValue)|\($0.displayName)|\($0.rawLabel)").inserted
        }
    }

    public init(items: [StartupItem], gaps: [InspectionGap], collectedAt: Date = Date(), sourceLabel: String) {
        self.items = items
        self.gaps = gaps
        self.collectedAt = collectedAt
        self.sourceLabel = sourceLabel
    }
}

public struct StartupInspector: Sendable {
    public let reader: any StartupReading

    public init(reader: any StartupReading = StartupFileSystemReader()) {
        self.reader = reader
    }

    public func snapshot() -> StartupSnapshot {
        let result = reader.readPlists()
        var items: [StartupItem] = []
        var gaps = result.gaps

        for plist in result.plists {
            do {
                let object = try PropertyListSerialization.propertyList(from: plist.data, options: [], format: nil)
                guard let dict = object as? [String: Any] else {
                    throw InspectionError.malformed("顶层不是字典")
                }
                let label = (dict["Label"] as? String) ?? (dict["Name"] as? String) ?? "来源未知"
                let arguments = dict["ProgramArguments"] as? [String] ?? []
                let program = dict["Program"] as? String ?? ""
                let command = arguments.first ?? program
                let sourceApp = command.isEmpty ? "来源未知" : InspectionChineseNames.appName(for: command)
                let method = plist.scope == .loginItem
                    ? "在系统设置中设为登录时打开"
                    : Self.launchMethod(of: dict, scope: plist.scope)
                let risk: RiskLevel = {
                    if plist.scope == .systemDaemon || plist.scope == .systemAgent { return .protected }
                    if plist.scope == .loginItem { return .review }
                    if command.isEmpty { return .unknown }
                    return .review
                }()
                let why = "它在「\(plist.scope.chineseName)」里，\(method)。"
                let suggestion = risk == .protected
                    ? "这是系统级后台项，不建议自行关闭；本软件也不会替你改动。"
                    : "确认是你认识的程序后再决定；关闭必须去系统设置亲手操作。"

                items.append(StartupItem(
                    displayName: plist.scope == .loginItem
                        ? label
                        : InspectionChineseNames.serviceName(for: label),
                    rawLabel: label,
                    scope: plist.scope,
                    sourceApp: sourceApp,
                    rawCommand: command,
                    launchMethod: method,
                    risk: risk,
                    why: why,
                    suggestion: suggestion,
                    rawPath: plist.path
                ))
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                gaps.append(InspectionGap(
                    kind: .malformed,
                    message: "启动项配置读不懂（\(plist.path)）：\(reason)。已跳过，不猜测内容。",
                    blocksResult: false
                ))
            }
        }

        return StartupSnapshot(items: items, gaps: gaps, sourceLabel: "启动项配置（只读）")
    }

    private static func launchMethod(of dict: [String: Any], scope: StartupScope) -> String {
        if dict["RunAtLoad"] as? Bool == true { return "登录时自动启动" }
        if dict["StartInterval"] != nil || dict["StartCalendarInterval"] != nil { return "按设定时间运行" }
        if let keepAlive = dict["KeepAlive"] {
            if let flag = keepAlive as? Bool, flag { return "一直在后台运行" }
            if keepAlive is [String: Any] { return "一直在后台运行" }
        }
        if scope == .loginItem { return "在系统设置中设为登录时打开" }
        return "有需要时才运行"
    }
}

/// 只读枚举 LaunchAgents / LaunchDaemons，不写任何文件。
public struct StartupFileSystemReader: StartupReading, Sendable {
    public struct Directory: Sendable {
        public let path: String
        public let scope: StartupScope
        public let required: Bool

        public init(path: String, scope: StartupScope, required: Bool = false) {
            self.path = path
            self.scope = scope
            self.required = required
        }
    }

    public let directories: [Directory]
    /// 登录项数据库候选位置。macOS 13 及更早用用户目录里的 backgrounditems.btm；
    /// macOS 14+ 改到 /var/db/com.apple.backgroundtaskmanagement（需完全磁盘访问权限）。
    /// 测试可注入单一路径；默认遍历全部候选，读不到就明确报缺口，不静默留空。
    public let loginItemFileURLs: [URL]

    public init(directories: [Directory]? = nil, loginItemFileURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.directories = directories ?? [
            Directory(path: home.appendingPathComponent("Library/LaunchAgents").path, scope: .userAgent),
            Directory(path: "/Library/LaunchAgents", scope: .systemAgent),
            Directory(path: "/Library/LaunchDaemons", scope: .systemDaemon)
        ]
        if let injected = loginItemFileURL {
            self.loginItemFileURLs = [injected]
        } else {
            self.loginItemFileURLs = [
                home.appendingPathComponent("Library/Application Support/com.apple.backgroundtaskmanagementagent/backgrounditems.btm"),
                URL(fileURLWithPath: "/var/db/com.apple.backgroundtaskmanagement/backgrounditems.btm")
            ]
        }
    }

    public func readPlists() -> StartupReadResult {
        var plists: [StartupPlist] = []
        var gaps: [InspectionGap] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]

        for directory in directories {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                if directory.required {
                    gaps.append(InspectionGap(
                        kind: .unreadable,
                        message: "启动项目录不存在或不可读（\(directory.path)）。",
                        blocksResult: false
                    ))
                }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: directory.path),
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                gaps.append(InspectionGap(
                    kind: .unreadable,
                    message: "无法枚举启动项目录（\(directory.path)）。",
                    blocksResult: false
                ))
                continue
            }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "plist" else { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                do {
                    let data = try Data(contentsOf: url)  // 只读，不创建、不改写
                    plists.append(StartupPlist(path: url.path, scope: directory.scope, data: data))
                } catch {
                    gaps.append(InspectionGap(
                        kind: .unreadable,
                        message: "启动项配置读不到（\(url.path)）：\(error)。",
                        blocksResult: false
                    ))
                }
            }
        }

        // 登录项数据库：先按候选文件找，再按候选目录找里面的 .btm（macOS 14+ 新位置）。
        var loginFound = false
        var loginUnreadable = false
        for candidate in loginItemFileURLs {
            let files = Self.loginDatabaseFiles(at: candidate)
            guard !files.isEmpty else { continue }
            for file in files {
                do {
                    let data = try Data(contentsOf: file)
                    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    var names: Set<String> = []
                    Self.collectNames(from: object, into: &names, depth: 0)
                    if names.isEmpty {
                        loginFound = true
                    } else {
                        for name in names.sorted() {
                            let synthetic: [String: Any] = ["Name": name, "RunAtLoad": true]
                            let encoded = try PropertyListSerialization.data(
                                fromPropertyList: synthetic, format: .xml, options: 0
                            )
                            plists.append(StartupPlist(
                                path: "\(file.path)#\(name)", scope: .loginItem, data: encoded
                            ))
                            loginFound = true
                        }
                    }
                } catch {
                    loginUnreadable = true
                }
            }
        }
        // 读不到就明说，不留静默空白。注入单一路径的测试若读到名字则不受影响。
        if !loginFound {
            let hint = loginUnreadable
                ? "登录项数据库存在但读不到，通常是缺少完全磁盘访问权限。"
                : "没有找到登录项数据库（新版 macOS 在 /var/db/com.apple.backgroundtaskmanagement，需完全磁盘访问权限）。"
            gaps.append(InspectionGap(
                kind: .loginItemsNeedsSystemSettings,
                message: "\(hint)请到「系统设置 › 通用 › 登录项与扩展」查看；本软件不会替你修改。",
                blocksResult: false
            ))
        }

        return StartupReadResult(plists: plists, gaps: gaps)
    }

    /// 候选路径本身是 .btm 文件则直接用；是目录则找里面的 backgrounditems*.btm。
    private static func loginDatabaseFiles(at candidate: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return candidate.pathExtension.lowercased() == "btm" ? [candidate] : []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: candidate,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            let name = url.lastPathComponent.lowercased()
            return name.hasPrefix("backgrounditems") && name.hasSuffix(".btm") ? url : nil
        }
    }

    private static func collectNames(from value: Any, into names: inout Set<String>, depth: Int) {
        guard depth < 10 else { return }
        if let dict = value as? [String: Any] {
            for (key, raw) in dict {
                let lower = key.lowercased()
                if lower == "name" || lower == "displayname" || lower == "localizedname" || lower == "title",
                   let text = raw as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed.count < 120 { names.insert(trimmed) }
                }
                collectNames(from: raw, into: &names, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for item in array { collectNames(from: item, into: &names, depth: depth + 1) }
        }
    }
}
