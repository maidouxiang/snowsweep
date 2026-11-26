import Foundation
import Testing
@testable import SnowSweepCore

@Test func currentVersionIsV0934SnowFilter() {
    let version = AppVersion.current
    #expect(version.number == "0.9.34")
    #expect(version.codeName == "雪滤")
    #expect(version.stage == "样本路径过滤修正")
    #expect(version.display == "V0.9.34 · 雪滤")
}

@Test func releaseVersionHasNoDevTag() {
    let version = AppVersion.current
    #expect(version.devTag == nil)
    #expect(version.fullDisplay == version.display)
    #expect(!version.fullDisplay.contains("dev"))
    #expect(version.fullDisplay.contains("V0.9.34"))
}
