import Foundation

/// 一条本机日常快照。字段全部来自系统只读接口；读不到就留空，不估算。
public struct DailyMetricSample: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let at: Date
    public let chargePercent: Int?
    public let isCharging: Bool
    public let externalPower: Bool
    public let adapterWatts: Int?
    public let cycleCount: Int?
    public let healthPercent: Double?
    public let temperatureC: Double?
    public let thermalPressure: String
    public let lowPowerMode: Bool
    public let diskFreeBytes: Int64?
    public let memoryUsedBytes: Int64?
    public let memoryTotalBytes: Int64?

    public init(
        id: UUID = UUID(),
        at: Date = Date(),
        chargePercent: Int?,
        isCharging: Bool,
        externalPower: Bool,
        adapterWatts: Int?,
        cycleCount: Int?,
        healthPercent: Double?,
        temperatureC: Double?,
        thermalPressure: String,
        lowPowerMode: Bool,
        diskFreeBytes: Int64?,
        memoryUsedBytes: Int64?,
        memoryTotalBytes: Int64?
    ) {
        self.id = id
        self.at = at
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.externalPower = externalPower
        self.adapterWatts = adapterWatts
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
        self.temperatureC = temperatureC
        self.thermalPressure = thermalPressure
        self.lowPowerMode = lowPowerMode
        self.diskFreeBytes = diskFreeBytes
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
    }
}

/// 按自然日聚合后的电池与资源摘要。比例都是「样本占比」，不是连续分钟数。
public struct DailyBatterySummary: Identifiable, Equatable, Sendable {
    public let day: Date
    public let sampleCount: Int
    public let coverageSeconds: TimeInterval
    public let chargeMin: Int?
    public let chargeMax: Int?
    public let chargeEnd: Int?
    public let pluggedSampleRatio: Double
    public let chargingSampleRatio: Double
    public let healthPercent: Double?
    public let cycleStart: Int?
    public let cycleEnd: Int?
    public let maxTemperatureC: Double?
    public let averageTemperatureC: Double?
    public let thermalAlertSamples: Int
    public let diskFreeStart: Int64?
    public let diskFreeEnd: Int64?
    public let memoryUsedPeak: Int64?
    public var id: Date { day }

    public var cycleDelta: Int? {
        guard let cycleStart, let cycleEnd else { return nil }
        return cycleEnd - cycleStart
    }
}

public struct BatteryGuardFinding: Identifiable, Equatable, Sendable {
    public enum Level: String, Codable, CaseIterable, Sendable {
        case attention
        case insufficient
        case good
    }

    public let id: String
    public let level: Level
    public let title: String
    public let detail: String

    public init(id: String, level: Level, title: String, detail: String) {
        self.id = id
        self.level = level
        self.title = title
        self.detail = detail
    }

    public var priority: Int {
        switch level {
        case .attention: return 0
        case .insufficient: return 1
        case .good: return 2
        }
    }
}

/// 本地 JSONL 日常记录。默认放在 Application Support/雪，永不联网。
public struct DailyJournal: Sendable {
    public let fileURL: URL
    private let calendar: Calendar

    public init(fileURL: URL? = nil, calendar: Calendar = .current) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            self.fileURL = appSupport
                .appendingPathComponent(SnowIdentity.supportDirectoryName, isDirectory: true)
                .appendingPathComponent("daily-metrics.jsonl")
        }
        self.calendar = calendar
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

    /// 追加一条样本。重复时间点由调用方按采样间隔去重，存储层不擅自丢弃。
    public func append(_ sample: DailyMetricSample) throws {
        try prepareFile()
        var line = try encoder.encode(sample)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// 读取全部样本；坏行跳过，不影响后续记录。
    public func samples() throws -> [DailyMetricSample] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = self.decoder
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(DailyMetricSample.self, from: data)
        }
    }

    public func latestSample() throws -> DailyMetricSample? {
        try samples().max { $0.at < $1.at }
    }

    /// 按自然日聚合最近 N 天。只返回有样本的日期，不用空值伪造趋势。
    public func summaries(days: Int = 7, now: Date = Date()) throws -> [DailyBatterySummary] {
        let limit = max(1, min(365, days))
        let startOfToday = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(limit - 1), to: startOfToday) else {
            return []
        }
        let filtered = try samples().filter { $0.at >= start && $0.at <= now }
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.at) }
        return grouped.keys.sorted().compactMap { day in
            guard let items = grouped[day]?.sorted(by: { $0.at < $1.at }), !items.isEmpty else { return nil }
            let charges = items.compactMap(\.chargePercent)
            let temps = items.compactMap(\.temperatureC)
            let health = items.compactMap(\.healthPercent).last
            let cycles = items.compactMap(\.cycleCount)
            let disks = items.compactMap(\.diskFreeBytes)
            let memories = items.compactMap(\.memoryUsedBytes)
            let count = items.count
            let coverage = max(0, items[count - 1].at.timeIntervalSince(items[0].at))
            return DailyBatterySummary(
                day: day,
                sampleCount: count,
                coverageSeconds: coverage,
                chargeMin: charges.min(),
                chargeMax: charges.max(),
                chargeEnd: charges.last,
                pluggedSampleRatio: Double(items.filter(\.externalPower).count) / Double(count),
                chargingSampleRatio: Double(items.filter(\.isCharging).count) / Double(count),
                healthPercent: health,
                cycleStart: cycles.first,
                cycleEnd: cycles.last,
                maxTemperatureC: temps.max(),
                averageTemperatureC: temps.isEmpty ? nil : temps.reduce(0, +) / Double(temps.count),
                thermalAlertSamples: items.filter {
                    $0.thermalPressure == "严重" || $0.thermalPressure == "临界"
                }.count,
                diskFreeStart: disks.first,
                diskFreeEnd: disks.last,
                memoryUsedPeak: memories.max()
            )
        }
    }

    /// 清理超过保留期的样本，返回删除条数。只在显式调用时重写文件。
    @discardableResult
    public func prune(keepingDays: Int = 120, now: Date = Date()) throws -> Int {
        let limit = max(1, keepingDays)
        guard let cutoff = calendar.date(byAdding: .day, value: -limit, to: calendar.startOfDay(for: now)) else {
            return 0
        }
        let all = try samples()
        let kept = all.filter { $0.at >= cutoff }
        guard kept.count != all.count else { return 0 }
        let encoder = self.encoder
        var text = ""
        for sample in kept {
            guard let data = try? encoder.encode(sample),
                  let line = String(data: data, encoding: .utf8) else { continue }
            text += line + "\n"
        }
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return all.count - kept.count
    }

    /// 生成只含本机记录的 Markdown 周报；不调用模型，不推断未记录的分钟数。
    public func report(days: Int = 7, now: Date = Date()) throws -> String {
        let summaries = try summaries(days: days, now: now)
        let latest = try latestSample()
        let findings = BatteryGuardAdvisor.findings(summaries: summaries, latest: latest, now: now)
        let totalSamples = summaries.reduce(0) { $0 + $1.sampleCount }
        let totalCoverage = summaries.reduce(0) { $0 + $1.coverageSeconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = []
        lines.append("# 雪 · 电池守护周报")
        lines.append("")
        lines.append("- 生成时间：\(formatter.string(from: now))")
        lines.append("- 统计范围：最近 \(max(1, days)) 天")
        lines.append("- 数据覆盖：\(summaries.count) 天 / \(totalSamples) 个样本 / 记录跨度 \(coverageText(totalCoverage))")
        if let latest {
            lines.append("- 最近记录：\(formatter.string(from: latest.at)) · \(latest.chargePercent.map { "\($0)%" } ?? "电量读不到") · \(powerText(latest))")
        } else {
            lines.append("- 最近记录：还没有样本")
        }
        lines.append("")
        lines.append("## 结论")
        lines.append("")
        for finding in findings.sorted(by: { $0.priority < $1.priority }) {
            lines.append("- **\(finding.title)**：\(finding.detail)")
        }
        lines.append("")
        lines.append("## 每日明细")
        lines.append("")
        if summaries.isEmpty {
            lines.append("还没有可统计的记录。打开雪并保持菜单栏常驻后，每 10 分钟会记录一次。")
        } else {
            lines.append("| 日期 | 样本 | 电量最低–最高 | 日末 | 插电样本 | 循环 | 健康度 | 最高温度 | 磁盘可用 |")
            lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
            for day in summaries.reversed() {
                let chargeRange: String
                if let low = day.chargeMin, let high = day.chargeMax {
                    chargeRange = "\(low)–\(high)%"
                } else {
                    chargeRange = "—"
                }
                let cycle: String
                if let start = day.cycleStart, let end = day.cycleEnd {
                    let delta = end - start
                    cycle = delta == 0 ? "\(end)" : "\(start)→\(end)（\(delta >= 0 ? "+" : "")\(delta)）"
                } else {
                    cycle = "—"
                }
                lines.append("| \(formatter.string(from: day.day).prefix(10)) | \(day.sampleCount) | \(chargeRange) | \(day.chargeEnd.map { "\($0)%" } ?? "—") | \(Int((day.pluggedSampleRatio * 100).rounded()))% | \(cycle) | \(day.healthPercent.map { String(format: "%.0f%%", $0) } ?? "—") | \(day.maxTemperatureC.map { String(format: "%.1f °C", $0) } ?? "读不到") | \(day.diskFreeEnd.map { bytesText($0) } ?? "—") |")
            }
        }
        lines.append("")
        lines.append("## 口径")
        lines.append("")
        lines.append("- 采样频率为每 10 分钟一次；只有雪在运行时才会记录，关掉后不补采，因此「插电样本占比」不是连续分钟数。")
        lines.append("- 温度只在系统确实提供时记录；读不到时留空，不用估算值参与判断。")
        lines.append("- 循环增长是本次统计窗口内的首末差值，不等于 Apple 的官方电池循环口径。")
        lines.append("- 本报告由本机模板生成，不调用模型；建议只做行为提醒，不修改任何系统设置。")
        return lines.joined(separator: "\n") + "\n"
    }

    private func coverageText(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }

    private func powerText(_ sample: DailyMetricSample) -> String {
        if sample.isCharging { return "正在充电" }
        if sample.externalPower { return "已接电源" }
        return "未充电"
    }

    private func bytesText(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}

/// 把日常记录翻成可解释的电池习惯建议。规则命中才说，样本不足先承认样本不足。
public enum BatteryGuardAdvisor {
    public static func findings(
        summaries: [DailyBatterySummary],
        latest: DailyMetricSample? = nil,
        now: Date = Date()
    ) -> [BatteryGuardFinding] {
        let totalSamples = summaries.reduce(0) { $0 + $1.sampleCount }
        let totalCoverage = summaries.reduce(0) { $0 + $1.coverageSeconds }
        var result: [BatteryGuardFinding] = []

        if summaries.isEmpty {
            return [
                BatteryGuardFinding(
                    id: "no-samples",
                    level: .insufficient,
                    title: "还没有日常记录",
                    detail: "打开雪并让菜单栏常驻，每 10 分钟会记录一次。至少积累 24 小时后再看长期习惯，避免把一次使用当成规律。"
                )
            ]
        }

        if totalSamples < 12 || totalCoverage < 2 * 3600 {
            result.append(BatteryGuardFinding(
                id: "insufficient-data",
                level: .insufficient,
                title: "记录刚开始，先不急着下结论",
                detail: "目前只有 \(totalSamples) 个样本，记录跨度 \(coverageText(totalCoverage))。至少积累 24 小时、几十个样本后，长期插电、高温和深度放电的判断才可靠。"
            ))
        }

        let pluggedHighDays = summaries.filter {
            $0.pluggedSampleRatio >= 0.8 && ($0.chargeEnd ?? 0) >= 80
        }.count
        if pluggedHighDays >= 3 {
            result.append(BatteryGuardFinding(
                id: "long-plugged",
                level: .attention,
                title: "长期插电且电量偏高",
                detail: "最近 \(summaries.count) 天里有 \(pluggedHighDays) 天满足「插电样本占比 ≥ 80% 且日末电量 ≥ 80%」。如果大部分时间接电源，建议在「系统设置 › 电池」开启优化充电，把日常上限压到 80% 左右；雪只提醒，不代为修改。"
            ))
        }

        let hottest = summaries.compactMap(\.maxTemperatureC).max()
        let thermalAlerts = summaries.reduce(0) { $0 + $1.thermalAlertSamples }
        if (hottest ?? 0) >= 35 || thermalAlerts > 0 {
            let tempText = hottest.map { String(format: "最高记录 %.1f °C", $0) } ?? "温度读不到"
            result.append(BatteryGuardFinding(
                id: "high-temperature",
                level: .attention,
                title: "记录到高温或热压力告警",
                detail: "\(tempText)，另有 \(thermalAlerts) 个样本处于「严重 / 临界」热压力。高温会加快容量衰减；避免边充边跑重载，先保存工作并降低负载。温度读不到时只按系统热压力判断。"
            ))
        }

        let deepDischargeDays = summaries.filter { ($0.chargeMin ?? 100) <= 20 }.count
        if deepDischargeDays >= 2 {
            result.append(BatteryGuardFinding(
                id: "deep-discharge",
                level: .attention,
                title: "出现过较深的放电",
                detail: "最近 \(summaries.count) 天里有 \(deepDischargeDays) 天最低电量 ≤ 20%。深度放电会增加循环压力；尽量在 20–30% 左右补电，不必每次都用到很低。"
            ))
        }

        if let first = summaries.first, let last = summaries.last,
           let start = first.cycleStart, let end = last.cycleEnd {
            let delta = end - start
            if delta >= 4 {
                result.append(BatteryGuardFinding(
                    id: "cycle-growth",
                    level: .attention,
                    title: "统计窗口内循环增长较快",
                    detail: "记录窗口内循环次数从 \(start) 增到 \(end)，增加 \(delta) 次。若主要来自高频满充满放，优先改成浅充浅放，并减少高温下的重载使用。"
                ))
            }
        }

        if latest?.thermalPressure == "严重" || latest?.thermalPressure == "临界" {
            if !result.contains(where: { $0.id == "high-temperature" }) {
                result.append(BatteryGuardFinding(
                    id: "current-thermal",
                    level: .attention,
                    title: "当前热压力偏高",
                    detail: "最近一次记录显示系统热压力为「\(latest?.thermalPressure ?? "读不到")」。先降低负载，等温度回落再继续。"
                ))
            }
        }

        if !result.contains(where: { $0.level == .attention }) && totalSamples >= 12 && totalCoverage >= 2 * 3600 {
            result.append(BatteryGuardFinding(
                id: "no-obvious-risk",
                level: .good,
                title: "当前没有明显的高风险习惯",
                detail: "已记录 \(totalSamples) 个样本。继续保持避免高温、长期高电量插电和频繁深度放电；这不等同于电池健康检测，容量与循环仍以系统报告为准。"
            ))
        }

        return result.sorted { $0.priority < $1.priority }
    }

    private static func coverageText(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }
}
