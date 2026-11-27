import Foundation
import Testing
@testable import SnowSweepCore

@Test func currentVersionIsV0936SnowRelease() {
    let version = AppVersion.current
    #expect(version.number == "0.9.36")
    #expect(version.codeName == "雪发")
    #expect(version.stage == "发版流水线")
    #expect(version.display == "V0.9.36 · 雪发")
}

@Test func releaseVersionHasNoDevTag() {
    let version = AppVersion.current
    #expect(version.devTag == nil)
    #expect(version.fullDisplay == version.display)
    #expect(!version.fullDisplay.contains("dev"))
    #expect(version.fullDisplay.contains("V0.9.36"))
}
