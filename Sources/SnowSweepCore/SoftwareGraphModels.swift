import Foundation

public enum SoftwareNodeKind: String, Codable, CaseIterable, Sendable {
    case app
    case family
    case plugin
    case helper
    case cache
    case license
    case installer
    case runtime
    case unknown

    public var chineseName: String {
        switch self {
        case .app: return "应用"
        case .family: return "软件家族"
        case .plugin: return "插件/扩展"
        case .helper: return "后台服务"
        case .cache: return "缓存"
        case .license: return "许可证"
        case .installer: return "安装包"
        case .runtime: return "运行库"
        case .unknown: return "未知目录"
        }
    }
}

public enum SoftwareRelation: String, Codable, Sendable {
    case belongsTo
    case installedBy
    case sharedBy
    case requires
    case sibling
    case leftoverOf

    public var chineseName: String {
        switch self {
        case .belongsTo: return "属于"
        case .installedBy: return "由…安装"
        case .sharedBy: return "被…共用"
        case .requires: return "依赖"
        case .sibling: return "同厂商"
        case .leftoverOf: return "是…的残留"
        }
    }
}

public enum SoftwareEvidenceKind: String, Codable, Sendable {
    case bundleIdentifier
    case teamIdentifier
    case packageReceipt
    case pluginRoot
    case launchAgent
    case pathAlias
    case lastUsed
    case sharedHost
    case systemPath
    case manual
}

public enum SoftwareEvidenceStrength: String, Codable, Sendable {
    case strong
    case medium
    case weak

    public var chineseName: String {
        switch self {
        case .strong: return "强证据"
        case .medium: return "中证据"
        case .weak: return "弱证据"
        }
    }
}

public struct SoftwareEvidence: Codable, Hashable, Sendable {
    public let kind: SoftwareEvidenceKind
    public let value: String
    public let strength: SoftwareEvidenceStrength
    public let note: String

    public init(kind: SoftwareEvidenceKind, value: String,
                strength: SoftwareEvidenceStrength, note: String) {
        self.kind = kind
        self.value = value
        self.strength = strength
        self.note = note
    }
}

public struct SoftwareHost: Codable, Hashable, Sendable, Identifiable {
    public let bundleID: String
    public let name: String
    public let path: String?
    public var id: String { bundleID }

    public init(bundleID: String, name: String, path: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

public struct SoftwareNode: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let path: String
    public let kind: SoftwareNodeKind
    public let bundleID: String?
    public let familyID: String?
    public let familyName: String?
    public let isSystem: Bool
    public let isProtected: Bool
    public let sizeBytes: Int64?
    public let lastUsed: Date?
    public let lastModified: Date?

    public init(id: String, name: String, path: String, kind: SoftwareNodeKind,
                bundleID: String? = nil, familyID: String? = nil,
                familyName: String? = nil, isSystem: Bool = false,
                isProtected: Bool = false, sizeBytes: Int64? = nil,
                lastUsed: Date? = nil, lastModified: Date? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.bundleID = bundleID
        self.familyID = familyID
        self.familyName = familyName
        self.isSystem = isSystem
        self.isProtected = isProtected
        self.sizeBytes = sizeBytes
        self.lastUsed = lastUsed
        self.lastModified = lastModified
    }
}

public struct SoftwareEdge: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let from: String
    public let to: String
    public let relation: SoftwareRelation
    public let evidence: SoftwareEvidence

    public init(from: String, to: String, relation: SoftwareRelation,
                evidence: SoftwareEvidence) {
        self.id = "\(from)->\(to)->\(relation.rawValue)"
        self.from = from
        self.to = to
        self.relation = relation
        self.evidence = evidence
    }
}

public enum SoftwareVerdict: String, Codable, CaseIterable, Sendable {
    case suggestedCleanup
    case possibleRedundancy
    case keep
    case unknown
    case protected

    public var chineseName: String {
        switch self {
        case .suggestedCleanup: return "建议清理"
        case .possibleRedundancy: return "可能冗余"
        case .keep: return "保留"
        case .unknown: return "待判断"
        case .protected: return "受保护"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .suggestedCleanup: return 0
        case .possibleRedundancy: return 1
        case .unknown: return 2
        case .keep: return 3
        case .protected: return 4
        }
    }
}

public struct SoftwareFinding: Codable, Hashable, Sendable, Identifiable {
    public let node: SoftwareNode
    public let familyID: String?
    public let familyName: String?
    public let installedHosts: [SoftwareHost]
    public let missingHostBundleIDs: [String]
    public let sharedByHosts: [SoftwareHost]
    public let verdict: SoftwareVerdict
    public let reasons: [String]
    public let evidence: [SoftwareEvidence]
    public let isShared: Bool
    public let isOwnerMissing: Bool
    public let lastUsed: Date?
    public let lastModified: Date?
    public let sizeBytes: Int64?
    public var id: String { node.id }

    public init(node: SoftwareNode, familyID: String?, familyName: String?,
                installedHosts: [SoftwareHost], missingHostBundleIDs: [String],
                sharedByHosts: [SoftwareHost], verdict: SoftwareVerdict,
                reasons: [String], evidence: [SoftwareEvidence],
                isShared: Bool, isOwnerMissing: Bool,
                lastUsed: Date?, lastModified: Date?, sizeBytes: Int64?) {
        self.node = node
        self.familyID = familyID
        self.familyName = familyName
        self.installedHosts = installedHosts
        self.missingHostBundleIDs = missingHostBundleIDs
        self.sharedByHosts = sharedByHosts
        self.verdict = verdict
        self.reasons = reasons
        self.evidence = evidence
        self.isShared = isShared
        self.isOwnerMissing = isOwnerMissing
        self.lastUsed = lastUsed
        self.lastModified = lastModified
        self.sizeBytes = sizeBytes
    }
}

public struct SoftwareGraphStats: Codable, Sendable {
    public var appCount: Int
    public var familyCount: Int
    public var pluginNodeCount: Int
    public var suggestedCleanupCount: Int
    public var possibleRedundancyCount: Int
    public var keepCount: Int
    public var unknownCount: Int
    public var protectedCount: Int
    public var totalCandidateBytes: Int64
    public var warnings: [String]

    public init(appCount: Int = 0, familyCount: Int = 0, pluginNodeCount: Int = 0,
                suggestedCleanupCount: Int = 0, possibleRedundancyCount: Int = 0,
                keepCount: Int = 0, unknownCount: Int = 0,
                protectedCount: Int = 0, totalCandidateBytes: Int64 = 0,
                warnings: [String] = []) {
        self.appCount = appCount
        self.familyCount = familyCount
        self.pluginNodeCount = pluginNodeCount
        self.suggestedCleanupCount = suggestedCleanupCount
        self.possibleRedundancyCount = possibleRedundancyCount
        self.keepCount = keepCount
        self.unknownCount = unknownCount
        self.protectedCount = protectedCount
        self.totalCandidateBytes = totalCandidateBytes
        self.warnings = warnings
    }
}

public struct SoftwareGraphReport: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let storeUpdatedAt: String
    public let nodes: [SoftwareNode]
    public let edges: [SoftwareEdge]
    public let findings: [SoftwareFinding]
    public let stats: SoftwareGraphStats

    public init(schemaVersion: Int, generatedAt: Date, storeUpdatedAt: String,
                nodes: [SoftwareNode], edges: [SoftwareEdge],
                findings: [SoftwareFinding], stats: SoftwareGraphStats) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.storeUpdatedAt = storeUpdatedAt
        self.nodes = nodes
        self.edges = edges
        self.findings = findings
        self.stats = stats
    }
}
