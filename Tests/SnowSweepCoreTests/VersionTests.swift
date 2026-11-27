import Foundation
import Testing
@testable import SnowSweepCore

@Test func currentVersionIsV0935SnowCollect() {
    let version = AppVersion.current
    #expect(version.number == "0.9.35")
    #expect(version.codeName == "雪集")
    #expect(version.stage == "应用内样本导出入口")
    #expect(version.display == "V0.9.35 · 雪集")
}

@Test func releaseVersionHasNoDevTag() {
    let version = AppVersion.current
    #expect(version.devTag == nil)
    #expect(version.fullDisplay == version.display)
    #expect(!version.fullDisplay.contains("dev"))
    #expect(version.fullDisplay.contains("V0.9.35"))
}
