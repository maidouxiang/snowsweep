import Foundation

/// 判断 `/Applications/厂商目录/应用.app` 里的应用是否值得列进卸载清单。
/// 只收主应用，避免把崩溃报告、卸载器、助手 App 当成可卸载主应用。
public enum ApplicationInstallPolicy {
    public static func isNestedMainApp(appName: String, folderName: String) -> Bool {
        let app = normalized(appName)
        let folder = normalized(folderName)
        guard !app.isEmpty, !folder.isEmpty else { return false }
        if app == folder { return true }
        guard min(app.count, folder.count) >= 8 else { return false }
        return app.hasPrefix(folder) || folder.hasPrefix(app)
    }

    public static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
