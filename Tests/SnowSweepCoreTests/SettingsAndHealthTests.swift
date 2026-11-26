import Foundation
import Testing
@testable import SnowSweepCore

@Test func displayUnitFormatsWithFixedUnits() {
    #expect(DisplayUnit.megabyte.format(bytes: 2_000_000) == "2.0 MB")
    #expect(DisplayUnit.gigabyte.format(bytes: 57_640_000_000) == "57.64 GB")
    #expect(DisplayUnit.auto.format(bytes: 0).isEmpty == false)
}

@Test func assistantBytesUsesTheSameDecimalScaleAsTheInterface() {
    #expect(AssistantBytes.text(494_384_795_648) == "494.38 GB")
    #expect(AssistantBytes.text(2_000_000) == "2.0 MB")
}

@Test func configurationRoundTripKeepsMenuPreferences() throws {
    let original = AppConfiguration(
        customProtections: ["~/Library/**", "~/Desktop/私藏"],
        aiMode: "hybrid",
        showDockIcon: false,
        displayUnit: .megabyte,
        scanScope: "wholeDisk",
        menuBar: MenuBarPreferences(showDiskSpace: false, showMemory: true,
                                    showBattery: false, showQuickClean: false, showBadge: true),
        dailyJournalEnabled: false
    )
    let data = try ConfigurationTransfer.encode(original)
    let decoded = try ConfigurationTransfer.decode(data)
    #expect(decoded == original)
    #expect(decoded.version == AppConfiguration.currentVersion)
    #expect(decoded.dailyJournalEnabled == false)
}

@Test func legacyConfigurationDefaultsDailyJournalToEnabled() throws {
    let json = #"{"version":1,"customProtections":["~/A"],"aiMode":"off","showDockIcon":true,"displayUnit":"auto","scanScope":"userOnly","menuBar":{}}"#
    let decoded = try ConfigurationTransfer.decode(Data(json.utf8))
    #expect(decoded.dailyJournalEnabled)
    #expect(decoded.showEnglishOriginal, "老配置没有开关时保持英文原名可见，避免用户找不到文件")
}

@Test func configurationPreservesHiddenEnglishOriginal() throws {
    let original = AppConfiguration(showEnglishOriginal: false)
    let decoded = try ConfigurationTransfer.decode(try ConfigurationTransfer.encode(original))
    #expect(decoded.showEnglishOriginal == false)
    #expect(decoded.version == AppConfiguration.currentVersion)
}

@Test func configurationNormalizesProtectionsAndDropsBlankDuplicates() throws {
    let config = AppConfiguration(customProtections: ["  ~/A  ", "~/A", "", "   ", "~/B\n"])
    let data = try ConfigurationTransfer.encode(config)
    let decoded = try ConfigurationTransfer.decode(data)
    #expect(decoded.customProtections == ["~/A", "~/B"])
}

@Test func configurationRejectsFutureVersion() throws {
    let json = #"{"version":9,"customProtections":["~/A"],"aiMode":"off","showDockIcon":true,"displayUnit":"auto","scanScope":"userOnly","menuBar":{}}"#
    let data = Data(json.utf8)
    #expect(throws: ConfigurationTransferError.futureVersion(9)) {
        _ = try ConfigurationTransfer.decode(data)
    }
}

@Test func configurationRejectsMalformedData() {
    let data = Data("not json".utf8)
    #expect(throws: ConfigurationTransferError.malformed) {
        _ = try ConfigurationTransfer.decode(data)
    }
}

@Test func configurationFallsBackOnUnknownEnums() throws {
    let json = #"{"version":1,"customProtections":[],"aiMode":"turbo","showDockIcon":true,"displayUnit":"terabyte","scanScope":"moon","menuBar":{}}"#
    let decoded = try ConfigurationTransfer.decode(Data(json.utf8))
    #expect(decoded.aiMode == "off")
    #expect(decoded.displayUnit == .auto)
    #expect(decoded.scanScope == "userOnly")
    #expect(decoded.menuBar == .default)
}

@Test func menuBarPreferencesDefaultsAreAllOn() {
    let prefs = MenuBarPreferences.default
    #expect(prefs.showDiskSpace && prefs.showMemory && prefs.showBattery)
    #expect(prefs.showQuickClean && prefs.showBadge)
}

@Test func healthScoreWeightsThreeMetrics() {
    let health = HealthScore.evaluate(diskFreeRatio: 0.5, memoryUsedFraction: 0.4, batteryHealthPercent: 100)
    #expect(health.total == 100)
    #expect(health.components.count == 3)
    #expect(health.components.map(\.weight) == [0.35, 0.35, 0.30])
}

@Test func healthScorePenalizesLowBattery() {
    let health = HealthScore.evaluate(diskFreeRatio: 0.5, memoryUsedFraction: 0.4, batteryHealthPercent: 50)
    #expect(health.total == 85)
}

@Test func healthScoreRenormalizesWithoutBattery() {
    let health = HealthScore.evaluate(diskFreeRatio: 0.5, memoryUsedFraction: 0.4, batteryHealthPercent: nil)
    #expect(health.total == 100)
    #expect(health.components.count == 2)
    #expect(health.components.map(\.weight) == [0.50, 0.50])
}

@Test func healthScoreTieredPenalties() {
    let health = HealthScore.evaluate(diskFreeRatio: 0.10, memoryUsedFraction: 0.70, batteryHealthPercent: nil)
    #expect(health.total == 80)
    #expect(health.components.map(\.score) == [80, 80])
    #expect(health.title == "状态良好")
}

@Test func healthScoreTitles() {
    #expect(HealthScore.evaluate(diskFreeRatio: 0.5, memoryUsedFraction: 0.4, batteryHealthPercent: 100).title == "状态良好")
    #expect(HealthScore.evaluate(diskFreeRatio: 0.05, memoryUsedFraction: 0.90, batteryHealthPercent: 40).title == "需要处理")
}

@Test func helpSearchMatchesChineseAndMultipleTerms() {
    #expect(HelpSearch.matches(query: "废纸篓", title: "删除是怎么执行的", keywords: "删除 废纸篓", body: "默认移到废纸篓。"))
    #expect(HelpSearch.matches(query: "权限 缺口", title: "为什么清理按钮是灰的", keywords: "权限 缺口", body: ""))
    #expect(!HelpSearch.matches(query: "权限 蓝牙", title: "为什么清理按钮是灰的", keywords: "权限 缺口", body: "扫描没扫完"))
}

@Test func helpSearchIsCaseInsensitiveAndEmptyAlwaysMatches() {
    #expect(HelpSearch.matches(query: "MB", title: "单位", keywords: "mb gb", body: ""))
    #expect(HelpSearch.matches(query: "   ", title: "任意", keywords: "", body: ""))
}
