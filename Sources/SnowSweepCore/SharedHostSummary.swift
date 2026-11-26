import Foundation

/// 共享宿主摘要：把同一插件的已安装宿主去重、排序，并给出一句明确保留结论。
/// 只做展示与判定辅助，不参与删除，不改变任何勾选状态。
public struct SharedHostSummary: Hashable, Sendable {
    public let hosts: [SoftwareHost]

    public init(hosts: [SoftwareHost]) {
        var seen: Set<String> = []
        var unique: [SoftwareHost] = []
        for host in hosts {
            let key = host.bundleID.lowercased() + "|" + (host.path ?? "")
            if seen.insert(key).inserted {
                unique.append(host)
            }
        }
        unique.sort { lhs, rhs in
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder == .orderedSame {
                return lhs.bundleID < rhs.bundleID
            }
            return nameOrder == .orderedAscending
        }
        self.hosts = unique
    }

    public init(finding: SoftwareFinding) {
        self.init(hosts: finding.installedHosts)
    }

    public var count: Int { hosts.count }
    public var isShared: Bool { count > 1 }

    public var names: String {
        hosts.map(\.name).joined(separator: "、")
    }

    public var headline: String {
        switch count {
        case 0:
            return "没有已安装宿主"
        case 1:
            return "唯一宿主：\(names)"
        default:
            return "同家族 \(count) 个宿主：\(names)"
        }
    }

    public var conclusion: String {
        switch count {
        case 0:
            return "宿主不在；先按可能冗余处理，确认没有其他共用后再决定。"
        case 1:
            return "宿主还在，插件仍会被使用；保留，不建议删。"
        default:
            return "同一家族还有多个宿主仍安装；插件可能被共用，保留，不要删。"
        }
    }
}
