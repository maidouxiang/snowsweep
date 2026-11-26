import Foundation

/// 手动删除的一次预览。身份在用户确认前捕获，确认后仍按原身份复核，
/// 防止“预览时是 A，点确认时路径已被换成 B”。
public struct ManualDeletionPlan: Sendable, Hashable {
    public let path: String
    public let displayName: String
    public let sizeBytes: Int64
    public let identity: FileIdentity
    public let reason: String

    public init(path: String, displayName: String, sizeBytes: Int64,
                identity: FileIdentity, reason: String) {
        self.path = path
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.identity = identity
        self.reason = reason
    }

    public var kindText: String {
        switch identity.kind {
        case .file: return "文件"
        case .directory: return "文件夹"
        case .symlink: return "快捷方式"
        case .other: return "其他项目"
        }
    }
}

public enum ManualDeletionError: Error, LocalizedError, Equatable {
    case notFound(String)
    case symbolicLink(String)
    case protected(String)
    case outsideAllowedRoots(String)
    case identityChanged(String)
    case trashFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(path): return "「\(path)」已经不存在，请刷新列表"
        case let .symbolicLink(path): return "「\(path)」是快捷方式（符号链接），为了不误删它指向的文件，已停止操作"
        case let .protected(path): return "「\(path)」在保护清单内，已停止操作"
        case let .outsideAllowedRoots(path): return "「\(path)」不在允许清理的位置内，已停止操作"
        case let .identityChanged(path): return "「\(path)」在确认前被替换过，已停止操作；请刷新后重新确认"
        case let .trashFailed(reason): return "移到废纸篓失败：\(reason)。文件没有被永久删除"
        }
    }
}

/// 给大文件、重复文件、软件族谱和空间分析共用的手动废纸篓入口。
/// 这里刻意不提供永久删除：所有操作都只到废纸篓，且每次都写审计日志。
public struct ManualDeletionService: Sendable {
    public let trasher: any FileTrashing
    public let audit: AuditLog
    public let verifier: any TargetVerifying
    public let protectionCheck: (@Sendable (String) -> Bool)?
    public let allowedRoots: [String]

    public init(
        trasher: any FileTrashing = SystemFileTrasher(),
        audit: AuditLog = AuditLog(),
        verifier: any TargetVerifying = SystemTargetVerifier(),
        protectionCheck: (@Sendable (String) -> Bool)? = nil,
        allowedRoots: [String] = [NSHomeDirectory()]
    ) {
        self.trasher = trasher
        self.audit = audit
        self.verifier = verifier
        self.protectionCheck = protectionCheck
        self.allowedRoots = allowedRoots.map {
            NSString(string: $0).expandingTildeInPath
        }
    }

    /// 预览只读取体积与身份，不碰文件内容，也不写审计日志。
    public func preview(path: String, reason: String) throws -> ManualDeletionPlan {
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard !standardized.isEmpty, standardized != "/" else {
            throw ManualDeletionError.outsideAllowedRoots(path)
        }
        try ensureAllowed(standardized)
        if let protectionCheck, protectionCheck(standardized) {
            throw ManualDeletionError.protected(standardized)
        }
        guard let identity = FileIdentity.capture(at: standardized) else {
            throw ManualDeletionError.notFound(standardized)
        }
        guard identity.kind != .symlink else {
            throw ManualDeletionError.symbolicLink(standardized)
        }
        let size = Self.sizeOfItem(at: standardized)
        return ManualDeletionPlan(
            path: standardized,
            displayName: (standardized as NSString).lastPathComponent,
            sizeBytes: size,
            identity: identity,
            reason: reason
        )
    }

    /// 用户确认后执行。只移到废纸篓；失败即停并写失败审计，绝不回退永久删除。
    @discardableResult
    public func moveToTrash(_ plan: ManualDeletionPlan, source: String) throws -> AuditEvent {
        let item = ScanItem(
            path: plan.path,
            sizeBytes: plan.sizeBytes,
            identity: plan.identity
        )
        do {
            try verifier.verify(item, strictIdentity: true, isProtected: protectionCheck)
        } catch let reason as TargetRevalidationError {
            _ = try? audit.append(
                action: .targetRejected,
                path: plan.path,
                ruleID: "manual:\(source)",
                sizeBytes: plan.sizeBytes,
                success: false,
                detail: reason.auditDetail
            )
            throw ManualDeletionError.identityChanged(plan.path)
        } catch {
            _ = try? audit.append(
                action: .targetRejected,
                path: plan.path,
                ruleID: "manual:\(source)",
                sizeBytes: plan.sizeBytes,
                success: false,
                detail: "\(error)"
            )
            throw ManualDeletionError.identityChanged(plan.path)
        }

        do {
            let resulting = try trasher.trashItem(at: plan.path)
            return try audit.append(
                action: .moveToTrash,
                path: plan.path,
                ruleID: "manual:\(source)",
                sizeBytes: plan.sizeBytes,
                success: true,
                detail: "手动确认：\(plan.reason)",
                resultingItemURL: resulting?.path
            )
        } catch {
            _ = try? audit.append(
                action: .moveToTrashFailed,
                path: plan.path,
                ruleID: "manual:\(source)",
                sizeBytes: plan.sizeBytes,
                success: false,
                detail: "\(error)"
            )
            throw ManualDeletionError.trashFailed("\(error)")
        }
    }

    private func ensureAllowed(_ path: String) throws {
        guard allowedRoots.contains(where: { root in
            path == root || path.hasPrefix(root + "/")
        }) else {
            throw ManualDeletionError.outsideAllowedRoots(path)
        }
        // 系统目录即使误传也不允许进入手动清理。
        let forbidden = ["/System", "/usr", "/bin", "/sbin", "/private", "/dev", "/etc"]
        if forbidden.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            throw ManualDeletionError.protected(path)
        }
    }

    private static func sizeOfItem(at path: String) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            if let attributes = try? fm.attributesOfItem(atPath: path),
               let number = attributes[.size] as? NSNumber {
                return number.int64Value
            }
            return 0
        }
        let resourceKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
