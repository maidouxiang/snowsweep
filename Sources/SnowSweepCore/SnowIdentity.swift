import Foundation

/// 雪的对外与技术身份唯一事实来源。
///
/// 对外名统一为「雪」；旧工程身份 `SnowSweep` / `com.selfuse.snowso.sweep`
/// 只作为迁移来源与回退路径保留，不再出现在新安装的技术标识里。
public enum SnowIdentity: Sendable {
    /// 用户可见名称。
    public static let displayName = "雪"

    /// 新 Bundle ID。
    public static let bundleIdentifier = "com.selfuse.xue"

    /// 旧 Bundle ID，仅用于迁移偏好、数据与回退说明。
    public static let legacyBundleIdentifier = "com.selfuse.snowso.sweep"

    /// 新数据目录名：`~/Library/Application Support/雪`。
    public static let supportDirectoryName = "雪"

    /// 旧数据目录名：`~/Library/Application Support/SnowSweep`。
    public static let legacySupportDirectoryName = "SnowSweep"

    /// 新扫描服务 Bundle ID。
    public static let scannerServiceIdentifier = "com.selfuse.xue.ScannerService"

    /// 新模型宿主 Bundle ID。
    public static let modelHostIdentifier = "com.selfuse.xue.ModelHost"

    /// 新模型接入 Keychain service。
    public static let assistantKeychainService = "com.selfuse.xue.assistant"

    /// 默认数据目录。测试与调用方可注入 FileManager。
    public static func supportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    /// 旧数据目录。只读迁移来源，不在这里写入。
    public static func legacySupportDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(legacySupportDirectoryName, isDirectory: true)
    }
}
