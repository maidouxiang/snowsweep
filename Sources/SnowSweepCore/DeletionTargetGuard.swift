import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 文件类型。删除前复核用，避免"扫描时是普通目录，删除时已被换成符号链接"。
public enum FileKind: String, Codable, Sendable {
    case file
    case directory
    case symlink
    case other
}

/// 扫描时记录的文件身份。用 (device, inode) 唯一标识一个文件系统对象，
/// 不依赖路径——路径可以被替换，inode 不会。
public struct FileIdentity: Codable, Hashable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public let kind: FileKind

    public init(device: Int64, inode: UInt64, kind: FileKind) {
        self.device = device
        self.inode = inode
        self.kind = kind
    }

    /// 用 lstat 捕获身份，**不跟随符号链接**。返回 nil 表示路径此时不存在。
    public static func capture(at path: String) -> FileIdentity? {
        let expanded = NSString(string: path).expandingTildeInPath
        #if canImport(Darwin)
        var info = stat()
        guard lstat(expanded, &info) == 0 else { return nil }
        let mode = info.st_mode
        let kind: FileKind
        if (mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            kind = .symlink
        } else if (mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
            kind = .directory
        } else if (mode & mode_t(S_IFMT)) == mode_t(S_IFREG) {
            kind = .file
        } else {
            kind = .other
        }
        return FileIdentity(
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            kind: kind
        )
        #else
        _ = expanded
        return nil
        #endif
    }

    /// 两个身份是否指向同一个文件系统对象且类型未变。
    public func matches(_ other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode && kind == other.kind
    }
}

/// 删除前复核失败的原因。全部是"停止操作"，绝不自动重试或降级删除。
public enum TargetRevalidationError: Error, LocalizedError, Equatable {
    /// 严格模式下扫描报告没有身份信息（旧报告/手工构造），拒绝删除。
    case identityRequired(String)
    /// 文件在扫描后消失。可能已被其他程序清理，需重新扫描确认。
    case vanished(String)
    /// 扫描后路径被换成符号链接。这是典型的路径欺骗攻击。
    case becameSymbolicLink(String)
    /// (device, inode) 或类型与扫描时不一致：文件被替换过。
    case identityChanged(String, expected: FileIdentity, actual: FileIdentity)
    /// 命中保护清单，无论规则怎么说都不允许删除。
    case protectedPath(String)
    /// 路径规范化后为空或文件系统根，拒绝。
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case let .identityRequired(path):
            return "「\(path)」缺少扫描时的文件身份，无法确认安全，请重新扫描后再清理"
        case let .vanished(path):
            return "「\(path)」在扫描后已不存在，请重新扫描"
        case let .becameSymbolicLink(path):
            return "「\(path)」已变成快捷方式（符号链接），已停止操作以防误删真实文件"
        case let .identityChanged(path, expected, actual):
            return "「\(path)」在扫描后被替换（原 \(expected.kind.rawValue)／现 \(actual.kind.rawValue)），已停止操作"
        case let .protectedPath(path):
            return "「\(path)」在保护清单内，禁止删除"
        case let .unsafePath(path):
            return "路径「\(path)」不安全，已停止操作"
        }
    }

    /// 写入审计日志的简短原因。
    public var auditDetail: String { errorDescription ?? "删除前复核失败" }
}

/// 删除前复核器。测试可注入 Mock，生产用 `SystemTargetVerifier`。
public protocol TargetVerifying: Sendable {
    /// - Parameters:
    ///   - item: 待删除条目，携带扫描时捕获的身份（可能为空）
    ///   - strictIdentity: 为 true 时，缺少身份直接拒绝
    ///   - isProtected: 保护清单判定闭包，由 RuleEngine 提供
    func verify(
        _ item: ScanItem,
        strictIdentity: Bool,
        isProtected: (@Sendable (String) -> Bool)?
    ) throws
}

public struct SystemTargetVerifier: TargetVerifying {
    public init() {}

    public func verify(
        _ item: ScanItem,
        strictIdentity: Bool,
        isProtected: (@Sendable (String) -> Bool)?
    ) throws {
        let expanded = NSString(string: item.path).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard !standardized.isEmpty, standardized != "/" else {
            throw TargetRevalidationError.unsafePath(item.path)
        }

        if let isProtected, isProtected(item.path) {
            throw TargetRevalidationError.protectedPath(item.path)
        }

        // lstat 不跟随符号链接，拿到的就是路径本身指向的对象。
        guard let current = FileIdentity.capture(at: standardized) else {
            // 路径不存在时：严格模式仍允许交给 trasher 返回正常的"文件不存在"错误，
            // 但带身份的报告必须报"消失"，提示用户重新扫描。
            if item.identity != nil {
                throw TargetRevalidationError.vanished(item.path)
            }
            return
        }

        if current.kind == .symlink {
            throw TargetRevalidationError.becameSymbolicLink(item.path)
        }

        guard let expected = item.identity else {
            if strictIdentity {
                throw TargetRevalidationError.identityRequired(item.path)
            }
            // 兼容模式：旧报告没有身份，但至少确认了它不是符号链接。
            return
        }

        guard expected.matches(current) else {
            throw TargetRevalidationError.identityChanged(
                item.path, expected: expected, actual: current
            )
        }
    }
}
