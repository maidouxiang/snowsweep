import Foundation

/// 一次已成功执行、因此可能需要「找回来」的清理动作。
///
/// 安全口径：这个助手**只负责列出与定位**，绝不自动把文件移回原路径。
/// 原因很具体——清理之后原路径可能已经出现了名字相同的新文件，自动反向移动
/// 会静默覆盖它，等于用"好心回滚"制造一次真正的数据丢失。真正的恢复动作
/// 必须用户在 Finder 里亲眼确认后完成。
public struct RollbackCandidate: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let originalPath: String
    public let displayName: String
    public let sizeBytes: Int64
    public let movedAt: Date
    public let destination: RollbackDestination
    public let ruleID: String?
    /// 新审计记录里保存的精确位置；旧记录为 nil，界面再按废纸篓前缀匹配。
    public let resultingItemURL: String?
    /// 审计日志中的行号，便于回溯原始记录。
    public let auditLine: Int

    public init(
        id: UUID,
        originalPath: String,
        displayName: String,
        sizeBytes: Int64,
        movedAt: Date,
        destination: RollbackDestination,
        ruleID: String?,
        resultingItemURL: String? = nil,
        auditLine: Int
    ) {
        self.id = id
        self.originalPath = originalPath
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.movedAt = movedAt
        self.destination = destination
        self.ruleID = ruleID
        self.resultingItemURL = resultingItemURL
        self.auditLine = auditLine
    }
}

/// 文件被移到了哪里。只记录软件自己做过的事，不猜测用户后续操作。
public enum RollbackDestination: Codable, Hashable, Sendable {
    case trash
    case backup(String)
}

public enum RollbackError: Error, LocalizedError, Equatable {
    /// 审计链断了就不列出候选：日志本身不可信时，任何"可恢复清单"都不可信。
    case auditChainBroken(brokenLines: [Int], chainBreaks: [Int])

    public var errorDescription: String? {
        switch self {
        case let .auditChainBroken(broken, chain):
            return "审计日志校验失败（记录损坏 \(broken)，链断裂 \(chain)），暂时不显示恢复清单。"
        }
    }
}

public enum TrashLocations: Sendable {
    public static func directory() -> URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }
}

/// 从审计日志生成"可找回清单"。
/// 设计要点：
/// 1. 只认成功的 `moveToTrash` / `movedToBackup`，失败与拒绝项不进入清单；
/// 2. 列出之前先校验整条哈希链，链断就拒绝（错误信息明确指出断在第几行）；
/// 3. 清单按时间倒序，最近清理排在最前；
/// 4. 废纸篓里的文件通常被 Finder 改过名，匹配时按"原名前缀 + 文件类型"宽松匹配，
///    匹配不到也保留条目，让用户按原始路径自己找。
public struct AuditRollback: Sendable {
    public let audit: AuditLog

    public init(audit: AuditLog = AuditLog()) {
        self.audit = audit
    }

    public func candidates() throws -> [RollbackCandidate] {
        let verification = try audit.verify()
        guard verification.isValid else {
            throw RollbackError.auditChainBroken(
                brokenLines: verification.brokenLines,
                chainBreaks: verification.chainBrokenAt
            )
        }
        let events = try audit.events()
        return events.enumerated().compactMap { index, event in
            guard event.success else { return nil }
            let destination: RollbackDestination?
            switch event.action {
            case .moveToTrash:
                destination = .trash
            case .movedToBackup:
                destination = Self.backupPath(from: event.detail).map { .backup($0) }
            default:
                destination = nil
            }
            guard let destination else { return nil }
            return RollbackCandidate(
                id: event.id,
                originalPath: event.path,
                displayName: (event.path as NSString).lastPathComponent,
                sizeBytes: event.sizeBytes,
                movedAt: event.at,
                destination: destination,
                ruleID: event.ruleID,
                resultingItemURL: event.resultingItemURL,
                auditLine: index + 1
            )
        }
        .sorted { $0.movedAt > $1.movedAt }
    }

    /// 如果审计记录了精确位置且文件仍在，优先返回它；否则返回 nil 交给前缀匹配兜底。
    public func exactLocation(for candidate: RollbackCandidate) -> URL? {
        guard let path = candidate.resultingItemURL, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 在废纸篓里按原始文件名找候选条目。Finder 会把同名文件改成
    /// `原名 MM-DD-HH-MM-SS.ext` 或 `原名 2.ext`，所以用"原名是前缀"匹配。
    /// 只做只读匹配，不移动、不删除任何文件。
    public func trashMatches(for candidate: RollbackCandidate) -> [URL] {
        guard case .trash = candidate.destination else { return [] }
        let base = candidate.displayName
        guard !base.isEmpty else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: TrashLocations.directory(),
            includingPropertiesForKeys: nil
        )) ?? []
        return items.filter { url in
            let name = url.lastPathComponent
            return name == base || name.hasPrefix(base + " ") || name.hasPrefix(base + ".")
        }
    }

    /// 备份目录仍存在时返回其 URL；不存在返回 nil，界面据此提示"备份位置已不可用"。
    public func backupDestination(for candidate: RollbackCandidate) -> URL? {
        guard case let .backup(path) = candidate.destination else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    /// 从审计 detail 里解析备份目标。兼容两种写法：
    /// - 当前版本："废纸篓失败后按用户选择备份到 /path/to/backup"
    /// - 早期版本可能只写了路径本身
    private static func backupPath(from detail: String) -> String? {
        let prefix = "废纸篓失败后按用户选择备份到 "
        if detail.hasPrefix(prefix) {
            let path = String(detail.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
        if detail.hasPrefix("/") || detail.hasPrefix("~") { return detail }
        return nil
    }
}
