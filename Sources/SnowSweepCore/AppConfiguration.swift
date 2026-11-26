import Foundation

/// 存储显示单位。自动沿用系统风格；固定单位用于需要横向比较大小的场景。
public enum DisplayUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case megabyte
    case gigabyte

    public var id: String { rawValue }

    public var chineseName: String {
        switch self {
        case .auto: return "自动"
        case .megabyte: return "MB"
        case .gigabyte: return "GB"
        }
    }

    /// 十进制口径，与磁盘容量和概览页的 GB 保持一致。
    public func format(bytes: Int64) -> String {
        let value = max(0, bytes)
        switch self {
        case .auto:
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB, .useKB]
            formatter.countStyle = .file
            formatter.includesUnit = true
            return formatter.string(fromByteCount: value)
        case .megabyte:
            return String(format: "%.1f MB", Double(value) / 1_000_000)
        case .gigabyte:
            return String(format: "%.2f GB", Double(value) / 1_000_000_000)
        }
    }
}

/// 菜单栏快速面板的模块与提醒开关。只影响显示，不影响扫描、判定或清理。
public struct MenuBarPreferences: Codable, Equatable, Sendable {
    public var showDiskSpace: Bool
    public var showMemory: Bool
    public var showBattery: Bool
    public var showQuickClean: Bool
    public var showBadge: Bool

    public init(
        showDiskSpace: Bool = true,
        showMemory: Bool = true,
        showBattery: Bool = true,
        showQuickClean: Bool = true,
        showBadge: Bool = true
    ) {
        self.showDiskSpace = showDiskSpace
        self.showMemory = showMemory
        self.showBattery = showBattery
        self.showQuickClean = showQuickClean
        self.showBadge = showBadge
    }

    public static let `default` = MenuBarPreferences()

    private enum CodingKeys: String, CodingKey {
        case showDiskSpace, showMemory, showBattery, showQuickClean, showBadge
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showDiskSpace = try c.decodeIfPresent(Bool.self, forKey: .showDiskSpace) ?? true
        showMemory = try c.decodeIfPresent(Bool.self, forKey: .showMemory) ?? true
        showBattery = try c.decodeIfPresent(Bool.self, forKey: .showBattery) ?? true
        showQuickClean = try c.decodeIfPresent(Bool.self, forKey: .showQuickClean) ?? true
        showBadge = try c.decodeIfPresent(Bool.self, forKey: .showBadge) ?? true
    }

    public static let storageKey = "snow.menuBar.preferences"

    public static func load(from defaults: UserDefaults = .standard) -> MenuBarPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(MenuBarPreferences.self, from: data)
        else { return .default }
        return decoded
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// 可导入导出的本机配置。只含偏好、保护路径和显示口径，不含任何用户文件内容。
public struct AppConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 3

    public var version: Int
    public var customProtections: [String]
    public var aiMode: String
    public var showDockIcon: Bool
    public var displayUnit: DisplayUnit
    public var scanScope: String
    public var menuBar: MenuBarPreferences
    public var dailyJournalEnabled: Bool
    public var runMode: String
    /// V0.8.0：默认开着英文原名，关闭后主界面只留中文，原始路径折叠到「查看原始路径」。
    public var showEnglishOriginal: Bool

    public init(
        version: Int = AppConfiguration.currentVersion,
        customProtections: [String] = [],
        aiMode: String = "off",
        showDockIcon: Bool = true,
        displayUnit: DisplayUnit = .auto,
        scanScope: String = "userOnly",
        menuBar: MenuBarPreferences = .default,
        dailyJournalEnabled: Bool = true,
        runMode: String = "silent",
        showEnglishOriginal: Bool = true
    ) {
        self.version = version
        self.customProtections = customProtections
        self.aiMode = aiMode
        self.showDockIcon = showDockIcon
        self.displayUnit = displayUnit
        self.scanScope = scanScope
        self.menuBar = menuBar
        self.dailyJournalEnabled = dailyJournalEnabled
        self.runMode = RunMode(rawValue: runMode)?.rawValue ?? "silent"
        self.showEnglishOriginal = showEnglishOriginal
    }

    private enum CodingKeys: String, CodingKey {
        case version, customProtections, aiMode, showDockIcon, displayUnit, scanScope, menuBar, dailyJournalEnabled, runMode, showEnglishOriginal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        customProtections = try c.decodeIfPresent([String].self, forKey: .customProtections) ?? []
        aiMode = try c.decodeIfPresent(String.self, forKey: .aiMode) ?? "off"
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
        let rawUnit = try c.decodeIfPresent(String.self, forKey: .displayUnit) ?? ""
        displayUnit = DisplayUnit(rawValue: rawUnit) ?? .auto
        scanScope = try c.decodeIfPresent(String.self, forKey: .scanScope) ?? "userOnly"
        menuBar = try c.decodeIfPresent(MenuBarPreferences.self, forKey: .menuBar) ?? .default
        dailyJournalEnabled = try c.decodeIfPresent(Bool.self, forKey: .dailyJournalEnabled) ?? true
        let rawRunMode = try c.decodeIfPresent(String.self, forKey: .runMode) ?? "silent"
        runMode = RunMode(rawValue: rawRunMode)?.rawValue ?? "silent"
        showEnglishOriginal = try c.decodeIfPresent(Bool.self, forKey: .showEnglishOriginal) ?? true
    }
}

public enum ConfigurationTransfer {
    /// 清洗保护路径：去空白、去重、限长；空数组是合法配置。
    public static func normalizeProtections(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in paths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 1_024 else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    public static func encode(_ configuration: AppConfiguration) throws -> Data {
        var copy = configuration
        copy.version = AppConfiguration.currentVersion
        copy.customProtections = normalizeProtections(copy.customProtections)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(copy)
    }

    public static func decode(_ data: Data) throws -> AppConfiguration {
        let decoded: AppConfiguration
        do {
            decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        } catch {
            throw ConfigurationTransferError.malformed
        }
        guard decoded.version <= AppConfiguration.currentVersion else {
            throw ConfigurationTransferError.futureVersion(decoded.version)
        }
        var normalized = decoded
        normalized.version = AppConfiguration.currentVersion
        normalized.customProtections = normalizeProtections(decoded.customProtections)
        normalized.aiMode = ["off", "hybrid", "full"].contains(decoded.aiMode) ? decoded.aiMode : "off"
        normalized.scanScope = ["userOnly", "wholeDisk"].contains(decoded.scanScope) ? decoded.scanScope : "userOnly"
        return normalized
    }
}

public enum ConfigurationTransferError: Error, LocalizedError, Equatable {
    case malformed
    case futureVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .malformed: return "配置文件格式不正确，未导入任何设置。"
        case let .futureVersion(version): return "这个配置来自更高的版本（\(version)），当前版本无法安全读取。"
        }
    }
}
