import Foundation

/// 卸载前使用：只根据已有族谱报告和选中的应用做纯计算，不碰文件、不执行删除。
public struct UninstallAppRef: Sendable, Hashable {
    public let name: String
    public let bundleID: String
    public let path: String

    public init(name: String, bundleID: String, path: String) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
    }
}

public struct UninstallFamilyImpact: Identifiable, Sendable, Hashable {
    public let familyID: String
    public let familyName: String
    public let selectedHosts: [SoftwareHost]
    public let remainingHosts: [SoftwareHost]
    public let pluginFindings: [SoftwareFinding]
    public let pluginCount: Int
    public let pluginBytes: Int64

    public var id: String { familyID }
    public var isShared: Bool { !remainingHosts.isEmpty && pluginCount > 0 }
    public var becomesOrphan: Bool { remainingHosts.isEmpty && pluginCount > 0 }

    public init(familyID: String, familyName: String,
                selectedHosts: [SoftwareHost], remainingHosts: [SoftwareHost],
                pluginFindings: [SoftwareFinding], pluginCount: Int,
                pluginBytes: Int64) {
        self.familyID = familyID
        self.familyName = familyName
        self.selectedHosts = selectedHosts
        self.remainingHosts = remainingHosts
        self.pluginFindings = pluginFindings
        self.pluginCount = pluginCount
        self.pluginBytes = pluginBytes
    }
}

public struct UninstallImpact: Sendable {
    public let selectedApps: [SoftwareHost]
    public let families: [UninstallFamilyImpact]
    public let unregisteredApps: [UninstallAppRef]

    public var affectedFamilyCount: Int { families.count }
    public var sharedFamilyCount: Int { families.filter(\.isShared).count }
    public var orphanFamilyCount: Int { families.filter(\.becomesOrphan).count }
    public var orphanPluginCount: Int { families.filter(\.becomesOrphan).reduce(0) { $0 + $1.pluginCount } }
    public var orphanBytes: Int64 { families.filter(\.becomesOrphan).reduce(0) { $0 + $1.pluginBytes } }
    public var hasAnyImpact: Bool { !families.isEmpty }

    public var familyNames: String {
        families.map(\.familyName).joined(separator: "、")
    }

    /// 给确认弹窗与结果卡用的一句中文结论。只提示，不批准删除。
    public var summaryText: String {
        if families.isEmpty {
            return unregisteredApps.isEmpty
                ? "没有可提示的软件家族影响。"
                : "这些应用不在本地族谱，暂时无法判断插件归属。卸载后可在「软件族谱」查看是否留下可识别的残留。"
        }
        var parts: [String] = ["会影响 \(affectedFamilyCount) 个软件家族（\(familyNames)）"]
        if sharedFamilyCount > 0 {
            parts.append("\(sharedFamilyCount) 个家族还有其他应用仍安装，插件继续保留")
        }
        if orphanFamilyCount > 0 {
            parts.append("\(orphanFamilyCount) 个家族会失去最后一个宿主，预计 \(orphanPluginCount) 个插件或组件可能变成孤儿")
        }
        if unregisteredApps.count > 0 {
            parts.append("另有 \(unregisteredApps.count) 个应用不在族谱，无法判断归属")
        }
        return parts.joined(separator: "；") + "。不会自动清理。"
    }

    public init(selectedApps: [SoftwareHost], families: [UninstallFamilyImpact],
                unregisteredApps: [UninstallAppRef]) {
        self.selectedApps = selectedApps
        self.families = families
        self.unregisteredApps = unregisteredApps
    }
}

public enum UninstallImpactEvaluator {
    /// 依据 `SoftwareGraphScanner` 的报告，计算卸载选中应用对家族 / 插件的影响。
    /// 只读纯函数：不读盘、不执行、不把「可能」升级成「建议清理」。
    public static func evaluate(report: SoftwareGraphReport,
                                selectedApps: [UninstallAppRef]) -> UninstallImpact {
        guard !selectedApps.isEmpty else {
            return UninstallImpact(selectedApps: [], families: [], unregisteredApps: [])
        }
        let selectedPaths = Set(selectedApps.map(\.path))

        let appNodes = report.nodes.filter { $0.kind == .app }
        var hostsByFamily: [String: [SoftwareHost]] = [:]
        for node in appNodes {
            guard let familyID = node.familyID, let bundleID = node.bundleID else { continue }
            let host = SoftwareHost(bundleID: bundleID, name: node.name, path: node.path)
            hostsByFamily[familyID, default: []].append(host)
        }

        let families = report.nodes.compactMap { node -> (String, String)? in
            guard node.kind == .family, let id = node.familyID else { return nil }
            return (id, node.familyName ?? node.name)
        }

        var impacts: [UninstallFamilyImpact] = []
        let affectedFamilyIDs = Set(appNodes.compactMap { node -> String? in
            guard selectedPaths.contains(node.path) else { return nil }
            return node.familyID
        })

        for familyID in affectedFamilyIDs.sorted() {
            let familyName = families.first { $0.0 == familyID }?.1
                ?? report.findings.first { $0.familyID == familyID }?.familyName
                ?? familyID
            let allHosts = hostsByFamily[familyID] ?? []
            let selectedHosts = allHosts.filter {
                selectedPaths.contains($0.path ?? "")
            }
            let remainingHosts = allHosts.filter {
                !selectedPaths.contains($0.path ?? "")
            }
            let plugins = report.findings.filter { finding in
                guard finding.familyID == familyID else { return false }
                switch finding.node.kind {
                case .app, .family, .license: return false
                default: return !finding.node.isProtected && !finding.node.isSystem
                }
            }
            impacts.append(UninstallFamilyImpact(
                familyID: familyID, familyName: familyName,
                selectedHosts: selectedHosts, remainingHosts: remainingHosts,
                pluginFindings: plugins, pluginCount: plugins.count,
                pluginBytes: plugins.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
            ))
        }

        let knownPaths = Set(appNodes.compactMap { node -> String? in
            node.familyID == nil ? nil : node.path
        })
        let unregistered = selectedApps.filter { !knownPaths.contains($0.path) }
        let selectedHosts = selectedApps.map {
            SoftwareHost(bundleID: $0.bundleID, name: $0.name, path: $0.path)
        }
        return UninstallImpact(selectedApps: selectedHosts, families: impacts,
                               unregisteredApps: unregistered)
    }
}
