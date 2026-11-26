import Foundation
import Testing
@testable import SnowSweepCore

@Test func batchGateAllowsOrdinaryBatches() {
    let decision = BatchSizeGate.check(count: 200, bytes: 5 * 1024 * 1024 * 1024)
    #expect(decision == .allowed)
    #expect(decision.allows(acknowledged: false))
}

@Test func batchGateRequiresConfirmationWhenItemCountExceeds() {
    let decision = BatchSizeGate.check(count: 201, bytes: 1)
    #expect(decision.requiresConfirmation)
    #expect(decision.reasons.count == 1)
    #expect(decision.reasons[0].contains("201 项"))
    #expect(!decision.allows(acknowledged: false))
    #expect(decision.allows(acknowledged: true))
}

@Test func batchGateRequiresConfirmationWhenBytesExceed() {
    let decision = BatchSizeGate.check(count: 1, bytes: 5 * 1024 * 1024 * 1024 + 1)
    #expect(decision.requiresConfirmation)
    #expect(decision.reasons.count == 1)
    #expect(decision.reasons[0].contains("超过"))
}

@Test func batchGateReportsBothReasonsAtOnce() {
    let decision = BatchSizeGate.check(count: 500, bytes: 9 * 1024 * 1024 * 1024)
    #expect(decision.reasons.count == 2)
}

@Test func batchGateWorksOnSelectionEntries() {
    let entries = (0..<201).map { index in
        CleanupSelection.Entry(
            verdict: Verdict(
                item: ScanItem(path: "/tmp/caches/\(index).dat", sizeBytes: 1),
                risk: .safe, explanation: "可重建缓存"
            ),
            ruleID: "test"
        )
    }
    let decision = BatchSizeGate.check(entries)
    #expect(decision.requiresConfirmation)
}

@Test func batchGateHonorsCustomLimits() {
    let limits = BatchSizeLimits(maxItems: 2, maxBytes: 10)
    #expect(BatchSizeGate.check(count: 2, bytes: 10, limits: limits) == .allowed)
    #expect(BatchSizeGate.check(count: 3, bytes: 10, limits: limits).requiresConfirmation)
    #expect(BatchSizeGate.check(count: 2, bytes: 11, limits: limits).requiresConfirmation)
}
