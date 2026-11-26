import Foundation
import Testing
@testable import SnowSweepCore

@Test func fullDiskAccessUsesModernPrivacyExtension() throws {
    let url = try #require(SystemSettingsLinks.fullDiskAccessURL())
    #expect(url.absoluteString == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
}

@Test func loginItemsUsesDedicatedExtension() throws {
    let url = try #require(SystemSettingsLinks.loginItemsURL())
    #expect(url.absoluteString == "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
}

@Test func previouslyWrongAnchorsAreCorrected() {
    // M4 查证发现的 4 处跳错页，回归锁定。
    #expect(SystemSettingsLinks.privacyAnchor(for: .location) == "Privacy_LocationServices")
    #expect(SystemSettingsLinks.privacyAnchor(for: .calendar) == "Privacy_Calendars")
    #expect(SystemSettingsLinks.privacyAnchor(for: .appleEvents) == "Privacy_Automation")
    #expect(SystemSettingsLinks.privacyAnchor(for: .inputMonitoring) == "Privacy_ListenEvent")
}

@Test func everyPermissionKindMapsToAConcreteOrFallbackAnchor() throws {
    for kind in PermissionKind.allCases {
        let anchor = SystemSettingsLinks.privacyAnchor(for: kind)
        // other 故意落到 ?Privacy 首页，其余必须指向具体分类页。
        if kind == .other {
            #expect(anchor == "Privacy")
        } else {
            #expect(anchor.hasPrefix("Privacy_"), "\(kind) 锚点格式不对：\(anchor)")
        }
        let url = try #require(SystemSettingsLinks.permissionURL(for: kind))
        #expect(url.absoluteString.contains(SystemSettingsLinks.privacyPane))
        #expect(url.absoluteString.hasSuffix(anchor))
    }
}

@Test func unknownPermissionFallsBackToPrivacyHomeNotAGuessedPage() throws {
    #expect(SystemSettingsLinks.privacyAnchor(for: nil) == "Privacy")
    #expect(SystemSettingsLinks.privacyAnchor(for: .other) == "Privacy")
    let url = try #require(SystemSettingsLinks.permissionURL(for: nil))
    #expect(url.absoluteString.hasSuffix("?Privacy"))
}
