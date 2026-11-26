import Foundation

/// M3 空间时间线：一次目录级只读快照。
/// 条目只保存路径、体积和“是否读全”，不保存文件名列表或文件内容。
public struct SpaceSnapshotEntry: Codable, Hashable, Sendable {
    public let path: String
    public let bytes: Int64
    public let isPartial: Bool

    public init(path: String, bytes: Int64, isPartial: Bool = false) {
        self.path = path
        self.bytes = bytes
        self.isPartial = isPartial
    }
}

public struct SpaceSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let at: Date
    public let diskTotalBytes: Int64?
    public let diskFreeBytes: Int64?
    public let source: String
    public let note: String
    public let entries: [SpaceSnapshotEntry]

    public init(
        id: UUID = UUID(),
        at: Date = Date(),
        diskTotalBytes: Int64? = nil,
        diskFreeBytes: Int64? = nil,
        source: String = "manual",
        note: String = "",
        entries: [SpaceSnapshotEntry]
    ) {
        self.id = id
        self.at = at
        self.diskTotalBytes = diskTotalBytes
        self.diskFreeBytes = diskFreeBytes
        self.source = source
        self.note = note
        self.entries = entries
    }

    public var partialCount: Int { entries.filter(\.isPartial).count }
}

/// 把一句中文时间窗落成起止时间。只识别保守的常见说法，识别不了就用最近 7 天。
public struct SpaceDeltaQuery: Sendable, Equatable {
    public let rawText: String
    public let label: String
    public let start: Date
    public let end: Date

    public init(rawText: String, label: String, start: Date, end: Date) {
        self.rawText = rawText
        self.label = label
        self.start = start
        self.end = end
    }

    /// 是否在问“空间为什么变了”。不是所有带“少”的句子都算，避免把“日志少了”当空间问题。
    public static func isChangeQuestion(_ rawText: String) -> Bool {
        let text = normalized(rawText)
        guard !text.isEmpty else { return false }
        let changeWords = [
            "少了", "少掉", "不见", "用掉", "吃掉", "去哪", "哪去", "哪去了",
            "哪里去了", "都去哪", "去哪儿", "变化", "下降", "减少", "增加",
            "多了", "满了", "没空间", "占满"
        ]
        let diskWords = [
            "空间", "磁盘", "硬盘", "存储", "容量", "系统盘", "数据盘",
            "gb", "内存", "macintosh"
        ]
        let hasSizeUnit = text.range(of: #"[0-9]+(?:\.[0-9]+)?(?:gb|g|mb|tb)"#, options: .regularExpression) != nil
        let hasChange = changeWords.contains { text.contains($0) }
        let hasDisk = diskWords.contains { text.contains($0) } || hasSizeUnit
        return hasChange && hasDisk
    }

    public static func parse(_ rawText: String, now: Date = Date(), calendar: Calendar = .current) -> SpaceDeltaQuery {
        let text = normalized(rawText)
        let startOfToday = calendar.startOfDay(for: now)

        func date(byAdding component: Calendar.Component, value: Int, to date: Date) -> Date {
            calendar.date(byAdding: component, value: value, to: date) ?? date
        }

        if text.contains("一下午") || text.contains("这下午") {
            return SpaceDeltaQuery(rawText: rawText, label: "这一下午",
                                   start: date(byAdding: .hour, value: -5, to: now), end: now)
        }
        if text.contains("刚才") || text.contains("刚刚") || text.contains("一小时") || text.contains("这小时") {
            return SpaceDeltaQuery(rawText: rawText, label: "最近一小时",
                                   start: date(byAdding: .hour, value: -1, to: now), end: now)
        }
        if text.contains("昨天") {
            let start = date(byAdding: .day, value: -1, to: startOfToday)
            return SpaceDeltaQuery(rawText: rawText, label: "昨天", start: start, end: startOfToday)
        }
        if text.contains("前天") {
            let start = date(byAdding: .day, value: -2, to: startOfToday)
            return SpaceDeltaQuery(rawText: rawText, label: "前天", start: start, end: startOfToday)
        }
        if text.contains("今天") || text.contains("今早") || text.contains("今晚") {
            return SpaceDeltaQuery(rawText: rawText, label: "今天", start: startOfToday, end: now)
        }
        if text.contains("这周") || text.contains("本周") || text.contains("一周") || text.contains("最近7天") {
            return SpaceDeltaQuery(rawText: rawText, label: "最近七天",
                                   start: date(byAdding: .day, value: -7, to: now), end: now)
        }
        if text.contains("这月") || text.contains("本月") || text.contains("一个月") || text.contains("30天") {
            return SpaceDeltaQuery(rawText: rawText, label: "最近三十天",
                                   start: date(byAdding: .day, value: -30, to: now), end: now)
        }

        if let hours = firstNumber(in: text, pattern: #"([0-9]+)(?:小时|h)"#), hours > 0, hours <= 168 {
            return SpaceDeltaQuery(rawText: rawText, label: "最近 \(hours) 小时",
                                   start: date(byAdding: .hour, value: -hours, to: now), end: now)
        }
        if let days = firstNumber(in: text, pattern: #"([0-9]+)(?:天|日)"#), days > 0, days <= 180 {
            return SpaceDeltaQuery(rawText: rawText, label: "最近 \(days) 天",
                                   start: date(byAdding: .day, value: -days, to: now), end: now)
        }
        if let weeks = firstNumber(in: text, pattern: #"([0-9]+)(?:周|星期)"#), weeks > 0, weeks <= 26 {
            let days = weeks * 7
            return SpaceDeltaQuery(rawText: rawText, label: "最近 \(weeks) 周",
                                   start: date(byAdding: .day, value: -days, to: now), end: now)
        }

        return SpaceDeltaQuery(rawText: rawText, label: "最近七天",
                               start: date(byAdding: .day, value: -7, to: now), end: now)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
    }

    private static func firstNumber(in text: String, pattern: String) -> Int? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(text[range])
        let digits = match.filter(\.isNumber)
        return Int(digits)
    }
}

public enum SpaceDeltaEntryState: String, Codable, Sendable {
    case grew
    case shrank
    case appeared
    case disappeared
    case unchanged
}

public struct SpaceDeltaEntry: Identifiable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let beforeBytes: Int64
    public let afterBytes: Int64
    public let deltaBytes: Int64
    public let state: SpaceDeltaEntryState
    public let isPartial: Bool

    public var id: String { path }
    public var absoluteDelta: Int64 { abs(deltaBytes) }
}

/// 一次“变化账单”。所有数字都来自两次本机快照；没有数据就明说，不拿模型猜。
public struct SpaceDeltaReport: Sendable {
    public let ruleID: String
    public let query: SpaceDeltaQuery
    public let dataSufficient: Bool
    public let reason: String?
    public let baseline: SpaceSnapshot?
    public let current: SpaceSnapshot?
    public let snapshotCount: Int
    public let diskFreeStart: Int64?
    public let diskFreeEnd: Int64?
    public let diskFreeDelta: Int64?
    public let usedDelta: Int64?
    public let attributedBytes: Int64
    public let unexplainedBytes: Int64?
    public let topChanges: [SpaceDeltaEntry]
    public let partialCount: Int
    public let caveat: String
    public let explanation: String

    public var hasData: Bool { baseline != nil && current != nil && dataSufficient }
    public var freeText: String? {
        guard let diskFreeDelta else { return nil }
        if diskFreeDelta == 0 { return "可用空间没有变化" }
        return diskFreeDelta > 0
            ? "可用空间增加 \(AssistantBytes.text(diskFreeDelta))"
            : "可用空间减少 \(AssistantBytes.text(-diskFreeDelta))"
    }

    public init(
        ruleID: String = "space-delta",
        query: SpaceDeltaQuery,
        dataSufficient: Bool,
        reason: String?,
        baseline: SpaceSnapshot?,
        current: SpaceSnapshot?,
        snapshotCount: Int,
        diskFreeStart: Int64?,
        diskFreeEnd: Int64?,
        diskFreeDelta: Int64?,
        usedDelta: Int64?,
        attributedBytes: Int64,
        unexplainedBytes: Int64?,
        topChanges: [SpaceDeltaEntry],
        partialCount: Int,
        caveat: String,
        explanation: String
    ) {
        self.ruleID = ruleID
        self.query = query
        self.dataSufficient = dataSufficient
        self.reason = reason
        self.baseline = baseline
        self.current = current
        self.snapshotCount = snapshotCount
        self.diskFreeStart = diskFreeStart
        self.diskFreeEnd = diskFreeEnd
        self.diskFreeDelta = diskFreeDelta
        self.usedDelta = usedDelta
        self.attributedBytes = attributedBytes
        self.unexplainedBytes = unexplainedBytes
        self.topChanges = topChanges
        self.partialCount = partialCount
        self.caveat = caveat
        self.explanation = explanation
    }
}

public enum SpaceDeltaDiagnostic {
    /// 只比较两次快照的叶子目录，避免父目录和子目录重复计数。
    public static func report(
        snapshots: [SpaceSnapshot],
        query: SpaceDeltaQuery,
        now: Date = Date()
    ) -> SpaceDeltaReport {
        let sorted = snapshots.sorted { $0.at < $1.at }
        guard !sorted.isEmpty else {
            return insufficient(query: query, reason: "还没有任何空间快照。先到「空间分析」里记录两次快照，再来看变化。")
        }

        guard let endSnapshot = sorted.last(where: { $0.at <= query.end }) else {
            return insufficient(query: query, reason: "这个时间范围里还没有快照。")
        }
        let earlier = sorted.filter { $0.at < endSnapshot.at }
        guard let baseline = earlier.last(where: { $0.at <= query.start }) ?? earlier.last else {
            return insufficient(query: query, reason: "这个时间范围里只有一次快照，至少需要两次才能比较。")
        }

        let actualStart = baseline.at
        let actualEnd = endSnapshot.at
        let windowCount = sorted.filter { $0.at >= actualStart && $0.at <= actualEnd }.count
        guard actualEnd.timeIntervalSince(actualStart) >= 60 else {
            return insufficient(query: query, reason: "这两次快照相隔不到一分钟，空间还没稳定下来，暂时不能比较。")
        }

        let beforeEntries = leafEntries(of: baseline.entries)
        let afterEntries = leafEntries(of: endSnapshot.entries)
        let unionPaths = Set(beforeEntries.keys).union(afterEntries.keys)
        var changes: [SpaceDeltaEntry] = []
        var partialCount = 0

        for path in unionPaths {
            let before = beforeEntries[path]?.bytes ?? 0
            let after = afterEntries[path]?.bytes ?? 0
            let delta = after - before
            let state: SpaceDeltaEntryState
            if beforeEntries[path] == nil && afterEntries[path] != nil {
                state = .appeared
            } else if beforeEntries[path] != nil && afterEntries[path] == nil {
                state = .disappeared
            } else if delta > 0 {
                state = .grew
            } else if delta < 0 {
                state = .shrank
            } else {
                state = .unchanged
            }
            let partial = (beforeEntries[path]?.isPartial ?? false) || (afterEntries[path]?.isPartial ?? false)
            if partial && delta != 0 { partialCount += 1 }
            let name = path == "/" ? "/" : (path as NSString).lastPathComponent
            changes.append(
                SpaceDeltaEntry(
                    path: path,
                    name: name,
                    beforeBytes: before,
                    afterBytes: after,
                    deltaBytes: delta,
                    state: state,
                    isPartial: partial
                )
            )
        }

        changes.sort {
            if $0.absoluteDelta != $1.absoluteDelta { return $0.absoluteDelta > $1.absoluteDelta }
            return $0.path < $1.path
        }
        let top = Array(changes.filter { $0.deltaBytes != 0 }.prefix(8))
        let attributed = changes.reduce(Int64(0)) { $0 + $1.deltaBytes }

        let freeStart = baseline.diskFreeBytes
        let freeEnd = endSnapshot.diskFreeBytes
        let freeDelta: Int64?
        if let freeStart, let freeEnd {
            freeDelta = freeEnd - freeStart
        } else {
            freeDelta = nil
        }
        let usedDelta = freeDelta.map { -$0 }
        let unexplained: Int64?
        if let usedDelta {
            unexplained = usedDelta - attributed
        } else {
            unexplained = nil
        }

        var caveats: [String] = []
        if partialCount > 0 {
            caveats.append("有 \(partialCount) 个目录没读全，它们的体积只计了已读到的部分。")
        }
        if let freeDelta, freeDelta == 0 {
            caveats.append("这次磁盘可用空间口径没有变化；目录账面变化可能被 APFS 可回收空间、本地快照或统计取整抵消，不能当净增或净减。")
        } else if unexplained != nil {
            caveats.append("差额里可能包含 APFS 本地快照、系统更新、其他卷、废纸篓、临时文件或未纳入快照的位置；这些统一算“未归因”，不硬塞给某个目录。")
        } else {
            caveats.append("这次快照没有同时记录磁盘可用空间，无法核对“目录变化”和“系统可用空间”是否对得上。")
        }
        caveats.append("账单只比较当前快照覆盖的目录；没有出现在快照里的位置不会凭空出现。")

        let explanation = makeExplanation(
            query: query,
            freeStart: freeStart,
            freeEnd: freeEnd,
            freeDelta: freeDelta,
            usedDelta: usedDelta,
            attributed: attributed,
            unexplained: unexplained,
            top: top
        )

        return SpaceDeltaReport(
            query: query,
            dataSufficient: true,
            reason: nil,
            baseline: baseline,
            current: endSnapshot,
            snapshotCount: windowCount,
            diskFreeStart: freeStart,
            diskFreeEnd: freeEnd,
            diskFreeDelta: freeDelta,
            usedDelta: usedDelta,
            attributedBytes: attributed,
            unexplainedBytes: unexplained,
            topChanges: top,
            partialCount: partialCount,
            caveat: caveats.joined(separator: " "),
            explanation: explanation
        )
    }

    public static func insufficient(query: SpaceDeltaQuery, reason: String) -> SpaceDeltaReport {
        SpaceDeltaReport(
            query: query,
            dataSufficient: false,
            reason: reason,
            baseline: nil,
            current: nil,
            snapshotCount: 0,
            diskFreeStart: nil,
            diskFreeEnd: nil,
            diskFreeDelta: nil,
            usedDelta: nil,
            attributedBytes: 0,
            unexplainedBytes: nil,
            topChanges: [],
            partialCount: 0,
            caveat: "",
            explanation: reason
        )
    }

    /// 只保留没有子目录同时出现在快照里的条目。父目录已经被子目录覆盖，不再重复计。
    public static func leafEntries(of entries: [SpaceSnapshotEntry]) -> [String: SpaceSnapshotEntry] {
        var map: [String: SpaceSnapshotEntry] = [:]
        for entry in entries {
            let path = (entry.path as NSString).standardizingPath
            map[path] = SpaceSnapshotEntry(path: path, bytes: entry.bytes, isPartial: entry.isPartial)
        }
        let paths = Array(map.keys)
        for path in paths {
            let prefix = path == "/" ? "/" : path + "/"
            if paths.contains(where: { $0 != path && $0.hasPrefix(prefix) }) {
                map.removeValue(forKey: path)
            }
        }
        return map
    }

    private static func makeExplanation(
        query: SpaceDeltaQuery,
        freeStart: Int64?,
        freeEnd: Int64?,
        freeDelta: Int64?,
        usedDelta: Int64?,
        attributed: Int64,
        unexplained: Int64?,
        top: [SpaceDeltaEntry]
    ) -> String {
        var parts: [String] = []
        if let freeStart, let freeEnd {
            parts.append("可用空间从 \(AssistantBytes.text(freeStart)) 变成 \(AssistantBytes.text(freeEnd))。")
        } else {
            parts.append("这次快照没有磁盘可用空间的首末值，只能看目录变化。")
        }
        if let freeDelta, let usedDelta {
            if freeDelta == 0 {
                if attributed > 0 {
                    parts.append("系统可用空间口径没有变化；目录账面合计增加 \(AssistantBytes.text(attributed))，可能被 APFS 可回收空间、本地快照或统计取整抵消，不能当成净增。")
                } else if attributed < 0 {
                    parts.append("系统可用空间口径没有变化；目录账面合计减少 \(AssistantBytes.text(-attributed))，也不能当成系统净减。")
                } else {
                    parts.append("系统可用空间和目录账面都没有变化。")
                }
            } else if freeDelta < 0 {
                parts.append("系统占用增加 \(AssistantBytes.text(usedDelta))。")
            } else {
                parts.append("系统占用减少 \(AssistantBytes.text(-usedDelta))。")
            }
        }
        if top.isEmpty {
            parts.append("目录层面没有明显变化。")
        } else {
            let grown = top.filter { $0.deltaBytes > 0 }.prefix(3)
            let shrunk = top.filter { $0.deltaBytes < 0 }.prefix(3)
            if !grown.isEmpty {
                let text = grown.map { "\($0.name) 增加 \(AssistantBytes.text($0.deltaBytes))" }.joined(separator: "、")
                parts.append("主要增加：\(text)。")
            }
            if !shrunk.isEmpty {
                let text = shrunk.map { "\($0.name) 减少 \(AssistantBytes.text(-$0.deltaBytes))" }.joined(separator: "、")
                parts.append("主要减少：\(text)。")
            }
        }
        if let unexplained, abs(unexplained) >= 10_000_000 {
            if freeDelta == 0 {
                let difference = unexplained >= 0
                    ? AssistantBytes.text(unexplained)
                    : "-" + AssistantBytes.text(-unexplained)
                parts.append("系统可用空间没有变化，目录账面与 0 的差额 \(difference) 单列，不硬塞给某个目录。")
            } else if unexplained > 0 {
                parts.append("目录只解释了 \(AssistantBytes.text(attributed)) 的增长，另有 \(AssistantBytes.text(unexplained)) 未归因。")
            } else {
                parts.append("目录账面净增比系统实际占用多出 \(AssistantBytes.text(-unexplained))，这部分差额未归因。")
            }
        } else if unexplained != nil {
            parts.append("目录变化和系统可用空间基本对得上。")
        }
        return parts.joined(separator: " ")
    }
}

/// 空间时间线的自动记录策略。
/// 每次扫描成功写一张；没有扫描时，每 7 天至少补一张，避免用户忘了手动记录。
public enum SpaceSnapshotSchedule {
    public static let automaticInterval: TimeInterval = 7 * 24 * 60 * 60

    public static func isDue(
        lastAt: Date?,
        now: Date = Date(),
        interval: TimeInterval = automaticInterval
    ) -> Bool {
        guard let lastAt else { return true }
        return now.timeIntervalSince(lastAt) >= interval
    }
}

/// 本机 JSONL 空间快照。只追加，不覆盖；清理时按保留天数重写。
public struct SpaceSnapshotStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            self.fileURL = appSupport
                .appendingPathComponent(SnowIdentity.supportDirectoryName, isDirectory: true)
                .appendingPathComponent("space-snapshots.jsonl")
        }
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func prepareFile() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    public func append(_ snapshot: SpaceSnapshot) throws {
        try prepareFile()
        var line = try encoder.encode(snapshot)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// 坏行跳过；不因一条损坏丢掉整段历史。
    public func snapshots() throws -> [SpaceSnapshot] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = self.decoder
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(SpaceSnapshot.self, from: data)
        }.sorted { $0.at < $1.at }
    }

    public func latest() throws -> SpaceSnapshot? {
        try snapshots().last
    }

    public func report(for rawText: String = "", now: Date = Date()) throws -> SpaceDeltaReport {
        let query = SpaceDeltaQuery.parse(rawText, now: now)
        let values = try snapshots()
        return SpaceDeltaDiagnostic.report(snapshots: values, query: query, now: now)
    }

    @discardableResult
    public func prune(keepingDays: Int = 180, maxCount: Int = 720, now: Date = Date(),
                      calendar: Calendar = .current) throws -> Int {
        let all = try snapshots()
        let cutoff = calendar.date(byAdding: .day, value: -max(1, keepingDays),
                                   to: calendar.startOfDay(for: now)) ?? .distantPast
        var kept = all.filter { $0.at >= cutoff }
        if kept.count > maxCount {
            kept = Array(kept.suffix(maxCount))
        }
        guard kept.count != all.count else { return 0 }
        let encoder = self.encoder
        var text = ""
        for snapshot in kept {
            guard let data = try? encoder.encode(snapshot),
                  let line = String(data: data, encoding: .utf8) else { continue }
            text += line + "\n"
        }
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return all.count - kept.count
    }
}

public enum SpaceTimelineEventKind: String, Sendable {
    case snapshot
    case cleanup
}

public struct SpaceTimelineEvent: Identifiable, Sendable {
    public let id: String
    public let at: Date
    public let kind: SpaceTimelineEventKind
    public let title: String
    public let detail: String
    public let bytes: Int64?

    public init(id: String, at: Date, kind: SpaceTimelineEventKind,
                title: String, detail: String, bytes: Int64? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.title = title
        self.detail = detail
        self.bytes = bytes
    }
}

/// 只把“快照”和“清理成功事件”放在同一时间线上；失败事件与预览单列在审计页。
public enum SpaceTimelineBuilder {
    public static func events(
        snapshots: [SpaceSnapshot],
        audit: [AuditEvent],
        start: Date,
        end: Date
    ) -> [SpaceTimelineEvent] {
        var events: [SpaceTimelineEvent] = snapshots
            .filter { $0.at >= start && $0.at <= end }
            .map {
                SpaceTimelineEvent(
                    id: $0.id.uuidString,
                    at: $0.at,
                    kind: .snapshot,
                    title: "记录快照",
                    detail: "\($0.entries.count) 个目录",
                    bytes: $0.diskFreeBytes
                )
            }

        for event in audit where event.at >= start && event.at <= end {
            guard event.action.isCleanupAction, event.success else { continue }
            let name = event.path == "/" ? "/" : (event.path as NSString).lastPathComponent
            events.append(
                SpaceTimelineEvent(
                    id: event.id.uuidString,
                    at: event.at,
                    kind: .cleanup,
                    title: event.action.chineseLabel,
                    detail: name,
                    bytes: event.sizeBytes
                )
            )
        }

        return events.sorted { $0.at > $1.at }
    }
}
