import Testing
@testable import SnowSweepCore

@Test func uninstallDetailOnlyShowsForOneMatchingSelection() {
    #expect(UninstallDetailPolicy.shows(selectedPaths: [], inspectedPath: "A"))
    #expect(UninstallDetailPolicy.shows(selectedPaths: ["A"], inspectedPath: "A"))
    #expect(!UninstallDetailPolicy.shows(selectedPaths: ["A", "B"], inspectedPath: "A"))
    #expect(!UninstallDetailPolicy.shows(selectedPaths: ["A"], inspectedPath: "B"))
    #expect(!UninstallDetailPolicy.shows(selectedPaths: [], inspectedPath: nil))
}

@Test func selfCheckFailureNeverLeaksEnglishSystemMessage() {
    let raw = "This device does not support Apple Intelligence."
    #expect(SelfCheckFailureCopy.isUnsupportedDevice(raw))
    let message = SelfCheckFailureCopy.message(for: raw)
    #expect(message.contains("当前设备或系统不支持"))
    #expect(!message.contains("This device"))
    #expect(!SelfCheckFailureCopy.message(for: "Operation failed").contains("Operation failed"))
}
