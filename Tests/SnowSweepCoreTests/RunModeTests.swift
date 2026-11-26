import Foundation
import Testing
@testable import SnowSweepCore

@Test func runModesHaveAgreedIntervals() {
    #expect(RunMode.silent.menuBarInterval == 300)
    #expect(RunMode.silent.dailyJournalInterval == 1_800)
    #expect(RunMode.balanced.menuBarInterval == 60)
    #expect(RunMode.balanced.dailyJournalInterval == 600)
    #expect(RunMode.performance.menuBarInterval == 15)
    #expect(RunMode.performance.dailyJournalInterval == 300)
}

@Test func silentModeDoesNotAllowBackgroundHeavyReads() {
    #expect(!RunMode.silent.allowsBackgroundHeavyReads)
    #expect(!RunMode.balanced.allowsBackgroundHeavyReads)
    #expect(RunMode.performance.allowsBackgroundHeavyReads)
}

@Test func preferredModeIsUsedWhenNothingForcesSilence() {
    let status = RunModePolicy.status(
        preferred: .balanced,
        batteryPercent: 88,
        lowPowerMode: false,
        isScanning: false
    )
    #expect(status.mode == .balanced)
    #expect(!status.isTemporary)
}

@Test func scanningTemporarilyBoostsToPerformance() {
    let status = RunModePolicy.status(
        preferred: .silent,
        batteryPercent: 90,
        lowPowerMode: false,
        isScanning: true
    )
    #expect(status.mode == .performance)
    #expect(status.isTemporary)
    #expect(status.reason.contains("60 秒"))
}

@Test func lowPowerModeForcesSilentEvenInPerformancePreference() {
    let status = RunModePolicy.status(
        preferred: .performance,
        batteryPercent: 90,
        lowPowerMode: true,
        isScanning: false
    )
    #expect(status.mode == .silent)
    #expect(status.isTemporary)
}

@Test func batteryProtectionWinsOverScanBoost() {
    let status = RunModePolicy.status(
        preferred: .performance,
        batteryPercent: 20,
        lowPowerMode: false,
        isScanning: true
    )
    #expect(status.mode == .silent)
    #expect(status.isTemporary)
}

@Test func batteryBelowThirtyForcesSilent() {    let status = RunModePolicy.status(
        preferred: .balanced,
        batteryPercent: 29,
        lowPowerMode: false,
        isScanning: false
    )
    #expect(status.mode == .silent)
    #expect(status.reason.contains("30"))

    let boundary = RunModePolicy.status(
        preferred: .balanced,
        batteryPercent: 30,
        lowPowerMode: false,
        isScanning: false
    )
    #expect(boundary.mode == .balanced)
}

@Test func missingBatteryDoesNotForceSilent() {
    let status = RunModePolicy.status(
        preferred: .performance,
        batteryPercent: nil,
        lowPowerMode: false,
        isScanning: false
    )
    #expect(status.mode == .performance)
}

@Test func configurationRoundTripsRunModeAndUpgradesOldFiles() throws {
    let configuration = AppConfiguration(runMode: RunMode.balanced.rawValue)
    let data = try ConfigurationTransfer.encode(configuration)
    let decoded = try ConfigurationTransfer.decode(data)
    #expect(decoded.runMode == "balanced")
    #expect(decoded.version == AppConfiguration.currentVersion)

    // 旧配置没有 runMode 字段：必须安全落回静默，不能直接报错。
    let legacyJSON = #"{"version":1,"customProtections":[],"aiMode":"off"}"#
    let legacy = try ConfigurationTransfer.decode(Data(legacyJSON.utf8))
    #expect(legacy.runMode == "silent")
}

@Test func closedMainWindowForcesSilentAndIsTemporary() {
    let status = RunModePolicy.status(
        preferred: .performance,
        batteryPercent: 90,
        lowPowerMode: false,
        isScanning: true,
        mainWindowClosed: true
    )
    #expect(status.mode == .silent)
    #expect(status.isTemporary)
    #expect(status.reason.contains("主窗口"))
}

@Test func dockIconIsHiddenWhileMainWindowClosed() {
    #expect(DockVisibilityPolicy.shouldShowDockIcon(preference: true, mainWindowClosed: true) == false)
    #expect(DockVisibilityPolicy.activationPolicy(preference: true, mainWindowClosed: true) == "accessory")
}

@Test func dockIconRestoresPreferenceAfterReopen() {
    #expect(DockVisibilityPolicy.shouldShowDockIcon(preference: true, mainWindowClosed: false))
    #expect(DockVisibilityPolicy.shouldShowDockIcon(preference: false, mainWindowClosed: false) == false)
    #expect(DockVisibilityPolicy.activationPolicy(preference: true, mainWindowClosed: false) == "regular")
    #expect(DockVisibilityPolicy.activationPolicy(preference: false, mainWindowClosed: false) == "accessory")
}
