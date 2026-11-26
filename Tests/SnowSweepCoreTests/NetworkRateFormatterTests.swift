import Foundation
import Testing
@testable import SnowSweepCore

@Test func networkRateFormatterUsesReadableDecimalUnits() {
    #expect(NetworkRateFormatter.string(bytesPerSecond: 0) == "0 B/s")
    #expect(NetworkRateFormatter.string(bytesPerSecond: 512) == "512 B/s")
    #expect(NetworkRateFormatter.string(bytesPerSecond: 12_345) == "12 KB/s")
    #expect(NetworkRateFormatter.string(bytesPerSecond: 1_500_000) == "1.5 MB/s")
    #expect(NetworkRateFormatter.string(bytesPerSecond: 2_500_000_000) == "2.50 GB/s")
}

@Test func networkRateFormatterClampsInvalidValues() {
    #expect(NetworkRateFormatter.string(bytesPerSecond: -1) == "0 B/s")
    #expect(NetworkRateFormatter.string(bytesPerSecond: .infinity) == "0 B/s")
    #expect(NetworkRateFormatter.string(bytesPerSecond: .nan) == "0 B/s")
}
