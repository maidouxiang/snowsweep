import Foundation

/// 系统设置跳转地址。把 URL 构造集中在 Core，做成纯函数以便单元测试，
/// 避免真机点开才发现跳错页。App 层只负责把 URL 交给系统打开。
///
/// 文案口径（2026-11 查证，macOS 13+ 新 System Settings）：
/// - 隐私各分类使用新式扩展 `com.apple.settings.PrivacySecurity.extension?锚点`；
/// - 登录项使用官方 SMAppService API（App 层），URL `com.apple.LoginItems-Settings.extension` 兜底。
/// 这些只是"跳转到哪一页"，不包含任何自动改动；关闭权限必须由用户在系统设置亲手做。
public enum SystemSettingsLinks {

    /// 隐私与安全 pane 的扩展标识。
    public static let privacyPane = "com.apple.settings.PrivacySecurity.extension"
    /// 登录项 pane 的扩展标识（SMAppService 不可用时的兜底）。
    public static let loginItemsPane = "com.apple.LoginItems-Settings.extension"

    public static func url(_ string: String) -> URL? { URL(string: string) }

    /// 完全磁盘访问权限页。
    public static func fullDiskAccessURL() -> URL? {
        url("x-apple.systempreferences:\(privacyPane)?Privacy_AllFiles")
    }

    /// 登录项与扩展（兜底 URL；App 层优先用官方 SMAppService）。
    public static func loginItemsURL() -> URL? {
        url("x-apple.systempreferences:\(loginItemsPane)")
    }

    /// 按权限类型跳到对应的隐私分类页。未知类型落到隐私与安全性首页，不猜具体页。
    public static func permissionURL(for kind: PermissionKind?) -> URL? {
        url("x-apple.systempreferences:\(privacyPane)?\(privacyAnchor(for: kind))")
    }

    /// 锚点表。经查证修正了 4 处会导致跳错页的错误：
    /// Location→LocationServices、Calendar→Calendars、AppleEvents→Automation、
    /// InputMonitoring→ListenEvent；并把旧式 pane 统一到新式扩展。
    public static func privacyAnchor(for kind: PermissionKind?) -> String {
        guard let kind else { return "Privacy" }
        switch kind {
        case .camera: return "Privacy_Camera"
        case .microphone: return "Privacy_Microphone"
        case .location: return "Privacy_LocationServices"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .accessibility: return "Privacy_Accessibility"
        case .fullDiskAccess: return "Privacy_AllFiles"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .folders: return "Privacy_FilesAndFolders"
        case .bluetooth: return "Privacy_Bluetooth"
        case .motion: return "Privacy_Motion"
        case .contacts: return "Privacy_Contacts"
        case .calendar: return "Privacy_Calendars"
        case .reminders: return "Privacy_Reminders"
        case .photos: return "Privacy_Photos"
        case .appleEvents: return "Privacy_Automation"
        case .other: return "Privacy"
        }
    }
}
