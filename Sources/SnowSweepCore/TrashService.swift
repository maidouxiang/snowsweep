import Foundation

/// 文件操作抽象。测试注入 Mock，避免真实增删文件。
public protocol FileTrashing: Sendable {
    /// 返回系统给出的最终位置；无法获得时返回 nil，但移动已经成功。
    func trashItem(at path: String) throws -> URL?
    func removeItem(at path: String) throws
}

public struct SystemFileTrasher: FileTrashing {
    public init() {}

    public func trashItem(at path: String) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(
            at: URL(fileURLWithPath: path),
            resultingItemURL: &resultingURL
        )
        return resultingURL as URL?
    }

    public func removeItem(at path: String) throws {
        try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
    }
}

/// 永久删除默认关闭；即使打开，也必须携带显式确认短语。
public struct DeletionPolicy: Sendable, Codable {
    public var allowPermanentDelete: Bool = false
    public var requirePhrase: String = "我确认永久删除"

    public init(allowPermanentDelete: Bool = false, requirePhrase: String = "我确认永久删除") {
        self.allowPermanentDelete = allowPermanentDelete
        self.requirePhrase = requirePhrase
    }
}

public struct DeleteConfirmation: Sendable {
    public let phrase: String
    public let acknowledgedIrreplaceable: Bool

    public init(phrase: String, acknowledgedIrreplaceable: Bool) {
        self.phrase = phrase
        self.acknowledgedIrreplaceable = acknowledgedIrreplaceable
    }
}

/// 废纸篓失败后的用户选择。默认是停止；跳过和备份都不等于永久删除。
public enum TrashFailureResolution: Sendable {
    case stop
    case skip
    case backupTo(String)
}

public enum DeletionError: Error, LocalizedError, Equatable {
    case incompleteReport(String)
    case permanentDeleteDisabled
    case confirmationRequired
    case trashFailed(String)
    case backupFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .incompleteReport(reason): return "报告不完整，禁止清理：\(reason)"
        case .permanentDeleteDisabled: return "永久删除未开启，只能移到废纸篓"
        case .confirmationRequired: return "永久删除需要输入确认短语并勾选不可恢复提示"
        case let .trashFailed(reason): return "移到废纸篓失败：\(reason)。未执行任何永久删除。"
        case let .backupFailed(reason): return "备份失败：\(reason)。未执行任何永久删除。"
        }
    }
}

/// M3 清理闭环。三步骤：dry-run 预览 → 废纸篓（失败即停） → 永久删除（双重确认）。
/// 每一步无论成败都写 JSONL 审计日志；失败绝不静默升级为永久删除。
public struct DeletionCoordinator: Sendable {
    public let trasher: any FileTrashing
    public let audit: AuditLog
    public let policy: DeletionPolicy
    /// 删除前复核目标是否仍是扫描时的那个文件。
    public let verifier: any TargetVerifying
    /// 保护清单判定。由上层注入 RuleEngine.isProtected；未注入时只靠规则引擎前置拦截。
    public let protectionCheck: (@Sendable (String) -> Bool)?
    /// 严格要求扫描报告带身份信息。生产环境建议开启；旧报告/测试可关闭。
    public let requireIdentity: Bool

    public init(
        trasher: any FileTrashing = SystemFileTrasher(),
        audit: AuditLog = AuditLog(),
        policy: DeletionPolicy = DeletionPolicy(),
        verifier: any TargetVerifying = SystemTargetVerifier(),
        protectionCheck: (@Sendable (String) -> Bool)? = nil,
        requireIdentity: Bool = false
    ) {
        self.trasher = trasher
        self.audit = audit
        self.policy = policy
        self.verifier = verifier
        self.protectionCheck = protectionCheck
        self.requireIdentity = requireIdentity
    }

    /// dry-run 只生成判定，不触碰文件系统。
    public func dryRun(
        items: [ScanItem],
        report: ScanReport,
        engine: RuleEngine,
        batchID: String? = nil
    ) throws -> [Verdict] {
        try guardComplete(report)
        let verdicts = items.map { engine.verdict(for: $0) }
        try audit.append(
            action: .dryRun,
            path: "批次共 \(items.count) 项",
            success: true,
            detail: "预览生成，无文件操作",
            batchID: batchID
        )
        return verdicts
    }

    /// 返回 nil 表示用户选择了「跳过」，该条目未被处理，后续批次可继续。
    @discardableResult
    public func moveToTrash(
        _ item: ScanItem,
        ruleID: String?,
        report: ScanReport,
        resolution: TrashFailureResolution = .stop,
        batchID: String? = nil
    ) throws -> AuditEvent? {
        try guardComplete(report)
        try revalidate(item, batchID: batchID)
        do {
            let resulting = try trasher.trashItem(at: item.path)
            return try audit.append(
                action: .moveToTrash,
                path: item.path,
                ruleID: ruleID,
                sizeBytes: item.sizeBytes,
                success: true,
                detail: "已移到废纸篓",
                batchID: batchID,
                resultingItemURL: resulting?.path
            )
        } catch {
            // 关键：失败只记录，绝不调用 removeItem 兜底。
            _ = try? audit.append(
                action: .moveToTrashFailed,
                path: item.path,
                ruleID: ruleID,
                sizeBytes: item.sizeBytes,
                success: false,
                detail: "\(error)",
                batchID: batchID
            )
            switch resolution {
            case .stop:
                throw DeletionError.trashFailed("\(error)")
            case .skip:
                _ = try? audit.append(
                    action: .skippedAfterTrashFailure,
                    path: item.path,
                    ruleID: ruleID,
                    sizeBytes: item.sizeBytes,
                    success: true,
                    detail: "用户选择跳过，文件保持原样",
                    batchID: batchID
                )
                return nil
            case let .backupTo(directory):
                let destination = try moveToBackup(item.path, directory: directory)
                return try audit.append(
                    action: .movedToBackup,
                    path: item.path,
                    ruleID: ruleID,
                    sizeBytes: item.sizeBytes,
                    success: true,
                    detail: "废纸篓失败后按用户选择备份到 \(destination)",
                    batchID: batchID,
                    resultingItemURL: destination
                )
            }
        }
    }

    /// 把条目移入用户指定备份目录。这里只做 move，不调用 removeItem，
    /// 且拒绝把备份目录设在条目自身内部，避免递归移动。
    private func moveToBackup(_ path: String, directory: String) throws -> String {
        let expanded = NSString(string: directory).expandingTildeInPath
        let backupURL = URL(fileURLWithPath: expanded, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: backupURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            _ = try? audit.append(
                action: .backupFailed, path: path, success: false, detail: "备份目录不存在或不是文件夹"
            )
            throw DeletionError.backupFailed("备份目录不存在或不是文件夹")
        }
        let source = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let sourceRoot = source.path.hasSuffix("/") ? source.path : source.path + "/"
        guard !backupURL.path.hasPrefix(sourceRoot), backupURL.path != source.path else {
            _ = try? audit.append(
                action: .backupFailed, path: path, success: false, detail: "备份目录不能位于该条目内部"
            )
            throw DeletionError.backupFailed("备份目录不能位于该条目内部")
        }

        let base = source.lastPathComponent
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var destination = backupURL.appendingPathComponent("\(base).\(stamp)")
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = backupURL.appendingPathComponent("\(base).\(stamp).\(index)")
            index += 1
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination.path
        } catch {
            _ = try? audit.append(
                action: .backupFailed, path: path, success: false, detail: "\(error)"
            )
            throw DeletionError.backupFailed("\(error)")
        }
    }

    @discardableResult
    public func permanentlyDelete(
        _ item: ScanItem,
        ruleID: String?,
        report: ScanReport,
        confirmation: DeleteConfirmation
    ) throws -> AuditEvent {
        try guardComplete(report)
        try revalidate(item)
        guard policy.allowPermanentDelete else {
            _ = try? audit.append(
                action: .policyRejected, path: item.path, success: false, detail: "永久删除开关关闭"
            )
            throw DeletionError.permanentDeleteDisabled
        }
        guard confirmation.acknowledgedIrreplaceable,
              confirmation.phrase == policy.requirePhrase else {
            _ = try? audit.append(
                action: .policyRejected, path: item.path, success: false, detail: "二次确认不完整"
            )
            throw DeletionError.confirmationRequired
        }
        do {
            try trasher.removeItem(at: item.path)
            return try audit.append(
                action: .permanentDelete,
                path: item.path,
                ruleID: ruleID,
                sizeBytes: item.sizeBytes,
                success: true,
                detail: "已按二次确认永久删除"
            )
        } catch {
            _ = try? audit.append(
                action: .permanentDeleteFailed,
                path: item.path,
                ruleID: ruleID,
                sizeBytes: item.sizeBytes,
                success: false,
                detail: "\(error)"
            )
            throw DeletionError.trashFailed("\(error)")
        }
    }

    private func guardComplete(_ report: ScanReport) throws {
        guard report.canClean else {
            throw DeletionError.incompleteReport(report.cleaningBlockedReason ?? "未知原因")
        }
    }

    /// 删除前的最后一道门。任何失败都先写审计再抛出，绝不继续执行删除。
    private func revalidate(_ item: ScanItem, batchID: String? = nil) throws {
        do {
            try verifier.verify(
                item,
                strictIdentity: requireIdentity,
                isProtected: protectionCheck
            )
        } catch let reason as TargetRevalidationError {
            _ = try? audit.append(
                action: .targetRejected,
                path: item.path,
                ruleID: nil,
                sizeBytes: item.sizeBytes,
                success: false,
                detail: reason.auditDetail,
                batchID: batchID
            )
            throw reason
        }
    }
}
