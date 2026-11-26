import Foundation

// MARK: - 大文件筛选

/// 大文件的可解释分类。只按扩展名归类，不改写、不推断文件内容。
public enum LargeFileKind: String, CaseIterable, Identifiable, Sendable {
    case all
    case video
    case image
    case audio
    case archive
    case document
    case installer
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部类型"
        case .video: return "视频"
        case .image: return "图片与工程"
        case .audio: return "音频"
        case .archive: return "压缩包"
        case .document: return "文档"
        case .installer: return "安装包"
        case .other: return "其他"
        }
    }

    public static func classify(ext: String) -> LargeFileKind {
        switch ext.lowercased() {
        case "mp4", "mov", "mkv", "avi", "m4v", "webm", "flv", "wmv":
            return .video
        case "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif",
             "raw", "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "psd", "psb", "ai":
            return .image
        case "mp3", "wav", "aif", "aiff", "flac", "m4a", "aac", "ogg", "opus":
            return .audio
        case "dmg", "pkg", "mpkg", "iso":
            return .installer
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst", "tgz":
            return .archive
        case "pdf", "doc", "docx", "ppt", "pptx", "key", "pages", "numbers",
             "xls", "xlsx", "csv", "rtf", "txt", "md":
            return .document
        default:
            return .other
        }
    }
}

/// 修改时间区间。边界用自然日向前推算，避免夏令时导致 30 天差一小时。
public enum LargeFileAge: String, CaseIterable, Identifiable, Sendable {
    case any
    case recent30
    case recent180
    case recent365
    case older90
    case older180
    case older365

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: return "不限时间"
        case .recent30: return "30 天内"
        case .recent180: return "半年内"
        case .recent365: return "一年内"
        case .older90: return "90 天以上"
        case .older180: return "半年以上"
        case .older365: return "一年以上"
        }
    }

    public func matches(modifiedAt: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .any:
            return true
        case .recent30:
            guard let boundary = calendar.date(byAdding: .day, value: -30, to: now) else { return true }
            return modifiedAt >= boundary && modifiedAt <= now
        case .recent180:
            guard let boundary = calendar.date(byAdding: .day, value: -180, to: now) else { return true }
            return modifiedAt >= boundary && modifiedAt <= now
        case .recent365:
            guard let boundary = calendar.date(byAdding: .day, value: -365, to: now) else { return true }
            return modifiedAt >= boundary && modifiedAt <= now
        case .older90:
            guard let boundary = calendar.date(byAdding: .day, value: -90, to: now) else { return false }
            return modifiedAt < boundary
        case .older180:
            guard let boundary = calendar.date(byAdding: .day, value: -180, to: now) else { return false }
            return modifiedAt < boundary
        case .older365:
            guard let boundary = calendar.date(byAdding: .day, value: -365, to: now) else { return false }
            return modifiedAt < boundary
        }
    }
}

public enum LargeFileSort: String, CaseIterable, Identifiable, Sendable {
    case size
    case modified
    case name

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .size: return "体积从大到小"
        case .modified: return "修改时间从新到旧"
        case .name: return "文件名 A–Z"
        }
    }
}

public struct LargeFileRecord: Identifiable, Hashable, Sendable {
    public let path: String
    public let bytes: Int64
    public let modifiedAt: Date

    public init(path: String, bytes: Int64, modifiedAt: Date) {
        self.path = path
        self.bytes = bytes
        self.modifiedAt = modifiedAt
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var kind: LargeFileKind { LargeFileKind.classify(ext: (path as NSString).pathExtension) }
}

/// 所有条件同时生效：体积下限、类型、时间、关键词，最后按指定顺序排序。
public struct LargeFileFilter: Equatable, Sendable {
    public var query: String
    public var kind: LargeFileKind
    public var age: LargeFileAge
    public var minMegabytes: Int
    public var sort: LargeFileSort

    public init(query: String = "", kind: LargeFileKind = .all, age: LargeFileAge = .any,
                minMegabytes: Int = 100, sort: LargeFileSort = .size) {
        self.query = query
        self.kind = kind
        self.age = age
        self.minMegabytes = minMegabytes
        self.sort = sort
    }

    public func apply(to records: [LargeFileRecord], now: Date = Date(),
                      calendar: Calendar = .current) -> [LargeFileRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let minimumBytes = Int64(max(1, minMegabytes)) * 1_000_000
        let filtered = records.filter { record in
            guard record.bytes >= minimumBytes else { return false }
            guard kind == .all || record.kind == kind else { return false }
            guard age.matches(modifiedAt: record.modifiedAt, now: now, calendar: calendar) else { return false }
            guard !needle.isEmpty else { return true }
            return record.path.localizedCaseInsensitiveContains(needle)
                || record.name.localizedCaseInsensitiveContains(needle)
        }
        switch sort {
        case .size:
            return filtered.sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        case .modified:
            return filtered.sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        case .name:
            return filtered.sorted {
                let result = $0.name.localizedStandardCompare($1.name)
                if result != .orderedSame { return result == .orderedAscending }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        }
    }
}

// MARK: - 重复文件只读分组

/// 已算好摘要的候选。摘要为空表示读取失败，不参与成组。
public struct DuplicateFileRecord: Identifiable, Hashable, Sendable {
    public let path: String
    public let bytes: Int64
    public let modifiedAt: Date
    public let digest: String

    public init(path: String, bytes: Int64, modifiedAt: Date, digest: String) {
        self.path = path
        self.bytes = bytes
        self.modifiedAt = modifiedAt
        self.digest = digest
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let bytes: Int64
    public let digest: String
    public let files: [DuplicateFileRecord]

    public init(bytes: Int64, digest: String, files: [DuplicateFileRecord]) {
        self.bytes = bytes
        self.digest = digest
        self.files = files
    }

    public var id: String { "\(digest)|\(bytes)" }
    public var count: Int { files.count }
    /// 假设只保留一份，其余份占用的体积。仅作说明，不产生任何选择或删除动作。
    public var recoverableBytes: Int64 { bytes * Int64(max(0, files.count - 1)) }
}

public struct DuplicateReview: Sendable {
    public let groups: [DuplicateGroup]
    public let candidates: Int
    public let hashedFiles: Int
    public let skippedFiles: Int
    public let truncated: Bool
    public let timedOut: Bool
    public let generatedAt: Date

    public init(groups: [DuplicateGroup], candidates: Int, hashedFiles: Int, skippedFiles: Int,
                truncated: Bool, timedOut: Bool, generatedAt: Date = Date()) {
        self.groups = groups
        self.candidates = candidates
        self.hashedFiles = hashedFiles
        self.skippedFiles = skippedFiles
        self.truncated = truncated
        self.timedOut = timedOut
        self.generatedAt = generatedAt
    }

    /// 整个功能只用于核对：没有选择集合，也不会进入清理批处理。
    public static let policy = "只核对，不勾选、不删除，也不参与清理批处理。"

    public var groupCount: Int { groups.count }
    public var fileCount: Int { groups.reduce(0) { $0 + $1.count } }
    public var recoverableBytes: Int64 { groups.reduce(0) { $0 + $1.recoverableBytes } }
}

public enum DuplicateGrouper {
    public static func group(_ records: [DuplicateFileRecord]) -> [DuplicateGroup] {
        struct Key: Hashable {
            let bytes: Int64
            let digest: String
        }
        var buckets: [Key: [DuplicateFileRecord]] = [:]
        for record in records {
            let digest = record.digest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !digest.isEmpty else { continue }
            buckets[Key(bytes: record.bytes, digest: digest), default: []].append(record)
        }
        return buckets.compactMap { key, files -> DuplicateGroup? in
            guard files.count > 1 else { return nil }
            let sortedFiles = files.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            return DuplicateGroup(bytes: key.bytes, digest: key.digest, files: sortedFiles)
        }
        .sorted {
            if $0.recoverableBytes != $1.recoverableBytes {
                return $0.recoverableBytes > $1.recoverableBytes
            }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.digest < $1.digest
        }
    }
}

// MARK: - 多维判读（V0.9.0）

/// 只根据路径、类型和修改时间给出“先看哪一类”，不读取文件内容，也不承诺可删。
public enum LargeFileCandidateLevel: String, Sendable, Comparable {
    case recent
    case personal
    case review
    case priority

    public var chineseName: String {
        switch self {
        case .recent: return "近期修改"
        case .personal: return "个人内容"
        case .review: return "需要核对"
        case .priority: return "优先核对"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .priority: return 0
        case .review: return 1
        case .personal: return 2
        case .recent: return 3
        }
    }

    public static func < (lhs: LargeFileCandidateLevel, rhs: LargeFileCandidateLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

public struct LargeFileJudgement: Sendable, Equatable {
    public let level: LargeFileCandidateLevel
    public let title: String
    public let reason: String
    /// 只表示“值得先看”，从不表示“可以自动删”。
    public let isDimensionCandidate: Bool

    public init(level: LargeFileCandidateLevel, title: String,
                reason: String, isDimensionCandidate: Bool) {
        self.level = level
        self.title = title
        self.reason = reason
        self.isDimensionCandidate = isDimensionCandidate
    }
}

public enum StorageDimension: String, CaseIterable, Identifiable, Sendable {
    case oldInstaller
    case oldArchive
    case oldDownload
    case oldLarge

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .oldInstaller: return "旧安装包"
        case .oldArchive: return "旧压缩包"
        case .oldDownload: return "长期未改的下载"
        case .oldLarge: return "半年以上大文件"
        }
    }

    public var detail: String {
        switch self {
        case .oldInstaller:
            return "90 天以上没改的 dmg / pkg / iso。安装包通常能重新下载，但仍要先确认不是唯一版本。"
        case .oldArchive:
            return "180 天以上没改的 zip / tar / 7z。可能是旧备份，先解开看一眼或确认项目已经归档。"
        case .oldDownload:
            return "下载目录里 180 天以上没改的文件。按修改时间判断，不假装知道“最近打开”。"
        case .oldLarge:
            return "半年以上没改、体积 100 MB 以上的文件。可能是一次性素材，也可能是长期归档。"
        }
    }
}

public extension LargeFileRecord {
    func judgement(home: String, now: Date = Date()) -> LargeFileJudgement {
        let age = now.timeIntervalSince(modifiedAt) / 86_400
        let inDownloads = path.hasPrefix(home + "/Downloads/")
        if age >= 0, age < 30 {
            return LargeFileJudgement(
                level: .recent,
                title: "近期修改",
                reason: "30 天内动过，可能是正在做的项目；除非确认是临时副本，否则先别删。",
                isDimensionCandidate: false
            )
        }
        if kind == .installer, age >= 90 {
            return LargeFileJudgement(
                level: .priority,
                title: "旧安装包",
                reason: "超过 90 天没改。安装包一般能从官网重新下载；先确认版本号，再决定是否移废纸篓。",
                isDimensionCandidate: true
            )
        }
        if kind == .archive, age >= 180 {
            return LargeFileJudgement(
                level: .priority,
                title: "旧压缩包",
                reason: "超过 180 天没改。很可能是旧备份；先确认解压后的内容，或确认原项目还在。",
                isDimensionCandidate: true
            )
        }
        if inDownloads, age >= 180 {
            return LargeFileJudgement(
                level: .review,
                title: "长期未改的下载",
                reason: "在下载目录里超过 180 天没改。先看是否已经归档到项目目录；如果是唯一素材，不要删。",
                isDimensionCandidate: true
            )
        }
        if age >= 180 {
            return LargeFileJudgement(
                level: .review,
                title: "半年以上未改",
                reason: "半年没改不等于没用，也可能是归档或长期素材。先核对项目和重复副本，再手动确认。",
                isDimensionCandidate: true
            )
        }
        if kind == .video || kind == .image || kind == .audio || kind == .document {
            return LargeFileJudgement(
                level: .personal,
                title: "个人内容",
                reason: "照片、视频、音频和文档更可能是成片或源素材；优先核对重复组和项目备份，不按体积直接删。",
                isDimensionCandidate: false
            )
        }
        return LargeFileJudgement(
            level: .review,
            title: "需要核对",
            reason: "类型不明确，不能只凭文件名猜用途；先看路径、项目归属和是否重复。",
            isDimensionCandidate: false
        )
    }

    func matches(_ dimension: StorageDimension, home: String, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(modifiedAt) / 86_400
        switch dimension {
        case .oldInstaller:
            return kind == .installer && age >= 90
        case .oldArchive:
            return kind == .archive && age >= 180
        case .oldDownload:
            return path.hasPrefix(home + "/Downloads/") && age >= 180
        case .oldLarge:
            return age >= 180
        }
    }
}

public struct StorageDimensionSummary: Sendable, Equatable {
    public let dimension: StorageDimension
    public let count: Int
    public let bytes: Int64

    public init(dimension: StorageDimension, count: Int, bytes: Int64) {
        self.dimension = dimension
        self.count = count
        self.bytes = bytes
    }

    public static func summarize(_ records: [LargeFileRecord], home: String,
                                 now: Date = Date()) -> [StorageDimensionSummary] {
        StorageDimension.allCases.map { dimension in
            let hits = records.filter { $0.matches(dimension, home: home, now: now) }
            return StorageDimensionSummary(
                dimension: dimension,
                count: hits.count,
                bytes: hits.reduce(0) { $0 + $1.bytes }
            )
        }
    }
}
