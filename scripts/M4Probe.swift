import Foundation
import SnowSweepCore

/// M4 验收探针：调用真实 Core 采集器，输出 JSON 供 m4-accept.sh 判定。
/// 只读、零网络、零写入。不依赖 App 界面。
struct M4Probe: Codable {
    let systemVersion: String
    let machine: String
    let collectedAt: String
    let permission: PermissionPart
    let startup: StartupPart
    let links: [String: String]

    struct PermissionPart: Codable {
        let grants: Int
        let gaps: [String]
        let isComplete: Bool
        let hasTCCDeniedGap: Bool
        let blocksResultCorrectly: Bool
    }
    struct StartupPart: Codable {
        let items: Int
        let gaps: [String]
        let isComplete: Bool
        let untranslated: [String]
        let hedgeMistakenAsEdge: Bool
        let hasLoginItemsGap: Bool
    }
}

let perm = PermissionInspector().snapshot()
let start = StartupInspector().snapshot()

let untranslated = start.items
    .filter { $0.displayName == "后台服务（原文见详情）" || $0.displayName == "未知程序" }
    .map(\.rawLabel)

let hedgeWrong = start.items.contains {
    $0.rawLabel.lowercased().contains("hedge") &&
    $0.displayName.contains("Edge")
}

let tccDeniedGap = perm.gaps.first { $0.kind == .tccDenied }
let permPart = M4Probe.PermissionPart(
    grants: perm.grants.count,
    gaps: perm.gaps.map(\.kind.rawValue),
    isComplete: perm.isComplete,
    hasTCCDeniedGap: tccDeniedGap != nil,
    blocksResultCorrectly: tccDeniedGap?.blocksResult == true
)

let loginGap = start.gaps.first { $0.kind == .loginItemsNeedsSystemSettings }
let startPart = M4Probe.StartupPart(
    items: start.items.count,
    gaps: start.gaps.map(\.kind.rawValue),
    isComplete: start.isComplete,
    untranslated: untranslated,
    hedgeMistakenAsEdge: hedgeWrong,
    hasLoginItemsGap: loginGap != nil
)

let links: [String: String] = [
    "fda": SystemSettingsLinks.fullDiskAccessURL()?.absoluteString ?? "NIL",
    "loginItems": SystemSettingsLinks.loginItemsURL()?.absoluteString ?? "NIL",
    "location": SystemSettingsLinks.privacyAnchor(for: .location),
    "calendar": SystemSettingsLinks.privacyAnchor(for: .calendar),
    "appleEvents": SystemSettingsLinks.privacyAnchor(for: .appleEvents),
    "inputMonitoring": SystemSettingsLinks.privacyAnchor(for: .inputMonitoring),
]

var machineSize = 0
var machineName = "unknown"
var sysname = utsname()
if uname(&sysname) == 0 {
    machineName = withUnsafePointer(to: &sysname.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
}

let probe = M4Probe(
    systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
    machine: machineName,
    collectedAt: ISO8601DateFormatter().string(from: Date()),
    permission: permPart,
    startup: startPart,
    links: links
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if let data = try? encoder.encode(probe), let text = String(data: data, encoding: .utf8) {
    print(text)
} else {
    print("{\"error\":\"编码失败\"}")
}
