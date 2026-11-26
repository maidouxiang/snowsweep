import Foundation
import Testing
@testable import SnowSweepCore

private struct UnavailableScanner: Scanning {
    let sourceLabel = "测试用不可用扫描器"
    let isAvailable = false
    func version() throws -> String { "1.0.0" }
    func statusJSON() throws -> Data { Data() }
    func analyzeJSON(path: String?) throws -> Data { Data() }
    func cleanPreviewJSON() throws -> Data { Data() }
}

private struct OutdatedScanner: Scanning {
    let sourceLabel = "测试用旧版扫描器"
    let isAvailable = true
    func version() throws -> String { "0.9.9" }
    func statusJSON() throws -> Data { Data() }
    func analyzeJSON(path: String?) throws -> Data { Data() }
    func cleanPreviewJSON() throws -> Data { Data() }
}

@Test func resolverFallsBackWhenMoleMissing() {
    let resolved = ScannerResolver.resolve(preferred: UnavailableScanner())
    #expect(resolved is NativeScanner)
}

@Test func resolverFallsBackWhenMoleOutdated() {
    let resolved = ScannerResolver.resolve(preferred: OutdatedScanner())
    #expect(resolved is NativeScanner)
}

@Test func versionComparisonIsConservative() {
    #expect(ScannerVersion.isVersion("1.2.0", atLeast: "1.0.0"))
    // 主版本升级视为契约未知，保守降级；不再当作"兼容"。
    #expect(ScannerVersion.compatibility(found: "mole 2.0.1", required: "1.0.0") == .futureMajor)
    #expect(!ScannerVersion.isVersion("mole 2.0.1", atLeast: "1.0.0"))
    #expect(!ScannerVersion.isVersion("0.9.9", atLeast: "1.0.0"))
    #expect(!ScannerVersion.isVersion("版本未知", atLeast: "1.0.0"))
}

@Test func moleFixtureParsesIntoScanItems() throws {
    // 契约测试用 fixture，不依赖真实 mo 可执行文件
    let fixture = """
    {"source":"fixture","items":[
      {"path":"/tmp/a.txt","sizeBytes":123,"owner":"X","modifiedAt":700000000},
      {"path":"/tmp/b.txt","size":456}
    ]}
    """
    let items = try MolePayloadParser.parseScanItems(Data(fixture.utf8))
    #expect(items.count == 2)
    #expect(items[0].path == "/tmp/a.txt")
    #expect(items[0].sizeBytes == 123)
    #expect(items[0].owner == "X")
    #expect(items[0].modifiedAt != nil)
    #expect(items[1].sizeBytes == 456)
}

@Test func moleDirectArrayFixtureParses() throws {
    let fixture = """
    [{"path":"/tmp/c.txt","sizeBytes":789}]
    """
    let items = try MolePayloadParser.parseScanItems(Data(fixture.utf8))
    #expect(items.count == 1)
    #expect(items.first?.sizeBytes == 789)
}

@Test func nativeScannerPreviewOnlyContainsRealHighConfidencePaths() throws {
    let data = try NativeScanner().cleanPreviewJSON()
    let payload = try JSONDecoder().decode(ScanPayload.self, from: data)
    #expect(payload.source == "native-safe-preview")
    // 每条预览项必须来自磁盘上真实存在的路径，绝不凭空生成。
    for item in payload.items {
        #expect(FileManager.default.fileExists(atPath: item.path), "预览项不存在：\(item.path)")
    }
    #expect(payload.gaps.contains { $0.path == "降级模式" })
}

@Test func nativeScannerStatusReportsRealDiskNumbers() throws {
    let data = try NativeScanner().statusJSON()
    let status = try JSONDecoder().decode(StatusPayload.self, from: data)
    #expect(status.totalBytes > 0)
}
