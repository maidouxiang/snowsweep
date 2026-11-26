import Foundation
import Testing
@testable import SnowSweepCore

@Test func runtimeModeBudgetsAreOrdered() {
    #expect(RuntimeMode.silent.residentMemoryBudgetMB == 60)
    #expect(RuntimeMode.scan.residentMemoryBudgetMB == 600)
    #expect(RuntimeMode.assist.residentMemoryBudgetMB == 3_600)
    #expect(RuntimeMode.silent.residentMemoryBudgetMB < RuntimeMode.scan.residentMemoryBudgetMB)
    #expect(RuntimeMode.scan.residentMemoryBudgetMB < RuntimeMode.assist.residentMemoryBudgetMB)
}

@Test func runtimeModeKeepsScanAndAssistExclusive() {
    #expect(RuntimeTransition.next(from: .silent, to: .scan) == .enterScan)
    #expect(RuntimeTransition.next(from: .silent, to: .assist) == .enterAssist)
    #expect(RuntimeTransition.next(from: .scan, to: .silent) == .enterSilent)
    #expect(RuntimeTransition.next(from: .assist, to: .silent) == .enterSilent)
    #expect(RuntimeTransition.next(from: .scan, to: .assist) == .rejected)
    #expect(RuntimeTransition.next(from: .assist, to: .scan) == .rejected)
}

@Test func runtimeModeOnlyLoadsModelInAssist() {
    #expect(RuntimeMode.silent.allowsModel == false)
    #expect(RuntimeMode.scan.allowsModel == false)
    #expect(RuntimeMode.assist.allowsModel == true)
    #expect(RuntimeMode.silent.allowsScanning == false)
    #expect(RuntimeMode.scan.allowsScanning == true)
}
