import Foundation
import Testing
@testable import SnowSweepCore

// MARK: - 路径模板化

@Test func templateCollapsesHomeAndKeepsAppIdentity() {
    let redactor = SampleRedactor(home: "/Users/example")
    let path = "/Users/example/Library/Caches/com.example.editor/20261101T091500Z-3f2a9c"
    let templated = redactor.template(path)

    #expect(!templated.contains("/Users/example"))
    #expect(templated.hasPrefix("~/Library/Caches/com.example.editor/"))
    #expect(templated.contains("<name>"))
    #expect(templated.hasSuffix("<name>"))
}

@Test func templateKeepsStructuralDirectoriesAndHidesFileNames() {
    let redactor = SampleRedactor(home: "/Users/example")
    let templated = redactor.template("/Users/example/Documents/项目资料/最终版-2026.xlsx")

    #expect(templated == "~/Documents/<name>/<name>.xlsx")
    #expect(!templated.contains("项目资料"))
    #expect(!templated.contains("最终版"))
}

@Test func templateReplacesOpaqueSegmentsWithHash() {
    let redactor = SampleRedactor(home: "/Users/example")
    let templated = redactor.template("/Users/example/Library/Caches/com.example.app/9d41ab77c0de4f8899aabbccddeeff00")

    #expect(templated.contains("<hash>"))
    #expect(!templated.contains("9d41ab77c0de4f88"))
}

@Test func templateDeduplicatesRepeatedPatterns() {
    let redactor = SampleRedactor(home: "/Users/example")
    let paths = [
        "/Users/example/Library/Caches/com.example.app/a",
        "/Users/example/Library/Caches/com.example.app/a/20260101",
        "/Users/example/Library/Caches/com.example.app/b"
    ]
    let result = redactor.templates(paths)

    #expect(!result.isEmpty)
    #expect(result.allSatisfy { !$0.contains("/Users/example") })
}

// MARK: - 文本脱敏

@Test func scrubRemovesContactAndIdentifierPatterns() {
    let redactor = SampleRedactor(home: "/Users/example")
    let raw = "联系 jiang@example.com 或 13800001111，机器 0A1B2C3D4E5F，IP 192.168.1.7，单号 202611270001"
    let scrubbed = redactor.scrub(raw)

    #expect(!scrubbed.contains("@"))
    #expect(!scrubbed.contains("13800001111"))
    #expect(!scrubbed.contains("192.168.1.7"))
    #expect(!scrubbed.contains("202611270001"))
    #expect(scrubbed.contains("<id>"))
}

@Test func scrubTemplatesAbsolutePathsInsideText() {
    let redactor = SampleRedactor(home: "/Users/example")
    let scrubbed = redactor.scrub("在 /Users/example/Library/Caches/com.example.app 里发现残留")

    #expect(!scrubbed.contains("/Users/example"))
    #expect(scrubbed.contains("~/Library/Caches/com.example.app"))
}

@Test func safeQueryRefusesPathsAndKeepsPlainIntent() {
    let redactor = SampleRedactor(home: "/Users/example")

    #expect(redactor.safeQuery("清理某个应用更新留下的缓存") == "清理某个应用更新留下的缓存")
    #expect(redactor.safeQuery("把 /Users/example/Downloads 里的大文件清掉") == nil)
    #expect(redactor.safeQuery("订单号 202611270001 能不能删") == "订单号 <id> 能不能删")
    #expect(redactor.safeQuery("   ") == nil)
}

@Test func safeQueryTruncatesLongText() {
    let redactor = SampleRedactor(home: "/Users/example")
    let long = String(repeating: "清理", count: 60)
    let result = redactor.safeQuery(long, maxLength: 20)

    #expect(result != nil)
    #expect(result!.count <= 21)
    #expect(result!.hasSuffix("…"))
}

// MARK: - 分桶

@Test func bucketsUseRangesNotExactValues() {
    #expect(SampleBucket.fileCount(0) == "0")
    #expect(SampleBucket.fileCount(1) == "1-10")
    #expect(SampleBucket.fileCount(100) == "11-100")
    #expect(SampleBucket.fileCount(1000) == "101-1000")
    #expect(SampleBucket.fileCount(5000) == "1000+")

    #expect(SampleBucket.bytes(0) == "0")
    #expect(SampleBucket.bytes(1024) == "<1MB")
    #expect(SampleBucket.bytes(50 * 1024 * 1024) == "1-100MB")
    #expect(SampleBucket.bytes(500 * 1024 * 1024) == "100MB-1GB")
    #expect(SampleBucket.bytes(2 * 1024 * 1024 * 1024) == "1-5GB")
    #expect(SampleBucket.bytes(8 * 1024 * 1024 * 1024) == "5GB+")

    #expect(SampleBucket.coverage(0.876) == 0.88)
    #expect(SampleBucket.coverage(2) == 1)
}

// MARK: - 样本本体

@Test func sampleCarriesSchemaAndConsent() {
    let redactor = SampleRedactor(home: "/Users/example")
    let context = SampleContext(
        category: "caches",
        query: "清理某个应用更新留下的缓存",
        coverage: 0.87,
        fileCount: 240,
        bytes: 734_003_200,
        ruleBookVersion: "0.5.2",
        ruleBookSHA256: String(repeating: "a", count: 64),
        observedPaths: ["/Users/example/Library/Caches/com.example.editor/3f2a9c"],
        protectedPaths: ["/Users/example/Library/Keychains"]
    )
    let sample = SampleExporter.sample(from: context, redactor: redactor)

    #expect(sample.schema == "xue.sample/v1")
    #expect(sample.consent.sampleLicense == "CC0-1.0")
    #expect(sample.consent.rawPaths == false)
    #expect(sample.consent.screenshots == false)
    #expect(sample.intent.queryRedacted == "清理某个应用更新留下的缓存")
    #expect(sample.paths.contains { $0.role == "protected" && $0.protected })
}

@Test func sampleEncodedJSONHasNoRawHomeOrUserName() throws {
    let redactor = SampleRedactor(home: "/Users/example")
    let context = SampleContext(
        category: "documents",
        query: "桌面上的导出文件能不能一起清掉",
        coverage: 0.35,
        fileCount: 12,
        bytes: 88_000_000,
        ruleBookVersion: "0.5.2",
        ruleBookSHA256: String(repeating: "b", count: 64),
        observedPaths: [
            "/Users/example/Documents/项目资料/最终版-2026.xlsx",
            "/Users/example/Desktop/导出/导出-20261101.csv"
        ],
        evidence: ["读取 /Users/example/Library/Caches 时权限不足"]
    )
    let sample = SampleExporter.sample(from: context, redactor: redactor)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    let text = String(decoding: try encoder.encode(sample), as: UTF8.self)

    #expect(!text.contains("/Users/example"))
    #expect(!text.contains("/Users/example"))
    #expect(!text.contains("项目资料"))
    #expect(!text.contains("导出-20261101"))
    #expect(text.contains("~/Documents"))
}

@Test func sampleFromUnknownCaseKeepsOnlyClosestRuleIDs() {
    let unknown = UnknownCase(
        query: "这个目录能不能删",
        reason: "没有匹配到任何规则",
        closestRules: [
            RuleHint(id: "r-cache-generic", name: "通用缓存", pathPattern: "~/Library/Caches/**", reason: "层级相近", score: 40)
        ],
        observedPaths: ["/Users/example/Library/Caches/com.example.app/9d41ab77c0de4f88"]
    )
    let redactor = SampleRedactor(home: "/Users/example")
    let sample = SampleExporter.sample(
        from: unknown,
        ruleBookVersion: "0.5.2",
        ruleBookSHA256: String(repeating: "c", count: 64),
        redactor: redactor
    )

    #expect(sample.verdict.result == "unknown")
    #expect(sample.verdict.closestRules == ["r-cache-generic"])
    #expect(sample.observation.scope.count == 1)
    #expect(!sample.observation.scope[0].contains("9d41ab77"))
}

// MARK: - 写包

@Test func writesBundleWithVerifiableManifest() throws {
    let redactor = SampleRedactor(home: "/Users/example")
    let sample = SampleExporter.sample(
        from: SampleContext(
            category: "caches",
            query: "清理某个应用更新留下的缓存",
            coverage: 0.87,
            fileCount: 240,
            bytes: 734_003_200,
            ruleBookVersion: "0.5.2",
            ruleBookSHA256: String(repeating: "d", count: 64),
            observedPaths: ["/Users/example/Library/Caches/com.example.editor/3f2a9c"]
        ),
        redactor: redactor
    )

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("xue-sample-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try SampleExporter.write(sample, to: root)

    let fileManager = FileManager.default
    for name in ["sample.json", "scan-summary.json", "manifest.json", "README.txt"] {
        #expect(fileManager.fileExists(atPath: root.appendingPathComponent(name).path))
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(
        SampleExporter.Manifest.self,
        from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
    )

    #expect(manifest.schema == "xue.sample/v1")
    #expect(manifest.license == "CC0-1.0")
    #expect(manifest.files.count == 3)
    #expect(manifest.files.allSatisfy { $0.sha256.count == 64 })
    #expect(manifest.files.allSatisfy { $0.bytes > 0 })

    // 清单必须与磁盘实际内容一致，否则样本在传递中被动过手脚就查不出来。
    for entry in manifest.files {
        let data = try Data(contentsOf: root.appendingPathComponent(entry.name))
        #expect(data.count == entry.bytes)
    }

    let readme = try String(contentsOf: root.appendingPathComponent("README.txt"), encoding: .utf8)
    #expect(readme.contains("xue.sample/v1"))
    #expect(readme.contains("CC0-1.0"))
}

@Test func bundleNeverContainsRawUserPath() throws {
    let redactor = SampleRedactor(home: "/Users/example")
    let sample = SampleExporter.sample(
        from: SampleContext(
            category: "containers",
            query: "某个聊天工具占了很大空间",
            coverage: 0.62,
            fileCount: 1_180,
            bytes: 4_700_000_000,
            ruleBookVersion: "0.5.2",
            ruleBookSHA256: String(repeating: "e", count: 64),
            observedPaths: ["/Users/example/Library/Containers/com.example.chat/Data/Library/Caches/9d41ab77c0de4f88"]
        ),
        redactor: redactor
    )

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("xue-sample-scan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try SampleExporter.write(sample, to: root)

    for name in ["sample.json", "scan-summary.json", "README.txt"] {
        let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        #expect(!text.contains("/Users/example"))
        #expect(!text.contains("9d41ab77c0de4f88"))
    }
}

@Test func templatesIgnoreProseEntries() {
    let redactor = SampleRedactor(home: "/Users/example")
    let result = redactor.templates(["未提供具体路径；只能从原话和现有规则反推候选目录"])

    #expect(result.isEmpty)
    #expect(SampleRedactor.isPathLike("/Users/example/Library/Caches"))
    #expect(SampleRedactor.isPathLike("~/Library/Caches"))
    #expect(!SampleRedactor.isPathLike("未提供具体路径"))
}

@Test func sampleFromProseOnlyCaseHasEmptyScope() {
    let unknown = UnknownCase(
        query: "某个应用该不该清",
        reason: "报告没有给出路径",
        observedPaths: ["未提供具体路径；只能从原话和现有规则反推候选目录"]
    )
    let sample = SampleExporter.sample(
        from: unknown,
        ruleBookVersion: "0.5.2",
        ruleBookSHA256: String(repeating: "f", count: 64),
        redactor: SampleRedactor(home: "/Users/example")
    )

    #expect(sample.observation.scope.isEmpty)
    #expect(sample.paths.isEmpty)
}
