import Foundation
import Testing
@testable import SnowSweepCore

@Test func currentVersionIsV0932SnowRestraint() {
    let version = AppVersion.current
    #expect(version.number == "0.9.32")
    #expect(version.codeName == "雪敛")
    #expect(version.stage == "菜单栏实时面板与上下行网速")
    #expect(version.display == "V0.9.32 · 雪敛")
}

@Test func releaseVersionHasNoDevTag() {
    let version = AppVersion.current
    #expect(version.devTag == nil)
    #expect(version.fullDisplay == version.display)
    #expect(!version.fullDisplay.contains("dev"))
    #expect(version.fullDisplay.contains("V0.9.32"))
}
