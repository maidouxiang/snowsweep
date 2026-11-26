import Foundation
import Testing
@testable import SnowSweepCore

@Test func releaseFreshnessUsesThreeBands() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(AppReleaseFreshness.classify(lastRelease: now.addingTimeInterval(-400 * 86_400), now: now) == .active)
    #expect(AppReleaseFreshness.classify(lastRelease: now.addingTimeInterval(-900 * 86_400), now: now) == .aging)
    #expect(AppReleaseFreshness.classify(lastRelease: now.addingTimeInterval(-1_500 * 86_400), now: now) == .stale)
    #expect(AppReleaseFreshness.classify(lastRelease: nil, now: now) == .unknown)
}

@Test func onlineLookupOnlySendsBundleIDQuery() throws {
    let url = try #require(OnlineAppVerifier.lookupURL(bundleID: "com.example.app"))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(Set(items.map(\.name)) == ["bundleId", "entity", "country", "limit"])
    #expect(items.first { $0.name == "bundleId" }?.value == "com.example.app")
}

@Test func onlineLookupRejectsUnsafeBundleID() async {
    let verifier = OnlineAppVerifier()
    await #expect(throws: OnlineVerificationError.self) {
        try await verifier.verify(bundleID: "com.example.app/../../etc/passwd")
    }
}

@Test func onlineNotFoundDoesNotMeanSafeToDelete() {
    let result = OnlineAppVerification(bundleID: "com.example.gone", found: false)
    #expect(result.summary.contains("不能证明文件没用"))
    #expect(result.freshness == .unknown)
}
