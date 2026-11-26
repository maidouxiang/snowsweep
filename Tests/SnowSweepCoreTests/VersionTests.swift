import Foundation
import Testing
@testable import SnowSweepCore

@Test func currentVersionIsV0933SnowSignature() {
    let version = AppVersion.current
    #expect(version.number == "0.9.33")
    #expect(version.codeName == "雪签")
    #expect(version.stage == "样本导出与脱敏")
    #expect(version.display == "V0.9.33 · 雪签")
}

@Test func releaseVersionHasNoDevTag() {
    let version = AppVersion.current
    #expect(version.devTag == nil)
    #expect(version.fullDisplay == version.display)
    #expect(!version.fullDisplay.contains("dev"))
    #expect(version.fullDisplay.contains("V0.9.33"))
}
