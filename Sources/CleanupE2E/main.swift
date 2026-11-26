import Foundation
#if canImport(Darwin)
import Darwin
#endif
import SnowSweepCore

// ============================================================
// SnowSweep 清理闭环 · 真机实测（E2E）
//
// 与单元测试的本质区别：这里用的是**真实**组件——
//   · 真实文件系统样本（放在 ~/Library/Caches 下，命中内置 safe 规则）
//   · 真实 NativeScanner 扫描（真实 lstat 捕获 (device, inode) 身份）
//   · 真实内置规则库 Rules/rules.json（不是构造的 RuleBook）
//   · 真实 SystemFileTrasher（FileManager.trashItem 移入废纸篓，可恢复）
//   · 真实 SystemTargetVerifier（删除前 lstat 复核）
//   · 真实 AuditLog（SHA256 哈希链）
// 唯一被隔离的是测试样本本身：全部带随机 token，运行结束自动从废纸篓清除，
// 不碰用户任何现有文件。
// ============================================================

final class Checker: @unchecked Sendable {
    var passed = 0
    var failed = 0
    var skipped = 0

    /// 环境权限不足、无法取证时不计失败，但必须显式标「未验证」，不能伪装成通过。
    func skip(_ name: String, _ detail: String) {
        skipped += 1
        print("  [未验证] \(name) — \(detail)")
    }

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            passed += 1
            print("  [通过] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        } else {
            failed += 1
            print("  [失败] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }
}

let checker = Checker()

final class ModelResultBox: @unchecked Sendable {
    var intent: CleanIntent?
    var error: Error?
}

func section(_ title: String) {
    print("\n=== \(title) ===")
}

let token = "SnowSweepE2E-\(UUID().uuidString)"
let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let sampleRoot = cachesRoot.appendingPathComponent(token, isDirectory: true)
let auditURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("\(token)-audit.jsonl")
// 顶层条目名都带 token：macOS 移入废纸篓时可能加时间戳后缀，但只要保留
// token 子串，cleanupAll 就能精确识别并清除本次测试产生的条目。
let nestedDirName = "\(token)-nested"
let sampleRels = [
    "\(token)-cache-a.dat",
    "\(token)-cache-b.dat",
    "\(nestedDirName)/cache-c.dat"
]
let sampleNames = Set(sampleRels.map { ($0 as NSString).lastPathComponent })

func trashDirectory() -> URL {
    FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
}

/// 清除本次实测产生的所有痕迹：样本目录、审计日志、废纸篓里的测试文件。
/// 只删带本运行 token 的条目，绝不触碰用户原有文件。
func cleanupAll() {
    let fm = FileManager.default
    try? fm.removeItem(at: sampleRoot)
    try? fm.removeItem(at: auditURL)
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
    try? fm.removeItem(at: temp.appendingPathComponent("\(token)-mock-model.py"))
    try? fm.removeItem(at: temp.appendingPathComponent("\(token)-model-audit.jsonl"))
    let trash = trashDirectory()
    // ~/.Trash 在无 FDA 时禁止枚举，但已知 token 条目可按精确路径删除。
    for name in [nestedDirName, "\(token)-cache-a.dat", "\(token)-cache-b.dat"] {
        try? fm.removeItem(at: trash.appendingPathComponent(name))
    }
    if let entries = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
        for entry in entries where entry.lastPathComponent.contains(token) {
            try? fm.removeItem(at: entry)
        }
    }
}

func rulesURL() -> URL? {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Rules/rules.json")
    if FileManager.default.fileExists(atPath: cwd.path) { return cwd }
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Rules/rules.json")
    return FileManager.default.fileExists(atPath: source.path) ? source : nil
}

func run() throws {
    guard let ruleFile = rulesURL() else {
        FileHandle.standardError.write("找不到 Rules/rules.json，请从项目根目录运行\n".data(using: .utf8)!)
        exit(2)
    }

    section("0. 准备隔离样本（真实文件，~/Library/Caches 下）")
    try FileManager.default.createDirectory(at: sampleRoot, withIntermediateDirectories: true)
    for (index, rel) in sampleRels.enumerated() {
        let url = sampleRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: UInt8(index + 1), count: 4096 * (index + 1)).write(to: url)
    }
    print("  样本根：\(sampleRoot.path)")
    print("  样本文件：\(sampleRels.joined(separator: ", "))")
    checker.check("隔离样本创建成功", sampleRels.allSatisfy {
        FileManager.default.fileExists(atPath: sampleRoot.appendingPathComponent($0).path)
    })

    section("1. 真实加载规则库 + 真实扫描（捕获真实文件身份）")
    let engine = try RuleBookMigrator.loadEngine(builtinURL: ruleFile, overlayURL: nil)
    checker.check("内置规则库加载成功", engine.ruleBook.rules.count > 0,
                  "\(engine.ruleBook.rules.count) 条规则 / v\(engine.ruleBook.version)")

    let collector = ScanPayloadCollector(maxItems: 1_000)
    let summary = try NativeScanner().streamAnalyze(path: sampleRoot.path, sink: collector)
    let payload = collector.payload
    let scannedPaths = Set(payload.items.map { $0.path })
    checker.check("真实扫描覆盖全部样本文件", sampleRels.allSatisfy {
        scannedPaths.contains(sampleRoot.appendingPathComponent($0).path)
    }, "扫描 \(summary.kept) 条")
    checker.check("扫描过程无缺口", payload.gaps.isEmpty)
    checker.check("每条样本都捕获了真实 (device,inode) 身份",
                  payload.items.allSatisfy { $0.identity != nil })

    section("2. 规则判定 + 安全闸门（CleanupSelection）")
    let verdicts = payload.items.map { engine.verdict(for: $0) }
    let report = ScanReport(
        scanStatus: (summary.truncated || !payload.gaps.isEmpty) ? "partial" : "complete",
        totalBytes: verdicts.reduce(Int64(0)) { $0 + $1.item.sizeBytes },
        verdicts: verdicts,
        scanGaps: payload.gaps
    )
    checker.check("扫描报告判定为可清理（complete 且无缺口）", report.canClean)
    let fileVerdicts = verdicts.filter { sampleNames.contains(($0.item.path as NSString).lastPathComponent) }
    checker.check("样本缓存均命中内置 safe 规则",
                  fileVerdicts.count == sampleRels.count &&
                  fileVerdicts.allSatisfy { $0.risk == .safe && $0.defaultSelected },
                  "\(fileVerdicts.count)/\(sampleRels.count)")
    let entries = CleanupSelection.allSafeEntries(from: report)
    checker.check("祖先折叠：父目录与其子文件只保留父目录",
                  !entries.contains { $0.verdict.item.path.hasSuffix("cache-c.dat") } &&
                  entries.contains { $0.verdict.item.path.hasSuffix("/\(nestedDirName)") },
                  "放行 \(entries.count) 条（扫描原始 \(verdicts.filter { $0.defaultSelected }.count) 条）")
    checker.check("闸门正确提取命中规则 ID",
                  entries.allSatisfy { $0.ruleID == "user-app-caches" })

    section("3. 第一步 dry-run：只算判定，不碰文件系统")
    let audit = AuditLog(fileURL: auditURL)
    let coordinator = DeletionCoordinator(
        trasher: SystemFileTrasher(),
        audit: audit,
        policy: DeletionPolicy(),                       // 永久删除保持关闭
        verifier: SystemTargetVerifier(),               // 真实 lstat 复核
        protectionCheck: { path in engine.isProtected(path) },
        requireIdentity: true                           // 严格身份模式（生产口径）
    )
    _ = try coordinator.dryRun(items: payload.items, report: report, engine: engine)
    checker.check("dry-run 之后样本文件全部仍在（预览不删除）", sampleRels.allSatisfy {
        FileManager.default.fileExists(atPath: sampleRoot.appendingPathComponent($0).path)
    })

    section("4. 第二步确认：删除前真实复核 + 真实移入废纸篓")
    var moveEvents: [AuditEvent] = []
    for entry in entries {
        if let event = try coordinator.moveToTrash(
            entry.verdict.item, ruleID: entry.ruleID, report: report, resolution: .stop
        ) {
            moveEvents.append(event)
        }
    }
    checker.check("全部放行条目成功移到废纸篓（无 vanished 中断）",
                  moveEvents.count == entries.count, "\(moveEvents.count)/\(entries.count)")
    checker.check("原路径已全部消失（父目录带走子文件）", sampleRels.allSatisfy {
        !FileManager.default.fileExists(atPath: sampleRoot.appendingPathComponent($0).path)
    })
    // 两个文件直接入篓；nested 目录整体入篓并带走 cache-c。
    let expectedTrashNames = [
        "\(token)-cache-a.dat", "\(token)-cache-b.dat", nestedDirName
    ]
    do {
        let trashed = try FileManager.default.contentsOfDirectory(
            at: trashDirectory(), includingPropertiesForKeys: nil
        )
        let trashedNames = trashed.map { $0.lastPathComponent }
        let hits = expectedTrashNames.filter { name in
            trashedNames.contains { $0.contains(name) }
        }
        checker.check("废纸篓中出现全部测试样本（可恢复，非永久删除）",
                      hits.count == expectedTrashNames.count,
                      "匹配 \(hits.count)/\(expectedTrashNames.count)")
    } catch {
        // 无 FDA 时 macOS 允许移入废纸篓但不允许读取废纸篓，属权限不可取证，不是清理失败。
        checker.skip("废纸篓中出现全部测试样本（可恢复，非永久删除）",
                     "当前进程无 ~/.Trash 读取权限（TCC）")
    }

    section("5. 审计链：SHA256 哈希链完整")
    let verification = try audit.verify()
    checker.check("审计链无损坏、无断链", verification.isValid,
                  "\(verification.lineCount) 条记录")
    let actions = (try? audit.events().map { $0.action }) ?? []
    checker.check("审计记录了 dryRun", actions.contains(.dryRun))
    checker.check("审计记录了每一次 moveToTrash",
                  actions.filter { $0 == .moveToTrash }.count == moveEvents.count)

    section("6. 安全拒绝断言（真实复核器 / 真实组件，样本不移动）")

    // 6.1 扫描后目标被换成符号链接 → 拒绝，且不删链接指向的重要文件
    do {
        let victim = sampleRoot.appendingPathComponent("victim.dat")
        let target = sampleRoot.appendingPathComponent("swap.dat")
        try Data("important-victim".utf8).write(to: victim)
        try Data("original".utf8).write(to: target)
        let originalIdentity = FileIdentity.capture(at: target.path)!
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)
        let item = ScanItem(path: target.path, sizeBytes: 8, identity: originalIdentity)
        var rejected = false
        do {
            _ = try coordinator.moveToTrash(item, ruleID: nil, report: report, resolution: .stop)
        } catch is TargetRevalidationError { rejected = true }
        checker.check("扫描后变符号链接 → 删除被拒绝", rejected)
        checker.check("符号链接指向的重要文件未被删除", FileManager.default.fileExists(atPath: victim.path))
        checker.check("符号链接本身未移动", (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil)
    }

    // 6.2 扫描后文件被替换（不同 inode）→ 拒绝
    do {
        let target = sampleRoot.appendingPathComponent("replaced.dat")
        try Data("old".utf8).write(to: target)
        let originalIdentity = FileIdentity.capture(at: target.path)!
        try FileManager.default.removeItem(at: target)
        try Data("brand-new-content".utf8).write(to: target)
        let item = ScanItem(path: target.path, sizeBytes: 17, identity: originalIdentity)
        var rejected = false
        do {
            _ = try coordinator.moveToTrash(item, ruleID: nil, report: report, resolution: .stop)
        } catch is TargetRevalidationError { rejected = true }
        checker.check("扫描后 inode 变更 → 删除被拒绝", rejected)
        checker.check("替换后的新文件仍在原处", FileManager.default.fileExists(atPath: target.path))
    }

    // 6.3 命中保护清单 → 拒绝（真实保护清单判定闭包）
    do {
        let target = sampleRoot.appendingPathComponent("keep-me.dat")
        try Data("keep".utf8).write(to: target)
        let identity = FileIdentity.capture(at: target.path)!
        let guarded = DeletionCoordinator(
            trasher: SystemFileTrasher(),
            audit: audit,
            protectionCheck: { $0.hasSuffix("keep-me.dat") },   // 模拟命中保护清单
            requireIdentity: true
        )
        let item = ScanItem(path: target.path, sizeBytes: 4, identity: identity)
        var rejected = false
        do {
            _ = try guarded.moveToTrash(item, ruleID: nil, report: report, resolution: .stop)
        } catch is TargetRevalidationError { rejected = true }
        checker.check("命中保护清单 → 删除被拒绝", rejected)
        checker.check("受保护文件仍在原处", FileManager.default.fileExists(atPath: target.path))
    }

    // 6.4 报告不完整（partial）→ 任何删除都被拒绝
    do {
        let target = sampleRoot.appendingPathComponent("partial.dat")
        try Data("x".utf8).write(to: target)
        let identity = FileIdentity.capture(at: target.path)!
        let item = ScanItem(path: target.path, sizeBytes: 1, identity: identity)
        let partial = ScanReport(
            scanStatus: "partial", totalBytes: 1, verdicts: [],
            scanGaps: [ScanGap(kind: .tccDenied, path: "/")]
        )
        var rejected = false
        do {
            _ = try coordinator.moveToTrash(item, ruleID: nil, report: partial, resolution: .stop)
        } catch let error as DeletionError {
            if case .incompleteReport = error { rejected = true }
        }
        checker.check("报告不完整 → 删除被拒绝", rejected)
        checker.check("报告不完整时文件未被删除", FileManager.default.fileExists(atPath: target.path))
    }

    // 6.5 永久删除默认关闭 → 即使确认短语正确也被拒
    do {
        let target = sampleRoot.appendingPathComponent("permanent.dat")
        try Data("p".utf8).write(to: target)
        let identity = FileIdentity.capture(at: target.path)!
        let item = ScanItem(path: target.path, sizeBytes: 1, identity: identity)
        let confirmation = DeleteConfirmation(phrase: "我确认永久删除", acknowledgedIrreplaceable: true)
        var rejected = false
        do {
            _ = try coordinator.permanentlyDelete(
                item, ruleID: nil, report: report, confirmation: confirmation
            )
        } catch DeletionError.permanentDeleteDisabled { rejected = true }
        checker.check("永久删除默认关闭 → 被拒绝", rejected)
        checker.check("文件未被永久删除", FileManager.default.fileExists(atPath: target.path))
    }

    section("6.6 模型计划 → 白名单 → 确认 → 只移废纸篓 → 审计")

    // 这一节用真实 HTTP 模型接口（本机 mock，只返回白名单结构），
    // 走完与 App 相同的 AssistantRemoteBridge、AssistantPlanBuilder、
    // AssistantCleanupPolicy、ManualDeletionService 链路。
    let modelPort = 19_000 + Int.random(in: 0..<900)
    let mockScript = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(token)-mock-model.py")
    let mockSource = """
from http.server import BaseHTTPRequestHandler, HTTPServer
import json

PAYLOAD = {"choices": [{"message": {"content": json.dumps({
    "goal": "clean",
    "targets": ["appCache"],
    "excludes": ["chatHistory"],
    "mode": "preview",
    "understanding": "模型计划 E2E"
})}}]}

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        self.rfile.read(n)
        data = json.dumps(PAYLOAD).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", \(modelPort)), H).serve_forever()
"""
    try mockSource.write(to: mockScript, atomically: true, encoding: .utf8)
    let mock = Process()
    mock.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    mock.arguments = [mockScript.path]
    mock.standardOutput = FileHandle.nullDevice
    mock.standardError = FileHandle.nullDevice
    try mock.run()
    defer { mock.terminate() }

    // 等 mock 端口就绪；最多 5 秒。
    var mockReady = false
    for _ in 0..<50 {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        probe.arguments = ["-z", "127.0.0.1", "\(modelPort)"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try? probe.run()
        probe.waitUntilExit()
        if probe.terminationStatus == 0 { mockReady = true; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    checker.check("模型接口 mock 就绪", mockReady, "127.0.0.1:\(modelPort)")

    let modelPlanRoot = sampleRoot.appendingPathComponent("model-plan")
    try FileManager.default.createDirectory(at: modelPlanRoot, withIntermediateDirectories: true)
    let modelRels = ["model-a.bin", "model-b.bin"]
    for (index, rel) in modelRels.enumerated() {
        try Data(repeating: UInt8(0xA0 + index), count: 8192 * (index + 1))
            .write(to: modelPlanRoot.appendingPathComponent(rel))
    }
    let modelBytes = modelRels.enumerated().reduce(Int64(0)) { sum, pair in
        sum + Int64(8192 * (pair.offset + 1))
    }

    let config = AssistantProviderConfiguration(
        route: .openAICompatible,
        baseURL: "http://127.0.0.1:\(modelPort)/v1",
        model: "mock-model",
        timeoutSeconds: 5
    )
    let fallback = CleanIntent(
        rawText: "清一下应用缓存",
        goal: .clean,
        targets: [.appCache],
        mode: .preview,
        interpretation: "规则兜底"
    )
    let modelResult = ModelResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            modelResult.intent = try await AssistantRemoteBridge.parse(
                "清一下应用缓存",
                fallback: fallback,
                configuration: config,
                apiKey: "e2e"
            )
        } catch {
            modelResult.error = error
        }
        semaphore.signal()
    }
    semaphore.wait()
    checker.check("模型接口返回可解析的白名单意图",
                  modelResult.intent != nil && modelResult.error == nil,
                  modelResult.error?.localizedDescription ?? (modelResult.intent?.interpretation ?? "无结果"))
    guard let intent = modelResult.intent else {
        throw NSError(domain: "CleanupE2E", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "模型计划没有意图，后续链路停止"])
    }
    checker.check("模型意图只使用白名单目标", intent.targets == [.appCache])
    checker.check("模型意图不改删除模式", intent.mode == .preview)

    let modelSpec = AssistantPathSpec(
        target: .appCache,
        displayName: "模型计划样本",
        rawPath: modelPlanRoot.path,
        role: .clean,
        reason: "模型计划 E2E 隔离样本",
        category: "缓存"
    )
    let measurement = AssistantMeasurement(
        specID: modelSpec.id,
        path: modelPlanRoot.path,
        bytes: modelBytes,
        exists: true,
        isPartial: false
    )
    let plan = AssistantPlanBuilder.build(
        intent: intent,
        specs: [modelSpec],
        measurements: [measurement]
    )
    checker.check("计划只读且只有一项 clean 候选",
                  plan.isReadOnly && plan.items.count == 1 &&
                  plan.items.first?.role == .clean && plan.items.first?.defaultSelected == true,
                  "cleanBytes=\(plan.cleanBytes)")
    let eligible = AssistantCleanupPolicy.eligibleItems(in: plan, includeReview: false)
    checker.check("安全策略放行 clean、排除 partial",
                  eligible.count == 1 && eligible.first?.path == modelPlanRoot.path)

    let modelAuditURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(token)-model-audit.jsonl")
    let modelAudit = AuditLog(fileURL: modelAuditURL)
    let service = ManualDeletionService(
        audit: modelAudit,
        protectionCheck: { path in engine.isProtected(path) },
        allowedRoots: [NSHomeDirectory()]
    )
    let previews = eligible.map { item in
        try? service.preview(path: item.path, reason: item.reason)
    }
    checker.check("确认前预览拿到真实身份与体积",
                  previews.count == 1 && previews.first??.identity != nil,
                  previews.first??.sizeBytes.description ?? "无预览")
    var freeBefore: Int64 = 0
    if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: sampleRoot.path),
       let free = attrs[.systemFreeSize] as? NSNumber {
        freeBefore = free.int64Value
    }
    let trashed = try previews.compactMap { $0 }.map { preview in
        try service.moveToTrash(preview, source: "assistant-model-e2e")
    }
    checker.check("确认后只移废纸篓", trashed.count == 1)
    checker.check("原路径已消失", !FileManager.default.fileExists(atPath: modelPlanRoot.path))
    do {
        let modelTrashed = try FileManager.default.contentsOfDirectory(
            at: trashDirectory(), includingPropertiesForKeys: nil
        ).contains { $0.lastPathComponent.contains("model-plan") }
        checker.check("模型计划样本没有被永久删除（废纸篓可恢复）", modelTrashed)
    } catch {
        // 与第 4 节同口径：无 ~/.Trash 读取权限时不可取证，不伪装成失败。
        checker.skip("模型计划样本没有被永久删除（废纸篓可恢复）",
                     "当前进程无 ~/.Trash 读取权限（TCC）")
    }
    let modelAuditEvents = (try? modelAudit.events()) ?? []
    checker.check("模型计划删除写入审计链",
                  modelAuditEvents.contains { $0.action == .moveToTrash })
    var freeAfter: Int64 = 0
    if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: sampleRoot.path),
       let free = attrs[.systemFreeSize] as? NSNumber {
        freeAfter = free.int64Value
    }
    // 只移废纸篓不释放物理空间；这里记录而不是伪造“已释放”。
    print("  说明：只移废纸篓，物理可用空间不立即增加（\(freeBefore) → \(freeAfter) bytes）；原路径占用已移出。")

    // 6.6 安全闸门只放行 defaultSelected
    do {
        let foreign = ScanItem(path: "/tmp/SnowSweepE2E-should-not-delete", sizeBytes: 1)
        let review = Verdict(item: foreign, risk: .review, explanation: "", needConfirm: true)
        let protectedV = Verdict(item: foreign, risk: .protected, explanation: "", needConfirm: true)
        let unknown = Verdict(item: foreign, risk: .unknown, explanation: "", needConfirm: true)
        let badReport = ScanReport(
            scanStatus: "complete", totalBytes: 3, verdicts: [review, protectedV, unknown]
        )
        let safe = CleanupSelection.safeEntries(
            from: badReport, selectedPaths: Set([foreign.path])
        )
        checker.check("review/protected/unknown 全部被闸门拦截", safe.isEmpty)
    }
}

do {
    try run()
} catch {
    checker.failed += 1
    print("\n[异常] 实测中断：\(error)")
}

// exit() 会跳过 defer，因此清理必须显式调用，确保测试痕迹不残留。
// 排查废纸篓断言时可设 SNOWSWEEP_E2E_KEEP=1 临时保留本次 token 条目。
if ProcessInfo.processInfo.environment["SNOWSWEEP_E2E_KEEP"] != "1" {
    cleanupAll()
}

print("\n========================================")
print("真机清理闭环实测结果：通过 \(checker.passed) / 未验证 \(checker.skipped) / 失败 \(checker.failed)")
print("========================================")
exit(checker.failed == 0 ? 0 : 1)
