import Darwin
import Foundation

/// 完全磁盘访问的行为探测。
///
/// TCC.db 本身往往连有授权的 App 也打不开（被 SIP / root 独占），所以不能拿
/// “TCC.db 是否可读”当作 FDA 的唯一证据。这里改为尝试打开系统明确保护的个人目录：
/// 只有拿到完全磁盘访问，`opendir` 才会成功；没有授权会返回 EPERM。
///
/// 只打开目录句柄并立即关闭，不读取文件名、不读内容、不写任何东西。
public enum FullDiskAccessProbe: Sendable {
    public static func isLikelyGranted(home: String = NSHomeDirectory()) -> Bool {
        let candidates = [
            (home as NSString).appendingPathComponent("Library/Safari"),
            (home as NSString).appendingPathComponent("Library/Mail"),
            (home as NSString).appendingPathComponent("Library/Messages"),
            (home as NSString).appendingPathComponent("Library/Application Support/AddressBook"),
            "/Library/Application Support/com.apple.TCC",
            "/private/var/db/locationd"
        ]
        for path in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            if let handle = opendir(path) {
                closedir(handle)
                return true
            }
        }
        return false
    }
}
