import Foundation
import Testing
@testable import SnowSweepCore

private func journalURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("SnowSweepDaily-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("daily-metrics.jsonl")
}

private func fixedCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "zh_CN")
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    fixedCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func sample(
    at: Date,
    charge: Int?,
    plugged: Bool,
    charging: Bool = false,
    cycles: Int? = nil,
    health: Double? = nil,
    temperature: Double? = nil,
    thermal: String = "正常",
    diskFree: Int64? = nil,
    memoryUsed: Int64? = nil
) -> DailyMetricSample {
    DailyMetricSample(
        at: at,
        chargePercent: charge,
        isCharging: charging,
        externalPower: plugged,
        adapterWatts: plugged ? 140 : nil,
        cycleCount: cycles,
        healthPercent: health,
        temperatureC: temperature,
        thermalPressure: thermal,
        lowPowerMode: false,
        diskFreeBytes: diskFree,
        memoryUsedBytes: memoryUsed,
        memoryTotalBytes: 36_000_000_000
    )
}

private func summary(
    day: Date,
    sampleCount: Int = 12,
    coverage: TimeInterval = 8 * 3600,
    chargeMin: Int,
    chargeMax: Int,
    chargeEnd: Int,
    pluggedRatio: Double,
    cyclesStart: Int? = nil,
    cyclesEnd: Int? = nil,
    temp: Double? = nil,
    thermalAlerts: Int = 0
) -> DailyBatterySummary {
    DailyBatterySummary(
        day: day,
        sampleCount: sampleCount,
        coverageSeconds: coverage,
        chargeMin: chargeMin,
        chargeMax: chargeMax,
        chargeEnd: chargeEnd,
        pluggedSampleRatio: pluggedRatio,
        chargingSampleRatio: pluggedRatio,
        healthPercent: 97,
        cycleStart: cyclesStart,
        cycleEnd: cyclesEnd,
        maxTemperatureC: temp,
        averageTemperatureC: temp,
        thermalAlertSamples: thermalAlerts,
        diskFreeStart: 120_000_000_000,
        diskFreeEnd: 110_000_000_000,
        memoryUsedPeak: 20_000_000_000
    )
}

@Test func dailyJournalAppendsReadsAndToleratesBadLines() throws {
    let journal = DailyJournal(fileURL: journalURL(), calendar: fixedCalendar())
    let first = sample(at: date(2026, 11, 23, 9), charge: 80, plugged: true, cycles: 80, health: 97, temperature: 33, diskFree: 120_000_000_000)
    let second = sample(at: date(2026, 11, 23, 10), charge: 79, plugged: true, cycles: 80, health: 97, temperature: 34, diskFree: 119_000_000_000)
    try journal.append(first)
    try journal.append(second)

    let handle = try FileHandle(forWritingTo: journal.fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("not-json\n".utf8))
    try handle.close()

    let loaded = try journal.samples()
    #expect(loaded.count == 2)
    #expect(loaded.map(\.chargePercent) == [80, 79])
    #expect(try journal.latestSample()?.at == second.at)
    try? FileManager.default.removeItem(at: journal.fileURL.deletingLastPathComponent())
}

@Test func dailyJournalSummarizesDaysWithoutFakeEmptyDays() throws {
    let journal = DailyJournal(fileURL: journalURL(), calendar: fixedCalendar())
    try journal.append(sample(at: date(2026, 11, 23, 9), charge: 80, plugged: true, cycles: 80, health: 97, temperature: 35, thermal: "严重", diskFree: 120_000_000_000, memoryUsed: 18_000_000_000))
    try journal.append(sample(at: date(2026, 11, 23, 10), charge: 60, plugged: true, cycles: 80, health: 97, temperature: 30, diskFree: 119_000_000_000, memoryUsed: 19_000_000_000))
    try journal.append(sample(at: date(2026, 11, 23, 11), charge: 40, plugged: false, cycles: 81, health: 97, diskFree: 118_000_000_000, memoryUsed: 20_000_000_000))
    try journal.append(sample(at: date(2026, 11, 24, 9), charge: 90, plugged: true, charging: true, cycles: 83, health: 97, temperature: 31, diskFree: 117_000_000_000, memoryUsed: 21_000_000_000))
    try journal.append(sample(at: date(2026, 11, 24, 10), charge: 95, plugged: true, charging: true, cycles: 83, health: 97, temperature: 31, diskFree: 116_000_000_000, memoryUsed: 21_000_000_000))

    let summaries = try journal.summaries(days: 7, now: date(2026, 11, 24, 12))
    #expect(summaries.count == 2)
    #expect(summaries[0].sampleCount == 3)
    #expect(summaries[0].chargeMin == 40)
    #expect(summaries[0].chargeMax == 80)
    #expect(summaries[0].chargeEnd == 40)
    #expect(summaries[0].cycleDelta == 1)
    #expect(summaries[0].maxTemperatureC == 35)
    #expect(summaries[0].thermalAlertSamples == 1)
    #expect(summaries[0].pluggedSampleRatio > 0.66 && summaries[0].pluggedSampleRatio < 0.67)
    #expect(summaries[1].chargeMin == 90)
    #expect(summaries[1].chargeMax == 95)
    #expect(summaries[1].cycleDelta == 0)
    #expect(summaries[1].memoryUsedPeak == 21_000_000_000)
    try? FileManager.default.removeItem(at: journal.fileURL.deletingLastPathComponent())
}

@Test func batteryAdvisorFlagsLongPluggedHighCharge() {
    let days = [
        summary(day: date(2026, 11, 22, 0), chargeMin: 75, chargeMax: 100, chargeEnd: 100, pluggedRatio: 0.95),
        summary(day: date(2026, 11, 23, 0), chargeMin: 80, chargeMax: 100, chargeEnd: 100, pluggedRatio: 0.92),
        summary(day: date(2026, 11, 24, 0), chargeMin: 82, chargeMax: 100, chargeEnd: 98, pluggedRatio: 0.88)
    ]
    let findings = BatteryGuardAdvisor.findings(summaries: days, now: date(2026, 11, 24, 12))
    #expect(findings.contains { $0.id == "long-plugged" })
    #expect(findings.first { $0.id == "long-plugged" }?.level == .attention)
}

@Test func batteryAdvisorFlagsHeatDeepDischargeAndCycleGrowth() {
    let days = [
        summary(day: date(2026, 11, 22, 0), chargeMin: 15, chargeMax: 100, chargeEnd: 20, pluggedRatio: 0.4, cyclesStart: 80, cyclesEnd: 85, temp: 36, thermalAlerts: 1),
        summary(day: date(2026, 11, 23, 0), chargeMin: 10, chargeMax: 90, chargeEnd: 15, pluggedRatio: 0.3, cyclesStart: 85, cyclesEnd: 91, temp: 35),
        summary(day: date(2026, 11, 24, 0), chargeMin: 50, chargeMax: 80, chargeEnd: 60, pluggedRatio: 0.5, cyclesStart: 91, cyclesEnd: 92, temp: 30)
    ]
    let findings = BatteryGuardAdvisor.findings(summaries: days, now: date(2026, 11, 24, 12))
    #expect(findings.contains { $0.id == "high-temperature" })
    #expect(findings.contains { $0.id == "deep-discharge" })
    #expect(findings.contains { $0.id == "cycle-growth" })
    #expect(!findings.contains { $0.id == "long-plugged" })
}

@Test func batteryAdvisorAdmitsInsufficientSamples() {
    let one = summary(day: date(2026, 11, 24, 0), sampleCount: 1, coverage: 0, chargeMin: 80, chargeMax: 80, chargeEnd: 80, pluggedRatio: 1)
    let findings = BatteryGuardAdvisor.findings(summaries: [one], now: date(2026, 11, 24, 12))
    #expect(findings.contains { $0.id == "insufficient-data" })
    #expect(!findings.contains { $0.level == .good })
}

@Test func dailyReportContainsLocalOnlyDisclosureAndTable() throws {
    let journal = DailyJournal(fileURL: journalURL(), calendar: fixedCalendar())
    try journal.append(sample(at: date(2026, 11, 23, 9), charge: 80, plugged: true, cycles: 80, health: 97, temperature: 34, diskFree: 120_000_000_000))
    try journal.append(sample(at: date(2026, 11, 23, 19), charge: 60, plugged: false, cycles: 81, health: 97, diskFree: 118_000_000_000))
    let report = try journal.report(days: 7, now: date(2026, 11, 24, 12))
    #expect(report.contains("雪 · 电池守护周报"))
    #expect(report.contains("每日明细"))
    #expect(report.contains("插电样本占比"))
    #expect(report.contains("不调用模型"))
    #expect(report.contains("2026-11-23"))
    try? FileManager.default.removeItem(at: journal.fileURL.deletingLastPathComponent())
}

@Test func dailyJournalPruneKeepsRecent120DaysOnly() throws {
    let journal = DailyJournal(fileURL: journalURL(), calendar: fixedCalendar())
    try journal.append(sample(at: date(2026, 6, 1, 9), charge: 80, plugged: true))
    try journal.append(sample(at: date(2026, 11, 20, 9), charge: 70, plugged: false))
    try journal.append(sample(at: date(2026, 11, 24, 9), charge: 60, plugged: true))

    let removed = try journal.prune(keepingDays: 120, now: date(2026, 11, 25, 12))
    #expect(removed == 1)
    let kept = try journal.samples()
    #expect(kept.count == 2)
    #expect(kept.map(\.chargePercent) == [70, 60])
    try? FileManager.default.removeItem(at: journal.fileURL.deletingLastPathComponent())
}
