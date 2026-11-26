import Foundation
import Darwin
import Testing
@testable import SnowSweepCore

/// 判定吞吐与硬链接去重基准。真实 1TB 盘的遍历基准留到 M2 接真实扫描时跑。
@Test func tenThousandVerdictsCompleteQuickly() throws {
    let book = RuleBook(
        version: "test", updatedAt: nil, protectedPaths: [],
        rules: [Rule(id: "caches", risk: .safe, name: "缓存", pathPattern: "~/Library/Caches/**",
                     reason: "测试", needConfirm: false, priority: 10)]
    )
    let engine = try RuleEngine(ruleBook: book)
    let items = (0..<10_000).map { index in
        ScanItem(path: "~/Library/Caches/com.example.app/cache-\(index).db", sizeBytes: Int64(index))
    }

    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for item in items { _ = engine.verdict(for: item) }
    }
    #expect(elapsed < .seconds(5), "1 万条判定耗时 \(elapsed)，超出 5 秒上限")
}

@Test func hardLinkDeduplicationUsesDeviceAndInode() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SnowSweepDedup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let original = root.appendingPathComponent("original.txt")
    let linked = root.appendingPathComponent("linked.txt")
    try Data("dedup-test".utf8).write(to: original)
    let linkResult = original.path.withCString { source in
        linked.path.withCString { destination in
            link(source, destination)
        }
    }
    #expect(linkResult == 0, "创建硬链接失败，错误码 \(linkResult)")

    var deduplicator = HardLinkDeduplicator()
    #expect(deduplicator.register(path: original.path) == true)
    #expect(deduplicator.register(path: linked.path) == false)
    #expect(deduplicator.uniqueCount == 1)
}
