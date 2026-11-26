import Foundation
import Testing
@testable import SnowSweepCore

private func makeVerdict(path: String, bytes: Int64, rule: String) -> Verdict {
    Verdict(
        item: ScanItem(path: path, sizeBytes: bytes, modifiedAt: Date(), owner: "tester", identity: nil),
        risk: .safe,
        explanation: "测试规则：\(rule)",
        evidence: ["rule:\(rule)"]
    )
}

@Test func observationFactsGroupScannedItemsByRule() {
    let report = ScanReport(
        scanStatus: "complete",
        totalBytes: 10 * 1024 * 1024,
        verdicts: [
            makeVerdict(path: "/tmp/a/cache.bin", bytes: 4 * 1024 * 1024, rule: "tmp-cache"),
            makeVerdict(path: "/tmp/b/cache.bin", bytes: 3 * 1024 * 1024, rule: "tmp-cache"),
            makeVerdict(path: "/tmp/log.txt", bytes: 1 * 1024 * 1024, rule: "logs")
        ],
        scanGaps: []
    )
    let facts = LocalObservationFactsBuilder.build(
        report: report,
        diskFreeBytes: 60 * 1024 * 1024 * 1024,
        diskTotalBytes: 100 * 1024 * 1024 * 1024,
        summaries: []
    )

    #expect(facts.candidateCount == 3)
    #expect(facts.candidateBytes == 8 * 1024 * 1024)
    #expect(facts.evidence.contains { $0.id == "disk.free" })
    #expect(facts.evidence.contains { $0.id == "scan.summary" })
    #expect(facts.evidence.contains { $0.id == "cluster.0" })
    #expect(facts.clusters.first?.count == 2)
}

@Test func observationDecoderKeepsOnlyGroundedFindings() throws {
    let json = """
    {"headline":"本机观察","summary":"只读事实里有两处值得看。","findings":[
      {"level":"attention","title":"同一规则重复命中","detail":"两条缓存来自同一规则。","evidence":["cluster.0"],"confidence":0.8},
      {"level":"note","title":"没有依据的猜测","detail":"这条应被丢掉。","evidence":["made.up"],"confidence":0.9}
    ]}
    """
    let report = try LocalObservationDecoder.decode(content: json, allowedEvidence: ["cluster.0"])
    #expect(report.findings.count == 1)
    #expect(report.findings.first?.title == "同一规则重复命中")
    #expect(report.findings.first?.evidence == ["cluster.0"])
}

@Test func observationDecoderRejectsDeletionInstruction() {
    let json = """
    {"headline":"建议删除缓存","summary":"删掉就好。","findings":[
      {"level":"attention","title":"建议删除","detail":"立即删除这些文件。","evidence":["cluster.0"],"confidence":0.9}
    ]}
    """
    do {
        _ = try LocalObservationDecoder.decode(content: json, allowedEvidence: ["cluster.0"])
        Issue.record("删除类输出应该被拒绝")
    } catch let error as LocalObservationError {
        #expect(error == .unsafeOutput)
    } catch {
        Issue.record("错误类型不对：\(error)")
    }
}

@Test func observationDecoderDropsSelfComputedPercent() throws {
    let json = """
    {"headline":"本机观察","summary":"读一下磁盘占比。","findings":[
      {"level":"attention","title":"自己算了占比","detail":"可用占 14.3%。","evidence":["disk.free"],"confidence":0.8},
      {"level":"note","title":"照抄证据","detail":"证据写的是可用 60.0%。","evidence":["disk.free"],"confidence":0.8}
    ]}
    """
    let report = try LocalObservationDecoder.decode(
        content: json,
        allowedEvidence: ["disk.free"],
        evidenceText: ["当前磁盘可用 60.0 GB / 共 100.0 GB（可用 60.0%）"]
    )
    #expect(report.findings.count == 1)
    #expect(report.findings.first?.title == "照抄证据")
}

@Test func observationDecoderRejectsUngroundedOutput() {
    let json = """
    {"headline":"本机观察","summary":"看起来有增长。","findings":[
      {"level":"attention","title":"磁盘在涨","detail":"但是没有任何可核对依据。","evidence":["not.in.facts"],"confidence":0.9}
    ]}
    """
    do {
        _ = try LocalObservationDecoder.decode(content: json, allowedEvidence: ["disk.free"])
        Issue.record("没有依据的发现应该被拒绝")
    } catch let error as LocalObservationError {
        #expect(error == .ungrounded)
    } catch {
        Issue.record("错误类型不对：\(error)")
    }
}
